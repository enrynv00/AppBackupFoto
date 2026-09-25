import XCTest
@testable import AppBackupFoto

/// `LibraryListFreshness` — da quanto l'elenco delle foto gia' sull'SSD non viene rimesso in
/// pari (Task 12, spec 2026-09-24 §4). Pura: nessun filesystem, nessun database.
final class LibraryListFreshnessTests: XCTestCase {

    // MARK: - Le cinque diramazioni

    func testNeverBuilt_saysSoAndWarns() {
        let line = LibraryListFreshness.line(hasAnyEntries: false, lastCompleteReadAt: nil, isReading: false)
        XCTAssertEqual(line.id, "never-built")
        XCTAssertTrue(line.text.lowercased().contains("non hai ancora creato"))
    }

    func testReading_precedesEverythingElse() {
        // Anche con l'elenco mai creato E nessuna data: "sta leggendo" vince su tutto.
        let line = LibraryListFreshness.line(hasAnyEntries: false, lastCompleteReadAt: nil, isReading: true)
        XCTAssertEqual(line.id, "reading")
    }

    func testUnknownDate_neutralNotWarning() {
        let line = LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: nil, isReading: false)
        XCTAssertEqual(line.id, "unknown")
        XCTAssertEqual(line.tone, .info)
    }

    func testFresh_belowThreshold_isNeutral() {
        let now = Date()
        let line = LibraryListFreshness.line(hasAnyEntries: true,
                                             lastCompleteReadAt: now.addingTimeInterval(-3 * 86_400),
                                             isReading: false, now: now)
        XCTAssertEqual(line.id, "fresh")
        XCTAssertEqual(line.tone, .ok)
    }

    func testStale_aboveThreshold_isWarning() {
        let now = Date()
        let line = LibraryListFreshness.line(hasAnyEntries: true,
                                             lastCompleteReadAt: now.addingTimeInterval(-21 * 86_400),
                                             isReading: false, now: now)
        XCTAssertEqual(line.id, "stale")
        XCTAssertEqual(line.tone, .warning)
        XCTAssertTrue(line.text.contains("settimane"))
    }

    // MARK: - Il bordo esatto della soglia (mutante: `>` invece di `>=`)

    func testThreshold_thirteenDaysAndTwentyThreeHours_staysNeutral() {
        let now = Date()
        let almostFourteen = now.addingTimeInterval(-(13 * 86_400 + 23 * 3_600))
        let line = LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: almostFourteen,
                                             isReading: false, now: now)
        XCTAssertEqual(line.id, "fresh", "13 giorni e 23 ore devono restare sotto soglia")
    }

    func testThreshold_exactlyFourteenDays_warns() {
        let now = Date()
        let exactlyFourteen = now.addingTimeInterval(-14 * 86_400)
        let line = LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: exactlyFourteen,
                                             isReading: false, now: now)
        XCTAssertEqual(line.id, "stale", "14 giorni esatti devono già scattare l'avviso")
    }

    // MARK: - `agoText` — plurali di giorni e settimane

    func testAgoText_singularDay() {
        XCTAssertEqual(LibraryListFreshness.agoText(days: 1), "un giorno fa")
    }

    func testAgoText_pluralDays() {
        XCTAssertEqual(LibraryListFreshness.agoText(days: 5), "5 giorni fa")
    }

    func testAgoText_singularWeek() {
        XCTAssertEqual(LibraryListFreshness.agoText(days: 7), "una settimana fa")
    }

    func testAgoText_pluralWeeks() {
        XCTAssertEqual(LibraryListFreshness.agoText(days: 21), "3 settimane fa")
    }

    // MARK: - Mai una promessa di durata

    func testLine_neverPromisesADuration() {
        let now = Date()
        let allTexts = [
            LibraryListFreshness.line(hasAnyEntries: false, lastCompleteReadAt: nil, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: nil, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: now, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: now.addingTimeInterval(-30 * 86_400),
                                      isReading: false, now: now).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: nil, isReading: true).text,
        ]
        for text in allTexts {
            XCTAssertFalse(text.lowercased().contains("minut"), "nessuna promessa di durata: \(text)")
        }
    }

    // MARK: - Registro anti-gergo, su tutte le diramazioni

    func testNoJargon_onEveryBranch() {
        let forbidden = ["hash", "indice", "sha256", "entry", "scansione", "registro", "manifest", "cache"]
        let now = Date()
        let allTexts = [
            LibraryListFreshness.line(hasAnyEntries: false, lastCompleteReadAt: nil, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: nil, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: now, isReading: false).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: now.addingTimeInterval(-30 * 86_400),
                                      isReading: false, now: now).text,
            LibraryListFreshness.line(hasAnyEntries: true, lastCompleteReadAt: nil, isReading: true).text,
        ]
        for text in allTexts {
            let lower = text.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word), "'\(word)' non deve comparire in: \(text)")
            }
        }
    }

    // MARK: - `readReachedTheEnd`

    func testReadReachedTheEnd_falseOnError() {
        var progress = LibraryIndexer.Progress()
        progress.traversalIncomplete = false
        XCTAssertFalse(LibraryListFreshness.readReachedTheEnd(progress: progress, error: NSError(domain: "t", code: 1)))
    }

    func testReadReachedTheEnd_falseOnNilProgress() {
        XCTAssertFalse(LibraryListFreshness.readReachedTheEnd(progress: nil, error: nil))
    }

    func testReadReachedTheEnd_falseWhenTraversalIncomplete() {
        var progress = LibraryIndexer.Progress()
        progress.traversalIncomplete = true
        XCTAssertFalse(LibraryListFreshness.readReachedTheEnd(progress: progress, error: nil))
    }

    /// Mutante da uccidere: `cancelled`/`volumeVanished` sono sottoinsiemi di
    /// `traversalIncomplete` (vedi `LibraryIndexer.scan`) — verificarlo qui blinda quella
    /// relazione, non solo il campo che la riassume.
    func testReadReachedTheEnd_falseWhenCancelled() {
        var progress = LibraryIndexer.Progress()
        progress.cancelled = true
        progress.traversalIncomplete = true
        XCTAssertFalse(LibraryListFreshness.readReachedTheEnd(progress: progress, error: nil))
    }

    func testReadReachedTheEnd_trueOnACompleteRead() {
        var progress = LibraryIndexer.Progress()
        progress.traversalIncomplete = false
        XCTAssertTrue(LibraryListFreshness.readReachedTheEnd(progress: progress, error: nil))
    }
}
