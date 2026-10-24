import { clickTestId, query, stats, waitFor, waitForServerReady } from "./client";
import { assert, run, test } from "./runner";

// Measurement probe (log only): where does opening a glass story spend its
// time? Cold launch (empty DXBC cache) vs warm is read off the app log:
// "[d3d12] HLSL compile ..." and "[glass] first-use pipeline build ...".
async function openStory(key: string) {
  const t0 = Date.now();
  const before = await stats();
  assert((await clickTestId(`nav.${key}`)).ok, `click nav.${key}`);
  const tClick = Date.now();
  await waitFor(async () => ((await query(`story.${key}`))[0]?.rect?.h ?? 0) > 0 ? true : null, 60000, 20);
  const tVisible = Date.now();
  await waitFor(async () => (await stats()).frame_count > before.frame_count + 2 ? true : null, 60000, 20);
  const after = await stats();
  console.log(`  ${key}: click rpc=${tClick - t0}ms, story in tree=${tVisible - t0}ms, 3 frames rendered=${Date.now() - t0}ms, frames ${before.frame_count}->${after.frame_count}`);
}

test("first glass story open time", async () => {
  await waitForServerReady(15000);
  console.log(`  renderer=${(await stats()).renderer_backend}`);
  await openStory("button");
  await openStory("glassbox");
  await openStory("glasslab");
  await openStory("glassbox");
});

run();
