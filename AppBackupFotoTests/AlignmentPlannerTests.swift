import XCTest
@testable import AppBackupFoto

/// Le condizioni 1-5 della spec del progetto 4 (ROADMAP #47, ADR-0019): quali copie uscite
/// dall'SSD si possono togliere da HDD e Cubbit, sull'inventario, senza toccare niente. Per
/// ogni motivo per cui una copia resta c'e' un test che lo produce da solo.
final class AlignmentPlannerTests: XCTestCase {
    private let ssdRoot = URL(fileURLWithPath: "/Volumes/SSD - Enri")
    private let leaving = "Takeout/Google Photos/a.jpg"
    private let kept = "Foto iPhone/0/A.JPG"

    // MARK: - Aiuti

    private func digest(_ text: String) -> ContentDigest {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize()
    }

    private func local(_ path: String, _ text: String, status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        let d = digest(text)
        return InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: d.size, mtime: 0,
                                  status: status, digest: status == .ok ? d : nil, hashedAt: 0)
    }

    private func object(_ key: String, _ text: String, etag: String? = nil) -> InventoryS3Object {
        let d = digest(text)
        return InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: d.size, etag: etag ?? "\"\(d.md5)\"")
    }

    private func states(complete: Bool = true, started: Double = 1_000) -> [InventoryArchive: InventoryArchiveState] {
        Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, InventoryArchiveState(archive: $0, runId: 7, complete: complete, reason: complete ? nil : .interrupted,
                                       unreadable: 0, startedAt: started, finishedAt: started + 60))
        })
    }

    /// SSD con la sola copia tenuta; HDD e Cubbit con entrambe, stesso contenuto.
    private func snapshot(ssd: [InventoryLocalFile]? = nil, hdd: [InventoryLocalFile]? = nil,
                          s3: [InventoryS3Object]? = nil, complete: Bool = true) -> InventorySnapshot {
        InventorySnapshot(ssd: ssd ?? [local(kept, "foto")],
                          hdd: hdd ?? [local(leaving, "foto"), local(kept, "foto")],
                          s3: s3 ?? [object(leaving, "foto"), object(kept, "foto")],
                          states: states(complete: complete))
    }

    private func history(_ pairs: [(String, String?)]) -> TrashHistoryReader.Result {
        let entry = TrashHistoryEntry(blockId: "b1", trashedAt: Date(timeIntervalSince1970: 500),
                                      originalPaths: pairs.map { $0.0 },
                                      keptPaths: pairs.map { $0.1 ?? "" })
        return TrashHistoryReader.Result(entries: [entry], malformedLines: 0, unreadable: false)
    }

    private func abs(_ rel: String) -> String { "/Volumes/SSD - Enri/" + rel }

    private func plan(_ archive: AlignmentArchive, history h: TrashHistoryReader.Result? = nil,
                      snapshot s: InventorySnapshot? = nil, lastWrite: Date? = nil,
                      alreadyRemoved: Set<String> = []) -> AlignmentPlan {
        AlignmentPlanner.plan(archive: archive, history: h ?? history([(abs(leaving), kept)]), ssdRoot: ssdRoot,
                              snapshot: s ?? snapshot(), lastArchiveWriteAt: lastWrite, alreadyRemoved: alreadyRemoved)
    }

    private func onlyStay(_ p: AlignmentPlan, _ reason: AlignmentStayReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.candidates.isEmpty, "nessuna copia doveva uscire", file: file, line: line)
        XCTAssertEqual(p.stays, [reason: 1], file: file, line: line)
    }

    // MARK: - Il caso buono

    func testHDD_copyWithKeptCopyCertified_isACandidate() {
        let p = plan(.hdd)
        XCTAssertNil(p.block)
        XCTAssertEqual(p.runId, 7)
        XCTAssertEqual(p.candidates.count, 1)
        let c = p.candidates[0]
        XCTAssertEqual(c.archive, .hdd)
        XCTAssertEqual(c.leavingPath, leaving)
        XCTAssertEqual(c.keptPath, kept)
        XCTAssertEqual(c.ssdLeavingPath, leaving)
        XCTAssertEqual(c.ssdKeptPath, kept)
        XCTAssertEqual(c.sha256, digest("foto").sha256)
        XCTAssertEqual(c.size, digest("foto").size)
        XCTAssertEqual(c.ssdKeptSize, digest("foto").size)
        XCTAssertNil(c.leavingETag)
        XCTAssertEqual(p.bytes, digest("foto").size)
        XCTAssertEqual(p.stayCount, 0)
    }

    func testCubbit_copyWithKeptCopyCertified_isACandidate_withNormalizedETags() {
        let p = plan(.cubbit)
        XCTAssertEqual(p.candidates.count, 1)
        let c = p.candidates[0]
        XCTAssertEqual(c.archive, .cubbit)
        XCTAssertEqual(c.leavingPath, leaving)
        XCTAssertEqual(c.leavingETag, digest("foto").md5)
        XCTAssertEqual(c.keptETag, digest("foto").md5)
    }

    func testArchivePathsAreTheOnesWrittenOnTheArchive() {
        // Sull'HDD la copia ha maiuscole diverse dall'SSD: il motore deve usare quelle dell'HDD.
        let s = snapshot(hdd: [local("TAKEOUT/Google Photos/a.jpg", "foto"), local("Foto iPhone/0/a.jpg", "foto")])
        let c = plan(.hdd, snapshot: s).candidates[0]
        XCTAssertEqual(c.leavingPath, "TAKEOUT/Google Photos/a.jpg")
        XCTAssertEqual(c.keptPath, "Foto iPhone/0/a.jpg")
        XCTAssertEqual(c.ssdLeavingPath, leaving)
    }

    func testCubbit_onePartUploadETag_isCertified() {
        // `-1` con la formula standard: certificata come nell'inventario (ADR-0015).
        let md5 = digest("foto").md5
        let s = snapshot(s3: [object(leaving, "foto", etag: "\"\(S3ETagMatcher.md5OfMD5Hex(md5)!)-1\""), object(kept, "foto")])
        XCTAssertEqual(plan(.cubbit, snapshot: s).candidates.count, 1)
    }

    // MARK: - Condizione 1: l'inventario

    func testInventoryOlderThanLastBackup_nothingLeaves() {
        let p = plan(.hdd, lastWrite: Date(timeIntervalSince1970: 1_001))
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.block, .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_001)))
        XCTAssertNil(p.runId)
    }

    func testIncompleteInventory_nothingLeaves() {
        let p = plan(.cubbit, snapshot: snapshot(complete: false))
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.block, .inventoryIncomplete)
    }

    func testNoInventory_nothingLeaves() {
        let s = InventorySnapshot()
        XCTAssertEqual(plan(.hdd, snapshot: s).block, .inventoryNeverRun)
    }

    func testUnreadableHistory_nothingLeaves() {
        let h = TrashHistoryReader.Result(entries: [], malformedLines: 0, unreadable: true)
        let p = plan(.hdd, history: h)
        XCTAssertTrue(p.historyUnreadable)
        XCTAssertTrue(p.candidates.isEmpty)
    }

    // MARK: - La storia

    func testKeptPathUnknown_stays() {
        onlyStay(plan(.hdd, history: history([(abs(leaving), nil)])), .keptUnknown)
        let old = TrashHistoryEntry(blockId: "b0", trashedAt: Date(), originalPaths: [abs(leaving)], keptPaths: nil)
        onlyStay(plan(.hdd, history: .init(entries: [old], malformedLines: 0, unreadable: false)), .keptUnknown)
    }

    func testOriginalOutsideTheSSD_stays() {
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD - Enri 1/" + leaving, kept)])), .outsideSSD)
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD/" + leaving, kept)])), .outsideSSD)
    }

    func testDotDotInTheWrittenPath_stays() {
        onlyStay(plan(.hdd, history: history([("/Volumes/SSD - Enri/Takeout/../" + leaving, kept)])), .unsafePath)
        onlyStay(plan(.hdd, history: history([(abs(leaving), "Foto iPhone/../x.jpg")])), .unsafePath)
    }

    func testQuarantine_stays() {
        onlyStay(plan(.hdd, history: history([(abs("_quarantena/2026-10-04/" + leaving), kept)])), .unsafePath)
    }

    func testSameAsKept_comparedWithoutCase_stays() {
        onlyStay(plan(.hdd, history: history([(abs("Foto iPhone/0/a.jpg"), "foto iphone/0/A.JPG")])), .sameAsKept)
    }

    func testRepeatedInHistory_withTheSameKept_countsOnce() {
        let p = plan(.hdd, history: history([(abs(leaving), kept), (abs(leaving), kept)]))
        XCTAssertEqual(p.candidates.count, 1)
        XCTAssertEqual(p.stays, [.repeatedInHistory: 1])
        XCTAssertEqual(p.historyCopies, 2)
    }

    func testSameCopyWithTwoDifferentKept_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/b.jpg", "foto")])
        let p = plan(.hdd, history: history([(abs(leaving), kept), (abs(leaving), "Other/b.jpg")]), snapshot: s)
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.stays, [.conflictingKept: 2])
    }

    func testAlreadyRemovedFromThisArchive_stays() {
        onlyStay(plan(.hdd, alreadyRemoved: [normalizedIndexKey(leaving)]), .alreadyRemoved)
    }

    // MARK: - Condizioni 3 e 4: l'SSD

    func testCopyBackOnTheSSD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(ssd: [local(kept, "foto"), local(leaving, "foto")])), .backOnSSD)
    }

    func testCopyBackOnTheSSD_evenIfUnreadable_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local(leaving, "?", status: .unreadable)])
        onlyStay(plan(.cubbit, snapshot: s), .backOnSSD)
    }

    func testKeptCopyMissingOnTheSSD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(ssd: [])), .keptNotOnSSD)
    }

    func testKeptCopyUnreadableOnTheSSD_stays() {
        onlyStay(plan(.cubbit, snapshot: snapshot(ssd: [local(kept, "?", status: .changedWhileReading)])), .keptNotOnSSD)
    }

    func testKeptCopyTwiceOnTheSSD_stays() {
        let s = snapshot(ssd: [local(kept, "foto"), local("foto iphone/0/a.jpg", "foto")])
        onlyStay(plan(.hdd, snapshot: s), .keptNotOnSSD)
    }

    // MARK: - Condizione 2 e 5: l'archivio

    func testCopyNotOnTheArchive_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(kept, "foto")])), .notInArchive)
        onlyStay(plan(.cubbit, snapshot: snapshot(s3: [object(kept, "foto")])), .notInArchive)
    }

    func testKeptCopyNotOnTheArchive_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "foto")])), .keptNotInArchive)
        onlyStay(plan(.cubbit, snapshot: snapshot(s3: [object(leaving, "foto")])), .keptNotInArchive)
    }

    func testTwoPathsThatDifferOnlyByCase_onTheHDD_stay() {
        let s = snapshot(hdd: [local(leaving, "foto"), local(leaving.uppercased(), "foto"), local(kept, "foto")])
        onlyStay(plan(.hdd, snapshot: s), .pathCollision)
    }

    func testTwoCubbitKeysThatBecomeTheSamePath_stay() {
        let s = snapshot(s3: [object(leaving, "foto"), object(kept, "foto"), object(kept.lowercased(), "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .pathCollision)
    }

    func testUnreadableOnTheHDD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "?", status: .unreadable), local(kept, "foto")])),
                 .unreadableInArchive)
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "foto"), local(kept, "?", status: .changedWhileReading)])),
                 .unreadableInArchive)
    }

    func testDifferentContentOnTheHDD_stays() {
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "altra"), local(kept, "foto")])), .contentDiffers)
        // Le due copie sull'HDD uguali fra loro, ma diverse dalla tenuta sull'SSD, CON LA STESSA
        // DIMENSIONE (altrimenti lo direbbe gia' il confronto delle dimensioni: mutante M04).
        onlyStay(plan(.hdd, snapshot: snapshot(hdd: [local(leaving, "fata"), local(kept, "fata")])), .contentDiffers)
    }

    func testCubbitObjectNotCertifiable_stays() {
        let s = snapshot(s3: [object(leaving, "foto", etag: "\"non-un-etag\""), object(kept, "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .notCertifiable)
    }

    func testCubbitObjectKnownOnlyByItsMD5_stays() {
        // ETag a parte unica che nessun file locale produce: contenuto solo su Cubbit.
        let s = snapshot(s3: [object(leaving, "foto"), object(kept, "foto", etag: "\"\(digest("sconosciuta").md5)\"")])
        onlyStay(plan(.cubbit, snapshot: s), .notCertifiable)
    }

    func testCubbitObjectWithAnotherKnownContent_stays() {
        // La copia su Cubbit ha il contenuto di un'altra foto che c'e' sull'SSD.
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/z.jpg", "zeta")],
                         s3: [object(leaving, "zeta"), object(kept, "foto")])
        onlyStay(plan(.cubbit, snapshot: s), .contentDiffers)
    }

    func testDefence_aCopyThatIsTheKeptCopyOfAnother_neverLeaves() {
        let a = AlignmentCandidate(archive: .hdd, leavingKey: "x", keptKey: "y", leavingPath: "X", keptPath: "Y",
                                   ssdLeavingPath: "X", ssdKeptPath: "Y", ssdKeptSize: 1, size: 1, sha256: "s",
                                   leavingETag: nil, keptETag: nil)
        let b = AlignmentCandidate(archive: .hdd, leavingKey: "y", keptKey: "z", leavingPath: "Y", keptPath: "Z",
                                   ssdLeavingPath: "Y", ssdKeptPath: "Z", ssdKeptSize: 1, size: 1, sha256: "s",
                                   leavingETag: nil, keptETag: nil)
        let r = AlignmentPlanner.dropLeavingThatIsKept([a, b])
        XCTAssertEqual(r.kept.map(\.leavingKey), ["x"])
        XCTAssertEqual(r.dropped.map(\.leavingKey), ["y"])
    }

    // MARK: - Conti, ordine, blocchi

    func testEveryHistoryCopyIsEitherACandidateOrHasAReason() {
        let s = snapshot(ssd: [local(kept, "foto"), local("Other/b.jpg", "b")],
                         hdd: [local(leaving, "foto"), local(kept, "foto"), local("Other/c.jpg", "b"), local("Other/b.jpg", "b")])
        let h = history([(abs(leaving), kept), (abs(leaving), kept), (abs("Other/c.jpg"), "Other/b.jpg"),
                         (abs("Other/d.jpg"), "Other/b.jpg"), (abs("x.jpg"), nil), ("/altrove/y.jpg", kept)])
        let p = plan(.hdd, history: h, snapshot: s)
        XCTAssertEqual(p.candidates.count + p.stayCount, p.historyCopies)
        XCTAssertEqual(p.historyCopies, 6)
        XCTAssertEqual(p.candidates.count, 2)
    }

    func testCandidatesAreOrderedByKeptCopy() {
        let s = snapshot(ssd: [local("B/k.jpg", "b"), local("A/k.jpg", "a")],
                         hdd: [local("B/k.jpg", "b"), local("A/k.jpg", "a"), local("Z/1.jpg", "a"), local("Y/2.jpg", "b")])
        let p = plan(.hdd, history: history([(abs("Y/2.jpg"), "B/k.jpg"), (abs("Z/1.jpg"), "A/k.jpg")]), snapshot: s)
        XCTAssertEqual(p.candidates.map(\.leavingPath), ["Z/1.jpg", "Y/2.jpg"])
    }

    func testBlocks_respectFileAndByteCaps_neverEmpty() {
        func c(_ i: Int, _ size: Int64) -> AlignmentCandidate {
            AlignmentCandidate(archive: .hdd, leavingKey: "\(i)", keptKey: "k", leavingPath: "\(i)", keptPath: "k",
                               ssdLeavingPath: "\(i)", ssdKeptPath: "k", ssdKeptSize: size, size: size, sha256: "s",
                               leavingETag: nil, keptETag: nil)
        }
        let five = (0..<5).map { c($0, 10) }
        XCTAssertEqual(AlignmentRunPlan.blocks(five, fileCap: 2, byteCap: 1_000).map(\.count), [2, 2, 1])
        XCTAssertEqual(AlignmentRunPlan.blocks(five, fileCap: 100, byteCap: 25).map(\.count), [2, 2, 1])
        // Una copia piu' grande del tetto ha un blocco tutto suo.
        XCTAssertEqual(AlignmentRunPlan.blocks([c(0, 5), c(1, 500), c(2, 5)], fileCap: 100, byteCap: 100).map(\.count), [1, 1, 1])
        XCTAssertEqual(AlignmentRunPlan.blocks([]).count, 0)
    }

    func testCubbitVerdict_matchesTheClassifier() {
        // «Una regola sola»: per ogni oggetto Cubbit, il controllo certifica lo stesso contenuto
        // che l'inventario mostra presente su Cubbit.
        let s = InventorySnapshot(ssd: [local("a.jpg", "uno"), local("b.jpg", "due")],
                                  hdd: [local("a.jpg", "uno"), local("c.jpg", "tre")],
                                  s3: [object("a.jpg", "uno"), object("c.jpg", "tre"), object("d.jpg", "solo-cubbit"),
                                       object("e.jpg", "uno", etag: "\"rotto\"")],
                                  states: states())
        let candidates = AlignmentPlanner.localETagCandidates(s)
        let onCubbit = Set(InventoryClassifier.classify(s).items.filter { $0.presentOn.contains(.s3) }.map(\.id))
        for o in s.s3 {
            if case .certified(let sha) = S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: candidates[o.size] ?? []) {
                XCTAssertTrue(onCubbit.contains(sha), o.displayKey)
            }
        }
        XCTAssertEqual(onCubbit.filter { !$0.contains(":") }.count, 2)
    }

    // MARK: - Lettura della storia

    func testHistoryReader_readsEveryLine_andCountsTheBrokenOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trash-history.jsonl")
        let history = try TrashHistory(url: url)
        history.append(blockId: "b1", trashed: [TrashedItem(batchId: "b1", originalDisplayPath: abs(leaving), originalKey: "k",
                                                            trashedPath: "/t", size: 1, hash: "h", trashedAt: Date(), keptPath: kept)])
        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile(); fh.write(Data("non json\n\n".utf8)); try fh.close()
        let r = TrashHistoryReader.read(url: url)
        XCTAssertFalse(r.unreadable)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].keptPaths ?? [], [kept])
        XCTAssertEqual(r.malformedLines, 1)
        let missing = TrashHistoryReader.read(url: dir.appendingPathComponent("non-c-e.jsonl"))
        XCTAssertFalse(missing.unreadable)
        XCTAssertTrue(missing.entries.isEmpty)
    }
}
