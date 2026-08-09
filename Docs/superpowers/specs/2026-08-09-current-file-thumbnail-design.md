# Roadmap #17: Miniatura live dell'ultimo file

Data: 2026-08-09

## Problema

`Docs/ROADMAP.md` punto #17: "Nessuna miniatura dell'ultimo file backuppato — tocco di fiducia visiva usato da Mylio/PhotoSync." Puro polish visivo, non funzionale — confermato con l'utente che vale comunque la pena farlo.

## Decisioni prese in brainstorming

- **Quando**: live, file per file, durante un job in corso (non nel `CompletionSheet` a fine job — fuori scope).
- **File non-immagine** (es. gli zip da 40-50GB nella cartella "Zip"): icona generica del file, non saltare la miniatura.
- **Scope**: solo i tre job di backup (Mac→SSD, SSD→HDD, SSD→S3). Il restore (`RestoreEngine`) resta fuori — ha già una UI volutamente più semplice (`RestoreProgress`, non `JobStats`), non toccata da questo lavoro.

## Contesto tecnico verificato

Oggi non esiste un URL riutilizzabile del file corrente: `onStatus` (già threaded attraverso `FileSyncer.sync` → `syncDir` → `syncFile`, e attraverso `S3Syncer.sync` → `upload`) riceve solo una `String` con il nome file già interpolato (`ContentView.swift:621` per la copia, `:965` per l'upload S3). Serve una nuova via per propagare l'URL vero e proprio.

`RestoreEngine` chiama anch'esso `FileSyncer.sync(...)` (`ContentView.swift:2361`, con `onStatus: { _ in }` già oggi) — qualunque nuovo parametro aggiunto alla firma di `sync`/`syncDir`/`syncFile` deve essere passato anche lì, come no-op (`{ _ in }`), per non rompere la compilazione. `S3Syncer.downloadMany` (usato dal restore per Cubbit) è una funzione diversa da `S3Syncer.sync` (usato per l'upload) — non serve toccarla.

## Design tecnico

### 1. Nuovo parametro `onCurrentFile` threaded attraverso `FileSyncer` e `S3Syncer`

Stesso pattern già usato per `onStatus`/`onProgress` (callback distinti per responsabilità distinte, non un parametro sovraccaricato):

- `FileSyncer.sync(from:to:deep:onStatus:onProgress:)` (`ContentView.swift:515`) → aggiungere `onCurrentFile: @escaping (URL) -> Void`.
- `FileSyncer.syncDir(...)` (`ContentView.swift:565`) → stesso parametro, passato a `syncFile`.
- `FileSyncer.syncFile(...)` (`ContentView.swift:593`) → stesso parametro, chiamato subito prima della copia effettiva (accanto alla chiamata `onStatus` esistente alla riga 621, con lo stesso `src`).
- `S3Syncer.sync(from:config:onStatus:onProgress:)` (`ContentView.swift:914`) → stesso parametro, chiamato subito prima dell'upload di ogni file (accanto a `onStatus` esistente riga 965, con `item.url`).

Call site da aggiornare con il callback vero (`BackupRunner`):
- `runMacToSSD()` (`ContentView.swift:1573-1575`)
- `runSSDToHDD()` (`ContentView.swift:1625-1627`)
- `runSyncS3()` (chiamata a `s3syncer.sync`, vicino a riga 1649-1655)

Call site da aggiornare con no-op (`RestoreEngine`, fuori scope):
- `ContentView.swift:2361-2366` (`syncer.sync(...)`, dentro `RestoreEngine`) → `onCurrentFile: { _ in }`.

### 2. Decisione "è un'immagine?" — funzione pura testabile

```swift
enum FileKind {
    static func isImage(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
```

Nessuna dipendenza da rete/disco — testabile con XCTest passando solo URL con estensioni diverse (jpg/heic/png → true; zip/pdf/txt → false; nessuna estensione → false).

### 3. `BackupRunner` genera la miniatura in modo asincrono, senza rallentare la copia

Nuove proprietà pubblicate:

```swift
@Published var currentThumbnail: NSImage?
private var thumbnailRequestID = UUID()
```

Nuovo metodo, chiamato dal callback `onCurrentFile`:

```swift
func publishCurrentFile(_ url: URL) {
    let requestID = UUID()
    thumbnailRequestID = requestID
    if FileKind.isImage(url: url) {
        Task.detached(priority: .utility) { [weak self] in
            let thumb = Self.makeThumbnail(url: url, maxPixelSize: 88)
            await MainActor.run {
                guard let self, self.thumbnailRequestID == requestID else { return }  // scarta risultati arrivati in ritardo
                self.currentThumbnail = thumb
            }
        }
    } else {
        currentThumbnail = NSWorkspace.shared.icon(forFile: url.path)  // sincrono, già leggero (icona di sistema)
    }
}

private static func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true  // rispetta l'orientamento EXIF
    ]
    guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cgThumb, size: .zero)
}
```

`CGImageSourceCreateThumbnailAtIndex` (ImageIO, già disponibile — nessun nuovo import) non carica mai l'immagine intera in memoria, a differenza di `NSImage(contentsOf:)` — coerente con la lezione già imparata su questo progetto sul bug di memoria di `sha256(of:)` (vedi `Docs/CLAUDE.md`): non fidarsi del "sembra piccolo" quando si legge un file, usare sempre l'API pensata per l'uso specifico. Il guard su `thumbnailRequestID` evita che una miniatura lenta (file grande, generazione tardiva) sovrascriva quella di un file più recente già mostrato.

### 4. UI: nuova view `CurrentFileThumbnail`, in `StatsPanel` accanto a `StatusBar`

```swift
struct CurrentFileThumbnail: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2), lineWidth: 1))
    }
}
```

Inserita in `StatsPanel` (`ContentView.swift:3243-3272`) accanto a `StatusBar`, in una `HStack`, passando `runner.currentThumbnail`.

### 5. Ciclo di vita

Stesso comportamento già esistente per `currentStatus`: azzerato (`currentThumbnail = nil`) all'inizio di `run(label:work:)` (dove oggi già si azzera `currentStatus = ""`, `ContentView.swift:1816`), nessuna pulizia esplicita a fine job — resta visibile con l'ultimo file mostrato, stesso comportamento di `currentStatus` oggi. Nessuna nuova decisione UX da gestire.

## Fuori scope

- Nessuna miniatura nel `CompletionSheet`.
- Nessuna cache di thumbnail tra sessioni o tra file già visti.
- `RestoreEngine` non guadagna una miniatura (riceve solo il no-op `onCurrentFile: { _ in }` per compatibilità di firma).
- Nessuna miniatura per `S3Syncer.downloadMany` (usato solo dal restore).

## Testing

- `FileKind.isImage(url:)` — funzione pura, XCTest diretto: estensioni immagine note (jpg, jpeg, heic, heif, png, gif, tiff, bmp, webp) → `true`; estensioni non-immagine (zip, pdf, txt, csv) → `false`; nessuna estensione → `false`.
- Generazione thumbnail reale, resa UI, comportamento con file di grandi dimensioni: verifica manuale (non automatizzabile in ambiente headless) — avviare un job reale con foto reali e con almeno un file dalla cartella "Zip", controllare che la miniatura cambi file per file, mostri l'icona generica per lo zip, e non rallenti visibilmente la copia.
