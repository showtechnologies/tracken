/* Mobile offline workflow. Local identity permits drafts only; server reauth is mandatory. */
let journal=[], offlineProfile=null, serverSnapshot=null, localReady=false, offlineSaving=false, syncRetryAt=0, syncFailures=0;
const clone=value=>JSON.parse(JSON.stringify(value));
const baseRender=render, baseLoginView=renderHome;
const LOCAL_WINDOW=7*24*60*60*1000;
const localAllowed=()=>localReady&&offlineProfile&&offlineProfile.user.id===currentUserId&&Date.now()<offlineProfile.until;
const mine=()=>journal.filter(e=>e.recorded_by_user_id===currentUserId);
const pending=()=>mine().filter(e=>e.status==='pending').sort((a,b)=>a.device_sequence-b.device_sequence);
getOfflineQueue=()=>mine().filter(e=>e.status==='pending'||e.status==='legacy');
queueCount=()=>getOfflineQueue().length;
function hydrate(){
 if(!serverSnapshot) return;
 db=clone(serverSnapshot);
 for(const op of pending()){
  const article=db.articles.find(a=>a.id===op.article_id);
  if(article&&op.article_patch) Object.assign(article,op.article_patch);
  db.movements.unshift({...op,id:op.operation_id,created_at:op.device_occurred_at,_queued:true});
 }
}
async function saveProfile(){
 await TrackenStore.write('meta','profile',offlineProfile);
}
api=async function(action,body={}){
 const {data,error}=await sb.rpc('tracken_api',{p_action:action,p_token:secureSession?.token||null,p_body:body});
 if(error) throw Object.assign(new Error(error.message),{network:true});
 if(data?.error){
  if(data.auth_required){secureSession=null;adminLogged=false;}
  throw Object.assign(new Error(data.error),{business:true,auth_required:data.auth_required});
 }
 return data;
};
ensureSession=function(){
 if(secureSession&&!sessionValid()){secureSession=null;adminLogged=false;}
 if(currentUserId&&!sessionValid()&&!localAllowed()){
  currentUserId=null;adminLogged=false;db={users:[],articles:[],locations:[],movements:[]};
 }
};
acceptSession=async function(result){
 secureSession=result; currentUserId=result.user.id; adminLogged=!!result.user.manager; currentView=adminLogged?'admin_dashboard':'home';
 currentSessionId=uid();touchSession();
 offlineProfile={user:result.user,until:Date.now()+LOCAL_WINDOW,last_sync:new Date().toISOString()};
 serverSnapshot=null;
 await fetchAllData();
 subscribeRealtime();startOfflineRetryLoop();render();
 await processOfflineQueue(false);
 if(navigator.storage?.persist) navigator.storage.persist().catch(()=>{});
};
fetchAllData=async function(){
 if(!sessionValid()) return false;
 const owner=currentUserId;
 try{
  const data=await api('data');
  if(owner!==currentUserId) return false;
  serverSnapshot={users:data.users,locations:data.locations,articles:data.articles,movements:data.movements};
  if(!data.user.manager) adminLogged=false;
  if(localReady){
   await TrackenStore.write('meta','snapshot:'+owner,serverSnapshot);
   offlineProfile={user:data.user,until:Date.now()+LOCAL_WINDOW,last_sync:new Date().toISOString()};await saveProfile();
  }
  hydrate();syncState='idle';return true;
 }catch(e){showAlert('error',e.message);return false;}
};
logoutAll=async function(notifyServer=true){
 const token=secureSession?.token; secureSession=null;currentUserId=null;adminLogged=false;currentLocationId=null;
 currentView='home';selectedArticleIds=[];serverSnapshot=null;offlineProfile=null;
 db={users:[],locations:[],articles:[],movements:[]};stopOfflineRetryLoop();
 if(localReady) await TrackenStore.write('meta','profile',null);
 render();
 if(notifyServer&&token) await sb.rpc('tracken_api',{p_action:'logout',p_token:token,p_body:{}});
};
function resumeOffline(){
 if(!localReady||!offlineProfile||Date.now()>=offlineProfile.until||!serverSnapshot) return showAlert('error','Accedi online per preparare questo dispositivo.');
 currentUserId=offlineProfile.user.id;adminLogged=false;currentView='home';currentSessionId=uid();hydrate();render();startOfflineRetryLoop();
}
function loginForSync(){
 secureSession=null;currentUserId=null;adminLogged=false;db={users:[],locations:[],articles:[],movements:[]};render();
}
renderHome=function(){
 return baseLoginView()+`<div class="panel" style="margin-top:12px"><h3>Uso senza rete</h3><p>Accedi online una prima volta. Questo dispositivo conserva inventario, foto e movimenti: usa il blocco schermo del telefono.</p>${offlineProfile&&serverSnapshot&&Date.now()<offlineProfile.until?`<button class="primary" onclick="resumeOffline()">Continua sul dispositivo come ${esc(offlineProfile.user.name)}</button><p class="small">Registrazione locale disponibile fino al ${formatDate(new Date(offlineProfile.until).toISOString())}. Per sincronizzare serve l’accesso online.</p>`:'<p>Dispositivo da preparare con un accesso online.</p>'}<p id="offlineAvailability"></p><p class="small">Per riaprire l’app a bordo: aggiungila alla schermata Home dal menu del browser. Non cancellare i dati del sito prima della sincronizzazione.</p></div>`;
};
renderSyncBadge=function(){
 const n=pending().length, review=mine().filter(e=>e.status==='review'||e.status==='legacy').length;
 const label=queueProcessing?'Invio in corso…':n?`${n} da inviare`:review?`${review} da verificare`:!navigator.onLine?'Senza rete · salvato sul telefono':'Dati aggiornati all’ultima sincronizzazione';
 return `<button onclick="openSyncCenter()">${label}</button>${currentUserId&&!sessionValid()?'<button onclick="loginForSync()">Accedi per sincronizzare</button>':''}`;
};
render=function(){baseRender();const el=document.getElementById('offlineAvailability');if(el)el.textContent=localReady?'Archivio locale pronto.':'Archivio locale non disponibile: non registrare offline.';};
async function saveMovementLocal(article,movement,articlePatch){
 if(!localAllowed()) {showAlert('error','Prepara il dispositivo con un accesso online prima di registrare offline.');return false;}
 if(offlineSaving) return false;
 offlineSaving=true;
 try{
  const previous=pending().filter(e=>e.article_id===article.id).at(-1);
  const op={...movement,kind:'movement',operation_id:uid(),expected:expectedArticle(article),previous_operation:previous?.operation_id||null,
   article_id:article.id,recorded_by_user_id:currentUserId,device_occurred_at:nowIso(),device_timezone_offset:new Date().getTimezoneOffset(),article_patch:clone(articlePatch)};
  const saved=await TrackenStore.append(op); // No success or optimistic state before commit.
  journal.push(saved);hydrate();renderSyncBadgeOnly();startOfflineRetryLoop();
  syncChannel?.postMessage('changed');
  return true;
 }catch(e){showAlert('error','Movimento NON salvato: spazio esaurito o archivio locale non disponibile. Libera spazio e riprova.');return false;}
 finally{offlineSaving=false;}
}
saveMovementAndArticle=saveMovementLocal;
startOfflineRetryLoop=function(){if(offlineRetryTimer) return;offlineRetryTimer=setInterval(()=>processOfflineQueue(false),5000);};
subscribeRealtime=function(){
 if(pollingTimer)return;
 pollingTimer=setInterval(async()=>{if(sessionValid()&&navigator.onLine&&!queueProcessing){await fetchAllData();renderSyncBadgeOnly();}},30000);
};
async function syncCall(action,body){
 const {data,error}=await sb.rpc('tracken_sync',{p_action:action,p_token:secureSession?.token||null,p_body:body});
 if(error)throw new Error(error.message);
 if(data?.auth_required){secureSession=null;adminLogged=false;throw new Error('Accedi nuovamente per inviare i movimenti salvati.');}
 if(data?.error)throw new Error(data.error);
 return data;
}
processOfflineQueue=async function(showMessage=true){
 if(queueProcessing||!sessionValid()||!navigator.onLine||Date.now()<syncRetryAt)return false;
 const owner=currentUserId, items=pending();if(!items.length)return false;
 queueProcessing=true;renderSyncBadgeOnly();let count=0;
 try{
  for(const op of items){
   if(currentUserId!==owner||!sessionValid())break;
   const result=await syncCall('submit',{operation:op});
   if(!['accepted','review','resolved'].includes(result.status))throw new Error('Risposta incompleta: il movimento resta sul dispositivo.');
   const stored={...op,status:result.status==='accepted'?'synced':'review',receipt:result};
   await TrackenStore.write('events',op.operation_id,stored);
   journal=journal.map(e=>e.operation_id===op.operation_id?stored:e);count++;syncChannel?.postMessage('changed');
  }
  syncFailures=0;syncRetryAt=0;
  if(currentUserId===owner)await fetchAllData();
  if(showMessage&&count)showAlert('ok',`${count} registrazioni ricevute dal server. Controlla eventuali verifiche nella coda.`);
 }catch(e){
  syncFailures++;syncRetryAt=Date.now()+Math.min(60000,5000*2**Math.min(syncFailures,4));
  if(showMessage)showAlert('error',e.message);
 }finally{queueProcessing=false;renderSyncBadgeOnly();}
 return count>0;
};
async function manualSync(){syncRetryAt=0;await processOfflineQueue(true);await openSyncCenter();}
async function refreshReceipts(){
 if(!sessionValid())return;
 const ids=mine().filter(e=>e.status==='review').slice(0,100).map(e=>e.operation_id);
 if(!ids.length)return;
 const data=await syncCall('receipts',{ids});
 for(const receipt of data.events||[]){
  if(receipt.status!=='resolved')continue;
  const old=journal.find(e=>e.operation_id===receipt.operation_id);if(!old)continue;
  const updated={...old,status:'resolved',receipt:{...old.receipt,reason:receipt.resolution_note}};
  await TrackenStore.write('events',updated.operation_id,updated);journal=journal.map(e=>e.operation_id===updated.operation_id?updated:e);
 }
}
async function openSyncCenter(){
 try{await refreshReceipts();}catch(e){/* Retry on the next opening. */}

 const rows=mine().slice().sort((a,b)=>b.device_sequence-a.device_sequence);
 let conflicts=[];
 if(sessionValid())try{conflicts=(await syncCall('reviews',{})).events||[];}catch(e){/* Local records remain visible. */}
 openModal(`<h3>Movimenti sul dispositivo</h3><p>Ultimo aggiornamento: ${formatDate(offlineProfile?.last_sync)}.</p><p>Orario dichiarato dal telefono. Il server conserva anche l’ora di ricezione; gli orologi possono differire.</p><button onclick="manualSync()">Sincronizza ora</button>${!sessionValid()?'<button onclick="closeModal();loginForSync()">Accedi per inviare</button>':''}<button onclick="exportLocalJournal()">Esporta copia locale</button><p class="small">Le copie includono foto e dati di lavoro: conservale in un luogo protetto.</p>${rows.slice(0,100).map(e=>`<div class="panel" style="margin:8px 0"><strong>${esc(e.article_name||'Registrazione precedente')}</strong><p>${esc(e.movement_type||'')} · ${formatDate(e.device_occurred_at||e.queued_at)}</p><b>${({pending:'Salvato sul telefono · da inviare',synced:'Ricevuto dal server',review:'Ricevuto · da verificare',resolved:'Verifica conclusa',legacy:'Versione precedente · verifica manuale'})[e.status]||e.status}</b><p>${esc(e.receipt?.reason||'')}</p></div>`).join('')||'<p>Nessun movimento locale per questo utente.</p>'}<h3>Verifiche sul server</h3>${conflicts.map(e=>`<div class="panel"><b>${esc(e.article_name)}</b><p>${esc(e.user_name)} · ${esc(e.movement_type)} · ${formatDate(e.device_occurred_at)} · ${esc(e.reason)}</p>${secureSession?.user.manager?`<button onclick="resolveReview('${e.operation_id}')">Registra verifica</button>`:''}</div>`).join('')||'<p>Nessuna verifica caricata.</p>'}<button onclick="closeModal()">Chiudi</button>`);
}
async function resolveReview(id){
 const note=prompt('Descrivi la verifica. Se necessario registra prima un movimento correttivo sull’attrezzo. La verifica non cambia automaticamente il possessore.');
 if(!note?.trim())return;
 try{await syncCall('resolve',{operation_id:id,note:note.trim()});await openSyncCenter();}catch(e){showAlert('error',e.message);}
}
function exportLocalJournal(){
 const blob=new Blob([JSON.stringify(mine(),null,2)],{type:'application/json'}),a=document.createElement('a');
 a.href=URL.createObjectURL(blob);a.download='tracken-movimenti-locali.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}
initApp=async function(){
 try{
  journal=await TrackenStore.read('events');offlineProfile=await TrackenStore.read('meta','profile');
  if(offlineProfile)serverSnapshot=await TrackenStore.read('meta','snapshot:'+offlineProfile.user.id);
  // Preserve old queue before removing its localStorage copy. No automatic replay.
  const legacy=JSON.parse(localStorage.getItem(OFFLINE_QUEUE_KEY)||'[]');
  for(const old of legacy){const id=old.operation_id||old.local_id||uid();if(!journal.some(e=>e.operation_id===id)){const saved={...old,operation_id:id,status:'legacy'};await TrackenStore.write('events',id,saved);journal.push(saved);}}
  if(legacy.length)localStorage.removeItem(OFFLINE_QUEUE_KEY);
  localReady=true;
 }catch(e){localReady=false;}
 render();hideProgress();
 if('serviceWorker' in navigator){
  try{await navigator.serviceWorker.register('./sw.js');await navigator.serviceWorker.ready;
   const el=document.getElementById('offlineAvailability');if(el)el.textContent=localReady?'App pronta alla riapertura senza rete dopo il primo accesso.':'Archivio locale non disponibile.';
  }catch(e){showAlert('error','Installazione offline non riuscita. Mantieni la pagina aperta e riprova con rete disponibile.');}
 }
};
window.resumeOffline=resumeOffline;window.loginForSync=loginForSync;window.openSyncCenter=openSyncCenter;window.manualSync=manualSync;
window.resolveReview=resolveReview;window.exportLocalJournal=exportLocalJournal;window.logoutAll=logoutAll;
window.addEventListener('online',()=>{syncRetryAt=0;processOfflineQueue(false);});
document.addEventListener('visibilitychange',()=>{if(!document.hidden){syncRetryAt=0;processOfflineQueue(false);}});
window.addEventListener('pagehide',()=>{}); // Journal is committed on each action, never on unload.
const syncChannel=typeof BroadcastChannel!=='undefined'?new BroadcastChannel('tracken-local-events'):null;
if(syncChannel)syncChannel.onmessage=async()=>{journal=await TrackenStore.read('events');hydrate();renderSyncBadgeOnly();};

function formatMovementTime(m){
 const local=m.device_occurred_at||m.created_at;
 return `${formatDate(local)}${m.device_occurred_at?`<br><small>Ora dispositivo · ricevuto ${formatDate(m.created_at)}</small>`:m._queued?'<br><small>Da sincronizzare</small>':''}`;
}
const baseConfirmMovement=confirmMovement, baseImageChange=handleMovementImageChange;
let movementBusy=false,imageBusy=false;
handleMovementImageChange=async function(event){imageBusy=true;try{await baseImageChange(event);}finally{imageBusy=false;}};
confirmMovement=async function(type){
 if(movementBusy)return;
 if(imageBusy)return showAlert('error','Attendi che la foto sia pronta prima di confermare.');
 movementBusy=true;
 try{await baseConfirmMovement(type);}finally{movementBusy=false;}
};
window.confirmMovement=confirmMovement;window.handleMovementImageChange=handleMovementImageChange;
