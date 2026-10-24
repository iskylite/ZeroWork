import {createHash} from "node:crypto";
import {clickTestId, query, request, resizeWindow, sleep, waitFor, waitForServerReady} from "./client";
import {assert, getSessionDir, run, test} from "./runner";
const native=(body:object)=>request("POST","/windows/native-input",body);
const read=async()=>{const t=(await query("drop.status"))[0]?.text;return t&&t!=="ready"?JSON.parse(t):null;};
test("Windows external OLE source delivers typed Unicode payloads, policies and cancellation",async()=>{
 await waitForServerReady(15000);await resizeWindow(1400,1000);
 assert((await native({action:"activate"})).foreground,"owned app not foreground");
 assert((await clickTestId("gallery.drops")).ok,"drop fixture not activated");
 assert((await query("drop.capability"))[0]?.text==="OLE registered","native OLE target unavailable");
 const r=(await query("drop.target"))[0].rect;
 console.log(`  native target rectangle: ${JSON.stringify(r)}`);
 assert((await request("POST","/windows/native-desktop",{path:`${getSessionDir()}/windows-ole-ready.png`})).ok,"ready screenshot failed");
 const x=r.x+r.w*.65,y=r.y+r.h*.6;
 const directory=(await query("drop.directory"))[0].text!;
 let drops=0;
 const begin=async(kind:string,text:string,files:string[],operations=7)=>{
   assert((await native({action:"drag-start",x,y,kind,text,files,operations})).ok,"external OLE start failed");
   await waitFor(async()=>{const s=await native({action:"drag-status"});assert(!s.error,`${s.error}; ${JSON.stringify(s)}`);assert(!s.done,`OLE exited before release: ${JSON.stringify(s)}`);return s.active?s:null;},8000,50);
   await native({action:"drag-move",x:x+3,y:y+2});await sleep(100);
 };
 const finish=async(effect:number)=>{
   await native({action:"drag-release"});
   const s=await waitFor(async()=>{const s=await native({action:"drag-status"});assert(!s.error,s.error);return s.done?s:null;},8000,50);
   assert(s.effect===effect,`source effect ${s.effect}, expected ${effect}`);
 };
 const drop=async(stage:string,kind:string,text:string,files:string[],payloadKind:number,effect=1,operations=7)=>{
   const before=await read();await begin(kind,text,files,operations);
   const entered=await waitFor(async()=>{const s=await read();assert(s?.enters>(before?.enters??0),`No entered: ${JSON.stringify(s)}; rect=${JSON.stringify(r)}`);return s;},5000,50);
   assert(entered.enters>0,"native drag enter absent");
   if(stage==="files"){
     assert((await request("POST","/screenshot",{path:`${getSessionDir()}/windows-ole-enter.png`})).ok,"drop screenshot failed");
     await native({action:"drag-move",x:r.x+r.w+40,y:y+2});
     await waitFor(async()=>{const s=await read();return s?.leaves>entered.leaves?s:null;},5000,50);
     await native({action:"drag-move",x:x+3,y:y+2});
     await waitFor(async()=>{const s=await read();return s?.enters>entered.enters?s:null;},5000,50);
   }
   await finish(effect);drops++;
   const s=await waitFor(async()=>{const s=await read();return s?.drops===drops?s:null;},5000,50);
   const expected=kind==="files"?files.join("\n"):text;
   assert(s.length===Buffer.byteLength(expected),`${stage}: payload length differs`);
   assert((await query("drop.hash"))[0]?.text===createHash("sha256").update(expected).digest("hex"),`${stage}: complete payload hash differs`);
   assert(s.kind===payloadKind&&!s.truncated&&s.untrusted,`${stage}: payload metadata invalid`);
   assert(Math.abs(s.x-(x+3))<2&&Math.abs(s.y-(y+2))<2,`${stage}: wrong logical drop point ${s.x},${s.y}`);
   console.log(`  ${stage}: kind=${s.kind}, effect=${effect}, point=${s.x},${s.y}, UTF8 bytes=${s.length}`);
 };
 try {
   await drop("files","files","",[`${directory}\\输入-🧪.txt`,`${directory}\\另一个文件.txt`],1);
   await drop("text","text","中文 🧪\nsecond line",[],2);
   await drop("url","url","https://zenit.example/路径?q=🧪",[],1);
   await drop("internal","internal","内部\0🧪payload",[],3);
   for(const [policy,effect] of [["move",2],["link",4]] as const){
     await clickTestId(`drop.${policy}`);await drop(policy,"text",`operation-${policy}`,[],2,effect);
   }
   await clickTestId("drop.none");await begin("text","rejected",[]);await finish(0);await sleep(150);
   assert((await read()).drops===drops,"rejected policy delivered drop");
   await clickTestId("drop.copy");await begin("text","source-move-only",[],2);await finish(0);await sleep(150);
   assert((await read()).drops===drops,"source/target disjoint policy delivered drop");
   const before=await read();await begin("text","cancelled",[]);await native({action:"drag-cancel"});await sleep(150);
   assert((await native({action:"drag-status"})).done,"cancel did not finish OLE source");
   assert((await read()).drops===drops,"cancel delivered drop");
   assert((await read()).leaves>before.leaves,"cancel failed to clear entered target");
   await begin("text","x".repeat(1048577),[]);await finish(0);drops++;
   const cap=await waitFor(async()=>{const s=await read();return s?.drops===drops?s:null;},5000,50);
   assert(cap.truncated&&cap.length===0&&cap.untrusted,"oversize payload partially accepted");
   console.log(`  rejection/cancellation/capacity: passed; drops=${drops}`);
 } finally {await native({action:"drag-cancel"}).catch(()=>{});}
});
run();
