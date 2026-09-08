/* Atomic local journal. A successful write means IndexedDB committed. */
window.TrackenStore = (() => {
  let connection;
  function open() {
    if (connection) return connection;
    connection = new Promise((resolve, reject) => {
      const r = indexedDB.open('tracken-offline-v2', 1);
      r.onupgradeneeded = () => {
        r.result.createObjectStore('meta');
        r.result.createObjectStore('events', {keyPath:'operation_id'});
      };
      r.onsuccess = () => { r.result.onversionchange=()=>r.result.close(); resolve(r.result); };
      r.onerror = () => reject(r.error);
      r.onblocked = () => reject(new Error('Chiudi le altre schede Tracken e riprova.'));
    });
    return connection;
  }
  async function read(store, key) {
    const d=await open();
    return new Promise((resolve,reject)=>{
      const tx=d.transaction(store), r=key===undefined?tx.objectStore(store).getAll():tx.objectStore(store).get(key);
      r.onsuccess=()=>resolve(r.result); r.onerror=()=>reject(r.error);
    });
  }
  async function write(store,key,value) {
    const d=await open();
    return new Promise((resolve,reject)=>{
      const tx=d.transaction(store,'readwrite');
      if(store==='events') tx.objectStore(store).put(value); else tx.objectStore(store).put(value,key);
      tx.oncomplete=()=>resolve(value); tx.onerror=()=>reject(tx.error); tx.onabort=()=>reject(tx.error||new Error('Salvataggio interrotto.'));
    });
  }
  async function append(op) {
    const d=await open();
    return new Promise((resolve,reject)=>{
      const tx=d.transaction(['meta','events'],'readwrite'), meta=tx.objectStore('meta'), events=tx.objectStore('events');
      let saved;
      const r=meta.get('device');
      r.onsuccess=()=>{
        const device=r.result||{id:crypto.randomUUID(),sequence:0};
        device.sequence++;
        saved={...op,device_id:device.id,device_sequence:device.sequence,status:'pending',queued_at:new Date().toISOString()};
        events.add(saved); meta.put(device,'device');
      };
      tx.oncomplete=()=>resolve(saved); tx.onerror=()=>reject(tx.error); tx.onabort=()=>reject(tx.error||new Error('Salvataggio interrotto.'));
    });
  }
  return {read,write,append};
})();
