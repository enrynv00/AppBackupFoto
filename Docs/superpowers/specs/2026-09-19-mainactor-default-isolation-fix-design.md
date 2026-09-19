# Spec — Il lavoro "in background" che tornava sul main thread (isolamento MainActor di default)

**Stato: APPROVATA da Enrico il 2026-09-19.** Risposte alle domande aperte (in fondo, aggiornate): 1→(a) il backup non parte e l'app spiega perché, in un linguaggio non tecnico; 2→sì, gate di compilazione in Debug; 3→i cinque punti fuori scope non si implementano, vanno registrati come punti aperti in `Docs/ROADMAP.md` (non come ticket in `Docs/superpowers/tickets/`) con le evidenze già raccolte qui.

Piano di esecuzione: `Docs/superpowers/plans/2026-09-19-mainactor-default-isolation-fix.md`.

## Il sintomo, e cosa lo prova

**Dopo un MAC → SSD l'app va in beachball per circa 6 minuti.** Confermato il 2026-09-19 sull'app reale, non ipotizzato:

- log di sistema: main thread muto dalle **01:15:59 alle 01:22:10**;
- campionamenti con `sample` durante il blocco: main thread al 100% in `closure #1 in BackupRunner.rebuildLibraryIndex` → `LibraryIndexer.scan` → `NSURLDirectoryEnumerator nextObject` → `getattrlist` sull'SSD, e `canonicalPathComponents` → `realpath` → `statfs`;
- riproduzione con un programma standalone compilato con le stesse impostazioni del progetto.

**La catena.** `runMacToSSD` chiama `run(label:refreshesLibraryIndex: true)`; a job riuscito parte `autoRefreshLibraryIndexIfEnabled()` → `rebuildLibraryIndex()`, che lancia `idx.scan(...)` dentro un `Task.detached`. Il codice *sembra* fuori dal main thread. Non lo è: il target ha `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (dal primo commit, è il default del template di Xcode 26), quindi **ogni tipo non annotato è `@MainActor`**, `LibraryIndexer` compreso. Chiamare un suo metodo sincrono da un contesto `async` non isolato — il corpo di un `Task.detached` — produce in Swift 5 **solo un warning** ("cannot be called from outside of the actor; this is an error in the Swift 6 language mode") e a runtime **un salto implicito sul main actor**. Tutta la scansione (47.482 file, `stat` + `realpath` + una query SQLite per file) gira quindi sul main thread.

## Misure fatte per questa spec (2026-09-19)

Tutte con `derivedDataPath` nello scratchpad, mai sulla build che Enrico sta usando. Nessuna modifica al progetto: le prove di codice sono su programmi standalone o su una **copia usa-e-getta** del progetto nello scratchpad.

### 1. L'elenco completo dei warning: 29, non 43

Build pulita (`build-for-testing`, derived data nuova), Xcode 27.0 / Swift 6.4, flag reali del target: `-swift-version 5 -default-isolation=MainActor` più le cinque feature di *Approachable Concurrency* (`DisableOutwardActorInference`, `GlobalActorIsolatedTypesUsability`, `InferIsolatedConformances`, `InferSendableFromCaptures`, **`NonisolatedNonsendingByDefault`**). **29 warning unici** per file:riga:colonna, tutti in `ContentView.swift`, **zero** nel target di test. Il 43 riportato prima conta righe duplicate dell'output di `xcodebuild` (lo stesso diagnostico compare in più fasi), non warning distinti.

| Classe | Cosa succede a runtime | Siti (riga al 2026-09-19 — usare `grep`) |
| :--- | :--- | :--- |
| **A — "cannot be called/accessed from outside of the actor"** in contesto `async` | **salto sul main thread** (il bug) | `store.count()` in `refreshIndexedFileCount` (6671); `idx.scan` in `rebuildLibraryIndex` (6735); `store.duplicateGroups()` (10929) e `DuplicateBatch(groups:)` (10933) in `DuplicatesView.loadGroups`; `trasher.run` in `DuplicatesView.startTrashing` (10998); `self.cancelled` di `S3Syncer` in un `group.addTask` (5439) |
| **F — "call to main actor-isolated … in a synchronous nonisolated context [#ActorIsolatedCall]"** | nessun salto: il codice gira sul thread del chiamante **violando** l'isolamento dichiarato. In Swift 6 diventerebbe errore, e con controlli dinamici un crash | `ProcessOutputBuffer.append` (1194), `ContinuationGuard.claim` (1203), `AdaptiveLimiter.applying` dentro l'actor (5244), `S3Syncer.readConfigWithSource` (6570), e in `isAlreadyInLibrary`/`importPreviewDuplicates`: `candidates(withSize:)`, `hasAnyEntry(withSize:)` ×2, `sha256(of:)` ×3, `entries(withHash:)`, `ImportSessionIndex.init`, `record(hash:at:)` ×2 (7046-7225) |
| altri riferimenti isolati | come F | `buffer.text` da closure `Sendable` (1204); `self.cancelled` in `addNext()` (5436) |
| catture non `Sendable` | nessun effetto oggi, errore in Swift 6 | `[weak self]` catturato in `await MainActor.run { … }` dentro `run(label:)` ×2 (7467, 7497) e `publishCurrentFile` (7554); `alertSink` di `LibraryIndexCard` passato come `AlertSink` ×4 (10494, 10602, 10611, 10624) |

### 2. Come si comporta davvero l'isolamento di default: sei casi, misurati

Programma standalone con gli stessi flag del target:

| Caso | Chi chiama cosa | Gira sul main? | Warning? |
| :--- | :--- | :---: | :---: |
| A | `Task.detached { oggettoMainActor.metodoSincrono() }` | **sì** | sì (classe A) |
| B | `DispatchQueue.global().async { oggettoMainActor.metodo() }` | no | **nessuno** |
| C | `Task.detached { oggettoNonisolated.metodo() }` | no | no |
| D | `await nonisolatedAsync()` chiamata dal MainActor | **sì** (`NonisolatedNonsendingByDefault`) | no |
| E | `await funzioneConcurrent()` (`@concurrent`) dal MainActor | no | no |
| F | `Task.detached { Result { oggettoMainActor.metodo() } }` (closure sincrona) | no | sì (classe F) |

Tre conseguenze che reggono il resto della spec:

- **Solo la classe A è il bug di prestazioni.** La F è una violazione latente, non un salto.
- **Zero warning non significa zero lavoro sul main thread.** Il caso B è silenzioso (è il modo in cui `FileSyncer` gira oggi, e funziona per caso), e il caso D è codice perfettamente legale che torna sul main.
- **Un `nonisolated` su una funzione `async` non basta per uscire dal main thread** (caso D): serve `@concurrent`. Questa spec non rende `async` niente, ed è anche per questo.

### 3. Le alternative sull'impostazione di progetto, misurate

Stesso sorgente, impostazione cambiata solo da riga di comando:

| Variante | Esito |
| :--- | :--- |
| com'è oggi | 29 warning |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` | **10 warning**, build verde |
| `SWIFT_STRICT_CONCURRENCY = complete` | 242 warning (157 sono override di `XCTestCase` nei test) |
| `SWIFT_VERSION = 6` | **160 errori**, build rossa |

### 4. Cosa fa `-warnings-as-errors`, misurato su due mutanti

Copia usa-e-getta con le correzioni di questa spec applicate, poi due mutanti: `LibraryIndexStore` rimesso `@MainActor` e `sha256(of:)` rimessa `@MainActor`. Con `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`: **build rossa** sui siti di classe A (`count()`, `duplicateGroups()`), mentre i **17 siti di classe F restano warning**. E `-Werror ActorIsolatedCall` (controllo per gruppo di diagnostici) non ha effetto su nessuna delle due classi in modalità Swift 5. Il gate di compilazione copre quindi esattamente la classe che rallenta, e non l'altra.

### 5. Il prototipo: da 29 a 0

Sulla stessa copia usa-e-getta, con l'elenco di annotazioni della sezione Design: **0 warning Swift in entrambi i target**, `build-for-testing` verde anche con `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. **La suite non è stata eseguita** (lancia l'app come host dei test mentre Enrico usa la sua): lo fa il piano. Il prototipo è servito a misurare l'effetto a cascata delle annotazioni, che è risultato nullo — non sostituisce l'implementazione, e non va copiato: il piano lo riscrive a passi, test prima.

## Cosa comporta oggi, oltre alla lentezza

Il salto sul main non costa solo il beachball. Con il main thread occupato per minuti:

1. **«Interrompi» della lettura non funziona.** Il click arriva al main thread solo quando `scan` è già finita. Lo stesso vale per l'osservatore di smontaggio di `BackupRunner` (`queue: .main`): durante una lettura reale non è mai scattato in tempo. La scansione resta sicura lo stesso — le difese vere sono l'`errorHandler` e `st_dev`, che girano dentro `scan` — ma i due comandi sono morti.
2. **«Interrompi» dello spostamento nel Cestino non funziona.** `DuplicateTrasher.run` salta sul main (classe A): un blocco da 500 file, cioè minuti di rilettura e rihash, congela la finestra e rende l'interruzione impossibile. È il percorso a danno più alto del progetto.
3. **La barra di avanzamento non avanza.** Gli aggiornamenti `Task { @MainActor in … }` si accodano e vengono eseguiti tutti insieme a lavoro finito.
4. **Una mutua esclusione accidentale.** Mentre il main è bloccato l'utente non può avviare un backup, né aprire una seconda finestra Doppioni e lanciare un secondo spostamento. Oggi è il bug a garantirlo, non il codice: le regole scritte («niente spostamento nel Cestino durante un backup o una lettura dell'elenco») sono controllate **in un verso solo** (`DuplicatesStatus.trashDisabledReason` guarda il job e la lettura; il job e la lettura non guardano lo spostamento, e `isTrashing` è uno `@State` della finestra, che riaprendola torna `false`). **Togliere il bug senza aggiungere il verso mancante aprirebbe proprio il caso che la spec del pannello Doppioni vieta** («cestinare mentre un mirror legge gli stessi file è esattamente il modo di trasformare due operazioni corrette in un guasto»).

## I rallentamenti del 2-3 settembre avevano la stessa causa?

Solo in parte, e i dati permettono di dire quale.

- **Pannello Doppioni (2026-09-02): causa diversa, correzione efficace a metà.** Il `sample` di allora mostrava il main thread in `DuplicatesView.body → headerLine → DuplicateBatch.init`: calcolo dentro il `body`, che è main per natura. Causa: il batch ricostruito a ogni ridisegno. La correzione ha tolto la ripetizione — e quello è un guadagno vero. Ma ha anche dichiarato di spostare il calcolo «fuori dal main thread, nello stesso `Task.detached`», e questo **non è successo**: `store.duplicateGroups()` e `DuplicateBatch(groups:)` sono esattamente due dei siti di classe A. Oggi il pannello blocca ancora il main **una volta** a ogni caricamento (e dopo ogni spostamento, che chiama `loadGroups()`). `.claude/rules/architecture.md` lo descrive come fuori dal main: è falso, e il piano lo corregge. **Quanto dura quel blocco con 12.001 gruppi non è misurato**: lo misura la verifica del piano.
- **`VolumeMonitor` (2026-09-03): causa diversa, correzione efficace.** Il `fileExists` stava dentro un `DispatchQueue.main.async` esplicito. La nuova `probeQueue` è il caso B: gira davvero fuori dal main.
- **Avvio (2026-09-03): metà e metà.** La lettura del Keychain sta dentro `Result { … }`, una closure sincrona: è il caso F, gira davvero fuori dal main, **correzione efficace**. L'apertura di SQLite è stata solo **rimandata di un giro di run loop** (lo dice il commento stesso) e resta sul main, dentro il getter `lazy` di `libraryIndexStore`. E il `store.count()` che segue, lanciato in un `Task.detached`, è un sito di classe A: **torna sul main**. Stessa causa radice, ma per una sola `SELECT COUNT(*)`: costo probabilmente piccolo, non misurato.

## Design

### D1 — Si tiene `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

Raccomandazione: **una sola strada, annotare il lavoro di fondo tipo per tipo; l'impostazione di progetto non cambia.**

| Opzione | Pro | Contro |
| :--- | :--- | :--- |
| **A. Tenere MainActor, `nonisolated` mirato (scelta)** | circa 50 dichiarazioni, cambio di sola annotazione per quasi tutte (misurato sul prototipo); il compilatore da quel momento **controlla** i tipi di fondo; ogni tipo che nasce nuovo resta protetto per default | bisogna ricordarsi di annotare il prossimo tipo di fondo (coperto dal gate D6) |
| B. Default `nonisolated` | 10 warning invece di 29, a prima vista la più economica | rende non isolati in blocco anche `BookmarkManager`, `VolumeMonitor`, `AuthGateManager`, `AppearanceManager`, `ImmichManager`, `ReviewEngine`: tutti `ObservableObject` con `@Published`, oggi protetti proprio dal default. I salti sul main che oggi **proteggono per caso** un `@Published` scritto da un `Task.detached` diventerebbero **data race silenziose**: in modalità Swift 5 minimale il compilatore non le segnala (lo dicono i 10 warning: non c'è nessuna delle violazioni nuove). Scambia un bug di prestazioni visibile con bug di correttezza invisibili |
| C. Passare a Swift 6 | errori al posto dei warning | 160 errori; e i casi B esistenti (`FileSyncer`) diventerebbero **crash a runtime** per i controlli dinamici di isolamento. Troppo per un bug fix; questo lavoro lo avvicina comunque |
| D. `LibraryIndexStore`/`LibraryIndexer` come `actor` | isolamento garantito dal linguaggio | tutto diventa `async`: `isAlreadyInLibrary` è sincrona e chiamata dalla coda di `FileSyncer`; e una `scan` di minuti bloccherebbe l'esecutore dell'actor. Lo store ha già la sua serializzazione (coda seriale), misurata e testata |

### D2 — Cosa diventa `nonisolated`, e perché è davvero thread-safe

Regola: si annota `nonisolated` un tipo o una funzione **solo se** gira fuori dal main thread oggi (o deve farlo) **e** si può scrivere in una riga perché è sicuro. `@unchecked Sendable` si usa solo accanto a quella riga.

| Dichiarazione | Perché serve | Perché è sicura |
| :--- | :--- | :--- |
| `LibraryIndexStore` (`nonisolated final class …: @unchecked Sendable`) | usata da scansione, import, pannello, trasher, conteggio | **tutto** lo stato mutabile (`db`) si tocca solo dentro `queue.sync`; `url` è `let`; `deinit` ha accesso esclusivo per definizione. È l'invariante già scritto nel doc-comment (SIGSEGV misurato senza coda): l'annotazione lo rende verificabile, non lo cambia |
| `LibraryIndexer` (`… : @unchecked Sendable`) | la `scan` | `store` e `fm` sono `let` (`FileManager.default` è thread-safe per queste operazioni); `cancelled` passa già da `NSLock`; tutto il resto dello stato di una scansione è **locale** a `scan`. Il contratto «una scansione per volta» resta, ed è semantico (consumo del cancel), non di memoria: lo garantisce `isIndexing` sul MainActor |
| `ImportSessionIndex` (`… : @unchecked Sendable`) | coda di `FileSyncer` | `NSLock` su `bySize`, già presente |
| `TrashManifestStore` (`… : @unchecked Sendable`) | `record` dal trasher, `lastBatch`/`restore` dal main | ogni accesso a `manifest` è dentro `lock.withLock` (verificato riga per riga, scrittura su disco compresa); `url` è `let` |
| `DuplicateTrasher` (`… : @unchecked Sendable`) | `run` fuori dal main | solo proprietà `let`, stato di `run` tutto locale |
| `FileSyncer` (`… : @unchecked Sendable`) | **non** segnalato da nessun warning: è il caso B | vedi D3: l'unica `var` (`cancelled`) diventa un `CancelFlag`. Serve a far controllare al compilatore, d'ora in poi, cosa la coda di copia chiama: oggi `FileSyncer` potrebbe leggere `BookmarkManager.shared.urls` dalla coda di lavoro senza un warning |
| value type e funzioni pure: `LibraryExclusions`, `canonicalPathComponents`, `IndexEntryVerdict`, `indexEntryVerdict`, `LibraryIndexEntry`, `DuplicateGroup`, `normalizedIndexKey`, `mainLibraryFolderKey`, `importFolderKey`, `DuplicateKeepReason`, `DuplicateKeepChoice`, `topLevelFolderKey`, `isInMainLibrary`, `isInImportFolder`, `duplicateKeepChoice`, `duplicateBatchFileCap`, `duplicateBatchByteCap`, `DuplicateBatch`, `TrashedItem`, `RestoreSkipReason`, `RestoreOutcome`, `TrashManifest` (+ estensione), estensione di `TrashedItem`, `DuplicateTrashSkipReason`, `DuplicateTrashOutcome`, `isAllowedStoreLocation`, `isRunningUnderTests`, `storeAllowedRoots`, `isPathInside`, `MeasuredHash`, `sha256Measured`, `sha256(of:)` | chiamate dai tipi sopra | nessuno stato condiviso mutabile; le `let` globali sono inizializzate una volta in modo thread-safe dal runtime |
| `S3Syncer.AdaptiveLimiterState`, `AdaptiveLimiterOutcome`, `AdaptiveLimiter` | chiamate dall'actor `AdaptiveUploadGate` | logica pura, già testata in `AdaptiveLimiterTests` |
| `S3Syncer.S3Config`, `KeychainCredentials`, `keychainQuery`, `readFromKeychain`, `writeToKeychain`, `readConfig`, `readConfigWithSource`, `readConfigFromFile`, `validateEndpoint` | la lettura delle credenziali **già** gira fuori dal main dal 2026-09-03 (caso F) | funzioni statiche senza stato; le API Keychain sono thread-safe. **Tocca il flusso delle credenziali**: nessun cambio di comportamento, ma passa dal Security/Rules Auditor |
| `ProcessOutputBuffer`, `ContinuationGuard` (Immich) | handler di `Pipe`/`Process` su thread arbitrari | hanno già `NSLock` e `@unchecked Sendable`: mancava solo `nonisolated` |

Resta `@MainActor` tutto il resto, `BackupRunner` e `S3Syncer` compresi (di `S3Syncer` cambia solo il flag di interruzione, D3).

**Cosa NON si fa:** nessuna funzione diventa `async`, nessun `Task.detached` cambia posto, nessun call site in `BackupRunner`/`DuplicatesView` cambia forma. Il bug si chiude cambiando l'isolamento dei **chiamati**, non la struttura dei chiamanti.

### D3 — I flag di interruzione: uno solo, con il lock

Oggi ne esistono quattro versioni: `LibraryIndexer.cancelled` (con `NSLock`, corretto), `CancelFlag` privata del pannello Doppioni (con `NSLock`, corretta, ma `@MainActor` per default), e due `private var cancelled = false` **nudi** in `FileSyncer` e `S3Syncer`, scritti dal main e letti da un altro thread. Quello di `FileSyncer` è una data race vera, non segnalata (caso B); quello di `S3Syncer` produce due dei 29 warning.

Decisione: **`CancelFlag` diventa il tipo condiviso** (`nonisolated final class CancelFlag: @unchecked Sendable`, non più `private`, con `cancel()`, `reset()`, `isCancelled`). `FileSyncer` e `S3Syncer` tengono `private let cancelFlag = CancelFlag()` e una `cancelled` calcolata (in `S3Syncer`: `nonisolated private var cancelled: Bool`); le assegnazioni `cancelled = false` diventano `cancelFlag.reset()`. **`LibraryIndexer` non si tocca**: il suo flag è già corretto, ha un contratto di consumo particolare (azzerato alla *fine* di `scan`) ed è coperto da test e mutation testing: migrarlo sarebbe rischio senza guadagno. Scelta `NSLock` e non `Mutex`/`Atomic` del modulo Synchronization per coerenza con i cinque lock già presenti.

### D4 — Il verso mancante della mutua esclusione (obbligatorio, non opzionale)

Vedi il punto 4 di «Cosa comporta oggi». Con il trasher fuori dal main, lo stato «spostamento nel Cestino in corso» deve essere visibile a chi avvia job e letture:

- `BackupRunner` guadagna `@Published private(set) var isTrashingDuplicates` con `beginDuplicateTrashing() -> Bool` (rifiuta se è già in corso uno spostamento, un job o una lettura) e `endDuplicateTrashing()`. Tutto sul MainActor: controllo e impostazione sono atomici rispetto a ogni altro gate. Lo `@State isTrashing` di `DuplicatesView` sparisce: riaprire la finestra non azzera più lo stato.
- Un gate puro nuovo, `JobStartGate.blockedReason(...)`, consultato da `run(label:refreshesLibraryIndex:work:)` — il punto da cui passano **tutti** i job che scrivono (Mac→SSD, SSD→HDD, SSD→Cubbit, import). Se c'è un motivo, il job non parte e l'utente legge **il motivo**, come in tutto il resto dell'app.
- `LibraryIndexCommandGate.disabledReason`, `resetDisabledReason`, `LibraryIndexAutoRefresh.shouldRun` e `DuplicatesStatus.trashDisabledReason` guadagnano il parametro dello spostamento in corso, **senza valore di default**: un default lascerebbe a un chiamante futuro la possibilità di dimenticarlo in silenzio.
- Il trasher non si ferma se la finestra si chiude, com'è già oggi: `endDuplicateTrashing()` sta nello stesso `MainActor.run` che pubblica l'esito, e `run` non lancia mai.

**Resta fuori, dichiarato**: `RestoreEngine` (legge l'SSD e scrive in una cartella del Mac) e il campione d'integrità (sola lettura) non consultano il gate. Durante uno spostamento possono trovare file spariti e contarli come problemi; non possono perdere niente.

**Da decidere con Enrico (domanda 1):** con la lettura dell'elenco fuori dal main, un backup potrà partire *mentre* l'elenco si aggiorna — oggi lo impedisce il bug. `LibraryIndexCommandGate` vieta già il verso opposto, con il motivo scritto («i file che vengono scritti proprio ora risulterebbero illeggibili»). Non è un rischio per le foto (l'elenco è una cache, ADR-0002, e l'import rilegge sempre, ADR-0003), ma è l'esatto caso che quel gate voleva evitare.

### D5 — I sette warning di `Sendable` rimasti

- `[weak self]` catturato in `await MainActor.run { guard let self … }` (tre siti): si ricattura nella closure interna, `await MainActor.run { [weak self] in … }`. Verificato che toglie il warning senza cambiare semantica.
- `alertSink` di `LibraryIndexCard` (quattro siti): la proprietà calcolata diventa un metodo `postAlert(_:)` con lo stesso corpo (il rinvio di un giro di run loop è voluto e documentato, e resta), e i call site passano una closure letterale `{ postAlert($0) }`. Riprodotto: il warning nasce dal valore-funzione che cattura la `@Binding` di un tipo non `Sendable` (`SimpleAlert` contiene una closure); la closure letterale scritta nel contesto MainActor del bottone è invece inferita `Sendable`. `typealias AlertSink` **non cambia**: verificato che non serve.

### D6 — La difesa contro la regressione: tre strati, ognuno con il proprio limite scritto

1. **Test che falliscono se il lavoro torna sul main thread** (file nuovo `MainThreadIsolationTests.swift`). Tecnica: il test lancia il lavoro in un `Task.detached` esattamente come fa il codice di produzione e poi **tiene occupato il main thread** aspettando un `DispatchSemaphore` con un timeout. Se il lavoro ha bisogno del main non può finire, e il test **scade e diventa rosso** invece di bloccarsi per sempre. È deterministico: non dipende da una corsa, perché il main è occupato dal test per costruzione. Un test di controllo usa una funzione volutamente `@MainActor` e si aspetta **il timeout**: senza, un test che passa sempre per un difetto dell'impalcatura sarebbe indistinguibile da uno che funziona («un test può codificare il bug invece di trovarlo»). Copre `scan`, `count()`, `duplicateGroups()`, `DuplicateBatch(groups:)`, `DuplicateTrasher.run`. **Limite**: verifica l'isolamento dei tipi, non la forma dei call site: un futuro `await MainActor.run { idx.scan(...) }` scritto in `BackupRunner` non lo prenderebbe. Per quello resta la verifica empirica.
2. **`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` sul target app, solo in Debug.** Misurato: rende la build rossa su ogni sito di classe A, cioè su esattamente la classe che rallenta. Solo Debug perché Release è la configurazione dell'archivio di `Script/release.sh`: un warning di deprecazione introdotto da un Xcode futuro non deve poter bloccare un rilascio. **Limite**: non copre la classe F (misurato), e non vede i casi B e D, che non producono warning affatto. **Costo da accettare**: il primo aggiornamento di Xcode che introduce un warning nuovo rende rossa la build Debug finché qualcuno non lo corregge.
3. **Una regola scritta in `Docs/CLAUDE.md`**: una build con anche un solo warning che contiene `actor-isolated` non è verde; e chi scrive un tipo nuovo che gira fuori dal main lo annota `nonisolated` con la riga sul perché è sicuro.

Scartati: un controllo per gruppo di diagnostici (`-Werror ActorIsolatedCall`), perché misurato inefficace in modalità Swift 5; un `dispatchPrecondition(.notOnQueue(.main))` dentro `scan`, perché i test esistenti chiamano `scan` dal main thread in modo sincrono e diventerebbero tutti crash; un hook di Claude che legge i warning, perché proteggerebbe solo le sessioni degli agenti e non le build di Xcode.

## Cosa NON cambia

- **Regola assoluta invariata.** Nessuna riga nuova chiama `removeItem`, `trashItem`, `copyItem`, `moveItem` o fa richieste S3. `DuplicateTrasher.run` fa le stesse cose nello stesso ordine: cambia **il thread** su cui gira, non cosa fa. Zero overwrite e zero delete (con l'unica porta di ADR-0005) restano identici.
- Nessuno schema SQLite, nessun formato su disco, nessuna chiave `UserDefaults`, nessuna stringa esistente.
- `FileSyncer` e `S3Syncer` si comportano identici; cambia solo come è custodito il loro flag di interruzione.
- `BackupRunner` resta `@MainActor`; `AlertSink` resta com'è.

## Test

Baseline: **da misurare** sul `main` di partenza, non da copiare. Oggi `Docs/CLAUDE.md` dice 568 e altre note 564; un conteggio statico delle `func test` dà 568, ma vale solo il totale nel log di `xcodebuild test`.

- `MainThreadIsolationTests.swift` (nuovo, 4 punti in `project.pbxproj`): 6 test — 5 sui siti di classe A, 1 di controllo. **Scritti prima delle correzioni e rossi sul codice di oggi** (per timeout), è la prova che misurano il bug.
- `CancelFlag`: 2 test (attraversamento fra thread; `reset()`).
- Gate di D4: `JobStartGate` e il parametro nuovo nei gate esistenti, circa 9 test; le 21 chiamate esistenti dei gate nei test vanno aggiornate con il parametro esplicito.
- `FileSyncer`: 1 test («dopo `cancel()`, un nuovo `sync` copia di nuovo»), perché oggi nessun test chiama `cancel()` su `FileSyncer` e il `reset()` resterebbe scoperto.
- Nessun test esistente cambia asserzioni.

**Non coperto, dichiarato:** i call site in `BackupRunner`/`DuplicatesView` (SwiftUI e bookmark veri); che il main thread resti libero durante un lavoro reale. Li copre la verifica empirica.

## Verifica empirica sull'app reale (obbligatoria, con Enrico)

Criterio: **durante il lavoro di fondo il main thread del processo sta fermo nel run loop** — le prime righe del suo albero di chiamate finiscono in `mach_msg2_trap` sotto `__CFRunLoopServiceMachPort` — **e** un altro thread mostra `LibraryIndexer.scan`. La seconda metà è il controllo positivo: senza, «main libero» potrebbe voler dire «la lettura non è mai partita». Procedura esatta nel piano, Task 9. Si ripete il MAC→SSD con l'aggiornamento automatico dell'elenco acceso, si campiona con `sample <pid> 4` ripetuto per tutta la durata della lettura, si prova «Interrompi» e si apre il pannello Doppioni campionando anche lì. Lo spostamento vero nel Cestino **solo se Enrico decide di farlo**, su un blocco piccolo.

## Verifiche

Risultati misurati a fine piano (Task 8 e Task 9), registrati qui come richiesto dal Task 8 Step 4 e dal Task 10.

### Task 8 — gate di compilazione e mutation testing complessivo

- **Build pulita + suite con `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` in Debug**: **587 test, 0 fallimenti, 0 warning di isolamento.** Baseline misurata a inizio piano (Task 1): **568**.
- **Mutanti** (rimozione di `nonisolated`, su copia scratchpad):

| Mutante | Build con gate | Test senza gate |
| :--- | :--- | :--- |
| `LibraryIndexStore` senza `nonisolated` | **rossa** (exit 65) | `testStoreCount_…`, `testDuplicateGroups_…` rossi per timeout |
| `LibraryIndexer` senza `nonisolated` | **rossa** | `testScan_…` rosso per timeout |
| `DuplicateBatch` senza `nonisolated` | **rossa** | `testDuplicateBatch_…` rosso per timeout |
| `DuplicateTrasher` senza `nonisolated` | **rossa** | `testTrasherRun_…` rosso per timeout |
| `sha256(of:)` senza `nonisolated` | **verde con warning** (classe F, atteso) | nessuno — equivalente dichiarato: lo prende solo la regola sui warning |
| copia non mutata (controllo) | verde | nessun fallimento |

  Il mutante di controllo del harness (`await MainActor.run { }` tolto dal test di controllo) **non è stato eseguito separatamente**: i quattro fallimenti per timeout sopra dimostrano comunque che il harness rileva davvero il lavoro rimasto sul main.
- **Correzione al piano**: l'ID di build config indicato nel Task 8 Step 1 (`695F43402EB019B400509478`) è quello di livello **progetto**; il flag `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` è stato messo correttamente nella configurazione Debug del **target app** (`695F43432EB019B400509478`).

### Task 9 — verifica empirica sull'app reale, con Enrico (2026-09-19)

App Debug compilata dal branch, `sample <pid> 4` ripetuto ogni ~5 s, Mac → SSD reale con Enrico, 18.399 file, 0 copiati.

- **Aggiornamento dell'elenco, 11:09:59 → 11:11:44 (~1'45")**: `LibraryIndexer.scan` presente in 17-32 campioni per istantanea su un thread di fondo, **0 volte sul main thread**; main thread idle (`__CFRunLoopServiceMachPort`) al 96-100% in tutte le istantanee. **Prima del fix**: beachball 01:15:59 → 01:22:10 (~6 minuti), main al 100% dentro `scan`.
- **`JobStartGate` verificato dal vivo**: premendo di nuovo Mac → SSD durante l'aggiornamento compare l'alert «Meglio non farlo adesso — L'app sta leggendo le foto sull'SSD per aggiornare l'elenco…» e il job non parte, coerente con la risposta (a) alla domanda 1.
  - **Cambio di UX richiesto da Enrico, non implementato qui**: l'aggiornamento dell'elenco diventerà "passo 2 di 2" del backup invece di un job separato con questo gate — lavoro pianificato a parte, citato come seguito in `Docs/ROADMAP.md`, non in questa spec/piano.
- **Non provati dal vivo, verifiche ancora aperte**: «Interrompi» durante lo scan (Task 9 Step 5) e lo smontaggio a metà scan (Task 9 Step 10). Dichiarato esplicitamente, non dedotto.
- **Osservazione nuova, fuori da quanto previsto dalla spec**: durante la fase di copia/scan del backup (11:09:29 → 11:09:53, ~575 file/s) il main thread risultava occupato ~100% in ridisegno SwiftUI/CoreAnimation (flush transazioni, `NSHostingView`) — **non bloccato** (eventi processati regolarmente), probabilmente per un eccesso di aggiornamenti di progresso pubblicati per-file. Non è un sintomo di BUG-7 (nessun salto di isolamento coinvolto): registrata in `Docs/ROADMAP.md` come punto aperto a priorità bassa (throttling degli aggiornamenti UI), insieme ai cinque punti «Fuori scope» sotto.

## Fuori scope — trovati lavorando a questa spec, da decidere a parte

Nessuno di questi produce un warning, ed è per questo che la regola «zero warning» non li chiude:

1. **Upload verso Cubbit, probabilmente in parte sul main (non misurato).** `upload()`/`multipart()` sono metodi `async` di `S3Syncer`, che è `@MainActor`: la loro parte sincrona — `Data(contentsOf:)` fino a 64 MB per file e lo SHA256 del corpo per la firma — gira sul main (caso D). Scatti, non beachball di minuti. Da misurare con `sample` durante un SSD→Cubbit prima di decidere.
2. **Campione d'integrità sul main (non misurato).** `ReviewEngine.runIntegritySample` è `async` e `@MainActor`: enumerazione dei volumi e 60 SHA256 sul main. Su un file grande (gli zip da 50 GB) sarebbero minuti.
3. **«Annulla l'ultimo spostamento» sul main**: `TrashManifestStore.restore` chiamata in modo sincrono dalla view (fino a 2.000 `moveItem`). Percorso distruttivo-adiacente: va spostato con la stessa cura di D4, non di passaggio.
4. **Apertura di SQLite sul main**, nel getter `lazy` di `libraryIndexStore` (rimandata di un giro di run loop, non spostata).
5. **Lavoro sincrono di minuti nel pool cooperativo**: `Task.detached` esegue `scan` e `trasher.run` su un thread del pool di Swift Concurrency (tanti thread quanti core) e lo tiene occupato per minuti. Con uno o due lavori così non si vede niente; `FileSyncer` usa invece `DispatchQueue.global`, che è la forma raccomandata per I/O bloccante lungo. Accettato qui per non cambiare i call site.
6. **Swift 6 / controllo `complete`**: questo lavoro toglie una parte dei 160 errori, non tutti.

## Rischi

1. **Concorrenza nuova e reale.** Scansione, caricamento del pannello e spostamento nel Cestino gireranno per la prima volta davvero in parallelo alla UI. Tutto ciò che condividono passa da `LibraryIndexStore` (coda seriale) o `TrashManifestStore` (lock), ed è l'uso per cui erano stati scritti — ma la combinazione non è mai stata eseguita sui volumi veri. Mitigazione: D4, verifica empirica.
2. **«Interrompi» e l'arresto allo smontaggio funzioneranno per la prima volta durante una lettura reale.** Sono testati a livello di `scan`, mai visti dall'app. La verifica li prova.
3. **Un `@unchecked Sendable` è una promessa, non un controllo.** Il compilatore smette di verificare quei tipi: se domani qualcuno aggiunge una `var` a `DuplicateTrasher` senza lock, niente lo segnala. Mitigazione: la riga sul perché è sicuro accanto a ogni annotazione, che la review deve rileggere.
4. **Gate di compilazione e aggiornamenti di Xcode** (D6, punto 2).
5. **Il bug del 2 settembre ritorna visibile?** No: il batch resta calcolato una volta sola; ora anche fuori dal main.
6. **Conflitto con il piano «volume-space-indicator» (bozza dello stesso giorno)**: tocca `S3Syncer` e si è prenotato ADR-0006. Questo lavoro è un bug fix e dovrebbe entrare prima; il suo ADR prende il primo numero libero al momento della scrittura.

## Bozza di ADR (da scrivere in `Docs/adr/` solo dopo l'approvazione, Task 0 del piano)

**Titolo:** `NNNN-isolamento-mainactor-di-default-e-lavoro-di-fondo-nonisolated.md`

**Contesto.** Il target compila con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` e Swift 5. Ogni tipo non annotato è `@MainActor`; un suo metodo sincrono chiamato da un `Task.detached` salta sul main thread con un semplice warning. È successo alla lettura dell'elenco delle foto (6 minuti di beachball dopo ogni MAC→SSD, misurato il 2026-09-19), al caricamento del pannello Doppioni e allo spostamento nel Cestino, rendendo inutilizzabile anche «Interrompi».

**Opzioni valutate.** (A) tenere il default e annotare `nonisolated` i tipi di fondo; (B) default `nonisolated` — 10 warning invece di 29, ma toglie la protezione a tutti gli `ObservableObject` non annotati e trasforma salti che oggi proteggono per caso in data race che il compilatore Swift 5 non segnala; (C) Swift 6 — 160 errori, e crash a runtime sui casi oggi silenziosi; (D) `actor` per store e scanner — tutto `async`, incompatibile con la chiamata sincrona dalla coda di `FileSyncer`.

**Decisione e motivo.** (A). Il default protegge ciò che è UI senza che nessuno se ne ricordi; il lavoro di fondo si dichiara, tipo per tipo, con accanto la riga che spiega perché è thread-safe. Difesa: test che tengono occupato il main thread e scadono se il lavoro ne ha bisogno, `SWIFT_TREAT_WARNINGS_AS_ERRORS` in Debug. **Cosa si accetta di perdere**: i `@unchecked Sendable` sono promesse non verificate dal compilatore; il gate non vede i casi senza warning (una closure di `DispatchQueue` che chiama codice `@MainActor`, un `async nonisolated` chiamato dal main); un nuovo warning di un Xcode futuro rompe la build Debug. **Per riaprire la decisione** serve un argomento nuovo: per esempio il passaggio a Swift 6, dove il compilatore farebbe da sé il lavoro di questi test.

**Conseguenze.** Chi scrive un tipo che gira fuori dal main lo annota `nonisolated`; chi rende `async` una funzione di fondo usa `@concurrent`, altrimenti con `NonisolatedNonsendingByDefault` gira sul thread del chiamante. Una build con un warning `actor-isolated` non è verde. Lo spostamento nel Cestino è ora visibile a job e letture (`isTrashingDuplicates`): la mutua esclusione che prima garantiva il bug la garantisce il codice.

## Domande aperte per Enrico — RISPOSTE (2026-09-19)

1. **Backup mentre l'elenco si sta aggiornando.** Risposta: **(a)**. Il backup non parte e l'app spiega perché, con un messaggio chiaro per un utente non tecnico (niente gergo — niente "indice", "hash", "scansione"), con «Interrompi» a portata di mano. È lo stesso comportamento che l'app ha già nel verso opposto. Costo accettato: dopo ogni MAC→SSD, finché l'elenco si aggiorna, gli altri backup aspettano — oggi quella lettura dura circa 6 minuti, fuori dal main thread la durata va rimisurata (Task 9).
2. **Il gate di compilazione in Debug** (D6, punto 2). Risposta: **sì**, sapendo che un aggiornamento di Xcode potrà renderlo rosso finché non si corregge.
3. **I cinque punti «fuori scope»**. Risposta: **non si implementano**. Non si aprono ticket in `Docs/superpowers/tickets/`: si registrano come punti aperti in `Docs/ROADMAP.md`, con le evidenze già raccolte in questa spec (sezione «Fuori scope» sopra), da verificare in futuro.

## Fonti

- Misure e prototipi di questa spec: scratchpad della sessione del 2026-09-19 (build log, esperimenti A-F, copia usa-e-getta).
- SE-0466 *Control default actor isolation inference*; SE-0461 *Run nonisolated async functions on the caller's actor by default* (`NonisolatedNonsendingByDefault`, `@concurrent`); SE-0434 *Usability of global-actor-isolated types*.
