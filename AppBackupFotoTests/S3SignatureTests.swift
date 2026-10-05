import XCTest
@testable import AppBackupFoto

/// La firma SigV4 (ROADMAP #45). La riparazione aggiunge due richieste nuove — HEAD e copia
/// lato server, con l'intestazione `x-amz-copy-source` firmata — e per farlo la firma e' stata
/// divisa: `S3Syncer.sigV4Signature` (pura) e `sign` (che costruisce la richiesta canonica).
///
/// Da dove vengono i valori attesi, perche' nessuno e' stato calcolato con questo codice:
/// - i primi tre sono gli esempi PUBBLICATI da AWS nella documentazione di S3 («Signature
///   Calculations for the Authorization Header», bucket `examplebucket`, 24/05/2013);
/// - gli altri sono stati calcolati con uno script python indipendente (`hmac`/`hashlib`), lo
///   stesso che riproduce esattamente i tre esempi di AWS, il 2026-10-04.
final class S3SignatureTests: XCTestCase {
    private let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    private let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let date = Date(timeIntervalSince1970: 1_791_115_200)   // 2026-10-04T12:00:00Z
    private let heic = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"

    private var config: S3Syncer.S3Config {
        S3Syncer.S3Config(accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: secret,
                          endpoint: "https://s3.it.cubbit.org", region: "auto", bucket: "backupfoto")
    }

    private func awsHeaders(_ extra: [String: String] = [:]) -> [String: String] {
        var h = ["host": "examplebucket.s3.amazonaws.com", "x-amz-content-sha256": empty,
                 "x-amz-date": "20130524T000000Z"]
        h.merge(extra) { $1 }
        return h
    }

    private func expected(_ signedHeaders: String, _ signature: String) -> String {
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261004/us-east-1/s3/aws4_request, "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    // MARK: - Esempi pubblicati da AWS

    func testAWSExample_getObjectWithRange() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/test.txt", canonicalQuery: "",
                                        headers: awsHeaders(["range": "bytes=0-9"]), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signedHeaders, "host;range;x-amz-content-sha256;x-amz-date")
        XCTAssertEqual(s.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testAWSExample_getBucketLifecycle() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/", canonicalQuery: "lifecycle=",
                                        headers: awsHeaders(), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signature, "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    func testAWSExample_listObjects() {
        let s = S3Syncer.sigV4Signature(method: "GET", canonicalURI: "/", canonicalQuery: "max-keys=2&prefix=J",
                                        headers: awsHeaders(), payloadHash: empty,
                                        amzDate: "20130524T000000Z", secretAccessKey: secret, region: "us-east-1")
        XCTAssertEqual(s.signature, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    // MARK: - `sign`: le richieste di sempre non cambiano

    /// La lista con un token che contiene `+` (BUG-8): stessa firma di prima della divisione.
    func testListRequest_isSignedAsBefore() throws {
        var req = URLRequest(url: try XCTUnwrap(URL(string:
            "https://s3.it.cubbit.org/backupfoto?list-type=2&max-keys=1000&continuation-token=a%2Bb")))
        req.httpMethod = "GET"
        S3Syncer().sign(&req, config: config, body: Data(), date: date)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-date"), "20261004T120000Z")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-content-sha256"), empty)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "b3253f5a6b2934ddbe8e9b059fd4af56febab5635e4818d5cd9daeed908375a6"))
    }

    /// La lista con `prefix` costruita come `fetchListPageXML`: la `/` del prefisso entra
    /// nella firma come `%2F`.
    func testListWithPrefix_isSigned() throws {
        var comps = try XCTUnwrap(URLComponents(string: "https://s3.it.cubbit.org/backupfoto"))
        comps.queryItems = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "max-keys", value: "1000"),
                            URLQueryItem(name: "prefix", value: "_quarantena/")]
        comps.percentEncodedQuery = S3Syncer.encodePlusInQuery(comps.percentEncodedQuery)
        var req = URLRequest(url: try XCTUnwrap(comps.url))
        req.httpMethod = "GET"
        S3Syncer().sign(&req, config: config, body: Data(), date: date)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "d6197d250a3392491616ab933589414cfd124fc89e78e6f58fa1e5167e1e7ea0"))
    }

    // MARK: - Le richieste nuove

    func testHeadRequest_isSignedOnTheSamePathItSends() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: heic)
        XCTAssertEqual(path, "/backupfoto/Foto%20iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "HEAD"
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path)
        XCTAssertEqual(req.url?.absoluteString, "https://s3.it.cubbit.org" + path, "il percorso viaggia com'e' firmato")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "01a74f23090b90d4a69b97fa48e0216cc0c168e5c84c3212d1ac9cfe6f4fb095"))
    }

    /// La copia in quarantena: `x-amz-copy-source` viaggia nella richiesta ED e' firmata.
    func testCopyRequest_signsTheCopySource() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: "_quarantena/2026-10-04/" + heic)
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "PUT"
        let source = S3Syncer.copySourceHeader(bucket: "backupfoto", key: heic)
        XCTAssertEqual(source, "backupfoto/Foto%20iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path,
                        extraSignedHeaders: ["x-amz-copy-source": source])
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-copy-source"), source)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       expected("host;x-amz-content-sha256;x-amz-copy-source;x-amz-date",
                                "a4fb3b12bb2aff051c5fa6db6e516acd81ddc593e926d59fc16efeb0e6dc7b1f"))
    }

    /// `+`, apostrofo e lettere accentate (la famiglia di BUG-8): codificati una volta sola,
    /// uguali nella richiesta e nella firma.
    func testSpecialCharacters_areSignedAsSent() throws {
        let path = S3Syncer.objectRequestPath(bucket: "backupfoto", key: "Foto/l'isola+mare è.jpg")
        XCTAssertEqual(path, "/backupfoto/Foto/l%27isola%2Bmare%20%C3%A8.jpg")
        var req = URLRequest(url: try XCTUnwrap(URL(string: "https://s3.it.cubbit.org" + path)))
        req.httpMethod = "HEAD"
        S3Syncer().sign(&req, config: config, body: Data(), date: date, canonicalURI: path)
        XCTAssertEqual(req.url?.absoluteString, "https://s3.it.cubbit.org" + path)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expected("host;x-amz-content-sha256;x-amz-date",
            "2a4a8165db747c973f5889fb4fdd66de7266cdb0432a51712298ec74203b4768"))
    }
}
