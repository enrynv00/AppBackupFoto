import XCTest
@testable import AppBackupFoto

/// La cartella `_quarantena` della riparazione (ROADMAP #45, ADR-0016) non deve rientrare da
/// nessuna parte: backup SSD → HDD e SSD → Cubbit, elenco delle foto (e quindi Doppioni),
/// inventario (dischi e Cubbit), ripristino, campione d'integrita'.
///
/// E' il TEST DI PARITA' chiesto dalla spec: ogni lettore riceve lo stesso albero — una foto
/// vera, la sua copia rovinata messa in quarantena, e una copia in arrivo lasciata li' da una
/// riparazione fallita — e deve vedere la sola foto vera. Se un giorno qualcuno scrive un
/// lettore nuovo, o cambia l'esclusione di uno solo, questo file lo pretende per tutti.
final class QuarantineExclusionTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!

    override func setUpWithError() throws {
        // `realResolvedPath`: la cartella temporanea passa da `/var` → `/private/var`, e
        // `S3Syncer.localUploadFiles` calcola la chiave togliendo la radice come stringa
        // (sull'SSD vero, `/Volumes/SSD - Enri`, non ci sono link da risolvere).
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("QuarantineExclusionTests-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("SSD")
        try put("Foto/a.jpg", "foto vera")
        // La copia rovinata messa da parte, e una copia in arrivo mai rinominata: STESSO
        // contenuto della foto vera, cosi' i Doppioni la vedrebbero come copia se rientrasse.
        try put("_quarantena/2026-10-04/Foto/a.jpg", "foto vera")
        try put("_quarantena/2026-10-04/Foto/a.jpg.in-arrivo-1a2b3c4d", "foto vera")
        // exFAT non distingue le maiuscole: anche questa va saltata. Sta DENTRO `Foto/` e non
        // in radice perche' anche la cartella temporanea (APFS) non distingue le maiuscole, e in
        // radice finirebbe dentro la `_quarantena` appena creata: il test non proverebbe niente.
        try put("Foto/_Quarantena/b.jpg", "foto vera")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func put(_ rel: String, _ text: String, under base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Una sola fonte

    func testTheFolderName_isOneAndIsInTheSharedList() {
        XCTAssertEqual(LibraryExclusions.quarantineFolderName, "_quarantena")
        XCTAssertTrue(LibraryExclusions.names.contains(LibraryExclusions.quarantineFolderName))
    }

    func testTheName_isMatchedWithoutCase_butExactly() {
        for name in ["_quarantena", "_Quarantena", "_QUARANTENA"] {
            XCTAssertTrue(LibraryExclusions.shouldExclude(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["quarantena", "_quarantena2", "_quarantena.jpg", "la_quarantena"] {
            XCTAssertFalse(LibraryExclusions.shouldExclude(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        XCTAssertTrue(LibraryExclusions.isInsideQuarantine(relativePath: "_quarantena/2026-10-04/Foto/a.jpg"))
        XCTAssertFalse(LibraryExclusions.isInsideQuarantine(relativePath: "Foto/quarantena/a.jpg"))
    }

    // MARK: - I lettori, uno per uno

    func testListOfPhotos_andDuplicates_doNotSeeIt() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        _ = try LibraryIndexer(store: store).scan(root: root)
        XCTAssertEqual(try store.allKeys(), ["foto/a.jpg"])
        XCTAssertTrue(try store.duplicateGroups().isEmpty,
                      "la copia in quarantena non e' un doppione da proporre")
    }

    func testInventoryOfTheDisks_doesNotSeeIt() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        try store.beginInventoryRun(runId: 1, startedAt: 0)
        let report = try InventoryScanner(store: store, cancelFlag: CancelFlag()).scan(root: root, archive: .ssd, runId: 1)
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(Set(try store.inventoryLocalRows(.ssd).keys), ["foto/a.jpg"])
    }

    func testInventoryOfCubbit_doesNotSeeIt() {
        XCTAssertTrue(InventoryPerimeter.includesS3Key("Foto/a.jpg"))
        XCTAssertFalse(InventoryPerimeter.includesS3Key("_quarantena/2026-10-04/Foto/a.jpg"))
        XCTAssertFalse(InventoryPerimeter.includesS3Key("_Quarantena/2026-10-04/Foto/a.jpg"))
    }

    func testBackupToTheHDD_doesNotCopyIt() async throws {
        let hdd = tmp.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        let syncer = FileSyncer()
        let preview = await syncer.previewSync(from: root, to: hdd, deep: false)
        XCTAssertEqual(preview.toAdd, 1)
        let result = try await syncer.sync(from: root, to: hdd, deep: false, onStatus: { _ in }, onProgress: { _ in })
        XCTAssertEqual(result.copied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Foto/a.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("_quarantena").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Foto/_Quarantena").path))
    }

    func testBackupToCubbit_doesNotUploadIt() throws {
        let files = try XCTUnwrap(S3Syncer.localUploadFiles(root: root))
        XCTAssertEqual(files.map(\.key), ["Foto/a.jpg"])
    }

    func testRestore_doesNotOfferIt() {
        XCTAssertEqual(RestoreEngine().listAvailableFolders(rootURL: root), ["Foto"])
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: ["Foto/a.jpg", "_quarantena/2026-10-04/Foto/a.jpg"]),
                       ["Foto"])
    }

    func testIntegritySample_doesNotSampleIt() throws {
        // Sull'HDD c'e' SOLO la quarantena: senza esclusione il campione la conterebbe come
        // "sorgente mancante".
        let src = tmp.appendingPathComponent("SRC"), dst = tmp.appendingPathComponent("DST")
        try put("Foto/x.jpg", "x", under: src)
        try put("_quarantena/2026-10-04/Foto/y.jpg", "y", under: dst)
        let result = integritySampleLocalPair(srcRoot: src, dstRoot: dst, pairName: "Test", sampleSize: 20,
                                              defaults: UserDefaults(suiteName: "QuarantineExclusionTests-\(UUID())")!)
        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.skippedNoSource, 0)
    }

    // MARK: - Un'importazione non deve poter finire li' dentro

    func testImportLabel_cannotBecomeAnExcludedFolder() {
        XCTAssertEqual(importFolderSlug("_quarantena"), "Import")
        XCTAssertEqual(importFolderSlug("_Quarantena"), "Import")
        XCTAssertEqual(importFolderSlug("lost+found"), "Import")
        XCTAssertEqual(importFolderSlug("Quarantena estate"), "Quarantena estate")
    }
}
