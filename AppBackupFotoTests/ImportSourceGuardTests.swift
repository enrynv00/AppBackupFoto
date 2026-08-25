import XCTest
@testable import AppBackupFoto

final class ImportSourceGuardTests: XCTestCase {
    private let configured = [
        URL(fileURLWithPath: "/Users/enrico/Pictures/Photos Library.photoslibrary"),
        URL(fileURLWithPath: "/Volumes/SSD - Enri"),
        URL(fileURLWithPath: "/Volumes/BackupHDD"),
    ]

    func testExactMatch_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri"), configuredURLs: configured))
    }

    func testSubfolderOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone"), configuredURLs: configured))
    }

    func testParentOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes"), configuredURLs: configured))
    }

    func testUnrelatedPath_isNotInside() {
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), configuredURLs: configured))
    }

    func testSimilarPrefixDifferentVolume_isNotInside() {
        // "/Volumes/SSD - Enri 2" NON è dentro "/Volumes/SSD - Enri" anche se il path
        // condivide lo stesso prefisso testuale senza separatore "/" di mezzo.
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri 2"), configuredURLs: configured))
    }

    func testSlug_normalLabel_unchanged() {
        XCTAssertEqual(importFolderSlug("EOS_DIGITAL - 2026-08-25"), "EOS_DIGITAL - 2026-08-25")
    }

    func testSlug_replacesSlash() {
        XCTAssertEqual(importFolderSlug("Foto/Vacanze"), "Foto-Vacanze")
    }

    func testSlug_replacesColon() {
        XCTAssertEqual(importFolderSlug("Nikon: vecchie foto"), "Nikon- vecchie foto")
    }

    func testSlug_emptyAfterTrim_fallsBackToImport() {
        XCTAssertEqual(importFolderSlug("   "), "Import")
    }

    // MARK: - Guardia: casi aggiunti dopo la review del Task 1

    func testEmptyConfiguredList_isNotInside() {
        // Nessuna location configurata: nulla può essere "dentro".
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), configuredURLs: []))
    }

    func testSymlinkToConfiguredLocation_isInside() throws {
        // Symlink reale su disco: senza risoluzione su entrambi i lati il confronto
        // testuale non lo intercetta, e a valle FileSyncer ricorrerebbe dentro la
        // destinazione appena creata (ricorsione runaway fino a PATH_MAX).
        let real = try makeTempDirectory(named: "real")
        let link = tempRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(isSourceInsideConfiguredLocations(link, configuredURLs: [real]))
    }

    func testSymlinkedSubfolderOfConfiguredLocation_isInside() throws {
        let real = try makeTempDirectory(named: "real")
        let sub = real.appendingPathComponent("Foto")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(isSourceInsideConfiguredLocations(
            link.appendingPathComponent("Foto"), configuredURLs: [real]))
    }

    func testSymlinkToUnrelatedFolder_isNotInside() throws {
        let real = try makeTempDirectory(named: "real")
        let other = try makeTempDirectory(named: "altro")
        let link = tempRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

        XCTAssertFalse(isSourceInsideConfiguredLocations(link, configuredURLs: [real]))
    }

    // MARK: - Slug: casi aggiunti dopo la review del Task 1

    func testSlug_dotDot_fallsBackToImport() {
        // "<SSD>/Import/.." risolve nella root dell'SSD: la cartella dedicata non
        // esisterebbe affatto e i file atterrerebbero fuori da "Import".
        XCTAssertEqual(importFolderSlug(".."), "Import")
    }

    func testSlug_singleDot_fallsBackToImport() {
        // "<SSD>/Import/." è "<SSD>/Import": nessun isolamento per-import.
        XCTAssertEqual(importFolderSlug("."), "Import")
    }

    func testSlug_onlyDots_fallsBackToImport() {
        XCTAssertEqual(importFolderSlug("..."), "Import")
        XCTAssertEqual(importFolderSlug("  ..  "), "Import")
    }

    func testSlug_dotsWithRealText_isKept() {
        // Un punto dentro un'etichetta normale non è un caso pericoloso.
        XCTAssertEqual(importFolderSlug("Canon 5D .backup"), "Canon 5D .backup")
    }

    // MARK: - Punto iniziale: cartella nascosta, invisibile a TUTTA l'app

    func testSlug_leadingDot_isRemoved() {
        // "<SSD>/Import/.EOS_DIGITAL" è una cartella NASCOSTA. Non è un problema
        // estetico: `.skipsHiddenFiles` compare in 8 punti di ContentView.swift,
        // fra cui `previewDir` e `syncDir` (la copia SSD→HDD) e
        // `listAvailableFolders`. Le foto importate lì resterebbero sull'SSD ma
        // non verrebbero MAI copiate su HDD né elencate nella UI, senza un solo
        // errore — e non entrerebbero nell'indice di contenuto (roadmap #31),
        // quindi nemmeno nel dedup.
        XCTAssertEqual(importFolderSlug(".EOS_DIGITAL"), "EOS_DIGITAL")
    }

    func testSlug_leadingDotAfterTrim_isRemoved() {
        // Il punto può emergere solo dopo il trim degli spazi.
        XCTAssertEqual(importFolderSlug("  .EOS_DIGITAL  "), "EOS_DIGITAL")
    }

    func testSlug_multipleLeadingDots_areRemoved() {
        XCTAssertEqual(importFolderSlug("..Foto vacanze"), "Foto vacanze")
    }

    func testSlug_leadingDotThenSpace_isTrimmedAgain() {
        // Tolto il punto resta uno spazio in testa: va ritrimmato, altrimenti
        // il nome della cartella inizierebbe con uno spazio.
        XCTAssertEqual(importFolderSlug(". Foto"), "Foto")
    }

    func testSlug_leadingDotOnly_fallsBackToImport() {
        // Tolti i punti non resta nulla: deve valere il fallback già esistente.
        XCTAssertEqual(importFolderSlug(".."), "Import")
        XCTAssertEqual(importFolderSlug("."), "Import")
    }

    func testSlug_neverProducesHiddenFolderName() {
        // Proprietà generale: nessun input può produrre un nome nascosto.
        for label in [".x", "..x", "...", ".", "..", "  .y  ", ". ", ".\u{0}z"] {
            XCTAssertFalse(importFolderSlug(label).hasPrefix("."),
                           "slug nascosto prodotto da \(label.debugDescription)")
        }
    }

    func testSlug_removesControlCharactersInsideLabel() {
        // Il trim tocca solo i bordi: un \n a metà stringa resterebbe nel nome.
        XCTAssertEqual(importFolderSlug("Foto\nVacanze"), "FotoVacanze")
        XCTAssertEqual(importFolderSlug("Foto\rVacanze"), "FotoVacanze")
        XCTAssertEqual(importFolderSlug("Foto\u{0}Vacanze"), "FotoVacanze")
        XCTAssertEqual(importFolderSlug("Foto\tVacanze"), "FotoVacanze")
    }

    func testSlug_onlyControlCharacters_fallsBackToImport() {
        XCTAssertEqual(importFolderSlug("\n\r\u{0}"), "Import")
    }

    func testSlug_truncatesToByteLimit() {
        // 300 caratteri accentati = 600 byte UTF-8: ben oltre il limite del filesystem
        // (255 byte), che è in byte e non in caratteri.
        let slug = importFolderSlug(String(repeating: "à", count: 300))
        XCTAssertLessThanOrEqual(slug.utf8.count, importFolderSlugMaxBytes)
        XCTAssertEqual(slug, String(repeating: "à", count: importFolderSlugMaxBytes / 2))
    }

    func testSlug_truncationNeverSplitsMultibyteCharacter() {
        // 99 × "é" (198 byte) + "😀" (4 byte) = 202 byte: il taglio cade in mezzo
        // all'emoji. Deve scartarla intera, non produrre byte orfani.
        let label = String(repeating: "é", count: 99) + "😀"
        XCTAssertEqual(label.utf8.count, 202)
        let slug = importFolderSlug(label)
        XCTAssertEqual(slug.utf8.count, 198)
        XCTAssertEqual(slug, String(repeating: "é", count: 99))
        XCTAssertFalse(slug.unicodeScalars.contains("\u{FFFD}"))
        // Round-trip: se il troncamento avesse spezzato una sequenza UTF-8, ridecodificare
        // i byte produrrebbe un carattere di sostituzione e la stringa cambierebbe.
        XCTAssertEqual(String(decoding: Array(slug.utf8), as: UTF8.self), slug)
    }

    func testSlug_accentedLabelExactlyAtByteLimit_isUnchanged() {
        // 100 × "à" = esattamente 200 byte: sotto il limite, nessun troncamento.
        let label = String(repeating: "à", count: importFolderSlugMaxBytes / 2)
        XCTAssertEqual(label.utf8.count, importFolderSlugMaxBytes)
        XCTAssertEqual(importFolderSlug(label), label)
    }

    func testSlug_longLabelIsAcceptedByCreateDirectory() throws {
        // Il punto del limite in byte: il nome prodotto deve essere davvero creabile.
        let slug = importFolderSlug(String(repeating: "à", count: 300))
        let dir = tempRoot.appendingPathComponent(slug)
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Temp dir (solo directory temporanee: mai SSD/HDD o dati reali)

    private var tempRoot: URL {
        if let existing = createdTempRoot { return existing }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportSourceGuardTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdTempRoot = url
        return url
    }
    private var createdTempRoot: URL?

    private func makeTempDirectory(named name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    override func tearDownWithError() throws {
        if let root = createdTempRoot {
            try? FileManager.default.removeItem(at: root)
            createdTempRoot = nil
        }
        try super.tearDownWithError()
    }
}
