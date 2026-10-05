# Doppioni sull'SSD con la garanzia dell'inventario — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: APPROVATO da Enrico il 2026-10-05** — S1-S9 approvati, D1 (testo del punto 1 della «Regola assoluta») approvato così com'è, D2 e D3 come raccomandato.

**Base:** `main` a `2e32d56` (1.159 test: conteggio delle `func test` nei 78 file, ed eseguiti tutti, 0 fallimenti, 0 warning, nel prototipo descritto sotto), branch nuovo `feature/certified-duplicates-ssd`. Spec: `Docs/superpowers/specs/2026-10-05-certified-duplicates-ssd-design.md` (approvata a voce il 2026-10-05). Numerazione riservata: **ADR-0017**, **ROADMAP #46**.

**Goal:** nel pannello Doppioni un gruppo di copie sull'SSD si può spuntare solo se l'ultimo inventario è completo su SSD, HDD e Cubbit, nessun backup o import ha scritto dopo l'inizio di quel giro, il contenuto del gruppo è ✅ «Al sicuro», e tutte le sue copie (la tenuta e quelle che escono) sono nell'inventario dell'SSD di quel giro con lo stesso contenuto. Gli altri gruppi restano visibili con la casella spenta e il motivo scritto sotto; la selezione in massa e la regola per cartella li saltano e lo dicono nel conteggio. Allo spostamento resta tutto quello di oggi (riepilogo, conferma, rilettura dal vivo di ogni membro, Cestino, blocchi, «Annulla»), più un ricontrollo della freschezza prima di ogni blocco. Il registro del Cestino annota per ogni foto spostata il percorso della copia tenuta.

**Architecture:** tre pezzi puri e un po' di cablaggio. `ArchiveWriteClock` dice quando un job che scrive sugli archivi (Mac → SSD, SSD → HDD, SSD → Cubbit, import: tutti e soli quelli che passano da `BackupRunner.run(label:)`) ha scritto l'ultima volta. `DuplicateInventoryFreshness` decide se l'inventario vale (stati dei tre archivi + quell'ora); `DuplicateCertificationBasis` estrae dall'inventario salvato, **una volta e fuori dal main**, i contenuti ✅ (con `InventoryClassifier`, la stessa regola della finestra Inventario) e la mappa percorso → contenuto dell'SSD; `DuplicateCertification` dà a ogni gruppo caricato il suo verdetto, letto dalla finestra in O(1) per riga. `BackupRunner` tiene l'ultima base in memoria (si riusa finché gli stati non cambiano), segna l'inizio di ogni job e ricontrolla la freschezza prima di ogni blocco della corsa. `TrashedItem.keptPath` e `TrashHistoryEntry.keptPaths` sono campi nuovi letti con `decodeIfPresent`. Testi tutti in `DuplicatesStatus`.

**Tech Stack:** Swift 5.x, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, *Approachable Concurrency*, SwiftUI, SQLite (store esistente, nessuno schema nuovo), XCTest. Nessuna dipendenza nuova.

**Verifica preventiva fatta dall'Architect (2026-10-05), senza `xcodebuild`.** Tutto il codice di produzione dei Task 1-5 e **tutti** i test di questo piano sono stati compilati ed eseguiti **fuori da Xcode**, in `/private/tmp/claude-501/dupcert-plan/proto/`: l'intero `AppBackupFoto/ContentView.swift` di `2e32d56`, con le patch di questo piano applicate (testo identico a quello dei task; le patch sono in `proto/patches/0N-*.py`, una per task, ogni «Trova» presente esattamente una volta), compilato con `swiftc` con le stesse impostazioni del target, e i 78 file di test esistenti più i 3 nuovi e le aggiunte in un bundle lanciato con `xcrun xctest`. Risultato: **1.219 test, 0 fallimenti, 0 warning** (app e test); ogni task verificato anche da solo, in ordine (patch fino al task N + test fino al task N), con il conteggio scritto nel task. Mutanti provati: vedi «Mutanti verificati» in fondo. Differenze volute del prototipo, solo lì: `import Sparkle` sostituito da uno stub, `@main` tolto, `isRunningUnderTests()` forzato a `true`. Il cablaggio di `BackupRunner` e `DuplicatesView` (Task 4-5) è compilato senza warning ma **non eseguito** (SwiftUI, bookmark e volumi veri). **Nessuna scrittura su `/Volumes` né su Cubbit.**

**Fatti letti dall'Architect sul Mac di Enrico (sola lettura, 2026-10-05 sera):**
- Inventario salvato (`library-index.sqlite`, aperto `mode=ro`): giro `1791228398292`, **completo sui tre archivi**, iniziato il 2026-10-05 alle 20:26:38, finito alle 20:31:28 (SSD 59 s, HDD 67 s, Cubbit 4 min 50 s: le impronte invariate si riusano). Il secondo giro del 2026-09-30/10-01 aveva impiegato 19 + 52 + 4 minuti.
- Ultimo job registrato (`lastJobSummary` in `~/Library/Preferences/enri.AppBackupFoto.plist`): «SSD -> Cubbit S3», riuscito, 2026-09-26. **Oggi l'inventario è quindi «fresco»**; la chiave nuova `lastArchiveWriteJobStartedAt` non esiste ancora. `autoBackupOnSSDConnect` è spento.
- Stima SQL indipendente dal codice (stesso database, sola lettura): 27.760 gruppi di doppioni (142,7 GB in eccesso); in **tutti** ogni copia è nell'inventario dell'SSD con lo stesso contenuto e il contenuto è sull'HDD; almeno 27.727 hanno su Cubbit un oggetto con l'ETag a parte unica o a pezzi da 64 MiB uguale (gli altri 33 vanno guardati dalla classificazione vera, che riconosce anche le forme alternative dell'ETag). All'apertura del pannello, a codice finito, ci si aspettano quindi quasi tutti i gruppi spuntabili.

---

## Scostamenti dalla spec da far approvare

Trovati leggendo il codice a `2e32d56` e provando il codice nel prototipo. **Nessuno è stato applicato di nascosto**: il piano implementa la colonna «Proposta»; se Enrico sceglie l'alternativa, l'Implementer si ferma e rimanda all'Architect.

| # | La spec dice | Il codice / il problema | Proposta del piano | Alternativa |
| :--- | :--- | :--- | :--- | :--- |
| S1 | Il percorso tenuto va nel registro del Cestino (`TrashManifest`), per il progetto 4 | `TrashManifestStore` ricorda al massimo le ultime **2.000** voci (`maxItems`) e pota le altre; una corsa vera ne sposta decine di migliaia (89.541 copie in eccesso misurate il 2026-09-25). Il progetto 4 troverebbe il percorso tenuto solo per l'ultimo blocco | `TrashedItem.keptPath` (come da spec) **e** `TrashHistoryEntry.keptPaths` nella storia append-only `trash-history.jsonl` (una riga per blocco, mai potata), stesso ordine di `originalPaths`; entrambi letti con `decodeIfPresent` | Solo `TrashManifest`, come scritto: il progetto 4 dovrebbe ricostruire la tenuta per le foto potate |
| S2 | «il percorso tenuto» | `originalDisplayPath` nel registro è **assoluto** (`/Volumes/SSD - Enri/…`); la radice cambia nome se macOS monta l'SSD come «SSD - Enri 1», e su HDD e Cubbit serve il percorso relativo | `keptPath` = percorso **relativo** alla radice dell'SSD, scritto com'è sul disco (`LibraryIndexEntry.displayPath` della tenuta): è lo stesso percorso relativo dell'HDD e la stessa chiave di Cubbit | Assoluto, come `originalDisplayPath` |
| S3 | «nessun backup/import è finito dopo l'inizio di quel giro» | L'ultimo job si legge da `JobHistoryStore` (`lastJobSummary` in `UserDefaults`, scritto **solo alla fine**: `finishCopyStep`, `stop()`, ramo di errore di `run`). Un job interrotto da una chiusura forzata dell'app non scrive niente: un Mac → SSD a metà lascerebbe l'inventario «fresco» | `ArchiveWriteClock.lastWriteAt()` = la più recente fra la data dell'ultimo `JobSummary` e una chiave nuova `lastArchiveWriteJobStartedAt`, scritta da `run(label:)` **prima** di ogni scrittura. Contano tutti e soli i job che passano da `run(label:)` (Mac → SSD, SSD → HDD, SSD → Cubbit, import); non passano da lì spostamenti nel Cestino, annullamenti, riparazioni, inventario, lettura dell'elenco, ripristino | Solo `JobHistoryStore`, alla lettera: il caso della chiusura forzata resta coperto solo dalla regola 4 per le copie nuove sull'SSD (vedi «Fuori scope») |
| S4 | Testo: «aggiornalo, ci vogliono pochi minuti» | Non sempre vero: il secondo giro misurato (30/09-01/10) è durato 75 minuti, l'ultimo (05/10) 5 minuti | La riga dice quanto è durato **davvero** l'ultimo aggiornamento: «L'inventario è più vecchio dell'ultimo backup (5 ottobre 2026 alle 21:10): aggiornalo, poi torna qui. L'ultimo aggiornamento è durato circa 5 minuti.» (dagli stati dell'inventario, nessuna stima fissa) | Il testo della spec, fisso |
| S5 | Cinque motivi: mai fatto / incompleto / più vecchio dell'ultimo backup / non certificata su tutti e tre / file cambiato | Due casi reali non hanno un motivo vero fra i cinque: il database non si lascia leggere (dire «mai fatto» sarebbe falso), e — solo al ricontrollo — l'inventario rifatto fra il calcolo della finestra e lo spostamento (il giro che ha certificato non è più l'ultimo) | Due motivi in più: «l'app non è riuscita a leggere l'inventario salvato» e «l'inventario è stato aggiornato dopo che hai aperto questo elenco» (quest'ultimo compare solo nell'esito di una corsa fermata) | Ridurli a «incompleto» |
| S6 | «subito prima dello spostamento, il controllo di freschezza si rifà» | Una corsa dura fino a ~40 minuti in più blocchi | Il ricontrollo si fa **prima di ogni blocco**, fuori dal main, e pretende anche lo **stesso giro** che ha certificato i gruppi (`runId`). Se fallisce, la corsa si ferma lì (motivo di stop nuovo `.inventoryNoLongerValid`), i blocchi già fatti restano fatti, l'esito lo dice. Il runner rifiuta anche una corsa con un gruppo che la certificazione non copre | Una volta sola, prima del primo blocco |
| S7 | (non detto) | Se la finestra resta aperta durante un backup o un inventario, il suo verdetto resterebbe quello vecchio fino alla riapertura | La garanzia si ricalcola da sola quando finisce un backup (`isRunning` → falso) o un inventario (`isInventorying` → falso); con l'inventario non valido la riga in testa ha un bottone «Apri l'inventario…» | Ricalcolo solo all'apertura della finestra |
| S8 | «resta tutto quello che c'è oggi» (riepilogo compreso) | — | Nel riepilogo **una riga in più**, prima del piano della corsa: «Ogni foto di questo riepilogo risulta al sicuro anche sull'HDD e su Cubbit nell'inventario del … Subito prima di spostare, l'app ricontrolla che l'inventario valga ancora.» `summaryLines()` non cambia | Nessuna riga nuova |
| S9 | «La regola zero-delete resta com'è: l'unica porta resta il Cestino dell'SSD, ora con una condizione in più» | Il punto 1 della «Regola assoluta» in `Docs/CLAUDE.md` elenca le condizioni della porta: senza la nuova sarebbe incompleto; idem la checklist «IF il codice chiama `trashItem`» | Aggiungere la condizione al punto 1 e una riga alla checklist (testo nel Task 6, **da approvare parola per parola**, D1) | — |

### Decisioni da confermare (con la raccomandazione)

- **D1 — Il testo nuovo del punto 1 della «Regola assoluta» (S9).** Il Task 6 lo propone parola per parola. **Raccomandazione:** approvarlo prima del Task 0 o correggerlo: senza un testo approvato il Task 6 non si chiude.
- **D2 — Conta ogni job, anche quello che non ha copiato niente** (un SSD → HDD con zero file nuovi invecchia l'inventario come uno da mille). È la spec alla lettera ed è il verso sicuro; il prezzo è un aggiornamento dell'inventario dopo ogni backup prima di spostare doppioni (l'ultimo è durato 5 minuti; il backup automatico al collegamento dell'SSD oggi è spento). **Raccomandazione:** così. L'alternativa — contare solo i job che hanno copiato almeno un file, o che sono stati interrotti — toglie aggiornamenti inutili ma aggiunge un caso da sbagliare (un job interrotto che ha scritto mezzo file).
- **D3 — La base della certificazione resta in memoria nel runner** finché gli stati dei tre archivi non cambiano (decine di MB: ~140.000 percorsi e impronte dell'SSD più l'insieme dei contenuti ✅), invece di rileggere e riclassificare tutto l'inventario (~500.000 righe) a ogni apertura della finestra e dopo ogni corsa. Costo del calcolo non misurato sul volume vero: la stessa classificazione è quella che la finestra Inventario fa già all'apertura. **Raccomandazione:** così; l'alternativa (ricalcolare sempre) è più semplice ma costa secondi e centinaia di MB di passaggio a ogni caricamento.

---

## Global Constraints

- **Il pannello sposta solo gruppi certificati** (spec, «Regole»), e **tutto il resto di ADR-0005 resta**: rilettura e rihash di ogni membro, tenuta compresa, unanimità, `trashItem` nel Cestino dell'SSD, registro scritto prima del file successivo, blocchi, «Annulla l'ultimo spostamento». `DuplicateTrasher.verify` e la sequenza di `run` non cambiano: l'unica riga toccata nel trasher è il campo `keptPath` della voce del registro.
- **Una regola sola per ✅**: la certificazione usa `InventoryClassifier.classify`, la stessa funzione della finestra Inventario. Mai una seconda implementazione di «al sicuro».
- **L'inventario è una cache (ADR-0002)**: la certificazione **aggiunge** una condizione, non toglie la rilettura dal disco al momento dello spostamento. Un hash che la certificazione non conosce **non** è spuntabile (lista di permessi, non di divieti).
- **Freschezza** (`DuplicateInventoryFreshness.evaluate`): tre stati, tutti completi, stesso giro; poi `lastWriteAt > inizio del giro` ⇒ vecchio (confronto con l'**inizio**, stretto). Precedenza: mai fatto > incompleto > più vecchio dell'ultimo backup. Per gruppo, con l'inventario fresco: non ✅ > copia cambiata dopo l'inventario.
- **Fuori dal main**: la lettura dell'inventario e la classificazione (`DuplicateCertificationBasis.load`) e il verdetto per tutti i gruppi girano in `Task.detached`; i tipi sono `nonisolated` (value type puri, nessuna riga di sicurezza necessaria). Il ricontrollo della corsa legge gli stati dallo store nel `Task.detached` della corsa. Sul main restano solo letture O(1) per riga e conteggi su indici già calcolati. **Mai** un `filter`/`reduce` sui gruppi dentro il `body` (lezione del 2026-09-02).
- **Testi a schermo solo in `DuplicatesStatus`**, italiano semplice, senza gergo («hash», «indice», «SHA256», «scansione», «ETag», «MD5», «bucket», «cache»).
- **Registro retrocompatibile**: `keptPath` e `keptPaths` opzionali, `decodeIfPresent`; una voce vecchia resta valida con `nil`.
- **Nessuno schema SQLite nuovo, nessun file nuovo su disco**; una chiave nuova in `UserDefaults` (`lastArchiveWriteJobStartedAt`, una data).
- Tutto il codice in **`AppBackupFoto/ContentView.swift`**; test in **`AppBackupFotoTests/`**, ogni file nuovo registrato nel pbxproj nei **4 punti**. Si verifica sempre il totale `Executed N tests`.
- Un commit per task, messaggio in italiano, **mai `git push`**. **Nessuna scrittura su `/Volumes` né su Cubbit prima del Task 7**, che esegue l'orchestratore con Enrico.

---

## Mappa dei file e dei tipi

**`AppBackupFoto/ContentView.swift`** (righe verificate a `2e32d56`, 18.440 righe; si ritrova tutto con `grep -n`, i numeri si spostano dopo ogni task):

| Dove (riga a `2e32d56`) | Cosa | Task |
| :--- | :--- | :--- |
| `nonisolated struct TrashedItem` → `var restoredAt: Date? = nil` (2871), `nonisolated extension TrashedItem` (2975: `CodingKeys`, `init(from:)`) | `keptPath: String?` | 1 |
| `nonisolated struct TrashHistoryEntry` (3146), `TrashHistory.append` (`originalPaths: trashed.map`, 3207) | `keptPaths: [String]?` | 1 |
| `DuplicateTrasher.run`, costruzione di `TrashedItem` (`trashedAt: Date())`, 4172) | `keptPath: decision.keeper.displayPath` | 1 |
| **regione D**: subito prima di `// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)` (3613) | in quest'ordine: `ArchiveWriteClock`, `DuplicateInventoryFreshness`, `DuplicateCertificationBlock`, `DuplicateCertificationBasis`, `DuplicateCertification` (T2), poi `extension DuplicatesStatus` con i testi (T3). Ogni blocco si aggiunge **dopo** il precedente, sempre prima di quella riga `MARK` | 2-3 |
| `nonisolated enum DuplicateRunStopReason` (3590), `DuplicatesStatus.runOutcomeLines` (`case .interrupted:` a 3914) | `case inventoryNoLongerValid(DuplicateCertificationBlock)` e la sua riga | 3 |
| `BackupRunner.endDuplicateTrashing()` (11819) | `duplicateCertificationBasisCache`, `rememberDuplicateCertificationBasis(_:)` | 4 |
| `BackupRunner.startDuplicateTrashRun` (12031; il controllo `ssdMounted` per blocco a 12083) | parametro `certification:`, rifiuto di una corsa non coperta, ricontrollo prima di ogni blocco | 4 |
| `BackupRunner.run(label:...)` (`output = ""; stats = JobStats()` a 13481) | `ArchiveWriteClock.markStarted()` | 4 |
| `struct DuplicatesView` (17093-17891): `@State … thumbnailCache` (17192), `content`, `listArea`, `ruleEditorSheet` (17484), `summarySheet` (17627), `toggleSelection` (17673), `selectAllVisible` (17681), `reapplyFilter` (17731), `loadGroups` (17763), `rebuildBatch` (17793), `beginConfirmation` (17864), `startTrashing` (17880), `startUndo` (17888) | stato nuovo, riga in testa, casella spenta con motivo, conteggi, riepilogo; `extension DuplicatesView` dopo la `}` della struct con `certificationBanner`, `blockedRowLine(for:)`, `refreshCertification()`, `recountBlocked()` | 5 |
| `private struct DuplicateGroupRow` (18032) | `blockedReason: String?`, `.disabled`, riga del motivo | 5 |

Tipi esistenti usati e **non** modificati: `JobHistoryStore`/`JobSummary` (13619-13693), `LibraryIndexStore.inventoryStates()`/`inventorySnapshot()` (4857/4864), `InventoryArchiveState` (5808, `Equatable`), `InventorySnapshot`, `InventoryClassifier.classify` (6179), `DuplicateGroup`, `DuplicateBatch.Entry`, `DuplicateRunPlan`, `duplicateKeepChoice`.

**`AppBackupFotoTests/`** — nuovi: `DuplicateCertificationTests` (30), `ArchiveWriteClockTests` (5), `DuplicateCertificationStatusTests` (17). Estesi (in coda alla classe): `TrashManifestTests` (+3), `TrashHistoryTests` (+2), `DuplicateTrasherTests` (+2), `MainThreadIsolationTests` (+1). **Nessun test esistente cambia.** **Totale atteso: B + 60** (con B = 1.159, **1.219**).

**Docs:** `Docs/adr/0017-…md` (nuovo), `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`.

### ID per il pbxproj (verificati assenti a `2e32d56` con `grep -c`)

| File | `PBXFileReference` | `PBXBuildFile` |
| :--- | :--- | :--- |
| `DuplicateCertificationTests.swift` | `0AD7A73E4152051C79F6A0CB` | `D2A50B3C054F2C11D73854B5` |
| `ArchiveWriteClockTests.swift` | `4FFCEC4262EDFEC724EC777B` | `8F1F1C0D7A29DB01536FF1DC` |
| `DuplicateCertificationStatusTests.swift` | `15EF2A3B9C10CF5411E285B2` | `DBA7082C2B0608C672FE5540` |

Per ogni file le quattro righe hanno questa forma (esempio con `ArchiveWriteClockTests`; i tab sono quelli delle righe vicine; gruppo e fase verificati presenti a `2e32d56`, le righe di `QuarantineExclusionTests` sono un buon vicino):

```
/* sezione PBXBuildFile */
		8F1F1C0D7A29DB01536FF1DC /* ArchiveWriteClockTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 4FFCEC4262EDFEC724EC777B /* ArchiveWriteClockTests.swift */; };
/* sezione PBXFileReference */
		4FFCEC4262EDFEC724EC777B /* ArchiveWriteClockTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ArchiveWriteClockTests.swift; sourceTree = "<group>"; };
/* children del gruppo 11123F514533138A989F11C4 /* AppBackupFotoTests */ */
				4FFCEC4262EDFEC724EC777B /* ArchiveWriteClockTests.swift */,
/* files della fase 62FE197CBAC2C2E908580583 /* Sources */ */
				8F1F1C0D7A29DB01536FF1DC /* ArchiveWriteClockTests.swift in Sources */,
```

Prima di usarli: `grep -c <ID> AppBackupFoto.xcodeproj/project.pbxproj` deve dare `0`.

---

## Comandi di build e test

**Precondizione di ogni build/test con `xcodebuild`:** nessun backup in corso nell'app di Enrico (il target di test ha `TEST_HOST` = l'app). `SP` = una cartella di lavoro sotto `/private/tmp/claude-501/`, mai il `derivedDataPath` di default.

**Su questo progetto `xcodebuild` impiega più di 10 minuti**, e un agente fermo 10 minuti senza output viene terminato. Due livelli, quindi:

1. **Verifica veloce, a ogni step che lo chiede** (~50 s, nessun lancio dell'app): `fasttest.sh`, creato nel Task 0 con il testo qui sotto. Compila con `swiftc` **il vero** `AppBackupFoto/ContentView.swift` del repository e **tutti** i file di `AppBackupFotoTests/` (copiandoli in `$SP`, il repository non si tocca) con le impostazioni del target, e li esegue con `xcrun xctest`. Non vede: il pbxproj (un file di test non registrato lo esegue lo stesso — per questo il conteggio con `xcodebuild` resta obbligatorio ai punti di controllo), le risorse dell'app, il test host.
2. **`xcodebuild` vero, in background**, ai punti di controllo: fine dei Task 3 e 5 (e prima di unire il branch). Lanciarlo con `run_in_background` e aspettarne la fine con un ciclo di attesa sul file di log, mai in primo piano. È la sola prova che soddisfa l'hook di fine sessione (`BUILD SUCCEEDED`/`TEST SUCCEEDED`).

```bash
# 1. verifica veloce (una classe, o tutta la suite senza argomento)
/private/tmp/claude-501/dupcert-impl/fasttest.sh DuplicateCertificationTests
/private/tmp/claude-501/dupcert-impl/fasttest.sh            # atteso: "Executed N tests, with 0 failures", 0 warning
# 2. xcodebuild, in background (run_in_background: true), poi attesa sul log
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=/private/tmp/claude-501/dupcert-impl
rm -rf $SP/dd && xcodebuild -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l      # atteso 0, sempre
xcodebuild test-without-building -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" $SP/test.log | tail -2
```

Testo di `fasttest.sh` (da salvare in `/private/tmp/claude-501/dupcert-impl/fasttest.sh`, `chmod +x`; **non** va nel repository). È quello del piano precedente con due righe cambiate (commento e `SP`):

```bash
#!/bin/bash
# Verifica veloce, FUORI da Xcode, di AppBackupFoto/ContentView.swift e di tutti i test del
# repository (ROADMAP #46, piano 2026-10-05). Non tocca il repository: copia i sorgenti in $SP.
# Uso: fasttest.sh [Classe di test]     (senza argomento: suite completa)
set -euo pipefail
REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=${SP:-/private/tmp/claude-501/dupcert-impl/fast}
rm -rf "$SP/src" "$SP/tests" "$SP/mod"; mkdir -p "$SP/src" "$SP/tests" "$SP/mod" "$SP/Tests.xctest/Contents/MacOS"
# Tre differenze, solo qui: niente Sparkle (stub), niente @main, test runner riconosciuto.
sed -e 's/^import Sparkle$//' -e 's/^@main$//' \
    -e 's/ProcessInfo.processInfo.environment\["XCTestConfigurationFilePath"\] != nil/true/' \
    "$REPO/AppBackupFoto/ContentView.swift" > "$SP/src/ContentView.swift"
cat > "$SP/src/SparkleStub.swift" <<'SWIFT'
import Foundation
final class SPUStandardUpdaterController {
    init(startingUpdater: Bool, updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?) {}
    func checkForUpdates(_ sender: Any?) {}
}
SWIFT
cp "$REPO"/AppBackupFotoTests/*.swift "$SP/tests/"
SDK=$(xcrun --show-sdk-path --sdk macosx); PLAT=$(xcrun --show-sdk-platform-path --sdk macosx)
FW="$PLAT/Developer/Library/Frameworks"; LIBX="$PLAT/Developer/usr/lib"
FLAGS=(-swift-version 5 -default-isolation MainActor
  -enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature MemberImportVisibility
  -target arm64-apple-macosx26.0 -sdk "$SDK" -Onone)
xcrun swiftc "${FLAGS[@]}" -enable-testing -module-name AppBackupFoto -emit-library -emit-module \
  -emit-module-path "$SP/mod/AppBackupFoto.swiftmodule" -o "$SP/libAppBackupFoto.dylib" \
  -Xlinker -install_name -Xlinker @rpath/libAppBackupFoto.dylib "$SP"/src/*.swift 2> "$SP/app.log" \
  || { grep -E 'error' "$SP/app.log" | head -20; echo "COMPILAZIONE APP FALLITA"; exit 1; }
xcrun swiftc "${FLAGS[@]}" -module-name Tests -I "$SP/mod" -L "$SP" -lAppBackupFoto -F "$FW" -I "$LIBX" -L "$LIBX" \
  -framework XCTest -Xlinker -bundle -Xlinker -rpath -Xlinker "$SP" -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIBX" -o "$SP/Tests.xctest/Contents/MacOS/Tests" "$SP"/tests/*.swift 2> "$SP/tests.log" \
  || { grep -E 'error' "$SP/tests.log" | head -20; echo "COMPILAZIONE TEST FALLITA"; exit 1; }
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Tests</string><key>CFBundleIdentifier</key><string>fast.Tests</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>' > "$SP/Tests.xctest/Contents/Info.plist"
echo "warning app: $(grep -c 'warning:' "$SP/app.log" || true) · warning test: $(grep -c 'warning:' "$SP/tests.log" || true)"
if [ -n "${1:-}" ]; then
  xcrun xctest -XCTest "$1" "$SP/Tests.xctest" 2>&1 | grep -E "error:|' failed \(|Executed [0-9]+ tests" | tail -25
else
  xcrun xctest "$SP/Tests.xctest" 2>&1 | grep -E "error:|' failed \(|Executed [0-9]+ tests" | tail -25
fi
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`**, mai col numero di riga: quelli citati valgono per `2e32d56` e si spostano dopo ogni task.
2. **Il codice si copia così com'è**: ogni «Trova … Sostituisci con …» di questo piano è stato applicato con un controllo automatico che il testo cercato comparisse **una sola volta**, poi compilato ed eseguito. Se un «Trova» non si trova, o qualcosa non compila nel target vero, **fermati e rimanda all'Architect**: non adattarlo a tentativi.
3. **Zero warning.** Un solo rimedio è autorizzato in anticipo: se un riferimento a una funzione statica `@MainActor` passata come valore dà «call to main actor-isolated … in a synchronous nonisolated context», si riscrive come chiusura. Ogni altro warning di isolamento: fermati.
4. **Nessuna asserzione esistente cambia**, e nessun test esistente si tocca se non per aggiungere test in coda alla classe (Task 1 e 2).
5. **Ogni task dichiara i mutanti che devono morire**; quelli segnati «(verificato)» sono stati provati dall'Architect sul prototipo.
6. **Commit con verifica veloce verde** (0 warning, conteggio uguale all'atteso), e ai punti di controllo anche con `xcodebuild` verde. Messaggio in italiano: oggetto, riga vuota, le due righe:
   ```
   Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
   ```
7. **Nessuna prova su `/Volumes` o su Cubbit** fino al Task 7.
8. **Revisione obbligatoria** (`Docs/CLAUDE.md`, ciclo in due fasi) a ogni task che tocca `trashItem`, `Task.detached` o UI da contesto async: Task 1 (`DuplicateTrasher`), Task 4 (runner), Task 5 (view).

---
### Task 0: branch, baseline, ADR-0017, strumento di verifica veloce

**Files:** `Docs/adr/0017-i-doppioni-sull-ssd-si-spostano-solo-se-l-inventario-fresco-li-certifica-al-sicuro-su-tutti-e-tre.md` (nuovo), `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md` (questo piano), `/private/tmp/claude-501/dupcert-impl/fasttest.sh` (fuori dal repository).

- [ ] **Step 1:** `git status --short`: l'unico file non tracciato ammesso è `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md` (di un altro piano: **non** si committa qui). `git switch -c feature/certified-duplicates-ssd main`; `git rev-parse --short HEAD` → `2e32d56` o un discendente (in quel caso rifai i `grep -n` delle ancore della mappa e fermati se una manca).
- [ ] **Step 2:** Verifica che Enrico abbia risposto su S1-S9 e D1-D3. Se una risposta è diversa dalla «Proposta», **fermati e rimanda all'Architect**.
- [ ] **Step 3:** Crea `fasttest.sh` (testo nella sezione «Comandi»), `chmod +x`, e lancialo senza argomenti: `Executed 1159 tests, with 0 failures`, 0 warning. Se il numero è diverso, `B` = quello misurato e tutti gli attesi del piano si spostano della differenza.
- [ ] **Step 4:** Chiedi a Enrico il via libera («nessun backup in corso nell'app?») e lancia in background la build pulita e la suite con `xcodebuild`: 0 warning, `Executed 1159 tests` (B).
- [ ] **Step 5:** Scrivi l'ADR con questo testo (in fondo, alla sezione «Risposte di Enrico», le risposte ricevute):

```markdown
# ADR-0017 — I doppioni sull'SSD si spostano solo se un inventario fresco li certifica al sicuro su tutti e tre gli archivi

**Data:** 2026-10-05
**Stato:** Accettata

## Contesto

Il pannello Doppioni (ADR-0005) sposta nel Cestino dell'SSD copie byte-identiche (ADR-0001) dopo una rilettura dal vivo di ogni membro del gruppo, ma non sapeva se quella foto esiste anche su HDD e Cubbit. Con l'inventario certificato (ADR-0015, ROADMAP #44) lo si sa per contenuto, e dopo la riparazione (ADR-0016, #45) tutte le foto risultano su tutti e tre. È il progetto 3 di 4 verso «una copia per archivio»: prima l'SSD, poi (progetto 4) HDD e Cubbit. Spec: `Docs/superpowers/specs/2026-10-05-certified-duplicates-ssd-design.md`; piano: `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md`.

## Opzioni valutate

- **A. Lasciare il pannello com'è.** Scartata: la garanzia «la foto resta al sicuro altrove» sarebbe solo un'abitudine (i backup), non una verifica.
- **B. Ricontrollare HDD e Cubbit dal vivo al momento dello spostamento.** Scartata: per decine di migliaia di gruppi vorrebbe dire rileggere l'HDD e chiedere a Cubbit per ore a ogni corsa; l'inventario esiste apposta.
- **C. Fidarsi dell'inventario, a condizione che sia completo e più recente dell'ultimo backup (scelta).** Un gruppo si può spuntare solo se il suo contenuto è ✅ nell'ultimo giro completo, nessun job che scrive sugli archivi è finito (o partito) dopo l'inizio di quel giro, e ogni sua copia sull'SSD è nell'inventario di quel giro con lo stesso contenuto. Allo spostamento resta la rilettura di ADR-0005, più un ricontrollo della freschezza prima di ogni blocco.

## Decisione e motivo

**Freschezza** (decisione 1 di Enrico): l'inventario vale se è completo su tutti e tre gli archivi (ADR-0015: incompleto non è assente) e nessun job che passa da `BackupRunner.run(label:)` — Mac → SSD, SSD → HDD, SSD → Cubbit, import — ha scritto dopo l'inizio del giro. «Ha scritto» = la più recente fra la fine dell'ultimo job (`JobHistoryStore`) e l'inizio dell'ultimo job (`lastArchiveWriteJobStartedAt`, scritta prima di ogni scrittura: copre il job interrotto da una chiusura forzata). Spostamenti nel Cestino, annullamenti, riparazioni, inventario e lettura dell'elenco non lo invecchiano.

**Gruppi non certificati** (decisione 2): visibili, casella spenta, una riga col motivo; selezione in massa e regola per cartella li saltano e lo dicono. Un gruppo che la certificazione non conosce non è mai spuntabile.

**Una regola sola per ✅**: `InventoryClassifier.classify`, la stessa della finestra Inventario, calcolata una volta fuori dal main e tenuta in memoria finché gli stati dei tre archivi non cambiano.

**Copia tenuta** (decisione 3): stessa scelta di oggi; il registro del Cestino (`TrashedItem.keptPath`) e la storia degli spostamenti (`TrashHistoryEntry.keptPaths`) annotano il percorso tenuto, relativo alla radice dell'SSD, per il progetto 4.

**Cosa si accetta di perdere:** dopo ogni backup, anche uno che non ha copiato niente, serve un aggiornamento dell'inventario prima di spostare doppioni (l'ultimo è durato 5 minuti, il secondo giro misurato 75); un gruppo con una copia comparsa sull'SSD dopo l'inventario resta bloccato finché l'inventario non la vede; la base in memoria occupa decine di MB mentre l'app è aperta.

**Per riaprirla** serve un argomento nuovo: per esempio un modo di sapere dal vivo, in pochi secondi, che HDD e Cubbit hanno ancora quel contenuto (checksum SHA256 lato server su Cubbit), che renderebbe superfluo fidarsi dell'inventario.

## Risposte di Enrico (S1-S9, D1-D3)

<!-- riportare qui, una riga per punto -->
```

- [ ] **Step 6:** Commit (solo documentazione: l'ADR e questo piano, copiato in `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md`):
  ```
  ADR-0017 e piano: doppioni sull'SSD con la garanzia dell'inventario

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 1: il registro annota il percorso tenuto

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `TrashedItem` (struct ed `extension`), `TrashHistoryEntry`, `TrashHistory.append`, `DuplicateTrasher.run` (una riga).
- Modify: `AppBackupFotoTests/TrashManifestTests.swift` (+3), `AppBackupFotoTests/TrashHistoryTests.swift` (+2), `AppBackupFotoTests/DuplicateTrasherTests.swift` (+2) — in coda alla classe, prima della `}` finale.

**Interfaces:**
- Produces: `TrashedItem.keptPath: String?` (`var`, default `nil`, dopo `restoredAt`: l'init membro a membro resta compatibile con ogni chiamante esistente); `TrashHistoryEntry.keptPaths: [String]?` (`let`, stesso ordine di `originalPaths`, `""` per una voce senza `keptPath`).
- Consumes: `DuplicateTrasher.Decision.keeper.displayPath` (relativo alla radice dell'SSD, S2).

`DuplicateTrasher` cambia **solo** nel valore registrato: nessun passo della sequenza di ADR-0005 si sposta. `TrashRestorer`/`markRestored` riscrivono la voce intera, quindi il campo sopravvive all'annullamento (test).

- [ ] **Step 1: test che falliscono.** In coda a `TrashManifestTests` (prima della `}` finale):

```swift
    // MARK: - Il percorso tenuto (ROADMAP #46, ADR-0017)

    /// Il registro annota quale copia del gruppo e' rimasta: il progetto 4 terra' lo stesso
    /// percorso su HDD e Cubbit. Il test riapre lo store da zero: conta quello che c'e' su disco.
    func testKeptPath_isWrittenToDisk() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        var it = try item(trashed: trashed, originalAt: root.appendingPathComponent("Takeout/a.jpg"))
        it.keptPath = "Foto iPhone/a.jpg"
        try store.record(it)

        XCTAssertEqual(try TrashManifestStore(url: manifestURL).lastBatch().first?.keptPath, "Foto iPhone/a.jpg")
    }

    /// Una voce scritta prima di questo campo (la forma di oggi, con `restoredAt`, JSON
    /// letterale) resta valida: `keptPath` vale `nil` («non si sa»), il resto e' intatto.
    func testRecordWithoutKeptPath_stillDecodes() throws {
        let vecchio = """
        {"totalRecorded":1,"items":[{"batchId":"b1","originalDisplayPath":"/x/a.jpg",\
        "originalKey":"a.jpg","trashedPath":"/x/.Trashes/a.jpg","size":4,"hash":"abc",\
        "trashedAt":770000000,"restoredAt":770000100}]}
        """
        try vecchio.write(to: manifestURL, atomically: true, encoding: .utf8)

        let items = try TrashManifestStore(url: manifestURL).lastBatch()
        XCTAssertEqual(items.count, 1, "una voce senza il campo nuovo ha fatto sparire il registro")
        XCTAssertNil(items.first?.keptPath)
        XCTAssertEqual(items.first?.hash, "abc")
        XCTAssertNotNil(items.first?.restoredAt)
    }

    /// «Annulla» riscrive la voce marcandola tornata: il percorso tenuto non deve andare perso.
    func testMarkRestored_keepsTheKeptPath() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        var it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        it.keptPath = "Other/tenuta.jpg"
        try store.record(it)
        try store.markRestored(it, at: Date())

        let riletta = try TrashManifestStore(url: manifestURL).lastBatch().first
        XCTAssertNotNil(riletta?.restoredAt)
        XCTAssertEqual(riletta?.keptPath, "Other/tenuta.jpg")
    }
```

In coda a `TrashHistoryTests`:

```swift
    // MARK: - Il percorso tenuto (ROADMAP #46, ADR-0017)

    /// Una riga per blocco, e per ogni foto spostata il percorso della copia tenuta, nello
    /// stesso ordine dei percorsi originali (due gruppi diversi nello stesso blocco: l'ordine
    /// conta, un mutante che li scambiasse direbbe a ogni foto la tenuta sbagliata).
    func testKeptPaths_followTheOrderOfTheOriginals() throws {
        let history = try TrashHistory(url: historyURL)
        var a = item(path: "/Volumes/SSD - Enri/Takeout/a.jpg")
        a.keptPath = "Foto iPhone/a.jpg"
        var b = item(path: "/Volumes/SSD - Enri/Takeout 2/b.jpg")
        b.keptPath = "Foto Google Drive/b.jpg"
        let senza = item(path: "/Volumes/SSD - Enri/Other/c.jpg")
        history.append(blockId: "b1", trashed: [a, b, senza])

        let decoded = try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(try linesOfFile(historyURL)[0].utf8))
        XCTAssertEqual(decoded.originalPaths, [a.originalDisplayPath, b.originalDisplayPath, senza.originalDisplayPath])
        XCTAssertEqual(decoded.keptPaths, ["Foto iPhone/a.jpg", "Foto Google Drive/b.jpg", ""])
    }

    /// Le righe gia' scritte prima di questo campo restano leggibili.
    func testOldLineWithoutKeptPaths_stillDecodes() throws {
        let vecchia = #"{"blockId":"b0","trashedAt":770000000,"originalPaths":["/x/a.jpg"]}"#
        let decoded = try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(vecchia.utf8))
        XCTAssertEqual(decoded.originalPaths, ["/x/a.jpg"])
        XCTAssertNil(decoded.keptPaths)
    }
```

In coda a `DuplicateTrasherTests`:

```swift
    // MARK: - Il percorso tenuto (ROADMAP #46, ADR-0017)

    /// Ogni voce del registro dice quale copia e' rimasta, sia nell'esito sia su disco.
    func testTrashedItems_recordTheKeptPath() throws {
        let (decision, _) = try healthyTrio()
        let outcome = makeTrasher().run([decision])

        XCTAssertEqual(outcome.trashedFiles.count, 2)
        XCTAssertEqual(outcome.trashedFiles.map(\.keptPath), ["Foto iPhone/a.jpg", "Foto iPhone/a.jpg"])
        XCTAssertEqual(manifest.lastBatch().map(\.keptPath), ["Foto iPhone/a.jpg", "Foto iPhone/a.jpg"])
    }

    /// La tenuta e' quella decisa (`Decision.keeper`), non il primo membro del gruppo: qui si
    /// tiene il TERZO, e un mutante che scrivesse `group.members[0]` direbbe il falso.
    func testKeptPath_isTheChosenKeeper_notTheFirstMember() throws {
        let (decision, entries) = try healthyTrio()
        let other = DuplicateTrasher.Decision(group: decision.group, keeper: entries[2])
        let outcome = makeTrasher().run([other])

        XCTAssertEqual(Set(outcome.trashedFiles.map(\.originalKey)), [entries[0].path, entries[1].path])
        XCTAssertEqual(Set(outcome.trashedFiles.compactMap(\.keptPath)), ["Import/c.jpg"])
    }
```

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh TrashManifestTests` → `COMPILAZIONE TEST FALLITA` con `value of type 'TrashedItem' has no member 'keptPath'`.

- [ ] **Step 3: implementa.** Sei sostituzioni.

**1. TrashedItem.keptPath.** Trova:

```swift
    var restoredAt: Date? = nil
}
```

Sostituisci con:

```swift
    var restoredAt: Date? = nil
    /// Il percorso della copia TENUTA del gruppo (ROADMAP #46, ADR-0017), relativo alla radice
    /// dell'SSD e scritto com'e' sul disco (`LibraryIndexEntry.displayPath` del tenuto): e' lo
    /// stesso percorso relativo che quella foto ha sull'HDD e la stessa chiave che ha su Cubbit,
    /// ed e' quello che il progetto 4 terra' su HDD e Cubbit. Relativo e non assoluto (come
    /// invece `originalDisplayPath`) apposta: la radice dell'SSD cambia nome se macOS lo monta
    /// come «SSD - Enri 1». `nil` nelle voci scritte prima di questo campo: «non si sa», mai
    /// un percorso inventato.
    var keptPath: String? = nil
}
```

**2. CodingKeys di TrashedItem.** Trova:

```swift
        case batchId, originalDisplayPath, originalKey, trashedPath, size, hash, trashedAt, restoredAt
```

Sostituisci con:

```swift
        case batchId, originalDisplayPath, originalKey, trashedPath, size, hash, trashedAt, restoredAt
        case keptPath
```

**3. decodifica di keptPath.** Trova:

```swift
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
```

Sostituisci con:

```swift
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
        // Campo accessorio (ROADMAP #46): le voci scritte prima non l'hanno, e restano valide.
        keptPath = try c.decodeIfPresent(String.self, forKey: .keptPath)
```

**4. TrashHistoryEntry.keptPaths.** Trova:

```swift
    /// Percorsi **assoluti**, come `TrashedItem.originalDisplayPath`: e' li' che la foto
    /// stava prima di finire nel Cestino.
    let originalPaths: [String]
}
```

Sostituisci con:

```swift
    /// Percorsi **assoluti**, come `TrashedItem.originalDisplayPath`: e' li' che la foto
    /// stava prima di finire nel Cestino.
    let originalPaths: [String]
    /// Per ogni voce di `originalPaths`, nello stesso ordine, il percorso della copia TENUTA
    /// del suo gruppo (`TrashedItem.keptPath`, relativo alla radice dell'SSD; stringa vuota se
    /// non si sa). Serve al progetto 4: il registro di ripristino ricorda solo le ultime
    /// `TrashManifestStore.maxItems` voci, questa storia le ricorda tutte. Opzionale: le righe
    /// scritte prima di questo campo non ce l'hanno (la decodifica sintetizzata di un
    /// opzionale usa `decodeIfPresent`).
    let keptPaths: [String]?
}
```

**5. TrashHistory.append scrive keptPaths.** Trova:

```swift
                                      originalPaths: trashed.map(\.originalDisplayPath))
```

Sostituisci con:

```swift
                                      originalPaths: trashed.map(\.originalDisplayPath),
                                      keptPaths: trashed.map { $0.keptPath ?? "" })
```

**6. DuplicateTrasher annota il tenuto.** Trova:

```swift
                                           hash: group.hash,
                                           trashedAt: Date())
```

Sostituisci con:

```swift
                                           hash: group.hash,
                                           trashedAt: Date(),
                                           keptPath: decision.keeper.displayPath)
```

- [ ] **Step 4: esegui i test.** `fasttest.sh TrashManifestTests` → `Executed 28 tests, with 0 failures`; `fasttest.sh TrashHistoryTests` → `Executed 9 tests, with 0 failures`; `fasttest.sh DuplicateTrasherTests` → `Executed 32 tests, with 0 failures`; `fasttest.sh TrashRestorerTests` → 0 fallimenti (invariato).
- [ ] **Step 5:** `fasttest.sh`: `Executed 1166 tests` (B+7), 0 fallimenti, 0 warning.
- [ ] **Step 6: revisione (checklist `trashItem` di `Docs/CLAUDE.md`).** Nessuna chiamata nuova a `trashItem`/`removeItem`/`moveItem`; la tenuta resta fuori da `trashItem` (`testKeeperIsNeverPassedToTrash` verde); la voce del registro è ancora scritta (`manifest.record`) prima del file successivo.
- [ ] **Mutanti che devono morire:** `keptPath: group.members[0].displayPath` al posto della tenuta decisa (muore `testKeptPath_isTheChosenKeeper_notTheFirstMember`, verificato); `keptPaths` in ordine inverso (muore `testKeptPaths_followTheOrderOfTheOriginals`, verificato); `decode` al posto di `decodeIfPresent` per `keptPath` (muore `testRecordWithoutKeptPath_stillDecodes`, verificato).
- [ ] **Step 7: commit.**
  ```
  Doppioni certificati, task 1: il registro annota il percorso tenuto

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 2: le regole pure — freschezza, certificazione per gruppo, ricontrollo

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione D (un solo inserimento).
- Create: `AppBackupFotoTests/DuplicateCertificationTests.swift` (`0AD7A73E4152051C79F6A0CB` / `D2A50B3C054F2C11D73854B5`), `AppBackupFotoTests/ArchiveWriteClockTests.swift` (`4FFCEC4262EDFEC724EC777B` / `8F1F1C0D7A29DB01536FF1DC`), registrati nel pbxproj nei 4 punti.
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda, prima della `}` finale).

**Interfaces:**
- Consumes: `JobHistoryStore.load(defaults:)`, `LibraryIndexStore.inventoryStates()`/`inventorySnapshot()`, `InventoryArchiveState` (`Equatable`), `InventorySnapshot`, `InventoryClassifier.classify`, `DuplicateGroup`, `DuplicateRunPlan`.
- Produces:
  - `enum ArchiveWriteClock { static let startedKey; static func markStarted(at:defaults:); static func lastWriteAt(defaults:) -> Date? }` — **non** `nonisolated` (legge `JobHistoryStore`, del MainActor).
  - `nonisolated enum DuplicateInventoryFreshness: Equatable, Sendable { neverRun, incomplete, unreadable, olderThanLastBackup(backupAt:startedAt:finishedAt:), fresh(runId:startedAt:finishedAt:); static func evaluate(states:lastArchiveWriteAt:) }`
  - `nonisolated enum DuplicateCertificationBlock: Equatable, Sendable` (sette casi, `init?(freshness:)`)
  - `nonisolated struct DuplicateCertificationBasis: Sendable { states; readFailed; safeHashes; ssdHashByKey; static let unreadable; static func isCompleteRun(_:); init(snapshot:); static func load(store:reusing:) }`
  - `nonisolated struct DuplicateCertification: Sendable { freshness; init(basis:lastArchiveWriteAt:groups:); static func groupBlock(_:basis:); func block(for:); func isSelectable(_:); var certifiedRunId; var inventoryFinishedAt; func uncoveredGroupCount(in:); static func runBlock(states:lastArchiveWriteAt:certifiedRunId:) }`

Tutti value type senza stato condiviso: `nonisolated` senza riga di sicurezza (regola di `.claude/rules/architecture.md`, «La regola per annotare `nonisolated`»). La lettura di tutto l'inventario sta in `load`, mai nel `body`: la finestra la chiama in un `Task.detached` (Task 5), e se gli stati non sono cambiati restituisce la base già calcolata senza leggere altro.

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/DuplicateCertificationTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Doppioni sull'SSD con la garanzia dell'inventario (ROADMAP #46, ADR-0017): quando un gruppo
/// si puo' spuntare. Ogni motivo di «non spuntabile» della spec ha qui almeno un test, e ogni
/// precedenza il suo.
///
/// Convenzione dei dati finti (la stessa di `InventoryClassifierTests`): il contenuto «X» ha
/// SHA256 "sha-X" e MD5 fatto di 32 volte la lettera X (a-f); l'oggetto Cubbit con ETag uguale
/// a quell'MD5 e' la stessa foto. L'hash di un gruppo di doppioni e' quindi "sha-X".
final class DuplicateCertificationTests: XCTestCase {

    // MARK: - Dati finti

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func file(_ path: String, _ content: Character, status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1, status: status,
                           digest: status == .ok
                               ? ContentDigest(size: 10, sha256: "sha-\(content)", md5: md5(content), multipartETag: nil)
                               : nil,
                           hashedAt: 2)
    }

    private func object(_ key: String, _ content: Character) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: 10, etag: "\"\(md5(content))\"")
    }

    private func state(_ a: InventoryArchive, complete: Bool = true, runId: Int64 = 7,
                       startedAt: Double = 1_000, finishedAt: Double? = 5_000) -> InventoryArchiveState {
        InventoryArchiveState(archive: a, runId: runId, complete: complete, reason: complete ? nil : .interrupted,
                              unreadable: 0, startedAt: startedAt, finishedAt: finishedAt)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true,
                        runId: Int64 = 7) -> [InventoryArchive: InventoryArchiveState] {
        [.ssd: state(.ssd, complete: ssd, runId: runId), .hdd: state(.hdd, complete: hdd, runId: runId),
         .s3: state(.s3, complete: s3, runId: runId)]
    }

    private func entry(_ path: String, _ content: Character) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1,
                          hash: "sha-\(content)", hashedAt: 2)
    }

    private func group(_ content: Character, _ paths: [String]) -> DuplicateGroup {
        DuplicateGroup(hash: "sha-\(content)", size: 10, members: paths.map { entry($0, content) })
    }

    /// La foto «a» in due copie sull'SSD, al sicuro su HDD e Cubbit: il caso spuntabile.
    private func safeSnapshot(states: [InventoryArchive: InventoryArchiveState]? = nil) -> InventorySnapshot {
        InventorySnapshot(ssd: [file("Foto iPhone/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                          hdd: [file("Foto iPhone/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                          s3: [object("Foto iPhone/a.jpg", "a")],
                          states: states ?? self.states())
    }

    private let safeGroup = DuplicateGroup(hash: "sha-a", size: 10, members: [
        LibraryIndexEntry(path: normalizedIndexKey("Foto iPhone/a.jpg"), displayPath: "Foto iPhone/a.jpg",
                          size: 10, mtime: 1, hash: "sha-a", hashedAt: 2),
        LibraryIndexEntry(path: normalizedIndexKey("Takeout/a.jpg"), displayPath: "Takeout/a.jpg",
                          size: 10, mtime: 1, hash: "sha-a", hashedAt: 2)])

    private func certify(_ snapshot: InventorySnapshot, _ groups: [DuplicateGroup], lastWrite: Date? = nil) -> DuplicateCertification {
        DuplicateCertification(basis: DuplicateCertificationBasis(snapshot: snapshot), lastArchiveWriteAt: lastWrite, groups: groups)
    }

    // MARK: - Freschezza

    func testNoInventory_isNeverRun() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: [:], lastArchiveWriteAt: nil), .neverRun)
    }

    func testCompleteAndNoBackupAfter_isFresh_withRunAndTimes() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: Date(timeIntervalSince1970: 999)),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: nil),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
    }

    /// Basta UN archivio letto a meta' (ADR-0015: incompleto non e' assente).
    func testAnyArchiveIncomplete_isIncomplete() {
        for s in [states(ssd: false), states(hdd: false), states(s3: false)] {
            XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
        }
    }

    func testAMissingArchive_isIncomplete() {
        var s = states()
        s[.s3] = nil
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
    }

    func testStatesOfDifferentRuns_areIncomplete() {
        var s = states()
        s[.hdd] = state(.hdd, runId: 8)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
    }

    /// Il backup e' finito DURANTE il giro (dopo l'inizio, prima della fine): l'inventario e' gia'
    /// vecchio. Un mutante che confrontasse con la fine del giro lo direbbe fresco. (verificato)
    func testBackupFinishedAfterTheStartOfTheRun_makesItOlder() {
        let backup = Date(timeIntervalSince1970: 4_000)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: backup),
                       .olderThanLastBackup(backupAt: backup, startedAt: 1_000, finishedAt: 5_000))
    }

    /// Il confronto e' stretto: un backup finito non dopo l'inizio (qui: nello stesso istante) non invecchia niente.
    func testBackupFinishedNotAfterTheStart_keepsItFresh() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: Date(timeIntervalSince1970: 1_000)),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
    }

    /// L'inizio del giro e' il PIU' VECCHIO dei tre (oggi coincidono, ma non e' imposto dal tipo).
    func testTheStartOfTheRun_isTheEarliestOfTheThree() {
        let s: [InventoryArchive: InventoryArchiveState] = [.ssd: state(.ssd, startedAt: 300),
                                                            .hdd: state(.hdd, startedAt: 100),
                                                            .s3: state(.s3, startedAt: 200)]
        let backup = Date(timeIntervalSince1970: 150)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: backup),
                       .olderThanLastBackup(backupAt: backup, startedAt: 100, finishedAt: 5_000))
    }

    func testIncomplete_winsOverOlderThanTheLastBackup() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(hdd: false),
                                                            lastArchiveWriteAt: Date(timeIntervalSince1970: 9_999)),
                       .incomplete)
    }

    // MARK: - Il gruppo

    func testSafeContent_withEveryCopyInTheSSDInventory_isSelectable() {
        let c = certify(safeSnapshot(), [safeGroup])
        XCTAssertNil(c.block(for: "sha-a"))
        XCTAssertTrue(c.isSelectable("sha-a"))
        XCTAssertEqual(c.certifiedRunId, 7)
        XCTAssertEqual(c.inventoryFinishedAt, Date(timeIntervalSince1970: 5_000))
    }

    func testContentMissingFromCubbit_isNotSafeOnAllThree() {
        var snap = safeSnapshot()
        snap.s3 = []
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// ❗ non e' ✅: stessa foto su tutti e tre, ma lo stesso percorso ha un altro contenuto su HDD.
    func testContentToBeChecked_isNotSafeOnAllThree() {
        var snap = safeSnapshot()
        snap.hdd[0] = file("Foto iPhone/a.jpg", "b")
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// Una terza copia comparsa dopo l'inventario (un ripristino, una copia dal Finder): non e'
    /// coperta, anche se il contenuto e' al sicuro.
    func testACopyNotInTheSSDInventory_isChangedAfterInventory() {
        let g = group("a", ["Foto iPhone/a.jpg", "Takeout/a.jpg", "Other/nuova.jpg"])
        XCTAssertEqual(certify(safeSnapshot(), [g]).block(for: "sha-a"), .changedAfterInventory)
    }

    /// Lo stesso percorso aveva un altro contenuto quando l'inventario l'ha letto.
    func testACopyWithAnotherContentInTheSSDInventory_isChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.ssd.append(file("Other/b.jpg", "b"))
        snap.hdd.append(file("Other/b.jpg", "b"))
        snap.s3.append(object("Other/b.jpg", "b"))
        let g = group("a", ["Foto iPhone/a.jpg", "Other/b.jpg"])
        XCTAssertEqual(certify(snap, [g]).block(for: "sha-a"), .changedAfterInventory)
    }

    func testACopyUnreadableInTheInventory_isChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.ssd[1] = file("Takeout/a.jpg", "a", status: .unreadable)
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .changedAfterInventory)
    }

    /// La regola vale anche per la copia che RESTA: qui manca dall'inventario solo il primo
    /// membro, che e' quello che `duplicateKeepChoice` terrebbe (Foto iPhone). (verificato)
    func testTheKeptCopyCountsToo() {
        var snap = safeSnapshot()
        snap.ssd.removeFirst()
        snap.ssd.append(file("Other/a.jpg", "a"))
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .changedAfterInventory)
    }

    func testNotSafe_winsOverChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.s3 = []
        let g = group("a", ["Foto iPhone/a.jpg", "Other/nuova.jpg"])
        XCTAssertEqual(certify(snap, [g]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// Con l'inventario vecchio OGNI gruppo ha il motivo comune, anche quello che sarebbe certificato.
    func testWhenTheInventoryIsOld_everyGroupHasTheCommonReason() {
        let backup = Date(timeIntervalSince1970: 2_000)
        let c = certify(safeSnapshot(), [safeGroup], lastWrite: backup)
        XCTAssertEqual(c.block(for: "sha-a"), .inventoryOlderThanLastBackup(backupAt: backup))
        XCTAssertFalse(c.isSelectable("sha-a"))
        XCTAssertNil(c.certifiedRunId)
        XCTAssertNil(c.inventoryFinishedAt)
    }

    func testWhenNeverRunOrIncomplete_everyGroupSaysSo() {
        XCTAssertEqual(certify(InventorySnapshot(), [safeGroup]).block(for: "sha-a"), .inventoryNeverRun)
        XCTAssertEqual(certify(safeSnapshot(states: states(s3: false)), [safeGroup]).block(for: "sha-a"),
                       .inventoryIncomplete)
    }

    func testUnreadableInventory_blocksEverything() {
        let c = DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: [safeGroup])
        XCTAssertEqual(c.freshness, .unreadable)
        XCTAssertEqual(c.block(for: "sha-a"), .inventoryUnreadable)
    }

    /// Un gruppo che non era fra quelli certificati non e' mai spuntabile, nemmeno con
    /// l'inventario fresco: la certificazione e' una lista di permessi, non di divieti. (verificato)
    func testAHashThatWasNotCertified_isNeverSelectable() {
        let c = certify(safeSnapshot(), [safeGroup])
        XCTAssertFalse(c.isSelectable("sha-z"))
        XCTAssertEqual(c.block(for: "sha-z"), .changedAfterInventory)
    }

    /// Da un giro incompleto non si ricava nessun contenuto «al sicuro», anche se la foto e' su
    /// tutti e tre: la base resta vuota. (verificato)
    func testAnIncompleteSnapshot_certifiesNoContent() {
        let basis = DuplicateCertificationBasis(snapshot: safeSnapshot(states: states(hdd: false)))
        XCTAssertTrue(basis.safeHashes.isEmpty)
        XCTAssertTrue(basis.ssdHashByKey.isEmpty)
        // Controllo: con il giro completo lo stesso gruppo e' certificato.
        XCTAssertNil(DuplicateCertification.groupBlock(safeGroup, basis: DuplicateCertificationBasis(snapshot: safeSnapshot())))
    }

    // MARK: - Il ricontrollo prima dello spostamento

    func testRunCheck_sameFreshRun_letsItGo() {
        XCTAssertNil(DuplicateCertification.runBlock(states: states(), lastArchiveWriteAt: nil, certifiedRunId: 7))
    }

    func testRunCheck_aNewerRun_stopsIt() {
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(runId: 8), lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryChangedSinceOpening)
    }

    func testRunCheck_aBackupAfterTheRun_stopsIt() {
        let backup = Date(timeIntervalSince1970: 6_000)
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(), lastArchiveWriteAt: backup, certifiedRunId: 7),
                       .inventoryOlderThanLastBackup(backupAt: backup))
    }

    func testRunCheck_incompleteOrUnreadable_stopsIt() {
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(s3: false), lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryIncomplete)
        XCTAssertEqual(DuplicateCertification.runBlock(states: nil, lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryUnreadable)
        XCTAssertEqual(DuplicateCertification.runBlock(states: [:], lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryNeverRun)
    }

    func testUncoveredGroupCount_countsTheGroupsTheCertificationDoesNotCover() {
        let other = group("b", ["Other/b1.jpg", "Other/b2.jpg"])
        let c = certify(safeSnapshot(), [safeGroup, other])
        let entries = [safeGroup, other].map { DuplicateBatch.Entry(group: $0, choice: duplicateKeepChoice($0, rule: nil)) }
        XCTAssertEqual(c.uncoveredGroupCount(in: DuplicateRunPlan(entries: entries)), 1)
        XCTAssertEqual(c.uncoveredGroupCount(in: DuplicateRunPlan(entries: [entries[0]])), 0)
    }

    // MARK: - Con il database vero

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateCertificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func storeWithACompleteRun(runId: Int64 = 7) throws -> LibraryIndexStore {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        let snap = safeSnapshot()
        try store.beginInventoryRun(runId: runId, startedAt: 1_000)
        try store.upsertInventoryLocal(snap.ssd, archive: .ssd, runId: runId)
        try store.upsertInventoryLocal(snap.hdd, archive: .hdd, runId: runId)
        try store.upsertInventoryS3(snap.s3, runId: runId)
        for a in InventoryArchive.allCases {
            try store.finishInventoryArchive(a, runId: runId, complete: true, reason: nil, unreadable: 0, finishedAt: 5_000)
        }
        return store
    }

    func testLoad_fromTheSavedInventory_certifiesTheSafeGroup() throws {
        let basis = DuplicateCertificationBasis.load(store: try storeWithACompleteRun(), reusing: nil)
        XCTAssertFalse(basis.readFailed)
        XCTAssertEqual(basis.safeHashes, ["sha-a"])
        XCTAssertEqual(basis.ssdHashByKey[normalizedIndexKey("Takeout/a.jpg")], "sha-a")
        XCTAssertTrue(DuplicateCertification(basis: basis, lastArchiveWriteAt: nil, groups: [safeGroup]).isSelectable("sha-a"))
    }

    func testLoad_withAnEmptyDatabase_isNeverRun() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        let c = DuplicateCertification(basis: .load(store: store, reusing: nil), lastArchiveWriteAt: nil, groups: [safeGroup])
        XCTAssertEqual(c.freshness, .neverRun)
    }

    /// Finche' gli stati dei tre archivi sono gli stessi, la base gia' calcolata si riusa (la
    /// classificazione di tutto l'inventario costa secondi); appena cambiano si ricalcola.
    func testLoad_reusesTheCachedBasisOnlyWhileTheStatesAreTheSame() throws {
        let store = try storeWithACompleteRun()
        let first = DuplicateCertificationBasis.load(store: store, reusing: nil)
        let fake = DuplicateCertificationBasis(snapshot: InventorySnapshot(
            ssd: [file("Z/z.jpg", "c")], hdd: [file("Z/z.jpg", "c")], s3: [object("Z/z.jpg", "c")], states: first.states))
        XCTAssertEqual(DuplicateCertificationBasis.load(store: store, reusing: fake).safeHashes, ["sha-c"],
                       "stati uguali: doveva riusare la base gia' calcolata")

        try store.beginInventoryRun(runId: 8, startedAt: 6_000)
        let after = DuplicateCertificationBasis.load(store: store, reusing: fake)
        XCTAssertTrue(after.safeHashes.isEmpty, "stati cambiati (giro nuovo in corso): doveva rileggere")
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: after.states, lastArchiveWriteAt: nil), .incomplete)
    }
}
```

Crea `AppBackupFotoTests/ArchiveWriteClockTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Quando un backup o un import ha scritto per l'ultima volta sugli archivi (ROADMAP #46,
/// ADR-0017): la piu' recente fra la fine dell'ultimo job (`JobHistoryStore`) e l'inizio
/// dell'ultimo job (`ArchiveWriteClock.startedKey`).
final class ArchiveWriteClockTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ArchiveWriteClockTests"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func saveJob(endedAt t: Double) {
        JobHistoryStore.save(JobSummary(date: Date(timeIntervalSince1970: t), label: "SSD -> HDD", copied: 1,
                                        skipped: 0, errors: 0, hashErrors: 0, succeeded: true), defaults: defaults)
    }

    func testNoJobEver_isNil() {
        XCTAssertNil(ArchiveWriteClock.lastWriteAt(defaults: defaults))
    }

    func testOnlyTheLastJobSummary_isItsEnd() {
        saveJob(endedAt: 2_000)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 2_000))
    }

    /// Il job partito e mai arrivato a salvare il suo riepilogo (app chiusa a forza a meta').
    func testOnlyTheStartMarker_isItsStart() {
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 3_000), defaults: defaults)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 3_000))
    }

    func testAJobStartedAfterTheLastSummary_wins() {
        saveJob(endedAt: 2_000)
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 3_000), defaults: defaults)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 3_000))
    }

    /// Il caso normale: il job e' partito e poi e' finito; conta la fine. (verificato: un mutante
    /// che leggesse solo l'inizio darebbe 1.000)
    func testTheEndOfTheSameJob_winsOverItsStart() {
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 1_000), defaults: defaults)
        saveJob(endedAt: 2_000)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 2_000))
    }
}
```

In coda a `MainThreadIsolationTests` (prima della `}` finale):

```swift
    // MARK: - Doppioni con la garanzia dell'inventario (ROADMAP #46)

    /// La lettura e la classificazione dell'inventario per i Doppioni costano secondi: devono
    /// girare fuori dal main come in `DuplicatesView.refreshCertification()`.
    func testDuplicateCertificationLoad_runsWithoutTheMainThread() throws {
        let store = try makeStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let basis = DuplicateCertificationBasis.load(store: store, reusing: nil)
            _ = DuplicateCertification(basis: basis, lastArchiveWriteAt: nil, groups: [])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "DuplicateCertificationBasis.load ha avuto bisogno del main thread: manca un nonisolated?")
    }
```

Registra i due file nuovi nel pbxproj (4 punti ciascuno, ID nella tabella in testa).

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh DuplicateCertificationTests` → `COMPILAZIONE TEST FALLITA` con `cannot find 'DuplicateInventoryFreshness' in scope` (e `ArchiveWriteClock`, `DuplicateCertificationBasis`).

- [ ] **Step 3: implementa.** Un inserimento.

**1. regole della certificazione.** Inserisci **subito prima** della riga `// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)` (unica nel file):

```swift
// MARK: - Doppioni sull'SSD con la garanzia dell'inventario (ROADMAP #46, ADR-0017)

/// Quando un backup o un import ha scritto per l'ultima volta su SSD, HDD o Cubbit: il
/// riferimento con cui si decide se l'inventario vale ancora per i Doppioni (decisione 1 di
/// Enrico: un inventario piu' vecchio dell'ultimo backup non certifica niente).
///
/// Contano SOLO i job che passano da `BackupRunner.run(label:...)`: Mac → SSD, SSD → HDD,
/// SSD → Cubbit e gli import, cioe' gli unici che scrivono sugli archivi. Non passano da li', e
/// quindi non contano, gli spostamenti nel Cestino, gli annullamenti, le riparazioni,
/// l'inventario e la lettura dell'elenco.
///
/// Due fonti, vale la piu' recente:
/// - la data dell'ultimo `JobSummary` (`JobHistoryStore`): la FINE dell'ultimo job, anche
///   interrotto o fallito (puo' aver scritto lo stesso);
/// - `startedKey`, scritta all'INIZIO di ogni job da `run(label:...)`: copre il job che non
///   arriva mai a salvare il suo `JobSummary` (l'app chiusa a forza a meta' copia).
/// Un job e un inventario non si sovrappongono mai (mutua esclusione nei due versi): per un job
/// arrivato in fondo, «iniziato dopo l'inizio del giro» e «finito dopo l'inizio del giro»
/// sono la stessa cosa.
///
/// NON `nonisolated`: legge `JobHistoryStore`, che vive sul MainActor. Si chiama dal main
/// (la finestra Doppioni, `run(label:)`, il ricontrollo della corsa via `MainActor.run`).
enum ArchiveWriteClock {
    static let startedKey = "lastArchiveWriteJobStartedAt"

    static func markStarted(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: startedKey)
    }

    /// `nil` = nessun job registrato.
    static func lastWriteAt(defaults: UserDefaults = .standard) -> Date? {
        let ended = JobHistoryStore.load(defaults: defaults)?.date
        let started = defaults.object(forKey: startedKey) as? Date
        return [ended, started].compactMap { $0 }.max()
    }
}

/// Se l'ultimo inventario vale per i Doppioni (spec, «Regole»: completo su tutti e tre gli
/// archivi, e nessun backup o import finito dopo l'inizio di quel giro). Vale per tutti i gruppi
/// insieme. Logica pura.
// `nonisolated`: value type puro, calcolato fuori dal main con il resto della certificazione.
nonisolated enum DuplicateInventoryFreshness: Equatable, Sendable {
    /// Nessun inventario salvato.
    case neverRun
    /// Un archivio non e' stato letto per intero, o i tre stati non sono dello stesso giro, o
    /// un giro e' ancora in corso (ADR-0015: incompleto non e' assente).
    case incomplete
    /// L'inventario salvato non si e' lasciato leggere.
    case unreadable
    /// Un backup o un import ha scritto dopo l'inizio del giro.
    case olderThanLastBackup(backupAt: Date, startedAt: Double, finishedAt: Double)
    case fresh(runId: Int64, startedAt: Double, finishedAt: Double)

    /// Precedenza: mai fatto > incompleto > piu' vecchio dell'ultimo backup.
    static func evaluate(states: [InventoryArchive: InventoryArchiveState],
                         lastArchiveWriteAt: Date?) -> DuplicateInventoryFreshness {
        guard !states.isEmpty else { return .neverRun }
        let all = InventoryArchive.allCases.compactMap { states[$0] }
        guard all.count == InventoryArchive.allCases.count,
              all.allSatisfy(\.complete),
              Set(all.map(\.runId)).count == 1 else { return .incomplete }
        // L'inizio piu' vecchio dei tre (oggi coincidono: `beginInventoryRun` li scrive insieme).
        let startedAt = all.map(\.startedAt).min() ?? 0
        let finishedAt = all.compactMap(\.finishedAt).max() ?? startedAt
        // Confronto con l'INIZIO del giro, non con la fine: un archivio letto prima del backup
        // non ha visto quello che il backup ha scritto.
        if let written = lastArchiveWriteAt, written.timeIntervalSince1970 > startedAt {
            return .olderThanLastBackup(backupAt: written, startedAt: startedAt, finishedAt: finishedAt)
        }
        return .fresh(runId: all[0].runId, startedAt: startedAt, finishedAt: finishedAt)
    }
}

/// Perche' un gruppo di doppioni non si puo' spuntare. Ogni caso ha la sua frase in
/// `DuplicatesStatus.certificationReason`.
// `nonisolated`: value type puro.
nonisolated enum DuplicateCertificationBlock: Equatable, Sendable {
    case inventoryNeverRun
    case inventoryIncomplete
    case inventoryUnreadable
    case inventoryOlderThanLastBackup(backupAt: Date)
    /// Il contenuto del gruppo non e' nella categoria ✅ «Al sicuro» dell'ultimo giro.
    case notSafeOnAllThree
    /// Una copia del gruppo (la tenuta o una che esce) non e' nell'inventario dell'SSD di quel
    /// giro con lo stesso contenuto: letta dopo, cambiata, o illeggibile allora.
    case changedAfterInventory
    /// Solo al ricontrollo prima dello spostamento: l'inventario e' stato rifatto dopo che la
    /// finestra aveva calcolato quali gruppi sono certificati.
    case inventoryChangedSinceOpening

    /// Il motivo che vale per tutti i gruppi, o `nil` se l'inventario e' fresco.
    init?(freshness: DuplicateInventoryFreshness) {
        switch freshness {
        case .neverRun: self = .inventoryNeverRun
        case .incomplete: self = .inventoryIncomplete
        case .unreadable: self = .inventoryUnreadable
        case .olderThanLastBackup(let backupAt, _, _): self = .inventoryOlderThanLastBackup(backupAt: backupAt)
        case .fresh: return nil
        }
    }
}

/// Quello che serve dall'ultimo inventario per certificare i gruppi, calcolato UNA volta fuori
/// dal main (la classificazione di tutto l'inventario costa secondi: mai nel `body`, mai a ogni
/// ridisegno). `BackupRunner` ne tiene l'ultima copia e la riusa finche' gli stati dei tre
/// archivi non cambiano (`load(store:reusing:)`).
// `nonisolated`: value type senza stato condiviso, costruito in un `Task.detached`.
nonisolated struct DuplicateCertificationBasis: Sendable {
    let states: [InventoryArchive: InventoryArchiveState]
    /// Vero se l'inventario salvato non si e' lasciato leggere.
    let readFailed: Bool
    /// I contenuti (SHA256) nella categoria ✅ dell'ultimo giro. Vuoto se il giro non e' completo.
    let safeHashes: Set<String>
    /// Chiave normalizzata → SHA256 dei file dell'SSD letti bene nell'ultimo giro. Vuoto se il
    /// giro non e' completo.
    let ssdHashByKey: [String: String]

    private init(states: [InventoryArchive: InventoryArchiveState], readFailed: Bool,
                 safeHashes: Set<String>, ssdHashByKey: [String: String]) {
        self.states = states
        self.readFailed = readFailed
        self.safeHashes = safeHashes
        self.ssdHashByKey = ssdHashByKey
    }

    static let unreadable = DuplicateCertificationBasis(states: [:], readFailed: true, safeHashes: [], ssdHashByKey: [:])

    /// Tre archivi, tutti completi, dello stesso giro.
    static func isCompleteRun(_ states: [InventoryArchive: InventoryArchiveState]) -> Bool {
        let all = InventoryArchive.allCases.compactMap { states[$0] }
        return all.count == InventoryArchive.allCases.count && all.allSatisfy(\.complete)
            && Set(all.map(\.runId)).count == 1
    }

    /// Dalla fotografia dell'inventario. La categoria ✅ e' quella di `InventoryClassifier`, la
    /// stessa che mostra la finestra Inventario: una regola sola, mai una seconda.
    init(snapshot: InventorySnapshot) {
        self.states = snapshot.states
        self.readFailed = false
        guard Self.isCompleteRun(snapshot.states) else {
            self.safeHashes = []
            self.ssdHashByKey = [:]
            return
        }
        let (items, _) = InventoryClassifier.classify(snapshot)
        self.safeHashes = Set(items.lazy.filter { $0.category == .safe }.map(\.id))
        var byKey: [String: String] = [:]
        byKey.reserveCapacity(snapshot.ssd.count)
        for file in snapshot.ssd where file.status == .ok {
            guard let digest = file.digest else { continue }
            byKey[file.key] = digest.sha256
        }
        self.ssdHashByKey = byKey
    }

    /// Legge l'inventario salvato. Gli stati per primi (una query piccola): se sono gli stessi
    /// di `cached`, si riusa quella; se il giro non e' completo non si legge altro (non
    /// certificherebbe niente). Non lancia: un errore di lettura e' `.unreadable`, che blocca
    /// tutto.
    static func load(store: LibraryIndexStore, reusing cached: DuplicateCertificationBasis?) -> DuplicateCertificationBasis {
        guard let states = try? store.inventoryStates() else { return .unreadable }
        if let cached, !cached.readFailed, cached.states == states { return cached }
        guard isCompleteRun(states) else {
            return DuplicateCertificationBasis(states: states, readFailed: false, safeHashes: [], ssdHashByKey: [:])
        }
        guard let snapshot = try? store.inventorySnapshot() else { return .unreadable }
        return DuplicateCertificationBasis(snapshot: snapshot)
    }
}

/// Quali gruppi di doppioni si possono spuntare (spec, «Regole»), calcolato una volta fuori dal
/// main per tutti i gruppi caricati e letto dalla finestra in O(1) per riga. Un gruppo e'
/// spuntabile solo se l'inventario e' fresco, il suo contenuto e' ✅ e TUTTE le sue copie
/// (la tenuta e quelle che escono) sono nell'inventario dell'SSD di quel giro con lo stesso
/// contenuto. Un hash che non era fra i gruppi certificati non e' mai spuntabile.
///
/// Non sostituisce niente di ADR-0005: allo spostamento ogni copia si rilegge e si rihasha
/// comunque dal disco. Questa e' una condizione IN PIU'.
// `nonisolated`: value type puro, costruito in un `Task.detached` e passato al runner.
nonisolated struct DuplicateCertification: Sendable {
    let freshness: DuplicateInventoryFreshness
    private let certifiedHashes: Set<String>
    private let blockedByHash: [String: DuplicateCertificationBlock]

    init(basis: DuplicateCertificationBasis, lastArchiveWriteAt: Date?, groups: [DuplicateGroup]) {
        let freshness = basis.readFailed
            ? .unreadable
            : DuplicateInventoryFreshness.evaluate(states: basis.states, lastArchiveWriteAt: lastArchiveWriteAt)
        self.freshness = freshness
        guard case .fresh = freshness else {
            self.certifiedHashes = []
            self.blockedByHash = [:]
            return
        }
        var certified = Set<String>()
        var blocked: [String: DuplicateCertificationBlock] = [:]
        for group in groups {
            if let block = Self.groupBlock(group, basis: basis) {
                blocked[group.hash] = block
            } else {
                certified.insert(group.hash)
            }
        }
        self.certifiedHashes = certified
        self.blockedByHash = blocked
    }

    /// La regola per un gruppo, con l'inventario gia' fresco. Precedenza della spec: foto non
    /// al sicuro su tutti e tre > copia cambiata dopo l'inventario.
    static func groupBlock(_ group: DuplicateGroup, basis: DuplicateCertificationBasis) -> DuplicateCertificationBlock? {
        guard basis.safeHashes.contains(group.hash) else { return .notSafeOnAllThree }
        // OGNI membro, la copia tenuta compresa: la regola della spec vale per entrambe.
        for member in group.members where basis.ssdHashByKey[member.path] != group.hash {
            return .changedAfterInventory
        }
        return nil
    }

    /// Il motivo per cui il gruppo non si puo' spuntare, `nil` se si puo'.
    func block(for hash: String) -> DuplicateCertificationBlock? {
        if let global = DuplicateCertificationBlock(freshness: freshness) { return global }
        if certifiedHashes.contains(hash) { return nil }
        return blockedByHash[hash] ?? .changedAfterInventory
    }

    func isSelectable(_ hash: String) -> Bool { block(for: hash) == nil }

    /// Il giro che ha certificato i gruppi: il ricontrollo prima dello spostamento pretende lo stesso.
    var certifiedRunId: Int64? {
        if case .fresh(let runId, _, _) = freshness { return runId }
        return nil
    }

    /// Quando e' finito il giro che certifica, per il riepilogo.
    var inventoryFinishedAt: Date? {
        if case .fresh(_, _, let finishedAt) = freshness { return Date(timeIntervalSince1970: finishedAt) }
        return nil
    }

    /// Quanti gruppi della corsa questa certificazione NON copre (deve essere 0 per partire).
    func uncoveredGroupCount(in plan: DuplicateRunPlan) -> Int {
        plan.blocks.reduce(0) { total, block in total + block.filter { !isSelectable($0.group.hash) }.count }
    }

    /// Il ricontrollo subito prima di ogni blocco di uno spostamento (spec: «il controllo di
    /// freschezza si rifa'»). `states == nil` = l'inventario non si e' lasciato leggere.
    static func runBlock(states: [InventoryArchive: InventoryArchiveState]?, lastArchiveWriteAt: Date?,
                         certifiedRunId: Int64) -> DuplicateCertificationBlock? {
        guard let states else { return .inventoryUnreadable }
        let freshness = DuplicateInventoryFreshness.evaluate(states: states, lastArchiveWriteAt: lastArchiveWriteAt)
        if let block = DuplicateCertificationBlock(freshness: freshness) { return block }
        if case .fresh(let runId, _, _) = freshness, runId != certifiedRunId { return .inventoryChangedSinceOpening }
        return nil
    }
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh DuplicateCertificationTests` → `Executed 30 tests, with 0 failures`; `fasttest.sh ArchiveWriteClockTests` → `Executed 5 tests, with 0 failures`; `fasttest.sh MainThreadIsolationTests` → `Executed 22 tests, with 0 failures`.
- [ ] **Step 5:** `fasttest.sh`: `Executed 1202 tests` (B+43), 0 fallimenti, 0 warning.
- [ ] **Mutanti che devono morire** (tutti verificati sul prototipo): confronto con la **fine** del giro invece che con l'inizio (muore `testBackupFinishedAfterTheStartOfTheRun_makesItOlder`); `max` al posto di `min` per l'inizio (muore `testTheStartOfTheRun_isTheEarliestOfTheThree`); solo l'SSD deve essere completo (muoiono i test sugli archivi incompleti); la regola 4 che salta il primo membro (muore `testTheKeptCopyCountsToo`); un hash sconosciuto spuntabile (muore `testAHashThatWasNotCertified_isNeverSelectable`); classificazione anche di un giro incompleto (muore `testAnIncompleteSnapshot_certifiesNoContent`); precedenza invertita fra «non al sicuro» e «copia cambiata» (muore `testNotSafe_winsOverChangedAfterInventory`); base riusata anche con stati diversi (muore `testLoad_reusesTheCachedBasisOnlyWhileTheStatesAreTheSame`); ricontrollo che ignora un giro nuovo (muore `testRunCheck_aNewerRun_stopsIt`); `uncoveredGroupCount` sempre 0 (muore `testUncoveredGroupCount_…`); l'orologio che legge solo l'inizio del job (muore `testTheEndOfTheSameJob_winsOverItsStart`).
- [ ] **Step 6: commit.**
  ```
  Doppioni certificati, task 2: freschezza dell'inventario e certificazione per gruppo

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 3: i testi della garanzia, e il motivo di stop nuovo della corsa

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione D (dopo il blocco del Task 2), `DuplicateRunStopReason`, `DuplicatesStatus.runOutcomeLines`.
- Create: `AppBackupFotoTests/DuplicateCertificationStatusTests.swift` (`15EF2A3B9C10CF5411E285B2` / `DBA7082C2B0608C672FE5540`), registrato nel pbxproj nei 4 punti.

**Interfaces:**
- Consumes: `DuplicateCertificationBlock`, `DuplicateInventoryFreshness` (Task 2), `DuplicatesStatus.Line`/`Tone`/`count` (esistenti; `count` è `private` ma visibile da un'`extension` nello stesso file).
- Produces (tutte in `extension DuplicatesStatus`, sul MainActor come il resto di `DuplicatesStatus`):
  - `static func dayAndTime(_:calendar:) -> String` — «5 ottobre 2026 alle 14:07», mesi scritti a mano (niente `DateFormatter`: stessa frase su ogni Mac)
  - `static func approxDuration(seconds:) -> String`
  - `static func certificationReason(_:calendar:) -> String`, `static func blockedRowLine(_:calendar:) -> String`, `static let certificationPendingRowLine`
  - `static func certificationLine(_ freshness: DuplicateInventoryFreshness?, calendar:) -> Line` (id `cert-loading`/`cert-fresh`/`cert-never`/`cert-incomplete`/`cert-unreadable`/`cert-older`)
  - `static func bulkSkipLine(blockedVisible:visible:) -> String?`, `static func ruleBlockedLine(blockedCovered:) -> String?`
  - `static func certifiedSummaryLine(inventoryFinishedAt:calendar:) -> String`, `static let notCertifiedRunMessage`
  - `DuplicateRunStopReason.inventoryNoLongerValid(DuplicateCertificationBlock)` e la riga `run-inventory-invalid` di `runOutcomeLines`

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/DuplicateCertificationStatusTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// I testi della garanzia dell'inventario nel pannello Doppioni (ROADMAP #46, ADR-0017): una
/// frase propria per ogni motivo, italiano semplice, nessun gergo.
final class DuplicateCertificationStatusTests: XCTestCase {

    /// Un calendario fisso: la frase non deve dipendere dal fuso del Mac che esegue i test.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-05 14:07:00 UTC
    private let ottobre = Date(timeIntervalSince1970: 1_791_209_220)

    private let jargon = ["hash", "indice", "sha", "scansione", "etag", "md5", "bucket", "cache"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in jargon {
            XCTAssertFalse(text.lowercased().contains(word), "gergo «\(word)» in: \(text)", file: file, line: line)
        }
    }

    private let allBlocks: [DuplicateCertificationBlock] = [
        .inventoryNeverRun, .inventoryIncomplete, .inventoryUnreadable,
        .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_791_209_220)),
        .notSafeOnAllThree, .changedAfterInventory, .inventoryChangedSinceOpening]

    // MARK: - Date e durate

    func testDayAndTime_isWrittenInItalian() {
        XCTAssertEqual(DuplicatesStatus.dayAndTime(ottobre, calendar: utc), "5 ottobre 2026 alle 14:07")
    }

    func testDayAndTime_padsTheMinutes() {
        XCTAssertEqual(DuplicatesStatus.dayAndTime(Date(timeIntervalSince1970: 1_767_258_300), calendar: utc),
                       "1 gennaio 2026 alle 9:05")
    }

    func testApproxDuration() {
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 30), "meno di un minuto")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 60), "circa 1 minuto")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 1_190), "circa 20 minuti")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 3_590), "circa 1 ora")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 4_500), "circa 1 ora e 15 minuti")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 7_260), "circa 2 ore e 1 minuto")
    }

    // MARK: - I motivi

    func testEveryReason_hasItsOwnSentence_withoutJargon() {
        let sentences = allBlocks.map { DuplicatesStatus.certificationReason($0, calendar: utc) }
        XCTAssertEqual(Set(sentences).count, allBlocks.count, "due motivi non devono dire la stessa cosa")
        for s in sentences {
            XCTAssertFalse(s.isEmpty)
            assertNoJargon(s)
        }
    }

    func testOlderReason_saysWhenTheBackupWas() {
        let s = DuplicatesStatus.certificationReason(.inventoryOlderThanLastBackup(backupAt: ottobre), calendar: utc)
        XCTAssertTrue(s.contains("5 ottobre 2026 alle 14:07"), s)
    }

    func testRowLine_saysItCannotBeTicked_andWhy() {
        XCTAssertEqual(DuplicatesStatus.blockedRowLine(.notSafeOnAllThree, calendar: utc),
                       "Non si può spuntare: secondo l'inventario questa foto non è al sicuro su SSD, HDD e Cubbit insieme.")
    }

    // MARK: - La riga in testa

    func testHeaderLine_fresh_isOk_andNamesHDDAndCubbit() {
        let line = DuplicatesStatus.certificationLine(.fresh(runId: 7, startedAt: 1_791_200_000,
                                                             finishedAt: 1_791_209_220), calendar: utc)
        XCTAssertEqual(line.id, "cert-fresh")
        XCTAssertEqual(line.tone, .ok)
        XCTAssertTrue(line.text.contains("5 ottobre 2026 alle 14:07"), line.text)
        XCTAssertTrue(line.text.contains("HDD") && line.text.contains("Cubbit"), line.text)
        assertNoJargon(line.text)
    }

    /// Lo scostamento della spec: non «ci vogliono pochi minuti» (falso: il secondo giro misurato
    /// il 2026-10-01 e' durato 75 minuti), ma quanto e' durato davvero l'ultimo aggiornamento.
    func testHeaderLine_older_asksToUpdate_andSaysHowLongItTookLastTime() {
        let line = DuplicatesStatus.certificationLine(.olderThanLastBackup(backupAt: ottobre, startedAt: 0, finishedAt: 4_500),
                                                      calendar: utc)
        XCTAssertEqual(line.id, "cert-older")
        XCTAssertEqual(line.tone, .warning)
        XCTAssertTrue(line.text.contains("aggiornalo"), line.text)
        XCTAssertTrue(line.text.contains("5 ottobre 2026 alle 14:07"), line.text)
        XCTAssertTrue(line.text.contains("circa 1 ora e 15 minuti"), line.text)
        XCTAssertFalse(line.text.contains("pochi minuti"), line.text)
    }

    func testHeaderLine_theOtherCases_areWarnings_withTheirOwnIds() {
        let lines = [DuplicateInventoryFreshness.neverRun, .incomplete, .unreadable]
            .map { DuplicatesStatus.certificationLine($0, calendar: utc) }
        XCTAssertEqual(lines.map(\.id), ["cert-never", "cert-incomplete", "cert-unreadable"])
        XCTAssertTrue(lines.allSatisfy { $0.tone == .warning })
        lines.forEach { assertNoJargon($0.text) }
    }

    func testHeaderLine_beforeTheCheck_saysItIsChecking() {
        let line = DuplicatesStatus.certificationLine(nil, calendar: utc)
        XCTAssertEqual(line.id, "cert-loading")
        XCTAssertEqual(line.tone, .info)
    }

    // MARK: - Selezione in massa e regola per cartella

    func testBulkSkipLine_isNilWhenNothingIsSkipped() {
        XCTAssertNil(DuplicatesStatus.bulkSkipLine(blockedVisible: 0, visible: 40))
    }

    func testBulkSkipLine_countsTheSkippedGroups() {
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 1, visible: 40),
                       "«Seleziona tutti quelli visibili» salta 1 gruppo che non si può ancora spostare: il motivo è scritto sotto ciascuno.")
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 1_234, visible: 5_000),
                       "«Seleziona tutti quelli visibili» salta \(1_234.formatted()) gruppi che non si possono ancora spostare: il motivo è scritto sotto ciascuno.")
    }

    func testBulkSkipLine_whenEveryVisibleGroupIsBlocked() {
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 40, visible: 40),
                       "Nessuno dei gruppi visibili si può spuntare adesso: il motivo è scritto sotto ciascuno.")
    }

    func testRuleBlockedLine() {
        XCTAssertNil(DuplicatesStatus.ruleBlockedLine(blockedCovered: 0))
        XCTAssertEqual(DuplicatesStatus.ruleBlockedLine(blockedCovered: 1),
                       "Di questi, 1 gruppo non si può ancora spostare: la selezione lo salta.")
        XCTAssertEqual(DuplicatesStatus.ruleBlockedLine(blockedCovered: 3),
                       "Di questi, 3 gruppi non si possono ancora spostare: la selezione li salta.")
    }

    // MARK: - Riepilogo ed esito

    func testSummaryLine_namesTheInventory_andTheLastCheck() {
        let s = DuplicatesStatus.certifiedSummaryLine(inventoryFinishedAt: ottobre, calendar: utc)
        XCTAssertTrue(s.contains("5 ottobre 2026 alle 14:07"), s)
        XCTAssertTrue(s.contains("ricontrolla"), s)
        assertNoJargon(s)
    }

    /// La corsa fermata dal ricontrollo prima del primo blocco: lo dice, col motivo, e dice che
    /// non e' stato completato niente.
    func testRunOutcome_stoppedBecauseTheInventoryIsNoLongerValid() {
        var outcome = DuplicateRunOutcome(totalBlocks: 3)
        outcome.stopReason = .inventoryNoLongerValid(.inventoryChangedSinceOpening)
        let lines = DuplicatesStatus.runOutcomeLines(outcome)
        XCTAssertEqual(lines.first?.id, "run-inventory-invalid")
        XCTAssertEqual(lines.first?.tone, .warning)
        XCTAssertEqual(lines.first?.text,
                       "Mi sono fermato prima di spostare altro: l'inventario è stato aggiornato dopo che hai aperto "
                       + "questo elenco. 0 blocchi sono stati completati su 3 previsti.")
    }

    func testNotCertifiedRunMessage_hasNoJargon() {
        assertNoJargon(DuplicatesStatus.notCertifiedRunMessage)
    }
}
```

Registra il file nel pbxproj (4 punti).

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh DuplicateCertificationStatusTests` → `COMPILAZIONE TEST FALLITA` con `type 'DuplicatesStatus' has no member 'dayAndTime'`.

- [ ] **Step 3: implementa.** Tre sostituzioni.

**1. testi della garanzia.** Inserisci **subito prima** della riga `// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)` (unica nel file):

```swift
// MARK: - Testi della garanzia dell'inventario nel pannello Doppioni (ROADMAP #46, ADR-0017)

/// Tutte le frasi nuove del pannello Doppioni sulla garanzia dell'inventario. Stessa disciplina
/// di `DuplicatesStatus`: logica pura, italiano semplice, niente gergo («hash», «indice»,
/// «SHA256», «scansione», «ETag»).
extension DuplicatesStatus {
    /// «5 ottobre 2026 alle 14:07». Scritta a mano, con i nomi dei mesi fissi, e non con un
    /// `DateFormatter`: la frase deve essere la stessa su ogni Mac e verificabile da un test.
    static func dayAndTime(_ date: Date, calendar: Calendar = .current) -> String {
        let months = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio",
                      "agosto", "settembre", "ottobre", "novembre", "dicembre"]
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(c.day ?? 0) \(month) \(c.year ?? 0) alle \(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
    }

    /// Una durata a parole, arrotondata al minuto: «circa 1 ora e 15 minuti».
    static func approxDuration(seconds: Double) -> String {
        guard seconds >= 60 else { return "meno di un minuto" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "circa \(count(minutes, "minuto", "minuti"))" }
        let hours = minutes / 60, rest = minutes % 60
        let hoursText = count(hours, "ora", "ore")
        return rest == 0 ? "circa \(hoursText)" : "circa \(hoursText) e \(count(rest, "minuto", "minuti"))"
    }

    /// Il motivo, come pezzo di frase (minuscola, senza punto): lo usano la riga del gruppo e
    /// l'esito di una corsa fermata.
    static func certificationReason(_ block: DuplicateCertificationBlock, calendar: Calendar = .current) -> String {
        switch block {
        case .inventoryNeverRun:
            return "l'inventario di SSD, HDD e Cubbit non è mai stato fatto"
        case .inventoryIncomplete:
            return "l'ultimo inventario non è completo"
        case .inventoryUnreadable:
            return "l'app non è riuscita a leggere l'inventario salvato"
        case .inventoryOlderThanLastBackup(let backupAt):
            return "l'inventario è più vecchio dell'ultimo backup (\(dayAndTime(backupAt, calendar: calendar)))"
        case .notSafeOnAllThree:
            return "secondo l'inventario questa foto non è al sicuro su SSD, HDD e Cubbit insieme"
        case .changedAfterInventory:
            return "una delle sue copie è cambiata, o è comparsa, dopo l'ultimo inventario"
        case .inventoryChangedSinceOpening:
            return "l'inventario è stato aggiornato dopo che hai aperto questo elenco"
        }
    }

    /// La riga sotto un gruppo che non si puo' spuntare (spec: «visibili ma non spuntabili, con
    /// una riga che dice perché»).
    static func blockedRowLine(_ block: DuplicateCertificationBlock, calendar: Calendar = .current) -> String {
        "Non si può spuntare: \(certificationReason(block, calendar: calendar))."
    }

    /// La riga sotto i gruppi finche' la certificazione non e' pronta (la casella resta spenta).
    static let certificationPendingRowLine = "Sto controllando l'inventario…"

    /// La riga in testa al pannello: vale per tutti i gruppi. `nil` = non ancora calcolata.
    static func certificationLine(_ freshness: DuplicateInventoryFreshness?, calendar: Calendar = .current) -> Line {
        guard let freshness else {
            return Line(id: "cert-loading", tone: .info, text: "Sto controllando l'inventario di SSD, HDD e Cubbit…")
        }
        switch freshness {
        case .fresh(_, _, let finishedAt):
            return Line(id: "cert-fresh", tone: .ok, text:
                "Inventario completo del \(dayAndTime(Date(timeIntervalSince1970: finishedAt), calendar: calendar)), "
                + "più recente dell'ultimo backup: puoi spostare nel Cestino solo le copie di foto che "
                + "risultano al sicuro anche sull'HDD e su Cubbit.")
        case .neverRun:
            return Line(id: "cert-never", tone: .warning, text:
                "Non c'è ancora un inventario di SSD, HDD e Cubbit: finché non ce n'è uno completo, "
                + "nessuna copia si può spostare. Apri l'inventario e premi «Aggiorna l'inventario».")
        case .incomplete:
            return Line(id: "cert-incomplete", tone: .warning, text:
                "L'ultimo inventario non è completo (o è ancora in corso): finché non ne finisce uno "
                + "completo, nessuna copia si può spostare.")
        case .unreadable:
            return Line(id: "cert-unreadable", tone: .warning, text:
                "L'app non è riuscita a leggere l'inventario salvato, quindi nessuna copia si può "
                + "spostare. Riapri questa finestra; se succede ancora, aggiorna l'inventario.")
        case .olderThanLastBackup(let backupAt, let startedAt, let finishedAt):
            return Line(id: "cert-older", tone: .warning, text:
                "L'inventario è più vecchio dell'ultimo backup (\(dayAndTime(backupAt, calendar: calendar))): "
                + "aggiornalo, poi torna qui. L'ultimo aggiornamento è durato "
                + "\(approxDuration(seconds: finishedAt - startedAt)).")
        }
    }

    /// Sotto «Seleziona tutti quelli visibili»: quanti gruppi visibili la selezione in massa
    /// salta (spec: «lo dicono nel conteggio»). `nil` se non ne salta nessuno.
    static func bulkSkipLine(blockedVisible: Int, visible: Int) -> String? {
        guard blockedVisible > 0 else { return nil }
        guard blockedVisible < visible else {
            return "Nessuno dei gruppi visibili si può spuntare adesso: il motivo è scritto sotto ciascuno."
        }
        return "«Seleziona tutti quelli visibili» salta \(count(blockedVisible, "gruppo", "gruppi")) che non si "
            + "\(blockedVisible == 1 ? "può" : "possono") ancora spostare: il motivo è scritto sotto ciascuno."
    }

    /// Sotto la copertura della regola per cartella: quanti dei gruppi coperti non si possono
    /// ancora spostare. `nil` se nessuno.
    static func ruleBlockedLine(blockedCovered: Int) -> String? {
        guard blockedCovered > 0 else { return nil }
        return "Di questi, \(count(blockedCovered, "gruppo", "gruppi")) non si "
            + "\(blockedCovered == 1 ? "può" : "possono") ancora spostare: la selezione "
            + "\(blockedCovered == 1 ? "lo" : "li") salta."
    }

    /// Nel riepilogo, prima della conferma: su quale inventario poggia la garanzia.
    static func certifiedSummaryLine(inventoryFinishedAt: Date, calendar: Calendar = .current) -> String {
        "Ogni foto di questo riepilogo risulta al sicuro anche sull'HDD e su Cubbit nell'inventario del "
            + "\(dayAndTime(inventoryFinishedAt, calendar: calendar)). Subito prima di spostare, l'app "
            + "ricontrolla che l'inventario valga ancora."
    }

    /// L'avviso se il runner riceve una corsa con un gruppo che la certificazione non copre
    /// (non dovrebbe succedere: la finestra non lo lascia spuntare).
    static let notCertifiedRunMessage =
        "Alcuni gruppi scelti non risultano al sicuro su SSD, HDD e Cubbit secondo l'inventario, "
        + "quindi non ho spostato niente. Chiudi e riapri la finestra Doppioni e scegli di nuovo."
}
```

**2. motivo di stop nuovo.** Trova:

```swift
    case trashFailed(displayPath: String, detail: String)
    case interrupted
}
```

Sostituisci con:

```swift
    case trashFailed(displayPath: String, detail: String)
    case interrupted
    /// Il ricontrollo prima di un blocco (ROADMAP #46, ADR-0017) ha trovato che l'inventario non
    /// vale piu': la corsa si ferma prima di spostare altro.
    case inventoryNoLongerValid(DuplicateCertificationBlock)
}
```

**3. esito della corsa fermata dal ricontrollo.** Inserisci **subito prima** della riga `case .interrupted:` (unica nel file):

```swift
        case .inventoryNoLongerValid(let block):
            out.append(Line(id: "run-inventory-invalid", tone: .warning, text:
                "Mi sono fermato prima di spostare altro: \(certificationReason(block)). "
                + "\(count(outcome.blocksCompleted, "blocco è stato completato", "blocchi sono stati completati")) "
                + "su \(count(outcome.totalBlocks, "previsto", "previsti"))."))
```

- [ ] **Step 4: esegui i test.** `fasttest.sh DuplicateCertificationStatusTests` → `Executed 17 tests, with 0 failures`; `fasttest.sh DuplicatesStatusTests` → `Executed 57 tests, with 0 failures` (invariato: le altre righe di `runOutcomeLines` non cambiano).
- [ ] **Step 5:** `fasttest.sh`: `Executed 1219 tests` (B+60), 0 fallimenti, 0 warning. **Punto di controllo `xcodebuild`** (in background): build pulita 0 warning, `Executed 1219 tests` — è il primo punto in cui i tre file nuovi devono risultare registrati nel pbxproj (se il conteggio è più basso, manca una delle 4 righe di un file).
- [ ] **Mutanti che devono morire:** la riga «più vecchio» col testo della spec «aggiornalo, ci vogliono pochi minuti» (muore `testHeaderLine_older_asksToUpdate_andSaysHowLongItTookLastTime`, verificato); due motivi con la stessa frase (muore `testEveryReason_hasItsOwnSentence_withoutJargon`); `bulkSkipLine` che non distingue «tutti» da «alcuni» (muore `testBulkSkipLine_whenEveryVisibleGroupIsBlocked`).
- [ ] **Step 6: commit.**
  ```
  Doppioni certificati, task 3: i testi della garanzia dell'inventario

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 4: cablaggio in `BackupRunner` — l'orologio dei job, la base in memoria, il ricontrollo prima di ogni blocco

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `BackupRunner.run(label:...)`, `BackupRunner.endDuplicateTrashing()` (dopo), `BackupRunner.startDuplicateTrashRun`, e la sola chiamata in `DuplicatesView.startTrashing(_:)`.

**Interfaces:**
- Consumes: `ArchiveWriteClock`, `DuplicateCertification`, `DuplicateCertificationBasis`, `DuplicatesStatus.notCertifiedRunMessage`, `DuplicateRunStopReason.inventoryNoLongerValid` (Task 2-3).
- Produces:
  - `BackupRunner.startDuplicateTrashRun(_ plan: DuplicateRunPlan, certification: DuplicateCertification, onAlert:)` — **firma cambiata** (unico chiamante: `DuplicatesView.startTrashing`)
  - `BackupRunner.duplicateCertificationBasisCache: DuplicateCertificationBasis?` (`private(set)`, **non** `@Published`) e `rememberDuplicateCertificationBasis(_:)`
  - `ArchiveWriteClock.markStarted()` in `run(label:...)`, dopo il cancello `JobStartGate` e prima di qualunque scrittura

**Cosa succede adesso in una corsa**, in ordine: (1) `trashDisabledReason` come oggi; (2) **nuovo** — la certificazione deve avere un giro (`certifiedRunId`) e coprire ogni gruppo della corsa, altrimenti avviso e niente parte; (3) store, registro, storia, radice come oggi; (4) `beginDuplicateTrashing()`; (5) nel `Task.detached`, prima di **ogni** blocco: interruzione, poi in un solo `MainActor.run` l'SSD collegato **e** `ArchiveWriteClock.lastWriteAt()`, poi **nuovo** — `DuplicateCertification.runBlock(states: try? store.inventoryStates(), …)` fuori dal main; se dice no, `stopReason = .inventoryNoLongerValid(motivo)` e la corsa si ferma prima di quel blocco. `DuplicateTrasher.run` e il resto del ciclo non cambiano.

**Nota sul commit intermedio:** la sostituzione 5 fa compilare la finestra passando una certificazione vuota (`.unreadable`): fra questo commit e il Task 5 **ogni** corsa viene rifiutata col messaggio `notCertifiedRunMessage`. È il verso sicuro, voluto: nessuno spostamento può partire senza la garanzia, nemmeno a metà piano.

- [ ] **Step 1: implementa.** Cinque sostituzioni.

**1. run(label:) segna l'inizio di un job che scrive.** Inserisci **subito prima** della riga `output = ""; stats = JobStats(); currentStatus = ""; currentThumbnail = nil` (unica nel file):

```swift
        // Da qui il job puo' scrivere su SSD, HDD o Cubbit: l'inventario non vale piu' per i
        // Doppioni (ROADMAP #46, ADR-0017). Prima di qualunque scrittura, cosi' anche un job che
        // non arriva mai a salvare il suo `JobSummary` (app chiusa a forza) lascia la traccia.
        ArchiveWriteClock.markStarted()
```

**2. la base della certificazione in memoria.** Trova:

```swift
    func endDuplicateTrashing() {
        isTrashingDuplicates = false
    }
```

Sostituisci con:

```swift
    func endDuplicateTrashing() {
        isTrashingDuplicates = false
    }

    /// L'ultima base della certificazione dei Doppioni (ROADMAP #46, ADR-0017), tenuta qui e non
    /// nella finestra: riaprire la finestra, o ricaricare l'elenco dopo uno spostamento, la
    /// riusa senza rileggere e riclassificare tutto l'inventario (secondi, e centinaia di MB di
    /// passaggio). Si sostituisce da sola quando gli stati dei tre archivi cambiano
    /// (`DuplicateCertificationBasis.load(store:reusing:)`). Non `@Published`: nessuna view la
    /// osserva, la finestra la legge e la riscrive solo dentro le proprie funzioni.
    private(set) var duplicateCertificationBasisCache: DuplicateCertificationBasis? = nil

    func rememberDuplicateCertificationBasis(_ basis: DuplicateCertificationBasis) {
        duplicateCertificationBasisCache = basis
    }
```

**3. startDuplicateTrashRun riceve la certificazione.** Trova:

```swift
    func startDuplicateTrashRun(_ plan: DuplicateRunPlan, onAlert: @escaping (SimpleAlert) -> Void) {
        guard !plan.blocks.isEmpty else { return }
```

Sostituisci con:

```swift
    ///
    /// **La garanzia dell'inventario (ROADMAP #46, ADR-0017).** `certification` e' quella con cui
    /// la finestra ha lasciato spuntare i gruppi: ogni gruppo della corsa deve esserne coperto,
    /// altrimenti non parte niente. Subito prima di OGNI blocco la freschezza si ricontrolla
    /// (`DuplicateCertification.runBlock`): stesso giro, ancora completo, nessun backup dopo
    /// l'inizio. Un backup non puo' partire durante la corsa (`isTrashingDuplicates` lo ferma
    /// alla fonte), ma la regola si ricontrolla lo stesso (spec).
    func startDuplicateTrashRun(_ plan: DuplicateRunPlan, certification: DuplicateCertification,
                                onAlert: @escaping (SimpleAlert) -> Void) {
        guard !plan.blocks.isEmpty else { return }
        guard let certifiedRunId = certification.certifiedRunId,
              certification.uncoveredGroupCount(in: plan) == 0 else {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: DuplicatesStatus.notCertifiedRunMessage))
            return
        }
```

**4. ricontrollo prima di ogni blocco.** Trova:

```swift
                guard await MainActor.run(body: { VolumeMonitor.shared.ssdMounted }) else {
                    runOutcome.stopReason = .volumeVanished
                    break
                }
```

Sostituisci con:

```swift
                let (ssdMounted, lastWrite) = await MainActor.run {
                    (VolumeMonitor.shared.ssdMounted, ArchiveWriteClock.lastWriteAt())
                }
                guard ssdMounted else {
                    runOutcome.stopReason = .volumeVanished
                    break
                }
                // Il ricontrollo della spec, fuori dal main (una query piccola sullo store).
                if let block = DuplicateCertification.runBlock(states: try? store.inventoryStates(),
                                                              lastArchiveWriteAt: lastWrite,
                                                              certifiedRunId: certifiedRunId) {
                    runOutcome.stopReason = .inventoryNoLongerValid(block)
                    break
                }
```

**5. la finestra passa la certificazione (temporaneo, Task 5 la sostituisce).** Trova:

```swift
        runner.startDuplicateTrashRun(plan, onAlert: { pendingAlert = $0 })
```

Sostituisci con:

```swift
        runner.startDuplicateTrashRun(plan, certification: DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: []),
                                      onAlert: { pendingAlert = $0 })
```

- [ ] **Step 2:** `fasttest.sh`: `Executed 1219 tests` (invariato), 0 fallimenti, **0 warning** (è il controllo che conta qui: la tupla letta dentro `MainActor.run` e la chiamata allo store nel `Task.detached` non devono produrre warning di isolamento).
- [ ] **Step 3: revisione obbligatoria (checklist di `Docs/CLAUDE.md`).** `trashItem`: nessuna chiamata nuova, nessun passo di `DuplicateTrasher.run` spostato; ogni gruppo passato al trasher è coperto dalla certificazione (controllo prima di `beginDuplicateTrashing`), e la freschezza si ricontrolla prima di ogni blocco. `Task.detached`: i tipi chiamati sono `nonisolated` (`LibraryIndexStore`, `DuplicateCertification`); `ArchiveWriteClock` e `VolumeMonitor` sono letti solo dentro `MainActor.run`. Ogni uscita del ciclo passa ancora dal `MainActor.run` finale che chiama `endDuplicateTrashing()` (il `break` nuovo esce dal `for`, come gli altri).
- [ ] **Non coperto da test, dichiarato:** l'orchestrazione in `BackupRunner` (stessa ragione di `startDuplicateTrashRun` oggi). Coperto ai due capi: `DuplicateCertification.runBlock`/`uncoveredGroupCount` (Task 2), la riga dell'esito (Task 3). **Mutante dichiarato, non uccidibile da un test automatico:** togliere il ricontrollo prima di ogni blocco — lo copre solo la verifica dal vivo (Task 7, Step 6).
- [ ] **Step 4: commit.**
  ```
  Doppioni certificati, task 4: ricontrollo dell'inventario prima di ogni blocco

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 5: la finestra Doppioni — caselle spente col motivo, riga in testa, conteggi, riepilogo

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `DuplicatesView` (stato, `content`, `listArea`, `ruleEditorSheet`, `summarySheet`, `toggleSelection`, `selectAllVisible`, `reapplyFilter`, `loadGroups`, `rebuildBatch`, `beginConfirmation`, `startTrashing`), una `extension DuplicatesView` nuova subito dopo la struct, `DuplicateGroupRow`.

**Interfaces:**
- Consumes: tutto quanto prodotto dai Task 2-4.
- Produces (privati della finestra): `@State certification`, `certificationToken`, `pendingCertification`, `visibleBlockedCount`, `ruleCoveredHashes`, `ruleCoveredBlockedCount`, `@Environment(\.openWindow)`; `certificationBanner`, `blockedRowLine(for:)`, `refreshCertification()`, `recountBlocked()`; `DuplicateGroupRow.blockedReason: String?` (nuovo parametro, dopo `isSelected`).

**Dove gira cosa (la lezione del 2026-09-02):**
- `refreshCertification()` — `Task.detached`: `DuplicateCertificationBasis.load(store:reusing:)` (riusa la base del runner se gli stati non sono cambiati) e `DuplicateCertification(...)` su tutti i gruppi caricati; sul main solo la lettura di `ArchiveWriteClock.lastWriteAt()` (prima) e la pubblicazione (dopo), con un token che scarta un risultato superato. Chiamata dopo ogni `loadGroups()` e quando finisce un backup o un inventario (S7).
- Per riga: `blockedRowLine(for:)`, una lettura O(1) (solo le righe che la `LazyVStack` disegna).
- `recountBlocked()` — sul main, letture O(1) su `visibleIndices` e sui gruppi coperti dalla regola, già calcolati altrove: stesso costo di «Seleziona tutti quelli visibili», chiamata solo quando cambiano filtro, blocco o certificazione, mai dal `body`.
- `rule.covers` gira una volta sola, come oggi, in `rebuildBatch` (fuori dal main): ora ne tiene anche gli hash.

**Regola della selezione:** nella selezione entrano solo gruppi certificati (spunta a mano, «Seleziona tutti quelli visibili»); quando la certificazione cambia (un backup è finito) la selezione perde i gruppi non più spuntabili; `beginConfirmation()` filtra di nuovo e congela la certificazione insieme al blocco (`pendingCertification`), che viaggia invariata fino al runner. Una casella già spuntata si può sempre togliere.

- [ ] **Step 1: implementa.** Ventitré sostituzioni (le ultime tre sono in `DuplicateGroupRow`).

**1. stato nuovo della finestra.** Trova:

```swift
    @State private var thumbnailCache = DuplicateThumbnailCache()
```

Sostituisci con:

```swift
    @State private var thumbnailCache = DuplicateThumbnailCache()

    // MARK: - La garanzia dell'inventario (ROADMAP #46, ADR-0017)

    /// Quali gruppi si possono spuntare, calcolato fuori dal main da `refreshCertification()`,
    /// mai nel `body`. `nil` finche' non e' pronto: nessuna casella si accende.
    @State private var certification: DuplicateCertification? = nil
    /// Scarta un calcolo arrivato dopo uno piu' recente (stesso meccanismo di `loadToken` delle
    /// miniature): un backup finito mentre si calcolava non deve essere coperto da un risultato
    /// vecchio.
    @State private var certificationToken = UUID()
    /// La certificazione congelata insieme a `pendingBatch` in `beginConfirmation()`: viaggia
    /// invariata fino al runner, che ricontrolla la freschezza prima di ogni blocco.
    @State private var pendingCertification: DuplicateCertification? = nil
    /// Quanti gruppi visibili non si possono spuntare (`DuplicatesStatus.bulkSkipLine`),
    /// ricalcolato da `recountBlocked()` quando cambiano l'insieme visibile o la certificazione.
    @State private var visibleBlockedCount = 0
    /// I gruppi coperti dalla regola per cartella attiva (vuoto senza regola), calcolati in
    /// `rebuildBatch` insieme a `ruleCoverage`.
    @State private var ruleCoveredHashes: [String] = []
    @State private var ruleCoveredBlockedCount = 0
    @Environment(\.openWindow) private var openWindow
```

**2. riga in testa.** Trova:

```swift
            headerLine

            Label(DuplicatesStatus.mirrorsUntouchedNote()
```

Sostituisci con:

```swift
            headerLine

            certificationBanner

            Label(DuplicatesStatus.mirrorsUntouchedNote()
```

**3. quanti ne salta la selezione in massa.** Trova:

```swift
            selectionStatusLine
```

Sostituisci con:

```swift
            selectionStatusLine

            if let skipped = DuplicatesStatus.bulkSkipLine(blockedVisible: visibleBlockedCount,
                                                            visible: visibleIndices.count) {
                Text(skipped).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

**4. ricalcolo a fine backup e a fine inventario.** Inserisci **subito prima** della riga `.onChange(of: runner.isTrashingDuplicates) { _, isTrashing in` (unica nel file):

```swift
        // La garanzia si ricalcola quando finisce un backup (puo' aver invecchiato l'inventario)
        // o un inventario (puo' averlo rinnovato): il pannello lo dice senza essere riaperto.
        .onChange(of: runner.isRunning) { _, running in
            if !running { refreshCertification() }
        }
        .onChange(of: runner.isInventorying) { _, inventorying in
            if !inventorying { refreshCertification() }
        }
```

**5. fine corsa: via anche la certificazione congelata.** Trova:

```swift
                pendingPlan = nil
                loadGroups()
```

Sostituisci con:

```swift
                pendingPlan = nil
                pendingCertification = nil
                loadGroups()
```

**6. la riga riceve il motivo.** Trova:

```swift
                            DuplicateGroupRow(entry: entry,
                                              isSelected: selectedHashes.contains(entry.group.hash),
```

Sostituisci con:

```swift
                            DuplicateGroupRow(entry: entry,
                                              isSelected: selectedHashes.contains(entry.group.hash),
                                              blockedReason: blockedRowLine(for: entry.group.hash),
```

**7. regola per cartella: quanti dei coperti non si possono spostare.** Trova:

```swift
            } else if let coverage = ruleCoverage {
                Text(DuplicatesStatus.ruleCoverageLine(covered: coverage.covered,
                                                       excludedByThirdFolder: coverage.excludedByThirdFolder))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

Sostituisci con:

```swift
            } else if let coverage = ruleCoverage {
                Text(DuplicatesStatus.ruleCoverageLine(covered: coverage.covered,
                                                       excludedByThirdFolder: coverage.excludedByThirdFolder))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let blocked = DuplicatesStatus.ruleBlockedLine(blockedCovered: ruleCoveredBlockedCount) {
                    Text(blocked).font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
```

**8. riepilogo: su quale inventario poggia la garanzia.** Inserisci **subito prima** della riga `if let plan = pendingPlan {` (unica nel file):

```swift
            if let finishedAt = pendingCertification?.inventoryFinishedAt {
                Label(DuplicatesStatus.certifiedSummaryLine(inventoryFinishedAt: finishedAt),
                      systemImage: "checkmark.shield")
                    .font(AppFont.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

**9. spunta a mano: solo i gruppi certificati.** Trova:

```swift
    private func toggleSelection(_ hash: String) {
```

Sostituisci con:

```swift
    private func toggleSelection(_ hash: String) {
        // Seconda difesa (la casella e' gia' spenta): un gruppo non certificato non entra mai
        // nella selezione; toglierlo invece si puo' sempre.
        guard selectedHashes.contains(hash) || certification?.isSelectable(hash) == true else { return }
```

**10. selezione in massa: salta i gruppi non certificati.** Trova:

```swift
        for i in visibleIndices { selectedHashes.insert(loadedBatch.groups[i].group.hash) }
```

Sostituisci con:

```swift
        for i in visibleIndices {
            let hash = loadedBatch.groups[i].group.hash
            if certification?.isSelectable(hash) == true { selectedHashes.insert(hash) }
        }
```

**11. filtro: riconta i gruppi saltati.** Trova:

```swift
                self.visibleIndices = indices
                self.isApplyingFilter = false
            }
```

Sostituisci con:

```swift
                self.visibleIndices = indices
                self.isApplyingFilter = false
                self.recountBlocked()
            }
```

**12. lettura dell'elenco: poi la certificazione.** Trova:

```swift
                    self.loadState = .loaded(groups)
                    self.rebuildBatch(from: groups, rule: rule)
```

Sostituisci con:

```swift
                    self.loadState = .loaded(groups)
                    self.rebuildBatch(from: groups, rule: rule)
                    self.refreshCertification()
```

**13. regola: i gruppi coperti.** Trova:

```swift
            var coverage: (covered: Int, excludedByThirdFolder: Int)? = nil
            if let rule {
                let covered = groupsOnly.filter { rule.covers($0) }.count
```

Sostituisci con:

```swift
            var coverage: (covered: Int, excludedByThirdFolder: Int)? = nil
            var coveredHashes: [String] = []
            if let rule {
                coveredHashes = groupsOnly.filter { rule.covers($0) }.map(\.hash)
                let covered = coveredHashes.count
```

**14. regola: istantanea dei coperti.** Trova:

```swift
            let finalCoverage = coverage
```

Sostituisci con:

```swift
            let finalCoverage = coverage
            let finalCoveredHashes = coveredHashes
```

**15. regola: pubblica i coperti.** Trova:

```swift
                self.ruleCoverage = finalCoverage
```

Sostituisci con:

```swift
                self.ruleCoverage = finalCoverage
                self.ruleCoveredHashes = finalCoveredHashes
```

**16. ricostruzione: la selezione tiene solo i certificati.** Trova:

```swift
                self.selectedHashes = self.selectedHashes.filter { finalByHash[$0] != nil }
```

Sostituisci con:

```swift
                self.selectedHashes = self.selectedHashes.filter {
                    finalByHash[$0] != nil && self.certification?.isSelectable($0) == true
                }
                self.recountBlocked()
```

**17. conferma: solo i certificati, e la certificazione si congela col blocco.** Trova:

```swift
        let selected = loadedBatch.groups.filter { selectedHashes.contains($0.group.hash) }
```

Sostituisci con:

```swift
        // Secondo filtro (la selezione contiene gia' solo gruppi certificati): sulla
        // certificazione che da qui viaggia col blocco fino al runner.
        guard let certification else { return }
        let selected = loadedBatch.groups.filter {
            selectedHashes.contains($0.group.hash) && certification.isSelectable($0.group.hash)
        }
```

**18. conferma: congela la certificazione.** Trova:

```swift
        pendingPlan = DuplicateRunPlan(entries: batch.groups)
```

Sostituisci con:

```swift
        pendingPlan = DuplicateRunPlan(entries: batch.groups)
        pendingCertification = certification
```

**19. avvio: la certificazione congelata va al runner.** Trova:

```swift
        runner.startDuplicateTrashRun(plan, certification: DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: []),
                                      onAlert: { pendingAlert = $0 })
```

Sostituisci con:

```swift
        guard let certification = pendingCertification else { return }
        runner.startDuplicateTrashRun(plan, certification: certification, onAlert: { pendingAlert = $0 })
```

**20. le funzioni nuove della finestra.** Trova:

```swift
    private func startUndo() {
        runner.startTrashRestore(onAlert: { pendingAlert = $0 })
    }
}
```

Sostituisci con:

```swift
    private func startUndo() {
        runner.startTrashRestore(onAlert: { pendingAlert = $0 })
    }
}

// MARK: - La garanzia dell'inventario nella finestra Doppioni (ROADMAP #46, ADR-0017)

extension DuplicatesView {
    /// La riga in testa: se e su quale inventario si puo' spostare. Con l'inventario non
    /// valido, il bottone che apre la finestra Inventario (dove lo si aggiorna).
    @ViewBuilder
    private var certificationBanner: some View {
        if case .loaded = loadState {
            let line = DuplicatesStatus.certificationLine(certification?.freshness)
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Label(line.text, systemImage: line.tone == .ok ? "checkmark.shield" : "exclamationmark.shield")
                    .font(AppFont.caption)
                    .foregroundStyle(line.tone == .warning ? AppColor.warning : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if line.tone == .warning {
                    Spacer()
                    Button("Apri l'inventario…") { openWindow(id: "inventory") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    /// La riga sotto un gruppo che non si puo' spuntare, `nil` se si puo'. Una lettura O(1)
    /// nella certificazione gia' calcolata.
    private func blockedRowLine(for hash: String) -> String? {
        guard let certification else { return DuplicatesStatus.certificationPendingRowLine }
        return certification.block(for: hash).map { DuplicatesStatus.blockedRowLine($0) }
    }

    /// Ricalcola quali gruppi si possono spuntare, fuori dal main. La base dell'inventario si
    /// riusa dal runner finche' gli stati dei tre archivi non cambiano; l'ora dell'ultimo
    /// backup si legge qui sul main (`JobHistoryStore` e' del MainActor). Chiamata dopo ogni
    /// lettura dell'elenco e quando finisce un backup o un inventario. Toglie dalla selezione
    /// i gruppi che non si possono piu' spuntare.
    private func refreshCertification() {
        guard let store = runner.libraryIndexStore, case .loaded(let groups) = loadState else { return }
        let cached = runner.duplicateCertificationBasisCache
        let lastWrite = ArchiveWriteClock.lastWriteAt()
        let token = UUID()
        certificationToken = token
        Task.detached(priority: .utility) {
            let basis = DuplicateCertificationBasis.load(store: store, reusing: cached)
            let result = DuplicateCertification(basis: basis, lastArchiveWriteAt: lastWrite, groups: groups)
            await MainActor.run {
                self.runner.rememberDuplicateCertificationBasis(basis)
                guard self.certificationToken == token else { return }
                self.certification = result
                self.selectedHashes = self.selectedHashes.filter { result.isSelectable($0) }
                self.recomputeSelectionStats()
                self.recountBlocked()
            }
        }
    }

    /// Quanti gruppi visibili, e quanti coperti dalla regola, non si possono spuntare. Sul main:
    /// letture O(1) sugli insiemi gia' calcolati (al massimo tanti quanti i gruppi caricati),
    /// mai un ricalcolo dei gruppi — lo stesso costo di «Seleziona tutti quelli visibili».
    private func recountBlocked() {
        guard let certification, let loadedBatch else {
            visibleBlockedCount = 0
            ruleCoveredBlockedCount = 0
            return
        }
        visibleBlockedCount = visibleIndices.reduce(0) { total, i in
            guard loadedBatch.groups.indices.contains(i) else { return total }
            return total + (certification.isSelectable(loadedBatch.groups[i].group.hash) ? 0 : 1)
        }
        ruleCoveredBlockedCount = ruleCoveredHashes.reduce(0) { $0 + (certification.isSelectable($1) ? 0 : 1) }
    }
}
```

**21. la riga: il motivo.** Trova:

```swift
    let entry: DuplicateBatch.Entry
    let isSelected: Bool
    let libraryRootPath: String?
```

Sostituisci con:

```swift
    let entry: DuplicateBatch.Entry
    let isSelected: Bool
    /// Perche' la casella e' spenta (ROADMAP #46, ADR-0017), `nil` se il gruppo si puo' spuntare.
    let blockedReason: String?
    let libraryRootPath: String?
```

**22. la riga: casella spenta.** Trova:

```swift
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
```

Sostituisci con:

```swift
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // Spenta se il gruppo non e' certificato; un gruppo gia' spuntato si puo' sempre togliere.
                .disabled(blockedReason != nil && !isSelected)
```

**23. la riga: il perche' scritto.** Trova:

```swift
                Text(duplicateKeepExplanation(entry.choice, in: entry.group))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
```

Sostituisci con:

```swift
                Text(duplicateKeepExplanation(entry.choice, in: entry.group))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let blockedReason {
                    Label(blockedReason, systemImage: "lock")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 2:** `fasttest.sh`: `Executed 1219 tests`, 0 fallimenti, 0 warning. **Punto di controllo `xcodebuild`** (in background): build pulita 0 warning, `Executed 1219 tests` (B+60).
- [ ] **Step 3: revisione obbligatoria (checklist di `Docs/CLAUDE.md`).** UI aggiornata da contesto async solo dentro `MainActor.run`; il `Task.detached` di `refreshCertification` chiama solo tipi `nonisolated` (`DuplicateCertificationBasis`, `DuplicateCertification`, `LibraryIndexStore`); nessun `filter`/`reduce` sui gruppi dentro il `body` (`grep -n "certification" AppBackupFoto/ContentView.swift` nella `struct DuplicatesView`: le uniche letture nel `body` sono `certification?.freshness` nella riga in testa e `blockedRowLine(for:)` per riga).
- [ ] **Step 4: prova a vista, senza spostare niente** (Enrico o l'orchestratore, app avviata da Xcode, **nessun clic su «Sposta nel Cestino» nella conferma**): aprire Diagnostica → «Vedi le copie doppie…». Atteso con l'inventario di oggi (vedi la testa del piano): riga in testa verde «Inventario completo del 5 ottobre 2026 alle 20:31, più recente dell'ultimo backup: …»; quasi tutte le caselle accese; un gruppo eventualmente spento ha sotto «Non si può spuntare: …»; «Seleziona tutti quelli visibili» seguito da «Togli la selezione…» funziona e la riga sotto dice quanti ne salta. «Sposta nel Cestino…» apre il riepilogo con la riga nuova sull'inventario: **chiudere con «Annulla»**. Il resto si prova nel Task 7.
- [ ] **Non coperto da test, dichiarato:** `DuplicatesView`, `DuplicateGroupRow` e il loro cablaggio (SwiftUI e bookmark veri), come per tutto il pannello. Coperto ai due capi: `DuplicateCertification` (Task 2) e `DuplicatesStatus` (Task 3).
- [ ] **Step 5: commit.**
  ```
  Doppioni certificati, task 5: la finestra mostra e rispetta la garanzia dell'inventario

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 6: documentazione (regola assoluta, CLAUDE, ROADMAP #46, CONTEXT, architettura)

**Files:** `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`.

- [ ] **Step 1: `Docs/CLAUDE.md`, «Regola assoluta», punto 1 (S9, D1 — testo da approvare parola per parola).** Nel punto 1, trova:

```
il pannello Doppioni può spostare nel **Cestino del volume** (`FileManager.trashItem`) copie byte-identiche di file che restano presenti sull'SSD — e solo dopo che ogni membro del gruppo,
```

Sostituisci con:

```
il pannello Doppioni può spostare nel **Cestino del volume** (`FileManager.trashItem`) copie byte-identiche di file che restano presenti sull'SSD — **dal 2026-10-05 (ADR-0017) solo se l'ultimo inventario, completo su SSD, HDD e Cubbit e più recente dell'ultimo backup o import, certifica quella foto al sicuro su tutti e tre gli archivi e vede ogni copia del gruppo sull'SSD con lo stesso contenuto; la freschezza si ricontrolla prima di ogni blocco** — e solo dopo che ogni membro del gruppo,
```

E dopo la seconda nota in corsivo sotto la regola (quella che comincia con «I punti **2** e **3** sono stati riscritti il **2026-10-05**»), aggiungi:

```
> Il punto **1** ha guadagnato la condizione sull'inventario il **<data del commit>** (testo approvato da Enrico, ADR-0017): con i doppioni certificati la porta del Cestino ha una condizione in più, e una regola assoluta che non elenca tutte le sue condizioni è un'eccezione silenziosa.
```

- [ ] **Step 2: `Docs/CLAUDE.md`, checklist di revisione.** Nel blocco «IF il codice chiama `trashItem`», dopo «THEN verifica che il percorso di destinazione sia registrato prima di procedere al file successivo», aggiungi (riga vuota prima, stessa rientranza):

```
    THEN verifica che ogni gruppo sia coperto da una `DuplicateCertification` fresca (ADR-0017) e che `DuplicateCertification.runBlock` si ricontrolli prima di ogni blocco
```

- [ ] **Step 3: `Docs/CLAUDE.md`, «Stato attuale».** Aggiorna la data del titolo; nella frase introduttiva, dopo il «Settimo tocco», aggiungi: «**Ottavo tocco, <data>**: piano `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md` (ADR-0017) — doppioni sull'SSD con la garanzia dell'inventario (#46), progetto 3 di 4; aggiunta una condizione al punto 1 della «Regola assoluta»; aggiunta la riga «Doppioni con garanzia (#46)» e aggiornata la riga «Test automatici».» Aggiungi dopo la riga «Riparazione 2 su 3 (#45)»:

```
| Doppioni con garanzia dell'inventario (#46) | ⏳ **Implementato (<data>, ADR-0017)** su `feature/certified-duplicates-ssd`. Nel pannello Doppioni un gruppo si spunta solo se l'ultimo inventario è completo su SSD, HDD e Cubbit, nessun backup o import ha scritto dopo l'inizio di quel giro (`ArchiveWriteClock`: fine dell'ultimo job o inizio dell'ultimo, il più recente), il contenuto è ✅ e ogni copia del gruppo è nell'inventario dell'SSD di quel giro; gli altri restano visibili con la casella spenta e il motivo; selezione in massa e regola per cartella li saltano e lo dicono; ricontrollo della freschezza prima di ogni blocco; il registro del Cestino e la storia degli spostamenti annotano il percorso tenuto (`keptPath`/`keptPaths`, relativo alla radice dell'SSD) per il progetto 4. Verifica dal vivo (Task 7 del piano) ancora da fare — non marcarlo "fatto". |
```

Nella riga «Test automatici», in testa: «**1.219 test XCTest** su `feature/certified-duplicates-ssd` (<data>, +60 rispetto ai 1.159 di `main`). File nuovi dai doppioni certificati (#46, ADR-0017): `DuplicateCertificationTests` (30), `ArchiveWriteClockTests` (5), `DuplicateCertificationStatusTests` (17); estesi `TrashManifestTests` (+3), `TrashHistoryTests` (+2), `DuplicateTrasherTests` (+2), `MainThreadIsolationTests` (+1). **Storia precedente — …**» (il resto della riga resta com'è).

- [ ] **Step 4: `Docs/ROADMAP.md`.** Aggiungi dopo il punto 45:

```
46. ⏳ **Implementato il <data>, verifica dal vivo ancora da fare — doppioni sull'SSD con la garanzia dell'inventario (progetto 3 di 4).** Spec `Docs/superpowers/specs/2026-10-05-certified-duplicates-ssd-design.md`, piano `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md`, ADR-0017. Un gruppo di doppioni sull'SSD si sposta nel Cestino solo se un inventario completo e più recente dell'ultimo backup certifica la foto al sicuro su SSD, HDD e Cubbit; il registro annota il percorso tenuto per il progetto 4 (doppioni su HDD e Cubbit).
```

- [ ] **Step 5: `Docs/CONTEXT.md`.** Nella sezione «## Pannello Doppioni (roadmap #31)», dopo il paragrafo «**Copia tenuta** — …», aggiungi:

```
**Gruppo certificato** (termine nuovo, 2026-10-05, ADR-0017) — un gruppo di doppioni che si può spuntare: l'ultimo inventario è completo su SSD, HDD e Cubbit, nessun backup o import ha scritto dopo l'inizio di quel giro, il contenuto è ✅ «Al sicuro», e ogni copia del gruppo — la tenuta e quelle che escono — è nell'inventario dell'SSD di quel giro con lo stesso contenuto. Un gruppo non certificato resta visibile, con la casella spenta e il motivo. La certificazione si aggiunge alla rilettura dal disco al momento dello spostamento, non la sostituisce.

**Inventario fresco** — completo su tutti e tre gli archivi e più recente dell'ultimo job che scrive sugli archivi (Mac → SSD, SSD → HDD, SSD → Cubbit, import). Lo invecchia anche un job che non ha copiato niente; non lo invecchiano spostamenti nel Cestino, annullamenti, riparazioni, inventario, lettura dell'elenco.

**Percorso tenuto** — nel registro del Cestino e nella storia degli spostamenti, per ogni foto spostata, il percorso della copia rimasta, relativo alla radice dell'SSD: è lo stesso percorso sull'HDD e la stessa chiave su Cubbit, e il progetto 4 terrà quella.
```

- [ ] **Step 6: `.claude/rules/architecture.md`.** Dopo la sezione «#### Il pannello Doppioni alla scala reale — …» (prima del `---` che precede «### Inventario certificato»), aggiungi:

```
#### Doppioni con la garanzia dell'inventario (<data>, ROADMAP #46, ADR-0017)

Piano `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md`, spec `Docs/superpowers/specs/2026-10-05-certified-duplicates-ssd-design.md`. **Implementato, verifica dal vivo del Task 7 ancora da fare.**

- **`ArchiveWriteClock`** (enum sul MainActor: legge `JobHistoryStore`) — l'ora dell'ultima scrittura sugli archivi: la più recente fra la data dell'ultimo `JobSummary` (fine del job, anche interrotto o fallito) e `lastArchiveWriteJobStartedAt`, scritta da `run(label:)` dopo il cancello e prima di ogni scrittura (copre un job interrotto da una chiusura forzata). Contano tutti e soli i job di `run(label:)`.
- **`DuplicateInventoryFreshness`/`DuplicateCertificationBlock`/`DuplicateCertificationBasis`/`DuplicateCertification`** (`nonisolated`, value type puri) — freschezza (tre stati completi dello stesso giro, ultima scrittura non dopo l'**inizio** del giro), contenuti ✅ presi da `InventoryClassifier.classify` (una regola sola), mappa chiave → SHA256 dell'SSD; verdetto per gruppo (non ✅ > copia non vista nell'inventario dell'SSD, la tenuta compresa). Un hash che la certificazione non conosce non è spuntabile. `load(store:reusing:)` legge prima gli stati e riusa la base se sono uguali; con un giro incompleto non legge altro.
- **`BackupRunner`** — `duplicateCertificationBasisCache` (non `@Published`); `startDuplicateTrashRun(_:certification:onAlert:)` rifiuta una corsa non coperta e prima di ogni blocco, insieme a `ssdMounted`, rifà `DuplicateCertification.runBlock` (stesso giro, ancora fresco); se no, `DuplicateRunStopReason.inventoryNoLongerValid`.
- **`DuplicatesView`** — `refreshCertification()` in `Task.detached` dopo ogni lettura dell'elenco e a fine backup/inventario (token contro i risultati superati); per riga una lettura O(1); `recountBlocked()` sul main su indici già calcolati; selezione (a mano e in massa) solo di gruppi certificati; `pendingCertification` congelata con il blocco in `beginConfirmation()`.
- **Registro** — `TrashedItem.keptPath` e `TrashHistoryEntry.keptPaths` (relativi alla radice dell'SSD, `decodeIfPresent`/opzionale): il progetto 4 terrà lo stesso percorso su HDD e Cubbit. La storia c'è perché il registro di ripristino pota a 2.000 voci.

**Non coperto da test, dichiarato:** il cablaggio in `BackupRunner` e `DuplicatesView`. Coperto ai due capi: `DuplicateCertificationTests`, `ArchiveWriteClockTests`, `DuplicateCertificationStatusTests`, e le aggiunte a `TrashManifestTests`/`TrashHistoryTests`/`DuplicateTrasherTests`/`MainThreadIsolationTests`.
```

- [ ] **Step 7:** nessun codice cambiato: `fasttest.sh` non serve. Rileggi i quattro file cercando le frasi che la garanzia ha reso incomplete (`grep -n "Unica porta\|non sa se la foto\|copie byte-identiche" Docs/CLAUDE.md Docs/CONTEXT.md .claude/rules/architecture.md Docs/adr/0005-*.md`) — ADR-0005 **non** si riscrive: se serve, una nota in coda «Vedi ADR-0017 (2026-10-05): la porta del Cestino ha una condizione in più».
- [ ] **Step 8: commit.**
  ```
  Doppioni certificati, task 6: documentazione (regola assoluta, CLAUDE, ROADMAP #46, CONTEXT, architettura)

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 7: verifica dal vivo (la esegue l'orchestratore con Enrico)

**Precondizioni:** Task 0-6 fatti, `xcodebuild` verde (1.219 test). L'app di `/Applications` chiusa; si usa la build del branch avviata da Xcode (Debug), con SSD e HDD collegati e Cubbit raggiungibile (NordVPN spenta). Ogni comando da terminale qui sotto è **in sola lettura**. **L'app non svuota mai il Cestino, e nemmeno noi**: le foto spostate restano in `/Volumes/SSD - Enri/.Trashes/501/` finché Enrico non decide.

- [ ] **Step 1: fotografia di prima (sola lettura).**
  ```bash
  DB="$HOME/Library/Application Support/AppBackupFoto/library-index.sqlite"
  sqlite3 "file:$DB?mode=ro" "SELECT archive,run_id,complete,datetime(started_at,'unixepoch','localtime'),datetime(finished_at,'unixepoch','localtime') FROM inventory_state;"
  python3 -c "import plistlib,os,json,datetime;d=plistlib.load(open(os.path.expanduser('~/Library/Preferences/enri.AppBackupFoto.plist'),'rb'));j=json.loads(d['lastJobSummary']);print(j['label'],datetime.datetime(2001,1,1)+datetime.timedelta(seconds=j['date']),'start-marker:',d.get('lastArchiveWriteJobStartedAt'))"
  ls "/Volumes/SSD - Enri/.Trashes/501" | wc -l
  tail -c 600 "$HOME/Library/Application Support/AppBackupFoto/trash-history.jsonl" 2>/dev/null; echo
  ```
  Atteso (oggi): giro `1791228398292` completo sui tre archivi; ultimo job «SSD -> Cubbit S3» del 2026-09-26; nessun `start-marker`. Annotare il numero di file nel Cestino dell'SSD.
- [ ] **Step 2: il pannello con l'inventario fresco.** Diagnostica → «Vedi le copie doppie…». Atteso: riga in testa verde «Inventario completo del 5 ottobre 2026 alle 20:31, più recente dell'ultimo backup: …» (o la data dell'ultimo giro, se nel frattempo ne è stato fatto un altro); quasi tutte le caselle accese (stima: almeno 27.727 gruppi su 27.760); sotto «Seleziona tutti quelli visibili» la riga dei saltati solo se qualche gruppo è spento, e sotto ogni gruppo spento «Non si può spuntare: …». Se la riga in testa è arancione: **fermarsi** e leggere il motivo (un backup fatto dopo il 05/10 sera → aggiornare l'inventario, Step 7, poi ricominciare da qui).
- [ ] **Step 3: un blocco piccolo, spostato.** Filtro su una cartella con pochi gruppi; spuntare **uno o due** gruppi di foto piccole; annotare per ciascuno il percorso «RESTA» e quelli «NEL CESTINO». «Sposta nel Cestino…»: il riepilogo deve avere la riga nuova «Ogni foto di questo riepilogo risulta al sicuro anche sull'HDD e su Cubbit nell'inventario del …». «Continua…» → «Sposta nel Cestino». Atteso: «Fatto: 1 blocco completato, N file spostati nel Cestino.» Poi, in sola lettura:
  ```bash
  python3 -c "import json,os;m=json.load(open(os.path.expanduser('~/Library/Application Support/AppBackupFoto/trash-manifest.json')));[print(i['originalDisplayPath'],'->',i.get('keptPath')) for i in m['items'][-4:]]"
  tail -n 1 "$HOME/Library/Application Support/AppBackupFoto/trash-history.jsonl"
  ```
  Atteso: per ogni foto spostata `keptPath` = il percorso «RESTA» annotato (relativo, senza `/Volumes/…`); nell'ultima riga della storia `keptPaths` nello stesso ordine di `originalPaths`. La copia tenuta c'è ancora sull'SSD (Mostra nel Finder dalla riga, o `ls`).
- [ ] **Step 4: annullato.** «Annulla l'ultimo spostamento» → «Rimetti a posto». Atteso: tutte le foto del blocco tornate (stesso esito di oggi); nel registro le stesse voci con `restoredAt` **e ancora** `keptPath`; il numero di file in `.Trashes/501` uguale a quello dello Step 1. (Le foto tornate ricompaiono fra i doppioni solo dopo il prossimo aggiornamento dell'elenco: è il comportamento di sempre, ADR-0002.)
- [ ] **Step 5: un backup che invecchia l'inventario, con la finestra aperta.** Nel pannello spuntare di nuovo un gruppo piccolo e aprire il riepilogo («Sposta nel Cestino…»), **senza** continuare. Nella finestra principale avviare **SSD → HDD** e aspettare che finisca. Atteso nel pannello, senza riaprirlo: la riga in testa diventa arancione «L'inventario è più vecchio dell'ultimo backup (<ora del backup>): aggiornalo, poi torna qui. L'ultimo aggiornamento è durato circa 5 minuti.» col bottone «Apri l'inventario…»; ogni gruppo ha la casella spenta e «Non si può spuntare: l'inventario è più vecchio dell'ultimo backup (…)»; la selezione si è svuotata; «Seleziona tutti quelli visibili» non spunta niente e la riga sotto dice «Nessuno dei gruppi visibili si può spuntare adesso: …».
- [ ] **Step 6: il ricontrollo prima del blocco (l'unico modo di provarlo: non ha un test automatico).** Nel riepilogo rimasto aperto dallo Step 5 (il blocco e la certificazione erano stati congelati prima del backup): «Continua…» → «Sposta nel Cestino». Atteso: **nessun file spostato**; l'esito dice «Mi sono fermato prima di spostare altro: l'inventario è più vecchio dell'ultimo backup (…). 0 blocchi sono stati completati su 1 previsto.»; il numero di file in `.Trashes/501` invariato; nessuna riga nuova in `trash-history.jsonl`. Se invece qualcosa si sposta: **fermarsi**, è un difetto del Task 4.
- [ ] **Step 7: l'inventario aggiornato.** «Apri l'inventario…» → «Aggiorna l'inventario» (l'ultimo giro è durato ~5 minuti). Tornati al pannello, atteso senza riaprirlo: riga in testa di nuovo verde con la data nuova, caselle di nuovo accese.
- [ ] **Step 8: un blocco vero.** Enrico sceglie cosa smaltire (un filtro, o la regola per cartella con «Solo i gruppi coperti dalla regola» e «Seleziona tutti quelli visibili»; nell'editor della regola, sotto la copertura, la riga «Di questi, N … non si possono ancora spostare» compare solo se qualcuno è spento). **Raccomandazione: una selezione che stia in un blocco solo** (fino a 2.000 file o 50 GB: il riepilogo non nomina «blocchi»), così «Annulla» la copre tutta. Leggere il riepilogo insieme, confermare. Annotare l'esito (file spostati, gruppi saltati e perché) e ripetere i due comandi dello Step 3: ogni voce nuova ha il suo `keptPath`.
- [ ] **Step 9: niente altro è cambiato.** HDD e Cubbit non toccati: nessun backup è partito durante lo spostamento (era bloccato), e nel registro nessun percorso fuori dall'SSD. Lo spazio sull'SSD non è ancora tornato: tornerà quando Enrico svuota il Cestino.
- [ ] **Step 10: non provati dal vivo, per costruzione (dichiarato):** inventario illeggibile, inventario rifatto fra l'apertura del pannello e lo spostamento («aggiornato dopo che hai aperto questo elenco»), job interrotto da una chiusura forzata (il segno d'inizio), una copia comparsa sull'SSD dopo l'inventario — coperti dai test automatici (`DuplicateCertificationTests`, `ArchiveWriteClockTests`), non dal vivo.
- [ ] **Step 11:** riportare l'esito in `Docs/CLAUDE.md` (riga «Doppioni con garanzia dell'inventario (#46)», da ⏳ a ✅ solo se gli Step 2-8 sono passati) e in `Docs/ROADMAP.md` (#46), commit:
  ```
  Doppioni certificati: verifica dal vivo

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

## Fuori scope (dichiarato)

- Spostare o cancellare doppioni su HDD e Cubbit (progetto 4): qui si **prepara** solo il percorso tenuto nel registro.
- Svuotare il Cestino dall'app (ADR-0005, permanentemente).
- Doppioni fuori dal perimetro foto/video (`IndexableKind`).
- Un job interrotto da una chiusura forzata **prima** di questo piano non ha lasciato il segno d'inizio: se ne è successo uno dopo l'ultimo inventario, la regola 4 (ogni copia nell'inventario dell'SSD) blocca comunque i gruppi con copie nuove sull'SSD; un job verso HDD o Cubbit aggiunge soltanto, e non rende «non al sicuro» niente. Oggi l'ultimo job registrato (26/09) è precedente all'ultimo inventario (05/10).
- Il ripristino guidato (`RestoreEngine`) può scrivere in una cartella sull'SSD scelta dall'utente senza passare da `run(label:)`: non invecchia l'inventario, ma le copie che crea non sono nell'inventario dell'SSD e i loro gruppi restano bloccati dalla regola 4 («una delle sue copie è cambiata, o è comparsa, dopo l'ultimo inventario»). Verso sicuro, nessuna modifica.
- La certificazione non riconsidera i gruppi già spostati prima di questo piano (27/09): sono nel Cestino, e il registro vecchio non ha `keptPath` (resta `nil`, «non si sa»).

## Mutanti verificati dall'Architect (prototipo, 2026-10-05)

Ogni mutante applicato al `ContentView.swift` con tutte le patch, compilato, ed eseguita la classe indicata: **15 su 15 uccisi**.

| # | Mutante | Classe | Esito |
| :--- | :--- | :--- | :--- |
| M1 | freschezza confrontata con la **fine** del giro | `DuplicateCertificationTests` | 6 fallimenti |
| M2 | regola 4 che salta il primo membro (la tenuta) | `DuplicateCertificationTests` | 1 |
| M3 | hash sconosciuto spuntabile | `DuplicateCertificationTests` | 2 |
| M4 | giro incompleto classificato lo stesso | `DuplicateCertificationTests` | 2 |
| M5 | orologio dei job che legge solo l'inizio | `ArchiveWriteClockTests` | 1 |
| M6 | ricontrollo che ignora un giro nuovo | `DuplicateCertificationTests` | 1 |
| M7 | base riusata anche con stati diversi | `DuplicateCertificationTests` | 2 |
| M8 | `keptPath` = primo membro invece della tenuta | `DuplicateTrasherTests` | 1 |
| M9 | `keptPaths` in ordine inverso | `TrashHistoryTests` | 1 |
| M10 | `decode` al posto di `decodeIfPresent` per `keptPath` | `TrashManifestTests` | 15 |
| M11 | inizio del giro = il più recente dei tre | `DuplicateCertificationTests` | 1 |
| M12 | precedenza invertita fra «non al sicuro» e «copia cambiata» | `DuplicateCertificationTests` | 1 |
| M13 | `uncoveredGroupCount` sempre 0 | `DuplicateCertificationTests` | 1 |
| M14 | testo «aggiornalo, ci vogliono pochi minuti» | `DuplicateCertificationStatusTests` | 2 |
| M15 | basta l'SSD completo | `DuplicateCertificationTests` | 5 |

**Non uccidibile da un test automatico, dichiarato:** togliere il ricontrollo prima di ogni blocco in `BackupRunner.startDuplicateTrashRun` (cablaggio). Lo prova il Task 7, Step 6.

**Verifica task per task** (patch fino al task N, test fino al task N, stesso compilatore e stesse impostazioni del target): T1 1.166, T2 1.202, T3 1.219, T4 1.219, T5 1.219 test; 0 fallimenti e 0 warning (app e test) a ogni passo.

**Il prototipo** (fuori dal repository, da non committare): `/private/tmp/claude-501/dupcert-plan/proto/` — `base/ContentView.orig.swift` (copia di `2e32d56`), `patches/01-kept-path.py` … `patches/05-view.py` (una per task di codice, `PATCHES = [(descrizione, trova, sostituisci)]`, ogni «trova» presente una volta sola: è il testo di questo piano), `patch.py`, `newtests/` (i tre file nuovi), `../snippets/` (le aggiunte ai file esistenti), `addtests.py`, `fasttest.sh`, `mutate.py`.
