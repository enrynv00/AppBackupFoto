import XCTest
@testable import AppBackupFoto

final class IsLikelyVolumeRootTests: XCTestCase {
    func testVolumeRoot_isTrue() {
        XCTAssertTrue(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri")))
    }

    func testDirectSubfolder_isFalse() {
        XCTAssertFalse(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone")))
    }

    func testDeeplyNestedSubfolder_isFalse() {
        XCTAssertFalse(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone/2024")))
    }

    func testOtherVolumeRoot_isTrue() {
        XCTAssertTrue(isLikelyVolumeRoot(URL(fileURLWithPath: "/Volumes/BackupHDD")))
    }
}
