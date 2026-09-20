# I punti dove l'interfaccia può ancora bloccarsi — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: IMPLEMENTATO (2026-09-20).** Approvato da Enrico con le tre risposte alla §8 della spec, tutte allineate alla raccomandazione (D1 = registro marcato, conferma sì, ~10 aggiornamenti/s): nessuna riscrittura dei Task 6/9/10 è stata necessaria. Tasks 0-10 eseguiti dall'Implementer nella sessione del 2026-09-20 (baseline 679 → finale 756 test, 0 warning). Aggiunta rispetto allo scope originale: ROADMAP #33 (campione d'integrità fuori dal main), richiesta esplicitamente da Enrico nello stesso messaggio di approvazione — vedi Docs/CLAUDE.md e `.claude/rules/architecture.md` per i dettagli. Task 12 (verifiche manuali) resta da fare con Enrico e l'SSD vero.

**Goal:** «Annulla l'ultimo spostamento» gira fuori dal main, con progresso, «Interrompi», `st_dev` a ogni fallimento, registro che ricorda cosa è tornato a posto e mutua esclusione scritta in entrambi i versi (#34). Il progresso della copia arriva alla UI al massimo ~10 volte al secondo, sempre con l'ultimo valore (#37). Lo spazio libero prima di un job si legge fuori dal main con `VolumeCapacityReader` (#39).

**Architecture:** tre tipi nuovi `nonisolated` (`ProgressThrottle`, `TrashRestorer`) più logica pura (`FreeSpaceCheck`, `TrashRestoreStatus`, `DuplicatesStatus.undoDisabledReason`). Il registro guadagna un campo (`restoredAt`). `BackupRunner` guadagna `isRestoringFromTrash` e l'orchestrazione dell'annullamento. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` resta.

**Tech Stack:** Swift 5.x, isolamento MainActor di default, *Approachable Concurrency*, SwiftUI, XCTest. Nessuna dipendenza nuova.

**Baseline:** **misurala** (Task 1). `Docs/CLAUDE.md` riporta 617 su `main` e 670 sul branch dell'indicatore di spazio, e `main` oggi contiene lavoro successivo (#38, #40): non copiare nessuno dei due. Il target di test **non è file-system-synchronized**: ogni file di test nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Verifica sempre il **totale** nella riga `Executed N tests`, mai il solo `** TEST SUCCEEDED **`.

| Task | Punto | Cosa | Test nuovi (ordine di grandezza) |
| :--- | :--- | :--- | :--- |
| 0 | — | ADR-0009 (#34), ADR-0010 (#37), nota in ADR-0008 (#39) | — |
| 1 | — | baseline | — |
| 2 | #37/#34 | `ProgressThrottle` | `ProgressThrottleTests` ~7, isolamento +1 |
| 3 | #34 | registro: `restoredAt`, `markRestored`, `pendingInLastBatch`, `restorableSummary` | `TrashManifestTests` +6, isolamento +1 |
| 4 | #34 | `TrashRestorer`, rimozione di `TrashManifestStore.restore` | `TrashRestorerTests` ~18, isolamento +1 |
| 5 | #34 | mutua esclusione: `isRestoringFromTrash` nei gate | +~10 nei file esistenti |
| 6 | #34 | testi: `TrashRestoreStatus`, `undoDisabledReason` | `TrashRestoreStatusTests` ~12 |
| 7 | #34 | orchestrazione nel runner + `DuplicatesView` | nessuno (dichiarato) |
| 8 | #37 | `FileSyncer` diradato alla fonte | `FileSyncerProgressThrottleTests` ~3 |
| 9 | #39 | `FreeSpaceCheck` + lettura fuori dal main | `FreeSpaceCheckTests` ~8, isolamento +1 |
| 10 | — | mutation testing (copia nello scratchpad) | — |
| 11 | — | documentazione | — |
| 12 | — | verifiche manuali con Enrico; eventuale passo condizionato di #37 | — |

`#34` è la priorità: viene prima di `#37`/`#39`. `ProgressThrottle` viene per primo solo perché `#34` lo usa.

## Comandi di build e test

Sempre con un `derivedDataPath` nello scratchpad della sessione (`$SP`), **mai** quello di default: Enrico usa la sua build.

```bash
SP=<scratchpad della sessione>
# build pulita (per i warning serve pulita: un'incrementale non ristampa i warning dei file non ricompilati)
rm -rf $SP/dd && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l     # atteso 0, sempre
# suite completa
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests" $SP/test.log | tail -1
# singola classe
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai con il numero di riga.** `ContentView.swift` ha ~12.500 righe; i numeri citati nella spec valgono solo per `230097d`.
2. **Ogni task dichiara il mutante che deve morire.** Si verifica nel Task 10, su una copia nello scratchpad. Un mutante che sopravvive va dichiarato equivalente e spiegato, mai nascosto.
3. **Ogni `nonisolated` su una classe con stato porta accanto la riga che dice perché è sicura** (quale lock o quale confinamento custodisce quale proprietà). `@unchecked Sendable` senza quella riga è un errore di review.
4. **Zero warning.** Un warning nuovo, di qualunque tipo, in Debug è una build rossa (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). Se compare un warning di isolamento in un punto che il piano non prevede, **fermati e rimandalo all'Architect** invece di annotare `nonisolated` per tentativi.
5. **Regola assoluta.** Nessun diff aggiunge `removeItem`, `trashItem`, `copyItem` o richieste S3 nel codice dell'app. L'unico `moveItem` su file foto resta quello del ripristino dal Cestino, che **si sposta** da `TrashManifestStore.restore` a `TrashRestorer.run` (Task 4), non si moltiplica. `createDirectory` resta dov'è (stesso ripristino). `DuplicateTrasher.run` cambia **una sola riga** (la chiamata di ripristino nel ramo `keeperVanished`, Task 4).
6. **Asserzioni esistenti.** Aggiornare la firma di una chiamata in un test esistente è ammesso; cambiare cosa asserisce **no**, con una sola eccezione dichiarata dalla spec (§2.4): `testRestoringTwice_isNotAnError`. Ogni altra asserzione che «deve» cambiare è un segnale da rimandare all'Architect.
7. **Testi a schermo solo in tipi puri** (`TrashRestoreStatus`, `DuplicatesStatus`, `JobStartGate`, `LibraryIndexCommandGate`, `FreeSpaceCheck`), mai costruiti nella View. Niente gergo: niente «hash», «indice», «registro», «manifest», «volume», «scansione», «entry», «cache», «sha».
8. **Commit solo con build e suite verdi**, un commit per task, nel formato dei commit esistenti (messaggio in italiano, trailer di attribuzione della sessione). **Mai `git push`**.

---

### Task 0: ADR, dopo l'approvazione e prima del codice

- [x] **Step 1:** `Docs/adr/0009-l-annullamento-dello-spostamento-gira-fuori-dal-main-e-il-registro-ricorda-cosa-e-tornato.md` (verifica che 0009 sia ancora il primo numero libero). Contesto: §1 #34 della spec (costo dominato dalla rilettura, registro che non ricorda, nessun `st_dev`, mutua esclusione accidentale). Opzioni valutate: registro marcato (a un livello) / voci tolte (a più livelli) / `restore` lasciata sul main con un semplice `Task.detached` attorno (scartata: lascia le frasi false e la mutua esclusione accidentale). Decisione: quella scelta da Enrico alla domanda 1, con la conferma della domanda 2. Conseguenze: schema del registro (retrocompatibile in lettura in entrambi i versi; una versione vecchia che **riscrive** il registro perde `restoredAt`, e la riconciliazione di D3 lo recupera), rimozione di `TrashManifestStore.restore`, parametro nuovo in quattro gate.
- [x] **Step 2:** `Docs/adr/0010-il-progresso-della-copia-si-dirada-alla-fonte.md`. Opzioni: diradare in `FileSyncer` (scelta) / in `BackupRunner.publishProgress` (scartata: restano i salti sul main e nasce un valore «in attesa» da gestire in tre punti di fine job) / ogni N file (scartata: a 575 file/s e a 5 file/s serve un N diverso; il tempo no).
- [x] **Step 3:** In `Docs/adr/0008-…`, in coda, una nota datata: «2026-09-XX: `VolumeCapacityReader.read` è ora usato anche dal controllo di spazio prima dei job (#39), fuori dal main; `hasSufficientSpace` rimossa.»
- [x] **Step 4:** Commit solo documentazione.

---

### Task 1: baseline misurata

- [x] **Step 1:** `git rev-parse --short HEAD`, annotalo.
- [x] **Step 2:** Build pulita. Atteso: **0** warning. Se non è 0, **fermati** e rimanda all'Architect.
- [x] **Step 3:** Suite completa. `B` = numero in `Executed N tests`, zero fallimenti.
- [x] **Step 4:** Nessun commit.

---

### Task 2: `ProgressThrottle` (puro, `nonisolated`)

**File:** `AppBackupFoto/ContentView.swift` (accanto a `CancelFlag`), `AppBackupFotoTests/ProgressThrottleTests.swift` (nuovo, registralo nei 4 punti), `AppBackupFotoTests/MainThreadIsolationTests.swift`.

- [x] **Step 1: test prima.** `ProgressThrottleTests`:
  - `testFirstUpdate_isAlwaysEmitted`
  - `testUpdateWithinInterval_isSuppressed` (0 ns, poi 50 ms → false)
  - `testUpdateAfterInterval_isEmitted` (0, poi 100 ms esatti → true; il bordo è `>=`)
  - `testFinalUpdate_isAlwaysEmitted_evenWithinInterval`
  - `testSuppressedUpdate_doesNotMoveTheReference` (0 emesso, 60 ms soppresso, 100 ms emesso: il riferimento resta 0)
  - `testClockGoingBackwards_emitsAndResets` (1 s, poi 0,5 s → true; poi 0,55 s → false)
  - `testZeroInterval_emitsEverything`
- [x] **Step 2:** In `MainThreadIsolationTests`, `testProgressThrottle_runsWithoutTheMainThread` (stesso schema degli altri: `Task.detached`, main occupato dal semaforo).
- [x] **Step 3: implementa.**

```swift
/// Dirada gli aggiornamenti di progresso verso la UI: al massimo uno ogni `minimumIntervalNanos`,
/// e **sempre** quello finale. Nasce da una misura del 2026-09-19 (ROADMAP #37): durante un
/// MAC -> SSD con quasi tutti i file gia' presenti (~575 file/s) il main thread era al ~100%
/// in ridisegno, perche' ogni file pubblicava il proprio progresso. Il tempo e non il numero di
/// file: a 575 file/s e a 5 file/s serve la stessa cadenza a schermo.
// `nonisolated`: value type senza stato condiviso; ogni istanza vive sullo stack del thread
// che la usa (il thread di `FileSyncer.sync`, quello di `TrashRestorer.run`).
nonisolated struct ProgressThrottle {
    static let defaultMinimumIntervalNanos: UInt64 = 100_000_000
    let minimumIntervalNanos: UInt64
    private var lastEmitNanos: UInt64?

    init(minimumIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos) {
        self.minimumIntervalNanos = minimumIntervalNanos
    }

    mutating func shouldEmit(nowNanos: UInt64, isFinal: Bool) -> Bool {
        guard !isFinal, let last = lastEmitNanos, nowNanos >= last else {
            lastEmitNanos = nowNanos
            return true
        }
        guard nowNanos - last >= minimumIntervalNanos else { return false }
        lastEmitNanos = nowNanos
        return true
    }
}
```

- [x] **Step 4:** build (0 warning) + suite: `B + 8`.
- [x] **Mutante che deve morire:** `>=` → `>` sul bordo (`testUpdateAfterInterval_isEmitted`); togliere `!isFinal` (`testFinalUpdate_…`); aggiornare `lastEmitNanos` anche quando si sopprime (`testSuppressedUpdate_…`); togliere `nonisolated` (build rossa se usato da tipo `nonisolated`; qui il test di isolamento).
- [x] **Step 5:** Commit.

---

### Task 3: il registro ricorda cosa è tornato a posto

**File:** `ContentView.swift` (`TrashedItem`, `TrashManifestStore`, nuovo `RestorableBatchSummary`), `AppBackupFotoTests/TrashManifestTests.swift`, `MainThreadIsolationTests.swift`.

- [x] **Step 1: test prima** (in `TrashManifestTests`):
  - `testRecordWrittenByTheCurrentVersion_decodesWithoutRestoredAt` — un JSON scritto **a mano** con la forma di oggi (sette chiavi, nessun `restoredAt`) si decodifica con `restoredAt == nil`. Scrivi il JSON letterale nel test, non generarlo col tipo nuovo: altrimenti il test prova il tipo nuovo contro se stesso.
  - `testMarkRestored_isOnDiskImmediately` — `record`, `markRestored`, riapertura **da zero**: la voce ha `restoredAt != nil`.
  - `testPendingInLastBatch_excludesRestoredItems`
  - `testMarkRestored_matchesByIdentity_notByOriginalPathAlone` — due blocchi con lo stesso `originalDisplayPath` (lo stesso file cestinato, rimesso, ricestinato): marcare la voce del blocco nuovo non tocca quella del vecchio.
  - `testRestorableSummary_isNilWhenTheLastBatchIsFullyRestored` e `…_countsOnlyPendingItems`
  - `testMarkRestored_ignoresItemsWithEmptyTrashedPath`
- [x] **Step 2:** `testRestorableSummary_runsWithoutTheMainThread` in `MainThreadIsolationTests`.
- [x] **Step 3: implementa.**
  - `TrashedItem`: `var restoredAt: Date? = nil`; aggiungi `restoredAt` a `CodingKeys` e `restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)` nella `init(from:)` esistente. Aggiorna il commento della `init(from:)`: il campo è accessorio e degrada a `nil`.
  - `TrashManifestStore`: `markRestored(_:at:) throws`, `pendingInLastBatch()`, `restorableSummary()` — tutti dentro `lock.withLock`, `markRestored` con `writeUnsynchronized()` prima di tornare (stessa disciplina e stesso commento di `record`). Identità = `batchId` + `trashedPath` + `originalDisplayPath`, prima voce con `restoredAt == nil`.
  - `RestorableBatchSummary`: `nonisolated struct` con `pendingCount: Int`, `batchCount: Int`, `trashedAt: Date` (il `trashedAt` più vecchio del blocco). Nessuna riga di sicurezza: value type.
  - `lastBatch()` **resta** (usata dai test e dal Task 4 per la storia del blocco); aggiungi al suo doc-comment che «Annulla» usa `pendingInLastBatch()`.
  - Aggiorna il commento `nonisolated` di `TrashManifestStore` («`record` dal trasher, `markRestored` dal restorer, entrambi fuori dal main; ogni accesso a `manifest` dentro `lock.withLock`»).
- [x] **Step 4:** build + suite: +7.
- [x] **Mutante che deve morire:** togliere la scrittura su disco da `markRestored` (`…_isOnDiskImmediately`); matching sul solo `originalDisplayPath` (`…_matchesByIdentity…`); `decode` al posto di `decodeIfPresent` per `restoredAt` (`testRecordWrittenByTheCurrentVersion_…`).
- [x] **Step 5:** Commit.

---

### Task 4: `TrashRestorer` — il ripristino, fuori dal main, con `st_dev`

**File:** `ContentView.swift` (nuovo `TrashRestorer` accanto a `DuplicateTrasher`; `RestoreSkipReason` +2 casi; `RestoreOutcome` +4 campi; rimozione di `TrashManifestStore.restore`; una riga in `DuplicateTrasher.run`), `AppBackupFotoTests/TrashRestorerTests.swift` (nuovo, registralo), `TrashManifestTests.swift`, `DuplicateTrasherTests.swift`, `MainThreadIsolationTests.swift`.

- [x] **Step 1: test prima** (`TrashRestorerTests`, directory temporanea con `SSD/` come `libraryRoot` e il Cestino **dentro** la stessa directory temporanea, così `st_dev` coincide; `volumeIdentity` iniettata solo nei test di scollegamento):
  - riuscita: `testRestore_putsTheFileBack_andMarksIt`
  - zero-overwrite: `testOccupiedOriginal_isNeverOverwritten` (occupante con contenuto diverso: byte per byte invariato; voce `.originalPathOccupied`, non marcata, file nel Cestino intatto)
  - corsa sull'occupante: `testOccupantAppearingJustBeforeTheMove_isNeverOverwritten` (`moveFunction` che crea la destinazione e poi chiama la vera `FileManager.moveItem`: esito `.moveFailed`, occupante intatto, voce non marcata)
  - `testUnreadableTrashedFile_isNotReportedAsAltered` (`hashFunction` → `nil`, disco invariato → `.unreadableInTrash`)
  - `testAlteredTrashedFile_isNotRestored` (hash diverso → `.alteredInTrash`)
  - scollegamento, tre test, uno per punto di fallimento: `testVolumeVanished_whenTrashedFileIsMissing_stopsEverything`, `…_whenHashIsNil_…`, `…_whenMoveThrowsNoSuchFile_…` — `volumeIdentity` che cambia valore al momento giusto; asserisci `stoppedBecauseVolumeVanished`, `restored.count` onesto, `notAttempted` corretto, **nessuna** voce `missingInTrash`/`alteredInTrash`, voci non tentate **non** marcate
  - `testVolumeMissingAtStart_attemptsNothing`
  - `testVolumeChangedAfterTheReread_createsNoFolder` (la cartella intermedia dell'originale non esiste; `volumeIdentity` cambia dopo la rilettura: nessuna cartella creata, stop)
  - `testInterruption_marksOnlyWhatWasRestored_andASecondRunFinishes`
  - `testFileAlreadyBackInPlace_isReconciled_notReportedAsMissing` (file tolto dal Cestino e messo a mano al posto originale: `alreadyInPlace`, marcato, nessuno `skipped`)
  - `testFileMissingEverywhere_isMissingInTrash`
  - `testOriginalOutsideTheLibrary_isRefused` (percorso fuori dalla root e percorso con `..` che ne esce: `.outsideLibrary`, nessuna mossa)
  - `testTrashedFileOnAnotherDisk_isRefused` (`volumeIdentity` che risponde un `dev_t` diverso per il solo file nel Cestino)
  - `testProgress_isReportedOncePerItem_includingSkipped`
  - `testMissingIntermediateFolders_areRecreated` (portato da `TrashManifestTests`)
- [x] **Step 2:** `testTrashRestorerRun_runsWithoutTheMainThread` in `MainThreadIsolationTests` (funzioni iniettate che non toccano niente, `run([])` e una voce finta).
- [x] **Step 3: implementa** `TrashRestorer` seguendo **esattamente** la sequenza della spec §2.3 (passi 0-10). Scheletro:

```swift
// `nonisolated`: `run` deve girare fuori dal main thread — la rilettura di ogni foto puo'
// richiedere minuti (blocco fino a 50 GB). Solo proprieta' `let`; lo stato di `run` e' tutto
// locale. Uno alla volta: lo garantisce `BackupRunner.isRestoringFromTrash`. Il registro e'
// protetto dal proprio lock. Vedi ADR-0006, ADR-0009.
nonisolated final class TrashRestorer: @unchecked Sendable {
    init(libraryRoot: URL,
         manifest: TrashManifestStore,
         moveFunction: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
         volumeIdentity: @escaping (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         now: @escaping () -> Date = Date.init)
    func run(_ items: [TrashedItem],
             onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
             isCancelled: () -> Bool = { false }) -> RestoreOutcome
}
```

  Regole di scrittura, ciascuna con il suo commento nel codice (il **perché**, non il cosa): confinamento per componenti canoniche con `rootForms` + `relativePath(of:under:)` (stesso codice del trasher, non una seconda implementazione — se serve, estrai una funzione libera `nonisolated` condivisa); mai `NSFileNoSuchFileError` come «già fatto»; `st_dev` riletto **a ogni** fallimento e **subito prima** di `createDirectory`; `markRestored` dopo il `moveFunction` riuscito, errore di scrittura ignorato con commento (la foto è tornata; D3 la riconosce alla prossima); nessun `throw` esce da `run`.
- [x] **Step 4:** `RestoreSkipReason`: `.unreadableInTrash`, `.outsideLibrary` con `explanation` (testi della spec §2.8). Estendi `testEverySkipReason_hasItsOwnPlainExplanation` ai nuovi casi.
- [x] **Step 5: migra e rimuovi.**
  - `DuplicateTrasher.run`, ramo `keeperVanished`: `_ = manifest.restore(trashedInGroup)` → `_ = TrashRestorer(libraryRoot: libraryRoot, manifest: manifest).run(trashedInGroup)`. Nient'altro nel trasher.
  - Rimuovi `TrashManifestStore.restore(_:)`.
  - `TrashManifestTests`: i test di ripristino chiamano `TrashRestorer(libraryRoot: root, manifest: store).run(...)`; asserzioni invariate **tranne** `testRestoringTwice_isNotAnError` → la seconda `run` restituisce `alreadyInPlace.count == 1` e `skipped` vuoto (spec §2.4, unica eccezione ammessa). `testRestore_doesNotDropTheOtherBatchesFromTheRegister` resta identico (con D1 `itemCount` resta 2).
  - `DuplicateTrasherTests`: le chiamate a `manifest.restore(...)` passano a `TrashRestorer`; aggiungi a `testKeeperVanished_restoresWhatWasJustTrashed` l'asserzione che le voci risultino marcate.
- [x] **Step 6:** build (0 warning) + suite: ~+20. Controlla con `grep -n 'moveItem' ContentView.swift` che le occorrenze sui file foto siano **le stesse di prima, spostate**, non una in più.
- [x] **Mutanti che devono morire:** ciascuno dei tre controlli `st_dev` tolto (tre test di scollegamento); ricontrollo prima di `createDirectory` tolto; `markRestored` tolto; `hash == nil` → `.alteredInTrash`; guardia zero-overwrite nostra tolta (deve morire su `testOccupiedOriginal_…`: l'esito diventa `.moveFailed`, non `.originalPathOccupied`); confinamento tolto; `nonisolated` tolto (build rossa).
- [x] **Step 7:** Commit.

---

### Task 5: mutua esclusione in entrambi i versi

**File:** `ContentView.swift` (`BackupRunner`, `JobStartGate`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`, nuovo `DuplicatesStatus.undoDisabledReason`), test esistenti `JobStartGateTests`, `DuplicatesStatusTests`, `LibraryIndexStatusTests`.

- [x] **Step 1: test prima.**
  - `JobStartGateTests`: `testRestoringInProgress_blocksWithAReason`, `testRestoringReason_differsFromTheOthers`, `testTrashingAndRestoring_trashingWins` (impossibile a runtime, ma la precedenza va fissata), estendi `testReasonsCarryNoJargon` ai casi nuovi.
  - `LibraryIndexStatusTests`: `testCommandGate_restoringInProgress_disablesWithAReason`.
  - `DuplicatesStatusTests`: `testTrashDisabled_whileRestoring`; per `undoDisabledReason(ssdMounted:isRunning:isIndexing:isTrashingDuplicates:isRestoringFromTrash:summary:hasEverTrashed:)` un caso per ramo + `testUndoDisabled_everyBranchIsReachedByItsCase` (lista di casi condivisa, stile `LibraryIndexStatus`), + `nil` quando tutto è a posto e ci sono voci da rimettere.
- [x] **Step 2: implementa.**
  - `BackupRunner`: `@Published private(set) var isRestoringFromTrash = false`; `beginTrashRestore() -> SimpleAlert?` (`guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing`, poi imposta); `endTrashRestore()`. `beginDuplicateTrashing()` aggiunge `!isRestoringFromTrash` alla propria guardia. Doc-comment sul modello di quelli di `isTrashingDuplicates`.
  - Parametro `isRestoringFromTrash: Bool` **senza default** in `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`. Messaggi dalla spec §2.8. Precedenza: spostamento > annullamento > lettura.
  - **Non** toccare `resetDisabledReason` né `BackupListStep.shouldRun` (spec §2.5, con motivo: scrivilo in una riga di commento accanto a `JobStartGate`, così nessuno lo «completa» per simmetria).
  - Aggiorna tutti i call site che il compilatore segnala (app e test) passando il valore vero (`isRestoringFromTrash` del runner) nell'app e `false` nei test esistenti.
- [x] **Step 3:** build + suite: ~+10. Rileggi il diff dei test esistenti: **solo** argomenti aggiunti, nessuna asserzione toccata.
- [x] **Mutante che deve morire:** `isRestoringFromTrash` ignorato in `JobStartGate` (`testRestoringInProgress_blocks…`); `beginDuplicateTrashing` senza `!isRestoringFromTrash` (non raggiungibile da test unitario: `BackupRunner` è MainActor e non costruibile senza bookmark — dichiaralo **non coperto** nel commit e nella documentazione, la difesa resta `trashDisabledReason`, che è coperta).
- [x] **Step 4:** Commit.

---

### Task 6: testi dell'annullamento (`TrashRestoreStatus`)

**File:** `ContentView.swift` (nuovo enum puro accanto a `DuplicatesStatus`), `AppBackupFotoTests/TrashRestoreStatusTests.swift` (nuovo, registralo).

- [x] **Step 1: test prima.** Per `confirmation(summary:)` (titolo + messaggio con numero e data), `progressLine(done:total:)`, `stoppingLine`, `outcomeLines(_ outcome: RestoreOutcome)`:
  - una riga per ciascun caso della spec §2.8 (tutto, già a posto, interrotto, scollegamento, saltate per motivo raggruppate con il conteggio)
  - `testReappearsInDuplicatesLine_presentIffSomethingCameBack`
  - `testInterruptedAndVanished_neverSayEverythingIsFine` (con `interrupted`/`stoppedBecauseVolumeVanished` non compare mai la riga «tutte tornate»)
  - plurali (1 foto / 2 foto; «è tornata»/«sono tornate»)
  - anti-gergo su tutte le righe, dalla stessa lista di casi (regola 7)
  - `id` unici e stabili fra due chiamate
  - data formattata con `Locale(identifier: "it_IT")` e fuso fissato nel test
- [x] **Step 2: implementa** con i testi della spec §2.8 (se Enrico ha chiesto modifiche ai testi rispondendo alla spec, valgono le sue).
- [x] **Step 3:** build + suite: ~+12.
- [x] **Mutante che deve morire:** la riga «le altre N sono ancora nel Cestino» con N calcolato come `total - restored` invece che dalle voci non tornate (deve contare anche `skipped`: scrivi il test con un caso misto).
- [x] **Step 4:** Commit.

---

### Task 7: orchestrazione — runner e finestra Doppioni

**File:** `ContentView.swift` (`BackupRunner`, `DuplicatesView`). **Nessun test unitario** (SwiftUI e bookmark veri): dichiaralo nel doc-comment di `DuplicatesView`, sul modello della dichiarazione già presente.

- [x] **Step 1: `BackupRunner`.**
  - Stato pubblicato: `trashRestoreProgress: (done: Int, total: Int)?` (una `struct` `Equatable` se la tupla crea attrito con `@Published`), `trashRestoreStopRequested: Bool`, `lastTrashRestoreOutcome: RestoreOutcome?`, `restorableBatch: RestorableBatchSummary?`. `CancelFlag` privato.
  - `refreshRestorableBatch()` — `Task.detached(priority: .utility) { manifest.restorableSummary() }` poi `MainActor.run` che assegna **solo se cambiato** (lezione del 2026-09-03: non ripubblicare lo stesso valore).
  - `startTrashRestore(onAlert: (SimpleAlert) -> Void)` — `beginTrashRestore()` (rifiuto → `onAlert`, **mai** `pendingAlert` del runner: regola `AlertSink`); poi store/root SSD (`BookmarkManager.shared.urls[.ssd]`) o, se mancano, `endTrashRestore()` + avviso; poi un **unico** `Task.detached(priority: .utility)` che legge `pendingInLastBatch()`, costruisce `TrashRestorer` e chiama `run` con `onProgress` diradato da un `ProgressThrottle` locale al task (pubblica con `Task { @MainActor in … }`, sempre anche l'ultimo) e `isCancelled: { flag.isCancelled }`; alla fine **un solo** `MainActor.run` che chiama `endTrashRestore()`, azzera progresso e richiesta di stop, pubblica l'esito, e chiama `refreshRestorableBatch()`. Nessun `return` fra `beginTrashRestore()` riuscito e il `Task.detached`, come in `startTrashing`.
  - `stopTrashRestore()` — `flag.cancel()`, `trashRestoreStopRequested = true`; secondo clic ignorato.
  - A inizio di uno spostamento nel Cestino (`DuplicatesView.startTrashing`, dopo `beginDuplicateTrashing` riuscito) azzera `lastTrashRestoreOutcome`; a fine spostamento chiama `refreshRestorableBatch()`.
- [x] **Step 2: `DuplicatesView`.**
  - Rimuovi `hasRestorableBatch` e `undoLastBatch()`.
  - `.task`: oltre a `loadGroups()`, `runner.refreshRestorableBatch()`.
  - Bottone «Annulla l'ultimo spostamento»: `.disabled(undoDisabledReasonNow != nil)`, con il motivo mostrato come `Label` sotto (stesso stile di `trashDisabledReasonNow`); al clic apre l'alert di conferma (Task 6), il cui bottone chiama `runner.startTrashRestore(onAlert: { pendingAlert = $0 })`.
  - Se `runner.isRestoringFromTrash`: barra con `TrashRestoreStatus.progressLine` e «Interrompi» (→ `stopTrashRestore()`), che diventa `stoppingLine` disattivato se `trashRestoreStopRequested`.
  - Righe di `TrashRestoreStatus.outcomeLines(runner.lastTrashRestoreOutcome)` sotto quelle dell'esito dello spostamento.
  - `.onChange(of: runner.isRestoringFromTrash)` → quando torna `false`, `loadGroups()`.
- [x] **Step 3:** build (0 warning) + suite: invariata rispetto al Task 6. Avvia l'app una volta e apri la finestra Doppioni **senza premere niente** (niente SSD necessario): la finestra si apre, il bottone mostra un motivo coerente.
- [x] **Step 4: revisione a mano, checklist.** (a) Ogni `begin…()` riuscito ha un `end…()` su ogni percorso; (b) nessun accesso a `trashManifestStore` nel `body`; (c) nessuna stringa nuova costruita nella View; (d) nessun `runner.pendingAlert` dalla finestra Doppioni; (e) il `Task.detached` non cattura niente di `@MainActor` se non attraverso `MainActor.run`/`Task { @MainActor }` (se il compilatore non si lamenta, verifica comunque a occhio: il caso B è silenzioso).
- [x] **Step 5:** Commit.

---

### Task 8: `FileSyncer` diradato alla fonte (#37)

**File:** `ContentView.swift` (`FileSyncer.init`, `sync`, `syncDir`, `syncFile`), `AppBackupFotoTests/FileSyncerProgressThrottleTests.swift` (nuovo, registralo).

- [x] **Step 1: test prima.**
  - `testLastProgress_equalsTheReturnedResult` — 50 file in una directory temporanea, `FileSyncer(progressIntervalNanos: 3_600_000_000_000)`, raccogli gli snapshot in un array **sul main**; dopo `sync`, svuota la coda del main (`expectation` soddisfatta da un `DispatchQueue.main.async` accodato dopo); l'ultimo snapshot ha `done`, `total`, `copied`, `skipped`, `errors`, `hashErrors`, `copiedUnverified` uguali al risultato restituito; il numero di snapshot è ≤ 4 (quello «Trovati N file» prima della copia, il primo file, quello con `done == total`, quello finale di `sync`) — non 50.
  - `testLastProgress_afterCancel_equalsThePartialResult` — stesso setup; `isDuplicate: { url in if <è il 10° file> { syncer.cancel() }; return false }` (deterministico: nessun timer); l'ultimo snapshot è uguale al risultato parziale restituito e `done < total`.
  - `testDefaultInterval_isTheShared100ms` — `FileSyncer()` senza argomenti usa `ProgressThrottle.defaultMinimumIntervalNanos` (espone l'intervallo in sola lettura, `internal`).
- [x] **Step 2: implementa.**
  - `init(hashFunction: … , progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos)` — iniettato **solo dai test**, commento sul modello di `hashFunction`.
  - In `sync`: `var throttle = ProgressThrottle(minimumIntervalNanos: progressIntervalNanos)`; passa `progress: &throttle` a `syncDir`, e da lì a `syncFile` (parametro **senza default**, rispettando il commento già presente su quei due metodi).
  - In `syncFile`, al posto dell'emissione incondizionata finale: emetti solo se `throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds, isFinal: result.done == result.total)`.
  - In `sync`, **prima di ogni `cont.resume`** dopo l'inizio della copia (ritorno normale — che include l'interruzione — e `catch`): `let snap = result; DispatchQueue.main.async { onProgress(snap) }`. Commento: è la garanzia «sempre l'ultimo valore», non dipende da `done == total`, e il valore coincide con quello restituito, quindi arrivare dopo `finishCopyStep` non cambia niente. I due rami che già emettono prima della copia (`total == 0`, «Trovati N file») restano come sono.
  - Le righe di stato (`onStatus`) **non si toccano**.
- [x] **Step 3:** build + suite: +3. Tutti i test `FileSyncer*` esistenti verdi senza modifiche (se uno richiede un cambio di asserzione, **fermati**: significa che dipendeva da un progresso per file, e va rimandato all'Architect).
- [x] **Mutanti che devono morire:** togliere l'emissione finale in `sync` (`…_afterCancel_…`); `isFinal: false` sempre (**equivalente atteso** grazie all'emissione finale di `sync` — dichiaralo, non è un buco: le due garanzie sono volutamente ridondanti); intervallo ignorato (`≤ 4` fallisce).
- [x] **Step 4:** Commit.

---

### Task 9: spazio libero fuori dal main (#39)

**File:** `ContentView.swift` (nuovo `FreeSpaceCheck`, `BackupRunner.runMacToSSD`/`runSSDToHDD`/`runImport`, rimozione di `hasSufficientSpace`, doc-comment di `VolumeCapacityReader`), `AppBackupFotoTests/FreeSpaceCheckTests.swift` (nuovo, registralo), `MainThreadIsolationTests.swift`.

- [x] **Step 1: test prima.** `FreeSpaceCheckTests`:
  - `testExactlyEnough_isEnough` (`available == needed + margin`) e `testOneByteShort_isNotEnough`
  - `testSmallJob_usesTheMinimumMarginOf500MB`, `testLargeJob_usesFivePercent` (bordo dove 5% supera 500 MB: 10 GB)
  - `testNothingToCopy_stillRequiresTheMinimumMargin` (`bytesNeeded == 0`: comportamento di oggi, fissato)
  - `testNotAMountPoint_isNotADisk`, `testUnreadable_isUnreadable_neverEnough`
  - `testMessages_carryNoJargon` (i testi di `.notADisk`/`.unreadable` per SSD e HDD)
  - `MainThreadIsolationTests`: `testVolumeCapacityRead_runsWithoutTheMainThread` (una directory temporanea: il risultato è `.notAMountPoint`, conta solo che finisca).
- [x] **Step 2: implementa.**
  - `enum FreeSpaceCheck` (MainActor di default: puro, gira sul main) con `Verdict` e `verdict(bytesNeeded:reading:)`; il margine è **copiato da `hasSufficientSpace`** (`max(Int64(Double(bytesNeeded) * 0.05), 500_000_000)`), non riscritto. Testi di `.notADisk`/`.unreadable` come funzioni statiche con il nome del disco.
  - Nei tre job: `let reading = await Task.detached(priority: .userInitiated) { VolumeCapacityReader.read(path: path) }.value` con `path` catturato come `String`; `switch FreeSpaceCheck.verdict(...)`; `.notEnough` → **stesso alert, stesso testo** di oggi (compreso il «al massimo» dell'import); `.notADisk`/`.unreadable` → alert nuovi; in tutti i rami che bloccano, gli stessi `bm.stopAccessing(...)` di oggi.
  - Rimuovi `hasSufficientSpace`. Aggiorna il doc-comment di `VolumeCapacityReader` («chiamata dalla `probeQueue` di `VolumeMonitor` e, una volta per job, da `BackupRunner` — sempre fuori dal main») e il punto 3 della stessa lista (non esiste più `hasSufficientSpace` da citare).
- [x] **Step 3:** build + suite: ~+9.
- [x] **Mutante che deve morire:** `>=` → `>` nel confronto (`testExactlyEnough_…`); `.unreadable` trattato come `.enough` (`testUnreadable_…`); `.notAMountPoint` trattato come lettura valida (`testNotAMountPoint_…`).
- [x] **Step 4:** Commit.

---

### Task 10: mutation testing (solo su copia)

- [x] **Step 1:** `rsync -a --exclude Log/ --exclude .git/ <repo>/ $SP/mut/` e lavora **solo** lì, con un `derivedDataPath` separato.
- [x] **Step 2:** Applica uno alla volta i mutanti elencati nei Task 2-9, build + classe di test interessata; annota per ciascuno: test rosso / build rossa / sopravvissuto (con motivo di equivalenza).
- [x] **Step 3:** Riporta la tabella nel messaggio di chiusura e nella documentazione del Task 11. Nessun sopravvissuto non spiegato.

---

### Task 11: documentazione

- [x] `.claude/rules/architecture.md`: sezione del pannello Doppioni — `TrashRestorer`, `restoredAt`, `pendingInLastBatch`, riconciliazione, stato dell'annullamento nel runner, la dichiarazione «non coperto»; sezione «Isolamento MainActor di default» — `isRestoringFromTrash` accanto a `isTrashingDuplicates` (verso scritto in entrambi i sensi) e i tre nuovi tipi fuori dal main; sezione `FileSyncer` — progresso diradato alla fonte, `progressIntervalNanos` solo per i test, righe di stato non diradate; sezione `BackupRunner` — controllo di spazio con `VolumeCapacityReader` + `FreeSpaceCheck`, esiti `.notADisk`/`.unreadable`.
- [x] `Docs/ROADMAP.md`: #34, #37, #39 → ✅ con data e rimando a spec/piano; il testo originale resta sotto. #37 dice esplicitamente che il log non è stato diradato e perché. Correggi nel testo di #34 «fino a 2.000 `moveItem`» con il dato vero (blocchi da ≤500 file / ≤50 GB; il costo è la rilettura). Nuovo punto **#41** per la scoperta collaterale «lo spostamento nel Cestino perde barra e Interrompi riaprendo la finestra» (spec §9), e le altre due scoperte come note.
- [x] `Docs/CLAUDE.md`: tabella «Stato attuale» (data e riga «Test automatici» con il conteggio **misurato** e i file nuovi), riga del pannello Doppioni.
- [x] Il piano stesso: spunta i checkbox **mentre** lavori (la ROADMAP #27-A insegna cosa succede quando restano vuoti su codice già in `main`).
- [x] Commit solo documentazione.

---

### Task 12: verifiche manuali con Enrico

Richiedono Enrico e l'SSD vero: **non eseguirle in autonomia**. Elenco e criteri: spec §6, punti 1-6. **Lo scollegamento a metà annullamento non si prova sull'SSD vero** (spec §6 e §2.7).

- [ ] **Passo condizionato di #37:** se la verifica 5 mostra il main ancora saturo durante una copia con molti file nuovi, **non** implementare niente a occhio: riporta il `sample` all'Architect, che scriverà un task per raggruppare le righe di log in `publishStatus` senza perderne nessuna (spec §3.2 e §9).
