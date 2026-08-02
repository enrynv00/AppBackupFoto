# Retry con backoff sugli upload S3

Data: 2026-08-02
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto critico #3: un errore di rete su un singolo file durante SSD→Cubbit S3 lo marca "errore" e il job prosegue oltre — corretto per non bloccarsi, ma senza un secondo tentativo automatico ogni blip di WiFi diventa un file permanentemente non backuppato finché non rilanci l'intero job. Approfondito nel briefing `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md` (sezione 1) e discusso con l'utente.

Vincolo esplicito derivato dal bug di cancellazione risolto nella notte del 2026-07-29/30 (vedi `Docs/CLAUDE.md`): qualunque meccanismo che introduce nuove attese asincrone (qui: il backoff tra un tentativo e l'altro) deve rispettare correttamente `cancelled`/`Task.isCancelled`, altrimenti si rischia di reintrodurre lo stesso tipo di blocco quasi irreversibile già capitato con `RestoreEngine`.

## Scope

Dentro scope:
- Retry con backoff esponenziale sul singolo PUT (file <64MB).
- Retry sulla singola parte di un upload multipart (file ≥64MB) — non sull'intero file da capo.
- Retry anche sull'init e sul complete del multipart, per coerenza con lo stesso meccanismo (stessa natura di chiamata HTTP singola).
- Fino a 3 tentativi totali (1 iniziale + 2 retry), attese 1s poi 2s tra un tentativo e l'altro.
- Distinzione tra errori da ritentare (rete/timeout, HTTP 5xx) ed errori permanenti da non ritentare (HTTP 4xx, errori di configurazione/logica come URL malformato).
- Messaggio visibile su `onStatus` ad ogni retry, stesso tab Log già esistente.
- Rispetto di `cancelled`/`Task.isCancelled` prima di ogni attesa di backoff.

Fuori scope (esplicitamente, per questa iterazione):
- Nessuna categoria di contatore separata per "fallito dopo retry" — resta nello stesso contatore "Errori" di `JobStats`/`StatsPanel`/`CompletionSheet`, invariati.
- Nessun retry sui download (`downloadToTemp`, usato da restore e dal campione di integrità) — la richiesta riguardava esplicitamente gli upload; i download restano un intervento futuro separato se necessario.
- Nessun retry sulle chiamate di lista (`listPage`/`listAll`) — non toccate da questo intervento.
- Numero di tentativi e tempi di attesa non configurabili dall'utente in UI — valori fissi nel codice (3 tentativi, 1s/2s), coerente con come il resto del progetto gestisce le costanti operative (es. `maxSpeedSamples`, `lastDeepKey`).

## Architettura

Tutto dentro `final class S3Syncer` in `AppBackupFoto/ContentView.swift`.

### `S3HTTPError` (nuovo tipo)

```swift
struct S3HTTPError: Error {
    let statusCode: Int
    let message: String
}
```

Sostituisce gli `NSError(domain: "S3", code: ...)` lanciati oggi da `put`, dal loop delle parti in `multipart`, dall'init e dal complete del multipart, in tutti i punti dove la causa dell'errore è una risposta HTTP non-2xx — cioè esattamente i punti dove serve sapere il codice reale per decidere se ritentare. Gli errori non-HTTP (es. "URL non valido per il file") restano `NSError` come oggi: non sono errori di rete, ritentarli non cambierebbe nulla.

### `isRetryable(_:) -> Bool` (funzione statica pura, testabile)

```swift
static func isRetryable(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let httpError = error as? S3HTTPError { return !(400...499).contains(httpError.statusCode) }
    if error is URLError { return true }
    return false
}
```

- `URLError` (nessuna connessione, timeout, connessione persa) → sempre da ritentare.
- `S3HTTPError` con codice 400-499 (credenziali, richiesta malformata, oggetto non trovato) → mai da ritentare, l'esito sarebbe identico.
- `S3HTTPError` con altro codice (5xx, errori lato server) → da ritentare.
- Qualunque altro errore (es. `NSError` per URL malformato, un bug di configurazione locale) → mai da ritentare.
- `CancellationError` → mai da ritentare, propaga subito.

### `retrying(key:onStatus:operation:)` (helper generico)

```swift
private func retrying<T>(key: String, maxAttempts: Int = 3,
                          onStatus: @escaping (String) -> Void,
                          operation: () async throws -> T) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard !cancelled, !Task.isCancelled else { throw error }
            guard attempt < maxAttempts, S3Syncer.isRetryable(error) else { throw error }
            let delaySec = pow(2.0, Double(attempt - 1))   // 1s, 2s
            attempt += 1
            let msg = "Errore di rete su \(key), riprovo tra \(Int(delaySec))s (tentativo \(attempt)/\(maxAttempts))"
            DispatchQueue.main.async { onStatus(msg) }
            try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
        }
    }
}
```

`Task.sleep` lancia `CancellationError` automaticamente se il Task viene cancellato durante l'attesa — propaga naturalmente verso l'alto senza bisogno di codice aggiuntivo, coerente col fix già applicato a `RestoreEngine`.

### Punti di applicazione

- `upload(url:key:config:)` guadagna un parametro `onStatus: @escaping (String) -> Void`, passato a valle:
  - Per file <64MB: `try await retrying(key: key, onStatus: onStatus) { try await self.put(data: data, key: key, config: config) }`.
  - Per file ≥64MB: passa `onStatus` a `multipart(...)`.
- `multipart(url:key:config:onStatus:)` guadagna lo stesso parametro. Ogni chiamata HTTP singola al suo interno (init, ciascuna parte, complete) viene avvolta in `retrying(key:onStatus:) { ... }`.
- `sync(from:config:onStatus:onProgress:)`, unico chiamante di `upload(...)` all'interno di `S3Syncer`, passa il proprio `onStatus` già esistente — nessuna nuova firma pubblica da imparare per chi chiama `sync` da fuori (`BackupRunner.runSyncS3`).

## Gestione errori

- Un errore permanente (4xx) o l'esaurimento dei 3 tentativi propaga l'eccezione esattamente come oggi: il chiamante (`sync`'s loop) la cattura e incrementa `result.errors`, il job prosegue con il file successivo.
- Un'interruzione (`stop()` → `cancelled = true` / `Task.isCancelled`) durante un'attesa di backoff propaga `CancellationError` immediatamente, senza aspettare il resto del delay — stessa garanzia già data dal fix di stanotte per `RestoreEngine`.

## Testing

- **`S3SyncerRetryTests.swift`** (nuovo): test su `S3Syncer.isRetryable(_:)`, funzione pura senza rete — casi: `URLError(.notConnectedToInternet)` → true, `S3HTTPError(statusCode: 403, ...)` → false, `S3HTTPError(statusCode: 404, ...)` → false, `S3HTTPError(statusCode: 500, ...)` → true, `S3HTTPError(statusCode: 503, ...)` → true, `NSError` generico (es. dominio "S3" per URL malformato) → false, `CancellationError()` → false.
- Nessun test automatico per `retrying(...)` stesso (richiederebbe simulare fallimenti di rete reali o un mock di `URLSession`, fuori scope per questa iterazione) — verificato manualmente: forzare un errore temporaneo (es. staccare la rete per qualche secondo durante un upload) e osservare nel Log i messaggi di retry, poi il ripristino della connessione che fa completare il file.
- Nessun test automatico per il rispetto della cancellazione durante il backoff — stesso limite già accettato per gli altri meccanismi di cancellazione in questo progetto; verifica manuale: avviare un upload, forzare un errore su un file, premere Interrompi mentre è in attesa del retry, confermare che si fermi subito.

## Domande aperte per l'implementazione

Nessuna bloccante. Dettaglio di implementazione lasciato a quella fase: se `multipart`'s complete-step fallisce dopo aver già caricato con successo tutte le parti, il retry lo riprova senza ricaricare le parti (il complete è idempotente lato S3 finché `uploadId` resta valido) — comportamento naturale della struttura already proposta, non richiede una decisione separata.
