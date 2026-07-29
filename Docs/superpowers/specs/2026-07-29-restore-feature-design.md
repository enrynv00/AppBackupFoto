# Restore — ripristino guidato da SSD/HDD/Cubbit

Data: 2026-07-29
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto 1 (Critico): l'app sa solo copiare in avanti (Mac→SSD→HDD→S3). Se il Mac si guasta o viene sostituito, oggi non esiste un percorso guidato per recuperare le foto — è l'unica cosa che manca perché questa sia davvero un'app "di backup" e non solo un sincronizzatore a senso unico.

Vincolo esplicito dell'utente, guida per ogni scelta di questo documento: l'app **non deve essere per esperti**. Ogni schermata di questo flusso deve restare comprensibile a chi non ha alcuna competenza tecnica — niente gergo, niente contatori tecnici a meno che non servano davvero.

## Scope

Dentro scope:
- Scenario principale: disastro totale (Mac nuovo/formattato, Libreria Foto vuota), ma il flusso funziona qualunque sia lo stato del Mac.
- Restore da una delle tre fonti esistenti (SSD, HDD, Cubbit S3), scelta dall'utente ogni volta — l'app non sceglie automaticamente.
- Selezione a livello di cartella (Foto iPhone, Foto Google Drive, Other, Takeout, Takeout 2, Zip) — non selezione per singolo file o per data.
- Destinazione: una cartella normale sul Mac, scelta dall'utente con lo stesso selettore già usato altrove nell'app — non scrittura diretta nel database interno di Foto.app.
- Raggiungibile sia dalla schermata di configurazione iniziale (anche a setup incompleto) sia dal menu hamburger dell'app già configurata.
- Schermata di avanzamento deliberatamente più semplice di quella delle altre operazioni: barra, conteggio in linguaggio comune, tempo stimato — non i contatori tecnici di `JobStats`.
- Stima preventiva (dimensione/tempo) prima di avviare un restore da Cubbit, per non far partire alla cieca un download potenzialmente enorme.
- **Indicatore di disponibilità in tempo reale per tutte e 3 le fonti nel primo passo** — l'utente ha fatto notare un caso reale (SSD collegato, HDD scollegato, Cubbit non raggiungibile in quel momento) in cui mostrare 3 bottoni identicamente cliccabili è fuorviante: quelli non disponibili vanno disattivati e motivati, non lasciati lì a fallire se premuti.
- Fix di un bug di correttezza già trovato in `BackupRunner.run()` (vedi sotto), incluso in questo lavoro perché il nuovo motore di restore avrebbe lo stesso identico scenario a rischio.

Fuori scope (esplicitamente, per questa iterazione):
- Nessuna scrittura diretta nella libreria di Foto.app (troppo rischioso: richiederebbe l'API privata di import di Photos, non solo copia di file — l'utente importa lui stesso in Foto con un paio di click dopo il restore).
- Nessuna selezione granulare per singolo file o intervallo di date — solo a livello di cartella.
- Nessuna scelta automatica della "fonte migliore" — l'utente sceglie sempre esplicitamente.
- Nessun redesign delle altre schermate dell'app (StatsPanel, SpeedLogPanel, ecc. restano come sono) — la semplificazione riguarda solo questa nuova funzione, il resto dell'app resta un punto della roadmap separato da affrontare in futuro.
- Nessuno split di `ContentView.swift` in più file — tutto il nuovo codice resta nel file unico, coerente con la convenzione già stabilita nella sessione precedente.

## Architettura

Nuovo blocco `// MARK: - Restore` in `AppBackupFoto/ContentView.swift`. Il motore è deliberatamente separato da `BackupRunner`: riusa `FileSyncer` così com'è (nessuna modifica, zero rischio sul codice già testato) e aggiunge due funzioni nuove a `S3Syncer` per il download, ma non riusa `JobStats`/`StatsPanel`/`CompletionSheet` — quelle sono il modello "tecnico" che qui vogliamo evitare.

### `RestoreEngine` (nuova classe, `@MainActor ObservableObject`)

```swift
enum RestoreSource: String, Identifiable {
    case ssd, hdd, s3
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ssd: return "Dal mio SSD"
        case .hdd: return "Dal mio HDD"
        case .s3:  return "Da Cubbit (cloud)"
        }
    }
}

struct RestoreProgress {
    var done: Int = 0
    var total: Int = 0
    var startDate: Date = Date()
    var problems: [String] = []   // "nomefile — motivo in linguaggio semplice"
    var percent: Int { total > 0 ? min(100, done * 100 / total) : 0 }
    var etaSec: Int {
        guard done > 0, total > done else { return 0 }
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0.5 else { return 0 }
        return Int(elapsed * Double(total - done) / Double(done))
    }
}

@MainActor
final class RestoreEngine: ObservableObject {
    @Published var phase: JobPhase = .idle   // riuso il tipo esistente: idle/running/success/failed, niente di tecnico
    @Published var progress = RestoreProgress()

    private let syncer = FileSyncer()        // istanza dedicata, non condivisa con BackupRunner
    private let s3Syncer = S3Syncer()
    private var cancelled = false
    private var wasStopped = false

    func listAvailableFolders(rootURL: URL) -> [String] {
        // sottocartelle di primo livello di rootURL, stesse esclusioni di sempre
        // (niente nascosti, niente ._*), ordinate alfabeticamente
    }

    func listAvailableFolders(fromS3Config config: S3Syncer.S3Config) async throws -> [String] {
        let keys = try await s3Syncer.listAll(config: config).keys
        return S3Syncer.topLevelFolders(fromKeys: Array(keys))
    }

    func estimateS3Download(selectedFolders: Set<String>, destination: URL, config: S3Syncer.S3Config) async throws -> (count: Int, bytes: Int64)

    func run(source: RestoreSource, selectedFolders: Set<String>, sourceRootURL: URL?,
             destination: URL, s3Config: S3Syncer.S3Config?)

    func stop()
}
```

**`run(...)`**:
- Per `.ssd`/`.hdd`: per ciascuna cartella selezionata, prima passa `previewSync(from: sourceRoot/folder, to: destination/folder, deep: false)` per sommare i totali attesi, poi esegue `syncer.sync(from:to:deep:onStatus:onProgress:)` una cartella alla volta, accumulando `done`/`total` in `RestoreProgress`. Zero-overwrite già garantito da `FileSyncer` così com'è.
- Per `.s3`: chiama la nuova `S3Syncer.downloadMany(selectedFolders:config:destination:onStatus:onProgress:)` (vedi sotto).
- Errori su singoli file **non** interrompono il resto: vengono accumulati in `progress.problems` con un messaggio semplice (nome file + cartella), il conteggio prosegue.
- **Fix incluso**: sia il ramo di completamento normale sia `stop()` controllano `wasStopped` prima di scrivere `phase`, replicando correttamente il pattern che oggi manca nel ramo di successo di `BackupRunner.run()` (vedi sezione dedicata sotto) — qui il bug non viene mai introdotto fin dall'inizio.

### `S3Syncer` — tre aggiunte

```swift
extension S3Syncer {
    // Funzione pura, testabile senza rete: prende le chiavi del bucket e restituisce
    // i nomi delle cartelle di primo livello (es. "Foto iPhone", "Takeout 2", ...).
    static func topLevelFolders(fromKeys keys: [String]) -> [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for key in keys {
            guard key.contains("/"), let first = key.split(separator: "/", maxSplits: 1).first else { continue }
            let name = String(first)
            if !seen.contains(name) { seen.insert(name); ordered.append(name) }
        }
        return ordered.sorted()
    }

    struct DownloadManyResult {
        var downloaded = 0; var skipped = 0; var total = 0; var done = 0
        var problems: [String] = []
    }

    func downloadMany(selectedFolders: Set<String>, config: S3Config, destination: URL,
                       onStatus: @escaping (String) -> Void,
                       onProgress: @escaping (DownloadManyResult) -> Void) async throws -> DownloadManyResult

    // Controllo rapido di raggiungibilità, usato solo dal primo passo del restore per
    // decidere se il bottone "Da Cubbit" è selezionabile. Timeout breve (4s): non deve
    // far percepire la schermata come bloccata se il cloud non risponde.
    func checkReachable(config: S3Config, timeoutSec: Double = 4) async -> Bool
}
```

`downloadMany` lista tutte le chiavi del bucket (`listAll`, già esistente), le filtra tenendo solo quelle il cui primo componente di percorso è in `selectedFolders`, e per ciascuna: se il file esiste già in `destination/key` la salta (zero-overwrite), altrimenti chiama `downloadToTemp(key:config:)` (già esistente, usato oggi dal campione di integrità) e sposta il file temporaneo nella posizione finale, creando le sottocartelle necessarie. Un errore su un file singolo va in `problems` e non interrompe gli altri.

`checkReachable` fa una singola richiesta minima (lista con `max-keys=1`, riusando la stessa firma già presente in `listPage`) su una `URLSession` con `timeoutIntervalForRequest` impostato al valore passato; qualunque errore (rete assente, timeout, credenziali non valide) restituisce `false` senza propagare l'errore — qui interessa solo un booleano "posso provarci o no", il messaggio d'errore dettagliato resta comunque disponibile più avanti se l'utente sceglie comunque Cubbit e qualcosa va storto lì.

### `RestoreView` (nuova, presentata come `.sheet`)

Stato interno:
```swift
enum RestoreStep { case chooseSource, chooseFolders, chooseDestination, running }
```

1. **`chooseSource`** — tre bottoni grandi (SSD/HDD/Cubbit), **ciascuno con lo stato reale mostrato subito**, non semplici bottoni sempre attivi:
   - `RestoreView` istanzia un proprio `@StateObject private var volumes = VolumeMonitor()` (stessa classe già usata da `ContentView`, un'istanza separata e leggera — nessun singleton necessario). Il bottone SSD è attivo solo se `volumes.ssdMounted`, quello HDD solo se `volumes.hddMounted`; se disattivo, mostra una riga secondaria "non collegato in questo momento" invece di restare silenziosamente non cliccabile.
   - Il bottone Cubbit parte in stato "verifica in corso…" (spinner piccolo) appena si arriva su questo passo: in `.task` chiama `S3Syncer.checkReachable(config:)` (se `readConfig()` fallisce prima ancora di provare la rete, mostra subito "configurazione mancante" senza attendere il timeout). Al risultato, il bottone diventa selezionabile o disattivato con "non raggiungibile in questo momento".
   - Per SSD/HDD attivi: se il bookmark è già configurato lo riusa, altrimenti apre subito il selettore cartella (stesso meccanismo di `BookmarkManager.selectAndSave`, che nel farlo salva anche il bookmark normale — comodo se l'utente sta configurando l'app da zero mentre ripristina).
2. **`chooseFolders`** — lista con spunta delle cartelle disponibili nella fonte scelta (da `listAvailableFolders`), tutte selezionate di default.
3. **`chooseDestination`** — stesso selettore cartella già usato altrove; scelta non persistita in `BookmarkManager` (è un target una tantum, non una delle 3 posizioni fisse dell'app).
4. **`running`** — barra di avanzamento, "Recuperate X di Y foto", tempo stimato. Se la fonte è Cubbit, prima di entrare in questo step viene mostrato un alert con la stima (conteggio file + GB stimati) e un bottone Continua/Annulla. A fine job, la stessa schermata mostra lo stato finale: ✅ "Fatto! Le tue foto sono qui" con bottone "Apri cartella" (rivela in Finder) — oppure, se `progress.problems` non è vuoto, una riga discreta ("12 file non è stato possibile recuperare") con un bottone per vederne l'elenco semplice.

### Punti di accesso

- **Hamburger**: nuova riga "Ripristina" (icona `arrow.down.doc`), accanto a Report Log/Configurazione/Tools — apre `RestoreView`.
- **`SetupView`**: sotto i tre `LocationRow`, un bottone secondario "Ho già un backup, voglio ripristinare" — apre `RestoreView` senza richiedere `allConfigured`.

## Fix incluso: race stop()/successo in `BackupRunner`

In `run(label:work:)`, il ramo di successo (dentro `Task.detached`, dopo `try await work()`) non controlla `wasStopped` prima di scrivere `phase = .success(...)` e salvare il `JobSummary`, a differenza del ramo `catch` che invece lo fa. Se l'utente preme Interrompi mentre un job sta per terminare naturalmente (cancellazione cooperativa: il loop interno controlla `cancelled` solo a inizio iterazione, non istantaneamente), il job può restituire un risultato parziale in modo "normale" e il ramo di successo sovrascrive silenziosamente lo stato `.failed("Interrotto dall'utente")` già impostato da `stop()`.

Fix: aggiungere `guard !self.wasStopped else { return }` anche nel ramo di successo, subito dopo la riga che cancella `elapsedTimer`, prima di qualunque scrittura su `stats`/`phase`/`completionSnapshot`/`JobHistoryStore`. Una riga, stesso punto esatto dove il ramo `catch` già lo fa.

## Gestione errori

- Config S3 non valida (Cubbit scelto come fonte ma credenziali mancanti/errate): stesso `NSAlert` con `error.localizedDescription` già usato in `runSyncS3()` — comportamento coerente col resto dell'app, nessuna nuova UX da inventare qui.
- Cartella sorgente selezionata manualmente non valida (es. non è la root del volume, per SSD/HDD): stesso controllo `isLikelyVolumeRoot` + alert già usato in `BackupRunner`.
- Errori su singoli file durante il restore: mai bloccanti, accumulati in `progress.problems`, mostrati solo a fine job in forma discreta (vedi sopra).

## Testing

- **`S3Syncer.topLevelFolders(fromKeys:)`** — funzione pura, nuovo file `RestoreS3FolderParsingTests.swift`: chiavi con più cartelle, chiavi senza `/` (ignorate), chiavi duplicate nella stessa cartella (deduplicate), lista vuota.
- Nessun nuovo test per `FileSyncer` (riusato senza modifiche, già coperto da `FileSyncerZeroOverwriteTests`).
- Nessun test automatico per `downloadMany` (rete reale, stesso limite già accettato per il resto di `S3Syncer`) — verifica manuale.
- Nessun test automatico per il fix della race `wasStopped` (richiede orchestrare un vero `Task` in corsa con un job reale — non isolabile a basso costo); verifica manuale: avviare un job, premere Interrompi, confermare che lo stato resti "Interrotto" e non torni a "Completato".

## Domande aperte per l'implementazione

Nessuna bloccante. Dettaglio di UI lasciato alla fase di implementazione: l'esatta icona SF Symbols per la riga "Ripristina" nell'hamburger (coerente con lo stile delle altre righe, non una decisione architetturale).
