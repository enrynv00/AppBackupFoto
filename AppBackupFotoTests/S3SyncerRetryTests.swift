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
}
