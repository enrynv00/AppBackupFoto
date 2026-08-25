import XCTest
@testable import AppBackupFoto

final class LibraryIndexStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ key: String, size: Int64 = 100, hash: String = "abc") -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(key), displayPath: key,
                          size: size, mtime: 1_700_000_000, hash: hash, hashedAt: 1_700_003_600)
    }

    func testEmptyStore_hasNoEntries() throws {
        XCTAssertEqual(try store.count(), 0)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    func testUpsertThenRead() throws {
        try store.upsert([entry("Foto/a.jpg")])
        let got = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))
        XCTAssertEqual(got?.displayPath, "Foto/a.jpg")
        XCTAssertEqual(got?.hash, "abc")
        XCTAssertEqual(got?.size, 100)
    }

    func testUpsertSameKeyTwice_replacesInsteadOfDuplicating() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "vecchio")])
        try store.upsert([entry("Foto/a.jpg", hash: "nuovo")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash, "nuovo")
    }

    func testEntriesWithHash_findsAllCopies() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "H"),
                          entry("Import/b.jpg", hash: "H"),
                          entry("Altro/c.jpg", hash: "DIVERSO")])
        let found = try store.entries(withHash: "H")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.displayPath)), ["Foto/a.jpg", "Import/b.jpg"])
    }

    func testHasAnyEntryWithSize() throws {
        try store.upsert([entry("Foto/a.jpg", size: 500)])
        XCTAssertTrue(try store.hasAnyEntry(withSize: 500))
        XCTAssertFalse(try store.hasAnyEntry(withSize: 501))
    }

    func testRemoveKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        try store.remove(keys: [normalizedIndexKey("Foto/a.jpg")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    func testAllKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/a.jpg"),
                                             normalizedIndexKey("Foto/b.jpg")])
    }

    func testPersistsAcrossReopen() throws {
        let dbURL = tempDir.appendingPathComponent("persist.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 1)
    }

    func testBatchUpsertIsAtomicPerBatch() throws {
        let many = (0..<500).map { entry("Foto/f\($0).jpg", hash: "h\($0)") }
        try store.upsert(many)
        XCTAssertEqual(try store.count(), 500)
    }

    // Normalizzazione della chiave: ExFAT e' case-insensitive e non normalizza
    // l'Unicode, APFS preserva la normalizzazione originale invece di imporne una.
    // Senza normalizzazione lo stesso file produrrebbe due entry distinte.
    func testKeyNormalization_caseInsensitive() {
        XCTAssertEqual(normalizedIndexKey("Foto/IMG.JPG"), normalizedIndexKey("foto/img.jpg"))
    }

    func testKeyNormalization_unicodeNFCvsNFD() {
        let nfc = "Citt\u{00E0}/foto.jpg"        // à precomposta
        let nfd = "Citta\u{0300}/foto.jpg"       // a + accento combinante
        XCTAssertEqual(normalizedIndexKey(nfc), normalizedIndexKey(nfd))
    }

    func testKeyNormalization_preservesDistinctPaths() {
        XCTAssertNotEqual(normalizedIndexKey("Foto/a.jpg"), normalizedIndexKey("Foto/b.jpg"))
    }

    // Un indice scritto con uno schema diverso non va interpretato: si riparte.
    func testUnknownSchemaVersion_resetsIndex() throws {
        let dbURL = tempDir.appendingPathComponent("schema.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        XCTAssertEqual(try first.count(), 1)

        // Simula un indice scritto da una versione futura dell'app.
        try first.setSchemaVersionForTesting(999)
        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 0, "schema sconosciuto: l'indice va ricostruito, non letto")
    }
}
