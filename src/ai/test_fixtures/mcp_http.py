# Isolated loopback MCP fixture. Never used by production.
import http.server, json, sys, threading, time
port_file, trace, mode = sys.argv[1:]
replied = threading.Event()
def record(value):
    with open(trace, 'a') as f: f.write(json.dumps(value) + '\n')
schema = {'type':'object','additionalProperties':False,'properties':{'text':{'type':'string','maxLength':64}},'required':['text']}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    list_count = 0
    def log_message(self, *args): pass
    def response(self, status, obj=None, session=False):
        raw = json.dumps(obj).encode() if obj is not None else b''
        self.send_response(status)
        if session: self.send_header('Mcp-Session-Id', 'fixture-session')
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(raw))); self.end_headers()
        if raw: self.wfile.write(raw)
    def do_DELETE(self):
        record({'method':'DELETE','session':self.headers.get('Mcp-Session-Id')}); self.response(204)
    def do_POST(self):
        r = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = r.get('method'); rid = r.get('id')
        record({'method':method,'id':rid,'session':self.headers.get('Mcp-Session-Id'),'version':self.headers.get('MCP-Protocol-Version'),'request':r})
        if mode=='redirect':
            self.send_response(307); self.send_header('Location','http://127.0.0.1:1/leaked'); self.send_header('Content-Length','0'); self.end_headers(); return
        if method=='initialize':
            assert isinstance(r['params'],dict) and isinstance(r['params']['capabilities'],dict)
            self.response(200, {'jsonrpc':'2.0','id':rid,'result':{'protocolVersion':'unsupported' if mode=='badversion' else '2025-11-25','capabilities':{'tools':{}}}}, True); return
        if self.headers.get('Mcp-Session-Id')!='fixture-session' or self.headers.get('MCP-Protocol-Version')!='2025-11-25': self.response(400); return
        if 'error' in r:
            if rid=='unsupported-request' and r['error']['code']==-32601: replied.set()
            self.response(202); return
        if rid is None: self.response(202); return
        if method=='tools/list':
            Handler.list_count += 1
            if mode=='schema-change' and Handler.list_count>1: schema['properties']['text']['maxLength']=32
            if mode=='sse':
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Connection','close'); self.end_headers()
                self.wfile.write(b'data: {"jsonrpc":"2.0","id":"unsupported-request","method":"roots/list"}\r\n\r\n'); self.wfile.flush()
                if not replied.wait(3): return
                body=json.dumps({'jsonrpc':'2.0','id':rid,'result':{'tools':[{'name':'material','inputSchema':schema},{'name':'same-schema','inputSchema':schema}]}})
                split=body.index(',')+1
                self.wfile.write(('event: message\r\ndata: '+body[:split]+'\r\ndata: '+body[split:]+'\r\n\r\n').encode()); self.wfile.flush(); time.sleep(2); return
            result={'tools':[{'name':'material','inputSchema':schema}]}
        elif method=='tools/call':
            if mode=='hang': time.sleep(4)
            result={'content':[{'type':'text','text':r['params']['arguments']['text'].upper()}]}
        else: self.response(200,{'jsonrpc':'2.0','id':rid,'error':{'code':-32601,'message':'unsupported'}}); return
        self.response(200,{'jsonrpc':'2.0','id':rid,'result':result})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
with open(port_file,'w') as f: f.write(str(server.server_port))
server.serve_forever()
