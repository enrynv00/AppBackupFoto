import XCTest
@testable import AppBackupFoto

final class JobHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "JobHistoryStoreTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testLoad_withNoSavedData_returnsNil() {
        XCTAssertNil(JobHistoryStore.load(defaults: defaults))
    }

    func testSaveThenLoad_roundTripsAllFields() {
        let summary = JobSummary(date: Date(timeIntervalSince1970: 1_700_000_000),
                                  label: "MAC -> SSD", copied: 42, skipped: 3,
                                  errors: 1, hashErrors: 0, succeeded: true)
        JobHistoryStore.save(summary, defaults: defaults)
        let loaded = JobHistoryStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.date, summary.date)
        XCTAssertEqual(loaded?.label, "MAC -> SSD")
        XCTAssertEqual(loaded?.copied, 42)
        XCTAssertEqual(loaded?.skipped, 3)
        XCTAssertEqual(loaded?.errors, 1)
        XCTAssertEqual(loaded?.hashErrors, 0)
        XCTAssertEqual(loaded?.succeeded, true)
    }

    func testIsClean_falseWhenErrorsPresent() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 1, hashErrors: 0, succeeded: true)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_falseWhenNotSucceeded() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 0, hashErrors: 0, succeeded: false)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_trueWhenSucceededWithoutErrors() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 2,
                                  errors: 0, hashErrors: 0, succeeded: true)
        XCTAssertTrue(summary.isClean)
    }
}
