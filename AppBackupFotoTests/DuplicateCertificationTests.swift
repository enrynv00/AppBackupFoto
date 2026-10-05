import XCTest
@testable import AppBackupFoto

/// Doppioni sull'SSD con la garanzia dell'inventario (ROADMAP #46, ADR-0017): quando un gruppo
/// si puo' spuntare. Ogni motivo di «non spuntabile» della spec ha qui almeno un test, e ogni
/// precedenza il suo.
///
/// Convenzione dei dati finti (la stessa di `InventoryClassifierTests`): il contenuto «X» ha
/// SHA256 "sha-X" e MD5 fatto di 32 volte la lettera X (a-f); l'oggetto Cubbit con ETag uguale
/// a quell'MD5 e' la stessa foto. L'hash di un gruppo di doppioni e' quindi "sha-X".
final class DuplicateCertificationTests: XCTestCase {

    // MARK: - Dati finti

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func file(_ path: String, _ content: Character, status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1, status: status,
                           digest: status == .ok
                               ? ContentDigest(size: 10, sha256: "sha-\(content)", md5: md5(content), multipartETag: nil)
                               : nil,
                           hashedAt: 2)
    }

    private func object(_ key: String, _ content: Character) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: 10, etag: "\"\(md5(content))\"")
    }

    private func state(_ a: InventoryArchive, complete: Bool = true, runId: Int64 = 7,
                       startedAt: Double = 1_000, finishedAt: Double? = 5_000) -> InventoryArchiveState {
        InventoryArchiveState(archive: a, runId: runId, complete: complete, reason: complete ? nil : .interrupted,
                              unreadable: 0, startedAt: startedAt, finishedAt: finishedAt)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true,
                        runId: Int64 = 7) -> [InventoryArchive: InventoryArchiveState] {
        [.ssd: state(.ssd, complete: ssd, runId: runId), .hdd: state(.hdd, complete: hdd, runId: runId),
         .s3: state(.s3, complete: s3, runId: runId)]
    }

    private func entry(_ path: String, _ content: Character) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1,
                          hash: "sha-\(content)", hashedAt: 2)
    }

    private func group(_ content: Character, _ paths: [String]) -> DuplicateGroup {
        DuplicateGroup(hash: "sha-\(content)", size: 10, members: paths.map { entry($0, content) })
    }

    /// La foto «a» in due copie sull'SSD, al sicuro su HDD e Cubbit: il caso spuntabile.
    private func safeSnapshot(states: [InventoryArchive: InventoryArchiveState]? = nil) -> InventorySnapshot {
        InventorySnapshot(ssd: [file("Foto iPhone/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                          hdd: [file("Foto iPhone/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                          s3: [object("Foto iPhone/a.jpg", "a")],
                          states: states ?? self.states())
    }

    private let safeGroup = DuplicateGroup(hash: "sha-a", size: 10, members: [
        LibraryIndexEntry(path: normalizedIndexKey("Foto iPhone/a.jpg"), displayPath: "Foto iPhone/a.jpg",
                          size: 10, mtime: 1, hash: "sha-a", hashedAt: 2),
        LibraryIndexEntry(path: normalizedIndexKey("Takeout/a.jpg"), displayPath: "Takeout/a.jpg",
                          size: 10, mtime: 1, hash: "sha-a", hashedAt: 2)])

    private func certify(_ snapshot: InventorySnapshot, _ groups: [DuplicateGroup], lastWrite: Date? = nil) -> DuplicateCertification {
        DuplicateCertification(basis: DuplicateCertificationBasis(snapshot: snapshot), lastArchiveWriteAt: lastWrite, groups: groups)
    }

    // MARK: - Freschezza

    func testNoInventory_isNeverRun() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: [:], lastArchiveWriteAt: nil), .neverRun)
    }

    func testCompleteAndNoBackupAfter_isFresh_withRunAndTimes() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: Date(timeIntervalSince1970: 999)),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: nil),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
    }

    /// Basta UN archivio letto a meta' (ADR-0015: incompleto non e' assente).
    func testAnyArchiveIncomplete_isIncomplete() {
        for s in [states(ssd: false), states(hdd: false), states(s3: false)] {
            XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
        }
    }

    func testAMissingArchive_isIncomplete() {
        var s = states()
        s[.s3] = nil
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
    }

    func testStatesOfDifferentRuns_areIncomplete() {
        var s = states()
        s[.hdd] = state(.hdd, runId: 8)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: nil), .incomplete)
    }

    /// Il backup e' finito DURANTE il giro (dopo l'inizio, prima della fine): l'inventario e' gia'
    /// vecchio. Un mutante che confrontasse con la fine del giro lo direbbe fresco. (verificato)
    func testBackupFinishedAfterTheStartOfTheRun_makesItOlder() {
        let backup = Date(timeIntervalSince1970: 4_000)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: backup),
                       .olderThanLastBackup(backupAt: backup, startedAt: 1_000, finishedAt: 5_000))
    }

    /// Il confronto e' stretto: un backup finito non dopo l'inizio (qui: nello stesso istante) non invecchia niente.
    func testBackupFinishedNotAfterTheStart_keepsItFresh() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(), lastArchiveWriteAt: Date(timeIntervalSince1970: 1_000)),
                       .fresh(runId: 7, startedAt: 1_000, finishedAt: 5_000))
    }

    /// L'inizio del giro e' il PIU' VECCHIO dei tre (oggi coincidono, ma non e' imposto dal tipo).
    func testTheStartOfTheRun_isTheEarliestOfTheThree() {
        let s: [InventoryArchive: InventoryArchiveState] = [.ssd: state(.ssd, startedAt: 300),
                                                            .hdd: state(.hdd, startedAt: 100),
                                                            .s3: state(.s3, startedAt: 200)]
        let backup = Date(timeIntervalSince1970: 150)
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: s, lastArchiveWriteAt: backup),
                       .olderThanLastBackup(backupAt: backup, startedAt: 100, finishedAt: 5_000))
    }

    func testIncomplete_winsOverOlderThanTheLastBackup() {
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: states(hdd: false),
                                                            lastArchiveWriteAt: Date(timeIntervalSince1970: 9_999)),
                       .incomplete)
    }

    // MARK: - Il gruppo

    func testSafeContent_withEveryCopyInTheSSDInventory_isSelectable() {
        let c = certify(safeSnapshot(), [safeGroup])
        XCTAssertNil(c.block(for: "sha-a"))
        XCTAssertTrue(c.isSelectable("sha-a"))
        XCTAssertEqual(c.certifiedRunId, 7)
        XCTAssertEqual(c.inventoryFinishedAt, Date(timeIntervalSince1970: 5_000))
    }

    func testContentMissingFromCubbit_isNotSafeOnAllThree() {
        var snap = safeSnapshot()
        snap.s3 = []
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// ❗ non e' ✅: stessa foto su tutti e tre, ma lo stesso percorso ha un altro contenuto su HDD.
    func testContentToBeChecked_isNotSafeOnAllThree() {
        var snap = safeSnapshot()
        snap.hdd[0] = file("Foto iPhone/a.jpg", "b")
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// Una terza copia comparsa dopo l'inventario (un ripristino, una copia dal Finder): non e'
    /// coperta, anche se il contenuto e' al sicuro.
    func testACopyNotInTheSSDInventory_isChangedAfterInventory() {
        let g = group("a", ["Foto iPhone/a.jpg", "Takeout/a.jpg", "Other/nuova.jpg"])
        XCTAssertEqual(certify(safeSnapshot(), [g]).block(for: "sha-a"), .changedAfterInventory)
    }

    /// Lo stesso percorso aveva un altro contenuto quando l'inventario l'ha letto.
    func testACopyWithAnotherContentInTheSSDInventory_isChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.ssd.append(file("Other/b.jpg", "b"))
        snap.hdd.append(file("Other/b.jpg", "b"))
        snap.s3.append(object("Other/b.jpg", "b"))
        let g = group("a", ["Foto iPhone/a.jpg", "Other/b.jpg"])
        XCTAssertEqual(certify(snap, [g]).block(for: "sha-a"), .changedAfterInventory)
    }

    func testACopyUnreadableInTheInventory_isChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.ssd[1] = file("Takeout/a.jpg", "a", status: .unreadable)
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .changedAfterInventory)
    }

    /// La regola vale anche per la copia che RESTA: qui manca dall'inventario solo il primo
    /// membro, che e' quello che `duplicateKeepChoice` terrebbe (Foto iPhone). (verificato)
    func testTheKeptCopyCountsToo() {
        var snap = safeSnapshot()
        snap.ssd.removeFirst()
        snap.ssd.append(file("Other/a.jpg", "a"))
        XCTAssertEqual(certify(snap, [safeGroup]).block(for: "sha-a"), .changedAfterInventory)
    }

    func testNotSafe_winsOverChangedAfterInventory() {
        var snap = safeSnapshot()
        snap.s3 = []
        let g = group("a", ["Foto iPhone/a.jpg", "Other/nuova.jpg"])
        XCTAssertEqual(certify(snap, [g]).block(for: "sha-a"), .notSafeOnAllThree)
    }

    /// Con l'inventario vecchio OGNI gruppo ha il motivo comune, anche quello che sarebbe certificato.
    func testWhenTheInventoryIsOld_everyGroupHasTheCommonReason() {
        let backup = Date(timeIntervalSince1970: 2_000)
        let c = certify(safeSnapshot(), [safeGroup], lastWrite: backup)
        XCTAssertEqual(c.block(for: "sha-a"), .inventoryOlderThanLastBackup(backupAt: backup))
        XCTAssertFalse(c.isSelectable("sha-a"))
        XCTAssertNil(c.certifiedRunId)
        XCTAssertNil(c.inventoryFinishedAt)
    }

    func testWhenNeverRunOrIncomplete_everyGroupSaysSo() {
        XCTAssertEqual(certify(InventorySnapshot(), [safeGroup]).block(for: "sha-a"), .inventoryNeverRun)
        XCTAssertEqual(certify(safeSnapshot(states: states(s3: false)), [safeGroup]).block(for: "sha-a"),
                       .inventoryIncomplete)
    }

    func testUnreadableInventory_blocksEverything() {
        let c = DuplicateCertification(basis: .unreadable, lastArchiveWriteAt: nil, groups: [safeGroup])
        XCTAssertEqual(c.freshness, .unreadable)
        XCTAssertEqual(c.block(for: "sha-a"), .inventoryUnreadable)
    }

    /// Un gruppo che non era fra quelli certificati non e' mai spuntabile, nemmeno con
    /// l'inventario fresco: la certificazione e' una lista di permessi, non di divieti. (verificato)
    func testAHashThatWasNotCertified_isNeverSelectable() {
        let c = certify(safeSnapshot(), [safeGroup])
        XCTAssertFalse(c.isSelectable("sha-z"))
        XCTAssertEqual(c.block(for: "sha-z"), .changedAfterInventory)
    }

    /// Da un giro incompleto non si ricava nessun contenuto «al sicuro», anche se la foto e' su
    /// tutti e tre: la base resta vuota. (verificato)
    func testAnIncompleteSnapshot_certifiesNoContent() {
        let basis = DuplicateCertificationBasis(snapshot: safeSnapshot(states: states(hdd: false)))
        XCTAssertTrue(basis.safeHashes.isEmpty)
        XCTAssertTrue(basis.ssdHashByKey.isEmpty)
        // Controllo: con il giro completo lo stesso gruppo e' certificato.
        XCTAssertNil(DuplicateCertification.groupBlock(safeGroup, basis: DuplicateCertificationBasis(snapshot: safeSnapshot())))
    }

    // MARK: - Il ricontrollo prima dello spostamento

    func testRunCheck_sameFreshRun_letsItGo() {
        XCTAssertNil(DuplicateCertification.runBlock(states: states(), lastArchiveWriteAt: nil, certifiedRunId: 7))
    }

    func testRunCheck_aNewerRun_stopsIt() {
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(runId: 8), lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryChangedSinceOpening)
    }

    func testRunCheck_aBackupAfterTheRun_stopsIt() {
        let backup = Date(timeIntervalSince1970: 6_000)
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(), lastArchiveWriteAt: backup, certifiedRunId: 7),
                       .inventoryOlderThanLastBackup(backupAt: backup))
    }

    func testRunCheck_incompleteOrUnreadable_stopsIt() {
        XCTAssertEqual(DuplicateCertification.runBlock(states: states(s3: false), lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryIncomplete)
        XCTAssertEqual(DuplicateCertification.runBlock(states: nil, lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryUnreadable)
        XCTAssertEqual(DuplicateCertification.runBlock(states: [:], lastArchiveWriteAt: nil, certifiedRunId: 7),
                       .inventoryNeverRun)
    }

    func testUncoveredGroupCount_countsTheGroupsTheCertificationDoesNotCover() {
        let other = group("b", ["Other/b1.jpg", "Other/b2.jpg"])
        let c = certify(safeSnapshot(), [safeGroup, other])
        let entries = [safeGroup, other].map { DuplicateBatch.Entry(group: $0, choice: duplicateKeepChoice($0, rule: nil)) }
        XCTAssertEqual(c.uncoveredGroupCount(in: DuplicateRunPlan(entries: entries)), 1)
        XCTAssertEqual(c.uncoveredGroupCount(in: DuplicateRunPlan(entries: [entries[0]])), 0)
    }

    // MARK: - Con il database vero

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateCertificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func storeWithACompleteRun(runId: Int64 = 7) throws -> LibraryIndexStore {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        let snap = safeSnapshot()
        try store.beginInventoryRun(runId: runId, startedAt: 1_000)
        try store.upsertInventoryLocal(snap.ssd, archive: .ssd, runId: runId)
        try store.upsertInventoryLocal(snap.hdd, archive: .hdd, runId: runId)
        try store.upsertInventoryS3(snap.s3, runId: runId)
        for a in InventoryArchive.allCases {
            try store.finishInventoryArchive(a, runId: runId, complete: true, reason: nil, unreadable: 0, finishedAt: 5_000)
        }
        return store
    }

    func testLoad_fromTheSavedInventory_certifiesTheSafeGroup() throws {
        let basis = DuplicateCertificationBasis.load(store: try storeWithACompleteRun(), reusing: nil)
        XCTAssertFalse(basis.readFailed)
        XCTAssertEqual(basis.safeHashes, ["sha-a"])
        XCTAssertEqual(basis.ssdHashByKey[normalizedIndexKey("Takeout/a.jpg")], "sha-a")
        XCTAssertTrue(DuplicateCertification(basis: basis, lastArchiveWriteAt: nil, groups: [safeGroup]).isSelectable("sha-a"))
    }

    func testLoad_withAnEmptyDatabase_isNeverRun() throws {
        let store = try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
        let c = DuplicateCertification(basis: .load(store: store, reusing: nil), lastArchiveWriteAt: nil, groups: [safeGroup])
        XCTAssertEqual(c.freshness, .neverRun)
    }

    /// Finche' gli stati dei tre archivi sono gli stessi, la base gia' calcolata si riusa (la
    /// classificazione di tutto l'inventario costa secondi); appena cambiano si ricalcola.
    func testLoad_reusesTheCachedBasisOnlyWhileTheStatesAreTheSame() throws {
        let store = try storeWithACompleteRun()
        let first = DuplicateCertificationBasis.load(store: store, reusing: nil)
        let fake = DuplicateCertificationBasis(snapshot: InventorySnapshot(
            ssd: [file("Z/z.jpg", "c")], hdd: [file("Z/z.jpg", "c")], s3: [object("Z/z.jpg", "c")], states: first.states))
        XCTAssertEqual(DuplicateCertificationBasis.load(store: store, reusing: fake).safeHashes, ["sha-c"],
                       "stati uguali: doveva riusare la base gia' calcolata")

        try store.beginInventoryRun(runId: 8, startedAt: 6_000)
        let after = DuplicateCertificationBasis.load(store: store, reusing: fake)
        XCTAssertTrue(after.safeHashes.isEmpty, "stati cambiati (giro nuovo in corso): doveva rileggere")
        XCTAssertEqual(DuplicateInventoryFreshness.evaluate(states: after.states, lastArchiveWriteAt: nil), .incomplete)
    }
}
