# I file non caricati su Cubbit si vedono, e il registro non perde l'inizio — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: APPROVATO da Enrico il 2026-10-27, con D1 = A, D2 = A, D3 = A, D4 = A, D5 = A, D6 = A** (tutte le raccomandate, sezione «Decisioni di Enrico»). Bozza scritta il 2026-09-26 su `main` a `1f6a9fb`; **riscritta il 2026-10-27 per `main` a `bacdaca`** (89 commit dopo, `git log --oneline 1f6a9fb..bacdaca`: inventario, riparazione, doppioni certificati, progetto 4 con `RetryingAlignmentCloud`; test da 772 a 1.425). Non c'è una spec separata: il problema è stato verificato leggendo il codice e il log reale `~/Downloads/backup_log_1790417439.txt` (sezione «Da dove nasce»).

**Base:** `main` a `bacdaca`, **branch nuovo** `fix/s3-upload-failures-visible`.

**Goal:** dopo un backup SSD → Cubbit con errori, Enrico può sapere **quali** file non sono stati caricati e **perché**, senza ricostruirlo a mano: (1) ogni file che non si carica lascia una riga nel log, (2) ogni riga di nuovo tentativo dice il motivo, (3) i tentativi passano da 3 (attese 1 s, 2 s) a 5 (attese 1, 2, 4, 8 s), (4) il log completo di ogni job finisce su un file in `~/Library/Logs/AppBackupFoto/`, il bottone «Salva» della scheda Log esporta quel file intero e non più solo gli ultimi 60.000 caratteri, e il riepilogo di fine job elenca i file non caricati.

**Architecture:** tre tipi puri nuovi (`FailedFile`, `S3UploadText`, `UploadFailureSummary`), un enum per l'esito di ogni file (`S3Syncer.FileUploadOutcome`) e un tipo che scrive su file (`JobLogFile`), tutti `nonisolated`. `S3Syncer.retrying` delega a una funzione nuova, `S3Syncer.runWithRetry`, che riceve l'attesa e l'interruzione dall'esterno e quindi si prova senza rete e senza attese vere. In `S3Syncer.sync` cambia **solo** cosa restituisce il task di ogni file e cosa fa il ciclo degli esiti. `BackupRunner` apre un `JobLogFile` a inizio job e lo alimenta da `append(_:)`, l'unico punto da cui passano tutte le righe del log. **Nessuna richiesta S3 aggiunta, tolta o spostata** (solo ripetuta più volte, punto 3). **Nessun cambiamento a `AdaptiveUploadGate`/`AdaptiveLimiter`, a `isRetryable`, a `FirstFailureRecorder`, alla finestra di 32 file, a `readFileInChunks`, all'abort del multipart, a `RetryingAlignmentCloud`.**

**Tech Stack:** Swift 5.x, isolamento MainActor di default, *Approachable Concurrency*, SwiftUI, XCTest. Nessuna dipendenza nuova.

---

## Da dove nasce (verificato il 2026-09-26)

- Job SSD → Cubbit chiuso con **102 errori**. Il log salvato (`backup_log_1790417439.txt`) è lungo **esattamente 60.000 caratteri** e comincia a metà di una riga (`ATUS: Carico: …`): è il buffer `BackupRunner.output`, tagliato da `append(_:)` a `maxOut = 60_000`. L'inizio del job è perso.
- Nel log ci sono **99** righe `Errore di rete su <key>, riprovo tra Ns (tentativo k/3)`: 65 al tentativo 2, 34 al tentativo 3. Quasi tutte su video `.mp4` grandi, spesso `(parte N)` di un multipart; una sola su un `.jpg`. **Nessuna** dice il motivo.
- **Nessuna riga dice quale file è fallito davvero.** In `S3Syncer.sync`, il `catch` dentro `group.addTask` restituisce `ok: false` e il ciclo degli esiti fa solo `result.errors += 1`. Gli errori che non si ritentano (4xx, file illeggibile) non producono **nessuna** riga.
- Le righe del log non hanno orario: non si può dire se i tentativi sono concentrati in un minuto (interruzione di rete) o sparsi su ore (Cubbit lento).
- **Dopo (memoria di progetto del 2026-09-26, non riverificato qui):** quegli errori venivano da NordVPN attiva; spenta, i 102 file si sono caricati. La causa l'ha trovata Enrico a mano: è esattamente la diagnosi che questo piano rende possibile dal log.

## Cosa è cambiato su `main` dal 2026-09-26 (verificato il 2026-10-27 su `bacdaca`)

Ogni nome citato dalla bozza è stato riletto sul codice di `bacdaca`. Esistono ancora tutti, con queste differenze:

| Cosa | Su `bacdaca` | Effetto sul piano |
| :--- | :--- | :--- |
| `ContentView.swift` | 21.732 righe (13.428 a `1f6a9fb`) | nessuno: si cerca con `grep -n`, mai col numero di riga |
| `S3Syncer.retrying(key:maxAttempts:onStatus:operation:)` | identica (3 tentativi, attese 1-2 s, riga senza motivo) | come da bozza |
| `S3Syncer.isRetryable` | ora `nonisolated static`: la chiama anche `RetryingAlignmentCloud` (progetto 4) fuori dal main | **non si tocca** (regola 4): è la regola condivisa fra i due ritentativi |
| `S3Syncer.sync` | identica nella parte che cambia (task figlio con `ok: Bool`, ciclo degli esiti con la guardia di stop in testa) | come da bozza |
| `S3Syncer.S3HTTPError` | `struct` dentro `S3Syncer`, non annotata | **il rimedio previsto dalla bozza non serve**: leggerla da `S3UploadText` (`nonisolated`) non dà warning (provato) |
| `FileSyncer` | ora `nonisolated final class` (BUG-7), quindi `FileSyncer.SyncResult` è `nonisolated` | `FailedFile` deve essere `nonisolated` (lo è) |
| `BackupRunner.run(label:refreshesLibraryIndex:work:)` | `JobStartGate.blockedReason` con sei parametri (`isAligning` compreso) e `ArchiveWriteClock.markStarted()` prima di `output = ""` | il registro si apre dopo tutte e due |
| `BackupRunner.stop()`, `finishCopyStep`, `finishJob`, `append(_:)`, `maxOut` | invariati | come da bozza |
| `CompletionSheet`, `SpeedLogPanel` (bottone «Salva»), `JobStats` | invariati; un solo chiamante di `SpeedLogPanel(` in `ContentView` | come da bozza |
| `S3SyncerRetryTests` | 8 test su `isRetryable`; ID pbxproj `0B024A051625E6BF5881555E` / `2EB4FE6309D38F1A70CB575B` invariati | come da bozza |
| `MainThreadIsolationTests` | 29 test | +1 |
| `RetryingAlignmentCloud` (nuovo, progetto 4) | ritenta le sole **letture** del progetto 4 (attese 2, 5, 15 s, attesa a fette, nessuna riga nel log); i DELETE mai | **resta separato**, vedi sotto |
| Test host (BUG-10, 2026-09-28) | sotto `xcodebuild test` l'app gira con le cartelle vere dell'utente; `backupRunnerStoreRoot` porta i suoi file in una cartella temporanea | **nuovo**: anche `JobLogFile.defaultDirectory()` sotto test punta a una cartella temporanea |
| `AlignmentDeleteGuardTests` | conta nel sorgente `httpMethod = "DELETE"` = 3 | resta 3 (verificato sul prototipo) |
| Numerazione | ADR fino a `0019` con `0014` **lasciato libero** per questo piano; ROADMAP fino a `#48` con `#43` **libero**; BUG fino a `BUG-10` | ADR-0014 e ROADMAP #43 restano; **BUG-8 è già preso** (lista S3 con `+`/apostrofo): questo diventa **BUG-11**; il ticket D4 diventa **ROADMAP #49** (il #44 della bozza è l'inventario) |

**`RetryingAlignmentCloud` e `runWithRetry`: separati, decisione dell'Architect (non serve una decisione di Enrico).** Condividono già l'unica cosa che deve essere una sola, `S3Syncer.isRetryable` (cosa è passeggero). Il resto è diverso apposta: lì si ritentano **letture** con attese lunghe (2-5-15 s) spezzate da «Interrompi» ogni 250 ms e senza riga nel log, qui **scritture** del backup con attese brevi, una riga col motivo, e la cancellazione del job già gestita dalla `URLSession`. Unificarle cambierebbe il motore del progetto 4, verificato dal vivo su 89.436 copie: fuori scope e senza guadagno. Il doc-comment di `runWithRetry` lo scrive, così nessuno le "unifica" credendole un doppione.

## Decisioni di Enrico (2026-10-27)

| # | Domanda | Risposta | Cosa vuol dire nel codice |
| :--- | :--- | :--- | :--- |
| D1 | Quanti file di log tenere in `~/Library/Logs/AppBackupFoto/` | **A**: gli ultimi 50 job | `JobLogFile.keepCount = 50`; all'apertura di un job si tolgono i più vecchi, solo file regolari con il nome esatto `backup_AAAA-MM-GG_hh-mm-ss.log`, nella sola cartella dell'app. È **una `removeItem` nuova**: la rivede il Security/Rules Auditor (Task 6) |
| D2 | Il motivo porta anche il codice tecnico | **A**: frase semplice più `(codice N)`, stesso testo nell'app e nel file | `S3UploadText.reason(for:)` |
| D3 | Il gate adattivo deve sentire anche i tentativi falliti poi riusciti | **A**: gate invariato; si misura su un backup vero e si decide dopo | nessuna riga cambia in `AdaptiveUploadGate`/`AdaptiveLimiter`; costo scritto nel doc-comment di `uploadMaxAttempts` e nell'ADR |
| D4 | Lo stesso buco nelle copie locali (`FileSyncer.syncFile`) | **A**: ticket separato | `FileSyncer.SyncResult.failedFiles` esiste ma `FileSyncer` non lo riempie; ROADMAP #49 |
| D5 | Il log su file vale per tutti i job | **A**: tutti | il file lo alimenta `append(_:)`, comune a tutti i job |
| D6 | Orario su ogni riga del file | **A**: sì; nell'app le righe restano come oggi | `JobLogFile.stamped` |

**Costo del punto 3, già deciso (5 tentativi, 1-2-4-8 s):** le attese sommano **15 secondi**. Un errore che arriva subito (`-1009`, Mac non collegato a Internet; `-1005`, connessione caduta) esaurisce i 5 tentativi in circa 15 secondi. Un'interruzione più lunga fa ancora fallire i file, che però con questo piano **si vedono** e vengono ripresi dal backup successivo. Un errore per risposta lenta (`-1001`) arriva solo dopo 300 secondi di silenzio (`timeoutIntervalForRequest`), quindi 5 tentativi possono tenere occupato uno slot fino a ~25 minuti, contro i ~15 di oggi. Non è una decisione nuova, solo il costo dichiarato di quella presa.

---

| Task | Cosa | Patch | Test nuovi | Totale atteso |
| :--- | :--- | :--- | :--- | ---: |
| 0 | branch da `main`, ADR-0014 | — | — | — |
| 1 | baseline misurata | — | — | **1.425** |
| 2 | `FailedFile`, `S3UploadText` | `02-upload-text.py` | `S3UploadTextTests` **nuovo** +16 | **1.441** |
| 3 | 5 tentativi, `runWithRetry`, motivo nella riga | `03-retry.py` | `S3SyncerRetryTests` +7 | **1.448** |
| 4 | `sync()`: esito per file, riga «Non caricato», elenco nel risultato | `04-sync-outcome.py` | `S3UploadTextTests` +2 | **1.450** |
| 5 | elenco fino al `CompletionSheet` e in fondo al log | `05-summary.py` | `S3UploadTextTests` +7 | **1.457** |
| 6 | `JobLogFile` | `06-job-log-file.py` | `JobLogFileTests` **nuovo** +19, `MainThreadIsolationTests` +1 | **1.477** |
| 7 | cablaggio in `BackupRunner` e «Salva» | `07-wiring.py` | nessuno (dichiarato) | **1.477** |
| 8 | mutation testing (copia nello scratch) | `mutants/mutants.py` | — | — |
| 9 | documentazione | — | — | — |
| 10 | verifiche dal vivo con Enrico | — | — | — |

**Conteggio atteso finale: 1.477** (`B` = 1.425 + 52). Con le patch copiate così come sono il numero è **esatto**, a ogni task. Fascia ammessa solo se un revisore chiede test in più e lo si dichiara nel commit: **1.477–1.487**. Sotto 1.477, o sopra senza una dichiarazione, ci si ferma a capire perché, non si aggiusta il numero.

**Due file di test nuovi**, registrati in `AppBackupFoto.xcodeproj/project.pbxproj` nei **4 punti** (`PBXBuildFile`, `PBXFileReference`, figli del gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`), accanto alle righe del modello `S3SyncerRetryTests.swift` (`0B024A051625E6BF5881555E` / `2EB4FE6309D38F1A70CB575B`). Lo fa `apply.py`, con gli ID già scelti e controllati assenti dal pbxproj di `bacdaca`:

| File | `PBXBuildFile` | `PBXFileReference` |
| :--- | :--- | :--- |
| `S3UploadTextTests.swift` | `DC2CC96B22A4D122F6F6E4CE` | `F901D97C39FFEDA58D187B40` |
| `JobLogFileTests.swift` | `FA5F6A8DDFB9AB28A1BAA9BA` | `C53CCEF7AF2529DD863E818D` |

Senza registrazione il file compila ma sotto `xcodebuild` non gira, e la suite «passa» lo stesso (la verifica veloce invece lo esegue comunque): per questo ai punti di controllo si verifica **sempre** il totale in `Executed N tests` di `xcodebuild`, mai il solo `** TEST SUCCEEDED **`.

## Prototipo (verificato dall'Architect fuori da Xcode, 2026-10-27)

Tutto il codice e tutti i test di questo piano sono già scritti e provati in `/private/tmp/claude-501/s3-failures-plan/`:

- `proto/patches/02-…07-*.py`: una patch per task. Ogni «trova» compare **esattamente una volta** nel `ContentView.swift` di `bacdaca` (dopo le patch precedenti); la patch contiene il codice, i test nuovi, le aggiunte in coda alle classi di test esistenti e le righe del pbxproj. **È il testo vincolante del task**: le descrizioni qui sotto dicono cosa fa e perché, la patch dice come.
- `proto/apply.py`: sul repository, un task alla volta, `REPO=<repository> python3 proto/apply.py --only N` (con le patch precedenti già applicate); su una copia di `main`, `python3 proto/apply.py [N]` applica in ordine dalla 02 alla N (default: tutte). Fa **tutti** i controlli prima di scrivere: si ferma con «FERMO», senza scrivere niente di quella patch, se un «trova» non compare esattamente una volta, se la sostituzione c'è già, se un file di test nuovo esiste già o se un ID del pbxproj è già usato. Provato: applicate una per volta con `--only` danno esattamente gli stessi file della copia verificata; riapplicate una seconda volta si fermano tutte e sei senza scrivere niente.
- `fasttest.sh`: la verifica veloce (testo nella sezione «Comandi»), con `REPO` impostabile.
- `proto/diffs/task-N.diff`: il diff di ogni task rispetto al precedente, per i revisori.
- `proto/mutants/mutants.py` e `mutants.log`: i mutanti del Task 8 e i loro esiti.
- Misurato su copie di `main` (`git archive bacdaca`, mai il repository di Enrico), una per task, patch fino al task N: **1.425 → 1.441 → 1.448 → 1.450 → 1.457 → 1.477 → 1.477 test, 0 fallimenti, 0 warning app, 0 warning test**. `plutil -lint` del pbxproj: OK, 4 righe per file nuovo. `httpMethod = "DELETE"` nel sorgente: 3, come prima. `removeItem(` nel sorgente: da 9 a 10.
- Differenze volute del prototipo, solo lì: stub di Sparkle, niente `@main`, `isRunningUnderTests()` = `true`.
- **Non eseguiti** (SwiftUI, bookmark, rete veri): il cablaggio in `BackupRunner` e `SpeedLogPanel`, la sezione nuova di `CompletionSheet`, le richieste vere a Cubbit. Compilano (la verifica veloce compila tutto `ContentView.swift`), non girano.
- **Nessuna scrittura su `/Volumes`, nessuna richiesta a Cubbit, nessun accesso a `~/Library/Application Support/AppBackupFoto` né a `~/Library/Logs`, repository non toccato.**

Se `/private/tmp` è stato svuotato, il prototipo non si ricostruisce da questo piano: si chiede all'Architect di rigenerarlo.

## Comandi di build e test

**Su questo progetto `xcodebuild` impiega più di 10 minuti**, e un agente fermo 10 minuti senza output viene terminato (anche se aspetta un comando in background). Quindi:

1. **Verifica veloce, a ogni task** (~70 s, nessun lancio dell'app): `fasttest.sh`. Compila con `swiftc` il `ContentView.swift` di `$REPO` e **tutti** i file di `AppBackupFotoTests/` (copiandoli in `$SP`, `$REPO` non si tocca) con le impostazioni del target, e li esegue con `xcrun xctest`. Non vede il pbxproj, le risorse dell'app, il test host. **La lancia l'orchestratore**, non un subagente revisore se non serve.
2. **`xcodebuild` vero, in background, solo dall'orchestratore**, ai punti di controllo: fine del Task 3 (prima modifica al percorso S3), fine del Task 6 (pbxproj con due file nuovi) e fine del Task 7 (prima di unire). Con `run_in_background`, mai in primo piano, mai da un subagente. È la sola prova che soddisfa l'hook di fine sessione.

**Precondizione di ogni `xcodebuild test`:** nessun backup in corso nell'app di Enrico (`TEST_HOST` = l'app). Il Task 1 chiede il via libera; senza risposta esplicita non si lancia.

```bash
# 1. verifica veloce (una classe, o tutta la suite senza argomento)
REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto /private/tmp/claude-501/s3-failures-plan/fasttest.sh JobLogFileTests
REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto /private/tmp/claude-501/s3-failures-plan/fasttest.sh   # "Executed N tests, with 0 failures", 0 warning
# 2. xcodebuild, in background (run_in_background: true), poi attesa sul log
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
SP=/private/tmp/claude-501/s3-failures-plan
rm -rf $SP/dd && xcodebuild -scheme AppBackupFoto -configuration Debug -derivedDataPath $SP/dd build-for-testing > $SP/build.log 2>&1; tail -3 $SP/build.log
grep -E '\.swift:[0-9]+:[0-9]+: warning:' $SP/build.log | sort -u | wc -l      # atteso 0, sempre
xcodebuild test-without-building -scheme AppBackupFoto -destination 'platform=macOS' -derivedDataPath $SP/dd > $SP/test.log 2>&1; grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" $SP/test.log | tail -2
```

`fasttest.sh` è già in `/private/tmp/claude-501/s3-failures-plan/fasttest.sh` (non va nel repository). È lo stesso testo del piano `2026-10-05-certified-duplicates-ssd.md` («Comandi di build e test») con `REPO=${REPO:-…}` e `SP=${SP:-/private/tmp/claude-501/s3-failures-plan/fast}`.

**Nota su `JobLogFileTests.testJobLogFile_hasExactlyOneRemoveItem_insidePrune`** (legge `ContentView.swift` accanto alla cartella dei test, come `AlignmentDeleteGuardTests`, che su `main` passa già sotto `xcodebuild`). Se sotto `xcodebuild` fallisse con «Non trovo ContentView.swift» (TCC sulla Scrivania), non si indebolisce: si sposta il conteggio in uno script accanto a quello di `AlignmentDeleteGuardTests` e lo si scrive nel riepilogo.

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai col numero di riga.** I nomi citati sono stati letti a `bacdaca`.
2. **Il codice si copia dalla patch così com'è** (`apply.py`). Se un «trova» non si trova, o qualcosa non compila nel target vero, **fermati e rimanda all'Architect**: non adattarlo a tentativi.
3. **Zero warning** (in Debug `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`). Il rimedio che la bozza autorizzava su `S3HTTPError` **non serve** (provato). Qualunque warning `actor-isolated`: ci si ferma e si rimanda all'Architect.
4. **Regola assoluta.** Nessun diff di questo intervento aggiunge, sposta o rimuove una richiesta S3 (PUT, POST, DELETE, GET), una `copyItem`/`moveItem`/`trashItem`, o una scrittura sull'SSD o sull'HDD. L'**unica** `removeItem` nuova è la conservazione dei log (`JobLogFile.prune`, Task 6), e agisce solo dentro la cartella dei log dell'app. `AdaptiveUploadGate`, `AdaptiveLimiter`, `isRetryable`, `FirstFailureRecorder`, `RetryingAlignmentCloud`, l'abort del multipart, `readFileInChunks` e la finestra di 32 file in `sync()` **non cambiano di una riga**. Se ti accorgi di doverli toccare, fermati e rimanda all'Architect.
5. **Il log non scrive mai sull'SSD, sull'HDD né sotto `Log/` del repository.** La cartella è `~/Library/Logs/AppBackupFoto/` (`FileManager.urls(for: .libraryDirectory, in: .userDomainMask)`); sotto test una cartella temporanea (BUG-10); `JobLogFile` rifiuta `/Volumes` anche passando da un collegamento. I test usano cartelle temporanee e non toccano `/Volumes` né `~/Library/Logs`.
6. **Asserzioni esistenti:** nessuna cambia, e nessun test esistente si tocca se non per aggiungere test in coda alla classe (`S3SyncerRetryTests`, `MainThreadIsolationTests`). Gli 8 test di `S3SyncerRetryTests` su `isRetryable` restano identici.
7. **I testi a schermo stanno solo in tipi puri** (`S3UploadText`, `UploadFailureSummary`, `JobLogFile.closingLine`/`unavailableNote`), mai costruiti nella View né in `sync()`. Niente gergo: nessuno dei testi contiene `URLError`, `HTTP`, `multipart`, `timeout`, `retry`, `upload`, `NSError`, `Domain`, `S3HTTPError` (lo controlla `S3UploadTextTests.assertNoJargon`). «Cubbit», «SSD», «Log» e «parte N» vanno bene.
8. **Revisione** (`Docs/CLAUDE.md`, ciclo in due fasi) a ogni task, dal Code Reviewer sul diff (`proto/diffs/task-N.diff`, senza `xcodebuild`). **Security/Rules Auditor obbligatorio** sui Task 3 e 4 (percorso S3: nessuna richiesta nuova, zero-overwrite di `shouldUpload` invariato, abort invariato), sul Task 6 (`removeItem` nuova: checklist «IF il codice contiene operazioni FileManager» di `Docs/CLAUDE.md` più i punti del Task 6) e sul Task 7 (l'esportazione scrive solo dove l'utente ha scelto nel pannello «Salva»).
9. **Commit solo con verifica veloce verde** (0 warning, conteggio uguale all'atteso), e ai punti di controllo anche con `xcodebuild` verde. Un commit per task, messaggio in italiano nel formato dei commit esistenti, con le due righe di attribuzione della sessione che esegue (oggi `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` e `Claude-Session: …`). **Mai `git push`.**

---

### Task 0: branch e ADR-0014, prima del codice

**File:** `Docs/adr/0014-i-file-non-caricati-si-elencano-e-il-log-completo-sta-sul-mac.md` (nuovo), `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md` (questo piano).

- [ ] **Step 0:** `git status --short`: l'unico file non tracciato ammesso è questo piano. `git switch -c fix/s3-upload-failures-visible main`. `git rev-parse --short HEAD` → `bacdaca`, oppure un discendente: in quel caso `REPO=<una copia> python3 /private/tmp/claude-501/s3-failures-plan/proto/apply.py` su una **copia** del repository (`git archive HEAD`, mai sul repository) deve passare senza «FERMO» e `fasttest.sh` su quella copia deve dare 1.477 più i test aggiunti nel frattempo su `main`; se no, **fermati** e rimanda all'Architect.
- [ ] **Step 1:** Scrivi l'ADR con questo testo:

```markdown
# ADR-0014 — I file non caricati su Cubbit si elencano, e il registro completo di ogni job sta sul disco del Mac

**Data:** 2026-10-27
**Stato:** Accettata

## Contesto

Il 2026-09-26 un backup SSD → Cubbit si è chiuso con 102 errori e nessun nome: il `catch` del task di ogni file in `S3Syncer.sync` contava l'errore e basta, e le 99 righe di nuovo tentativo non dicevano il motivo. Il registro salvato dalla scheda Log era lungo esattamente 60.000 caratteri e cominciava a metà di una riga: `BackupRunner.output` è tagliato a `maxOut`, e «Salva» esportava quello. Le righe non avevano orario, quindi non si poteva distinguere un minuto di rete caduta da ore di Cubbit lento. La causa (una VPN accesa) l'ha trovata Enrico a mano. Numeri di ADR (0014) e ROADMAP (#43) erano stati lasciati liberi apposta il 2026-09-26. Piano: `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md`.

## Opzioni valutate

- **Alzare `maxOut`.** Scartata: la `Text` della scheda Log ridisegna tutta la stringa a ogni riga, lo stesso problema di prestazioni chiuso da ADR-0010; e un tetto più alto si supera comunque con un primo backup completo (~120.000 righe).
- **Solo l'elenco dei file non caricati nel riepilogo di fine job.** Non basta: si perde chiudendo il foglio, e non dice cosa è successo prima.
- **Il registro completo su file (scelta).** Un file per job in `~/Library/Logs/AppBackupFoto/`, sul disco del Mac: mai sull'SSD o sull'HDD, che sono archivi di foto, e lì dove macOS tiene i registri delle app (si apre anche con Console). L'ora su ogni riga. «Salva» esporta il file intero.
- **Conservazione:** tenere tutto (i file crescono per sempre: un primo backup verso Cubbit scrive qualche MB) oppure gli ultimi 50 job (scelta).
- **Tentativi:** restare a 3 (attese 1 e 2 s) oppure 5 (attese 1, 2, 4, 8 s, scelta); e, con 5, far sentire al gate adattivo anche i tentativi falliti poi riusciti oppure no (scelta: no, per ora).
- **Ritentativi condivisi con il progetto 4** (`RetryingAlignmentCloud`): scartato. Hanno in comune la sola regola su cosa è passeggero (`S3Syncer.isRetryable`), che resta una; per il resto lì si ritentano letture con attese lunghe che «Interrompi» spezza, qui scritture del backup con una riga di log.

## Decisione e motivo

Ogni file che non si carica lascia una riga «Non caricato: «percorso» — motivo» e finisce in `S3Syncer.SyncResult.failures`; `errors` e `failures` si muovono insieme, da un solo punto. Ogni nuovo tentativo dice il motivo. Il riepilogo di fine job elenca al massimo 8 file più «…e altri N», e l'elenco completo va in fondo al registro. Il registro di ogni job va in un file con l'ora su ogni riga; si tengono gli ultimi 50. I tentativi passano a 5, con attese 1, 2, 4, 8 secondi. Lezione: un contatore di errori senza l'elenco di cosa è fallito non è una diagnosi, è un allarme.

**Cosa si accetta di perdere.** (1) Il gate adattivo continua a ricevere un solo esito per unità di lavoro, quello finale: con 5 tentativi più errori si risolvono prima della fine, e il gate rallenta meno spesso di prima. Se i motivi raccolti diranno congestione, si farà sentire al gate anche ogni tentativo fallito; se diranno connessioni chiuse da Cubbit, no. (2) Uno slot resta occupato più a lungo: fino a 15 s di attese in più, fino a ~25 minuti se ogni tentativo scade dopo 300 s. (3) La conservazione è una cancellazione nuova (`removeItem`): solo file regolari con il nome esatto `backup_AAAA-MM-GG_hh-mm-ss.log`, direttamente nella cartella dei log dell'app, mai quello del job che parte, mai sotto `/Volumes` nemmeno passando da un collegamento. Nessuna foto può arrivarci. (4) Le righe che arrivano dopo la chiusura del job (aggiornamenti in ritardo) si vedono nell'app ma non nel file; l'elenco dei file non caricati entra prima, in modo sincrono. (5) Lo stesso buco nelle copie locali (`FileSyncer.syncFile`) resta: ticket a parte (ROADMAP #49).

**Per riaprire questa decisione** serve un backup vero in cui i motivi nel registro mostrino che 5 tentativi non bastano o sono troppi, o che il gate dovrebbe sentire i tentativi intermedi.

## Risposte di Enrico (2026-10-27)

D1 = A (ultimi 50 registri), D2 = A (codice fra parentesi nell'app e nel file), D3 = A (gate invariato, si misura prima), D4 = A (copie locali in un ticket a parte), D5 = A (registro per tutti i job), D6 = A (ora su ogni riga del file).

## Conseguenze

- Tipi nuovi, tutti `nonisolated`: `FailedFile`, `S3UploadText`, `UploadFailureSummary`, `S3Syncer.FileUploadOutcome`, `JobLogFile`. Funzione nuova `S3Syncer.runWithRetry`; `retrying` ne diventa un involucro e perde il parametro `maxAttempts`.
- `FileSyncer.SyncResult.failedFiles` e `JobStats.failedFiles` (non persistiti); `SpeedLogPanel` riceve `onSave`.
- Nessuna richiesta S3 nuova; nessuna riga cambiata in `AdaptiveUploadGate`, `isRetryable`, `RetryingAlignmentCloud`.
```

- [ ] **Step 2:** Commit solo documentazione (ADR e questo piano), sul branch. Se Enrico ha cambiato una risposta nel frattempo, **fermati** e rimanda all'Architect.

---

### Task 1: baseline misurata

- [ ] **Step 1:** `git branch --show-current` → `fix/s3-upload-failures-visible`; `git status --short` vuoto.
- [ ] **Step 2:** `fasttest.sh` (senza argomento, `REPO` = il repository): `Executed 1425 tests, with 0 failures`, 0 warning. Se il numero è diverso, `B` = quello misurato e tutti gli attesi si spostano della differenza.
- [ ] **Step 3:** **Chiedi a Enrico il via libera** («nessun backup in corso nell'app?»). Poi, in background, build pulita e suite con `xcodebuild`: 0 warning, `Executed 1425 tests`. Se i warning non sono 0, **fermati** e rimanda all'Architect.
- [ ] **Step 4:** Nessun commit.

---

### Task 2: i testi puri — perché un file non si è caricato

**Patch:** `proto/patches/02-upload-text.py`. **File:** `AppBackupFoto/ContentView.swift` (subito **prima** di `// MARK: - S3Syncer (native Swift, no rclone subprocess)`), `AppBackupFotoTests/S3UploadTextTests.swift` (**nuovo**, registrato nel pbxproj).

- [ ] **Step 1:** `REPO=/Users/enriconannivicenzi/Desktop/AppBackupFoto python3 /private/tmp/claude-501/s3-failures-plan/proto/apply.py --only 2`.
- [ ] **Step 2: cosa c'è.**
  - `nonisolated struct FailedFile: Equatable, Sendable { let path: String; let reason: String }` — `path` relativo alla radice dell'SSD, che per Cubbit coincide con la chiave.
  - `nonisolated enum S3UploadText`: `reason(for:)`, `retryLine(key:reason:delaySeconds:nextAttempt:maxAttempts:)`, `failedLine(key:reason:)`. Motivi: `-1009` «il Mac non è collegato a Internet», `-1005` «la connessione si è interrotta», `-1001` «Cubbit non ha risposto in tempo», `-1003/-1004/-1006` «Cubbit non è raggiungibile», altri errori di rete «problema di rete»; HTTP 429 «Cubbit ha chiesto di rallentare», 5xx «problema temporaneo di Cubbit», 403 «Cubbit ha rifiutato il file: credenziali o permessi», altri 4xx «Cubbit ha rifiutato il file», senza risposta «risposta di Cubbit non valida»; file sparito «il file non si trova più sull'SSD», file illeggibile (`S3` 13/14, errori di lettura di Foundation 256…511) «il file non si è potuto leggere dall'SSD»; il resto «errore imprevisto», mai il dominio. Sempre `(codice N)` in fondo (D2). `CancellationError` → «interrotto», senza codice: non si mostra mai, chi chiama esclude lo stop prima.
  - Righe: `Connessione difficile con Cubbit per «<key>»: <motivo>. Riprovo tra <N> secondi (tentativo <k> di <max>).` (al singolare «1 secondo») e `Non caricato: «<key>» — <motivo>. Il prossimo backup verso Cubbit lo riproverà da solo.`
  - **Differenza dalla bozza:** la riga «Non caricato» non dice più «Il file resta sull'SSD»: con il motivo «il file non si trova più sull'SSD» le due frasi si contraddirebbero sulla stessa riga. Resta vero in ogni caso che il prossimo backup lo riprova (`shouldUpload` carica ogni chiave assente). Il doc-comment di `reason(for:)` spiega il codice fra parentesi (D2) e il limite dichiarato del completamento multipart con risposta persa.
- [ ] **Step 3: i 16 test** (`S3UploadTextTests`): `testReason_notConnectedToInternet`, `testReason_networkConnectionLost`, `testReason_timedOut`, `testReason_cannotFindOrConnectToHost`, `testReason_otherURLError_keepsTheCode`, `testReason_http429`, `testReason_http5xx`, `testReason_http403`, `testReason_otherHttp4xx`, `testReason_httpWithoutResponse`, `testReason_fileVanishedFromSSD`, `testReason_fileUnreadable`, `testReason_unknownError_neverShowsTheDomain`, `testReason_everyReasonHasNoJargon_andACode`, `testRetryLine_saysKeyReasonWaitAndNextAttempt`, `testFailedLine_saysKeyReasonAndThatTheNextBackupRetries`.
- [ ] **Step 4:** `fasttest.sh S3UploadTextTests` → 16; `fasttest.sh` → **1.441**, 0 warning. (Sotto `xcodebuild`, al punto di controllo del Task 3, 1.425 + 7 = 1.432 vorrebbe dire `S3UploadTextTests` non registrato.)
- [ ] **Mutanti (verificati sul prototipo, vedi Task 8):** 2a `.timedOut` e `.networkConnectionLost` scambiati; 2b niente `(codice …)` nel ramo HTTP; 2c `retryLine` con `nextAttempt - 1`; 2d `S3UploadText` senza `nonisolated`.
- [ ] **Step 5:** Commit.

---

### Task 3: 5 tentativi, attese 1-2-4-8 s, e il motivo nella riga

**Patch:** `proto/patches/03-retry.py`. **File:** `AppBackupFoto/ContentView.swift` (`S3Syncer.retrying`), `AppBackupFotoTests/S3SyncerRetryTests.swift` (in coda alla classe).

- [ ] **Step 1:** `apply.py --only 3`.
- [ ] **Step 2: cosa c'è.**
  - `nonisolated static let uploadMaxAttempts = 5` (costante; `nonisolated` perché è il valore di default di `runWithRetry`, che Swift valuta fuori dal MainActor: senza, un warning di isolamento «main actor-isolated static property … nonisolated context» — provato) con il doc-comment **obbligatorio** sui tre costi: slot occupato più a lungo (≤ 15 s di attese, fino a ~25 minuti con `-1001`), gate che riceve solo l'esito finale (D3), 5 tentativi per ogni parte di un multipart.
  - `nonisolated static func retryDelaySeconds(afterFailedAttempt:) -> Double` = `pow(2, attempt - 1)`.
  - `static func runWithRetry<T>(maxAttempts:isCancelled:sleep:onRetry:operation:)`: il ciclo di `retrying` di prima, **stesso ordine dei controlli** (interruzione, poi `attempt < maxAttempts && isRetryable(error)`, poi l'attesa); `onRetry` riceve il motivo già in parole (`S3UploadText.reason`), il ritardo e il numero del tentativo successivo. Doc-comment: perché resta separato da `RetryingAlignmentCloud`.
  - `retrying(key:onStatus:operation:)` diventa un involucro: `isCancelled: { self.cancelled || Task.isCancelled }`, `sleep: Task.sleep`, `onRetry` costruisce `S3UploadText.retryLine` e la manda con `DispatchQueue.main.async { onStatus(msg) }` come prima. Il parametro `maxAttempts: Int = 3` **sparisce**: le quattro chiamate (`put`, avvio/parte/completamento del multipart) non lo passavano.
- [ ] **Step 3: i 7 test** (in coda a `S3SyncerRetryTests`, con un piccolo `RetryProbe` che registra chiamate, attese e tentativi): `testMaxAttempts_isFive`, `testDelays_are1_2_4_8`, `testRunWithRetry_retryableError_triesFiveTimesThenThrows` (5 chiamate, attese `[1, 2, 4, 8]`, lancia l'ultimo errore, `onRetry` con 2, 3, 4, 5), `testRunWithRetry_permanentError_doesNotRetry` (403: 1 chiamata), `testRunWithRetry_succeedsOnThirdAttempt` (42, 3 chiamate, attese `[1, 2]`), `testRunWithRetry_cancelled_doesNotRetry`, `testRunWithRetry_onRetryGetsThePlainReason`.
- [ ] **Step 4:** `grep -n "maxAttempts" AppBackupFoto/ContentView.swift`: ogni occorrenza è dentro `runWithRetry`, nella sua firma, in `retrying` (`Self.uploadMaxAttempts`) o in `S3UploadText.retryLine`.
- [ ] **Step 5:** `fasttest.sh S3SyncerRetryTests` → 15; `fasttest.sh` → **1.448**, 0 warning. **Punto di controllo `xcodebuild`** in background: 1.448, 0 warning.
- [ ] **Mutanti (verificati):** 3a `uploadMaxAttempts = 3`; 3b attesa `pow(2, attempt)`; 3c senza `isRetryable`; 3d senza il controllo dell'interruzione.
- [ ] **Step 6:** Security/Rules Auditor sul diff (nessuna richiesta S3 nuova o spostata; le stesse quattro chiamate passano da `retrying`). Commit.

---

### Task 4: `sync()` — ogni file non caricato lascia la sua riga

**Patch:** `proto/patches/04-sync-outcome.py`. **File:** `AppBackupFoto/ContentView.swift` (`S3Syncer.SyncResult`, `S3Syncer.FileUploadOutcome` nuovo accanto a `readFileInChunks`, `S3Syncer.sync`), `AppBackupFotoTests/S3UploadTextTests.swift`.

- [ ] **Step 1:** `apply.py --only 4`.
- [ ] **Step 2: cosa c'è.**
  - `S3Syncer.SyncResult`: `var failures: [FailedFile] = []` e `mutating func recordFailure(key:reason:)`, che incrementa `errors` **e** aggiunge. Doc-comment: `errors` e `failures` si muovono insieme, sempre e solo da qui.
  - `nonisolated enum FileUploadOutcome: Sendable { case uploaded, failed(reason: String), stopped }`. Il tipo del gruppo diventa `(url: URL, key: String, size: Int64, outcome: FileUploadOutcome)`.
  - Task figlio: uscita anticipata per stop → `.stopped`; `catch`: con lo stop → `.stopped`, altrimenti `.failed(reason: S3UploadText.reason(for: error))`. Il motivo si calcola **nel task figlio**: oltre viaggia solo il testo.
  - Ciclo degli esiti: **la guardia `if self.cancelled || Task.isCancelled { continue }` resta la prima riga**, invariata. Poi `switch`: `.uploaded` come prima; `.failed` → `result.recordFailure`, poi `S3UploadText.failedLine` via `DispatchQueue.main.async { onStatus(line) }`; `.stopped` → `continue` (irraggiungibile dopo la guardia, resta per lo `switch`, con il commento). `result.done += 1`, snapshot, `onProgress`, `addNext()`: identici.
- [ ] **Step 3:** rileggi `proto/diffs/task-4.diff`: nessuna riga fuori dal task figlio e dal ciclo degli esiti è cambiata. **Non** cambiano `addNext`, la finestra di `adaptiveConcurrencyCeiling`, la chiamata a `upload(...)` con `onStart`, il blocco `CloudUsageTotals.afterSync`.
- [ ] **Step 4: i 2 test:** `testRecordFailure_countsAndRemembers`, `testRecordFailure_errorsAlwaysEqualsFailuresCount`.
- [ ] **Step 5:** `fasttest.sh` → **1.450**, 0 warning.
- [ ] **Mutante (verificato):** 4a `recordFailure` che aggiunge senza incrementare `errors`. Il cablaggio in `sync()` **non** ha un mutante coperto da test (serve la rete): dichiaralo nel commit; lo coprono la rilettura dello Step 3 e la verifica dal vivo 2.
- [ ] **Step 6:** Security/Rules Auditor sul diff. Commit.

---

### Task 5: l'elenco arriva al riepilogo di fine job e in fondo al log

**Patch:** `proto/patches/05-summary.py`. **File:** `AppBackupFoto/ContentView.swift` (`UploadFailureSummary` nuovo accanto a `S3UploadText`, `FileSyncer.SyncResult`, `JobStats`, `BackupRunner.runSyncS3`, `BackupRunner.finishCopyStep`, `CompletionSheet`), `AppBackupFotoTests/S3UploadTextTests.swift`.

- [ ] **Step 1:** `apply.py --only 5`.
- [ ] **Step 2: cosa c'è.**
  - `nonisolated enum UploadFailureSummary`: `headline(count:)` («1 file non caricato su Cubbit» / «N file non caricati su Cubbit»), `reassurance` («Sull'SSD non è stato toccato niente: il prossimo backup verso Cubbit riproverà da solo questi file.» — stessa correzione del Task 2 rispetto a «restano sull'SSD»), `whereIsTheFullList` («L'elenco completo è in fondo al registro: scheda Log → Salva.»), `visibleLines(_:limit:)` (al massimo `limit` righe `percorso — motivo`, poi «…e altri N» / «…e altro 1»), `logLines(_:)` (intestazione più **tutte** le righe, senza limite).
  - Il trasporto **non** passa per `onProgress` (copiare l'array a ogni file costerebbe O(n²) con migliaia di fallimenti): solo nel risultato finale. `FileSyncer.SyncResult.failedFiles` (doc-comment: lo riempie solo `runSyncS3`, D4), `JobStats.failedFiles` (non persistito, come `listStepOutcome`), `runSyncS3`: `fr.failedFiles = r.failures`, `finishCopyStep`: `stats.failedFiles = r.failedFiles`.
  - In `finishCopyStep`, dopo il blocco `if let r` e **prima** di `JobHistoryStore.save`, l'elenco completo va in fondo al log **con una sola `append`** (`logLines(...).joined(separator: "\n")`). **Differenza dalla bozza** (che faceva una `append` per riga): ogni `append` misura e taglia `output` sul main, e con migliaia di file (rete caduta a metà job) una per riga bloccherebbe la finestra. Commento: l'elenco entra qui in modo sincrono; le singole righe «Non caricato» arrivano per strade asincrone.
  - `CompletionSheet`: se `!stats.failedFiles.isEmpty`, una sezione con `Label(headline, systemImage: "exclamationmark.triangle.fill")` in `AppColor.warning`, `reassurance`, le `visibleLines(…, limit: 8)` in `.caption` con `.lineLimit(1)` e `.truncationMode(.middle)`, poi `whereIsTheFullList`. `ForEach` su `Array(…enumerated())` con `id: \.offset` (due righe possono essere identiche). La riga generica «Controlla il log per i dettagli sugli errori.» resta, ma **solo** quando `stats.errors > 0 && stats.failedFiles.isEmpty` (copie locali, D4).
- [ ] **Step 3: i 7 test:** `testHeadline_singularAndPlural`, `testReassurance_saysNothingWasTouchedAndTheNextBackupRetries`, `testVisibleLines_showsAtMostTheLimit`, `testVisibleLines_overflowSaysHowManyMore`, `testVisibleLines_empty_isEmpty`, `testLogLines_listEveryFailureWithFullPath`, `testAllSummaryTexts_haveNoJargon`.
- [ ] **Step 4:** `fasttest.sh` → **1.457**, 0 warning.
- [ ] **Mutanti (verificati):** 5a `visibleLines` con `limit + 1`; 5b plurale deciso su `count < 1`; 5c `logLines` che applica anche lui un limite; 5d `UploadFailureSummary` senza `nonisolated` è **equivalente** (chiamata solo dal main), dichiaralo nel commit. La sezione della View e `finishCopyStep` non hanno un mutante coperto da test: dichiaralo; li copre la verifica dal vivo 3.
- [ ] **Step 5:** Commit.

---

### Task 6: `JobLogFile` — il log completo sul disco del Mac

**Patch:** `proto/patches/06-job-log-file.py`. **File:** `AppBackupFoto/ContentView.swift` (nuovo tipo subito **prima** di `// MARK: - BackupRunner`), `AppBackupFotoTests/JobLogFileTests.swift` (**nuovo**, registrato nel pbxproj), `AppBackupFotoTests/MainThreadIsolationTests.swift` (in coda).

- [ ] **Step 1:** `apply.py --only 6`.
- [ ] **Step 2: la forma** (nomi vincolanti, corpi nella patch):

```swift
/// `nonisolated`, `@unchecked Sendable`: `handle`, `opened`, `finished` e `broken` si leggono e
/// si scrivono SOLO sulla coda seriale `queue`; tutto il resto e' `let`. Nessun I/O sul main.
nonisolated final class JobLogFile: @unchecked Sendable {
    static let keepCount = 50                                            // D1
    static let defaultRefusedRoots = ["/Volumes"]
    static let unavailableNote: String
    static func defaultDirectory(isRunningUnderTests: Bool = isRunningUnderTests()) -> URL   // ~/Library/Logs/AppBackupFoto; sotto test una cartella temporanea (BUG-10)
    static func fileName(startedAt: Date, timeZone: TimeZone = .current) -> String         // backup_AAAA-MM-GG_hh-mm-ss.log
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String           // AAAA-MM-GG hh:mm:ss
    static func stamped(_ text: String, at: Date, timeZone: TimeZone = .current) -> String // D6: l'ora su OGNI riga non vuota
    static func isLogFileName(_ name: String) -> Bool                                      // il nome esatto, cifre ASCII
    static func namesToPrune(_ names: [String], keep: Int, protecting: String) -> [String] // D1
    static func closingLine(phaseLabel: String, copied: Int, skipped: Int, errors: Int, elapsed: String) -> String
    static func isRefused(_ path: String, refusedRoots: [String]) -> Bool                  // per componenti, solo lessicale
    static func resolvedPath(of directory: URL) -> String                                  // collegamenti della parte che esiste
    let url: URL
    init(directory: URL, startedAt: Date, header: String, refusedRoots: [String] = JobLogFile.defaultRefusedRoots)
    func write(_ text: String, at: Date)
    func finish(closingLine: String)
    func export(to destination: URL, fallback: String, completion: @escaping @Sendable (Bool) -> Void)
    func waitForPendingWrites()                                          // queue.sync {} — solo per i test
}
```

- [ ] **Step 3: vincoli, tutti nel codice della patch:**
  - **`FileHandle.write(contentsOf:)` (quella che lancia), mai `write(_ data:)`**: la seconda solleva un'eccezione Objective-C su disco pieno e manderebbe in crash l'app a metà di un backup. Ogni errore mette `broken = true` e da lì il file tace. **Il log su disco non fa mai fallire né rallentare un job.**
  - Apertura, sulla coda: rifiuto se la cartella sta sotto `/Volumes`, **anche risolvendo i collegamenti della parte che esiste già** (prima di creare qualunque cosa) e di nuovo dopo la creazione; `createDirectory(withIntermediateDirectories: true)`; conservazione (Step 4); file aperto con `open(O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600)`: creato solo se manca, altrimenti in coda (due job nello stesso secondo accodano, non sovrascrivono), mai attraverso un collegamento, `0600` perché contiene i percorsi delle foto. Poi l'intestazione.
  - `export` gira sulla **stessa coda** delle scritture, legge il file fuori dal main, scrive la destinazione con `.atomic`, `completion` sul main. Senza file: `unavailableNote` + la parte visibile. Con un file interrotto a metà (disco pieno): il file com'è, che contiene l'inizio.
  - **Novità rispetto alla bozza, per BUG-10:** `defaultDirectory(isRunningUnderTests:)` come `backupRunnerStoreRoot`; il rifiuto di `/Volumes` come parametro `refusedRoots` (solo i test lo cambiano), così il rifiuto si prova **senza toccare `/Volumes`**; il controllo attraverso i collegamenti.
- [ ] **Step 4: conservazione (D1), l'unica `removeItem` nuova** (`prune()`, sulla coda, dopo `createDirectory`): `contentsOfDirectory` della **sola** cartella dei log; solo i nomi che passano `isLogFileName` **e** sono file regolari secondo `attributesOfItem` (che non segue i collegamenti: mai una cartella, mai un collegamento); `namesToPrune(quelli + [nome del nuovo], keep: 50, protecting: nome del nuovo)`; per ciascuno `try? removeItem(at: directory.appendingPathComponent(nome))`. Il nome ha superato il controllo esatto, quindi non contiene `/` né `..`. Un errore si ignora. Doc-comment: è l'unica cancellazione di questo intervento, cosa può toccare e cosa mai.
- [ ] **Step 5: i 19 test** (`JobLogFileTests`, ognuno in una cartella temporanea propria, rimossa nel `tearDown`): `testDefaultDirectory_isInTheUserLibraryLogs_neverOnAVolume`, `testDefaultDirectory_underTests_isInTheTemporaryFolder`, `testFileName_format`, `testStamped_prefixesEveryLine`, `testWriteAndFinish_fileHasHeaderLinesAndClosing` (anche i permessi `0600`), `testWritesAfterFinish_areIgnored`, `testMoreThanSixtyThousandCharacters_areAllKept` (**la regressione**), `testExport_copiesTheWholeFile`, `testExport_withoutAFile_writesTheFallbackWithANote`, `testUnwritableDirectory_neverCrashes_andWritesNothing`, `testRefusedRoot_isNeverWritten`, `testDirectoryThroughALinkToARefusedRoot_isRefused`, `testNamesToPrune_keepsTheNewest`, `testNamesToPrune_ignoresEverythingElse_andProtectsTheCurrent`, `testPruneOnDisk_removesOnlyOldMatchingFiles` (52 vecchi + `appunti.txt` + una cartella con nome valido → 50 registri, il nuovo compreso; nota e cartella intatte), `testPrune_neverTouchesALink` (un collegamento con nome valido verso una «foto» fuori: collegamento e foto intatti), `testTwoJobsInTheSameSecond_appendNotOverwrite`, `testClosingLine_hasAllNumbers`, `testJobLogFile_hasExactlyOneRemoveItem_insidePrune` (guardia sul sorgente, per l'Auditor). In più `MainThreadIsolationTests.testJobLogFile_writesWithoutTheMainThread`.
- [ ] **Step 6:** `fasttest.sh JobLogFileTests` → 19; `fasttest.sh MainThreadIsolationTests` → 30; `fasttest.sh` → **1.477**, 0 warning. **Punto di controllo `xcodebuild`** in background: **1.477** (1.458 = `JobLogFileTests` non registrato nel pbxproj; 1.452 = `S3UploadTextTests` non registrato).
- [ ] **Mutanti (verificati):** 6a `namesToPrune` che toglie i più nuovi; 6b nome allentato a `hasPrefix("backup_")`; 6c `protecting` ignorato; 6d `export` che scrive sempre il fallback; 6e senza il rifiuto delle radici; 6e2 senza il controllo attraverso i collegamenti; 6f l'ora solo sulla prima riga; 6g conservazione anche su cartelle e collegamenti; 6h file troncato invece che in coda; 6i `write(_ data:)` che non lancia; 6j `JobLogFile` senza `nonisolated`.
- [ ] **Step 7:** **Security/Rules Auditor obbligatorio** sul diff, con questa lista: (1) l'unica `removeItem(` nuova è in `JobLogFile.prune`, e il test di guardia lo conta; (2) agisce solo su file regolari, con nome esatto, direttamente nella cartella dei log, mai sul file del job che parte; (3) la cartella non può stare sotto `/Volumes`, nemmeno attraverso un collegamento, ed è controllata **prima** di creare qualunque cosa; (4) sotto test la cartella non è quella vera dell'utente; (5) nessun file foto è raggiungibile da questo codice. Commit; nel messaggio una riga per l'Auditor: dove sta l'unica `removeItem` e quali test la delimitano.

---

### Task 7: cablaggio in `BackupRunner` e bottone «Salva»

**Patch:** `proto/patches/07-wiring.py`. **File:** `AppBackupFoto/ContentView.swift` (`BackupRunner`, `SpeedLogPanel` e il suo unico chiamante).

- [ ] **Step 1:** `apply.py --only 7`.
- [ ] **Step 2: cosa c'è.**
  - `private var jobLog: JobLogFile?` e `private var lastJobLog: JobLogFile?` accanto a `maxOut`, con il doc-comment: `output` resta tagliato **apposta** (ADR-0010), il registro completo è il file.
  - In `run(label:refreshesLibraryIndex:work:)`, subito dopo `completionSnapshot = nil; startTime = now` (quindi **dopo** `JobStartGate` e `ArchiveWriteClock.markStarted()`: un job rifiutato non apre file): `jobLog = JobLogFile(directory: JobLogFile.defaultDirectory(), startedAt: now, header: "AppBackupFoto <versione> — <label>")` (versione da `CFBundleShortVersionString`, come `HamburgerPanel`), poi `lastJobLog = jobLog`.
  - `append(_:)`: `jobLog?.write(text, at: Date())` **prima** del taglio a `maxOut`.
  - `closeJobLog()`: `finish(closingLine:)` con `phase.label` e i numeri di `stats`, poi `jobLog = nil`. Chiamata nei **tre** punti in cui un job finisce: `finishJob` (dopo l'ultima `append` e `completionSnapshot`); il ramo `catch` di `run`, dopo `self.phase = .failed(...)` (così il motivo dell'errore entra nella riga di chiusura); `stop()` dopo `phase = .failed("Interrotto dall'utente")`, **non** nel ramo del passo 2 (lì il job finisce in `finishJob`). Le righe che arrivano dopo la chiusura si vedono nell'app ma non nel file: accettato e scritto nel doc-comment.
  - `func exportFullLog(to:)`: con `lastJobLog` → `export(to:fallback: output)`; senza → `output` come prima.
  - `SpeedLogPanel` riceve `let onSave: (URL) -> Void`; «Salva» chiama `onSave(url)` con lo stesso `NSSavePanel` e lo stesso nome proposto. «Copia» resta com'è (copia ciò che si vede). Il chiamante passa `{ runner.exportFullLog(to: $0) }`.
- [ ] **Step 3:** `grep -n "closeJobLog()" AppBackupFoto/ContentView.swift` → la definizione più **3** chiamate (`stop`, `finishJob`, `catch` di `run`); `grep -n "JobLogFile(" AppBackupFoto/ContentView.swift` → **1** sola apertura, in `run`.
- [ ] **Step 4:** `fasttest.sh` → **1.477** (nessun test nuovo), 0 warning. **Punto di controllo `xcodebuild`** in background: **1.477**, `TEST SUCCEEDED`, 0 warning.
- [ ] **Mutante:** **nessuno.** È cablaggio; le difese sono la build, i `grep` dello Step 3 e le verifiche dal vivo 1, 4 e 5. Dichiaralo nel commit.
- [ ] **Step 5:** Security/Rules Auditor: l'esportazione scrive solo nella destinazione scelta nel pannello «Salva» (che chiede conferma prima di sostituire un file, come prima), mai altrove. Commit.

---

### Task 8: mutation testing

**Solo su una copia nello scratch**, mai sull'albero di lavoro. Già eseguito dall'Architect sul prototipo: esiti in `proto/mutants/mutants.log` (tabella in fondo a questo piano). Qui si ripete sul branch vero.

- [ ] **Step 1:** copia il repository del branch (a fine Task 7) in `/private/tmp/claude-501/s3-failures-plan/branch-copy` (`git archive HEAD | tar -x -C …`).
- [ ] **Step 2:** `SRC=/private/tmp/claude-501/s3-failures-plan/branch-copy python3 /private/tmp/claude-501/s3-failures-plan/proto/mutants/mutants.py` (in background, dall'orchestratore: 24 mutanti × ~70 s, circa mezz'ora). Ogni mutante deve risultare `UCCISO` in `mutants.log` (annota da quale test), tranne 5d, equivalente dichiarato.
- [ ] **Step 3:** un mutante che sopravvive si copre con un test nuovo (e si dichiara, spostando l'atteso), oppure si **dichiara equivalente, con il motivo scritto**, nel commit e nel Task 9.
- [ ] **Step 4:** nessun commit del codice mutato. Cancella `branch-copy` e `mut` alla fine.

---

### Task 9: documentazione

- [ ] **Step 1:** `.claude/rules/architecture.md`, sezione `S3Syncer`, voce «Retry con backoff»: 5 tentativi, attese 1-2-4-8 s, `uploadMaxAttempts`/`runWithRetry`, il motivo in chiaro nella riga, i tre costi del doc-comment del Task 3, e perché resta separato da `RetryingAlignmentCloud`. Nella stessa sezione una voce nuova: ogni file non caricato lascia una riga e finisce in `SyncResult.failures` (con `recordFailure` unico punto).
- [ ] **Step 2:** stessa pagina, sezione `BackupRunner`: una voce su `JobLogFile` — dove sta e perché mai sull'SSD, sotto test una cartella temporanea (BUG-10), conservazione (D1) e l'unica `removeItem` con i suoi limiti, orari (D6), `output` tagliato di proposito e il file come registro completo, le righe tardive non registrate, «Salva» che esporta il file intero, e cosa **non** è coperto da test (il cablaggio del Task 7, la sezione della `CompletionSheet`).
- [ ] **Step 3:** `.claude/rules/bug-history.md`: **BUG-11** (non BUG-8, già preso dalla lista S3 con `+`/apostrofo). Sintomo (102 errori senza un nome, log che comincia a metà riga), causa (il `catch` che contava e basta, più il taglio a 60.000 caratteri), fix, e la lezione: *un contatore di errori senza l'elenco di cosa è fallito non è una diagnosi, è un allarme*.
- [ ] **Step 4:** `Docs/ROADMAP.md`, **punto 43** (numero lasciato libero il 2026-09-26 apposta): «file non caricati visibili e log completo su disco, implementato il 2026-10-XX, verifica dal vivo ancora da fare» — **non** ✅ finché Enrico non ha fatto il Task 10 — con la riga di D3: «dopo un backup vero, leggere i motivi e decidere se il gate deve sentire i tentativi intermedi». **Punto 49** (D4): stesso buco in `FileSyncer.syncFile` nelle copie locali, con il riferimento a `FileSyncer.SyncResult.failedFiles` già pronto.
- [ ] **Step 5:** `Docs/CLAUDE.md`: riga «SSD → S3» della tabella (5 tentativi, file non caricati elencati, registro completo su disco) e riga «Test automatici» (nuovo totale misurato, 1.425 → 1.477; file nuovi `S3UploadTextTests` (25) e `JobLogFileTests` (19); estesi `S3SyncerRetryTests` (+7) e `MainThreadIsolationTests` (+1)). Aggiorna la data in testa a «Stato attuale» con un **decimo tocco** che dice quali righe sono state toccate, come i precedenti. Nella checklist «IF il codice contiene operazioni FileManager», nessuna regola nuova serve: la conservazione dei log ricade già in «verifica che nessuna tocchi file sorgente»; aggiungi solo, accanto, il nome di `JobLogFile.prune` e del test di guardia.
- [ ] **Step 6:** Commit solo documentazione.

---

### Task 10: verifiche dal vivo (Enrico, SSD collegato)

**Non le esegue l'Implementer.** Servono l'app compilata da questo branch e un backup vero verso Cubbit.

- [ ] **1.** Dopo un SSD → Cubbit qualunque, in `~/Library/Logs/AppBackupFoto/` c'è un file `backup_….log` con intestazione, righe con orario e riga finale. Si apre anche con Console.app.
- [ ] **2.** *(la verifica che copre il rischio principale)* Durante il caricamento di un video grande, spegnere il Wi-Fi per ~5 s e riaccenderlo. Nel Log compaiono righe «Connessione difficile con Cubbit … Riprovo tra N secondi (tentativo k di 5)» con un motivo leggibile; il file finisce caricato. Spegnerlo per ~60 s: compaiono righe «Non caricato: … — …», e il numero di errori del riepilogo è uguale al numero di quelle righe.
- [ ] **3.** Il riepilogo di fine job elenca i file non caricati (al massimo 8 più «…e altri N»), dice che sull'SSD non è stato toccato niente, e non contiene parole tecniche oltre al codice fra parentesi.
- [ ] **4.** «Salva» nella scheda Log produce un file che comincia dall'**inizio** del job, non a metà di una riga.
- [ ] **5.** Un secondo backup verso Cubbit subito dopo il punto 2 carica proprio i file elencati come non caricati (e il conteggio degli errori torna a 0, se la rete regge).
- [ ] **6.** *(facoltativa)* Con più di 50 registri nella cartella, dopo un job ne restano 50, e un file estraneo messo lì apposta (`prova.txt`) è ancora al suo posto.

---

## Mutanti verificati sul prototipo (2026-10-27)

`proto/mutants/mutants.py` su una copia con tutte le patch, un mutante alla volta, verifica veloce della classe indicata. **23 uccisi su 24; 1 equivalente dichiarato (5d).**

| # | Mutante | Ucciso da |
| :-- | :-- | :-- |
| 2a | `.timedOut` e `.networkConnectionLost` scambiati | `testReason_networkConnectionLost`, `testReason_timedOut` |
| 2b | niente `(codice …)` nel ramo HTTP 5xx | `testReason_http5xx`, `testReason_everyReasonHasNoJargon_andACode` |
| 2c | `retryLine` con `nextAttempt - 1` | `testRetryLine_saysKeyReasonWaitAndNextAttempt` |
| 2d | `S3UploadText` senza `nonisolated` | warning di isolamento (in Debug: build rossa) |
| 3a | `uploadMaxAttempts = 3` | `testMaxAttempts_isFive`, `testRunWithRetry_retryableError_triesFiveTimesThenThrows`, `testRunWithRetry_onRetryGetsThePlainReason` |
| 3b | attesa `pow(2, attempt)` | `testDelays_are1_2_4_8`, `testRunWithRetry_retryableError_…`, `testRunWithRetry_succeedsOnThirdAttempt` |
| 3c | senza `isRetryable` | `testRunWithRetry_permanentError_doesNotRetry` |
| 3d | senza il controllo dell'interruzione | `testRunWithRetry_cancelled_doesNotRetry` |
| 4a | `recordFailure` senza `errors += 1` | `testRecordFailure_countsAndRemembers`, `testRecordFailure_errorsAlwaysEqualsFailuresCount` |
| 5a | `visibleLines` con `limit + 1` | `testVisibleLines_overflowSaysHowManyMore` |
| 5b | plurale invertito | `testHeadline_singularAndPlural` |
| 5c | `logLines` con un limite | `testLogLines_listEveryFailureWithFullPath` |
| 5d | `UploadFailureSummary` senza `nonisolated` | **equivalente**: la chiamano solo `finishCopyStep` e `CompletionSheet`, sul main. L'annotazione dichiara l'intento (tipo puro), non è un vincolo del compilatore — stessa situazione di `UnverifiedCopiesStore` in `.claude/rules/architecture.md` |
| 6a | `namesToPrune` toglie i più nuovi | `testNamesToPrune_keepsTheNewest`, `testPruneOnDisk_…`, `testPrune_neverTouchesALink` |
| 6b | nome allentato a `hasPrefix("backup_")` | `testNamesToPrune_ignoresEverythingElse_andProtectsTheCurrent` |
| 6c | `protecting` ignorato | `testNamesToPrune_ignoresEverythingElse_andProtectsTheCurrent` |
| 6d | `export` scrive sempre il fallback | `testExport_copiesTheWholeFile` |
| 6e | senza il rifiuto delle radici | `testRefusedRoot_isNeverWritten`, `testDirectoryThroughALinkToARefusedRoot_isRefused` |
| 6e2 | senza il controllo attraverso i collegamenti | `testDirectoryThroughALinkToARefusedRoot_isRefused` |
| 6f | l'ora solo sulla prima riga | `testStamped_prefixesEveryLine` |
| 6g | conservazione anche su cartelle e collegamenti | `testPruneOnDisk_removesOnlyOldMatchingFiles`, `testPrune_neverTouchesALink` |
| 6h | file troncato (`O_TRUNC`) invece che in coda | `testTwoJobsInTheSameSecond_appendNotOverwrite` |
| 6i | `write(_ data:)` che non lancia | warning (in Debug: build rossa) |
| 6j | `JobLogFile` senza `nonisolated` | `MainThreadIsolationTests.testJobLogFile_writesWithoutTheMainThread` |

**Trovato dal primo giro e corretto nelle patch:** 5c e 6h risultavano «sopravvissuti» perché, dopo l'asserzione rossa, il test andava fuori indice o scartava un `!` su un valore assente e mandava in **crash** il processo dei test (sotto `xcodebuild` avrebbe interrotto l'intera suite). Ora `testLogLines_listEveryFailureWithFullPath`, `testWriteAndFinish_fileHasHeaderLinesAndClosing` e `testTwoJobsInTheSameSecond_appendNotOverwrite` si fermano con un `guard … else { return XCTFail(…) }`, e `mutants.py` conta come ucciso anche un crash.

## Rischi e punti da tenere d'occhio

- **Nessuna decisione nuova di Enrico serve.** Le due differenze di testo rispetto alla bozza (la riga «Non caricato» e la frase di rassicurazione non dicono più «resta sull'SSD») e le tre aggiunte di sicurezza a `JobLogFile` (cartella temporanea sotto test, rifiuto di `/Volumes` anche attraverso i collegamenti, file `0600` aperto senza seguire collegamenti) stanno dentro le decisioni prese; sono scritte nei task.
- **Più richieste ripetute su una rete in difficoltà**: fino a 4 ripetizioni per unità invece di 2. Sono le stesse richieste di prima, zero-overwrite per costruzione (`shouldUpload`), con il limite già dichiarato del completamento multipart con risposta persa.
- **`S3Syncer.sync` gira ancora in parte sul main** (ROADMAP #32): il ciclo degli esiti e la riga «Non caricato» non cambiano questo; la riga è un salto `DispatchQueue.main.async` per file fallito, come le righe «Carico:».
- **Il registro su disco cresce durante un primo backup completo** (~120.000 righe, qualche MB): tenuto a 50 registri.
- **Non coperto da test, dichiarato**: il cablaggio in `BackupRunner`, `SpeedLogPanel` e la sezione nuova di `CompletionSheet` (SwiftUI); il cablaggio in `sync()` (serve la rete). Coperti ai due capi, e dalle verifiche dal vivo 1-5.

## Fuori scope (dichiarato, per non riscoprirlo)

- **`FileSyncer.syncFile`**, `catch { result.errors += 1 }` senza riga né nome, nelle copie locali: D4, ROADMAP #49.
- **Il gate che sente i tentativi intermedi:** D3.
- **Ritentativi condivisi con `RetryingAlignmentCloud`:** separati apposta (sezione «Cosa è cambiato»).
- **Nessuna variazione casuale sulle attese** (*jitter*): le unità che falliscono nello stesso istante ritentano insieme. Da riconsiderare solo se i motivi raccolti mostrano congestione.
- **Un PUT ritentato dopo una risposta persa** riscrive la stessa key con gli stessi byte; un completamento multipart ritentato dopo una risposta persa riceve un 404 (Task 2, limite dichiarato). Entrambi esistevano già e non cambiano con questo intervento.
- **L'elenco dei file non caricati non si salva in `JobSummary`** (pannello Revisione). Il registro su disco è il posto dove quell'elenco sopravvive al riavvio dell'app.
- **ROADMAP #32** (parte sincrona di `upload()` sul main) e **BUG-6** (abort su stop): non toccati.
