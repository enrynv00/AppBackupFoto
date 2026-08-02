import XCTest
@testable import AppBackupFoto

final class ValidateEndpointTests: XCTestCase {
    func testHTTPEndpoint_isRejected() {
        XCTAssertThrowsError(try S3Syncer.validateEndpoint("http://s3.it.cubbit.org")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "S3")
            XCTAssertEqual(nsError.code, 10)
        }
    }

    func testHTTPSHostNotInAllowList_isRejected() {
        XCTAssertThrowsError(try S3Syncer.validateEndpoint("https://evil.example.com")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "S3")
            XCTAssertEqual(nsError.code, 13)
        }
    }

    func testHTTPSCubbitEndpoint_isAccepted() throws {
        let result = try S3Syncer.validateEndpoint("https://s3.it.cubbit.org")
        XCTAssertEqual(result, "https://s3.it.cubbit.org")
    }

    func testHTTPSCubbitEndpoint_trailingSlashIsRemoved() throws {
        let result = try S3Syncer.validateEndpoint("https://s3.it.cubbit.org/")
        XCTAssertEqual(result, "https://s3.it.cubbit.org")
    }
}
