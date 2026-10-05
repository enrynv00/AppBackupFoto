import XCTest
@testable import AppBackupFoto

/// `RepairRules` (ROADMAP #45, ADR-0016): quando una voce dell'inventario si puo' riparare,
/// quale archivio e' la minoranza, da dove si copia. Ogni condizione della spec («Quando una
/// foto e' riparabile») ha qui almeno un test, e ogni «in ogni altro caso no» il suo.
///
/// Stessa convenzione di `InventoryClassifierTests`: il contenuto «X» ha SHA256 "sha-X" e MD5
/// fatto di 32 volte la lettera minuscola di X; un oggetto Cubbit con quell'MD5 come ETag e'
/// la stessa foto.
final class RepairRulesTests: XCTestCase {
    private let path = "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic"

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func digest(_ c: Character, size: Int64 = 10, multipart: String? = nil) -> ContentDigest {
        ContentDigest(size: size, sha256: "sha-\(c)", md5: md5(c), multipartETag: multipart)
    }

    private func file(_ p: String, _ c: Character, size: Int64 = 10, status: InventoryReadStatus = .ok,
                      digestSize: Int64? = nil, multipart: String? = nil) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(p), displayPath: p, size: size, mtime: 1, status: status,
                           digest: status == .ok ? digest(c, size: digestSize ?? size, multipart: multipart) : nil,
                           hashedAt: 2)
    }

    private func object(_ k: String, etag: String?, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(k), displayKey: k, size: size, etag: etag)
    }

    private func object(_ k: String, _ c: Character, size: Int64 = 10) -> InventoryS3Object {
        object(k, etag: "\"\(md5(c))\"", size: size)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true) -> [InventoryArchive: InventoryArchiveState] {
        func st(_ a: InventoryArchive, _ c: Bool) -> InventoryArchiveState {
            InventoryArchiveState(archive: a, runId: 1, complete: c, reason: c ? nil : .interrupted,
                                  unreadable: 0, startedAt: 0, finishedAt: 1)
        }
        return [.ssd: st(.ssd, ssd), .hdd: st(.hdd, hdd), .s3: st(.s3, s3)]
    }

    private func candidates(ssd: [InventoryLocalFile], hdd: [InventoryLocalFile], s3: [InventoryS3Object],
                            states: [InventoryArchive: InventoryArchiveState]? = nil) -> [RepairCandidate] {
        RepairRules.candidates(in: InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states ?? self.states()))
    }

    // MARK: - Il caso vero: rovinata su Cubbit

    /// La `.heic` del 2026-10-01: integra e identica su SSD e HDD, su Cubbit stessa dimensione
    /// ma contenuto diverso (ETag a parte unica = MD5 diverso).
    func testBrokenOnCubbit_isRepairedFromTheSSD_withTheHDDAsWitness() throws {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "b")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(only.key, normalizedIndexKey(path))
        XCTAssertEqual(only.target, .s3)
        XCTAssertEqual(only.source, .ssd)
        XCTAssertEqual(only.witness, .hdd)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSize, 10)
        XCTAssertEqual(only.badETag, "\"\(md5("b"))\"")
        XCTAssertNil(only.badSHA256)
        XCTAssertEqual(only.paths, [.ssd: path, .hdd: path, .s3: path])
    }

    /// Su Cubbit la dimensione diversa non cambia niente: l'MD5 diverso basta a dimostrare che
    /// il contenuto e' un altro.
    func testBrokenOnCubbit_withADifferentSize_isStillRepairable() {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "b", size: 7)])
        XCTAssertEqual(c.map(\.target), [.s3])
        XCTAssertEqual(c.first?.badSize, 7)
    }

    /// Il percorso su Cubbit si porta con le maiuscole vere; la chiave e' quella normalizzata.
    func testPaths_keepTheRealCaseOfEachArchive() {
        let c = candidates(ssd: [file("Foto/IMG_1.JPG", "a")], hdd: [file("foto/img_1.jpg", "a")],
                           s3: [object("Foto/IMG_1.JPG", "b")])
        XCTAssertEqual(c.first?.paths, [.ssd: "Foto/IMG_1.JPG", .hdd: "foto/img_1.jpg", .s3: "Foto/IMG_1.JPG"])
    }

    // MARK: - Rovinata su un disco

    func testBrokenOnTheHDD_isRepairedFromTheSSD_withCubbitAsWitness() throws {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "b")], s3: [object(path, "a")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(only.target, .hdd)
        XCTAssertEqual(only.source, .ssd)
        XCTAssertEqual(only.witness, .s3)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSHA256, "sha-b")
        XCTAssertNil(only.badETag)
    }

    /// Decisione 2 di Enrico: si ripara anche l'SSD, con la stessa regola — dall'HDD.
    func testBrokenOnTheSSD_isRepairedFromTheHDD_withCubbitAsWitness() throws {
        let c = candidates(ssd: [file(path, "b")], hdd: [file(path, "a")], s3: [object(path, "a")])
        let only = try XCTUnwrap(c.first)
        XCTAssertEqual(only.target, .ssd)
        XCTAssertEqual(only.source, .hdd)
        XCTAssertEqual(only.witness, .s3)
        XCTAssertEqual(only.good, digest("a"))
        XCTAssertEqual(only.badSHA256, "sha-b")
    }

    /// Cubbit certifica anche con l'ETag a pezzi (qui finto, ma nella forma giusta).
    func testCubbitCertifyingWithAMultipartETag_canBeTheWitness() {
        let etag = "\(md5("c"))-2"
        let c = candidates(ssd: [file(path, "a", multipart: etag)], hdd: [file(path, "b")],
                           s3: [object(path, etag: "\"\(etag)\"")])
        XCTAssertEqual(c.map(\.target), [.hdd])
    }

    // MARK: - In ogni altro caso no

    func testAllThreeAgree_isNothingToRepair() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, "a")]).isEmpty)
    }

    func testThreeDifferentContents_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "b")], s3: [object(path, "c")]).isEmpty)
    }

    /// Incompleto non e' assente (ADR-0015): con un archivio letto a meta' non si ripara
    /// niente, nemmeno quello che sembrerebbe chiarissimo.
    func testAnyArchiveIncomplete_blocksEveryRepair() {
        let ssd = [file(path, "a")], hdd = [file(path, "a")], s3 = [object(path, "b")]
        for st in [states(ssd: false), states(hdd: false), states(s3: false)] {
            XCTAssertTrue(candidates(ssd: ssd, hdd: hdd, s3: s3, states: st).isEmpty)
        }
        XCTAssertTrue(candidates(ssd: ssd, hdd: hdd, s3: s3, states: [:]).isEmpty, "mai letto")
    }

    func testPathMissingFromOneArchive_isNotRepairable() {
        let a = file(path, "a"), o = object(path, "b")
        XCTAssertTrue(candidates(ssd: [], hdd: [a], s3: [o]).isEmpty)
        XCTAssertTrue(candidates(ssd: [a], hdd: [], s3: [o]).isEmpty)
        XCTAssertTrue(candidates(ssd: [a], hdd: [a], s3: []).isEmpty)
    }

    func testCubbitETagInAnUnknownFormat_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, etag: "\"boh\"")]).isEmpty)
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a")], s3: [object(path, etag: nil)]).isEmpty)
    }

    /// Un ETag a pezzi che non torna NON dimostra un contenuto diverso (parti di altra
    /// dimensione): la voce resta in ❗ senza «Ripara…».
    func testCubbitMultipartETagThatDoesNotMatch_isNotProofOfDamage() {
        let c = candidates(ssd: [file(path, "a")], hdd: [file(path, "a")],
                           s3: [object(path, etag: "\"\(md5("b"))-3\"")])
        XCTAssertTrue(c.isEmpty)
    }

    /// SSD e HDD diversi e Cubbit che non certifica nessuno dei due: tre contenuti, nessuna
    /// maggioranza.
    func testDisksDisagree_andCubbitCertifiesNeither_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "b")],
                                 s3: [object(path, etag: "\"\(md5("a"))-2\"")]).isEmpty)
    }

    /// Due file con lo stesso percorso a meno delle maiuscole dentro un archivio: quale dei
    /// due e' «la» copia? Non si sceglie.
    func testCaseCollisionInsideOneArchive_isNotRepairable() {
        let c = candidates(ssd: [file("Foto/A.jpg", "a")], hdd: [file("Foto/A.jpg", "b"), file("Foto/a.jpg", "a")],
                           s3: [object("Foto/A.jpg", "a")])
        XCTAssertTrue(c.isEmpty)
    }

    func testUnreadableLocalCopy_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a")], hdd: [file(path, "a", status: .unreadable)],
                                 s3: [object(path, "b")]).isEmpty)
        XCTAssertTrue(candidates(ssd: [file(path, "a", status: .changedWhileReading)], hdd: [file(path, "a")],
                                 s3: [object(path, "b")]).isEmpty)
    }

    /// La dimensione della copia buona deve essere la stessa letta dal disco.
    func testGoodCopyWhoseSizeDoesNotMatchItsFile_isNotRepairable() {
        XCTAssertTrue(candidates(ssd: [file(path, "a", digestSize: 11)], hdd: [file(path, "a")],
                                 s3: [object(path, "b")]).isEmpty)
    }

    /// Su Cubbit si sovrascrive solo dove la richiesta di caricamento e quelle nuove mandano
    /// lo stesso percorso.
    func testCubbitKeyWithPlusOrApostrophe_isNotRepairedOnCubbit() {
        for p in ["Foto/a+b.jpg", "Foto/l'isola.jpg", "Foto/a&b.jpg"] {
            XCTAssertTrue(candidates(ssd: [file(p, "a")], hdd: [file(p, "a")], s3: [object(p, "b")]).isEmpty, p)
        }
    }

    /// Sui dischi lo stesso nome si ripara: a Cubbit si chiede solo una HEAD.
    func testDiskTargetWithPlusOrApostrophe_isRepairable() {
        let p = "Foto/l'isola+mare.jpg"
        XCTAssertEqual(candidates(ssd: [file(p, "a")], hdd: [file(p, "b")], s3: [object(p, "a")]).map(\.target), [.hdd])
    }

    func testPathsInsideTheQuarantine_areNeverCandidates() {
        let q = "_quarantena/2026-10-04/" + path
        XCTAssertTrue(candidates(ssd: [file(q, "a")], hdd: [file(q, "a")], s3: [object(q, "b")]).isEmpty)
    }

    func testSeveralCandidates_comeInPathOrder() {
        let c = candidates(ssd: [file("b.jpg", "a"), file("a.jpg", "c")], hdd: [file("b.jpg", "a"), file("a.jpg", "d")],
                           s3: [object("b.jpg", "e"), object("a.jpg", "c")])
        XCTAssertEqual(c.map(\.key), ["a.jpg", "b.jpg"])
        XCTAssertEqual(c.map(\.target), [.hdd, .s3])
    }

    // MARK: - Piccole regole

    func testSourceAndWitness_forEachTarget() {
        XCTAssertEqual(RepairRules.source(forTarget: .s3), .ssd)
        XCTAssertEqual(RepairRules.source(forTarget: .hdd), .ssd)
        XCTAssertEqual(RepairRules.source(forTarget: .ssd), .hdd)
        XCTAssertEqual(RepairRules.witness(forTarget: .s3), .hdd)
        XCTAssertEqual(RepairRules.witness(forTarget: .hdd), .s3)
        XCTAssertEqual(RepairRules.witness(forTarget: .ssd), .s3)
    }

    /// Dopo il caricamento: l'MD5 fino a 64 MiB compresi, l'ETag a pezzi sopra. La `.heic`:
    /// 2.463.629 byte, caricamento unico, ETag atteso `b59917c9c6e38fccab5ce3f30c90d13a`.
    func testExpectedCubbitETag() {
        XCTAssertEqual(RepairRules.expectedCubbitETag(for: ContentDigest(size: 2_463_629, sha256: "s",
                       md5: "b59917c9c6e38fccab5ce3f30c90d13a", multipartETag: nil)), "b59917c9c6e38fccab5ce3f30c90d13a")
        XCTAssertEqual(RepairRules.expectedCubbitETag(for: digest("a", size: 70_000_000, multipart: "\(md5("c"))-2")),
                       "\(md5("c"))-2")
    }

    func testNormalizedETag() {
        XCTAssertEqual(RepairRules.normalizedETag("\"24CB65338294B62644FEEC09251BD6AC\" "), "24cb65338294b62644feec09251bd6ac")
        XCTAssertEqual(RepairRules.normalizedETag("abc-2"), "abc-2")
        XCTAssertNil(RepairRules.normalizedETag(nil))
        XCTAssertNil(RepairRules.normalizedETag(""))
        XCTAssertNil(RepairRules.normalizedETag("\"\""))
    }

    func testCubbitKeyIsRepairable() {
        XCTAssertTrue(RepairRules.cubbitKeyIsRepairable(path))
        XCTAssertTrue(RepairRules.cubbitKeyIsRepairable("Foto/Città è.jpg"), "fuori dall'ASCII le codifiche coincidono")
        for k in ["a+b.jpg", "l'isola.jpg", "a&b.jpg", "a=b.jpg", "a(1).jpg", "a@b.jpg"] {
            XCTAssertFalse(RepairRules.cubbitKeyIsRepairable(k), k)
        }
    }
}
