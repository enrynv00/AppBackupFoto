# Controllo spazio libero prima del backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prima di avviare Mac→SSD o SSD→HDD (manuale o automatico), controllare che il volume di destinazione abbia spazio sufficiente e bloccare l'avvio con un alert se non basta.

**Architecture:** `FileSyncer.previewSync` viene esteso per sommare anche i byte dei file da copiare (`toAddBytes`), non solo contarli. `BackupRunner` guadagna un helper `hasSufficientSpace(bytesNeeded:atVolumeOf:)` che legge lo spazio libero reale del volume (`URLResourceValues.volumeAvailableCapacity`) con un margine di sicurezza. `runMacToSSD()`/`runSSDToHDD()` chiamano `previewSync` + il nuovo helper in un `Task { @MainActor }` subito dopo i guard sincroni esistenti (bookmark, `isLikelyVolumeRoot`) — se lo spazio non basta, mostrano un `NSAlert` e non chiamano mai `run(label:)`, quindi il job non entra mai in `phase: .running`.

**Tech Stack:** Swift 5.x, Foundation (`URLResourceValues`, `ByteCountFormatter` — nessuna dipendenza nuova), XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Zero delete, zero overwrite, read-only sulla sorgente — questa feature non copia né cancella nulla, calcola solo dimensioni; nessun impatto su questa regola.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Margine di sicurezza: lo spazio libero deve superare i byte necessari di almeno il 5% di quei byte, o almeno 500.000.000 byte (500MB), il maggiore dei due — mai basta "esattamente pari".
- Ambito: solo Mac→SSD e SSD→HDD. SSD→S3 resta invariato (nessun limite pratico su Cubbit per questo caso d'uso).
- Il controllo si applica anche al trigger automatico Mac→SSD al collegamento SSD (nessuna modifica separata necessaria: eredita il comportamento da `runMacToSSD()`, già chiamato da quel trigger).
- `previewMacToSSD()`/`previewSSDToHDD()` (righe indicative 1366/1401 — verificare nel file reale) accedono al risultato di `previewSync` per nome (`result.toAdd`, `result.toSkip`, `result.estimatedSec`), non per posizione: aggiungere `toAddBytes` alla tupla non richiede modificarli.

---

### Task 1: `FileSyncer.previewSync` calcola anche i byte da copiare

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (metodi `previewSync`/`previewDir`/`previewFile` della classe `FileSyncer`, righe indicative 278-317 — verificare nel file reale col contenuto esatto mostrato sotto)
- Create: `AppBackupFotoTests/FileSyncerPreviewBytesTests.swift`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task
- Produces: `FileSyncer.previewSync(from:to:deep:) async -> (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int)` — Task 2 userà il campo `toAddBytes`

- [ ] **Step 1: Scrivere il test file con i casi che verificano `toAddBytes` (fallirà: il campo non esiste ancora)**

Crea `AppBackupFotoTests/FileSyncerPreviewBytesTests.swift`:

```swift
//
//  FileSyncerPreviewBytesTests.swift
//  AppBackupFotoTests
//
//  Verifica che FileSyncer.previewSync sommi correttamente i byte dei file
//  che verrebbero copiati (toAddBytes), ignorando i file già presenti a
//  destinazione (zero-overwrite: skippati, non contano nei byte da aggiungere).
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerPreviewBytesTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerPreviewBytesTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        root = nil; srcDir = nil; dstDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ url: URL, byteCount: Int) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    func testSingleNewFile_sumsItsByteCount() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toAddBytes, 1000)
    }

    func testMultipleNewFiles_sumsAllByteCounts() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 2500)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toAddBytes, 3500)
    }

    func testExistingDestFile_isSkippedAndNotCountedInBytes() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 2500)
        try writeFile(dstDir.appendingPathComponent("a.jpg"), byteCount: 1000)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toSkip, 1)
        XCTAssertEqual(result.toAddBytes, 2500)
    }

    func testNestedSubdirectory_bytesAreSummedAcrossSubdirs() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("2024/b.jpg"), byteCount: 2500)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toAddBytes, 3500)
    }

    func testEmptySource_zeroBytes() async throws {
        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 0)
        XCTAssertEqual(result.toAddBytes, 0)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `value of type '(toAdd: Int, toSkip: Int, estimatedSec: Int)' has no member 'toAddBytes'`. Se il file di test non compare nei risultati del test target, verifica che sia stato aggiunto al gruppo file-system-synchronized dell'app (Xcode lo fa automaticamente per i nuovi file nella cartella `AppBackupFotoTests/` — se non succede, aggiungilo manualmente al target `AppBackupFotoTests` da Xcode prima di continuare).

- [ ] **Step 3: Implementare `toAddBytes` in `FileSyncer.previewSync`/`previewDir`/`previewFile`**

Trova (nella classe `FileSyncer`):

```swift
    func previewSync(from src: URL, to dst: URL, deep: Bool) async -> (toAdd: Int, toSkip: Int, estimatedSec: Int) {
        return await withCheckedContinuation { [self] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cancelled = false
                var toAdd = 0
                var toSkip = 0
                self.previewDir(src: src, dst: dst, deep: deep, toAdd: &toAdd, toSkip: &toSkip)
                let estimatedSec = toAdd > 0 ? max(1, toAdd / 50) : 0
                cont.resume(returning: (toAdd: toAdd, toSkip: toSkip, estimatedSec: estimatedSec))
            }
        }
    }

    private func previewDir(src: URL, dst: URL, deep: Bool, toAdd: inout Int, toSkip: inout Int) {
        if cancelled { return }
        guard let items = try? fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if cancelled { return }
            if shouldExclude(item) { continue }
            let vals = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let destItem = dst.appendingPathComponent(item.lastPathComponent)
            if vals?.isDirectory == true {
                previewDir(src: item, dst: destItem, deep: deep, toAdd: &toAdd, toSkip: &toSkip)
            } else if vals?.isRegularFile == true {
                previewFile(src: item, dst: destItem, toAdd: &toAdd, toSkip: &toSkip)
            }
        }
    }

    private func previewFile(src: URL, dst: URL, toAdd: inout Int, toSkip: inout Int) {
        // Zero-overwrite rule: se il file esiste gia a destinazione sara sempre skippato
        if fm.fileExists(atPath: dst.path) {
            toSkip += 1
        } else {
            toAdd += 1
        }
    }
```

Sostituisci con:

```swift
    func previewSync(from src: URL, to dst: URL, deep: Bool) async
        -> (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int) {
        return await withCheckedContinuation { [self] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cancelled = false
                var toAdd = 0
                var toSkip = 0
                var toAddBytes: Int64 = 0
                self.previewDir(src: src, dst: dst, deep: deep, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
                let estimatedSec = toAdd > 0 ? max(1, toAdd / 50) : 0
                cont.resume(returning: (toAdd: toAdd, toSkip: toSkip, toAddBytes: toAddBytes, estimatedSec: estimatedSec))
            }
        }
    }

    private func previewDir(src: URL, dst: URL, deep: Bool, toAdd: inout Int, toSkip: inout Int, toAddBytes: inout Int64) {
        if cancelled { return }
        guard let items = try? fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if cancelled { return }
            if shouldExclude(item) { continue }
            let vals = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let destItem = dst.appendingPathComponent(item.lastPathComponent)
            if vals?.isDirectory == true {
                previewDir(src: item, dst: destItem, deep: deep, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
            } else if vals?.isRegularFile == true {
                previewFile(src: item, dst: destItem, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
            }
        }
    }

    private func previewFile(src: URL, dst: URL, toAdd: inout Int, toSkip: inout Int, toAddBytes: inout Int64) {
        // Zero-overwrite rule: se il file esiste gia a destinazione sara sempre skippato
        if fm.fileExists(atPath: dst.path) {
            toSkip += 1
        } else {
            toAdd += 1
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            toAddBytes += Int64(size)
        }
    }
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 5 nuovi di questo task (totale 54: i 49 esistenti + 5 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/FileSyncerPreviewBytesTests.swift
git commit -m "$(cat <<'EOF'
FileSyncer.previewSync also sums bytes of files to be copied

Adds toAddBytes to the preview result, needed to check destination free
space before starting a job. Skipped (already-present) files don't
count, consistent with the zero-overwrite rule.
EOF
)"
```

---

### Task 2: Controllo spazio libero in `runMacToSSD()`/`runSSDToHDD()`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (classe `BackupRunner`: aggiunta di `hasSufficientSpace`, modifica di `runMacToSSD()` e `runSSDToHDD()`, righe indicative 1249-1315 — verificare nel file reale col contenuto esatto mostrato sotto)

**Interfaces:**
- Consumes: `FileSyncer.previewSync(from:to:deep:) async -> (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int)` (prodotto da Task 1)
- Produces: `BackupRunner.hasSufficientSpace(bytesNeeded:atVolumeOf:) -> (ok: Bool, availableBytes: Int64)` — nessun altro consumer previsto in questo piano

- [ ] **Step 1: Aggiungere l'helper `hasSufficientSpace` a `BackupRunner`**

Trova (nella classe `BackupRunner`):

```swift
    func runMacToSSD() {
```

Inserisci subito prima (stesso livello di indentazione, dentro la classe `BackupRunner`):

```swift
    private func hasSufficientSpace(bytesNeeded: Int64, atVolumeOf url: URL) -> (ok: Bool, availableBytes: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        let margin = max(Int64(Double(bytesNeeded) * 0.05), 500_000_000)
        return (available >= bytesNeeded + margin, available)
    }

    func runMacToSSD() {
```

- [ ] **Step 2: Riscrivere `runMacToSSD()` con il controllo spazio prima di `run()`**

Trova:

```swift
    func runMacToSSD() {
        speedUnit = "file/s"
        guard let photosURL = bm.startAccessing(.photos) else {
            alert("Accesso alla Libreria Foto non disponibile",
                  "Vai in Impostazioni (ingranaggio) e riseleziona la cartella Foto.")
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd) else {
            bm.stopAccessing(.photos)
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.photos); bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        let dst = ssdURL.appendingPathComponent("Foto iPhone")
        run(label: "MAC -> SSD") { [weak self] in
            self?.publishStatus("Foto: \(photosURL.path)  →  SSD: \(dst.path)")
            defer { self?.bm.stopAccessing(.photos); self?.bm.stopAccessing(.ssd) }
            return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                onStatus: { self?.publishStatus($0) },
                onProgress: { self?.publishProgress($0) })
        }
    }
```

Sostituisci con:

```swift
    func runMacToSSD() {
        speedUnit = "file/s"
        guard let photosURL = bm.startAccessing(.photos) else {
            alert("Accesso alla Libreria Foto non disponibile",
                  "Vai in Impostazioni (ingranaggio) e riseleziona la cartella Foto.")
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd) else {
            bm.stopAccessing(.photos)
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.photos); bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
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
                self?.publishStatus("Foto: \(photosURL.path)  →  SSD: \(dst.path)")
                defer { self?.bm.stopAccessing(.photos); self?.bm.stopAccessing(.ssd) }
                return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) })
            }
        }
    }
```

- [ ] **Step 3: Riscrivere `runSSDToHDD()` con il controllo spazio prima di `run()`**

Trova:

```swift
    func runSSDToHDD() {
        speedUnit = "file/s"
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        guard let hddURL = bm.startAccessing(.hdd) else {
            bm.stopAccessing(.ssd)
            alert("Accesso all'HDD non disponibile", "Vai in Impostazioni e riseleziona l'HDD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        if !isLikelyVolumeRoot(hddURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark HDD non valido",
                  "Il percorso '\(hddURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona HDD scegliendo '/Volumes/BackupHDD' (root del volume, non una sottocartella).")
            return
        }
        let now = Date()
        let lastDeep = UserDefaults.standard.object(forKey: lastDeepKey) as? Date ?? .distantPast
        let deep = now.timeIntervalSince(lastDeep) > TimeInterval(30 * 24 * 3600)
        let label = deep ? "SSD -> HDD (deep)" : "SSD -> HDD"
        run(label: label) { [weak self] in
            self?.publishStatus("SSD: \(ssdURL.path)  →  HDD: \(hddURL.path)")
            defer { self?.bm.stopAccessing(.ssd); self?.bm.stopAccessing(.hdd) }
            let r = try await self?.syncer.sync(from: ssdURL, to: hddURL, deep: deep,
                onStatus: { self?.publishStatus($0) },
                onProgress: { self?.publishProgress($0) })
            if deep, (r?.errors ?? 1) == 0 {
                UserDefaults.standard.set(Date(), forKey: self?.lastDeepKey ?? "")
            }
            return r
        }
    }
```

Sostituisci con:

```swift
    func runSSDToHDD() {
        speedUnit = "file/s"
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        guard let hddURL = bm.startAccessing(.hdd) else {
            bm.stopAccessing(.ssd)
            alert("Accesso all'HDD non disponibile", "Vai in Impostazioni e riseleziona l'HDD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        if !isLikelyVolumeRoot(hddURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark HDD non valido",
                  "Il percorso '\(hddURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona HDD scegliendo '/Volumes/BackupHDD' (root del volume, non una sottocartella).")
            return
        }
        let now = Date()
        let lastDeep = UserDefaults.standard.object(forKey: lastDeepKey) as? Date ?? .distantPast
        let deep = now.timeIntervalSince(lastDeep) > TimeInterval(30 * 24 * 3600)
        let label = deep ? "SSD -> HDD (deep)" : "SSD -> HDD"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = await self.syncer.previewSync(from: ssdURL, to: hddURL, deep: deep)
            let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: hddURL)
            guard space.ok else {
                self.bm.stopAccessing(.ssd); self.bm.stopAccessing(.hdd)
                let a = NSAlert()
                a.messageText = "Spazio insufficiente sull'HDD"
                a.informativeText = "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                    + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(hddURL.path)."
                a.alertStyle = .warning
                a.addButton(withTitle: "OK")
                a.runModal()
                return
            }
            self.run(label: label) { [weak self] in
                self?.publishStatus("SSD: \(ssdURL.path)  →  HDD: \(hddURL.path)")
                defer { self?.bm.stopAccessing(.ssd); self?.bm.stopAccessing(.hdd) }
                let r = try await self?.syncer.sync(from: ssdURL, to: hddURL, deep: deep,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) })
                if deep, (r?.errors ?? 1) == 0 {
                    UserDefaults.standard.set(Date(), forKey: self?.lastDeepKey ?? "")
                }
                return r
            }
        }
    }
```

- [ ] **Step 4: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Eseguire l'intera suite di test per verificare che nulla si sia rotto**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 54 test passano (invariati rispetto a Task 1 — questo task non aggiunge test automatici, vedi nota sotto).

Nota: nessun nuovo test XCTest per `hasSufficientSpace`/il flusso di `runMacToSSD`/`runSSDToHDD` — dipendono dallo spazio libero reale del disco e dall'accesso ai bookmark reali, non deterministici in un ambiente di test headless (stesso motivo per cui `runMacToSSD`/`runSSDToHDD` non hanno test automatici oggi). Verifica manuale richiesta: vedi Task 3.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Block Mac->SSD/SSD->HDD if destination volume lacks free space

Both jobs now preview-scan the source (already-existing pattern, reused
from the manual preview button) and compare bytes needed against real
free space on the destination volume before calling run(), with a 5%
(min 500MB) safety margin. Blocks with an NSAlert showing the exact
numbers instead of letting a job fail partway through. SSD->S3 is
unaffected (no practical space limit on Cubbit for this use case).
EOF
)"
```

---

### Task 3: Aggiornare la documentazione del progetto

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:**
- Consumes: nessuna (solo modifiche testuali)
- Produces: nessuna

- [ ] **Step 1: Aggiornare `Docs/CLAUDE.md`**

Nella sezione `### BackupRunner (`@MainActor ObservableObject`)`, dopo la riga che descrive `runMacToSSD()` / `runSSDToHDD()` / `runSyncS3()`, aggiungi:

```
- **Controllo spazio libero (2026-08-09)**: `runMacToSSD()` e `runSSDToHDD()` calcolano i byte da copiare (`FileSyncer.previewSync`, esteso con `toAddBytes`) e li confrontano con lo spazio libero reale sul volume di destinazione (`hasSufficientSpace`, margine 5%/min 500MB) prima di chiamare `run()` — se insufficiente, alert bloccante e il job non parte mai. SSD→S3 non è coperto (nessun limite pratico su Cubbit).
```

- [ ] **Step 2: Aggiornare `Docs/ROADMAP.md`**

Trova il punto 8 nella sezione `## Alto — prestazioni e qualità percepita (6)`:

```
8. **Nessun controllo di spazio libero prima di partire** — se HDD si riempie a metà copia, l'errore arriva a job già a metà.
   *Effort: basso · `resourceValues(.volumeAvailableCapacityKey)` prima di `run()`*
```

Sostituisci con:

```
8. ✅ **Fatto (2026-08-09) — Nessun controllo di spazio libero prima di partire.** `runMacToSSD()`/`runSSDToHDD()` ora controllano lo spazio libero sul volume di destinazione prima di avviare (margine 5%/min 500MB), bloccando con un alert se insufficiente. SSD→S3 escluso (nessun limite pratico su Cubbit). Vedi `Docs/superpowers/specs/2026-08-09-free-space-check-design.md`.
```

Nella sezione `## Da dove partire (aggiornato 2026-08-02)`, aggiungi `#8 controllo spazio` all'elenco dei punti "Fatti".

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: free space check shipped"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** i 4 punti del design tecnico dello spec (byte in `previewSync`, helper spazio, controllo in `runMacToSSD`/`runSSDToHDD`, formattazione leggibile) sono coperti da Task 1 (punti 1/4) e Task 2 (punti 2/3). Ambito limitato a Mac→SSD/SSD→HDD rispettato — nessuna modifica a `runSyncS3()`. `previewMacToSSD()`/`previewSSDToHDD()` correttamente non toccati (accesso per nome alla tupla, non per posizione).

**Scan placeholder:** nessuno — ogni step ha codice completo, comandi esatti e output atteso.

**Coerenza dei tipi:** `previewSync` restituisce `(toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int)` in Task 1, usato identicamente (`preview.toAddBytes`) in Task 2. `hasSufficientSpace(bytesNeeded: Int64, atVolumeOf: URL) -> (ok: Bool, availableBytes: Int64)` definito e usato coerentemente in Task 2.
