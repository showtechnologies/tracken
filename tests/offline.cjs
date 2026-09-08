const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {JSDOM}=require(process.env.JSDOM_PATH||'jsdom');
const {IDBFactory}=require(process.env.FAKE_IDB_PATH||'fake-indexeddb');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const idb=new IDBFactory(),user={id:'worker',name:'Worker',role:'user',manager:false};
const article={id:'tool',name:'Tool',active:true,state:'home',location_id:'site',current_holder_user_id:null,last_movement_at:null};
let server={users:[{...user,active:true}],articles:[article],locations:[{id:'site',name:'Site',active:true}],movements:[]};
let received=new Map(),lostResponse=false,forceConflict=false,requests=0;
function boot(){
 const dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://test.invalid/tracken/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window;w.indexedDB=idb;w.structuredClone=structuredClone;w.scrollTo=()=>{};w.confirm=()=>true;
 w.supabase={createClient:()=>({rpc:async(name,args)=>{
  requests++;
  if(name==='tracken_sync'){
   if(args.p_action!=='submit')return {data:{events:[]}};
   const op=args.p_body.operation;
   if(!received.has(op.operation_id))received.set(op.operation_id,{status:forceConflict?'review':'accepted',operation_id:op.operation_id});
   if(lostResponse){lostResponse=false;return {error:{message:'Network lost after commit'}};}
   return {data:received.get(op.operation_id)};
  }
  if(args.p_action==='data')return {data:{...structuredClone(server),user}};
  return {data:{ok:true}};
 }})};
 w.eval(fs.readFileSync(path.join(root,'offline-db.js'),'utf8')+'\n'+html.match(/<script>([\s\S]*?)<\/script>/)[1]+'\n'+fs.readFileSync(path.join(root,'offline-app.js'),'utf8')+'\nwindow.inspect=code=>eval(code);');
 return {dom,w};
}
async function login(w){await w.acceptSession({token:'a'.repeat(64),user,expires_at:new Date(Date.now()+1200000).toISOString()});}
async function save(w,type='prelievo'){
 return w.inspect(`saveMovementAndArticle(db.articles[0],{article_id:'tool',article_name:'Tool',movement_type:'${type}',recorded_by_user_id:'worker',image_data:'data:image/jpeg;base64,AAAA'}, {state:'${type==='prelievo'?'in_carico':'home'}',current_holder_user_id:${type==='prelievo'?"'worker'":'null'},last_movement_at:new Date().toISOString()})`);
}
(async()=>{
 let {dom,w}=boot();await w.initApp();assert.equal(requests,0,'Boot contacted server before auth');await login(w);
 Object.defineProperty(w.navigator,'onLine',{value:false,configurable:true});
 assert.equal(await save(w),true);assert.equal((await w.TrackenStore.read('events')).length,1);
 assert.equal(w.inspect('db.articles[0].state'),'in_carico');
 dom.window.close();
 ({dom,w}=boot());Object.defineProperty(w.navigator,'onLine',{value:false,configurable:true});await w.initApp();w.resumeOffline();
 assert.equal(w.inspect('db.articles[0].state'),'in_carico','Restart lost optimistic state');
 assert.equal(w.inspect('pending()[0].image_data'),'data:image/jpeg;base64,AAAA','Photo lost');
 assert.equal(await save(w,'restituzione'),true);
 assert.equal(w.inspect('pending()[1].previous_operation'),w.inspect('pending()[0].operation_id'),'Missing causal link');
 w.inspect("offlineProfile.until=Date.now()+10000;secureSession=null");assert.equal(await save(w),true,'Expired server session blocks offline');
 Object.defineProperty(w.navigator,'onLine',{value:true,configurable:true});lostResponse=true;await login(w);
 assert.equal(w.inspect('pending().length'),3,'Lost acknowledgement removed journal');
 w.inspect('syncRetryAt=0');await w.processOfflineQueue(false);assert.equal(received.size,3);assert.equal(w.inspect('pending().length'),0);
 forceConflict=true;await save(w);await w.processOfflineQueue(false);assert.equal(w.inspect("mine().filter(e=>e.status==='review').length"),1,'Conflict lost');
 const before=w.inspect('journal.length'), beforeState=w.inspect('db.articles[0].state');w.TrackenStore.append=async()=>{throw new Error('QuotaExceeded')};
 assert.equal(await save(w),false);assert.equal(w.inspect('journal.length'),before);assert.equal(w.inspect('db.articles[0].state'),beforeState,'False local success');
 assert.equal(JSON.stringify(await w.TrackenStore.read('meta','profile')).includes('token'),false,'Token persisted');
 await w.logoutAll();assert.equal(w.inspect('currentUserId'),null);assert.equal(await w.TrackenStore.read('meta','profile'),null,'Logout leaves offline identity');
 assert.equal((await w.TrackenStore.read('events')).length,4,'Logout lost journal');
 dom.window.close();console.log('PASS: persistence, offline reopen, photo, causal order, expired session, lost response retry, conflicts, quota failure, no stored token, logout retention');
})().catch(e=>{console.error(e);process.exit(1)});
