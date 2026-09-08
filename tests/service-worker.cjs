const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
const handlers={},stored=new Map();let claimed=false,deleted=[];
const context={URL,console,self:{location:{origin:'https://test.invalid'},registration:{scope:'https://test.invalid/tracken/'},clients:{claim:async()=>{claimed=true}},addEventListener:(name,fn)=>handlers[name]=fn},caches:{open:async()=>({addAll:async paths=>{for(const path of paths)stored.set(new URL(path,'https://test.invalid/tracken/').href,{cached:true})}}),keys:async()=>['tracken-mobile-old','unrelated'],delete:async key=>deleted.push(key),match:async req=>stored.get(req.url.split('?')[0])},fetch:async()=>{throw new Error('airplane mode')}};
vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../sw.js'),'utf8'),context);
(async()=>{
 let p;handlers.install({waitUntil:v=>p=v});await p;handlers.activate({waitUntil:v=>p=v});await p;
 assert(claimed);assert.deepEqual(deleted,['tracken-mobile-old']);
 for(const path of ['/tracken/','/tracken/index.html','/tracken/offline-app.js','/tracken/offline-db.js']){
  let response;handlers.fetch({request:{url:'https://test.invalid'+path,method:'GET'},respondWith:v=>response=v});assert((await response).cached,'offline shell not cached');
 }
 let intercepted=false;handlers.fetch({request:{url:'https://project.supabase.co/rest/v1/rpc/tracken_sync',method:'POST'},respondWith:()=>intercepted=true});assert(!intercepted,'API was intercepted');
 console.log('PASS: offline shell, scope, cache version cleanup, no API cache');
})().catch(e=>{console.error(e);process.exitCode=1});
