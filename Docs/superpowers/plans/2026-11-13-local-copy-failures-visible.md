# I file che una copia locale non ha copiato si vedono — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: approvato da Enrico il 2026-11-13 (D1 = A, D2 = A, D3 = A, vedi ADR-0020).** ROADMAP #49.

**Base:** `fix/s3-upload-failures-visible` a `19db05d` (#43 non è ancora su `main`), branch nuovo `fix/local-copy-failures-visible` (D3).

**Goal:** dopo un Mac → SSD, SSD → HDD o Importa con errori, Enrico sa quali file non sono stati copiati e perché: ogni file lascia una riga col motivo, il riepilogo li elenca (max 8 + «…e altri N»), l'elenco completo va in fondo al registro in `~/Library/Logs/AppBackupFoto/`.

**Architecture:** due tipi puri nuovi (`LocalCopyText`, `LocalCopySummary`), quattro membri nuovi su `FileSyncer.SyncResult`, un campo su `JobStats`. In `FileSyncer.syncFile` cambiano SOLO il corpo del `catch`, il ramo del mismatch e le due copie inviate al progresso; `syncDir`/`syncFile` ricevono il percorso relativo. **Nessun comportamento di copia cambia.** Nessuna riga cambia in `S3Syncer`, `S3UploadText`, `UploadFailureSummary`, `JobLogFile`, `RestoreEngine`.

**Tech Stack:** Swift 5.x, isolamento MainActor di default, SwiftUI, XCTest. Nessuna dipendenza nuova.

| Task | Cosa | Test nuovi | Totale atteso |
| :--- | :--- | :--- | ---: |
| 0 | branch, ADR-0020, piano | — | — |
| 1 | baseline | — | **1.477** |
| 2 | `LocalCopyText` | `LocalCopyTextTests` **nuovo** +23 | **1.500** |
| 3 | `SyncResult`: elenco, due punti di registrazione, `progressSnapshot` | `LocalCopyTextTests` +3 | **1.503** |
| 4 | cablaggio in `FileSyncer.syncFile` | `FileSyncerFailedCopiesTests` **nuovo** +10, `MainThreadIsolationTests` +1 | **1.514** |
| 5 | `LocalCopySummary`, `JobStats`, `finishCopyStep`, `CompletionSheet` | `LocalCopyTextTests` +8 | **1.522** |
| 6 | mutation testing (copia nello scratch) | — | — |
| 7 | documentazione | — | — |
| 8 | verifica dal vivo (Enrico) | — | — |

**Conteggio finale atteso: 1.522** (1.477 + 45: 40 del piano + 5 dell'allineamento alla tabella dell'ADR, Task 2). Fascia ammessa solo con test in più chiesti da un revisore e dichiarati nel commit: 1.522–1.532.

**Due file di test nuovi**, registrati a mano in `AppBackupFoto.xcodeproj/project.pbxproj` nei 4 punti (`PBXBuildFile`, `PBXFileReference`, figli del gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`), accanto alle righe di `S3UploadTextTests.swift` (`DC2CC96B22A4D122F6F6E4CE` / `F901D97C39FFEDA58D187B40`). ID controllati assenti il 2026-11-13:

| File | `PBXBuildFile` | `PBXFileReference` |
| :--- | :--- | :--- |
| `LocalCopyTextTests.swift` | `AEEB14414B517F69BAD8E045` | `635D798B96BD62D040CB88F9` |
| `FileSyncerFailedCopiesTests.swift` | `6232D0E79307D96CCF0CEB4A` | `C15AE6A68B2D49F478DE2901` |

Dopo: `plutil -lint` OK e `grep -c` = 4 per ciascun file. Ai punti di controllo si legge `Executed N tests` di `xcodebuild`, mai il solo `** TEST SUCCEEDED **`.

## Comandi di build e test

Come nel piano `2026-09-26-s3-upload-failures-visible.md`, sezione «Comandi di build e test». Il prototipo e `fasttest.sh` di allora non esistono più in `/private/tmp`: nel Task 0 si ricrea `fasttest.sh` col testo del piano `2026-10-05-certified-duplicates-ssd.md` («Comandi di build e test»), con `REPO=${REPO:-/Users/enriconannivicenzi/Desktop/AppBackupFoto}` e `SP=${SP:-/private/tmp/claude-501/local-failures/fast}`, salvato in `/private/tmp/claude-501/local-failures/fasttest.sh` (mai nel repository). Verifica veloce a ogni task; `xcodebuild` in background, solo dall'orchestratore, alla fine dei Task 2, 4 e 5, con la precondizione «nessun backup in corso nell'app» chiesta a Enrico.

## Regole valide per tutti i task

1. Codice trovato con `grep -n`, mai col numero di riga.
2. Zero warning (in Debug `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`). Un warning `actor-isolated`: fermati e rimanda all'Architect.
3. **Regola assoluta.** Nessun diff aggiunge, sposta o toglie `copyItem`/`moveItem`/`removeItem`/`trashItem`/`createDirectory`/`fileExists`. A fine di ogni task: `grep -c` nel sorgente dà `copyItem(` 2, `removeItem(` 10, `moveItem(` 16, `trashItem(` 2, `createDirectory(` 14, `httpMethod = "DELETE"` 3. In `syncFile` restano identici l'ordine fra zero-overwrite e `isDuplicate`, la creazione della cartella genitore, `copyItem`, le due chiamate a `hashFunction`, `onCopied`, `onUnverified`, il ramo `copiedUnverified`.
4. Asserzioni esistenti: nessuna cambia. Nei file esistenti si aggiunge solo in coda alla classe (`MainThreadIsolationTests`).
5. Testi a schermo solo nei tipi puri. Niente gergo: lo controlla `LocalCopyTextTests.assertNoJargon`, con la lista di `S3UploadTextTests.jargon` più `posix, errno, cocoa, copyitem, filemanager, hash, sha, mismatch, overwrite, skip, enospc, eacces, eperm, enoent`. «SSD», «HDD», «macOS», «Accesso completo al disco» vanno bene.
6. Revisione a ogni task (ciclo in due fasi di `Docs/CLAUDE.md`); **Security/Rules Auditor obbligatorio sul Task 4.** Un commit per task, in italiano, con le righe di attribuzione della sessione; mai `git push`.

---

### Task 0: branch, ADR, piano

- [ ] **Step 1:** `git status --short` vuoto; `git switch -c fix/local-copy-failures-visible fix/s3-upload-failures-visible`; `git rev-parse --short HEAD` → `19db05d` o un suo discendente. Se è un discendente con modifiche a `FileSyncer`, `CompletionSheet` o `finishCopyStep`, fermati e rimanda all'Architect.
- [x] **Step 2:** ADR-0020 scritto, «Accettata (2026-11-13)», con le risposte D1-D3 in fondo.
- [ ] **Step 3:** ricrea `fasttest.sh` (sezione Comandi). Commit di sola documentazione.

### Task 1: baseline

- [ ] `fasttest.sh` → `Executed 1477 tests, with 0 failures`, 0 warning. Se il numero è diverso, B = quello misurato e tutti gli attesi si spostano della differenza.
- [ ] Via libera da Enrico, poi `xcodebuild` in background: 1.477, 0 warning. Nessun commit.

### Task 2: `LocalCopyText`, i motivi in parole

**File:** `ContentView.swift`, subito DOPO la chiusura di `enum UploadFailureSummary` e PRIMA di `// MARK: - S3Syncer (native Swift, no rclone subprocess)`; `AppBackupFotoTests/LocalCopyTextTests.swift` (nuovo, pbxproj).

- [ ] **Step 1 (test prima, rossi in compilazione):** `final class LocalCopyTextTests: XCTestCase` con `static let jargon = S3UploadTextTests.jargon + [...]`, `assertNoJargon` e un aiuto `cocoa(_ code: Int, posix: Int?) -> NSError` (`NSCocoaErrorDomain`, `NSUnderlyingErrorKey` = `NSError(domain: NSPOSIXErrorDomain, code: posix)`). I 18 test (più 5 aggiunti in coda con l'allineamento alla tabella dell'ADR, «Vocabolario dei motivi»: `testReason_fileTooBig`, `testReason_illegalCharacters`, `testReason_nameTooLongCocoaAlone`, `testReason_otherReadError`, `testReason_otherWriteError`; entrano anche in `testReason_everyReasonHasNoJargon_andACode`):
  - `testReason_diskFull` — (640, 28): contiene «pieno» e finisce con «(codice 640/28)»
  - `testReason_diskFull_withoutUnderlying` — (640, nil): «pieno», «(codice 640)»
  - `testReason_posixErrorAlone` — `NSError(domain: NSPOSIXErrorDomain, code: 28)`: «pieno», «(codice 28)»
  - `testReason_permissionDenied` — (513, 13): «permesso negato», «leggere il file o scrivere nella cartella di destinazione», «(codice 513/13)»
  - `testReason_notPermittedByMacOS` — (513, 1): «Accesso completo al disco», NON «permesso negato» (il codice di sistema decide prima di quello Cocoa)
  - `testReason_vanished` — (260, 2): «non c'è più»
  - `testReason_vanishedCocoa4` — (4, nil): «non c'è più», «(codice 4)»
  - `testReason_alreadyAtDestination` — (516, 17): «non è stato sovrascritto»
  - `testReason_readOnlyDisk` — (642, 30): «sola lettura»
  - `testReason_nameTooLong` — (514, 63): «troppo lungo»
  - `testReason_parentIsAFile` — (512, 20): «al posto di una cartella»
  - `testReason_ioError` — (512, 5): «lettura o scrittura»
  - `testReason_diskNotResponding` — (512, 6): «non risponde»
  - `testReason_unknownError_neverShowsTheDomain` — `NSError(domain: "XYZ", code: 77)`: «errore imprevisto (codice 77)», non contiene «XYZ»
  - `testReason_everyReasonHasNoJargon_andACode` — tutti i casi sopra: niente gergo e contengono «(codice »
  - `testFailedLine_saysPathAndReason_andPromisesNothing` — `failedLine(path: "sub/a.jpg", reason: "r")` == «Non copiato: «sub/a.jpg» — r.»; non contiene «riprov»
  - `testMismatchLine_saysPathAndThatItIsNotRedone` — contiene ««sub/a.jpg»», «non è identica all'originale», «non la rifà da sola»; niente gergo
  - `testRelativeChild` — `("", "a.jpg")` → «a.jpg»; `("a b/c", "x é.jpg")` → «a b/c/x é.jpg»
- [ ] **Step 2:** registra `LocalCopyTextTests.swift` nei 4 punti del pbxproj.
- [ ] **Step 3 (codice):** `nonisolated enum LocalCopyText` (commento: puro, lo chiama `syncFile` dalla coda di fondo):
  - `static func reason(for error: Error) -> String`: la tabella dell'ADR. Prima il codice POSIX (`NSUnderlyingErrorKey` di dominio `NSPOSIXErrorDomain`, oppure l'errore stesso se POSIX), poi il codice Cocoa; codice «(codice C/P)» o «(codice N)».
  - `static let mismatchReason = "la copia appena fatta non è identica all'originale"`
  - `static func failedLine(path:reason:)`, `static func mismatchLine(path:)`, `static func relativeChild(of parent: String, name: String) -> String`.
  - Doc-comment: le misure del 2026-11-13 (stesso 513/13 sui due lati, nessuna copia parziale col disco pieno, i casi non misurati) e il motivo per cui la riga non promette niente.
- [ ] **Step 4:** `fasttest.sh LocalCopyTextTests` → 23; `fasttest.sh` → **1.500**, 0 warning. **Controllo `xcodebuild`**: 1.500 (1.477 = file non registrato). Commit.

### Task 3: l'elenco in `SyncResult`

**File:** `ContentView.swift` (`FileSyncer.SyncResult`), `LocalCopyTextTests.swift` (in coda).

- [ ] **Step 1 (test):**
  - `testRecordCopyFailure_countsAndRemembers` — `errors == 1`, `failedCopies == [FailedFile(path: "a", reason: "r")]`, `hashErrors == 0`
  - `testRecordCopyMismatch_countsAsHashErrorAndRemembers` — `hashErrors == 1`, `errors == 0`, reason == `LocalCopyText.mismatchReason`
  - `testProgressSnapshot_dropsOnlyTheList` — dopo due registrazioni: snapshot con `failedCopies` vuoto e `errors`/`hashErrors`/`done`/`total`/`copied` uguali; l'originale ha ancora 2 voci
- [ ] **Step 2 (codice):**
  - `var failedCopies: [FailedFile] = []`, con doc-comment: copie locali (ROADMAP #49), `failedFiles` resta di Cubbit; percorso relativo alla sorgente del job.
  - `mutating func recordCopyFailure(path: String, reason: String)` (`errors += 1` + append).
  - `mutating func recordCopyMismatch(path: String)` (`hashErrors += 1` + append con `mismatchReason`).
  - `var progressSnapshot: SyncResult` (copia con `failedCopies = []`; doc-comment: evita di ricopiare l'elenco a ogni file).
  - Aggiorna il doc-comment di `failedFiles`: «FileSyncer usa `failedCopies` (ADR-0020)».
- [ ] **Step 3:** `fasttest.sh` → **1.503**. Commit.

### Task 4: cablaggio in `FileSyncer.syncFile`

**File:** `ContentView.swift` (`FileSyncer.sync`/`syncDir`/`syncFile`), `AppBackupFotoTests/FileSyncerFailedCopiesTests.swift` (nuovo, pbxproj), `MainThreadIsolationTests.swift` (in coda).

- [ ] **Step 1 (test prima):** `FileSyncerFailedCopiesTests`, cartelle temporanee proprie come `FileSyncerHashVerificationTests`; il `tearDown` rimette `0755` prima di rimuovere.
  1. `testUnwritableDestinationFolder_isListedWithPathAndReason` — `src/sub/a.jpg`, `dst/sub` creata con `0555`: `errors == 1`, `failedCopies.count == 1`, `path == "sub/a.jpg"`, motivo con «permesso negato»; la sorgente esiste ancora con lo stesso contenuto.
  2. `testUnwritableDestinationFolder_writesALogLine` — fra le righe di `onStatus` (raccolte con una `XCTestExpectation` dopo il ritorno) ce n'è una che comincia con «Non copiato: «sub/a.jpg» — permesso negato».
  3. `testDestinationAppearingBeforeTheCopy_isNeverOverwritten_andIsListed` — `isDuplicate` scrive `dst/a.jpg` = «preesistente» e restituisce `false`: il contenuto di `dst/a.jpg` è ancora «preesistente» byte per byte, `copied == 0`, motivo con «non è stato sovrascritto». (È anche una prova di zero-overwrite: il controllo di esistenza perde la corsa, `copyItem` rifiuta.)
  4. `testSourceVanishedBeforeTheCopy_isListed` — `isDuplicate` cancella la sorgente (file di test) e restituisce `false`: motivo con «non c'è più», `path == "a.jpg"`.
  5. `testHashMismatch_isListedWithPath_andCountsAsHashError` — `hashFunction` come in `testRealMismatch_…`, file `sub/a.jpg`: `hashErrors == 1`, `errors == 0`, una voce con `mismatchReason` e `path == "sub/a.jpg"`; la riga di stato contiene «Copia non identica: «sub/a.jpg»».
  6. `testRelativePath_isRightThroughTheVarLink_andWithUnicode` — `src/a b/c/x é.jpg`, `dst/a b/c` con `0555`: `path == "a b/c/x é.jpg"` (la cartella temporanea è `/var/…`, il listing dà `/private/var/…`: è il fatto misurato).
  7. `testCountersAndList_alwaysAgree` — un fallimento per permessi più un mismatch più un file copiato: `failedCopies.count == errors + hashErrors` e `copied + skipped + errors + hashErrors + copiedUnverified == done`.
  8. `testProgressUpdates_neverCarryTheList` — `FileSyncer(progressIntervalNanos: 0)`, due file che falliscono: ogni `SyncResult` ricevuto da `onProgress` ha `failedCopies` vuoto, il risultato restituito ne ha 2.
  9. `testSuccessfulSync_hasEmptyList` — `failedCopies` vuoto, `errors == 0`.
  10. `testLocalFailures_neverFillTheCubbitList` — dopo il caso 1, `failedFiles` è vuoto.
  - In coda a `MainThreadIsolationTests`: `testLocalCopyText_runsWithoutTheMainThread`, stesso schema di `testJobLogFile_writesWithoutTheMainThread` (`Task.detached` che chiama `reason(for:)`, `failedLine`, `mismatchLine`; semaforo con 5 s).
- [ ] **Step 2:** registra `FileSyncerFailedCopiesTests.swift` nei 4 punti.
- [ ] **Step 3 (codice, solo questo):**
  - `syncDir` riceve `relativeDir: String` e `syncFile` riceve `relativePath: String`, senza default, come gli altri parametri privati. `sync` passa `relativeDir: ""`. In `syncDir`, `let rel = LocalCopyText.relativeChild(of: relativeDir, name: item.lastPathComponent)` va alla ricorsione e a `syncFile`. `base` resta.
  - Ramo mismatch: `result.hashErrors += 1` + riga «HASH MISMATCH» diventano `result.recordCopyMismatch(path: relativePath)` + `let line = LocalCopyText.mismatchLine(path: relativePath)` + `DispatchQueue.main.async { onStatus(line) }`.
  - `catch`: `let reason = LocalCopyText.reason(for: error); result.recordCopyFailure(path: relativePath, reason: reason); let line = LocalCopyText.failedLine(path: relativePath, reason: reason); DispatchQueue.main.async { onStatus(line) }`.
  - Le due copie durante il lavoro (quella prima della riga «Copia (…)» e quella dopo `result.done += 1`) diventano `let snap = result.progressSnapshot`. Le due finali in `sync` restano `let snap = result`.
- [ ] **Step 4:** rileggi il diff: nessuna altra riga di `syncFile`/`syncDir` è cambiata; `grep -c` della regola 3 invariati; `grep -n "result.errors += 1\|hashErrors += 1" ContentView.swift` → nessuna occorrenza dentro `FileSyncer` (restano solo in `recordCopyFailure`/`recordCopyMismatch`/`recordFailure`).
- [ ] **Step 5:** `fasttest.sh FileSyncerFailedCopiesTests` → 10; `fasttest.sh` → **1.514**, 0 warning. **Controllo `xcodebuild`**: 1.514 (1.504 = `FileSyncerFailedCopiesTests` non registrato). Devono restare verdi senza modifiche `FileSyncerZeroOverwriteTests`, `FileSyncerChangedSkippedTests`, `FileSyncerHashVerificationTests`, `ImportDedupTests`, `FileSyncerProgressThrottleTests`.
- [ ] **Step 6: Security/Rules Auditor obbligatorio:** (1) zero-overwrite di `syncFile` invariato riga per riga; (2) nessuna operazione FileManager nuova o spostata (conteggi); (3) `LocalCopyText` è `nonisolated` e non tocca il disco; (4) il test 3 prova che una destinazione comparsa dopo il controllo non viene sovrascritta. Commit, con una riga per l'Auditor.

### Task 5: riepilogo e fondo del registro

**File:** `ContentView.swift` (`LocalCopySummary` subito dopo `LocalCopyText`, `JobStats`, `BackupRunner.finishCopyStep`, `CompletionSheet`), `LocalCopyTextTests.swift` (in coda).

- [ ] **Step 1 (test):**
  - `testHeadline_failedOnly` — 1 → «1 file non copiato», 3 → «3 file non copiati»
  - `testHeadline_mismatchedOnly` — «1 copia non identica all'originale» / «2 copie non identiche all'originale»
  - `testHeadline_both` — (2, 1) → «2 file non copiati e 1 copia non identica all'originale»
  - `testReassurance_dependsOnWhatHappened` — solo falliti: una riga con «originali non sono stati toccati» e «mancano ancora»; solo non identiche: una riga con «non sovrascrive mai»; entrambi: le due righe
  - `testVisibleLines_sameRuleAsCubbit` — uguale a `UploadFailureSummary.visibleLines(_, limit: 8)` su 10 voci
  - `testLogLines_listEveryFile_noLimit` — 20 voci: 21 righe, la prima finisce con «— elenco completo:», le altre «  percorso — motivo»
  - `testLogLines_empty_isEmpty`
  - `testAllSummaryTexts_haveNoJargon`
- [ ] **Step 2 (codice):**
  - `nonisolated enum LocalCopySummary` con `headline(failed:mismatched:)`, `reassurance(failed:mismatched:) -> [String]`, `visibleLines(_:limit:)` (delega a `UploadFailureSummary.visibleLines`), `whereIsTheFullList` (= `UploadFailureSummary.whereIsTheFullList`), `logLines(_:failed:mismatched:)`. Testi:
    - «Gli originali non sono stati toccati: il prossimo backup riprova da solo i file che a destinazione mancano ancora.»
    - «Le copie non identiche restano come sono: l'app non sovrascrive mai, quindi non le rifà da sola. Vanno controllate a mano.» (D2 = A)
  - `JobStats.failedCopies: [FailedFile] = []` (doc: non persistito, come `failedFiles`).
  - `finishCopyStep`: `stats.failedCopies = r.failedCopies` accanto a `stats.failedFiles`; `failureList = UploadFailureSummary.logLines(stats.failedFiles) + LocalCopySummary.logLines(stats.failedCopies, failed: stats.errors, mismatched: stats.hashErrors)`; resta una sola `append`.
  - `CompletionSheet`: sezione nuova `if !stats.failedCopies.isEmpty`, stessa forma di quella di Cubbit (titolo con icona in `AppColor.warning`, righe di rassicurazione, 8 righe `.caption` `.lineLimit(1)` `.truncationMode(.middle)`, `id: \.offset`, «L'elenco completo…»). La riga «N hash mismatch — controlla il log» si vede solo se `stats.failedCopies.isEmpty`; la riga generica solo se `stats.errors > 0 && stats.failedFiles.isEmpty && stats.failedCopies.isEmpty`.
- [ ] **Step 3:** `fasttest.sh` → **1.522**, 0 warning. **Controllo `xcodebuild`**: 1.522, `TEST SUCCEEDED`. Dichiara nel commit: la sezione SwiftUI e `finishCopyStep` non sono coperti da test (li copre il Task 8). Commit.

### Task 6: mutation testing (copia nello scratch, mai il repository)

Ogni mutante deve risultare UCCISO:
- 2a: 28 tradotto come «permesso negato» → `testReason_diskFull`
- 2b: decide prima il codice Cocoa → `testReason_notPermittedByMacOS`
- 2c: solo il codice esterno → `testReason_diskFull`
- 2d: `relativeChild` con «/» iniziale alla radice → `testRelativeChild`
- 2e: `LocalCopyText` senza `nonisolated` → warning (build rossa) e `testLocalCopyText_runsWithoutTheMainThread`
- 3a: `recordCopyFailure` senza `errors += 1` → test 3/7
- 3b: `progressSnapshot` che non svuota → `testProgressSnapshot` e test 8
- 4a: `catch` tornato a `errors += 1` → test 1/2
- 4b: `relativePath = item.lastPathComponent` → test 1/6
- 4c: copie durante il lavoro con `result` → test 8
- 4d: mismatch senza elenco → test 5
- 5a: plurale invertito; 5b: `logLines` con un limite; 5c: rassicurazione senza la riga sulle copie non identiche

Equivalente dichiarato: 5d, `LocalCopySummary` senza `nonisolated` (chiamata solo dal main).

### Task 7: documentazione

- [ ] `.claude/rules/architecture.md`, sezione `FileSyncer`: voce nuova (ogni file non copiato e ogni copia non identica lascia una riga e finisce in `failedCopies`; due soli punti; percorso relativo costruito cartella per cartella, con il fatto `/private/var`; `progressSnapshot`; motivi da `LocalCopyText` con codice/codice; le misure del 2026-11-13; cosa non è coperto da test).
- [ ] `.claude/rules/bug-history.md`: in coda a BUG-11 «stesso buco nelle copie locali chiuso da ADR-0020», senza un BUG nuovo.
- [ ] `Docs/ROADMAP.md` #49: «⏳ implementato il …, verifica dal vivo da fare», correggendo «`failedFiles` già pronto» in «elenco a parte `failedCopies`, ADR-0020»; non ✅ prima del Task 8.
- [ ] `Docs/CLAUDE.md`: righe «Mac → SSD» e «SSD → HDD» (elenco dei file non copiati e dei motivi); riga «Test automatici» (1.477 → 1.522 misurati; `LocalCopyTextTests` (34) e `FileSyncerFailedCopiesTests` (10) nuovi, `MainThreadIsolationTests` +1); undicesimo tocco in «Stato attuale» con le righe toccate.
- [ ] Commit solo documentazione.

### Task 8: verifica dal vivo (Enrico, SSD collegato, app compilata da questo branch)

Si fa insieme al Task 10 del piano #43, stessa build.
1. Sul Desktop crea la cartella `prova-49` con 3 screenshot nuovi (contenuti mai visti dall'app, altrimenti l'import li salta come doppioni). Nel Terminale: `chmod 000 ~/Desktop/prova-49/<uno dei tre>`.
2. Hamburger → Importa foto → `prova-49`, etichetta «prova 49». Atteso:
   - 2 copiati, 1 errore;
   - nella scheda Log la riga «Non copiato: «<nome>» — permesso negato: … (codice 513/13).»;
   - il riepilogo dice «1 file non copiato», «Gli originali non sono stati toccati…» e il nome del file.
3. In `~/Library/Logs/AppBackupFoto/`, l'ultimo `backup_….log` contiene la riga con l'orario e, in fondo, «1 file non copiato — elenco completo:».
4. `chmod 644 ~/Desktop/prova-49/<lo stesso>` e rifai l'import con la stessa etichetta: 1 copiato, 2 saltati, 0 errori, nessuna sezione «non copiato».
5. *(regressione)* Dopo un SSD → Cubbit con errori, il riepilogo dice ancora «non caricati su Cubbit».
6. I 3 screenshot restano in `SSD/Import/prova-49/`: l'app non li toglie mai, Enrico può toglierli a mano dal Finder prima del prossimo SSD → HDD. Nota: nasce `Import/`, che sull'SSD oggi non esiste.

Non provabili dal vivo, coperti dai test: copia non identica, disco pieno, destinazione comparsa durante la copia.

## Rischi

- Migliaia di righe con un disco pieno: frequenza al massimo doppia rispetto a oggi; il registro le tiene tutte.
- `progressSnapshot` dimenticato in un punto futuro: il costo torna a crescere col quadrato a migliaia di errori; lo prende il test 8.
- La riga «HASH MISMATCH» sparisce: chi la cercava nei vecchi registri trova «Copia non identica».

## Fuori scope (dichiarato)

- Ripristino guidato (`RestoreEngine.runLocal`).
- Gli attributi non leggibili contati come «cambiati».
- I file ignorati quando `resourceValues` restituisce `nil`.
- Fermare il job al disco pieno.
- Le copie che nascono bloccate quando la sorgente è bloccata.
