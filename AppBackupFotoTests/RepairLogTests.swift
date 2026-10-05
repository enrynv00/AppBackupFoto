import XCTest
@testable import AppBackupFoto

/// Il registro delle riparazioni (ROADMAP #45): `repair-log.json` sul Mac, stesso schema e
/// stessa disciplina di `TrashManifestStore` — scritto prima di tornare, `0600`, mai su un
/// archivio, retrocompatibile.
final class RepairLogTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RepairLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var url: URL { tmp.appendingPathComponent("repair-log.json") }

    private func record(_ id: String, outcome: RepairOutcomeKind = .inProgress) -> RepairRecord {
        RepairRecord(repairId: id, key: "foto/a.heic", displayPath: "Foto/a.heic", target: "s3", source: "ssd",
                     witness: "hdd", goodSHA256: "sha-a", goodSize: 10, badSize: 10, badETag: "\"bbb\"",
                     startedAt: Date(timeIntervalSince1970: 1_791_115_200), outcome: outcome)
    }

    func testRecord_isOnDiskBeforeReturning() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        let reread = try RepairLogStore(url: url)
        XCTAssertEqual(reread.records(), [record("r1")])
        XCTAssertEqual(reread.totalRecorded, 1)
    }

    /// La stessa riparazione passa da «in corso» al suo esito: una voce sola.
    func testSameRepair_isUpdatedInPlace() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        var done = record("r1", outcome: .repaired)
        done.afterETag = "\"b59917c9c6e38fccab5ce3f30c90d13a\""
        done.quarantinePath = "_quarantena/2026-10-04/Foto/a.heic"
        try store.record(done)
        try store.record(record("r2"))
        let reread = try RepairLogStore(url: url)
        XCTAssertEqual(reread.records().map(\.repairId), ["r1", "r2"])
        XCTAssertEqual(reread.records().first, done)
        XCTAssertEqual(reread.totalRecorded, 2)
    }

    func testPruning_keepsTheNewest_andTheTrueTotal() throws {
        let store = try RepairLogStore(url: url, maxItems: 3)
        for i in 0..<5 { try store.record(record("r\(i)")) }
        XCTAssertEqual(store.records().map(\.repairId), ["r2", "r3", "r4"], "si potano le piu' vecchie")
        XCTAssertEqual(store.totalRecorded, 5)
        XCTAssertEqual(RepairLogStore.defaultMaxItems, 2000)
    }

    /// Contiene i percorsi delle foto: leggibile solo dall'utente.
    func testFile_isPrivate() throws {
        let store = try RepairLogStore(url: url)
        try store.record(record("r1"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    /// Mai su un archivio: stessa allow-list dell'elenco e del registro dei Doppioni.
    func testLocationOutsideTheAllowList_isRefused() {
        XCTAssertThrowsError(try RepairLogStore(url: URL(fileURLWithPath: "/Volumes/SSD - Enri/repair-log.json")))
    }

    func testUnreadableFile_startsEmpty_andStaysUsable() throws {
        try Data("non e' json".utf8).write(to: url)
        let store = try RepairLogStore(url: url)
        XCTAssertTrue(store.records().isEmpty)
        try store.record(record("r1"))
        XCTAssertEqual(try RepairLogStore(url: url).records().count, 1)
    }

    /// Una voce scritta con i soli campi portanti (una versione futura potrebbe toglierne o
    /// aggiungerne altri) si legge; i campi mancanti prendono il loro valore neutro.
    func testRecordWithOnlyTheLoadBearingFields_decodes() throws {
        let json = """
        {"items":[{"repairId":"r1","key":"foto/a.heic","target":"hdd","startedAt":0,"outcome":"repaired"}]}
        """
        try Data(json.utf8).write(to: url)
        let r = try XCTUnwrap(try RepairLogStore(url: url).records().first)
        XCTAssertEqual(r.target, "hdd")
        XCTAssertEqual(r.outcome, .repaired)
        XCTAssertNil(r.quarantinePath)
        XCTAssertFalse(r.reusedQuarantineCopy)
    }
}
