const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const paths = require('node:path');
const source = fs.readFileSync(process.argv[2] || paths.join(__dirname, '..', 'extension.js'), 'utf8');
let passed = 0;
let failed = 0;
function check(name, action) {
  try { action(); passed++; console.log('PASS ' + name); }
  catch (error) { failed++; console.error('FAIL ' + name + ': ' + error.message); }
}
function harness(platform) {
  const path = platform === 'win32' ? paths.win32 : paths.posix;
  const root = platform === 'win32' ? 'C:' + path.sep + 'repo' : '/repo';
  const second = platform === 'win32' ? 'C:' + path.sep + 'other' : '/other';
  const bin = platform === 'win32' ? 'C:' + path.sep + 'path' : '/path';
  const storageRoot = platform === 'win32' ? path.join('C:' + path.sep, 'storage', 'zenit.yix') : '/storage/zenit.yix';
  const exe = name => name + (platform === 'win32' ? '.exe' : '');
  const workspaceBinary = (name, folder = root) => path.join(folder, 'zig-out', 'bin', exe(name));
  const pathBinary = name => path.join(bin, exe(name));
  const storage = path.join(path.dirname(storageRoot), 'ziglang.vscode-zig', 'zls');
  const files = new Set();
  const settings = { yix: {}, zig: {} };
  let serverOptions;
  const vscode = {
    workspace: {
      workspaceFolders: [{ uri: { fsPath: root } }, { uri: { fsPath: second } }],
      getConfiguration: name => ({ get: key => settings[name][key] }),
    },
    window: { showWarningMessage() {} },
  };
  const context = { globalStorageUri: { fsPath: storageRoot }, subscriptions: [] };
  const sandbox = {
    module: { exports: {} },
    process: { env: { PATH: bin, PRESERVED: 'keep' } },
    require(name) {
      if (name === 'fs') return { existsSync: file => files.has(file), readdirSync: () => ['0.15.1', '0.17.0'] };
      if (name === 'os') return { platform: () => platform };
      if (name === 'path') return path;
      if (name === 'vscode') return vscode;
      if (name === 'vscode-languageclient/node') return {
        TransportKind: { stdio: 1 },
        LanguageClient: class { constructor(_id, _name, options) { serverOptions = options; } start() {} stop() {} },
      };
      throw new Error(name);
    },
  };
  vm.runInNewContext(source + '\nmodule.exports.resolve = { findLsp, findZls };', sandbox);
  const { findLsp, findZls } = sandbox.module.exports.resolve;
  return { files, settings, findLsp, findZls: () => findZls(context), workspaceBinary, pathBinary, path, storage, exe, root, second,
    activate: () => { sandbox.module.exports.activate(context); return serverOptions; } };
}
for (const platform of ['darwin', 'win32']) {
  check(platform + ' workspace tools, including platform suffix', () => {
    const h = harness(platform);
    h.files.add(h.workspaceBinary('yix-lsp')); h.files.add(h.workspaceBinary('zenit-zls'));
    h.files.add(h.pathBinary('zls'));
    assert.equal(h.findLsp(), h.workspaceBinary('yix-lsp'));
    assert.equal(h.findZls(), h.workspaceBinary('zenit-zls'));
    const server = h.activate();
    assert.equal(server.command, h.workspaceBinary('yix-lsp'));
    assert.equal(server.options.env.YIX_ZLS, h.workspaceBinary('zenit-zls'));
    assert.equal(server.options.env.PRESERVED, 'keep');
  });
  check(platform + ' explicit yix settings precede Zig and workspace', () => {
    const h = harness(platform);
    h.settings.yix['lsp.path'] = '/custom/yix'; h.settings.yix['zls.path'] = '/custom/zls';
    h.settings.zig['zls.path'] = '/zig/zls'; h.files.add('/zig/zls');
    h.files.add(h.workspaceBinary('zenit-zls'));
    assert.equal(h.findLsp(), '/custom/yix'); assert.equal(h.findZls(), '/custom/zls');
  });
  check(platform + ' existing explicit Zig setting precedes workspace', () => {
    const h = harness(platform); h.settings.zig['zls.path'] = '/zig/zls'; h.files.add('/zig/zls');
    h.files.add(h.workspaceBinary('zenit-zls')); assert.equal(h.findZls(), '/zig/zls');
  });
  check(platform + ' missing Zig setting falls back to second workspace', () => {
    const h = harness(platform); h.settings.zig['zls.path'] = '/missing';
    h.files.add(h.workspaceBinary('zenit-zls', h.second));
    assert.equal(h.findZls(), h.workspaceBinary('zenit-zls', h.second));
  });
  check(platform + ' PATH tools use platform suffix and bundled ZLS wins', () => {
    const h = harness(platform); h.files.add(h.pathBinary('yix-lsp'));
    h.files.add(h.pathBinary('zenit-zls')); h.files.add(h.pathBinary('zls'));
    assert.equal(h.findLsp(), h.pathBinary('yix-lsp')); assert.equal(h.findZls(), h.pathBinary('zenit-zls'));
  });
  check(platform + ' upstream PATH fallback', () => {
    const h = harness(platform); h.files.add(h.pathBinary('zls')); assert.equal(h.findZls(), h.pathBinary('zls'));
  });
  check(platform + ' upstream download fallback and missing tools', () => {
    const h = harness(platform);
    assert.equal(h.findLsp(), undefined); assert.equal(h.findZls(), undefined);
    h.files.add(h.storage);
    const downloaded = h.path.join(h.storage, '0.17.0', h.exe('zls')); h.files.add(downloaded);
    assert.equal(h.findZls(), downloaded);
  });
}
console.log(`${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
