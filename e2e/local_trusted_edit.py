#!/usr/bin/env python3
"""Headless system-zsh/ZLE proof; never opens the native application.

Compiles the small lifecycle-only module and uses a real controlling Darwin PTY,
private Unix socket, user .zshenv/.zshrc, and actual ZLE widgets. All commands and
files belong to the temporary fixture. Run: python3 e2e/local_trusted_edit.py
"""
import os
from pathlib import Path
import pty
import select
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def quote(text):
    return "'" + str(text).replace("'", "'\\''") + "'"


def frame(fields):
    payload = b''.join(str(len(value)).encode() + b':' + value + b',' for value in fields)
    return f'{len(payload):08x}'.encode() + payload


def decode(payload):
    values = []
    while payload:
        count, payload = payload.split(b':', 1)
        count = int(count)
        assert payload[count:count + 1] == b','
        values.append(payload[:count])
        payload = payload[count + 1:]
    return values


class Shell:
    def __init__(self, directory, vi=False, rc_extra=''):
        self.directory = directory
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(directory / 'control'))
        self.listener.listen(2)
        self.listener.setblocking(False)
        self.connection = None
        self.rx = b''
        self.output = b''
        self.events = []
        self.sequence = 0
        self.snapshot = None
        self.operation = 0
        self.user = directory / 'user'
        self.user.mkdir()
        self.later = directory / 'later'
        self.later.mkdir()
        (self.user / '.zshenv').write_text('export ZDOTDIR=' + quote(self.later) + '\n')
        (self.later / '.zshrc').write_text('''
PROMPT='ZW> '
bindkey -%s
zle-line-init() { print -r -- init >> %s; }
zle -N zle-line-init
zle-line-pre-redraw() { print -r -- redraw >> %s; }
zle -N zle-line-pre-redraw
_user_tab() { BUFFER+=' USER_TAB'; CURSOR=${#BUFFER}; }
zle -N _user_tab
bindkey '^I' _user_tab
print -s -- 'echo fixture-history'
''' % ('v' if vi else 'e', quote(directory / 'hooks'), quote(directory / 'hooks')) + rc_extra)
        # This matches the native wrapper: restore original ZDOTDIR, read its
        # .zshenv once, preserve its redirect, then append the integration hook.
        (directory / '.zshenv').write_text('export ZDOTDIR=' + quote(self.user) + '\n'
            'source "$ZDOTDIR/.zshenv"\n'
            'typeset -g _zw_session=7 _zw_generation=3 _zw_nonce=nonce _zw_parent=' + str(os.getpid()) +
            ' _zw_socket=' + quote(directory / 'control') + ' _zw_module_dir=' + quote(directory) + '\n'
            'source ' + quote(ROOT / 'src/local/shell/integration.zsh') + '\n')
        self.pid, self.fd = pty.fork()
        if not self.pid:
            os.environ['ZDOTDIR'] = str(directory)
            os.execv('/bin/zsh', ['/bin/zsh', '-l', '-i'])
        self.until(lambda: self.snapshot is not None)

    def read(self, duration=.05):
        targets = [self.listener, self.fd]
        if self.connection:
            targets.append(self.connection)
        readable, _, _ = select.select(targets, [], [], duration)
        for target in readable:
            if target is self.listener:
                self.connection, _ = self.listener.accept()
                self.connection.setblocking(False)
                self.rx = b''
                self.sequence = 0
            elif target == self.fd:
                try:
                    self.output += os.read(self.fd, 65536)
                except OSError:
                    pass
            else:
                chunk = self.connection.recv(65536)
                if not chunk:
                    self.connection.close()
                    self.connection = None
                    continue
                self.rx += chunk
                while len(self.rx) >= 8:
                    size = int(self.rx[:8], 16)
                    if len(self.rx) < size + 8:
                        break
                    values = decode(self.rx[8:8 + size])
                    self.rx = self.rx[8 + size:]
                    assert values[:4] == [b'1', b'7', b'3', b'nonce']
                    self.events.append(values)
                    if values[5] == b'snapshot':
                        self.snapshot = values
                    if values[5] != b'revoked':
                        self.send([b'credit'])

    def until(self, condition, timeout=4):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > deadline:
                raise AssertionError(f'timeout; events={self.events[-4:]!r}; output={self.output[-1000:]!r}')
            self.read()

    def send(self, fields):
        self.sequence += 1
        self.connection.sendall(frame([b'1', b'7', b'3', b'nonce', str(self.sequence).encode()] + fields))

    def type(self, text):
        os.write(self.fd, text)

    def buffer(self, expected):
        self.until(lambda: self.snapshot[8] == expected)
        return self.snapshot

    def request(self, kind, replacement=b'', token=None, revision=None):
        current = self.snapshot
        self.operation += 1
        operation = str(self.operation).encode()
        self.send([kind, operation, token or current[6], revision or current[7], current[8], current[9], replacement])
        self.until(lambda: any(v[5] in (b'applied', b'rejected') and v[6] == operation for v in self.events))
        return next(v for v in reversed(self.events) if v[5] in (b'applied', b'rejected') and v[6] == operation)

    def close(self):
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        os.close(self.fd)
        if self.connection:
            self.connection.close()
        self.listener.close()


def main():
    with tempfile.TemporaryDirectory(prefix='zw-zle-proof-') as temporary:
        directory = Path(temporary)
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-bundle',
            '-undefined', 'dynamic_lookup', str(ROOT / 'src/local/shell/zw_ipc.c'), '-o', str(directory / 'zw_ipc.so')], check=True)
        for vi in (False, True):
            case = directory / ('vi' if vi else 'emacs')
            case.mkdir()
            (case / 'zw_ipc.so').symlink_to(directory / 'zw_ipc.so')
            shell = Shell(case, vi)
            try:
                assert shell.snapshot[13] == b'start'
                assert shell.snapshot[12] in (b'main', b'viins')
                shell.type('echo 中文é👩‍💻'.encode())
                expected = 'echo 中文é👩‍💻'.encode()
                snapshot = shell.buffer(expected)
                assert int(snapshot[9]) == len(expected.decode())
                original = snapshot[7]
                # Data containing shell code is replaced in one widget and
                # remains unexecuted until an explicit terminal Return.
                marker = case / 'executed'
                replacement = ('printf done > ' + quote(marker)).encode()
                result = shell.request(b'replace', replacement)
                assert result[5] == b'applied', result
                shell.buffer(replacement)
                assert not marker.exists()
                assert int(result[8]) > int(original)
                stale = shell.request(b'replace', b'NO', revision=original)
                assert stale[5:] == [b'rejected', str(shell.operation).encode(), b'revision_changed']
                wrong = shell.request(b'replace', b'NO', token=b'999999')
                assert wrong[5] == b'rejected' and wrong[7] == b'stale_prompt'
                shell.type(b'\r')
                shell.until(marker.exists)
                shell.until(lambda: shell.snapshot[8] == b'' and shell.connection is not None)
                # Preserve an existing user Tab binding and its actual BUFFER.
                shell.type(b'abc\t')
                shell.buffer(b'abc USER_TAB')
                shell.type(b'\x15')
                shell.until(lambda: shell.snapshot[8] == b'')
                begun = shell.request(b'begin')
                assert begun[5] == b'applied' and int(begun[11]) > 0
                assert shell.snapshot[8] == b''
                literal = shell.request(b'replace', b'@')
                assert literal[5] == b'applied'
                shell.buffer(b'@')
                shell.type(b'\x15')
                shell.until(lambda: shell.snapshot[8] == b'')
                hooks = (case / 'hooks').read_text().splitlines()
                assert 'init' in hooks and 'redraw' in hooks
                if vi:
                    shell.type(b'abc\x1b')
                    shell.until(lambda: shell.snapshot[12] == b'vicmd')
                    denied = shell.request(b'replace', b'NO')
                    assert denied[5] == b'rejected' and denied[7] == b'mode_changed'
                print(('vi' if vi else 'emacs') + ': real snapshots, Unicode cursor, replace/no execution, stale owner/revision, user hooks/Tab, lease and literal @ passed')
            finally:
                shell.close()


if __name__ == '__main__':
    main()
