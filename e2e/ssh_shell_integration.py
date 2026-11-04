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
             b';_zwR ${BASH_VERSION:+-n}${ZSH_VERSION:+-k} ' + quote(nonce) + b'||_zwD=0;builtin unset -f _zwR _zwG;[[ ${_zwD-} = 1 ]]&&{ builtin eval "$_zwP";builtin printf %s "$_zwA";};builtin unset _zwT _zwI _zwA _zwL _zwC _zwP _zwD _zwF\n')
    assert len(first) < 1024
    chunks = [(first, b"\x1b]" + ack(1, 128) + b"\x07")]
    script = initializer()
    for batch_offset in range(0, len(script), 8192):
        batch = script[batch_offset:batch_offset + 8192]
        sequence = len(chunks) + 1
        line = receiver_upgrade() if batch_offset == 0 else b""
        for offset in range(0, len(batch), 128):
            fragment = batch[offset:offset + 128]
            line += b"_zwA=;" + (b"_zwP=" if batch_offset + offset == 0 else b"_zwP+=") + quote(fragment)
            if offset + len(fragment) == len(batch):
                line += b"; _zwA=" + ack_value(sequence, len(batch))
            line += b"\n"
        assert all(len(physical) < 512 for physical in line.splitlines())
        chunks.append((line, b"\x1b]" + ack(sequence, len(batch)) + b"\x07"))
    sequence = len(chunks) + 1
    chunks.append((b"_zwD=1; _zwA=" + ack_value(sequence, 0) + b"\n",
                   b"\x1b]" + ack(sequence, 0) + b"\x07"))
    return chunks



def receiver_upgrade():
    def quote(value):
        for old, new in ((b"\\", b"\\\\"), (b"'", b"\\'"),
                         (b"\n", b"\\n"), (b"\r", b"\\r"), (b"\t", b"\\t")):
            value = value.replace(old, new)
        return b"$'" + value + b"'"
    compact = b"".join(line.strip() + (b"" if line.strip().endswith(b";") else b" ")
                       for line in (ROOT / "src/vt/shell/receive_fast.sh").read_bytes().splitlines()
                       if line.strip() and not line.lstrip().startswith(b"#"))
    result = b""
    for offset in range(0, len(compact), 128):
        result += (b"_zwA=;_zwF=" if offset == 0 else b"_zwF+=") + quote(compact[offset:offset + 128]) + b"\n"
    return result + b"""if test -n "${ZSH_VERSION-}";then builtin zmodload -e zsh/system 2>/dev/null||{ builtin zmodload zsh/system 2>/dev/null&&_zwI='builtin zmodload -u zsh/system||_zwD=0;'$_zwI;};fi
_zwB=;_zwI='builtin unset _zwB;'$_zwI
if test -n "${BASH_VERSION-}"||test "$(builtin whence -w sysread)" = 'sysread: builtin';then builtin eval "$_zwF";fi
builtin unset _zwF
"""


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
        self.command_counter = 0
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
                try:
                    data = data[os.write(self.fd, data[:128]):]
                except BlockingIOError:
                    pass
        assert not data, "PTY write timeout"

    def command(self, text, integrated=True):
        self.command_counter += 1
        marker = f"\x1eZW_CMD_{self.command_counter}\x1f".encode()
        if not integrated:
            # A late previous prompt must not satisfy this command's wait.
            text += f"; builtin printf '\\036ZW_CMD_{self.command_counter}\\037'".encode()
        self.send(text + b"\n")
        if integrated:
            return self.read_until(lambda data: any(x == b"B" for x in OSC.findall(data)))
        # The input line can contain the prompt text: wait for a fresh final prompt.
        return self.read_until(lambda data: marker in data and CSI.sub(b"", data).endswith(b"ZW_TEST> "))

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
    readers = ("bootstrap", "fast", "module-unavailable") if "zsh" in Path(binary).name else ("bootstrap", "fast")
    for reader in readers:
        for scenario in ("timeout", "interrupt"):
            shell = Shell(binary)
            try:
                # Give the shell an existing INT handler and prove it survives.
                shell.command(b"trap 'printf USER_INT_HANDLER' INT", integrated=False)
                before = shell.command(b"stty -g", integrated=False)
                before = shell.read_until(lambda data: re.search(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", data) is not None and CSI.sub(b"", data).endswith(b"ZW_TEST> "))
                tty_before = re.findall(rb"(?:gfmt1:|[0-9a-f]+:)[^\r\n]+", before)[-1]
                if reader == "module-unavailable":
                    shell.command(b"disable zmodload", integrated=False)
                header, ack = initializer_chunks()[0]
                # Same production receiver with a short fixture deadline.
                header = header.replace(b"-t 4", b"-t 1")
                shell.send(header)
                shell.read_until(lambda data: ack in data)
                if reader != "bootstrap":
                    upgrade = receiver_upgrade().replace(b"-t 4", b"-t 1")
                    marker = b"\x1b]133;P;zw_test_reader=ready\x07"
                    shell.send(upgrade + b"builtin printf '\\e]133;P;zw_test_reader=ready\\a'\n")
                    shell.read_until(lambda data: marker in data)
                shell.buffer = b""
                os.write(shell.fd, b"\x03" if scenario == "interrupt" else b"_zwP+=partial")
                # Restoration must wait for the client to drain its native
                # batch and send a nonce-bound abort barrier.
                time.sleep(1.1 if scenario == "timeout" else .05)
                nonce = re.search(rb"zw_init=([0-9a-f]+);", ack)[1]
                shell.send(b"\x03\n" + nonce + b"\n")
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
                print(f"PASS {binary} quiet receiver {reader}/{scenario}: echo, termios, trap and output restored")
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


def check_fast_receiver_boundaries(binary):
    shell = Shell(binary)
    try:
        header, ack = initializer_chunks()[0]
        shell.send(header)
        shell.read_until(lambda data: ack in data)
        marker = b"\x1b]133;P;zw_test_reader=ready\x07"
        shell.send(receiver_upgrade() + b"builtin printf '\\e]133;P;zw_test_reader=ready\\a'\n")
        shell.read_until(lambda data: marker in data)
        # A split line is retained without evaluating its incomplete prefix.
        shell.send(b"builtin printf 'SPLIT_")
        time.sleep(.05)
        shell.send(b"LINE_OK\\n'\n")
        shell.read_until(lambda data: b"SPLIT_LINE_OK\r\n" in data)
        # Reject an oversized physical line without evaluating its suffix.
        shell.send(b" " * 512 + b"; builtin printf SHOULD_NOT_EXECUTE\n")
        nonce = re.search(rb"zw_init=([0-9a-f]+);", ack)[1]
        shell.send(b"\x03\n" + nonce + b"\n")
        data = shell.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))
        assert b"SHOULD_NOT_EXECUTE" not in data
        assert b"zw_restored=" in data
        assert b"\x1b]133;A" not in data
        print(f"PASS {binary} fast receiver: partial line retained, oversized line rejected without evaluation")
    finally:
        shell.close()


def check_receiver_module_state(binary):
    if "zsh" not in Path(binary).name:
        return
    for mode, outcome in ((mode, outcome) for mode in ("cold", "loaded", "sysread-disabled", "autoload") for outcome in ("success", "cancel")):
        shell = Shell(binary)
        try:
            if mode == "autoload":
                shell.command(b"builtin zmodload -Fa zsh/system b:sysread", integrated=False)
            elif mode != "cold":
                shell.command(b"builtin zmodload zsh/system", integrated=False)
            if mode == "sysread-disabled":
                shell.command(b"builtin zmodload -F zsh/system -b:sysread", integrated=False)
            if mode == "loaded":
                shell.command(b"setopt shwordsplit nonomatch", integrated=False)
            probe = (b"builtin zmodload -e zsh/system; builtin printf 'MODULE_STATUS:%s\\n' \"$?\"; "
                     b"builtin zmodload -F -l zsh/system 2>/dev/null; builtin zmodload -Fa -l zsh/system 2>/dev/null; "
                     b"builtin printf 'OPTIONS_BEGIN\\n'; builtin setopt; builtin printf 'OPTIONS_END\\n'")
            before = shell.command(probe, integrated=False)
            if outcome == "success":
                shell.install()
            else:
                header, ack = initializer_chunks()[0]
                nonce = re.search(rb"zw_init=([0-9a-f]+);", ack)[1]
                shell.send(header)
                shell.read_until(lambda data: ack in data)
                shell.send(receiver_upgrade() + b"builtin printf 'MODULE_READER_READY\\n'\n")
                shell.read_until(lambda data: b"MODULE_READER_READY\r\n" in data)
                shell.send(b"\x03\n" + nonce + b"\n")
                shell.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))
            after = shell.command(probe, integrated=outcome == "success")
            status = lambda data: re.findall(rb"MODULE_STATUS:[01]\r\n", data)
            features = lambda data: re.findall(rb"^[+-]?[bpf]:[^\r\n]+", data, re.M)
            assert status(before) == status(after), (mode, before, after)
            assert features(before) == features(after), (mode, before, after)
            options = lambda data: re.findall(rb"OPTIONS_BEGIN\r\n(.*?)OPTIONS_END\r\n", data, re.S)
            assert options(before) == options(after), (mode, before, after)
            print(f"PASS {binary} receiver preserves {mode} module/features after {outcome}")
        finally:
            shell.close()


def check_cancel_batch_tail(binary):
    for noflsh in (False, True):
        shell = Shell(binary)
        try:
            shell.command(b"stty noflsh" if noflsh else b"stty -noflsh", integrated=False)
            header, ack = initializer_chunks()[0]
            nonce = re.search(rb"zw_init=([0-9a-f]+);", ack)[1]
            shell.send(header)
            shell.read_until(lambda data: ack in data)
            marker = b"UPGRADED\r\n"
            shell.send(receiver_upgrade() + b"builtin printf 'UPGRADED\\n'\n")
            shell.read_until(lambda data: marker in data)
            shell.send(b"builtin printf 'BLOCKING\\n'; command sleep 1\n")
            shell.read_until(lambda data: b"BLOCKING\r\n" in data)
            payload = b"_zwA=;_zwP+='padding'\n" * 420 + b"builtin printf ESCAPED_AFTER_CANCEL\n"
            assert len(payload) > 8192
            shell.buffer = b""
            written = os.write(shell.fd, payload[:128])
            assert written > 0
            shell.send(b"\x03")
            # Cancellation cannot acknowledge restoration ahead of the batch.
            end = time.monotonic() + .15
            while time.monotonic() < end:
                if select.select([shell.fd], [], [], .02)[0]:
                    shell.buffer += os.read(shell.fd, 65536)
            assert b"zw_restored=" not in shell.buffer, "restored before the batch barrier"
            shell.send(payload[written:] + b"\x03\n" + nonce + b"\n")
            data = shell.read_until(lambda data: CSI.sub(b"", data).endswith(b"ZW_TEST> "))
            assert b"zw_restored=" in data
            assert b"ESCAPED_AFTER_CANCEL" not in data and b"_zwP+=" not in data
            assert b"\x1b]133;A" not in data
            output = shell.command(b"printf 'AFTER_CANCEL_OK\\n'", integrated=False)
            assert b"AFTER_CANCEL_OK\r\n" in output
            if shell.kind == "zsh":
                status = shell.command(b"builtin zmodload -e zsh/system; printf 'MODULE_STATUS:%s\\n' \"$?\"", integrated=False)
                assert b"MODULE_STATUS:1\r\n" in status
            print(f"PASS {binary} 8 KiB cancellation noflsh={noflsh}: tail discarded before restoration")
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
        check_fast_receiver_boundaries(binary)
        check_receiver_module_state(binary)
        check_cancel_batch_tail(binary)
