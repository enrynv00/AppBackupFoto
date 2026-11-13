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
            cocoa(512, posix: 27), cocoa(512, posix: 92), cocoa(514, posix: nil),
            cocoa(256, posix: nil), cocoa(512, posix: nil),
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

    func testReason_fileTooBig() {
        let r = reason(cocoa(512, posix: 27))
        XCTAssertTrue(r.contains("troppo grande"), r)
        XCTAssertTrue(r.contains("(codice 512/27)"), r)
    }

    func testReason_illegalCharacters() {
        let r = reason(cocoa(512, posix: 92))
        XCTAssertTrue(r.contains("caratteri"), r)
        XCTAssertTrue(r.contains("non accetta"), r)
    }

    func testReason_nameTooLongCocoaAlone() {
        let r = reason(cocoa(514, posix: nil))
        XCTAssertTrue(r.contains("troppo lungo"), r)
        XCTAssertTrue(r.contains("(codice 514)"), r)
    }

    func testReason_otherReadError() {
        let r = reason(cocoa(256, posix: nil))
        XCTAssertTrue(r.contains("non si è potuto leggere"), r)
        XCTAssertTrue(r.contains("(codice 256)"), r)
    }

    func testReason_otherWriteError() {
        let r = reason(cocoa(512, posix: nil))
        XCTAssertTrue(r.contains("non si è potuto scrivere a destinazione"), r)
        XCTAssertTrue(r.contains("(codice 512)"), r)
    }

    func testRelativeChild() {
        XCTAssertEqual(LocalCopyText.relativeChild(of: "", name: "a.jpg"), "a.jpg")
        XCTAssertEqual(LocalCopyText.relativeChild(of: "a b/c", name: "x é.jpg"), "a b/c/x é.jpg")
    }

    // MARK: - L'elenco in FileSyncer.SyncResult (Task 3)

    func testRecordCopyFailure_countsAndRemembers() {
        var r = FileSyncer.SyncResult()
        r.recordCopyFailure(path: "a", reason: "r")
        XCTAssertEqual(r.errors, 1)
        XCTAssertEqual(r.failedCopies, [FailedFile(path: "a", reason: "r")])
        XCTAssertEqual(r.hashErrors, 0)
    }

    func testRecordCopyMismatch_countsAsHashErrorAndRemembers() {
        var r = FileSyncer.SyncResult()
        r.recordCopyMismatch(path: "a")
        XCTAssertEqual(r.hashErrors, 1)
        XCTAssertEqual(r.errors, 0)
        XCTAssertEqual(r.failedCopies, [FailedFile(path: "a", reason: LocalCopyText.mismatchReason)])
    }

    func testProgressSnapshot_dropsOnlyTheList() {
        var r = FileSyncer.SyncResult()
        r.total = 10; r.done = 4; r.copied = 2
        r.recordCopyFailure(path: "a", reason: "r")
        r.recordCopyMismatch(path: "b")
        let snap = r.progressSnapshot
        XCTAssertTrue(snap.failedCopies.isEmpty)
        XCTAssertEqual(snap.errors, r.errors)
        XCTAssertEqual(snap.hashErrors, r.hashErrors)
        XCTAssertEqual(snap.done, 4)
        XCTAssertEqual(snap.total, 10)
        XCTAssertEqual(snap.copied, 2)
        XCTAssertEqual(r.failedCopies.count, 2)
    }

    // MARK: - Il riepilogo di fine job (Task 5)

    private func entries(_ n: Int) -> [FailedFile] {
        (0..<n).map { FailedFile(path: "sub/f\($0).jpg", reason: "motivo \($0)") }
    }

    func testHeadline_failedOnly() {
        XCTAssertEqual(LocalCopySummary.headline(failed: 1, mismatched: 0), "1 file non copiato")
        XCTAssertEqual(LocalCopySummary.headline(failed: 3, mismatched: 0), "3 file non copiati")
    }

    func testHeadline_mismatchedOnly() {
        XCTAssertEqual(LocalCopySummary.headline(failed: 0, mismatched: 1), "1 copia non identica all'originale")
        XCTAssertEqual(LocalCopySummary.headline(failed: 0, mismatched: 2), "2 copie non identiche all'originale")
    }

    func testHeadline_both() {
        XCTAssertEqual(LocalCopySummary.headline(failed: 2, mismatched: 1),
                       "2 file non copiati e 1 copia non identica all'originale")
    }

    func testReassurance_dependsOnWhatHappened() {
        let onlyFailed = LocalCopySummary.reassurance(failed: 2, mismatched: 0)
        XCTAssertEqual(onlyFailed.count, 1)
        XCTAssertTrue(onlyFailed[0].contains("originali non sono stati toccati"), onlyFailed[0])
        XCTAssertTrue(onlyFailed[0].contains("mancano ancora"), onlyFailed[0])

        let onlyMismatched = LocalCopySummary.reassurance(failed: 0, mismatched: 2)
        XCTAssertEqual(onlyMismatched.count, 1)
        XCTAssertTrue(onlyMismatched[0].contains("non sovrascrive mai"), onlyMismatched[0])

        let both = LocalCopySummary.reassurance(failed: 1, mismatched: 1)
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(both[0].contains("originali non sono stati toccati"), both[0])
        XCTAssertTrue(both[1].contains("non sovrascrive mai"), both[1])
    }

    func testVisibleLines_sameRuleAsCubbit() {
        let list = entries(10)
        XCTAssertEqual(LocalCopySummary.visibleLines(list, limit: 8),
                       UploadFailureSummary.visibleLines(list, limit: 8))
    }

    func testLogLines_listEveryFile_noLimit() {
        let list = entries(20)
        let lines = LocalCopySummary.logLines(list, failed: 20, mismatched: 0)
        XCTAssertEqual(lines.count, 21)
        XCTAssertTrue(lines[0].hasSuffix("— elenco completo:"), lines[0])
        XCTAssertEqual(lines[1], "  sub/f0.jpg — motivo 0")
        XCTAssertEqual(lines[20], "  sub/f19.jpg — motivo 19")
    }

    func testLogLines_empty_isEmpty() {
        XCTAssertTrue(LocalCopySummary.logLines([], failed: 0, mismatched: 0).isEmpty)
    }

    func testAllSummaryTexts_haveNoJargon() {
        for (f, m) in [(1, 0), (3, 0), (0, 1), (0, 2), (2, 1)] {
            Self.assertNoJargon(LocalCopySummary.headline(failed: f, mismatched: m))
            for line in LocalCopySummary.reassurance(failed: f, mismatched: m) { Self.assertNoJargon(line) }
        }
        Self.assertNoJargon(LocalCopySummary.whereIsTheFullList)
    }
}
