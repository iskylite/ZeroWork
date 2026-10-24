import {request, query, tree, clickTestId, mouseMove, key, waitFor, screenshot, waitForServerReady} from './client';
import {assert, test, run, getSessionDir, appendLog} from './runner';
import {decodePng, countDarkPixels} from './png';
const dir = getSessionDir();
async function quality(mode = 'status') {
  const r = await request('POST', '/visual-quality', {mode});
  assert(!r.error && ['full', 'frosted', 'basic'].includes(r.quality), JSON.stringify(r));
  return r.quality;
}
async function navigate(name: string) {
  await clickTestId(`nav.${name}`);
}
async function ink(name: string, id: string, min = 100) {
  const node = await waitFor(async () => (await query(id))[0] ?? null, 5000, 50);
  const path = `${dir}/${name}.png`;
  await screenshot(path);
  const png = decodePng(path), root = await tree();
  const scale = png.width / root.rect.w;
  const count = countDarkPixels(png, node.rect, scale);
  appendLog(`${name}: ink=${count}, scale=${scale}, rect=${JSON.stringify(node.rect)}`);
  assert(count >= min, `${name} lost visible content: ${count}`);
  return png;
}

test('Windows basic material preserves glass content, controls and overlay lifecycle', async () => {
  await waitForServerReady(20000);
  const initial = await quality();
  appendLog(`initial quality=${initial}`);
  // Software adapters (WARP) default to frosted glass, not basic.
  assert(initial === 'frosted' || initial === 'full', `auto quality on this adapter: ${initial}`);
  assert(await quality('basic') === 'basic', 'explicit basic');
  await navigate('glassislands');
  await ink('basic-glass-first', 'story.glassislands.first.slab', 5000);
  await ink('basic-glass-second', 'story.glassislands.second.slab', 5000);
  await navigate('checkbox');
  await clickTestId('story.checkbox.box');
  await waitFor(async () => (await query('story.checkbox.status'))[0]?.text === 'changed → checked', 5000, 50);
  await ink('basic-checkbox', 'story.checkbox.status', 20);
  await navigate('modal');
  for (let cycle=0; cycle<3; cycle++) {
    await clickTestId('story.modal.open');
    await waitFor(async () => {const n=(await query('story.modal.dialog'))[0]; return n && n.rect.w>100 && n.rect.h>40 && n.visible !== false;}, 5000, 50);
    await ink(`basic-modal-${cycle}`, 'story.modal.dialog');
    await key('escape');
    await waitFor(async () => (await query('story.modal.dialog'))[0]?.visible === false, 5000, 50);
  }
  await navigate('notification');
  await clickTestId('story.notify.btn.success');
  const card = await waitFor(async () => (await query('story.notify.success'))[0] ?? null, 5000, 50);
  await mouseMove(card.rect.x+card.rect.w/2, card.rect.y+card.rect.h/2);
  await ink('basic-notification', 'story.notify.success');
  await clickTestId('story.notify.btn.clear');
  await waitFor(async () => !(await query('story.notify.success')).length, 5000, 50);
});

function pixelAt(png: ReturnType<typeof decodePng>, scale: number, x: number, y: number): number[] {
  const i = (Math.round(y * scale) * png.width + Math.round(x * scale)) * png.channels;
  return [png.pixels[i], png.pixels[i + 1], png.pixels[i + 2]];
}

for (const tier of ['frosted', 'basic']) {
  test(`Windows ${tier} glass keeps GlassGroup member shapes and tints, translucent`, async () => {
    assert(await quality(tier) === tier, `explicit ${tier}`);
    await navigate('glassbox');
    const plain = await waitFor(async () => (await query('story.glassbox.glassbutton'))[0] ?? null, 5000, 50);
    const prominent = await waitFor(async () => (await query('story.glassbox.prominent'))[0] ?? null, 5000, 50);
    const path = `${dir}/${tier}-glass-group.png`;
    await screenshot(path);
    const png = decodePng(path), root = await tree();
    const scale = png.width / root.rect.w;
    // Capsule members: the bounding-box corner lies outside the shape, so the
    // background gradient shows there; inside, a light translucent material.
    const r = plain.rect;
    const corner = pixelAt(png, scale, r.x + 2, r.y + 2), center = pixelAt(png, scale, r.x + r.w / 2, r.y + r.h - 4);
    appendLog(`${tier} plain corner=${corner} center=${center} rect=${JSON.stringify(r)}`);
    const luma = (c: number[]) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    const gray = (c: number[]) => Math.max(...c) - Math.min(...c) < 12 && c[0] > 200;
    assert(!gray(corner), `capsule corner must not be filled (member shape lost): ${corner}`);
    assert(luma(center) > luma(corner) + 40, `member material should lighten the backdrop: ${center} vs ${corner}`);
    assert(center.some((v) => Math.abs(v - 247) > 3), `${tier} material must stay translucent (opaque only for Reduce Transparency): ${center}`);
    // Tinted .glassProminent keeps its tint (white label stays readable).
    const p = prominent.rect;
    const tinted = pixelAt(png, scale, p.x + 6, p.y + p.h / 2);
    appendLog(`${tier} prominent=${tinted} rect=${JSON.stringify(p)}`);
    assert(tinted[2] > tinted[0] + 80, `prominent member should keep its blue tint: ${tinted}`);
  });
}

test('Windows full-to-basic invalidates material caches and failed blur degrades automatically', async () => {
  assert(await quality('full') === 'full', 'full override on software');
  await navigate('glassislands');
  const full = await ink('full-glass', 'story.glassislands.first.slab', 5000);
  assert(await quality('basic') === 'basic', 'switch to basic');
  const basic = await ink('switched-basic-glass', 'story.glassislands.first.slab', 5000);
  assert(full.width===basic.width && full.height===basic.height, 'same geometry');
  let changed=0;
  for(let i=0;i<full.pixels.length;i+=full.channels) {
    if(Math.abs(full.pixels[i]-basic.pixels[i])+Math.abs(full.pixels[i+1]-basic.pixels[i+1])+Math.abs(full.pixels[i+2]-basic.pixels[i+2])>30) changed++;
  }
  assert(changed>1000, `quality switch failed to repaint glass: ${changed}`);
  assert(await quality('full') === 'full', 'return to full');
  await quality('fail_blur');
  await waitFor(async () => await quality() === 'basic', 5000, 50);
  await ink('failed-blur-readable', 'story.glassislands.first.slab', 5000);
  await ink('failed-blur-second', 'story.glassislands.second.slab', 5000);
  assert(await quality('full') === 'basic', 'permanent unsupported pipeline must remain degraded');
  await navigate('checkbox');
  await clickTestId('story.checkbox.box');
  await ink('failed-blur-controls', 'story.checkbox.status', 20);
});
run();
