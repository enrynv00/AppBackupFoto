# Segnalazione file cambiati-non-copiati (roadmap #13)

Data: 2026-08-09

## Problema

Roadmap #13: nessuno storico se un file alla sorgente cambia dopo essere già stato backuppato — zero-overwrite lo skippa silenziosamente, senza che l'utente lo sappia.

## Decisione presa in brainstorming: go/no-go come per #5

Scartato il "versioning vero" (salvare la nuova versione accanto alla vecchia): aggiunge complessità reale (spazio che cresce nel tempo, nuova UI) per un beneficio che non vale il rischio di toccare la regola più delicata del progetto. Scelto invece: **solo segnalare**, nessuna nuova scrittura, nessuna azione automatica.

Durante il brainstorming, trovato e già risolto separatamente **BUG-3**: `S3Syncer.sync()` non solo non segnalava i file cambiati, ma li *sovrascriveva* silenziosamente su Cubbit. Vedi `Docs/superpowers/specs/2026-08-09-s3-zero-overwrite-fix-design.md` — fix già committato, prerequisito di questo spec (dopo il fix, tutti e tre i job skippano sempre un file esistente, mai lo sovrascrivono, coerentemente).

## Decisioni di design

- **Dove**: nel `CompletionSheet` (popup di fine job), riga condizionale solo se `changedSkipped > 0` — stesso stile delle righe già esistenti per hash-mismatch/errori.
- **Dettaglio**: solo un conteggio ("N file cambiati, non copiati"), nessun elenco di nomi né riga aggiuntiva nel tab Log.
- **Costo**: zero scansioni aggiuntive — il confronto "il file esiste ma è diverso" è già calcolato oggi da `FileSyncer.syncFile` (variabile `needs`) e, dopo il fix di BUG-3, anche da `S3Syncer.sync()` (confronto dimensione per le key già esistenti, ora solo informativo). Serve solo distinguerlo dal generico "skippato" invece di scartarlo.

## Design tecnico

### 1. Nuovo campo `changedSkipped` lungo tutta la catena esistente

- `FileSyncer.SyncResult` (`ContentView.swift:435`): aggiungere `var changedSkipped = 0`.
- `S3Syncer.SyncResult` (`ContentView.swift:718`): aggiungere `var changedSkipped: Int = 0`.
- `JobStats` (`ContentView.swift:258`): aggiungere `var changedSkipped: Int = 0`.
- `JobSummary` (`ContentView.swift:1912`, `Codable`): aggiungere `let changedSkipped: Int` (persistito, visibile in Tools → ultimo job, stesso trattamento degli altri contatori).

### 2. `FileSyncer.syncFile` incrementa `changedSkipped`

`ContentView.swift:585`, nel branch già esistente:

```swift
if needs {
    if fm.fileExists(atPath: dst.path) {
        // destination exists but differs — zero-overwrite rule: skip
        result.skipped += 1
        result.changedSkipped += 1   // NUOVO
    } else {
        ...
```

### 3. `S3Syncer.sync()` calcola `changedSkipped` come conteggio informativo

Nuova funzione pura e testabile (nessuna rete), stesso stile di `shouldUpload`:

```swift
static func isChangedExistingKey(key: String, size: Int64, existing: [String: Int64]) -> Bool {
    guard let existingSize = existing[key] else { return false }  // key assente: è nuova, non "cambiata"
    return existingSize != size
}
```

`ContentView.swift:896`, dove oggi (dopo il fix di BUG-3) si calcola `toUpload` via `S3Syncer.shouldUpload`:

```swift
let existingKeys = Set(existing.keys)
let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
let changedCount = files.filter { S3Syncer.isChangedExistingKey(key: $0.key, size: $0.size, existing: existing) }.count
result.total = files.count
result.toUploadCount = toUpload.count
result.skipped = files.count - toUpload.count
result.changedSkipped = changedCount
```

Questo conteggio è puramente informativo — non influenza in alcun modo `toUpload`/la decisione di caricare, già corretta dal fix di BUG-3.

### 4. Propagazione a `JobStats`/`JobSummary`

- `BackupRunner.publishProgress(_:FileSyncer.SyncResult)` (`ContentView.swift:1855`): aggiungere `self.stats.changedSkipped = r.changedSkipped`.
- `runSyncS3()`, closure `onProgress` (`ContentView.swift:1615`, righe indicative 1635-1652): aggiungere `self.stats.changedSkipped = snap.changedSkipped`.
- `runSyncS3()`, conversione finale `S3Syncer.SyncResult` → `FileSyncer.SyncResult` (righe indicative 1653-1656): aggiungere `fr.changedSkipped = r.changedSkipped`.
- `run(label:)`, completamento con successo (righe indicative 1816-1823): aggiungere `self.stats.changedSkipped = r.changedSkipped`.
- I tre punti che chiamano `JobHistoryStore.save(JobSummary(...))` (righe 1786, 1828, 1840): aggiungere `changedSkipped: self.stats.changedSkipped` (o `stats.changedSkipped` per `stop()`).

### 5. `CompletionSheet` mostra il conteggio

`ContentView.swift:2831`, stesso stile delle righe condizionali già esistenti per `hashErrors`/`errors`:

```swift
if stats.changedSkipped > 0 {
    Label("\(stats.changedSkipped) file locali cambiati, non copiati (regola zero-overwrite)",
          systemImage: "arrow.triangle.2.circlepath")
        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
}
```

## Testing

Nuovi test XCTest su `FileSyncer.sync()`, stesso pattern di `FileSyncerZeroOverwriteTests.swift` (directory temporanee reali, nessun mock): un file esistente a destinazione con contenuto/dimensione diversa dalla sorgente produce `result.changedSkipped == 1` oltre a `result.skipped == 1`; un file esistente identico produce `result.changedSkipped == 0`.

Nuovo test XCTest puro (nessuna rete) su `S3Syncer.isChangedExistingKey`: key assente da `existing` → `false` (è nuova, non cambiata); key presente con dimensione diversa → `true`; key presente con dimensione identica → `false`.

## Fuori scope

- Nessun salvataggio automatico di nuove versioni (scartato in brainstorming).
- Nessun elenco di nomi file, né nel riepilogo né nel tab Log.
- Nessuna nuova voce nel pannello Revisione (Tools) — solo il riepilogo di fine job, come deciso.
- Nessuna modifica a `StatsPanel` (i 5 `StatCard` live durante il job restano invariati) — solo `CompletionSheet`.
