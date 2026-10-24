import { health, query, request, screenshot, sleep, tree, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";
test("retained frame: abandoned GPU work cannot publish new cached contents", async () => {
  await waitForServerReady();
  assert((await request("POST", "/review/retained-mount", {})).mounted, "mount failed");
  await sleep(500);
  const node = (await query("review.retained.layer"))[0];
  assert(node?.rect.w > 10, "retained node missing");
  const dir = getSessionDir(), before = `${dir}/before.png`, after = `${dir}/after.png`;
  const pixel = async (path: string) => {
    assert((await screenshot(path)).ok, "capture failed");
    const png = decodePng(path), s = png.width / (await tree()).rect.w;
    const i = (Math.floor((node.rect.y+node.rect.h/2)*s)*png.width+Math.floor((node.rect.x+node.rect.w/2)*s))*png.channels;
    return [png.pixels[i], png.pixels[i+1], png.pixels[i+2]];
  };
  const initial = await pixel(before);
  assert(initial[1] > 240 && initial[0] < 20, `baseline was not green: ${initial}`);
  const fault = await request("POST", "/review/retained-frame-failure", {});
  await sleep(500);
  const recovered = await pixel(after);
  appendLog(`fault: ${JSON.stringify(fault)} before=${initial} after=${recovered}`);
  assert(fault.failure === "InjectedFrameFailure", "frame did not fail after encoding");
  assert(fault.uncommitted_cache_entries === 0, "unsubmitted layer was marked primed");
  assert(recovered[0] > 240 && recovered[1] < 20, `retry reused old green pixels: ${recovered}`);
  assert((await health()).status === "ok", "app died after failed frame retry");
});
run();
