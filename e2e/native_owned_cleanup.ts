/** Remove only private ZLE wrappers belonging to this runner's exited App.
 * Do not serialize wrapper contents: they contain the per-session nonce. */
import assert from 'node:assert/strict';
import {lstat, readdir, readFile, rm} from 'node:fs/promises';
import {join} from 'node:path';

export async function cleanupOwnedBridgeDirectories(appPid:number):Promise<string[]> {
 let alive=false;try{process.kill(appPid,0);alive=true}catch(error:any){if(error.code!=='ESRCH')throw error}
 assert(!alive,'Only an exited owned App may have its private bridge removed');
 const uid=process.getuid!(),removed:string[]=[];
 for(const name of await readdir('/tmp')){
  if(!name.startsWith(`zw-edit-${uid}-`))continue;
  const path=join('/tmp',name);
  try{
   const info=await lstat(path);if(!info.isDirectory()||info.isSymbolicLink()||info.uid!==uid||(info.mode&0o777)!==0o700)continue;
   const wrapper=await readFile(join(path,'.zshenv'),'utf8');
   if(!new RegExp(`(?:^|\\s)_zw_parent=${appPid}(?:\\s|$)`).test(wrapper))continue;
   await rm(path,{recursive:true});removed.push(path);
  }catch(error:any){if(error.code!=='ENOENT')throw error}
 }
 return removed;
}
