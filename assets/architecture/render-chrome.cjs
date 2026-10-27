// Playwright-free variant of render.cjs: drives an installed Chrome/Edge over the DevTools
// protocol using Node 22's built-in WebSocket. Same checks and outputs as render.cjs.
// CHROME_PATH=<chrome.exe> node render-chrome.cjs
const {spawn}=require('child_process');
const fs=require('fs'),os=require('os'),path=require('path');
const NAME='beach-k8s-poc-architecture-v4';
const out=__dirname;
const chrome=process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  const src=fs.readFileSync(path.join(out,NAME+'.svg'),'utf8');
  const [,w,h]=src.match(/<svg[^>]* width="(\d+)" height="(\d+)"/).map(Number);
  const checks=JSON.parse(fs.readFileSync(path.join(out,'text-layout.json'),'utf8'));
  const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'beach-render-'));
  const proc=spawn(chrome,['--headless=new','--disable-gpu','--hide-scrollbars','--no-first-run',
    '--remote-debugging-port=0',`--user-data-dir=${tmp}`,'about:blank'],{stdio:'ignore'});
  const portFile=path.join(tmp,'DevToolsActivePort');
  for(let i=0;i<100&&!fs.existsSync(portFile);i++) await sleep(100);
  const port=fs.readFileSync(portFile,'utf8').split('\n')[0];
  const target=(await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t=>t.type==='page');
  const ws=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise(r=>ws.addEventListener('open',r));
  let id=0;const pending=new Map();
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(pending.has(m.id)){pending.get(m.id)(m);pending.delete(m.id);}});
  const send=(method,params={})=>new Promise((res,rej)=>{const i=++id;pending.set(i,m=>m.error?rej(new Error(method+': '+m.error.message)):res(m.result));ws.send(JSON.stringify({id:i,method,params}));});
  const evaluate=async expr=>(await send('Runtime.evaluate',{expression:expr,awaitPromise:true,returnByValue:true})).result.value;

  await send('Emulation.setDeviceMetricsOverride',{width:w,height:h,deviceScaleFactor:2,mobile:false});
  const frameId=(await send('Page.getFrameTree')).frameTree.frame.id;
  const html='<!doctype html><meta charset="utf-8"><style>html,body{margin:0}svg{display:block}@page{margin:0}</style>'+src;
  await send('Page.setDocumentContent',{frameId,html});
  await evaluate('document.fonts.ready.then(()=>true)');
  const bad=await evaluate(`(c=>[...document.querySelectorAll('text')].map((t,i)=>({text:t.textContent,width:Math.round(t.getComputedTextLength()),limit:c[i].maxWidth})).filter(x=>x.width>x.limit+2))(${JSON.stringify(checks)})`);
  console.log('Text overflow:',JSON.stringify(bad));
  const shot=await send('Page.captureScreenshot',{format:'png',clip:{x:0,y:0,width:w,height:h,scale:1}});
  fs.writeFileSync(path.join(out,NAME+'.png'),Buffer.from(shot.data,'base64'));
  const pdf=await send('Page.printToPDF',{paperWidth:w/96,paperHeight:h/96,marginTop:0,marginBottom:0,marginLeft:0,marginRight:0,
    printBackground:true,displayHeaderFooter:false,pageRanges:'1'});
  fs.writeFileSync(path.join(out,NAME+'.pdf'),Buffer.from(pdf.data,'base64'));
  ws.close();proc.kill();
  await sleep(500);
  try{fs.rmSync(tmp,{recursive:true,force:true,maxRetries:5,retryDelay:300});}catch{}
})().catch(e=>{console.error(e);process.exit(1);});
