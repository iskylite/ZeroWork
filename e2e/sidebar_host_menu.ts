/** Open the saved-host menu through its existing right-click entry. */
import assert from 'node:assert/strict';
import * as h from '../zig-out/share/zenit/harness/client.ts';
export async function openSidebarHostMenu(row?:h.QueryNode):Promise<void>{
 const target=row??await h.waitFor(async()=>(await h.query('sidebar.host')).find(n=>n.visible!==false&&n.rect.w>0&&n.rect.h>0)??null);
 const point={x:target.rect.x+10,y:target.rect.y+target.rect.h/2,button:'right'};
 assert((await h.request('POST','/mouse_down',point)).ok);
 assert((await h.request('POST','/mouse_up',point)).ok);
 await h.waitFor(async()=>(await h.query('context.menu')).find(n=>n.visible!==false&&n.rect.w>0&&n.rect.h>0)??null);
}
