import XCTest
@testable import AppBackupFoto

final class RunBoundedTests: XCTestCase {

    private actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var completedCount = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func exit() {
            current -= 1
            completedCount += 1
        }
    }

    func testPeakConcurrency_neverExceedsMax() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<20)
        var processed: [Int] = []

        await S3Syncer.runBounded(
            items: items,
            maxConcurrent: 4,
            isCancelled: { false },
            operation: { item -> Int in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
                await tracker.exit()
                return item
            },
            onOutcome: { outcome in processed.append(outcome) }
        )

        let peak = await tracker.peak
        let completed = await tracker.completedCount
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(completed, 20)
        XCTAssertEqual(Set(processed), Set(0..<20))
    }

    func testEmptyItems_completesImmediately() async {
        var processed: [Int] = []
        await S3Syncer.runBounded(
            items: [Int](),
            maxConcurrent: 4,
            isCancelled: { false },
            operation: { item -> Int in item },
            onOutcome: { outcome in processed.append(outcome) }
        )
        XCTAssertTrue(processed.isEmpty)
    }

    func testCancelledBeforeStart_schedulesNothing() async {
        var processed: [Int] = []
        await S3Syncer.runBounded(
            items: Array(0..<10),
            maxConcurrent: 4,
            isCancelled: { true },
            operation: { item -> Int in item },
            onOutcome: { outcome in processed.append(outcome) }
        )
        XCTAssertTrue(processed.isEmpty)
    }
}
