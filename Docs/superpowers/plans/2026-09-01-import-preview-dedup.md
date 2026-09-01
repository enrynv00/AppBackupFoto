# Anteprima vera nel wizard di import (roadmap #27-A / #31, terza parte) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: APPROVATO da Enrico il 2026-09-01.** Spec di riferimento: `Docs/superpowers/specs/2026-09-01-import-preview-dedup-design.md`. **Le quattro domande aperte sono chiuse**: leggere la sezione «Risposte di Enrico» in coda alla spec **prima di toccare il Task 4**, che ne è cambiato.

**Quello che le risposte cambiano nel Task 4** — è la parte di questo piano che si implementa più facilmente a metà, quindi sta qui e non solo nella spec:

- L'anteprima **parte da sola** alla scelta della sorgente, come oggi. Nessun bottone «controlla», nessuna soglia.
- Enrico ha accettato il doppio costo di lettura **a condizione** che l'attesa sia visibile e fermabile. Parole sue: *«accettabile, ma il processo deve essere interrompibile, ci deve essere timer o figura che gira per far capire che sta procedendo»*. Quindi servono tutti e tre: **avanzamento determinato** (i file e i byte della sorgente si conoscono prima di iniziare — non uno `ProgressView()` indeterminato), **tempo trascorso o stimato** (riusando `SyncResult.hms` e la macchina dell'ETA già in casa, non riscrivendola), e **«Interrompi» che ferma davvero la lettura**, non solo l'aggiornamento della barra.
- **Interrompere non torna indietro e non lascia una schermata vuota**: degrada al conteggio grezzo con una riga che dichiara che il controllo è stato interrotto e che alcune di quelle foto potrebbero essere già sull'SSD ed essere saltate. Chi interrompe ha scelto di non aspettare e ha diritto di procedere con un numero dichiarato approssimato.
- **La discrepanza sullo spazio si riformula**: l'alert di `runImport` dice «Servono **al massimo** circa X». Nessuna terza lettura della sorgente — quel controllo vuole un limite superiore, ed è il verso sicuro.

**Goal:** Il numero «File da importare: N» mostrato dal wizard è quello che verrà davvero copiato — dedup per contenuto contro l'indice della libreria **e** doppioni interni alla stessa sorgente inclusi — senza toccare i job Mac→SSD e SSD→HDD e senza che `FileSyncer` impari cos'è un doppione.

**Architecture:** Un parametro nuovo con default `nil` su `FileSyncer.previewSync` (stesso schema di `isDuplicate`/`onCopied`/`onUnverified` su `sync`), che consegna a una closure esterna l'elenco dei candidati e ne riceve indietro gli indici dei doppioni. La closure vive in `BackupRunner`, riusa **la stessa** `isAlreadyInLibrary` dell'import e non introduce nessuna nuova query sullo store. Le righe di stato del wizard sono logica pura in un enum a parte.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest. Nessuna dipendenza nuova, nessuna modifica allo schema SQLite.

**Baseline: 503 test verdi su `main`** (working tree pulito). **Verifica il conteggio reale prima di iniziare** — la documentazione del progetto riporta 480/501/503 in punti diversi e il numero di partenza va confermato, non ereditato. Ogni task dichiara il proprio incremento e il cumulativo atteso; il target di test **non è file-system-synchronized**: ogni file nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti, e si verifica sempre il **conteggio totale nel log**, mai il solo `** TEST SUCCEEDED **`.

| Componente | Responsabilità | Test |
| :---- | :---- | :---- |
| `FileSyncer.PreviewCandidate` + `previewSync(duplicateFilter:)` | raccogliere i candidati, sottrarre i doppioni, mantenere l'invariante dei conteggi | `FileSyncerPreviewDedupTests.swift` |
| `isAlreadyInLibrary(onSourceHash:)` | restituire l'hash già calcolato, senza cambiare la decisione | `ImportPreviewDedupTests.swift` |
| `BackupRunner.importPreviewDuplicates` | il motore dell'anteprima: prefiltro, doppioni interni, progresso, interruzione | `ImportPreviewDedupTests.swift` |
| `ImportPreviewStatus` | le righe che il wizard mostra, come logica pura | `ImportPreviewStatusTests.swift` |
| `ImportView` | cablaggio, barra determinata, gate SSD montato | non coperto, dichiarato |

## Comandi di build e test

```bash
# build
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
# suite completa
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
# singola classe
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Localizza sempre con `grep -n`, mai per numero di riga.** `ContentView.swift` è un file da 10.500 righe e i numeri citati qui invecchiano al primo commit.
2. **Ogni task dichiara «il mutante che deve morire»**: la modifica plausibile che un ottimizzatore futuro farebbe, e il test che deve diventare rosso. Un mutante che sopravvive va dichiarato **equivalente e spiegato**, mai nascosto — su questo progetto un test che codifica il bug invece di trovarlo è già successo tre volte.
3. **Nessun percorso di questo piano scrive, copia, sposta o cancella un file.** È tutto sola lettura: se un diff introduce una `copyItem`, `removeItem`, `trashItem` o `createDirectory` fuori dai test, è un errore.
4. **Nessuna nuova lettura di `resourceValues(forKeys: [.fileSizeKey])`.** Si riusa quella già presente in `previewFile`. Vedi il vincolo 3 della spec: il fatto misurato n. 1 è già costato due bug.

---

### Task 1: `previewSync(duplicateFilter:)` — il gancio dentro `FileSyncer`

Primo perché il Task 4 lo consuma, ed è l'unica parte che tocca un tipo condiviso con altri tre job.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `FileSyncer`, sezione `MARK: - Dry-run preview` — localizza con `grep -n "func previewSync"`)
- Modify: `AppBackupFoto/ContentView.swift` (l'annotazione di tipo `@State private var previewResult` in `ImportView` — `grep -n "toAdd: Int, toSkip: Int"` trova entrambi i punti da aggiornare, e sono solo due)
- Create: `AppBackupFotoTests/FileSyncerPreviewDedupTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `previewDir`/`previewFile`, `LibraryExclusions.shouldExclude`, il flag `cancelled` già esistente.
- Produce:
  - `struct FileSyncer.PreviewCandidate { let url: URL; let size: Int64 }`
  - `previewSync(from:to:deep:duplicateFilter:)` con `duplicateFilter: (([PreviewCandidate]) -> Set<Int>)? = nil`
  - tupla di ritorno con il campo nuovo `toSkipDuplicates: Int`
  Consumati dai Task 3 e 4.

- [ ] **Step 1: Scrivi il file di test** (~12 test). Copertura minima:
  - **senza `duplicateFilter`**: `toAdd`, `toSkip`, `toAddBytes` identici a oggi su una sorgente mista, e `toSkipDuplicates == 0` (è il test che protegge i tre job che non optano in)
  - **senza `duplicateFilter`**: la closure non viene mai chiamata e nessun array viene costruito — verificabile passando `nil` e asserendo sui soli conteggi; la parte «nessun array» si copre col mutante (vedi sotto)
  - con una closure che restituisce l'insieme vuoto: risultato identico al caso `nil`
  - con una closure che restituisce un indice: `toAdd` scende di 1, `toSkipDuplicates` sale di 1, `toAddBytes` scende **esattamente** della dimensione di quel candidato
  - **invariante**: `toAdd + toSkip + toSkipDuplicates == numero di file esaminati`, su una sorgente con file nuovi, file già a destinazione e doppioni insieme
  - i candidati passati alla closure sono **solo** quelli che sarebbero stati contati in `toAdd`: un file già presente a destinazione (zero-overwrite) **non** compare fra i candidati. È l'ordine dei rami di `syncFile`, e qui va rispettato allo stesso modo
  - i candidati escludono i file filtrati da `LibraryExclusions` e i file nascosti
  - i candidati includono i file nelle sottocartelle, nell'ordine di enumerazione
  - `PreviewCandidate.size` corrisponde alla dimensione reale del file
  - indici **fuori intervallo** restituiti dalla closure vengono ignorati senza crash e senza alterare i conteggi
  - indici **ripetuti** non sottraggono due volte (è un `Set`, ma il test fissa il contratto)
  - `estimatedSec` conta i doppioni insieme ai file da copiare (vedi Step 4)

- [ ] **Step 2: Registra il file in `project.pbxproj`** (4 punti; `grep -n "FileSyncerPreviewBytesTests" AppBackupFoto.xcodeproj/project.pbxproj` per copiare il formato esatto).

- [ ] **Step 3: Verifica il fallimento atteso** — `cannot find type 'PreviewCandidate' in scope` o `extra argument 'duplicateFilter'`. Se il comando non trova affatto la classe di test, la registrazione non ha funzionato: **fermati e segnalalo**.

- [ ] **Step 4: Implementa.**
  - `previewDir`/`previewFile` guadagnano un parametro `candidates: inout [PreviewCandidate]?`. **Quando è `nil` non si alloca e non si appende niente**: è questo, non un `if` a valle, a rendere il default davvero a costo zero. Niente valori di default su questi due, che sono privati — stessa regola già scritta accanto a `syncDir`: un default trasformerebbe una propagazione dimenticata in un cambio di comportamento silenzioso invece che in un errore di compilazione.
  - `previewSync` alloca l'array **solo se** `duplicateFilter != nil`, esegue la camminata, poi chiama la closure una volta sola e sottrae: `for i in indices where candidates.indices.contains(i) { toAdd -= 1; toSkipDuplicates += 1; toAddBytes -= candidates[i].size }`.
  - **`estimatedSec` conta anche i doppioni**: `max(1, (toAdd + toSkipDuplicates) / 50)` quando la somma è > 0. Un doppione costa al job una lettura completa del file sorgente, esattamente come una copia; con la formula di oggi un reimport interamente duplicato mostrerebbe «Tempo stimato: 00:00:00» per un job da tre minuti — cioè avremmo corretto un numero falso e ne avremmo lasciato un secondo. `toSkipDuplicates` è 0 per gli altri chiamanti, quindi la formula non cambia per loro.
  - Doc-comment su `duplicateFilter` che scriva **perché è un lotto e non un predicato per file**: per riconoscere due file identici dentro la stessa sorgente bisogna sapere, prima di hashare il primo, che esiste un secondo file di quella dimensione. Un predicato in streaming non può.
  - Doc-comment su `PreviewCandidate.size` che dica da dove viene la dimensione (la `resourceValues` già presente in `previewFile`, potenzialmente servita dalla cache dell'URL) e che **non decide niente**: è chiave di bucket e stima di byte, a decidere è `sha256` a valle. Vedi il fatto misurato n. 1.
  - Aggiorna l'annotazione di tipo di `ImportView.previewResult` e i riferimenti al nuovo campo. `RestoreEngine.runLocal` usa `preview.toAdd + preview.toSkip` e **non va toccato**: `toSkipDuplicates` è 0 lì.

- [ ] **Step 5: Test verdi.**
- [ ] **Step 6: Build, suite completa, commit** — **515 test attesi** (503 + 12).

**Il mutante che deve morire:**

| Mutante | Test che deve diventare rosso |
| :---- | :---- |
| `toAdd -= 1` rimosso, `toSkipDuplicates += 1` lasciato | l'invariante `toAdd + toSkip + toSkipDuplicates == totale` |
| `toAddBytes -= candidates[i].size` rimosso | il test sui byte sottratti esattamente |
| `candidates.indices.contains(i)` rimosso | il test sugli indici fuori intervallo (deve **crashare**, non passare) |
| il candidato viene raccolto **prima** della guardia zero-overwrite | il test «un file già a destinazione non compare fra i candidati» |
| `estimatedSec` torna a `toAdd / 50` | il test sull'ETA che conta i doppioni |
| `candidates` allocato **sempre** invece che solo con la closure | **equivalente sul risultato** — cambia solo memoria e tempo. Va dichiarato tale nel commit, non silenziato: l'allocazione condizionata è ciò che rende il default a costo zero per i tre job che non optano in, e nessun test può vederlo. |

---

### Task 2: `importPreviewDuplicates` — il motore, e l'hash restituito da `isAlreadyInLibrary`

Indipendente dal Task 1: si può eseguire in parallelo. È il cuore del lavoro e la sola parte dove un errore produce un numero sbagliato.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `BackupRunner`, accanto a `isAlreadyInLibrary` — `grep -n "static func isAlreadyInLibrary"`)
- Create: `AppBackupFotoTests/ImportPreviewDedupTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `FileSyncer.PreviewCandidate` (Task 1 — se il Task 2 parte prima, dichiara il tipo qui e il Task 1 lo trova già fatto), `BackupRunner.isAlreadyInLibrary`, `ImportSessionIndex`, `LibraryIndexStore`, `sha256`.
- Produce:
  - quarto parametro `onSourceHash: (String) -> Void = { _ in }` su `isAlreadyInLibrary`
  - `nonisolated static func importPreviewDuplicates(candidates:store:libraryRoot:isCancelled:onProgress:) -> Set<Int>`
  Consumati dal Task 4.

- [ ] **Step 1: Scrivi il file di test** (~18 test), su file veri in una directory temporanea e su un `LibraryIndexStore` reale, come già fa `ImportDedupTests`. Copertura minima:

  *`onSourceHash`:*
  - viene chiamato con l'hash reale del file sorgente quando lo Stadio 2 è raggiunto
  - **non** viene chiamato quando lo Stadio 1 scarta il file (nessuna dimensione corrispondente): è la prova che il prefiltro fa davvero risparmiare la lettura
  - non viene chiamato per un `.notIndexable`
  - `isAlreadyInLibrary` senza il parametro si comporta identica a prima (il test di regressione che protegge `runImport`)

  *decisione:*
  - un file già in libreria (entry nell'indice **e** file davvero sul disco) ⇒ indice presente nel risultato
  - un file nuovo ⇒ assente
  - **due file di dimensione identica ma contenuto diverso ⇒ entrambi assenti.** È il test che vale più di tutti: la misura dice che il 37-53% delle collisioni di dimensione fra insiemi diversi **non** è un doppione
  - **entry fantasma**: l'indice conosce un hash ma il file non è più sul disco ⇒ **assente** dal risultato (il file verrà copiato, e l'anteprima deve dirlo). È il test che fissa la scelta del livello di fiducia 2 invece del livello 1
  - un `.notIndexable` byte-identico a un altro `.notIndexable` ⇒ entrambi assenti (due sidecar `.AAE` da 0 byte hanno lo stesso SHA256)
  - un candidato dell'indice **fuori dalla root** della libreria ⇒ ignorato, il file conta come nuovo
  - `store == nil` ⇒ nessun errore, solo i doppioni interni vengono rilevati
  - un file sorgente illeggibile ⇒ mai dichiarato doppione

  *doppioni interni alla sorgente:*
  - due file byte-identici nella stessa sorgente ⇒ **esattamente uno** dei due nel risultato, e non il primo in ordine di enumerazione
  - tre file byte-identici ⇒ **due** nel risultato
  - due file byte-identici in **sottocartelle diverse** della stessa sorgente ⇒ uno solo nel risultato
  - due file di dimensione uguale e contenuto diverso nella stessa sorgente ⇒ nessuno dei due

  *progresso e interruzione:*
  - `onProgress` riceve `total` **prima** che venga letto un solo byte, e `total` conta i soli candidati che superano il prefiltro (non tutti i file)
  - `isCancelled` che diventa vero a metà ⇒ ritorna presto, e il risultato è parziale (il test asserisce che è parziale, così nessuno lo scambi per completo)
  - `isCancelled` sempre vero ⇒ nessuna lettura, insieme vuoto

- [ ] **Step 2: Registra il file in `project.pbxproj`** (4 punti; `grep -n "ImportDedupTests" AppBackupFoto.xcodeproj/project.pbxproj` per il formato).

- [ ] **Step 3: Verifica il fallimento atteso** — `cannot find 'importPreviewDuplicates' in scope`.

- [ ] **Step 4: Implementa.** Nell'ordine della sezione «Il motore dell'anteprima» della spec:
  - istogramma delle dimensioni dei candidati ⇒ `sourceRepeatedSizes` (dimensioni con conteggio ≥ 2). Solo memoria, nessun I/O.
  - `ImportSessionIndex` **locale alla chiamata**, mai condivisa con un job.
  - `total` calcolato in un primo giro che chiama **solo** lo Stadio 1 (dimensione), senza hash. Serve alla barra determinata e va calcolato prima, non stimato.
  - giro principale: prefiltro ⇒ `isAlreadyInLibrary(..., session:, onSourceHash:)` ⇒ inserimento o `session.record`.
  - `onProgress` dopo ogni candidato **effettivamente controllato**, non dopo ogni candidato.
  - `isCancelled()` controllato a ogni iterazione, prima della lettura.
  - Doc-comment che dica esplicitamente: **livello di fiducia 2, non 1** (rileggere il candidato sull'SSD è ciò che rende il numero vero in presenza di entry fantasma, che l'indice contiene per decisione di prodotto), e **risultato parziale se interrotto** — chi interrompe deve scartarlo, mai mostrarlo.
  - Doc-comment sul motivo per cui `importPreviewDuplicates` **non** aggiunge query allo store: misurato, 2.000 `hasAnyEntry` costano 9,3 ms totali contro 9,1 ms di un'unica `SELECT DISTINCT size`. Serve a impedire che qualcuno "ottimizzi" reintroducendo una seconda copia della decisione.

- [ ] **Step 5: Test verdi.**
- [ ] **Step 6: Build, suite completa, commit** — **533 test attesi** (515 + 18).

**Il mutante che deve morire:**

| Mutante | Test che deve diventare rosso |
| :---- | :---- |
| `isAlreadyInLibrary` sostituita da un confronto di sole dimensioni | «due file di dimensione identica e contenuto diverso ⇒ entrambi assenti» |
| la rilettura su disco (`fileOnDisk`) rimossa, ci si fida dell'indice | «entry fantasma ⇒ assente dal risultato» |
| `sourceRepeatedSizes` rimosso dal prefiltro | «due file byte-identici nella stessa sorgente ⇒ uno solo nel risultato» |
| `session.record` non chiamato sui non-doppioni | idem sopra (il gemello non verrebbe mai riconosciuto) |
| la guardia `IndexableKind` rimossa dal ramo di sessione | «due sidecar `.AAE` da 0 byte ⇒ entrambi assenti» |
| `total` calcolato come `candidates.count` | «`total` conta i soli candidati che superano il prefiltro» |
| il **prefiltro sull'indice** (`hasAnyEntry`) rimosso, hashando tutto | **equivalente sul risultato**, osservabile solo in tempo. Lo intercetta il test su `onSourceHash` non chiamato allo Stadio 1 — che esiste apposta, ed è l'unico modo di renderlo osservabile. Se un giorno quel test viene indebolito, il prefiltro può sparire in silenzio. |

---

### Task 3: `ImportPreviewStatus` — le righe che il wizard mostra

Logica **pura**: nessun filesystem, nessun database, nessuna View. Stesso ruolo di `LibraryIndexStatus.lines` e `DuplicatesStatus`.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (accanto a `importStartDisabledReason` — `grep -n "func importStartDisabledReason"`)
- Create: `AppBackupFotoTests/ImportPreviewStatusTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produce: `enum ImportPreviewStatus` con
  - `static func unavailableReason(ssdConfigured: Bool, ssdMounted: Bool) -> String?`
  - `static func lines(toAdd: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int) -> [Line]`
  - `static func progressLine(done: Int, total: Int, sourceFileCount: Int) -> String`
  Consumati dal Task 4.

- [ ] **Step 1: Scrivi il file di test** (~10 test). Copertura minima:
  - SSD non configurato ⇒ motivo scritto, e **non** lo stesso di «non collegato»: sono due azioni diverse per l'utente (configurare vs collegare)
  - SSD configurato ma non montato ⇒ motivo scritto, che nomina il collegamento
  - SSD configurato e montato ⇒ `nil`
  - `toSkipDuplicates == 0` ⇒ la riga «Già presenti sull'SSD» **non** compare
  - `toSkipDuplicates > 0` ⇒ compare, con il numero
  - **plurali**: «1 file» / «2 file» concordati su entrambe le righe che portano un numero (stessa disciplina già applicata a `LibraryIndexStatus` il 2026-09-01)
  - `toAdd == 0` con `toSkipDuplicates > 0` ⇒ la coppia di righe si legge come «non c'è niente di nuovo da importare», mai come un silenzio o un errore. È lo scenario del reimport, cioè quello per cui esiste questo lavoro
  - `toAdd == 0` e `toSkipDuplicates == 0` (sorgente vuota) ⇒ riga diversa dalla precedente: «non ho trovato foto» e «le hai già tutte» sono due situazioni opposte, ed è la stessa classe di errore già corretta con `sawNothing` in #31
  - la riga di avanzamento dice **quanti su quanti**, e nomina anche il totale della sorgente quando il denominatore è molto più piccolo (è l'informazione che dice all'utente se aspetterà 3 secondi o 3 minuti)
  - **registro anti-gergo**: nessuna riga contiene «hash», «indice», «SHA256», «dedup», «scansione». Test esplicito su tutte le diramazioni, come `LibraryIndexStatusTests`
  - **`id` stabili** fra due chiamate con gli stessi dati

- [ ] **Step 2: Registra il file in `project.pbxproj`** (4 punti).
- [ ] **Step 3: Verifica il fallimento atteso.**
- [ ] **Step 4: Implementa.** Nessuna stringa duplicata fra qui e la View: se una riga esiste, esiste qui.
- [ ] **Step 5: Test verdi.**
- [ ] **Step 6: Build, suite completa, commit** — **543 test attesi** (533 + 10).

**Il mutante che deve morire:**

| Mutante | Test che deve diventare rosso |
| :---- | :---- |
| i due motivi (non configurato / non montato) unificati in uno | i due test sui motivi distinti |
| la riga «Già presenti» mostrata anche con `toSkipDuplicates == 0` | il test omonimo |
| «sorgente vuota» e «tutto già presente» producono la stessa riga | il test sulle due diramazioni distinte |
| un plurale non concordato | i test sui plurali |

---

### Task 4: `ImportView` — cablaggio, barra determinata, gate SSD montato

Ultimo perché consuma i tre precedenti. **Non coperto da test**, e va dichiarato: stessa disciplina di `LibraryIndexCard` e `DuplicatesView`.

**Prima di eseguirlo servono le risposte alle domande aperte 2 e 4 della spec** (avvio automatico o su richiesta; cosa fa «Interrompi»). Il resto del task non dipende da loro.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`struct ImportView` — `grep -n "struct ImportView"`)

**Interfaces:**
- Consuma: `FileSyncer.previewSync(duplicateFilter:)`, `BackupRunner.importPreviewDuplicates`, `ImportPreviewStatus`, `VolumeMonitor.ssdMounted`, `runner.libraryIndexStore`.
- Produce: niente di riusabile altrove.

- [ ] **Step 1: `@StateObject private var volumes = VolumeMonitor()`** in `ImportView`, come già fanno `ContentView`, `RestoreView` e `DuplicatesView`. Serve a distinguere «SSD non configurato» da «SSD non collegato».

- [ ] **Step 2: `CancelFlag`.** Riusa la classe già presente (`grep -n "final class CancelFlag"`): è `private` a livello di file, quindi è già visibile. **Non scriverne una seconda** — è la lezione di `LibraryExclusions`/`realResolvedPath`/`makeThumbnail`, pagata tre volte. Se il compilatore si lamenta della visibilità, il rimedio è spostarla, non duplicarla.

- [ ] **Step 3: Aggancia l'anteprima vera in `pickSource()`.** Il `Task` esistente diventa:
  - se `ImportPreviewStatus.unavailableReason(...)` non è `nil` ⇒ mostra il motivo, nessun numero, nessuna lettura;
  - altrimenti chiama `previewSync(..., duplicateFilter: { candidates in BackupRunner.importPreviewDuplicates(candidates: candidates, store: runner.libraryIndexStore, libraryRoot: bm.urls[.ssd], isCancelled: { flag.isCancelled }, onProgress: { d, t in Task { @MainActor in ... } }) })`.
  - La closure gira **sulla coda di lavoro di `previewSync`**, non sul MainActor: qualunque cosa tocchi lo stato della View deve passare da `await MainActor.run` / `Task { @MainActor in }`. Stessa regola di `DuplicatesView` e di `BackupRunner.indexedFileCount`.
  - `libraryRoot` passata **esplicita** da `bm.urls[.ssd]`, letta sul MainActor **prima** di entrare nel `Task`: `urls` è `@Published` e leggerla da un thread di background è il difetto che `isAlreadyInLibrary` ha già chiuso una volta col parametro `libraryRoot`.

- [ ] **Step 4: Token di richiesta.** L'utente può tornare indietro e scegliere un'altra sorgente mentre l'anteprima gira. Al ritorno del `Task`, scarta il risultato se il token non è più quello corrente — pattern già in uso in `DuplicateGroupRow` per le miniature, che esiste perché `Task.detached`/le closure di lavoro non ereditano la cancellazione della View. **Un risultato interrotto non va mai mostrato**: è parziale per costruzione.

- [ ] **Step 5: Barra determinata + «Interrompi»** nel passo `.preview`, con il testo di `ImportPreviewStatus.progressLine`. «Interrompi» alza il `CancelFlag` **e** chiama `previewSyncer.cancel()` (l'interruzione della camminata e quella della fase di hashing sono due meccanismi distinti: il primo è dentro `FileSyncer`, il secondo è nella closure, e servono entrambi).

- [ ] **Step 6: Le righe** del passo `.preview` vengono da `ImportPreviewStatus.lines`, nessuna stringa scritta nella View.

- [ ] **Step 7: `runImport` — una parola sola.** Nell'alert «Spazio insufficiente sull'SSD», «Servono circa X» diventa «Servono **al massimo** circa X». Il controllo resta **senza dedup**, di proposito: vuole un limite superiore, e renderlo esatto costerebbe una terza lettura completa della sorgente per rendere *meno* conservativa una guardia di sicurezza. Aggiungi un commento accanto che lo dica, altrimenti il prossimo lettore lo prenderà per la svista che questo piano ha appena corretto altrove.

- [ ] **Step 8: Dichiara ciò che non è testato**, in un commento su `ImportView`: questa View, la barra, il bottone «Interrompi», il gate `VolumeMonitor`. Sono SwiftUI e volumi veri, non raggiungibili senza una corsa. **È testato tutto ciò che sta ai due capi del cablaggio.**

- [ ] **Step 9: Build, suite completa, commit** — **543 test**, invariati. Se il numero cambia, qualcosa si è rotto altrove.

**Verifica manuale obbligatoria** (nessuno di questi punti è raggiungibile da un test):
1. Scheda/cartella **nuova** ⇒ l'anteprima resta rapida e il numero coincide con quello copiato a fine job.
2. **Stessa** sorgente reimportata ⇒ l'anteprima dice 0 (o solo i non-media), la barra si muove, e `CompletionSheet` a fine job concorda.
3. «Interrompi» a metà ⇒ nessun numero mostrato, nessun crash, l'app resta usabile.
4. SSD scollegato a wizard aperto ⇒ compare il motivo scritto, non un numero sbagliato.
5. Anteprima avviata **mentre l'aggiornamento dell'elenco è in corso** ⇒ nessun blocco della finestra (è il vincolo sulla coda seriale dello store).
6. **Misura la velocità di lettura della sorgente vera** e riportala in `architecture.md`: è l'assunzione non verificata di questa spec.

---

### Task 5: Documentazione — dove va scritto cosa

**Files:**
- Modify: `.claude/rules/architecture.md`
- Modify: `Docs/adr/0003-due-livelli-di-fiducia-sullo-stesso-indice.md`
- Modify: `Docs/superpowers/plans/2026-09-01-import-preview-dedup.md` (esiti, conteggi reali, mutanti sopravvissuti)

- [ ] **Step 1: `architecture.md`.** Nella sezione «Il dedup entra in `FileSyncer` senza toccare i job esistenti», **sostituisci** la frase «Nota nota e accettata: `previewSync` non è allineato e sovrastima lo spazio necessario quando la sorgente contiene doppioni — verso sicuro»: non è più vera per il wizard, e lasciarla lì manderebbe fuori strada. Al suo posto: `previewSync` ha un `duplicateFilter` opzionale; lo passa **solo** il wizard; il controllo di spazio di `runImport` continua di proposito a usare il limite superiore, **e perché**.

- [ ] **Step 2: `architecture.md`, fatti misurati.** Aggiungi i numeri del 2026-09-01: 34.513 dimensioni distinte su 47.482 media (72,7%), collisione fra cartelle non-doppione **sotto l'1%** con il rihash che lo dimostra (40/40 e 39/40 byte-identici sulle coppie sopra il 25%, 7/19 e 21/40 su quelle sotto l'1%), doppioni interni al 2,7% su `Foto iPhone` e 36,0% su `Foto Google Drive`, lettura+SHA256 dall'SSD a 279-616 MiB/s, e **2.000 `hasAnyEntry` = 9,3 ms contro 9,1 ms di una `SELECT DISTINCT size`**. Quest'ultimo è il fatto che impedisce a un futuro «ottimizziamo con una query sola» di ripartire da zero.

- [ ] **Step 3: ADR-0003, nota nuova.** «L'anteprima dell'import sta al livello 2, non al livello 1», con l'argomento delle entry fantasma: l'indice contiene per decisione di prodotto file che sul disco non ci sono più (`vanishedKept`), quindi la fiducia di livello 1 produrrebbe un numero **sotto**-promettente — l'errore opposto a quello appena corretto. E la contro-domanda per chi vorrà togliere la rilettura, sul modello di ADR-0005.

- [ ] **Step 4: ADR-0003, seconda nota.** «Gli hash calcolati per l'anteprima non vengono riusati dall'import», con il costo che si accetta (~78 s in più su una scheda da 7 GiB) e il motivo: fra i due momenti passa un passo del wizard, l'utente può cambiare scheda, e non esiste un controllo di identità del volume fra i due. È il caso «X» che la regola «si rilegge sempre» esiste per non dover ricordare.

- [ ] **Step 5: Aggiorna questo piano** con i conteggi reali, i mutanti sopravvissuti e gli esiti della verifica manuale.

- [ ] **Step 6: Commit.** Nessun test nuovo.

---

## Riepilogo dei conteggi

| Task | Test nuovi | Cumulativo atteso |
| :---- | ---: | ---: |
| baseline `main` | — | **503** (da riverificare) |
| Task 1 — `previewSync(duplicateFilter:)` | 12 | 515 |
| Task 2 — `importPreviewDuplicates` | 18 | 533 |
| Task 3 — `ImportPreviewStatus` | 10 | 543 |
| Task 4 — `ImportView` | 0 (dichiarato) | 543 |
| Task 5 — documentazione | 0 | 543 |

## Nota sull'ordine dei task

Il Task 2 è il più rischioso e il più indipendente: se qualcosa deve rompersi, conviene che si rompa lì, prima che il Task 4 lo cabli. I Task 1 e 2 non si toccano e possono andare in parallelo, a patto che chi arriva primo dichiari `FileSyncer.PreviewCandidate`. Il Task 3 non dipende da nessuno dei due. Il Task 4 dipende da tutti e tre **e** da due risposte di Enrico.
