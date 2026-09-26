import XCTest
@testable import AppBackupFoto

// Chiavi reali del bucket che interrompevano la lista (verificato il 2026-09-26).
final class S3ListSpecialCharsTests: XCTestCase {
    func testXmlDecode_numericApostrophe() {
        XCTAssertEqual(S3Syncer.xmlDecode("Altro 2.0/UNIVERSITA&#39;/2nd YEAR/chap11.pptx"),
                       "Altro 2.0/UNIVERSITA'/2nd YEAR/chap11.pptx")
    }

    func testXmlDecode_hexAndNamedEntities() {
        XCTAssertEqual(S3Syncer.xmlDecode("a&#x27;b &lt;c&gt; &quot;d&quot; &apos;e&apos; f&amp;g"),
                       "a'b <c> \"d\" 'e' f&g")
    }

    func testXmlDecode_singlePass() {
        XCTAssertEqual(S3Syncer.xmlDecode("&amp;#39;"), "&#39;")
    }

    func testXmlDecode_leavesUnknownOrBrokenEntities() {
        XCTAssertEqual(S3Syncer.xmlDecode("a&b"), "a&b")
        XCTAssertEqual(S3Syncer.xmlDecode("a&nope;b & c;"), "a&nope;b & c;")
        XCTAssertEqual(S3Syncer.xmlDecode("nessuna entità"), "nessuna entità")
    }

    func testEncodePlusInQuery_plusInContinuationToken() {
        var comps = URLComponents(string: "https://s3.cubbit.eu/backupfoto")!
        comps.queryItems = [URLQueryItem(name: "list-type", value: "2"),
                            URLQueryItem(name: "continuation-token", value: "Pioneer/6205e7b5_2050+.png")]
        comps.percentEncodedQuery = S3Syncer.encodePlusInQuery(comps.percentEncodedQuery)
        XCTAssertEqual(comps.percentEncodedQuery, "list-type=2&continuation-token=Pioneer/6205e7b5_2050%2B.png")
        XCTAssertEqual(comps.queryItems?.last?.value, "Pioneer/6205e7b5_2050+.png")
    }

    func testEncodePlusInQuery_nil() {
        XCTAssertNil(S3Syncer.encodePlusInQuery(nil))
    }
}
