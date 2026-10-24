import { clickAt, mouseMove, screenshot, sleep, tree, waitForServerReady } from "./client";
import { strict as assert } from "node:assert";

type N = Awaited<ReturnType<typeof tree>>;
const out = process.env.ZENIT_SHOT_DIR;
if (!out) throw new Error("ZENIT_SHOT_DIR is required");

const find = (n: N, text: string): N | undefined => {
  if (n.text === text && n.rect.w > 0) return n;
  for (const c of n.children ?? []) {
    const m = find(c, text);
    if (m) return m;
  }
  return undefined;
};
const center = (n: N) => ({ x: n.rect.x + n.rect.w / 2, y: n.rect.y + n.rect.h / 2 });

async function click(label: string) {
  const n = find(await tree(), label);
  if (!n) throw new Error("not found: " + label);
  const c = center(n);
  await clickAt(c.x, c.y);
  await sleep(250);
}

await waitForServerReady(20_000);
await sleep(500);
assert(find(await tree(), "count = 0"));
await screenshot(`${out}/0_initial.png`);
await click("+1");
await screenshot(`${out}/1_after_one.png`);
const t1 = await tree();
assert(find(t1, "count = 1") && find(t1, "doubled = 2") && find(t1, "odd"));
await click("+1");
const t2 = await tree();
assert(find(t2, "count = 2") && find(t2, "even"));
const badge = find(t2, "even")!;
await mouseMove(center(badge).x, center(badge).y);
await sleep(300);
await screenshot(`${out}/2_even_hover.png`);
await mouseMove(5, 5);
await click("Reset");
const t3 = await tree();
assert(find(t3, "count = 0"));
await screenshot(`${out}/3_reset.png`);

console.log(`counter capture: 4 states verified, screenshots in ${out}`);
