# Inventario certificato su SSD, HDD e Cubbit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: BOZZA — in attesa dell'approvazione esplicita di Enrico**, in particolare della sezione «Scostamenti dalla spec da far approvare» qui sotto. Nessuna riga di codice scritta nel repository. Spec: `Docs/superpowers/specs/2026-09-26-cross-store-inventory-design.md` (approvata). ADR: **0015** (scritto nel Task 0, dopo l'approvazione). ROADMAP: **#44**. ADR-0014 e #43 restano riservati al piano `2026-09-26-s3-upload-failures-visible`.

**Base:** `main` a `bf9fd99` (861 test), branch nuovo `feature/cross-store-inventory`.

**Goal:** una finestra «Inventario», solo lettura, che per ogni contenuto foto/video dice se è ✅ al sicuro su SSD+HDD+Cubbit, ⚠️ manca da qualche parte (e da dove), 🔎 c'è solo fuori dall'SSD, ❗ va controllato — con i numeri per archivio (foto, copie in più, spazio recuperabile) e la regola «un archivio letto a metà non rende assente niente». È la base dei progetti 2-4.

**Architecture:** una lettura per file produce tre impronte (`ContentHasher`: SHA256, MD5, ETag a pezzi da 64 MiB). SSD e HDD si leggono con `InventoryScanner` (stessa traversata di `LibraryIndexer`, tabelle diverse), Cubbit con `InventoryCubbitReader` (la stessa `ListObjectsV2` di oggi, letta oggetto per oggetto con l'ETag). Tutto finisce in tre tabelle nuove dello stesso SQLite dell'elenco (`LibraryIndexStore`, schema 2). `S3ETagMatcher` e `InventoryClassifier` (puri) trasformano i tre elenchi in categorie; `InventoryRefresh` orchestra il giro fuori dal main; `BackupRunner` ci mette solo bookmark, cancelli e pubblicazione; `InventoryView` mostra testi che vivono tutti in `InventoryStatus`.

**Tech Stack:** Swift 5.x, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, *Approachable Concurrency* (`NonisolatedNonsendingByDefault`), SwiftUI, SQLite di sistema, CryptoKit (`SHA256`, `Insecure.MD5`), XCTest. Nessuna dipendenza nuova.

**Verifica preventiva fatta dall'Architect (2026-09-26).** Il codice di produzione dei Task 1-9 e **tutti** i test dei Task 1-9 di questo piano sono stati compilati ed eseguiti **fuori dall'app** — un modulo di prova `AppBackupFoto` costruito con `swiftc` in `/private/tmp/claude-501/inventory-plan/proto/` con le stesse impostazioni del target (Swift 5, default `MainActor`, le cinque feature di *Approachable Concurrency*), con `LibraryIndexStore`/`LibraryIndexer` copiati da `bf9fd99` e un bundle XCTest lanciato con `xcrun xctest` (nessun lancio dell'app, nessun `UserDefaults`/Keychain toccato): **140 test, 0 fallimenti, 0 warning**. Sette mutanti delle regole principali verificati morti (elencati nei task). Il cablaggio di `BackupRunner` e `InventoryView` (Task 10-11) è stato compilato contro stub, senza warning; non è stato eseguito. Unica differenza voluta del prototipo: `isRunningUnderTests()` forzato a `true` (fuori da Xcode la variabile d'ambiente non c'è).

---

## Scostamenti dalla spec da far approvare

Trovati leggendo il codice a `bf9fd99`. **Nessuno è stato applicato di nascosto**: il piano implementa la colonna «Proposta»; se Enrico sceglie l'alternativa, l'Implementer si ferma e rimanda all'Architect.

| # | La spec dice | Il codice dice | Proposta del piano | Alternativa |
| :--- | :--- | :--- | :--- | :--- |
| S1 | Lettura con `S3Syncer.readFileInChunks` | `S3Syncer` non è annotato, quindi è `@MainActor` (default del target): `readFileInChunks` è un `static func … async` **isolato al main** — chiamato dallo scanner girerebbe sul main (ADR-0006, caso D). Copia ogni parte da 64 MiB in un `Data` nuovo e non misura la dimensione prima/dopo come `sha256Measured` | `ContentHasher.digestFile`: stesso principio (POSIX `open/read/close`, buffer riusato da 1 MiB, **mai** `FileHandle`), con `fstat` prima/dopo come `sha256Measured` | Annotare `nonisolated` `readFileInChunks` e usarlo: resta la copia da 64 MiB per parte e manca la misura della dimensione |
| S2 | «Stesso scanner dell'elenco attuale (`LibraryIndexer`)» | `LibraryIndexer.scan` scrive solo in `entries` (`upsert`/`allKeys`/`remove`/`entry(forKey:)`), calcola solo SHA256 e contiene la logica di rimozione più protetta del progetto | `InventoryScanner` nuovo, con **la stessa traversata** (stesse funzioni condivise: `LibraryExclusions`, `.skipsHiddenFiles`, `IndexableKind`, `canonicalPathComponents`, `deviceIdentifier`, `errorHandler` che conta, `indexEntryVerdict`) e un **test di parità** (`testSeesExactlyTheFilesTheListSees`) che fallisce se i due lettori vedono file diversi | Generalizzare `LibraryIndexer` con un protocollo di destinazione e un hasher iniettato: tocca il componente più testato e mutato del progetto |
| S3 | «Aumento della versione di schema: uno schema sconosciuto significa ricostruisci» | Oggi ogni versione diversa da quella attesa fa `DROP TABLE entries`: portando la versione a 2 alla lettera, **al primo avvio si butterebbe l'elenco da 141.683 voci** (25-35 minuti per rifarlo, e intanto l'import non riconosce i doppioni) | Versione 2; **dalla 1 (schema noto, `entries` identica) si sale tenendo `entries`** e ricreando vuote le tabelle dell'inventario; ogni altra versione = ricostruisci tutto | Bump letterale: si butta anche l'elenco |
| S4 | Ogni contenuto cade in una delle quattro categorie | Un contenuto che manca **solo** da archivi letti a metà non può essere ✅ (sarebbe falso) né ⚠️/🔎 (vietato dalla regola «incompleto ≠ assente») | Quinta situazione **«⏳ Non si può ancora dire»**, mostrata in fondo e solo se non vuota. Non è un esito: è il posto dei contenuti sospesi | — (le alternative violano la spec) |
| S5 | Certificato = ETag uguale all'MD5 o all'ETag a pezzi di un file locale; non certificabile = `-N` senza corrispondenza o formato sconosciuto | Resta scoperto il caso **ETag a parte unica senza file locale corrispondente** (il materiale che c'è solo su Cubbit, i ~20 GB in più) | È l'MD5 vero di un contenuto che c'è solo su Cubbit: si riconosce dall'MD5 (`identifiedOnlyByMD5`) → 🔎. Un oggetto **a pezzi** solo su Cubbit resta non certificabile → ❗, alla lettera | Mettere anche gli oggetti a pezzi solo-Cubbit in 🔎 con una nota: i progetti 2-4 potrebbero agire su un contenuto mai confrontato |
| S6 | `-N` confrontato con parti da 64 MB | Un ETag `-1` (caricamento a pezzi con una sola parte) non dipende dalla dimensione delle parti | `-1` si certifica ricalcolandolo dall'MD5 (`md5` dei 16 byte dell'MD5) | Trattarlo come non certificabile |
| S7 | Incrementale «per dimensione o data cambiata» | L'elenco usa già `indexEntryVerdict` (regola anti-racy di ADR-0003 e tolleranza per il cambio d'ora) | Stessa funzione: si rilegge anche un file modificato entro 2 s dall'ultima lettura; uno spostamento d'ora esatto non fa rileggere | Solo dimensione+data |
| S8 | Tabelle nello stesso SQLite (decisione 4) | «Svuota l'elenco» (`deleteIndexAndRecreate`) cancella il file intero | Conseguenza dichiarata: svuotare l'elenco svuota anche l'inventario; il testo di conferma in Diagnostica lo dice (Task 11) | — |
| S9 | Lista Cubbit via `listPage`, estesa all'ETag senza cambiare cosa ricevono i chiamanti | `listPage` accoppia per **posizione** due liste separate (chiavi e dimensioni): con l'ETag, un oggetto senza ETag sposterebbe tutti i successivi e un contenuto risulterebbe «certificato» sulla chiave sbagliata | `listPage` resta identico nell'interpretazione; la richiesta si estrae in `fetchListPageXML` (una sola richiesta, stesse correzioni di BUG-8); per l'inventario un parser nuovo **blocco `<Contents>` per blocco** (`S3Syncer.parseListPage`). `S3Listing` non cambia | Estendere il `zip` di `listPage` |
| S10 | (non detto) | `LibraryIndexer` si ferma a ogni smontaggio di qualunque volume | L'inventario si ferma solo se si smonta **l'SSD o l'HDD** (o se macOS non dice quale): un giro dura decine di minuti, espellere una chiavetta non deve buttarlo | Fermarsi a ogni smontaggio |
| S11 | (non detto) | — | «Presente» = visto **nell'ultimo giro**. Un giro interrotto lascia gli archivi non raggiunti «non letti»: mai numeri di un giro vecchio mescolati a quelli di oggi | Tenere l'ultimo giro completo per gli archivi non raggiunti |

### Decisioni da confermare (con la raccomandazione)

- **D1 — Granularità dell'«incompleto»: per archivio (raccomandata, è la lettera della spec).** Un solo file illeggibile sull'HDD rende l'HDD incompleto e sospende tutte le mancanze «dall'HDD» (finiscono in ⏳), e la finestra dice quanti file e perché. Alternativa più fine: sospendere solo le mancanze di contenuti con la stessa dimensione del file illeggibile — più codice e un ragionamento più difficile da verificare, per un caso che sull'HDD (APFS) non è mai stato osservato.
- **D2 — Ordine delle letture: in sequenza SSD → HDD → Cubbit (raccomandato).** In parallelo SSD e HDD si risparmierebbe tempo (dischi diversi) ma avanzamento, interruzione e test diventano più complicati. **Misurato il 2026-09-26 su questo Mac (compilato -O):** SHA256 2.300 MiB/s, MD5 689 MiB/s, `ContentHasher` completo **~300 MiB/s**: il primo giro sull'SSD (390,6 GB) costa ~22 minuti di solo calcolo, quindi è limitato più dalla CPU che dal disco; l'HDD non è misurato. Il primo giro completo dura verosimilmente **fra 45 e 90 minuti**; i successivi rileggono solo i file cambiati.
- **D3 — La finestra mostra al massimo 300 voci per categoria**, dicendo sempre «Qui ne vedi 300 su N» (mai un elenco tagliato in silenzio). L'elenco completo resta nel database per i progetti 2-4.

---

## Global Constraints

- Perimetro: **solo foto e video**, `IndexableKind.of(url:) != .notIndexable`; stesse esclusioni dei dischi (`.skipsHiddenFiles` + `LibraryExclusions`) applicate anche alle chiavi di Cubbit (`InventoryPerimeter.includesS3Key`).
- Parti da **64 MiB = `S3Syncer.multipartChunkSize` = 67.108.864 byte**. ETag a pezzi **solo per `size > 64 MiB`**, la stessa condizione di `S3Syncer.upload` (`if size > Self.multipartChunkSize`, riga 7185): un file di **esattamente** 64 MiB è un caricamento unico e il suo ETag è l'MD5.
- **Sola lettura su ogni archivio.** Nessuna `removeItem`/`moveItem`/`copyItem`/`trashItem` nuova, nessuna scrittura su SSD/HDD, nessuna richiesta S3 oltre a `ListObjectsV2` (GET) e al `checkReachable` già esistente. Le sole scritture sono righe nel SQLite sotto Application Support.
- Lettura dei file **POSIX a blocchi** (`open`/`read`/`close`, buffer da 1 MiB riusato) in `ContentHasher.digestFile`; **mai** `FileHandle.readData`.
- **Fuori dal main**: ogni tipo di fondo è `nonisolated` con accanto la riga che dice perché è sicuro; ogni funzione di fondo `async` è `@concurrent`. Zero warning (`SWIFT_TREAT_WARNINGS_AS_ERRORS` in Debug).
- **Salvataggio a lotti** (200 righe per SSD/HDD, una pagina ≤ 1.000 oggetti per Cubbit), ognuno in una transazione: un inventario parziale è valido in ogni istante (ADR-0002).
- **Schema sconosciuto = ricostruisci** (ADR-0002): `schemaVersion = 2`; dalla 1 si sale tenendo `entries` (S3); qualunque altra versione butta tutto.
- **Incompleto ≠ assente**: «manca da X» solo se `InventoryArchiveState.complete` per X; «presente» = visto nell'ultimo giro; un disco scollegato non è mai un disco vuoto.
- Precedenza **❗ > 🔎 > ⚠️ > ✅**, residuo ⏳ (S4).
- **Mutua esclusione** con backup, lettura dell'elenco, spostamento nel Cestino, annullamento: parametro `isInventorying` **senza default** nei cinque cancelli esistenti, più `InventoryStartGate` per il verso opposto.
- Progresso **diradato alla fonte** (`ProgressThrottle`, ~10/s) nello scanner; una notifica per pagina da Cubbit.
- Testi a schermo **solo** in `InventoryStatus`/`InventoryStartGate`, in italiano semplice, senza gergo («hash», «impronta», «ETag», «MD5», «indice», «scansione», «bucket», «cache»).
- Nuova `Window` scene **gated** da `AuthGateManager` e con `.restorationBehavior(.disabled)`.
- Numerazione: **ADR-0015**, **ROADMAP #44**.
- Tutto il codice in **`AppBackupFoto/ContentView.swift`** (convenzione del progetto).
- Test in **`AppBackupFotoTests/`**, ogni file nuovo registrato in `AppBackupFoto.xcodeproj/project.pbxproj` nei **4 punti** (`PBXBuildFile`, `PBXFileReference`, gruppo `11123F514533138A989F11C4 /* AppBackupFotoTests */`, `PBXSourcesBuildPhase` `62FE197CBAC2C2E908580583`). Si verifica sempre il totale `Executed N tests`, mai il solo `** TEST SUCCEEDED **`.
- Un commit per task, messaggio in italiano, **mai `git push`**.

---

## Mappa dei file e dei tipi

**`AppBackupFoto/ContentView.swift`** (righe verificate a `bf9fd99`, ~14.800 righe; si ritrova tutto con `grep -n`):

| Dove | Cosa | Task |
| :--- | :--- | :--- |
| dopo `nonisolated func sha256(of url: URL)` (5903-5905), prima di `// MARK: - BookmarkManager` (5907) | nuovi `ContentDigest`, `ContentHasher`, `ContentReadOutcome`, `ContentHasher.digestFile` | 1 |
| `S3Syncer.multipartChunkSize` (6754) | diventa `nonisolated static let` | 1 |
| `S3Syncer.listPage` (7129-7160) | estratta `fetchListPageXML`; interpretazione invariata | 2 |
| `S3Syncer.xmlDecode` (7598) | diventa `nonisolated static func` | 2 |
| dentro `S3Syncer`, dopo `xmlAll` (7630-7637) | nuovi `S3ObjectInfo`, `S3ListPage`, `parseListPage` | 2 |
| dopo la `}` di `S3Syncer` (7638), prima di `// MARK: - Spazio usato su Cubbit` (7640) | nuovi `S3ETag`, `S3ETagMatcher` | 3 |
| `LibraryIndexStore` (4313-4821): `schemaVersion` (4314), `createSchemaIfNeeded` (4535-4566), dopo `newestHashedAt()` (4647-4649), dopo `newestHashedAtUnsynchronized` (4811-4820) | schema 2, tabelle e API dell'inventario | 4 |
| **regione R**: subito prima di `// MARK: - Testi e regole della card "Foto gia' salvate"` (5280) | in quest'ordine: modello (T4), `InventoryScanReport`/`InventoryScanner` (T5), `CubbitReadReport`/`InventoryPerimeter`/`InventoryCubbitReader` (T6), categorie/`InventoryClassifier`/`InventorySummary` (T7), `InventoryProgress`/`InventoryRefreshOutcome`/`InventoryRefresh`/`InventoryStartGate` (T8), `InventoryStatus` (T9). Ogni blocco si aggiunge **dopo** il precedente, sempre prima di quella riga `MARK` | 4-9 |
| `DuplicatesStatus.trashDisabledReason` (3652), `.undoDisabledReason` (3686), `JobStartGate` (5445), `LibraryIndexCommandGate` (5469) | parametro `isInventorying` | 10 |
| `BackupRunner`: `beginDuplicateTrashing` (8711), `beginTrashRestore` (8738), chiamate ai cancelli (8808, 8912, 9257, 9312, 10113), osservatore di smontaggio in `init` (9103-9111), `resetLibraryIndex` (9308), nuova sezione prima del commento `` // `autoRefreshLibraryIndexIfEnabled()` e `` (9345) | stato e comandi dell'inventario | 10 |
| scene (`Window("Doppioni"…)` 191-199), `HamburgerPanel` (riga «Foto» 12685-12687), `LibraryIndexCard.commandsDisabledReason` (13434), `confirmReset` (13628-13636), `DuplicatesView` (14005, 14028), fine file (14801) | finestra, voce di menu, testo di conferma, `InventoryView` | 10-11 |

**`AppBackupFotoTests/`** — nuovi: `ContentHasherTests` (15), `S3ListPageParserTests` (11), `S3ETagMatcherTests` (16), `InventoryStoreTests` (19), `InventoryScannerTests` (12), `InventoryCubbitReaderTests` (7), `InventoryClassifierTests` (30), `InventoryRefreshTests` (10), `InventoryStatusTests` (15). Estesi: `MainThreadIsolationTests` (14 → 19), `JobStartGateTests` (9 → 10), `LibraryIndexStatusTests` (37 → 39), `DuplicatesStatusTests` (55 → 57). **Totale atteso: B + 145** (con B = 861, **1.006**).

**Docs:** `Docs/adr/0015-…md` (nuovo), `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`.

### ID per il pbxproj (verificati assenti a `bf9fd99` con `grep -c`)

| File | `PBXFileReference` | `PBXBuildFile` |
| :--- | :--- | :--- |
| `ContentHasherTests.swift` | `D18DDA4A93921BC5B9FA2F80` | `DEE9C0ABADE0FF0EB6289907` |
| `S3ListPageParserTests.swift` | `5FB823EB40B78EF9925B9164` | `09FC66E10978B41A9187FF38` |
| `S3ETagMatcherTests.swift` | `E23C952846EB4FAAB758CC44` | `496E00D79739E3114DC87822` |
| `InventoryStoreTests.swift` | `B03981ED6C74915210F086AB` | `8051CD87C86D4474EA31B719` |
| `InventoryScannerTests.swift` | `13740CD609C3CF49E0834FEE` | `EE37493DA8873EFB121F2062` |
| `InventoryCubbitReaderTests.swift` | `580B6ADF04D6871266BBF239` | `C83C8DBDEA1EFF04AD9B6E40` |
| `InventoryClassifierTests.swift` | `E1EB0DF8A234B0B8A0802230` | `571CCCE2BF5254CBC5C95301` |
| `InventoryRefreshTests.swift` | `C08CBD0B92948BEFEE0428F4` | `D32A3EFFFFA66AAE2C29C8E6` |
| `InventoryStatusTests.swift` | `410F77B6DAC6CC5324775DA3` | `51437C0FB531B995488AA29D` |

Per ogni file le quattro righe hanno questa forma (esempio con `ContentHasherTests`; i tab sono quelli delle righe vicine):

```
/* sezione PBXBuildFile */
		DEE9C0ABADE0FF0EB6289907 /* ContentHasherTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = D18DDA4A93921BC5B9FA2F80 /* ContentHasherTests.swift */; };
/* sezione PBXFileReference */
		D18DDA4A93921BC5B9FA2F80 /* ContentHasherTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ContentHasherTests.swift; sourceTree = "<group>"; };
/* children del gruppo 11123F514533138A989F11C4 /* AppBackupFotoTests */ */
				D18DDA4A93921BC5B9FA2F80 /* ContentHasherTests.swift */,
/* files della fase 62FE197CBAC2C2E908580583 /* Sources */ */
				DEE9C0ABADE0FF0EB6289907 /* ContentHasherTests.swift in Sources */,
```

Prima di usarli: `grep -c <ID> AppBackupFoto.xcodeproj/project.pbxproj` deve dare `0`. Se il piano `s3-upload-failures-visible` è stato unito nel frattempo, le stesse quattro sezioni avranno righe in più: si tengono tutte.

---

## Comandi di build e test

**Precondizione di ogni build/test:** nessun backup in corso nell'app di Enrico (il target di test ha `TEST_HOST` = l'app). `SP` = una cartella di lavoro sotto `/private/tmp/claude-501/`, mai il `derivedDataPath` di default.

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=/private/tmp/claude-501/inventory-impl
# build pulita (i warning li ristampa solo una build pulita)
rm -rf $SP/dd && xcodebuild -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l      # atteso 0, sempre
# una classe
xcodebuild test -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd -only-testing:AppBackupFotoTests/<Classe> 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -5
# suite completa
xcodebuild test -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests" $SP/test.log | tail -1
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`**, mai col numero di riga: quelli citati valgono per `bf9fd99` e si spostano dopo ogni task.
2. **Il codice dei Task 1-9 si copia così com'è**: è stato compilato ed eseguito dall'Architect. Se qualcosa non compila nel target vero, **fermati e rimanda all'Architect**: non adattarlo a tentativi.
3. **Zero warning.** Un solo rimedio è autorizzato in anticipo: se un riferimento a una funzione statica `@MainActor` passata come valore (`map(Tipo.funzione)`) dà «call to main actor-isolated … in a synchronous nonisolated context», si riscrive come chiusura (`map { Tipo.funzione($0) }`). Ogni altro warning di isolamento: fermati.
4. **Asserzioni esistenti.** Nel Task 10 si aggiunge `isInventorying: false` alle chiamate esistenti dei cinque cancelli nei test: cambiare la firma è ammesso, cambiare **cosa asseriscono** no.
5. **Ogni task dichiara il mutante che deve morire.** Quelli segnati «(verificato)» sono stati provati dall'Architect sul prototipo.
6. **Commit solo con build pulita (0 warning) e suite verde**, conteggio uguale all'atteso. Messaggio in italiano, chiuso da:
   ```
   Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
   ```

---

### Task 0: branch, baseline, ADR-0015

**Files:** `Docs/adr/0015-l-inventario-certifica-per-contenuto-e-un-archivio-letto-a-meta-non-rende-assente-niente.md` (nuovo), `Docs/superpowers/plans/2026-09-26-cross-store-inventory.md` (questo piano).

- [ ] **Step 1:** `git status --short`: l'unico file non tracciato ammesso è `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md` (di un altro piano: **non** si committa qui). `git switch -c feature/cross-store-inventory main`; `git rev-parse --short HEAD` → `bf9fd99` o un discendente (in quel caso rifai i `grep -n` delle ancore della mappa e fermati se una manca).
- [ ] **Step 2:** Chiedi a Enrico il via libera («nessun backup in corso nell'app?»). Senza risposta esplicita non si lancia nessun test.
- [ ] **Step 3:** Build pulita: 0 warning. Suite completa: `B` = `Executed N tests`, 0 fallimenti (atteso 861).
- [ ] **Step 4:** Verifica che Enrico abbia risposto su S1-S11 e D1-D3. Se una risposta è diversa dalla «Proposta», **fermati e rimanda all'Architect**.
- [ ] **Step 5:** Scrivi l'ADR con questo testo (aggiungi in fondo, alla sezione «Risposte di Enrico», le risposte ricevute):

```markdown
# ADR-0015 — L'inventario certifica per contenuto, e un archivio letto a metà non rende assente niente

**Data:** 2026-09-26
**Stato:** Accettata

## Contesto

Enrico vuole arrivare a una copia sola di ogni foto per archivio (SSD, HDD, Cubbit), mettere al sicuro le foto che stanno in un posto solo e togliere le ridondanze anche da HDD e Cubbit. È stato diviso in quattro progetti; il primo è l'inventario, in sola lettura, su cui gli altri tre decideranno copie e cancellazioni (spec `Docs/superpowers/specs/2026-09-26-cross-store-inventory-design.md`).

Fatti misurati il 2026-09-26: su 219.877 oggetti Cubbit (529,9 GB), 219.629 hanno un ETag uguale all'MD5 del contenuto; i restanti 248 (tutti ≥ 64 MB) sono stati caricati a pezzi da 64 MiB e il loro ETag (`md5(md5(parte1)‖…‖md5(parteN))-N`) si ricalcola dal file sull'SSD (`ASUS/Elba/FILE0056.MOV` → `fc22b3a263f8c63ba9d9f8fbd7a0b713-4` da entrambe le parti). Il bucket non ha versioni.

## Opzioni valutate

- **A. Confronto per percorso e dimensione** (come `rclone check --size-only`). Scartata: non dice niente del contenuto.
- **B. Scaricare da Cubbit e rihashare.** Scartata: ~530 GB di download a ogni giro.
- **C. Confronto per contenuto con l'ETag, senza scaricare (scelta).** Una lettura per file locale produce SHA256, MD5 ed ETag a pezzi da 64 MiB (`ContentHasher`); un oggetto Cubbit è *certificato* solo se il suo ETag coincide con quello di un file letto della stessa dimensione.
- **D. Un secondo database.** Scartata da Enrico (decisione 4): si estende lo stesso SQLite dell'elenco.

## Decisione e motivo

**Cosa l'inventario certifica:** che un contenuto (SHA256) è presente su SSD e/o HDD perché letto per intero nell'ultimo giro; che un oggetto Cubbit contiene quello stesso contenuto, se il suo ETag (parte unica, `-1`, o `-N` con parti da 64 MiB) coincide con quello di un file locale della stessa dimensione; che un oggetto Cubbit a parte unica senza file locale corrispondente è un contenuto presente **solo** su Cubbit, riconosciuto dal suo MD5.

**Cosa non certifica:** un oggetto `-N` caricato con parti di altra dimensione, o con un ETag in un formato non riconosciuto, è *non certificabile* — mai «certificato» per ipotesi — e finisce in ❗ insieme alla foto che sta allo stesso percorso sugli altri archivi. L'inventario è una cache (ADR-0002): prima di ogni copia o cancellazione dei progetti 2-4 il file va riletto dal disco (ADR-0005).

**Incompleto ≠ assente.** Un archivio è *completo* solo se l'ultima lettura è arrivata in fondo senza problemi: nessun file o cartella illeggibile, disco mai sparito, nessuna interruzione, lista di Cubbit finita davvero. «Manca da X» si dice solo se X è completo. «Presente» vuol dire «visto nell'ultimo giro». Un contenuto che mancherebbe solo da archivi incompleti non entra in ⚠️ né in 🔎: resta in «⏳ Non si può ancora dire». Un disco scollegato non è mai un disco vuoto.

**Precedenza:** ❗ > 🔎 > ⚠️ > ✅, residuo ⏳.

**Scelte d'implementazione, con il perché:**
- `InventoryScanner` è nuovo e non `LibraryIndexer` riusato: stessa traversata con le stesse funzioni condivise, e un test di parità che fallisce se i due vedono file diversi. Generalizzare `LibraryIndexer` avrebbe toccato il componente più protetto del progetto.
- La lettura è `ContentHasher.digestFile` (POSIX, buffer da 1 MiB, `fstat` prima/dopo), non `S3Syncer.readFileInChunks`, che è isolato al main e copia ogni parte in un `Data` da 64 MiB.
- Schema 2: dalla versione 1 si sale tenendo l'elenco (schema noto); ogni altra versione ricostruisce tutto.
- La lista di Cubbit per l'inventario si legge blocco `<Contents>` per blocco: accoppiare chiavi ed ETag per posizione metterebbe l'ETag di un oggetto su un altro.

**Cosa si accetta di perdere:** il primo giro rilegge per intero SSD e HDD (misurato ~300 MiB/s di calcolo: decine di minuti per disco); un solo file illeggibile sospende le mancanze da tutto il suo archivio; «Svuota l'elenco» svuota anche l'inventario; oggetti Cubbit caricati da altri strumenti con parti diverse restano ❗ finché non si scaricano (fuori da questo progetto).

**Per riaprirla** serve un argomento nuovo: per esempio un bucket con versioni o checksum SHA256 lato server (che renderebbe superfluo l'ETag), o una misura che mostri molti oggetti non certificabili.

## Risposte di Enrico (S1-S11, D1-D3)

<!-- riportare qui, una riga per punto -->
```

- [ ] **Step 6:** Commit (solo documentazione: l'ADR e questo piano):
  ```
  ADR-0015 e piano: inventario certificato su SSD, HDD e Cubbit

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---
### Task 1: `ContentHasher` — una lettura, tre impronte

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `S3Syncer.multipartChunkSize` (riga 6754); nuovo codice subito dopo `nonisolated func sha256(of url: URL) -> String? { … }` (5903-5905), prima di `// MARK: - BookmarkManager` (5907).
- Create: `AppBackupFotoTests/ContentHasherTests.swift` (registrarlo nei 4 punti).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda, prima della `}` finale, riga 230).

**Interfaces:**
- Consumes: `S3Syncer.multipartChunkSize` (resa `nonisolated`), CryptoKit `SHA256`, `Insecure.MD5` (`import CryptoKit` già presente, riga 7).
- Produces:
  - `nonisolated struct ContentDigest: Equatable, Sendable { let size: Int64; let sha256: String; let md5: String; let multipartETag: String? }`
  - `nonisolated struct ContentHasher { let partSize: Int; private(set) var byteCount: Int64; init(partSize: Int = S3Syncer.multipartChunkSize); mutating func update(_ bytes: UnsafeRawBufferPointer); mutating func update(_ data: Data); func finalize() -> ContentDigest; static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 }`
  - `nonisolated enum ContentReadOutcome: Equatable, Sendable { case digest(ContentDigest), unreadable, changedWhileReading, cancelled }`
  - `extension ContentHasher { nonisolated static let readBufferSize: Int; nonisolated static func digestFile(at url: URL, partSize: Int = S3Syncer.multipartChunkSize, isCancelled: () -> Bool = { false }) -> ContentReadOutcome }`

**Valori di riferimento** (byte `i` = `(i*31 + 7) % 251`; calcolati con `python3` `hashlib`, ricontrollati con `shasum -a 256` e `md5` il 2026-09-26; ETag = md5 della concatenazione degli md5 binari delle parti, più `-N`):

| byte | SHA256 | MD5 | ETag a pezzi (64 MiB) |
| ---: | :--- | :--- | :--- |
| 0 | `e3b0c442…7852b855` | `d41d8cd98f00b204e9800998ecf8427e` | — |
| 1 | `ca358758…005ee879` | `89e74e640b8c46257a29de0616794d5d` | — |
| 1.000 | `008549d9…956d32ef` | `e722bbb0c3185d08f1a31567e66a825b` | — |
| 67.108.864 (64 MiB esatti) | `d7279ae9…d214af3c` | `1c81167936a46883a15d0fe49895453f` | — (parte unica) |
| 67.108.865 | `e4441760…2e397f40` | `9c800b6accf6f26be7e8684d46ffdedb` | `96aa53ed4132d7e2986467263954caad-2` |
| 134.230.073 (2×64 MiB + 12.345) | `bb7eb580…d1ca4023` | `8ea3de5a355296de9f08a2091e627443` | `e260e09492e358dfcf24368dcb3b0d4f-3` |

(Gli SHA256 completi sono nel test.)

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/ContentHasherTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `ContentHasher` (ROADMAP #44, ADR-0015): una lettura, tre impronte — SHA256, MD5 e l'ETag
/// a pezzi da 64 MiB che Cubbit assegna ai file caricati in piu' parti.
///
/// I valori attesi NON sono stati calcolati con questo codice: vengono da `python3`
/// (`hashlib.sha256`/`hashlib.md5`, ETag = md5 della concatenazione degli md5 binari delle
/// parti, piu' `-N`) e sono stati ricontrollati con `shasum -a 256` e `md5` sugli stessi byte,
/// il 2026-09-26. I byte sono deterministici: il byte i vale (i*31 + 7) % 251.
final class ContentHasherTests: XCTestCase {
    private let mib64 = 64 * 1024 * 1024
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentHasherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// n byte con il byte i = (i*31 + 7) % 251. La sequenza ha periodo 251, quindi si
    /// costruisce raddoppiando un blocco da 251 byte (veloce anche per 128 MiB in Debug).
    static func pattern(_ n: Int) -> Data {
        var block = Data((0..<251).map { UInt8(($0 * 31 + 7) % 251) })
        while block.count < n { block.append(block) }
        return Data(block.prefix(n))
    }

    private func digest(_ data: Data, partSize: Int = S3Syncer.multipartChunkSize, chunk: Int? = nil) -> ContentDigest {
        var h = ContentHasher(partSize: partSize)
        if let chunk {
            var i = 0
            while i < data.count {
                let end = min(data.count, i + chunk)
                h.update(data.subdata(in: i..<end))
                i = end
            }
        } else {
            h.update(data)
        }
        return h.finalize()
    }

    // MARK: - Valori di riferimento

    func testEmpty() {
        let d = digest(Data())
        XCTAssertEqual(d.size, 0)
        XCTAssertEqual(d.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(d.md5, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertNil(d.multipartETag)
    }

    func testOneByte() {
        let d = digest(Self.pattern(1))
        XCTAssertEqual(d.sha256, "ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879")
        XCTAssertEqual(d.md5, "89e74e640b8c46257a29de0616794d5d")
        XCTAssertNil(d.multipartETag)
    }

    func testThousandBytes() {
        let d = digest(Self.pattern(1000))
        XCTAssertEqual(d.size, 1000)
        XCTAssertEqual(d.sha256, "008549d94fa71e7a0a483d84380d05a923a4b18e79ba1f8a8ddac923956d32ef")
        XCTAssertEqual(d.md5, "e722bbb0c3185d08f1a31567e66a825b")
        XCTAssertNil(d.multipartETag)
    }

    /// Il caso limite che decide tutto: `S3Syncer.upload` passa al caricamento a pezzi solo con
    /// `size > multipartChunkSize`. Esattamente 64 MiB e' quindi un caricamento UNICO, e il suo
    /// ETag su Cubbit e' l'MD5: qui non deve esserci nessun ETag a pezzi.
    func testExactly64MiB_isASinglePart() {
        let d = digest(Self.pattern(mib64))
        XCTAssertEqual(d.size, Int64(mib64))
        XCTAssertEqual(d.sha256, "d7279ae9528c7908d99a3c0c84b077e4b5ed515d32fee94847048187d214af3c")
        XCTAssertEqual(d.md5, "1c81167936a46883a15d0fe49895453f")
        XCTAssertNil(d.multipartETag, "64 MiB esatti: Cubbit li riceve con un caricamento unico")
    }

    /// Un byte in piu': due parti, la seconda da 1 byte.
    func test64MiBPlusOne_isTwoParts() {
        let d = digest(Self.pattern(mib64 + 1))
        XCTAssertEqual(d.sha256, "e44417605ed97d14de38fdd4561c81e3f8329f4a6621144e31801c992e397f40")
        XCTAssertEqual(d.md5, "9c800b6accf6f26be7e8684d46ffdedb")
        XCTAssertEqual(d.multipartETag, "96aa53ed4132d7e2986467263954caad-2")
    }

    func testTwoPartsAndABit_isThreeParts() {
        let d = digest(Self.pattern(2 * mib64 + 12_345))
        XCTAssertEqual(d.size, Int64(2 * mib64 + 12_345))
        XCTAssertEqual(d.sha256, "bb7eb580b9968c7b39adcfcd02c9c71756f3b0744f0f789584107344d1ca4023")
        XCTAssertEqual(d.md5, "8ea3de5a355296de9f08a2091e627443")
        XCTAssertEqual(d.multipartETag, "e260e09492e358dfcf24368dcb3b0d4f-3")
    }

    /// Le parti si contano sui byte, non sulle letture: pezzi da 1.000.003 byte (che non
    /// dividono 64 MiB) devono dare lo stesso ETag. E' il caso reale di `read()` che restituisce
    /// meno byte di quanti ne ha chiesti.
    func testHowTheBytesArrive_doesNotChangeTheResult() {
        let data = Self.pattern(mib64 + 1)
        XCTAssertEqual(digest(data, chunk: 1_000_003), digest(data))
    }

    /// Parti piccole per vedere i confini senza file enormi (valori da `python3`, parti da 4).
    func testSmallPartSize_boundaries() {
        XCTAssertNil(digest(Self.pattern(4), partSize: 4).multipartETag, "una parte piena sola: caricamento unico")
        XCTAssertEqual(digest(Self.pattern(8), partSize: 4).multipartETag, "3060bef1713675e57187df2d94b5913e-2")
        XCTAssertEqual(digest(Self.pattern(9), partSize: 4).multipartETag, "038a681c2984a3fcb1f6eac9f2bc92c0-3")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4).multipartETag, "31c509ee7df935ddc35518ca34642cf7-3")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4, chunk: 1).multipartETag,
                       "31c509ee7df935ddc35518ca34642cf7-3", "un byte alla volta, stesso risultato")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4, chunk: 3).multipartETag,
                       "31c509ee7df935ddc35518ca34642cf7-3")
    }

    /// La dimensione delle parti e' quella con cui l'app carica su Cubbit: una sola fonte.
    func testDefaultPartSize_isTheUploadPartSize() {
        XCTAssertEqual(ContentHasher().partSize, S3Syncer.multipartChunkSize)
        XCTAssertEqual(S3Syncer.multipartChunkSize, 67_108_864)
    }

    // MARK: - Lettura da file

    func testDigestFile_matchesTheReferenceValues() throws {
        let url = tmp.appendingPathComponent("grande.mov")
        try Self.pattern(2 * mib64 + 12_345).write(to: url)
        guard case .digest(let d) = ContentHasher.digestFile(at: url) else {
            return XCTFail("un file leggibile deve dare le impronte")
        }
        XCTAssertEqual(d.sha256, "bb7eb580b9968c7b39adcfcd02c9c71756f3b0744f0f789584107344d1ca4023")
        XCTAssertEqual(d.md5, "8ea3de5a355296de9f08a2091e627443")
        XCTAssertEqual(d.multipartETag, "e260e09492e358dfcf24368dcb3b0d4f-3")
    }

    func testDigestFile_emptyFile() throws {
        let url = tmp.appendingPathComponent("vuoto.jpg")
        try Data().write(to: url)
        XCTAssertEqual(ContentHasher.digestFile(at: url), .digest(digest(Data())))
    }

    func testDigestFile_missingFile_isUnreadable() {
        XCTAssertEqual(ContentHasher.digestFile(at: tmp.appendingPathComponent("non-c-e.jpg")), .unreadable)
    }

    func testDigestFile_withoutPermission_isUnreadable() throws {
        let url = tmp.appendingPathComponent("chiuso.jpg")
        try Self.pattern(1000).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertEqual(ContentHasher.digestFile(at: url), .unreadable)
    }

    /// Il file cambia dimensione mentre lo si legge: le impronte non valgono niente. Il
    /// troncamento avviene alla prima domanda "devo fermarmi?", cioe' dopo il primo `fstat`
    /// e prima della prima lettura — deterministico, nessuna corsa.
    func testDigestFile_fileTruncatedWhileReading_isChanged() throws {
        let url = tmp.appendingPathComponent("cambia.jpg")
        try Self.pattern(5_000_000).write(to: url)
        var truncated = false
        let outcome = ContentHasher.digestFile(at: url, isCancelled: {
            if !truncated {
                truncated = true
                if let fh = try? FileHandle(forWritingTo: url) { try? fh.truncate(atOffset: 6); try? fh.close() }
            }
            return false
        })
        XCTAssertTrue(truncated)
        XCTAssertEqual(outcome, .changedWhileReading)
    }

    func testDigestFile_cancelled() throws {
        let url = tmp.appendingPathComponent("fermo.jpg")
        try Self.pattern(1000).write(to: url)
        XCTAssertEqual(ContentHasher.digestFile(at: url, isCancelled: { true }), .cancelled)
    }
}
```

e aggiungi in coda a `MainThreadIsolationTests` (prima della `}` finale):

```swift
    // MARK: - Inventario (ROADMAP #44)

    func testContentHasherDigestFile_runsWithoutTheMainThread() throws {
        let url = tmp.appendingPathComponent("a.jpg")
        try Data("uno".utf8).write(to: url)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = ContentHasher.digestFile(at: url)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "ContentHasher.digestFile ha avuto bisogno del main thread.")
    }
```

Registra `ContentHasherTests.swift` nel pbxproj (ID `D18DDA4A93921BC5B9FA2F80` / `DEE9C0ABADE0FF0EB6289907`).

- [ ] **Step 2: esegui e verifica che fallisca.**
  `xcodebuild test -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd -only-testing:AppBackupFotoTests/ContentHasherTests 2>&1 | grep -E "error:" | head -3`
  Atteso: `error: cannot find 'ContentHasher' in scope` (e `** TEST FAILED **`).

- [ ] **Step 3: implementa.** In `S3Syncer` sostituisci la riga 6754

```swift
    static let multipartChunkSize = 64 * 1024 * 1024
```

con

```swift
    // `nonisolated`: una costante; la legge anche `ContentHasher`, fuori dal main (ROADMAP #44).
    nonisolated static let multipartChunkSize = 64 * 1024 * 1024
```

Poi inserisci dopo `sha256(of:)`:

```swift

// MARK: - ContentHasher: una lettura, tre impronte (ROADMAP #44, ADR-0015)

/// Le tre impronte di un contenuto.
// `nonisolated`: value type senza stato, prodotto e letto fuori dal main.
nonisolated struct ContentDigest: Equatable, Sendable {
    let size: Int64
    /// Quella dell'elenco dei Doppioni (ADR-0001): e' l'identita' del contenuto.
    let sha256: String
    /// L'ETag che Cubbit da' a un file caricato in un colpo solo.
    let md5: String
    /// L'ETag che Cubbit da' a un file caricato a pezzi da 64 MiB:
    /// `md5(md5(parte1) ‖ … ‖ md5(parteN))-N`. `nil` per i file fino a 64 MiB COMPRESI, perche'
    /// `S3Syncer.upload` passa ai pezzi solo con `size > multipartChunkSize`: un file di
    /// esattamente 64 MiB va su con un caricamento unico, e il suo ETag e' l'MD5.
    let multipartETag: String?
}

/// Accumula SHA256, MD5 e l'MD5 di ogni parte da `partSize` byte mentre i byte arrivano, in
/// UNA passata. Puro: non sa da dove vengono i byte (un file, un `Data` in un test). Le parti
/// si contano sui byte, non sulle letture: un `read()` che restituisce meno byte di quanti
/// chiesti non sposta i confini.
// `nonisolated`: value type; ogni istanza vive sullo stack del thread che legge.
nonisolated struct ContentHasher {
    let partSize: Int
    private var sha = SHA256()
    private var whole = Insecure.MD5()
    private var part = Insecure.MD5()
    private var partFill = 0
    private var partDigests = Data()
    private var partCount = 0
    private(set) var byteCount: Int64 = 0

    /// `partSize` e' iniettabile solo per i test (confini visibili con pochi byte); in
    /// produzione e' sempre la dimensione delle parti con cui l'app carica su Cubbit.
    init(partSize: Int = S3Syncer.multipartChunkSize) {
        precondition(partSize > 0, "partSize deve essere positivo")
        self.partSize = partSize
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        sha.update(bufferPointer: bytes)
        whole.update(bufferPointer: bytes)
        byteCount += Int64(bytes.count)
        var offset = 0
        while offset < bytes.count {
            let n = min(bytes.count - offset, partSize - partFill)
            part.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + n)]))
            partFill += n
            offset += n
            if partFill == partSize { closePart() }
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    private mutating func closePart() {
        partDigests.append(contentsOf: part.finalize())
        partCount += 1
        part = Insecure.MD5()
        partFill = 0
    }

    func finalize() -> ContentDigest {
        var copy = self
        if copy.partFill > 0 { copy.closePart() }
        let etag: String? = byteCount > Int64(partSize)
            ? Self.hex(Insecure.MD5.hash(data: copy.partDigests)) + "-\(copy.partCount)"
            : nil
        return ContentDigest(size: byteCount, sha256: Self.hex(sha.finalize()),
                             md5: Self.hex(whole.finalize()), multipartETag: etag)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Esito della lettura di un file per l'inventario.
nonisolated enum ContentReadOutcome: Equatable, Sendable {
    case digest(ContentDigest)
    /// Non si apre, o `read()` fallisce (permessi, EIO, disco scollegato a meta').
    case unreadable
    /// `fstat` prima e dopo, o i byte letti, non coincidono: il file si e' mosso sotto di noi.
    case changedWhileReading
    case cancelled
}

extension ContentHasher {
    /// 1 MiB, riusato per tutto il file: la memoria resta costante anche su un video da 40 GB.
    nonisolated static let readBufferSize = 1 << 20

    /// Legge `url` una volta sola e restituisce le tre impronte.
    ///
    /// Stesso schema di `sha256Measured`, e per le stesse ragioni: I/O POSIX a basso livello
    /// (`open`/`read`/`close`, buffer riusato), MAI `FileHandle.readData` — e' il bug di memoria
    /// da 41 GB (`.claude/rules/architecture.md`); dimensione misurata sullo stesso descrittore
    /// prima e dopo, perche' `URL.resourceValues` serve valori in cache. NON usa
    /// `S3Syncer.readFileInChunks`, che segue lo stesso principio ma e' un metodo `async` di un
    /// tipo `@MainActor` (girerebbe sul main, ADR-0006) e copia ogni parte da 64 MiB in un
    /// `Data` nuovo (vedi ADR-0015).
    ///
    /// `isCancelled` si chiede prima di ogni blocco da 1 MiB: «Interrompi» risponde anche a meta'
    /// di un file grande.
    nonisolated static func digestFile(at url: URL, partSize: Int = S3Syncer.multipartChunkSize,
                                       isCancelled: () -> Bool = { false }) -> ContentReadOutcome {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else { return .unreadable }

        var hasher = ContentHasher(partSize: partSize)
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while true {
            if isCancelled() { return .cancelled }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, readBufferSize) }
            if n < 0 { return .unreadable }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }

        var after = stat()
        guard fstat(fd, &after) == 0 else { return .unreadable }
        guard before.st_size == after.st_size, hasher.byteCount == Int64(after.st_size) else {
            return .changedWhileReading
        }
        return .digest(hasher.finalize())
    }
}
```

- [ ] **Step 4: esegui i test.**
  `… -only-testing:AppBackupFotoTests/ContentHasherTests` → `Executed 15 tests, with 0 failures`.
  `… -only-testing:AppBackupFotoTests/MainThreadIsolationTests` → `Executed 15 tests, with 0 failures`.
- [ ] **Step 5:** build pulita (0 warning) + suite completa: `Executed B+16 tests` (877), 0 fallimenti.
- [ ] **Mutante che deve morire:** `byteCount > Int64(partSize)` → `>=` (verificato: muoiono `testExactly64MiB_isASinglePart` e `testSmallPartSize_boundaries`); `partFill == partSize` spostato fuori dal ciclo (muore `testHowTheBytesArrive_doesNotChangeTheResult`).
- [ ] **Step 6: commit.**
  ```
  Inventario, task 1: ContentHasher calcola SHA256, MD5 ed ETag a pezzi in una lettura

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 2: la lista di Cubbit con l'ETag, oggetto per oggetto

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `S3Syncer.listPage` (7129-7160), `S3Syncer.xmlDecode` (7598), nuovo codice dentro `S3Syncer` dopo `xmlAll` (7630-7637), prima della `}` della classe (7638).
- Create: `AppBackupFotoTests/S3ListPageParserTests.swift` (4 punti: `5FB823EB40B78EF9925B9164` / `09FC66E10978B41A9187FF38`).

**Interfaces:**
- Consumes: `S3Syncer.xmlDecode` (resa `nonisolated`), `S3Syncer.encodePlusInQuery`, `sign`, `session` (invariati).
- Produces:
  - `func fetchListPageXML(config: S3Config, token: String?) async throws -> String` (su `S3Syncer`, `@MainActor` come il resto della classe; non privata)
  - `nonisolated struct S3Syncer.S3ObjectInfo: Equatable, Sendable { let key: String; let size: Int64; let etag: String? }`
  - `nonisolated struct S3Syncer.S3ListPage: Equatable, Sendable { let objects: [S3ObjectInfo]; let isTruncated: Bool; let nextToken: String?; let malformedEntries: Int }`
  - `nonisolated static func S3Syncer.parseListPage(_ xml: String) -> S3ListPage`
- **Invariati** (S9): `listPage` restituisce esattamente quello che restituiva; `S3Listing`, `collectPages`, `listAllDetailed`, `listAll` non si toccano.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/S3ListPageParserTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `S3Syncer.parseListPage` (ROADMAP #44): una pagina di `ListObjectsV2` letta oggetto per
/// oggetto, con l'ETag. Il vecchio `listPage` legge chiavi e dimensioni in due liste separate e
/// le accoppia per posizione: per l'ETag questo non basta, perche' un oggetto senza ETag
/// sposterebbe tutti i successivi di un posto e l'ETag di un file finirebbe su un altro — cioe'
/// un contenuto "certificato" su una chiave che non lo contiene.
final class S3ListPageParserTests: XCTestCase {

    private func page(_ contents: String, truncated: Bool = false, token: String? = nil) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>backupfoto</Name>"
        xml += "<IsTruncated>\(truncated ? "true" : "false")</IsTruncated>"
        xml += contents
        if let token { xml += "<NextContinuationToken>\(token)</NextContinuationToken>" }
        return xml + "</ListBucketResult>"
    }

    private func object(_ key: String, size: String, etag: String?) -> String {
        var s = "<Contents><Key>\(key)</Key><LastModified>2026-09-26T10:00:00.000Z</LastModified>"
        if let etag { s += "<ETag>\(etag)</ETag>" }
        return s + "<Size>\(size)</Size><StorageClass>STANDARD</StorageClass></Contents>"
    }

    func testKeySizeAndETag_areReadPerObject() {
        let p = S3Syncer.parseListPage(page(
            object("Foto iPhone/IMG_1.JPG", size: "1000", etag: "&quot;e722bbb0c3185d08f1a31567e66a825b&quot;")
            + object("ASUS/Elba/FILE0056.MOV", size: "67108865", etag: "&quot;96aa53ed4132d7e2986467263954caad-2&quot;")))
        XCTAssertEqual(p.objects, [
            S3Syncer.S3ObjectInfo(key: "Foto iPhone/IMG_1.JPG", size: 1000, etag: "\"e722bbb0c3185d08f1a31567e66a825b\""),
            S3Syncer.S3ObjectInfo(key: "ASUS/Elba/FILE0056.MOV", size: 67_108_865, etag: "\"96aa53ed4132d7e2986467263954caad-2\""),
        ])
        XCTAssertEqual(p.malformedEntries, 0)
    }

    /// Il punto per cui esiste questo parser: un oggetto senza ETag resta senza, e non prende
    /// quello dell'oggetto dopo.
    func testMissingETag_staysMissing_andDoesNotShiftTheOthers() {
        let p = S3Syncer.parseListPage(page(
            object("a.jpg", size: "1", etag: nil)
            + object("b.jpg", size: "2", etag: "&quot;bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&quot;")))
        XCTAssertEqual(p.objects.map(\.key), ["a.jpg", "b.jpg"])
        XCTAssertNil(p.objects[0].etag)
        XCTAssertEqual(p.objects[1].etag, "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"")
    }

    /// Le chiavi di BUG-8: apostrofo scritto `&#39;`, `&amp;`.
    func testKeysWithEntities_areDecoded() {
        let p = S3Syncer.parseListPage(page(
            object("ASUS/Enrico Nanni Vicenzi/l&#39;estate.jpg", size: "3", etag: "&quot;x&quot;")
            + object("Foto/a &amp; b.jpg", size: "4", etag: "&quot;y&quot;")))
        XCTAssertEqual(p.objects.map(\.key), ["ASUS/Enrico Nanni Vicenzi/l'estate.jpg", "Foto/a & b.jpg"])
    }

    /// Una voce senza dimensione (o con una dimensione che non e' un numero) non si inventa:
    /// si salta e si conta, e chi legge la pagina sa che l'elenco non e' integro.
    func testEntryWithoutAReadableSize_isCountedAsMalformed() {
        let p = S3Syncer.parseListPage(page(
            "<Contents><Key>senza-dimensione.jpg</Key></Contents>"
            + object("dimensione-strana.jpg", size: "tanti", etag: nil)
            + object("buono.jpg", size: "7", etag: nil)))
        XCTAssertEqual(p.objects.map(\.key), ["buono.jpg"])
        XCTAssertEqual(p.malformedEntries, 2)
    }

    func testUnclosedContents_isMalformed() {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key><Size>1</Size></ListBucketResult>"
        let p = S3Syncer.parseListPage(xml)
        XCTAssertTrue(p.objects.isEmpty)
        XCTAssertEqual(p.malformedEntries, 1)
    }

    /// Una risposta che non e' una lista (vuota, un errore, un corpo troncato) non deve MAI
    /// leggersi come «lista finita e vuota»: ogni foto risulterebbe mancante da Cubbit.
    func testResponseWithoutTheListEnvelope_isMalformed() {
        for body in ["", "<Error><Code>InternalError</Code></Error>",
                     "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key><Size>1</Size></Contents>"] {
            XCTAssertGreaterThan(S3Syncer.parseListPage(body).malformedEntries, 0, "«\(body)»")
        }
    }

    func testTruncatedPage_givesTheNextToken() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: true, token: "ASUS/x+y.jpg"))
        XCTAssertTrue(p.isTruncated)
        XCTAssertEqual(p.nextToken, "ASUS/x+y.jpg")
    }

    /// "Ce n'e' ancora, ma non ti dico da dove": chi legge deve poterlo distinguere da "finito".
    func testTruncatedPageWithoutToken_saysSo() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: true, token: nil))
        XCTAssertTrue(p.isTruncated)
        XCTAssertNil(p.nextToken)
    }

    func testLastPage_ignoresAnyToken() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: false, token: "t"))
        XCTAssertFalse(p.isTruncated)
        XCTAssertNil(p.nextToken)
    }

    func testEmptyPage() {
        let p = S3Syncer.parseListPage(page(""))
        XCTAssertTrue(p.objects.isEmpty)
        XCTAssertEqual(p.malformedEntries, 0)
        XCTAssertFalse(p.isTruncated)
    }

    /// `xmlDecode` deve essere usabile fuori dal main (l'inventario legge le pagine in un
    /// `Task.detached`): stessa funzione dei test di BUG-8, stesso risultato.
    func testXmlDecode_isTheSameFunctionUsedByTheList() {
        XCTAssertEqual(S3Syncer.xmlDecode("&quot;abc&quot;"), "\"abc\"")
    }
}
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/S3ListPageParserTests` → atteso `error: type 'S3Syncer' has no member 'parseListPage'`.

- [ ] **Step 3: implementa.**

(a) `xmlDecode` (riga 7598): cambia solo l'intestazione, il corpo resta identico:

```swift
    // `nonisolated`: pura; la usa anche `parseListPage`, chiamata dall'inventario fuori dal main.
    nonisolated static func xmlDecode(_ s: String) -> String {
```

(b) Sostituisci **tutta** `private func listPage(config:token:)` (7129-7160) con queste due funzioni. Le righe di `fetchListPageXML` sono quelle di prima fino alla verifica dello stato HTTP, spostate e non riscritte; quelle di `listPage` sono le sue ultime otto, identiche:

```swift
    /// Una pagina di `ListObjectsV2` cosi' com'e' arrivata, senza interpretarla. Estratta da
    /// `listPage` il 2026-09-26 (ROADMAP #44): l'inventario ha bisogno anche dell'ETag, che
    /// `listPage` non legge. La richiesta resta UNA — stessa URL, stessa firma, stesse
    /// correzioni di BUG-8 (`encodePlusInQuery`, `xmlDecode`) — e i chiamanti di `listPage`
    /// ricevono esattamente quello che ricevevano prima.
    func fetchListPageXML(config: S3Config, token: String?) async throws -> String {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        comps.queryItems = qi
        comps.percentEncodedQuery = Self.encodePlusInQuery(comps.percentEncodedQuery)
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista S3: \(body.prefix(300))"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func listPage(config: S3Config, token: String?) async throws -> ([String: Int64], String?) {
        let xml = try await fetchListPageXML(config: config, token: token)
        let keys = xmlAll(xml, tag: "Key")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        var objs: [String: Int64] = [:]
        for (k, s) in zip(keys, sizes) { objs[k] = s }
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (objs, nextToken)
    }
```

(c) Dopo `xmlAll` (ultima funzione della classe), prima della `}` di `S3Syncer`:

```swift
    // MARK: Lista con ETag, per l'inventario (ROADMAP #44, ADR-0015)

    /// Un oggetto della lista, con l'ETag (`nil` se la voce non lo porta).
    nonisolated struct S3ObjectInfo: Equatable, Sendable {
        let key: String
        let size: Int64
        let etag: String?
    }

    /// Una pagina di `ListObjectsV2` letta oggetto per oggetto.
    nonisolated struct S3ListPage: Equatable, Sendable {
        let objects: [S3ObjectInfo]
        let isTruncated: Bool
        /// `nil` anche quando `isTruncated` e' vero ma la pagina non dice da dove ripartire:
        /// chi legge deve trattarlo come lista incompleta, non come lista finita.
        let nextToken: String?
        /// Voci `<Contents>` senza chiave, senza dimensione leggibile o non chiuse.
        let malformedEntries: Int
    }

    /// Legge una pagina blocco `<Contents>` per blocco `<Contents>`: chiave, dimensione ed ETag
    /// di un oggetto vengono dallo STESSO blocco. `listPage` accoppia per posizione due liste
    /// separate (chiavi e dimensioni): per l'ETag non basterebbe, perche' un oggetto senza ETag
    /// sposterebbe tutti i successivi di un posto — l'ETag di un file finirebbe su un altro, e
    /// un contenuto risulterebbe «certificato» su una chiave che non lo contiene.
    ///
    /// Scorre la stringa per intervalli, senza ricopiarne il resto a ogni voce. `nonisolated`
    /// e statica: l'inventario la chiama fuori dal main, e non tocca niente dell'istanza.
    nonisolated static func parseListPage(_ xml: String) -> S3ListPage {
        func firstValue(_ tag: String, in range: Range<String.Index>) -> String? {
            guard let open = xml.range(of: "<\(tag)>", range: range),
                  let close = xml.range(of: "</\(tag)>", range: open.upperBound..<range.upperBound) else { return nil }
            return xmlDecode(String(xml[open.upperBound..<close.lowerBound]))
        }
        var objects: [S3ObjectInfo] = []
        // Una risposta senza l'involucro della lista (vuota, non UTF-8, un <Error>, un corpo
        // troncato) non e' "una pagina senza oggetti": e' una pagina che non si e' letta.
        // Senza questa riga, una risposta illeggibile chiuderebbe la lista come COMPLETA e
        // VUOTA, e ogni foto risulterebbe mancante da Cubbit.
        var malformed = (xml.contains("<ListBucketResult") && xml.contains("</ListBucketResult>")) ? 0 : 1
        var cursor = xml.startIndex
        while let open = xml.range(of: "<Contents>", range: cursor..<xml.endIndex) {
            guard let close = xml.range(of: "</Contents>", range: open.upperBound..<xml.endIndex) else {
                malformed += 1
                break
            }
            let block = open.upperBound..<close.lowerBound
            if let key = firstValue("Key", in: block),
               let sizeText = firstValue("Size", in: block),
               let size = Int64(sizeText), size >= 0 {
                objects.append(S3ObjectInfo(key: key, size: size, etag: firstValue("ETag", in: block)))
            } else {
                malformed += 1
            }
            cursor = close.upperBound
        }
        // I tag di controllo si cercano in tutta la pagina: dentro una chiave non possono
        // comparire, perche' la lista scrive `<` come `&lt;`.
        let whole = xml.startIndex..<xml.endIndex
        let isTruncated = firstValue("IsTruncated", in: whole) == "true"
        let token = isTruncated ? firstValue("NextContinuationToken", in: whole) : nil
        return S3ListPage(objects: objects, isTruncated: isTruncated, nextToken: token, malformedEntries: malformed)
    }
}
```

- [ ] **Step 4:** `… -only-testing:AppBackupFotoTests/S3ListPageParserTests` → `Executed 11 tests, with 0 failures`. Anche `S3ListSpecialCharsTests` e `S3ListingTests` verdi (invariati: 6 e 10).
- [ ] **Step 5:** build pulita (0 warning) + suite: `B+27` (888).
- [ ] **Step 6: rilettura del diff di `listPage`** (non coperta da test: serve la rete): `git diff -U0 AppBackupFoto/ContentView.swift | grep -A40 "fetchListPageXML"` — le righe tolte da `listPage` devono ricomparire identiche in `fetchListPageXML`, salvo l'ultima (`return String(data:…) ?? ""`).
- [ ] **Mutante che deve morire:** ETag cercato da `block.lowerBound` fino alla fine della pagina invece che nel solo blocco (verificato: muore `testMissingETag_staysMissing_andDoesNotShiftTheOthers`); tolta la guardia sull'involucro `<ListBucketResult>` (muore `testResponseWithoutTheListEnvelope_isMalformed`).
- [ ] **Step 7: commit.** `Inventario, task 2: lista di Cubbit letta oggetto per oggetto con l'ETag` + le due righe di attribuzione.

---

### Task 3: `S3ETag` e `S3ETagMatcher` — certificato, riconosciuto solo dall'MD5, non certificabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — nuovo codice dopo la `}` di `S3Syncer` (7638), prima di `// MARK: - Spazio usato su Cubbit` (7640).
- Create: `AppBackupFotoTests/S3ETagMatcherTests.swift` (4 punti: `E23C952846EB4FAAB758CC44` / `496E00D79739E3114DC87822`).

**Interfaces:**
- Consumes: `S3Syncer.multipartChunkSize` (Task 1), `Insecure.MD5`.
- Produces:
  - `nonisolated enum S3ETag: Equatable, Sendable { case singlePart(md5: String), multipart(digest: String, parts: Int), unrecognized; static func parse(_ raw: String?) -> S3ETag }`
  - `nonisolated enum S3ETagMatcher { struct Candidate { let size: Int64; let sha256: String; let md5: String; let multipartETag: String? }; enum NotCertifiableReason: String { case unrecognizedFormat, differentPartSize, noLocalFileProducesIt, ambiguous }; enum Verdict { case certified(sha256: String), identifiedOnlyByMD5(md5: String), notCertifiable(NotCertifiableReason) }; static func expectedParts(size: Int64, partSize: Int) -> Int; static func md5OfMD5Hex(_ md5Hex: String) -> String?; static func verdict(etag: String?, size: Int64, candidates: [Candidate], partSize: Int = S3Syncer.multipartChunkSize) -> Verdict }`

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/S3ETagMatcherTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `S3ETag`/`S3ETagMatcher` (ROADMAP #44, decisione 1 di Enrico): un oggetto Cubbit e'
/// «certificato» solo se il suo ETag coincide con l'MD5 (caricamento unico) o con l'ETag a
/// pezzi da 64 MiB (`-N`) di un file letto su SSD o HDD della stessa dimensione. Mai per
/// ipotesi. I valori sono quelli di `ContentHasherTests` (stessi byte, stessa fonte `python3`).
final class S3ETagMatcherTests: XCTestCase {
    private let size1000: Int64 = 1000
    private let sizeBig: Int64 = 67_108_865

    private var small: S3ETagMatcher.Candidate {
        .init(size: size1000, sha256: "008549d94fa71e7a0a483d84380d05a923a4b18e79ba1f8a8ddac923956d32ef",
              md5: "e722bbb0c3185d08f1a31567e66a825b", multipartETag: nil)
    }
    private var big: S3ETagMatcher.Candidate {
        .init(size: sizeBig, sha256: "e44417605ed97d14de38fdd4561c81e3f8329f4a6621144e31801c992e397f40",
              md5: "9c800b6accf6f26be7e8684d46ffdedb", multipartETag: "96aa53ed4132d7e2986467263954caad-2")
    }

    // MARK: - Formato

    func testParse_singlePart_withQuotesAndUppercase() {
        XCTAssertEqual(S3ETag.parse("\"E722BBB0C3185D08F1A31567E66A825B\""),
                       .singlePart(md5: "e722bbb0c3185d08f1a31567e66a825b"))
        XCTAssertEqual(S3ETag.parse(" e722bbb0c3185d08f1a31567e66a825b "),
                       .singlePart(md5: "e722bbb0c3185d08f1a31567e66a825b"))
    }

    func testParse_multipart() {
        XCTAssertEqual(S3ETag.parse("\"fc22b3a263f8c63ba9d9f8fbd7a0b713-4\""),
                       .multipart(digest: "fc22b3a263f8c63ba9d9f8fbd7a0b713", parts: 4))
    }

    func testParse_unrecognizedFormats() {
        for raw: String? in [nil, "", "\"\"", "abc", String(repeating: "a", count: 31),
                             String(repeating: "g", count: 32),
                             String(repeating: "a", count: 32) + "-0",
                             String(repeating: "a", count: 32) + "-02",
                             String(repeating: "a", count: 32) + "-10001",
                             String(repeating: "a", count: 32) + "-",
                             String(repeating: "a", count: 32) + "-2-3",
                             String(repeating: "１", count: 32)] {
            XCTAssertEqual(S3ETag.parse(raw), .unrecognized, "formato che non va riconosciuto: \(String(describing: raw))")
        }
    }

    // MARK: - Caricamento unico

    func testSinglePart_sameMD5_isCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"e722bbb0c3185d08f1a31567e66a825b\"", size: size1000, candidates: [small]),
                       .certified(sha256: small.sha256))
    }

    /// Esattamente 64 MiB: caricamento unico, quindi l'ETag e' l'MD5 del file intero.
    func testSinglePart_exactly64MiB_isComparedWithTheMD5() {
        let c = S3ETagMatcher.Candidate(size: 67_108_864,
                                        sha256: "d7279ae9528c7908d99a3c0c84b077e4b5ed515d32fee94847048187d214af3c",
                                        md5: "1c81167936a46883a15d0fe49895453f", multipartETag: nil)
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"1c81167936a46883a15d0fe49895453f\"", size: 67_108_864, candidates: [c]),
                       .certified(sha256: c.sha256))
    }

    /// Nessun file locale con quell'MD5: il contenuto c'e' solo su Cubbit, e lo si riconosce
    /// dall'MD5. Non e' «non certificabile»: l'ETag e' un MD5 vero, manca solo un file da
    /// affiancargli.
    func testSinglePart_noLocalFile_isIdentifiedByItsMD5Only() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"ffffffffffffffffffffffffffffffff\"", size: size1000, candidates: [small]),
                       .identifiedOnlyByMD5(md5: "ffffffffffffffffffffffffffffffff"))
    }

    /// La dimensione fa parte della regola: un file con lo stesso MD5 ma dimensione diversa
    /// non e' un candidato (e per l'MD5 vero non puo' succedere: se succede, e' un dato rotto).
    func testCandidateOfADifferentSize_isIgnored() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"e722bbb0c3185d08f1a31567e66a825b\"", size: 999, candidates: [small]),
                       .identifiedOnlyByMD5(md5: "e722bbb0c3185d08f1a31567e66a825b"))
    }

    /// Due file diversi con lo stesso MD5 (una collisione): non si sceglie a caso.
    func testSinglePart_twoDifferentContentsWithTheSameMD5_isAmbiguous() {
        let twin = S3ETagMatcher.Candidate(size: size1000, sha256: "altro-contenuto", md5: small.md5, multipartETag: nil)
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"\(small.md5)\"", size: size1000, candidates: [small, twin]),
                       .notCertifiable(.ambiguous))
    }

    func testSameContentListedTwice_isStillCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"\(small.md5)\"", size: size1000, candidates: [small, small]),
                       .certified(sha256: small.sha256))
    }

    // MARK: - A pezzi

    func testMultipart_rightETag_isCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-2\"", size: sizeBig, candidates: [big]),
                       .certified(sha256: big.sha256))
    }

    /// Caricato con parti di un'altra dimensione (per esempio rclone): il numero di parti non
    /// torna con 64 MiB, e l'app non puo' ricalcolarlo senza scaricare. Mai «certificato».
    func testMultipart_otherPartSize_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-13\"", size: sizeBig, candidates: [big]),
                       .notCertifiable(.differentPartSize))
    }

    func testMultipart_rightPartCountButDifferentDigest_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"00000000000000000000000000000000-2\"", size: sizeBig, candidates: [big]),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    func testMultipart_noLocalFile_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-2\"", size: sizeBig, candidates: []),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    /// Una sola parte (`-1`): il risultato non dipende dalla dimensione delle parti, e si
    /// ricalcola dall'MD5 del file (md5 dei 16 byte dell'MD5). Valore da `python3`.
    func testMultipartWithOnePart_isComputedFromTheMD5() {
        XCTAssertEqual(S3ETagMatcher.md5OfMD5Hex(small.md5), "89ce4de5b26c4f12814730135253df12")
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"89ce4de5b26c4f12814730135253df12-1\"", size: size1000, candidates: [small]),
                       .certified(sha256: small.sha256))
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"89ce4de5b26c4f12814730135253df13-1\"", size: size1000, candidates: [small]),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    func testUnrecognizedFormat_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"boh\"", size: size1000, candidates: [small]),
                       .notCertifiable(.unrecognizedFormat))
        XCTAssertEqual(S3ETagMatcher.verdict(etag: nil, size: size1000, candidates: [small]),
                       .notCertifiable(.unrecognizedFormat))
    }

    func testExpectedParts_followsTheUploadRule() {
        let p = S3Syncer.multipartChunkSize
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: 0, partSize: p), 1)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: Int64(p), partSize: p), 1)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: Int64(p) + 1, partSize: p), 2)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: 4 * Int64(p), partSize: p), 4)
    }
}
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/S3ETagMatcherTests` → atteso `error: cannot find 'S3ETag' in scope`.
- [ ] **Step 3: implementa:**

```swift
// MARK: - ETag di Cubbit (ROADMAP #44, ADR-0015)

/// La forma di un ETag di Cubbit. Tre casi, nient'altro: tutto quello che non e' riconosciuto
/// con certezza e' `.unrecognized`, e un ETag non riconosciuto non certifica mai niente.
// `nonisolated`: pura, chiamata dal confronto fuori dal main.
nonisolated enum S3ETag: Equatable, Sendable {
    /// Caricamento unico: l'ETag e' l'MD5 del contenuto.
    case singlePart(md5: String)
    /// Caricamento a pezzi: `md5(md5(parte1) ‖ … ‖ md5(parteN))-N`.
    case multipart(digest: String, parts: Int)
    case unrecognized

    /// Accetta l'ETag con o senza virgolette (la lista le manda come `&quot;`, gia' decodificate
    /// da `S3Syncer.xmlDecode`), in maiuscolo o minuscolo, con spazi ai bordi. Esadecimale solo
    /// ASCII; `N` fra 1 e 10.000 (il massimo di S3), scritto senza zeri davanti.
    static func parse(_ raw: String?) -> S3ETag {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return .unrecognized }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        func isHex32(_ t: Substring) -> Bool { t.count == 32 && t.allSatisfy { $0.isASCII && $0.isHexDigit } }
        let pieces = s.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count == 1, isHex32(pieces[0]) { return .singlePart(md5: String(pieces[0])) }
        if pieces.count == 2, isHex32(pieces[0]), let n = Int(pieces[1]), n >= 1, n <= 10_000, String(n) == pieces[1] {
            return .multipart(digest: String(pieces[0]), parts: n)
        }
        return .unrecognized
    }
}

/// Decisione 1 di Enrico: «certificato» su Cubbit vuol dire contenuto, confrontato con l'ETag
/// senza scaricare. Un oggetto che non si riesce a confrontare cosi' e' NON CERTIFICABILE, mai
/// «certificato» per ipotesi.
// `nonisolated`: pura.
nonisolated enum S3ETagMatcher {
    /// Un file letto su SSD o HDD, con le sue impronte.
    struct Candidate: Equatable, Sendable {
        let size: Int64
        let sha256: String
        let md5: String
        let multipartETag: String?
    }

    enum NotCertifiableReason: String, Equatable, Sendable {
        case unrecognizedFormat
        /// `-N` con un numero di parti che non torna con 64 MiB: caricato con un'altra
        /// dimensione delle parti (per esempio da rclone). Ricalcolarlo vorrebbe dire scaricarlo.
        case differentPartSize
        /// Formato giusto, ma nessun file locale della stessa dimensione lo produce.
        case noLocalFileProducesIt
        /// Due contenuti locali diversi producono lo stesso ETag (una collisione MD5): non si
        /// sceglie a caso.
        case ambiguous
    }

    enum Verdict: Equatable, Sendable {
        case certified(sha256: String)
        /// ETag a parte unica che nessun file locale riproduce: e' l'MD5 vero di un contenuto
        /// che c'e' solo su Cubbit. Si riconosce, ma non ha un SHA256.
        case identifiedOnlyByMD5(md5: String)
        case notCertifiable(NotCertifiableReason)
    }

    /// Quante parti da `partSize` produce `S3Syncer.upload` per un file di `size` byte (un
    /// file vuoto o fino a `partSize` compresi e' una parte sola).
    static func expectedParts(size: Int64, partSize: Int) -> Int {
        guard size > 0 else { return 1 }
        return Int((size + Int64(partSize) - 1) / Int64(partSize))
    }

    /// ETag di un caricamento a pezzi con UNA parte: l'MD5 dei 16 byte dell'MD5 del file. Non
    /// dipende dalla dimensione delle parti, quindi si ricalcola da qualunque file locale.
    static func md5OfMD5Hex(_ md5Hex: String) -> String? {
        var bytes: [UInt8] = []
        var i = md5Hex.startIndex
        while i < md5Hex.endIndex {
            let j = md5Hex.index(i, offsetBy: 2, limitedBy: md5Hex.endIndex) ?? md5Hex.endIndex
            guard let b = UInt8(md5Hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        guard bytes.count == 16 else { return nil }
        return Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Solo i candidati della STESSA dimensione contano (spec: «di almeno un file letto su SSD
    /// o HDD con la stessa dimensione»): il filtro e' qui, non affidato a chi chiama.
    static func verdict(etag: String?, size: Int64, candidates: [Candidate],
                        partSize: Int = S3Syncer.multipartChunkSize) -> Verdict {
        let sameSize = candidates.filter { $0.size == size }
        let matching: [Candidate]
        switch S3ETag.parse(etag) {
        case .unrecognized:
            return .notCertifiable(.unrecognizedFormat)
        case .singlePart(let md5):
            matching = sameSize.filter { $0.md5 == md5 }
            if matching.isEmpty { return .identifiedOnlyByMD5(md5: md5) }
        case .multipart(let digest, 1):
            matching = sameSize.filter { md5OfMD5Hex($0.md5) == digest }
            if matching.isEmpty { return .notCertifiable(.noLocalFileProducesIt) }
        case .multipart(let digest, let parts):
            guard parts == expectedParts(size: size, partSize: partSize) else {
                return .notCertifiable(.differentPartSize)
            }
            let wanted = "\(digest)-\(parts)"
            matching = sameSize.filter { $0.multipartETag == wanted }
            if matching.isEmpty { return .notCertifiable(.noLocalFileProducesIt) }
        }
        let shas = Set(matching.map(\.sha256))
        guard shas.count == 1, let sha = shas.first else { return .notCertifiable(.ambiguous) }
        return .certified(sha256: sha)
    }
}
```

- [ ] **Step 4:** `… -only-testing:AppBackupFotoTests/S3ETagMatcherTests` → `Executed 16 tests, with 0 failures`.
- [ ] **Step 5:** build pulita + suite: `B+43` (904).
- [ ] **Mutante che deve morire:** tolto il controllo sul numero di parti (verificato: muore `testMultipart_otherPartSize_isNotCertifiable`); tolto il filtro `sameSize` (muore `testCandidateOfADifferentSize_isIgnored`); `shas.count == 1` → `>= 1` (muore `testSinglePart_twoDifferentContentsWithTheSameMD5_isAmbiguous`).
- [ ] **Step 6: commit.** `Inventario, task 3: un oggetto Cubbit si certifica solo con l'ETag, mai per ipotesi` + attribuzione.

---

### Task 4: il modello dell'inventario e le tabelle nello stesso SQLite (schema 2)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `LibraryIndexStore` (4313-4821): `static let schemaVersion = 1` (4314), `createSchemaIfNeeded()` (4535-4566), API dopo `newestHashedAt()` (4647-4649, prima di `// MARK: Implementazioni`), implementazioni dopo `newestHashedAtUnsynchronized()` (4811-4820, prima della `}` della classe); modello in regione R (prima di `// MARK: - Testi e regole della card "Foto gia' salvate"`, 5280).
- Create: `AppBackupFotoTests/InventoryStoreTests.swift` (4 punti: `B03981ED6C74915210F086AB` / `8051CD87C86D4474EA31B719`).

**Interfaces:**
- Consumes: `ContentDigest` (Task 1), `normalizedIndexKey`, gli helper privati dello store (`exec`, `prepare`, `bindText`, `bindInt64`, `bindDouble`, `stepRow`, `sqlError`, `queue`, `db`).
- Produces (modello, tutto `nonisolated … Sendable`):
  - `enum InventoryArchive: String, CaseIterable, Comparable { case ssd, hdd, s3; var rank: Int }`
  - `enum InventoryReadStatus: String { case ok, unreadable, changedWhileReading }`
  - `struct InventoryLocalFile: Equatable { let key, displayPath: String; let size: Int64; let mtime: Double; let status: InventoryReadStatus; let digest: ContentDigest?; let hashedAt: Double }`
  - `struct InventoryS3Object: Equatable { let key, displayKey: String; let size: Int64; let etag: String? }`
  - `enum InventoryIncompleteReason: String { case running, notReached, interrupted, volumeVanished, foldersUnreadable, filesUnreadable, sawNothing, listingFailed, listingMalformed, couldNotSave }`
  - `struct InventoryArchiveState: Equatable { let archive: InventoryArchive; let runId: Int64; let complete: Bool; let reason: InventoryIncompleteReason?; let unreadable: Int; let startedAt: Double; let finishedAt: Double? }`
  - `struct InventorySnapshot: Equatable { var ssd, hdd: [InventoryLocalFile]; var s3: [InventoryS3Object]; var states: [InventoryArchive: InventoryArchiveState]; func isComplete(_:) -> Bool }`
- Produces (store): `static let schemaVersion = 2`, `static let upgradableFromVersion: Int32 = 1`, `static let createInventoryTablesSQL: String`, `static let dropInventoryTablesSQL: String`, e
  - `func beginInventoryRun(runId: Int64, startedAt: Double) throws`
  - `func inventoryLocalRows(_ archive: InventoryArchive) throws -> [String: InventoryLocalFile]`
  - `func upsertInventoryLocal(_ rows: [InventoryLocalFile], archive: InventoryArchive, runId: Int64) throws`
  - `func upsertInventoryS3(_ rows: [InventoryS3Object], runId: Int64) throws`
  - `func finishInventoryArchive(_ archive: InventoryArchive, runId: Int64, complete: Bool, reason: InventoryIncompleteReason?, unreadable: Int, finishedAt: Double) throws`
  - `func inventoryStates() throws -> [InventoryArchive: InventoryArchiveState]`
  - `func inventorySnapshot() throws -> InventorySnapshot`

**Le tabelle** (dettaglio richiesto dalla spec): `inventory_local` (PK `archive`+`path`; `status`; `sha256`/`md5` NULL se illeggibile; `etag` NULL anche per i file ≤ 64 MiB; `hashed_at`; `run_id`), `inventory_s3` (PK `display_key`, la chiave vera, perché su Cubbit maiuscole e minuscole contano; `path` normalizzato indicizzato per il confronto; `etag`; `run_id`), `inventory_state` (una riga per archivio: `run_id`, `complete`, `reason`, `unreadable`, `started_at`, `finished_at`). Conta come presente solo una riga del `run_id` registrato nello stato; dopo una lettura completa le righe di giri vecchi si cancellano, dopo una incompleta restano solo come memoria per non rileggere.

**Test esistenti toccati:** nessuno. `DuplicateGroupsStoreTests`/`LibraryIndexStoreTests` che scrivono `user_version = LibraryIndexStore.schemaVersion` da fuori continuano a funzionare (con 2 le tabelle dell'inventario si creano con `IF NOT EXISTS`); `testUnknownSchemaVersion_resetsIndex` (999) e `testSchemaWrittenByAnotherVersionWithNonNumericVersion_isRebuilt` (0) continuano a ricostruire.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryStoreTests.swift`:

```swift
import XCTest
import SQLite3
@testable import AppBackupFoto

/// Le tabelle dell'inventario nello stesso file dell'elenco (ROADMAP #44, ADR-0015): lotti,
/// giri, completezza per archivio, e il passaggio dalla versione 1 dello schema.
final class InventoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func local(_ path: String, sha: String = "S", size: Int64 = 10,
                       status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: size, mtime: 1_700_000_000,
                           status: status,
                           digest: status == .ok ? ContentDigest(size: size, sha256: sha, md5: "m-" + sha, multipartETag: nil) : nil,
                           hashedAt: 1_700_003_600)
    }

    private func object(_ key: String, size: Int64 = 10, etag: String? = "\"e\"") -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: etag)
    }

    private func finish(_ a: InventoryArchive, _ run: Int64, complete: Bool,
                        reason: InventoryIncompleteReason? = nil) throws {
        try store.finishInventoryArchive(a, runId: run, complete: complete, reason: reason,
                                         unreadable: 0, finishedAt: 2_000)
    }

    private func external(_ url: URL, _ sql: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return XCTFail("connessione esterna non aperta")
        }
        defer { sqlite3_close_v2(handle) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("SQL esterno fallito: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    private func userVersion(_ url: URL) -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close_v2(handle) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    // MARK: - Giri e completezza

    func testNewStore_hasNoInventory() throws {
        XCTAssertTrue(try store.inventoryStates().isEmpty)
        XCTAssertEqual(try store.inventorySnapshot(), InventorySnapshot())
    }

    /// Un giro aperto e mai chiuso (l'app chiusa a meta') non deve mai leggersi come completo.
    func testBeginRun_marksEveryArchiveIncomplete() throws {
        try store.beginInventoryRun(runId: 7, startedAt: 1_000)
        let states = try store.inventoryStates()
        XCTAssertEqual(Set(states.keys), [.ssd, .hdd, .s3])
        for a in InventoryArchive.allCases {
            XCTAssertEqual(states[a]?.complete, false)
            XCTAssertEqual(states[a]?.reason, .running)
            XCTAssertEqual(states[a]?.runId, 7)
            XCTAssertNil(states[a]?.finishedAt)
        }
    }

    func testLocalRows_roundTrip_throughTheSnapshot() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        let big = InventoryLocalFile(key: "asus/elba/file0056.mov", displayPath: "ASUS/Elba/FILE0056.MOV",
                                     size: 67_108_865, mtime: 1.5, status: .ok,
                                     digest: ContentDigest(size: 67_108_865, sha256: "S", md5: "M",
                                                           multipartETag: "96aa53ed4132d7e2986467263954caad-2"),
                                     hashedAt: 2.5)
        try store.upsertInventoryLocal([local("Foto/a.jpg"), big], archive: .ssd, runId: 1)
        try finish(.ssd, 1, complete: true)
        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.ssd, [big, local("Foto/a.jpg")], "in ordine di chiave, valori identici")
        XCTAssertTrue(snap.hdd.isEmpty)
        XCTAssertTrue(snap.isComplete(.ssd))
        XCTAssertFalse(snap.isComplete(.hdd))
    }

    func testUnreadableRow_roundTripsWithoutDigest() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/rotto.jpg", status: .unreadable)], archive: .hdd, runId: 1)
        let row = try XCTUnwrap(store.inventorySnapshot().hdd.first)
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Conta come presente solo cio' che e' stato visto nel giro registrato: una riga di un giro
    /// vecchio e' solo memoria per non rileggere, mai una prova che il file c'e' ancora.
    func testSnapshot_readsOnlyTheRecordedRun() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/vecchia.jpg")], archive: .ssd, runId: 1)
        try finish(.ssd, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 10)
        try store.upsertInventoryLocal([local("Foto/nuova.jpg")], archive: .ssd, runId: 2)
        try finish(.ssd, 2, complete: false, reason: .interrupted)

        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.ssd.map(\.displayPath), ["Foto/nuova.jpg"])
        XCTAssertEqual(try store.inventoryLocalRows(.ssd).count, 2,
                       "giro incompleto: la riga vecchia resta come memoria")
    }

    func testCompleteFinish_deletesRowsNotSeenInThisRun() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/a.jpg"), local("Foto/b.jpg")], archive: .ssd, runId: 1)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .hdd, runId: 1)
        try finish(.ssd, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 10)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 2)
        try finish(.ssd, 2, complete: true)

        XCTAssertEqual(Set(try store.inventoryLocalRows(.ssd).keys), ["foto/a.jpg"])
        XCTAssertEqual(try store.inventoryLocalRows(.hdd).count, 1, "l'HDD non si tocca chiudendo l'SSD")
    }

    func testIncompleteFinish_recordsTheReason() throws {
        try store.beginInventoryRun(runId: 3, startedAt: 0)
        try store.finishInventoryArchive(.hdd, runId: 3, complete: false, reason: .filesUnreadable,
                                         unreadable: 4, finishedAt: 9)
        let state = try XCTUnwrap(store.inventoryStates()[.hdd])
        XCTAssertFalse(state.complete)
        XCTAssertEqual(state.reason, .filesUnreadable)
        XCTAssertEqual(state.unreadable, 4)
        XCTAssertEqual(state.finishedAt, 9)
    }

    /// Chiudere un archivio con un `runId` che non e' quello aperto non deve toccare niente:
    /// e' un giro vecchio arrivato tardi.
    func testFinishWithAnotherRunId_changesNothing() throws {
        try store.beginInventoryRun(runId: 5, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 5)
        try store.finishInventoryArchive(.ssd, runId: 4, complete: true, reason: nil, unreadable: 0, finishedAt: 1)
        XCTAssertEqual(try store.inventoryStates()[.ssd]?.complete, false)
        XCTAssertEqual(try store.inventoryLocalRows(.ssd).count, 1, "le righe del giro aperto non si toccano")
    }

    // MARK: - Cubbit

    /// Su Cubbit maiuscole e minuscole contano: due oggetti che differiscono solo per quello
    /// restano due righe.
    func testS3Objects_differingOnlyByCase_areBothKept() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("Foto/IMG.JPG"), object("Foto/img.jpg")], runId: 1)
        try finish(.s3, 1, complete: true)
        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.s3.map(\.displayKey), ["Foto/IMG.JPG", "Foto/img.jpg"])
        XCTAssertEqual(Set(snap.s3.map(\.key)), ["foto/img.jpg"])
    }

    func testS3_missingETag_roundTripsAsNil() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg", etag: nil)], runId: 1)
        XCTAssertNil(try store.inventorySnapshot().s3.first?.etag)
    }

    func testS3_completeFinish_deletesObjectsNotListedAgain() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg"), object("b.jpg")], runId: 1)
        try finish(.s3, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 0)
        try store.upsertInventoryS3([object("b.jpg")], runId: 2)
        try finish(.s3, 2, complete: true)
        XCTAssertEqual(try store.inventorySnapshot().s3.map(\.displayKey), ["b.jpg"])
    }

    // MARK: - Schema (ADR-0002, ADR-0015)

    func testSchemaVersion_isTwo() {
        XCTAssertEqual(LibraryIndexStore.schemaVersion, 2)
        XCTAssertEqual(LibraryIndexStore.upgradableFromVersion, 1)
    }

    /// Il passaggio che conta per Enrico: l'elenco da 141.683 voci NON si butta aggiornando
    /// l'app. La versione 1 ha `entries` identica: si tiene, e l'inventario nasce vuoto.
    func testVersion1Database_keepsTheListAndGainsAnEmptyInventory() throws {
        let url = tempDir.appendingPathComponent("v1.sqlite")
        external(url, """
        CREATE TABLE entries (path TEXT PRIMARY KEY NOT NULL, display_path TEXT NOT NULL, size INTEGER NOT NULL,
                              mtime REAL NOT NULL, hash TEXT NOT NULL, hashed_at REAL NOT NULL);
        CREATE INDEX idx_entries_hash ON entries(hash);
        CREATE INDEX idx_entries_size ON entries(size);
        INSERT INTO entries VALUES ('foto/a.jpg','Foto/a.jpg',10,1.0,'H',2.0);
        PRAGMA user_version=1;
        """)
        let s = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s.count(), 1, "l'elenco resta")
        XCTAssertEqual(try s.entry(forKey: "foto/a.jpg")?.hash, "H")
        XCTAssertTrue(try s.inventoryStates().isEmpty)
        XCTAssertEqual(userVersion(url), 2)
    }

    /// Una build vecchia riaperta su un file nuovo riporta la versione a 1 e lascia le tabelle
    /// dell'inventario orfane: al ritorno sulla build nuova si buttano, non si adottano.
    func testVersion1WithLeftoverInventory_discardsTheInventoryOnly() throws {
        let url = tempDir.appendingPathComponent("ritorno.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.upsert([LibraryIndexEntry(path: "foto/a.jpg", displayPath: "Foto/a.jpg", size: 10, mtime: 1, hash: "H", hashedAt: 2)])
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
            try s1.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 1)
        }
        external(url, "PRAGMA user_version=1;")

        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.count(), 1)
        XCTAssertTrue(try s2.inventoryStates().isEmpty)
        XCTAssertTrue(try s2.inventoryLocalRows(.ssd).isEmpty)
    }

    func testUnknownVersion_rebuildsEverything_inventoryIncluded() throws {
        let url = tempDir.appendingPathComponent("futuro.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.upsert([LibraryIndexEntry(path: "foto/a.jpg", displayPath: "Foto/a.jpg", size: 10, mtime: 1, hash: "H", hashedAt: 2)])
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
        }
        external(url, "PRAGMA user_version=999;")

        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.count(), 0)
        XCTAssertTrue(try s2.inventoryStates().isEmpty)
    }

    func testReopenAtTheCurrentVersion_keepsTheInventory() throws {
        let url = tempDir.appendingPathComponent("stesso.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
            try s1.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 1)
        }
        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.inventoryLocalRows(.ssd).count, 1)
    }

    /// «Svuota l'elenco» cancella il file: con l'elenco se ne va anche l'inventario.
    func testDeleteIndexAndRecreate_emptiesTheInventoryToo() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg")], runId: 1)
        try store.deleteIndexAndRecreate()
        XCTAssertTrue(try store.inventoryStates().isEmpty)
        XCTAssertEqual(try store.inventorySnapshot(), InventorySnapshot())
    }

    // MARK: - Righe scritte da fuori

    /// Una riga "ok" senza impronte e' una riga rotta: si legge come illeggibile, cosi' il giro
    /// dopo la rilegge invece di fidarsi.
    func testOkRowWithoutDigest_readsAsUnreadable() throws {
        let url = tempDir.appendingPathComponent("riga.sqlite")
        let s = try LibraryIndexStore(url: url)
        try s.beginInventoryRun(runId: 1, startedAt: 0)
        external(url, """
        INSERT INTO inventory_local VALUES ('ssd','foto/a.jpg','Foto/a.jpg',10,1.0,'ok',NULL,NULL,NULL,2.0,1);
        """)
        let row = try XCTUnwrap(s.inventoryLocalRows(.ssd)["foto/a.jpg"])
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Un motivo che questa versione non conosce, o un "completo" senza data di fine, non
    /// rendono completo un archivio.
    func testUnknownReasonOrMissingEnd_neverReadsAsComplete() throws {
        let url = tempDir.appendingPathComponent("stato.sqlite")
        let s = try LibraryIndexStore(url: url)
        external(url, """
        INSERT INTO inventory_state VALUES ('ssd',1,0,'boh',0,0.0,5.0);
        INSERT INTO inventory_state VALUES ('hdd',1,1,NULL,0,0.0,NULL);
        """)
        let states = try s.inventoryStates()
        XCTAssertEqual(states[.ssd]?.complete, false)
        XCTAssertEqual(states[.ssd]?.reason, .interrupted)
        XCTAssertEqual(states[.hdd]?.complete, false)
    }
}
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryStoreTests` → atteso `error: cannot find type 'InventoryLocalFile' in scope`.

- [ ] **Step 3: implementa.**

(a) In regione R, il modello:

```swift
// MARK: - Inventario certificato: il modello dei dati (ROADMAP #44, ADR-0015)
//
// Tutti value type senza stato condiviso: `nonisolated` perche' li producono e li leggono lo
// scanner, il lettore di Cubbit e il confronto, fuori dal main (ADR-0006).

/// I tre posti in cui stanno le foto. L'ordine (`rank`) e' quello in cui la finestra li nomina.
nonisolated enum InventoryArchive: String, CaseIterable, Sendable, Comparable {
    case ssd, hdd, s3

    var rank: Int {
        switch self {
        case .ssd: return 0
        case .hdd: return 1
        case .s3: return 2
        }
    }

    static func < (a: InventoryArchive, b: InventoryArchive) -> Bool { a.rank < b.rank }
}

/// Com'e' andata la lettura di un file su SSD o HDD.
nonisolated enum InventoryReadStatus: String, Sendable {
    case ok
    /// Non si e' aperto o la lettura si e' interrotta (permessi, errore del disco, disco sparito).
    case unreadable
    /// Letto, ma e' cambiato mentre lo si leggeva: le impronte non valgono niente.
    case changedWhileReading
}

/// Un file foto o video letto su SSD o HDD.
nonisolated struct InventoryLocalFile: Equatable, Sendable {
    /// `normalizedIndexKey` del percorso relativo alla radice del disco: la stessa chiave
    /// dell'elenco dei Doppioni, cosi' "stesso percorso" vuol dire la stessa cosa ovunque.
    let key: String
    /// Il percorso com'e' sul disco, da mostrare.
    let displayPath: String
    let size: Int64
    /// Data di modifica letta PRIMA della lettura del contenuto (vedi `InventoryScanner`).
    let mtime: Double
    let status: InventoryReadStatus
    /// `nil` se `status != .ok`.
    let digest: ContentDigest?
    /// Quando le impronte sono state calcolate: serve alla regola anti-racy di `indexEntryVerdict`.
    let hashedAt: Double
}

/// Un oggetto del bucket, nel perimetro (foto e video).
nonisolated struct InventoryS3Object: Equatable, Sendable {
    /// `normalizedIndexKey` della chiave: per il confronto dei percorsi con SSD e HDD.
    let key: String
    /// La chiave vera, con maiuscole e minuscole: su Cubbit contano.
    let displayKey: String
    let size: Int64
    /// L'ETag come arriva dalla lista (virgolette comprese); `nil` se la lista non lo dava.
    let etag: String?
}

/// Perche' la lettura di un archivio non vale come completa.
nonisolated enum InventoryIncompleteReason: String, Sendable {
    /// Scritto all'inizio di ogni giro: resta se l'app si chiude prima della fine.
    case running
    /// Il giro si e' fermato prima di arrivare a questo archivio.
    case notReached
    /// Fermato da «Interrompi» o dallo scollegamento di un disco qualsiasi.
    case interrupted
    case volumeVanished
    case foldersUnreadable
    case filesUnreadable
    /// Zero foto viste dove la volta prima ce n'erano.
    case sawNothing
    case listingFailed
    case listingMalformed
    case couldNotSave
}

/// Com'e' andata l'ultima lettura di un archivio.
nonisolated struct InventoryArchiveState: Equatable, Sendable {
    let archive: InventoryArchive
    let runId: Int64
    /// Vero SOLO se la lettura e' arrivata in fondo senza nessun problema. Finche' e' falso,
    /// da questo archivio non si dichiara assente niente (la regola «incompleto non e' assente»).
    let complete: Bool
    /// `nil` se completo.
    let reason: InventoryIncompleteReason?
    /// File che non si sono lasciati leggere per intero.
    let unreadable: Int
    let startedAt: Double
    /// `nil` finche' la lettura di questo archivio non e' finita.
    let finishedAt: Double?
}

/// Quello che il confronto riceve: per ogni archivio le righe dell'ultimo giro, e i tre stati.
nonisolated struct InventorySnapshot: Equatable, Sendable {
    var ssd: [InventoryLocalFile] = []
    var hdd: [InventoryLocalFile] = []
    var s3: [InventoryS3Object] = []
    var states: [InventoryArchive: InventoryArchiveState] = [:]

    func isComplete(_ archive: InventoryArchive) -> Bool { states[archive]?.complete == true }
}
```

(b) In `LibraryIndexStore`, sostituisci `static let schemaVersion = 1` con:

```swift
    /// 2 dal 2026-09-26 (ROADMAP #44): si aggiungono le tabelle dell'inventario.
    static let schemaVersion = 2
    /// L'unica versione diversa da `schemaVersion` da cui si sale SENZA buttare l'elenco:
    /// la 1 ha `entries` identica a quella della 2 (vedi `createSchemaIfNeeded`, ADR-0015).
    static let upgradableFromVersion: Int32 = 1
```

(c) Sostituisci **tutta** `private func createSchemaIfNeeded()` (4535-4566) con quanto segue (la funzione nuova più le due costanti SQL):

```swift
    private func createSchemaIfNeeded() throws {
        // La versione dello schema e' `PRAGMA user_version`, non una riga di tabella: e' un
        // intero per costruzione (nessun "2.0"/"v2" da interpretare), esiste su qualunque
        // file SQLite e vale 0 sui database nuovi. Con la versione tenuta in una tabella,
        // un valore non numerico veniva letto come "database nuovo" e i dati vecchi
        // venivano adottati — il caso peggiore era irreversibile (schema futuro con colonne
        // diverse: ogni lettura falliva a ogni avvio, per sempre).
        //
        // Tre casi, e solo tre (ADR-0002, ADR-0015):
        // - versione attesa: niente da fare;
        // - versione 1 (`upgradableFromVersion`): e' lo schema di prima dell'inventario, con
        //   `entries` IDENTICA a quella di oggi. Si tiene l'elenco e si ricreano VUOTE le
        //   tabelle dell'inventario: una build vecchia riaperta su un file nuovo le lascia
        //   orfane, con dati di un giro che nessuno ha piu' controllato;
        // - qualunque altra versione — piu' vecchia, piu' nuova, o zero — significa
        //   "ricostruisci tutto", mai "interpreta al meglio". Buttare l'indice non perde
        //   nulla di originale.
        let onDisk = try userVersionOnDisk()
        if onDisk == Self.upgradableFromVersion {
            try exec(Self.dropInventoryTablesSQL)
        } else if onDisk != Int32(Self.schemaVersion) {
            // `meta` non esiste piu' in questo schema: il DROP serve solo a ripulire i
            // database scritti dalla prima versione della store, che la creava.
            try exec("DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS meta; " + Self.dropInventoryTablesSQL)
        }
        // NOT NULL esplicito sulle colonne TEXT: in una tabella rowid `TEXT PRIMARY KEY`
        // **non** implica NOT NULL e ammette perfino piu' righe NULL (verificato scrivendole
        // da una connessione esterna). Una riga con path NULL faceva poi crashare la lettura.
        try exec("""
        CREATE TABLE IF NOT EXISTS entries (
            path         TEXT PRIMARY KEY NOT NULL,
            display_path TEXT NOT NULL,
            size         INTEGER NOT NULL,
            mtime        REAL NOT NULL,
            hash         TEXT NOT NULL,
            hashed_at    REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(hash);
        CREATE INDEX IF NOT EXISTS idx_entries_size ON entries(size);
        """)
        try exec(Self.createInventoryTablesSQL)
        try exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    // MARK: Schema dell'inventario (ROADMAP #44, ADR-0015)

    /// Le tre tabelle dell'inventario. Vivono nello STESSO file dell'elenco (decisione 4
    /// della spec del 2026-09-26: si estende l'elenco, non un secondo database), quindi
    /// "Svuota l'elenco" svuota anche l'inventario.
    ///
    /// - `inventory_local`: un file foto/video letto su SSD o HDD. `sha256`/`md5` sono NULL
    ///   se la lettura non e' riuscita (`status` diverso da `ok`); `etag` e' NULL anche per
    ///   i file fino a 64 MiB compresi, che Cubbit riceve con un caricamento unico.
    /// - `inventory_s3`: un oggetto del bucket nel perimetro (foto e video). La chiave
    ///   primaria e' la chiave VERA (`display_key`): su Cubbit maiuscole e minuscole
    ///   contano, e due oggetti che differiscono solo per quello non devono sovrascriversi.
    /// - `inventory_state`: com'e' andata l'ultima lettura di ciascun archivio.
    ///
    /// `run_id` dice in quale giro la riga e' stata vista l'ultima volta. Conta come
    /// "presente" solo una riga del giro registrato in `inventory_state`: le altre sono solo
    /// una memoria per non rileggere i file invariati (e dopo un giro completo si cancellano).
    static let createInventoryTablesSQL = """
    CREATE TABLE IF NOT EXISTS inventory_local (
        archive      TEXT NOT NULL,
        path         TEXT NOT NULL,
        display_path TEXT NOT NULL,
        size         INTEGER NOT NULL,
        mtime        REAL NOT NULL,
        status       TEXT NOT NULL,
        sha256       TEXT,
        md5          TEXT,
        etag         TEXT,
        hashed_at    REAL NOT NULL,
        run_id       INTEGER NOT NULL,
        PRIMARY KEY (archive, path)
    );
    CREATE INDEX IF NOT EXISTS idx_inventory_local_run ON inventory_local(archive, run_id);
    CREATE TABLE IF NOT EXISTS inventory_s3 (
        display_key  TEXT PRIMARY KEY NOT NULL,
        path         TEXT NOT NULL,
        size         INTEGER NOT NULL,
        etag         TEXT,
        run_id       INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_inventory_s3_run ON inventory_s3(run_id);
    CREATE TABLE IF NOT EXISTS inventory_state (
        archive      TEXT PRIMARY KEY NOT NULL,
        run_id       INTEGER NOT NULL,
        complete     INTEGER NOT NULL,
        reason       TEXT,
        unreadable   INTEGER NOT NULL,
        started_at   REAL NOT NULL,
        finished_at  REAL
    );
    """

    static let dropInventoryTablesSQL =
        "DROP TABLE IF EXISTS inventory_local; DROP TABLE IF EXISTS inventory_s3; DROP TABLE IF EXISTS inventory_state;"
```

(d) Subito dopo `func newestHashedAt() throws -> Double? { … }`, prima di `// MARK: Implementazioni (gia' sulla coda: non chiamarle dall'esterno)`:

```swift
    // MARK: Inventario (ROADMAP #44, ADR-0015) — API pubblica, serializzata sulla coda

    /// Apre un giro: i tre archivi risultano "in corso", quindi INCOMPLETI, finche' ognuno
    /// non viene chiuso da `finishInventoryArchive`. Se l'app si chiude a meta', resta
    /// scritto che il giro non e' finito: mai un vecchio "completo" che sembra di oggi.
    func beginInventoryRun(runId: Int64, startedAt: Double) throws {
        try queue.sync { try beginInventoryRunUnsynchronized(runId: runId, startedAt: startedAt) }
    }

    /// Le righe di SSD o HDD rimaste dal giro precedente (qualunque `run_id`), per chiave.
    /// Servono solo a non rileggere i file invariati.
    func inventoryLocalRows(_ archive: InventoryArchive) throws -> [String: InventoryLocalFile] {
        try queue.sync { try inventoryLocalRowsUnsynchronized(archive) }
    }

    /// Un lotto di righe di SSD o HDD, in una sola transazione (ADR-0002: un inventario
    /// parziale e' valido in ogni istante).
    func upsertInventoryLocal(_ rows: [InventoryLocalFile], archive: InventoryArchive, runId: Int64) throws {
        try queue.sync { try upsertInventoryLocalUnsynchronized(rows, archive: archive, runId: runId) }
    }

    /// Una pagina di oggetti Cubbit, in una sola transazione.
    func upsertInventoryS3(_ rows: [InventoryS3Object], runId: Int64) throws {
        try queue.sync { try upsertInventoryS3Unsynchronized(rows, runId: runId) }
    }

    /// Chiude la lettura di un archivio. Solo se `complete`, cancella le righe di quel
    /// archivio viste in un giro precedente e non in questo: e' l'unico momento in cui
    /// "non l'ho visto" vuol dire "non c'e' piu'" (stessa regola di `LibraryIndexer`).
    func finishInventoryArchive(_ archive: InventoryArchive, runId: Int64, complete: Bool,
                                reason: InventoryIncompleteReason?, unreadable: Int,
                                finishedAt: Double) throws {
        try queue.sync {
            try finishInventoryArchiveUnsynchronized(archive, runId: runId, complete: complete,
                                                     reason: reason, unreadable: unreadable,
                                                     finishedAt: finishedAt)
        }
    }

    /// Lo stato dell'ultima lettura di ogni archivio. Un archivio mai letto non compare.
    func inventoryStates() throws -> [InventoryArchive: InventoryArchiveState] {
        try queue.sync { try inventoryStatesUnsynchronized() }
    }

    /// Tutto quello che serve a `InventoryClassifier`: per ogni archivio, SOLO le righe del
    /// giro registrato nel suo stato. In ordine di percorso, cosi' il risultato non dipende
    /// dall'ordine in cui SQLite restituisce le righe.
    func inventorySnapshot() throws -> InventorySnapshot {
        try queue.sync { try inventorySnapshotUnsynchronized() }
    }
```

(e) Subito dopo `private func newestHashedAtUnsynchronized() throws -> Double? { … }`, prima della `}` che chiude `LibraryIndexStore`:

```swift

    // MARK: Inventario — implementazioni (gia' sulla coda)

    /// Come `bindText`, ma un valore assente diventa NULL di proposito (non per un bind fallito).
    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        guard let value else {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqlError() }
            return
        }
        try bindText(stmt, index, value)
    }

    private func optionalText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let p = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: p)
    }

    private func beginInventoryRunUnsynchronized(runId: Int64, startedAt: Double) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_state(archive,run_id,complete,reason,unreadable,started_at,finished_at)
            VALUES(?,?,0,?,0,?,NULL);
            """)
            defer { sqlite3_finalize(stmt) }
            for archive in InventoryArchive.allCases {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, archive.rawValue)
                try bindInt64(stmt, 2, runId)
                try bindText(stmt, 3, InventoryIncompleteReason.running.rawValue)
                try bindDouble(stmt, 4, startedAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func readLocalRow(_ stmt: OpaquePointer?) -> InventoryLocalFile? {
        // Stessa guardia nil di `readEntry`: una riga malformata si salta, non si interpreta.
        guard let path = sqlite3_column_text(stmt, 0),
              let display = sqlite3_column_text(stmt, 1),
              let statusText = sqlite3_column_text(stmt, 4),
              let status = InventoryReadStatus(rawValue: String(cString: statusText)) else { return nil }
        let size = sqlite3_column_int64(stmt, 2)
        var digest: ContentDigest? = nil
        if status == .ok {
            // Una riga "ok" senza impronte non e' una riga ok: si legge come illeggibile,
            // cosi' il giro dopo la rilegge invece di fidarsi.
            guard let sha = optionalText(stmt, 5), let md5 = optionalText(stmt, 6) else {
                return InventoryLocalFile(key: String(cString: path), displayPath: String(cString: display),
                                          size: size, mtime: sqlite3_column_double(stmt, 3),
                                          status: .unreadable, digest: nil,
                                          hashedAt: sqlite3_column_double(stmt, 8))
            }
            digest = ContentDigest(size: size, sha256: sha, md5: md5, multipartETag: optionalText(stmt, 7))
        }
        return InventoryLocalFile(key: String(cString: path), displayPath: String(cString: display),
                                  size: size, mtime: sqlite3_column_double(stmt, 3),
                                  status: status, digest: digest,
                                  hashedAt: sqlite3_column_double(stmt, 8))
    }

    private static let localColumns = "path,display_path,size,mtime,status,sha256,md5,etag,hashed_at"

    private func inventoryLocalRowsUnsynchronized(_ archive: InventoryArchive) throws -> [String: InventoryLocalFile] {
        let stmt = try prepare("SELECT \(Self.localColumns) FROM inventory_local WHERE archive=?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, 1, archive.rawValue)
        var out: [String: InventoryLocalFile] = [:]
        while try stepRow(stmt) {
            if let row = readLocalRow(stmt) { out[row.key] = row }
        }
        return out
    }

    private func upsertInventoryLocalUnsynchronized(_ rows: [InventoryLocalFile], archive: InventoryArchive,
                                                    runId: Int64) throws {
        precondition(archive != .s3, "inventory_local contiene solo SSD e HDD")
        guard !rows.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_local(archive,path,display_path,size,mtime,status,sha256,md5,etag,hashed_at,run_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, archive.rawValue)
                try bindText(stmt, 2, r.key)
                try bindText(stmt, 3, r.displayPath)
                try bindInt64(stmt, 4, r.size)
                try bindDouble(stmt, 5, r.mtime)
                try bindText(stmt, 6, r.status.rawValue)
                try bindOptionalText(stmt, 7, r.digest?.sha256)
                try bindOptionalText(stmt, 8, r.digest?.md5)
                try bindOptionalText(stmt, 9, r.digest?.multipartETag)
                try bindDouble(stmt, 10, r.hashedAt)
                try bindInt64(stmt, 11, runId)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func upsertInventoryS3Unsynchronized(_ rows: [InventoryS3Object], runId: Int64) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_s3(display_key,path,size,etag,run_id) VALUES(?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, r.displayKey)
                try bindText(stmt, 2, r.key)
                try bindInt64(stmt, 3, r.size)
                try bindOptionalText(stmt, 4, r.etag)
                try bindInt64(stmt, 5, runId)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func finishInventoryArchiveUnsynchronized(_ archive: InventoryArchive, runId: Int64, complete: Bool,
                                                      reason: InventoryIncompleteReason?, unreadable: Int,
                                                      finishedAt: Double) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            UPDATE inventory_state SET complete=?, reason=?, unreadable=?, finished_at=?
            WHERE archive=? AND run_id=?;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, 1, complete ? 1 : 0)
            try bindOptionalText(stmt, 2, complete ? nil : (reason ?? .interrupted).rawValue)
            try bindInt64(stmt, 3, Int64(unreadable))
            try bindDouble(stmt, 4, finishedAt)
            try bindText(stmt, 5, archive.rawValue)
            try bindInt64(stmt, 6, runId)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            // Nessuna riga aggiornata = non e' il giro aperto (un giro vecchio arrivato tardi):
            // non si cancella niente, altrimenti sparirebbero le righe del giro vero.
            if complete && sqlite3_changes(db) == 1 {
                let sql = archive == .s3
                    ? "DELETE FROM inventory_s3 WHERE run_id<>?;"
                    : "DELETE FROM inventory_local WHERE archive=? AND run_id<>?;"
                let del = try prepare(sql)
                defer { sqlite3_finalize(del) }
                if archive == .s3 {
                    try bindInt64(del, 1, runId)
                } else {
                    try bindText(del, 1, archive.rawValue)
                    try bindInt64(del, 2, runId)
                }
                guard sqlite3_step(del) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func inventoryStatesUnsynchronized() throws -> [InventoryArchive: InventoryArchiveState] {
        let stmt = try prepare("""
        SELECT archive,run_id,complete,reason,unreadable,started_at,finished_at FROM inventory_state;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [InventoryArchive: InventoryArchiveState] = [:]
        while try stepRow(stmt) {
            guard let a = sqlite3_column_text(stmt, 0),
                  let archive = InventoryArchive(rawValue: String(cString: a)) else { continue }
            let finished = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            // "Completo" vale solo con una data di fine: un giro mai chiuso non e' completo.
            let complete = sqlite3_column_int64(stmt, 2) == 1 && finished != nil
            // Un motivo che questa versione non conosce non rende l'archivio completo: resta
            // incompleto, col motivo generico.
            let reason = optionalText(stmt, 3).map { InventoryIncompleteReason(rawValue: $0) ?? .interrupted }
            out[archive] = InventoryArchiveState(archive: archive, runId: sqlite3_column_int64(stmt, 1),
                                                 complete: complete,
                                                 reason: complete ? nil : (reason ?? .interrupted),
                                                 unreadable: Int(sqlite3_column_int64(stmt, 4)),
                                                 startedAt: sqlite3_column_double(stmt, 5),
                                                 finishedAt: finished)
        }
        return out
    }

    private func inventorySnapshotUnsynchronized() throws -> InventorySnapshot {
        let states = try inventoryStatesUnsynchronized()
        var snap = InventorySnapshot(states: states)
        for archive in [InventoryArchive.ssd, .hdd] {
            guard let state = states[archive] else { continue }
            let stmt = try prepare("""
            SELECT \(Self.localColumns) FROM inventory_local WHERE archive=? AND run_id=? ORDER BY path;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, archive.rawValue)
            try bindInt64(stmt, 2, state.runId)
            var rows: [InventoryLocalFile] = []
            while try stepRow(stmt) {
                if let row = readLocalRow(stmt) { rows.append(row) }
            }
            if archive == .ssd { snap.ssd = rows } else { snap.hdd = rows }
        }
        if let state = states[.s3] {
            let stmt = try prepare("""
            SELECT display_key,path,size,etag FROM inventory_s3 WHERE run_id=? ORDER BY display_key;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, 1, state.runId)
            while try stepRow(stmt) {
                guard let display = sqlite3_column_text(stmt, 0),
                      let path = sqlite3_column_text(stmt, 1) else { continue }
                snap.s3.append(InventoryS3Object(key: String(cString: path), displayKey: String(cString: display),
                                                 size: sqlite3_column_int64(stmt, 2), etag: optionalText(stmt, 3)))
            }
        }
        return snap
    }
```

- [ ] **Step 4:** `… -only-testing:AppBackupFotoTests/InventoryStoreTests` → `Executed 19 tests, with 0 failures`. Anche `LibraryIndexStoreTests` (35) e `DuplicateGroupsStoreTests` verdi, invariati.
- [ ] **Step 5:** build pulita + suite: `B+62` (923).
- [ ] **Mutante che deve morire:** `DELETE … WHERE archive=? AND run_id<>?` → `OR` (verificato: muoiono `testCompleteFinish_deletesRowsNotSeenInThisRun` e i test del giro completo); tolto `&& sqlite3_changes(db) == 1` (verificato: muore `testFinishWithAnotherRunId_changesNothing`); ramo `onDisk == upgradableFromVersion` che butta anche `entries` (muore `testVersion1Database_keepsTheListAndGainsAnEmptyInventory`); tolto `&& finished != nil` (muore `testUnknownReasonOrMissingEnd_neverReadsAsComplete`).
- [ ] **Step 6: commit.** `Inventario, task 4: tabelle dell'inventario nello stesso elenco, schema 2 senza perdere l'elenco` + attribuzione.

---

### Task 5: `InventoryScanner` — SSD e HDD, incrementale, incompleto ≠ assente

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo il modello del Task 4.
- Create: `AppBackupFotoTests/InventoryScannerTests.swift` (4 punti: `13740CD609C3CF49E0834FEE` / `EE37493DA8873EFB121F2062`).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda).

**Interfaces:**
- Consumes: `LibraryIndexStore.inventoryLocalRows/upsertInventoryLocal` (Task 4), `ContentHasher.digestFile` (Task 1), `CancelFlag`, `ProgressThrottle`, `LibraryExclusions.shouldExclude`, `IndexableKind.of(url:)`, `canonicalPathComponents(of:)`, `deviceIdentifier(of:)`, `normalizedIndexKey`, `indexEntryVerdict(…)` — tutti esistenti e `nonisolated`.
- Produces:
  - `nonisolated struct InventoryScanReport: Equatable, Sendable { var scanned, reread, reused, unreadableFiles, unreadableFolders, outsideRoot: Int; var volumeVanished, cancelled, sawNothing: Bool; var isComplete: Bool; var incompleteReason: InventoryIncompleteReason? }`
  - `nonisolated final class InventoryScanner: @unchecked Sendable { init(store: LibraryIndexStore, cancelFlag: CancelFlag); @discardableResult func scan(root: URL, archive: InventoryArchive, runId: Int64, batchSize: Int = 200, progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos, onProgress: @escaping (InventoryScanReport) -> Void = { _ in }) throws -> InventoryScanReport }`

**Perché non `LibraryIndexer`:** vedi S2. `LibraryIndexer.scan` **non cambia di una riga**; se sembra necessario toccarlo, fermati e rimanda all'Architect.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryScannerTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `InventoryScanner` (ROADMAP #44): la lettura di SSD e HDD per l'inventario, su cartelle
/// temporanee vere. Il caso piu' importante e' la regola «incompleto non e' assente».
final class InventoryScannerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var store: LibraryIndexStore!
    private var flag: CancelFlag!
    private var scanner: InventoryScanner!

    /// Data fissa nel passato, come in `LibraryIndexerTests`: un file appena creato cadrebbe
    /// nella regola anti-racy e verrebbe riletto sempre, e il riuso non si vedrebbe mai.
    private static let fixtureMTime = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryScannerTests-\(UUID().uuidString)")
        root = tempDir.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        flag = CancelFlag()
        scanner = InventoryScanner(store: store, cancelFlag: flag)
    }

    override func tearDownWithError() throws {
        scanner = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureMTime], ofItemAtPath: url.path)
        return url
    }

    private func run(_ id: Int64, batchSize: Int = 200,
                     onProgress: @escaping (InventoryScanReport) -> Void = { _ in }) throws -> InventoryScanReport {
        try store.beginInventoryRun(runId: id, startedAt: Double(id))
        return try scanner.scan(root: root, archive: .hdd, runId: id, batchSize: batchSize,
                                progressIntervalNanos: 0, onProgress: onProgress)
    }

    func testReadsOnlyPhotosAndVideos_withTheirDigests() throws {
        try makeFile("Foto iPhone/a.jpg", "uno")
        try makeFile("Foto iPhone/b.mov", "due")
        try makeFile("Zip/archivio.zip", "non e' una foto")
        try makeFile("Takeout/a.json", "metadati")
        let r = try run(1)
        XCTAssertEqual(r.scanned, 2)
        XCTAssertEqual(r.reread, 2)
        XCTAssertTrue(r.isComplete)

        let rows = try store.inventoryLocalRows(.hdd)
        XCTAssertEqual(Set(rows.keys), ["foto iphone/a.jpg", "foto iphone/b.mov"])
        let a = try XCTUnwrap(rows["foto iphone/a.jpg"])
        XCTAssertEqual(a.displayPath, "Foto iPhone/a.jpg")
        XCTAssertEqual(a.status, .ok)
        var h = ContentHasher(); h.update(Data("uno".utf8))
        XCTAssertEqual(a.digest, h.finalize())
        XCTAssertNil(a.digest?.multipartETag, "3 byte: caricamento unico su Cubbit")
    }

    /// La guardia contro la divergenza fra i due lettori (ADR-0015): sullo stesso albero,
    /// l'inventario vede ESATTAMENTE i file che vede l'elenco dei Doppioni. Nell'albero ci sono
    /// tutte le trappole note: sidecar `._`, cartelle nascoste, `.Trashes`, esclusioni, non-media.
    func testSeesExactlyTheFilesTheListSees() throws {
        try makeFile("Foto iPhone/IMG_1.JPG", "1")
        try makeFile("Foto iPhone/._IMG_1.JPG", "sidecar")
        try makeFile("Foto iPhone/.nascosta/x.jpg", "nascosta")
        try makeFile(".Trashes/501/cestinata.jpg", "cestino")
        try makeFile("lost+found/perso.jpg", "perso")
        try makeFile("Takeout/Foto/IMG_2.heic", "2")
        try makeFile("Takeout/Foto/IMG_2.heic.json", "json")
        try makeFile("Other/video.mp4", "v")
        try makeFile("Zip/a.zip", "zip")

        let listStore = try LibraryIndexStore(url: tempDir.appendingPathComponent("elenco.sqlite"))
        _ = try LibraryIndexer(store: listStore).scan(root: root)
        _ = try run(1)
        XCTAssertEqual(Set(try store.inventoryLocalRows(.hdd).keys), try listStore.allKeys())
        XCTAssertEqual(try listStore.allKeys().count, 3)
    }

    func testSecondRun_reusesUnchangedFiles() throws {
        try makeFile("Foto/a.jpg", "uno")
        try makeFile("Foto/b.jpg", "due")
        _ = try run(1)
        let r = try run(2)
        XCTAssertEqual(r.reused, 2)
        XCTAssertEqual(r.reread, 0)
        XCTAssertTrue(r.isComplete)
    }

    func testChangedFile_isReadAgain() throws {
        try makeFile("Foto/a.jpg", "uno")
        let b = try makeFile("Foto/b.jpg", "due")
        _ = try run(1)
        try Data("contenuto nuovo".utf8).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureMTime.addingTimeInterval(600)],
                                              ofItemAtPath: b.path)
        let r = try run(2)
        XCTAssertEqual(r.reused, 1)
        XCTAssertEqual(r.reread, 1)
        var h = ContentHasher(); h.update(Data("contenuto nuovo".utf8))
        XCTAssertEqual(try store.inventoryLocalRows(.hdd)["foto/b.jpg"]?.digest, h.finalize())
    }

    /// Un file che non si legge rende l'archivio incompleto, e resta scritto: quel file c'e',
    /// solo che non sappiamo cosa contiene.
    func testUnreadableFile_makesTheArchiveIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        let b = try makeFile("Foto/b.jpg", "due")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: b.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path) }

        let r = try run(1)
        XCTAssertEqual(r.unreadableFiles, 1)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.incompleteReason, .filesUnreadable)
        let row = try XCTUnwrap(store.inventoryLocalRows(.hdd)["foto/b.jpg"])
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Un file che l'ultima volta non si leggeva non si "ricorda" come letto: si riprova.
    func testPreviouslyUnreadableFile_isTriedAgain() throws {
        let b = try makeFile("Foto/b.jpg", "due")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: b.path)
        _ = try run(1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
        let r = try run(2)
        XCTAssertEqual(r.reread, 1)
        XCTAssertTrue(r.isComplete)
    }

    func testUnreadableFolder_makesTheArchiveIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        try makeFile("Foto/segreta/s.jpg", "s")
        let secret = root.appendingPathComponent("Foto/segreta")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        let r = try run(1)
        XCTAssertEqual(r.unreadableFolders, 1)
        XCTAssertEqual(r.incompleteReason, .foldersUnreadable)
    }

    /// Disco scollegato prima di partire: non e' un disco vuoto.
    func testRootMissingAtStart_isAVanishedDisk_notAnEmptyOne() throws {
        try FileManager.default.removeItem(at: root)
        let r = try run(1)
        XCTAssertTrue(r.volumeVanished)
        XCTAssertEqual(r.incompleteReason, .volumeVanished)
        XCTAssertEqual(r.scanned, 0)
    }

    /// La radice sparisce a meta' lettura (lo stesso trucco deterministico di
    /// `LibraryIndexerTests.testRootRenamedDuringScan_…`: rinominarla dal primo progresso).
    func testRootVanishingDuringTheRead_isAVanishedDisk() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        let moved = tempDir.appendingPathComponent("HDD-scollegato")
        let original = root!
        var renamed = false
        let r = try run(1, batchSize: 1) { _ in
            guard !renamed else { return }
            renamed = true
            try? FileManager.default.moveItem(at: original, to: moved)
        }
        XCTAssertTrue(renamed)
        XCTAssertTrue(r.volumeVanished)
        XCTAssertFalse(r.isComplete)
    }

    func testStop_isAnInterruption() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        flag.cancel()
        let r = try run(1)
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.incompleteReason, .interrupted)
    }

    /// Zero file visti dove la volta prima ce n'erano: "non ho trovato niente" non e' "non c'e'
    /// niente".
    func testSawNothing_afterAPreviousRun_isIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        _ = try run(1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto"))
        let r = try run(2)
        XCTAssertTrue(r.sawNothing)
        XCTAssertEqual(r.incompleteReason, .sawNothing)
    }

    /// ADR-0002: le righe si salvano a lotti MENTRE la lettura va avanti, non tutte alla fine.
    func testRowsAreSavedInBatches_duringTheRead() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        var savedDuringTheRead = 0
        let r = try run(1, batchSize: 2) { [store] report in
            if report.scanned == 3 { savedDuringTheRead = (try? store!.inventoryLocalRows(.hdd).count) ?? -1 }
        }
        XCTAssertEqual(r.scanned, 5)
        XCTAssertGreaterThanOrEqual(savedDuringTheRead, 2)
    }
}
```

e in coda a `MainThreadIsolationTests`:

```swift
    func testInventoryScan_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let scanner = InventoryScanner(store: try makeStore(), cancelFlag: CancelFlag())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? scanner.scan(root: root, archive: .hdd, runId: 1)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryScanner.scan ha avuto bisogno del main thread.")
    }
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryScannerTests` → atteso `error: cannot find 'InventoryScanner' in scope`.
- [ ] **Step 3: implementa** in regione R, dopo il modello:

```swift
/// Com'e' andata la lettura di SSD o HDD per l'inventario.
nonisolated struct InventoryScanReport: Equatable, Sendable {
    /// Foto e video visti (nel perimetro di `IndexableKind`).
    var scanned = 0
    /// Letti davvero in questo giro.
    var reread = 0
    /// Impronte riprese dal giro precedente: dimensione e data invariate.
    var reused = 0
    /// File che non si sono lasciati leggere per intero, o cambiati mentre li si leggeva.
    var unreadableFiles = 0
    /// Cartelle che non si sono lasciate aprire (contate dall'`errorHandler`).
    var unreadableFolders = 0
    /// File il cui percorso canonico non ricade sotto la radice (non raggiungibile oggi).
    var outsideRoot = 0
    var volumeVanished = false
    var cancelled = false
    /// Zero file visti, ma il giro precedente ne aveva: "non ho trovato niente" non e'
    /// "non c'e' niente".
    var sawNothing = false

    var isComplete: Bool { incompleteReason == nil }

    /// Il motivo principale per cui la lettura non vale come completa, `nil` se e' completa.
    /// Precedenza: dal guasto piu' grave (il disco e' sparito) al piu' circoscritto.
    var incompleteReason: InventoryIncompleteReason? {
        if volumeVanished { return .volumeVanished }
        if cancelled { return .interrupted }
        if unreadableFolders > 0 { return .foldersUnreadable }
        if unreadableFiles > 0 { return .filesUnreadable }
        if sawNothing { return .sawNothing }
        return nil
    }
}

/// Legge SSD o HDD per l'inventario: stessa traversata di `LibraryIndexer.scan` (stesse
/// esclusioni, stesso `.skipsHiddenFiles`, stesso filtro `IndexableKind`, stesso calcolo del
/// percorso relativo per componenti, stesso `st_dev` inizio/fine, stesso `errorHandler` che
/// conta), ma scrive nelle tabelle dell'inventario e calcola tre impronte per file in una
/// lettura (`ContentHasher`). NON e' `LibraryIndexer` riusato: vedi ADR-0015 per il perche',
/// e `InventoryScannerTests.testSeesExactlyTheFilesTheListSees` per la guardia contro le
/// divergenze fra i due.
///
/// Sola lettura sul volume: non scrive, non sposta, non cancella niente.
// `nonisolated`: `store`, `cancelFlag` e `fm` sono `let` (`LibraryIndexStore` serializza da
// se' sulla propria coda, `CancelFlag` sta dietro il proprio lock, `FileManager.default` e'
// thread-safe per queste operazioni); tutto lo stato di un giro e' LOCALE a `scan`. Vedi ADR-0006.
nonisolated final class InventoryScanner: @unchecked Sendable {
    private let store: LibraryIndexStore
    private let cancelFlag: CancelFlag
    private let fm = FileManager.default

    /// Stessa scatola di `LibraryIndexer.TraversalFailures`: l'`errorHandler` e' `@escaping` e
    /// viene chiamato in modo sincrono dal thread che chiama `nextObject()`, cioe' questo.
    private final class TraversalFailures { var count = 0 }

    init(store: LibraryIndexStore, cancelFlag: CancelFlag) {
        self.store = store
        self.cancelFlag = cancelFlag
    }

    @discardableResult
    func scan(root: URL, archive: InventoryArchive, runId: Int64, batchSize: Int = 200,
              progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos,
              onProgress: @escaping (InventoryScanReport) -> Void = { _ in }) throws -> InventoryScanReport {
        precondition(archive != .s3, "InventoryScanner legge solo SSD e HDD")
        var report = InventoryScanReport()
        var throttle = ProgressThrottle(minimumIntervalNanos: progressIntervalNanos)
        var batch: [InventoryLocalFile] = []
        let failures = TraversalFailures()
        let previous = try store.inventoryLocalRows(archive)

        let deviceAtStart = deviceIdentifier(of: root)
        guard deviceAtStart != nil else {
            // Disco assente prima di partire: un disco scollegato non e' mai un disco vuoto.
            report.volumeVanished = true
            onProgress(report)
            return report
        }
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in
                                                 failures.count += 1
                                                 return true
                                             }) else {
            report.unreadableFolders = 1
            onProgress(report)
            return report
        }
        let rootComponents = canonicalPathComponents(of: root)
        var volumeVanished = false

        func flush() throws {
            guard !batch.isEmpty else { return }
            try store.upsertInventoryLocal(batch, archive: archive, runId: runId)
            batch.removeAll(keepingCapacity: true)
            // Uscita anticipata opportunistica, come in `LibraryIndexer`: la garanzia vera e'
            // il controllo dopo il ciclo.
            if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }
        }

        walk: while let url = enumerator.nextObject() as? URL {
            if cancelFlag.isCancelled { break }
            if LibraryExclusions.shouldExclude(url) { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard IndexableKind.of(url: url) != .notIndexable else { continue }

            let fileComponents = canonicalPathComponents(of: url)
            guard fileComponents.count > rootComponents.count,
                  Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
                report.outsideRoot += 1
                continue
            }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            report.scanned += 1
            let key = normalizedIndexKey(relative)

            // Senza dimensione o data non c'e' niente da confrontare: il file non entra, e
            // l'archivio risulta incompleto (e' un file che c'e' e che non conosciamo).
            guard let fileSize = values?.fileSize, let modified = values?.contentModificationDate else {
                report.unreadableFiles += 1
                continue
            }
            let size = Int64(fileSize)
            // La data si legge PRIMA della lettura, come in `LibraryIndexer`: un file che cambia
            // mentre lo si legge risulta cambiato al giro dopo, invece che invariato per sempre.
            let mtime = modified.timeIntervalSince1970

            if let old = previous[key], old.status == .ok, let digest = old.digest {
                let verdict = indexEntryVerdict(storedSize: old.size, storedMTime: old.mtime,
                                                storedHashedAt: old.hashedAt,
                                                currentSize: size, currentMTime: mtime)
                if verdict == .fresh || verdict == .timezoneShift {
                    batch.append(InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                                    status: .ok, digest: digest, hashedAt: old.hashedAt))
                    report.reused += 1
                    if batch.count >= batchSize { try flush(); if volumeVanished { break walk } }
                    if throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds, isFinal: false) {
                        onProgress(report)
                    }
                    continue
                }
            }

            let now = Date().timeIntervalSince1970
            let row: InventoryLocalFile
            switch ContentHasher.digestFile(at: url, isCancelled: { self.cancelFlag.isCancelled }) {
            case .digest(let digest) where digest.size == size:
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .ok, digest: digest, hashedAt: now)
                report.reread += 1
            case .digest, .changedWhileReading:
                // Letto per intero ma con una dimensione diversa da quella della cartella, o
                // cambiato durante la lettura: le impronte non valgono niente.
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .changedWhileReading, digest: nil, hashedAt: now)
                report.unreadableFiles += 1
            case .unreadable:
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .unreadable, digest: nil, hashedAt: now)
                report.unreadableFiles += 1
            case .cancelled:
                break walk
            }
            batch.append(row)
            if batch.count >= batchSize { try flush(); if volumeVanished { break walk } }
            if throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds, isFinal: false) {
                onProgress(report)
            }
        }

        try flush()
        if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }
        report.unreadableFolders = failures.count
        report.volumeVanished = volumeVanished
        report.cancelled = cancelFlag.isCancelled
        report.sawNothing = report.scanned == 0 && !previous.isEmpty
        onProgress(report)
        return report
    }
}
```

- [ ] **Step 4:** `… -only-testing:AppBackupFotoTests/InventoryScannerTests` → `Executed 12 tests, with 0 failures`; `MainThreadIsolationTests` → `Executed 16 tests`.
- [ ] **Step 5:** build pulita + suite: `B+75` (936).
- [ ] **Mutante che deve morire:** nel ramo `.unreadable` tolto `report.unreadableFiles += 1` (verificato: muore `testUnreadableFile_makesTheArchiveIncomplete`); tolto `.skipsHiddenFiles` o il controllo `LibraryExclusions` (muore `testSeesExactlyTheFilesTheListSees`); tolto il controllo `st_dev` dopo il ciclo (muore `testRootVanishingDuringTheRead_isAVanishedDisk`); data letta DOPO la lettura del file (non coperto da un test: va controllato in review, come in `LibraryIndexer`).
- [ ] **Step 6: commit.** `Inventario, task 5: lettura di SSD e HDD con le tre impronte, a lotti e interrompibile` + attribuzione.

---

### Task 6: `InventoryCubbitReader` — la lista del bucket, salvata a pagine

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo `InventoryScanner`.
- Create: `AppBackupFotoTests/InventoryCubbitReaderTests.swift` (4 punti: `580B6ADF04D6871266BBF239` / `C83C8DBDEA1EFF04AD9B6E40`).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda).

**Interfaces:**
- Consumes: `S3Syncer.parseListPage` (Task 2), `LibraryIndexStore.upsertInventoryS3` (Task 4), `CancelFlag`, `LibraryExclusions.names`, `IndexableKind`, `normalizedIndexKey`.
- Produces:
  - `nonisolated struct CubbitReadReport: Equatable, Sendable { var pages, objectsListed, objectsKept, malformedEntries: Int; var truncatedWithoutToken, reachedEnd, cancelled, couldNotSave: Bool; var failure: String?; var isComplete: Bool; var incompleteReason: InventoryIncompleteReason? }`
  - `nonisolated enum InventoryPerimeter { static func includesS3Key(_ key: String) -> Bool }`
  - `nonisolated final class InventoryCubbitReader: @unchecked Sendable { init(store: LibraryIndexStore, cancelFlag: CancelFlag); @concurrent func read(runId: Int64, fetchPage: @escaping @Sendable (String?) async throws -> String, onProgress: @escaping @Sendable (CubbitReadReport) -> Void = { _ in }) async -> CubbitReadReport }`

`@concurrent` è la prima occorrenza nel progetto: è la regola di ADR-0006 per le funzioni di fondo `async` (compilato e verificato con Swift 6.4 in modalità 5 dall'Architect).

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryCubbitReaderTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `InventoryCubbitReader` e `InventoryPerimeter` (ROADMAP #44): la lista di Cubbit con l'ETag,
/// salvata a pagine, con un Cubbit finto (le pagine sono XML scritti a mano, nessuna rete).
final class InventoryCubbitReaderTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!
    private var flag: CancelFlag!
    private var reader: InventoryCubbitReader!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryCubbitReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        flag = CancelFlag()
        reader = InventoryCubbitReader(store: store, cancelFlag: flag)
        try store.beginInventoryRun(runId: 1, startedAt: 0)
    }

    override func tearDownWithError() throws {
        reader = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct NetworkDown: Error {}

    private static func object(_ key: String, _ size: Int, _ etag: String) -> String {
        "<Contents><Key>\(key)</Key><ETag>&quot;\(etag)&quot;</ETag><Size>\(size)</Size></Contents>"
    }

    /// Pagina per token (`""` = la prima). Un dizionario `let`: `Sendable`, nessuno stato.
    private static let twoPages: [String: String] = [
        "": "<ListBucketResult><IsTruncated>true</IsTruncated>"
            + object("Foto iPhone/IMG_1.JPG", 1000, "e722bbb0c3185d08f1a31567e66a825b")
            + object("Zip/archivio.zip", 5, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            + object("Foto iPhone/._IMG_1.JPG", 4096, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            + "<NextContinuationToken>Foto iPhone/IMG_1.JPG</NextContinuationToken></ListBucketResult>",
        "Foto iPhone/IMG_1.JPG": "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + object("ASUS/Elba/FILE0056.MOV", 67_108_865, "96aa53ed4132d7e2986467263954caad-2")
            + "</ListBucketResult>",
    ]

    func testTwoPages_complete_keepsOnlyPhotosAndVideos() async throws {
        let pages = Self.twoPages
        let r = await reader.read(runId: 1, fetchPage: { token in
            guard let page = pages[token ?? ""] else { throw NetworkDown() }
            return page
        })
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.pages, 2)
        XCTAssertEqual(r.objectsListed, 4)
        XCTAssertEqual(r.objectsKept, 2, "niente archivi zip, niente sidecar `._`")
        try store.finishInventoryArchive(.s3, runId: 1, complete: true, reason: nil, unreadable: 0, finishedAt: 1)
        let s3 = try store.inventorySnapshot().s3
        XCTAssertEqual(s3.map(\.displayKey), ["ASUS/Elba/FILE0056.MOV", "Foto iPhone/IMG_1.JPG"])
        XCTAssertEqual(s3.map(\.key), ["asus/elba/file0056.mov", "foto iphone/img_1.jpg"],
                       "la chiave di confronto e' la stessa forma normalizzata dei dischi")
        XCTAssertEqual(s3[0].etag, "\"96aa53ed4132d7e2986467263954caad-2\"")
    }

    /// La lista si interrompe alla seconda pagina: la prima resta salvata (ADR-0002), ma
    /// Cubbit e' incompleto e da li' non si dichiara assente niente.
    func testNetworkFailureOnTheSecondPage_isIncomplete_firstPageKept() async throws {
        let first = Self.twoPages[""]!
        let r = await reader.read(runId: 1, fetchPage: { token in
            guard token == nil else { throw NetworkDown() }
            return first
        })
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.incompleteReason, .listingFailed)
        XCTAssertEqual(r.pages, 1)
        XCTAssertEqual(try store.inventorySnapshot().s3.count, 1)
    }

    func testTruncatedWithoutToken_isIncomplete() async {
        let page = "<ListBucketResult><IsTruncated>true</IsTruncated>"
            + Self.object("a.jpg", 1, "e722bbb0c3185d08f1a31567e66a825b") + "</ListBucketResult>"
        let r = await reader.read(runId: 1, fetchPage: { _ in page })
        XCTAssertTrue(r.truncatedWithoutToken)
        XCTAssertEqual(r.incompleteReason, .listingMalformed)
    }

    func testMalformedEntry_isIncomplete() async {
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key></Contents></ListBucketResult>"
        let r = await reader.read(runId: 1, fetchPage: { _ in page })
        XCTAssertEqual(r.malformedEntries, 1)
        XCTAssertEqual(r.incompleteReason, .listingMalformed)
    }

    func testStopBeforeTheFirstPage_asksNothing() async {
        flag.cancel()
        let r = await reader.read(runId: 1, fetchPage: { _ in
            XCTFail("dopo uno stop non si chiede niente a Cubbit")
            return ""
        })
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.pages, 0)
        XCTAssertEqual(r.incompleteReason, .interrupted)
    }

    func testStopAfterTheFirstPage_isAnInterruption() async {
        let pages = Self.twoPages
        let flag = self.flag!
        let r = await reader.read(runId: 1, fetchPage: { token in pages[token ?? ""] ?? "" },
                                  onProgress: { report in if report.pages == 1 { flag.cancel() } })
        XCTAssertEqual(r.pages, 1)
        XCTAssertTrue(r.cancelled)
        XCTAssertFalse(r.isComplete)
    }

    // MARK: - Perimetro

    func testPerimeter_isTheSameAsTheDisks() {
        let inside = ["Foto iPhone/IMG_1.JPG", "ASUS/recup_dir.37/f200571080.jpg", "Takeout/Foto/IMG_2.heic", "Other/v.mp4"]
        let outside = ["Zip/archivio.zip", "Takeout/Foto/IMG_2.heic.json", "Foto/._IMG_1.JPG", "Foto/.nascosta/a.jpg",
                       ".Trashes/501/a.jpg", "lost+found/a.jpg", "Foto/", "", "Foto/IMG.AAE"]
        for k in inside { XCTAssertTrue(InventoryPerimeter.includesS3Key(k), "dentro: \(k)") }
        for k in outside { XCTAssertFalse(InventoryPerimeter.includesS3Key(k), "fuori: \(k)") }
    }
}
```

e in coda a `MainThreadIsolationTests`:

```swift
    func testCubbitRead_runsWithoutTheMainThread() throws {
        let reader = InventoryCubbitReader(store: try makeStore(), cancelFlag: CancelFlag())
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await reader.read(runId: 1, fetchPage: { _ in page })
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryCubbitReader.read ha avuto bisogno del main thread (manca @concurrent?).")
    }
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryCubbitReaderTests` → atteso `error: cannot find 'InventoryCubbitReader' in scope`.
- [ ] **Step 3: implementa** in regione R, dopo `InventoryScanner`:

```swift
/// Com'e' andata la lettura dell'elenco di Cubbit per l'inventario.
nonisolated struct CubbitReadReport: Equatable, Sendable {
    var pages = 0
    /// Oggetti elencati, di qualunque tipo.
    var objectsListed = 0
    /// Oggetti nel perimetro (foto e video), quelli salvati.
    var objectsKept = 0
    /// Voci della lista senza chiave o senza dimensione leggibile.
    var malformedEntries = 0
    /// La lista dice "ce n'e' ancora" ma non dice da dove ripartire.
    var truncatedWithoutToken = false
    /// L'ultima pagina e' arrivata: la lista e' finita davvero.
    var reachedEnd = false
    var cancelled = false
    /// Testo dell'errore di rete o di salvataggio, per il registro. Mai mostrato cosi' com'e'.
    var failure: String? = nil
    var couldNotSave = false

    var isComplete: Bool { incompleteReason == nil }

    var incompleteReason: InventoryIncompleteReason? {
        if couldNotSave { return .couldNotSave }
        if cancelled { return .interrupted }
        if failure != nil { return .listingFailed }
        if malformedEntries > 0 || truncatedWithoutToken { return .listingMalformed }
        if !reachedEnd { return .interrupted }
        return nil
    }
}

/// Foto e video: lo stesso perimetro dei dischi, applicato alle chiavi di Cubbit.
// `nonisolated`: pura, chiamata dal lettore di Cubbit fuori dal main.
nonisolated enum InventoryPerimeter {
    /// Vero se un oggetto con questa chiave sarebbe stato letto dallo scanner dei dischi:
    /// nessuna componente nascosta (`.skipsHiddenFiles`, e quindi anche i `._` AppleDouble),
    /// nessuna componente fra `LibraryExclusions.names`, e `IndexableKind` foto o video.
    static func includesS3Key(_ key: String) -> Bool {
        let components = key.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !key.hasSuffix("/") else { return false }
        for c in components where c.hasPrefix(".") || LibraryExclusions.names.contains(String(c)) {
            return false
        }
        return IndexableKind.of(url: URL(fileURLWithPath: key)) != .notIndexable
    }
}

/// Legge l'elenco del bucket con l'ETag di ogni oggetto e lo salva a pagine. Nessun download,
/// nessuna scrittura su Cubbit: solo `ListObjectsV2`, la stessa richiesta di `S3Syncer.listPage`.
// `nonisolated`: `store` e `cancelFlag` sono `let`, custoditi rispettivamente dalla coda
// seriale dello store e dal lock di `CancelFlag`; il resto e' locale a `read`. `read` e'
// `@concurrent` (regola del progetto per le funzioni di fondo `async`, ADR-0006): senza, con
// `NonisolatedNonsendingByDefault` girerebbe sul thread di chi la chiama.
nonisolated final class InventoryCubbitReader: @unchecked Sendable {
    private let store: LibraryIndexStore
    private let cancelFlag: CancelFlag

    init(store: LibraryIndexStore, cancelFlag: CancelFlag) {
        self.store = store
        self.cancelFlag = cancelFlag
    }

    @concurrent
    func read(runId: Int64,
              fetchPage: @escaping @Sendable (String?) async throws -> String,
              onProgress: @escaping @Sendable (CubbitReadReport) -> Void = { _ in }) async -> CubbitReadReport {
        var report = CubbitReadReport()
        var token: String? = nil
        while true {
            if cancelFlag.isCancelled { report.cancelled = true; break }
            let xml: String
            do {
                xml = try await fetchPage(token)
            } catch {
                report.failure = error.localizedDescription
                break
            }
            let page = S3Syncer.parseListPage(xml)
            report.pages += 1
            report.objectsListed += page.objects.count
            report.malformedEntries += page.malformedEntries
            let rows = page.objects
                .filter { InventoryPerimeter.includesS3Key($0.key) }
                .map { InventoryS3Object(key: normalizedIndexKey($0.key), displayKey: $0.key,
                                         size: $0.size, etag: $0.etag) }
            do {
                try store.upsertInventoryS3(rows, runId: runId)
            } catch {
                report.couldNotSave = true
                report.failure = error.localizedDescription
                break
            }
            report.objectsKept += rows.count
            onProgress(report)
            guard page.isTruncated else { report.reachedEnd = true; break }
            guard let next = page.nextToken else { report.truncatedWithoutToken = true; break }
            token = next
        }
        onProgress(report)
        return report
    }
}
```

- [ ] **Step 4:** `InventoryCubbitReaderTests` → `Executed 7 tests, with 0 failures`; `MainThreadIsolationTests` → `Executed 17 tests`.
- [ ] **Step 5:** build pulita + suite: `B+83` (944).
- [ ] **Mutante che deve morire:** `guard let next = page.nextToken else { reachedEnd = true … }` al posto di `truncatedWithoutToken` (muore `testTruncatedWithoutToken_isIncomplete`); tolto `malformedEntries > 0` da `incompleteReason` (muore `testMalformedEntry_isIncomplete`); tolto il filtro di perimetro (muore `testTwoPages_complete_keepsOnlyPhotosAndVideos`).
- [ ] **Step 6: commit.** `Inventario, task 6: lista di Cubbit con l'ETag, a pagine, senza scaricare niente` + attribuzione.

---

### Task 7: `InventoryClassifier` e `InventorySummary` — dai tre elenchi alle categorie

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo `InventoryCubbitReader`.
- Create: `AppBackupFotoTests/InventoryClassifierTests.swift` (4 punti: `E1EB0DF8A234B0B8A0802230` / `571CCCE2BF5254CBC5C95301`).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda).

**Interfaces:**
- Consumes: modello del Task 4, `S3ETagMatcher` (Task 3).
- Produces (tutto `nonisolated … Sendable`):
  - `enum InventoryCategory: String, CaseIterable { case toCheck, onlyOutsideSSD, missingSomewhere, safe, undetermined }` (l'ordine è la precedenza)
  - `enum InventoryCheckReason: String, Hashable { case samePathDifferentContent, cubbitNotCertifiable }`
  - `struct InventoryItem: Equatable, Identifiable { let id: String; let category: InventoryCategory; let size: Int64; let presentOn, missingFrom, unknownOn: Set<InventoryArchive>; let checkReasons: Set<InventoryCheckReason>; let exampleArchive: InventoryArchive; let examplePath: String }`
  - `struct InventoryArchiveStats: Equatable { var files = 0; var extraCopies = 0; var reclaimableBytes: Int64 = 0 }`
  - `enum InventoryClassifier { static func classify(_ s: InventorySnapshot) -> (items: [InventoryItem], stats: [InventoryArchive: InventoryArchiveStats]) }`
  - `struct InventorySummary: Equatable { static let defaultSampleLimit = 300; let states; let stats; let counts: [InventoryCategory: Int]; let bytes: [InventoryCategory: Int64]; let samples: [InventoryCategory: [InventoryItem]]; init(_ snapshot: InventorySnapshot, sampleLimit: Int); func count(_:) -> Int; func bytes(_:) -> Int64 }`

**Le regole, in una tabella** (ciascuna ha almeno un test):

| Regola | Dove |
| :--- | :--- |
| Contenuto = SHA256 fra SSD e HDD; Cubbit via `S3ETagMatcher` contro file letti della stessa dimensione | passi 1-2 |
| Solo-Cubbit a parte unica → id `md5:<md5>`; non certificabile → id `s3:<chiave>`, ❗ | passo 2 (S5) |
| Stesso percorso normalizzato su ≥ 2 archivi con contenuti diversi → ❗ per tutti | passo 3 |
| Oggetto non certificabile → ❗ anche per i contenuti allo stesso percorso su SSD/HDD | passo 3 |
| Copie in più per archivio, esclusi i file vuoti e gli oggetti non certificabili | passo 4 |
| ❗ > 🔎 (assente dall'SSD **completo**) > ⚠️ (assente da almeno un archivio **completo**) > ✅ > ⏳ | passo 5 |

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryClassifierTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `InventoryClassifier` (ROADMAP #44): dai tre elenchi alle categorie. E' il pezzo su cui i
/// progetti 2-4 decideranno copie e cancellazioni, quindi ogni regola della spec ha qui almeno
/// un test, e ogni precedenza il suo.
///
/// Convenzione dei dati finti: il contenuto «X» ha SHA256 "sha-X" e MD5 fatto di 32 volte la
/// lettera minuscola di X (esadecimale valido per a-f); l'oggetto Cubbit con ETag uguale a
/// quell'MD5 e' la stessa foto.
final class InventoryClassifierTests: XCTestCase {

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func file(_ path: String, _ content: Character, size: Int64 = 10,
                      status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: size, mtime: 1,
                           status: status,
                           digest: status == .ok
                               ? ContentDigest(size: size, sha256: "sha-\(content)", md5: md5(content), multipartETag: nil)
                               : nil,
                           hashedAt: 2)
    }

    private func object(_ key: String, _ content: Character, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: "\"\(md5(content))\"")
    }

    private func objectWithETag(_ key: String, _ etag: String?, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: etag)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true) -> [InventoryArchive: InventoryArchiveState] {
        func st(_ a: InventoryArchive, _ c: Bool) -> InventoryArchiveState {
            InventoryArchiveState(archive: a, runId: 1, complete: c, reason: c ? nil : .interrupted,
                                  unreadable: 0, startedAt: 0, finishedAt: 1)
        }
        return [.ssd: st(.ssd, ssd), .hdd: st(.hdd, hdd), .s3: st(.s3, s3)]
    }

    private func classify(ssd: [InventoryLocalFile] = [], hdd: [InventoryLocalFile] = [], s3: [InventoryS3Object] = [],
                          states: [InventoryArchive: InventoryArchiveState]? = nil) -> [InventoryItem] {
        InventoryClassifier.classify(InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states ?? self.states())).items
    }

    private func item(_ items: [InventoryItem], _ id: String) -> InventoryItem? { items.first { $0.id == id } }

    // MARK: - Le quattro categorie della spec

    func testOnAllThree_isSafe() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].category, .safe)
        XCTAssertEqual(items[0].presentOn, [.ssd, .hdd, .s3])
    }

    /// L'unita' e' il contenuto, non il nome: la stessa foto con nomi diversi nei tre posti e'
    /// comunque al sicuro.
    func testSameContentUnderDifferentNames_isStillSafe() {
        let items = classify(ssd: [file("Foto iPhone/IMG_1.JPG", "a")], hdd: [file("Takeout/copia.jpg", "a")],
                             s3: [object("Other/altro-nome.jpg", "a")])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    func testMissingFromTheHDD_isMissingSomewhere_andSaysWhere() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.hdd])
        XCTAssertTrue(items[0].unknownOn.isEmpty)
    }

    func testOnlyOnTheSSD_isMissingFromBoth() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.hdd, .s3])
    }

    func testOnlyOnTheHDD_isOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].presentOn, [.hdd])
    }

    /// Il materiale che c'e' solo su Cubbit (i ~20 GB in piu' dello zero-delete): riconosciuto
    /// dall'MD5, senza scaricarlo.
    func testOnlyOnCubbit_isOnlyOutsideTheSSD() {
        let items = classify(s3: [object("ASUS/vecchia.jpg", "e")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].id, "md5:\(md5("e"))")
    }

    func testSamePathDifferentContent_isToCheck_forBothContents() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "b")],
                             s3: [object("Foto/a.jpg", "a"), object("x.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
        XCTAssertEqual(item(items, "sha-b")?.category, .toCheck)
        XCTAssertEqual(item(items, "sha-a")?.checkReasons, [.samePathDifferentContent])
    }

    /// Il confronto per percorso usa la chiave normalizzata: maiuscole diverse e Unicode NFD/NFC
    /// sono lo stesso percorso (ExFAT e APFS lo trattano cosi').
    func testSamePath_isComparedOnNormalizedKeys() {
        let nfd = "Foto/Citta\u{0300}.jpg"
        let nfc = "Foto/Citt\u{00E0}.JPG"
        let items = classify(ssd: [file(nfd, "a")], hdd: [file(nfc, "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    func testSamePathSameContent_isNotAConflict() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .safe)
    }

    /// Copie in piu' dello stesso contenuto dentro un solo archivio non sono un conflitto.
    func testTwoCopiesInOneArchive_areNotAConflict() {
        let items = classify(ssd: [file("Foto/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                             hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    /// Un oggetto Cubbit a pezzi che nessun file locale riproduce: non certificabile, quindi da
    /// controllare — e con lui la foto che sta allo stesso percorso sull'SSD, che su Cubbit
    /// potrebbe esserci come no.
    func testNotCertifiableCubbitObject_isToCheck_andSoIsTheLocalFileAtThatPath() {
        let items = classify(ssd: [file("Video/lungo.mov", "a", size: 67_108_865)],
                             hdd: [file("Video/lungo.mov", "a", size: 67_108_865)],
                             s3: [objectWithETag("Video/lungo.mov", "\"96aa53ed4132d7e2986467263954caad-13\"", size: 67_108_865)])
        XCTAssertEqual(item(items, "s3:Video/lungo.mov")?.category, .toCheck)
        XCTAssertEqual(item(items, "s3:Video/lungo.mov")?.checkReasons, [.cubbitNotCertifiable])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck, "mai «manca da Cubbit» ne' «al sicuro» per ipotesi")
    }

    func testCubbitObjectWithAnUnknownETag_isToCheck() {
        let items = classify(s3: [objectWithETag("strano.jpg", "\"boh\"")])
        XCTAssertEqual(items.map(\.category), [.toCheck])
    }

    /// Il caso verificato sui dati veri (FILE0056.MOV): l'ETag a pezzi ricalcolato dal file
    /// locale coincide, quindi l'oggetto e' certificato e la foto e' al sicuro.
    func testMultipartObjectMatchingTheLocalFile_isSafe() {
        let d = ContentDigest(size: 67_108_865, sha256: "sha-big", md5: "9c800b6accf6f26be7e8684d46ffdedb",
                              multipartETag: "96aa53ed4132d7e2986467263954caad-2")
        let local = InventoryLocalFile(key: "asus/elba/file0056.mov", displayPath: "ASUS/Elba/FILE0056.MOV",
                                       size: 67_108_865, mtime: 1, status: .ok, digest: d, hashedAt: 2)
        let items = classify(ssd: [local], hdd: [local],
                             s3: [objectWithETag("ASUS/Elba/FILE0056.MOV", "\"96aa53ed4132d7e2986467263954caad-2\"", size: 67_108_865)])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    // MARK: - Precedenze (❗ > 🔎 > ⚠️ > ✅)

    func testToCheck_winsOverOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    func testToCheck_winsOverMissingSomewhere() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    /// Solo sull'HDD e non su Cubbit: vale sia 🔎 sia ⚠️, e vince 🔎.
    func testOnlyOutsideTheSSD_winsOverMissingSomewhere() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].missingFrom, [.ssd, .s3])
    }

    // MARK: - Incompleto non e' assente

    func testIncompleteHDD_neverSaysMissingFromTheHDD() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")], states: states(hdd: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertTrue(items[0].missingFrom.isEmpty)
        XCTAssertEqual(items[0].unknownOn, [.hdd])
    }

    func testIncompleteSSD_neverSaysOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")], states: states(ssd: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertEqual(items[0].unknownOn, [.ssd])
    }

    func testIncompleteCubbit_neverSaysMissingFromCubbit() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], states: states(s3: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertEqual(items[0].unknownOn, [.s3])
    }

    /// Un archivio incompleto sospende solo le assenze che dipendono da lui: se la foto manca
    /// anche da un archivio COMPLETO, quella mancanza si dice.
    func testIncompleteSSD_stillAllowsMissingFromACompleteCubbit() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], states: states(ssd: false))
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.s3])
        XCTAssertEqual(items[0].unknownOn, [.ssd])
    }

    /// Una presenza vista vale anche su un archivio incompleto: «c'e'» e' una conoscenza,
    /// «non c'e'» no.
    func testPresenceOnAnIncompleteArchive_stillCounts() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")],
                             states: states(hdd: false, s3: false))
        XCTAssertEqual(items[0].category, .safe)
    }

    /// Un file illeggibile non e' un contenuto (non si sa cosa contiene), ma e' un file.
    func testUnreadableLocalFile_isAFileButNotAContent() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("Foto/rotto.jpg", "a", status: .unreadable)], states: states()))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.stats[.ssd]?.files, 1)
    }

    /// Un file illeggibile non rende «certificato» niente su Cubbit: senza impronte non e' un
    /// candidato.
    func testUnreadableLocalFile_neverCertifiesACubbitObject() {
        let items = classify(ssd: [file("Foto/a.jpg", "a", status: .unreadable)], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.map(\.id), ["md5:\(md5("a"))"])
    }

    // MARK: - Numeri per archivio

    func testExtraCopies_andRecoverableSpace_perArchive() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("A/a.jpg", "a", size: 100), file("B/a.jpg", "a", size: 100), file("C/a.jpg", "a", size: 100),
                  file("A/b.jpg", "b", size: 7)],
            hdd: [file("A/a.jpg", "a", size: 100)],
            s3: [object("A/a.jpg", "a", size: 100), object("B/a.jpg", "a", size: 100)],
            states: states()))
        XCTAssertEqual(result.stats[.ssd], InventoryArchiveStats(files: 4, extraCopies: 2, reclaimableBytes: 200))
        XCTAssertEqual(result.stats[.hdd], InventoryArchiveStats(files: 1, extraCopies: 0, reclaimableBytes: 0))
        XCTAssertEqual(result.stats[.s3], InventoryArchiveStats(files: 2, extraCopies: 1, reclaimableBytes: 100))
    }

    /// Tutti i file vuoti hanno la stessa impronta: non sono copie l'uno dell'altro (stessa
    /// regola di `LibraryIndexStore.duplicateGroups`).
    func testEmptyFiles_areNeverExtraCopies() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("a.jpg", "a", size: 0), file("b.jpg", "a", size: 0)], states: states()))
        XCTAssertEqual(result.stats[.ssd]?.extraCopies, 0)
    }

    /// Oggetti non certificabili non si contano come copie: sotto-stimare lo spazio
    /// recuperabile e' innocuo, sovra-stimarlo no.
    func testNotCertifiableObjects_areNeverExtraCopies() {
        let etag = "\"96aa53ed4132d7e2986467263954caad-13\""
        let result = InventoryClassifier.classify(InventorySnapshot(
            s3: [objectWithETag("a.mov", etag, size: 67_108_865), objectWithETag("b.mov", etag, size: 67_108_865)],
            states: states()))
        XCTAssertEqual(result.stats[.s3]?.files, 2)
        XCTAssertEqual(result.stats[.s3]?.extraCopies, 0)
    }

    // MARK: - Proprieta' generali

    func testEveryContentFallsInExactlyOneCategory_andNothingIsLost() {
        let items = classify(ssd: [file("1.jpg", "a"), file("2.jpg", "b"), file("x.jpg", "c")],
                             hdd: [file("1.jpg", "a"), file("3.jpg", "d"), file("x.jpg", "e")],
                             s3: [object("1.jpg", "a"), object("4.jpg", "f"), objectWithETag("5.jpg", "\"boh\"")])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "nessun contenuto due volte")
        XCTAssertEqual(Set(items.map(\.id)),
                       ["sha-a", "sha-b", "sha-c", "sha-d", "sha-e", "md5:\(md5("f"))", "s3:5.jpg"])
    }

    func testResult_doesNotDependOnTheInputOrder() {
        let ssd = [file("1.jpg", "a"), file("2.jpg", "b"), file("3.jpg", "c")]
        let hdd = [file("1.jpg", "a"), file("2.jpg", "d")]
        let s3 = [object("1.jpg", "a"), object("9.jpg", "e")]
        let one = InventoryClassifier.classify(InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states()))
        let two = InventoryClassifier.classify(InventorySnapshot(ssd: ssd.reversed(), hdd: hdd.reversed(),
                                                                 s3: s3.reversed(), states: states()))
        XCTAssertEqual(one.items, two.items)
        XCTAssertEqual(one.stats, two.stats)
    }

    /// Il percorso di esempio e' quello dell'SSD quando c'e': e' il posto che Enrico conosce.
    func testExamplePath_prefersTheSSD() {
        let items = classify(ssd: [file("Foto iPhone/a.jpg", "a")], hdd: [file("AAA/a.jpg", "a")], s3: [object("0/a.jpg", "a")])
        XCTAssertEqual(items[0].exampleArchive, .ssd)
        XCTAssertEqual(items[0].examplePath, "Foto iPhone/a.jpg")
    }

    func testSummary_limitsTheSamples_butNotTheCounts() {
        let many = (0..<5).map { file("f\($0).jpg", Character(UnicodeScalar(UInt8(97 + $0)))) }
        let summary = InventorySummary(InventorySnapshot(ssd: many, states: states()), sampleLimit: 2)
        XCTAssertEqual(summary.count(.missingSomewhere), 5)
        XCTAssertEqual(summary.samples[.missingSomewhere]?.count, 2)
        XCTAssertEqual(summary.bytes(.missingSomewhere), 50)
        XCTAssertEqual(summary.count(.safe), 0)
    }
}
```

e in coda a `MainThreadIsolationTests`:

```swift
    func testInventorySummary_runsWithoutTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = InventorySummary(InventorySnapshot(), sampleLimit: 10)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventorySummary/InventoryClassifier hanno avuto bisogno del main thread.")
    }
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryClassifierTests` → atteso `error: cannot find 'InventoryClassifier' in scope`.
- [ ] **Step 3: implementa** in regione R, dopo `InventoryCubbitReader`:

```swift
/// In quale categoria cade un contenuto. L'ordine dei casi e' la PRECEDENZA della spec
/// (❗ > 🔎 > ⚠️ > ✅), con «non si puo' ancora dire» per ultimo: non e' un esito, e' il posto
/// dei contenuti su cui la regola «incompleto non e' assente» sospende il giudizio.
nonisolated enum InventoryCategory: String, CaseIterable, Sendable {
    case toCheck
    case onlyOutsideSSD
    case missingSomewhere
    case safe
    case undetermined
}

nonisolated enum InventoryCheckReason: String, Hashable, Sendable {
    /// Stesso percorso relativo, contenuto diverso, fra due archivi.
    case samePathDifferentContent
    /// Un oggetto Cubbit che non si riesce a confrontare senza scaricarlo — lui, e la foto
    /// che sta allo stesso percorso su SSD o HDD.
    case cubbitNotCertifiable
}

/// Un contenuto (non un file): tutte le copie con la stessa impronta, nei tre archivi.
nonisolated struct InventoryItem: Equatable, Sendable, Identifiable {
    /// L'SHA256; `md5:<md5>` per un contenuto che c'e' solo su Cubbit, riconosciuto dal suo
    /// MD5; `s3:<chiave>` per un oggetto Cubbit non certificabile (contenuto sconosciuto).
    let id: String
    let category: InventoryCategory
    let size: Int64
    let presentOn: Set<InventoryArchive>
    /// Archivi COMPLETI da cui manca: solo qui si puo' dire «manca».
    let missingFrom: Set<InventoryArchive>
    /// Archivi incompleti da cui non risulta: «non si sa ancora».
    let unknownOn: Set<InventoryArchive>
    let checkReasons: Set<InventoryCheckReason>
    /// Un percorso da mostrare: quello dell'SSD se c'e', poi HDD, poi Cubbit; a parita', il
    /// primo in ordine alfabetico. Cosi' il risultato non dipende dall'ordine delle righe.
    let exampleArchive: InventoryArchive
    let examplePath: String
}

/// I numeri in testa alla finestra, per archivio.
nonisolated struct InventoryArchiveStats: Equatable, Sendable {
    /// File foto e video letti (anche quelli illeggibili: ci sono, anche se non si sa cosa
    /// contengono) o oggetti Cubbit nel perimetro.
    var files = 0
    /// Copie in piu' dello stesso contenuto nello stesso archivio.
    var extraCopies = 0
    /// Spazio che si libererebbe tenendone una sola per contenuto.
    var reclaimableBytes: Int64 = 0
}

/// Dai tre elenchi alle categorie. Logica PURA: nessun disco, nessuna rete, nessun database.
/// E' il pezzo su cui i progetti 2-4 decideranno copie e cancellazioni (sempre rileggendo i
/// file prima, ADR-0005), quindi e' il piu' testato (`InventoryClassifierTests`).
///
/// Due confronti, come nella spec:
/// 1. **per contenuto** — SHA256 fra SSD e HDD; verso Cubbit con l'ETag (`S3ETagMatcher`),
///    solo contro file letti della stessa dimensione;
/// 2. **per percorso** — stesso percorso relativo (chiave normalizzata) su due archivi con
///    contenuto diverso: ❗ per entrambi i contenuti.
///
/// La regola che conta di piu': si dice «manca da X» solo se X e' stato letto per intero.
nonisolated enum InventoryClassifier {
    private struct Content {
        var size: Int64
        var present: Set<InventoryArchive> = []
        var reasons: Set<InventoryCheckReason> = []
        var example: (archive: InventoryArchive, path: String)
    }

    static func classify(_ s: InventorySnapshot) -> (items: [InventoryItem], stats: [InventoryArchive: InventoryArchiveStats]) {
        var contents: [String: Content] = [:]
        var stats: [InventoryArchive: InventoryArchiveStats] = [.ssd: .init(), .hdd: .init(), .s3: .init()]
        var copies: [InventoryArchive: [String: Int]] = [.ssd: [:], .hdd: [:], .s3: [:]]
        var byPath: [String: [InventoryArchive: Set<String>]] = [:]
        var uncertainS3Paths = Set<String>()

        func record(id: String, size: Int64, archive: InventoryArchive, key: String, displayPath: String) {
            if var c = contents[id] {
                c.present.insert(archive)
                if (archive, displayPath) < (c.example.archive, c.example.path) { c.example = (archive, displayPath) }
                contents[id] = c
            } else {
                contents[id] = Content(size: size, present: [archive], example: (archive, displayPath))
            }
            copies[archive]![id, default: 0] += 1
            byPath[key, default: [:]][archive, default: []].insert(id)
        }

        // 1. SSD e HDD: un contenuto per SHA256. Un file illeggibile conta come file, non come
        //    contenuto, e non puo' certificare niente su Cubbit.
        var candidatesBySize: [Int64: [S3ETagMatcher.Candidate]] = [:]
        var knownSha = Set<String>()
        for (archive, files) in [(InventoryArchive.ssd, s.ssd), (.hdd, s.hdd)] {
            for f in files {
                stats[archive]!.files += 1
                guard f.status == .ok, let d = f.digest else { continue }
                record(id: d.sha256, size: f.size, archive: archive, key: f.key, displayPath: f.displayPath)
                if knownSha.insert(d.sha256).inserted {
                    candidatesBySize[f.size, default: []].append(
                        .init(size: f.size, sha256: d.sha256, md5: d.md5, multipartETag: d.multipartETag))
                }
            }
        }

        // 2. Cubbit: certificato, riconosciuto dal solo MD5, o non certificabile.
        for o in s.s3 {
            stats[.s3]!.files += 1
            switch S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: candidatesBySize[o.size] ?? []) {
            case .certified(let sha):
                record(id: sha, size: o.size, archive: .s3, key: o.key, displayPath: o.displayKey)
            case .identifiedOnlyByMD5(let md5):
                record(id: "md5:" + md5, size: o.size, archive: .s3, key: o.key, displayPath: o.displayKey)
            case .notCertifiable:
                contents["s3:" + o.displayKey] = Content(size: o.size, present: [.s3], reasons: [.cubbitNotCertifiable],
                                                         example: (.s3, o.displayKey))
                uncertainS3Paths.insert(o.key)
            }
        }

        // 3. Per percorso: stesso percorso su almeno due archivi, piu' di un contenuto.
        for (_, perArchive) in byPath where perArchive.count >= 2 {
            let ids = perArchive.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            guard ids.count > 1 else { continue }
            for id in ids { contents[id]!.reasons.insert(.samePathDifferentContent) }
        }
        // Un oggetto Cubbit non certificabile rende incerta anche la foto allo stesso percorso:
        // su Cubbit potrebbe esserci come no.
        for key in uncertainS3Paths {
            for (archive, ids) in byPath[key] ?? [:] where archive != .s3 {
                for id in ids { contents[id]!.reasons.insert(.cubbitNotCertifiable) }
            }
        }

        // 4. Copie in piu' per archivio. I file vuoti hanno tutti la stessa impronta e non sono
        //    copie l'uno dell'altro (stessa regola di `LibraryIndexStore.duplicateGroups`).
        for archive in InventoryArchive.allCases {
            for (id, n) in copies[archive]! where n > 1 {
                let size = contents[id]!.size
                guard size > 0 else { continue }
                stats[archive]!.extraCopies += n - 1
                stats[archive]!.reclaimableBytes += Int64(n - 1) * size
            }
        }

        // 5. Categorie, con la precedenza della spec.
        var items: [InventoryItem] = []
        items.reserveCapacity(contents.count)
        for (id, c) in contents {
            let missing = Set(InventoryArchive.allCases).subtracting(c.present)
            let missingKnown = missing.filter { s.isComplete($0) }
            let unknown = missing.subtracting(missingKnown)
            let category: InventoryCategory
            if !c.reasons.isEmpty {
                category = .toCheck
            } else if !c.present.contains(.ssd) && s.isComplete(.ssd) {
                category = .onlyOutsideSSD
            } else if !missingKnown.isEmpty {
                category = .missingSomewhere
            } else if missing.isEmpty {
                category = .safe
            } else {
                category = .undetermined
            }
            items.append(InventoryItem(id: id, category: category, size: c.size, presentOn: c.present,
                                       missingFrom: missingKnown, unknownOn: unknown, checkReasons: c.reasons,
                                       exampleArchive: c.example.archive, examplePath: c.example.path))
        }
        let order = Dictionary(uniqueKeysWithValues: InventoryCategory.allCases.enumerated().map { ($1, $0) })
        items.sort { a, b in
            if a.category != b.category { return order[a.category]! < order[b.category]! }
            if a.examplePath != b.examplePath { return a.examplePath < b.examplePath }
            return a.id < b.id
        }
        return (items, stats)
    }
}

/// Quello che la finestra Inventario mostra, calcolato una volta fuori dal main: numeri per
/// categoria e per archivio, e un campione limitato di voci per categoria. L'elenco completo
/// (centinaia di migliaia di contenuti) non viaggia verso la UI.
nonisolated struct InventorySummary: Equatable, Sendable {
    /// Quante voci per categoria si mostrano al massimo. La finestra dice sempre quante sono
    /// in tutto (`InventoryStatus.sampleLimitLine`): mai un elenco tagliato in silenzio.
    static let defaultSampleLimit = 300

    let states: [InventoryArchive: InventoryArchiveState]
    let stats: [InventoryArchive: InventoryArchiveStats]
    let counts: [InventoryCategory: Int]
    let bytes: [InventoryCategory: Int64]
    let samples: [InventoryCategory: [InventoryItem]]

    init(_ snapshot: InventorySnapshot, sampleLimit: Int) {
        let (items, stats) = InventoryClassifier.classify(snapshot)
        var counts: [InventoryCategory: Int] = [:]
        var bytes: [InventoryCategory: Int64] = [:]
        var samples: [InventoryCategory: [InventoryItem]] = [:]
        for item in items {
            counts[item.category, default: 0] += 1
            bytes[item.category, default: 0] += item.size
            if samples[item.category, default: []].count < sampleLimit {
                samples[item.category, default: []].append(item)
            }
        }
        self.states = snapshot.states
        self.stats = stats
        self.counts = counts
        self.bytes = bytes
        self.samples = samples
    }

    func count(_ c: InventoryCategory) -> Int { counts[c] ?? 0 }
    func bytes(_ c: InventoryCategory) -> Int64 { bytes[c] ?? 0 }
}
```

- [ ] **Step 4:** `InventoryClassifierTests` → `Executed 30 tests, with 0 failures`; `MainThreadIsolationTests` → `Executed 18 tests`.
- [ ] **Step 5:** build pulita + suite: `B+114` (975).
- [ ] **Mutante che deve morire:** `missingKnown = missing` senza filtro di completezza (verificato: muoiono i test «Incomplete…»); 🔎 valutato dopo ⚠️ (verificato: muoiono `testOnlyOutsideTheSSD_winsOverMissingSomewhere` e altri); `perArchive.count >= 2` → `>= 1` (muore `testTwoCopiesInOneArchive_areNotAConflict`); tolto `guard size > 0` (muore `testEmptyFiles_areNeverExtraCopies`).
- [ ] **Step 6: commit.** `Inventario, task 7: le categorie, con la regola «incompleto non è assente»` + attribuzione.

---

### Task 8: `InventoryRefresh` e `InventoryStartGate` — il giro completo, fuori dal main

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo `InventorySummary`.
- Create: `AppBackupFotoTests/InventoryRefreshTests.swift` (4 punti: `C08CBD0B92948BEFEE0428F4` / `D32A3EFFFFA66AAE2C29C8E6`).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda).

**Interfaces:**
- Consumes: Task 4-7, `CancelFlag`.
- Produces:
  - `nonisolated enum InventoryProgress: Equatable, Sendable { case checkingCubbit, local(InventoryArchive, InventoryScanReport), cubbit(CubbitReadReport), classifying }`
  - `nonisolated struct InventoryRefreshOutcome: Sendable { let summary: InventorySummary?; let failure: String? }`
  - `nonisolated enum InventoryRefresh { @concurrent static func run(store: LibraryIndexStore, ssdRoot: URL, hddRoot: URL, runId: Int64, cancelFlag: CancelFlag, sampleLimit: Int = InventorySummary.defaultSampleLimit, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }, fetchPage: @escaping @Sendable (String?) async throws -> String, onProgress: @escaping @Sendable (InventoryProgress) -> Void) async -> InventoryRefreshOutcome }`
  - `enum InventoryStartGate { static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool, isRestoringFromTrash: Bool, isInventorying: Bool, ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String?; static let cubbitUnreachable: String; static func volumeChangeStopsInventory(unmounting volume: URL?, ssdRoot: URL?, hddRoot: URL?) -> Bool }` (MainActor per default del target, come `JobStartGate`).

**Regole del giro:** ordine SSD → HDD → Cubbit (D2); un archivio non raggiunto dopo uno stop si chiude con `.notReached`; un errore di salvataggio con `.couldNotSave`; il confronto si fa sempre su quello che c'è nel database a fine giro. Precedenza del cancello: operazioni in corso (inventario, spostamento, annullamento, backup, lettura dell'elenco) prima dei dischi mancanti e delle credenziali.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryRefreshTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Il cancello di partenza dell'inventario e il giro completo SSD → HDD → Cubbit → confronto
/// (ROADMAP #44), con due cartelle temporanee al posto dei dischi e un Cubbit finto.
final class InventoryRefreshTests: XCTestCase {
    private var tempDir: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryRefreshTests-\(UUID().uuidString)")
        ssd = tempDir.appendingPathComponent("SSD")
        hdd = tempDir.appendingPathComponent("HDD")
        for d in [ssd!, hdd!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: url.path)
    }

    private func md5(_ text: String) -> String {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize().md5
    }

    // MARK: - Cancello di partenza

    private func reason(isRunning: Bool = false, isIndexing: Bool = false, isTrashingDuplicates: Bool = false,
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
        InventoryStartGate.blockedReason(isRunning: isRunning, isIndexing: isIndexing,
                                         isTrashingDuplicates: isTrashingDuplicates,
                                         isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                         ssdMounted: ssdMounted, hddMounted: hddMounted, hasCubbitConfig: hasCubbitConfig)
    }

    func testNothingInTheWay_canStart() {
        XCTAssertNil(reason())
    }

    /// Ogni condizione ferma la partenza con una frase sua: chi legge deve capire quale.
    func testEachCondition_blocksWithItsOwnReason() {
        let all = [reason(isRunning: true), reason(isIndexing: true), reason(isTrashingDuplicates: true),
                   reason(isRestoringFromTrash: true), reason(isInventorying: true), reason(ssdMounted: false),
                   reason(hddMounted: false), reason(hasCubbitConfig: false)]
        XCTAssertTrue(all.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(all.compactMap { $0 }).count, all.count, "otto motivi, otto frasi diverse")
        XCTAssertTrue(reason(ssdMounted: false)!.contains("SSD"))
        XCTAssertTrue(reason(hddMounted: false)!.contains("HDD"))
        XCTAssertTrue(reason(hasCubbitConfig: false)!.contains("Cubbit"))
    }

    /// Un'operazione in corso si dice prima di un disco mancante: e' la causa su cui l'utente
    /// puo' fare qualcosa subito ("aspetta"), e un disco si ricollega dopo.
    func testOperationsInProgress_comeBeforeMissingDisks() {
        XCTAssertEqual(reason(isRunning: true, ssdMounted: false), reason(isRunning: true))
        XCTAssertEqual(reason(isRunning: true, isInventorying: true), reason(isInventorying: true))
    }

    func testReasons_haveNoJargon() {
        let gergo = ["hash", "sha", "md5", "etag", "indice", "scansione", "cache", "bucket", "sqlite", "multipart"]
        let texts = [reason(isRunning: true), reason(isIndexing: true), reason(isTrashingDuplicates: true),
                     reason(isRestoringFromTrash: true), reason(isInventorying: true), reason(ssdMounted: false),
                     reason(hddMounted: false), reason(hasCubbitConfig: false), InventoryStartGate.cubbitUnreachable]
        for t in texts.compactMap({ $0?.lowercased() }) {
            for g in gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(t)»") }
        }
    }

    // MARK: - Dischi che si smontano

    func testUnmountingTheSSDOrTheHDD_stopsTheInventory() {
        let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
        let hddRoot = URL(fileURLWithPath: "/Volumes/BackupHDD")
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/SSD - Enri/"), ssdRoot: ssdRoot, hddRoot: hddRoot))
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/BackupHDD"), ssdRoot: ssdRoot, hddRoot: hddRoot))
    }

    /// Espellere una chiavetta o un'immagine disco non butta via un giro di decine di minuti;
    /// e un nome che comincia come quello dell'SSD non e' l'SSD.
    func testUnmountingAnotherDisk_doesNotStopIt() {
        let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
        let hddRoot = URL(fileURLWithPath: "/Volumes/BackupHDD")
        XCTAssertFalse(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/CHIAVETTA"), ssdRoot: ssdRoot, hddRoot: hddRoot))
        XCTAssertFalse(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/SSD - Enri 2"), ssdRoot: ssdRoot, hddRoot: hddRoot))
    }

    /// Se macOS non dice quale disco se ne va, ci si ferma: e' il verso prudente.
    func testUnknownDisk_stopsTheInventory() {
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: nil, ssdRoot: URL(fileURLWithPath: "/Volumes/SSD - Enri"), hddRoot: nil))
    }

    // MARK: - Il giro completo

    func testFullRun_readsTheThreeArchives_andClassifies() async throws {
        try put(ssd, "Foto iPhone/a.jpg", "alfa")      // ovunque
        try put(ssd, "Foto iPhone/b.jpg", "beta")      // manca dall'HDD
        try put(hdd, "Foto iPhone/a.jpg", "alfa")
        try put(hdd, "Vecchie/c.jpg", "gamma")         // solo sull'HDD
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>Foto iPhone/a.jpg</Key><ETag>&quot;\(md5("alfa"))&quot;</ETag><Size>4</Size></Contents>"
            + "<Contents><Key>Foto iPhone/b.jpg</Key><ETag>&quot;\(md5("beta"))&quot;</ETag><Size>4</Size></Contents>"
            + "</ListBucketResult>"
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 42,
                                                 cancelFlag: CancelFlag(), fetchPage: { _ in page },
                                                 onProgress: { _ in })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(InventoryArchive.allCases.allSatisfy { summary.states[$0]?.complete == true })
        XCTAssertEqual(summary.count(.safe), 1)
        XCTAssertEqual(summary.count(.missingSomewhere), 1)
        XCTAssertEqual(summary.samples[.missingSomewhere]?.first?.missingFrom, [.hdd])
        XCTAssertEqual(summary.count(.onlyOutsideSSD), 1)
        XCTAssertEqual(summary.stats[.ssd]?.files, 2)
        XCTAssertEqual(summary.stats[.hdd]?.files, 2)
        XCTAssertEqual(summary.stats[.s3]?.files, 2)
    }

    /// Fermato durante l'SSD: HDD e Cubbit non sono stati letti, e restano «non letti» — mai i
    /// numeri del giro prima spacciati per quelli di oggi, mai «assente» per colpa loro.
    func testStopDuringTheSSD_leavesTheOthersNotReached() async throws {
        try put(ssd, "Foto/a.jpg", "alfa")
        try put(hdd, "Foto/a.jpg", "alfa")
        let flag = CancelFlag()
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1, cancelFlag: flag,
                                                 fetchPage: { _ in
                                                     XCTFail("fermato prima di Cubbit: non si chiede niente")
                                                     return ""
                                                 },
                                                 onProgress: { p in if case .local(.ssd, _) = p { flag.cancel() } })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertEqual(summary.states[.ssd]?.reason, .interrupted)
        XCTAssertEqual(summary.states[.hdd]?.reason, .notReached)
        XCTAssertEqual(summary.states[.s3]?.reason, .notReached)
        XCTAssertEqual(summary.count(.missingSomewhere) + summary.count(.onlyOutsideSSD), 0,
                       "nessuna foto dichiarata mancante da archivi non letti")
    }

    /// L'HDD sparito prima di partire (il caso della prova dal vivo): l'HDD risulta incompleto
    /// e nessuna foto passa in ⚠️ per colpa sua.
    func testMissingHDD_neverMakesAPhotoMissingFromIt() async throws {
        try put(ssd, "Foto/a.jpg", "alfa")
        try FileManager.default.removeItem(at: hdd)
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>Foto/a.jpg</Key><ETag>&quot;\(md5("alfa"))&quot;</ETag><Size>4</Size></Contents></ListBucketResult>"
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1,
                                                 cancelFlag: CancelFlag(), fetchPage: { _ in page }, onProgress: { _ in })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertEqual(summary.states[.hdd]?.reason, .volumeVanished)
        XCTAssertEqual(summary.count(.missingSomewhere), 0)
        XCTAssertEqual(summary.count(.undetermined), 1)
    }
}
```

e in coda a `MainThreadIsolationTests`:

```swift
    func testInventoryRefresh_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD"), hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd, hdd] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let store = try makeStore()
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1, cancelFlag: CancelFlag(),
                                           fetchPage: { _ in page }, onProgress: { _ in })
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryRefresh.run ha avuto bisogno del main thread (manca @concurrent?).")
    }
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryRefreshTests` → atteso `error: cannot find 'InventoryStartGate' in scope`.
- [ ] **Step 3: implementa** in regione R, dopo `InventorySummary`:

```swift
/// A che punto e' un aggiornamento dell'inventario, per la barra della finestra.
nonisolated enum InventoryProgress: Equatable, Sendable {
    case checkingCubbit
    case local(InventoryArchive, InventoryScanReport)
    case cubbit(CubbitReadReport)
    case classifying
}

/// Com'e' finito un aggiornamento: il riepilogo nuovo, oppure il motivo per cui non c'e'.
nonisolated struct InventoryRefreshOutcome: Sendable {
    let summary: InventorySummary?
    /// Testo per il registro, mai mostrato cosi' com'e'.
    let failure: String?
}

/// L'aggiornamento completo: SSD, poi HDD, poi Cubbit, poi il confronto. Separato da
/// `BackupRunner` perche' sia verificabile da un test con cartelle temporanee e un Cubbit
/// finto; `BackupRunner` ci mette solo i bookmark, il cancello e la pubblicazione sul main.
// `nonisolated`: nessuno stato, tutto e' nei parametri. `@concurrent`: e' una funzione di fondo
// `async`, e senza girerebbe sul thread di chi la chiama (ADR-0006).
nonisolated enum InventoryRefresh {
    @concurrent
    static func run(store: LibraryIndexStore, ssdRoot: URL, hddRoot: URL, runId: Int64,
                    cancelFlag: CancelFlag,
                    sampleLimit: Int = InventorySummary.defaultSampleLimit,
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                    fetchPage: @escaping @Sendable (String?) async throws -> String,
                    onProgress: @escaping @Sendable (InventoryProgress) -> Void) async -> InventoryRefreshOutcome {
        do {
            try store.beginInventoryRun(runId: runId, startedAt: now())
        } catch {
            return InventoryRefreshOutcome(summary: nil, failure: error.localizedDescription)
        }
        let scanner = InventoryScanner(store: store, cancelFlag: cancelFlag)
        for (archive, root) in [(InventoryArchive.ssd, ssdRoot), (.hdd, hddRoot)] {
            guard !cancelFlag.isCancelled else {
                try? store.finishInventoryArchive(archive, runId: runId, complete: false, reason: .notReached,
                                                  unreadable: 0, finishedAt: now())
                continue
            }
            do {
                let report = try scanner.scan(root: root, archive: archive, runId: runId) { r in
                    onProgress(.local(archive, r))
                }
                try store.finishInventoryArchive(archive, runId: runId, complete: report.isComplete,
                                                 reason: report.incompleteReason,
                                                 unreadable: report.unreadableFiles, finishedAt: now())
            } catch {
                try? store.finishInventoryArchive(archive, runId: runId, complete: false, reason: .couldNotSave,
                                                  unreadable: 0, finishedAt: now())
            }
        }
        if cancelFlag.isCancelled {
            try? store.finishInventoryArchive(.s3, runId: runId, complete: false, reason: .notReached,
                                              unreadable: 0, finishedAt: now())
        } else {
            let reader = InventoryCubbitReader(store: store, cancelFlag: cancelFlag)
            let report = await reader.read(runId: runId, fetchPage: fetchPage) { r in onProgress(.cubbit(r)) }
            try? store.finishInventoryArchive(.s3, runId: runId, complete: report.isComplete,
                                              reason: report.incompleteReason, unreadable: 0, finishedAt: now())
        }
        onProgress(.classifying)
        do {
            let snapshot = try store.inventorySnapshot()
            return InventoryRefreshOutcome(summary: InventorySummary(snapshot, sampleLimit: sampleLimit), failure: nil)
        } catch {
            return InventoryRefreshOutcome(summary: nil, failure: error.localizedDescription)
        }
    }
}

/// Perche' «Aggiorna l'inventario» non puo' partire adesso, `nil` se puo'. Il verso opposto
/// (niente backup, lettura dell'elenco, spostamento o annullamento durante l'inventario) sta
/// nei cancelli di quelle operazioni, col parametro `isInventorying`.
enum InventoryStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
        if isInventorying { return "L'inventario si sta già aggiornando." }
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino delle copie doppie: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
        if isRunning {
            return "C'è un backup in corso: aspetta che finisca, altrimenti l'inventario "
                + "leggerebbe i dischi mentre cambiano."
        }
        if isIndexing {
            return "L'app sta aggiornando l'elenco delle foto sull'SSD: aspetta che finisca."
        }
        if !ssdMounted {
            return "L'SSD non è collegato: l'inventario ha bisogno di SSD, HDD e Cubbit insieme."
        }
        if !hddMounted {
            return "L'HDD non è collegato: l'inventario ha bisogno di SSD, HDD e Cubbit insieme."
        }
        if !hasCubbitConfig {
            return "L'app non ha letto le credenziali di Cubbit: controlla in Diagnostica, poi riprova."
        }
        return nil
    }

    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."

    /// Un disco si sta smontando durante l'inventario: ci si ferma solo se e' l'SSD o l'HDD
    /// (o se macOS non dice quale, per prudenza). Diverso dalla lettura dell'elenco, che si
    /// ferma a ogni smontaggio: li' costa poco, qui un giro dura decine di minuti, ed espellere
    /// una chiavetta non deve buttarlo via. Il confronto e' per componenti, mai per prefisso
    /// di stringa (`/Volumes/SSD` non e' `/Volumes/SSD 2`).
    static func volumeChangeStopsInventory(unmounting volume: URL?, ssdRoot: URL?, hddRoot: URL?) -> Bool {
        guard let volume else { return true }
        let target = volume.standardizedFileURL.pathComponents
        return [ssdRoot, hddRoot].compactMap { $0 }.contains { $0.standardizedFileURL.pathComponents == target }
    }
}
```

- [ ] **Step 4:** `InventoryRefreshTests` → `Executed 10 tests, with 0 failures`; `MainThreadIsolationTests` → `Executed 19 tests`.
- [ ] **Step 5:** build pulita + suite: `B+125` (986).
- [ ] **Mutante che deve morire:** ramo `guard !cancelFlag.isCancelled` che chiude l'archivio come completo (muore `testStopDuringTheSSD_leavesTheOthersNotReached`); `volumeChangeStopsInventory` che confronta con `hasPrefix` sulle stringhe (muore `testUnmountingAnotherDisk_doesNotStopIt`, caso «SSD - Enri 2»).
- [ ] **Step 6: commit.** `Inventario, task 8: il giro SSD, HDD, Cubbit e il cancello di partenza` + attribuzione.

---

### Task 9: `InventoryStatus` — i testi della finestra, puri e senza gergo

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo `InventoryStartGate`.
- Create: `AppBackupFotoTests/InventoryStatusTests.swift` (4 punti: `410F77B6DAC6CC5324775DA3` / `51437C0FB531B995488AA29D`).

**Interfaces:**
- Consumes: Task 4-8.
- Produces: `enum InventoryStatus` (MainActor, come `DuplicatesStatus`) con `Tone`, `Line`, `displayOrder`, `readOnlyNote`, `refreshButton`, `stopButton`, `stoppingLine`, `loadingLine`, `archiveName(_:)`, `title(_:)`, `explanation(_:)`, `categoryLine(_:count:bytes:)`, `archiveLine(_:stats:)`, `completenessLine(_:state:) -> Line?`, `freshnessLine(states:now:calendar:) -> Line`, `itemLine(_:)`, `progressLine(_:)`, `sampleLimitLine(shown:total:) -> String?`.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/InventoryStatusTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// I testi della finestra Inventario (ROADMAP #44): tutti in `InventoryStatus`, nessuno nella
/// View, e nessuna parola tecnica — la finestra la legge Enrico, non un programmatore.
final class InventoryStatusTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text)»", file: file, line: line) }
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func state(_ a: InventoryArchive, complete: Bool, reason: InventoryIncompleteReason? = nil,
                       unreadable: Int = 0, runId: Int64 = 1, startedAt: Double = 0,
                       finishedAt: Double? = 0) -> InventoryArchiveState {
        InventoryArchiveState(archive: a, runId: runId, complete: complete, reason: complete ? nil : reason,
                              unreadable: unreadable, startedAt: startedAt, finishedAt: finishedAt)
    }

    private func item(_ c: InventoryCategory, present: Set<InventoryArchive>, missing: Set<InventoryArchive> = [],
                      unknown: Set<InventoryArchive> = [], reasons: Set<InventoryCheckReason> = []) -> InventoryItem {
        InventoryItem(id: "x", category: c, size: 10, presentOn: present, missingFrom: missing, unknownOn: unknown,
                      checkReasons: reasons, exampleArchive: present.sorted().first ?? .ssd,
                      examplePath: "Foto iPhone/IMG_1.JPG")
    }

    func testTitles_areTheFourOfTheSpec_plusNotYetKnown() {
        XCTAssertEqual(InventoryStatus.displayOrder.map { InventoryStatus.title($0) },
                       ["✅ Al sicuro", "⚠️ Manca da qualche parte", "🔎 Solo fuori dall'SSD",
                        "❗ Da controllare", "⏳ Non si può ancora dire"])
        XCTAssertEqual(Set(InventoryStatus.displayOrder), Set(InventoryCategory.allCases))
    }

    func testCategoryLine_singularAndPlural() {
        XCTAssertTrue(InventoryStatus.categoryLine(.safe, count: 1, bytes: 10).contains("1 foto o video"))
        XCTAssertTrue(InventoryStatus.categoryLine(.safe, count: 2, bytes: 10).contains("2 foto e video"))
    }

    func testArchiveLine_withAndWithoutExtraCopies() {
        let none = InventoryStatus.archiveLine(.hdd, stats: InventoryArchiveStats(files: 3, extraCopies: 0, reclaimableBytes: 0))
        XCTAssertTrue(none.hasPrefix("HDD: 3 foto e video"))
        XCTAssertTrue(none.contains("nessuna copia in più"))
        let one = InventoryStatus.archiveLine(.s3, stats: InventoryArchiveStats(files: 3, extraCopies: 1, reclaimableBytes: 10))
        XCTAssertTrue(one.hasPrefix("Cubbit:"))
        XCTAssertTrue(one.contains("1 copia in più"))
        XCTAssertTrue(one.contains("tenendone una sola"))
        let many = InventoryStatus.archiveLine(.ssd, stats: InventoryArchiveStats(files: 9, extraCopies: 5, reclaimableBytes: 10))
        XCTAssertTrue(many.contains("5 copie in più"))
    }

    func testCompleteness_nothingToSayWhenComplete() {
        XCTAssertNil(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: true)))
    }

    func testCompleteness_neverRead() {
        let line = InventoryStatus.completenessLine(.hdd, state: nil)
        XCTAssertEqual(line?.id, "never-hdd")
        XCTAssertEqual(line?.tone, .info)
    }

    /// Ogni motivo ha la sua frase, e ogni frase dice la regola: da li' non si dichiara
    /// mancante niente.
    func testCompleteness_everyReasonHasItsOwnText_andStatesTheRule() {
        let reasons: [InventoryIncompleteReason] = [.running, .notReached, .interrupted, .volumeVanished,
                                                     .foldersUnreadable, .filesUnreadable, .sawNothing,
                                                     .listingFailed, .listingMalformed, .couldNotSave]
        var texts = Set<String>()
        for r in reasons {
            let line = InventoryStatus.completenessLine(.hdd, state: state(.hdd, complete: false, reason: r, unreadable: 3))
            XCTAssertEqual(line?.tone, .warning)
            XCTAssertTrue(line?.text.contains("non dice mai che una foto manca") == true, "\(r)")
            assertNoJargon(line?.text ?? "")
            texts.insert(line?.text ?? "")
        }
        XCTAssertEqual(texts.count, reasons.count)
    }

    func testCompleteness_unreadableFiles_singularAndPlural() {
        XCTAssertTrue(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: false, reason: .filesUnreadable,
                                                                          unreadable: 1))!.text.contains("1 file non si è lasciato"))
        XCTAssertTrue(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: false, reason: .filesUnreadable,
                                                                          unreadable: 4))!.text.contains("4 file non si sono lasciati"))
    }

    func testFreshness_neverDone() {
        let line = InventoryStatus.freshnessLine(states: [:], now: Date(), calendar: utc)
        XCTAssertEqual(line.id, "never")
        XCTAssertEqual(line.tone, .info)
    }

    func testFreshness_completeRun_saysWhen() {
        let finished = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26 00:00 UTC
        let states = Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, state($0, complete: true, finishedAt: finished.timeIntervalSince1970))
        })
        let today = InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(3_600), calendar: utc)
        XCTAssertEqual(today.id, "complete")
        XCTAssertTrue(today.text.contains("oggi"))
        XCTAssertTrue(today.text.contains("26 settembre 2026"))
        XCTAssertTrue(InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(86_400),
                                                    calendar: utc).text.contains("ieri"))
        XCTAssertTrue(InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(5 * 86_400),
                                                    calendar: utc).text.contains("5 giorni fa"))
    }

    func testFreshness_incompleteRun_isAWarning() {
        let states: [InventoryArchive: InventoryArchiveState] = [
            .ssd: state(.ssd, complete: true), .hdd: state(.hdd, complete: false, reason: .interrupted),
            .s3: state(.s3, complete: true)]
        let line = InventoryStatus.freshnessLine(states: states, now: Date(timeIntervalSince1970: 0), calendar: utc)
        XCTAssertEqual(line.id, "incomplete")
        XCTAssertEqual(line.tone, .warning)
    }

    func testItemLine_perCategory() {
        XCTAssertTrue(InventoryStatus.itemLine(item(.safe, present: [.ssd, .hdd, .s3])).contains("su SSD, HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.missingSomewhere, present: [.ssd], missing: [.hdd, .s3]))
            .contains("manca da: HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.missingSomewhere, present: [.hdd], missing: [.s3], unknown: [.ssd]))
            .contains("su SSD non si sa ancora"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.onlyOutsideSSD, present: [.hdd, .s3])).contains("c'è solo su HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.toCheck, present: [.ssd], reasons: [.samePathDifferentContent]))
            .contains("stesso nome"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.toCheck, present: [.s3], reasons: [.cubbitNotCertifiable]))
            .contains("senza scaricarla"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.undetermined, present: [.ssd], unknown: [.hdd]))
            .contains("su HDD non si sa ancora"))
    }

    func testProgressLine_saysTheStepOutOfThree() {
        var r = InventoryScanReport(); r.scanned = 12; r.reread = 3
        XCTAssertTrue(InventoryStatus.progressLine(.local(.ssd, r)).hasPrefix("1 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.local(.hdd, r)).hasPrefix("2 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.local(.hdd, r)).contains("12 viste"))
        var c = CubbitReadReport(); c.objectsKept = 7
        XCTAssertTrue(InventoryStatus.progressLine(.cubbit(c)).hasPrefix("3 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.cubbit(c)).contains("7"))
    }

    func testSampleLimitLine() {
        XCTAssertNil(InventoryStatus.sampleLimitLine(shown: 3, total: 3))
        XCTAssertEqual(InventoryStatus.sampleLimitLine(shown: 300, total: 450), "Qui ne vedi 300 su 450, in ordine di nome.")
    }

    func testReadOnlyNote_namesAllThreePlaces() {
        for name in ["SSD", "HDD", "Cubbit"] { XCTAssertTrue(InventoryStatus.readOnlyNote.contains(name)) }
    }

    /// Tutte le diramazioni, non un campione.
    func testNoJargon_onEveryText() {
        var texts = [InventoryStatus.readOnlyNote, InventoryStatus.stoppingLine, InventoryStatus.loadingLine,
                     InventoryStatus.refreshButton, InventoryStatus.stopButton,
                     InventoryStatus.freshnessLine(states: [:], now: Date(), calendar: utc).text,
                     InventoryStatus.progressLine(.checkingCubbit), InventoryStatus.progressLine(.classifying),
                     InventoryStatus.progressLine(.cubbit(CubbitReadReport())),
                     InventoryStatus.progressLine(.local(.ssd, InventoryScanReport()))]
        for c in InventoryCategory.allCases {
            texts.append(InventoryStatus.title(c))
            texts.append(InventoryStatus.explanation(c))
            texts.append(InventoryStatus.categoryLine(c, count: 2, bytes: 1_000))
            texts.append(InventoryStatus.itemLine(item(c, present: [.ssd], missing: [.hdd], unknown: [.s3],
                                                       reasons: [.samePathDifferentContent])))
            texts.append(InventoryStatus.itemLine(item(c, present: [.s3], reasons: [.cubbitNotCertifiable])))
        }
        for a in InventoryArchive.allCases {
            texts.append(InventoryStatus.archiveLine(a, stats: InventoryArchiveStats(files: 2, extraCopies: 1, reclaimableBytes: 5)))
            texts.append(InventoryStatus.completenessLine(a, state: nil)!.text)
        }
        texts.forEach { assertNoJargon($0) }
    }
}
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/InventoryStatusTests` → atteso `error: cannot find 'InventoryStatus' in scope`.
- [ ] **Step 3: implementa** in regione R, dopo `InventoryStartGate`:

```swift
/// I testi della finestra Inventario. Logica pura, come `DuplicatesStatus`: nessuna stringa
/// nasce dentro la View. Registro: niente gergo («hash», «impronta», «ETag», «MD5», «indice»,
/// «scansione», «bucket», «cache»): Enrico legge SSD, HDD, Cubbit, foto e video.
enum InventoryStatus {
    enum Tone: Equatable { case ok, info, warning }

    struct Line: Identifiable, Equatable {
        let id: String
        let tone: Tone
        let text: String
    }

    /// Ordine in cui la finestra mostra le categorie: quello della tabella della spec, con
    /// «non si può ancora dire» in fondo.
    static let displayOrder: [InventoryCategory] = [.safe, .missingSomewhere, .onlyOutsideSSD, .toCheck, .undetermined]

    static let readOnlyNote = "Questa finestra guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit."
    static let refreshButton = "Aggiorna l'inventario"
    static let stopButton = "Interrompi"
    static let stoppingLine = "Mi fermo appena finisco il file o la pagina dell'elenco che sto leggendo…"
    static let loadingLine = "Leggo l'ultimo inventario salvato…"

    static func archiveName(_ a: InventoryArchive) -> String {
        switch a {
        case .ssd: return "SSD"
        case .hdd: return "HDD"
        case .s3: return "Cubbit"
        }
    }

    static func title(_ c: InventoryCategory) -> String {
        switch c {
        case .safe: return "✅ Al sicuro"
        case .missingSomewhere: return "⚠️ Manca da qualche parte"
        case .onlyOutsideSSD: return "🔎 Solo fuori dall'SSD"
        case .toCheck: return "❗ Da controllare"
        case .undetermined: return "⏳ Non si può ancora dire"
        }
    }

    static func explanation(_ c: InventoryCategory) -> String {
        switch c {
        case .safe:
            return "Ci sono sull'SSD, sull'HDD e su Cubbit, e l'app ha verificato che sono identiche in tutti e tre i posti."
        case .missingSomewhere:
            return "Ci sono in uno o due posti ma mancano dagli altri: per ognuna l'app dice da dove manca."
        case .onlyOutsideSSD:
            return "Ci sono sull'HDD o su Cubbit, ma sull'SSD non ci sono più."
        case .toCheck:
            return "Con lo stesso nome c'è un contenuto diverso in due posti, oppure la copia su Cubbit "
                + "non si può confrontare senza scaricarla. Queste non verranno mai toccate in automatico."
        case .undetermined:
            return "Mancano da un posto che l'app non è riuscita a leggere per intero: finché non lo "
                + "legge tutto, non dice che mancano."
        }
    }

    static func categoryLine(_ c: InventoryCategory, count: Int, bytes: Int64) -> String {
        "\(title(c)): \(photos(count)) (\(size(bytes)))"
    }

    static func archiveLine(_ a: InventoryArchive, stats: InventoryArchiveStats) -> String {
        guard stats.extraCopies > 0 else {
            return "\(archiveName(a)): \(photos(stats.files)) · nessuna copia in più"
        }
        let copies = stats.extraCopies == 1 ? "1 copia in più" : "\(number(stats.extraCopies)) copie in più"
        return "\(archiveName(a)): \(photos(stats.files)) · \(copies) · \(size(stats.reclaimableBytes)) "
            + "si possono recuperare tenendone una sola"
    }

    /// `nil` se l'archivio e' stato letto per intero nell'ultimo aggiornamento.
    static func completenessLine(_ a: InventoryArchive, state: InventoryArchiveState?) -> Line? {
        let name = archiveName(a)
        guard let state else {
            return Line(id: "never-\(a.rawValue)", tone: .info, text: "\(name): non ancora letto.")
        }
        guard !state.complete else { return nil }
        let why: String
        switch state.reason ?? .interrupted {
        case .running:
            why = "l'ultimo aggiornamento non è arrivato in fondo (l'app si è chiusa a metà)."
        case .notReached:
            why = "non è stato letto, perché l'aggiornamento si è fermato prima di arrivarci."
        case .interrupted:
            why = "la lettura è stata fermata prima della fine."
        case .volumeVanished:
            why = "il disco è stato scollegato mentre l'app lo leggeva."
        case .foldersUnreadable:
            why = "alcune cartelle non si sono lasciate aprire (permessi o errori di lettura)."
        case .filesUnreadable:
            why = state.unreadable == 1
                ? "1 file non si è lasciato leggere per intero."
                : "\(number(state.unreadable)) file non si sono lasciati leggere per intero."
        case .sawNothing:
            why = "l'app non ha trovato nessuna foto, mentre la volta prima ce n'erano."
        case .listingFailed:
            why = "l'elenco si è interrotto per un problema di rete."
        case .listingMalformed:
            why = "l'elenco è arrivato con delle voci che l'app non ha saputo leggere."
        case .couldNotSave:
            why = "l'app non è riuscita a salvare quello che leggeva."
        }
        return Line(id: "incomplete-\(a.rawValue)", tone: .warning, text:
            "\(name): \(why) Finché non viene letto per intero, l'app non dice mai che una foto manca da lì.")
    }

    static func freshnessLine(states: [InventoryArchive: InventoryArchiveState], now: Date,
                              calendar: Calendar = .current) -> Line {
        guard !states.isEmpty else {
            return Line(id: "never", tone: .info, text:
                "L'inventario non è mai stato fatto. La prima volta l'app rilegge per intero l'SSD e "
                + "l'HDD, e ci vogliono decine di minuti.")
        }
        let runIds = Set(states.values.map(\.runId))
        let allComplete = InventoryArchive.allCases.allSatisfy { states[$0]?.complete == true }
        let started = states.values.map(\.startedAt).max() ?? 0
        let finished = states.values.compactMap(\.finishedAt).max() ?? started
        if allComplete && runIds.count == 1 {
            return Line(id: "complete", tone: .ok, text:
                "Inventario completo, aggiornato \(when(finished, now: now, calendar: calendar)).")
        }
        return Line(id: "incomplete", tone: .warning, text:
            "L'ultimo aggiornamento (\(when(started, now: now, calendar: calendar))) non è completo: "
            + "qui sotto trovi quali posti non sono stati letti per intero.")
    }

    static func itemLine(_ item: InventoryItem) -> String {
        let place = "«\(item.examplePath)» (\(archiveName(item.exampleArchive)))"
        switch item.category {
        case .safe:
            return "\(place) — su SSD, HDD e Cubbit"
        case .missingSomewhere:
            var text = "\(place) — manca da: \(names(item.missingFrom))"
            if !item.unknownOn.isEmpty { text += "; su \(names(item.unknownOn)) non si sa ancora" }
            return text
        case .onlyOutsideSSD:
            return "\(place) — c'è solo su \(names(item.presentOn))"
        case .toCheck:
            if item.checkReasons.contains(.samePathDifferentContent) {
                return "\(place) — con lo stesso nome, altrove c'è un contenuto diverso"
            }
            return "\(place) — la copia su Cubbit non si può confrontare senza scaricarla"
        case .undetermined:
            return "\(place) — c'è su \(names(item.presentOn)); su \(names(item.unknownOn)) non si sa ancora"
        }
    }

    static func progressLine(_ p: InventoryProgress) -> String {
        switch p {
        case .checkingCubbit:
            return "Controllo che Cubbit risponda…"
        case .local(let archive, let r):
            let step = archive == .ssd ? "1 di 3" : "2 di 3"
            return "\(step) · Leggo le foto sull'\(archiveName(archive)): \(number(r.scanned)) viste, "
                + "\(number(r.reread)) lette da capo"
        case .cubbit(let r):
            return "3 di 3 · Chiedo a Cubbit l'elenco delle foto: \(number(r.objectsKept)) finora"
        case .classifying:
            return "Metto a confronto SSD, HDD e Cubbit…"
        }
    }

    /// `nil` quando si vedono tutte.
    static func sampleLimitLine(shown: Int, total: Int) -> String? {
        guard total > shown else { return nil }
        return "Qui ne vedi \(number(shown)) su \(number(total)), in ordine di nome."
    }

    // MARK: - Aiuti

    private static func photos(_ n: Int) -> String { n == 1 ? "1 foto o video" : "\(number(n)) foto e video" }
    private static func number(_ n: Int) -> String { n.formatted() }
    private static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private static func names(_ set: Set<InventoryArchive>) -> String {
        let list = set.sorted().map { archiveName($0) }
        guard list.count > 1 else { return list.first ?? "" }
        return list.dropLast().joined(separator: ", ") + " e " + list.last!
    }

    private static func when(_ t: Double, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .long
        f.timeStyle = .none
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let ago: String
        switch days {
        case ..<1: ago = "oggi"
        case 1: ago = "ieri"
        default: ago = "\(days) giorni fa"
        }
        return "\(ago), il \(f.string(from: date))"
    }
}
```

- [ ] **Step 4:** `InventoryStatusTests` → `Executed 15 tests, with 0 failures`.
- [ ] **Step 5:** build pulita + suite: `B+140` (1.001).
- [ ] **Mutante che deve morire:** la regola «non dice mai che una foto manca» tolta da un solo motivo (muore `testCompleteness_everyReasonHasItsOwnText_andStatesTheRule`); plurale di `archiveLine` deciso su `> 0` (muore `testArchiveLine_withAndWithoutExtraCopies`).
- [ ] **Step 6: commit.** `Inventario, task 9: i testi della finestra Inventario` + attribuzione.

---

### Task 10: cablaggio in `BackupRunner` e mutua esclusione in entrambi i versi

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `DuplicatesStatus.trashDisabledReason` (3652) e `.undoDisabledReason` (3686); `JobStartGate.blockedReason` (5451); `LibraryIndexCommandGate.disabledReason` (5473) e `.resetDisabledReason` (5502); `BackupRunner`: `beginDuplicateTrashing` (8711), `beginTrashRestore` (8738), chiamate in `startTrashRestore` (8808), `startDuplicateTrashRun` (8912), `rebuildLibraryIndex` (9257), `resetLibraryIndex` (9312 e ramo di successo 9320-9327), `run(label:…)` (10113), osservatore in `init` (9103-9111), nuova sezione prima del commento `` // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati `` (9345); `LibraryIndexCard.commandsDisabledReason` (13434); `DuplicatesView` (14005, 14028).
- Modify (test): `JobStartGateTests` (+1), `LibraryIndexStatusTests` (+2), `DuplicatesStatusTests` (+2), e **tutte** le chiamate esistenti ai cinque cancelli in quei tre file (firma, non asserzioni: regola 4).

**Interfaces:**
- Consumes: `InventoryRefresh`, `InventoryStartGate`, `InventorySummary`, `InventoryProgress`, `InventoryStatus.stopButton`, `S3Syncer.fetchListPageXML`/`checkReachable`, `CancelFlag`, `VolumeMonitor.shared`, `libraryIndexStore`, `s3Config`, `bm`.
- Produces:
  - `JobStartGate.blockedReason(isIndexing:isTrashingDuplicates:isRestoringFromTrash:isInventorying:)`
  - `LibraryIndexCommandGate.disabledReason(isIndexing:jobIsRunning:isTrashingDuplicates:isRestoringFromTrash:isInventorying:)`
  - `LibraryIndexCommandGate.resetDisabledReason(isIndexing:jobIsRunning:isTrashingDuplicates:isInventorying:)`
  - `DuplicatesStatus.trashDisabledReason(isRunning:isIndexing:ssdMounted:isTrashingDuplicates:isRestoringFromTrash:isInventorying:)`
  - `DuplicatesStatus.undoDisabledReason(ssdMounted:isRunning:isIndexing:isTrashingDuplicates:isRestoringFromTrash:summary:hasEverTrashed:isInventorying:)`
  - su `BackupRunner`: `@Published private(set) var isInventorying: Bool`, `inventoryProgress: InventoryProgress?`, `inventoryStopRequested: Bool`, `inventorySummary: InventorySummary?`, `isLoadingInventory: Bool`; `func startInventoryRefresh(onAlert: @escaping AlertSink)`, `func stopInventoryRefresh()`, `func loadInventoryIfNeeded()`, `private func finishInventoryRefresh(summary:)`, `private func stopInventoryForVolumeChange(_:)`.
  - Tutti i parametri `isInventorying` sono **senza default** (stessa disciplina di ADR-0009).

- [ ] **Step 1: test che falliscono.** In coda a `JobStartGateTests` (prima della `}` finale):

```swift
    // MARK: - Inventario in corso (ROADMAP #44)

    /// L'inventario legge SSD, HDD e Cubbit: un job che ci scrive sopra non parte, con una
    /// frase sua, diversa dalle altre tre.
    func testInventoryInProgress_blocksWithItsOwnReason() {
        let inventory = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false,
                                                   isRestoringFromTrash: false, isInventorying: true)
        XCTAssertNotNil(inventory)
        XCTAssertTrue(inventory!.contains("inventario"))
        for other in [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false)] {
            XCTAssertNotEqual(inventory, other)
        }
    }
```

In coda a `LibraryIndexStatusTests`:

```swift
    // MARK: - Inventario in corso (ROADMAP #44)

    func testCommandGate_blocksDuringTheInventory_withItsOwnReason() {
        let reason = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false,
                                                            isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                            isInventorying: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }

    /// Svuotare l'elenco durante l'inventario cancellerebbe il file su cui l'inventario sta scrivendo.
    func testResetGate_blocksDuringTheInventory() {
        let reason = LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: false,
                                                                 isTrashingDuplicates: false, isInventorying: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }
```

In coda a `DuplicatesStatusTests`:

```swift
    // MARK: - Inventario in corso (ROADMAP #44)

    func testTrashDisabled_duringTheInventory() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          isInventorying: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }

    func testUndoDisabled_duringTheInventory() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                         isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                         summary: nil, hasEverTrashed: true, isInventorying: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }
```

- [ ] **Step 2:** `… -only-testing:AppBackupFotoTests/JobStartGateTests` → atteso `error: extra argument 'isInventorying' in call`.

- [ ] **Step 3: i cinque cancelli.**

(a) `JobStartGate.blockedReason` diventa (i tre rami esistenti identici; il ramo nuovo fra annullamento e lettura):

```swift
    static func blockedReason(isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool) -> String? {
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino le copie doppie che hai confermato. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto le foto che avevi spostato nel Cestino. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        // ROADMAP #44: l'inventario legge SSD, HDD e Cubbit; un job che ci scrive sopra
        // renderebbe falso quello che sta leggendo.
        if isInventorying {
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit. Aspetta che finisca, "
                + "oppure fermalo con «\(InventoryStatus.stopButton)» nella finestra Inventario."
        }
        if isIndexing {
            return "L'app sta leggendo le foto sull'SSD per aggiornare l'elenco. Aspetta che "
                + "finisca, oppure fermala con «\(LibraryIndexCommands.stop)» in Diagnostica."
        }
        return nil
    }
```

(b) `LibraryIndexCommandGate.disabledReason`: firma con `isInventorying: Bool` in fondo; subito dopo il ramo `isRestoringFromTrash` e prima di `isIndexing`:

```swift
        if isInventorying {
            return "L'app sta facendo l'inventario e sta leggendo le stesse foto: aggiornare "
                + "l'elenco adesso rallenterebbe entrambe le cose. Riprova quando ha finito."
        }
```

(c) `LibraryIndexCommandGate.resetDisabledReason`: firma `(isIndexing: Bool, jobIsRunning: Bool, isTrashingDuplicates: Bool, isInventorying: Bool)`; subito dopo il ramo `isTrashingDuplicates`:

```swift
        if isInventorying {
            return "L'inventario sta scrivendo in questo stesso elenco: svuotarlo adesso lo "
                + "lascerebbe a metà. Riprova quando ha finito."
        }
```

(d) `DuplicatesStatus.trashDisabledReason`: firma con `isInventorying: Bool` in fondo; subito prima di `return nil`:

```swift
        guard !isInventorying else {
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit: aspetta che finisca "
                + "prima di spostare copie nel Cestino."
        }
```

(e) `DuplicatesStatus.undoDisabledReason`: firma con `isInventorying: Bool` dopo `hasEverTrashed:`; subito dopo il `guard !isIndexing` e prima di `guard summary != nil`:

```swift
        guard !isInventorying else {
            return "L'app sta facendo l'inventario: aspetta che finisca prima di annullare lo "
                + "spostamento."
        }
```

(f) Chiamate di produzione: aggiungi come ultimo argomento `isInventorying: isInventorying` (in `BackupRunner`: 8808, 8912, 9257, 9312, 10113) o `isInventorying: runner.isInventorying` (in `LibraryIndexCard` 13434, `DuplicatesView` 14005 e 14028).

(g) Chiamate nei test: compila; **ogni** errore `missing argument for parameter 'isInventorying'` in `JobStartGateTests`, `LibraryIndexStatusTests`, `DuplicatesStatusTests` si corregge aggiungendo `, isInventorying: false` prima della parentesi di chiusura di quella chiamata. Nessuna asserzione cambia. Verifica finale: `grep -c "isInventorying" AppBackupFotoTests/{JobStartGateTests,LibraryIndexStatusTests,DuplicatesStatusTests}.swift` deve contare almeno le chiamate originali (17, 21, 28) più quelle dei test nuovi.

- [ ] **Step 4: `BackupRunner`.**

(a) `beginDuplicateTrashing()` e `beginTrashRestore()`: nella `guard` aggiungi `!isInventorying`, e nel messaggio sostituisci `(un backup, una lettura dell'elenco, …` con `(un backup, una lettura dell'elenco, un inventario, …` (resto identico).

(b) Nuova sezione, prima del commento `` // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati ``:

```swift
    // MARK: Inventario certificato (ROADMAP #44, ADR-0015)

    /// Vero mentre l'inventario legge SSD, HDD e Cubbit. Vive QUI e non in uno `@State` di
    /// `InventoryView`, per la stessa ragione di `isTrashingDuplicates`: chiudere e riaprire la
    /// finestra non deve far perdere ne' la mutua esclusione con job, letture, spostamenti e
    /// annullamenti, ne' la barra e «Interrompi» (regola D3 di ROADMAP #41).
    @Published private(set) var isInventorying = false
    @Published private(set) var inventoryProgress: InventoryProgress? = nil
    @Published private(set) var inventoryStopRequested = false
    /// L'ultimo confronto calcolato. `nil` = non ancora letto in questa sessione, o elenco
    /// appena svuotato: la finestra lo chiede con `loadInventoryIfNeeded()`.
    @Published private(set) var inventorySummary: InventorySummary? = nil
    @Published private(set) var isLoadingInventory = false
    private var inventoryCancelFlag: CancelFlag? = nil

    /// «Aggiorna l'inventario». Le precondizioni si rivalutano QUI, all'avvio vero (stessa
    /// disciplina di `rebuildLibraryIndex`), e `isInventorying` si alza PRIMA della domanda a
    /// Cubbit: da quel momento nessun backup, lettura, spostamento o annullamento puo' partire.
    func startInventoryRefresh(onAlert: @escaping AlertSink) {
        if let reason = InventoryStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let store = libraryIndexStore, let config = s3Config else {
            onAlert(SimpleAlert(title: "Inventario non disponibile",
                                message: "Non è stato possibile aprire sul Mac l'elenco in cui l'inventario viene salvato."))
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd), isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            onAlert(SimpleAlert(title: "SSD non valido",
                                message: "Vai in Impostazioni e riseleziona l'SSD scegliendo '/Volumes/SSD - Enri' (la radice del disco, non una cartella)."))
            return
        }
        guard let hddURL = bm.startAccessing(.hdd), isLikelyVolumeRoot(hddURL) else {
            bm.stopAccessing(.ssd)
            bm.stopAccessing(.hdd)
            onAlert(SimpleAlert(title: "HDD non valido",
                                message: "Vai in Impostazioni e riseleziona l'HDD scegliendo '/Volumes/BackupHDD' (la radice del disco, non una cartella)."))
            return
        }
        let flag = CancelFlag()
        isInventorying = true
        inventoryStopRequested = false
        inventoryCancelFlag = flag
        inventoryProgress = .checkingCubbit
        // Un `S3Syncer` DEDICATO, come il ricalcolo dello spazio di Cubbit: `s3Syncer` del
        // runner condivide il proprio flag di interruzione con i job.
        let syncer = S3Syncer()
        Task { @MainActor in
            let reachable = await syncer.checkReachable(config: config)
            guard reachable, !flag.isCancelled else {
                self.finishInventoryRefresh(summary: nil)
                if !reachable {
                    onAlert(SimpleAlert(title: "Cubbit non risponde", message: InventoryStartGate.cubbitUnreachable))
                }
                return
            }
            let runId = Int64(Date().timeIntervalSince1970 * 1000)
            Task.detached(priority: .utility) {
                let outcome = await InventoryRefresh.run(
                    store: store, ssdRoot: ssdURL, hddRoot: hddURL, runId: runId, cancelFlag: flag,
                    fetchPage: { token in try await syncer.fetchListPageXML(config: config, token: token) },
                    onProgress: { p in Task { @MainActor in self.inventoryProgress = p } })
                await MainActor.run {
                    self.finishInventoryRefresh(summary: outcome.summary)
                    if outcome.summary == nil {
                        onAlert(SimpleAlert(title: "L'inventario si è fermato",
                                            message: "Non è stato possibile salvare o rileggere l'inventario sul Mac. "
                                                + "Le foto non sono state toccate: puoi riprovare più tardi."))
                    }
                }
            }
        }
    }

    /// L'UNICO punto in cui un aggiornamento finisce, su ogni percorso: accessi chiusi, flag
    /// giu', esito pubblicato. Un esito `nil` lascia quello di prima (piu' vecchio, mai sbagliato).
    private func finishInventoryRefresh(summary: InventorySummary?) {
        bm.stopAccessing(.ssd)
        bm.stopAccessing(.hdd)
        isInventorying = false
        inventoryCancelFlag = nil
        inventoryProgress = nil
        inventoryStopRequested = false
        if let summary { inventorySummary = summary }
    }

    /// «Interrompi» (idempotente). Lo scanner si ferma fra un blocco da 1 MiB e l'altro, il
    /// lettore di Cubbit fra una pagina e l'altra: quello che e' stato letto resta salvato.
    func stopInventoryRefresh() {
        guard isInventorying, !inventoryStopRequested else { return }
        inventoryStopRequested = true
        inventoryCancelFlag?.cancel()
    }

    /// Un volume si sta smontando: l'inventario si ferma solo se e' l'SSD o l'HDD (S10), senza
    /// segnarlo come «fermato da te».
    private func stopInventoryForVolumeChange(_ volume: URL?) {
        guard isInventorying,
              InventoryStartGate.volumeChangeStopsInventory(unmounting: volume, ssdRoot: bm.urls[.ssd],
                                                            hddRoot: bm.urls[.hdd]) else { return }
        inventoryCancelFlag?.cancel()
    }

    /// Legge l'ultimo inventario salvato e ne calcola il confronto, fuori dal main. Chiamata
    /// all'apertura della finestra; non fa niente se c'e' gia' un risultato o se un
    /// aggiornamento e' in corso (arrivera' da quello).
    func loadInventoryIfNeeded() {
        guard inventorySummary == nil, !isLoadingInventory, !isInventorying,
              let store = libraryIndexStore else { return }
        isLoadingInventory = true
        Task.detached(priority: .userInitiated) {
            let snapshot = (try? store.inventorySnapshot()) ?? InventorySnapshot()
            let summary = InventorySummary(snapshot, sampleLimit: InventorySummary.defaultSampleLimit)
            await MainActor.run {
                self.isLoadingInventory = false
                self.inventorySummary = summary
            }
        }
    }
```

(c) L'osservatore di smontaggio in `init` (9103-9111) diventa:

```swift
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
                // Non si filtra per volume per la lettura dell'elenco: fermarla a ogni smontaggio e'
                // innocuo (quello che e' stato letto resta valido e la volta dopo si riprende
                // da li'), mentre continuare a leggere da un volume che sta sparendo produce
                // hash calcolati su letture troncate. L'inventario invece si ferma solo per
                // l'SSD o l'HDD (ROADMAP #44, S10): un suo giro dura decine di minuti.
                guard let self else { return }
                // L'URL si estrae qui: la notifica non attraversa il salto sul MainActor, l'URL si'.
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor in
                    self.stopIndexingForVolumeChange()
                    self.stopInventoryForVolumeChange(volume)
                }
            }
```

(d) In `resetLibraryIndex`, nel ramo di successo, dopo `indexedFileCount = 0`:

```swift
            // Lo stesso file conteneva l'inventario (S8): la finestra lo rilegge, e ora dira'
            // «mai fatto».
            inventorySummary = nil
```

- [ ] **Step 5:** build pulita (0 warning). `JobStartGateTests` → 10, `LibraryIndexStatusTests` → 39, `DuplicatesStatusTests` → 57, tutti verdi. Suite: `B+145` (1.006).
- [ ] **Step 6: rilettura obbligatoria** (il cablaggio non è coperto da test): `grep -n "isInventorying = true\|finishInventoryRefresh(" AppBackupFoto/ContentView.swift` — ogni percorso che alza `isInventorying` arriva a `finishInventoryRefresh` (Cubbit non raggiungibile, stop prima del giro, fine del giro, errore); `grep -n "bm.startAccessing(.hdd)"` — ogni `startAccessing` ha il suo `stopAccessing` su ogni ramo; nessun `removeItem`/`trashItem`/`copyItem`/`moveItem`/richiesta S3 nuova nel diff (`git diff | grep -E "removeItem|trashItem|copyItem|moveItem|httpMethod"` deve mostrare solo righe spostate del Task 2).
- [ ] **Mutante che deve morire:** un cancello senza il ramo `isInventorying` (muoiono i cinque test nuovi). Il cablaggio in `BackupRunner` è **dichiarato non coperto da test**: lo coprono i test ai due capi (`InventoryRefreshTests`, `InventoryStartGate`) e le verifiche dal vivo 6-8 del Task 13.
- [ ] **Step 7: commit.** `Inventario, task 10: cablaggio nel runner e mutua esclusione con backup, elenco e Cestino` + attribuzione.

---

### Task 11: la finestra «Inventario»

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — scene dopo `Window("Doppioni", id: "duplicates") { … }` (191-199); `HamburgerPanel` dopo la riga «Foto» (12685-12687); `LibraryIndexCard.confirmReset` (13628-13636); nuovo `InventoryView` in fondo al file (dopo la riga 14801), sotto `// MARK: - Pannello Inventario`.

**Interfaces:**
- Consumes: `BackupRunner` (Task 10), `InventoryStatus` (Task 9), `InventoryStartGate` (Task 8), `AuthGateManager`, `LockScreenView`, `VolumeMonitor`, `SimpleAlert`, `AppSpacing`/`AppFont`/`AppColor`.
- Produces: `struct InventoryView: View`, scena `Window("Inventario", id: "inventory")` (compare da sola nel menu **Finestra**, come Doppioni e Diagnostica), voce «Inventario» nel pannello laterale.

Nessun test nuovo: è SwiftUI, **dichiarato non coperto** (stessa disciplina di `DuplicatesView`/`LibraryIndexCard`). Compilato dall'Architect contro stub, 0 warning.

- [ ] **Step 1: la scena.** Dopo la scena Doppioni, prima di `MenuBarExtra`:

```swift
        Window("Inventario", id: "inventory") {
            InventoryView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 680)
        // Stessa regola di #30: ogni Window scene di primo livello va gated (il gate vero e'
        // dentro InventoryView: elenca percorsi e nomi di tutte le foto) e non deve essere
        // riaperta dal ripristino automatico di macOS prima dello sblocco.
        .restorationBehavior(.disabled)
```

- [ ] **Step 2: la voce nel pannello laterale**, dopo la riga «Foto»:

```swift
                        HamburgerRow(icon: "checklist", label: "Inventario", iconColor: .indigo) {
                            openWindow(id: "inventory")
                        }
```

- [ ] **Step 3: il testo di conferma di «Svuota l'elenco»** (S8). In `confirmReset`, il `message` diventa:

```swift
            message: "Viene cancellato solo l'elenco che l'app tiene sul Mac. Le tue foto e i tuoi video sull'SSD non vengono toccati: non ne viene cancellato nemmeno uno.\n\nDopo, l'elenco va rifatto da zero (\(durata)) e finché non lo rifai un'importazione può ricopiare foto che hai già.\n\nInsieme all'elenco si svuota anche l'inventario (finestra Inventario), che andrà aggiornato di nuovo.",
```

- [ ] **Step 4: la vista**, in fondo al file:

```swift
// MARK: - Pannello Inventario (ROADMAP #44, ADR-0015)

/// La finestra "Inventario": per ogni contenuto foto/video, in quale dei tre posti (SSD, HDD,
/// Cubbit) c'e' davvero, e cosa non torna. SOLA LETTURA: nessun bottone copia, sposta o
/// cancella (spec, «Il pannello e' solo lettura»).
///
/// **NON coperta da test** (stessa dichiarazione di `DuplicatesView` e `LibraryIndexCard`):
/// questa view, il gate Touch ID, l'apertura della finestra. E' testato tutto cio' che sta ai
/// due capi del cablaggio: `InventoryStatus` (testi), `InventoryStartGate`, `InventorySummary`/
/// `InventoryClassifier`, `InventoryRefresh`.
struct InventoryView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var volumes = VolumeMonitor.shared

    /// Avvisi LOCALI della finestra (vedi `AlertSink`): `runner.pendingAlert` ha un solo
    /// presentatore, nella finestra principale.
    @State private var alert: SimpleAlert? = nil
    @State private var expanded: Set<InventoryCategory> = []

    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    private var startDisabledReason: String? {
        InventoryStartGate.blockedReason(
            isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            isInventorying: runner.isInventorying, ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Inventario").font(AppFont.title)
            Label(InventoryStatus.readOnlyNote, systemImage: "eye")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = runner.inventorySummary {
                lineView(InventoryStatus.freshnessLine(states: summary.states, now: Date()))
                ForEach(InventoryArchive.allCases, id: \.self) { archive in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(InventoryStatus.archiveLine(archive, stats: summary.stats[archive] ?? InventoryArchiveStats()))
                            .font(AppFont.body)
                        if let line = InventoryStatus.completenessLine(archive, state: summary.states[archive]) {
                            lineView(line)
                        }
                    }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(InventoryStatus.displayOrder, id: \.self) { category in
                            categoryRow(category, summary: summary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(InventoryStatus.loadingLine).font(AppFont.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(AppSpacing.lg)
        .frame(minWidth: 560, minHeight: 480, alignment: .topLeading)
        .task { runner.loadInventoryIfNeeded() }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        ), presenting: alert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle { Button(cancelTitle, role: .cancel) {} }
        } message: { a in
            Text(a.message)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: InventoryCategory, summary: InventorySummary) -> some View {
        let count = summary.count(category)
        // «Non si puo' ancora dire» compare solo se c'e' qualcosa: non e' una categoria della
        // spec, e' il posto dei contenuti su cui il giudizio e' sospeso.
        if category != .undetermined || count > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(category) },
                set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } }
            )) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(InventoryStatus.explanation(category))
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let items = summary.samples[category] ?? []
                    ForEach(items) { item in
                        Text(InventoryStatus.itemLine(item))
                            .font(AppFont.caption)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let more = InventoryStatus.sampleLimitLine(shown: items.count, total: count) {
                        Text(more).font(AppFont.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, AppSpacing.md)
            } label: {
                Text(InventoryStatus.categoryLine(category, count: count, bytes: summary.bytes(category)))
                    .font(AppFont.body)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if runner.isInventorying {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(runner.inventoryStopRequested
                         ? InventoryStatus.stoppingLine
                         : runner.inventoryProgress.map { InventoryStatus.progressLine($0) } ?? InventoryStatus.progressLine(.checkingCubbit))
                        .font(AppFont.caption)
                }
                Button(InventoryStatus.stopButton) { runner.stopInventoryRefresh() }
                    .disabled(runner.inventoryStopRequested)
            } else {
                Button(InventoryStatus.refreshButton) {
                    runner.startInventoryRefresh(onAlert: { alert = $0 })
                }
                .disabled(startDisabledReason != nil)
                if let reason = startDisabledReason {
                    Label(reason, systemImage: "info.circle")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lineView(_ line: InventoryStatus.Line) -> some View {
        Label(line.text, systemImage: line.tone == .ok ? "checkmark.circle.fill"
              : line.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(AppFont.caption)
            .foregroundStyle(line.tone == .ok ? AppColor.success : line.tone == .warning ? AppColor.warning : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 5:** build pulita (0 warning) + suite: ancora `B+145` (1.006).
- [ ] **Step 6: rilettura:** la vista non contiene nessun bottone che copia, sposta o cancella; nessuna stringa a schermo nasce nella vista (a parte il titolo «Inventario», che è il nome della finestra); nessun `reduce`/`filter` su migliaia di elementi nel `body` (i campioni arrivano già limitati da `InventorySummary`).
- [ ] **Mutante:** nessuno (SwiftUI). Copertura sostitutiva: verifiche 2-4 e 9-11 del Task 13.
- [ ] **Step 7: commit.** `Inventario, task 11: la finestra Inventario, solo lettura` + attribuzione.

---

### Task 12: documentazione

**Files:** `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`, `Docs/adr/0015-…md` (solo se le risposte di Enrico hanno cambiato qualcosa dopo il Task 0).

- [ ] **Step 1: `Docs/CLAUDE.md`.** (a) Data in testa a «Stato attuale» e un «Sesto tocco, 2026-09-2x» che dice quali righe sono state toccate, come i tocchi precedenti. (b) Riga nuova nella tabella, dopo «Indice di contenuto della libreria…»:
  `| Inventario certificato SSD/HDD/Cubbit (#44) | ⏳ **Implementato (2026-09-2x, ADR-0015)** su \`feature/cross-store-inventory\`, verifiche dal vivo ancora da fare. Finestra «Inventario» in sola lettura: per ogni contenuto foto/video dice se è ✅ su tutti e tre, ⚠️ manca da qualche parte, 🔎 solo fuori dall'SSD, ❗ da controllare (⏳ se dipende da un archivio letto a metà), con foto, copie in più e spazio recuperabile per archivio. Cubbit si certifica con l'ETag senza scaricare (parte unica = MD5, a pezzi = parti da 64 MiB). Tabelle nello stesso SQLite dell'elenco (schema 2; dalla 1 si sale senza perdere l'elenco). Non marcarlo "fatto" finché non passano le verifiche del Task 13 del piano |`
  (c) Riga «Test automatici»: il totale **misurato** (atteso 1.006) e i file nuovi/estesi della mappa di questo piano. (d) Nella sezione «Regola assoluta» non cambia niente: l'inventario non scrive; aggiungere solo, dopo il punto 3, «L'inventario (ADR-0015) legge SSD, HDD e Cubbit e scrive solo nel database dell'app sul Mac.»
- [ ] **Step 2: `Docs/ROADMAP.md`.** In fondo al capitolo più recente (prima di «Fonti consultate»), il punto:
  `44. ⏳ **Implementato il 2026-09-2x, verifica dal vivo ancora da fare — inventario certificato su SSD, HDD e Cubbit (progetto 1 di 4 verso «una copia per archivio»).** Spec \`Docs/superpowers/specs/2026-09-26-cross-store-inventory-design.md\`, piano \`Docs/superpowers/plans/2026-09-26-cross-store-inventory.md\`, ADR-0015. Solo lettura. I progetti 2 (mettere al sicuro), 3 (doppioni SSD con garanzia) e 4 (ridondanze su HDD e Cubbit, zero-delete che cade) partono da qui e rifiuteranno un inventario vecchio (soglia da decidere nel progetto 2). Aperti: misura della memoria del confronto alla scala reale; oggetti Cubbit caricati con parti diverse restano ❗; la lettura calcola a ~300 MiB/s (misurato), il primo giro dura decine di minuti per disco.`
- [ ] **Step 3: `Docs/CONTEXT.md`**, sezione nuova «## Inventario (roadmap #44)» prima di «## Import da sorgenti locali»: **Archivio** (SSD, HDD o Cubbit, visti come tre posti in cui una foto può stare); **Inventario** (l'elenco del contenuto dei tre archivi, per contenuto e non per nome; è una cache come l'indice, ADR-0002); **Certificato** (su Cubbit: ETag uguale all'MD5 o all'ETag a pezzi da 64 MiB di un file letto della stessa dimensione — mai per ipotesi); **Non certificabile** (un oggetto Cubbit che non si può confrontare senza scaricarlo: sempre ❗); **Incompleto ≠ assente** (da un archivio non letto per intero non si dichiara mai assente niente; un disco scollegato non è un disco vuoto); **Giro** (un aggiornamento dell'inventario; «presente» vuol dire «visto nell'ultimo giro»).
- [ ] **Step 4: `.claude/rules/architecture.md`.** (a) Nella voce «Il gate copre anche le finestre secondarie» aggiungere `Window("Inventario", id: "inventory")`. (b) Sezione nuova «### Inventario certificato (2026-09-2x, roadmap #44, ADR-0015)» dopo quella sul pannello Doppioni alla scala reale: i tipi (`ContentHasher`, `S3Syncer.parseListPage`/`fetchListPageXML`, `S3ETag`/`S3ETagMatcher`, tabelle e API in `LibraryIndexStore`, `InventoryScanner`, `InventoryCubbitReader`/`InventoryPerimeter`, `InventoryClassifier`/`InventorySummary`, `InventoryRefresh`/`InventoryStartGate`, `InventoryStatus`, `InventoryView`), con per ciascun tipo di fondo la riga sul perché è `nonisolated`/`@concurrent`; S1, S2, S3, S9, S10 con una riga ciascuno; il test di parità fra `InventoryScanner` e `LibraryIndexer` («se cambi la traversata di uno, cambia l'altro: il test lo pretende»); cosa **non** è coperto da test (cablaggio in `BackupRunner`, `InventoryView`). (c) Nella sezione `isTrashingDuplicates`/`JobStartGate` aggiungere `isInventorying` ai cancelli. (d) Nella sezione `S3Syncer`: `multipartChunkSize` e `xmlDecode` ora `nonisolated`, `listPage` delega la richiesta a `fetchListPageXML`.
- [ ] **Step 5:** Commit solo documentazione: `Inventario, task 12: documentazione (CLAUDE, ROADMAP #44, CONTEXT, architettura)` + attribuzione.

---

### Task 13: verifiche dal vivo (Enrico, con SSD, HDD e rete)

**Non le esegue l'Implementer.** Servono l'app compilata da questo branch, SSD e HDD collegati, Cubbit raggiungibile (VPN spenta: gli errori del 26/09 venivano da NordVPN), e nessun backup in corso. Ogni comando da Terminale qui sotto **legge soltanto**.

- [ ] **0. Segnaposto per «non ha scritto niente».** Prima di iniziare: `mkdir -p /private/tmp/claude-501/inventory-check && touch /private/tmp/claude-501/inventory-check/marker`.
- [ ] **1. Finestra.** Pannello laterale → «Inventario»; compare anche nel menu **Finestra**. Prima apertura: «L'inventario non è mai stato fatto…», nessun numero inventato.
- [ ] **2. Primo giro.** «Aggiorna l'inventario»: si vedono in ordine «Controllo che Cubbit risponda…», «1 di 3 · Leggo le foto sull'SSD…», «2 di 3 · …HDD…», «3 di 3 · Chiedo a Cubbit…», «Metto a confronto…». Annotare la durata di ogni passo (serve al progetto 2 e alla stima nei testi).
- [ ] **3. Memoria.** Durante «Metto a confronto…», Monitor Attività: picco di memoria di AppBackupFoto. **Sopra 1,5 GB, riportarlo all'Architect** (il confronto tiene in memoria tre elenchi da centinaia di migliaia di righe: non misurato alla scala reale).
- [ ] **4. Numeri plausibili.** SSD: foto e video ≈ quelle dell'elenco dei Doppioni (card in Diagnostica), e «copie in più» ≈ le copie in eccesso mostrate da Doppioni (stessa definizione, file vuoti esclusi). ❗ «Da controllare» vicino a zero: la spec ha verificato che i 248 oggetti a pezzi si ricalcolano tutti; se sono tanti, riportarlo.
- [ ] **5. Confronto indipendente con `rclone check`** (riferimento del 2026-09-26: 97.558 file identici fra SSD e Cubbit nella cartella `ASUS`):
  ```bash
  W=/private/tmp/claude-501/inventory-check
  rclone check "/Volumes/SSD - Enri/ASUS" "Cubbit:backupfoto/ASUS" --one-way --combined "$W/asus.txt" 2> "$W/asus.log"
  grep '^= ' "$W/asus.txt" | grep -Eic '\.(jpe?g|heic|heif|png|gif|webp|tiff?|bmp|cr2|cr3|nef|arw|dng|raf|orf|rw2|mov|mp4|m4v|avi|wmv|mts|m2ts|3gp)$'
  # copia del database (mai l'originale), con l'app ferma o inattiva
  cp ~/Library/Application\ Support/AppBackupFoto/library-index.sqlite* "$W/"
  sqlite3 "$W/library-index.sqlite" "
    SELECT COUNT(*) FROM inventory_local l JOIN inventory_s3 s ON s.path = l.path
    WHERE l.archive='ssd' AND l.path LIKE 'asus/%' AND l.status='ok'
      AND l.run_id=(SELECT run_id FROM inventory_state WHERE archive='ssd')
      AND s.run_id=(SELECT run_id FROM inventory_state WHERE archive='s3')
      AND lower(replace(s.etag,'\"','')) IN (l.md5, l.etag);"
  ```
  I due numeri devono coincidere o quasi: l'elenco di estensioni del `grep` approssima `IndexableKind`, e `rclone` conta «=» anche gli oggetti a pezzi di cui non verifica l'hash. Ogni differenza oltre qualche decina va capita prima di dichiarare il punto #44 fatto.
- [ ] **6. Robustezza, HDD scollegato a metà** (la prova della spec). Nuovo giro; quando compare «2 di 3 · …HDD», espellere l'HDD dal Finder (o staccarlo). Atteso: il giro si ferma; riga HDD «…la lettura è stata fermata prima della fine» (o «il disco è stato scollegato…») con «l'app non dice mai che una foto manca da lì»; Cubbit «non è stato letto…»; **nessuna voce ⚠️ dice «manca da: HDD»** e 🔎 non cresce per colpa dell'HDD; i contenuti sospesi stanno in ⏳. Ricollegare, nuovo giro: tutto completo, numeri come al punto 4.
- [ ] **7. «Interrompi»** durante «1 di 3»: la barra dice «Mi fermo…», poi SSD «fermata», HDD e Cubbit «non letto». Un giro successivo è veloce (rilegge solo i file cambiati).
- [ ] **8. Mutua esclusione**, con un giro in corso: MAC → SSD risponde «Meglio non farlo adesso… inventario»; in Doppioni lo spostamento nel Cestino e «Annulla l'ultimo spostamento» sono disattivati col motivo; in Diagnostica i comandi dell'elenco pure. Viceversa, durante un backup il bottone dell'inventario è disattivato col motivo.
- [ ] **9. Chiudere e riaprire la finestra** durante un giro: barra e «Interrompi» ci sono ancora.
- [ ] **10. Espellere una chiavetta** qualsiasi durante un giro: il giro **non** si ferma (S10).
- [ ] **11. Touch ID:** con l'app bloccata la finestra Inventario mostra la schermata di blocco.
- [ ] **12. Niente scritto sui dischi:**
  ```bash
  find "/Volumes/SSD - Enri" "/Volumes/BackupHDD" -newer /private/tmp/claude-501/inventory-check/marker \
       -not -path '*/.Spotlight-V100/*' -not -path '*/.fseventsd/*' -not -path '*/.DocumentRevisions-V100*' 2>/dev/null | head
  ```
  Atteso: nessuna riga (a parte file di sistema da discutere, mai foto).
- [ ] **13.** Riportare all'Architect le durate (2), il picco di memoria (3), i due numeri del punto 5 e l'esito di 6-12; aggiornare `Docs/CLAUDE.md` e il punto #44 solo dopo.

---

## Fuori scope (dichiarato)

- Copiare, spostare, cancellare qualunque cosa (progetti 2-4); file che non sono foto o video; aggiornamento automatico in coda ai backup; versioni sul bucket.
- Soglia di «inventario vecchio» per i progetti successivi (si decide nel progetto 2).
- Scaricare da Cubbit gli oggetti non certificabili per confrontarli.
- Letture di SSD e HDD in parallelo (D2) e l'ottimizzazione che risparmierebbe un MD5 sui file fino a 64 MiB: solo se le misure del Task 13 lo chiedono.
