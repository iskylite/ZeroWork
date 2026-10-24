import { stats, waitForServerReady } from "./client";
import { run, test } from "./runner";

// Manual acceptance hold: keeps the Windows app open on the worker machine so a
// person can drive it. The "test" ends when the app window is closed (the
// harness stops answering) or shortly before the suite deadline
// (ZENIT_E2E_SUITE_TIMEOUT_MS), whichever comes first. It never asserts on the UI.
test("Windows manual acceptance: keep the app open until its window is closed", async () => {
  await waitForServerReady(15000);
  const suiteTimeoutMs = Number(process.env.ZENIT_E2E_SUITE_TIMEOUT_MS ?? "900000");
  const holdMs = Math.max(60_000, suiteTimeoutMs - 30_000);
  const started = Date.now();
  console.log(`\n  App is open for manual acceptance. Close its window to finish; auto-ends in ${Math.round(holdMs / 60_000)} min.`);
  while (Date.now() - started < holdMs) {
    try {
      await stats();
    } catch {
      console.log(`  window closed after ${Math.round((Date.now() - started) / 1000)}s; manual hold finished`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  console.log("  manual hold reached its time limit; finishing");
});

run();
