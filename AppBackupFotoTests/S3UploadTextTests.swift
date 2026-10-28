import XCTest
@testable import AppBackupFoto

/// ROADMAP #43, ADR-0014: perche' un file non si e' caricato su Cubbit, in parole semplici e con
/// il codice fra parentesi (D2 = A). Logica pura: nessuna rete.
final class S3UploadTextTests: XCTestCase {
    /// Regola 7 del piano: nessuna di queste parole compare in un testo che l'utente legge.
    static let jargon = ["urlerror", "http", "multipart", "timeout", "retry", "upload", "nserror", "domain", "s3httperror"]

    static func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        for word in jargon {
            XCTAssertFalse(lower.contains(word), "«\(word)» in: \(text)", file: file, line: line)
        }
    }

    private func reason(_ error: Error) -> String { S3UploadText.reason(for: error) }
    private func http(_ code: Int) -> Error { S3Syncer.S3HTTPError(statusCode: code, message: "x") }

    func testReason_notConnectedToInternet() {
        let r = reason(URLError(.notConnectedToInternet))
        XCTAssertTrue(r.contains("non è collegato a Internet"), r)
        XCTAssertTrue(r.contains("(codice -1009)"), r)
    }

    func testReason_networkConnectionLost() {
        let r = reason(URLError(.networkConnectionLost))
        XCTAssertTrue(r.contains("la connessione si è interrotta"), r)
        XCTAssertTrue(r.contains("(codice -1005)"), r)
    }

    func testReason_timedOut() {
        let r = reason(URLError(.timedOut))
        XCTAssertTrue(r.contains("Cubbit non ha risposto in tempo"), r)
        XCTAssertTrue(r.contains("(codice -1001)"), r)
    }

    func testReason_cannotFindOrConnectToHost() {
        for (code, n) in [(URLError.Code.cannotFindHost, -1003), (.cannotConnectToHost, -1004), (.dnsLookupFailed, -1006)] {
            let r = reason(URLError(code))
            XCTAssertTrue(r.contains("Cubbit non è raggiungibile"), r)
            XCTAssertTrue(r.contains("(codice \(n))"), r)
        }
    }

    func testReason_otherURLError_keepsTheCode() {
        let r = reason(URLError(.badServerResponse))
        XCTAssertTrue(r.contains("problema di rete"), r)
        XCTAssertTrue(r.contains("(codice -1011)"), r)
    }

    func testReason_http429() {
        let r = reason(http(429))
        XCTAssertTrue(r.contains("Cubbit ha chiesto di rallentare"), r)
        XCTAssertTrue(r.contains("(codice 429)"), r)
    }

    func testReason_http5xx() {
        for code in [500, 503] {
            let r = reason(http(code))
            XCTAssertTrue(r.contains("problema temporaneo di Cubbit"), r)
            XCTAssertTrue(r.contains("(codice \(code))"), r)
        }
    }

    func testReason_http403() {
        let r = reason(http(403))
        XCTAssertTrue(r.contains("Cubbit ha rifiutato il file: credenziali o permessi"), r)
        XCTAssertTrue(r.contains("(codice 403)"), r)
    }

    func testReason_otherHttp4xx() {
        let r = reason(http(404))
        XCTAssertTrue(r.contains("Cubbit ha rifiutato il file"), r)
        XCTAssertFalse(r.contains("credenziali"), r)
        XCTAssertTrue(r.contains("(codice 404)"), r)
    }

    func testReason_httpWithoutResponse() {
        let r = reason(http(-1))
        XCTAssertTrue(r.contains("risposta di Cubbit non valida"), r)
        XCTAssertTrue(r.contains("(codice -1)"), r)
    }

    func testReason_fileVanishedFromSSD() {
        let r = reason(CocoaError(.fileReadNoSuchFile))
        XCTAssertTrue(r.contains("non si trova più sull'SSD"), r)
        XCTAssertTrue(r.contains("(codice 260)"), r)
    }

    func testReason_fileUnreadable() {
        for error: Error in [NSError(domain: "S3", code: 13), NSError(domain: "S3", code: 14), CocoaError(.fileReadUnknown)] {
            let r = reason(error)
            XCTAssertTrue(r.contains("non si è potuto leggere dall'SSD"), r)
            XCTAssertTrue(r.contains("(codice "), r)
        }
    }

    func testReason_unknownError_neverShowsTheDomain() {
        let r = reason(NSError(domain: "XYZDomain", code: 7))
        XCTAssertEqual(r, "errore imprevisto (codice 7)")
        XCTAssertFalse(r.contains("XYZ"), r)
    }

    func testReason_everyReasonHasNoJargon_andACode() {
        let errors: [Error] = [
            URLError(.notConnectedToInternet), URLError(.networkConnectionLost), URLError(.timedOut),
            URLError(.cannotFindHost), URLError(.cannotConnectToHost), URLError(.dnsLookupFailed),
            URLError(.badServerResponse), http(429), http(500), http(503), http(403), http(404), http(-1),
            CocoaError(.fileReadNoSuchFile), NSError(domain: "S3", code: 13), NSError(domain: "S3", code: 14),
            CocoaError(.fileReadUnknown), NSError(domain: "XYZDomain", code: 7),
        ]
        for error in errors {
            let r = reason(error)
            Self.assertNoJargon(r)
            XCTAssertTrue(r.contains("(codice "), r)
        }
    }

    func testRetryLine_saysKeyReasonWaitAndNextAttempt() {
        let line = S3UploadText.retryLine(key: "Foto/VID.mp4 (parte 12)", reason: "la connessione si è interrotta (codice -1005)",
                                          delaySeconds: 4, nextAttempt: 4, maxAttempts: 5)
        XCTAssertTrue(line.contains("Foto/VID.mp4 (parte 12)"), line)
        XCTAssertTrue(line.contains("la connessione si è interrotta (codice -1005)"), line)
        XCTAssertTrue(line.contains("4 secondi"), line)
        XCTAssertTrue(line.contains("tentativo 4 di 5"), line)
        Self.assertNoJargon(line)
        let one = S3UploadText.retryLine(key: "a.jpg", reason: "x", delaySeconds: 1, nextAttempt: 2, maxAttempts: 5)
        XCTAssertTrue(one.contains("1 secondo"), one)
        XCTAssertFalse(one.contains("1 secondi"), one)
    }

    func testFailedLine_saysKeyReasonAndThatTheNextBackupRetries() {
        let line = S3UploadText.failedLine(key: "ASUS/IMG-1.jpg", reason: "la connessione si è interrotta (codice -1005)")
        XCTAssertTrue(line.hasPrefix("Non caricato: «ASUS/IMG-1.jpg»"), line)
        XCTAssertTrue(line.contains("la connessione si è interrotta (codice -1005)"), line)
        XCTAssertTrue(line.contains("prossimo backup"), line)
        Self.assertNoJargon(line)
    }
}
