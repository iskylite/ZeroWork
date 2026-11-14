#!/usr/bin/env python3
"""Exercise PTY permission decisions against a real Bash 4.3+ session."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from ssh_shell_integration import ROOT, Shell


def main(bash):
    version = subprocess.check_output(
        [bash, "--version"], env=dict(os.environ, LC_ALL="C"), text=True,
    ).splitlines()[0]
    match = re.match(r"GNU bash, version (\d+)\.(\d+)", version)
    if match is None or tuple(map(int, match.groups())) < (4, 3):
        raise SystemExit(f"Bash 4.3 or newer required, got {version}")
    policy_source = ROOT / "src/ai/permission.zig"
    with tempfile.TemporaryDirectory(prefix="zw-bash-session-policy-") as directory:
        source = Path(directory) / "policy.zig"
        binary = Path(directory) / "policy"
        source.write_text("""
const std = @import("std");
const permission = @import("permission");
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse return error.MissingCommand;
    const verdict = permission.classifyTerminal(.{ .mode = .auto }, command, false);
    try std.Io.File.stdout().writeStreamingAll(init.io, @tagName(verdict));
}
""")
        subprocess.run(
            ["zig", "build-exe", "--dep", "permission", f"-Mroot={source}",
             f"-Mpermission={policy_source}", f"-femit-bin={binary}"],
            cwd=directory, check=True,
        )

        shell = Shell(bash)
        try:
            shell.install()
            shell.command(b"items=(initial); declare -n value='items[0]'; declare -i count=6")
            shell.command(b"value=manual")
            assert b"<manual:6>\r\n" in shell.command(b"printf '<%s:%s>\\n' \"${items[0]}\" \"$count\"")

            cases = (
                ("value=auto", "need_confirm", None),
                ("value+=suffix", "need_confirm", None),
                ("printf '%s' \"$value\"", "need_confirm", None),
                ("printf -v value '%s' auto", "need_confirm", None),
                ("count=3+4", "need_confirm", None),
                ("eval 'value=auto'", "need_confirm", None),
                ("printf '%s' \"$(value=auto)\"", "need_confirm", None),
                ("printf '%s' safe; shutdown now", "deny_exec_copy_only", None),
                ("printf '%s\\n' alpha beta | grep '^beta$'", "allow_auto", b"beta"),
                ("printf '%s\\n' 'value=literal'", "allow_auto", b"value=literal"),
                ("printf '%s\\n' \"$(printf nested)\"", "allow_auto", b"nested"),
                (f"{shlex.quote(bash)} --noprofile --norc -p -c 'value=child; printf \"%s\\n\" \"$value\"'",
                 "allow_auto", b"child"),
            )
            for command, expected, output in cases:
                verdict = subprocess.check_output([str(binary), command], text=True)
                assert verdict == expected, (command, expected, verdict)
                if verdict == "allow_auto":
                    observed = shell.command(command.encode())
                    assert b"\x07" + output + b"\r\n" in observed, (command, observed)

            assert b"<manual:6>\r\n" in shell.command(b"printf '<%s:%s>\\n' \"${items[0]}\" \"$count\"")
        finally:
            shell.close()
    print(f"{version}: {len(cases)} PTY permission cases passed")


if __name__ == "__main__":
    if len(sys.argv) != 2 or (bash := shutil.which(sys.argv[1])) is None:
        raise SystemExit(f"usage: {sys.argv[0]} /path/to/bash-4.3-or-newer")
    main(os.path.abspath(bash))
