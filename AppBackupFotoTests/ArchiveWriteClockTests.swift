import XCTest
@testable import AppBackupFoto

/// Quando un backup o un import ha scritto per l'ultima volta sugli archivi (ROADMAP #46,
/// ADR-0017): la piu' recente fra la fine dell'ultimo job (`JobHistoryStore`) e l'inizio
/// dell'ultimo job (`ArchiveWriteClock.startedKey`).
final class ArchiveWriteClockTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ArchiveWriteClockTests"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func saveJob(endedAt t: Double) {
        JobHistoryStore.save(JobSummary(date: Date(timeIntervalSince1970: t), label: "SSD -> HDD", copied: 1,
                                        skipped: 0, errors: 0, hashErrors: 0, succeeded: true), defaults: defaults)
    }

    func testNoJobEver_isNil() {
        XCTAssertNil(ArchiveWriteClock.lastWriteAt(defaults: defaults))
    }

    func testOnlyTheLastJobSummary_isItsEnd() {
        saveJob(endedAt: 2_000)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 2_000))
    }

    /// Il job partito e mai arrivato a salvare il suo riepilogo (app chiusa a forza a meta').
    func testOnlyTheStartMarker_isItsStart() {
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 3_000), defaults: defaults)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 3_000))
    }

    func testAJobStartedAfterTheLastSummary_wins() {
        saveJob(endedAt: 2_000)
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 3_000), defaults: defaults)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 3_000))
    }

    /// Il caso normale: il job e' partito e poi e' finito; conta la fine. (verificato: un mutante
    /// che leggesse solo l'inizio darebbe 1.000)
    func testTheEndOfTheSameJob_winsOverItsStart() {
        ArchiveWriteClock.markStarted(at: Date(timeIntervalSince1970: 1_000), defaults: defaults)
        saveJob(endedAt: 2_000)
        XCTAssertEqual(ArchiveWriteClock.lastWriteAt(defaults: defaults), Date(timeIntervalSince1970: 2_000))
    }
}
