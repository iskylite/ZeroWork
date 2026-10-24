/// storybook-shots.capture.ts: one screenshot per story for pixel diffs before / after rewrites.
///
/// Environment: ZENIT_SHOT_DIR (output dir, required), ZENIT_SHOT_KEYS (comma-separated keys,
/// default all). Also exports each story subtree's node tree (without ids) as <key>.tree.json,
/// to tell 'pixel changed' from 'structure changed'. Driver: scripts/storybook_pixel_diff.sh.
import { clickTestId, key, mouseMove, query, screenshot, sleep, waitForServerReady } from "./client";
import { readFileSync } from "node:fs";

const out = process.env.ZENIT_SHOT_DIR;
if (!out) throw new Error("ZENIT_SHOT_DIR is required");

const main = readFileSync(new URL("../examples/storybook/main.zig", import.meta.url), "utf8");
const all = [...main.matchAll(/\.key = "([a-z0-9_]+)"/g)].map((m) => m[1]);
const keys = process.env.ZENIT_SHOT_KEYS ? process.env.ZENIT_SHOT_KEYS.split(",") : all;

await waitForServerReady(20_000);
await sleep(500);
const failed: string[] = [];
for (const k of keys) {
  await mouseMove(-10, -10);
  for (let i = 0; i < 3; i++) await key("escape");
  const click = await clickTestId(`nav.${k}`);
  if (!click.ok) {
    failed.push(k);
    continue;
  }
  await sleep(700);
  await screenshot(`${out}/${k}.png`);
  const q = await query(`story.${k}`);
  const strip = (_: string, v: unknown) => (_ === "id" || _ === "node_id" ? undefined : v);
  await Bun.write(`${out}/${k}.tree.json`, JSON.stringify(q[0] ?? null, strip));
}
console.log(`storybook shots: ${keys.length - failed.length}/${keys.length} captured in ${out}`);
if (failed.length) {
  console.log(`nav failed: ${failed.join(",")}`);
  process.exit(1);
}
