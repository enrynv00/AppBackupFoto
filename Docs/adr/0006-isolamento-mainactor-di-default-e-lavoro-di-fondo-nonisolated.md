# ADR-0006 — Isolamento MainActor di default e lavoro di fondo `nonisolated`

**Data:** 2026-09-19
**Stato:** Accettata

## Contesto

Il target `AppBackupFoto` compila con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (il default del template di Xcode 26, presente dal primo commit) e con Swift 5 in modalità *Approachable Concurrency*. Con questa impostazione, ogni tipo non annotato è implicitamente `@MainActor`. Un suo metodo sincrono chiamato da un contesto `async` non isolato — per esempio il corpo di un `Task.detached` — produce in Swift 5 **solo un warning** ("cannot be called from outside of the actor; this is an error in the Swift 6 language mode") e a runtime **un salto implicito sul main actor**: il lavoro gira comunque sul main thread, nonostante il codice sembri fuori da esso.

Il caso reale, misurato il 2026-09-19: dopo un MAC → SSD l'app va in beachball per circa 6 minuti (log di sistema: main thread muto dalle 01:15:59 alle 01:22:10; `sample` mostra il main al 100% dentro `LibraryIndexer.scan` → `NSURLDirectoryEnumerator` → `getattrlist`/`realpath`/`statfs`). La stessa causa colpisce il caricamento del pannello Doppioni (`store.duplicateGroups()`, `DuplicateBatch(groups:)`) e lo spostamento nel Cestino (`DuplicateTrasher.run`), rendendo inutilizzabile anche «Interrompi» durante quelle operazioni — il percorso a danno più alto del progetto (ADR-0005).

L'elenco completo dei 29 warning unici, la classificazione in classi A-F e le misure sui sei casi di isolamento sono in `Docs/superpowers/specs/2026-09-19-mainactor-default-isolation-fix-design.md`.

## Opzioni valutate

**A. Tenere `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, annotare `nonisolated` i tipi di fondo (scelta).** Circa 50 dichiarazioni, cambio di sola annotazione per quasi tutte (misurato su un prototipo usa-e-getta). Il compilatore da quel momento controlla i tipi di fondo, e ogni tipo che nasce nuovo resta protetto per default. Contro: bisogna ricordarsi di annotare il prossimo tipo di fondo — mitigato da un gate di compilazione (`SWIFT_TREAT_WARNINGS_AS_ERRORS` in Debug) e da test che tengono occupato il main thread.

**B. Default `nonisolated`.** Misurato: 10 warning invece di 29, a prima vista la più economica. Ma rende non isolati in blocco anche `BookmarkManager`, `VolumeMonitor`, `AuthGateManager`, `AppearanceManager`, `ImmichManager`, `ReviewEngine` — tutti `ObservableObject` con `@Published`, oggi protetti proprio dal default. I salti sul main che oggi proteggono per caso un `@Published` scritto da un `Task.detached` diventerebbero data race silenziose: in modalità Swift 5 minimale il compilatore non le segnala. Scambia un bug di prestazioni visibile con bug di correttezza invisibili.

**C. Passare a Swift 6.** Misurato: 160 errori, build rossa. I casi B esistenti (`FileSyncer`) diventerebbero crash a runtime per i controlli dinamici di isolamento. Troppo per un bug fix, anche se questo lavoro lo avvicina.

**D. `LibraryIndexStore`/`LibraryIndexer` come `actor`.** Isolamento garantito dal linguaggio, ma tutto diventerebbe `async`: `isAlreadyInLibrary` è sincrona e chiamata dalla coda di `FileSyncer`, e una `scan` di minuti bloccherebbe l'esecutore dell'actor. Lo store ha già la sua serializzazione (coda seriale), misurata e testata.

## Decisione e motivo

**Opzione A.** Il default `MainActor` protegge ciò che è UI senza che nessuno se ne debba ricordare; il lavoro di fondo si dichiara esplicitamente, tipo per tipo, con accanto la riga che spiega perché è thread-safe (quale coda o quale lock custodisce quale proprietà). Difesa in tre strati: test che lanciano il lavoro in un `Task.detached` e tengono occupato il main thread con un semaforo — se il lavoro ha bisogno del main, il test scade ed è rosso; `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` sul target app, solo in Debug; una regola scritta in `Docs/CLAUDE.md`.

**Risposte di Enrico alle domande aperte della spec (2026-09-19):**
1. Un backup avviato mentre l'elenco dell'SSD si sta aggiornando (o mentre il trasher sposta nel Cestino) **non parte**: l'app spiega perché con un messaggio chiaro, senza gergo tecnico («indice», «hash», «scansione»), con «Interrompi» a portata di mano — stesso comportamento che l'app ha già nel verso opposto (`JobStartGate`, D4).
2. Il gate di compilazione in Debug (`SWIFT_TREAT_WARNINGS_AS_ERRORS`) si attiva, sapendo che un aggiornamento di Xcode futuro potrà renderlo rosso finché qualcuno non corregge il warning nuovo.
3. I cinque punti «fuori scope» trovati lavorando a questa spec (upload S3 probabilmente in parte sul main, campione d'integrità sul main, «Annulla l'ultimo spostamento» sul main, apertura di SQLite sul main, lavoro sincrono di minuti nel pool cooperativo) **non si implementano ora**: restano registrati come punti aperti in `Docs/ROADMAP.md`, con le evidenze già raccolte nella spec, non come ticket separati.

**Cosa si accetta di perdere.** Ogni `@unchecked Sendable` è una promessa non verificata dal compilatore: se domani qualcuno aggiunge una `var` senza lock a uno di questi tipi, niente lo segnala — la riga di commento accanto a ogni annotazione è la difesa, e la review deve rileggerla. Il gate di compilazione non vede i casi senza warning (una closure di `DispatchQueue` che chiama codice `@MainActor`, un `async nonisolated` chiamato dal main). Un nuovo warning introdotto da un Xcode futuro rompe la build Debug finché non viene corretto.

**Per riaprire questa decisione** serve un argomento nuovo — per esempio il passaggio a Swift 6, dove il compilatore farebbe da sé il lavoro che oggi fanno i test di regressione.

## Conseguenze

- Chi scrive un tipo che deve girare fuori dal main lo annota `nonisolated`, con la riga sul perché è thread-safe accanto. Chi rende `async` una funzione di fondo usa `@concurrent`, altrimenti con `NonisolatedNonsendingByDefault` il lavoro gira comunque sul thread del chiamante.
- Una build con anche un solo warning che contiene `actor-isolated` non è considerata verde.
- Lo spostamento nel Cestino è ora visibile a job e letture tramite `BackupRunner.isTrashingDuplicates` e `JobStartGate`: la mutua esclusione che prima garantiva (per caso) il bug, ora la garantisce codice scritto e testato.
- `FileSyncer` e `S3Syncer` si comportano in modo identico; cambia solo come è custodito il loro flag di interruzione (`CancelFlag` condiviso).
- Nessuna funzione diventa `async`, nessun `Task.detached` cambia posto, nessuna riga di corpo di `DuplicateTrasher.run` cambia: il bug si chiude cambiando l'isolamento dei tipi chiamati, non la struttura dei chiamanti.
