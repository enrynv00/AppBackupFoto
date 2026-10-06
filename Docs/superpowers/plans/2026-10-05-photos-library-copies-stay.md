# Le copie che la libreria Foto del Mac ha ancora non si spostano mai — Implementation Plan

**Stato: APPROVATO da Enrico il 2026-10-06** — D1-D3, D5 (testo della Regola assoluta) e D6 approvati come proposti; D4: «Ottimizza spazio del Mac» è spento, gli originali sono tutti sul Mac.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: DA APPROVARE.** Scritto dall'Architect il 2026-10-05 sera. Le decisioni D1-D6 qui sotto sono di Enrico; finché non le ha lette, l'Implementer non parte.

**Base:** `feature/certified-duplicates-ssd` a `63a7a0c` (1.219 test, non ancora unito a `main`). Si continua **sullo stesso branch** (D6): è un difetto del progetto 3 (#46) trovato durante la sua verifica dal vivo, prima dell'unione. Numerazione proposta: **ADR-0018**, nessun numero ROADMAP nuovo (riga aggiunta a #46).

**Problema (verificato dal vivo da Enrico e dall'orchestratore, 2026-10-05).** Il backup MAC → SSD copia `~/Pictures/Photos Library.photoslibrary/originals/<X>/<file>` in `/Volumes/SSD - Enri/Foto iPhone/<X>/<file>` e copia solo ciò che manca. La libreria Foto contiene doppioni veri (asset diversi, stesso contenuto), quindi l'SSD ha gruppi di doppioni dentro `Foto iPhone/`. Il pannello Doppioni ne sposta una copia nel Cestino → il backup successivo la **ricopia** (esiste ancora in `originals`). Degli 8 file spostati da `Foto iPhone/`, 6 sono già tornati (es. `1103F08E-…BA1C.mp4`, `F4E891D9-…5B25.mov`).

**Decisione di Enrico (opzione 1).** Una copia in `Foto iPhone/` il cui originale c'è ancora in `originals` **non si sposta mai**. Le altre copie del gruppo (fuori da `Foto iPhone/`, o in `Foto iPhone/` ma non più in Foto) si spostano come prima. Se tutte le copie in più di un gruppo sono «nella libreria», il gruppo non ha niente da spostare: casella spenta, con il motivo e cosa fare (toglierle da Foto, non dall'app). In più: voce **«Doppioni»** nel pannello laterale, accanto a «Inventario».

**Goal:** nessuna copia in `Foto iPhone/` ancora presente nella libreria Foto del Mac arriva mai a `trashItem` — né dal pannello (non è fra le copie che escono) né dal trasher (che la ricontrolla dal vivo e rifiuta il gruppo); la copia tenuta è, quando c'è, una copia «nella libreria»; conteggi, byte, piano a blocchi, riepilogo e progresso contano solo le copie che escono davvero.

**Architecture:** un tipo puro nuovo e quattro ritocchi.
- `PhotosLibraryPresence` (`nonisolated`, value type): l'insieme delle chiavi dell'elenco che i file di `originals` hanno sull'SSD (`normalizedIndexKey("Foto iPhone/" + percorso in originals)`), letto **una volta per caricamento** del pannello, fuori dal main, dal bookmark `.photos`; `nil` = non si sa ⇒ **ogni** copia in `Foto iPhone/` «nella libreria» (verso sicuro: bookmark non risolto, cartella assente, una sottocartella illeggibile, zero file). `holds(entry)`: copia in `Foto iPhone/` (per componente) **e** nella libreria (o non si sa).
- `duplicateKeepChoice(_:rule:photos:)` (parametro senza default): regola **1b** dopo la regola 1 — fra le copie della libreria principale, quella «nella libreria»; e restituisce in `DuplicateKeepChoice.keptByPhotosLibrary` le **altre** copie «nella libreria», decise e congelate con la tenuta.
- `DuplicateBatch.Entry.leaving` esclude `keptByPhotosLibrary`: file, byte, cartelle, piano a blocchi, stima, progresso e ciò che arriva al trasher seguono da soli. `DuplicateBatch` guadagna `nothingToMove` (hash dei gruppi senza copie che escono) e `keptByPhotosLibraryCount`; `summaryLines()` dice quante copie restano e perché.
- `DuplicateTrasher` (ultima linea di difesa): `Decision.keptByPhotosLibrary` (mai a `trashItem`, ma riletto per l'unanimità) e `init(…, photosLibraryRoot: URL?)` senza default; subito prima dei `trashItem` di un gruppo, per ogni copia in uscita in `Foto iPhone/`, ricontrolla **dal vivo** `originals/<resto del percorso>` (`fileExists`): presente ⇒ gruppo saltato `.stillInPhotosLibrary`; libreria non configurata/assente/vuota o percorso con `.`/`..` ⇒ `.photosLibraryUnreadable`. Il runner passa le due cose.
- `DuplicatesView`: un punto solo per «si può spuntare» (`DuplicatesStatus.canSelect`: garanzia dell'inventario **e** qualcosa da spostare), riga del motivo (`DuplicatesStatus.rowBlockedLine`, precedenza «niente da spostare» > garanzia), etichetta «RESTA · È ANCORA IN FOTO» per le copie che restano, riga in testa sulla libreria Foto (`DuplicatesStatus.photosLibraryLine`). Voce «Doppioni» in `HamburgerPanel`.

**Tech Stack:** Swift 5.x, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, SwiftUI, XCTest. Nessuna dipendenza, nessuno schema, nessun file su disco, nessuna chiave `UserDefaults` nuova.

**Verifica preventiva dell'Architect (2026-10-05), senza `xcodebuild`.** Codice dei Task 1-3 e **tutti** i test compilati ed eseguiti fuori da Xcode in `/private/tmp/claude-501/pinned-plan/proto/`: `ContentView.swift` di `63a7a0c` + patch `proto/patches/0N-*.py` (una per task, ogni «Trova» presente esattamente una volta, applicate in ordine), `swiftc` con le impostazioni del target, 81 file di test esistenti (con le modifiche dichiarate) + 2 nuovi in un bundle lanciato con `xcrun xctest`. Ogni task verificato anche da solo, in ordine (patch fino al task N + test fino al task N, `proto/tests-tN/`): **1.247 → 1.256 → 1.262 test, 0 fallimenti, 0 warning** (app e test). Mutanti: vedi in fondo. Prova a secco di `apply.py` su una copia dei tre file del repository (stessi conteggi). Differenze volute del prototipo, solo lì: stub di Sparkle, niente `@main`, `isRunningUnderTests()` = `true`. **Non eseguiti** (SwiftUI e bookmark veri): il cablaggio in `DuplicatesView`, `HamburgerPanel` e `BackupRunner.startDuplicateTrashRun`. **Nessuna scrittura su `/Volumes`, nessuna rete, repository non toccato.**

**Fatti letti dall'Architect sul Mac di Enrico (sola lettura, 2026-10-05 sera):**
- Il bookmark `bk_photos` si risolve in `/Users/enriconannivicenzi/Pictures/Photos Library.photoslibrary/originals` (non stantio); `bk_ssd` in `/Volumes/SSD - Enri`. `runMacToSSD` copia da quella cartella a `<SSD>/Foto iPhone`: la mappa `originals/<rel>` ↔ `Foto iPhone/<rel>` è esatta.
- `originals` ha 16 sottocartelle `0`-`F` e **18.472 file**; `find` li elenca in **0,11 s**: leggerli a ogni caricamento del pannello non costa niente.
- I due file del caso dal vivo esistono in `originals/1/` e `originals/F/` (il `.mp4` pesa 1,1 GB).
- Il disco del Mac **non distingue le maiuscole** (`ls` con il percorso tutto in minuscolo trova il file): il `fileExists` del ricontrollo dal vivo non dipende da come sono scritte.

---

## Decisioni da far approvare (con la raccomandazione)

Nessuna è stata applicata di nascosto: il piano implementa la «Raccomandazione»; se Enrico sceglie l'alternativa, l'Implementer si ferma e rimanda all'Architect.

| # | Domanda | Raccomandazione (implementata) | Alternativa / costo |
| :--- | :--- | :--- | :--- |
| D1 | Preferire come **tenuta** una copia «nella libreria»? | **Sì** (regola 1b, dopo la regola 1). Una copia «nella libreria» resta comunque: se la tenuta fosse un'altra, resterebbero **due** copie. Caso tipico: `Foto iPhone/0/A.jpg` (tolta da Foto, più vecchia) e `Foto iPhone/1/B.jpg` (ancora in Foto): oggi vincerebbe A per data e B resterebbe lo stesso ⇒ niente da spostare; con 1b si tiene B e A esce (il backup non la ricopia, il suo originale non c'è più). Dopo la regola 1 e non prima: la tenuta è identica nei due ordini (ogni copia «nella libreria» sta in `Foto iPhone/`), e così il caso comune (una copia in `Foto iPhone/`, le altre fuori) mantiene motivo e frase di oggi (`.mainLibrary`). | Nessuna preferenza: più semplice, ma tiene due copie in casi come sopra e la spiegazione nominerebbe come «tenuta» una copia mentre un'altra resta per un altro motivo. |
| D2 | La regola per cartella dell'utente può spostare una copia «nella libreria»? | **No, la regola resta sovrana sulla tenuta ma non sposta mai una copia «nella libreria»**: con «tieni in Takeout, sposta da Foto iPhone» un gruppo `Takeout` + `Foto iPhone` (ancora in Foto) tiene Takeout, la copia in `Foto iPhone/` resta, e il gruppo non ha niente da spostare (casella spenta con il motivo). | Far vincere 1b sulla regola (tenere `Foto iPhone/`, spostare Takeout): libera spazio ma contraddice un'istruzione esplicita («tieni in Takeout»). |
| D3 | Libreria Foto **vuota** o letta a metà | **Vale «non si sa»**: ogni copia in `Foto iPhone/` resta (riga d'avviso in testa con cosa fare). Una libreria vuota e una illeggibile si confondono, e la seconda renderebbe spostabile tutto. Prezzo: se un giorno Enrico svuotasse davvero Foto, le copie in `Foto iPhone/` non si sposterebbero più dal pannello. | Fidarsi di zero file: sposta tutto ciò che la libreria non mostra, anche quando non l'ha mostrato perché non si lasciava leggere. |
| D4 | «Ottimizza spazio del Mac» in Foto | **Da chiedere a Enrico se è acceso.** Con l'opzione accesa, un originale può mancare da `originals` (è solo su iCloud): la copia in `Foto iPhone/` risulta «non più in Foto» e può uscire; il backup non la ricopia **finché** Foto non riscarica l'originale, poi sì. Nessuna foto si perde (la copia tenuta resta, HDD e Cubbit intatti): torna solo il doppione. Misura: `originals` ha 18.472 file, l'elenco dell'SSD ne aveva 18.530 in `Foto iPhone/` il 2026-09-24 — non dice niente da solo. | Interrogare il database di Foto per sapere quali asset esistono: fuori discussione (regola assoluta 3 e un formato privato). |
| D5 | Testo della «Regola assoluta», punto 1, e checklist (`Docs/CLAUDE.md`) | **Aggiungere la condizione** (testo esatto nel Task 4, da approvare parola per parola, stessa ragione di ADR-0017: una regola assoluta che non elenca tutte le sue condizioni è un'eccezione silenziosa). | Lasciarla com'è: è una condizione *in più* (restringe), ma la regola resterebbe incompleta. |
| D6 | Dove va il lavoro | **Stesso branch** `feature/certified-duplicates-ssd`, prima dell'unione, ADR-0018 nuovo, riga aggiunta a ROADMAP #46 (la verifica dal vivo di #46 resta aperta e ora comprende questo). | Branch nuovo da `main` dopo l'unione di #46: unirebbe a `main` un pannello che oggi fa ricopiare i file al backup. |

**Fatto da sapere, nessuna decisione richiesta:** le 6 copie già tornate hanno ora **due** copie sull'SSD: quella ricopiata in `Foto iPhone/` e quella nel Cestino dell'SSD. Se Enrico premesse «Annulla l'ultimo spostamento», per quelle 6 l'app direbbe «Al posto di questa foto c'è di nuovo un file con lo stesso nome… la copia nel Cestino è ancora lì» e non sovrascriverebbe niente (zero-overwrite, `TrashRestorer`). Svuotare o no il Cestino resta una scelta sua; l'app non lo fa mai.

---

## Global Constraints

- **Tutto ADR-0005 e ADR-0017 resta**: rilettura e rihash di ogni membro (tenuta e copie che restano comprese), unanimità, `trashItem` nel Cestino dell'SSD, registro scritto prima del file successivo, blocchi, ricontrollo della garanzia prima di ogni blocco, «Annulla». Questa è una condizione **in più**.
- **Un punto solo per decidere cosa resta**: `duplicateKeepChoice` (tenuta **e** `keptByPhotosLibrary`), congelato in `DuplicateBatch.Entry` e passato invariato al trasher. Mai ricalcolato altrove. Il trasher non decide cosa resta: **rifiuta** soltanto (ultima linea di difesa, dal vivo).
- **Verso sicuro ovunque**: libreria Foto non letta per intero ⇒ ogni copia in `Foto iPhone/` resta (pannello) e ogni copia in `Foto iPhone/` in uscita è rifiutata (trasher). Mai un elenco parziale.
- **Solo `Foto iPhone/`** dipende dalla libreria Foto (`isInMainLibrary`, confronto per componente: `Foto iPhone 2/` è un'altra cartella). Le copie fuori si spostano come prima, anche con la libreria illeggibile.
- **Sola lettura sulla libreria Foto** (regola assoluta 3): solo `enumerator`/`fileExists`/`contentsOfDirectory` su `originals`, nessun file aperto.
- **Fuori dal main**: `PhotosLibraryPresence.read` gira nel `Task.detached` di `loadGroups()` (tipo `nonisolated`, test in `MainThreadIsolationTests`); sul main solo letture O(1) (`nothingToMove.contains`) e i conteggi già esistenti su indici calcolati.
- **Testi solo in `DuplicatesStatus`/`DuplicateBatch`/`DuplicateTrashSkipReason`/`duplicateKeepExplanation`**, italiano semplice, senza gergo («hash», «indice», «originals», «bookmark», «cache»…).
- **Parametri nuovi senza default** (`photos:`, `photosLibraryRoot:`, `keptByPhotosLibrary:`): un chiamante che li dimentica non compila. Per questo cambiano, senza toccare nessuna asserzione, le chiamate in 7 file di test esistenti (tabella sotto).
- Tutto il codice in **`AppBackupFoto/ContentView.swift`**; due file di test nuovi registrati nel pbxproj nei **4 punti**. Si verifica sempre il totale `Executed N tests`. Un commit per task, messaggio in italiano, **mai `git push`**.

---

## Mappa dei file e dei tipi

**`AppBackupFoto/ContentView.swift`** (si ritrova tutto con `grep -n`):

| Dove | Cosa | Task |
| :--- | :--- | :--- |
| `nonisolated enum DuplicateKeepReason`, `nonisolated struct DuplicateKeepChoice` | `case stillInPhotosLibrary`; `let keptByPhotosLibrary: Set<String>` | 1 |
| dopo `private nonisolated func isInImportFolder` | **`PhotosLibraryPresence`** (nuovo) | 1 |
| `duplicateKeepChoice`, `duplicateKeepExplanation` | parametro `photos:`, regola 1b, `keptByPhotosLibrary`; frase del motivo nuovo e delle copie che restano | 1 |
| `DuplicateBatch` (`Entry.leaving`, `init(groups:rule:)`, `init(entries:)`, `summaryLines`) | `leaving` senza le copie che restano, `Entry.keptByPhotosLibrary`, `nothingToMove`, `keptByPhotosLibraryCount`, riga nel riepilogo | 1 |
| `DuplicatesView`: `@State`, `loadGroups`, `applyRule`, `rebuildBatch` | `photosPresence`, lettura fuori dal main, `photos:` passato | 1 |
| `DuplicateTrashSkipReason` (+ `explanation`), `DuplicatesStatus.skipCategoryKey/Description` | `.stillInPhotosLibrary`, `.photosLibraryUnreadable` | 2 |
| `DuplicateTrasher` (`Decision`, `init`, `run`, helper nuovi) | `keptByPhotosLibrary`, `photosLibraryRoot`, ricontrollo dal vivo | 2 |
| `BackupRunner.startDuplicateTrashRun` | `photosLibraryRoot` letto sul main, `Decision` e trasher completi | 2 |
| prima di `// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)` | `extension DuplicatesStatus`: `canSelect`, `rowBlockedLine`, `nothingToMoveRowLine`, `photosLibraryLine` | 3 |
| `DuplicatesView` (`content`, `toggleSelection`, `selectAllVisible`, `rebuildBatch`, `beginConfirmation`) ed `extension DuplicatesView` (`blockedRowLine`, `refreshCertification`, `recountBlocked`) | `canSelect`, `photosLibraryBanner` | 3 |
| `DuplicateRoleBadge`, `DuplicateGroupRow` | etichetta «RESTA · È ANCORA IN FOTO», righe delle copie che restano | 3 |
| `HamburgerPanel` | voce «Doppioni» dopo «Inventario» | 3 |

**`AppBackupFotoTests/`** — nuovi: `PhotosLibraryPresenceTests` (13), `DuplicatePhotosLibraryTests` (14 + 1 + 6 = 21). Estesi: `DuplicateTrasherTests` (+8), `MainThreadIsolationTests` (+1). Modificati **solo nelle chiamate** (argomento nuovo, nessuna asserzione toccata): `DuplicateKeepChoiceTests`, `DuplicateBatchTests`, `DuplicateRunPlanTests`, `DuplicateCertificationTests`, `MainThreadIsolationTests`, `DuplicateTrasherTests` (più `photosLibraryRoot` nel `setUp`). **Totale atteso: 1.219 + 43 = 1.262.**

### ID per il pbxproj (verificati assenti a `63a7a0c` con `grep -c`)

| File | `PBXFileReference` | `PBXBuildFile` |
| :--- | :--- | :--- |
| `PhotosLibraryPresenceTests.swift` | `828C24EE1C094A8B0CAB656C` | `1EF7067CDC221CB2D0BB895D` |
| `DuplicatePhotosLibraryTests.swift` | `981A075A343A39F00088AE64` | `23F360A2C9B120AAE3EF7A94` |

Le quattro righe di ogni file seguono quelle di `DuplicateCertificationStatusTests.swift` (le scrive `apply.py`; a mano: stessa forma di quelle). Prima di usarli: `grep -c <ID> AppBackupFoto.xcodeproj/project.pbxproj` deve dare `0`.

---

## Comandi di build e test

Stessi due livelli del piano 2026-10-05-certified-duplicates-ssd (precondizione di ogni `xcodebuild`: nessun backup in corso nell'app di Enrico).

1. **Verifica veloce** (~50 s, mai `xcodebuild`): `/private/tmp/claude-501/pinned-impl/fasttest.sh [Classe]`. È `dupcert-impl/fasttest.sh` con tre righe cambiate: il commento, `REPO=${REPO:-…}` e `SP=${SP:-/private/tmp/claude-501/pinned-impl/fast}`. Se manca (la cartella `/private/tmp` si svuota al riavvio), ricrearlo così:
   ```bash
   mkdir -p /private/tmp/claude-501/pinned-impl
   sed -e 's#(ROADMAP \#45, piano 2026-10-04)#(ADR-0018, piano 2026-10-05 «copie nella libreria Foto»)#' \
       -e 's#^REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto$#REPO=${REPO:-/Users/enriconannivicenzi/Desktop/AppBackupFoto}#' \
       -e 's#SP=${SP:-/private/tmp/claude-501/dupcert-impl/fast}#SP=${SP:-/private/tmp/claude-501/pinned-impl/fast}#' \
       /private/tmp/claude-501/dupcert-impl/fasttest.sh > /private/tmp/claude-501/pinned-impl/fasttest.sh
   chmod +x /private/tmp/claude-501/pinned-impl/fasttest.sh
   ```
   (se manca anche `dupcert-impl/fasttest.sh`, il suo testo integrale è nel piano `2026-10-05-certified-duplicates-ssd.md`, sezione «Comandi di build e test»).
2. **`xcodebuild` in background** solo ai punti di controllo (fine Task 3 e prima di unire il branch), come nel piano precedente; conteggio atteso **1.262**, 0 warning.

**Applicare una patch:** `/private/tmp/claude-501/pinned-plan/apply.py N` applica `proto/patches/0N-*.py` al vero `ContentView.swift` (si ferma senza scrivere niente se un «Trova» non compare esattamente una volta), copia i file di test del task da `proto/tests-tN/` e registra i file nuovi nel pbxproj (4 righe ciascuno, ID dalla tabella sopra). Se `/private/tmp` è stato svuotato, il testo integrale delle patch e dei test è nelle **Appendici A-C**: si applica a mano, «Trova» → «Sostituisci», nell'ordine.

---

## Task 1 — Il tipo `PhotosLibraryPresence`, la tenuta, il blocco

**Files:** `AppBackupFoto/ContentView.swift` (patch `01-photos-library-core.py`, 16 sostituzioni); test nuovi `PhotosLibraryPresenceTests.swift`, `DuplicatePhotosLibraryTests.swift` (primi 14 test); `MainThreadIsolationTests` +1; chiamate aggiornate in 5 file (tabella «Modifiche ai test esistenti»).

- [ ] **Step 1: test prima (rosso).** Copiare i due file nuovi e le modifiche (Appendice B/C, o `apply.py` dopo lo Step 2). Prima della patch la compilazione dei test fallisce: `cannot find 'PhotosLibraryPresence' in scope`, `extra argument 'photos' in call`. È il rosso atteso.
- [ ] **Step 2: applicare la patch.** `apply.py 1`. Cosa fa (Appendice A, `01`): `DuplicateKeepReason.stillInPhotosLibrary`; `DuplicateKeepChoice.keptByPhotosLibrary`; `PhotosLibraryPresence` (`unknown`, `known`, `isKnown`, `holds`, `key(forOriginalsRelativePath:)`, `read(originalsRoot:)` con `errorHandler`, due forme della root, zero file ⇒ `.unknown`); `duplicateKeepChoice(_:rule:photos:)` con regola 1b e `keptByPhotosLibrary`; frase del motivo nuovo e frase «Anche quella resta / Una di queste resta / N di queste restano» in `duplicateKeepExplanation`; `Entry.leaving` senza le copie che restano, `Entry.keptByPhotosLibrary`; `DuplicateBatch(groups:rule:photos:)`, `nothingToMove`, `keptByPhotosLibraryCount`, riga nel riepilogo; in `DuplicatesView` `@State photosPresence`, lettura in `loadGroups()` dentro il `Task.detached` (radice da `BookmarkManager.shared.urls[.photos]`, come l'SSD da `urls[.ssd]`: bookmark non security-scoped dal 2026-07-29, `startAccessing` restituisce lo stesso URL e `stopAccessing` è un no-op), `photos:` passato da `loadGroups`/`applyRule` a `rebuildBatch`.
- [ ] **Step 3:** `fasttest.sh PhotosLibraryPresenceTests` → 13, 0 fallimenti; `fasttest.sh DuplicatePhotosLibraryTests` → 14; `fasttest.sh` → **`Executed 1247 tests, with 0 failures`**, 0 warning.
- [ ] **Step 4: revisione (checklist di `Docs/CLAUDE.md`).** Nessuna operazione `FileManager` che scrive; `read` solo elenca. `PhotosLibraryPresence` è `nonisolated` e chiamata da un `Task.detached` (test in `MainThreadIsolationTests`). Nessun `filter` nuovo nel `body`.
- [ ] **Step 5: commit** `Copie nella libreria Foto, task 1: la libreria Foto letta, la tenuta e il blocco (ADR-0018)`.

## Task 2 — `DuplicateTrasher`: ultima linea di difesa, e il runner

**Files:** `ContentView.swift` (patch `02-trasher-last-line.py`, 14 sostituzioni); `DuplicateTrasherTests` +8 (e `setUp`/`makeTrasher`/13 `Decision` aggiornati); `DuplicatePhotosLibraryTests` +1; `MainThreadIsolationTests` (una chiamata).

- [ ] **Step 1: test prima (rosso):** `extra argument 'keptByPhotosLibrary'`, `type 'DuplicateTrashSkipReason' has no member 'stillInPhotosLibrary'`.
- [ ] **Step 2:** `apply.py 2`. Cosa fa: due motivi nuovi (`.stillInPhotosLibrary`, `.photosLibraryUnreadable`) con frase, categoria e descrizione nell'esito della corsa; `Decision.keptByPhotosLibrary`; `init(…, photosLibraryRoot: URL?, …)` senza default; in `run`: `photosLibraryReadable` una volta per blocco (`contentsOfDirectory` non vuoto), guardia «niente da spostare» e ciclo dei `trashItem` sullo stesso predicato `leaves(_:_:)` (né tenuta né `keptByPhotosLibrary`), e — **dopo la rilettura, prima del primo `trashItem` del gruppo** — `photosLibraryRefusal(for:libraryReadable:)` su ogni copia in uscita: fuori da `Foto iPhone/` ⇒ `nil`; libreria illeggibile, `.`/`..` ⇒ `.photosLibraryUnreadable`; `fileExists(originals/<resto>)` ⇒ `.stillInPhotosLibrary`; un rifiuto salta l'intero gruppo (mai «sposto quelle che posso»). Nel runner: `BookmarkManager.shared.urls[.photos]` letto sul main prima del `Task.detached`, `Decision(…, keptByPhotosLibrary: $0.choice.keptByPhotosLibrary)`, `DuplicateTrasher(…, photosLibraryRoot:)`. Un gruppo rifiutato **non ferma la corsa** (come gli altri motivi della verifica, non è un guasto del volume).
- [ ] **Step 3:** `fasttest.sh DuplicateTrasherTests` → tutti verdi (+8); `fasttest.sh` → **`Executed 1256 tests, with 0 failures`**, 0 warning.
- [ ] **Step 4: revisione.** IF `trashItem`: il percorso confinato per componenti (invariato); rilettura unanime **compresa la copia che resta per la libreria Foto**; tenuta **e `keptByPhotosLibrary`** mai passate a `trashItem` (`testKeptByPhotosLibrary_isRereadButNeverTrashed`); ogni copia in `Foto iPhone/` ricontrollata dal vivo; registro prima del file successivo (invariato); garanzia dell'inventario invariata.
- [ ] **Step 5: commit** `Copie nella libreria Foto, task 2: il trasher le ricontrolla dal vivo e non le sposta mai`.

## Task 3 — Il pannello e la voce «Doppioni»

**Files:** `ContentView.swift` (patch `03-panel-and-menu.py`, 12 sostituzioni); `DuplicatePhotosLibraryTests` +6.

- [ ] **Step 1: test prima (rosso):** `type 'DuplicatesStatus' has no member 'canSelect'`.
- [ ] **Step 2:** `apply.py 3`. Cosa fa: `extension DuplicatesStatus` con `canSelect` (garanzia **e** qualcosa da spostare), `rowBlockedLine` (precedenza: niente da spostare > garanzia non pronta > motivo della garanzia), `nothingToMoveRowLine(photosLibraryKnown:)`, `photosLibraryLine(photosLibraryKnown:keptCopies:)`; in `DuplicatesView` ogni `certification…isSelectable` (casella, selezione in massa, ricostruzione, conferma, garanzia ricalcolata, conteggi) passa da `canSelect`; `blockedRowLine` delega; `photosLibraryBanner` sotto la riga della garanzia; `DuplicateRoleBadge.keptInPhotos` («RESTA · È ANCORA IN FOTO») e le righe delle copie che restano in `DuplicateGroupRow` (prima di quelle che escono); in `HamburgerPanel` la voce «Doppioni» (`square.on.square`, viola) subito dopo «Inventario», che apre `openWindow(id: "duplicates")` — stessa finestra e stesso gate Touch ID; il bottone in Diagnostica resta.
- [ ] **Step 3:** `fasttest.sh DuplicatePhotosLibraryTests` → 21; `fasttest.sh` → **`Executed 1262 tests, with 0 failures`**, 0 warning. Poi `xcodebuild` in background (punto di controllo): **1.262**, `TEST SUCCEEDED`, 0 warning.
- [ ] **Step 4: revisione.** Nessun `filter`/`reduce` nuovo nel `body` (`photosLibraryBanner` legge un intero già calcolato; `canSelect` è O(1)); `recountBlocked` resta un giro sugli indici visibili, sul main, come prima.
- [ ] **Step 5: commit** `Copie nella libreria Foto, task 3: casella spenta col motivo, copie che restano, voce Doppioni nel menu`.

## Task 4 — Documentazione (testi da approvare in D5)

- [ ] **`Docs/adr/0018-le-copie-che-la-libreria-foto-ha-ancora-non-si-spostano.md`** (nuovo, stile di 0017): *Contesto* (il caso dal vivo, 6 su 8 tornati; zero-overwrite del backup ⇒ la copia torna); *Opzioni valutate*: (1) mai spostare una copia in `Foto iPhone/` ancora in Foto — **scelta di Enrico**; (2) escludere `Foto iPhone/` dai Doppioni — perde i doppioni la cui copia in `Foto iPhone/` non è più in Foto, e quelli fra `Foto iPhone/` e le altre cartelle se la tenuta fosse altrove; (3) il backup salta i file spostati nel Cestino (lista dal registro) — tocca il percorso di copia, crea un secondo elenco di «cose da non copiare» che diverge, e una foto tornata in Foto apposta non verrebbe più salvata; (4) togliere i doppioni dalla libreria Foto dall'app — vietato dalla regola assoluta 3. *Decisione e motivo*, più D1-D4 e il limite «Ottimizza spazio» (D4).
- [ ] **`Docs/CLAUDE.md`**, Regola assoluta punto 1 (**testo proposto, da approvare parola per parola**): dopo «…e vede ogni copia del gruppo sull'SSD con lo stesso contenuto; la freschezza si ricontrolla prima di ogni blocco» aggiungere «**— e mai una copia in «Foto iPhone» il cui originale c'è ancora nella libreria Foto del Mac (dal 2026-10-05, ADR-0018: il backup la ricopierebbe), ricontrollata dal vivo subito prima di spostare; se la libreria Foto non si lascia leggere, nessuna copia in «Foto iPhone» si sposta**». Nota sotto la regola: «Il punto **1** ha guadagnato la condizione sulla libreria Foto il **2026-10-05** (ADR-0018): stessa ragione di ADR-0017.» Checklist «IF il codice chiama `trashItem`», riga in più: «THEN verifica che nessuna copia in `Foto iPhone/` ancora presente nella libreria Foto del Mac arrivi a `trashItem` (`Decision.keptByPhotosLibrary` + ricontrollo dal vivo in `DuplicateTrasher`, ADR-0018)». Tabella «Stato attuale»: riga #46 e «Test automatici» (1.219 → 1.262), riga «Sidebar hamburger» (+ «Doppioni»).
- [ ] **`.claude/rules/architecture.md`**: nella sezione «Doppioni con la garanzia dell'inventario» un paragrafo «Le copie che la libreria Foto ha ancora (ADR-0018)» (i quattro pezzi dell'Architecture qui sopra); nella sezione «Pannello Doppioni con cancellazione» la frase «**Unico ingresso** … nessuna voce nell'hamburger, nemmeno disattivata (deciso il 2026-08-28)» diventa «Due ingressi: il bottone in `LibraryIndexCard` e, dal 2026-10-05 su richiesta di Enrico, la voce «Doppioni» in `HamburgerPanel`»; in «UI» la riga `HamburgerPanel` elenca «Doppioni» e «Inventario».
- [ ] **`Docs/ROADMAP.md`** #46: una frase con il difetto trovato dal vivo e il rimando ad ADR-0018. **`Docs/CONTEXT.md`**: voce «copia nella libreria Foto».
- [ ] Commit `Copie nella libreria Foto, task 4: documentazione (ADR-0018, regola assoluta, architettura)`.

## Task 5 — Verifica dal vivo (orchestratore con Enrico; l'agente non scrive su `/Volumes`)

Build Release installata da Enrico, SSD collegato. Si aggiunge alla verifica del Task 7 di #46.
1. Pannello laterale: la voce «Doppioni» c'è, sotto «Inventario», e apre la finestra (con Touch ID acceso, la finestra mostra prima il blocco).
2. In testa, la riga «N copie in «Foto iPhone» restano dove sono…» (N > 0 atteso: le 6 ricopiate formano di nuovo gruppi con la loro gemella). I gruppi di `1103F08E-…BA1C.mp4` e `F4E891D9-…5B25.mov`: la copia in `Foto iPhone/` è «RESTA» o «RESTA · È ANCORA IN FOTO», mai «NEL CESTINO»; se nessuna altra copia esce, casella spenta con «Non si può spuntare: le copie in più stanno tutte in «Foto iPhone»…».
3. Spostare un piccolo gruppo con una copia fuori da `Foto iPhone/`; poi MAC → SSD: **nessun file ricopiato** in `Foto iPhone/` per quel gruppo (`Copiati: 0` o solo foto nuove dell'iPhone).
4. Il caso «libreria Foto non leggibile» è coperto dai test (pannello e trasher): non si prova dal vivo, perché richiederebbe di togliere il bookmark della Libreria Foto.

---

## Modifiche ai test esistenti (solo chiamate, nessuna asserzione cambiata)

| Task | File | Trova | Sostituisci | Volte |
| :--- | :--- | :--- | :--- | ---: |
| 1 | `DuplicateKeepChoiceTests` | `rule: nil)` | `rule: nil, photos: .known([]))` | 5 |
| 1 | `DuplicateKeepChoiceTests` | `duplicateKeepChoice(group(members), rule: rule)` | `… rule: rule, photos: .known([]))` | 1 |
| 1 | `DuplicateKeepChoiceTests` | `duplicateKeepChoice(g, rule: rule(keepIn: "Takeout", trashIn: ["Foto iPhone"]))` | `… ["Foto iPhone"]), photos: .known([]))` | 2 |
| 1 | `DuplicateBatchTests` | `rule: nil)` | `rule: nil, photos: .known([]))` | 31 |
| 1 | `DuplicateBatchTests`, `DuplicateRunPlanTests` | `tiedCandidates: 1, tiedPaths: [])` | `tiedCandidates: 1, tiedPaths: [], keptByPhotosLibrary: [])` | 1 + 1 |
| 1 | `DuplicateCertificationTests` | `duplicateKeepChoice($0, rule: nil)` | `duplicateKeepChoice($0, rule: nil, photos: .known([]))` | 1 |
| 1 | `MainThreadIsolationTests` | `DuplicateBatch(groups: [], rule: nil)` | `DuplicateBatch(groups: [], rule: nil, photos: .unknown)` | 1 |
| 2 | `MainThreadIsolationTests` | `DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest,⏎` | `… manifest: manifest, photosLibraryRoot: nil,⏎` | 1 |
| 2 | `DuplicateTrasherTests` | `private var manifest: TrashManifestStore!` | + `private var photosLibraryRoot: URL!` (con commento) | 1 |
| 2 | `DuplicateTrasherTests` | `manifest = try TrashManifestStore(…)` nel `setUp` | + crea `root/originals/0/` (leggibile, non vuota, senza foto dei test) | 1 |
| 2 | `DuplicateTrasherTests` | `manifest: manifest,⏎ trashFunction:` in `makeTrasher` | + `photosLibraryRoot: photosLibraryRoot,` | 1 |
| 2 | `DuplicateTrasherTests` | regex `keeper: (\w+(?:\[\d\])?)\)` | `keeper: \1, keptByPhotosLibrary: [])` | 13 |

`.known([])` = «libreria letta, nessuna di queste copie è in Foto»: il comportamento di oggi, bit per bit. Nei test del trasher la cartella `originals` finta è leggibile e non contiene nessuna delle foto dei test: per gli 8 test nuovi conta il contenuto, per i vecchi è come oggi.

---

## Mutanti verificati

Prova: `proto/mutate.py` (ogni mutante su tutte le patch applicate, compilazione completa, esecuzione della classe indicata; atteso almeno un fallimento).

| # | Mutante | Classe | Esito |
| :--- | :--- | :--- | :--- |
| M1 | niente regola 1b | 21 test | 7 fallimenti |
| M3 | libreria sconosciuta = nessuna copia | 13 test | 3 fallimenti |
| M5 | read ignora le cartelle illeggibili | 13 test | 2 fallimenti |
| M7 | read: una sola forma della root | 13 test | **sopravvissuto** (vedi sotto) |
| M8 | keptByPhotos mai calcolato | 21 test | 22 fallimenti |
| M9 | leaving ignora keptByPhotos | 21 test | 13 fallimenti |
| M10 | nothingToMove sempre vuoto | 21 test | 2 fallimenti |
| M12 | trasher: niente ricontrollo dal vivo | 40 test | 12 fallimenti |
| M13 | trasher: ricontrollo anche fuori da Foto iPhone | 40 test | 2 fallimenti |
| M14 | trasher: libreria illeggibile = via libera | 40 test | 4 fallimenti |
| M15 | trasher: originals vuota = leggibile | 40 test | 2 fallimenti |
| M16 | trasher: niente guardia su .. | 40 test | 2 fallimenti |
| M17 | trasher: sposta anche le copie congelate | 40 test | 6 fallimenti |
| M18 | trasher: guardia «niente da spostare» vecchia | 40 test | 2 fallimenti |
| M21 | trasher: fileExists rovesciato | 40 test | 10 fallimenti |

**20 su 21 uccisi.** **M7 sopravvive, dichiarato:** su questo macOS l'enumeratore restituisce i percorsi nella stessa forma della root passata (anche con `/var/…` e con un link simbolico), quindi la seconda forma (`realResolvedPath`) non serve in nessun caso provato. Resta come difesa (stesso schema di `DuplicateTrasher.rootForms`), e il suo fallimento va nel verso sicuro: un file che non risulta sotto la root rende la lettura `.unknown`, cioè tiene tutte le copie in `Foto iPhone/`. **Non coperti da mutanti (nessun test li raggiunge, dichiarato):** il cablaggio nel runner (`keptByPhotosLibrary`/`photosLibraryRoot` passati al trasher) e in `DuplicatesView`/`HamburgerPanel`. Se il runner passasse `keptByPhotosLibrary: []`, il trasher rifiuterebbe dal vivo i gruppi con copie ancora in Foto (rumore nell'esito, nessuna copia spostata): l'ultima linea di difesa copre anche questo errore.

---

## Fuori scope e limiti dichiarati

- **«Ottimizza spazio del Mac»** in Foto (D4): una copia il cui originale è solo su iCloud risulta «non più in Foto»; se esce, torna quando Foto riscarica l'originale. Nessuna perdita, solo un doppione che ricompare.
- **Il registro del Cestino** (`TrashedItem.keptPath`, `TrashHistoryEntry.keptPaths`) annota solo la copia tenuta, non quelle che restano per la libreria Foto. Per il progetto 4 (doppioni su HDD e Cubbit): le copie che restano sull'SSD restano anche sugli altri due archivi; il progetto 4 deve togliere su HDD/Cubbit solo ciò che è uscito dall'SSD, mai «tutto tranne `keptPath`».
- L'intestazione del pannello conta anche i gruppi senza niente da spostare (sono doppioni veri); i byte recuperabili no. La riga della regola per cartella dice «non si possono ancora spostare» anche per loro: imprecisione di una parola, accettata.
- Le 6 copie già tornate e i loro gemelli nel Cestino: vedi «Fatto da sapere» in testa.

## Appendice A — Le patch, testo integrale

Ogni voce è `(descrizione, «Trova», «Sostituisci»)`; ogni «Trova» compare **esattamente una volta** nel file al momento della sua patch (prima le patch precedenti). In Python le stringhe sono letterali `"""…"""`: `\\(` nel file `.py` diventa `\(` in Swift, `\\.` diventa `\.`.

### `01-photos-library-core.py`

```python
# Task 1 — Le copie che la libreria Foto del Mac ha ancora: tipo puro, scelta della copia
# tenuta, blocco (DuplicateBatch) e cablaggio minimo in DuplicatesView (lettura fuori dal main).
PATCHES = [
("DuplicateKeepReason: motivo nuovo",
"""    case mainLibrary
    /// Sta in una cartella organizzata a mano, e le altre copie stanno in un import.
    case notAnImport""",
"""    case mainLibrary
    /// Fra le copie della libreria principale, e' quella che la libreria Foto del Mac ha
    /// ancora (ADR-0018): resta comunque, quindi tenerla libera le altre.
    case stillInPhotosLibrary
    /// Sta in una cartella organizzata a mano, e le altre copie stanno in un import.
    case notAnImport"""),

("DuplicateKeepChoice: le altre copie che restano per la libreria Foto",
"""    let tiedPaths: Set<String>
}
""",
"""    let tiedPaths: Set<String>

    /// Le chiavi delle ALTRE copie (non la tenuta) che restano dove sono perche' stanno in
    /// «Foto iPhone» e la libreria Foto del Mac ha ancora il loro originale (ADR-0018): se
    /// uscissero, il backup MAC -> SSD successivo le ricopierebbe. Decise qui, insieme alla
    /// tenuta, e congelate con lei fino al `DuplicateTrasher` — mai ricalcolate altrove.
    /// Vuoto quando nessuna copia del gruppo e' nella libreria Foto.
    let keptByPhotosLibrary: Set<String>
}
"""),

("PhotosLibraryPresence, accanto alle regole sulle cartelle",
"""private nonisolated func isInImportFolder(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == importFolderKey
}
""",
"""private nonisolated func isInImportFolder(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == importFolderKey
}

// MARK: - Le copie che la libreria Foto del Mac ha ancora (ADR-0018, 2026-10-05)

/// Quali copie in «Foto iPhone» hanno ancora il loro originale nella libreria Foto del Mac.
///
/// Il backup MAC -> SSD copia `originals/<X>/<file>` in `Foto iPhone/<X>/<file>` e copia solo
/// cio' che manca (zero-overwrite). Una copia in «Foto iPhone» spostata nel Cestino mentre il
/// suo originale c'e' ancora **torna al backup successivo**: verificato dal vivo il 2026-10-05
/// (degli 8 file spostati da «Foto iPhone» dal pannello Doppioni, 6 erano gia' tornati). La
/// libreria Foto contiene doppioni veri (asset diversi, stesso contenuto), quindi l'SSD ha gruppi
/// di doppioni dentro «Foto iPhone». Decisione di Enrico (opzione 1, ADR-0018): una copia cosi'
/// non si sposta MAI; le altre copie dello stesso gruppo (fuori da «Foto iPhone», o in «Foto
/// iPhone» ma non piu' in Foto) si spostano come prima.
///
/// `mainLibraryKeys` sono le chiavi dell'elenco (`normalizedIndexKey`: NFC + minuscole) che i
/// file di `originals` hanno sull'SSD: «foto iphone/<percorso dentro originals>». `nil` = non si
/// sa (libreria non configurata, non trovata, letta a meta', o vuota): **nel verso sicuro ogni
/// copia in «Foto iPhone» conta come nella libreria**. Le copie fuori da «Foto iPhone» non
/// dipendono mai da questo tipo: il backup scrive solo li'.
///
/// E' una fotografia presa una volta per caricamento del pannello, fuori dal main (`read`), che
/// serve a scegliere la tenuta e a mostrare cosa resta. Non e' l'ultima parola: subito prima di
/// spostare, `DuplicateTrasher` ricontrolla dal vivo ogni copia in uscita.
// `nonisolated`: value type senza stato condiviso, costruito in un `Task.detached` e letto da
// `duplicateKeepChoice` fuori dal main.
nonisolated struct PhotosLibraryPresence: Equatable, Sendable {
    let mainLibraryKeys: Set<String>?

    /// Non si sa: ogni copia in «Foto iPhone» resta.
    static let unknown = PhotosLibraryPresence(mainLibraryKeys: nil)

    static func known(_ keys: Set<String>) -> PhotosLibraryPresence {
        PhotosLibraryPresence(mainLibraryKeys: keys)
    }

    var isKnown: Bool { mainLibraryKeys != nil }

    /// Vero se questa copia dell'SSD sta in «Foto iPhone» (confronto per componente, come
    /// `duplicateKeepChoice`: «Foto iPhone 2» e' un'altra cartella) e la libreria Foto ha
    /// ancora il suo originale — o non si sa.
    func holds(_ entry: LibraryIndexEntry) -> Bool {
        guard isInMainLibrary(entry) else { return false }
        guard let mainLibraryKeys else { return true }
        return mainLibraryKeys.contains(normalizedIndexKey(entry.path))
    }

    /// La chiave dell'elenco che la copia sull'SSD di un file di `originals` ha: lo stesso
    /// percorso relativo sotto «Foto iPhone», normalizzato come ogni chiave dell'elenco.
    static func key(forOriginalsRelativePath relative: String) -> String {
        normalizedIndexKey(mainLibraryFolderKey + "/" + relative)
    }

    /// Legge l'elenco dei file di `originals` (la cartella del bookmark `.photos`). Fuori dal
    /// main: ~18.500 file, misurati in 0,1 s con `find` il 2026-10-05. Sola lettura: nessun
    /// file della libreria Foto viene aperto, solo le cartelle elencate (regola assoluta 3).
    ///
    /// Nel verso sicuro restituisce `.unknown`, mai un elenco parziale: root `nil`, assente o
    /// non cartella; enumeratore `nil`; una cartella che non si lascia aprire (`errorHandler`,
    /// stessa disciplina di `LibraryIndexer.scan`: il suo default e' «prosegui in silenzio»);
    /// un file che non risulta sotto la root; nessun file trovato (una libreria vuota e una
    /// libreria illeggibile si confondono, e la seconda renderebbe spostabile tutto).
    /// Include ogni voce che non e' una cartella, nascosti compresi: contare un file in piu'
    /// tiene una copia in piu', contarne uno in meno la farebbe ricopiare.
    static func read(originalsRoot: URL?, fileManager fm: FileManager = .default) -> PhotosLibraryPresence {
        guard let root = originalsRoot else { return .unknown }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unknown
        }
        let failures = ReadFailures()
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [],
                                             errorHandler: { _, _ in
                                                 failures.count += 1
                                                 return true
                                             }) else { return .unknown }
        // Le due forme della root, come in `DuplicateTrasher`: l'enumeratore restituisce
        // percorsi in forma `realpath` (`/private/var/...` per una root `/var/...`).
        let rootForms = [root.standardizedFileURL.path, realResolvedPath(root)].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        var keys = Set<String>()
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            guard let relative = rootForms.lazy.compactMap({ relativePath(of: url.path, under: $0) }).first else {
                return .unknown
            }
            keys.insert(key(forOriginalsRelativePath: relative))
        }
        guard failures.count == 0, !keys.isEmpty else { return .unknown }
        return .known(keys)
    }

    /// Contatore condiviso con l'`errorHandler` (closure `@escaping`, non puo' catturare un
    /// `var` locale). Nessun lock: l'enumeratore la chiama in modo sincrono dal thread che
    /// esegue `read`, stesso schema di `LibraryIndexer`/`InventoryScanner`.
    private final class ReadFailures {
        var count = 0
    }
}
"""),

("duplicateKeepChoice: firma con la libreria Foto",
"""nonisolated func duplicateKeepChoice(_ group: DuplicateGroup, rule: DuplicateFolderRule?) -> DuplicateKeepChoice {""",
"""///
/// **Regola 1b — la copia che la libreria Foto ha ancora (ADR-0018, 2026-10-05).** Fra le
/// copie rimaste dopo la regola 1, si preferisce quella che `photos.holds` (in «Foto iPhone» e
/// ancora in Foto): resta comunque, quindi tenerla permette di spostare le altre. Dopo la
/// regola 1 e non prima, perche' ogni copia «nella libreria» sta in «Foto iPhone»: la tenuta
/// e' la stessa nei due ordini, e cosi' il motivo del caso comune (una copia in «Foto iPhone»,
/// le altre fuori) resta `.mainLibrary`. Dopo la regola 0: la regola dell'utente resta
/// sovrana — se chiede di tenere fuori da «Foto iPhone», le copie «nella libreria» restano lo
/// stesso (`keptByPhotosLibrary`) e il gruppo puo' restare senza niente da spostare. Anche
/// `photos` non ha un default (stessa disciplina di `rule`).
nonisolated func duplicateKeepChoice(_ group: DuplicateGroup, rule: DuplicateFolderRule?,
                                     photos: PhotosLibraryPresence) -> DuplicateKeepChoice {"""),

("duplicateKeepChoice: regola 1b",
"""    narrow(candidates.filter(isInMainLibrary), .mainLibrary)
""",
"""    narrow(candidates.filter(isInMainLibrary), .mainLibrary)
    // 1b. Fra le copie della libreria principale, quella che la libreria Foto del Mac ha
    //     ancora: resta comunque (ADR-0018), quindi tenerla libera le altre.
    narrow(candidates.filter { photos.holds($0) }, .stillInPhotosLibrary)
"""),

("duplicateKeepChoice: le altre copie che restano",
"""    return DuplicateKeepChoice(keeper: keeper ?? candidates[0],
                               reason: reason,
                               tiedCandidates: candidates.count,
                               tiedPaths: Set(candidates.map(\\.path)))
}""",
"""    let chosen = keeper ?? candidates[0]
    // Le altre copie che la libreria Foto ha ancora restano: decise qui, una volta sola,
    // insieme alla tenuta (ADR-0018).
    let keptByPhotos = Set(group.members.lazy
        .filter { $0.path != chosen.path && photos.holds($0) }
        .map(\\.path))
    return DuplicateKeepChoice(keeper: chosen,
                               reason: reason,
                               tiedCandidates: candidates.count,
                               tiedPaths: Set(candidates.map(\\.path)),
                               keptByPhotosLibrary: keptByPhotos)
}"""),

("duplicateKeepExplanation: frase del motivo nuovo",
"""    case .notAnImport:
        lead = allOthersAreImports""",
"""    case .stillInPhotosLibrary:
        lead = "Tengo la copia che si trova \\(place): è ancora nella libreria Foto del Mac, quindi "
            + "resta comunque. Se la spostassi, il prossimo backup dal Mac la ricopierebbe."
    case .notAnImport:
        lead = allOthersAreImports"""),

("duplicateKeepExplanation: le altre copie che restano",
"""    return lead + tie + copies
}""",
"""    // Le altre copie che restano per la libreria Foto (ADR-0018): dirlo qui, accanto al numero
    // di copie, perche' «identiche» non si legga come «andranno tutte nel Cestino».
    let keptByPhotos = choice.keptByPhotosLibrary.count
    let photosClause: String
    switch (keptByPhotos, keptByPhotos == others.count) {
    case (0, _): photosClause = ""
    case (1, true): photosClause = " Anche quella resta in «Foto iPhone», perché è ancora nella libreria Foto del Mac."
    case (_, true): photosClause = " Restano anche tutte quelle, in «Foto iPhone», perché sono ancora nella libreria "
        + "Foto del Mac."
    case (1, false): photosClause = " Una di queste resta comunque in «Foto iPhone», perché è ancora nella libreria "
        + "Foto del Mac."
    default: photosClause = " \\(keptByPhotos) di queste restano comunque in «Foto iPhone», perché sono ancora nella "
        + "libreria Foto del Mac."
    }

    return lead + tie + copies + photosClause
}"""),

("Entry.leaving: senza le copie che la libreria Foto ha ancora",
"""        var leaving: [LibraryIndexEntry] {
            group.members.filter { $0.path != choice.keeper.path }
        }
""",
"""        ///
        /// Senza la tenuta **e senza le copie che la libreria Foto del Mac ha ancora**
        /// (`choice.keptByPhotosLibrary`, ADR-0018): quelle restano, e tutto quello che deriva da
        /// `leaving` (file, spazio, cartelle, piano della corsa, progresso, cosa arriva al
        /// trasher) le esclude da solo.
        var leaving: [LibraryIndexEntry] {
            group.members.filter { $0.path != choice.keeper.path && !choice.keptByPhotosLibrary.contains($0.path) }
        }

        /// Le altre copie che restano perche' la libreria Foto del Mac le ha ancora (ADR-0018).
        var keptByPhotosLibrary: [LibraryIndexEntry] {
            group.members.filter { $0.path != choice.keeper.path && choice.keptByPhotosLibrary.contains($0.path) }
        }
"""),

("DuplicateBatch: campi nuovi",
"""    let folderBreakdown: [(folder: String, count: Int)]
    let exceedsCap: Bool
""",
"""    let folderBreakdown: [(folder: String, count: Int)]
    let exceedsCap: Bool
    /// I gruppi senza niente da spostare: ogni copia oltre la tenuta resta perche' la libreria
    /// Foto del Mac la ha ancora (ADR-0018). Nel pannello la casella resta spenta con il motivo.
    let nothingToMove: Set<String>
    /// Quante copie restano in tutto per la libreria Foto (non la tenuta).
    let keptByPhotosLibraryCount: Int
"""),

("DuplicateBatch.init(groups:rule:photos:)",
"""    init(groups: [DuplicateGroup], rule: DuplicateFolderRule?) {
        // I gruppi ridotti a un solo membro si scartano prima: `duplicateKeepChoice` ha una
        // precondition su almeno due membri, e questo e' il confine dove il filtro va messo
        // (non ammorbidendo la guardia).
        let entries = groups
            .filter { $0.members.count > 1 }
            .map { Entry(group: $0, choice: duplicateKeepChoice($0, rule: rule)) }""",
"""    /// `photos` (ADR-0018) senza default, come `rule`: un chiamante che lo dimentica non deve
    /// compilare.
    init(groups: [DuplicateGroup], rule: DuplicateFolderRule?, photos: PhotosLibraryPresence) {
        // I gruppi ridotti a un solo membro si scartano prima: `duplicateKeepChoice` ha una
        // precondition su almeno due membri, e questo e' il confine dove il filtro va messo
        // (non ammorbidendo la guardia).
        let entries = groups
            .filter { $0.members.count > 1 }
            .map { Entry(group: $0, choice: duplicateKeepChoice($0, rule: rule, photos: photos)) }"""),

("DuplicateBatch.init(entries:): calcolo dei campi nuovi",
"""        self.exceedsCap = self.fileCount > duplicateBatchFileCap
            || self.reclaimableBytes > duplicateBatchByteCap
    }""",
"""        self.exceedsCap = self.fileCount > duplicateBatchFileCap
            || self.reclaimableBytes > duplicateBatchByteCap

        self.nothingToMove = Set(entries.lazy.filter { $0.leaving.isEmpty }.map(\\.group.hash))
        self.keptByPhotosLibraryCount = entries.reduce(0) { $0 + $1.choice.keptByPhotosLibrary.count }
    }"""),

("summaryLines: le copie che restano per la libreria Foto",
"""        out.append("Le copie che stanno sull'HDD e su Cubbit restano dove sono: questa operazione "
            + "tocca soltanto l'SSD.")
""",
"""        // ADR-0018: chi conferma deve sapere che alcune copie dei gruppi scelti restano, e perche'.
        if keptByPhotosLibraryCount > 0 {
            out.append(keptByPhotosLibraryCount == 1
                ? "Resta dov'è 1 copia in «Foto iPhone», perché è ancora nella libreria Foto del Mac: "
                    + "se la spostassi, il prossimo backup dal Mac la ricopierebbe."
                : "Restano dove sono \\(DuplicateBatch.count(keptByPhotosLibraryCount, "copia", "copie")) in "
                    + "«Foto iPhone», perché sono ancora nella libreria Foto del Mac: se le spostassi, il "
                    + "prossimo backup dal Mac le ricopierebbe.")
        }

        out.append("Le copie che stanno sull'HDD e su Cubbit restano dove sono: questa operazione "
            + "tocca soltanto l'SSD.")
"""),

("DuplicatesView: stato della libreria Foto",
"""    @State private var thumbnailCache = DuplicateThumbnailCache()
""",
"""    @State private var thumbnailCache = DuplicateThumbnailCache()

    /// Quali copie in «Foto iPhone» la libreria Foto del Mac ha ancora (ADR-0018), letto fuori
    /// dal main a ogni `loadGroups()` e riusato da `applyRule`: una fotografia per caricamento.
    /// `.unknown` finche' non e' letto: nel verso sicuro ogni copia in «Foto iPhone» resta.
    @State private var photosPresence: PhotosLibraryPresence = .unknown
"""),

("loadGroups: legge la libreria Foto fuori dal main",
"""        loadState = .loading
        let rule = folderRule
        Task.detached(priority: .utility) {
            do {
                let groups = try store.duplicateGroups()
                await MainActor.run {
                    self.loadState = .loaded(groups)
                    self.rebuildBatch(from: groups, rule: rule)
                    self.refreshCertification()
                }""",
"""        loadState = .loading
        let rule = folderRule
        // La cartella `originals` del bookmark `.photos` (non security-scoped dal 2026-07-29,
        // come l'SSD letto qui sotto da `urls[.ssd]`): `nil` se non si risolve, e allora ogni
        // copia in «Foto iPhone» resta (ADR-0018).
        let originalsRoot = BookmarkManager.shared.urls[.photos]
        Task.detached(priority: .utility) {
            do {
                let groups = try store.duplicateGroups()
                let photos = PhotosLibraryPresence.read(originalsRoot: originalsRoot)
                await MainActor.run {
                    self.loadState = .loaded(groups)
                    self.photosPresence = photos
                    self.rebuildBatch(from: groups, rule: rule, photos: photos)
                    self.refreshCertification()
                }"""),

("applyRule: riusa la fotografia della libreria Foto",
"""        guard case .loaded(let groups) = loadState else { return }
        rebuildBatch(from: groups, rule: rule)
    }""",
"""        guard case .loaded(let groups) = loadState else { return }
        rebuildBatch(from: groups, rule: rule, photos: photosPresence)
    }"""),

("rebuildBatch: firma con la libreria Foto",
"""    private func rebuildBatch(from rawGroups: [DuplicateGroup], rule: DuplicateFolderRule?) {
        isApplyingFilter = true
        let currentFilter = filter
        Task.detached(priority: .utility) {
            let batch = DuplicateBatch(groups: rawGroups, rule: rule)""",
"""    private func rebuildBatch(from rawGroups: [DuplicateGroup], rule: DuplicateFolderRule?,
                              photos: PhotosLibraryPresence) {
        isApplyingFilter = true
        let currentFilter = filter
        Task.detached(priority: .utility) {
            let batch = DuplicateBatch(groups: rawGroups, rule: rule, photos: photos)"""),
]
```

### `02-trasher-last-line.py`

```python
# Task 2 — DuplicateTrasher, ultima linea di difesa: non passa mai a trashItem una copia in
# «Foto iPhone» che la libreria Foto del Mac ha ancora (ricontrollata dal vivo); il runner gli
# passa le copie congelate come «nella libreria» e la cartella originals.
PATCHES = [
("DuplicateTrashSkipReason: due motivi nuovi",
"""    /// La copia da tenere e' sparita a cestinamento gia' iniziato: quanto era stato
    /// spostato e' stato rimesso a posto.
    case keeperVanished(displayPath: String)
""",
"""    /// La copia da tenere e' sparita a cestinamento gia' iniziato: quanto era stato
    /// spostato e' stato rimesso a posto.
    case keeperVanished(displayPath: String)
    /// Una copia che stava per uscire e' in «Foto iPhone» e la libreria Foto del Mac ha ancora
    /// il suo originale, ricontrollato subito prima di spostare (ADR-0018): il backup la
    /// ricopierebbe. Il gruppo non e' stato toccato.
    case stillInPhotosLibrary(displayPath: String)
    /// Una copia che stava per uscire e' in «Foto iPhone» e la libreria Foto del Mac non si e'
    /// lasciata controllare (non configurata, non trovata, vuota): nel verso sicuro non si
    /// sposta (ADR-0018). Il gruppo non e' stato toccato.
    case photosLibraryUnreadable(displayPath: String)
"""),

("DuplicateTrashSkipReason.explanation: frasi nuove",
"""        case .keeperVanished(let p):
            return "La copia da tenere (\\(p)) è sparita mentre il gruppo veniva smaltito. "
                + "Le copie appena spostate sono state rimesse al loro posto: non sei rimasto "
                + "senza nessuna copia."
        }""",
"""        case .keeperVanished(let p):
            return "La copia da tenere (\\(p)) è sparita mentre il gruppo veniva smaltito. "
                + "Le copie appena spostate sono state rimesse al loro posto: non sei rimasto "
                + "senza nessuna copia."
        case .stillInPhotosLibrary(let p):
            return "\\(p) è ancora nella libreria Foto del Mac: se la spostassi nel Cestino, il prossimo "
                + "backup dal Mac la ricopierebbe. Non ho spostato niente di questo gruppo."
        case .photosLibraryUnreadable(let p):
            return "Non sono riuscito a controllare se \\(p) è ancora nella libreria Foto del Mac, quindi "
                + "per sicurezza non ho spostato niente di questo gruppo."
        }"""),

("skipCategoryKey: categorie nuove",
"""        case .keeperVanished: return "keeper-vanished"
        }""",
"""        case .keeperVanished: return "keeper-vanished"
        case .stillInPhotosLibrary: return "still-in-photos-library"
        case .photosLibraryUnreadable: return "photos-library-unreadable"
        }"""),

("skipCategoryDescription: descrizioni nuove",
"""        case .keeperVanished:
            return "perché la copia da tenere è sparita a metà"
        }""",
"""        case .keeperVanished:
            return "perché la copia da tenere è sparita a metà"
        case .stillInPhotosLibrary:
            return "perché una copia era ancora nella libreria Foto del Mac"
        case .photosLibraryUnreadable:
            return "perché non sono riuscito a controllare la libreria Foto del Mac"
        }"""),

("DuplicateTrasher.Decision: le copie che restano per la libreria Foto",
"""    struct Decision {
        let group: DuplicateGroup
        let keeper: LibraryIndexEntry
    }""",
"""    struct Decision {
        let group: DuplicateGroup
        let keeper: LibraryIndexEntry
        /// Le altre copie che restano perche' la libreria Foto del Mac le ha ancora
        /// (`DuplicateKeepChoice.keptByPhotosLibrary`, ADR-0018), congelate con la tenuta. Come
        /// la tenuta: si rileggono e si rihashano (l'unanimita' vale per tutto il gruppo), ma
        /// non si passano MAI a `trashItem`. Nessun default: chi costruisce una decisione deve
        /// dire cosa resta.
        let keptByPhotosLibrary: Set<String>
    }"""),

("DuplicateTrasher: proprieta' photosLibraryRoot",
"""    private let libraryRoot: URL
    private let store: LibraryIndexStore
    private let manifest: TrashManifestStore
    private let trashFunction: (URL) throws -> URL?""",
"""    private let libraryRoot: URL
    private let store: LibraryIndexStore
    private let manifest: TrashManifestStore
    /// La cartella `originals` della libreria Foto del Mac (bookmark `.photos`), o `nil` se non
    /// si risolve: allora nessuna copia in «Foto iPhone» esce (ADR-0018). Solo letta, con
    /// `fileExists`/`contentsOfDirectory`: nessun file della libreria Foto viene aperto.
    private let photosLibraryRoot: URL?
    private let trashFunction: (URL) throws -> URL?"""),

("DuplicateTrasher.init: parametro photosLibraryRoot",
"""    init(libraryRoot: URL,
         store: LibraryIndexStore,
         manifest: TrashManifestStore,
         trashFunction: @escaping (URL) throws -> URL? = { url in""",
"""    /// `photosLibraryRoot` senza default (ADR-0018): un chiamante che lo dimentica non compila.
    init(libraryRoot: URL,
         store: LibraryIndexStore,
         manifest: TrashManifestStore,
         photosLibraryRoot: URL?,
         trashFunction: @escaping (URL) throws -> URL? = { url in"""),

("DuplicateTrasher.init: assegnazione",
"""        self.libraryRoot = libraryRoot
        self.store = store
        self.manifest = manifest
        self.trashFunction = trashFunction""",
"""        self.libraryRoot = libraryRoot
        self.store = store
        self.manifest = manifest
        self.photosLibraryRoot = photosLibraryRoot
        self.trashFunction = trashFunction"""),

("run: libreria Foto leggibile, controllata una volta",
"""        let deviceAtStart = deviceIdentifier(of: libraryRoot)

        for (index, decision) in decisions.enumerated() {""",
"""        let deviceAtStart = deviceIdentifier(of: libraryRoot)
        // La libreria Foto si lascia leggere? Una volta per blocco. Se no, nessuna copia in
        // «Foto iPhone» esce (ADR-0018): un `fileExists` falso su una cartella illeggibile
        // direbbe «non c'e' piu'» proprio dove non si sa.
        let photosLibraryReadable = Self.isReadableLibraryRoot(photosLibraryRoot)

        for (index, decision) in decisions.enumerated() {"""),

("run: niente da spostare se restano tutte",
"""            let group = decision.group
            guard group.members.contains(where: { $0.path != decision.keeper.path }) else {""",
"""            let group = decision.group
            guard group.members.contains(where: { leaves($0, decision) }) else {"""),

("run: ricontrollo dal vivo prima di spostare",
"""            var trashedInGroup: [TrashedItem] = []
            var groupFailure: DuplicateTrashSkipReason?
            var volumeVanished = false

            for (entry, url) in resolved where entry.path != decision.keeper.path {""",
"""            // ULTIMA LINEA DI DIFESA (ADR-0018), dopo la rilettura e prima di qualunque
            // `trashItem` del gruppo: una copia in uscita che sta in «Foto iPhone» e che la
            // libreria Foto del Mac ha ANCORA, adesso, non si sposta — il backup la
            // ricopierebbe. Dal vivo e non dalla fotografia presa all'apertura del pannello: fra
            // le due Enrico puo' aver reimportato una foto. Se una sola copia non passa, il gruppo
            // intero resta intatto (mai «sposto quelle che posso»).
            let photosRefusal: DuplicateTrashSkipReason? = resolved.lazy
                .filter { self.leaves($0.entry, decision) }
                .compactMap { self.photosLibraryRefusal(for: $0.entry, libraryReadable: photosLibraryReadable) }
                .first
            if let photosRefusal {
                outcome.skippedGroups.append((group, photosRefusal))
                continue
            }

            var trashedInGroup: [TrashedItem] = []
            var groupFailure: DuplicateTrashSkipReason?
            var volumeVanished = false

            for (entry, url) in resolved where leaves(entry, decision) {"""),

("helper: leaves, photosLibraryRefusal, isReadableLibraryRoot",
"""    private enum Verification {
        case ok([(entry: LibraryIndexEntry, url: URL)])
        case skip(DuplicateTrashSkipReason)
    }""",
"""    /// Vero se la copia esce: non e' la tenuta e non e' fra quelle che restano per la libreria
    /// Foto. Un posto solo per la regola, usato dalla guardia «niente da spostare», dal
    /// ricontrollo e dal ciclo di `trashItem`.
    private func leaves(_ entry: LibraryIndexEntry, _ decision: Decision) -> Bool {
        entry.path != decision.keeper.path && !decision.keptByPhotosLibrary.contains(entry.path)
    }

    /// Il ricontrollo dal vivo di una copia in uscita (ADR-0018). `nil` = puo' uscire. Le copie
    /// fuori da «Foto iPhone» non dipendono mai dalla libreria Foto (il backup scrive solo li').
    /// Per una copia in «Foto iPhone»: libreria illeggibile, o percorso con `.`/`..` ⇒ rifiuto;
    /// l'originale `originals/<resto del percorso>` esiste ⇒ rifiuto. Il volume della libreria
    /// Foto (disco del Mac) non distingue le maiuscole, come la copia fatta dal backup.
    private func photosLibraryRefusal(for entry: LibraryIndexEntry, libraryReadable: Bool) -> DuplicateTrashSkipReason? {
        guard isInMainLibrary(entry) else { return nil }
        guard libraryReadable, let photosLibraryRoot else {
            return .photosLibraryUnreadable(displayPath: entry.displayPath)
        }
        let inside = entry.displayPath.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        guard !inside.isEmpty, !inside.contains(where: { $0 == "." || $0 == ".." }) else {
            return .photosLibraryUnreadable(displayPath: entry.displayPath)
        }
        let original = photosLibraryRoot.appendingPathComponent(inside.joined(separator: "/"))
        return FileManager.default.fileExists(atPath: original.path)
            ? .stillInPhotosLibrary(displayPath: entry.displayPath)
            : nil
    }

    /// La cartella `originals` c'e', e' una cartella e si lascia elencare con almeno una voce.
    /// Vuota conta come illeggibile, come in `PhotosLibraryPresence.read`.
    private static func isReadableLibraryRoot(_ root: URL?) -> Bool {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return false }
        return !names.isEmpty
    }

    private enum Verification {
        case ok([(entry: LibraryIndexEntry, url: URL)])
        case skip(DuplicateTrashSkipReason)
    }"""),

("runner: cartella originals letta sul main prima della corsa",
"""        let totalBlocks = plan.blocks.count
        let totalFiles = plan.blocks.reduce(0) { $0 + $1.reduce(0) { $0 + $1.leaving.count } }""",
"""        // La cartella `originals` per il ricontrollo dal vivo del trasher (ADR-0018). `nil` se il
        // bookmark non si risolve: allora nessuna copia in «Foto iPhone» esce.
        let photosLibraryRoot = BookmarkManager.shared.urls[.photos]
        let totalBlocks = plan.blocks.count
        let totalFiles = plan.blocks.reduce(0) { $0 + $1.reduce(0) { $0 + $1.leaving.count } }"""),

("runner: decisioni e trasher con la libreria Foto",
"""                let decisions = block.map { DuplicateTrasher.Decision(group: $0.group, keeper: $0.choice.keeper) }
                let trasher = DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest)""",
"""                let decisions = block.map {
                    DuplicateTrasher.Decision(group: $0.group, keeper: $0.choice.keeper,
                                              keptByPhotosLibrary: $0.choice.keptByPhotosLibrary)
                }
                let trasher = DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest,
                                               photosLibraryRoot: photosLibraryRoot)"""),
]
```

### `03-panel-and-menu.py`

```python
# Task 3 — Pannello Doppioni: casella spenta con il motivo per i gruppi senza niente da
# spostare, copie che restano mostrate con la loro etichetta, riga in testa sulla libreria Foto;
# voce «Doppioni» nel pannello laterale.
PATCHES = [
("DuplicatesStatus: regole e testi della libreria Foto",
"""// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)
""",
"""// MARK: - Le copie che la libreria Foto del Mac ha ancora, nel pannello Doppioni (ADR-0018)

/// Regole e frasi del pannello per le copie che restano perche' la libreria Foto del Mac le ha
/// ancora. Logica pura, testata senza aprire la finestra; stesso registro anti-gergo.
extension DuplicatesStatus {
    /// Un gruppo si puo' spuntare solo se la garanzia dell'inventario e' pronta e lo copre
    /// (ADR-0017) **e** ha almeno una copia da spostare (ADR-0018). Un punto solo per tutti i
    /// percorsi della finestra: casella, selezione in massa, conteggi, riepilogo.
    static func canSelect(_ hash: String, certification: DuplicateCertification?, nothingToMove: Set<String>) -> Bool {
        guard let certification, !nothingToMove.contains(hash) else { return false }
        return certification.isSelectable(hash)
    }

    /// La riga sotto un gruppo che non si puo' spuntare, `nil` se si puo'. Precedenza: niente da
    /// spostare (vale qualunque sia l'inventario, e si risolve solo in Foto) > garanzia non ancora
    /// pronta > motivo della garanzia.
    static func rowBlockedLine(_ hash: String, certification: DuplicateCertification?,
                               nothingToMove: Set<String>, photosLibraryKnown: Bool) -> String? {
        if nothingToMove.contains(hash) { return nothingToMoveRowLine(photosLibraryKnown: photosLibraryKnown) }
        guard let certification else { return certificationPendingRowLine }
        return certification.block(for: hash).map { blockedRowLine($0) }
    }

    /// Perche' un gruppo non ha niente da spostare. Con la libreria letta, dice anche cosa fare:
    /// togliere i doppioni da Foto, non da qui.
    static func nothingToMoveRowLine(photosLibraryKnown: Bool) -> String {
        photosLibraryKnown
            ? "Non si può spuntare: le copie in più stanno tutte in «Foto iPhone» e sono ancora nella "
                + "libreria Foto del Mac. Se le spostassi nel Cestino, il prossimo backup dal Mac le "
                + "ricopierebbe. Se vuoi tenerne una sola, togli i doppioni dalla libreria Foto, non da qui."
            : "Non si può spuntare: le copie in più stanno tutte in «Foto iPhone» e l'app non è riuscita "
                + "a leggere la libreria Foto del Mac, quindi per sicurezza restano dove sono."
    }

    /// La riga in testa al pannello sulla libreria Foto. `nil` se si e' lasciata leggere e nessuna
    /// copia resta per lei.
    static func photosLibraryLine(photosLibraryKnown: Bool, keptCopies: Int) -> Line? {
        guard photosLibraryKnown else {
            return Line(id: "photos-unknown", tone: .warning, text:
                "L'app non è riuscita a leggere la libreria Foto del Mac: per sicurezza nessuna copia in "
                + "«Foto iPhone» si sposta, perché se fosse ancora in Foto il prossimo backup la "
                + "ricopierebbe. Controlla in Configurazione la cartella della Libreria Foto, poi riapri "
                + "questa finestra.")
        }
        guard keptCopies > 0 else { return nil }
        let one = keptCopies == 1
        return Line(id: "photos-kept", tone: .info, text:
            "\\(count(keptCopies, "copia", "copie")) in «Foto iPhone» \\(one ? "resta" : "restano") dove "
            + "\\(one ? "è" : "sono"), perché \\(one ? "è" : "sono") ancora nella libreria Foto del Mac: se "
            + "\\(one ? "la" : "le") spostassi nel Cestino, il prossimo backup dal Mac \\(one ? "la" : "le") "
            + "ricopierebbe. Per tenerne una sola, togli i doppioni dalla libreria Foto.")
    }
}

// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)
"""),

("DuplicatesView: riga in testa sulla libreria Foto",
"""            certificationBanner

            Label(DuplicatesStatus.mirrorsUntouchedNote(), systemImage: "externaldrive.badge.checkmark")""",
"""            certificationBanner

            photosLibraryBanner

            Label(DuplicatesStatus.mirrorsUntouchedNote(), systemImage: "externaldrive.badge.checkmark")"""),

("toggleSelection: un punto solo per «si puo' spuntare»",
"""        guard selectedHashes.contains(hash) || certification?.isSelectable(hash) == true else { return }""",
"""        guard selectedHashes.contains(hash) || canSelect(hash) else { return }"""),

("selectAllVisible",
"""            if certification?.isSelectable(hash) == true { selectedHashes.insert(hash) }""",
"""            if canSelect(hash) { selectedHashes.insert(hash) }"""),

("rebuildBatch: la selezione tiene solo i gruppi spuntabili",
"""                self.selectedHashes = self.selectedHashes.filter {
                    finalByHash[$0] != nil && self.certification?.isSelectable($0) == true
                }""",
"""                self.selectedHashes = self.selectedHashes.filter {
                    finalByHash[$0] != nil && self.canSelect($0)
                }"""),

("beginConfirmation",
"""        let selected = loadedBatch.groups.filter {
            selectedHashes.contains($0.group.hash) && certification.isSelectable($0.group.hash)
        }""",
"""        let selected = loadedBatch.groups.filter {
            selectedHashes.contains($0.group.hash)
                && DuplicatesStatus.canSelect($0.group.hash, certification: certification,
                                              nothingToMove: loadedBatch.nothingToMove)
        }"""),

("blockedRowLine: delega allo stato puro",
"""    private func blockedRowLine(for hash: String) -> String? {
        guard let certification else { return DuplicatesStatus.certificationPendingRowLine }
        return certification.block(for: hash).map { DuplicatesStatus.blockedRowLine($0) }
    }""",
"""    private func blockedRowLine(for hash: String) -> String? {
        DuplicatesStatus.rowBlockedLine(hash, certification: certification,
                                        nothingToMove: loadedBatch?.nothingToMove ?? [],
                                        photosLibraryKnown: photosPresence.isKnown)
    }

    /// Si puo' spuntare adesso? Letture O(1) su insiemi gia' calcolati (`DuplicatesStatus.canSelect`).
    private func canSelect(_ hash: String) -> Bool {
        DuplicatesStatus.canSelect(hash, certification: certification, nothingToMove: loadedBatch?.nothingToMove ?? [])
    }

    /// La riga in testa sulla libreria Foto del Mac (ADR-0018): solo con l'elenco letto.
    @ViewBuilder
    private var photosLibraryBanner: some View {
        if case .loaded = loadState,
           let line = DuplicatesStatus.photosLibraryLine(photosLibraryKnown: photosPresence.isKnown,
                                                         keptCopies: loadedBatch?.keptByPhotosLibraryCount ?? 0) {
            Label(line.text, systemImage: line.tone == .warning ? "exclamationmark.triangle" : "photo.on.rectangle")
                .font(AppFont.caption)
                .foregroundStyle(line.tone == .warning ? AppColor.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }"""),

("refreshCertification: la selezione tiene solo i gruppi spuntabili",
"""                self.certification = result
                self.selectedHashes = self.selectedHashes.filter { result.isSelectable($0) }""",
"""                self.certification = result
                self.selectedHashes = self.selectedHashes.filter { self.canSelect($0) }"""),

("recountBlocked",
"""        visibleBlockedCount = visibleIndices.reduce(0) { total, i in
            guard loadedBatch.groups.indices.contains(i) else { return total }
            return total + (certification.isSelectable(loadedBatch.groups[i].group.hash) ? 0 : 1)
        }
        ruleCoveredBlockedCount = ruleCoveredHashes.reduce(0) { $0 + (certification.isSelectable($1) ? 0 : 1) }""",
"""        let nothingToMove = loadedBatch.nothingToMove
        func selectable(_ hash: String) -> Bool {
            DuplicatesStatus.canSelect(hash, certification: certification, nothingToMove: nothingToMove)
        }
        visibleBlockedCount = visibleIndices.reduce(0) { total, i in
            guard loadedBatch.groups.indices.contains(i) else { return total }
            return total + (selectable(loadedBatch.groups[i].group.hash) ? 0 : 1)
        }
        ruleCoveredBlockedCount = ruleCoveredHashes.reduce(0) { $0 + (selectable($1) ? 0 : 1) }"""),

("DuplicateRoleBadge: terza etichetta",
"""private struct DuplicateRoleBadge: View {
    enum Kind { case kept, leaving }
    let kind: Kind

    var body: some View {
        Text(kind == .kept ? "RESTA" : "NEL CESTINO")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(kind == .kept ? AppColor.success : AppColor.warning)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill((kind == .kept ? AppColor.success : AppColor.warning).opacity(0.15)))
            .accessibilityLabel(kind == .kept ? "Questa copia resta sull'SSD"
                                              : "Questa copia viene spostata nel Cestino")
    }
}""",
"""private struct DuplicateRoleBadge: View {
    /// `keptInPhotos` (ADR-0018): una copia che resta perche' la libreria Foto del Mac la ha ancora.
    enum Kind { case kept, keptInPhotos, leaving }
    let kind: Kind

    private var text: String {
        switch kind {
        case .kept: return "RESTA"
        case .keptInPhotos: return "RESTA · È ANCORA IN FOTO"
        case .leaving: return "NEL CESTINO"
        }
    }

    private var color: Color { kind == .leaving ? AppColor.warning : AppColor.success }

    private var accessibilityText: String {
        switch kind {
        case .kept: return "Questa copia resta sull'SSD"
        case .keptInPhotos: return "Questa copia resta sull'SSD: è ancora nella libreria Foto del Mac"
        case .leaving: return "Questa copia viene spostata nel Cestino"
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
            .accessibilityLabel(accessibilityText)
    }
}"""),

("DuplicateGroupRow: mostra le copie che restano per la libreria Foto",
"""                ForEach(entry.leaving, id: \\.path) { leaving in""",
"""                // ADR-0018: le altre copie che restano perche' la libreria Foto del Mac le ha
                // ancora. Senza queste righe sparirebbero dalla lista: l'utente non vedrebbe
                // ne' che esistono ne' perche' restano.
                ForEach(entry.keptByPhotosLibrary, id: \\.path) { kept in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpacing.xs) {
                            DuplicateRoleBadge(kind: .keptInPhotos)
                            Text(kept.displayPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            RevealInFinderButton(url: url(for: kept))
                        }
                        DuplicateFileDetail(entry: kept).padding(.leading, AppSpacing.md)
                    }
                }

                ForEach(entry.leaving, id: \\.path) { leaving in"""),

("HamburgerPanel: voce Doppioni accanto a Inventario",
"""                        HamburgerRow(icon: "checklist", label: "Inventario", iconColor: .indigo) {
                            openWindow(id: "inventory")
                        }""",
"""                        HamburgerRow(icon: "checklist", label: "Inventario", iconColor: .indigo) {
                            openWindow(id: "inventory")
                        }
                        // Richiesta di Enrico del 2026-10-05: fino a oggi si arrivava ai Doppioni
                        // solo da Tools -> Diagnostica -> «Vedi le copie doppie…», e non la trovava
                        // (rovescia la scelta del 2026-08-28, «nessuna voce nell'hamburger»). Stessa
                        // finestra, stesso gate Touch ID (`Window("Doppioni", id: "duplicates")`);
                        // il bottone in Diagnostica resta.
                        HamburgerRow(icon: "square.on.square", label: "Doppioni", iconColor: .purple) {
                            openWindow(id: "duplicates")
                        }"""),
]
```

## Appendice B — File di test nuovi (stato finale, dopo il Task 3)

`DuplicatePhotosLibraryTests.swift` qui sotto è lo stato dopo il **Task 1**; le aggiunte dei Task 2 e 3 sono in Appendice C, in coda alla classe.

### `AppBackupFotoTests/PhotosLibraryPresenceTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// `PhotosLibraryPresence` (ADR-0018): quali copie in «Foto iPhone» hanno ancora il loro originale
/// nella libreria Foto del Mac. Su cartelle temporanee reali, come il resto del progetto: la
/// cartella `originals` finta ha lo stesso schema di quella vera (`<X>/<file>`).
///
/// Il verso sicuro e' il cuore di questo tipo: ogni volta che la lettura non e' completa e certa,
/// il risultato e' `.unknown`, che tiene TUTTE le copie in «Foto iPhone» — mai un elenco parziale,
/// che renderebbe spostabile una copia che il backup ricopierebbe.
final class PhotosLibraryPresenceTests: XCTestCase {

    private var root: URL!
    private var originals: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photospresence-\(UUID().uuidString)")
        originals = root.appendingPathComponent("Photos Library.photoslibrary/originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Una sottocartella resa illeggibile da un test va riaperta prima di cancellare.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e {
                _ = chmod(root.appendingPathComponent(rel).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeOriginal(_ relative: String) throws {
        let url = originals.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// Una copia sull'SSD come la scrive l'elenco: chiave normalizzata e percorso com'e' su disco.
    private func ssdCopy(_ displayPath: String) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(displayPath), displayPath: displayPath,
                          size: 1, mtime: 0, hash: "h", hashedAt: 0)
    }

    // MARK: - Lettura

    func testRead_everyFileOfOriginals_holdsItsCopyInFotoIPhone() throws {
        try makeOriginal("1/1103F08E-E098-47BE-A402-3708A737BA1C.mp4")
        try makeOriginal("F/F4E891D9-8927-46D3-8174-BE672BC35B25.mov")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)

        XCTAssertTrue(presence.isKnown)
        XCTAssertEqual(presence.mainLibraryKeys?.count, 2)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/1/1103F08E-E098-47BE-A402-3708A737BA1C.mp4")))
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/F/F4E891D9-8927-46D3-8174-BE672BC35B25.mov")))
    }

    func testCopyWhoseOriginalIsGone_isNotHeld() throws {
        try makeOriginal("1/ancora.jpg")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone/1/tolta-da-foto.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone/2/ancora.jpg")), "stessa foto, altra sottocartella: non e' lei")
    }

    /// Stessa regola delle chiavi dell'elenco: maiuscole e forma Unicode non contano (exFAT non
    /// distingue le maiuscole e non normalizza).
    func testHolds_ignoresCaseAndUnicodeForm_likeTheList() throws {
        try makeOriginal("1/Caff\u{00E8}.JPG")                      // NFC
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertTrue(presence.holds(ssdCopy("FOTO IPHONE/1/caffe\u{0300}.jpg")))  // NFD, minuscole
    }

    /// Solo «Foto iPhone» e' scritta dal backup: le copie altrove non dipendono mai dalla
    /// libreria Foto, anche con lo stesso percorso relativo. Confronto per componente.
    func testCopiesOutsideFotoIPhone_areNeverHeld() throws {
        try makeOriginal("1/a.jpg")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertFalse(presence.holds(ssdCopy("Takeout/1/a.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone 2/1/a.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("1/a.jpg")))
        XCTAssertFalse(PhotosLibraryPresence.unknown.holds(ssdCopy("Takeout/1/a.jpg")),
                       "anche senza libreria leggibile, fuori da «Foto iPhone» non resta niente in piu'")
    }

    func testKey_isTheListKeyOfTheBackupCopy() {
        XCTAssertEqual(PhotosLibraryPresence.key(forOriginalsRelativePath: "1/IMG_0001.HEIC"),
                       normalizedIndexKey("Foto iPhone/1/IMG_0001.HEIC"))
    }

    /// Un file direttamente in `originals` (non in una sottocartella) si mappa lo stesso.
    func testFileDirectlyInOriginals_isMapped() throws {
        try makeOriginal("sciolto.jpg")
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: originals).holds(ssdCopy("Foto iPhone/sciolto.jpg")))
    }

    /// I nascosti contano (un file in piu' tiene una copia in piu', mai il contrario).
    func testHiddenFiles_areCounted() throws {
        try makeOriginal("1/.nascosto.jpg")
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: originals).holds(ssdCopy("Foto iPhone/1/.nascosto.jpg")))
    }

    /// La root raggiunta da un link simbolico: l'enumeratore restituisce la forma `realpath`.
    func testRootThroughASymlink_stillMaps() throws {
        try makeOriginal("3/a.jpg")
        let link = root.appendingPathComponent("collegamento")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originals)
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: link).holds(ssdCopy("Foto iPhone/3/a.jpg")))
    }

    // MARK: - Il verso sicuro: non si sa ⇒ tutte le copie in «Foto iPhone» restano

    func testNoBookmark_isUnknown_andEveryFotoIPhoneCopyIsHeld() {
        let presence = PhotosLibraryPresence.read(originalsRoot: nil)
        XCTAssertFalse(presence.isKnown)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/1/qualunque.jpg")))
    }

    func testMissingRoot_isUnknown() {
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: root.appendingPathComponent("non-esiste")), .unknown)
    }

    func testRootIsAFile_isUnknown() throws {
        let file = root.appendingPathComponent("file.jpg")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: file), .unknown)
    }

    /// Una libreria vuota e una libreria che non si lascia leggere si confondono: nel dubbio,
    /// `.unknown` (che tiene tutto), mai «nessuna copia nella libreria» (che sposterebbe tutto).
    func testEmptyOriginals_isUnknown() throws {
        try FileManager.default.createDirectory(at: originals.appendingPathComponent("0"), withIntermediateDirectories: true)
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: originals), .unknown)
    }

    /// Una sottocartella che non si lascia aprire: la lettura e' incompleta, quindi `.unknown` —
    /// anche se gli altri file si sono letti. Un elenco parziale renderebbe spostabili proprio le
    /// copie della cartella illeggibile.
    func testUnreadableSubfolder_isUnknown_notAPartialList() throws {
        try makeOriginal("1/a.jpg")
        try makeOriginal("2/b.jpg")
        let locked = originals.appendingPathComponent("2")
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        defer { _ = chmod(locked.path, 0o755) }
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertEqual(presence, .unknown)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/2/b.jpg")))
    }
}
```

### `AppBackupFotoTests/DuplicatePhotosLibraryTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Le copie in «Foto iPhone» che la libreria Foto del Mac ha ancora non escono mai (ADR-0018):
/// scelta della tenuta, blocco, piano della corsa, spiegazione e riepilogo. Logica pura.
///
/// Fixture costruite contro i mutanti, come in `DuplicateBatchTests`: la copia «nella libreria»
/// non e' mai la prima del gruppo, non e' la piu' vecchia e non ha il percorso piu' corto,
/// cosi' una regola che la ignorasse sceglierebbe un'altra copia.
final class DuplicatePhotosLibraryTests: XCTestCase {

    private func entry(_ displayPath: String, size: Int64 = 1_000, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(displayPath), displayPath: displayPath,
                          size: size, mtime: mtime, hash: "H", hashedAt: 1_700_003_600)
    }

    private func group(_ members: [LibraryIndexEntry], hash: String = "H") -> DuplicateGroup {
        DuplicateGroup(hash: hash, size: members.map(\.size).min() ?? 0,
                       members: members.map {
                           LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                             mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                       })
    }

    /// La libreria Foto letta, con questi file (percorsi sotto «Foto iPhone»).
    private func photos(_ displayPaths: String...) -> PhotosLibraryPresence {
        .known(Set(displayPaths.map(normalizedIndexKey)))
    }

    private let rimossaDaFoto = "Foto iPhone/0/A.jpg"         // la piu' vecchia, percorso corto
    private let ancoraInFoto = "Foto iPhone/1/IMG_0002_lungo.jpg"

    // MARK: - Quale copia si tiene

    /// Senza la regola 1b vincerebbe la piu' vecchia (rimossa da Foto) e quella ancora in Foto
    /// resterebbe lo stesso: due copie tenute invece di una.
    func testKeeper_isTheCopyStillInPhotos_evenIfAnotherIsOlder() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto, mtime: 1_700_000_000)
        let c = duplicateKeepChoice(group([old, inPhotos]), rule: nil, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .stillInPhotosLibrary)
        XCTAssertEqual(c.keptByPhotosLibrary, [])
        let e = DuplicateBatch.Entry(group: group([old, inPhotos]), choice: c)
        XCTAssertEqual(e.leaving.map(\.path), [old.path])
    }

    /// Il caso comune (una copia in «Foto iPhone», le altre fuori): tenuta e motivo come prima.
    func testCommonCase_mainLibraryVersusTakeout_isUnchanged() {
        let takeout = entry("Takeout/a.jpg", mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let c = duplicateKeepChoice(group([takeout, inPhotos]), rule: nil, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .mainLibrary)
        XCTAssertEqual(DuplicateBatch.Entry(group: group([takeout, inPhotos]), choice: c).leaving.map(\.path), [takeout.path])
    }

    /// Due copie ancora in Foto (doppioni veri della libreria Foto) e una in Takeout: una delle
    /// due e' la tenuta, l'altra resta, esce solo Takeout.
    func testTwoCopiesStillInPhotos_bothStay_onlyTheOtherLeaves() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let takeout = entry("Takeout/b.jpg", mtime: 1_400_000_000)
        let g = group([takeout, f1, f2])
        let c = duplicateKeepChoice(g, rule: nil, photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        let e = DuplicateBatch.Entry(group: g, choice: c)
        XCTAssertTrue([f1.path, f2.path].contains(c.keeper.path))
        XCTAssertEqual(c.keptByPhotosLibrary, Set([f1.path, f2.path]).subtracting([c.keeper.path]))
        XCTAssertEqual(e.leaving.map(\.path), [takeout.path])
        XCTAssertEqual(e.keptByPhotosLibrary.count, 1)
        XCTAssertEqual(e.reclaimableBytes, 1_000, "si libera solo la copia di Takeout")
    }

    /// Tutte le copie in piu' ancora in Foto: niente da spostare.
    func testAllExtraCopiesStillInPhotos_nothingToMove() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let b = DuplicateBatch(groups: [group([f1, f2], hash: "h1")], rule: nil,
                               photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        XCTAssertEqual(b.groups.count, 1, "il gruppo resta visibile")
        XCTAssertEqual(b.groups[0].leaving.map(\.path), [])
        XCTAssertEqual(b.nothingToMove, ["h1"])
        XCTAssertEqual(b.fileCount, 0)
        XCTAssertEqual(b.reclaimableBytes, 0)
        XCTAssertEqual(b.keptByPhotosLibraryCount, 1)
    }

    /// La regola dell'utente resta sovrana: «tieni in Takeout, sposta da Foto iPhone» non sposta
    /// una copia ancora in Foto — il gruppo resta senza niente da spostare.
    func testUserRule_cannotMoveACopyStillInPhotos() {
        let takeout = entry("Takeout/a.jpg")
        let inPhotos = entry(ancoraInFoto)
        let rule = DuplicateFolderRule(keepIn: normalizedIndexKey("Takeout"), trashIn: [normalizedIndexKey("Foto iPhone")])
        let b = DuplicateBatch(groups: [group([inPhotos, takeout], hash: "h1")], rule: rule, photos: photos(ancoraInFoto))
        XCTAssertEqual(b.groups[0].choice.keeper.path, takeout.path)
        XCTAssertEqual(b.groups[0].choice.reason, .userFolderRule)
        XCTAssertEqual(b.nothingToMove, ["h1"])
    }

    /// «Tieni in Foto iPhone»: fra le copie li', quella ancora in Foto.
    func testUserRule_keepInFotoIPhone_prefersTheCopyStillInPhotos() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let takeout = entry("Takeout/a.jpg", mtime: 1_400_000_000)
        let rule = DuplicateFolderRule(keepIn: normalizedIndexKey("Foto iPhone"), trashIn: [normalizedIndexKey("Takeout")])
        let c = duplicateKeepChoice(group([old, takeout, inPhotos]), rule: rule, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .stillInPhotosLibrary)
    }

    /// Libreria Foto non leggibile: ogni copia in «Foto iPhone» resta; quelle fuori escono.
    func testUnknownLibrary_keepsEveryFotoIPhoneCopy_butNotTheOthers() {
        let f1 = entry(rimossaDaFoto)
        let f2 = entry(ancoraInFoto)
        let takeout = entry("Takeout/a.jpg")
        let e = DuplicateBatch(groups: [group([takeout, f1, f2])], rule: nil, photos: .unknown).groups[0]
        XCTAssertEqual(e.leaving.map(\.path), [takeout.path])
        XCTAssertEqual(e.keptByPhotosLibrary.count, 1)
    }

    /// Libreria letta, nessuna copia ancora in Foto: tutto come prima.
    func testCopiesNoLongerInPhotos_leaveAsBefore() {
        let f1 = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let f2 = entry(ancoraInFoto)
        let e = DuplicateBatch(groups: [group([f1, f2])], rule: nil, photos: photos("Foto iPhone/9/altro.jpg")).groups[0]
        XCTAssertEqual(e.choice.keeper.path, f1.path)
        XCTAssertEqual(e.choice.reason, .oldest)
        XCTAssertEqual(e.leaving.map(\.path), [f2.path])
    }

    // MARK: - Il blocco e la corsa contano solo le copie che escono

    func testBatchTotals_countOnlyTheCopiesThatLeave() {
        let keeper = entry("Foto iPhone/2/IMG_0003.jpg", size: 500)
        let stays = entry(ancoraInFoto, size: 500)
        let leaves = entry("Takeout/x.jpg", size: 500)
        let b = DuplicateBatch(groups: [group([leaves, stays, keeper], hash: "h1")], rule: nil,
                               photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        XCTAssertEqual(b.fileCount, 1)
        XCTAssertEqual(b.reclaimableBytes, 500)
        XCTAssertEqual(b.verifiedBytes, 1_500, "si rileggono comunque tutte le copie, anche quelle che restano")
        XCTAssertEqual(b.folderBreakdown.map(\.folder), ["Takeout"], "«Foto iPhone» non perde niente")
        XCTAssertEqual(b.nothingToMove, [])
    }

    func testRunPlan_splitsAndEstimatesOnTheCopiesThatLeave() {
        let g1 = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")], hash: "h1")
        let g2 = group([entry("Foto iPhone/3/b.jpg"), entry("Takeout/b.jpg")], hash: "h2")
        let b = DuplicateBatch(groups: [g1, g2], rule: nil,
                               photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg", "Foto iPhone/3/b.jpg"))
        // Con 2 file per blocco: g1 fa uscire 1 file (non 2), quindi entrambi i gruppi stanno nello stesso blocco.
        XCTAssertEqual(DuplicateRunPlan(entries: b.groups, fileCap: 2, byteCap: .max).blocks.count, 1)
    }

    /// `init(entries:)` conserva le copie congelate come «nella libreria», senza ricalcolare.
    func testInitFromEntries_keepsTheFrozenSet() {
        let g = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")])
        let frozen = DuplicateBatch(groups: [g], rule: nil, photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg"))
        let sub = DuplicateBatch(entries: frozen.groups)
        XCTAssertEqual(sub.groups[0].choice.keptByPhotosLibrary, frozen.groups[0].choice.keptByPhotosLibrary)
        XCTAssertEqual(sub.fileCount, 1)
        XCTAssertEqual(sub.keptByPhotosLibraryCount, 1)
    }

    // MARK: - Testi

    func testExplanation_saysWhyTheCopyStillInPhotosIsKept() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let g = group([old, inPhotos])
        let text = duplicateKeepExplanation(duplicateKeepChoice(g, rule: nil, photos: photos(ancoraInFoto)), in: g)
        XCTAssertEqual(text, "Tengo la copia che si trova in «Foto iPhone/1»: è ancora nella libreria Foto del Mac, "
            + "quindi resta comunque. Se la spostassi, il prossimo backup dal Mac la ricopierebbe. C'è 1 altra copia "
            + "che risulta identica a questa, in base all'ultimo controllo delle foto sull'SSD.")
    }

    func testExplanation_saysWhichOtherCopiesStay() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let all = photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto)
        let pair = group([f1, f2])
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(pair, rule: nil, photos: all), in: pair)
            .hasSuffix(" Anche quella resta in «Foto iPhone», perché è ancora nella libreria Foto del Mac."))
        let trio = group([f1, f2, entry("Takeout/z.jpg")])
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(trio, rule: nil, photos: all), in: trio)
            .hasSuffix(" Una di queste resta comunque in «Foto iPhone», perché è ancora nella libreria Foto del Mac."))
        let quartet = group([f1, f2, entry("Foto iPhone/4/c.jpg"), entry("Takeout/z.jpg")])
        let three = photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto, "Foto iPhone/4/c.jpg")
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(quartet, rule: nil, photos: three), in: quartet)
            .hasSuffix(" 2 di queste restano comunque in «Foto iPhone», perché sono ancora nella libreria Foto del Mac."))
    }

    func testSummary_saysWhichCopiesStay_onlyWhenThereAreAny() {
        let g = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")])
        let with = DuplicateBatch(groups: [g], rule: nil, photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg"))
        XCTAssertTrue(with.summaryLines().contains(
            "Resta dov'è 1 copia in «Foto iPhone», perché è ancora nella libreria Foto del Mac: se la spostassi, "
            + "il prossimo backup dal Mac la ricopierebbe."))
        let without = DuplicateBatch(groups: [g], rule: nil, photos: .known([]))
        XCTAssertFalse(without.summaryLines().contains { $0.contains("libreria Foto") })
    }
}
```

## Appendice C — Aggiunte in coda alle classi (prima dell'ultima `}`)

### Task 1 — in coda a `MainThreadIsolationTests.swift`

```swift
    // MARK: - Le copie che la libreria Foto del Mac ha ancora (ADR-0018)

    /// La lettura di `originals` gira nel `Task.detached` di `DuplicatesView.loadGroups()`.
    func testPhotosLibraryPresenceRead_runsWithoutTheMainThread() throws {
        let originals = tmp.appendingPathComponent("originals/1")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: originals.appendingPathComponent("a.jpg"))
        let root = tmp.appendingPathComponent("originals")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = PhotosLibraryPresence.read(originalsRoot: root)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "PhotosLibraryPresence.read ha avuto bisogno del main thread: manca un nonisolated?")
    }
```

### Task 2 — in coda a `DuplicateTrasherTests.swift`

```swift
    // MARK: - Le copie che la libreria Foto del Mac ha ancora (ADR-0018): ultima linea di difesa

    /// Un file nella cartella `originals` finta, come l'ha la libreria Foto.
    private func makeOriginal(_ relative: String) throws {
        let url = photosLibraryRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "originale".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Una copia in «Foto iPhone» e una in Takeout, indicizzate; si tiene Takeout, cosi' la copia
    /// in «Foto iPhone» e' quella che uscirebbe.
    private func fotoIPhoneLeaving() throws -> (DuplicateTrasher.Decision, [LibraryIndexEntry]) {
        try makeMedia("Takeout/a.jpg", contents: "identiche")
        try makeMedia("Foto iPhone/1/a.jpg", contents: "identiche")
        let entries = [try entry("Takeout/a.jpg"), try entry("Foto iPhone/1/a.jpg")]
        try store.upsert(entries)
        return (DuplicateTrasher.Decision(group: group(entries), keeper: entries[0], keptByPhotosLibrary: []), entries)
    }

    /// Il caso dal vivo del 2026-10-05: la decisione lascia uscire la copia (la fotografia presa
    /// all'apertura non la vedeva in Foto, o un chiamante ha sbagliato), ma la libreria Foto ha
    /// l'originale adesso. Il trasher non la passa a `trashItem` e non tocca il gruppo.
    func testCopyStillInPhotos_isNeverTrashed_evenIfTheDecisionLetsItLeave() throws {
        let (decision, entries) = try fotoIPhoneLeaving()
        try makeOriginal("1/a.jpg")

        let outcome = makeTrasher().run([decision])

        XCTAssertEqual(spy.calls.count, 0, "nessun trashItem")
        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.first?.reason, .stillInPhotosLibrary(displayPath: "Foto iPhone/1/a.jpg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("Foto iPhone/1/a.jpg").path))
        XCTAssertTrue(manifest.lastBatch().isEmpty)
        XCTAssertEqual(try store.entries(withHash: entries[0].hash).count, 2, "l'elenco resta com'era")
    }

    /// Lo stesso gruppo, con l'originale non piu' in Foto: esce come prima.
    func testCopyNoLongerInPhotos_leavesAsBefore() throws {
        let (decision, _) = try fotoIPhoneLeaving()
        try makeOriginal("1/un-altro.jpg")

        let outcome = makeTrasher().run([decision])

        XCTAssertEqual(outcome.trashedFiles.map(\.originalKey), [normalizedIndexKey("Foto iPhone/1/a.jpg")])
        XCTAssertTrue(outcome.skippedGroups.isEmpty)
    }

    /// Libreria Foto non configurata, non trovata o vuota: nel verso sicuro nessuna copia in
    /// «Foto iPhone» esce, con un motivo che non finge di sapere.
    func testUnreadablePhotosLibrary_refusesFotoIPhoneCopies() throws {
        let (decision, _) = try fotoIPhoneLeaving()
        let empty = root.appendingPathComponent("originals-vuota", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for photosRoot in [nil, root.appendingPathComponent("non-esiste"), empty] {
            spy = TrashSpy(trashDir: trashDir)
            let trasher = DuplicateTrasher(libraryRoot: libraryRoot, store: store, manifest: manifest,
                                           photosLibraryRoot: photosRoot,
                                           trashFunction: { [spy] in try spy!.trash($0) })
            let outcome = trasher.run([decision])
            XCTAssertEqual(spy.calls.count, 0, "radice: \(String(describing: photosRoot))")
            XCTAssertEqual(outcome.skippedGroups.first?.reason,
                           .photosLibraryUnreadable(displayPath: "Foto iPhone/1/a.jpg"))
        }
    }

    /// Fuori da «Foto iPhone» la libreria Foto non conta, nemmeno se illeggibile: la copia in
    /// Takeout esce anche con lo stesso percorso relativo dentro `originals`.
    func testCopiesOutsideFotoIPhone_ignoreThePhotosLibrary() throws {
        try makeMedia("Foto iPhone/1/a.jpg", contents: "identiche")
        try makeMedia("Takeout/1/a.jpg", contents: "identiche")
        let entries = [try entry("Foto iPhone/1/a.jpg"), try entry("Takeout/1/a.jpg")]
        try store.upsert(entries)
        try makeOriginal("1/a.jpg")
        let decision = DuplicateTrasher.Decision(group: group(entries), keeper: entries[0], keptByPhotosLibrary: [])

        let outcome = makeTrasher().run([decision])
        XCTAssertEqual(outcome.trashedFiles.map(\.originalKey), [normalizedIndexKey("Takeout/1/a.jpg")])

        // Anche con la libreria Foto illeggibile: la tenuta in «Foto iPhone» non esce comunque.
        try makeMedia("Takeout/1/a.jpg", contents: "identiche")
        try store.upsert(entries)
        spy = TrashSpy(trashDir: trashDir)
        let blind = DuplicateTrasher(libraryRoot: libraryRoot, store: store, manifest: manifest,
                                     photosLibraryRoot: nil, trashFunction: { [spy] in try spy!.trash($0) })
        XCTAssertEqual(blind.run([decision]).trashedFiles.count, 1)
    }

    /// Le copie congelate come «nella libreria» restano: si rileggono (unanimita' su tutto il
    /// gruppo) ma non arrivano mai a `trashItem`; le altre escono.
    func testKeptByPhotosLibrary_isRereadButNeverTrashed() throws {
        try makeMedia("Foto iPhone/1/a.jpg", contents: "identiche")
        try makeMedia("Foto iPhone/2/a.jpg", contents: "identiche")
        try makeMedia("Takeout/a.jpg", contents: "identiche")
        let entries = [try entry("Foto iPhone/1/a.jpg"), try entry("Foto iPhone/2/a.jpg"), try entry("Takeout/a.jpg")]
        try store.upsert(entries)
        try makeOriginal("1/a.jpg")
        try makeOriginal("2/a.jpg")
        let decision = DuplicateTrasher.Decision(group: group(entries), keeper: entries[0],
                                                 keptByPhotosLibrary: [entries[1].path])
        var reread: [String] = []
        let outcome = makeTrasher(hashFunction: { reread.append($0.lastPathComponent + "@" + $0.deletingLastPathComponent().lastPathComponent); return sha256Measured(of: $0) })
            .run([decision])

        XCTAssertEqual(spy.calls.map { $0.standardizedFileURL.path },
                       [libraryRoot.appendingPathComponent("Takeout/a.jpg").standardizedFileURL.path])
        XCTAssertEqual(outcome.trashedFiles.count, 1)
        XCTAssertTrue(outcome.skippedGroups.isEmpty)
        XCTAssertEqual(reread.count, 3, "si rileggono tutte e tre le copie")
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("Foto iPhone/2/a.jpg").path))
    }

    /// Se restano tutte, non c'e' niente da spostare: nessuna rilettura, nessun `trashItem`.
    func testAllOthersKeptByPhotos_isNothingToTrash() throws {
        let (decision, entries) = try fotoIPhoneLeaving()
        let allKept = DuplicateTrasher.Decision(group: decision.group, keeper: entries[0],
                                                keptByPhotosLibrary: [entries[1].path])
        var reads = 0
        let outcome = makeTrasher(hashFunction: { reads += 1; return sha256Measured(of: $0) }).run([allKept])
        XCTAssertEqual(outcome.skippedGroups.first?.reason, .nothingToTrash)
        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertEqual(reads, 0)
    }

    /// Un percorso con `..` dentro «Foto iPhone» non si controlla nella libreria Foto: si rifiuta.
    func testFotoIPhonePathWithDotDot_isRefused() throws {
        try makeMedia("Takeout/a.jpg", contents: "identiche")
        try makeMedia("Foto iPhone/1/a.jpg", contents: "identiche")
        let keeper = try entry("Takeout/a.jpg")
        let tricky = try entry(at: libraryRoot.appendingPathComponent("Foto iPhone/1/a.jpg"),
                               displayPath: "Foto iPhone/../Foto iPhone/1/a.jpg")
        try store.upsert([keeper, tricky])
        let outcome = makeTrasher().run([.init(group: group([keeper, tricky]), keeper: keeper, keptByPhotosLibrary: [])])
        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertEqual(outcome.skippedGroups.first?.reason,
                       .photosLibraryUnreadable(displayPath: "Foto iPhone/../Foto iPhone/1/a.jpg"))
    }

    func testPhotosLibrarySkipReasons_haveTheirOwnExplanations() {
        let motivi: [DuplicateTrashSkipReason] = [
            .contentDisagrees(displayPath: "a.jpg"), .unreadable(displayPath: "a.jpg"),
            .sizeChanged(displayPath: "a.jpg"), .outsideLibrary(displayPath: "a.jpg"),
            .notMedia(displayPath: "a.jpg"), .nothingToTrash, .trashFailed(displayPath: "a.jpg", detail: "x"),
            .keeperVanished(displayPath: "a.jpg"),
            .stillInPhotosLibrary(displayPath: "a.jpg"), .photosLibraryUnreadable(displayPath: "a.jpg")
        ]
        XCTAssertEqual(Set(motivi.map(\.explanation)).count, motivi.count)
        for word in ["hash", "indice", "sha256", "entry", "scansione", "originals"] {
            XCTAssertFalse(DuplicateTrashSkipReason.stillInPhotosLibrary(displayPath: "a.jpg").explanation.lowercased().contains(word))
            XCTAssertFalse(DuplicateTrashSkipReason.photosLibraryUnreadable(displayPath: "a.jpg").explanation.lowercased().contains(word))
        }
    }
```

### Task 2 — in coda a `DuplicatePhotosLibraryTests.swift`

```swift
    // MARK: - Esito di una corsa con gruppi lasciati per la libreria Foto (Task 2)

    func testRunOutcome_groupsTheCopiesLeftForThePhotosLibrary() {
        let g1 = group([entry("Foto iPhone/1/a.jpg"), entry("Takeout/a.jpg")], hash: "h1")
        let g2 = group([entry("Foto iPhone/2/b.jpg"), entry("Takeout/b.jpg")], hash: "h2")
        var outcome = DuplicateRunOutcome(totalBlocks: 1)
        outcome.blocksCompleted = 1
        outcome.skippedGroups = [(g1, .stillInPhotosLibrary(displayPath: "Foto iPhone/1/a.jpg")),
                                 (g2, .stillInPhotosLibrary(displayPath: "Foto iPhone/2/b.jpg")),
                                 (g1, .photosLibraryUnreadable(displayPath: "Foto iPhone/1/a.jpg"))]
        let texts = DuplicatesStatus.runOutcomeLines(outcome).map(\.text)
        XCTAssertEqual(texts.filter { $0.contains("perché una copia era ancora nella libreria Foto del Mac") }.count, 1,
                       "due gruppi per lo stesso motivo: una riga sola")
        XCTAssertEqual(texts.filter { $0.contains("perché non sono riuscito a controllare la libreria Foto del Mac") }.count, 1)
    }
```

### Task 3 — in coda a `DuplicatePhotosLibraryTests.swift`

```swift
    // MARK: - Il pannello: casella, motivo, riga in testa (Task 3)

    /// Una garanzia dell'inventario fresca che copre il gruppo «sha-a» (stessa costruzione di
    /// `DuplicateCertificationTests`): SSD, HDD e Cubbit completi, copie dell'SSD viste.
    private func freshCertification() -> DuplicateCertification {
        func md5(_ c: Character) -> String { String(repeating: c, count: 32) }
        func file(_ path: String) -> InventoryLocalFile {
            InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1, status: .ok,
                               digest: ContentDigest(size: 10, sha256: "sha-a", md5: md5("a"), multipartETag: nil),
                               hashedAt: 2)
        }
        func state(_ a: InventoryArchive) -> InventoryArchiveState {
            InventoryArchiveState(archive: a, runId: 7, complete: true, reason: nil, unreadable: 0,
                                  startedAt: 1_000, finishedAt: 5_000)
        }
        let snapshot = InventorySnapshot(
            ssd: [file("Foto iPhone/1/a.jpg"), file("Takeout/a.jpg")],
            hdd: [file("Foto iPhone/1/a.jpg"), file("Takeout/a.jpg")],
            s3: [InventoryS3Object(key: normalizedIndexKey("Takeout/a.jpg"), displayKey: "Takeout/a.jpg", size: 10,
                                   etag: "\"\(md5("a"))\"")],
            states: [.ssd: state(.ssd), .hdd: state(.hdd), .s3: state(.s3)])
        let g = DuplicateGroup(hash: "sha-a", size: 10, members: [
            LibraryIndexEntry(path: normalizedIndexKey("Foto iPhone/1/a.jpg"), displayPath: "Foto iPhone/1/a.jpg",
                              size: 10, mtime: 1, hash: "sha-a", hashedAt: 2),
            LibraryIndexEntry(path: normalizedIndexKey("Takeout/a.jpg"), displayPath: "Takeout/a.jpg",
                              size: 10, mtime: 1, hash: "sha-a", hashedAt: 2)])
        let c = DuplicateCertification(basis: DuplicateCertificationBasis(snapshot: snapshot), lastArchiveWriteAt: nil, groups: [g])
        XCTAssertTrue(c.isSelectable("sha-a"), "premessa: il gruppo e' certificato")
        return c
    }

    func testCanSelect_needsTheGuarantee_andSomethingToMove() {
        let fresh = freshCertification()
        XCTAssertTrue(DuplicatesStatus.canSelect("sha-a", certification: fresh, nothingToMove: []))
        XCTAssertFalse(DuplicatesStatus.canSelect("sha-a", certification: fresh, nothingToMove: ["sha-a"]),
                       "certificato ma tutte le copie in piu' restano: niente da spuntare")
        XCTAssertFalse(DuplicatesStatus.canSelect("sha-a", certification: nil, nothingToMove: []))
        let stale = DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: [])
        XCTAssertFalse(DuplicatesStatus.canSelect("sha-a", certification: stale, nothingToMove: []))
    }

    /// «Niente da spostare» viene prima di tutto: vale qualunque sia l'inventario.
    func testRowLine_nothingToMoveComesFirst() {
        let stale = DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: [])
        let known = DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: true)
        XCTAssertEqual(DuplicatesStatus.rowBlockedLine("h", certification: nil, nothingToMove: ["h"], photosLibraryKnown: true), known)
        XCTAssertEqual(DuplicatesStatus.rowBlockedLine("h", certification: stale, nothingToMove: ["h"], photosLibraryKnown: true), known)
        XCTAssertEqual(DuplicatesStatus.rowBlockedLine("h", certification: stale, nothingToMove: ["h"], photosLibraryKnown: false),
                       DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: false))
    }

    func testRowLine_otherwiseTheGuaranteeDecides() {
        let stale = DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: [])
        XCTAssertEqual(DuplicatesStatus.rowBlockedLine("h", certification: nil, nothingToMove: [], photosLibraryKnown: true),
                       DuplicatesStatus.certificationPendingRowLine)
        XCTAssertEqual(DuplicatesStatus.rowBlockedLine("h", certification: stale, nothingToMove: ["altro"], photosLibraryKnown: true),
                       DuplicatesStatus.blockedRowLine(.inventoryUnreadable))
        XCTAssertNil(DuplicatesStatus.rowBlockedLine("sha-a", certification: freshCertification(), nothingToMove: [],
                                                     photosLibraryKnown: true))
    }

    func testNothingToMoveLine_saysWhatToDo_orWhyItCannotTell() {
        XCTAssertEqual(DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: true),
                       "Non si può spuntare: le copie in più stanno tutte in «Foto iPhone» e sono ancora nella "
                       + "libreria Foto del Mac. Se le spostassi nel Cestino, il prossimo backup dal Mac le "
                       + "ricopierebbe. Se vuoi tenerne una sola, togli i doppioni dalla libreria Foto, non da qui.")
        XCTAssertEqual(DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: false),
                       "Non si può spuntare: le copie in più stanno tutte in «Foto iPhone» e l'app non è riuscita "
                       + "a leggere la libreria Foto del Mac, quindi per sicurezza restano dove sono.")
    }

    func testPhotosLibraryLine() {
        XCTAssertNil(DuplicatesStatus.photosLibraryLine(photosLibraryKnown: true, keptCopies: 0))
        let one = DuplicatesStatus.photosLibraryLine(photosLibraryKnown: true, keptCopies: 1)
        XCTAssertEqual(one?.tone, .info)
        XCTAssertEqual(one?.text, "1 copia in «Foto iPhone» resta dove è, perché è ancora nella libreria Foto del Mac: "
            + "se la spostassi nel Cestino, il prossimo backup dal Mac la ricopierebbe. Per tenerne una sola, "
            + "togli i doppioni dalla libreria Foto.")
        XCTAssertEqual(DuplicatesStatus.photosLibraryLine(photosLibraryKnown: true, keptCopies: 3)?.text,
                       "3 copie in «Foto iPhone» restano dove sono, perché sono ancora nella libreria Foto del Mac: "
                       + "se le spostassi nel Cestino, il prossimo backup dal Mac le ricopierebbe. Per tenerne una "
                       + "sola, togli i doppioni dalla libreria Foto.")
        let unknown = DuplicatesStatus.photosLibraryLine(photosLibraryKnown: false, keptCopies: 0)
        XCTAssertEqual(unknown?.tone, .warning)
        XCTAssertEqual(unknown?.id, "photos-unknown")
        XCTAssertEqual(DuplicatesStatus.photosLibraryLine(photosLibraryKnown: false, keptCopies: 5)?.id, "photos-unknown",
                       "senza libreria leggibile vale l'avviso, non il conteggio")
    }

    func testNewTexts_haveNoJargon() {
        let texts = [DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: true),
                     DuplicatesStatus.nothingToMoveRowLine(photosLibraryKnown: false),
                     DuplicatesStatus.photosLibraryLine(photosLibraryKnown: false, keptCopies: 0)?.text ?? "",
                     DuplicatesStatus.photosLibraryLine(photosLibraryKnown: true, keptCopies: 2)?.text ?? ""]
        for text in texts {
            for word in ["hash", "indice", "sha", "scansione", "entry", "originals", "bookmark", "cache"] {
                XCTAssertFalse(text.lowercased().contains(word), "gergo «\(word)» in: \(text)")
            }
        }
    }
```

