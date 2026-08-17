# Spec — Integrazione Immich (roadmap #29)

## Problema

Il Catalogo attuale (`CatalogView`, roadmap #12) è inadeguato: le foto sono organizzate per cartelle "a caso" (Foto iPhone, Foto Google Drive, Takeout, Zip...) invece che per metadati (data, luogo, persone). Enrico vuole poter sfogliare e cercare le foto già backuppate in modo reale, con ricerca smart e riconoscimento facce — non solo un elenco di file per nome.

**Fuori scope per questa fase** (deciso in brainstorming, roadmap #29): accesso da telefono/altri dispositivi, diventare il sostituto quotidiano di Apple Foto. Questa fase resta desktop-only, un nuovo strato di consultazione sopra il backup già esistente.

## Ricerca preliminare (2026-08-17, Researcher agent)

Prima di decidere l'architettura, verificato con ricerca su fonti ufficiali (Immich docs, GitHub, Docker docs — dettagli completi nel report di sessione):

- **Stack Docker ufficiale**: 4 servizi — `immich-server`, `immich-machine-learning` (riconoscimento facce/ricerca smart CLIP/OCR, rimovibile se non serve), `redis` (in realtà `valkey`), `database` (Postgres+pgvector, richiede storage SSD locale, mai in rete). *Fonte: [docker-compose.yml ufficiale](https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml), [Requirements | Immich](https://docs.immich.app/install/requirements/).*
- **Risorse**: minimo 6GB RAM dichiarato (4GB se si disabilita l'ML), 2+ core CPU, ~20GB disco per Immich stesso (esclusa la libreria foto). Non pensato per girare leggero in background su un Mac personale insieme ad altre app — tipicamente usato su NAS/home-server. *Fonte: [Requirements | Immich](https://docs.immich.app/install/requirements/).*
- **Gestione Docker su macOS senza interazione GUI**: nessuna opzione è installabile in modo del tutto invisibile. **Colima** (CLI pura, nessuna GUI/EULA, binario scaricabile ed eseguibile via `Process`) è la più scriptabile — richiede comunque un prompt admin una tantum per l'installazione. Docker Desktop è più diffuso ma ha GUI/EULA/licenza. *Fonte: [Colima INSTALL.md](https://github.com/abiosoft/colima/blob/main/docs/INSTALL.md), [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/), [issue su install silenziosa Docker Desktop](https://github.com/docker/for-mac/issues/6302).*
- **API key**: si genera solo dopo un primo login via web UI di Immich — non automatizzabile del tutto in silenzio. Va nell'header `x-api-key`. *Fonte: [Immich API Documentation](https://api.immich.app/authentication).*
- **Versionamento**: prima release stabile v2.0.0 a ottobre 2025, già a v3.1.0 — sviluppo ancora molto attivo, breaking change dichiarati limitati alle sole major release. *Fonte: [GitHub Discussion #22546](https://github.com/immich-app/immich/discussions/22546).*

## Decisioni prese in brainstorming (2026-08-17, one-question-at-a-time)

- **Runtime Docker**: **Colima**, installato/avviato/fermato interamente dall'app (nessuna richiesta all'utente di installare Docker Desktop a parte).
- **Servizio machine-learning**: incluso **da subito** (riconoscimento facce + ricerca smart), non rimandato — priorità dichiarata da Enrico, accettato il costo RAM più alto.
- **Primo setup/API key**: l'app avvia i container e apre il **browser di sistema** (non una WebView incorporata) sulla web UI di Immich per la creazione account e generazione API key, una tantum. Da quel momento in poi l'app parla solo con l'API — mai più il browser per l'uso normale.
- **Origine delle foto**: **libreria esterna (External Library) in sola lettura sull'SSD** — Immich indicizza le foto dove già stanno, nessuna copia/duplicazione. Coerente con "zero delete, zero overwrite": Immich non scrive mai nella cartella foto, solo la legge e mantiene un proprio indice/DB separato.

## Design tecnico

### Dove vive cosa

- **Compose file + dati propri di Immich** (Postgres, cache modelli ML, config) → `~/Library/Application Support/AppBackupFoto/immich/` sul disco interno del Mac, **mai sull'SSD/HDD esterni** — coerente con la ricerca ("Postgres vuole storage locale veloce, mai in rete") e più robusto: se l'SSD viene scollegato, il server Immich resta comunque in piedi (solo la scansione della libreria esterna diventa temporaneamente non disponibile).
- **Libreria foto** → resta sull'SSD dov'è oggi, configurata in Immich come External Library puntata al path del bookmark SSD già esistente in `BookmarkManager`. Nessuna nuova destinazione, nessun nuovo bookmark.
- **Binding di rete**: `immich-server` va configurato per ascoltare **solo su `127.0.0.1`**, mai su `0.0.0.0` — l'accesso da telefono/rete è esplicitamente fuori scope in questa fase, e un server aperto alla LAN senza motivo sarebbe un rischio di sicurezza non necessario per foto private.

### UI di consultazione: WebView, non reimplementazione nativa

Immich ha già una web UI completa (griglia foto, ricerca smart con barra di testo, pagina persone/facce, album) servita dallo stesso `immich-server` su `localhost:2283`. Invece di ricostruire da zero una UI nativa equivalente (grande sforzo, duplicherebbe funzionalità che Immich offre già), la nuova view **incorpora quella web UI in una `WKWebView`** dentro una finestra dell'app.

Motivazione: il problema di Enrico è "il Catalogo fa schifo, voglio sfoglia+ricerca smart+facce" — Immich risolve tutto questo out-of-the-box nella propria UI. Costruire un client nativo dell'API REST per rifare la stessa cosa sarebbe lavoro duplicato senza beneficio reale per un'app single-user. Se in futuro l'esperienza WebView risultasse insoddisfacente, un client nativo via API resta un'opzione da rivalutare separatamente (non preclusa da questa scelta).

### Nuova componente: `ImmichManager`

Nuovo singleton (`ObservableObject`, stesso stile di `BackupRunner`/`AuthGateManager`), responsabile di:
- **Stato**: `installed: Bool`, `isRunning: Bool`, `isStarting: Bool`, `lastError: String?`.
- **Installazione (una tantum)**: scarica il binario Colima + client `docker` CLI, li posiziona in una cartella dell'app (non `/usr/local/bin` di sistema, per non toccare nulla di globale sul Mac di Enrico), richiede conferma esplicita prima di scaricare (stima spazio/tempo — le immagini Docker di Immich sono diversi GB) — coerente con "mai azioni automatiche/silenziose su dati sensibili senza conferma esplicita", stessa disciplina già seguita per Keychain/rclone.conf.
- **Avvio**: `colima start` poi `docker compose up -d` sul compose file di Immich, con health-check (polling su `http://127.0.0.1:2283/api/server/ping` o equivalente) prima di considerarlo pronto — l'avvio reale (VM Colima + Postgres + ML) richiede probabilmente decine di secondi, va mostrato uno stato di caricamento esplicito, mai una finestra bianca.
- **Arresto**: `docker compose down` + `colima stop` — chiamato da `applicationWillTerminate` quando AppBackupFoto viene chiusa del tutto (non ha senso lasciare 6-8GB di container attivi con l'app chiusa). Mentre l'app resta aperta, i container restano su (nessun avvio/arresto per ogni apertura/chiusura della finestra Immich, per evitare il costo di uno startup di decine di secondi ogni volta).
- **Setup External Library**: dopo la creazione account (fatta dall'utente via browser), l'app chiama l'API di Immich per creare la external library puntata al path SSD e avviare la prima scansione — richiede che l'utente abbia incollato/generato la API key nell'app una volta (nuovo campo in Impostazioni o in un nuovo pannello "Foto (Immich)", da definire nel piano).

### Punto d'ingresso UI

Nuova voce nel pannello hamburger, es. "Foto" (o si valuta in piano se sostituire la voce "Catalogo" esistente o affiancarla — decisione rimandata al piano, non blocca la spec). Click su quella voce: se Immich non è installato, propone il primo setup (con conferma esplicita di spazio/tempo); se installato ma fermo, lo avvia (mostrando stato di avvio); una volta pronto, apre la finestra con la `WKWebView`.

**Gate Touch ID**: la nuova finestra segue la stessa regola già stabilita per roadmap #30 — è una nuova `Window` scene di primo livello, quindi va gated con `AuthGateManager.shared` esattamente come `ToolsSheet`/`CatalogView` (vedi `.claude/rules/architecture.md`, nota "ogni nuova Window scene di primo livello va gated allo stesso modo").

## Fuori scope (deciso esplicitamente)

- Nessun accesso da telefono/rete — server Immich bindato solo su `127.0.0.1`.
- Nessuna sostituzione di Apple Foto come app quotidiana.
- Nessun client nativo dell'API Immich in questa fase (si usa la web UI incorporata).
- Nessuna libreria esterna anche su HDD/Cubbit in questa prima fase — solo SSD. Estendere ad altre destinazioni è un'estensione futura, non bloccante per questa spec.
- Nessuna modifica a `FileSyncer`/`S3Syncer`/`BackupRunner`/regole zero-delete-zero-overwrite: Immich legge, non scrive mai, sulla cartella foto.

## Rischi noti, accettati esplicitamente

- **Dipendenza pesante**: prima vera dipendenza esterna "pesante" del progetto (Docker/Colima + un intero servizio di terze parti), diversa da Sparkle (#18, libreria leggera linkata) — più superficie di cose che possono rompersi (aggiornamenti Immich, breaking change tra major version, Colima che smette di funzionare dopo un aggiornamento macOS).
- **Costo risorse**: 6-8GB RAM + spazio disco quando Immich è in esecuzione — accettato da Enrico consapevolmente.
- **Complessità di setup**: nessuna opzione Docker su macOS è installabile in modo invisibile — un minimo di frizione al primo utilizzo (prompt admin, un passaggio nel browser) è inevitabile con lo stato dell'arte attuale.

## Prossimo passo

Spec da approvare esplicitamente da Enrico prima del piano di implementazione — dato lo scope (nuova dipendenza esterna, gestione Docker, nuovo processo in background), è la spec più delicata delle 4 di questo capitolo e merita una lettura attenta prima del via libera.
