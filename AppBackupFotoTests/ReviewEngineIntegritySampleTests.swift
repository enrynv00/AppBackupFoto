import XCTest
@testable import AppBackupFoto

final class ReviewEngineIntegritySampleTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default
    private var defaults: UserDefaults!
    private let suiteName = "ReviewEngineIntegritySampleTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fm.temporaryDirectory
            .appendingPathComponent("ReviewEngineTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        root = nil; srcDir = nil; dstDir = nil
        try super.tearDownWithError()
    }

    func testIdenticalFiles_areMatched() throws {
        let data = Data("hello world".utf8)
        try data.write(to: srcDir.appendingPathComponent("a.jpg"))
        try data.write(to: dstDir.appendingPathComponent("a.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
        XCTAssertNil(result.error)
    }

    func testAlteredDestinationFile_isReportedAsMismatch() throws {
        try Data("original".utf8).write(to: srcDir.appendingPathComponent("b.jpg"))
        try Data("corrupted".utf8).write(to: dstDir.appendingPathComponent("b.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.mismatches, ["b.jpg"])
    }

    func testDestinationFileMissingFromSource_isSkippedNotMismatch() throws {
        try Data("only-on-dest".utf8).write(to: dstDir.appendingPathComponent("c.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.skippedNoSource, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
    }

    func testEmptyDestination_returnsZeroedResultWithoutError() throws {
        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.matched, 0)
        XCTAssertNil(result.error)
    }

    func testNestedSubdirectory_relativePathIsPreserved() throws {
        try fm.createDirectory(at: srcDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        let data = Data("nested".utf8)
        try data.write(to: srcDir.appendingPathComponent("2024/d.jpg"))
        try data.write(to: dstDir.appendingPathComponent("2024/d.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
    }

    // MARK: - Precedenza ai file copiati ma non verificati

    private func writePair(_ rel: String, src: String, dst: String) throws {
        for (dir, content) in [(srcDir!, src), (dstDir!, dst)] {
            let url = dir.appendingPathComponent(rel)
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try Data(content.utf8).write(to: url)
        }
    }

    /// Riempie la destinazione di rumore, cosi' un campione casuale ha una probabilita'
    /// trascurabile di pescare proprio il file in debito.
    private func writeFiller(_ n: Int) throws {
        for i in 0..<n { try writePair("filler-\(i).jpg", src: "riempitivo \(i)", dst: "riempitivo \(i)") }
    }

    // Il cuore dell'intervento: un file copiato-ma-non-verificato non verra' MAI ricopiato
    // (zero-overwrite), quindi il campione d'integrita' e' l'unica occasione che ha di essere
    // ricontrollato. Con un campione da 1 su 201 file, pescarlo per caso ha probabilita' 0,5%:
    // se il test e' verde e' perche' la precedenza funziona, non per fortuna.
    func testUnverifiedFile_isCheckedFirstEvenWithATinySample() throws {
        try writeFiller(200)
        try writePair("debito.jpg", src: "originale", dst: "DIVERSO")   // mismatch: visibile nel risultato
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("debito.jpg"), defaults: defaults)

        let result = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 1)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.mismatches, ["debito.jpg"],
                       "il campione deve pescare prima dalla lista dei non verificati")
    }

    // Il debito si chiude: verificato e corrispondente, esce dalla lista. Senza questo il
    // campione continuerebbe a ricontrollare per sempre lo stesso file gia' assolto.
    func testVerifiedUnverifiedFile_isRemovedFromTheDebt() throws {
        try writePair("debito.jpg", src: "identico", dst: "identico")
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("debito.jpg"), defaults: defaults)

        let result = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.matched, 1)
        let debt = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertTrue(debt.paths.isEmpty, "il debito verificato va chiuso")
        XCTAssertEqual(debt.totalCount, 0)
    }

    // Su mismatch invece il debito RESTA: e' appena diventato un problema vero, e toglierlo
    // dalla lista significherebbe smettere di guardarlo proprio quando conta.
    func testMismatchedUnverifiedFile_staysInTheDebt() throws {
        try writePair("debito.jpg", src: "originale", dst: "corrotto")
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("debito.jpg"), defaults: defaults)

        _ = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 20)

        XCTAssertEqual(UnverifiedCopiesStore.load(defaults: defaults).paths,
                       [dstDir.appendingPathComponent("debito.jpg").path])
    }

    // Un file importato da un dispositivo poi scollegato non ha piu' una sorgente con cui
    // confrontarsi: non e' verificabile in questa coppia. Dargli la precedenza brucerebbe uno
    // slot del campione a ogni esecuzione, per sempre, senza mai chiudersi.
    func testUnverifiedFileWithoutASource_doesNotConsumeThePrioritySlot() throws {
        // Due debiti e un solo slot, cosi' l'esito e' deterministico e non dipende dal
        // sorteggio: l'orfano e' registrato per PRIMO, quindi senza la guardia sarebbe lui a
        // prendersi lo slot e il file verificabile non verrebbe mai controllato.
        try Data("solo a destinazione".utf8).write(to: dstDir.appendingPathComponent("orfano.jpg"))
        try writePair("verificabile.jpg", src: "identico", dst: "identico")
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("orfano.jpg"), defaults: defaults)
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("verificabile.jpg"), defaults: defaults)

        let result = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 1)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.skippedNoSource, 0,
                       "lo slot non deve essere sprecato su un file senza sorgente")
        XCTAssertEqual(UnverifiedCopiesStore.load(defaults: defaults).paths,
                       [dstDir.appendingPathComponent("orfano.jpg").path],
                       "chiuso il debito verificabile, resta solo quello che non lo e'")
    }

    // Il debito raccolto da una coppia (Mac->SSD) non deve influenzare le altre: i percorsi
    // fuori dalla root di destinazione si ignorano, e si confronta per componenti, mai con
    // `hasPrefix` (`/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`, ma lo e' come
    // stringa).
    func testDebtPathOutsideTheDestinationRoot_isIgnored() throws {
        try writePair("a.jpg", src: "identico", dst: "identico")
        // STESSO nome di file, cartella diversa e fuori dalla root di destinazione: e' il
        // caso che distingue un confronto per percorso da un confronto per nome. Un debito
        // contratto su Mac->SSD non deve chiudersi perche' la coppia SSD->HDD ha per caso un
        // file con lo stesso nome.
        let elsewhere = root.appendingPathComponent("altrove/a.jpg")
        UnverifiedCopiesStore.record(elsewhere, defaults: defaults)

        let result = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(UnverifiedCopiesStore.load(defaults: defaults).paths, [elsewhere.path],
                       "un debito di un'altra coppia non va ne' controllato ne' chiuso qui")
    }

    // Il resto del campione resta casuale: la precedenza non deve MAI ridurre il numero di
    // file controllati.
    func testPriorityDoesNotShrinkTheSample() throws {
        try writeFiller(10)
        try writePair("debito.jpg", src: "identico", dst: "identico")
        UnverifiedCopiesStore.record(dstDir.appendingPathComponent("debito.jpg"), defaults: defaults)

        let result = ReviewEngine(defaults: defaults).sampleLocalPair(
            srcRoot: srcDir, dstRoot: dstDir, pairName: "Test", sampleSize: 5)

        XCTAssertEqual(result.checked, 5)
        XCTAssertEqual(result.matched, 5)
    }
}
