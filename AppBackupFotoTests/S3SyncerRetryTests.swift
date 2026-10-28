import XCTest
@testable import AppBackupFoto

final class S3SyncerRetryTests: XCTestCase {
    func testURLError_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(URLError(.notConnectedToInternet)))
    }

    func testHTTP403_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 403, message: "Forbidden")))
    }

    func testHTTP404_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 404, message: "Not Found")))
    }

    func testHTTP500_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 500, message: "Server Error")))
    }

    func testHTTP503_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 503, message: "Unavailable")))
    }

    func testHTTP429_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 429, message: "Too Many Requests")))
    }

    func testGenericNSError_isNotRetryable() {
        let error = NSError(domain: "S3", code: 12, userInfo: [NSLocalizedDescriptionKey: "URL non valido"])
        XCTAssertFalse(S3Syncer.isRetryable(error))
    }

    func testCancellationError_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(CancellationError()))
    }

    // MARK: - 5 tentativi, attese 1-2-4-8 s (ROADMAP #43, ADR-0014)

    /// Registra cosa fa il ciclo dei tentativi, senza rete e senza attese vere.
    private final class RetryProbe {
        var calls = 0
        var sleeps: [Double] = []
        var retries: [(reason: String, delay: Int, next: Int)] = []
    }

    private func run<T>(_ probe: RetryProbe, cancelled: Bool = false,
                        _ operation: () async throws -> T) async throws -> T {
        try await S3Syncer.runWithRetry(
            isCancelled: { cancelled },
            sleep: { probe.sleeps.append($0) },
            onRetry: { probe.retries.append(($0, $1, $2)) },
            operation: { probe.calls += 1; return try await operation() })
    }

    func testMaxAttempts_isFive() {
        XCTAssertEqual(S3Syncer.uploadMaxAttempts, 5)
    }

    func testDelays_are1_2_4_8() {
        XCTAssertEqual((1...4).map(S3Syncer.retryDelaySeconds(afterFailedAttempt:)), [1, 2, 4, 8])
    }

    func testRunWithRetry_retryableError_triesFiveTimesThenThrows() async {
        let probe = RetryProbe()
        do {
            let _: Int = try await run(probe) { throw URLError(.networkConnectionLost) }
            XCTFail("doveva lanciare")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(probe.calls, 5)
        XCTAssertEqual(probe.sleeps, [1, 2, 4, 8])
        XCTAssertEqual(probe.retries.map { $0.next }, [2, 3, 4, 5])
        XCTAssertEqual(probe.retries.map { $0.delay }, [1, 2, 4, 8])
    }

    func testRunWithRetry_permanentError_doesNotRetry() async {
        let probe = RetryProbe()
        do {
            let _: Int = try await run(probe) { throw S3Syncer.S3HTTPError(statusCode: 403, message: "Forbidden") }
            XCTFail("doveva lanciare")
        } catch {
            XCTAssertEqual((error as? S3Syncer.S3HTTPError)?.statusCode, 403)
        }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(probe.sleeps.isEmpty)
        XCTAssertTrue(probe.retries.isEmpty)
    }

    func testRunWithRetry_succeedsOnThirdAttempt() async throws {
        let probe = RetryProbe()
        let value: Int = try await run(probe) {
            if probe.calls < 3 { throw URLError(.timedOut) }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(probe.calls, 3)
        XCTAssertEqual(probe.sleeps, [1, 2])
    }

    func testRunWithRetry_cancelled_doesNotRetry() async {
        let probe = RetryProbe()
        do {
            let _: Int = try await run(probe, cancelled: true) { throw URLError(.networkConnectionLost) }
            XCTFail("doveva lanciare")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(probe.sleeps.isEmpty)
        XCTAssertTrue(probe.retries.isEmpty)
    }

    func testRunWithRetry_onRetryGetsThePlainReason() async {
        let probe = RetryProbe()
        let error = URLError(.notConnectedToInternet)
        let _: Int? = try? await run(probe) { throw error }
        XCTAssertEqual(probe.retries.count, 4)
        XCTAssertTrue(probe.retries.allSatisfy { $0.reason == S3UploadText.reason(for: error) })
    }
}
