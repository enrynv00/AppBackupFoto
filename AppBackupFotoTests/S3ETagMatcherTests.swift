import XCTest
@testable import AppBackupFoto

/// `S3ETag`/`S3ETagMatcher` (ROADMAP #44, decisione 1 di Enrico): un oggetto Cubbit e'
/// «certificato» solo se il suo ETag coincide con l'MD5 (caricamento unico) o con l'ETag a
/// pezzi da 64 MiB (`-N`) di un file letto su SSD o HDD della stessa dimensione. Mai per
/// ipotesi. I valori sono quelli di `ContentHasherTests` (stessi byte, stessa fonte `python3`).
final class S3ETagMatcherTests: XCTestCase {
    private let size1000: Int64 = 1000
    private let sizeBig: Int64 = 67_108_865

    private var small: S3ETagMatcher.Candidate {
        .init(size: size1000, sha256: "008549d94fa71e7a0a483d84380d05a923a4b18e79ba1f8a8ddac923956d32ef",
              md5: "e722bbb0c3185d08f1a31567e66a825b", multipartETag: nil)
    }
    private var big: S3ETagMatcher.Candidate {
        .init(size: sizeBig, sha256: "e44417605ed97d14de38fdd4561c81e3f8329f4a6621144e31801c992e397f40",
              md5: "9c800b6accf6f26be7e8684d46ffdedb", multipartETag: "96aa53ed4132d7e2986467263954caad-2")
    }

    // MARK: - Formato

    func testParse_singlePart_withQuotesAndUppercase() {
        XCTAssertEqual(S3ETag.parse("\"E722BBB0C3185D08F1A31567E66A825B\""),
                       .singlePart(md5: "e722bbb0c3185d08f1a31567e66a825b"))
        XCTAssertEqual(S3ETag.parse(" e722bbb0c3185d08f1a31567e66a825b "),
                       .singlePart(md5: "e722bbb0c3185d08f1a31567e66a825b"))
    }

    func testParse_multipart() {
        XCTAssertEqual(S3ETag.parse("\"fc22b3a263f8c63ba9d9f8fbd7a0b713-4\""),
                       .multipart(digest: "fc22b3a263f8c63ba9d9f8fbd7a0b713", parts: 4))
    }

    func testParse_unrecognizedFormats() {
        for raw: String? in [nil, "", "\"\"", "abc", String(repeating: "a", count: 31),
                             String(repeating: "g", count: 32),
                             String(repeating: "a", count: 32) + "-0",
                             String(repeating: "a", count: 32) + "-02",
                             String(repeating: "a", count: 32) + "-10001",
                             String(repeating: "a", count: 32) + "-",
                             String(repeating: "a", count: 32) + "-2-3",
                             String(repeating: "１", count: 32)] {
            XCTAssertEqual(S3ETag.parse(raw), .unrecognized, "formato che non va riconosciuto: \(String(describing: raw))")
        }
    }

    // MARK: - Caricamento unico

    func testSinglePart_sameMD5_isCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"e722bbb0c3185d08f1a31567e66a825b\"", size: size1000, candidates: [small]),
                       .certified(sha256: small.sha256))
    }

    /// Esattamente 64 MiB: caricamento unico, quindi l'ETag e' l'MD5 del file intero.
    func testSinglePart_exactly64MiB_isComparedWithTheMD5() {
        let c = S3ETagMatcher.Candidate(size: 67_108_864,
                                        sha256: "d7279ae9528c7908d99a3c0c84b077e4b5ed515d32fee94847048187d214af3c",
                                        md5: "1c81167936a46883a15d0fe49895453f", multipartETag: nil)
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"1c81167936a46883a15d0fe49895453f\"", size: 67_108_864, candidates: [c]),
                       .certified(sha256: c.sha256))
    }

    /// Nessun file locale con quell'MD5: il contenuto c'e' solo su Cubbit, e lo si riconosce
    /// dall'MD5. Non e' «non certificabile»: l'ETag e' un MD5 vero, manca solo un file da
    /// affiancargli.
    func testSinglePart_noLocalFile_isIdentifiedByItsMD5Only() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"ffffffffffffffffffffffffffffffff\"", size: size1000, candidates: [small]),
                       .identifiedOnlyByMD5(md5: "ffffffffffffffffffffffffffffffff"))
    }

    /// La dimensione fa parte della regola: un file con lo stesso MD5 ma dimensione diversa
    /// non e' un candidato (e per l'MD5 vero non puo' succedere: se succede, e' un dato rotto).
    func testCandidateOfADifferentSize_isIgnored() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"e722bbb0c3185d08f1a31567e66a825b\"", size: 999, candidates: [small]),
                       .identifiedOnlyByMD5(md5: "e722bbb0c3185d08f1a31567e66a825b"))
    }

    /// Due file diversi con lo stesso MD5 (una collisione): non si sceglie a caso.
    func testSinglePart_twoDifferentContentsWithTheSameMD5_isAmbiguous() {
        let twin = S3ETagMatcher.Candidate(size: size1000, sha256: "altro-contenuto", md5: small.md5, multipartETag: nil)
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"\(small.md5)\"", size: size1000, candidates: [small, twin]),
                       .notCertifiable(.ambiguous))
    }

    func testSameContentListedTwice_isStillCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"\(small.md5)\"", size: size1000, candidates: [small, small]),
                       .certified(sha256: small.sha256))
    }

    // MARK: - A pezzi

    func testMultipart_rightETag_isCertified() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-2\"", size: sizeBig, candidates: [big]),
                       .certified(sha256: big.sha256))
    }

    /// Caricato con parti di un'altra dimensione (per esempio rclone): il numero di parti non
    /// torna con 64 MiB, e l'app non puo' ricalcolarlo senza scaricare. Mai «certificato».
    func testMultipart_otherPartSize_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-13\"", size: sizeBig, candidates: [big]),
                       .notCertifiable(.differentPartSize))
    }

    func testMultipart_rightPartCountButDifferentDigest_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"00000000000000000000000000000000-2\"", size: sizeBig, candidates: [big]),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    func testMultipart_noLocalFile_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"96aa53ed4132d7e2986467263954caad-2\"", size: sizeBig, candidates: []),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    /// Una sola parte (`-1`): il risultato non dipende dalla dimensione delle parti, e si
    /// ricalcola dall'MD5 del file (md5 dei 16 byte dell'MD5). Valore da `python3`.
    func testMultipartWithOnePart_isComputedFromTheMD5() {
        XCTAssertEqual(S3ETagMatcher.md5OfMD5Hex(small.md5), "89ce4de5b26c4f12814730135253df12")
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"89ce4de5b26c4f12814730135253df12-1\"", size: size1000, candidates: [small]),
                       .certified(sha256: small.sha256))
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"89ce4de5b26c4f12814730135253df13-1\"", size: size1000, candidates: [small]),
                       .notCertifiable(.noLocalFileProducesIt))
    }

    func testUnrecognizedFormat_isNotCertifiable() {
        XCTAssertEqual(S3ETagMatcher.verdict(etag: "\"boh\"", size: size1000, candidates: [small]),
                       .notCertifiable(.unrecognizedFormat))
        XCTAssertEqual(S3ETagMatcher.verdict(etag: nil, size: size1000, candidates: [small]),
                       .notCertifiable(.unrecognizedFormat))
    }

    func testExpectedParts_followsTheUploadRule() {
        let p = S3Syncer.multipartChunkSize
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: 0, partSize: p), 1)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: Int64(p), partSize: p), 1)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: Int64(p) + 1, partSize: p), 2)
        XCTAssertEqual(S3ETagMatcher.expectedParts(size: 4 * Int64(p), partSize: p), 4)
    }
}
