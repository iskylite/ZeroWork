import {nativeThemeData} from './native_theme_data.mjs';
/** Settings card and selection feedback in isolated native windows.
 * node e2e/settings_theme_contrast_native.ts BINARY OUTPUT_DIR
 */
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdir, mkdtemp, open, readFile, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary = resolve(process.argv[2]), out = resolve(process.argv[3]);
await mkdir(out, {recursive: true});
const cases = [
  ['gruvbox-dark', 0], ['gruvbox-dark', 50], ['gruvbox-dark', 100],
  ['dark', 0], ['light', 0], ['light', 50], ['light', 100], ['sauber', 0],
] as const;
const requestedCase = process.argv[4];
const report: any = {status: 'running', cases: []};
const palettes = nativeThemeData.themes;
const shown = (node: any) => node && node.visible !== false && !node.hidden && node.rect?.w > 0 && node.rect?.h > 0;
const descendants = (node: any): any[] => [node, ...(node.children ?? []).flatMap(descendants)];

try {
  for (const [theme, transparency] of cases) {
    const name = `${theme}-t${transparency}`;
    if (requestedCase && name !== requestedCase) continue;
    const iso = await mkdtemp('/private/tmp/zw-settings-colors-');
    const data = join(iso, 'data'), rpc = join(iso, 'rpc'), image = join(iso, 'background.png');
    await Promise.all([mkdir(data), mkdir(rpc)]);
    execFileSync('python3', ['-c', `from PIL import Image, ImageDraw
import sys
im=Image.new('RGB',(360,240),(29,48,73));d=ImageDraw.Draw(im)
d.rectangle((180,0,359,239),fill=(210,180,125));d.ellipse((60,30,300,210),fill=(102,138,143))
im.save(sys.argv[1])`, image]);
    await writeFile(join(data, 'config.toml'), `[ui]\ntheme="${theme}"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\nenabled=true\npath=${JSON.stringify(image)}\nfit="fill"\ntransparency=${transparency}\n[ai]\ndefault_provider="Fixture"\n[[ai.providers]]\nid="Fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="model"\ndefault=true\ncontext_window=128000\n`);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const log = await open(join(out, `${name}.log`), 'w');
    const app = spawn(binary, [], {env: {...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0', ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1'}, stdio: ['ignore', log.fd, log.fd]});
    const ended = new Promise(done => app.once('close', done));
    const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 15000);
    const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
    const item: any = {theme, transparency}; report.cases.push(item);
    try {
      await h.waitForServerReady();
      assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
      await h.resizeWindow(1440, 900);
      await click('toolbar.settings'); await click('settings.nav.ai');
      if ((await h.query('settings.ai.provider.0.endpoint')).some(shown)) await click('settings.ai.provider.0.header');
      const headerId = 'settings.ai.permissions.header', summaryId = 'settings.ai.permissions.summary';
      await visible(headerId);
      if (!(await h.query(summaryId)).some(shown)) await click(headerId);
      const summary = await visible(summaryId);
      await h.mouseMove(5, 5); await h.sleep(350);
      const card = await visible(headerId), nav = await visible('settings.nav.ai');
      const geometry = Object.fromEntries(await Promise.all(['settings.viewport', 'settings.footer', 'settings.ai.attachments', 'appearance.material.compensation'].map(async id => [id, await h.query(id)])));
      const attachments = geometry['settings.ai.attachments'].find(shown);
      assert(attachments && !descendants(attachments).some(node => node.test_id === 'appearance.material.compensation'), 'collapsed provider contents must not mask the visible attachment card');
      if (process.env.ZW_SETTINGS_CONTRAST_DEBUG) await writeFile(join(out, `${name}-tree.json`), JSON.stringify(await h.tree()));
      assert((await h.screenshot(join(out, `${name}-rest.png`))).ok);
      await h.mouseMove(card.rect.x + card.rect.w * .75, card.rect.y + card.rect.h * .5);
      await h.sleep(250); assert((await h.screenshot(join(out, `${name}-card-hover.png`))).ok);
      await h.mouseMove(nav.rect.x + nav.rect.w * .8, nav.rect.y + nav.rect.h * .5);
      await h.sleep(250); assert((await h.screenshot(join(out, `${name}-selection-hover.png`))).ok);
      await click('settings.nav.keys'); await h.mouseMove(5, 5); await h.sleep(200);
      assert((await h.screenshot(join(out, `${name}-unselected.png`))).ok);
      await writeFile(join(out, `${name}.json`), JSON.stringify({card: card.rect, nav: nav.rect, geometry}, null, 2));
      const pixels = `from PIL import Image
import json,sys,math,collections
base,name,rects=sys.argv[1],sys.argv[2],json.loads(sys.argv[3]);a=Image.open(f'{base}/{name}-rest.png').convert('RGB');b=Image.open(f'{base}/{name}-card-hover.png').convert('RGB');c=Image.open(f'{base}/{name}-selection-hover.png').convert('RGB');u=Image.open(f'{base}/{name}-unselected.png').convert('RGB');scale=a.width/1440
def p(im,r,x,y):return im.getpixel((round((r['x']+r['w']*x)*scale),round((r['y']+r['h']*y)*scale)))
def d(x,y):return math.sqrt(sum((u-v)**2 for u,v in zip(x,y)))
card=d(p(a,rects['card'],.65,.5),p(b,rects['card'],.65,.5));edge=d(p(b,rects['card'],.65,.5),p(b,rects['card'],.65,-5/rects['card']['h']));selection=d(p(a,rects['nav'],.65,.7),p(c,rects['nav'],.65,.7));chosen=d(p(a,rects['nav'],.65,.7),p(u,rects['nav'],.65,.7));result={'card_hover_rgb_distance':round(card,2),'hover_edge_rgb_distance':round(edge,2),'selected_hover_rgb_distance':round(selection,2),'selection_rgb_distance':round(chosen,2)};assert card>=5 and edge>=5 and selection>=3 and chosen>=5
if name=='light-t50':
 r=rects['summary'];ink=tuple(int(rects['ink'][i:i+2],16) for i in (1,3,5));box=tuple(round(v*scale) for v in (r['x'],r['y'],r['x']+min(r['w'],200),r['y']+r['h']));counts=collections.Counter(a.crop(box).getdata());bg=a.getpixel((round((r['x']+min(r['w'],190))*scale),round((r['y']+r['h']/2)*scale)))
 def lum(col):return sum((v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4)*w for v,w in zip(col,(.2126,.7152,.0722)))
 x,y=sorted((lum(ink),lum(bg)));ratio=(y+.05)/(x+.05);result['summary_contrast']=round(ratio,2);assert counts[ink]>=3 and ratio>=4.5
print(json.dumps(result))`;
      item.pixels = JSON.parse(execFileSync('python3', ['-c', pixels, out, name, JSON.stringify({card: card.rect, nav: nav.rect, summary: summary.rect, ink: palettes[theme]['--fg-1']})], {encoding: 'utf8'}));
      await click('settings.nav.ai'); await visible(summaryId);
      await click(headerId); await h.waitFor(async () => !(await h.query(summaryId)).some(shown) || null, 10000);
      await click(headerId); await visible(summaryId);
      if (theme === 'dark' && transparency === 0) {
        await click('settings.nav.appearance');
        const tile = await visible('settings.theme.dark');
        await h.mouseMove(5, 5); await h.sleep(200);
        assert((await h.screenshot(join(out, `${name}-theme-selected.png`))).ok);
        await h.mouseMove(tile.rect.x + tile.rect.w * .5, tile.rect.y + tile.rect.h * .5);
        await h.sleep(250); assert((await h.screenshot(join(out, `${name}-theme-selected-hover.png`))).ok);
        const tilePixels = `from PIL import Image
import json,sys,math
base,name,r=sys.argv[1],sys.argv[2],json.loads(sys.argv[3]);a=Image.open(f'{base}/{name}-theme-selected.png').convert('RGB');b=Image.open(f'{base}/{name}-theme-selected-hover.png').convert('RGB');s=a.width/1440;x=round((r['x']+r['w']*.98)*s);y=round((r['y']+r['h']*.5)*s);d=math.sqrt(sum((u-v)**2 for u,v in zip(a.getpixel((x,y)),b.getpixel((x,y)))));print(round(d,2));assert d>=3`;
        item.theme_selected_hover_rgb_distance = Number(execFileSync('python3', ['-c', tilePixels, out, name, JSON.stringify(tile.rect)], {encoding: 'utf8'}));
        const otherTile = await visible('settings.theme.light');
        await h.mouseMove(otherTile.rect.x + otherTile.rect.w * .5, otherTile.rect.y + otherTile.rect.h * .5);
        await h.sleep(250); assert((await h.screenshot(join(out, `${name}-theme-unselected-hover.png`))).ok);
        const otherTilePixels = `from PIL import Image
import json,sys,math
base,name,r=sys.argv[1],sys.argv[2],json.loads(sys.argv[3]);a=Image.open(f'{base}/{name}-theme-selected.png').convert('RGB');b=Image.open(f'{base}/{name}-theme-unselected-hover.png').convert('RGB');s=a.width/1440;x=round((r['x']+r['w']*.98)*s);y=round((r['y']+r['h']*.5)*s);edge=round((r['x']+r['w']+2)*s);d=lambda p,q:math.sqrt(sum((u-v)**2 for u,v in zip(p,q)));change=d(a.getpixel((x,y)),b.getpixel((x,y)));boundary=d(b.getpixel((x,y)),b.getpixel((edge,y)));print(json.dumps({'change':round(change,2),'boundary':round(boundary,2)}));assert change>=5 and boundary>=5`;
        item.theme_unselected_hover = JSON.parse(execFileSync('python3', ['-c', otherTilePixels, out, name, JSON.stringify(otherTile.rect)], {encoding: 'utf8'}));
      }
      item.status = 'passed'; console.log(`${name} passed`);
    } catch (error) {
      item.status = 'failed'; item.error = String(error);
      await h.screenshot(join(out, `${name}-failure.png`)).catch(() => {});
      throw error;
    } finally {
      if (app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
      await ended; await log.close();
    }
  }
  assert(report.cases.length > 0, `Unknown case: ${requestedCase}`);
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = String(error); console.error(error); process.exitCode = 1;
} finally {
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
}
