/** Theme state publisher. Native policy: src/ui/theme_states.zig.
 * Update after editing base palettes: node scripts/sync_theme_states.mjs
 * CI: node scripts/sync_theme_states.mjs --check
 */
import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
const root=fileURLToPath(new URL('../',import.meta.url));
const native=readFileSync(resolve(root,'src/ui/theme_states.zig'),'utf8');
export const policy=Object.fromEntries(['text_min','state_min','focus_min','hover_amount','pressed_amount','graphic_min'].map(name=>[name,Number(native.match(new RegExp(`pub const ${name}: f\\d+ = ([\\d.]+);`))[1])]));
export const rgb=hex=>[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));
const hex=color=>'#'+color.map(v=>v.toString(16).padStart(2,'0')).join('');
export const luminance=color=>color.reduce((sum,v,i)=>{const x=v/255;return sum+(x<=.04045?x/12.92:((x+.055)/1.055)**2.4)*[.2126,.7152,.0722][i]},0);
export const contrast=(a,b)=>{const x=luminance(a),y=luminance(b);return(Math.max(x,y)+.05)/(Math.min(x,y)+.05)};
// Match native Color.lerp's float32 arithmetic and final integer truncation.
const mix=(a,b,t)=>a.map((v,i)=>Math.trunc(Math.fround(Math.fround(v)+Math.fround(Math.fround(b[i]-v)*Math.fround(t)))));
const black=[0,0,0],white=[255,255,255];
const foreground=bg=>contrast(bg,white)>=policy.text_min?white:black;
const separate=(seed,references,inks,minimum)=>{
 const passes=color=>references.every(ref=>contrast(color,ref)>=minimum)&&inks.every(ink=>contrast(color,ink)>=policy.text_min);
 if(passes(seed))return seed;
 for(let step=1;step<=255;step++)for(const pole of [black,white]){const candidate=mix(seed,pole,Math.fround(step/255));if(passes(candidate))return candidate;}
 return seed;
};
export function deriveStateColors(p){
 const c=Object.fromEntries(Object.entries(p).filter(([,v])=>v.startsWith('#')).map(([k,v])=>[k.slice(2),rgb(v)]));
 const overlay=c['overlay-base'],well=c['well-base'],blend=mix(overlay,well,.3),control=contrast(overlay,blend)>=1.1?blend:well;
 const action=mix(overlay,c['fg-2'],.12),disabled=separate(action,[control],[c['fg-3']],policy.state_min),inks=[c['fg-1'],c['fg-2']],selectedInks=[...inks,c['fg-3'],c['accent-ink']];
 const hover=separate(c['hover-base'],[overlay,action],inks,policy.state_min),pressed=separate(hover,[hover],inks,policy.state_min);
 const dark=c['bg-app'].reduce((s,v,i)=>s+v*[299,587,114][i],0)<128000,seed=mix(overlay,c['accent-base'],dark?.16:.10);
 const selected=separate(seed,[overlay],selectedInks,policy.state_min),focus=separate(seed,[control],inks,policy.focus_min),selected_hover=separate(selected,[selected],selectedInks,policy.state_min),drop_target=separate(mix(overlay,c['accent-base'],.28),[selected],inks,policy.focus_min);
 const rangeStep=(seed,track,previous)=>{for(let step=1;step<=255;step++)for(const pole of [black,white]){const candidate=mix(seed,pole,Math.fround(step/255));if(contrast(candidate,track)>=policy.graphic_min&&contrast(candidate,previous)>=policy.state_min)return candidate;}return seed;};
 const primary=c['action-accent'],primary_to=c['action-accent-2'],primary_ink=foreground(primary),pole=primary_ink===white?black:white;
 const danger=c['action-danger'],danger_ink=foreground(danger),dangerPole=danger_ink===white?black:white;
 const tint=role=>{const seed=mix(overlay,c[role==='danger'?'danger-base':role],.09);return contrast(seed,c[role+'-ink'])>=policy.text_min?seed:separate(seed,[],[c[role+'-ink']],1)};
 const tag_danger=tint('danger');
 const backgrounds=[hover,pressed,focus,selected,selected_hover,drop_target];
 let muted_ink=c['fg-1'];for(let step=0;step<=255;step++){const candidate=mix(c['fg-3'],c['fg-1'],Math.fround(step/255));if(backgrounds.every(bg=>contrast(candidate,bg)>=policy.text_min)){muted_ink=candidate;break;}}
 const choice_off=separate(mix(overlay,c['fg-2'],.4),[overlay,control,primary],[],1.5),choice_disabled_on=separate(mix(primary,overlay,.55),[disabled],[],1.5);
 const range_fill=separate(primary,[action],[],policy.graphic_min),range_hover=rangeStep(range_fill,action,range_fill),range_drag=rangeStep(range_hover,action,range_hover),range_disabled=separate(c['fg-3'],[action],[],policy.graphic_min);
 const feedback_info=(()=>{const seed=mix(overlay,c['accent-base'],.09);return contrast(seed,c['accent-ink'])>=policy.text_min?seed:separate(seed,[],[c['accent-ink']],1)})();
 const search_match=separate(tint('warn'),[c['bg-term-base']],[c['fg-1']],1.5),search_current=separate(primary,[c['bg-term-base'],search_match],[],policy.graphic_min);
 return {control,action,disabled,hover,pressed,focus,selected,selected_hover,drop_target,primary,primary_to,primary_hover:mix(primary,pole,policy.hover_amount),primary_hover_to:mix(primary_to,pole,policy.hover_amount),primary_pressed:mix(primary,pole,policy.pressed_amount),primary_pressed_to:mix(primary_to,pole,policy.pressed_amount),primary_ink,danger,danger_hover:mix(danger,dangerPole,policy.hover_amount),danger_pressed:mix(danger,dangerPole,policy.pressed_amount),danger_ink,tag:control,tag_ok:tint('ok'),tag_warn:tint('warn'),tag_danger,error_focus:separate(tag_danger,[tag_danger],[c['danger-ink']],policy.focus_min),muted_ink,choice_off,choice_on:primary,choice_ink:primary_ink,choice_disabled_off:disabled,choice_disabled_on,choice_disabled_ink:foreground(choice_disabled_on),choice_thumb_off:separate(overlay,[choice_off],[],policy.graphic_min),choice_disabled_thumb_off:foreground(disabled),range_track:action,range_fill,range_hover,range_drag,range_thumb:foreground(range_fill),range_disabled,range_disabled_thumb:foreground(range_disabled),progress_ok:separate(c.ok,[action],[],policy.graphic_min),progress_warn:separate(c.warn,[action],[],policy.graphic_min),progress_danger:separate(c['danger-base'],[action],[],policy.graphic_min),feedback_info,feedback_ok:tint('ok'),feedback_warn:tint('warn'),feedback_danger:tag_danger,search_match,search_match_ink:c['fg-1'],search_current,search_current_ink:foreground(search_current)};
}
const stateMaterials=Object.fromEntries([...native.match(/pub const material_roles = \.\{([\s\S]*?)\};/)[1].matchAll(/\.\{ "(\w+)", "(\w+)" \}/g)].map(m=>[m[1],m[2].replaceAll('_','-')]));
export function publish(check=false){
 const source=JSON.parse(readFileSync(resolve(root,'docs/UI_V3/theme-presets.json'),'utf8'));
 const themes=Object.fromEntries(Object.entries(source.themes).map(([id,palette])=>[id,Object.fromEntries(Object.entries(deriveStateColors(palette)).map(([role,color])=>[role,hex(color)]))]));
 const fields=[...native.slice(native.indexOf('pub const Palette = struct'),native.indexOf('pub fn derive')).matchAll(/^    (\w+): ui.Color,/gm)].map(m=>m[1]);
 for(const [id,colors]of Object.entries(themes))if(JSON.stringify(Object.keys(colors))!==JSON.stringify(fields))throw Error('State role completeness: '+id);
 const surfaces=Object.fromEntries(Object.entries(source.themes).map(([id,p])=>[id,Object.fromEntries(['bg-app','surface-1-base','surface-2-base','well-base','overlay-base'].map(role=>[role,p['--'+role]]))]));
 const terminalSelection=Object.fromEntries(Object.entries(source.terminalPalettes).map(([id,p])=>[id,{foreground:p.foreground,selection:p.selection}]));
 const json=JSON.stringify({version:1,policy,themes,surfaces,stateMaterials,materials:source.materialProjection,terminalSelection},null,2)+'\n';
 const css='/* Generated by scripts/sync_theme_states.mjs; change theme base colors/policy, then regenerate. */\n'+Object.entries(themes).map(([id,colors])=>(id==='dark'?':root,':'')+'body[data-theme="'+id+'"]{'+Object.entries(colors).map(([role,color])=>{const name='--state-'+role.replaceAll('_','-'),material=stateMaterials[role];return material?name+'-base:'+color+';'+name+':color-mix(in srgb,rgb(from var('+name+'-base) r g b / 1) var(--'+material+'-alpha,100%),transparent);':name+':'+color+';'}).join('')+'}').join('\n')+'\n';
 for(const [path,content]of [['docs/UI_V3/theme-states.json',json],['docs/UI_V3/theme-states.css',css]]){
  if(check){if(readFileSync(resolve(root,path),'utf8')!==content)throw Error(path+' is stale; run node scripts/sync_theme_states.mjs');}
  else writeFileSync(resolve(root,path),content);
 }
 const digest=text=>createHash('sha256').update(text).digest('hex').slice(0,12);
 const tokenPath=resolve(root,'docs/UI_V3/theme-tokens.css'),tokens=readFileSync(tokenPath,'utf8'),updatedTokens=tokens.replace(/@import url\("theme-states.css(?:\?v=[a-f\d]+)?"\);/,'@import url("theme-states.css?v='+digest(css)+'");');
 if(check&&tokens!==updatedTokens)throw Error('Theme state CSS import is stale');
 if(!check&&tokens!==updatedTokens)writeFileSync(tokenPath,updatedTokens);
 const versions={'theme-tokens.css':digest(updatedTokens),'primitives.css':digest(readFileSync(resolve(root,'docs/UI_V3/components/primitives.css'),'utf8'))};
 for(const file of readdirSync(resolve(root,'docs/UI_V3'),{recursive:true}).filter(name=>/\.(html|js)$/.test(name))){
  const path=resolve(root,'docs/UI_V3',file),before=readFileSync(path,'utf8');let after=before;
  for(const [asset,version]of Object.entries(versions))after=after.replaceAll(new RegExp(asset.replace('.',String.raw`\.`)+String.raw`\?v=[a-f\d]+`,'g'),asset+'?v='+version);
  if(before!==after){if(check)throw Error(file+' references stale theme CSS');writeFileSync(path,after);}
 }
 console.log(`${check?'PASS':'Published'}: ${Object.keys(themes).length} themes × ${fields.length} component state roles; one native policy`);
 return {themes,source};
}
if(process.argv[1]&&pathToFileURL(resolve(process.argv[1])).href===import.meta.url)publish(process.argv.includes('--check'));
