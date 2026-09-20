import XCTest
@testable import AppBackupFoto

/// Cosa dice l'app durante e dopo «Annulla l'ultimo spostamento» (ADR-0009). Logica pura,
/// stessa disciplina di `DuplicatesStatusTests`/`LibraryIndexStatusTests`: registro
/// anti-gergo, plurali, `id` stabili.
final class TrashRestoreStatusTests: XCTestCase {

    private func item(batch: String = "b1", restoredAt: Date? = nil) -> TrashedItem {
        TrashedItem(batchId: batch, originalDisplayPath: "/SSD/a.jpg", originalKey: "a.jpg",
                   trashedPath: "/SSD/.Trashes/a.jpg", size: 4, hash: "abc",
                   trashedAt: Date(timeIntervalSince1970: 1_700_000_000), restoredAt: restoredAt)
    }

    // MARK: - Conferma

    func testConfirmation_mentionsCountAndDate() {
        let summary = RestorableBatchSummary(pendingCount: 312, batchCount: 312,
                                             trashedAt: Date(timeIntervalSince1970: 1_758_000_000))
        let confirmation = TrashRestoreStatus.confirmation(summary: summary)
        XCTAssertTrue(confirmation.message.contains("312"))
        XCTAssertFalse(confirmation.title.isEmpty)
    }

    func testConfirmation_singularCount_usesSingularWord() {
        let summary = RestorableBatchSummary(pendingCount: 1, batchCount: 1, trashedAt: Date())
        let confirmation = TrashRestoreStatus.confirmation(summary: summary)
        XCTAssertTrue(confirmation.message.contains("1 foto spostata"))
    }

    // MARK: - Progresso

    func testProgressLine_mentionsDoneAndTotal() {
        let line = TrashRestoreStatus.progressLine(done: 120, total: 312)
        XCTAssertTrue(line.contains("120"))
        XCTAssertTrue(line.contains("312"))
    }

    func testStoppingLine_isNotEmpty() {
        XCTAssertFalse(TrashRestoreStatus.stoppingLine.isEmpty)
    }

    // MARK: - Esiti

    func testEverythingRestored_hasADoneLine() {
        let outcome = RestoreOutcome(restored: [item(), item(), item()])
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        XCTAssertTrue(lines.contains { $0.text.contains("3") && $0.tone == .ok })
    }

    func testAlreadyInPlace_mentionsTheFinder() {
        let outcome = RestoreOutcome(alreadyInPlace: [item(), item(), item(), item()])
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        XCTAssertTrue(lines.contains { $0.text.contains("4") && $0.text.lowercased().contains("finder") })
    }

    func testInterrupted_neverSaysEverythingIsFine() {
        var outcome = RestoreOutcome(restored: [item()])
        outcome.interrupted = true
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        XCTAssertFalse(lines.contains { $0.id == "done" })
        XCTAssertTrue(lines.contains { $0.id == "interrupted" })
    }

    func testVolumeVanished_neverSaysEverythingIsFine() {
        var outcome = RestoreOutcome(restored: [item()])
        outcome.stoppedBecauseVolumeVanished = true
        outcome.notAttempted = 5
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        XCTAssertFalse(lines.contains { $0.id == "done" })
        XCTAssertTrue(lines.contains { $0.id == "volume-vanished" })
    }

    /// Il mutante da uccidere: "ancora nel Cestino" calcolato come `total - restored` conta
    /// per errore anche le voci `alreadyInPlace` (che NON sono nel Cestino). Con 1 restored,
    /// 2 alreadyInPlace e 3 notAttempted, il numero corretto e' 3 (solo `notAttempted`, dato
    /// che non ci sono `skipped`), mai 5 (`total - restored` con `total = 6`).
    func testStillInTrashCount_excludesAlreadyInPlace() {
        var outcome = RestoreOutcome(restored: [item()], alreadyInPlace: [item(), item()])
        outcome.interrupted = true
        outcome.notAttempted = 3
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        let interrupted = lines.first { $0.id == "interrupted" }
        XCTAssertTrue(interrupted?.text.contains("3") ?? false, "atteso 3, testo: \(String(describing: interrupted))")
        XCTAssertFalse(interrupted?.text.contains("5") ?? true)
    }

    func testSkippedReasons_areGroupedWithCount() {
        var outcome = RestoreOutcome()
        outcome.skipped = [(item(), .missingInTrash), (item(), .missingInTrash), (item(), .alteredInTrash)]
        let lines = TrashRestoreStatus.outcomeLines(outcome)
        XCTAssertTrue(lines.contains { $0.text.contains("2") && $0.text.lowercased().contains("cestino") })
        XCTAssertTrue(lines.contains { $0.text.lowercased().contains("identica") })
    }

    func testReappearsInDuplicatesLine_presentIffSomethingCameBack() {
        let withRestore = TrashRestoreStatus.outcomeLines(RestoreOutcome(restored: [item()]))
        XCTAssertTrue(withRestore.contains { $0.id == "reappears" })

        var noneRestored = RestoreOutcome()
        noneRestored.skipped = [(item(), .missingInTrash)]
        let withoutRestore = TrashRestoreStatus.outcomeLines(noneRestored)
        XCTAssertFalse(withoutRestore.contains { $0.id == "reappears" })
    }

    func testPlurals_singularVsPlural() {
        let uno = TrashRestoreStatus.outcomeLines(RestoreOutcome(restored: [item()]))
        let due = TrashRestoreStatus.outcomeLines(RestoreOutcome(restored: [item(), item()]))
        XCTAssertTrue(uno.first { $0.id == "done" }?.text.contains("è tornata") ?? false)
        XCTAssertTrue(due.first { $0.id == "done" }?.text.contains("sono tornate") ?? false)
    }

    func testIdsAreStableAcrossTwoCalls() {
        let outcome = RestoreOutcome(restored: [item()])
        let a = TrashRestoreStatus.outcomeLines(outcome).map(\.id)
        let b = TrashRestoreStatus.outcomeLines(outcome).map(\.id)
        XCTAssertEqual(a, b)
    }

    func testAntiJargon_acrossAllLines() {
        var outcome = RestoreOutcome(restored: [item()], alreadyInPlace: [item()])
        outcome.skipped = [(item(), .missingInTrash), (item(), .alteredInTrash),
                           (item(), .originalPathOccupied), (item(), .unreadableInTrash),
                           (item(), .outsideLibrary), (item(), .moveFailed("errore"))]
        outcome.interrupted = true
        let confirmation = TrashRestoreStatus.confirmation(
            summary: RestorableBatchSummary(pendingCount: 3, batchCount: 3, trashedAt: Date()))
        var testi = TrashRestoreStatus.outcomeLines(outcome).map(\.text)
        testi.append(confirmation.title); testi.append(confirmation.message)
        testi.append(TrashRestoreStatus.progressLine(done: 1, total: 2))
        testi.append(TrashRestoreStatus.stoppingLine)
        for testo in testi {
            for parola in ["hash", "indice", "registro", "manifest", "volume", "scansione",
                          "entry", "cache", "sha"] {
                XCTAssertFalse(testo.lowercased().contains(parola), "gergo '\(parola)' in «\(testo)»")
            }
        }
    }
}
