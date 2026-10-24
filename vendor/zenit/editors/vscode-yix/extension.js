// Yix language client: spawns yix-lsp (which proxies ZLS), see docs/YIX_EDITOR.md.
const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function executableName(name) {
  return os.platform() === "win32" ? `${name}.exe` : name;
}

function inWorkspace(name) {
  for (const folder of vscode.workspace.workspaceFolders || []) {
    const p = path.join(folder.uri.fsPath, "zig-out", "bin", executableName(name));
    if (fs.existsSync(p)) return p;
  }
  return undefined;
}

function onPath(name) {
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    const p = path.join(dir, executableName(name));
    if (fs.existsSync(p)) return p;
  }
  return undefined;
}

function findLsp() {
  const configured = vscode.workspace.getConfiguration("yix").get("lsp.path");
  if (configured) return configured;
  return inWorkspace("yix-lsp") || onPath("yix-lsp");
}

function findZls(context) {
  const configured = vscode.workspace.getConfiguration("yix").get("zls.path");
  if (configured) return configured;
  const zigSetting = vscode.workspace.getConfiguration("zig").get("zls.path");
  if (zigSetting && fs.existsSync(zigSetting)) return zigSetting;
  const bundled = inWorkspace("zenit-zls");
  if (bundled) return bundled;
  const fromPath = onPath("zenit-zls") || onPath("zls");
  if (fromPath) return fromPath;
  // ZLS downloaded by Zig official extension into its own globalStorage
  const storage = path.join(path.dirname(context.globalStorageUri.fsPath), "ziglang.vscode-zig", "zls");
  if (fs.existsSync(storage)) {
    for (const version of fs.readdirSync(storage).sort().reverse()) {
      const p = path.join(storage, version, executableName("zls"));
      if (fs.existsSync(p)) return p;
    }
  }
  return undefined;
}

function activate(context) {
  const lsp = findLsp();
  if (!lsp) {
    vscode.window.showWarningMessage("Yix: yix-lsp not found. Run `zig build yix-lsp` or set yix.lsp.path.");
    return;
  }
  const zls = findZls(context);
  const env = Object.assign({}, process.env);
  if (zls) env.YIX_ZLS = zls;
  else vscode.window.showWarningMessage("Yix: ZLS not found; run `zig build dev-tools` or set yix.zls.path to enable Zig intelligence.");
  const serverOptions = { command: lsp, transport: TransportKind.stdio, options: { env } };
  const clientOptions = { documentSelector: [{ scheme: "file", language: "yix" }, { scheme: "file", language: "yss" }] };
  // On-save build: Zig type errors mapped back to .yix / .yss (null delegates to yix-lsp's default
  // zig build)
  const buildOnSave = vscode.workspace.getConfiguration("yix").get("buildOnSave");
  if (Array.isArray(buildOnSave)) clientOptions.initializationOptions = { buildOnSave };
  client = new LanguageClient("yix", "Yix", serverOptions, clientOptions);
  client.start();
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
