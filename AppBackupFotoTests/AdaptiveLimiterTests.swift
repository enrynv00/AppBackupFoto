import XCTest
@testable import AppBackupFoto

final class AdaptiveLimiterTests: XCTestCase {
    private let ceiling = 32

    func testSuccess_belowThreshold_growsCounterNotLimit() {
        var state = S3Syncer.AdaptiveLimiterState(limit: 4, consecutiveSuccesses: 0)
        for _ in 0..<4 {
            state = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: ceiling)
        }
        XCTAssertEqual(state.limit, 4)
        XCTAssertEqual(state.consecutiveSuccesses, 4)
    }

    func testSuccess_reachingThreshold_growsLimitAndResetsCounter() {
        var state = S3Syncer.AdaptiveLimiterState(limit: 4, consecutiveSuccesses: 0)
        for _ in 0..<5 {
            state = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: ceiling)
        }
        XCTAssertEqual(state.limit, 6)
        XCTAssertEqual(state.consecutiveSuccesses, 0)
    }

    func testSuccess_growthIsCappedAtCeiling() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 31, consecutiveSuccesses: 4)
        let result = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: 32)
        XCTAssertEqual(result.limit, 32)
        XCTAssertEqual(result.consecutiveSuccesses, 0)
    }

    func testSuccess_alreadyAtCeiling_staysAtCeiling() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 32, consecutiveSuccesses: 4)
        let result = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: 32)
        XCTAssertEqual(result.limit, 32)
    }

    func testRetryableFailure_halvesLimitAndResetsCounter() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 8, consecutiveSuccesses: 3)
        let result = S3Syncer.AdaptiveLimiter.applying(.retryableFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 4)
        XCTAssertEqual(result.consecutiveSuccesses, 0)
    }

    func testRetryableFailure_floorsAtOne() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 1, consecutiveSuccesses: 0)
        let result = S3Syncer.AdaptiveLimiter.applying(.retryableFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 1)
    }

    func testPermanentFailure_hasNoEffect() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 5, consecutiveSuccesses: 3)
        let result = S3Syncer.AdaptiveLimiter.applying(.permanentFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 5)
        XCTAssertEqual(result.consecutiveSuccesses, 3)
    }

    // Sanity-check best-effort (non una misura rigorosa: active/peak sono mutati da più
    // Task concorrenti senza isolamento esplicito). Le unità di lavoro sono 4, non 10:
    // con 10 il gate supera la soglia di crescita (5 successi consecutivi) e il limite
    // sale legittimamente da 2 a 4 a metà corsa — picco 4 osservato in esecuzione, cioè
    // il comportamento AIMD voluto, non un difetto del gate. Con 4 successi la crescita
    // non può avvenire, quindi il picco deve restare entro startingLimit.
    func testGate_acquireRelease_neverExceedsCurrentLimit() async {
        let gate = S3Syncer.AdaptiveUploadGate(startingLimit: 2, ceiling: 32)
        var active = 0, peak = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await gate.acquire()
                    active += 1
                    peak = max(peak, active)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    active -= 1
                    await gate.release(outcome: .success)
                }
            }
        }
        XCTAssertLessThanOrEqual(peak, 2)
    }
}
