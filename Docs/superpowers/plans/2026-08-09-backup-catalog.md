# Catalogo backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un pannello "Catalogo" (nuova finestra indipendente) per sfogliare e cercare per nome/cartella cosa è già stato backuppato su SSD, HDD o Cubbit S3, in sola lettura.

**Architecture:** Un nuovo struct condiviso `CatalogEntry` (nome, cartella relativa, dimensione, data) alimentato da due sorgenti dati indipendenti: `S3Syncer.listAllWithDates(config:)` (nuovo, non tocca `listAll`/`listPage` esistenti) per Cubbit, e `ReviewEngine.scanLocalCatalog(rootURL:)` (nuovo) per SSD/HDD. Una funzione pura `filterCatalogEntries(_:matching:)` applica la ricerca in memoria. `CatalogView`, una nuova `Window` scene indipendente (stesso pattern di Diagnostica), mostra un Picker per la destinazione, un campo di ricerca e una `Table` con i risultati.

**Tech Stack:** Swift 5.x, SwiftUI (`Table`, `Window` scene — macOS 13+, target reale 15.6), XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Zero delete, zero overwrite, read-only sulla sorgente — il catalogo è puramente di lettura: nessuna azione di cancellazione/modifica su nessun elemento elencato, in nessun task di questo piano.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Non modificare `S3Syncer.listAll`/`listPage` esistenti né i loro chiamanti (`previewUpload`, `sampleS3Pair`, restore, orphaned-uploads) — il catalogo usa funzioni nuove e separate.
- Credenziali S3: il catalogo usa `runner.s3Config` (cache condivisa già esistente, `BackupRunner.loadS3ConfigIfNeeded()`) — nessuna nuova lettura Keychain indipendente, e la lettura va sempre innescata dalla finestra principale prima di aprire la finestra Catalogo (lezione da BUG-2: un'autorizzazione Keychain interattiva innescata da dentro una `Window` scene indipendente va in loop).
- Verifica manuale (non eseguibile in headless, la fa l'utente dopo): apertura Catalogo, cambio destinazione nel Picker, tempi di caricamento su Cubbit (120k oggetti), ricerca di un file noto, destinazioni non disponibili mostrate come tali.

---

### Task 1: `CatalogEntry` + lettura S3 con date (`S3Syncer.listAllWithDates`)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo struct `CatalogEntry` prima di `final class ReviewEngine`, riga indicativa 1743 — verificare nel file reale; nuovi metodi in `final class S3Syncer`, dopo `listPage`, riga indicativa 855-885)
- Create: `AppBackupFotoTests/S3SyncerCatalogParsingTests.swift`

**Interfaces:**
- Consumes: `S3Syncer.sign`, `S3Syncer.session`, `S3Syncer.xmlAll`/`xmlFirst` (metodi privati esistenti, usati solo internamente a `listPageWithDates`, non dai test)
- Produces: `struct CatalogEntry: Identifiable { let id: UUID; let name: String; let relativePath: String; let sizeBytes: Int64; let modified: Date? }`; `S3Syncer.parseCatalogEntries(fromListObjectsXML:) -> [CatalogEntry]` (non privato, usato dai test e da `listPageWithDates`); `S3Syncer.listAllWithDates(config:) async throws -> [CatalogEntry]` — Task 4 lo userà per popolare il catalogo quando la destinazione è Cubbit

- [ ] **Step 1: Scrivere il test file con i casi di parsing XML (fallirà: la funzione non esiste ancora)**

Crea `AppBackupFotoTests/S3SyncerCatalogParsingTests.swift`:

```swift
//
//  S3SyncerCatalogParsingTests.swift
//  AppBackupFotoTests
//
//  Verifica S3Syncer.parseCatalogEntries su frammenti XML di ListObjectsV2 —
//  funzione pura, nessuna chiamata di rete.
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerCatalogParsingTests: XCTestCase {

    func testEmptyXML_returnsEmptyArray() {
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: "<ListBucketResult></ListBucketResult>")
        XCTAssertTrue(entries.isEmpty)
    }

    func testSingleEntry_parsesNameRelativePathSizeAndDate() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>Foto iPhone/2024/IMG_001.jpg</Key>
                <LastModified>2024-03-15T10:30:00.000Z</LastModified>
                <ETag>"abc123"</ETag>
                <Size>2048576</Size>
                <StorageClass>STANDARD</StorageClass>
            </Contents>
            <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "IMG_001.jpg")
        XCTAssertEqual(entries[0].relativePath, "Foto iPhone/2024/IMG_001.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 2_048_576)
        XCTAssertNotNil(entries[0].modified)
        if let modified = entries[0].modified {
            let comps = Calendar(identifier: .gregorian).dateComponents(
                in: TimeZone(identifier: "UTC")!, from: modified)
            XCTAssertEqual(comps.year, 2024); XCTAssertEqual(comps.month, 3); XCTAssertEqual(comps.day, 15)
        }
    }

    func testMultipleEntries_parsedInDocumentOrder() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>Foto iPhone/2024/IMG_001.jpg</Key>
                <LastModified>2024-03-15T10:30:00.000Z</LastModified>
                <Size>1000</Size>
            </Contents>
            <Contents>
                <Key>Foto iPhone/2024/IMG_002.jpg</Key>
                <LastModified>2024-03-16T11:00:00.000Z</LastModified>
                <Size>2000</Size>
            </Contents>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "IMG_001.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 1000)
        XCTAssertEqual(entries[1].name, "IMG_002.jpg")
        XCTAssertEqual(entries[1].sizeBytes, 2000)
    }

    func testKeyWithNoSubfolder_relativePathEqualsName() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>root-file.jpg</Key>
                <LastModified>2024-01-01T00:00:00.000Z</LastModified>
                <Size>500</Size>
            </Contents>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "root-file.jpg")
        XCTAssertEqual(entries[0].relativePath, "root-file.jpg")
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `value of type 'S3Syncer' has no member 'parseCatalogEntries'`. Se il file di test non compare nei risultati, verifica che sia stato aggiunto al target `AppBackupFotoTests` (Xcode di solito lo fa automaticamente per i file in `AppBackupFotoTests/`; se il target usa un `PBXGroup` esplicito invece di un gruppo file-system-synchronized, potrebbe servire aggiungerlo a mano al `project.pbxproj` — pattern già visto in una sessione precedente di questo stesso piano di lavoro).

- [ ] **Step 3: Aggiungere `CatalogEntry` e implementare `parseCatalogEntries`/`listPageWithDates`/`listAllWithDates`**

Trova (prima di `final class ReviewEngine`):

```swift
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
```

Sostituisci con:

```swift
struct IntegrityCheckResult: Identifiable {
    let id = UUID()
    let pairName: String
    var checked: Int = 0
    var matched: Int = 0
    var mismatches: [String] = []
    var skippedNoSource: Int = 0
    var error: String? = nil
}

// Voce del catalogo backup (roadmap #12) — alimentata sia da ReviewEngine.scanLocalCatalog
// (SSD/HDD) sia da S3Syncer.listAllWithDates (Cubbit), sola lettura, nessuna azione associata.
struct CatalogEntry: Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let sizeBytes: Int64
    let modified: Date?
}

// Filtro di ricerca puro sul catalogo (nome o cartella, case-insensitive) — nessuna dipendenza
// da rete o disco, applicato in memoria sui CatalogEntry già caricati.
func filterCatalogEntries(_ entries: [CatalogEntry], matching query: String) -> [CatalogEntry] {
    guard !query.isEmpty else { return entries }
    let q = query.lowercased()
    return entries.filter { $0.name.lowercased().contains(q) || $0.relativePath.lowercased().contains(q) }
}

final class ReviewEngine {
```

Trova (nella classe `S3Syncer`, subito dopo `listPage`):

```swift
    private func listPage(config: S3Config, token: String?) async throws -> ([String: Int64], String?) {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        comps.queryItems = qi
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista S3: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let keys = xmlAll(xml, tag: "Key")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        var objs: [String: Int64] = [:]
        for (k, s) in zip(keys, sizes) { objs[k] = s }
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (objs, nextToken)
    }
```

Lascialo invariato, e aggiungi subito dopo (stesso livello di indentazione, dentro `final class S3Syncer`):

```swift

    // Come listPage, ma per il Catalogo (roadmap #12): estrae anche LastModified, non solo
    // Key/Size. Funzione separata per non toccare listPage/listAll esistenti, usati da
    // preview/restore/orphaned-uploads.
    func parseCatalogEntries(fromListObjectsXML xml: String) -> [CatalogEntry] {
        let keys = xmlAll(xml, tag: "Key")
        let dates = xmlAll(xml, tag: "LastModified")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let count = min(keys.count, dates.count, sizes.count)
        var entries: [CatalogEntry] = []
        for i in 0..<count {
            let key = keys[i]
            entries.append(CatalogEntry(
                name: (key as NSString).lastPathComponent,
                relativePath: key,
                sizeBytes: sizes[i],
                modified: fmt.date(from: dates[i])))
        }
        return entries
    }

    private func listPageWithDates(config: S3Config, token: String?) async throws -> ([CatalogEntry], String?) {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        comps.queryItems = qi
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista S3: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let entries = parseCatalogEntries(fromListObjectsXML: xml)
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (entries, nextToken)
    }

    func listAllWithDates(config: S3Config) async throws -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        var token: String? = nil
        repeat {
            if cancelled || Task.isCancelled { break }
            let (page, next) = try await listPageWithDates(config: config, token: token)
            entries.append(contentsOf: page)
            token = next
        } while token != nil
        return entries
    }
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 4 nuovi di questo task (totale 58: i 54 esistenti + 4 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerCatalogParsingTests.swift
git commit -m "$(cat <<'EOF'
Add CatalogEntry and S3Syncer.listAllWithDates for the backup catalog

New, separate from listAll/listPage (used by preview/restore/orphaned
uploads) — parses LastModified in addition to Key/Size, needed to show
dates in the catalog browser (roadmap #12).
EOF
)"
```

---

### Task 2: Scansione locale del catalogo (`ReviewEngine.scanLocalCatalog`)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo metodo in `final class ReviewEngine`, dopo `sampleLocalPair`, riga indicativa 1794 — verificare nel file reale)
- Create: `AppBackupFotoTests/ReviewEngineCatalogScanTests.swift`

**Interfaces:**
- Consumes: `CatalogEntry` (prodotto da Task 1); `ReviewEngine.realResolvedPath(_:)` (metodo privato esistente, usato internamente)
- Produces: `ReviewEngine.scanLocalCatalog(rootURL: URL) -> [CatalogEntry]` — Task 4 lo userà per popolare il catalogo quando la destinazione è SSD o HDD

- [ ] **Step 1: Scrivere il test file (fallirà: il metodo non esiste ancora)**

Crea `AppBackupFotoTests/ReviewEngineCatalogScanTests.swift`:

```swift
//
//  ReviewEngineCatalogScanTests.swift
//  AppBackupFotoTests
//
//  Verifica ReviewEngine.scanLocalCatalog su directory temporanee reali (nessun mock).
//

import XCTest
@testable import AppBackupFoto

final class ReviewEngineCatalogScanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ReviewEngineCatalogScanTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ relativePath: String, byteCount: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    func testTopLevelFile_appearsWithCorrectNameAndSize() throws {
        try writeFile("a.jpg", byteCount: 1000)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "a.jpg")
        XCTAssertEqual(entries[0].relativePath, "a.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 1000)
        XCTAssertNotNil(entries[0].modified)
    }

    func testNestedSubdirectory_relativePathIncludesSubfolder() throws {
        try writeFile("2024/b.jpg", byteCount: 2000)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "b.jpg")
        XCTAssertEqual(entries[0].relativePath, "2024/b.jpg")
    }

    func testExcludedSystemFiles_areSkipped() throws {
        try writeFile("a.jpg", byteCount: 1000)
        try writeFile(".DS_Store", byteCount: 10)
        try writeFile("._a.jpg", byteCount: 10)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "a.jpg")
    }

    func testEmptyDirectory_returnsEmptyArray() {
        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)
        XCTAssertTrue(entries.isEmpty)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `value of type 'ReviewEngine' has no member 'scanLocalCatalog'`.

- [ ] **Step 3: Implementare `scanLocalCatalog`**

Trova (in `final class ReviewEngine`, subito dopo la chiusura di `sampleLocalPair`):

```swift
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

    private func sampleS3Pair(ssdRoot: URL, sampleSize: Int,
```

Sostituisci con (aggiunta di `scanLocalCatalog` tra la chiusura di `sampleLocalPair` e l'inizio di `sampleS3Pair`):

```swift
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

    // Catalogo backup (roadmap #12): elenca tutti i file sotto rootURL con nome/cartella
    // relativa/dimensione/data. Sola lettura — nessuna azione, nessuna modifica. Stessa
    // esclusione di file di sistema già usata da FileSyncer.
    func scanLocalCatalog(rootURL: URL) -> [CatalogEntry] {
        let excluded: Set<String> = [
            ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
            ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb"
        ]
        let resolvedRoot = URL(fileURLWithPath: realResolvedPath(rootURL), isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [CatalogEntry] = []
        let base = resolvedRoot.path
        while let f = enumerator.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if excluded.contains(name) || name.hasPrefix("._") { continue }
            let relativePath = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            entries.append(CatalogEntry(
                name: name,
                relativePath: relativePath,
                sizeBytes: Int64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate))
        }
        return entries
    }

    private func sampleS3Pair(ssdRoot: URL, sampleSize: Int,
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 4 nuovi di questo task (totale 62: i 58 di Task 1 + 4 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ReviewEngineCatalogScanTests.swift
git commit -m "$(cat <<'EOF'
Add ReviewEngine.scanLocalCatalog for local (SSD/HDD) backup catalog

Recursive enumeration producing CatalogEntry (name/relative path/size/
date), same exclusion list as FileSyncer. Read-only, roadmap #12.
EOF
)"
```

---

### Task 3: Filtro di ricerca (`filterCatalogEntries`)

**Files:**
- Test: `AppBackupFotoTests/FilterCatalogEntriesTests.swift`

**Interfaces:**
- Consumes: `CatalogEntry` (prodotto da Task 1); `filterCatalogEntries(_:matching:)` (già implementato in Task 1 — questo task lo copre di test, nessuna nuova implementazione)
- Produces: nessuno — Task 4 userà `filterCatalogEntries` direttamente in `CatalogView`

Nota: `filterCatalogEntries` è già stato scritto in Task 1 (necessario lì per completare il file sorgente in un colpo solo). Questo task aggiunge solo la copertura di test dedicata — non modificare `ContentView.swift`.

- [ ] **Step 1: Scrivere i test (già passano, essendo `filterCatalogEntries` già implementato — verifica comunque l'intera suite)**

Crea `AppBackupFotoTests/FilterCatalogEntriesTests.swift`:

```swift
//
//  FilterCatalogEntriesTests.swift
//  AppBackupFotoTests
//
//  Verifica filterCatalogEntries: filtro puro per nome/cartella, case-insensitive.
//

import XCTest
@testable import AppBackupFoto

final class FilterCatalogEntriesTests: XCTestCase {
    private func entry(name: String, path: String) -> CatalogEntry {
        CatalogEntry(name: name, relativePath: path, sizeBytes: 100, modified: nil)
    }

    func testEmptyQuery_returnsAllEntries() {
        let entries = [entry(name: "a.jpg", path: "2024/a.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        XCTAssertEqual(filterCatalogEntries(entries, matching: "").count, 2)
    }

    func testMatchByName_isCaseInsensitive() {
        let entries = [entry(name: "IMG_001.jpg", path: "2024/IMG_001.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        let result = filterCatalogEntries(entries, matching: "img_001")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "IMG_001.jpg")
    }

    func testMatchByFolderPath_notJustFileName() {
        let entries = [entry(name: "a.jpg", path: "Takeout/2019/a.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        let result = filterCatalogEntries(entries, matching: "takeout")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "a.jpg")
    }

    func testNoMatch_returnsEmptyArray() {
        let entries = [entry(name: "a.jpg", path: "2024/a.jpg")]
        XCTAssertTrue(filterCatalogEntries(entries, matching: "zzz").isEmpty)
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che passino (già implementato in Task 1)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 4 nuovi di questo task (totale 66: i 62 di Task 2 + 4 nuovi).

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFotoTests/FilterCatalogEntriesTests.swift
git commit -m "Add test coverage for filterCatalogEntries search filter"
```

---

### Task 4: `CatalogView` (finestra indipendente) e apertura da `HamburgerPanel`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuova scene `Window("Catalogo", id: "catalog")` in `BackupFotoEnricoApp`, righe indicative 9-36 — verificare nel file reale; nuova struct `CatalogView`, subito dopo `RootView`; nuova `HamburgerRow` in `HamburgerPanel`, righe indicative 2796-2818)

**Interfaces:**
- Consumes: `CatalogEntry`, `filterCatalogEntries(_:matching:)`, `S3Syncer.listAllWithDates(config:)` (Task 1); `ReviewEngine.scanLocalCatalog(rootURL:)` (Task 2); `BackupRunner.s3Config`/`loadS3ConfigIfNeeded()` (esistenti, dalla sessione precedente su BUG-2); `BookmarkManager.shared.startAccessing(_:)`/`stopAccessing(_:)`, `VolumeMonitor.ssdMounted`/`hddMounted` (esistenti)
- Produces: `CatalogView: View` — nessun altro consumer previsto in questo piano

- [ ] **Step 1: Aggiungere la scene `Window("Catalogo", id: "catalog")`**

Trova (in `BackupFotoEnricoApp`):

```swift
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)

        MenuBarExtra {
```

Sostituisci con:

```swift
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)

        Window("Catalogo", id: "catalog") {
            CatalogView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)

        MenuBarExtra {
```

- [ ] **Step 2: Aggiungere `CatalogView`**

Trova:

```swift
struct RootView: View {
```

Inserisci subito prima (nuova struct, top-level):

```swift
struct CatalogView: View {
    enum CatalogDestination: String, CaseIterable, Identifiable {
        case ssd = "SSD", hdd = "HDD", s3 = "Cubbit S3"
        var id: String { rawValue }
    }
    enum LoadState {
        case idle, loading, loaded([CatalogEntry]), failed(String)
    }

    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    @StateObject private var volumes = VolumeMonitor()
    @State private var destination: CatalogDestination = .ssd
    @State private var searchText = ""
    @State private var loadState: LoadState = .idle
    private let reviewEngine = ReviewEngine()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private func isAvailable(_ d: CatalogDestination) -> Bool {
        switch d {
        case .ssd: return volumes.ssdMounted
        case .hdd: return volumes.hddMounted
        case .s3: return runner.s3Config != nil
        }
    }

    private var filteredEntries: [CatalogEntry] {
        guard case .loaded(let entries) = loadState else { return [] }
        return filterCatalogEntries(entries, matching: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Catalogo").font(.title2).fontWeight(.semibold)

            Picker("Destinazione", selection: $destination) {
                ForEach(CatalogDestination.allCases) { d in
                    Text(isAvailable(d) ? d.rawValue : "\(d.rawValue) (non disponibile)").tag(d)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: destination) { _, _ in loadCurrentDestination() }

            TextField("Cerca per nome o cartella", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Group {
                switch loadState {
                case .idle:
                    Color.clear.onAppear { loadCurrentDestination() }
                case .loading:
                    ProgressView("Sto leggendo \(destination.rawValue)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    if filteredEntries.isEmpty {
                        Text(searchText.isEmpty ? "Nessun file trovato" : "Nessun risultato per \"\(searchText)\"")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(filteredEntries) {
                            TableColumn("Nome") { Text($0.name) }
                            TableColumn("Cartella") { Text($0.relativePath) }
                            TableColumn("Dimensione") { entry in
                                Text(byteFormatter.string(fromByteCount: entry.sizeBytes))
                            }
                            TableColumn("Data") { entry in
                                Text(entry.modified.map { dateFormatter.string(from: $0) } ?? "—")
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }

    private func loadCurrentDestination() {
        guard isAvailable(destination) else {
            loadState = .failed("\(destination.rawValue) non disponibile al momento")
            return
        }
        loadState = .loading
        let dest = destination
        Task {
            do {
                let entries: [CatalogEntry]
                switch dest {
                case .ssd:
                    guard let url = bm.startAccessing(.ssd) else {
                        throw NSError(domain: "Catalog", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Accesso all'SSD non disponibile"])
                    }
                    defer { bm.stopAccessing(.ssd) }
                    entries = reviewEngine.scanLocalCatalog(rootURL: url)
                case .hdd:
                    guard let url = bm.startAccessing(.hdd) else {
                        throw NSError(domain: "Catalog", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Accesso all'HDD non disponibile"])
                    }
                    defer { bm.stopAccessing(.hdd) }
                    entries = reviewEngine.scanLocalCatalog(rootURL: url)
                case .s3:
                    guard let cfg = runner.s3Config else {
                        throw NSError(domain: "Catalog", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Configurazione Cubbit non disponibile"])
                    }
                    entries = try await S3Syncer().listAllWithDates(config: cfg)
                }
                await MainActor.run {
                    guard dest == destination else { return }
                    loadState = .loaded(entries)
                }
            } catch {
                await MainActor.run {
                    guard dest == destination else { return }
                    loadState = .failed(error.localizedDescription)
                }
            }
        }
    }
}

struct RootView: View {
```

- [ ] **Step 3: Aggiungere la voce "Catalogo" in `HamburgerPanel`**

Trova (in `HamburgerPanel`, subito dopo il bottone "Tools"):

```swift
                        HamburgerSectionLabel("Preferenze").padding(.top, 6)
```

Sostituisci con:

```swift
                        HamburgerRow(icon: "magnifyingglass", label: "Catalogo", iconColor: .indigo) {
                            Task {
                                await runner.loadS3ConfigIfNeeded()
                                await MainActor.run { openWindow(id: "catalog") }
                            }
                        }

                        HamburgerSectionLabel("Preferenze").padding(.top, 6)
```

- [ ] **Step 4: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Eseguire l'intera suite di test per verificare che nulla si sia rotto**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 66 test passano (invariati rispetto a Task 3 — questo task non aggiunge test automatici, solo UI).

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add Catalogo window: browse/search backed-up files on SSD/HDD/Cubbit

New independent Window scene (movable/resizable, same pattern as
Diagnostica), opened from HamburgerPanel. Segmented picker for
destination (disabled if unavailable), live search over name/folder,
read-only table of results. S3 credentials come from the already-loaded
BackupRunner.s3Config, triggered from the main window before opening
the catalog window (BUG-2 lesson: Keychain prompts must not originate
from inside an independent Window scene).
EOF
)"
```

---

### Task 5: Aggiornare la documentazione del progetto

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:**
- Consumes: nessuna (solo modifiche testuali)
- Produces: nessuna

- [ ] **Step 1: Aggiornare `Docs/CLAUDE.md`**

Nella sezione `## UI (SwiftUI views in ContentView.swift)`, dopo la riga che descrive `MenuBarExtra`, aggiungi:

```
- **CatalogView (2026-08-09)** — finestra indipendente "Catalogo" (`Window`, stesso pattern di Diagnostica), aperta da hamburger → Catalogo: Picker per la destinazione (SSD/HDD/Cubbit S3, disattivata se non disponibile), ricerca live per nome/cartella su dati scansionati dal vivo a ogni apertura (nessun indice persistito). SSD/HDD via `ReviewEngine.scanLocalCatalog`, Cubbit via il nuovo `S3Syncer.listAllWithDates` (separato da `listAll`/`listPage`, non li tocca). Sola lettura, nessuna azione sugli elementi elencati. Credenziali S3 dalla cache condivisa `runner.s3Config`, caricata dalla finestra principale prima di aprire la finestra Catalogo.
```

- [ ] **Step 2: Aggiornare `Docs/ROADMAP.md`**

Trova il punto 12 nella sezione `## Valore aggiunto — da "buona" a "da mercato" (9)`:

```
12. **Nessun catalogo/ricerca di cosa è già backuppato** — oggi serve Tools o rclone a mano; un browser dei backup (data/cartella/nome) alzerebbe la fiducia senza toccare la logica di sync.
```

Sostituisci con:

```
12. ✅ **Fatto (2026-08-09) — Nessun catalogo/ricerca di cosa è già backuppato.** Nuova finestra "Catalogo" (SSD/HDD/Cubbit S3), ricerca per nome/cartella, scansione dal vivo a ogni apertura, sola lettura. Vedi `Docs/superpowers/specs/2026-08-09-backup-catalog-design.md`.
```

Nella sezione `## Da dove partire (aggiornato 2026-08-02)`, aggiungi `#12 catalogo backup` all'elenco dei punti "Fatti".

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: backup catalog shipped"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** ambito (tutte e tre le destinazioni) → Task 4 (`CatalogDestination`); scansione dal vivo senza indice → Task 1/2 (chiamate dirette a ogni apertura, nessuna persistenza); presentazione come Window indipendente → Task 4 Step 1; sola lettura → nessun task aggiunge azioni di modifica/cancellazione; credenziali S3 dalla cache condivisa → Task 4 usa `runner.s3Config`/`loadS3ConfigIfNeeded()`, mai una lettura Keychain diretta nella finestra Catalogo. `parseCatalogEntries` isolata da `listAll`/`listPage` esistenti → Task 1, verificato che nessun chiamante esistente sia toccato.

**Scan placeholder:** nessuno — ogni step di codice ha contenuto completo, comandi e output attesi.

**Coerenza dei tipi:** `CatalogEntry` (Task 1) usato identicamente in `ReviewEngine.scanLocalCatalog` (Task 2), `filterCatalogEntries` (Task 1/3) e `CatalogView` (Task 4). `S3Syncer.listAllWithDates(config:) async throws -> [CatalogEntry]` (Task 1) e `ReviewEngine.scanLocalCatalog(rootURL: URL) -> [CatalogEntry]` (Task 2) hanno la stessa forma di ritorno, usati simmetricamente in `CatalogView.loadCurrentDestination()` (Task 4).
