// NODE_PATH=<dir containing playwright> node render.cjs
const {chromium}=require('playwright');
const fs=require('fs'),path=require('path');
const NAME='beach-k8s-poc-architecture-v4';
(async()=>{
  const out=__dirname;
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
  const src=fs.readFileSync(path.join(out,NAME+'.svg'),'utf8');
  const [,w,h]=src.match(/<svg[^>]* width="(\d+)" height="(\d+)"/).map(Number);
  const page=await browser.newPage({viewport:{width:w,height:h},deviceScaleFactor:2});
  await page.setContent('<!doctype html><meta charset="utf-8"><style>html,body{margin:0}svg{display:block}@page{margin:0}</style>'+src);
  await page.evaluate(()=>document.fonts.ready);
  const checks=JSON.parse(fs.readFileSync(path.join(out,'text-layout.json'),'utf8'));
  const bad=await page.evaluate(c=>[...document.querySelectorAll('text')].map((t,i)=>({text:t.textContent,width:Math.round(t.getComputedTextLength()),limit:c[i].maxWidth})).filter(x=>x.width>x.limit+2),checks);
  console.log('Text overflow:',JSON.stringify(bad));
  await page.screenshot({path:path.join(out,NAME+'.png')});
  await page.pdf({path:path.join(out,NAME+'.pdf'),width:w+'px',height:h+'px',printBackground:true});
  await browser.close();
})();
