import XCTest
@testable import AppBackupFoto

/// `InventoryClassifier` (ROADMAP #44): dai tre elenchi alle categorie. E' il pezzo su cui i
/// progetti 2-4 decideranno copie e cancellazioni, quindi ogni regola della spec ha qui almeno
/// un test, e ogni precedenza il suo.
///
/// Convenzione dei dati finti: il contenuto «X» ha SHA256 "sha-X" e MD5 fatto di 32 volte la
/// lettera minuscola di X (esadecimale valido per a-f); l'oggetto Cubbit con ETag uguale a
/// quell'MD5 e' la stessa foto.
final class InventoryClassifierTests: XCTestCase {

    private func md5(_ c: Character) -> String { String(repeating: c, count: 32) }

    private func file(_ path: String, _ content: Character, size: Int64 = 10,
                      status: InventoryReadStatus = .ok) -> InventoryLocalFile {
        InventoryLocalFile(key: normalizedIndexKey(path), displayPath: path, size: size, mtime: 1,
                           status: status,
                           digest: status == .ok
                               ? ContentDigest(size: size, sha256: "sha-\(content)", md5: md5(content), multipartETag: nil)
                               : nil,
                           hashedAt: 2)
    }

    private func object(_ key: String, _ content: Character, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: "\"\(md5(content))\"")
    }

    private func objectWithETag(_ key: String, _ etag: String?, size: Int64 = 10) -> InventoryS3Object {
        InventoryS3Object(key: normalizedIndexKey(key), displayKey: key, size: size, etag: etag)
    }

    private func states(ssd: Bool = true, hdd: Bool = true, s3: Bool = true) -> [InventoryArchive: InventoryArchiveState] {
        func st(_ a: InventoryArchive, _ c: Bool) -> InventoryArchiveState {
            InventoryArchiveState(archive: a, runId: 1, complete: c, reason: c ? nil : .interrupted,
                                  unreadable: 0, startedAt: 0, finishedAt: 1)
        }
        return [.ssd: st(.ssd, ssd), .hdd: st(.hdd, hdd), .s3: st(.s3, s3)]
    }

    private func classify(ssd: [InventoryLocalFile] = [], hdd: [InventoryLocalFile] = [], s3: [InventoryS3Object] = [],
                          states: [InventoryArchive: InventoryArchiveState]? = nil) -> [InventoryItem] {
        InventoryClassifier.classify(InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states ?? self.states())).items
    }

    private func item(_ items: [InventoryItem], _ id: String) -> InventoryItem? { items.first { $0.id == id } }

    // MARK: - Le quattro categorie della spec

    func testOnAllThree_isSafe() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].category, .safe)
        XCTAssertEqual(items[0].presentOn, [.ssd, .hdd, .s3])
    }

    /// L'unita' e' il contenuto, non il nome: la stessa foto con nomi diversi nei tre posti e'
    /// comunque al sicuro.
    func testSameContentUnderDifferentNames_isStillSafe() {
        let items = classify(ssd: [file("Foto iPhone/IMG_1.JPG", "a")], hdd: [file("Takeout/copia.jpg", "a")],
                             s3: [object("Other/altro-nome.jpg", "a")])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    func testMissingFromTheHDD_isMissingSomewhere_andSaysWhere() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.hdd])
        XCTAssertTrue(items[0].unknownOn.isEmpty)
    }

    func testOnlyOnTheSSD_isMissingFromBoth() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.hdd, .s3])
    }

    func testOnlyOnTheHDD_isOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].presentOn, [.hdd])
    }

    /// Il materiale che c'e' solo su Cubbit (i ~20 GB in piu' dello zero-delete): riconosciuto
    /// dall'MD5, senza scaricarlo.
    func testOnlyOnCubbit_isOnlyOutsideTheSSD() {
        let items = classify(s3: [object("ASUS/vecchia.jpg", "e")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].id, "md5:\(md5("e"))")
    }

    func testSamePathDifferentContent_isToCheck_forBothContents() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "b")],
                             s3: [object("Foto/a.jpg", "a"), object("x.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
        XCTAssertEqual(item(items, "sha-b")?.category, .toCheck)
        XCTAssertEqual(item(items, "sha-a")?.checkReasons, [.samePathDifferentContent])
    }

    /// Il confronto per percorso usa la chiave normalizzata: maiuscole diverse e Unicode NFD/NFC
    /// sono lo stesso percorso (ExFAT e APFS lo trattano cosi').
    func testSamePath_isComparedOnNormalizedKeys() {
        let nfd = "Foto/Citta\u{0300}.jpg"
        let nfc = "Foto/Citt\u{00E0}.JPG"
        let items = classify(ssd: [file(nfd, "a")], hdd: [file(nfc, "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    func testSamePathSameContent_isNotAConflict() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .safe)
    }

    /// Copie in piu' dello stesso contenuto dentro un solo archivio non sono un conflitto.
    func testTwoCopiesInOneArchive_areNotAConflict() {
        let items = classify(ssd: [file("Foto/a.jpg", "a"), file("Takeout/a.jpg", "a")],
                             hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    /// Un oggetto Cubbit a pezzi che nessun file locale riproduce: non certificabile, quindi da
    /// controllare — e con lui la foto che sta allo stesso percorso sull'SSD, che su Cubbit
    /// potrebbe esserci come no.
    func testNotCertifiableCubbitObject_isToCheck_andSoIsTheLocalFileAtThatPath() {
        let items = classify(ssd: [file("Video/lungo.mov", "a", size: 67_108_865)],
                             hdd: [file("Video/lungo.mov", "a", size: 67_108_865)],
                             s3: [objectWithETag("Video/lungo.mov", "\"96aa53ed4132d7e2986467263954caad-13\"", size: 67_108_865)])
        XCTAssertEqual(item(items, "s3:Video/lungo.mov")?.category, .toCheck)
        XCTAssertEqual(item(items, "s3:Video/lungo.mov")?.checkReasons, [.cubbitNotCertifiable])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck, "mai «manca da Cubbit» ne' «al sicuro» per ipotesi")
    }

    func testCubbitObjectWithAnUnknownETag_isToCheck() {
        let items = classify(s3: [objectWithETag("strano.jpg", "\"boh\"")])
        XCTAssertEqual(items.map(\.category), [.toCheck])
    }

    /// Il caso verificato sui dati veri (FILE0056.MOV): l'ETag a pezzi ricalcolato dal file
    /// locale coincide, quindi l'oggetto e' certificato e la foto e' al sicuro.
    func testMultipartObjectMatchingTheLocalFile_isSafe() {
        let d = ContentDigest(size: 67_108_865, sha256: "sha-big", md5: "9c800b6accf6f26be7e8684d46ffdedb",
                              multipartETag: "96aa53ed4132d7e2986467263954caad-2")
        let local = InventoryLocalFile(key: "asus/elba/file0056.mov", displayPath: "ASUS/Elba/FILE0056.MOV",
                                       size: 67_108_865, mtime: 1, status: .ok, digest: d, hashedAt: 2)
        let items = classify(ssd: [local], hdd: [local],
                             s3: [objectWithETag("ASUS/Elba/FILE0056.MOV", "\"96aa53ed4132d7e2986467263954caad-2\"", size: 67_108_865)])
        XCTAssertEqual(items.map(\.category), [.safe])
    }

    // MARK: - Precedenze (❗ > 🔎 > ⚠️ > ✅)

    func testToCheck_winsOverOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    func testToCheck_winsOverMissingSomewhere() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "b")])
        XCTAssertEqual(item(items, "sha-a")?.category, .toCheck)
    }

    /// Solo sull'HDD e non su Cubbit: vale sia 🔎 sia ⚠️, e vince 🔎.
    func testOnlyOutsideTheSSD_winsOverMissingSomewhere() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")])
        XCTAssertEqual(items[0].category, .onlyOutsideSSD)
        XCTAssertEqual(items[0].missingFrom, [.ssd, .s3])
    }

    // MARK: - Incompleto non e' assente

    func testIncompleteHDD_neverSaysMissingFromTheHDD() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")], states: states(hdd: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertTrue(items[0].missingFrom.isEmpty)
        XCTAssertEqual(items[0].unknownOn, [.hdd])
    }

    func testIncompleteSSD_neverSaysOnlyOutsideTheSSD() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")], states: states(ssd: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertEqual(items[0].unknownOn, [.ssd])
    }

    func testIncompleteCubbit_neverSaysMissingFromCubbit() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], states: states(s3: false))
        XCTAssertEqual(items[0].category, .undetermined)
        XCTAssertEqual(items[0].unknownOn, [.s3])
    }

    /// Un archivio incompleto sospende solo le assenze che dipendono da lui: se la foto manca
    /// anche da un archivio COMPLETO, quella mancanza si dice.
    func testIncompleteSSD_stillAllowsMissingFromACompleteCubbit() {
        let items = classify(hdd: [file("Foto/a.jpg", "a")], states: states(ssd: false))
        XCTAssertEqual(items[0].category, .missingSomewhere)
        XCTAssertEqual(items[0].missingFrom, [.s3])
        XCTAssertEqual(items[0].unknownOn, [.ssd])
    }

    /// Una presenza vista vale anche su un archivio incompleto: «c'e'» e' una conoscenza,
    /// «non c'e'» no.
    func testPresenceOnAnIncompleteArchive_stillCounts() {
        let items = classify(ssd: [file("Foto/a.jpg", "a")], hdd: [file("Foto/a.jpg", "a")], s3: [object("Foto/a.jpg", "a")],
                             states: states(hdd: false, s3: false))
        XCTAssertEqual(items[0].category, .safe)
    }

    /// Un file illeggibile non e' un contenuto (non si sa cosa contiene), ma e' un file.
    func testUnreadableLocalFile_isAFileButNotAContent() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("Foto/rotto.jpg", "a", status: .unreadable)], states: states()))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.stats[.ssd]?.files, 1)
    }

    /// Un file illeggibile non rende «certificato» niente su Cubbit: senza impronte non e' un
    /// candidato.
    func testUnreadableLocalFile_neverCertifiesACubbitObject() {
        let items = classify(ssd: [file("Foto/a.jpg", "a", status: .unreadable)], s3: [object("Foto/a.jpg", "a")])
        XCTAssertEqual(items.map(\.id), ["md5:\(md5("a"))"])
    }

    // MARK: - Numeri per archivio

    func testExtraCopies_andRecoverableSpace_perArchive() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("A/a.jpg", "a", size: 100), file("B/a.jpg", "a", size: 100), file("C/a.jpg", "a", size: 100),
                  file("A/b.jpg", "b", size: 7)],
            hdd: [file("A/a.jpg", "a", size: 100)],
            s3: [object("A/a.jpg", "a", size: 100), object("B/a.jpg", "a", size: 100)],
            states: states()))
        XCTAssertEqual(result.stats[.ssd], InventoryArchiveStats(files: 4, extraCopies: 2, reclaimableBytes: 200))
        XCTAssertEqual(result.stats[.hdd], InventoryArchiveStats(files: 1, extraCopies: 0, reclaimableBytes: 0))
        XCTAssertEqual(result.stats[.s3], InventoryArchiveStats(files: 2, extraCopies: 1, reclaimableBytes: 100))
    }

    /// Tutti i file vuoti hanno la stessa impronta: non sono copie l'uno dell'altro (stessa
    /// regola di `LibraryIndexStore.duplicateGroups`).
    func testEmptyFiles_areNeverExtraCopies() {
        let result = InventoryClassifier.classify(InventorySnapshot(
            ssd: [file("a.jpg", "a", size: 0), file("b.jpg", "a", size: 0)], states: states()))
        XCTAssertEqual(result.stats[.ssd]?.extraCopies, 0)
    }

    /// Oggetti non certificabili non si contano come copie: sotto-stimare lo spazio
    /// recuperabile e' innocuo, sovra-stimarlo no.
    func testNotCertifiableObjects_areNeverExtraCopies() {
        let etag = "\"96aa53ed4132d7e2986467263954caad-13\""
        let result = InventoryClassifier.classify(InventorySnapshot(
            s3: [objectWithETag("a.mov", etag, size: 67_108_865), objectWithETag("b.mov", etag, size: 67_108_865)],
            states: states()))
        XCTAssertEqual(result.stats[.s3]?.files, 2)
        XCTAssertEqual(result.stats[.s3]?.extraCopies, 0)
    }

    // MARK: - Proprieta' generali

    func testEveryContentFallsInExactlyOneCategory_andNothingIsLost() {
        let items = classify(ssd: [file("1.jpg", "a"), file("2.jpg", "b"), file("x.jpg", "c")],
                             hdd: [file("1.jpg", "a"), file("3.jpg", "d"), file("x.jpg", "e")],
                             s3: [object("1.jpg", "a"), object("4.jpg", "f"), objectWithETag("5.jpg", "\"boh\"")])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "nessun contenuto due volte")
        XCTAssertEqual(Set(items.map(\.id)),
                       ["sha-a", "sha-b", "sha-c", "sha-d", "sha-e", "md5:\(md5("f"))", "s3:5.jpg"])
    }

    func testResult_doesNotDependOnTheInputOrder() {
        let ssd = [file("1.jpg", "a"), file("2.jpg", "b"), file("3.jpg", "c")]
        let hdd = [file("1.jpg", "a"), file("2.jpg", "d")]
        let s3 = [object("1.jpg", "a"), object("9.jpg", "e")]
        let one = InventoryClassifier.classify(InventorySnapshot(ssd: ssd, hdd: hdd, s3: s3, states: states()))
        let two = InventoryClassifier.classify(InventorySnapshot(ssd: ssd.reversed(), hdd: hdd.reversed(),
                                                                 s3: s3.reversed(), states: states()))
        XCTAssertEqual(one.items, two.items)
        XCTAssertEqual(one.stats, two.stats)
    }

    /// Il percorso di esempio e' quello dell'SSD quando c'e': e' il posto che Enrico conosce.
    func testExamplePath_prefersTheSSD() {
        let items = classify(ssd: [file("Foto iPhone/a.jpg", "a")], hdd: [file("AAA/a.jpg", "a")], s3: [object("0/a.jpg", "a")])
        XCTAssertEqual(items[0].exampleArchive, .ssd)
        XCTAssertEqual(items[0].examplePath, "Foto iPhone/a.jpg")
    }

    func testSummary_limitsTheSamples_butNotTheCounts() {
        let many = (0..<5).map { file("f\($0).jpg", Character(UnicodeScalar(UInt8(97 + $0)))) }
        let summary = InventorySummary(InventorySnapshot(ssd: many, states: states()), sampleLimit: 2)
        XCTAssertEqual(summary.count(.missingSomewhere), 5)
        XCTAssertEqual(summary.samples[.missingSomewhere]?.count, 2)
        XCTAssertEqual(summary.bytes(.missingSomewhere), 50)
        XCTAssertEqual(summary.count(.safe), 0)
    }

    /// Decisione del 2026-09-29: ❗ «stesso percorso, contenuto diverso» vale fra DUE archivi
    /// (spec, ADR-0015), non dentro un archivio solo. SSD e HDD non distinguono maiuscole e
    /// minuscole, e su Cubbit il 2026-09-29 non c'era nessuna coppia di chiavi che collide dopo
    /// la normalizzazione (219.877 chiavi controllate). Il progetto 4 deve ricontrollarlo
    /// prima di cancellare qualunque cosa da Cubbit.
    func testPathCollisionInsideASingleArchive_isNotAConflict() {
        let items = classify(hdd: [file("Foto/IMG.JPG", "x"), file("Foto/img.jpg", "y")])
        XCTAssertEqual(item(items, "sha-x")?.checkReasons, [])
        XCTAssertEqual(item(items, "sha-y")?.checkReasons, [])
        XCTAssertEqual(item(items, "sha-x")?.category, .onlyOutsideSSD)
        XCTAssertEqual(item(items, "sha-y")?.category, .onlyOutsideSSD)
    }
}
