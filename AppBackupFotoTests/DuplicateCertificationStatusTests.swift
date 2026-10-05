import XCTest
@testable import AppBackupFoto

/// I testi della garanzia dell'inventario nel pannello Doppioni (ROADMAP #46, ADR-0017): una
/// frase propria per ogni motivo, italiano semplice, nessun gergo.
final class DuplicateCertificationStatusTests: XCTestCase {

    /// Un calendario fisso: la frase non deve dipendere dal fuso del Mac che esegue i test.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-05 14:07:00 UTC
    private let ottobre = Date(timeIntervalSince1970: 1_791_209_220)

    private let jargon = ["hash", "indice", "sha", "scansione", "etag", "md5", "bucket", "cache"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in jargon {
            XCTAssertFalse(text.lowercased().contains(word), "gergo «\(word)» in: \(text)", file: file, line: line)
        }
    }

    private let allBlocks: [DuplicateCertificationBlock] = [
        .inventoryNeverRun, .inventoryIncomplete, .inventoryUnreadable,
        .inventoryOlderThanLastBackup(backupAt: Date(timeIntervalSince1970: 1_791_209_220)),
        .notSafeOnAllThree, .changedAfterInventory, .inventoryChangedSinceOpening]

    // MARK: - Date e durate

    func testDayAndTime_isWrittenInItalian() {
        XCTAssertEqual(DuplicatesStatus.dayAndTime(ottobre, calendar: utc), "5 ottobre 2026 alle 14:07")
    }

    func testDayAndTime_padsTheMinutes() {
        XCTAssertEqual(DuplicatesStatus.dayAndTime(Date(timeIntervalSince1970: 1_767_258_300), calendar: utc),
                       "1 gennaio 2026 alle 9:05")
    }

    func testApproxDuration() {
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 30), "meno di un minuto")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 60), "circa 1 minuto")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 1_190), "circa 20 minuti")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 3_590), "circa 1 ora")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 4_500), "circa 1 ora e 15 minuti")
        XCTAssertEqual(DuplicatesStatus.approxDuration(seconds: 7_260), "circa 2 ore e 1 minuto")
    }

    // MARK: - I motivi

    func testEveryReason_hasItsOwnSentence_withoutJargon() {
        let sentences = allBlocks.map { DuplicatesStatus.certificationReason($0, calendar: utc) }
        XCTAssertEqual(Set(sentences).count, allBlocks.count, "due motivi non devono dire la stessa cosa")
        for s in sentences {
            XCTAssertFalse(s.isEmpty)
            assertNoJargon(s)
        }
    }

    func testOlderReason_saysWhenTheBackupWas() {
        let s = DuplicatesStatus.certificationReason(.inventoryOlderThanLastBackup(backupAt: ottobre), calendar: utc)
        XCTAssertTrue(s.contains("5 ottobre 2026 alle 14:07"), s)
    }

    func testRowLine_saysItCannotBeTicked_andWhy() {
        XCTAssertEqual(DuplicatesStatus.blockedRowLine(.notSafeOnAllThree, calendar: utc),
                       "Non si può spuntare: secondo l'inventario questa foto non è al sicuro su SSD, HDD e Cubbit insieme.")
    }

    // MARK: - La riga in testa

    func testHeaderLine_fresh_isOk_andNamesHDDAndCubbit() {
        let line = DuplicatesStatus.certificationLine(.fresh(runId: 7, startedAt: 1_791_200_000,
                                                             finishedAt: 1_791_209_220), calendar: utc)
        XCTAssertEqual(line.id, "cert-fresh")
        XCTAssertEqual(line.tone, .ok)
        XCTAssertTrue(line.text.contains("5 ottobre 2026 alle 14:07"), line.text)
        XCTAssertTrue(line.text.contains("HDD") && line.text.contains("Cubbit"), line.text)
        assertNoJargon(line.text)
    }

    /// Lo scostamento della spec: non «ci vogliono pochi minuti» (falso: il secondo giro misurato
    /// il 2026-10-01 e' durato 75 minuti), ma quanto e' durato davvero l'ultimo aggiornamento.
    func testHeaderLine_older_asksToUpdate_andSaysHowLongItTookLastTime() {
        let line = DuplicatesStatus.certificationLine(.olderThanLastBackup(backupAt: ottobre, startedAt: 0, finishedAt: 4_500),
                                                      calendar: utc)
        XCTAssertEqual(line.id, "cert-older")
        XCTAssertEqual(line.tone, .warning)
        XCTAssertTrue(line.text.contains("aggiornalo"), line.text)
        XCTAssertTrue(line.text.contains("5 ottobre 2026 alle 14:07"), line.text)
        XCTAssertTrue(line.text.contains("circa 1 ora e 15 minuti"), line.text)
        XCTAssertFalse(line.text.contains("pochi minuti"), line.text)
    }

    func testHeaderLine_theOtherCases_areWarnings_withTheirOwnIds() {
        let lines = [DuplicateInventoryFreshness.neverRun, .incomplete, .unreadable]
            .map { DuplicatesStatus.certificationLine($0, calendar: utc) }
        XCTAssertEqual(lines.map(\.id), ["cert-never", "cert-incomplete", "cert-unreadable"])
        XCTAssertTrue(lines.allSatisfy { $0.tone == .warning })
        lines.forEach { assertNoJargon($0.text) }
    }

    func testHeaderLine_beforeTheCheck_saysItIsChecking() {
        let line = DuplicatesStatus.certificationLine(nil, calendar: utc)
        XCTAssertEqual(line.id, "cert-loading")
        XCTAssertEqual(line.tone, .info)
    }

    // MARK: - Selezione in massa e regola per cartella

    func testBulkSkipLine_isNilWhenNothingIsSkipped() {
        XCTAssertNil(DuplicatesStatus.bulkSkipLine(blockedVisible: 0, visible: 40))
    }

    func testBulkSkipLine_countsTheSkippedGroups() {
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 1, visible: 40),
                       "«Seleziona tutti quelli visibili» salta 1 gruppo che non si può ancora spostare: il motivo è scritto sotto ciascuno.")
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 1_234, visible: 5_000),
                       "«Seleziona tutti quelli visibili» salta \(1_234.formatted()) gruppi che non si possono ancora spostare: il motivo è scritto sotto ciascuno.")
    }

    func testBulkSkipLine_whenEveryVisibleGroupIsBlocked() {
        XCTAssertEqual(DuplicatesStatus.bulkSkipLine(blockedVisible: 40, visible: 40),
                       "Nessuno dei gruppi visibili si può spuntare adesso: il motivo è scritto sotto ciascuno.")
    }

    func testRuleBlockedLine() {
        XCTAssertNil(DuplicatesStatus.ruleBlockedLine(blockedCovered: 0))
        XCTAssertEqual(DuplicatesStatus.ruleBlockedLine(blockedCovered: 1),
                       "Di questi, 1 gruppo non si può ancora spostare: la selezione lo salta.")
        XCTAssertEqual(DuplicatesStatus.ruleBlockedLine(blockedCovered: 3),
                       "Di questi, 3 gruppi non si possono ancora spostare: la selezione li salta.")
    }

    // MARK: - Riepilogo ed esito

    func testSummaryLine_namesTheInventory_andTheLastCheck() {
        let s = DuplicatesStatus.certifiedSummaryLine(inventoryFinishedAt: ottobre, calendar: utc)
        XCTAssertTrue(s.contains("5 ottobre 2026 alle 14:07"), s)
        XCTAssertTrue(s.contains("ricontrolla"), s)
        assertNoJargon(s)
    }

    /// La corsa fermata dal ricontrollo prima del primo blocco: lo dice, col motivo, e dice che
    /// non e' stato completato niente.
    func testRunOutcome_stoppedBecauseTheInventoryIsNoLongerValid() {
        var outcome = DuplicateRunOutcome(totalBlocks: 3)
        outcome.stopReason = .inventoryNoLongerValid(.inventoryChangedSinceOpening)
        let lines = DuplicatesStatus.runOutcomeLines(outcome)
        XCTAssertEqual(lines.first?.id, "run-inventory-invalid")
        XCTAssertEqual(lines.first?.tone, .warning)
        XCTAssertEqual(lines.first?.text,
                       "Mi sono fermato prima di spostare altro: l'inventario è stato aggiornato dopo che hai aperto "
                       + "questo elenco. 0 blocchi sono stati completati su 3 previsti.")
    }

    func testNotCertifiedRunMessage_hasNoJargon() {
        assertNoJargon(DuplicatesStatus.notCertifiedRunMessage)
    }
}
