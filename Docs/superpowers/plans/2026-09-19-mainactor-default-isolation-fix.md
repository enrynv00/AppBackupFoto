# Il lavoro "in background" che tornava sul main thread — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: APPROVATO da Enrico il 2026-09-19.** Spec di riferimento: `Docs/superpowers/specs/2026-09-19-mainactor-default-isolation-fix-design.md`. Risposte di Enrico alle domande aperte: 1→(a) (decide il contenuto di `JobStartGate` nel Task 4, già scritto per questo caso); 2→sì (si fa il Task 8, gate di compilazione); 3→i cinque punti fuori scope **non si implementano**: lo Step 4 del Task 10 non apre ticket, aggiorna `Docs/ROADMAP.md`.

**Goal:** La lettura dell'elenco delle foto, il caricamento del pannello Doppioni, lo spostamento nel Cestino e il conteggio all'avvio girano davvero fuori dal main thread. Zero warning di isolamento. Un test rosso e una build rossa se uno di questi torna sul main.

**Architecture:** `SWIFT_DEFAULT_ACTOR_ISOLATION` resta `MainActor`. Si annotano `nonisolated` i **tipi chiamati** dal lavoro di fondo (non si toccano i call site), ognuno con la riga che dice perché è thread-safe. I due flag di interruzione non protetti passano a un `CancelFlag` condiviso. La mutua esclusione fra spostamento nel Cestino, job e letture, che oggi garantisce il bug, la garantisce un gate scritto.

**Tech Stack:** Swift 5.x con isolamento MainActor di default e *Approachable Concurrency*, SwiftUI, XCTest. Nessuna dipendenza nuova, nessuno schema toccato.

**Baseline:** **misura** il conteggio dei test su `main` prima di iniziare (Task 1) e usalo come `B`. `Docs/CLAUDE.md` dice 568, altre note 564: non copiarne nessuno. Il target di test **non è file-system-synchronized**: il file nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Verifica sempre il **totale nel log**, mai il solo `** TEST SUCCEEDED **`.

| Componente | Cosa cambia | Test |
| :---- | :---- | :---- |
| indice e hashing (`LibraryIndexStore`, `LibraryIndexer`, `sha256*`, chiavi, esclusioni, `ImportSessionIndex`) | `nonisolated` | `MainThreadIsolationTests` (scan, count) |
| gate dello spostamento (`JobStartGate`, parametro nei gate esistenti, `BackupRunner.isTrashingDuplicates`) | nuovo | `JobStartGateTests` + test esistenti aggiornati |
| pannello Doppioni (`DuplicateBatch`, `DuplicateTrasher`, `TrashManifestStore`, tipi del registro, `CancelFlag`) | `nonisolated` | `MainThreadIsolationTests` (duplicateGroups, batch, trasher), `CancelFlag` |
| `FileSyncer`, `S3Syncer` (flag), credenziali, limitatore AIMD, buffer di Immich | `nonisolated` / `CancelFlag` | test esistenti invariati |
| `[weak self]` ×3, `postAlert` ×4 | forma della cattura | nessuno (solo warning) |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` in Debug | impostazione del target app | mutanti del Task 8 |

## Comandi di build e test

Sempre con un `derivedDataPath` nello scratchpad della sessione (`$SP`), **mai** quello di default: Enrico usa la sua build.

```bash
SP=<scratchpad della sessione>
# build (per i warning serve una build PULITA: una incrementale non ristampa i warning dei file non ricompilati)
rm -rf $SP/dd && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
# conteggio warning Swift unici (file:riga:colonna)
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l
# solo quelli di isolamento
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | grep -cE 'actor-isolated|Sendable|concurrently-executing'
# suite completa
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests" $SP/test.log | tail -1
# singola classe
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai con il numero di riga.** I numeri di riga di questo piano sono quelli del 2026-09-19 e servono solo a riconoscere i warning.
2. **Ogni task dichiara «il mutante che deve morire».** Un mutante che sopravvive va dichiarato **equivalente e spiegato**, mai nascosto. Il mutation testing si fa **solo su una copia nello scratchpad**, mai sul working tree.
3. **Ogni `nonisolated` su una classe con stato ha accanto una riga di commento che dice perché è sicura** (quale coda o quale lock custodisce quale proprietà). `@unchecked Sendable` senza quella riga è un errore di review.
4. **Non cambia la forma di nessun call site** in `BackupRunner`/`DuplicatesView` (salvo Task 4 e Task 7, che lo dicono). Nessuna funzione diventa `async`. Nessun `Task.detached` si sposta. Se una correzione sembra richiederlo, fermati e rimanda all'Architect.
5. **Regola assoluta.** Nessun diff di questo piano aggiunge `removeItem`, `trashItem`, `copyItem`, `moveItem`, `createDirectory` (fuori dai test) o una richiesta S3. `DuplicateTrasher.run` non cambia una riga del proprio corpo.
6. **Il conteggio dei warning scende a ogni task e non sale mai.** Se compare un warning in un punto nuovo, è una dipendenza che il piano non ha previsto: fermati e rimandala all'Architect invece di annotare altro per tentativi.
7. **Commit solo con build e suite verdi**, nel formato dei commit esistenti.

---

### Task 0: ADR, dopo l'approvazione e prima del codice

- [ ] **Step 1:** Scrivi `Docs/adr/NNNN-isolamento-mainactor-di-default-e-lavoro-di-fondo-nonisolated.md`, con `NNNN` = **il primo numero libero in `Docs/adr/` in quel momento** (0006 se il piano «volume-space-indicator», che se l'è prenotato, non l'ha ancora scritto). Contenuto: la «Bozza di ADR» in fondo alla spec, riportata con le risposte di Enrico alle domande aperte. Struttura Contesto / Opzioni valutate / Decisione e motivo, sul modello di 0001-0005.
- [ ] **Step 2:** Commit solo documentazione.

---

### Task 1: baseline misurata

- [ ] **Step 1:** Annota l'hash di `main` (`git rev-parse --short HEAD`).
- [ ] **Step 2:** Build pulita (comandi sopra). Atteso: **29** warning Swift unici, tutti in `ContentView.swift`, zero in `AppBackupFotoTests`. Salva l'elenco in `$SP/warnings-baseline.txt`. Se il numero è diverso, **fermati**: il codice è cambiato dopo la spec, e l'elenco dei task va riverificato dall'Architect.
- [ ] **Step 3:** Suite completa. Annota `B` = il numero nella riga `Executed N tests` e verifica zero fallimenti.
- [ ] **Step 4:** Nessun commit.

---

### Task 2: i test che vedono il bug (rossi sul codice di oggi)

**Files:**
- Create: `AppBackupFotoTests/MainThreadIsolationTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (4 punti)

- [ ] **Step 1:** Crea il file con l'impalcatura, il test di controllo e i primi due test. Usa gli helper di directory temporanea già in uso in `LibraryIndexStoreTests`/`LibraryIndexerTests` se ce ne sono (controlla con `grep`), altrimenti questi:

```swift
import XCTest
@testable import AppBackupFoto

/// Regressione del 2026-09-19 (BUG-7). Con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` un tipo
/// non annotato e' `@MainActor`, e un suo metodo sincrono chiamato da un `Task.detached` salta
/// sul main thread: era la lettura dell'elenco dopo ogni MAC -> SSD, sei minuti di beachball.
///
/// Tecnica: il lavoro parte in un `Task.detached`, ESATTAMENTE come in produzione, e intanto il
/// test tiene OCCUPATO il main thread aspettando un semaforo. Se il lavoro ha bisogno del main
/// non puo' finire, e il test scade (rosso) invece di restare appeso per sempre. Non e' una
/// corsa: il main e' occupato dal test per costruzione, quindi l'esito non dipende dal timing.
///
/// Limite dichiarato: verifica l'isolamento dei TIPI, non la forma dei call site. Un futuro
/// `await MainActor.run { idx.scan(...) }` scritto in `BackupRunner` passerebbe questi test.
final class MainThreadIsolationTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainThreadIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() throws -> LibraryIndexStore {
        try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
    }

    /// Il test del test. Se l'impalcatura fosse difettosa — per esempio se il semaforo non
    /// tenesse davvero occupato il main — tutti gli altri test passerebbero anche col bug.
    /// Qui il lavoro ha BISOGNO del main per costruzione, e il test si aspetta la scadenza.
    func testHarness_detectsWorkThatNeedsTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await MainActor.run { }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .timedOut,
                       "L'impalcatura non tiene occupato il main thread: gli altri test non provano niente.")
    }

    func testStoreCount_runsWithoutTheMainThread() throws {
        let store = try makeStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? store.count()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexStore.count() ha avuto bisogno del main thread: il tipo e' tornato @MainActor?")
    }

    func testScan_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: root.appendingPathComponent("a.jpg"))
        try Data("due".utf8).write(to: root.appendingPathComponent("b.jpg"))
        let indexer = LibraryIndexer(store: try makeStore())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? indexer.scan(root: root)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexer.scan ha avuto bisogno del main thread: e' il bug dei sei minuti dopo MAC -> SSD.")
    }
}
```

- [ ] **Step 2:** Registra il file nei 4 punti di `project.pbxproj`.
- [ ] **Step 3:** Esegui solo questa classe. Atteso **sul codice di oggi**: il controllo **passa**, `testStoreCount_…` e `testScan_…` **falliscono per timeout** (~10 s ciascuno). Se uno dei due passa, **fermati**: il test non misura il bug, e va capito perché prima di andare avanti. Annota l'esito.
- [ ] **Step 4:** Nessun commit: i due test rossi entrano insieme alla correzione del Task 3.

---

### Task 3: indice e hashing fuori dal main

Premetti `nonisolated` a queste dichiarazioni (trovale con `grep -n`), e per le quattro classi aggiungi anche `: @unchecked Sendable` con la riga di commento della regola 3:

| Dichiarazione | Forma | Riga di sicurezza (da scrivere accanto) |
| :--- | :--- | :--- |
| `enum LibraryExclusions` | `nonisolated enum` | — (puro) |
| `func canonicalPathComponents(of:)` | `nonisolated func` | — |
| `enum IndexEntryVerdict`, `func indexEntryVerdict(...)` | `nonisolated` | — |
| `struct LibraryIndexEntry`, `struct DuplicateGroup` | `nonisolated struct` | — (lo store li costruisce sulla sua coda) |
| `func normalizedIndexKey(_:)` | `nonisolated func` | — |
| `func isAllowedStoreLocation`, `func isRunningUnderTests`, `private func storeAllowedRoots`, `private func isPathInside` | `nonisolated` | — |
| `struct MeasuredHash`, `func sha256Measured(of:)`, `func sha256(of:)` | `nonisolated` | — (I/O POSIX su un descrittore locale) |
| `final class LibraryIndexStore` | `nonisolated final class LibraryIndexStore: @unchecked Sendable` | tutto lo stato mutabile (`db`) si tocca solo dentro `queue.sync`; `url` e' `let`; `deinit` ha accesso esclusivo |
| `final class LibraryIndexer` | `nonisolated final class LibraryIndexer: @unchecked Sendable` | `store`/`fm` sono `let`; `cancelled` passa da `cancelLock`; lo stato di una scansione e' locale a `scan`; «una scansione per volta» resta un contratto, garantito da `BackupRunner.isIndexing` |
| `final class ImportSessionIndex` | `nonisolated final class ImportSessionIndex: @unchecked Sendable` | `bySize` solo sotto `lock` |

Aggiorna anche i commenti che oggi dicono il falso: il doc-comment di `LibraryIndexStore` (la card «conta dal main thread»: non piu'), il commento su `realResolvedPath` che spiega il `nonisolated` e il commento sopra `refreshIndexedFileCount` (quel `count()` ora gira davvero fuori dal main).

- [ ] **Step 1:** Applica le annotazioni e i commenti.
- [ ] **Step 2:** Build pulita. Atteso: **16** warning (spariscono i 13 siti di `count`, `scan`, `duplicateGroups` e quelli di `isAlreadyInLibrary`/`importPreviewDuplicates`). Nessun sito nuovo (regola 6).
- [ ] **Step 3:** `MainThreadIsolationTests`: 3/3 verdi. Suite completa: `B + 3`, zero fallimenti.
- [ ] **Step 4: Il mutante che deve morire** (su copia nello scratchpad): togli `nonisolated` da `LibraryIndexStore` → `testStoreCount_…` rosso per timeout; toglilo da `LibraryIndexer` → `testScan_…` rosso. **Equivalenti dichiarati**: togliere `nonisolated` da `LibraryExclusions`, `canonicalPathComponents`, `normalizedIndexKey`, `sha256*` non fa fallire nessun test (una chiamata sincrona da un contesto non isolato non salta sul main, caso F della spec): lo uccide solo il conteggio dei warning, che risale.
- [ ] **Step 5:** Commit.

---

### Task 4: il verso mancante della mutua esclusione (prima di togliere il trasher dal main)

Va fatto **prima** del Task 5: finché `DuplicateTrasher.run` salta sul main il gate è innocuo; dopo, senza gate, un backup o una lettura potrebbero partire durante uno spostamento. Nessun commit intermedio deve avere la finestra aperta.

**Files:** `ContentView.swift`; test: `AppBackupFotoTests/JobStartGateTests.swift` (nuovo, 4 punti in `project.pbxproj`) e i file che chiamano i gate esistenti (`grep -ln "LibraryIndexCommandGate\|LibraryIndexAutoRefresh.shouldRun\|trashDisabledReason" AppBackupFotoTests/`).

- [ ] **Step 1: `JobStartGate`**, enum puro accanto a `LibraryIndexCommandGate`:

```swift
/// Perche' un job che scrive (MAC -> SSD, SSD -> HDD, SSD -> Cubbit, importazione) non puo'
/// partire adesso, oppure `nil`. Consultato da `BackupRunner.run(label:...)`, il punto da cui
/// passano tutti.
///
/// Esiste dal 2026-09-19. Fino a quel giorno lo spostamento nel Cestino e la lettura
/// dell'elenco giravano per errore sul main thread, e nessun backup poteva partire mentre
/// erano in corso perche' l'app era bloccata: la mutua esclusione la garantiva il bug. Tolto
/// il bug, la garantisce questo gate. Il verso opposto (niente spostamento durante un job o
/// una lettura) e' in `DuplicatesStatus.trashDisabledReason` e `LibraryIndexCommandGate`.
enum JobStartGate {
    static func blockedReason(isIndexing: Bool, isTrashingDuplicates: Bool) -> String? {
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino le copie doppie che hai confermato. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        if isIndexing {
            return "L'app sta leggendo le foto sull'SSD per aggiornare l'elenco. Aspetta che "
                + "finisca, oppure fermala con «\(LibraryIndexCommands.stop)» in Diagnostica."
        }
        return nil
    }
}
```

  Enrico ha risposto **(a)** alla domanda 1: il codice sopra (con il ramo `isIndexing`) è quello da scrivere, invariato.

- [ ] **Step 2: `BackupRunner`.** Aggiungi `@Published private(set) var isTrashingDuplicates = false`, `func beginDuplicateTrashing() -> SimpleAlert?` (restituisce l'avviso se non si puo' partire, altrimenti imposta il flag e restituisce `nil`: rifiuta se `isTrashingDuplicates`, `isRunning` o `isIndexing`) e `func endDuplicateTrashing()`. In `run(label:refreshesLibraryIndex:work:)`, subito dopo `guard !isRunning`, se `JobStartGate.blockedReason(...)` non e' `nil` assegna `pendingAlert = SimpleAlert(title: "Meglio non farlo adesso", message: reason)` e `return`.
- [ ] **Step 3: i gate esistenti guadagnano `isTrashingDuplicates:`, senza default.** `LibraryIndexCommandGate.disabledReason` e `resetDisabledReason`, `LibraryIndexAutoRefresh.shouldRun`, `DuplicatesStatus.trashDisabledReason`. Precedenza: lo spostamento prima di tutto negli ultimi tre, dopo `isIndexing` nel primo (stesso criterio del commento esistente: la causa piu' vicina a cio' che l'utente guarda). Testi:
  - `disabledReason`: «L'app sta spostando nel Cestino le copie doppie che hai confermato: leggere le foto adesso darebbe un elenco sbagliato. Riprova quando ha finito.»
  - `resetDisabledReason`: «L'app sta spostando nel Cestino le copie doppie e intanto aggiorna l'elenco: svuotarlo adesso lo lascerebbe a metà. Riprova quando ha finito.»
  - `trashDisabledReason`: «Uno spostamento nel Cestino è già in corso: aspetta che finisca.»
  Aggiorna tutti i call site di produzione (`grep`) passando `runner.isTrashingDuplicates` / `isTrashingDuplicates`.
- [ ] **Step 4: `DuplicatesView`.** Togli `@State private var isTrashing` e usa `runner.isTrashingDuplicates` ovunque lo si leggeva. In `startTrashing`, dopo il controllo `trashDisabledReasonNow`: `if let alert = runner.beginDuplicateTrashing() { pendingAlert = alert; return }`. Nel `MainActor.run` finale, **nello stesso blocco** che pubblica l'esito, chiama `runner.endDuplicateTrashing()` (`run` non lancia mai: nessun percorso salta la chiamata). Il commento accanto dice perché lo stato sta nel runner: riaprendo la finestra uno `@State` torna `false` e permetterebbe un secondo spostamento.
- [ ] **Step 5: test.** `JobStartGateTests`: nessun motivo quando tutto e' fermo; motivo con spostamento; motivo con lettura; con entrambi vince lo spostamento; nessun testo contiene «indice», «hash», «scansione» (stesso registro anti-gergo di `LibraryIndexStatus`). Nei file di test esistenti: aggiungi `isTrashingDuplicates: false` alle chiamate esistenti (asserzioni **invariate**) e un test per ciascun gate col flag a `true`. Atteso circa **+9**.
- [ ] **Step 6:** Build: warning invariati (16). Suite: `B + 3 + 9` circa (annota il numero esatto).
- [ ] **Step 7: Il mutante che deve morire:** `JobStartGate.blockedReason` che restituisce sempre `nil` → i test dello Step 5 rossi; in ciascun gate esistente, il ramo nuovo tolto → il test col flag a `true` rosso. **Non coperto, dichiarato**: `beginDuplicateTrashing`/`endDuplicateTrashing` e il `guard` in `run` (metodi di `BackupRunner`, non raggiungibili senza una corsa): li prova la verifica del Task 9.
- [ ] **Step 8:** Commit. Il Security/Rules Auditor rilegge questo task: tocca il perimetro del percorso a danno più alto.

---

### Task 5: pannello Doppioni fuori dal main

- [ ] **Step 1: test prima.** In `MainThreadIsolationTests` aggiungi, stessa forma dei precedenti: `testDuplicateGroups_runsWithoutTheMainThread` (`store.duplicateGroups()`), `testDuplicateBatch_runsWithoutTheMainThread` (`DuplicateBatch(groups: [])`), `testTrasherRun_runsWithoutTheMainThread`. Nell'ultimo il trasher si costruisce **con funzioni iniettate che non toccano niente**, e con un blocco vuoto:

```swift
let trasher = DuplicateTrasher(libraryRoot: root, store: store,
                               manifest: try TrashManifestStore(url: tmp.appendingPathComponent("manifest.json")),
                               trashFunction: { _ in nil },   // nessun Cestino vero, mai
                               hashFunction: { _ in nil })
Task.detached { _ = trasher.run([]); done.signal() }
```

  Esegui la classe. Atteso **dopo il Task 3**: `testDuplicateGroups_…` già verde (lo store è non isolato dal Task 3: questo test fissa la regressione, non la scopre), `testDuplicateBatch_…` e `testTrasherRun_…` **rossi per timeout**. Se uno di questi due passa, fermati come al Task 2, Step 3. Annota l'esito.
- [ ] **Step 2:** Premetti `nonisolated` a: `mainLibraryFolderKey`, `importFolderKey`, `DuplicateKeepReason`, `DuplicateKeepChoice`, `topLevelFolderKey`, `isInMainLibrary`, `isInImportFolder`, `duplicateKeepChoice`, `duplicateBatchFileCap`, `duplicateBatchByteCap`, `DuplicateBatch`, `TrashedItem`, `RestoreSkipReason`, `RestoreOutcome`, `TrashManifest`, `extension TrashManifest`, `extension TrashedItem`, `DuplicateTrashSkipReason`, `DuplicateTrashOutcome`. Più:
  - `TrashManifestStore` → `nonisolated final class …: @unchecked Sendable`, riga: «ogni accesso a `manifest` avviene dentro `lock.withLock`, scrittura su disco compresa; `url` e' `let`».
  - `DuplicateTrasher` → `nonisolated final class …: @unchecked Sendable`, riga: «solo proprieta' `let`; lo stato di `run` e' tutto locale. `run` puo' girare su qualunque thread, uno alla volta per blocco (lo garantisce `BackupRunner.isTrashingDuplicates`)».
  - `CancelFlag`: da `private final class` a `nonisolated final class CancelFlag: @unchecked Sendable`, aggiungi `func reset() { lock.withLock { flag = false } }`, aggiorna il doc-comment (e' ora il flag condiviso del progetto, vedi Task 6).
  **Il corpo di `DuplicateTrasher.run` non cambia di una riga** (regola 5).
- [ ] **Step 3:** Correggi in `.claude/rules/architecture.md` **subito**, non al Task 10, le due frasi che dicono che `loadGroups()` calcola «fuori dal main thread»: da oggi è vero, fino a oggi non lo era. Una riga con la data.
- [ ] **Step 4:** Test di `CancelFlag` (in `MainThreadIsolationTests` o in un file suo): `cancel()` da un `Task.detached` e lettura dal main dopo l'attesa → `true`; `reset()` → `false`.
- [ ] **Step 5:** Build: **14** warning. Suite: tutto verde, `+5` rispetto al Task 4.
- [ ] **Step 6: Il mutante che deve morire:** togli `nonisolated` da `DuplicateBatch` → test del batch rosso; da `DuplicateTrasher` → test del trasher rosso; `reset()` vuota → test di `CancelFlag` rosso.
- [ ] **Step 7:** Commit. Security/Rules Auditor: verifica che il diff non contenga una riga dentro `DuplicateTrasher.run` né una chiamata nuova a `trashItem`.

---

### Task 6: flag di interruzione, credenziali, limitatore, Immich

- [ ] **Step 1: `FileSyncer`.** `nonisolated final class FileSyncer: @unchecked Sendable`; `private var cancelled = false` diventa `private let cancelFlag = CancelFlag()` più `private var cancelled: Bool { cancelFlag.isCancelled }`; `cancel()` chiama `cancelFlag.cancel()`; le due `self.cancelled = false` diventano `self.cancelFlag.reset()`. Riga di sicurezza: «unico stato mutabile: `cancelFlag`, con lock; `fm` e `hashFunction` sono `let`». Commento: non era segnalato da nessun warning (caso B della spec), era una data race vera.
- [ ] **Step 2: `S3Syncer`**, che **resta `@MainActor`**: stessa sostituzione del flag, con `nonisolated private var cancelled: Bool { cancelFlag.isCancelled }`; le due `cancelled = false` diventano `cancelFlag.reset()`.
- [ ] **Step 3:** `nonisolated` su `AdaptiveLimiterState`, `AdaptiveLimiterOutcome`, `AdaptiveLimiter`.
- [ ] **Step 4: credenziali.** `nonisolated` su `S3Config`, `KeychainCredentials`, `keychainQuery`, `readFromKeychain`, `writeToKeychain`, `readConfig`, `readConfigWithSource`, `readConfigFromFile`, `validateEndpoint`. **Nessuna riga di corpo cambia.** Commento su `readConfigWithSource`: gira fuori dal main dal 2026-09-03 (`loadS3ConfigIfNeeded`), l'annotazione lo rende dichiarato.
- [ ] **Step 5:** `ProcessOutputBuffer`, `ContinuationGuard`: da `private final class` a `private nonisolated final class`.
- [ ] **Step 6:** Build: **7** warning, tutti di cattura (`[weak self]` ×3, `alertSink` ×4). Suite verde, conteggio invariato.
- [ ] **Step 7: Il mutante che deve morire.** Sostituire il flag nudo con `CancelFlag` è **equivalente per i test**: da un thread solo i due si comportano identici, e la data race che si toglie non è riproducibile in modo deterministico. Va dichiarato così. Il mutante che invece conta è sul reset: in `FileSyncer.sync` togli `self.cancelFlag.reset()` → un `sync` lanciato dopo un `cancel()` non copierebbe più niente. Al 2026-09-19 nessun test chiama `cancel()` su `FileSyncer` (l'unico file di test che usa `.cancel()` è `LibraryIndexerTests`): aggiungi in `FileSyncerZeroOverwriteTests` il test «dopo `cancel()`, un nuovo `sync` copia di nuovo» e verifica che il mutante lo renda rosso. `+1`.
- [ ] **Step 8:** Commit. **Security/Rules Auditor obbligatorio**: tocca il flusso delle credenziali (`Docs/CLAUDE.md`, «Progettazione prima dell'implementazione»). Deve confermare che nessuna riga di corpo del percorso Keychain/`rclone.conf` è cambiata.

---

### Task 7: gli ultimi sette warning

- [ ] **Step 1:** In `run(label:…)` (due blocchi) e in `publishCurrentFile`: `await MainActor.run {` → `await MainActor.run { [weak self] in` sui tre blocchi che iniziano con `guard let self`.
- [ ] **Step 2:** In `LibraryIndexCard`: la proprietà `alertSink` diventa `private func postAlert(_ alert: SimpleAlert) { DispatchQueue.main.async { pendingAlert = alert } }`, con lo stesso doc-comment (il rinvio di un giro di run loop resta, è voluto). I quattro `onAlert: alertSink` diventano `onAlert: { postAlert($0) }`. Aggiorna i due commenti che nominano `alertSink` (`grep -n alertSink`). **`typealias AlertSink` non cambia.**
- [ ] **Step 3:** Build pulita: **0** warning Swift in entrambi i target (restano solo quelli non Swift: `Info.plist` nella fase Copy Bundle Resources e `appintentsmetadataprocessor`, preesistenti). Suite verde.
- [ ] **Step 4:** Commit.

---

### Task 8: gate di compilazione e mutation testing complessivo (Enrico ha risposto sì alla domanda 2)

- [ ] **Step 1:** In `project.pbxproj`, **solo** nella configurazione **Debug** del target **app** (`695F43402EB019B400509478`, verificare con `grep`), aggiungi `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;`. Non Release, non il target di test.
- [ ] **Step 2:** Build pulita e suite: verdi.
- [ ] **Step 3: mutanti, su una copia nello scratchpad.** Per ciascuno: build con `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` → **deve essere rossa**; poi build e test con `SWIFT_TREAT_WARNINGS_AS_ERRORS=NO` da riga di comando → **il test indicato deve essere rosso per timeout**. Due esiti separati perché il gate di compilazione, se acceso, nasconderebbe il test.

| Mutante | Build con gate | Test senza gate |
| :--- | :--- | :--- |
| `LibraryIndexStore` senza `nonisolated` | rossa (misurato in spec) | `testStoreCount_…`, `testDuplicateGroups_…` |
| `LibraryIndexer` senza `nonisolated` | rossa | `testScan_…` |
| `DuplicateBatch` senza `nonisolated` | rossa | `testDuplicateBatch_…` |
| `DuplicateTrasher` senza `nonisolated` | rossa | `testTrasherRun_…` |
| `sha256(of:)` senza `nonisolated` | **verde con warning** (classe F, misurato) | nessuno — **equivalente dichiarato**: lo prende solo la regola sui warning |
| controllo: `await MainActor.run { }` tolto dal test di controllo | — | `testHarness_…` rosso |

- [ ] **Step 4:** Scrivi l'esito (tabella compilata) nel messaggio di commit e nella sezione «Verifiche» della spec.
- [ ] **Step 5:** Commit.

---

### Task 9: verifica empirica sull'app reale, con Enrico

Nessun punto si spunta senza averlo visto. Serve l'app con la correzione, lanciata **nello stesso modo** in cui è stato riprodotto il bug il 2026-09-19, con Full Disk Access valido (prima prova: la card «Foto già salvate sull'SSD» legge l'SSD). SSD collegato, elenco già creato (`indexedFileCount > 0`), aggiornamento automatico acceso in Impostazioni.

- [ ] **Step 1: il processo.** `pgrep -x AppBackupFoto | wc -l` deve dare **1** (un'altra istanza, per esempio l'host dei test, falserebbe i campioni). `PID=$(pgrep -x AppBackupFoto)`; `OUT=$SP/verifica-$(date +%H%M%S); mkdir -p $OUT`.
- [ ] **Step 2: MAC → SSD, poi campionamento per tutta la lettura dell'elenco.** Avvia MAC → SSD dall'app. Appena il job finisce (parte da solo l'aggiornamento dell'elenco; in Diagnostica la card mostra la lettura in corso), lancia:

```bash
for i in $(seq 1 12); do sample $PID 4 -file $OUT/s$i.txt >/dev/null 2>&1; sleep 26; done
```

  Dodici campioni da 4 s ogni 30 s coprono circa 6 minuti, la durata misurata del blocco. Se la lettura finisce prima, fermati: annota **quanto è durata** fuori dal main thread (serve alla domanda 1).
- [ ] **Step 3: analisi.** Per ogni campione, il blocco del main thread (dalla riga `com.apple.main-thread` alla riga del thread successivo):

```bash
for f in $OUT/s*.txt; do
  awk '/Thread_[0-9]+.*com\.apple\.main-thread/{p=1; print; next} p && /^ +[0-9]+ Thread_/{p=0} p' "$f" > "$f.main"
  tot=$(head -1 "$f.main" | awk '{print $1}')
  idle=$(grep '__CFRunLoopServiceMachPort' "$f.main" | head -1 | grep -oE '^[ +!:|]*[0-9]+' | grep -oE '[0-9]+$')
  bad=$(grep -cE 'LibraryIndexer|LibraryIndexStore|sqlite3_|getattrlist|realpath|statfs|DuplicateBatch|DuplicateTrasher' "$f.main")
  scanAll=$(grep -c 'LibraryIndexer.scan' "$f"); scanMain=$(grep -c 'LibraryIndexer.scan' "$f.main")
  echo "$(basename $f): main campioni=$tot in-runloop=$idle righe-sospette-sul-main=$bad scan-su-altri-thread=$((scanAll-scanMain))"
done
```

  **Passa se**, in ogni campione preso durante la lettura: `righe-sospette-sul-main = 0`, `in-runloop` almeno il 90% di `campioni`, **e** `scan-su-altri-thread > 0`. L'ultima condizione è il controllo positivo: senza, «main libero» potrebbe voler dire «la lettura non è partita». Conserva i file in `$OUT` e riporta la tabella nella spec.
- [ ] **Step 4: la finestra risponde.** Durante la lettura: apri e chiudi il pannello hamburger, cambia tab nel log, apri Diagnostica. Nessun beachball. **La barra della card avanza** (prima si aggiornava solo a lettura finita).
- [ ] **Step 5: «Interrompi» funziona per la prima volta.** Rilancia «Aggiorna l'elenco» da Diagnostica e premi «Interrompi» dopo qualche secondo: la lettura si ferma entro pochi secondi e la card mostra la riga dell'interruzione. Annota il tempo di reazione.
- [ ] **Step 6: il gate del Task 4.** Mentre l'elenco si aggiorna, premi MAC → SSD: con la risposta (a) alla domanda 1 compare l'avviso con il motivo e il job non parte.
- [ ] **Step 7: pannello Doppioni.** Apri la finestra «Doppioni» e campiona subito due volte (`sample $PID 4`) mentre carica: il blocco del main non contiene `duplicateGroupsUnsynchronized` né `DuplicateBatch`. **Cronometra** quanto ci mette a comparire l'elenco dei 12.001 gruppi, e annotalo: è il numero che la spec dice non misurato.
- [ ] **Step 8: avvio.** Chiudi e riapri l'app, campiona entro 2 secondi: il main non contiene `countUnsynchronized`. `sqlite3_open_v2` **può** comparire (apertura nel getter `lazy`, fuori scope, spec «Fuori scope» punto 4): annotalo, non è un fallimento.
- [ ] **Step 9 (solo se Enrico decide di farlo): uno spostamento vero nel Cestino.** Operazione reale, sotto ADR-0005: blocco piccolo (3-5 gruppi) scelto da Enrico. Durante: campiona una volta (main libero), e prova a premere MAC → SSD (deve comparire l'avviso dello spostamento in corso). Dopo: la finestra mostra l'esito, e si può usare «Annulla l'ultimo spostamento» se Enrico vuole.
- [ ] **Step 10:** Registro di sistema, stesso metodo del 2026-09-19: nessun intervallo in cui il main thread resta muto durante i passi 2-7.

---

### Task 10: documentazione

- [ ] **Step 1:** `.claude/rules/bug-history.md`: **BUG-7** — sintomo (beachball di ~6 minuti dopo MAC → SSD, 01:15:59 → 01:22:10), causa (isolamento MainActor di default + `Task.detached`), conseguenze (Interrompi e arresto allo smontaggio morti durante lettura e spostamento, barra ferma, mutua esclusione garantita dal bug), correzione, tabella dei mutanti del Task 8 e dei campioni del Task 9. **Lezione**: la lezione del 2026-09-03 («`sample` misura CPU, un main bloccato in I/O sembra idle») qui non valeva, perché il main era al 100% dentro `getattrlist`/`realpath`: `sample` l'ha trovato subito. E la seconda: *un warning "cannot be called from outside of the actor" in un contesto `async` non è un avviso di stile, è un salto sul main thread*.
- [ ] **Step 2:** `.claude/rules/architecture.md`: sezione nuova «Isolamento MainActor di default (2026-09-19)» con la tabella dei casi A-F della spec, la regola sui tipi `nonisolated` e la riga di sicurezza, `CancelFlag` come flag condiviso, `isTrashingDuplicates`/`JobStartGate`. Correggi le frasi rimaste false: `indexedFileCount` «aggiornato fuori dal main thread» (vero da oggi, con la data), la sezione sul bug del 2026-09-02 (la correzione tolse la ripetizione, lo spostamento fuori dal main è di oggi), e la nota sull'avvio del 2026-09-03 (il `count()` tornava sul main).
- [ ] **Step 3:** `Docs/CLAUDE.md`: conteggio dei test (numero **misurato** a fine piano), data della tabella; nella checklist «Regola sul ciclo AI di revisione» aggiungi: *IF il codice lancia lavoro in `Task.detached` o su una `DispatchQueue` THEN verifica che i tipi chiamati siano `nonisolated`, con la riga sul perché sono thread-safe; IF una funzione di fondo diventa `async` THEN `@concurrent`*; nella sezione Build: *una build con un warning `actor-isolated` non è verde*.
- [ ] **Step 4 (Enrico ha risposto: non implementare, registrare in ROADMAP):** aggiungi in `Docs/ROADMAP.md` un punto numerato per ciascuno dei cinque punti «Fuori scope» della spec (numerazione progressiva dall'ultimo punto esistente), con le evidenze già raccolte nella spec (sezione «Fuori scope»), marcati come aperti/da verificare — non ticket in `Docs/superpowers/tickets/`.
- [ ] **Step 5:** Commit della documentazione.

---

## Riepilogo dei conteggi

| Task | warning Swift a fine task | nuovi test (circa) | cumulativo |
| :--- | ---: | ---: | ---: |
| 1 (baseline) | 29 | 0 | B |
| 2-3 | 16 | 3 | B + 3 |
| 4 | 16 | 9 | B + 12 |
| 5 | 14 | 5 | B + 17 |
| 6 | 7 | 1 | B + 18 |
| 7 | 0 | 0 | B + 18 |
| 8 | 0 (con gate) | 0 | idem |

I conteggi dei warning dei Task 3, 5 e 7 sono stati **misurati** su una copia usa-e-getta durante la stesura della spec; quelli dei test sono stime, e vale il numero nel log. Due file di test nuovi (`MainThreadIsolationTests.swift`, `JobStartGateTests.swift`), da registrare entrambi in `project.pbxproj`.
