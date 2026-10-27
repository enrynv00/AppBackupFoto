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

1. **Zero delete.** Nessun percorso di codice cancella un file foto. **Due porte sole.** *La prima, aperta il 2026-08-27*: il pannello Doppioni può spostare nel **Cestino del volume** (`FileManager.trashItem`) copie byte-identiche di file che restano presenti sull'SSD — **dal 2026-10-05 (ADR-0017) solo se l'ultimo inventario, completo su SSD, HDD e Cubbit e più recente dell'ultimo backup o import, certifica quella foto al sicuro su tutti e tre gli archivi e vede ogni copia del gruppo sull'SSD con lo stesso contenuto; la freschezza si ricontrolla prima di ogni blocco — e mai una copia in «Foto iPhone» il cui originale c'è ancora nella libreria Foto del Mac (dal 2026-10-05, ADR-0018: il backup la ricopierebbe), ricontrollata dal vivo subito prima di spostare; se la libreria Foto non si lascia leggere, nessuna copia in «Foto iPhone» si sposta** — e solo dopo che ogni membro del gruppo, **la copia tenuta compresa**, è stato riletto e rihashato dal disco con esito unanime, e dopo che l'utente ha spuntato i gruppi, letto un riepilogo dettagliato e confermato. Anche lì: mai `removeItem` su un file foto, mai uno svuotamento del Cestino, mai un file la cui unica copia sparisce. *La seconda, aperta il 2026-10-10 (ADR-0019)*: la sezione «Copie già tolte dall'SSD» della finestra Inventario può togliere dall'**HDD** e da **Cubbit** solo le copie che la storia degli spostamenti dell'SSD dice già uscite dall'SSD, una alla volta, e per ciascuna solo se l'ultimo inventario — completo su SSD, HDD e Cubbit e più recente dell'ultimo backup o import, ricontrollato prima di ogni blocco — vede la copia che l'SSD ha tenuto presente sull'SSD e identica sullo stesso archivio (sull'HDD stesso contenuto letto, su Cubbit stessa certificazione per contenuto), la copia da togliere non più sull'SSD e con un percorso diverso dalla tenuta; e solo dopo che, subito prima di toglierla, l'app ha ricontrollato dal vivo l'SSD (la copia non c'è, la tenuta c'è) e l'archivio (sull'HDD rilette e rihashate entrambe le copie, su Cubbit entrambe chieste con una HEAD) e ha scritto la riga del registro. Sull'HDD la copia va nel **Cestino dell'HDD** (`trashItem`, stesso volume), mai `removeItem`, e l'app non lo svuota mai. Su Cubbit si toglie con un DELETE **senza versione**, solo se le versioni del bucket sono accese e le regole fanno sparire le versioni vecchie di tutto il bucket e mai prima di 30 giorni (lette prima di ogni blocco, mai cambiate dall'app); un DELETE che non crea il segno di cancellazione ferma tutto; l'unico DELETE con versione ammesso toglie un segno di cancellazione registrato, per annullare. Sempre dopo un controllo senza togliere, un riepilogo e una conferma. Tutto il resto del progetto resta a zero delete.
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga. **Unica eccezione, aperta il 2026-10-05 (ADR-0016)**: la riparazione «2 su 3» della finestra Inventario può sostituire la copia di una foto in UN archivio (SSD, HDD o Cubbit) solo se gli altri due hanno la stessa copia certificata e quella da sostituire è dimostrata diversa; solo dopo aver riletto dal vivo tutte e tre le copie; solo dopo aver messo da parte la copia da sostituire in `_quarantena/<giorno>/<percorso>` sullo stesso archivio — su disco con un `rename` sullo stesso volume, su Cubbit con una copia lato server verificata — mai cancellandola; una foto alla volta, dopo un riepilogo e una conferma. La cartella `_quarantena` la svuota solo l'utente. Il backup resta zero-overwrite.
3. **Read-only sulla sorgente.** La Libreria Foto del Mac non viene mai modificata, in nessun caso. Sull'SSD le sole scritture ammesse oltre alle copie di backup sono lo spostamento nel Cestino del punto 1 e la riparazione del punto 2 (la copia diversa spostata in `_quarantena`, la copia buona scritta al suo posto). Nessun'altra funzione scrive sull'SSD: la seconda porta del punto 1 (ADR-0019) legge l'SSD e non lo tocca mai. L'inventario (ADR-0015) legge SSD, HDD e Cubbit e scrive solo nel database dell'app sul Mac; dalla stessa finestra scrivono solo «Ripara…» (punto 2) e «Togli le copie…» (punto 1, seconda porta, solo su HDD e Cubbit).
4. **Dry-run prima di ogni nuova operazione di sync**: qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione.
5. **Confronto sempre esplicito**: prima di copiare, il codice deve verificare esplicitamente che il file di destinazione non esista già.
> I punti **1** e **3** sono stati riscritti il **2026-08-28** (testo approvato da Enrico, riportato parola per parola dalla spec `Docs/superpowers/specs/2026-08-27-duplicates-panel-design.md`, sezione «La regola assoluta cambia»). Prima dicevano «nessuna cancellazione in nessun caso» e «la sorgente viene solo letta»: con il pannello Doppioni sarebbero diventati **falsi**. Una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa, che qualcuno prima o poi estenderà. Il motivo e la data stanno in **ADR-0005**.
> I punti **2** e **3** sono stati riscritti il **2026-10-05** (testo approvato da Enrico, ADR-0016): con la riparazione «2 su 3» sarebbero diventati falsi. Stessa ragione del 2026-08-28: una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa.
> Il punto **1** ha guadagnato la condizione sull'inventario il **2026-10-05** (testo approvato da Enrico, ADR-0017): con i doppioni certificati la porta del Cestino ha una condizione in più, e una regola assoluta che non elenca tutte le sue condizioni è un'eccezione silenziosa.
> Il punto **1** ha guadagnato la condizione sulla libreria Foto il **2026-10-05** (ADR-0018): stessa ragione di ADR-0017.
> I punti **1** e **3** sono stati riscritti il **2026-10-10** (testo approvato da Enrico, ADR-0019): con i doppioni su HDD e Cubbit sarebbero diventati falsi. Stessa ragione del 2026-08-28: una regola assoluta che diventa falsa e non viene riscritta è un'eccezione silenziosa.

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

    THEN verifica che il percorso sia dentro la root della libreria (l'SSD per i Doppioni, l'HDD per ADR-0019), confrontato per componenti canoniche

    THEN verifica che il file sia stato riletto e rihashato, e che l'intero gruppo sia unanime

    THEN verifica che il file tenuto non sia fra quelli passati a `trashItem`

    THEN verifica che il percorso di destinazione sia registrato prima di procedere al file successivo

    THEN verifica che ogni gruppo sia coperto da una `DuplicateCertification` fresca (ADR-0017) e che `DuplicateCertification.runBlock` si ricontrolli prima di ogni blocco

    THEN verifica che nessuna copia in `Foto iPhone/` ancora presente nella libreria Foto del Mac arrivi a `trashItem` (`Decision.keptByPhotosLibrary` + ricontrollo dal vivo in `DuplicateTrasher`, ADR-0018)

    THEN, sull'HDD (ADR-0019): verifica che la copia venga dalla storia degli spostamenti (`AlignmentPlanner`), che copia e tenuta siano state rilette e rihashate entrambe, che l'SSD sia stato ricontrollato dal vivo (copia assente, tenuta presente), che `st_dev` dell'HDD e dell'SSD si ricontrolli a ogni copia e che la riga `pending` del registro sia scritta prima di `trashItem` e `removed` prima della copia successiva (`ArchiveAligner.runHDDBlock`)

IF il codice fa chiamate S3 (PUT, DELETE, COPY):

    THEN verifica che non ci siano DELETE, con due eccezioni sole: AbortMultipartUpload su cancel (non tocca dati già scritti) e, da ADR-0019, `S3Syncer.deleteObjectForAlignment`/`removeDeleteMarkerForAlignment`, chiamate solo da `S3AlignmentCloud` per `ArchiveAligner` (`AlignmentDeleteGuardTests` conta le richieste DELETE nel sorgente)

    THEN verifica che PUT controlli esistenza remota prima di inviare

    THEN, unica eccezione (ADR-0016): `S3Syncer.replaceObjectForRepair` sovrascrive senza controllo di esistenza — verifica che la chiami solo `RepairEngine`, dopo una quarantena verificata con HEAD

    THEN verifica che una COPY (`CopyObject`) scriva solo dentro `_quarantena/`, su una chiave controllata prima con HEAD

    THEN, per il DELETE di ADR-0019: verifica che parta solo con `AlignmentCubbitSafety.evaluate` = `.ready` letto nello stesso blocco, dopo la HEAD della copia e della tenuta con dimensione ed ETag dell'inventario e la riga `pending` già scritta; che sia SENZA versione; che una risposta senza segno di cancellazione fermi la corsa

    THEN verifica che l'unico DELETE con `versionId` tolga un segno di cancellazione registrato, dopo `ListObjectVersions` che lo conferma segno e ultimo stato della chiave (`ArchiveAligner.undoCubbit`)

    THEN verifica che l'app non scriva mai la configurazione del bucket (versioni, regole): solo GET

IF il codice sposta o rinomina un file foto per la riparazione:

    THEN verifica che passi da `RepairEngine.renameWithoutOverwriting` (`rename(2)`, mai `moveItem`/`removeItem`), dentro la stessa radice, con la voce del registro già scritta

    THEN verifica che la copia buona sia stata preparata e riletta PRIMA di spostare quella rovinata

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

## Stato attuale (aggiornato 2026-10-27)

La data sopra vale per l'intera tabella. Se ci lavori, aggiornala: fino a oggi diceva 2026-07-29 mentre alcune righe erano già state riscritte al 2026-08-18, e il conteggio dei test era fermo a 139 su 346 reali. **Il primo tocco del 2026-09-19 era mirato**: solo la riga «Test automatici» sotto era stata aggiornata (fix di isolamento MainActor, BUG-7, 568 → 587 test). **Un secondo tocco, stesso giorno**: l'aggiornamento dell'elenco delle foto è diventato l'ultimo passo del backup invece di una lettura separata dopo la fine del job (spec `Docs/superpowers/specs/2026-09-19-index-refresh-as-backup-step-design.md`, ADR-0007) — aggiornate le righe «Backup automatico Mac→SSD», «Indice di contenuto della libreria» e «Test automatici» (587 → 617). **Terzo tocco, 2026-09-20**: «Annulla l'ultimo spostamento» (#34), il progresso della copia (#37), il controllo di spazio libero (#39) e il campione d'integrità (#33, aggiunta allo scope) sono usciti dal main thread (spec `Docs/superpowers/specs/2026-09-19-remaining-main-thread-work-design.md`, ADR-0009/0010) — aggiornate le righe «Indice di contenuto della libreria» (per il pannello Doppioni) e «Test automatici» (baseline di sessione 679, misurata su `main` con il lavoro successivo #38/#40 già incluso, → 756). **Quarto tocco, 2026-09-24**: `main` è stato portato a `fix/remaining-main-thread-work` con un fast-forward (nessuna riscrittura di storia), poi lo stesso schema di «Annulla l'ultimo spostamento» è stato applicato allo spostamento nel Cestino (ROADMAP #41, spec `Docs/superpowers/specs/2026-09-20-trash-progress-survives-window-close-design.md`) — aggiornate solo le righe «Indice di contenuto della libreria» e «Test automatici» (756 → 772). **Quinto tocco, 2026-09-25**: piano `Docs/superpowers/plans/2026-09-24-duplicates-at-real-scale.md` (ADR-0011/0012) — filtri, regola per cartella e corsa a più blocchi per i 27.798 gruppi reali; Task 12 (avviso di elenco stantio) e Task 14 (questa stessa passata di documentazione) chiusi, **Task 13 (mutation testing) non eseguito, dichiarato**. Aggiornate le righe «Indice di contenuto della libreria» e «Test automatici» (772 → ~854, stima dai delta — l'ultima misura indipendente del coordinatore, 837, è di poco prima dei Task 12/14). **Sesto tocco, 2026-09-29**: piano `Docs/superpowers/plans/2026-09-26-cross-store-inventory.md` (ADR-0015) — inventario certificato su SSD, HDD e Cubbit (#44), progetto 1 di 4 verso «una copia per archivio», implementato in sola lettura su `feature/cross-store-inventory`; Task 12 (questa stessa passata di documentazione) chiuso, **Task 13 (verifiche dal vivo) non ancora fatto**. Aggiunta la riga «Inventario certificato SSD/HDD/Cubbit (#44)» dopo «Indice di contenuto della libreria…», aggiornata la riga «Test automatici» (861 → 1.014, misurato) e aggiunto un punto alla «Regola assoluta» sulla sola lettura dell'inventario. **Settimo tocco, 2026-10-05**: piano `Docs/superpowers/plans/2026-10-04-repair-from-majority.md` (ADR-0016) — riparazione di una copia rovinata con la regola «2 su 3» (#45), progetto 2 di 4; riscritti i punti 2 e 3 della «Regola assoluta»; aggiunta la riga «Riparazione 2 su 3 (#45)» e aggiornata la riga «Test automatici». **Ottavo tocco, 2026-10-05**: piano `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md` (ADR-0017) — doppioni sull'SSD con la garanzia dell'inventario (#46), progetto 3 di 4; aggiunta una condizione al punto 1 della «Regola assoluta»; aggiunta la riga «Doppioni con garanzia (#46)» e aggiornata la riga «Test automatici». **Nono tocco, 2026-10-11**: piano `Docs/superpowers/plans/2026-10-10-archive-alignment-hdd-cubbit.md` (ADR-0019) — doppioni su HDD e Cubbit (#47), progetto 4 di 4; riscritti i punti 1 e 3 della «Regola assoluta» (la seconda porta del punto 1, DELETE su Cubbit nella checklist); aggiunta la riga «Doppioni su HDD e Cubbit (#47)» e aggiornata la riga «Test automatici» (1.266 → 1.412). Le altre righe restano alle date che portano già scritte, non sono state riverificate in questa sessione.

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
| Sidebar hamburger (Report Log, Ripristina, Importa foto, Configurazione, Tools, Foto, Doppioni, Controlla aggiornamenti, Aspetto, Lingua) | ✅ Implementata. «Catalogo» **rimosso il 2026-09-03** su richiesta di Enrico: lo sostituirà Immich (#29), che sfoglia per metadati invece che per cartelle. **«Doppioni» aggiunta il 2026-10-05** (ADR-0018, su richiesta di Enrico), accanto a «Inventario» |
| Grafico velocità real-time | ✅ Implementato (Charts, MB/s per S3, file/s locale) |
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256 (con **precedenza ai file copiati e mai verificati**, 2026-08-26), pulizia upload multipart orfani |
| Backup automatico Mac→SSD | ✅ Implementato — trigger su collegamento SSD, toggle on/off in Impostazioni, solo ad app aperta. **Dal 2026-09-19 include il passo 2**: a fine copia, se l'elenco esiste già e l'interruttore relativo è acceso, l'app aggiorna l'elenco delle foto sull'SSD come ultimo passo dello stesso job (stessa barra, stesso «Interrompi», riepilogo e notifica solo alla fine) invece che con una lettura separata dopo la fine del backup. Al collegamento dell'SSD non parte più nessuna lettura da sola |
| Gate Touch ID all'avvio (#30) | ✅ Implementato — `AuthGateManager` + `LockScreenView`, copre anche le finestre di primo livello Diagnostica/Foto/Doppioni. Verifica con Touch ID reale ancora da fare |
| Auto-update Sparkle (#18) | ✅ Implementato e verificato end-to-end con due release reali. **Catalogo backup (#12): rimosso il 2026-09-03** — vedi ROADMAP punto 12 |
| Indice di contenuto della libreria + dedup in import (#31) | ✅ **Nucleo implementato (2026-08-25/27)** — indice SHA256 SQLite delle foto/video dell'SSD in `~/Library/Application Support/AppBackupFoto/`, mai sull'SSD; card «Foto già salvate sull'SSD» in Diagnostica; durante un import non si ricopia un file il cui contenuto è già in libreria, né un doppione interno allo stesso import. **Pannello Doppioni implementato (2026-08-27 → 2026-09-01)**: finestra «Doppioni» dedicata, proposta spiegata a parole su quale copia tenere, lavoro a blocchi con riepilogo + conferma distruttiva, spostamento nel **Cestino del volume** con rilettura e rihash unanimi di tutto il gruppo, registro di ripristino proprio e «Annulla l'ultimo spostamento». È l'unica feature del progetto che rimuove file dalla loro posizione: leggere **ADR-0005** prima di toccarla. **Aggiornamento dell'elenco come passo 2 del backup (2026-09-19, ADR-0007)**: `LibraryIndexer.scan` emette avanzamento anche sui file invariati (`progressEvery`, la barra del passo 2 si muove davvero) e `total` parte dal numero di voci già in elenco invece che da 0. **«Annulla l'ultimo spostamento» fuori dal main (2026-09-20, ADR-0009, ROADMAP #34)**: nuovo motore `TrashRestorer` (stessa cura del cestinamento, `st_dev` a ogni fallimento, mai "già fatto" per errore), il registro ora ricorda quali foto sono già tornate (`restoredAt`) così una seconda pressione non mente più, conferma non distruttiva prima di partire («Rimetto a posto N foto spostate il ...»), mutua esclusione scritta con job/lettura/spostamento in entrambi i versi. Annullamento a **un solo livello** (decisione di Enrico): rimette a posto solo l'ultimo blocco, un blocco più vecchio resta recuperabile solo a mano dal Cestino. Restano due verifiche manuali dall'app (vedi sotto) più quelle nuove del Task 12 del piano del 2026-09-20 (col vero SSD collegato). **Lo spostamento nel Cestino non perde più barra e «Interrompi» chiudendo la finestra Doppioni (2026-09-24, ROADMAP #41)**: stesso schema nel runner, l'elenco non si ricarica mentre lo spostamento è in corso, e anche «Annulla l'ultimo spostamento» ora rivaluta il proprio motivo specifico all'avvio vero — verifiche dal vivo ancora da fare (ROADMAP #41). **Il pannello alla scala reale (2026-09-25, piano `2026-09-24-duplicates-at-real-scale`, ADR-0011/0012)**: 27.798 gruppi veri hanno richiesto filtri (cartella, interno/incrociato, coperti dalla regola) con selezione in massa sul solo insieme filtrato, una regola per cartella («tieni in X, cestina in Y») che persiste fra le sessioni, un tetto ripensato come granularità dei blocchi (non più un rifiuto) e una **corsa** che li smaltisce uno dopo l'altro con `DuplicateTrasher.run` invariato, più una storia degli spostamenti (`TrashHistory`) perché il registro di ripristino ricorda solo gli ultimi 2.000. I quattro simboli del blocco singolo di ROADMAP #41 (`startDuplicateTrashing` e le tre proprietà collegate) sono stati rimossi, sostituiti dalla corsa. **Mutation testing (Task 13 del piano) non ancora eseguito** — resta da fare prima di considerare l'intervento verificato in profondità. Dettagli in `.claude/rules/architecture.md`, decisioni in `Docs/adr/` |
| Inventario certificato SSD/HDD/Cubbit (#44) | ✅ **Fatto (2026-10-01, ADR-0015)**, unito a `main`. Finestra «Inventario» in sola lettura su SSD, HDD e Cubbit (sola lettura allora; da #45/ADR-0016 la stessa finestra può anche scrivere, con «Ripara…»), categorie ✅ ⚠️ 🔎 ❗ ⏳. Verifica dal vivo (2026-09-30/10-01): primo giro completo SSD 81 min, HDD 112 min, Cubbit 2 min, 0 file illeggibili, memoria max ~490 MB; confronto indipendente con rclone su ASUS 93.802 vs 93.799 (differenza: 2 .svg e 1 .psd, contati come immagini); nessun file scritto su SSD/HDD; il primo giro ha rivelato le forme alternative dell'ETag (parti da 128 MiB, formula «in testo»), riconosciute da `d708098`; secondo giro SSD 19 min, HDD 52 min, Cubbit 4 min: su 141.686 oggetti Cubbit resta 1 solo non confermato, ed e' una foto davvero rovinata su Cubbit (`Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, ultimi 38.796 byte a zero, integra su SSD e HDD: primo caso per il progetto 2). Verificati dal vivo anche «Interrompi» (SSD interrotto, HDD e Cubbit non raggiunti) e il rifiuto di partire con l'HDD scollegato. NON fatte dal vivo, per scelta di Enrico: HDD espulso a meta' lettura, mutua esclusione con un backup, chiusura/riapertura della finestra, chiavetta espulsa, Touch ID (coperte dai test automatici, non dal vivo). |
| Riparazione 2 su 3 (#45) | ✅ **Fatta (2026-10-05, ADR-0016)**, unita a `main`. Nella finestra Inventario, sotto ❗, «Ripara…» per le foto rovinate in un archivio e integre e identiche negli altri due: riepilogo, «Controlla senza riparare», conferma, ricontrollo dal vivo, quarantena `_quarantena/<giorno>/<percorso>`, scrittura, verifica, registro `repair-log.json`. Verifica dal vivo (2026-10-05): inventario completo, «Controlla senza riparare» sulla .heic (Cubbit minoranza, SSD sorgente, HDD testimone, quarantena del 2026-10-04 riconosciuta), riparazione vera: ETag su Cubbit passato da `24cb6533…` a `b59917c9…` (= SSD e HDD), copia rovinata intatta in `_quarantena/2026-10-04/…`, SSD e HDD non toccati (stessa data e dimensione), voce «repaired» in `repair-log.json`; inventario successivo: 0 oggetti Cubbit senza corrispondenza, 0 differenze SSD/HDD, ❗ = 0. |
| Doppioni con garanzia dell'inventario (#46) | ✅ **Implementato (2026-10-05, ADR-0017)** su `feature/certified-duplicates-ssd`. Nel pannello Doppioni un gruppo si spunta solo se l'ultimo inventario è completo su SSD, HDD e Cubbit, nessun backup o import ha scritto dopo l'inizio di quel giro (`ArchiveWriteClock`: fine dell'ultimo job o inizio dell'ultimo, il più recente), il contenuto è ✅ e ogni copia del gruppo è nell'inventario dell'SSD di quel giro; gli altri restano visibili con la casella spenta e il motivo; selezione in massa e regola per cartella li saltano e lo dicono; ricontrollo della freschezza prima di ogni blocco; il registro del Cestino e la storia degli spostamenti annotano il percorso tenuto (`keptPath`/`keptPaths`, relativo alla radice dell'SSD) per il progetto 4. **Corretto il 2026-10-05 (ADR-0018)**: una copia in `Foto iPhone/` il cui originale è ancora nella libreria Foto del Mac non si sposta mai (il backup Mac → SSD la ricopierebbe) — regola **1b** in `duplicateKeepChoice` (dopo la regola 1), `DuplicateBatch.nothingToMove`/`keptByPhotosLibraryCount`, ricontrollo dal vivo in `DuplicateTrasher` subito prima di ogni gruppo, voce «Doppioni» in più nel pannello laterale accanto a «Inventario». Verifica dal vivo (Task 5 del piano ADR-0018, che comprende il Task 7 di ADR-0017) ancora da fare — non marcarlo "fatto". | **Verifica dal vivo (2026-10-06/07)**: blocco piccolo spostato e annullato; backup che invecchia l'inventario e spegne le caselle; corsa completa di 46 blocchi (~89.400 copie, ~164 GB liberati sull'SSD dopo lo svuotamento del Cestino), HDD e Cubbit non toccati. Trovato dal vivo: le copie in «Foto iPhone» tornavano col backup (ADR-0018), con la sola data restava la copia in ASUS (ordine di cartelle scelto da Enrico, regola 1c), 11 file con flag «Bloccato» (uchg, da exFAT/Windows) fermavano la corsa: sbloccati a mano, elenco in ~/Documents/AppBackupFoto-file-sbloccati-2026-10-06.txt.
| Doppioni su HDD e Cubbit (#47) | ✅ **Fatto e verificato dal vivo (HDD 2026-10-14, Cubbit 2026-10-15; 89.436 copie per archivio; inventario finale del 2026-10-27 senza ⚠️ né ❗), su `main`**, ADR-0019. Nella finestra Inventario, sezione «Copie già tolte dall'SSD»: toglie da HDD (Cestino dell'HDD, `trashItem`) e da Cubbit (DELETE senza versione, con le versioni del bucket accese e la regola dei 30 giorni lette prima di ogni blocco) solo le copie che la storia degli spostamenti dell'SSD (`TrashHistoryReader` su `trash-history.jsonl`) dice già uscite, con la copia che l'SSD ha tenuto (`keptPaths`), una alla volta; solo se l'ultimo inventario — completo su SSD, HDD e Cubbit e più recente dell'ultimo backup o import, ricontrollato prima di ogni blocco — vede la copia tenuta presente sull'SSD e identica sullo stesso archivio (`AlignmentPlanner`), e solo dopo un ricontrollo dal vivo subito prima di ogni copia (`ArchiveAligner.runHDDBlock`/`runCubbitBlock`: rilettura e rihash sull'HDD, HEAD su Cubbit tramite `S3AlignmentCloud`, con `AlignmentCubbitSafety.evaluate`). Registro in sola aggiunta (`AlignmentLogStore`), «Annulla l'ultimo blocco» (`ArchiveAligner.undo`/`undoCubbit`), corsa a blocchi dopo un controllo senza togliere, un riepilogo e una conferma, cancello `isAligning` in mutua esclusione con backup, inventario, riparazione e Doppioni, nei due versi. L'app legge versioni e regole del bucket ma non le scrive mai. Dopo un errore passeggero di Cubbit a metà corsa: le letture (HEAD, versioni, regole) si ritentano 3 volte, i DELETE mai (`RetryingAlignmentCloud`). |
| Formattazione disco guidata (#28) | ⏳ Codice completo e buildabile, **mai eseguito davvero** — nessun `diskutil eraseDisk`. Non marcarlo "fatto" |
| Immich (#29) | ⏳ **Avviato davvero il 2026-09-13**: VM, 4 container, libreria esterna, 47.479 media indicizzati, sola lettura confermata dall'interno del container. Restano i punti 8-10 della verifica (griglia/ricerca/facce, chiusura app → container fermi, lock screen). Non marcarlo "fatto" |
| Test automatici | ✅ **1.425 test XCTest** su `main` (2026-10-14: 1.412 del progetto 4 + 13 dei ritentativi su Cubbit; +159 rispetto ai 1.266 di prima del progetto 4). File nuovi dai doppioni su HDD e Cubbit (#47, ADR-0019): `AlignmentPlannerTests` (36, regole pure/storia/blocchi), `AlignmentLogTests` (13, registro in sola aggiunta), `S3AlignmentRequestsTests` (13, richieste a Cubbit e regola delle versioni), `AlignmentEngineHDDTests` (21, motore sull'HDD), `AlignmentEngineCubbitTests` (15, motore su Cubbit), `AlignmentUndoTests` (14, «Annulla l'ultimo blocco»), `AlignmentGatesTests` (9, mutua esclusione `isAligning`), `AlignmentStatusTests` (15, finestra Inventario e runner), `AlignmentDeleteGuardTests` (5, conta i DELETE nel sorgente). Esteso `MainThreadIsolationTests` (+5, `AlignmentPlanner`/`TrashHistoryReader`/`AlignmentLogStore`/`ArchiveAligner.runHDDBlock`/`runCubbitBlock`/`undo` fuori dal main). Firma estesa con `isAligning`, nelle sole chiamate (nessuna asserzione cambiata), in `DuplicatesStatusTests`, `InventoryRefreshTests`, `JobStartGateTests`, `LibraryIndexStatusTests`, `RepairGatesTests`. **Storia precedente — 1.262 test XCTest** su `feature/certified-duplicates-ssd` (2026-10-05, +43 rispetto ai 1.219 di prima). File nuovi dalla correzione delle copie nella libreria Foto (ADR-0018): `PhotosLibraryPresenceTests` (13), `DuplicatePhotosLibraryTests` (21: 14 nel Task 1, +1 nel Task 2, +6 nel Task 3); estesi `DuplicateTrasherTests` (+8), `MainThreadIsolationTests` (+1). **Storia precedente — 1.219 test XCTest** su `feature/certified-duplicates-ssd` (2026-10-05, +60 rispetto ai 1.159 di `main`). File nuovi dai doppioni certificati (#46, ADR-0017): `DuplicateCertificationTests` (30), `ArchiveWriteClockTests` (5), `DuplicateCertificationStatusTests` (17); estesi `TrashManifestTests` (+3), `TrashHistoryTests` (+2), `DuplicateTrasherTests` (+2), `MainThreadIsolationTests` (+1). **Storia precedente — 1.159 test XCTest** su `feature/repair-from-majority` (2026-10-05, +136 rispetto ai 1.023 di `main`). File nuovi dalla riparazione (#45, ADR-0016): `QuarantineExclusionTests` (10, il test di parità), `S3SignatureTests` (8, con i tre esempi pubblicati da AWS), `S3RepairRequestsTests` (9), `RepairRulesTests` (24), `RepairPathsTests` (7), `RepairLogTests` (7), `RepairEngineTests` (37), `RepairGatesTests` (9), `RepairStatusTests` (23); `MainThreadIsolationTests` +2. Firma estesa con `isRepairing` in `JobStartGateTests`/`LibraryIndexStatusTests`/`DuplicatesStatusTests`/`InventoryRefreshTests`, nessuna asserzione cambiata. **Storia precedente — 1.014 test XCTest misurati** su `feature/cross-store-inventory` (2026-09-29, +153 rispetto agli 861 di `main`). File nuovi dall'inventario (#44, ADR-0015): `ContentHasherTests` (15), `S3ETagMatcherTests` (16), `S3ListPageParserTests` (12, incluso il caso del token di continuazione vuoto), `InventoryStoreTests` (19), `InventoryScannerTests` (13, incluso il controllo `st_dev` isolato dopo il ciclo), `InventoryCubbitReaderTests` (8, incluso lo stesso caso del token di continuazione vuoto), `InventoryClassifierTests` (31, incluso il caso della collisione di percorso dentro un solo archivio — non è ❗, decisione del 2026-09-29; su Cubbit nessuna collisione trovata fra 219.877 chiavi), `InventoryRefreshTests` (10), `InventoryStatusTests` (15), `BackupRunnerStoreRootTests` (4: 3 del Task 0 di questo piano + 1 per BUG-10, già raccontato in `.claude/rules/bug-history.md`). File estesi per il cancello `isInventorying`: `DuplicatesStatusTests` (+2), `JobStartGateTests` (+1), `LibraryIndexStatusTests` (+2), `MainThreadIsolationTests` (+5). Il fix del token di continuazione vuoto (commit `4548ead`) è in `.claude/rules/architecture.md`, sezione `S3Syncer`/`parseListPage`. **Storia precedente — 861 test XCTest** su `main` dopo l'unione di `feature/duplicates-at-real-scale` (2026-09-26, BUG-8 e BUG-9 inclusi: +6 di `S3ListSpecialCharsTests`, BUG-8, copiato da `main`. Prima 855: suite completa verificata dal coordinatore il 2026-09-25 su macchina scarica, 0 fallimenti, 0 warning). **File nuovo del 2026-09-25** (piano `2026-09-24-duplicates-at-real-scale`, Task 12): `LibraryListFreshnessTests` (18, l'avviso "elenco stantio" a 14 giorni). **Rimossi lo stesso giorno**: 2 in `DuplicatesStatusTests` (`confirmationBlockedReason`, Task 11 — la funzione stessa è stata rimossa, non riscritta) e 1 in `DuplicateBatchTests` (`testSummary_saysWhenTheBatchIsTooBig`, Task 14 — la riga che verificava è stata tolta da `summaryLines()`, terza eccezione autorizzata alla regola 7 dei piani). **File estesi dal 2026-09-24** (ROADMAP #41): `DuplicatesStatusTests` +16 (`trashProgressLine`/`trashStoppingLine`/`headerLine(groupsKnown:)`, `DuplicatesPanelLoad.shouldLoadOnAppear`, un test mancante su `undoDisabledReason`/SSD scollegato). **File nuovi del 2026-09-20** (#34/#37/#39, ADR-0009/0010): `TrashRestorerTests` (~18), `ProgressThrottleTests` (7), `FileSyncerProgressThrottleTests` (4), `FreeSpaceCheckTests` (8), `TrashRestoreStatusTests` (14); `TrashManifestTests` (+7, registro che ricorda i ripristini) e `MainThreadIsolationTests` (+5, incluso il campione d'integrità del #33) estesi; `JobStartGateTests`/`LibraryIndexStatusTests`/`DuplicatesStatusTests` estesi con `isRestoringFromTrash` e `undoDisabledReason`. File nuovi dall'indicatore di spazio (2026-09-19, ADR-0008): `VolumeSpaceDisplayTests` (21), `VolumeCapacityReaderTests` (4), `S3ListingTests` (10), `CloudUsageStoreTests` (6), `CloudUsageTextTests` (12) — 53 test, UI (`VolumeSpaceLine`/`SpaceBar`/`CloudUsageLine`) e cablaggio in `VolumeMonitor.check()` dichiarati non coperti (SwiftUI/timer, non raggiungibili senza una corsa). File nuovo dal passo 2 del backup (2026-09-19): `BackupListStepTests` (33 test, logica pura del passo 2); 6 test rimossi in `LibraryIndexStatusTests` (`LibraryIndexAutoRefresh.shouldRun`, sostituita da `BackupListStep.shouldRun`). File nuovi dal fix di isolamento dello stesso giorno: `MainThreadIsolationTests`, `JobStartGateTests` — vedi BUG-7 in `.claude/rules/bug-history.md`. 40+ file in `AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256 (incluso il file che cambia dimensione mentre lo si legge), classificazione retry S3, lettura file a blocchi, logica AIMD del gate adattivo, ordinamento parti multipart, validazione endpoint S3, generazione docker-compose Immich verificata con parser YAML reale, esclusione dischi formattabili `DiskFormatter`, guardia self-import e slug etichetta, gli otto file nati dal nucleo di #31 (`IndexableKindTests`, `IndexEntryVerdictTests`, `LibraryIndexStoreTests`, `LibraryIndexerTests`, `LibraryIndexStatusTests`, `ImportDedupTests`, `UnverifiedCopiesStoreTests`, `FileSyncerHashVerificationTests`) e i sei del pannello Doppioni (`DuplicateGroupsStoreTests`, `DuplicateKeepChoiceTests`, `DuplicateBatchTests`, `TrashManifestTests`, `DuplicateTrasherTests`, `DuplicatesStatusTests`) |
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
