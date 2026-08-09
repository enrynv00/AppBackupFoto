# Segnalazione file cambiati-non-copiati Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Segnalare a fine job quanti file locali sono stati "skippati" non perché già identici, ma perché diversi dalla copia già presente a destinazione (zero-overwrite li protegge comunque, ma oggi l'utente non lo sa mai).

**Architecture:** Un nuovo campo `changedSkipped` attraversa la catena già esistente (`FileSyncer.SyncResult` → `JobStats` → `JobSummary`), popolato dove il confronto "file esiste ma è diverso" già avviene oggi per tutti e tre i job — nessuna nuova scansione. `CompletionSheet` mostra una riga condizionale se `> 0`.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Zero delete, zero overwrite, read-only sulla sorgente — questa feature è puramente di segnalazione, non cambia in alcun modo quali file vengono copiati o skippati, solo distingue due tipi di skip già esistenti.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Fuori scope: nessun salvataggio di nuove versioni, nessun elenco di nomi file (né nel riepilogo né nel log), nessuna nuova voce nel pannello Revisione, nessuna modifica a `StatsPanel`.
- `JobSummary` guadagna un nuovo campo `Codable` non opzionale con default `0` — un `JobSummary` persistito PRIMA di questa modifica (in `UserDefaults`, chiave `lastJobSummary`) non ha quella chiave nel JSON: la prima volta che l'app lo rilegge dopo l'aggiornamento, `JSONDecoder` fallirà su quel blob specifico e `JobHistoryStore.load()` restituirà `nil` (già gestito con `try?`, nessun crash) — il pannello Tools mostrerà "nessun job precedente" finché non gira il prossimo job, che sovrascrive con un blob valido. Comportamento accettato, non è un bug da correggere in questo piano.

---

### Task 1: `changedSkipped` in `FileSyncer` (Mac→SSD, SSD→HDD) con TDD

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`FileSyncer.SyncResult` riga 435, `syncFile` riga 585 — verificare nel file reale)
- Create: `AppBackupFotoTests/FileSyncerChangedSkippedTests.swift`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task
- Produces: `FileSyncer.SyncResult.changedSkipped: Int` — Task 3 lo propagherà a `JobStats`/`JobSummary`

- [ ] **Step 1: Scrivere il test file (fallirà: il campo non esiste ancora)**

Crea `AppBackupFotoTests/FileSyncerChangedSkippedTests.swift`:

```swift
//
//  FileSyncerChangedSkippedTests.swift
//  AppBackupFotoTests
//
//  Verifica che FileSyncer.sync distingua "file identico, skippato" da "file
//  esistente ma diverso, skippato per zero-overwrite" (roadmap #13).
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerChangedSkippedTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerChangedSkippedTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil; srcDir = nil; dstDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ url: URL, _ contents: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testChangedExistingFile_incrementsChangedSkippedAndSkipped() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), "new content, different size")
        try writeFile(dstDir.appendingPathComponent("a.jpg"), "old")

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.changedSkipped, 1)
        XCTAssertEqual(result.copied, 0)
    }

    func testIdenticalExistingFile_doesNotIncrementChangedSkipped() async throws {
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let srcURL = try writeFile(srcDir.appendingPathComponent("a.jpg"), "same")
        let dstURL = try writeFile(dstDir.appendingPathComponent("a.jpg"), "same")
        try fm.setAttributes([.modificationDate: sameDate], ofItemAtPath: srcURL.path)
        try fm.setAttributes([.modificationDate: sameDate], ofItemAtPath: dstURL.path)

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.changedSkipped, 0)
    }

    func testNewFile_doesNotIncrementChangedSkipped() async throws {
        try writeFile(srcDir.appendingPathComponent("new.jpg"), "brand new")

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.changedSkipped, 0)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `value of type 'FileSyncer.SyncResult' has no member 'changedSkipped'`. Se il file di test non compare nei risultati, aggiungilo manualmente al target `AppBackupFotoTests` in `project.pbxproj` (problema noto, già incontrato più volte in questo progetto: entry `PBXFileReference`/`PBXBuildFile`/gruppo/Sources build phase).

- [ ] **Step 3: Aggiungere il campo e la logica**

Trova (`FileSyncer.SyncResult`):

```swift
    struct SyncResult {
        var total = 0; var done = 0; var copied = 0; var skipped = 0; var errors = 0
        var hashErrors = 0   // file con SHA256 mismatch dopo la copia
        var startDate = Date()
```

Sostituisci con:

```swift
    struct SyncResult {
        var total = 0; var done = 0; var copied = 0; var skipped = 0; var errors = 0
        var hashErrors = 0   // file con SHA256 mismatch dopo la copia
        var changedSkipped = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
        var startDate = Date()
```

Trova (in `syncFile`):

```swift
        if needs {
            if fm.fileExists(atPath: dst.path) {
                // destination exists but differs — zero-overwrite rule: skip
                result.skipped += 1
            } else {
```

Sostituisci con:

```swift
        if needs {
            if fm.fileExists(atPath: dst.path) {
                // destination exists but differs — zero-overwrite rule: skip
                result.skipped += 1
                result.changedSkipped += 1
            } else {
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 3 nuovi di questo task (totale 72: i 69 esistenti + 3 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/FileSyncerChangedSkippedTests.swift
git commit -m "$(cat <<'EOF'
FileSyncer.SyncResult distinguishes changed-but-skipped from identical

New changedSkipped counter, incremented alongside the existing skipped
counter in the branch that already detects "destination exists but
differs" for zero-overwrite. No new scanning — reuses the comparison
already computed today. Roadmap #13 (report only, no auto-versioning).
EOF
)"
```

---

### Task 2: `S3Syncer.isChangedExistingKey` (SSD→S3) con TDD

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo metodo statico in `final class S3Syncer`, subito dopo `shouldUpload` riga 651; fix di `sync()` riga 896-930 — verificare nel file reale)
- Create: `AppBackupFotoTests/S3SyncerChangedKeyTests.swift`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task (indipendente da Task 1)
- Produces: `S3Syncer.isChangedExistingKey(key:size:existing:) -> Bool`; `S3Syncer.SyncResult.changedSkipped: Int` — Task 3 li propagherà a `JobStats`/`JobSummary`

- [ ] **Step 1: Scrivere il test file (fallirà: la funzione non esiste ancora)**

Crea `AppBackupFotoTests/S3SyncerChangedKeyTests.swift`:

```swift
//
//  S3SyncerChangedKeyTests.swift
//  AppBackupFotoTests
//
//  Verifica S3Syncer.isChangedExistingKey — funzione pura, nessuna rete.
//  Conteggio informativo per il roadmap #13, non influenza la decisione di
//  upload (S3Syncer.shouldUpload, già corretta dal fix di BUG-3).
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerChangedKeyTests: XCTestCase {

    func testKeyAbsentFromExisting_isNotChanged() {
        // Una key assente è un file NUOVO, non "cambiato" — shouldUpload la caricherà,
        // isChangedExistingKey non deve contarla come cambiata.
        XCTAssertFalse(S3Syncer.isChangedExistingKey(key: "new.jpg", size: 1000, existing: [:]))
    }

    func testKeyPresentWithDifferentSize_isChanged() {
        let existing: [String: Int64] = ["a.jpg": 500]
        XCTAssertTrue(S3Syncer.isChangedExistingKey(key: "a.jpg", size: 1000, existing: existing))
    }

    func testKeyPresentWithSameSize_isNotChanged() {
        let existing: [String: Int64] = ["a.jpg": 1000]
        XCTAssertFalse(S3Syncer.isChangedExistingKey(key: "a.jpg", size: 1000, existing: existing))
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `type 'S3Syncer' has no member 'isChangedExistingKey'`. Se il file di test non compare nei risultati, aggiungilo manualmente al target `AppBackupFotoTests` in `project.pbxproj` (stesso pattern noto).

- [ ] **Step 3: Implementare `isChangedExistingKey` e aggiornare `SyncResult`/`sync()`**

Trova:

```swift
    // BUG-3: una key già presente su S3 non va mai ricaricata, indipendentemente
    // dalla dimensione locale — ricaricare sovrascriverebbe l'oggetto esistente via
    // PUT, violando zero-overwrite. Solo le key davvero assenti vengono caricate.
    static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
        !existingKeys.contains(key)
    }
```

Sostituisci con:

```swift
    // BUG-3: una key già presente su S3 non va mai ricaricata, indipendentemente
    // dalla dimensione locale — ricaricare sovrascriverebbe l'oggetto esistente via
    // PUT, violando zero-overwrite. Solo le key davvero assenti vengono caricate.
    static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
        !existingKeys.contains(key)
    }

    // Conteggio informativo per roadmap #13 (segnalazione, non azione): una key già
    // presente su S3 con dimensione diversa da quella locale. Non influenza in alcun
    // modo shouldUpload/la decisione di caricare.
    static func isChangedExistingKey(key: String, size: Int64, existing: [String: Int64]) -> Bool {
        guard let existingSize = existing[key] else { return false }
        return existingSize != size
    }
```

Trova (in `S3Syncer.SyncResult`):

```swift
    struct SyncResult {
        var uploaded = 0; var skipped = 0; var errors = 0
        var total = 0; var done = 0; var startDate = Date()
        var uploadedBytes: Int64 = 0
        var toUploadCount: Int = 0
```

Sostituisci con:

```swift
    struct SyncResult {
        var uploaded = 0; var skipped = 0; var errors = 0
        var total = 0; var done = 0; var startDate = Date()
        var uploadedBytes: Int64 = 0
        var toUploadCount: Int = 0
        var changedSkipped = 0   // key esistente con dimensione diversa (roadmap #13)
```

Trova (in `sync(from localURL:config:...)`):

```swift
        let existingKeys = Set(existing.keys)
        let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
        result.total = files.count
        result.toUploadCount = toUpload.count
```

Sostituisci con:

```swift
        let existingKeys = Set(existing.keys)
        let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
        result.total = files.count
        result.toUploadCount = toUpload.count
        result.changedSkipped = files.filter {
            S3Syncer.isChangedExistingKey(key: $0.key, size: $0.size, existing: existing)
        }.count
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 3 nuovi di questo task (totale 75: i 72 di Task 1 + 3 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerChangedKeyTests.swift
git commit -m "$(cat <<'EOF'
S3Syncer.SyncResult reports changed-but-skipped keys informationally

New S3Syncer.isChangedExistingKey + SyncResult.changedSkipped, computed
alongside toUpload but purely informational — does not affect which
keys get uploaded (that decision stays with shouldUpload, fixed in
BUG-3). Roadmap #13.
EOF
)"
```

---

### Task 3: Propagazione a `JobStats`/`JobSummary` e `CompletionSheet`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`JobStats` riga 258, `publishProgress` , `runSyncS3()` righe 1615-1662, `stop()`/`run(label:)` righe 1777-1846, `JobSummary` riga 1912, `CompletionSheet` riga 2831 — verificare nel file reale)

**Interfaces:**
- Consumes: `FileSyncer.SyncResult.changedSkipped` (Task 1), `S3Syncer.SyncResult.changedSkipped` (Task 2)
- Produces: `JobStats.changedSkipped: Int`, `JobSummary.changedSkipped: Int` — nessun altro consumer previsto in questo piano

- [ ] **Step 1: Aggiungere `changedSkipped` a `JobStats`**

Trova:

```swift
struct JobStats {
    var percent: Int = 0
    var done: Int = 0
    var total: Int = 0
    var eta: String = "—"
    var elapsed: String = "—"
    var copied: Int = 0
    var skipped: Int = 0
    var errors: Int = 0
    var speed: String = "—"
    var verifiedOk: Int = 0   // file copiati con SHA256 verificato con successo
    var hashErrors: Int = 0   // file con SHA256 mismatch dopo la copia
}
```

Sostituisci con:

```swift
struct JobStats {
    var percent: Int = 0
    var done: Int = 0
    var total: Int = 0
    var eta: String = "—"
    var elapsed: String = "—"
    var copied: Int = 0
    var skipped: Int = 0
    var errors: Int = 0
    var speed: String = "—"
    var verifiedOk: Int = 0   // file copiati con SHA256 verificato con successo
    var hashErrors: Int = 0   // file con SHA256 mismatch dopo la copia
    var changedSkipped: Int = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
}
```

- [ ] **Step 2: `publishProgress` (Mac→SSD/SSD→HDD) propaga il campo**

Trova:

```swift
    private func publishProgress(_ r: FileSyncer.SyncResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stats.percent = r.percent; self.stats.done = r.done; self.stats.total = r.total
            self.stats.copied = r.copied; self.stats.skipped = r.skipped; self.stats.errors = r.errors
            self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
            self.stats.hashErrors = r.hashErrors          // mismatch SHA256 in tempo reale
```

Sostituisci con:

```swift
    private func publishProgress(_ r: FileSyncer.SyncResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stats.percent = r.percent; self.stats.done = r.done; self.stats.total = r.total
            self.stats.copied = r.copied; self.stats.skipped = r.skipped; self.stats.errors = r.errors
            self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
            self.stats.hashErrors = r.hashErrors          // mismatch SHA256 in tempo reale
            self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
```

- [ ] **Step 3: `runSyncS3()` propaga il campo (live e nella conversione finale)**

Trova:

```swift
                    onProgress: { [weak self] snap in
                        guard let self else { return }
                        self.stats.percent = snap.percent
                        self.stats.done = snap.done; self.stats.total = snap.total
                        self.stats.copied = snap.uploaded; self.stats.skipped = snap.skipped
                        self.stats.errors = snap.errors
                        self.stats.elapsed = S3Syncer.SyncResult.hms(snap.elapsedSec)
```

Sostituisci con:

```swift
                    onProgress: { [weak self] snap in
                        guard let self else { return }
                        self.stats.percent = snap.percent
                        self.stats.done = snap.done; self.stats.total = snap.total
                        self.stats.copied = snap.uploaded; self.stats.skipped = snap.skipped
                        self.stats.errors = snap.errors
                        self.stats.changedSkipped = snap.changedSkipped
                        self.stats.elapsed = S3Syncer.SyncResult.hms(snap.elapsedSec)
```

Trova:

```swift
                var fr = FileSyncer.SyncResult()
                fr.copied = r.uploaded; fr.skipped = r.skipped
                fr.errors = r.errors; fr.done = r.done; fr.total = r.total
                return fr
```

Sostituisci con:

```swift
                var fr = FileSyncer.SyncResult()
                fr.copied = r.uploaded; fr.skipped = r.skipped
                fr.errors = r.errors; fr.done = r.done; fr.total = r.total
                fr.changedSkipped = r.changedSkipped
                return fr
```

- [ ] **Step 4: `run(label:)` propaga il campo nel completamento**

Trova:

```swift
                    if let r = result {
                        self.stats.copied = r.copied; self.stats.skipped = r.skipped
                        self.stats.errors = r.errors; self.stats.done = r.done
                        self.stats.total = r.total; self.stats.percent = 100
                        self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
                        self.stats.hashErrors = r.hashErrors          // mismatch SHA256
                        self.stats.verifiedOk = r.copied              // tutti i copied sono verified ok
                    }
```

Sostituisci con:

```swift
                    if let r = result {
                        self.stats.copied = r.copied; self.stats.skipped = r.skipped
                        self.stats.errors = r.errors; self.stats.done = r.done
                        self.stats.total = r.total; self.stats.percent = 100
                        self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
                        self.stats.hashErrors = r.hashErrors          // mismatch SHA256
                        self.stats.verifiedOk = r.copied              // tutti i copied sono verified ok
                        self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
                    }
```

- [ ] **Step 5: `JobSummary` guadagna il campo (con default, nessuna rottura dei call site esistenti nei test)**

Trova:

```swift
struct JobSummary: Codable {
    let date: Date
    let label: String
    let copied: Int
    let skipped: Int
    let errors: Int
    let hashErrors: Int
    let succeeded: Bool

    var isClean: Bool { succeeded && errors == 0 && hashErrors == 0 }
}
```

Sostituisci con:

```swift
struct JobSummary: Codable {
    let date: Date
    let label: String
    let copied: Int
    let skipped: Int
    let errors: Int
    let hashErrors: Int
    let succeeded: Bool
    var changedSkipped: Int = 0   // deve essere "var", non "let": una "let" con valore iniziale viene esclusa sia dal memberwise init (i call site esistenti nei test smetterebbero di compilare) sia dalla decodifica Codable (verrebbe sempre 0, mai letta dal JSON persistito) — comportamento reale di Swift, verificato in questa sessione

    var isClean: Bool { succeeded && errors == 0 && hashErrors == 0 }
}
```

- [ ] **Step 6: I tre call site reali in `BackupRunner` passano il valore vero (non il default)**

Trova (in `stop()`):

```swift
        JobHistoryStore.save(JobSummary(date: Date(), label: jobLabel, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors, hashErrors: stats.hashErrors, succeeded: false))
```

Sostituisci con:

```swift
        JobHistoryStore.save(JobSummary(date: Date(), label: jobLabel, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors, hashErrors: stats.hashErrors,
            succeeded: false, changedSkipped: stats.changedSkipped))
```

Trova (in `run(label:)`, ramo di successo):

```swift
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: true))
```

Sostituisci con:

```swift
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: true,
                        changedSkipped: self.stats.changedSkipped))
```

Trova (in `run(label:)`, ramo di errore):

```swift
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false))
```

Sostituisci con:

```swift
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false,
                        changedSkipped: self.stats.changedSkipped))
```

- [ ] **Step 7: `CompletionSheet` mostra il conteggio**

Trova:

```swift
            if stats.hashErrors > 0 {
                Label("\(stats.hashErrors) hash mismatch — controlla il log",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
```

Sostituisci con:

```swift
            if stats.hashErrors > 0 {
                Label("\(stats.hashErrors) hash mismatch — controlla il log",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if stats.changedSkipped > 0 {
                Label("\(stats.changedSkipped) file locali cambiati, non copiati (regola zero-overwrite)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
```

- [ ] **Step 8: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 9: Eseguire l'intera suite di test per verificare che nulla si sia rotto**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 75 test passano (invariati rispetto a Task 2 — questo task non aggiunge test automatici, solo propagazione dati e UI; i test esistenti di `JobHistoryStoreTests.swift` continuano a passare grazie al default `= 0` su `changedSkipped`).

- [ ] **Step 10: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Surface changed-but-skipped file count in the job completion sheet

Threads changedSkipped through JobStats and JobSummary (both already
carried copied/skipped/errors/hashErrors the same way) for all three
jobs, and shows a count-only line in CompletionSheet when > 0. No file
names, no new log entries, no Revisione panel entry — matches the
"report only, never act" decision from brainstorming. Roadmap #13.
EOF
)"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** campo lungo tutta la catena (`FileSyncer.SyncResult`/`S3Syncer.SyncResult`/`JobStats`/`JobSummary`) → Task 1/2/3; popolamento dove il confronto già avviene (`syncFile`, `isChangedExistingKey`) → Task 1/2; propagazione (`publishProgress`, `runSyncS3`, `run(label:)`, i tre `JobHistoryStore.save`) → Task 3; visualizzazione solo in `CompletionSheet`, solo conteggio → Task 3 Step 7. Fuori scope rispettato: nessuna modifica a `StatsPanel`, nessun elenco nomi, nessuna voce in Revisione, nessun salvataggio di nuove versioni.

**Scan placeholder:** nessuno — ogni step di codice ha contenuto completo, comandi e output attesi.

**Coerenza dei tipi:** `changedSkipped: Int` con lo stesso nome su `FileSyncer.SyncResult` (Task 1), `S3Syncer.SyncResult` (Task 2), `JobStats` e `JobSummary` (Task 3) — stesso nome ovunque, nessuna divergenza terminologica. `S3Syncer.isChangedExistingKey(key:size:existing:)` definito e usato identicamente in Task 2 Step 1 (test) e Step 3 (implementazione).
