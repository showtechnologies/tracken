const CACHE='tracken-mobile-v1';
const SHELL=['./','./index.html','./offline-db.js','./offline-app.js','./manifest.webmanifest','./icon.svg'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL))));
// New versions activate after old app windows close, preserving in-flight work.
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  for(const key of await caches.keys()) if(key.startsWith('tracken-mobile-')&&key!==CACHE) await caches.delete(key);
  await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.origin!==self.location.origin) return;
  const paths=SHELL.map(p=>new URL(p,self.registration.scope).pathname);
  if(!paths.includes(url.pathname)) return;
  // Serve one installed version consistently; never cache API responses or tokens.
  event.respondWith(caches.match(event.request,{ignoreSearch:true}).then(cached=>cached||fetch(event.request)));
});
