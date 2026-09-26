# AppBackupFoto — Contesto per Claude Code

Questo file definisce regole, architettura e obiettivi del progetto. Leggilo integralmente prima di toccare qualsiasi file. Il dettaglio dell'architettura Swift (componente per componente) e lo storico bug sono in `.claude/rules/architecture.md` e `.claude/rules/bug-history.md` — si caricano automaticamente quando lavori su `ContentView.swift` o `AppBackupFotoTests/`.

Altre due letture brevi che questo file **non** sostituisce: le **decisioni architetturali** stanno in `Docs/adr/` (una pagina per decisione, con il perché e le conseguenze — oggi 4, tutte sull'indice di contenuto e sul concetto di doppione), e il **vocabolario del progetto** in `Docs/CONTEXT.md`. Se stai per riproporre una scelta che un ADR ha già chiuso, l'ADR dice anche quale argomento nuovo servirebbe per riaprirla.

---

## Identità del progetto

App macOS nativa (SwiftUI, Swift 5.x, target macOS 26+) per il backup automatico delle foto di **Enrico Nanni Vicenzi** su tre destinazioni:

- **Mac → SSD** — copia Photos Library originals in `/Volumes/SSD - Enri/Foto iPhone`
- **SSD → HDD** — mirror locale (deep checksum automatico ogni 30 giorni)
- **SSD → Cubbit S3** — cloud backup sul bucket `backupfoto`

File principale e unico: `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/ContentView.swift` (**~8.400 righe** al 2026-08-27 — il "~2000" scritto qui fino a oggi era fermo a luglio; non fidarti dei numeri di riga per localizzare una funzione, usa `grep -n`). Non esistono altri file Swift nel target app oltre agli Assets — l'entry point `@main` (`BackupFotoEnricoApp`) vive anch'esso in questo file (`AppBackupFotoApp.swift` è stato rimosso perché ridondante).

Target di test separato `AppBackupFotoTests/`: **31 file XCTest** su directory temporanee reali (nessun mock), capostipite `FileSyncerZeroOverwriteTests.swift`, che blinda l'invariante zero-overwrite. **Il target non è file-system-synchronized**: ogni nuovo file di test va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`), altrimenti compila ma non viene mai eseguito e i test "passano" solo perché non girano — verificare sempre il **conteggio totale atteso**, mai il solo `** TEST SUCCEEDED **`.

---

## Regola assoluta — Le foto non si toccano

Le foto sono dati irrecuperabili. Ogni modifica al codice deve rispettare questi vincoli senza eccezioni:

1. **Zero delete.** Nessun percorso di codice cancella un file foto. **Unica porta, aperta il 2026-08-27**: il pannello Doppioni può spostare nel **Cestino del volume** (`FileManager.trashItem`) copie byte-identiche di file che restano presenti sull'SSD — e solo dopo che ogni membro del gruppo, **la copia tenuta compresa**, è stato riletto e rihashato dal disco con esito unanime, e dopo che l'utente ha spuntato i gruppi, letto un riepilogo dettagliato e confermato. Anche lì: mai `removeItem` su un file foto, mai uno svuotamento del Cestino, mai un file la cui unica copia sparisce. Tutto il resto del progetto resta a zero delete.
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga.
3. **Read-only sulla sorgente.** La Libreria Foto del Mac non viene mai modificata, in nessun caso. Sull'SSD l'unica scrittura ammessa oltre alle copie di backup è lo spostamento nel Cestino del punto 1. Nessun'altra funzione scrive sull'SSD.
4. **Dry-run prima di ogni nuova operazione di sync**: qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione.
5. **Confronto sempre esplicito**: prima di copiare, il codice deve verificare esplicitamente che il file di destinazione non esista già.
> I punti **1** e **3** sono stati riscritti il **2026-08-28** (testo approvato da Enrico, riportato parola per parola dalla spec `Docs/superpowers/specs/2026-08-27-duplicates-panel-design.md`, sezione «La regola assoluta cambia»). Prima dicevano «nessuna cancellazione in nessun caso» e «la sorgente viene solo letta»: con il pannello Doppioni sarebbero diventati **falsi**. Una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa, che qualcuno prima o poi estenderà. Il motivo e la data stanno in **ADR-0005**.

6. **Mai committare dati foto o credenziali in git** — vedi `.gitignore`: `Log/` (foto reali, non log testuali) e `Script/*.csv` (export credenziali rclone/S3) sono esclusi. Una scrittura su `Log/` da un tool automatico è bloccata anche a livello di hook (`.claude/hooks/protect_log_dir.py`).

---

## Regola sul ciclo AI di revisione (obbligatoria)

Ogni modifica al codice deve passare attraverso un ciclo in due fasi:

**Fase 1 — Scrittura**: scrivi o modifica il codice per soddisfare il requisito.

**Fase 2 — Revisione AI (if-then)**: dopo aver scritto il codice, esegui mentalmente questa checklist come agente di revisione separato:

IF il codice contiene operazioni FileManager (removeItem, moveItem, copyItem):

    THEN verifica che nessuna tocchi file sorgente

    THEN verifica che copyItem abbia guardia di esistenza prima dell'esecuzione

IF il codice chiama `trashItem`:

    THEN verifica che il percorso sia dentro la root della libreria, confrontato per componenti canoniche

    THEN verifica che il file sia stato riletto e rihashato, e che l'intero gruppo sia unanime

    THEN verifica che il file tenuto non sia fra quelli passati a `trashItem`

    THEN verifica che il percorso di destinazione sia registrato prima di procedere al file successivo

IF il codice fa chiamate S3 (PUT, DELETE, COPY):

    THEN verifica che non ci siano DELETE (eccetto AbortMultipartUpload su cancel, che non tocca dati già scritti)

    THEN verifica che PUT controlli esistenza remota prima di inviare

IF il codice usa bookmark security-scoped:

    THEN verifica che startAccessing() sia chiamato prima dell'uso

    THEN verifica che stopAccessing() sia chiamato in defer o finally

IF il codice aggiorna la UI da contesto async:

    THEN verifica che sia wrappato in Task { @MainActor in }

IF il codice lancia lavoro in `Task.detached` o su una `DispatchQueue`:

    THEN verifica che i tipi chiamati siano `nonisolated`, con la riga sul perché sono thread-safe

    THEN se una funzione di fondo diventa `async`, verifica che sia `@concurrent`

IF trovi bug in questa revisione:

    THEN documentalo nel log di output e correggilo prima di presentare il risultato finale

Presenta sempre l'output della revisione insieme al codice. Questa checklist è il minimo: se il progetto opera con i ruoli Code Reviewer/Security Auditor (vedi "Team di sviluppo" sotto), la copre in aggiunta, non in sostituzione.

---

## Vincolo tecnico macOS Sequoia (critico)

Qualsiasi subprocess (rsync, bash, rclone, Process()) lanciato da un'app GUI **non riceve i permessi TCC per i volumi esterni**, indipendentemente da Full Disk Access. L'unica soluzione senza firma Apple è: **bookmark + FileManager nativo** (dal 2026-07-29 bookmark normali, non più security-scoped — vedi `.claude/rules/architecture.md` per `BookmarkManager`: il meccanismo di scope non serve dato che l'app non è sandboxata e ha Full Disk Access, e su ExFAT è addirittura rotto). Non proporre mai soluzioni basate su subprocess per accedere a volumi esterni.

---

## Stato attuale (aggiornato 2026-09-25)

La data sopra vale per l'intera tabella. Se ci lavori, aggiornala: fino a oggi diceva 2026-07-29 mentre alcune righe erano già state riscritte al 2026-08-18, e il conteggio dei test era fermo a 139 su 346 reali. **Il primo tocco del 2026-09-19 era mirato**: solo la riga «Test automatici» sotto era stata aggiornata (fix di isolamento MainActor, BUG-7, 568 → 587 test). **Un secondo tocco, stesso giorno**: l'aggiornamento dell'elenco delle foto è diventato l'ultimo passo del backup invece di una lettura separata dopo la fine del job (spec `Docs/superpowers/specs/2026-09-19-index-refresh-as-backup-step-design.md`, ADR-0007) — aggiornate le righe «Backup automatico Mac→SSD», «Indice di contenuto della libreria» e «Test automatici» (587 → 617). **Terzo tocco, 2026-09-20**: «Annulla l'ultimo spostamento» (#34), il progresso della copia (#37), il controllo di spazio libero (#39) e il campione d'integrità (#33, aggiunta allo scope) sono usciti dal main thread (spec `Docs/superpowers/specs/2026-09-19-remaining-main-thread-work-design.md`, ADR-0009/0010) — aggiornate le righe «Indice di contenuto della libreria» (per il pannello Doppioni) e «Test automatici» (baseline di sessione 679, misurata su `main` con il lavoro successivo #38/#40 già incluso, → 756). **Quarto tocco, 2026-09-24**: `main` è stato portato a `fix/remaining-main-thread-work` con un fast-forward (nessuna riscrittura di storia), poi lo stesso schema di «Annulla l'ultimo spostamento» è stato applicato allo spostamento nel Cestino (ROADMAP #41, spec `Docs/superpowers/specs/2026-09-20-trash-progress-survives-window-close-design.md`) — aggiornate solo le righe «Indice di contenuto della libreria» e «Test automatici» (756 → 772). **Quinto tocco, 2026-09-25**: piano `Docs/superpowers/plans/2026-09-24-duplicates-at-real-scale.md` (ADR-0011/0012) — filtri, regola per cartella e corsa a più blocchi per i 27.798 gruppi reali; Task 12 (avviso di elenco stantio) e Task 14 (questa stessa passata di documentazione) chiusi, **Task 13 (mutation testing) non eseguito, dichiarato**. Aggiornate le righe «Indice di contenuto della libreria» e «Test automatici» (772 → ~854, stima dai delta — l'ultima misura indipendente del coordinatore, 837, è di poco prima dei Task 12/14). Le altre righe restano alle date che portano già scritte, non sono state riverificate in questa sessione.

| Funzione | Stato |
| :---- | :---- |
| Mac → SSD | ✅ Funziona, con anteprima dry-run e verifica SHA256 post-copia |
| SSD → HDD | ✅ Funziona; validazione volume-root con alert esplicito impedisce più il caso 0/0 silenzioso |
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart fallito/cancellato, retry con backoff, concorrenza adattiva condivisa tra file e parti multipart (2026-08-18), grafico MB/s |
| Ripristino guidato (SSD/HDD/Cubbit → cartella) | ✅ Implementato — 4 passi, indicatori di disponibilità in tempo reale, UI volutamente semplice |
| Sheet completamento | ✅ Funziona |
| Notifiche sistema | ✅ Funzionano |
| SetupView | ✅ Funziona; basta la Libreria Foto per entrare nell'app (`canEnterApp`) |
| SettingsSheet / ToolsSheet / AppearanceSheet | ✅ Funzionano |
| Sidebar hamburger (Report Log, Ripristina, Importa foto, Configurazione, Tools, Foto, Controlla aggiornamenti, Aspetto, Lingua) | ✅ Implementata. «Catalogo» **rimosso il 2026-09-03** su richiesta di Enrico: lo sostituirà Immich (#29), che sfoglia per metadati invece che per cartelle |
| Grafico velocità real-time | ✅ Implementato (Charts, MB/s per S3, file/s locale) |
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256 (con **precedenza ai file copiati e mai verificati**, 2026-08-26), pulizia upload multipart orfani |
| Backup automatico Mac→SSD | ✅ Implementato — trigger su collegamento SSD, toggle on/off in Impostazioni, solo ad app aperta. **Dal 2026-09-19 include il passo 2**: a fine copia, se l'elenco esiste già e l'interruttore relativo è acceso, l'app aggiorna l'elenco delle foto sull'SSD come ultimo passo dello stesso job (stessa barra, stesso «Interrompi», riepilogo e notifica solo alla fine) invece che con una lettura separata dopo la fine del backup. Al collegamento dell'SSD non parte più nessuna lettura da sola |
| Gate Touch ID all'avvio (#30) | ✅ Implementato — `AuthGateManager` + `LockScreenView`, copre anche le finestre di primo livello Diagnostica/Foto/Doppioni. Verifica con Touch ID reale ancora da fare |
| Auto-update Sparkle (#18) | ✅ Implementato e verificato end-to-end con due release reali. **Catalogo backup (#12): rimosso il 2026-09-03** — vedi ROADMAP punto 12 |
| Indice di contenuto della libreria + dedup in import (#31) | ✅ **Nucleo implementato (2026-08-25/27)** — indice SHA256 SQLite delle foto/video dell'SSD in `~/Library/Application Support/AppBackupFoto/`, mai sull'SSD; card «Foto già salvate sull'SSD» in Diagnostica; durante un import non si ricopia un file il cui contenuto è già in libreria, né un doppione interno allo stesso import. **Pannello Doppioni implementato (2026-08-27 → 2026-09-01)**: finestra «Doppioni» dedicata, proposta spiegata a parole su quale copia tenere, lavoro a blocchi con riepilogo + conferma distruttiva, spostamento nel **Cestino del volume** con rilettura e rihash unanimi di tutto il gruppo, registro di ripristino proprio e «Annulla l'ultimo spostamento». È l'unica feature del progetto che rimuove file dalla loro posizione: leggere **ADR-0005** prima di toccarla. **Aggiornamento dell'elenco come passo 2 del backup (2026-09-19, ADR-0007)**: `LibraryIndexer.scan` emette avanzamento anche sui file invariati (`progressEvery`, la barra del passo 2 si muove davvero) e `total` parte dal numero di voci già in elenco invece che da 0. **«Annulla l'ultimo spostamento» fuori dal main (2026-09-20, ADR-0009, ROADMAP #34)**: nuovo motore `TrashRestorer` (stessa cura del cestinamento, `st_dev` a ogni fallimento, mai "già fatto" per errore), il registro ora ricorda quali foto sono già tornate (`restoredAt`) così una seconda pressione non mente più, conferma non distruttiva prima di partire («Rimetto a posto N foto spostate il ...»), mutua esclusione scritta con job/lettura/spostamento in entrambi i versi. Annullamento a **un solo livello** (decisione di Enrico): rimette a posto solo l'ultimo blocco, un blocco più vecchio resta recuperabile solo a mano dal Cestino. Restano due verifiche manuali dall'app (vedi sotto) più quelle nuove del Task 12 del piano del 2026-09-20 (col vero SSD collegato). **Lo spostamento nel Cestino non perde più barra e «Interrompi» chiudendo la finestra Doppioni (2026-09-24, ROADMAP #41)**: stesso schema nel runner, l'elenco non si ricarica mentre lo spostamento è in corso, e anche «Annulla l'ultimo spostamento» ora rivaluta il proprio motivo specifico all'avvio vero — verifiche dal vivo ancora da fare (ROADMAP #41). **Il pannello alla scala reale (2026-09-25, piano `2026-09-24-duplicates-at-real-scale`, ADR-0011/0012)**: 27.798 gruppi veri hanno richiesto filtri (cartella, interno/incrociato, coperti dalla regola) con selezione in massa sul solo insieme filtrato, una regola per cartella («tieni in X, cestina in Y») che persiste fra le sessioni, un tetto ripensato come granularità dei blocchi (non più un rifiuto) e una **corsa** che li smaltisce uno dopo l'altro con `DuplicateTrasher.run` invariato, più una storia degli spostamenti (`TrashHistory`) perché il registro di ripristino ricorda solo gli ultimi 2.000. I quattro simboli del blocco singolo di ROADMAP #41 (`startDuplicateTrashing` e le tre proprietà collegate) sono stati rimossi, sostituiti dalla corsa. **Mutation testing (Task 13 del piano) non ancora eseguito** — resta da fare prima di considerare l'intervento verificato in profondità. Dettagli in `.claude/rules/architecture.md`, decisioni in `Docs/adr/` |
| Formattazione disco guidata (#28) | ⏳ Codice completo e buildabile, **mai eseguito davvero** — nessun `diskutil eraseDisk`. Non marcarlo "fatto" |
| Immich (#29) | ⏳ **Avviato davvero il 2026-09-13**: VM, 4 container, libreria esterna, 47.479 media indicizzati, sola lettura confermata dall'interno del container. Restano i punti 8-10 della verifica (griglia/ricerca/facce, chiusura app → container fermi, lock screen). Non marcarlo "fatto" |
| Test automatici | ✅ **861 test XCTest** su `main` dopo l'unione di `feature/duplicates-at-real-scale` (2026-09-26, BUG-8 e BUG-9 inclusi: +6 di `S3ListSpecialCharsTests`, BUG-8, copiato da `main`. Prima 855: suite completa verificata dal coordinatore il 2026-09-25 su macchina scarica, 0 fallimenti, 0 warning). **File nuovo del 2026-09-25** (piano `2026-09-24-duplicates-at-real-scale`, Task 12): `LibraryListFreshnessTests` (18, l'avviso "elenco stantio" a 14 giorni). **Rimossi lo stesso giorno**: 2 in `DuplicatesStatusTests` (`confirmationBlockedReason`, Task 11 — la funzione stessa è stata rimossa, non riscritta) e 1 in `DuplicateBatchTests` (`testSummary_saysWhenTheBatchIsTooBig`, Task 14 — la riga che verificava è stata tolta da `summaryLines()`, terza eccezione autorizzata alla regola 7 dei piani). **File estesi dal 2026-09-24** (ROADMAP #41): `DuplicatesStatusTests` +16 (`trashProgressLine`/`trashStoppingLine`/`headerLine(groupsKnown:)`, `DuplicatesPanelLoad.shouldLoadOnAppear`, un test mancante su `undoDisabledReason`/SSD scollegato). **File nuovi del 2026-09-20** (#34/#37/#39, ADR-0009/0010): `TrashRestorerTests` (~18), `ProgressThrottleTests` (7), `FileSyncerProgressThrottleTests` (4), `FreeSpaceCheckTests` (8), `TrashRestoreStatusTests` (14); `TrashManifestTests` (+7, registro che ricorda i ripristini) e `MainThreadIsolationTests` (+5, incluso il campione d'integrità del #33) estesi; `JobStartGateTests`/`LibraryIndexStatusTests`/`DuplicatesStatusTests` estesi con `isRestoringFromTrash` e `undoDisabledReason`. File nuovi dall'indicatore di spazio (2026-09-19, ADR-0008): `VolumeSpaceDisplayTests` (21), `VolumeCapacityReaderTests` (4), `S3ListingTests` (10), `CloudUsageStoreTests` (6), `CloudUsageTextTests` (12) — 53 test, UI (`VolumeSpaceLine`/`SpaceBar`/`CloudUsageLine`) e cablaggio in `VolumeMonitor.check()` dichiarati non coperti (SwiftUI/timer, non raggiungibili senza una corsa). File nuovo dal passo 2 del backup (2026-09-19): `BackupListStepTests` (33 test, logica pura del passo 2); 6 test rimossi in `LibraryIndexStatusTests` (`LibraryIndexAutoRefresh.shouldRun`, sostituita da `BackupListStep.shouldRun`). File nuovi dal fix di isolamento dello stesso giorno: `MainThreadIsolationTests`, `JobStartGateTests` — vedi BUG-7 in `.claude/rules/bug-history.md`. 40+ file in `AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256 (incluso il file che cambia dimensione mentre lo si legge), classificazione retry S3, lettura file a blocchi, logica AIMD del gate adattivo, ordinamento parti multipart, validazione endpoint S3, generazione docker-compose Immich verificata con parser YAML reale, esclusione dischi formattabili `DiskFormatter`, guardia self-import e slug etichetta, gli otto file nati dal nucleo di #31 (`IndexableKindTests`, `IndexEntryVerdictTests`, `LibraryIndexStoreTests`, `LibraryIndexerTests`, `LibraryIndexStatusTests`, `ImportDedupTests`, `UnverifiedCopiesStoreTests`, `FileSyncerHashVerificationTests`) e i sei del pannello Doppioni (`DuplicateGroupsStoreTests`, `DuplicateKeepChoiceTests`, `DuplicateBatchTests`, `TrashManifestTests`, `DuplicateTrasherTests`, `DuplicatesStatusTests`) |
| Indicatore di spazio SSD/HDD/Cubbit | ⏳ **Implementato (2026-09-19, ADR-0008)** su `feature/volume-space-indicator`, non ancora unito a `main`. Barra + «X liberi su Y · N%» sotto SSD/HDD nella sidebar (colore della destinazione, arancione da 86%, rosso da 96%), «X usati · aggiornato…» sotto Cubbit con bottone ↻ di ricalcolo manuale. Restano le verifiche manuali con SSD/HDD reali collegati (vedi il piano, Task 8 Step 4) — non marcarlo "fatto" finché non sono state viste da Enrico |
| Build | ✅ `xcodebuild ... build` e `... test` verdi su questo stato (commit `23be5d0`) |

Storico bug (risolti e aperti): vedi `.claude/rules/bug-history.md`.

---

## Verifiche manuali e obiettivi aperti

(Il titolo diceva "Obiettivi futuri (non ancora iniziati)" mentre la sezione elencava anche verifiche già fatte.)

**Prossimo incremento naturale**: **#27-A riprende dal Task 3** (il wizard di import), fermato a suo tempo in attesa di #31 — che ora è completo, pannello Doppioni incluso. Attenzione a una frase che questa pagina ha portato fino al 2026-08-27, e che è **falsa** dal momento in cui il pannello ha potuto cestinare: il pannello Doppioni non è «il consumatore a basso danno, dove ci si fida della cache invece di rileggere». Ci si fida della cache **solo per mostrare** i gruppi; per cestinarli si rilegge e si rihasha ogni membro, la copia tenuta compresa. È il percorso a danno più alto del progetto (ADR-0005).

**Verifica manuale — campione di integrità: fatta (2026-08-23)**. Eseguita da Enrico con SSD e HDD collegati: zero problemi su tutte e 3 le coppie (Mac↔SSD, SSD↔HDD, SSD↔S3). Confermato anche che `sampleS3Pair` cancella davvero i file temporanei scaricati da S3 per il confronto (`defer { try? fm.removeItem(at: tempURL) }`, nessun residuo trovato in `$TMPDIR` dopo il check). Badge di Revisione (#20) già confermato in una sessione precedente (2026-08-16).

**Verifiche manuali ancora pendenti**, in stand-by su richiesta esplicita di Enrico (2026-08-23) — vedi memoria di progetto: test TCC/formattazione reale per #28 (`Docs/superpowers/plans/2026-08-17-setup-guide-formatting.md`, Task 4 Step 5) e, per #29/Immich (`Docs/superpowers/plans/2026-08-17-immich-integration.md`, Task 5 Step 4), **i soli punti 8-10**: lo stand-by su Immich è stato tolto da Enrico il 2026-09-13 e i punti 0-7 sono passati, verifica upload S3 reale con Monitor Attività, conferma Touch ID reale.

**Verifiche manuali per #31 (indice di contenuto) — sessione con SSD e HDD collegati del 2026-09-01.** Erano l'unico step non spuntato del piano `Docs/superpowers/plans/2026-08-25-library-content-index.md` (Task 6, Step 5) più quanto emerso dalle review. Tre chiuse, due ancora da fare dall'app:

1. ⬜ **Prima costruzione reale dell'elenco dall'app**: aprire Diagnostica → «Foto già salvate sull'SSD» → «Crea l'elenco», guardare progresso e «Interrompi». È l'unico percorso della card mai eseguito davvero. **Ancora da fare**: richiede l'app in esecuzione, non una misura da terminale.
2. ✅ **Durata: misurata (2026-09-01)**, ma non dall'app. Throughput reale letto dall'SSD con `shasum -a 256` su un campione di 300 file distribuiti: **1103 MiB in 4,9 s = 224 MiB/s**. Con **237,4 GiB** di media indicizzabili (47.482 file), la stima è **~18 minuti**. La card dichiara «di solito servono dai 5 ai 15 minuti» (`LibraryIndexCard.durata`): ordine di grandezza giusto, **estremo superiore sottostimato**. Il numero della card va corretto. La misura vera dall'app resta da fare col punto 1 — l'app usa `FileChunkReader` in streaming, questa misura paga in più l'avvio di un processo per file, quindi 18 minuti è probabilmente un tetto.
3. ✅ **Estensioni realmente presenti sull'SSD: censite (2026-09-01), sospetto infondato.** Nessuna occorrenza di `.mkv`, `.x3f`, `.hevc`, `.insv`, `.lrv` — le cinque estensioni che `IndexableKind` non riconosce come media. Presenti: `jpg` 34.914, `heic` 26.211, `mov` 6.349, `mp4` 6.101, `jpeg` 3.794, `png` 3.506, `cr2` 1.496, poi `webp` 46, `gif` 29, `wmv` 6, `raf` 2. I 44.762 `.json` (metadati Google Takeout) e i 217 `.aae` (sidecar di modifica) sono correttamente fuori dall'indice. **Nessun file media viene ignorato in silenzio dal dedup.**
4. ✅ **`ls -a "/Volumes/SSD - Enri"`: fatto (2026-09-01).** `lost+found` e `Backups.backupdb` **non esistono**, né sull'SSD né sull'HDD: restano in `LibraryExclusions` come voci difensive, non corrispondono a niente di reale. Layout di primo livello dell'SSD: `Foto Google Drive`, `Foto iPhone`, `Other`, `Takeout`, `Takeout 2`, `Zip`, più il file sciolto `_prova_rsync.txt` in radice.
5. ⬜ **Un avviso della card deve comparire nella finestra Diagnostica.** Aprire Diagnostica **senza SSD collegato** e premere «Crea l'elenco»: il messaggio deve apparire *in quella finestra*. È il rilievo chiuso il 2026-08-27 con `AlertSink`, e per costruzione non è verificabile da un test (due scene SwiftUI). **Ancora da fare**, e ora richiede di scollegare l'SSD.

### Fatti misurati sui volumi reali il 2026-09-01 — da non riscoprire pagandoli una seconda volta

- **L'SSD è exFAT** (`/dev/disk4s1`, montato via **FSKit**), **l'HDD è APFS**. Che l'SSD fosse exFAT era già l'ipotesi su cui la spec aveva fatto le misure del 2026-08-27, ma su un'immagine disco creata apposta, non sul volume vero. Ora è confermato sul volume vero — e con un dettaglio nuovo: il mount avviene via **FSKit**, l'implementazione exFAT nuova di macOS, non il driver storico su cui girava l'immagine di test.
- **`trashItem` sull'SSD vero funziona: verificato empiricamente (2026-09-01)** con una sonda Swift su un file creato apposta. Destinazione `/Volumes/SSD - Enri/.Trashes/501/`, **stesso volume**, contenuto integro, origine rimossa. Chiude i punti 1 e 2 della lista «Cosa NON è stato misurato» della spec — **con una riserva: la sonda gira da `swift` a riga di comando, non dall'app firmata con Full Disk Access**, quindi il contesto TCC resta l'unica parte di quel punto ancora non verificata.
- **`.Trashes/501/` sull'SSD esisteva già da febbraio 2025**, quindi `trashItem` non ha dovuto crearla. Chiude il punto 2 della stessa lista.
- **Il record di «Rimetti a posto» viene scritto davvero sull'SSD vero.** Letto e decodificato dal B-tree di `.Trashes/501/.DS_Store`: `ptbL = "/_prova_cestino_claude/"`, `ptbN = "doppione_finto.txt"`. Coerente con la misura del 2026-08-27 sull'immagine disco, e coerente anche con la sua parte scomoda — il record è asincrono e con un processo a vita breve si perde, ma **su un solo file non si è perso**, come previsto dalla misura (le perdite erano sugli ultimi file di blocchi da 100-300). Resta valido il motivo per cui l'app tiene un registro proprio: non si può dipendere da questo.
- **exFAT produce 57.560 file AppleDouble `._`, tutti esattamente da 4096 byte, e 34.969 di essi portano un'estensione da foto** (`._IMG_7960.JPG`, `._IMG_8393.MOV`). Senza esclusione entrerebbero nell'indice e formerebbero migliaia di gruppi di doppioni fasulli da 4096 byte, che il pannello Doppioni proporrebbe di cestinare. **`LibraryExclusions.shouldExclude` li esclude già** (`name.hasPrefix("._")`, applicato dall'indicizzatore): la difesa era scritta a tavolino, ora si sa che il caso è reale e di massa.
- **`Import/` non esiste sull'SSD.** La regola 2 di `duplicateKeepChoice` (`notAnImport`) **non si attiva mai** sul volume reale. Resta corretta e va tenuta — una cartella `Import/` può nascere in qualsiasi momento — ma non discrimina nulla oggi.
- **Distribuzione dei 47.482 file media indicizzabili**: `Foto iPhone` 18.180, `Takeout` 13.139, `Takeout 2` 10.708, `Foto Google Drive` 3.947, `Other` 1.508. **Metà della libreria sta nelle due estrazioni di Google.**
### DECISIONE CHIUSA (2026-09-01) — `Takeout/` e `Takeout 2/` restano alla pari

Enrico aveva rimandato questa decisione il 2026-08-28, in attesa di avere il layout reale davanti. Chiusa ora, col layout confermato e i conteggi misurati.

**`Takeout/` e `Takeout 2/` NON vengono declassate accanto a `Import/`.** Sono **due cartelle distinte**, e contengono le **copie originali** di foto estratte da Google: una copia esiste anche nel cloud, ma i file sull'SSD sono gli originali estratti, non uno scarico rigenerabile. L'argomento «sono estrazioni automatiche, quindi valgono meno» — forte sulla carta, e scritto come tale nel commento di `duplicateKeepChoice` — **è respinto**: la loro origine automatica non dice niente sul valore del contenuto.

Conseguenza sulla regola: `duplicateKeepChoice` **non cambia nella sostanza**. Fra una copia in `Foto iPhone/` e una in `Takeout/` vince la libreria principale (regola 1); fra `Takeout/` e `Takeout 2/` decidono la data più vecchia (regola 3) e, a parità, il tie-break sul percorso più corto — che fa vincere `Takeout/` per la sola ragione che il nome è più breve. **Arbitrario ma deterministico e innocuo**: entrambe le copie sono identiche per definizione di gruppo, una delle due resta, ed entrambe le cartelle sono comunque mirrorate sull'HDD.

Quello che **deve** cambiare nel codice è il commento di `duplicateKeepChoice`, che oggi dichiara la regola «provvisoria, da rivedere con un `ls -1` del volume vero davanti» e l'argomento sul declassamento «forte». Il layout è stato riconfermato identico a quello del 2026-07-29/30 e la decisione è presa: la regola non è più provvisoria, e il motivo per cui `Takeout` resta alla pari va scritto lì, altrimenti qualcuno rifarà lo stesso ragionamento e declasserà le cartelle.

- **Il mirror SSD → HDD è completo: verificato cartella per cartella (2026-09-01).** Conteggi di file media identici su tutte e cinque le cartelle di primo livello — `Foto iPhone` 18.180, `Takeout` 13.139, `Takeout 2` 10.708, `Foto Google Drive` 3.947, `Other` 1.508 — su entrambi i volumi, **47.482 = 47.482**. Nessuna cartella presente su un volume e assente sull'altro. È un confronto per conteggio, non per contenuto: la verifica per checksum resta quella del campione di integrità (fatta il 2026-08-23, zero problemi) e del deep mirror.
- **Due residui in radice sull'HDD, nessuno dei due nostro**: `.DocumentRevisions-V100-bad-1` (cartella di sistema che macOS rinomina così quando ne rileva la corruzione — non leggibile, `Permission denied`, e non è l'app a scriverla) e `backup_log_1780339684.txt` del 1 giugno, 24 KB. Non sono prodotti dal codice attuale; segnalati per non farli riscoprire come anomalie.

**Verifica manuale pronta da eseguire nel Finder**: nel Cestino dell'SSD c'è `doppione_finto.txt`, lasciato lì apposta dalla sonda del 2026-09-01 insieme alla sua cartella d'origine `/Volumes/SSD - Enri/_prova_cestino_claude/`. Premere **«Rimetti a posto»** su quel file chiude l'ultima verifica manuale del Task 7 del pannello Doppioni. Entrambi sono file di prova: si possono cancellare in qualsiasi momento.

**Rilievi minori di #31: cinque su sei chiusi il 2026-09-01** (suite da 480 a **501 test**). Chiusi: il registro anti-gergo delle righe di stato, che era verificato su 6 diramazioni su 10 e ora lo è su tutte e dieci; i plurali e gli `id` di `LibraryIndexStatus`, prima non testati; i bottoni della card, che ora sanno di un job di copia in corso come già lo sapeva l'aggiornamento automatico (`LibraryIndexCommandGate`, con **il motivo scritto** e non solo un bottone grigio); `NSTemporaryDirectory()`, tolto dall'allow-list delle posizioni valide quando l'app gira davvero; e l'avviso della card, che non nasce più dentro l'`onConfirm` dell'alert che lo produce.

**Il sesto è stato affrontato ma resta aperto, e la ragione è dimostrata.** I debiti di verifica scadono in blocco se l'orologio di sistema salta in avanti. La metà univoca è chiusa — se l'orologio torna **indietro** non si pota niente — ma il salto in avanti è **indistinguibile dai soli timestamp** da un'app rimasta chiusa a lungo: 40 giorni di assenza e un orologio spostato di 40 giorni danno esattamente la stessa lettura. La prima versione della guardia le trattava allo stesso modo e ha fatto fallire tre test esistenti della scadenza: non correggeva un difetto, spegneva una funzione voluta. Il limite è ora **codificato in un test** (`testForwardJump_stillExpiresInBulk_acceptedLimit`) invece di restare implicito. Il verso resta innocuo — nessun file si perde, si svuota una lista di precedenza — e chiuderlo richiede un riferimento monotono che sopravviva ai riavvii, che non abbiamo.

---

## Build e distribuzione

- Compilare: `Cmd+B` (o `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`)
- Testare: `Cmd+U` (o target `AppBackupFotoTests` via `xcodebuild ... test`)
- Distribuire: Product → Archive → Distribute → Custom → Copy App → sostituisci in /Applications → ri-aggiungi in System Settings → Privacy → Full Disk Access
- **Una build con anche un solo warning che contiene `actor-isolated` non è verde** (2026-09-19, BUG-7): è un salto reale sul main thread a runtime, non un avviso di stile. In Debug il target app ha `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` proprio per questo — vedi `.claude/rules/architecture.md`, sezione «Isolamento MainActor di default».

---

## Team di sviluppo (aggiornato 2026-08-16)

Questo progetto usa il workflow a ruoli espliciti descritto in `~/.claude/docs/specs/2026-08-11-agent-role-orchestration-design.md`: fase Architect (brainstorming → spec → piano, sempre con approvazione esplicita di Enrico) seguita da un team autonomo (Implementer + Code Reviewer + Security/Rules Auditor, ruoli globali in `~/.claude/agents/`) che esegue tutti i task del piano fino in fondo, con un solo checkpoint umano a fine intervento (eccetto blocchi reali che richiedono una decisione di Enrico).

**Sostituisce la vecchia regola "Pattern Advisor"**: non serve chiedere conferma prima di ogni dispatch. Dal 2026-08-31 Implementer, Code Reviewer e Security/Rules Auditor girano su **Sonnet 5** — scrivere codice su una spec già decisa, cercare pattern noti e fare audit di sicurezza sono lavori meccanici, e i subagenti sono la quasi totalità del consumo. **Architect resta su Opus 5**: il ragionamento architetturale è l'unico punto in cui il modello grande si ripaga, ed è circa il 2% del consumo. (Fino al 2026-08-30 giravano tutti su Opus 5.)

Gate automatici attivi su questo progetto (vedi `.claude/settings.json`): un hook blocca la scrittura sotto `Log/`, un hook blocca la fine sessione se `ContentView.swift`/i test sono stati modificati senza un build/test verde successivo, e un hook blocca i comandi git distruttivi (`push`, `reset --hard`, `clean -f`, `branch -D`, `checkout .`, `restore .`) prima che vengano eseguiti — `git add` e `git commit` restano liberi.

---

## Agent skills

Dal 2026-08-25 questo progetto ha installate le 25 skill di [mattpocock/skills](https://github.com/mattpocock/skills) v1.2.3 in `.claude/skills/`, **solo a livello di progetto**, in prova. Sono complementari ai ruoli sopra, non li sostituiscono: i ruoli dicono *chi* fa il lavoro, le skill *come* si fa.

### Issue tracker

Le issue vivono come markdown in `Docs/superpowers/tickets/`, non su GitHub — il repo è pubblico e questo progetto maneggia credenziali S3. Vedi `Docs/agents/issue-tracker.md`.

### Triage labels

Le cinque etichette canoniche (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), usate come valori della riga `Status:` nei file di ticket. Vedi `Docs/agents/triage-labels.md`.

### Domain docs

Layout single-context, tutto sotto `Docs/` (non alla root). Vedi `Docs/agents/domain.md`.

### Cautele

- **`/code-review`**: la skill di mattpocock ha lo stesso nome del built-in di Claude Code e lo shadowa in questo progetto. È voluto — controlla Standards + Spec invece di cacciare bug. Il ruolo Code Reviewer usa questa.
- **`/research`**: non usarla, ha un bug di ricorsione noto (#530) che spawna run duplicate. Usa la `deep-research` globale.
- **`/wizard`**: in fase di scoping legge i file `.env*`. Qui non ce ne sono, ma le credenziali S3 stanno in `rclone.conf` e nel Keychain: tienilo presente se un giorno ne aggiungi uno.
- **`/diagnosing-bugs`**: fa incollare output e artefatti di debug nei ticket. Redigi tu i segreti — l'issue upstream sul redacting automatico (#674) è aperta.

---

## Progettazione prima dell'implementazione

Il rapporto da tenere è: **più progettazione a monte, meno implementazione a caso**. Regole vincolanti.

**Quando serve l'Architect.** Per ogni modifica non banale si consulta *prima* l'Architect per un piano, e solo dopo si passa il piano all'Implementer. Una modifica è non banale se ricade in almeno uno di questi casi:

- tocca più di un file;
- cambia un'interfaccia (firma pubblica, protocollo, contratto fra tipi);
- cambia uno schema dati (schema SQLite dell'indice, formato di un file su disco, formato di un ticket o di un log);
- tocca un flusso di autenticazione o di credenziali (Keychain, `rclone.conf`, chiavi S3, firma/notarizzazione);
- aggiunge una dipendenza (package Swift, tool esterno, servizio).

Sotto questa soglia — fix di una riga, rinomina locale, correzione di un commento o di un test isolato — si va diretti all'Implementer senza piano.

**L'Implementer esegue piani, non li inventa.** Riceve un task alla volta, con il testo esatto preso dal piano. Se la richiesta è ambigua, incompleta o in conflitto con il codice che trova, **non improvvisa e non "interpreta"**: la rimanda all'Architect (via `SendMessage`) e aspetta un piano aggiornato. Scoprire a metà task che serve una decisione di design è un motivo valido per fermarsi e rimbalzare, non per scegliere da soli.

**Le decisioni architetturali si scrivono.** Ogni decisione di design presa dall'Architect e approvata va registrata in `Docs/adr/` come file numerato progressivamente (`NNNN-titolo-in-kebab-case.md`, continuando la numerazione esistente). Ogni ADR contiene:

1. **Contesto** — qual era il problema e quali vincoli erano in gioco;
2. **Opzioni valutate** — le alternative considerate davvero, non solo quella scelta;
3. **Decisione e motivo** — cosa si è scelto e *perché*, incluso cosa si accetta di perdere.

Un ADR si scrive prima che l'Implementer parta, non dopo. Gli ADR esistenti (`0001`–`0004`) sono il modello di riferimento per tono e lunghezza.

---

## Regole di lettura dei file

Regole operative per non sprecare contesto (e token) durante una sessione.

- **Non rileggere file interi già letti in questa sessione.** Se serve ricontrollare un punto preciso, rileggi solo quel punto.
- **Per cercare si usa Grep, non Read.** Read serve quando sai già dove guardare; se stai ancora cercando *dove* si trova qualcosa, la risposta è Grep (o Glob per i nomi di file).
- **Sui file grandi leggi porzioni mirate**, con `offset`/`limit` attorno alla zona che ti interessa, invece di caricare tutto il file. Vale in particolare per `ContentView.swift`.
- **Non incollare output lunghi nel contesto** — log, dump, elenchi di file, output di build. Filtra prima alla fonte con `grep`, `head`, `tail`, `wc -l`, e porta dentro solo le righe che servono davvero.

---

## Come iniziare una sessione

Leggi questo file, poi leggi `ContentView.swift`, poi affronta il primo obiettivo futuro aperto (vedi sopra). Non fare assunzioni sul codice senza averlo letto prima.
