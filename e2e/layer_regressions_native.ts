/** Retained material regressions through production settings and AI controls.
 * node e2e/layer_regressions_native.ts /absolute/test-mode/binary /absolute/output
 */
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, mkdtemp, open, readFile, writeFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
await mkdir(out, {recursive: true});
const iso = await mkdtemp('/private/tmp/zw-layer-regressions-');
const data = join(iso, 'data'), rpc = join(iso, 'rpc');
await mkdir(data); await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const wallpaper = join(data, 'background.png');
await writeFile(wallpaper, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAJ0lEQVR4nGPQcksBoiq3aUCEzGbAKVFVkQJEWhXTgAiZjVuCDnYAAMasS4GfPJd/AAAAAElFTkSuQmCC', 'base64'));
await writeFile(join(data, 'config.toml'), `[ui]
theme="dark"
[ui.materials]
blur_px=24
[ui.materials.background]
enabled=true
path="${wallpaper}"
transparency=75
[ai]
default_provider="fixture"
[[ai.providers]]
id="fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:9/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="layer-model"
context_window=128000
default=true
`);
await writeFile(join(data, 'hosts.toml'), '[[hosts]]\nname="Material fixture"\nhost="192.0.2.1"\nuser="fixture"\n');
const log = await open(join(out, 'app.log'), 'w');
const env = {...process.env, ZEROWORK_DATA_DIR:data, ZEROWORK_AUTOCONNECT:'0', ZENIT_E2E_BACKGROUND:'1', ZENIT_E2E_ISOLATE_POINTER:'1'};
for (const name of ['ZEROWORK_AI_MOCK', 'ZEROWORK_AI_ENDPOINT', 'ZEROWORK_AI_MODEL', 'ZEROWORK_AI_PROVIDER', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY']) delete env[name];
const app = spawn(binary, [], {env, stdio:['ignore',log.fd,log.fd]});
const ended = new Promise<void>(r => app.once('close', () => r()));
const shown = (n:any) => n?.rect?.w > 0 && n.rect.h > 0 && n.visible !== false && n.hidden !== true;
const visible = (id:string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
const click = async (id:string) => {await visible(id); assert((await h.clickTestId(id)).ok, id);};
const report:any = {status:'running', binary, sha256:createHash('sha256').update(await readFile(binary)).digest('hex'), captures:[], checks:[], limits:['Isolated Local PTY and synthetic wallpaper/input; no SSH or model request.']};
async function capture(name:string, id='ai.panel') {
  await h.mouseMove(5,5); await h.sleep(500);
  const panel = await visible(id);
  assert((await h.screenshot(join(out,name+'.png'))).ok);
  await writeFile(join(out,name+'.json'), JSON.stringify(panel,null,2));
  report.captures.push({name,id,rect:panel.rect});
}
async function selectTheme(theme:string) {
  await click('toolbar.settings'); await click('settings.nav.appearance');
  // A collapsed accordion retains its children's last bounds. Require the
  // strip to fit the actual card, not merely have a nonzero retained rect.
  const exposedStrip = async () => {
    const card = (await h.query('settings.appearance.themes')).find(shown);
    const strip = (await h.query('settings.theme.strip')).find(shown);
    return card && strip && strip.rect.y >= card.rect.y && strip.rect.y+strip.rect.h <= card.rect.y+card.rect.h+1 ? strip : null;
  };
  if (!await exposedStrip()) await click('settings.appearance.themes.header');
  const strip = await h.waitFor(exposedStrip,15000);
  let tile = await visible('settings.theme.'+theme);
  for (let i=0; i<8 && (tile.rect.x<strip.rect.x || tile.rect.x+tile.rect.w>strip.rect.x+strip.rect.w); i++) {
    await h.scrollAt(strip.rect.x+strip.rect.w/2,strip.rect.y+strip.rect.h/2,tile.rect.x<strip.rect.x?strip.rect.x-tile.rect.x+5:strip.rect.x+strip.rect.w-tile.rect.x-tile.rect.w-5,0);
    await h.sleep(100); tile=await visible('settings.theme.'+theme);
  }
  await click('settings.theme.'+theme); await click('settings.save');
  await h.waitFor(async () => (await visible('settings.footer.state')).text==='已保存' || null);
  await click('settings.close');
}
try {
  await h.waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid), app.pid);
  await h.resizeWindow(1440,900); await click('workspace.empty.local');
  // No AI open has occurred: its original opaque Dark branch is detached.
  await selectTheme('light'); await click('ai.strip'); await capture('light-first-open');
  const original = (await visible('ai.panel')).id;
  const draft = await visible('ai.prompt');
  await h.clickAt(draft.rect.x+40,draft.rect.y+15); await h.type_('分层回归草稿');
  for (const theme of ['sauber','dark','light']) {
    await click('ai.collapse'); await h.sleep(250); await selectTheme(theme);
    await click('ai.strip'); await capture(theme+'-after-hidden-theme');
    assert.equal((await visible('ai.panel')).id, original, 'retained node identity');
    assert.equal((await h.inputState('ai.prompt')).buffer, '分层回归草稿');
  }
  for (let i=0;i<4;i++) {await click('ai.collapse');await h.sleep(250);await click('ai.strip');await visible('ai.panel');}
  await capture('light-reopened');
  await h.resizeWindow(860,480); await capture('light-compact');
  await h.resizeWindow(1440,900); await h.key('k',{cmd:true});
  await visible('quick.connect'); await h.key('down'); await h.key('down');
  await capture('quick-selection','quick.connect'); await h.key('escape');
  report.checks.push('Theme change before first AI open', 'Dark/Light/Sauber changes while detached preserve node ID and draft', 'Repeated collapse/reopen and 860×480', 'Quick-connect selected state');
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  execFileSync('python3',[resolve('e2e/layer_regression_pixels.py'),out],{stdio:'inherit'});
  report.status='passed';
} catch(e) {
  report.status='failed';report.error=String(e);process.exitCode=1;
  await h.screenshot(join(out,'failure.png')).catch(()=>{});
} finally {
  if(app.exitCode===null && app.signalCode===null) app.kill('SIGTERM');
  await ended; if(app.pid) await cleanupOwnedBridgeDirectories(app.pid);
  await log.close(); await rm(iso,{recursive:true,force:true});
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify({status:report.status,error:report.error,captures:report.captures.length}));
}
