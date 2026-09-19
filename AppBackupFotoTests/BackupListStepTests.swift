import XCTest
@testable import AppBackupFoto

/// `BackupListStep` e' la logica pura del passo 2 del backup (spec
/// 2026-09-19-index-refresh-as-backup-step-design.md): decide se il passo 2 parte, calcola
/// la stima/percentuale mostrata durante la lettura, decide l'esito finale e produce ogni
/// testo che arriva a schermo. Nessuna View, nessun filesystem, nessun SQLite qui dentro:
/// e' l'unica parte del passo 2 verificabile senza una corsa reale (cablaggio in
/// `BackupRunner`, coperto dalla verifica sull'app reale).
final class BackupListStepTests: XCTestCase {

    // MARK: - shouldRun

    func testShouldRun_falseIfJobDoesNotWriteToSSD() {
        XCTAssertFalse(BackupListStep.shouldRun(refreshesLibraryIndex: false, enabled: true,
                                                indexedFileCount: 100, isIndexing: false,
                                                isTrashingDuplicates: false),
                       "SSD -> HDD e SSD -> Cubbit non scrivono sull'SSD: niente passo 2")
    }

    func testShouldRun_falseIfSwitchIsOff() {
        XCTAssertFalse(BackupListStep.shouldRun(refreshesLibraryIndex: true, enabled: false,
                                                indexedFileCount: 100, isIndexing: false,
                                                isTrashingDuplicates: false))
    }

    func testShouldRun_falseIfListIsEmpty() {
        XCTAssertFalse(BackupListStep.shouldRun(refreshesLibraryIndex: true, enabled: true,
                                                indexedFileCount: 0, isIndexing: false,
                                                isTrashingDuplicates: false),
                       "la prima creazione dell'elenco non parte mai da sola")
    }

    func testShouldRun_falseIfAlreadyReading() {
        XCTAssertFalse(BackupListStep.shouldRun(refreshesLibraryIndex: true, enabled: true,
                                                indexedFileCount: 100, isIndexing: true,
                                                isTrashingDuplicates: false),
                       "una lettura per volta, sempre sulla stessa istanza dello store")
    }

    func testShouldRun_falseIfTrashingDuplicates() {
        XCTAssertFalse(BackupListStep.shouldRun(refreshesLibraryIndex: true, enabled: true,
                                                indexedFileCount: 100, isIndexing: false,
                                                isTrashingDuplicates: true),
                       "leggere mentre si sposta nel Cestino darebbe un elenco sbagliato")
    }

    func testShouldRun_trueWhenEverythingIsInOrder() {
        XCTAssertTrue(BackupListStep.shouldRun(refreshesLibraryIndex: true, enabled: true,
                                               indexedFileCount: 100, isIndexing: false,
                                               isTrashingDuplicates: false))
    }

    // MARK: - stima e percentuale

    func testEstimate_isListBeforePlusCopiedPlusUnverified() {
        XCTAssertEqual(BackupListStep.estimate(indexedBefore: 100, copied: 3, copiedUnverified: 1), 104)
    }

    func testProgress_neverReports100WhileRunning() {
        let r = BackupListStep.progress(scanned: 104, estimate: 104)
        XCTAssertEqual(r.percent, 99, "il 100% lo scrive solo finishJob")
    }

    func testProgress_normalCase() {
        let r = BackupListStep.progress(scanned: 50, estimate: 100)
        XCTAssertEqual(r.percent, 50)
        XCTAssertEqual(r.shownTotal, 100)
    }

    func testProgress_scannedAboveEstimate_shownTotalFollowsScanned() {
        let r = BackupListStep.progress(scanned: 120, estimate: 100)
        XCTAssertEqual(r.shownTotal, 120, "mai '50.100 / 48.000': il totale mostrato non torna mai indietro")
        XCTAssertEqual(r.percent, 99)
    }

    func testProgress_zeroEstimate_noDivisionByZero() {
        let r = BackupListStep.progress(scanned: 0, estimate: 0)
        XCTAssertEqual(r.percent, 0)
        XCTAssertEqual(r.shownTotal, 0)
    }

    // MARK: - outcome

    private func completeProgress() -> LibraryIndexer.Progress {
        var p = LibraryIndexer.Progress()
        p.scanned = 500; p.hashed = 10; p.skipped = 490; p.total = 500
        p.traversalIncomplete = false
        return p
    }

    func testOutcome_couldNotStart_winsOverEverything() {
        var p = completeProgress()
        p.volumeVanished = true
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: true,
                                              couldNotStart: true, scanFailed: false), .couldNotUpdate)
    }

    func testOutcome_scanFailed_isCouldNotUpdate() {
        XCTAssertEqual(BackupListStep.outcome(progress: completeProgress(), interruptedByUser: false,
                                              couldNotStart: false, scanFailed: true), .couldNotUpdate)
    }

    func testOutcome_stoppedByYou_winsOverVolumeVanished() {
        var p = completeProgress()
        p.volumeVanished = true
        p.traversalIncomplete = true
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: true,
                                              couldNotStart: false, scanFailed: false), .stoppedByYou,
                       "«fermato da te» vince su SSD scollegato")
    }

    func testOutcome_ssdDisconnected() {
        var p = completeProgress()
        p.volumeVanished = true
        p.traversalIncomplete = true
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: false,
                                              couldNotStart: false, scanFailed: false), .ssdDisconnected)
    }

    func testOutcome_stoppedByAnotherDisk() {
        var p = completeProgress()
        p.cancelled = true
        p.traversalIncomplete = true
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: false,
                                              couldNotStart: false, scanFailed: false), .stoppedByAnotherDisk)
    }

    func testOutcome_updatedWithRemarks_followsLibraryIndexStatusWarningLines() {
        var p = completeProgress()
        p.unreadableItems = 3   // riga "illeggibili": tono .warning in LibraryIndexStatus
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: false,
                                              couldNotStart: false, scanFailed: false), .updatedWithRemarks)
    }

    func testOutcome_informativeLineOnly_isPlainUpdated() {
        var p = completeProgress()
        p.rebasedByTimezone = 4   // riga "fuso": tono .info, non .warning
        XCTAssertEqual(BackupListStep.outcome(progress: p, interruptedByUser: false,
                                              couldNotStart: false, scanFailed: false), .updated,
                       "una riga informativa (cambio d'ora) non deve produrre 'qualcosa non torna'")
    }

    func testOutcome_cleanRead_isUpdated() {
        XCTAssertEqual(BackupListStep.outcome(progress: completeProgress(), interruptedByUser: false,
                                              couldNotStart: false, scanFailed: false), .updated)
    }

    // MARK: - testi

    func testHeader_plannedSaysStepOneOfTwo() {
        XCTAssertEqual(BackupListStep.header(label: "MAC -> SSD", state: .planned), "MAC -> SSD — passo 1 di 2")
    }

    func testHeader_runningSaysStepTwoOfTwo() {
        XCTAssertEqual(BackupListStep.header(label: "MAC -> SSD", state: .running(estimate: 100)),
                       "MAC -> SSD — passo 2 di 2")
    }

    func testHeader_nilStateIsUnchanged() {
        XCTAssertEqual(BackupListStep.header(label: "MAC -> SSD", state: nil), "MAC -> SSD")
    }

    func testCopyDoneLine_singularNewAndAlreadyThere() {
        var stats = JobStats()
        stats.copied = 1; stats.skipped = 1
        let (text, clean) = BackupListStep.copyDoneLine(stats: stats)
        XCTAssertTrue(text.contains("1 nuova"), text)
        XCTAssertTrue(text.contains("1 già presente"), text)
        XCTAssertTrue(clean)
    }

    func testCopyDoneLine_pluralNewAndAlreadyThere() {
        var stats = JobStats()
        stats.copied = 2; stats.copiedUnverified = 0; stats.skipped = 2
        let (text, _) = BackupListStep.copyDoneLine(stats: stats)
        XCTAssertTrue(text.contains("2 nuove"), text)
        XCTAssertTrue(text.contains("2 già presenti"), text)
    }

    func testCopyDoneLine_withErrors_isNotClean() {
        var stats = JobStats()
        stats.copied = 5; stats.skipped = 1; stats.errors = 3
        let (text, clean) = BackupListStep.copyDoneLine(stats: stats)
        XCTAssertFalse(clean)
        XCTAssertTrue(text.contains("3"), text)
    }

    func testCopyDoneLine_duplicatesSkippedCountAsAlreadyThere() {
        var stats = JobStats()
        stats.copied = 1; stats.skipped = 1; stats.duplicatesSkipped = 4
        let (text, _) = BackupListStep.copyDoneLine(stats: stats)
        XCTAssertTrue(text.contains("5 già presenti"), text)
    }

    func testNotificationBody_nilOutcome_isIdenticalToToday() {
        var stats = JobStats()
        stats.copied = 3; stats.skipped = 2; stats.errors = 1
        XCTAssertEqual(BackupListStep.notificationBody(stats: stats, outcome: nil),
                       "Copiati 3 · Skippati 2 · Errori 1")
    }

    func testNotificationBody_stoppedByYou_appendsSuffix() {
        let stats = JobStats()
        let body = BackupListStep.notificationBody(stats: stats, outcome: .stoppedByYou)
        XCTAssertTrue(body.hasSuffix(" · Elenco delle foto non aggiornato"), body)
    }

    func testNotificationBody_updatedWithRemarks_addsNothing() {
        var stats = JobStats()
        stats.copied = 1
        let plain = BackupListStep.notificationBody(stats: stats, outcome: nil)
        let withRemarks = BackupListStep.notificationBody(stats: stats, outcome: .updatedWithRemarks)
        XCTAssertEqual(plain, withRemarks)
    }

    func testCompletionLine_updatedWithRemarksNamesTheCard() {
        let (text, tone) = BackupListStep.completionLine(.updatedWithRemarks)
        XCTAssertTrue(text.contains(LibraryIndexCommands.cardTitle), text)
        XCTAssertEqual(tone, .warning)
    }

    func testCompletionLine_stoppedByYou_saysStoppedNotInterrupted() {
        let (text, tone) = BackupListStep.completionLine(.stoppedByYou)
        XCTAssertTrue(text.contains("Hai fermato"), text)
        XCTAssertFalse(text.lowercased().contains("interrotto"), text)
        XCTAssertEqual(tone, .info)
    }

    func testCompletionLine_updated_isOk() {
        let (_, tone) = BackupListStep.completionLine(.updated)
        XCTAssertEqual(tone, .ok)
    }

    // MARK: - registro anti-gergo

    func testNoTechnicalJargonReachesTheScreen() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache", "entry",
                     "traversata", "incrementale"]
        var stats = JobStats()
        stats.copied = 3; stats.skipped = 2; stats.errors = 1; stats.duplicatesSkipped = 4

        var testi: [String] = [
            BackupListStep.header(label: "MAC -> SSD", state: .planned),
            BackupListStep.header(label: "MAC -> SSD", state: .running(estimate: 100)),
            BackupListStep.runningLine,
            BackupListStep.countLine(scanned: 48, shownTotal: 78),
            BackupListStep.stoppingLabel,
            BackupListStep.copyDoneLine(stats: stats).text,
            BackupListStep.notificationBody(stats: stats, outcome: nil),
        ]
        let outcomes: [BackupListStep.Outcome] = [.updated, .updatedWithRemarks, .stoppedByYou,
                                                   .ssdDisconnected, .stoppedByAnotherDisk, .couldNotUpdate]
        for o in outcomes {
            testi.append(BackupListStep.completionLine(o).text)
            testi.append(BackupListStep.notificationBody(stats: stats, outcome: o))
        }

        for detto in testi {
            let lower = detto.lowercased()
            for parola in gergo {
                XCTAssertFalse(lower.contains(parola), "gergo a schermo: '\(parola)' in «\(detto)»")
            }
        }
    }
}
