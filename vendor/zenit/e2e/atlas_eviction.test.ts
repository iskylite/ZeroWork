import { clickTestId, health, query, screenshot, sleep, tree, request, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";

test("atlas eviction OOM: live glyphs rerasterize and keep identical pixels", async () => {
  await waitForServerReady();
  await clickTestId("nav.emoji");
  await sleep(700);
  const node = (await query("story.emoji.control"))[0];
  assert(node != null && node.rect.w > 10, "grayscale control was not laid out");
  const root = await tree();
  const dir = getSessionDir();
  const beforePath = `${dir}/atlas-before.png`;
  const afterPath = `${dir}/atlas-after.png`;
  assert((await screenshot(beforePath)).ok === true, "baseline screenshot failed");
  const injected = await request("POST", "/review/atlas-eviction-oom", {});
  appendLog(`fault: ${JSON.stringify(injected)}`);
  await sleep(300);
  assert((await screenshot(afterPath)).ok === true, "recovery screenshot failed");
  const before = decodePng(beforePath);
  const after = decodePng(afterPath);
  const scale = before.width / root.rect.w;
  assert(before.width === after.width && before.height === after.height, "capture dimensions changed");
  const x0 = Math.max(0, Math.floor(node.rect.x * scale));
  const y0 = Math.max(0, Math.floor(node.rect.y * scale));
  const x1 = Math.min(before.width, Math.ceil((node.rect.x + node.rect.w) * scale));
  const y1 = Math.min(before.height, Math.ceil((node.rect.y + node.rect.h) * scale));
  let different = 0, ink = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const a = (y * before.width + x) * before.channels;
    const b = (y * after.width + x) * after.channels;
    if (before.pixels[a] < 200 && before.pixels[a + 1] < 200 && before.pixels[a + 2] < 200) ink++;
    if ([0, 1, 2].some(c => before.pixels[a + c] !== after.pixels[b + c])) different++;
  }
  appendLog(`baseline_ink=${ink} changed_pixels=${different}`);
  assert(ink > 100, "baseline contained no useful glyph ink");
  assert(injected.victim_entries > 0 && injected.pages_after === injected.pages_before - 1,
    "fixture did not evict the populated glyph page");
  assert(injected.stale_entries === 0, `eviction left ${injected.stale_entries} stale glyph regions`);
  assert(different === 0, `glyph pixels changed after OOM eviction: ${different}`);
  assert((await health()).status === "ok", "app died during atlas recovery");
});

run();
