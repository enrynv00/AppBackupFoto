# Pulizia upload multipart S3 orfani

Data: 2026-08-02
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto critico #4: `AbortMultipartUpload` viene chiamato oggi solo se l'utente preme Interrompi esplicitamente mentre un job sta girando (dentro `S3Syncer.multipart(...)`). Se l'app va in crash, il Mac si spegne, o il processo viene ucciso a metà di un upload multipart, le parti già caricate restano sul bucket Cubbit per sempre — nessun meccanismo di pulizia esiste oggi. Non è uno scenario ipotetico: l'utente ha file da 40-50GB nella cartella "Zip" del suo SSD, upload multipart con molte parti su connessioni lente (verificato: ~2,9 Mbps effettivi in sessione precedente) durano ore, aumentando la probabilità reale di un'interruzione non pulita. Approfondito nel briefing `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md` (sezione 2) e discusso con l'utente.

## Scope

Dentro scope:
- Soluzione lato app (non una lifecycle rule Cubbit — non verificato se il provider la supporta, e l'utente preferisce restare sotto controllo diretto).
- Scoperta automatica degli upload multipart incompleti quando si apre il pannello Revisione (Tools), stesso trigger già usato per i controlli di configurazione esistenti.
- Pulizia (`AbortMultipartUpload`) **solo** con conferma esplicita per singolo upload — mai automatica.
- Il controllo è disattivato mentre un job è in corso (`BackupRunner.isRunning`), per non rischiare di scoprire/offrire la cancellazione di un upload multipart che è semplicemente ancora in corso nello stesso momento, non orfano.
- Estrazione della logica di abort già esistente (oggi inline dentro `multipart(...)`, usata solo sul cancel durante lo stesso job) in una funzione riusabile, condivisa tra il percorso esistente e quello nuovo.

Fuori scope (esplicitamente, per questa iterazione):
- Nessuna configurazione di lifecycle rule lato Cubbit — richiederebbe verificare se il provider la supporta e implementare `PutBucketLifecycleConfiguration`, non fatto ora.
- Nessuna paginazione della lista upload incompleti (fino a 1000 risultati in una singola chiamata) — per un account personale, realisticamente non ce ne saranno mai così tanti da richiederla.
- Nessuna cancellazione automatica dopo N giorni — resta sempre una scelta esplicita dell'utente, coerente con la cautela già applicata ad ogni altra operazione distruttiva nel progetto.
- Nessun test automatico (rete reale) — verificato manualmente.

## Architettura

Tutto in `AppBackupFoto/ContentView.swift`.

### `S3Syncer` — due aggiunte

```swift
struct OrphanedMultipartUpload: Identifiable {
    let id = UUID()
    let key: String
    let uploadId: String
    let initiated: Date
}

func listMultipartUploads(config: S3Config) async throws -> [OrphanedMultipartUpload]

func abortMultipartUpload(key: String, uploadId: String, config: S3Config) async throws
```

`listMultipartUploads` chiama `GET {endpoint}/{bucket}?uploads` (firmato SigV4 come le altre chiamate), parsa la risposta XML estraendo `<Key>`, `<UploadId>`, `<Initiated>` per ciascun blocco `<Upload>` (stesso pattern di `xmlAll`/zip già usato in `listPage` per Key+Size), converte `<Initiated>` (formato ISO8601, es. `2026-07-20T12:34:56.000Z`) in `Date` con un `DateFormatter` dedicato.

`abortMultipartUpload` è la stessa richiesta `DELETE {endpoint}/{bucket}/{key}?uploadId={uploadId}` già presente inline nel ramo `if cancelled { ... }` di `multipart(...)` — estratta qui come funzione a sé, poi **richiamata da entrambi i punti**: il cancel esistente durante un job, e la nuova pulizia manuale.

### `ReviewEngine` — una aggiunta

```swift
func findOrphanedMultipartUploads() async throws -> [OrphanedMultipartUpload] {
    let config = try S3Syncer.readConfig()
    return try await s3Syncer.listMultipartUploads(config: config)
}
```

Riusa la `s3Syncer` già presente come proprietà di `ReviewEngine`. Nessun bisogno di una nuova funzione per l'abort: la UI chiama direttamente `S3Syncer().abortMultipartUpload(...)` con la config già letta, stesso livello di indirection già usato altrove in `ToolsSheet` per `S3Syncer.readConfig()`.

### UI — `ToolsSheet`, nuova sotto-sezione in "Revisione"

- Se `runner.isRunning` (serve passare/leggere lo stato del job attivo, oggi `ToolsSheet` non ne ha visibilità diretta — va aggiunto un modo per saperlo, vedi "Domande aperte" sotto): mostra solo "Controllo disponibile a job fermo", nessuna chiamata di rete.
- Altrimenti, nello stesso `.onAppear` che già esegue `reviewFindings = reviewEngine.runConfigChecks()`, aggiunge una chiamata a `findOrphanedMultipartUploads()`, popolando una lista `@State private var orphanedUploads: [S3Syncer.OrphanedMultipartUpload] = []`.
- Ogni upload trovato mostra: nome file (ultimo componente della `key`), "iniziato N giorni fa" (calcolato da `initiated`), bottone "Elimina" che apre un `NSAlert` di conferma (stesso stile di `confirmReveal` già esistente in `ToolsSheet` per le credenziali) e poi chiama `abortMultipartUpload(...)`, rimuovendo l'elemento dalla lista locale al successo.
- Se non ne trova nessuno: nessuna riga mostrata (coerente con "niente di anomalo" delle altre sezioni di Revisione, che non urlano quando tutto va bene).

## Gestione errori

- Se `findOrphanedMultipartUploads()` fallisce (es. credenziali non valide, rete assente): stesso trattamento silenzioso/non bloccante già usato per gli altri controlli di Revisione — nessun alert invasivo, la sotto-sezione resta semplicemente vuota (l'utente vede comunque gli altri controlli di configurazione, che spiegano già se le credenziali sono il problema).
- Se `abortMultipartUpload(...)` fallisce: `NSAlert` con l'errore, l'elemento resta nella lista (non si assume che sia stato cancellato se la chiamata non conferma successo).

## Testing

Nessun test automatico (rete reale verso Cubbit, stesso limite già accettato per il resto di `S3Syncer`). Verifica manuale suggerita dall'utente stesso in fase di brainstorming: generare un upload orfano vero (avviare SSD→S3 su un file grande, forzare l'uscita dell'app a metà) e confermare che compaia nel pannello Revisione e che "Elimina" lo rimuova davvero dal bucket (verificabile anche con `rclone` da terminale, come già fatto in sessioni precedenti). Da programmare quando l'utente ha tempo per un test così invasivo — non bloccante per l'implementazione.

## Domande aperte per l'implementazione

Una, non bloccante ma da risolvere in fase di codice: `ToolsSheet` oggi non ha visibilità sullo stato `isRunning` di `BackupRunner` (sono viste separate, `ToolsSheet` è aperta dall'hamburger, `BackupRunner` vive dentro `ContentView`). Il modo più semplice è passare un `Bool` (o direttamente un riferimento a `runner.isRunning`) come parametro quando si istanzia `ToolsSheet` dal chiamante che già ha accesso a `runner` — dettaglio di plumbing, non una decisione di design.
