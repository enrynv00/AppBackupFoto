import XCTest
@testable import AppBackupFoto

/// `TrashRestorer`: il motore fuori dal main di «Annulla l'ultimo spostamento» (ADR-0009).
/// Stessa disciplina di `DuplicateTrasherTests`: directory temporanee reali, nessun mock del
/// filesystem. Gli scollegamenti si producono iniettando `volumeIdentity`, non staccando un
/// disco vero — un test basato su una corsa reale sarebbe verde col bug ogni volta che la
/// corsa va nell'altro verso.
final class TrashRestorerTests: XCTestCase {
    private var root: URL!
    private var libraryRoot: URL!
    private var trashDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrashRestorerTests-\(UUID().uuidString)")
        // Il Cestino di prova vive DENTRO la stessa libreria, cosi' `st_dev` coincide per
        // costruzione: e' quello che succede davvero sull'SSD (`.Trashes/501/`).
        libraryRoot = root.appendingPathComponent("SSD", isDirectory: true)
        trashDir = libraryRoot.appendingPathComponent(".Trashes", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifestStore() throws -> TrashManifestStore {
        try TrashManifestStore(url: root.appendingPathComponent("manifest.json"))
    }

    @discardableResult
    private func makeTrashedFile(_ name: String, contents: String) throws -> URL {
        let url = trashDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func item(trashed: URL, originalAt original: URL, batch: String = "b1") throws -> TrashedItem {
        let measured = try XCTUnwrap(sha256Measured(of: trashed))
        return TrashedItem(batchId: batch,
                           originalDisplayPath: original.path,
                           originalKey: normalizedIndexKey(original.lastPathComponent),
                           trashedPath: trashed.path,
                           size: measured.size,
                           hash: measured.hash,
                           trashedAt: Date())
    }

    // MARK: - Percorso felice

    func testRestore_putsTheFileBack_andMarksIt() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.restored.count, 1)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "foto")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNotNil(store.lastBatch().first?.restoredAt)
    }

    // MARK: - Zero-overwrite

    func testOccupiedOriginal_isNeverOverwritten() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "cestinata")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        try "occupante".write(to: original, atomically: true, encoding: .utf8)
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertEqual(outcome.skipped.first?.reason, .originalPathOccupied)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "occupante")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNil(store.lastBatch().first?.restoredAt)
    }

    /// Corsa: l'occupante compare esattamente fra il controllo di esistenza e la mossa vera.
    /// `moveFunction` iniettata crea la destinazione e poi chiama la vera `moveItem`, che deve
    /// rifiutarla: e' il secondo strato che regge quando il primo (il nostro controllo) perde
    /// la corsa.
    func testOccupantAppearingJustBeforeTheMove_isNeverOverwritten() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "cestinata")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, moveFunction: { from, to in
            try "arrivato per primo".write(to: to, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: from, to: to)
        })
        let outcome = restorer.run([it])

        XCTAssertTrue(outcome.restored.isEmpty)
        guard case .moveFailed = outcome.skipped.first?.reason else {
            return XCTFail("atteso .moveFailed, trovato \(String(describing: outcome.skipped.first?.reason))")
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "arrivato per primo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNil(store.lastBatch().first?.restoredAt)
    }

    // MARK: - Hash illeggibile vs alterato

    func testUnreadableTrashedFile_isNotReportedAsAltered() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store,
                                     hashFunction: { _ in nil },
                                     volumeIdentity: { _ in 1 })
        let outcome = restorer.run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .unreadableInTrash)
        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished == false)
    }

    func testAlteredTrashedFile_isNotRestored() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "originale")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)
        try "alterata dopo il cestinamento".write(to: trashed, atomically: true, encoding: .utf8)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .alteredInTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    // MARK: - Scollegamento: un punto per ciascuno dei tre fallimenti

    func testVolumeVanished_whenTrashedFileIsMissing_stopsEverything() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let b = try makeTrashedFile("b.jpg", contents: "b")
        let itA = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        let itB = try item(trashed: b, originalAt: libraryRoot.appendingPathComponent("b.jpg"))
        try store.record(itA); try store.record(itB)
        try FileManager.default.removeItem(at: a)   // "sparito" prima di iniziare

        var calls = 0
        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, volumeIdentity: { _ in
            calls += 1
            return calls == 1 ? 42 : 99   // primo giro (deviceAtStart) invariato, poi cambia
        })
        let outcome = restorer.run([itA, itB])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertFalse(outcome.skipped.contains { $0.reason == .missingInTrash })
        XCTAssertFalse(outcome.skipped.contains { $0.reason == .alteredInTrash })
        XCTAssertEqual(outcome.notAttempted, 1, "solo b.jpg non e' mai stato tentato")
    }

    func testVolumeVanished_whenHashIsNil_stopsEverything() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let it = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        try store.record(it)

        var calls = 0
        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store,
                                     hashFunction: { _ in nil },
                                     volumeIdentity: { _ in
            calls += 1
            // call1 = deviceAtStart, call2 = disco del Cestino (invariato): entrambi 42.
            // call3 = ricontrollo dopo l'hash `nil`: cambiato.
            return calls <= 2 ? 42 : 99
        })
        let outcome = restorer.run([it])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertFalse(outcome.skipped.contains { $0.reason == .unreadableInTrash })
        XCTAssertEqual(outcome.notAttempted, 0)
    }

    func testVolumeVanished_whenMoveThrowsNoSuchFile_stopsEverything() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let it = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        try store.record(it)

        var calls = 0
        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, moveFunction: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 4)
        }, volumeIdentity: { _ in
            calls += 1
            // Invariato per: deviceAtStart, il controllo del disco del Cestino, il
            // ricontrollo pre-`createDirectory`. Cambia solo DOPO che `moveFunction` lancia,
            // nel controllo dentro il `catch`.
            return calls <= 3 ? 42 : 99
        })
        let outcome = restorer.run([it])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertFalse(outcome.skipped.contains { if case .moveFailed = $0.reason { return true }; return false })
        XCTAssertTrue(outcome.restored.isEmpty)
    }

    func testVolumeMissingAtStart_attemptsNothing() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let it = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        try store.record(it)

        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, volumeIdentity: { _ in nil })
        let outcome = restorer.run([it])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertEqual(outcome.notAttempted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "non doveva toccare niente")
    }

    func testVolumeChangedAfterTheReread_createsNoFolder() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let original = libraryRoot.appendingPathComponent("nuova-cartella/a.jpg")
        let it = try item(trashed: a, originalAt: original)
        try store.record(it)

        var calls = 0
        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, volumeIdentity: { _ in
            calls += 1
            return calls <= 2 ? 42 : 99   // invariato per deviceAtStart + il controllo pre-createDirectory: cambia
        })
        let outcome = restorer.run([it])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.deletingLastPathComponent().path),
                       "ha creato la cartella intermedia nonostante il disco fosse sparito")
    }

    // MARK: - Interruzione

    func testInterruption_marksOnlyWhatWasRestored_andASecondRunFinishes() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let b = try makeTrashedFile("b.jpg", contents: "b")
        let itA = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        let itB = try item(trashed: b, originalAt: libraryRoot.appendingPathComponent("b.jpg"))
        try store.record(itA); try store.record(itB)

        var stopAtSecond = false
        let outcome1 = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run(
            [itA, itB], isCancelled: { let s = stopAtSecond; stopAtSecond = true; return s })
        XCTAssertEqual(outcome1.restored.count, 1)
        XCTAssertTrue(outcome1.interrupted)
        XCTAssertEqual(store.pendingInLastBatch().count, 1)

        let outcome2 = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run(store.pendingInLastBatch())
        XCTAssertEqual(outcome2.restored.count, 1)
        XCTAssertTrue(store.pendingInLastBatch().isEmpty)
    }

    // MARK: - Riconciliazione

    func testFileAlreadyBackInPlace_isReconciled_notReportedAsMissing() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let original = libraryRoot.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)
        // L'utente ha fatto "Rimetti a posto" dal Finder: il file e' gia' al suo posto.
        try FileManager.default.moveItem(at: trashed, to: original)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.alreadyInPlace.count, 1)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertNotNil(store.lastBatch().first?.restoredAt)
    }

    func testFileMissingEverywhere_isMissingInTrash() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        try store.record(it)
        try FileManager.default.removeItem(at: trashed)   // "Cestino svuotato" per davvero

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .missingInTrash)
        XCTAssertNil(store.lastBatch().first?.restoredAt)
    }

    // MARK: - Confinamento

    func testOriginalOutsideTheLibrary_isRefused() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let fuori = root.appendingPathComponent("fuori-dalla-libreria/a.jpg")
        let it = try item(trashed: trashed, originalAt: fuori)
        try store.record(it)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .outsideLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fuori.path))
    }

    func testOriginalWithDotDot_isRefused() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let conDotDot = libraryRoot.appendingPathComponent("../fuori/a.jpg")
        var it = try item(trashed: trashed, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        it.originalDisplayPath = conDotDot.path

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .outsideLibrary)
    }

    func testTrashedFileOnAnotherDisk_isRefused() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        try store.record(it)

        let restorer = TrashRestorer(libraryRoot: libraryRoot, manifest: store, volumeIdentity: { url in
            url.path == trashed.path ? 7 : 42   // il file nel Cestino "sta" su un disco diverso
        })
        let outcome = restorer.run([it])

        XCTAssertEqual(outcome.skipped.first?.reason, .outsideLibrary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    // MARK: - Progresso

    func testProgress_isReportedOncePerItem_includingSkipped() throws {
        let store = try manifestStore()
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let b = try makeTrashedFile("b.jpg", contents: "b")
        let occupato = libraryRoot.appendingPathComponent("occupato.jpg")
        try "occupante".write(to: occupato, atomically: true, encoding: .utf8)
        let itA = try item(trashed: a, originalAt: libraryRoot.appendingPathComponent("a.jpg"))
        let itOccupato = try item(trashed: b, originalAt: occupato)
        try store.record(itA); try store.record(itOccupato)

        var calls: [(Int, Int)] = []
        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run(
            [itA, itOccupato], onProgress: { done, total in calls.append((done, total)) })

        XCTAssertEqual(outcome.restored.count, 1)
        XCTAssertEqual(outcome.skipped.first?.reason, .originalPathOccupied)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.0, 2)
        XCTAssertEqual(calls.last?.1, 2)
    }

    // MARK: - Cartelle intermedie (portato da TrashManifestTests)

    func testMissingIntermediateFolders_areRecreated() throws {
        let store = try manifestStore()
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let original = libraryRoot.appendingPathComponent("2019 Vacanze/Luglio/a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let outcome = TrashRestorer(libraryRoot: libraryRoot, manifest: store).run([it])

        XCTAssertEqual(outcome.restored.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
