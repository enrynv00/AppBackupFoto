import XCTest
@testable import AppBackupFoto

/// I testi della riparazione (ROADMAP #45): tutti in `RepairStatus`, nessuno nella View, niente
/// gergo, e ogni esito dice dove sta ogni copia.
final class RepairStatusTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum", "staging", "rename"]
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let q = "_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"
    private let today = Date(timeIntervalSince1970: 1_791_115_200)
    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text)»", file: file, line: line) }
    }

    private func candidate(_ target: InventoryArchive) -> RepairCandidate {
        RepairCandidate(key: normalizedIndexKey(path), target: target, source: RepairRules.source(forTarget: target),
                        witness: RepairRules.witness(forTarget: target), paths: [.ssd: path, .hdd: path, .s3: path],
                        good: ContentDigest(size: 10, sha256: "s", md5: "m", multipartETag: nil),
                        badSize: 10, badSHA256: target == .s3 ? nil : "b", badETag: target == .s3 ? "\"b\"" : nil)
    }

    private func outcome(_ target: InventoryArchive, _ edit: (inout RepairOutcome) -> Void) -> RepairOutcome {
        var o = RepairOutcome(key: normalizedIndexKey(path), target: target, displayPath: path, finishedAt: today)
        edit(&o)
        return o
    }

    private func state(startedAt: Double) -> [InventoryArchive: InventoryArchiveState] {
        Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, InventoryArchiveState(archive: $0, runId: 1, complete: true, reason: nil, unreadable: 0,
                                       startedAt: startedAt, finishedAt: startedAt + 60))
        })
    }

    private func record(_ target: String, _ outcome: RepairOutcomeKind, finishedAt: Date) -> RepairRecord {
        RepairRecord(repairId: UUID().uuidString, key: normalizedIndexKey(path), displayPath: path, target: target,
                     source: "ssd", witness: "hdd", goodSHA256: "s", goodSize: 10, badSize: 10,
                     startedAt: finishedAt.addingTimeInterval(-5), finishedAt: finishedAt, outcome: outcome)
    }

    // MARK: - Voce e riepilogo

    func testCandidateLine_saysWhereItDiffersAndWhereItAgrees() {
        XCTAssertEqual(RepairStatus.candidateLine(candidate(.s3)), "«\(path)» — diversa su Cubbit; uguale sull'SSD e sull'HDD")
        XCTAssertEqual(RepairStatus.candidateLine(candidate(.ssd)), "«\(path)» — diversa sull'SSD; uguale sull'HDD e su Cubbit")
    }

    func testSectionTitle_plural() {
        XCTAssertEqual(RepairStatus.sectionTitle(count: 1), "1 foto si può riparare")
        XCTAssertTrue(RepairStatus.sectionTitle(count: 3).hasPrefix("3 foto si possono"))
    }

    /// Il riepilogo nomina la quarantena esatta di oggi, la sorgente, e cosa non tocca.
    func testSummary_forCubbit() {
        let lines = RepairStatus.summaryLines(candidate(.s3), date: today, calendar: rome)
        let all = lines.joined(separator: "\n")
        XCTAssertTrue(lines[0].contains(path))
        XCTAssertTrue(all.contains("Su Cubbit la copia è diversa"))
        XCTAssertTrue(all.contains("«\(q)»"))
        XCTAssertTrue(all.contains("carica la copia sull'SSD"))
        XCTAssertTrue(all.contains("non viene cancellata"))
        XCTAssertTrue(all.contains("Non viene toccato nient'altro"))
        lines.forEach { assertNoJargon($0) }
    }

    func testSummary_forADisk() {
        let all = RepairStatus.summaryLines(candidate(.ssd), date: today, calendar: rome).joined(separator: "\n")
        XCTAssertTrue(all.contains("Sull'SSD la copia è diversa"))
        XCTAssertTrue(all.contains("spostata sull'SSD stesso, in «\(q)»"))
        XCTAssertTrue(all.contains("copia quella sull'HDD"))
        assertNoJargon(all)
    }

    func testConfirmMessage() {
        let m = RepairStatus.confirmMessage(candidate(.s3))
        XCTAssertTrue(m.contains("su Cubbit") && m.contains("sull'SSD") && m.contains("_quarantena"))
        assertNoJargon(m)
    }

    func testProgressLines_areAllDifferent_andPlain() {
        let lines = [nil, RepairStep.liveCheck, .quarantine, .write, .finalCheck, .log].map { RepairStatus.progressLine($0) }
        XCTAssertEqual(Set(lines).count, lines.count)
        lines.forEach { assertNoJargon($0) }
    }

    // MARK: - «Riparata il …»

    func testAwaitingConfirmation_onlyForASuccessAfterTheLastInventory() {
        let c = candidate(.s3)
        let states = state(startedAt: today.timeIntervalSince1970 - 3600)
        let after = record("s3", .repaired, finishedAt: today)
        XCTAssertEqual(RepairStatus.awaitingConfirmation(c, records: [after], states: states), after)
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [after], states: state(startedAt: today.timeIntervalSince1970 + 60)),
                     "un inventario fatto dopo la riparazione la conferma (o la smentisce) da solo")
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("s3", .failed, finishedAt: today)], states: states))
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("s3", .verificationFailed, finishedAt: today)], states: states))
        XCTAssertNil(RepairStatus.awaitingConfirmation(c, records: [record("hdd", .repaired, finishedAt: today)], states: states))
    }

    func testAwaitingConfirmation_takesTheLatest() {
        let c = candidate(.s3)
        let older = record("s3", .repaired, finishedAt: today.addingTimeInterval(-60))
        let newer = record("s3", .repaired, finishedAt: today)
        XCTAssertEqual(RepairStatus.awaitingConfirmation(c, records: [newer, older], states: state(startedAt: 0)), newer)
    }

    func testRepairedLine() {
        XCTAssertEqual(RepairStatus.repairedLine(record("s3", .repaired, finishedAt: today), calendar: rome),
                       "Riparata il 4 ottobre 2026: aggiorna l'inventario per confermarlo.")
    }

    // MARK: - Esiti

    func testSuccess_saysWhereTheDifferentCopyIs_andToRefresh() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q })
        XCTAssertEqual(lines.map(\.id), ["repair-done", "repair-confirm"])
        XCTAssertTrue(lines[0].text.contains("riparata su Cubbit"))
        XCTAssertTrue(lines[0].text.contains(q))
        XCTAssertTrue(lines[1].text.contains("Aggiorna l'inventario"))
    }

    func testSuccess_withAQuarantineCopyAlreadyThere_saysSo() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.reusedQuarantineCopy = true })
        XCTAssertTrue(lines[0].text.contains("era già da parte"))
    }

    func testEveryFailure_hasItsOwnPlainSentence() {
        let all: [RepairFailure] = [.volumeMissing(.ssd), .volumeMissing(.hdd), .unsafePath, .sourceChanged, .witnessChanged,
                                    .badCopyMissing, .badCopyChanged, .cubbitError("x"), .logNotWritten("x"),
                                    .quarantineOccupied, .quarantineFailed("x"), .quarantineCopyMismatch,
                                    .stagingFailed("x"), .stagingMismatch, .writeFailed("x"), .finalCheckFailed]
        let texts = all.map { RepairStatus.failureText($0) }
        XCTAssertEqual(Set(texts).count, texts.count)
        texts.forEach { assertNoJargon($0) }
        XCTAssertFalse(RepairStatus.failureText(.cubbitError("SignatureDoesNotMatch")).contains("Signature"),
                       "il dettaglio tecnico va nel registro, non a schermo")
    }

    func testLiveCheckFailure_saysNothingWasTouched() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .liveCheck; $0.failure = .badCopyChanged })
        XCTAssertEqual(lines.map(\.id), ["repair-failed", "repair-why", "repair-state"])
        XCTAssertEqual(lines[2].text, "Non è stato toccato niente.")
    }

    func testDiskWriteFailure_withTheCopyPutBack_saysAllIsAsBefore() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) {
            $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.restoredOriginal = true
            $0.leftoverStagingPath = q + ".in-arrivo-1a2b3c4d"
        })
        XCTAssertTrue(lines.contains { $0.text.contains("com'era prima") })
        XCTAssertTrue(lines.contains { $0.id == "repair-staging" && $0.text.contains(".in-arrivo-1a2b3c4d") })
    }

    func testDiskWriteFailure_withoutPuttingItBack_saysWhereBothCopiesAre() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) {
            $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q
            $0.leftoverStagingPath = q + ".in-arrivo-1a2b3c4d"
        })
        let state = lines.first { $0.id == "repair-state" }?.text ?? ""
        XCTAssertTrue(state.contains(q) && state.contains("non è andata persa") && state.contains("non c'è niente"))
        XCTAssertTrue(lines.contains { $0.id == "repair-staging" })
    }

    func testCubbitUploadFailure_saysTheBrokenCopyIsStillThere() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q })
        XCTAssertEqual(lines.first { $0.id == "repair-state" }?.text,
                       "Su Cubbit la copia diversa è ancora al suo posto, e una copia è anche in «\(q)».")
    }

    func testFinalCheckFailure_saysNoSecondAttempt() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.failedStep = .finalCheck; $0.failure = .finalCheckFailed; $0.quarantinePath = q })
        let state = lines.first { $0.id == "repair-state" }?.text ?? ""
        XCTAssertTrue(state.contains("non riprova da sola") && state.contains(q))
    }

    func testLogError_isAlwaysSaid() {
        let ok = RepairStatus.outcomeLines(outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.logError = "x" })
        XCTAssertEqual(ok.last?.id, "repair-log")
        XCTAssertEqual(ok.last?.tone, .warning)
    }

    func testDryRun_success_saysNothingWasTouched_andWhereItWouldGo() {
        let lines = RepairStatus.outcomeLines(outcome(.s3) { $0.wasDryRun = true; $0.succeeded = true; $0.quarantinePath = q })
        XCTAssertEqual(lines.map(\.id), ["dry-ok", "dry-where"])
        XCTAssertTrue(lines[0].text.contains("non è stato toccato niente"))
        XCTAssertTrue(lines[1].text.contains(q) && lines[1].text.contains("andrebbe"))
        let reused = RepairStatus.outcomeLines(outcome(.s3) {
            $0.wasDryRun = true; $0.succeeded = true; $0.quarantinePath = q; $0.reusedQuarantineCopy = true
        })
        XCTAssertTrue(reused[1].text.contains("già da parte"))
        (lines + reused).forEach { assertNoJargon($0.text) }
    }

    func testDryRun_failure_saysWhy() {
        let lines = RepairStatus.outcomeLines(outcome(.hdd) { $0.wasDryRun = true; $0.failedStep = .liveCheck; $0.failure = .badCopyChanged })
        XCTAssertEqual(lines.map(\.id), ["dry-failed", "repair-why"])
        XCTAssertTrue(lines[0].text.contains("non è stato toccato niente"))
    }

    func testAllOutcomeTexts_arePlain() {
        let outcomes = [outcome(.s3) { $0.succeeded = true; $0.quarantinePath = q; $0.logError = "x" },
                        outcome(.hdd) { $0.failedStep = .write; $0.failure = .writeFailed("x"); $0.quarantinePath = q; $0.leftoverStagingPath = q + ".in-arrivo-1" }]
        for o in outcomes { RepairStatus.outcomeLines(o).forEach { assertNoJargon($0.text) } }
    }

    /// La nota in testa alla finestra non dice piu' «guarda soltanto» senza dire di «Ripara…».
    func testReadOnlyNote_mentionsTheOnlyWritingButton() {
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(RepairStatus.buttonTitle))
    }

    /// Il riepilogo dell'inventario porta con se' le voci riparabili, calcolate dallo stesso snapshot.
    func testInventorySummary_carriesTheRepairCandidates() {
        func file(_ c: Character) -> InventoryLocalFile {
            InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: 10, mtime: 1, status: .ok,
                               digest: ContentDigest(size: 10, sha256: "sha-\(c)", md5: String(repeating: c, count: 32),
                                                     multipartETag: nil), hashedAt: 2)
        }
        let s3 = InventoryS3Object(key: normalizedIndexKey(path), displayKey: path, size: 10,
                                   etag: "\"\(String(repeating: "b", count: 32))\"")
        let snapshot = InventorySnapshot(ssd: [file("a")], hdd: [file("a")], s3: [s3], states: state(startedAt: 0))
        let summary = InventorySummary(snapshot, sampleLimit: 10)
        XCTAssertEqual(summary.repairCandidates.map(\.target), [.s3])
        XCTAssertEqual(summary.count(.toCheck), 2, "le due voci restano in ❗ fino al prossimo giro")
    }
}
