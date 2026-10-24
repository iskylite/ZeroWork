// Independent angular Snell-law oracle for the known circle/flat ramp fixture.
const encode=(x:number)=>Math.round(255*(x<=.0031308?12.92*x:1.055*Math.max(x,0)**(1/2.4)-.055));
const decode=(x:number)=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4;
const clamp=(x:number,lo=0,hi=1)=>Math.max(lo,Math.min(hi,x));
const mix=(a:number,b:number,t:number)=>a+(b-a)*t;
const ramp=(x:number)=>{const q=clamp(x,0,110)/11,i=Math.floor(q);return i%2?1-(q-i):q-i;};
export function snellDisplacement(slope:number,height:number,thickness:number,bezel:number,ior:number) {
  const incident=Math.atan(slope*thickness/bezel);
  const refracted=Math.asin(Math.sin(incident)/ior);
  return height*thickness*(Math.tan(incident-refracted));
}
export function circleRay(x:number,y:number,s:number,warp=2,refraction=1){
  const half=40*s,p=[(x-40)*s,(y-40)*s],inset=half-Math.max(Math.abs(p[0]),Math.abs(p[1]));
  const topWidth=clamp(half*.18,2*s,half),bottomWidth=clamp(half*.12,2*s,half);
  const topT=clamp(inset/topWidth),bottomT=clamp(inset/bottomWidth);
  const profile=(t:number)=>{const q=1-clamp(t),h=Math.sqrt(Math.max(1-q*q,0));return [h,q/Math.max(h,1e-5)*1.08];};
  const edge=profile(topT),topEdge=(1-topT)**2.3,bottomEdge=(1-bottomT)**2.1;
  // The bottom surface is flat: it adds neither height nor thickness.
  const thickness=12*s+Math.min(topWidth*(.52+.48*edge[0]),20*s)*(.38+topEdge*.62);
  const bodyT=1-(1-clamp(inset/half))**mix(1.15,3.75,(1-.35)/1.25),body=profile(bodyT);
  const height=mix(edge[0],body[0],bodyT),slope=mix(edge[1],body[1],bodyT);
  const cover=clamp((.58-.1)/1.4),hardness=clamp((2.2-.4)/5.6);
  const envelope=(1-Math.exp(-bodyT*(.8+cover*4.2)))**mix(.78,2.4,hardness);
  const bezel=mix(topWidth,half,bodyT);
  const boost=mix(1,.15+.85*envelope,bodyT)*warp*refraction;
  const sdfNormal=[p[0]<0?-1:1,0],len=Math.hypot(...p),radial=p.map(v=>v/len);
  const t=clamp((bodyT-.10)/(.92-.10)),directionT=t*t*(3-2*t);
  const direction=[mix(sdfNormal[0],radial[0],directionT),mix(0,radial[1],directionT)],dl=Math.hypot(...direction);
  const colors=[1.447,1.450,1.454].map(ior=>{
    const shift=snellDisplacement(slope,height,thickness,bezel,ior)*boost;
    // The fixture gradient interpolates encoded CSS colors. Decode that
    // source before the material's linear-light saturation, then encode once.
    return decode(ramp(15+x+direction[0]/dl*shift/s));
  });
  const luma=colors[0]*.2126+colors[1]*.7152+colors[2]*.0722,sat=1.01+(topEdge+bottomEdge*.45)*.06;
  return colors.map(c=>encode(clamp(mix(luma,c,sat))));
}

