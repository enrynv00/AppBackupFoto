import XCTest
@testable import AppBackupFoto

/// I testi del progetto 4 nella finestra Inventario (ROADMAP #47, ADR-0019): ogni motivo ha la sua
/// frase, i conti sono quelli giusti, e nessuna parola tecnica arriva a Enrico.
final class AlignmentStatusTests: XCTestCase {
    private let jargon = ["hash", "etag", "md5", "sha", "bucket", "versionid", "delete", "marker", "indice",
                          "scansione", "cache", "inventory", "candidate", "plan"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for w in jargon { XCTAssertFalse(t.contains(w), "«\(w)» in: \(text)", file: file, line: line) }
        XCTAssertFalse(text.isEmpty, file: file, line: line)
    }

    private var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    private func candidate(_ i: Int, size: Int64 = 1_000_000) -> AlignmentCandidate {
        AlignmentCandidate(archive: .hdd, leavingKey: "p\(i)", keptKey: "k", leavingPath: "P/\(i).jpg", keptPath: "K.jpg",
                           ssdLeavingPath: "P/\(i).jpg", ssdKeptPath: "K.jpg", ssdKeptSize: size, size: size, sha256: "s",
                           leavingETag: nil, keptETag: nil)
    }

    private func plan(_ archive: AlignmentArchive = .hdd, candidates: Int = 3, stays: [AlignmentStayReason: Int] = [:],
                      malformed: Int = 0) -> AlignmentPlan {
        AlignmentPlan(archive: archive, runId: 7, block: nil, historyUnreadable: false, malformedHistoryLines: malformed,
                      historyCopies: candidates + stays.values.reduce(0, +), candidates: (0..<candidates).map { candidate($0) },
                      stays: stays, stayExamples: [:])
    }

    func testPlanLines_countAndSpace() {
        let lines = AlignmentStatus.planLines(plan(candidates: 3))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].text.contains("3 copie"))
        XCTAssertTrue(lines[0].text.contains("HDD"))
        XCTAssertTrue(lines[0].text.contains(ByteCountFormatter.string(fromByteCount: 3_000_000, countStyle: .file)))
        assertNoJargon(lines[0].text)
        XCTAssertTrue(AlignmentStatus.planLines(plan(.cubbit, candidates: 1))[0].text.contains("1 copia"))
    }

    func testPlanLines_nothingToRemove() {
        let lines = AlignmentStatus.planLines(plan(candidates: 0))
        XCTAssertEqual(lines.map(\.id), ["align-none"])
    }

    func testPlanLines_blockedByTheInventory_saysWhyAndWhatToDo() {
        let p = AlignmentPlan.blocked(.cubbit, block: .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_791_115_200)))
        let lines = AlignmentStatus.planLines(p, calendar: rome)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].tone, .warning)
        XCTAssertTrue(lines[0].text.contains("4 ottobre 2026"))
        XCTAssertTrue(lines[0].text.contains("Aggiorna l'inventario"))
    }

    func testPlanLines_unreadableHistory() {
        let lines = AlignmentStatus.planLines(.blocked(.hdd, block: nil, historyUnreadable: true))
        XCTAssertEqual(lines.map(\.id), ["align-history"])
        assertNoJargon(lines[0].text)
    }

    func testEveryStayReason_hasItsOwnLine_withTheCount() {
        var stays: [AlignmentStayReason: Int] = [:]
        for (i, r) in AlignmentStayReason.allCases.enumerated() { stays[r] = i + 2 }
        for archive in AlignmentArchive.allCases {
            let lines = AlignmentStatus.planLines(plan(archive, candidates: 0, stays: stays, malformed: 1))
            XCTAssertEqual(lines.count, 1 + AlignmentStayReason.allCases.count + 1)
            XCTAssertEqual(Set(lines.map(\.text)).count, lines.count)
            lines.forEach { assertNoJargon($0.text) }
        }
        XCTAssertTrue(AlignmentStatus.planLines(plan(candidates: 0, stays: [.backOnSSD: 1]))[1].text.hasPrefix("1 copia resta"))
    }

    func testCubbitSafety_everyCaseIsExplained_andOnlyReadyIsOk() {
        let cases: [AlignmentCubbitSafety] = [.ready(days: 30), .versioningNotEnabled(.neverEnabled), .noExpiryRule,
                                              .expiryTooShort(days: 7), .expiresCurrentPhotos]
        let lines = cases.map { AlignmentStatus.cubbitSafetyLine($0) }
        XCTAssertEqual(lines.map(\.tone), [.ok, .warning, .warning, .warning, .warning])
        XCTAssertEqual(Set(lines.map(\.text)).count, cases.count)
        XCTAssertTrue(lines[0].text.contains("30 giorni"))
        XCTAssertTrue(lines[3].text.contains("7 giorni"))
        lines.forEach { assertNoJargon($0.text) }
    }

    func testSummary_HDD_saysTrashAndNeverEmptied_Cubbit_says30Days() {
        let hdd = AlignmentStatus.summaryLines(plan(.hdd, candidates: 3), blocks: 1).joined(separator: " ")
        XCTAssertTrue(hdd.contains("Cestino dell'HDD"))
        XCTAssertTrue(hdd.contains("non lo svuota mai"))
        XCTAssertTrue(hdd.contains("L'SSD non viene toccato"))
        XCTAssertFalse(hdd.contains("blocchi"))
        let cubbit = AlignmentStatus.summaryLines(plan(.cubbit, candidates: 3), blocks: 45).joined(separator: " ")
        XCTAssertTrue(cubbit.contains("30 giorni"))
        XCTAssertTrue(cubbit.contains("45 blocchi"))
        XCTAssertTrue(cubbit.contains(AlignmentStatus.undoButton))
        assertNoJargon(hdd)
        assertNoJargon(cubbit)
    }

    func testConfirmMessage_namesTheCountAndWhereTheyGo() {
        XCTAssertTrue(AlignmentStatus.confirmMessage(plan(.hdd, candidates: 4)).contains("Cestino dell'HDD"))
        XCTAssertTrue(AlignmentStatus.confirmMessage(plan(.cubbit, candidates: 4)).contains("30 giorni"))
    }

    func testEveryStopReason_hasAnHonestLine() {
        let stops: [AlignmentStopReason] = [.interrupted, .volumeMissing(.ssd), .volumeMissing(.hdd), .volumeVanished(.hdd),
                                            .logNotWritten("x"), .trashFailed(path: "a.jpg", detail: "permesso negato"),
                                            .keptVanished(path: "k.jpg"), .cubbitNotReady(.noExpiryRule), .cubbitError("x"),
                                            .deleteWithoutMarker(path: "a.jpg"), .inventoryNoLongerValid(.inventoryIncomplete)]
        let texts = stops.map { AlignmentStatus.stopLine($0, archive: .cubbit) }
        XCTAssertEqual(Set(texts).count, stops.count)
        texts.forEach { assertNoJargon($0) }
        XCTAssertTrue(AlignmentStatus.stopLine(.keptVanished(path: "k.jpg"), archive: .hdd).contains(AlignmentStatus.undoButton))
    }

    func testEverySkipAndUndoReason_hasItsOwnText() {
        let skips = AlignmentSkipReason.allCases.map { AlignmentStatus.skipReasonText($0) }
        XCTAssertEqual(Set(skips).count, skips.count)
        skips.forEach { assertNoJargon($0) }
        let undos = AlignmentUndoSkipReason.allCases.map { AlignmentStatus.undoSkipText($0) }
        undos.forEach { assertNoJargon($0) }
        // Due casi dicono la stessa cosa all'utente, apposta: non risultano piu' tolte da questa app.
        XCTAssertEqual(Set(undos).count, undos.count - 1)
    }

    func testRunOutcome_absorbsBlocks_andTheLinesTellEverything() {
        var run = AlignmentRunOutcome(archive: .hdd, totalBlocks: 2)
        var a = AlignmentBlockOutcome()
        a.removed = [candidate(1), candidate(2)]
        a.skip(candidate(3), .locked)
        var b = AlignmentBlockOutcome()
        b.removed = [candidate(4)]
        b.skip(candidate(5), .locked)
        b.skip(candidate(6), .contentChanged)
        b.stop = .interrupted
        run.absorb(a)
        run.absorb(b)
        XCTAssertEqual(run.removedCount, 3)
        XCTAssertEqual(run.removedBytes, 3_000_000)
        XCTAssertEqual(run.skipped, [.locked: 2, .contentChanged: 1])
        XCTAssertEqual(run.skippedExamples[.locked], ["P/3.jpg", "P/5.jpg"])
        run.stop = b.stop
        let lines = AlignmentStatus.runOutcomeLines(run)
        XCTAssertEqual(lines.map(\.id), ["run-removed", "run-stop", "run-skip-locked", "run-skip-contentChanged"])
        XCTAssertTrue(lines[0].text.contains("3 copie"))
        XCTAssertTrue(lines[0].text.contains("Cestino dell'HDD"))
        lines.forEach { assertNoJargon($0.text) }
    }

    func testUndo_confirmationAndOutcome() {
        let c = AlignmentStatus.undoConfirmation(.cubbit, summary: RestorableBatchSummary(pendingCount: 12, batchCount: 12,
                                                 trashedAt: Date(timeIntervalSince1970: 1_791_115_200)), calendar: rome)
        XCTAssertTrue(c.message.contains("12 copie tolte"))
        XCTAssertTrue(c.message.contains("4 ottobre 2026"))
        var o = AlignmentUndoOutcome()
        o.restored = 10
        o.alreadyBack = 1
        o.skip("a.jpg", .tooOld)
        o.notAttempted = 2
        let lines = AlignmentStatus.undoOutcomeLines(.cubbit, o)
        XCTAssertEqual(lines.map(\.id), ["undo-restored", "undo-skip-tooOld", "undo-left"])
        lines.forEach { assertNoJargon($0.text) }
    }

    func testProgressLine_mentionsBlocksOnlyWhenThereAreMany() {
        XCTAssertEqual(AlignmentStatus.progressLine(.hdd, done: 1_234, total: 89_442, block: 1, blocks: 45),
                       "Tolgo da HDD le copie doppie: \(1_234.formatted()) di \(89_442.formatted()) (blocco 1 di 45)")
        XCTAssertFalse(AlignmentStatus.progressLine(.cubbit, done: 1, total: 2, block: 1, blocks: 1).contains("blocco"))
    }

    func testUnfinishedLine_onlyWhenSomethingIsUnfinished() {
        XCTAssertNil(AlignmentStatus.unfinishedLine(0, archive: .hdd))
        let l = AlignmentStatus.unfinishedLine(2, archive: .cubbit)
        XCTAssertEqual(l?.tone, .warning)
        assertNoJargon(l?.text ?? "")
    }

    func testTheInventoryNote_nowNamesBothButtonsThatWrite() {
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(RepairStatus.buttonTitle))
        XCTAssertTrue(InventoryStatus.readOnlyNote.contains(AlignmentStatus.runButton))
    }
}
