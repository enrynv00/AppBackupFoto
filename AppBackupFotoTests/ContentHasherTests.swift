import XCTest
import CryptoKit
@testable import AppBackupFoto

/// `ContentHasher` (ROADMAP #44, ADR-0015): una lettura, tre impronte — SHA256, MD5 e l'ETag
/// a pezzi da 64 MiB che Cubbit assegna ai file caricati in piu' parti.
///
/// I valori attesi NON sono stati calcolati con questo codice: vengono da `python3`
/// (`hashlib.sha256`/`hashlib.md5`, ETag = md5 della concatenazione degli md5 binari delle
/// parti, piu' `-N`) e sono stati ricontrollati con `shasum -a 256` e `md5` sugli stessi byte,
/// il 2026-09-26. I byte sono deterministici: il byte i vale (i*31 + 7) % 251.
final class ContentHasherTests: XCTestCase {
    private let mib64 = 64 * 1024 * 1024
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentHasherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// n byte con il byte i = (i*31 + 7) % 251. La sequenza ha periodo 251, quindi si
    /// costruisce raddoppiando un blocco da 251 byte (veloce anche per 128 MiB in Debug).
    static func pattern(_ n: Int) -> Data {
        var block = Data((0..<251).map { UInt8(($0 * 31 + 7) % 251) })
        while block.count < n { block.append(block) }
        return Data(block.prefix(n))
    }

    private func digest(_ data: Data, partSize: Int = S3Syncer.multipartChunkSize, chunk: Int? = nil) -> ContentDigest {
        var h = ContentHasher(partSize: partSize)
        if let chunk {
            var i = 0
            while i < data.count {
                let end = min(data.count, i + chunk)
                h.update(data.subdata(in: i..<end))
                i = end
            }
        } else {
            h.update(data)
        }
        return h.finalize()
    }

    // MARK: - Valori di riferimento

    func testEmpty() {
        let d = digest(Data())
        XCTAssertEqual(d.size, 0)
        XCTAssertEqual(d.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(d.md5, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertNil(d.multipartETag)
    }

    func testOneByte() {
        let d = digest(Self.pattern(1))
        XCTAssertEqual(d.sha256, "ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879")
        XCTAssertEqual(d.md5, "89e74e640b8c46257a29de0616794d5d")
        XCTAssertNil(d.multipartETag)
    }

    func testThousandBytes() {
        let d = digest(Self.pattern(1000))
        XCTAssertEqual(d.size, 1000)
        XCTAssertEqual(d.sha256, "008549d94fa71e7a0a483d84380d05a923a4b18e79ba1f8a8ddac923956d32ef")
        XCTAssertEqual(d.md5, "e722bbb0c3185d08f1a31567e66a825b")
        XCTAssertNil(d.multipartETag)
    }

    /// Il caso limite che decide tutto: `S3Syncer.upload` passa al caricamento a pezzi solo con
    /// `size > multipartChunkSize`. Esattamente 64 MiB e' quindi un caricamento UNICO, e il suo
    /// ETag su Cubbit e' l'MD5: qui non deve esserci nessun ETag a pezzi.
    func testExactly64MiB_isASinglePart() {
        let d = digest(Self.pattern(mib64))
        XCTAssertEqual(d.size, Int64(mib64))
        XCTAssertEqual(d.sha256, "d7279ae9528c7908d99a3c0c84b077e4b5ed515d32fee94847048187d214af3c")
        XCTAssertEqual(d.md5, "1c81167936a46883a15d0fe49895453f")
        XCTAssertNil(d.multipartETag, "64 MiB esatti: Cubbit li riceve con un caricamento unico")
    }

    /// Un byte in piu': due parti, la seconda da 1 byte.
    func test64MiBPlusOne_isTwoParts() {
        let d = digest(Self.pattern(mib64 + 1))
        XCTAssertEqual(d.sha256, "e44417605ed97d14de38fdd4561c81e3f8329f4a6621144e31801c992e397f40")
        XCTAssertEqual(d.md5, "9c800b6accf6f26be7e8684d46ffdedb")
        XCTAssertEqual(d.multipartETag, "96aa53ed4132d7e2986467263954caad-2")
    }

    func testTwoPartsAndABit_isThreeParts() {
        let d = digest(Self.pattern(2 * mib64 + 12_345))
        XCTAssertEqual(d.size, Int64(2 * mib64 + 12_345))
        XCTAssertEqual(d.sha256, "bb7eb580b9968c7b39adcfcd02c9c71756f3b0744f0f789584107344d1ca4023")
        XCTAssertEqual(d.md5, "8ea3de5a355296de9f08a2091e627443")
        XCTAssertEqual(d.multipartETag, "e260e09492e358dfcf24368dcb3b0d4f-3")
    }

    /// Le parti si contano sui byte, non sulle letture: pezzi da 1.000.003 byte (che non
    /// dividono 64 MiB) devono dare lo stesso ETag. E' il caso reale di `read()` che restituisce
    /// meno byte di quanti ne ha chiesti.
    func testHowTheBytesArrive_doesNotChangeTheResult() {
        let data = Self.pattern(mib64 + 1)
        XCTAssertEqual(digest(data, chunk: 1_000_003), digest(data))
    }

    /// Parti piccole per vedere i confini senza file enormi (valori da `python3`, parti da 4).
    func testSmallPartSize_boundaries() {
        XCTAssertNil(digest(Self.pattern(4), partSize: 4).multipartETag, "una parte piena sola: caricamento unico")
        XCTAssertEqual(digest(Self.pattern(8), partSize: 4).multipartETag, "3060bef1713675e57187df2d94b5913e-2")
        XCTAssertEqual(digest(Self.pattern(9), partSize: 4).multipartETag, "038a681c2984a3fcb1f6eac9f2bc92c0-3")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4).multipartETag, "31c509ee7df935ddc35518ca34642cf7-3")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4, chunk: 1).multipartETag,
                       "31c509ee7df935ddc35518ca34642cf7-3", "un byte alla volta, stesso risultato")
        XCTAssertEqual(digest(Self.pattern(10), partSize: 4, chunk: 3).multipartETag,
                       "31c509ee7df935ddc35518ca34642cf7-3")
    }

    /// La dimensione delle parti e' quella con cui l'app carica su Cubbit: una sola fonte.
    func testDefaultPartSize_isTheUploadPartSize() {
        XCTAssertEqual(ContentHasher().partSize, S3Syncer.multipartChunkSize)
        XCTAssertEqual(S3Syncer.multipartChunkSize, 67_108_864)
    }

    // MARK: - Lettura da file

    func testDigestFile_matchesTheReferenceValues() throws {
        let url = tmp.appendingPathComponent("grande.mov")
        try Self.pattern(2 * mib64 + 12_345).write(to: url)
        guard case .digest(let d) = ContentHasher.digestFile(at: url) else {
            return XCTFail("un file leggibile deve dare le impronte")
        }
        XCTAssertEqual(d.sha256, "bb7eb580b9968c7b39adcfcd02c9c71756f3b0744f0f789584107344d1ca4023")
        XCTAssertEqual(d.md5, "8ea3de5a355296de9f08a2091e627443")
        XCTAssertEqual(d.multipartETag, "e260e09492e358dfcf24368dcb3b0d4f-3")
    }

    func testDigestFile_emptyFile() throws {
        let url = tmp.appendingPathComponent("vuoto.jpg")
        try Data().write(to: url)
        XCTAssertEqual(ContentHasher.digestFile(at: url), .digest(digest(Data())))
    }

    func testDigestFile_missingFile_isUnreadable() {
        XCTAssertEqual(ContentHasher.digestFile(at: tmp.appendingPathComponent("non-c-e.jpg")), .unreadable)
    }

    func testDigestFile_withoutPermission_isUnreadable() throws {
        let url = tmp.appendingPathComponent("chiuso.jpg")
        try Self.pattern(1000).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertEqual(ContentHasher.digestFile(at: url), .unreadable)
    }

    /// Il file cambia dimensione mentre lo si legge: le impronte non valgono niente. Il
    /// troncamento avviene alla prima domanda "devo fermarmi?", cioe' dopo il primo `fstat`
    /// e prima della prima lettura — deterministico, nessuna corsa.
    func testDigestFile_fileTruncatedWhileReading_isChanged() throws {
        let url = tmp.appendingPathComponent("cambia.jpg")
        try Self.pattern(5_000_000).write(to: url)
        var truncated = false
        let outcome = ContentHasher.digestFile(at: url, isCancelled: {
            if !truncated {
                truncated = true
                if let fh = try? FileHandle(forWritingTo: url) { try? fh.truncate(atOffset: 6); try? fh.close() }
            }
            return false
        })
        XCTAssertTrue(truncated)
        XCTAssertEqual(outcome, .changedWhileReading)
    }

    func testDigestFile_cancelled() throws {
        let url = tmp.appendingPathComponent("fermo.jpg")
        try Self.pattern(1000).write(to: url)
        XCTAssertEqual(ContentHasher.digestFile(at: url, isCancelled: { true }), .cancelled)
    }


    // MARK: - Forme alternative dell'ETag (2026-09-30, oggetti reali caricati a pezzi da 128 MiB)

    /// Riferimento indipendente: le parti si tagliano a mano sul `Data`, senza `ContentHasher`.
    private func referenceETags(_ data: Data, partSize: Int) -> (binary: String, text: String) {
        var digests = Data(); var hexes = ""; var count = 0
        var start = 0
        while start < data.count {
            let end = min(start + partSize, data.count)
            let d = Insecure.MD5.hash(data: data.subdata(in: start..<end))
            digests.append(contentsOf: d)
            hexes += d.map { String(format: "%02x", $0) }.joined()
            count += 1
            start = end
        }
        let hex = { (x: Insecure.MD5.Digest) in x.map { String(format: "%02x", $0) }.joined() }
        return (hex(Insecure.MD5.hash(data: digests)) + "-\(count)",
                hex(Insecure.MD5.hash(data: Data(hexes.utf8))) + "-\(count)")
    }

    func testAlternativeETags_standardPartsTextFormula_andLegacyPartsBothFormulas() {
        let data = Data((0..<21).map { UInt8($0 * 7 & 0xff) })
        var h = ContentHasher(partSize: 4, legacyPartSize: 8)
        h.update(data)
        let d = h.finalize()
        let std = referenceETags(data, partSize: 4), legacy = referenceETags(data, partSize: 8)
        XCTAssertEqual(d.multipartETag, std.binary)
        XCTAssertEqual(d.alternativeMultipartETags, [std.text, legacy.binary, legacy.text])
    }

    /// Fra le due dimensioni di parte: solo la formula «in testo» delle parti piccole. Con parti
    /// da 128 MiB un file cosi' e' una parte sola, e quella la riconosce il confronto dall'MD5.
    func testAlternativeETags_betweenTheTwoPartSizes_onlyTheTextFormula() {
        let data = Data((0..<6).map { UInt8($0) })
        var h = ContentHasher(partSize: 4, legacyPartSize: 8)
        h.update(data)
        XCTAssertEqual(h.finalize().alternativeMultipartETags, [referenceETags(data, partSize: 4).text])
    }

    func testAlternativeETags_emptyUpToThePartSize() {
        var h = ContentHasher(partSize: 4, legacyPartSize: 8)
        h.update(Data([1, 2, 3, 4]))
        let d = h.finalize()
        XCTAssertNil(d.multipartETag)
        XCTAssertEqual(d.alternativeMultipartETags, [])
        XCTAssertFalse(d.needsAlternativeETags)
    }

    /// Un'impronta salvata prima delle forme alternative va riletta, solo se il file e' grande.
    func testNeedsAlternativeETags_onlyForBigFilesWithoutThem() {
        let big = Int64(S3Syncer.multipartChunkSize) + 1
        XCTAssertTrue(ContentDigest(size: big, sha256: "s", md5: "m", multipartETag: "x-2").needsAlternativeETags)
        XCTAssertFalse(ContentDigest(size: big, sha256: "s", md5: "m", multipartETag: "x-2",
                                     alternativeMultipartETags: ["y-2"]).needsAlternativeETags)
        XCTAssertFalse(ContentDigest(size: 10, sha256: "s", md5: "m", multipartETag: nil).needsAlternativeETags)
    }

    func testStoredETagColumn_roundTrips() {
        let d = ContentDigest(size: 1, sha256: "s", md5: "m", multipartETag: "a-2", alternativeMultipartETags: ["b-2", "c-1"])
        XCTAssertEqual(d.storedETagColumn, "a-2 b-2 c-1")
        let back = ContentDigest.splitStoredETagColumn(d.storedETagColumn)
        XCTAssertEqual(back.primary, "a-2")
        XCTAssertEqual(back.alternatives, ["b-2", "c-1"])
        XCTAssertNil(ContentDigest.splitStoredETagColumn(nil).primary)
        XCTAssertEqual(ContentDigest.splitStoredETagColumn("solo-3").alternatives, [])
    }
}
