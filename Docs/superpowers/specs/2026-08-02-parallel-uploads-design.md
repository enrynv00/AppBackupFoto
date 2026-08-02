# Upload S3 paralleli + fix memoria multipart

Data: 2026-08-02
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto alto #6: gli upload verso Cubbit S3 in `S3Syncer.sync(from:config:onStatus:onProgress:)` sono completamente sequenziali — un file alla volta. Su una libreria di ~69.000 file (in gran parte foto/video piccoli, più una manciata di archivi `.zip` da 40-53GB nella cartella "Zip"), è probabilmente il collo di bottiglia più grande sulla velocità reale. Approfondito nel briefing `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md` (sezione 4) e discusso con l'utente.

**Vincolo di banda**: la connessione dell'utente ha banda effettiva limitata (~2,9 Mbps misurati in sessione precedente durante un download reale da Cubbit). Il parallelismo aiuta dove il collo di bottiglia è la latenza per richiesta (tanti file piccoli), molto meno dove il collo di bottiglia è la banda stessa (i pochi zip enormi). Per questo lo scope è stato ristretto al parallelismo tra file diversi — le parti di un singolo upload multipart restano sequenziali.

**Scoperta collegata durante il brainstorming**: `multipart()` (per i file ≥64MB) legge le parti con `FileHandle(forReadingFrom:)` + `fileHandle.readData(ofLength: chunkSize)` in un ciclo — lo stesso pattern che ha causato il bug critico di memoria (41-43GB di RAM) già trovato e corretto in `sha256(of:)` in questa sessione (vedi `Docs/CLAUDE.md`). Non è ancora stato verificato empiricamente su un upload multipart reale, ma è la stessa firma di codice: letture "a blocchi" su file molto grandi dove `FileHandle` mantiene le pagine residenti in memoria invece di rilasciarle. Parallelizzare gli upload senza prima sistemare questo avrebbe amplificato il problema (più file handle che "perdono" memoria contemporaneamente). L'utente ha scelto di includere il fix in questo stesso intervento, prima di parallelizzare.

## Decisioni (dall'utente, in fase di brainstorming)

1. **Fix memoria multipart prima del parallelismo** — stesso approccio POSIX low-level già in produzione per `sha256(of:)`.
2. **Parallelismo solo tra file diversi**, non tra le parti di un singolo upload multipart (il collo di bottiglia sui file enormi è la banda, non la latenza — parallelizzare le parti lì non aiuterebbe granché e aggiungerebbe complessità).
3. **4 upload concorrenti, valore fisso nel codice**, non configurabile dall'utente — coerente con la filosofia "non un'app per nerd" già applicata al resto del progetto.

## Scope

Dentro scope:
- Funzione pura `S3Syncer.readFileInChunks(path:chunkSize:onChunk:)` che sostituisce la lettura `FileHandle` in `multipart()`.
- Funzione generica `S3Syncer.runBounded(items:maxConcurrent:isCancelled:operation:onOutcome:)` per la concorrenza limitata a finestra fissa.
- Riscrittura di `sync(from:config:onStatus:onProgress:)` per usare `runBounded` con 4 upload concorrenti sui file effettivamente da caricare (quelli già presenti restano contati come `skipped` senza passare dal parallelismo, nessuna chiamata di rete necessaria).
- Controllo di cancellazione (`cancelled` / `Task.isCancelled`) dentro ogni singolo task figlio, prima della chiamata di rete — non solo nel loop esterno.
- Due nuovi file di test, nessuna rete reale coinvolta.

Fuori scope (esplicitamente, per questa iterazione):
- Parallelismo tra le parti di un singolo upload multipart — deciso esplicitamente fuori scope (vedi Decisioni).
- Numero di upload concorrenti configurabile dall'utente — deciso esplicitamente fuori scope.
- Modifiche a `RestoreEngine`/`downloadMany` (percorso di restore, non di backup) — non toccato da questo intervento.
- Retry/backoff: già esistente (`S3Syncer.retrying`), riusato senza modifiche.

## Architettura

Tutto in `AppBackupFoto/ContentView.swift`, dentro `S3Syncer`.

### 1. `readFileInChunks` — sostituisce la lettura in `multipart()`

```swift
static func readFileInChunks(path: String, chunkSize: Int,
                              onChunk: (Data) async throws -> Void) async throws {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else {
        throw NSError(domain: "S3", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Impossibile aprire il file: \(path)"])
    }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
        if n < 0 {
            throw NSError(domain: "S3", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Errore di lettura: \(path)"])
        }
        if n == 0 { break }
        try await onChunk(Data(bytes: buffer, count: n))
    }
}
```

Stesso principio già in produzione per `sha256(of:)`: `open`/`read`/`close` POSIX con un buffer riutilizzato, invece di `FileHandle.readData(ofLength:)`. `onChunk` è `async throws` per poter fare la chiamata di rete della singola parte direttamente dentro il ciclo, senza dover accumulare tutte le parti in memoria.

`multipart()` cambia da:
```swift
let fileHandle = try FileHandle(forReadingFrom: url)
defer { fileHandle.closeFile() }
...
while offset < fileSize {
    if cancelled { break }
    fileHandle.seek(toFileOffset: UInt64(offset))
    let chunk = fileHandle.readData(ofLength: chunkSize)
    guard !chunk.isEmpty else { break }
    ...upload della parte con retry...
    offset += Int64(chunkSize); pn += 1
}
```
a:
```swift
var pn = 1
try await S3Syncer.readFileInChunks(path: url.path, chunkSize: chunkSize) { chunk in
    guard !self.cancelled else { return }
    let partNumber = pn
    let etag = try await self.retrying(key: "\(key) (parte \(partNumber))", onStatus: onStatus) { () async throws -> String in
        ...stessa richiesta PUT già esistente, usando `chunk` invece di `chunk` letto da FileHandle...
    }
    parts.append((partNumber, etag))
    pn += 1
}
```
Il resto di `multipart()` (init, completamento, abort su cancellazione) resta invariato.

### 2. `runBounded` — concorrenza limitata generica

```swift
static func runBounded<Item, Outcome>(
    items: [Item], maxConcurrent: Int,
    isCancelled: @escaping () -> Bool,
    operation: @escaping (Item) async -> Outcome,
    onOutcome: (Outcome) -> Void
) async {
    await withTaskGroup(of: Outcome.self) { group in
        var index = 0
        func addNext() {
            guard index < items.count, !isCancelled() else { return }
            let item = items[index]; index += 1
            group.addTask { await operation(item) }
        }
        for _ in 0..<maxConcurrent { addNext() }
        while let outcome = await group.next() {
            onOutcome(outcome)
            addNext()
        }
    }
}
```

`operation` non lancia mai (ritorna un `Outcome` che incapsula successo/errore) — questo evita che un fallimento su un file cancelli gli altri task del gruppo (`withTaskGroup`, non `withThrowingTaskGroup`), mantenendo lo stesso comportamento attuale di "un file fallito non blocca gli altri". **Solo il loop `while let outcome = await group.next()` — a thread singolo — tocca lo stato mutabile (`result`, contatori)**: i task figli restituiscono un valore, non mutano nulla di condiviso, quindi non serve nessun lock/actor.

### 3. `sync()` riscritto per usare `runBounded`

```swift
func sync(from localURL: URL, config: S3Config,
          onStatus: @escaping (String) -> Void,
          onProgress: @escaping (SyncResult) -> Void) async throws -> SyncResult {
    cancelled = false
    var result = SyncResult()

    // ... invariato: listAll(), enumerazione file locali in `files` ...

    let toUpload = files.filter { existing[$0.key] != $0.size }
    result.total = files.count
    result.toUploadCount = toUpload.count
    result.skipped = files.count - toUpload.count
    result.done = result.skipped
    let initSnap = result
    DispatchQueue.main.async {
        onStatus("Trovati \(files.count) file locali · \(toUpload.count) da caricare · \(result.skipped) già presenti")
        onProgress(initSnap)
    }

    await S3Syncer.runBounded(
        items: toUpload, maxConcurrent: 4,
        isCancelled: { self.cancelled },
        operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
            if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
            DispatchQueue.main.async { onStatus("Carico: \(item.url.lastPathComponent)") }
            do {
                try await self.upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
                return (item.url, item.size, true)
            } catch {
                return (item.url, item.size, false)
            }
        },
        onOutcome: { outcome in
            if outcome.ok { result.uploaded += 1; result.uploadedBytes += outcome.size }
            else { result.errors += 1 }
            result.done += 1
            let snap = result
            DispatchQueue.main.async { onProgress(snap) }
        }
    )
    return result
}
```

Note di correttezza:
- Il check `self.cancelled || Task.isCancelled` è **dentro** la closure `operation`, eseguita nel task figlio, prima di qualunque chiamata di rete — non solo nel loop esterno di schedulazione. Stessa lezione già applicata a `RestoreEngine` dopo il bug del bottone Interrompi che non fermava nulla.
- L'ordine di completamento tra i 4 upload concorrenti non è garantito: il messaggio di stato "Carico: nomefile" può comparire "fuori ordine" rispetto alla lista dei file. `result.done`/`result.percent` restano corretti perché sono contatori, non dipendono dall'ordine.
- I file già presenti su S3 (`skipped`) sono contati subito, prima del loop parallelo — non generano task né chiamate di rete, esattamente come nel comportamento attuale.

## Gestione errori

Invariata rispetto a oggi: un errore su un singolo file (rete, 4xx dopo i retry, ecc.) incrementa `result.errors` e non interrompe gli altri upload — né quelli già in volo nella finestra di concorrenza, né quelli ancora da schedulare. Il retry con backoff (`S3Syncer.retrying`) resta invariato e continua a funzionare per-parte e per-file esattamente come oggi, ora chiamato da dentro `operation` invece che dal loop sequenziale.

## Testing

- **`readFileInChunks`**: nuovo test (no rete) — scrive un file temporaneo di contenuto noto (dimensione non multipla del chunk size, per coprire l'ultimo chunk parziale), chiama `readFileInChunks` con un chunk size piccolo, concatena i chunk ricevuti e verifica che ricostruiscano esattamente il contenuto originale.
- **`runBounded`**: nuovo test (no rete) — 20 item finti, `operation` che fa un piccolo `Task.sleep` e incrementa/decrementa un contatore di concorrenza corrente protetto da un `actor` dedicato al test, verificando che il picco di concorrenza osservato non superi mai `maxConcurrent` e che tutti i 20 item vengano effettivamente processati (nessuno perso).
- **Upload multipart/parallelo reale verso Cubbit**: verifica manuale, stesso limite già accettato per il resto di `S3Syncer` (dipendenza da rete reale). Suggerita dall'utente: un upload SSD→S3 reale su una cartella con più file piccoli (osservare nei log/stato che più file avanzano "insieme") e, separatamente, un upload di uno degli zip da 40-50GB con il Monitor Attività aperto per confermare che la memoria resti bassa (~60-100MB, non più 40+GB).

## Domande aperte per l'implementazione

Nessuna bloccante. Un dettaglio di plumbing: `sync()` cattura `result` per riferimento nella closure `onOutcome` (var locale mutata da una closure non-escaping passata a `runBounded` — legale in Swift dato che `runBounded` è `async` e la closure non sopravvive alla chiamata, ma va verificato in fase di build che il compilatore non richieda annotazioni aggiuntive per la cattura).
