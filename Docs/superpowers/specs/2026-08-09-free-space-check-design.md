# Controllo spazio libero prima del backup (Mac→SSD, SSD→HDD)

Data: 2026-08-09

## Problema

Roadmap #8: nessun controllo di spazio libero prima di avviare un backup. Se il volume di destinazione (SSD o HDD) si riempie a metà copia, l'errore arriva a job già a metà — meglio saperlo prima di iniziare.

## Decisioni prese in brainstorming

- **Comportamento se lo spazio non basta**: blocca l'avvio con un `NSAlert` (stesso stile già usato per bookmark non validi, `isLikelyVolumeRoot`), non solo un avviso ignorabile.
- **Ambito**: solo Mac→SSD e SSD→HDD, i due backup su disco fisico locale. SSD→S3 (Cubbit, cloud) resta fuori — nessun limite di spazio pratico rilevante per questo caso d'uso.
- **Copertura del backup automatico**: il controllo si applica anche al trigger automatico Mac→SSD al collegamento SSD (roadmap #7, già shippato) — coerenza totale, accettato il costo di qualche secondo di scansione in più anche lì.
- **Margine di sicurezza**: non basta che lo spazio combaci esattamente — si richiede un margine extra del 5% dei byte stimati, minimo 500MB (il maggiore dei due), per non ridurre mai un volume a zero byte liberi e assorbire piccoli scarti di stima.

## Design tecnico

### 1. `FileSyncer.previewSync` calcola anche i byte

Oggi (`ContentView.swift`, `FileSyncer`) restituisce `(toAdd: Int, toSkip: Int, estimatedSec: Int)` — conta i file ma non le dimensioni. `previewFile`/`previewDir` vanno estesi per sommare anche i byte dei file che verrebbero copiati (stesso pattern già usato da `S3Syncer.previewUpload`, che include `.fileSizeKey` nella resourceValues fetch):

```swift
func previewSync(from src: URL, to dst: URL, deep: Bool) async
    -> (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int)
```

`previewFile` aggiunge la dimensione del file sorgente a `toAddBytes` solo quando decide `toAdd += 1` (file nuovo, non skippato) — coerente con la regola zero-overwrite: i byte contati sono solo quelli che verranno davvero scritti.

Questo cambia la firma pubblica di `previewSync` — aggiornare i due call site esistenti (`previewMacToSSD()`, `previewSSDToHDD()`) che già mostrano `result.toAdd`/`result.toSkip`/`result.estimatedSec` in un `NSAlert`: nessuna modifica di comportamento per loro, solo il nuovo campo `toAddBytes` disponibile (non ancora mostrato in quell'alert, a meno che valga la pena aggiungerlo lì per coerenza — vedi nota finale).

### 2. Nuovo helper per lo spazio disponibile

In `BackupRunner`:

```swift
private func hasSufficientSpace(bytesNeeded: Int64, atVolumeOf url: URL) -> (ok: Bool, availableBytes: Int64) {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    let available = Int64(values?.volumeAvailableCapacity ?? 0)
    let margin = max(Int64(Double(bytesNeeded) * 0.05), 500_000_000)
    return (available >= bytesNeeded + margin, available)
}
```

### 3. `runMacToSSD()` e `runSSDToHDD()` controllano prima di avviare

Entrambi hanno oggi una catena di `guard` sincroni (accesso bookmark, `isLikelyVolumeRoot`) prima di chiamare `run(label:) { ... }`. Il controllo spazio richiede una scansione asincrona (`previewSync`), quindi il punto di innesto è lo stesso già usato da `previewMacToSSD()`: un `Task { @MainActor [weak self] in ... }` subito dopo i guard sincroni esistenti, che:

1. chiama `await self.syncer.previewSync(from:to:deep:)` per ottenere `toAddBytes`
2. verifica lo spazio con `hasSufficientSpace`
3. se insufficiente: mostra l'alert con i numeri esatti, chiude gli accessi bookmark aperti (`bm.stopAccessing`), e si ferma — il job non entra mai in `phase: .running`
4. se sufficiente: procede a chiamare `self.run(label:) { ... }` esattamente come il codice fa oggi

Esempio per `runMacToSSD()` (stessa struttura per `runSSDToHDD()`, con `deep` calcolato come già fa oggi):

```swift
func runMacToSSD() {
    speedUnit = "file/s"
    guard let photosURL = bm.startAccessing(.photos) else { ... }   // invariato
    guard let ssdURL = bm.startAccessing(.ssd) else { ... }          // invariato
    if !isLikelyVolumeRoot(ssdURL) { ... }                           // invariato
    let dst = ssdURL.appendingPathComponent("Foto iPhone")

    Task { @MainActor [weak self] in
        guard let self else { return }
        let preview = await self.syncer.previewSync(from: photosURL, to: dst, deep: false)
        let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: ssdURL)
        guard space.ok else {
            self.bm.stopAccessing(.photos); self.bm.stopAccessing(.ssd)
            let a = NSAlert()
            a.messageText = "Spazio insufficiente sull'SSD"
            a.informativeText = "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path)."
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        self.run(label: "MAC -> SSD") { [weak self] in
            // stesso corpo di oggi, invariato
        }
    }
}
```

Il backup automatico su collegamento SSD (`.onChange(of: volumes.ssdMounted)` in `ContentView`) chiama già `runMacToSSD()` — nessuna modifica lì, eredita il controllo automaticamente.

### 4. Formattazione leggibile

`ByteCountFormatter` (già parte di Foundation, nessuna dipendenza nuova) per mostrare GB/MB in linguaggio comune invece di byte grezzi.

## Testing

Nuovi test XCTest su `FileSyncer.previewSync`: verificare che `toAddBytes` sommi correttamente le dimensioni di file di test con contenuto di dimensione nota, e che i file skippati (già esistenti a destinazione) non contribuiscano ai byte. Nessun test automatico su `hasSufficientSpace`/`volumeAvailableCapacity` (dipende dallo spazio reale del disco di test, non deterministico) — verifica manuale: creare temporaneamente una condizione di spazio scarso (es. puntare la destinazione a un volume quasi pieno, se disponibile) o rivedere a occhio i numeri mostrati nell'alert su un caso reale.

## Fuori scope

- SSD→S3 (Cubbit) non tocca questo controllo.
- Nessuna modifica al comportamento in caso di spazio sufficiente (nessun nuovo alert, nessun ritardo percepibile oltre alla scansione già prevista).
- L'alert di anteprima manuale esistente (`previewMacToSSD`/`previewSSDToHDD`) non viene esteso per mostrare i byte — resta invariato, a meno di richiesta esplicita in revisione.
