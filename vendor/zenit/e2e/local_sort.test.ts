import { query, request, screenshot, sleep, tree, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";
test("local sort: spread shadows cover earlier images and later images cover wide glyph ink", async () => {
  await waitForServerReady();
  assert((await request("POST", "/review/local-sort-scene", {})).mounted, "fixture mount failed");
  await sleep(500);
  const path = `${getSessionDir()}/order.png`;
  assert((await screenshot(path)).ok, "capture failed");
  const png = decodePng(path), scale = png.width / (await tree()).rect.w;
  const shadow = (await query("review.sort.shadow-image"))[0];
  const cover = (await query("review.sort.text-image"))[0];
  assert(shadow?.rect.w > 0 && cover?.rect.w > 0, "probe nodes not laid out");
  const at = (x: number, y: number) => {
    const i = (Math.floor(y * scale) * png.width + Math.floor(x * scale)) * png.channels;
    return [png.pixels[i], png.pixels[i+1], png.pixels[i+2]];
  };
  const rgb = at(shadow.rect.x + shadow.rect.w/2, shadow.rect.y + shadow.rect.h/2);
  let obscured = 0, sampled = 0;
  for (let y = cover.rect.y+2; y < cover.rect.y+cover.rect.h-2; y++)
    for (let x = cover.rect.x+2; x < cover.rect.x+cover.rect.w-2; x++) {
      const c = at(x, y); sampled++;
      if (c[0] > 20 || c[1] > 20 || c[2] < 220) obscured++;
    }
  appendLog(`shadow_rgb=${rgb.join(",")} later_image_obscured=${obscured}/${sampled}`);
  assert(Math.max(...rgb) < 40, `spread shadow reordered below image: rgb=${rgb}`);
  assert(obscured === 0, `wide glyphs reordered above later image: ${obscured} samples`);
});
run();
