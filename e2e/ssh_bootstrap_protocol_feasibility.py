#!/usr/bin/env python3
"""Controlled local BootstrapV1 resource proof, never a real-host deployment.

Runs the real versioned launcher, native module and zsh hooks on a disposable
PTY, with a separate pipe-backed control relay. This proves that resource
combination only; SSH/recording/host authorization need separate acceptance.
"""
import argparse
import hashlib
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import time


def encode(fields):
    body = b"".join(str(len(value)).encode() + b":" + value + b"," for value in fields)
    return f"{len(body):08x}".encode() + body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.resources / "manifest.json").read_bytes())
    root = pathlib.Path("/tmp/zw-bootstrap-v1-" + os.urandom(16).hex())
    root.mkdir(mode=0o700)
    report = {"status": "running", "checks": [], "resources": manifest, "limits": ["Local native PTY and separate pipe-backed control process, not an SSH transport.", "No production recording or native App was started.", "Linux resources are not executed by this Darwin proof."]}
    child = master = control = None
    try:
        for entry in manifest["files"]:
            encoded = (args.resources / (entry["name"] + ".payload")).read_bytes()
            assert encoded.startswith(b"ZWBOOTSTRAP1\n")
            data = encoded[len(b"ZWBOOTSTRAP1\n"):]
            assert len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"]
            (root / entry["name"]).write_bytes(data)
            (root / entry["name"]).chmod(entry["mode"])
        nonce = os.urandom(32).hex().encode()
        child, master = pty.fork()
        if child == 0:
            os.execve(str(root / "bootstrap"), [str(root / "bootstrap"), "shell", str(root), "17", "1", nonce.decode(), "/bin/zsh"], {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_ALL": "C.UTF-8"})
        os.set_blocking(master, False)
        deadline = time.monotonic() + 5
        while not (root / "control.sock").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        control = subprocess.Popen([str(root / "bootstrap"), "control", str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.set_blocking(control.stdout.fileno(), False)
        private = b""
        events, output = [], bytearray()
        tx_sequence = 0
        rx_sequence = 0

        def receive():
            nonlocal private, rx_sequence
            for fd in select.select([master, control.stdout.fileno()], [], [], 0.05)[0]:
                try:
                    data = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if fd == master:
                    output.extend(data)
                else:
                    private += data
            while len(private) >= 8:
                size = int(private[:8], 16)
                assert size <= 131072
                if len(private) < size + 8:
                    break
                body, private = private[8:size + 8], private[size + 8:]
                fields = []
                while body:
                    digits, body = body.split(b":", 1)
                    count = int(digits)
                    assert body[count:count + 1] == b"," and len(fields) < 16
                    fields.append(body[:count])
                    body = body[count + 1:]
                assert fields[:4] == [b"1", b"17", b"1", nonce]
                assert int(fields[4]) > rx_sequence
                rx_sequence = int(fields[4])
                events.append(fields[5:])

        def until(predicate, label):
            deadline = time.monotonic() + 10
            while not predicate() and time.monotonic() < deadline:
                receive()
            assert predicate(), (label, events, bytes(output)[-1000:], control.poll())

        def send(*fields):
            nonlocal tx_sequence
            tx_sequence += 1
            control.stdin.write(encode([b"1", b"17", b"1", nonce, str(tx_sequence).encode(), *fields]))
            control.stdin.flush()

        until(lambda: any(e[0] == b"hello" for e in events) and any(e[0] == b"idle" for e in events), "authenticated hello and real ZLE idle")
        report["checks"].append("private hello plus actual ZLE empty-line readiness")

        def run(index, command, handoff=False):
            execution_id = f"{index:032x}".encode()
            fence, epoch = str(index).encode(), str(index).encode()
            start, end = os.urandom(32).hex().encode(), os.urandom(32).hex().encode()
            command_hash = hashlib.sha256(command).hexdigest().encode()
            before = len(events)
            send(b"prepare", execution_id, fence, epoch, start, b"session_interval")
            start_frame = b"\x1b]777;zerowork-exec-v1;" + start + b";start\x07"
            until(lambda: any(e[:2] == [b"ready", execution_id] for e in events[before:]) and start_frame in output, "private ready and same PTY START")
            send(b"buffer", execution_id, fence, epoch, end, command, command_hash)
            until(lambda: any(e[:2] == [b"accepted", execution_id] for e in events[before:]), "exact buffer acceptance")
            accepted = next(e for e in events[before:] if e[:2] == [b"accepted", execution_id])
            assert accepted[4:] == [command_hash, command]
            send(b"submit", execution_id, fence, epoch, command_hash)
            until(lambda: any(e[:2] == [b"submitted", execution_id] for e in events[before:]), "private submit ACK")
            os.write(master, b"\0")  # single protocol wake, never command text
            until(lambda: any(e[:2] == [b"started", execution_id] for e in events[before:]), "real preexec")
            if handoff:
                # Human input after logical handoff; no private input/command
                # is sent, and the original execution observer remains live.
                os.write(master, b"human-value\n")
            end_frame = b"\x1b]777;zerowork-exec-v1;" + end + b";end\x07"
            until(lambda: any(e[:2] == [b"finished", execution_id] for e in events[before:]) and end_frame in output, "real foreground status and same PTY END")
            finish = next(e for e in events[before:] if e[:2] == [b"finished", execution_id])
            assert output.index(start_frame) < output.index(end_frame)
            return finish

        first = run(1, b"printf '\\033]777;zerowork-exec-v1;forged;end\\007'; printf 'BOOTSTRAP_%s\\n' \"$RANDOM\"; (exit 7)")
        assert first[3] == b"7" and first[4] == b"4"
        report["checks"].append("exact private buffer/submit, real exit 7, unverified attribution, forged OSC gives no private completion")
        second = run(2, b"true")
        assert second[3] == b"0"
        report["checks"].append("zero-output command still has distinct same-PTY START/END")
        third = run(3, b"read -r answer; printf 'HANDOFF_%s\\n' \"$answer\"", handoff=True)
        assert third[3] == b"0" and b"HANDOFF_human-value" in output
        report["checks"].append("original command and private observer survive human input handoff")
        os.write(master, b"exit\n")
        until(lambda: control.poll() is not None, "separate control relay cleanup")
        _, status = os.waitpid(child, 0)
        child = None
        assert os.waitstatus_to_exitcode(status) == 0
        assert not any((root / name).exists() for name in ["shell.sock", "control.sock", ".zshrc"])
        report["checks"].append("normal shell exit releases both relay endpoints and exact runtime files")
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = repr(error)
        raise
    finally:
        if control and control.poll() is None:
            control.terminate()
            try:
                control.wait(2)
            except subprocess.TimeoutExpired:
                control.kill()
                control.wait()
        if child:
            try:
                os.kill(child, signal.SIGTERM)
                os.waitpid(child, 0)
            except ProcessLookupError:
                pass
        if master is not None:
            os.close(master)
        shutil.rmtree(root)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
