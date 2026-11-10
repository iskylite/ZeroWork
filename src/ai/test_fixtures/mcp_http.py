# Isolated loopback MCP fixture. Never used by production.
import http.server, json, sys, threading, time, base64, io, wave, urllib.parse
port_file, trace, mode = sys.argv[1:]
replied = threading.Event()
def record(value):
    with open(trace, 'a') as f: f.write(json.dumps(value) + '\n')
schema = {'type':'object','additionalProperties':False,'properties':{'text':{'type':'string','maxLength':64}},'required':['text']}
if mode=='multi': schema={'type':'object','additionalProperties':False,'properties':{'query':{'type':'string'},'limit':{'type':'integer','minimum':1,'maximum':10},'options':{'type':'object','properties':{'tags':{'type':'array','items':{'type':'string'}}},'additionalProperties':False}},'required':['query','limit']}
protocol = '2025-03-26' if mode=='legacy-version' else '2025-11-25'
if mode in ('standard','bad-output'):
    schema={'$schema':'https://json-schema.org/draft/2020-12/schema','$defs':{'target':{'type':'object','properties':{'host':{'type':'string','pattern':'^[a-z]+$'},'port':{'type':'integer','minimum':1,'maximum':65535}},'required':['host'],'additionalProperties':False}},'type':'object','properties':{'target':{'$ref':'#/$defs/target'},'filter':{'type':['string','null']},'limit':{'oneOf':[{'type':'integer','minimum':1},{'const':'all'}]},'mode':{'anyOf':[{'const':'read'},{'const':'write'}]}},'required':['target','mode'],'unevaluatedProperties':False}
output_schema={'type':'object','properties':{'status':{'const':'ok'},'count':{'type':'integer'}},'required':['status','count'],'additionalProperties':False}
pixel=bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63f8cfc0f01f00050001ff89993d1d0000000049454e44ae426082')
wave_buffer=io.BytesIO()
with wave.open(wave_buffer,'wb') as wav:
    wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(8000);wav.writeframes(b'\x00\x00'*8)
ping_replied=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    list_count = 0
    call_count = 0
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
        raw = self.rfile.read(int(self.headers['Content-Length']))
        if mode=='oauth-refresh':
            fields=urllib.parse.parse_qs(raw.decode())
            assert fields['grant_type']==['refresh_token'] and fields['refresh_token']==['refresh-one']
            assert fields['client_id']==['refresh-client'] and fields['resource']==['http://127.0.0.1:%d/mcp'%self.server.server_port]
            record({'method':'refresh','resource':fields['resource'][0]})
            self.response(200, {'access_token':'fresh-access-token','token_type':'Bearer','expires_in':3600,'refresh_token':'rotated-refresh-token'});return
        r = json.loads(raw)
        method = r.get('method'); rid = r.get('id')
        record({'method':method,'id':rid,'session':self.headers.get('Mcp-Session-Id'),'version':self.headers.get('MCP-Protocol-Version'),'request':r})
        if mode.startswith('modern'):
            assert self.headers.get('Mcp-Method')==method
            meta=r.get('params',{}).get('_meta',{})
            assert meta.get('io.modelcontextprotocol/protocolVersion')=='2026-07-28'
            assert isinstance(meta.get('io.modelcontextprotocol/clientCapabilities'),dict)
            assert meta.get('io.modelcontextprotocol/clientInfo',{}).get('name')=='ZeroWork'
            def complete(value): self.response(200, {'jsonrpc':'2.0','id':rid,'result':dict(value,resultType='complete')})
            if method=='server/discover':
                if mode=='modern-unsupported':self.response(400,{'jsonrpc':'2.0','id':rid,'error':{'code':-32022,'message':'unsupported','data':{'supported':['2099-01-01']}}});return
                complete({'supportedVersions':['2026-07-28'],'capabilities':{'tools':{}},'_meta':{'io.modelcontextprotocol/serverInfo':{'name':'modern-fixture','version':'1'}}});return
            if method=='tools/list':
                tools=[{'name':'material','inputSchema':schema,'outputSchema':{'type':'array'}}]
                if mode=='modern-bad-result':self.response(200,{'jsonrpc':'2.0','id':rid,'result':{'resultType':'unknown','tools':tools}});return
                complete({'tools':tools,'ttlMs':100,'cacheScope':'private'});return
            if method=='tools/call':
                assert self.headers.get('Mcp-Name')=='material'
                params=r['params']
                Handler.call_count += 1
                if 'inputResponses' in params:
                    assert params['requestState']=='opaque::#/% unchanged'
                    assert params['inputResponses']['roots']['roots']==[{'uri':'file:///tmp/selected-root'}]
                    assert params['arguments']=={'text':'modern'}
                if 'inputResponses' not in params or (mode=='modern' and Handler.call_count<=20):
                    request={'method':'host/run_command','params':{}} if mode=='modern-unknown-input' else {'method':'roots/list'}
                    self.response(200,{'jsonrpc':'2.0','id':rid,'result':{'resultType':'input_required','inputRequests':{'roots':request},'requestState':'opaque::#/% unchanged'}});return
                assert params['requestState']=='opaque::#/% unchanged'
                assert params['inputResponses']['roots']['roots']==[{'uri':'file:///tmp/selected-root'}]
                assert params['arguments']=={'text':'modern'}
                complete({'content':[{'type':'text','text':'MODERN COMPLETE'}],'structuredContent':[1,'two']});return
            if rid is None:self.response(202);return
            self.response(400,{'jsonrpc':'2.0','id':rid,'error':{'code':-32601,'message':'unknown'}});return
        if mode=='redirect':
            self.send_response(307); self.send_header('Location','http://127.0.0.1:1/leaked'); self.send_header('Content-Length','0'); self.end_headers(); return
        if method=='initialize':
            assert isinstance(r['params'],dict) and isinstance(r['params']['capabilities'],dict)
            self.response(200, {'jsonrpc':'2.0','id':rid,'result':{'protocolVersion':'unsupported' if mode=='badversion' else protocol,'capabilities':{'prompts':{}} if mode=='no-tools' else {'tools':{}}}}, True); return
        if self.headers.get('Mcp-Session-Id')!='fixture-session' or self.headers.get('MCP-Protocol-Version')!=protocol: self.response(400); return
        if method is None and 'result' in r:
            if rid=='ping-request':
                assert r['result']=={};ping_replied.set()
            self.response(202);return
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
                self.wfile.write(b'data: {"jsonrpc":"2.0","id":"ping-request","method":"ping"}\r\n\r\n');self.wfile.flush()
                if not replied.wait(3) or not ping_replied.wait(3): return
                progress={'jsonrpc':'2.0','method':'notifications/progress','params':{'progressToken':r['params']['_meta']['progressToken'],'progress':2,'total':4,'message':'halfway'}}
                self.wfile.write(('data: '+json.dumps(progress)+'\r\n\r\n').encode());self.wfile.flush()
                body=json.dumps({'jsonrpc':'2.0','id':rid,'result':{'tools':[{'name':'material','inputSchema':schema},{'name':'same-schema','inputSchema':schema}]}})
                split=body.index(',')+1
                self.wfile.write(('event: message\r\ndata: '+body[:split]+'\r\ndata: '+body[split:]+'\r\n\r\n').encode()); self.wfile.flush(); time.sleep(2); return
            result={'tools':[{'name':'material','title':'Standard tool','inputSchema':schema, **({'outputSchema':output_schema,'annotations':{'readOnlyHint':True}} if mode in ('standard','bad-output','mixed') else {})}]}
        elif method=='tools/call':
            if mode=='hang': time.sleep(4)
            if mode in ('standard','bad-output'):
                result={'content':[{'type':'text','text':json.dumps(r['params']['arguments'])}],'structuredContent':{'status':'bad' if mode=='bad-output' else 'ok','count':3}}
            elif mode=='mixed':
                result={'content':[{'type':'text','text':'all content types'},{'type':'image','mimeType':'image/png','data':base64.b64encode(pixel).decode()},{'type':'audio','mimeType':'audio/wav','data':base64.b64encode(wave_buffer.getvalue()).decode()},{'type':'resource_link','name':'linked.txt','uri':'fixture://linked.txt'},{'type':'resource','resource':{'uri':'fixture://text','mimeType':'text/plain','text':'embedded text'}},{'type':'resource','resource':{'uri':'fixture://binary','mimeType':'application/octet-stream','blob':base64.b64encode(b'opaque\x00resource').decode()}}],'structuredContent':{'status':'ok','count':3}}
            elif mode=='large':
                result={'content':[{'type':'text','text':'large-result-'*100000}]}
            else:
                result={'content':[{'type':'text','text':json.dumps(r['params']['arguments']) if mode=='multi' else r['params']['arguments']['text'].upper()}]}
        else: self.response(200,{'jsonrpc':'2.0','id':rid,'error':{'code':-32601,'message':'unsupported'}}); return
        self.response(200,{'jsonrpc':'2.0','id':rid,'result':result})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
with open(port_file,'w') as f: f.write(str(server.server_port))
server.serve_forever()
