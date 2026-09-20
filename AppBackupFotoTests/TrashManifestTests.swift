import XCTest
@testable import AppBackupFoto

/// Il registro di ripristino: la rete di sicurezza della decisione 2 di Enrico.
///
/// Non puo' poggiare sul Finder — misurato che il record «Rimetti a posto» e' scritto in
/// modo asincrono e si perde se il processo muore subito dopo (226/300 e 85/100 in due
/// misure indipendenti; 100/100 solo col processo vivo). Da qui un registro nostro, scritto
/// **subito**, su directory temporanee reali come tutto il resto del progetto.
final class TrashManifestTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trashmanifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var manifestURL: URL { root.appendingPathComponent("trash-manifest.json") }

    /// Un file col contenuto dato, e l'item che lo descrive come se fosse gia' nel Cestino.
    @discardableResult
    private func makeTrashedFile(_ name: String, contents: String) throws -> URL {
        let trash = root.appendingPathComponent("Cestino", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let url = trash.appendingPathComponent(name)
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

    /// `restore` non e' piu' un metodo dello store (ADR-0009): il motore e' `TrashRestorer`,
    /// con `root` come `libraryRoot` — sia gli originali sia il Cestino di prova vivono
    /// sotto la stessa directory temporanea, quindi `st_dev` coincide per costruzione.
    private func restore(_ items: [TrashedItem], via store: TrashManifestStore) -> RestoreOutcome {
        TrashRestorer(libraryRoot: root, manifest: store).run(items)
    }

    // MARK: - Scrittura immediata

    /// **La lezione diretta della misura sul Finder.** Un registro bufferizzato e scritto a
    /// fine blocco ha lo stesso identico difetto di quello che stiamo sostituendo: se il
    /// processo muore a meta' blocco, i file sono nel Cestino e nessuno sa piu' da dove
    /// venivano. Il test riapre lo store **da zero**, senza chiuderlo ordinatamente.
    func testRecordIsOnDiskImmediately() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        try store.record(try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg")))

        let riletto = try TrashManifestStore(url: manifestURL)
        XCTAssertEqual(riletto.lastBatch().count, 1)
        XCTAssertEqual(riletto.lastBatch().first?.trashedPath, trashed.path)
    }

    func testLastBatch_returnsOnlyTheMostRecentBatch() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let uno = try makeTrashedFile("uno.jpg", contents: "1")
        let due = try makeTrashedFile("due.jpg", contents: "2")
        let tre = try makeTrashedFile("tre.jpg", contents: "3")
        try store.record(try item(trashed: uno, originalAt: root.appendingPathComponent("uno.jpg"), batch: "b1"))
        try store.record(try item(trashed: due, originalAt: root.appendingPathComponent("due.jpg"), batch: "b2"))
        try store.record(try item(trashed: tre, originalAt: root.appendingPathComponent("tre.jpg"), batch: "b2"))

        let ultimo = store.lastBatch()
        XCTAssertEqual(ultimo.count, 2)
        XCTAssertEqual(Set(ultimo.map(\.batchId)), ["b2"])
    }

    /// Il blocco piu' recente e' quello registrato per **ultimo**, non quello con la data
    /// piu' alta: le date possono coincidere, l'ordine di registrazione no.
    func testLastBatch_isEmptyOnAFreshStore() throws {
        XCTAssertTrue(try TrashManifestStore(url: manifestURL).lastBatch().isEmpty)
    }

    // MARK: - Ripristino

    func testRestore_putsTheFileBackWithItsContentIntact() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "contenuto originale")
        let original = root.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let esito = restore([it], via: store)
        XCTAssertEqual(esito.restored.count, 1)
        XCTAssertTrue(esito.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "contenuto originale")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path), "il file non e' stato spostato")
    }

    /// Fra il cestinamento e l'annullamento l'utente puo' aver cancellato la cartella che
    /// conteneva le foto: ricrearla e' l'unico modo perche' l'annullamento funzioni davvero.
    func testRestore_recreatesMissingIntermediateFolders() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let original = root.appendingPathComponent("2019 Vacanze/Luglio/a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        XCTAssertEqual(restore([it], via: store).restored.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    /// **Il file nel Cestino e' stato alterato**: non si ripristina. Un file diverso da
    /// quello cestinato non e' la foto dell'utente, e rimetterlo al posto dell'originale
    /// sarebbe una sostituzione silenziosa.
    func testAlteredTrashedFile_isNotRestored() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "originale")
        let original = root.appendingPathComponent("a.jpg")
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        try "alterato dopo il cestinamento".write(to: trashed, atomically: true, encoding: .utf8)

        let esito = restore([it], via: store)
        XCTAssertTrue(esito.restored.isEmpty)
        XCTAssertEqual(esito.skipped.count, 1)
        XCTAssertEqual(esito.skipped.first?.reason, .alteredInTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "ha ripristinato un file alterato")
    }

    /// Stessa dimensione, contenuto diverso: e' il caso che una guardia basata sulla sola
    /// dimensione lascerebbe passare, ed e' esattamente quello che il confronto dell'hash
    /// esiste per intercettare.
    func testTrashedFileAlteredKeepingTheSameSize_isNotRestored() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "AAAA")
        let it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        try store.record(it)

        try "BBBB".write(to: trashed, atomically: true, encoding: .utf8)
        XCTAssertEqual(it.size, 4)

        XCTAssertEqual(restore([it], via: store).skipped.first?.reason, .alteredInTrash)
    }

    /// **Il percorso originale e' di nuovo occupato**: non si sovrascrive. Non basta
    /// affidarsi al rifiuto di `moveItem` (misurato `NSCocoaErrorDomain/516`): la guardia e'
    /// nostra, e questo test la prova. E' la regola zero-overwrite, che vale anche qui.
    func testOccupiedOriginalPath_isNotOverwritten() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "quella cestinata")
        let original = root.appendingPathComponent("a.jpg")
        try "una foto nuova, arrivata dopo".write(to: original, atomically: true, encoding: .utf8)
        let it = try item(trashed: trashed, originalAt: original)
        try store.record(it)

        let esito = restore([it], via: store)
        XCTAssertEqual(esito.skipped.first?.reason, .originalPathOccupied)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "una foto nuova, arrivata dopo",
                       "ha sovrascritto il file che si trovava al posto originale")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path),
                      "il file cestinato e' sparito senza essere stato ripristinato")
    }

    /// Cestino svuotato: la voce non e' piu' ripristinabile. Va detto, non e' un errore
    /// fatale e non deve fermare il resto.
    func testMissingTrashedFile_isReportedAndNotFatal() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        try store.record(it)
        try FileManager.default.removeItem(at: trashed)

        let esito = restore([it], via: store)
        XCTAssertEqual(esito.skipped.first?.reason, .missingInTrash)
        XCTAssertTrue(esito.restored.isEmpty)
    }

    /// Una voce non ripristinabile **non blocca le altre**. La fixture mette quella rotta
    /// in mezzo: se stesse per prima o per ultima, un `for` che esce al primo problema
    /// darebbe comunque 2 ripristinate in uno dei due ordini e il test sarebbe cieco.
    func testOneBadEntry_doesNotBlockTheOthers() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let a = try makeTrashedFile("a.jpg", contents: "a")
        let rotta = try makeTrashedFile("rotta.jpg", contents: "rotta")
        let c = try makeTrashedFile("c.jpg", contents: "c")
        let items = [try item(trashed: a, originalAt: root.appendingPathComponent("a.jpg")),
                     try item(trashed: rotta, originalAt: root.appendingPathComponent("rotta.jpg")),
                     try item(trashed: c, originalAt: root.appendingPathComponent("c.jpg"))]
        for it in items { try store.record(it) }
        try FileManager.default.removeItem(at: rotta)

        let esito = restore(items, via: store)
        XCTAssertEqual(esito.restored.count, 2)
        XCTAssertEqual(esito.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.jpg").path))
    }

    /// Ogni motivo di scarto ha una spiegazione **diversa** e comprensibile: se due motivi
    /// condividessero la stessa frase, il test sarebbe cieco proprio sul testo che l'utente
    /// legge per capire cosa non e' tornato al suo posto.
    func testEverySkipReason_hasItsOwnPlainExplanation() {
        let reasons: [RestoreSkipReason] = [.missingInTrash, .alteredInTrash, .originalPathOccupied,
                                            .unreadableInTrash, .outsideLibrary]
        let frasi = reasons.map(\.explanation)
        XCTAssertEqual(Set(frasi).count, reasons.count, "due motivi condividono la stessa frase: \(frasi)")
        for frase in frasi {
            XCTAssertFalse(frase.isEmpty)
            for parola in ["hash", "SHA256", "indice", "manifest"] {
                XCTAssertFalse(frase.lowercased().contains(parola.lowercased()), "gergo in «\(frase)»")
            }
        }
    }

    // MARK: - Il registro ricorda cosa e' tornato a posto (Task 3, ADR-0009)

    /// Un registro scritto dalla forma di OGGI (sette chiavi, nessun `restoredAt`) si
    /// decodifica con `restoredAt == nil`: e' il JSON letterale, non generato dal tipo
    /// nuovo, altrimenti il test proverebbe il tipo nuovo contro se stesso.
    func testRecordWrittenByTheCurrentVersion_decodesWithoutRestoredAt() throws {
        let vecchio = """
        {"totalRecorded":1,"items":[{"batchId":"b1","originalDisplayPath":"/x/a.jpg",\
        "originalKey":"a.jpg","trashedPath":"/x/.Trashes/a.jpg","size":4,"hash":"abc",\
        "trashedAt":770000000}]}
        """
        try vecchio.write(to: manifestURL, atomically: true, encoding: .utf8)

        let store = try TrashManifestStore(url: manifestURL)
        XCTAssertEqual(store.lastBatch().first?.restoredAt, nil)
    }

    func testMarkRestored_isOnDiskImmediately() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        try store.record(it)

        try store.markRestored(it, at: Date())

        let riletto = try TrashManifestStore(url: manifestURL)
        XCTAssertNotNil(riletto.lastBatch().first?.restoredAt)
    }

    func testPendingInLastBatch_excludesRestoredItems() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let uno = try makeTrashedFile("uno.jpg", contents: "1")
        let due = try makeTrashedFile("due.jpg", contents: "2")
        let itUno = try item(trashed: uno, originalAt: root.appendingPathComponent("uno.jpg"))
        let itDue = try item(trashed: due, originalAt: root.appendingPathComponent("due.jpg"))
        try store.record(itUno)
        try store.record(itDue)

        try store.markRestored(itUno, at: Date())

        let pending = store.pendingInLastBatch()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.trashedPath, due.path)
    }

    /// Due blocchi possono condividere lo stesso `originalDisplayPath` (lo stesso file
    /// cestinato, rimesso a posto, e ricestinato): marcare la voce del blocco NUOVO non deve
    /// toccare quella del VECCHIO. L'identita' e' `batchId` + `trashedPath` +
    /// `originalDisplayPath`, mai il solo percorso originale. Verificato leggendo il JSON
    /// grezzo: l'API pubblica espone solo l'ultimo blocco, e qui serve controllare anche
    /// quello vecchio.
    func testMarkRestored_matchesByIdentity_notByOriginalPathAlone() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let vecchio = try makeTrashedFile("vecchio.jpg", contents: "v")
        let original = root.appendingPathComponent("a.jpg")
        let itVecchio = try item(trashed: vecchio, originalAt: original, batch: "b1")
        try store.record(itVecchio)

        let nuovo = try makeTrashedFile("nuovo.jpg", contents: "n")
        let itNuovo = try item(trashed: nuovo, originalAt: original, batch: "b2")
        try store.record(itNuovo)

        try store.markRestored(itNuovo, at: Date())

        let raw = try String(contentsOf: manifestURL, encoding: .utf8)
        let decoded = try JSONDecoder().decode(TrashManifest.self, from: Data(raw.utf8))
        let vecchiaVoce = try XCTUnwrap(decoded.items.first(where: { $0.batchId == "b1" }))
        let nuovaVoce = try XCTUnwrap(decoded.items.first(where: { $0.batchId == "b2" }))
        XCTAssertNil(vecchiaVoce.restoredAt, "marcare la voce nuova ha toccato anche quella vecchia")
        XCTAssertNotNil(nuovaVoce.restoredAt)
    }

    func testRestorableSummary_isNilWhenTheLastBatchIsFullyRestored() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        try store.record(it)

        XCTAssertNotNil(store.restorableSummary())
        try store.markRestored(it, at: Date())
        XCTAssertNil(store.restorableSummary())
    }

    func testRestorableSummary_countsOnlyPendingItems() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let uno = try makeTrashedFile("uno.jpg", contents: "1")
        let due = try makeTrashedFile("due.jpg", contents: "2")
        let itUno = try item(trashed: uno, originalAt: root.appendingPathComponent("uno.jpg"))
        let itDue = try item(trashed: due, originalAt: root.appendingPathComponent("due.jpg"))
        try store.record(itUno)
        try store.record(itDue)
        try store.markRestored(itUno, at: Date())

        let summary = try XCTUnwrap(store.restorableSummary())
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.batchCount, 2)
    }

    /// Una voce con `trashedPath` vuoto non era ripristinabile (non e' mai stata spostata
    /// davvero dal Cestino): non si marca mai, anche se qualcuno la passasse per errore.
    func testMarkRestored_ignoresItemsWithEmptyTrashedPath() throws {
        let store = try TrashManifestStore(url: manifestURL)
        var it = try item(trashed: try makeTrashedFile("a.jpg", contents: "foto"),
                          originalAt: root.appendingPathComponent("a.jpg"))
        it.trashedPath = ""
        try store.record(it)

        try store.markRestored(it, at: Date())
        XCTAssertNil(store.lastBatch().first?.restoredAt)
    }

    // MARK: - Persistenza

    /// **Fatto misurato n. 5 di #31**: i default sulle proprieta' non li usa la decodifica
    /// sintetizzata, che lancia `keyNotFound`. Un campo aggiunto in una versione futura
    /// farebbe sparire in silenzio l'intero registro — cioe' proprio la rete di sicurezza.
    func testOldRecordWithoutNewField_stillDecodes() throws {
        let vecchio = """
        {"totalRecorded":1,"items":[{"batchId":"b1","originalDisplayPath":"/x/a.jpg",\
        "trashedPath":"/x/.Trashes/a.jpg","size":4,"hash":"abc","trashedAt":770000000}]}
        """
        try vecchio.write(to: manifestURL, atomically: true, encoding: .utf8)

        let store = try TrashManifestStore(url: manifestURL)
        let items = store.lastBatch()
        XCTAssertEqual(items.count, 1, "un campo mancante ha fatto sparire tutto il registro")
        XCTAssertEqual(items.first?.hash, "abc")
        XCTAssertEqual(items.first?.originalKey, "", "il campo assente deve degradare, non far fallire")
    }

    func testGarbageManifest_startsEmptyInsteadOfCrashing() throws {
        try "non sono JSON".write(to: manifestURL, atomically: true, encoding: .utf8)
        let store = try TrashManifestStore(url: manifestURL)
        XCTAssertTrue(store.lastBatch().isEmpty)

        // E resta usabile: un registro illeggibile non deve bloccare l'annullamento futuro.
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        try store.record(try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg")))
        XCTAssertEqual(try TrashManifestStore(url: manifestURL).lastBatch().count, 1)
    }

    /// Il tetto tiene la lista corta, e `totalRecorded` resta veritiero a lista troncata —
    /// stessa forma di `UnverifiedCopies.totalCount`, per lo stesso motivo: il numero
    /// mostrato non puo' essere `items.count` quando la lista e' stata potata.
    func testCap_keepsTheNewestAndKeepsTheTotalTruthful() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let quante = TrashManifestStore.maxItems + 5
        for i in 0..<quante {
            var it = try item(trashed: trashed, originalAt: root.appendingPathComponent("f\(i).jpg"))
            it.batchId = "b\(i)"
            try store.record(it)
        }
        let riletto = try TrashManifestStore(url: manifestURL)
        XCTAssertEqual(riletto.totalRecorded, quante)
        XCTAssertEqual(riletto.itemCount, TrashManifestStore.maxItems)
        XCTAssertEqual(riletto.lastBatch().first?.batchId, "b\(quante - 1)",
                       "il tetto ha buttato via le voci piu' recenti invece delle piu' vecchie")
    }

    /// Il registro sta sul disco interno, **mai** sull'SSD: quello e' la sorgente, e si
    /// tratta in sola lettura. Allow-list condivisa con `LibraryIndexStore`, non riscritta.
    ///
    /// **La posizione deve essere scrivibile davvero**, ed e' il punto del test. La prima
    /// versione usava `/Volumes/SSD - Enri/…`: con l'SSD scollegato l'init falliva comunque,
    /// quindi `XCTAssertThrowsError` era verde **anche senza la guardia** — misurato il
    /// 2026-08-29, il mutante che cancella `isAllowedStoreLocation` sopravviveva a tutti e
    /// 18 i test. Qui la cartella esiste, e senza la guardia il registro ci verrebbe creato.
    /// Per la stessa ragione si pretende **quale** errore: un `throws` qualsiasi non
    /// distingue «rifiutato dalla regola» da «fallito per caso».
    func testManifestLocation_isRefusedOutsideAppSupport() throws {
        let fuori = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/AppBackupFotoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fuori, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fuori) }

        let dentroLaCartellaSbagliata = fuori.appendingPathComponent("trash-manifest.json")
        XCTAssertThrowsError(try TrashManifestStore(url: dentroLaCartellaSbagliata)) { errore in
            guard case TrashManifestStore.StoreError.invalidLocation = errore else {
                return XCTFail("rifiutato per un motivo diverso dalla allow-list: \(errore)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dentroLaCartellaSbagliata.path),
                       "ha creato il registro fuori dalle posizioni consentite")
    }

    /// Il registro contiene i **percorsi** delle foto dell'utente in chiaro: `0600`, come
    /// l'indice. Verificato **dopo** un ciclo completo scrittura/riapertura, perche' e' la
    /// riscrittura a poter riportare i permessi di default.
    func testManifestFile_is0600AfterAFullCycle() throws {
        // Auto-skip se l'umask del processo di test e' gia' restrittiva: altrimenti il test
        // sarebbe verde senza dimostrare niente.
        let sonda = root.appendingPathComponent("sonda")
        try "x".write(to: sonda, atomically: true, encoding: .utf8)
        let sondaPerms = try FileManager.default.attributesOfItem(atPath: sonda.path)[.posixPermissions] as? Int ?? 0
        try XCTSkipIf(sondaPerms & 0o077 == 0, "umask gia' restrittiva: il test non proverebbe niente")

        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        try store.record(try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg")))
        _ = try TrashManifestStore(url: manifestURL)

        let perms = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(perms & 0o077, 0, "permessi \(String(perms, radix: 8))")
    }

    /// Ripristinare due volte la stessa voce non ripristina due volte, e la seconda dice il
    /// VERO: la foto e' gia' al suo posto (riconciliazione D3, ADR-0009) — non piu' «il
    /// Cestino e' stato svuotato», che sarebbe falso qui.
    func testRestoringTwice_isNotAnError() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let trashed = try makeTrashedFile("a.jpg", contents: "foto")
        let it = try item(trashed: trashed, originalAt: root.appendingPathComponent("a.jpg"))
        try store.record(it)

        XCTAssertEqual(restore([it], via: store).restored.count, 1)
        let seconda = restore([it], via: store)
        XCTAssertEqual(seconda.alreadyInPlace.count, 1)
        XCTAssertTrue(seconda.skipped.isEmpty)
    }

    /// Un ripristino non tocca il registro delle **altre** voci: annullare un blocco non
    /// deve far sparire la possibilita' di annullarne un altro.
    func testRestore_doesNotDropTheOtherBatchesFromTheRegister() throws {
        let store = try TrashManifestStore(url: manifestURL)
        let vecchia = try makeTrashedFile("vecchia.jpg", contents: "v")
        let nuova = try makeTrashedFile("nuova.jpg", contents: "n")
        let itVecchia = try item(trashed: vecchia, originalAt: root.appendingPathComponent("vecchia.jpg"), batch: "b1")
        let itNuova = try item(trashed: nuova, originalAt: root.appendingPathComponent("nuova.jpg"), batch: "b2")
        try store.record(itVecchia)
        try store.record(itNuova)

        _ = restore([itNuova], via: store)
        XCTAssertEqual(try TrashManifestStore(url: manifestURL).itemCount, 2)
    }
}
