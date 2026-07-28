# Review Engine (pannello "Revisione" in-app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere a AppBackupFoto un pannello "Revisione" dentro `ToolsSheet` che mostra controlli di configurazione istantanei, il riepilogo persistito dell'ultimo job eseguito, e un campione di verifica integrità SHA256 su richiesta tra Mac↔SSD, SSD↔HDD e SSD↔S3.

**Architecture:** Tutto il nuovo codice vive in `AppBackupFoto/ContentView.swift` (nessuno split di file). Due funzioni pure oggi private (`isLikelyVolumeRoot`, `sha256(of:)`) vengono estratte a top-level per essere riusate dal nuovo motore e testate direttamente. Un nuovo blocco `ReviewEngine` esegue controlli sincroni di configurazione e un campionamento asincrono di integrità; un `JobHistoryStore` persiste in UserDefaults l'ultimo `JobSummary`, scritto da `BackupRunner` a fine job. `ToolsSheet` chiama questi componenti e mostra i risultati — nessun nuovo sheet, nessuna nuova voce nell'hamburger.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest, `Foundation`/`CryptoKit` per l'hashing, `UserDefaults` per la persistenza, target macOS 13+.

## Global Constraints

- Target macOS 13+, Swift 5.x — coerente con il resto del progetto.
- Tutto il codice nuovo va in `AppBackupFoto/ContentView.swift`; nessuno split in file separati (decisione esplicita dell'utente in fase di brainstorming).
- Nessun controllo automatico in background: tutto on-demand, attivato dall'apertura di `ToolsSheet` (config checks) o dalla pressione del bottone dedicato (campione integrità).
- Il motore di revisione **segnala soltanto** — nessuna `removeItem`/`copyItem`/scrittura S3 verso una destinazione persistente. Gli unici file scritti sono download temporanei per il confronto S3, rimossi subito dopo l'hash.
- Dimensione campione: 20 file per coppia (Mac↔SSD, SSD↔HDD, SSD↔S3), valore di default parametrizzato ma non esposto nella UI in questa iterazione.
- Il riepilogo dell'ultimo job deve sopravvivere al riavvio dell'app (persistito, non solo in-memory).
- Il ramo S3 del campione di integrità non è coperto da test automatici (richiederebbe rete/mock) — resta verificato manualmente prima del rilascio.
- Ogni modifica a operazioni FileManager/S3/bookmark/UI-async deve rispettare la checklist if-then già documentata in `Docs/CLAUDE.md` ("Regola sul ciclo AI di revisione").

---

## Task 1: Estrarre `isLikelyVolumeRoot` in una utility condivisa e testarla

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:105-107` (inserire nuova sezione), `AppBackupFoto/ContentView.swift:1143-1146` (rimuovere il metodo privato)
- Test: `AppBackupFotoTests/IsLikelyVolumeRootTests.swift` (nuovo)

**Interfaces:**
- Produce: `func isLikelyVolumeRoot(_ url: URL) -> Bool` a livello di file (top-level), usata da `BackupRunner` (7 call site già esistenti, invariati) e dal `ReviewEngine` del Task 6.

- [ ] **Step 1: Scrivere il test (fallirà finché la funzione non esiste a livello di file)**

Crea `AppBackupFotoTests/IsLikelyVolumeRootTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class IsLikelyVolumeRootTests: XCTestCase {
    func testVolumeRoot_isTrue() {
        XCTAssertTrue(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri")))
    }

    func testDirectSubfolder_isFalse() {
        XCTAssertFalse(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone")))
    }

    func testDeeplyNestedSubfolder_isFalse() {
        XCTAssertFalse(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone/2024")))
    }

    func testOtherVolumeRoot_isTrue() {
        XCTAssertTrue(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/BackupHDD")))
    }
}
```

- [ ] **Step 2: Eseguire il test e verificare che fallisca**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/IsLikelyVolumeRootTests 2>&1 | tail -30`

Expected: FAIL — `cannot find 'isLikelyVolumeRoot' in scope` (la funzione oggi è `private` dentro `BackupRunner`, non visibile a livello di file).

- [ ] **Step 3: Estrarre la funzione a livello di file**

In `AppBackupFoto/ContentView.swift`, tra la fine dell'enum `JobPhase` (riga 105, `}`) e `// MARK: - BookmarkManager` (riga 107), inserisci:

```swift

// MARK: - Shared utilities

func isLikelyVolumeRoot(_ url: URL) -> Bool {
    // /Volumes/VolumeName ha esattamente 3 componenti: ["/", "Volumes", "Name"]
    url.pathComponents.count <= 3
}
```

Poi, dentro `final class BackupRunner` (verso la fine, prima di `private func alert`), **rimuovi** il metodo ora duplicato:

```swift
    private func isLikelyVolumeRoot(_ url: URL) -> Bool {
        // /Volumes/VolumeName ha esattamente 3 componenti: ["/", "Volumes", "Name"]
        url.pathComponents.count <= 3
    }

```

Non serve modificare nessuno dei 7 call site in `BackupRunner` (`if !isLikelyVolumeRoot(ssdURL)` ecc.): erano già chiamate non qualificate, continuano a risolvere sulla nuova funzione top-level.

- [ ] **Step 4: Eseguire il test e verificare che passi**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/IsLikelyVolumeRootTests 2>&1 | tail -30`

Expected: PASS — 4 test eseguiti, 0 falliti.

- [ ] **Step 5: Eseguire l'intera suite di test esistente per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -20`

Expected: PASS — inclusi i 5 test già esistenti di `FileSyncerZeroOverwriteTests`.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/IsLikelyVolumeRootTests.swift
git commit -m "Extract isLikelyVolumeRoot into shared top-level utility"
```

---

## Task 2: Estrarre `sha256(of:)` in una utility condivisa

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:107` (nuova sezione "Shared utilities", stessa introdotta nel Task 1), `AppBackupFoto/ContentView.swift:388-398` (rimuovere il metodo privato di `FileSyncer`)

**Interfaces:**
- Produce: `func sha256(of url: URL) -> String?` a livello di file, usata da `FileSyncer.syncFile` (già chiamata non qualificata, nessuna modifica al call site) e dal `ReviewEngine` del Task 4/5.

- [ ] **Step 1: Spostare la funzione nella sezione "Shared utilities"**

In `AppBackupFoto/ContentView.swift`, nella sezione `// MARK: - Shared utilities` creata nel Task 1, aggiungi sotto `isLikelyVolumeRoot`:

```swift

func sha256(of url: URL) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { fh.closeFile() }
    var hasher = SHA256()
    var chunk = fh.readData(ofLength: 65536)
    while !chunk.isEmpty {
        hasher.update(data: chunk)
        chunk = fh.readData(ofLength: 65536)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
```

Poi, dentro `final class FileSyncer`, **rimuovi** il metodo ora duplicato:

```swift
    private func sha256(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        var hasher = SHA256()
        var chunk = fh.readData(ofLength: 65536)
        while !chunk.isEmpty {
            hasher.update(data: chunk)
            chunk = fh.readData(ofLength: 65536)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

```

Il call site in `syncFile` (`if let srcHash = sha256(of: src), let dstHash = sha256(of: dst), srcHash != dstHash {`) resta invariato: era già una chiamata non qualificata.

- [ ] **Step 2: Eseguire l'intera suite di test per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -20`

Expected: PASS — i 5 test di `FileSyncerZeroOverwriteTests` esercitano `syncFile`/`sha256(of:)` indirettamente tramite `sync(from:to:deep:...)` e devono continuare a passare invariati.

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Extract sha256(of:) into shared top-level utility"
```

---

## Task 3: `JobSummary` + `JobHistoryStore` con persistenza testabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1153-1155` (inserire il nuovo blocco tra la fine di `BackupRunner` e `// MARK: - SetupView`)
- Test: `AppBackupFotoTests/JobHistoryStoreTests.swift` (nuovo)

**Interfaces:**
- Produce:
  - `struct JobSummary: Codable` con campi `date: Date`, `label: String`, `copied: Int`, `skipped: Int`, `errors: Int`, `hashErrors: Int`, `succeeded: Bool`, e proprietà calcolata `isClean: Bool`.
  - `enum JobHistoryStore` con `static func save(_ summary: JobSummary, defaults: UserDefaults = .standard)` e `static func load(defaults: UserDefaults = .standard) -> JobSummary?`.
- Consumato da: Task 7 (`BackupRunner`) e Task 8 (`ToolsSheet`).

- [ ] **Step 1: Scrivere i test (falliranno finché i tipi non esistono)**

Crea `AppBackupFotoTests/JobHistoryStoreTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class JobHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "JobHistoryStoreTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testLoad_withNoSavedData_returnsNil() {
        XCTAssertNil(JobHistoryStore.load(defaults: defaults))
    }

    func testSaveThenLoad_roundTripsAllFields() {
        let summary = JobSummary(date: Date(timeIntervalSince1970: 1_700_000_000),
                                  label: "MAC -> SSD", copied: 42, skipped: 3,
                                  errors: 1, hashErrors: 0, succeeded: true)
        JobHistoryStore.save(summary, defaults: defaults)
        let loaded = JobHistoryStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.date, summary.date)
        XCTAssertEqual(loaded?.label, "MAC -> SSD")
        XCTAssertEqual(loaded?.copied, 42)
        XCTAssertEqual(loaded?.skipped, 3)
        XCTAssertEqual(loaded?.errors, 1)
        XCTAssertEqual(loaded?.hashErrors, 0)
        XCTAssertEqual(loaded?.succeeded, true)
    }

    func testIsClean_falseWhenErrorsPresent() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 1, hashErrors: 0, succeeded: true)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_falseWhenNotSucceeded() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 0, hashErrors: 0, succeeded: false)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_trueWhenSucceededWithoutErrors() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 2,
                                  errors: 0, hashErrors: 0, succeeded: true)
        XCTAssertTrue(summary.isClean)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/JobHistoryStoreTests 2>&1 | tail -30`

Expected: FAIL — `cannot find 'JobSummary' in scope` / `cannot find 'JobHistoryStore' in scope`.

- [ ] **Step 3: Implementare `JobSummary` e `JobHistoryStore`**

In `AppBackupFoto/ContentView.swift`, subito dopo la chiusura di `final class BackupRunner` (riga 1153, `}`) e prima di `// MARK: - SetupView` (riga 1155), inserisci:

```swift

// MARK: - Review Engine

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

enum JobHistoryStore {
    private static let key = "lastJobSummary"

    static func save(_ summary: JobSummary, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> JobSummary? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(JobSummary.self, from: data)
    }
}
```

- [ ] **Step 4: Eseguire i test e verificare che passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/JobHistoryStoreTests 2>&1 | tail -30`

Expected: PASS — 5 test eseguiti, 0 falliti.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/JobHistoryStoreTests.swift
git commit -m "Add JobSummary and JobHistoryStore with injectable UserDefaults"
```

---

## Task 4: `ReviewFinding`, `IntegrityCheckResult`, `ReviewEngine` con campionamento locale testabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (subito dopo il blocco `JobHistoryStore` aggiunto nel Task 3)
- Test: `AppBackupFotoTests/ReviewEngineIntegritySampleTests.swift` (nuovo)

**Interfaces:**
- Consuma: `func sha256(of url: URL) -> String?` (Task 2).
- Produce:
  - `struct ReviewFinding: Identifiable` con `id: UUID`, `title: String`, `ok: Bool`, `detail: String`.
  - `struct IntegrityCheckResult: Identifiable` con `id: UUID`, `pairName: String`, `checked: Int = 0`, `matched: Int = 0`, `mismatches: [String] = []`, `skippedNoSource: Int = 0`, `error: String? = nil`.
  - `final class ReviewEngine` con metodo `func sampleLocalPair(srcRoot: URL, dstRoot: URL, pairName: String, sampleSize: Int) -> IntegrityCheckResult` (accesso `internal`, non `private`, per essere testabile via `@testable import`).
- Consumato da: Task 5 (`sampleS3Pair`/`runIntegritySample` nello stesso `ReviewEngine`), Task 6 (`runConfigChecks`), Task 8 (`ToolsSheet`).

- [ ] **Step 1: Scrivere i test (falliranno finché i tipi non esistono)**

Crea `AppBackupFotoTests/ReviewEngineIntegritySampleTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class ReviewEngineIntegritySampleTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ReviewEngineTests-\(UUID().uuidString)", isDirectory: true)
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

    func testIdenticalFiles_areMatched() throws {
        let data = Data("hello world".utf8)
        try data.write(to: srcDir.appendingPathComponent("a.jpg"))
        try data.write(to: dstDir.appendingPathComponent("a.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
        XCTAssertNil(result.error)
    }

    func testAlteredDestinationFile_isReportedAsMismatch() throws {
        try Data("original".utf8).write(to: srcDir.appendingPathComponent("b.jpg"))
        try Data("corrupted".utf8).write(to: dstDir.appendingPathComponent("b.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.mismatches, ["b.jpg"])
    }

    func testDestinationFileMissingFromSource_isSkippedNotMismatch() throws {
        try Data("only-on-dest".utf8).write(to: dstDir.appendingPathComponent("c.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.skippedNoSource, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
    }

    func testEmptyDestination_returnsZeroedResultWithoutError() throws {
        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.matched, 0)
        XCTAssertNil(result.error)
    }

    func testNestedSubdirectory_relativePathIsPreserved() throws {
        try fm.createDirectory(at: srcDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        let data = Data("nested".utf8)
        try data.write(to: srcDir.appendingPathComponent("2024/d.jpg"))
        try data.write(to: dstDir.appendingPathComponent("2024/d.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/ReviewEngineIntegritySampleTests 2>&1 | tail -30`

Expected: FAIL — `cannot find 'ReviewEngine' in scope`.

- [ ] **Step 3: Implementare `ReviewFinding`, `IntegrityCheckResult` e `ReviewEngine.sampleLocalPair`**

Subito dopo il blocco `JobHistoryStore` (Task 3), nella stessa sezione `// MARK: - Review Engine`, aggiungi:

```swift

struct ReviewFinding: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
    let detail: String
}

struct IntegrityCheckResult: Identifiable {
    let id = UUID()
    let pairName: String
    var checked: Int = 0
    var matched: Int = 0
    var mismatches: [String] = []
    var skippedNoSource: Int = 0
    var error: String? = nil
}

final class ReviewEngine {
    private let bm = BookmarkManager.shared
    private let s3Syncer = S3Syncer()
    private let fm = FileManager.default

    func sampleLocalPair(srcRoot: URL, dstRoot: URL, pairName: String, sampleSize: Int) -> IntegrityCheckResult {
        var result = IntegrityCheckResult(pairName: pairName)
        guard let enumerator = fm.enumerator(
            at: dstRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            result.error = "Impossibile enumerare \(dstRoot.path)"
            return result
        }

        var relPaths: [String] = []
        let base = dstRoot.path
        while let f = enumerator.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            relPaths.append(String(f.path.dropFirst(base.count).drop(while: { $0 == "/" })))
        }
        guard !relPaths.isEmpty else { return result }

        let sample = relPaths.shuffled().prefix(sampleSize)
        for rel in sample {
            let dstFile = dstRoot.appendingPathComponent(rel)
            let srcFile = srcRoot.appendingPathComponent(rel)
            guard fm.fileExists(atPath: srcFile.path) else {
                result.skippedNoSource += 1
                continue
            }
            result.checked += 1
            if let srcHash = sha256(of: srcFile), let dstHash = sha256(of: dstFile), srcHash == dstHash {
                result.matched += 1
            } else {
                result.mismatches.append(rel)
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Eseguire i test e verificare che passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/ReviewEngineIntegritySampleTests 2>&1 | tail -30`

Expected: PASS — 5 test eseguiti, 0 falliti.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ReviewEngineIntegritySampleTests.swift
git commit -m "Add ReviewEngine with tested local-pair integrity sampling"
```

---

## Task 5: Estendere `S3Syncer` con il download di verifica e collegare il campione SSD↔S3

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:547` (rendere `listAll` non-private), `AppBackupFoto/ContentView.swift:687-689` (aggiungere `downloadToTemp`), blocco `ReviewEngine` del Task 4 (aggiungere `sampleS3Pair` e `runIntegritySample`)

**Interfaces:**
- Consuma: `S3Syncer.readConfig() -> S3Config` (esistente, invariato), `S3Syncer().listAll(config:) async throws -> [String: Int64]` (reso non-private in questo task), `func sha256(of url: URL) -> String?` (Task 2), `ReviewEngine.sampleLocalPair(...)` (Task 4).
- Produce:
  - `S3Syncer.downloadToTemp(key: String, config: S3Config) async throws -> URL`.
  - `ReviewEngine.runIntegritySample(sampleSize: Int = 20, onProgress: @escaping (String) -> Void) async -> [IntegrityCheckResult]` — entry point usato da Task 8 (`ToolsSheet`).

Nessun test automatico in questo task (richiederebbe rete reale verso Cubbit S3): la verifica è manuale, vedi Step 4.

- [ ] **Step 1: Rendere `listAll` accessibile da `ReviewEngine` e aggiungere `downloadToTemp`**

In `AppBackupFoto/ContentView.swift`, dentro `final class S3Syncer`, cambia la riga 547 da:

```swift
    private func listAll(config: S3Config) async throws -> [String: Int64] {
```

a:

```swift
    func listAll(config: S3Config) async throws -> [String: Int64] {
```

Poi, tra la fine di `private func multipart(...)` (riga 687, `}`) e `// MARK: - AWS Signature V4` (riga 689), inserisci:

```swift

    func downloadToTemp(key: String, config: S3Config) async throws -> URL {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let getURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: getURL)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (tempURL, resp) = try await session.download(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            throw NSError(domain: "S3", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Errore GET \(key)"])
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
```

- [ ] **Step 2: Aggiungere `sampleS3Pair` e `runIntegritySample` a `ReviewEngine`**

Dentro `final class ReviewEngine` (Task 4), subito dopo `sampleLocalPair`, aggiungi:

```swift

    private func sampleS3Pair(ssdRoot: URL, sampleSize: Int,
                               onProgress: @escaping (String) -> Void) async throws -> IntegrityCheckResult {
        var result = IntegrityCheckResult(pairName: "SSD ↔ S3")
        let config = try S3Syncer.readConfig()
        let remoteKeys = try await s3Syncer.listAll(config: config)
        let candidates = remoteKeys.keys.filter { fm.fileExists(atPath: ssdRoot.appendingPathComponent($0).path) }
        guard !candidates.isEmpty else { return result }

        let sample = candidates.shuffled().prefix(sampleSize)
        for key in sample {
            onProgress("Verifica S3: \(key)")
            let localFile = ssdRoot.appendingPathComponent(key)
            guard let localHash = sha256(of: localFile) else { result.skippedNoSource += 1; continue }
            result.checked += 1
            do {
                let tempURL = try await s3Syncer.downloadToTemp(key: key, config: config)
                defer { try? fm.removeItem(at: tempURL) }
                if let remoteHash = sha256(of: tempURL), remoteHash == localHash {
                    result.matched += 1
                } else {
                    result.mismatches.append(key)
                }
            } catch {
                result.mismatches.append("\(key) (errore download: \(error.localizedDescription))")
            }
        }
        return result
    }

    func runIntegritySample(sampleSize: Int = 20,
                             onProgress: @escaping (String) -> Void) async -> [IntegrityCheckResult] {
        var results: [IntegrityCheckResult] = []

        let photosURL = bm.startAccessing(.photos)
        let ssdURL = bm.startAccessing(.ssd)
        let hddURL = bm.startAccessing(.hdd)
        defer {
            if photosURL != nil { bm.stopAccessing(.photos) }
            if ssdURL != nil { bm.stopAccessing(.ssd) }
            if hddURL != nil { bm.stopAccessing(.hdd) }
        }

        onProgress("Campionamento Mac ↔ SSD…")
        if let photosURL, let ssdURL {
            results.append(sampleLocalPair(srcRoot: photosURL,
                                            dstRoot: ssdURL.appendingPathComponent("Foto iPhone"),
                                            pairName: "Mac ↔ SSD", sampleSize: sampleSize))
        } else {
            var r = IntegrityCheckResult(pairName: "Mac ↔ SSD")
            r.error = "Bookmark Foto o SSD non accessibile"
            results.append(r)
        }

        onProgress("Campionamento SSD ↔ HDD…")
        if let ssdURL, let hddURL {
            results.append(sampleLocalPair(srcRoot: ssdURL, dstRoot: hddURL,
                                            pairName: "SSD ↔ HDD", sampleSize: sampleSize))
        } else {
            var r = IntegrityCheckResult(pairName: "SSD ↔ HDD")
            r.error = "Bookmark SSD o HDD non accessibile"
            results.append(r)
        }

        onProgress("Campionamento SSD ↔ S3…")
        if let ssdURL {
            do {
                results.append(try await sampleS3Pair(ssdRoot: ssdURL, sampleSize: sampleSize, onProgress: onProgress))
            } catch {
                var r = IntegrityCheckResult(pairName: "SSD ↔ S3")
                r.error = error.localizedDescription
                results.append(r)
            }
        } else {
            var r = IntegrityCheckResult(pairName: "SSD ↔ S3")
            r.error = "Bookmark SSD non accessibile"
            results.append(r)
        }

        return results
    }
```

- [ ] **Step 3: Build (nessun nuovo test automatico in questo task)**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verifica manuale (annotare l'esito, non automatizzabile in CI)**

Con SSD montato, bookmark configurati e `rclone.conf` valido, istanziare `ReviewEngine()` e chiamare `await engine.runIntegritySample(onProgress: { print($0) })` da un punto di test manuale (es. temporaneamente da un bottone di debug o dal Task 8 una volta cablato in UI) e confermare che: il ramo Mac↔SSD e SSD↔HDD trovino match reali sui file esistenti, il ramo SSD↔S3 scarichi ed elimini correttamente i file temporanei (verificare con `ls /private/var/folders/.../T/` che non restino file orfani dopo l'esecuzione).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Wire S3 sample verification into ReviewEngine.runIntegritySample"
```

---

## Task 6: `ReviewEngine.runConfigChecks()` — controlli di configurazione sincroni

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `final class ReviewEngine`, blocco Task 4/5)

**Interfaces:**
- Consuma: `BookmarkManager.shared.urls[Location]` (esistente), `isLikelyVolumeRoot(_:)` (Task 1), `S3Syncer.readConfig()` (esistente).
- Produce: `ReviewEngine.runConfigChecks() -> [ReviewFinding]`, usato da Task 8 (`ToolsSheet`).

Nessun test automatico dedicato per questo task (non richiesto dallo spec): la logica di root-validity è già coperta da `IsLikelyVolumeRootTests` (Task 1); `runConfigChecks()` è un semplice assemblaggio di quella logica più letture di file di configurazione, verificato con build + smoke test manuale nello Step 3.

- [ ] **Step 1: Implementare i controlli**

Dentro `final class ReviewEngine`, subito dopo `runIntegritySample` (Task 5), aggiungi:

```swift

    func runConfigChecks() -> [ReviewFinding] {
        checkBookmarkRoots() + [checkRcloneConfPermissions(), checkS3Endpoint()]
    }

    private func checkBookmarkRoots() -> [ReviewFinding] {
        [BookmarkManager.Location.ssd, .hdd].compactMap { loc -> ReviewFinding? in
            guard let url = bm.urls[loc] else { return nil }
            let ok = isLikelyVolumeRoot(url)
            let name = loc == .ssd ? "SSD" : "HDD"
            return ReviewFinding(
                title: "Bookmark \(name)", ok: ok,
                detail: ok
                    ? "Punta alla root del volume (\(url.path))"
                    : "Punta a una sottocartella (\(url.path)), non alla root del volume")
        }
    }

    private func checkRcloneConfPermissions() -> ReviewFinding {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "File non trovato in ~/.config/rclone/rclone.conf")
        }
        let perms = attrs[.posixPermissions] as? Int ?? 0
        if perms & 0o077 != 0 {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "Permessi troppo aperti (\(String(perms, radix: 8))) — esegui: chmod 600 ~/.config/rclone/rclone.conf")
        }
        return ReviewFinding(title: "Permessi rclone.conf", ok: true,
            detail: "0600 — solo il proprietario può leggere/scrivere")
    }

    private func checkS3Endpoint() -> ReviewFinding {
        do {
            let cfg = try S3Syncer.readConfig()
            return ReviewFinding(title: "Endpoint S3", ok: true, detail: "\(cfg.endpoint) · bucket \(cfg.bucket)")
        } catch {
            return ReviewFinding(title: "Endpoint S3", ok: false, detail: error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Eseguire l'intera suite di test per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -20`

Expected: PASS — tutti i test esistenti + quelli aggiunti nei Task 1/3/4.

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add ReviewEngine.runConfigChecks for bookmark, rclone and S3 endpoint validation"
```

---

## Task 7: Persistere `JobSummary` a fine job in `BackupRunner`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1037-1086` (`run(label:work:)`), `AppBackupFoto/ContentView.swift` (`stop()`, subito dopo `syncTask?.cancel(); syncTask = nil`)

**Interfaces:**
- Consuma: `JobSummary` e `JobHistoryStore.save(_:)` (Task 3).

Nessun nuovo test automatico: `BackupRunner` non ha oggi una suite di test (richiederebbe simulare bookmark reali); la verifica è manuale via smoke test nello Step 3, coerente con come il resto di `BackupRunner` è già verificato nel progetto.

- [ ] **Step 1: Salvare il riepilogo nel ramo di successo e in quello di errore di `run(label:work:)`**

In `AppBackupFoto/ContentView.swift`, dentro `private func run(label: String, work: ...)`, cambia:

```swift
                    self.phase = .success("Completato: \(label)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.stats.elapsed = self.makeElapsed()
                    self.phase = .failed("Errore: \(error.localizedDescription)")
                    self.completionSnapshot = (self.phase, self.stats)
                }
            }
```

in:

```swift
                    self.phase = .success("Completato: \(label)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: true))
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.stats.elapsed = self.makeElapsed()
                    self.phase = .failed("Errore: \(error.localizedDescription)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false))
                }
            }
```

- [ ] **Step 2: Salvare il riepilogo anche quando l'utente interrompe il job manualmente**

Cambia `func stop()` da:

```swift
    func stop() {
        wasStopped = true
        elapsedTimer?.cancel(); elapsedTimer = nil
        syncer.cancel()
        s3Syncer.cancel()
        syncTask?.cancel(); syncTask = nil
        phase = .failed("Interrotto dall'utente")
        completionSnapshot = (phase, stats)
    }
```

a:

```swift
    func stop() {
        wasStopped = true
        let jobLabel = phase.label   // etichetta del job in corso, catturata prima di sovrascrivere phase
        elapsedTimer?.cancel(); elapsedTimer = nil
        syncer.cancel()
        s3Syncer.cancel()
        syncTask?.cancel(); syncTask = nil
        phase = .failed("Interrotto dall'utente")
        completionSnapshot = (phase, stats)
        JobHistoryStore.save(JobSummary(date: Date(), label: jobLabel, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors, hashErrors: stats.hashErrors, succeeded: false))
    }
```

- [ ] **Step 3: Build + smoke test manuale**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

Poi, avviare l'app (`Cmd+R` da Xcode), lanciare un job breve (es. MAC → SSD se non ci sono file da copiare, così finisce subito), e verificare da un breakpoint o da un print temporaneo che `JobHistoryStore.load()` restituisca il riepilogo appena salvato. Rimuovere eventuali print/breakpoint di debug prima del commit.

- [ ] **Step 4: Eseguire l'intera suite di test per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -20`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Persist JobSummary after every job completion, failure or manual stop"
```

---

## Task 8: UI — sezione "Revisione" in `ToolsSheet`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1974-1980` (dentro `struct ToolsSheet`, tra `GroupBox("Sync Info")` e il bottone "Chiudi")

**Interfaces:**
- Consuma: `ReviewEngine().runConfigChecks() -> [ReviewFinding]` (Task 6), `ReviewEngine().runIntegritySample(sampleSize:onProgress:) async -> [IntegrityCheckResult]` (Task 5), `JobHistoryStore.load() -> JobSummary?` (Task 3).

Nessun test automatico per la UI (coerente con il resto del progetto, che non ha UI test): verifica tramite build + avvio manuale dell'app, come da Step 3.

- [ ] **Step 1: Aggiungere lo stato e la nuova `GroupBox` a `ToolsSheet`**

In `AppBackupFoto/ContentView.swift`, dentro `struct ToolsSheet: View`, subito dopo:

```swift
    @State private var showSecret = false
```

aggiungi:

```swift
    @State private var reviewFindings: [ReviewFinding] = []
    @State private var lastJob: JobSummary? = JobHistoryStore.load()
    @State private var integrityResults: [IntegrityCheckResult] = []
    @State private var integrityRunning = false
    @State private var integrityStatus = ""
    private let reviewEngine = ReviewEngine()

    private let jobDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()
```

Poi, subito dopo la chiusura di `GroupBox("Sync Info") { ... }` (riga 1979, `}`) e prima di `HStack { Spacer(); Button("Chiudi") ... }`, inserisci:

```swift

            GroupBox("Revisione") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reviewFindings) { finding in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: finding.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.ok ? Color.green : Color.orange)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.title).font(.caption).fontWeight(.medium)
                                Text(finding.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    if let lastJob {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: lastJob.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(lastJob.isClean ? Color.green : Color.orange)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Ultimo job: \(lastJob.label)").font(.caption).fontWeight(.medium)
                                Text("\(jobDateFormatter.string(from: lastJob.date)) · Copiati \(lastJob.copied) · Skippati \(lastJob.skipped) · Errori \(lastJob.errors) · Hash-mismatch \(lastJob.hashErrors)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Nessun job registrato").font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    Button(integrityRunning ? "Verifica in corso…" : "Verifica integrità campione (20 file per coppia)") {
                        integrityRunning = true
                        integrityResults = []
                        integrityStatus = ""
                        Task {
                            let results = await reviewEngine.runIntegritySample(onProgress: { status in
                                Task { @MainActor in integrityStatus = status }
                            })
                            await MainActor.run {
                                integrityResults = results
                                integrityRunning = false
                            }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(integrityRunning)

                    if integrityRunning {
                        Text(integrityStatus).font(.caption2).foregroundStyle(.secondary)
                    }

                    ForEach(integrityResults) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            if let error = result.error {
                                Text("\(result.pairName): saltato — \(error)")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else if result.mismatches.isEmpty {
                                Text("\(result.pairName): \(result.matched)/\(result.checked) verificati, 0 problemi")
                                    .font(.caption2).foregroundStyle(.green)
                            } else {
                                Text("\(result.pairName): \(result.mismatches.count) mismatch su \(result.checked) verificati — \(result.mismatches.prefix(3).joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }.padding(4)
            }
            .onAppear { reviewFindings = reviewEngine.runConfigChecks() }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verifica manuale in app**

Avviare l'app (`Cmd+R`), aprire hamburger → Tools, scorrere fino alla nuova sezione "Revisione": confermare che compaiano i check di configurazione (con ✅ se i bookmark sono configurati correttamente), il riepilogo dell'ultimo job (o "Nessun job registrato" alla primissima esecuzione), e che premendo "Verifica integrità campione" il bottone si disabiliti, mostri lo stato di avanzamento e infine i risultati per le tre coppie senza bloccare il resto della UI.

- [ ] **Step 4: Eseguire l'intera suite di test per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -20`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Revisione section to ToolsSheet: config checks, last job summary, integrity sample"
```

---

## Task 9: Aggiornare `Docs/CLAUDE.md` e verifica finale

**Files:**
- Modify: `Docs/CLAUDE.md` (tabella "Stato attuale" e sezione "Obiettivi futuri")

**Interfaces:** Nessuna — solo documentazione.

- [ ] **Step 1: Aggiornare la tabella "Stato attuale"**

In `Docs/CLAUDE.md`, aggiungi una riga alla tabella "Stato attuale":

```markdown
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256 |
```

- [ ] **Step 2: Aggiornare "Obiettivi futuri"**

Sostituisci:

```markdown
1. Agente AI di revisione codice integrato nell'app (ciclo if-then che scopre bug a runtime) — unico obiettivo della lista storica non ancora affrontato
2. Valutare se serve un meccanismo di notifica/alert se il deep mirror SSD→HDD non gira da troppo tempo (es. oltre 45 giorni) per segnalare che l'HDD non viene collegato abbastanza spesso
```

con:

```markdown
1. Valutare se serve un meccanismo di notifica/alert se il deep mirror SSD→HDD non gira da troppo tempo (es. oltre 45 giorni) per segnalare che l'HDD non viene collegato abbastanza spesso
```

Aggiungi anche una breve voce all'architettura, nella sezione `## Architettura Swift`, se presente, oppure una nuova sottosezione "ReviewEngine" descrivendo brevemente cosa fa (config checks + campione integrità) e dove vive (`ContentView.swift`, blocco `// MARK: - Review Engine`) — coerente con lo stile delle altre sottosezioni già presenti (`BookmarkManager`, `FileSyncer`, ecc.).

- [ ] **Step 3: Build + suite di test completa**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -30`

Expected: `** BUILD SUCCEEDED **` e tutti i test (5 preesistenti + quelli aggiunti nei Task 1/3/4) verdi.

- [ ] **Step 4: Commit**

```bash
git add Docs/CLAUDE.md
git commit -m "Update Docs/CLAUDE.md: review engine panel shipped"
```
