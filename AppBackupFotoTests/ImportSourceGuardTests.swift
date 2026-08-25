import XCTest
@testable import AppBackupFoto

final class ImportSourceGuardTests: XCTestCase {
    private let configured = [
        URL(fileURLWithPath: "/Users/enrico/Pictures/Photos Library.photoslibrary"),
        URL(fileURLWithPath: "/Volumes/SSD - Enri"),
        URL(fileURLWithPath: "/Volumes/BackupHDD"),
    ]

    func testExactMatch_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri"), configuredURLs: configured))
    }

    func testSubfolderOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone"), configuredURLs: configured))
    }

    func testParentOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes"), configuredURLs: configured))
    }

    func testUnrelatedPath_isNotInside() {
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), configuredURLs: configured))
    }

    func testSimilarPrefixDifferentVolume_isNotInside() {
        // "/Volumes/SSD - Enri 2" NON è dentro "/Volumes/SSD - Enri" anche se il path
        // condivide lo stesso prefisso testuale senza separatore "/" di mezzo.
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri 2"), configuredURLs: configured))
    }

    func testSlug_normalLabel_unchanged() {
        XCTAssertEqual(importFolderSlug("EOS_DIGITAL - 2026-08-25"), "EOS_DIGITAL - 2026-08-25")
    }

    func testSlug_replacesSlash() {
        XCTAssertEqual(importFolderSlug("Foto/Vacanze"), "Foto-Vacanze")
    }

    func testSlug_replacesColon() {
        XCTAssertEqual(importFolderSlug("Nikon: vecchie foto"), "Nikon- vecchie foto")
    }

    func testSlug_emptyAfterTrim_fallsBackToImport() {
        XCTAssertEqual(importFolderSlug("   "), "Import")
    }
}
