// Frame series of an iOS switch tap (story glasscontrolsios) on a locked 60 Hz clock: press the
// off switch's knob, release after 50 ms (the native probe's tap), then a screenshot every 50 ms
// for a second. Launch with ZENIT_STORYBOOK_STORY=glasscontrolsios
// ZENIT_E2E_TEST_FILE=e2e/toggle-tap-capture.test.ts ZENIT_TAP_OUT=<dir>. No thresholds.
import { writeFileSync, mkdirSync } from "node:fs";
import { query, screenshot, waitForServerReady, sleep, mouseMove, mouseDown, mouseUp, request, stats } from "./client";
const out = process.env.ZENIT_TAP_OUT!;
mkdirSync(out, { recursive: true });
await waitForServerReady();
await sleep(1500);
const stage = (await query("story.glasscontrolsios.stage"))[0];
if (!stage) throw new Error("stage missing");
const STEP = 1000 / 60;
const r = await request("POST", "/clock", { step_ms: STEP, locked: true });
if (r.error) throw new Error(`clock: ${JSON.stringify(r)}`);
const advance = async (ms: number) => {
  const a = await request("POST", "/clock/advance", { ms });
  if (a.error) throw new Error(`advance: ${JSON.stringify(a)}`);
  for (let i = 0; i < 2000 && ((await request("GET", "/stats")) as any).clock_budget_ms > 0; i++) await sleep(5);
};
await advance(STEP * 6);
const x = stage.rect.x + 270.5, y = stage.rect.y + 60;
await mouseMove(x, y);
await mouseDown(x, y);
await advance(50);
await mouseUp(x, y);
const shots: Array<{ t: number; path: string }> = [];
for (let k = 0; k <= 20; k++) {
  const path = `${out}/f_${String(k).padStart(2, "0")}.png`;
  const s = await screenshot(path);
  if (s.ok !== true) throw new Error("capture failed");
  shots.push({ t: k * 50, path });
  await advance(50);
}
const st = await stats();
writeFileSync(`${out}/meta.json`, JSON.stringify({ window_scale: st.window_scale, stage: stage.rect, shots }, null, 2));
console.log(`captured ${out}`);
