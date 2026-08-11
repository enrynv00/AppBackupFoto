# AppBackupFoto — Contesto per Claude Code

Questo file definisce regole, architettura e obiettivi del progetto. Leggilo integralmente prima di toccare qualsiasi file. Il dettaglio dell'architettura Swift (componente per componente) e lo storico bug sono in `.claude/rules/architecture.md` e `.claude/rules/bug-history.md` — si caricano automaticamente quando lavori su `ContentView.swift` o `AppBackupFotoTests/`.

---

## Identità del progetto

App macOS nativa (SwiftUI, Swift 5.x, target macOS 13+) per il backup automatico delle foto di **Enrico Nanni Vicenzi** su tre destinazioni:

- **Mac → SSD** — copia Photos Library originals in `/Volumes/SSD - Enri/Foto iPhone`
- **SSD → HDD** — mirror locale (deep checksum automatico ogni 30 giorni)
- **SSD → Cubbit S3** — cloud backup sul bucket `backupfoto`

File principale e unico: `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/ContentView.swift` (~2000 righe). Non esistono altri file Swift nel target app oltre agli Assets — l'entry point `@main` (`BackupFotoEnricoApp`) vive anch'esso in questo file (`AppBackupFotoApp.swift` è stato rimosso perché ridondante).

Target di test separato: `AppBackupFotoTests/FileSyncerZeroOverwriteTests.swift` — XCTest che blinda l'invariante zero-overwrite su directory temporanee reali (nessun mock).

---

## Regola assoluta — Le foto non si toccano

Le foto sono dati irrecuperabili. Ogni modifica al codice deve rispettare questi vincoli senza eccezioni:

1. **Zero delete**: nessuna operazione di cancellazione su file foto, né locale né remota, in nessun caso.
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga.
3. **Read-only sulla sorgente**: la sorgente (Mac Photos Library o SSD) viene solo letta, mai modificata.
4. **Dry-run prima di ogni nuova operazione di sync**: qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione.
5. **Confronto sempre esplicito**: prima di copiare, il codice deve verificare esplicitamente che il file di destinazione non esista già.
6. **Mai committare dati foto o credenziali in git** — vedi `.gitignore`: `Log/` (foto reali, non log testuali) e `Script/*.csv` (export credenziali rclone/S3) sono esclusi. Una scrittura su `Log/` da un tool automatico è bloccata anche a livello di hook (`.claude/hooks/protect_log_dir.py`).

---

## Regola sul ciclo AI di revisione (obbligatoria)

Ogni modifica al codice deve passare attraverso un ciclo in due fasi:

**Fase 1 — Scrittura**: scrivi o modifica il codice per soddisfare il requisito.

**Fase 2 — Revisione AI (if-then)**: dopo aver scritto il codice, esegui mentalmente questa checklist come agente di revisione separato:

IF il codice contiene operazioni FileManager (removeItem, moveItem, copyItem):

    THEN verifica che nessuna tocchi file sorgente

    THEN verifica che copyItem abbia guardia di esistenza prima dell'esecuzione

IF il codice fa chiamate S3 (PUT, DELETE, COPY):

    THEN verifica che non ci siano DELETE (eccetto AbortMultipartUpload su cancel, che non tocca dati già scritti)

    THEN verifica che PUT controlli esistenza remota prima di inviare

IF il codice usa bookmark security-scoped:

    THEN verifica che startAccessing() sia chiamato prima dell'uso

    THEN verifica che stopAccessing() sia chiamato in defer o finally

IF il codice aggiorna la UI da contesto async:

    THEN verifica che sia wrappato in Task { @MainActor in }

IF trovi bug in questa revisione:

    THEN documentalo nel log di output e correggilo prima di presentare il risultato finale

Presenta sempre l'output della revisione insieme al codice. Questa checklist è il minimo: se il progetto opera con i ruoli Code Reviewer/Security Auditor (vedi "Team di sviluppo" sotto), la copre in aggiunta, non in sostituzione.

---

## Vincolo tecnico macOS Sequoia (critico)

Qualsiasi subprocess (rsync, bash, rclone, Process()) lanciato da un'app GUI **non riceve i permessi TCC per i volumi esterni**, indipendentemente da Full Disk Access. L'unica soluzione senza firma Apple è: **bookmark + FileManager nativo** (dal 2026-07-29 bookmark normali, non più security-scoped — vedi `.claude/rules/architecture.md` per `BookmarkManager`: il meccanismo di scope non serve dato che l'app non è sandboxata e ha Full Disk Access, e su ExFAT è addirittura rotto). Non proporre mai soluzioni basate su subprocess per accedere a volumi esterni.

---

## Stato attuale (aggiornato 2026-07-29)

| Funzione | Stato |
| :---- | :---- |
| Mac → SSD | ✅ Funziona, con anteprima dry-run e verifica SHA256 post-copia |
| SSD → HDD | ✅ Funziona; validazione volume-root con alert esplicito impedisce più il caso 0/0 silenzioso |
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, retry con backoff, upload paralleli (4 file), grafico MB/s |
| Ripristino guidato (SSD/HDD/Cubbit → cartella) | ✅ Implementato — 4 passi, indicatori di disponibilità in tempo reale, UI volutamente semplice |
| Sheet completamento | ✅ Funziona |
| Notifiche sistema | ✅ Funzionano |
| SetupView | ✅ Funziona; basta la Libreria Foto per entrare nell'app (`canEnterApp`) |
| SettingsSheet / ToolsSheet / AppearanceSheet | ✅ Funzionano |
| Sidebar hamburger (Report Log, Ripristina, Configurazione, Tools, Aspetto, Lingua) | ✅ Implementata |
| Grafico velocità real-time | ✅ Implementato (Charts, MB/s per S3, file/s locale) |
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256, pulizia upload multipart orfani |
| Backup automatico Mac→SSD | ✅ Implementato — trigger su collegamento SSD, toggle on/off in Impostazioni, solo ad app aperta |
| Test automatici | ✅ 45 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3, lettura file a blocchi, concorrenza limitata, validazione endpoint S3) |
| Build | ✅ `xcodebuild ... build` e `... test` verdi su questo stato |

Storico bug (risolti e aperti): vedi `.claude/rules/bug-history.md`.

---

## Obiettivi futuri (non ancora iniziati)

**Verifica manuale ancora da fare**:

- **Roadmap #18, auto-update**: dopo aver creato il repo GitHub pubblico e sostituito `PLACEHOLDER-github-username` in `Info.plist`/`appcast.xml`/`Script/release.sh`, pubblicare una prima release reale con `Script/release.sh` e verificare che una build precedente installata trovi/scarichi/installi correttamente l'update, con la firma EdDSA verificata da Sparkle.
- Non eseguibile in ambiente headless, serve l'app in mano con volumi montati: controllo visivo della sezione "Revisione" in Tools, funzionamento reale di `runIntegritySample` su Mac↔SSD/SSD↔HDD/SSD↔S3, conferma che i file temporanei scaricati da S3 per il confronto vengano effettivamente cancellati.

---

## Build e distribuzione

- Compilare: `Cmd+B` (o `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`)
- Testare: `Cmd+U` (o target `AppBackupFotoTests` via `xcodebuild ... test`)
- Distribuire: Product → Archive → Distribute → Custom → Copy App → sostituisci in /Applications → ri-aggiungi in System Settings → Privacy → Full Disk Access

---

## Team di sviluppo (aggiornato 2026-08-11)

Questo progetto usa il workflow a ruoli espliciti descritto in `~/.claude/docs/specs/2026-08-11-agent-role-orchestration-design.md`: fase Architect (brainstorming → spec → piano, sempre con approvazione esplicita di Enrico) seguita da un team autonomo (Implementer + Code Reviewer + Security/Rules Auditor, ruoli globali in `~/.claude/agents/`) che esegue tutti i task del piano fino in fondo, con un solo checkpoint umano a fine intervento (eccetto blocchi reali che richiedono una decisione di Enrico).

**Sostituisce la vecchia regola "Pattern Advisor"**: Code Reviewer e Security/Rules Auditor usano Fable 5 di default per ogni task (non più chiesto ogni volta) — il costo non è più un vincolo per Enrico. Non serve più chiedere conferma prima di ogni dispatch a Fable 5 su questo progetto.

Gate automatici attivi su questo progetto (vedi `.claude/settings.json`): un hook blocca la scrittura sotto `Log/`, un hook blocca la fine sessione se `ContentView.swift`/i test sono stati modificati senza un build/test verde successivo.

---

## Come iniziare una sessione

Leggi questo file, poi leggi `ContentView.swift`, poi affronta il primo obiettivo futuro aperto (vedi sopra). Non fare assunzioni sul codice senza averlo letto prima.
