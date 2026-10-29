#!/usr/bin/env python3
"""Build versioned, hash-manifested BootstrapV1 resources; deploys nothing.

Linux artifacts are cross-built candidates. A compiled artifact is never a
runtime compatibility receipt; the host still requires an actual probe and
private hello/idle/barrier before enabling trusted execution.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

PAYLOAD_MAGIC = b"ZWBOOTSTRAP1\n"
NAMES = ("bootstrap", "zw_execution.so", "execution.zsh")

def verify(output: pathlib.Path, platform: str | None = None) -> None:
    expected = {platform} if platform else {"darwin-aarch64", "linux-x86_64", "linux-aarch64"}
    if {p.name for p in output.iterdir() if p.is_dir()} != expected:
        raise SystemExit("BootstrapV1 platform resource set is incomplete")
    for directory in sorted(output.iterdir()):
        if not directory.is_dir():
            continue
        manifest = json.loads((directory / "manifest.json").read_bytes())
        if manifest.get("payload_format") != "ZWBOOTSTRAP1" or len(manifest["files"]) != 3:
            raise SystemExit("Unsupported BootstrapV1 payload format")
        for name, entry in zip(NAMES, manifest["files"]):
            if entry["name"] != name:
                raise SystemExit("Invalid BootstrapV1 payload name")
            encoded = (directory / (name + ".payload")).read_bytes()
            if not encoded.startswith(PAYLOAD_MAGIC):
                raise SystemExit("Invalid BootstrapV1 payload header")
            data = encoded[len(PAYLOAD_MAGIC):]
            if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise SystemExit("BootstrapV1 resource checksum mismatch")
            if (directory / name).exists():
                raise SystemExit("Unwrapped native resource must not enter the App bundle")


def build(output: pathlib.Path, only: str | None = None) -> None:
    root = pathlib.Path(__file__).resolve().parent.parent
    source = root / "src/proto/ssh/bootstrap/v1"
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("zig is required for the pinned remote resource toolchain")
    version = subprocess.check_output([zig, "version"], text=True).strip()
    if version != "0.17.0":
        raise SystemExit(f"BootstrapV1 requires repository Zig 0.17.0, got {version}")
    targets = {
        "darwin-aarch64": ("arm64-apple-macos14.0", None),
        "linux-x86_64": ("x86_64-linux-musl", "x86_64-linux-gnu.2.28"),
        "linux-aarch64": ("aarch64-linux-musl", "aarch64-linux-gnu.2.28"),
    }
    if only:
        targets = {only: targets[only]}
    output.mkdir(parents=True, exist_ok=True)
    for name, (executable_target, module_target) in targets.items():
        destination = output / name
        destination.mkdir(parents=True, exist_ok=True)
        common = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2"]
        if module_target is None:
            compiler = ["xcrun", "clang", "-target", executable_target]
            subprocess.run([*compiler, *common, str(source / "launcher.c"), "-o", str(destination / "bootstrap")], check=True)
            subprocess.run([*compiler, *common, "-bundle", "-undefined", "dynamic_lookup", str(source / "zw_ssh_execution.c"), "-o", str(destination / "zw_execution.so")], check=True)
        else:
            subprocess.run([zig, "cc", "-target", executable_target, *common, "-static", str(source / "launcher.c"), "-o", str(destination / "bootstrap")], check=True)
            subprocess.run([zig, "cc", "-target", module_target, *common, "-shared", "-fPIC", str(source / "zw_ssh_execution.c"), "-o", str(destination / "zw_execution.so")], check=True)
        shutil.copyfile(source / "execution.zsh", destination / "execution.zsh")
        manifest = {
            "schema": 1,
            "payload_format": "ZWBOOTSTRAP1",
            "protocol": "TerminalExecutionProtocolV1",
            "bootstrap": "BootstrapV1",
            "resource_version": 1,
            "platform": name,
            "shell": "zsh",
            "shell_version": "5.9",
            "capability": "ssh_cloexec_boundary_interval_v1",
            "output_scope": "session_interval",
            "toolchain": {"zig": version},
            "files": [],
        }
        for filename, mode in [("bootstrap", 0o700), ("zw_execution.so", 0o600), ("execution.zsh", 0o600)]:
            path = destination / filename
            path.chmod(mode)
            data = path.read_bytes()
            manifest["files"].append({"name": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "mode": mode})
            # A data envelope prevents macOS codesign --deep from rewriting a
            # remote Mach-O payload and invalidating its deployment checksum.
            encoded = destination / (filename + ".payload")
            encoded.write_bytes(PAYLOAD_MAGIC + data)
            encoded.chmod(0o644)
            path.unlink()
        path = destination / "manifest.json"
        path.write_text(json.dumps(manifest, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n")
        path.chmod(0o644)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--platform", choices=["darwin-aarch64", "linux-x86_64", "linux-aarch64"])
    arguments = parser.parse_args()
    if not arguments.verify_only:
        build(arguments.output, arguments.platform)
    verify(arguments.output, arguments.platform)
