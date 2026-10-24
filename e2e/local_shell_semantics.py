#!/usr/bin/env python3
"""Production shell integration in real system-zsh PTYs; no application launch."""
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import unquote_to_bytes

from local_trusted_edit import ROOT, Shell, quote


def events(output):
    return re.findall(rb'\x1b\]133;([^\x07]*)\x07', output)


def command(shell, text):
    token = shell.snapshot[6]
    start = len(shell.output)
    shell.type(text + b'\r')
    shell.until(lambda: shell.snapshot[6] != token and shell.snapshot[8] == b'')
    return events(shell.output[start:])


def main():
    with tempfile.TemporaryDirectory(prefix='zw-shell-semantics-') as temporary:
        directory = Path(temporary)
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-bundle', '-undefined', 'dynamic_lookup',
            str(ROOT / 'src/local/shell/zw_ipc.c'), '-o', str(directory / 'zw_ipc.so')], check=True)
        for existing in (False, True):
            case = directory / ('existing' if existing else 'automatic')
            case.mkdir()
            (case / 'zw_ipc.so').symlink_to(directory / 'zw_ipc.so')
            statuses = case / 'statuses'
            rc = '''
precmd() { print -r -- "special:$?" >> %s; }
_user_precmd() { print -r -- "array:$?" >> %s; }
precmd_functions+=(_user_precmd)
_user_preexec() { print -r -- preexec >> %s; }
preexec_functions+=(_user_preexec)
''' % (quote(statuses), quote(statuses), quote(statuses))
            if existing:
                rc += '''
_user_semantic_preexec() { printf '\\e]133;C;cmdline=user\\a'; }
_user_semantic_precmd() { local code=$?; printf '\\e]133;D;%d\\a\\e]133;A\\a' "$code"; }
preexec_functions+=(_user_semantic_preexec)
precmd_functions+=(_user_semantic_precmd)
'''
            shell = Shell(case, rc_extra=rc)
            try:
                for text, code in ((b'true', 0), (b'false', 1), (b'(exit 7)', 7),
                                   (b'printf "semi;percent%% \\a"', 0),
                                   ('printf "中文"'.encode(), 0)):
                    observed = command(shell, text)
                    starts = [e for e in observed if e.startswith(b'C;')]
                    ends = [e for e in observed if e.startswith(b'D;')]
                    assert len(starts) == 1 and ends == [f'D;{code}'.encode()], observed
                    if not existing:
                        assert starts[0].startswith(b'C;cmdline_url='), starts
                        assert unquote_to_bytes(starts[0].split(b'=', 1)[1].decode()) == text
                        assert observed == [starts[0], ends[0], b'A', b'B'], observed
                    lines = statuses.read_text().splitlines()
                    assert lines[-2:] == [f'special:{code}', f'array:{code}'], lines
                # Shell-visible status survives all user and production hooks.
                command(shell, b'false')
                command(shell, ('printf "%s" "$?" > ' + quote(case / 'status')).encode())
                assert (case / 'status').read_text() == '1'
                assert statuses.read_text().count('preexec\n') == 7
                print(('existing OSC133' if existing else 'automatic OSC133') +
                      ': single command events, real statuses, consecutive commands, safe metadata and user hooks passed')
            finally:
                shell.close()


if __name__ == '__main__':
    main()
