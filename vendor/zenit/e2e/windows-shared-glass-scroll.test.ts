import { writeFileSync } from 'node:fs';
import { clickTestId, mouseMove, query, screenshot, sleep, stats, tree, waitFor, waitForServerReady } from './client';
import { decodePng } from './png';
import { assert, getSessionDir, run, test } from './runner';

test('Shared GlassChrome refreshes scrolling backdrop and restores clipped surfaces', async () => {
  await waitForServerReady(15000);
  const backend = (await stats()).renderer_backend;
  assert(backend === 'd3d12' || backend === 'd3d11', 'requires a shared Windows renderer');
  assert((await clickTestId('nav.glasschrome')).ok, 'navigation failed');
  await waitFor(async () => (await query('story.glasschrome.edge'))[0] || null, 15000, 50);
  await mouseMove(20, 20);
  await sleep(500);
  // Light scene: rounded clipped stage, scrolling canvas and the measured
  // title-bar glass edge with its toolbar. The dark scene below is an
  // independent stage the scroll buttons never touch.
  const stage = (await query('story.glasschrome.stage'))[0].rect;
  const edge = (await query('story.glasschrome.edge'))[0].rect;
  const untouched = (await query('story.glasschrome.dark.stage'))[0].rect;
  const originalCanvas = (await query('story.glasschrome.canvas'))[0].rect;
  const logicalWidth = (await tree()).rect.w;
  const capture = async (name: string) => {
    const path = `${getSessionDir()}/glass-scroll-${name}.png`;
    assert((await screenshot(path)).ok, `capture ${name} failed`);
    return decodePng(path);
  };
  const baseline = await capture('initial');
  const scale = baseline.width / logicalWidth;
  type Rect = {x:number,y:number,w:number,h:number};
  const compare = (a:typeof baseline,b:typeof baseline,r:Rect) => {
    assert(a.width===b.width && a.height===b.height, 'drawable changed');
    // Include exactly the physical pixels whose centers lie in the region.
    const x0=Math.ceil(r.x*scale-.5), y0=Math.ceil(r.y*scale-.5);
    const x1=Math.ceil((r.x+r.w)*scale-.5), y1=Math.ceil((r.y+r.h)*scale-.5);
    assert(x0>=0 && y0>=0 && x1<=a.width && y1<=a.height && x1>x0 && y1>y0, 'sample outside viewport');
    let changed=0, maximum=0, total=0;
    for(let y=y0;y<y1;y++) for(let x=x0;x<x1;x++) {
      const i=(y*a.width+x)*a.channels;
      const delta=Math.max(...[0,1,2].map(c=>Math.abs(a.pixels[i+c]-b.pixels[i+c])));
      if(delta>3) changed++;
      maximum=Math.max(maximum,delta); total+=delta;
    }
    return {changed,maximum,mean:total/((x1-x0)*(y1-y0))};
  };
  const records:unknown[]=[];
  for(let cycle=0;cycle<2;cycle++) {
    assert((await clickTestId('story.glasschrome.scrolldown')).ok, 'scroll down failed');
    await mouseMove(20,20);
    await waitFor(async()=>{
      const r=(await query('story.glasschrome.canvas'))[0].rect;
      return Math.abs(r.y-(originalCanvas.y-90))<.1 ? r : null;
    },10000,50);
    const down=await capture(`down-${cycle}`);
    const glass=compare(baseline,down,edge);
    // Canvas below the title-bar edge, inside the stage.
    const canvas=compare(baseline,down,{x:stage.x+10,y:edge.y+edge.h+10,w:stage.w-20,h:stage.y+stage.h-(edge.y+edge.h)-20});
    const isolated=compare(baseline,down,untouched);
    const outside = [
      {x:stage.x-2,y:stage.y,w:1,h:stage.h},
      {x:stage.x+stage.w+1,y:stage.y,w:1,h:stage.h},
      {x:stage.x,y:stage.y-2,w:stage.w,h:1},
      {x:stage.x,y:stage.y+stage.h+1,w:stage.w,h:1},
    ].map(rect=>compare(baseline,down,rect));
    records.push({cycle,glass,canvas,isolated,outside});
    writeFileSync(`${getSessionDir()}/glass-scroll-metrics.json`,JSON.stringify({scale,stage,edge,untouched,records},null,2));
    assert(outside.every(band=>band.maximum<=3), `scroll escaped the clipped stage: ${JSON.stringify(outside)}`);
    assert(canvas.changed>100 && canvas.mean>1, `underlay did not visibly scroll: ${JSON.stringify(canvas)}`);
    assert(glass.changed>100 && glass.mean>1, `glass retained stale backdrop: ${JSON.stringify(glass)}`);
    assert(isolated.maximum<=3, `scroll contaminated another glass surface: ${JSON.stringify(isolated)}`);
    assert((await clickTestId('story.glasschrome.scrollup')).ok, 'scroll up failed');
    await mouseMove(20,20);
    await waitFor(async()=>{
      const r=(await query('story.glasschrome.canvas'))[0].rect;
      return Math.abs(r.y-originalCanvas.y)<.1 ? r : null;
    },10000,50);
    const restored=await capture(`restored-${cycle}`);
    // Includes the rounded parent boundary and a two-pixel logical margin.
    const restoredRegion=compare(baseline,restored,{x:stage.x-2,y:stage.y-2,w:stage.w+4,h:stage.h+4});
    records.push({cycle,restored:restoredRegion});
    assert(restoredRegion.maximum<=3, `round trip left stale pixels: ${JSON.stringify(restoredRegion)}`);
  }
  writeFileSync(`${getSessionDir()}/glass-scroll-metrics.json`,JSON.stringify({scale,stage,edge,untouched,records},null,2));
});
run();
