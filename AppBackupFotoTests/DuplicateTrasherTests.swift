import XCTest
@testable import AppBackupFoto

/// Il motore di cancellazione: l'unico componente del progetto che sposta un file foto.
///
/// Tutti i test girano su directory temporanee **reali** — nessun mock del filesystem, come
/// nel resto del progetto. `trashFunction` e `hashFunction` sono invece iniettate, perche'
/// gli esiti che contano (un hash che cambia fra la visualizzazione e la cancellazione, uno
/// scollegamento a meta' blocco) non sono producibili su file veri senza una corsa fra
/// thread, e un test basato su una corsa e' verde col bug ogni volta che la corsa va
/// nell'altro verso.
final class DuplicateTrasherTests: XCTestCase {

    private var root: URL!
    private var libraryRoot: URL!
    private var trashDir: URL!
    private var store: LibraryIndexStore!
    private var manifest: TrashManifestStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("duptrasher-\(UUID().uuidString)")
        // La libreria e' una SOTTOcartella della root di test: cosi' il Cestino finto puo'
        // stare fuori dalla libreria, come il Cestino vero sta fuori dalle cartelle foto.
        libraryRoot = root.appendingPathComponent("SSD", isDirectory: true)
        trashDir = root.appendingPathComponent("Cestino", isDirectory: true)
        for dir in [libraryRoot!, trashDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        manifest = try TrashManifestStore(url: root.appendingPathComponent("trash-manifest.json"))
    }

    override func tearDownWithError() throws {
        store = nil
        manifest = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Infrastruttura

    /// Registra ogni chiamata e, per default, sposta davvero il file nel Cestino finto.
    /// `failure` permette di far fallire una chiamata specifica; `beforeThrowing` di
    /// simulare il mondo che cambia (la root che sparisce) nell'istante del fallimento.
    private final class TrashSpy {
        private(set) var calls: [URL] = []
        let trashDir: URL
        var failure: ((URL, Int) -> Error?)?
        var beforeThrowing: (() -> Void)?
        /// Quando e' `false` la funzione non tocca il filesystem: serve a provare che
        /// nessun altro ramo del motore cancella per conto suo.
        var actuallyMoves = true

        init(trashDir: URL) { self.trashDir = trashDir }

        func trash(_ url: URL) throws -> URL? {
            calls.append(url)
            if let error = failure?(url, calls.count) {
                beforeThrowing?()
                throw error
            }
            guard actuallyMoves else { return nil }
            let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    private var spy: TrashSpy!

    private func makeTrasher(hashFunction: ((URL) -> MeasuredHash?)? = nil) -> DuplicateTrasher {
        if spy == nil { spy = TrashSpy(trashDir: trashDir) }
        return DuplicateTrasher(libraryRoot: libraryRoot,
                                store: store,
                                manifest: manifest,
                                trashFunction: { [spy] in try spy!.trash($0) },
                                hashFunction: hashFunction ?? { sha256Measured(of: $0) })
    }

    @discardableResult
    private func makeMedia(_ relative: String, contents: String) throws -> URL {
        let url = libraryRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func entry(_ relative: String) throws -> LibraryIndexEntry {
        try entry(at: libraryRoot.appendingPathComponent(relative), displayPath: relative)
    }

    private func entry(at url: URL, displayPath: String) throws -> LibraryIndexEntry {
        let measured = try XCTUnwrap(sha256Measured(of: url))
        return LibraryIndexEntry(path: normalizedIndexKey(displayPath),
                                 displayPath: displayPath,
                                 size: measured.size,
                                 mtime: 0,
                                 hash: measured.hash,
                                 hashedAt: Date().timeIntervalSince1970)
    }

    /// Un gruppo dai membri dati, con l'hash del primo e la dimensione minima — le stesse
    /// invarianti che `LibraryIndexStore.duplicateGroups()` garantisce.
    private func group(_ members: [LibraryIndexEntry], hash: String? = nil) -> DuplicateGroup {
        DuplicateGroup(hash: hash ?? members[0].hash,
                       size: members.map(\.size).min() ?? 0,
                       members: members)
    }

    /// Tre copie identiche, indicizzate. La prima e' quella che si tiene.
    ///
    /// ATTENZIONE per chi scrive nuovi test: un contenuto "modificato" deve avere la
    /// **stessa lunghezza** dell'originale (9 byte). Cambiando anche la dimensione scatta
    /// prima `sizeChanged` e la guardia sull'unanimita' degli hash non viene mai raggiunta:
    /// il test resterebbe verde anche togliendola. Trovato dal mutation testing il
    /// 2026-08-31 — due mutanti sopravvissuti proprio per questo.
    private func healthyTrio() throws -> (DuplicateTrasher.Decision, [LibraryIndexEntry]) {
        try makeMedia("Foto iPhone/a.jpg", contents: "identiche")
        try makeMedia("Import/b.jpg", contents: "identiche")
        try makeMedia("Import/c.jpg", contents: "identiche")
        let entries = [try entry("Foto iPhone/a.jpg"), try entry("Import/b.jpg"), try entry("Import/c.jpg")]
        try store.upsert(entries)
        return (DuplicateTrasher.Decision(group: group(entries), keeper: entries[0]), entries)
    }

    // MARK: - Verifica prima della cancellazione

    func testHealthyGroup_trashesAllButKeeper() throws {
        let (decision, entries) = try healthyTrio()
        let outcome = makeTrasher().run([decision])

        XCTAssertEqual(outcome.trashedFiles.count, 2)
        XCTAssertTrue(outcome.skippedGroups.isEmpty)
        XCTAssertFalse(outcome.stoppedBecauseVolumeVanished)
        XCTAssertFalse(outcome.interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(entries[0].displayPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(entries[1].displayPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(entries[2].displayPath).path))
    }

    /// Mutante: «un membro con hash diverso viene solo escluso, gli altri si cestinano».
    func testOneMemberDiffers_skipsWholeGroup() throws {
        let (decision, _) = try healthyTrio()
        // Il contenuto di una copia cambia DOPO che l'indice l'ha registrata.
        try makeMedia("Import/c.jpg", contents: "diverseXX")

        let outcome = makeTrasher().run([decision])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0, "nessun file va toccato se il gruppo non e' unanime")
    }

    /// Mutante: «si rileggono solo i file da cestinare, non il tenuto».
    ///
    /// E' il test che distingue il livello 3 di fiducia dal livello 2: rileggere solo i file
    /// da cestinare direbbe che sono uguali *fra loro*, non che sono uguali a quello che resta.
    func testKeeperContentChanged_skipsWholeGroup() throws {
        let (decision, _) = try healthyTrio()
        try makeMedia("Foto iPhone/a.jpg", contents: "cambiata!")

        let outcome = makeTrasher().run([decision])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("Import/b.jpg").path))
    }

    /// Mutante: «`nil` da `hashFunction` trattato come "coincide"».
    func testUnreadableMember_skipsWholeGroup() throws {
        let (decision, entries) = try healthyTrio()
        let illeggibile = entries[2].displayPath
        let outcome = makeTrasher(hashFunction: { url in
            url.path.hasSuffix(illeggibile) ? nil : sha256Measured(of: url)
        }).run([decision])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0, "mai «cestino quelli che ho potuto verificare»")
    }

    func testSizeMismatch_skipsWholeGroup() throws {
        try makeMedia("Foto iPhone/a.jpg", contents: "identiche")
        try makeMedia("Import/b.jpg", contents: "identiche")
        var entries = [try entry("Foto iPhone/a.jpg"), try entry("Import/b.jpg")]
        // L'indice dice una dimensione, il file ne ha un'altra.
        entries[1] = LibraryIndexEntry(path: entries[1].path, displayPath: entries[1].displayPath,
                                       size: entries[1].size + 10, mtime: 0,
                                       hash: entries[1].hash, hashedAt: 0)
        try store.upsert(entries)

        let outcome = makeTrasher().run([.init(group: group(entries), keeper: entries[0])])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
    }

    func testMissingMember_skipsWholeGroup() throws {
        let (decision, entries) = try healthyTrio()
        try FileManager.default.removeItem(at: libraryRoot.appendingPathComponent(entries[2].displayPath))

        let outcome = makeTrasher().run([decision])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
    }

    /// L'indice era stantio su **tutti** i membri insieme: fra loro coincidono, ma non con
    /// l'hash del gruppo. Un confronto solo fra membri non lo intercetterebbe.
    func testHashesUnanimousButDifferentFromGroup_skipsWholeGroup() throws {
        try makeMedia("Foto iPhone/a.jpg", contents: "coerenti fra loro")
        try makeMedia("Import/b.jpg", contents: "coerenti fra loro")
        let entries = [try entry("Foto iPhone/a.jpg"), try entry("Import/b.jpg")]
        try store.upsert(entries)

        let stantio = group(entries, hash: String(repeating: "a", count: 64))
        let outcome = makeTrasher().run([.init(group: stantio, keeper: entries[0])])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
    }

    // MARK: - Guardie

    /// Mutante: «confinamento con `hasPrefix` invece che per componenti».
    ///
    /// La libreria e' `<root>/SSD`, il file sta in `<root>/SSD 2`: prefisso testuale, ma
    /// non componente. Con `hasPrefix` questo test passerebbe anche col bug.
    func testSiblingRootWithCommonPrefix_isRefused() throws {
        let sibling = root.appendingPathComponent("SSD 2", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try makeMedia("Foto iPhone/a.jpg", contents: "identiche")
        let fuori = sibling.appendingPathComponent("b.jpg")
        try "identiche".write(to: fuori, atomically: true, encoding: .utf8)

        let dentro = try entry("Foto iPhone/a.jpg")
        let esterno = try entry(at: fuori, displayPath: "../SSD 2/b.jpg")
        try store.upsert([dentro, esterno])

        let outcome = makeTrasher().run([.init(group: group([dentro, esterno]), keeper: dentro)])

        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fuori.path),
                      "un file fuori dalla libreria non si tocca mai")
    }

    /// Mutante: «guardia `IndexableKind` rimossa».
    func testNonMediaEntry_isNeverTrashed() throws {
        try makeMedia("Foto iPhone/a.jpg", contents: "identiche")
        try makeMedia("Import/note.txt", contents: "identiche")
        let entries = [try entry("Foto iPhone/a.jpg"), try entry("Import/note.txt")]
        try store.upsert(entries)

        let outcome = makeTrasher().run([.init(group: group(entries), keeper: entries[0])])

        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("Import/note.txt").path))
    }

    /// Mutante: «off-by-one che include il tenuto nel ciclo».
    func testKeeperIsNeverPassedToTrash() throws {
        let (decision, entries) = try healthyTrio()
        let keeperPath = libraryRoot.appendingPathComponent(entries[0].displayPath).standardizedFileURL.path

        _ = makeTrasher().run([decision])

        XCTAssertFalse(spy.calls.contains { $0.standardizedFileURL.path == keeperPath },
                       "la copia tenuta non deve mai essere passata a trashItem")
        XCTAssertEqual(spy.calls.count, 2)
    }

    func testSingleMemberGroup_trashesNothing() throws {
        try makeMedia("Foto iPhone/a.jpg", contents: "sola")
        let solo = try entry("Foto iPhone/a.jpg")
        try store.upsert([solo])

        let outcome = makeTrasher().run([.init(group: group([solo]), keeper: solo)])

        XCTAssertEqual(spy.calls.count, 0)
        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(outcome.skippedGroups.first?.reason, .nothingToTrash)
    }

    func testGroupWithKeeperNotAMember_isSkipped() throws {
        let (_, entries) = try healthyTrio()
        try makeMedia("Foto iPhone/estranea.jpg", contents: "identiche")
        let estranea = try entry("Foto iPhone/estranea.jpg")

        let outcome = makeTrasher().run([.init(group: group(entries), keeper: estranea)])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(spy.calls.count, 0)
    }

    // MARK: - Scollegamento

    /// Mutante: «il controllo di `st_dev` dopo un fallimento viene rimosso».
    ///
    /// Il primo file viene spostato davvero; al secondo la root sparisce e `trashItem`
    /// fallisce con `NSCocoaErrorDomain/4`. Il blocco intero si ferma, e il numero di file
    /// gia' spostati resta onesto.
    func testUnmountMidBatch_stopsEverything() throws {
        let (primo, _) = try healthyTrio()
        try makeMedia("Altro/d.jpg", contents: "secondo gruppo")
        try makeMedia("Altro/e.jpg", contents: "secondo gruppo")
        let secondi = [try entry("Altro/d.jpg"), try entry("Altro/e.jpg")]
        try store.upsert(secondi)
        let secondo = DuplicateTrasher.Decision(group: group(secondi), keeper: secondi[0])

        spy = TrashSpy(trashDir: trashDir)
        spy.failure = { _, n in
            n == 2 ? NSError(domain: NSCocoaErrorDomain, code: 4) : nil
        }
        spy.beforeThrowing = { [libraryRoot] in
            try? FileManager.default.removeItem(at: libraryRoot!)
        }

        let outcome = makeTrasher().run([primo, secondo])

        XCTAssertTrue(outcome.stoppedBecauseVolumeVanished)
        XCTAssertEqual(outcome.trashedFiles.count, 1, "il conteggio dei gia' spostati resta onesto")
        XCTAssertEqual(spy.calls.count, 2, "il secondo gruppo non viene nemmeno tentato")
    }

    /// L'altra meta': stesso errore, volume ancora al suo posto. Solo quel gruppo si chiude,
    /// il blocco prosegue. I due casi si distinguono da `st_dev`, non dall'errore.
    func testTrashFailureWithoutUnmount_closesOnlyThatGroup() throws {
        let (primo, _) = try healthyTrio()
        try makeMedia("Altro/d.jpg", contents: "secondo gruppo")
        try makeMedia("Altro/e.jpg", contents: "secondo gruppo")
        let secondi = [try entry("Altro/d.jpg"), try entry("Altro/e.jpg")]
        try store.upsert(secondi)
        let secondo = DuplicateTrasher.Decision(group: group(secondi), keeper: secondi[0])

        spy = TrashSpy(trashDir: trashDir)
        spy.failure = { _, n in n == 1 ? NSError(domain: NSCocoaErrorDomain, code: 4) : nil }

        let outcome = makeTrasher().run([primo, secondo])

        XCTAssertFalse(outcome.stoppedBecauseVolumeVanished)
        XCTAssertEqual(outcome.skippedGroups.count, 1, "solo il primo gruppo si chiude")
        XCTAssertEqual(outcome.trashedFiles.count, 1, "il secondo gruppo viene smaltito")
    }

    /// Mutante: «`NSCocoaErrorDomain/4` trattato come successo o come "gia' fatto"».
    func testFileNotFoundError_isNeverTreatedAsDone() throws {
        let (decision, entries) = try healthyTrio()
        spy = TrashSpy(trashDir: trashDir)
        spy.failure = { _, _ in NSError(domain: NSCocoaErrorDomain, code: 4) }

        let outcome = makeTrasher().run([decision])

        XCTAssertTrue(outcome.trashedFiles.isEmpty, "un fallimento non e' mai un successo")
        XCTAssertEqual(outcome.skippedGroups.count, 1)
        if case .trashFailed? = outcome.skippedGroups.first?.reason {} else {
            XCTFail("il fallimento va riportato come tale")
        }
        let chiavi = try store.allKeys()
        XCTAssertTrue(chiavi.contains(entries[1].path), "la entry resta: il file non e' stato spostato")
    }

    // MARK: - Post-condizione e indice

    /// Mutante: «il tenuto sparito non fa scattare il ripristino».
    func testKeeperVanished_restoresWhatWasJustTrashed() throws {
        let (decision, entries) = try healthyTrio()
        let keeperURL = libraryRoot.appendingPathComponent(entries[0].displayPath)
        spy = TrashSpy(trashDir: trashDir)
        // La copia tenuta sparisce mentre il gruppo viene smaltito.
        spy.failure = { _, n in
            if n == 2 { try? FileManager.default.removeItem(at: keeperURL) }
            return nil
        }

        let outcome = makeTrasher().run([decision])

        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(outcome.skippedGroups.first?.reason,
                       .keeperVanished(displayPath: entries[0].displayPath))
        XCTAssertTrue(outcome.trashedFiles.isEmpty, "niente e' stato smaltito davvero")
        for e in entries.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(e.displayPath).path),
                          "\(e.displayPath) doveva essere rimesso a posto")
        }
        // Task 4, ADR-0009: il ripristino passa da `TrashRestorer`, che marca le voci
        // rimesse a posto nel registro — non piu' solo mosse sul disco.
        for item in manifest.lastBatch() {
            XCTAssertNotNil(item.restoredAt, "\(item.originalDisplayPath) non risulta marcata come tornata")
        }
    }

    func testIndexLosesOnlyTrashedKeys() throws {
        let (decision, entries) = try healthyTrio()
        _ = makeTrasher().run([decision])

        let chiavi = try store.allKeys()
        XCTAssertTrue(chiavi.contains(entries[0].path), "la chiave del tenuto non si tocca mai")
        XCTAssertFalse(chiavi.contains(entries[1].path))
        XCTAssertFalse(chiavi.contains(entries[2].path))
    }

    /// Mutante: «rimozione dall'indice **prima** del cestinamento».
    func testTrashFailure_leavesIndexEntry() throws {
        let (decision, entries) = try healthyTrio()
        spy = TrashSpy(trashDir: trashDir)
        spy.failure = { _, _ in NSError(domain: NSCocoaErrorDomain, code: 513) }

        _ = makeTrasher().run([decision])

        let chiavi = try store.allKeys()
        for e in entries {
            XCTAssertTrue(chiavi.contains(e.path), "\(e.path) doveva restare nell'indice")
        }
    }

    /// Mutante: «rimozione dall'indice anche per i gruppi saltati».
    func testSkippedGroup_leavesIndexUntouched() throws {
        let (decision, entries) = try healthyTrio()
        try makeMedia("Import/c.jpg", contents: "diverseXX")

        _ = makeTrasher().run([decision])

        let chiavi = try store.allKeys()
        for e in entries {
            XCTAssertTrue(chiavi.contains(e.path), "\(e.path) doveva restare nell'indice")
        }
    }

    func testInterruptedMidBatch_keepsClosedGroupsClosed() throws {
        let (primo, _) = try healthyTrio()
        try makeMedia("Altro/d.jpg", contents: "secondo gruppo")
        try makeMedia("Altro/e.jpg", contents: "secondo gruppo")
        let secondi = [try entry("Altro/d.jpg"), try entry("Altro/e.jpg")]
        try store.upsert(secondi)
        let secondo = DuplicateTrasher.Decision(group: group(secondi), keeper: secondi[0])

        var visti = 0
        let outcome = makeTrasher().run([primo, secondo], isCancelled: {
            defer { visti += 1 }
            return visti == 1
        })

        XCTAssertTrue(outcome.interrupted)
        XCTAssertEqual(outcome.trashedFiles.count, 2, "il primo gruppo resta chiuso")
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("Altro/e.jpg").path),
                      "il secondo gruppo non e' stato toccato")
    }

    // MARK: - Invariante strutturale

    /// Mutante: «un `removeItem` aggiunto "per pulizia"».
    ///
    /// Con una `trashFunction` che non fa nulla, tutti i file devono esistere ancora a fine
    /// corsa. E' il modo di provare che `trashItem` e' l'unica porta senza affidarsi a una
    /// lettura del codice.
    func testNoOpTrashFunction_leavesEveryFileOnDisk() throws {
        let (decision, entries) = try healthyTrio()
        spy = TrashSpy(trashDir: trashDir)
        spy.actuallyMoves = false

        _ = makeTrasher().run([decision])

        for e in entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(e.displayPath).path),
                          "\(e.displayPath) e' stato toccato da qualcosa che non e' trashItem")
        }
    }

    // MARK: - Registro di ripristino

    func testEveryTrashedFileIsRecordedInManifest() throws {
        let (decision, _) = try healthyTrio()
        _ = makeTrasher().run([decision])

        XCTAssertEqual(manifest.itemCount, 2)
        XCTAssertEqual(manifest.totalRecorded, 2)
    }

    func testManifestRecordsAbsoluteOriginalPathAndNormalizedKey() throws {
        let (decision, entries) = try healthyTrio()
        _ = makeTrasher().run([decision])

        let voce = try XCTUnwrap(manifest.lastBatch().first { $0.originalKey == entries[1].path })
        XCTAssertTrue(voce.originalDisplayPath.hasPrefix("/"),
                      "restore() riapre questo percorso con URL(fileURLWithPath:): deve essere assoluto")
        XCTAssertEqual(voce.originalKey, entries[1].path)
        XCTAssertEqual(voce.hash, entries[1].hash)
        XCTAssertEqual(voce.size, entries[1].size)
    }

    /// La voce del registro deve bastare, da sola, a rimettere il file al suo posto: e' la
    /// rete di sicurezza dell'intera feature.
    func testRecordedItemsAreEnoughToRestore() throws {
        let (decision, entries) = try healthyTrio()
        _ = makeTrasher().run([decision])

        let esito = TrashRestorer(libraryRoot: libraryRoot, manifest: manifest).run(manifest.lastBatch())

        XCTAssertEqual(esito.restored.count, 2)
        XCTAssertTrue(esito.skipped.isEmpty)
        for e in entries.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(e.displayPath).path))
        }
    }

    func testTrashedItemsShareOneBatchId() throws {
        let (decision, _) = try healthyTrio()
        _ = makeTrasher().run([decision], batchId: "blocco-1")

        XCTAssertEqual(Set(manifest.lastBatch().map(\.batchId)), ["blocco-1"])
    }

    func testSkippedGroup_recordsNothingInManifest() throws {
        let (decision, _) = try healthyTrio()
        try makeMedia("Import/c.jpg", contents: "diverseXX")

        _ = makeTrasher().run([decision])

        XCTAssertEqual(manifest.itemCount, 0)
        XCTAssertEqual(manifest.totalRecorded, 0)
    }

    // MARK: - Blocco

    func testMultipleGroups_allProcessed() throws {
        let (primo, _) = try healthyTrio()
        try makeMedia("Altro/d.jpg", contents: "secondo gruppo")
        try makeMedia("Altro/e.jpg", contents: "secondo gruppo")
        let secondi = [try entry("Altro/d.jpg"), try entry("Altro/e.jpg")]
        try store.upsert(secondi)

        let outcome = makeTrasher().run([primo, .init(group: group(secondi), keeper: secondi[0])])

        XCTAssertEqual(outcome.trashedFiles.count, 3)
        XCTAssertTrue(outcome.skippedGroups.isEmpty)
    }

    func testEmptyBatch_isANoOp() throws {
        let outcome = makeTrasher().run([])

        XCTAssertTrue(outcome.trashedFiles.isEmpty)
        XCTAssertTrue(outcome.skippedGroups.isEmpty)
        XCTAssertFalse(outcome.interrupted)
        XCTAssertFalse(outcome.stoppedBecauseVolumeVanished)
    }

    func testGoodGroupSurvivesABadOne() throws {
        let (primo, _) = try healthyTrio()
        try makeMedia("Import/c.jpg", contents: "rotta!!!!")
        try makeMedia("Altro/d.jpg", contents: "secondo gruppo")
        try makeMedia("Altro/e.jpg", contents: "secondo gruppo")
        let secondi = [try entry("Altro/d.jpg"), try entry("Altro/e.jpg")]
        try store.upsert(secondi)

        let outcome = makeTrasher().run([primo, .init(group: group(secondi), keeper: secondi[0])])

        XCTAssertEqual(outcome.skippedGroups.count, 1)
        XCTAssertEqual(outcome.trashedFiles.count, 1)
    }

    // MARK: - Messaggi

    /// Ogni motivo ha una frase propria: chi vede un gruppo restare nell'elenco deve capire
    /// quale dei casi lo riguarda.
    func testSkipReasons_haveDistinctExplanations() {
        let motivi: [DuplicateTrashSkipReason] = [
            .contentDisagrees(displayPath: "a.jpg"),
            .unreadable(displayPath: "a.jpg"),
            .sizeChanged(displayPath: "a.jpg"),
            .outsideLibrary(displayPath: "a.jpg"),
            .notMedia(displayPath: "a.jpg"),
            .nothingToTrash,
            .trashFailed(displayPath: "a.jpg", detail: "x"),
            .keeperVanished(displayPath: "a.jpg")
        ]
        let frasi = motivi.map(\.explanation)
        XCTAssertEqual(Set(frasi).count, motivi.count, "due motivi non devono dire la stessa cosa")
        XCTAssertFalse(frasi.contains { $0.isEmpty })
    }
}
