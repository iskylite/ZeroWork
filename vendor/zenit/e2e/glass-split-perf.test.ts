/// Measure real frame rate and per-frame time during Glass Split & Merge transition (frame drop
/// diagnosis).
/// Usage: ZENIT_E2E_TEST_FILE=e2e/glass-split-perf.test.ts bash scripts/run_storybook_e2e.sh
import { clickTestId, sleep, waitForServerReady, mouseMove, stats } from "./client";
import { test, run, assert, appendLog } from "./runner";
test("frame pacing during split/merge", async () => {
  await waitForServerReady();
  await clickTestId("nav.glasssplit"); await sleep(800); await mouseMove(-10, -10); await sleep(500);
  for (const [phase, btn] of [["bar-expand", "story.glasssplit.splitbtn"], ["bar-collapse", "story.glasssplit.splitbtn"], ["card-expand", "story.glasssplit.cardbtn"], ["card-collapse", "story.glasssplit.cardbtn"]] as const) {
    const s0 = await stats();
    const t0 = performance.now();
    await clickTestId(btn);
    const samples: Array<{ t: number; frames: number; cpu: number; gpu: number; total: number }> = [];
    while (performance.now() - t0 < 900) {
      const s = await stats();
      samples.push({ t: performance.now() - t0, frames: Number(s.frame_count) - Number(s0.frame_count), cpu: Number(s.cpu_frame_us), gpu: Number(s.gpu_execute_us), total: Number(s.total_frame_us) });
      await sleep(4);
    }
    const last = samples[samples.length - 1];
    const fps = (last.frames / (last.t / 1000)).toFixed(1);
    const maxCpu = Math.max(...samples.map((s) => s.cpu)), maxGpu = Math.max(...samples.map((s) => s.gpu)), maxTot = Math.max(...samples.map((s) => s.total));
    // Longest period frame count doesn't grow within sampling interval (frame drop / stutter)
    let longest = 0, lastChange = 0, prevFrames = 0;
    for (const s of samples) { if (s.frames !== prevFrames) { longest = Math.max(longest, s.t - lastChange); lastChange = s.t; prevFrames = s.frames; } }
    const s1 = await stats();
    appendLog(`  ${phase}: frames=${last.frames} in ${last.t.toFixed(0)}ms (${fps} fps), longest gap without a new frame=${longest.toFixed(0)}ms, max cpu=${maxCpu}us gpu=${maxGpu}us total=${maxTot}us | p95 cpu=${s1.cpu_p95_us} gpu=${s1.gpu_p95_us} total=${s1.total_p95_us} (n=${s1.timing_samples})`);
    await sleep(900);
  }
  assert(true, "");
});
await run();
