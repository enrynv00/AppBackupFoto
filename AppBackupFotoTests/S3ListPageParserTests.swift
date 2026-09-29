import XCTest
@testable import AppBackupFoto

/// `S3Syncer.parseListPage` (ROADMAP #44): una pagina di `ListObjectsV2` letta oggetto per
/// oggetto, con l'ETag. Il vecchio `listPage` legge chiavi e dimensioni in due liste separate e
/// le accoppia per posizione: per l'ETag questo non basta, perche' un oggetto senza ETag
/// sposterebbe tutti i successivi di un posto e l'ETag di un file finirebbe su un altro — cioe'
/// un contenuto "certificato" su una chiave che non lo contiene.
final class S3ListPageParserTests: XCTestCase {

    private func page(_ contents: String, truncated: Bool = false, token: String? = nil) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>backupfoto</Name>"
        xml += "<IsTruncated>\(truncated ? "true" : "false")</IsTruncated>"
        xml += contents
        if let token { xml += "<NextContinuationToken>\(token)</NextContinuationToken>" }
        return xml + "</ListBucketResult>"
    }

    private func object(_ key: String, size: String, etag: String?) -> String {
        var s = "<Contents><Key>\(key)</Key><LastModified>2026-09-26T10:00:00.000Z</LastModified>"
        if let etag { s += "<ETag>\(etag)</ETag>" }
        return s + "<Size>\(size)</Size><StorageClass>STANDARD</StorageClass></Contents>"
    }

    func testKeySizeAndETag_areReadPerObject() {
        let p = S3Syncer.parseListPage(page(
            object("Foto iPhone/IMG_1.JPG", size: "1000", etag: "&quot;e722bbb0c3185d08f1a31567e66a825b&quot;")
            + object("ASUS/Elba/FILE0056.MOV", size: "67108865", etag: "&quot;96aa53ed4132d7e2986467263954caad-2&quot;")))
        XCTAssertEqual(p.objects, [
            S3Syncer.S3ObjectInfo(key: "Foto iPhone/IMG_1.JPG", size: 1000, etag: "\"e722bbb0c3185d08f1a31567e66a825b\""),
            S3Syncer.S3ObjectInfo(key: "ASUS/Elba/FILE0056.MOV", size: 67_108_865, etag: "\"96aa53ed4132d7e2986467263954caad-2\""),
        ])
        XCTAssertEqual(p.malformedEntries, 0)
    }

    /// Il punto per cui esiste questo parser: un oggetto senza ETag resta senza, e non prende
    /// quello dell'oggetto dopo.
    func testMissingETag_staysMissing_andDoesNotShiftTheOthers() {
        let p = S3Syncer.parseListPage(page(
            object("a.jpg", size: "1", etag: nil)
            + object("b.jpg", size: "2", etag: "&quot;bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&quot;")))
        XCTAssertEqual(p.objects.map(\.key), ["a.jpg", "b.jpg"])
        XCTAssertNil(p.objects[0].etag)
        XCTAssertEqual(p.objects[1].etag, "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"")
    }

    /// Le chiavi di BUG-8: apostrofo scritto `&#39;`, `&amp;`.
    func testKeysWithEntities_areDecoded() {
        let p = S3Syncer.parseListPage(page(
            object("ASUS/Enrico Nanni Vicenzi/l&#39;estate.jpg", size: "3", etag: "&quot;x&quot;")
            + object("Foto/a &amp; b.jpg", size: "4", etag: "&quot;y&quot;")))
        XCTAssertEqual(p.objects.map(\.key), ["ASUS/Enrico Nanni Vicenzi/l'estate.jpg", "Foto/a & b.jpg"])
    }

    /// Una voce senza dimensione (o con una dimensione che non e' un numero) non si inventa:
    /// si salta e si conta, e chi legge la pagina sa che l'elenco non e' integro.
    func testEntryWithoutAReadableSize_isCountedAsMalformed() {
        let p = S3Syncer.parseListPage(page(
            "<Contents><Key>senza-dimensione.jpg</Key></Contents>"
            + object("dimensione-strana.jpg", size: "tanti", etag: nil)
            + object("buono.jpg", size: "7", etag: nil)))
        XCTAssertEqual(p.objects.map(\.key), ["buono.jpg"])
        XCTAssertEqual(p.malformedEntries, 2)
    }

    func testUnclosedContents_isMalformed() {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key><Size>1</Size></ListBucketResult>"
        let p = S3Syncer.parseListPage(xml)
        XCTAssertTrue(p.objects.isEmpty)
        XCTAssertEqual(p.malformedEntries, 1)
    }

    /// Una risposta che non e' una lista (vuota, un errore, un corpo troncato) non deve MAI
    /// leggersi come «lista finita e vuota»: ogni foto risulterebbe mancante da Cubbit.
    func testResponseWithoutTheListEnvelope_isMalformed() {
        for body in ["", "<Error><Code>InternalError</Code></Error>",
                     "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.jpg</Key><Size>1</Size></Contents>"] {
            XCTAssertGreaterThan(S3Syncer.parseListPage(body).malformedEntries, 0, "«\(body)»")
        }
    }

    func testTruncatedPage_givesTheNextToken() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: true, token: "ASUS/x+y.jpg"))
        XCTAssertTrue(p.isTruncated)
        XCTAssertEqual(p.nextToken, "ASUS/x+y.jpg")
    }

    /// "Ce n'e' ancora, ma non ti dico da dove": chi legge deve poterlo distinguere da "finito".
    func testTruncatedPageWithoutToken_saysSo() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: true, token: nil))
        XCTAssertTrue(p.isTruncated)
        XCTAssertNil(p.nextToken)
    }

    func testLastPage_ignoresAnyToken() {
        let p = S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil), truncated: false, token: "t"))
        XCTAssertFalse(p.isTruncated)
        XCTAssertNil(p.nextToken)
    }

    func testEmptyPage() {
        let p = S3Syncer.parseListPage(page(""))
        XCTAssertTrue(p.objects.isEmpty)
        XCTAssertEqual(p.malformedEntries, 0)
        XCTAssertFalse(p.isTruncated)
    }

    /// `xmlDecode` deve essere usabile fuori dal main (l'inventario legge le pagine in un
    /// `Task.detached`): stessa funzione dei test di BUG-8, stesso risultato.
    func testXmlDecode_isTheSameFunctionUsedByTheList() {
        XCTAssertEqual(S3Syncer.xmlDecode("&quot;abc&quot;"), "\"abc\"")
    }

    /// Un token vuoto non e' un token: la pagina e' troncata senza un modo di proseguire, e chi
    /// legge deve trattarla come lista incompleta, non richiedere di nuovo la stessa pagina.
    func testTruncatedWithAnEmptyToken_hasNoNextToken() {
        XCTAssertNil(S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil),
                                                 truncated: true, token: "")).nextToken)
        XCTAssertNil(S3Syncer.parseListPage(page(object("a.jpg", size: "1", etag: nil),
                                                 truncated: true, token: "  ")).nextToken)
    }
}
