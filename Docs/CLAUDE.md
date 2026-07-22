# AppBackupFoto — Contesto per Claude Code

Questo file definisce regole, architettura e obiettivi del progetto. Leggilo integralmente prima di toccare qualsiasi file.

---

## Identità del progetto

App macOS nativa (SwiftUI, Swift 5.x, target macOS 13+) per il backup automatico delle foto di **Enrico Nanni Vicenzi** su tre destinazioni:

- **Mac → SSD** — copia Photos Library originals in `/Volumes/SSD - Enri/Foto iPhone`  
- **SSD → HDD** — mirror locale (deep checksum automatico ogni 30 giorni)  
- **SSD → Cubbit S3** — cloud backup sul bucket `backupfoto`

File principale e unico: `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/ContentView.swift` Non esistono altri file Swift nel progetto oltre agli Assets.

---

## Regola assoluta — Le foto non si toccano

Le foto sono dati irrecuperabili. Ogni modifica al codice deve rispettare questi vincoli senza eccezioni:

1. **Zero delete**: nessuna operazione di cancellazione su file foto, né locale né remota, in nessun caso.  
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga.  
3. **Read-only sulla sorgente**: la sorgente (Mac Photos Library o SSD) viene solo letta, mai modificata.  
4. **Dry-run prima di ogni nuova operazione di sync**: qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione.  
5. **Confronto sempre esplicito**: prima di copiare, il codice deve verificare esplicitamente che il file di destinazione non esista già.

---

## Regola sul ciclo AI di revisione (obbligatoria)

Ogni modifica al codice deve passare attraverso un ciclo in due fasi:

**Fase 1 — Scrittura**: scrivi o modifica il codice per soddisfare il requisito.

**Fase 2 — Revisione AI (if-then)**: dopo aver scritto il codice, esegui mentalmente questa checklist come agente di revisione separato:

IF il codice contiene operazioni FileManager (removeItem, moveItem, copyItem):

    THEN verifica che nessuna tocchi file sorgente

    THEN verifica che copyItem abbia guardia di esistenza prima dell'esecuzione

IF il codice fa chiamate S3 (PUT, DELETE, COPY):

    THEN verifica che non ci siano DELETE

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

### BookmarkManager (singleton)

- Salva/ripristina security-scoped bookmarks in UserDefaults  
- Chiavi: `bk_photos`, `bk_ssd`, `bk_hdd`  
- `startAccessing(_ loc)` → URL con accesso attivo  
- `stopAccessing(_ loc)` → rilascia il token  
- `allConfigured` → true se tutte e 3 le cartelle sono selezionate  
- Al primo avvio mostra `SetupView`

### FileSyncer (sync locale)

- Copia file via `FileManager.copyItem` — zero subprocess  
- Confronto: data \+ dimensione (default) o solo dimensione (deep mode)  
- Esclude: `.DS_Store`, `.Spotlight-V100`, `.Trashes`, `._*`  
- Callbacks: `onStatus(String)` e `onProgress(SyncResult)` per ogni file

### S3Syncer (upload S3 nativo)

- Legge credenziali da `~/.config/rclone/rclone.conf`  
- List bucket con paginazione (ListObjectsV2)  
- PUT per file \< 64MB, multipart per file \>= 64MB  
- AWS Signature V4 implementata manualmente  
- SigV4: host NON va in allHTTPHeaderFields; `/` e `()` vanno encoded nella query string

### BackupRunner (@MainActor ObservableObject)

- Coordina FileSyncer e S3Syncer  
- `runMacToSSD()` / `runSSDToHDD()` / `runSyncS3()`  
- Deep mode SSD→HDD ogni 30 giorni (UserDefaults `lastDeepMirrorDate`)  
- `publishStatus()` e `publishProgress()` aggiornano la UI

---

## Vincolo tecnico macOS Sequoia (critico)

Qualsiasi subprocess (rsync, bash, rclone, Process()) lanciato da un'app GUI **non riceve i permessi TCC per i volumi esterni**, indipendentemente da Full Disk Access. L'unica soluzione senza firma Apple è: **security-scoped bookmarks \+ FileManager nativo**. Non proporre mai soluzioni basate su subprocess per accedere a volumi esterni.

---

## Stato attuale (2 giugno 2026\)

| Funzione | Stato |
| :---- | :---- |
| Mac → SSD | ✅ Funziona |
| SSD → S3 | ✅ Funziona con feedback UI e grafico |
| Sheet completamento | ✅ Funziona |
| Notifiche sistema | ✅ Funzionano |
| SetupView | ✅ Funziona |
| SettingsSheet | ✅ Funziona |
| SSD → HDD | ⚠️ Logga il path — se mostra 0/0, il bookmark punta alla cartella sbagliata |

---

## Bug aperti (in ordine di priorità)

### BUG 1 — SSD→HDD bookmark sbagliato

Se mostra "Nessun file trovato in '/percorso/errato'", il bookmark SSD punta a una sottocartella invece che a `/Volumes/SSD - Enri`. Fix utente: Impostazioni → riseleziona SSD scegliendo la root del volume. Il log ora mostra il path all'avvio del job per diagnostica.

---

## Obiettivi futuri (non ancora iniziati)

In ordine di priorità:

1. Fix BUG 1 (SSD→HDD bookmark)  
2. Fix BUG 2 (feedback UI S3)  
3. Grafico velocità real-time (Charts framework — il wireframe mostra una linechart ondulata con label "Speed" e "Log")  
4. Sidebar secondaria (hamburger menu da sinistra con: Login, Password, Report Log, Configurazione, Tono, Lingua, Versione, Tools)  
5. Rimuovere BUG 3 (debug print)  
6. Agente AI di revisione codice integrato nell'app (ciclo if-then che scopre bug a runtime)

---

## Wireframe UI (da Excalidraw)

┌─────────────────────────────────────────────────────────┐

│ \[☰\]  Backup Foto                    Main Console        │

│      Enrico Nanni Vicenzi  ╔══════════════════════════╗ │

│                            ║  \[grafico speed lineare\] ║ │

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

Il bottone \[☰\] apre un pannello secondario da sinistra con

le opzioni di configurazione (Report Log, Configurazione, Tools,

Aspetto, Lingua, Versione). Nessun Login/Password: app locale

single-user, credenziali S3 disponibili in Tools → Diagnostica.

---

## Build e distribuzione

- Compilare: `Cmd+B`  
- Testare: `Cmd+R`  
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

Leggi questo file, poi leggi `ContentView.swift`, poi affronta il primo bug aperto. Non fare assunzioni sul codice senza averlo letto prima.  
