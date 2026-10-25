'use strict';
/* Figma 495/496 and 359:1538484: UTF-8 text ≤64 KiB; at most four
   images, each ≤10 MB. A rejected source never enters the draft. */
window.V3AILocalAttachments=(()=>{
 const limits=Object.freeze({textBytes:64*1024,imageBytes:10_000_000,imageCount:4});
 const textExtensions=Object.freeze(['txt','md','log','json','yaml','yml','toml','csv','zig','js','ts','css','html','sh']);
 const imageTypes=Object.freeze({png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',gif:'image/gif',webp:'image/webp'});
 const imageMimes=new Set(Object.values(imageTypes));
 const extension=file=>String(file?.name||'').split('.').length>1?String(file.name).split('.').pop().toLowerCase():'';
 const mime=file=>String(file?.mime||(/^\w+\//.test(file?.type||'')?file.type:'')||'').toLowerCase();
 const kindOf=file=>file?.kind==='image'||file?.type==='image'||mime(file).startsWith('image/')||Object.hasOwn(imageTypes,extension(file))?'image':'text';
 const failure=(code,message)=>Object.freeze({code,message});
 const duplicateKey=file=>[String(file?.name||''),Number(file?.size??file?.bytes??0),Number(file?.lastModified||0)].join('\u0000');
 function validate({files=[],existing=[],mode='mixed'}={}){
  const prior=Array.from(existing||[]).map(item=>item?.file||item),seen=new Set(prior.map(duplicateKey));
  let imageCount=prior.filter(file=>kindOf(file)==='image').length;
  return Array.from(files||[]).map(file=>{
   const kind=kindOf(file),ext=extension(file),type=mime(file),size=Number(file?.size),key=duplicateKey(file);
   let error=null;
   if(!file||!file.name||!Number.isFinite(size)||size<0)error=failure('invalid_file','无法读取此文件。');
   else if(mode!=='mixed'&&mode!==kind)error=failure('unsupported_format',mode==='image'?'请选择 PNG、JPEG、GIF 或 WebP 图片。':'请选择最大 64 KiB 的 UTF-8 文本。');
   else if(seen.has(key))error=failure('duplicate','此文件已在草稿中。');
   else if(kind==='image'){
    if(!Object.hasOwn(imageTypes,ext)||type&&!imageMimes.has(type)||type&&type!==imageTypes[ext])error=failure('unsupported_image','文件格式不支持，请选择 PNG、JPEG、GIF 或 WebP 图片。');
    else if(size===0)error=failure('invalid_image','文件格式或内容无效；草稿及其他附件保留。');
    else if(size>limits.imageBytes)error=failure('image_too_large','单张图片最多 10 MB；此文件未加入草稿。');
    else if(imageCount>=limits.imageCount)error=failure('image_count','最多 4 张图片；此文件未加入草稿。');
   }else{
    if(!textExtensions.includes(ext)||type.startsWith('image/')||/zip|octet-stream|pdf|audio|video/.test(type))error=failure('unsupported_text','格式不支持。请选择最大 64 KiB 的 UTF-8 文本。');
    else if(size>limits.textBytes)error=failure('text_too_large','超过 64 KiB。文件未加入草稿。');
   }
   if(!error){seen.add(key);if(kind==='image')imageCount++;}
   return {file,accepted:!error,error,kind};
  });
 }
 function sniff(bytes){
  if(bytes.length>=8&&[137,80,78,71,13,10,26,10].every((n,i)=>bytes[i]===n))return 'image/png';
  if(bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255)return 'image/jpeg';
  const ascii=(a,b)=>String.fromCharCode(...bytes.slice(a,b));
  if(bytes.length>=6&&['GIF87a','GIF89a'].includes(ascii(0,6)))return 'image/gif';
  if(bytes.length>=12&&ascii(0,4)==='RIFF'&&ascii(8,12)==='WEBP')return 'image/webp';
  return null;
 }
 async function readFile(input,{decodeImage}={}){
  const result=input?.file&&typeof input.accepted==='boolean'?input:validate({files:[input]})[0];
  if(!result?.accepted)return result;
  const {file,kind}=result;
  try{
   const bytes=new Uint8Array(await file.arrayBuffer());
   if(bytes.byteLength!==file.size)throw failure('read_failed','文件读取不完整；此文件未加入草稿。');
   const base={name:file.name,source:'本地文件',size:file.size,lastModified:file.lastModified||0};
   if(kind==='text'){
    let content;try{content=new TextDecoder('utf-8',{fatal:true}).decode(bytes);}catch{throw failure('invalid_utf8','内容不是有效的 UTF-8 文本；此文件未加入草稿。');}
    if(content.includes('\u0000'))throw failure('invalid_text','内容不是可预览的文本；此文件未加入草稿。');
    return {...result,snapshot:{...base,type:'text',mime:mime(file)||'text/plain',text:content,url:null}};
   }
   const detected=sniff(bytes);if(!detected||detected!==imageTypes[extension(file)])throw failure('invalid_image','文件格式或内容无效；草稿及其他附件保留。');
   const decoder=decodeImage||(typeof createImageBitmap==='function'?createImageBitmap:null);
   if(!decoder)throw failure('image_decode_unavailable','当前环境无法解码图片；此文件未加入草稿。');
   let image;try{image=await decoder(file);}catch{throw failure('invalid_image','文件格式或内容无效；草稿及其他附件保留。');}
   const width=image?.width,height=image?.height;image?.close?.();
   if(!(width>0&&height>0))throw failure('invalid_image','文件格式或内容无效；草稿及其他附件保留。');
   return {...result,snapshot:{...base,type:'image',mime:detected,text:'图片附件 · '+file.name,url:URL.createObjectURL(file),width,height}};
  }catch(error){return {...result,accepted:false,error:failure(error?.code||'read_failed',error?.code?error.message:'无法读取文件；草稿及其他附件保留。')};}
 }
 return Object.freeze({limits,textExtensions,imageTypes,validate,readFile});
})();
