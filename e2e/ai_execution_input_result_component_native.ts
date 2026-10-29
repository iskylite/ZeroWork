/** Production Store → native cards with synthetic input receipts; no PTY/provider. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, open, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const prefix = resolve(process.argv[2] ?? '/tmp/zw-execution-input-projection-component');
const out = resolve(process.argv[3] ?? '/tmp/zw-execution-input-projection-native');
const binary = join(prefix, 'bin/execution-result-preview');
await mkdir(out, { recursive: true });
const text = (n: any): string => n.text ?? (n.children ?? []).map(text).join('');
const find = (n: any, id: string): any => n.test_id === id ? n : (n.children ?? []).map((c: any) => find(c, id)).find(Boolean);
const visible = (n: any) => n && n.visible !== false && n.hidden !== true && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const card = (id: string) => h.waitFor(async () => (await h.query(id)).find(visible) ?? null, 10000);
const report: any = { status: 'running', binary, sha256: createHash('sha256').update(await readFile(binary)).digest('hex'), checks: [], shutdown: [], limits: ['Isolated production projection/Store/view with synthetic immutable receipts. No command, secret, PTY, provider, or main App was exercised.'] };
try {
    for (const theme of ['dark', 'light', 'sauber']) for (const width of [600, 360]) for (const state of theme === 'dark' && width === 600 ? ['input_consumed', 'input_unknown'] : ['input_consumed']) {
        const name = `${theme}-${width}-${state}`;
        const rpc = await mkdtemp('/tmp/zw-input-result-rpc-');
        process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
        const log = await open(join(out, `${name}.log`), 'w');
        const app = spawn(binary, [`--theme=${theme}`, `--state=${state}`], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' }, stdio: ['ignore', log.fd, log.fd] });
        const ended = new Promise<any>(done => app.once('exit', (code, signal) => done({ code, signal })));
        try {
            await h.waitForServerReady(10000);
            assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), app.pid);
            await h.resizeWindow(width, 560);
            const execution = await card('execution_result.preview.card');
            const input = await card('execution_result.preview.input_card');
            assert.equal(text(find(execution, 'ai.execution.result.summary')), '最近观测 · 前台已结束 · 观测片段已保存');
            assert.equal(text(find(execution, 'ai.execution.result.process')), '前台已结束 · 退出码 0');
            assert.equal(text(find(execution, 'ai.execution.result.output_scope')), '同一终端观测片段 · 已保存');
            assert(text(find(execution, 'ai.execution.result.terminal_output')).includes('ACTUAL_TERMINAL_OUTPUT'));
            assert.equal(text(find(input, 'ai.execution.result.summary')), state === 'input_unknown' ? '输入结果 · 输入结果待核实' : '输入结果 · 输入已消费');
            assert.equal(text(find(input, 'ai.execution.result.input_type')), '输入类型 · 宿主安全输入');
            assert.equal(text(find(input, 'ai.execution.result.input_sequence')), '输入序号 5 · 等待序号 3');
            assert.equal(Boolean(find(input, 'ai.execution.result.failure')), state === 'input_unknown');
            for (const id of ['process', 'terminal_output', 'output_label', 'copy_output', 'copy_command', 'stop', 'takeover', 'view_terminal']) assert(!find(input, `ai.execution.result.${id}`), id);
            const title = find(input, 'ai.execution.result.title').rect, icon = find(input, 'ai.execution.result.icon').rect;
            assert(Math.abs(icon.y + icon.h / 2 - title.y - title.h / 2) < .5 && icon.x + icon.w < title.x);
            assert(input.rect.x >= 0 && input.rect.x + input.rect.w <= width + .1 && input.rect.y + input.rect.h <= 560);
            const header = find(input, 'ai.execution.result.header').rect;
            await h.clickAt(header.x + 20, header.y + header.h / 2);
            await h.waitFor(async () => (await card('execution_result.preview.input_card')).rect.h <= 32.1 || null, 5000);
            await h.clickAt(header.x + 20, header.y + header.h / 2);
            await h.waitFor(async () => {
                const current = await card('execution_result.preview.input_card');
                return Math.abs(current.rect.h - 32 - find(current, 'ai.execution.result.details').rect.h) < .1 || null;
            }, 5000);
            await h.mouseMove(1, 559);
            assert((await h.screenshot(join(out, `${name}.png`))).ok);
            await writeFile(join(out, `${name}.json`), JSON.stringify(await h.tree(), null, 2));
            report.checks.push({ name, execution_summary: text(find(execution, 'ai.execution.result.summary')), input_summary: text(find(input, 'ai.execution.result.summary')), icon_title_same_row: true, disclosure: 'collapsed/reopened', unrelated_execution_output_on_input: false });
        } finally {
            const shutdown: any = { name, route: 'POST /quit' };
            if (app.exitCode === null && app.signalCode === null) {
                try { await h.request('POST', '/quit'); await h.waitFor(async () => app.exitCode !== null || app.signalCode !== null || null, 10000); }
                catch (error) { shutdown.error = String(error); shutdown.route = 'SIGTERM fallback'; app.kill('SIGTERM'); }
            }
            Object.assign(shutdown, await ended);
            report.shutdown.push(shutdown);
            await log.close();
            await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
            assert.equal(shutdown.route, 'POST /quit');
            assert.equal(shutdown.code, 0);
            assert.equal(shutdown.signal, null);
        }
    }
    report.status = 'passed';
} catch (error) { report.status = 'failed'; report.error = String(error); process.exitCode = 1; }
await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ status: report.status, checks: report.checks.length, out, error: report.error }, null, 2));
