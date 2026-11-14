#!/usr/bin/env python3
"""Own loopback model + real native transport compaction contract. No credentials."""
import http.server, json, subprocess, threading, pathlib, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
requests = []
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        assert self.path == '/v1/models'
        body = json.dumps({'data': [{'id': 'alpha', 'context_window': 32768, 'reasoning': False, 'vision': False}, {'id': 'beta', 'context_window': 65536, 'reasoning': False, 'vision': False}]}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = 'MEMORY_BACKUP_TESTS_PASSED. Recorded tool output.'
        path = self.path.removesuffix('/chat/completions')
        requests.append({'path': path, 'body': body})
        if path == '/image':
            assert 'data:image/png;base64,' in json.dumps(body['messages'])
        if path == '/next':
            messages = body['messages']
            serialized = json.dumps(messages)
            assert 'MEMORY_BACKUP_TESTS_PASSED' in serialized
            assert 'OLD_RAW_CONTEXT' not in serialized and 'SECOND_RAW_CONTEXT' not in serialized
            assert 'RECENT_FIRST' in serialized and 'RECENT_LAST' in serialized
            user_texts = [m['content'] for m in messages if m['role'] == 'user']
            original = '只生成备份。\n  不得部署，也不要重启服务。'
            correction = '更正：输出目录用 backup-v2，不再用 backup-v1。\n'
            assert user_texts.count(original) == user_texts.count(correction) == 1
            assert user_texts.index(original) < user_texts.index(correction)
            assert messages[-1]['content'] in ('NEXT_REAL_REQUEST', 'MORE_RECENT')
            text = 'NEXT_REQUEST_ACCEPTED'
        else:
            assert not body.get('tools'), 'summary requests must have no tools'
            assert [m['role'] for m in body['messages']] == ['system', 'user'], 'historical roles must be quoted data, not active turns'
            encoded = body['messages'][1]['content']
            if isinstance(encoded, list): encoded = next(x['text'] for x in encoded if x.get('type') == 'text')
            transcript = json.loads(encoded)['historical_transcript']
            assert transcript, 'summary must receive quoted transcript data'
            if path == '/success':
                assert [entry['role'] for entry in transcript] == ['assistant', 'tool']
                assert 'OLD_RAW_CONTEXT' in transcript[1]['content']
            if path == '/repeated':
                assert any('SECOND_RAW_CONTEXT' in entry['content'] for entry in transcript)
        if path in ['/failure', '/worker-failure']:
            self.send_response(400); self.end_headers(); return
        if path == '/limit': text = 'BLOCK_MEMORY ' * 1250
        if path == '/empty': text = ''
        if path == '/acknowledgement': text = '已记录。'
        if path == '/larger': text = 'NO_REDUCTION ' * 200
        if path in ['/cancel', '/owner', '/conversation', '/revision', '/generation', '/transcript', '/busy']: time.sleep(.08)
        content = 'data: ' + json.dumps({'choices':[{'delta':{'content':text}}]}) + '\n\ndata: [DONE]\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length', str(len(content.encode()))); self.end_headers()
        try: self.wfile.write(content.encode())
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',18987), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run(['zig','test','src/compaction_e2e_tests.zig','-lc','-framework','CoreFoundation','-framework','CoreGraphics','-framework','ImageIO','--test-filter','compaction real'], cwd=ROOT)
    assert result.returncode == 0
    assert sum(x['path'] == '/worker-failure' for x in requests) == 1, 'failed worker compaction must not retry unchanged input'
    assert sum(x['path'] == '/limit' for x in requests) == 4
    assert sum(x['path'] == '/next' for x in requests) == 2
    assert all(x['path'] != '/verbatim-overflow' for x in requests)
    print(json.dumps({'status':'passed','requests':[x['path'] for x in requests], 'assertions':['real HTTP summary','verbatim requirements and corrections in both follow-up requests','older tool output compacted first','visible history unchanged','failure/cancel/stale owner/conversation/revision/generation/transcript/busy unchanged','empty/non-reducing/over-budget summaries rejected','old image pixels summarized and recent images retained; nonvision fails unchanged']}, indent=2))
finally: server.shutdown()
