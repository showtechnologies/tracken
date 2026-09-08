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
