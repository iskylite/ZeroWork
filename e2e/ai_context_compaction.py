#!/usr/bin/env python3
"""Own loopback model + real native transport compaction contract. No credentials."""
import http.server, json, subprocess, threading, pathlib, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
requests = []
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'body': body})
        text = 'MEMORY_BACKUP_TESTS_PASSED; Goal backup; no deployment; pending review.'
        if self.path == '/image':
            assert 'data:image/png;base64,' in json.dumps(body['messages'])
        if self.path == '/next':
            messages = body['messages']
            serialized = json.dumps(messages)
            assert 'MEMORY_BACKUP_TESTS_PASSED' in serialized
            assert 'OLD_RAW_CONTEXT' not in serialized
            assert 'RECENT_FIRST' in serialized and 'RECENT_LAST' in serialized
            assert messages[-1]['content'] == 'NEXT_REAL_REQUEST'
            text = 'NEXT_REQUEST_ACCEPTED'
        else:
            assert not body.get('tools'), 'summary requests must have no tools'
            assert 'OLD_RAW_CONTEXT' in json.dumps(body['messages'])
            assert 'RECENT_FIRST' not in json.dumps(body['messages'])
        if self.path == '/failure':
            self.send_response(400); self.end_headers(); return
        if self.path == '/empty': text = ''
        if self.path == '/larger': text = 'NO_REDUCTION ' * 200
        if self.path in ['/cancel', '/owner', '/conversation', '/revision', '/generation', '/transcript', '/busy']: time.sleep(.08)
        content = 'data: ' + json.dumps({'choices':[{'delta':{'content':text}}]}) + '\n\ndata: [DONE]\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length', str(len(content.encode()))); self.end_headers()
        try: self.wfile.write(content.encode())
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',18987), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run(['zig','test','src/compaction_e2e_tests.zig','-lc','-framework','CoreFoundation','-framework','CoreGraphics','-framework','ImageIO','--test-filter','compaction real'], cwd=ROOT)
    assert result.returncode == 0
    assert any(x['path'] == '/next' for x in requests)
    print(json.dumps({'status':'passed','requests':[x['path'] for x in requests], 'assertions':['real HTTP summary','next request uses memory and retained turns','visible history unchanged','failure/cancel/stale owner/conversation/revision/generation/transcript/busy unchanged','empty/non-reducing/over-budget summaries rejected','old image pixels summarized and recent images retained; nonvision fails unchanged']}, indent=2))
finally: server.shutdown()
