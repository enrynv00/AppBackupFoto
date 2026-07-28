# AppBackupFoto — Contesto per Claude Code

Questo file definisce regole, architettura e obiettivi del progetto. Leggilo integralmente prima di toccare qualsiasi file.

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
6. **Mai committare dati foto o credenziali in git** — vedi `.gitignore`: `Log/` (foto reali, non log testuali) e `Script/*.csv` (export credenziali rclone/S3) sono esclusi.

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

Presenta sempre l'output della revisione insieme al codice.

---

## Architettura Swift (ContentView.swift)

### App entry & Root

- `BackupFotoEnricoApp` (`@main`) → `WindowGroup { RootView() }`
- `RootView` mostra `SetupView` finché `BookmarkManager.allConfigured` non è true, poi `ContentView`
- `Notifier` (enum) → richiede permessi notifiche e invia notifiche di completamento job
- `AppearanceManager` (singleton `ObservableObject`) → forza Chiaro/Scuro/Sistema via `NSApp.appearance`, persistito in UserDefaults

### BookmarkManager (singleton)

- Salva/ripristina security-scoped bookmarks in UserDefaults
- Chiavi: `bk_photos`, `bk_ssd`, `bk_hdd`
- `startAccessing(_ loc)` → URL con accesso attivo · `stopAccessing(_ loc)` → rilascia il token
- `allConfigured` → true se tutte e 3 le cartelle sono selezionate → al primo avvio mostra `SetupView`

### FileSyncer (sync locale Mac→SSD e SSD→HDD)

- Copia file via `FileManager.copyItem` — zero subprocess
- Confronto: data + dimensione (default) o solo dimensione (deep mode)
- Esclude: `.DS_Store`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `lost+found`, `Backups.backupdb`, `._*`
- **Zero-overwrite enforcement**: se il file esiste già a destinazione (anche con contenuto diverso) viene sempre skippato, mai sovrascritto — mai un branch di codice che chiama `copyItem` su un path esistente
- **Verifica SHA256 post-copia**: ogni file copiato viene ri-hashato e confrontato con la sorgente; mismatch → `hashErrors` (contatore separato dagli errori I/O), loggato come "⚠️ HASH MISMATCH"
- `previewSync(from:to:deep:)` → dry-run: conta `toAdd`/`toSkip`/tempo stimato senza copiare nulla (usato dai bottoni 👁 anteprima)
- Callbacks: `onStatus(String)` e `onProgress(SyncResult)` per ogni file

### S3Syncer (upload S3 nativo, SSD→Cubbit)

- Legge credenziali da `~/.config/rclone/rclone.conf`, sezione `[Cubbit]`
- **Guardie di sicurezza su `readConfig`**: rifiuta se i permessi del file sono più aperti di `0600`; rifiuta se l'endpoint non è HTTPS; **allow-list dell'host** (`s3.it.cubbit.org`) — se rclone.conf viene alterato per puntare altrove, il caricamento si blocca finché l'host non viene aggiunto esplicitamente alla allow-list nel codice
- List bucket con paginazione (ListObjectsV2), confronto per key+size per decidere cosa caricare (mai DELETE/overwrite remoto)
- PUT per file < 64MB, multipart per file ≥ 64MB (chunk da 64MB)
- **Cancel su multipart** → chiama `AbortMultipartUpload` (nessuna parte orfana lasciata sul bucket)
- AWS Signature V4 implementata manualmente — host NON va in `allHTTPHeaderFields`; `/` e `()` vanno encoded nella query string

### VolumeMonitor (`ObservableObject`)

- Polling ogni 3s su `/Volumes/SSD - Enri` e `/Volumes/BackupHDD` → `ssdMounted`/`hddMounted` pubblicati
- Guida l'abilitazione dei bottoni in `SidebarView` (MAC→SSD e SSD→S3 richiedono SSD montato; SSD→HDD richiede entrambi)

### BackupRunner (`@MainActor ObservableObject`)

- Coordina `FileSyncer` e `S3Syncer`, pubblica `phase`/`stats`/`output`/`speedHistory` per la UI
- `runMacToSSD()` / `runSSDToHDD()` / `runSyncS3()` — ciascuno valida gli accessi bookmark, poi valida **che il bookmark punti alla root del volume** (`isLikelyVolumeRoot`: `pathComponents.count <= 3`) prima di avviare, con alert esplicito se il path non è la root (fix del vecchio BUG-1)
- `previewMacToSSD()` / `previewSSDToHDD()` — dry-run: mostrano un `NSAlert` con conteggio file/tempo stimato senza avviare la copia
- Deep mode SSD→HDD ogni 30 giorni (UserDefaults `lastDeepMirrorDate`), aggiornato solo se il job deep è terminato senza errori
- `speedHistory`/`speedUnit` alimentano `SpeedChartView` — MB/s per S3, file/s per FileSyncer, "scan/s" durante la fase di conteggio
- `stop()` cancella `syncer`/`s3Syncer`/`syncTask`, imposta `wasStopped` per evitare un doppio update della UI dopo l'interruzione; cattura `phase.label` prima di sovrascrivere `phase`, così il riepilogo persistito mantiene il nome del job originale
- Alla fine di ogni job (successo, errore o stop manuale) salva un `JobSummary` in `JobHistoryStore`

### ReviewEngine (pannello "Revisione", in `ToolsSheet`)

- `runConfigChecks() -> [ReviewFinding]` — sincrono, nessun accesso ai volumi: valida che i bookmark SSD/HDD puntino alla root del volume, i permessi di `rclone.conf`, l'endpoint S3 (via `S3Syncer.readConfig()`)
- `runIntegritySample(sampleSize:onProgress:) async -> [IntegrityCheckResult]` — su richiesta (bottone dedicato): ricampiona 20 file a caso per coppia (Mac↔SSD, SSD↔HDD, SSD↔S3), ricalcola SHA256 e confronta; per S3 scarica il campione in un file temporaneo e lo cancella subito dopo l'hash. Salta (non fallisce) le coppie i cui bookmark non sono accessibili
- `sampleLocalPair(...)` usa `realpath()` (non `URL.resolvingSymlinksInPath()`, che lascia `/var`/`/tmp` non risolti di proposito su macOS) per calcolare correttamente i path relativi quando confronta directory temporanee — dettaglio scoperto scrivendo i test, importante se si tocca di nuovo questa logica
- `JobSummary`/`JobHistoryStore` — riepilogo dell'ultimo job (data, label, copiati/skippati/errori/hash-mismatch), persistito in UserDefaults (`defaults` parametrizzato per testabilità), sopravvive al riavvio dell'app
- Il motore **segnala soltanto**: nessuna `removeItem`/`copyItem`/scrittura S3 verso una destinazione persistente

---

## UI (SwiftUI views in ContentView.swift)

- **SetupView / LocationRow** — onboarding iniziale, selezione delle 3 cartelle
- **ContentView** — `HSplitView` con `SidebarView` a sinistra e pannello principale (fase corrente, `SpeedLogPanel`, `StatsPanel`, bottone Interrompi/Esci) a destra
- **SidebarView** — hamburger `[☰]`, stato volumi (`VolumeRow`), i 3 `OpsButton` (con bottone 👁 anteprima per Mac→SSD e SSD→HDD)
- **HamburgerPanel** — pannello laterale con: Report Log (apre il tab Log inline, non un subprocess), Configurazione (`SettingsSheet`), Tools (`ToolsSheet`), Aspetto (`AppearanceSheet`), Lingua (apre System Settings). Nessun Login/Password: app locale single-user, credenziali S3 disponibili solo in Tools → Diagnostica dietro conferma esplicita.
- **ToolsSheet** — diagnostica: stato bookmark configurati, config S3 (endpoint/bucket/region), AccessKey/SecretKey mascherate con reveal dietro `NSAlert` di conferma, ultimo deep mirror, sezione "Revisione" (config checks, ultimo job persistito, verifica integrità campione su richiesta — vedi `ReviewEngine`)
- **SpeedLogPanel / SpeedChartView** — grafico velocità real-time (Charts framework) + tab Log con output testuale
- **CompletionSheet / StatsPanel** — riepilogo copiati/skippati/errori/hash-mismatch a fine job

---

## Vincolo tecnico macOS Sequoia (critico)

Qualsiasi subprocess (rsync, bash, rclone, Process()) lanciato da un'app GUI **non riceve i permessi TCC per i volumi esterni**, indipendentemente da Full Disk Access. L'unica soluzione senza firma Apple è: **security-scoped bookmarks + FileManager nativo**. Non proporre mai soluzioni basate su subprocess per accedere a volumi esterni.

---

## Stato attuale (aggiornato 2026-07-28)

| Funzione | Stato |
| :---- | :---- |
| Mac → SSD | ✅ Funziona, con anteprima dry-run e verifica SHA256 post-copia |
| SSD → HDD | ✅ Funziona; validazione volume-root con alert esplicito impedisce più il caso 0/0 silenzioso |
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, grafico MB/s |
| Sheet completamento | ✅ Funziona |
| Notifiche sistema | ✅ Funzionano |
| SetupView | ✅ Funziona |
| SettingsSheet / ToolsSheet / AppearanceSheet | ✅ Funzionano |
| Sidebar hamburger (Report Log, Configurazione, Tools, Aspetto, Lingua) | ✅ Implementata |
| Grafico velocità real-time | ✅ Implementato (Charts, MB/s per S3, file/s locale) |
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256 |
| Test automatici | ✅ 19 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale) |
| Build | ✅ `xcodebuild ... build` e `... test` verdi su questo stato |

---

## Bug aperti

Nessun bug noto aperto al momento. Il vecchio BUG-1 (SSD→HDD bookmark su sottocartella errata) è mitigato a livello di codice da `isLikelyVolumeRoot` + alert guidato — se dovesse ripresentarsi, il fix utente resta: Impostazioni → riseleziona il volume scegliendo la sua root (`/Volumes/SSD - Enri` o `/Volumes/BackupHDD`).

Se emergono nuovi bug, documentarli qui con: sintomo osservato, causa, fix applicato o da applicare.

---

## Obiettivi futuri (non ancora iniziati)

In ordine di priorità:

1. Valutare se serve un meccanismo di notifica/alert se il deep mirror SSD→HDD non gira da troppo tempo (es. oltre 45 giorni) per segnalare che l'HDD non viene collegato abbastanza spesso

**Verifica manuale ancora da fare** (non eseguibile in ambiente headless, serve l'app in mano con volumi montati): controllo visivo della sezione "Revisione" in Tools, funzionamento reale di `runIntegritySample` su Mac↔SSD/SSD↔HDD/SSD↔S3, conferma che i file temporanei scaricati da S3 per il confronto vengano effettivamente cancellati.

---

## Wireframe UI (da Excalidraw)

Riferimento storico del design — l'implementazione attuale in `ContentView.swift` lo rispecchia (vedi sezione UI sopra). File sorgente: `Docs/AppBackupFoto.excalidraw`.

```
┌─────────────────────────────────────────────────────────┐
│ [☰]  Backup Foto                    Main Console        │
│      Enrico Nanni Vicenzi  ╔══════════════════════════╗ │
│                            ║  [grafico speed lineare] ║ │
│  ┌─────────────┐           ║                          ║ │
│  │  Volumi     │           ║ Speed              Log   ║ │
│  │  SSD  🟢   │           ╚══════════════════════════╝ │
│  │  HDD  🔴   │                                        │
│  │  S3   🟢   │  Avanzamento ████████░░░░░░░░░░░  %   │
│  └─────────────┘                                        │
│                   ┌───────┬────────┬───────┬──────┬────┐│
│  ┌─────────────┐  │Copiati│Skippati│Errori │Trasco│ Eta││
│  │ Operazioni  │  │       │        │       │ rso  │    ││
│  │ Mac → SSD   │  └───────┴────────┴───────┴──────┴────┘│
│  │ SSD → HDD   │  ┌──────────────────────── Copia│Salva┐│
│  │ SSD → S3    │  │ Output Esecuzione              ...  ││
│  └─────────────┘  └─────────────────────────────────────┘│
│                                                    Esci  │
└─────────────────────────────────────────────────────────┘
```

Il bottone `[☰]` apre un pannello secondario da sinistra con le opzioni di configurazione (Report Log, Configurazione, Tools, Aspetto, Lingua, Versione). Nessun Login/Password: app locale single-user, credenziali S3 disponibili in Tools → Diagnostica.

---

## Build e distribuzione

- Compilare: `Cmd+B` (o `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`)
- Testare: `Cmd+U` (o target `AppBackupFotoTests` via `xcodebuild ... test`)
- Distribuire: Product → Archive → Distribute → Custom → Copy App → sostituisci in /Applications → ri-aggiungi in System Settings → Privacy → Full Disk Access

---

## Pattern Advisor (Sonnet 5 esecutore + Fable 5 consulente)

Il modello esecutore di questa sessione è Sonnet 5 (pinnato in `.claude/settings.json`). Per decisioni chiave, consulta un subagent con modello Fable 5 (Agent tool, `model: "fable"`) — NON per ogni singolo passo, solo in questi momenti:

1. Dopo un po' di lettura esplorativa (quando ti sei fatto un'idea del problema, prima di formulare un piano).
2. Prima di scrivere modifiche sostanziali al codice (non per fix banali).
3. Come check finale, prima di chiudere il task.

**Regola sul costo — obbligatoria**: Fable 5 è il modello più costoso disponibile ($10/$50 per milione di token) e non hai modo di controllare il credito residuo dell'account. Prima di OGNI dispatch a Fable 5, chiedi esplicitamente conferma all'utente (non dare per scontato un ok precedente), spiegando brevemente perché vuoi consultarlo in quel momento.

**Integrazione con la todo list**: se il subagent Fable 5 restituisce un piano o una lista di passi, non limitarti a riportarli in chat — trasferiscili nella todo list (TodoWrite) come task concreti, così le indicazioni non si perdono tra un checkpoint e l'altro.

---

## Come iniziare una sessione

Leggi questo file, poi leggi `ContentView.swift`, poi affronta il primo obiettivo futuro aperto (vedi sopra). Non fare assunzioni sul codice senza averlo letto prima.
