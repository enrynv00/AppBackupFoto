import XCTest
@testable import AppBackupFoto

/// Il registro del progetto 4 (ROADMAP #47, ADR-0019): in sola aggiunta, una riga per evento,
/// e lo stato che se ne ricava (cosa e' gia' tolto, cosa rimette a posto «Annulla l'ultimo blocco»).
final class AlignmentLogTests: XCTestCase {
    private var tmp: URL!
    private var url: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AlignmentLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        url = tmp.appendingPathComponent("alignment-hdd.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func pending(_ id: String, block: String = "b1", archive: AlignmentArchive = .hdd,
                         path: String = "Takeout/a.jpg", at: Double = 100) -> AlignmentLogEntry {
        AlignmentLogEntry(event: .pending, id: id, blockId: block, archive: archive, at: Date(timeIntervalSince1970: at),
                          leavingPath: path, leavingKey: normalizedIndexKey(path), keptPath: "Foto iPhone/0/A.JPG",
                          size: 4, sha256: "sha", etag: archive == .cubbit ? "etag" : nil,
                          originalAbsolutePath: archive == .hdd ? "/Volumes/BackupHDD/" + path : nil)
    }

    private func event(_ e: AlignmentLogEntry.Event, _ id: String, block: String = "b1", archive: AlignmentArchive = .hdd,
                       at: Double = 101, trashed: String? = nil, marker: String? = nil) -> AlignmentLogEntry {
        AlignmentLogEntry(event: e, id: id, blockId: block, archive: archive, at: Date(timeIntervalSince1970: at),
                          trashedPath: trashed, deleteMarkerVersionId: marker)
    }

    func testAppend_thenRead_roundTrips_andTheFileIsPrivate() throws {
        let store = try AlignmentLogStore(url: url)
        let p = pending("1")
        try store.append(p)
        try store.append(event(.removed, "1", trashed: "/Volumes/BackupHDD/.Trashes/501/a.jpg"))
        let r = store.read()
        XCTAssertFalse(r.unreadable)
        XCTAssertEqual(r.malformedLines, 0)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.entries[0], p)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testAppend_neverRewritesEarlierLines() throws {
        try AlignmentLogStore(url: url).append(pending("1"))
        let before = try Data(contentsOf: url)
        try AlignmentLogStore(url: url).append(pending("2"))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(before.count), before)
        XCTAssertEqual(try AlignmentLogStore(url: url).read().entries.map(\.id), ["1", "2"])
    }

    func testState_pendingPlusRemoved_isARemoval_withEveryField() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), event(.removed, "1", trashed: "/T/a.jpg")])
        XCTAssertEqual(s.removals.count, 1)
        let r = s.removals[0]
        XCTAssertEqual(r.leavingPath, "Takeout/a.jpg")
        XCTAssertEqual(r.leavingKey, "takeout/a.jpg")
        XCTAssertEqual(r.trashedPath, "/T/a.jpg")
        XCTAssertEqual(r.originalAbsolutePath, "/Volumes/BackupHDD/Takeout/a.jpg")
        XCTAssertEqual(r.removedAt, Date(timeIntervalSince1970: 101))
        XCTAssertNil(r.restoredAt)
        XCTAssertTrue(s.unfinished.isEmpty)
        XCTAssertEqual(s.removedKeys, ["takeout/a.jpg"])
    }

    func testState_pendingWithoutOutcome_isUnfinished_notARemoval() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), pending("2", path: "b.jpg"), event(.failed, "2")])
        XCTAssertTrue(s.removals.isEmpty)
        XCTAssertEqual(s.unfinished.map(\.id), ["1"])
        XCTAssertTrue(s.removedKeys.isEmpty)
    }

    func testState_restoredCopiesAreNotRemovedAnymore() {
        let s = AlignmentLogState(archive: .hdd, entries: [pending("1"), event(.removed, "1"), event(.restored, "1", at: 200)])
        XCTAssertEqual(s.removals[0].restoredAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(s.removedKeys.isEmpty)
        XCTAssertTrue(s.lastBlockToRestore.isEmpty)
        XCTAssertNil(s.lastBlockSummary)
    }

    func testState_onlyTheRequestedArchive() {
        let entries = [pending("1", archive: .cubbit), event(.removed, "1", archive: .cubbit, marker: "v1"), pending("2"), event(.removed, "2")]
        XCTAssertEqual(AlignmentLogState(archive: .cubbit, entries: entries).removals.map(\.id), ["1"])
        XCTAssertEqual(AlignmentLogState(archive: .cubbit, entries: entries).removals.first?.deleteMarkerVersionId, "v1")
        XCTAssertEqual(AlignmentLogState(archive: .hdd, entries: entries).removals.map(\.id), ["2"])
    }

    func testLastBlock_isTheBlockOfTheLastRemoval_withoutTheRestoredOnes() {
        let entries = [pending("1", block: "A"), event(.removed, "1", block: "A", at: 101),
                       pending("2", block: "B", path: "b.jpg"), event(.removed, "2", block: "B", at: 102),
                       pending("3", block: "B", path: "c.jpg"), event(.removed, "3", block: "B", at: 103),
                       event(.restored, "2", block: "B", at: 300)]
        let s = AlignmentLogState(archive: .hdd, entries: entries)
        XCTAssertEqual(s.lastBlockToRestore.map(\.id), ["3"])
        XCTAssertEqual(s.lastBlockSummary, RestorableBatchSummary(pendingCount: 1, batchCount: 2, trashedAt: Date(timeIntervalSince1970: 103)))
        // Il blocco A non torna mai «ultimo» per aver rimesso a posto il B (un livello solo).
        let allBack = AlignmentLogState(archive: .hdd, entries: entries + [event(.restored, "3", block: "B", at: 301)])
        XCTAssertTrue(allBack.lastBlockToRestore.isEmpty)
        XCTAssertNil(allBack.lastBlockSummary)
    }

    func testBrokenLines_areCounted_andTheOthersAreRead() throws {
        let store = try AlignmentLogStore(url: url)
        try store.append(pending("1"))
        let fh = try FileHandle(forWritingTo: url); fh.seekToEndOfFile()
        fh.write(Data("{\"event\":\"removed\"}\nnon json\n".utf8)); try fh.close()
        try store.append(event(.removed, "1"))
        let r = store.read()
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.malformedLines, 2)
        XCTAssertEqual(store.state(for: .hdd)?.malformedLines, 2)
        XCTAssertEqual(store.state(for: .hdd)?.removals.count, 1)
    }

    func testOldOrPartialLine_decodesWithTheOptionalFieldsMissing() throws {
        let json = #"{"event":"failed","id":"9","blockId":"b","archive":"cubbit","at":0}"#
        let e = try JSONDecoder().decode(AlignmentLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.event, .failed)
        XCTAssertNil(e.leavingPath)
        XCTAssertNil(e.detail)
    }

    func testMissingFile_isAnEmptyLog_unreadableFileIsNot() throws {
        let store = try AlignmentLogStore(url: url)
        XCTAssertEqual(store.state(for: .hdd)?.removals.count, 0)
        try store.append(pending("1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertTrue(store.read().unreadable)
        XCTAssertNil(store.state(for: .hdd))
    }

    func testAppendFails_loudly_whenTheFileCannotBeWritten() throws {
        let store = try AlignmentLogStore(url: url)
        try store.append(pending("1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.append(pending("2")))
    }

    func testLocationOutsideTheAllowList_isRefused() {
        XCTAssertThrowsError(try AlignmentLogStore(url: URL(fileURLWithPath: "/Volumes/BackupHDD/alignment-hdd.jsonl")))
    }

    func testConcurrentAppends_loseNoLine() throws {
        let store = try AlignmentLogStore(url: url)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<50 { try? store.append(self.pending("\(t)-\(i)", path: "f\(t)-\(i).jpg")) }
        }
        let r = store.read()
        XCTAssertEqual(r.entries.count, 400)
        XCTAssertEqual(r.malformedLines, 0)
    }
}
