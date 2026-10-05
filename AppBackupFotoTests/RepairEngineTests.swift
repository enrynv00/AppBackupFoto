import XCTest
@testable import AppBackupFoto

/// Un Cubbit finto in memoria, con un interruttore per far fallire ogni richiesta. L'ETag di un
/// oggetto e' l'MD5 del suo contenuto, come per un caricamento unico.
nonisolated final class FakeRepairCloud: RepairCloud, @unchecked Sendable {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "rete finta giu'" } }
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var etagOverride: [String: String] = [:]
    private(set) var copies: [(from: String, to: String)] = []
    private(set) var replaces: [String] = []
    var failHead = false, failList = false, failCopy = false, failReplace = false
    /// La copia lato server scrive un contenuto diverso (per la verifica dopo la copia).
    var copyCorrupts = false
    /// Il caricamento scrive un contenuto diverso (per la verifica finale).
    var replaceCorrupts = false

    static func md5(_ d: Data) -> String { var h = ContentHasher(); h.update(d); return h.finalize().md5 }

    func put(_ key: String, _ text: String) { lock.withLock { objects[key] = Data(text.utf8) } }
    func data(_ key: String) -> String? { lock.withLock { objects[key].map { String(decoding: $0, as: UTF8.self) } } }
    func keys() -> [String] { lock.withLock { objects.keys.sorted() } }
    func remove(_ key: String) { lock.withLock { objects[key] = nil } }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try lock.withLock {
            if failHead { throw Failure() }
            guard let d = objects[key] else { return nil }
            return S3Syncer.S3ObjectHead(size: Int64(d.count), etag: "\"\(etagOverride[key] ?? Self.md5(d))\"")
        }
    }

    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo] {
        try lock.withLock {
            if failList { throw Failure() }
            return objects.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                .map { S3Syncer.S3ObjectInfo(key: $0.key, size: Int64($0.value.count), etag: "\"\(Self.md5($0.value))\"") }
        }
    }

    func copy(from sourceKey: String, to destinationKey: String) async throws {
        try lock.withLock {
            if failCopy { throw Failure() }
            copies.append((sourceKey, destinationKey))
            objects[destinationKey] = copyCorrupts ? Data("guasta".utf8) : objects[sourceKey]
        }
    }

    func replace(key: String, withFileAt url: URL) async throws {
        let d = try Data(contentsOf: url)
        try lock.withLock {
            if failReplace { throw Failure() }
            replaces.append(key)
            objects[key] = replaceCorrupts ? Data(d.reversed()) : d
        }
    }
}

/// Il motore della riparazione (ROADMAP #45, ADR-0016) su cartelle temporanee al posto di SSD e
/// HDD e un Cubbit finto. Per ogni passo che puo' fallire c'e' un test che pretende che tutto
/// resti com'era (o, dopo la quarantena, che la copia rovinata non vada mai persa).
final class RepairEngineTests: XCTestCase {
    private var tmp: URL!
    private var ssd: URL!
    private var hdd: URL!
    private var log: RepairLogStore!
    private var cloud: FakeRepairCloud!
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let good = "foto integra, letta su SSD e HDD"
    private let bad  = "foto rovinata, ultimi byte a zero"   // stessa lunghezza non serve: conta l'impronta
    /// 2026-10-04T12:00:00Z: a Roma e' il 4 ottobre.
    private let today = Date(timeIntervalSince1970: 1_791_115_200)
    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: realResolvedPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("RepairEngineTests-\(UUID().uuidString)")
        ssd = tmp.appendingPathComponent("SSD")
        hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd!, hdd!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        log = try RepairLogStore(url: tmp.appendingPathComponent("repair-log.json"))
        cloud = FakeRepairCloud()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Aiuti

    private func put(_ root: URL, _ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func digest(_ text: String) -> ContentDigest {
        var h = ContentHasher(); h.update(Data(text.utf8)); return h.finalize()
    }

    /// Tutti i file sotto una radice, percorso relativo → contenuto: per dire «tutto com'era».
    private func tree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        while let u = e.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[String(u.path.dropFirst(base.count + 1))] = String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self)
        }
        return out
    }

    private func engine(record: (@Sendable (RepairRecord) throws -> Void)? = nil,
                        hashFile: (@Sendable (URL) -> ContentReadOutcome)? = nil,
                        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil,
                        renameFile: (@Sendable (URL, URL) throws -> Void)? = nil,
                        volumeIdentity: (@Sendable (URL) -> dev_t?)? = nil,
                        now: Date? = nil) -> RepairEngine {
        let store = log!
        let when = now ?? today
        return RepairEngine(ssdRoot: ssd, hddRoot: hdd, cloud: cloud,
                            record: record ?? { try store.record($0) },
                            now: { when }, calendar: rome,
                            hashFile: hashFile ?? { ContentHasher.digestFile(at: $0) },
                            copyFile: copyFile ?? { try FileManager.default.copyItem(at: $0, to: $1) },
                            renameFile: renameFile ?? { try RepairEngine.renameWithoutOverwriting(from: $0, to: $1) },
                            volumeIdentity: volumeIdentity ?? { deviceIdentifier(of: $0) },
                            makeToken: { "1a2b3c4d" })
    }

    /// Rovinata su Cubbit: la situazione del 2026-10-01.
    private func brokenOnCubbit() throws -> RepairCandidate {
        try put(ssd, path, good)
        try put(hdd, path, good)
        cloud.put(path, bad)
        return RepairCandidate(key: normalizedIndexKey(path), target: .s3, source: .ssd, witness: .hdd,
                               paths: [.ssd: path, .hdd: path, .s3: path], good: digest(good),
                               badSize: Int64(bad.utf8.count), badSHA256: nil,
                               badETag: "\"\(FakeRepairCloud.md5(Data(bad.utf8)))\"")
    }

    /// Rovinata su un disco (`target` .hdd o .ssd): l'altro disco e Cubbit hanno la buona.
    private func brokenOnDisk(_ target: InventoryArchive) throws -> RepairCandidate {
        try put(target == .ssd ? ssd : hdd, path, bad)
        try put(target == .ssd ? hdd : ssd, path, good)
        cloud.put(path, good)
        return RepairCandidate(key: normalizedIndexKey(path), target: target,
                               source: RepairRules.source(forTarget: target), witness: .s3,
                               paths: [.ssd: path, .hdd: path, .s3: path], good: digest(good),
                               badSize: Int64(bad.utf8.count), badSHA256: digest(bad).sha256, badETag: nil)
    }

    private var quarantineKey: String { "_quarantena/2026-10-04/" + path }
    private var stagingRel: String { quarantineKey + ".in-arrivo-1a2b3c4d" }

    // MARK: - Cubbit: riuscita

    func testCubbit_repairs_andKeepsTheBrokenCopyInQuarantine() async throws {
        let c = try brokenOnCubbit()
        let steps = StepRecorder()
        let out = await engine().run(c, onStep: { steps.add($0) })
        XCTAssertTrue(out.succeeded, "\(String(describing: out.failure))")
        XCTAssertEqual(cloud.data(path), good, "al suo posto c'e' la copia dell'SSD")
        XCTAssertEqual(cloud.data(quarantineKey), bad, "la rovinata e' in quarantena, non cancellata")
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(RepairRules.normalizedETag(out.afterETag), digest(good).md5)
        XCTAssertEqual(steps.all, [.liveCheck, .quarantine, .write, .finalCheck, .log])
        XCTAssertEqual(read(ssd, path), good, "la sorgente non si tocca")
        XCTAssertEqual(read(hdd, path), good)
        let r = try XCTUnwrap(log.records().first)
        XCTAssertEqual(log.records().count, 1)
        XCTAssertEqual(r.outcome, .repaired)
        XCTAssertEqual(r.target, "s3")
        XCTAssertEqual(r.source, "ssd")
        XCTAssertEqual(r.quarantinePath, quarantineKey)
        XCTAssertEqual(r.goodSHA256, digest(good).sha256)
        XCTAssertEqual(RepairRules.normalizedETag(r.afterETag), digest(good).md5)
    }

    /// La prova con `rclone` del 2026-10-04 ha gia' messo da parte la rovinata: un altro giorno
    /// non la si copia di nuovo, si procede.
    func testCubbit_quarantineCopyFromAnotherDay_isReused() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, bad)
        let sixth = today.addingTimeInterval(2 * 86_400)
        let out = await engine(now: sixth).run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertTrue(out.reusedQuarantineCopy)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertTrue(cloud.copies.isEmpty, "nessuna seconda copia")
        XCTAssertFalse(cloud.keys().contains("_quarantena/2026-10-06/" + path))
    }

    /// In quarantena c'e' qualcosa con quel nome, ma non e' la rovinata: non vale.
    func testCubbit_differentQuarantineCopy_isNotReused() async throws {
        let c = try brokenOnCubbit()
        cloud.put("_quarantena/2026-10-01/" + path, "un'altra cosa")
        let out = await engine().run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(cloud.data("_quarantena/2026-10-01/" + path), "un'altra cosa", "mai sovrascritta")
    }

    func testCubbit_todaysQuarantineKeyHoldsSomethingElse_stopsWithoutTouching() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, "un'altra cosa")
        // La lista la vede ma non e' la rovinata; la HEAD sulla chiave di oggi la trova occupata.
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineOccupied)
        XCTAssertEqual(out.failedStep, .quarantine)
        XCTAssertEqual(cloud.data(quarantineKey), "un'altra cosa")
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty)
    }

    // MARK: - Cubbit: ricontrollo dal vivo, niente viene toccato

    private func assertCubbitUntouched(_ out: RepairOutcome, _ failure: RepairFailure,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(out.succeeded, file: file, line: line)
        XCTAssertEqual(out.failure, failure, file: file, line: line)
        XCTAssertEqual(out.failedStep, .liveCheck, file: file, line: line)
        XCTAssertTrue(cloud.copies.isEmpty, "nessuna quarantena", file: file, line: line)
        XCTAssertTrue(cloud.replaces.isEmpty, "nessuna scrittura", file: file, line: line)
        XCTAssertFalse(cloud.keys().contains { $0.hasPrefix("_quarantena/") }, file: file, line: line)
        XCTAssertNil(out.quarantinePath, file: file, line: line)
    }

    func testCubbit_sourceChangedSinceTheInventory_stops() async throws {
        let c = try brokenOnCubbit()
        try put(ssd, path, "cambiata dopo l'inventario")
        assertCubbitUntouched(await engine().run(c), .sourceChanged)
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testCubbit_witnessChanged_stops() async throws {
        let c = try brokenOnCubbit()
        try put(hdd, path, "diversa sull'HDD")
        assertCubbitUntouched(await engine().run(c), .witnessChanged)
    }

    func testCubbit_brokenCopyChangedSinceTheInventory_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.put(path, "ricaricata da qualcun altro")
        assertCubbitUntouched(await engine().run(c), .badCopyChanged)
        XCTAssertEqual(cloud.data(path), "ricaricata da qualcun altro")
    }

    func testCubbit_brokenCopyGone_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.remove(path)
        assertCubbitUntouched(await engine().run(c), .badCopyMissing)
    }

    func testCubbit_unreachable_stops() async throws {
        let c = try brokenOnCubbit()
        cloud.failHead = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .liveCheck)
        guard case .cubbitError = out.failure else { return XCTFail("\(String(describing: out.failure))") }
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testMissingDisk_stops() async throws {
        let c = try brokenOnCubbit()
        try FileManager.default.removeItem(at: ssd)
        assertCubbitUntouched(await engine().run(c), .volumeMissing(.ssd))
    }

    func testUnsafePath_stops() async throws {
        let c0 = try brokenOnCubbit()
        let c = RepairCandidate(key: c0.key, target: .s3, source: .ssd, witness: .hdd,
                                paths: [.ssd: "../fuori.heic", .hdd: path, .s3: path], good: c0.good,
                                badSize: c0.badSize, badSHA256: nil, badETag: c0.badETag)
        assertCubbitUntouched(await engine().run(c), .unsafePath)
    }

    /// Un candidato incoerente (sorgente sbagliata per l'archivio da riparare) non parte.
    func testInconsistentCandidate_stops() async throws {
        let c0 = try brokenOnCubbit()
        let c = RepairCandidate(key: c0.key, target: .s3, source: .hdd, witness: .ssd, paths: c0.paths,
                                good: c0.good, badSize: c0.badSize, badSHA256: nil, badETag: c0.badETag)
        assertCubbitUntouched(await engine().run(c), .unsafePath)
    }

    // MARK: - Cubbit: fallimenti dopo il ricontrollo

    func testCubbit_logCannotBeWritten_stopsBeforeTouchingAnything() async throws {
        let c = try brokenOnCubbit()
        struct Full: Error {}
        let out = await engine(record: { _ in throw Full() }).run(c)
        XCTAssertEqual(out.failedStep, .log)
        guard case .logNotWritten = out.failure else { return XCTFail() }
        XCTAssertTrue(cloud.copies.isEmpty)
        XCTAssertTrue(cloud.replaces.isEmpty)
        XCTAssertEqual(cloud.data(path), bad)
    }

    func testCubbit_copyFails_leavesTheBrokenCopyWhereItWas() async throws {
        let c = try brokenOnCubbit()
        cloud.failCopy = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .quarantine)
        guard case .quarantineFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty, "senza quarantena non si scrive")
        XCTAssertEqual(log.records().first?.outcome, .failed)
        XCTAssertEqual(log.records().first?.failedStep, .quarantine)
    }

    func testCubbit_quarantineCopyNotIdentical_stopsBeforeWriting() async throws {
        let c = try brokenOnCubbit()
        cloud.copyCorrupts = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineCopyMismatch)
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(cloud.replaces.isEmpty)
    }

    func testCubbit_uploadFails_theBrokenCopyIsStillThere_andInQuarantine() async throws {
        let c = try brokenOnCubbit()
        cloud.failReplace = true
        let out = await engine().run(c)
        XCTAssertEqual(out.failedStep, .write)
        guard case .writeFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(cloud.data(path), bad, "il caricamento fallito non ha toccato l'oggetto")
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
    }

    /// La verifica finale non torna: avviso, la rovinata resta in quarantena, nessun secondo tentativo.
    func testCubbit_finalCheckFails_noSecondAttempt() async throws {
        let c = try brokenOnCubbit()
        cloud.replaceCorrupts = true
        let out = await engine().run(c)
        XCTAssertFalse(out.succeeded)
        XCTAssertEqual(out.failedStep, .finalCheck)
        XCTAssertEqual(out.failure, .finalCheckFailed)
        XCTAssertEqual(cloud.replaces.count, 1)
        XCTAssertEqual(cloud.data(quarantineKey), bad)
        XCTAssertEqual(log.records().first?.outcome, .verificationFailed)
    }

    /// Il registro non si aggiorna alla fine: la riparazione e' fatta, e la finestra lo dice.
    func testCubbit_logFailsOnlyAtTheEnd_repairStands_andSaysSo() async throws {
        let c = try brokenOnCubbit()
        let store = log!
        let calls = Counter()
        struct Full: Error {}
        let out = await engine(record: { r in
            if calls.next() > 1 { throw Full() }
            try store.record(r)
        }).run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertNotNil(out.logError)
        XCTAssertEqual(log.records().first?.outcome, .inProgress, "resta la voce scritta prima di toccare")
    }

    // MARK: - Disco: riuscita

    func testHDD_repairsFromTheSSD_withCubbitAsWitness() async throws {
        let c = try brokenOnDisk(.hdd)
        let steps = StepRecorder()
        let out = await engine().run(c, onStep: { steps.add($0) })
        XCTAssertTrue(out.succeeded, "\(String(describing: out.failure))")
        XCTAssertEqual(read(hdd, path), good)
        XCTAssertEqual(read(hdd, quarantineKey), bad, "rovinata spostata in quarantena sullo stesso disco")
        XCTAssertNil(read(hdd, stagingRel), "la copia preparata e' andata al suo posto")
        XCTAssertNil(out.leftoverStagingPath)
        XCTAssertEqual(out.afterSHA256, digest(good).sha256)
        XCTAssertEqual(tree(ssd), [path: good], "la sorgente non si tocca")
        XCTAssertEqual(cloud.keys(), [path], "Cubbit solo letto")
        XCTAssertTrue(cloud.copies.isEmpty && cloud.replaces.isEmpty)
        XCTAssertEqual(steps.all, [.liveCheck, .write, .quarantine, .write, .finalCheck, .log])
        XCTAssertEqual(log.records().first?.outcome, .repaired)
        XCTAssertEqual(log.records().first?.target, "hdd")
    }

    /// Decisione 2 di Enrico: anche l'SSD, dall'HDD.
    func testSSD_repairsFromTheHDD() async throws {
        let c = try brokenOnDisk(.ssd)
        let out = await engine().run(c)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(read(ssd, path), good)
        XCTAssertEqual(read(ssd, quarantineKey), bad)
        XCTAssertEqual(tree(hdd), [path: good])
        XCTAssertEqual(log.records().first?.source, "hdd")
    }

    // MARK: - Disco: ogni fallimento lascia la foto dov'era

    func testDisk_brokenCopyChanged_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        try put(hdd, path, "toccata dopo l'inventario")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .badCopyChanged)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_brokenCopyGone_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        try FileManager.default.removeItem(at: hdd.appendingPathComponent(path))
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .badCopyMissing)
    }

    func testDisk_cubbitWitnessChanged_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        cloud.put(path, "diversa su Cubbit")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .witnessChanged)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_quarantineNameAlreadyTaken_stopsWithoutTouching() async throws {
        let c = try brokenOnDisk(.hdd)
        try put(hdd, quarantineKey, "c'era gia'")
        let before = tree(hdd)
        let out = await engine().run(c)
        XCTAssertEqual(out.failure, .quarantineOccupied)
        XCTAssertEqual(tree(hdd), before)
    }

    func testDisk_preparingTheCopyFails_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        struct Full: Error {}
        let out = await engine(copyFile: { _, _ in throw Full() }).run(c)
        XCTAssertEqual(out.failedStep, .write)
        guard case .stagingFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(tree(hdd), [path: bad])
        XCTAssertNil(out.quarantinePath)
    }

    func testDisk_preparedCopyDoesNotMatch_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        let wrong = digest("un'altra cosa")
        let out = await engine(hashFile: { url in
            url.lastPathComponent.contains(".in-arrivo-") ? .digest(wrong) : ContentHasher.digestFile(at: url)
        }).run(c)
        XCTAssertEqual(out.failure, .stagingMismatch)
        XCTAssertEqual(read(hdd, path), bad)
        XCTAssertNil(out.quarantinePath)
        XCTAssertEqual(out.leftoverStagingPath, stagingRel, "resta in quarantena, non si cancella")
        XCTAssertEqual(read(hdd, stagingRel), good)
    }

    func testDisk_moveToQuarantineFails_photoStaysWhereItWas() async throws {
        let c = try brokenOnDisk(.hdd)
        struct Denied: Error {}
        let out = await engine(renameFile: { _, _ in throw Denied() }).run(c)
        XCTAssertEqual(out.failedStep, .quarantine)
        guard case .quarantineFailed = out.failure else { return XCTFail() }
        XCTAssertEqual(read(hdd, path), bad)
        XCTAssertNil(read(hdd, quarantineKey))
    }

    /// Il secondo `rename` (la copia buona al suo posto) fallisce: la rovinata torna dov'era.
    func testDisk_writeFails_theBrokenCopyGoesBack() async throws {
        let c = try brokenOnDisk(.hdd)
        let calls = Counter()
        struct Denied: Error {}
        let out = await engine(renameFile: { from, to in
            if calls.next() == 2 { throw Denied() }
            try RepairEngine.renameWithoutOverwriting(from: from, to: to)
        }).run(c)
        XCTAssertEqual(out.failedStep, .write)
        XCTAssertTrue(out.restoredOriginal)
        XCTAssertNil(out.quarantinePath)
        XCTAssertEqual(read(hdd, path), bad, "tutto com'era")
        XCTAssertNil(read(hdd, quarantineKey))
        XCTAssertEqual(out.leftoverStagingPath, stagingRel)
    }

    /// E se fallisce anche il ritorno: la rovinata resta in quarantena (mai persa) e l'esito
    /// dice dove sono entrambe.
    func testDisk_writeAndRollbackFail_nothingIsLost() async throws {
        let c = try brokenOnDisk(.hdd)
        let calls = Counter()
        struct Denied: Error {}
        let out = await engine(renameFile: { from, to in
            if calls.next() >= 2 { throw Denied() }
            try RepairEngine.renameWithoutOverwriting(from: from, to: to)
        }).run(c)
        XCTAssertFalse(out.restoredOriginal)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertEqual(read(hdd, quarantineKey), bad)
        XCTAssertEqual(read(hdd, stagingRel), good)
        XCTAssertNil(read(hdd, path))
    }

    func testDisk_finalCheckFails_noSecondAttempt() async throws {
        let c = try brokenOnDisk(.hdd)
        let wrong = digest("un'altra cosa")
        let target = hdd.appendingPathComponent(path).path
        let reads = Counter()
        let out = await engine(hashFile: { url in
            // La prima lettura del bersaglio e' il ricontrollo (vera), la seconda la verifica finale.
            if url.path == target, reads.next() == 2 { return .digest(wrong) }
            return ContentHasher.digestFile(at: url)
        }).run(c)
        XCTAssertEqual(out.failure, .finalCheckFailed)
        XCTAssertEqual(log.records().first?.outcome, .verificationFailed)
        XCTAssertEqual(read(hdd, quarantineKey), bad, "la rovinata resta in quarantena")
    }

    func testDisk_volumeChangesBeforeTheQuarantine_stops() async throws {
        let c = try brokenOnDisk(.hdd)
        let root = hdd.path
        let calls = Counter()
        let out = await engine(volumeIdentity: { url in
            // Il ricontrollo vede il disco; subito dopo e' un altro disco (scollegato e ricollegato).
            if url.path == root, calls.next() >= 2 { return 999_999 }
            return deviceIdentifier(of: url)
        }).run(c)
        XCTAssertEqual(out.failure, .volumeMissing(.hdd))
        XCTAssertEqual(tree(hdd), [path: bad])
    }

    // MARK: - Controllo senza riparare (S11)

    func testDryRun_onCubbit_touchesNothing_andSaysWhere() async throws {
        let c = try brokenOnCubbit()
        let steps = StepRecorder()
        let out = await engine().run(c, dryRun: true, onStep: { steps.add($0) })
        XCTAssertTrue(out.wasDryRun)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertFalse(out.reusedQuarantineCopy)
        XCTAssertEqual(steps.all, [.liveCheck])
        XCTAssertTrue(cloud.copies.isEmpty && cloud.replaces.isEmpty)
        XCTAssertEqual(cloud.keys(), [path])
        XCTAssertEqual(cloud.data(path), bad)
        XCTAssertTrue(log.records().isEmpty, "un controllo non va nel registro")
    }

    func testDryRun_onCubbit_seesTheCopyAlreadyInQuarantine() async throws {
        let c = try brokenOnCubbit()
        cloud.put(quarantineKey, bad)
        let out = await engine(now: today.addingTimeInterval(86_400)).run(c, dryRun: true)
        XCTAssertTrue(out.succeeded)
        XCTAssertTrue(out.reusedQuarantineCopy)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertTrue(cloud.copies.isEmpty)
    }

    func testDryRun_onADisk_touchesNothing() async throws {
        let c = try brokenOnDisk(.hdd)
        let out = await engine().run(c, dryRun: true)
        XCTAssertTrue(out.succeeded)
        XCTAssertEqual(out.quarantinePath, quarantineKey)
        XCTAssertEqual(tree(hdd), [path: bad])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdd.appendingPathComponent("_quarantena").path),
                       "nemmeno una cartella creata")
        XCTAssertTrue(log.records().isEmpty)
    }

    func testDryRun_thatFails_saysWhy_andIsNotLogged() async throws {
        let c = try brokenOnCubbit()
        try put(ssd, path, "cambiata")
        let out = await engine().run(c, dryRun: true)
        XCTAssertTrue(out.wasDryRun)
        XCTAssertEqual(out.failure, .sourceChanged)
        XCTAssertTrue(log.records().isEmpty)
    }

    // MARK: - Le funzioni di disco

    func testRenameWithoutOverwriting_neverOverwrites() throws {
        try put(tmp, "a.jpg", "a")
        try put(tmp, "b.jpg", "b")
        XCTAssertThrowsError(try RepairEngine.renameWithoutOverwriting(from: tmp.appendingPathComponent("a.jpg"),
                                                                       to: tmp.appendingPathComponent("b.jpg")))
        XCTAssertEqual(read(tmp, "a.jpg"), "a")
        XCTAssertEqual(read(tmp, "b.jpg"), "b")
        try RepairEngine.renameWithoutOverwriting(from: tmp.appendingPathComponent("a.jpg"),
                                                  to: tmp.appendingPathComponent("c.jpg"))
        XCTAssertNil(read(tmp, "a.jpg"))
        XCTAssertEqual(read(tmp, "c.jpg"), "a")
    }

    /// Una cartella che e' un link verso fuori dalla radice non e' «sotto la radice».
    func testConfined_refusesALinkThatLeavesTheRoot() throws {
        let outside = tmp.appendingPathComponent("fuori")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ssd.appendingPathComponent("Foto"), withDestinationURL: outside)
        XCTAssertNil(RepairEngine.confined(ssd, "Foto/a.jpg"))
        try FileManager.default.createDirectory(at: ssd.appendingPathComponent("Vere"), withIntermediateDirectories: true)
        XCTAssertNotNil(RepairEngine.confined(ssd, "Vere/a.jpg"))
        XCTAssertNil(RepairEngine.confined(ssd, "../SSD/Vere/a.jpg"))
    }
}

/// Raccoglie i passi annunciati dal motore (da un thread qualsiasi).
nonisolated final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [RepairStep] = []
    func add(_ s: RepairStep) { lock.withLock { steps.append(s) } }
    var all: [RepairStep] { lock.withLock { steps } }
}

/// Un contatore da usare dentro le closure `@Sendable` dei test.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
