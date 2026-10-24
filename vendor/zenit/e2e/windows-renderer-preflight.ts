// Loaded by the VM runner before any suite can register or execute tests.
import { request, stats, waitForServerReady } from "./client";

const expected = process.env.ZENIT_E2E_EXPECT_RENDERER;
if (expected !== "legacy" && expected !== "d3d12" && expected !== "d3d11") {
  throw new Error("Windows renderer preflight requires an explicit expected renderer");
}
// Artifact transfer and first shader initialization happen before the worker
// serves RPC. WAN acceptance can allow more startup time without changing any
// animation, frame or per-test assertion deadline.
const startupMs = Number(process.env.ZENIT_E2E_STARTUP_TIMEOUT_MS ?? "15000");
if (!Number.isFinite(startupMs) || startupMs <= 0 || startupMs > 300000) {
  throw new Error("Invalid Windows startup timeout");
}
await waitForServerReady(startupMs);
const actual = (await stats()).renderer_backend;
console.log(`Windows renderer preflight: expected=${expected}, actual=${actual ?? "unreported"}`);
if (actual !== expected) {
  throw new Error(`Windows renderer mismatch: expected ${expected}, got ${actual ?? "unreported"}; rebuild with the selected --renderer`);
}

// Visual tests declare their quality explicitly; default app launches remain
// adaptive. A software full-effects regression must never silently test basic.
const quality = process.env.ZENIT_E2E_VISUAL_QUALITY;
if (quality) {
  if (!['auto', 'basic', 'full'].includes(quality)) throw new Error('Invalid visual quality');
  const state = await request('POST', '/visual-quality', {mode: quality});
  console.log(`Windows visual quality: requested=${quality}, effective=${state.quality}`);
  if (state.error || (quality !== 'auto' && state.quality !== quality)) throw new Error(`Visual quality mismatch: ${JSON.stringify(state)}`);
}
