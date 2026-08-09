# Roadmap #17: Miniatura live dell'ultimo file Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mostrare una miniatura live (foto vera per le immagini, icona generica per il resto) dell'ultimo file in copia/upload durante un job di backup (Mac→SSD, SSD→HDD, SSD→S3), come tocco di fiducia visiva.

**Architecture:** Un nuovo parametro `onCurrentFile: (URL) -> Void` viene threaded attraverso `FileSyncer.sync/syncDir/syncFile` e `S3Syncer.sync`, con default no-op (`{ _ in }`) sulle firme pubbliche così i chiamanti esistenti non toccati da questo piano (`RestoreEngine`) continuano a compilare senza modifiche. `BackupRunner` riceve l'URL, decide se è un'immagine (`FileKind.isImage`, funzione pura), genera una miniatura leggera via ImageIO in background (mai l'immagine intera in memoria) o usa l'icona di sistema per i file non-immagine, pubblicando il risultato in `@Published var currentThumbnail: NSImage?`. Una nuova view `CurrentFileThumbnail` la mostra in `StatsPanel`.

**Tech Stack:** ImageIO (`CGImageSourceCreateThumbnailAtIndex`, nuovo import), AppKit (`NSWorkspace.shared.icon(forFile:)`, già disponibile), UniformTypeIdentifiers (già importato), XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Solo i tre job di backup guadagnano la miniatura reale — `RestoreEngine` resta non toccato (beneficia del default `{ _ in }` sulla firma pubblica di `FileSyncer.sync`, nessuna modifica al suo codice).
- Mai caricare l'immagine intera in memoria per generare la miniatura — usare `CGImageSourceCreateThumbnailAtIndex` (ImageIO), coerente con la lezione già imparata sul bug di memoria di `sha256(of:)` documentata in `Docs/CLAUDE.md`.
- Nessuna miniatura nel `CompletionSheet`, nessuna cache tra sessioni — fuori scope, deciso in brainstorming.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Baseline nota: 75 test XCTest verdi. I task che aggiungono solo firme/wiring (senza nuovi test) devono lasciare la conta a 75; il task con la funzione pura `FileKind.isImage` la porta a un numero maggiore (verificare il numero esatto riportato da `xcodebuild test` in quel task, non assumerlo).
- Controllo incrociato obbligatorio a fine piano sulle righe riassuntive di `Docs/ROADMAP.md` (vedi Task 6) — nelle ultime tre sessioni (#14, #15, #16) questo controllo ha sempre trovato almeno una riga rimasta disallineata.
- Comando build: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
- Comando test: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`

---

### Task 1: `FileKind.isImage(url:)` — funzione pura testabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (sezione `// MARK: - Shared utilities`, riga 310 — aggiungere subito dopo `isLikelyVolumeRoot`, righe 312-315)
- Test: `AppBackupFotoTests/FileKindIsImageTests.swift`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task
- Produces: `FileKind.isImage(url: URL) -> Bool` — Task 4 lo userà per decidere se generare una miniatura reale o un'icona generica

- [ ] **Step 1: Scrivere il test file (fallirà: `FileKind` non esiste ancora)**

Crea `AppBackupFotoTests/FileKindIsImageTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class FileKindIsImageTests: XCTestCase {
    func testKnownImageExtensions_returnTrue() {
        for ext in ["jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "bmp", "webp"] {
            let url = URL(fileURLWithPath: "/tmp/foto.\(ext)")
            XCTAssertTrue(FileKind.isImage(url: url), "atteso true per estensione \(ext)")
        }
    }

    func testNonImageExtensions_returnFalse() {
        for ext in ["zip", "pdf", "txt", "csv"] {
            let url = URL(fileURLWithPath: "/tmp/archivio.\(ext)")
            XCTAssertFalse(FileKind.isImage(url: url), "atteso false per estensione \(ext)")
        }
    }

    func testNoExtension_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/file-senza-estensione")
        XCTAssertFalse(FileKind.isImage(url: url))
    }

    func testUppercaseExtension_returnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/FOTO.JPG")
        XCTAssertTrue(FileKind.isImage(url: url))
    }
}
```

- [ ] **Step 2: Aggiungere il file al target di test in `project.pbxproj`**

Il target `AppBackupFotoTests` NON usa un gruppo file-system-synchronized (a differenza del target app) — ogni nuovo file va aggiunto a mano a `project.pbxproj` (`PBXBuildFile`/`PBXFileReference`/gruppo/Sources build phase), altrimenti resta silenziosamente escluso dalla suite. Seguire lo stesso pattern usato per gli altri file in `AppBackupFotoTests/` già presenti in `project.pbxproj` (cercare una entry esistente, es. `Sha256Tests.swift`, e replicarne la struttura con nuovi ID univoci per `FileKindIsImageTests.swift`).

- [ ] **Step 3: Eseguire i test per verificare che falliscano (compile error: `FileKind` non esiste)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`
Expected: FAIL — errore di compilazione, `FileKind` non trovato

- [ ] **Step 4: Implementare `FileKind.isImage(url:)`**

In `ContentView.swift`, subito dopo `isLikelyVolumeRoot` (righe 312-315), nella sezione `// MARK: - Shared utilities`:

```swift
enum FileKind {
    static func isImage(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
```

- [ ] **Step 5: Eseguire i test per verificare che passino, e verificare il nuovo conteggio totale**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `Executed 79 tests, with 0 failures` (75 esistenti + 4 nuovi in `FileKindIsImageTests`). Se il conteggio totale non è 79, il file di test non è stato incluso correttamente nel target (vedi Step 2) — non procedere finché il conteggio non torna.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/FileKindIsImageTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add FileKind.isImage pure function (roadmap #17)"
```

---

### Task 2: Threading `onCurrentFile` attraverso `FileSyncer`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:515-551` (`FileSyncer.sync`)
- Modify: `AppBackupFoto/ContentView.swift:565-591` (`FileSyncer.syncDir`)
- Modify: `AppBackupFoto/ContentView.swift:593-` (`FileSyncer.syncFile`, punto di chiamata riga 619-622)

**Interfaces:**
- Consumes: nessuna dipendenza da Task 1
- Produces: `FileSyncer.sync(from:to:deep:onStatus:onProgress:onCurrentFile:)` con `onCurrentFile` default `{ _ in }` — Task 4 passerà un callback reale da `runMacToSSD()`/`runSSDToHDD()`

- [ ] **Step 1: Estendere la firma pubblica `sync(...)` con default no-op**

Sostituire (righe 515-517):

```swift
    func sync(from src: URL, to dst: URL, deep: Bool,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void) async throws -> SyncResult {
```

con:

```swift
    func sync(from src: URL, to dst: URL, deep: Bool,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
```

- [ ] **Step 2: Passare `onCurrentFile` alla chiamata interna a `syncDir` (riga 543-544)**

Sostituire:

```swift
                    try self.syncDir(src: src, dst: dst, base: src, deep: deep,
                                     result: &result, onStatus: onStatus, onProgress: onProgress)
```

con:

```swift
                    try self.syncDir(src: src, dst: dst, base: src, deep: deep,
                                     result: &result, onStatus: onStatus, onProgress: onProgress,
                                     onCurrentFile: onCurrentFile)
```

- [ ] **Step 3: Estendere `syncDir` (righe 565-568) con il nuovo parametro, richiesto (nessun default — chiamante interno controllato in questo stesso task)**

Sostituire:

```swift
    private func syncDir(src: URL, dst: URL, base: URL, deep: Bool,
                         result: inout SyncResult,
                         onStatus: @escaping (String) -> Void,
                         onProgress: @escaping (SyncResult) -> Void) throws {
```

con:

```swift
    private func syncDir(src: URL, dst: URL, base: URL, deep: Bool,
                         result: inout SyncResult,
                         onStatus: @escaping (String) -> Void,
                         onProgress: @escaping (SyncResult) -> Void,
                         onCurrentFile: @escaping (URL) -> Void) throws {
```

- [ ] **Step 4: Propagare `onCurrentFile` nelle due chiamate ricorsive dentro `syncDir` (righe 584-588)**

Sostituire:

```swift
            if vals?.isDirectory == true {
                try syncDir(src: item, dst: destItem, base: base, deep: deep,
                            result: &result, onStatus: onStatus, onProgress: onProgress)
            } else if vals?.isRegularFile == true {
                syncFile(src: item, dst: destItem, deep: deep,
                         result: &result, onStatus: onStatus, onProgress: onProgress)
            }
```

con:

```swift
            if vals?.isDirectory == true {
                try syncDir(src: item, dst: destItem, base: base, deep: deep,
                            result: &result, onStatus: onStatus, onProgress: onProgress,
                            onCurrentFile: onCurrentFile)
            } else if vals?.isRegularFile == true {
                syncFile(src: item, dst: destItem, deep: deep,
                         result: &result, onStatus: onStatus, onProgress: onProgress,
                         onCurrentFile: onCurrentFile)
            }
```

- [ ] **Step 5: Estendere `syncFile` (righe 593-596) con il nuovo parametro**

Sostituire:

```swift
    private func syncFile(src: URL, dst: URL, deep: Bool,
                          result: inout SyncResult,
                          onStatus: @escaping (String) -> Void,
                          onProgress: @escaping (SyncResult) -> Void) {
```

con:

```swift
    private func syncFile(src: URL, dst: URL, deep: Bool,
                          result: inout SyncResult,
                          onStatus: @escaping (String) -> Void,
                          onProgress: @escaping (SyncResult) -> Void,
                          onCurrentFile: @escaping (URL) -> Void) {
```

- [ ] **Step 6: Chiamare `onCurrentFile(src)` subito prima della copia effettiva (righe 619-622), stesso punto di `onStatus`**

Sostituire:

```swift
                let snap = result
                DispatchQueue.main.async {
                    onStatus("Copia (\(snap.done + 1)/\(snap.total) — \(snap.percent)%): \(src.lastPathComponent)")
                }
```

con:

```swift
                let snap = result
                DispatchQueue.main.async {
                    onStatus("Copia (\(snap.done + 1)/\(snap.total) — \(snap.percent)%): \(src.lastPathComponent)")
                    onCurrentFile(src)
                }
```

- [ ] **Step 7: Build per verificare che compili (i call site esistenti — `runMacToSSD`, `runSSDToHDD`, `RestoreEngine` — non passano `onCurrentFile` e devono continuare a compilare grazie al default)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Eseguire i test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 79 tests, with 0 failures` (stessa baseline di fine Task 1 — questo task non aggiunge test, solo threading)

- [ ] **Step 9: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Thread onCurrentFile through FileSyncer sync/syncDir/syncFile (roadmap #17)"
```

---

### Task 3: Threading `onCurrentFile` attraverso `S3Syncer.sync`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:914-916` (firma `S3Syncer.sync`)
- Modify: `AppBackupFoto/ContentView.swift:960-972` (loop di upload dentro `runBounded`)

**Interfaces:**
- Consumes: nessuna dipendenza da Task 1/2
- Produces: `S3Syncer.sync(from:config:onStatus:onProgress:onCurrentFile:)` con `onCurrentFile` default `{ _ in }` — Task 4 passerà un callback reale da `runSyncS3()`

- [ ] **Step 1: Estendere la firma `sync(...)` con default no-op**

Sostituire (righe 914-916):

```swift
    func sync(from localURL: URL, config: S3Config,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void) async throws -> SyncResult {
```

con:

```swift
    func sync(from localURL: URL, config: S3Config,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
```

- [ ] **Step 2: Chiamare `onCurrentFile(item.url)` nel loop di upload (righe 963-965), stesso punto di `onStatus`**

Sostituire:

```swift
            operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
                if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                DispatchQueue.main.async { onStatus("Carico: \(item.url.lastPathComponent)") }
```

con:

```swift
            operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
                if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                DispatchQueue.main.async {
                    onStatus("Carico: \(item.url.lastPathComponent)")
                    onCurrentFile(item.url)
                }
```

Nota: fino a 4 upload procedono in parallelo (`maxConcurrent: 4`) — `onCurrentFile` può quindi essere chiamato da task concorrenti diversi quasi nello stesso momento. È un comportamento atteso (la miniatura mostrerà "l'ultimo che è arrivato", coerente con upload paralleli), non un bug da correggere in questo task.

- [ ] **Step 3: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Eseguire i test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 79 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Thread onCurrentFile through S3Syncer.sync (roadmap #17)"
```

---

### Task 4: `BackupRunner` genera e pubblica la miniatura

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1-7` (import)
- Modify: `AppBackupFoto/ContentView.swift` (classe `BackupRunner`, righe indicative 1478+ — verificare nel file reale la posizione esatta di `@Published var currentStatus`, per aggiungere `currentThumbnail` accanto)
- Modify: `AppBackupFoto/ContentView.swift:1573-1575` (`runMacToSSD`, chiamata a `syncer.sync`)
- Modify: `AppBackupFoto/ContentView.swift:1625-1627` (`runSSDToHDD`, chiamata a `syncer.sync`)
- Modify: `AppBackupFoto/ContentView.swift` (`runSyncS3`, chiamata a `s3syncer.sync` — verificare riga esatta nel file reale, indicativamente vicino a 1649-1655)
- Modify: `AppBackupFoto/ContentView.swift:1816` (`run(label:work:)`, reset stato a inizio job)

**Interfaces:**
- Consumes: `FileKind.isImage(url:) -> Bool` (Task 1), `FileSyncer.sync(...onCurrentFile:)` (Task 2), `S3Syncer.sync(...onCurrentFile:)` (Task 3)
- Produces: `BackupRunner.currentThumbnail: NSImage?` (pubblicato) — Task 5 lo userà nella UI

- [ ] **Step 1: Aggiungere `import ImageIO` in cima al file**

`ContentView.swift:1-7` attuale:

```swift
import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit
import Charts
```

Sostituire con:

```swift
import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit
import Charts
import ImageIO
```

- [ ] **Step 2: Trovare la posizione esatta di `@Published var currentStatus` in `BackupRunner`**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "@Published var currentStatus" AppBackupFoto/ContentView.swift`

- [ ] **Step 3: Aggiungere `currentThumbnail` e il token anti-staleness subito dopo `currentStatus`**

Nella riga trovata al passo precedente, aggiungere subito dopo la dichiarazione di `@Published var currentStatus = ""`:

```swift
    @Published var currentThumbnail: NSImage?
    private var thumbnailRequestID = UUID()
```

- [ ] **Step 4: Aggiungere `publishCurrentFile(_:)` e `makeThumbnail(url:maxPixelSize:)` come metodi di `BackupRunner`**

Aggiungere, vicino agli altri metodi privati di supporto della classe (es. accanto a `publishStatus`/`publishProgress`, trovabili con `grep -n "private func publishStatus" AppBackupFoto/ContentView.swift`):

```swift
    func publishCurrentFile(_ url: URL) {
        let requestID = UUID()
        thumbnailRequestID = requestID
        if FileKind.isImage(url: url) {
            Task.detached(priority: .utility) { [weak self] in
                let thumb = Self.makeThumbnail(url: url, maxPixelSize: 88)
                await MainActor.run {
                    guard let self, self.thumbnailRequestID == requestID else { return }
                    self.currentThumbnail = thumb
                }
            }
        } else {
            currentThumbnail = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: .zero)
    }
```

**Nota tecnica — `nonisolated` non è opzionale**: `BackupRunner` è `@MainActor` (dichiarazione della classe), e l'isolamento si propaga per inferenza a tutti i membri inclusi i metodi `static`. Senza `nonisolated`, `makeThumbnail` sarebbe MainActor-isolated e la chiamata `Self.makeThumbnail(...)` dentro `Task.detached` (che gira fuori dal MainActor) non compilerebbe senza `await` — e mettere `await` lì vanificherebbe lo scopo di generare la miniatura in background, riportando il lavoro sul MainActor esattamente come si voleva evitare. `nonisolated` è corretto qui perché la funzione è pura (nessun accesso a stato dell'attore).

- [ ] **Step 5: Azzerare `currentThumbnail` a inizio job, stesso punto di `currentStatus`**

Trovare in `run(label:work:)` (`ContentView.swift:1816` circa) la riga:

```swift
        output = ""; stats = JobStats(); currentStatus = ""
```

Sostituirla con:

```swift
        output = ""; stats = JobStats(); currentStatus = ""; currentThumbnail = nil
```

- [ ] **Step 6: Passare il callback reale da `runMacToSSD()` (righe 1573-1575)**

Sostituire:

```swift
                return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) })
```

con:

```swift
                return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) })
```

- [ ] **Step 7: Passare il callback reale da `runSSDToHDD()` (righe 1625-1627)**

Sostituire:

```swift
                let r = try await self?.syncer.sync(from: ssdURL, to: hddURL, deep: deep,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) })
```

con:

```swift
                let r = try await self?.syncer.sync(from: ssdURL, to: hddURL, deep: deep,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) })
```

- [ ] **Step 8: Passare il callback reale da `runSyncS3()` (riga 1653-1674 circa — verificare nel file reale che corrisponda, i numeri di riga sono shiftati dai task precedenti)**

Contenuto attuale (contesto: dentro la closure passata a `run(label: "SSD -> Cubbit S3")`):

```swift
                let r = try await s3syncer.sync(
                    from: ssdURL, config: config,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { [weak self] snap in
                        guard let self else { return }
                        self.stats.percent = snap.percent
                        self.stats.done = snap.done; self.stats.total = snap.total
                        self.stats.copied = snap.uploaded; self.stats.skipped = snap.skipped
                        self.stats.errors = snap.errors
                        self.stats.changedSkipped = snap.changedSkipped
                        self.stats.elapsed = S3Syncer.SyncResult.hms(snap.elapsedSec)
                        self.stats.eta = snap.etaSec > 0 ? self.smoothEta(raw: snap.etaSec) : "—"
                        let elapsed = max(0.1, Date().timeIntervalSince(snap.startDate))
                        if snap.uploadedBytes > 0 {
                            let mbps = Double(snap.uploadedBytes) / 1_048_576.0 / elapsed
                            self.stats.speed = String(format: "%.2f MB/s", mbps)
                            self.appendSpeedSample(mbps)
                        } else if snap.done > 0 {
                            let fps = Double(snap.done) / elapsed
                            self.stats.speed = String(format: "%.0f elem/s", fps)
                        }
                    })
```

Sostituire l'ultima riga (`                    })`) con:

```swift
                    },
                    onCurrentFile: { self?.publishCurrentFile($0) })
```

(il resto del blocco, dalla riga `let r = try await s3syncer.sync(` fino alla penultima riga `                        }`, resta invariato — si tocca solo la chiusura della chiamata per aggiungere il nuovo argomento).

- [ ] **Step 9: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Eseguire i test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 79 tests, with 0 failures`

- [ ] **Step 11: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "BackupRunner generates and publishes current-file thumbnail (roadmap #17)"
```

---

### Task 5: UI — `CurrentFileThumbnail` in `StatsPanel`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuova view, vicino a `StatusBar`, riga 3225 circa — verificare nel file reale, i numeri di riga sono shiftati dai task precedenti)
- Modify: `AppBackupFoto/ContentView.swift` (`StatsPanel.body`, dove oggi c'è `StatusBar(status: currentStatus, phase: phase)`)

**Interfaces:**
- Consumes: `BackupRunner.currentThumbnail: NSImage?` (Task 4)
- Produces: nessuna interfaccia per altri task — ultimo task di codice del piano

- [ ] **Step 1: Trovare la posizione esatta di `StatusBar` e `StatsPanel` nel file reale (i numeri di riga sono shiftati dai task 1-4)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "struct StatusBar\|struct StatsPanel\|StatusBar(status:" AppBackupFoto/ContentView.swift`

- [ ] **Step 2: Aggiungere la view `CurrentFileThumbnail` subito prima di `struct StatusBar`**

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

- [ ] **Step 3: Integrare la view in `StatsPanel`, accanto a `StatusBar`**

Nel `body` di `StatsPanel`, trovare la riga:

```swift
            StatusBar(status: currentStatus, phase: phase)
```

Serve anche l'accesso a `runner.currentThumbnail` — `StatsPanel` oggi riceve `stats`/`phase`/`currentStatus` come parametri semplici (non `@EnvironmentObject`), quindi aggiungere un nuovo parametro `currentThumbnail: NSImage?` alla struct:

Trovare (all'inizio di `struct StatsPanel`):

```swift
struct StatsPanel: View {
    let stats: JobStats; let phase: JobPhase; let currentStatus: String
```

Sostituire con:

```swift
struct StatsPanel: View {
    let stats: JobStats; let phase: JobPhase; let currentStatus: String; let currentThumbnail: NSImage?
```

Poi sostituire la riga `StatusBar(status: currentStatus, phase: phase)` con:

```swift
            HStack(spacing: 10) {
                CurrentFileThumbnail(image: currentThumbnail)
                StatusBar(status: currentStatus, phase: phase)
            }
```

- [ ] **Step 4: Aggiornare il call site di `StatsPanel` per passare `runner.currentThumbnail`**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "StatsPanel(stats:" AppBackupFoto/ContentView.swift`

Nella riga trovata (stile: `StatsPanel(stats: runner.stats, phase: runner.phase, currentStatus: runner.currentStatus)`), aggiungere `, currentThumbnail: runner.currentThumbnail` prima della parentesi di chiusura.

- [ ] **Step 5: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Eseguire i test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 79 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Show live current-file thumbnail in StatsPanel (roadmap #17)"
```

- [ ] **Step 8: Annotare la verifica manuale ancora da fare**

Non automatizzabile in ambiente headless. Aggiungerla come nota nel report finale del task: avviare un job reale con foto reali e, se possibile, almeno un file dalla cartella "Zip", controllare che la miniatura cambi file per file, mostri l'icona generica per lo zip, non rallenti visibilmente la copia, e che l'orientamento delle foto (EXIF) sia corretto.

---

### Task 6: Aggiornamento documentazione (`Docs/CLAUDE.md`, `Docs/ROADMAP.md`)

**Files:**
- Modify: `Docs/CLAUDE.md` (sezione `BackupRunner` in "Architettura Swift")
- Modify: `Docs/ROADMAP.md` (voce #17, e le righe riassuntive)

**Interfaces:**
- Consumes: risultato dei Task 1-5 (feature completa, build/test verdi)
- Produces: nessuna interfaccia di codice — solo documentazione

- [ ] **Step 1: Aggiungere una voce in `Docs/CLAUDE.md`, sezione `### BackupRunner`**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "^### BackupRunner" Docs/CLAUDE.md`

Aggiungere in fondo alla sezione, stesso stile delle voci esistenti:

```
- **Miniatura live dell'ultimo file (2026-08-09, roadmap #17)**: `BackupRunner.publishCurrentFile(_:)` riceve l'URL del file corrente da un nuovo callback `onCurrentFile`, threaded attraverso `FileSyncer.sync/syncDir/syncFile` e `S3Syncer.sync` (default no-op sulle firme pubbliche, `RestoreEngine` non toccato). Per le immagini genera una miniatura leggera via ImageIO (`CGImageSourceCreateThumbnailAtIndex`, mai l'immagine intera in memoria — stessa lezione del bug di memoria di `sha256(of:)`), per il resto usa l'icona di sistema (`NSWorkspace.shared.icon(forFile:)`). Un token (`thumbnailRequestID`) scarta miniature arrivate in ritardo su file già superati. Pubblicato in `currentThumbnail`, mostrato in `StatsPanel` (`CurrentFileThumbnail`) solo live durante il job, non nel `CompletionSheet`. Vedi `Docs/superpowers/specs/2026-08-09-current-file-thumbnail-design.md`.
```

- [ ] **Step 2: Aggiornare la voce #17 in `Docs/ROADMAP.md`**

Trova la riga:

```
17. **Nessuna miniatura dell'ultimo file backuppato** — tocco di fiducia visiva usato da Mylio/PhotoSync.
    *Fonte: ricerca su pattern UX di Mylio Photos*
```

Sostituiscila con (mantenendo la riga `*Fonte:*` invariata subito dopo):

```
17. ✅ **Fatto (2026-08-09) — Nessuna miniatura dell'ultimo file backuppato.** Miniatura live in `StatsPanel` durante un job (foto vera via ImageIO per le immagini, icona di sistema per il resto, es. gli zip nella cartella "Zip") — solo live, non nel riepilogo finale. Vedi `Docs/superpowers/specs/2026-08-09-current-file-thumbnail-design.md`.
    *Fonte: ricerca su pattern UX di Mylio Photos*
```

- [ ] **Step 3: Aggiornare la riga riassuntiva "Fatti:"**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "Fatti: #1 restore" Docs/ROADMAP.md`

Aggiungere `, #17 miniatura live` dopo `#16 notifica errore.`, e correggere l'intervallo dei punti "valore aggiunto" rimanenti (attualmente `17-20`) togliendo `17`: deve diventare `18-20`.

- [ ] **Step 4: Controllo incrociato — leggere OGNI riga trovata, non solo la prima**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "17-20\|18-20\|#17\|valore aggiunto" Docs/ROADMAP.md`

Per ogni riga risultante: se cita ancora #17 come punto aperto o l'intervallo `17-20` come tutto da fare, correggerla con lo stesso criterio del passo 3. Nelle ultime tre sessioni (#14, #15, #16) questo controllo ha sempre trovato almeno una riga rimasta disallineata nella sezione "Stato aggiornato (2026-08-09)" più in basso nel file — controllare in particolare quella sezione.

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: current-file thumbnail (#17) shipped"
```
