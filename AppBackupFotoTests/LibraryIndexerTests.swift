import XCTest
@testable import AppBackupFoto

final class LibraryIndexerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var store: LibraryIndexStore!
    private var indexer: LibraryIndexer!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexerTests-\(UUID().uuidString)")
        root = tempDir.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        indexer = LibraryIndexer(store: store)
    }

    override func tearDownWithError() throws {
        indexer = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// mtime fisso e ben nel passato per i file di prova. NON e' un aggiustamento
    /// per far passare i test: e' la condizione reale della libreria. Un file appena
    /// creato e hashato nello stesso istante ricade nella regola anti-racy di
    /// `indexEntryVerdict` (git/borg): `currentMTime >= hashedAt - 2s` produce
    /// `.needsVerification`, cioe' un rehash, ed e' il comportamento voluto — una
    /// scrittura potrebbe essere avvenuta subito dopo la lettura a parita' di mtime.
    /// Sull'SSD i file sono stati copiati molto prima della scansione, quindi senza
    /// questa data i test misurerebbero solo il caso racy e non verificherebbero mai
    /// il riuso incrementale dell'hash, che e' cio' che devono coprire.
    private static let fixtureMTime = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    private func makeFile(_ relative: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureMTime],
                                              ofItemAtPath: url.path)
        return url
    }

    func testIndexesImagesAndVideos() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/b.mov", contents: "due")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 2)
        XCTAssertEqual(try store.count(), 2)
    }

    func testIgnoresNonIndexableFiles() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Zip/archivio.zip", contents: "grosso")
        try makeFile("Foto/a.xmp", contents: "sidecar")
        try makeFile("Takeout/meta.json", contents: "{}")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1, "solo a.jpg deve entrare nell'indice")
        XCTAssertEqual(try store.count(), 1)
    }

    func testSecondScanReusesStoredHashes() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let second = try indexer.scan(root: root)
        XCTAssertEqual(second.hashed, 0, "nulla e' cambiato: nessun rehash")
        XCTAssertEqual(second.skipped, 1)
    }

    func testChangedFileIsRehashed() throws {
        let url = try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let before = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash

        // Cambia contenuto E mtime, ben oltre il margine racy.
        try "contenuto completamente diverso".data(using: .utf8)!.write(to: url)
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

        let second = try indexer.scan(root: root)
        XCTAssertEqual(second.hashed, 1)
        XCTAssertNotEqual(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash, before)
    }

    func testDeletedFileIsRemovedFromIndex() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/b.jpg", contents: "due")
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/b.jpg"))
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 1, "le entry di file spariti vanno rimosse")
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/b.jpg")))
    }

    func testIdenticalContentProducesSameHash() throws {
        try makeFile("Foto/a.jpg", contents: "identico")
        try makeFile("Import/copia.jpg", contents: "identico")
        _ = try indexer.scan(root: root)
        let a = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!
        XCTAssertEqual(try store.entries(withHash: a.hash).count, 2)
    }

    func testExcludesSystemFiles() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/.DS_Store", contents: "junk")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1)
    }

    func testProgressIsReported() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        var reports: [LibraryIndexer.Progress] = []
        _ = try indexer.scan(root: root, batchSize: 2) { reports.append($0) }
        XCTAssertFalse(reports.isEmpty, "il progresso deve essere riportato durante la scansione")
        XCTAssertEqual(reports.last?.hashed, 5)
    }

    // Cancellazione DURANTE la scansione: e' il flusso reale (l'utente preme
    // "Interrompi" mentre il lavoro gira). Un `cancel()` PRIMA di `scan()` non e' un
    // caso reale ed e' volutamente ignorato, perche' `scan` riparte pulita.
    func testCancelDuringScan_stopsEarly() throws {
        for i in 0..<50 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        let p = try idx.scan(root: root, batchSize: 5) { _ in idx.cancel() }
        XCTAssertLessThan(p.hashed, 50, "la cancellazione deve fermare la scansione")
        XCTAssertGreaterThan(try store.count(), 0, "cio' che era gia' stato committato resta")
    }

    // Il bug che questo test blocca: `cancelled` non veniva mai rimesso a false, quindi
    // dopo UNA cancellazione l'istanza non avrebbe indicizzato mai piu' nulla, e la
    // rimozione dei file spariti non sarebbe piu' girata. Con `LibraryIndexer` come
    // @StateObject della finestra (Task 6) il sintomo e' "l'indice ha smesso di
    // aggiornarsi finche' non riavvio l'app".
    func testScanAfterCancel_worksAgain() throws {
        for i in 0..<20 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        _ = try idx.scan(root: root, batchSize: 2) { _ in idx.cancel() }
        XCTAssertLessThan(try store.count(), 20, "la prima scansione e' stata interrotta")

        let second = try idx.scan(root: root)
        XCTAssertEqual(try store.count(), 20, "la seconda scansione deve completare l'indice")
        XCTAssertEqual(second.errors, 0)
    }

    func testPartialIndexAfterCancelIsStillUsable() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        _ = try idx.scan(root: root, batchSize: 2) { _ in idx.cancel() }
        // Un indice parziale deve essere leggibile e coerente, mai a meta' riga.
        let count = try store.count()
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 10)
        XCTAssertNoThrow(try store.allKeys())
        XCTAssertEqual(try store.allKeys().count, count)
    }

    // Guardia di plausibilita' (Q3). Una scansione che vede sparire piu' della meta'
    // dell'indice e' quasi sempre un'interruzione non riconosciuta: nel dubbio si
    // tiene l'indice, perche' svuotarlo costa una ricostruzione da 5-15 minuti e
    // lascia l'import successivo senza dedup.
    func testMassiveDisappearance_keepsIndex() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        for i in 0..<8 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10, "sparizione implausibile: l'indice si tiene")
    }

    // ...ma una cancellazione normale viene applicata, altrimenti l'indice non si
    // pulirebbe mai. (Copre anche il confine: 5 su 10 e' ancora plausibile.)
    func testHalfDisappearance_isStillApplied() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        for i in 0..<5 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 5)
    }

    // La guardia non deve scattare in silenzio: il numero va riportato, altrimenti
    // dopo una riorganizzazione legittima scatterebbe a ogni avvio senza che nessuno
    // se ne accorga.
    func testPlausibilityGuard_reportsWhatItKept() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        for i in 0..<8 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.vanishedKept, 8, "la guardia deve dire QUANTE entry ha tenuto")
        XCTAssertEqual(try store.count(), 10)
    }

    func testPlausibilityGuard_reportsZeroWhenItDoesNotTrip() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f0.jpg"))
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.vanishedKept, 0)
        XCTAssertEqual(try store.count(), 9)
    }

    // Cambio di fuso: l'mtime si sposta di un'ora esatta ma il contenuto no.
    // Deve adottare il nuovo mtime SENZA rihashare — e' l'unico effetto reale
    // della regola DST, senza il quale rihasheremmo tutto due volte l'anno.
    func testTimezoneShift_adoptsMTimeWithoutRehashing() throws {
        let url = try makeFile("Foto/a.jpg", contents: "contenuto")
        _ = try indexer.scan(root: root)
        let before = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!

        // Sposta SOLO l'mtime di un'ora esatta, lasciando il contenuto intatto.
        let shifted = Date(timeIntervalSince1970: before.mtime + 3600)
        try FileManager.default.setAttributes([.modificationDate: shifted],
                                              ofItemAtPath: url.path)

        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 0, "un cambio di fuso non deve far rihashare")
        XCTAssertEqual(p.rebasedByTimezone, 1)

        let after = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!
        XCTAssertEqual(after.hash, before.hash, "l'hash resta quello gia' calcolato")
        XCTAssertEqual(after.mtime, before.mtime + 3600, accuracy: 0.05,
                       "il nuovo mtime va adottato, altrimenti si ricade qui a ogni scansione")

        // La scansione successiva deve trovarlo .fresh: se l'mtime non fosse stato
        // adottato, ogni scansione ripeterebbe il rebase all'infinito.
        let third = try indexer.scan(root: root)
        XCTAssertEqual(third.rebasedByTimezone, 0)
        XCTAssertEqual(third.skipped, 1)
    }

    // La via d'uscita: dopo una cancellazione massiccia VERA, la "Ricostruzione
    // completa" scavalca la guardia e ripulisce le entry fantasma.
    func testFullRebuild_bypassesPlausibilityGuard() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        for i in 0..<8 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10, "la scansione normale si tiene tutto")

        _ = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertEqual(try store.count(), 2, "la ricostruzione completa ripulisce")
    }

    // Modalita' "verifica completa": non fidarsi di nulla di memorizzato.
    func testIgnoringStoredHashes_rehashesEverything() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let normal = try indexer.scan(root: root)
        XCTAssertEqual(normal.hashed, 0, "scansione normale: riusa l'hash memorizzato")

        let full = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertEqual(full.hashed, 1, "verifica completa: rihasha comunque")
        XCTAssertEqual(full.skipped, 0)
    }

    // Root assente all'INIZIO (SSD scollegato prima di partire): le entry gia'
    // indicizzate non vanno scambiate per file cancellati.
    // NB: questo test NON copre lo scollegamento a meta' scansione — la root sparisce
    // prima che `scan` cominci, quindi scatta la `guard` in cima. Il caso "a meta'"
    // e' coperto dal controllo dopo il ciclo piu' dalla guardia di plausibilita'
    // (`testMassiveDisappearance_keepsIndex`), perche' non e' simulabile in modo
    // deterministico da un test: dipende da quando l'enumeratore smette di produrre.
    func testRootAbsentAtStart_doesNotWipeIndex() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        // Simula lo scollegamento: la root sparisce.
        try FileManager.default.removeItem(at: root)
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10,
                       "root assente non significa 'tutti i file cancellati': l'indice resta")
    }

    // Regressione (bug reale, 2026-08-26). La chiave deve dipendere SOLO dal percorso
    // relativo alla root, mai dalla forma testuale con cui la root viene passata.
    // Il bug: il relativo era calcolato con `dropFirst(root.path.count)`, ma
    // l'enumeratore restituisce la forma con i symlink risolti (`/private/var/...`)
    // mentre la root arrivava come `/var/...` — otto caratteri di differenza. Le chiavi
    // uscivano deformate (`40CC/SSD/Foto/a.jpg`) ma coerenti dentro la singola
    // scansione, quindi i conteggi tornavano e solo la rilettura per chiave falliva.
    // Sul volume reale (`/Volumes/SSD - Enri`, che non e' un symlink) non si sarebbe
    // visto: e' proprio per questo che serve un test che vari la forma della root.
    func testKeysAreRelativeToRootWhateverItsPathForm() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)

        let key = normalizedIndexKey("Foto/a.jpg")
        XCTAssertNotNil(try store.entry(forKey: key),
                        "la chiave deve essere il percorso relativo, non un pezzo di percorso assoluto")
        XCTAssertEqual(try store.allKeys(), [key])

        // Stessa directory, scritta in forme diverse: con i symlink risolti, con lo
        // slash finale, con un segmento `.` di mezzo. Se una sola forma producesse
        // chiavi diverse, ogni scansione duplicherebbe l'intero indice.
        var variants = [URL(fileURLWithPath: root.path + "/"),
                        URL(fileURLWithPath: root.path + "/./")]
        let resolved = root.resolvingSymlinksInPath()
        if resolved.path != root.path { variants.append(resolved) }
        if FileManager.default.fileExists(atPath: "/private" + root.path) {
            variants.append(URL(fileURLWithPath: "/private" + root.path))
        }
        XCTAssertGreaterThanOrEqual(variants.count, 3, "il caso col symlink deve essere coperto")

        for variant in variants {
            let p = try indexer.scan(root: variant)
            XCTAssertEqual(p.scanned, 1, "root come \(variant.path): il file va comunque visto")
            XCTAssertEqual(p.skipped, 1, "root come \(variant.path): stessa chiave, hash riusato")
            XCTAssertEqual(try store.allKeys(), [key], "root come \(variant.path): nessuna chiave nuova")
            XCTAssertEqual(try store.count(), 1)
        }
    }
}
