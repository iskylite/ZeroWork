/** Non-GUI contract test: no application/window is created. */
import {mkdtempSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
const root=mkdtempSync(join(tmpdir(),'zenit-caret-unit-'));
try{
 const binary=join(root,'caret-test');
 for(const command of [['nice','-n','19','clang','-fobjc-arc','-Werror','-Wno-deprecated-declarations',resolve(import.meta.dir,'../native/macos/tests/caret_patch_test.m'),'-framework','AppKit','-framework','QuartzCore','-framework','Metal','-framework','IOSurface','-framework','ImageIO','-o',binary],['nice','-n','19',binary]]){
  const r=spawnSync(command[0],command.slice(1),{stdio:'inherit'});if(r.status!==0)throw Error(`caret native unit failed: ${r.status}`);
 }
}finally{rmSync(root,{recursive:true,force:true});}
