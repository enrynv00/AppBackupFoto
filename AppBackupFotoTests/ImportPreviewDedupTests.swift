//
//  ImportPreviewDedupTests.swift
//  AppBackupFotoTests
//
//  Il motore dell'anteprima vera del wizard di import (roadmap #27-A / #31, terza
//  parte, Task 2). Copre due cose distinte:
//
//   - `isAlreadyInLibrary(..., onSourceHash:)`: il quarto parametro non deve cambiare
//     la decisione di dedup (test di regressione), e deve notificare l'hash SOLO
//     quando lo Stadio 2 e' davvero raggiunto — mai per un file scartato allo Stadio 1,
//     mai per un `.notIndexable`.
//   - `BackupRunner.importPreviewDuplicates`: riusa la STESSA `isAlreadyInLibrary`
//     dell'import (nessuna seconda copia della decisione), si colloca al LIVELLO DI
//     FIDUCIA 2 (ADR-0003) — un'entry fantasma dell'indice non fa dichiarare un
//     doppione — e riconosce anche i doppioni INTERNI alla stessa sorgente, che
//     l'indice persistito non puo' ancora conoscere.
//
//  Niente mock: directory temporanee reali e un `LibraryIndexStore` reale, come gia'
//  fa `ImportDedupTests`.
//

import XCTest
@testable import AppBackupFoto

final class ImportPreviewDedupTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var libraryDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportPreviewDedupTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        libraryDir = root.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil; srcDir = nil; libraryDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ url: URL, _ contents: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize))
    }

    private func candidate(_ url: URL) throws -> FileSyncer.PreviewCandidate {
        FileSyncer.PreviewCandidate(url: url, size: try fileSize(url))
    }

    /// Registra `existing` nello store come se fosse gia' presente in libreria a
    /// `displayPath` (relativo a `libraryDir`).
    private func seedStore(_ store: LibraryIndexStore, displayPath: String, contentsOf url: URL) throws {
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey(displayPath),
                                            displayPath: displayPath,
                                            size: try fileSize(url),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: url)),
                                            hashedAt: 1_700_003_600)])
    }

    // MARK: - `isAlreadyInLibrary(onSourceHash:)`

    func testOnSourceHash_isCalledWithRealHash_whenStage2IsReached() throws {
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "contenuto vero")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto vero")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: existing)

        var reportedHash: String?
        let isDup = BackupRunner.isAlreadyInLibrary(url: incoming, store: store,
                                                    session: ImportSessionIndex(), libraryRoot: library,
                                                    onSourceHash: { reportedHash = $0 })

        XCTAssertTrue(isDup)
        XCTAssertEqual(reportedHash, try XCTUnwrap(sha256(of: incoming)))
    }

    func testOnSourceHash_notCalled_whenStage1RejectsBySize() throws {
        // Nessuna entry nello store, nessuna nella sessione, e nessun altro candidato
        // di questa dimensione: lo Stadio 1 scarta il file prima di leggerlo. E' la
        // prova che il prefiltro fa davvero risparmiare la lettura.
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto unico e mai visto")

        var called = false
        let isDup = BackupRunner.isAlreadyInLibrary(url: incoming, store: nil,
                                                    session: ImportSessionIndex(), libraryRoot: nil,
                                                    onSourceHash: { _ in called = true })

        XCTAssertFalse(isDup)
        XCTAssertFalse(called, "lo Stadio 1 non deve leggere il file")
    }

    func testOnSourceHash_notCalled_forNotIndexable() throws {
        // La guardia `IndexableKind` scatta PRIMA di qualunque lettura di dimensione o
        // di hash: un file non indicizzabile non viene mai letto per il dedup.
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.aae"), "")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.aae"), "")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.aae", contentsOf: existing)

        var called = false
        let isDup = BackupRunner.isAlreadyInLibrary(url: incoming, store: store,
                                                    session: ImportSessionIndex(), libraryRoot: library,
                                                    onSourceHash: { _ in called = true })

        XCTAssertFalse(isDup)
        XCTAssertFalse(called)
    }

    func testIsAlreadyInLibrary_withoutOnSourceHash_behavesIdenticalToBefore() throws {
        // Regressione: `runImport` non passa `onSourceHash` e non deve cambiare
        // comportamento.
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "contenuto vero")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto vero")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: existing)

        let isDup = BackupRunner.isAlreadyInLibrary(url: incoming, store: store,
                                                    session: ImportSessionIndex(), libraryRoot: library)
        XCTAssertTrue(isDup)
    }

    // MARK: - `importPreviewDuplicates` — decisione (indice persistito)

    func testFileAlreadyInLibrary_entryAndRealFile_isDetected() throws {
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "una foto vera")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "una foto vera")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: existing)

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(result, [0])
    }

    func testNewFile_isAbsentFromResult() throws {
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto mai visto prima")

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    func testSameSizeDifferentContentAcrossLibrary_bothAbsent() throws {
        // IL TEST CHE VALE PIU' DI TUTTI (misura: 37-53% delle collisioni di dimensione
        // fra insiemi diversi non e' un doppione). Se un giorno il confronto degradasse
        // alla sola dimensione, qui si perderebbe una foto.
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "AAAAAAAA")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "BBBBBBBB")
        XCTAssertEqual(try fileSize(existing), try fileSize(incoming))

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: existing)

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    func testGhostEntry_hashKnownButFileGone_isAbsentFromResult() throws {
        // ADR-0003 nota 2026-08-27 + spec: l'indice contiene per decisione di prodotto
        // entry il cui file non e' piu' sul disco ("traversata incompleta => nessuna
        // rimozione"). Il livello di fiducia 2 rilegge, la scopre sparita, e NON
        // dichiara doppione: e' il test che fissa la scelta del livello 2 invece del
        // livello 1 (che, fidandosi dell'indice, avrebbe sbagliato in difetto).
        let library = libraryDir!
        let vanished = library.appendingPathComponent("Foto/sparita.jpg")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto della foto sparita")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        // La entry esiste nell'indice, ma il file NON viene mai scritto su disco.
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("Foto/sparita.jpg"),
                                            displayPath: "Foto/sparita.jpg",
                                            size: try fileSize(incoming),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: incoming)),
                                            hashedAt: 1_700_003_600)])
        XCTAssertFalse(fm.fileExists(atPath: vanished.path))

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty, "il file verra' copiato, e l'anteprima deve dirlo")
    }

    func testNotIndexableByteIdenticalToAnotherInLibrary_isAbsent() throws {
        // Due sidecar .AAE da 0 byte hanno lo stesso SHA256 (della stringa vuota):
        // senza la guardia `IndexableKind` diventerebbero l'uno il doppione dell'altro.
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.aae"), "")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.aae"), "")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.aae", contentsOf: existing)

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    func testCandidateOutsideLibraryRoot_isIgnored_countsAsNew() throws {
        // Un'entry dell'indice il cui `displayPath` risolve FUORI dalla root della
        // libreria (indice corrotto o manomesso) non deve mai autorizzare uno skip.
        let library = libraryDir!
        let outside = root.appendingPathComponent("fuori/altrove.jpg")
        try writeFile(outside, "contenuto")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "contenuto")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("../fuori/altrove.jpg"),
                                            displayPath: "../fuori/altrove.jpg",
                                            size: try fileSize(outside),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: outside)),
                                            hashedAt: 1_700_003_600)])

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(incoming)], store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    func testStoreNil_onlyInternalDuplicatesAreDetected() throws {
        let a = try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "contenuto identico")
        let b = try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "contenuto identico")

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(result.count, 1)
    }

    func testUnreadableSourceFile_isNeverDeclaredDuplicate() throws {
        let library = libraryDir!
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "contenuto")
        // Un file che punta a un percorso inesistente: `sha256` non puo' leggerlo.
        let unreadable = srcDir.appendingPathComponent("fantasma.jpg")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: existing)

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [FileSyncer.PreviewCandidate(url: unreadable, size: try fileSize(existing))],
            store: store, libraryRoot: library, isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Doppioni interni alla stessa sorgente

    func testTwoByteIdenticalFilesInSameSource_exactlyOneInResult() throws {
        let a = try writeFile(srcDir.appendingPathComponent("uno.jpg"), "contenuto identico")
        let b = try writeFile(srcDir.appendingPathComponent("due.jpg"), "contenuto identico")

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(result.count, 1, "esattamente uno dei due, mai zero ne' due")
    }

    func testThreeByteIdenticalFiles_twoInResult() throws {
        let a = try writeFile(srcDir.appendingPathComponent("uno.jpg"), "contenuto identico")
        let b = try writeFile(srcDir.appendingPathComponent("due.jpg"), "contenuto identico")
        let c = try writeFile(srcDir.appendingPathComponent("tre.jpg"), "contenuto identico")

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b), try candidate(c)],
            store: nil, libraryRoot: nil, isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(result.count, 2)
    }

    func testTwoByteIdenticalFilesInDifferentSubfolders_oneInResult() throws {
        let a = try writeFile(srcDir.appendingPathComponent("SottoA/uno.jpg"), "contenuto identico")
        let b = try writeFile(srcDir.appendingPathComponent("SottoB/Profondo/due.jpg"), "contenuto identico")

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(result.count, 1)
    }

    func testTwoSameSizeDifferentContentInSameSource_neitherInResult() throws {
        // Simmetrico al test "IL TEST CHE VALE PIU' DI TUTTI", ma per la collisione
        // INTERNA alla sorgente: la dimensione condivisa da sola non basta nemmeno qui.
        let a = try writeFile(srcDir.appendingPathComponent("uno.jpg"), "AAAAAAAA")
        let b = try writeFile(srcDir.appendingPathComponent("due.jpg"), "BBBBBBBB")
        XCTAssertEqual(try fileSize(a), try fileSize(b))

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    func testMixedIndexableAndNotIndexableSameSizeInSameSource_neitherInResult() throws {
        // Mutante mirato: se la guardia `IndexableKind` sparisse dal ramo che semina la
        // sessione con l'hash del PRIMO file di una coppia (necessaria perche'
        // `isAlreadyInLibrary` da sola non hasherebbe mai il primo file di un paio
        // tutto interno alla sorgente), un sidecar non indicizzabile potrebbe
        // "insegnare" il proprio hash a un file indicizzabile byte-identico per puro
        // caso (entrambi 0 byte), facendolo dichiarare doppione di un non-media.
        let aae = try writeFile(srcDir.appendingPathComponent("sidecar.aae"), "")
        let emptyPhoto = try writeFile(srcDir.appendingPathComponent("vuota.jpg"), "")
        XCTAssertEqual(try fileSize(aae), try fileSize(emptyPhoto))

        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(aae), try candidate(emptyPhoto)], store: nil, libraryRoot: nil,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Progresso e interruzione

    func testOnProgress_receivesTotalBeforeAnyRead_totalCountsOnlyPrefilterSurvivors() throws {
        // 3 candidati: uno solo supera il prefiltro (dimensione ripetuta nella
        // sorgente). Gli altri due sono di dimensioni uniche, mai viste altrove: il
        // denominatore della barra deve escluderli.
        let a = try writeFile(srcDir.appendingPathComponent("uno.jpg"), "ripetuto!")
        let b = try writeFile(srcDir.appendingPathComponent("due.jpg"), "ripetuto!")
        let c = try writeFile(srcDir.appendingPathComponent("unico1.jpg"), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let d = try writeFile(srcDir.appendingPathComponent("unico2.jpg"), "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")

        var firstProgressCall: (done: Int, total: Int)?
        _ = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b), try candidate(c), try candidate(d)],
            store: nil, libraryRoot: nil, isCancelled: { false },
            onProgress: { done, total in
                if firstProgressCall == nil { firstProgressCall = (done, total) }
            })

        let first = try XCTUnwrap(firstProgressCall)
        XCTAssertEqual(first.done, 0, "il totale arriva PRIMA che venga letto un solo byte")
        XCTAssertEqual(first.total, 2, "solo i due candidati con dimensione ripetuta superano il prefiltro")
    }

    func testIsCancelled_becomesTrueHalfway_returnsPartialResult() throws {
        // Due coppie di doppioni interni indipendenti. Se l'interruzione scattasse a
        // meta', il risultato conterrebbe al massimo la prima coppia: e' un risultato
        // PARZIALE, e il test lo dichiara come tale cosi' nessuno lo scambi per completo.
        let a1 = try writeFile(srcDir.appendingPathComponent("a1.jpg"), "coppia uno")
        let a2 = try writeFile(srcDir.appendingPathComponent("a2.jpg"), "coppia uno")
        let b1 = try writeFile(srcDir.appendingPathComponent("b1.jpg"), "coppia due")
        let b2 = try writeFile(srcDir.appendingPathComponent("b2.jpg"), "coppia due")

        var calls = 0
        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a1), try candidate(a2), try candidate(b1), try candidate(b2)],
            store: nil, libraryRoot: nil,
            isCancelled: {
                calls += 1
                return calls > 2
            },
            onProgress: { _, _ in })

        XCTAssertLessThan(result.count, 2, "il risultato deve essere parziale, non completo")
    }

    func testIsCancelled_alwaysTrue_noReadingEmptyResult() throws {
        let a = try writeFile(srcDir.appendingPathComponent("a.jpg"), "coppia")
        let b = try writeFile(srcDir.appendingPathComponent("b.jpg"), "coppia")

        var progressCallsAfterStart = 0
        let result = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)], store: nil, libraryRoot: nil,
            isCancelled: { true },
            onProgress: { done, _ in if done > 0 { progressCallsAfterStart += 1 } })

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(progressCallsAfterStart, 0, "nessuna lettura, quindi nessun avanzamento oltre 0")
    }

    // MARK: - Il ramo di bookkeeping che passa dallo store (rilievo di review, 2026-09-01)

    /// **Buco di copertura chiuso il 2026-09-01.** `importPreviewDuplicates` ha **due**
    /// rami che seminano `previewSession`, e fino a questo test uno solo era coperto.
    ///
    /// Tutti i test sui doppioni interni qui sopra usano `store: nil`, quindi passano
    /// sempre dal ramo "seed manuale" — quello che hasha da se' perche' `isAlreadyInLibrary`
    /// e' uscita al proprio Stadio 1. L'altro ramo — quello che registra l'hash gia'
    /// calcolato quando lo **store** aveva fatto passare lo Stadio 1 — non era esercitato da
    /// nessuno: si poteva cancellare e la suite restava verde.
    ///
    /// Lo scenario che lo isola: la libreria conosce gia' la dimensione S con un contenuto
    /// **diverso**; la sorgente porta due file byte-identici fra loro, anch'essi di
    /// dimensione S. Per il primo, lo Stadio 1 passa **grazie allo store** (non grazie a
    /// `sourceRepeatedSizes`), quindi il seed manuale non scatta mai: se il ramo di
    /// bookkeeping non registrasse l'hash, il secondo file verrebbe hashato, non troverebbe
    /// il gemello in sessione ne' corrispondenza in libreria, e risulterebbe **nuovo**.
    /// L'anteprima tornerebbe a mentire, esattamente nel caso realistico di una scheda con
    /// foto in parte nuove e in parte gia' note per dimensione.
    func testInternalPairWhoseSizeIsKnownToTheStore_isStillRecognized() throws {
        let library = libraryDir!

        // In libreria: un file di un certo contenuto. Serve solo a far conoscere allo
        // store la sua DIMENSIONE.
        let inLibrary = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"),
                                      "AAAAAAAAAAAAAAAAAAAAAAAA")
        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try seedStore(store, displayPath: "Foto/vecchia.jpg", contentsOf: inLibrary)

        // Sulla sorgente: due file byte-identici FRA LORO, della stessa dimensione di
        // quello in libreria ma con contenuto diverso. Stessa lunghezza, contenuto altro.
        let gemelli = "BBBBBBBBBBBBBBBBBBBBBBBB"
        XCTAssertEqual(gemelli.utf8.count, "AAAAAAAAAAAAAAAAAAAAAAAA".utf8.count,
                       "il caso ha senso solo se le dimensioni coincidono davvero")
        let a = try writeFile(srcDir.appendingPathComponent("uno.jpg"), gemelli)
        let b = try writeFile(srcDir.appendingPathComponent("due.jpg"), gemelli)

        // Precondizione del caso: nessuno dei due e' un doppione di cio' che c'e' in
        // libreria — altrimenti il test proverebbe un'altra cosa.
        XCTAssertNotEqual(try XCTUnwrap(sha256(of: a)), try XCTUnwrap(sha256(of: inLibrary)))

        let dup = BackupRunner.importPreviewDuplicates(
            candidates: [try candidate(a), try candidate(b)],
            store: store, libraryRoot: library,
            isCancelled: { false }, onProgress: { _, _ in })

        XCTAssertEqual(dup, [1],
                       "il secondo dei due gemelli va riconosciuto come doppione interno "
                       + "anche quando e' lo store, non il lotto, ad aver aperto lo Stadio 1")
    }

}
