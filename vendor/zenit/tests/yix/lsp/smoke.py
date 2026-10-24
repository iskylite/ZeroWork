#!/usr/bin/env python3
"""yix-lsp 端到端冒烟：真实 ZLS + 脚本化 LSP 客户端，验证悬停 / 跳转 / 补全 / 诊断的位置往返。

用法：python3 tests/yix/lsp/smoke.py [yix-lsp 路径][ZLS 路径]（默认使用仓库内的 zenit-zls）
"""
import json, os, subprocess, sys, threading, queue, time, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
LSP = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "zig-out/bin/yix-lsp")
DOC = ROOT / "src/ui/components/badge/badge.yix"
URI = DOC.as_uri()

def find_zls():
    if len(sys.argv) > 2:
        return sys.argv[2]
    if os.environ.get("YIX_ZLS"):
        return os.environ["YIX_ZLS"]
    local = ROOT / "zig-out/bin" / ("zenit-zls.exe" if os.name == "nt" else "zenit-zls")
    if local.is_file():
        return str(local)
    import shutil
    if shutil.which("zls"):
        return shutil.which("zls")
    # Same order as VS Code extension: last find ZLS downloaded by Zig extension
    for base in [pathlib.Path.home() / "Library/Application Support/Code/User/globalStorage/ziglang.vscode-zig/zls",
                 pathlib.Path.home() / ".config/Code/User/globalStorage/ziglang.vscode-zig/zls"]:
        if base.exists():
            for d in sorted(base.iterdir(), reverse=True):
                if (d / "zls").exists():
                    return str(d / "zls")
    return None

zls = find_zls()
if not zls:
    print("FAIL ZLS not found (set YIX_ZLS or put zls on PATH)")
    sys.exit(1)
env = dict(os.environ, YIX_ZLS=zls)
proc = subprocess.Popen([LSP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=ROOT, env=env)
inbox = queue.Queue()

def reader():
    f = proc.stdout
    while True:
        headers = b""
        while not headers.endswith(b"\r\n\r\n"):
            c = f.read(1)
            if not c:
                return
            headers += c
        n = int([h for h in headers.decode().split("\r\n") if h.lower().startswith("content-length")][0].split(":")[1])
        inbox.put(json.loads(f.read(n)))

threading.Thread(target=reader, daemon=True).start()
next_id = 0

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()

diagnostics = {}

def wait(pred, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        try:
            m = inbox.get(timeout=0.2)
        except queue.Empty:
            continue
        if m.get("method") == "textDocument/publishDiagnostics":
            diagnostics[m["params"]["uri"]] = m["params"]["diagnostics"]
        if pred(m):
            return m
    raise TimeoutError("no matching message")

def request(method, params):
    global next_id
    next_id += 1
    rid = next_id
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    return wait(lambda m: m.get("id") == rid).get("result")

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def pos_of(text, needle, delta=0, nth=0):
    at = -1
    for _ in range(nth + 1):
        at = text.index(needle, at + 1)
    at += delta
    line = text.count("\n", 0, at)
    col = len(text[text.rfind("\n", 0, at) + 1 : at].encode("utf-16-le")) // 2
    return {"line": line, "character": col}

failures = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  -- {detail}"))
    if not ok:
        failures.append(name)

# On save build: replace zig build with a command that echoes pre-written 'Zig error' to stderr
# (don't actually run a build in smoke test)
import tempfile
BUILD_ERRS = pathlib.Path(tempfile.mkdtemp()) / "build.err"
BUILD_ERRS.write_text("")
init = request("initialize", {"processId": os.getpid(), "rootUri": ROOT.as_uri(), "initializationOptions": {"buildOnSave": ["sh", "-c", f"cat '{BUILD_ERRS}' >&2"]}, "capabilities": {"textDocument": {"publishDiagnostics": {}, "hover": {"contentFormat": ["markdown", "plaintext"]}, "completion": {"completionItem": {"snippetSupport": False}}}}})
caps = init["capabilities"]
check("initialize advertises proxied capabilities", caps.get("hoverProvider") and "completionProvider" in caps and caps.get("textDocumentSync", {}).get("change") == 1 and caps["textDocumentSync"].get("save") is not None, json.dumps(caps)[:200])
notify("initialized", {})

text = DOC.read_text()
notify("textDocument/didOpen", {"textDocument": {"uri": URI, "languageId": "yix", "version": 1, "text": text}})
time.sleep(2.0)

# Hover: labelOf inside computed(labelOf(...))
hover = None
for _ in range(10):
    hover = request("textDocument/hover", {"textDocument": {"uri": URI}, "position": pos_of(text, "labelOf(label, count", 2)})
    if hover:
        break
    time.sleep(1)
hv = json.dumps(hover) if hover else ""
check("hover on labelOf shows its signature", "labelOf" in hv and "Label" in hv, hv[:200])

# Jump: fall back to definition line of fn labelOf in badge.yix
defn = request("textDocument/definition", {"textDocument": {"uri": URI}, "position": pos_of(text, "labelOf(label, count", 2)})
locs = defn if isinstance(defn, list) else ([defn] if defn else [])
want_line = pos_of(text, "fn labelOf")["line"]
got = [(l.get("uri") or l.get("targetUri"), (l.get("range") or l.get("targetSelectionRange"))["start"]["line"]) for l in locs]
check("definition of labelOf maps back to the .yix definition line", any(u == URI and ln == want_line for u, ln in got), str(got))

# Jump to another real file (URI preserved): mod.BadgeStatus in file-level Zig -> enum in mod.zig
defn2 = request("textDocument/definition", {"textDocument": {"uri": URI}, "position": pos_of(text, "mod.BadgeStatus", 5)})
locs2 = defn2 if isinstance(defn2, list) else ([defn2] if defn2 else [])
check("definition of mod.BadgeStatus points into badge/mod.zig", any((l.get("uri") or l.get("targetUri", "")).endswith("badge/mod.zig") for l in locs2), json.dumps(defn2)[:200])

# Completion: after S.
comp = request("textDocument/completion", {"textDocument": {"uri": URI}, "position": pos_of(text, "S.Badge.slot", 2)})
items = comp.get("items", comp) if isinstance(comp, dict) else (comp or [])
labels = {i["label"] for i in items}
check("completion after S. lists style exports", {"Badge", "StatusDot"} <= labels, str(sorted(labels))[:200])

# In progress: typing property value halfway (closing brace not yet typed), content after cursor
# still exists -- .yix doesn't compile, but tolerance-patching at cursor continues completion
typing = text.replace("style={S.Badge.slot(.label, .{ .status = status, .size = size })}", "style={S.", 1)
notify("textDocument/didChange", {"textDocument": {"uri": URI, "version": 10}, "contentChanges": [{"text": typing}]})
comp2 = request("textDocument/completion", {"textDocument": {"uri": URI}, "position": pos_of(typing, "style={S.", len("style={S."))})
items2 = comp2.get("items", comp2) if isinstance(comp2, dict) else (comp2 or [])
check("completion works while the attribute is still being typed", {"Badge", "StatusDot"} <= {i["label"] for i in items2}, str(sorted(i["label"] for i in items2))[:200])

# In progress: typing interpolation halfway (closing brace not yet typed)
typing2 = text.replace(">{label}</text>", ">{lab</text>", 1)
notify("textDocument/didChange", {"textDocument": {"uri": URI, "version": 11}, "contentChanges": [{"text": typing2}]})
comp3 = request("textDocument/completion", {"textDocument": {"uri": URI}, "position": pos_of(typing2, ">{lab", len(">{lab"))})
items3 = comp3.get("items", comp3) if isinstance(comp3, dict) else (comp3 or [])
check("completion offers component locals inside a half-typed interpolation", "label" in {i["label"] for i in items3}, str(sorted(i["label"] for i in items3))[:200])

# Syntax error in Zig fragment: diagnostic mapped back to that line in .yix
bad = text.replace("if (dot) return .{};", "if (dot) return .{}", 1)
notify("textDocument/didChange", {"textDocument": {"uri": URI, "version": 2}, "contentChanges": [{"text": bad}]})
want = pos_of(bad, "if (dot) return .{}")["line"]
try:
    wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and any(d.get("source") == "zig" for d in m["params"]["diagnostics"]), 20)
except TimeoutError:
    pass
zig_diags = [d for d in diagnostics.get(URI, []) if d.get("source") == "zig"]
lines = [d["range"]["start"]["line"] for d in zig_diags]
check("zig syntax error is reported on the .yix line", any(abs(l - want) <= 1 for l in lines), f"want {want}, got {lines}")

# Yix own syntax error: yix diagnostic
bad2 = text.replace("</text>", "</txt>", 1)
notify("textDocument/didChange", {"textDocument": {"uri": URI, "version": 3}, "contentChanges": [{"text": bad2}]})
wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and any(d.get("source") == "yix" for d in m["params"]["diagnostics"]), 10)
yd = [d for d in diagnostics[URI] if d.get("source") == "yix"]
check("yix syntax error is reported", bool(yd) and "closing tag" in yd[0]["message"], str(yd))

# ---- Completion at template location (fixtures: builtin W.Button + Yix component Card2 in this
# file) ----
FIX = ROOT / "tests/yix/lsp/fixture.yix"
FURI = FIX.as_uri()
ftext = FIX.read_text()
notify("textDocument/didOpen", {"textDocument": {"uri": FURI, "languageId": "yix", "version": 1, "text": ftext}})
time.sleep(1.0)

def labels_at(t, needle, delta):
    r = request("textDocument/completion", {"textDocument": {"uri": FURI}, "position": pos_of(t, needle, delta)})
    items = r.get("items", r) if isinstance(r, dict) else (r or [])
    return {i["label"] for i in items}

def edit(t, version):
    notify("textDocument/didChange", {"textDocument": {"uri": FURI, "version": version}, "contentChanges": [{"text": t}]})

t1 = ftext.replace('<W.Button label="Save" />', '<W.Button label="Save" v />', 1)
edit(t1, 2)
got = labels_at(t1, 'label="Save" v', len('label="Save" v'))
check("attribute completion lists props of a built-in component (camelCase, minus ones already written)", {"variant", "onClick", "disabled"} <= got and "label" not in got, str(sorted(got))[:200])

t2 = ftext.replace('<Card2 title="a" />', '<Card2 title="a" c />', 1)
edit(t2, 3)
got = labels_at(t2, 'title="a" c', len('title="a" c'))
check("attribute completion lists params of a Yix component", {"count", "onPick"} <= got and "title" not in got, str(sorted(got))[:200])

t3 = ftext.replace("<row />", "<row f />", 1)
edit(t3, 4)
got = labels_at(t3, "<row f", len("<row f"))
check("host element attribute completion", {"style", "focusRing", "onClick"} <= got, str(sorted(got))[:200])

t4 = ftext.replace("<row />", "<C", 1)
edit(t4, 5)
got = labels_at(t4, "<C", 2)
check("tag name completion offers host tags and file components", {"box", "text", "Card2", "Demo"} <= got, str(sorted(got))[:200])

# ---- .yss style recipe: diagnostics from style compiler (report on open, clear on fix) ----
YSS = ROOT / "src/ui/components/card/styles.yss"
YURI = YSS.as_uri()
ytext = YSS.read_text() + "\npub fn smokeSize() ui.BoxStyle { return .{}; }\n"
ybad = ytext.replace("flag hoverable;", "flag hoverable;\n  when nosuch { }", 1)
notify("textDocument/didOpen", {"textDocument": {"uri": YURI, "languageId": "yss", "version": 1, "text": ybad}})
wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == YURI and m["params"]["diagnostics"], 10)
yd = diagnostics.get(YURI, [])
want_line = ybad.splitlines().index("  when nosuch { }")
check(".yss diagnostic points at the bad `when`", bool(yd) and "not a declared variant or flag" in yd[0]["message"] and yd[0]["range"]["start"]["line"] == want_line, str(yd)[:200])
notify("textDocument/didChange", {"textDocument": {"uri": YURI, "version": 2}, "contentChanges": [{"text": ytext}]})
wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == YURI and not m["params"]["diagnostics"], 10)
check(".yss diagnostics clear once fixed", not diagnostics.get(YURI), str(diagnostics.get(YURI))[:200])

# ---- .yss DSL smarts: completion / hover / jump / outline (agent answers per schema and outline),
# handoff Zig to ZLS ----
def ylabels(t, needle, delta, uri=YURI):
    r = request("textDocument/completion", {"textDocument": {"uri": uri}, "position": pos_of(t, needle, delta)})
    items = r if isinstance(r, list) else (r or {}).get("items", [])
    return {i["label"] for i in items}

def yhover(t, needle, delta, uri=YURI):
    h = request("textDocument/hover", {"textDocument": {"uri": uri}, "position": pos_of(t, needle, delta)})
    if not h:
        return ""
    c = h["contents"]
    return c["value"] if isinstance(c, dict) else json.dumps(c)

got = ylabels(ytext, "corner-radius: 6", len("corner-r"))
check(".yss property completion lists style properties", {"corner-radius", "direction", "background", "transition"} <= got and "bg-primary" not in got, str(sorted(got))[:200])
got = ylabels(ytext, "background: bg-primary", len("background: bg-"))
check(".yss color value completion lists color tokens", {"bg-primary", "bg-hover", "transparent", "mix", "rgba", "rgb"} <= got and "column" not in got, str(sorted(got))[:200])
got = ylabels(ytext, "direction: column", len("direction: col"))
check(".yss enum value completion lists the enum", {"column", "row", "row-reverse"} <= got and "bg-primary" not in got, str(sorted(got))[:200])
got = ylabels(ytext, ":hover { background", 2)
check(".yss condition completion", {"hover", "focus", "disabled"} <= got, str(sorted(got))[:200])
got = ylabels(ytext, "!selected & kind in", 3)
check(".yss when completion lists dimensions", {"selected", "hoverable", "kind"} <= got, str(sorted(got))[:200])
got = ylabels(ytext, "in (default, elevated)", 5)
check(".yss when completion lists the variant's options", {"default", "outlined", "elevated"} <= got, str(sorted(got))[:200])
hv = yhover(ytext, "corner-radius: 6", 3)
check(".yss hover on a property shows its type and token category", "corner-radius" in hv and "radius token" in hv, hv[:200])
hv = yhover(ytext, "bg-primary;", 3)
check(".yss hover on a token shows light and dark values", "color token" in hv and "light `#" in hv and "dark `#" in hv, hv[:200])
hv = yhover(ytext, "recipe Card", 8)
check(".yss hover on a recipe name summarises it", "ui.cva" in hv and "variant **kind**" in hv, hv[:200])
syms = request("textDocument/documentSymbol", {"textDocument": {"uri": YURI}}) or []
names = [x["name"] for x in syms]
card = next((x for x in syms if x["name"] == "Card"), {})
kids = {c["name"]: c for c in card.get("children", [])}
check(".yss document symbols list declarations with variants", {"Card", "header", "Body"} <= set(names) and "kind" in kids and {"default", "outlined"} <= {o["name"] for o in kids["kind"].get("children", [])}, json.dumps(syms)[:300])
hv = yhover(ytext, "ui.BoxStyle {", 4)
check(".yss passthrough Zig is served by ZLS (hover on ui.BoxStyle)", "BoxStyle" in hv, hv[:200])
# mixin call -> declaration
TAG = ROOT / "src/ui/components/tag/styles.yss"
TURI = TAG.as_uri()
ttext = TAG.read_text()
notify("textDocument/didOpen", {"textDocument": {"uri": TURI, "languageId": "yss", "version": 1, "text": ttext}})
d = request("textDocument/definition", {"textDocument": {"uri": TURI}, "position": pos_of(ttext, "tone(accent)", 1)})
d = d if isinstance(d, list) else [d] if d else []
check(".yss definition of a mixin call jumps to the mixin", any(x["uri"] == TURI and x["range"]["start"]["line"] == ttext[:ttext.index("mixin tone")].count("\n") for x in d), json.dumps(d)[:200])
# `@import("styles.yss")` symbols in .yix: jump lands in .yss source file, not generated
CARD = ROOT / "src/ui/components/card/card.yix"
CURI = CARD.as_uri()
ctext = CARD.read_text() + "\nconst smokeSize = S.smokeSize;\n"
notify("textDocument/didOpen", {"textDocument": {"uri": CURI, "languageId": "yix", "version": 1, "text": ctext}})
time.sleep(1)
def ylocs(method, t, needle, delta, uri):
    d = request(method, {"textDocument": {"uri": uri}, "position": pos_of(t, needle, delta)})
    d = d if isinstance(d, list) else [d] if d else []
    return [(x.get("uri") or x.get("targetUri"), (x.get("range") or x.get("targetSelectionRange"))["start"]["line"]) for x in d]
locs = ylocs("textDocument/definition", ctext, "S.smokeSize", 3, CURI)
check(".yix definition of a .yss passthrough function lands in the .yss source", (YURI, ytext[:ytext.index("pub fn smokeSize")].count("\n")) in locs, str(locs)[:200])
locs = ylocs("textDocument/definition", ctext, '@import("styles.yss")', 10, CURI)
check(".yix definition on @import(\"styles.yss\") opens the .yss source, not the twin", any(u == YURI for u, _ in locs), str(locs)[:200])
locs = ylocs("textDocument/declaration", ctext, "S.Card.of", 3, CURI)
check(".yix declaration of a .yss recipe lands in the .yss source", (YURI, ytext[:ytext.index("recipe Card")].count("\n")) in locs, str(locs)[:200])

# ---- .yss token values per nearest theme.json: under examples use examples/theme.json (has
# counterValue), under src/ui use default design system ----
EX = ROOT / "examples/yix_counter/probe.yss" # No disk requirement: LSP only looks up by path
EXURI = EX.as_uri()
extext = 'const ui = @import("ui");\nstyle s { font-size: counterValue; }\n'
notify("textDocument/didOpen", {"textDocument": {"uri": EXURI, "languageId": "yss", "version": 1, "text": extext}})
got = ylabels(extext, "font-size: counterValue", len("font-size: c"), EXURI)
check(".yss under examples completes tokens from examples/theme.json", "counterValue" in got and "xxl" in got, str(sorted(got))[:200])
hv = yhover(extext, "counterValue", 3, EXURI)
check(".yss hover shows the token value from examples/theme.json", "light `18`" in hv, hv[:200])
got = ylabels(ytext, "font-size: 14", len("font-size: "))
check(".yss under src/ui uses the default design system (no example-only tokens)", "counterValue" not in got and "md" in got, str(sorted(got))[:200])

# ---- On save write twin back to disk (don't touch if compile fails; save again to restore) ----
FTWIN = FIX.parent / ("_" + FIX.name + ".zig")
twin_before = FTWIN.read_bytes()
source_before = FIX.read_bytes()
marked = ftext.replace("const W = ui.widgets;", "const W = ui.widgets;\nconst saved_marker = 1;", 1)
def save_fixture(t, version):
    edit(t, version)
    # An editor saves the source to disk before sending didSave. ZLS's build
    # runner may also regenerate twins from disk, so match that contract.
    FIX.write_text(t)
    notify("textDocument/didSave", {"textDocument": {"uri": FURI}})
    # The proxy handles this request after didSave; avoid a timing-dependent sleep.
    request("textDocument/documentSymbol", {"textDocument": {"uri": FURI}})

try:
    save_fixture(marked, 50)
    check("didSave rewrites the generated twin", b"saved_marker" in FTWIN.read_bytes(), FTWIN.read_text()[:120])
    save_fixture(ftext.replace("</col>", "</cl>", 1), 51)
    check("didSave leaves the twin alone while the source does not compile", b"saved_marker" in FTWIN.read_bytes(), "")
    save_fixture(ftext, 52)
    check("saving the original text restores the twin byte-for-byte", FTWIN.read_bytes() == twin_before, "")
finally:
    FIX.write_bytes(source_before)
    FTWIN.write_bytes(twin_before)

# ---- On save build: Zig errors in twin mapped back to .yix line; errors in library code mapped via
# component-frame in reference chain ----
twin_text = FTWIN.read_text()
g = twin_text.index('"Save"')
gl = twin_text.count("\n", 0, g) + 1
gc = g - (twin_text.rfind("\n", 0, g) + 1) + 1
twin_rel = FTWIN.relative_to(ROOT)
BUILD_ERRS.write_text(f"{twin_rel}:{gl}:{gc}: error: smoke boom\nsrc/ui/reactive/props.zig:33:37: error: ButtonProps: unknown prop 'lable'\nreferenced by:\n    __yix_Demo: {twin_rel}:{gl}:{gc}\n")
diagnostics.pop(FURI, None)
notify("textDocument/didSave", {"textDocument": {"uri": FURI}})
m = wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == FURI and any(d.get("source") == "zig build" for d in m["params"]["diagnostics"]), 20)
bd = [d for d in m["params"]["diagnostics"] if d.get("source") == "zig build"]
save_line = pos_of(ftext, '"Save"')["line"]
check("build-on-save maps a Zig error in the twin back to the .yix line", any("smoke boom" in d["message"] and d["range"]["start"]["line"] == save_line for d in bd), json.dumps(bd)[:300])
check("build-on-save maps a library error through the component frame", any("unknown prop 'lable'" in d["message"] and d["range"]["start"]["line"] == save_line for d in bd), json.dumps(bd)[:300])
BUILD_ERRS.write_text("")
notify("textDocument/didSave", {"textDocument": {"uri": FURI}})
wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == FURI and not any(d.get("source") == "zig build" for d in m["params"]["diagnostics"]), 20)
check("a clean build clears the build diagnostics", True)

# ---- Named modules: `@import("ui")` in examples view.yix resolves (virtual doc is the twin in
# build graph) ----
HB = ROOT / "examples/hello_button/view.yix"
HURI = HB.as_uri()
htext = HB.read_text()
notify("textDocument/didOpen", {"textDocument": {"uri": HURI, "languageId": "yix", "version": 1, "text": htext}})
# ZLS loads the build graph asynchronously. A cold configuration may not be
# ready for the first hover; retry the same semantic assertion within a bound.
deadline = time.monotonic() + 30
while True:
    hv = yhover(htext, "ui.widgets.Button", len("ui.widgets.Bu"), HURI)
    if "Button" in hv or time.monotonic() >= deadline:
        break
    time.sleep(0.2)
check("named module @import(\"ui\") resolves in an example (hover on ui.widgets.Button)", "Button" in hv, hv[:200])

request("shutdown", None)
notify("exit", None)
proc.wait(timeout=10)

# ---- No ZLS: degrade not hang (Yix diagnostics, template completion work, other requests return
# null immediately) ----
proc = subprocess.Popen([LSP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=ROOT, env=dict(os.environ, YIX_ZLS="/nonexistent/zls"))
inbox = queue.Queue()
threading.Thread(target=reader, daemon=True).start()
init = request("initialize", {"processId": os.getpid(), "rootUri": ROOT.as_uri(), "capabilities": {}})
check("no ZLS: initialize still answers", init is not None and init["capabilities"].get("textDocumentSync", {}).get("change") == 1, json.dumps(init)[:200])
notify("initialized", {})
notify("textDocument/didOpen", {"textDocument": {"uri": URI, "languageId": "yix", "version": 1, "text": bad2}})
wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and any(d.get("source") == "yix" for d in m["params"]["diagnostics"]), 10)
check("no ZLS: yix diagnostics still published", True)
t0 = time.time()
h = request("textDocument/hover", {"textDocument": {"uri": URI}, "position": pos_of(bad2, "labelOf(label, count", 2)})
check("no ZLS: Zig requests answer null immediately", h is None and time.time() - t0 < 2, str(h))
notify("textDocument/didOpen", {"textDocument": {"uri": FURI, "languageId": "yix", "version": 1, "text": t3}})
got = labels_at(t3, "<row f", len("<row f"))
check("no ZLS: host attribute completion still works", {"style", "focusRing"} <= got, str(sorted(got))[:200])
request("shutdown", None)
notify("exit", None)
try:
    proc.wait(timeout=10)
    check("no ZLS: exits cleanly", proc.returncode == 0, str(proc.returncode))
except subprocess.TimeoutExpired:
    check("no ZLS: exits cleanly", False, "timeout")
print("all passed" if not failures else f"{len(failures)} failed")
sys.exit(1 if failures else 0)
