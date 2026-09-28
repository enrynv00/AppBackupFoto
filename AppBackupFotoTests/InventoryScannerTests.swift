import XCTest
@testable import AppBackupFoto

/// `InventoryScanner` (ROADMAP #44): la lettura di SSD e HDD per l'inventario, su cartelle
/// temporanee vere. Il caso piu' importante e' la regola «incompleto non e' assente».
final class InventoryScannerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var store: LibraryIndexStore!
    private var flag: CancelFlag!
    private var scanner: InventoryScanner!

    /// Data fissa nel passato, come in `LibraryIndexerTests`: un file appena creato cadrebbe
    /// nella regola anti-racy e verrebbe riletto sempre, e il riuso non si vedrebbe mai.
    private static let fixtureMTime = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryScannerTests-\(UUID().uuidString)")
        root = tempDir.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        flag = CancelFlag()
        scanner = InventoryScanner(store: store, cancelFlag: flag)
    }

    override func tearDownWithError() throws {
        scanner = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureMTime], ofItemAtPath: url.path)
        return url
    }

    private func run(_ id: Int64, batchSize: Int = 200,
                     onProgress: @escaping (InventoryScanReport) -> Void = { _ in }) throws -> InventoryScanReport {
        try store.beginInventoryRun(runId: id, startedAt: Double(id))
        return try scanner.scan(root: root, archive: .hdd, runId: id, batchSize: batchSize,
                                progressIntervalNanos: 0, onProgress: onProgress)
    }

    func testReadsOnlyPhotosAndVideos_withTheirDigests() throws {
        try makeFile("Foto iPhone/a.jpg", "uno")
        try makeFile("Foto iPhone/b.mov", "due")
        try makeFile("Zip/archivio.zip", "non e' una foto")
        try makeFile("Takeout/a.json", "metadati")
        let r = try run(1)
        XCTAssertEqual(r.scanned, 2)
        XCTAssertEqual(r.reread, 2)
        XCTAssertTrue(r.isComplete)

        let rows = try store.inventoryLocalRows(.hdd)
        XCTAssertEqual(Set(rows.keys), ["foto iphone/a.jpg", "foto iphone/b.mov"])
        let a = try XCTUnwrap(rows["foto iphone/a.jpg"])
        XCTAssertEqual(a.displayPath, "Foto iPhone/a.jpg")
        XCTAssertEqual(a.status, .ok)
        var h = ContentHasher(); h.update(Data("uno".utf8))
        XCTAssertEqual(a.digest, h.finalize())
        XCTAssertNil(a.digest?.multipartETag, "3 byte: caricamento unico su Cubbit")
    }

    /// La guardia contro la divergenza fra i due lettori (ADR-0015): sullo stesso albero,
    /// l'inventario vede ESATTAMENTE i file che vede l'elenco dei Doppioni. Nell'albero ci sono
    /// tutte le trappole note: sidecar `._`, cartelle nascoste, `.Trashes`, esclusioni, non-media.
    func testSeesExactlyTheFilesTheListSees() throws {
        try makeFile("Foto iPhone/IMG_1.JPG", "1")
        try makeFile("Foto iPhone/._IMG_1.JPG", "sidecar")
        try makeFile("Foto iPhone/.nascosta/x.jpg", "nascosta")
        try makeFile(".Trashes/501/cestinata.jpg", "cestino")
        try makeFile("lost+found/perso.jpg", "perso")
        try makeFile("Takeout/Foto/IMG_2.heic", "2")
        try makeFile("Takeout/Foto/IMG_2.heic.json", "json")
        try makeFile("Other/video.mp4", "v")
        try makeFile("Zip/a.zip", "zip")

        let listStore = try LibraryIndexStore(url: tempDir.appendingPathComponent("elenco.sqlite"))
        _ = try LibraryIndexer(store: listStore).scan(root: root)
        _ = try run(1)
        XCTAssertEqual(Set(try store.inventoryLocalRows(.hdd).keys), try listStore.allKeys())
        XCTAssertEqual(try listStore.allKeys().count, 3)
    }

    func testSecondRun_reusesUnchangedFiles() throws {
        try makeFile("Foto/a.jpg", "uno")
        try makeFile("Foto/b.jpg", "due")
        _ = try run(1)
        let r = try run(2)
        XCTAssertEqual(r.reused, 2)
        XCTAssertEqual(r.reread, 0)
        XCTAssertTrue(r.isComplete)
    }

    func testChangedFile_isReadAgain() throws {
        try makeFile("Foto/a.jpg", "uno")
        let b = try makeFile("Foto/b.jpg", "due")
        _ = try run(1)
        try Data("contenuto nuovo".utf8).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureMTime.addingTimeInterval(600)],
                                              ofItemAtPath: b.path)
        let r = try run(2)
        XCTAssertEqual(r.reused, 1)
        XCTAssertEqual(r.reread, 1)
        var h = ContentHasher(); h.update(Data("contenuto nuovo".utf8))
        XCTAssertEqual(try store.inventoryLocalRows(.hdd)["foto/b.jpg"]?.digest, h.finalize())
    }

    /// Un file che non si legge rende l'archivio incompleto, e resta scritto: quel file c'e',
    /// solo che non sappiamo cosa contiene.
    func testUnreadableFile_makesTheArchiveIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        let b = try makeFile("Foto/b.jpg", "due")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: b.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path) }

        let r = try run(1)
        XCTAssertEqual(r.unreadableFiles, 1)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.incompleteReason, .filesUnreadable)
        let row = try XCTUnwrap(store.inventoryLocalRows(.hdd)["foto/b.jpg"])
        XCTAssertEqual(row.status, .unreadable)
        XCTAssertNil(row.digest)
    }

    /// Un file che l'ultima volta non si leggeva non si "ricorda" come letto: si riprova.
    func testPreviouslyUnreadableFile_isTriedAgain() throws {
        let b = try makeFile("Foto/b.jpg", "due")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: b.path)
        _ = try run(1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
        let r = try run(2)
        XCTAssertEqual(r.reread, 1)
        XCTAssertTrue(r.isComplete)
    }

    func testUnreadableFolder_makesTheArchiveIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        try makeFile("Foto/segreta/s.jpg", "s")
        let secret = root.appendingPathComponent("Foto/segreta")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        let r = try run(1)
        XCTAssertEqual(r.unreadableFolders, 1)
        XCTAssertEqual(r.incompleteReason, .foldersUnreadable)
    }

    /// Disco scollegato prima di partire: non e' un disco vuoto.
    func testRootMissingAtStart_isAVanishedDisk_notAnEmptyOne() throws {
        try FileManager.default.removeItem(at: root)
        let r = try run(1)
        XCTAssertTrue(r.volumeVanished)
        XCTAssertEqual(r.incompleteReason, .volumeVanished)
        XCTAssertEqual(r.scanned, 0)
    }

    /// La radice sparisce a meta' lettura (lo stesso trucco deterministico di
    /// `LibraryIndexerTests.testRootRenamedDuringScan_…`: rinominarla dal primo progresso).
    func testRootVanishingDuringTheRead_isAVanishedDisk() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        let moved = tempDir.appendingPathComponent("HDD-scollegato")
        let original = root!
        var renamed = false
        let r = try run(1, batchSize: 1) { _ in
            guard !renamed else { return }
            renamed = true
            try? FileManager.default.moveItem(at: original, to: moved)
        }
        XCTAssertTrue(renamed)
        XCTAssertTrue(r.volumeVanished)
        XCTAssertFalse(r.isComplete)
    }

    func testStop_isAnInterruption() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        flag.cancel()
        let r = try run(1)
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.incompleteReason, .interrupted)
    }

    /// Zero file visti dove la volta prima ce n'erano: "non ho trovato niente" non e' "non c'e'
    /// niente".
    func testSawNothing_afterAPreviousRun_isIncomplete() throws {
        try makeFile("Foto/a.jpg", "uno")
        _ = try run(1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto"))
        let r = try run(2)
        XCTAssertTrue(r.sawNothing)
        XCTAssertEqual(r.incompleteReason, .sawNothing)
    }

    /// ADR-0002: le righe si salvano a lotti MENTRE la lettura va avanti, non tutte alla fine.
    func testRowsAreSavedInBatches_duringTheRead() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", "c\(i)") }
        var savedDuringTheRead = 0
        let r = try run(1, batchSize: 2) { [store] report in
            if report.scanned == 3 { savedDuringTheRead = (try? store!.inventoryLocalRows(.hdd).count) ?? -1 }
        }
        XCTAssertEqual(r.scanned, 5)
        XCTAssertGreaterThanOrEqual(savedDuringTheRead, 2)
    }
}
