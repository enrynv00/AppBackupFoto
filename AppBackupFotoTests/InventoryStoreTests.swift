import XCTest
import SQLite3
@testable import AppBackupFoto

/// Le tabelle dell'inventario nello stesso file dell'elenco (ROADMAP #44, ADR-0015): lotti,
/// giri, completezza per archivio, e il passaggio dalla versione 1 dello schema.
final class InventoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func local(_ path: String, sha: String = "S", size: Int64 = 10,
                       status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: size, mtime: 1_700_000_000,
                           status: status,
                           digest: status == .ok ? ContentDigest(size: size, sha256: sha, md5: "m-" + sha, multipartETag: nil) : nil,
                           hashedAt: 1_700_003_600)
    }

    private func object(_ key: String, size: Int64 = 10, etag: String? = "\"e\"") -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: etag)
    }

    private func finish(_ a: InventoryArchive, _ run: Int64, complete: Bool,
                        reason: InventoryIncompleteReason? = nil) throws {
        try store.finishInventoryArchive(a, runId: run, complete: complete, reason: reason,
                                         unreadable: 0, finishedAt: 2_000)
    }

    private func external(_ url: URL, _ sql: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return XCTFail("connessione esterna non aperta")
        }
        defer { sqlite3_close_v2(handle) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("SQL esterno fallito: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    private func userVersion(_ url: URL) -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close_v2(handle) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    // MARK: - Giri e completezza

    func testNewStore_hasNoInventory() throws {
        XCTAssertTrue(try store.inventoryStates().isEmpty)
        XCTAssertEqual(try store.inventorySnapshot(), InventorySnapshot())
    }

    /// Un giro aperto e mai chiuso (l'app chiusa a meta') non deve mai leggersi come completo.
    func testBeginRun_marksEveryArchiveIncomplete() throws {
        try store.beginInventoryRun(runId: 7, startedAt: 1_000)
        let states = try store.inventoryStates()
        XCTAssertEqual(Set(states.keys), [.ssd, .hdd, .s3])
        for a in InventoryArchive.allCases {
            XCTAssertEqual(states[a]?.complete, false)
            XCTAssertEqual(states[a]?.reason, .running)
            XCTAssertEqual(states[a]?.runId, 7)
            XCTAssertNil(states[a]?.finishedAt)
        }
    }

    func testLocalRows_roundTrip_throughTheSnapshot() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        let big = InventoryLocalFile(key: "asus/elba/file0056.mov", displayPath: "ASUS/Elba/FILE0056.MOV",
                                     size: 67_108_865, mtime: 1.5, status: .ok,
                                     digest: ContentDigest(size: 67_108_865, sha256: "S", md5: "M",
                                                           multipartETag: "96aa53ed4132d7e2986467263954caad-2"),
                                     hashedAt: 2.5)
        try store.upsertInventoryLocal([local("Foto/a.jpg"), big], archive: .ssd, runId: 1)
        try finish(.ssd, 1, complete: true)
        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.ssd, [big, local("Foto/a.jpg")], "in ordine di chiave, valori identici")
        XCTAssertTrue(snap.hdd.isEmpty)
        XCTAssertTrue(snap.isComplete(.ssd))
        XCTAssertFalse(snap.isComplete(.hdd))
    }

    func testUnreadableRow_roundTripsWithoutDigest() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/rotto.jpg", status: .unreadable)], archive: .hdd, runId: 1)
        let row = try XCTUnwrap(store.inventorySnapshot().hdd.first)
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Conta come presente solo cio' che e' stato visto nel giro registrato: una riga di un giro
    /// vecchio e' solo memoria per non rileggere, mai una prova che il file c'e' ancora.
    func testSnapshot_readsOnlyTheRecordedRun() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/vecchia.jpg")], archive: .ssd, runId: 1)
        try finish(.ssd, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 10)
        try store.upsertInventoryLocal([local("Foto/nuova.jpg")], archive: .ssd, runId: 2)
        try finish(.ssd, 2, complete: false, reason: .interrupted)

        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.ssd.map(\.displayPath), ["Foto/nuova.jpg"])
        XCTAssertEqual(try store.inventoryLocalRows(.ssd).count, 2,
                       "giro incompleto: la riga vecchia resta come memoria")
    }

    func testCompleteFinish_deletesRowsNotSeenInThisRun() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/a.jpg"), local("Foto/b.jpg")], archive: .ssd, runId: 1)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .hdd, runId: 1)
        try finish(.ssd, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 10)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 2)
        try finish(.ssd, 2, complete: true)

        XCTAssertEqual(Set(try store.inventoryLocalRows(.ssd).keys), ["foto/a.jpg"])
        XCTAssertEqual(try store.inventoryLocalRows(.hdd).count, 1, "l'HDD non si tocca chiudendo l'SSD")
    }

    func testIncompleteFinish_recordsTheReason() throws {
        try store.beginInventoryRun(runId: 3, startedAt: 0)
        try store.finishInventoryArchive(.hdd, runId: 3, complete: false, reason: .filesUnreadable,
                                         unreadable: 4, finishedAt: 9)
        let state = try XCTUnwrap(store.inventoryStates()[.hdd])
        XCTAssertFalse(state.complete)
        XCTAssertEqual(state.reason, .filesUnreadable)
        XCTAssertEqual(state.unreadable, 4)
        XCTAssertEqual(state.finishedAt, 9)
    }

    /// Chiudere un archivio con un `runId` che non e' quello aperto non deve toccare niente:
    /// e' un giro vecchio arrivato tardi.
    func testFinishWithAnotherRunId_changesNothing() throws {
        try store.beginInventoryRun(runId: 5, startedAt: 0)
        try store.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 5)
        try store.finishInventoryArchive(.ssd, runId: 4, complete: true, reason: nil, unreadable: 0, finishedAt: 1)
        XCTAssertEqual(try store.inventoryStates()[.ssd]?.complete, false)
        XCTAssertEqual(try store.inventoryLocalRows(.ssd).count, 1, "le righe del giro aperto non si toccano")
    }

    // MARK: - Cubbit

    /// Su Cubbit maiuscole e minuscole contano: due oggetti che differiscono solo per quello
    /// restano due righe.
    func testS3Objects_differingOnlyByCase_areBothKept() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("Foto/IMG.JPG"), object("Foto/img.jpg")], runId: 1)
        try finish(.s3, 1, complete: true)
        let snap = try store.inventorySnapshot()
        XCTAssertEqual(snap.s3.map(\.displayKey), ["Foto/IMG.JPG", "Foto/img.jpg"])
        XCTAssertEqual(Set(snap.s3.map(\.key)), ["foto/img.jpg"])
    }

    func testS3_missingETag_roundTripsAsNil() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg", etag: nil)], runId: 1)
        XCTAssertNil(try store.inventorySnapshot().s3.first?.etag)
    }

    func testS3_completeFinish_deletesObjectsNotListedAgain() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg"), object("b.jpg")], runId: 1)
        try finish(.s3, 1, complete: true)
        try store.beginInventoryRun(runId: 2, startedAt: 0)
        try store.upsertInventoryS3([object("b.jpg")], runId: 2)
        try finish(.s3, 2, complete: true)
        XCTAssertEqual(try store.inventorySnapshot().s3.map(\.displayKey), ["b.jpg"])
    }

    // MARK: - Schema (ADR-0002, ADR-0015)

    func testSchemaVersion_isTwo() {
        XCTAssertEqual(LibraryIndexStore.schemaVersion, 2)
        XCTAssertEqual(LibraryIndexStore.upgradableFromVersion, 1)
    }

    /// Il passaggio che conta per Enrico: l'elenco da 141.683 voci NON si butta aggiornando
    /// l'app. La versione 1 ha `entries` identica: si tiene, e l'inventario nasce vuoto.
    func testVersion1Database_keepsTheListAndGainsAnEmptyInventory() throws {
        let url = tempDir.appendingPathComponent("v1.sqlite")
        external(url, """
        CREATE TABLE entries (path TEXT PRIMARY KEY NOT NULL, display_path TEXT NOT NULL, size INTEGER NOT NULL,
                              mtime REAL NOT NULL, hash TEXT NOT NULL, hashed_at REAL NOT NULL);
        CREATE INDEX idx_entries_hash ON entries(hash);
        CREATE INDEX idx_entries_size ON entries(size);
        INSERT INTO entries VALUES ('foto/a.jpg','Foto/a.jpg',10,1.0,'H',2.0);
        PRAGMA user_version=1;
        """)
        let s = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s.count(), 1, "l'elenco resta")
        XCTAssertEqual(try s.entry(forKey: "foto/a.jpg")?.hash, "H")
        XCTAssertTrue(try s.inventoryStates().isEmpty)
        XCTAssertEqual(userVersion(url), 2)
    }

    /// Una build vecchia riaperta su un file nuovo riporta la versione a 1 e lascia le tabelle
    /// dell'inventario orfane: al ritorno sulla build nuova si buttano, non si adottano.
    func testVersion1WithLeftoverInventory_discardsTheInventoryOnly() throws {
        let url = tempDir.appendingPathComponent("ritorno.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.upsert([LibraryIndexEntry(path: "foto/a.jpg", displayPath: "Foto/a.jpg", size: 10, mtime: 1, hash: "H", hashedAt: 2)])
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
            try s1.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 1)
        }
        external(url, "PRAGMA user_version=1;")

        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.count(), 1)
        XCTAssertTrue(try s2.inventoryStates().isEmpty)
        XCTAssertTrue(try s2.inventoryLocalRows(.ssd).isEmpty)
    }

    func testUnknownVersion_rebuildsEverything_inventoryIncluded() throws {
        let url = tempDir.appendingPathComponent("futuro.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.upsert([LibraryIndexEntry(path: "foto/a.jpg", displayPath: "Foto/a.jpg", size: 10, mtime: 1, hash: "H", hashedAt: 2)])
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
        }
        external(url, "PRAGMA user_version=999;")

        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.count(), 0)
        XCTAssertTrue(try s2.inventoryStates().isEmpty)
    }

    func testReopenAtTheCurrentVersion_keepsTheInventory() throws {
        let url = tempDir.appendingPathComponent("stesso.sqlite")
        do {
            let s1 = try LibraryIndexStore(url: url)
            try s1.beginInventoryRun(runId: 1, startedAt: 0)
            try s1.upsertInventoryLocal([local("Foto/a.jpg")], archive: .ssd, runId: 1)
        }
        let s2 = try LibraryIndexStore(url: url)
        XCTAssertEqual(try s2.inventoryLocalRows(.ssd).count, 1)
    }

    /// «Svuota l'elenco» cancella il file: con l'elenco se ne va anche l'inventario.
    func testDeleteIndexAndRecreate_emptiesTheInventoryToo() throws {
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        try store.upsertInventoryS3([object("a.jpg")], runId: 1)
        try store.deleteIndexAndRecreate()
        XCTAssertTrue(try store.inventoryStates().isEmpty)
        XCTAssertEqual(try store.inventorySnapshot(), InventorySnapshot())
    }

    // MARK: - Righe scritte da fuori

    /// Una riga "ok" senza impronte e' una riga rotta: si legge come illeggibile, cosi' il giro
    /// dopo la rilegge invece di fidarsi.
    func testOkRowWithoutDigest_readsAsUnreadable() throws {
        let url = tempDir.appendingPathComponent("riga.sqlite")
        let s = try LibraryIndexStore(url: url)
        try s.beginInventoryRun(runId: 1, startedAt: 0)
        external(url, """
        INSERT INTO inventory_local VALUES ('ssd','foto/a.jpg','Foto/a.jpg',10,1.0,'ok',NULL,NULL,NULL,2.0,1);
        """)
        let row = try XCTUnwrap(s.inventoryLocalRows(.ssd)["foto/a.jpg"])
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Un motivo che questa versione non conosce, o un "completo" senza data di fine, non
    /// rendono completo un archivio.
    func testUnknownReasonOrMissingEnd_neverReadsAsComplete() throws {
        let url = tempDir.appendingPathComponent("stato.sqlite")
        let s = try LibraryIndexStore(url: url)
        external(url, """
        INSERT INTO inventory_state VALUES ('ssd',1,0,'boh',0,0.0,5.0);
        INSERT INTO inventory_state VALUES ('hdd',1,1,NULL,0,0.0,NULL);
        """)
        let states = try s.inventoryStates()
        XCTAssertEqual(states[.ssd]?.complete, false)
        XCTAssertEqual(states[.ssd]?.reason, .interrupted)
        XCTAssertEqual(states[.hdd]?.complete, false)
    }
}
