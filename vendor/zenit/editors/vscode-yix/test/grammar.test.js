// Yix TextMate grammar tokenization test: Zig part reuses local Zig extension's source.zig (skips
// if not found).
const fs = require("fs");
const os = require("os");
const path = require("path");
const vsctm = require("vscode-textmate");
const oniguruma = require("vscode-oniguruma");

const extDir = path.join(os.homedir(), ".vscode", "extensions");
const zigExt = fs.existsSync(extDir) && fs.readdirSync(extDir).find((d) => d.startsWith("ziglang.vscode-zig"));
if (!zigExt) {
  console.log("skip: Zig extension (source.zig grammar) not installed");
  process.exit(0);
}
const grammars = {
  "source.yix": path.join(__dirname, "..", "syntaxes", "yix.tmLanguage.json"),
  "source.yss": path.join(__dirname, "..", "syntaxes", "yss.tmLanguage.json"),
  "source.zig": path.join(extDir, zigExt, "syntaxes", "zig.tmLanguage.json"),
};
const wasm = fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm")).buffer;
const onigLib = oniguruma.loadWASM(wasm).then(() => ({
  createOnigScanner: (s) => new oniguruma.OnigScanner(s),
  createOnigString: (s) => new oniguruma.OnigString(s),
}));
const registry = new vsctm.Registry({
  onigLib,
  loadGrammar: async (scope) => (grammars[scope] ? vsctm.parseRawGrammar(fs.readFileSync(grammars[scope], "utf8"), grammars[scope]) : null),
});

const source = `pub fn Switch(checked: Model(bool) = false, label: []const u8 = "") View {
    const ok = a < b;
    return (
        <row style={S.SwitchParts.slot(.root, .{ .disabled = disabled })} focusRing onClick={if (!disabled) checked = !checked}>
            <W.Card title="Hi">plain words {label}</W.Card>
            {if (has_label) <text style={S.label}>{label}</text>}
        </row>
    );
}`;

const yssSource = `const ui = @import("../../ui.zig");
recipe Card {
  base { direction: column; corner-radius: 6; transition: background 120ms ease-out; }
  variant tone = calm { calm { border: 1 border-strong; } }
  variant variant = plain { plain { } }
  flag hoverable;
  when hoverable & tone in (calm) { :hover { background: #ff0000; } :focus-visible { border: 2 accent; } }
  base { background: #11223380; color: rgba(0, 0, 0, 0.5); }
}
pub fn keep() void {}`;

function scopesAt(grammar, needle, nth = 0, text = source) {
  let rule = vsctm.INITIAL;
  const lines = text.split("\n");
  let seen = 0;
  for (const line of lines) {
    const r = grammar.tokenizeLine(line, rule);
    let idx = -1;
    while ((idx = line.indexOf(needle, idx + 1)) !== -1) {
      if (seen++ === nth) {
        const tok = r.tokens.find((t) => t.startIndex <= idx && idx < t.endIndex);
        return tok.scopes;
      }
    }
    rule = r.ruleStack;
  }
  throw new Error("needle not found: " + needle);
}

registry.loadGrammar("source.yix").then((g) => {
  const cases = [
    ["pub", (s) => s.some((x) => x.startsWith("storage") || x.startsWith("keyword")), "Zig keyword"],
    ["row", (s) => s.includes("entity.name.tag.yix"), "host tag"],
    ["W.Card", (s) => s.includes("support.class.component.yix"), "component tag"],
    ["focusRing", (s) => s.includes("entity.other.attribute-name.yix"), "boolean attribute"],
    ["onClick", (s) => s.includes("entity.other.attribute-name.yix"), "attribute name"],
    ["SwitchParts", (s) => s.includes("meta.embedded.block.zig"), "Zig inside attribute braces"],
    ["a < b", (s) => !s.some((x) => x.includes("tag")), "comparison in Zig code is not a tag"],
    ["text", (s) => s.includes("entity.name.tag.yix"), "tag inside control flow braces", 0],
    ["plain words", (s) => s.includes("meta.jsx.children.yix") && !s.some((x) => x.includes("attribute") || x.includes("keyword") || x.endsWith(".zig")), "children text is plain text"],
    ["label}</W.Card>", (s) => s.includes("meta.embedded.block.zig"), "interpolation in children is Zig"],
    ["Hi", (s) => s.some((x) => x.startsWith("string")), "string attribute value"],
  ];
  let failed = 0;
  for (const [needle, ok, what, nth] of cases) {
    const s = scopesAt(g, needle, nth || 0);
    const pass = ok(s);
    if (!pass) failed++;
    console.log(`${pass ? "PASS" : "FAIL"} ${what}: '${needle}' -> ${s.join(" ")}`);
  }
  return registry.loadGrammar("source.yss").then((y) => {
    const yssCases = [
      ["recipe", (s) => s.includes("keyword.declaration.yss"), ".yss declaration keyword"],
      ["Card", (s) => s.includes("entity.name.type.yss"), ".yss recipe name"],
      ["corner-radius", (s) => s.includes("support.type.property-name.yss"), ".yss property name"],
      ["border-strong", (s) => s.includes("variable.other.token.yss"), ".yss token value"],
      ["120ms", (s) => s.includes("constant.numeric.yss"), ".yss number with unit"],
      ["variant", (s) => s.includes("keyword.control.yss"), ".yss section keyword"],
      ["tone = calm", (s) => s.includes("entity.name.tag.yss"), ".yss dimension name after `variant` is a name, not a keyword"],
      ["hover {", (s) => s.includes("entity.other.attribute-name.pseudo-class.yss"), ".yss condition"],
      ["#11223380", (s) => s.includes("constant.other.color.yss"), ".yss 8-digit hex color"],
      ["rgba(", (s) => s.includes("support.function.yss"), ".yss rgba()"],
      ["-visible {", (s) => s.includes("entity.other.attribute-name.pseudo-class.yss"), ".yss condition with a hyphen (:focus-visible)"],
      ["#ff0000", (s) => s.includes("constant.other.color.yss"), ".yss hex color"],
      ["pub fn keep", (s) => !s.some((x) => x.endsWith(".yss") && x !== "source.yss"), ".yss passthrough Zig is Zig"],
    ];
    for (const [needle, ok, what] of yssCases) {
      const s = scopesAt(y, needle, 0, yssSource);
      const pass = ok(s);
      if (!pass) failed++;
      console.log(`${pass ? "PASS" : "FAIL"} ${what}: '${needle}' -> ${s.join(" ")}`);
    }
    process.exit(failed ? 1 : 0);
  });
});
