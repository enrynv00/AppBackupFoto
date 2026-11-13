import XCTest
@testable import AppBackupFoto

/// ROADMAP #49, ADR-0020: perche' un file non e' stato copiato (o e' stato copiato non identico),
/// in parole semplici e con il codice fra parentesi. Logica pura: nessun disco.
final class LocalCopyTextTests: XCTestCase {
    /// Regola 5 del piano: nessuna di queste parole compare in un testo che l'utente legge.
    static let jargon = S3UploadTextTests.jargon + [
        "posix", "errno", "cocoa", "copyitem", "filemanager", "hash", "sha", "mismatch",
        "overwrite", "skip", "enospc", "eacces", "eperm", "enoent",
    ]

    static func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        for word in jargon {
            XCTAssertFalse(lower.contains(word), "«\(word)» in: \(text)", file: file, line: line)
        }
    }

    /// Un errore come lo da' `copyItem`: dominio Cocoa, con il codice di sistema sotto (se c'e').
    private func cocoa(_ code: Int, posix: Int?) -> NSError {
        var info: [String: Any] = [:]
        if let posix {
            info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: posix)
        }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
    }

    private func reason(_ error: Error) -> String { LocalCopyText.reason(for: error) }

    func testReason_diskFull() {
        let r = reason(cocoa(640, posix: 28))
        XCTAssertTrue(r.contains("pieno"), r)
        XCTAssertTrue(r.hasSuffix("(codice 640/28)"), r)
    }

    func testReason_diskFull_withoutUnderlying() {
        let r = reason(cocoa(640, posix: nil))
        XCTAssertTrue(r.contains("pieno"), r)
        XCTAssertTrue(r.contains("(codice 640)"), r)
    }

    func testReason_posixErrorAlone() {
        let r = reason(NSError(domain: NSPOSIXErrorDomain, code: 28))
        XCTAssertTrue(r.contains("pieno"), r)
        XCTAssertTrue(r.contains("(codice 28)"), r)
    }

    func testReason_permissionDenied() {
        let r = reason(cocoa(513, posix: 13))
        XCTAssertTrue(r.contains("permesso negato"), r)
        XCTAssertTrue(r.contains("leggere il file o scrivere nella cartella di destinazione"), r)
        XCTAssertTrue(r.contains("(codice 513/13)"), r)
    }

    func testReason_notPermittedByMacOS() {
        // Il codice di sistema decide prima di quello Cocoa: 513 + 1 non e' «permesso negato».
        let r = reason(cocoa(513, posix: 1))
        XCTAssertTrue(r.contains("Accesso completo al disco"), r)
        XCTAssertFalse(r.contains("permesso negato"), r)
    }

    func testReason_vanished() {
        let r = reason(cocoa(260, posix: 2))
        XCTAssertTrue(r.contains("non c'è più"), r)
    }

    func testReason_vanishedCocoa4() {
        let r = reason(cocoa(4, posix: nil))
        XCTAssertTrue(r.contains("non c'è più"), r)
        XCTAssertTrue(r.contains("(codice 4)"), r)
    }

    func testReason_alreadyAtDestination() {
        let r = reason(cocoa(516, posix: 17))
        XCTAssertTrue(r.contains("non è stato sovrascritto"), r)
    }

    func testReason_readOnlyDisk() {
        let r = reason(cocoa(642, posix: 30))
        XCTAssertTrue(r.contains("sola lettura"), r)
    }

    func testReason_nameTooLong() {
        let r = reason(cocoa(514, posix: 63))
        XCTAssertTrue(r.contains("troppo lungo"), r)
    }

    func testReason_parentIsAFile() {
        let r = reason(cocoa(512, posix: 20))
        XCTAssertTrue(r.contains("al posto di una cartella"), r)
    }

    func testReason_ioError() {
        let r = reason(cocoa(512, posix: 5))
        XCTAssertTrue(r.contains("lettura o scrittura"), r)
    }

    func testReason_diskNotResponding() {
        let r = reason(cocoa(512, posix: 6))
        XCTAssertTrue(r.contains("non risponde"), r)
    }

    func testReason_unknownError_neverShowsTheDomain() {
        let r = reason(NSError(domain: "XYZ", code: 77))
        XCTAssertTrue(r.contains("errore imprevisto (codice 77)"), r)
        XCTAssertFalse(r.contains("XYZ"), r)
    }

    func testReason_everyReasonHasNoJargon_andACode() {
        let all: [Error] = [
            cocoa(640, posix: 28), cocoa(640, posix: nil), NSError(domain: NSPOSIXErrorDomain, code: 28),
            cocoa(513, posix: 13), cocoa(513, posix: 1), cocoa(260, posix: 2), cocoa(4, posix: nil),
            cocoa(516, posix: 17), cocoa(642, posix: 30), cocoa(514, posix: 63), cocoa(512, posix: 20),
            cocoa(512, posix: 5), cocoa(512, posix: 6), NSError(domain: "XYZ", code: 77),
        ]
        for error in all {
            let r = reason(error)
            Self.assertNoJargon(r)
            XCTAssertTrue(r.contains("(codice "), r)
        }
    }

    func testFailedLine_saysPathAndReason_andPromisesNothing() {
        let line = LocalCopyText.failedLine(path: "sub/a.jpg", reason: "r")
        XCTAssertEqual(line, "Non copiato: «sub/a.jpg» — r.")
        XCTAssertFalse(line.lowercased().contains("riprov"), line)
    }

    func testMismatchLine_saysPathAndThatItIsNotRedone() {
        let line = LocalCopyText.mismatchLine(path: "sub/a.jpg")
        XCTAssertTrue(line.contains("«sub/a.jpg»"), line)
        XCTAssertTrue(line.contains("non è identica all'originale"), line)
        XCTAssertTrue(line.contains("non la rifà da sola"), line)
        Self.assertNoJargon(line)
    }

    func testRelativeChild() {
        XCTAssertEqual(LocalCopyText.relativeChild(of: "", name: "a.jpg"), "a.jpg")
        XCTAssertEqual(LocalCopyText.relativeChild(of: "a b/c", name: "x é.jpg"), "a b/c/x é.jpg")
    }
}
