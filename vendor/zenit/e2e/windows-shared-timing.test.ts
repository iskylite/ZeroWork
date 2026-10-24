// Run explicitly against -Dgpu-backend=d3d12. This verifies telemetry and
// collects native command-buffer timestamp attribution; not a smoothness gate.
import {clickTestId,query,request,stats,sleep,waitForServerReady} from './client';
import {test,run,assert,getSessionDir} from './runner';
import {writeFileSync} from 'node:fs';
test('Windows shared renderer publishes frame timing breakdown',async()=>{
  await waitForServerReady(15000);
  assert((await clickTestId('nav.modal')).ok,'modal navigation failed');
  const samples=[];
  // Idle gating stops frames once the open animation settles; on real GPUs
  // that is well under one 250 ms sample. Keep the tree rendering so every
  // sample reports a fresh frame's breakdown (this is a telemetry check).
  const redraw=await request('POST','/redraw',{continuous:true});
  assert(!(redraw as any).error,`continuous redraw unsupported: ${JSON.stringify(redraw)}`);
  try {
  for(let cycle=0;cycle<2;cycle++){
    assert((await clickTestId('story.modal.open')).ok,'modal open failed');
    for(let i=0;i<5;i++){
      await sleep(250);
      const value=await stats();
      for(const key of ['wait_for_frame_us','acquire_texture_us','encode_us','flush_us'] as const)
        assert(typeof value[key]==='number' && Number.isFinite(value[key]) && value[key]!>=0,`missing ${key}`);
      assert(value.total_frame_us===value.cpu_frame_us+value.wait_for_frame_us!+value.acquire_texture_us!, 'frame time decomposition is inconsistent');
      samples.push({cycle,i,wall_ms:Date.now(),...value});
      console.log(JSON.stringify(samples.at(-1)));
    }
    assert((await clickTestId('modal.close')).ok,'modal close failed');
    for(let i=0;i<20;i++){
      await sleep(250);
      if((await query('story.modal.dialog'))[0]?.visible===false)break;
    }
    assert((await query('story.modal.dialog'))[0]?.visible===false,'modal never closed');
  }
  } finally { await request('POST','/redraw',{continuous:false}); }
  writeFileSync(`${getSessionDir()}/shared-frame-timing.json`,JSON.stringify(samples,null,2));
  assert(new Set(samples.map(s=>s.frame_count)).size>=3,'too few distinct rendered frames');
  assert(samples.some(s=>s.gpu_timing_query_supported===true && s.timing_samples>0 && s.gpu_execute_us>0 && s.gpu_p95_us>0),
    'no completed native GPU timestamps reached app telemetry');
  assert(samples.every(s=>s.timing_samples<=(s.cpu_timing_samples??-1)), 'GPU samples include unresolved frames');
});
run();
