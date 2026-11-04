const std = @import("std");
const native = @import("plugins/bmc_ikvm/native_driver.zig");
const console = @import("plugins/bmc_ikvm/controller.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const auth = @import("plugins/bmc_ikvm/protocol/auth.zig");
const http = @import("plugins/bmc_ikvm/protocol/http.zig");
const redfish = @import("plugins/bmc_ikvm/protocol/redfish.zig");
const power = @import("plugins/bmc_ikvm/protocol/power.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const trust = @import("host/tls_trust.zig");
const secrets = @import("host/secret_lease.zig");
const contexts = @import("host/host_context.zig");
const credentials = @import("config/credential_store.zig");
const transport = @import("host/transport_factory.zig");
const frames = @import("plugins/bmc_ikvm/framebuffer.zig");
const input = @import("plugins/bmc_ikvm/remote_input.zig");
const budgets = @import("host/frame_budget.zig");
const management = @import("plugins/bmc_ikvm/management_adapter.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const progress = @import("plugins/bmc_ikvm/connection_progress.zig");
const a = std.testing.allocator;
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(902), .generation = 7 };
const operation: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 80, .attempt_id = 2 };
const management_fixture = @embedFile("plugins/bmc_ikvm/protocol/profile_fixtures/sugon_1_80_management_readonly.json");

// Only loopback sockets. The key/certificate and passwords exist for this run;
// neither a real BMC nor the documented design-example addresses are contacted.
const fixture =
    \\import base64,hashlib,json,os,pathlib,socket,ssl,struct,subprocess,sys,tempfile,threading,time
    \\with tempfile.TemporaryDirectory(prefix='zerowork-native-bmc-') as directory:
    \\ d=pathlib.Path(directory)
    \\ (d/'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\n')
    \\ subprocess.run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-config',str(d/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    \\ public=subprocess.run(['/usr/bin/openssl','pkey','-in',str(d/'key.pem'),'-pubout'],capture_output=True,check=True).stdout
    \\ listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(4);listener.settimeout(15)
    \\ port=listener.getsockname()[1];reviewed=json.loads(sys.argv[3]);management_reviewed=json.loads(sys.argv[4])
    \\ object_manager_links=sys.argv[2].startswith('object-')
    \\ if object_manager_links: sys.argv[2]=sys.argv[2][len('object-'):]
    \\ observed=sys.argv[2]=='observed-partial'
    \\ readonly_modes={'firmware-progress','optional-malformed','optional-disconnect','cancel','mapped-read','missing-mapping','partial-mapping','missing-fields','manager-linked-system','broken-canonical','multiple-members','paged-members','partial-collection','missing-identity','observed-partial'}
    \\ broken_canonical_modes={'broken-canonical','multiple-members','paged-members','partial-collection','missing-identity'}
    \\ restart_modes={'production-restart','production-restart-advanced','production-restart-missing','production-restart-invalid','production-restart-query'}
    \\ critical_modes={'production-critical-power','production-critical-boot','production-scoped-power','production-scoped-boot','production-critical-disabled'}
    \\ production_modes={'production-power','production-boot','production-pending','production-forbidden403','production-conflict409','production-precondition412','production-disconnect','production-hold'}|restart_modes|critical_modes
    \\ production=sys.argv[2] in production_modes
    \\ current={'power':'On','boot_enabled':'Disabled','boot_target':'None','pending':False,'written':False,'system_gets':0}
    \\ if sys.argv[2]=='production-critical-disabled': current.update(boot_enabled='Once',boot_target='Pxe')
    \\ def diagnostics():
    \\  related={'production-scoped-power':['#/PowerState'],'production-scoped-boot':['#/Boot/BootSourceOverrideTarget'],'production-critical-disabled':['#/Boot/BootSourceOverrideTarget','#/Boot/BootSourceOverrideMode']}.get(sys.argv[2],[])
    \\  return [{'MessageId':'Base.1.19.InternalError','Severity':'Critical','MessageSeverity':'Critical','MessageArgs':[],'RelatedProperties':related}]
    \\ bootstrap=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=10)
    \\ bootstrap.sendall(str(port).encode()+b'\n'+public+b'ENDPUB\n')
    \\ expected=b''
    \\ while len(expected)<32: expected+=bootstrap.recv(32-len(expected))
    \\ bootstrap.close()
    \\ context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(d/'cert.pem',d/'key.pem')
    \\ changed_context=None
    \\ if sys.argv[2] in ('cleanup-changed-cert','optional-changed-cert'):
    \\  subprocess.run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'changed-key.pem'),'-out',str(d/'changed-cert.pem'),'-days','1','-config',str(d/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    \\  changed_context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);changed_context.load_cert_chain(d/'changed-cert.pem',d/'changed-key.pem')
    \\ webtoken=os.urandom(16).hex();kvmtoken=os.urandom(16).hex()
    \\ paths=[];errors=[];connections=[];closed=[];writes=[];ws_closed=threading.Event()
    \\ def run(raw,cleanup):
    \\  try:
    \\   with (changed_context if cleanup and changed_context else context).wrap_socket(raw,server_side=True) as s:
    \\    s.settimeout(10);buffer=b''
    \\    def take(n):
    \\     nonlocal buffer
    \\     while len(buffer)<n:
    \\      x=s.recv(16384)
    \\      if not x: raise EOFError()
    \\      buffer+=x
    \\     out=buffer[:n];buffer=buffer[n:];return out
    \\    def response(status,body=None,headers=None):
    \\     b=json.dumps(body).encode() if body is not None else b''
    \\     h=('HTTP/1.1 '+str(status)+' OK\r\nContent-Length: '+str(len(b))+'\r\n').encode()
    \\     for k,v in (headers or {}).items(): h+=(k+': '+v+'\r\n').encode()
    \\     data=h+b'\r\n'+b
    \\     for i in range(0,len(data),17): s.sendall(data[i:i+17])
    \\    while True:
    \\     while b'\r\n\r\n' not in buffer:
    \\      b=s.recv(16384)
    \\      if not b: return
    \\      buffer+=b
    \\     head,buffer=buffer.split(b'\r\n\r\n',1);lines=head.decode().split('\r\n');method,path,_=lines[0].split(' ')
    \\     headers={k.lower():v.strip() for k,v in (line.split(':',1) for line in lines[1:])}
    \\     assert headers['host']=='127.0.0.1:'+str(port)
    \\     body=take(int(headers.get('content-length','0')))
    \\     paths.append((method,path))
    \\     if path!='/kvm/0':
    \\      web_context=headers.get('from')=='WebUI' and headers.get('x-requested-with')=='XMLHttpRequest'
    \\      if not web_context:
    \\       assert path=='/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions' and method=='POST'
    \\       assert headers.get('x-auth-token')==webtoken
    \\       response(201,{'error':{'code':'Base.1.19.ResourceAtUriUnauthorized','@Message.ExtendedInfo':[{'MessageId':'Base.1.19.ResourceAtUriUnauthorized','Severity':'Critical'}]}},{'X-Auth-Token':kvmtoken})
    \\       continue
    \\      assert sum(line.lower().startswith('from:') for line in lines[1:])==1
    \\      assert sum(line.lower().startswith('x-requested-with:') for line in lines[1:])==1
    \\     if path=='/kvm/0':
    \\      assert headers['sec-websocket-protocol']==kvmtoken and headers['origin']=='https://127.0.0.1:'+str(port)
    \\      accept=base64.b64encode(hashlib.sha1((headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
    \\      upgrade=b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\nSec-WebSocket-Protocol: '+kvmtoken.encode()+b'\r\n\r\n'
    \\      fmt=bytes([32,24,0,1])+struct.pack('>HHH',255,255,255)+bytes([16,8,0,0,0,0])
    \\      hello=b'RFB 003.008\n'+bytes([105,1,0,99,104,0,0,0,1,1,0,0,0,0])+struct.pack('>HH',2,1)+fmt+struct.pack('>I',0)
    \\      image=bytes([0,0,0,1])+struct.pack('>HHHHi',0,0,2,1,0)+bytes([3,2,1,0])*2
    \\      payload=hello+image
    \\      # Upgrade and first complete image deliberately share one TLS write.
    \\      s.sendall(upgrade+bytes([0x82,len(payload)])+payload)
    \\      while True:
    \\       h=take(2);opcode=h[0]&15;length=h[1]&127;assert h[1]&128
    \\       if length==126: length=struct.unpack('>H',take(2))[0]
    \\       elif length==127: length=struct.unpack('>Q',take(8))[0]
    \\       mask=take(4)
    \\       if sys.argv[2]=='partial-video' and length==32768:
    \\        data=buffer;buffer=b''
    \\        while True:
    \\         try: chunk=s.recv(16384)
    \\         except (ssl.SSLEOFError,ConnectionResetError): break
    \\         if not chunk: break
    \\         data+=chunk
    \\        assert 0<len(data)<length,'partial frame was completed during cleanup'
    \\        assert all((x^mask[i%4])==0 for i,x in enumerate(data)),'cleanup appended bytes to a partial WS payload'
    \\        closed.append('partial-ws');ws_closed.set();return
    \\       data=take(length);decoded=bytes(x^mask[i%4] for i,x in enumerate(data))
    \\       if opcode==8: closed.append('ws');ws_closed.set();return
    \\       if decoded==b'KVM ': closed.append('preamble')
    \\     elif path=='/redfish/v1/' and method=='GET': response(200,management_reviewed['documents']['root']['body'] if observed else {'Systems':{'@odata.id':'/redfish/v1/Systems'},'Managers':{'@odata.id':'/redfish/v1/Managers'},'SessionService':{'@odata.id':'/redfish/v1/SessionService'}})
    \\     elif path=='/redfish/v1/SessionService': response(200,{'Sessions':{'@odata.id':'/redfish/v1/SessionService/Sessions'}})
    \\     elif path=='/redfish/v1/SessionService/Sessions' and method=='POST':
    \\      assert headers['from']=='WebUI' and headers['x-requested-with']=='XMLHttpRequest'
    \\      request=json.loads(body);assert request['UserName']=='fixture'
    \\      ciphertext=base64.b64decode(request['Password'],validate=True);assert len(ciphertext)==256
    \\      result=subprocess.run(['/usr/bin/openssl','pkeyutl','-decrypt','-inkey',str(d/'key.pem'),'-pkeyopt','rsa_padding_mode:pkcs1'],input=ciphertext,capture_output=True,check=True)
    \\      assert result.stdout==expected
    \\      response(201,{'Id':'own-web'},{'X-Auth-Token':webtoken,'Location':'/redfish/v1/SessionService/Sessions/own-web'})
    \\     else:
    \\      expected_token=kvmtoken if method=='DELETE' and path.endswith('/own-kvm') else webtoken
    \\      assert headers.get('x-auth-token')==expected_token
    \\      if observed and method=='GET':
    \\       document=next((value for value in management_reviewed['documents'].values() if value['uri']==path),None)
    \\       if document: response(document['status'],document['body'],{'ETag':'"observed"'});continue
    \\       options=management_reviewed['documents']['boot_options']['body']['Members']
    \\       assert any(option['@odata.id']==path for option in options),'unexpected observed fixture GET'
    \\       reference=path.rsplit('/',1)[1];option=dict(management_reviewed['boot_option_template']);option['BootOptionReference']=reference;option['Id']=reference
    \\       response(200,option,{'ETag':'"observed-option"'});continue
    \\      if method=='DELETE':
    \\       assert path in ('/redfish/v1/SessionService/Sessions/own-web','/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm')
    \\       assert ws_closed.wait(.5),'owned session DELETE preceded WebSocket close'
    \\       if sys.argv[2]=='logout-timeout' and path.endswith('/own-kvm'):
    \\        closed.append(path)
    \\        # A late response must not be consumed as WEB DELETE success.
    \\        time.sleep(1.3);response(200,{});return
    \\       evidence=reviewed['logout']['kvm' if path.endswith('/own-kvm') else 'web']
    \\       messages=[{'MessageId':evidence['message_id'],'Severity':evidence['severity']}]
    \\       if sys.argv[2]=='mixed': messages.append({'MessageId':'Base.1.19.Success','Severity':'Critical'})
    \\       closed.append(path);response(evidence['status'],{'error':{'code':evidence['message_id'],'@Message.ExtendedInfo':messages}})
    \\       return
    \\      elif path=='/redfish/v1/Systems':
    \\       if sys.argv[2]=='optional-malformed': s.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\ninvalid');continue
    \\       if sys.argv[2] in ('optional-disconnect','optional-changed-cert'): s.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{');return
    \\       collection={'Members':[{'@odata.id':'/redfish/v1/Systems/one'}]}
    \\       if sys.argv[2]=='multiple-members': collection['Members'].append({'@odata.id':'/redfish/v1/Systems/second'})
    \\       if sys.argv[2]=='paged-members': collection['Members@odata.nextLink']='/redfish/v1/Systems?page=2'
    \\       if sys.argv[2]=='partial-collection': collection['error']={'code':'Base.Error'}
    \\       response(200,collection)
    \\      elif path=='/redfish/v1/Systems?page=2': response(200,{'Members':[{'@odata.id':'/redfish/v1/Systems/second'}]})
    \\      elif path=='/redfish/v1/Managers': response(200,{'Members':[{'@odata.id':'/redfish/v1/Managers/one'}]})
    \\      elif path in ('/redfish/v1/Systems/one','/redfish/v1/Systems/canonical','/redfish/v1/Systems/second'):
    \\       if production and method=='PATCH':
    \\        assert sys.argv[2] in ('production-boot','production-pending','production-critical-boot','production-scoped-power','production-critical-disabled') and path=='/redfish/v1/Systems/one'
    \\        assert headers['if-match']=='"fixture-1"' and 'authkey' not in headers
    \\        request=json.loads(body);assert set(request)=={'Boot'}
    \\        if sys.argv[2]=='production-critical-disabled': assert request['Boot']=={'BootSourceOverrideEnabled':'Disabled'}
    \\        else:
    \\         assert set(request['Boot']) in ({'BootSourceOverrideEnabled','BootSourceOverrideTarget'},{'BootSourceOverrideEnabled','BootSourceOverrideTarget','BootSourceOverrideMode'})
    \\         assert request['Boot']['BootSourceOverrideEnabled']=='Once' and request['Boot']['BootSourceOverrideTarget']=='Pxe' and request['Boot'].get('BootSourceOverrideMode','UEFI')=='UEFI'
    \\        writes.append(path);current['written']=True
    \\        if sys.argv[2]=='production-pending': current['pending']=True
    \\        elif sys.argv[2]=='production-critical-disabled': current['boot_enabled']='Disabled'
    \\        else: current['boot_enabled']='Once';current['boot_target']='Pxe'
    \\        if sys.argv[2] in critical_modes: response(200,{'@odata.id':path,'Boot':{'BootSourceOverrideEnabled':current['boot_enabled'],'BootSourceOverrideTarget':current['boot_target'],'BootSourceOverrideMode':'UEFI'},'@Message.ExtendedInfo':diagnostics()})
    \\        else: response(204)
    \\        continue
    \\       assert method=='GET'
    \\       if path.endswith('/canonical') and sys.argv[2] in broken_canonical_modes:
    \\        response(404,'not-a-resource' if object_manager_links else {'error':{'code':'Base.ResourceMissingAtURI'}});continue
    \\       system={'Id':'one','UUID':'synthetic-system','PowerState':'On','Actions':{'#ComputerSystem.Reset':{'target':'/redfish/v1/Systems/one/Actions/ComputerSystem.Reset','ResetType@Redfish.AllowableValues':['On','GracefulShutdown']}},'Boot':{'BootSourceOverrideEnabled':'Disabled','BootSourceOverrideTarget':'None','BootSourceOverrideMode':'UEFI','BootSourceOverrideEnabled@Redfish.AllowableValues':['Disabled','Once'],'BootSourceOverrideTarget@Redfish.AllowableValues':['None','Pxe'],'BootSourceOverrideMode@Redfish.AllowableValues':['UEFI'],'BootOrder':['Boot%04X'%i for i in range(20)]},'Links':{'ManagedBy':[{'@odata.id':'/redfish/v1/Managers/one'}]}}
    \\       system['@odata.id']='/redfish/v1/Systems/canonical' if sys.argv[2]=='manager-linked-system' else path
    \\       if sys.argv[2]=='partial-mapping': system['error']={'code':'Base.Error'}
    \\       if sys.argv[2]=='missing-identity': system.pop('Id');system.pop('UUID')
    \\       if sys.argv[2]=='missing-fields':
    \\        for key in ('PowerState','Actions','Boot'): system.pop(key)
    \\       if production:
    \\        current['system_gets']+=1
    \\        system['PowerState']=current['power'];system['Boot']['BootSourceOverrideEnabled']=current['boot_enabled'];system['Boot']['BootSourceOverrideTarget']=current['boot_target']
    \\        system['Actions']['#ComputerSystem.Reset']['ResetType@Redfish.AllowableValues']+=['ForceOff','GracefulRestart']
    \\        if sys.argv[2] in critical_modes:
    \\         system['@Message.ExtendedInfo']=diagnostics()
    \\         system['Boot'].pop('BootSourceOverrideEnabled@Redfish.AllowableValues');system['Boot'].pop('BootSourceOverrideMode@Redfish.AllowableValues')
    \\        if current['pending']: system['@Redfish.Settings']={'SettingsObject':{'@odata.id':'/redfish/v1/Systems/one/Settings'}}
    \\        if sys.argv[2] in restart_modes:
    \\         system['LastResetTime']='2026-10-31T01:00:00Z'
    \\         if current['written']:
    \\          if sys.argv[2]=='production-restart-advanced' or (sys.argv[2]=='production-restart-query' and current['system_gets']>=4): system['LastResetTime']='2026-11-01T01:00:00Z'
    \\          elif sys.argv[2]=='production-restart-missing': system.pop('LastResetTime')
    \\          elif sys.argv[2]=='production-restart-invalid': system['LastResetTime']='2026-02-30T01:00:00Z'
    \\       response(200,system,{'ETag':('"fixture-2"' if current['written'] else '"fixture-1"') if production else '"first"'})
    \\      elif production and path=='/redfish/v1/Systems/one/Settings':
    \\       assert method=='GET' and current['pending']
    \\       response(200,{'Id':'one','UUID':'synthetic-system','Boot':{'BootSourceOverrideEnabled':'Once','BootSourceOverrideTarget':'Pxe','BootSourceOverrideMode':'UEFI'}},{'ETag':'"fixture-pending"'})
    \\      elif production and path=='/redfish/v1/TaskService/Tasks/fixture':
    \\       assert method=='GET' and sys.argv[2]=='production-power' and current['written']
    \\       response(200,{'TaskState':'Completed','TaskStatus':'OK'})
    \\      elif path=='/redfish/v1/Managers/one':
    \\       manager={'Id':'one','Links':{'ManagerForServers':[{'@odata.id':'/redfish/v1/Systems/one'}]},'SecurityService':{'@odata.id':'/redfish/v1/Managers/one/SecurityService'}}
    \\       if production: manager['Oem']={'Public':{'SecurityService':manager.pop('SecurityService')}}
    \\       if sys.argv[2]=='manager-linked-system' or sys.argv[2] in broken_canonical_modes: manager['Links']['ManagerForServers']=[{'@odata.id':'/redfish/v1/Systems/canonical'}]
    \\       if sys.argv[2] in ('firmware-progress','optional-malformed','optional-disconnect','optional-changed-cert'): manager['FirmwareVersion']='1.80'
    \\       if sys.argv[2]=='missing-mapping': manager.pop('Links')
    \\       if object_manager_links and 'Links' in manager: manager['Links']['ManagerForServers']=manager['Links']['ManagerForServers'][0]
    \\       response(200,manager)
    \\      elif path.endswith('/SecurityService'): response(200,{'EnableAuthConfirm':False})
    \\      elif path=='/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions':
    \\       assert json.loads(body)=={'Type':'WEB','KvmAuthentication':'own-web'}
    \\       response(201,{'Id':'own-kvm'},{'X-Auth-Token':kvmtoken,'Location':'/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm'})
    \\       if sys.argv[2]=='idle-management': closed.append('idle-management');return
    \\      elif path=='/redfish/v1/Systems/one/Actions/ComputerSystem.Reset':
    \\       if production:
    \\        requested_action='GracefulRestart' if sys.argv[2] in restart_modes else 'ForceOff'
    \\        assert method=='POST' and json.loads(body)=={'ResetType':requested_action} and headers['if-match']=='"fixture-1"' and 'authkey' not in headers
    \\        writes.append(path);current['written']=True
    \\        if sys.argv[2]=='production-disconnect': return
    \\        if sys.argv[2]=='production-hold':
    \\         time.sleep(1);current['power']='Off';response(204);continue
    \\        if sys.argv[2] in restart_modes:
    \\         response(200,{'error':{'code':'Base.1.19.Success','@Message.ExtendedInfo':[{'MessageId':'Base.1.19.Success','Severity':'OK','MessageSeverity':'OK'}]}});continue
    \\        failures={'production-forbidden403':(403,'Base.1.19.InsufficientPrivilege'),'production-conflict409':(409,'Base.1.19.ResourceInUse'),'production-precondition412':(412,'Base.1.19.PreconditionFailed')}
    \\        if sys.argv[2] in failures:
    \\         status,message=failures[sys.argv[2]];response(status,{'error':{'code':message,'@Message.ExtendedInfo':[{'MessageId':message,'Severity':'Critical'}]}});continue
    \\        if sys.argv[2] in ('production-critical-power','production-scoped-boot'):
    \\         current['power']='Off';response(200,{'@odata.id':'/redfish/v1/Systems/one','PowerState':'Off','@Message.ExtendedInfo':diagnostics()});continue
    \\        assert sys.argv[2]=='production-power'
    \\        current['power']='Off';response(202,{'TaskState':'Running'},{'Location':'/redfish/v1/TaskService/Tasks/fixture','Retry-After':'0'});continue
    \\       assert method=='POST' and body==b'{"ResetType":"On"}' and headers['authkey'].encode()==expected and headers['if-match']=='"first"'
    \\       writes.append(path);response(202,{'TaskState':'Running'},{'Location':'/redfish/v1/TaskService/Tasks/own','Retry-After':'2'})
    \\      elif path=='/redfish/v1/CancelledRead': raise AssertionError('cancelled normal IO reached wire')
    \\      else: raise AssertionError('unexpected fixture route')
    \\  except (EOFError,ssl.SSLEOFError,ConnectionResetError,BrokenPipeError):
    \\   if sys.argv[2] in ('graceful','missing-headers','mixed'): errors.append('unexpected disconnect')
    \\  except Exception as e: errors.append(type(e).__name__+': '+str(e))
    \\ for index in range(2 if sys.argv[2]=='untrusted' else (5 if sys.argv[2]=='optional-disconnect' else 4)):
    \\  raw,_=listener.accept();connections.append(raw);thread=threading.Thread(target=run,args=(raw,index>=2));thread.start();connections.append(thread)
    \\ for thread in connections[1::2]: thread.join(15);assert not thread.is_alive()
    \\ listener.close()
    \\ assert not errors,errors
    \\ if sys.argv[2]=='untrusted': assert paths==[], 'application bytes preceded host trust'
    \\ if production:
    \\  assert len(writes)==1 and 'ws' in closed and 'preamble' in closed
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/own-web')==1
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm')==1
    \\ if sys.argv[2] in ('production-restart','production-restart-query'): assert paths.count(('GET','/redfish/v1/Systems/one'))>=4,'restart query did not reach the wire'
    \\ elif sys.argv[2] in restart_modes: assert paths.count(('GET','/redfish/v1/Systems/one'))>=3,'restart verification did not reach the wire'
    \\ if sys.argv[2]=='production-hold': assert paths.count(('GET','/redfish/v1/Systems/one'))>=3,'cancelled operation query did not reach the wire'
    \\ if sys.argv[2] in ('graceful','missing-headers','mixed'):
    \\  assert len(writes)==1 and 'ws' in closed and 'preamble' in closed
    \\ if sys.argv[2] in ('graceful','missing-headers','mixed') or sys.argv[2] in readonly_modes:
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/own-web')==1
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm')==1
    \\ if sys.argv[2] in readonly_modes: assert writes==[] and len([p for p in paths if p[0]=='DELETE'])==2
    \\ if sys.argv[2] in ('optional-malformed','optional-disconnect'):
    \\  assert paths.index(('GET','/redfish/v1/Managers/one'))<paths.index(('GET','/redfish/v1/Systems'))
    \\  assert paths.count(('GET','/redfish/v1/Systems'))==1,'optional failed read replayed'
    \\  assert paths.count(('POST','/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions'))==1,'OEM session creation retried'
    \\ if sys.argv[2]=='manager-linked-system': assert paths.count(('GET','/redfish/v1/Systems/canonical'))==1
    \\ if sys.argv[2]=='logout-timeout':
    \\  assert writes==[] and [p for p in paths if p[0]=='DELETE']==[('DELETE','/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm'),('DELETE','/redfish/v1/SessionService/Sessions/own-web')]
    \\ if sys.argv[2]=='idle-management':
    \\  assert writes==[] and 'idle-management' in closed and 'ws' in closed
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/own-web')==1
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm')==1
    \\ if sys.argv[2]=='cleanup-changed-cert': assert writes==[] and not [p for p in paths if p[0]=='DELETE'],'tokens sent to a changed cleanup peer'
    \\ if sys.argv[2]=='optional-changed-cert':
    \\  assert writes==[] and not [p for p in paths if p[0]=='DELETE'],'tokens sent to a changed peer'
    \\  assert not [p for p in paths if '/Oem/' in p[1] or p[1]=='/kvm/0'],'KVM started after a peer change'
    \\ if sys.argv[2]=='partial-video':
    \\  assert writes==[] and 'partial-ws' in closed and 'ws' not in closed
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/own-web')==1
    \\  assert closed.count('/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions/own-kvm')==1
;

pub const Fixture = struct {
    child: std.process.Child,
    port: u16,
    pem: []u8,
    password: [32]u8,
    pub fn start(mode: []const u8) !Fixture {
        const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (listener < 0) return error.SocketFailed;
        defer _ = std.c.close(listener);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or std.c.listen(listener, 1) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(listener, @ptrCast(&address), &len) != 0) return error.AddressFailed;
        const port = try std.fmt.allocPrint(a, "{d}", .{std.mem.bigToNative(u16, address.port)});
        defer a.free(port);
        var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/usr/bin/python3", "-c", fixture, port, mode, @embedFile("plugins/bmc_ikvm/protocol/profile_fixtures/sugon_1_80.json"), management_fixture } });
        errdefer child.kill(std.testing.io);
        var pending = [_]std.c.pollfd{.{ .fd = listener, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pending, 1, 10000) <= 0) return error.FixtureTimeout;
        const fd = std.c.accept(listener, null, null);
        if (fd < 0) return error.AcceptFailed;
        defer _ = std.c.close(fd);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(a);
        var bytes: [512]u8 = undefined;
        while (!std.mem.endsWith(u8, data.items, "ENDPUB\n")) {
            var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 10000) <= 0) return error.FixtureTimeout;
            const n = std.c.read(fd, &bytes, bytes.len);
            if (n <= 0) return error.FixtureClosed;
            try data.appendSlice(a, bytes[0..@intCast(n)]);
            if (data.items.len > 16384) return error.FixtureTooLarge;
        }
        const newline = std.mem.indexOfScalar(u8, data.items, '\n') orelse return error.FixtureProtocol;
        var password: [32]u8 = undefined;
        std.c.arc4random_buf(&password, password.len);
        // Hex is a valid header token too; the fixture uses it to verify copied
        // AUTHKEY without a persistent test credential or command-line secret.
        const alphabet = "0123456789abcdef";
        for (&password) |*b| b.* = alphabet[b.* & 15];
        if (std.c.write(fd, &password, password.len) != password.len) return error.FixtureClosed;
        return .{ .child = child, .port = try std.fmt.parseInt(u16, data.items[0..newline], 10), .pem = try a.dupe(u8, data.items[newline + 1 .. data.items.len - "ENDPUB\n".len]), .password = password };
    }
    pub fn deinit(self: *Fixture) void {
        if (self.child.id != null) self.child.kill(std.testing.io);
        a.free(self.pem);
        std.crypto.secureZero(u8, &self.password);
    }
};

const Replies = struct {
    prompts: usize = 0,
    reject: bool = false,
    capability_calls: usize = 0,
    connection_progress: ?*progress.Tracker = null,
    fn grantCapability(raw: *anyopaque, _: *const redfish.Discovery) !svc.Capability {
        const self: *Replies = @ptrCast(@alignCast(raw));
        self.capability_calls += 1;
        return .{ .binding_generation = owner.generation, .write_granted = true };
    }
    fn reply(context: *anyopaque, challenge: trust.Challenge, cancel: *const std.atomic.Value(bool)) !trust.TrustChoice {
        const self: *Replies = @ptrCast(@alignCast(context));
        try std.testing.expect(challenge.owner.eql(owner));
        try std.testing.expect(challenge.operation.eql(operation));
        try std.testing.expectEqualStrings("127.0.0.1", challenge.authority.host());
        try std.testing.expect(!cancel.load(.acquire));
        if (self.connection_progress) |tracker| {
            const waiting = tracker.snapshot();
            try std.testing.expectEqual(progress.Stage.waiting_certificate, waiting.stage);
            try std.testing.expect(waiting.waiting_for_user);
        }
        self.prompts += 1;
        return if (self.reject) .reject else .once;
    }
    fn verify(_: ?*anyopaque, authority: trust.Authority, chain: []const []const u8) !trust.VerificationResult {
        try std.testing.expectEqualStrings("127.0.0.1", authority.host);
        try std.testing.expect(chain.len == 1 and chain[0].len > 500 and chain[0][0] == 0x30);
        return .{ .failures = .{ .untrusted_issuer = true } };
    }
};
pub fn selected(pem: []const u8) !profile.Profile {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &digest, .{});
    return profile.syntheticForTest(.{ .trusted_channel = true, .manufacturer = "Sugon", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "1.80", .oem_namespace = "Public", .kvm_login_resource = profile.kvm_login_path, .oem_rfb = true }, .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = pem, .public_key_sha256 = digest, .public_key_source = "ephemeral loopback-only fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
}

const Worker = struct {
    backend: *native.NativeDriver,
    payload: console.model.Payload,
    plan: *const console.route.Plan,
    cancel: *std.atomic.Value(bool),
    password: [32]u8,
    cancel_after_begin: bool,
    truncate_video: bool = false,
    readonly_after_frame: bool = false,
    revoked_trust_store: ?*trust.Store = null,
    probe_missing_headers: bool = false,
    expected_begin_error: ?anyerror = null,
    failure: ?anyerror = null,
    published: u64 = 0,
    cleanup_ns: u64 = 0,
    begin_progress: ?progress.Snapshot = null,
    fn run(self: *Worker) void {
        self.work() catch |err| {
            self.failure = err;
        };
        const driver = self.backend.driver();
        driver.abort(driver.context);
        const before_cleanup = driver.now_ns(driver.context);
        const receipt = driver.cleanup(driver.context);
        self.cleanup_ns = driver.now_ns(driver.context) - before_cleanup;
        if (driver.cleanup(driver.context) != receipt and self.failure == null) self.failure = error.NonIdempotentCleanup;
        if (receipt != .released and self.failure == null) self.failure = error.CleanupIncomplete;
    }
    fn work(self: *Worker) !void {
        const driver = self.backend.driver();
        if (self.expected_begin_error) |err| {
            try std.testing.expectError(err, driver.begin(driver.context, &self.payload, self.plan, operation, self.cancel));
            return;
        }
        const authenticated = try driver.begin(driver.context, &self.payload, self.plan, operation, self.cancel);
        if (self.backend.connection_progress) |tracker| self.begin_progress = tracker.snapshot();
        if (self.backend.management_policy == .read_only) {
            for ([_]power.Method{ .post, .patch }) |method| {
                try std.testing.expectError(error.ManagementReadOnly, driver.management_io.?(driver.context, .{ .sequence = 98, .operation = operation, .purpose = .write, .method = method, .uri = "/redfish/v1/ForbiddenWrite", .body = "{}" }));
                try std.testing.expect(self.backend.transaction == null);
            }
        }
        if (self.probe_missing_headers) try self.missingWebHeaders();
        if (self.cancel_after_begin) {
            self.cancel.store(true, .release);
            if (self.revoked_trust_store) |store| store.cancelOwner(owner);
            // Let the independently owned transport worker observe the same
            // cancellation before testing cleanup. Existing streams survive;
            // the ordinary protocol and any new stream remain revoked.
            driver.wait(driver.context, 20);
            try std.testing.expect(!self.backend.pair.transport.done.load(.acquire));
            var out: [32]u8 = undefined;
            try std.testing.expectError(error.Cancelled, driver.read(driver.context, &out));
            try std.testing.expectError(error.Cancelled, driver.write(driver.context, "ordinary cancelled video write"));
            const completion = (try driver.management_io.?(driver.context, .{ .sequence = 99, .operation = operation, .purpose = .query, .method = .get, .uri = "/redfish/v1/CancelledRead", .body = "" })).?;
            try std.testing.expect(completion.transport_error and completion.sequence == 99);
            try std.testing.expect(self.backend.transaction == null);
            try std.testing.expectError(error.Cancelled, self.backend.pair.transport.openTcpStream(self.backend.pair.destination));
            return;
        }
        var budget = budgets.Budget.init(128 * 1024 * 1024);
        defer budget.deinit() catch unreachable;
        var framebuffer = frames.Service.init(a, owner, &budget);
        defer framebuffer.deinit() catch unreachable;
        var remote_input = input.Service.init(owner);
        var pipeline = try console.video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
        defer pipeline.deinit();
        try pipeline.start(authenticated);
        var out: [7]u8 = undefined;
        const deadline = driver.now_ns(driver.context) + 5 * std.time.ns_per_s;
        while (pipeline.published_frames == 0) {
            if (driver.now_ns(driver.context) >= deadline) return error.FirstFrameTimeout;
            const n = driver.read(driver.context, &out) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n != 0) _ = try pipeline.feed(out[0..n], driver.now_ns(driver.context));
            try pipeline.pump(.{ .context = driver.context, .write = driver.write, .abort = driver.abort });
            driver.wait(driver.context, 1);
        }
        self.published = pipeline.published_frames;
        var lease = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 1, 2, 3, 255 }, lease.snapshot.pixels);
        lease.release();
        if (self.readonly_after_frame) {
            self.cancel.store(true, .release);
            driver.wait(driver.context, 20);
            try std.testing.expectError(error.Cancelled, self.backend.pair.transport.openTcpStream(self.backend.pair.destination));
            return;
        }
        if (self.truncate_video) {
            // One TLS record cannot finish this complete WS packet. Cleanup
            // must close this stream rather than insert a Close into its body.
            const payload: [32768]u8 = @splat(0);
            const packet = try console.video.ws.clientFrame(a, .binary, true, &payload);
            defer a.free(packet);
            const written = try driver.write(driver.context, packet);
            try std.testing.expect(written > 8 and written < packet.len);
            self.cancel.store(true, .release);
            return;
        }
        var body = "{\"ResetType\":\"On\"}".*;
        var authkey = self.password;
        var uri = "/redfish/v1/Systems/one/Actions/ComputerSystem.Reset".*;
        var completed = try driver.management_io.?(driver.context, .{ .sequence = 17, .operation = operation, .purpose = .write, .method = .post, .uri = &uri, .body = &body, .if_match = "\"first\"", .authkey = &authkey });
        // The producer may immediately wipe/mutate the borrowed Outbound.
        @memset(&body, 'x');
        @memset(&authkey, 0);
        @memset(&uri, 'x');
        while (completed == null) {
            if (driver.now_ns(driver.context) >= deadline) return error.ManagementTimeout;
            completed = try driver.management_io.?(driver.context, null);
            driver.wait(driver.context, 1);
        }
        try std.testing.expectEqual(@as(u64, 17), completed.?.sequence);
        try std.testing.expectEqual(@as(u16, 202), completed.?.status);
        try std.testing.expectEqualStrings("/redfish/v1/TaskService/Tasks/own", completed.?.location.?);
        try std.testing.expectEqual(@as(u64, 2000), completed.?.retry_after_ms.?);
    }
    fn missingWebHeaders(self: *Worker) !void {
        // A negative wire probe uses the already trusted, privately owned
        // management stream. It deliberately omits the vendor's WEB context
        // defaults and must not mint any additional session in the fixture.
        const channel = &self.backend.management_channel.?;
        try std.testing.expectEqual(channel.start, channel.end);
        const body = "{\"Type\":\"WEB\",\"KvmAuthentication\":\"own-web\"}";
        const bytes = try http.buildRequest(a, "POST", .{ .host = self.payload.endpoint.host, .port = self.payload.endpoint.https_port }, profile.kvm_login_path, &.{ .{ .name = "X-Auth-Token", .value = self.backend.web_session.?.token.bytes }, .{ .name = "Content-Type", .value = "application/json" } }, body);
        defer {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        var parser = http.ResponseParser.init(a, .{});
        defer parser.deinit();
        const driver = self.backend.driver();
        const deadline = driver.now_ns(driver.context) + 5 * std.time.ns_per_s;
        var offset: usize = 0;
        var buffer: [1024]u8 = undefined;
        while (!parser.isDone()) {
            if (driver.now_ns(driver.context) >= deadline) return error.MissingHeadersProbeTimeout;
            if (offset != bytes.len) {
                switch (try channel.client.write(bytes[offset..])) {
                    .bytes => |n| offset += n,
                    .progress => {},
                }
            } else switch (try channel.client.read(&buffer)) {
                .bytes => |n| {
                    if (n == 0) return error.MissingHeadersProbeClosed;
                    try std.testing.expectEqual(n, try parser.feed(buffer[0..n]));
                },
                .progress => {},
            }
            driver.wait(driver.context, 1);
        }
        try std.testing.expectEqual(@as(u16, 201), parser.status);
        var doc = try redfish.Document.parse(a, profile.kvm_login_path, parser.status, parser.body(), null, 1);
        defer doc.deinit();
        try std.testing.expect(!doc.accepted());
        const selected_profile = self.backend.selected.value;
        const evidence = selected_profile.evidence;
        try std.testing.expectError(error.KvmAuthenticationFailed, auth.acceptKvmSessionHeader(a, .{ .profile_id = @tagName(selected_profile.id), .firmware = evidence.firmware, .public_key_pem = evidence.public_key_pem, .public_key_sha256 = evidence.public_key_sha256, .source_uri = evidence.public_key_source, .verified = true, .web_headers_verified = true, .kvm_schema_verified = true }, owner, doc, parser.header("X-Auth-Token"), null));
    }
};

const Mode = enum { firmware_progress, optional_malformed, optional_disconnect, optional_changed_cert, graceful, cancel, untrusted, missing_headers, mixed, logout_timeout, idle_management, cleanup_changed_cert, partial_video, mapped_read, missing_mapping, partial_mapping, missing_fields, manager_linked_system, broken_canonical, multiple_members, paged_members, partial_collection, missing_identity, observed_partial };
fn endToEnd(mode: Mode) !void {
    return endToEndWithManagerLink(mode, false);
}
fn endToEndWithManagerLink(mode: Mode, object_manager_links: bool) !void {
    const optional_failure = mode == .optional_malformed or mode == .optional_disconnect or mode == .optional_changed_cert;
    const cancel_after_begin = switch (mode) {
        .firmware_progress, .optional_malformed, .optional_disconnect, .cancel, .logout_timeout, .mapped_read, .missing_mapping, .partial_mapping, .missing_fields, .manager_linked_system, .broken_canonical, .multiple_members, .paged_members, .partial_collection, .missing_identity, .observed_partial => true,
        else => false,
    };
    const no_trust_reply = mode == .untrusted;
    const fixture_mode = switch (mode) {
        .firmware_progress => "firmware-progress",
        .optional_malformed => "optional-malformed",
        .optional_disconnect => "optional-disconnect",
        .optional_changed_cert => "optional-changed-cert",
        .graceful => "graceful",
        .cancel => "cancel",
        .untrusted => "untrusted",
        .missing_headers => "missing-headers",
        .mixed => "mixed",
        .logout_timeout => "logout-timeout",
        .idle_management => "idle-management",
        .cleanup_changed_cert => "cleanup-changed-cert",
        .partial_video => "partial-video",
        .mapped_read => "mapped-read",
        .missing_mapping => "missing-mapping",
        .partial_mapping => "partial-mapping",
        .missing_fields => "missing-fields",
        .manager_linked_system => "manager-linked-system",
        .broken_canonical => "broken-canonical",
        .multiple_members => "multiple-members",
        .paged_members => "paged-members",
        .partial_collection => "partial-collection",
        .missing_identity => "missing-identity",
        .observed_partial => "observed-partial",
    };
    const server_mode = if (object_manager_links) try std.fmt.allocPrint(a, "object-{s}", .{fixture_mode}) else try a.dupe(u8, fixture_mode);
    defer a.free(server_mode);
    var server = try Fixture.start(server_mode);
    defer server.deinit();
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tx = try credentials.Transaction.init();
    defer tx.deinit();
    const reference = (try tx.stage(std.testing.io, a, &server.password, null)).?;
    defer a.free(reference);
    tx.commit();
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    try secret_store.authorize(owner, operation, reference);
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var library: @import("proto/ssh/session.zig").Library = .{ .active = false };
    var cancel: std.atomic.Value(bool) = .init(false);
    const payload: console.model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture", .credential_ref = reference };
    var plan = try console.route.Plan.init(a, owner, null, &.{}, .{ .host = payload.endpoint.host, .port = server.port });
    defer plan.deinit();
    const context: contexts.HostContext = .{ .owner = owner, .operation = operation, .target = .{ .window_id = @fromBackingInt(@intCast(1)), .workspace_id = @fromBackingInt(@intCast(1)) }, .transports = transport.Factory{ .allocator = a, .library = &library }, .secrets = secret_store.facade(owner), .trust = .{ .tls = trust_store.facade(owner) } };
    var journal_backend: ledger.MemoryBackend = .{ .allocator = a };
    defer journal_backend.deinit();
    var journal = try ledger.Journal.init(a, journal_backend.backend());
    defer journal.deinit();
    var adapter: management.Adapter = undefined;
    try adapter.init(a, owner, payload.endpoint, &journal, null);
    defer adapter.deinit();
    const initial_capability: svc.Capability = .{ .binding_generation = owner.generation };
    try adapter.setSnapshots(.{ .capability = initial_capability }, .{ .capability = initial_capability }, false);
    var tracker = progress.Tracker.init(0);
    var replies: Replies = .{ .connection_progress = &tracker };
    const unproven_mapping = switch (mode) {
        .optional_malformed, .optional_disconnect, .missing_mapping, .partial_mapping, .broken_canonical, .multiple_members, .paged_members, .partial_collection, .missing_identity, .observed_partial => true,
        else => false,
    };
    const backend = try native.NativeDriver.prepare(a, context, payload, &plan, &cancel, .{ .selected = try selected(server.pem), .callbacks = if (no_trust_reply) null else .{ .context = &replies, .trust_reply = Replies.reply, .capability = if (unproven_mapping) Replies.grantCapability else null }, .management_adapter = &adapter, .management_policy = switch (mode) {
        .graceful, .missing_headers, .mixed => .user_approved,
        else => .read_only,
    }, .progress = &tracker });
    defer backend.deinit() catch unreachable;
    if (mode == .firmware_progress or optional_failure) backend.firmware_pending_verification = true;
    // Preparing is memory/config-only and cannot perform native IO here.
    try std.testing.expect(!backend.pair.transport.started);
    try std.testing.expectError(error.NativeIoOnConfigurationThread, backend.driver().begin(backend, &payload, &plan, operation, &cancel));
    var worker: Worker = .{ .backend = backend, .payload = payload, .plan = &plan, .cancel = &cancel, .password = server.password, .cancel_after_begin = cancel_after_begin, .truncate_video = mode == .partial_video, .readonly_after_frame = mode == .idle_management or mode == .cleanup_changed_cert, .revoked_trust_store = if (mode == .cancel) &trust_store else null, .probe_missing_headers = mode == .missing_headers, .expected_begin_error = if (no_trust_reply) error.TrustReplyUnavailable else if (mode == .optional_changed_cert) error.ManagementPeerChanged else null };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    if (mode == .optional_changed_cert) {
        try std.testing.expectEqual(@as(usize, 1), replies.prompts);
        try std.testing.expect(backend.diagnostics.firmware_observed);
        try std.testing.expect(!backend.diagnostics.video_upgraded);
        try std.testing.expectEqual(native.RemoteRelease.not_created, backend.diagnostics.kvm_logout);
        try std.testing.expectEqual(native.RemoteRelease.unknown, backend.diagnostics.web_logout);
        try std.testing.expectEqual(console.Cleanup.released, backend.diagnostics.local_cleanup);
        const rejected_cleanup = backend.logoutDiagnostics().?.web;
        try std.testing.expectEqual(error.CleanupPeerChanged, rejected_cleanup.failure.?);
        try std.testing.expect(!rejected_cleanup.request_dispatched);
        const term = try server.child.wait(std.testing.io);
        try std.testing.expect(term.success());
        return;
    }
    try std.testing.expectEqual(@as(usize, if (no_trust_reply) 0 else 1), replies.prompts);
    const mapped = !no_trust_reply and !unproven_mapping;
    const management_verified = mapped or mode == .missing_mapping or mode == .broken_canonical or mode == .observed_partial;
    const has_fields = management_verified and mode != .missing_fields;
    try std.testing.expectEqual(mapped, backend.diagnostics.system_mapping_verified);
    try std.testing.expectEqual(has_fields, backend.driver().management_available.?(backend));
    try std.testing.expectEqual(@as(usize, if (mode == .missing_mapping or mode == .broken_canonical or mode == .observed_partial) 1 else 0), replies.capability_calls);
    if (backend.discoveryDiagnostics()) |diagnostic| {
        try std.testing.expectEqual(@as(usize, 1), diagnostic.manager_count);
        const expected_systems: usize = switch (mode) {
            .optional_malformed, .optional_disconnect => 0,
            .manager_linked_system, .broken_canonical, .missing_identity, .observed_partial => 2,
            // An error envelope cannot contribute its apparent Members; only
            // the Manager's independently followed target is discovered.
            .partial_collection => 1,
            .multiple_members, .paged_members => 3,
            else => 1,
        };
        try std.testing.expectEqual(expected_systems, diagnostic.system_count);
        try std.testing.expectEqual(mapped, diagnostic.mapping_verified);
        try std.testing.expectEqual(management_verified, diagnostic.management_target_verified);
        try std.testing.expectEqual(!management_verified, diagnostic.management_target_error != null);
        try std.testing.expectEqual(mode == .observed_partial, diagnostic.resource_association_verified);
        try std.testing.expectEqual(if (mode == .observed_partial) @as(?native.ResourceAssociationMethod, .reviewed_public_ids_and_chassis) else null, diagnostic.resource_association_method);
        try std.testing.expect(!diagnostic.readonly_system_projection);
        const readonly_rejection: ?progress.Code = switch (mode) {
            .optional_malformed, .optional_disconnect => .readonly_discovery_incomplete,
            .partial_mapping => .readonly_member_rejected,
            .multiple_members, .paged_members => .readonly_members_not_single,
            .partial_collection => .readonly_collection_rejected,
            .missing_identity => .readonly_identity_missing,
            else => null,
        };
        try std.testing.expectEqual(readonly_rejection, diagnostic.readonly_rejection);
        if (readonly_rejection != null and !optional_failure) {
            try std.testing.expect(diagnostic.readonly_collection_count > 0);
            try std.testing.expect(diagnostic.readonly_collection_status != null);
            if (diagnostic.readonly_system_projection) try std.testing.expect(diagnostic.readonly_system_identity_present);
        }
        if (mapped) {
            try std.testing.expect(diagnostic.mapping_error == null);
            try std.testing.expect(diagnostic.mapping_rejection == null);
        } else if (optional_failure) {
            try std.testing.expectEqual(error.DiscoveryIncomplete, diagnostic.mapping_error.?);
            try std.testing.expect(diagnostic.mapping_rejection == null);
            try std.testing.expect(!diagnostic.management_discovery_complete);
            try std.testing.expectEqual(if (mode == .optional_malformed) error.SyntaxError else error.TlsFailed, diagnostic.management_discovery_error.?);
            try std.testing.expect(backend.diagnostics.firmware_observed);
        } else {
            const mapping_error = diagnostic.mapping_error orelse return error.MissingMappingDiagnostic;
            try std.testing.expectEqualStrings("MappingUnverified", @errorName(mapping_error));
            try std.testing.expectEqual(if (mode == .missing_mapping) native.MappingRejection.manager_servers_not_single else native.MappingRejection.system_document_rejected, diagnostic.mapping_rejection.?);
            if (mode == .partial_mapping) {
                try std.testing.expectEqual(@as(?u16, 200), diagnostic.mapping_system_status);
                try std.testing.expectEqual(svc.Validity.partial_with_error, diagnostic.mapping_system_validity.?);
            } else if (mode != .missing_mapping) {
                try std.testing.expectEqual(@as(?u16, 404), diagnostic.mapping_system_status);
                try std.testing.expectEqual(svc.Validity.unavailable, diagnostic.mapping_system_validity.?);
            }
        }
    } else try std.testing.expect(no_trust_reply);
    const call: svc.Call = .{ .owner = owner, .binding_generation = owner.generation };
    const power_binding = adapter.powerBinding();
    const power_api = try power_binding.borrow(svc.PowerService, svc.power_key, owner);
    var power_snapshot = try power_api.snapshot(power_binding.context, call, a);
    defer power_snapshot.deinit();
    const boot_binding = adapter.bootBinding();
    const boot_api = try boot_binding.borrow(svc.BootService, svc.boot_key, owner);
    var boot_snapshot = try boot_api.snapshot(boot_binding.context, call, a);
    defer boot_snapshot.deinit();
    try std.testing.expect(!power_snapshot.value.capability.write_granted and !boot_snapshot.value.capability.write_granted);
    try std.testing.expectEqual(management_verified, power_snapshot.value.capability.system_mapping_verified);
    try std.testing.expectEqual(management_verified, boot_snapshot.value.capability.system_mapping_verified);
    if (mode == .missing_mapping or mode == .broken_canonical) {
        try std.testing.expectEqual(svc.SecondaryAuth.disabled, power_snapshot.value.capability.secondary_auth);
        try std.testing.expect(power_snapshot.value.capability.secondary_auth_evidence.permitsWrite());
        try std.testing.expectEqualStrings("/redfish/v1/Systems/one", boot_snapshot.value.write_uri.?);
        try std.testing.expect(!power_snapshot.value.capability.write_requestable and !boot_snapshot.value.capability.write_requestable);
    }
    if (has_fields) {
        // Discovery was destroyed during cleanup: typed caches must own their
        // observed fields, options and per-field evidence independently.
        try std.testing.expectEqual(svc.PowerState.on, power_snapshot.value.state.value.?);
        if (mode == .manager_linked_system) try std.testing.expectEqualStrings("/redfish/v1/Systems/canonical", power_snapshot.value.state.evidence.source_uri);
        try std.testing.expectEqual(svc.Validity.valid, power_snapshot.value.state.evidence.validity);
        if (mode == .observed_partial) {
            try std.testing.expectEqual(@as(usize, 8), power_snapshot.value.reset_types.value.?.len);
            try std.testing.expectEqual(svc.Validity.partial_with_error, power_snapshot.value.resource_evidence.validity);
            try std.testing.expectEqual(svc.Validity.partial_with_error, boot_snapshot.value.resource_evidence.validity);
            try std.testing.expectEqual(@as(usize, 20), boot_snapshot.value.options.len);
            for (boot_snapshot.value.options) |option| try std.testing.expectEqual(svc.Validity.valid, option.evidence.validity);
            try std.testing.expect(boot_snapshot.value.allowed_enabled.evidence.permitsWrite());
            try std.testing.expect(!boot_snapshot.value.capability.write_requestable and !power_snapshot.value.capability.write_requestable);
        } else {
            try std.testing.expectEqual(@as(usize, 2), power_snapshot.value.reset_types.value.?.len);
            try std.testing.expectEqualStrings("On", power_snapshot.value.reset_types.value.?[0]);
            try std.testing.expectEqualStrings("GracefulShutdown", power_snapshot.value.reset_types.value.?[1]);
        }
        try std.testing.expectEqualStrings("Disabled", boot_snapshot.value.state.enabled.?);
        try std.testing.expectEqualStrings("None", boot_snapshot.value.state.target.?);
        try std.testing.expectEqualStrings("UEFI", boot_snapshot.value.state.mode.?);
        try std.testing.expectEqual(svc.Validity.valid, boot_snapshot.value.allowed_targets.evidence.validity);
        try std.testing.expectEqual(@as(usize, 20), boot_snapshot.value.boot_order.value.?.len);
    } else {
        try std.testing.expect(power_snapshot.value.state.value == null);
        try std.testing.expectEqual(svc.Validity.unavailable, power_snapshot.value.state.evidence.validity);
        try std.testing.expect(boot_snapshot.value.state.enabled == null and boot_snapshot.value.allowed_targets.value == null and boot_snapshot.value.boot_order.value == null);
    }
    try std.testing.expectEqual(@as(usize, 0), journal_backend.writes);
    try std.testing.expectEqual(!no_trust_reply, backend.diagnostics.video_upgraded);
    try std.testing.expectEqual(console.Cleanup.released, backend.diagnostics.local_cleanup);
    const remote_release: native.RemoteRelease = if (no_trust_reply) .not_created else if (mode == .mixed or mode == .cleanup_changed_cert) .unknown else .confirmed;
    try std.testing.expectEqual(remote_release, backend.diagnostics.web_logout);
    try std.testing.expectEqual(if (mode == .logout_timeout) native.RemoteRelease.unknown else remote_release, backend.diagnostics.kvm_logout);
    const logout_diagnostic = backend.logoutDiagnostics() orelse return error.MissingLogoutDiagnostics;
    if (mode == .partial_video) {
        try std.testing.expectEqualStrings("incomplete_frame_aborted", @tagName(logout_diagnostic.websocket_close));
    } else if (!no_trust_reply) try std.testing.expectEqual(native.WebSocketClose.frame_sent, logout_diagnostic.websocket_close);
    if (mode == .cleanup_changed_cert) {
        for ([_]native.LogoutAttempt{ logout_diagnostic.web, logout_diagnostic.kvm }) |attempt| {
            try std.testing.expectEqual(native.LogoutStage.connection_failed, attempt.stage);
            try std.testing.expectEqualStrings("CleanupPeerChanged", @errorName(attempt.failure.?));
            try std.testing.expect(attempt.fresh_connection and !attempt.request_dispatched);
        }
    } else if (remote_release == .confirmed and mode != .logout_timeout) {
        for ([_]native.LogoutAttempt{ logout_diagnostic.web, logout_diagnostic.kvm }) |attempt| {
            try std.testing.expectEqual(native.LogoutStage.confirmed, attempt.stage);
            try std.testing.expectEqual(@as(?u16, 200), attempt.http_status);
            try std.testing.expect(attempt.request_dispatched);
            try std.testing.expect(attempt.fresh_connection);
            try std.testing.expect(!attempt.management_failed_at_entry and !attempt.transport_done_at_entry and !attempt.transport_done_at_exit);
        }
    }
    if (mode == .logout_timeout) {
        try std.testing.expect(worker.cleanup_ns >= 900 * std.time.ns_per_ms);
        try std.testing.expect(worker.cleanup_ns < 2 * std.time.ns_per_s);
        try std.testing.expectEqual(native.LogoutStage.transaction_failed, logout_diagnostic.kvm.stage);
        try std.testing.expectEqualStrings("HttpTimeout", @errorName(logout_diagnostic.kvm.failure.?));
        try std.testing.expect(logout_diagnostic.kvm.request_dispatched);
        try std.testing.expectEqual(native.LogoutStage.confirmed, logout_diagnostic.web.stage);
        try std.testing.expect(logout_diagnostic.web.request_dispatched and logout_diagnostic.web.management_failed_at_entry and logout_diagnostic.web.fresh_connection);
    }
    if (!cancel_after_begin and !no_trust_reply) try std.testing.expectEqual(@as(u64, 1), worker.published);
    if (worker.begin_progress) |observed| {
        try std.testing.expectEqual(progress.Stage.websocket_upgrade, observed.stage);
        try std.testing.expect(observed.failure_code == null);
        var saw_web = false;
        var saw_kvm = false;
        var saw_upgrade = false;
        var saw_video_tls = false;
        for (observed.events[0..observed.event_count]) |event| {
            if (event.resource == .web_session and event.http_status == 201) saw_web = true;
            if (event.resource == .kvm_session and event.http_status == 201) saw_kvm = true;
            if (event.resource == .websocket and event.http_status == 101) saw_upgrade = true;
            if (event.kind == .stage and event.stage == .video_tls_handshake) saw_video_tls = true;
            if (saw_video_tls) try std.testing.expect(event.stage != .tls_handshake and event.stage != .waiting_certificate);
        }
        try std.testing.expect(saw_kvm and saw_upgrade and saw_video_tls);
        // Twenty separately sourced BootOption reads can retire early WEB
        // events from the intentionally bounded progress ring.
        if (mode != .observed_partial) try std.testing.expect(saw_web);
        if (mode == .observed_partial) {
            const issue = observed.discovery_issue.?;
            try std.testing.expectEqual(@as(?u16, 404), issue.http_status);
            try std.testing.expectEqual(progress.Code.manager_system_link_missing, issue.code);
            try std.testing.expectEqualStrings("/redfish/v1/Systems/broken-alias", issue.context.?.resource_path.?.text());
            try std.testing.expectEqualStrings("/redfish/v1/Managers/manager-B", issue.context.?.source_path.?.text());
            try std.testing.expectEqualStrings("/Links/ManagerForServers", issue.context.?.source_property.?.text());
            try std.testing.expect(std.mem.indexOf(u8, issue.context.?.response_errors.?.text(), "Base.1.19.ResourceNotFound") != null);
            var mapping_checked = false;
            for (observed.events[0..observed.event_count]) |event| if (event.code == .mapping_system_document_rejected) {
                mapping_checked = true;
                try std.testing.expectEqual(@as(?u16, 404), event.context.?.http_status);
                try std.testing.expectEqualStrings("/redfish/v1/Systems/broken-alias", event.context.?.resource_path.?.text());
                try std.testing.expectEqualStrings("Base.1.19.ResourceNotFound", event.context.?.response_errors.?.text());
            };
            try std.testing.expect(mapping_checked);
        }
        if (mode == .firmware_progress) {
            var firmware_verified = false;
            var confirmations: usize = 0;
            var discoveries: usize = 0;
            var systems_before_firmware = false;
            var manager_before_firmware = false;
            for (observed.events[0..observed.event_count]) |event| {
                if (event.code == .firmware_verified) firmware_verified = true;
                if (event.stage == .redfish_discovery) try std.testing.expect(firmware_verified);
                if (event.kind == .stage and event.stage == .firmware_confirmation) confirmations += 1;
                if (event.kind == .stage and event.stage == .redfish_discovery) discoveries += 1;
                if (event.kind == .http_response and !firmware_verified) {
                    if (event.resource == .systems_collection) systems_before_firmware = true;
                    if (event.resource == .manager) manager_before_firmware = true;
                    if (event.resource == .systems_collection or event.resource == .managers_collection or event.resource == .manager or event.resource == .system) try std.testing.expectEqual(progress.Stage.firmware_confirmation, event.stage);
                }
            }
            try std.testing.expect(firmware_verified and !systems_before_firmware and manager_before_firmware);
            try std.testing.expectEqual(@as(usize, 1), confirmations);
            try std.testing.expectEqual(@as(usize, 1), discoveries);
        }
    } else try std.testing.expect(no_trust_reply);
    if (optional_failure) {
        var saw_degraded = false;
        const observed = worker.begin_progress.?;
        for (observed.events[0..observed.event_count]) |event| if (event.code == .management_discovery_incomplete) {
            saw_degraded = true;
            try std.testing.expect(event.error_code != null);
            try std.testing.expectEqual(progress.Resource.systems_collection, event.resource);
            try std.testing.expectEqual(progress.RequestPath.systems, event.context.?.path);
            try std.testing.expectEqual(progress.Channel.management, event.context.?.channel);
        };
        try std.testing.expect(saw_degraded);
    }
    const final_progress = tracker.snapshot();
    try std.testing.expectEqual(progress.Stage.cleanup, final_progress.stage);
    const safe_log = try std.json.Stringify.valueAlloc(a, final_progress, .{});
    defer a.free(safe_log);
    for ([_][]const u8{ payload.endpoint.host, payload.username, reference, &server.password, "X-Auth-Token", "Location", "/SessionService/Sessions/", "own-web", "own-kvm" }) |secret_or_identifier| try std.testing.expect(std.mem.indexOf(u8, safe_log, secret_or_identifier) == null);
    if (remote_release == .confirmed) {
        var confirmed: usize = 0;
        for (final_progress.events[0..final_progress.event_count]) |event| if (event.code == .remote_logout_confirmed) {
            try std.testing.expectEqual(@as(?u16, 200), event.http_status);
            confirmed += 1;
        };
        try std.testing.expectEqual(@as(usize, if (mode == .logout_timeout) 1 else 2), confirmed);
    }
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}

pub const LiveBackendScenario = enum { mapped, missing_mapping, partial_mapping, missing_fields, manager_linked_system, broken_canonical, multiple_members, paged_members, partial_collection, missing_identity };
pub fn liveBackendScenario(scenario: LiveBackendScenario) !void {
    try endToEnd(switch (scenario) {
        .mapped => .mapped_read,
        .missing_mapping => .missing_mapping,
        .partial_mapping => .partial_mapping,
        .missing_fields => .missing_fields,
        .manager_linked_system => .manager_linked_system,
        .broken_canonical => .broken_canonical,
        .multiple_members => .multiple_members,
        .paged_members => .paged_members,
        .partial_collection => .partial_collection,
        .missing_identity => .missing_identity,
    });
}

test "BMC native driver object ManagerForServers retains valid collection reads and verified mapping" {
    try endToEndWithManagerLink(.mapped_read, true);
}
test "BMC native driver object ManagerForServers 404 preserves collection address fields and cleanup" {
    try endToEndWithManagerLink(.broken_canonical, true);
}
test "BMC native driver live-shaped all REST WEB headers header-only KVM token separated logout tokens and Success envelope" {
    try endToEnd(.graceful);
}
test "BMC native driver cancellation blocks normal IO and new streams but deletes each owned session once" {
    try endToEnd(.cancel);
}
test "BMC native driver incomplete WS write aborts its video stream before owned session cleanup" {
    try endToEnd(.partial_video);
}
test "BMC native driver cancelled logout deadline retains KVM unknown and independently deletes WEB without replay" {
    try endToEnd(.logout_timeout);
}
test "BMC native driver video survives idle management TLS close and owns independent fresh logouts" {
    try endToEnd(.idle_management);
}
test "BMC native driver changed cleanup certificate sends no owned token and requests no new trust" {
    try endToEnd(.cleanup_changed_cert);
}
test "BMC native driver pending TLS trust without a reply sends zero application bytes" {
    try endToEnd(.untrusted);
}
test "BMC native driver live-shaped missing WEB defaults rejects misleading 201 Critical OEM response" {
    try endToEnd(.missing_headers);
}
test "BMC native driver live-shaped session DELETE Success mixed with Critical stays unknown" {
    try endToEnd(.mixed);
}

test "BMC native driver pending firmware metadata stays in confirmation before management discovery" {
    try endToEnd(.firmware_progress);
}
test "BMC native driver optional malformed management discovery preserves required firmware proof and KVM startup" {
    try endToEnd(.optional_malformed);
}
test "BMC native driver optional truncated management stream reopens the accepted peer before KVM startup" {
    try endToEnd(.optional_disconnect);
}
test "BMC native driver optional management recovery rejects a changed peer without tokens or KVM startup" {
    try endToEnd(.optional_changed_cert);
}
test "BMC native driver observed object Critical publishes independently bound valid fields and diagnostic" {
    try endToEnd(.observed_partial);
}
