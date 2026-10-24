/**
 * e2e/mock.ts: embedded mock HTTP service (runner runs in-process, no separate process).
 *
 * Implements docs/internal/UI_AUTOMATION_PLAN.md section 5:
 * - Per-case atomic override activation (setCaseOverrides)
 * - Matching by method + path (query/headers/body matching and sequence matching deferred to P1)
 * - Request audit: count / order / unmatched (for assert:requests and failure detection)
 * - Fixtures: body_file resolved relative to scenario file
 * - delay_ms props up loading state
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface MockResponse {
  status: number;
  body_file?: string;
  body_json?: unknown;
  body_text?: string;
  delay_ms?: number;
}

export interface MockDef {
  name: string;
  request: { method: string; path: string };
  response: MockResponse;
}

export interface MockAudit {
  counts: Record<string, number>;
  order: string[];
  unmatched: Array<{ method: string; path: string }>;
}

export interface MockServer {
  url: string;
  port: number;
  setCaseOverrides(overrides: Record<string, MockResponse>): void;
  getAudit(): MockAudit;
  resetAudit(): void;
  stop(): void;
}

export function startMockServer(mocks: MockDef[], scenarioDir: string): MockServer {
  const byKey = new Map<string, MockDef>();
  for (const m of mocks) byKey.set(`${m.request.method} ${m.request.path}`, m);

  let overrides: Record<string, MockResponse> = {};
  const counts: Record<string, number> = {};
  const order: string[] = [];
  const unmatched: Array<{ method: string; path: string }> = [];

  const server = Bun.serve({
    port: 0, // Random port to avoid concurrent conflicts
    async fetch(req) {
      const url = new URL(req.url);
      const key = `${req.method} ${url.pathname}`;
      const mock = byKey.get(key);
      if (!mock) {
        unmatched.push({ method: req.method, path: url.pathname });
        return new Response(
          JSON.stringify({ error: "unmatched mock request", method: req.method, path: url.pathname }),
          { status: 404, headers: { "content-type": "application/json" } },
        );
      }
      counts[mock.name] = (counts[mock.name] ?? 0) + 1;
      order.push(mock.name);
      const resp = overrides[mock.name] ?? mock.response;
      if (resp.delay_ms) await Bun.sleep(resp.delay_ms);
      const body = resolveBody(resp, scenarioDir);
      const headers: Record<string, string> = {};
      if (body !== undefined && (resp.body_file !== undefined || resp.body_json !== undefined)) {
        headers["content-type"] = "application/json";
      }
      return new Response(body ?? null, { status: resp.status, headers });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    port: server.port,
    setCaseOverrides(o) {
      overrides = o;
    },
    getAudit() {
      return { counts, order, unmatched };
    },
    resetAudit() {
      for (const k of Object.keys(counts)) delete counts[k];
      order.length = 0;
      unmatched.length = 0;
    },
    stop() {
      server.stop(true);
    },
  };
}

function resolveBody(resp: MockResponse, scenarioDir: string): string | undefined {
  if (resp.body_file !== undefined) return readFileSync(resolve(scenarioDir, resp.body_file), "utf8");
  if (resp.body_json !== undefined) return JSON.stringify(resp.body_json);
  if (resp.body_text !== undefined) return resp.body_text;
  return undefined;
}

// ── self-test ──

async function selfTest(): Promise<void> {
  const mocks: MockDef[] = [
    { name: "users", request: { method: "GET", path: "/api/users" }, response: { status: 200, body_json: { users: ["a"] } } },
    { name: "slow", request: { method: "GET", path: "/api/slow" }, response: { status: 200, body_text: "ok", delay_ms: 30 } },
  ];
  const srv = startMockServer(mocks, process.cwd());

  // 1. Default match
  const r1 = await fetch(`${srv.url}/api/users`);
  const j1 = (await r1.json()) as { users: string[] };
  if (r1.status !== 200 || j1.users[0] !== "a") throw new Error("default mock failed");

  // 2. Case override
  srv.setCaseOverrides({ users: { status: 200, body_json: { users: [] } } });
  const r2 = await fetch(`${srv.url}/api/users`);
  const j2 = (await r2.json()) as { users: string[] };
  if (j2.users.length !== 0) throw new Error("override mock failed");

  // 3. No match -> 404 + audit
  const r3 = await fetch(`${srv.url}/api/nope`);
  if (r3.status !== 404) throw new Error("unmatched should be 404");
  const audit = srv.getAudit();
  if (audit.counts["users"] !== 2 || audit.order.join(",") !== "users,users" || audit.unmatched.length !== 1) {
    throw new Error(`audit failed: ${JSON.stringify(audit)}`);
  }

  // 4. resetAudit clears
  srv.resetAudit();
  if (srv.getAudit().counts["users"] !== undefined || srv.getAudit().order.length !== 0) {
    throw new Error("resetAudit failed");
  }

  // 5. delay_ms takes effect
  const t0 = Date.now();
  await (await fetch(`${srv.url}/api/slow`)).text();
  if (Date.now() - t0 < 25) throw new Error("delay_ms not honored");

  srv.stop();
  console.log("mock self-test: PASS");
}

if (import.meta.main) selfTest().catch((e) => {
  console.error("mock self-test FAIL:", e?.message ?? e);
  process.exit(1);
});
