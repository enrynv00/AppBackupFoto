import XCTest
@testable import AppBackupFoto

/// Un Cubbit finto con le versioni: ogni chiave ha la sua storia (la piu' recente in fondo), un
/// DELETE senza versione aggiunge un segno di cancellazione se le versioni sono accese e cancella
/// tutto se sono spente; togliere una versione la toglie QUALUNQUE essa sia — anche una versione
/// di dati: e' il motore che non deve mai chiederlo, e i test lo verificano.
nonisolated final class FakeAlignmentCloud: AlignmentCloud, @unchecked Sendable {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "rete finta giu'" } }
    struct Version { let id: String; let data: Data? }   // `data == nil`: segno di cancellazione

    private let lock = NSLock()
    private var store: [String: [Version]] = [:]
    private var next = 0
    private var _versioning: S3Syncer.BucketVersioning = .enabled
    private var _rules = [S3Syncer.LifecycleRule(id: "r1", enabled: true, wholeBucket: true, noncurrentDays: 30, expiresCurrentObjects: false)]
    private var _deletes: [String] = []
    private var _markerRemovals: [(key: String, versionId: String)] = []
    var failVersioning = false, failHead = false, failDelete = false, failVersions = false, failRemoveMarker = false
    /// Cubbit che dice «versioni accese» ma cancella senza segno.
    var deleteWithoutMarker = false

    static func md5(_ d: Data) -> String { var h = ContentHasher(); h.update(d); return h.finalize().md5 }

    var versioningState: S3Syncer.BucketVersioning {
        get { lock.withLock { _versioning } }
        set { lock.withLock { _versioning = newValue } }
    }
    var rules: [S3Syncer.LifecycleRule] {
        get { lock.withLock { _rules } }
        set { lock.withLock { _rules = newValue } }
    }
    var deletes: [String] { lock.withLock { _deletes } }
    var markerRemovals: [(key: String, versionId: String)] { lock.withLock { _markerRemovals } }

    func put(_ key: String, _ text: String) {
        lock.withLock { next += 1; store[key, default: []].append(Version(id: "v\(next)", data: Data(text.utf8))) }
    }
    func current(_ key: String) -> String? {
        lock.withLock { store[key]?.last?.data.map { String(decoding: $0, as: UTF8.self) } }
    }
    func versionCount(_ key: String) -> Int { lock.withLock { store[key]?.count ?? 0 } }
    func dataVersionIds(_ key: String) -> [String] { lock.withLock { (store[key] ?? []).filter { $0.data != nil }.map(\.id) } }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try lock.withLock {
            if failHead { throw Failure() }
            guard let d = store[key]?.last?.data else { return nil }
            return S3Syncer.S3ObjectHead(size: Int64(d.count), etag: "\"\(Self.md5(d))\"")
        }
    }
    func versioning() async throws -> S3Syncer.BucketVersioning {
        try lock.withLock { if failVersioning { throw Failure() }; return _versioning }
    }
    func lifecycleRules() async throws -> [S3Syncer.LifecycleRule] { lock.withLock { _rules } }
    func delete(key: String) async throws -> S3Syncer.DeleteResult {
        try lock.withLock {
            if failDelete { throw Failure() }
            _deletes.append(key)
            if _versioning == .enabled && !deleteWithoutMarker {
                next += 1
                let id = "m\(next)"
                store[key, default: []].append(Version(id: id, data: nil))
                return S3Syncer.DeleteResult(isDeleteMarker: true, versionId: id)
            }
            store[key] = nil
            return S3Syncer.DeleteResult(isDeleteMarker: false, versionId: nil)
        }
    }
    func versions(key: String) async throws -> [S3Syncer.VersionEntry] {
        try lock.withLock {
            if failVersions { throw Failure() }
            let list = store[key] ?? []
            return list.enumerated().map { i, v in
                S3Syncer.VersionEntry(key: key, versionId: v.id, isLatest: i == list.count - 1, isDeleteMarker: v.data == nil,
                                      etag: v.data.map { "\"\(Self.md5($0))\"" }, size: v.data.map { Int64($0.count) })
            }
        }
    }
    func removeDeleteMarker(key: String, versionId: String) async throws -> S3Syncer.DeleteResult {
        try lock.withLock {
            if failRemoveMarker { throw Failure() }
            _markerRemovals.append((key, versionId))
            guard let i = store[key]?.firstIndex(where: { $0.id == versionId }) else {
                return S3Syncer.DeleteResult(isDeleteMarker: false, versionId: versionId)
            }
            let wasMarker = store[key]![i].data == nil
            store[key]!.remove(at: i)
            return S3Syncer.DeleteResult(isDeleteMarker: wasMarker, versionId: versionId)
        }
    }
}

/// Il motore del progetto 4 su Cubbit (ROADMAP #47, ADR-0019), con l'SSD in una cartella
/// temporanea e un Cubbit finto con le versioni.
final class AlignmentEngineCubbitTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var store: AlignmentLogStore!
    private var cloud: FakeAlignmentCloud!
    private let leaving = "Takeout/Google Photos/IMG_2906 (1).JPG"
    private let kept = "Foto iPhone/0/A.JPG"
    private let content = "foto identica"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("AlignmentEngineCubbitTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: ssd, withIntermediateDirectories: true)
        store = try AlignmentLogStore(url: tmp.appendingPathComponent("alignment-cubbit.jsonl"))
        cloud = FakeAlignmentCloud()
        try put(ssd, kept, content)
        cloud.put(leaving, content)
        cloud.put(kept, content)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func digest(_ text: String) -> ContentDigest { var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize() }

    private func candidate(_ l: String? = nil, archive: AlignmentArchive = .cubbit, leavingETag: String?? = nil) -> AlignmentCandidate {
        let lp = l ?? leaving, d = digest(content)
        return AlignmentCandidate(archive: archive, leavingKey: normalizedIndexKey(lp), keptKey: normalizedIndexKey(kept),
                                  leavingPath: lp, keptPath: kept, ssdLeavingPath: lp, ssdKeptPath: kept, ssdKeptSize: d.size,
                                  size: d.size, sha256: d.sha256, leavingETag: leavingETag ?? d.md5, keptETag: d.md5)
    }

    private func engine(log: (@Sendable (AlignmentLogEntry) throws -> Void)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil) -> ArchiveAligner {
        let s = store!
        return ArchiveAligner(ssdRoot: ssd, hddRoot: nil, cloud: cloud, log: log ?? { try s.append($0) },
                              volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) })
    }

    private func run(_ block: [AlignmentCandidate], engine e: ArchiveAligner? = nil, cancelAfter: Int? = nil) async -> AlignmentBlockOutcome {
        let counter = AlignmentTestCounter()
        return await (e ?? engine()).runCubbitBlock(block, blockId: "b1",
                                                    isCancelled: { cancelAfter.map { counter.value >= $0 } ?? false },
                                                    onProgress: { counter.set($0) })
    }

    // MARK: - Il caso buono

    func testDeleteWithoutVersion_leavesADeleteMarker_andTheVersionStays() async {
        let o = await run([candidate()])
        XCTAssertNil(o.stop)
        XCTAssertEqual(o.removed.count, 1)
        XCTAssertEqual(cloud.deletes, [leaving])
        XCTAssertNil(cloud.current(leaving), "la copia non si vede piu'")
        XCTAssertEqual(cloud.dataVersionIds(leaving).count, 1, "la versione della foto resta")
        XCTAssertEqual(cloud.current(kept), content)
        let entries = store.read().entries
        XCTAssertEqual(entries.map(\.event), [.pending, .removed])
        XCTAssertEqual(entries[0].etag, digest(content).md5)
        XCTAssertEqual(entries[1].deleteMarkerVersionId, "m3")
        XCTAssertNil(entries[0].originalAbsolutePath)
    }

    // MARK: - Condizione 7: le versioni, prima di ogni blocco

    func testVersionsNotEnabled_theBlockDoesNotStart() async {
        cloud.versioningState = .neverEnabled
        let o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.versioningNotEnabled(.neverEnabled)))
        XCTAssertTrue(cloud.deletes.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
        cloud.versioningState = .suspended
        let s = await run([candidate()])
        XCTAssertEqual(s.stop, .cubbitNotReady(.versioningNotEnabled(.suspended)))
    }

    func testMissingOrShortExpiryRule_theBlockDoesNotStart() async {
        cloud.rules = []
        var o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.noExpiryRule))
        cloud.rules = [.init(id: "r", enabled: true, wholeBucket: true, noncurrentDays: 3, expiresCurrentObjects: false)]
        o = await run([candidate()])
        XCTAssertEqual(o.stop, .cubbitNotReady(.expiryTooShort(days: 3)))
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testVersionsAreReadAgainBeforeEveryBlock() async {
        let e = engine()
        let first = await run([candidate()], engine: e)
        XCTAssertEqual(first.removed.count, 1)
        cloud.put("Other/b.jpg", content)
        cloud.versioningState = .suspended
        let second = await run([candidate("Other/b.jpg")], engine: e)
        XCTAssertEqual(second.stop, .cubbitNotReady(.versioningNotEnabled(.suspended)))
        XCTAssertEqual(cloud.current("Other/b.jpg"), content)
    }

    func testVersionsUnreadable_theBlockDoesNotStart() async {
        cloud.failVersioning = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    // MARK: - Il ricontrollo dal vivo

    func testCopyBackOnTheSSD_orKeptCopyGoneFromTheSSD_stays() async throws {
        try put(ssd, leaving, content)
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.backOnSSD: 1])
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(leaving))
        try FileManager.default.removeItem(at: ssd.appendingPathComponent(kept))
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.keptChangedOnSSD: 1])
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testKeptCopyMissingOrChangedOnCubbit_stays() async {
        let k = FakeAlignmentCloud(); k.put(leaving, content)
        cloud = k
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.keptMissingInArchive: 1])
        k.put(kept, "tenuta diversa")
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(k.deletes.isEmpty)
    }

    func testCopyGoneOrChangedOnCubbit_stays() async {
        let c = FakeAlignmentCloud(); c.put(kept, content)
        cloud = c
        var o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.goneFromArchive: 1])
        c.put(leaving, "un'altra foto")
        o = await run([candidate()])
        XCTAssertEqual(o.skipped, [.contentChanged: 1])
        XCTAssertTrue(c.deletes.isEmpty)
        XCTAssertTrue(store.read().entries.isEmpty)
    }

    func testUnsafeCandidates_stay() async {
        let o = await run([candidate(leavingETag: .some(nil)), candidate("_quarantena/2026-10-04/a.jpg"), candidate(archive: .hdd),
                           candidate(kept.lowercased())])
        XCTAssertEqual(o.skipped, [.unsafePath: 4])
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    // MARK: - I guasti che fermano la corsa

    func testHeadError_stops_beforeAnyDelete() async {
        cloud.failHead = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testDeleteError_stops_andTheLogSaysFailed() async {
        cloud.failDelete = true
        let o = await run([candidate()])
        guard case .cubbitError = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertEqual(store.read().entries.map(\.event), [.pending, .failed])
    }

    func testDeleteWithoutDeleteMarker_stopsImmediately() async {
        cloud.put("Other/b.jpg", content)
        cloud.deleteWithoutMarker = true
        let o = await run([candidate(), candidate("Other/b.jpg")])
        XCTAssertEqual(o.stop, .deleteWithoutMarker(path: leaving))
        XCTAssertEqual(cloud.deletes, [leaving], "nessun secondo DELETE dopo un DELETE senza segno")
        XCTAssertEqual(cloud.current("Other/b.jpg"), content)
        let last = store.read().entries.last
        XCTAssertEqual(last?.event, .removed)
        XCTAssertNil(last?.deleteMarkerVersionId)
    }

    func testLogNotWritable_noDelete() async {
        struct Broken: Error {}
        let o = await run([candidate()], engine: engine(log: { _ in throw Broken() }))
        guard case .logNotWritten = o.stop else { return XCTFail("\(String(describing: o.stop))") }
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testSSDMissingAtStart_noDelete() async {
        let ssdPath = ssd.path
        let o = await run([candidate()], engine: engine(volumeIdentity: { $0.path == ssdPath ? nil : deviceIdentifier(of: $0) }))
        XCTAssertEqual(o.stop, .volumeMissing(.ssd))
        XCTAssertTrue(cloud.deletes.isEmpty)
    }

    func testInterrupt_stopsBetweenCopies() async {
        cloud.put("Other/b.jpg", content)
        let o = await run([candidate(), candidate("Other/b.jpg")], cancelAfter: 1)
        XCTAssertEqual(o.stop, .interrupted)
        XCTAssertEqual(cloud.deletes, [leaving])
    }
}
