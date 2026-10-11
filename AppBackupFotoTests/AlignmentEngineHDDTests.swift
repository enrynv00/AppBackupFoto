import XCTest
@testable import AppBackupFoto

/// Il motore del progetto 4 sull'HDD (ROADMAP #47, ADR-0019), su cartelle temporanee al posto di
/// SSD e HDD e un Cestino finto (una cartella sull'«HDD», con `rename`: un `trashItem` vero
/// manderebbe i file di prova nel Cestino del Mac). Per ogni condizione del ricontrollo dal vivo
/// c'e' un test che la fa fallire da sola e pretende che niente si muova.
final class AlignmentEngineHDDTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var trash: URL!
    private var store: AlignmentLogStore!
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentEngineHDDTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        trash = hdd.appendingPathComponent(".Trashes/501")
        for d in [ssd!, hdd!, trash!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment-hdd.jsonl"))
        try put(ssd, kept, content)
        try put(hdd, leaving, content)
        try put(hdd, kept, content)
    }

    override func tearDownWithError() throws {
        if let e = FileManager.default.enumerator(atPath: tmp.path) {
            while let rel = e.nextObject() as? String { _ = chflags(tmp.appendingPathComponent(rel).path, 0) }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ root: URL, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ leavingPath: String? = nil, kept keptPath: String? = nil, archive: AlignmentArchive = .hdd) -> AlignmentCandidate {
        let l = leavingPath ?? leaving, k = keptPath ?? kept, d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(l), keptKey: normalizedIndexKey(k),
                                  leavingPath: l, keptPath: k, ssdLeavingPath: l, ssdKeptPath: k, ssdKeptSize: d.size,
                                  size: d.size, sha256: d.sha256, leavingETag: nil, keptETag: nil)
    }

    /// Il Cestino finto: `rename` nella cartella `.Trashes/501` dell'«HDD», con un nome unico.
    private nonisolated static func fakeTrash(into dir: URL) -> @Sendable (URL) throws -> URL? {
        return { url in
            let dst = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dst)
            return dst
        }
    }

    private func engine(hddRoot: URL?? = nil,
                        log: (@Sendable (AlignmentLogEntry) throws -> Void)? = nil,
                        hashFunction: (@Sendable (URL) -> MeasuredHash?)? = nil,
                        trashFunction: (@Sendable (URL) throws -> URL?)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil,
                        fileFlags: (@Sendable (URL) -> UInt32?)? = nil) -> ArchiveAligner {
        let s = store!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: hddRoot ?? hdd, cloud: nil,
                              log: log ?? { try s.append($0) },
                              hashFunction: hashFunction ?? { sha256Measured(of: $0) },
                              trashFunction: trashFunction ?? Self.fakeTrash(into: trash),
                              volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) },
                              fileFlags: fileFlags ?? { url in var st = stat(); return lstat(url.path, &st) == 0 ? st.st_flags : nil })
    }

    private func run(_ e: ArchiveAligner, _ block: [AlignmentCandidate], cancelAfter: Int? = nil) async -> AlignmentBlockOutcome {
        let counter = AlignmentTestCounter()
        return await e.runHDDBlock(block, blockId: "b1",
                                   isCancelled: { cancelAfter.map { counter.value >= $0 } ?? false },
                                   onProgress: { counter.set($0) })
    }

    private func assertNothingMoved(_ o: AlignmentBlockOutcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(o.removed.isEmpty, file: file, line: line)
        XCTAssertTrue(exists(hdd, leaving), "la copia doveva restare sull'HDD", file: file, line: line)
        XCTAssertTrue(exists(hdd, kept), file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [], file: file, line: line)
    }

    // MARK: - Il caso buono

    func testCopyGoesToTheHDDTrash_keptCopyAndSSDUntouched_logWritten() async throws {
        let o = await run(engine(), [candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.removed, [candidate()])
        XCTAssertEqual(o.removedBytes, digest(content).size)
        XCTAssertFalse(exists(hdd, leaving))
        XCTAssertTrue(exists(hdd, kept))
        XCTAssertTrue(exists(ssd, kept))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(trashed.count, 1)
        let entries = store.read().entries
        XCTAssertEqual(entries.map(\.event), [.pending, .removed])
        XCTAssertEqual(entries[0].id, entries[1].id)
        XCTAssertEqual(entries[0].originalAbsolutePath, hdd.appendingPathComponent(leaving).path)
        XCTAssertEqual(entries[0].keptPath, kept)
        XCTAssertEqual(entries[0].sha256, digest(content).sha256)
        XCTAssertEqual(entries[1].trashedPath, trash.appendingPathComponent(trashed[0]).path)
        XCTAssertEqual(store.state(for: .hdd)?.removedKeys, [normalizedIndexKey(leaving)])
    }

    func testThePendingLineIsWrittenBeforeTheCopyIsTouched() async {
        let s = store!
        let seen = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in
            seen.set(s.read().entries.filter { $0.event == .pending }.count)
            return try base(url)
        }), [candidate()])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(seen.value, 1)
    }

    func testProgressIsReportedForEveryCopy() async throws {
        try put(hdd, "Other/b.jpg", content)
        let counter = AlignmentTestCounter()
        _ = await engine().runHDDBlock([candidate(), candidate("Other/b.jpg")], blockId: "b", onProgress: { counter.set($0) })
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - L'SSD dal vivo (condizioni 3 e 4)

    func testCopyBackOnTheSSD_stays() async throws {
        try put(ssd, leaving, content)
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.backOnSSD: 1])
        assertNothingMoved(o)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testKeptCopyGoneOrChangedOnTheSSD_stays() async throws {
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(kept))
        var o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        assertNothingMoved(o)
        try put(ssd, kept, content + " e un po' di piu'")
        o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        assertNothingMoved(o)
    }

    // MARK: - L'HDD dal vivo (condizioni 2 e 6)

    func testCopyAlreadyGoneFromTheHDD_isSkipped_notCountedAsRemoved() async throws {
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(leaving))
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.goneFromArchive: 1])
        XCTAssertTrue(o.removed.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testKeptCopyGoneFromTheHDD_stays() async throws {
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(kept))
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.keptMissingInArchive: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testChangedContent_onEitherCopy_stays() async throws {
        try put(hdd, leaving, "un'altra foto")
        var o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        assertNothingMoved(o)
        try put(hdd, leaving, content)
        try put(hdd, kept, "tenuta cambiata")
        o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testBothCopiesChangedTheSameWay_stillStays() async throws {
        // Uguali fra loro ma diverse dall'inventario: non e' la foto che l'utente ha confermato.
        try put(hdd, leaving, "entrambe cambiate")
        try put(hdd, kept, "entrambe cambiate")
        let o = await run(engine(), [candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testUnreadableCopy_stays() async {
        let o = await run(engine(hashFunction: { $0.path.hasSuffix("A.JPG") ? nil : sha256Measured(of: $0) }), [candidate()])
        XCTAssertEqual(o.skipped, [.unreadable: 1])
        assertNothingMoved(o)
    }

    func testRealLockedFile_isSkipped_andTheRunGoesOn() async throws {
        try put(hdd, "Other/b.jpg", content)
        XCTAssertEqual(chflags(hdd.appendingPathComponent(leaving).path, UInt32(UF_IMMUTABLE)), 0)
        let o = await run(engine(), [candidate(), candidate("Other/b.jpg")])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.skipped, [.locked: 1])
        XCTAssertEqual(o.removed.map(\.leavingPath), ["Other/b.jpg"])
        XCTAssertTrue(exists(hdd, leaving))
    }

    func testLockedOnlyDiscoveredWhenTrashFails_isSkipped() async {
        let calls = AlignmentTestCounter()
        let o = await run(engine(trashFunction: { _ in throw CocoaError(.fileWriteNoPermission) },
                                 fileFlags: { _ in calls.increment() > 1 ? UInt32(UF_IMMUTABLE) : 0 }), [candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.skipped, [.locked: 1])
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testUnsafePaths_symlinks_andNonMedia_stay() async throws {
        try put(hdd, "Takeout/note.json", content)
        try FileManager.default.createSymbolicLink(at: hdd.appendingPathComponent("Takeout/link.jpg"),
                                                   withDestinationURL: hdd.appendingPathComponent(kept))
        let o = await run(engine(), [candidate("../fuori.jpg"), candidate("Takeout/note.json"), candidate("Takeout/link.jpg"),
                                     candidate(archive: .cubbit)])
        XCTAssertEqual(o.skipped, [.unsafePath: 4])
        assertNothingMoved(o)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("Takeout/link.jpg").path))
    }

    // MARK: - I guasti che fermano la corsa

    func testHDDMissingAtStart_nothingIsTouched() async {
        let o = await run(engine(hddRoot: .some(tmp.appendingPathComponent("non-c-e"))), [candidate()])
        XCTAssertEqual(o.stop, .volumeMissing(.hdd))
        assertNothingMoved(o)
        let none = await run(engine(hddRoot: .some(nil)), [candidate()])
        XCTAssertEqual(none.stop, .volumeMissing(.hdd))
    }

    func testSSDMissingAtStart_nothingIsTouched() async {
        let ssdPath = ssd.path
        let o = await run(engine(volumeIdentity: { $0.path == ssdPath ? nil : deviceIdentifier(of: $0) }), [candidate()])
        XCTAssertEqual(o.stop, .volumeMissing(.ssd))
        assertNothingMoved(o)
    }

    func testHDDVanishingMidBlock_stopsAndKeepsTheHonestCount() async throws {
        try put(hdd, "Other/b.jpg", content)
        let hddPath = hdd.path
        let trashed = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        // Dopo il primo spostamento la radice dell'HDD risponde con un altro disco.
        let o = await run(engine(trashFunction: { url in trashed.increment(); return try base(url) },
                                 volumeIdentity: { url in
                                     url.path == hddPath && trashed.value > 0 ? 999 : deviceIdentifier(of: url)
                                 }), [candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(o.stop, .volumeVanished(.hdd))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }

    func testSSDVanishingMidBlock_stops() async throws {
        try put(hdd, "Other/b.jpg", content)
        let ssdPath = ssd.path
        let trashed = AlignmentTestCounter()
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in trashed.increment(); return try base(url) },
                                 volumeIdentity: { url in
                                     url.path == ssdPath && trashed.value > 0 ? 999 : deviceIdentifier(of: url)
                                 }), [candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(o.stop, .volumeVanished(.ssd))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }

    func testLogNotWritable_nothingIsTouched() async {
        struct Broken: Error {}
        let o = await run(engine(log: { _ in throw Broken() }), [candidate()])
        guard case .logNotWritten = o.stop else { return XCTFail("doveva fermarsi sul registro: \(String(describing: o.stop))") }
        assertNothingMoved(o)
    }

    func testTrashFailing_stopsTheRun_andTheCopyStays() async throws {
        try put(hdd, "Other/b.jpg", content)
        let o = await run(engine(trashFunction: { _ in throw CocoaError(.fileWriteUnknown) }), [candidate(), candidate("Other/b.jpg")])
        guard case .trashFailed(let path, _) = o.stop else { return XCTFail("doveva fermarsi: \(String(describing: o.stop))") }
        XCTAssertEqual(path, leaving)
        XCTAssertTrue(exists(hdd, leaving))
        XCTAssertTrue(exists(hdd, "Other/b.jpg"), "dopo un guasto non si prova la copia successiva")
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testKeptCopyVanishingRightAfter_stops_withTheRemovedCopyLogged() async throws {
        let keptURL = hdd.appendingPathComponent(kept)
        let base = Self.fakeTrash(into: trash)
        let o = await run(engine(trashFunction: { url in
            let r = try base(url)
            try FileManager.default.removeItem(at: keptURL)
            return r
        }), [candidate()])
        XCTAssertEqual(o.stop, .keptVanished(path: kept))
        XCTAssertEqual(store.state(for: .hdd)?.lastBlockToRestore.count, 1, "«Annulla» deve poterla rimettere")
    }

    func testInterrupt_stopsBetweenCopies() async throws {
        try put(hdd, "Other/b.jpg", content)
        let o = await run(engine(), [candidate(), candidate("Other/b.jpg")], cancelAfter: 1)
        XCTAssertEqual(o.stop, .interrupted)
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertTrue(exists(hdd, "Other/b.jpg"))
    }
}

/// Un contatore condiviso fra le closure `@Sendable` dei test.
nonisolated final class AlignmentTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func set(_ v: Int) { lock.withLock { n = v } }
    @discardableResult func increment() -> Int { lock.withLock { n += 1; return n } }
}
