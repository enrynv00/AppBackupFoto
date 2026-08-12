---
paths:
  - "AppBackupFoto/ContentView.swift"
  - "AppBackupFotoTests/**"
---

## Architettura Swift (ContentView.swift)

### App entry & Root

- `BackupFotoEnricoApp` (`@main`) → `WindowGroup { RootView() }`
- `RootView` mostra `SetupView` finché `BookmarkManager.allConfigured` non è true, poi `ContentView`
- `Notifier` (enum) → richiede permessi notifiche e invia notifiche di completamento job
- `AppearanceManager` (singleton `ObservableObject`) → forza Chiaro/Scuro/Sistema via `NSApp.appearance`, persistito in UserDefaults

### BookmarkManager (singleton)

- Salva/ripristina bookmark in UserDefaults (chiavi: `bk_photos`, `bk_ssd`, `bk_hdd`)
- **Bookmark NON security-scoped** (`options: []`, non `.withSecurityScope`) — decisione presa il 2026-07-29 dopo un bug reale: la root di un volume ExFAT (es. `/Volumes/SSD - Enri`) fa fallire `bookmarkData(options: .withSecurityScope, ...)` con `NSCocoaErrorDomain` codice 256, un limite noto e mai risolto di macOS sui filesystem ExFAT/FAT — non un bug dell'app (stesso codice, stesso identico path, funziona su APFS come `BackupHDD`). L'app non è sandboxata (`ENABLE_APP_SANDBOX = NO`) e ha Full Disk Access, quindi il meccanismo di security scope non serve: `FileManager` legge/scrive comunque ovunque. Verificato che i bookmark creati in passato con `.withSecurityScope` si risolvono correttamente anche con `options: []`, quindi nessuna migrazione necessaria per bookmark già salvati.
- `startAccessing(_ loc)` → restituisce l'URL salvato (nessuno scope da avviare) · `stopAccessing(_ loc)` → no-op, mantenuto per compatibilità con i call site esistenti (`defer { bm.stopAccessing(...) }` in `BackupRunner`/`ReviewEngine`)
- `allConfigured` → true se tutte e 3 le cartelle sono selezionate (usata come informazione, non più come gate d'ingresso)
- `canEnterApp` → true se solo la Libreria Foto è selezionata — è questa a decidere se `RootView` mostra `ContentView` o `SetupView`: SSD/HDD non sono obbligatori per entrare, dato che sono dischi esterni che potrebbero non essere collegati in un dato momento (le operazioni che li richiedono restano comunque disattivate finché non li configuri)
- Se un volume esterno non compare/non si lascia selezionare in `NSOpenPanel`, o se salvare la cartella "non fa nulla", `selectAndSave` mostra un `NSAlert` con l'errore reale (dominio/codice) invece di fallire in silenzio — utile diagnostica se il problema si ripresenta su un altro volume

### FileSyncer (sync locale Mac→SSD e SSD→HDD)

- Copia file via `FileManager.copyItem` — zero subprocess
- Confronto: data + dimensione (default) o solo dimensione (deep mode)
- Esclude: `.DS_Store`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `lost+found`, `Backups.backupdb`, `._*`
- **Zero-overwrite enforcement**: se il file esiste già a destinazione (anche con contenuto diverso) viene sempre skippato, mai sovrascritto — mai un branch di codice che chiama `copyItem` su un path esistente
- **Verifica SHA256 post-copia**: ogni file copiato viene ri-hashato e confrontato con la sorgente; mismatch → `hashErrors` (contatore separato dagli errori I/O), loggato come "⚠️ HASH MISMATCH"
- `previewSync(from:to:deep:)` → dry-run: conta `toAdd`/`toSkip`/tempo stimato senza copiare nulla (usato dai bottoni 👁 anteprima)
- Callbacks: `onStatus(String)` e `onProgress(SyncResult)` per ogni file

### S3Syncer (upload S3 nativo, SSD→Cubbit)

- **Credenziali nel Keychain**: `readConfig()` prova prima il Keychain (`kSecAttrService: "AppBackupFoto"`), fallback a `~/.config/rclone/rclone.conf` (sezione `[Cubbit]`) se vuoto, con adozione silenziosa best-effort nel Keychain al primo utilizzo utile. Nessun form di inserimento credenziali nell'app: l'utente continua a modificare `rclone.conf` a mano e forza un nuovo adottamento con il bottone "Aggiorna da rclone.conf" in Tools (nessun rilevamento automatico delle modifiche al file — scelta deliberata, coerente con "mai azioni automatiche su dati sensibili").
- **Guardie di sicurezza su `readConfig`**: rifiuta se i permessi del file sono più aperti di `0600`; rifiuta se l'endpoint non è HTTPS; **allow-list dell'host** (`s3.it.cubbit.org`) — se rclone.conf viene alterato per puntare altrove, il caricamento si blocca finché l'host non viene aggiunto esplicitamente alla allow-list nel codice
- List bucket con paginazione (ListObjectsV2), confronto per key+size per decidere cosa caricare (mai DELETE/overwrite remoto)
- PUT per file < 64MB, multipart per file ≥ 64MB (chunk da 64MB), lettura parti via `readFileInChunks` (POSIX low-level, stesso fix di `sha256(of:)` — vedi sezione dedicata sotto)
- **Upload paralleli**: `sync()` carica fino a 4 file diversi in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Le parti di un singolo multipart restano sequenziali (parallelizzarle non aiuterebbe: sui pochi file enormi il collo di bottiglia è la banda, non la latenza per richiesta). Cancellazione controllata dentro ogni task figlio prima di ogni chiamata di rete, non solo nel loop di schedulazione.
- **Cancel su multipart** → chiama `AbortMultipartUpload` (nessuna parte orfana lasciata sul bucket)
- **Retry con backoff**: ogni chiamata HTTP di upload (PUT singolo, init/parte/complete multipart) viene ritentata fino a 3 volte (1s poi 2s di attesa) per errori transitori (`URLError`, HTTP 5xx) — non per errori permanenti (HTTP 4xx) né se l'utente interrompe (`cancelled`/`Task.isCancelled` controllati prima di ogni attesa). Vedi `S3Syncer.retrying`/`isRetryable`/`S3HTTPError`.
- **Pulizia upload multipart orfani**: `listMultipartUploads`/`abortMultipartUpload` (quest'ultima condivisa col cancel già esistente durante un job). Scoperta automatica nel pannello Revisione (Tools) quando nessun job è in corso, cancellazione sempre dietro conferma esplicita per singolo upload — mai automatica.
- AWS Signature V4 implementata manualmente — host NON va in `allHTTPHeaderFields`; `/` e `()` vanno encoded nella query string

### VolumeMonitor (`ObservableObject`)

- Polling ogni 3s su `/Volumes/SSD - Enri` e `/Volumes/BackupHDD` → `ssdMounted`/`hddMounted` pubblicati
- Guida l'abilitazione dei bottoni in `SidebarView` (MAC→SSD e SSD→S3 richiedono SSD montato; SSD→HDD richiede entrambi)

### BackupRunner (`@MainActor ObservableObject`)

- Coordina `FileSyncer` e `S3Syncer`, pubblica `phase`/`stats`/`output`/`speedHistory` per la UI
- `runMacToSSD()` / `runSSDToHDD()` / `runSyncS3()` — ciascuno valida gli accessi bookmark, poi valida **che il bookmark punti alla root del volume** (`isLikelyVolumeRoot`: `pathComponents.count <= 3`) prima di avviare, con alert esplicito se il path non è la root (fix del vecchio BUG-1)
- **Controllo spazio libero (2026-08-09)**: `runMacToSSD()` e `runSSDToHDD()` calcolano i byte da copiare (`FileSyncer.previewSync`, esteso con `toAddBytes`) e li confrontano con lo spazio libero reale sul volume di destinazione (`hasSufficientSpace`, margine 5%/min 500MB) prima di chiamare `run()` — se insufficiente, alert bloccante e il job non parte mai. SSD→S3 non è coperto (nessun limite pratico su Cubbit).
- `previewMacToSSD()` / `previewSSDToHDD()` — dry-run: mostrano un `NSAlert` con conteggio file/tempo stimato senza avviare la copia
- Deep mode SSD→HDD ogni 30 giorni (UserDefaults `lastDeepMirrorDate`), aggiornato solo se il job deep è terminato senza errori
- `speedHistory`/`speedUnit` alimentano `SpeedChartView` — MB/s per S3, file/s per FileSyncer, "scan/s" durante la fase di conteggio
- `stop()` cancella `syncer`/`s3Syncer`/`syncTask`, imposta `wasStopped` per evitare un doppio update della UI dopo l'interruzione; cattura `phase.label` prima di sovrascrivere `phase`, così il riepilogo persistito mantiene il nome del job originale
- Alla fine di ogni job (successo, errore o stop manuale) salva un `JobSummary` in `JobHistoryStore`
- **Segnalazione file cambiati (2026-08-09, roadmap #13)**: `JobStats`/`JobSummary` guadagnano `changedSkipped` — file esistenti a destinazione ma diversi dalla sorgente, skippati per zero-overwrite (mai sovrascritti, solo segnalati). Calcolato dove il confronto già avviene (`FileSyncer.syncFile`, `S3Syncer.isChangedExistingKey`), mostrato in `CompletionSheet` come conteggio (nessun nome file, nessuna voce in Revisione). Decisione esplicita go/no-go: nessun salvataggio automatico di nuove versioni (scartato, troppo rischio/complessità per la regola zero-overwrite).
- **Backup automatico Mac→SSD al collegamento SSD**: `ContentView` osserva `volumes.ssdMounted` (`.onChange`) e chiama `runMacToSSD()` da sola quando passa da scollegato a collegato, se l'app è aperta e il toggle "Backup automatico" in Impostazioni è attivo (`@AppStorage("autoBackupOnSSDConnect")`, default acceso). Solo Mac→SSD si automatizza — SSD→HDD e SSD→S3 restano manuali. Nessun LaunchAgent: non funziona ad app chiusa (richiederebbe prima una modalità menu bar/background, non ancora fatta).
- **Notifica di errore (2026-08-09, roadmap #16)**: il ramo `catch` di `run()` ora invia una notifica di sistema (`Notifier.send`) quando un job fallisce per un errore reale (rete, I/O) — prima nessuna notifica veniva inviata in caso di errore, solo in caso di successo. Non scatta su stop manuale (`wasStopped` già escluso dalla guard esistente). Nessun bottone "Riprova": deciso esplicitamente contro in brainstorming, complessità (categoria + delegate + routing per job) sproporzionata per un'app single-user. Vedi `Docs/superpowers/specs/2026-08-09-error-notification-design.md`.
- **Miniatura live dell'ultimo file (2026-08-09, roadmap #17)**: `BackupRunner.publishCurrentFile(_:)` riceve l'URL del file corrente da un nuovo callback `onCurrentFile`, threaded attraverso `FileSyncer.sync/syncDir/syncFile` e `S3Syncer.sync` (default no-op sulle firme pubbliche, `RestoreEngine` non toccato). Per le immagini genera una miniatura leggera via ImageIO (`CGImageSourceCreateThumbnailAtIndex`, mai l'immagine intera in memoria — stessa lezione del bug di memoria di `sha256(of:)`), per il resto usa l'icona di sistema (`NSWorkspace.shared.icon(forFile:)`). Un token (`thumbnailRequestID`) scarta miniature arrivate in ritardo su file già superati. Pubblicato in `currentThumbnail`, mostrato in `StatsPanel` (`CurrentFileThumbnail`) solo live durante il job, non nel `CompletionSheet`. Vedi `Docs/superpowers/specs/2026-08-09-current-file-thumbnail-design.md`.
- **Auto-update (2026-08-10, roadmap #18)**: `UpdaterViewModel` (wrapper `ObservableObject` attorno a `SPUStandardUpdaterController` di Sparkle 2.x, aggiunto via SPM — prima dipendenza esterna del progetto) avvia un check automatico in background (1 volta/giorno, `SUScheduledCheckInterval` in `AppBackupFoto/Info.plist`); l'installazione richiede sempre un click esplicito dell'utente sull'alert standard di Sparkle, mai automatica. Voce "Controlla aggiornamenti" in `HamburgerPanel` per il check manuale. Il target è passato da Info.plist generato a un `Info.plist` fisico (necessario per tipizzare correttamente `SUEnableAutomaticChecks`/`SUScheduledCheckInterval` come booleano/intero). Chiave privata EdDSA nel Keychain di questo Mac (mai in git), backup esplicito in un posto sicuro fuori dal repo. Pubblicazione automatizzata da `Script/release.sh` (archive → firma con `sign_update` → GitHub Release → nuovo `<item>` inserito in `appcast.xml`). Repo GitHub pubblico ancora da creare — `PLACEHOLDER-github-username` in `Info.plist`/`appcast.xml`/`Script/release.sh` va sostituito appena disponibile. Vedi `Docs/superpowers/specs/2026-08-10-sparkle-auto-update-design.md`.
- **Badge di Revisione all'avvio (2026-08-11, roadmap #20)**: `ContentView.task` esegue una volta, al primo apparire, `ReviewEngine.runConfigChecks(...)` (bookmark/permessi rclone.conf/endpoint S3, include già `checkDeepMirrorFreshness`) e pubblica il risultato in `runner.toolsReviewFindings` — stesso campo già letto da `ToolsSheet` per l'apertura manuale. Esclusi deliberatamente dal check automatico: campione di integrità (`runIntegritySample`, tocca volumi/rete) e scoperta upload multipart orfani (rete S3) — restano solo su richiesta esplicita in Tools. Se `toolsReviewFindings` non è vuoto, `HamburgerRow` mostra un pallino rosso discreto (nuovo parametro `alert: Bool`) sulla sola voce "Tools" — non su Dock/menu bar, riservati allo stato job (#11/#15). Nessun timer periodico, nessuna azione correttiva automatica: solo segnalazione passiva, coerente col resto di `ReviewEngine`.

### ReviewEngine (pannello "Revisione", in `ToolsSheet`)

- `runConfigChecks() -> [ReviewFinding]` — sincrono, nessun accesso ai volumi: valida che i bookmark SSD/HDD puntino alla root del volume, i permessi di `rclone.conf`, l'endpoint S3 (via `S3Syncer.readConfig()`)
- `checkDeepMirrorFreshness(hddConfigured:defaults:now:)` — nuovo finding (2026-08-08) che segnala se il deep mirror SSD→HDD non gira da più di 45 giorni, o non è mai girato (`lastDeepMirrorDate` assente). Nessun finding se l'HDD non è configurato. Solo passivo: visibile aprendo Tools → Revisione, nessuna notifica di sistema.
- `runIntegritySample(sampleSize:onProgress:) async -> [IntegrityCheckResult]` — su richiesta (bottone dedicato): ricampiona 20 file a caso per coppia (Mac↔SSD, SSD↔HDD, SSD↔S3), ricalcola SHA256 e confronta; per S3 scarica il campione in un file temporaneo e lo cancella subito dopo l'hash. Salta (non fallisce) le coppie i cui bookmark non sono accessibili
- `sampleLocalPair(...)` usa `realpath()` (non `URL.resolvingSymlinksInPath()`, che lascia `/var`/`/tmp` non risolti di proposito su macOS) per calcolare correttamente i path relativi quando confronta directory temporanee — dettaglio scoperto scrivendo i test, importante se si tocca di nuovo questa logica
- `JobSummary`/`JobHistoryStore` — riepilogo dell'ultimo job (data, label, copiati/skippati/errori/hash-mismatch), persistito in UserDefaults (`defaults` parametrizzato per testabilità), sopravvive al riavvio dell'app
- Il motore **segnala soltanto**: nessuna `removeItem`/`copyItem`/scrittura S3 verso una destinazione persistente

### RestoreEngine e RestoreView (ripristino guidato)

- `RestoreEngine` — separato da `BackupRunner`, riusa `FileSyncer` invariato per SSD/HDD; per Cubbit usa `S3Syncer.downloadMany`. Modello di progresso volutamente semplice (`RestoreProgress`: done/total/eta/problems), non `JobStats` — la UI di restore non mostra copiati/skippati/errori/hash-mismatch, solo una barra e "Recuperate X di Y foto" in linguaggio comune.
- `RestoreView` — 4 passi: scelta fonte (con indicatori di disponibilità in tempo reale: `VolumeMonitor` per SSD/HDD, `S3Syncer.checkReachable` per Cubbit — le fonti non disponibili in quel momento sono disattivate e motivate, non semplici bottoni che poi falliscono), scelta cartelle (spunta, tutte selezionate di default), scelta destinazione (stesso selettore usato altrove), avanzamento. Prima di un restore da Cubbit mostra una stima (conteggio file + GB) con conferma esplicita.
- Le foto ripristinate atterrano in una cartella normale sul Mac, **non** nella libreria interna di Foto.app (troppo rischioso toccare il suo database privato) — l'utente le importa lui con un paio di click.
- Raggiungibile da hamburger → Ripristina, e da un bottone secondario in `SetupView` (visibile anche a configurazione incompleta, grazie a `canEnterApp`).

### Bug critico risolto: `sha256(of:)` e file molto grandi (2026-07-30)

Un restore locale reale della cartella `Zip` dell'SSD (15 file, tra cui due archivi da ~50GB: `takeout-001.zip` 53,5GB e `takeout-002.zip` 44,5GB) ha fatto salire il processo a 41-43GB di RAM (37GB di swap), quasi bloccando il Mac. Causa trovata e verificata empiricamente (non solo per lettura del codice): `sha256(of:)` — la funzione condivisa usata sia da `FileSyncer` (verifica integrità post-copia, su sorgente **e** destinazione) sia da `ReviewEngine` — leggeva il file con `FileHandle.readData(ofLength: 65536)` in un ciclo. Il chunking a 64KB è corretto sulla carta, ma su questo carico `FileHandle`/`NSData` mantiene le pagine lette residenti in memoria invece di rilasciarle tra una lettura e l'altra: la RAM cresce in proporzione ai byte totali letti, non alla dimensione del buffer. Per un file di pochi MB non si nota; per un file da 50GB, letto due volte (sorgente + destinazione), diventa un problema di sistema.

Fix verificato prima di toccare il codice reale: stesso file da 2GB (`Zip/Elba-...zip`), stesso hash risultante — `FileHandle.readData(ofLength:)` picco 4,09GB di memoria residente; `open`/`read`/`close` POSIX a basso livello (stesso buffer da 64KB, riusato) picco 61MB. 67 volte meno memoria, leggermente più veloce. `sha256(of:)` ora usa questa versione POSIX — nessun'altra modifica necessaria, la funzione resta drop-in per entrambi i chiamanti.

**Lezione per il futuro**: se un'altra funzione in questo progetto legge file di grandi dimensioni via `FileHandle`, verificarne il comportamento in memoria su file realmente grandi (decine di GB) prima di fidarsi del chunking sulla carta — non è garantito che basti leggere "a blocchi" per avere memoria costante.

### Stessa lezione applicata: `multipart()` upload (2026-08-02)

Rileggendo il codice durante il brainstorming per gli upload paralleli, `multipart()` (upload dei file ≥64MB verso Cubbit) usava lo stesso pattern a rischio: `FileHandle(forReadingFrom:)` + `readData(ofLength: chunkSize)` in un ciclo per leggere le parti da 64MB. Non è stato ancora misurato empiricamente un picco di memoria su un multipart reale (serve un upload di ore su uno degli zip da 40-50GB), ma è la stessa firma di codice del bug già trovato — corretto preventivamente riusando `S3Syncer.readFileInChunks` (stesso `open`/`read`/`close` POSIX con buffer riutilizzato). Verifica manuale con Monitor Attività ancora da fare da parte dell'utente.

---

## UI (SwiftUI views in ContentView.swift)

- **SetupView / LocationRow** — onboarding iniziale, selezione delle 3 cartelle
- **ContentView** — `NavigationSplitView` (roadmap #22, 2026-08-12) con `SidebarView` come colonna sidebar (range 220-260pt, collasso nativo) e il pannello principale (fase corrente, `SpeedLogPanel`, `StatsPanel`, bottone Interrompi/Esci) come `detail`, ancorato in alto (`alignment: .top`, fix del content-centering introdotto dal fix del bug finestra del Task 2). Liquid Glass: sidebar già traslucida col solo materiale automatico di sistema di `NavigationSplitView` (nessun `.background` esplicito necessario), barra superiore invece richiede `.background(.regularMaterial)` esplicito (`.bar` da solo non bastava, macOS 26, deployment target alzato in questa fase). Il pannello hamburger resta un overlay `ZStack` separato, invariato.
- **SidebarView** — hamburger `[☰]`, stato volumi (`VolumeRow`), i 3 `OpsButton` (con bottone 👁 anteprima per Mac→SSD e SSD→HDD)
- **HamburgerPanel** — pannello laterale con: Report Log (apre il tab Log inline, non un subprocess), Ripristina (`RestoreView`), Configurazione (`SettingsSheet`), Tools (`ToolsSheet`), Aspetto (`AppearanceSheet`), Lingua (apre System Settings). Nessun Login/Password: app locale single-user, credenziali S3 disponibili solo in Tools → Diagnostica dietro conferma esplicita.
- **MenuBarExtra (2026-08-09)** — icona nella menu bar (SF Symbol `photo.stack`, pulsa con `.symbolEffect(.pulse)` mentre un job è in corso) con menu a discesa: riga di stato (job in corso / data ultimo backup / nessun backup) + bottone "Apri AppBackupFoto" (`openWindow(id: "main")` + `NSApp.activate`). Solo scorciatoia — l'app resta un'app normale con Dock icon e finestra, nessun `LSUIElement`, nessuna estensione dello scheduling automatico ad app chiusa (deliberatamente fuori scope, vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`).
- **Badge percentuale sul Dock (roadmap #15, 2026-08-09)** — `MenuBarIcon` osserva `runner.stats.percent`/`runner.isRunning` (`.onChange`) e imposta `NSApp.dockTile.badgeLabel = "\(percent)%"` mentre un job è in corso, `nil` altrimenti — stessa fonte dati (`BackupRunner.stats.percent`) già usata dalla progress bar della finestra principale, nessuna nuova proprietà pubblicata. Vedi `Docs/superpowers/specs/2026-08-09-dock-badge-design.md`.
- **CatalogView (2026-08-09)** — finestra indipendente "Catalogo" (`Window`, stesso pattern di Diagnostica), aperta da hamburger → Catalogo: Picker per la destinazione (SSD/HDD/Cubbit S3, disattivata se non disponibile), ricerca live per nome/cartella su dati scansionati dal vivo a ogni apertura (nessun indice persistito). SSD/HDD via `ReviewEngine.scanLocalCatalog`, Cubbit via il nuovo `S3Syncer.listAllWithDates` (separato da `listAll`/`listPage`, non li tocca). Sola lettura, nessuna azione sugli elementi elencati. Credenziali S3 dalla cache condivisa `runner.s3Config`, caricata dalla finestra principale prima di aprire la finestra Catalogo.
- **ToolsSheet** — diagnostica: stato bookmark configurati, config S3 (endpoint/bucket/region), AccessKey/SecretKey mascherate con reveal dietro `NSAlert` di conferma, ultimo deep mirror, sezione "Revisione" (config checks, ultimo job persistito, verifica integrità campione su richiesta — vedi `ReviewEngine`). **Non è più uno sheet modale** (2026-08-08): è una `Window` scene SwiftUI indipendente (id `"tools"`, singleton — riaprirla la porta in primo piano invece di duplicarla), spostabile e ridimensionabile liberamente, aperta da `HamburgerPanel` via `openWindow(id: "tools")`. Legge lo stato del job in corso (`BackupRunner.isRunning`) dal vero `environmentObject` condiviso con la finestra principale (non più un `Bool` congelato all'apertura), quindi resta aggiornata mentre l'utente continua a usare l'app. Nome del tipo invariato (`ToolsSheet`) nonostante non sia più uno sheet — non rinominato per restare nello scope minimo del cambiamento. Vedi `Docs/superpowers/specs/2026-08-08-tools-window-design.md`.
- **SpeedLogPanel / SpeedChartView** — grafico velocità real-time (Charts framework) + tab Log con output testuale
- **CompletionSheet / StatsPanel** — riepilogo copiati/skippati/errori/hash-mismatch a fine job

### Design Tokens (2026-08-12, roadmap #21, Fase 1)

`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize` (inizio `ContentView.swift`, subito dopo gli import): palette semantica (stato: successo/errore/warning/in-corso; identità destinazione: Mac→SSD/SSD→HDD/SSD→Cubbit; utility: Tools/Configurazione), griglia di spacing 4/8/12/16/24/32, 5 ruoli di testo (titolo/intestazione/corpo/didascalia/numero-hero), 2 taglie icona hero (36/48). Migrazione completa dei valori hardcoded preesistenti — nessun colore/font/spacing arbitrario rimasto fuori dai token, salvo 2 eccezioni documentate nel codice: l'etichetta `.caption2` sotto il numero in `CStat`/`StatCard` (contesto card compatta) e i 6 colori decorativi delle voci `HamburgerRow` diverse da Tools (fuori scope, non fanno parte della palette semantica a 7 token). Nessun cambio strutturale alle view — solo valori. Vedi `Docs/superpowers/specs/2026-08-12-design-foundations-design.md`.

**Componenti unificati (2026-08-12, roadmap #23, Fase 3)**: `.cardBackground()` (ViewModifier) consolida le 9 occorrenze del pattern card in un solo punto. `StatCard`/`CStat` (duplicati, differivano solo per `frame`) uniti in `StatTile` con parametro `compact: Bool`. I 4 `GroupBox` di `ToolsSheet` usano `CardGroupBoxStyle` (applicato una volta sul contenitore radice del `body`, si propaga via environment) per lo stesso linguaggio visivo delle altre card — nessun cambio al contenuto interno dei blocchi. Nessuna resa visiva diversa da prima in nessuno dei tre casi, solo consolidamento di codice duplicato.

**Micro-interazioni (2026-08-12, roadmap #24, Fase 4)**: hover feedback (tint di sfondo leggero) su `HamburgerRow`, `OpsButton` (bottone principale), e le righe del wizard Ripristina (`restoreSourceRow`, `s3SourceRow`, `chooseFoldersStep` — condividono un `@State` su `RestoreView` dato che non sono struct `View` indipendenti). `contentTransition(.numericText())` su `StatTile.value` e sui contatori percentuale/velocità di `StatsPanel`. `contentTransition(.symbolEffect(.replace))` sull'icona di stato in `PhaseIndicator`. `LocationRow` esclusa deliberatamente (non è una riga cliccabile a tutta larghezza, solo il bottone interno lo è, già con hover nativo). Nessuno skeleton/`.redacted` — nessun caso reale identificato nel codice attuale.

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
