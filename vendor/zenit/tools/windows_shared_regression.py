#!/usr/bin/env python3
"""Run the shared Windows render/input gates, including mandatory Modal, Sheet and Notification frame audits."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def completed_summary(log: Path, minimum_cases: int):
    # A suite bundled on the worker also prints its guest-side session path; the
    # host path (recovered session) is the one that holds summary.json.
    matches = [m.strip() for m in re.findall(r"Session output: ([^\r\n]+)", log.read_text())]
    matches = [m for m in matches if m.startswith('/')]
    if len(matches) != 1:
        raise ValueError("missing or ambiguous suite summary")
    session = Path(matches[0])
    path = session / "summary.json"
    if not path.exists():
        candidates = [d / "summary.json" for d in session.iterdir() if d.is_dir() and (d / "summary.json").exists()]
        if len(candidates) != 1:
            raise ValueError("missing or ambiguous recovered session summary")
        path = candidates[0]
    summary = json.loads(path.read_text())
    if (summary["total"] < minimum_cases or summary["executed"] != summary["total"]
            or summary["passed"] != summary["total"] or summary["failed"] or summary["aborted"]):
        raise ValueError("suite was filtered, incomplete, aborted or failed")
    return {"path": str(path), **summary}


PHASES = [
    # Probes that native input is denied without --allow-foreground; the host answers 403,
    # so this one stays on the host RPC path even when the others run beside the app.
    ('gallery-background', 'render-gallery', 'e2e/windows-native-background.test.ts', 1, False, ['--host-rpc']),
    ('gallery-dialogs', 'render-gallery', 'e2e/windows-dialog-background.test.ts', 1, True, []),
    ('gallery-retained', 'render-gallery', 'e2e/windows-image-render.test.ts', 1, True, []),
    ('storybook', 'storybook', 'e2e/windows-storybook-render.test.ts', 6, False, []),
    ('emoji-and-morph', 'storybook', 'e2e/storybook.test.ts', 3, True, []),
    ('modal-frames', 'storybook', 'e2e/windows-shared-modal-archive.test.ts', 2, True, ['--audit-modal-frames', 'target']),
    ('sheet-frames', 'storybook', 'e2e/windows-shared-sheet-archive.test.ts', 1, True, ['--capture-frames']),
    # Host RPC path kept for the VM. (Its note that a local suite overflows the 256-frame
    # archive described a since-fixed idle-frame leak: hidden glass kept the window at 60 fps.)
    ('notification-frames', 'storybook', 'e2e/windows-shared-notification-archive.test.ts', 1, True, ['--capture-frames', '--host-rpc']),
    ('glass-scroll', 'storybook', 'e2e/windows-shared-glass-scroll.test.ts', 1, True, []),
    ('input', 'text-input', 'e2e/windows-text-input-visual.test.ts', 6, False, []),
    ('input-edge-drag', 'text-input', 'e2e/windows-input-edge-drag.test.ts', 1, True, []),
    ('textarea-edge-drag', 'text-input', 'e2e/windows-textarea-edge-drag.test.ts', 1, True, []),
    ('resize', 'text-input', 'e2e/windows-shared-resize.test.ts', 1, True, []),
]

# Filters go through --filter so they reach a suite bundled on the worker as well as one run on
# the host (the tool exports ZENIT_E2E_FILTER for both paths). ASCII only: a suite bundled on the
# worker receives its env through PowerShell, which mangles non-ASCII filter text.
STAGE_FILTERS = {
    # Reuse the original full-suite pixel/motion contracts without copying them.
    'emoji-and-morph': 'Emoji:|GlassMotion: morph',
    'gallery-retained': 'Windows retained pixels match full repaint',
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Verify and reuse existing shared executables')
    parser.add_argument('--base', default='http://127.0.0.1:19817')
    parser.add_argument('--arch', choices=['aarch64', 'x86_64'], default='aarch64')
    parser.add_argument('--artifact-dir', type=Path, default=None,
                        help='Prebuilt bin directory (implies --skip-build; use an isolated --prefix for x86_64)')
    parser.add_argument('--suite-on-worker', action='store_true', help='Run every suite beside the app on the worker')
    parser.add_argument('--startup-timeout', type=float, default=None, help='Seconds for artifact download and app start')
    parser.add_argument('--visual-quality', choices=['auto', 'full', 'basic'], default=None)
    parser.add_argument('--no-host-rpc', action='store_true',
                        help='Bundle even the phases marked host-only (needs a worker whose agent answers native-input refusals; use for the physical machine behind a tunnel)')
    args = parser.parse_args()
    if args.artifact_dir is not None:
        args.skip_build = True
    folder = Path(tempfile.mkdtemp(prefix='zenit-windows-shared-regression-'))
    report = {'passed': False, 'complete': False, 'stages': []}
    report_path = folder / 'result.json'
    def save():
        pending = report_path.with_suffix('.tmp')
        pending.write_text(json.dumps(report, indent=2) + '\n')
        pending.replace(report_path)
    save()
    phases = PHASES
    print(f'Shared Windows regression evidence: {folder}', flush=True)
    env = os.environ.copy()
    env.pop('ZENIT_E2E_FILTER', None)
    for name, app, suite, minimum_cases, reuse, extra in phases:
        command = [sys.executable, str(ROOT / 'tools/windows_vm_http.py'), 'e2e',
                   '--base', args.base, '--renderer', 'd3d12', '--app', app,
                   '--suite', suite, '--timeout', '420', *extra]
        if args.skip_build or reuse:
            command.append('--skip-build')
        command += ['--arch', args.arch]
        if args.artifact_dir is not None:
            command += ['--artifact-dir', str(args.artifact_dir)]
        if args.suite_on_worker and ('--host-rpc' not in extra or args.no_host_rpc):
            command.append('--suite-on-worker')
        if '--host-rpc' in command:
            command.remove('--host-rpc')
        if args.startup_timeout is not None:
            command += ['--startup-timeout', str(args.startup_timeout)]
        if args.visual_quality is not None:
            command += ['--visual-quality', args.visual_quality]
        log = folder / f'{name}.log'
        stage = {'name': name, 'command': command, 'log': str(log), 'status': 'running'}
        phase_env = env.copy()
        # Filters go through --filter so they reach a suite bundled on the worker as well
        # as one run on the host (the tool exports ZENIT_E2E_FILTER for both paths).
        if name in STAGE_FILTERS:
            stage['filter'] = STAGE_FILTERS[name]
        if 'filter' in stage:
            command += ['--filter', stage['filter']]
            phase_env['ZENIT_E2E_FILTER'] = stage['filter']
        report['stages'].append(stage)
        save()
        print(f'Running {name}; log: {log}', flush=True)
        with log.open('w') as output:
            result = subprocess.run(command, cwd=ROOT, env=phase_env, stdout=output, stderr=subprocess.STDOUT)
        stage.update(status='passed' if result.returncode == 0 else 'failed', exit_code=result.returncode)
        if result.returncode == 0:
            try:
                stage['summary'] = completed_summary(log, minimum_cases)
                if name in ('notification-frames', 'sheet-frames'):
                    effect = 'notification' if name == 'notification-frames' else 'sheet'
                    ids = re.findall(r'^Windows E2E job: ([a-f0-9]{32}); evidence:', log.read_text(), re.MULTILINE)
                    if len(ids) != 1:
                        raise ValueError(f'missing or ambiguous {effect} archive job')
                    job = Path(env.get('ZENIT_VM_HTTP_DATA', '/tmp/zenit-vm-http')).resolve() / 'jobs' / ids[0]
                    audit_log = folder / f'{effect}-audit.log'
                    with audit_log.open('w') as output:
                        audited = subprocess.run([sys.executable, str(ROOT / f'tools/windows_shared_{effect}_frame_audit.py'), str(job)],
                                                 cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
                    stage['audit_log'] = str(audit_log)
                    stage['audit'] = json.loads((job / f'{effect}-frame-audit.json').read_text())
                    if audited.returncode or stage['audit'].get('passed') is not True:
                        raise ValueError(f'{effect} submitted-frame pixel audit failed')
            except (OSError, ValueError, KeyError) as error:
                stage.update(status='failed', error=str(error))
        save()
        if stage['status'] != 'passed':
            # A timed-out CLI may leave a still-running VM job. Never enqueue
            # another phase automatically after a non-successful result.
            print(f'FAILED: {name}; inspect {log}; remaining stages were not run', flush=True)
            return 1
    report.update(passed=True, complete=True)
    save()
    print(f'PASSED: {report_path}', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
