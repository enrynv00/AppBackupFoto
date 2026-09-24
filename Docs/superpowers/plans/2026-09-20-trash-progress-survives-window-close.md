# Lo spostamento nel Cestino non perde barra e «Interrompi» (#41) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: BOZZA — in attesa di approvazione di Enrico.** Nessuna riga di codice scritta. Spec: `Docs/superpowers/specs/2026-09-20-trash-progress-survives-window-close-design.md`.

**Base:** `main` **dopo** il merge di `fix/remaining-main-thread-work`. Se quel merge non è ancora avvenuto, **fermati**: questo piano riusa `startTrashRestore`/`stopTrashRestore`/`TrashRestoreStatus` come modello e come vicini di casa, e su un `main` senza #34 metà dei riferimenti non esiste.

**Goal:** chiudere e riaprire la finestra Doppioni durante uno spostamento nel Cestino non fa più perdere né la barra né «Interrompi», e l'esito si legge anche se la finestra era chiusa quando l'operazione è finita. Stesso schema di #34 (ADR-0009): lo stato dell'operazione vive in `BackupRunner`, non negli `@State` di `DuplicatesView`.

**Architecture:** nessun tipo nuovo `nonisolated`, nessun motore toccato. `BackupRunner` guadagna quattro proprietà e due metodi (simmetrici a quelli dell'annullamento); `DuplicatesView` ne perde tre e cede il corpo di `startTrashing`; `DuplicatesStatus` guadagna tre testi puri; nasce un piccolo predicato puro `DuplicatesPanelLoad`. `DuplicateTrasher.run` non cambia di una riga.

**Tech Stack:** Swift 5.x, isolamento MainActor di default, *Approachable Concurrency*, SwiftUI, XCTest. Nessuna dipendenza nuova.

**Baseline:** **misurala** (Task 1). `Docs/CLAUDE.md` riporta 756 test su `fix/remaining-main-thread-work`: dopo il merge su `main` dovrebbe essere lo stesso numero, ma va verificato, non copiato. Il target di test **non è file-system-synchronized**: ogni file di test nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Questo piano **non aggiunge file di test nuovi** — estende `DuplicatesStatusTests.swift`, già registrato — quindi quel passaggio non serve; verifica comunque sempre il **totale** nella riga `Executed N tests`, mai il solo `** TEST SUCCEEDED **`.

| Task | Cosa | Test nuovi (ordine di grandezza) |
| :--- | :--- | :--- |
| 0 | nota in ADR-0009 (nessun ADR nuovo — dipende dalla risposta 1) | — |
| 1 | baseline misurata | — |
| 2 | testi puri: `trashProgressLine`, `trashStoppingLine`, `headerLine(groupsKnown:)` | `DuplicatesStatusTests` +~10 |
| 3 | `DuplicatesPanelLoad.shouldLoadOnAppear` | `DuplicatesStatusTests` +~8 |
| 4 | `BackupRunner`: stato e orchestrazione dello spostamento | nessuno (dichiarato) |
| 5 | `DuplicatesView`: `@State` rimossi, cablaggio, `.task`/`.onChange` | nessuno (dichiarato) |
| 6 | **condizionato** (risposta 3): stessa rivalutazione per «Annulla» | +~1 |
| 7 | mutation testing (copia nello scratchpad) | — |
| 8 | documentazione | — |
| 9 | verifiche dal vivo con Enrico | — |

I Task 2 e 3 vengono prima perché i Task 4 e 5 usano quei testi e quel predicato: scritti dopo, verrebbero scritti inline nella View e poi estratti, che è come sono nati i tre difetti di gergo già corretti in questo progetto.

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
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd test -only-testing:AppBackupFotoTests/DuplicatesStatusTests 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai con il numero di riga.** `ContentView.swift` ha ~13.300 righe; i nomi citati qui sono stati letti a `2e63dc4`, i numeri di riga no.
2. **Ogni task dichiara il mutante che deve morire**, o dichiara perché non ne ha uno. Si verifica nel Task 7, su una copia nello scratchpad. Un mutante che sopravvive va dichiarato equivalente e spiegato, mai nascosto.
3. **Zero warning.** Un warning nuovo, di qualunque tipo, in Debug è una build rossa (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). **Se compare un warning di isolamento (`actor-isolated`), fermati e rimanda all'Architect**: questo intervento non deve produrne nessuno — sposta stato fra due tipi già `@MainActor` — quindi un warning simile significa che qualcosa è finito dalla parte sbagliata, non che manca un `nonisolated`.
4. **Regola assoluta.** Nessun diff di questo intervento aggiunge, sposta o rimuove una chiamata a `trashItem`, `removeItem`, `copyItem`, `moveItem`, `createDirectory` o una richiesta S3. **`DuplicateTrasher.run` non cambia di una riga, firma compresa.** Se ti accorgi di doverlo toccare, fermati e rimanda all'Architect.
5. **Asserzioni esistenti.** Adattare la *firma* di una chiamata in un test esistente è ammesso (Task 2 cambia la firma di `headerLine`); cambiare **cosa asserisce** no. Ogni asserzione che «deve» cambiare è un segnale da rimandare all'Architect.
6. **Testi a schermo solo in tipi puri** (`DuplicatesStatus`), mai costruiti nella View. Niente gergo: niente «hash», «indice», «registro», «manifest», «volume», «scansione», «entry», «cache», «sha».
7. **Commit solo con build e suite verdi**, un commit per task, nel formato dei commit esistenti (messaggio in italiano, trailer di attribuzione della sessione). **Mai `git push`**.

---

### Task 0: nota nell'ADR, dopo l'approvazione e prima del codice

**Dipende dalla risposta alla domanda 1 della spec (§6).** Se Enrico chiede un ADR nuovo, **fermati e rimanda all'Architect** invece di scriverlo a braccio: un ADR va scritto con contesto, opzioni e conseguenze, non dedotto da questo piano.

- [ ] **Step 1:** In coda a `Docs/adr/0009-l-annullamento-dello-spostamento-gira-fuori-dal-main-e-il-registro-ricorda-cosa-e-tornato.md`, una nota datata: lo stesso schema è stato applicato allo spostamento nel Cestino (ROADMAP #41); il difetto che il doc-comment di ADR-0009 citava come «ancora aperto» è chiuso; le due scelte minori di questo intervento (l'elenco non si ricarica mentre l'operazione è in corso, l'esito vive in memoria e non su disco) con il loro perché in una riga ciascuna.
- [ ] **Step 2:** Verifica che nessun altro documento dica ancora che #41 è aperto **tranne** `Docs/ROADMAP.md`, che si aggiorna nel Task 8 (dopo il codice, non qui).
- [ ] **Step 3:** Commit solo documentazione.

---

### Task 1: baseline misurata

- [ ] **Step 1:** `git rev-parse --short HEAD` su `main`, annotalo. Verifica che `git log --oneline -5` contenga il lavoro di #34 (`TrashRestorer`, `startTrashRestore`): se non c'è, **fermati**.
- [ ] **Step 2:** Build pulita. Atteso: **0** warning. Se non è 0, **fermati** e rimanda all'Architect.
- [ ] **Step 3:** Suite completa. `B` = numero in `Executed N tests`, zero fallimenti. Atteso ~756.
- [ ] **Step 4:** Nessun commit.

---

### Task 2: i tre testi puri di `DuplicatesStatus`

**File:** `AppBackupFoto/ContentView.swift` (`enum DuplicatesStatus`), `AppBackupFotoTests/DuplicatesStatusTests.swift`.

- [ ] **Step 1: test prima.** In `DuplicatesStatusTests`:
  - `testTrashProgressLine_showsBothNumbers` — `(done: 3, total: 10)` contiene «3» e «10» nell'ordine giusto (asserisci sulla posizione di `range(of:)`, non solo sulla presenza: è il mutante principale).
  - `testTrashProgressLine_singularTotal` — `total == 1` → «gruppo», mai «gruppi».
  - `testTrashProgressLine_pluralTotal` — `total == 2` → «gruppi».
  - `testTrashProgressLine_singularDependsOnTotal_notOnDone` — `(done: 1, total: 4)` → «gruppi». È il test che uccide il mutante.
  - `testTrashProgressLine_hasNoJargon` — riusa la lista di parole vietate già presente nel file (se esiste un helper condiviso, usalo; non ricrearne uno secondo).
  - `testTrashStoppingLine_isNotEmptyAndHasNoJargon`.
  - `testTrashStoppingLine_doesNotPromiseAnImmediateStop` — non contiene «subito»/«immediat» (il trasher si ferma fra un gruppo e l'altro).
  - `testHeaderLine_groupsUnknown_neverSaysThereAreNoDuplicates` — `groupsKnown: false, groupCount: 0` → il testo **non** contiene la frase di `zero-groups`, e l'`id` è diverso da `zero-groups`.
  - `testHeaderLine_groupsUnknown_ignoresTheCount` — `groupsKnown: false, groupCount: 12` → stessa riga del caso precedente (il conteggio non è attendibile, non si mostra).
  - `testHeaderLine_groupsKnown_keepsTodaysThreeBranches` — con `groupsKnown: true`, le tre diramazioni esistenti (`no-index`, `zero-groups`, `groups`) restituiscono esattamente quello che restituiscono oggi.
- [ ] **Step 2:** Implementa in `DuplicatesStatus`:
  - `static func trashProgressLine(done: Int, total: Int) -> String` — il testo di oggi del `body` di `DuplicatesView` («Sposto le copie nel Cestino: …»), con il plurale via l'helper `count(_:_:_:)` già usato nel file, deciso su `total`.
  - `static let trashStoppingLine` — gemella di `TrashRestoreStatus.stoppingLine`, riferita al gruppo e non alla foto.
  - `headerLine`: nuovo parametro `groupsKnown: Bool` **senza valore di default**, valutato **prima** di `groupCount`, con un `id` nuovo e stabile (`"groups-unknown"`) e un testo che dice che l'elenco non è ancora stato letto. Doc-comment: perché il default manca (un chiamante vecchio compilerebbe con il comportamento sbagliato) e perché la riga esiste (un elenco che non si conosce e un elenco vuoto sono due situazioni opposte — stessa classe di errore di `sawNothing` in #31).
- [ ] **Step 3:** Aggiorna le chiamate esistenti di `headerLine` nei test (solo la firma) e in `DuplicatesView.headerLine` (passa `loadedBatch != nil`; il resto della view si sistema nel Task 5).
- [ ] **Step 4:** Build pulita (0 warning) + suite. Atteso `B + ~10`.
- [ ] **Mutante da uccidere:** (a) in `trashProgressLine`, decidere il plurale su `done` invece che su `total`; (b) in `headerLine`, ignorare `groupsKnown` e cadere nella logica di oggi.
- [ ] **Step 5:** Commit.

---

### Task 3: `DuplicatesPanelLoad` — quando la finestra legge l'elenco all'apertura

**File:** `AppBackupFoto/ContentView.swift` (accanto a `DuplicatesStatus`), `AppBackupFotoTests/DuplicatesStatusTests.swift`.

- [ ] **Step 1: test prima.** Le otto combinazioni, una asserzione ciascuna, più i due casi che portano il motivo:
  - `testLoadsOnAppear_whenIdleAndNothingIsRunning` → `true`.
  - `testDoesNotLoad_whenNotIdle` (elenco già caricato o in caricamento) → `false`, per tutte e quattro le combinazioni dei due flag.
  - `testDoesNotLoad_whileTrashing` → `false`.
  - `testDoesNotLoad_whileRestoringFromTrash` → `false`.
  - `testDoesNotLoad_whileBothFlagsSomehowTrue` → `false` (combinazione impossibile per la mutua esclusione, ma il predicato non deve dipendere da quell'ipotesi).
- [ ] **Step 2:** Implementa `enum DuplicatesPanelLoad { static func shouldLoadOnAppear(isIdle: Bool, isTrashingDuplicates: Bool, isRestoringFromTrash: Bool) -> Bool }`. Doc-comment: l'elenco letto a metà operazione è un bersaglio in movimento (il trasher toglie chiavi dallo stesso elenco mentre legge e rihasha sullo stesso volume), è già vecchio quando compare, costa il percorso pesante misurato il 2026-09-02, e il bottone è comunque disattivato con il motivo scritto; arriva da solo quando l'operazione finisce.
- [ ] **Step 3:** Build pulita + suite. Atteso `B + ~18`.
- [ ] **Mutante da uccidere:** togliere `!isTrashingDuplicates` dal predicato (deve arrossire `testDoesNotLoad_whileTrashing`).
- [ ] **Step 4:** Commit.

---

### Task 4: `BackupRunner` — stato e orchestrazione dello spostamento

**File:** `AppBackupFoto/ContentView.swift` (`BackupRunner`, subito **dopo** il blocco «Annullamento dell'ultimo spostamento»).

- [ ] **Step 1:** Aggiungi, con un doc-comment che spiega perché non sono `@State` e cita ROADMAP #41 come il difetto che chiudono:
  - `@Published private(set) var duplicateTrashProgress: (done: Int, total: Int)? = nil`
  - `@Published private(set) var duplicateTrashStopRequested = false`
  - `@Published private(set) var lastDuplicateTrashOutcome: DuplicateTrashOutcome? = nil`
  - `private var duplicateTrashCancelFlag: CancelFlag? = nil`
- [ ] **Step 2:** `func startDuplicateTrashing(_ batch: DuplicateBatch, onAlert: @escaping (SimpleAlert) -> Void)`. Il corpo è quello di `DuplicatesView.startTrashing(_:)` di oggi, **spostato, non riscritto**, nell'ordine di oggi:
  1. `DuplicatesStatus.trashDisabledReason(isRunning:isIndexing:ssdMounted:isTrashingDuplicates:isRestoringFromTrash:)` con `ssdMounted: VolumeMonitor.shared.ssdMounted` → se non `nil`, `onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))` e `return`. **Riporta il commento esistente** sul perché le precondizioni si rivalutano qui e non al click (rilievo di review del 2026-09-01), e aggiungi una riga sul perché il runner legge `VolumeMonitor.shared` (lettura di un `Bool` sul MainActor, nessun I/O, nessuna sottoscrizione).
  2. `guard let store = libraryIndexStore, let manifest = trashManifestStore, let root = BookmarkManager.shared.urls[.ssd]` → alert «Non è stato possibile procedere», stesso testo di oggi.
  3. `if let alert = beginDuplicateTrashing() { onAlert(alert); return }` — **nessun `return` fra qui e il `Task.detached`**, invariante da lasciare scritta nel commento come oggi.
  4. `decisions`, `DuplicateTrasher(libraryRoot:store:manifest:)`, `CancelFlag()` in `duplicateTrashCancelFlag`, `duplicateTrashStopRequested = false`, `lastDuplicateTrashOutcome = nil`, `lastTrashRestoreOutcome = nil`, `duplicateTrashProgress = (0, decisions.count)`.
  5. `Task.detached(priority: .utility)` con `trasher.run(decisions, onProgress:isCancelled:)` **identico a oggi** — nessun `ProgressThrottle` (la cadenza è per gruppo, ADR-0010 lascia esplicitamente stare le altre sorgenti).
  6. Un solo `MainActor.run` finale: `endDuplicateTrashing()`, `duplicateTrashProgress = nil`, `duplicateTrashStopRequested = false`, `duplicateTrashCancelFlag = nil`, `lastDuplicateTrashOutcome = outcome`, `refreshRestorableBatch()`. **Niente `loadGroups()` e niente selezione qui**: sono della view, e ci arriva dal Task 5. Riporta il commento sul perché `end` sta in questo blocco.
- [ ] **Step 3:** `func stopDuplicateTrashing()` — `guard !duplicateTrashStopRequested else { return }`, poi `duplicateTrashStopRequested = true` e `duplicateTrashCancelFlag?.cancel()`. Doc-comment sul fatto che il trasher si ferma fra un gruppo e l'altro: un gruppo in corso viene chiuso, non lasciato a metà.
- [ ] **Step 4:** In `startTrashRestore`, aggiungi `lastDuplicateTrashOutcome = nil` accanto a `lastTrashRestoreOutcome = nil` (invalidazione reciproca, spec D5). Stringi `trashRestoreProgress` e `lastTrashRestoreOutcome` a `@Published private(set)`: dopo questo passo la view non li scrive più. Se il compilatore segnala un altro scrittore, **fermati** — significa che c'è un percorso che la spec non ha visto.
- [ ] **Step 5:** Build pulita (0 warning). La suite resta a `B + ~18` (nessun test nuovo). In questo momento `DuplicatesView` non compila ancora se hai già tolto i suoi `@State`: **non toglierli qui**, il Task 5 fa la view in un solo passaggio.
- [ ] **Mutante:** **nessuno.** Questo task non introduce logica pura; le difese sono la build (le due proprietà `private(set)`) e le verifiche dal vivo 1, 2 e 6 del Task 9. Dichiaralo così nel commit, non inventare un mutante che non c'è.
- [ ] **Step 6:** Commit.

---

### Task 5: `DuplicatesView` — via gli `@State`, dentro il cablaggio

**File:** `AppBackupFoto/ContentView.swift` (`DuplicatesView`).

- [ ] **Step 1:** Rimuovi `trashProgress`, `activeCancelFlag`, `lastOutcome`. Rimuovi il corpo di `startTrashing(_:)` e sostituiscilo con `runner.startDuplicateTrashing(batch, onAlert: { pendingAlert = $0 })` (una riga, come `startUndo()`). Il `.alert` distruttivo continua a passare `pendingBatch`: **il blocco congelato resta della view e viaggia come parametro**, invariante del Task 2/4 del pannello.
- [ ] **Step 2:** Nel `body`: la barra dello spostamento si condiziona a `runner.isTrashingDuplicates, let progress = runner.duplicateTrashProgress`; le righe di esito a `runner.lastDuplicateTrashOutcome`. `trashProgressBar(_:)` usa `DuplicatesStatus.trashProgressLine(done:total:)` e, come la gemella dell'annullamento, mostra `DuplicatesStatus.trashStoppingLine` al posto del bottone quando `runner.duplicateTrashStopRequested`; il bottone chiama `runner.stopDuplicateTrashing()`.
- [ ] **Step 3:** `headerLine` passa `groupsKnown: loadedBatch != nil` (già fatto nel Task 2, ricontrolla che sia ancora così dopo le modifiche).
- [ ] **Step 4:** `.task`: `if DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: { if case .idle = loadState { true } else { false } }(), isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash) { loadGroups() }`, poi `runner.refreshRestorableBatch()` come oggi. Scrivi il predicato leggibile (una `private var loadStateIsIdle: Bool` va benissimo), non un'espressione compressa.
- [ ] **Step 5:** Aggiungi `.onChange(of: runner.isTrashingDuplicates) { _, isTrashing in if !isTrashing { selectedHashes.removeAll(); pendingBatch = nil; loadGroups() } }`, **accanto** a quello già esistente su `isRestoringFromTrash`, non fuso con esso (spec, rischio 5). Commento: è qui che finisce quello che prima stava nel blocco finale del `Task.detached` della view — le chiavi dei file davvero cestinati sono già state tolte dall'elenco dentro `run(...)`, quindi si rilegge per mostrare i gruppi rimasti.
- [ ] **Step 6:** Rileggi il `body` intero e verifica che **nessuna stringa a schermo** sia costruita lì dentro (regola 6). Verifica che non sia rimasto nessun riferimento ai tre `@State` rimossi (`grep -n "trashProgress\b\|activeCancelFlag\|lastOutcome" AppBackupFoto/ContentView.swift`).
- [ ] **Step 7:** Build pulita (0 warning) + suite completa. Atteso `B + ~18`, zero fallimenti.
- [ ] **Mutante:** **nessuno** (nessuna logica pura nuova). Difese: la build, il `grep` dello Step 6, e le verifiche dal vivo 1-5 del Task 9. In particolare la verifica 4 copre il rischio principale dell'intervento (l'`.onChange` dello Step 5 dimenticato o scritto sul flag sbagliato).
- [ ] **Step 8:** Commit.

---

### Task 6 (CONDIZIONATO alla risposta 3 della spec): stessa rivalutazione per «Annulla»

Eseguire **solo** se Enrico risponde «sì» alla domanda 3 della §6 della spec. Altrimenti saltare e segnalarlo nel Task 8 come punto nuovo da aprire in `Docs/ROADMAP.md`.

- [ ] **Step 1:** In `BackupRunner.startTrashRestore`, prima di `beginTrashRestore()`, rivaluta `DuplicatesStatus.undoDisabledReason(...)` con `ssdMounted: VolumeMonitor.shared.ssdMounted`, `summary: restorableBatch`, `hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0` → se non `nil`, `onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))` e `return`. Stesso ordine del Task 4 (motivo specifico prima, alert generico dopo).
- [ ] **Step 2:** Se la view smette di usare `undoDisabledReasonNow` per qualcosa di diverso dal disabilitare il bottone, **non** rimuoverla: serve ancora alla riga che spiega perché il bottone è grigio.
- [ ] **Step 3:** Un test in `DuplicatesStatusTests` se manca: `undoDisabledReason` con `ssdMounted: false` ha la precedenza su tutto il resto (probabilmente c'è già — controlla prima di aggiungerlo, non duplicare).
- [ ] **Mutante da uccidere:** invertire l'ordine dei due controlli in `startTrashRestore` (il motivo specifico dopo quello generico). Non è coperto da test: dichiaralo **equivalente sul piano dei test e verificato a vista**, come già fatto altrove in questo progetto.
- [ ] **Step 4:** Build pulita + suite. Commit.

---

### Task 7: mutation testing

**Solo su una copia del repository nello scratchpad**, mai sull'albero di lavoro di Enrico.

- [ ] **Step 1:** `cp -R` del repo in `$SP/mutants`, e lavora lì.
- [ ] **Step 2:** Applica uno alla volta i mutanti dichiarati nei Task 2 (a e b), 3 e 6, e verifica che ciascuno faccia arrossire **almeno un test nominato**. Annota quale.
- [ ] **Step 3:** Un mutante che sopravvive va o coperto con un test nuovo o **dichiarato equivalente con il motivo scritto** nel commit e nel Task 8. Mai nascosto.
- [ ] **Step 4:** Nessun commit del codice mutato. Cancella `$SP/mutants` alla fine.

---

### Task 8: documentazione

- [ ] **Step 1:** `.claude/rules/architecture.md`, sezione «Pannello Doppioni con cancellazione» (o una sottosezione nuova subito dopo «Annulla l'ultimo spostamento fuori dal main»): cosa è passato nel runner e perché, la regola di D3 («lo stato di un'operazione che sopravvive alla finestra vive nel runner; lo stato della conversazione vive nella view»), la scelta di non ricaricare l'elenco durante l'operazione, la durata in memoria dell'esito e l'invalidazione reciproca, e cosa **non** è coperto da test con la ragione.
- [ ] **Step 2:** Nella stessa pagina, aggiorna il doc-comment/riferimento che cita #41 come difetto ancora aperto (sezione dell'annullamento): ora è chiuso.
- [ ] **Step 3:** `Docs/ROADMAP.md`, punto 41: da 🔲 a **«implementato il 2026-09-XX, verifica dal vivo ancora da fare»** — **non** ✅ finché Enrico non ha eseguito il Task 9. Se il Task 6 è stato saltato, aggiungi un punto nuovo in coda per la rivalutazione mancante di «Annulla».
- [ ] **Step 4:** `Docs/CLAUDE.md`: riga «Test automatici» (nuovo totale e da dove viene) e la riga «Indice di contenuto della libreria» per il pannello Doppioni (una frase, non un paragrafo). Aggiorna la data in testa a «Stato attuale» dicendo quali righe sono state riverificate in questa sessione e quali no, come fanno i tocchi precedenti.
- [ ] **Step 5:** Commit solo documentazione.

---

### Task 9: verifiche dal vivo (Enrico, con l'SSD collegato)

**Non le esegue l'Implementer.** Sono elencate per esteso nella §4 della spec; qui restano solo come checklist da spuntare insieme.

- [ ] Barra e «Interrompi» presenti riaprendo la finestra a metà spostamento.
- [ ] «Interrompi» dalla finestra riaperta: compare la riga «mi fermo…», l'operazione si ferma fra un gruppo e l'altro, l'esito lo racconta con i numeri giusti.
- [ ] Esito visibile riaprendo la finestra dopo la fine, con l'elenco ricaricato e nessuna spunta rimasta.
- [ ] Finestra sempre aperta: comportamento identico a prima dell'intervento (**la verifica che copre il rischio principale**).
- [ ] L'intestazione, a finestra riaperta durante l'operazione, non dice «non ci sono copie doppie».
- [ ] Durante uno spostamento, «Annulla l'ultimo spostamento» e un backup restano rifiutati con i motivi di sempre.
- [ ] *(facoltativa, da Xcode)* Nessun avviso SwiftUI di accesso a `State` fuori da una view installata, con la finestra chiusa durante l'operazione.
