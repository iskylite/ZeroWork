/**
 * Run against a freshly built Harness binary with isolated storage and RPC.
 * node e2e/workspace.ts --out /absolute/output [--steps /absolute/steps.json]
 * Optional steps include geometry, capture, click, drag, tab_order and input.
 * Captures are the real Metal surface; native traffic lights need a separate
 * native-window capture. Synthetic keys/IME do not prove a real input method.
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rename, rm, writeFile, open, cp, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  waitForServerReady, waitFor, tree, stats, screenshot, resizeWindow,
  clickTestId, key, type_, query, screenPos, sleep, mouseDown, mouseMove, mouseUp, scrollAt, focused,
} from "../zig-out/share/zenit/harness/client.ts";

type HarnessNode = Awaited<ReturnType<typeof tree>>;
async function visibleNodes(testId: string): Promise<HarnessNode[]> {
  // Production mounts enough retained overlays to exceed the full-tree RPC
  // buffer. Query projects inherited visibility for this bounded subtree.
  const nodes = await query(testId);
  if (!Array.isArray(nodes)) throw new Error(`Cannot query ${testId}: ${JSON.stringify(nodes)}`);
  return nodes.filter(node => node.visible !== false && node.hidden !== true && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0);
}

async function visibleTabOrder(): Promise<string[]> {
  const tabs: HarnessNode[] = [];
  const visit = (node: HarnessNode, parentVisible: boolean) => {
    const visible = parentVisible && node.visible !== false;
    if (visible && /^tabs\.tab\.[0-9]+$/.test(node.test_id ?? "") && node.rect.w > 0 && node.rect.h > 0) tabs.push(node);
    for (const child of node.children ?? []) visit(child, visible);
  };
  visit(await tree(), true);
  return tabs.sort((a, b) => a.rect.x - b.rect.x).map((node) => node.test_id!);
}

type Step =
  | { action: "resize"; width: number; height: number }
  | { action: "size"; width: number; height: number }
  | { action: "bounds"; test_id: string; x: number; y: number; width: number; height: number }
  | { action: "rect"; test_id: string; x: number; y: number; width: number; height: number }
  | { action: "capture"; name: string }
  | { action: "click"; test_id: string }
  | { action: "hover"; test_id: string }
  | { action: "scroll"; test_id: string; dy: number }
  | { action: "focused"; test_id: string }
  | { action: "drag"; test_id: string; to_test_id: string; edge: "before" | "after"; cancel?: boolean }
  | { action: "tab_order"; test_ids: string[] }
  | { action: "block_config_save" }
  | { action: "key"; name: string; mods?: { cmd?: boolean; ctrl?: boolean; alt?: boolean; shift?: boolean } }
  | { action: "type"; text: string }
  | { action: "visible"; test_id: string }
  | { action: "hidden"; test_id: string }
  | { action: "text"; test_id: string; text: string };

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("node e2e/workspace.ts [--binary PATH] [--out DIR] [--steps JSON_FILE]");
  process.exit(0);
}
const options: Record<string, string> = {};
for (let index = 0; index < args.length; index += 2) {
  if (!["--binary", "--out", "--steps", "--fixture-dir"].includes(args[index]) || !args[index + 1]) throw new Error(`Invalid option ${args[index]}`);
  options[args[index]] = args[index + 1];
}
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const output = resolve(options["--out"] ?? join(root, `dist/ui-acceptance/harness-${Date.now()}`));
const steps: Step[] = options["--steps"]
  ? JSON.parse(await readFile(resolve(options["--steps"]), "utf8"))
  : [
      { action: "resize", width: 1440, height: 900 },
      { action: "capture", name: "default" },
      { action: "resize", width: 860, height: 480 },
      { action: "capture", name: "compact" },
      { action: "resize", width: 640, height: 360 },
      { action: "size", width: 860, height: 480 },
      { action: "capture", name: "minimum-clamped" },
      { action: "resize", width: 1440, height: 900 },
    ];
if (!Array.isArray(steps)) throw new Error("Steps must be a JSON array");
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
await mkdir(output, { recursive: true });
// Native data safety rejects symlink ancestors (macOS /var and /tmp aliases).
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zerowork-harness-")));
const rpc = join(isolated, "rpc");
const data = join(isolated, "data");
await mkdir(rpc);
await mkdir(data);
if (options["--fixture-dir"]) await cp(resolve(options["--fixture-dir"]), data, { recursive: true });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], {
  cwd: root,
  env: {
    ...process.env,
    ZENIT_E2E_FILE_RPC_DIR: rpc,
    ZENIT_E2E_ISOLATE_POINTER: "1",
    ZENIT_E2E_BACKGROUND: "1",
    ZEROWORK_DATA_DIR: data,
    ZEROWORK_AUTOCONNECT: "0",
  },
  stdio: ["ignore", log.fd, log.fd],
});
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const evidence: Record<string, unknown> = {
  started_at: new Date().toISOString(),
  binary,
  binary_sha256: binaryHash,
  harness_rpc: "isolated file RPC",
  app_storage: "isolated temporary directory",
  entry_point: "src/main.zig",
  steps: [],
  status: "running",
};
const records = evidence.steps as unknown[];
let failure: unknown;
let serverReady = false;
try {
  await waitForServerReady();
  serverReady = true;
  if (launchError) throw launchError;
  for (const step of steps) {
    const record: Record<string, unknown> = { step, status: "running" };
    records.push(record);
    switch (step.action) {
      case "resize": {
        if (!Number.isInteger(step.width) || !Number.isInteger(step.height) || step.width <= 0 || step.height <= 0) throw new Error("Invalid resize dimensions");
        const previousFrame = (await stats()).frame_count;
        const resized = await resizeWindow(step.width, step.height);
        if (!resized.ok) throw new Error("Native resize failed");
        await waitFor(async () => (await stats()).frame_count > previousFrame || null);
        record.actual_root = (await waitFor(async () => (await visibleNodes("workspace.shell"))[0] ?? null)).rect;
        break;
      }
      case "size": {
        const rect = (await waitFor(async () => (await visibleNodes("workspace.shell"))[0] ?? null)).rect;
        if (Math.abs(rect.w - step.width) > 0.5 || Math.abs(rect.h - step.height) > 0.5) throw new Error(`Expected ${step.width}x${step.height}, received ${rect.w}x${rect.h}`);
        record.actual_root = rect;
        break;
      }
      case "bounds": {
        const expected = { x: step.x, y: step.y, w: step.width, h: step.height };
        const actual = await waitFor(async () => {
          const rect = await screenPos(step.test_id);
          return (["x", "y", "w", "h"] as const).every(axis => Math.abs(rect[axis] - expected[axis]) <= 0.5) ? rect : null;
        }, 3000);
        record.actual_rect = actual;
        break;
      }
      case "rect": {
        const expected = { x: step.x, y: step.y, w: step.width, h: step.height };
        const node = await waitFor(async () => {
          const current = (await visibleNodes(step.test_id))[0];
          return current && (["x", "y", "w", "h"] as const).every(axis => Math.abs(current.rect[axis] - expected[axis]) <= 0.5) ? current : null;
        }, 3000);
        record.actual_rect = node.rect;
        break;
      }
      case "capture": {
        if (!/^[A-Za-z0-9_-]+$/.test(step.name)) throw new Error("Capture name must use letters, digits, _ or -");
        // Allow native widget enter/exit transitions to finish before visual evidence.
        await sleep(300);
        const path = join(output, `${step.name}.png`);
        const captured = await screenshot(path);
        if (!captured.ok) throw new Error(`Capture failed: ${step.name}`);
        const nodeTree = await tree();
        await writeFile(join(output, `${step.name}.tree.json`), JSON.stringify(nodeTree, null, 2));
        if (!nodeTree.rect) {
          const bounded = Object.fromEntries(await Promise.all(["workspace.body", "workspace.sidebar.collapsed", "history.panel", "ai.panel", "settings.panel", "tabs.strip", "wizard.steps", "wizard.protocol", "wizard.footer", "wizard.close"].map(async id => [id, await query(id)])));
          await writeFile(join(output, `${step.name}.queries.json`), JSON.stringify(bounded, null, 2));
          record.tree_limit = "Full tree RPC exceeded its buffer; bounded projections saved separately.";
        }
        record.capture = path;
        record.root = nodeTree.rect;
        record.stats = await stats();
        break;
      }
      case "click": {
        let previous = "";
        await waitFor(async () => {
          const node = (await visibleNodes(step.test_id))[0];
          if (!node || (node.effective_opacity ?? 1) < 0.99) return null;
          const position = JSON.stringify(node.rect);
          const stable = position === previous;
          previous = position;
          return stable || null;
        }, 5000);
        const clicked = await clickTestId(step.test_id);
        if (!clicked.ok) throw new Error(`Click failed: ${step.test_id}`);
        break;
      }
      case "scroll": {
        const target = (await visibleNodes(step.test_id))[0];
        if (!target) throw new Error(`Scroll target missing: ${step.test_id}`);
        if (!(await scrollAt(target.rect.x + target.rect.w / 2, target.rect.y + target.rect.h / 2, 0, step.dy)).ok) throw new Error(`Scroll failed: ${step.test_id}`);
        await sleep(300);
        break;
      }
      case "hover": {
        const target = (await visibleNodes(step.test_id))[0];
        if (!target) throw new Error(`Hover target missing: ${step.test_id}`);
        if (!(await mouseMove(target.rect.x + target.rect.w / 2, target.rect.y + target.rect.h / 2)).ok) throw new Error(`Hover failed: ${step.test_id}`);
        await sleep(600);
        break;
      }
      case "focused": {
        await waitFor(async () => {
          const actual = await focused();
          record.actual_focus = actual;
          return actual.test_id === step.test_id || null;
        });
        break;
      }
      case "drag": {
        if (step.test_id === step.to_test_id || !["before", "after"].includes(step.edge)) throw new Error("Drag requires distinct source and destination nodes and an edge");
        const source = (await visibleNodes(step.test_id))[0];
        const target = (await visibleNodes(step.to_test_id))[0];
        if (!source || !target) throw new Error(`Drag node missing: ${step.test_id} -> ${step.to_test_id}`);
        const from = { x: source.rect.x + source.rect.w / 2, y: source.rect.y + source.rect.h / 2 };
        const to = { x: target.rect.x + (step.edge === "before" ? 8 : target.rect.w - 8), y: target.rect.y + target.rect.h / 2 };
        const before = await visibleTabOrder();
        record.order_before = before;
        record.pointer_from = from;
        record.pointer_to = to;
        if (!(await mouseDown(from.x, from.y)).ok) throw new Error("Drag pointer down failed");
        try {
          for (let sample = 1; sample <= 12; sample++) {
            const fraction = sample / 12;
            if (!(await mouseMove(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction)).ok) throw new Error("Drag pointer move failed");
            await sleep(16);
          }
          await waitFor(async () => {
            const during = await visibleTabOrder();
            record.order_during = during;
            return JSON.stringify(during) !== JSON.stringify(before) || null;
          });
          if (step.cancel && !(await key("escape")).ok) throw new Error("Drag Escape failed");
        } finally {
          if (!(await mouseUp(to.x, to.y)).ok) throw new Error("Drag pointer up failed");
        }
        record.order_after = await visibleTabOrder();
        break;
      }
      case "tab_order": {
        await waitFor(async () => {
          const actual = await visibleTabOrder();
          record.actual_order = actual;
          return JSON.stringify(actual) === JSON.stringify(step.test_ids) || null;
        });
        break;
      }
      case "block_config_save": {
        // This runner created `data` for this PID. Never touch default storage.
        try {
          await rename(join(data, "config.toml"), join(data, "config-before-failure.toml"));
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        await mkdir(join(data, "config.toml"));
        record.config_save = "blocked by a directory at the isolated config.toml path";
        break;
      }
      case "key":
        if (!(await key(step.name, step.mods)).ok) throw new Error(`Key failed: ${step.name}`);
        break;
      case "type":
        if (!(await type_(step.text)).ok) throw new Error("Text input failed");
        break;
      case "visible": {
        await waitFor(async () => {
          return (await visibleNodes(step.test_id)).length > 0 || null;
        });
        break;
      }
      case "hidden": {
        await waitFor(async () => {
          return (await visibleNodes(step.test_id)).length === 0 || null;
        });
        break;
      }
      case "text": {
        const matches = (node: HarnessNode): boolean =>
          node.visible !== false && node.hidden !== true && (node.effective_opacity ?? 1) > 0 &&
          (node.text === step.text || (node.children ?? []).some(matches));
        await waitFor(async () => (await visibleNodes(step.test_id)).some(matches) || null);
        break;
      }
      default:
        throw new Error(`Unknown action ${JSON.stringify(step)}`);
    }
    record.status = "passed";
  }
  evidence.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  evidence.status = "failed";
  evidence.error = String(failure);
  if (serverReady && child.exitCode === null && child.signalCode === null) {
    const diagnostics = await Promise.allSettled([
      screenshot(join(output, "failure.png")),
      tree().then((value) => writeFile(join(output, "failure.tree.json"), JSON.stringify(value, null, 2))),
    ]);
    evidence.failure_diagnostics = diagnostics.map((result) => result.status);
  }
  if (records.length > 0) (records[records.length - 1] as Record<string, unknown>).status = "failed";
} finally {
  // This runner owns only this PID. Termination is test cleanup, not evidence
  // that the application's normal close/resource lifecycle passed acceptance.
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await ended;
  }
  evidence.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  evidence.finished_at = new Date().toISOString();
  await writeFile(join(output, "harness-report.json"), JSON.stringify(evidence, null, 2));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${evidence.status}: ${join(output, "harness-report.json")}`);
if (failure) throw failure;
