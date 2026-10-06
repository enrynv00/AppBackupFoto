import XCTest
@testable import AppBackupFoto

/// `PhotosLibraryPresence` (ADR-0018): quali copie in «Foto iPhone» hanno ancora il loro originale
/// nella libreria Foto del Mac. Su cartelle temporanee reali, come il resto del progetto: la
/// cartella `originals` finta ha lo stesso schema di quella vera (`<X>/<file>`).
///
/// Il verso sicuro e' il cuore di questo tipo: ogni volta che la lettura non e' completa e certa,
/// il risultato e' `.unknown`, che tiene TUTTE le copie in «Foto iPhone» — mai un elenco parziale,
/// che renderebbe spostabile una copia che il backup ricopierebbe.
final class PhotosLibraryPresenceTests: XCTestCase {

    private var root: URL!
    private var originals: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photospresence-\(UUID().uuidString)")
        originals = root.appendingPathComponent("Photos Library.photoslibrary/originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Una sottocartella resa illeggibile da un test va riaperta prima di cancellare.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e {
                _ = chmod(root.appendingPathComponent(rel).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeOriginal(_ relative: String) throws {
        let url = originals.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// Una copia sull'SSD come la scrive l'elenco: chiave normalizzata e percorso com'e' su disco.
    private func ssdCopy(_ displayPath: String) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(displayPath), displayPath: displayPath,
                          size: 1, mtime: 0, hash: "h", hashedAt: 0)
    }

    // MARK: - Lettura

    func testRead_everyFileOfOriginals_holdsItsCopyInFotoIPhone() throws {
        try makeOriginal("1/1103F08E-E098-47BE-A402-3708A737BA1C.mp4")
        try makeOriginal("F/F4E891D9-8927-46D3-8174-BE672BC35B25.mov")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)

        XCTAssertTrue(presence.isKnown)
        XCTAssertEqual(presence.mainLibraryKeys?.count, 2)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/1/1103F08E-E098-47BE-A402-3708A737BA1C.mp4")))
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/F/F4E891D9-8927-46D3-8174-BE672BC35B25.mov")))
    }

    func testCopyWhoseOriginalIsGone_isNotHeld() throws {
        try makeOriginal("1/ancora.jpg")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone/1/tolta-da-foto.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone/2/ancora.jpg")), "stessa foto, altra sottocartella: non e' lei")
    }

    /// Stessa regola delle chiavi dell'elenco: maiuscole e forma Unicode non contano (exFAT non
    /// distingue le maiuscole e non normalizza).
    func testHolds_ignoresCaseAndUnicodeForm_likeTheList() throws {
        try makeOriginal("1/Caff\u{00E8}.JPG")                      // NFC
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertTrue(presence.holds(ssdCopy("FOTO IPHONE/1/caffe\u{0300}.jpg")))  // NFD, minuscole
    }

    /// Solo «Foto iPhone» e' scritta dal backup: le copie altrove non dipendono mai dalla
    /// libreria Foto, anche con lo stesso percorso relativo. Confronto per componente.
    func testCopiesOutsideFotoIPhone_areNeverHeld() throws {
        try makeOriginal("1/a.jpg")
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertFalse(presence.holds(ssdCopy("Takeout/1/a.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("Foto iPhone 2/1/a.jpg")))
        XCTAssertFalse(presence.holds(ssdCopy("1/a.jpg")))
        XCTAssertFalse(PhotosLibraryPresence.unknown.holds(ssdCopy("Takeout/1/a.jpg")),
                       "anche senza libreria leggibile, fuori da «Foto iPhone» non resta niente in piu'")
    }

    func testKey_isTheListKeyOfTheBackupCopy() {
        XCTAssertEqual(PhotosLibraryPresence.key(forOriginalsRelativePath: "1/IMG_0001.HEIC"),
                       normalizedIndexKey("Foto iPhone/1/IMG_0001.HEIC"))
    }

    /// Un file direttamente in `originals` (non in una sottocartella) si mappa lo stesso.
    func testFileDirectlyInOriginals_isMapped() throws {
        try makeOriginal("sciolto.jpg")
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: originals).holds(ssdCopy("Foto iPhone/sciolto.jpg")))
    }

    /// I nascosti contano (un file in piu' tiene una copia in piu', mai il contrario).
    func testHiddenFiles_areCounted() throws {
        try makeOriginal("1/.nascosto.jpg")
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: originals).holds(ssdCopy("Foto iPhone/1/.nascosto.jpg")))
    }

    /// La root raggiunta da un link simbolico: l'enumeratore restituisce la forma `realpath`.
    func testRootThroughASymlink_stillMaps() throws {
        try makeOriginal("3/a.jpg")
        let link = root.appendingPathComponent("collegamento")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originals)
        XCTAssertTrue(PhotosLibraryPresence.read(originalsRoot: link).holds(ssdCopy("Foto iPhone/3/a.jpg")))
    }

    // MARK: - Il verso sicuro: non si sa ⇒ tutte le copie in «Foto iPhone» restano

    func testNoBookmark_isUnknown_andEveryFotoIPhoneCopyIsHeld() {
        let presence = PhotosLibraryPresence.read(originalsRoot: nil)
        XCTAssertFalse(presence.isKnown)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/1/qualunque.jpg")))
    }

    func testMissingRoot_isUnknown() {
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: root.appendingPathComponent("non-esiste")), .unknown)
    }

    func testRootIsAFile_isUnknown() throws {
        let file = root.appendingPathComponent("file.jpg")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: file), .unknown)
    }

    /// Una libreria vuota e una libreria che non si lascia leggere si confondono: nel dubbio,
    /// `.unknown` (che tiene tutto), mai «nessuna copia nella libreria» (che sposterebbe tutto).
    func testEmptyOriginals_isUnknown() throws {
        try FileManager.default.createDirectory(at: originals.appendingPathComponent("0"), withIntermediateDirectories: true)
        XCTAssertEqual(PhotosLibraryPresence.read(originalsRoot: originals), .unknown)
    }

    /// Una sottocartella che non si lascia aprire: la lettura e' incompleta, quindi `.unknown` —
    /// anche se gli altri file si sono letti. Un elenco parziale renderebbe spostabili proprio le
    /// copie della cartella illeggibile.
    func testUnreadableSubfolder_isUnknown_notAPartialList() throws {
        try makeOriginal("1/a.jpg")
        try makeOriginal("2/b.jpg")
        let locked = originals.appendingPathComponent("2")
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        defer { _ = chmod(locked.path, 0o755) }
        let presence = PhotosLibraryPresence.read(originalsRoot: originals)
        XCTAssertEqual(presence, .unknown)
        XCTAssertTrue(presence.holds(ssdCopy("Foto iPhone/2/b.jpg")))
    }
}
