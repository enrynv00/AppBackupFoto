import XCTest
@testable import AppBackupFoto

/// `InventoryCubbitReader` e `InventoryPerimeter` (ROADMAP #44): la lista di Cubbit con l'ETag,
/// salvata a pagine, con un Cubbit finto (le pagine sono XML scritti a mano, nessuna rete).
final class InventoryCubbitReaderTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!
    private var flag: CancelFlag!
    private var reader: InventoryCubbitReader!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InventoryCubbitReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        flag = CancelFlag()
        reader = InventoryCubbitReader(store: store, cancelFlag: flag)
        try store.beginInventoryRun(runId: 1, startedAt: 0)
    }

    override func tearDownWithError() throws {
        reader = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct NetworkDown: Error {}

    private static func object(_ key: String, _ size: Int, _ etag: String) -> String {
        "<Contents><Key>\(key)</Key><ETag>&quot;\(etag)&quot;</ETag><Size>\(size)</Size></Contents>"
    }

    /// Pagina per token (`""` = la prima). Un dizionario `let`: `Sendable`, nessuno stato.
    private static let twoPages: [String: String] = [
        "": "<ListBucketResult><IsTruncated>true</IsTruncated>"
            + object("Foto iPhone/IMG_1.JPG", 1000, "e722bbb0c3185d08f1a31567e66a825b")
            + object("Zip/archivio.zip", 5, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            + object("Foto iPhone/._IMG_1.JPG", 4096, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            + "<NextContinuationToken>Foto iPhone/IMG_1.JPG</NextContinuationToken></ListBucketResult>",
        "Foto iPhone/IMG_1.JPG": "<ListBucketResult><IsTruncated>false</IsTruncated>"
            + object("ASUS/Elba/FILE0056.MOV", 67_108_865, "96aa53ed4132d7e2986467263954caad-2")
            + "</ListBucketResult>",
    ]

    func testTwoPages_complete_keepsOnlyPhotosAndVideos() async throws {
        let pages = Self.twoPages
        let r = await reader.read(runId: 1, fetchPage: { token in
            guard let page = pages[token ?? ""] else { throw NetworkDown() }
            return page
        })
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.pages, 2)
        XCTAssertEqual(r.objectsListed, 4)
        XCTAssertEqual(r.objectsKept, 2, "niente archivi zip, niente sidecar `._`")
        try store.finishInventoryArchive(.s3, runId: 1, complete: true, reason: nil, unreadable: 0, finishedAt: 1)
        let s3 = try store.inventorySnapshot().s3
        XCTAssertEqual(s3.map(\.displayKey), ["ASUS/Elba/FILE0056.MOV", "Foto iPhone/IMG_1.JPG"])
        XCTAssertEqual(s3.map(\.key), ["asus/elba/file0056.mov", "foto iphone/img_1.jpg"],
                       "la chiave di confronto e' la stessa forma normalizzata dei dischi")
        XCTAssertEqual(s3[0].etag, "\"96aa53ed4132d7e2986467263954caad-2\"")
    }

    /// La lista si interrompe alla seconda pagina: la prima resta salvata (ADR-0002), ma
    /// Cubbit e' incompleto e da li' non si dichiara assente niente.
    func testNetworkFailureOnTheSecondPage_isIncomplete_firstPageKept() async throws {
        let first = Self.twoPages[""]!
        let r = await reader.read(runId: 1, fetchPage: { token in
            guard token == nil else { throw NetworkDown() }
            return first
        })
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.incompleteReason, .listingFailed)
        XCTAssertEqual(r.pages, 1)
        XCTAssertEqual(try store.inventorySnapshot().s3.count, 1)
    }

    func testTruncatedWithoutToken_isIncomplete() async {
        let page = "<ListBucketResult><IsTruncated>true</IsTruncated>"
            + Self.object("a.jpg", 1, "e722bbb0c3185d08f1a31567e66a825b") + "</ListBucketResult>"
        let r = await reader.read(runId: 1, fetchPage: { _ in page })
        XCTAssertTrue(r.truncatedWithoutToken)
        XCTAssertEqual(r.incompleteReason, .listingMalformed)
    }

    /// Token vuoto su una pagina troncata: incompleto, e nessuna seconda richiesta (con `""`
    /// si richiederebbe di nuovo la prima pagina, all'infinito).
    func testTruncatedWithAnEmptyToken_isIncomplete_andAsksOnlyOnce() async {
        let page = "<ListBucketResult><IsTruncated>true</IsTruncated>"
            + Self.object("a.jpg", 1, "e722bbb0c3185d08f1a31567e66a825b")
            + "<NextContinuationToken></NextContinuationToken></ListBucketResult>"
        let r = await reader.read(runId: 1, fetchPage: { token in
            XCTAssertNil(token, "dopo una pagina con token vuoto non si chiede altro")
            return page
        })
        XCTAssertEqual(r.pages, 1)
        XCTAssertTrue(r.truncatedWithoutToken)
        XCTAssertFalse(r.isComplete)
    }

    func testMalformedEntry_isIncomplete() async {
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key></Contents></ListBucketResult>"
        let r = await reader.read(runId: 1, fetchPage: { _ in page })
        XCTAssertEqual(r.malformedEntries, 1)
        XCTAssertEqual(r.incompleteReason, .listingMalformed)
    }

    func testStopBeforeTheFirstPage_asksNothing() async {
        flag.cancel()
        let r = await reader.read(runId: 1, fetchPage: { _ in
            XCTFail("dopo uno stop non si chiede niente a Cubbit")
            return ""
        })
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.pages, 0)
        XCTAssertEqual(r.incompleteReason, .interrupted)
    }

    func testStopAfterTheFirstPage_isAnInterruption() async {
        let pages = Self.twoPages
        let flag = self.flag!
        let r = await reader.read(runId: 1, fetchPage: { token in pages[token ?? ""] ?? "" },
                                  onProgress: { report in if report.pages == 1 { flag.cancel() } })
        XCTAssertEqual(r.pages, 1)
        XCTAssertTrue(r.cancelled)
        XCTAssertFalse(r.isComplete)
    }

    // MARK: - Perimetro

    func testPerimeter_isTheSameAsTheDisks() {
        let inside = ["Foto iPhone/IMG_1.JPG", "ASUS/recup_dir.37/f200571080.jpg", "Takeout/Foto/IMG_2.heic", "Other/v.mp4"]
        let outside = ["Zip/archivio.zip", "Takeout/Foto/IMG_2.heic.json", "Foto/._IMG_1.JPG", "Foto/.nascosta/a.jpg",
                       ".Trashes/501/a.jpg", "lost+found/a.jpg", "Foto/", "", "Foto/IMG.AAE"]
        for k in inside { XCTAssertTrue(InventoryPerimeter.includesS3Key(k), "dentro: \(k)") }
        for k in outside { XCTAssertFalse(InventoryPerimeter.includesS3Key(k), "fuori: \(k)") }
    }
}
