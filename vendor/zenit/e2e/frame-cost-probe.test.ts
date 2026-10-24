// Frame-cost probe for hardware acceptance and before/after comparisons (not a
// CI gate): ZENIT_E2E_TEST_FILE=e2e/frame-cost-probe.test.ts, optionally
// ZENIT_PERF_QUALITY=full|frosted|basic and ZENIT_PERF_ONLY=story,story.
// Each scene renders continuously with the whole tree dirtied (/redraw), so the
// numbers are a steady full-repaint load independent of input and driver latency.
import { clickTestId, mouseMove, request, resetTiming, sleep, stats, waitForServerReady } from "./client";
import { appendLog, run, test } from "./runner";

const scenes: { story: string; before?: () => Promise<unknown> }[] = [
  { story: "button" },
  { story: "table" },
  { story: "markdown" },
  { story: "virtuallist" },
  { story: "glassbox" },
  { story: "glasslab" },
  { story: "glassmerge" },
  { story: "glassgroup" },
  { story: "notification", before: () => clickTestId("story.notify.btn.burst") },
];

test("frame cost per scene", async () => {
  await waitForServerReady(60000);
  const quality = process.env.ZENIT_PERF_QUALITY;
  if (quality) await request("POST", "/visual-quality", { mode: quality });
  const only = process.env.ZENIT_PERF_ONLY?.split(",");
  for (const scene of scenes) {
    if (only && !only.includes(scene.story)) continue;
    const nav = await clickTestId(`nav.${scene.story}`).catch(() => null) as any;
    if (!nav || nav.ok === false) { const line = `PERF ${scene.story.padEnd(13)} (story absent)`; appendLog(line); console.log(line); continue; }
    await mouseMove(-10, -10);
    await sleep(1500);
    if (scene.before) await scene.before();
    const on = await request("POST", "/redraw", { continuous: true });
    if ((on as any).error) throw new Error(`continuous redraw unsupported: ${JSON.stringify(on)}`);
    await sleep(1000);
    await resetTiming();
    const f0 = (await stats()).frame_count;
    const t0 = Date.now();
    const parts: Record<string, number[]> = {};
    const keys = ["layout_us", "render_gen_us", "gpu_encode_us", "acquire_texture_us", "flush_us", "cpu_frame_us", "encode_us", "wait_for_frame_us", "total_frame_us", "gpu_execute_us", "glass_count", "glass_us", "texture_creates", "render_passes", "blit_passes", "pass_native_us"];
    while (Date.now() - t0 < 4000) {
      const p = await stats() as any;
      for (const k of keys) if (typeof p[k] === "number") (parts[k] ??= []).push(p[k]);
      await sleep(100);
    }
    const s = await stats();
    const med = (v: number[], k = "") => v.length ? [...v].sort((a, b) => a - b)[v.length >> 1] / (/_us$/.test(k) ? 1000 : 1) : NaN;
    const breakdown = keys.filter((k) => parts[k]).map((k) => `${k.replace(/_us$/, "")}=${med(parts[k], k).toFixed(2)}`).join(" ");
    await request("POST", "/redraw", { continuous: false });
    const seconds = (Date.now() - t0) / 1000;
    const line = `PERF ${(quality ?? "auto").padEnd(7)} ${scene.story.padEnd(13)} fps=${((s.frame_count - f0) / seconds).toFixed(1).padStart(5)} ` +
      `total_p95=${(s.total_p95_us / 1000).toFixed(2)}ms cpu_p95=${(s.cpu_p95_us / 1000).toFixed(2)}ms ` +
      `gpu_p95=${(s.gpu_p95_us / 1000).toFixed(2)}ms samples=${s.timing_samples}`;
    appendLog(line);
    console.log(line);
    console.log(`PARTS ${scene.story.padEnd(13)} ${breakdown}`);
  }
});

await run();
