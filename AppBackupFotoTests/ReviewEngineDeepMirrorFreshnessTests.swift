import XCTest
@testable import AppBackupFoto

final class ReviewEngineDeepMirrorFreshnessTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ReviewEngineDeepMirrorFreshnessTests"
    private let now = Date(timeIntervalSince1970: 1_754_000_000) // fisso, riproducibile

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

    func testHDDNotConfigured_returnsNilRegardlessOfDate() {
        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: false, defaults: defaults, now: now)
        XCTAssertNil(finding)
    }

    func testNeverRun_isNotOkWithMaiEseguitoDetail() {
        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)
        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, false)
        XCTAssertTrue(finding!.detail.contains("Mai eseguito"))
    }

    func testTenDaysAgo_isOk() {
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
        defaults.set(tenDaysAgo, forKey: "lastDeepMirrorDate")

        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)

        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, true)
        XCTAssertTrue(finding!.detail.contains("10 giorni fa"))
    }

    func testFiftyDaysAgo_isNotOkWithDayCountInDetail() {
        let fiftyDaysAgo = now.addingTimeInterval(-50 * 86400)
        defaults.set(fiftyDaysAgo, forKey: "lastDeepMirrorDate")

        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)

        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, false)
        XCTAssertTrue(finding!.detail.contains("50 giorni fa"))
    }
}
