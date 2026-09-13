# Immich Integration — Implementation Plan (roadmap #29)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) o superpowers:executing-plans per implementare questo piano task-per-task. Gli step usano checkbox (`- [ ]`) per il tracking.

**Goal:** Aggiungere una finestra "Foto" ad AppBackupFoto che incorpora la web UI di un'istanza Immich gestita interamente dall'app (Colima + Docker Compose), puntata come External Library in sola lettura sull'SSD. Spec: `Docs/superpowers/specs/2026-08-17-immich-integration-design.md`.

**Architecture:** `ImmichManager` (singleton `ObservableObject`, stile `BackupRunner`) gestisce ciclo di vita di Colima+Docker Compose via `Process`. Compose file e dati propri di Immich su disco interno (`~/Library/Application Support/AppBackupFoto/immich/`), mai su SSD/HDD. Nuova `Window` scene "Foto" con `WKWebView` puntata su `http://127.0.0.1:2283`, gated da `AuthGateManager` (stessa regola di #30). Primo setup (creazione account, API key, external library) è un flusso guidato ma **richiede la presenza reale di Enrico** — non è automatizzabile in silenzio (vedi spec, ricerca preliminare).

**Tech Stack:** `WebKit` (`WKWebView`, nuovo import), `Process`/`Foundation` per Colima/Docker CLI, `URLSession` per il download dei binari, SwiftUI, `ContentView.swift` (unico file, convenzione del progetto).

## Global Constraints — IMPORTANTI, leggere prima di iniziare

- **NESSUN task di questo piano esegue realmente `colima start`, scarica le immagini Docker di Immich, o completa il primo setup (account/API key/external library) in autonomia.** Questi passi scaricano diversi GB, avviano una VM e un intero stack di container, e richiedono un login via browser — vanno fatti una volta sola con Enrico presente e consapevole, mai da un agente in background senza supervisione. I task di questo piano producono codice Swift **compilabile e buildabile**, non un'esecuzione end-to-end reale. L'esecuzione reale è l'ultimo step del Task 5, esplicitamente manuale.
- Nessun task usa `sudo` o scrive fuori dalla sandbox dell'app (`~/Library/Application Support/AppBackupFoto/`) — i binari Colima/docker CLI vanno scaricati lì, mai in `/usr/local/bin` di sistema (deviazione intenzionale dalla guida ufficiale Colima, per non toccare nulla di globale sul Mac di Enrico).
- Tutto il codice Swift va in `AppBackupFoto/ContentView.swift` (convenzione single-file del progetto), tranne il contenuto del compose file (nuova risorsa/file di testo, non Swift).
- Build (`xcodebuild ... build`) deve restare verde dopo ogni task. Nessun nuovo unit test per la logica che shella `Process` verso Colima/Docker (non testabile senza eseguirla realmente) — dove possibile, isolare in funzioni pure testabili (es. costruzione del path, contenuto del compose file) seguendo lo stesso pattern di `checkDeepMirrorFreshness(hddConfigured:defaults:now:)`.
- Il server Immich nel compose file deve pubblicare la porta **solo su `127.0.0.1:2283`**, mai `0.0.0.0:2283`.
- Nessuna modifica a `FileSyncer`/`S3Syncer`/`BackupRunner`/regole zero-delete-zero-overwrite.

---

## Task 1: `ImmichManager` — stato e percorsi

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: nessuno (primo task).
- Produces: `ImmichManager.shared` (`installed`, `isRunning`, `isStarting`, `lastError` pubblicati; `appSupportDir`, `composeFilePath` come proprietà) — consumato dai Task 2-4.

- [ ] **Step 1: Aggiungere `import WebKit`** in cima al file, insieme agli import esistenti.

- [ ] **Step 2: Aggiungere `ImmichManager`**, singleton `ObservableObject` stile `BackupRunner`/`AuthGateManager`:

```swift
// MARK: - ImmichManager
final class ImmichManager: ObservableObject {
    static let shared = ImmichManager()
    @Published var installed: Bool = false
    @Published var isRunning: Bool = false
    @Published var isStarting: Bool = false
    @Published var lastError: String?

    let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppBackupFoto/immich", isDirectory: true)
    }()

    var binDir: URL { appSupportDir.appendingPathComponent("bin", isDirectory: true) }
    var composeFilePath: URL { appSupportDir.appendingPathComponent("docker-compose.yml") }
    var dataDir: URL { appSupportDir.appendingPathComponent("data", isDirectory: true) }

    private init() {
        installed = FileManager.default.fileExists(atPath: composeFilePath.path)
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add ImmichManager skeleton: state, paths (roadmap #29)"
```

---

## Task 2: Contenuto del Docker Compose file

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (funzione che genera il contenuto)

**Interfaces:**
- Consumes: `ImmichManager.shared.dataDir` dal Task 1.
- Produces: `ImmichManager.composeFileContent(sourceLibraryPath: String) -> String` — usata dal Task 3 per scrivere il file su disco prima di `docker compose up`.

- [ ] **Step 1: Aggiungere una funzione pura e testabile** che genera il contenuto YAML, adattato dal compose ufficiale Immich (server + machine-learning + redis/valkey + postgres+pgvector), con queste differenze intenzionali rispetto al file ufficiale:
  - `immich-server`: porta pubblicata **solo `127.0.0.1:2283:2283`**, mai `0.0.0.0`.
  - Tutti i volumi dati (`UPLOAD_LOCATION`, Postgres, cache ML) puntano sotto `dataDir` (disco interno Mac), passato come parametro.
  - Un volume aggiuntivo in sola lettura (`:ro`) che monta `sourceLibraryPath` (il path SSD) dentro il container `immich-server`, per l'External Library.

```swift
extension ImmichManager {
    func composeFileContent(sourceLibraryPath: String) -> String {
        """
        name: appbackupfoto-immich
        services:
          immich-server:
            image: ghcr.io/immich-app/immich-server:release
            ports:
              - "127.0.0.1:2283:2283"
            volumes:
              - "\(dataDir.path)/upload:/data"
              - "\(sourceLibraryPath):/external-ssd:ro"
              - /etc/localtime:/etc/localtime:ro
            environment:
              - DB_HOSTNAME=immich-database
              - DB_USERNAME=postgres
              - DB_PASSWORD=postgres
              - DB_DATABASE_NAME=immich
              - REDIS_HOSTNAME=immich-redis
            depends_on:
              - immich-redis
              - immich-database
            restart: unless-stopped
          immich-machine-learning:
            image: ghcr.io/immich-app/immich-machine-learning:release
            volumes:
              - "\(dataDir.path)/model-cache:/cache"
            restart: unless-stopped
          immich-redis:
            image: docker.io/valkey/valkey:9-bookworm
            restart: unless-stopped
          immich-database:
            image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
            environment:
              - POSTGRES_PASSWORD=postgres
              - POSTGRES_USER=postgres
              - POSTGRES_DB=immich
            volumes:
              - "\(dataDir.path)/postgres:/var/lib/postgresql/data"
            restart: unless-stopped
        """
    }
}
```

Nota per l'Implementer: i tag immagine esatti (`:release` ecc.) e i nomi variabile d'ambiente vanno riverificati contro il compose file ufficiale più recente (`https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml`) al momento dell'esecuzione — la ricerca preliminare li ha confermati validi al 2026-08-17, ma Immich evolve rapidamente (vedi spec, sezione versionamento). Se qualcosa è cambiato, adattare mantenendo invariati i tre vincoli di sicurezza/posizionamento (bind solo localhost, dati su disco interno, libreria SSD in sola lettura).

- [ ] **Step 2: Test unitario sulla funzione pura** (nuovo file di test, ricordarsi di aggiungerlo a `project.pbxproj` manualmente — nota tecnica ricorrente del progetto, il target test non è file-system-synchronized): verificare che l'output contenga `127.0.0.1:2283:2283` (mai `0.0.0.0`), che il path sorgente passato compaia con suffisso `:ro`, e che tutti i volumi dati puntino sotto `dataDir`.

- [ ] **Step 3: Build + test**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```

Expected: build verde, nuovo test verde, conteggio totale test aumentato di quello nuovo (verificare il numero esatto, non fidarsi solo di "TEST SUCCEEDED" — nota tecnica ricorrente del progetto).

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add Immich docker-compose generation, localhost-only + external SSD library (roadmap #29)"
```

---

## Task 3: Ciclo di vita — install/start/stop (codice, non esecuzione reale)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: `ImmichManager` dai Task 1-2.
- Produces: `ImmichManager.install() async throws`, `start() async throws`, `stop() async`, `healthCheck() async -> Bool` — consumati dalla UI nel Task 4.

- [ ] **Step 1: Aggiungere i metodi di ciclo di vita a `ImmichManager`** (chiamate `Process` verso i binari scaricati in `binDir`, mai verso path di sistema):
  - `install()`: scarica (via `URLSession`) i binari `colima` e `docker` CLI per l'architettura corrente (arm64/x86_64) da GitHub Releases, li rende eseguibili (`chmod +x`), li posiziona in `binDir`. Aggiorna `installed = true` al termine.
  - `start(sourceLibraryPath: String)`: scrive `composeFileContent(sourceLibraryPath:)` su `composeFilePath`, lancia `<binDir>/colima start` poi `<binDir>/docker compose -f <composeFilePath> up -d`, con `isStarting = true` durante l'attesa. Fa polling di `healthCheck()` (richiesta HTTP a `http://127.0.0.1:2283/api/server/ping` o endpoint equivalente — verificare il path esatto nella documentazione API al momento dell'implementazione) fino a un timeout ragionevole (es. 120s, dato l'avvio di VM+Postgres+ML), poi `isRunning = true`, `isStarting = false`.
  - `stop()`: `<binDir>/docker compose -f <composeFilePath> down` poi `<binDir>/colima stop`. `isRunning = false`.
  - Tutti i metodi aggiornano `lastError` su fallimento invece di far crashare l'app o restare in uno stato ambiguo.

- [ ] **Step 2: Agganciare `stop()` alla chiusura dell'app** — in `BackupFotoEnricoApp` o dove più appropriato, `NSApplication.shared.delegate` (o `.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification))`) chiama `await ImmichManager.shared.stop()` se `isRunning`, prima che l'app termini davvero. Verificare che non blocchi indefinitamente la chiusura se `stop()` è lenta (timeout ragionevole).

- [ ] **Step 3: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Nessuna esecuzione reale di questi metodi in questo task — solo compilazione.

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Immich lifecycle management (install/start/stop, not yet wired to UI) (roadmap #29)"
```

---

## Task 4: UI — voce hamburger, finestra "Foto", gate Touch ID

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: `ImmichManager` (Task 1-3), `AuthGateManager`/`LockScreenView` (roadmap #30, già in produzione).
- Produces: nessuna nuova interfaccia — task terminale lato UI.

- [ ] **Step 1: Nuova `Window` scene "Foto"** in `BackupFotoEnricoApp.body`, stesso pattern di `Window("Catalogo", id: "catalog")`:

```swift
Window("Foto", id: "immich") {
    ImmichView()
        .environmentObject(runner)
}
.defaultSize(width: 1000, height: 700)
.restorationBehavior(.disabled)   // stessa regola stabilita per #30 — ogni nuova Window scene va gated
```

- [ ] **Step 2: Nuova view `ImmichView`**, con lo stesso pattern di gating già usato da `ToolsSheet`/`CatalogView` (roadmap #30):

```swift
struct ImmichView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    @ObservedObject private var immich = ImmichManager.shared
    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if !immich.installed {
            ImmichSetupPromptView()   // spiega cosa succederà, spazio/tempo stimato, bottone "Installa" esplicito
        } else if immich.isStarting {
            ProgressView("Avvio di Immich…")
        } else if immich.isRunning {
            ImmichWebView(url: URL(string: "http://127.0.0.1:2283")!)
        } else {
            Button("Avvia Immich") { Task { try? await immich.start(sourceLibraryPath: /* path SSD da BookmarkManager */ "") } }
        }
    }
}
```

- [ ] **Step 3: `ImmichSetupPromptView`** — schermata di conferma esplicita prima di installare (stima spazio disco/tempo, spiegazione in linguaggio semplice di cosa sta per succedere: "verrà scaricato ~X GB e avviato un servizio in background"), bottone "Installa" che chiama `ImmichManager.shared.install()`. Nessuna installazione automatica silenziosa (coerente con la regola generale del progetto).

- [ ] **Step 4: `ImmichWebView`** — wrapper `NSViewRepresentable` attorno a `WKWebView`, carica l'URL passato:

```swift
struct ImmichWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil { webView.load(URLRequest(url: url)) }
    }
}
```

- [ ] **Step 5: Voce nel pannello hamburger** — aggiungere una nuova `HamburgerRow` (o riga equivalente) "Foto" che chiama `openWindow(id: "immich")`, stesso pattern delle voci Catalogo/Tools esistenti.

- [ ] **Step 6: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Immich UI: hamburger entry, gated Window, setup prompt, WKWebView (roadmap #29)"
```

---

## Task 5: Doc update + verifica finale (build/test) + verifica manuale end-to-end

**Files:**
- Modify: `.claude/rules/architecture.md` (nuova voce per `ImmichManager`/`ImmichView`, stesso stile delle voci esistenti)
- Modify: `Docs/ROADMAP.md` (marcare #29 come fatto **solo dopo** la verifica manuale end-to-end riuscita — vedi sotto; controllo incrociato su tutte le righe riassuntive del capitolo #27-30, non fermarsi alla prima occorrenza, stessa lezione applicata per #14/#15/#16/#30)

**Interfaces:**
- Consumes: output dei Task 1-4 (feature completa e buildabile).
- Produces: nessuno (task terminale del piano).

- [ ] **Step 1: Aggiungere una voce in `.claude/rules/architecture.md`** per `ImmichManager`/`ImmichView`, con lo stesso livello di dettaglio delle voci esistenti (vedi la voce Touch ID come modello di stile) — includere esplicitamente: dove vivono i dati (disco interno, mai SSD/HDD), bind solo `127.0.0.1`, external library in sola lettura, il fatto che il gate Touch ID copre anche questa finestra, e **non marcare #29 come "fatto" finché la verifica manuale sotto non è stata eseguita con successo da Enrico**.

- [ ] **Step 2: Build + test finali**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -5
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: entrambi verdi, nessuna regressione sul conteggio test.

- [ ] **Step 3: Commit doc**

```bash
git add .claude/rules/architecture.md
git commit -m "Document Immich integration architecture (roadmap #29, code complete)"
```

- [ ] **Step 4: NON eseguire questo step via agente in background — richiede Enrico presente.** Riportare questo elenco a Enrico come "resta da fare, con te presente" invece di eseguirlo:

**0. ✅ ESEGUITO E PASSATO il 2026-09-03.** Da dentro la VM (`--vm-type vz --mount-type virtiofs`, mount dell'SSD) `ls "/Volumes/SSD - Enri/Foto iPhone"` elenca le sottocartelle e `Foto iPhone/0` conta **1131 file**: il vincolo TCC **non** si applica a Colima, e un volume exFAT via FSKit si monta e si legge in una VM Lima. Riserva: prova fatta da terminale, non dall'app firmata — un fallimento sarebbe stato decisivo, il successo non lo è del tutto. **Trovato durante la prova un bug bloccante indipendente**: il socket della VM sforava `UNIX_PATH_MAX` (117 > 104), quindi `colima start` falliva sempre; corretto spostando `LIMA_HOME` in `~/.appbackupfoto-vm`. Testo originale:  verificare che il conflitto con la regola `Docs/CLAUDE.md` → "Vincolo tecnico macOS Sequoia" (subprocess non ricevono permessi TCC sui volumi esterni) non si applichi anche a Colima. Installare **solo** Colima (poche decine di MB, non l'intero stack Immich), avviarlo con un mount di prova sul path SSD (`colima start --mount "<path SSD>:w"` o equivalente), poi `limactl shell` dentro la VM e `ls "<path SSD montato>"` — se la cartella è vuota o dà permission denied, il problema TCC si applica anche qui e l'intero approccio "External Library sull'SSD via VM" va rivisto con Enrico prima di procedere oltre (Task 5 Step 4 punti 1-10 sotto non hanno senso se questo fallisce). Se invece i file si vedono, procedere pure con gli altri punti.

1. ✅ **Fatto 2026-09-13.** Aprire l'app, andare su hamburger → Foto.
2. ✅ **Fatto 2026-09-13.** Schermata di setup, "Installa": scaricati `colima` e il plugin `docker-compose` (132 MB totali in `immich/bin` contando `limactl` e `docker` già presenti da tentativi precedenti).
3. ✅ **Non si è presentato** (2026-09-13): nessun prompt admin, nessun `sudo`. Coerente col progetto — i binari stanno in `binDir` dentro Application Support, non in `/usr/local/bin`.
4. ✅ **Fatto 2026-09-13.** VM su in ~90 secondi, pull immagini ~4,1 GB, 4 container `healthy`, Immich 3.2.0 che risponde `{"res":"pong"}` su `127.0.0.1:2283`. Socket reale a 64 caratteri contro `UNIX_PATH_MAX` 104.
5. ✅ **Fatto 2026-09-13**, con una differenza da annotare: la web UI si è aperta **dentro la finestra "Foto" dell'app** (`ImmichWebView`), non nel browser di sistema come diceva questo passo. Account admin creato da lì.
6. ✅ **Fatto 2026-09-13.** Chiave creata da Impostazioni account → Chiavi API. Nota: è servita per configurare la libreria via `curl`, **non** perché l'app la richiedesse — nessun campo dell'app l'ha chiesta.
7. ✅ **Fatto 2026-09-13.** External Library creata via API (`POST /api/libraries`) su **`/external-ssd`** — il path *dentro il container*, non `/Volumes/SSD - Enri`. `exclusionPatterns`: `**/Zip/**` (come da review; verificato che dentro `Zip/` ci sono solo archivi `.zip`, zero media sciolti) e **`**/._*`, non previsto da questo piano**, senza il quale Immich importerebbe i 34.969 sidecar AppleDouble con estensione da foto generati dall'SSD exFAT/FSKit. Percorso validato con `POST /api/libraries/:id/validate` (rotta non prevista dal piano, da usare prima dello scan). Scansione: **47.479 media** (39.873 foto + 7.606 video), contro i 47.482 censiti dall'app il 01/09 — 3 di differenza ancora da spiegare.
8. Verificare che le foto dell'SSD compaiano nella griglia Immich (Zip escluso), che la ricerca smart funzioni, che il riconoscimento facce produca risultati sensati su un campione.
9. Chiudere del tutto AppBackupFoto (non solo la finestra) → verificare (`docker ps`) che i container Immich si siano fermati.
10. Riaprire l'app, andare su Foto con l'app bloccata da Touch ID (lock screen) → verificare che la finestra Foto mostri anch'essa la lock screen, non il contenuto.

**Solo dopo che questi punti (0 incluso) sono stati verificati con successo**, tornare su `Docs/ROADMAP.md` e marcare #29 come fatto (stesso controllo incrociato già descritto sopra).
