import {createHash} from "node:crypto";
import {clickTestId,query,request,resizeWindow,screenshot,sleep,waitFor,waitForServerReady} from "./client";
import {assert,getSessionDir,run,test} from "./runner";
const native=(body:object)=>request("POST","/windows/native-input",body);
const source=async()=>{const text=(await query("drop.source-status"))[0]?.text;return text&&text!=="ready"?JSON.parse(text):null;};
test("Windows SDK source transfers all payloads and negotiates effects with an independent receiver",async()=>{
 await waitForServerReady(15000);await resizeWindow(1400,1100);
 const app=await native({action:"activate"});assert(app.foreground,"app not foreground");
 await clickTestId("gallery.drops");
 const directory=(await query("drop.directory"))[0].text!;
 const receiver=()=>native({action:"receiver-status"});
 const drop=async(mode:string,payload:string,kind:number,effect=1,keys:number[]=[],policy=7,preheld=false,allowed=7,logical=false)=>{
   await clickTestId(`drop.source-${mode}`);await clickTestId(allowed===1?"drop.source-copy-only":"drop.source-all");
   await native({action:"receiver-start",operations:policy,logical});
   const ready=await waitFor(async()=>{const t=await receiver();assert(!t.error,t.error);return t.ready?t:null;},6000,50);
   assert(ready.pid!==app.pid&&ready.hwnd!==app.hwnd,"receiver is not an independent process/window");
   const old=await source();
   try{
     const current=(await query("drop.source"))[0].rect;
     if(preheld)for(const vk of keys)await native({action:"key",vk,edge:"down"});
     await native({action:"pointer-down",x:current.x+current.w/2,y:current.y+current.h/2});
     const active=await waitFor(async()=>{const t=await source();assert(t?.phase!=="refused","source gesture refused");return t?.phase==="active"&&t.token!==old?.token?t:null;},5000,50);
     if(!preheld)for(const vk of keys)await native({action:"key",vk,edge:"down"});
     await native({action:"receiver-move"});
     const entered=await waitFor(async()=>{const t=await receiver();assert(!t.error,t.error);return t.enters>0?t:null;},6000,50);
     assert((await source()).phase==="active","source exited before drop");
     assert(entered.effect===effect,`${mode}: hover effect ${entered.effect}, expected ${effect}, keys=${entered.keys}`);
     await sleep(80);await native({action:"drag-release"});
     const done=await waitFor(async()=>{const t=await source();return t?.phase==="complete"&&t.token===active.token?t:null;},6000,50);
     assert(done.operation===effect&&!done.untrusted,`${mode}: source completion ${JSON.stringify(done)}`);
     const received=await receiver();assert(!received.error,received.error);
     if(effect){
       assert(received.drops===1&&received.kind===kind,`${mode}: receiver did not accept typed payload ${JSON.stringify(received)}`);
       assert(received.length===Buffer.byteLength(payload),`${mode}: full payload length differs`);
       assert(received.hash===createHash("sha256").update(payload).digest("hex"),`${mode}: full payload hash differs`);
       if(mode==="file"||mode==="uri")assert(received.files_exist,"CF_HDROP paths do not refer to existing guest fixture files");
     }else assert(received.drops===0,"rejected negotiation delivered data");
     console.log(`  independent receiver: mode=${mode}, token=${done.token}, kind=${received.kind}, bytes=${received.length}, effect=${done.operation}, keys=${entered.keys}`);
   }catch(error){
     console.log(`  failure: mode=${mode}, old=${JSON.stringify(old)}, source=${JSON.stringify(await source())}, rect=${JSON.stringify((await query("drop.source"))[0].rect)}, native=${JSON.stringify(await native({action:"status"}))}, receiver=${JSON.stringify(await receiver())}`);
     await screenshot(`${getSessionDir()}/source-external-failure-${mode}-${old?.token??0}.png`).catch(()=>{});
     throw error;
   }finally{
     await clickTestId("drop.source-cancel").catch(()=>{});
     for(const vk of [...keys].reverse())await native({action:"key",vk,edge:"up"}).catch(()=>{});
     await native({action:"drag-cancel"}).catch(()=>{});await native({action:"receiver-stop"}).catch(()=>{});
   }
 };
 await drop("text","source 中文 🧪",2);
 await drop("file",`${directory}\\输入-🧪.txt`,1);
 await drop("url","https://zenit.example/路径?q=🧪",1);
 await drop("internal","内部\0🧪payload",3);
 await drop("uri",`${directory}\\输入-🧪.txt`,1);
 await drop("text","source 中文 🧪",2,2,[0x10]);
 await drop("text","source 中文 🧪",2,1,[0x11]);
 await drop("text","source 中文 🧪",2,4,[0x10,0x11]);
 await drop("text","source 中文 🧪",2,0,[0x10],1);
 await drop("text","source 中文 🧪",2,2,[0x10],7,true);
 await drop("text","source 中文 🧪",2,1,[0x11],7,true);
 await drop("text","source 中文 🧪",2,4,[0x10,0x11],7,true);
 await drop("text","source 中文 🧪",2,0,[],2,false,1);
 await drop("file",`${directory}\\输入-🧪.txt`,1,2,[0x10],7,false,7,true);
 // Deactivate the source using only the independent window owned by this driver.
 await clickTestId("drop.source-text");await native({action:"receiver-start",operations:7});
 try{
   await waitFor(async()=>{const t=await receiver();assert(!t.error,t.error);return t.ready?t:null;},6000,50);
   const old=await source(),r=(await query("drop.source"))[0].rect;
   await native({action:"pointer-down",x:r.x+r.w/2,y:r.y+r.h/2});
   const active=await waitFor(async()=>{const t=await source();return t?.phase==="active"&&t.token!==old?.token?t:null;},5000,50);
   await native({action:"receiver-move"});
   await waitFor(async()=>(await receiver()).enters>0,5000,50);
   await native({action:"receiver-activate"});
   const done=await waitFor(async()=>{const t=await source();return t?.phase==="complete"&&t.token===active.token?t:null;},6000,50);
   assert(done.operation===0&&!done.untrusted,"deactivation did not cancel source");
   const t=await receiver();assert(t.foreground&&t.left_button_down,"source cancellation required mouse release or failed to deactivate");
   assert(t.drops===0&&t.leaves>0,"deactivation delivered payload or retained target hover");
   let denied=false;try{await native({action:"text",text:"forbidden"});}catch(error){denied=String(error).includes("foreground is not owned");}
   assert(denied,"driver injected text into independent receiver");
   console.log(`  source deactivation: token=${done.token}, cancellation while physical button held, no drop`);
 }finally{
   await native({action:"activate"}).catch(()=>{});await native({action:"drag-cancel"}).catch(()=>{});await native({action:"receiver-stop"}).catch(()=>{});
 }
 const stopped=await receiver();assert(!stopped.ready&&!stopped.thread_alive&&stopped.hwnd===0,"owned receiver leaked HWND/thread");
 await drop("text","source 中文 🧪",2);
 const recovered=await receiver();assert(!recovered.ready&&!recovered.thread_alive&&recovered.hwnd===0,"recovery drag leaked receiver");
 // Window lifecycle is last: RPC into the App becomes unavailable after close.
 await native({action:"receiver-start",operations:7});
 try{
   await waitFor(async()=>(await receiver()).ready,5000,50);
   const current=(await query("drop.source"))[0].rect,old=await source();
   await native({action:"pointer-down",x:current.x+current.w/2,y:current.y+current.h/2});
   const active=await waitFor(async()=>{const t=await source();return t?.phase==="active"&&t.token!==old?.token?t:null;},5000,50);
   await native({action:"receiver-move"});await waitFor(async()=>(await receiver()).enters>0,5000,50);
   const closed=await native({action:"close"});assert(closed.exited&&closed.exit_code===0&&!closed.hwnd_alive,"owned App did not close cleanly");
   const t=await waitFor(async()=>{const t=await receiver();assert(!t.error,t.error);return t.leaves>0?t:null;},5000,50);
   assert(t.left_button_down&&t.drops===0,"close released physical input or delivered payload");
   console.log(`  source window close: token=${active.token}, exit=0, HWND destroyed, target left while button held`);
 }finally{await native({action:"drag-cancel"}).catch(()=>{});await native({action:"receiver-stop"}).catch(()=>{});}
 const final=await receiver();assert(!final.ready&&!final.thread_alive&&final.hwnd===0,"close leaked receiver");
});
run();
