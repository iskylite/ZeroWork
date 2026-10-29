/** Native provider fixtures discover IDs through the same product tool as a
 * real model. System rules and JSON schemas carry no ambient session facts. */
import assert from 'node:assert/strict';
export function fixtureSessionIds(request:any, response:any):number[]|null {
 const callId='fixture-session-inventory';
 const messages=request.messages.slice(request.messages.findLastIndex((m:any)=>m.role==='user')+1);
 const result=messages.find((m:any)=>m.role==='tool'&&m.tool_call_id===callId);
 if(!result){
  assert(request.tools.some((t:any)=>t.function.name==='host__list_usessions'));
  if(!response.headersSent)response.writeHead(200,{'content-type':'text/event-stream'});
  response.end('data: '+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{index:0,id:callId,type:'function',function:{name:'host__list_usessions',arguments:'{"limit":16}'}}]}}]})+'\n\ndata: [DONE]\n\n');
  return null;
 }
 const receipt=JSON.parse(result.content);assert.equal(receipt.status,'succeeded');
 const state=JSON.parse(receipt.content[0].text);
 const ids=state.sessions.map((s:any)=>s.session_id);
 assert(ids.length>0&&ids.every((id:any)=>Number.isSafeInteger(id)&&id>0));
 return ids;
}
