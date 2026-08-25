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

/// La lista dei file di sistema da escludere esisteva in due copie identiche
/// (`FileSyncer.excluded` e una locale dentro `ReviewEngine.scanLocalCatalog`), ed
/// era in procinto di diventare tre con l'indice di contenuto (roadmap #31). Due
/// liste che devono restare uguali sono due liste che prima o poi divergono, e il
/// sintomo sarebbe silenzioso: un file indicizzato ma mai copiato, o viceversa.
/// Ora la fonte è una sola; questi test la bloccano.
final class LibraryExclusionsTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/qualsiasi/\(name)")
    }

    func testSystemNames_areExcluded() {
        for name in [".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
                     ".fseventsd", ".DocumentRevisions-V100", "lost+found",
                     "Backups.backupdb"] {
            XCTAssertTrue(LibraryExclusions.shouldExclude(url(name)),
                          "atteso escluso: \(name)")
        }
    }

    func testAppleDoubleFiles_areExcluded() {
        // I sidecar "._nome" che macOS crea sui filesystem non-HFS (l'SSD è ExFAT).
        XCTAssertTrue(LibraryExclusions.shouldExclude(url("._IMG_0001.jpg")))
        XCTAssertTrue(LibraryExclusions.shouldExclude(url("._")))
    }

    func testRealPhotos_areNotExcluded() {
        for name in ["IMG_0001.jpg", "DSC0001.JPG", "clip.mov", "Takeout.zip",
                     "Backups.backupdb.txt", "lost+found.jpg"] {
            XCTAssertFalse(LibraryExclusions.shouldExclude(url(name)),
                           "atteso NON escluso: \(name)")
        }
    }

    func testNamesAreMatchedExactly_notAsSubstrings() {
        // "DS_Store" senza punto, o un file che contiene il nome, non vanno esclusi.
        XCTAssertFalse(LibraryExclusions.shouldExclude(url("DS_Store")))
        XCTAssertFalse(LibraryExclusions.shouldExclude(url("mio.DS_Store.jpg")))
    }

    func testExclusionIsByLastComponent_notFullPath() {
        // Una cartella di passaggio che si chiama come un elemento escluso non
        // deve escludere un file legittimo al suo interno.
        let deep = URL(fileURLWithPath: "/tmp/.Trashes-archivio/IMG_1.jpg")
        XCTAssertFalse(LibraryExclusions.shouldExclude(deep))
    }
}
