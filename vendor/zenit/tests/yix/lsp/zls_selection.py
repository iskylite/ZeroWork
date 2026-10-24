#!/usr/bin/env python3
"""Real subprocess regressions for CLI/env/sibling/PATH ZLS precedence."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    binary = root / pathlib.Path(sys.argv[1]).name
    shutil.copy2(sys.argv[1], binary)
    marker = root / "selected"

    def stub(name):
        file = root / name
        file.write_text("#!" + sys.executable + "\n"
                        "import pathlib,sys\n"
                        f"pathlib.Path({str(marker)!r}).write_text({name!r})\n"
                        "sys.stdin.buffer.read()\n")
        file.chmod(0o755)
        return str(file)

    sibling = stub("zenit-zls")
    override = stub("explicit-zls")
    fallback = stub("zls")
    env = dict(os.environ, PATH=str(root))
    env.pop("YIX_ZLS", None)
    env.pop("YIX_LSP_DEBUG", None)

    def check(label, args, environment, expected):
        marker.unlink(missing_ok=True)
        result = subprocess.run([str(binary), *args], input=b"", env=environment,
                                cwd=directory, capture_output=True, timeout=10)
        assert result.returncode == 0, (label, result.returncode, result.stderr)
        assert marker.read_text() == expected, (label, marker.read_text())
        assert b"leaked" not in result.stderr, result.stderr
        print("PASS " + label)

    check("installed sibling beats PATH", [], env, "zenit-zls")
    check("YIX_ZLS beats sibling", [], dict(env, YIX_ZLS=override), "explicit-zls")
    check("--zls beats YIX_ZLS", ["--zls", sibling], dict(env, YIX_ZLS=override), "zenit-zls")
    pathlib.Path(sibling).unlink()
    check("PATH fallback without sibling", [], env, "zls")
