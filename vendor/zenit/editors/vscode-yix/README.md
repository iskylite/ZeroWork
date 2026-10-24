# Yix (zenit)

Yix (.yix) language support: syntax highlighting, Yix diagnostics, and Zig intelligence (hover, completion, go to definition, references) through ZLS with source mapping. With Zig 0.17.0, run `zig build dev-tools` in the Zenit repository to install both `yix-lsp` and the bundled `zenit-zls` in `zig-out/bin`. `zig build yix-lsp` also installs both; `zig build zls` installs only `zenit-zls`. See [YIX_EDITOR.md](../../docs/YIX_EDITOR.md).

Yix style recipes (.yss): syntax highlighting; completion, hover and go-to-definition for properties, tokens (with light / dark values), conditions, mixins and variants; outline; live style-compiler diagnostics; Zig parts served by ZLS. See docs/YSS.md.

Generated twins: each `.yix` / `.yss` has a checked-in `_<name>.zig` next to it (`card.yix` → `_card.yix.zig`, `zig build gen-yix`; yix-lsp also rewrites it on save). Inside `.yix` / `.yss`, import sources by their own name (`@import("styles.yss")`); the compiler rewrites the string to the twin. Hand-written Zig imports the twin. The extension nests twins under their source in the Explorer and opens them read-only.

Build on save: after saving a `.yix` / `.yss` file, yix-lsp runs a build in the workspace root and maps its Zig compile errors (which ZLS does not report) back onto the source. Configure the command with `yix.buildOnSave` (default: `zig build` when the workspace has a `build.zig`; `[]` turns it off).

ZLS discovery honors `yix.zls.path`, then an existing `zig.zls.path`, then the workspace's `zig-out/bin/zenit-zls`, `zenit-zls` or `zls` on PATH, and the Zig extension's download. `yix-lsp` is found through `yix.lsp.path`, the workspace's `zig-out/bin/yix-lsp`, or PATH. Both executable names use `.exe` on Windows.

For ordinary Zig files, configure the Zig extension's `zig.zls.path` to the absolute path of `zig-out/bin/zenit-zls` (`zenit-zls.exe` on Windows), and use Zig 0.17.0. The bundled source is pinned in `vendor/zls`, based on upstream commit `eab2be0fd74443a27662da809b771c4ad0d2afcf` and PR #3270 commit `9b57f17367e2a11ddb6af0efcbe992c82709d165`, with local fixes. See [vendor compatibility notes](../../vendor/zls/ZIG017.md) for provenance and remaining protocol limitations, including modules not reachable from any compile/check/test step.

## Install from this checkout

Use Zig 0.17.0 and Node/npm. From the repository root on macOS:

```sh
zig build dev-tools
(cd editors/vscode-yix && npm ci && npx @vscode/vsce package --out zenit-yix.vsix)
code --install-extension editors/vscode-yix/zenit-yix.vsix
```

For PowerShell commands and Windows build-on-save settings, see
[YIX_EDITOR.md](../../docs/YIX_EDITOR.md). For the component/style workflow, see
[YIX_YSS_GUIDE.md](../../docs/YIX_YSS_GUIDE.md).
