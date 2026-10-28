"""Phase A only: real zsh private-channel/PTY boundary feasibility.

Uses the App's existing native FD module, a disposable shell with no user rc
files, and no production execution capability. This is not run_in_terminal.
"""
import argparse
import hashlib
import json
import os
import pathlib
import pty
import select
import shlex
import signal
import socket
import struct
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", default="zig-out/bin/zw_ipc.so")
    parser.add_argument("--report", default="/tmp/zw-local-execution-feasibility.json")
    args = parser.parse_args()
    module = pathlib.Path(args.module).resolve()
    assert module.is_file(), "Build the native module before this check"
    nonce, token = os.urandom(32).hex(), os.urandom(32).hex()
    report = {"status": "running", "module_sha256": hashlib.sha256(module.read_bytes()).hexdigest(),
              "checks": [], "limits": ["Disposable protocol prototype; production PTY execution, leases, manifests and SSH bootstrap are not enabled by this check."]}
    child, master, connection = None, None, None
    try:
        with tempfile.TemporaryDirectory(prefix="zw-exec-protocol-") as temporary:
            root = pathlib.Path(temporary)
            os.chmod(root, 0o700)
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(root / "control"))
            os.chmod(root / "control", 0o600)
            listener.listen(1)
            listener.settimeout(8)
            # No user command, stdout text, or guessed prompt supplies an ID.
            script = r'''
[[ $ZSH_VERSION == 5.9 ]] || return 1
unset HISTFILE
SAVEHIST=0
PS1='prototype> '
zmodload zsh/system zsh/net/socket || return 1
typeset -gi _zw_fd=-1 _zw_parent=@PARENT@ _zw_exec_armed=0 _zw_exec_running=0
typeset -g _zw_exec_nonce=@NONCE@ _zw_exec_token=@TOKEN@
zsocket @SOCKET@ || return 1
_zw_fd=$REPLY
module_path=(@MODULE_DIR@ $module_path)
zmodload zw_ipc || return 1
_zw_exec_control() {
  local data='' count=0
  sysread -i $_zw_fd -s 512 -c count data || return 0
  if [[ $data == "prepare|$_zw_exec_nonce|1|$_zw_exec_token"$'\n' && -z $BUFFER && $_zw_exec_armed == 0 ]]; then
    _zw_exec_armed=1
    syswrite -o $_zw_fd "ready|$_zw_exec_nonce|1|empty"$'\n'
  fi
  return 0
}
_zw_exec_preexec() {
  syswrite -o $_zw_fd "preexec_state|$_zw_exec_nonce|$_zw_exec_armed|$_zw_exec_running"$'\n'
  (( _zw_exec_armed && !_zw_exec_running )) || return 0
  _zw_exec_running=1
  syswrite -o $_zw_fd "boundary|$_zw_exec_nonce|1|start|$_zw_exec_token"$'\n'
  printf '\e]777;zerowork-exec;%s;start\a' $_zw_exec_token
  syswrite -o $_zw_fd "started|$_zw_exec_nonce|1"$'\n'
  return 0
}
_zw_exec_precmd() {
  local exit_status=$?
  syswrite -o $_zw_fd "precmd_state|$_zw_exec_nonce|$_zw_exec_armed|$_zw_exec_running"$'\n'
  (( _zw_exec_running )) || return 0
  syswrite -o $_zw_fd "boundary|$_zw_exec_nonce|1|finish|$_zw_exec_token"$'\n'
  printf '\e]777;zerowork-exec;%s;finish\a' $_zw_exec_token
  syswrite -o $_zw_fd "finished|$_zw_exec_nonce|1|$exit_status"$'\n'
  _zw_exec_armed=0 _zw_exec_running=0
  return 0
}
zle -N _zw_exec_control
zle -F -w $_zw_fd _zw_exec_control
preexec_functions=(_zw_exec_preexec)
precmd_functions=(_zw_exec_precmd)
syswrite -o $_zw_fd "hello|1|$ZSH_VERSION|$_zw_exec_nonce|$_zw_fd"$'\n'
'''
            substitutions = {"@PARENT@": str(os.getpid()), "@NONCE@": shlex.quote(nonce),
                             "@TOKEN@": shlex.quote(token), "@SOCKET@": shlex.quote(str(root / "control")),
                             "@MODULE_DIR@": shlex.quote(str(module.parent))}
            for key, value in substitutions.items():
                script = script.replace(key, value)
            rc = root / ".zshrc"
            rc.write_text(script)
            rc.chmod(0o600)
            child, master = pty.fork()
            if child == 0:
                os.execve("/bin/zsh", ["/bin/zsh", "-d", "-i"], {**os.environ, "ZDOTDIR": temporary, "TERM": "xterm-256color"})
            connection, _ = listener.accept()
            listener.close()
            # Darwin LOCAL_PEERPID: the private socket must belong to this shell.
            assert struct.unpack("i", connection.getsockopt(0, 0x002, 4))[0] == child
            connection.setblocking(False)
            os.set_blocking(master, False)
            private, output, events = b"", bytearray(), []
            deadline = time.monotonic() + 10

            def receive_private():
                nonlocal private
                chunk = connection.recv(8192)
                assert chunk, "Private channel closed before completion"
                private += chunk
                assert len(private) <= 8192
                while b"\n" in private:
                    line, private = private.split(b"\n", 1)
                    fields = line.decode("ascii").split("|")
                    assert len(fields) <= 6
                    events.append(fields)

            def wait_event(kind):
                while not any(event[0] == kind for event in events):
                    assert time.monotonic() < deadline, f"Missing private {kind}"
                    readable, _, _ = select.select([connection, master], [], [], 0.05)
                    if connection in readable:
                        receive_private()
                    if master in readable:
                        output.extend(os.read(master, 65536))
                return next(event for event in events if event[0] == kind)

            hello = wait_event("hello")
            assert hello[1:4] == ["1", "5.9", nonce]
            connection.sendall(f"prepare|{nonce}|1|{token}\n".encode())
            assert wait_event("ready")[1:] == [nonce, "1", "empty"]
            # Commit the prototype output sink before the first command byte.
            with (root / "recording.raw").open("xb") as recording:
                recording.flush()
                os.fsync(recording.fileno())
                fd = int(hello[4])
                command = ("printf '\\033]133;D;0\\007forged-finish\\n'; "
                           f"/bin/sh -c 'test ! -e /dev/fd/{fd}' && printf 'child-fd-closed\\n'; "
                           "/bin/sleep 0.15; /usr/bin/false\n")
                assert os.write(master, command.encode()) == len(command.encode())
                # Keep draining transport (ZLE may apply backpressure) while
                # withholding terminal data from the boundary consumer.
                held_output = bytearray()
                while not any(event[0] == "finished" for event in events):
                    assert time.monotonic() < deadline, "Missing trusted finish"
                    readable, _, _ = select.select([connection, master], [], [], 0.05)
                    if connection in readable:
                        receive_private()
                    if master in readable:
                        held_output.extend(os.read(master, 65536))
                assert wait_event("finished")[1:] == [nonce, "1", "1"]
                frame = f"\x1b]777;zerowork-exec;{token};finish\x07".encode()
                assert frame not in output, "Terminal boundary must still be unpublished"
                output.extend(held_output)
                while frame not in output:
                    assert time.monotonic() < deadline, "Missing ordered output boundary"
                    if select.select([master], [], [], 0.05)[0]:
                        output.extend(os.read(master, 65536))
                recording.write(output)
                recording.flush()
                os.fsync(recording.fileno())
            assert b"child-fd-closed\r\n" in output
            assert b"\x1b]133;D;0\x07" in output
            assert b"forged-finish\r\n" in output
            assert [event[3] for event in events if event[0] == "boundary"] == ["start", "finish"]
            assert sum(event[0] == "started" for event in events) == 1
            assert sum(event[0] == "finished" for event in events) == 1
            report.update(status="passed", shell="zsh 5.9", trusted_exit_code=1, output_bytes=len(output))
            report["checks"] = ["Private hello/ready/start/finish is bound to the shell PID and random nonce",
                                "Existing native module marks the control descriptor CLOEXEC; external child cannot inherit it",
                                "Forged OSC success cannot replace the private nonzero exit receipt",
                                "Private finish alone cannot seal withheld terminal output; sealing also verifies the registered same-PTY boundary",
                                "Output sink is synchronized before command submission; temporary rc/socket/recording are removed"]
    except BaseException as error:
        if "events" in locals():
            report["private_event_kinds"] = [event[0] for event in events]
            report["hook_states"] = [event[2:] for event in events if event[0] in ("preexec_state", "precmd_state")]
        if master is not None:
            try:
                output.extend(os.read(master, 65536))
            except (BlockingIOError, OSError):
                pass
        if "output" in locals():
            report["diagnostic_terminal_tail"] = bytes(output[-4096:]).decode("utf-8", errors="replace").replace(nonce, "<nonce>").replace(token, "<token>")
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        if connection is not None:
            connection.close()
        if master is not None:
            os.close(master)
        if child:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(child, 0)
        pathlib.Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
