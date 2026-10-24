// Survey every story the way the website frames it (zenit site scripts/zenit/capture.ts): the
// story root (first sized child of `story.<key>`) padded 28 px, at least 440 wide, inside the
// panel. Writes one window screenshot per story plus survey.json (panel / root rects, the root's
// first child and its text), for contact sheets before and after Storybook layout changes.
//   ZENIT_E2E_TEST_FILE=e2e/story-survey.test.ts ZENIT_SURVEY_OUT=<dir> [ZENIT_SURVEY_KEYS=a,b]
// No thresholds.
import { writeFileSync, mkdirSync } from "node:fs";
import { clickTestId, key, mouseMove, query, screenshot, sleep, stats, waitFor, waitForServerReady } from "./client";

const out = process.env.ZENIT_SURVEY_OUT!;
mkdirSync(out, { recursive: true });
await waitForServerReady();
await sleep(1500);
const keys = (process.env.ZENIT_SURVEY_KEYS ?? "").split(",").filter(Boolean);
const textOf = (n: any, depth = 0): string => {
  if (!n || depth > 3) return "";
  if (n.text?.trim()) return n.text.trim();
  for (const c of n.children ?? []) {
    const t = textOf(c, depth + 1);
    if (t) return t;
  }
  return "";
};
const rows: any[] = [];
for (const k of keys) {
  await mouseMove(-10, -10);
  for (let i = 0; i < 3; i++) await key("escape");
  await clickTestId(`nav.${k}`);
  await waitFor(async () => ((await query(`story.${k}`))[0]?.rect.w ?? 0) > 100 || null, 8000, 60);
  await sleep(700);
  const panel = (await query(`story.${k}`))[0];
  const root = (panel?.children ?? []).find((c: any) => c.visible !== false && c.rect && c.rect.w > 1 && c.rect.h > 1);
  const first = (root?.children ?? []).find((c: any) => c.visible !== false && c.rect && c.rect.w > 1 && c.rect.h > 1);
  await screenshot(`${out}/${k}.png`);
  rows.push({ key: k, panel: panel?.rect, root: root?.rect, first: first?.rect, first_text: textOf(first).slice(0, 160) });
}
const st = await stats();
writeFileSync(`${out}/survey.json`, JSON.stringify({ window_scale: st.window_scale, rows }, null, 1));
console.log(`surveyed ${rows.length} stories -> ${out}`);
