import { captureFrameAt, clickTestId, key, query, request, sleep, tree, waitFor, waitForServerReady } from './client';
import { decodePng } from './png';
import { assert, getSessionDir, run, test } from './runner';
import { writeFileSync } from 'node:fs';

test('Windows native timed capture rejects bad requests and preserves the selected Sheet frame', async () => {
  await waitForServerReady(15000);
  await clickTestId('nav.sheet');
  await sleep(400);
  const rootWidth = (await tree()).rect.w;
  // Sample animation time independently of variable GPU/VM submission latency.
  assert(!(await request('POST', '/clock', {step_ms:20})).error, 'animation clock failed');
  try {
    for (const [index, overrides] of [
      {after_ms:0}, {after_ms:2001}, {after_ms:'120'}, {click_test_id:''}, {click_test_id:'missing.capture.target'},
    ].entries()) {
      const response = await request('POST', '/frames/capture', {
        test_id:'story.sheet.panel', click_test_id:'story.sheet.open', after_ms:120,
        path:`${getSessionDir()}/invalid-${index}.png`, ...overrides,
      });
      assert(typeof response.error === 'string', `invalid capture accepted: ${JSON.stringify(response)}`);
      assert((await query('story.sheet.panel'))[0]?.visible === false, 'invalid capture performed an action');
    }
    for (let cycle=0; cycle<3; cycle++) {
      const path=`${getSessionDir()}/timed-sheet-${cycle}.png`;
      const sample=await captureFrameAt('story.sheet.panel','story.sheet.open',120,path);
      writeFileSync(`${getSessionDir()}/timed-sheet-${cycle}.json`,JSON.stringify(sample,null,2));
      assert(sample.ok && sample.requested_ms===120 && sample.sample_ms>=120 && sample.sample_ms<=200,
        `late or missing native frame: ${JSON.stringify(sample)}`);
      // Delay inspection until the live animation has finished; the returned
      // image must still be the locally selected intermediate submitted frame.
      await waitFor(async () => Math.abs((await query('story.sheet.panel'))[0].rect.x-780)<2 ? true : null, 15000, 50);
      const png=decodePng(path), scale=png.width/rootWidth, y=Math.round(500*scale);
      const lum=(x:number)=>{const p=(y*png.width+x)*png.channels;return (png.pixels[p]+png.pixels[p+1]+png.pixels[p+2])/3;};
      const background=lum(Math.round(680*scale)), panel=lum(png.width-10), threshold=(background+panel)/2;
      assert(panel-background>=2,'missing intermediate panel contrast');
      let edge:number|undefined;
      for(let x=png.width-1;x>Math.round(740*scale);x--) if(lum(x)<threshold){edge=(x+1)/scale;break;}
      assert(edge!==undefined && edge>788 && edge<1098 && Math.abs(edge-sample.x)<=2,
        `pixels are not the recorded intermediate: edge=${edge}, ${JSON.stringify(sample)}`);
      console.log(`  cycle=${cycle} requested=120ms actual=${sample.sample_ms}ms edge=${edge} recorded=${sample.x}`);
      await key('escape');
      await waitFor(async () => (await query('story.sheet.panel'))[0]?.visible===false ? true : null, 15000, 50);
    }
  } finally {
    await request('POST', '/clock', {step_ms:0});
  }
});
run();
