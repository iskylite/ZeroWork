// Capture the iOS slider / switch knobs (story glasscontrolsios) at rest and held, with the
// stage rect, for comparison with the ios GlassProbe `switches` scene. Launch with
// ZENIT_STORYBOOK_STORY=glasscontrolsios ZENIT_E2E_TEST_FILE=e2e/knob-lens-capture.test.ts
// ZENIT_KNOB_OUT=<dir>. No thresholds: the comparison is offline.
import { writeFileSync, mkdirSync } from "node:fs";
import { query, screenshot, waitForServerReady, sleep, stats, mouseDown, mouseUp } from "./client";
const out = process.env.ZENIT_KNOB_OUT!;
mkdirSync(out, { recursive: true });
await waitForServerReady();
await sleep(2000);
const stage = (await query("story.glasscontrolsios.stage"))[0];
if (!stage) throw new Error("stage missing");
const st = await stats();
const shots: Record<string, string> = {};
const knobs: Record<string, unknown> = {};
async function shot(name: string) {
  const path = `${out}/${name}.png`;
  const r = await screenshot(path);
  if (r.ok !== true) throw new Error(`capture ${name} failed`);
  shots[name] = path;
}
await shot("rest");
// held: stage-local knob centres (on switch knob 132,60; slider thumb 201,180)
for (const [name, x, y] of [["slider", 201, 180], ["switch", 132, 60]] as const) {
  await mouseDown(stage.rect.x + x, stage.rect.y + y);
  await sleep(900);
  await shot(`held_${name}`);
  // the held knob's rect
  knobs[name] = (await query(name === "switch" ? "story.glasscontrolsios.on.knob" : "story.glasscontrolsios.slider.knob"))[0]?.rect;
  await mouseUp(stage.rect.x + x, stage.rect.y + y);
  await sleep(900);
}
writeFileSync(`${out}/meta.json`, JSON.stringify({ window_scale: st.window_scale, stage: stage.rect, shots, knobs }, null, 2));
console.log(`captured ${out}`);
