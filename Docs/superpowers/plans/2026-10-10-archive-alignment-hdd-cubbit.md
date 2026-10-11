# Doppioni su HDD e Cubbit: i tre archivi tornano uguali — Implementation Plan

**Stato: APPROVATO da Enrico il 2026-10-11** (D1-D12 con le raccomandazioni, testi del Task 9 compresi). Scritto dall'Architect il 2026-10-10 sera.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Base:** `main` a `804a8b4` (1.266 test). Spec approvata: `Docs/superpowers/specs/2026-10-10-archive-alignment-hdd-cubbit-design.md` (fonte delle decisioni, non riaperte qui). Numerazione: **ADR-0019**, **ROADMAP #47**. Branch proposto: `feature/archive-alignment` (D12).

## In breve (per Enrico)

L'SSD ha già tolto 89.442 copie doppie; HDD e Cubbit le hanno ancora tutte. Questo piano aggiunge, nella finestra **Inventario**, una sezione «Copie già tolte dall'SSD, ancora su HDD e Cubbit», con l'HDD e Cubbit separati. Per ciascuno:

1. **«Controlla senza togliere»**: guarda l'inventario e la storia degli spostamenti, non tocca niente, e dice quante copie si toglierebbero, quanto spazio, e quante restano e perché.
2. **«Togli le copie…»**: riepilogo, poi conferma. Si procede a blocchi da 2.000 copie, una copia alla volta. Prima di ogni copia l'app ricontrolla dal vivo: la copia che l'SSD ha tenuto c'è ancora sull'SSD; quella da togliere non è tornata sull'SSD; sull'archivio le due copie sono ancora identiche (sull'HDD le rilegge per intero, su Cubbit le chiede a Cubbit). Se qualcosa non torna, la copia resta e il riepilogo lo dice.
3. Sull'**HDD** le copie vanno nel **Cestino dell'HDD** (l'app non lo svuota mai). Su **Cubbit** si tolgono solo con le **versioni accese** e la regola dei 30 giorni: per 30 giorni ogni copia si recupera identica. L'app legge lo stato delle versioni prima di ogni blocco e non lo cambia mai.
4. Un **registro** sul Mac annota ogni copia prima di toccarla e subito dopo (dove è finita).
5. **«Annulla l'ultimo blocco»** rimette a posto l'ultimo blocco (dal Cestino dell'HDD, o togliendo il segno di cancellazione su Cubbit entro i 30 giorni, con verifica).
6. Una corsa alla volta: mentre gira, niente backup, inventario, riparazione o spostamenti dell'SSD, e viceversa.

Il backup resta com'è: copia solo ciò che manca, non cancella mai. L'SSD non viene toccato.

**Verifica preventiva dell'Architect (2026-10-10), senza `xcodebuild`.** Codice dei Task 1-8 e **tutti** i test compilati ed eseguiti fuori da Xcode in `/private/tmp/claude-501/align-plan/proto/`: `ContentView.swift` di `804a8b4` + patch `proto/patches/0N-*.py` (una per task, ogni «Trova» presente esattamente una volta, applicate in ordine), `swiftc` con le impostazioni del target (`-default-isolation MainActor` e le sei funzioni «upcoming» del progetto), tutti i file di test in un bundle lanciato con `xcrun xctest`. Ogni task verificato anche da solo, in ordine (patch fino al task N + test fino al task N, `proto/tests-tN/`): **1.303 → 1.317 → 1.333 → 1.355 → 1.372 → 1.388 → 1.397 → 1.412 test, 0 fallimenti, 0 warning** (app e test). Mutanti: vedi in fondo. Prova a secco di `apply.py` su una copia del repository (stessi conteggi, pbxproj con 4 righe per file nuovo). Differenze volute del prototipo, solo lì: stub di Sparkle, niente `@main`, `isRunningUnderTests()` = `true`. **Non eseguiti** (SwiftUI e bookmark veri): il cablaggio in `BackupRunner` (`startAlignmentCheck`/`startAlignmentRun`/`startAlignmentUndo`) e la sezione in `InventoryView`; le richieste vere a Cubbit (`bucketVersioning`, `bucketLifecycleRules`, `listObjectVersions`, i due DELETE). **Nessuna scrittura su `/Volumes`, nessuna scrittura su Cubbit, repository non toccato.**

**Due difetti trovati dal prototipo mentre lo scrivevo, già corretti nelle patch:**
- Il motore ricontrollava `st_dev` dell'HDD solo dopo un fallimento: un HDD rimontato (o un altro disco con lo stesso nome) con i file leggibili sarebbe passato. Ora `st_dev` di HDD e SSD si ricontrolla all'inizio di ogni copia (`testHDDVanishingMidBlock_stopsAndKeepsTheHonestCount` era rosso).
- I membri di un'`extension` non annotata di un tipo `nonisolated` sono `@MainActor` per il default del target: `undoCubbit` (async, senza `@concurrent`) sarebbe saltato sul main **senza nessun warning** (caso D di ADR-0006). Le tre estensioni sono `nonisolated extension` (`testArchiveAlignerUndo_runsWithoutTheMainThread` era rosso). **Lezione da aggiungere a architecture.md** (Task 9): «`nonisolated` su un tipo non si estende alle sue `extension`».

## Fatti letti (sola lettura, 2026-10-10 sera)

Su copie in `/private/tmp/claude-501/align-plan/data/` di `trash-history.jsonl` e `library-index.sqlite` (+`-wal`/`-shm`), aperte in sola lettura; `stat` sui volumi; Cubbit solo letture con `cubbit-aws.sh`. Script: `/private/tmp/claude-501/align-plan/measure/*.py`.

- **Inventario**: l'ultimo giro (run `1791653112831`) è **completo** su SSD, HDD e Cubbit, iniziato oggi alle 18:25:12, finito alle 18:27:26; 0 file illeggibili. Righe: SSD **52.169**, HDD **141.686**, Cubbit **141.686**.
- **Storia**: 47 blocchi, **89.442** copie, tutte sotto `/Volumes/SSD - Enri/`, tutte con la copia tenuta. **89.436** percorsi distinti: 6 copie compaiono due volte (blocco spostato, annullato e rispostato) e sempre con la **stessa** tenuta. Nessuna copia uscita è la tenuta di un'altra voce. Le copie tenute distinte sono 27.761.
- **Applicando le condizioni 1-5 all'inventario di oggi** (stessa logica del Task 1, ricalcolata in Python, ETag compresi con le forme alternative): si toglierebbero **tutte le 89.442** copie sia dall'HDD sia da Cubbit (89.436 dopo le ripetizioni), **144,34 GB** (134,4 GiB) per archivio. Nessuna copia tornata sull'SSD, nessuna tenuta mancante, nessuna collisione, nessun contenuto diverso, nessun oggetto Cubbit non certificabile fra queste.
  - La spec dice «circa 164 GB»: la somma delle dimensioni delle copie è 144,3 GB. Il 164 era lo spazio liberato sull'SSD misurato col Cestino svuotato, che può contenere anche altro: si usa 144.
- Per cartella, le copie uscite: `ASUS` 76.663, `Takeout` 5.457, `Takeout 2` 3.433, `Foto Google Drive` 3.274, `Other` 416, `Foto iPhone` 199. Dimensione mediana 29 KB, la più grande 1,1 GB.
- **Percorsi**: le copie hanno la stessa grafia (maiuscole comprese) sull'SSD, sull'HDD e su Cubbit. Su Cubbit **1.259** chiavi contengono parentesi, apostrofo o `+` (1.237 con `(`, 96 con `'`, 1 con `+`).
- **Cubbit accetta la codifica stretta del progetto**: HEAD (con `aws --debug`, che codifica come `S3Syncer.encodeKeyStrict`) su `…_2050+ (1).png` (`%2B%20%281%29`), su `…UNIVERSITA'/…video (4).mp4` (`%27`, `%28`) e su `ASUS/Rhodes/IMG_2906 (1).JPG`: tutte 200 con dimensione ed ETag. HEAD e DELETE del progetto usano lo stesso percorso (`objectRequestPath`).
- **Cubbit, versioni del bucket `backupfoto`**: `get-bucket-versioning` risponde vuoto = **mai accese** (come atteso: le accende l'orchestratore con Enrico).
- **Cubbit, tempi**: una richiesta con la connessione già aperta costa **~110 ms** (5 pagine di lista consecutive: 535, 239, 112, 110, 107 ms). Tre richieste per copia (HEAD tenuta, HEAD copia, DELETE) ⇒ ~0,35 s a copia ⇒ **~8-9 ore** per 89.436 copie, una alla volta (D7).
- **81 copie su HDD e Cubbit restano fuori dal progetto**: sono sull'HDD e su Cubbit, non sull'SSD, non nella storia, e tutte hanno il loro contenuto sull'SSD in un altro percorso. Il registro di ripristino dell'SSD conta 89.529 spostamenti contro le 89.442 voci della storia: sono copie spostate prima che la storia esistesse (fine settembre). Per la decisione 1 della spec restano su HDD e Cubbit; dopo le due corse HDD e Cubbit avranno 52.250 file, l'SSD 52.169.
- **HDD**: APFS, `.Trashes/501` esiste già (dal 10/02/2025), 437 GiB liberi. **Nessuna** delle 89.442 copie sull'HDD ha il blocco «Bloccato» (`uchg`); nemmeno gli 11 file sbloccati a mano sull'SSD il 06/10 lo hanno sull'HDD (il mirror non copia quel flag). Stima HDD: ~0,05 s a copia ⇒ **~1-1,5 ore**.

---

## Decisioni da far approvare (con la raccomandazione)

Nessuna è stata applicata di nascosto: il piano implementa la «Raccomandazione»; se Enrico sceglie l'alternativa, l'Implementer si ferma e rimanda all'Architect. Le decisioni già prese dalla spec (quali copie, quale copia resta, Cestino dell'HDD, DELETE solo con versioni, chi accende le versioni, finestra Inventario, HDD e Cubbit separati) non sono riaperte.

| # | Domanda | Raccomandazione (implementata) | Alternativa / costo |
| :--- | :--- | :--- | :--- |
| D1 | Dove sta la sezione dentro la finestra Inventario | **In fondo all'elenco delle categorie** (dentro la parte che scorre), con un titolo e due righe: HDD e Cubbit, ciascuna con i suoi bottoni, lo stato e l'esito. | In alto, sopra le categorie: più visibile, ma spinge in basso lo stato dei tre archivi. |
| D2 | Quante copie per blocco | **Al massimo 2.000 copie o 50 GB**, come i Doppioni: ~45 blocchi per archivio. Il blocco è anche quello che «Annulla l'ultimo blocco» rimette a posto. | Blocchi più grandi (meno blocchi, annullamento più largo) o più piccoli (annullamento più fine, più righe nel riepilogo). |
| D3 | File con il blocco «Bloccato» sull'HDD | **Si saltano con il motivo e la corsa prosegue.** L'app non li sblocca mai (sbloccare vuol dire cambiare un file dell'archivio). Oggi sull'HDD non ce n'è nessuno. | Fermare la corsa al primo, come fanno i Doppioni sull'SSD: con 89.000 copie vorrebbe dire ripartire a mano. |
| D4 | Come si legge lo stato di Cubbit | **Prima di ogni blocco** l'app legge le versioni e le regole (solo lettura). Il blocco parte solo se: le versioni sono accese; c'è una regola attiva per tutto il bucket che fa sparire le versioni vecchie; **nessuna** regola attiva lo fa prima di **30 giorni** (sotto, «Annulla» non funzionerebbe); **nessuna** regola fa sparire le foto attuali. In più, se un DELETE non risponde con il segno di cancellazione, la corsa si ferma subito. | Leggere solo le versioni, non le regole: più semplice, ma una regola sbagliata (1 giorno) toglierebbe la rete dei 30 giorni senza che l'app se ne accorga. |
| D5 | HDD e Cubbit insieme? | **Corse separate, una alla volta** (anche fra HDD e Cubbit), come dice la spec; prima l'HDD (dura poco), poi Cubbit. | Le due in parallelo: si risparmia tempo, ma due corse da seguire e due registri che crescono insieme. |
| D6 | Le condizioni 3 e 4 (copia tenuta sull'SSD, copia non tornata) si ricontrollano anche **dal vivo**? | **Sì: l'SSD deve essere collegato** durante la corsa, e prima di ogni copia l'app guarda che la copia tolta non ci sia e che la tenuta ci sia con la stessa dimensione. La spec le chiede solo sull'inventario, ma un «Annulla l'ultimo spostamento» o uno spostamento dei Doppioni fatto dopo l'inventario **non lo invecchiano** (ADR-0017): solo il controllo dal vivo se ne accorge. | Solo inventario, come la spec: l'SSD può restare scollegato durante la corsa sull'HDD o su Cubbit. |
| D7 | Cubbit: una copia alla volta? | **Sì**, con la HEAD della copia tenuta prima di ogni copia, come scrive la spec: **~8-9 ore** per tutto Cubbit (da far girare di notte; «Interrompi» e ripresa: le copie già tolte si saltano da sole). | 4 copie insieme (~2 ore) o una sola HEAD della tenuta per gruppo (−25%): registro e «Interrompi» più complicati, o un ricontrollo meno «subito prima». |
| D8 | Il registro | **Due file sul Mac**, `alignment-hdd.jsonl` e `alignment-cubbit.jsonl`, in sola aggiunta: una riga prima di toccare la copia e una subito dopo (sull'HDD dove è finita nel Cestino, su Cubbit la versione del segno di cancellazione). Se il registro non si lascia scrivere, la corsa si ferma. Senza `fsync`, come il registro dei Doppioni: una chiusura dell'app non perde niente, uno spegnimento brusco le ultime righe (le copie restano recuperabili). | Riscrivere un file intero a ogni copia (come il registro dei Doppioni): con 89.000 copie costerebbe minuti di scritture e crescerebbe col quadrato. |
| D9 | Chiavi di Cubbit con parentesi, apostrofo o `+` (1.259 copie) | **Si tolgono anche quelle**: HEAD e DELETE mandano lo stesso identico percorso, e Cubbit ha risposto correttamente alla HEAD con quella codifica (fatti letti). Il problema della riparazione (ADR-0016) era il caricamento del backup, che qui non c'è. | Lasciarle su Cubbit finché una prova dal vivo non le copre (come per la riparazione): 1.259 copie in più su Cubbit. |
| D10 | «Annulla» sull'HDD | **Riusa `TrashRestorer`** (lo stesso dell'annullamento dei Doppioni), a cui si passa il modo di segnare «rimessa» invece del registro dell'SSD: una modifica di poche righe a un componente protetto, nessun comportamento cambiato (i suoi 18 test restano verdi senza modifiche). | Un secondo motore di ripristino per l'HDD: due copie della stessa cura che prima o poi divergono (la classe di errore già pagata tre volte nel progetto). |
| D11 | Testo dei punti 1 e 3 della «Regola assoluta» e della checklist | **Il testo esatto è nel Task 9** (da approvare parola per parola). | — |
| D12 | Dove va il lavoro | **Branch nuovo** `feature/archive-alignment` da `main` (`804a8b4`), ADR-0019, ROADMAP #47. | Direttamente su `main`: no, è il percorso a danno più alto del progetto. |

**Fatti da sapere, nessuna decisione richiesta:**
- Sull'HDD lo spazio si libera solo quando Enrico svuota il Cestino dell'HDD: dentro ci saranno ~89.000 file (molti con lo stesso nome, rinominati dal Finder). Aprire quel Cestino nel Finder può essere lento.
- Su Cubbit lo spazio si libera da solo dopo 30 giorni dalla corsa. Attenzione a un numero che inganna: la riga «X usati» sotto Cubbit (indicatore di spazio, ADR-0008) conta solo gli oggetti visibili, quindi scenderà subito di ~144 GB, mentre Cubbit tiene (e conta) le versioni vecchie ancora per 30 giorni. L'indicatore dell'HDD invece non cambia finché il Cestino dell'HDD non viene svuotato.
- «Annulla l'ultimo blocco» chiede l'SSD collegato anche se non lo usa (un cancello solo per corsa e annullamento): limite piccolo, accettato.
- Dopo una corsa il controllo va rifatto: le copie tolte risultano «già tolte» dal registro (l'inventario le vede ancora finché non lo si aggiorna).
- 81 copie doppie restano su HDD e Cubbit anche dopo le due corse: furono spostate dall'SSD prima che esistesse la storia degli spostamenti (vedi «Fatti letti»). Per toglierle servirebbe un progetto a parte (la spec le lascia fuori).

---

## Global Constraints

- **Il motore non sceglie, rifiuta.** Cosa togliere lo decide una volta sola `AlignmentPlanner` (condizioni 1-5, pura, sull'inventario e sulla storia); il piano si **congela** al controllo e viaggia invariato fino alla corsa (come `DuplicateBatch`). `ArchiveAligner` ricontrolla dal vivo e salta (condizione 6), legge le versioni (condizione 7), scrive il registro. Mai ricalcolare il piano fra il riepilogo e la corsa.
- **Verso sicuro ovunque**: inventario non fresco, storia o registro illeggibili ⇒ niente esce. Una copia che non passa un controllo resta, con il motivo. «Non c'è» non vuol dire mai «già fatto» senza `st_dev` (ADR-0005, fatto 9). Un guasto (disco sparito, registro non scritto, `trashItem` fallito, errore di Cubbit, DELETE senza segno) ferma la corsa.
- **Una regola sola**: la freschezza è `DuplicateInventoryFreshness.evaluate` e, prima di ogni blocco, `DuplicateCertification.runBlock` (ADR-0017, stesse funzioni); la certificazione Cubbit è `S3ETagMatcher.verdict` con gli stessi candidati di `InventoryClassifier` (test di parità); i percorsi sicuri sono `RepairPaths.safeComponents` e `RepairEngine.confined`; i tetti dei blocchi sono `duplicateBatchFileCap`/`duplicateBatchByteCap`.
- **HDD**: solo `trashItem` (stesso volume), mai `removeItem`/`moveItem` per togliere; mai un collegamento simbolico, mai un file non media; l'app non svuota il Cestino e non sblocca file.
- **Cubbit**: solo letture della configurazione del bucket (`GET ?versioning`, `GET ?lifecycle`); DELETE **senza** versione solo da `runCubbitBlock`; DELETE **con** versione solo da `undoCubbit`, solo su un segno di cancellazione confermato da `ListObjectVersions` e ultimo stato della chiave. Le due richieste nuove passano solo da `S3AlignmentCloud` (`AlignmentDeleteGuardTests` lo pretende leggendo il sorgente).
- **Fuori dal main** (BUG-7, ADR-0006): tutti i tipi nuovi del lavoro di fondo sono `nonisolated` con la riga sul perché sono sicuri, **anche le loro `extension`**; le funzioni async di fondo sono `@concurrent`; un test per motore in `MainThreadIsolationTests`.
- **Testi solo in `AlignmentStatus`**, italiano semplice, senza gergo («hash», «ETag», «MD5», «bucket», «DELETE», «segno di cancellazione», «versionId»); «versioni» sì (è la parola della spec).
- **Parametri nuovi senza default** (`isAligning:` nei sei cancelli): un chiamante che lo dimentica non compila. Per questo cambiano, senza toccare nessuna asserzione, le chiamate in 5 file di test esistenti (tabella sotto).
- Tutto il codice in **`AppBackupFoto/ContentView.swift`**; nove file di test nuovi registrati nel pbxproj nei **4 punti**. Si verifica sempre il totale `Executed N tests`. Un commit per task, messaggio in italiano, **mai `git push`**.

---

## Mappa dei file e dei tipi

**`AppBackupFoto/ContentView.swift`** (si ritrova tutto con `grep -n`; il codice nuovo sta, in ordine, prima di `// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)`):

| Dove | Cosa | Task |
| :--- | :--- | :--- |
| `// MARK: - Doppioni su HDD e Cubbit: le regole pure` | `AlignmentArchive`, `TrashHistoryReader`, `AlignmentStayReason`, `AlignmentCandidate`, `AlignmentPlan`, `AlignmentPlanner` (`plan`, `dropLeavingThatIsKept`, `localETagCandidates`), `AlignmentRunPlan.blocks` | 1 |
| `// MARK: - Doppioni su HDD e Cubbit: il registro` | `AlignmentLogEntry` (+ `init(from:)`), `AlignmentRemoval`, `AlignmentLogState`, `AlignmentLogStore` | 2 |
| `S3Syncer`, prima di `// MARK: - AWS Signature V4` | `BucketVersioning`, `LifecycleRule`, `DeleteResult`, `VersionEntry`, `VersionsPage`, `xmlTag`, `xmlBlocks`, `parseVersioning`, `parseLifecycle`, `parseDelete`, `parseVersionsPage`, `bucketGET`, `bucketVersioning`, `bucketLifecycleRules`, `listObjectVersions`, **`deleteObjectForAlignment`**, **`removeDeleteMarkerForAlignment`** | 3 |
| prima di `// MARK: - Testi e regole della card "Foto gia' salvate"` | `AlignmentCloud`, `S3AlignmentCloud`, `AlignmentCubbitSafety` | 3 |
| `// MARK: - Doppioni su HDD e Cubbit: il motore` | `AlignmentVolume`, `AlignmentSkipReason`, `AlignmentStopReason`, `AlignmentBlockOutcome`, `ArchiveAligner` (`runHDDBlock`) | 4 |
| `nonisolated extension ArchiveAligner` | `runCubbitBlock` | 5 |
| `TrashRestorer` | `markRestored` come closure; init di sempre `convenience` | 6 |
| dopo il Task 5 | `AlignmentUndoSkipReason`, `AlignmentUndoOutcome`, `AlignmentCubbitSafety.undoWindowDays`, `ArchiveAligner.undo` (`undoHDD`, `undoCubbit`) | 6 |
| `JobStartGate`, `LibraryIndexCommandGate`, `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason`, `InventoryStartGate`, `RepairStartGate` | parametro `isAligning` + motivo | 7 |
| dopo `RepairStartGate` | `AlignmentStartGate` | 7 |
| `BackupRunner` | `isAligning`, `beginAlignment`/`endAlignment`; `!isAligning` in `beginDuplicateTrashing`/`beginTrashRestore`/`beginRepair`; i 11 chiamanti dei cancelli | 7 |
| dopo il Task 6 | `AlignmentRunOutcome`, `AlignmentArchive: Identifiable`, `AlignmentStatus` | 8 |
| `InventoryStatus.readOnlyNote` | nomina anche «Togli le copie…» | 8 |
| `BackupRunner`, prima del commento su `autoRefreshLibraryIndexIfEnabled()` | registri, stato pubblicato, `refreshAlignmentLogSummaries`, `startAlignmentCheck`, `startAlignmentRun`, `startAlignmentUndo`, `stopAlignment`, `finishAlignment` | 8 |
| `InventoryView` | `alignmentSheet`/`confirmAlignment`, `alignmentSection`, `alignmentRow`, `alignmentSummarySheet`, foglio + conferma distruttiva | 8 |

**`AppBackupFotoTests/`** — nuovi: `AlignmentPlannerTests` (36), `AlignmentLogTests` (13), `S3AlignmentRequestsTests` (13), `AlignmentDeleteGuardTests` (3 + 1 + 1 = 5), `AlignmentEngineHDDTests` (21), `AlignmentEngineCubbitTests` (15), `AlignmentUndoTests` (14), `AlignmentGatesTests` (9), `AlignmentStatusTests` (15). Estesi: `MainThreadIsolationTests` (+5). Modificati **solo nelle chiamate** (Task 7, argomento nuovo, nessuna asserzione toccata): `JobStartGateTests`, `RepairGatesTests`, `DuplicatesStatusTests`, `InventoryRefreshTests`, `LibraryIndexStatusTests`. **Totale atteso: 1.266 + 146 = 1.412.**

### ID per il pbxproj (verificati assenti a `804a8b4` con `grep -c`)

| File | `PBXFileReference` | `PBXBuildFile` |
| :--- | :--- | :--- |
| `AlignmentPlannerTests.swift` | `C6630F6B6DF15983F7C25D6D` | `183FB83454EBD136296E630A` |
| `AlignmentLogTests.swift` | `2723B185AAD056DC017BA796` | `490EE9231B0D5B822970C686` |
| `S3AlignmentRequestsTests.swift` | `F59E71C22B8AD140F33522E3` | `A44FE3F7D6115F4D02AB5D08` |
| `AlignmentDeleteGuardTests.swift` | `A16ADC08B2099D6D2DE0B7C8` | `08A77EFB1DC9A8A53D84408B` |
| `AlignmentEngineHDDTests.swift` | `311B2D4961CF7D6923022FA2` | `9ABB6EBD16B49A14D3408973` |
| `AlignmentEngineCubbitTests.swift` | `879B1018208A1ABD4D67CFA9` | `598E3D2FCD5B978B1E59B750` |
| `AlignmentUndoTests.swift` | `E61512DE71A2D29F013B0318` | `505266521312027D46FB9EA9` |
| `AlignmentGatesTests.swift` | `E01F117656B0A6E86B75B940` | `CB2904422E18E0F974979839` |
| `AlignmentStatusTests.swift` | `3FF2996AA6FBF9DF90F10E3D` | `7739CCB7CDC3C57CDFAD71EE` |

Le quattro righe di ogni file seguono quelle di `DuplicateCertificationStatusTests.swift` (le scrive `apply.py`; a mano: stessa forma). Prima di usarli: `grep -c <ID> AppBackupFoto.xcodeproj/project.pbxproj` deve dare `0` (`apply.py` lo controlla da sé e si ferma senza scrivere).

---

## Comandi di build e test

1. **Verifica veloce** (~50 s, mai `xcodebuild`): `/private/tmp/claude-501/align-plan/fasttest.sh [Classe]` (con `REPO=<repository o worktree>`). Se `/private/tmp` è stato svuotato, ricrearlo dal testo integrale del piano `2026-10-05-certified-duplicates-ssd.md` («Comandi di build e test») cambiando `REPO=${REPO:-…}` e `SP=${SP:-/private/tmp/claude-501/align-plan/fast}`.
2. **`xcodebuild` in background** solo ai punti di controllo (fine Task 3, fine Task 8 e prima di unire il branch), dall'orchestratore, su un worktree; precondizione: nessun backup in corso nell'app di Enrico. Conteggio atteso **1.412**, 0 warning.
3. **Applicare una patch**: `/private/tmp/claude-501/align-plan/apply.py N` applica `proto/patches/0N-*.py` al vero `ContentView.swift` (si ferma senza scrivere niente se un «Trova» non compare esattamente una volta, o se un ID del pbxproj c'è già), copia i file di test del task da `proto/tests-tN/` e registra i file nuovi nel pbxproj (4 righe ciascuno). Se `/private/tmp` è stato svuotato, il testo integrale delle patch e dei test è nelle **Appendici A-C**: si applica a mano, «Trova» → «Sostituisci», nell'ordine.

**Nota su `AlignmentDeleteGuardTests`** (legge `ContentView.swift` accanto alla cartella dei test). Sotto `xcodebuild` il processo che esegue i test è l'app stessa: se macOS le negasse la lettura della cartella Scrivania (TCC), il test fallirebbe con «Non trovo ContentView.swift» o un errore di lettura — **non** in silenzio. In quel caso l'orchestratore non indebolisce il test: sposta i quattro conteggi in `Script/check-delete-guard.sh` (stessi `grep -c`, stessi numeri: `httpMethod = "DELETE"` = 3, `"?versionId="` = 1, `deleteObjectForAlignment(` = 2, `removeDeleteMarkerForAlignment(` = 2, `cloud.delete(key:` = 1, `cloud.removeDeleteMarker(` = 1), lo aggiunge alla checklist «IF il codice fa chiamate S3» e lo scrive nel riepilogo. Fuori da Xcode (`fasttest.sh`) il test gira e passa.

---

## Task 1 — Le regole pure: storia, condizioni 1-5, blocchi

**Files:** `ContentView.swift` (patch `01-alignment-rules.py`, 2 sostituzioni); test nuovo `AlignmentPlannerTests.swift` (36); `MainThreadIsolationTests` +1.

- [ ] **Step 1: test prima (rosso).** Copiare i test (Appendice B, o `apply.py 1` dopo lo Step 2). Senza la patch: `cannot find 'AlignmentPlanner' in scope`.
- [ ] **Step 2:** `apply.py 1`. Cosa fa: `AlignmentArchive`; `TrashHistoryReader.read` (file assente = storia vuota, illeggibile = `unreadable`, riga rotta = contata e saltata); `AlignmentStayReason` (16 motivi, nell'ordine della precedenza); `AlignmentCandidate` (percorsi come sono scritti sull'archivio **e** sull'SSD, dimensione della tenuta sull'SSD, contenuto, ETag normalizzati); `AlignmentPlan`; `AlignmentPlanner.plan`: storia → coppie relative alla radice dell'SSD (`.`/`..` guardati sul percorso scritto, prima della standardizzazione), `RepairPaths.safeComponents` (fuori la quarantena), P ≠ K normalizzati; una copia per percorso (ripetizioni con la stessa tenuta contano una volta, tenute diverse ⇒ resta); già tolta (dal registro); **condizione 4** (qualunque riga dell'SSD per P); **condizione 3** (K una volta sull'SSD, letta bene); **condizione 2**: HDD stesso SHA256 fra P e K sull'HDD e K sull'SSD, stesse dimensioni; Cubbit `S3ETagMatcher.verdict` certificato per P e K sullo stesso contenuto di K sull'SSD; collisioni di percorso ⇒ resta; difesa `dropLeavingThatIsKept`; ordine per tenuta. `AlignmentRunPlan.blocks` (tetti dei Doppioni, mai un blocco vuoto). Doc-comment di `TrashHistory`: da ADR-0019 la storia la legge `TrashHistoryReader`.
- [ ] **Step 3:** `fasttest.sh AlignmentPlannerTests` → 36; `fasttest.sh` → **`Executed 1303 tests, with 0 failures`**, 0 warning.
- [ ] **Step 4: revisione.** Nessuna operazione su file o rete; tipi `nonisolated`; un solo `S3ETagMatcher`, un solo `DuplicateInventoryFreshness`.
- [ ] **Step 5: commit** `Progetto 4, task 1: quali copie si possono togliere da HDD e Cubbit (regole pure, ADR-0019)`.

## Task 2 — Il registro

**Files:** `ContentView.swift` (patch `02-alignment-log.py`, 1 sostituzione); test nuovo `AlignmentLogTests.swift` (13); `MainThreadIsolationTests` +1.

- [ ] **Step 1: test prima (rosso):** `cannot find 'AlignmentLogStore' in scope`.
- [ ] **Step 2:** `apply.py 2`. Cosa fa: `AlignmentLogEntry` (eventi `pending`/`removed`/`failed`/`restored`, `init(from:)` severa su evento/identità/blocco/archivio/data); `AlignmentRemoval`; `AlignmentLogState` (copie tolte, «a metà», `removedKeys`, `lastBlockToRestore`, `lastBlockSummary`); `AlignmentLogStore` (allow-list, `O_APPEND`, `0600`, scrittura completa o eccezione, lettura che conta le righe rotte, file illeggibile ⇒ `nil`).
- [ ] **Step 3:** `fasttest.sh AlignmentLogTests` → 13; `fasttest.sh` → **1317**, 0 warning.
- [ ] **Step 4: revisione.** Il registro sta in Application Support (allow-list, BUG-10 sotto test); `append` lancia (diverso apposta da `TrashHistory.append`).
- [ ] **Step 5: commit** `Progetto 4, task 2: il registro delle copie tolte, in sola aggiunta`.

## Task 3 — Le richieste a Cubbit e la regola delle versioni

**Files:** `ContentView.swift` (patch `03-alignment-s3.py`, 2 sostituzioni); test nuovi `S3AlignmentRequestsTests.swift` (13), `AlignmentDeleteGuardTests.swift` (3).

- [ ] **Step 1: test prima (rosso):** `type 'S3Syncer' has no member 'parseVersioning'`.
- [ ] **Step 2:** `apply.py 3`. Cosa fa: in `S3Syncer` i parser puri (versioni: `Enabled`/`Suspended`/mai accese/altro; regole: forma «vecchio stile» con `<Prefix>` e forma con `<Filter>`, tutto il bucket solo senza prefisso né tag, `NoncurrentDays`, `Expiration` con `Days`/`Date` = farebbe sparire le foto attuali; 404 = nessuna regola; DELETE: segno e versione dalle intestazioni `x-amz-delete-marker`/`x-amz-version-id`, errore sopra 2xx; elenco versioni in ordine di documento, segni e versioni, voci rotte contate); `bucketVersioning`/`bucketLifecycleRules`/`listObjectVersions` (solo GET, firmate da `sign`, chiave esatta, pagine con `key-marker`/`version-id-marker`, lista incompleta ⇒ errore); `deleteObjectForAlignment` (DELETE senza versione sul percorso di `objectRequestPath`, lo stesso della HEAD); `removeDeleteMarkerForAlignment` (l'unico `?versionId=`). Fuori da `S3Syncer`: `AlignmentCloud`, `S3AlignmentCloud` (stessa forma di `S3RepairCloud`), `AlignmentCubbitSafety.evaluate` (D4).
- [ ] **Step 3:** `fasttest.sh S3AlignmentRequestsTests` → 13; `fasttest.sh AlignmentDeleteGuardTests` → 3; `fasttest.sh` → **1333**, 0 warning. Punto di controllo `xcodebuild` (vedi la nota su `AlignmentDeleteGuardTests`).
- [ ] **Step 4: revisione (checklist S3).** Tre `httpMethod = "DELETE"` in tutto il file; nessun PUT/POST sulla configurazione del bucket; `sign` invariata (`S3SignatureTests` verdi).
- [ ] **Step 5: commit** `Progetto 4, task 3: richieste a Cubbit (versioni, regole, DELETE) e regola dei 30 giorni`.

## Task 4 — Il motore sull'HDD

**Files:** `ContentView.swift` (patch `04-alignment-engine-hdd.py`, 1 sostituzione); test nuovo `AlignmentEngineHDDTests.swift` (21); `MainThreadIsolationTests` +1.

- [ ] **Step 1: test prima (rosso):** `cannot find 'ArchiveAligner' in scope`.
- [ ] **Step 2:** `apply.py 4`. Cosa fa: `AlignmentVolume`, `AlignmentSkipReason`, `AlignmentStopReason`, `AlignmentBlockOutcome`; `ArchiveAligner` (dipendenze iniettate solo dai test, `@Sendable`) con `runHDDBlock`, `@concurrent`. Per ogni copia, in quest'ordine: interruzione (solo fra una copia e l'altra); percorsi confinati con `RepairEngine.confined`, solo media, mai un collegamento simbolico; **`st_dev` dell'HDD e dell'SSD** come all'inizio; SSD dal vivo (P assente, K presente con la dimensione dell'inventario, D6); P e K presenti sull'HDD (altrimenti `st_dev` e salto); blocco «Bloccato» ⇒ salto (D3); P sullo stesso disco; **rilettura e rihash di P e di K**, uguali fra loro e all'inventario; riga **`pending`**; `trashItem`; riga **`removed`** con il percorso nel Cestino; post-condizione: K c'è ancora (se no stop, «Annulla» la rimette). Un `trashItem` fallito: riga `failed`, `st_dev`, «Bloccato» riletto (salto), altrimenti stop.
- [ ] **Step 3:** `fasttest.sh AlignmentEngineHDDTests` → 21; `fasttest.sh` → **1355**, 0 warning.
- [ ] **Step 4: revisione (checklist `trashItem`).** Percorso dentro la radice dell'HDD per componenti; P **e K** riletti e rihashati; K mai passato a `trashItem`; riga `pending` prima di `trashItem`, `removed` prima della copia successiva; `st_dev` a ogni copia e a ogni fallimento.
- [ ] **Step 5: commit** `Progetto 4, task 4: il motore sull'HDD (Cestino dell'HDD, ricontrollo dal vivo)`.

## Task 5 — Il motore su Cubbit

**Files:** `ContentView.swift` (patch `05-alignment-engine-cubbit.py`, 1 sostituzione); test nuovo `AlignmentEngineCubbitTests.swift` (15, con il Cubbit finto con le versioni `FakeAlignmentCloud`); `AlignmentDeleteGuardTests` +1; `MainThreadIsolationTests` +1.

- [ ] **Step 1: test prima (rosso):** `value of type 'ArchiveAligner' has no member 'runCubbitBlock'`.
- [ ] **Step 2:** `apply.py 5`. Cosa fa: `nonisolated extension ArchiveAligner` con `runCubbitBlock`, `@concurrent`. Prima del blocco: versioni e regole lette, `AlignmentCubbitSafety.evaluate` deve dire `.ready`, altrimenti il blocco non parte (condizione 7). Per ogni copia: percorsi sicuri, ETag noti, P ≠ K; SSD dal vivo; **HEAD della tenuta** (c'è, stessa dimensione ed ETag dell'inventario) e **HEAD della copia** (se non c'è: salto «già sparita»); riga `pending` con l'ETag; **DELETE senza versione**; se la risposta non ha il segno con la sua versione: riga `removed` senza versione e **stop immediato**; altrimenti riga `removed` con la versione del segno.
- [ ] **Step 3:** `fasttest.sh AlignmentEngineCubbitTests` → 15; `fasttest.sh` → **1372**, 0 warning.
- [ ] **Step 4: revisione (checklist S3).** Un solo `cloud.delete(key:` nel file; versioni lette nello stesso blocco; mai un DELETE senza le due HEAD e la riga `pending`.
- [ ] **Step 5: commit** `Progetto 4, task 5: il motore su Cubbit (versioni lette prima di ogni blocco)`.

## Task 6 — «Annulla l'ultimo blocco»

**Files:** `ContentView.swift` (patch `06-alignment-undo.py`, 5 sostituzioni: 4 in `TrashRestorer`); test nuovo `AlignmentUndoTests.swift` (14); `AlignmentDeleteGuardTests` +1; `MainThreadIsolationTests` +1.

- [ ] **Step 1: test prima (rosso):** `value of type 'ArchiveAligner' has no member 'undo'`.
- [ ] **Step 2:** `apply.py 6`. Cosa fa: `TrashRestorer` riceve `markRestored` come closure (D10); l'init di sempre diventa `convenience` e costruisce la closure dal registro dei Doppioni, nessun chiamante cambia. `AlignmentUndoSkipReason`, `AlignmentUndoOutcome`, `AlignmentCubbitSafety.undoWindowDays`. `ArchiveAligner.undo` (`@concurrent`): HDD con `TrashRestorer` sulla radice dell'HDD (le voci senza percorso nel Cestino non si toccano; esiti mappati; riga `restored` per ogni copia tornata o già al suo posto); Cubbit: giorni della regola (un giorno di margine), HEAD (già tornata ⇒ `restored`; un'altra foto ⇒ non si tocca), **`ListObjectVersions`: la versione registrata deve essere un segno ed essere l'ultimo stato della chiave**, poi DELETE con quella versione, poi HEAD con dimensione ed ETag registrati.
- [ ] **Step 3:** `fasttest.sh AlignmentUndoTests` → 14; `fasttest.sh TrashRestorerTests` → 18 (invariati); `fasttest.sh` → **1388**, 0 warning.
- [ ] **Step 4: revisione.** Un solo `cloud.removeDeleteMarker(` nel file; mai su `isDeleteMarker == false`; HDD: zero-overwrite di `TrashRestorer` invariato.
- [ ] **Step 5: commit** `Progetto 4, task 6: Annulla l'ultimo blocco (Cestino dell'HDD, segni di cancellazione su Cubbit)`.

## Task 7 — Una corsa alla volta, nei due versi

**Files:** `ContentView.swift` (patch `07-alignment-gates.py`, 28 sostituzioni); test nuovo `AlignmentGatesTests.swift` (9); chiamate aggiornate in 5 file (tabella sotto).

- [ ] **Step 1: test prima (rosso):** `extra argument 'isAligning' in call`.
- [ ] **Step 2:** `apply.py 7`. Cosa fa: `isAligning:` senza default in `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason`, `InventoryStartGate.blockedReason`, `RepairStartGate.blockedReason`, ognuno con il suo motivo subito dopo quello della riparazione; `AlignmentStartGate.blockedReason(archive:…)` (precedenza: altra corsa > spostamento/annullamento > riparazione > inventario > backup > lettura dell'elenco > SSD > HDD solo per l'HDD > credenziali solo per Cubbit); `BackupRunner.isAligning` + `beginAlignment`/`endAlignment`; `!isAligning` in `beginDuplicateTrashing`, `beginTrashRestore`, `beginRepair`; gli 11 chiamanti. **Non toccati, con il motivo**: `LibraryIndexCommandGate.resetDisabledReason` (svuotare l'elenco svuota anche l'inventario: la corsa se ne accorge al blocco dopo e si ferma con «inventario mai fatto»); `BackupListStep.shouldRun` (già dentro `isRunning`); ripristino e campione d'integrità (sola lettura).
- [ ] **Step 3:** `fasttest.sh AlignmentGatesTests` → 9; `fasttest.sh` → **1397**, 0 warning.
- [ ] **Step 4: revisione.** Ogni `begin…` guarda tutti gli altri flag; nessun cancello con un default su `isAligning`.
- [ ] **Step 5: commit** `Progetto 4, task 7: mutua esclusione con backup, inventario, riparazione e Doppioni`.

## Task 8 — La finestra Inventario e il runner

**Files:** `ContentView.swift` (patch `08-alignment-runner-ui.py`, 8 sostituzioni); test nuovo `AlignmentStatusTests.swift` (15).

- [ ] **Step 1: test prima (rosso):** `cannot find 'AlignmentStatus' in scope`.
- [ ] **Step 2:** `apply.py 8`. Cosa fa: `AlignmentRunOutcome`; `AlignmentStatus` (tutti i testi: piano, motivi, stato di Cubbit, riepilogo, conferma, avanzamento, stop, esiti, annullamento, copie «a metà»); `InventoryStatus.readOnlyNote` nomina anche «Togli le copie…». Nel runner: due registri `lazy`; `startAlignmentCheck` (fuori dal main: storia, registro, inventario, piano; per Cubbit anche versioni e regole); `startAlignmentRun` (precondizioni all'avvio vero, `beginAlignment` per tutta la corsa, prima di ogni blocco SSD/HDD collegati e `DuplicateCertification.runBlock` con il giro del piano, avanzamento ogni 25 copie, stop sul primo guasto; a fine corsa il piano si azzera); `startAlignmentUndo`; `stopAlignment` (idempotente); `finishAlignment` unico punto di fine. In `InventoryView`: sezione in fondo alle categorie (D1), per HDD e Cubbit: «Controlla senza togliere», «Togli le copie…» (attivo solo con un piano che certifica qualcosa e, per Cubbit, versioni lette `.ready`), «Annulla l'ultimo blocco» (con conferma), barra e «Interrompi», righe di stato; foglio del riepilogo → conferma distruttiva → `startAlignmentRun`.
- [ ] **Step 3:** `fasttest.sh AlignmentStatusTests` → 15; `fasttest.sh` → **1412**, 0 warning. Punto di controllo `xcodebuild` in background: **1.412**, `TEST SUCCEEDED`, 0 warning.
- [ ] **Step 4: revisione.** Nessun `filter`/`reduce` nel `body` (le righe arrivano già calcolate dal runner); nessun avviso su `runner.pendingAlert` (canale della finestra); il piano della corsa è quello del controllo (`alignmentPlans`), mai ricalcolato.
- [ ] **Step 5: commit** `Progetto 4, task 8: la sezione nella finestra Inventario e la corsa a blocchi`.

## Task 9 — Documentazione (testi da approvare in D11)

- [ ] **`Docs/adr/0019-le-copie-gia-tolte-dall-ssd-si-tolgono-da-hdd-e-cubbit-solo-se-la-copia-tenuta-e-identica-li.md`** (nuovo, testo integrale):

> # ADR-0019 — Le copie già tolte dall'SSD si tolgono da HDD e Cubbit solo se la copia tenuta è identica lì e c'è ancora sull'SSD
>
> **Data:** 2026-10-10 (spec), piano dello stesso giorno
> **Stato:** Proposta (diventa «Accettata» con le risposte di Enrico in fondo)
>
> ## Contesto
>
> Il progetto 3 (ADR-0017, ROADMAP #46) ha tolto dall'SSD 89.442 copie doppie (47 blocchi, 2026-10-06/07); HDD e Cubbit le hanno ancora tutte, 144 GB ciascuno. Il backup copia solo ciò che manca e non cancella mai, quindi non le toglierà da solo. È il progetto 4 di 4 verso «una copia per archivio» (ADR-0015/0016/0017). Togliere una copia dall'HDD o da Cubbit apre due porte nuove nella regola «zero delete»: il Cestino dell'HDD e il DELETE su Cubbit. Spec `Docs/superpowers/specs/2026-10-10-archive-alignment-hdd-cubbit-design.md`; piano `Docs/superpowers/plans/2026-10-10-archive-alignment-hdd-cubbit.md`.
>
> Fatti verificati prima di progettare (2026-10-10): su un bucket di prova Cubbit accetta le versioni e la regola di scadenza solo «vecchio stile» (`Prefix` vuoto); un DELETE senza versione crea un segno di cancellazione e la versione resta; togliere il segno con la sua versione fa tornare l'oggetto identico. Sul bucket vero le versioni non sono accese. L'inventario di oggi certifica tutte le 89.442 copie su entrambi gli archivi; Cubbit risponde ~110 ms a richiesta; sull'HDD nessuna copia è bloccata.
>
> ## Opzioni valutate
>
> - **A. Lasciare tutto com'è.** Scartata da Enrico: 144 GB in più su HDD e Cubbit, e tre archivi diversi.
> - **B. Rifare il pannello Doppioni su HDD e su Cubbit** (gruppi propri di ciascun archivio). Scartata (decisione 1 di Enrico): la scelta di cosa tenere è già stata fatta e verificata sull'SSD; rifarla altrove potrebbe tenere copie diverse nei tre archivi. I doppioni che esistono solo su HDD o Cubbit restano fuori.
> - **C. Uno specchio che cancella** (l'HDD e Cubbit diventano uguali all'SSD togliendo tutto ciò che sull'SSD non c'è). Scartata: è esattamente il «delete» che la regola assoluta esiste per impedire; un SSD letto a metà o rovinato si propagherebbe agli altri due.
> - **D. Togliere solo le copie della storia degli spostamenti, con la stessa copia tenuta, a condizioni verificate (scelta).**
>
> ## Decisione e motivo
>
> **Quali copie:** solo quelle nella storia degli spostamenti dell'SSD (`trash-history.jsonl`), con la copia che l'SSD ha tenuto (`keptPaths`). La storia, che fino a ADR-0012 non si leggeva mai per decidere, diventa l'elenco di partenza (`TrashHistoryReader`); una riga illeggibile non porta copie.
>
> **Quando una copia si toglie da un archivio** (tutte le condizioni): inventario completo sui tre archivi e più recente dell'ultimo backup o import (stessa regola e stessa funzione di ADR-0017), ricontrollato prima di ogni blocco; la copia tenuta c'è sull'archivio con lo stesso contenuto (HDD: stesso SHA256; Cubbit: stessa certificazione per contenuto dell'inventario, ADR-0015) ed è la stessa che c'è sull'SSD; la copia uscita non è tornata sull'SSD; i due percorsi sono diversi e nessuno dei due collide con un altro senza maiuscole; ricontrollo dal vivo subito prima: SSD (la copia non c'è, la tenuta c'è con la stessa dimensione), HDD (rilettura e rihash di entrambe) o Cubbit (HEAD di entrambe); su Cubbit le versioni accese e le regole lette prima di ogni blocco.
>
> **Come:** sull'HDD `trashItem` nel Cestino dell'HDD (stesso volume); su Cubbit DELETE senza versione (il segno di cancellazione lascia la versione per 30 giorni). Una copia alla volta, a blocchi da 2.000, dopo un controllo senza togliere, un riepilogo e una conferma. Registro in sola aggiunta sul Mac, una riga prima di toccare la copia e una dopo. «Annulla l'ultimo blocco»: dal Cestino con la cura di `TrashRestorer`; su Cubbit togliendo solo un segno di cancellazione registrato, confermato come segno e ultimo stato della chiave, entro i giorni della regola, con la HEAD dopo. Una corsa alla volta, in mutua esclusione con backup, inventario, riparazione e Doppioni, nei due versi.
>
> **L'app non cambia mai la configurazione del bucket**: legge versioni e regole, non le scrive. Le versioni le accende Enrico con Claude, dal terminale, subito prima della prima pulizia vera.
>
> **Cosa si accetta di perdere:** l'HDD libera spazio solo quando Enrico svuota il suo Cestino; Cubbit dopo 30 giorni; una corsa su Cubbit dura ore (una copia alla volta, ~0,35 s); l'SSD deve restare collegato durante le corse (D6); un DELETE senza segno, se Cubbit lo facesse nonostante le versioni lette accese, cancella quella copia per sempre prima che la corsa si fermi (la copia tenuta resta su Cubbit, SSD e HDD); dopo una corsa l'inventario va aggiornato perché la finestra Inventario rifletta i nuovi numeri.
>
> **Per riaprirla** serve un argomento nuovo: per esempio doppioni che esistono solo su HDD o Cubbit (un progetto a parte), checksum SHA256 lato server su Cubbit, o una misura che mostri copie della storia che le condizioni bloccano in massa.
>
> ## Risposte di Enrico (D1-D12)
>
> (da compilare all'approvazione del piano)

- [ ] **`Docs/CLAUDE.md`**, «Regola assoluta», punto 1 (**testo proposto, da approvare parola per parola**): il testo di oggi resta per intero come «prima porta»; cambiano l'inizio e si aggiunge la seconda. Nuovo inizio: «1. **Zero delete.** Nessun percorso di codice cancella un file foto. **Due porte sole.** *La prima, aperta il 2026-08-27*: il pannello Doppioni può spostare nel **Cestino del volume** …» (seguito invariato fino a «… mai un file la cui unica copia sparisce.»). Poi, prima di «Tutto il resto del progetto resta a zero delete.», aggiungere: «*La seconda, aperta il 2026-10-10 (ADR-0019)*: la sezione «Copie già tolte dall'SSD» della finestra Inventario può togliere dall'**HDD** e da **Cubbit** solo le copie che la storia degli spostamenti dell'SSD dice già uscite dall'SSD, una alla volta, e per ciascuna solo se l'ultimo inventario — completo su SSD, HDD e Cubbit e più recente dell'ultimo backup o import, ricontrollato prima di ogni blocco — vede la copia che l'SSD ha tenuto presente sull'SSD e identica sullo stesso archivio (sull'HDD stesso contenuto letto, su Cubbit stessa certificazione per contenuto), la copia da togliere non più sull'SSD e con un percorso diverso dalla tenuta; e solo dopo che, subito prima di toglierla, l'app ha ricontrollato dal vivo l'SSD (la copia non c'è, la tenuta c'è) e l'archivio (sull'HDD rilette e rihashate entrambe le copie, su Cubbit entrambe chieste con una HEAD) e ha scritto la riga del registro. Sull'HDD la copia va nel **Cestino dell'HDD** (`trashItem`, stesso volume), mai `removeItem`, e l'app non lo svuota mai. Su Cubbit si toglie con un DELETE **senza versione**, solo se le versioni del bucket sono accese e le regole fanno sparire le versioni vecchie di tutto il bucket e mai prima di 30 giorni (lette prima di ogni blocco, mai cambiate dall'app); un DELETE che non crea il segno di cancellazione ferma tutto; l'unico DELETE con versione ammesso toglie un segno di cancellazione registrato, per annullare. Sempre dopo un controllo senza togliere, un riepilogo e una conferma.»
- [ ] **`Docs/CLAUDE.md`**, punto 3 (**testo proposto**): sostituire «Nessun'altra funzione scrive sull'SSD. L'inventario (ADR-0015) legge SSD, HDD e Cubbit e scrive solo nel database dell'app sul Mac.» con «Nessun'altra funzione scrive sull'SSD: la seconda porta del punto 1 (ADR-0019) legge l'SSD e non lo tocca mai. L'inventario (ADR-0015) legge SSD, HDD e Cubbit e scrive solo nel database dell'app sul Mac; dalla stessa finestra scrivono solo «Ripara…» (punto 2) e «Togli le copie…» (punto 1, seconda porta, solo su HDD e Cubbit).»
- [ ] **`Docs/CLAUDE.md`**, nota sotto la regola: «> I punti **1** e **3** sono stati riscritti il **2026-10-10** (testo approvato da Enrico, ADR-0019): con i doppioni su HDD e Cubbit sarebbero diventati falsi. Stessa ragione del 2026-08-28: una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa.»
- [ ] **`Docs/CLAUDE.md`**, checklist (**testo proposto**):
  - «IF il codice chiama `trashItem`», prima riga: «THEN verifica che il percorso sia dentro la root della libreria (l'SSD per i Doppioni, l'HDD per ADR-0019), confrontato per componenti canoniche»; riga nuova in fondo: «THEN, sull'HDD (ADR-0019): verifica che la copia venga dalla storia degli spostamenti (`AlignmentPlanner`), che copia e tenuta siano state rilette e rihashate entrambe, che l'SSD sia stato ricontrollato dal vivo (copia assente, tenuta presente), che `st_dev` dell'HDD e dell'SSD si ricontrolli a ogni copia e che la riga `pending` del registro sia scritta prima di `trashItem` e `removed` prima della copia successiva (`ArchiveAligner.runHDDBlock`)».
  - «IF il codice fa chiamate S3», la prima riga diventa: «THEN verifica che non ci siano DELETE, con due eccezioni sole: AbortMultipartUpload su cancel (non tocca dati già scritti) e, da ADR-0019, `S3Syncer.deleteObjectForAlignment`/`removeDeleteMarkerForAlignment`, chiamate solo da `S3AlignmentCloud` per `ArchiveAligner` (`AlignmentDeleteGuardTests` conta le richieste DELETE nel sorgente)»; righe nuove: «THEN, per il DELETE di ADR-0019: verifica che parta solo con `AlignmentCubbitSafety.evaluate` = `.ready` letto nello stesso blocco, dopo la HEAD della copia e della tenuta con dimensione ed ETag dell'inventario e la riga `pending` già scritta; che sia SENZA versione; che una risposta senza segno di cancellazione fermi la corsa» · «THEN verifica che l'unico DELETE con `versionId` tolga un segno di cancellazione registrato, dopo `ListObjectVersions` che lo conferma segno e ultimo stato della chiave (`ArchiveAligner.undoCubbit`)» · «THEN verifica che l'app non scriva mai la configurazione del bucket (versioni, regole): solo GET».
- [ ] **`Docs/CLAUDE.md`**, tabella «Stato attuale»: riga nuova «Doppioni su HDD e Cubbit (#47)» con «⏳ Implementato (data) su `feature/archive-alignment`, ADR-0019: … Verifica dal vivo ancora da fare — non marcarlo "fatto"»; riga «Test automatici» (1.266 → 1.412, con i nove file nuovi e i cinque toccati nelle sole chiamate); un «nono tocco» nel paragrafo della data della tabella.
- [ ] **`Docs/ROADMAP.md`**, dopo #46: «47. ⏳ **Implementato il (data), verifica dal vivo ancora da fare — doppioni su HDD e Cubbit (progetto 4 di 4).** Spec `Docs/superpowers/specs/2026-10-10-archive-alignment-hdd-cubbit-design.md`, piano `Docs/superpowers/plans/2026-10-10-archive-alignment-hdd-cubbit.md`, ADR-0019. Le 89.442 copie già tolte dall'SSD si tolgono anche dall'HDD (Cestino dell'HDD) e da Cubbit (DELETE con le versioni accese e la regola dei 30 giorni), solo se la copia tenuta è identica sullo stesso archivio e c'è ancora sull'SSD, con ricontrollo dal vivo, registro, «Annulla l'ultimo blocco» e una corsa alla volta. Prima della corsa su Cubbit, le versioni sul bucket `backupfoto` vanno accese da Enrico con Claude.»
- [ ] **`.claude/rules/architecture.md`**: sezione nuova «### Doppioni su HDD e Cubbit (2026-10-10, roadmap #47, ADR-0019)» dopo «Riparazione con la regola «2 su 3»», con i pezzi della «Mappa dei file e dei tipi» (regole pure, registro, richieste a Cubbit e `AlignmentCubbitSafety`, motore HDD/Cubbit, annullamento, cancelli, runner e finestra) e la riga «Non coperto da test, dichiarato: il cablaggio in `BackupRunner` e `InventoryView`; le richieste vere a Cubbit». Nella sezione `S3Syncer`: «Richieste del progetto 4 (ADR-0019)» (le due GET di configurazione, l'elenco delle versioni, i due DELETE e chi li chiama). Nella sezione «Isolamento MainActor di default», sotto «La regola per annotare `nonisolated`»: «**`nonisolated` su un tipo non si estende alle sue `extension`** (trovato il 2026-10-10 scrivendo il piano del progetto 4): i membri di un'`extension` non annotata sono `@MainActor` per il default del target, e una funzione `async` senza `@concurrent` lì dentro salta sul main senza nessun warning. Si scrive `nonisolated extension`.» Nella sezione `TrashHistory`/pannello Doppioni: la storia ora la legge `TrashHistoryReader` (ADR-0019). Nella sezione mutua esclusione: paragrafo «2026-10-10 (ROADMAP #47, ADR-0019): `isAligning` entra negli stessi cancelli», con i non toccati e il perché.
- [ ] **`Docs/CONTEXT.md`**: voce «copia già tolta dall'SSD» (una voce della storia degli spostamenti; su HDD e Cubbit si toglie solo con la tenuta identica lì e presente sull'SSD).
- [ ] Commit `Progetto 4, task 9: documentazione (ADR-0019, regola assoluta, architettura, ROADMAP #47)`.

## Task 10 — Verifica dal vivo (orchestratore con Enrico; l'agente non scrive su `/Volumes` né su Cubbit)

Build Release installata da Enrico, SSD e HDD collegati, Cubbit raggiungibile. Nell'ordine della spec:

0. **Prima di toccare il bucket vero, sul bucket di prova `backupfoto-prova-versioni`** (orchestratore, terminale, `--debug` per vedere l'XML grezzo): `get-bucket-versioning` (atteso `<Status>Enabled</Status>`), `get-bucket-lifecycle-configuration` (che forma ha la risposta: `<Prefix>` o `<Filter>`; il parser accetta entrambe), `list-object-versions --prefix <una chiave>` dopo un DELETE (che ci sia un blocco `<DeleteMarker>` con `<IsLatest>true</IsLatest>`). Se una delle tre risposte ha una forma diversa da quella dei test di `S3AlignmentRequestsTests`, ci si ferma e si torna all'Architect: una forma non riconosciuta fa fallire il controllo nel verso sicuro (nessuna copia tolta, o nessun annullamento), ma «Annulla» non funzionerebbe.
1. **Inventario fresco** (dopo l'ultimo backup).
2. **HDD**: «Controlla senza togliere» → atteso «si possono togliere 89.436 copie (~144 GB)», 6 «compaiono più volte nella storia», nient'altro. Poi **un blocco piccolo**: «Togli le copie…», conferma, e «Interrompi» dopo poche decine di copie (la corsa si ferma fra una copia e l'altra; nessuna modifica al codice). Verificare: le copie tolte sono in `/Volumes/BackupHDD/.Trashes/501/`; la copia tenuta è al suo posto sull'HDD; l'SSD non è cambiato (stessa data e dimensione dei file toccati); `alignment-hdd.jsonl` ha una riga `pending` e una `removed` per copia. Poi **«Annulla l'ultimo blocco»** → le copie tornano, il Cestino dell'HDD non le ha più, righe `restored`. Poi «Controlla senza togliere» di nuovo e la corsa completa (~1-1,5 ore). Poi la corsa completa (~1-1,5 ore). Esito atteso: «Tolte da HDD 89.436 copie».
3. **Cubbit**: accensione delle versioni e della regola sul bucket `backupfoto` (con Enrico, dal terminale: `put-bucket-versioning --versioning-configuration Status=Enabled`, `put-bucket-lifecycle-configuration` con la regola «vecchio stile» da 30 giorni verificata sul bucket di prova). «Controlla senza togliere» → la riga «Su Cubbit le versioni sono accese: … 30 giorni», e il conteggio. Un blocco piccolo (come sopra), poi «Annulla l'ultimo blocco» con verifica: per due copie, `head-object` dopo l'annullamento ha lo **stesso ETag** di prima (scritto nel registro). Poi la corsa (~8-9 ore, anche in più volte: le copie già tolte si saltano da sole). Durante la corsa: un `head-object` su una copia appena tolta risponde 404; `list-object-versions` mostra la versione e il segno.
4. **Inventario finale**: HDD e Cubbit con **52.250** file foto/video ciascuno, l'SSD con 52.169: le 81 in più sono le copie spostate dall'SSD prima che la storia esistesse (vedi «Fatti letti»), fuori da questo progetto. Nessuna categoria ⚠️ nuova.
5. Fuori dalla prova, da ricordare a Enrico: svuotare il Cestino dell'HDD quando vuole (l'app non lo fa); su Cubbit lo spazio si libera dopo 30 giorni; il bucket di prova resta fino al 2026-11-10 per verificare la scadenza (decisione 6 della spec).

---

## Modifiche ai test esistenti (solo chiamate, nessuna asserzione cambiata)

| Task | File | Trova | Sostituisci | Volte |
| :--- | :--- | :--- | :--- | ---: |
| 7 | `JobStartGateTests`, `RepairGatesTests`, `DuplicatesStatusTests`, `LibraryIndexStatusTests` | regex `isRepairing: (true\|false)\)` | `isRepairing: \1, isAligning: false)` | 77 |
| 7 | `RepairGatesTests` | `isRepairing: true,⏎` (chiamate dirette a `InventoryStartGate`/`RepairStartGate`) | `isRepairing: true, isAligning: false,⏎` | 2 |
| 7 | `RepairGatesTests`, `InventoryRefreshTests` | `isRepairing: Bool = false,` (firma degli aiuti dei test) | `isRepairing: Bool = false, isAligning: Bool = false,` | 2 |
| 7 | `RepairGatesTests`, `InventoryRefreshTests` | `isRepairing: isRepairing,` (corpo degli aiuti) | `isRepairing: isRepairing, isAligning: isAligning,` | 2 |
| 1, 2, 4, 5, 6 | `MainThreadIsolationTests` | (in coda alla classe) | un test per tipo/motore nuovo (Appendice C) | +5 |
| 5, 6 | `AlignmentDeleteGuardTests` | (in coda alla classe) | +1 per il DELETE del motore, +1 per l'annullamento (Appendice C) | +2 |

Lo script che fa le sostituzioni del Task 7 è in Appendice C (le versioni già trasformate sono in `proto/tests-t7/`).

---

## Punti della spec rischiosi o da completare (trovati scrivendo il piano)

1. **Condizioni 3 e 4 solo sull'inventario non bastano.** «Annulla l'ultimo spostamento» e gli spostamenti dei Doppioni non invecchiano l'inventario (ADR-0017): dopo l'inventario una copia può tornare sull'SSD, o la tenuta lasciarlo, senza che l'inventario lo sappia. Il piano aggiunge il ricontrollo dal vivo sull'SSD (D6), che costa due `stat` per copia e l'SSD collegato.
2. **«Circa 164 GB»**: misurati 144,3 GB per archivio (somma delle dimensioni delle copie). Il riepilogo mostra il numero calcolato, non quello della spec.
3. **La storia non era fatta per essere letta.** Il doc-comment di `TrashHistory` (ADR-0012) dice che non legge mai il proprio contenuto per decidere niente: resta vero per `TrashHistory`, ma da ADR-0019 la legge `TrashHistoryReader`. Righe illeggibili: le loro copie restano (verso sicuro), e si contano.
4. **Le risposte di Cubbit a `GET ?lifecycle` e `ListObjectVersions` non sono ancora state viste nella loro forma XML** (solo tramite `aws`, che le traduce). I parser accettano le due forme documentate; una forma diversa fa fallire nel verso sicuro (nessuna copia tolta, o nessun annullamento). Il passo 0 della verifica dal vivo le guarda sul bucket di prova **prima** di accendere le versioni su `backupfoto`.
5. **Un DELETE senza segno di cancellazione è definitivo.** Le versioni si leggono prima di ogni blocco e la risposta di ogni DELETE si controlla (stop immediato), ma se qualcuno sospendesse le versioni a metà blocco, al massimo una copia sparirebbe davvero prima dello stop. Il suo contenuto resta nella copia tenuta (su Cubbit, SSD e HDD). Solo Enrico e Claude cambiano le versioni, dal terminale.
6. **Durata su Cubbit: ~8-9 ore** una copia alla volta (D7). La corsa si interrompe e riprende senza perdere niente.
7. **81 copie doppie restano fuori** (spostate prima della storia): HDD e Cubbit avranno 81 file in più dell'SSD.
8. **Il test che legge il sorgente** (`AlignmentDeleteGuardTests`) potrebbe non poter leggere la Scrivania sotto `xcodebuild` (TCC): ripiego già scritto nella sezione «Comandi di build e test».

## Fuori scope e limiti dichiarati

- Doppioni presenti solo su HDD o solo su Cubbit; le 81 copie spostate prima della storia.
- Svuotare il Cestino dell'HDD; gestire versioni o regole del bucket (l'app le legge soltanto).
- Il registro senza `fsync` (D8): uno spegnimento brusco può perdere le ultime righe; le copie restano recuperabili a mano (Cestino dell'HDD, versioni di Cubbit), il controllo successivo le vede come «già sparite».
- Righe `pending` senza esito (app chiusa a metà copia): la finestra le conta e dice di controllarle a mano; «Annulla» non le tocca.
- **Non coperti da test (SwiftUI, bookmark, rete veri), dichiarati**: `startAlignmentCheck`/`startAlignmentRun`/`startAlignmentUndo`/`finishAlignment`, `S3AlignmentCloud`, le cinque richieste vere a Cubbit, la sezione di `InventoryView`, `beginAlignment`. È testato tutto ciò che sta ai due capi del cablaggio (regole, registro, parser, motore con dischi in cartelle temporanee e Cubbit finto, annullamento, cancelli, testi).

---

## Mutanti verificati

Prova: `proto/mutate.py` (ogni mutante sullo stato del Task 8, compilazione completa, esecuzione della classe indicata; atteso almeno un fallimento). Definizioni in `proto/mutants/all.py`, esiti in `proto/mutants.log`. Le guardie chieste dall'orchestratore: copia tenuta presente (M01 sull'SSD, M28 sull'archivio, M29 dal vivo sull'HDD, M18 dal vivo su Cubbit), controllo delle versioni (M16, M17), ricontrollo dal vivo (M09, M10, M18), P ≠ K (M03), P tornata sull'SSD (M02, M10).

| # | Mutante | Classe | Esito |
| :--- | :--- | :--- | :--- |
| M01 | piano: niente condizione 3 (tenuta sull'SSD) | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M02 | piano: niente condizione 4 (copia tornata sull'SSD) | `AlignmentPlannerTests` | ucciso (4 fallimenti su 36) |
| M03 | piano: niente confronto P != K | `AlignmentPlannerTests` | ucciso — 1 fallimenti su 36 |
| M04 | piano HDD: non confronta con la tenuta sull'SSD | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M05 | piano Cubbit: non confronta P e K | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M06 | piano: niente controllo delle collisioni | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M07 | piano: freschezza senza l'ultimo backup | `AlignmentPlannerTests` | ucciso (3 fallimenti su 36) |
| M08 | piano: niente difesa «tenuta di un'altra voce» | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M09 | motore HDD: rihash solo della copia che esce | `AlignmentEngineHDDTests` | ucciso (2 fallimenti su 21) |
| M10 | motore: niente ricontrollo dal vivo sull'SSD | `AlignmentEngineHDDTests` | ucciso (5 fallimenti su 21) |
| M11 | motore HDD: registro dopo lo spostamento | `AlignmentEngineHDDTests` | ucciso (4 fallimenti su 21) |
| M12 | motore HDD: niente st_dev dell'HDD a ogni copia | `AlignmentEngineHDDTests` | ucciso (3 fallimenti su 21) |
| M13 | motore HDD: trashItem fallito = salta e prosegue | `AlignmentEngineHDDTests` | ucciso — 1 fallimenti su 21 |
| M14 | motore HDD: blocco «Bloccato» non riletto dopo il fallimento | `AlignmentEngineHDDTests` | ucciso (2 fallimenti su 21) |
| M15 | motore HDD: niente post-condizione sulla tenuta | `AlignmentEngineHDDTests` | ucciso — 1 fallimenti su 21 |
| M16 | motore Cubbit: niente controllo delle versioni | `AlignmentEngineCubbitTests` | ucciso (9 fallimenti su 15) |
| M17 | regola: versioni accese bastano (niente 30 giorni) | `S3AlignmentRequestsTests` | ucciso (6 fallimenti su 13) |
| M18 | motore Cubbit: niente HEAD della copia tenuta | `AlignmentEngineCubbitTests` | ucciso (3 fallimenti su 15) |
| M19 | motore Cubbit: DELETE senza segno non ferma | `AlignmentEngineCubbitTests` | ucciso (3 fallimenti su 15) |
| M20 | annullamento Cubbit: toglie anche versioni di dati | `AlignmentUndoTests` | ucciso — 1 fallimenti su 14 |
| M21 | annullamento Cubbit: niente limite dei giorni | `AlignmentUndoTests` | ucciso (3 fallimenti su 14) |
| M22 | annullamento Cubbit: niente HEAD di verifica | `AlignmentUndoTests` | ucciso — 1 fallimenti su 14 |
| M23 | cancello dei job: ignora la corsa | `AlignmentGatesTests` | ucciso (3 fallimenti su 9) |
| M24 | cancello della corsa: ignora il backup | `AlignmentGatesTests` | ucciso (4 fallimenti su 9) |
| M25 | isolamento: estensione dell'annullamento senza nonisolated | `MainThreadIsolationTests` | ucciso — 1 fallimenti su 28 |
| M26 | S3: un DELETE risponde sempre «segno creato» | `S3AlignmentRequestsTests` | ucciso — 1 fallimenti su 13 |
| M27 | S3: un secondo DELETE con versione | `AlignmentDeleteGuardTests` | ucciso (2 fallimenti su 5) |
| M28 | piano HDD: niente controllo «tenuta sull'archivio» | `AlignmentPlannerTests` | ucciso (2 fallimenti su 36) |
| M29 | motore HDD: niente controllo dal vivo «tenuta sull'HDD» | `AlignmentEngineHDDTests` | ucciso — 1 fallimenti su 21 |

29 su 29 uccisi.

**29 su 29 uccisi** (l'ultima esecuzione di ciascuno; il primo giro è in `proto/mutants-giro1.log`). Tre correzioni nate dai mutanti, già nei test del piano:
- **M04 era sopravvissuto** al primo giro: il test «stesso contenuto della tenuta sull'SSD» usava testi di lunghezza diversa, quindi lo fermava già il confronto delle dimensioni e il confronto del contenuto non era mai isolato. Ora usa due contenuti della stessa dimensione (`"fata"`/`"foto"`): ucciso.
- **M23 e M27** erano uccisi al primo giro, ma da un crash del test (un `!` su un opzionale nullo, un intervallo rovesciato), non da un'asserzione. I due test ora falliscono in modo pulito, con il messaggio: uccisi di nuovo, con 3 e 2 fallimenti.
- **M13-M14** insieme: togliere solo il controllo «Bloccato» *prima* di `trashItem` è equivalente (lo ripesca il controllo dopo il fallimento: il file resta comunque); M14 toglie quello dopo ed è ucciso.

**Non coperti da mutanti (nessun test li raggiunge, dichiarato):** `BackupRunner.beginAlignment` (un `!isRunning` tolto lì non farebbe arrossire niente: la difesa sta anche nei cancelli testati, `AlignmentStartGate` e i sei con `isAligning`), il cablaggio di `startAlignmentRun` (ricontrollo dell'inventario prima di ogni blocco: la funzione chiamata, `DuplicateCertification.runBlock`, è coperta dai test di ADR-0017), `InventoryView`, le richieste vere a Cubbit.

---

## Appendice A — Le patch, testo integrale

Ogni file definisce `PATCHES = [(descrizione, trova, sostituisci), …]`; si applicano in ordine sul `ContentView.swift` di `804a8b4` dopo le patch dei task precedenti, e ogni «trova» compare esattamente una volta.

### `01-alignment-rules.py`

```python
# Task 1 — Doppioni su HDD e Cubbit (ROADMAP #47, ADR-0019): le regole pure. La storia degli
# spostamenti letta dal disco, e quali copie uscite dall'SSD si possono togliere da HDD o Cubbit
# (condizioni 1-5 della spec), calcolate sull'inventario senza toccare niente. Divisione in blocchi.
ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''// MARK: - Doppioni su HDD e Cubbit: le regole pure (ROADMAP #47, ADR-0019)

/// I due archivi che il progetto 4 rimette uguali all'SSD. L'SSD non e' fra questi: non si tocca.
// `nonisolated`: value type puro, usato dal motore e dal registro fuori dal main.
nonisolated enum AlignmentArchive: String, Codable, CaseIterable, Sendable {
    case hdd, cubbit

    /// Lo stesso archivio, come lo chiama l'inventario.
    var inventoryArchive: InventoryArchive { self == .hdd ? .hdd : .s3 }
}

/// La storia degli spostamenti (`trash-history.jsonl`, `TrashHistory`) letta dal disco. Da
/// ADR-0019 la storia non e' piu' solo da leggere a mano: e' l'elenco delle copie che il
/// progetto 4 puo' togliere da HDD e Cubbit (decisione 1 di Enrico). Una riga che non si
/// decodifica non porta copie (verso sicuro: restano), ma si conta.
// `nonisolated`: pura, letta fuori dal main insieme all'inventario.
nonisolated enum TrashHistoryReader {
    struct Result: Sendable {
        let entries: [TrashHistoryEntry]
        /// Righe non vuote che non si sono lasciate decodificare.
        let malformedLines: Int
        /// Il file c'e' ma non si e' lasciato leggere: allora non si toglie niente.
        let unreadable: Bool

        static let empty = Result(entries: [], malformedLines: 0, unreadable: false)
    }

    /// Un file assente e' una storia vuota (non si e' mai spostato niente); uno illeggibile no.
    static func read(url: URL, fm: FileManager = .default) -> Result {
        guard fm.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            return Result(entries: [], malformedLines: 0, unreadable: true)
        }
        var entries: [TrashHistoryEntry] = []
        var malformed = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(TrashHistoryEntry.self, from: Data(line)) {
                entries.append(e)
            } else {
                malformed += 1
            }
        }
        return Result(entries: entries, malformedLines: malformed, unreadable: false)
    }
}

/// Perche' una copia uscita dall'SSD resta sull'archivio. Ogni caso ha la sua frase in
/// `AlignmentStatus.stayReasonLine`. L'ordine dei casi e' la precedenza con cui si controllano.
// `nonisolated`: value type puro.
nonisolated enum AlignmentStayReason: String, CaseIterable, Sendable {
    /// La storia non dice quale copia l'SSD ha tenuto (righe scritte prima di ADR-0017).
    case keptUnknown
    /// Il percorso d'origine non sta sotto la radice dell'SSD di oggi.
    case outsideSSD
    /// Un percorso vuoto, con `.`/`..`, o dentro la quarantena.
    case unsafePath
    /// La copia uscita e la copia tenuta sono lo stesso percorso (condizione 5).
    case sameAsKept
    /// La stessa copia compare piu' volte nella storia con la stessa tenuta: conta una volta.
    case repeatedInHistory
    /// La stessa copia compare nella storia con due copie tenute diverse.
    case conflictingKept
    /// Il registro dice che e' gia' stata tolta da questo archivio, e non e' stata rimessa.
    case alreadyRemoved
    /// La copia e' di nuovo sull'SSD (condizione 4): il backup la ricopierebbe.
    case backOnSSD
    /// La copia tenuta non c'e' sull'SSD, o non vi e' stata letta bene (condizione 3).
    case keptNotOnSSD
    /// La copia uscita non c'e' su questo archivio: niente da togliere.
    case notInArchive
    /// La copia tenuta non c'e' su questo archivio (condizione 2).
    case keptNotInArchive
    /// Due percorsi diversi diventano lo stesso confrontati senza maiuscole (condizione 5).
    case pathCollision
    /// Sull'HDD una delle due copie non si e' lasciata leggere per intero nell'inventario.
    case unreadableInArchive
    /// Su Cubbit una delle due copie non e' certificata per contenuto (ADR-0015).
    case notCertifiable
    /// Le due copie sull'archivio, o la tenuta sull'SSD, non hanno lo stesso contenuto.
    case contentDiffers
    /// Difesa in piu': la copia da togliere e' la copia tenuta di un'altra voce.
    case keptAlsoLeaving
}

/// Una copia da togliere da un archivio: tutto quello che il motore deve ricontrollare dal
/// vivo, congelato al momento del controllo (come `DuplicateBatch.Entry`).
// `nonisolated`: value type, prodotto fuori dal main e passato al motore.
nonisolated struct AlignmentCandidate: Equatable, Sendable, Identifiable {
    let archive: AlignmentArchive
    /// `normalizedIndexKey` della copia uscita e della copia tenuta.
    let leavingKey: String
    let keptKey: String
    /// I percorsi come sono scritti SU QUESTO ARCHIVIO (sull'HDD il percorso relativo alla
    /// radice, su Cubbit la chiave vera, con le maiuscole).
    let leavingPath: String
    let keptPath: String
    /// I percorsi come sono scritti sull'SSD, per il ricontrollo dal vivo delle condizioni 3 e 4.
    let ssdLeavingPath: String
    let ssdKeptPath: String
    let ssdKeptSize: Int64
    let size: Int64
    /// Il contenuto comune a copia uscita, copia tenuta e copia tenuta sull'SSD.
    let sha256: String
    /// Solo Cubbit: gli ETag delle due copie nell'inventario, senza virgolette (`RepairRules.normalizedETag`).
    let leavingETag: String?
    let keptETag: String?

    var id: String { archive.rawValue + ":" + leavingKey }
}

/// L'esito del controllo «senza togliere» (regola assoluta 4): cosa si toglierebbe, quanto
/// spazio, e quante copie restano e perche'. Si calcola senza toccare niente.
// `nonisolated`: value type, calcolato in un `Task.detached` e mostrato dalla finestra.
nonisolated struct AlignmentPlan: Sendable {
    let archive: AlignmentArchive
    /// Il giro dell'inventario che certifica le copie: il ricontrollo prima di ogni blocco
    /// pretende lo stesso. `nil` se il controllo non certifica niente.
    let runId: Int64?
    /// Il motivo che vale per tutte le copie (condizione 1), `nil` se l'inventario e' fresco.
    let block: DuplicateCertificationBlock?
    /// La storia non si e' lasciata leggere: non si toglie niente.
    let historyUnreadable: Bool
    let malformedHistoryLines: Int
    /// Le voci della storia (una per copia uscita), ripetizioni comprese.
    let historyCopies: Int
    /// In ordine di copia tenuta, poi di copia uscita.
    let candidates: [AlignmentCandidate]
    let stays: [AlignmentStayReason: Int]
    /// Fino a tre percorsi d'esempio per motivo, per il riepilogo.
    let stayExamples: [AlignmentStayReason: [String]]

    var bytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
    var stayCount: Int { stays.values.reduce(0, +) }

    static func blocked(_ archive: AlignmentArchive, block: DuplicateCertificationBlock?, historyUnreadable: Bool = false,
                        malformedHistoryLines: Int = 0, historyCopies: Int = 0) -> AlignmentPlan {
        AlignmentPlan(archive: archive, runId: nil, block: block, historyUnreadable: historyUnreadable,
                      malformedHistoryLines: malformedHistoryLines, historyCopies: historyCopies,
                      candidates: [], stays: [:], stayExamples: [:])
    }
}

/// Le condizioni 1-5 della spec (`Docs/superpowers/specs/2026-10-10-archive-alignment-hdd-cubbit-design.md`,
/// «Regole»), sulla storia e sull'inventario. Logica PURA: nessun disco, nessuna rete. La
/// condizione 6 (il ricontrollo dal vivo) e la 7 (le versioni su Cubbit) sono del motore.
// `nonisolated`: pura, calcolata fuori dal main (l'inventario ha centinaia di migliaia di righe).
nonisolated enum AlignmentPlanner {
    static func plan(archive: AlignmentArchive, history: TrashHistoryReader.Result, ssdRoot: URL,
                     snapshot: InventorySnapshot, lastArchiveWriteAt: Date?,
                     alreadyRemoved: Set<String>) -> AlignmentPlan {
        let pairCount = history.entries.reduce(0) { $0 + $1.originalPaths.count }
        guard !history.unreadable else {
            return .blocked(archive, block: nil, historyUnreadable: true, historyCopies: pairCount)
        }
        // Condizione 1: la stessa regola di ADR-0017, con la stessa funzione.
        let freshness = DuplicateInventoryFreshness.evaluate(states: snapshot.states, lastArchiveWriteAt: lastArchiveWriteAt)
        guard case .fresh(let runId, _, _) = freshness else {
            return .blocked(archive, block: DuplicateCertificationBlock(freshness: freshness),
                            malformedHistoryLines: history.malformedLines, historyCopies: pairCount)
        }

        var stays: [AlignmentStayReason: Int] = [:]
        var examples: [AlignmentStayReason: [String]] = [:]
        func stay(_ r: AlignmentStayReason, _ path: String) {
            stays[r, default: 0] += 1
            if examples[r, default: []].count < 3 { examples[r, default: []].append(path) }
        }

        // 1. Dalla storia alle coppie (copia uscita, copia tenuta), relative alla radice dell'SSD.
        let rootForms = [ssdRoot.standardizedFileURL.path, realResolvedPath(ssdRoot)].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        var pairs: [(leaving: String, kept: String)] = []
        for entry in history.entries {
            for (i, original) in entry.originalPaths.enumerated() {
                let kept = entry.keptPaths.flatMap { i < $0.count ? $0[i] : nil } ?? ""
                guard !kept.isEmpty else { stay(.keptUnknown, original); continue }
                // `.`/`..` si guardano sul percorso SCRITTO, prima che la standardizzazione li tolga.
                let raw = original.split(separator: "/", omittingEmptySubsequences: true)
                guard !raw.contains(where: { $0 == "." || $0 == ".." }) else { stay(.unsafePath, original); continue }
                guard let leaving = rootForms.lazy.compactMap({ relativePath(of: original, under: $0) }).first else {
                    stay(.outsideSSD, original); continue
                }
                guard RepairPaths.safeComponents(leaving) != nil, RepairPaths.safeComponents(kept) != nil else {
                    stay(.unsafePath, leaving); continue
                }
                guard normalizedIndexKey(leaving) != normalizedIndexKey(kept) else { stay(.sameAsKept, leaving); continue }
                pairs.append((leaving, kept))
            }
        }

        // 2. Una copia per percorso: ripetizioni con la stessa tenuta contano una volta; con due
        //    tenute diverse la copia resta (la storia si contraddice).
        var byLeaving: [String: [(leaving: String, kept: String)]] = [:]
        var order: [String] = []
        for p in pairs {
            let k = normalizedIndexKey(p.leaving)
            if byLeaving[k] == nil { order.append(k) }
            byLeaving[k, default: []].append(p)
        }

        let ssd = Dictionary(grouping: snapshot.ssd, by: \.key)
        let localArchive = archive == .hdd ? Dictionary(grouping: snapshot.hdd, by: \.key) : [:]
        let cubbit = archive == .cubbit ? Dictionary(grouping: snapshot.s3, by: \.key) : [:]
        let etagCandidates = archive == .cubbit ? localETagCandidates(snapshot) : [:]

        var candidates: [AlignmentCandidate] = []
        for leavingKey in order {
            let group = byLeaving[leavingKey]!
            let first = group[0]
            if Set(group.map { normalizedIndexKey($0.kept) }).count > 1 {
                for p in group { stay(.conflictingKept, p.leaving) }
                continue
            }
            for p in group.dropFirst() { stay(.repeatedInHistory, p.leaving) }
            let keptKey = normalizedIndexKey(first.kept)

            if alreadyRemoved.contains(leavingKey) { stay(.alreadyRemoved, first.leaving); continue }
            // Condizione 4: la copia uscita e' tornata sull'SSD (qualunque riga, anche illeggibile).
            if ssd[leavingKey] != nil { stay(.backOnSSD, first.leaving); continue }
            // Condizione 3: la copia tenuta c'e' sull'SSD, una volta sola, letta bene.
            guard let ssdKeptRows = ssd[keptKey], ssdKeptRows.count == 1, ssdKeptRows[0].status == .ok,
                  let ssdKept = ssdKeptRows[0].digest else {
                stay(.keptNotOnSSD, first.leaving); continue
            }
            let ssdKeptRow = ssdKeptRows[0]

            switch archive {
            case .hdd:
                guard let pRows = localArchive[leavingKey] else { stay(.notInArchive, first.leaving); continue }
                guard let kRows = localArchive[keptKey] else { stay(.keptNotInArchive, first.leaving); continue }
                guard pRows.count == 1, kRows.count == 1 else { stay(.pathCollision, first.leaving); continue }
                let p = pRows[0], k = kRows[0]
                guard p.status == .ok, k.status == .ok, let pd = p.digest, let kd = k.digest else {
                    stay(.unreadableInArchive, first.leaving); continue
                }
                // Condizione 2 (e 3): stesso contenuto fra le due copie sull'HDD e la tenuta sull'SSD.
                guard pd.sha256 == kd.sha256, kd.sha256 == ssdKept.sha256,
                      p.size == k.size, k.size == ssdKeptRow.size else {
                    stay(.contentDiffers, first.leaving); continue
                }
                candidates.append(AlignmentCandidate(
                    archive: .hdd, leavingKey: leavingKey, keptKey: keptKey, leavingPath: p.displayPath,
                    keptPath: k.displayPath, ssdLeavingPath: first.leaving, ssdKeptPath: ssdKeptRow.displayPath,
                    ssdKeptSize: ssdKeptRow.size, size: p.size, sha256: pd.sha256, leavingETag: nil, keptETag: nil))
            case .cubbit:
                guard let pRows = cubbit[leavingKey] else { stay(.notInArchive, first.leaving); continue }
                guard let kRows = cubbit[keptKey] else { stay(.keptNotInArchive, first.leaving); continue }
                guard pRows.count == 1, kRows.count == 1 else { stay(.pathCollision, first.leaving); continue }
                let p = pRows[0], k = kRows[0]
                // Condizione 2 su Cubbit: la stessa certificazione per contenuto dell'inventario.
                guard case .certified(let pSha) = S3ETagMatcher.verdict(etag: p.etag, size: p.size,
                                                                        candidates: etagCandidates[p.size] ?? []),
                      case .certified(let kSha) = S3ETagMatcher.verdict(etag: k.etag, size: k.size,
                                                                        candidates: etagCandidates[k.size] ?? []) else {
                    stay(.notCertifiable, first.leaving); continue
                }
                guard pSha == kSha, kSha == ssdKept.sha256, p.size == k.size, k.size == ssdKeptRow.size else {
                    stay(.contentDiffers, first.leaving); continue
                }
                candidates.append(AlignmentCandidate(
                    archive: .cubbit, leavingKey: leavingKey, keptKey: keptKey, leavingPath: p.displayKey,
                    keptPath: k.displayKey, ssdLeavingPath: first.leaving, ssdKeptPath: ssdKeptRow.displayPath,
                    ssdKeptSize: ssdKeptRow.size, size: p.size, sha256: pSha,
                    leavingETag: RepairRules.normalizedETag(p.etag), keptETag: RepairRules.normalizedETag(k.etag)))
            }
        }

        let (kept, dropped) = dropLeavingThatIsKept(candidates)
        for c in dropped { stay(.keptAlsoLeaving, c.ssdLeavingPath) }
        let sorted = kept.sorted { ($0.keptKey, $0.leavingKey) < ($1.keptKey, $1.leavingKey) }
        return AlignmentPlan(archive: archive, runId: runId, block: nil, historyUnreadable: false,
                             malformedHistoryLines: history.malformedLines, historyCopies: pairCount,
                             candidates: sorted, stays: stays, stayExamples: examples)
    }

    /// Difesa in piu': nessuna copia da togliere puo' essere la copia tenuta di un'altra voce.
    /// Con un inventario coerente non succede mai (la tenuta e' sull'SSD, la copia uscita no:
    /// condizioni 3 e 4), ma una regola che "non puo' succedere" si scrive comunque.
    static func dropLeavingThatIsKept(_ candidates: [AlignmentCandidate]) -> (kept: [AlignmentCandidate], dropped: [AlignmentCandidate]) {
        let keptKeys = Set(candidates.map(\.keptKey))
        var kept: [AlignmentCandidate] = []
        var dropped: [AlignmentCandidate] = []
        for c in candidates {
            if keptKeys.contains(c.leavingKey) { dropped.append(c) } else { kept.append(c) }
        }
        return (kept, dropped)
    }

    /// I file letti su SSD e HDD, per dimensione, come li vede `InventoryClassifier` per
    /// certificare un oggetto Cubbit (un candidato per contenuto, il primo incontrato).
    /// `AlignmentPlannerTests.testCubbitVerdict_matchesTheClassifier` pretende che i due
    /// certifichino le stesse cose.
    static func localETagCandidates(_ s: InventorySnapshot) -> [Int64: [S3ETagMatcher.Candidate]] {
        var out: [Int64: [S3ETagMatcher.Candidate]] = [:]
        var known = Set<String>()
        for f in s.ssd + s.hdd {
            guard f.status == .ok, let d = f.digest, known.insert(d.sha256).inserted else { continue }
            out[f.size, default: []].append(.init(size: f.size, sha256: d.sha256, md5: d.md5, multipartETag: d.multipartETag,
                                                  alternativeETags: d.alternativeMultipartETags))
        }
        return out
    }
}

/// La corsa a blocchi: stessi tetti dei Doppioni (`duplicateBatchFileCap`, `duplicateBatchByteCap`,
/// D2 del piano): il blocco e' anche la granularita' di «Annulla l'ultimo blocco». Una copia
/// piu' grande del tetto ha un blocco tutto suo.
// `nonisolated`: pura.
nonisolated enum AlignmentRunPlan {
    static func blocks(_ candidates: [AlignmentCandidate], fileCap: Int = duplicateBatchFileCap,
                       byteCap: Int64 = duplicateBatchByteCap) -> [[AlignmentCandidate]] {
        var out: [[AlignmentCandidate]] = []
        var current: [AlignmentCandidate] = []
        var bytes: Int64 = 0
        for c in candidates {
            if !current.isEmpty && (current.count >= fileCap || bytes + c.size > byteCap) {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(c)
            bytes += c.size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

'''
PATCHES = [("regole pure del progetto 4 prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)]

PATCHES.append(("TrashHistory: la storia ora la legge TrashHistoryReader (ADR-0019)",
"""/// **Non e' un annullamento.** Non ha bottoni, non legge mai il proprio contenuto per
/// decidere niente, e non aggiunge nessun percorso distruttivo: `TrashManifestStore` resta""",
"""/// **Non e' un annullamento.** Non ha bottoni, non legge mai il proprio contenuto per
/// decidere niente (da ADR-0019 la legge `TrashHistoryReader`, per il progetto 4: e' l'elenco
/// delle copie che si possono togliere anche da HDD e Cubbit), e non aggiunge nessun percorso
/// distruttivo: `TrashManifestStore` resta"""))
```

### `02-alignment-log.py`

```python
# Task 2 — Il registro proprio del progetto 4 (spec, «Come si usa», punto 4): una riga per evento,
# in sola aggiunta, scritta PRIMA di toccare l'archivio («pending») e subito dopo («removed»
# con dove e' finita la copia: nel Cestino dell'HDD o il segno di cancellazione su Cubbit).
ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''// MARK: - Doppioni su HDD e Cubbit: il registro (ROADMAP #47, ADR-0019)

/// Una riga del registro del progetto 4 (`alignment-hdd.jsonl`, `alignment-cubbit.jsonl`). Le
/// righe di una stessa copia condividono `id`: «pending» porta tutto quello che serve a
/// ricostruire cosa si stava togliendo, le altre portano l'esito.
// `nonisolated`: value type, scritto dal motore fuori dal main e letto dalla finestra.
nonisolated struct AlignmentLogEntry: Codable, Equatable, Sendable {
    enum Event: String, Codable, Sendable {
        /// Scritta PRIMA di toccare l'archivio: se l'app si chiude a meta', il registro dice
        /// che quella copia era in uscita.
        case pending
        /// Tolta: nel Cestino dell'HDD (`trashedPath`) o con un segno di cancellazione su Cubbit
        /// (`deleteMarkerVersionId`).
        case removed
        /// Non tolta, con il motivo (`detail`).
        case failed
        /// Rimessa a posto da «Annulla l'ultimo blocco».
        case restored
    }

    var event: Event
    var id: String
    var blockId: String
    var archive: AlignmentArchive
    var at: Date
    /// Solo nella riga «pending».
    var leavingPath: String? = nil
    var leavingKey: String? = nil
    var keptPath: String? = nil
    var size: Int64? = nil
    var sha256: String? = nil
    /// Cubbit: l'ETag della copia tolta, per verificare l'annullamento.
    var etag: String? = nil
    /// HDD: dove stava la copia, percorso assoluto (e' li' che l'annullamento la rimette).
    var originalAbsolutePath: String? = nil
    /// Solo nella riga «removed».
    var trashedPath: String? = nil
    var deleteMarkerVersionId: String? = nil
    var detail: String? = nil
}

nonisolated extension AlignmentLogEntry {
    private enum CodingKeys: String, CodingKey {
        case event, id, blockId, archive, at, leavingPath, leavingKey, keptPath, size, sha256, etag,
             originalAbsolutePath, trashedPath, deleteMarkerVersionId, detail
    }

    /// `init(from:)` esplicita con `decodeIfPresent` (regola del progetto per i tipi persistiti,
    /// fatto misurato n. 5 di #31): severa su evento, identita', blocco, archivio e data —
    /// senza, la riga non racconta niente — tollerante sul resto.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(Event.self, forKey: .event)
        id = try c.decode(String.self, forKey: .id)
        blockId = try c.decode(String.self, forKey: .blockId)
        archive = try c.decode(AlignmentArchive.self, forKey: .archive)
        at = try c.decode(Date.self, forKey: .at)
        leavingPath = try c.decodeIfPresent(String.self, forKey: .leavingPath)
        leavingKey = try c.decodeIfPresent(String.self, forKey: .leavingKey)
        keptPath = try c.decodeIfPresent(String.self, forKey: .keptPath)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        originalAbsolutePath = try c.decodeIfPresent(String.self, forKey: .originalAbsolutePath)
        trashedPath = try c.decodeIfPresent(String.self, forKey: .trashedPath)
        deleteMarkerVersionId = try c.decodeIfPresent(String.self, forKey: .deleteMarkerVersionId)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Una copia tolta, ricostruita dalle righe del registro.
// `nonisolated`: value type puro.
nonisolated struct AlignmentRemoval: Equatable, Sendable {
    let id: String
    let blockId: String
    let archive: AlignmentArchive
    let leavingPath: String
    let leavingKey: String
    let keptPath: String
    let size: Int64
    let sha256: String
    let etag: String?
    let originalAbsolutePath: String?
    let trashedPath: String?
    let deleteMarkerVersionId: String?
    let removedAt: Date
    let restoredAt: Date?
}

/// Lo stato che il registro racconta, per UN archivio. Logica pura sulle righe lette.
// `nonisolated`: value type puro, calcolato fuori dal main.
nonisolated struct AlignmentLogState: Sendable {
    let archive: AlignmentArchive
    /// In ordine di uscita. Solo le copie con una riga «removed».
    let removals: [AlignmentRemoval]
    /// Righe «pending» senza esito: l'app si e' chiusa mentre toglieva quella copia. Si
    /// controllano a mano (il riepilogo le nomina), l'annullamento non le tocca.
    let unfinished: [AlignmentLogEntry]
    /// Righe che non si sono lasciate leggere.
    let malformedLines: Int

    init(archive: AlignmentArchive, entries: [AlignmentLogEntry], malformedLines: Int = 0) {
        self.archive = archive
        self.malformedLines = malformedLines
        var pending: [String: AlignmentLogEntry] = [:]
        var order: [String] = []
        var removed: [String: AlignmentLogEntry] = [:]
        var removedOrder: [String] = []
        var closed = Set<String>()
        var restoredAt: [String: Date] = [:]
        for e in entries where e.archive == archive {
            switch e.event {
            case .pending:
                if pending[e.id] == nil { order.append(e.id) }
                pending[e.id] = e
            case .removed:
                if removed[e.id] == nil { removedOrder.append(e.id) }
                removed[e.id] = e
                closed.insert(e.id)
            case .failed:
                closed.insert(e.id)
            case .restored:
                restoredAt[e.id] = e.at
            }
        }
        removals = removedOrder.compactMap { id in
            guard let p = pending[id], let r = removed[id], let leavingPath = p.leavingPath, let leavingKey = p.leavingKey,
                  let keptPath = p.keptPath, let size = p.size, let sha256 = p.sha256 else { return nil }
            return AlignmentRemoval(id: id, blockId: p.blockId, archive: archive, leavingPath: leavingPath,
                                    leavingKey: leavingKey, keptPath: keptPath, size: size, sha256: sha256, etag: p.etag,
                                    originalAbsolutePath: p.originalAbsolutePath, trashedPath: r.trashedPath,
                                    deleteMarkerVersionId: r.deleteMarkerVersionId, removedAt: r.at,
                                    restoredAt: restoredAt[id])
        }
        unfinished = order.filter { !closed.contains($0) }.compactMap { pending[$0] }
    }

    /// Le copie tolte e non rimesse: il controllo le salta (`AlignmentStayReason.alreadyRemoved`).
    var removedKeys: Set<String> { Set(removals.filter { $0.restoredAt == nil }.map(\.leavingKey)) }

    /// Le copie dell'ultimo blocco ancora da rimettere a posto. L'ultimo e' quello della riga
    /// «removed» scritta per ultima (stessa regola di `TrashManifestStore.pendingInLastBatch`):
    /// un annullamento si fa a un solo livello (decisione di Enrico del 2026-09-20, ripresa qui).
    var lastBlockToRestore: [AlignmentRemoval] {
        guard let last = removals.last?.blockId else { return [] }
        return removals.filter { $0.blockId == last && $0.restoredAt == nil }
    }

    /// Per la conferma di «Annulla l'ultimo blocco»: quante copie e quando. `nil` = niente da fare.
    var lastBlockSummary: RestorableBatchSummary? {
        guard let last = removals.last?.blockId else { return nil }
        let block = removals.filter { $0.blockId == last }
        let pending = block.filter { $0.restoredAt == nil }
        guard let oldest = pending.map(\.removedAt).min() else { return nil }
        return RestorableBatchSummary(pendingCount: pending.count, batchCount: block.count, trashedAt: oldest)
    }
}

/// Il registro del progetto 4, sul disco interno (`Application Support/AppBackupFoto/`), mai su
/// un archivio. In SOLA AGGIUNTA, una riga JSON per evento: 89.442 copie per archivio, e un
/// registro riscritto per intero a ogni riga (come `TrashManifestStore`) costerebbe in modo
/// quadratico. Diverso da `TrashHistory` in un punto voluto: qui una scrittura fallita LANCIA,
/// e il motore si ferma — una copia tolta senza registro e' proprio quello da evitare.
///
/// Durabilita': `write(2)` senza `fsync`, come `TrashManifestStore` (scrittura atomica senza
/// `fsync`): una chiusura dell'app non perde niente, uno spegnimento brusco puo' perdere le
/// ultime righe. Le copie restano comunque recuperabili (Cestino dell'HDD con il suo «Rimetti
/// a posto», versioni di Cubbit per 30 giorni).
// `nonisolated`: `append` arriva dal motore fuori dal main, `read`/`state` da un `Task.detached`.
// Ogni accesso al file passa da `lock.withLock`; `url` e' `let`. Vedi ADR-0006.
nonisolated final class AlignmentLogStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case invalidLocation(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation(let p): return "Posizione non consentita per il registro: \(p)"
            case .writeFailed(let d): return "Il registro non si e' lasciato scrivere: \(d)"
            }
        }
    }

    struct ReadResult: Sendable {
        let entries: [AlignmentLogEntry]
        let malformedLines: Int
        let unreadable: Bool
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL) throws {
        // Stessa allow-list degli altri registri: nomina i percorsi delle foto.
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Aggiunge una riga e torna solo quando e' tutta sul file. Lancia su qualunque errore.
    func append(_ entry: AlignmentLogEntry) throws {
        var line = try JSONEncoder().encode(entry)
        line.append(0x0A)
        try lock.withLock {
            let fd = open(url.path, O_APPEND | O_CREAT | O_WRONLY, 0o600)
            guard fd >= 0 else { throw StoreError.writeFailed(String(cString: strerror(errno))) }
            defer { close(fd) }
            _ = fchmod(fd, 0o600)
            var written = 0
            try line.withUnsafeBytes { buffer in
                while written < buffer.count {
                    let n = write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw StoreError.writeFailed(String(cString: strerror(errno)))
                    }
                    written += n
                }
            }
        }
    }

    /// Tutte le righe. Un file assente e' un registro vuoto; uno che non si apre e' `unreadable`.
    func read() -> ReadResult {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ReadResult(entries: [], malformedLines: 0, unreadable: false)
            }
            guard let data = try? Data(contentsOf: url) else {
                return ReadResult(entries: [], malformedLines: 0, unreadable: true)
            }
            let decoder = JSONDecoder()
            var entries: [AlignmentLogEntry] = []
            var malformed = 0
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let e = try? decoder.decode(AlignmentLogEntry.self, from: Data(line)) { entries.append(e) } else { malformed += 1 }
            }
            return ReadResult(entries: entries, malformedLines: malformed, unreadable: false)
        }
    }

    /// Lo stato per un archivio, o `nil` se il registro non si lascia leggere.
    func state(for archive: AlignmentArchive) -> AlignmentLogState? {
        let r = read()
        guard !r.unreadable else { return nil }
        return AlignmentLogState(archive: archive, entries: r.entries, malformedLines: r.malformedLines)
    }
}

'''
PATCHES = [("registro del progetto 4 prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)]
```

### `03-alignment-s3.py`

```python
# Task 3 — Le richieste a Cubbit del progetto 4 (ROADMAP #47, ADR-0019): stato delle versioni e
# regole di scadenza (sola lettura), DELETE di una copia SENZA versione (crea il segno di
# cancellazione), elenco delle versioni di UNA chiave, e l'unico DELETE con versione ammesso:
# quello che toglie un segno di cancellazione registrato (annullamento). Tutte firmate da `sign`,
# con il percorso di `objectRequestPath` (lo stesso della HEAD). Piu' il protocollo per il motore.
ANCHOR = "    // MARK: - AWS Signature V4\n"
CODE = r'''    // MARK: - Richieste del progetto 4: doppioni su Cubbit (ROADMAP #47, ADR-0019)
    //
    // Le uniche richieste DELETE su oggetti del progetto, oltre ad `AbortMultipartUpload`. Le
    // chiama SOLO `S3AlignmentCloud`, per `ArchiveAligner` (`AlignmentDeleteGuardTests` lo
    // pretende leggendo il sorgente). Il percorso e' quello di `objectRequestPath`, lo stesso
    // della HEAD che le precede: la HEAD e il DELETE parlano della stessa chiave per costruzione.

    /// Lo stato delle versioni del bucket (`GetBucketVersioning`). Un bucket su cui non sono mai
    /// state accese risponde senza `<Status>`.
    nonisolated enum BucketVersioning: Equatable, Sendable {
        case enabled
        case suspended
        case neverEnabled
        case unrecognized(String)
    }

    /// Una regola di scadenza del bucket, per quel che serve all'app: si legge, non si scrive mai.
    nonisolated struct LifecycleRule: Equatable, Sendable {
        let id: String
        let enabled: Bool
        /// Vale per tutto il bucket: `<Prefix>` vuoto o assente, e nessun `<Filter>` che restringa.
        let wholeBucket: Bool
        /// `NoncurrentVersionExpiration/NoncurrentDays`: dopo quanti giorni una versione vecchia sparisce.
        let noncurrentDays: Int?
        /// `Expiration` con `Days` o `Date`: farebbe sparire le foto ATTUALI. L'app non parte.
        let expiresCurrentObjects: Bool
    }

    /// L'esito di un DELETE: se ha creato (o tolto) un segno di cancellazione, e con quale versione.
    nonisolated struct DeleteResult: Equatable, Sendable {
        let isDeleteMarker: Bool
        let versionId: String?
    }

    /// Una voce di `ListObjectVersions`: una versione di dati o un segno di cancellazione.
    nonisolated struct VersionEntry: Equatable, Sendable {
        let key: String
        let versionId: String
        let isLatest: Bool
        let isDeleteMarker: Bool
        let etag: String?
        let size: Int64?
    }

    nonisolated struct VersionsPage: Equatable, Sendable {
        let entries: [VersionEntry]
        let isTruncated: Bool
        let nextKeyMarker: String?
        let nextVersionIdMarker: String?
        /// Blocchi senza chiave o senza versione leggibile: non si fanno sparire in silenzio.
        let malformedEntries: Int
    }

    /// Il testo del primo `<tag>…</tag>` (decodificato), `""` per `<tag/>`, `nil` se manca.
    nonisolated static func xmlTag(_ xml: Substring, _ tag: String) -> String? {
        if xml.range(of: "<\(tag)/>") != nil, xml.range(of: "<\(tag)>") == nil { return "" }
        guard let s = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>", range: s.upperBound..<xml.endIndex) else {
            return nil
        }
        return xmlDecode(String(xml[s.upperBound..<e.lowerBound]))
    }

    /// I blocchi `<tag>…</tag>` di primo livello, nell'ordine del documento.
    nonisolated static func xmlBlocks(_ xml: Substring, _ tag: String) -> [Substring] {
        var out: [Substring] = []
        var rest = xml
        while let s = rest.range(of: "<\(tag)>"), let e = rest.range(of: "</\(tag)>", range: s.upperBound..<rest.endIndex) {
            out.append(rest[s.upperBound..<e.lowerBound])
            rest = rest[e.upperBound...]
        }
        return out
    }

    nonisolated static func parseVersioning(_ xml: String) -> BucketVersioning {
        guard let status = xmlTag(xml[...], "Status")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return .neverEnabled }
        switch status {
        case "Enabled": return .enabled
        case "Suspended": return .suspended
        default: return .unrecognized(status)
        }
    }

    /// 200 = le regole; 404 = nessuna regola (`NoSuchLifecycleConfiguration`); altro = errore.
    nonisolated static func parseLifecycle(statusCode: Int, body: String) throws -> [LifecycleRule] {
        if statusCode == 404 { return [] }
        guard statusCode == 200 else {
            throw S3HTTPError(statusCode: statusCode, message: "Errore lettura regole di scadenza: \(body.prefix(200))")
        }
        return xmlBlocks(body[...], "Rule").map { rule in
            var outside = String(rule)
            var filterRestricts = false
            var filterPrefix = ""
            if let f = xmlBlocks(rule, "Filter").first {
                filterRestricts = f.contains("<Tag>") || f.contains("<And>") || f.contains("ObjectSize")
                filterPrefix = xmlTag(f, "Prefix") ?? ""
                if let r = outside.range(of: "<Filter>" + f + "</Filter>") { outside.removeSubrange(r) }
            }
            let prefix = xmlTag(outside[...], "Prefix") ?? ""
            let expiration = xmlBlocks(rule, "Expiration").first
            let noncurrent = xmlBlocks(rule, "NoncurrentVersionExpiration").first
            return LifecycleRule(
                id: xmlTag(rule, "ID") ?? "",
                enabled: xmlTag(outside[...], "Status")?.trimmingCharacters(in: .whitespaces) == "Enabled",
                wholeBucket: prefix.isEmpty && filterPrefix.isEmpty && !filterRestricts,
                noncurrentDays: noncurrent.flatMap { xmlTag($0, "NoncurrentDays") }.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                expiresCurrentObjects: expiration.map { xmlTag($0, "Days") != nil || xmlTag($0, "Date") != nil } ?? false)
        }
    }

    nonisolated static func parseDelete(statusCode: Int, deleteMarker: String?, versionId: String?, key: String) throws -> DeleteResult {
        guard (200...299).contains(statusCode) else {
            throw S3HTTPError(statusCode: statusCode, message: "Errore DELETE \(key)")
        }
        let v = versionId?.trimmingCharacters(in: .whitespaces)
        return DeleteResult(isDeleteMarker: deleteMarker?.trimmingCharacters(in: .whitespaces).lowercased() == "true",
                            versionId: (v?.isEmpty ?? true) ? nil : v)
    }

    nonisolated static func parseVersionsPage(_ xml: String) -> VersionsPage {
        var entries: [VersionEntry] = []
        var malformed = 0
        var rest = xml[...]
        // Versioni e segni nell'ordine del documento: si cerca il prossimo dei due.
        while true {
            let v = rest.range(of: "<Version>"), d = rest.range(of: "<DeleteMarker>")
            guard v != nil || d != nil else { break }
            let isMarker = d != nil && (v == nil || d!.lowerBound < v!.lowerBound)
            let tag = isMarker ? "DeleteMarker" : "Version"
            let start = isMarker ? d! : v!
            guard let end = rest.range(of: "</\(tag)>", range: start.upperBound..<rest.endIndex) else { malformed += 1; break }
            let block = rest[start.upperBound..<end.lowerBound]
            rest = rest[end.upperBound...]
            guard let key = xmlTag(block, "Key"), !key.isEmpty, let version = xmlTag(block, "VersionId"), !version.isEmpty else {
                malformed += 1; continue
            }
            entries.append(VersionEntry(key: key, versionId: version,
                                        isLatest: xmlTag(block, "IsLatest")?.lowercased() == "true",
                                        isDeleteMarker: isMarker, etag: xmlTag(block, "ETag"),
                                        size: xmlTag(block, "Size").flatMap { Int64($0) }))
        }
        let truncated = xmlTag(xml[...], "IsTruncated")?.lowercased() == "true"
        let nk = xmlTag(xml[...], "NextKeyMarker").flatMap { $0.isEmpty ? nil : $0 }
        let nv = xmlTag(xml[...], "NextVersionIdMarker").flatMap { $0.isEmpty ? nil : $0 }
        return VersionsPage(entries: entries, isTruncated: truncated, nextKeyMarker: nk, nextVersionIdMarker: nv,
                            malformedEntries: malformed)
    }

    /// Una richiesta sul bucket (non su un oggetto) con la query data, firmata. Sola lettura.
    private func bucketGET(config: S3Config, queryItems: [URLQueryItem]) async throws -> (Int, String) {
        guard var comps = URLComponents(string: config.endpoint + "/" + Self.encodeKeyStrict(config.bucket)) else {
            throw NSError(domain: "S3", code: 8, userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket"])
        }
        comps.queryItems = queryItems
        comps.percentEncodedQuery = Self.encodePlusInQuery(comps.percentEncodedQuery)
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8, userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
    }

    /// `GetBucketVersioning`, sola lettura: l'app non cambia mai la configurazione del bucket.
    func bucketVersioning(config: S3Config) async throws -> BucketVersioning {
        let (code, body) = try await bucketGET(config: config, queryItems: [URLQueryItem(name: "versioning", value: nil)])
        guard code == 200 else { throw S3HTTPError(statusCode: code, message: "Errore lettura versioni: \(body.prefix(200))") }
        return Self.parseVersioning(body)
    }

    /// `GetBucketLifecycleConfiguration`, sola lettura.
    func bucketLifecycleRules(config: S3Config) async throws -> [LifecycleRule] {
        let (code, body) = try await bucketGET(config: config, queryItems: [URLQueryItem(name: "lifecycle", value: nil)])
        return try Self.parseLifecycle(statusCode: code, body: body)
    }

    /// Tutte le versioni (e i segni di cancellazione) della chiave ESATTA `key`: la lista per
    /// prefisso porterebbe anche `a.jpg.json` insieme ad `a.jpg`, e si scartano. Lancia su una
    /// lista illeggibile o incompleta.
    func listObjectVersions(config: S3Config, key: String) async throws -> [VersionEntry] {
        var out: [VersionEntry] = []
        var marker: (key: String, version: String)? = nil
        repeat {
            var q = [URLQueryItem(name: "prefix", value: key), URLQueryItem(name: "versions", value: nil)]
            if let marker {
                q.append(URLQueryItem(name: "key-marker", value: marker.key))
                q.append(URLQueryItem(name: "version-id-marker", value: marker.version))
            }
            let (code, body) = try await bucketGET(config: config, queryItems: q)
            guard code == 200 else { throw S3HTTPError(statusCode: code, message: "Errore elenco versioni di \(key)") }
            let page = Self.parseVersionsPage(body)
            guard page.malformedEntries == 0 else { throw S3HTTPError(statusCode: 200, message: "Elenco versioni di \(key) illeggibile") }
            out += page.entries.filter { $0.key == key }
            if page.isTruncated {
                guard let nk = page.nextKeyMarker, let nv = page.nextVersionIdMarker else {
                    throw S3HTTPError(statusCode: 200, message: "Elenco versioni di \(key) troncato senza seguito")
                }
                marker = (nk, nv)
            } else {
                marker = nil
            }
        } while marker != nil
        return out
    }

    /// DELETE di una copia SENZA versione (ADR-0019): con le versioni accese crea un segno di
    /// cancellazione e la versione resta per i giorni della regola. Chi chiama ha gia' letto lo
    /// stato delle versioni e fatto la HEAD della copia e della copia tenuta.
    func deleteObjectForAlignment(config: S3Config, key: String) async throws -> DeleteResult {
        let path = Self.objectRequestPath(bucket: config.bucket, key: key)
        guard let url = URL(string: config.endpoint + path) else {
            throw NSError(domain: "S3", code: 12, userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path)
        let (_, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        return try Self.parseDelete(statusCode: http?.statusCode ?? -1,
                                    deleteMarker: http?.value(forHTTPHeaderField: "x-amz-delete-marker"),
                                    versionId: http?.value(forHTTPHeaderField: "x-amz-version-id"), key: key)
    }

    /// L'UNICO DELETE con versione del progetto: toglie un segno di cancellazione che il registro
    /// ha annotato, per annullare. Chi chiama ha gia' verificato con `listObjectVersions` che
    /// `versionId` e' un segno di cancellazione di `key`, mai una versione di dati.
    func removeDeleteMarkerForAlignment(config: S3Config, key: String, versionId: String) async throws -> DeleteResult {
        let path = Self.objectRequestPath(bucket: config.bucket, key: key)
        guard let url = URL(string: config.endpoint + path + "?versionId=" + Self.encodeKeyStrict(versionId)) else {
            throw NSError(domain: "S3", code: 12, userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path)
        let (_, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        return try Self.parseDelete(statusCode: http?.statusCode ?? -1,
                                    deleteMarker: http?.value(forHTTPHeaderField: "x-amz-delete-marker"),
                                    versionId: http?.value(forHTTPHeaderField: "x-amz-version-id"), key: key)
    }

'''
ANCHOR2 = "// MARK: - Testi e regole della card \"Foto gia' salvate\" (roadmap #31, Task 6)\n"
CODE2 = r'''// MARK: - Doppioni su Cubbit: cosa il motore chiede a Cubbit (ROADMAP #47, ADR-0019)

/// Quello che il motore del progetto 4 chiede a Cubbit. In produzione `S3AlignmentCloud` (sopra
/// `S3Syncer`); nei test un Cubbit finto con le versioni.
nonisolated protocol AlignmentCloud: Sendable {
    /// `nil` = l'oggetto non c'e' (o il suo ultimo stato e' un segno di cancellazione).
    func head(key: String) async throws -> S3Syncer.S3ObjectHead?
    func versioning() async throws -> S3Syncer.BucketVersioning
    func lifecycleRules() async throws -> [S3Syncer.LifecycleRule]
    /// DELETE senza versione: crea il segno di cancellazione.
    func delete(key: String) async throws -> S3Syncer.DeleteResult
    func versions(key: String) async throws -> [S3Syncer.VersionEntry]
    /// Toglie il segno di cancellazione `versionId` di `key`: l'annullamento.
    func removeDeleteMarker(key: String, versionId: String) async throws -> S3Syncer.DeleteResult
}

/// Il Cubbit vero per il motore del progetto 4. Stessa forma di `S3RepairCloud`: solo `let`,
/// ogni chiamata salta sul main il tempo di costruire e firmare la richiesta.
// `nonisolated`: solo proprieta' `let`; `S3Syncer` e' isolato al MainActor (quindi `Sendable`).
nonisolated final class S3AlignmentCloud: AlignmentCloud, @unchecked Sendable {
    private let syncer: S3Syncer
    private let config: S3Syncer.S3Config

    init(syncer: S3Syncer, config: S3Syncer.S3Config) {
        self.syncer = syncer
        self.config = config
    }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? { try await syncer.headObject(config: config, key: key) }
    func versioning() async throws -> S3Syncer.BucketVersioning { try await syncer.bucketVersioning(config: config) }
    func lifecycleRules() async throws -> [S3Syncer.LifecycleRule] { try await syncer.bucketLifecycleRules(config: config) }
    func delete(key: String) async throws -> S3Syncer.DeleteResult {
        try await syncer.deleteObjectForAlignment(config: config, key: key)
    }
    func versions(key: String) async throws -> [S3Syncer.VersionEntry] {
        try await syncer.listObjectVersions(config: config, key: key)
    }
    func removeDeleteMarker(key: String, versionId: String) async throws -> S3Syncer.DeleteResult {
        try await syncer.removeDeleteMarkerForAlignment(config: config, key: key, versionId: versionId)
    }
}

/// Se Cubbit e' pronto per togliere copie (condizione 7 della spec). Logica pura sulle due
/// letture. Le versioni devono essere accese; le regole di scadenza devono far sparire le
/// versioni vecchie di tutto il bucket, e MAI prima di `minimumDays` giorni (e' la finestra in
/// cui «Annulla» funziona, D5 del piano); nessuna regola deve far sparire le foto attuali.
// `nonisolated`: pura, valutata dal motore fuori dal main.
nonisolated enum AlignmentCubbitSafety: Equatable, Sendable {
    case ready(days: Int)
    case versioningNotEnabled(S3Syncer.BucketVersioning)
    case noExpiryRule
    case expiryTooShort(days: Int)
    case expiresCurrentPhotos

    static let minimumDays = 30

    static func evaluate(versioning: S3Syncer.BucketVersioning, rules: [S3Syncer.LifecycleRule]) -> AlignmentCubbitSafety {
        guard versioning == .enabled else { return .versioningNotEnabled(versioning) }
        let enabled = rules.filter(\.enabled)
        if enabled.contains(where: \.expiresCurrentObjects) { return .expiresCurrentPhotos }
        // Il minimo fra TUTTE le regole attive, anche quelle per una sola cartella: una regola
        // da 1 giorno su «Takeout/» renderebbe l'annullamento impossibile li'.
        if let shortest = enabled.compactMap(\.noncurrentDays).min(), shortest < minimumDays {
            return .expiryTooShort(days: shortest)
        }
        guard let days = enabled.filter(\.wholeBucket).compactMap(\.noncurrentDays).min() else { return .noExpiryRule }
        return .ready(days: days)
    }
}

'''
PATCHES = [("richieste S3 del progetto 4 prima della firma", ANCHOR, CODE + ANCHOR),
           ("protocollo, Cubbit vero e controllo delle versioni prima dei testi della card", ANCHOR2, CODE2 + ANCHOR2)]
```

### `04-alignment-engine-hdd.py`

```python
# Task 4 — Il motore del progetto 4, lato HDD (ROADMAP #47, ADR-0019): per ogni copia del blocco
# il ricontrollo dal vivo (condizione 6: SSD, rilettura e rihash di copia uscita e copia tenuta
# sull'HDD, confinamento), la riga «pending» nel registro, `trashItem` nel Cestino dell'HDD, la
# riga «removed». I tipi dell'esito valgono anche per Cubbit (Task 5) e l'annullamento (Task 6).
ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''// MARK: - Doppioni su HDD e Cubbit: il motore (ROADMAP #47, ADR-0019)

/// Uno dei due dischi coinvolti in una corsa.
nonisolated enum AlignmentVolume: String, Sendable { case ssd, hdd }

/// Perche' una copia del blocco non e' stata tolta al ricontrollo dal vivo (condizione 6). La
/// corsa prosegue con la copia successiva: sono i casi in cui il disco o Cubbit non sono piu'
/// quelli che l'inventario ha visto, e la risposta giusta e' lasciare la copia dov'e'.
// `nonisolated`: value type puro.
nonisolated enum AlignmentSkipReason: String, CaseIterable, Sendable {
    /// Un percorso non sicuro, o che risolve fuori dalla radice del disco.
    case unsafePath
    /// La copia uscita e' di nuovo sull'SSD (condizione 4, dal vivo).
    case backOnSSD
    /// La copia tenuta non c'e' piu' sull'SSD, o ha un'altra dimensione (condizione 3, dal vivo).
    case keptChangedOnSSD
    /// La copia da togliere non c'e' piu' sull'archivio: niente da fare.
    case goneFromArchive
    /// La copia tenuta non c'e' piu' sull'archivio (condizione 2, dal vivo).
    case keptMissingInArchive
    /// Solo HDD: il file ha il blocco «Bloccato» (`uchg`). L'app non lo sblocca (D3 del piano).
    case locked
    /// Solo HDD: una delle due copie non si e' lasciata rileggere.
    case unreadable
    /// Contenuto, dimensione (o ETag su Cubbit) diversi da quelli dell'inventario.
    case contentChanged
    /// Solo HDD: la copia sta su un altro disco (un collegamento che porta fuori dall'HDD).
    case otherVolume
}

/// Perche' una corsa si e' fermata. Ogni caso ha la sua frase in `AlignmentStatus`.
// `nonisolated`: value type puro.
nonisolated enum AlignmentStopReason: Equatable, Sendable {
    case interrupted
    /// Il disco non c'era gia' all'inizio del blocco.
    case volumeMissing(AlignmentVolume)
    /// Il disco e' sparito a meta' (`st_dev` cambiato): «non c'e'» non vuol dire «gia' fatto».
    case volumeVanished(AlignmentVolume)
    /// Il registro non si e' lasciato scrivere: senza registro non si toglie niente.
    case logNotWritten(String)
    /// `trashItem` e' fallito per un motivo che non e' il blocco «Bloccato».
    case trashFailed(path: String, detail: String)
    /// Dopo aver tolto la copia, la copia tenuta non c'era piu': ci si ferma subito. La copia
    /// tolta e' nel Cestino ed e' nel registro: «Annulla l'ultimo blocco» la rimette.
    case keptVanished(path: String)
    /// Condizione 7: versioni non accese, o regole di scadenza non adatte.
    case cubbitNotReady(AlignmentCubbitSafety)
    case cubbitError(String)
    /// Cubbit ha cancellato senza creare il segno di cancellazione: ci si ferma subito.
    case deleteWithoutMarker(path: String)
    /// Prima di un blocco: l'inventario non e' piu' quello che ha certificato le copie.
    case inventoryNoLongerValid(DuplicateCertificationBlock)
}

/// L'esito di un blocco.
// `nonisolated`: value type, prodotto dal motore fuori dal main.
nonisolated struct AlignmentBlockOutcome: Sendable {
    var removed: [AlignmentCandidate] = []
    var skipped: [AlignmentSkipReason: Int] = [:]
    var skippedExamples: [AlignmentSkipReason: [String]] = [:]
    var stop: AlignmentStopReason? = nil

    var removedBytes: Int64 { removed.reduce(0) { $0 + $1.size } }
    var skippedCount: Int { skipped.values.reduce(0, +) }

    mutating func skip(_ c: AlignmentCandidate, _ r: AlignmentSkipReason) {
        skipped[r, default: 0] += 1
        if skippedExamples[r, default: []].count < 3 { skippedExamples[r, default: []].append(c.leavingPath) }
    }
}

/// Il motore del progetto 4: toglie da HDD o Cubbit le copie gia' uscite dall'SSD, un blocco
/// alla volta, una copia alla volta, con il ricontrollo dal vivo subito prima di ogni copia e il
/// registro scritto prima di toccare l'archivio e subito dopo. Il blocco arriva gia' deciso
/// (`AlignmentPlanner`): il motore non sceglie cosa togliere, RIFIUTA soltanto.
///
/// - HDD: `trashItem` nel Cestino dell'HDD (stesso volume, l'app non lo svuota mai).
/// - Cubbit (Task 5): DELETE senza versione, solo con le versioni accese.
///
/// Le funzioni di disco e il Cubbit sono iniettati: i casi da coprire (un disco che sparisce,
/// un file bloccato, un `trashItem` che fallisce) non si producono su file veri senza una corsa.
/// In produzione sono quelle vere (default), stesso schema di `RepairEngine`.
// `nonisolated`: i blocchi girano fuori dal main (rilettura di file interi, rete). Solo
// proprieta' `let` (URL, closure `@Sendable`, il Cubbit `Sendable`); lo stato di un blocco e'
// tutto locale. Un blocco alla volta: lo garantisce `BackupRunner.isAligning` (Task 7).
// Le funzioni `async` sono `@concurrent` (ADR-0006).
nonisolated final class ArchiveAligner: @unchecked Sendable {
    /// I blocchi «Bloccato» che `trashItem` non scavalca: utente e sistema, immutabile e solo-aggiunta.
    static let lockedFlags = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_APPEND)

    private let ssdRoot: URL
    private let hddRoot: URL?
    private let cloud: (any AlignmentCloud)?
    private let log: @Sendable (AlignmentLogEntry) throws -> Void
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String
    private let hashFunction: @Sendable (URL) -> MeasuredHash?
    private let trashFunction: @Sendable (URL) throws -> URL?
    private let volumeIdentity: @Sendable (URL) -> dev_t?
    private let fileFlags: @Sendable (URL) -> UInt32?
    private let fileSize: @Sendable (URL) -> Int64?

    init(ssdRoot: URL, hddRoot: URL?, cloud: (any AlignmentCloud)?,
         log: @escaping @Sendable (AlignmentLogEntry) throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() },
         makeId: @escaping @Sendable () -> String = { UUID().uuidString },
         hashFunction: @escaping @Sendable (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
         trashFunction: @escaping @Sendable (URL) throws -> URL? = { url in
             var resulting: NSURL?
             try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
             return resulting as URL?
         },
         volumeIdentity: @escaping @Sendable (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         fileFlags: @escaping @Sendable (URL) -> UInt32? = { url in
             var st = stat()
             return lstat(url.path, &st) == 0 ? st.st_flags : nil
         },
         fileSize: @escaping @Sendable (URL) -> Int64? = { url in
             var st = stat()
             return stat(url.path, &st) == 0 ? Int64(st.st_size) : nil
         }) {
        self.ssdRoot = ssdRoot
        self.hddRoot = hddRoot
        self.cloud = cloud
        self.log = log
        self.now = now
        self.makeId = makeId
        self.hashFunction = hashFunction
        self.trashFunction = trashFunction
        self.volumeIdentity = volumeIdentity
        self.fileFlags = fileFlags
        self.fileSize = fileSize
    }

    private func pendingEntry(_ c: AlignmentCandidate, id: String, blockId: String, absolute: String?) -> AlignmentLogEntry {
        AlignmentLogEntry(event: .pending, id: id, blockId: blockId, archive: c.archive, at: now(),
                          leavingPath: c.leavingPath, leavingKey: c.leavingKey, keptPath: c.keptPath, size: c.size,
                          sha256: c.sha256, etag: c.leavingETag, originalAbsolutePath: absolute)
    }

    private func outcomeEntry(_ e: AlignmentLogEntry.Event, _ c: AlignmentCandidate, id: String, blockId: String,
                              trashedPath: String? = nil, marker: String? = nil, detail: String? = nil) -> AlignmentLogEntry {
        AlignmentLogEntry(event: e, id: id, blockId: blockId, archive: c.archive, at: now(),
                          trashedPath: trashedPath, deleteMarkerVersionId: marker, detail: detail)
    }

    /// Le condizioni 3 e 4 dal vivo sull'SSD, uguali per HDD e Cubbit. `nil` = la copia puo'
    /// proseguire; altrimenti il motivo per saltarla. Il disco si ricontrolla PRIMA: un SSD
    /// sparito farebbe sembrare «non tornata» ogni copia.
    private enum SSDCheck { case ok, skip(AlignmentSkipReason), stop(AlignmentStopReason) }

    private func checkSSD(_ c: AlignmentCandidate, ssdDevice: dev_t) -> SSDCheck {
        guard volumeIdentity(ssdRoot) == ssdDevice else { return .stop(.volumeVanished(.ssd)) }
        guard let pSSD = RepairEngine.confined(ssdRoot, c.ssdLeavingPath),
              let kSSD = RepairEngine.confined(ssdRoot, c.ssdKeptPath) else { return .skip(.unsafePath) }
        if RepairEngine.itemExists(pSSD) { return .skip(.backOnSSD) }
        guard fileSize(kSSD) == c.ssdKeptSize else {
            return volumeIdentity(ssdRoot) == ssdDevice ? .skip(.keptChangedOnSSD) : .stop(.volumeVanished(.ssd))
        }
        return .ok
    }

    /// Un blocco sull'HDD. Non lancia: ogni copia non tolta ha il suo motivo, e la corsa si ferma
    /// solo sui guasti (disco sparito, registro, `trashItem` fallito, copia tenuta sparita).
    @concurrent
    func runHDDBlock(_ block: [AlignmentCandidate], blockId: String,
                     isCancelled: @escaping @Sendable () -> Bool = { false },
                     onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async -> AlignmentBlockOutcome {
        var out = AlignmentBlockOutcome()
        guard let hddRoot, let hddDevice = volumeIdentity(hddRoot) else { out.stop = .volumeMissing(.hdd); return out }
        guard let ssdDevice = volumeIdentity(ssdRoot) else { out.stop = .volumeMissing(.ssd); return out }

        copies: for (index, c) in block.enumerated() {
            // Solo FRA una copia e l'altra: una copia a meta' non esiste.
            if isCancelled() { out.stop = .interrupted; break }
            defer { onProgress(index + 1) }

            // Un collegamento simbolico non si sposta mai: `trashItem` toglierebbe il collegamento,
            // la rilettura avrebbe letto il file a cui porta.
            guard c.archive == .hdd,
                  let pURL = RepairEngine.confined(hddRoot, c.leavingPath),
                  let kURL = RepairEngine.confined(hddRoot, c.keptPath),
                  IndexableKind.of(url: pURL) != .notIndexable,
                  (try? pURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                out.skip(c, .unsafePath); continue
            }

            // Il disco e' ancora lo stesso, prima di qualunque verdetto su questa copia: un HDD
            // rimontato (o un altro disco con lo stesso nome) non e' quello che l'inventario ha visto.
            guard volumeIdentity(hddRoot) == hddDevice else { out.stop = .volumeVanished(.hdd); break }
            switch checkSSD(c, ssdDevice: ssdDevice) {
            case .ok: break
            case .skip(let r): out.skip(c, r); continue copies
            case .stop(let s): out.stop = s; break copies
            }

            // Il disco prima del verdetto: «non c'e'» e «l'HDD e' sparito» si somigliano.
            guard RepairEngine.itemExists(pURL) else {
                if volumeIdentity(hddRoot) != hddDevice { out.stop = .volumeVanished(.hdd); break }
                out.skip(c, .goneFromArchive); continue
            }
            guard RepairEngine.itemExists(kURL) else {
                if volumeIdentity(hddRoot) != hddDevice { out.stop = .volumeVanished(.hdd); break }
                out.skip(c, .keptMissingInArchive); continue
            }
            if let flags = fileFlags(pURL), flags & Self.lockedFlags != 0 { out.skip(c, .locked); continue }
            guard volumeIdentity(pURL) == hddDevice else { out.skip(c, .otherVolume); continue }

            // Condizione 6: rilettura e rihash di ENTRAMBE le copie, uguali fra loro e all'inventario.
            // Rileggere solo quella che esce direbbe che non e' cambiata, non che e' uguale a
            // quella che resta (ADR-0005, la contro-domanda).
            guard let p = hashFunction(pURL), let k = hashFunction(kURL) else {
                if volumeIdentity(hddRoot) != hddDevice { out.stop = .volumeVanished(.hdd); break }
                out.skip(c, .unreadable); continue
            }
            guard p.hash == c.sha256, k.hash == c.sha256, p.size == c.size, k.size == c.size else {
                out.skip(c, .contentChanged); continue
            }

            // Il registro PRIMA di toccare l'HDD.
            let id = makeId()
            do {
                try log(pendingEntry(c, id: id, blockId: blockId, absolute: pURL.path))
            } catch {
                out.stop = .logNotWritten(error.localizedDescription); break
            }
            let resulting: URL?
            do {
                resulting = try trashFunction(pURL)
            } catch {
                try? log(outcomeEntry(.failed, c, id: id, blockId: blockId, detail: error.localizedDescription))
                // Mai «era gia' fatto»: lo stesso errore arriva da un disco che sparisce.
                if volumeIdentity(hddRoot) != hddDevice { out.stop = .volumeVanished(.hdd); break }
                if let flags = fileFlags(pURL), flags & Self.lockedFlags != 0 { out.skip(c, .locked); continue }
                out.stop = .trashFailed(path: c.leavingPath, detail: (error as NSError).localizedDescription); break
            }
            // Il registro SUBITO, prima della copia successiva: dov'e' finita nel Cestino.
            do {
                try log(outcomeEntry(.removed, c, id: id, blockId: blockId, trashedPath: resulting?.path))
            } catch {
                out.removed.append(c)
                out.stop = .logNotWritten(error.localizedDescription); break
            }
            out.removed.append(c)
            // Post-condizione: la copia tenuta c'e' ancora. Non dovrebbe mai mancare, e proprio per
            // questo ci si ferma: la copia appena tolta e' nel registro, «Annulla» la rimette.
            guard RepairEngine.itemExists(kURL) else { out.stop = .keptVanished(path: c.keptPath); break }
        }
        return out
    }
}

'''
PATCHES = [("motore del progetto 4 (HDD) prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)]
```

### `05-alignment-engine-cubbit.py`

```python
# Task 5 — Il motore del progetto 4, lato Cubbit (ROADMAP #47, ADR-0019): prima di ogni blocco
# lo stato delle versioni e le regole di scadenza (condizione 7); per ogni copia il ricontrollo
# dal vivo (SSD, HEAD della copia tenuta e della copia uscita), la riga «pending», il DELETE
# SENZA versione, la riga «removed» con la versione del segno di cancellazione.
ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''// `nonisolated` anche qui: i membri di un'estensione non annotata sarebbero MainActor per il
// default del target (BUG-7): una funzione `async` senza `@concurrent` salterebbe sul main.
nonisolated extension ArchiveAligner {
    /// Un blocco su Cubbit. Non lancia: ogni copia non tolta ha il suo motivo; la corsa si ferma
    /// su versioni spente o regole non adatte, errori di Cubbit, registro, e su un DELETE che
    /// non ha creato il segno di cancellazione.
    @concurrent
    func runCubbitBlock(_ block: [AlignmentCandidate], blockId: String,
                        isCancelled: @escaping @Sendable () -> Bool = { false },
                        onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async -> AlignmentBlockOutcome {
        var out = AlignmentBlockOutcome()
        guard let cloud else { out.stop = .cubbitError("Cubbit non configurato"); return out }
        // Condizione 7, PRIMA DI OGNI BLOCCO: le versioni si leggono, non si cambiano mai.
        do {
            let safety = AlignmentCubbitSafety.evaluate(versioning: try await cloud.versioning(),
                                                        rules: try await cloud.lifecycleRules())
            guard case .ready = safety else { out.stop = .cubbitNotReady(safety); return out }
        } catch {
            out.stop = .cubbitError(error.localizedDescription); return out
        }
        guard let ssdDevice = volumeIdentity(ssdRoot) else { out.stop = .volumeMissing(.ssd); return out }

        copies: for (index, c) in block.enumerated() {
            if isCancelled() { out.stop = .interrupted; break }
            defer { onProgress(index + 1) }

            guard c.archive == .cubbit, let leavingETag = c.leavingETag, let keptETag = c.keptETag,
                  RepairPaths.safeComponents(c.leavingPath) != nil, RepairPaths.safeComponents(c.keptPath) != nil,
                  normalizedIndexKey(c.leavingPath) != normalizedIndexKey(c.keptPath) else {
                out.skip(c, .unsafePath); continue
            }
            switch checkSSD(c, ssdDevice: ssdDevice) {
            case .ok: break
            case .skip(let r): out.skip(c, r); continue copies
            case .stop(let s): out.stop = s; break copies
            }

            // Condizione 6 su Cubbit: HEAD della copia tenuta e della copia uscita, ADESSO.
            do {
                guard let k = try await cloud.head(key: c.keptPath) else { out.skip(c, .keptMissingInArchive); continue }
                guard k.size == c.size, RepairRules.normalizedETag(k.etag) == keptETag else { out.skip(c, .contentChanged); continue }
                guard let p = try await cloud.head(key: c.leavingPath) else { out.skip(c, .goneFromArchive); continue }
                guard p.size == c.size, RepairRules.normalizedETag(p.etag) == leavingETag else { out.skip(c, .contentChanged); continue }
            } catch {
                out.stop = .cubbitError(error.localizedDescription); break
            }

            let id = makeId()
            do {
                try log(pendingEntry(c, id: id, blockId: blockId, absolute: nil))
            } catch {
                out.stop = .logNotWritten(error.localizedDescription); break
            }
            // DELETE SENZA versione: con le versioni accese crea il segno di cancellazione, e la
            // versione della foto resta per i giorni della regola. Mai un DELETE con versione qui.
            let result: S3Syncer.DeleteResult
            do {
                result = try await cloud.delete(key: c.leavingPath)
            } catch {
                try? log(outcomeEntry(.failed, c, id: id, blockId: blockId, detail: error.localizedDescription))
                out.stop = .cubbitError(error.localizedDescription); break
            }
            guard result.isDeleteMarker, let marker = result.versionId else {
                // Le versioni dicevano «accese» e Cubbit ha cancellato senza segno: la copia
                // tenuta su Cubbit c'e' (HEAD appena fatta), ma ci si ferma SUBITO.
                try? log(outcomeEntry(.removed, c, id: id, blockId: blockId, marker: result.versionId,
                                      detail: "cancellata senza segno di cancellazione"))
                out.removed.append(c)
                out.stop = .deleteWithoutMarker(path: c.leavingPath); break
            }
            do {
                try log(outcomeEntry(.removed, c, id: id, blockId: blockId, marker: marker))
            } catch {
                out.removed.append(c)
                out.stop = .logNotWritten(error.localizedDescription); break
            }
            out.removed.append(c)
        }
        return out
    }
}

'''
PATCHES = [("motore del progetto 4 (Cubbit) prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)]
```

### `06-alignment-undo.py`

```python
# Task 6 — «Annulla l'ultimo blocco» del progetto 4 (spec, «Come si usa», punto 5). Sull'HDD con
# `TrashRestorer` (stessa cura del Cestino dell'SSD, mai sovrascrivere), che per questo riceve il
# modo di segnare «rimessa» come closure invece del registro dell'SSD: nessun cambio per i
# chiamanti di oggi. Su Cubbit togliendo i segni di cancellazione registrati, solo se sono
# davvero segni (mai una versione di dati), solo entro i giorni della regola, con la HEAD dopo.
P1 = ("TrashRestorer: la proprieta' del registro diventa una closure",
"""    private let libraryRoot: URL
    private let manifest: TrashManifestStore
    private let moveFunction: (URL, URL) throws -> Void""",
"""    private let libraryRoot: URL
    /// Come si segna «rimessa a posto». Per il Cestino dell'SSD e' `TrashManifestStore.markRestored`
    /// (init qui sotto, invariata); per l'HDD del progetto 4 (ADR-0019) una riga «restored» nel
    /// registro di quel progetto. Un errore si ignora come prima (la riconciliazione D3 la recupera).
    private let markRestored: (TrashedItem, Date) throws -> Void
    private let moveFunction: (URL, URL) throws -> Void""")
P2 = ("TrashRestorer: init con la closure, e quella di sempre che la costruisce dal registro",
"""    init(libraryRoot: URL,
         manifest: TrashManifestStore,
         moveFunction: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
         volumeIdentity: @escaping (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         now: @escaping () -> Date = Date.init) {
        self.libraryRoot = libraryRoot
        self.manifest = manifest
        self.moveFunction = moveFunction""",
"""    convenience init(libraryRoot: URL,
                     manifest: TrashManifestStore,
                     moveFunction: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                     hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
                     volumeIdentity: @escaping (URL) -> dev_t? = { deviceIdentifier(of: $0) },
                     now: @escaping () -> Date = Date.init) {
        self.init(libraryRoot: libraryRoot, markRestored: { try manifest.markRestored($0, at: $1) },
                  moveFunction: moveFunction, hashFunction: hashFunction, volumeIdentity: volumeIdentity, now: now)
    }

    init(libraryRoot: URL,
         markRestored: @escaping (TrashedItem, Date) throws -> Void,
         moveFunction: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
         volumeIdentity: @escaping (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         now: @escaping () -> Date = Date.init) {
        self.libraryRoot = libraryRoot
        self.markRestored = markRestored
        self.moveFunction = moveFunction""")
P3 = ("TrashRestorer: riconciliazione con la closure",
"""                    outcome.alreadyInPlace.append(item)
                    // La foto e' tornata: se la scrittura del registro fallisce non si
                    // ritenta qui, la prossima esecuzione la riconoscera' comunque via D3.
                    try? manifest.markRestored(item, at: now())""",
"""                    outcome.alreadyInPlace.append(item)
                    // La foto e' tornata: se la scrittura del registro fallisce non si
                    // ritenta qui, la prossima esecuzione la riconoscera' comunque via D3.
                    try? markRestored(item, now())""")
P4 = ("TrashRestorer: ripristino con la closure",
"""                outcome.restored.append(item)
                // Foto tornata: se la scrittura del registro fallisce non si ritenta qui, la
                // prossima esecuzione la riconosce comunque via D3.
                try? manifest.markRestored(item, at: now())""",
"""                outcome.restored.append(item)
                // Foto tornata: se la scrittura del registro fallisce non si ritenta qui, la
                // prossima esecuzione la riconosce comunque via D3.
                try? markRestored(item, now())""")

ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''/// Perche' una copia dell'ultimo blocco non e' stata rimessa a posto. Ogni caso ha la sua frase.
// `nonisolated`: value type puro.
nonisolated enum AlignmentUndoSkipReason: String, CaseIterable, Sendable {
    /// Il registro non dice dove e' finita (nessun percorso nel Cestino, nessun segno registrato).
    case notRestorable
    /// Non e' piu' nel Cestino dell'HDD: il Cestino e' stato svuotato.
    case missingInTrash
    /// Nel Cestino c'e' un file diverso da quello tolto.
    case changed
    /// Al suo posto c'e' gia' un altro file (HDD) o un'altra foto (Cubbit): mai sovrascrivere.
    case occupied
    case moveFailed
    case unreadable
    case outsideArchive
    /// Su Cubbit: piu' vecchia dei giorni della regola, la versione potrebbe non esserci piu'.
    case tooOld
    /// Su Cubbit: il segno registrato non c'e' piu'.
    case markerNotFound
    /// Su Cubbit: la versione registrata NON e' un segno di cancellazione. Non si tocca mai.
    case notADeleteMarker
    /// Su Cubbit: il segno registrato non e' l'ultimo stato della chiave.
    case markerNotLatest
    /// Su Cubbit: tolto il segno, la HEAD non ritrova la stessa foto.
    case verifyFailed
}

/// L'esito di «Annulla l'ultimo blocco».
// `nonisolated`: value type, prodotto fuori dal main.
nonisolated struct AlignmentUndoOutcome: Sendable {
    var restored = 0
    /// Gia' al suo posto: rimessa a mano, o un annullamento precedente interrotto prima del registro.
    var alreadyBack = 0
    var skipped: [AlignmentUndoSkipReason: Int] = [:]
    var skippedExamples: [AlignmentUndoSkipReason: [String]] = [:]
    var stop: AlignmentStopReason? = nil
    var notAttempted = 0

    var skippedCount: Int { skipped.values.reduce(0, +) }

    mutating func skip(_ path: String, _ r: AlignmentUndoSkipReason) {
        skipped[r, default: 0] += 1
        if skippedExamples[r, default: []].count < 3 { skippedExamples[r, default: []].append(path) }
    }
}

// `nonisolated`: chiamata da `undoCubbit`, fuori dal main.
nonisolated extension AlignmentCubbitSafety {
    /// Per quanti giorni un segno di cancellazione si puo' togliere ritrovando la foto: la
    /// regola attiva piu' corta. `nil` = nessuna regola, le versioni restano per sempre.
    static func undoWindowDays(rules: [S3Syncer.LifecycleRule]) -> Int? {
        rules.filter(\.enabled).compactMap(\.noncurrentDays).min()
    }
}

// `nonisolated` anche qui: i membri di un'estensione non annotata sarebbero MainActor per il
// default del target, e `undoCubbit` (async) salterebbe sul main senza un warning (BUG-7, caso
// D). Trovato scrivendo questo piano: `testArchiveAlignerUndo_runsWithoutTheMainThread` era rosso.
nonisolated extension ArchiveAligner {
    private func restoredEntry(_ r: AlignmentRemoval) -> AlignmentLogEntry {
        AlignmentLogEntry(event: .restored, id: r.id, blockId: r.blockId, archive: r.archive, at: now())
    }

    /// Rimette a posto le copie dell'ultimo blocco (`AlignmentLogState.lastBlockToRestore`).
    @concurrent
    func undo(_ removals: [AlignmentRemoval], archive: AlignmentArchive,
              isCancelled: @escaping @Sendable () -> Bool = { false },
              onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async -> AlignmentUndoOutcome {
        switch archive {
        case .hdd: return undoHDD(removals, isCancelled: isCancelled, onProgress: onProgress)
        case .cubbit: return await undoCubbit(removals, isCancelled: isCancelled, onProgress: onProgress)
        }
    }

    /// Sull'HDD: `TrashRestorer`, la stessa cura dell'annullamento dei Doppioni (confinamento,
    /// rilettura e riverifica nel Cestino, mai sovrascrivere, `st_dev` a ogni fallimento).
    private func undoHDD(_ removals: [AlignmentRemoval], isCancelled: @escaping @Sendable () -> Bool,
                         onProgress: @escaping @Sendable (Int) -> Void) -> AlignmentUndoOutcome {
        var out = AlignmentUndoOutcome()
        guard let hddRoot, volumeIdentity(hddRoot) != nil else {
            out.stop = .volumeMissing(.hdd); out.notAttempted = removals.count; return out
        }
        var items: [TrashedItem] = []
        var idByTrashedPath: [String: AlignmentRemoval] = [:]
        for r in removals where r.archive == .hdd {
            guard let original = r.originalAbsolutePath, !original.isEmpty, let trashed = r.trashedPath, !trashed.isEmpty else {
                out.skip(r.leavingPath, .notRestorable); continue
            }
            items.append(TrashedItem(batchId: r.blockId, originalDisplayPath: original, originalKey: r.leavingKey,
                                     trashedPath: trashed, size: r.size, hash: r.sha256, trashedAt: r.removedAt,
                                     keptPath: r.keptPath))
            idByTrashedPath[trashed] = r
        }
        let log = self.log
        let stamp = self.now
        let byTrashedPath = idByTrashedPath
        let restorer = TrashRestorer(libraryRoot: hddRoot, markRestored: { item, _ in
            guard let r = byTrashedPath[item.trashedPath] else { return }
            try log(AlignmentLogEntry(event: .restored, id: r.id, blockId: r.blockId, archive: .hdd, at: stamp()))
        }, hashFunction: hashFunction, volumeIdentity: volumeIdentity, now: now)
        let result = restorer.run(items, onProgress: { done, _ in onProgress(done) }, isCancelled: isCancelled)
        out.restored = result.restored.count
        out.alreadyBack = result.alreadyInPlace.count
        out.notAttempted = result.notAttempted
        for (item, reason) in result.skipped {
            let path = idByTrashedPath[item.trashedPath]?.leavingPath ?? item.originalDisplayPath
            switch reason {
            case .missingInTrash: out.skip(path, .missingInTrash)
            case .alteredInTrash: out.skip(path, .changed)
            case .originalPathOccupied: out.skip(path, .occupied)
            case .moveFailed: out.skip(path, .moveFailed)
            case .unreadableInTrash: out.skip(path, .unreadable)
            case .outsideLibrary: out.skip(path, .outsideArchive)
            }
        }
        if result.stoppedBecauseVolumeVanished { out.stop = .volumeVanished(.hdd) } else if result.interrupted { out.stop = .interrupted }
        return out
    }

    /// Su Cubbit: per ogni copia, la versione registrata deve essere un SEGNO di cancellazione e
    /// l'ultimo stato della chiave; solo allora il DELETE con versione lo toglie, e la HEAD
    /// deve ritrovare la stessa foto. Una copia gia' tornata si riconosce e si segna.
    private func undoCubbit(_ removals: [AlignmentRemoval], isCancelled: @escaping @Sendable () -> Bool,
                            onProgress: @escaping @Sendable (Int) -> Void) async -> AlignmentUndoOutcome {
        var out = AlignmentUndoOutcome()
        guard let cloud else { out.stop = .cubbitError("Cubbit non configurato"); out.notAttempted = removals.count; return out }
        let window: Int?
        do {
            window = AlignmentCubbitSafety.undoWindowDays(rules: try await cloud.lifecycleRules())
        } catch {
            out.stop = .cubbitError(error.localizedDescription); out.notAttempted = removals.count; return out
        }
        for (index, r) in removals.enumerated() {
            if isCancelled() { out.stop = .interrupted; out.notAttempted += removals.count - index; break }
            defer { onProgress(index + 1) }
            guard r.archive == .cubbit, let marker = r.deleteMarkerVersionId, !marker.isEmpty else {
                out.skip(r.leavingPath, .notRestorable); continue
            }
            // Un giorno di margine: la regola di Cubbit non scatta al secondo.
            if let window, now().timeIntervalSince(r.removedAt) >= TimeInterval(window - 1) * 86_400 {
                out.skip(r.leavingPath, .tooOld); continue
            }
            do {
                if let h = try await cloud.head(key: r.leavingPath) {
                    if h.size == r.size, RepairRules.normalizedETag(h.etag) == r.etag {
                        do { try log(restoredEntry(r)) } catch { out.stop = .logNotWritten(error.localizedDescription); break }
                        out.alreadyBack += 1
                    } else {
                        out.skip(r.leavingPath, .occupied)
                    }
                    continue
                }
                let versions = try await cloud.versions(key: r.leavingPath)
                guard let entry = versions.first(where: { $0.versionId == marker }) else { out.skip(r.leavingPath, .markerNotFound); continue }
                // L'unico DELETE con versione ammesso: solo su un SEGNO registrato, mai su dati.
                guard entry.isDeleteMarker else { out.skip(r.leavingPath, .notADeleteMarker); continue }
                guard entry.isLatest else { out.skip(r.leavingPath, .markerNotLatest); continue }
                _ = try await cloud.removeDeleteMarker(key: r.leavingPath, versionId: marker)
                guard let after = try await cloud.head(key: r.leavingPath), after.size == r.size,
                      RepairRules.normalizedETag(after.etag) == r.etag else {
                    out.skip(r.leavingPath, .verifyFailed); continue
                }
            } catch {
                out.stop = .cubbitError(error.localizedDescription); out.notAttempted += removals.count - index - 1; break
            }
            do { try log(restoredEntry(r)) } catch { out.restored += 1; out.stop = .logNotWritten(error.localizedDescription); break }
            out.restored += 1
        }
        return out
    }
}

'''
PATCHES = [P1, P2, P3, P4, ("annullamento del progetto 4 prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)]
```

### `07-alignment-gates.py`

```python
# Task 7 — Mutua esclusione del progetto 4 in entrambi i versi (spec, «Come si usa», punto 3):
# `BackupRunner.isAligning`, il parametro `isAligning` SENZA default in tutti i cancelli che gia'
# hanno `isRepairing`, i tre `begin…` che lo guardano, e `AlignmentStartGate` per il verso opposto.
P = []
def add(d, f, r): P.append((d, f, r))

# --- DuplicatesStatus.trashDisabledReason
add("trashDisabledReason: firma",
"""                                    isInventorying: Bool, isRepairing: Bool) -> String? {
        guard ssdMounted else {
            return "L'SSD non è collegato in questo momento: senza, l'app non può né \"""",
"""                                    isInventorying: Bool, isRepairing: Bool, isAligning: Bool) -> String? {
        guard ssdMounted else {
            return "L'SSD non è collegato in questo momento: senza, l'app non può né \"""")
add("trashDisabledReason: motivo",
"""        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di spostare copie nel Cestino."
        }""",
"""        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di spostare copie nel Cestino."
        }
        // ROADMAP #47: la corsa su HDD o Cubbit legge l'SSD per le condizioni 3 e 4.
        guard !isAligning else {
            return "L'app sta togliendo da HDD o Cubbit le copie già tolte dall'SSD: aspetta che finisca "
                + "prima di spostare copie nel Cestino."
        }""")
# --- DuplicatesStatus.undoDisabledReason
add("undoDisabledReason: firma",
"""                                   summary: RestorableBatchSummary?, hasEverTrashed: Bool,
                                   isInventorying: Bool, isRepairing: Bool) -> String? {""",
"""                                   summary: RestorableBatchSummary?, hasEverTrashed: Bool,
                                   isInventorying: Bool, isRepairing: Bool, isAligning: Bool) -> String? {""")
add("undoDisabledReason: motivo",
"""        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di annullare lo spostamento."
        }""",
"""        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di annullare lo spostamento."
        }
        guard !isAligning else {
            return "L'app sta togliendo copie doppie da HDD o Cubbit: aspetta che finisca prima di annullare "
                + "lo spostamento."
        }""")
# --- InventoryStartGate
add("InventoryStartGate: firma",
"""enum InventoryStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,""",
"""enum InventoryStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool, isAligning: Bool,""")
add("InventoryStartGate: motivo",
"""            return "L'app sta riparando una foto: aspetta che finisca, poi aggiorna l'inventario per "
                + "confermare la riparazione."
        }""",
"""            return "L'app sta riparando una foto: aspetta che finisca, poi aggiorna l'inventario per "
                + "confermare la riparazione."
        }
        if isAligning {
            return "L'app sta togliendo copie doppie da HDD o Cubbit: aspetta che finisca, altrimenti "
                + "l'inventario leggerebbe gli archivi mentre cambiano."
        }""")
# --- RepairStartGate
add("RepairStartGate: firma",
"""enum RepairStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,""",
"""enum RepairStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool, isAligning: Bool,""")
add("RepairStartGate: motivo",
"""        if isInventorying {
            return "L'inventario si sta aggiornando: aspetta che finisca, poi ripara."
        }""",
"""        if isInventorying {
            return "L'inventario si sta aggiornando: aspetta che finisca, poi ripara."
        }
        if isAligning {
            return "L'app sta togliendo copie doppie da HDD o Cubbit: aspetta che finisca, poi ripara."
        }""")
# --- AlignmentStartGate, dopo RepairStartGate
add("AlignmentStartGate dopo RepairStartGate",
"""    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."
}

/// I testi della finestra Inventario.""",
"""    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."
}

/// Perche' «Togli le copie…» del progetto 4 non puo' partire adesso, `nil` se puo' (ROADMAP #47,
/// ADR-0019). Il verso opposto sta nei cancelli delle altre operazioni, col parametro
/// `isAligning`. Precedenza scritta a parole: un'altra corsa > spostamento/annullamento >
/// riparazione > inventario > backup > lettura dell'elenco > dischi > Cubbit non configurato.
/// L'SSD serve sempre (condizioni 3 e 4 dal vivo); l'HDD solo per l'HDD; Cubbit solo per Cubbit.
enum AlignmentStartGate {
    static func blockedReason(archive: AlignmentArchive, isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool, isAligning: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
        if isAligning { return "Le copie doppie si stanno già togliendo: un archivio alla volta." }
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino delle copie doppie dell'SSD: aspetta che finisca."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto delle foto dal Cestino dell'SSD: aspetta che finisca."
        }
        if isRepairing { return "L'app sta riparando una foto: aspetta che finisca." }
        if isInventorying {
            return "L'inventario si sta aggiornando: aspetta che finisca, poi controlla di nuovo."
        }
        if isRunning {
            return "C'è un backup in corso: aspetta che finisca. Dopo un backup serve anche un inventario nuovo."
        }
        if isIndexing { return "L'app sta aggiornando l'elenco delle foto sull'SSD: aspetta che finisca." }
        if !ssdMounted {
            return "L'SSD non è collegato: serve per controllare che la copia tenuta ci sia ancora e che "
                + "quella da togliere non sia tornata."
        }
        if archive == .hdd && !hddMounted { return "L'HDD non è collegato." }
        if archive == .cubbit && !hasCubbitConfig {
            return "L'app non ha letto le credenziali di Cubbit: controlla in Diagnostica, poi riprova."
        }
        return nil
    }
}

/// I testi della finestra Inventario.""")
# --- JobStartGate
add("JobStartGate: firma",
"""                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool) -> String? {
        if isTrashingDuplicates {""",
"""                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,
                              isAligning: Bool) -> String? {
        if isTrashingDuplicates {""")
add("JobStartGate: motivo",
"""        if isRepairing {
            return "L'app sta riparando una foto. Aspetta che finisca: di solito bastano pochi secondi."
        }""",
"""        if isRepairing {
            return "L'app sta riparando una foto. Aspetta che finisca: di solito bastano pochi secondi."
        }
        // ROADMAP #47: un backup ricopierebbe su HDD e Cubbit proprio le copie che la corsa toglie,
        // e renderebbe vecchio l'inventario su cui la corsa si fida.
        if isAligning {
            return "L'app sta togliendo da HDD o Cubbit le copie doppie già tolte dall'SSD. Aspetta che "
                + "finisca, oppure fermala con «Interrompi» nella finestra Inventario."
        }""")
# --- LibraryIndexCommandGate
add("LibraryIndexCommandGate: firma",
"""                               isInventorying: Bool, isRepairing: Bool) -> String? {
        // Lo spostamento nel Cestino ha la precedenza sulle altre: da quando gira""",
"""                               isInventorying: Bool, isRepairing: Bool, isAligning: Bool) -> String? {
        // Lo spostamento nel Cestino ha la precedenza sulle altre: da quando gira""")
add("LibraryIndexCommandGate: motivo",
"""        if isRepairing {
            return "L'app sta riparando una foto: leggere le foto adesso potrebbe trovarla a metà. "
                + "Riprova quando ha finito."
        }""",
"""        if isRepairing {
            return "L'app sta riparando una foto: leggere le foto adesso potrebbe trovarla a metà. "
                + "Riprova quando ha finito."
        }
        if isAligning {
            return "L'app sta togliendo copie doppie da HDD o Cubbit: aspetta che finisca, poi aggiorna l'elenco."
        }""")
# --- BackupRunner: begin… e il flag
add("beginDuplicateTrashing guarda isAligning",
"""        guard !isTrashingDuplicates, !isRunning, !isIndexing, !isRestoringFromTrash, !isInventorying,
              !isRepairing else {""",
"""        guard !isTrashingDuplicates, !isRunning, !isIndexing, !isRestoringFromTrash, !isInventorying,
              !isRepairing, !isAligning else {""")
add("beginTrashRestore guarda isAligning",
"""        guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing, !isInventorying,
              !isRepairing else {""",
"""        guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing, !isInventorying,
              !isRepairing, !isAligning else {""")
add("beginRepair guarda isAligning",
"""        guard !isRepairing, !isTrashingDuplicates, !isRestoringFromTrash, !isInventorying, !isRunning,
              !isIndexing else {""",
"""        guard !isRepairing, !isTrashingDuplicates, !isRestoringFromTrash, !isInventorying, !isRunning,
              !isIndexing, !isAligning else {""")
add("isAligning con begin/end dopo endRepair",
"""    func endRepair() {
        isRepairing = false
    }""",
"""    func endRepair() {
        isRepairing = false
    }

    /// Vero mentre una corsa del progetto 4 toglie copie da HDD o Cubbit, o ne rimette a posto
    /// l'ultimo blocco (ROADMAP #47, ADR-0019). Vive QUI per la stessa ragione di
    /// `isTrashingDuplicates`: riaprire la finestra Inventario non deve permettere una seconda
    /// corsa, ne' un backup, una lettura, un inventario, una riparazione, uno spostamento.
    @Published private(set) var isAligning = false

    /// Rifiuta se c'e' gia' un'altra operazione in corso, altrimenti alza il flag. Controllo e
    /// impostazione sono atomici: entrambi sul MainActor.
    func beginAlignment() -> SimpleAlert? {
        guard !isAligning, !isRepairing, !isTrashingDuplicates, !isRestoringFromTrash, !isInventorying,
              !isRunning, !isIndexing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura dell'elenco, "
                    + "un inventario, una riparazione, uno spostamento nel Cestino, un annullamento o "
                    + "un'altra pulizia di HDD o Cubbit). Aspetta che finisca.")
        }
        isAligning = true
        return nil
    }

    /// Chiamato SEMPRE dall'unico punto in cui una corsa o un annullamento del progetto 4 finisce.
    func endAlignment() {
        isAligning = false
    }""")
# --- Chiamanti
add("chiamante: undoDisabledReason nel runner",
"""                                                             summary: restorableBatch, hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0,
                                                             isInventorying: isInventorying, isRepairing: isRepairing) {""",
"""                                                             summary: restorableBatch, hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0,
                                                             isInventorying: isInventorying, isRepairing: isRepairing,
                                                             isAligning: isAligning) {""")
add("chiamante: trashDisabledReason nel runner",
"""                                                           isInventorying: isInventorying,
                                                           isRepairing: isRepairing)""",
"""                                                           isInventorying: isInventorying,
                                                           isRepairing: isRepairing,
                                                           isAligning: isAligning)""")
add("chiamante: LibraryIndexCommandGate nel runner",
"""                                                              isInventorying: isInventorying,
                                                              isRepairing: isRepairing) {""",
"""                                                              isInventorying: isInventorying,
                                                              isRepairing: isRepairing,
                                                              isAligning: isAligning) {""")
add("chiamante: InventoryStartGate nel runner",
"""        if let reason = InventoryStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,""",
"""        if let reason = InventoryStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            isAligning: isAligning,""")
add("chiamante: RepairStartGate nel runner",
"""        if let reason = RepairStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,""",
"""        if let reason = RepairStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            isAligning: isAligning,""")
add("chiamante: JobStartGate in run(label:)",
"""                                                    isInventorying: isInventorying,
                                                    isRepairing: isRepairing) {""",
"""                                                    isInventorying: isInventorying,
                                                    isRepairing: isRepairing,
                                                    isAligning: isAligning) {""")
add("chiamante: LibraryIndexCommandGate nella card",
"""                                               isInventorying: runner.isInventorying,
                                               isRepairing: runner.isRepairing)""",
"""                                               isInventorying: runner.isInventorying,
                                               isRepairing: runner.isRepairing,
                                               isAligning: runner.isAligning)""")
add("chiamante: trashDisabledReason nella finestra Doppioni",
"""                                             isInventorying: runner.isInventorying,
                                             isRepairing: runner.isRepairing)""",
"""                                             isInventorying: runner.isInventorying,
                                             isRepairing: runner.isRepairing,
                                             isAligning: runner.isAligning)""")
add("chiamante: undoDisabledReason nella finestra Doppioni",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing)""",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing, isAligning: runner.isAligning)""")
add("chiamante: InventoryStartGate nella finestra Inventario",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)""",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing, isAligning: runner.isAligning,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)""")
add("chiamante: RepairStartGate nella finestra Inventario",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted, hasCubbitConfig: runner.s3Config != nil)""",
"""            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing, isAligning: runner.isAligning,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted, hasCubbitConfig: runner.s3Config != nil)""")
PATCHES = P
```

### `08-alignment-runner-ui.py`

```python
# Task 8 — Il progetto 4 nella finestra Inventario (ROADMAP #47, ADR-0019): i testi
# (`AlignmentStatus`, logica pura, niente gergo), l'esito di una corsa (`AlignmentRunOutcome`), il
# runner (controllo senza togliere, corsa a blocchi con il ricontrollo dell'inventario prima di
# ogni blocco, «Interrompi», annullamento dell'ultimo blocco) e la sezione nella finestra.
P = []
def add(d, f, r): P.append((d, f, r))

ANCHOR = "// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)\n"
CODE = r'''/// L'esito di una corsa (tutti i blocchi smaltiti prima che si fermasse).
// `nonisolated`: value type, accumulato fuori dal main.
nonisolated struct AlignmentRunOutcome: Sendable {
    let archive: AlignmentArchive
    let totalBlocks: Int
    var blocksCompleted = 0
    var removedCount = 0
    var removedBytes: Int64 = 0
    var skipped: [AlignmentSkipReason: Int] = [:]
    var skippedExamples: [AlignmentSkipReason: [String]] = [:]
    var stop: AlignmentStopReason? = nil

    mutating func absorb(_ b: AlignmentBlockOutcome) {
        removedCount += b.removed.count
        removedBytes += b.removedBytes
        for (r, n) in b.skipped { skipped[r, default: 0] += n }
        for (r, paths) in b.skippedExamples {
            skippedExamples[r] = Array((skippedExamples[r, default: []] + paths).prefix(3))
        }
    }
}

// `nonisolated`: la finestra usa l'archivio come elemento di un foglio (`.sheet(item:)`).
nonisolated extension AlignmentArchive: Identifiable {
    var id: String { rawValue }
}

// MARK: - Doppioni su HDD e Cubbit: i testi (ROADMAP #47, ADR-0019)

/// I testi della sezione «Copie già tolte dall'SSD» della finestra Inventario. Logica pura, come
/// `RepairStatus`: nessuna stringa nasce dentro la View. Registro: niente gergo («hash», «ETag»,
/// «MD5», «bucket», «DELETE», «segno di cancellazione», «versionId»): Enrico legge SSD, HDD,
/// Cubbit, copie, Cestino; «versioni» si', e' la parola della spec.
enum AlignmentStatus {
    typealias Line = InventoryStatus.Line

    static let sectionTitle = "Copie già tolte dall'SSD, ancora su HDD e Cubbit"
    static let sectionExplanation = "Le copie doppie che hai tolto dall'SSD ci sono ancora sull'HDD e su "
        + "Cubbit. Qui si tolgono anche da lì, una alla volta, solo se la copia che l'SSD ha tenuto c'è "
        + "ancora sull'SSD ed è identica sullo stesso archivio. Sull'HDD vanno nel suo Cestino (l'app non lo "
        + "svuota mai); su Cubbit si possono recuperare per 30 giorni."
    static let checkButton = "Controlla senza togliere"
    static let runButton = "Togli le copie…"
    static let undoButton = "Annulla l'ultimo blocco"
    static let stopButton = "Interrompi"
    static let continueButton = "Continua…"
    static let cancelButton = "Annulla"
    static let confirmButton = "Togli le copie"
    static let undoConfirmButton = "Rimetti a posto"
    static let checkingLine = "Controllo la storia degli spostamenti e l'inventario…"
    static let stoppingLine = "Mi fermo dopo la copia in corso…"
    /// Secondi per copia, per la stima a parole (misure del 2026-10-10: Cubbit ~110 ms a
    /// richiesta, tre richieste per copia; HDD: due riletture di file piccoli e uno spostamento).
    static func secondsPerCopy(_ a: AlignmentArchive) -> Double { a == .hdd ? 0.05 : 0.35 }

    static func archiveName(_ a: AlignmentArchive) -> String { a == .hdd ? "HDD" : "Cubbit" }

    private static func number(_ n: Int) -> String { n.formatted() }
    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(number(n)) \(n == 1 ? singular : plural)"
    }
    private static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// Perche' una copia resta, in una frase che segue «N restano: …».
    static func stayReasonText(_ r: AlignmentStayReason, archive a: AlignmentArchive) -> String {
        let x = archiveName(a)
        switch r {
        case .keptUnknown: return "la storia non dice quale copia l'SSD ha tenuto"
        case .outsideSSD: return "venivano da un posto che oggi non è l'SSD delle foto"
        case .unsafePath: return "il loro percorso non è sicuro da usare"
        case .sameAsKept: return "sono la stessa copia che l'SSD ha tenuto"
        case .repeatedInHistory: return "compaiono più volte nella storia: contano una volta sola"
        case .conflictingKept: return "la storia nomina per loro due copie tenute diverse"
        case .alreadyRemoved: return "le hai già tolte da \(x)"
        case .backOnSSD: return "sono di nuovo sull'SSD: il backup le ricopierebbe"
        case .keptNotOnSSD: return "la copia che l'SSD aveva tenuto non c'è più sull'SSD, o non si è lasciata leggere"
        case .notInArchive: return "non ci sono su \(x): niente da togliere"
        case .keptNotInArchive: return "la copia tenuta non c'è su \(x)"
        case .pathCollision: return "su \(x) due nomi diversi diventano lo stesso se non si guardano maiuscole e minuscole"
        case .unreadableInArchive: return "sull'HDD una delle due copie non si è lasciata leggere per intero"
        case .notCertifiable: return "su Cubbit l'app non riesce a confermare che il contenuto sia lo stesso senza scaricarle"
        case .contentDiffers: return "su \(x) non sono identiche alla copia tenuta"
        case .keptAlsoLeaving: return "sono a loro volta la copia tenuta di un'altra foto"
        }
    }

    /// L'esito di «Controlla senza togliere».
    static func planLines(_ p: AlignmentPlan, calendar: Calendar = .current) -> [Line] {
        let x = archiveName(p.archive)
        var out: [Line] = []
        if p.historyUnreadable {
            return [Line(id: "align-history", tone: .warning, text:
                "La storia degli spostamenti dell'SSD non si lascia leggere: da \(x) non tolgo niente.")]
        }
        if let block = p.block {
            return [Line(id: "align-block", tone: .warning, text:
                "Da \(x) non tolgo niente perché \(DuplicatesStatus.certificationReason(block, calendar: calendar)). "
                + "Aggiorna l'inventario e controlla di nuovo.")]
        }
        if p.candidates.isEmpty {
            out.append(Line(id: "align-none", tone: .ok, text: "Da \(x) non c'è niente da togliere."))
        } else {
            out.append(Line(id: "align-count", tone: .info, text:
                "Da \(x) si possono togliere \(count(p.candidates.count, "copia", "copie")) "
                + "(\(bytes(p.bytes))): per ognuna la copia che l'SSD ha tenuto c'è ancora sull'SSD ed è "
                + "identica su \(x)."))
        }
        for r in AlignmentStayReason.allCases {
            guard let n = p.stays[r], n > 0 else { continue }
            out.append(Line(id: "align-stay-\(r.rawValue)", tone: r == .alreadyRemoved || r == .repeatedInHistory ? .info : .warning,
                            text: "\(count(n, "copia resta", "copie restano")): \(stayReasonText(r, archive: p.archive))."))
        }
        if p.malformedHistoryLines > 0 {
            out.append(Line(id: "align-malformed", tone: .warning, text:
                "\(count(p.malformedHistoryLines, "riga della storia non si è lasciata leggere", "righe della storia non si sono lasciate leggere")): le loro copie restano."))
        }
        return out
    }

    /// Cosa l'app ha letto su Cubbit: versioni e regola dei 30 giorni (sola lettura).
    static func cubbitSafetyLine(_ s: AlignmentCubbitSafety) -> Line {
        switch s {
        case .ready(let days):
            return Line(id: "cubbit-ready", tone: .ok, text:
                "Su Cubbit le versioni sono accese: una copia tolta si può recuperare per \(count(days, "giorno", "giorni")).")
        case .versioningNotEnabled:
            return Line(id: "cubbit-versions", tone: .warning, text:
                "Su Cubbit le versioni non sono accese: senza, una copia tolta non si potrebbe più recuperare. "
                + "Finché non si accendono, da Cubbit non tolgo niente.")
        case .noExpiryRule:
            return Line(id: "cubbit-rule", tone: .warning, text:
                "Su Cubbit manca la regola che fa sparire le versioni vecchie dopo 30 giorni: lo spazio non si "
                + "libererebbe mai. Finché non c'è, da Cubbit non tolgo niente.")
        case .expiryTooShort(let days):
            return Line(id: "cubbit-short", tone: .warning, text:
                "Su Cubbit una regola fa sparire le versioni vecchie dopo \(count(days, "giorno", "giorni")): troppo "
                + "presto per poter tornare indietro. Ne servono almeno \(AlignmentCubbitSafety.minimumDays).")
        case .expiresCurrentPhotos:
            return Line(id: "cubbit-danger", tone: .warning, text:
                "Su Cubbit c'è una regola che farebbe sparire anche le foto di oggi: da Cubbit non tolgo niente. "
                + "Fai controllare subito le regole di Cubbit.")
        }
    }

    static func summaryTitle(_ a: AlignmentArchive) -> String { "Togliere le copie doppie da \(archiveName(a))?" }

    /// Il riepilogo prima della conferma (decisione 2 della spec, «come nel pannello Doppioni»).
    static func summaryLines(_ p: AlignmentPlan, blocks: Int) -> [String] {
        let x = archiveName(p.archive)
        var out = ["Tolgo da \(x) \(count(p.candidates.count, "copia", "copie")) (\(bytes(p.bytes))) che hai già tolto dall'SSD.",
                   "Per ognuna la copia che l'SSD ha tenuto resta, identica, sull'SSD e su \(x).",
                   "Prima di ogni copia ricontrollo dal vivo che le due copie siano ancora identiche: se qualcosa è "
                   + "cambiato, la lascio dov'è e te lo dico."]
        if p.archive == .hdd {
            out.append("Le copie vanno nel Cestino dell'HDD: lo spazio si libera solo quando svuoti il Cestino "
                       + "dell'HDD. L'app non lo svuota mai.")
        } else {
            out.append("Su Cubbit ogni copia tolta si può recuperare per 30 giorni; dopo, lo spazio si libera da solo.")
        }
        if blocks > 1 {
            out.append("Procedo a blocchi da al massimo \(number(duplicateBatchFileCap)) copie (\(number(blocks)) blocchi): "
                       + "«\(undoButton)» rimette a posto solo l'ultimo.")
        }
        out.append("Ci vorrà \(DuplicatesStatus.approxDuration(seconds: Double(p.candidates.count) * secondsPerCopy(p.archive))). "
                   + "Puoi fermarti quando vuoi con «\(stopButton)».")
        out.append("L'SSD non viene toccato.")
        return out
    }

    static let confirmTitle = "Togliere davvero queste copie?"
    static func confirmMessage(_ p: AlignmentPlan) -> String {
        p.archive == .hdd
            ? "Le \(number(p.candidates.count)) copie vanno nel Cestino dell'HDD. La copia tenuta resta, identica, sull'HDD e sull'SSD."
            : "Le \(number(p.candidates.count)) copie spariscono da Cubbit e restano recuperabili per 30 giorni. La copia tenuta resta, identica, su Cubbit e sull'SSD."
    }

    static func progressLine(_ a: AlignmentArchive, done: Int, total: Int, block: Int, blocks: Int) -> String {
        "Tolgo da \(archiveName(a)) le copie doppie: \(number(done)) di \(number(total))"
            + (blocks > 1 ? " (blocco \(block) di \(blocks))" : "")
    }

    static func skipReasonText(_ r: AlignmentSkipReason) -> String {
        switch r {
        case .unsafePath: return "il percorso non era sicuro da usare"
        case .backOnSSD: return "erano tornate sull'SSD"
        case .keptChangedOnSSD: return "la copia tenuta sull'SSD non c'era più o era cambiata"
        case .goneFromArchive: return "non c'erano già più"
        case .keptMissingInArchive: return "la copia tenuta non c'era più"
        case .locked: return "sono bloccate (l'opzione «Bloccato» del Finder): l'app non le sblocca"
        case .unreadable: return "non si sono lasciate rileggere"
        case .contentChanged: return "non erano più identiche a quelle viste dall'inventario"
        case .otherVolume: return "stavano su un altro disco"
        }
    }

    static func stopLine(_ s: AlignmentStopReason, archive a: AlignmentArchive, calendar: Calendar = .current) -> String {
        let x = archiveName(a)
        switch s {
        case .interrupted: return "Ti sei fermato tu: quello che è già stato tolto è nel registro."
        case .volumeMissing(let v): return "\(v == .ssd ? "L'SSD" : "L'HDD") non era collegato: non ho toccato niente."
        case .volumeVanished(let v): return "\(v == .ssd ? "L'SSD" : "L'HDD") si è scollegato: mi sono fermato subito."
        case .logNotWritten: return "Il registro sul Mac non si è lasciato scrivere: senza registro non tolgo niente, mi sono fermato."
        case .trashFailed(let path, let detail):
            return "Non sono riuscito a spostare nel Cestino dell'HDD «\(path)» (\(detail)): mi sono fermato. La copia è ancora al suo posto."
        case .keptVanished(let path):
            return "Subito dopo, la copia tenuta «\(path)» non c'era più: mi sono fermato. Premi «\(undoButton)» per rimettere a posto."
        case .cubbitNotReady(let safety): return cubbitSafetyLine(safety).text
        case .cubbitError: return "\(x) non ha risposto come doveva: mi sono fermato. Quello che è già stato tolto è nel registro."
        case .deleteWithoutMarker(let path):
            return "Cubbit ha tolto «\(path)» senza tenerne la versione recuperabile: mi sono fermato subito. "
                + "La copia tenuta è ancora su Cubbit, sull'SSD e sull'HDD. Fai ricontrollare le versioni di Cubbit."
        case .inventoryNoLongerValid(let block):
            return "Mi sono fermato perché \(DuplicatesStatus.certificationReason(block, calendar: calendar)): aggiorna l'inventario e controlla di nuovo."
        }
    }

    static func runOutcomeLines(_ o: AlignmentRunOutcome) -> [Line] {
        let x = archiveName(o.archive)
        var out = [Line(id: "run-removed", tone: o.removedCount > 0 ? .ok : .info, text:
            "Tolte da \(x) \(count(o.removedCount, "copia", "copie")) (\(bytes(o.removedBytes)))"
            + (o.archive == .hdd ? ": sono nel Cestino dell'HDD." : ": si possono recuperare per 30 giorni."))]
        if let stop = o.stop {
            out.append(Line(id: "run-stop", tone: stop == .interrupted ? .info : .warning, text: stopLine(stop, archive: o.archive)))
        }
        for r in AlignmentSkipReason.allCases {
            guard let n = o.skipped[r], n > 0 else { continue }
            out.append(Line(id: "run-skip-\(r.rawValue)", tone: .warning, text:
                "\(count(n, "copia è rimasta", "copie sono rimaste")) perché \(skipReasonText(r))."))
        }
        return out
    }

    static func undoConfirmation(_ a: AlignmentArchive, summary: RestorableBatchSummary, calendar: Calendar = .current) -> (title: String, message: String) {
        ("Rimettere a posto l'ultimo blocco?",
         "Rimetto su \(archiveName(a)) \(count(summary.pendingCount, "copia tolta", "copie tolte")) il "
         + "\(DuplicatesStatus.dayAndTime(summary.trashedAt, calendar: calendar)). Ogni copia viene ricontrollata; "
         + "se al suo posto c'è già qualcos'altro, l'app non lo sovrascrive e te lo dice.")
    }

    static func undoSkipText(_ r: AlignmentUndoSkipReason) -> String {
        switch r {
        case .notRestorable: return "il registro non dice dove sono finite"
        case .missingInTrash: return "non sono più nel Cestino dell'HDD: probabilmente è stato svuotato"
        case .changed: return "nel Cestino c'è un file diverso da quello tolto"
        case .occupied: return "al loro posto c'è già qualcos'altro, e l'app non sovrascrive mai"
        case .moveFailed: return "lo spostamento non è riuscito"
        case .unreadable: return "non si sono lasciate rileggere"
        case .outsideArchive: return "dovevano tornare in un posto fuori dall'archivio"
        case .tooOld: return "sono passati troppi giorni: Cubbit potrebbe non averle più"
        case .markerNotFound, .markerNotLatest: return "su Cubbit non risultano più tolte da questa app"
        case .notADeleteMarker: return "su Cubbit il registro non corrisponde: l'app non tocca niente"
        case .verifyFailed: return "dopo averle rimesse, Cubbit non mostra la stessa foto"
        }
    }

    static func undoOutcomeLines(_ a: AlignmentArchive, _ o: AlignmentUndoOutcome) -> [Line] {
        var out = [Line(id: "undo-restored", tone: o.restored + o.alreadyBack > 0 ? .ok : .info, text:
            "Rimesse su \(archiveName(a)) \(count(o.restored, "copia", "copie"))"
            + (o.alreadyBack > 0 ? "; \(count(o.alreadyBack, "era già al suo posto", "erano già al loro posto"))." : "."))]
        if let stop = o.stop {
            out.append(Line(id: "undo-stop", tone: stop == .interrupted ? .info : .warning, text: stopLine(stop, archive: a)))
        }
        for r in AlignmentUndoSkipReason.allCases {
            guard let n = o.skipped[r], n > 0 else { continue }
            out.append(Line(id: "undo-skip-\(r.rawValue)", tone: .warning, text:
                "\(count(n, "copia non è tornata", "copie non sono tornate")) perché \(undoSkipText(r))."))
        }
        if o.notAttempted > 0 {
            out.append(Line(id: "undo-left", tone: .info, text: "\(count(o.notAttempted, "copia resta", "copie restano")) da rimettere: premi di nuovo «\(undoButton)»."))
        }
        return out
    }

    /// Righe «pending» senza esito: l'app si e' chiusa mentre toglieva quelle copie.
    static func unfinishedLine(_ n: Int, archive a: AlignmentArchive) -> Line? {
        guard n > 0 else { return nil }
        return Line(id: "align-unfinished", tone: .warning, text:
            "\(count(n, "copia risulta", "copie risultano")) a metà su \(archiveName(a)): l'app si è chiusa mentre le "
            + "toglieva. Il registro sul Mac le elenca: vanno controllate a mano.")
    }
}

'''
add("tipi e testi del progetto 4 prima dei testi della riparazione", ANCHOR, CODE + ANCHOR)

add("la nota della finestra Inventario non dice piu' che scrive solo «Ripara…»",
"""    static let readOnlyNote = "L'inventario guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit. L'unica cosa che da qui può scrivere è "
        + "«Ripara…», una foto alla volta e solo dopo la tua conferma.\"""",
"""    static let readOnlyNote = "L'inventario guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit. Da qui scrivono solo «Ripara…», una foto alla "
        + "volta, e «Togli le copie…», che toglie da HDD e Cubbit le copie già tolte dall'SSD: sempre e "
        + "solo dopo la tua conferma.\"""")

RUNNER = r'''    // MARK: Doppioni su HDD e Cubbit (ROADMAP #47, ADR-0019)

    /// I registri del progetto 4, uno per archivio, sul disco interno come gli altri (BUG-10:
    /// sotto test in una cartella temporanea). Lazy e `try?`: senza registro la corsa non parte.
    private(set) lazy var alignmentHDDLog: AlignmentLogStore? = {
        try? AlignmentLogStore(url: backupRunnerStoreRoot().appendingPathComponent("alignment-hdd.jsonl"))
    }()
    private(set) lazy var alignmentCubbitLog: AlignmentLogStore? = {
        try? AlignmentLogStore(url: backupRunnerStoreRoot().appendingPathComponent("alignment-cubbit.jsonl"))
    }()
    private func alignmentLog(_ a: AlignmentArchive) -> AlignmentLogStore? { a == .hdd ? alignmentHDDLog : alignmentCubbitLog }

    /// L'ultimo controllo per archivio: e' lui che la corsa usa, congelato (mai ricalcolato fra
    /// il riepilogo e la corsa). Dopo una corsa si azzera: le copie tolte vanno ricontate.
    @Published private(set) var alignmentPlans: [AlignmentArchive: AlignmentPlan] = [:]
    @Published private(set) var alignmentCubbitSafety: AlignmentCubbitSafety? = nil
    @Published private(set) var alignmentChecking: AlignmentArchive? = nil
    /// L'archivio su cui gira una corsa o un annullamento; `nil` se nessuno.
    @Published private(set) var alignmentRunArchive: AlignmentArchive? = nil
    @Published private(set) var alignmentProgress: (done: Int, total: Int, block: Int, blocks: Int)? = nil
    @Published private(set) var alignmentStopRequested = false
    @Published private(set) var lastAlignmentOutcome: [AlignmentArchive: AlignmentRunOutcome] = [:]
    @Published private(set) var lastAlignmentUndoOutcome: [AlignmentArchive: AlignmentUndoOutcome] = [:]
    @Published private(set) var alignmentUndoSummary: [AlignmentArchive: RestorableBatchSummary] = [:]
    @Published private(set) var alignmentUnfinished: [AlignmentArchive: Int] = [:]
    private var alignmentCancelFlag: CancelFlag? = nil

    private var trashHistoryURL: URL { backupRunnerStoreRoot().appendingPathComponent("trash-history.jsonl") }

    /// Rilegge i due registri fuori dal main: cosa si puo' annullare, cosa e' rimasto a meta'.
    func refreshAlignmentLogSummaries() {
        let logs = AlignmentArchive.allCases.compactMap { a in alignmentLog(a).map { (a, $0) } }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var summaries: [AlignmentArchive: RestorableBatchSummary] = [:]
            var unfinished: [AlignmentArchive: Int] = [:]
            for (a, log) in logs {
                guard let s = log.state(for: a) else { continue }
                summaries[a] = s.lastBlockSummary
                unfinished[a] = s.unfinished.count
            }
            let (s, u) = (summaries, unfinished)
            await MainActor.run {
                if self.alignmentUndoSummary != s { self.alignmentUndoSummary = s }
                if self.alignmentUnfinished != u { self.alignmentUnfinished = u }
            }
        }
    }

    /// «Controlla senza togliere» (regola assoluta 4): le condizioni 1-5 sull'inventario e sulla
    /// storia, e per Cubbit lo stato delle versioni (sola lettura). Non tocca nessun archivio.
    func startAlignmentCheck(_ archive: AlignmentArchive, onAlert: @escaping AlertSink) {
        guard alignmentChecking == nil, !isAligning else { return }
        guard let store = libraryIndexStore, let log = alignmentLog(archive), let ssdRoot = bm.urls[.ssd] else {
            onAlert(SimpleAlert(title: "Controllo non disponibile",
                                message: "L'elenco delle foto, il registro o l'SSD non sono disponibili in questo momento."))
            return
        }
        alignmentChecking = archive
        let lastWrite = ArchiveWriteClock.lastWriteAt()
        let historyURL = trashHistoryURL
        let cloud: S3AlignmentCloud? = archive == .cubbit ? s3Config.map { S3AlignmentCloud(syncer: S3Syncer(), config: $0) } : nil
        Task.detached(priority: .userInitiated) {
            let history = TrashHistoryReader.read(url: historyURL)
            let logState = log.state(for: archive)
            var plan: AlignmentPlan? = nil
            if let logState {
                if let snapshot = try? store.inventorySnapshot() {
                    plan = AlignmentPlanner.plan(archive: archive, history: history, ssdRoot: ssdRoot, snapshot: snapshot,
                                                 lastArchiveWriteAt: lastWrite, alreadyRemoved: logState.removedKeys)
                } else {
                    plan = .blocked(archive, block: .inventoryUnreadable)
                }
            }
            var safety: AlignmentCubbitSafety? = nil
            if let cloud, let v = try? await cloud.versioning(), let rules = try? await cloud.lifecycleRules() {
                safety = AlignmentCubbitSafety.evaluate(versioning: v, rules: rules)
            }
            let (finalPlan, finalSafety) = (plan, safety)
            await MainActor.run {
                self.alignmentChecking = nil
                guard let finalPlan, let logState else {
                    onAlert(SimpleAlert(title: "Il registro non si lascia leggere",
                                        message: "Il registro delle copie tolte da \(AlignmentStatus.archiveName(archive)) non si "
                                            + "lascia leggere: finché non si risolve, l'app non toglie niente."))
                    return
                }
                self.alignmentPlans[archive] = finalPlan
                if archive == .cubbit { self.alignmentCubbitSafety = finalSafety }
                self.alignmentUndoSummary[archive] = logState.lastBlockSummary
                self.alignmentUnfinished[archive] = logState.unfinished.count
            }
        }
    }

    /// «Togli le copie» confermato: la corsa a blocchi sul piano congelato dal controllo. Le
    /// precondizioni si rivalutano QUI, all'avvio vero; `isAligning` per l'intera corsa (non per
    /// blocco: fra due blocchi non deve poter partire nient'altro); prima di OGNI blocco dischi
    /// collegati e inventario ancora quello che ha certificato le copie (ADR-0017, stessa funzione).
    func startAlignmentRun(_ plan: AlignmentPlan, onAlert: @escaping AlertSink) {
        let archive = plan.archive
        guard let runId = plan.runId, plan.block == nil, !plan.candidates.isEmpty else {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: "Premi prima «\(AlignmentStatus.checkButton)»."))
            return
        }
        if let reason = AlignmentStartGate.blockedReason(
            archive: archive, isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            isAligning: isAligning, ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let store = libraryIndexStore, let log = alignmentLog(archive) else {
            onAlert(SimpleAlert(title: "Non è stato possibile procedere", message: "L'elenco delle foto o il registro non sono disponibili."))
            return
        }
        guard let roots = alignmentRoots(archive, onAlert: onAlert) else { return }
        let cloud: S3AlignmentCloud? = archive == .cubbit ? s3Config.map { S3AlignmentCloud(syncer: S3Syncer(), config: $0) } : nil
        if let alert = beginAlignment() {
            closeAlignmentAccess()
            onAlert(alert)
            return
        }
        let flag = CancelFlag()
        alignmentCancelFlag = flag
        alignmentStopRequested = false
        alignmentRunArchive = archive
        lastAlignmentOutcome[archive] = nil
        lastAlignmentUndoOutcome[archive] = nil
        let blocks = AlignmentRunPlan.blocks(plan.candidates)
        let total = plan.candidates.count
        alignmentProgress = (0, total, 1, blocks.count)

        Task.detached(priority: .utility) {
            let aligner = ArchiveAligner(ssdRoot: roots.ssd, hddRoot: roots.hdd, cloud: cloud, log: { try log.append($0) })
            var run = AlignmentRunOutcome(archive: archive, totalBlocks: blocks.count)
            var doneSoFar = 0
            for (index, block) in blocks.enumerated() {
                if flag.isCancelled { run.stop = .interrupted; break }
                let (ssdMounted, hddMounted, lastWrite) = await MainActor.run {
                    (VolumeMonitor.shared.ssdMounted, VolumeMonitor.shared.hddMounted, ArchiveWriteClock.lastWriteAt())
                }
                guard ssdMounted else { run.stop = .volumeVanished(.ssd); break }
                if archive == .hdd && !hddMounted { run.stop = .volumeVanished(.hdd); break }
                // Condizione 1, prima di OGNI blocco: stesso giro, ancora completo, nessun backup dopo.
                if let b = DuplicateCertification.runBlock(states: try? store.inventoryStates(), lastArchiveWriteAt: lastWrite,
                                                           certifiedRunId: runId) {
                    run.stop = .inventoryNoLongerValid(b); break
                }
                let before = doneSoFar
                let count = block.count
                let progress: @Sendable (Int) -> Void = { done in
                    guard done % 25 == 0 || done == count else { return }
                    // Un aggiornamento arrivato dopo la fine non riaccende la barra (stesso schema della riparazione).
                    Task { @MainActor in if self.isAligning { self.alignmentProgress = (before + done, total, index + 1, blocks.count) } }
                }
                let blockId = UUID().uuidString
                let outcome = archive == .hdd
                    ? await aligner.runHDDBlock(block, blockId: blockId, isCancelled: { flag.isCancelled }, onProgress: progress)
                    : await aligner.runCubbitBlock(block, blockId: blockId, isCancelled: { flag.isCancelled }, onProgress: progress)
                run.absorb(outcome)
                doneSoFar += block.count
                if let stop = outcome.stop { run.stop = stop; break }
                run.blocksCompleted += 1
            }
            let final = run
            let state = log.state(for: archive)
            await MainActor.run {
                self.lastAlignmentOutcome[archive] = final
                // Il piano e' consumato: le copie tolte ora sono «gia' tolte», si ricontrolla.
                self.alignmentPlans[archive] = nil
                self.finishAlignment(archive, logState: state)
            }
        }
    }

    /// «Annulla l'ultimo blocco» confermato.
    func startAlignmentUndo(_ archive: AlignmentArchive, onAlert: @escaping AlertSink) {
        if let reason = AlignmentStartGate.blockedReason(
            archive: archive, isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            isAligning: isAligning, ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let log = alignmentLog(archive) else { return }
        guard let roots = alignmentRoots(archive, onAlert: onAlert) else { return }
        let cloud: S3AlignmentCloud? = archive == .cubbit ? s3Config.map { S3AlignmentCloud(syncer: S3Syncer(), config: $0) } : nil
        if let alert = beginAlignment() {
            closeAlignmentAccess()
            onAlert(alert)
            return
        }
        let flag = CancelFlag()
        alignmentCancelFlag = flag
        alignmentStopRequested = false
        alignmentRunArchive = archive
        lastAlignmentUndoOutcome[archive] = nil
        lastAlignmentOutcome[archive] = nil
        Task.detached(priority: .utility) {
            let removals = log.state(for: archive)?.lastBlockToRestore ?? []
            let total = removals.count
            await MainActor.run { self.alignmentProgress = (0, total, 1, 1) }
            let aligner = ArchiveAligner(ssdRoot: roots.ssd, hddRoot: roots.hdd, cloud: cloud, log: { try log.append($0) })
            let outcome = await aligner.undo(removals, archive: archive, isCancelled: { flag.isCancelled }, onProgress: { done in
                Task { @MainActor in if self.isAligning { self.alignmentProgress = (done, total, 1, 1) } }
            })
            let state = log.state(for: archive)
            await MainActor.run {
                self.lastAlignmentUndoOutcome[archive] = outcome
                self.alignmentPlans[archive] = nil
                self.finishAlignment(archive, logState: state)
            }
        }
    }

    /// «Interrompi» (idempotente): la corsa si ferma fra una copia e l'altra.
    func stopAlignment() {
        guard isAligning, !alignmentStopRequested else { return }
        alignmentStopRequested = true
        alignmentCancelFlag?.cancel()
    }

    /// Le radici di SSD (sempre) e HDD (solo per l'HDD), aperte; `nil` dopo aver mostrato l'avviso.
    private func alignmentRoots(_ archive: AlignmentArchive, onAlert: @escaping AlertSink) -> (ssd: URL, hdd: URL?)? {
        guard let ssdURL = bm.startAccessing(.ssd), isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            onAlert(SimpleAlert(title: "SSD non valido",
                                message: "Vai in Impostazioni e riseleziona l'SSD scegliendo '/Volumes/SSD - Enri' (la radice del disco, non una cartella)."))
            return nil
        }
        guard archive == .hdd else { return (ssdURL, nil) }
        guard let hddURL = bm.startAccessing(.hdd), isLikelyVolumeRoot(hddURL) else {
            closeAlignmentAccess()
            onAlert(SimpleAlert(title: "HDD non valido",
                                message: "Vai in Impostazioni e riseleziona l'HDD scegliendo '/Volumes/BackupHDD' (la radice del disco, non una cartella)."))
            return nil
        }
        return (ssdURL, hddURL)
    }

    private func closeAlignmentAccess() {
        bm.stopAccessing(.ssd)
        bm.stopAccessing(.hdd)
    }

    /// L'UNICO punto in cui una corsa o un annullamento del progetto 4 finisce, su ogni percorso.
    private func finishAlignment(_ archive: AlignmentArchive, logState: AlignmentLogState?) {
        closeAlignmentAccess()
        endAlignment()
        alignmentProgress = nil
        alignmentStopRequested = false
        alignmentCancelFlag = nil
        alignmentRunArchive = nil
        alignmentUndoSummary[archive] = logState?.lastBlockSummary
        alignmentUnfinished[archive] = logState?.unfinished.count ?? 0
    }

'''
add("runner del progetto 4 dopo la riparazione",
"""    // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati""",
RUNNER + """    // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati""")

add("finestra Inventario: stato della conversazione del progetto 4",
"""    @State private var confirmRepair: RepairCandidate? = nil""",
"""    @State private var confirmRepair: RepairCandidate? = nil
    /// Il riepilogo del progetto 4 aperto (per archivio) e il piano da confermare dopo la sua
    /// chiusura: stessa forma di `pendingRepair`/`confirmRepair`.
    @State private var alignmentSheet: AlignmentArchive? = nil
    @State private var confirmAlignment: AlignmentPlan? = nil""")
add("finestra Inventario: sezione del progetto 4 sotto le categorie",
"""                        ForEach(InventoryStatus.displayOrder, id: \\.self) { category in
                            categoryRow(category, summary: summary)
                        }""",
"""                        ForEach(InventoryStatus.displayOrder, id: \\.self) { category in
                            categoryRow(category, summary: summary)
                        }
                        Divider()
                        alignmentSection""")
add("finestra Inventario: i registri si rileggono all'apertura",
"""            runner.refreshRepairRecords()""",
"""            runner.refreshRepairRecords()
            runner.refreshAlignmentLogSummaries()""")
add("finestra Inventario: foglio del riepilogo del progetto 4",
"""        .sheet(item: $pendingRepair, onDismiss: {""",
"""        .sheet(item: $alignmentSheet, onDismiss: {
            guard let plan = confirmAlignment else { return }
            confirmAlignment = nil
            alert = SimpleAlert(title: AlignmentStatus.confirmTitle, message: AlignmentStatus.confirmMessage(plan),
                                isDestructive: true, confirmTitle: AlignmentStatus.confirmButton,
                                cancelTitle: AlignmentStatus.cancelButton,
                                onConfirm: { runner.startAlignmentRun(plan, onAlert: { alert = $0 }) })
        }) { archive in
            alignmentSummarySheet(archive)
        }
        .sheet(item: $pendingRepair, onDismiss: {""")
VIEW = r'''    private func alignmentDisabledReason(_ archive: AlignmentArchive) -> String? {
        AlignmentStartGate.blockedReason(
            archive: archive, isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing, isAligning: runner.isAligning,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted, hasCubbitConfig: runner.s3Config != nil)
    }

    /// «Togli le copie…» si puo' premere solo dopo un controllo che certifica qualcosa (e su
    /// Cubbit con le versioni lette accese): la corsa usa proprio quel piano.
    private func alignmentPlanReady(_ archive: AlignmentArchive) -> AlignmentPlan? {
        guard let plan = runner.alignmentPlans[archive], plan.block == nil, !plan.candidates.isEmpty else { return nil }
        if archive == .cubbit { guard case .ready = runner.alignmentCubbitSafety else { return nil } }
        return plan
    }

    /// Progetto 4 (ROADMAP #47, ADR-0019): HDD e Cubbit separati.
    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AlignmentStatus.sectionTitle).font(AppFont.body)
            Text(AlignmentStatus.sectionExplanation)
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AlignmentArchive.allCases) { archive in alignmentRow(archive) }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    @ViewBuilder
    private func alignmentRow(_ archive: AlignmentArchive) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(AlignmentStatus.archiveName(archive)).font(AppFont.body)
            if runner.alignmentRunArchive == archive {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    if runner.alignmentStopRequested {
                        Text(AlignmentStatus.stoppingLine).font(AppFont.caption)
                    } else if let p = runner.alignmentProgress {
                        Text(AlignmentStatus.progressLine(archive, done: p.done, total: p.total, block: p.block, blocks: p.blocks))
                            .font(AppFont.caption)
                    }
                    Button(AlignmentStatus.stopButton) { runner.stopAlignment() }
                        .disabled(runner.alignmentStopRequested)
                }
            } else {
                HStack(spacing: AppSpacing.sm) {
                    Button(AlignmentStatus.checkButton) { runner.startAlignmentCheck(archive, onAlert: { alert = $0 }) }
                        .disabled(runner.alignmentChecking != nil || runner.isAligning)
                    Button(AlignmentStatus.runButton) { alignmentSheet = archive }
                        .disabled(alignmentPlanReady(archive) == nil || alignmentDisabledReason(archive) != nil)
                    if let summary = runner.alignmentUndoSummary[archive] {
                        Button(AlignmentStatus.undoButton) {
                            let c = AlignmentStatus.undoConfirmation(archive, summary: summary)
                            alert = SimpleAlert(title: c.title, message: c.message, confirmTitle: AlignmentStatus.undoConfirmButton,
                                                cancelTitle: AlignmentStatus.cancelButton,
                                                onConfirm: { runner.startAlignmentUndo(archive, onAlert: { alert = $0 }) })
                        }
                        .disabled(alignmentDisabledReason(archive) != nil)
                    }
                }
                if runner.alignmentChecking == archive {
                    HStack(spacing: AppSpacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(AlignmentStatus.checkingLine).font(AppFont.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if archive == .cubbit, let safety = runner.alignmentCubbitSafety { lineView(AlignmentStatus.cubbitSafetyLine(safety)) }
            if let plan = runner.alignmentPlans[archive] { ForEach(AlignmentStatus.planLines(plan)) { lineView($0) } }
            if let line = AlignmentStatus.unfinishedLine(runner.alignmentUnfinished[archive] ?? 0, archive: archive) { lineView(line) }
            if let o = runner.lastAlignmentOutcome[archive] { ForEach(AlignmentStatus.runOutcomeLines(o)) { lineView($0) } }
            if let u = runner.lastAlignmentUndoOutcome[archive] { ForEach(AlignmentStatus.undoOutcomeLines(archive, u)) { lineView($0) } }
            if let reason = alignmentDisabledReason(archive), !runner.isAligning {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Il riepilogo prima della conferma distruttiva, come per «Ripara…».
    private func alignmentSummarySheet(_ archive: AlignmentArchive) -> some View {
        let plan = alignmentPlanReady(archive)
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AlignmentStatus.summaryTitle(archive)).font(AppFont.title)
            if let plan {
                ForEach(Array(AlignmentStatus.summaryLines(plan, blocks: AlignmentRunPlan.blocks(plan.candidates).count).enumerated()),
                        id: \.offset) { _, line in
                    Text(line).font(AppFont.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(AlignmentStatus.cancelButton, role: .cancel) { alignmentSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(AlignmentStatus.continueButton) {
                    confirmAlignment = plan
                    alignmentSheet = nil
                }
                .disabled(plan == nil || alignmentDisabledReason(archive) != nil)
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 520)
    }

'''
add("finestra Inventario: le viste del progetto 4 prima del piede",
"""    private var footer: some View {""",
VIEW + """    private var footer: some View {""")
PATCHES = P
```


## Appendice B — File di test nuovi

Stato al task in cui nascono (`AlignmentDeleteGuardTests` cresce nei Task 5 e 6: aggiunte in Appendice C).

### Task 1 — `AppBackupFotoTests/AlignmentPlannerTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Le condizioni 1-5 della spec del progetto 4 (ROADMAP #47, ADR-0019): quali copie uscite
/// dall'SSD si possono togliere da HDD e Cubbit, sull'inventario, senza toccare niente. Per
/// ogni motivo per cui una copia resta c'e' un test che lo produce da solo.
final class AlignmentPlannerTests: XCTestCase {
    private let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"

    // MARK: - Aiuti

    private func digest(_ text: String) -> ContentDigest {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize()
    }

    private func local(_ path: String, _ text: String, status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        let d = digest(text)
        return InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: d.size, mtime: 0,
                                  status: status, digest: status == .ok ? d : nil, hashedAt: 0)
    }

    private func object(_ key: String, _ text: String, etag: String? = nil) -> InventoryS3Object {
        let d = digest(text)
        return InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: d.size, etag: etag ?? "\"\(d.md5)\"")
    }

    private func states(complete: Bool = true, started: Double = 1_000) -> [InventoryArchive: InventoryArchiveState] {
        Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, InventoryArchiveState(archive: $0, runId: 7, complete: complete, reason: complete ? nil : .interrupted,
                                       unreadable: 0, startedAt: started, finishedAt: started + 60))
        })
    }

    /// SSD con la sola copia tenuta; HDD e Cubbit con entrambe, stesso contenuto.
    private func snapshot(ssd: [InventoryLocalFile]? = nil, hdd: [InventoryLocalFile]? = nil,
                          s3: [InventoryS3Object]? = nil, complete: Bool = true) -> InventorySnapshot {
        InventorySnapshot(ssd: ssd ?? [local(kept, "foto")],
                          hdd: hdd ?? [local(leaving, "foto"), local(kept, "foto")],
                          s3: s3 ?? [object(leaving, "foto"), object(kept, "foto")],
                          states: states(complete: complete))
    }

    private func history(_ pairs: [(String, String?)]) -> TrashHistoryReader.Result {
        let entry = TrashHistoryEntry(blockId: "b1", trashedAt: Date(timeIntervalSince1970: 500),
                                      originalPaths: pairs.map { $0.0 },
                                      keptPaths: pairs.map { $0.1 ?? "" })
        return TrashHistoryReader.Result(entries: [entry], malformedLines: 0, unreadable: false)
    }

    private func abs(_ rel: String) -> String { "/Volumes/SSD - Enri/" + rel }

    private func plan(_ archive: AlignmentArchive, history h: TrashHistoryReader.Result? = nil,
                      snapshot s: InventorySnapshot? = nil, lastWrite: Date? = nil,
                      alreadyRemoved: Set<String> = []) -> AlignmentPlan {
        AlignmentPlanner.plan(archive: archive, history: h ?? history([(abs(leaving), kept)]), ssdRoot: ssdRoot,
                              snapshot: s ?? snapshot(), lastArchiveWriteAt: lastWrite, alreadyRemoved: alreadyRemoved)
    }

    private func onlyStay(_ p: AlignmentPlan, _ reason: AlignmentStayReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.candidates.isEmpty, "nessuna copia doveva uscire", file: file, line: line)
        XCTAssertEqual(p.stays, [reason: 1], file: file, line: line)
    }

    // MARK: - Il caso buono

    func testHDD_copyWithKeptCopyCertified_isACandidate() {
        let p = plan(.hdd)
        XCTAssertNil(p.block)
        XCTAssertEqual(p.runId, 7)
        XCTAssertEqual(p.candidates.count, 1)
        let c = p.candidates[0]
        XCTAssertEqual(c.archive, .hdd)
        XCTAssertEqual(c.leavingPath, leaving)
        XCTAssertEqual(c.keptPath, kept)
        XCTAssertEqual(c.ssdLeavingPath, leaving)
        XCTAssertEqual(c.ssdKeptPath, kept)
        XCTAssertEqual(c.sha256, digest("foto").sha256)
        XCTAssertEqual(c.size, digest("foto").size)
        XCTAssertEqual(c.ssdKeptSize, digest("foto").size)
        XCTAssertNil(c.leavingETag)
        XCTAssertEqual(p.bytes, digest("foto").size)
        XCTAssertEqual(p.stayCount, 0)
    }

    func testCubbit_copyWithKeptCopyCertified_isACandidate_withNormalizedETags() {
        let p = plan(.cubbit)
        XCTAssertEqual(p.candidates.count, 1)
        let c = p.candidates[0]
        XCTAssertEqual(c.archive, .cubbit)
        XCTAssertEqual(c.leavingPath, leaving)
        XCTAssertEqual(c.leavingETag, digest("foto").md5)
        XCTAssertEqual(c.keptETag, digest("foto").md5)
    }

    func testArchivePathsAreTheOnesWrittenOnTheArchive() {
        // Sull'HDD la copia ha maiuscole diverse dall'SSD: il motore deve usare quelle dell'HDD.
        let s = snapshot(hdd: [local("TAKEOUT/Google Photos/a.jpg", "foto"), local("Foto iPhone/0/a.jpg", "foto")])
        let c = plan(.hdd, snapshot: s).candidates[0]
        XCTAssertEqual(c.leavingPath, "TAKEOUT/Google Photos/a.jpg")
        XCTAssertEqual(c.keptPath, "Foto iPhone/0/a.jpg")
        XCTAssertEqual(c.ssdLeavingPath, leaving)
    }

    func testCubbit_onePartUploadETag_isCertified() {
        // `-1` con la formula standard: certificata come nell'inventario (ADR-0015).
        let md5 = digest("foto").md5
        let s = snapshot(s3: [object(leaving, "foto", etag: "\"\(S3ETagMatcher.md5OfMD5Hex(md5)!)-1\""), object(kept, "foto")])
        XCTAssertEqual(plan(.cubbit, snapshot: s).candidates.count, 1)
    }

    // MARK: - Condizione 1: l'inventario

    func testInventoryOlderThanLastBackup_nothingLeaves() {
        let p = plan(.hdd, lastWrite: Date(timeIntervalSince1970: 1_001))
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.block, .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_001)))
        XCTAssertNil(p.runId)
    }

    func testIncompleteInventory_nothingLeaves() {
        let p = plan(.cubbit, snapshot: snapshot(complete: false))
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.block, .inventoryIncomplete)
    }

    func testNoInventory_nothingLeaves() {
        let s = InventorySnapshot()
        XCTAssertEqual(plan(.hdd, snapshot: s).block, .inventoryNeverRun)
    }

    func testUnreadableHistory_nothingLeaves() {
        let h = TrashHistoryReader.Result(entries: [], malformedLines: 0, unreadable: true)
        let p = plan(.hdd, history: h)
        XCTAssertTrue(p.historyUnreadable)
        XCTAssertTrue(p.candidates.isEmpty)
    }

    // MARK: - La storia

    func testKeptPathUnknown_stays() {
        onlyStay(plan(.hdd, history: history([(abs(leaving), nil)])), .keptUnknown)
        let old = TrashHistoryEntry(blockId: "b0", trashedAt: Date(), originalPaths: [abs(leaving)], keptPaths: nil)
        onlyStay(plan(.hdd, history: .init(entries: [old], malformedLines: 0, unreadable: false)), .keptUnknown)
    }

    func testOriginalOutsideTheSSD_stays() {
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD - Enri 1/" + leaving, kept)])), .outsideSSD)
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD/" + leaving, kept)])), .outsideSSD)
    }

    func testDotDotInTheWrittenPath_stays() {
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD - Enri/Takeout/../" + leaving, kept)])), .unsafePath)
        onlyStay(plan(.hdd, history: history([(abs(leaving), "Foto iPhone/../x.jpg")])), .unsafePath)
    }

    func testQuarantine_stays() {
        onlyStay(plan(.hdd, history: history([(abs("_quarantena/2026-10-04/" + leaving), kept)])), .unsafePath)
    }

    func testSameAsKept_comparedWithoutCase_stays() {
        onlyStay(plan(.hdd, history: history([(abs("Foto iPhone/0/a.jpg"), "foto iphone/0/A.JPG")])), .sameAsKept)
    }

    func testRepeatedInHistory_withTheSameKept_countsOnce() {
        let p = plan(.hdd, history: history([(abs(leaving), kept), (abs(leaving), kept)]))
        XCTAssertEqual(p.candidates.count, 1)
        XCTAssertEqual(p.stays, [.repeatedInHistory: 1])
        XCTAssertEqual(p.historyCopies, 2)
    }

    func testSameCopyWithTwoDifferentKept_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/b.jpg", "foto")])
        let p = plan(.hdd, history: history([(abs(leaving), kept), (abs(leaving), "Other/b.jpg")]), snapshot: s)
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.stays, [.conflictingKept: 2])
    }

    func testAlreadyRemovedFromThisArchive_stays() {
        onlyStay(plan(.hdd, alreadyRemoved: [normalizedIndexKey(leaving)]), .alreadyRemoved)
    }

    // MARK: - Condizioni 3 e 4: l'SSD

    func testCopyBackOnTheSSD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(ssd: [local(kept, "foto"), local(leaving, "foto")])), .backOnSSD)
    }

    func testCopyBackOnTheSSD_evenIfUnreadable_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local(leaving, "?", status: .unreadable)])
        onlyStay(plan(.cubbit, snapshot: s), .backOnSSD)
    }

    func testKeptCopyMissingOnTheSSD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(ssd: [])), .keptNotOnSSD)
    }

    func testKeptCopyUnreadableOnTheSSD_stays() {
        onlyStay(plan(.cubbit, snapshot: snapshot(ssd: [local(kept, "?", status: .changedWhileReading)])), .keptNotOnSSD)
    }

    func testKeptCopyTwiceOnTheSSD_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local("foto iphone/0/a.jpg", "foto")])
        onlyStay(plan(.hdd, snapshot: s), .keptNotOnSSD)
    }

    // MARK: - Condizione 2 e 5: l'archivio

    func testCopyNotOnTheArchive_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(kept, "foto")])), .notInArchive)
        onlyStay(plan(.cubbit, snapshot: snapshot(s3: [object(kept, "foto")])), .notInArchive)
    }

    func testKeptCopyNotOnTheArchive_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "foto")])), .keptNotInArchive)
        onlyStay(plan(.cubbit, snapshot: snapshot(s3: [object(leaving, "foto")])), .keptNotInArchive)
    }

    func testTwoPathsThatDifferOnlyByCase_onTheHDD_stay() {
        let s = snapshot(hdd: [local(leaving, "foto"), local(leaving.uppercased(), "foto"), local(kept, "foto")])
        onlyStay(plan(.hdd, snapshot: s), .pathCollision)
    }

    func testTwoCubbitKeysThatBecomeTheSamePath_stay() {
        let s = snapshot(s3: [object(leaving, "foto"), object(kept, "foto"), object(kept.lowercased(), "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .pathCollision)
    }

    func testUnreadableOnTheHDD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "?", status: .unreadable), local(kept, "foto")])),
                 .unreadableInArchive)
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "foto"), local(kept, "?", status: .changedWhileReading)])),
                 .unreadableInArchive)
    }

    func testDifferentContentOnTheHDD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "altra"), local(kept, "foto")])), .contentDiffers)
        // Le due copie sull'HDD uguali fra loro, ma diverse dalla tenuta sull'SSD, CON LA STESSA
        // DIMENSIONE (altrimenti lo direbbe gia' il confronto delle dimensioni: mutante M04).
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "fata"), local(kept, "fata")])), .contentDiffers)
    }

    func testCubbitObjectNotCertifiable_stays() {
        let s = snapshot(s3: [object(leaving, "foto", etag: "\"non-un-etag\""), object(kept, "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .notCertifiable)
    }

    func testCubbitObjectKnownOnlyByItsMD5_stays() {
        // ETag a parte unica che nessun file locale produce: contenuto solo su Cubbit.
        let s = snapshot(s3: [object(leaving, "foto"), object(kept, "foto", etag: "\"\(digest("sconosciuta").md5)\"")])
        onlyStay(plan(.cubbit, snapshot: s), .notCertifiable)
    }

    func testCubbitObjectWithAnotherKnownContent_stays() {
        // La copia su Cubbit ha il contenuto di un'altra foto che c'e' sull'SSD.
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/z.jpg", "zeta")],
                         s3: [object(leaving, "zeta"), object(kept, "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .contentDiffers)
    }

    func testDefence_aCopyThatIsTheKeptCopyOfAnother_neverLeaves() {
        let a = AlignmentCandidate(archive: .hdd, leavingKey: "x", keptKey: "y", leavingPath: "X", keptPath: "Y",
                                   ssdLeavingPath: "X", ssdKeptPath: "Y", ssdKeptSize: 1, size: 1, sha256: "s",
                                   leavingETag: nil, keptETag: nil)
        let b = AlignmentCandidate(archive: .hdd, leavingKey: "y", keptKey: "z", leavingPath: "Y", keptPath: "Z",
                                   ssdLeavingPath: "Y", ssdKeptPath: "Z", ssdKeptSize: 1, size: 1, sha256: "s",
                                   leavingETag: nil, keptETag: nil)
        let r = AlignmentPlanner.dropLeavingThatIsKept([a, b])
        XCTAssertEqual(r.kept.map(\.leavingKey), ["x"])
        XCTAssertEqual(r.dropped.map(\.leavingKey), ["y"])
    }

    // MARK: - Conti, ordine, blocchi

    func testEveryHistoryCopyIsEitherACandidateOrHasAReason() {
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/b.jpg", "b")],
                         hdd: [local(leaving, "foto"), local(kept, "foto"), local("Other/c.jpg", "b"), local("Other/b.jpg", "b")])
        let h = history([(abs(leaving), kept), (abs(leaving), kept), (abs("Other/c.jpg"), "Other/b.jpg"),
                         (abs("Other/d.jpg"), "Other/b.jpg"), (abs("x.jpg"), nil), ("/altrove/y.jpg", kept)])
        let p = plan(.hdd, history: h, snapshot: s)
        XCTAssertEqual(p.candidates.count + p.stayCount, p.historyCopies)
        XCTAssertEqual(p.historyCopies, 6)
        XCTAssertEqual(p.candidates.count, 2)
    }

    func testCandidatesAreOrderedByKeptCopy() {
        let s = snapshot(ssd: [local("B/k.jpg", "b"), local("A/k.jpg", "a")],
                         hdd: [local("B/k.jpg", "b"), local("A/k.jpg", "a"), local("Z/1.jpg", "a"), local("Y/2.jpg", "b")])
        let p = plan(.hdd, history: history([(abs("Y/2.jpg"), "B/k.jpg"), (abs("Z/1.jpg"), "A/k.jpg")]), snapshot: s)
        XCTAssertEqual(p.candidates.map(\.leavingPath), ["Z/1.jpg", "Y/2.jpg"])
    }

    func testBlocks_respectFileAndByteCaps_neverEmpty() {
        func c(_ i: Int, _ size: Int64) -> AlignmentCandidate {
            AlignmentCandidate(archive: .hdd, leavingKey: "\(i)", keptKey: "k", leavingPath: "\(i)", keptPath: "k",
                               ssdLeavingPath: "\(i)", ssdKeptPath: "k", ssdKeptSize: size, size: size, sha256: "s",
                               leavingETag: nil, keptETag: nil)
        }
        let five = (0..<5).map { c($0, 10) }
        XCTAssertEqual(AlignmentRunPlan.blocks(five, fileCap: 2, byteCap: 1_000).map(\.count), [2, 2, 1])
        XCTAssertEqual(AlignmentRunPlan.blocks(five, fileCap: 100, byteCap: 25).map(\.count), [2, 2, 1])
        // Una copia piu' grande del tetto ha un blocco tutto suo.
        XCTAssertEqual(AlignmentRunPlan.blocks([c(0, 5), c(1, 500), c(2, 5)], fileCap: 100, byteCap: 100).map(\.count), [1, 1, 1])
        XCTAssertEqual(AlignmentRunPlan.blocks([]).count, 0)
    }

    func testCubbitVerdict_matchesTheClassifier() {
        // «Una regola sola»: per ogni oggetto Cubbit, il controllo certifica lo stesso contenuto
        // che l'inventario mostra presente su Cubbit.
        let s = InventorySnapshot(ssd: [local("a.jpg", "uno"), local("b.jpg", "due")],
                                  hdd: [local("a.jpg", "uno"), local("c.jpg", "tre")],
                                  s3: [object("a.jpg", "uno"), object("c.jpg", "tre"), object("d.jpg", "solo-cubbit"),
                                       object("e.jpg", "uno", etag: "\"rotto\"")],
                                  states: states())
        let candidates = AlignmentPlanner.localETagCandidates(s)
        let onCubbit = Set(InventoryClassifier.classify(s).items.filter { $0.presentOn.contains(.s3) }.map(\.id))
        for o in s.s3 {
            if case .certified(let sha) = S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: candidates[o.size] ?? []) {
                XCTAssertTrue(onCubbit.contains(sha), o.displayKey)
            }
        }
        XCTAssertEqual(onCubbit.filter { !$0.contains(":") }.count, 2)
    }

    // MARK: - Lettura della storia

    func testHistoryReader_readsEveryLine_andCountsTheBrokenOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trash-history.jsonl")
        let history = try TrashHistory(url: url)
        history.append(blockId: "b1", trashed: [TrashedItem(batchId: "b1", originalDisplayPath: abs(leaving), originalKey: "k",
                                                            trashedPath: "/t", size: 1, hash: "h", trashedAt: Date(), keptPath: kept)])
        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile(); fh.write(Data("non json\n\n".utf8)); try fh.close()
        let r = TrashHistoryReader.read(url: url)
        XCTAssertFalse(r.unreadable)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].keptPaths ?? [], [kept])
        XCTAssertEqual(r.malformedLines, 1)
        let missing = TrashHistoryReader.read(url: dir.appendingPathComponent("non-c-e.jsonl"))
        XCTAssertFalse(missing.unreadable)
        XCTAssertTrue(missing.entries.isEmpty)
    }
}
```

### Task 2 — `AppBackupFotoTests/AlignmentLogTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Il registro del progetto 4 (ROADMAP #47, ADR-0019): in sola aggiunta, una riga per evento,
/// e lo stato che se ne ricava (cosa e' gia' tolto, cosa rimette a posto «Annulla l'ultimo blocco»).
final class AlignmentLogTests: XCTestCase {
    private var tmp: URL!
    private var url: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        url = tmp.appendingPathComponent("alignment-hdd.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func pending(_ id: String, block: String = "b1", archive: AlignmentArchive = .hdd,
                         path: String = "Takeout/a.jpg", at: Double = 100) -> AlignmentLogEntry {
        AlignmentLogEntry(event: .pending, id: id, blockId: block, archive: archive, at: Date(timeIntervalSince1970: at),
                          leavingPath: path, leavingKey: normalizedIndexKey(path), keptPath: "Foto iPhone/0/A.JPG",
                          size: 4, sha256: "sha", etag: archive == .cubbit ? "etag" : nil,
                          originalAbsolutePath: archive == .hdd ? "/Volumes/BackupHDD/" + path : nil)
    }

    private func event(_ e: AlignmentLogEntry.Event, _ id: String, block: String = "b1", archive: AlignmentArchive = .hdd,
                       at: Double = 101, trashed: String? = nil, marker: String? = nil) -> AlignmentLogEntry {
        AlignmentLogEntry(event: e, id: id, blockId: block, archive: archive, at: Date(timeIntervalSince1970: at),
                          trashedPath: trashed, deleteMarkerVersionId: marker)
    }

    func testAppend_thenRead_roundTrips_andTheFileIsPrivate() throws {
        let store = try AlignmentLogStore(url: url)
        let p = pending("1")
        try store.append(p)
        try store.append(event(.removed, "1", trashed: "/Volumes/BackupHDD/.Trashes/501/a.jpg"))
        let r = store.read()
        XCTAssertFalse(r.unreadable)
        XCTAssertEqual(r.malformedLines, 0)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.entries[0], p)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testAppend_neverRewritesEarlierLines() throws {
        try AlignmentLogStore(url: url).append(pending("1"))
        let before = try Data(contentsOf: url)
        try AlignmentLogStore(url: url).append(pending("2"))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(before.count), before)
        XCTAssertEqual(try AlignmentLogStore(url: url).read().entries.map(\.id), ["1", "2"])
    }

    func testState_pendingPlusRemoved_isARemoval_withEveryField() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), event(.removed, "1", trashed: "/T/a.jpg")])
        XCTAssertEqual(s.removals.count, 1)
        let r = s.removals[0]
        XCTAssertEqual(r.leavingPath, "Takeout/a.jpg")
        XCTAssertEqual(r.leavingKey, "takeout/a.jpg")
        XCTAssertEqual(r.trashedPath, "/T/a.jpg")
        XCTAssertEqual(r.originalAbsolutePath, "/Volumes/BackupHDD/Takeout/a.jpg")
        XCTAssertEqual(r.removedAt, Date(timeIntervalSince1970: 101))
        XCTAssertNil(r.restoredAt)
        XCTAssertTrue(s.unfinished.isEmpty)
        XCTAssertEqual(s.removedKeys, ["takeout/a.jpg"])
    }

    func testState_pendingWithoutOutcome_isUnfinished_notARemoval() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), pending("2", path: "b.jpg"), event(.failed, "2")])
        XCTAssertTrue(s.removals.isEmpty)
        XCTAssertEqual(s.unfinished.map(\.id), ["1"])
        XCTAssertTrue(s.removedKeys.isEmpty)
    }

    func testState_restoredCopiesAreNotRemovedAnymore() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), event(.removed, "1"), event(.restored, "1", at: 200)])
        XCTAssertEqual(s.removals[0].restoredAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(s.removedKeys.isEmpty)
        XCTAssertTrue(s.lastBlockToRestore.isEmpty)
        XCTAssertNil(s.lastBlockSummary)
    }

    func testState_onlyTheRequestedArchive() {
        let entries = [pending("1", archive: .cubbit), event(.removed, "1", archive: .cubbit, marker: "v1"), pending("2"), event(.removed, "2")]
        XCTAssertEqual(AlignmentLogState(archive: .cubbit, entries: entries).removals.map(\.id), ["1"])
        XCTAssertEqual(AlignmentLogState(archive: .cubbit, entries: entries).removals.first?.deleteMarkerVersionId, "v1")
        XCTAssertEqual(AlignmentLogState(archive: .hdd, entries: entries).removals.map(\.id), ["2"])
    }

    func testLastBlock_isTheBlockOfTheLastRemoval_withoutTheRestoredOnes() {
        let entries = [pending("1", block: "A"), event(.removed, "1", block: "A", at: 101),
                       pending("2", block: "B", path: "b.jpg"), event(.removed, "2", block: "B", at: 102),
                       pending("3", block: "B", path: "c.jpg"), event(.removed, "3", block: "B", at: 103),
                       event(.restored, "2", block: "B", at: 300)]
        let s = AlignmentLogState(archive: .hdd, entries: entries)
        XCTAssertEqual(s.lastBlockToRestore.map(\.id), ["3"])
        XCTAssertEqual(s.lastBlockSummary, RestorableBatchSummary(pendingCount: 1, batchCount: 2, trashedAt: Date(timeIntervalSince1970: 103)))
        // Il blocco A non torna mai «ultimo» per aver rimesso a posto il B (un livello solo).
        let allBack = AlignmentLogState(archive: .hdd, entries: entries + [event(.restored, "3", block: "B", at: 301)])
        XCTAssertTrue(allBack.lastBlockToRestore.isEmpty)
        XCTAssertNil(allBack.lastBlockSummary)
    }

    func testBrokenLines_areCounted_andTheOthersAreRead() throws {
        let store = try AlignmentLogStore(url: url)
        try store.append(pending("1"))
        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write(Data("{\"event\":\"removed\"}\nnon json\n".utf8)); try fh.close()
        try store.append(event(.removed, "1"))
        let r = store.read()
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.malformedLines, 2)
        XCTAssertEqual(store.state(for: .hdd)?.malformedLines, 2)
        XCTAssertEqual(store.state(for: .hdd)?.removals.count, 1)
    }

    func testOldOrPartialLine_decodesWithTheOptionalFieldsMissing() throws {
        let json = #"{"event":"failed","id":"9","blockId":"b","archive":"cubbit","at":0}"#
        let e = try JSONDecoder().decode(AlignmentLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.event, .failed)
        XCTAssertNil(e.leavingPath)
        XCTAssertNil(e.detail)
    }

    func testMissingFile_isAnEmptyLog_unreadableFileIsNot() throws {
        let store = try AlignmentLogStore(url: url)
        XCTAssertEqual(store.state(for: .hdd)?.removals.count, 0)
        try store.append(pending("1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertTrue(store.read().unreadable)
        XCTAssertNil(store.state(for: .hdd))
    }

    func testAppendFails_loudly_whenTheFileCannotBeWritten() throws {
        let store = try AlignmentLogStore(url: url)
        try store.append(pending("1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.append(pending("2")))
    }

    func testLocationOutsideTheAllowList_isRefused() {
        XCTAssertThrowsError(try AlignmentLogStore(url: URL(fileURLWithPath: "/Volumes/BackupHDD/alignment-hdd.jsonl")))
    }

    func testConcurrentAppends_loseNoLine() throws {
        let store = try AlignmentLogStore(url: url)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<50 { try? store.append(self.pending("\(t)-\(i)", path: "f\(t)-\(i).jpg")) }
        }
        let r = store.read()
        XCTAssertEqual(r.entries.count, 400)
        XCTAssertEqual(r.malformedLines, 0)
    }
}
```

### Task 3 — `AppBackupFotoTests/S3AlignmentRequestsTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Le risposte di Cubbit che il progetto 4 legge (ROADMAP #47, ADR-0019): stato delle versioni,
/// regole di scadenza, esito di un DELETE, elenco delle versioni; e la regola che decide se
/// Cubbit e' pronto per togliere copie. Esempi nella forma della documentazione S3 e di quella
/// provata su Cubbit il 2026-10-10 (regola «vecchio stile» con `<Prefix>` vuoto).
final class S3AlignmentRequestsTests: XCTestCase {
    private typealias Rule = S3Syncer.LifecycleRule

    // MARK: - Versioni

    func testVersioning_enabledSuspendedNeverAndUnknown() {
        let ns = "xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration \(ns)><Status>Enabled</Status></VersioningConfiguration>"), .enabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>"), .suspended)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration \(ns)/>"), .neverEnabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration></VersioningConfiguration>"), .neverEnabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration><Status>Forse</Status></VersioningConfiguration>"), .unrecognized("Forse"))
    }

    // MARK: - Regole di scadenza

    private func lifecycle(_ rules: String) -> String { "<LifecycleConfiguration>\(rules)</LifecycleConfiguration>" }

    func testLifecycle_oldStyleWholeBucketRule_asAcceptedByCubbit() throws {
        let xml = lifecycle("<Rule><ID>r1</ID><Prefix></Prefix><Status>Enabled</Status><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays></NoncurrentVersionExpiration></Rule>")
        XCTAssertEqual(try S3Syncer.parseLifecycle(statusCode: 200, body: xml),
                       [Rule(id: "r1", enabled: true, wholeBucket: true, noncurrentDays: 30, expiresCurrentObjects: false)])
    }

    func testLifecycle_prefixAndFilterForms() throws {
        func whole(_ body: String) throws -> Bool { try S3Syncer.parseLifecycle(statusCode: 200, body: lifecycle("<Rule><Status>Enabled</Status>\(body)</Rule>"))[0].wholeBucket }
        XCTAssertTrue(try whole("<Prefix/>"))
        XCTAssertTrue(try whole(""))
        XCTAssertTrue(try whole("<Filter><Prefix></Prefix></Filter>"))
        XCTAssertTrue(try whole("<Filter/>"))
        XCTAssertFalse(try whole("<Prefix>Takeout/</Prefix>"))
        XCTAssertFalse(try whole("<Filter><Prefix>Takeout/</Prefix></Filter>"))
        XCTAssertFalse(try whole("<Filter><Tag><Key>a</Key><Value>b</Value></Tag></Filter>"))
        XCTAssertFalse(try whole("<Filter><And><Prefix></Prefix><Tag><Key>a</Key><Value>b</Value></Tag></And></Filter>"))
    }

    func testLifecycle_disabledRule_andExpirationForms() throws {
        let rules = try S3Syncer.parseLifecycle(statusCode: 200, body: lifecycle(
            "<Rule><ID>a</ID><Status>Disabled</Status><Prefix></Prefix><NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays></NoncurrentVersionExpiration></Rule>"
            + "<Rule><ID>b</ID><Status>Enabled</Status><Prefix></Prefix><Expiration><Days>30</Days></Expiration></Rule>"
            + "<Rule><ID>c</ID><Status>Enabled</Status><Prefix></Prefix><Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule>"))
        XCTAssertEqual(rules.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(rules[0].enabled)
        XCTAssertEqual(rules[0].noncurrentDays, 1)
        XCTAssertTrue(rules[1].expiresCurrentObjects)
        XCTAssertFalse(rules[2].expiresCurrentObjects)
    }

    func testLifecycle_noConfigurationIsNoRules_otherErrorsThrow() {
        XCTAssertEqual(try S3Syncer.parseLifecycle(statusCode: 404, body: "<Error><Code>NoSuchLifecycleConfiguration</Code></Error>"), [])
        XCTAssertThrowsError(try S3Syncer.parseLifecycle(statusCode: 403, body: "<Error/>"))
        XCTAssertThrowsError(try S3Syncer.parseLifecycle(statusCode: 500, body: ""))
    }

    // MARK: - Cubbit pronto?

    private func rule(_ days: Int?, whole: Bool = true, enabled: Bool = true, expires: Bool = false) -> Rule {
        Rule(id: "r", enabled: enabled, wholeBucket: whole, noncurrentDays: days, expiresCurrentObjects: expires)
    }

    func testSafety_readyOnlyWithVersionsAndThirtyDays() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30)]), .ready(days: 30))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(60)]), .ready(days: 60))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(1, enabled: false), rule(30)]), .ready(days: 30))
    }

    func testSafety_versionsNotEnabled() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .neverEnabled, rules: [rule(30)]), .versioningNotEnabled(.neverEnabled))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .suspended, rules: [rule(30)]), .versioningNotEnabled(.suspended))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .unrecognized("x"), rules: [rule(30)]), .versioningNotEnabled(.unrecognized("x")))
    }

    func testSafety_missingOrShortOrDangerousRules() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: []), .noExpiryRule)
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30, whole: false)]), .noExpiryRule)
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(7)]), .expiryTooShort(days: 7))
        // Anche una regola per una sola cartella, se piu' corta, accorcia l'annullamento li'.
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30), rule(1, whole: false)]), .expiryTooShort(days: 1))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30), rule(nil, expires: true)]), .expiresCurrentPhotos)
    }

    // MARK: - DELETE

    func testDelete_markerAndVersionFromTheHeaders() throws {
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "true", versionId: "v-123", key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: true, versionId: "v-123"))
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "True ", versionId: " v ", key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: true, versionId: "v"))
    }

    func testDelete_withoutMarker_isReportedAsSuch() throws {
        // Versioni spente: nessun segno, nessuna versione. Il motore deve fermarsi.
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: nil, versionId: nil, key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: false, versionId: nil))
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "true", versionId: "", key: "a.jpg").versionId, nil)
    }

    func testDelete_errorsThrow() {
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: 403, deleteMarker: nil, versionId: nil, key: "a.jpg"))
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: 404, deleteMarker: nil, versionId: nil, key: "a.jpg"))
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: -1, deleteMarker: nil, versionId: nil, key: "a.jpg"))
    }

    // MARK: - Elenco delle versioni

    func testVersionsPage_versionsAndMarkersInDocumentOrder() {
        let xml = """
        <ListVersionsResult><Name>b</Name><Prefix>a.jpg</Prefix><IsTruncated>false</IsTruncated>
        <DeleteMarker><Key>a.jpg</Key><VersionId>m1</VersionId><IsLatest>true</IsLatest></DeleteMarker>
        <Version><Key>a.jpg</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><ETag>&quot;abc&quot;</ETag><Size>12</Size></Version>
        <Version><Key>a.jpg.json</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><ETag>"d"</ETag><Size>3</Size></Version>
        </ListVersionsResult>
        """
        let p = S3Syncer.parseVersionsPage(xml)
        XCTAssertEqual(p.entries, [
            .init(key: "a.jpg", versionId: "m1", isLatest: true, isDeleteMarker: true, etag: nil, size: nil),
            .init(key: "a.jpg", versionId: "v1", isLatest: false, isDeleteMarker: false, etag: "\"abc\"", size: 12),
            .init(key: "a.jpg.json", versionId: "v2", isLatest: true, isDeleteMarker: false, etag: "\"d\"", size: 3)])
        XCTAssertFalse(p.isTruncated)
        XCTAssertEqual(p.malformedEntries, 0)
    }

    func testVersionsPage_truncatedWithMarkers_andBrokenEntriesCounted() {
        let xml = "<ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>a.jpg</NextKeyMarker><NextVersionIdMarker>v9</NextVersionIdMarker>"
            + "<Version><Key>a.jpg</Key><IsLatest>true</IsLatest></Version></ListVersionsResult>"
        let p = S3Syncer.parseVersionsPage(xml)
        XCTAssertTrue(p.isTruncated)
        XCTAssertEqual(p.nextKeyMarker, "a.jpg")
        XCTAssertEqual(p.nextVersionIdMarker, "v9")
        XCTAssertEqual(p.malformedEntries, 1)
        XCTAssertTrue(p.entries.isEmpty)
    }
}
```

### Task 3 — `AppBackupFotoTests/AlignmentDeleteGuardTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Il DELETE su Cubbit e' nuovo nel progetto (ADR-0019) e deve restare chiuso dove sta. Questi
/// test leggono il sorgente di `ContentView.swift` e pretendono che le richieste DELETE siano
/// esattamente quelle previste, e che l'unico DELETE con versione sia quello che toglie un segno
/// di cancellazione. Se ne aggiungi un'altra, questo test fallisce apposta: prima va scritto
/// perche' in ADR-0019 e nella checklist «IF il codice fa chiamate S3» di `Docs/CLAUDE.md`.
final class AlignmentDeleteGuardTests: XCTestCase {
    /// Il sorgente dell'app: accanto alla cartella dei test nel repository
    /// (`AppBackupFoto/ContentView.swift`), o in `src/` nella verifica veloce fuori da Xcode.
    private func source(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["AppBackupFoto/ContentView.swift", "src/ContentView.swift"] {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        XCTFail("Non trovo ContentView.swift accanto a \(root.path): il controllo sul DELETE non puo' girare.")
        return ""
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testOnlyThreeRequestsUseDELETE() throws {
        // AbortMultipartUpload (non tocca dati scritti), il DELETE senza versione del progetto 4
        // e la rimozione di un segno di cancellazione registrato. Nient'altro.
        XCTAssertEqual(count("httpMethod = \"DELETE\"", in: try source()), 3)
    }

    func testTheOnlyRequestWithAVersionId_isTheDeleteMarkerRemoval() throws {
        let src = try source()
        XCTAssertEqual(count("\"?versionId=\"", in: src), 1)
        guard let fn = src.range(of: "func removeDeleteMarkerForAlignment("),
              let use = src.range(of: "\"?versionId=\""), fn.upperBound <= use.lowerBound else {
            return XCTFail("il ?versionId= deve stare dentro removeDeleteMarkerForAlignment")
        }
        let body = src[fn.upperBound..<use.lowerBound]
        XCTAssertFalse(body.contains("\n    func "), "il ?versionId= deve stare dentro removeDeleteMarkerForAlignment")
    }

    func testTheTwoAlignmentDeletesAreCalledOnlyByTheCubbitAdapter() throws {
        let src = try source()
        XCTAssertEqual(count("deleteObjectForAlignment(", in: src), 2, "definizione + S3AlignmentCloud")
        XCTAssertEqual(count("removeDeleteMarkerForAlignment(", in: src), 2, "definizione + S3AlignmentCloud")
    }
}
```

### Task 4 — `AppBackupFotoTests/AlignmentEngineHDDTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Il motore del progetto 4 sull'HDD (ROADMAP #47, ADR-0019), su cartelle temporanee al posto di
/// SSD e HDD e un Cestino finto (una cartella sull'«HDD», con `rename`: un `trashItem` vero
/// manderebbe i file di prova nel Cestino del Mac). Per ogni condizione del ricontrollo dal vivo
/// c'e' un test che la fa fallire da sola e pretende che niente si muova.
final class AlignmentEngineHDDTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var trash: URL!
    private var store: AlignmentLogStore!
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentEngineHDDTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        trash = hdd.appendingPathComponent(".Trashes/501")
        for d in [ssd!, hdd!, trash!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment-hdd.jsonl"))
        try put(ssd, kept, content)
        try put(hdd, leaving, content)
        try put(hdd, kept, content)
    }

    override func tearDownWithError() throws {
        if let e = FileManager.default.enumerator(atPath: tmp.path) {
            while let rel = e.nextObject() as? String { _ = chflags(tmp.appendingPathComponent(rel).path, 0) }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ root: URL, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ leavingPath: String? = nil, kept keptPath: String? = nil, archive: AlignmentArchive = .hdd) -> AlignmentCandidate {
        let l = leavingPath ?? leaving, k = keptPath ?? kept, d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(l), keptKey: normalizedIndexKey(k),
                                  leavingPath: l, keptPath: k, ssdLeavingPath: l, ssdKeptPath: k, ssdKeptSize: d.size,
                                  size: d.size, sha256: d.sha256, leavingETag: nil, keptETag: nil)
    }

    /// Il Cestino finto: `rename` nella cartella `.Trashes/501` dell'«HDD», con un nome unico.
    private nonisolated static func fakeTrash(into dir: URL) -> @Sendable (URL) throws -> URL? {
        return { url in
            let dst = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dst)
            return dst
        }
    }

    private func engine(hddRoot: URL?? = nil,
                        log: (@Sendable (AlignmentLogEntry) throws -> Void)? = nil,
                        hashFunction: (@Sendable (URL) -> MeasuredHash?)? = nil,
                        trashFunction: (@Sendable (URL) throws -> URL?)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil,
                        fileFlags: (@Sendable (URL) -> UInt32?)? = nil) -> ArchiveAligner {
        let s = store!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: hddRoot ?? hdd, cloud: nil,
                              log: log ?? { try s.append($0) },
                              hashFunction: hashFunction ?? { sha256Measured(of: $0) },
                              trashFunction: trashFunction ?? Self.fakeTrash(into: trash),
                              volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) },
                              fileFlags: fileFlags ?? { url in var st = stat(); return lstat(url.path, &st) == 0 ? st.st_flags : nil })
    }

    private func run(_ e: ArchiveAligner, _ block: [AlignmentCandidate], cancelAfter: Int? = nil) async -> AlignmentBlockOutcome {
        let counter = AlignmentTestCounter()
        return await e.runHDDBlock(block, blockId: "b1",
                                   isCancelled: { cancelAfter.map { counter.value >= $0 } ?? false },
                                   onProgress: { counter.set($0) })
    }

    private func assertNothingMoved(_ o: AlignmentBlockOutcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(o.removed.isEmpty, file: file, line: line)
        XCTAssertTrue(exists(hdd, leaving), "la copia doveva restare sull'HDD", file: file, line: line)
        XCTAssertTrue(exists(hdd, kept), file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [], file: file, line: line)
    }

    // MARK: - Il caso buono

    func testCopyGoesToTheHDDTrash_keptCopyAndSSDUntouched_logWritten() async throws {
        let o = await run(engine(), [candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.removed, [candidate()])
        XCTAssertEqual(o.removedBytes, digest(content).size)
        XCTAssertFalse(exists(hdd, leaving))
        XCTAssertTrue(exists(hdd, kept))
        XCTAssertTrue(exists(ssd, kept))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(trashed.count, 1)
        let entries = store.read().entries
        XCTAssertEqual(entries.map(\.event), [.pending, .removed])
        XCTAssertEqual(entries[0].id, entries[1].id)
        XCTAssertEqual(entries[0].originalAbsolutePath, hdd.appendingPathComponent(leaving).path)
        XCTAssertEqual(entries[0].keptPath, kept)
        XCTAssertEqual(entries[0].sha256, digest(content).sha256)
        XCTAssertEqual(entries[1].trashedPath, trash.appendingPathComponent(trashed[0]).path)
        XCTAssertEqual(store.state(for: .hdd)?.removedKeys, [normalizedIndexKey(leaving)])
    }

    func testThePendingLineIsWrittenBeforeTheCopyIsTouched() async {
        let s = store!
        let seen = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in
            seen.set(s.read().entries.filter { $0.event == .pending }.count)
            return try base(url)
        }), [candidate()])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(seen.value, 1)
    }

    func testProgressIsReportedForEveryCopy() async throws {
        try put(hdd, "Other/b.jpg", content)
        let counter = AlignmentTestCounter()
        _ = await engine().runHDDBlock([candidate(), candidate("Other/b.jpg")], blockId: "b", onProgress: { counter.set($0) })
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - L'SSD dal vivo (condizioni 3 e 4)

    func testCopyBackOnTheSSD_stays() async throws {
        try put(ssd, leaving, content)
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.backOnSSD: 1])
        assertNothingMoved(o)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testKeptCopyGoneOrChangedOnTheSSD_stays() async throws {
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(kept))
        var o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        assertNothingMoved(o)
        try put(ssd, kept, content + " e un po' di piu'")
        o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        assertNothingMoved(o)
    }

    // MARK: - L'HDD dal vivo (condizioni 2 e 6)

    func testCopyAlreadyGoneFromTheHDD_isSkipped_notCountedAsRemoved() async throws {
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(leaving))
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.goneFromArchive: 1])
        XCTAssertTrue(o.removed.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testKeptCopyGoneFromTheHDD_stays() async throws {
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(kept))
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptMissingInArchive: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testChangedContent_onEitherCopy_stays() async throws {
        try put(hdd, leaving, "un'altra foto")
        var o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        assertNothingMoved(o)
        try put(hdd, leaving, content)
        try put(hdd, kept, "tenuta cambiata")
        o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testBothCopiesChangedTheSameWay_stillStays() async throws {
        // Uguali fra loro ma diverse dall'inventario: non e' la foto che l'utente ha confermato.
        try put(hdd, leaving, "entrambe cambiate")
        try put(hdd, kept, "entrambe cambiate")
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testUnreadableCopy_stays() async {
        let o = await run(engine(hashFunction: { $0.path.hasSuffix("A.JPG") ? nil : sha256Measured(of: $0) }), [candidate()])
        XCTAssertEqual(o.skipped, [.unreadable: 1])
        assertNothingMoved(o)
    }

    func testRealLockedFile_isSkipped_andTheRunGoesOn() async throws {
        try put(hdd, "Other/b.jpg", content)
        XCTAssertEqual(chflags(hdd.appendingPathComponent(leaving).path, UInt32(UF_IMMUTABLE)), 0)
        let o = await run(engine(), [candidate(), candidate("Other/b.jpg")])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.skipped, [.locked: 1])
        XCTAssertEqual(o.removed.map(\.leavingPath), ["Other/b.jpg"])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testLockedOnlyDiscoveredWhenTrashFails_isSkipped() async {
        let calls = AlignmentTestCounter()
        let o = await run(engine(trashFunction: { _ in throw CocoaError(.fileWriteNoPermission) },
                                 fileFlags: { _ in calls.increment() > 1 ? UInt32(UF_IMMUTABLE) : 0 }), [candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.skipped, [.locked: 1])
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testUnsafePaths_symlinks_andNonMedia_stay() async throws {
        try put(hdd, "Takeout/note.json", content)
        try FileManager.default.createSymbolicLink(at: hdd.appendingPathComponent("Takeout/link.jpg"),
                                                   withDestinationURL: hdd.appendingPathComponent(kept))
        let o = await run(engine(), [candidate("../fuori.jpg"), candidate("Takeout/note.json"), candidate("Takeout/link.jpg"),
                                     candidate(archive: .cubbit)])
        XCTAssertEqual(o.skipped, [.unsafePath: 4])
        assertNothingMoved(o)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Takeout/link.jpg").path))
    }

    // MARK: - I guasti che fermano la corsa

    func testHDDMissingAtStart_nothingIsTouched() async {
        let o = await run(engine(hddRoot: .some(tmp.appendingPathComponent("non-c-e"))), [candidate()])
        XCTAssertEqual(o.stop, .volumeMissing(.hdd))
        assertNothingMoved(o)
        let none = await run(engine(hddRoot: .some(nil)), [candidate()])
        XCTAssertEqual(none.stop, .volumeMissing(.hdd))
    }

    func testSSDMissingAtStart_nothingIsTouched() async {
        let ssdPath = ssd.path
        let o = await run(engine(volumeIdentity: { $0.path == ssdPath ? nil : deviceIdentifier(of: $0) }), [candidate()])
        XCTAssertEqual(o.stop, .volumeMissing(.ssd))
        assertNothingMoved(o)
    }

    func testHDDVanishingMidBlock_stopsAndKeepsTheHonestCount() async throws {
        try put(hdd, "Other/b.jpg", content)
        let hddPath = hdd.path
        let trashed = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        // Dopo il primo spostamento la radice dell'HDD risponde con un altro disco.
        let o = await run(engine(trashFunction: { url in trashed.increment(); return try base(url) },
                                 volumeIdentity: { url in
                                     url.path == hddPath && trashed.value > 0 ? 999 : deviceIdentifier(of: url)
                                 }), [candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(o.stop, .volumeVanished(.hdd))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }

    func testSSDVanishingMidBlock_stops() async throws {
        try put(hdd, "Other/b.jpg", content)
        let ssdPath = ssd.path
        let trashed = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in trashed.increment(); return try base(url) },
                                 volumeIdentity: { url in
                                     url.path == ssdPath && trashed.value > 0 ? 999 : deviceIdentifier(of: url)
                                 }), [candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(o.stop, .volumeVanished(.ssd))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }

    func testLogNotWritable_nothingIsTouched() async {
        struct Broken: Error {}
        let o = await run(engine(log: { _ in throw Broken() }), [candidate()])
        guard case .logNotWritten = o.stop else { return XCTFail("doveva fermarsi sul registro: \(String(describing: o.stop))") }
        assertNothingMoved(o)
    }

    func testTrashFailing_stopsTheRun_andTheCopyStays() async throws {
        try put(hdd, "Other/b.jpg", content)
        let o = await run(engine(trashFunction: { _ in throw CocoaError(.fileWriteUnknown) }), [candidate(), candidate("Other/b.jpg")])
        guard case .trashFailed(let path, _) = o.stop else { return XCTFail("doveva fermarsi: \(String(describing: o.stop))") }
        XCTAssertEqual(path, leaving)
        XCTAssertTrue(exists(hdd, leaving))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"), "dopo un guasto non si prova la copia successiva")
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testKeptCopyVanishingRightAfter_stops_withTheRemovedCopyLogged() async throws {
        let keptURL = hdd.appendingPathComponent(kept)
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in
            let r = try base(url)
            try FileManager.default.removeItem(at: keptURL)
            return r
        }), [candidate()])
        XCTAssertEqual(o.stop, .keptVanished(path: kept))
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 1, "«Annulla» deve poterla rimettere")
    }

    func testInterrupt_stopsBetweenCopies() async throws {
        try put(hdd, "Other/b.jpg", content)
        let o = await run(engine(), [candidate(), candidate("Other/b.jpg")], cancelAfter: 1)
        XCTAssertEqual(o.stop, .interrupted)
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }
}

/// Un contatore condiviso fra le closure `@Sendable` dei test.
nonisolated final class AlignmentTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func set(_ v: Int) { lock.withLock { n = v } }
    @discardableResult func increment() -> Int { lock.withLock { n += 1; return n } }
}
```

### Task 5 — `AppBackupFotoTests/AlignmentEngineCubbitTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Un Cubbit finto con le versioni: ogni chiave ha la sua storia (la piu' recente in fondo), un
/// DELETE senza versione aggiunge un segno di cancellazione se le versioni sono accese e cancella
/// tutto se sono spente; togliere una versione la toglie QUALUNQUE essa sia — anche una versione
/// di dati: e' il motore che non deve mai chiederlo, e i test lo verificano.
nonisolated final class FakeAlignmentCloud: AlignmentCloud, @unchecked Sendable {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "rete finta giu'" } }
    struct Version { let id: String; let data: Data? }   // `data == nil`: segno di cancellazione

    private let lock = NSLock()
    private var store: [String: [Version]] = [:]
    private var next = 0
    private var _versioning: S3Syncer.BucketVersioning = .enabled
    private var _rules = [S3Syncer.LifecycleRule(id: "r1", enabled: true, wholeBucket: true, noncurrentDays: 30, expiresCurrentObjects: false)]
    private var _deletes: [String] = []
    private var _markerRemovals: [(key: String, versionId: String)] = []
    var failVersioning = false, failHead = false, failDelete = false, failVersions = false, failRemoveMarker = false
    /// Cubbit che dice «versioni accese» ma cancella senza segno.
    var deleteWithoutMarker = false

    static func md5(_ d: Data) -> String { var h = ContentHasher(); h.update(d); return h.finalize().md5 }

    var versioningState: S3Syncer.BucketVersioning {
        get { lock.withLock { _versioning } }
        set { lock.withLock { _versioning = newValue } }
    }
    var rules: [S3Syncer.LifecycleRule] {
        get { lock.withLock { _rules } }
        set { lock.withLock { _rules = newValue } }
    }
    var deletes: [String] { lock.withLock { _deletes } }
    var markerRemovals: [(key: String, versionId: String)] { lock.withLock { _markerRemovals } }

    func put(_ key: String, _ text: String) {
        lock.withLock { next += 1; store[key, default: []].append(Version(id: "v\(next)", data: Data(text.utf8))) }
    }
    func current(_ key: String) -> String? {
        lock.withLock { store[key]?.last?.data.map { String(decoding: $0, as: UTF8.self) } }
    }
    func versionCount(_ key: String) -> Int { lock.withLock { store[key]?.count ?? 0 } }
    func dataVersionIds(_ key: String) -> [String] { lock.withLock { (store[key] ?? []).filter { $0.data != nil }.map(\.id) } }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try lock.withLock {
            if failHead { throw Failure() }
            guard let d = store[key]?.last?.data else { return nil }
            return S3Syncer.S3ObjectHead(size: Int64(d.count), etag: "\"\(Self.md5(d))\"")
        }
    }
    func versioning() async throws -> S3Syncer.BucketVersioning {
        try lock.withLock { if failVersioning { throw Failure() }; return _versioning }
    }
    func lifecycleRules() async throws -> [S3Syncer.LifecycleRule] { lock.withLock { _rules } }
    func delete(key: String) async throws -> S3Syncer.DeleteResult {
        try lock.withLock {
            if failDelete { throw Failure() }
            _deletes.append(key)
            if _versioning == .enabled && !deleteWithoutMarker {
                next += 1
                let id = "m\(next)"
                store[key, default: []].append(Version(id: id, data: nil))
                return S3Syncer.DeleteResult(isDeleteMarker: true, versionId: id)
            }
            store[key] = nil
            return S3Syncer.DeleteResult(isDeleteMarker: false, versionId: nil)
        }
    }
    func versions(key: String) async throws -> [S3Syncer.VersionEntry] {
        try lock.withLock {
            if failVersions { throw Failure() }
            let list = store[key] ?? []
            return list.enumerated().map { i, v in
                S3Syncer.VersionEntry(key: key, versionId: v.id, isLatest: i == list.count - 1, isDeleteMarker: v.data == nil,
                                      etag: v.data.map { "\"\(Self.md5($0))\"" }, size: v.data.map { Int64($0.count) })
            }
        }
    }
    func removeDeleteMarker(key: String, versionId: String) async throws -> S3Syncer.DeleteResult {
        try lock.withLock {
            if failRemoveMarker { throw Failure() }
            _markerRemovals.append((key, versionId))
            guard let i = store[key]?.firstIndex(where: { $0.id == versionId }) else {
                return S3Syncer.DeleteResult(isDeleteMarker: false, versionId: versionId)
            }
            let wasMarker = store[key]![i].data == nil
            store[key]!.remove(at: i)
            return S3Syncer.DeleteResult(isDeleteMarker: wasMarker, versionId: versionId)
        }
    }
}

/// Il motore del progetto 4 su Cubbit (ROADMAP #47, ADR-0019), con l'SSD in una cartella
/// temporanea e un Cubbit finto con le versioni.
final class AlignmentEngineCubbitTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var store: AlignmentLogStore!
    private var cloud: FakeAlignmentCloud!
    private let leaving = "Takeout/Google Photos/IMG_2906 (1).JPG"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentEngineCubbitTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: ssd, withIntermediateDirectories: true)
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment-cubbit.jsonl"))
        cloud = FakeAlignmentCloud()
        try put(ssd, kept, content)
        cloud.put(leaving, content)
        cloud.put(kept, content)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ l: String? = nil, archive: AlignmentArchive = .cubbit, leavingETag: String?? = nil) -> AlignmentCandidate {
        let lp = l ?? leaving, d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(lp), keptKey: normalizedIndexKey(kept),
                                  leavingPath: lp, keptPath: kept, ssdLeavingPath: lp, ssdKeptPath: kept, ssdKeptSize: d.size,
                                  size: d.size, sha256: d.sha256, leavingETag: leavingETag ?? d.md5, keptETag: d.md5)
    }

    private func engine(log: (@Sendable (AlignmentLogEntry) throws -> Void)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil) -> ArchiveAligner {
        let s = store!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: nil, cloud: cloud, log: log ?? { try s.append($0) },
                              volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) })
    }

    private func run(_ block: [AlignmentCandidate], engine e: ArchiveAligner? = nil, cancelAfter: Int? = nil) async -> AlignmentBlockOutcome {
        let counter = AlignmentTestCounter()
        return await (e ?? engine()).runCubbitBlock(block, blockId: "b1",
                                                    isCancelled: { cancelAfter.map { counter.value >= $0 } ?? false },
                                                    onProgress: { counter.set($0) })
    }

    // MARK: - Il caso buono

    func testDeleteWithoutVersion_leavesADeleteMarker_andTheVersionStays() async {
        let o = await run([candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(cloud.deletes, [leaving])
        XCTAssertNil(cloud.current(leaving), "la copia non si vede piu'")
        XCTAssertEqual(cloud.dataVersionIds(leaving).count, 1, "la versione della foto resta")
        XCTAssertEqual(cloud.current(kept), content)
        let entries = store.read().entries
        XCTAssertEqual(entries.map(\.event), [.pending, .removed])
        XCTAssertEqual(entries[0].etag, digest(content).md5)
        XCTAssertEqual(entries[1].deleteMarkerVersionId, "m3")
        XCTAssertNil(entries[0].originalAbsolutePath)
    }

    // MARK: - Condizione 7: le versioni, prima di ogni blocco

    func testVersionsNotEnabled_theBlockDoesNotStart() async {
        cloud.versioningState = .neverEnabled
        let o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.versioningNotEnabled(.neverEnabled)))
        XCTAssertTrue(cloud.deletes.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
        cloud.versioningState = .suspended
        let s = await run([candidate()])
        XCTAssertEqual(s.stop, .cubbitNotReady(.versioningNotEnabled(.suspended)))
    }

    func testMissingOrShortExpiryRule_theBlockDoesNotStart() async {
        cloud.rules = []
        var o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.noExpiryRule))
        cloud.rules = [.init(id: "r", enabled: true, wholeBucket: true, noncurrentDays: 3, expiresCurrentObjects: false)]
        o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.expiryTooShort(days: 3)))
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testVersionsAreReadAgainBeforeEveryBlock() async {
        let e = engine()
        let first = await run([candidate()], engine: e)
        XCTAssertEqual(first.removed.count, 1)
        cloud.put("Other/b.jpg", content)
        cloud.versioningState = .suspended
        let second = await run([candidate("Other/b.jpg")], engine: e)
        XCTAssertEqual(second.stop, .cubbitNotReady(.versioningNotEnabled(.suspended)))
        XCTAssertEqual(cloud.current("Other/b.jpg"), content)
    }

    func testVersionsUnreadable_theBlockDoesNotStart() async {
        cloud.failVersioning = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    // MARK: - Il ricontrollo dal vivo

    func testCopyBackOnTheSSD_orKeptCopyGoneFromTheSSD_stays() async throws {
        try put(ssd, leaving, content)
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.backOnSSD: 1])
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(leaving))
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(kept))
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testKeptCopyMissingOrChangedOnCubbit_stays() async {
        let k = FakeAlignmentCloud(); k.put(leaving, content)
        cloud = k
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.keptMissingInArchive: 1])
        k.put(kept, "tenuta diversa")
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(k.deletes.isEmpty)
    }

    func testCopyGoneOrChangedOnCubbit_stays() async {
        let c = FakeAlignmentCloud(); c.put(kept, content)
        cloud = c
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.goneFromArchive: 1])
        c.put(leaving, "un'altra foto")
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(c.deletes.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testUnsafeCandidates_stay() async {
        let o = await run([candidate(leavingETag: .some(nil)), candidate("_quarantena/2026-10-04/a.jpg"), candidate(archive: .hdd),
                           candidate(kept.lowercased())])
        XCTAssertEqual(o.skipped, [.unsafePath: 4])
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    // MARK: - I guasti che fermano la corsa

    func testHeadError_stops_beforeAnyDelete() async {
        cloud.failHead = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testDeleteError_stops_andTheLogSaysFailed() async {
        cloud.failDelete = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testDeleteWithoutDeleteMarker_stopsImmediately() async {
        cloud.put("Other/b.jpg", content)
        cloud.deleteWithoutMarker = true
        let o = await run([candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.stop, .deleteWithoutMarker(path: leaving))
        XCTAssertEqual(cloud.deletes, [leaving], "nessun secondo DELETE dopo un DELETE senza segno")
        XCTAssertEqual(cloud.current("Other/b.jpg"), content)
        let last = store.read().entries.last
        XCTAssertEqual(last?.event, .removed)
        XCTAssertNil(last?.deleteMarkerVersionId)
    }

    func testLogNotWritable_noDelete() async {
        struct Broken: Error {}
        let o = await run([candidate()], engine: engine(log: { _ in throw Broken() }))
        guard case .logNotWritten = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testSSDMissingAtStart_noDelete() async {
        let ssdPath = ssd.path
        let o = await run([candidate()], engine: engine(volumeIdentity: { $0.path == ssdPath ? nil : deviceIdentifier(of: $0) }))
        XCTAssertEqual(o.stop, .volumeMissing(.ssd))
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testInterrupt_stopsBetweenCopies() async {
        cloud.put("Other/b.jpg", content)
        let o = await run([candidate(), candidate("Other/b.jpg")], cancelAfter: 1)
        XCTAssertEqual(o.stop, .interrupted)
        XCTAssertEqual(cloud.deletes, [leaving])
    }
}
```

### Task 6 — `AppBackupFotoTests/AlignmentUndoTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// «Annulla l'ultimo blocco» del progetto 4 (ROADMAP #47, ADR-0019). Sull'HDD rimette a posto dal
/// Cestino con la cura di `TrashRestorer`; su Cubbit toglie solo i segni di cancellazione
/// registrati, mai una versione di dati, e verifica con la HEAD che la foto sia tornata.
final class AlignmentUndoTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var trash: URL!
    private var store: AlignmentLogStore!
    private var cloud: FakeAlignmentCloud!
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentUndoTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        trash = hdd.appendingPathComponent(".Trashes/501")
        for d in [ssd!, hdd!, trash!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment.jsonl"))
        cloud = FakeAlignmentCloud()
        try put(ssd, kept, content)
        try put(hdd, leaving, content)
        try put(hdd, kept, content)
        cloud.put(leaving, content)
        cloud.put(kept, content)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ archive: AlignmentArchive) -> AlignmentCandidate {
        let d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(leaving), keptKey: normalizedIndexKey(kept),
                                  leavingPath: leaving, keptPath: kept, ssdLeavingPath: leaving, ssdKeptPath: kept,
                                  ssdKeptSize: d.size, size: d.size, sha256: d.sha256,
                                  leavingETag: archive == .cubbit ? d.md5 : nil, keptETag: archive == .cubbit ? d.md5 : nil)
    }

    private func engine(now: Date = Date()) -> ArchiveAligner {
        let s = store!, dir = trash!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: hdd, cloud: cloud, log: { try s.append($0) }, now: { now },
                              trashFunction: { url in
                                  let dst = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                                  try FileManager.default.moveItem(at: url, to: dst)
                                  return dst
                              })
    }

    /// Toglie la copia con il motore, e restituisce l'ultimo blocco come lo legge «Annulla».
    private func removeThenLastBlock(_ archive: AlignmentArchive, removedAt: Date = Date()) async -> [AlignmentRemoval] {
        let e = engine(now: removedAt)
        let o = archive == .hdd ? await e.runHDDBlock([candidate(.hdd)], blockId: "b1")
                                : await e.runCubbitBlock([candidate(.cubbit)], blockId: "b1")
        XCTAssertEqual(o.removed.count, 1)
        return store.state(for: archive)?.lastBlockToRestore ?? []
    }

    // MARK: - HDD

    func testHDD_undo_putsTheCopyBack_andTheLogKnows() async {
        let block = await removeThenLastBlock(.hdd)
        XCTAssertNil(read(hdd, leaving))
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.restored, 1)
        XCTAssertEqual(read(hdd, leaving), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 0)
        XCTAssertNil(store.state(for: .hdd)?.lastBlockSummary)
    }

    func testHDD_undo_neverOverwritesAFileThatTookItsPlace() async throws {
        let block = await removeThenLastBlock(.hdd)
        try put(hdd, leaving, "un file nuovo con lo stesso nome")
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.skipped, [.occupied: 1])
        XCTAssertEqual(read(hdd, leaving), "un file nuovo con lo stesso nome")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func testHDD_undo_afterTheTrashWasEmptied_saysSo() async throws {
        let block = await removeThenLastBlock(.hdd)
        for f in try FileManager.default.contentsOfDirectory(atPath: trash.path) { try FileManager.default.removeItem(at: trash.appendingPathComponent(f)) }
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.skipped, [.missingInTrash: 1])
        XCTAssertEqual(o.restored, 0)
    }

    func testHDD_undo_recognisesACopyAlreadyPutBackByHand() async throws {
        let block = await removeThenLastBlock(.hdd)
        let inTrash = try FileManager.default.contentsOfDirectory(atPath: trash.path)[0]
        try FileManager.default.moveItem(at: trash.appendingPathComponent(inTrash), to: hdd.appendingPathComponent(leaving))
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.alreadyBack, 1)
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 0)
    }

    func testHDD_undo_withoutWhereItWent_isNotRestorable() async {
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .hdd, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: 1, sha256: "s", etag: nil, originalAbsolutePath: nil, trashedPath: nil,
                                 deleteMarkerVersionId: nil, removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .hdd)
        XCTAssertEqual(o.skipped, [.notRestorable: 1])
    }

    func testHDD_undo_withTheHDDGone_touchesNothing() async {
        let block = await removeThenLastBlock(.hdd)
        let e = ArchiveAligner(ssdRoot: ssd, hddRoot: tmp.appendingPathComponent("non-c-e"), cloud: nil, log: { _ in })
        let o = await e.undo(block, archive: .hdd)
        XCTAssertEqual(o.stop, .volumeMissing(.hdd))
        XCTAssertEqual(o.notAttempted, 1)
    }

    // MARK: - Cubbit

    func testCubbit_undo_removesTheRecordedMarker_andTheSamePhotoIsBack() async {
        let block = await removeThenLastBlock(.cubbit)
        XCTAssertNil(cloud.current(leaving))
        XCTAssertEqual(block.first?.deleteMarkerVersionId, "m3")
        let o = await engine().undo(block, archive: .cubbit)
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.restored, 1)
        XCTAssertEqual(cloud.current(leaving), content)
        XCTAssertEqual(cloud.markerRemovals.map(\.versionId), ["m3"])
        XCTAssertEqual(cloud.dataVersionIds(leaving), ["v1"], "la versione della foto non si tocca")
        XCTAssertEqual(store.state(for: .cubbit)?.lastBlockToRestore.count, 0)
    }

    func testCubbit_undo_pastTheRuleDays_doesNothing() async {
        let block = await removeThenLastBlock(.cubbit, removedAt: Date(timeIntervalSinceNow: -29.5 * 86_400))
        let o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.tooOld: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        // Senza regola le versioni restano per sempre: nessun limite.
        cloud.rules = []
        let again = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(again.restored, 1)
    }

    func testCubbit_undo_neverRemovesADataVersion_evenIfTheLogNamesOne() async {
        let block = await removeThenLastBlock(.cubbit)
        let r = block[0]
        let tampered = AlignmentRemoval(id: r.id, blockId: r.blockId, archive: .cubbit, leavingPath: r.leavingPath, leavingKey: r.leavingKey,
                                        keptPath: r.keptPath, size: r.size, sha256: r.sha256, etag: r.etag, originalAbsolutePath: nil,
                                        trashedPath: nil, deleteMarkerVersionId: "v1", removedAt: r.removedAt, restoredAt: nil)
        let o = await engine().undo([tampered], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.notADeleteMarker: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        XCTAssertEqual(cloud.dataVersionIds(leaving), ["v1"])
    }

    func testCubbit_undo_markerThatIsNotTheLatest_orMissing_staysPut() async {
        let block = await removeThenLastBlock(.cubbit)
        _ = try? await cloud.delete(key: leaving)          // un secondo segno sopra quello registrato
        var o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.markerNotLatest: 1])
        let r = block[0]
        let unknown = AlignmentRemoval(id: r.id, blockId: r.blockId, archive: .cubbit, leavingPath: r.leavingPath, leavingKey: r.leavingKey,
                                       keptPath: r.keptPath, size: r.size, sha256: r.sha256, etag: r.etag, originalAbsolutePath: nil,
                                       trashedPath: nil, deleteMarkerVersionId: "m-sconosciuto", removedAt: r.removedAt, restoredAt: nil)
        o = await engine().undo([unknown], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.markerNotFound: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
    }

    func testCubbit_undo_alreadyBack_orReplacedByAnotherPhoto() async {
        let block = await removeThenLastBlock(.cubbit)
        cloud.put(leaving, content)                        // ricaricata dal backup, stessa foto
        var o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.alreadyBack, 1)
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        cloud.put(leaving, "un'altra foto")
        o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.occupied: 1])
    }

    func testCubbit_undo_thatDoesNotBringBackTheSamePhoto_isReported() async {
        // Sotto il segno c'e' una versione con un altro contenuto: tolto il segno, la HEAD non torna.
        let other = FakeAlignmentCloud()
        other.put(leaving, "versione diversa")
        _ = try? await other.delete(key: leaving)
        cloud = other
        let d = digest(content)
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .cubbit, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: d.size, sha256: d.sha256, etag: d.md5, originalAbsolutePath: nil,
                                 trashedPath: nil, deleteMarkerVersionId: "m2", removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.verifyFailed: 1])
    }

    func testCubbit_undo_cubbitError_stops() async {
        let block = await removeThenLastBlock(.cubbit)
        cloud.failRemoveMarker = true
        let o = await engine().undo(block, archive: .cubbit)
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertEqual(o.restored, 0)
    }

    func testCubbit_undo_withoutARecordedMarker_isNotRestorable() async {
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .cubbit, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: 1, sha256: "s", etag: "e", originalAbsolutePath: nil, trashedPath: nil,
                                 deleteMarkerVersionId: nil, removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.notRestorable: 1])
    }
}
```

### Task 7 — `AppBackupFotoTests/AlignmentGatesTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// Mutua esclusione del progetto 4 (ROADMAP #47, ADR-0019) nei due versi: una corsa su HDD o
/// Cubbit ferma backup, lettura dell'elenco, inventario, riparazione, spostamenti e annullamenti
/// dell'SSD; e non parte mentre una di quelle e' in corso. Parametro `isAligning` SENZA default:
/// un cancello che lo dimentica non compila.
final class AlignmentGatesTests: XCTestCase {
    private let jargon = ["hash", "etag", "md5", "bucket", "versionid", "delete", "indice", "scansione", "cache"]

    private func assertNoJargon(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let t = text?.lowercased() else { return XCTFail("nessun motivo", file: file, line: line) }
        for w in jargon { XCTAssertFalse(t.contains(w), "«\(w)» in: \(t)", file: file, line: line) }
    }

    // MARK: - Il verso «la corsa ferma le altre»

    func testJobsDoNotStartDuringAnAlignment() {
        let r = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                           isInventorying: false, isRepairing: false, isAligning: true)
        XCTAssertNotNil(r)
        XCTAssertTrue(r?.contains("HDD o Cubbit") ?? false)
        assertNoJargon(r)
    }

    func testListReadingDoesNotStartDuringAnAlignment() {
        let r = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false,
                                                       isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                       isAligning: true)
        XCTAssertNotNil(r)
        assertNoJargon(r)
    }

    func testSSDTrashAndUndoDoNotStartDuringAnAlignment() {
        let trash = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                         isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                         isInventorying: false, isRepairing: false, isAligning: true)
        let undo = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                       isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                       summary: RestorableBatchSummary(pendingCount: 1, batchCount: 1, trashedAt: Date()),
                                                       hasEverTrashed: true, isInventorying: false, isRepairing: false, isAligning: true)
        XCTAssertNotNil(trash)
        XCTAssertNotNil(undo)
        assertNoJargon(trash)
        assertNoJargon(undo)
    }

    func testInventoryAndRepairDoNotStartDuringAnAlignment() {
        let inv = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                   isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                   isAligning: true, ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        let rep = RepairStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                isAligning: true, ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        XCTAssertNotNil(inv)
        XCTAssertNotNil(rep)
        assertNoJargon(inv)
        assertNoJargon(rep)
    }

    func testWithoutAnAlignment_theOtherGatesSayNothingNew() {
        XCTAssertNil(JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                isInventorying: false, isRepairing: false, isAligning: false))
        XCTAssertNil(InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                      isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                      isAligning: false, ssdMounted: true, hddMounted: true, hasCubbitConfig: true))
    }

    // MARK: - Il verso «le altre fermano la corsa»

    private func gate(_ archive: AlignmentArchive = .hdd, isRunning: Bool = false, isIndexing: Bool = false,
                      isTrashingDuplicates: Bool = false, isRestoringFromTrash: Bool = false, isInventorying: Bool = false,
                      isRepairing: Bool = false, isAligning: Bool = false, ssdMounted: Bool = true, hddMounted: Bool = true,
                      hasCubbitConfig: Bool = true) -> String? {
        AlignmentStartGate.blockedReason(archive: archive, isRunning: isRunning, isIndexing: isIndexing,
                                         isTrashingDuplicates: isTrashingDuplicates, isRestoringFromTrash: isRestoringFromTrash,
                                         isInventorying: isInventorying, isRepairing: isRepairing, isAligning: isAligning,
                                         ssdMounted: ssdMounted, hddMounted: hddMounted, hasCubbitConfig: hasCubbitConfig)
    }

    func testAlignmentStarts_onlyWhenNothingElseRuns() {
        XCTAssertNil(gate(.hdd))
        XCTAssertNil(gate(.cubbit))
    }

    func testEveryOtherOperation_blocksTheAlignment_withItsOwnReason() {
        let reasons = [gate(isRunning: true), gate(isIndexing: true), gate(isTrashingDuplicates: true),
                       gate(isRestoringFromTrash: true), gate(isInventorying: true), gate(isRepairing: true), gate(isAligning: true)]
        XCTAssertTrue(reasons.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(reasons.compactMap { $0 }).count, reasons.count, "ogni causa ha la sua frase")
        reasons.forEach { assertNoJargon($0) }
    }

    func testTheSSDIsAlwaysNeeded_theHDDOnlyForTheHDD_CubbitOnlyForCubbit() {
        XCTAssertNotNil(gate(.hdd, ssdMounted: false))
        XCTAssertNotNil(gate(.cubbit, ssdMounted: false))
        XCTAssertNotNil(gate(.hdd, hddMounted: false))
        XCTAssertNil(gate(.cubbit, hddMounted: false))
        XCTAssertNotNil(gate(.cubbit, hasCubbitConfig: false))
        XCTAssertNil(gate(.hdd, hasCubbitConfig: false))
    }

    func testPrecedence_anotherAlignmentFirst_thenTheSSDTrash() {
        XCTAssertEqual(gate(isRunning: true, isTrashingDuplicates: true, isAligning: true), gate(isAligning: true))
        XCTAssertEqual(gate(isRunning: true, isTrashingDuplicates: true), gate(isTrashingDuplicates: true))
        XCTAssertEqual(gate(isRunning: true, ssdMounted: false), gate(isRunning: true))
    }
}
```

### Task 8 — `AppBackupFotoTests/AlignmentStatusTests.swift`

```swift
import XCTest
@testable import AppBackupFoto

/// I testi del progetto 4 nella finestra Inventario (ROADMAP #47, ADR-0019): ogni motivo ha la sua
/// frase, i conti sono quelli giusti, e nessuna parola tecnica arriva a Enrico.
final class AlignmentStatusTests: XCTestCase {
    private let jargon = ["hash", "etag", "md5", "sha", "bucket", "versionid", "delete", "marker", "indice",
                          "scansione", "cache", "inventory", "candidate", "plan"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for w in jargon { XCTAssertFalse(t.contains(w), "«\(w)» in: \(text)", file: file, line: line) }
        XCTAssertFalse(text.isEmpty, file: file, line: line)
    }

    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    private func candidate(_ i: Int, size: Int64 = 1_000_000) -> AlignmentCandidate {
        AlignmentCandidate(archive: .hdd, leavingKey: "p\(i)", keptKey: "k", leavingPath: "P/\(i).jpg", keptPath: "K.jpg",
                           ssdLeavingPath: "P/\(i).jpg", ssdKeptPath: "K.jpg", ssdKeptSize: size, size: size, sha256: "s",
                           leavingETag: nil, keptETag: nil)
    }

    private func plan(_ archive: AlignmentArchive = .hdd, candidates: Int = 3, stays: [AlignmentStayReason: Int] = [:],
                      malformed: Int = 0) -> AlignmentPlan {
        AlignmentPlan(archive: archive, runId: 7, block: nil, historyUnreadable: false, malformedHistoryLines: malformed,
                      historyCopies: candidates + stays.values.reduce(0, +), candidates: (0..<candidates).map { candidate($0) },
                      stays: stays, stayExamples: [:])
    }

    func testPlanLines_countAndSpace() {
        let lines = AlignmentStatus.planLines(plan(candidates: 3))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].text.contains("3 copie"))
        XCTAssertTrue(lines[0].text.contains("HDD"))
        XCTAssertTrue(lines[0].text.contains(ByteCountFormatter.string(fromByteCount: 3_000_000, countStyle: .file)))
        assertNoJargon(lines[0].text)
        XCTAssertTrue(AlignmentStatus.planLines(plan(.cubbit, candidates: 1))[0].text.contains("1 copia"))
    }

    func testPlanLines_nothingToRemove() {
        let lines = AlignmentStatus.planLines(plan(candidates: 0))
        XCTAssertEqual(lines.map(\.id), ["align-none"])
    }

    func testPlanLines_blockedByTheInventory_saysWhyAndWhatToDo() {
        let p = AlignmentPlan.blocked(.cubbit, block: .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_791_115_200)))
        let lines = AlignmentStatus.planLines(p, calendar: rome)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].tone, .warning)
        XCTAssertTrue(lines[0].text.contains("4 ottobre 2026"))
        XCTAssertTrue(lines[0].text.contains("Aggiorna l'inventario"))
    }

    func testPlanLines_unreadableHistory() {
        let lines = AlignmentStatus.planLines(.blocked(.hdd, block: nil, historyUnreadable: true))
        XCTAssertEqual(lines.map(\.id), ["align-history"])
        assertNoJargon(lines[0].text)
    }

    func testEveryStayReason_hasItsOwnLine_withTheCount() {
        var stays: [AlignmentStayReason: Int] = [:]
        for (i, r) in AlignmentStayReason.allCases.enumerated() { stays[r] = i + 2 }
        for archive in AlignmentArchive.allCases {
            let lines = AlignmentStatus.planLines(plan(archive, candidates: 0, stays: stays, malformed: 1))
            XCTAssertEqual(lines.count, 1 + AlignmentStayReason.allCases.count + 1)
            XCTAssertEqual(Set(lines.map(\.text)).count, lines.count)
            lines.forEach { assertNoJargon($0.text) }
        }
        XCTAssertTrue(AlignmentStatus.planLines(plan(candidates: 0, stays: [.backOnSSD: 1]))[1].text.hasPrefix("1 copia resta"))
    }

    func testCubbitSafety_everyCaseIsExplained_andOnlyReadyIsOk() {
        let cases: [AlignmentCubbitSafety] = [.ready(days: 30), .versioningNotEnabled(.neverEnabled), .noExpiryRule,
                                              .expiryTooShort(days: 7), .expiresCurrentPhotos]
        let lines = cases.map { AlignmentStatus.cubbitSafetyLine($0) }
        XCTAssertEqual(lines.map(\.tone), [.ok, .warning, .warning, .warning, .warning])
        XCTAssertEqual(Set(lines.map(\.text)).count, cases.count)
        XCTAssertTrue(lines[0].text.contains("30 giorni"))
        XCTAssertTrue(lines[3].text.contains("7 giorni"))
        lines.forEach { assertNoJargon($0.text) }
    }

    func testSummary_HDD_saysTrashAndNeverEmptied_Cubbit_says30Days() {
        let hdd = AlignmentStatus.summaryLines(plan(.hdd, candidates: 3), blocks: 1).joined(separator: " ")
        XCTAssertTrue(hdd.contains("Cestino dell'HDD"))
        XCTAssertTrue(hdd.contains("non lo svuota mai"))
        XCTAssertTrue(hdd.contains("L'SSD non viene toccato"))
        XCTAssertFalse(hdd.contains("blocchi"))
        let cubbit = AlignmentStatus.summaryLines(plan(.cubbit, candidates: 3), blocks: 45).joined(separator: " ")
        XCTAssertTrue(cubbit.contains("30 giorni"))
        XCTAssertTrue(cubbit.contains("45 blocchi"))
        XCTAssertTrue(cubbit.contains(AlignmentStatus.undoButton))
        assertNoJargon(hdd)
        assertNoJargon(cubbit)
    }

    func testConfirmMessage_namesTheCountAndWhereTheyGo() {
        XCTAssertTrue(AlignmentStatus.confirmMessage(plan(.hdd, candidates: 4)).contains("Cestino dell'HDD"))
        XCTAssertTrue(AlignmentStatus.confirmMessage(plan(.cubbit, candidates: 4)).contains("30 giorni"))
    }

    func testEveryStopReason_hasAnHonestLine() {
        let stops: [AlignmentStopReason] = [.interrupted, .volumeMissing(.ssd), .volumeMissing(.hdd), .volumeVanished(.hdd),
                                            .logNotWritten("x"), .trashFailed(path: "a.jpg", detail: "permesso negato"),
                                            .keptVanished(path: "k.jpg"), .cubbitNotReady(.noExpiryRule), .cubbitError("x"),
                                            .deleteWithoutMarker(path: "a.jpg"), .inventoryNoLongerValid(.inventoryIncomplete)]
        let texts = stops.map { AlignmentStatus.stopLine($0, archive: .cubbit) }
        XCTAssertEqual(Set(texts).count, stops.count)
        texts.forEach { assertNoJargon($0) }
        XCTAssertTrue(AlignmentStatus.stopLine(.keptVanished(path: "k.jpg"), archive: .hdd).contains(AlignmentStatus.undoButton))
    }

    func testEverySkipAndUndoReason_hasItsOwnText() {
        let skips = AlignmentSkipReason.allCases.map { AlignmentStatus.skipReasonText($0) }
        XCTAssertEqual(Set(skips).count, skips.count)
        skips.forEach { assertNoJargon($0) }
        let undos = AlignmentUndoSkipReason.allCases.map { AlignmentStatus.undoSkipText($0) }
        undos.forEach { assertNoJargon($0) }
        // Due casi dicono la stessa cosa all'utente, apposta: non risultano piu' tolte da questa app.
        XCTAssertEqual(Set(undos).count, undos.count - 1)
    }

    func testRunOutcome_absorbsBlocks_andTheLinesTellEverything() {
        var run = AlignmentRunOutcome(archive: .hdd, totalBlocks: 2)
        var a = AlignmentBlockOutcome()
        a.removed = [candidate(1), candidate(2)]
        a.skip(candidate(3), .locked)
        var b = AlignmentBlockOutcome()
        b.removed = [candidate(4)]
        b.skip(candidate(5), .locked)
        b.skip(candidate(6), .contentChanged)
        b.stop = .interrupted
        run.absorb(a)
        run.absorb(b)
        XCTAssertEqual(run.removedCount, 3)
        XCTAssertEqual(run.removedBytes, 3_000_000)
        XCTAssertEqual(run.skipped, [.locked: 2, .contentChanged: 1])
        XCTAssertEqual(run.skippedExamples[.locked], ["P/3.jpg", "P/5.jpg"])
        run.stop = b.stop
        let lines = AlignmentStatus.runOutcomeLines(run)
        XCTAssertEqual(lines.map(\.id), ["run-removed", "run-stop", "run-skip-locked", "run-skip-contentChanged"])
        XCTAssertTrue(lines[0].text.contains("3 copie"))
        XCTAssertTrue(lines[0].text.contains("Cestino dell'HDD"))
        lines.forEach { assertNoJargon($0.text) }
    }

    func testUndo_confirmationAndOutcome() {
        let c = AlignmentStatus.undoConfirmation(.cubbit, summary: RestorableBatchSummary(pendingCount: 12, batchCount: 12,
                                                 trashedAt: Date(timeIntervalSince1970: 1_791_115_200)), calendar: rome)
        XCTAssertTrue(c.message.contains("12 copie tolte"))
        XCTAssertTrue(c.message.contains("4 ottobre 2026"))
        var o = AlignmentUndoOutcome()
        o.restored = 10
        o.alreadyBack = 1
        o.skip("a.jpg", .tooOld)
        o.notAttempted = 2
        let lines = AlignmentStatus.undoOutcomeLines(.cubbit, o)
        XCTAssertEqual(lines.map(\.id), ["undo-restored", "undo-skip-tooOld", "undo-left"])
        lines.forEach { assertNoJargon($0.text) }
    }

    func testProgressLine_mentionsBlocksOnlyWhenThereAreMany() {
        XCTAssertEqual(AlignmentStatus.progressLine(.hdd, done: 1_234, total: 89_442, block: 1, blocks: 45),
                       "Tolgo da HDD le copie doppie: \(1_234.formatted()) di \(89_442.formatted()) (blocco 1 di 45)")
        XCTAssertFalse(AlignmentStatus.progressLine(.cubbit, done: 1, total: 2, block: 1, blocks: 1).contains("blocco"))
    }

    func testUnfinishedLine_onlyWhenSomethingIsUnfinished() {
        XCTAssertNil(AlignmentStatus.unfinishedLine(0, archive: .hdd))
        let l = AlignmentStatus.unfinishedLine(2, archive: .cubbit)
        XCTAssertEqual(l?.tone, .warning)
        assertNoJargon(l?.text ?? "")
    }

    func testTheInventoryNote_nowNamesBothButtonsThatWrite() {
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(RepairStatus.buttonTitle))
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(AlignmentStatus.runButton))
    }
}
```


## Appendice C — Aggiunte in coda alle classi e chiamate cambiate

### Task 1 — in coda a `MainThreadIsolationTests.swift`

```swift
    // MARK: - Doppioni su HDD e Cubbit (ROADMAP #47, ADR-0019)

    func testAlignmentPlanner_runsWithoutTheMainThread() throws {
        let done = DispatchSemaphore(value: 0)
        let url = tmp.appendingPathComponent("trash-history.jsonl")
        Task.detached {
            let history = TrashHistoryReader.read(url: url)
            _ = AlignmentPlanner.plan(archive: .cubbit, history: history, ssdRoot: URL(fileURLWithPath: "/Volumes/SSD - Enri"),
                                      snapshot: InventorySnapshot(), lastArchiveWriteAt: nil, alreadyRemoved: [])
            _ = AlignmentRunPlan.blocks([])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "AlignmentPlanner/TrashHistoryReader hanno avuto bisogno del main thread: manca nonisolated?")
    }
```

### Task 2 — in coda a `MainThreadIsolationTests.swift`

```swift
    func testAlignmentLogStore_runsWithoutTheMainThread() throws {
        let store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment-hdd.jsonl"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? store.append(AlignmentLogEntry(event: .failed, id: "1", blockId: "b", archive: .hdd, at: Date()))
            _ = store.state(for: .hdd)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "AlignmentLogStore ha avuto bisogno del main thread: manca nonisolated?")
    }
```

### Task 4 — in coda a `MainThreadIsolationTests.swift`

```swift
    func testArchiveAlignerHDDBlock_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD"), hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd, hdd] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let aligner = ArchiveAligner(ssdRoot: ssd, hddRoot: hdd, cloud: nil, log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await aligner.runHDDBlock([], blockId: "b")
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "ArchiveAligner.runHDDBlock ha avuto bisogno del main thread (manca @concurrent o nonisolated?).")
    }
```

### Task 5 — in coda a `MainThreadIsolationTests.swift`

```swift
    func testArchiveAlignerCubbitBlock_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: ssd, withIntermediateDirectories: true)
        let aligner = ArchiveAligner(ssdRoot: ssd, hddRoot: nil, cloud: FakeAlignmentCloud(), log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await aligner.runCubbitBlock([], blockId: "b")
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "ArchiveAligner.runCubbitBlock ha avuto bisogno del main thread (manca @concurrent?).")
    }
```

### Task 6 — in coda a `MainThreadIsolationTests.swift`

```swift
    func testArchiveAlignerUndo_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: ssd, withIntermediateDirectories: true)
        let aligner = ArchiveAligner(ssdRoot: ssd, hddRoot: nil, cloud: FakeAlignmentCloud(), log: { _ in })
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await aligner.undo([], archive: .cubbit)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "ArchiveAligner.undo ha avuto bisogno del main thread (manca @concurrent?).")
    }
```

### Task 5 — in coda a `AlignmentDeleteGuardTests.swift`

```swift
    func testTheEngineSendsTheDeleteFromOnePlaceOnly() throws {
        // Un solo punto del motore manda il DELETE senza versione (dopo le versioni lette e le
        // due HEAD). Se ne serve un secondo, va scritto perche' in ADR-0019.
        XCTAssertEqual(count("cloud.delete(key:", in: try source()), 1)
    }
```

### Task 6 — in coda a `AlignmentDeleteGuardTests.swift`

```swift
    func testTheUndoRemovesDeleteMarkersFromOnePlaceOnly() throws {
        XCTAssertEqual(count("cloud.removeDeleteMarker(", in: try source()), 1)
    }
```

### Task 7 — le chiamate dei cinque file di test esistenti

```python
import re
for f in ['JobStartGateTests.swift','RepairGatesTests.swift','DuplicatesStatusTests.swift',
          'InventoryRefreshTests.swift','LibraryIndexStatusTests.swift']:
    p = 'AppBackupFotoTests/' + f; s = open(p).read()
    s = re.sub(r'isRepairing: (true|false)\)', r'isRepairing: \1, isAligning: false)', s)
    s = s.replace('isRepairing: true,\n', 'isRepairing: true, isAligning: false,\n')
    s = s.replace('isRepairing: Bool = false,', 'isRepairing: Bool = false, isAligning: Bool = false,')
    s = s.replace('isRepairing: isRepairing,', 'isRepairing: isRepairing, isAligning: isAligning,')
    open(p, 'w').write(s)
```
