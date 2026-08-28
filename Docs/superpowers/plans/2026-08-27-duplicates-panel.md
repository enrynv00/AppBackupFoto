# Pannello Doppioni con cancellazione (roadmap #31, seconda parte) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: approvato da Enrico il 2026-08-28, esecuzione in corso.** Spec di riferimento: `Docs/superpowers/specs/2026-08-27-duplicates-panel-design.md`. Le sei domande aperte sono chiuse (commit `6fffeb2`, sezione «Risposte alle domande aperte» in coda alla spec) e le tre che cambiavano il contenuto dei task — tetto per blocco, forma della seconda conferma, testo della regola assoluta — sono già riportate nei task che le usano.

**Ordine di esecuzione: il Task 5 si esegue prima del Task 4** (vedi «Nota sull'ordine dei task» in coda). La numerazione resta invariata.

**Goal:** Un pannello che elenca i gruppi di file byte-identici già presenti sull'SSD, propone e **spiega** quale copia tenere, e — dopo che l'utente ha spuntato i gruppi, letto un riepilogo dettagliato e confermato — sposta le copie in eccesso nel **Cestino del volume**, in modo annullabile.

**Architecture:** Sei componenti separati per responsabilità, cinque dei quali testabili senza UI. `LibraryIndexStore.duplicateGroups()` è una query nuova sullo store esistente (l'indice `idx_entries_hash` c'è già). `duplicateKeepChoice` e `duplicateKeepExplanation` sono logica **pura**: dato un gruppo, quale copia si tiene e **perché**, con il motivo come parte del risultato e non ricostruito dalla UI. `DuplicateBatch` è logica **pura** di aggregazione: conteggi, byte, cartelle, tetto. `DuplicateTrasher` è il motore di cancellazione, l'unico componente che tocca file foto; ha `trashFunction` e `hashFunction` iniettabili con default reali, stesso pattern di `FileSyncer.hashFunction`. `TrashManifestStore` è il registro di ripristino, sul disco interno. `DuplicatesView` è la `Window` di primo livello, gated con `AuthGateManager`.

**Tech Stack:** Swift 5.x, SwiftUI, `SQLite3` di sistema, `UniformTypeIdentifiers`, ImageIO (già in uso per `makeThumbnail`), XCTest. Nessuna dipendenza nuova.

**Baseline: 346 test verdi** al commit `310efa5`. Ogni task dichiara il proprio incremento e il **cumulativo atteso**; la regola del progetto vale integralmente — il target di test **non è file-system-synchronized**, ogni file nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti, e si verifica sempre il **conteggio totale nel log**, mai il solo `** TEST SUCCEEDED **`.

| Componente | Responsabilità | Test |
| :---- | :---- | :---- |
| `LibraryIndexStore.duplicateGroups()` | leggere i gruppi dall'indice | `DuplicateGroupsStoreTests.swift` |
| `duplicateKeepChoice` / `duplicateKeepExplanation` | quale copia tenere, e perché, a parole | `DuplicateKeepChoiceTests.swift` |
| `DuplicateBatch` | aggregazione del blocco: file, byte, cartelle, tetto | `DuplicateBatchTests.swift` |
| `DuplicateTrasher` | verifica, cestinamento, aggiornamento dell'indice | `DuplicateTrasherTests.swift` |
| `TrashManifest` / `TrashManifestStore` | registro di ripristino e annullamento | `TrashManifestTests.swift` |
| `DuplicatesView` + `DuplicatesStatus` | la finestra; le righe di stato sono pure | `DuplicatesStatusTests.swift` |

## Comandi di build e test

```bash
# build
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
# suite completa
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
# singola classe
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regola di sicurezza valida per tutti i task

Ogni task che tocca la cancellazione dichiara sotto **«Il mutante che deve morire»**: la modifica plausibile che un ottimizzatore futuro farebbe, e il test che deve diventare rosso se qualcuno la fa. Un test che passa sia col codice giusto sia con quello sbagliato non è una rete di protezione — su questo progetto è già successo tre volte (il parsing YAML di Immich con `contains`, `testCancelStopsScan`, il test sulla root sparita). **Al termine del Task 4 e del Task 5 va eseguita una corsa di mutation testing** sui mutanti elencati, con lo stesso metodo usato per il nucleo di #31 (22 mutanti, 22 uccisi).

Vincolo trasversale, da non violare in nessun task: **nessun percorso di codice di questo piano può chiamare `removeItem` su un file dentro la root della libreria**, e nessuno può scrivere dentro `.Trashes`.

---

### Task 1: `duplicateGroups()` — leggere i gruppi dall'indice

Primo perché tutto il resto lo consuma, e perché è la sola parte che tocca SQLite.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `LibraryIndexStore`, accanto a `entries(withHash:)` — **localizza con `grep -n "func entries(withHash"`, mai per numero di riga**)
- Create: `AppBackupFotoTests/DuplicateGroupsStoreTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `LibraryIndexEntry`, la coda seriale privata e gli helper `prepare`/`stepRow`/`bind*` già esistenti nello store.
- Produce: `struct DuplicateGroup { let hash: String; let size: Int64; let members: [LibraryIndexEntry] }` e `func duplicateGroups() throws -> [DuplicateGroup]`. Consumato dai Task 2, 3, 4, 6.

- [x] **Step 1: Scrivi il file di test** (~14 test) su un database temporaneo reale, come già fa `LibraryIndexStoreTests`. Copertura minima:
  - due entry stesso hash ⇒ un gruppo con due membri; tre entry ⇒ un gruppo con tre membri
  - entry con hash unico ⇒ nessun gruppo
  - due gruppi distinti ⇒ due gruppi, membri non mescolati
  - **entry con `size = 0` ⇒ nessun gruppo, anche se sono tre e hanno lo stesso hash** (tutti i file vuoti condividono lo SHA256; raggrupparli significherebbe proporre di cestinare file *diversi*)
  - un membro con `size = 0` e uno no, stesso hash: caso impossibile in pratica, ma il gruppo va escluso lo stesso — non si cestina su dati incoerenti
  - `displayPath`, `mtime`, `hashedAt` di ogni membro sono quelli scritti, non ricostruiti
  - indice vuoto ⇒ array vuoto, nessun errore
  - risultato **stabile fra due chiamate** sugli stessi dati (ordinamento deterministico)
  - un database corrotto ⇒ **lancia**, non restituisce un array vuoto

- [x] **Step 2: Registra il file in `project.pbxproj`** (4 punti; usa `grep -n "LibraryIndexStoreTests" AppBackupFoto.xcodeproj/project.pbxproj` per copiare il formato esatto).

- [x] **Step 3: Verifica il fallimento atteso** — `cannot find 'DuplicateGroup' in scope`. Se il comando non trova affatto la classe di test, la registrazione non ha funzionato: **fermati e segnalalo**. *(Ottenuto esattamente `error: cannot find type 'DuplicateGroup' in scope`: il file era già compilato dal target, quindi la registrazione aveva funzionato.)*

- [x] **Step 4: Implementa.** Una sola query, dentro la coda seriale, con i vincoli già stabiliti per lo store:
  - `SELECT ... FROM entries WHERE size > 0 AND hash IN (SELECT hash FROM entries WHERE size > 0 GROUP BY hash HAVING COUNT(*) > 1) ORDER BY hash, path`
  - **nessun ciclo `while sqlite3_step(...) == SQLITE_ROW` nudo**: esce identico su `SQLITE_DONE` e su `SQLITE_ERROR`/`CORRUPT`/`BUSY`, cioè può restituire un elenco **troncato senza errore** — e qui un elenco troncato è un gruppo che non compare, non un dato sbagliato, ma la regola dello store è unica e non si deroga. Usa `stepRow`, che lancia.
  - guardia nil su ogni colonna `TEXT` letta con `String(cString:)`: un puntatore nil termina il processo (SIGTRAP).
  - doc-comment che scrive il **contratto**: risultato corretto ma **potenzialmente stantio**, esattamente come `entries(withHash:)`. Serve a mostrare una lista, **mai** a decidere una cancellazione senza rilettura (ADR-0003 + ADR-0005).

- [x] **Step 5: Test verdi** — `Executed 18 tests, with 0 failures` (18 e non 14: vedi la nota sui mutanti qui sotto).
- [x] **Step 6: Build, suite completa, commit** — **364 test** (346 + 18), `** BUILD SUCCEEDED **` + `** TEST SUCCEEDED **`.

**Deciso il 2026-08-28 (coordinatore, dopo la review): `DuplicateGroup.size` è il MINIMO fra le dimensioni dei membri**, non la prima incontrata. Con un indice coerente coincidono, ma l'indice è una cache e può essere incoerente (ADR-0002) — e da quel numero esce lo spazio recuperabile mostrato nel riepilogo che precede il bottone distruttivo. Sovrastimarlo significa raccogliere un consenso su GB che non si libereranno; sottostimarlo è innocuo. Il gruppo **resta visibile** (scartarlo farebbe sparire in silenzio due doppioni veri per colpa di una terza riga avvelenata) e l'incoerenza vera la intercetta il Task 4, che rilegge, rihasha e pretende unanimità. I file da 0 byte restano esclusi come prima: non sono entry stantie, sono file **provabilmente diversi** che condividono lo SHA256 del vuoto.

**Il mutante che deve morire:**
| Mutante | Test che deve diventare rosso | Esito misurato (2026-08-28) |
| :---- | :---- | :---- |
| `size > 0` rimosso (entrambe le occorrenze) | `testZeroByteFiles_areNotAGroup` | **ucciso** (4 test rossi) |
| `size > 0` rimosso **solo dal filtro esterno** | `testZeroByteMemberInsideARealGroup_isNotAMember` | **ucciso** |
| `size > 0` rimosso **solo dalla sottoquery** | — | **sopravvissuto — equivalente**, vedi sotto |
| `HAVING COUNT(*) > 1` → `>= 1`, **da solo** | — | **sopravvissuto — equivalente**, vedi sotto |
| Regola «almeno due copie» rimossa da **entrambi** i punti (SQL + Swift) | `testUniqueHash_isNotAGroup` | **ucciso** (5 test rossi) |
| Guardia Swift `members.count > 1` rimossa, da sola | `testGroupReducedToASingleReadableMember_isNotAGroup` | **ucciso** |
| `min` delle dimensioni → `members[0].size` | `testIncoherentSizesForTheSameHash_exposeTheSmallestSize` | **ucciso** |
| `stepRow` sostituito da un `while sqlite3_step == SQLITE_ROW` | `testCorruptDatabase_throws` | **ucciso** |

**Nota (2026-08-28) — quali mutanti sono equivalenti, e soprattutto quali NO.** Due regole finiscono scritte in due punti ciascuna, ed è deliberato; ma **le due occorrenze non hanno lo stesso peso, e confonderle è pericoloso**:

- **`size > 0` del filtro esterno: PORTANTE, non ridondante.** Con un hash che ha già due copie vere, la sottoquery lo mette comunque nell'elenco degli hash duplicati: a tenere il file da 0 byte fuori dai *membri* resta solo il filtro esterno. Senza, un file troncato diventa il terzo membro di un gruppo sano — candidato al cestinamento, o peggio la copia che la regola di proposta sceglie di **tenere**. Misurato, e ora coperto da `testZeroByteMemberInsideARealGroup_isNotAMember`. **Non toglierla.**
- **`size > 0` della sottoquery: ridondante** rispetto al filtro esterno più la guardia Swift, quindi mutarla da sola è equivalente. Resta perché documenta l'intento e perché regge se un domani cambia il filtro esterno.
- **`HAVING COUNT(*) > 1` da solo: equivalente**, perché il conteggio dei membri **leggibili** in Swift lo replica. Quella guardia Swift non è ridondanza: la query conta le *righe*, ma una riga malformata (colonna TEXT a NULL) viene saltata in lettura, quindi un gruppo di due righe può arrivare con un solo membro leggibile — e un gruppo da un membro solo mostrerebbe come doppione un file che copie non ne ha. Mutare l'`HAVING` cambia solo quante righe si leggono (tutto l'indice invece dei soli doppioni), non il risultato.

Al posto dei due equivalenti sono stati verificati i mutanti **osservabili**: rimozione della regola da entrambi i punti, rimozione della sola guardia Swift, e rimozione del solo filtro esterno. Da qui 18 test invece di 14. Nessun test è stato indebolito per far quadrare un conteggio.

---

### Task 2: `duplicateKeepChoice` — quale copia si tiene, e perché

Logica **pura**: nessun filesystem, nessun database. È la decisione 3 di Enrico, e il motivo fa parte del risultato.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (accanto a `indexEntryVerdict`, l'altra funzione pura di #31)
- Create: `AppBackupFotoTests/DuplicateKeepChoiceTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `DuplicateGroup` (Task 1).
- Produce: `enum DuplicateKeepReason { case mainLibrary, notAnImport, oldest, deterministicTieBreak }`, `struct DuplicateKeepChoice { let keeper: LibraryIndexEntry; let reason: DuplicateKeepReason; let tiedCandidates: Int }`, `func duplicateKeepChoice(_ group: DuplicateGroup) -> DuplicateKeepChoice`, e `func duplicateKeepExplanation(_ choice:, in group:) -> String`. Consumati dai Task 3, 4, 6.

> **Deviazione dall'interfaccia originale, consapevole e approvata (2026-08-28).** `tiedCandidates` **non era in questo piano**: è comparso durante l'audit del Task 2. Senza di esso la frase `.mainLibrary` presenta come motivata una scelta fatta **a pari merito** fra due copie in libreria principale, di cui una finisce nel Cestino — l'utente legge una ragione che non c'è. Era il rilievo 4 del Security/Rules Auditor e non si chiudeva in nessun altro modo. Verificato per ricerca esaustiva (11.100 gruppi): il campo conta esattamente i membri indistinguibili dalla copia tenuta — stesso rango di cartella **e** stessa data — e non può contare membri che non erano in pareggio, perché `narrow` non restringe mai quando la regola non discrimina. `keeper` e `reason` restano quelli previsti dal piano e nessun consumatore cambia (i Task 3, 4 e 6 non erano ancora scritti quando è comparso).

- [x] **Step 1: Scrivi il file di test** (~18 test):
  - un membro sotto `Foto iPhone/` e uno sotto `Import/Scheda/` ⇒ vince il primo, `reason == .mainLibrary`
  - due membri sotto `Foto iPhone/` ⇒ si scende alla regola successiva
  - un membro sotto `Import/` e uno sotto `2019 Vacanze/` ⇒ vince il secondo, `.notAnImport`
  - due membri entrambi sotto `Import/` ⇒ `.oldest`
  - a parità di cartella, mtime diversi ⇒ vince il **più vecchio** (`.oldest`)
  - a parità piena ⇒ `.deterministicTieBreak`, e il risultato **non cambia permutando l'ordine dei membri in input** (test che prova almeno 6 permutazioni)
  - gruppo con tre membri e regole miste, per verificare la precedenza fra le tre regole
  - la spiegazione **nomina la cartella vera** del file tenuto e **il numero** delle altre copie
  - la spiegazione è diversa per ciascuno dei quattro motivi (nessun testo condiviso che renderebbe il test cieco)
  - la spiegazione non contiene le parole «hash», «indice», «SHA256», «scansione» — registro anti-gergo, come già per `LibraryIndexStatus`
  - `Foto iPhone` con maiuscole diverse / in NFD: riconosciuta comunque (le chiavi dell'indice sono già NFC + minuscole, ma il confronto va fatto sulla **chiave normalizzata**, non su `displayPath`)
  - `Fotografie iPhone/` **non** è `Foto iPhone/`: confronto per **componente di percorso**, mai `hasPrefix` sulla stringa

- [x] **Step 2–3: registra il file, verifica il fallimento atteso.** *(Ottenuto `error: cannot find type 'DuplicateKeepChoice' in scope`, con la classe di test gia' compilata dal target: la registrazione ha funzionato.)*

- [x] **Step 4: Implementa.** Precedenza: `mainLibrary` → `notAnImport` → `oldest` → tie-break deterministico (percorso più corto, poi ordine della chiave normalizzata). Il confronto delle cartelle passa dalla **prima componente della chiave normalizzata**, non da `hasPrefix`.
  Commento accanto al codice, obbligatorio: **questa regola è provvisoria e dichiarata tale.** Il layout di primo livello dell'SSD risulta rilevato il 2026-07-29/30 (`Foto iPhone`, `Foto Google Drive`, `Other`, `Takeout`, `Takeout 2`, `Zip`) ma non riconfermato da allora. In particolare **la posizione di `Takeout/` e `Takeout 2/` nella gerarchia è una decisione che Enrico ha esplicitamente rimandato al momento in cui avrà il layout reale davanti** (risposta 6 del 2026-08-28): sono estrazioni automatiche, quindi l'argomento per declassarle accanto a `Import/` è forte, ma finché non è deciso restano alla pari delle altre cartelle e disambigua la data più vecchia. Se il layout vero smentisce la regola, cambiano questa funzione e i suoi test, non il design.

- [x] **Step 5–6: test verdi, build, suite, commit** — `Executed 32 tests, with 0 failures` sulla sola classe, **396 test** in suite completa. Tre commit, non uno: 23 test e 387 al primo (`8462f9c`), 31 e 395 dopo i sette rilievi dell'audit (`4734342`), 32 e 396 dopo i tre buchi di test del code-reviewer. **Il Task 2 è costato il triplo dei giri previsti, e tutti e tre sono serviti** — vedi le tre note sui test ciechi qui sotto.

**Correzione del conteggio (2026-08-28).** Questo step diceva «attesi 378 test (360 + 18)» ed era stantio: la baseline reale al commit `2c87976` e' **364** (il Task 1 ha prodotto 18 test invece di 14). Il Task 2 ne ha scritti **23** invece di 18 — i cinque in piu' nascono tutti dalla corsa sui mutanti, nessuno e' stato aggiunto per far quadrare un numero: `testMainLibraryBeatsImportFolder`, `testFotoIPhone2_isNotTheMainLibrary`, `testImportante_isNotAnImportFolder`, `testFileAtTheRootIsNotAFolder`, `testComparisonUsesTheNormalizedKeyNotTheDisplayPath`. Cumulativo dopo il primo commit: **387**.

**Secondo giro (2026-08-28, dopo l'audit sicurezza/regole del commit `8462f9c`): 31 test, cumulativo 395.** L'audit non ha trovato rilievi su cancellazione, purezza o determinismo, ma ha dimostrato con una replica standalone che **il testo mostrato all'utente affermava il falso in quattro casi limite riproducibili**. Causa comune: `duplicateKeepChoice` restringe i candidati a ogni regola, quindi dalla regola 2 in poi le affermazioni valgono sui **sopravvissuti**, mentre l'utente legge la frase davanti al gruppo intero.

| Rilievo | Cosa diceva | Correzione |
| :---- | :---- | :---- |
| `.oldest` | «è la più vecchia» con la copia più vecchia del gruppo destinata al Cestino | frase forte solo se `nothingIsOlder` sul **gruppo intero**, altrimenti variante che dice che una copia più vecchia esiste |
| `.notAnImport` | «le altre stanno in una cartella di scarico» anche con un'altra copia in `Takeout 2/` | frase forte solo se `allOthersAreImports`, altrimenti «almeno un'altra copia» |
| `.deterministicTieBreak` | «che ha il percorso più corto», falso a lunghezze pari (il caso più comune) | nessuna promessa sul percorso: «a parità scelgo sempre la stessa» |
| `.mainLibrary` | vera ma taceva che fra due copie in libreria principale aveva deciso il tie-break | nuovo campo `DuplicateKeepChoice.tiedCandidates` e clausola «un'altra copia va bene quanto questa» |

Corretti nello stesso giro anche: la `precondition` di `duplicateKeepChoice` ora pretende **almeno due membri** (era «non vuoto», mentre `DuplicateGroup` è documentato a due — un gruppo da un membro produceva una riga che dichiara doppione un file che copie non ne ha); `duplicateKeepExplanation` lega i due argomenti (`precondition` che la copia tenuta appartenga al gruppo, e le altre copie ricavate **per differenza dalla tenuta**); il conteggio non è più presentato come un fatto verificato ma come ciò che risulta dall'ultimo controllo (livello 1 di fiducia, ADR-0002/0003); il doc-comment dichiara che questa funzione **non verifica niente** e che a valle resta obbligatoria la rilettura unanime (ADR-0005); tie-break sui **byte UTF-8** invece che sui grafemi, che dipendono dalla versione Unicode del runtime.

**`DuplicateKeepChoice` guadagna un campo rispetto all'interfaccia dichiarata sopra**: `tiedCandidates: Int`, quante copie restavano indistinguibili alla fine (tenuta compresa). Senza, la frase presenta come motivata una scelta fatta a pari merito. `keeper` e `reason` restano quelli previsti; i Task 3, 4 e 6 non sono ancora scritti, quindi nessun consumatore cambia.

**Il mutante che deve morire:**
| Mutante | Test rosso | Esito misurato (2026-08-28) |
| :---- | :---- | :---- |
| Precedenza `mainLibrary`/`notAnImport` invertita | ~~`testMainLibraryBeatsOrganizedFolder`~~ → `testMainLibraryBeatsImportFolder` | **ucciso** (4 test rossi) |
| «più vecchia» → «più recente» | `testSameFolder_keepsOldest` | **ucciso** (6 test rossi) |
| Tie-break rimosso (ordine di input) | `testTieBreak_isStableAcrossPermutations` | **ucciso** (6 test rossi) |
| `hasPrefix` al posto del confronto per componenti | ~~`testFotografieIPhone_isNotTheMainLibrary`~~ → `testFotoIPhone2_isNotTheMainLibrary` | **ucciso** (4 test rossi) |
| La spiegazione non nomina il numero delle altre copie | `testExplanation_namesTheNumberOfOtherCopies` | **ucciso** |
| Confronto su `displayPath` invece che sulla chiave normalizzata | `testMainLibraryFolder_isRecognizedWhateverTheCase` | **ucciso** |
| Un file nella root conta come cartella di primo livello | `testFileAtTheRootIsNotAFolder` | **ucciso** |
| La cartella nella spiegazione viene dalla chiave minuscola | `testExplanation_namesTheRealFolderOfTheKeptFile` | **ucciso** |
| Il motivo non scende alla regola successiva (la prima che tocca vince) | `testExplanation_coversAllFourReasons` | **ucciso** (23 test rossi) |
| «ha la data più vecchia di tutte» affermato sempre | `testExplanation_oldest_doesNotClaimToBeTheOldestOfTheWholeGroup` | **ucciso** |
| «tutte le altre stanno in un import» affermato sempre | `testExplanation_notAnImport_doesNotClaimAllOtherCopiesAreImports` | **ucciso** |
| La clausola del pari merito rimossa | `testExplanation_saysWhenTheFinalPickWasArbitrary` | **ucciso** |
| La frase torna a promettere il percorso più corto | `testExplanation_tieBreak_doesNotClaimTheShortestPath` | **ucciso** |
| Le altre copie prese con `dropFirst()` invece che per differenza dalla tenuta | `testExplanation_notAnImport_claimsAllOthersOnlyWhenTheyReallyAreImports` | **ucciso al secondo tentativo** — vedi sotto |
| Il conteggio presentato come fatto verificato | `testExplanation_doesNotPresentTheCountAsAVerifiedFact` | **ucciso** |
| Clausola «percorso più corto» del tie-break cancellata | `testTieBreak_prefersTheShortestPath` (riscritto) | **ucciso** (1 test rosso) |
| Il ramo singolare cade nel `default` ⇒ «Ci sono 1 altre copie» | `testExplanation_namesTheNumberOfOtherCopies` (riscritto) | **ucciso** (2 test rossi) |
| `>=` → `>` in `nothingIsOlder` (parità di data) | `testExplanation_oldest_keepsTheStrongClaimWhenTheOldestDateIsATie` | **ucciso** (2 test rossi) |

**Quarta, quinta e sesta riga cieca, trovate dal code-reviewer (2026-08-28).** Non erano mutanti nuovi: erano **regole vive che nessun test guardava**. Il reviewer le ha misurate cancellandole con i 31 test allora esistenti tutti verdi.

- **La clausola «percorso più corto» si poteva cancellare senza far diventare rosso niente**, pur cambiando quale foto sopravvive: in ogni fixture lunghezza e ordine alfabetico **concordavano**, quindi non si contraddicevano mai. Test riscritto su `Other/zz.jpg` contro `Other/aaa/bbb/IMG_0001.JPG`, dove il più corto e il primo in alfabeto sono file diversi.
- **`contains("1")`** era vero anche per la frase sgrammaticata «Ci sono 1 altre copie», cioè proprio l'esito del bug che doveva escludere. Ora si pretende la frase intera, più un `XCTAssertFalse` sulla forma sbagliata.
- **Il confine `>=`/`>` di `nothingIsOlder` non era provato**: altrove le date sono sempre distinte, mentre la **parità di data fra doppioni è la norma** (`cp -p`, `rsync -t` e il restore da Finder preservano l'mtime).

**Nota metodologica, dall'audit del proprio audit.** La ricerca esaustiva su 11.100 gruppi del Security/Rules Auditor **non** avrebbe trovato il primo di questi tre: cancellata la clausola sulla lunghezza, l'ordine resta totale e deterministico, quindi la proposta resta *stabile* e ogni frase resta *vera* — cambia solo **quale** foto sopravvive. Sono due reti ortogonali: le invarianti dell'auditor misurano la verità del testo e la stabilità della proposta, i mutanti del reviewer misurano che la regola di prodotto sia proprio quella e non un'altra ugualmente stabile. **Nessuna delle due copre l'altra, e sul Task 4 servono entrambe.**

**Corsa finale sui tre mutanti (2026-08-28, verificata a mano dopo l'interruzione del team): baseline 32 verdi, mutante 1 ⇒ 1 rosso, mutante 2 ⇒ 2 rossi, mutante 3 ⇒ 2 rossi. 3 su 3 uccisi.** Eseguita su copia nello scratchpad con `derivedDataPath` separato, repo reale mai toccato (verificato per hash prima e dopo).

**Nota (2026-08-28) — due righe di questa tabella erano cieche, e la corsa sui mutanti lo ha confermato.** Il Task 2 non prevedeva mutation testing (il piano lo chiede solo ai Task 4 e 5); e' stato fatto lo stesso, su una copia nello scratchpad, perche' due accoppiamenti mutante/test non reggevano alla lettura:

- **Precedenza invertita.** Con `Foto iPhone/` contro `2019 Vacanze/` — il caso di `testMainLibraryBeatsOrganizedFolder` — nessuna delle due copie sta in un import, quindi la regola 2 non discrimina e invertire l'ordine lascia identici sia la copia tenuta sia il motivo: **il mutante sopravvive**. Serve una copia in `Import/`, dove l'inversione produce lo stesso file ma con motivo `.notAnImport`, cioe' una frase sbagliata sulla schermata che precede la cancellazione. Da qui `testMainLibraryBeatsImportFolder`.
- **`hasPrefix`.** `Fotografie iPhone/` **non** ha come prefisso `Foto iPhone`, quindi quel test passa anche col confronto per prefisso. Il caso che lo uccide e' la cartella sorella `Foto iPhone 2/`, che il prefisso accetta — la stessa trappola per cui `/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`. Entrambi i test restano: il primo documenta l'intento, il secondo e' la rete.

**Terza riga cieca, trovata dalla seconda corsa (2026-08-28).** Il mutante che prende le altre copie con `dropFirst()` invece che per differenza dalla copia tenuta **è sopravvissuto a tutti e 31 i test**: nei casi di prova la copia tenuta era la prima del gruppo, e con la tenuta in prima posizione le due formule coincidono. Riscritto il test mettendo la copia tenuta **per ultima**. È lo stesso schema delle altre due: un test che passa sia col codice giusto sia con quello sbagliato. Corsa finale: **15 mutanti, 15 uccisi**.

Le due cartelle di primo livello (`Foto iPhone`, `Import`) restano scritte **due volte** nel progetto: come chiave normalizzata accanto alla regola di proposta e come letterale nel job di copia (`appendingPathComponent("Foto iPhone")`, `appendingPathComponent("Import")`). Non sono state unificate in questo task — la modifica toccherebbe il codice di copia, che il Task 2 non prevede — ma il debito e' segnalato nel commento accanto alle due costanti.

---

### Task 3: `DuplicateBatch` — il riepilogo del blocco

Logica **pura**. È la prima delle due conferme richieste dalla decisione 4 di Enrico: il riepilogo dettagliato *prima* della conferma vera.

**Files:** Modify `ContentView.swift`; Create `AppBackupFotoTests/DuplicateBatchTests.swift`; Modify `project.pbxproj`.

**Interfaces:**
- Consuma: `DuplicateGroup`, `DuplicateKeepChoice`.
- Produce: `struct DuplicateBatch { let groups: [...]; let fileCount: Int; let reclaimableBytes: Int64; let folderBreakdown: [(folder: String, count: Int)]; let exceedsCap: Bool }` e `DuplicateBatch.summaryLines(...) -> [String]` (testo puro del riepilogo). Consumati dai Task 4 e 6.

- [ ] **Step 1: Scrivi il file di test** (~14 test):
  - **spazio recuperabile = `size × (numero di copie − 1)`**, non `size × numero di copie`: la copia che resta occupa comunque il suo spazio. È l'errore aritmetico più facile della feature.
  - somma su più gruppi di dimensioni diverse
  - conteggio file da cestinare = somma di `(membri − 1)`
  - ripartizione per cartella: due gruppi che pescano dalla stessa cartella producono **una** riga con conteggio 2
  - ordinamento di default: **spazio recuperabile decrescente**; a parità, numero di copie decrescente
  - tetto: sopra la soglia `exceedsCap == true`; esattamente alla soglia `false` (off-by-one)
  - blocco vuoto ⇒ zero, nessun crash, e il riepilogo lo dice invece di mostrare «0 file»
  - il riepilogo dice **i file**, non i gruppi (il numero che conta è quello dei file che si spostano)
  - il riepilogo contiene la riga **«lo spazio si libera quando svuoti il Cestino»** — misurato: cestinare non libera spazio
  - il riepilogo contiene la riga **«le copie su HDD e su Cubbit restano dove sono»** — i mirror non cancellano mai
  - registro anti-gergo: nessun «hash», «indice», «SHA256»

- [ ] **Step 2–3: registra, verifica il fallimento atteso.**
- [ ] **Step 4: Implementa.** Tetto **500 file / 50 GB**, il primo che scatta — confermato da Enrico il 2026-08-28. È una costante nominata, con un commento che dice **perché** quel numero: non la durata (il cestinamento misura ~56 file/s, quindi 500 file ≈ 9 secondi; il tempo vero se lo prende la rilettura che lo precede) ma il **raggio di un guasto a metà blocco**, che la misura 3 della spec mostra essere uno stato reale. Il commento deve dire anche che il numero è prudente e ritarabile alla prima passata reale con l'SSD.
- [ ] **Step 5–6:** attesi **410 test** (396 + 14).

**Il mutante che deve morire:**
| Mutante | Test rosso |
| :---- | :---- |
| `size × count` invece di `size × (count − 1)` | `testReclaimableSpace_excludesTheKeptCopy` |
| Tetto non applicato / `>` invece di `>=` | `testCap_boundary` |
| Il riepilogo conta i gruppi invece dei file | `testSummary_countsFilesNotGroups` |
| Le due righe di avvertimento rimosse | `testSummary_saysSpaceIsFreedOnlyWhenTrashIsEmptied`, `testSummary_saysMirrorsKeepTheirCopies` |

---

### Task 4: `DuplicateTrasher` — il motore di cancellazione

**È il task pericoloso.** L'unico componente del progetto che sposta un file foto. Va scritto per ultimo fra quelli logici e revisionato con la massima severità.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`
- Modify: `AppBackupFoto/ContentView.swift` — estrazione di `deviceIdentifier(of:)` da `LibraryIndexer` (oggi `private`) a **funzione libera `nonisolated`**, accanto a `realResolvedPath`. Fonte unica: il progetto ha già pagato due volte la duplicazione della stessa logica (`LibraryExclusions`, `realResolvedPath`). `LibraryIndexer` la consuma da lì, senza cambiare comportamento.
- Create: `AppBackupFotoTests/DuplicateTrasherTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `DuplicateGroup`, `DuplicateKeepChoice`, `IndexableKind`, `sha256Measured`, `realResolvedPath`/`canonicalPathComponents`, `deviceIdentifier`, `LibraryIndexStore.remove(keys:)`, `TrashManifestStore.record(...)` (Task 5 — **il Task 5 va fatto prima di questo Step 4**, oppure l'interfaccia va stubbata e cablata in coda al Task 5; scegliere l'ordine e dichiararlo, non lasciarlo implicito).
- Produce: `final class DuplicateTrasher` con `init(libraryRoot:store:manifest:trashFunction:hashFunction:)` — **`trashFunction` e `hashFunction` hanno per default le funzioni reali** (`FileManager.default.trashItem`, `sha256Measured`) e sono iniettate **solo dai test**: gli esiti da coprire (hash che cambia fra visualizzazione e cancellazione, scollegamento a metà blocco) non sono producibili su file veri senza una corsa fra thread, e un test basato su una corsa è verde col bug ogni volta che la corsa va nell'altro verso. Stesso pattern già in `FileSyncer.init(hashFunction:)`.
- Produce: `struct DuplicateTrashOutcome { trashedFiles, skippedGroups: [(group, reason)], stoppedBecauseVolumeVanished: Bool, interrupted: Bool }`.

> **Due vincoli nati nell'audit del Task 2 (2026-08-28), da rispettare qui.** Non sono suggerimenti: chiudono due buchi misurati, e nessuno dei due è coperto dalle guardie già scritte nel Task 2.
>
> 1. **La coppia (gruppo, copia tenuta) va congelata al momento della conferma dell'utente** e passata così al `DuplicateTrasher`, **mai ricalcolata all'esecuzione**. Fra il riepilogo che l'utente legge e il cestinamento l'indice può essere cambiato (mtime diversi, membri diversi), e una `duplicateKeepChoice` ricalcolata su dati nuovi può nominare **un'altra copia**: l'utente acconsente a cestinare A e viene cestinato B. Attenzione: la `precondition` di appartenenza dentro `duplicateKeepExplanation` **non intercetta questo caso**, perché confronta solo il `path` — una `choice` stantia su un gruppo ricaricato la passa indenne, prendendo il conteggio dai membri nuovi e la cartella dalla copia tenuta vecchia.
> 2. **`duplicateKeepChoice` non va chiamata dentro il ciclo di cestinamento.** Ha due `precondition`, e un crash fra `trashItem` e la scrittura del registro di ripristino lascia un file nel Cestino **non registrato** — la spec ha misurato che il record «Rimetti a posto» del Finder è asincrono e si perde proprio quando il processo muore (74/300 persi in un caso). Tutte le scelte vanno risolte **prima** di aprire il ciclo. Il filtro difensivo sui gruppi ridotti a un solo membro (`groups.filter { $0.members.count > 1 }`) va messo al confine del Task 3/6, non ammorbidendo le guardie del Task 2.

- [ ] **Step 1: Scrivi il file di test** (~30 test), su directory temporanee reali (nessun mock del filesystem — convenzione del progetto).

  **Verifica prima della cancellazione:**
  - gruppo sano di 3 file identici ⇒ 2 cestinati, il tenuto resta, indice aggiornato
  - **un membro da cestinare ha contenuto diverso** ⇒ **l'intero gruppo saltato**, zero file cestinati, motivo riportato
  - **il file TENUTO ha contenuto diverso** ⇒ **l'intero gruppo saltato**. È il test che distingue il livello 3 di fiducia dal livello 2: rileggere solo i file da cestinare direbbe che sono uguali *fra loro*, non che sono uguali a quello che resta
  - un membro illeggibile (`hashFunction` restituisce `nil`) ⇒ gruppo saltato. Mai «cestino quelli che ho potuto verificare»
  - un membro con dimensione diversa da quella indicizzata ⇒ gruppo saltato
  - un membro non esiste più ⇒ gruppo saltato
  - hash unanimi fra loro ma **diversi dall'hash del gruppo** ⇒ gruppo saltato (l'indice era stantio su tutti i membri)

  **Guardie:**
  - una entry il cui percorso è **fuori** dalla root della libreria ⇒ mai cestinata, gruppo saltato, e il test usa un percorso che è **prefisso testuale ma non componente** della root (es. root `/tmp/x/SSD`, file in `/tmp/x/SSD 2/`) — altrimenti il test passa anche con `hasPrefix`
  - una entry che non è `.image`/`.video` (`.txt`, `.aae`) ⇒ mai cestinata
  - il file **tenuto non viene mai passato a `trashFunction`**: il test registra ogni chiamata e verifica che il percorso del tenuto non compaia
  - un gruppo con un solo membro ⇒ nessuna cancellazione

  **Scollegamento (la misura più importante della spec):**
  - `trashFunction` che lancia `NSError(NSCocoaErrorDomain, 4)` **e** `st_dev` della root cambiato ⇒ **l'intero blocco si ferma**, `stoppedBecauseVolumeVanished == true`, e il numero di file già cestinati è riportato onestamente
  - `trashFunction` che lancia `NSCocoaErrorDomain/4` **senza** cambio di `st_dev` ⇒ **solo quel gruppo** viene chiuso, il blocco prosegue, il fallimento è contato. È l'altra metà: i due casi hanno lo stesso errore e vanno distinti dal `st_dev`, non dall'errore
  - `NSCocoaErrorDomain/4` **non** viene mai trattato come «era già sparito, tutto a posto»

  **Post-condizione e indice:**
  - il file tenuto sparisce a metà gruppo ⇒ i file appena cestinati di quel gruppo vengono **rimessi a posto**
  - dall'indice si rimuovono **solo** le chiavi dei file effettivamente cestinati, mai quella del tenuto, mai quelle dei gruppi saltati
  - `trashFunction` che fallisce ⇒ **la entry resta nell'indice** (ordine: prima si cestina, poi si rimuove)
  - interruzione a metà blocco ⇒ i gruppi già chiusi restano chiusi, l'indice è coerente, `interrupted == true`

  **Invariante strutturale:**
  - con una `trashFunction` iniettata **che non fa nulla**, tutti i file del gruppo **esistono ancora** a fine corsa. Se il codice chiamasse anche `removeItem` da qualche parte, questo test diventerebbe rosso — è il modo di provare che `trashItem` è l'unica porta senza affidarsi a una lettura del codice

- [ ] **Step 2–3: registra il file, verifica il fallimento atteso.**

- [ ] **Step 4: Implementa** seguendo alla lettera la sequenza della sezione «La cancellazione — il percorso ad alto danno» della spec (8 punti). Ogni guardia ha accanto un commento di **una riga** che dice cosa succederebbe senza — la convenzione già usata in tutto `ContentView.swift` per le guardie non ovvie.

- [ ] **Step 5: Test verdi** — `Executed 30 tests, with 0 failures`.

- [ ] **Step 6: Mutation testing sui mutanti elencati sotto.** Un mutante sopravvissuto significa **riscrivere il test**, non il codice. Riporta il conteggio (`N mutanti, N uccisi`) nel commit.

- [ ] **Step 7: Build, suite completa, commit** — attesi **440 test** (410 + 30).

**Il mutante che deve morire:**
| Mutante | Test rosso |
| :---- | :---- |
| Si rileggono solo i file da cestinare, non il tenuto | `testKeeperContentChanged_skipsWholeGroup` |
| Un membro con hash diverso viene solo escluso, gli altri si cestinano | `testOneMemberDiffers_skipsWholeGroup` |
| `nil` da `hashFunction` trattato come «coincide» | `testUnreadableMember_skipsWholeGroup` |
| Il controllo di `st_dev` dopo un fallimento viene rimosso | `testUnmountMidBatch_stopsEverything` |
| `NSCocoaErrorDomain/4` trattato come successo o come «già fatto» | `testFileNotFoundError_isNeverTreatedAsDone` |
| Confinamento con `hasPrefix` invece che per componenti | `testSiblingRootWithCommonPrefix_isRefused` |
| Guardia `IndexableKind` rimossa | `testNonMediaEntry_isNeverTrashed` |
| Off-by-one che include il tenuto nel ciclo | `testKeeperIsNeverPassedToTrash` |
| Rimozione dall'indice **prima** del cestinamento | `testTrashFailure_leavesIndexEntry` |
| Rimozione dall'indice anche per i gruppi saltati | `testSkippedGroup_leavesIndexUntouched` |
| Un `removeItem` aggiunto «per pulizia» | `testNoOpTrashFunction_leavesEveryFileOnDisk` |
| Il tenuto sparito non fa scattare il ripristino | `testKeeperVanished_restoresWhatWasJustTrashed` |

---

### Task 5: `TrashManifest` — il registro di ripristino e l'annullamento

La rete di sicurezza della decisione 2 di Enrico non può poggiare sul Finder: **misurato che il record «Rimetti a posto» è scritto in modo asincrono e va perso** se il processo muore subito dopo (226/300 e 85/100 in due misure indipendenti; 100/100 solo con il processo vivo).

**Files:** Modify `ContentView.swift`; Create `AppBackupFotoTests/TrashManifestTests.swift`; Modify `project.pbxproj`.

**Interfaces:**
- Consuma: `sha256Measured`, `FileManager.moveItem`, la stessa directory di Application Support già usata da `LibraryIndexStore`.
- Produce: `struct TrashManifest: Codable`, `struct TrashedItem: Codable { originalDisplayPath, originalKey, trashedPath, size, hash, trashedAt }`, `final class TrashManifestStore { func record(_:); func lastBatch() -> [TrashedItem]; func restore(_:) -> RestoreOutcome }`. Consumato dai Task 4 e 6.

- [ ] **Step 1: Scrivi il file di test** (~18 test), su directory temporanee reali:
  - una voce registrata è rileggibile dopo un ciclo apri/scrivi/chiudi/riapri
  - **la voce è su disco subito dopo `record`, non a fine blocco**: il test registra una voce, riapre lo store da zero e la trova. È la lezione diretta della misura: un registro differito ha lo stesso difetto di quello del Finder
  - ripristino di un file: torna al percorso originale, dimensione e contenuto intatti
  - ripristino con le **cartelle intermedie cancellate** nel frattempo: vengono ricreate
  - **il file nel Cestino è stato alterato** (hash diverso) ⇒ **non si ripristina**, e lo si dice
  - **il percorso originale è di nuovo occupato** ⇒ **non si sovrascrive**, e lo si dice. Non basta affidarsi al rifiuto di `moveItem` (misurato `NSCocoaErrorDomain/516`): la guardia è nostra e va provata
  - il file nel Cestino **non esiste più** (Cestino svuotato) ⇒ voce non ripristinabile, messaggio, nessun errore fatale
  - un blocco con 3 voci di cui una non ripristinabile ⇒ le altre 2 vengono ripristinate
  - retrocompatibilità: un record scritto **senza** un campo aggiunto dopo si decodifica lo stesso (`init(from:)` esplicita + `decodeIfPresent`; il default sulla proprietà da solo è una retrocompatibilità **finta** — fatto misurato n. 5 di #31, che aveva fatto sparire in silenzio l'ultimo job dal pannello Revisione)
  - un file di registro spazzatura ⇒ si riparte da vuoto, mai un crash e mai un blocco dell'app
  - permessi `0600` sul file del registro, verificati **dopo** un ciclo completo di scrittura/riapertura, con auto-skip se l'umask del processo di test è già restrittiva (altrimenti il test è verde senza dimostrare niente) — stesso schema del test sui permessi dell'indice
  - il registro è dentro `~/Library/Application Support/AppBackupFoto/`, **mai sull'SSD**: allow-list riusata, non riscritta
  - tetto alle voci conservate, con il conteggio totale a parte, così il numero mostrato resta veritiero a lista troncata (stessa forma di `UnverifiedCopies.maxPaths`)

- [ ] **Step 2–3: registra, verifica il fallimento atteso.**
- [ ] **Step 4: Implementa.**
- [ ] **Step 5: Test verdi.**
- [ ] **Step 6: Mutation testing** sui mutanti sotto.
- [ ] **Step 7: Build, suite, commit** — attesi **458 test** (440 + 18).

**Il mutante che deve morire:**
| Mutante | Test rosso |
| :---- | :---- |
| `record` bufferizzato e scritto a fine blocco | `testRecordIsOnDiskImmediately` |
| Ripristino senza verifica dell'hash | `testAlteredTrashedFile_isNotRestored` |
| Ripristino che sovrascrive il percorso originale | `testOccupiedOriginalPath_isNotOverwritten` |
| Una voce non ripristinabile interrompe le altre | `testOneBadEntry_doesNotBlockTheOthers` |
| `init(from:)` sintetizzata al posto di quella esplicita | `testOldRecordWithoutNewField_stillDecodes` |
| Registro scritto sotto la root della libreria | `testManifestLocation_isRefusedOutsideAppSupport` |

---

### Task 6: `DuplicatesView` — la finestra, le due conferme, le miniature

La parte SwiftUI non è testabile senza una corsa reale; **è testato tutto ciò che sta ai due capi del cablaggio**, come già dichiarato per la card di #31.

**Files:** Modify `ContentView.swift` (nuova scena `Window`, la view, l'aggancio nella `LibraryIndexCard`); Create `AppBackupFotoTests/DuplicatesStatusTests.swift`; Modify `project.pbxproj`.

**Interfaces:** consuma tutti i componenti dei Task 1–5, `AuthGateManager`, `makeThumbnail`, `BackupRunner.isRunning`, `VolumeMonitor`. Produce `Window("Doppioni", id: "duplicates")`, `DuplicatesView`, `DuplicatesStatus.lines(...)` (pura), `DuplicateThumbnailCache`.

- [ ] **Step 1: Scrivi il file di test** (~12 test) sulle sole parti pure:
  - indice mai costruito ⇒ riga che **rimanda alla card**, mai una lista vuota che si legge come «non hai doppioni» (stessa classe di errore già corretta con `sawNothing`)
  - indice costruito, zero gruppi ⇒ riga diversa dalla precedente
  - N gruppi ⇒ riga con il numero di gruppi **e** i byte recuperabili
  - job in corso ⇒ riga che spiega perché la cancellazione è disattivata
  - SSD scollegato ⇒ riga propria, diversa da «nessun doppione»
  - blocco sopra il tetto ⇒ riga che dice «fallo in più volte», non un rifiuto muto
  - esito con gruppi saltati ⇒ riga con **il numero** e il motivo, mai un silenzio
  - esito interrotto dallo scollegamento ⇒ riga propria con quanti file erano stati spostati
  - registro anti-gergo su tutte le diramazioni: nessun «hash», «indice», «SHA256», «entry», «scansione»
  - cache miniature: oltre il tetto la più vecchia viene sfrattata; la dimensione non supera mai il tetto

- [ ] **Step 2–3: registra, verifica il fallimento atteso.**

- [ ] **Step 4: Implementa la view.** Requisiti non negoziabili:
  - **Gate `AuthGateManager`** all'inizio del `body` (`LockScreenView()` al posto del contenuto reale) e `.restorationBehavior(.disabled)`. Regola #30: una scena di primo livello nasce fuori dal gate, e questa elenca percorsi, nomi e miniature di tutte le foto.
  - Gli avvisi sono `@State` **locali della view**, mai `runner.pendingAlert` — che ha un solo presentatore, il `.alert` di `ContentView` nella scena `main` (sezione `AlertSink` in `.claude/rules/architecture.md`). Nessun secondo presentatore di `pendingAlert`.
  - **Due conferme distinte**: riepilogo dettagliato (`DuplicateBatch.summaryLines`) in uno sheet, **poi** la conferma vera, che è un **`.alert` con bottone distruttivo** (deciso il 2026-08-28). **Non** una stringa da ridigitare: quella resta il segnale esclusivo della formattazione, l'unica operazione irreversibile del progetto, e usarla anche qui — dove il cestinamento è annullabile due volte — la svaluterebbe proprio dove serve. Di conseguenza il peso della conferma sta tutto nel riepilogo: se quello è vago, non c'è alert che tenga.
  - Il conteggio dei gruppi **non** si legge nel `body` con una query sincrona allo store: quella query passa dalla coda seriale, occupata dalle scritture a batch, e sul main thread bloccherebbe la finestra a ogni ridisegno. Si carica fuori dal main thread e si pubblica, come già fa `BackupRunner.indexedFileCount`.
  - **Una miniatura per gruppo**, dal file tenuto, pigra (`LazyVStack` + `.task`), con token di richiesta e cache limitata. `makeThumbnail` esistente, **mai** una seconda implementazione, **mai** l'immagine intera. Video: icona di sistema, nessun fotogramma e nessun `AVAssetImageGenerator` in questa versione (deciso il 2026-08-28).
  - Cancellazione disattivata se un job è in corso, se una scansione dell'indice è in corso, o se l'SSD non è montato — con il **motivo scritto**, non un bottone grigio e basta (stessa disciplina di `RestoreView`, dove le fonti non disponibili sono disattivate *e* motivate).
  - Progresso e interruzione durante il blocco.
  - Bottone **«Annulla l'ultimo spostamento»**, attivo solo se il registro ha un blocco ripristinabile.
  - Ingresso: bottone dentro `LibraryIndexCard` in Diagnostica (`openWindow(id: "duplicates")`), **unico** — nessuna voce nell'hamburger, nemmeno disattivata (deciso il 2026-08-28).
  - **I membri a pari merito vanno marcati visivamente nella lista** (requisito nato dall'audit del Task 2, 2026-08-28). `DuplicateKeepChoice.tiedCandidates` dice **che** un'altra copia vale quanto quella tenuta, ma non **quale**: in un gruppo da tre membri l'utente legge «Un'altra copia va bene quanto questa» davanti a **due** righe, e sta per cestinarle entrambe senza sapere a quale si riferisce. L'informazione è vera ma non azionabile finché la riga corrispondente non è riconoscibile. Se la view non può marcarle, allora è la frase a dover nominare il percorso invece del numero.

- [ ] **Step 5–6: test verdi, build, suite, commit** — attesi **470 test** (458 + 12).

- [ ] **Step 7: Dichiara esplicitamente cosa NON è coperto da test** nel commento in testa alla view e in `.claude/rules/architecture.md`: la view, i due sheet di conferma, il gate, l'apertura della finestra, le miniature. Sono SwiftUI e bookmark veri, non raggiungibili senza una corsa.

---

### Task 7: Documentazione — la regola assoluta, gli ADR, il vocabolario

Nessun test. Va fatto **prima** di considerare la feature chiusa, non dopo: una regola assoluta cambiata e non scritta è un'eccezione silenziosa che qualcuno estenderà.

**Files:** `Docs/CLAUDE.md`, `Docs/adr/0005-il-pannello-doppioni-puo-cestinare.md` (nuovo), `Docs/adr/0002-indice-cache-non-fonte-di-verita.md`, `Docs/adr/0003-due-livelli-di-fiducia-sullo-stesso-indice.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`.

- [ ] **Step 1: `Docs/CLAUDE.md` — la regola assoluta.** Riscrivi i punti 1 e 3 col testo approvato da Enrico il 2026-08-28, riportato **parola per parola** nella spec, sezione «La regola assoluta cambia» — copiarlo, non riscriverlo a memoria: la clausola sulla rilettura unanime («ogni membro del gruppo, la copia tenuta compresa») è stata aggiunta apposta e non va persa. Aggiungi il ramo `trashItem` alla checklist di revisione AI, che oggi conosce `removeItem`/`moveItem`/`copyItem` ma non `trashItem`. Aggiorna la tabella di stato (pannello Doppioni non più «mai iniziato»), il conteggio dei test e la riga «Prossimo incremento naturale», che oggi descrive il pannello come «quello a basso danno, dove ci si fida della cache invece di rileggere» — **frase ora falsa**.
- [ ] **Step 2: ADR-0005 nuovo.** Contenuto in «Cosa cambia negli ADR esistenti» nella spec. Deve contenere le tre misure del 2026-08-27 e la contro-domanda per chi un giorno proporrà di togliere la rilettura del file tenuto «perché tanto l'indice ce l'ha già».
- [ ] **Step 3: nota datata in ADR-0003** — «pannello Doppioni = basso danno» vale ora solo per la **visualizzazione**; i livelli sono tre; rimando ad ADR-0005. Nota, non riscrittura: il ragionamento dell'ADR è ancora valido.
- [ ] **Step 4: nota datata in ADR-0002** — la cache non può mai essere la sola base di un atto distruttivo; e la rimozione mirata delle chiavi dopo il cestinamento è **conoscenza, non inferenza**, quindi non ricade sotto «traversata incompleta ⇒ nessuna rimozione».
- [ ] **Step 5: `Docs/CONTEXT.md`** — voci nuove (**Gruppo di doppioni**, **Copia tenuta**, **Blocco**, **Registro di ripristino**) e correzione della voce «Percorso a basso danno / percorso ad alto danno».
- [ ] **Step 6: `.claude/rules/architecture.md`** — sezione nuova sotto quella di #31, con i componenti, le guardie, i mutanti uccisi e i fatti misurati del 2026-08-27 (che vanno nella lista «Fatti misurati — da non riscoprire pagandoli una seconda volta», in coda ai sei esistenti).
- [ ] **Step 7: verifiche manuali pendenti.** Aggiungi a `Docs/CLAUDE.md`, accanto a quelle già in attesa dell'SSD: `trashItem` sull'SSD vero dall'app firmata; esistenza e contenuto di `.Trashes` su quel volume; `ls -1 "/Volumes/SSD - Enri"` per validare la regola di proposta del Task 2 — e con quel layout davanti, **chiudere la decisione rimandata da Enrico il 2026-08-28 su dove collocare `Takeout/` e `Takeout 2/` nella gerarchia** (alla pari delle cartelle organizzate, com'è ora in via provvisoria, oppure declassate accanto a `Import/` perché sono estrazioni automatiche); «Rimetti a posto» premuto davvero nel Finder.
- [ ] **Step 8: commit.**

---

## Riepilogo dei conteggi

| Task | Test nuovi | Cumulativo atteso |
| :---- | ----: | ----: |
| baseline (`310efa5`) | — | **346** |
| 1 — `duplicateGroups()` | ~~14~~ **18 (reale)** | ~~360~~ **364 (reale)** |
| 2 — `duplicateKeepChoice` | ~~18~~ **31 (reale)** | ~~378~~ **395 (reale)** |
| 3 — `DuplicateBatch` | 14 | 392 → **409** |
| 4 — `DuplicateTrasher` | 30 | 422 → **439** |
| 5 — `TrashManifest` | 18 | 440 → **457** |
| 6 — `DuplicatesView` / `DuplicatesStatus` | 12 | 452 → **469** |
| 7 — documentazione | 0 | 452 → **469** |

I cumulativi dei Task 3-7 sono scalati di **+17** rispetto al piano originale: **+4** dopo il Task 1 e **+13** dopo il Task 2 (5 test dalla prima corsa sui mutanti, 8 dai rilievi dell'audit), a parita' di incrementi previsti per i task successivi. Il Task 1 ha scritto 18 test invece dei 14 previsti, tutti nati dalla corsa sui mutanti (guardia Swift sui gruppi ridotti a un membro leggibile, file da 0 byte che non devono nascondere i gruppi veri, file da 0 byte dentro un gruppo sano, dimensione minima su indice incoerente). Restano target, non profezie.

I numeri per task sono **target**, non profezie: se la copertura reale ne richiede di più, si aggiornano qui. Quello che non si aggiusta è il metodo — **si verifica il conteggio totale nel log a ogni task**, mai il solo `** TEST SUCCEEDED **`.

## Nota sull'ordine dei task

Il Task 4 consuma `TrashManifestStore`, prodotto dal Task 5. Due ordini possibili: **5 prima di 4** (nessuno stub, ma si scrive il registro prima di sapere esattamente cosa registrare), oppure **4 con un'interfaccia stubbata** e cablaggio in coda al Task 5. Raccomandazione: **5 prima di 4**, rinumerando. Il registro è autonomo e la sua forma è già determinata dalla misura sul record del Finder; scriverlo prima evita l'unico stub del piano.

**Deciso il 2026-08-28: si esegue 5 prima di 4.** È una scelta di implementazione, non di prodotto, quindi presa senza girarla a Enrico (stesso criterio già usato nel progetto). I numeri dei task restano quelli scritti sopra per non invalidare i riferimenti incrociati: cambia l'ordine di esecuzione, non la numerazione.
