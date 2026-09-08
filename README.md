# Tracken

Inventario e movimenti con autenticazione verificata da PostgreSQL.

## Sicurezza

- Il frontend usa esclusivamente `tracken_api`; le tabelle non sono accessibili ai ruoli browser.
- PIN di 8–12 cifre protetti con bcrypt, mai restituiti ai client. I vecchi PIN devono essere sostituiti.
- Attivazione tramite codice casuale monouso valido 24 ore; ogni persona sceglie il proprio PIN.
- Sessioni casuali di 256 bit, archiviate sul server solo come digest, con scadenza di 20 minuti. Il client le conserva solo in memoria.
- Limite di 5 tentativi errati per account, blocco di 15 minuti e limite globale di 60 tentativi/minuto. Il limite globale può causare indisponibilità temporanea durante un attacco: un gateway con controllo per origine è un ulteriore miglioramento.
- `manager` è separato da `role=admin`: il primo gestisce utenti e anagrafiche, il secondo conserva i privilegi operativi estesi. Il gestore si assegna solo dalla console amministrativa del database.
- Gli utenti ordinari vedono i movimenti che li riguardano; admin operativi e gestore vedono lo storico globale, fino a 300 righe per caricamento.
- Movimenti atomici, verifica dello stato atteso e identificatore idempotente. L'identità dell'autore viene dalla sessione, non dal corpo della richiesta.
- La coda offline viene sincronizzata solo dalla stessa persona autenticata. Le vecchie operazioni senza identificatore/stato atteso richiedono verifica manuale, non vengono eseguite automaticamente.
- Disattivazione di utenti, ubicazioni e articoli senza cancellare lo storico.
- Le coordinate restano informazioni dichiarate dal dispositivo, non una prova certificata di presenza. L'indirizzo può essere ricavato tramite Nominatim su richiesta di acquisizione del movimento.

## Rilascio coordinato

1. Eseguire `supabase/migrations/20260908_secure_api.sql` sul progetto corretto. Questo prepara l'API e gli account privati, senza ancora chiudere il vecchio frontend.
2. Assegnare il solo gestore autorizzato in `tracken_private.accounts`; generare un codice di attivazione casuale sul server e memorizzarne solo il digest. Non salvare codici o PIN nel repository o nei log di rilascio.
3. Far attivare al gestore il nuovo PIN tramite l'interfaccia sicura preparata. Non usare le credenziali pubblicate in precedenza.
4. Pubblicare il nuovo `index.html` e verificare il deploy GitHub Pages.
5. Eseguire `20260908_lock_public.sql`: revoca grants, elimina le vecchie policy aperte e invalida il campo PIN legacy. La migrazione si ferma se il gestore non è ancora attivo.
6. Verificare richieste anonime negate, login del gestore e attivazione degli altri utenti. Disattivare l'esposizione automatica di nuove tabelle nella Data API.

Le migrazioni sono progettate per essere eseguite una sola volta. Non ripristinare le vecchie policy aperte come procedura di rollback: correggere il rilascio mantenendo chiusi gli accessi diretti.

`database.json` non contiene più dati. Le versioni storiche del repository possono ancora contenere lo snapshot e le vecchie credenziali: i vecchi accessi vengono invalidati, ma la rimozione dalla cronologia è un intervento separato.

## Test locali

Usare esclusivamente un database temporaneo con i dati sintetici di `tests/bootstrap.sql`. Eseguire la migrazione dell'API, poi `tests/security.sql`. Mai eseguire bootstrap o test di fixture sul progetto di produzione.

`tests/frontend.cjs` usa jsdom (`JSDOM_PATH` può indicare l'installazione locale). Verifica caricamento senza autenticazione, login server, immagini sicure, proprietà della coda e pulizia dei dati al logout. Non contatta il progetto Supabase.


## Mobile e lavoro senza rete (settembre 2026)

Applicare prima `20260909_offline_journal.sql`, poi pubblicare tutti i file statici nella stessa cartella. Non pubblicare solo index.html. La migrazione è compatibile con il frontend precedente.

Al primo accesso online il dispositivo salva in IndexedDB una copia dell'inventario e il profilo locale, senza PIN o token. La registrazione locale è disponibile per sette giorni dall'ultimo aggiornamento autenticato. Si tratta di bozze locali: il server richiede sempre una sessione valida e verifica ruolo, account attivo e stato dell'attrezzo durante l'invio. Il logout blocca la riapertura locale del profilo ma conserva il giornale per il successivo accesso dello stesso utente.

Il service worker conserva l'app senza dipendenze esterne e permette la riapertura senza rete. Aggiungere Tracken alla schermata Home, completare un accesso online e verificare la disponibilità offline prima di partire. Il browser può negare la persistenza o eliminare dati se manca spazio: non cancellare i dati del sito e non usare navigazione privata. Il dispositivo deve avere un blocco schermo. Una copia esportata contiene dati e foto aziendali.

Ogni movimento viene prima confermato da una transazione IndexedDB, che assegna un contatore progressivo per dispositivo. La sincronizzazione procede all'apertura, al ritorno online e ogni pochi secondi con attesa crescente dopo errori; non richiede esecuzione in background, che i telefoni possono sospendere. Il salvataggio ricevuto dal server viene marcato nel giornale soltanto dopo una ricevuta. Gli identificativi consentono di ritentare anche dopo la perdita della risposta senza duplicare il movimento.

Il registro privato offline_events conserva anche eventi discordanti, orario dichiarato dal dispositivo, sequenza locale e ricezione server. L'ora del dispositivo non decide automaticamente il possessore. Le dipendenze dello stesso attrezzo vengono validate dal server. Un evento discordante non blocca gli altri: compare in "Da verificare". Il gestore controlla l'attrezzo, registra se necessario un nuovo movimento correttivo e annota la verifica. La risoluzione non riscrive lo storico. La vista mostra al massimo 100 verifiche/locali recenti; l'esportazione include l'intero giornale dell'utente. Le vecchie code vengono conservate per verifica manuale.

Le foto restano incorporate nelle registrazioni: questo rilascio non le migra a Storage. Il giornale non viene eliminato automaticamente. Valutare successivamente conservazione/archiviazione e volumi delle immagini.

Per ogni nuova pubblicazione modificare la versione CACHE in sw.js. Il service worker nuovo entra in uso dopo la chiusura delle vecchie finestre, per evitare versioni miste. La cache non contiene risposte API né credenziali.

Test: `tests/offline.sql` su fixture vuota + migrazioni, `tests/offline.cjs` con jsdom/fake-indexeddb, `tests/service-worker.cjs`. Coprono perdita di risposta, riavvio, foto, scadenza sessione, conflitti/orologi discordanti, autorizzazioni, ricevute e fallimento per spazio locale.
