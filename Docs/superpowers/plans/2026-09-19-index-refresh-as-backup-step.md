# L'aggiornamento dell'elenco come ultimo passo del backup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: APPROVATO da Enrico (2026-09-19).** Spec di riferimento: `Docs/superpowers/specs/2026-09-19-index-refresh-as-backup-step-design.md`. Le tre domande aperte sono chiuse con le raccomandazioni dell'Architect (1→b, 2→«completato con nota», 3→sì) — vedi ADR-0007.

**Prerequisito, prima di tutto:** `fix/mainactor-isolation` è **mergiato su `main`** (con la sua verifica empirica, Task 9 di quel piano, chiusa). Questo lavoro parte da quel `main` su un **branch nuovo**, `feature/index-refresh-as-backup-step`. Se il merge non è avvenuto, **non iniziare**: il passo 2 presuppone che `scan` giri fuori dal main, e senza il fix un job che resta «in corso» per 6 minuti con l'app in beachball sarebbe peggio di oggi.

**Goal:** dopo MAC → SSD e dopo un'importazione, l'aggiornamento dell'elenco è il passo 2 del job: stessa barra, stesso «Interrompi», riepilogo e notifica solo alla fine, nessun avviso.

**Architecture:** il job resta `.running` fino alla fine della lettura. `run(label:refreshesLibraryIndex:work:)` finisce in due tempi (`finishCopyStep` → eventuale passo 2 → `finishJob`). La lettura ha due ingressi (passo 2 silenzioso, comando manuale con i suoi avvisi) sopra una sola `startLibraryIndexScan`. Tutta la logica di decisione e i testi stanno in un tipo puro nuovo, `BackupListStep`.

**Tech Stack:** Swift 5.x, isolamento MainActor di default, SwiftUI, XCTest. Nessuna dipendenza, nessuno schema, nessuna chiave `UserDefaults` nuova.

**Baseline:** **misurala** sul `main` post-merge (Task 1) e chiamala `B`. Non copiare numeri da `Docs/CLAUDE.md`. Il target di test **non è file-system-synchronized**: il file nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Verifica sempre il totale nel log, mai il solo `** TEST SUCCEEDED **`.

| Componente | Cosa cambia | Test |
| :---- | :---- | :---- |
| `LibraryIndexer.scan` | `progressEvery`, `total` iniziale | 3 in `LibraryIndexerTests` |
| `BackupListStep` (nuovo, puro) | decisione, stima, esiti, testi | `BackupListStepTests` (~26) |
| `LibraryIndexCommands.cardTitle` | costante al posto di due letterali | coperto dai test dei testi |
| `BackupRunner` | `startLibraryIndexScan`, `finishCopyStep`, `finishJob`, `stop()`, `displayPercent`, stato del passo | nessuno (cablaggio): verifica empirica |
| UI (`StatsPanel`, `PhaseIndicator`, `MenuBarIcon`, `CompletionSheet`, Impostazioni, `onChange(ssdMounted)`) | presentazione del passo 2 | nessuno: verifica empirica |

## Comandi di build e test

Sempre con un `derivedDataPath` nello scratchpad (`$SP`), mai quello di default: Enrico usa la sua build.

```bash
SP=<scratchpad della sessione>
rm -rf $SP/dd && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l     # deve restare 0 (warning = errori in Debug dal fix precedente)
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests" $SP/test.log | tail -1
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai con il numero di riga.**
2. **Test prima del codice** per tutta la logica pura: il test nuovo si vede rosso (o non compilare) prima dell'implementazione.
3. **Ogni task dichiara il mutante che deve morire.** Mutation testing solo su una copia nello scratchpad, mai sul working tree. Un mutante che sopravvive va dichiarato equivalente e spiegato.
4. **Nessun testo nelle View.** Ogni stringa nuova a schermo nasce in `BackupListStep` o in `LibraryIndexCommands` e passa il registro anti-gergo.
5. **Garanzie del fix di isolamento**: `scan` resta nel suo `Task.detached`, nessuna funzione diventa `async`, nessuna chiamata a `LibraryIndexer`/`LibraryIndexStore` finisce dentro un `MainActor.run`. `MainThreadIsolationTests` resta verde senza modifiche. Zero warning (la build Debug li tratta come errori).
6. **Regola assoluta**: nessun diff aggiunge `removeItem`, `trashItem`, `copyItem`, `moveItem` o richieste S3.
7. **I testi degli avvisi della lettura manuale non cambiano.** Se un diff modifica una stringa esistente in `rebuildLibraryIndex`, è un errore.
8. Se il codice trovato non corrisponde a quanto descritto qui, **fermati e rimanda all'Architect**.
9. **Commit solo con build e suite verdi**, nel formato dei commit esistenti.

---

### Task 0: ADR, dopo l'approvazione e prima del codice

- [ ] **Step 1:** Scrivi `Docs/adr/NNNN-l-aggiornamento-dell-elenco-e-l-ultimo-passo-del-backup.md`, `NNNN` = primo numero libero in quel momento (0007 se nessun altro piano l'ha preso). Contenuto: la «Bozza di ADR» in fondo alla spec, con le risposte di Enrico. Struttura Contesto / Opzioni valutate / Decisione e motivo, sul modello di 0001-0006.
- [ ] **Step 2:** Commit solo documentazione.

---

### Task 1: branch e baseline

- [ ] **Step 1:** Verifica che `main` contenga il merge di `fix/mainactor-isolation` (`git log --oneline main | grep -i "Task 8: warning trattati come errori"`). Se manca, fermati.
- [ ] **Step 2:** `git switch -c feature/index-refresh-as-backup-step main`.
- [ ] **Step 3:** Build pulita: **0** warning Swift. Suite completa: annota `B` e zero fallimenti.
- [ ] **Step 4:** Nessun commit.

---

### Task 2: l'avanzamento anche sui file invariati (`LibraryIndexer.scan`)

**Files:** Modify `AppBackupFoto/ContentView.swift` (`LibraryIndexer.scan`), `AppBackupFotoTests/LibraryIndexerTests.swift`.

- [ ] **Step 1: controllo preliminare.** `grep -n "0\.\.<" AppBackupFotoTests/*.swift` sui test che chiamano `scan` con una closure `onProgress` non vuota (`LibraryIndexerTests`, `DuplicateTrasherTests`, `MainThreadIsolationTests`, `LibraryIndexStoreTests` se la usa): annota il numero massimo di file creati. Deve essere **< 250**. Se un test ne crea di più, fermati e rimanda all'Architect (il default andrebbe rivisto).
- [ ] **Step 2: test rossi.** In `LibraryIndexerTests`:

```swift
// Un aggiornamento dopo un backup normale trova quasi solo file invariati: senza
// avanzamento su di loro la barra del passo 2 resterebbe ferma per minuti.
func testUnchangedFiles_stillReportProgress() throws {
    for i in 0..<600 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
    _ = try indexer.scan(root: root)                       // prima lettura: tutto in elenco
    var scannedSeen: [Int] = []
    let p = try indexer.scan(root: root, progressEvery: 100) { scannedSeen.append($0.scanned) }
    XCTAssertEqual(p.hashed, 0, "seconda lettura: nessun file da rileggere")
    XCTAssertGreaterThanOrEqual(scannedSeen.filter { $0 < 600 }.count, 5,
                                "servono avanzamenti intermedi anche senza file da rileggere")
    XCTAssertEqual(scannedSeen, scannedSeen.sorted(), "scanned non torna mai indietro")
}

// `total` e' "quante voci ci sono nell'elenco": vale gia' all'inizio, non 0.
func testFirstProgress_reportsTheEntriesAlreadyInTheList() throws {
    for i in 0..<300 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
    _ = try indexer.scan(root: root)
    var first: LibraryIndexer.Progress?
    _ = try indexer.scan(root: root, progressEvery: 100) { if first == nil { first = $0 } }
    XCTAssertEqual(first?.total, 300)
}

func testProgressEveryZero_emitsNoIntermediateProgress() throws {
    for i in 0..<300 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
    _ = try indexer.scan(root: root)
    var calls = 0
    _ = try indexer.scan(root: root, progressEvery: 0) { _ in calls += 1 }
    XCTAssertEqual(calls, 1, "solo l'avanzamento finale: nessun blocco da scrivere, nessuna emissione periodica")
}
```

Verifica che il terzo test, **sul codice di oggi e senza il parametro**, darebbe 1: se l'emissione finale non è unica in quel percorso, correggi l'atteso e scrivi nel commento perché.

- [ ] **Step 3: implementazione.** In `scan`: parametro `progressEvery: Int = 250` fra `ignoringStoredHashes` e `onProgress`; subito dopo `progress.scanned += 1`:

```swift
// Avanzamento anche sui file invariati (2026-09-19, passo 2 del backup): i blocchi si
// riempiono solo con file da rileggere, e dopo un backup normale quasi nessuno lo e' —
// senza questa riga la barra resterebbe ferma per minuti. Non scrive e non decide niente.
if progressEvery > 0 && progress.scanned % progressEvery == 0 { onProgress(progress) }
```

e subito dopo `let knownKeys = try store.allKeys()`: `progress.total = knownKeys.count` con una riga di commento («`total` = voci nell'elenco in questo momento; senza, il primo avanzamento farebbe leggere "0 foto" alla card»). Non toccare nessun'altra riga di `scan`.
- [ ] **Step 4:** i 3 test verdi; suite completa: `B + 3`, zero fallimenti.
- [ ] **Step 5: mutanti che devono morire** (copia nello scratchpad): togliere la riga di emissione → muore `testUnchangedFiles_stillReportProgress`; togliere `progress.total = knownKeys.count` → muore `testFirstProgress_…`; sostituire `progressEvery > 0 &&` con `true &&` → crash per modulo zero, muore `testProgressEveryZero_…`. **Tutti i test di cancellazione e di rinomina di #31 devono restare verdi sul codice mutato e non mutato.**
- [ ] **Step 6:** Commit.

---

### Task 3: `BackupListStep`, la logica pura del passo 2

**Files:** Create `AppBackupFotoTests/BackupListStepTests.swift` (+ 4 punti in `project.pbxproj`); Modify `AppBackupFoto/ContentView.swift` (tipo nuovo accanto a `LibraryIndexAutoRefresh`; `LibraryIndexCommands.cardTitle`).

Forma indicativa (i nomi possono cambiare in review, la sostanza no). Stesso isolamento di `LibraryIndexAutoRefresh` (nessuna annotazione: è chiamato solo dal MainActor e dai test, come lui).

```swift
enum BackupListStep {
    enum State: Equatable { case planned; case running(estimate: Int) }
    enum Outcome: Equatable {
        case updated, updatedWithRemarks, stoppedByYou, ssdDisconnected,
             stoppedByAnotherDisk, couldNotUpdate
    }
    static func shouldRun(refreshesLibraryIndex: Bool, enabled: Bool, indexedFileCount: Int,
                          isIndexing: Bool, isTrashingDuplicates: Bool) -> Bool
    static func estimate(indexedBefore: Int, copied: Int, copiedUnverified: Int) -> Int
    static func progress(scanned: Int, estimate: Int) -> (percent: Int, shownTotal: Int)
    static func outcome(progress: LibraryIndexer.Progress?, interruptedByUser: Bool,
                        couldNotStart: Bool, scanFailed: Bool) -> Outcome
    static func header(label: String, state: State?) -> String
    static func copyDoneLine(stats: JobStats) -> (text: String, clean: Bool)
    static let runningLine = "Aggiorno l'elenco delle foto sull'SSD…"
    static func countLine(scanned: Int, shownTotal: Int) -> String   // "48.300 / 78.000 file controllati"
    static let stoppingLabel = "Mi fermo…"
    static func completionLine(_ o: Outcome) -> (text: String, tone: LibraryIndexStatus.Tone)
    static func notificationBody(stats: JobStats, outcome: Outcome?) -> String
}
```

- [ ] **Step 1: test rossi** (~26), nello stile di `JobStartGateTests`/`LibraryIndexStatusTests`, un commento per test che dice **quale difetto** blocca:
  - `shouldRun` ×6 (vedi spec, «Test»);
  - stima e percentuale ×5: `estimate(indexedBefore: 100, copied: 3, copiedUnverified: 1) == 104`; `progress(scanned: 104, estimate: 104).percent == 99`; `progress(scanned: 50, estimate: 100) == (50, 100)`; `progress(scanned: 120, estimate: 100).shownTotal == 120` e percent 99; `progress(scanned: 0, estimate: 0) == (0, 0)`;
  - `outcome` ×8: un caso per esito della tabella D6; «fermato da te» vince su `volumeVanished`; `couldNotStart` vince su tutto; un `Progress` completo con `rebasedByTimezone > 0` (riga `fuso`, informativa) ⇒ `.updated`; un `Progress` con `unreadableItems > 0` ⇒ `.updatedWithRemarks`. Costruisci i `Progress` con `traversalIncomplete = false` quando vuoi una lettura completa: **il default è `true`**;
  - testi ×7: `header` nei tre casi (`nil` ⇒ `label` identico); `copyDoneLine` con 1 nuova / 2 nuove, con errori (`clean == false`), con `duplicatesSkipped` sommati a «già presenti»; `notificationBody` con esito `nil` ⇒ **identico al corpo di oggi** («Copiati N · Skippati M · Errori E»), con `.stoppedByYou` ⇒ termina con « · Elenco delle foto non aggiornato», con `.updatedWithRemarks` ⇒ nessuna aggiunta; `completionLine(.updatedWithRemarks)` contiene `LibraryIndexCommands.cardTitle`; registro anti-gergo su **ogni** testo di ogni esito e di ogni riga, da una lista di casi condivisa (stessa lista di parole di `LibraryIndexStatusTests`).
  - Numeri: sotto 1.000, oppure atteso costruito con `formatted()`.
- [ ] **Step 2:** implementa. `updatedWithRemarks` = `LibraryIndexStatus.lines(for: p, interruptedByUser: false).contains { $0.tone == .warning }` — **non** ridichiarare le condizioni. `LibraryIndexCommands.cardTitle = "Foto già salvate sull'SSD"`, e sostituisci con la costante i due letterali esistenti (`GroupBox(...)` della card e il messaggio che rimanda alla card: `grep -n "Foto già salvate sull'SSD"`).
- [ ] **Step 3:** verdi; suite `B + 3 + N3` (N3 = test aggiunti in questo task, dichiarato nel commit).
- [ ] **Step 4: mutanti**: invertire la precedenza fra `interruptedByUser` e `volumeVanished`; usare `.info` al posto di `.warning` nel criterio dei rilievi; togliere il `min(99, …)`; togliere il `max(estimate, scanned)`. Devono morire tutti.
- [ ] **Step 5:** Commit.

---

### Task 4: un solo punto che avvia la lettura (`startLibraryIndexScan`)

**Files:** Modify `AppBackupFoto/ContentView.swift` (`BackupRunner.rebuildLibraryIndex` e metodo privato nuovo).

- [ ] **Step 1:** estrai da `rebuildLibraryIndex` tutto quello che sta **dopo** il blocco `LibraryIndexCommandGate.disabledReason` in `private func startLibraryIndexScan(full: Bool, onFinish: @escaping @MainActor (LibraryIndexer.Progress?, Error?) -> Void) -> ListScanStartFailure?`, con `enum ListScanStartFailure { case storeUnavailable, ssdUnavailable, notVolumeRoot }`. I tre `guard` restituiscono il motivo invece di chiamare `showIndexAlert`; il `catch` del `Task.detached` non mostra più l'avviso ma conserva l'errore; il blocco finale (`stopAccessing`, `isIndexing = false`, `indexer = nil`) resta **identico** e **dopo** chiama `onFinish(progressFinale, erroreEventuale)`. Il `Progress` finale è il valore restituito da `scan` (oggi scartato con `_ =`).
- [ ] **Step 2:** `rebuildLibraryIndex(full:onAlert:)` = gate di oggi → `startLibraryIndexScan` → per ogni `ListScanStartFailure` **lo stesso `SimpleAlert` di oggi, stesso testo**, via `showIndexAlert(_, via: onAlert)`; `onFinish` mostra «Il controllo si è fermato» con lo stesso testo di oggi solo se c'è un errore.
- [ ] **Step 3:** controllo di equivalenza: `git diff` sulle stringhe di `rebuildLibraryIndex` = zero righe di testo cambiate. Build 0 warning, suite `B + 3 + N3` invariata (nessun test nuovo: è un refactoring, lo dicono i test esistenti e `MainThreadIsolationTests`).
- [ ] **Step 4:** Commit.

---

### Task 5: il job in due tempi (`BackupRunner.run`)

**Files:** Modify `AppBackupFoto/ContentView.swift` (`BackupRunner`: `run`, `stop`, proprietà pubblicate nuove; `JobStats.listStepOutcome`).

- [ ] **Step 1: stato nuovo sul runner.** `@Published private(set) var listStepState: BackupListStep.State? = nil`, `@Published private(set) var listStopRequested = false`, e `var displayPercent: Int` (durante `.running(estimate:)` la percentuale di `BackupListStep.progress(scanned: indexProgress?.scanned ?? 0, estimate:)`, altrimenti `stats.percent`). `JobStats` guadagna `var listStepOutcome: BackupListStep.Outcome? = nil` con il commento «non persistito, nessun conteggio lo legge».
- [ ] **Step 2: avvio.** In `run`, dopo `JobStartGate` e il reset di `stats`: `listStepState = BackupListStep.shouldRun(refreshesLibraryIndex:…, enabled: LibraryIndexAutoRefresh.isEnabled(), indexedFileCount:, isIndexing:, isTrashingDuplicates:) ? .planned : nil`; `listStopRequested = false`.
- [ ] **Step 3: `finishCopyStep`.** Il ramo di successo di oggi si divide: dentro il `MainActor.run`, dopo il `guard !self.wasStopped`, la copia dei valori da `r` in `stats` e il `JobHistoryStore.save(… succeeded: true …)` **restano identici e nello stesso ordine**; il timer **non** si cancella più qui; `phase`, `Notifier.send` e `completionSnapshot` **escono** da questo punto. Poi:

```swift
if BackupListStep.shouldRun(refreshesLibraryIndex: refreshesLibraryIndex,
                            enabled: LibraryIndexAutoRefresh.isEnabled(),
                            indexedFileCount: self.indexedFileCount,
                            isIndexing: self.isIndexing,
                            isTrashingDuplicates: self.isTrashingDuplicates) {
    self.startListStep(label: label)
} else {
    self.finishJob(label: label, listOutcome: nil)
}
```

  Il ramo `catch` e `stop()` durante la copia **non cambiano** (a parte azzerare `listStepState = nil`, così un job fallito non lascia «passo 1 di 2» sull'intestazione).
- [ ] **Step 4: `startListStep(label:)`.** `stats.percent` resta 100 (la copia è finita); `listStepState = .running(estimate: BackupListStep.estimate(indexedBefore: indexedFileCount, copied: stats.copied, copiedUnverified: stats.copiedUnverified))`; `append("STATUS: \(BackupListStep.runningLine)\n")`; poi `startLibraryIndexScan(full: false) { p, err in self.finishJob(label:, listOutcome: BackupListStep.outcome(progress: p, interruptedByUser: self.indexInterruptedByUser, couldNotStart: false, scanFailed: err != nil)) }`. Se `startLibraryIndexScan` restituisce un motivo: `finishJob(label:, listOutcome: .couldNotUpdate)` subito. **Nessun avviso, in nessun ramo.**
- [ ] **Step 5: `finishJob(label:listOutcome:)`.** `elapsedTimer?.cancel()`; `stats.elapsed = makeElapsed()`; `stats.listStepOutcome = listOutcome`; `listStepState = nil`; `listStopRequested = false`; `phase = .success("Completato: \(label)")`; `Notifier.send(phase.label, BackupListStep.notificationBody(stats: stats, outcome: listOutcome))`; se c'è un esito, `append` del suo testo nel log; `completionSnapshot = (phase, stats)`. **Non** salva un `JobSummary` (è già salvato).
- [ ] **Step 6: `stop()`.** In testa: `if case .running = listStepState { guard !listStopRequested else { return }; listStopRequested = true; cancelIndexing(); return }`. Il resto di `stop()` identico.
- [ ] **Step 7: `autoRefreshLibraryIndexIfEnabled`** non è più chiamata da `run`. (Il suo destino è nel Task 7.)
- [ ] **Step 8:** build 0 warning, suite invariata rispetto al Task 4. Rileggi il diff con questa checklist: (a) `JobHistoryStore.save` è chiamato **una** volta per job riuscito e **prima** del passo 2; (b) `Notifier.send` e `completionSnapshot` una volta, solo in `finishJob` (successo) o nei rami di errore/stop di oggi; (c) `finishJob` è raggiungibile da **ogni** uscita del passo 2 (non partito, `scan` finita, `scan` lanciata) — il blocco finale di `startLibraryIndexScan` è l'unico posto e non viene saltato; (d) nessuna chiamata a `idx.scan`/`store.*` dentro un `MainActor.run`.
- [ ] **Step 9:** Commit.

---

### Task 6: quello che si vede

**Files:** Modify `AppBackupFoto/ContentView.swift` (`StatsPanel`, `PhaseIndicator`, `ContentView` barra in alto, `MenuBarIcon`, `CompletionSheet`).

- [ ] **Step 1:** `PhaseIndicator` guadagna `title: String` (il chiamante passa `BackupListStep.header(label: runner.phase.label, state: runner.listStepState)`) e usa `displayPercent` al posto di `stats.percent`. Il ramo «Finalizzando...» a 100% resta per il passo 1 e **non** deve comparire nel passo 2 (lì la percentuale è ≤ 99 fino a `finishJob`).
- [ ] **Step 2:** `StatsPanel` riceve un parametro opzionale di presentazione del passo 2 (valori già calcolati: le due righe, `percent`, riga del conteggio). Se presente: righe dei passi al posto di miniatura+stato, conteggio al posto di «done / total file», velocità ed ETA «—». Tessere invariate. Nessuna stringa scritta nella View.
- [ ] **Step 3:** pulsante «Interrompi» della barra in alto: stesso pulsante; con `listStopRequested` mostra `BackupListStep.stoppingLabel` ed è disattivato.
- [ ] **Step 4:** `MenuBarIcon.updateDockBadge` legge `runner.displayPercent` e osserva anche quello (`.onChange(of: runner.displayPercent)`).
- [ ] **Step 5:** `CompletionSheet`: se `stats.listStepOutcome` c'è, **una** riga `Label` con `completionLine(_:)` e il colore del tono (ok = `AppColor.success`, info = `.secondary`, warning = `AppColor.warning`), dopo le righe esistenti e prima del pulsante OK. Titolo e icona invariati.
- [ ] **Step 6:** build 0 warning, suite invariata. Commit.

---

### Task 7: collegamento dell'SSD e Impostazioni (dipende dalla risposta 1)

**Con (b), raccomandata:**
- [ ] **Step 1:** `onChange(of: volumes.ssdMounted)`: `guard mounted, autoBackupEnabled, !runner.isRunning else { return }; runner.runMacToSSD()`. Via il ramo `else`. Aggiorna il commento: l'elenco si aggiorna come passo 2 del backup.
- [ ] **Step 2:** rimuovi `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` (resta `isEnabled`/`defaultsKey`). Rimuovi i 6 test di `shouldRun` in `LibraryIndexStatusTests` (`grep -n "testAutoRefresh_" …`): le condizioni che verificavano sono ora in `BackupListStepTests` (tranne «aspetta la fine di un job», che non ha più senso: il passo 2 **è** il job). `testAutoRefreshSwitch_isOnUntilTheUserTurnsItOff` resta. Aggiorna i doc-comment che citano `LibraryIndexAutoRefresh.shouldRun` (`grep -n "LibraryIndexAutoRefresh.shouldRun"`), fra cui quello di `LibraryIndexCommandGate` e di `rebuildLibraryIndex`.
- [ ] **Step 3:** Impostazioni: testo dell'interruttore e della didascalia come nella spec (D10). Chiave `@AppStorage` **identica**.

**Con (a):** nessun cambiamento in questo task salvo la didascalia (che deve smettere di promettere «un'occhiata veloce solo alle foto nuove»).

- [ ] **Step 4:** suite: `B + 3 + N3 − 6` con (b). Dichiara il saldo nel commit. Commit.

---

### Task 8: verifica sull'app reale, con Enrico

Build Debug dallo scratchpad, app lanciata da lì (non quella in `/Applications`). Procedura: i 5 punti della sezione «Verifica sull'app reale» della spec. Per il punto 3: `pgrep -x AppBackupFoto`, poi `sample <pid> 4 -file $SP/sample-N.txt` ripetuto ogni ~20 s per tutta la durata del passo 2; criterio: albero del main thread che termina in `mach_msg2_trap` sotto `__CFRunLoopServiceMachPort` **e** `LibraryIndexer.scan` su un altro thread. Annota la **durata del passo 2** (inizio = comparsa di «passo 2 di 2», fine = riepilogo): è il numero che conferma o riapre il costo accettato in D1.

Nessuno spostamento nel Cestino, nessuna importazione reale necessaria (l'importazione passa dallo stesso codice di `run`; se Enrico vuole provarla, una cartella piccola di prova).

---

### Task 9: documentazione

- [ ] `.claude/rules/architecture.md`: sezione «UI e aggancio automatico» (il punto «L'aggancio automatico non parte al collegamento dell'SSD…» va riscritto: ora è il passo 2 del job, e con (b) al collegamento non parte più niente da solo); `BackupRunner` (fine in due tempi, `JobSummary` salvato alla fine del passo 1, `stop()` nel passo 2); `LibraryIndexer` (`progressEvery`, `total` iniziale); badge del Dock (`displayPercent`).
- [ ] `Docs/CLAUDE.md`: tabella di stato (data, conteggio test misurato, riga «Backup automatico Mac→SSD» e riga #31).
- [ ] `Docs/CONTEXT.md`: voce «passo 2 del backup / aggiornamento dell'elenco» se il vocabolario ha una voce per l'elenco (controlla).
- [ ] Commit solo documentazione.

## Riepilogo dei conteggi

| Dopo il task | Test attesi |
| :--- | :--- |
| 1 | `B` |
| 2 | `B + 3` |
| 3 | `B + 3 + N3` (N3 ≈ 26, dichiarato nel commit) |
| 4-6 | invariato |
| 7 (b) | `B + 3 + N3 − 6` |

Warning Swift: 0 a ogni task.
