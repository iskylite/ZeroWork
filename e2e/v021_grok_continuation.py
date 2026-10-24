"""Strict real Grok continuation acceptance; run only with exclusive native UI ownership.

Secrets remain in the caller's private production config and are never copied to evidence.
Each failure is retained without retrying, replacing the chat, or changing the model.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import tomllib
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('--binary', required=True)
p.add_argument('--sha', required=True)
p.add_argument('--config', required=True)
p.add_argument('--out', required=True)
a = p.parse_args()
workspace = Path(__file__).resolve().parent.parent
binary, config_path, out = Path(a.binary).resolve(), Path(a.config).resolve(), Path(a.out).resolve()
assert hashlib.sha256(binary.read_bytes()).hexdigest() == a.sha
assert config_path.stat().st_mode & 0o077 == 0, 'Provider config must be mode 600'
config = tomllib.loads(config_path.read_text())
providers = config['ai']['providers']
assert len(providers) == 1 and len(providers[0]['models']) == 1
provider, model = providers[0], providers[0]['models'][0]
assert provider['endpoint'].endswith('/chat/completions')
assert model['name'] == 'grok/grok-4.7'
assert model['image_token_reservation'] == 1024
out.mkdir(parents=True, exist_ok=True)
assert not any(out.iterdir()), 'Preserve earlier attempts in separate directories'
summary = {'status': 'running', 'binary_sha256': a.sha, 'model': model['name'],
           'endpoint': provider['endpoint'], 'image_token_reservation': 1024,
           'reservation_meaning': 'admission estimate, not provider usage',
           'gpt_fallback': False, 'conversation_mode': 'strict_continuous_same_assistant_conversation',
           'started_at_unix': time.time(), 'suites': []}

def save():
    (out / 'acceptance-summary.json').write_text(json.dumps(summary, indent=2))

try:
    request = urllib.request.Request(provider['endpoint'].removesuffix('/chat/completions') + '/models', headers={
        'Authorization': 'Bearer ' + provider['api_key']})
    with urllib.request.urlopen(request, timeout=15) as response:
        listing = json.load(response)
    ids = [item['id'] for item in listing['data']]
    assert model['name'] in ids, 'Configured Grok model must exist before native requests'
    summary['models_preflight'] = {'configured_model_present': True, 'configured_model': model['name']}
    save()
    commands = [
        ('01-fixture-continuous', ['node', 'e2e/v021_fixture_native.ts', '--binary', str(binary),
            '--expected-sha', a.sha, '--out', str(out / '01-fixture-continuous'), '--config', str(config_path),
            '--shared-presenter-only', '1', '--continuous-ai', '1']),
        ('02-loopback-continuous', ['python3', 'e2e/v021_loopback_run.py', '--binary', str(binary),
            '--sha', a.sha, '--out', str(out / '02-loopback-continuous'), '--shared-challenge',
            '--sftp-ai', '--ai-config', str(config_path), '--continuous-ai']),
    ]
    clean_env = dict(os.environ)
    for key in ('ZEROWORK_AI_MOCK', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY'):
        clean_env.pop(key, None)
    for name, command in commands:
        with (out / (name + '-runner.log')).open('w') as log:
            run = subprocess.run(command, cwd=workspace, env=clean_env, stdout=log, stderr=log)
        suite = {'name': name, 'exit_code': run.returncode, 'report': str(out / name / 'report.json')}
        summary['suites'].append(suite)
        save()
        report_path = out / name / 'report.json'
        if report_path.exists():
            report = json.loads(report_path.read_text())
            suite['status'] = report['status']
            suite['error'] = report.get('error')
            suite['normal_app_close'] = report.get('normal_app_close', False)
            suite['process_cleanup'] = report.get('cleanup', report.get('process_cleanup'))
            turns = report.get('turns', report.get('sftp_ai', {}).get('turns', []))
            suite['turns'] = []
            for turn in turns:
                events = turn['events']
                invocations = [e for e in events if e['event'] == 'dynamic_invocation']
                finishes = [e for e in events if e['event'] == 'provider_response_finish']
                parse_errors = [e for e in events if e['event'] == 'provider_parse_error']
                diagnosis = 'actual_tool_invocation' if invocations else (
                    'provider_json_parse_error' if parse_errors else (
                    'provider_finished_without_tool_deltas' if finishes and not any(e['tool_call_deltas'] for e in finishes) else
                    'provider_tool_deltas_without_dynamic_invocation' if any(e['tool_call_deltas'] for e in finishes) else
                    'provider_response_incomplete_or_transport_failure'))
                suite['turns'].append({
                    'name': turn.get('name', turn.get('tool')), 'invocations': len(invocations),
                    'dispatches': len([e for e in events if e['event'] == 'dynamic_dispatch']),
                    'continuation': turn.get('continuation'), 'request_identity': turn.get('request_identity'),
                    'provider_finishes': finishes, 'provider_parse_errors': parse_errors,
                    'provider_http_responses': [e for e in events if e['event'] == 'provider_http_response'],
                    'diagnosis': diagnosis,
                })
            save()
        if run.returncode:
            raise RuntimeError(name + ' failed; original turn evidence retained, no retry performed')
        assert report['binary_sha256'] == a.sha and report['normal_app_close'] is True
    summary['status'] = 'passed_pending_visual_and_receipt_review'
except Exception as error:
    summary['status'] = 'failed'
    summary['error'] = str(error)
    raise
finally:
    summary['finished_at_unix'] = time.time()
    save()
