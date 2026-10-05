# Riparazione di una copia rovinata con la regola «2 su 3» — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: BOZZA, da approvare.** Nessuna riga di codice scritta nel repository. Spec: `Docs/superpowers/specs/2026-10-01-repair-from-majority-design.md` (approvata a voce da Enrico il 2026-10-01). **Prima di partire servono le risposte di Enrico agli scostamenti S1-S11 e alle decisioni D1-D4 qui sotto**: il piano implementa la colonna «Proposta»; se Enrico sceglie un'alternativa, l'Implementer si ferma e rimanda all'Architect. ADR: **0016** (scritto nel Task 0, dopo l'approvazione). ROADMAP: **#45**. ADR-0014 e #43 restano riservati al piano `2026-09-26-s3-upload-failures-visible`.

**Base:** `main` a `c296732` (1.023 test: conteggio delle `func test` nei 69 file, ed eseguiti tutti, 0 fallimenti, nel prototipo descritto sotto), branch nuovo `feature/repair-from-majority`.

**Goal:** nella finestra «Inventario», le foto rovinate in UN archivio e integre e identiche negli altri due (la `.heic` del 2026-10-01: rovinata su Cubbit, integra su SSD e HDD) hanno un «Ripara…»: riepilogo, conferma, poi l'app ricontrolla tutto dal vivo, mette da parte la copia rovinata in `_quarantena/<AAAA-MM-GG>/<percorso>` sullo stesso archivio (mai cancellata), scrive la copia buona al suo posto, la verifica e annota tutto in `repair-log.json` sul Mac. Nel riepilogo c'è anche «Controlla senza riparare»: lo stesso ricontrollo dal vivo, senza scrivere niente (regola 4 di `Docs/CLAUDE.md`, S11). È la prima eccezione controllata a zero-overwrite; la cartella `_quarantena` non rientra mai in backup, elenco, inventario, Doppioni, ripristino.

**Architecture:** quattro pezzi puri e un motore. `LibraryExclusions` (fonte unica già esistente) impara la cartella di quarantena, e ogni lettore la salta (test di parità). `RepairRules` decide dal `InventorySnapshot` quali voci sono riparabili (`RepairCandidate`: minoranza, sorgente, testimone, impronte), `RepairPaths` costruisce i percorsi di quarantena. `S3Syncer` guadagna HEAD, copia lato server (firmata con `x-amz-copy-source`), lista con prefisso e la sola sovrascrittura (`replaceObjectForRepair`, sopra l'`upload` esistente). `RepairEngine` (`nonisolated`, `@concurrent`, dipendenze iniettate) esegue i passi della spec, o solo il ricontrollo (`dryRun`); `RepairLogStore` è il registro, sullo stampo di `TrashManifestStore`. `BackupRunner` ci mette bookmark, cancelli (`isRepairing`, in mutua esclusione con tutto il resto) e pubblicazione; `InventoryView` mostra testi che vivono tutti in `RepairStatus`.

**Tech Stack:** Swift 5.x, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, *Approachable Concurrency*, SwiftUI, CryptoKit, POSIX (`rename`, `lstat`), XCTest. Nessuna dipendenza nuova.

**Verifica preventiva fatta dall'Architect (2026-10-04), senza `xcodebuild`.** Tutto il codice di produzione dei Task 1-9 e **tutti** i test di questo piano sono stati compilati ed eseguiti **fuori da Xcode**: in `/private/tmp/claude-501/repair-plan/proto/` l'intero `AppBackupFoto/ContentView.swift` di `c296732` (con le patch di questo piano applicate, testo identico a quello riportato nei task) è compilato con `swiftc` come modulo `AppBackupFoto` con le stesse impostazioni del target (Swift 5, default `MainActor`, le feature di *Approachable Concurrency*, `MemberImportVisibility`), e i 69 file di test esistenti più i 9 nuovi in un bundle lanciato con `xcrun xctest`. Risultato: **1.159 test, 0 fallimenti, 0 warning** (app e test); baseline senza patch 1.023 test, 0 fallimenti. Ogni task è stato verificato anche **da solo, in ordine** (patch fino al task N + test fino al task N), con il conteggio scritto nel task. Differenze volute del prototipo, entrambe solo lì: `import Sparkle` sostituito da uno stub di `SPUStandardUpdaterController`, `@main` tolto, e `isRunningUnderTests()` forzato a `true` (fuori da Xcode la variabile d'ambiente del test runner non c'è). Il cablaggio di `BackupRunner` e `InventoryView` (Task 8-9) è compilato senza warning ma **non eseguito** (SwiftUI e rete veri). **Nessuna richiesta a Cubbit e nessuna scrittura su `/Volumes`**: le richieste nuove sono provate con i valori pubblicati da AWS e con valori calcolati da uno script python indipendente; la prova vera è il Task 11.

**Fatto già verificato (2026-10-04, orchestratore):** Cubbit accetta `CopyObject`: `rclone copyto` ha copiato lato server `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic` in `_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, ETag identico `24cb65338294b62644feec09251bd6ac`. Quindi niente ripiego download+upload, e la quarantena su Cubbit è **idempotente**: quella copia (data 2026-10-04) sarà riconosciuta e riusata. L'ETag giusto dopo la riparazione è l'MD5 della copia sull'SSD, `b59917c9c6e38fccab5ce3f30c90d13a` (caricamento a parte unica, 2.463.629 byte).

**Fatto trovato dall'Architect leggendo il database dell'app (sola lettura, `?immutable=1`, 2026-10-04):** l'ultimo giro d'inventario salvato (`run_id` 1790892855714) ha **tutti e tre gli archivi in stato `running`**, cioè incompleti (l'app si è chiusa a metà giro). Con questo stato **la `.heic` oggi non risulterebbe riparabile** (regola «incompleto ≠ assente»): il Task 11 comincia con un inventario completo. Le righe di SSD e HDD della `.heic` ci sono (SHA256 `80f4a17b…69234b0`, MD5 `b59917c9…0d13a`, 2.463.629 byte), quella di Cubbit è di un giro precedente (ETag `24cb6533…bd6ac`). Nessun percorso in `entries`, `inventory_local` o `inventory_s3` contiene oggi `quarantena`.

---

## Scostamenti dalla spec da far approvare

Trovati leggendo il codice a `c296732` e provando il codice nel prototipo. **Nessuno è stato applicato di nascosto**: il piano implementa la colonna «Proposta»; se Enrico sceglie l'alternativa, l'Implementer si ferma e rimanda all'Architect.

| # | La spec dice | Il codice / il problema | Proposta del piano | Alternativa |
| :--- | :--- | :--- | :--- | :--- |
| S1 | Su SSD/HDD: 2. quarantena (`rename`), 3. scrittura con le funzioni di copia, «il primo passo che fallisce ferma tutto» | Nell'ordine letterale, se la copia fallisce (disco pieno, sorgente illeggibile, disco scollegato) la copia rovinata è già in quarantena e al percorso originale **non c'è più niente**: non «lascia tutto com'era» | La copia buona si **prepara prima**: `copyItem` in `_quarantena/<giorno>/<percorso>.in-arrivo-<8 caratteri>` e rilettura (SHA256 uguale alla sorgente); **poi** `rename` rovinata → quarantena; **poi** `rename` preparata → posto originale. Se l'ultimo `rename` fallisce, la rovinata torna al suo posto. La foto manca dal suo percorso solo fra due `rename` sullo stesso volume (microsecondi). Una copia preparata rimasta per un fallimento sta in quarantena (che nessuno legge) e **non si cancella** | Ordine letterale con un `rename` all'indietro dopo una copia fallita: la foto manca dal suo posto per tutta la durata della copia (minuti per un video) e il ritorno serve molto più spesso |
| S2 | Cubbit è la minoranza se «un ETag che non certifica il contenuto degli altri due» | Un ETag **a pezzi** che non coincide non dimostra un contenuto diverso: può essere lo stesso contenuto caricato con parti di un'altra dimensione (è la ragione per cui ADR-0015 lo chiama *non certificabile*). In più, la copia lato server di un oggetto a pezzi può ricevere un ETag diverso, e la verifica della quarantena («stesso ETag della rovinata») fallirebbe | Cubbit è la minoranza solo con un ETag **a parte unica** (è l'MD5 del contenuto) diverso dall'MD5 della copia buona — il caso della `.heic`. Con un ETag a pezzi che non torna la voce resta in ❗ senza «Ripara…» | Accettare anche gli `-N` con il numero di parti giusto per 64 MiB, e rinunciare al confronto d'ETag dopo la copia per quelli |
| S3 | (non detto) Chiavi con `+` e apostrofo (BUG-8) | La sovrascrittura usa l'`upload` del backup, che codifica il percorso con `.urlPathAllowed`: `+`, `'` e `!$&()*,;=:@` restano in chiaro; HEAD e copia (nuove) li codificano (`%2B`, `%27`…). Le due richieste manderebbero percorsi diversi per la stessa chiave: la sovrascrittura potrebbe finire su una chiave diversa da quella controllata. Lettere accentate, spazi, cifre e `-_.~/` danno lo stesso percorso nei due modi (verificato) | Su **Cubbit** si ripara solo una chiave per cui i due percorsi coincidono (`RepairRules.cubbitKeyIsRepairable`): oggi è il caso della `.heic`. Le altre restano in ❗. Sui **dischi** nessun limite (a Cubbit si chiede solo una HEAD) | Cambiare `put` del backup per usare la codifica rigorosa: tocca il caricamento di ogni file del backup, fuori dallo scopo di questo progetto |
| S4 | Registro al passo 5 | Se l'app si chiude fra la quarantena e la fine, nessuna traccia di dove sia finita la copia rovinata | Una voce `inProgress` si scrive **prima di toccare qualunque archivio** (se non si può scrivere, la riparazione non parte) e si aggiorna con l'esito alla fine. Si registrano anche i tentativi fermati al ricontrollo | Solo al passo 5, come da spec |
| S5 | Esclusione da backup SSD→HDD, SSD→Cubbit, elenco, inventario, Doppioni, ripristino | Il campione d'integrità (Diagnostica) scorre HDD e Cubbit per conto suo e conterebbe la quarantena come «sorgente mancante»; exFAT non distingue le maiuscole (`_Quarantena` creata a mano è la stessa cartella); un'importazione con etichetta `_quarantena` atterrerebbe in `Import/_quarantena`, esclusa da tutto | Esclusa anche dal campione d'integrità; nome confrontato **senza maiuscole**, a qualunque profondità (come `.Trashes`); un'etichetta d'importazione uguale a un nome escluso diventa «Import» (chiude anche il caso già esistente `lost+found`) | Solo i percorsi elencati, nome esatto |
| S6 | (non detto) | Una riparazione è una foto sola e dura secondi; un «Interrompi» a metà creerebbe proprio gli stati intermedi che S1 evita | **Nessun «Interrompi»**: la riga dice il passo in corso. Se l'app si chiude a metà, il registro dice «in corso» e dove sta la quarantena | «Interrompi» fra un passo e l'altro |
| S7 | «Ripara…» su ogni voce riparabile in ❗ | L'inventario raggruppa per **contenuto**: la `.heic` produce due voci in ❗ (la copia buona e quella diversa), mentre la riparazione è per **percorso**; l'elenco mostra al massimo 300 voci per categoria | Un sottoelenco in testa a ❗ («1 foto si può riparare»), con **tutte** le voci riparabili, una riga per percorso con il suo «Ripara…» (o la riga del passo in corso, o «Riparata il …»). Le due voci per contenuto restano nell'elenco ❗ finché un nuovo inventario non le toglie | Il bottone sulle righe per contenuto (due bottoni per la stessa riparazione) |
| S8 | (non detto) | La nota in testa alla finestra dice «Questa finestra guarda soltanto: non copia, non sposta e non cancella niente»: con «Ripara…» sarebbe falsa | Nuovo testo: «L'inventario guarda soltanto: … L'unica cosa che da qui può scrivere è «Ripara…», una foto alla volta e solo dopo la tua conferma.» | — |
| S9 | (non detto) | `Docs/CLAUDE.md`, «Regola assoluta» punti 2 (zero overwrite) e 3 (sull'SSD l'unica scrittura oltre ai backup è il Cestino), e la checklist «IF il codice fa chiamate S3 … THEN verifica che PUT controlli esistenza remota» diventano **false** | Riscriverle (testo proposto nel Task 10, **da approvare parola per parola da Enrico**, come fu per ADR-0005) | — (una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa) |
| S10 | «Va aggiunta in S3Syncer una richiesta CopyObject firmata SigV4» | `sign` firma solo `host`, `x-amz-content-sha256`, `x-amz-date` e ricalcola il percorso canonico da `url.path`: S3 rifiuta le intestazioni `x-amz-*` presenti ma non firmate, e il percorso firmato non sarebbe quello inviato per `+`/apostrofo | `sign` diventa `internal` (era `private`, serve ai test) con due parametri con default (`canonicalURI`, `extraSignedHeaders`); il cuore SigV4 si estrae in `sigV4Signature` (puro), provato con i 3 esempi pubblicati da AWS. Le richieste di oggi hanno **la stessa firma** di prima (test con un valore calcolato a parte) | Una seconda funzione di firma solo per la riparazione: due implementazioni della stessa cosa |

| S11 | (non detto) | `Docs/CLAUDE.md`, regola assoluta 4: «qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione». La riparazione non è una sincronizzazione, ma è la scrittura più delicata del progetto, e le sue richieste a Cubbit (HEAD e lista firmate in modo nuovo) non sono mai state provate dal vivo | Nel riepilogo, oltre a «Continua…», il bottone **«Controlla senza riparare»**: `RepairEngine.run(_:dryRun: true)` fa il ricontrollo dal vivo e la ricerca della quarantena, dice dove andrebbe la copia diversa, e si ferma — nessuna scrittura, nemmeno nel registro. Il Task 11 lo usa per primo: prova HEAD e lista su Cubbit vero prima di qualunque scrittura | Nessun dry-run: il riepilogo e il ricontrollo del passo 1 fanno da anteprima |

### Decisioni da confermare (con la raccomandazione)

- **D1 — Il testo nuovo della «Regola assoluta» (S9).** Il Task 10 lo propone parola per parola. **Raccomandazione:** approvarlo prima del Task 0 o correggerlo: senza un testo approvato il Task 10 non si chiude.
- **D2 — Una voce del registro illeggibile.** Come `TrashManifestStore`, un `repair-log.json` illeggibile riparte da vuoto e la prima scrittura lo sostituisce (la storia vecchia si perde, la riparazione no). **Raccomandazione:** tenerlo così (è «lo stesso schema di TrashManifest» della spec); l'alternativa è spostare da parte il file illeggibile (`repair-log.illeggibile-<data>.json`, nessuna cancellazione), più codice per un caso mai visto.
- **D3 — Dopo una riparazione la finestra non rilegge l'inventario da sola.** La voce resta in ❗ con «Riparata il …, aggiorna l'inventario per confermarlo» (spec). **Raccomandazione:** così; un aggiornamento automatico rileggerebbe SSD e HDD per decine di minuti senza che Enrico l'abbia chiesto.
- **D4 — Il nome della cartella è `_quarantena`, scritto così, anche su Cubbit** (dove le maiuscole contano: `_Quarantena/…` su Cubbit non è riconosciuta come quarantena dalla quarantena idempotente, ma è comunque esclusa da inventario e ripristino perché il confronto per l'esclusione ignora le maiuscole). **Raccomandazione:** così.

---

## Global Constraints

- **Una riparazione alla volta, con conferma** (decisione 3): «Ripara…» → riepilogo (foglio) → «Continua…» → conferma con bottone distruttivo → `BackupRunner.startRepair(_:dryRun: false,…)`. Dal riepilogo, «Controlla senza riparare» (`dryRun: true`, S11) fa solo il ricontrollo, senza scrivere niente. Nessuna riparazione in blocco, nessuna riparazione automatica.
- **Quando si ripara** (spec, `RepairRules.candidates`): tre archivi **completi** nell'ultimo giro; stesso percorso, una sola volta, in ciascuno dei tre; SSD e HDD letti per intero; due archivi con lo stesso contenuto certificato e la stessa dimensione, il terzo con contenuto **dimostrato** diverso (S2); su Cubbit solo chiavi per cui caricamento e richieste nuove mandano lo stesso percorso (S3). In ogni altro caso la voce resta in ❗ senza «Ripara…».
- **Sorgente sempre locale**: SSD per riparare HDD o Cubbit, HDD per riparare l'SSD. Testimone: HDD per Cubbit, Cubbit per i dischi.
- **L'inventario è una cache (ADR-0002)**: prima di toccare qualunque cosa il motore rilegge per intero sorgente e testimone locale (`ContentHasher.digestFile`), chiede a Cubbit una HEAD, e pretende che la copia rovinata sia ancora quella vista dall'inventario (stessa dimensione e stesso SHA256/ETag).
- **Mai cancellare, mai sovrascrivere senza quarantena**: su disco solo `rename(2)` (`RepairEngine.renameWithoutOverwriting`: rifiuta se la destinazione esiste, fallisce con `EXDEV` fra volumi diversi invece di copiare e cancellare come `FileManager.moveItem`); **nessuna** `removeItem`/`moveItem`/`trashItem` nuova; nessuna DELETE su Cubbit; la sola sovrascrittura è `S3Syncer.replaceObjectForRepair`, chiamata solo dal motore dopo una quarantena verificata.
- **Quarantena** `_quarantena/<AAAA-MM-GG>/<percorso relativo>` sullo stesso archivio, giorno nel fuso del Mac; su Cubbit **idempotente** (una copia con la stessa dimensione e lo stesso ETag della rovinata, in qualunque giorno, vale come fatta); zero-overwrite anche dentro la quarantena.
- **`_quarantena` non rientra mai**: un nome solo (`LibraryExclusions.quarantineFolderName`), escluso senza maiuscole da `LibraryExclusions` (FileSyncer, LibraryIndexer → Doppioni, InventoryScanner, InventoryPerimeter), `S3Syncer.localUploadFiles` (backup e anteprima SSD → Cubbit), ripristino (cartelle SSD/HDD e Cubbit), campione d'integrità. Un test di parità lo pretende per tutti.
- **Fuori dal main**: `RepairEngine` e `RepairLogStore` sono `nonisolated` con la riga sul perché sono sicuri; `run` è `@concurrent`. Zero warning.
- **Mutua esclusione**: parametro `isRepairing` **senza default** in `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason`, `InventoryStartGate.blockedReason`; `beginDuplicateTrashing`/`beginTrashRestore` guardano `isRepairing`; `RepairStartGate` per il verso opposto. `resetDisabledReason` non cambia (motivo scritto accanto).
- **Testi a schermo solo in `RepairStatus`/`RepairStartGate`**, italiano semplice, senza gergo («hash», «impronta», «ETag», «MD5», «bucket», «multipart»…); la cartella «_quarantena» si nomina tra virgolette (è quella che Enrico svuota dal Finder).
- **Registro** `Application Support/AppBackupFoto/repair-log.json` (sotto test: `backupRunnerStoreRoot()`, BUG-10), schema `totalRecorded` + `items` come `TrashManifest`, `init(from:)` con `decodeIfPresent`, scrittura prima di tornare, `0600`, allow-list della posizione.
- Numerazione: **ADR-0016**, **ROADMAP #45**.
- Tutto il codice in **`AppBackupFoto/ContentView.swift`**; test in **`AppBackupFotoTests/`**, ogni file nuovo registrato nel pbxproj nei **4 punti**. Si verifica sempre il totale `Executed N tests`.
- Un commit per task, messaggio in italiano, **mai `git push`**. **Nessuna scrittura su `/Volumes` né su Cubbit prima del Task 11**, che esegue l'orchestratore con Enrico.

---

## Mappa dei file e dei tipi

**`AppBackupFoto/ContentView.swift`** (righe verificate a `c296732`, 16.864 righe; si ritrova tutto con `grep -n`, i numeri si spostano dopo ogni task):

| Dove (riga a `c296732`) | Cosa | Task |
| :--- | :--- | :--- |
| `func importFolderSlug` (1378) | un'etichetta uguale a un nome escluso diventa «Import» | 1 |
| `nonisolated enum LibraryExclusions` (1631-1645) | `quarantineFolderName`, `isQuarantineName`, `isExcludedName`, `isInsideQuarantine` | 1 |
| `nonisolated enum InventoryPerimeter` (6008-6020) | usa `isExcludedName` | 1 |
| `S3Syncer.previewUpload` (8487) e `S3Syncer.sync(from localURL:)` (8511) | la traversata comune `localUploadFiles`, che salta la quarantena | 1 |
| `S3Syncer.topLevelFolders` (8991), `RestoreEngine.listAvailableFolders(rootURL:)` (12802) | la quarantena non è una cartella da ripristinare | 1 |
| `integritySampleLocalPair` (12487), `ReviewEngine.sampleS3Pair` (12591) | la quarantena non si campiona | 1 |
| `S3Syncer.fetchListPageXML` (8690) | parametro `prefix` (default `nil`) | 2 |
| dentro `S3Syncer`, prima di `nonisolated struct S3ListPage` (9215) | `S3ObjectHead` | 2 |
| `// MARK: - AWS Signature V4` / `private func sign` (9077-9151) | richieste della riparazione (`encodeKeyStrict`, `objectRequestPath`, `copySourceHeader`, `parseHead`, `copyObjectSucceeded`, `headObject`, `copyObject`, `listObjects`, `replaceObjectForRepair`) prima del MARK; `sign` internal con `canonicalURI`/`extraSignedHeaders`, cuore puro `sigV4Signature` | 2 |
| **regione R**: subito prima di `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (6614) | in quest'ordine: `RepairPaths`/`RepairCandidate`/`RepairRules` (T3), `RepairStep`/`RepairOutcomeKind`/`RepairRecord`/`RepairLog`/`RepairLogStore` (T4), `RepairCloud`/`RepairFailure`/`RepairOutcome`/`RepairEngine` (T5), `RepairStatus` (T7), `S3RepairCloud` (T8). Ogni blocco si aggiunge **dopo** il precedente, sempre prima di quella riga `MARK` | 3-8 |
| `DuplicatesStatus.trashDisabledReason` (3662), `.undoDisabledReason` (3701), `InventoryStartGate` (6366), `JobStartGate` (6779), `LibraryIndexCommandGate` (6809, 6847), prima di `/// I testi della finestra Inventario` (6413) | `isRepairing`; `RepairStartGate` | 6 |
| `BackupRunner`: `beginDuplicateTrashing` (10473), `beginTrashRestore` (10500), chiamate ai cancelli in `startTrashRestore` (10570), `startDuplicateTrashRun` (10675), `rebuildLibraryIndex` (11024), `startInventoryRefresh` (11136), `run(label:)` (12010) | `isRepairing`, `beginRepair`/`endRepair`, parametro nei cancelli | 6 |
| viste: `LibraryIndexCard.commandsDisabledReason` (15338), `DuplicatesView.trashDisabledReasonNow` (15910)/`undoDisabledReasonNow` (15934), `InventoryView.startDisabledReason` (16739) | parametro `isRepairing` | 6 |
| `InventorySummary` (6258-6290), `InventoryStatus.readOnlyNote` (6429) | `repairCandidates`; testo nuovo (S8) | 7 |
| `BackupRunner`, subito prima del commento `` // `autoRefreshLibraryIndexIfEnabled()` e `` (11243) | `repairLogStore`, `repairStep`, `repairingKey`, `lastRepairOutcome`, `repairRecords`, `refreshRepairRecords`, `startRepair`, `finishRepair` | 8 |
| `InventoryView` (16711-16864) | sottoelenco «si possono riparare», foglio di riepilogo, conferma | 9 |

**`AppBackupFotoTests/`** — nuovi: `QuarantineExclusionTests` (10), `S3SignatureTests` (8), `S3RepairRequestsTests` (9), `RepairRulesTests` (24), `RepairPathsTests` (7), `RepairLogTests` (7), `RepairEngineTests` (37, con `FakeRepairCloud`, `StepRecorder`, `Counter`), `RepairGatesTests` (9), `RepairStatusTests` (23). Estesi: `MainThreadIsolationTests` (+2). Modificati solo nella firma (aggiunta di `isRepairing: false`, **nessuna asserzione cambiata**): `JobStartGateTests` (21 chiamate), `LibraryIndexStatusTests` (15), `DuplicatesStatusTests` (30), `InventoryRefreshTests` (l'aiuto `reason`). **Totale atteso: B + 136** (con B = 1.023, **1.159**).

**Docs:** `Docs/adr/0016-…md` (nuovo), `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`.

### ID per il pbxproj (verificati assenti a `c296732` con `grep -c`)

| File | `PBXFileReference` | `PBXBuildFile` |
| :--- | :--- | :--- |
| `QuarantineExclusionTests.swift` | `B63D84C9B5F6DFE611C89286` | `4617E005A1169953A4B9116B` |
| `S3SignatureTests.swift` | `1922A6BF150035D742D1CE8A` | `81C34F19C0E11548D23E19B0` |
| `S3RepairRequestsTests.swift` | `83F99398053EFEE0718BE507` | `4FEC1A21A21E1363C8AC16A1` |
| `RepairRulesTests.swift` | `E3C9EBC30E095C631289A569` | `300DA1BAF6ECCD2BD27DCBCD` |
| `RepairPathsTests.swift` | `309AE9683F23DFEF253FB1FA` | `737DA6D834924A1DF98041E7` |
| `RepairLogTests.swift` | `3D7BDF69D092B120D96219AA` | `C02DAB72CD063550BF921394` |
| `RepairEngineTests.swift` | `C17486BE67CFB854FE2CAE08` | `66E8612C3A08039111319C1E` |
| `RepairGatesTests.swift` | `FC1ACC7BA2F23A603E66A74E` | `926C7CE294F0C7B407DC2164` |
| `RepairStatusTests.swift` | `26950E0DF441DE580320805F` | `A446EC617D35A9FB526D0C58` |

Per ogni file le quattro righe hanno questa forma (esempio con `RepairRulesTests`; i tab sono quelli delle righe vicine, il gruppo e la fase sono gli stessi del piano precedente, verificati presenti a `c296732`):

```
/* sezione PBXBuildFile */
		300DA1BAF6ECCD2BD27DCBCD /* RepairRulesTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = E3C9EBC30E095C631289A569 /* RepairRulesTests.swift */; };
/* sezione PBXFileReference */
		E3C9EBC30E095C631289A569 /* RepairRulesTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = RepairRulesTests.swift; sourceTree = "<group>"; };
/* children del gruppo 11123F514533138A989F11C4 /* AppBackupFotoTests */ */
				E3C9EBC30E095C631289A569 /* RepairRulesTests.swift */,
/* files della fase 62FE197CBAC2C2E908580583 /* Sources */ */
				300DA1BAF6ECCD2BD27DCBCD /* RepairRulesTests.swift in Sources */,
```

Prima di usarli: `grep -c <ID> AppBackupFoto.xcodeproj/project.pbxproj` deve dare `0`.

---

## Comandi di build e test

**Precondizione di ogni build/test con `xcodebuild`:** nessun backup in corso nell'app di Enrico (il target di test ha `TEST_HOST` = l'app). `SP` = una cartella di lavoro sotto `/private/tmp/claude-501/`, mai il `derivedDataPath` di default.

**Su questo progetto `xcodebuild` impiega più di 10 minuti**, e un agente fermo 10 minuti senza output viene terminato. Due livelli, quindi:

1. **Verifica veloce, a ogni step che lo chiede** (~30 s, nessun lancio dell'app): `fasttest.sh`, creato nel Task 0 con il testo qui sotto. Compila con `swiftc` **il vero** `AppBackupFoto/ContentView.swift` del repository e **tutti** i file di `AppBackupFotoTests/` (copiandoli in `$SP`, il repository non si tocca) con le impostazioni del target, e li esegue con `xcrun xctest`. È lo stesso meccanismo con cui l'Architect ha verificato questo piano. Non vede: il pbxproj (un file di test non registrato lo esegue lo stesso — per questo il conteggio con `xcodebuild` resta obbligatorio ai punti di controllo), le risorse dell'app, il test host.
2. **`xcodebuild` vero, in background**, ai punti di controllo: fine dei Task 3, 6 e 9 (e prima di unire il branch). Lanciarlo con `run_in_background` e aspettarne la fine con un ciclo di attesa sul file di log, mai in primo piano. È la sola prova che soddisfa l'hook di fine sessione (`BUILD SUCCEEDED`/`TEST SUCCEEDED`).

```bash
# 1. verifica veloce (una classe, o tutta la suite senza argomento)
/private/tmp/claude-501/repair-impl/fasttest.sh RepairRulesTests
/private/tmp/claude-501/repair-impl/fasttest.sh            # atteso: "Executed N tests, with 0 failures", 0 warning
# 2. xcodebuild, in background (run_in_background: true), poi attesa sul log
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=/private/tmp/claude-501/repair-impl
rm -rf $SP/dd && xcodebuild -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l      # atteso 0, sempre
xcodebuild test-without-building -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" $SP/test.log | tail -2
```

Testo di `fasttest.sh` (da salvare in `/private/tmp/claude-501/repair-impl/fasttest.sh`, `chmod +x`; **non** va nel repository):

```swift
#!/bin/bash
# Verifica veloce, FUORI da Xcode, di AppBackupFoto/ContentView.swift e di tutti i test del
# repository (ROADMAP #45, piano 2026-10-04). Non tocca il repository: copia i sorgenti in $SP.
# Uso: fasttest.sh [Classe di test]     (senza argomento: suite completa)
set -euo pipefail
REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=${SP:-/private/tmp/claude-501/repair-impl/fast}
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

1. **Trova il codice con `grep -n`**, mai col numero di riga: quelli citati valgono per `c296732` e si spostano dopo ogni task.
2. **Il codice si copia così com'è**: ogni «Trova … Sostituisci con …» di questo piano è stato applicato con un controllo automatico che il testo cercato comparisse **una sola volta**, poi compilato ed eseguito. Se un «Trova» non si trova, o qualcosa non compila nel target vero, **fermati e rimanda all'Architect**: non adattarlo a tentativi.
3. **Zero warning.** Un solo rimedio è autorizzato in anticipo: se un riferimento a una funzione statica `@MainActor` passata come valore dà «call to main actor-isolated … in a synchronous nonisolated context», si riscrive come chiusura. Ogni altro warning di isolamento: fermati.
4. **Asserzioni esistenti.** Nel Task 6 si aggiunge `isRepairing: false` alle chiamate esistenti dei cancelli nei test: cambiare la firma è ammesso, cambiare **cosa asseriscono** no.
5. **Ogni task dichiara i mutanti che devono morire**; quelli segnati «(verificato)» sono stati provati dall'Architect sul prototipo.
6. **Commit con verifica veloce verde** (0 warning, conteggio uguale all'atteso), e ai punti di controllo anche con `xcodebuild` verde. Messaggio in italiano, chiuso da:
   ```
   Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
   ```
7. **Nessuna prova su `/Volumes` o su Cubbit** fino al Task 11.

---

### Task 0: branch, baseline, ADR-0016, strumento di verifica veloce

**Files:** `Docs/adr/0016-la-riparazione-scrive-solo-se-due-copie-su-tre-sono-d-accordo-e-prima-mette-da-parte-quella-che-sostituisce.md` (nuovo), `Docs/superpowers/plans/2026-10-04-repair-from-majority.md` (questo piano), `/private/tmp/claude-501/repair-impl/fasttest.sh` (fuori dal repository).

- [ ] **Step 1:** `git status --short`: l'unico file non tracciato ammesso è `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md` (di un altro piano: **non** si committa qui). `git switch -c feature/repair-from-majority main`; `git rev-parse --short HEAD` → `c296732` o un discendente (in quel caso rifai i `grep -n` delle ancore della mappa e fermati se una manca).
- [ ] **Step 2:** Verifica che Enrico abbia risposto su S1-S11 e D1-D4. Se una risposta è diversa dalla «Proposta», **fermati e rimanda all'Architect**.
- [ ] **Step 3:** Crea `fasttest.sh` (testo nella sezione «Comandi»), `chmod +x`, e lancialo senza argomenti: `Executed 1023 tests, with 0 failures`, 0 warning. Se il numero è diverso, `B` = quello misurato e tutti gli attesi del piano si spostano della differenza.
- [ ] **Step 4:** Chiedi a Enrico il via libera («nessun backup in corso nell'app?») e lancia in background la build pulita e la suite con `xcodebuild`: 0 warning, `Executed 1023 tests` (B).
- [ ] **Step 5:** Scrivi l'ADR con questo testo (in fondo, alla sezione «Risposte di Enrico», le risposte ricevute):

```markdown
# ADR-0016 — La riparazione scrive solo se due copie su tre sono d'accordo, e prima mette da parte quella che sostituisce

**Data:** 2026-10-04
**Stato:** Accettata

## Contesto

Il primo inventario completo (ADR-0015, ROADMAP #44) ha trovato una foto rovinata su Cubbit: `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, integra e identica su SSD e HDD, su Cubbit con la stessa dimensione e gli ultimi 38.796 byte a zero (verificato scaricandola, 2026-10-01). Il backup non se ne accorge perché confronta solo la dimensione, e per la regola zero-overwrite non la ricaricherebbe comunque. Ripararla vuol dire sovrascrivere un file: la prima eccezione a zero-overwrite. Lo stesso meccanismo servirà ai progetti 3 e 4 (doppioni con garanzia). Spec: `Docs/superpowers/specs/2026-10-01-repair-from-majority-design.md`; piano: `Docs/superpowers/plans/2026-10-04-repair-from-majority.md`.

Fatti verificati prima di progettare (2026-10-04): Cubbit accetta la copia lato server (`CopyObject`, provata con `rclone copyto` sulla `.heic`: ETag identico); il bucket non ha versioni.

## Opzioni valutate

- **A. Ricaricare la foto a mano con rclone.** Scartata: nessun ricontrollo, nessuna traccia, e la prossima foto rovinata si ripresenta uguale.
- **B. Sovrascrivere la copia diversa con quella dell'SSD, sempre.** Scartata: l'SSD può essere lui la copia rovinata (decisione 2 di Enrico: si ripara anche l'SSD), e una sovrascrittura senza quarantena non è annullabile.
- **C. Regola «2 su 3» con quarantena (scelta).** Si scrive solo se due archivi hanno lo stesso contenuto certificato e il terzo uno dimostrato diverso; prima si ricontrolla tutto dal vivo (l'inventario è una cache, ADR-0002), si mette da parte la copia diversa in `_quarantena/<giorno>/<percorso>` sullo stesso archivio, poi si scrive e si verifica.
- **D. Svuotare la quarantena dall'app.** Scartata da Enrico (decisione 4): la svuota lui dal Finder o da Cubbit.

## Decisione e motivo

**Quando:** tre archivi completi nell'ultimo giro; stesso percorso, una volta, in ciascuno; due d'accordo (SHA256 fra SSD e HDD; su Cubbit l'ETag che certifica quel contenuto); il terzo dimostrato diverso — su un disco un SHA256 diverso, su Cubbit un ETag a parte unica (l'MD5) diverso. Un ETag a pezzi che non torna non dimostra niente e la voce resta in ❗. Una riparazione alla volta, con riepilogo e conferma.

**Da dove:** sempre da un file locale — l'SSD per riparare HDD o Cubbit, l'HDD per riparare l'SSD; la seconda copia buona (HDD per Cubbit, Cubbit per i dischi) deve coincidere anche lei, al ricontrollo.

**Come, senza perdere mai una copia:** su disco solo `rename(2)` sullo stesso volume (mai `removeItem`, mai `FileManager.moveItem`, che fra due volumi copia e cancella); la copia buona si prepara e si rilegge **prima** di spostare quella rovinata, così un fallimento non lascia mai il percorso vuoto. Su Cubbit: copia lato server in quarantena (idempotente: una copia già messa da parte un altro giorno, con la stessa dimensione e lo stesso ETag, vale), HEAD della copia, poi la sola sovrascrittura del progetto con l'`upload` del backup, poi HEAD con l'ETag atteso. Un registro sul Mac (`repair-log.json`) scritto **prima** di toccare qualunque archivio e aggiornato con l'esito.

**La quarantena non rientra mai** in backup, elenco, inventario, Doppioni, ripristino, campione d'integrità: un nome solo (`LibraryExclusions.quarantineFolderName`), confrontato senza maiuscole, e un test di parità che lo pretende da ogni lettore.

**Cosa si accetta di perdere:** su Cubbit le chiavi con `+`, apostrofo e simili non si riparano ancora (caricamento e richieste nuove codificano il percorso in modo diverso); un ETag a pezzi non coincidente resta in ❗; la quarantena occupa spazio finché Enrico non la svuota; dopo una riparazione l'inventario va riaggiornato a mano per confermarla.

**Per riaprirla** serve un argomento nuovo: un bucket con versioni (la quarantena su Cubbit diventerebbe superflua), checksum SHA256 lato server, o una prova dal vivo che copra le chiavi con caratteri speciali.

## Risposte di Enrico (S1-S11, D1-D4)

<!-- riportare qui, una riga per punto -->
```

- [ ] **Step 6:** Commit (solo documentazione: l'ADR e questo piano, copiato in `Docs/superpowers/plans/2026-10-04-repair-from-majority.md`):
  ```
  ADR-0016 e piano: riparazione di una copia rovinata con la regola 2 su 3

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 1: `_quarantena` non rientra da nessuna parte (test di parità)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `LibraryExclusions` (1631-1645), `importFolderSlug` (1378), `InventoryPerimeter` (6008-6020), `S3Syncer.previewUpload` (8487) e `S3Syncer.sync(from localURL:)` (8511), `S3Syncer.topLevelFolders` (8991), `integritySampleLocalPair` (12487), `ReviewEngine.sampleS3Pair` (12591), `RestoreEngine.listAvailableFolders(rootURL:)` (12802).
- Create: `AppBackupFotoTests/QuarantineExclusionTests.swift` (registrarlo nei 4 punti: `B63D84C9B5F6DFE611C89286` / `4617E005A1169953A4B9116B`).

**Interfaces:**
- Consumes: `LibraryExclusions.names`/`shouldExclude` (esistenti, chiamati da `FileSyncer`, `LibraryIndexer`, `InventoryScanner`).
- Produces:
  - `LibraryExclusions.quarantineFolderName: String` (= `"_quarantena"`), già dentro `names`
  - `LibraryExclusions.isQuarantineName(_ name: String) -> Bool` (senza maiuscole)
  - `LibraryExclusions.isExcludedName(_ name: String) -> Bool` (`names` + `._` + quarantena; `shouldExclude` delega qui)
  - `LibraryExclusions.isInsideQuarantine(relativePath: String) -> Bool`
  - `nonisolated static func S3Syncer.localUploadFiles(root: URL, isCancelled: () -> Bool = { false }) -> [(url: URL, key: String, size: Int64)]?` — la traversata unica di `sync` e `previewUpload`

**Perché la parità passa da qui.** `FileSyncer` (SSD → HDD, ripristino da disco), `LibraryIndexer` (elenco, quindi Doppioni) e `InventoryScanner` usano già `LibraryExclusions.shouldExclude` con `skipDescendants`: basta che il nome sia lì. Non lo usano `S3Syncer.sync`/`previewUpload` (hanno un filtro loro, `._*` e `.DS_Store`: allinearli del tutto cambierebbe il comportamento su `lost+found`/`Backups.backupdb`, decisione ancora aperta scritta nel commento di `LibraryExclusions`), `InventoryPerimeter` (confronta le componenti con `names`), il ripristino (elenca le cartelle di primo livello) e il campione d'integrità: ognuno riceve qui il controllo esplicito, e il test lo pretende da tutti.

- [ ] **Step 1: test che fallisce.** Crea `AppBackupFotoTests/QuarantineExclusionTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// La cartella `_quarantena` della riparazione (ROADMAP #45, ADR-0016) non deve rientrare da
/// nessuna parte: backup SSD → HDD e SSD → Cubbit, elenco delle foto (e quindi Doppioni),
/// inventario (dischi e Cubbit), ripristino, campione d'integrita'.
///
/// E' il TEST DI PARITA' chiesto dalla spec: ogni lettore riceve lo stesso albero — una foto
/// vera, la sua copia rovinata messa in quarantena, e una copia in arrivo lasciata li' da una
/// riparazione fallita — e deve vedere la sola foto vera. Se un giorno qualcuno scrive un
/// lettore nuovo, o cambia l'esclusione di uno solo, questo file lo pretende per tutti.
final class QuarantineExclusionTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!

    override func setUpWithError() throws {
        // `realResolvedPath`: la cartella temporanea passa da `/var` → `/private/var`, e
        // `S3Syncer.localUploadFiles` calcola la chiave togliendo la radice come stringa
        // (sull'SSD vero, `/Volumes/SSD - Enri`, non ci sono link da risolvere).
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("QuarantineExclusionTests-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("SSD")
        try put("Foto/a.jpg", "foto vera")
        // La copia rovinata messa da parte, e una copia in arrivo mai rinominata: STESSO
        // contenuto della foto vera, cosi' i Doppioni la vedrebbero come copia se rientrasse.
        try put("_quarantena/2026-10-04/Foto/a.jpg", "foto vera")
        try put("_quarantena/2026-10-04/Foto/a.jpg.in-arrivo-1a2b3c4d", "foto vera")
        // exFAT non distingue le maiuscole: anche questa va saltata. Sta DENTRO `Foto/` e non
        // in radice perche' anche la cartella temporanea (APFS) non distingue le maiuscole, e in
        // radice finirebbe dentro la `_quarantena` appena creata: il test non proverebbe niente.
        try put("Foto/_Quarantena/b.jpg", "foto vera")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func put(_ rel: String, _ text: String, under base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Una sola fonte

    func testTheFolderName_isOneAndIsInTheSharedList() {
        XCTAssertEqual(LibraryExclusions.quarantineFolderName, "_quarantena")
        XCTAssertTrue(LibraryExclusions.names.contains(LibraryExclusions.quarantineFolderName))
    }

    func testTheName_isMatchedWithoutCase_butExactly() {
        for name in ["_quarantena", "_Quarantena", "_QUARANTENA"] {
            XCTAssertTrue(LibraryExclusions.shouldExclude(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["quarantena", "_quarantena2", "_quarantena.jpg", "la_quarantena"] {
            XCTAssertFalse(LibraryExclusions.shouldExclude(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        XCTAssertTrue(LibraryExclusions.isInsideQuarantine(relativePath: "_quarantena/2026-10-04/Foto/a.jpg"))
        XCTAssertFalse(LibraryExclusions.isInsideQuarantine(relativePath: "Foto/quarantena/a.jpg"))
    }

    // MARK: - I lettori, uno per uno

    func testListOfPhotos_andDuplicates_doNotSeeIt() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        _ = try LibraryIndexer(store: store).scan(root: root)
        XCTAssertEqual(try store.allKeys(), ["foto/a.jpg"])
        XCTAssertTrue(try store.duplicateGroups().isEmpty,
                      "la copia in quarantena non e' un doppione da proporre")
    }

    func testInventoryOfTheDisks_doesNotSeeIt() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        let report = try InventoryScanner(store: store, cancelFlag: CancelFlag()).scan(root: root, archive: .ssd, runId: 1)
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(Set(try store.inventoryLocalRows(.ssd).keys), ["foto/a.jpg"])
    }

    func testInventoryOfCubbit_doesNotSeeIt() {
        XCTAssertTrue(InventoryPerimeter.includesS3Key("Foto/a.jpg"))
        XCTAssertFalse(InventoryPerimeter.includesS3Key("_quarantena/2026-10-04/Foto/a.jpg"))
        XCTAssertFalse(InventoryPerimeter.includesS3Key("_Quarantena/2026-10-04/Foto/a.jpg"))
    }

    func testBackupToTheHDD_doesNotCopyIt() async throws {
        let hdd = tmp.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        let syncer = FileSyncer()
        let preview = await syncer.previewSync(from: root, to: hdd, deep: false)
        XCTAssertEqual(preview.toAdd, 1)
        let result = try await syncer.sync(from: root, to: hdd, deep: false, onStatus: { _ in }, onProgress: { _ in })
        XCTAssertEqual(result.copied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Foto/a.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("_quarantena").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Foto/_Quarantena").path))
    }

    func testBackupToCubbit_doesNotUploadIt() throws {
        let files = try XCTUnwrap(S3Syncer.localUploadFiles(root: root))
        XCTAssertEqual(files.map(\.key), ["Foto/a.jpg"])
    }

    func testRestore_doesNotOfferIt() {
        XCTAssertEqual(RestoreEngine().listAvailableFolders(rootURL: root), ["Foto"])
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: ["Foto/a.jpg", "_quarantena/2026-10-04/Foto/a.jpg"]),
                       ["Foto"])
    }

    func testIntegritySample_doesNotSampleIt() throws {
        // Sull'HDD c'e' SOLO la quarantena: senza esclusione il campione la conterebbe come
        // "sorgente mancante".
        let src = tmp.appendingPathComponent("SRC"), dst = tmp.appendingPathComponent("DST")
        try put("Foto/x.jpg", "x", under: src)
        try put("_quarantena/2026-10-04/Foto/y.jpg", "y", under: dst)
        let result = integritySampleLocalPair(srcRoot: src, dstRoot: dst, pairName: "Test", sampleSize: 20,
                                              defaults: UserDefaults(suiteName: "QuarantineExclusionTests-\(UUID())")!)
        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.skippedNoSource, 0)
    }

    // MARK: - Un'importazione non deve poter finire li' dentro

    func testImportLabel_cannotBecomeAnExcludedFolder() {
        XCTAssertEqual(importFolderSlug("_quarantena"), "Import")
        XCTAssertEqual(importFolderSlug("_Quarantena"), "Import")
        XCTAssertEqual(importFolderSlug("lost+found"), "Import")
        XCTAssertEqual(importFolderSlug("Quarantena estate"), "Quarantena estate")
    }
}
```

Registralo nel pbxproj.

- [ ] **Step 2: esegui e verifica che fallisca.** `fasttest.sh QuarantineExclusionTests` → `COMPILAZIONE TEST FALLITA` con `type 'LibraryExclusions' has no member 'quarantineFolderName'` (e `localUploadFiles`).

- [ ] **Step 3: implementa.** Dieci sostituzioni, in quest'ordine.

**3a. `LibraryExclusions`.**

Trova (deve comparire **una sola volta**):

```swift
nonisolated enum LibraryExclusions {
    static let names: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb"
    ]

    /// Confronto sull'ultima componente del path, mai sul path intero: una cartella
    /// di passaggio dal nome simile non deve escludere i file che contiene.
    /// `._*` sono i sidecar AppleDouble che macOS crea sui filesystem non-HFS —
    /// l'SSD è ExFAT, quindi ce ne sono ovunque.
    static func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return names.contains(name) || name.hasPrefix("._")
    }
}
```

Sostituisci con:

```swift
nonisolated enum LibraryExclusions {
    /// La cartella in cui la riparazione (ROADMAP #45, ADR-0016) mette da parte la copia
    /// rovinata che sostituisce, alla radice di SSD, HDD e Cubbit. NON e' contenuto
    /// dell'utente: se rientrasse nel backup, il backup ricaricherebbe su Cubbit (o copierebbe
    /// sull'HDD) proprio la copia rovinata, e i Doppioni la vedrebbero come una copia in piu'.
    /// Il nome vive QUI e in nessun altro posto: anche `RepairPaths` lo legge da qui.
    static let quarantineFolderName = "_quarantena"

    static let names: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb",
        quarantineFolderName
    ]

    /// Vero per la cartella di quarantena, senza distinguere maiuscole e minuscole: l'SSD e'
    /// exFAT e non le distingue, quindi `_Quarantena` creata a mano e' la stessa cartella in
    /// cui la riparazione scriverebbe. Verificato il 2026-10-04 sull'elenco e sull'inventario
    /// salvati: nessun percorso di SSD, HDD o Cubbit contiene oggi `quarantena`.
    static func isQuarantineName(_ name: String) -> Bool {
        name.compare(quarantineFolderName, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    /// Il confronto su UNA componente di percorso, condiviso da `shouldExclude` (dischi) e da
    /// `InventoryPerimeter` (chiavi di Cubbit): i nomi della lista, i sidecar `._` e la
    /// cartella di quarantena.
    static func isExcludedName(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._") || isQuarantineName(name)
    }

    /// Confronto sull'ultima componente del path, mai sul path intero: una cartella
    /// di passaggio dal nome simile non deve escludere i file che contiene.
    /// `._*` sono i sidecar AppleDouble che macOS crea sui filesystem non-HFS —
    /// l'SSD è ExFAT, quindi ce ne sono ovunque.
    static func shouldExclude(_ url: URL) -> Bool {
        isExcludedName(url.lastPathComponent)
    }

    /// Per i percorsi che non si scorrono con `shouldExclude` (le chiavi di Cubbit nel
    /// campione d'integrita'): vero se UNA componente del percorso relativo e' la cartella di
    /// quarantena.
    static func isInsideQuarantine(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { isQuarantineName(String($0)) }
    }
}
```

**3b. `InventoryPerimeter`: il commento e il controllo** (due sostituzioni).

Trova (deve comparire **una sola volta**):

```swift
    /// nessuna componente fra `LibraryExclusions.names`, e `IndexableKind` foto o video.
```

Sostituisci con:

```swift
    /// nessuna componente esclusa da `LibraryExclusions.isExcludedName` (quindi nemmeno la
    /// cartella di quarantena della riparazione, ADR-0016), e `IndexableKind` foto o video.
```

Trova (deve comparire **una sola volta**):

```swift
        for c in components where c.hasPrefix(".") || LibraryExclusions.names.contains(String(c)) {
```

Sostituisci con:

```swift
        for c in components where c.hasPrefix(".") || LibraryExclusions.isExcludedName(String(c)) {
```

**3c. `S3Syncer.previewUpload`: la traversata diventa `localUploadFiles`** (la funzione nuova si aggiunge subito dopo `previewUpload`).

Trova (deve comparire **una sola volta**):

```swift
        let existingKeys = Set(try await listAll(config: config).keys)
        let fm = FileManager.default
        var files: [(key: String, size: Int64)] = []
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        while let f = enumerator.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            files.append((rel, Int64(v?.fileSize ?? 0)))
        }
        return Self.previewCount(files: files, existingKeys: existingKeys)
    }
```

Sostituisci con:

```swift
        let existingKeys = Set(try await listAll(config: config).keys)
        guard let files = Self.localUploadFiles(root: localURL) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        return Self.previewCount(files: files.map { (key: $0.key, size: $0.size) }, existingKeys: existingKeys)
    }

    /// I file dell'SSD che il backup SSD → Cubbit considera, con la chiave che avrebbero su
    /// Cubbit. UNA sola traversata per `sync` e `previewUpload` (prima erano due copie dello
    /// stesso ciclo). Stesse regole di prima — `.skipsHiddenFiles`, niente `._*` e
    /// `.DS_Store` — piu' la cartella di quarantena della riparazione (ADR-0016), saltata con
    /// tutto il suo contenuto: senza, il backup ricaricherebbe su Cubbit la copia rovinata messa
    /// da parte sull'SSD. NON usa `LibraryExclusions.shouldExclude` per intero: allineare anche
    /// `lost+found`/`Backups.backupdb` e' un cambio di comportamento ancora da decidere (vedi il
    /// commento di `LibraryExclusions`). `nil` se la radice non si lascia scorrere.
    // `nonisolated`: nessuno stato dell'istanza; il flag di interruzione arriva come closure.
    nonisolated static func localUploadFiles(root localURL: URL, isCancelled: () -> Bool = { false })
        -> [(url: URL, key: String, size: Int64)]? {
        let fm = FileManager.default
        var files: [(url: URL, key: String, size: Int64)] = []
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        while let f = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            let name = f.lastPathComponent
            if LibraryExclusions.isQuarantineName(name) { enumerator.skipDescendants(); continue }
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            files.append((url: f, key: rel, size: Int64(v?.fileSize ?? 0)))
        }
        return files
    }
```

**3d. `S3Syncer.sync`: stessa traversata.** Il ciclo tolto è identico a quello di `previewUpload` più `if cancelled { break }`, che diventa la closure `isCancelled`.

Trova (deve comparire **una sola volta**):

```swift
        let fm = FileManager.default
        var files: [(url: URL, key: String, size: Int64)] = []
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        while let f = enumerator.nextObject() as? URL {
            if cancelled { break }
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            files.append((url: f, key: rel, size: Int64(v?.fileSize ?? 0)))
        }
```

Sostituisci con:

```swift
        guard let files = Self.localUploadFiles(root: localURL, isCancelled: { self.cancelled }) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
```

**3e. Ripristino da Cubbit: `S3Syncer.topLevelFolders`.**

Trova (deve comparire **una sola volta**):

```swift
        for key in keys {
            guard key.contains("/"), let first = key.split(separator: "/", maxSplits: 1).first else { continue }
            let name = String(first)
            if !seen.contains(name) { seen.insert(name); ordered.append(name) }
```

Sostituisci con:

```swift
        for key in keys {
            guard key.contains("/"), let first = key.split(separator: "/", maxSplits: 1).first else { continue }
            let name = String(first)
            // La quarantena della riparazione (ADR-0016) non e' una cartella da ripristinare.
            if LibraryExclusions.isQuarantineName(name) { continue }
            if !seen.contains(name) { seen.insert(name); ordered.append(name) }
```

**3f. Ripristino da SSD/HDD: `RestoreEngine.listAvailableFolders(rootURL:)`.**

Trova (deve comparire **una sola volta**):

```swift
            guard vals?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            return name.hasPrefix(".") ? nil : name
```

Sostituisci con:

```swift
            guard vals?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            // La quarantena della riparazione (ADR-0016) non e' una cartella da ripristinare.
            return name.hasPrefix(".") || LibraryExclusions.isQuarantineName(name) ? nil : name
```

**3g. Campione d'integrità, coppie locali: `integritySampleLocalPair`** (il nome si legge prima del controllo sul file regolare, per poter saltare la cartella intera).

Trova (deve comparire **una sola volta**):

```swift
    while let f = enumerator.nextObject() as? URL {
        let vals = try? f.resourceValues(forKeys: [.isRegularFileKey])
        guard vals?.isRegularFile == true else { continue }
        let name = f.lastPathComponent
        if name.hasPrefix("._") || name == ".DS_Store" { continue }
        relPaths.append(String(f.path.dropFirst(base.count).drop(while: { $0 == "/" })))
    }
```

Sostituisci con:

```swift
    while let f = enumerator.nextObject() as? URL {
        let name = f.lastPathComponent
        // La quarantena della riparazione (ADR-0016) non e' una copia di backup da campionare.
        if LibraryExclusions.isQuarantineName(name) { enumerator.skipDescendants(); continue }
        let vals = try? f.resourceValues(forKeys: [.isRegularFileKey])
        guard vals?.isRegularFile == true else { continue }
        if name.hasPrefix("._") || name == ".DS_Store" { continue }
        relPaths.append(String(f.path.dropFirst(base.count).drop(while: { $0 == "/" })))
    }
```

**3h. Campione d'integrità, Cubbit: `ReviewEngine.sampleS3Pair`.**

Trova (deve comparire **una sola volta**):

```swift
        let candidates = remoteKeys.keys.filter { fm.fileExists(atPath: ssdRoot.appendingPathComponent($0).path) }
```

Sostituisci con:

```swift
        let candidates = remoteKeys.keys.filter {
            // La quarantena della riparazione (ADR-0016) non e' una copia di backup da campionare.
            !LibraryExclusions.isInsideQuarantine(relativePath: $0)
                && fm.fileExists(atPath: ssdRoot.appendingPathComponent($0).path)
        }
```

**3i. `importFolderSlug`.**

Trova (deve comparire **una sola volta**):

```swift
    if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "Import" }
    return cleaned
}
```

Sostituisci con:

```swift
    // Un'etichetta uguale a un nome escluso (`_quarantena`, `lost+found`, ...) farebbe
    // atterrare l'importazione in una cartella che backup, elenco e inventario saltano: le
    // foto resterebbero sull'SSD senza mai arrivare su HDD e Cubbit (ROADMAP #45).
    if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) || LibraryExclusions.isExcludedName(cleaned) {
        return "Import"
    }
    return cleaned
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh QuarantineExclusionTests` → `Executed 10 tests, with 0 failures`. Poi `fasttest.sh LibraryExclusionsTests` → `Executed 5 tests, with 0 failures` (invariati), `fasttest.sh RestoreS3FolderParsingTests` → `Executed 4 tests, with 0 failures`.
- [ ] **Step 5:** `fasttest.sh` (suite completa): `Executed 1033 tests` (B+10), 0 fallimenti, 0 warning.
- [ ] **Mutanti che devono morire:** togliere `if LibraryExclusions.isQuarantineName(name) { enumerator.skipDescendants(); continue }` da `localUploadFiles` (verificato: muore `testBackupToCubbit_doesNotUploadIt`); togliere `quarantineFolderName` da `names` (verificato: muore `testTheFolderName_isOneAndIsInTheSharedList` — gli altri lettori restano protetti da `isQuarantineName` dentro `isExcludedName`, ed è voluto: due difese); togliere `|| isQuarantineName(name)` da `isExcludedName` (verificato: 11 fallimenti — i lettori che vedono `Foto/_Quarantena/b.jpg`, fra cui `testBackupToTheHDD_doesNotCopyIt`, `testInventoryOfTheDisks_doesNotSeeIt`, `testInventoryOfCubbit_doesNotSeeIt`, e `testImportLabel_cannotBecomeAnExcludedFolder`). **Attenzione, già pagata una volta scrivendo questo test:** la cartella temporanea (APFS) non distingue le maiuscole, quindi `_Quarantena` in radice finirebbe dentro la `_quarantena` già creata e il test non proverebbe niente — per questo la variante con la maiuscola sta in `Foto/`.
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 1: la cartella _quarantena non rientra in backup, elenco, inventario, ripristino

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 2: le richieste nuove a Cubbit — HEAD, copia lato server, lista con prefisso, la sola sovrascrittura

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `S3Syncer.sign` (9077-9151), `S3Syncer.fetchListPageXML` (8690), dentro `S3Syncer` prima di `nonisolated struct S3ListPage` (9215).
- Create: `AppBackupFotoTests/S3SignatureTests.swift` (`1922A6BF150035D742D1CE8A` / `81C34F19C0E11548D23E19B0`), `AppBackupFotoTests/S3RepairRequestsTests.swift` (`83F99398053EFEE0718BE507` / `4FEC1A21A21E1363C8AC16A1`).

**Interfaces:**
- Consumes: `S3Syncer.upload(url:key:config:gate:onStart:onStatus:)` (privata, esistente), `AdaptiveUploadGate(startingLimit:ceiling:)`, `beginNewOperation()`, `parseListPage`, `session`, `S3HTTPError`.
- Produces (tutto dentro `S3Syncer`):
  - `func sign(_:config:body:date:canonicalURI: String? = nil, extraSignedHeaders: [String: String] = [:])` — da `private` a `internal`, stessa firma di oggi per i chiamanti esistenti
  - `nonisolated static func sigV4Signature(method:canonicalURI:canonicalQuery:headers:payloadHash:amzDate:secretAccessKey:region:) -> (signedHeaders: String, signature: String)`
  - `func fetchListPageXML(config:token:prefix: String? = nil)`
  - `nonisolated struct S3ObjectHead: Equatable, Sendable { let size: Int64; let etag: String? }`
  - `nonisolated static func encodeKeyStrict(_:) -> String`, `objectRequestPath(bucket:key:) -> String`, `copySourceHeader(bucket:key:) -> String`, `parseHead(statusCode:contentLength:etag:key:) throws -> S3ObjectHead?`, `copyObjectSucceeded(statusCode:body:) -> Bool`
  - `func headObject(config:key:) async throws -> S3ObjectHead?`, `func copyObject(config:from:to:) async throws`, `func listObjects(config:prefix:) async throws -> [S3ObjectInfo]`, `func replaceObjectForRepair(config:key:withFileAt:) async throws`

**Cosa NON cambia:** le nove chiamate esistenti a `sign` (lista, PUT, multipart, abort, GET, raggiungibilità) passano gli stessi argomenti di prima e ricevono la stessa firma (`testListRequest_isSignedAsBefore`, valore calcolato a parte); `upload`/`put`/`multipart` non si toccano; `shouldUpload` (BUG-3) resta l'unica regola del backup: `replaceObjectForRepair` non è raggiungibile da nessun job.

**Perché `x-amz-copy-source` va firmata e il percorso va passato a mano.** S3 rifiuta una richiesta con un'intestazione `x-amz-*` presente ma non firmata. E `sign` oggi ricalcola il percorso canonico da `url.path`, cioè lo decodifica e lo ricodifica con un insieme di caratteri diverso da quello con cui la richiesta è partita: per `+` e apostrofo i due testi divergono (la stessa famiglia di BUG-8). Le richieste nuove costruiscono il percorso una volta (`encodeKeyStrict`) e passano a `sign` lo stesso testo.

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/S3SignatureTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// La firma SigV4 (ROADMAP #45). La riparazione aggiunge due richieste nuove — HEAD e copia
/// lato server, con l'intestazione `x-amz-copy-source` firmata — e per farlo la firma e' stata
/// divisa: `S3Syncer.sigV4Signature` (pura) e `sign` (che costruisce la richiesta canonica).
///
/// Da dove vengono i valori attesi, perche' nessuno e' stato calcolato con questo codice:
/// - i primi tre sono gli esempi PUBBLICATI da AWS nella documentazione di S3 («Signature
///   Calculations for the Authorization Header», bucket `examplebucket`, 24/05/2013);
/// - gli altri sono stati calcolati con uno script python indipendente (`hmac`/`hashlib`), lo
///   stesso che riproduce esattamente i tre esempi di AWS, il 2026-10-04.
final class S3SignatureTests: XCTestCase {
    private let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    private let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let date = Date(timeIntervalSince1970: 1_791_115_200)   // 2026-10-04T12:00:00Z
    private let heic = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"

    private var config: S3Syncer.S3Config {
        S3Syncer.S3Config(accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: secret,
                          endpoint: "https://s3.it.cubbit.org", region: "auto", bucket: "backupfoto")
    }

    private func awsHeaders(_ extra: [String: String] = [:]) -> [String: String] {
        var h = ["host": "examplebucket.s3.amazonaws.com", "x-amz-content-sha256": empty,
                 "x-amz-date": "20130524T000000Z"]
        h.merge(extra) { $1 }
        return h
    }

    private func expected(_ signedHeaders: String, _ signature: String) -> String {
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261004/us-east-1/s3/aws4_request, "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    // MARK: - Esempi pubblicati da AWS

    func testAWSExample_getObjectWithRange() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/test.txt", canonicalQuery: "",
                                        headers: awsHeaders(["range": "bytes=0-9"]), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signedHeaders, "host;range;x-amz-content-sha256;x-amz-date")
        XCTAssertEqual(s.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testAWSExample_getBucketLifecycle() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/", canonicalQuery: "lifecycle=",
                                        headers: awsHeaders(), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signature, "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    func testAWSExample_listObjects() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/", canonicalQuery: "max-keys=2&prefix=J",
                                        headers: awsHeaders(), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signature, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    // MARK: - `sign`: le richieste di sempre non cambiano

    /// La lista con un token che contiene `+` (BUG-8): stessa firma di prima della divisione.
    func testListRequest_isSignedAsBefore() throws {
        var req = URLRequest(url: try XCTUnwrap(URL(string:
            "https://s3.it.cubbit.org/backupfoto?list-type=2&max-keys=1000&continuation-token=a%2Bb")))
        req.httpMethod = "GET"
        S3Syncer().sign(&req, config: config, body: Data(), date: date)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-date"), "20261004T120000Z")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-content-sha256"), empty)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "b3253f5a6b2934ddbe8e9b059fd4af56febab5635e4818d5cd9daeed908375a6"))
    }

    /// La lista con `prefix` costruita come `fetchListPageXML`: la `/` del prefisso entra
    /// nella firma come `%2F`.
    func testListWithPrefix_isSigned() throws {
        var comps = try XCTUnwrap(URLComponents(string: "https://s3.it.cubbit.org/backupfoto"))
        comps.queryItems = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "max-keys", value: "1000"),
                            URLQueryItem(name: "prefix", value: "_quarantena/")]
        comps.percentEncodedQuery = S3Syncer.encodePlusInQuery(comps.percentEncodedQuery)
        var req = URLRequest(url: try XCTUnwrap(comps.url))
        req.httpMethod = "GET"
        S3Syncer().sign(&req, config: config, body: Data(), date: date)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "d6197d250a3392491616ab933589414cfd124fc89e78e6f58fa1e5167e1e7ea0"))
    }

    // MARK: - Le richieste nuove

    func testHeadRequest_isSignedOnTheSamePathItSends() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: heic)
        XCTAssertEqual(path, "/backupfoto/Foto%20iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "HEAD"
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path)
        XCTAssertEqual(req.url?.absoluteString, "https://s3.it.cubbit.org" + path, "il percorso viaggia com'e' firmato")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "01a74f23090b90d4a69b97fa48e0216cc0c168e5c84c3212d1ac9cfe6f4fb095"))
    }

    /// La copia in quarantena: `x-amz-copy-source` viaggia nella richiesta ED e' firmata.
    func testCopyRequest_signsTheCopySource() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: "_quarantena/2026-10-04/" + heic)
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "PUT"
        let source = S3Syncer.copySourceHeader(bucket: "backupfoto", key: heic)
        XCTAssertEqual(source, "backupfoto/Foto%20iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path,
                        extraSignedHeaders: ["x-amz-copy-source": source])
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-copy-source"), source)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       expected("host;x-amz-content-sha256;x-amz-copy-source;x-amz-date",
                                "a4fb3b12bb2aff051c5fa6db6e516acd81ddc593e926d59fc16efeb0e6dc7b1f"))
    }

    /// `+`, apostrofo e lettere accentate (la famiglia di BUG-8): codificati una volta sola,
    /// uguali nella richiesta e nella firma.
    func testSpecialCharacters_areSignedAsSent() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: "Foto/l'isola+mare è.jpg")
        XCTAssertEqual(path, "/backupfoto/Foto/l%27isola%2Bmare%20%C3%A8.jpg")
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "HEAD"
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path)
        XCTAssertEqual(req.url?.absoluteString, "https://s3.it.cubbit.org" + path)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "2a4a8165db747c973f5889fb4fdd66de7266cdb0432a51712298ec74203b4768"))
    }
}
```

e `AppBackupFotoTests/S3RepairRequestsTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Le parti pure delle richieste della riparazione (ROADMAP #45): la codifica delle chiavi e
/// come si leggono le risposte di HEAD e della copia lato server. Niente rete: la prova vera
/// su Cubbit e' l'ultimo task del piano.
final class S3RepairRequestsTests: XCTestCase {

    // MARK: - Codifica delle chiavi

    func testStrictEncoding_keepsOnlyTheUnreservedCharactersAndSlash() {
        XCTAssertEqual(S3Syncer.encodeKeyStrict("Foto iPhone/3/A-B_c.d~e.heic"), "Foto%20iPhone/3/A-B_c.d~e.heic")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("a+b"), "a%2Bb", "il + di BUG-8")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("l'isola"), "l%27isola", "l'apostrofo di BUG-8")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("è"), "%C3%A8", "UTF-8 byte per byte")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("100%"), "100%25", "il % stesso, una volta sola")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("a&b=c?d#e"), "a%26b%3Dc%3Fd%23e")
        XCTAssertEqual(S3Syncer.encodeKeyStrict(""), "")
    }

    /// NFC e NFD sono byte diversi e restano diversi: la chiave si manda esattamente come la
    /// lista di Cubbit l'ha data, senza normalizzarla.
    func testStrictEncoding_doesNotNormalizeUnicode() {
        XCTAssertEqual(S3Syncer.encodeKeyStrict("e\u{301}"), "e%CC%81")
        XCTAssertNotEqual(S3Syncer.encodeKeyStrict("e\u{301}"), S3Syncer.encodeKeyStrict("\u{e9}"))
    }

    func testCopySource_hasNoLeadingSlash_andTheSameEncoding() {
        XCTAssertEqual(S3Syncer.copySourceHeader(bucket: "backupfoto", key: "Foto/l'isola+mare.jpg"),
                       "backupfoto/Foto/l%27isola%2Bmare.jpg")
    }

    // MARK: - HEAD

    func testHead_200_givesSizeAndETag() throws {
        let head = try S3Syncer.parseHead(statusCode: 200, contentLength: "2463629",
                                          etag: "\"24cb65338294b62644feec09251bd6ac\"", key: "k")
        XCTAssertEqual(head, S3Syncer.S3ObjectHead(size: 2_463_629, etag: "\"24cb65338294b62644feec09251bd6ac\""))
    }

    func testHead_404_isAMissingObject() throws {
        XCTAssertNil(try S3Syncer.parseHead(statusCode: 404, contentLength: nil, etag: nil, key: "k"))
    }

    /// Un 403 o un 500 non dicono niente sull'oggetto: mai «non c'e'».
    func testHead_otherStatuses_areErrors_neverAMissingObject() {
        for code in [301, 400, 403, 500, 503] {
            XCTAssertThrowsError(try S3Syncer.parseHead(statusCode: code, contentLength: "1", etag: "\"x\"", key: "k"),
                                 "\(code)")
        }
    }

    func testHead_withoutAReadableSize_isAnError() {
        for length in [nil, "", "abc", "-1"] {
            XCTAssertThrowsError(try S3Syncer.parseHead(statusCode: 200, contentLength: length, etag: "\"x\"", key: "k"),
                                 String(describing: length))
        }
    }

    func testHead_withoutETag_isStillAnObject_withoutETag() throws {
        XCTAssertEqual(try S3Syncer.parseHead(statusCode: 200, contentLength: "0", etag: nil, key: "k"),
                       S3Syncer.S3ObjectHead(size: 0, etag: nil))
    }

    // MARK: - Copia lato server

    func testCopy_succeedsOnlyWithAResultInTheBody() {
        let ok = "<?xml version=\"1.0\"?><CopyObjectResult><ETag>&quot;24cb&quot;</ETag></CopyObjectResult>"
        XCTAssertTrue(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ok))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: "<Error><Code>InternalError</Code></Error>"),
                       "S3 puo' rispondere 200 e mettere l'errore nel corpo")
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ""))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 403, body: ok))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ok + "<Error></Error>"))
    }
}
```

Registrali nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh S3SignatureTests` → `COMPILAZIONE TEST FALLITA` con `type 'S3Syncer' has no member 'sigV4Signature'` (e `'sign' is inaccessible due to 'private' protection level`).

- [ ] **Step 3: implementa.** Cinque sostituzioni.

**3a. `sign`, la testa: `internal`, i due parametri, le intestazioni in più, il percorso passato a mano.**

Trova (deve comparire **una sola volta**):

```swift
    // MARK: - AWS Signature V4
    private func sign(_ request: inout URLRequest, config: S3Config, body: Data, date: Date) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")!
        let datetime = fmt.string(from: date)
        let dateOnly = String(datetime.prefix(8))
        let region = config.region == "auto" ? "us-east-1" : config.region
        guard let host = URL(string: config.endpoint)?.host else { return }

        request.setValue(datetime, forHTTPHeaderField: "x-amz-date")
        let payHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        request.setValue(payHash, forHTTPHeaderField: "x-amz-content-sha256")

        let headerVals: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payHash,
            "x-amz-date": datetime
        ]
        let signedNames = headerVals.keys.sorted()
        let canonH = signedNames.map { "\($0):\(headerVals[$0]!)" }.joined(separator: "\n") + "\n"
        let signedH = signedNames.joined(separator: ";")

        let rawPath = request.url?.path ?? "/"
        let s3PathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~/"))
        let uri = rawPath.addingPercentEncoding(withAllowedCharacters: s3PathAllowed) ?? rawPath
```

Sostituisci con:

```swift
    // MARK: - AWS Signature V4

    /// Firma una richiesta. `internal` e non piu' `private` (ROADMAP #45) solo perche'
    /// `S3SignatureTests` possa bloccare la firma di una richiesta di lista con un valore
    /// calcolato a parte; nessun chiamante nuovo fuori da questa classe.
    ///
    /// Due parametri nuovi, entrambi con un default che lascia la firma di oggi IDENTICA per
    /// tutte le richieste esistenti:
    /// - `canonicalURI`: il percorso esattamente come viaggia nella richiesta. Le richieste
    ///   della riparazione (HEAD, copia) costruiscono il percorso con `encodeKeyStrict`; senza
    ///   questo parametro la firma ricalcolerebbe il percorso da `url.path` con una codifica
    ///   diversa per `+`, apostrofo e lettere accentate (la stessa famiglia di BUG-8).
    /// - `extraSignedHeaders`: intestazioni `x-amz-*` in piu', impostate sulla richiesta E
    ///   firmate. `x-amz-copy-source` della copia lato server va firmata: S3 rifiuta le
    ///   intestazioni `x-amz-*` presenti ma non firmate.
    func sign(_ request: inout URLRequest, config: S3Config, body: Data, date: Date,
              canonicalURI: String? = nil, extraSignedHeaders: [String: String] = [:]) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")!
        let datetime = fmt.string(from: date)
        let dateOnly = String(datetime.prefix(8))
        let region = config.region == "auto" ? "us-east-1" : config.region
        guard let host = URL(string: config.endpoint)?.host else { return }

        request.setValue(datetime, forHTTPHeaderField: "x-amz-date")
        let payHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        request.setValue(payHash, forHTTPHeaderField: "x-amz-content-sha256")

        var headerVals: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payHash,
            "x-amz-date": datetime
        ]
        for (name, value) in extraSignedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
            headerVals[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }

        let uri: String
        if let canonicalURI {
            uri = canonicalURI
        } else {
            let rawPath = request.url?.path ?? "/"
            let s3PathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~/"))
            uri = rawPath.addingPercentEncoding(withAllowedCharacters: s3PathAllowed) ?? rawPath
        }
```

**3b. `sign`, la coda: il cuore SigV4 diventa `sigV4Signature`.** Le operazioni sono le stesse, nello stesso ordine; cambia solo dove stanno.

Trova (deve comparire **una sola volta**):

```swift
        let sortedQuery = queryParams.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let canonReq = [request.httpMethod ?? "GET", uri, sortedQuery, canonH, signedH, payHash]
            .joined(separator: "\n")

        let credScope = "\(dateOnly)/\(region)/s3/aws4_request"
        let reqHash = SHA256.hash(data: Data(canonReq.utf8)).map { String(format: "%02x", $0) }.joined()
        let s2s = "AWS4-HMAC-SHA256\n\(datetime)\n\(credScope)\n\(reqHash)"

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let sigKey = hmac(hmac(hmac(hmac(Data(("AWS4" + config.secretAccessKey).utf8),
            dateOnly), region), "s3"), "aws4_request")
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(s2s.utf8),
            using: SymmetricKey(data: sigKey))).map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(credScope), " +
            "SignedHeaders=\(signedH), Signature=\(sig)",
            forHTTPHeaderField: "Authorization")
    }
```

Sostituisci con:

```swift
        let sortedQuery = queryParams.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let signed = Self.sigV4Signature(method: request.httpMethod ?? "GET", canonicalURI: uri,
                                         canonicalQuery: sortedQuery, headers: headerVals,
                                         payloadHash: payHash, amzDate: datetime,
                                         secretAccessKey: config.secretAccessKey, region: region)
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(dateOnly)/\(region)/s3/aws4_request, " +
            "SignedHeaders=\(signed.signedHeaders), Signature=\(signed.signature)",
            forHTTPHeaderField: "Authorization")
    }

    /// Il cuore di SigV4, PURO: dalla richiesta canonica alla firma. Estratto da `sign` il
    /// 2026-10 (ROADMAP #45) con le stesse identiche operazioni, per poterlo provare con i
    /// valori pubblicati da AWS (`S3SignatureTests`) prima di mandare a Cubbit la prima copia
    /// lato server. `headers`: nomi gia' in minuscolo, valori gia' ripuliti.
    // `nonisolated`: pura.
    nonisolated static func sigV4Signature(method: String, canonicalURI: String, canonicalQuery: String,
                                           headers: [String: String], payloadHash: String, amzDate: String,
                                           secretAccessKey: String, region: String)
        -> (signedHeaders: String, signature: String) {
        let signedNames = headers.keys.sorted()
        let canonH = signedNames.map { "\($0):\(headers[$0]!)" }.joined(separator: "\n") + "\n"
        let signedH = signedNames.joined(separator: ";")
        let canonReq = [method, canonicalURI, canonicalQuery, canonH, signedH, payloadHash]
            .joined(separator: "\n")
        let dateOnly = String(amzDate.prefix(8))
        let credScope = "\(dateOnly)/\(region)/s3/aws4_request"
        let reqHash = SHA256.hash(data: Data(canonReq.utf8)).map { String(format: "%02x", $0) }.joined()
        let s2s = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credScope)\n\(reqHash)"

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let sigKey = hmac(hmac(hmac(hmac(Data(("AWS4" + secretAccessKey).utf8),
            dateOnly), region), "s3"), "aws4_request")
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(s2s.utf8),
            using: SymmetricKey(data: sigKey))).map { String(format: "%02x", $0) }.joined()
        return (signedH, sig)
    }
```

**3c. `fetchListPageXML`: il prefisso.**

Trova (deve comparire **una sola volta**):

```swift
    func fetchListPageXML(config: S3Config, token: String?) async throws -> String {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
```

Sostituisci con:

```swift
    /// `prefix` (ROADMAP #45, default `nil` = la richiesta di sempre): la riparazione elenca
    /// solo `_quarantena/` per sapere se una copia rovinata e' gia' stata messa da parte.
    func fetchListPageXML(config: S3Config, token: String?, prefix: String? = nil) async throws -> String {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        if let prefix { qi.append(URLQueryItem(name: "prefix", value: prefix)) }
```

**3d. `S3ObjectHead`.**

Trova (deve comparire **una sola volta**):

```swift
    /// Una pagina di `ListObjectsV2` letta oggetto per oggetto.
    nonisolated struct S3ListPage: Equatable, Sendable {
```

Sostituisci con:

```swift
    /// Dimensione ed ETag di un oggetto, letti con una HEAD (ROADMAP #45).
    nonisolated struct S3ObjectHead: Equatable, Sendable {
        let size: Int64
        /// Cosi' come arriva nell'intestazione (virgolette comprese); `nil` se manca.
        let etag: String?
    }

    /// Una pagina di `ListObjectsV2` letta oggetto per oggetto.
    nonisolated struct S3ListPage: Equatable, Sendable {
```

**3e. Le richieste della riparazione**, subito prima di `// MARK: - AWS Signature V4`.

Trova (deve comparire **una sola volta**):

```swift
    // MARK: - AWS Signature V4
```

Sostituisci con:

```swift
    // MARK: - Richieste della riparazione (ROADMAP #45, ADR-0016)
    //
    // HEAD (sola lettura), copia lato server (in quarantena) e la sola sovrascrittura del
    // progetto. Le chiavi viaggiano codificate con `encodeKeyStrict` e la firma riceve lo
    // stesso identico percorso (`canonicalURI`): niente doppie codifiche diverse fra cio' che
    // si manda e cio' che si firma, la classe di errore di BUG-8.

    /// Codifica di una chiave (o del nome del bucket) per il percorso di una richiesta e per
    /// `x-amz-copy-source`: tutto tranne `A-Z a-z 0-9 - _ . ~` e `/`, byte per byte in UTF-8.
    /// `+` diventa `%2B` (in un percorso Cubbit potrebbe leggerlo come spazio), l'apostrofo
    /// `%27`, `è` `%C3%A8`. E' la codifica che SigV4 si aspetta per il percorso canonico.
    // `nonisolated`: pura.
    nonisolated static func encodeKeyStrict(_ key: String) -> String {
        var out = ""
        for byte in key.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E, 0x2F:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Il percorso di un oggetto, `/<bucket>/<chiave>`, codificato con `encodeKeyStrict`: lo
    /// stesso testo va nella richiesta e nella firma.
    nonisolated static func objectRequestPath(bucket: String, key: String) -> String {
        "/" + encodeKeyStrict(bucket) + "/" + encodeKeyStrict(key)
    }

    /// Il valore di `x-amz-copy-source`: `<bucket>/<chiave>` codificati, senza la barra
    /// iniziale — la forma che `rclone copyto` ha usato nella prova su Cubbit del 2026-10-04.
    nonisolated static func copySourceHeader(bucket: String, key: String) -> String {
        encodeKeyStrict(bucket) + "/" + encodeKeyStrict(key)
    }

    /// Come leggere la risposta a una HEAD: 404 = l'oggetto non c'e' (`nil`), 200 con una
    /// dimensione leggibile = l'oggetto, ogni altra cosa = errore (mai «non c'e'» per
    /// sbaglio: un 403 o un 500 non dicono niente sull'oggetto).
    nonisolated static func parseHead(statusCode: Int, contentLength: String?, etag: String?,
                                      key: String) throws -> S3ObjectHead? {
        if statusCode == 404 { return nil }
        guard statusCode == 200 else {
            throw S3HTTPError(statusCode: statusCode, message: "Errore HEAD \(key)")
        }
        guard let text = contentLength?.trimmingCharacters(in: .whitespaces),
              let size = Int64(text), size >= 0 else {
            throw S3HTTPError(statusCode: statusCode, message: "HEAD \(key) senza una dimensione leggibile")
        }
        return S3ObjectHead(size: size, etag: etag)
    }

    /// Una copia lato server e' riuscita solo se la risposta e' 2xx E il corpo e' un
    /// `<CopyObjectResult>`: S3 puo' rispondere 200 e mettere l'errore nel corpo.
    nonisolated static func copyObjectSucceeded(statusCode: Int, body: String) -> Bool {
        (200...299).contains(statusCode) && body.contains("<CopyObjectResult") && !body.contains("<Error>")
    }

    /// HEAD di un oggetto: dimensione ed ETag letti ADESSO da Cubbit (l'inventario e' una
    /// cache, ADR-0002). `nil` se l'oggetto non c'e'. Sola lettura.
    func headObject(config: S3Config, key: String) async throws -> S3ObjectHead? {
        let path = Self.objectRequestPath(bucket: config.bucket, key: key)
        guard let url = URL(string: config.endpoint + path) else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw S3HTTPError(statusCode: -1, message: "HEAD \(key): risposta non HTTP")
        }
        return try Self.parseHead(statusCode: http.statusCode,
                                  contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                                  etag: http.value(forHTTPHeaderField: "ETag"), key: key)
    }

    /// Copia lato server (`CopyObject`) di `sourceKey` in `destinationKey`, nello stesso
    /// bucket: la sorgente non viene toccata. La usa SOLO la riparazione, per mettere in
    /// quarantena la copia rovinata (ADR-0016); chi chiama ha gia' controllato con
    /// `headObject` che `destinationKey` non esista (zero-overwrite anche in quarantena).
    /// Provata su Cubbit il 2026-10-04 con `rclone copyto`: copia lato server, ETag identico.
    func copyObject(config: S3Config, from sourceKey: String, to destinationKey: String) async throws {
        let path = Self.objectRequestPath(bucket: config.bucket, key: destinationKey)
        guard let url = URL(string: config.endpoint + path) else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(destinationKey)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path,
             extraSignedHeaders: ["x-amz-copy-source": Self.copySourceHeader(bucket: config.bucket, key: sourceKey)])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        guard Self.copyObjectSucceeded(statusCode: code, body: body) else {
            throw S3HTTPError(statusCode: code, message: "Errore copia \(sourceKey): \(body.prefix(200))")
        }
    }

    /// Tutti gli oggetti sotto `prefix`, pagina dopo pagina. Lancia se la lista non arriva in
    /// fondo pulita: chi decide in base a cosa c'e' gia' in quarantena non deve leggere una
    /// lista a meta'.
    func listObjects(config: S3Config, prefix: String) async throws -> [S3ObjectInfo] {
        var out: [S3ObjectInfo] = []
        var token: String? = nil
        repeat {
            let page = Self.parseListPage(try await fetchListPageXML(config: config, token: token, prefix: prefix))
            guard page.malformedEntries == 0 else {
                throw S3HTTPError(statusCode: 200, message: "Lista di \(prefix) illeggibile")
            }
            out += page.objects
            if page.isTruncated {
                guard let next = page.nextToken else {
                    throw S3HTTPError(statusCode: 200, message: "Lista di \(prefix) troncata senza seguito")
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil
        return out
    }

    /// LA SOLA SOVRASCRITTURA SU CUBBIT DEL PROGETTO (ADR-0016): rimette al suo posto la copia
    /// buona di una foto la cui copia rovinata e' gia' in quarantena, verificata. Usa la stessa
    /// `upload` del backup (PUT unico fino a 64 MiB compresi, a pezzi sopra) con un gate tutto
    /// suo da uno slot. NON va chiamata da nessun'altra parte: il backup resta zero-overwrite
    /// (`shouldUpload`, BUG-3). Un'istanza dedicata di `S3Syncer`, mai quella dei job.
    func replaceObjectForRepair(config: S3Config, key: String, withFileAt url: URL) async throws {
        beginNewOperation()
        let gate = AdaptiveUploadGate(startingLimit: 1, ceiling: 1)
        try await upload(url: url, key: key, config: config, gate: gate, onStart: {}, onStatus: { _ in })
    }

    // MARK: - AWS Signature V4
```

- [ ] **Step 4: esegui i test.** `fasttest.sh S3SignatureTests` → `Executed 8 tests, with 0 failures`; `fasttest.sh S3RepairRequestsTests` → `Executed 9 tests, with 0 failures`; `fasttest.sh S3ListSpecialCharsTests` → invariato, 0 fallimenti.
- [ ] **Step 5:** `fasttest.sh`: `Executed 1050 tests` (B+27), 0 fallimenti, 0 warning.
- [ ] **Mutanti che devono morire:** in `sign`, togliere la riga `headerVals[name.lowercased()] = …` (verificato: muore `testCopyRequest_signsTheCopySource`); in `encodeKeyStrict` aggiungere `0x2B` (il `+`) ai caratteri lasciati in chiaro (muoiono `testStrictEncoding_…` e `testSpecialCharacters_areSignedAsSent`); in `parseHead` restituire `nil` per ogni stato diverso da 200 (muore `testHead_otherStatuses_areErrors_neverAMissingObject`).
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 2: HEAD, copia lato server firmata e sovrascrittura dedicata su Cubbit

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 3: le regole pure — quando una voce è riparabile, e dove va la quarantena

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R (subito prima di `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)`, riga 6614).
- Create: `AppBackupFotoTests/RepairRulesTests.swift` (`E3C9EBC30E095C631289A569` / `300DA1BAF6ECCD2BD27DCBCD`), `AppBackupFotoTests/RepairPathsTests.swift` (`309AE9683F23DFEF253FB1FA` / `737DA6D834924A1DF98041E7`).

**Interfaces:**
- Consumes: `InventorySnapshot`/`InventoryLocalFile`/`InventoryS3Object`/`InventoryArchive` (#44), `ContentDigest`, `S3ETag.parse`, `S3ETagMatcher.verdict`/`Candidate`, `normalizedIndexKey`, `LibraryExclusions` (T1), `S3Syncer.encodeKeyStrict` (T2).
- Produces:
  - `nonisolated enum RepairPaths { static var quarantineFolder: String; static var defaultCalendar: Calendar; static func dayFolder(for:calendar:) -> String; static func safeComponents(_:) -> [String]?; static func quarantinePath(for:date:calendar:) -> String?; static func stagingPath(for:date:calendar:token:) -> String?; static func isQuarantineCopy(_:of:) -> Bool }`
  - `nonisolated struct RepairCandidate: Equatable, Sendable, Identifiable { key, target, source, witness, paths: [InventoryArchive: String], good: ContentDigest, badSize: Int64, badSHA256: String?, badETag: String?; var id: String { key } }`
  - `nonisolated enum RepairRules { static func source(forTarget:) -> InventoryArchive; static func witness(forTarget:) -> InventoryArchive; static func expectedCubbitETag(for:) -> String; static func normalizedETag(_:) -> String?; static func cubbitKeyIsRepairable(_:) -> Bool; static func candidates(in:) -> [RepairCandidate] }`

**Il caso vero, come lo vedono queste regole.** Nell'inventario la `.heic` ha su SSD e HDD lo stesso SHA256 e l'MD5 `b59917c9…0d13a`; su Cubbit l'ETag `"24cb65338294b62644feec09251bd6ac"` (parte unica: è l'MD5 del contenuto rovinato). `candidates` produce un `RepairCandidate` con `target = .s3`, `source = .ssd`, `witness = .hdd`. L'inventario, che ragiona per contenuto, mette invece **due** voci in ❗ (la copia buona e quella diversa, `samePathDifferentContent`): per questo le voci riparabili sono un elenco a parte (S7).

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/RepairRulesTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `RepairRules` (ROADMAP #45, ADR-0016): quando una voce dell'inventario si puo' riparare,
/// quale archivio e' la minoranza, da dove si copia. Ogni condizione della spec («Quando una
/// foto e' riparabile») ha qui almeno un test, e ogni «in ogni altro caso no» il suo.
///
/// Stessa convenzione di `InventoryClassifierTests`: il contenuto «X» ha SHA256 "sha-X" e MD5
/// fatto di 32 volte la lettera minuscola di X; un oggetto Cubbit con quell'MD5 come ETag e'
/// la stessa foto.
final class RepairRulesTests: XCTestCase {
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func digest(_ c: Character, size: Int64 = 10, multipart: String? = nil) -> ContentDigest {
        ContentDigest(size: size, sha256: "sha-\(c)", md5: md5(c), multipartETag: multipart)
    }

    private func file(_ p: String, _ c: Character, size: Int64 = 10, status: InventoryReadStatus = .ok,
                      digestSize: Int64? = nil, multipart: String? = nil) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(p), displayPath: p, size: size, mtime: 1, status: status,
                           digest: status == .ok ? digest(c, size: digestSize ?? size, multipart: multipart) : nil,
                           hashedAt: 2)
    }

    private func object(_ k: String, etag: String?, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(k), displayKey: k, size: size, etag: etag)
    }

    private func object(_ k: String, _ c: Character, size: Int64 = 10) -> InventoryS3Object {
        object(k, etag: "\"\(md5(c))\"", size: size)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true) -> [InventoryArchive: InventoryArchiveState] {
        func st(_ a: InventoryArchive, _ c: Bool) -> InventoryArchiveState {
            InventoryArchiveState(archive: a, runId: 1, complete: c, reason: c ? nil : .interrupted,
                                  unreadable: 0, startedAt: 0, finishedAt: 1)
        }
        return [.ssd: st(.ssd, ssd), .hdd: st(.hdd, hdd), .s3: st(.s3, s3)]
    }

    private func candidates(ssd: [InventoryLocalFile], hdd: [InventoryLocalFile], s3: [InventoryS3Object],
                            states: [InventoryArchive: InventoryArchiveState]? = nil) -> [RepairCandidate] {
        RepairRules.candidates(in: InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states ?? self.states()))
    }

    // MARK: - Il caso vero: rovinata su Cubbit

    /// La `.heic` del 2026-10-01: integra e identica su SSD e HDD, su Cubbit stessa dimensione
    /// ma contenuto diverso (ETag a parte unica = MD5 diverso).
    func testBrokenOnCubbit_isRepairedFromTheSSD_withTheHDDAsWitness() throws {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "b")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(only.key, normalizedIndexKey(path))
        XCTAssertEqual(only.target, .s3)
        XCTAssertEqual(only.source, .ssd)
        XCTAssertEqual(only.witness, .hdd)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSize, 10)
        XCTAssertEqual(only.badETag, "\"\(md5("b"))\"")
        XCTAssertNil(only.badSHA256)
        XCTAssertEqual(only.paths, [.ssd: path, .hdd: path, .s3: path])
    }

    /// Su Cubbit la dimensione diversa non cambia niente: l'MD5 diverso basta a dimostrare che
    /// il contenuto e' un altro.
    func testBrokenOnCubbit_withADifferentSize_isStillRepairable() {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "b", size: 7)])
        XCTAssertEqual(c.map(\.target), [.s3])
        XCTAssertEqual(c.first?.badSize, 7)
    }

    /// Il percorso su Cubbit si porta con le maiuscole vere; la chiave e' quella normalizzata.
    func testPaths_keepTheRealCaseOfEachArchive() {
        let c = candidates(ssd: [file("Foto/IMG_1.JPG", "a")], hdd: [file("foto/img_1.jpg", "a")],
                           s3: [object("Foto/IMG_1.JPG", "b")])
        XCTAssertEqual(c.first?.paths, [.ssd: "Foto/IMG_1.JPG", .hdd: "foto/img_1.jpg", .s3: "Foto/IMG_1.JPG"])
    }

    // MARK: - Rovinata su un disco

    func testBrokenOnTheHDD_isRepairedFromTheSSD_withCubbitAsWitness() throws {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "b")], s3: [object(path, "a")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(only.target, .hdd)
        XCTAssertEqual(only.source, .ssd)
        XCTAssertEqual(only.witness, .s3)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSHA256, "sha-b")
        XCTAssertNil(only.badETag)
    }

    /// Decisione 2 di Enrico: si ripara anche l'SSD, con la stessa regola — dall'HDD.
    func testBrokenOnTheSSD_isRepairedFromTheHDD_withCubbitAsWitness() throws {
        let c = candidates(ssd: [file(path, "b")], hdd: [file(path, "a")], s3: [object(path, "a")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(only.target, .ssd)
        XCTAssertEqual(only.source, .hdd)
        XCTAssertEqual(only.witness, .s3)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSHA256, "sha-b")
    }

    /// Cubbit certifica anche con l'ETag a pezzi (qui finto, ma nella forma giusta).
    func testCubbitCertifyingWithAMultipartETag_canBeTheWitness() {
        let etag = "\(md5("c"))-2"
        let c = candidates(ssd: [file(path, "a", multipart: etag)], hdd: [file(path, "b")],
                           s3: [object(path, etag: "\"\(etag)\"")])
        XCTAssertEqual(c.map(\.target), [.hdd])
    }

    // MARK: - In ogni altro caso no

    func testAllThreeAgree_isNothingToRepair() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "a")]).isEmpty)
    }

    func testThreeDifferentContents_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "b")], s3: [object(path, "c")]).isEmpty)
    }

    /// Incompleto non e' assente (ADR-0015): con un archivio letto a meta' non si ripara
    /// niente, nemmeno quello che sembrerebbe chiarissimo.
    func testAnyArchiveIncomplete_blocksEveryRepair() {
        let ssd = [file(path, "a")], hdd = [file(path, "a")], s3 = [object(path, "b")]
        for st in [states(ssd: false), states(hdd: false), states(s3: false)] {
            XCTAssertTrue(candidates(ssd: ssd, hdd: hdd, s3: s3, states: st).isEmpty)
        }
        XCTAssertTrue(candidates(ssd: ssd, hdd: hdd, s3: s3, states: [:]).isEmpty, "mai letto")
    }

    func testPathMissingFromOneArchive_isNotRepairable() {
        let a = file(path, "a"), o = object(path, "b")
        XCTAssertTrue(candidates(ssd: [], hdd: [a], s3: [o]).isEmpty)
        XCTAssertTrue(candidates(ssd: [a], hdd: [], s3: [o]).isEmpty)
        XCTAssertTrue(candidates(ssd: [a], hdd: [a], s3: []).isEmpty)
    }

    func testCubbitETagInAnUnknownFormat_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, etag: "\"boh\"")]).isEmpty)
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, etag: nil)]).isEmpty)
    }

    /// Un ETag a pezzi che non torna NON dimostra un contenuto diverso (parti di altra
    /// dimensione): la voce resta in ❗ senza «Ripara…».
    func testCubbitMultipartETagThatDoesNotMatch_isNotProofOfDamage() {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")],
                           s3: [object(path, etag: "\"\(md5("b"))-3\"")])
        XCTAssertTrue(c.isEmpty)
    }

    /// SSD e HDD diversi e Cubbit che non certifica nessuno dei due: tre contenuti, nessuna
    /// maggioranza.
    func testDisksDisagree_andCubbitCertifiesNeither_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "b")],
                                 s3: [object(path, etag: "\"\(md5("a"))-2\"")]).isEmpty)
    }

    /// Due file con lo stesso percorso a meno delle maiuscole dentro un archivio: quale dei
    /// due e' «la» copia? Non si sceglie.
    func testCaseCollisionInsideOneArchive_isNotRepairable() {
        let c = candidates(ssd: [file("Foto/A.jpg", "a")], hdd: [file("Foto/A.jpg", "b"), file("Foto/a.jpg", "a")],
                           s3: [object("Foto/A.jpg", "a")])
        XCTAssertTrue(c.isEmpty)
    }

    func testUnreadableLocalCopy_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a", status: .unreadable)],
                                 s3: [object(path, "b")]).isEmpty)
        XCTAssertTrue(candidates(ssd: [file(path, "a", status: .changedWhileReading)], hdd: [file(path, "a")],
                                 s3: [object(path, "b")]).isEmpty)
    }

    /// La dimensione della copia buona deve essere la stessa letta dal disco.
    func testGoodCopyWhoseSizeDoesNotMatchItsFile_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a", digestSize: 11)], hdd: [file(path, "a")],
                                 s3: [object(path, "b")]).isEmpty)
    }

    /// Su Cubbit si sovrascrive solo dove la richiesta di caricamento e quelle nuove mandano
    /// lo stesso percorso.
    func testCubbitKeyWithPlusOrApostrophe_isNotRepairedOnCubbit() {
        for p in ["Foto/a+b.jpg", "Foto/l'isola.jpg", "Foto/a&b.jpg"] {
            XCTAssertTrue(candidates(ssd: [file(p, "a")], hdd: [file(p, "a")], s3: [object(p, "b")]).isEmpty, p)
        }
    }

    /// Sui dischi lo stesso nome si ripara: a Cubbit si chiede solo una HEAD.
    func testDiskTargetWithPlusOrApostrophe_isRepairable() {
        let p = "Foto/l'isola+mare.jpg"
        XCTAssertEqual(candidates(ssd: [file(p, "a")], hdd: [file(p, "b")], s3: [object(p, "a")]).map(\.target), [.hdd])
    }

    func testPathsInsideTheQuarantine_areNeverCandidates() {
        let q = "_quarantena/2026-10-04/" + path
        XCTAssertTrue(candidates(ssd: [file(q, "a")], hdd: [file(q, "a")], s3: [object(q, "b")]).isEmpty)
    }

    func testSeveralCandidates_comeInPathOrder() {
        let c = candidates(ssd: [file("b.jpg", "a"), file("a.jpg", "c")], hdd: [file("b.jpg", "a"), file("a.jpg", "d")],
                           s3: [object("b.jpg", "e"), object("a.jpg", "c")])
        XCTAssertEqual(c.map(\.key), ["a.jpg", "b.jpg"])
        XCTAssertEqual(c.map(\.target), [.hdd, .s3])
    }

    // MARK: - Piccole regole

    func testSourceAndWitness_forEachTarget() {
        XCTAssertEqual(RepairRules.source(forTarget: .s3), .ssd)
        XCTAssertEqual(RepairRules.source(forTarget: .hdd), .ssd)
        XCTAssertEqual(RepairRules.source(forTarget: .ssd), .hdd)
        XCTAssertEqual(RepairRules.witness(forTarget: .s3), .hdd)
        XCTAssertEqual(RepairRules.witness(forTarget: .hdd), .s3)
        XCTAssertEqual(RepairRules.witness(forTarget: .ssd), .s3)
    }

    /// Dopo il caricamento: l'MD5 fino a 64 MiB compresi, l'ETag a pezzi sopra. La `.heic`:
    /// 2.463.629 byte, caricamento unico, ETag atteso `b59917c9c6e38fccab5ce3f30c90d13a`.
    func testExpectedCubbitETag() {
        XCTAssertEqual(RepairRules.expectedCubbitETag(for: ContentDigest(size: 2_463_629, sha256: "s",
                       md5: "b59917c9c6e38fccab5ce3f30c90d13a", multipartETag: nil)), "b59917c9c6e38fccab5ce3f30c90d13a")
        XCTAssertEqual(RepairRules.expectedCubbitETag(for: digest("a", size: 70_000_000, multipart: "\(md5("c"))-2")),
                       "\(md5("c"))-2")
    }

    func testNormalizedETag() {
        XCTAssertEqual(RepairRules.normalizedETag("\"24CB65338294B62644FEEC09251BD6AC\" "), "24cb65338294b62644feec09251bd6ac")
        XCTAssertEqual(RepairRules.normalizedETag("abc-2"), "abc-2")
        XCTAssertNil(RepairRules.normalizedETag(nil))
        XCTAssertNil(RepairRules.normalizedETag(""))
        XCTAssertNil(RepairRules.normalizedETag("\"\""))
    }

    func testCubbitKeyIsRepairable() {
        XCTAssertTrue(RepairRules.cubbitKeyIsRepairable(path))
        XCTAssertTrue(RepairRules.cubbitKeyIsRepairable("Foto/Città è.jpg"), "fuori dall'ASCII le codifiche coincidono")
        for k in ["a+b.jpg", "l'isola.jpg", "a&b.jpg", "a=b.jpg", "a(1).jpg", "a@b.jpg"] {
            XCTAssertFalse(RepairRules.cubbitKeyIsRepairable(k), k)
        }
    }
}
```

e `AppBackupFotoTests/RepairPathsTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// `RepairPaths` (ROADMAP #45, ADR-0016): dove va la copia rovinata e dove si prepara quella
/// buona. Stessa chiave relativa, caratteri speciali compresi, mai un'uscita dalla cartella.
final class RepairPathsTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    /// 2026-10-03T22:30:00Z: a Roma (UTC+2) e' gia' il 4 ottobre.
    private let lateEvening = Date(timeIntervalSince1970: 1_791_066_600)

    func testQuarantineFolder_isTheExcludedOne() {
        XCTAssertEqual(RepairPaths.quarantineFolder, LibraryExclusions.quarantineFolderName,
                       "la riparazione deve scrivere proprio nella cartella che tutti escludono")
    }

    func testDayFolder_isTheLocalDay() {
        XCTAssertEqual(RepairPaths.dayFolder(for: lateEvening, calendar: calendar("Europe/Rome")), "2026-10-04")
        XCTAssertEqual(RepairPaths.dayFolder(for: lateEvening, calendar: calendar("UTC")), "2026-10-03")
        XCTAssertEqual(RepairPaths.dayFolder(for: Date(timeIntervalSince1970: 0), calendar: calendar("UTC")), "1970-01-01")
    }

    func testDefaultCalendar_isGregorianInTheMacTimeZone() {
        XCTAssertEqual(RepairPaths.defaultCalendar.identifier, .gregorian)
        XCTAssertEqual(RepairPaths.defaultCalendar.timeZone, TimeZone.current)
    }

    func testQuarantinePath_keepsTheSameRelativePath() {
        let rome = calendar("Europe/Rome")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic",
                                                  date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "Foto/l'isola+mare è.jpg", date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/Foto/l'isola+mare è.jpg", "+ e apostrofo restano come sono")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "a.jpg", date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/a.jpg")
    }

    func testUnsafePaths_areRefused() {
        let rome = calendar("Europe/Rome")
        for bad in ["", "/assoluto.jpg", "../fuori.jpg", "Foto/../../fuori.jpg", "Foto/./a.jpg", "Foto//a.jpg",
                    "Foto/", ".", "..", "_quarantena/2026-10-04/a.jpg", "_Quarantena/a.jpg"] {
            XCTAssertNil(RepairPaths.quarantinePath(for: bad, date: lateEvening, calendar: rome), bad)
            XCTAssertNil(RepairPaths.safeComponents(bad), bad)
        }
        XCTAssertEqual(RepairPaths.safeComponents("Foto/..a/b..jpg"), ["Foto", "..a", "b..jpg"],
                       "i punti dentro un nome non sono un'uscita")
    }

    func testStagingPath_sitsNextToTheQuarantineCopy() {
        let rome = calendar("Europe/Rome")
        XCTAssertEqual(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: "1a2b3c4d"),
                       "_quarantena/2026-10-04/Foto/a.jpg.in-arrivo-1a2b3c4d")
        XCTAssertNil(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: ""))
        XCTAssertNil(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: "../x"))
        XCTAssertNil(RepairPaths.stagingPath(for: "../a.jpg", date: lateEvening, calendar: rome, token: "ab"))
    }

    /// Quarantena idempotente: una copia messa da parte un altro giorno vale.
    func testQuarantineCopy_isRecognizedOnAnyDay() {
        let rel = "Foto iPhone/3/X.heic"
        XCTAssertTrue(RepairPaths.isQuarantineCopy("_quarantena/2026-10-04/Foto iPhone/3/X.heic", of: rel))
        XCTAssertTrue(RepairPaths.isQuarantineCopy("_quarantena/2027-01-31/Foto iPhone/3/X.heic", of: rel))
        for other in ["_quarantena/2026-10-4/Foto iPhone/3/X.heic", "_quarantena/oggi/Foto iPhone/3/X.heic",
                      "_quarantena/2026-10-04/altro/Foto iPhone/3/X.heic",
                      "_quarantena/2026-10-04/Foto iPhone/3/X.heic.in-arrivo-ab",
                      "_quarantena/2026-10-04/foto iphone/3/x.heic", "Foto iPhone/3/X.heic",
                      "_quarantena/Foto iPhone/3/X.heic", "_quarantena/2026-10-04"] {
            XCTAssertFalse(RepairPaths.isQuarantineCopy(other, of: rel), other)
        }
    }
}
```

Registrali nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh RepairRulesTests` → `COMPILAZIONE TEST FALLITA` con `cannot find 'RepairRules' in scope`.

- [ ] **Step 3: implementa.**

Inserisci **subito prima** della riga `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (si trova con `grep -n "MARK: - Testi e regole della card" AppBackupFoto/ContentView.swift`):

```swift
// MARK: - Riparazione con la regola «2 su 3»: le regole pure (ROADMAP #45, ADR-0016)

/// Dove la riparazione mette le copie, come percorsi RELATIVI alla radice di un archivio (SSD,
/// HDD) o come chiavi di Cubbit. Logica pura: nessun disco, nessuna rete.
// `nonisolated`: pura, chiamata dal motore della riparazione fuori dal main.
nonisolated enum RepairPaths {
    /// Lo stesso nome che backup, elenco, inventario e ripristino escludono (una fonte sola).
    static var quarantineFolder: String { LibraryExclusions.quarantineFolderName }

    /// Il calendario dei nomi delle cartelle per giorno: gregoriano, nel fuso del Mac.
    static var defaultCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// `AAAA-MM-GG` del giorno di `date` nel calendario dato.
    static func dayFolder(for date: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// Le componenti di un percorso relativo, o `nil` se non e' sicuro da usare: vuoto,
    /// assoluto, con componenti vuote, `.` o `..` (uscirebbe dalla cartella), oppure gia'
    /// dentro la quarantena (non si mette in quarantena una quarantena).
    static func safeComponents(_ relative: String) -> [String]? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !LibraryExclusions.isQuarantineName(parts[0]) else { return nil }
        return parts
    }

    /// `_quarantena/<AAAA-MM-GG>/<percorso originale>`: stessa chiave relativa, caratteri
    /// speciali compresi, sullo stesso archivio. `nil` se il percorso non e' sicuro.
    static func quarantinePath(for relative: String, date: Date, calendar: Calendar) -> String? {
        guard safeComponents(relative) != nil else { return nil }
        return quarantineFolder + "/" + dayFolder(for: date, calendar: calendar) + "/" + relative
    }

    /// Dove si prepara la copia buona prima di metterla al suo posto (solo SSD e HDD): accanto
    /// alla copia in quarantena, con un suffisso unico. Se la riparazione si ferma prima della
    /// fine, quello che resta sta dentro la quarantena (che nessuno legge) e non va cancellato.
    static func stagingPath(for relative: String, date: Date, calendar: Calendar, token: String) -> String? {
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }),
              let q = quarantinePath(for: relative, date: date, calendar: calendar) else { return nil }
        return q + ".in-arrivo-" + token
    }

    /// Vero se `key` e' `_quarantena/<un giorno qualsiasi>/<relative>`: serve alla quarantena
    /// IDEMPOTENTE su Cubbit (una copia messa da parte un altro giorno, per esempio dalla prova
    /// con `rclone` del 2026-10-04, vale come gia' fatta).
    static func isQuarantineCopy(_ key: String, of relative: String) -> Bool {
        let prefix = quarantineFolder + "/"
        guard key.hasPrefix(prefix) else { return false }
        let rest = key.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return isDayFolder(rest[..<slash]) && rest[rest.index(after: slash)...] == relative[...]
    }

    private static func isDayFolder(_ s: Substring) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}

/// Una foto rovinata in UN archivio, integra e identica negli altri due: si puo' riparare.
/// Viene dall'inventario, che e' una cache (ADR-0002): il motore ricontrolla tutto dal vivo.
nonisolated struct RepairCandidate: Equatable, Sendable, Identifiable {
    /// `normalizedIndexKey` del percorso: lo stesso nei tre archivi.
    let key: String
    /// La minoranza: l'archivio con la copia diversa.
    let target: InventoryArchive
    /// Da dove si copia: sempre un file locale — l'SSD per riparare HDD o Cubbit, l'HDD per
    /// riparare l'SSD.
    let source: InventoryArchive
    /// La seconda copia buona, che deve coincidere anche lei al ricontrollo.
    let witness: InventoryArchive
    /// Il percorso com'e' scritto in ciascun archivio (su Cubbit con le maiuscole vere).
    let paths: [InventoryArchive: String]
    /// Le impronte della copia buona, lette per intero nell'ultimo inventario.
    let good: ContentDigest
    /// Cosa l'inventario ha visto nella copia rovinata.
    let badSize: Int64
    /// Su SSD o HDD.
    let badSHA256: String?
    /// Su Cubbit, cosi' come arriva dalla lista.
    let badETag: String?

    var id: String { key }
}

/// Quando una voce dell'inventario si puo' riparare. Logica PURA sul `InventorySnapshot`.
// `nonisolated`: pura, calcolata insieme al riepilogo dell'inventario fuori dal main.
nonisolated enum RepairRules {
    /// L'archivio da cui si copia per riparare `target`.
    static func source(forTarget target: InventoryArchive) -> InventoryArchive {
        target == .ssd ? .hdd : .ssd
    }

    /// La seconda copia buona per riparare `target`.
    static func witness(forTarget target: InventoryArchive) -> InventoryArchive {
        target == .s3 ? .hdd : .s3
    }

    /// L'ETag che Cubbit dara' alla copia buona dopo `S3Syncer.upload`: l'MD5 fino a 64 MiB
    /// compresi, l'ETag a pezzi da 64 MiB sopra (stessa soglia di `upload`).
    static func expectedCubbitETag(for good: ContentDigest) -> String {
        good.multipartETag ?? good.md5
    }

    /// Un ETag senza virgolette, spazi e maiuscole, per confrontarne due.
    static func normalizedETag(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        return s.isEmpty ? nil : s
    }

    /// Una chiave di Cubbit si puo' riparare solo se il caricamento (che usa la codifica di
    /// sempre del backup, `.urlPathAllowed`) e le richieste nuove (HEAD e copia, con
    /// `encodeKeyStrict`) mandano lo STESSO percorso. Vale per lettere (accentate comprese:
    /// fuori dall'ASCII le due codifiche coincidono), cifre, spazi e `-_.~/` — la foto del
    /// 2026-10-01 compresa. Con `+`, apostrofo e gli altri segni che `.urlPathAllowed` lascia
    /// passare (`!$&'()*+,;=:@`) divergono, e la sovrascrittura potrebbe finire su una chiave
    /// diversa da quella controllata: quelle voci restano in ❗ finche' una prova dal vivo non
    /// le copre.
    static func cubbitKeyIsRepairable(_ key: String) -> Bool {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) == S3Syncer.encodeKeyStrict(key)
    }

    /// Le voci riparabili, in ordine di percorso. Le condizioni (spec, «Quando una foto e'
    /// riparabile»), tutte necessarie:
    /// - tutti e tre gli archivi COMPLETI nell'ultimo giro (incompleto non e' assente, ADR-0015);
    /// - lo stesso percorso, una sola volta, in ciascuno dei tre (una collisione di maiuscole
    ///   dentro un archivio non si ripara);
    /// - SSD e HDD letti per intero;
    /// - due archivi con lo stesso contenuto certificato e la stessa dimensione, il terzo con un
    ///   contenuto DIMOSTRATO diverso.
    ///
    /// «Dimostrato» su Cubbit vuol dire: un ETag a parte unica (e' l'MD5 del contenuto) diverso
    /// dall'MD5 della copia buona. Un ETag a pezzi che non torna non dimostra niente (potrebbe
    /// essere lo stesso contenuto caricato con parti di altra dimensione): la voce resta in ❗.
    static func candidates(in s: InventorySnapshot) -> [RepairCandidate] {
        guard InventoryArchive.allCases.allSatisfy({ s.isComplete($0) }) else { return [] }
        let ssd = Dictionary(grouping: s.ssd, by: \.key)
        let hdd = Dictionary(grouping: s.hdd, by: \.key)
        let s3 = Dictionary(grouping: s.s3, by: \.key)
        var out: [RepairCandidate] = []
        for (key, ssdRows) in ssd {
            guard !LibraryExclusions.isInsideQuarantine(relativePath: key),
                  ssdRows.count == 1, let hddRows = hdd[key], hddRows.count == 1,
                  let s3Rows = s3[key], s3Rows.count == 1 else { continue }
            let a = ssdRows[0], b = hddRows[0], o = s3Rows[0]
            guard a.status == .ok, b.status == .ok, let da = a.digest, let db = b.digest,
                  da.size == a.size, db.size == b.size else { continue }
            let paths: [InventoryArchive: String] = [.ssd: a.displayPath, .hdd: b.displayPath, .s3: o.displayKey]

            if da.sha256 == db.sha256 {
                // SSD e HDD d'accordo: Cubbit e' la minoranza solo se dimostrato diverso.
                guard case .singlePart(let md5) = S3ETag.parse(o.etag), md5 != da.md5,
                      cubbitKeyIsRepairable(o.displayKey) else { continue }
                out.append(RepairCandidate(key: key, target: .s3, source: .ssd, witness: .hdd, paths: paths,
                                           good: da, badSize: o.size, badSHA256: nil, badETag: o.etag))
                continue
            }
            // SSD e HDD diversi: decide Cubbit, solo se certifica uno dei due (stesso
            // confronto dell'inventario, `S3ETagMatcher`, fra i due contenuti in gioco).
            let both = [da, db].map {
                S3ETagMatcher.Candidate(size: $0.size, sha256: $0.sha256, md5: $0.md5,
                                        multipartETag: $0.multipartETag, alternativeETags: $0.alternativeMultipartETags)
            }
            guard case .certified(let sha) = S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: both) else {
                continue
            }
            if sha == da.sha256 && o.size == da.size {
                out.append(RepairCandidate(key: key, target: .hdd, source: .ssd, witness: .s3, paths: paths,
                                           good: da, badSize: b.size, badSHA256: db.sha256, badETag: nil))
            } else if sha == db.sha256 && o.size == db.size {
                out.append(RepairCandidate(key: key, target: .ssd, source: .hdd, witness: .s3, paths: paths,
                                           good: db, badSize: a.size, badSHA256: da.sha256, badETag: nil))
            }
        }
        return out.sorted { $0.key < $1.key }
    }
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh RepairRulesTests` → `Executed 24 tests, with 0 failures`; `fasttest.sh RepairPathsTests` → `Executed 7 tests, with 0 failures`.
- [ ] **Step 5:** `fasttest.sh`: `Executed 1081 tests` (B+58), 0 fallimenti, 0 warning. **Punto di controllo `xcodebuild`** (in background): build pulita 0 warning, `Executed 1081 tests`.
- [ ] **Mutanti che devono morire:** togliere la guardia `allSatisfy({ s.isComplete($0) })` (verificato: muore `testAnyArchiveIncomplete_blocksEveryRepair`); togliere `md5 != da.md5,` (verificato: muore `testAllThreeAgree_isNothingToRepair`); sostituire `cubbitKeyIsRepairable(o.displayKey)` con `true` (verificato: muore `testCubbitKeyWithPlusOrApostrophe_isNotRepairedOnCubbit`); in `safeComponents` accettare `.` e `..` (verificato: muoiono `testUnsafePaths_areRefused` e `testStagingPath_sitsNextToTheQuarantineCopy`).
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 3: regole pure di riparabilita' e percorsi di quarantena

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 4: il registro delle riparazioni (`repair-log.json`)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo il blocco del Task 3.
- Create: `AppBackupFotoTests/RepairLogTests.swift` (`3D7BDF69D092B120D96219AA` / `C02DAB72CD063550BF921394`).
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda, prima della `}` finale).

**Interfaces:**
- Consumes: `isAllowedStoreLocation` (la stessa allow-list di `LibraryIndexStore`/`TrashManifestStore`).
- Produces:
  - `nonisolated enum RepairStep: String, Codable, Sendable { case liveCheck, quarantine, write, finalCheck, log }`
  - `nonisolated enum RepairOutcomeKind: String, Codable, Sendable { case inProgress, repaired, failed, verificationFailed }`
  - `nonisolated struct RepairRecord: Codable, Equatable, Sendable` (`repairId`, `key`, `displayPath`, `target`, `source`, `witness`, `goodSHA256`, `goodSize`, `badSize`, `badSHA256?`, `badETag?`, `afterSHA256?`, `afterETag?`, `quarantinePath?`, `reusedQuarantineCopy`, `startedAt`, `finishedAt?`, `outcome`, `failedStep?`, `detail?`) con `init(from:)` esplicita
  - `nonisolated struct RepairLog: Codable { totalRecorded: Int; items: [RepairRecord] }` con `init(from:)` esplicita
  - `nonisolated final class RepairLogStore: @unchecked Sendable { static let defaultMaxItems = 2000; init(url:maxItems:) throws; var totalRecorded: Int; func record(_:) throws; func records() -> [RepairRecord] }`

**Stesso schema di `TrashManifest`, una differenza voluta:** `record` è un *upsert* per `repairId` — la stessa riparazione si scrive una volta «in corso», prima di toccare qualunque archivio (S4), e si aggiorna con l'esito. Gli archivi si scrivono come stringhe (`"ssd"`, `"hdd"`, `"s3"`, i `rawValue` di `InventoryArchive`): il file resta leggibile a mano.

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/RepairLogTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Il registro delle riparazioni (ROADMAP #45): `repair-log.json` sul Mac, stesso schema e
/// stessa disciplina di `TrashManifestStore` — scritto prima di tornare, `0600`, mai su un
/// archivio, retrocompatibile.
final class RepairLogTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RepairLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var url: URL { tmp.appendingPathComponent("repair-log.json") }

    private func record(_ id: String, outcome: RepairOutcomeKind = .inProgress) -> RepairRecord {
        RepairRecord(repairId: id, key: "foto/a.heic", displayPath: "Foto/a.heic", target: "s3", source: "ssd",
                     witness: "hdd", goodSHA256: "sha-a", goodSize: 10, badSize: 10, badETag: "\"bbb\"",
                     startedAt: Date(timeIntervalSince1970: 1_791_115_200), outcome: outcome)
    }

    func testRecord_isOnDiskBeforeReturning() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        let reread = try RepairLogStore(url: url)
        XCTAssertEqual(reread.records(), [record("r1")])
        XCTAssertEqual(reread.totalRecorded, 1)
    }

    /// La stessa riparazione passa da «in corso» al suo esito: una voce sola.
    func testSameRepair_isUpdatedInPlace() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        var done = record("r1", outcome: .repaired)
        done.afterETag = "\"b59917c9c6e38fccab5ce3f30c90d13a\""
        done.quarantinePath = "_quarantena/2026-10-04/Foto/a.heic"
        try store.record(done)
        try store.record(record("r2"))
        let reread = try RepairLogStore(url: url)
        XCTAssertEqual(reread.records().map(\.repairId), ["r1", "r2"])
        XCTAssertEqual(reread.records().first, done)
        XCTAssertEqual(reread.totalRecorded, 2)
    }

    func testPruning_keepsTheNewest_andTheTrueTotal() throws {
        let store = try RepairLogStore(url: url, maxItems: 3)
        for i in 0..<5 { try store.record(record("r\(i)")) }
        XCTAssertEqual(store.records().map(\.repairId), ["r2", "r3", "r4"], "si potano le piu' vecchie")
        XCTAssertEqual(store.totalRecorded, 5)
        XCTAssertEqual(RepairLogStore.defaultMaxItems, 2000)
    }

    /// Contiene i percorsi delle foto: leggibile solo dall'utente.
    func testFile_isPrivate() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    /// Mai su un archivio: stessa allow-list dell'elenco e del registro dei Doppioni.
    func testLocationOutsideTheAllowList_isRefused() {
        XCTAssertThrowsError(try RepairLogStore(url: URL(fileURLWithPath: "/Volumes/SSD - Enri/repair-log.json")))
    }

    func testUnreadableFile_startsEmpty_andStaysUsable() throws {
        try Data("non e' json".utf8).write(to: url)
        let store = try RepairLogStore(url: url)
        XCTAssertTrue(store.records().isEmpty)
        try store.record(record("r1"))
        XCTAssertEqual(try RepairLogStore(url: url).records().count, 1)
    }

    /// Una voce scritta con i soli campi portanti (una versione futura potrebbe toglierne o
    /// aggiungerne altri) si legge; i campi mancanti prendono il loro valore neutro.
    func testRecordWithOnlyTheLoadBearingFields_decodes() throws {
        let json = """
        {"items":[{"repairId":"r1","key":"foto/a.heic","target":"hdd","startedAt":0,"outcome":"repaired"}]}
        """
        try Data(json.utf8).write(to: url)
        let r = try XCTUnwrap(try RepairLogStore(url: url).records().first)
        XCTAssertEqual(r.target, "hdd")
        XCTAssertEqual(r.outcome, .repaired)
        XCTAssertNil(r.quarantinePath)
        XCTAssertFalse(r.reusedQuarantineCopy)
    }
}
```

e aggiungi in coda a `MainThreadIsolationTests` (prima della `}` finale):

```swift
    // MARK: - Riparazione (ROADMAP #45)

    func testRepairLogStore_runsWithoutTheMainThread() throws {
        let log = try RepairLogStore(url: tmp.appendingPathComponent("repair-log.json"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = log.records()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "RepairLogStore ha avuto bisogno del main thread.")
    }
```

Registra `RepairLogTests.swift` nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh RepairLogTests` → `COMPILAZIONE TEST FALLITA` con `cannot find 'RepairLogStore' in scope`.

- [ ] **Step 3: implementa.**

Inserisci **subito prima** della riga `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (si trova con `grep -n "MARK: - Testi e regole della card" AppBackupFoto/ContentView.swift`):

```swift
// MARK: - Riparazione: il registro sul Mac (ROADMAP #45, ADR-0016)

/// I passi della riparazione, nell'ordine in cui avvengono (spec, «Cosa succede quando si
/// ripara»). Su SSD e HDD la copia buona si PREPARA prima di mettere da parte quella rovinata
/// (scostamento S4 del piano): il passo `write` compare quindi due volte, prima e dopo
/// `quarantine`.
nonisolated enum RepairStep: String, Codable, Sendable {
    case liveCheck
    case quarantine
    case write
    case finalCheck
    case log
}

/// Com'e' finita una riparazione, per il registro.
nonisolated enum RepairOutcomeKind: String, Codable, Sendable {
    /// Scritto PRIMA di toccare qualunque archivio: se l'app si chiude a meta', il registro
    /// dice che una riparazione era cominciata e dove stava la copia messa da parte.
    case inProgress
    case repaired
    /// Fermata a un passo, con il motivo. Se il passo e' `liveCheck` non e' stato toccato niente.
    case failed
    /// Scritta, ma la verifica finale non torna: la copia rovinata resta in quarantena e non si
    /// ritenta da soli.
    case verificationFailed
}

/// Una riparazione nel registro. Tutti i campi che servono a ricostruire cosa e' successo
/// senza l'inventario: percorso, archivio riparato, sorgente, impronte prima e dopo, dove e'
/// finita la copia rovinata, quando, com'e' andata.
// `nonisolated`: value type, scritto dal motore fuori dal main e letto dalla finestra.
nonisolated struct RepairRecord: Codable, Equatable, Sendable {
    var repairId: String
    var key: String
    /// Il percorso nell'archivio riparato (su Cubbit, la chiave vera).
    var displayPath: String
    var target: String
    var source: String
    var witness: String
    var goodSHA256: String
    var goodSize: Int64
    var badSize: Int64
    var badSHA256: String? = nil
    var badETag: String? = nil
    var afterSHA256: String? = nil
    var afterETag: String? = nil
    /// Dove sta la copia rovinata messa da parte (relativo alla radice, o chiave di Cubbit).
    var quarantinePath: String? = nil
    /// Vero se su Cubbit la copia rovinata era gia' in quarantena (anche con un'altra data).
    var reusedQuarantineCopy: Bool = false
    var startedAt: Date
    var finishedAt: Date? = nil
    var outcome: RepairOutcomeKind
    var failedStep: RepairStep? = nil
    /// Testo per chi legge il registro a mano; mai mostrato cosi' com'e' nella finestra.
    var detail: String? = nil
}

nonisolated extension RepairRecord {
    private enum CodingKeys: String, CodingKey {
        case repairId, key, displayPath, target, source, witness, goodSHA256, goodSize, badSize, badSHA256, badETag,
             afterSHA256, afterETag, quarantinePath, reusedQuarantineCopy, startedAt, finishedAt, outcome, failedStep, detail
    }

    /// `init(from:)` esplicita con `decodeIfPresent` (regola del progetto per i tipi
    /// persistiti, fatto misurato n. 5 di #31). Severa sui campi portanti — senza identita',
    /// percorso, archivio, data o esito la voce non racconta niente — tollerante sugli altri.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repairId = try c.decode(String.self, forKey: .repairId)
        key = try c.decode(String.self, forKey: .key)
        displayPath = try c.decodeIfPresent(String.self, forKey: .displayPath) ?? ""
        target = try c.decode(String.self, forKey: .target)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        witness = try c.decodeIfPresent(String.self, forKey: .witness) ?? ""
        goodSHA256 = try c.decodeIfPresent(String.self, forKey: .goodSHA256) ?? ""
        goodSize = try c.decodeIfPresent(Int64.self, forKey: .goodSize) ?? 0
        badSize = try c.decodeIfPresent(Int64.self, forKey: .badSize) ?? 0
        badSHA256 = try c.decodeIfPresent(String.self, forKey: .badSHA256)
        badETag = try c.decodeIfPresent(String.self, forKey: .badETag)
        afterSHA256 = try c.decodeIfPresent(String.self, forKey: .afterSHA256)
        afterETag = try c.decodeIfPresent(String.self, forKey: .afterETag)
        quarantinePath = try c.decodeIfPresent(String.self, forKey: .quarantinePath)
        reusedQuarantineCopy = try c.decodeIfPresent(Bool.self, forKey: .reusedQuarantineCopy) ?? false
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outcome = try c.decode(RepairOutcomeKind.self, forKey: .outcome)
        failedStep = try c.decodeIfPresent(RepairStep.self, forKey: .failedStep)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Il contenuto di `repair-log.json`: stesso schema di `TrashManifest` (`totalRecorded` +
/// `items`), per la stessa ragione — il numero vero resta anche quando la lista e' potata.
// `nonisolated`: value type, letto e scritto da `RepairLogStore` sempre dietro `lock`.
nonisolated struct RepairLog: Codable {
    var totalRecorded: Int = 0
    var items: [RepairRecord] = []
}

nonisolated extension RepairLog {
    private enum CodingKeys: String, CodingKey { case totalRecorded, items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRecorded = try c.decodeIfPresent(Int.self, forKey: .totalRecorded) ?? 0
        items = try c.decodeIfPresent([RepairRecord].self, forKey: .items) ?? []
    }
}

/// Il registro delle riparazioni, sul disco interno (`Application Support/AppBackupFoto/
/// repair-log.json`), mai su un archivio. Stessa disciplina di `TrashManifestStore`: allow-list
/// della posizione, ogni scrittura su disco PRIMA di tornare, `0600`, un file illeggibile
/// riparte da vuoto senza bloccare niente.
// `nonisolated`: `record` arriva dal motore della riparazione fuori dal main, `records` dal
// main. Ogni accesso a `log` avviene dentro `lock.withLock`, scrittura su disco compresa;
// `url` e' `let`. Vedi ADR-0006.
nonisolated final class RepairLogStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case invalidLocation(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation(let p): return "Posizione non consentita per il registro delle riparazioni: \(p)"
            }
        }
    }

    /// Le riparazioni sono una alla volta e con conferma: 2.000 voci sono anni di storia.
    static let defaultMaxItems = 2000

    private let url: URL
    private let maxItems: Int
    private var log: RepairLog
    private let lock = NSLock()

    /// `maxItems` e' iniettato solo dai test (la potatura si prova con poche voci).
    init(url: URL, maxItems: Int = RepairLogStore.defaultMaxItems) throws {
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
        self.url = url
        self.maxItems = max(1, maxItems)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(RepairLog.self, from: data) {
            log = decoded
        } else {
            log = RepairLog()
        }
    }

    var totalRecorded: Int { lock.withLock { log.totalRecorded } }

    /// Aggiunge la voce, o aggiorna quella con lo stesso `repairId` (la stessa riparazione che
    /// passa da «in corso» al suo esito), e **scrive su disco prima di tornare**.
    func record(_ r: RepairRecord) throws {
        try lock.withLock {
            if let i = log.items.firstIndex(where: { $0.repairId == r.repairId }) {
                log.items[i] = r
            } else {
                log.items.append(r)
                log.totalRecorded += 1
                if log.items.count > maxItems { log.items = Array(log.items.suffix(maxItems)) }
            }
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
            // Best-effort, come il registro dei Doppioni: contiene i percorsi delle foto.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func records() -> [RepairRecord] { lock.withLock { log.items } }
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh RepairLogTests` → `Executed 7 tests, with 0 failures`; `fasttest.sh MainThreadIsolationTests` → 0 fallimenti (un test in più).
- [ ] **Step 5:** `fasttest.sh`: `Executed 1089 tests` (B+66), 0 fallimenti, 0 warning.
- [ ] **Mutanti che devono morire:** in `record`, aggiungere sempre in coda invece di aggiornare la voce con lo stesso `repairId` (muore `testSameRepair_isUpdatedInPlace`); `prefix` al posto di `suffix` nella potatura (muore `testPruning_keepsTheNewest_andTheTrueTotal`); `decode` al posto di `decodeIfPresent` su `quarantinePath` (muore `testRecordWithOnlyTheLoadBearingFields_decodes`).
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 4: registro delle riparazioni sul Mac

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 5: il motore della riparazione (`RepairEngine`)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R, dopo il blocco del Task 4.
- Create: `AppBackupFotoTests/RepairEngineTests.swift` (`C17486BE67CFB854FE2CAE08` / `66E8612C3A08039111319C1E`) — contiene anche `FakeRepairCloud`, `StepRecorder`, `Counter`.
- Modify: `AppBackupFotoTests/MainThreadIsolationTests.swift` (un test in coda, dopo quello del Task 4).

**Interfaces:**
- Consumes: `RepairCandidate`/`RepairRules`/`RepairPaths` (T3), `RepairRecord`/`RepairStep`/`RepairOutcomeKind` (T4), `S3Syncer.S3ObjectHead`/`S3ObjectInfo` (T2), `ContentHasher.digestFile`, `S3ETagMatcher`, `deviceIdentifier`, `canonicalPathComponents`.
- Produces:
  - `nonisolated protocol RepairCloud: Sendable { head(key:); list(prefix:); copy(from:to:); replace(key:withFileAt:) }` (tutti `async throws`)
  - `nonisolated enum RepairFailure: Equatable, Sendable` (15 casi, uno per ogni motivo di stop)
  - `nonisolated struct RepairOutcome: Equatable, Sendable` (`wasDryRun`, `succeeded`, `failedStep`, `failure`, `quarantinePath`, `reusedQuarantineCopy`, `restoredOriginal`, `leftoverStagingPath`, `afterSHA256`, `afterETag`, `finishedAt`, `logError`)
  - `nonisolated final class RepairEngine: @unchecked Sendable { init(ssdRoot:hddRoot:cloud:record:now:calendar:hashFile:copyFile:renameFile:volumeIdentity:makeToken:); @concurrent func run(_:dryRun:onStep:) async -> RepairOutcome; static func renameWithoutOverwriting(from:to:) throws; static func itemExists(_:) -> Bool; static func confined(_:_:) -> URL?; static func isInside(_:root:) -> Bool }`

**I passi, come li esegue `run`** (il primo che fallisce ferma tutto; ognuno ha almeno un test che lo fa fallire):

| Passo | Cubbit (`target == .s3`) | SSD/HDD |
| :--- | :--- | :--- |
| 1 ricontrollo | sorgente letta per intero = copia buona; testimone (HDD) letto per intero = copia buona; HEAD della rovinata: c'è, stessa dimensione e stesso ETag dell'inventario | sorgente letta = buona; HEAD del testimone (Cubbit): l'ETag certifica la buona (`S3ETagMatcher`); la rovinata c'è, stessa dimensione e stesso SHA256 dell'inventario; `st_dev` del disco annotato |
| (solo `dryRun`) | dove andrebbe la quarantena (lista di `_quarantena/`, HEAD della chiave di oggi), poi **stop**: nessuna scrittura, nessuna voce nel registro | dove andrebbe la quarantena (occupata = stop), poi **stop**, nessuna cartella creata |
| registro | voce `inProgress` (se non si scrive: stop, niente toccato) | idem |
| 2 quarantena | lista di `_quarantena/`: una copia di qualunque giorno con stessa dimensione ed ETag vale (**idempotente**); altrimenti HEAD della chiave di oggi (occupata da altro = stop) e copia lato server; poi HEAD della copia: stessa dimensione ed ETag | (dopo la preparazione) `rename` rovinata → `_quarantena/<oggi>/<percorso>`, con `st_dev` ricontrollato |
| 3 scrittura | `replace` (l'`upload` del backup) | **prima** della quarantena: `copyItem` sorgente → `…​.in-arrivo-<token>` e rilettura; **dopo**: `rename` preparata → posto; se fallisce, `rename` rovinata → posto (`restoredOriginal`) |
| 4 verifica | HEAD: dimensione e ETag = `expectedCubbitETag(good)` (per la `.heic`: `b59917c9c6e38fccab5ce3f30c90d13a`); se no `verificationFailed`, nessun secondo tentativo | rilettura della foto al suo posto = buona; se no `verificationFailed` |
| 5 registro | voce aggiornata `repaired` (se non si scrive: riparazione valida, `logError`) | idem |

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/RepairEngineTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// Un Cubbit finto in memoria, con un interruttore per far fallire ogni richiesta. L'ETag di un
/// oggetto e' l'MD5 del suo contenuto, come per un caricamento unico.
nonisolated final class FakeRepairCloud: RepairCloud, @unchecked Sendable {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "rete finta giu'" } }
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var etagOverride: [String: String] = [:]
    private(set) var copies: [(from: String, to: String)] = []
    private(set) var replaces: [String] = []
    var failHead = false, failList = false, failCopy = false, failReplace = false
    /// La copia lato server scrive un contenuto diverso (per la verifica dopo la copia).
    var copyCorrupts = false
    /// Il caricamento scrive un contenuto diverso (per la verifica finale).
    var replaceCorrupts = false

    static func md5(_ d: Data) -> String { var h = ContentHasher(); h.update(d); return h.finalize().md5 }

    func put(_ key: String, _ text: String) { lock.withLock { objects[key] = Data(text.utf8) } }
    func data(_ key: String) -> String? { lock.withLock { objects[key].map { String(decoding: $0, as: UTF8.self) } } }
    func keys() -> [String] { lock.withLock { objects.keys.sorted() } }
    func remove(_ key: String) { lock.withLock { objects[key] = nil } }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try lock.withLock {
            if failHead { throw Failure() }
            guard let d = objects[key] else { return nil }
            return S3Syncer.S3ObjectHead(size: Int64(d.count), etag: "\"\(etagOverride[key] ?? Self.md5(d))\"")
        }
    }

    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo] {
        try lock.withLock {
            if failList { throw Failure() }
            return objects.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                .map { S3Syncer.S3ObjectInfo(key: $0.key, size: Int64($0.value.count), etag: "\"\(Self.md5($0.value))\"") }
        }
    }

    func copy(from sourceKey: String, to destinationKey: String) async throws {
        try lock.withLock {
            if failCopy { throw Failure() }
            copies.append((sourceKey, destinationKey))
            objects[destinationKey] = copyCorrupts ? Data("guasta".utf8) : objects[sourceKey]
        }
    }

    func replace(key: String, withFileAt url: URL) async throws {
        let d = try Data(contentsOf: url)
        try lock.withLock {
            if failReplace { throw Failure() }
            replaces.append(key)
            objects[key] = replaceCorrupts ? Data(d.reversed()) : d
        }
    }
}

/// Il motore della riparazione (ROADMAP #45, ADR-0016) su cartelle temporanee al posto di SSD e
/// HDD e un Cubbit finto. Per ogni passo che puo' fallire c'e' un test che pretende che tutto
/// resti com'era (o, dopo la quarantena, che la copia rovinata non vada mai persa).
final class RepairEngineTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var log: RepairLogStore!
    private var cloud: FakeRepairCloud!
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let good = "foto integra, letta su SSD e HDD"
    private let bad  = "foto rovinata, ultimi byte a zero"   // stessa lunghezza non serve: conta l'impronta
    /// 2026-10-04T12:00:00Z: a Roma e' il 4 ottobre.
    private let today = Date(timeIntervalSince1970: 1_791_115_200)
    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("RepairEngineTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd!, hdd!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        log = try RepairLogStore(url: tmp.appendingPathComponent("repair-log.json"))
        cloud = FakeRepairCloud()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func digest(_ text: String) -> ContentDigest {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize()
    }

    /// Tutti i file sotto una radice, percorso relativo → contenuto: per dire «tutto com'era».
    private func tree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        while let u = e.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[String(u.path.dropFirst(base.count + 1))] = String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self)
        }
        return out
    }

    private func engine(record: (@Sendable (RepairRecord) throws -> Void)? = nil,
                        hashFile: (@Sendable (URL) -> ContentReadOutcome)? = nil,
                        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil,
                        renameFile: (@Sendable (URL, URL) throws -> Void)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil,
                        now: Date? = nil) -> RepairEngine {
        let store = log!
        let when = now ?? today
        return RepairEngine(ssdRoot: ssd, hddRoot: hdd, cloud: cloud,
                            record: record ?? { try store.record($0) },
                            now: { when }, calendar: rome,
                            hashFile: hashFile ?? { ContentHasher.digestFile(at: $0) },
                            copyFile: copyFile ?? { try FileManager.default.copyItem(at: $0, to: $1) },
                            renameFile: renameFile ?? { try RepairEngine.renameWithoutOverwriting(from: $0, to: $1) },
                            volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) },
                            makeToken: { "1a2b3c4d" })
    }

    /// Rovinata su Cubbit: la situazione del 2026-10-01.
    private func brokenOnCubbit() throws -> RepairCandidate {
        try put(ssd, path, good)
        try put(hdd, path, good)
        cloud.put(path, bad)
        return RepairCandidate(key: normalizedIndexKey(path), target: .s3, source: .ssd, witness: .hdd,
                               paths: [.ssd: path, .hdd: path, .s3: path], good: digest(good),
                               badSize: Int64(bad.utf8.count), badSHA256: nil,
                               badETag: "\"\(FakeRepairCloud.md5(Data(bad.utf8)))\"")
    }

    /// Rovinata su un disco (`target` .hdd o .ssd): l'altro disco e Cubbit hanno la buona.
    private func brokenOnDisk(_ target: InventoryArchive) throws -> RepairCandidate {
        try put(target == .ssd ? ssd : hdd, path, bad)
        try put(target == .ssd ? hdd : ssd, path, good)
        cloud.put(path, good)
        return RepairCandidate(key: normalizedIndexKey(path), target: target,
                               source: RepairRules.source(forTarget: target), witness: .s3,
                               paths: [.ssd: path, .hdd: path, .s3: path], good: digest(good),
                               badSize: Int64(bad.utf8.count), badSHA256: digest(bad).sha256, badETag: nil)
    }

    private var quarantineKey: String { "_quarantena/2026-10-04/" + path }
    private var stagingRel: String { quarantineKey + ".in-arrivo-1a2b3c4d" }

    // MARK: - Cubbit: riuscita

    func testCubbit_repairs_andKeepsTheBrokenCopyInQuarantine() async throws {
        let c = try brokenOnCubbit()
        let steps = StepRecorder()
        let out = await engine().run(c, onStep: { steps.add($0) })
        XCTAssertTrue(out.succeeded, "\(String(describing: out.failure))")
        XCTAssertEqual(cloud.data(path), good, "al suo posto c'e' la copia dell'SSD")
        XCTAssertEqual(cloud.data(quarantineKey), bad, "la rovinata e' in quarantena, non cancellata")
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(RepairRules.normalizedETag(out.afterETag), digest(good).md5)
        XCTAssertEqual(steps.all, [.liveCheck, .quarantine, .write, .finalCheck, .log])
        XCTAssertEqual(read(ssd, path), good, "la sorgente non si tocca")
        XCTAssertEqual(read(hdd, path), good)
        let r = try XCTUnwrap(log.records().first)
        XCTAssertEqual(log.records().count, 1)
        XCTAssertEqual(r.outcome, .repaired)
        XCTAssertEqual(r.target, "s3")
        XCTAssertEqual(r.source, "ssd")
        XCTAssertEqual(r.quarantinePath, quarantineKey)
        XCTAssertEqual(r.goodSHA256, digest(good).sha256)
        XCTAssertEqual(RepairRules.normalizedETag(r.afterETag), digest(good).md5)
    }

    /// La prova con `rclone` del 2026-10-04 ha gia' messo da parte la rovinata: un altro giorno
    /// non la si copia di nuovo, si procede.
    func testCubbit_quarantineCopyFromAnotherDay_isReused() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, bad)
        let sixth = today.addingTimeInterval(2 * 86_400)
        let out = await engine(now: sixth).run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertTrue(out.reusedQuarantineCopy)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertTrue(cloud.copies.isEmpty, "nessuna seconda copia")
        XCTAssertFalse(cloud.keys().contains("_quarantena/2026-10-06/" + path))
    }

    /// In quarantena c'e' qualcosa con quel nome, ma non e' la rovinata: non vale.
    func testCubbit_differentQuarantineCopy_isNotReused() async throws {
        let c = try brokenOnCubbit()
        cloud.put("_quarantena/2026-10-01/" + path, "un'altra cosa")
        let out = await engine().run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(cloud.data("_quarantena/2026-10-01/" + path), "un'altra cosa", "mai sovrascritta")
    }

    func testCubbit_todaysQuarantineKeyHoldsSomethingElse_stopsWithoutTouching() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, "un'altra cosa")
        // La lista la vede ma non e' la rovinata; la HEAD sulla chiave di oggi la trova occupata.
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineOccupied)
        XCTAssertEqual(out.failedStep, .quarantine)
        XCTAssertEqual(cloud.data(quarantineKey), "un'altra cosa")
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty)
    }

    // MARK: - Cubbit: ricontrollo dal vivo, niente viene toccato

    private func assertCubbitUntouched(_ out: RepairOutcome, _ failure: RepairFailure,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(out.succeeded, file: file, line: line)
        XCTAssertEqual(out.failure, failure, file: file, line: line)
        XCTAssertEqual(out.failedStep, .liveCheck, file: file, line: line)
        XCTAssertTrue(cloud.copies.isEmpty, "nessuna quarantena", file: file, line: line)
        XCTAssertTrue(cloud.replaces.isEmpty, "nessuna scrittura", file: file, line: line)
        XCTAssertFalse(cloud.keys().contains { $0.hasPrefix("_quarantena/") }, file: file, line: line)
        XCTAssertNil(out.quarantinePath, file: file, line: line)
    }

    func testCubbit_sourceChangedSinceTheInventory_stops() async throws {
        let c = try brokenOnCubbit()
        try put(ssd, path, "cambiata dopo l'inventario")
        assertCubbitUntouched(await engine().run(c), .sourceChanged)
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testCubbit_witnessChanged_stops() async throws {
        let c = try brokenOnCubbit()
        try put(hdd, path, "diversa sull'HDD")
        assertCubbitUntouched(await engine().run(c), .witnessChanged)
    }

    func testCubbit_brokenCopyChangedSinceTheInventory_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.put(path, "ricaricata da qualcun altro")
        assertCubbitUntouched(await engine().run(c), .badCopyChanged)
        XCTAssertEqual(cloud.data(path), "ricaricata da qualcun altro")
    }

    func testCubbit_brokenCopyGone_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.remove(path)
        assertCubbitUntouched(await engine().run(c), .badCopyMissing)
    }

    func testCubbit_unreachable_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.failHead = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .liveCheck)
        guard case .cubbitError = out.failure else { return XCTFail("\(String(describing: out.failure))") }
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testMissingDisk_stops() async throws {
        let c = try brokenOnCubbit()
        try FileManager.default.removeItem(at: ssd)
        assertCubbitUntouched(await engine().run(c), .volumeMissing(.ssd))
    }

    func testUnsafePath_stops() async throws {
        let c0 = try brokenOnCubbit()
        let c = RepairCandidate(key: c0.key, target: .s3, source: .ssd, witness: .hdd,
                                paths: [.ssd: "../fuori.heic", .hdd: path, .s3: path], good: c0.good,
                                badSize: c0.badSize, badSHA256: nil, badETag: c0.badETag)
        assertCubbitUntouched(await engine().run(c), .unsafePath)
    }

    /// Un candidato incoerente (sorgente sbagliata per l'archivio da riparare) non parte.
    func testInconsistentCandidate_stops() async throws {
        let c0 = try brokenOnCubbit()
        let c = RepairCandidate(key: c0.key, target: .s3, source: .hdd, witness: .ssd, paths: c0.paths,
                                good: c0.good, badSize: c0.badSize, badSHA256: nil, badETag: c0.badETag)
        assertCubbitUntouched(await engine().run(c), .unsafePath)
    }

    // MARK: - Cubbit: fallimenti dopo il ricontrollo

    func testCubbit_logCannotBeWritten_stopsBeforeTouchingAnything() async throws {
        let c = try brokenOnCubbit()
        struct Full: Error {}
        let out = await engine(record: { _ in throw Full() }).run(c)
        XCTAssertEqual(out.failedStep, .log)
        guard case .logNotWritten = out.failure else { return XCTFail() }
        XCTAssertTrue(cloud.copies.isEmpty)
        XCTAssertTrue(cloud.replaces.isEmpty)
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testCubbit_copyFails_leavesTheBrokenCopyWhereItWas() async throws {
        let c = try brokenOnCubbit()
        cloud.failCopy = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .quarantine)
        guard case .quarantineFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty, "senza quarantena non si scrive")
        XCTAssertEqual(log.records().first?.outcome, .failed)
        XCTAssertEqual(log.records().first?.failedStep, .quarantine)
    }

    func testCubbit_quarantineCopyNotIdentical_stopsBeforeWriting() async throws {
        let c = try brokenOnCubbit()
        cloud.copyCorrupts = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineCopyMismatch)
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty)
    }

    func testCubbit_uploadFails_theBrokenCopyIsStillThere_andInQuarantine() async throws {
        let c = try brokenOnCubbit()
        cloud.failReplace = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .write)
        guard case .writeFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(cloud.data(path), bad, "il caricamento fallito non ha toccato l'oggetto")
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
    }

    /// La verifica finale non torna: avviso, la rovinata resta in quarantena, nessun secondo tentativo.
    func testCubbit_finalCheckFails_noSecondAttempt() async throws {
        let c = try brokenOnCubbit()
        cloud.replaceCorrupts = true
        let out = await engine().run(c)
        XCTAssertFalse(out.succeeded)
        XCTAssertEqual(out.failedStep, .finalCheck)
        XCTAssertEqual(out.failure, .finalCheckFailed)
        XCTAssertEqual(cloud.replaces.count, 1)
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(log.records().first?.outcome, .verificationFailed)
    }

    /// Il registro non si aggiorna alla fine: la riparazione e' fatta, e la finestra lo dice.
    func testCubbit_logFailsOnlyAtTheEnd_repairStands_andSaysSo() async throws {
        let c = try brokenOnCubbit()
        let store = log!
        let calls = Counter()
        struct Full: Error {}
        let out = await engine(record: { r in
            if calls.next() > 1 { throw Full() }
            try store.record(r)
        }).run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertNotNil(out.logError)
        XCTAssertEqual(log.records().first?.outcome, .inProgress, "resta la voce scritta prima di toccare")
    }

    // MARK: - Disco: riuscita

    func testHDD_repairsFromTheSSD_withCubbitAsWitness() async throws {
        let c = try brokenOnDisk(.hdd)
        let steps = StepRecorder()
        let out = await engine().run(c, onStep: { steps.add($0) })
        XCTAssertTrue(out.succeeded, "\(String(describing: out.failure))")
        XCTAssertEqual(read(hdd, path), good)
        XCTAssertEqual(read(hdd, quarantineKey), bad, "rovinata spostata in quarantena sullo stesso disco")
        XCTAssertNil(read(hdd, stagingRel), "la copia preparata e' andata al suo posto")
        XCTAssertNil(out.leftoverStagingPath)
        XCTAssertEqual(out.afterSHA256, digest(good).sha256)
        XCTAssertEqual(tree(ssd), [path: good], "la sorgente non si tocca")
        XCTAssertEqual(cloud.keys(), [path], "Cubbit solo letto")
        XCTAssertTrue(cloud.copies.isEmpty && cloud.replaces.isEmpty)
        XCTAssertEqual(steps.all, [.liveCheck, .write, .quarantine, .write, .finalCheck, .log])
        XCTAssertEqual(log.records().first?.outcome, .repaired)
        XCTAssertEqual(log.records().first?.target, "hdd")
    }

    /// Decisione 2 di Enrico: anche l'SSD, dall'HDD.
    func testSSD_repairsFromTheHDD() async throws {
        let c = try brokenOnDisk(.ssd)
        let out = await engine().run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(read(ssd, path), good)
        XCTAssertEqual(read(ssd, quarantineKey), bad)
        XCTAssertEqual(tree(hdd), [path: good])
        XCTAssertEqual(log.records().first?.source, "hdd")
    }

    // MARK: - Disco: ogni fallimento lascia la foto dov'era

    func testDisk_brokenCopyChanged_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        try put(hdd, path, "toccata dopo l'inventario")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .badCopyChanged)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_brokenCopyGone_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(path))
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .badCopyMissing)
    }

    func testDisk_cubbitWitnessChanged_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        cloud.put(path, "diversa su Cubbit")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .witnessChanged)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_quarantineNameAlreadyTaken_stopsWithoutTouching() async throws {
        let c = try brokenOnDisk(.hdd)
        try put(hdd, quarantineKey, "c'era gia'")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineOccupied)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_preparingTheCopyFails_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        struct Full: Error {}
        let out = await engine(copyFile: { _, _ in throw Full() }).run(c)
        XCTAssertEqual(out.failedStep, .write)
        guard case .stagingFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(tree(hdd), [path: bad])
        XCTAssertNil(out.quarantinePath)
    }

    func testDisk_preparedCopyDoesNotMatch_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        let wrong = digest("un'altra cosa")
        let out = await engine(hashFile: { url in
            url.lastPathComponent.contains(".in-arrivo-") ? .digest(wrong) : ContentHasher.digestFile(at: url)
        }).run(c)
        XCTAssertEqual(out.failure, .stagingMismatch)
        XCTAssertEqual(read(hdd, path), bad)
        XCTAssertNil(out.quarantinePath)
        XCTAssertEqual(out.leftoverStagingPath, stagingRel, "resta in quarantena, non si cancella")
        XCTAssertEqual(read(hdd, stagingRel), good)
    }

    func testDisk_moveToQuarantineFails_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        struct Denied: Error {}
        let out = await engine(renameFile: { _, _ in throw Denied() }).run(c)
        XCTAssertEqual(out.failedStep, .quarantine)
        guard case .quarantineFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(read(hdd, path), bad)
        XCTAssertNil(read(hdd, quarantineKey))
    }

    /// Il secondo `rename` (la copia buona al suo posto) fallisce: la rovinata torna dov'era.
    func testDisk_writeFails_theBrokenCopyGoesBack() async throws {
        let c = try brokenOnDisk(.hdd)
        let calls = Counter()
        struct Denied: Error {}
        let out = await engine(renameFile: { from, to in
            if calls.next() == 2 { throw Denied() }
            try RepairEngine.renameWithoutOverwriting(from: from, to: to)
        }).run(c)
        XCTAssertEqual(out.failedStep, .write)
        XCTAssertTrue(out.restoredOriginal)
        XCTAssertNil(out.quarantinePath)
        XCTAssertEqual(read(hdd, path), bad, "tutto com'era")
        XCTAssertNil(read(hdd, quarantineKey))
        XCTAssertEqual(out.leftoverStagingPath, stagingRel)
    }

    /// E se fallisce anche il ritorno: la rovinata resta in quarantena (mai persa) e l'esito
    /// dice dove sono entrambe.
    func testDisk_writeAndRollbackFail_nothingIsLost() async throws {
        let c = try brokenOnDisk(.hdd)
        let calls = Counter()
        struct Denied: Error {}
        let out = await engine(renameFile: { from, to in
            if calls.next() >= 2 { throw Denied() }
            try RepairEngine.renameWithoutOverwriting(from: from, to: to)
        }).run(c)
        XCTAssertFalse(out.restoredOriginal)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertEqual(read(hdd, quarantineKey), bad)
        XCTAssertEqual(read(hdd, stagingRel), good)
        XCTAssertNil(read(hdd, path))
    }

    func testDisk_finalCheckFails_noSecondAttempt() async throws {
        let c = try brokenOnDisk(.hdd)
        let wrong = digest("un'altra cosa")
        let target = hdd.appendingPathComponent(path).path
        let reads = Counter()
        let out = await engine(hashFile: { url in
            // La prima lettura del bersaglio e' il ricontrollo (vera), la seconda la verifica finale.
            if url.path == target, reads.next() == 2 { return .digest(wrong) }
            return ContentHasher.digestFile(at: url)
        }).run(c)
        XCTAssertEqual(out.failure, .finalCheckFailed)
        XCTAssertEqual(log.records().first?.outcome, .verificationFailed)
        XCTAssertEqual(read(hdd, quarantineKey), bad, "la rovinata resta in quarantena")
    }

    func testDisk_volumeChangesBeforeTheQuarantine_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        let root = hdd.path
        let calls = Counter()
        let out = await engine(volumeIdentity: { url in
            // Il ricontrollo vede il disco; subito dopo e' un altro disco (scollegato e ricollegato).
            if url.path == root, calls.next() >= 2 { return 999_999 }
            return deviceIdentifier(of: url)
        }).run(c)
        XCTAssertEqual(out.failure, .volumeMissing(.hdd))
        XCTAssertEqual(tree(hdd), [path: bad])
    }

    // MARK: - Controllo senza riparare (S11)

    func testDryRun_onCubbit_touchesNothing_andSaysWhere() async throws {
        let c = try brokenOnCubbit()
        let steps = StepRecorder()
        let out = await engine().run(c, dryRun: true, onStep: { steps.add($0) })
        XCTAssertTrue(out.wasDryRun)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(steps.all, [.liveCheck])
        XCTAssertTrue(cloud.copies.isEmpty && cloud.replaces.isEmpty)
        XCTAssertEqual(cloud.keys(), [path])
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(log.records().isEmpty, "un controllo non va nel registro")
    }

    func testDryRun_onCubbit_seesTheCopyAlreadyInQuarantine() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, bad)
        let out = await engine(now: today.addingTimeInterval(86_400)).run(c, dryRun: true)
        XCTAssertTrue(out.succeeded)
        XCTAssertTrue(out.reusedQuarantineCopy)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertTrue(cloud.copies.isEmpty)
    }

    func testDryRun_onADisk_touchesNothing() async throws {
        let c = try brokenOnDisk(.hdd)
        let out = await engine().run(c, dryRun: true)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertEqual(tree(hdd), [path: bad])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("_quarantena").path),
                       "nemmeno una cartella creata")
        XCTAssertTrue(log.records().isEmpty)
    }

    func testDryRun_thatFails_saysWhy_andIsNotLogged() async throws {
        let c = try brokenOnCubbit()
        try put(ssd, path, "cambiata")
        let out = await engine().run(c, dryRun: true)
        XCTAssertTrue(out.wasDryRun)
        XCTAssertEqual(out.failure, .sourceChanged)
        XCTAssertTrue(log.records().isEmpty)
    }

    // MARK: - Le funzioni di disco

    func testRenameWithoutOverwriting_neverOverwrites() throws {
        try put(tmp, "a.jpg", "a")
        try put(tmp, "b.jpg", "b")
        XCTAssertThrowsError(try RepairEngine.renameWithoutOverwriting(from: tmp.appendingPathComponent("a.jpg"),
                                                                       to: tmp.appendingPathComponent("b.jpg")))
        XCTAssertEqual(read(tmp, "a.jpg"), "a")
        XCTAssertEqual(read(tmp, "b.jpg"), "b")
        try RepairEngine.renameWithoutOverwriting(from: tmp.appendingPathComponent("a.jpg"),
                                                  to: tmp.appendingPathComponent("c.jpg"))
        XCTAssertNil(read(tmp, "a.jpg"))
        XCTAssertEqual(read(tmp, "c.jpg"), "a")
    }

    /// Una cartella che e' un link verso fuori dalla radice non e' «sotto la radice».
    func testConfined_refusesALinkThatLeavesTheRoot() throws {
        let outside = tmp.appendingPathComponent("fuori")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ssd.appendingPathComponent("Foto"), withDestinationURL: outside)
        XCTAssertNil(RepairEngine.confined(ssd, "Foto/a.jpg"))
        try FileManager.default.createDirectory(at: ssd.appendingPathComponent("Vere"), withIntermediateDirectories: true)
        XCTAssertNotNil(RepairEngine.confined(ssd, "Vere/a.jpg"))
        XCTAssertNil(RepairEngine.confined(ssd, "../SSD/Vere/a.jpg"))
    }
}

/// Raccoglie i passi annunciati dal motore (da un thread qualsiasi).
nonisolated final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [RepairStep] = []
    func add(_ s: RepairStep) { lock.withLock { steps.append(s) } }
    var all: [RepairStep] { lock.withLock { steps } }
}

/// Un contatore da usare dentro le closure `@Sendable` dei test.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
```

e aggiungi in coda a `MainThreadIsolationTests`, dopo il test del Task 4:

```swift
    func testRepairEngineRun_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD"), hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd, hdd] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("buona".utf8).write(to: ssd.appendingPathComponent("a.jpg"))
        try Data("buona".utf8).write(to: hdd.appendingPathComponent("a.jpg"))
        let cloud = FakeRepairCloud()
        cloud.put("a.jpg", "rovinata")
        var h = ContentHasher(); h.update(Data("buona".utf8))
        let c = RepairCandidate(key: "a.jpg", target: .s3, source: .ssd, witness: .hdd,
                                paths: [.ssd: "a.jpg", .hdd: "a.jpg", .s3: "a.jpg"], good: h.finalize(),
                                badSize: 8, badSHA256: nil, badETag: FakeRepairCloud.md5(Data("rovinata".utf8)))
        let log = try RepairLogStore(url: tmp.appendingPathComponent("repair-log.json"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let engine = RepairEngine(ssdRoot: ssd, hddRoot: hdd, cloud: cloud, record: { try log.record($0) })
            _ = await engine.run(c)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "RepairEngine.run ha avuto bisogno del main thread (manca @concurrent o nonisolated?).")
    }
```

Registra `RepairEngineTests.swift` nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh RepairEngineTests` → `COMPILAZIONE TEST FALLITA` con `cannot find type 'RepairCloud' in scope`.

- [ ] **Step 3: implementa.**

Inserisci **subito prima** della riga `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (si trova con `grep -n "MARK: - Testi e regole della card" AppBackupFoto/ContentView.swift`):

```swift
// MARK: - Riparazione: il motore (ROADMAP #45, ADR-0016)

/// Quello che la riparazione chiede a Cubbit. In produzione `S3RepairCloud` (sopra
/// `S3Syncer`); nei test un Cubbit finto in memoria.
nonisolated protocol RepairCloud: Sendable {
    /// `nil` = l'oggetto non c'e'.
    func head(key: String) async throws -> S3Syncer.S3ObjectHead?
    /// Tutti gli oggetti sotto `prefix`; lancia se la lista non arriva in fondo.
    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo]
    /// Copia lato server; la sorgente non viene toccata.
    func copy(from sourceKey: String, to destinationKey: String) async throws
    /// La sola sovrascrittura: la copia buona al posto di quella rovinata.
    func replace(key: String, withFileAt url: URL) async throws
}

/// Perche' una riparazione si e' fermata. Ogni caso ha la sua frase in `RepairStatus`.
nonisolated enum RepairFailure: Equatable, Sendable {
    case volumeMissing(InventoryArchive)
    case unsafePath
    case sourceChanged
    case witnessChanged
    case badCopyMissing
    case badCopyChanged
    case cubbitError(String)
    case logNotWritten(String)
    case quarantineOccupied
    case quarantineFailed(String)
    case quarantineCopyMismatch
    case stagingFailed(String)
    case stagingMismatch
    case writeFailed(String)
    case finalCheckFailed
}

/// Com'e' andata una riparazione, per la finestra.
nonisolated struct RepairOutcome: Equatable, Sendable {
    let key: String
    let target: InventoryArchive
    /// Il percorso nell'archivio riparato.
    let displayPath: String
    /// Controllo senza riparare (S11): il ricontrollo e' stato fatto, niente e' stato scritto
    /// (nemmeno nel registro); `quarantinePath` dice dove andrebbe la copia diversa.
    var wasDryRun = false
    var succeeded = false
    var failedStep: RepairStep? = nil
    var failure: RepairFailure? = nil
    /// Dove sta la copia rovinata messa da parte; `nil` se non e' stata spostata (o e' stata
    /// rimessa al suo posto).
    var quarantinePath: String? = nil
    var reusedQuarantineCopy = false
    /// Su SSD/HDD: la scrittura e' fallita dopo la quarantena, e la copia rovinata e' stata
    /// rimessa dov'era — tutto com'era prima.
    var restoredOriginal = false
    /// Su SSD/HDD: la copia buona preparata e rimasta dentro la quarantena (non si cancella).
    var leftoverStagingPath: String? = nil
    var afterSHA256: String? = nil
    var afterETag: String? = nil
    var finishedAt: Date
    /// Il registro non si e' potuto aggiornare alla fine: la riparazione e' andata come dice
    /// `succeeded`, ma il registro dice ancora «in corso».
    var logError: String? = nil
}

/// La riparazione di UNA foto, nei passi della spec: ricontrollo dal vivo, quarantena,
/// scrittura, verifica finale, registro. Il primo passo che fallisce ferma tutto e dice cosa
/// e' successo.
///
/// - Su **Cubbit**: quarantena = copia lato server in `_quarantena/<giorno>/<chiave>`,
///   IDEMPOTENTE (una copia gia' messa da parte, anche un altro giorno, con la stessa
///   dimensione e lo stesso ETag della rovinata, vale come fatta); poi HEAD della copia;
///   scrittura = `S3Syncer.upload` (la sola sovrascrittura); verifica = HEAD con l'ETag atteso.
/// - Su **SSD/HDD**: la copia buona si PREPARA prima (copia + rilettura dentro la quarantena,
///   scostamento S4), poi la rovinata si sposta in quarantena con `rename(2)` sullo stesso
///   volume, poi la preparata va al suo posto con un altro `rename(2)`. Se quest'ultimo
///   fallisce la rovinata torna dov'era. Mai `removeItem`, mai `FileManager.moveItem` (fra due
///   volumi copierebbe e poi cancellerebbe).
///
/// Le funzioni di disco, di hash e il Cubbit sono iniettati: i fallimenti da coprire (un
/// `rename` che fallisce, un disco che cambia, una copia che non torna) non si producono su
/// file veri senza una corsa. In produzione sono quelle vere (default), stesso schema di
/// `TrashRestorer`.
// `nonisolated`: `run` gira fuori dal main (rilegge file interi). Solo proprieta' `let`
// (closure `@Sendable`, URL, `Calendar`); lo stato di una riparazione e' tutto locale a `run`.
// Una alla volta: lo garantisce `BackupRunner.isRepairing`. `run` e' `@concurrent` (ADR-0006).
nonisolated final class RepairEngine: @unchecked Sendable {
    enum FileError: Error, LocalizedError {
        case destinationExists(String)
        var errorDescription: String? {
            switch self {
            case .destinationExists(let p): return "Esiste gia' un file in \(p)"
            }
        }
    }

    private let ssdRoot: URL
    private let hddRoot: URL
    private let cloud: any RepairCloud
    private let record: @Sendable (RepairRecord) throws -> Void
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let hashFile: @Sendable (URL) -> ContentReadOutcome
    private let copyFile: @Sendable (URL, URL) throws -> Void
    private let renameFile: @Sendable (URL, URL) throws -> Void
    private let volumeIdentity: @Sendable (URL) -> dev_t?
    private let makeToken: @Sendable () -> String

    init(ssdRoot: URL, hddRoot: URL, cloud: any RepairCloud,
         record: @escaping @Sendable (RepairRecord) throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = RepairPaths.defaultCalendar,
         hashFile: @escaping @Sendable (URL) -> ContentReadOutcome = { ContentHasher.digestFile(at: $0) },
         copyFile: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
         renameFile: @escaping @Sendable (URL, URL) throws -> Void = { try RepairEngine.renameWithoutOverwriting(from: $0, to: $1) },
         volumeIdentity: @escaping @Sendable (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         makeToken: @escaping @Sendable () -> String = {
             String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
         }) {
        self.ssdRoot = ssdRoot
        self.hddRoot = hddRoot
        self.cloud = cloud
        self.record = record
        self.now = now
        self.calendar = calendar
        self.hashFile = hashFile
        self.copyFile = copyFile
        self.renameFile = renameFile
        self.volumeIdentity = volumeIdentity
        self.makeToken = makeToken
    }

    /// `rename(2)` senza mai sovrascrivere: se la destinazione esiste ci si ferma (zero-overwrite
    /// anche dentro la quarantena). Non `FileManager.moveItem`: fra due volumi diversi copia e
    /// poi CANCELLA l'originale, mentre `rename(2)` fallisce con `EXDEV` e non tocca niente. Il
    /// controllo e lo spostamento non sono atomici fra loro: la finestra e' di microsecondi, e
    /// nessun'altra operazione dell'app scrive mentre una riparazione e' in corso (`isRepairing`).
    nonisolated static func renameWithoutOverwriting(from: URL, to: URL) throws {
        guard !itemExists(to) else { throw FileError.destinationExists(to.path) }
        guard rename(from.path, to.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// `lstat`: vero anche per un link rotto (che `fileExists` darebbe come assente).
    nonisolated static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// `root/relative`, solo se il percorso e' sicuro e la sua cartella, risolta dal
    /// filesystem, sta davvero sotto la radice (per componenti, mai per prefisso di stringa).
    nonisolated static func confined(_ root: URL, _ relative: String) -> URL? {
        guard RepairPaths.safeComponents(relative) != nil else { return nil }
        let url = root.appendingPathComponent(relative)
        return isInside(url.deletingLastPathComponent(), root: root) ? url : nil
    }

    nonisolated static func isInside(_ dir: URL, root: URL) -> Bool {
        let r = canonicalPathComponents(of: root)
        let d = canonicalPathComponents(of: dir)
        return !r.isEmpty && d.count >= r.count && Array(d.prefix(r.count)) == r
    }

    private func root(_ a: InventoryArchive) -> URL? {
        switch a {
        case .ssd: return ssdRoot
        case .hdd: return hddRoot
        case .s3: return nil
        }
    }

    private static func isGood(_ r: ContentReadOutcome, _ good: ContentDigest) -> Bool {
        if case .digest(let d) = r { return d.sha256 == good.sha256 && d.size == good.size }
        return false
    }

    /// Una copia della rovinata gia' in quarantena su Cubbit, in un giorno qualsiasi, con la
    /// stessa dimensione e lo stesso ETag: la quarantena IDEMPOTENTE. `nil` se non c'e'.
    private func existingQuarantineCopy(of relative: String, size: Int64, etag: String?) async throws -> String? {
        try await cloud.list(prefix: RepairPaths.quarantineFolder + "/")
            .filter { RepairPaths.isQuarantineCopy($0.key, of: relative) && $0.size == size
                      && RepairRules.normalizedETag($0.etag) == etag }
            .map(\.key).sorted().first
    }

    /// `dryRun` (S11, regola 4 di `Docs/CLAUDE.md`): fa il ricontrollo dal vivo, dice dove
    /// andrebbe la copia diversa e si ferma. Nessuna scrittura su nessun archivio, nessuna voce
    /// nel registro.
    @concurrent
    func run(_ c: RepairCandidate, dryRun: Bool = false,
             onStep: @escaping @Sendable (RepairStep) -> Void = { _ in }) async -> RepairOutcome {
        let started = now()
        var out = RepairOutcome(key: c.key, target: c.target, displayPath: c.paths[c.target] ?? "", finishedAt: started)
        out.wasDryRun = dryRun
        var rec = RepairRecord(repairId: UUID().uuidString, key: c.key, displayPath: out.displayPath,
                               target: c.target.rawValue, source: c.source.rawValue, witness: c.witness.rawValue,
                               goodSHA256: c.good.sha256, goodSize: c.good.size, badSize: c.badSize,
                               badSHA256: c.badSHA256, badETag: c.badETag, startedAt: started, outcome: .inProgress)

        func finish(_ kind: RepairOutcomeKind, step: RepairStep? = nil, _ failure: RepairFailure? = nil) -> RepairOutcome {
            out.succeeded = kind == .repaired
            out.failedStep = step
            out.failure = failure
            out.finishedAt = now()
            rec.outcome = kind
            rec.failedStep = step
            rec.detail = failure.map { "\($0)" }
            rec.finishedAt = out.finishedAt
            rec.quarantinePath = out.quarantinePath
            rec.reusedQuarantineCopy = out.reusedQuarantineCopy
            rec.afterSHA256 = out.afterSHA256
            rec.afterETag = out.afterETag
            if case .logNotWritten = failure { return out }
            if out.wasDryRun { return out }
            do { try record(rec) } catch { out.logError = error.localizedDescription }
            return out
        }

        // 1. RICONTROLLO DAL VIVO. Niente e' ancora stato toccato.
        onStep(.liveCheck)
        guard c.source == RepairRules.source(forTarget: c.target), c.witness == RepairRules.witness(forTarget: c.target),
              let srcRel = c.paths[c.source], let tgtRel = c.paths[c.target], let witRel = c.paths[c.witness],
              RepairPaths.safeComponents(tgtRel) != nil, RepairPaths.safeComponents(witRel) != nil,
              c.target != .s3 || RepairRules.cubbitKeyIsRepairable(tgtRel),
              let srcRoot = root(c.source) else {
            return finish(.failed, step: .liveCheck, .unsafePath)
        }
        guard volumeIdentity(srcRoot) != nil else { return finish(.failed, step: .liveCheck, .volumeMissing(c.source)) }
        guard let srcURL = Self.confined(srcRoot, srcRel) else { return finish(.failed, step: .liveCheck, .unsafePath) }
        guard Self.isGood(hashFile(srcURL), c.good) else { return finish(.failed, step: .liveCheck, .sourceChanged) }

        if c.witness == .s3 {
            let candidate = S3ETagMatcher.Candidate(size: c.good.size, sha256: c.good.sha256, md5: c.good.md5,
                                                    multipartETag: c.good.multipartETag,
                                                    alternativeETags: c.good.alternativeMultipartETags)
            do {
                guard let h = try await cloud.head(key: witRel), h.size == c.good.size,
                      S3ETagMatcher.verdict(etag: h.etag, size: h.size, candidates: [candidate]) == .certified(sha256: c.good.sha256)
                else { return finish(.failed, step: .liveCheck, .witnessChanged) }
            } catch {
                return finish(.failed, step: .liveCheck, .cubbitError(error.localizedDescription))
            }
        } else if let witRoot = root(c.witness) {
            guard volumeIdentity(witRoot) != nil else { return finish(.failed, step: .liveCheck, .volumeMissing(c.witness)) }
            guard let witURL = Self.confined(witRoot, witRel), Self.isGood(hashFile(witURL), c.good) else {
                return finish(.failed, step: .liveCheck, .witnessChanged)
            }
        }

        let badETag = RepairRules.normalizedETag(c.badETag)
        var target: (root: URL, device: dev_t, url: URL)? = nil
        if c.target == .s3 {
            do {
                guard let h = try await cloud.head(key: tgtRel) else { return finish(.failed, step: .liveCheck, .badCopyMissing) }
                guard badETag != nil, h.size == c.badSize, RepairRules.normalizedETag(h.etag) == badETag else {
                    return finish(.failed, step: .liveCheck, .badCopyChanged)
                }
            } catch {
                return finish(.failed, step: .liveCheck, .cubbitError(error.localizedDescription))
            }
        } else if let tgtRoot = root(c.target) {
            guard let device = volumeIdentity(tgtRoot) else { return finish(.failed, step: .liveCheck, .volumeMissing(c.target)) }
            guard let url = Self.confined(tgtRoot, tgtRel) else { return finish(.failed, step: .liveCheck, .unsafePath) }
            guard Self.itemExists(url) else { return finish(.failed, step: .liveCheck, .badCopyMissing) }
            guard case .digest(let d) = hashFile(url), d.size == c.badSize, d.sha256 == c.badSHA256 else {
                return finish(.failed, step: .liveCheck, .badCopyChanged)
            }
            target = (tgtRoot, device, url)
        }

        // CONTROLLO SENZA RIPARARE: il ricontrollo e' fatto; si dice dove andrebbe la copia diversa
        // e ci si ferma, senza scrivere niente.
        if dryRun {
            if c.target == .s3 {
                do {
                    if let existing = try await existingQuarantineCopy(of: tgtRel, size: c.badSize, etag: badETag) {
                        out.quarantinePath = existing
                        out.reusedQuarantineCopy = true
                    } else {
                        guard let fresh = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                            return finish(.failed, step: .quarantine, .unsafePath)
                        }
                        if let h = try await cloud.head(key: fresh),
                           !(h.size == c.badSize && RepairRules.normalizedETag(h.etag) == badETag) {
                            return finish(.failed, step: .quarantine, .quarantineOccupied)
                        }
                        out.quarantinePath = fresh
                    }
                } catch {
                    return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
                }
            } else if let t = target {
                guard let qRel = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                    return finish(.failed, step: .quarantine, .unsafePath)
                }
                guard !Self.itemExists(t.root.appendingPathComponent(qRel)) else {
                    return finish(.failed, step: .quarantine, .quarantineOccupied)
                }
                out.quarantinePath = qRel
            }
            return finish(.repaired)
        }

        // Il registro PRIMA di toccare qualunque archivio.
        do {
            try record(rec)
        } catch {
            return finish(.failed, step: .log, .logNotWritten(error.localizedDescription))
        }

        if c.target == .s3 {
            // 2. QUARANTENA su Cubbit: copia lato server, idempotente.
            onStep(.quarantine)
            do {
                let qKey: String
                if let existing = try await existingQuarantineCopy(of: tgtRel, size: c.badSize, etag: badETag) {
                    qKey = existing
                    out.reusedQuarantineCopy = true
                } else {
                    guard let fresh = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                        return finish(.failed, step: .quarantine, .unsafePath)
                    }
                    if let h = try await cloud.head(key: fresh) {
                        // Zero-overwrite anche in quarantena: si riusa solo se e' proprio lei.
                        guard h.size == c.badSize, RepairRules.normalizedETag(h.etag) == badETag else {
                            return finish(.failed, step: .quarantine, .quarantineOccupied)
                        }
                        out.reusedQuarantineCopy = true
                    } else {
                        try await cloud.copy(from: tgtRel, to: fresh)
                    }
                    qKey = fresh
                }
                out.quarantinePath = qKey
                guard let h = try await cloud.head(key: qKey), h.size == c.badSize,
                      RepairRules.normalizedETag(h.etag) == badETag else {
                    return finish(.failed, step: .quarantine, .quarantineCopyMismatch)
                }
            } catch {
                return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
            }

            // 3. SCRITTURA: la sola sovrascrittura del progetto.
            onStep(.write)
            do {
                try await cloud.replace(key: tgtRel, withFileAt: srcURL)
            } catch {
                return finish(.failed, step: .write, .writeFailed(error.localizedDescription))
            }

            // 4. VERIFICA FINALE: l'ETag deve essere quello della copia buona.
            onStep(.finalCheck)
            do {
                let h = try await cloud.head(key: tgtRel)
                out.afterETag = h?.etag
                guard let h, h.size == c.good.size,
                      RepairRules.normalizedETag(h.etag) == RepairRules.expectedCubbitETag(for: c.good) else {
                    return finish(.verificationFailed, step: .finalCheck, .finalCheckFailed)
                }
            } catch {
                return finish(.verificationFailed, step: .finalCheck, .cubbitError(error.localizedDescription))
            }
        } else if let t = target {
            let token = makeToken()
            guard let qRel = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar),
                  let stRel = RepairPaths.stagingPath(for: tgtRel, date: started, calendar: calendar, token: token) else {
                return finish(.failed, step: .write, .unsafePath)
            }
            let qURL = t.root.appendingPathComponent(qRel)
            let stURL = t.root.appendingPathComponent(stRel)
            let qDir = qURL.deletingLastPathComponent()

            // 2a. PREPARAZIONE della copia buona, dentro la quarantena: la foto non e' ancora toccata.
            onStep(.write)
            guard volumeIdentity(t.root) == t.device else { return finish(.failed, step: .write, .volumeMissing(c.target)) }
            guard !Self.itemExists(qURL) else { return finish(.failed, step: .write, .quarantineOccupied) }
            do {
                try FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)
            } catch {
                return finish(.failed, step: .write, .stagingFailed(error.localizedDescription))
            }
            // `createDirectory` su un disco appena sparito creerebbe la cartella sul disco del
            // Mac: dopo averla creata, deve stare sullo stesso disco e sotto la radice.
            guard volumeIdentity(qDir) == t.device, Self.isInside(qDir, root: t.root) else {
                return finish(.failed, step: .write, .unsafePath)
            }
            do {
                try copyFile(srcURL, stURL)
            } catch {
                if Self.itemExists(stURL) { out.leftoverStagingPath = stRel }
                return finish(.failed, step: .write, .stagingFailed(error.localizedDescription))
            }
            out.leftoverStagingPath = stRel
            guard Self.isGood(hashFile(stURL), c.good) else { return finish(.failed, step: .write, .stagingMismatch) }

            // 2b. QUARANTENA: la copia rovinata si sposta, sullo stesso volume.
            onStep(.quarantine)
            guard volumeIdentity(t.root) == t.device else { return finish(.failed, step: .quarantine, .volumeMissing(c.target)) }
            do {
                try renameFile(t.url, qURL)
            } catch {
                return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
            }
            out.quarantinePath = qRel

            // 3. SCRITTURA: la copia preparata al suo posto. Se fallisce, la rovinata torna dov'era.
            onStep(.write)
            do {
                try renameFile(stURL, t.url)
                out.leftoverStagingPath = nil
            } catch {
                if (try? renameFile(qURL, t.url)) != nil {
                    out.restoredOriginal = true
                    out.quarantinePath = nil
                }
                return finish(.failed, step: .write, .writeFailed(error.localizedDescription))
            }

            // 4. VERIFICA FINALE: rilettura della foto al suo posto.
            onStep(.finalCheck)
            let after = hashFile(t.url)
            if case .digest(let d) = after { out.afterSHA256 = d.sha256 }
            guard Self.isGood(after, c.good) else { return finish(.verificationFailed, step: .finalCheck, .finalCheckFailed) }
        } else {
            return finish(.failed, step: .liveCheck, .unsafePath)
        }

        // 5. REGISTRO.
        onStep(.log)
        return finish(.repaired)
    }
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh RepairEngineTests` → `Executed 37 tests, with 0 failures`; `fasttest.sh MainThreadIsolationTests` → 0 fallimenti.
- [ ] **Step 5:** `fasttest.sh`: `Executed 1127 tests` (B+104), 0 fallimenti, 0 warning.
- [ ] **Revisione obbligatoria (checklist di `Docs/CLAUDE.md`)**: nessuna `removeItem`/`moveItem`/`trashItem`; l'unica `copyItem` ha la destinazione dentro la quarantena con un nome unico; ogni `rename` passa da `renameWithoutOverwriting`; nessuna DELETE; la PUT (`replace`) arriva solo dopo una quarantena verificata con HEAD.
- [ ] **Mutanti che devono morire:** quarantena non idempotente (`existingQuarantineCopy` che restituisce sempre `nil`) (verificato: muoiono `testCubbit_quarantineCopyFromAnotherDay_isReused` e `testDryRun_onCubbit_seesTheCopyAlreadyInQuarantine`); il controllo senza riparare che prosegue (togliere `return finish(.repaired)` alla fine del blocco `if dryRun`) (verificato: muoiono i `testDryRun_…`); il controllo che scrive nel registro (togliere `if out.wasDryRun { return out }` da `finish`) (verificato: muoiono i tre `testDryRun_…` che guardano il registro); niente ritorno dopo un secondo `rename` fallito (`if false` al posto di `if (try? renameFile(qURL, t.url)) != nil`) (verificato: muore `testDisk_writeFails_theBrokenCopyGoesBack`); `renameWithoutOverwriting` senza la guardia `itemExists` (verificato: muore `testRenameWithoutOverwriting_neverOverwrites`); verifica finale su Cubbit sempre vera (verificato: muore `testCubbit_finalCheckFails_noSecondAttempt`). **Mutante equivalente, dichiarato:** togliere `h.size == c.good.size` dal controllo del testimone su Cubbit non uccide nessun test (verificato), perché `S3ETagMatcher.verdict` confronta già solo candidati della stessa dimensione: la riga resta come difesa esplicita.
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 5: motore con ricontrollo, quarantena idempotente, scrittura e verifica

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 6: i cancelli — `isRepairing` in mutua esclusione con tutto il resto

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `JobStartGate` (6779), `LibraryIndexCommandGate` (6809, 6847), `DuplicatesStatus.trashDisabledReason` (3662)/`.undoDisabledReason` (3701), `InventoryStartGate` (6366), nuovo `RepairStartGate` prima di `/// I testi della finestra Inventario` (6413); `BackupRunner`: `beginDuplicateTrashing` (10473), `beginTrashRestore` (10500) e subito dopo `isRepairing`/`beginRepair`/`endRepair`, le chiamate ai cancelli in `startTrashRestore`, `startDuplicateTrashRun`, `rebuildLibraryIndex`, `startInventoryRefresh`, `run(label:)`; viste: `LibraryIndexCard.commandsDisabledReason`, `DuplicatesView.trashDisabledReasonNow`/`undoDisabledReasonNow`, `InventoryView.startDisabledReason`.
- Create: `AppBackupFotoTests/RepairGatesTests.swift` (`FC1ACC7BA2F23A603E66A74E` / `926C7CE294F0C7B407DC2164`).
- Modify (solo firma): `JobStartGateTests`, `LibraryIndexStatusTests`, `DuplicatesStatusTests`, `InventoryRefreshTests`.

**Interfaces:**
- Produces:
  - parametro `isRepairing: Bool` **senza default**, ultimo, in `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`, `DuplicatesStatus.undoDisabledReason`; dopo `isInventorying` in `InventoryStartGate.blockedReason`
  - `enum RepairStartGate { static func blockedReason(isRunning:isIndexing:isTrashingDuplicates:isRestoringFromTrash:isInventorying:isRepairing:ssdMounted:hddMounted:hasCubbitConfig:) -> String?; static let cubbitUnreachable: String }`
  - `BackupRunner`: `@Published private(set) var isRepairing`, `func beginRepair() -> SimpleAlert?`, `func endRepair()`
- **Non cambia, con il motivo scritto accanto:** `LibraryIndexCommandGate.resetDisabledReason` (la riparazione non scrive nell'elenco: il suo registro è un file a parte); `RestoreEngine` e campione d'integrità (sola lettura, come per l'inventario).

**Precedenze.** Nei cancelli esistenti la riparazione entra subito dopo spostamento/annullamento (le operazioni più vicine al danno) e prima di inventario e lettura; in `trashDisabledReason`/`undoDisabledReason` in coda (le operazioni si escludono comunque a vicenda alla fonte). In `RepairStartGate`: un'altra riparazione > spostamento/annullamento > inventario > backup > lettura > SSD > HDD > Cubbit non configurato.

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/RepairGatesTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// La riparazione (ROADMAP #45) scrive su SSD, HDD o Cubbit: non parte durante un backup, una
/// lettura dell'elenco, un inventario, uno spostamento nel Cestino o un annullamento, e
/// viceversa. Stesso schema di `isInventorying`: parametro `isRepairing` SENZA default nei
/// cancelli esistenti, piu' `RepairStartGate` per il verso opposto.
final class RepairGatesTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum", "quarantena"]

    private func assertNoJargon(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        let t = (text ?? "").lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text ?? "")»", file: file, line: line) }
    }

    // MARK: - Verso 1: durante una riparazione non parte nient'altro

    func testJobsDoNotStart_whileRepairing() {
        let r = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                           isInventorying: false, isRepairing: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
        let others = [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: true, isRepairing: false)]
        XCTAssertFalse(others.contains(r), "una frase sua")
    }

    func testReadingTheList_doesNotStart_whileRepairing() {
        let r = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false,
                                                       isRestoringFromTrash: false, isInventorying: false, isRepairing: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testTrashing_doesNotStart_whileRepairing() {
        let r = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                     isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                     isInventorying: false, isRepairing: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testUndo_doesNotStart_whileRepairing() {
        let summary = RestorableBatchSummary(pendingCount: 1, batchCount: 1, trashedAt: Date())
        let r = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                    isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                    summary: summary, hasEverTrashed: true,
                                                    isInventorying: false, isRepairing: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testInventory_doesNotStart_whileRepairing() {
        let r = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                 isRestoringFromTrash: false, isInventorying: false, isRepairing: true,
                                                 ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    /// Un'operazione in corso viene prima dei dischi scollegati anche per l'inventario.
    func testInventory_repairComesBeforeMissingDisks() {
        let r = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                 isRestoringFromTrash: false, isInventorying: false, isRepairing: true,
                                                 ssdMounted: false, hddMounted: false, hasCubbitConfig: false)
        XCTAssertTrue(r?.contains("riparando") == true)
    }

    // MARK: - Verso 2: «Ripara…» non parte durante le altre operazioni

    private func repair(isRunning: Bool = false, isIndexing: Bool = false, isTrashingDuplicates: Bool = false,
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false, isRepairing: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
        RepairStartGate.blockedReason(isRunning: isRunning, isIndexing: isIndexing,
                                      isTrashingDuplicates: isTrashingDuplicates,
                                      isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                      isRepairing: isRepairing, ssdMounted: ssdMounted, hddMounted: hddMounted,
                                      hasCubbitConfig: hasCubbitConfig)
    }

    func testRepair_canStart_whenNothingIsInTheWay() {
        XCTAssertNil(repair())
    }

    func testRepair_eachConditionBlocksWithItsOwnReason() {
        let all = [repair(isRunning: true), repair(isIndexing: true), repair(isTrashingDuplicates: true),
                   repair(isRestoringFromTrash: true), repair(isInventorying: true), repair(isRepairing: true),
                   repair(ssdMounted: false), repair(hddMounted: false), repair(hasCubbitConfig: false)]
        XCTAssertTrue(all.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(all.compactMap { $0 }).count, all.count, "nove motivi, nove frasi diverse")
        for r in all + [RepairStartGate.cubbitUnreachable] { assertNoJargon(r) }
        XCTAssertTrue(repair(ssdMounted: false)!.contains("SSD"))
        XCTAssertTrue(repair(hddMounted: false)!.contains("HDD"))
    }

    /// Precedenza: un'altra riparazione prima di tutto, le operazioni prima dei dischi.
    func testRepair_precedence() {
        XCTAssertEqual(repair(isRunning: true, isTrashingDuplicates: true, isRepairing: true), repair(isRepairing: true))
        XCTAssertEqual(repair(isRunning: true, isInventorying: true), repair(isInventorying: true))
        XCTAssertEqual(repair(isRunning: true, ssdMounted: false), repair(isRunning: true))
        XCTAssertEqual(repair(ssdMounted: false, hddMounted: false), repair(ssdMounted: false))
        XCTAssertEqual(repair(hddMounted: false, hasCubbitConfig: false), repair(hddMounted: false))
    }
}
```

Registralo nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh RepairGatesTests` → `COMPILAZIONE TEST FALLITA` con `extra argument 'isRepairing' in call`.

- [ ] **Step 3: implementa.** Ventitré sostituzioni.

**3a. `JobStartGate`** — firma, motivo, chiamata in `run(label:)`.

Trova (deve comparire **una sola volta**):

```swift
    static func blockedReason(isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool) -> String? {
```

Sostituisci con:

```swift
    static func blockedReason(isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
            return "L'app sta rimettendo a posto le foto che avevi spostato nel Cestino. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        // ROADMAP #44
```

Sostituisci con:

```swift
            return "L'app sta rimettendo a posto le foto che avevi spostato nel Cestino. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        // ROADMAP #45: la riparazione scrive su SSD, HDD o Cubbit; un job che copia negli
        // stessi posti nello stesso momento potrebbe copiare la foto a meta' riparazione.
        if isRepairing {
            return "L'app sta riparando una foto. Aspetta che finisca: di solito bastano pochi secondi."
        }
        // ROADMAP #44
```

Trova (deve comparire **una sola volta**):

```swift
        if let reason = JobStartGate.blockedReason(isIndexing: isIndexing,
                                                    isTrashingDuplicates: isTrashingDuplicates,
                                                    isRestoringFromTrash: isRestoringFromTrash,
                                                    isInventorying: isInventorying) {
```

Sostituisci con:

```swift
        if let reason = JobStartGate.blockedReason(isIndexing: isIndexing,
                                                    isTrashingDuplicates: isTrashingDuplicates,
                                                    isRestoringFromTrash: isRestoringFromTrash,
                                                    isInventorying: isInventorying,
                                                    isRepairing: isRepairing) {
```

**3b. `LibraryIndexCommandGate`** — firma, motivo, nota su `resetDisabledReason`, chiamate in `rebuildLibraryIndex` e nella card.

Trova (deve comparire **una sola volta**):

```swift
    static func disabledReason(isIndexing: Bool, jobIsRunning: Bool,
                               isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                               isInventorying: Bool) -> String? {
```

Sostituisci con:

```swift
    static func disabledReason(isIndexing: Bool, jobIsRunning: Bool,
                               isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                               isInventorying: Bool, isRepairing: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
            return "L'app sta rimettendo a posto le foto spostate nel Cestino: leggere le foto "
                + "adesso darebbe un elenco sbagliato. Riprova quando ha finito."
        }
```

Sostituisci con:

```swift
            return "L'app sta rimettendo a posto le foto spostate nel Cestino: leggere le foto "
                + "adesso darebbe un elenco sbagliato. Riprova quando ha finito."
        }
        if isRepairing {
            return "L'app sta riparando una foto: leggere le foto adesso potrebbe trovarla a metà. "
                + "Riprova quando ha finito."
        }
```

Trova (deve comparire **una sola volta**):

```swift
    static func resetDisabledReason(isIndexing: Bool, jobIsRunning: Bool,
                                    isTrashingDuplicates: Bool, isInventorying: Bool) -> String? {
```

Sostituisci con:

```swift
    /// Non guarda la riparazione (ROADMAP #45), di proposito: la riparazione non scrive in
    /// questo elenco (il suo registro e' un file a parte) e non lo legge mentre lavora.
    static func resetDisabledReason(isIndexing: Bool, jobIsRunning: Bool,
                                    isTrashingDuplicates: Bool, isInventorying: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
        if let reason = LibraryIndexCommandGate.disabledReason(isIndexing: isIndexing,
                                                              jobIsRunning: isRunning,
                                                              isTrashingDuplicates: isTrashingDuplicates,
                                                              isRestoringFromTrash: isRestoringFromTrash,
                                                              isInventorying: isInventorying) {
```

Sostituisci con:

```swift
        if let reason = LibraryIndexCommandGate.disabledReason(isIndexing: isIndexing,
                                                              jobIsRunning: isRunning,
                                                              isTrashingDuplicates: isTrashingDuplicates,
                                                              isRestoringFromTrash: isRestoringFromTrash,
                                                              isInventorying: isInventorying,
                                                              isRepairing: isRepairing) {
```

Trova (deve comparire **una sola volta**):

```swift
        LibraryIndexCommandGate.disabledReason(isIndexing: runner.isIndexing,
                                               jobIsRunning: runner.isRunning,
                                               isTrashingDuplicates: runner.isTrashingDuplicates,
                                               isRestoringFromTrash: runner.isRestoringFromTrash,
                                               isInventorying: runner.isInventorying)
```

Sostituisci con:

```swift
        LibraryIndexCommandGate.disabledReason(isIndexing: runner.isIndexing,
                                               jobIsRunning: runner.isRunning,
                                               isTrashingDuplicates: runner.isTrashingDuplicates,
                                               isRestoringFromTrash: runner.isRestoringFromTrash,
                                               isInventorying: runner.isInventorying,
                                               isRepairing: runner.isRepairing)
```

**3c. `DuplicatesStatus.trashDisabledReason`** — firma, motivo, chiamate in `startDuplicateTrashRun` e in `DuplicatesView`.

Trova (deve comparire **una sola volta**):

```swift
    static func trashDisabledReason(isRunning: Bool, isIndexing: Bool, ssdMounted: Bool,
                                    isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                                    isInventorying: Bool) -> String? {
```

Sostituisci con:

```swift
    static func trashDisabledReason(isRunning: Bool, isIndexing: Bool, ssdMounted: Bool,
                                    isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                                    isInventorying: Bool, isRepairing: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit: aspetta che finisca "
                + "prima di spostare copie nel Cestino."
        }
        return nil
    }
```

Sostituisci con:

```swift
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit: aspetta che finisca "
                + "prima di spostare copie nel Cestino."
        }
        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di spostare copie nel Cestino."
        }
        return nil
    }
```

Trova (deve comparire **una sola volta**):

```swift
                                                           isRestoringFromTrash: isRestoringFromTrash,
                                                           isInventorying: isInventorying)
        if let reason {
```

Sostituisci con:

```swift
                                                           isRestoringFromTrash: isRestoringFromTrash,
                                                           isInventorying: isInventorying,
                                                           isRepairing: isRepairing)
        if let reason {
```

Trova (deve comparire **una sola volta**):

```swift
                                             isRestoringFromTrash: runner.isRestoringFromTrash,
                                             isInventorying: runner.isInventorying)
    }
```

Sostituisci con:

```swift
                                             isRestoringFromTrash: runner.isRestoringFromTrash,
                                             isInventorying: runner.isInventorying,
                                             isRepairing: runner.isRepairing)
    }
```

**3d. `DuplicatesStatus.undoDisabledReason`** — firma, motivo, chiamate in `startTrashRestore` e in `DuplicatesView`.

Trova (deve comparire **una sola volta**):

```swift
                                   summary: RestorableBatchSummary?, hasEverTrashed: Bool,
                                   isInventorying: Bool) -> String? {
```

Sostituisci con:

```swift
                                   summary: RestorableBatchSummary?, hasEverTrashed: Bool,
                                   isInventorying: Bool, isRepairing: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
            return "L'app sta facendo l'inventario: aspetta che finisca prima di annullare lo "
                + "spostamento."
        }
```

Sostituisci con:

```swift
            return "L'app sta facendo l'inventario: aspetta che finisca prima di annullare lo "
                + "spostamento."
        }
        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di annullare lo spostamento."
        }
```

Trova (deve comparire **una sola volta**):

```swift
                                                             summary: restorableBatch, hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0,
                                                             isInventorying: isInventorying) {
```

Sostituisci con:

```swift
                                                             summary: restorableBatch, hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0,
                                                             isInventorying: isInventorying, isRepairing: isRepairing) {
```

Trova (deve comparire **una sola volta**):

```swift
            summary: runner.restorableBatch, hasEverTrashed: (runner.trashManifestStore?.totalRecorded ?? 0) > 0,
            isInventorying: runner.isInventorying)
```

Sostituisci con:

```swift
            summary: runner.restorableBatch, hasEverTrashed: (runner.trashManifestStore?.totalRecorded ?? 0) > 0,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing)
```

**3e. `InventoryStartGate`** — firma, motivo, chiamate in `startInventoryRefresh` e in `InventoryView`.

Trova (deve comparire **una sola volta**):

```swift
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
```

Sostituisci con:

```swift
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
```

Trova (deve comparire **una sola volta**):

```swift
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
```

Sostituisci con:

```swift
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
        if isRepairing {
            return "L'app sta riparando una foto: aspetta che finisca, poi aggiorna l'inventario per "
                + "confermare la riparazione."
        }
```

Trova (deve comparire **una sola volta**):

```swift
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
```

Sostituisci con:

```swift
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
```

Trova (deve comparire **una sola volta**):

```swift
            isInventorying: runner.isInventorying, ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)
```

Sostituisci con:

```swift
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)
```

**3f. `RepairStartGate`**, subito prima di `InventoryStatus`.

Trova (deve comparire **una sola volta**):

```swift
/// I testi della finestra Inventario. Logica pura, come `DuplicatesStatus`: nessuna stringa
/// nasce dentro la View.
```

Sostituisci con:

```swift
/// Perche' «Ripara…» non puo' partire adesso, `nil` se puo' (ROADMAP #45). Il verso opposto
/// (niente backup, lettura dell'elenco, inventario, spostamento o annullamento durante una
/// riparazione) sta nei cancelli di quelle operazioni, col parametro `isRepairing`. Precedenza
/// scritta a parole: un'altra riparazione > spostamento/annullamento > inventario > backup >
/// lettura dell'elenco > dischi non collegati > Cubbit non configurato.
enum RepairStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
        if isRepairing { return "C'è già una riparazione in corso: le foto si riparano una alla volta." }
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino delle copie doppie: aspetta che finisca."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca."
        }
        if isInventorying {
            return "L'inventario si sta aggiornando: aspetta che finisca, poi ripara."
        }
        if isRunning {
            return "C'è un backup in corso: aspetta che finisca, altrimenti la riparazione scriverebbe "
                + "mentre il backup copia."
        }
        if isIndexing {
            return "L'app sta aggiornando l'elenco delle foto sull'SSD: aspetta che finisca."
        }
        if !ssdMounted {
            return "L'SSD non è collegato: per riparare una foto servono SSD, HDD e Cubbit insieme."
        }
        if !hddMounted {
            return "L'HDD non è collegato: per riparare una foto servono SSD, HDD e Cubbit insieme."
        }
        if !hasCubbitConfig {
            return "L'app non ha letto le credenziali di Cubbit: controlla in Diagnostica, poi riprova."
        }
        return nil
    }

    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."
}

/// I testi della finestra Inventario. Logica pura, come `DuplicatesStatus`: nessuna stringa
/// nasce dentro la View.
```

**3g. `BackupRunner`: le due guardie esistenti e `isRepairing`/`beginRepair`/`endRepair`.**

Trova (deve comparire **una sola volta**):

```swift
        guard !isTrashingDuplicates, !isRunning, !isIndexing, !isRestoringFromTrash, !isInventorying else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, un altro spostamento nel Cestino o un annullamento). "
                    + "Aspetta che finisca.")
        }
        isTrashingDuplicates = true
```

Sostituisci con:

```swift
        guard !isTrashingDuplicates, !isRunning, !isIndexing, !isRestoringFromTrash, !isInventorying,
              !isRepairing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, una riparazione, un altro spostamento nel Cestino o "
                    + "un annullamento). Aspetta che finisca.")
        }
        isTrashingDuplicates = true
```

Trova (deve comparire **una sola volta**):

```swift
        guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing, !isInventorying else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, uno spostamento nel Cestino o un altro annullamento). "
                    + "Aspetta che finisca.")
        }
        isRestoringFromTrash = true
        return nil
    }
```

Sostituisci con:

```swift
        guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing, !isInventorying,
              !isRepairing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, una riparazione, uno spostamento nel Cestino o un "
                    + "altro annullamento). Aspetta che finisca.")
        }
        isRestoringFromTrash = true
        return nil
    }

    /// Vero mentre una riparazione scrive su SSD, HDD o Cubbit (ROADMAP #45, ADR-0016). Vive QUI
    /// e non in uno `@State` di `InventoryView`, per la stessa ragione di `isTrashingDuplicates`:
    /// riaprire la finestra non deve permettere una seconda riparazione in parallelo, ne' un
    /// backup, una lettura, un inventario, uno spostamento o un annullamento.
    @Published private(set) var isRepairing = false

    /// Prova ad avviare una riparazione: rifiuta se c'e' gia' un'altra operazione in corso,
    /// altrimenti alza il flag. Controllo e impostazione sono atomici: entrambi sul MainActor.
    func beginRepair() -> SimpleAlert? {
        guard !isRepairing, !isTrashingDuplicates, !isRestoringFromTrash, !isInventorying, !isRunning,
              !isIndexing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura dell'elenco, "
                    + "un inventario, uno spostamento nel Cestino, un annullamento o un'altra "
                    + "riparazione). Aspetta che finisca.")
        }
        isRepairing = true
        return nil
    }

    /// Chiamato SEMPRE dall'unico punto in cui una riparazione finisce (`finishRepair`).
    func endRepair() {
        isRepairing = false
    }
```

- [ ] **Step 4: aggiorna le chiamate nei test esistenti (solo la firma).** Dalla radice del repository:

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFotoTests
# Aggiunge ", isRepairing: false" dopo l'ultimo argomento dei quattro cancelli; NON tocca
# resetDisabledReason (dove isInventorying segue direttamente isTrashingDuplicates).
for f in JobStartGateTests.swift LibraryIndexStatusTests.swift DuplicatesStatusTests.swift; do
  perl -0pi -e 's/(?<!isTrashingDuplicates: true, )(?<!isTrashingDuplicates: false, )isInventorying: (true|false)\)/isInventorying: $1, isRepairing: false)/g' $f
done
grep -c 'isRepairing: false)' JobStartGateTests.swift LibraryIndexStatusTests.swift DuplicatesStatusTests.swift
# atteso: 21, 15, 30
grep -c 'resetDisabledReason.*isRepairing' LibraryIndexStatusTests.swift      # atteso: 0
```

e in `InventoryRefreshTests.swift`, nell'aiuto `reason(...)`:

```swift
// Trova:
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
// Sostituisci con:
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false, isRepairing: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
```

```swift
// Trova:
                                         isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                         ssdMounted: ssdMounted
// Sostituisci con:
                                         isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                         isRepairing: isRepairing,
                                         ssdMounted: ssdMounted
```

`git diff --stat AppBackupFotoTests/` deve mostrare solo righe cambiate nelle chiamate (nessuna `XCTAssert…` toccata).

- [ ] **Step 5: esegui i test.** `fasttest.sh RepairGatesTests` → `Executed 9 tests, with 0 failures`; `JobStartGateTests`, `LibraryIndexStatusTests`, `DuplicatesStatusTests`, `InventoryRefreshTests` → 0 fallimenti, stessi conteggi di prima.
- [ ] **Step 6:** `fasttest.sh`: `Executed 1136 tests` (B+113), 0 fallimenti, 0 warning. **Punto di controllo `xcodebuild`** (in background): build pulita 0 warning, `Executed 1136 tests`.
- [ ] **Mutanti che devono morire:** togliere il ramo `if isRepairing` da `JobStartGate` (verificato: muore `testJobsDoNotStart_whileRepairing`); spostare `if isRepairing` di `InventoryStartGate` dopo i dischi (muore `testInventory_repairComesBeforeMissingDisks`); in `RepairStartGate` mettere `isRunning` prima di `isInventorying` (muore `testRepair_precedence`).
- [ ] **Step 7: commit.**
  ```
  Riparazione, task 6: isRepairing in mutua esclusione con backup, elenco, inventario, Cestino

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 7: i testi della riparazione e le voci riparabili nel riepilogo dell'inventario

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `InventorySummary` (6258-6290), `InventoryStatus.readOnlyNote` (6429), regione R dopo il blocco del Task 5.
- Create: `AppBackupFotoTests/RepairStatusTests.swift` (`26950E0DF441DE580320805F` / `A446EC617D35A9FB526D0C58`).

**Interfaces:**
- Produces:
  - `InventorySummary.repairCandidates: [RepairCandidate]` (calcolato nell'`init`, fuori dal main come il resto del riepilogo; firma dell'`init` invariata)
  - `enum RepairStatus` (non `nonisolated`, come `InventoryStatus`): `buttonTitle`, `continueButton`, `cancelButton`, `confirmTitle`, `confirmButton`, `summaryTitle`, `dryRunButton`, `sectionExplanation`, `sectionTitle(count:)`, `candidateLine(_:)`, `summaryLines(_:date:calendar:)`, `confirmMessage(_:)`, `progressLine(_:)`, `awaitingConfirmation(_:records:states:) -> RepairRecord?`, `repairedLine(_:calendar:)`, `failureText(_:)`, `outcomeLines(_:) -> [InventoryStatus.Line]`
  - `InventoryStatus.readOnlyNote`: testo nuovo (S8)

**«Riparata il …».** `awaitingConfirmation` restituisce la riparazione riuscita più recente di quella voce (stessa chiave, stesso archivio) **conclusa dopo l'inizio dell'ultimo inventario**: è quella che la finestra mostra al posto di «Ripara…». Il giro successivo dell'inventario la conferma (la voce sparisce da ❗) o la smentisce (la voce ricompare con «Ripara…»).

- [ ] **Step 1: test che falliscono.** Crea `AppBackupFotoTests/RepairStatusTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

/// I testi della riparazione (ROADMAP #45): tutti in `RepairStatus`, nessuno nella View, niente
/// gergo, e ogni esito dice dove sta ogni copia.
final class RepairStatusTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum", "staging", "rename"]
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let q = "_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let today = Date(timeIntervalSince1970: 1_791_115_200)
    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text)»", file: file, line: line) }
    }

    private func candidate(_ target: InventoryArchive) -> RepairCandidate {
        RepairCandidate(key: normalizedIndexKey(path), target: target, source: RepairRules.source(forTarget: target),
                        witness: RepairRules.witness(forTarget: target), paths: [.ssd: path, .hdd: path, .s3: path],
                        good: ContentDigest(size: 10, sha256: "s", md5: "m", multipartETag: nil),
                        badSize: 10, badSHA256: target == .s3 ? nil : "b", badETag: target == .s3 ? "\"b\"" : nil)
    }

    private func outcome(_ target: InventoryArchive, _ edit: (inout RepairOutcome) -> Void) -> RepairOutcome {
        var o = RepairOutcome(key: normalizedIndexKey(path), target: target, displayPath: path, finishedAt: today)
        edit(&o)
        return o
    }

    private func state(startedAt: Double) -> [InventoryArchive: InventoryArchiveState] {
        Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, InventoryArchiveState(archive: $0, runId: 1, complete: true, reason: nil, unreadable: 0,
                                       startedAt: startedAt, finishedAt: startedAt + 60))
        })
    }

    private func record(_ target: String, _ outcome: RepairOutcomeKind, finishedAt: Date) -> RepairRecord {
        RepairRecord(repairId: UUID().uuidString, key: normalizedIndexKey(path), displayPath: path, target: target,
                     source: "ssd", witness: "hdd", goodSHA256: "s", goodSize: 10, badSize: 10,
                     startedAt: finishedAt.addingTimeInterval(-5), finishedAt: finishedAt, outcome: outcome)
    }

    // MARK: - Voce e riepilogo

    func testCandidateLine_saysWhereItDiffersAndWhereItAgrees() {
        XCTAssertEqual(RepairStatus.candidateLine(candidate(.s3)), "«\(path)» — diversa su Cubbit; uguale sull'SSD e sull'HDD")
        XCTAssertEqual(RepairStatus.candidateLine(candidate(.ssd)), "«\(path)» — diversa sull'SSD; uguale sull'HDD e su Cubbit")
    }

    func testSectionTitle_plural() {
        XCTAssertEqual(RepairStatus.sectionTitle(count: 1), "1 foto si può riparare")
        XCTAssertTrue(RepairStatus.sectionTitle(count: 3).hasPrefix("3 foto si possono"))
    }

    /// Il riepilogo nomina la quarantena esatta di oggi, la sorgente, e cosa non tocca.
    func testSummary_forCubbit() {
        let lines = RepairStatus.summaryLines(candidate(.s3), date: today, calendar: rome)
        let all = lines.joined(separator: "\n")
        XCTAssertTrue(lines[0].contains(path))
        XCTAssertTrue(all.contains("Su Cubbit la copia è diversa"))
        XCTAssertTrue(all.contains("«\(q)»"))
        XCTAssertTrue(all.contains("carica la copia sull'SSD"))
        XCTAssertTrue(all.contains("non viene cancellata"))
        XCTAssertTrue(all.contains("Non viene toccato nient'altro"))
        lines.forEach { assertNoJargon($0) }
    }

    func testSummary_forADisk() {
        let all = RepairStatus.summaryLines(candidate(.ssd), date: today, calendar: rome).joined(separator: "\n")
        XCTAssertTrue(all.contains("Sull'SSD la copia è diversa"))
        XCTAssertTrue(all.contains("spostata sull'SSD stesso, in «\(q)»"))
        XCTAssertTrue(all.contains("copia quella sull'HDD"))
        assertNoJargon(all)
    }

    func testConfirmMessage() {
        let m = RepairStatus.confirmMessage(candidate(.s3))
        XCTAssertTrue(m.contains("su Cubbit") && m.contains("sull'SSD") && m.contains("_quarantena"))
        assertNoJargon(m)
    }

    func testProgressLines_areAllDifferent_andPlain() {
        let lines = [nil, RepairStep.liveCheck, .quarantine, .write, .finalCheck, .log].map { RepairStatus.progressLine($0) }
        XCTAssertEqual(Set(lines).count, lines.count)
        lines.forEach { assertNoJargon($0) }
    }

    // MARK: - «Riparata il …»

    func testAwaitingConfirmation_onlyForASuccessAfterTheLastInventory() {
        let c = candidate(.s3)
        let states = state(startedAt: today.timeIntervalSince1970 - 3600)
        let after = record("s3", .repaired, finishedAt: today)
        XCTAssertEqual(RepairStatus.awaitingConfirmation(c, records: [after], states: states), after)
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [after], states: state(startedAt: today.timeIntervalSince1970 + 60)),
                     "un inventario fatto dopo la riparazione la conferma (o la smentisce) da solo")
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("s3", .failed, finishedAt: today)], states: states))
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("s3", .verificationFailed, finishedAt: today)], states: states))
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("hdd", .repaired, finishedAt: today)], states: states))
    }

    func testAwaitingConfirmation_takesTheLatest() {
        let c = candidate(.s3)
        let older = record("s3", .repaired, finishedAt: today.addingTimeInterval(-60))
        let newer = record("s3", .repaired, finishedAt: today)
        XCTAssertEqual(RepairStatus.awaitingConfirmation(c, records: [newer, older], states: state(startedAt: 0)), newer)
    }

    func testRepairedLine() {
        XCTAssertEqual(RepairStatus.repairedLine(record("s3", .repaired, finishedAt: today), calendar: rome),
                       "Riparata il 4 ottobre 2026: aggiorna l'inventario per confermarlo.")
    }

    // MARK: - Esiti

    func testSuccess_saysWhereTheDifferentCopyIs_andToRefresh() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q })
        XCTAssertEqual(lines.map(\.id), ["repair-done", "repair-confirm"])
        XCTAssertTrue(lines[0].text.contains("riparata su Cubbit"))
        XCTAssertTrue(lines[0].text.contains(q))
        XCTAssertTrue(lines[1].text.contains("Aggiorna l'inventario"))
    }

    func testSuccess_withAQuarantineCopyAlreadyThere_saysSo() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.reusedQuarantineCopy = true })
        XCTAssertTrue(lines[0].text.contains("era già da parte"))
    }

    func testEveryFailure_hasItsOwnPlainSentence() {
        let all: [RepairFailure] = [.volumeMissing(.ssd), .volumeMissing(.hdd), .unsafePath, .sourceChanged, .witnessChanged,
                                    .badCopyMissing, .badCopyChanged, .cubbitError("x"), .logNotWritten("x"),
                                    .quarantineOccupied, .quarantineFailed("x"), .quarantineCopyMismatch,
                                    .stagingFailed("x"), .stagingMismatch, .writeFailed("x"), .finalCheckFailed]
        let texts = all.map { RepairStatus.failureText($0) }
        XCTAssertEqual(Set(texts).count, texts.count)
        texts.forEach { assertNoJargon($0) }
        XCTAssertFalse(RepairStatus.failureText(.cubbitError("SignatureDoesNotMatch")).contains("Signature"),
                       "il dettaglio tecnico va nel registro, non a schermo")
    }

    func testLiveCheckFailure_saysNothingWasTouched() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .liveCheck; $0.failure = .badCopyChanged })
        XCTAssertEqual(lines.map(\.id), ["repair-failed", "repair-why", "repair-state"])
        XCTAssertEqual(lines[2].text, "Non è stato toccato niente.")
    }

    func testDiskWriteFailure_withTheCopyPutBack_saysAllIsAsBefore() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) {
            $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.restoredOriginal = true
            $0.leftoverStagingPath = q + ".in-arrivo-1a2b3c4d"
        })
        XCTAssertTrue(lines.contains { $0.text.contains("com'era prima") })
        XCTAssertTrue(lines.contains { $0.id == "repair-staging" && $0.text.contains(".in-arrivo-1a2b3c4d") })
    }

    func testDiskWriteFailure_withoutPuttingItBack_saysWhereBothCopiesAre() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) {
            $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q
            $0.leftoverStagingPath = q + ".in-arrivo-1a2b3c4d"
        })
        let state = lines.first { $0.id == "repair-state" }?.text ?? ""
        XCTAssertTrue(state.contains(q) && state.contains("non è andata persa") && state.contains("non c'è niente"))
        XCTAssertTrue(lines.contains { $0.id == "repair-staging" })
    }

    func testCubbitUploadFailure_saysTheBrokenCopyIsStillThere() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q })
        XCTAssertEqual(lines.first { $0.id == "repair-state" }?.text,
                       "Su Cubbit la copia diversa è ancora al suo posto, e una copia è anche in «\(q)».")
    }

    func testFinalCheckFailure_saysNoSecondAttempt() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .finalCheck; $0.failure = .finalCheckFailed; $0.quarantinePath = q })
        let state = lines.first { $0.id == "repair-state" }?.text ?? ""
        XCTAssertTrue(state.contains("non riprova da sola") && state.contains(q))
    }

    func testLogError_isAlwaysSaid() {
        let ok = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.logError = "x" })
        XCTAssertEqual(ok.last?.id, "repair-log")
        XCTAssertEqual(ok.last?.tone, .warning)
    }

    func testDryRun_success_saysNothingWasTouched_andWhereItWouldGo() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.wasDryRun = true; $0.succeeded = true; $0.quarantinePath = q })
        XCTAssertEqual(lines.map(\.id), ["dry-ok", "dry-where"])
        XCTAssertTrue(lines[0].text.contains("non è stato toccato niente"))
        XCTAssertTrue(lines[1].text.contains(q) && lines[1].text.contains("andrebbe"))
        let reused = RepairStatus.outcomeLines(outcome(.s3) {
            $0.wasDryRun = true; $0.succeeded = true; $0.quarantinePath = q; $0.reusedQuarantineCopy = true
        })
        XCTAssertTrue(reused[1].text.contains("già da parte"))
        (lines + reused).forEach { assertNoJargon($0.text) }
    }

    func testDryRun_failure_saysWhy() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) { $0.wasDryRun = true; $0.failedStep = .liveCheck; $0.failure = .badCopyChanged })
        XCTAssertEqual(lines.map(\.id), ["dry-failed", "repair-why"])
        XCTAssertTrue(lines[0].text.contains("non è stato toccato niente"))
    }

    func testAllOutcomeTexts_arePlain() {
        let outcomes = [outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.logError = "x" },
                        outcome(.hdd) { $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q; $0.leftoverStagingPath = q + ".in-arrivo-1" }]
        for o in outcomes { RepairStatus.outcomeLines(o).forEach { assertNoJargon($0.text) } }
    }

    /// La nota in testa alla finestra non dice piu' «guarda soltanto» senza dire di «Ripara…».
    func testReadOnlyNote_mentionsTheOnlyWritingButton() {
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(RepairStatus.buttonTitle))
    }

    /// Il riepilogo dell'inventario porta con se' le voci riparabili, calcolate dallo stesso snapshot.
    func testInventorySummary_carriesTheRepairCandidates() {
        func file(_ c: Character) -> InventoryLocalFile {
            InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1, status: .ok,
                               digest: ContentDigest(size: 10, sha256: "sha-\(c)", md5: String(repeating: c, count: 32),
                                                     multipartETag: nil), hashedAt: 2)
        }
        let s3 = InventoryS3Object(key: normalizedIndexKey(path), displayKey: path, size: 10,
                                   etag: "\"\(String(repeating: "b", count: 32))\"")
        let snapshot = InventorySnapshot(ssd: [file("a")], hdd: [file("a")], s3: [s3], states: state(startedAt: 0))
        let summary = InventorySummary(snapshot, sampleLimit: 10)
        XCTAssertEqual(summary.repairCandidates.map(\.target), [.s3])
        XCTAssertEqual(summary.count(.toCheck), 2, "le due voci restano in ❗ fino al prossimo giro")
    }
}
```

Registralo nel pbxproj.

- [ ] **Step 2: esegui e verifica che falliscano.** `fasttest.sh RepairStatusTests` → `COMPILAZIONE TEST FALLITA` con `cannot find 'RepairStatus' in scope`.

- [ ] **Step 3: implementa.** Quattro sostituzioni.

**3a. `InventorySummary`: il campo e il calcolo.**

Trova (deve comparire **una sola volta**):

```swift
    let counts: [InventoryCategory: Int]
    let bytes: [InventoryCategory: Int64]
    let samples: [InventoryCategory: [InventoryItem]]

    init(_ snapshot: InventorySnapshot, sampleLimit: Int) {
```

Sostituisci con:

```swift
    let counts: [InventoryCategory: Int]
    let bytes: [InventoryCategory: Int64]
    let samples: [InventoryCategory: [InventoryItem]]
    /// Le voci in ❗ che si possono riparare con la regola «2 su 3» (ROADMAP #45). Tutte, non
    /// un campione: sono poche (oggi una), e ognuna ha il suo «Ripara…».
    let repairCandidates: [RepairCandidate]

    init(_ snapshot: InventorySnapshot, sampleLimit: Int) {
```

Trova (deve comparire **una sola volta**):

```swift
        self.states = snapshot.states
        self.stats = stats
        self.counts = counts
        self.bytes = bytes
        self.samples = samples
    }
```

Sostituisci con:

```swift
        self.states = snapshot.states
        self.stats = stats
        self.counts = counts
        self.bytes = bytes
        self.samples = samples
        self.repairCandidates = RepairRules.candidates(in: snapshot)
    }
```

**3b. La nota in testa alla finestra (S8).**

Trova (deve comparire **una sola volta**):

```swift
    static let readOnlyNote = "Questa finestra guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit."
```

Sostituisci con:

```swift
    static let readOnlyNote = "L'inventario guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit. L'unica cosa che da qui può scrivere è "
        + "«Ripara…», una foto alla volta e solo dopo la tua conferma."
```

**3c. `RepairStatus`.**

Inserisci **subito prima** della riga `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (si trova con `grep -n "MARK: - Testi e regole della card" AppBackupFoto/ContentView.swift`):

```swift
// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)

/// I testi della riparazione nella finestra Inventario. Logica pura, come `InventoryStatus`:
/// nessuna stringa nasce dentro la View. Registro: niente gergo («hash», «impronta», «ETag»,
/// «MD5», «bucket»...). La cartella «_quarantena» si nomina, tra virgolette: e' quella che
/// Enrico vedra' nel Finder e svuotera' lui (decisione 4 della spec).
enum RepairStatus {
    static let buttonTitle = "Ripara…"
    static let continueButton = "Continua…"
    static let cancelButton = "Annulla"
    static let confirmTitle = "Riparare questa foto?"
    static let confirmButton = "Ripara"
    static let summaryTitle = "Riparazione di una foto"
    /// Il controllo senza riparare (S11): rilegge e ricontrolla, non scrive niente.
    static let dryRunButton = "Controlla senza riparare"

    static func sectionTitle(count: Int) -> String {
        count == 1 ? "1 foto si può riparare" : "\(count.formatted()) foto si possono riparare"
    }

    static let sectionExplanation = "Per ognuna, due posti su tre hanno la stessa copia integra e il terzo una "
        + "copia diversa. L'app può rimettere a posto la copia diversa, una foto alla volta: prima ricontrolla "
        + "tutto, poi mette da parte la copia diversa senza cancellarla."

    static func candidateLine(_ c: RepairCandidate) -> String {
        "«\(c.paths[c.target] ?? c.key)» — diversa \(on(c.target)); uguale \(on(c.source)) e \(on(c.witness))"
    }

    /// Il riepilogo prima della conferma: cosa e' diverso, cosa l'app ricontrolla, dove va la
    /// copia diversa, cosa scrive al suo posto, cosa non tocca.
    static func summaryLines(_ c: RepairCandidate, date: Date, calendar: Calendar) -> [String] {
        let path = c.paths[c.target] ?? c.key
        let q = RepairPaths.quarantinePath(for: path, date: date, calendar: calendar) ?? "«\(RepairPaths.quarantineFolder)»"
        var lines = ["Foto: «\(path)»."]
        lines.append("\(capitalized(on(c.target))) la copia è diversa da quella \(on(c.source)) e da quella "
                     + "\(on(c.witness)), che sono identiche fra loro.")
        lines.append("Prima di toccare qualcosa l'app rilegge per intero la copia \(on(c.source)), ricontrolla "
                     + "quella \(on(c.witness)) e quella \(on(c.target)): se anche una sola non è più com'era "
                     + "nell'ultimo inventario, si ferma senza toccare niente.")
        if c.target == .s3 {
            lines.append("La copia diversa non viene cancellata: viene messa da parte su Cubbit, in «\(q)». Se "
                         + "era già stata messa da parte un altro giorno, l'app usa quella.")
            lines.append("Al suo posto l'app carica la copia \(on(c.source)), poi controlla che Cubbit abbia "
                         + "proprio quella.")
        } else {
            lines.append("La copia diversa non viene cancellata: viene spostata \(on(c.target)) stesso, in «\(q)».")
            lines.append("Al suo posto l'app copia quella \(on(c.source)), la rilegge e controlla che sia identica.")
        }
        lines.append("Non viene toccato nient'altro. La cartella «\(RepairPaths.quarantineFolder)» la svuoti tu, "
                     + "quando vuoi.")
        return lines
    }

    static func confirmMessage(_ c: RepairCandidate) -> String {
        "La copia \(on(c.target)) di «\(c.paths[c.target] ?? c.key)» verrà sostituita da quella "
            + "\(on(c.source)). La copia diversa resta da parte in «\(RepairPaths.quarantineFolder)»."
    }

    static func progressLine(_ step: RepairStep?) -> String {
        switch step {
        case nil: return "Controllo che Cubbit risponda…"
        case .liveCheck: return "Ricontrollo le tre copie…"
        case .quarantine: return "Metto da parte la copia diversa…"
        case .write: return "Scrivo la copia buona…"
        case .finalCheck: return "Controllo la foto riparata…"
        case .log: return "Annoto la riparazione sul Mac…"
        }
    }

    /// La riparazione riuscita di questa voce, se e' piu' recente dell'ultimo inventario: la voce
    /// resta in ❗ fino al giro successivo, con «riparata il …» al posto di «Ripara…».
    static func awaitingConfirmation(_ c: RepairCandidate, records: [RepairRecord],
                                     states: [InventoryArchive: InventoryArchiveState]) -> RepairRecord? {
        let lastInventory = Date(timeIntervalSince1970: states.values.map(\.startedAt).max() ?? 0)
        return records
            .filter { $0.key == c.key && $0.target == c.target.rawValue && $0.outcome == .repaired
                      && ($0.finishedAt ?? $0.startedAt) > lastInventory }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }

    static func repairedLine(_ r: RepairRecord, calendar: Calendar = .current) -> String {
        "Riparata il \(day(r.finishedAt ?? r.startedAt, calendar: calendar)): aggiorna l'inventario per confermarlo."
    }

    static func failureText(_ f: RepairFailure) -> String {
        switch f {
        case .volumeMissing(let a):
            return "\(name(a)) non è collegato, o è stato scollegato proprio mentre l'app lavorava."
        case .unsafePath:
            return "Il percorso di questa foto non è sicuro da usare: l'app non scrive fuori dalla sua cartella."
        case .sourceChanged:
            return "La copia da cui l'app avrebbe copiato non è più quella vista nell'ultimo inventario, "
                + "oppure non si lascia leggere."
        case .witnessChanged:
            return "La seconda copia buona non è più identica alla prima: senza due copie d'accordo l'app non ripara."
        case .badCopyMissing:
            return "La copia diversa non c'è più dove l'inventario l'aveva vista."
        case .badCopyChanged:
            return "La copia diversa è cambiata dall'ultimo inventario."
        case .cubbitError:
            return "Cubbit non ha risposto come doveva."
        case .logNotWritten:
            return "L'app non è riuscita a scrivere sul Mac il registro delle riparazioni, quindi non ha cominciato."
        case .quarantineOccupied:
            return "In «\(RepairPaths.quarantineFolder)» c'è già un file con lo stesso nome ma diverso: l'app non "
                + "lo sovrascrive."
        case .quarantineFailed:
            return "Non è stato possibile mettere da parte la copia diversa."
        case .quarantineCopyMismatch:
            return "La copia messa da parte non è risultata identica a quella diversa: l'app si è fermata prima di scrivere."
        case .stagingFailed:
            return "Non è stato possibile preparare la copia buona (spazio o permessi sul disco)."
        case .stagingMismatch:
            return "La copia buona preparata non è risultata identica all'originale."
        case .writeFailed:
            return "Non è stato possibile mettere la copia buona al suo posto."
        case .finalCheckFailed:
            return "Dopo la scrittura la foto non è risultata identica alla copia buona."
        }
    }

    /// Com'e' andata, sempre con un numero onesto di cosa e' cambiato e dove sta ogni copia.
    static func outcomeLines(_ o: RepairOutcome) -> [InventoryStatus.Line] {
        typealias Line = InventoryStatus.Line
        var out: [Line] = []
        let path = "«\(o.displayPath)»"
        if o.wasDryRun {
            if o.succeeded {
                out.append(Line(id: "dry-ok", tone: .ok, text:
                    "\(path): controllo riuscito, non è stato toccato niente. Le tre copie sono come "
                    + "nell'ultimo inventario."))
                if let q = o.quarantinePath {
                    out.append(Line(id: "dry-where", tone: .info, text: o.reusedQuarantineCopy
                        ? "La copia diversa è già da parte in «\(q)»: riparando, l'app userebbe quella."
                        : "Riparando, la copia diversa andrebbe in «\(q)» \(on(o.target))."))
                }
            } else {
                out.append(Line(id: "dry-failed", tone: .warning, text:
                    "\(path): il controllo si è fermato, non è stato toccato niente."))
                if let f = o.failure { out.append(Line(id: "repair-why", tone: .warning, text: failureText(f))) }
            }
            return out
        }
        if o.succeeded {
            var text = "\(path) riparata \(on(o.target))."
            if let q = o.quarantinePath {
                text += o.reusedQuarantineCopy
                    ? " La copia diversa era già da parte in «\(q)»."
                    : " La copia diversa è da parte in «\(q)»."
            }
            out.append(Line(id: "repair-done", tone: .ok, text: text))
            out.append(Line(id: "repair-confirm", tone: .info, text: "Aggiorna l'inventario per confermarlo."))
        } else {
            out.append(Line(id: "repair-failed", tone: .warning, text: "\(path): riparazione non fatta."))
            if let f = o.failure { out.append(Line(id: "repair-why", tone: .warning, text: failureText(f))) }
            out.append(Line(id: "repair-state", tone: .info, text: stateLine(o)))
            if let st = o.leftoverStagingPath {
                out.append(Line(id: "repair-staging", tone: .info, text:
                    "La copia buona preparata è rimasta in «\(st)»: puoi lasciarla lì, se ne va quando svuoti "
                    + "«\(RepairPaths.quarantineFolder)»."))
            }
        }
        if o.logError != nil {
            out.append(Line(id: "repair-log", tone: .warning, text:
                "L'app non è riuscita ad annotare sul Mac come è finita: il registro dice ancora «in corso»."))
        }
        return out
    }

    private static func stateLine(_ o: RepairOutcome) -> String {
        if o.failedStep == .finalCheck {
            let q = o.quarantinePath.map { " resta in «\($0)»" } ?? " resta da parte"
            return "La copia diversa\(q). L'app non riprova da sola: aggiorna l'inventario e guarda di nuovo "
                + "questa foto."
        }
        if o.failedStep == .liveCheck || o.failedStep == .log || (o.quarantinePath == nil && o.target != .s3) {
            return o.restoredOriginal
                ? "La copia diversa è tornata al suo posto: tutto è com'era prima."
                : "Non è stato toccato niente."
        }
        if o.target == .s3 {
            if let q = o.quarantinePath {
                return "Su Cubbit la copia diversa è ancora al suo posto, e una copia è anche in «\(q)»."
            }
            return "Su Cubbit la copia diversa è ancora al suo posto."
        }
        return "La copia diversa è da parte in «\(o.quarantinePath ?? RepairPaths.quarantineFolder)» "
            + "\(on(o.target)) e non è andata persa, ma al suo posto per ora non c'è niente."
    }

    // MARK: - Aiuti

    private static func name(_ a: InventoryArchive) -> String { InventoryStatus.archiveName(a) }

    private static func on(_ a: InventoryArchive) -> String {
        switch a {
        case .ssd: return "sull'SSD"
        case .hdd: return "sull'HDD"
        case .s3: return "su Cubbit"
        }
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static func day(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: d)
    }
}
```

- [ ] **Step 4: esegui i test.** `fasttest.sh RepairStatusTests` → `Executed 23 tests, with 0 failures`; `fasttest.sh InventoryStatusTests` → `Executed 15 tests, with 0 failures` (la nota nuova nomina ancora SSD, HDD e Cubbit e non ha gergo); `fasttest.sh MainThreadIsolationTests` → 0 fallimenti (`testInventorySummary_runsWithoutTheMainThread` ora esercita anche `RepairRules`).
- [ ] **Step 5:** `fasttest.sh`: `Executed 1159 tests` (B+136), 0 fallimenti, 0 warning.
- [ ] **Mutanti che devono morire:** in `awaitingConfirmation` togliere il confronto con l'inizio dell'ultimo inventario (verificato: muore `testAwaitingConfirmation_onlyForASuccessAfterTheLastInventory`); in `stateLine` dire «Non è stato toccato niente.» anche quando `quarantinePath != nil` su disco (verificato: muore `testDiskWriteFailure_withoutPuttingItBack_saysWhereBothCopiesAre`); in `outcomeLines` non aggiungere la riga `repair-log` (verificato: muore `testLogError_isAlwaysSaid`).
- [ ] **Step 6: commit.**
  ```
  Riparazione, task 7: testi della riparazione e voci riparabili nel riepilogo dell'inventario

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 8: cablaggio in `BackupRunner` e il Cubbit vero (`S3RepairCloud`)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — regione R dopo il blocco del Task 7 (`S3RepairCloud`); `BackupRunner`, subito prima del commento `` // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati `` (11243).

**Interfaces:**
- Consumes: `RepairEngine` (T5), `RepairLogStore` (T4), `RepairStartGate`/`beginRepair`/`endRepair` (T6), `S3Syncer.headObject`/`listObjects`/`copyObject`/`replaceObjectForRepair`/`checkReachable` (T2), `bm.startAccessing`, `isLikelyVolumeRoot`, `backupRunnerStoreRoot()`, `VolumeMonitor.shared`.
- Produces:
  - `nonisolated final class S3RepairCloud: RepairCloud, @unchecked Sendable { init(syncer: S3Syncer, config: S3Syncer.S3Config) }`
  - `BackupRunner`: `private(set) lazy var repairLogStore: RepairLogStore?`, `@Published private(set) var repairStep: RepairStep?`, `repairingKey: String?`, `lastRepairOutcome: RepairOutcome?`, `repairRecords: [RepairRecord]`, `func refreshRepairRecords()`, `func startRepair(_:dryRun:onAlert:)` (`dryRun` senza default: ogni chiamante dice che cosa vuole), `private func finishRepair(_:)`

**Lo schema è quello di `startInventoryRefresh`**: precondizioni rivalutate all'avvio vero (fra «Ripara…» e la conferma il riepilogo può restare aperto per minuti), bookmark, `beginRepair()` **prima** della domanda a Cubbit, un `S3Syncer` **dedicato** (mai `s3Syncer` del runner, che condivide il flag di interruzione con i job), `checkReachable`, poi `Task.detached` con `RepairEngine.run`, e **un solo punto di fine** (`finishRepair`) su ogni percorso: accessi chiusi, `endRepair()`, esito pubblicato, registro riletto. Un passo annunciato in ritardo dopo la fine non sporca lo stato (`if self.isRepairing`).

- [ ] **Step 1: implementa.** Due inserimenti.

**1a. `S3RepairCloud`.**

Inserisci **subito prima** della riga `// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)` (si trova con `grep -n "MARK: - Testi e regole della card" AppBackupFoto/ContentView.swift`):

```swift
// MARK: - Riparazione: il Cubbit vero (ROADMAP #45, ADR-0016)

/// `RepairCloud` sopra un `S3Syncer` DEDICATO alla riparazione — mai `BackupRunner.s3Syncer`,
/// che condivide il flag di interruzione con i job (stessa regola dell'inventario e del
/// ricalcolo dello spazio di Cubbit).
// `nonisolated`: solo proprieta' `let`. `S3Syncer` e' isolato al MainActor (quindi `Sendable`):
// ogni chiamata salta sul main per il tempo di costruire e firmare la richiesta, l'attesa di
// rete no. `replaceObjectForRepair` legge il file come il backup (`Data(contentsOf:)` fino a
// 64 MiB, a pezzi sopra): per una foto sono millisecondi.
nonisolated final class S3RepairCloud: RepairCloud, @unchecked Sendable {
    private let syncer: S3Syncer
    private let config: S3Syncer.S3Config

    init(syncer: S3Syncer, config: S3Syncer.S3Config) {
        self.syncer = syncer
        self.config = config
    }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try await syncer.headObject(config: config, key: key)
    }

    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo] {
        try await syncer.listObjects(config: config, prefix: prefix)
    }

    func copy(from sourceKey: String, to destinationKey: String) async throws {
        try await syncer.copyObject(config: config, from: sourceKey, to: destinationKey)
    }

    func replace(key: String, withFileAt url: URL) async throws {
        try await syncer.replaceObjectForRepair(config: config, key: key, withFileAt: url)
    }
}
```

**1b. `BackupRunner`.**

Trova (deve comparire **una sola volta**):

```swift
    // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati
```

Sostituisci con:

```swift
    // MARK: Riparazione con la regola «2 su 3» (ROADMAP #45, ADR-0016)

    /// Il registro delle riparazioni, sul disco interno come gli altri file dell'app (BUG-10:
    /// sotto test in una cartella temporanea). Lazy e `try?`: senza registro la riparazione non
    /// parte, ma niente altro ne dipende.
    private(set) lazy var repairLogStore: RepairLogStore? = {
        try? RepairLogStore(url: backupRunnerStoreRoot().appendingPathComponent("repair-log.json"))
    }()
    /// Il passo in corso, per la riga sotto la voce. `nil` mentre si controlla che Cubbit risponda.
    @Published private(set) var repairStep: RepairStep? = nil
    /// La voce in riparazione (`RepairCandidate.key`).
    @Published private(set) var repairingKey: String? = nil
    @Published private(set) var lastRepairOutcome: RepairOutcome? = nil
    /// Le voci del registro, lette fuori dal main: la finestra ci trova «riparata il …».
    @Published private(set) var repairRecords: [RepairRecord] = []

    /// Rilegge il registro fuori dal main e pubblica solo se e' cambiato.
    func refreshRepairRecords() {
        guard let log = repairLogStore else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let records = log.records()
            await MainActor.run {
                guard self.repairRecords != records else { return }
                self.repairRecords = records
            }
        }
    }

    /// «Ripara» confermato, o «Controlla senza riparare» (`dryRun`, S11: stesso ricontrollo,
    /// nessuna scrittura). Le precondizioni si rivalutano QUI, all'avvio vero (fra «Ripara…» e
    /// la conferma l'utente puo' aver lasciato aperto il riepilogo per minuti), poi
    /// `isRepairing` si alza PRIMA della domanda a Cubbit. `onAlert` e' il canale della finestra
    /// Inventario (regola `AlertSink`).
    func startRepair(_ candidate: RepairCandidate, dryRun: Bool, onAlert: @escaping AlertSink) {
        if let reason = RepairStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let log = repairLogStore, let config = s3Config else {
            onAlert(SimpleAlert(title: "Riparazione non disponibile",
                                message: "Non è stato possibile aprire sul Mac il registro delle riparazioni."))
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
        if let alert = beginRepair() {
            bm.stopAccessing(.ssd)
            bm.stopAccessing(.hdd)
            onAlert(alert)
            return
        }
        repairingKey = candidate.key
        repairStep = nil
        lastRepairOutcome = nil
        let syncer = S3Syncer()
        Task { @MainActor in
            guard await syncer.checkReachable(config: config) else {
                self.finishRepair(nil)
                onAlert(SimpleAlert(title: "Cubbit non risponde", message: RepairStartGate.cubbitUnreachable))
                return
            }
            let cloud = S3RepairCloud(syncer: syncer, config: config)
            Task.detached(priority: .userInitiated) {
                let engine = RepairEngine(ssdRoot: ssdURL, hddRoot: hddURL, cloud: cloud,
                                          record: { try log.record($0) })
                let outcome = await engine.run(candidate, dryRun: dryRun, onStep: { step in
                    Task { @MainActor in if self.isRepairing { self.repairStep = step } }
                })
                await MainActor.run { self.finishRepair(outcome) }
            }
        }
    }

    /// L'UNICO punto in cui una riparazione finisce, su ogni percorso: accessi chiusi, flag giu',
    /// esito pubblicato, registro riletto.
    private func finishRepair(_ outcome: RepairOutcome?) {
        bm.stopAccessing(.ssd)
        bm.stopAccessing(.hdd)
        endRepair()
        repairStep = nil
        repairingKey = nil
        if let outcome { lastRepairOutcome = outcome }
        refreshRepairRecords()
    }

    // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati
```

- [ ] **Step 2:** `fasttest.sh`: `Executed 1159 tests` (invariato), 0 fallimenti, **0 warning** (è il controllo che conta qui: ogni salto di isolamento sbagliato fra `Task.detached`, `S3RepairCloud` e `S3Syncer` sarebbe un warning).
- [ ] **Step 3: revisione obbligatoria (checklist di `Docs/CLAUDE.md`).** `startAccessing` prima dell'uso e `stopAccessing` su ogni uscita (i tre `guard` e `finishRepair`); ogni aggiornamento della UI da contesto asincrono sul MainActor; i tipi chiamati da `Task.detached` sono `nonisolated` (`RepairEngine`, `RepairLogStore`, `S3RepairCloud`) e `run` è `@concurrent`.
- [ ] **Non coperto da test, dichiarato:** `startRepair`/`finishRepair`/`refreshRepairRecords` e `S3RepairCloud` (bookmark, rete e SwiftUI veri). È testato tutto ciò che sta ai due capi: `RepairStartGate`, `RepairEngine` con un Cubbit finto, le richieste e la firma di `S3Syncer`.
- [ ] **Step 4: commit.**
  ```
  Riparazione, task 8: cablaggio in BackupRunner e Cubbit vero per il motore

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 9: la finestra — «Ripara…», riepilogo, conferma, «Riparata il …»

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `InventoryView` (16711-16864).

**Interfaces:**
- Consumes: `InventorySummary.repairCandidates`, `RepairStatus`, `RepairStartGate`, `BackupRunner.startRepair(_:dryRun:onAlert:)`/`repairStep`/`repairingKey`/`lastRepairOutcome`/`repairRecords`/`refreshRepairRecords`.
- Produces: in `InventoryView` lo stato `pendingRepair`/`confirmRepair` (conversazione con l'utente: resta nella view, regola D3 di ROADMAP #41), `repairDisabledReason`, `repairSection(_:)`, `repairSummarySheet(_:)`.

**Come si presenta:** dentro «❗ Da controllare», prima delle voci, il sottoelenco «1 foto si può riparare» con la spiegazione e, per ogni voce, il percorso, dove è diversa e dove è uguale, e a destra **uno** fra: «Ripara…» (disattivato con il motivo scritto sotto, se `RepairStartGate` lo vieta), la riga del passo in corso, «Riparata il …: aggiorna l'inventario per confermarlo». Sotto, l'esito dell'ultima riparazione. «Ripara…» apre un foglio con il riepilogo (`RepairStatus.summaryLines`) e tre bottoni: «Annulla», «Controlla senza riparare» (chiude il foglio e avvia `startRepair(c, dryRun: true, …)`: nessuna conferma, perché non scrive niente), «Continua…» (chiude il foglio e, alla chiusura, apre la conferma con il bottone distruttivo «Ripara»: un alert non si presenta mentre un foglio si sta chiudendo, per questo passa da `onDismiss`).

- [ ] **Step 1: implementa.** Sei sostituzioni.

Trova (deve comparire **una sola volta**):

```swift
/// La finestra "Inventario": per ogni contenuto foto/video, in quale dei tre posti (SSD, HDD,
/// Cubbit) c'e' davvero, e cosa non torna. SOLA LETTURA: nessun bottone copia, sposta o
/// cancella (spec, «Il pannello e' solo lettura»).
```

Sostituisci con:

```swift
/// La finestra "Inventario": per ogni contenuto foto/video, in quale dei tre posti (SSD, HDD,
/// Cubbit) c'e' davvero, e cosa non torna. L'inventario e' SOLA LETTURA; l'unico bottone che
/// scrive e' «Ripara…» sulle voci riparabili in ❗ (ROADMAP #45, ADR-0016): una foto alla volta,
/// dopo un riepilogo e una conferma.
```

Trova (deve comparire **una sola volta**):

```swift
    @State private var alert: SimpleAlert? = nil
    @State private var expanded: Set<InventoryCategory> = []
```

Sostituisci con:

```swift
    @State private var alert: SimpleAlert? = nil
    @State private var expanded: Set<InventoryCategory> = []
    /// La voce di cui si sta leggendo il riepilogo (stato della conversazione: resta nella view,
    /// regola D3 di ROADMAP #41). `confirmRepair` passa la voce all'alert dopo la chiusura del
    /// foglio, perche' un alert non si presenta mentre un foglio si sta chiudendo.
    @State private var pendingRepair: RepairCandidate? = nil
    @State private var confirmRepair: RepairCandidate? = nil
```

Trova (deve comparire **una sola volta**):

```swift
    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Inventario").font(AppFont.title)
```

Sostituisci con:

```swift
    private var repairDisabledReason: String? {
        RepairStartGate.blockedReason(
            isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted, hasCubbitConfig: runner.s3Config != nil)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Inventario").font(AppFont.title)
```

Trova (deve comparire **una sola volta**):

```swift
        .task { runner.loadInventoryIfNeeded() }
        .alert(alert?.title ?? "", isPresented: Binding(
```

Sostituisci con:

```swift
        .task {
            runner.loadInventoryIfNeeded()
            runner.refreshRepairRecords()
        }
        .sheet(item: $pendingRepair, onDismiss: {
            guard let c = confirmRepair else { return }
            confirmRepair = nil
            alert = SimpleAlert(title: RepairStatus.confirmTitle, message: RepairStatus.confirmMessage(c),
                                isDestructive: true, confirmTitle: RepairStatus.confirmButton,
                                cancelTitle: RepairStatus.cancelButton,
                                onConfirm: { runner.startRepair(c, dryRun: false, onAlert: { alert = $0 }) })
        }) { c in
            repairSummarySheet(c)
        }
        .alert(alert?.title ?? "", isPresented: Binding(
```

Trova (deve comparire **una sola volta**):

```swift
                    Text(InventoryStatus.explanation(category))
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let items = summary.samples[category] ?? []
```

Sostituisci con:

```swift
                    Text(InventoryStatus.explanation(category))
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if category == .toCheck && !summary.repairCandidates.isEmpty {
                        repairSection(summary)
                    }
                    let items = summary.samples[category] ?? []
```

Trova (deve comparire **una sola volta**):

```swift
    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if runner.isInventorying {
```

Sostituisci con:

```swift
    /// Le voci riparabili, in testa a ❗: tutte (sono poche), ognuna con «Ripara…», con la riga
    /// del passo in corso, o con «riparata il …» finche' un nuovo inventario non la conferma.
    @ViewBuilder
    private func repairSection(_ summary: InventorySummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(RepairStatus.sectionTitle(count: summary.repairCandidates.count)).font(AppFont.body)
            Text(RepairStatus.sectionExplanation)
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.repairCandidates) { c in
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(RepairStatus.candidateLine(c))
                        .font(AppFont.caption)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: AppSpacing.sm)
                    if let done = RepairStatus.awaitingConfirmation(c, records: runner.repairRecords, states: summary.states) {
                        Label(RepairStatus.repairedLine(done), systemImage: "checkmark.circle.fill")
                            .font(AppFont.caption).foregroundStyle(AppColor.success)
                    } else if runner.repairingKey == c.key {
                        HStack(spacing: AppSpacing.xs) {
                            ProgressView().controlSize(.small)
                            Text(RepairStatus.progressLine(runner.repairStep)).font(AppFont.caption)
                        }
                    } else {
                        Button(RepairStatus.buttonTitle) { pendingRepair = c }
                            .disabled(repairDisabledReason != nil)
                    }
                }
            }
            if let reason = repairDisabledReason, !runner.isRepairing {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = runner.lastRepairOutcome {
                ForEach(RepairStatus.outcomeLines(outcome)) { lineView($0) }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    /// Il riepilogo prima della conferma (decisione 3 di Enrico): «Continua…» chiude il foglio e
    /// apre la conferma vera, con il bottone distruttivo; «Controlla senza riparare» fa solo il
    /// ricontrollo (S11).
    private func repairSummarySheet(_ c: RepairCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(RepairStatus.summaryTitle).font(AppFont.title)
            ForEach(Array(RepairStatus.summaryLines(c, date: Date(), calendar: RepairPaths.defaultCalendar).enumerated()),
                    id: \.offset) { _, line in
                Text(line).font(AppFont.body).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(RepairStatus.cancelButton, role: .cancel) { pendingRepair = nil }
                    .keyboardShortcut(.cancelAction)
                // Regola 4 di `Docs/CLAUDE.md` (S11): lo stesso ricontrollo, senza scrivere niente.
                Button(RepairStatus.dryRunButton) {
                    pendingRepair = nil
                    runner.startRepair(c, dryRun: true, onAlert: { alert = $0 })
                }
                .disabled(repairDisabledReason != nil)
                Button(RepairStatus.continueButton) {
                    confirmRepair = c
                    pendingRepair = nil
                }
                .disabled(repairDisabledReason != nil)
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 520)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if runner.isInventorying {
```

- [ ] **Step 2:** `fasttest.sh`: `Executed 1159 tests`, 0 fallimenti, 0 warning. **Punto di controllo `xcodebuild`** (in background): build pulita 0 warning, `Executed 1159 tests` (B+136).
- [ ] **Step 3: prova a vista, senza riparare niente** (Enrico o l'orchestratore, app avviata da Xcode, **nessun clic su «Ripara» nella conferma**): aprire Inventario. Con l'inventario salvato oggi (incompleto, vedi la testa del piano) il sottoelenco **non** compare; non deve comparire niente di nuovo e la nota in testa ha il testo nuovo. Il resto si vede nel Task 11.
- [ ] **Non coperto da test, dichiarato:** `InventoryView` (sottoelenco, foglio, conferma, gate Touch ID). Stessa ragione delle altre finestre: sono testati i testi (`RepairStatus`), i cancelli e il riepilogo.
- [ ] **Step 4: commit.**
  ```
  Riparazione, task 9: Ripara nella finestra Inventario, con riepilogo e conferma

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 10: documentazione (CLAUDE, regola assoluta, ROADMAP #45, CONTEXT, architettura)

**Files:** `Docs/CLAUDE.md`, `Docs/ROADMAP.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`. Nessun codice.

**Precondizione:** D1 risposta. **Convenzione dei testi qui sotto:** `<data>` e `<data dell'approvazione>` vanno sostituiti, prima del commit, con la data in cui si esegue questo task (formato `AAAA-MM-GG`); non restano mai nei file. Il testo della «Regola assoluta» qui sotto si copia **solo** nella forma approvata da Enrico; se l'ha cambiato, si usa il suo, parola per parola.

- [ ] **Step 1: `Docs/CLAUDE.md`, «Regola assoluta» (S9, D1).** Sostituisci i punti 2 e 3 con:

```markdown
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga. **Unica eccezione, aperta il <data dell'approvazione> (ADR-0016)**: la riparazione «2 su 3» della finestra Inventario può sostituire la copia di una foto in UN archivio (SSD, HDD o Cubbit) solo se gli altri due hanno la stessa copia certificata e quella da sostituire è dimostrata diversa; solo dopo aver riletto dal vivo tutte e tre le copie; solo dopo aver messo da parte la copia da sostituire in `_quarantena/<giorno>/<percorso>` sullo stesso archivio — su disco con un `rename` sullo stesso volume, su Cubbit con una copia lato server verificata — mai cancellandola; una foto alla volta, dopo un riepilogo e una conferma. La cartella `_quarantena` la svuota solo l'utente. Il backup resta zero-overwrite.
3. **Read-only sulla sorgente.** La Libreria Foto del Mac non viene mai modificata, in nessun caso. Sull'SSD le sole scritture ammesse oltre alle copie di backup sono lo spostamento nel Cestino del punto 1 e la riparazione del punto 2 (la copia diversa spostata in `_quarantena`, la copia buona scritta al suo posto). Nessun'altra funzione scrive sull'SSD. L'inventario (ADR-0015) legge SSD, HDD e Cubbit e scrive solo nel database dell'app sul Mac.
```

e subito dopo la nota esistente «> I punti **1** e **3** sono stati riscritti il **2026-08-28** …» aggiungi:

```markdown
> I punti **2** e **3** sono stati riscritti il **<data>** (testo approvato da Enrico, ADR-0016): con la riparazione «2 su 3» sarebbero diventati falsi. Stessa ragione del 2026-08-28: una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa.
```

- [ ] **Step 2: `Docs/CLAUDE.md`, checklist di revisione.** Nel blocco «IF il codice fa chiamate S3 (PUT, DELETE, COPY)», dopo «THEN verifica che PUT controlli esistenza remota prima di inviare», aggiungi:

```markdown
    THEN, unica eccezione (ADR-0016): `S3Syncer.replaceObjectForRepair` sovrascrive senza controllo di esistenza — verifica che la chiami solo `RepairEngine`, dopo una quarantena verificata con HEAD

    THEN verifica che una COPY (`CopyObject`) scriva solo dentro `_quarantena/`, su una chiave controllata prima con HEAD

IF il codice sposta o rinomina un file foto per la riparazione:

    THEN verifica che passi da `RepairEngine.renameWithoutOverwriting` (`rename(2)`, mai `moveItem`/`removeItem`), dentro la stessa radice, con la voce del registro già scritta

    THEN verifica che la copia buona sia stata preparata e riletta PRIMA di spostare quella rovinata
```

- [ ] **Step 3: `Docs/CLAUDE.md`, «Stato attuale».** Nella frase introduttiva, dopo il «Sesto tocco», aggiungi: «**Settimo tocco, <data>**: piano `Docs/superpowers/plans/2026-10-04-repair-from-majority.md` (ADR-0016) — riparazione di una copia rovinata con la regola «2 su 3» (#45), progetto 2 di 4; riscritti i punti 2 e 3 della «Regola assoluta»; aggiunta la riga «Riparazione 2 su 3 (#45)» e aggiornata la riga «Test automatici».» Aggiungi dopo la riga «Inventario certificato SSD/HDD/Cubbit (#44)»:

```markdown
| Riparazione 2 su 3 (#45) | ⏳ **Implementata (<data>, ADR-0016)** su `feature/repair-from-majority`. Nella finestra Inventario, sotto ❗, le foto rovinate in un archivio e integre e identiche negli altri due hanno «Ripara…»: riepilogo (con «Controlla senza riparare», che non scrive niente), conferma, ricontrollo dal vivo delle tre copie, quarantena in `_quarantena/<giorno>/<percorso>` sullo stesso archivio (su Cubbit copia lato server idempotente), scrittura, verifica, registro `repair-log.json` sul Mac. `_quarantena` esclusa da backup, elenco, inventario, Doppioni, ripristino, campione d'integrità (test di parità). Su Cubbit non si riparano ancora chiavi con `+`/apostrofo (S3 del piano). **Verifica dal vivo (Task 11) da fare** — non marcarla "fatto" |
```

e nella riga «Test automatici» metti in testa: «✅ **1.159 test XCTest** su `feature/repair-from-majority` (<data>, +136 rispetto ai 1.023 di `main`). File nuovi dalla riparazione (#45, ADR-0016): `QuarantineExclusionTests` (10, il test di parità), `S3SignatureTests` (8, con i tre esempi pubblicati da AWS), `S3RepairRequestsTests` (9), `RepairRulesTests` (24), `RepairPathsTests` (7), `RepairLogTests` (7), `RepairEngineTests` (37), `RepairGatesTests` (9), `RepairStatusTests` (23); `MainThreadIsolationTests` +2. Firma estesa con `isRepairing` in `JobStartGateTests`/`LibraryIndexStatusTests`/`DuplicatesStatusTests`/`InventoryRefreshTests`, nessuna asserzione cambiata. **Storia precedente — 1.014 test …**» (il resto della riga resta com'è).

- [ ] **Step 4: `Docs/ROADMAP.md`.** Aggiungi dopo il punto 44:

```markdown
45. ⏳ **Implementata il <data>, verifica dal vivo da fare — riparazione di una copia rovinata con la regola «2 su 3» (progetto 2 di 4).** Spec `Docs/superpowers/specs/2026-10-01-repair-from-majority-design.md`, piano `Docs/superpowers/plans/2026-10-04-repair-from-majority.md`, ADR-0016. Prima eccezione controllata a zero-overwrite: si scrive solo se due archivi su tre hanno la stessa copia certificata e il terzo una dimostrata diversa, una foto alla volta con conferma, ricontrollo dal vivo, quarantena `_quarantena/<giorno>/<percorso>` sullo stesso archivio (mai cancellata, la svuota Enrico), verifica e registro. Primo caso: `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, rovinata su Cubbit (ETag atteso dopo la riparazione `b59917c9c6e38fccab5ce3f30c90d13a`). Aperti: chiavi Cubbit con `+`/apostrofo (il caricamento del backup codifica il percorso in modo diverso dalle richieste nuove); ETag a pezzi non coincidenti restano ❗; svuotare la quarantena dall'app e riparazioni in blocco fuori scope. Il meccanismo (ricontrollo, quarantena, verifica, registro) è quello che useranno i progetti 3 e 4.
```

- [ ] **Step 5: `Docs/CONTEXT.md`.** Aggiungi dopo la sezione «## Inventario (roadmap #44)»:

```markdown
## Riparazione (roadmap #45)

**Copia rovinata** — la copia di una foto, in UN archivio, con un contenuto diverso da quello identico negli altri due. «Diverso» va dimostrato: su un disco un SHA256 diverso, su Cubbit un ETag a parte unica (che è l'MD5) diverso. Un ETag a pezzi che non torna non dimostra niente.

**Regola «2 su 3»** — si scrive su un archivio solo se gli altri due hanno la stessa copia certificata. Senza una maggioranza (tre contenuti diversi, un archivio letto a metà, il percorso che manca da un archivio) non si ripara niente.

**Sorgente e testimone** — la sorgente è il file locale da cui si copia (SSD per riparare HDD o Cubbit, HDD per riparare l'SSD); il testimone è la seconda copia buona (HDD per Cubbit, Cubbit per i dischi). Entrambi si ricontrollano dal vivo prima di toccare qualunque cosa: l'inventario è una cache.

**Quarantena** — la cartella `_quarantena/<AAAA-MM-GG>/<percorso originale>` sullo stesso archivio, dove la riparazione mette da parte la copia che sostituisce, invece di cancellarla. Non rientra mai in backup, elenco, inventario, Doppioni, ripristino. Su Cubbit è idempotente: una copia già messa da parte, in qualunque giorno, con la stessa dimensione e lo stesso ETag della rovinata, vale come fatta. La svuota solo l'utente, dal Finder o da Cubbit.

**Registro delle riparazioni** — `repair-log.json` sul disco interno del Mac, mai su un archivio: una voce scritta «in corso» prima di toccare qualunque archivio, aggiornata con l'esito, con percorsi, impronte prima e dopo e posizione della quarantena.
```

- [ ] **Step 6: `.claude/rules/architecture.md`.** (a) Nella sezione `FileSyncer`, al punto «Esclude: …», aggiungi `_quarantena` (senza maiuscole, ADR-0016) all'elenco. (b) Nella sezione `S3Syncer`, dopo il punto «Estensioni per l'inventario», aggiungi:

```markdown
- **Richieste della riparazione (<data>, ROADMAP #45, ADR-0016)**: `headObject` (HEAD, sola lettura; `parseHead`: 404 = assente, 200 con dimensione = oggetto, ogni altro stato = errore, mai «assente» per sbaglio), `copyObject` (copia lato server, `x-amz-copy-source` = `copySourceHeader`, riuscita solo con un `<CopyObjectResult>` nel corpo), `listObjects(prefix:)` (tutte le pagine, lancia su una lista incompleta) sopra `fetchListPageXML(…, prefix:)`, e **la sola sovrascrittura del progetto**, `replaceObjectForRepair` (l'`upload` del backup con un gate da uno slot; chiamata solo da `S3RepairCloud` per `RepairEngine`). Le chiavi viaggiano codificate con `encodeKeyStrict` (tutto tranne `A-Z a-z 0-9 - _ . ~ /`, byte per byte) e `sign` riceve lo stesso percorso (`canonicalURI`): niente due codifiche diverse fra richiesta e firma. `sign` è diventata `internal` con `canonicalURI`/`extraSignedHeaders` (default che lasciano identiche le firme di oggi, `testListRequest_isSignedAsBefore`), il cuore è `sigV4Signature`, puro, provato con i tre esempi pubblicati da AWS. **Limite noto**: `upload`/`put` del backup codificano ancora con `.urlPathAllowed`, che lascia in chiaro `+`, apostrofo e `!$&()*,;=:@`; per questo su Cubbit si ripara solo una chiave per cui i due percorsi coincidono (`RepairRules.cubbitKeyIsRepairable`). **Fatto notato e non corretto**: `localUploadFiles` calcola la chiave togliendo la radice come stringa; con una radice che passa da un link (`/var` → `/private/var`, solo nei test) le chiavi uscirebbero sbagliate — sull'SSD vero non succede.
```

(c) Dopo la sezione «### Inventario certificato (…)», aggiungi:

```markdown
### Riparazione con la regola «2 su 3» (<data>, roadmap #45, ADR-0016)

Nella finestra Inventario, sotto ❗, le foto rovinate in UN archivio e integre e identiche negli altri due hanno «Ripara…». Piano `Docs/superpowers/plans/2026-10-04-repair-from-majority.md`, spec `Docs/superpowers/specs/2026-10-01-repair-from-majority-design.md`, ADR-0016. **Implementata, verifica dal vivo del Task 11 ancora da fare** — non marcarla "fatto".

- **`LibraryExclusions.quarantineFolderName`** (`_quarantena`) — un nome solo, dentro `names`, confrontato senza maiuscole (`isQuarantineName`, exFAT). Lo saltano `FileSyncer`, `LibraryIndexer` (quindi i Doppioni), `InventoryScanner`, `InventoryPerimeter` (via `isExcludedName`), `S3Syncer.localUploadFiles` (backup e anteprima SSD → Cubbit, che hanno un filtro loro), il ripristino (cartelle SSD/HDD e `topLevelFolders`), il campione d'integrità; `importFolderSlug` non produce mai un nome escluso. **Test di parità**: `QuarantineExclusionTests` dà a ogni lettore lo stesso albero e pretende che veda solo la foto vera — se scrivi un lettore nuovo, aggiungilo lì.
- **`RepairRules`/`RepairPaths`/`RepairCandidate`** (`nonisolated`, puri) — quando una voce è riparabile (tre archivi completi, stesso percorso una volta per archivio, due d'accordo, il terzo dimostrato diverso: su Cubbit solo ETag a parte unica), chi è la minoranza, la sorgente (SSD per HDD/Cubbit, HDD per l'SSD) e il testimone; i percorsi di quarantena (giorno nel fuso del Mac, stessa chiave relativa, mai `.`/`..`, mai dentro la quarantena) e il riconoscimento di una copia già in quarantena in un giorno qualsiasi.
- **`RepairEngine`** (`nonisolated final class`, `run` `@concurrent`, dipendenze iniettate solo dai test) — con `dryRun: true` (S11, regola 4) solo il ricontrollo e la ricerca della quarantena, nessuna scrittura né voce nel registro; altrimenti ricontrollo dal vivo, registro «in corso», quarantena, scrittura, verifica, registro. Su disco la copia buona si **prepara prima** (`.in-arrivo-<token>` dentro la quarantena, riletta), poi `rename` rovinata → quarantena, poi `rename` preparata → posto, con il ritorno della rovinata se l'ultimo `rename` fallisce; solo `renameWithoutOverwriting` (`rename(2)` dopo `lstat`), mai `moveItem` (fra volumi copierebbe e cancellerebbe); `st_dev` ricontrollato prima di creare cartelle e di spostare, e la cartella creata deve stare sotto la radice e sullo stesso disco. Su Cubbit quarantena idempotente (lista di `_quarantena/`, poi HEAD), copia lato server, HEAD della copia, `replace`, HEAD con l'ETag atteso. Il primo passo che fallisce ferma tutto; una verifica finale fallita non si ritenta.
- **`RepairLogStore`** — `repair-log.json`, stesso schema e stessa disciplina di `TrashManifestStore` (allow-list, scrittura prima di tornare, `0600`, `init(from:)` con `decodeIfPresent`), *upsert* per `repairId`.
- **`isRepairing`** — vedi la sezione sulla mutua esclusione qui sotto; `RepairStartGate` per il verso opposto.
- **`RepairStatus`** — tutti i testi; la cartella «_quarantena» si nomina (Enrico la svuota dal Finder), il resto del gergo no.

**Non coperto da test, dichiarato**: `BackupRunner.startRepair`/`finishRepair`/`refreshRepairRecords`, `S3RepairCloud`, la parte di `InventoryView` (sottoelenco, foglio, conferma). È testato tutto ciò che sta ai due capi del cablaggio.
```

(d) Nella sezione «### `isTrashingDuplicates` / `isRestoringFromTrash` / `JobStartGate`…», dopo il paragrafo del 2026-09-29, aggiungi:

```markdown
**<data> (ROADMAP #45, ADR-0016): `isRepairing` entra negli stessi cancelli.** La riparazione scrive su SSD, HDD o Cubbit. `BackupRunner.isRepairing` (`@Published private(set)`, `beginRepair`/`endRepair`) si alza prima della domanda a Cubbit; `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason` e `InventoryStartGate.blockedReason` guadagnano `isRepairing: Bool` senza default; `beginDuplicateTrashing`/`beginTrashRestore` lo guardano. Verso opposto: `RepairStartGate.blockedReason` (un'altra riparazione > spostamento/annullamento > inventario > backup > lettura > dischi > Cubbit non configurato). **Non toccati, con motivo scritto**: `resetDisabledReason` (la riparazione non scrive nell'elenco), `RestoreEngine` e campione d'integrità (sola lettura).
```

- [ ] **Step 7:** nessun codice cambiato: `fasttest.sh` non serve. Rileggi i quattro file cercando le frasi che la riparazione ha reso false (`grep -n "solo lettura\|guarda soltanto\|zero-overwrite\|Nessun'altra funzione scrive" Docs/CLAUDE.md Docs/CONTEXT.md .claude/rules/architecture.md`) e correggi quelle che parlano della finestra Inventario come «solo lettura» senza eccezioni.
- [ ] **Step 8: commit.**
  ```
  Riparazione, task 10: documentazione (regola assoluta, CLAUDE, ROADMAP #45, CONTEXT, architettura)

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

### Task 11: verifica dal vivo sulla `.heic` (la esegue l'orchestratore con Enrico)

**Chi:** l'orchestratore, con Enrico presente. **Non** un Implementer da solo: è la prima scrittura vera su Cubbit di questo progetto. **Files:** nessuno (in fondo, una nota in `Docs/CLAUDE.md` e `Docs/ROADMAP.md` con l'esito, nello stesso stile della riga #44).

**Precondizioni:** Task 0-10 fatti e verdi con `xcodebuild`; l'app con questo branch avviata (da Xcode o installata, decide Enrico); SSD e HDD collegati; **VPN spenta** (il 2026-09-26 NordVPN ha fatto fallire gli upload verso Cubbit); nessun backup in corso.

`<oggi>` qui sotto è il giorno in cui si esegue la verifica, come lo mostra la finestra. Valori di riferimento: chiave `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, 2.463.629 byte; SSD e HDD: MD5 `b59917c9c6e38fccab5ce3f30c90d13a`, SHA256 `80f4a17bcffac94dd4e0b83707297b33c5672fbc70512dca32c8c840169234b0`; Cubbit oggi: ETag `24cb65338294b62644feec09251bd6ac`; quarantena già creata dalla prova del 2026-10-04: `_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, ETag `24cb65338294b62644feec09251bd6ac`.

- [ ] **Step 1: fotografia di prima (sola lettura, da terminale).**
  ```bash
  K="Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
  md5 -q "/Volumes/SSD - Enri/$K"; md5 -q "/Volumes/BackupHDD/$K"          # entrambi b59917c9…0d13a
  rclone md5sum "Cubbit:backupfoto/$K"                                     # 24cb6533…bd6ac
  rclone lsjson --recursive "Cubbit:backupfoto/_quarantena" | grep -c Path # 1 (la copia del 2026-10-04)
  ls "/Volumes/SSD - Enri/_quarantena" "/Volumes/BackupHDD/_quarantena" 2>&1 # entrambe assenti
  ```
- [ ] **Step 2: inventario completo.** Finestra Inventario → «Aggiorna l'inventario» (secondo giro: ~19 min SSD, ~52 min HDD, ~4 min Cubbit). Atteso: «Inventario completo, aggiornato oggi»; in ❗ il sottoelenco «1 foto si può riparare» con ««Foto iPhone/3/370C9D23-…heic» — diversa su Cubbit; uguale sull'SSD e sull'HDD» e il bottone «Ripara…». Le due voci della `.heic` restano anche nell'elenco ❗ sotto. Se il sottoelenco non c'è: **fermarsi** (vedi in testa al piano: un archivio non completo blocca ogni riparazione) e guardare le righe di completezza.
- [ ] **Step 3: controllo senza riparare (S11).** «Ripara…» → leggere il riepilogo insieme a Enrico (deve nominare `_quarantena/<oggi>/Foto iPhone/3/…heic` e dire che se la copia è già da parte l'app usa quella) → «Controlla senza riparare». Atteso: «controllo riuscito, non è stato toccato niente» e «La copia diversa è già da parte in «_quarantena/2026-10-04/…»: riparando, l'app userebbe quella.» È la prima prova dal vivo delle richieste nuove (HEAD e lista con prefisso, firmate): un errore qui («Cubbit non ha risposto come doveva») si diagnostica **prima** di qualunque scrittura. Ripetere lo Step 1: niente deve essere cambiato, e `~/Library/Application Support/AppBackupFoto/repair-log.json` non deve esistere.
- [ ] **Step 4: la riparazione.** «Ripara…» → «Continua…» → conferma «Ripara». Atteso, in pochi secondi: ««…heic» riparata su Cubbit. La copia diversa era già da parte in «_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic».» + «Aggiorna l'inventario per confermarlo.»; la riga della voce dice «Riparata il <oggi>: aggiorna l'inventario per confermarlo.» Se compare un errore: **non ritentare**, fotografare la finestra e leggere il registro.
- [ ] **Step 5: fotografia di dopo (sola lettura).**
  ```bash
  rclone md5sum "Cubbit:backupfoto/$K"                                     # b59917c9c6e38fccab5ce3f30c90d13a
  rclone md5sum "Cubbit:backupfoto/_quarantena/2026-10-04/$K"              # 24cb65338294b62644feec09251bd6ac
  rclone lsjson --recursive "Cubbit:backupfoto/_quarantena" | grep -c Path # ancora 1: nessuna seconda copia (idempotente)
  rclone cat "Cubbit:backupfoto/$K" | shasum -a 256                        # 80f4a17b…69234b0, come SSD e HDD
  md5 -q "/Volumes/SSD - Enri/$K"; md5 -q "/Volumes/BackupHDD/$K"          # invariati
  ls "/Volumes/SSD - Enri/_quarantena" "/Volumes/BackupHDD/_quarantena" 2>&1 # ancora assenti
  python3 -m json.tool ~/Library/Application\ Support/AppBackupFoto/repair-log.json
  #   una voce: outcome "repaired", target "s3", source "ssd", witness "hdd",
  #   reusedQuarantineCopy true, quarantinePath "_quarantena/2026-10-04/…", afterETag "\"b59917c9…\""
  ls -l ~/Library/Application\ Support/AppBackupFoto/repair-log.json        # -rw-------
  ```
- [ ] **Step 6: nient'altro è cambiato.** Ripristino guidato → Cubbit: fra le cartelle **non** compare `_quarantena`. Anteprima 👁 SSD → Cubbit: da caricare 0 (come prima). Nessun file nuovo sull'SSD o sull'HDD.
- [ ] **Step 7: conferma con un nuovo inventario.** «Aggiorna l'inventario» di nuovo. Atteso (spec): **❗ = 0**, il sottoelenco sparito, la `.heic` in ✅.
- [ ] **Step 8: non provati dal vivo, per costruzione (dichiarato):** riparazione di HDD o SSD (nessun caso reale), quarantena su disco, ogni percorso di fallimento, chiavi con caratteri speciali — coperti dai test automatici (`RepairEngineTests`, `QuarantineExclusionTests`), non dal vivo.
- [ ] **Step 9:** riportare l'esito in `Docs/CLAUDE.md` (riga «Riparazione 2 su 3 (#45)», da ⏳ a ✅ solo se gli Step 2-7 sono passati) e in `Docs/ROADMAP.md` (#45), commit:
  ```
  Riparazione: esito della verifica dal vivo, #45 fatto

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016dF19Hdyo1R9rrTKZPxyvs
  ```

---

## Fuori scope (dichiarato)

- Svuotare la quarantena dall'app (decisione 4: la svuota Enrico, dal Finder o da Cubbit).
- Riparare senza una maggioranza 2 su 3; riparazioni in blocco; riparazioni automatiche.
- Chiavi Cubbit con `+`, apostrofo e `!$&()*,;=:@` (S3): servirebbe cambiare la codifica del caricamento del backup, con una prova dal vivo dedicata.
- Oggetti Cubbit con un ETag a pezzi che non coincide (S2): restano ❗; scaricarli per confrontarli è un altro progetto.
- Allineare il filtro di `S3Syncer.sync`/`previewUpload` a `LibraryExclusions` per intero (`lost+found`, `Backups.backupdb`): decisione aperta da prima di questo piano, qui si aggiunge solo la quarantena.
- La chiave calcolata per stringa in `localUploadFiles` con radici che passano da un link (solo nei test, mai sull'SSD vero): segnalata in `architecture.md`, non corretta.
- Cancellare doppioni su HDD e Cubbit (progetti 3 e 4), che riuseranno ricontrollo, quarantena, verifica e registro di questo piano.

