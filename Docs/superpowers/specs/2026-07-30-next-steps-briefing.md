# Briefing per i prossimi interventi — pronto per una sessione di brainstorming veloce

Data: 2026-07-30 (notte), preparato mentre l'utente dormiva su sua richiesta esplicita.

Questo non è uno spec approvato — è materiale di ricerca e opzioni pronte, così che la prossima sessione di brainstorming per ciascun punto parta già a metà strada invece che da zero. Nessuno di questi interventi è stato implementato: richiedono scelte dell'utente (vedi "Domande aperte" per ciascuno).

---

## 1. Retry/backoff sui fallimenti di rete S3 (Critico #3 in ROADMAP.md)

**Ricerca**: pattern standard Swift async/await — funzione generica di retry con backoff esponenziale (1s, 2s, 4s...), numero massimo di tentativi configurabile (tipicamente 3), che rispetta `Task.checkCancellation()` tra un tentativo e l'altro, e distingue errori "transitori" (di rete, HTTP 5xx) da errori permanenti (es. 403/404) che non vale la pena ritentare. Fonti: [Swift by Sundell — Automatically retrying an asynchronous Swift Task](https://www.swiftbysundell.com/articles/retrying-an-async-swift-task/), [SwiftRetry su GitHub](https://github.com/1amageek/SwiftRetry).

**Dove si applicherebbe nel codice**: `S3Syncer.upload(url:key:config:)` (singolo PUT) e i singoli step di `multipart(...)`, oggi in caso di errore incrementano solo `result.errors` e passano al file successivo senza ritentare.

**Approccio suggerito**: una funzione helper `retrying(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T` dentro `S3Syncer`, usata attorno alle singole richieste HTTP (PUT, parti multipart), NON attorno all'intero job (per non ripetere lavoro già fatto). Errori di rete (timeout, connessione persa) vanno ritentati; un 403 (credenziali) no.

**Domande aperte per l'utente**: quanti tentativi (3 è lo standard, ma è una scelta)? Il ritardo tra tentativi deve essere visibile nella UI ("riprovo tra 2s...") o silenzioso? I file che falliscono dopo tutti i tentativi devono finire nello stesso contatore "errori" di oggi, o meritano una categoria a parte visibile all'utente?

---

## 2. Cleanup multipart upload orfani (Critico #4)

**Ricerca**: la pratica standard AWS S3 è una **lifecycle rule** sul bucket (`AbortIncompleteMultipartUpload`, tipicamente con una finestra di 7 giorni) che il provider esegue automaticamente lato server — non richiede codice nell'app. Fonti: [AWS docs — Configuring a bucket lifecycle to delete incomplete multipart uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpu-abort-incomplete-mpu-lifecycle-config.html), [AWS blog — Discovering and deleting incomplete multipart uploads](https://aws.amazon.com/blogs/aws-cloud-financial-management/discovering-and-deleting-incomplete-multipart-uploads-to-lower-amazon-s3-costs/).

**Il problema pratico**: non sappiamo se **Cubbit** (il provider S3-compatibile usato da questo progetto) supporta le lifecycle rule, e configurarle richiederebbe comunque un'azione manuale sul pannello Cubbit (fuori dal codice dell'app) o una chiamata `PutBucketLifecycleConfiguration` che `S3Syncer` non implementa oggi.

**Alternativa lato app**: `ListMultipartUploads` (endpoint S3 standard) elenca gli upload multipart incompleti sul bucket; l'app potrebbe chiamarlo all'avvio di un job SSD→S3 (o nel pannello Revisione già esistente) e offrire di abortirli esplicitamente (`AbortMultipartUpload`, già implementato — usato oggi solo su cancel esplicito dell'utente durante lo stesso job).

**Domande aperte**: preferisci configurare una lifecycle rule direttamente sul pannello Cubbit (probabilmente la soluzione più semplice e definitiva, ma va verificato se Cubbit la supporta), oppure vuoi che l'app stessa controlli e proponga la pulizia (via `ListMultipartUploads`, magari integrato nel pannello Revisione già esistente in Tools)?

---

## 3. Cifratura lato client prima dell'upload (Critico #5)

**Ricerca**: Arq usa un modello zero-knowledge — AES-256/CBC con una chiave di sessione casuale, IV casuale, HMAC-SHA256 per l'integrità, chiave derivata dalla password dell'utente via PBKDF2 (200.000 round). Il provider cloud non vede mai né la chiave né il contenuto in chiaro. Fonte: [Arq Cloud Backup Data Format](https://www.arqbackup.com/docs/arqcloudbackup/English.lproj/dataFormat.html).

**Implicazioni serie per questo progetto**: è la modifica con più rischio di tutta la lista.
- Se cifri, i file su Cubbit non sono più leggibili da nessun altro tool (incluso te, se perdi la password/chiave) — serve una strategia di backup della chiave stessa, separata dal bucket.
- Rompe la compatibilità con quello che c'è già su Cubbit oggi (120.842 oggetti non cifrati) — o cifri solo i nuovi upload (bucket misto, complesso da gestire) o fai una migrazione completa (richiede ri-caricare tutto, ore/giorni di banda).
- CryptoKit di Apple (già importato nel progetto per SHA256/HMAC) supporta AES-GCM nativamente — tecnicamente fattibile senza dipendenze esterne.

**Domande aperte, prima ancora di iniziare a progettare**: vuoi davvero questo, sapendo il rischio "perdi la password = perdi tutto"? Se sì: chiave derivata da una password che ricordi tu, o generata random e backuppata da qualche parte (dove?)? Cifratura per i soli file nuovi o migrazione completa del bucket esistente?

---

## 4. Upload paralleli — TaskGroup (Alto #6)

**Ricerca**: pattern standard `withThrowingTaskGroup` con concorrenza limitata (non lanciare tutti i task insieme, ma mantenere una finestra fissa: aggiungi un nuovo task solo quando uno precedente completa, via `group.next()`). Fonti: [A Deep Dive into withThrowingTaskGroup](https://www.dhiwise.com/post/a-beginners-guide-to-using-withthrowingtaskgroup-in-swift), [Apple Developer Forums — limiting concurrent tasks](https://developer.apple.com/forums/thread/735524).

**Dove si applicherebbe**: il ciclo `for item in files { ... try await upload(...) }` in `S3Syncer.sync()` (upload, oggi sequenziale) — e allo stesso modo il ciclo dei chunk in `multipart(...)`.

**Approccio suggerito**: `withThrowingTaskGroup` con un limite di 4-6 upload concorrenti (numero ragionevole di default, da confermare), mantenendo `onProgress`/`onStatus` thread-safe (gli aggiornamenti da task concorrenti vanno comunque dispacciati su `DispatchQueue.main.async` come già fanno oggi i singoli file).

**Nota di correttezza importante**: con upload concorrenti, l'ordine di completamento non è più garantito — `result.done`/`result.percent` restano corretti (sono contatori), ma il messaggio di stato "sto caricando X" mostrerà file "a caso" invece che in ordine, e bisogna gestire `cancelled`/`Task.isCancelled` dentro ogni task del gruppo, non solo nel loop esterno (visto quanto ci ha morso lo stesso problema nel restore stanotte).

**Domande aperte**: quanti upload concorrenti in parallelo (4? 6? di più)? Va reso configurabile o è un numero fisso nel codice?

---

## 5. Credenziali S3 nel Keychain invece di rclone.conf (Alto #10)

**Ricerca**: pattern standard `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate` del framework Security, già disponibile senza dipendenze esterne. Fonte: [macOS Keychain Tutorial for Developers](https://noboxdev.com/blog/macos-keychain-tutorial-for-developers).

**Approccio suggerito**: una nuova funzione (o estensione di `S3Syncer.readConfig()`) che prova PRIMA il Keychain (`service: "AppBackupFoto"`, `account: "Cubbit"`), e se non trova nulla fa fallback alla lettura di `rclone.conf` come oggi — così non serve una migrazione forzata, il primo avvio con Keychain vuoto continua a funzionare esattamente come ora finché non si decide di migrare esplicitamente.

**Domande aperte**: vuoi anche un modo per l'utente di inserire le credenziali direttamente nell'app (un piccolo form in Tools), o preferisci continuare a modificarle a mano in `rclone.conf` e far sì che l'app le "adotti" nel Keychain automaticamente al primo avvio dopo l'aggiornamento (leggendo una volta da rclone.conf e salvandole nel Keychain)?

---

## 6. Scheduling/automazione backup (Alto #7)

**Nota**: non ho trovato tempo per una ricerca approfondita su questo stanotte (priorità andata al bug di memoria). Prima considerazione: su macOS le opzioni standard sono `NSBackgroundActivityScheduler` (semplice, ma richiede l'app aperta o almeno in background) oppure un vero LaunchAgent registrato via `SMAppService` (avvia l'app anche se non è in esecuzione, più solido ma più invasivo da installare/rimuovere). Da approfondire nella prossima sessione prima di proporre un design.

**Domande aperte, di base**: lo scheduling deve funzionare anche se chiudi l'app (richiede LaunchAgent), o basta "se l'app è aperta, parte da sola all'ora giusta" (più semplice, `NSBackgroundActivityScheduler`)? Che granularità vuoi (ogni notte a un'ora fissa? solo "quando l'SSD viene collegato"? entrambe)?

---

## Cosa NON è in questo briefing

Gli item "valore aggiunto" della roadmap (catalogo/ricerca backup, versioning, localizzazione, badge dock, notifiche azionabili, miniature, auto-update Sparkle, notarization, revisione periodica) non sono stati approfonditi stanotte — priorità data ai punti critici/alti. Restano nella lista di `Docs/ROADMAP.md` così come sono.
