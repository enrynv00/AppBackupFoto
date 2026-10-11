import XCTest
@testable import AppBackupFoto

/// Il cancello di partenza dell'inventario e il giro completo SSD → HDD → Cubbit → confronto
/// (ROADMAP #44), con due cartelle temporanee al posto dei dischi e un Cubbit finto.
final class InventoryRefreshTests: XCTestCase {
    private var tempDir: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryRefreshTests-\(UUID().uuidString)")
        ssd = tempDir.appendingPathComponent("SSD")
        hdd = tempDir.appendingPathComponent("HDD")
        for d in [ssd!, hdd!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: url.path)
    }

    private func md5(_ text: String) -> String {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize().md5
    }

    // MARK: - Cancello di partenza

    private func reason(isRunning: Bool = false, isIndexing: Bool = false, isTrashingDuplicates: Bool = false,
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false, isRepairing: Bool = false, isAligning: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
        InventoryStartGate.blockedReason(isRunning: isRunning, isIndexing: isIndexing,
                                         isTrashingDuplicates: isTrashingDuplicates,
                                         isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                         isRepairing: isRepairing, isAligning: isAligning,
                                         ssdMounted: ssdMounted, hddMounted: hddMounted, hasCubbitConfig: hasCubbitConfig)
    }

    func testNothingInTheWay_canStart() {
        XCTAssertNil(reason())
    }

    /// Ogni condizione ferma la partenza con una frase sua: chi legge deve capire quale.
    func testEachCondition_blocksWithItsOwnReason() {
        let all = [reason(isRunning: true), reason(isIndexing: true), reason(isTrashingDuplicates: true),
                   reason(isRestoringFromTrash: true), reason(isInventorying: true), reason(ssdMounted: false),
                   reason(hddMounted: false), reason(hasCubbitConfig: false)]
        XCTAssertTrue(all.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(all.compactMap { $0 }).count, all.count, "otto motivi, otto frasi diverse")
        XCTAssertTrue(reason(ssdMounted: false)!.contains("SSD"))
        XCTAssertTrue(reason(hddMounted: false)!.contains("HDD"))
        XCTAssertTrue(reason(hasCubbitConfig: false)!.contains("Cubbit"))
    }

    /// Un'operazione in corso si dice prima di un disco mancante: e' la causa su cui l'utente
    /// puo' fare qualcosa subito ("aspetta"), e un disco si ricollega dopo.
    func testOperationsInProgress_comeBeforeMissingDisks() {
        XCTAssertEqual(reason(isRunning: true, ssdMounted: false), reason(isRunning: true))
        XCTAssertEqual(reason(isRunning: true, isInventorying: true), reason(isInventorying: true))
    }

    func testReasons_haveNoJargon() {
        let gergo = ["hash", "sha", "md5", "etag", "indice", "scansione", "cache", "bucket", "sqlite", "multipart"]
        let texts = [reason(isRunning: true), reason(isIndexing: true), reason(isTrashingDuplicates: true),
                     reason(isRestoringFromTrash: true), reason(isInventorying: true), reason(ssdMounted: false),
                     reason(hddMounted: false), reason(hasCubbitConfig: false), InventoryStartGate.cubbitUnreachable]
        for t in texts.compactMap({ $0?.lowercased() }) {
            for g in gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(t)»") }
        }
    }

    // MARK: - Dischi che si smontano

    func testUnmountingTheSSDOrTheHDD_stopsTheInventory() {
        let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
        let hddRoot = URL(fileURLWithPath: "/Volumes/BackupHDD")
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/SSD - Enri/"), ssdRoot: ssdRoot, hddRoot: hddRoot))
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/BackupHDD"), ssdRoot: ssdRoot, hddRoot: hddRoot))
    }

    /// Espellere una chiavetta o un'immagine disco non butta via un giro di decine di minuti;
    /// e un nome che comincia come quello dell'SSD non e' l'SSD.
    func testUnmountingAnotherDisk_doesNotStopIt() {
        let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
        let hddRoot = URL(fileURLWithPath: "/Volumes/BackupHDD")
        XCTAssertFalse(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/CHIAVETTA"), ssdRoot: ssdRoot, hddRoot: hddRoot))
        XCTAssertFalse(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: URL(fileURLWithPath: "/Volumes/SSD - Enri 2"), ssdRoot: ssdRoot, hddRoot: hddRoot))
    }

    /// Se macOS non dice quale disco se ne va, ci si ferma: e' il verso prudente.
    func testUnknownDisk_stopsTheInventory() {
        XCTAssertTrue(InventoryStartGate.volumeChangeStopsInventory(
            unmounting: nil, ssdRoot: URL(fileURLWithPath: "/Volumes/SSD - Enri"), hddRoot: nil))
    }

    // MARK: - Il giro completo

    func testFullRun_readsTheThreeArchives_andClassifies() async throws {
        try put(ssd, "Foto iPhone/a.jpg", "alfa")      // ovunque
        try put(ssd, "Foto iPhone/b.jpg", "beta")      // manca dall'HDD
        try put(hdd, "Foto iPhone/a.jpg", "alfa")
        try put(hdd, "Vecchie/c.jpg", "gamma")         // solo sull'HDD
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>Foto iPhone/a.jpg</Key><ETag>&quot;\(md5("alfa"))&quot;</ETag><Size>4</Size></Contents>"
            + "<Contents><Key>Foto iPhone/b.jpg</Key><ETag>&quot;\(md5("beta"))&quot;</ETag><Size>4</Size></Contents>"
            + "</ListBucketResult>"
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 42,
                                                 cancelFlag: CancelFlag(), fetchPage: { _ in page },
                                                 onProgress: { _ in })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(InventoryArchive.allCases.allSatisfy { summary.states[$0]?.complete == true })
        XCTAssertEqual(summary.count(.safe), 1)
        XCTAssertEqual(summary.count(.missingSomewhere), 1)
        XCTAssertEqual(summary.samples[.missingSomewhere]?.first?.missingFrom, [.hdd])
        XCTAssertEqual(summary.count(.onlyOutsideSSD), 1)
        XCTAssertEqual(summary.stats[.ssd]?.files, 2)
        XCTAssertEqual(summary.stats[.hdd]?.files, 2)
        XCTAssertEqual(summary.stats[.s3]?.files, 2)
    }

    /// Fermato durante l'SSD: HDD e Cubbit non sono stati letti, e restano «non letti» — mai i
    /// numeri del giro prima spacciati per quelli di oggi, mai «assente» per colpa loro.
    func testStopDuringTheSSD_leavesTheOthersNotReached() async throws {
        try put(ssd, "Foto/a.jpg", "alfa")
        try put(hdd, "Foto/a.jpg", "alfa")
        let flag = CancelFlag()
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1, cancelFlag: flag,
                                                 fetchPage: { _ in
                                                     XCTFail("fermato prima di Cubbit: non si chiede niente")
                                                     return ""
                                                 },
                                                 onProgress: { p in if case .local(.ssd, _) = p { flag.cancel() } })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertEqual(summary.states[.ssd]?.reason, .interrupted)
        XCTAssertEqual(summary.states[.hdd]?.reason, .notReached)
        XCTAssertEqual(summary.states[.s3]?.reason, .notReached)
        XCTAssertEqual(summary.count(.missingSomewhere) + summary.count(.onlyOutsideSSD), 0,
                       "nessuna foto dichiarata mancante da archivi non letti")
    }

    /// L'HDD sparito prima di partire (il caso della prova dal vivo): l'HDD risulta incompleto
    /// e nessuna foto passa in ⚠️ per colpa sua.
    func testMissingHDD_neverMakesAPhotoMissingFromIt() async throws {
        try put(ssd, "Foto/a.jpg", "alfa")
        try FileManager.default.removeItem(at: hdd)
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>Foto/a.jpg</Key><ETag>&quot;\(md5("alfa"))&quot;</ETag><Size>4</Size></Contents></ListBucketResult>"
        let outcome = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1,
                                                 cancelFlag: CancelFlag(), fetchPage: { _ in page }, onProgress: { _ in })
        let summary = try XCTUnwrap(outcome.summary)
        XCTAssertEqual(summary.states[.hdd]?.reason, .volumeVanished)
        XCTAssertEqual(summary.count(.missingSomewhere), 0)
        XCTAssertEqual(summary.count(.undetermined), 1)
    }
}
