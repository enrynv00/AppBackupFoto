import XCTest
@testable import AppBackupFoto

/// Le parti pure delle richieste della riparazione (ROADMAP #45): la codifica delle chiavi e
/// come si leggono le risposte di HEAD e della copia lato server. Niente rete: la prova vera
/// su Cubbit e' l'ultimo task del piano.
final class S3RepairRequestsTests: XCTestCase {

    // MARK: - Codifica delle chiavi

    func testStrictEncoding_keepsOnlyTheUnreservedCharactersAndSlash() {
        XCTAssertEqual(S3Syncer.encodeKeyStrict("Foto iPhone/3/A-B_c.d~e.heic"), "Foto%20iPhone/3/A-B_c.d~e.heic")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("a+b"), "a%2Bb", "il + di BUG-8")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("l'isola"), "l%27isola", "l'apostrofo di BUG-8")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("è"), "%C3%A8", "UTF-8 byte per byte")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("100%"), "100%25", "il % stesso, una volta sola")
        XCTAssertEqual(S3Syncer.encodeKeyStrict("a&b=c?d#e"), "a%26b%3Dc%3Fd%23e")
        XCTAssertEqual(S3Syncer.encodeKeyStrict(""), "")
    }

    /// NFC e NFD sono byte diversi e restano diversi: la chiave si manda esattamente come la
    /// lista di Cubbit l'ha data, senza normalizzarla.
    func testStrictEncoding_doesNotNormalizeUnicode() {
        XCTAssertEqual(S3Syncer.encodeKeyStrict("e\u{301}"), "e%CC%81")
        XCTAssertNotEqual(S3Syncer.encodeKeyStrict("e\u{301}"), S3Syncer.encodeKeyStrict("\u{e9}"))
    }

    func testCopySource_hasNoLeadingSlash_andTheSameEncoding() {
        XCTAssertEqual(S3Syncer.copySourceHeader(bucket: "backupfoto", key: "Foto/l'isola+mare.jpg"),
                       "backupfoto/Foto/l%27isola%2Bmare.jpg")
    }

    // MARK: - HEAD

    func testHead_200_givesSizeAndETag() throws {
        let head = try S3Syncer.parseHead(statusCode: 200, contentLength: "2463629",
                                          etag: "\"24cb65338294b62644feec09251bd6ac\"", key: "k")
        XCTAssertEqual(head, S3Syncer.S3ObjectHead(size: 2_463_629, etag: "\"24cb65338294b62644feec09251bd6ac\""))
    }

    func testHead_404_isAMissingObject() throws {
        XCTAssertNil(try S3Syncer.parseHead(statusCode: 404, contentLength: nil, etag: nil, key: "k"))
    }

    /// Un 403 o un 500 non dicono niente sull'oggetto: mai «non c'e'».
    func testHead_otherStatuses_areErrors_neverAMissingObject() {
        for code in [301, 400, 403, 500, 503] {
            XCTAssertThrowsError(try S3Syncer.parseHead(statusCode: code, contentLength: "1", etag: "\"x\"", key: "k"),
                                 "\(code)")
        }
    }

    func testHead_withoutAReadableSize_isAnError() {
        for length in [nil, "", "abc", "-1"] {
            XCTAssertThrowsError(try S3Syncer.parseHead(statusCode: 200, contentLength: length, etag: "\"x\"", key: "k"),
                                 String(describing: length))
        }
    }

    func testHead_withoutETag_isStillAnObject_withoutETag() throws {
        XCTAssertEqual(try S3Syncer.parseHead(statusCode: 200, contentLength: "0", etag: nil, key: "k"),
                       S3Syncer.S3ObjectHead(size: 0, etag: nil))
    }

    // MARK: - Copia lato server

    func testCopy_succeedsOnlyWithAResultInTheBody() {
        let ok = "<?xml version=\"1.0\"?><CopyObjectResult><ETag>&quot;24cb&quot;</ETag></CopyObjectResult>"
        XCTAssertTrue(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ok))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: "<Error><Code>InternalError</Code></Error>"),
                       "S3 puo' rispondere 200 e mettere l'errore nel corpo")
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ""))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 403, body: ok))
        XCTAssertFalse(S3Syncer.copyObjectSucceeded(statusCode: 200, body: ok + "<Error></Error>"))
    }
}
