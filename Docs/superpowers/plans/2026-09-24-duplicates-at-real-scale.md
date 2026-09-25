# Il pannello Doppioni alla scala reale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: BOZZA — in attesa dell'approvazione esplicita di Enrico.** Nessuna riga di codice scritta. Spec: `Docs/superpowers/specs/2026-09-24-duplicates-at-real-scale-design.md`. ADR: `0011`, `0012`, `0013` (scritti come **Proposta**; diventano *Accettata* nel Task 0, dopo l'approvazione).

**Base:** `main` **dopo** il merge di ROADMAP **#41** (`Docs/superpowers/plans/2026-09-20-trash-progress-survives-window-close.md`). Se #41 non è ancora stato eseguito, **fermati e rimanda all'Architect**: questo piano concatena blocchi per decine di minuti, e senza #41 barra e «Interrompi» sparirebbero chiudendo la finestra (spec §3.6, domanda 1 di §11).

**Goal:** il pannello Doppioni diventa usabile su 27.798 gruppi e 89.541 copie in eccesso. Filtri per cartella e per tipo di gruppo, «Seleziona tutti quelli visibili», una regola «tieni in X, cestina in Y…» che entra dentro l'unica scelta esistente; il tetto del blocco sale a 2.000 file e i blocchi si concatenano in una corsa con progresso, «Interrompi» e un resoconto unico; prima di un'importazione l'app dice da quando l'elenco delle foto sull'SSD non viene rimesso in pari e offre di aggiornarlo.

**Architecture:** cinque tipi puri nuovi (`DuplicateFolderRule`, `DuplicateFilter`, `DuplicateRunPlan`, `LibraryListFreshness`, più `TrashHistory` che è `nonisolated` con stato e lock). `duplicateKeepChoice` guadagna un parametro **senza default**; `DuplicateBatch` guadagna un costruttore che non ricalcola la scelta; `DuplicateTrasher` **non cambia di una riga**; `BackupRunner` orchestra la corsa. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` resta.

**Tech Stack:** Swift 5.x, isolamento MainActor di default, *Approachable Concurrency*, SwiftUI, XCTest. Nessuna dipendenza nuova.

**Baseline:** **misurala** (Task 1). `Docs/CLAUDE.md` riporta 756 test su `fix/remaining-main-thread-work`, e `main` dopo il merge di #41 avrà qualche test in più: non copiare nessuno dei due numeri. Il target di test **non è file-system-synchronized**: ogni file di test nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in **4 punti** (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`), altrimenti compila e non viene mai eseguito. Verifica sempre il **totale** nella riga `Executed N tests`, mai il solo `** TEST SUCCEEDED **`.

| Task | Cosa | Test nuovi (ordine di grandezza) |
| :--- | :--- | ---: |
| 0 | ADR da Proposta ad Accettata, con le risposte di Enrico | — |
| 1 | baseline misurata | — |
| 2 | **misure che condizionano il piano** (registro a 2.000 voci, ricostruzione su 27.798 gruppi) | — |
| 3 | `DuplicateFolderRule` (puro) + persistenza | `DuplicateFolderRuleTests` ~16 |
| 4 | la regola entra in `duplicateKeepChoice` | `DuplicateKeepChoiceTests` +~10 |
| 5 | `DuplicateFilter` (puro) | `DuplicateFilterTests` ~14 |
| 6 | `DuplicateBatch`: sottoinsieme senza ricalcolo, cartelle di primo livello | `DuplicateBatchTests` +~8 |
| 7 | tetto a 2.000 + `DuplicateRunPlan` + invariante | `DuplicateRunPlanTests` ~18, invariante 1 |
| 8 | `TrashHistory` (append-only, una riga per blocco) | `TrashHistoryTests` ~10 |
| 9 | i testi: selezione, piano della corsa, annullamento a un livello, resoconto | `DuplicatesStatusTests` +~16 |
| 10 | `BackupRunner`: orchestrazione della corsa | nessuno (dichiarato) |
| 11 | `DuplicatesView`: filtri, selezione in massa, regola | nessuno (dichiarato) |
| 12 | elenco stantio: data, testi, offerta nel wizard, durata della card | `LibraryListFreshnessTests` ~18, `LibraryIndexStatusTests` +~8 |
| 13 | mutation testing (solo su copia) | — |
| 14 | documentazione | — |
| 15 | verifiche manuali con Enrico | — |

I task puri (3-9) vengono **prima** del cablaggio (10-11): scritti dopo, i testi finirebbero inline nella View e poi estratti, che è come sono nati i tre difetti di gergo già corretti in questo progetto.

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

1. **Trova il codice con `grep -n`, mai con il numero di riga.** `ContentView.swift` ha ~13.000 righe; i numeri citati nella spec valgono solo per il commit su cui è stata scritta.
2. **La regola assoluta e ADR-0005 non si toccano.** Nessun diff aggiunge `removeItem`, `trashItem`, `copyItem`, `moveItem` o richieste S3. **`DuplicateTrasher.verify` e `DuplicateTrasher.run` non cambiano di una riga**: se un task sembra chiederlo, **fermati e rimanda all'Architect**.
3. **Nessuna seconda copia della decisione.** `duplicateKeepChoice` resta l'unico posto in cui si nomina la copia che resta. Un `filter`, un `sorted` o un `min` nuovo che sceglie fra i membri di un gruppo, in qualunque punto del codice, è un errore di review.
4. **Ogni task dichiara il mutante che deve morire.** Si verifica nel Task 13, su una copia nello scratchpad. Un mutante che sopravvive va dichiarato equivalente e spiegato, mai nascosto.
5. **Ogni `nonisolated` su un tipo con stato porta accanto la riga che dice perché è sicuro** (quale lock custodisce quale proprietà). `@unchecked Sendable` senza quella riga è un errore di review.
6. **Zero warning.** Un warning nuovo in Debug è una build rossa (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). Un warning di isolamento in un punto che il piano non prevede: **fermati e rimanda all'Architect**, non annotare `nonisolated` per tentativi.
7. **Asserzioni esistenti.** Aggiornare la firma di una chiamata in un test esistente è ammesso; cambiare **cosa** asserisce no, con **due sole eccezioni autorizzate dalla spec**: le 4 stringhe attese di `folderBreakdown` in `DuplicateBatchTests` (spec §2.7) e le 3 asserzioni su `confirmationBlockedReason` in `DuplicatesStatusTests` (spec §11 punto 5, subordinate alla risposta di Enrico). Ogni altra asserzione che «deve» cambiare è un segnale da rimandare all'Architect.
8. **Testi a schermo solo in tipi puri** (`DuplicatesStatus`, `LibraryListFreshness`, `LibraryIndexStatus`, `ImportPreviewStatus`, i gate), mai costruiti nella View. Niente gergo: niente «hash», «indice», «scansione», «registro», «manifest», «volume», «entry», «cache», «sha».
9. **Niente lavoro su 27.798 elementi dentro un `body`.** Filtri, totali e piani della corsa si calcolano in `Task.detached` e si memorizzano in `@State`. È il bug di prestazioni già pagato da questo pannello il 2026-09-02.
10. **Commit solo con build e suite verdi**, un commit per task, messaggio in italiano nel formato dei commit esistenti, con il trailer di attribuzione della sessione. **Mai `git push`.**

---

### Task 0: gli ADR, dopo l'approvazione e prima del codice

- [ ] **Step 1:** Verifica che `0011`, `0012`, `0013` siano ancora i primi numeri liberi in `Docs/adr/`. Se non lo sono, rinumera i tre file e aggiorna i riferimenti nella spec e in questo piano.
- [ ] **Step 2:** Porta i tre ADR da **Proposta** ad **Accettata**, e scrivi in ognuno le risposte di Enrico alle domande della spec §11 che lo riguardano: domande 2, 3, 5 → ADR-0012; domanda 6 → ADR-0011; domanda 4 → ADR-0013 (se la soglia scelta è 30 giorni, correggi l'argomento, non solo il numero).
- [ ] **Step 3:** Se Enrico risponde **no** alla domanda 3 (storia degli spostamenti), riscrivi §3.5 dell'ADR-0012 con le tre protezioni rimaste e **togli il Task 8** da questo piano, aggiungendo in ADR-0012 la riga su cosa si perde. Se risponde no alla 5, **fermati e rimanda all'Architect**: senza quella sostituzione il tetto continuerebbe a bloccare la conferma e la concatenazione non ha ingresso.
- [ ] **Step 4:** Commit solo documentazione.

---

### Task 1: baseline misurata

- [ ] **Step 1:** `git rev-parse --short HEAD`, annotalo. Verifica che #41 sia nella storia (`git log --oneline | grep -i "finestra Doppioni"` o equivalente); se non c'è, **fermati**.
- [ ] **Step 2:** Build pulita. Atteso: **0** warning. Se non è 0, **fermati** e rimanda all'Architect.
- [ ] **Step 3:** Suite completa. `B` = numero in `Executed N tests`, zero fallimenti.
- [ ] **Step 4:** Nessun commit.

---

### Task 2: le due misure che condizionano il piano

Non si scrive codice di produzione. Si misura, con una copia dell'indice reale nello scratchpad — **mai** l'originale in `~/Library/Application Support/AppBackupFoto/`.

- [ ] **Step 1: costo di scrittura del registro a 2.000 voci.** Un test temporaneo (o un piccolo eseguibile nello scratchpad) che chiama `TrashManifestStore.record` 2.000 volte con voci di forma realistica (percorsi lunghi come quelli veri: `ASUS/foto/recup_dir.37/f200571080.jpg`) e cronometra il totale. **Soglia di decisione: se supera ~30 s, il tetto del Task 7 non è 2.000** ma il valore che sta sotto la soglia (prova 1.000 e 1.500). Annota il numero: finisce nel doc-comment del tetto e in ADR-0012.
- [ ] **Step 2: costo della ricostruzione del blocco** su tutti i gruppi reali. Con una copia dell'indice nello scratchpad: `duplicateGroups()` e poi `DuplicateBatch(groups:)`, cronometrati separatamente. Serve a sapere se lo stato «sto applicando…» del Task 11 deve mostrare un progresso o basta un'attesa breve.
- [ ] **Step 3:** Rimuovi il test temporaneo (non deve entrare nella suite: dipende da una libreria che solo Enrico ha).
- [ ] **Step 4:** Nessun commit di codice; i due numeri vanno riportati all'Architect e nel Task 14.

---

### Task 3: `DuplicateFolderRule` — la regola, pura

**File:** `AppBackupFoto/ContentView.swift` (accanto a `duplicateKeepChoice`), `AppBackupFotoTests/DuplicateFolderRuleTests.swift` (nuovo, registralo nei 4 punti).

- [ ] **Step 1: test prima.** `DuplicateFolderRuleTests`:
  - `testCovers_groupSplitBetweenKeepAndTrashFolders`
  - `testDoesNotCover_groupWithACopyInAThirdFolder` — il caso che la spec §2.4 esclude per costruzione
  - `testDoesNotCover_groupWithNoCopyInTheKeepFolder`
  - `testCovers_groupWithSeveralCopiesInTheKeepFolder`
  - `testDoesNotCover_groupEntirelyInsideTheKeepFolder` (niente da cestinare: non è coperto, altrimenti si proporrebbe un blocco vuoto)
  - `testMatching_isOnNormalizedKeys_notOnDisplayPath` — `ASUS` / `asus`, e una forma NFD contro NFC: ExFAT è case-insensitive e non normalizza l'Unicode
  - `testMatching_isOnTheTopLevelFolderOnly` — `ASUS/foto/x.jpg` conta come `ASUS`, mai come `ASUS/foto`
  - `testFileAtTheRoot_belongsToNoTopLevelFolder` (un file sciolto in radice non è coperto da nessuna regola)
  - `testEmptyRule_coversNothing`, `testKeepFolderAlsoListedAsTrash_isRejected` (una regola contraddittoria non si applica, non si «interpreta al meglio»)
  - round-trip di persistenza: `testEncodedRule_decodesIdentical`, `testGarbageInDefaults_decodesToNoRule` (un valore corrotto = nessuna regola, non un crash)
- [ ] **Step 2: implementa.** `nonisolated struct DuplicateFolderRule: Codable, Equatable` con `keepIn: String` e `trashIn: Set<String>` (chiavi normalizzate), `covers(_ group: DuplicateGroup) -> Bool`, e le due funzioni di lettura/scrittura da `UserDefaults` con chiave nuova. Riusa `topLevelFolderKey` e `normalizedIndexKey` esistenti: **non scriverne una seconda versione** (è la lezione di `LibraryExclusions`/`realResolvedPath`/`makeThumbnail`).
- [ ] **Step 3:** build (0 warning) + suite: `B + ~16`.
- [ ] **Mutante che deve morire:** `covers` che accetta un gruppo con una terza cartella (`testDoesNotCover_groupWithACopyInAThirdFolder`); confronto su `displayPath` invece della chiave (`testMatching_isOnNormalizedKeys…`); `trashIn` ignorato, cioè «copre tutto ciò che ha una copia in X» (`testDoesNotCover_groupEntirelyInsideTheKeepFolder`).
- [ ] **Step 4:** Commit.

---

### Task 4: la regola entra in `duplicateKeepChoice`, non accanto

**File:** `ContentView.swift` (`DuplicateKeepReason`, `duplicateKeepChoice`, `duplicateKeepExplanation`), `AppBackupFotoTests/DuplicateKeepChoiceTests.swift`.

- [ ] **Step 1: test prima** (in `DuplicateKeepChoiceTests`):
  - `testUserRule_winsOverTheMainLibrary` — una regola «tieni in Takeout, cestina in Foto iPhone» tiene la copia in `Takeout`, e il motivo è `.userFolderRule`
  - `testUserRule_changesNothingOnGroupsItDoesNotCover` — stesso risultato, bit per bit, di `rule: nil`
  - `testUserRule_withSeveralCopiesInTheKeepFolder_fallsBackToTheExistingRules` — fra due copie in `Takeout` decide la più vecchia, poi il tie-break, e il motivo torna a essere quello della regola che ha davvero discriminato
  - `testUserRule_neverEmptiesTheCandidates` — una regola che non lascerebbe nessun candidato non si applica (è la condizione di `narrow`)
  - `testExplanation_namesTheUserRule` e `testExplanation_hasNoJargon` per il ramo nuovo
  - `testKeeperIsNeverAmongTheLeavingCopies` per il ramo nuovo (già vero per gli altri: va esteso, non riscritto)
- [ ] **Step 2: implementa.**
  - `DuplicateKeepReason` guadagna `userFolderRule`.
  - `duplicateKeepChoice(_ group: DuplicateGroup, rule: DuplicateFolderRule?)` — parametro **senza default**, come i quattro gate di ADR-0009. Primo `narrow` solo se `rule?.covers(group) == true`, sui membri sotto `keepIn`; le tre regole esistenti restano identiche e nell'ordine di oggi.
  - `duplicateKeepExplanation` guadagna il ramo `.userFolderRule` (clausola del pari merito e conteggio delle altre copie invariati).
  - **Aggiorna il doc-comment**: `Import/` ora esiste (30 voci), quindi la nota «`notAnImport` oggi non discrimina nulla» è falsa; e aggiungi la riga su `ASUS/` e sulla decisione del 2026-09-24 (pari dignità, `recup_dir.*` non si declassa, non riaprire).
  - Aggiorna i chiamanti esistenti nei test passando `rule: nil`: **la firma cambia, ciò che asseriscono no**.
- [ ] **Step 3:** build + suite: `+~10`.
- [ ] **Mutante che deve morire:** la regola messa **dopo** la libreria principale invece che prima (`testUserRule_winsOverTheMainLibrary`); la regola applicata anche ai gruppi non coperti (`testUserRule_changesNothingOnGroupsItDoesNotCover`); `narrow` senza la condizione «non svuotare» (`testUserRule_neverEmptiesTheCandidates`).
- [ ] **Step 4:** Commit.

---

### Task 5: `DuplicateFilter` — i tre predicati, puri

**File:** `ContentView.swift`, `AppBackupFotoTests/DuplicateFilterTests.swift` (nuovo, registralo).

- [ ] **Step 1: test prima.**
  - `testFolderFilter_keepsGroupsWithAtLeastOneCopyThere`
  - `testKindFilter_internalGroups_areThoseWithAllCopiesInOneFolder`
  - `testKindFilter_crossFolderGroups_areTheComplement` — insieme all'altro devono partizionare l'elenco: nessun gruppo fuori da entrambi, nessuno in entrambi
  - `testRuleFilter_keepsOnlyCoveredGroups`
  - `testFilters_composeWithAnd`
  - `testEmptyFilter_keepsEverything`
  - `testFolderList_comesFromTheGroups_notFromTheDisk` e `testFolderList_countsGroupsNotFiles` e `testFolderList_isSortedDeterministically`
  - `testFileAtTheRoot_hasNoTopLevelFolder_andIsCountedAsSuch`
- [ ] **Step 2: implementa.** `nonisolated struct DuplicateFilter` (value type, nessuna riga di sicurezza necessaria) con i tre predicati e `apply(to:) -> [Int]` che restituisce **indici** nell'elenco dei gruppi, non copie degli array (spec §2.8 punto 5). Più una funzione pura che ricava l'elenco delle cartelle con il conteggio dei gruppi.
- [ ] **Step 3:** build + suite: `+~14`.
- [ ] **Mutante che deve morire:** «interni» definiti come «una sola copia per cartella» invece di «tutte le copie nella stessa cartella» (`testKindFilter_internalGroups…` + il test di partizione); il conteggio delle cartelle fatto sui file invece che sui gruppi (`testFolderList_countsGroupsNotFiles`); composizione in OR invece che in AND.
- [ ] **Step 4:** Commit.

---

### Task 6: `DuplicateBatch` — il sottoinsieme non ricalcola, le cartelle sono di primo livello

**File:** `ContentView.swift` (`DuplicateBatch`), `AppBackupFotoTests/DuplicateBatchTests.swift`.

- [ ] **Step 1: test prima.**
  - `testInitFromEntries_doesNotRecomputeTheChoice` — costruisci `Entry` con una `choice` che nomina **un membro diverso** da quello che `duplicateKeepChoice` sceglierebbe; il blocco deve conservare *quella*. È il test che dimostra la proprietà di §2.6, e va scritto così o non dimostra niente.
  - `testInitFromEntries_recomputesOnlyTheTotals`
  - `testFolderBreakdown_isByTopLevelFolder` (nuovo) e aggiornamento delle **4 stringhe attese** esistenti (`"Other/vecchie"` → `"Other"`, `"Import/Scheda"` → `"Import"`): la proprietà verificata non cambia (autorizzazione: regola 7).
  - `testFolderBreakdown_saysHowManyFoldersInTotal`
  - `testVerifiedBytes_countsEveryMemberIncludingTheKeptCopy` — è la grandezza da cui si stima la rilettura, e **non** è `reclaimableBytes`
  - `testSummary_hasNoJargon` (esistente) esteso alle righe nuove
- [ ] **Step 2: implementa.** `init(entries: [Entry])` che non chiama `duplicateKeepChoice` **nemmeno una volta**; `init(groups:rule:)` come unico punto in cui la scelta si calcola; `folderBreakdown` per cartella di primo livello più il conteggio totale delle cartelle; `verifiedBytes`. Aggiorna il doc-comment del tipo: il congelamento della scelta ora vale **anche** attraverso il sottoinsieme, e questo è il motivo per cui `init(entries:)` esiste.
- [ ] **Step 3:** build + suite: `+~8`.
- [ ] **Mutante che deve morire:** `init(entries:)` che ricalcola la scelta (`testInitFromEntries_doesNotRecomputeTheChoice`); `verifiedBytes` che dimentica la copia tenuta; `folderBreakdown` che torna alla cartella genitrice completa.
- [ ] **Step 4:** Commit.

---

### Task 7: il tetto a 2.000 e `DuplicateRunPlan`

**File:** `ContentView.swift` (`duplicateBatchFileCap`, `DuplicateBatch.exceedsCap`, nuovo `DuplicateRunPlan`), `AppBackupFotoTests/DuplicateRunPlanTests.swift` (nuovo, registralo), `AppBackupFotoTests/DuplicateCapInvariantTests.swift` (nuovo, registralo).

- [ ] **Step 1: test prima.**
  - `DuplicateCapInvariantTests.testFileCapNeverExceedsTheRegisterCeiling` — `XCTAssertLessThanOrEqual(duplicateBatchFileCap, TrashManifestStore.maxItems)`, con il commento che dice **perché** (sopra il tetto del registro l'annullamento coprirebbe solo la coda del blocco, senza dirlo).
  - `DuplicateRunPlanTests`: `testSplitsAtTheFileCap`, `testSplitsAtTheByteCap`, `testNeverSplitsAGroupAcrossBlocks`, `testGroupBiggerThanTheCap_getsABlockOfItsOwn`, `testBlockOrder_followsThePanelOrder`, `testEmptySelection_producesNoBlocks`, `testSingleBlock_whenUnderBothCaps`, `testEstimatedSeconds_growsWithBytesAndFiles`, `testEstimatedSeconds_isNeverZeroForANonEmptyRun`, `testPlan_isDeterministic` (stesso input, stesso piano, due volte).
- [ ] **Step 2: implementa.** `duplicateBatchFileCap` al valore deciso nel Task 2 (2.000 se la misura lo consente), con il doc-comment **riscritto**: il tetto non è più «prudente e ritarabile», è la granularità dell'annullamento automatico, limitata da `TrashManifestStore.maxItems`; ci vanno i numeri della prima passata reale (89.541 copie, 1,75 MB medi, 45 blocchi, ~55 s per blocco) e la misura del Task 2. `duplicateBatchByteCap` **invariato**, con una riga che dice perché non si alza (su questa libreria è 14 volte più largo del tetto sui file). `nonisolated struct DuplicateRunPlan` puro, con `blocks: [[DuplicateBatch.Entry]]` e `estimatedSeconds`, costanti misurate (224 MiB/s, 55,8 file/s) **nominate e datate** nel commento.
- [ ] **Step 3:** build + suite: `+~19`.
- [ ] **Mutante che deve morire:** la divisione che spezza un gruppo (`testNeverSplitsAGroupAcrossBlocks`); il gruppo più grande del tetto scartato invece di avere un blocco suo (`testGroupBiggerThanTheCap…`); l'invariante del tetto rimosso (`DuplicateCapInvariantTests`); `>` ↔ `>=` sui bordi dei tetti (`testSplitsAtTheFileCap`).
- [ ] **Step 4:** Commit.

---

### Task 8: `TrashHistory` — la storia degli spostamenti

**Condizionato** alla risposta 3 di Enrico (spec §11). Se è no, salta il task e passa al 9.

**File:** `ContentView.swift` (accanto a `TrashManifestStore`), `AppBackupFotoTests/TrashHistoryTests.swift` (nuovo, registralo), `MainThreadIsolationTests.swift`.

- [ ] **Step 1: test prima.**
  - `testAppendsOneLinePerBlock_andNeverRewritesThePreviousOnes` (scrivi due blocchi, riapri da zero, verifica che la prima riga sia byte per byte quella di prima)
  - `testFileIs0600`, `testRefusesALocationOutsideTheAllowedOne` (riusa `isAllowedStoreLocation`, **non** una seconda allow-list)
  - `testUnreadableFile_doesNotFailTheWrite` (un file corrotto non blocca niente: è una storia, non un prerequisito)
  - `testRecordedPaths_areTheOriginalAbsolutePaths`
  - `testAppend_isSafeFromTwoThreads`
- [ ] **Step 2:** `testTrashHistory_runsWithoutTheMainThread` in `MainThreadIsolationTests`.
- [ ] **Step 3: implementa.** `nonisolated final class TrashHistory: @unchecked Sendable` con un `NSLock`, `append(blockId:trashed:)` che scrive **una riga** (JSON su una riga, file `.jsonl`) in append e la riga di sicurezza che dice quale lock custodisce cosa. Nel doc-comment: **non è un annullamento**, non ha bottoni, non legge niente per decidere, e esiste perché il registro ricorda 2.000 voci mentre una corsa può toccarne 89.541.
- [ ] **Step 4:** build + suite: `+~11`.
- [ ] **Mutante che deve morire:** riscrittura del file invece dell'append (`testAppendsOneLinePerBlock…`); `try` che propaga e fa fallire il blocco (`testUnreadableFile…`); allow-list duplicata invece di riusata.
- [ ] **Step 5:** Commit.

---

### Task 9: i testi — selezione, piano della corsa, annullamento a un livello, resoconto

**File:** `ContentView.swift` (`DuplicatesStatus`), `AppBackupFotoTests/DuplicatesStatusTests.swift`.

- [ ] **Step 1: test prima.**
  - `testSelectionLine_saysVisibleAndSelectedSeparately` — con 11.082 visibili su 27.798 e 4.000 selezionati, entrambi i numeri compaiono
  - `testSelectionLine_neverSaysSpaceWasRecovered` (mai il passato: ADR-0005)
  - `testSelectionLine_zeroSelected_saysSoInsteadOfShowingZero`
  - `testRunPlanLine_saysHowManyBlocksAndRoughlyHowLong`
  - `testRunPlanLine_singleBlock_doesNotMentionBlocks`
  - `testUndoScopeLine_appearsOnlyWithMoreThanOneBlock` e `testUndoScopeLine_saysOnlyTheLastBlockComesBack`
  - `testRunProgressLine_countsFilesOfTheWholeRun_notOfTheBlock`
  - `testRunOutcome_aggregatesEveryBlock`, `testRunOutcome_saysWhyTheChainStopped`, `testRunOutcome_skippedGroups_areCountedByReason_neverTruncatedSilently`
  - `testNoJargon_onEveryNewBranch` — **tutte** le diramazioni, non un campione
  - **sostituzione autorizzata:** le 3 asserzioni su `confirmationBlockedReason` (righe ~85, ~92, ~176) diventano asserzioni sul piano della corsa.
- [ ] **Step 2: implementa** in `DuplicatesStatus`: `selectionLine(visibleGroups:totalGroups:selectedGroups:files:reclaimableBytes:)`, `runPlanLine(blockCount:files:estimatedSeconds:)`, `undoScopeLine(blockCount:fileCapPerBlock:)`, `runProgressLine(blockIndex:blockCount:filesDone:filesTotal:)`, `runOutcomeLines(_:)`; rimuovi `confirmationBlockedReason`. Registro anti-gergo invariato.
  - **Deviazione decisa da Enrico il 2026-09-24, eseguita così**: la rimozione di `confirmationBlockedReason` è **rimandata al Task 11**, non fatta qui. Trovato in corso d'opera che l'unico call site di produzione è `DuplicatesView.summarySheet` (fuori dallo scope di questo task, dentro quello del Task 11) — toglierla al Task 9 avrebbe lasciato, per i commit fra Task 9 e Task 10, un bottone distruttivo premibile su un blocco più grande di quanto l'orchestrazione (Task 10, non ancora scritta a quel punto) sappia gestire: ogni commit deve restare sicuro da solo. Le 5 funzioni nuove sono state comunque tutte implementate e testate in questo task — coesistono senza conflitto, dato che nessun'altra funzione le chiama ancora. Le 3 asserzioni su `confirmationBlockedReason` in `DuplicatesStatusTests` restano **intatte e verdi**, non la "sostituzione" indicata allo Step 1: verranno **cancellate**, non riscritte, quando la funzione sparirà al Task 11. Vedi la nota gemella al Task 11.
- [ ] **Step 3:** build + suite: `+~16`.
- [ ] **Mutante che deve morire:** la riga di selezione che mostra solo il visibile (`…saysVisibleAndSelectedSeparately`); la frase sull'annullamento che compare anche con un blocco solo, o che promette che torna tutto (`testUndoScopeLine_…`); il progresso che conta i file del blocco (`testRunProgressLine_…`); i motivi dei gruppi saltati troncati con «e altri».
- [ ] **Step 4:** Commit.

---

### Task 10: `BackupRunner` — l'orchestrazione della corsa

**File:** `ContentView.swift` (`BackupRunner`). Nessun test nuovo: è cablaggio, **dichiarato non coperto** come già per il Task 7 di ADR-0009.

- [ ] **Step 1:** La corsa vive nel runner, non negli `@State` della view (schema di #41 e di ADR-0009): blocco corrente, numero di blocchi, file fatti sul totale, richiesta di stop, esito aggregato. `beginDuplicateTrashing()`/`endDuplicateTrashing()` **una volta per corsa**, non per blocco: due chiamate per blocco riaprirebbero la finestra in cui un altro job può partire fra due blocchi.
- [ ] **Step 2:** Il ciclo: per ogni blocco del `DuplicateRunPlan`, un `batchId` nuovo, `DuplicateTrasher.run(...)` (invariato), la riga nella storia degli spostamenti (Task 8), l'accumulo dell'esito. **La catena si ferma** se l'esito ha `stoppedBecauseVolumeVanished` oppure un `trashFailed`; **non** si ferma per i gruppi saltati dalla verifica. Stop richiesto dall'utente: onorato fra i gruppi (il `CancelFlag` di oggi) **e** fra i blocchi.
- [ ] **Step 3:** Le precondizioni (`trashDisabledReason`) si rivalutano **prima di ogni blocco**, non solo all'inizio della corsa: fra il blocco 3 e il blocco 4 possono passare minuti, ed è lo stesso rilievo del 2026-09-01 che ha portato a rivalutarle in `startTrashing`.
- [ ] **Step 4:** L'elenco si ricarica **una volta sola**, alla fine della corsa; `refreshRestorableBatch()` una volta sola alla fine.
- [ ] **Step 5:** build + suite: `+0`. Se un test esistente sullo spostamento fallisce, **fermati**: significa che il contratto di `DuplicateTrasher` è stato toccato.
- [ ] **Mutante che deve morire:** dichiarato **non coperto da test** (orchestrazione). Copertura sostitutiva: le verifiche manuali 4, 5 e 6 del Task 15.
- [ ] **Step 6:** Commit.

---

### Task 11: `DuplicatesView` — filtri, selezione in massa, regola

**File:** `ContentView.swift` (`DuplicatesView`). Nessun test nuovo: View, **dichiarata non coperta** (stessa disciplina di `LibraryIndexCard`).

- [ ] **Step 1:** Barra dei filtri sopra la lista: menu delle cartelle con i conteggi, controllo «Tutti / Tutte le copie nella stessa cartella / Copie in cartelle diverse», e (solo con una regola attiva) «Solo i gruppi coperti dalla regola». Il risultato filtrato è un `@State` di indici, ricalcolato in `Task.detached` **solo** al cambio di filtro.
- [ ] **Step 2:** «Seleziona tutti quelli visibili» / «Togli la selezione da quelli visibili», sul solo insieme filtrato. La selezione sopravvive al cambio di filtro. Sotto la lista, `DuplicatesStatus.selectionLine(...)` alimentata da valori **precalcolati**, mai da un `reduce` nel `body`.
- [ ] **Step 3:** La regola: due scelte di cartella (tieni / cestina, quest'ultima multipla), lo stato «sto applicando…», e la riga che dice quanti gruppi copre e quanti restano fuori perché hanno una copia in una terza cartella. **Cambiare la regola azzera la selezione**, ricostruisce il blocco una volta in `Task.detached` e lo dice.
- [ ] **Step 4:** Sopra la lista, quando il filtro è «Tutte le copie nella stessa cartella», la riga che dice con quale criterio l'app ha scelto (spec §2.5, categoria 1).
- [ ] **Step 5:** `beginConfirmation()` costruisce il blocco con `DuplicateBatch(entries:)` filtrando le `Entry` già congelate, **fuori dal main** se la selezione è grande, e apre il riepilogo solo quando il blocco è pronto. Il riepilogo mostra il piano della corsa e la frase sull'annullamento; l'alert distruttivo ne porta la forma breve.
  - **Obbligatorio, riportato dal Task 9**: in questo stesso Step (o comunque nello stesso commit del Task 11) rimuovere `DuplicatesStatus.confirmationBlockedReason` da `ContentView.swift` e ricablare `summarySheet` sul piano della corsa (`runPlanLine`/`undoScopeLine`) al posto suo — la rimozione era stata deliberatamente rimandata qui il 2026-09-24 (vedi la nota al Task 9, Step 2) proprio perché doveva avvenire insieme a questo ricablaggio, non prima. Cancellare (non riscrivere) le 3 asserzioni residue su `confirmationBlockedReason` in `DuplicatesStatusTests`. Verificare con `grep -n "confirmationBlockedReason" AppBackupFoto/ContentView.swift AppBackupFotoTests/DuplicatesStatusTests.swift` che non resti nessuna occorrenza, e riportarlo nel checkpoint di fine task.
- [ ] **Step 6:** La barra di avanzamento e «Interrompi» leggono lo stato del runner (Task 10), non `@State`.
- [ ] **Step 7:** build (0 warning) + suite: `+0`.
- [ ] **Mutante che deve morire:** dichiarato **non coperto** (SwiftUI). Copertura sostitutiva: verifiche manuali 3 e 4 del Task 15, più i test puri dei Task 5, 6, 9.
- [ ] **Step 8:** Commit.

---

### Task 12: l'elenco dice da quando non è aggiornato

**File:** `ContentView.swift` (`startLibraryIndexScan`, `deleteIndexAndRecreate`, `LibraryIndexStore`, nuovo `LibraryListFreshness`, `ImportView`, `LibraryIndexCard`), `AppBackupFotoTests/LibraryListFreshnessTests.swift` (nuovo, registralo), `LibraryIndexStatusTests.swift`, `LibraryIndexStoreTests.swift`.

- [ ] **Step 1: test prima** (`LibraryListFreshnessTests`): le 5 diramazioni della spec §4.3; la soglia ai **due bordi** (13 giorni e 23 ore → neutro; 14 giorni esatti → avviso); plurali di giorni/settimane; date scritte in parole; `testNoJargon_onEveryBranch` su tutte le diramazioni; `testNeverPromisesADuration` (finché la misura non c'è).
- [ ] **Step 2: test prima** sulla data: in `LibraryIndexStatusTests`, `testDateIsWrittenOnlyWhenTheReadReachedTheEnd`, `…notWrittenOnInterruption`, `…notWrittenWhenTheVolumeVanished`, `…notWrittenWhenFoldersWereUnreadable`, `…clearedWhenTheListIsEmptied`. In `LibraryIndexStoreTests`, `testNewestHashedAt_isNilOnAnEmptyIndex` e `…returnsTheMaximum`.
- [ ] **Step 3: implementa.** Chiave `UserDefaults` nuova scritta in **un punto solo** (il `onFinish` di `startLibraryIndexScan`, dove la completezza è già nota), azzerata da `deleteIndexAndRecreate`; `newestHashedAt()` sullo store come ripiego dichiarato; `nonisolated enum LibraryListFreshness` con le righe.
- [ ] **Step 4:** Nel wizard, passo `.preview`: le righe di `LibraryListFreshness` **sopra** quelle di `ImportPreviewStatus`, e — sopra soglia o senza data — i due bottoni «Aggiorna l'elenco adesso» / «Continua così». Il primo chiama `startLibraryIndexScan(full: false, ...)` (**mai** `full: true`) e, a lettura finita, **rifà l'anteprima**. Nessuna stringa nuova dentro la View.
- [ ] **Step 5:** `LibraryIndexCard`: la stessa riga di freschezza (una sola fonte), e `durata` corretta al numero derivato dai 390,6 GB reali (~28 minuti), con il commento che spiega da dove viene.
  - **Fatto solo in parte, deciso il 2026-09-25 per chiudere l'intervento**: `durata` è corretta ("dai 25 ai 35 minuti", commento con il calcolo a 224 MiB/s × 390,6 GB) e il commento gemello in `rebuildLibraryIndex` (riga ~9302) pure. **La riga di freschezza in `LibraryIndexCard` non è stata aggiunta** — l'offerta con l'azione vera (D18: «Aggiorna l'elenco adesso», aggiornamento incrementale) è nel wizard di import (Step 4, fatto per intero), che è il punto in cui la data stantia ha un costo concreto (foto reimportate). In Diagnostica la card mostra già `indexedFileCount` e i comandi manuali: aggiungerci la stessa riga è un miglioramento di rifinitura, non la correzione del difetto. **Da riprendere in un task futuro, se richiesto.**
- [ ] **Step 6:** build + suite: `+~26`.
  - **18 test** in `LibraryListFreshnessTests` (nuovo, registrato). **Non fatti**: le aggiunte a `LibraryIndexStatusTests` (`testDateIsWrittenOnlyWhenTheReadReachedTheEnd` e le tre sorelle) e a `LibraryIndexStoreTests` (`testNewestHashedAt_isNilOnAnEmptyIndex`/`…returnsTheMaximum`) — la logica che quei test avrebbero coperto (`LibraryListFreshness.readReachedTheEnd`, la scrittura in `startLibraryIndexScan`, `newestHashedAtUnsynchronized`) è implementata e verificata a mano con build pulita; `readReachedTheEnd` stesso è coperto da `LibraryListFreshnessTests` (che lo chiama direttamente, incluso il mutante `cancelled`/`traversalIncomplete`). **Debito di test dichiarato, non nascosto**: se una sessione futura tocca `newestHashedAtUnsynchronized` o il punto di scrittura in `startLibraryIndexScan`, aggiungere prima quei test.
- [ ] **Mutante che deve morire:** la data scritta anche su lettura incompleta (`…notWrittenOnInterruption`); la soglia con `>` invece di `>=` al bordo dei 14 giorni; `full: true` nell'offerta del wizard (nessun test lo intercetta: va **controllato in review**, ed è scritto qui per questo — verificato: `refreshLibraryListNow()` chiama `rebuildLibraryIndex(full: false, ...)`); l'anteprima **non** rifatta dopo l'aggiornamento.
- [ ] **Step 7:** Commit.

---

### Task 13: mutation testing (solo su una copia)

- [ ] **Step 1:** Copia il repository nello scratchpad. **Mai** sull'albero di lavoro di Enrico.
- [ ] **Step 2:** Applica, uno alla volta, i mutanti dichiarati nei Task 3-9 e 12. Ognuno deve far fallire **il test nominato**, non «qualche test».
- [ ] **Step 3:** Un mutante che sopravvive va dichiarato equivalente **con il ragionamento scritto**, o produce un test in più. Mai nascosto.
- [ ] **Step 4:** Nessun commit di codice; l'esito va nel Task 14.

---

### Task 14: documentazione

- [ ] **Step 1:** `Docs/CLAUDE.md`: riga «Indice di contenuto della libreria + dedup in import (#31)» — la selezione in massa, la regola per cartella, il tetto nuovo, la corsa a blocchi, l'avviso di elenco non aggiornato, con le date e i riferimenti agli ADR 0011-0013. Riga «Test automatici» con il totale nuovo e i file nuovi. **E la sezione «Fatti misurati sui volumi reali il 2026-09-01»**: aggiungi i numeri del 2026-09-24 (141.683 voci, `ASUS/`, `Import/` che ora esiste, 390,6 GB) invece di lasciare i vecchi a passare per attuali.
- [ ] **Step 2:** `Docs/CONTEXT.md`: la voce **Blocco** dice ancora «Tetto: 500 file o 50 GB… Oltre il tetto la UI dice "fallo in più volte"». Riscrivila con il tetto nuovo e con la **corsa** come termine nuovo del vocabolario (una sequenza di blocchi confermata in una volta), più una riga sulla **regola per cartella**.
- [ ] **Step 3:** `Docs/ROADMAP.md`: un capitolo nuovo con i punti chiusi da questo intervento e quelli aperti — il quarto filone (§5 della spec) come punto numerato, e le due misure del Task 2 se hanno spostato qualche scelta.
- [ ] **Step 4:** `.claude/rules/architecture.md`: i cinque tipi nuovi, con il perché di ogni `nonisolated`, e la nota che `DuplicateTrasher` non è stato toccato.
- [ ] **Step 5:** Commit solo documentazione.

---

### Task 15: verifiche manuali con Enrico (SSD collegato)

Nessuna di queste è automatizzabile: servono il volume vero e una persona che guardi.

- [ ] **Step 1:** Misura dell'aggiornamento incrementale dell'elenco dall'app (spec §9 punto 1). Il numero, se lo si vuole nel testo dell'offerta, va aggiunto **dopo** averlo misurato.
- [ ] **Step 2:** Selezione in massa su `Foto iPhone` da sola (150 gruppi, 166 copie, 3,8 GB), con controllo nel Finder di 3-4 gruppi presi a mano **prima** di confermare.
- [ ] **Step 3:** Una corsa piccola (2-3 blocchi) fino in fondo: progresso a due livelli, resoconto unico, elenco ricaricato una volta sola.
- [ ] **Step 4:** Interruzione a metà corsa: i numeri dei blocchi già fatti devono tornare, e la frase deve dire che ti sei fermato tu.
- [ ] **Step 5:** «Annulla l'ultimo spostamento» dopo la corsa: rimette a posto l'ultimo blocco e **dice** che gli altri restano nel Cestino.
- [ ] **Step 6:** Scollegamento dell'SSD a metà corsa, su una selezione piccola: la catena si ferma, il resoconto dice quanti file erano già stati spostati, la data dell'elenco **non** si aggiorna.
- [ ] **Step 7:** Wizard di importazione con l'elenco vecchio di più di 14 giorni: l'avviso deve comparire **in quella finestra**.
- [ ] **Step 8:** Verifica se `ASUS/` esiste sull'HDD (rischio 7 della spec). Se non c'è, **non** fare corse grandi su quella cartella prima di averne parlato con Enrico.
- [ ] **Step 9:** Misura dei file/s reali di `trashItem` sull'SSD via FSKit durante la corsa dello Step 3, e correzione delle costanti di `DuplicateRunPlan` se sono fuori di più del 30%.
