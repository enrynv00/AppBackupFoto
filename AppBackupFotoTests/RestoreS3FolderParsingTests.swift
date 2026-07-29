import XCTest
@testable import AppBackupFoto

final class RestoreS3FolderParsingTests: XCTestCase {
    func testMultipleFolders_areExtractedAndSorted() {
        let keys = ["Foto iPhone/a.jpg", "Takeout/b.jpg", "Foto iPhone/c.heic"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Foto iPhone", "Takeout"])
    }

    func testKeysWithoutSlash_areIgnored() {
        let keys = ["root-file.txt", "Foto iPhone/a.jpg"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Foto iPhone"])
    }

    func testDuplicateFolderNames_areDeduplicated() {
        let keys = ["Zip/a.jpg", "Zip/b.jpg", "Zip/nested/c.jpg"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Zip"])
    }

    func testEmptyList_returnsEmpty() {
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: []), [])
    }
}
