#!/usr/bin/env python3
"""Exercise the production session-only initializer in real bash/zsh PTYs.

This is an adapter test, not an SSH transport or remote Bash 4.2 certification.
Pass additional Bash binaries as arguments to validate an available version.
"""
from pathlib import Path
import errno
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import shutil
import time

ROOT = Path(__file__).resolve().parents[1]
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(rb"\x1b\]133;([^\x07]*)\x07")


def initializer():
    # Match shell_integration.zig's shell transport quoting byte for byte.
    def quote(path):
        value = path.read_bytes()
        return b"'" + value.replace(b"'", b"'\\''") + b"'"
    base = ROOT / "src/vt/shell"
    return (b'if test -n "${BASH_VERSION-}"; then builtin eval ' +
            quote(base / "integration.bash") +
            b'; elif test -n "${ZSH_VERSION-}"; then builtin eval ' +
            quote(base / "integration.zsh") + b'; fi\n')


def initializer_chunks(nonce=b"1234567890abcdef"):
    """Production ACK transport: short bootstrap, then silent input reads."""
    def quote(value):
        for old, new in ((b"\\", b"\\\\"), (b"'", b"\\'"),
                         (b"\n", b"\\n"), (b"\r", b"\\r"), (b"\t", b"\\t")):
            value = value.replace(old, new)
        return b"$'" + value + b"'"

    def ack(sequence, size):
        return b"133;P;zw_init=" + nonce + b";" + str(sequence).encode() + b";" + str(size).encode()

    def ack_value(sequence, size):
        return b"$'\\e]" + ack(sequence, size) + b"\\a'"

    body = b"".join(line.strip() + (b"" if line.strip().endswith(b";") else b" ")
                    for line in (ROOT / "src/vt/shell/receive.sh").read_bytes().splitlines()
                    if line.strip() and not line.lstrip().startswith(b"#"))
    first = (body + b"_zwA=" + ack_value(1, 128) +
             b';_zwR ${BASH_VERSION:+-n}${ZSH_VERSION:+-k} ' + quote(nonce) + b'||_zwO=0;builtin unset -f _zwR;if test "${_zwO-}${_zwD-}" = 11;then builtin eval "$_zwP";builtin printf %s "$_zwA";fi;builtin unset _zwT _zwI _zwA _zwL _zwC _zwO _zwP _zwD\n')
    assert len(first) < 1024
    chunks = [(first, b"\x1b]" + ack(1, 128) + b"\x07")]
    script = initializer()
    for offset in range(0, len(script), 128):
        fragment = script[offset:offset + 128]
        sequence = len(chunks) + 1
        line = ((b"_zwP=" if offset == 0 else b"_zwP+=") + quote(fragment) +
                b"; _zwA=" + ack_value(sequence, len(fragment)) + b"\n")
        assert len(line) <= 512 and line.count(b"\n") == 1
        chunks.append((line, b"\x1b]" + ack(sequence, len(fragment)) + b"\x07"))
    sequence = len(chunks) + 1
    chunks.append((b"_zwD=1; _zwA=" + ack_value(sequence, 0) + b"\n",
                   b"\x1b]" + ack(sequence, 0) + b"\x07"))
    return chunks


class Shell:
    def __init__(self, binary):
        self.binary = binary
        self.kind = "zsh" if "zsh" in Path(binary).name else "bash"
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ, TERM="xterm-256color", PS1="ZW_TEST> ",
                       PS2="ZW_MORE> ", BASH_SILENCE_DEPRECATION_WARNING="1")
            args = [binary, "-f", "-i"] if self.kind == "zsh" else [binary, "--noprofile", "--norc", "-i"]
            os.execve(binary, args, env)
        os.set_blocking(self.fd, False)
        self.buffer = b""
        self.read_until(lambda data: b"ZW_TEST> " in data or data.endswith(b"# ") or data.endswith(b"% "))
        self.command(b"PS1='ZW_TEST> '; PS2='ZW_MORE> '", integrated=False)

    def read_until(self, predicate, timeout=8):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate(self.buffer):
                return self.buffer
            if select.select([self.fd], [], [], 0.05)[0]:
                try:
                    self.buffer += os.read(self.fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EAGAIN:
                        raise
        raise AssertionError(("PTY timeout", self.buffer[-1500:]))

    def send(self, data):
        self.buffer = b""
        end = time.monotonic() + 8
        while data and time.monotonic() < end:
            readable, writable, _ = select.select([self.fd], [self.fd], [], 0.05)
            if readable:
                self.buffer += os.read(self.fd, 65536)
            if writable:
                data = data[os.write(self.fd, data[:128]):]
        assert not data, "PTY write timeout"

    def command(self, text, integrated=True):
        self.send(text + b"\n")
        if integrated:
            return self.read_until(lambda data: any(x == b"B" for x in OSC.findall(data)))
        # The input line can contain the prompt text: wait for a fresh final prompt.
        return self.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))

    def install(self, ready=True):
        for index, (line, ack) in enumerate(initializer_chunks()):
            self.send(line)
            data = self.read_until(lambda data: ack in data)
            if index > 0:
                assert b"_zwP=" not in data and b"_zwP+=" not in data, "initializer payload echoed"
                assert b"_zwA=$'" not in data, "initializer transport echoed"
        if ready:
            return self.read_until(lambda data: b"\x1b]133;B\x07" in data.split(ack, 1)[1])
        return self.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))

    def close(self):
        os.close(self.fd)
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)


def events(data):
    return [item.split(b";", 1)[0] for item in OSC.findall(data)]


def check_quiet_recovery(binary):
    for scenario in ("timeout", "interrupt"):
        shell = Shell(binary)
        try:
            # Give the shell an existing INT handler and prove it survives.
            shell.command(b"trap 'printf USER_INT_HANDLER' INT", integrated=False)
            before = shell.command(b"stty -g", integrated=False)
            before = shell.read_until(lambda data: re.search(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", data) is not None and CSI.sub(b"", data).endswith(b"ZW_TEST> "))
            tty_before = re.findall(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", before)[-1]
            header, ack = initializer_chunks()[0]
            # Same production receiver with a short fixture deadline.
            header = header.replace(b"-t 4", b"-t 1")
            shell.send(header)
            shell.read_until(lambda data: ack in data)
            shell.buffer = b""
            os.write(shell.fd, b"\x03" if scenario == "interrupt" else b"_zwP+=partial")
            shell.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "), timeout=3)
            result = shell.command(b"printf 'POST_RECOVERY_OUTPUT\\n'", integrated=False)
            assert b"printf 'POST_RECOVERY_OUTPUT" in result, "ordinary input echo not restored"
            assert b"POST_RECOVERY_OUTPUT\r\n" in result, "ordinary business output lost"
            after = shell.command(b"stty -g", integrated=False)
            after = shell.read_until(lambda data: re.search(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", data) is not None and CSI.sub(b"", data).endswith(b"ZW_TEST> "))
            tty_after = re.findall(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", after)[-1]
            assert tty_before == tty_after, "terminal flags changed permanently"
            handler = shell.command(b"trap", integrated=False)
            assert b"USER_INT_HANDLER" in handler, "user INT trap not restored"
            assert b"_zwP=partial" not in result, "partial input executed"
            print(f"PASS {binary} quiet receiver {scenario}: echo, termios, trap and output restored")
        finally:
            shell.close()


def check_quiet_restore_failure(binary):
    for failure in ("terminal", "trap"):
        shell = Shell(binary)
        try:
            with tempfile.TemporaryDirectory(prefix="zw-stty-failure-") as directory:
                if failure == "terminal":
                    real_stty = shutil.which("stty")
                    assert real_stty
                    fake = Path(directory) / "stty"
                    fake.write_text("#!/bin/sh\ncase \"$1\" in -g|-echo) exec " + real_stty +
                                    " \"$@\";; *) " + real_stty + " \"$@\"; exit 77;; esac\n")
                    fake.chmod(0o700)
                    shell.command(b"PATH='" + os.fsencode(directory) + b"':$PATH", integrated=False)
                chunks = initializer_chunks()
                for line, ack in chunks[:-1]:
                    shell.send(line)
                    shell.read_until(lambda data: ack in data)
                line, ack = chunks[-1]
                if failure == "trap":
                    line = b"_zwI='return 77'; " + line
                shell.send(line)
                data = shell.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))
                assert b"zw_restored=" not in data, "failed restoration claimed successful"
                assert ack not in data, "failed receiver emitted completion ACK"
                assert b"\x1b]133;A" not in data, "hooks evaluated after recovery failure"
                result = shell.command(b"printf 'RESTORE_FAILURE_OUTPUT\\n'", integrated=False)
                assert b"RESTORE_FAILURE_OUTPUT\r\n" in result
                print(f"PASS {binary} {failure} restore failure: no restored/completion ACK, no hook eval")
        finally:
            shell.close()


def check(binary):
    shell = Shell(binary)
    try:
        # Existing prompt hooks still receive the command's real status.
        if shell.kind == "bash":
            shell.command(b"PROMPT_COMMAND='printf \"USER_STATUS:%s\\n\" \"$?\"'", integrated=False)
        else:
            shell.command(b"precmd() { printf 'USER_STATUS:%s\\n' \"$?\"; return 31; }; _user_precmd() { return 32; }; precmd_functions=(_user_precmd)", integrated=False)
        shell.install()
        for command, code in ((b"true", 0), (b"false", 1), (b"sh -c 'exit 7'", 7),
                              (b"printf 'plain-output\\n'", 0), (b"false | true", 0),
                              (b"if true; then false; fi", 1)):
            output = shell.command(command)
            markers = OSC.findall(output)
            assert events(output).count(b"C") == 1, (command, markers)
            assert [x for x in markers if x.startswith(b"D;")] == [f"D;{code}".encode()], (command, markers)
            assert f"USER_STATUS:{code}\r\n".encode() in output, output
        shell.command(b"false")
        assert b"PREVIOUS:1\r\n" in shell.command(b"printf 'PREVIOUS:%s\\n' \"$?\"")
        shell.command(b"cd /tmp; ZW_VALUE='same session'; zw_test_fn() { printf 'FUNCTION:%s\\n' \"$ZW_VALUE\"; }")
        output = shell.command(b"printf 'PID:%s DIR:%s\\n' \"$$\" \"$PWD\"; zw_test_fn")
        assert f"PID:{shell.pid} DIR:/".encode() in output, output
        assert b"FUNCTION:same session\r\n" in output, output
        assert b"\x1b]7;file://" in output, output
        # Duplicate initialization must not add a second producer.
        shell.install()
        assert events(shell.command(b"true")).count(b"C") == 1
        output = shell.command(b"(exit 7)")
        if shell.kind == "bash" and b"zw_start=debug" in output:
            assert b"C" not in events(output), OSC.findall(output)
            assert b"D;7" in OSC.findall(output), OSC.findall(output)
            print(f"{binary}: DEBUG pure-subshell start unavailable (explicit limitation)")
        else:
            assert events(output).count(b"C") == 1 and b"D;7" in OSC.findall(output), OSC.findall(output)
        print(f"{binary}: status, prompt hooks, cwd, same PID/state, idempotency passed")
    finally:
        shell.close()

    if "bash" in Path(binary).name:
        shell = Shell(binary)
        try:
            shell.command(b"trap ':' DEBUG", integrated=False)
            output = shell.install(ready=False)
            assert all((x.startswith(b"P;zw_init=") or x.startswith(b"P;zw_restored=")) for x in OSC.findall(output)), OSC.findall(output)
            output = shell.command(b"trap -p DEBUG", integrated=False)
            assert b"trap -- ':' DEBUG" in output, output
            print(f"{binary}: existing DEBUG trap preserved; integration declined")
        finally:
            shell.close()

    for marker in (b"133", b"633"):
        shell = Shell(binary)
        try:
            # Detect another loaded producer without invoking or replacing it.
            shell.command(b"existing_integration() { printf '\\e]" + marker + b";C\\a'; }", integrated=False)
            output = shell.install(ready=False)
            assert all((x.startswith(b"P;zw_init=") or x.startswith(b"P;zw_restored=")) for x in OSC.findall(output)), OSC.findall(output)
            output = shell.command(b"printf 'VERSION:%s\\n' \"${__zw_osc_version-unset}\"", integrated=False)
            assert b"VERSION:unset\r\n" in output, output
        finally:
            shell.close()
    print(f"{binary}: existing OSC 133/633 producer preserved without duplicate hooks")


if __name__ == "__main__":
    for binary in sys.argv[1:] or ["/bin/bash", "/bin/zsh"]:
        print(subprocess.check_output([binary, "--version"], text=True).splitlines()[0])
        check(binary)
        check_quiet_recovery(binary)
        check_quiet_restore_failure(binary)
