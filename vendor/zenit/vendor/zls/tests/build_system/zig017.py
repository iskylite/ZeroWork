#!/usr/bin/env python3
"""Real Zig 0.17 build protocol regressions; requires ZLS and Zig executables."""
import argparse
import json
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time


class Client:
    def __init__(self, binary, config, root):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [str(binary), "--config-path", str(config), "--enable-stderr-logs"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            cwd=root,
        )
        self.inbox = queue.Queue()
        self.next_id = 0
        self.diagnostics = {}
        threading.Thread(target=self.read, daemon=True).start()
        self.request("initialize", {"rootUri": root.as_uri(), "capabilities": {}})
        self.notify("initialized", {})

    def read(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.process.stdout.readline()
                    if not line:
                        self.inbox.put(None)
                        return
                    if line in (b"\r\n", b"\n"):
                        break
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                remaining = int(headers["content-length"])
                body = bytearray()
                while len(body) < remaining:
                    chunk = self.process.stdout.read(remaining - len(body))
                    if not chunk:
                        raise EOFError("partial LSP message")
                    body.extend(chunk)
                self.inbox.put(json.loads(body))
        except Exception as error:
            self.inbox.put(error)

    def send(self, message):
        body = json.dumps(message).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                message = self.inbox.get(timeout=0.2)
            except queue.Empty:
                continue
            if message is None or isinstance(message, Exception):
                raise RuntimeError("ZLS disconnected before answering %s: %r" % (method, message))
            if message.get("method") == "textDocument/publishDiagnostics":
                params = message["params"]
                self.diagnostics[params["uri"]] = params["diagnostics"]
            elif message.get("method") and "id" in message:
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": None})
            elif message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result")
        raise TimeoutError(method)

    def open(self, path, text):
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": path.as_uri(), "languageId": "zig", "version": 1, "text": text,
        }})

    def hover(self, path, text, expression, expected):
        offset = text.index(expression) + len(expression) - 1
        position = {"line": text[:offset].count("\n"),
                    "character": offset - text.rfind("\n", 0, offset) - 1}
        deadline = time.monotonic() + 45
        last = None
        while time.monotonic() < deadline:
            last = self.request("textDocument/hover", {
                "textDocument": {"uri": path.as_uri()}, "position": position,
            })
            if last and expected in json.dumps(last):
                print("PASS", expression, "contains", expected, flush=True)
                return
            time.sleep(0.2)
        raise AssertionError("%s never resolved to %r; last hover: %r" % (expression, expected, last))

    def close(self, successful):
        try:
            if successful:
                self.request("shutdown", None)
                self.notify("exit", None)
                code = self.process.wait(timeout=10)
                if code != 0:
                    raise AssertionError("ZLS exit code %d" % code)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
            self.errors.seek(0)
            errors = self.errors.read().decode(errors="replace")
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass  # Preserve the server's crash diagnostics below.
            self.process.stdout.close()
            self.errors.close()
            if not successful:
                print(errors, file=sys.stderr)
            if " leaked" in errors or "reached unreachable" in errors:
                raise AssertionError(errors)


BUILD = r'''const std = @import("std");
pub fn build(b: *std.Build) void {
    const module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = b.graph.host });
    module.addImport("dep", b.createModule(.{ .root_source_file = b.path("dep.zig") }));
    const opts = b.addOptions();
    opts.addOption(u32, "value", 73);
    module.addOptions("generated_config", opts);
    const translation = b.addTranslateC(.{ .root_source_file = b.path("header.h"), .target = b.graph.host, .optimize = .debug });
    module.addImport("translated_c", translation.createModule());
    const run = b.addSystemCommand(&.{ __PYTHON__, "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('pub const provided: u32 = 88;\\n')" });
    module.addAnonymousImport("provider", .{ .root_source_file = run.addOutputFileArg("provided.zig") });
    const files = b.addWriteFiles();
    module.addAnonymousImport("written", .{ .root_source_file = files.add("written.zig", "pub const written: u32 = 64;\n") });
    const exe = b.addExecutable(.{ .name = "fixture", .root_module = module });
    b.installArtifact(exe);
    for (0..48) |i| b.step(b.fmt("probe{d}", .{i}), "alternate build entry").dependOn(&exe.step);
}
'''
TEXT = '''const dep = @import("dep");
const gen = @import("generated_config");
const c = @import("translated_c");
const provider = @import("provider");
const written = @import("written");
pub fn main() void {
    _ = dep.answer;
    _ = gen.value;
    _ = c.HEADER_VALUE;
    _ = provider.provided;
    _ = written.written;
}
'''



def verify_diagnostic_recovery(binary, config, root):
    text = 'const dep = @import("dep");\npub fn main() void { _ = dep.answer; }\n'
    good = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const m = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = b.graph.host });
    m.addImport("dep", b.createModule(.{ .root_source_file = b.path("dep.zig") }));
    b.installArtifact(b.addExecutable(.{ .name = "fixture", .root_module = m }));
}
'''
    bad = good.replace('pub fn build(b: *std.Build) void {',
                       'pub fn build(b: *std.Build) void { @compileError("BSP_NEGATIVE_REGRESSION");')
    build = root / "build.zig"
    build.write_text(bad, encoding="utf8")
    (root / "main.zig").write_text(text, encoding="utf8")
    client = Client(binary, config, root)
    successful = False
    try:
        client.open(build, bad)
        client.open(root / "main.zig", text)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            client.request("textDocument/hover", {"textDocument": {"uri": build.as_uri()},
                                                "position": {"line": 0, "character": 6}})
            if "BSP_NEGATIVE_REGRESSION" in json.dumps(client.diagnostics):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("BSP did not publish the real build error")
        build.write_text(good, encoding="utf8")
        client.notify("textDocument/didChange", {"textDocument": {"uri": build.as_uri(), "version": 2},
                                                "contentChanges": [{"text": good}]})
        client.notify("textDocument/didSave", {"textDocument": {"uri": build.as_uri()}})
        client.hover(root / "main.zig", text, "dep.answer", "42")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            client.request("textDocument/hover", {"textDocument": {"uri": build.as_uri()},
                                                "position": {"line": 0, "character": 6}})
            if build.as_uri() in client.diagnostics and not client.diagnostics[build.as_uri()]:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("BSP retained old diagnostics: %r" % client.diagnostics)
        successful = True
        print("PASS failed build recovers and clears old diagnostics")
    finally:
        client.close(successful)


def init_package(zig, root, dependencies):
    subprocess.run([str(zig), "init"], cwd=root, check=True, capture_output=True)
    manifest = (root / "build.zig.zon").read_text(encoding="utf8")
    name = re.search(r"\.name = ([^,]+),", manifest).group(1)
    fingerprint = re.search(r"\.fingerprint = ([^,]+),", manifest).group(1)
    (root / "build.zig.zon").write_text(
        '.{ .name = %s, .fingerprint = %s, .version = "0.0.0", '
        '.minimum_zig_version = "0.17.0", .dependencies = .{%s}, '
        '.paths = .{"build.zig", "build.zig.zon", "src"} }' % (name, fingerprint, dependencies),
        encoding="utf8")


def verify_package_import(binary, zig, config, root):
    package = root / "pkg"
    package.mkdir()
    init_package(zig, root, '.pkg = .{ .path = "pkg" },')
    init_package(zig, package, "")
    (package / "src/root.zig").write_text("pub const package_answer: u32 = 123;\n", encoding="utf8")
    (package / "build.zig").write_text('''const std = @import("std");
pub fn marker() u32 { return 17; }
pub fn build(b: *std.Build) void {
    _ = b.addModule("pkg", .{ .root_source_file = b.path("src/root.zig") });
}
''', encoding="utf8")
    build_text = '''const std = @import("std");
const package_build = @import("pkg");
pub fn build(b: *std.Build) void {
    _ = package_build.marker();
    const dependency = b.dependency("pkg", .{});
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host });
    module.addImport("pkg", dependency.module("pkg"));
    b.installArtifact(b.addExecutable(.{ .name = "fixture", .root_module = module }));
}
'''
    text = 'const pkg = @import("pkg");\npub fn main() void { _ = pkg.package_answer; }\n'
    (root / "build.zig").write_text(build_text, encoding="utf8")
    (root / "src/main.zig").write_text(text, encoding="utf8")
    client = Client(binary, config, root)
    successful = False
    try:
        client.open(root / "src/main.zig", text)
        client.open(root / "build.zig", build_text)
        client.hover(root / "src/main.zig", text, "pkg.package_answer", "123")
        client.hover(root / "build.zig", build_text, "package_build.marker", "fn marker")
        successful = True
        print("PASS dependency module and build script imports")
    finally:
        client.close(successful)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zls", type=Path)
    parser.add_argument("zig", type=Path)
    args = parser.parse_args()
    binary, zig = args.zls.resolve(), args.zig.resolve()
    version = subprocess.check_output([str(zig), "version"], text=True).strip()
    assert version == "0.17.0", version
    # Zig 0.17 prints env as ZON. Its quoted path string also uses JSON escapes.
    env = subprocess.check_output([str(zig), "env"], text=True)
    lib_dir = json.loads(re.search(r'\.lib_dir = ("(?:[^"\\]|\\.)*")', env).group(1))
    with tempfile.TemporaryDirectory(prefix="zls-zig017-") as directory:
        root = Path(directory).resolve()
        config = root / "zls.json"
        config.write_text(json.dumps({"zig_exe_path": str(zig),
                                     "zig_lib_path": lib_dir,
                                     "global_cache_path": str(root / "zls-cache")}), encoding="utf8")
        (root / "build.zig").write_text(BUILD.replace("__PYTHON__", json.dumps(sys.executable)), encoding="utf8")
        (root / "main.zig").write_text(TEXT, encoding="utf8")
        (root / "dep.zig").write_text("pub const answer: u32 = 42;\n", encoding="utf8")
        (root / "header.h").write_text("#define HEADER_VALUE 91\n", encoding="utf8")
        client = Client(binary, config, root)
        successful = False
        try:
            client.open(root / "main.zig", TEXT)
            for expression, value in [("dep.answer", "42"), ("gen.value", "73"),
                                      ("c.HEADER_VALUE", "91"), ("provider.provided", "88"),
                                      ("written.written", "64")]:
                client.hover(root / "main.zig", TEXT, expression, value)
            successful = True
        finally:
            client.close(successful)
        print("PASS Zig 0.17 build graph, 48 alternate steps and generated modules")
        verify_diagnostic_recovery(binary, config, root)
        verify_package_import(binary, zig, config, root)


if __name__ == "__main__":
    main()
