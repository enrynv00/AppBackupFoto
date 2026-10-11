import XCTest
@testable import AppBackupFoto

/// «Annulla l'ultimo blocco» del progetto 4 (ROADMAP #47, ADR-0019). Sull'HDD rimette a posto dal
/// Cestino con la cura di `TrashRestorer`; su Cubbit toglie solo i segni di cancellazione
/// registrati, mai una versione di dati, e verifica con la HEAD che la foto sia tornata.
final class AlignmentUndoTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var trash: URL!
    private var store: AlignmentLogStore!
    private var cloud: FakeAlignmentCloud!
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentUndoTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        trash = hdd.appendingPathComponent(".Trashes/501")
        for d in [ssd!, hdd!, trash!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment.jsonl"))
        cloud = FakeAlignmentCloud()
        try put(ssd, kept, content)
        try put(hdd, leaving, content)
        try put(hdd, kept, content)
        cloud.put(leaving, content)
        cloud.put(kept, content)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ archive: AlignmentArchive) -> AlignmentCandidate {
        let d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(leaving), keptKey: normalizedIndexKey(kept),
                                  leavingPath: leaving, keptPath: kept, ssdLeavingPath: leaving, ssdKeptPath: kept,
                                  ssdKeptSize: d.size, size: d.size, sha256: d.sha256,
                                  leavingETag: archive == .cubbit ? d.md5 : nil, keptETag: archive == .cubbit ? d.md5 : nil)
    }

    private func engine(now: Date = Date()) -> ArchiveAligner {
        let s = store!, dir = trash!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: hdd, cloud: cloud, log: { try s.append($0) }, now: { now },
                              trashFunction: { url in
                                  let dst = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                                  try FileManager.default.moveItem(at: url, to: dst)
                                  return dst
                              })
    }

    /// Toglie la copia con il motore, e restituisce l'ultimo blocco come lo legge «Annulla».
    private func removeThenLastBlock(_ archive: AlignmentArchive, removedAt: Date = Date()) async -> [AlignmentRemoval] {
        let e = engine(now: removedAt)
        let o = archive == .hdd ? await e.runHDDBlock([candidate(.hdd)], blockId: "b1")
                                : await e.runCubbitBlock([candidate(.cubbit)], blockId: "b1")
        XCTAssertEqual(o.removed.count, 1)
        return store.state(for: archive)?.lastBlockToRestore ?? []
    }

    // MARK: - HDD

    func testHDD_undo_putsTheCopyBack_andTheLogKnows() async {
        let block = await removeThenLastBlock(.hdd)
        XCTAssertNil(read(hdd, leaving))
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.restored, 1)
        XCTAssertEqual(read(hdd, leaving), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 0)
        XCTAssertNil(store.state(for: .hdd)?.lastBlockSummary)
    }

    func testHDD_undo_neverOverwritesAFileThatTookItsPlace() async throws {
        let block = await removeThenLastBlock(.hdd)
        try put(hdd, leaving, "un file nuovo con lo stesso nome")
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.skipped, [.occupied: 1])
        XCTAssertEqual(read(hdd, leaving), "un file nuovo con lo stesso nome")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func testHDD_undo_afterTheTrashWasEmptied_saysSo() async throws {
        let block = await removeThenLastBlock(.hdd)
        for f in try FileManager.default.contentsOfDirectory(atPath: trash.path) { try FileManager.default.removeItem(at: trash.appendingPathComponent(f)) }
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.skipped, [.missingInTrash: 1])
        XCTAssertEqual(o.restored, 0)
    }

    func testHDD_undo_recognisesACopyAlreadyPutBackByHand() async throws {
        let block = await removeThenLastBlock(.hdd)
        let inTrash = try FileManager.default.contentsOfDirectory(atPath: trash.path)[0]
        try FileManager.default.moveItem(at: trash.appendingPathComponent(inTrash), to: hdd.appendingPathComponent(leaving))
        let o = await engine().undo(block, archive: .hdd)
        XCTAssertEqual(o.alreadyBack, 1)
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 0)
    }

    func testHDD_undo_withoutWhereItWent_isNotRestorable() async {
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .hdd, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: 1, sha256: "s", etag: nil, originalAbsolutePath: nil, trashedPath: nil,
                                 deleteMarkerVersionId: nil, removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .hdd)
        XCTAssertEqual(o.skipped, [.notRestorable: 1])
    }

    func testHDD_undo_withTheHDDGone_touchesNothing() async {
        let block = await removeThenLastBlock(.hdd)
        let e = ArchiveAligner(ssdRoot: ssd, hddRoot: tmp.appendingPathComponent("non-c-e"), cloud: nil, log: { _ in })
        let o = await e.undo(block, archive: .hdd)
        XCTAssertEqual(o.stop, .volumeMissing(.hdd))
        XCTAssertEqual(o.notAttempted, 1)
    }

    // MARK: - Cubbit

    func testCubbit_undo_removesTheRecordedMarker_andTheSamePhotoIsBack() async {
        let block = await removeThenLastBlock(.cubbit)
        XCTAssertNil(cloud.current(leaving))
        XCTAssertEqual(block.first?.deleteMarkerVersionId, "m3")
        let o = await engine().undo(block, archive: .cubbit)
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.restored, 1)
        XCTAssertEqual(cloud.current(leaving), content)
        XCTAssertEqual(cloud.markerRemovals.map(\.versionId), ["m3"])
        XCTAssertEqual(cloud.dataVersionIds(leaving), ["v1"], "la versione della foto non si tocca")
        XCTAssertEqual(store.state(for: .cubbit)?.lastBlockToRestore.count, 0)
    }

    func testCubbit_undo_pastTheRuleDays_doesNothing() async {
        let block = await removeThenLastBlock(.cubbit, removedAt: Date(timeIntervalSinceNow: -29.5 * 86_400))
        let o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.tooOld: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        // Senza regola le versioni restano per sempre: nessun limite.
        cloud.rules = []
        let again = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(again.restored, 1)
    }

    func testCubbit_undo_neverRemovesADataVersion_evenIfTheLogNamesOne() async {
        let block = await removeThenLastBlock(.cubbit)
        let r = block[0]
        let tampered = AlignmentRemoval(id: r.id, blockId: r.blockId, archive: .cubbit, leavingPath: r.leavingPath, leavingKey: r.leavingKey,
                                        keptPath: r.keptPath, size: r.size, sha256: r.sha256, etag: r.etag, originalAbsolutePath: nil,
                                        trashedPath: nil, deleteMarkerVersionId: "v1", removedAt: r.removedAt, restoredAt: nil)
        let o = await engine().undo([tampered], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.notADeleteMarker: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        XCTAssertEqual(cloud.dataVersionIds(leaving), ["v1"])
    }

    func testCubbit_undo_markerThatIsNotTheLatest_orMissing_staysPut() async {
        let block = await removeThenLastBlock(.cubbit)
        _ = try? await cloud.delete(key: leaving)          // un secondo segno sopra quello registrato
        var o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.markerNotLatest: 1])
        let r = block[0]
        let unknown = AlignmentRemoval(id: r.id, blockId: r.blockId, archive: .cubbit, leavingPath: r.leavingPath, leavingKey: r.leavingKey,
                                       keptPath: r.keptPath, size: r.size, sha256: r.sha256, etag: r.etag, originalAbsolutePath: nil,
                                       trashedPath: nil, deleteMarkerVersionId: "m-sconosciuto", removedAt: r.removedAt, restoredAt: nil)
        o = await engine().undo([unknown], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.markerNotFound: 1])
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
    }

    func testCubbit_undo_alreadyBack_orReplacedByAnotherPhoto() async {
        let block = await removeThenLastBlock(.cubbit)
        cloud.put(leaving, content)                        // ricaricata dal backup, stessa foto
        var o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.alreadyBack, 1)
        XCTAssertTrue(cloud.markerRemovals.isEmpty)
        cloud.put(leaving, "un'altra foto")
        o = await engine().undo(block, archive: .cubbit)
        XCTAssertEqual(o.skipped, [.occupied: 1])
    }

    func testCubbit_undo_thatDoesNotBringBackTheSamePhoto_isReported() async {
        // Sotto il segno c'e' una versione con un altro contenuto: tolto il segno, la HEAD non torna.
        let other = FakeAlignmentCloud()
        other.put(leaving, "versione diversa")
        _ = try? await other.delete(key: leaving)
        cloud = other
        let d = digest(content)
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .cubbit, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: d.size, sha256: d.sha256, etag: d.md5, originalAbsolutePath: nil,
                                 trashedPath: nil, deleteMarkerVersionId: "m2", removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.verifyFailed: 1])
    }

    func testCubbit_undo_cubbitError_stops() async {
        let block = await removeThenLastBlock(.cubbit)
        cloud.failRemoveMarker = true
        let o = await engine().undo(block, archive: .cubbit)
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertEqual(o.restored, 0)
    }

    func testCubbit_undo_withoutARecordedMarker_isNotRestorable() async {
        let r = AlignmentRemoval(id: "1", blockId: "b", archive: .cubbit, leavingPath: leaving, leavingKey: normalizedIndexKey(leaving),
                                 keptPath: kept, size: 1, sha256: "s", etag: "e", originalAbsolutePath: nil, trashedPath: nil,
                                 deleteMarkerVersionId: nil, removedAt: Date(), restoredAt: nil)
        let o = await engine().undo([r], archive: .cubbit)
        XCTAssertEqual(o.skipped, [.notRestorable: 1])
    }
}
