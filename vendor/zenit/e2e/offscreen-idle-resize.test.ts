// Background RPC regression: recycled offscreen content must repaint correctly,
// then reach a stable allocation-free frame set. No native pointer/focus input.
import {test,run,assert,appendLog,getSessionDir} from './runner';
import {waitForServerReady,clickTestId,request,screenshot,stats,resizeWindow,sleep} from './client';
const dir=getSessionDir();
test('multi-glass repaint after wallclock idle and rapid viewport changes',async()=>{
 await waitForServerReady();
 for(const story of ['glasslab','glassgroup','glassmerge']){
  await clickTestId(`nav.${story}`);await request('POST','/wait',{frames:24});
  assert((await screenshot(`${dir}/${story}-before.png`)).ok,'before capture');
  await sleep(4100);await request('POST','/wait',{frames:16});
  assert((await screenshot(`${dir}/${story}-repaint.png`)).ok,'repaint capture');
  for(let i=0;i<16;i++){await resizeWindow(i%2?980:1600,i%2?600:1000);await request('POST','/wait',{frames:2});}
  await resizeWindow(980,600);await request('POST','/wait',{frames:24});
  const creates:number[]=[];
  for(let i=0;i<8;i++){await request('POST','/wait',{frames:1});creates.push(Number((await stats()).texture_creates??0));}
  appendLog(`${story}: steady texture creates ${JSON.stringify(creates)}`);
  assert(creates.every(n=>n===0),`${story}: steady viewport thrashes textures`);
  assert((await screenshot(`${dir}/${story}-resized.png`)).ok,'resize capture');
 }
});
await run();
