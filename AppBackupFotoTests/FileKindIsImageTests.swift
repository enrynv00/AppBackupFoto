import XCTest
@testable import AppBackupFoto

final class FileKindIsImageTests: XCTestCase {
    func testKnownImageExtensions_returnTrue() {
        for ext in ["jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "bmp", "webp"] {
            let url = URL(fileURLWithPath: "/tmp/foto.\(ext)")
            XCTAssertTrue(FileKind.isImage(url: url), "atteso true per estensione \(ext)")
        }
    }

    func testNonImageExtensions_returnFalse() {
        for ext in ["zip", "pdf", "txt", "csv"] {
            let url = URL(fileURLWithPath: "/tmp/archivio.\(ext)")
            XCTAssertFalse(FileKind.isImage(url: url), "atteso false per estensione \(ext)")
        }
    }

    func testNoExtension_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/file-senza-estensione")
        XCTAssertFalse(FileKind.isImage(url: url))
    }

    func testUppercaseExtension_returnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/FOTO.JPG")
        XCTAssertTrue(FileKind.isImage(url: url))
    }
}
