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
        XCTAssertFalse(p.traversalIncomplete, "traversata regolare: nessun segnale di incompletezza")
        XCTAssertEqual(p.unreadableItems, 0)
        XCTAssertEqual(p.outsideRoot, 0)
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
    // "Interrompi" mentre il lavoro gira). Il caso "cancel PRIMA di scan" e' coperto
    // da `testCancelBeforeScan_isHonored`: dal 2026-08-26 non viene piu' inghiottito.
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

    // Interruzione con l'indice GIA' POPOLATO. I tre test di cancellazione qui sopra
    // partono tutti da indice vuoto, quindi l'insieme delle chiavi sparite e' sempre
    // vuoto e la riga che decide la rimozione non veniva mai raggiunta: rimuovendo il
    // guard `!cancelled &&` la suite restava verde.
    //
    // Effetto reale del buco, misurato il 2026-08-26: indice da 40 entry, Ricostruzione
    // completa interrotta dopo 4 file -> `store.count()` 40 -> 4, `vanishedKept=0`,
    // nessun segnale. Sul volume vero sono ~110.000 entry cancellate da un click su
    // Interrompi. `ignoringStoredHashes: true` isola il caso: scavalca la guardia di
    // plausibilita', quindi l'unica cosa che impedisce la rimozione e' il fatto che una
    // scansione interrotta conta come traversata INCOMPLETA.
    func testCancelDuringFullRebuild_removesNothing() throws {
        for i in 0..<40 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 40)

        let idx = indexer!
        let p = try idx.scan(root: root, batchSize: 4, ignoringStoredHashes: true) { _ in idx.cancel() }

        XCTAssertTrue(p.traversalIncomplete,
                      "una scansione interrotta dall'utente NON e' una traversata completa")
        XCTAssertGreaterThan(p.vanishedKept, 0,
                             "le entry non viste per via dell'interruzione vanno riportate, non rimosse")
        XCTAssertEqual(try store.count(), 40,
                       "Interrompi non deve svuotare l'indice: sul volume vero sarebbero ~110.000 entry")
    }

    // Root che sparisce (qui: rinominata) MENTRE la scansione gira. Deterministico:
    // `batchSize: 1` fa scattare `onProgress` dopo il primo file, e da li' la root non
    // esiste piu' al percorso da cui si era partiti. Non monta niente, non dipende dal
    // timing — la nota che diceva "non simulabile in modo deterministico" era sbagliata.
    //
    // In questo scenario l'`errorHandler` dell'enumeratore **non viene chiamato**
    // (misurato: `unreadableItems=0`): i fallimenti di lettura finiscono in
    // `progress.errors`, che NON concorre a `traversalIncomplete`. Quindi qui il
    // confronto `st_dev` inizio/fine non e' "la seconda cintura", e' l'**unica**: senza
    // di lui la scansione dichiarerebbe una traversata completa, ed e' quella
    // dichiarazione che autorizza la rimozione delle entry non viste e che il Task 6
    // mostra all'utente. Verificato: togliendo entrambi i controlli `st_dev` questo test
    // fallisce; togliendone uno solo no, perche' sono ridondanti fra loro (vedi il
    // commento accanto al codice).
    //
    // E' anche l'unico test che asserisce `Progress.volumeVanished`, mai asserito prima.
    func testRootRenamedDuringScan_isReportedAsIncompleteTraversal() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        let moved = tempDir.appendingPathComponent("SSD-scollegato")
        let original = root!
        var renamed = false
        let p = try indexer.scan(root: root, batchSize: 1, ignoringStoredHashes: true) { _ in
            guard !renamed else { return }
            renamed = true
            try? FileManager.default.moveItem(at: original, to: moved)
        }

        XCTAssertTrue(renamed, "la rinomina deve essere avvenuta durante la scansione")
        XCTAssertEqual(p.unreadableItems, 0,
                       "qui l'errorHandler NON viene chiamato: e' il motivo per cui st_dev e' l'unica difesa")
        XCTAssertTrue(p.volumeVanished, "la root non e' piu' quella di partenza: va rilevato")
        XCTAssertTrue(p.traversalIncomplete)
        XCTAssertEqual(try store.count(), 10,
                       "traversata troncata: nessuna rimozione, nemmeno in Ricostruzione completa")
        XCTAssertEqual(p.vanishedKept, 9, "le 9 entry non viste vanno riportate, non rimosse")
        // Misura completa, con e senza il fix (2026-08-26). Con `st_dev`:
        // `scanned=1 errors=0 unreadableItems=0 traversalIncomplete=true volumeVanished=true
        //  vanishedKept=9` — la scansione si ferma al primo controllo del batch e dice la
        // verita'. Togliendo ENTRAMBI i controlli `st_dev`:
        // `scanned=10 errors=9 unreadableItems=0 traversalIncomplete=FALSE vanishedKept=0`,
        // cioe' 9 file su 10 illeggibili e la scansione che dichiara comunque una
        // traversata completa. Li' l'indice non si svuota solo perche' le chiavi entrano
        // in `seenKeys` prima del tentativo di lettura: basterebbe che uno di quei file
        // fosse davvero sparito per rimuoverlo sulla base di una traversata mai finita.
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
    // NB: questo test NON copre la sparizione a meta' scansione — la root sparisce prima
    // che `scan` cominci, quindi scatta la `guard` in cima. Il caso "a meta'" e' coperto
    // da `testRootRenamedDuringScan_removesNothing`.
    //
    // CORREZIONE (2026-08-26): qui c'era scritto che quel caso "non e' simulabile in modo
    // deterministico da un test". Era falso, e ha lasciato scoperto per un giro intero il
    // controllo su `st_dev`: rinominare la root da dentro `onProgress` con `batchSize: 1`
    // lo riproduce senza montare niente e senza dipendere da nessun timing.
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
    // MARK: - Rilievi chiusi dopo la review del Task 4 (2026-08-26)

    // Le esclusioni non erano esercitate da nessun test: `shouldExclude` forzata a
    // `false` sopravviveva al mutation test, perche' `Foto/.DS_Store` e' gia' coperto
    // tre volte da `.skipsHiddenFiles`. Questi due nomi NON iniziano con un punto:
    // sono l'unica parte della lista che solo `LibraryExclusions` puo' fermare.
    func testExcludedSystemFolders_areNotIndexed() throws {
        try makeFile("Foto/ok.jpg", contents: "buona")
        try makeFile("lost+found/x.jpg", contents: "recuperata")
        try makeFile("Backups.backupdb/y.jpg", contents: "time machine")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1, "solo Foto/ok.jpg")
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/ok.jpg")])
    }

    // `.skipsHiddenFiles` e' meta' del filtro, non un dettaglio di performance: senza,
    // l'indice diventa un superset di cio' che FileSyncer copia davvero e una copia
    // nascosta byte-identica farebbe saltare un import reale (ADR-0003 + commento su
    // `LibraryExclusions`). Toglierla sopravviveva a tutti i 20 test precedenti.
    func testHiddenFilesAndFolders_areNotIndexed() throws {
        try makeFile("Foto/ok.jpg", contents: "buona")
        try makeFile("Foto/.nascosta.jpg", contents: "nascosta")
        try makeFile(".Cartella/dentro.jpg", contents: "dentro")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1, "ne' il file nascosto ne' la cartella nascosta entrano nell'indice")
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/ok.jpg")])
    }

    // La regola anti-racy di ADR-0003 non era esercitata a livello di indexer:
    // trattare `.needsVerification` come `.fresh` sopravviveva. E' il caso che ADR-0003
    // chiama "il file potrebbe davvero essere cambiato": contenuto diverso, dimensione
    // identica al byte, mtime identico.
    //
    // L'mtime dei fixture e' volutamente nel FUTURO (+60s) e non "adesso": serve
    // `currentMTime >= hashedAt - 2s`, e con "adesso" il test dipenderebbe dal fatto
    // che la scansione parta entro 2 secondi dalla creazione del file — cioe' sarebbe
    // un test a tempo. Con +60s la condizione vale su qualunque macchina.
    func testNeedsVerification_isRehashedNotTrusted() throws {
        let url = try makeFile("Foto/a.jpg", contents: "uno")
        let racyMTime = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: racyMTime], ofItemAtPath: url.path)
        _ = try indexer.scan(root: root)
        let before = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!

        // Contenuto diverso, STESSA dimensione (3 byte), STESSO mtime.
        try "due".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: racyMTime], ofItemAtPath: url.path)

        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1, "nel dubbio si rihasha: e' la regola anti-racy")
        XCTAssertEqual(p.skipped, 0)
        let after = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!
        XCTAssertEqual(after.size, before.size, "la dimensione e' identica: e' proprio il caso ambiguo")
        XCTAssertNotEqual(after.hash, before.hash, "l'hash vecchio non doveva essere confermato")
    }

    // Un file che esiste ma non si riesce a leggere NON e' un file sparito: la sua
    // entry resta. Mutante che sopravviveva: `seenKeys.remove(key)` nel ramo di errore
    // dell'hash — l'entry di un file esistente spariva e nessuno se ne accorgeva.
    func testUnreadableFile_keepsItsEntry() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        let url = try makeFile("Foto/b.jpg", contents: "due")
        _ = try indexer.scan(root: root)
        let before = try store.entry(forKey: normalizedIndexKey("Foto/b.jpg"))!

        // Il file cambia (quindi andrebbe rihashato) e diventa illeggibile.
        try "contenuto molto piu' lungo di prima".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(300)],
                                              ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.errors, 1)
        XCTAssertEqual(try store.count(), 2, "un file illeggibile non e' un file sparito")
        XCTAssertEqual(p.vanishedKept, 0, "non c'e' nulla da tenere: la chiave e' stata vista")
        XCTAssertEqual(try store.entry(forKey: normalizedIndexKey("Foto/b.jpg"))?.hash, before.hash,
                       "resta l'hash vecchio: e' il comportamento voluto, coperto dalla rilettura di ADR-0003")
    }

    // Lettura troncata. Deterministico, nessun timing: `batchSize: 1` fa scattare
    // `onProgress` dopo il primo file, e da li' si troncano tutti gli altri. La
    // dimensione che l'enumeratore ha gia' messo in cache resta 5000, quindi la vecchia
    // difesa ("rileggi fileSizeKey dallo stesso url e confronta") era vera per
    // costruzione e non poteva scattare: le entry finivano nell'indice con size=5000 e
    // l'hash di 6 byte. Quell'hash decide se saltare un file in import.
    func testTruncatedRead_isNotIndexed() throws {
        let payload = String(repeating: "A", count: 5000)
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: payload) }

        let p = try indexer.scan(root: root, batchSize: 1) { [root] _ in
            for i in 0..<10 {
                let u = root!.appendingPathComponent("Foto/f\(i).jpg")
                let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
                guard (attrs?[.size] as? Int) == 5000,
                      let fh = try? FileHandle(forWritingTo: u) else { continue }
                try? fh.truncate(atOffset: 6)
                try? fh.close()
            }
        }

        XCTAssertEqual(p.hashed, 1, "solo il primo file e' stato letto integro")
        XCTAssertEqual(p.errors, 9, "i nove troncati non devono entrare nell'indice")
        XCTAssertEqual(try store.count(), 1)

        let fullHash = try hashOfString(payload)
        let truncatedHash = try hashOfString("AAAAAA")
        let key = try XCTUnwrap(store.allKeys().first)
        let entry = try XCTUnwrap(store.entry(forKey: key))
        XCTAssertEqual(entry.size, 5000)
        XCTAssertEqual(entry.hash, fullHash, "l'unica entry deve avere l'hash del contenuto intero")
        XCTAssertTrue(try store.entries(withHash: truncatedHash).isEmpty,
                      "nessuna entry deve portare l'hash del contenuto troncato con la dimensione intera")
    }

    // Cartella illeggibile: la traversata non e' completa, quindi NON si rimuove nulla
    // e il numero di elementi non letti va riportato. Misurato prima del fix: 3 entry
    // di file esistenti rimosse, `errors=0`, nessun segnale — la guardia di
    // plausibilita' non protegge, perche' 3 su 6 e' esattamente "plausibile".
    func testUnreadableDirectory_removesNothing() throws {
        for i in 0..<3 { try makeFile("Foto/v\(i).jpg", contents: "v\(i)") }
        for i in 0..<3 { try makeFile("Foto/segreta/s\(i).jpg", contents: "s\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 6)

        let secret = root.appendingPathComponent("Foto/segreta")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.unreadableItems, 1, "l'errorHandler deve contare la cartella non aperta")
        XCTAssertTrue(p.traversalIncomplete)
        XCTAssertEqual(p.vanishedKept, 3, "le 3 entry non viste vanno riportate, non rimosse")
        XCTAssertEqual(try store.count(), 6, "una cartella illeggibile non e' una cartella svuotata")
    }

    // "Enumerazione a zero file" non e' "libreria vuota". Misurato prima del fix:
    // `scanned=0`, nessun errore, indice azzerato.
    // `ignoringStoredHashes: true` isola il caso: scavalca la guardia di plausibilita',
    // quindi l'unica cosa che impedisce di azzerare l'indice e' questa regola.
    func testZeroFilesScanned_removesNothing() throws {
        for i in 0..<3 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 3)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto"))
        try makeFile("Zip/archivio.zip", contents: "non indicizzabile")

        let p = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertEqual(p.scanned, 0)
        XCTAssertEqual(p.unreadableItems, 0, "nessun errore di traversata: e' proprio il caso ambiguo")
        XCTAssertTrue(p.traversalIncomplete)
        XCTAssertEqual(p.vanishedKept, 3)
        XCTAssertEqual(try store.count(), 3, "zero file visti non autorizza nessuna rimozione")
    }

    // DECISIONE DI PRODOTTO (Enrico, 2026-08-26): se la traversata non e' completa non
    // si rimuove nulla NEMMENO in "Ricostruzione completa". E' la modalita' che dura
    // 5-15 minuti sul volume vero, cioe' quella con la probabilita' piu' alta di essere
    // interrotta da uno scollegamento; prima la guardia era disattivata del tutto qui
    // (`plausible = ignoringStoredHashes || ...`) e uno stacco a meta' cancellava
    // 12.220 entry. Righe stantie sono innocue (l'import rilegge e rihasha comunque,
    // ADR-0003); righe cancellate per errore costano dedup spento, doppioni ricreati e
    // una ricostruzione da 5-15 minuti.
    func testFullRebuildWithIncompleteTraversal_removesNothing() throws {
        for i in 0..<5 { try makeFile("Foto/v\(i).jpg", contents: "v\(i)") }
        for i in 0..<5 { try makeFile("Foto/segreta/s\(i).jpg", contents: "s\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        let secret = root.appendingPathComponent("Foto/segreta")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        let p = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertTrue(p.traversalIncomplete)
        XCTAssertEqual(p.unreadableItems, 1)
        XCTAssertEqual(p.vanishedKept, 5)
        XCTAssertEqual(try store.count(), 10,
                       "la ricostruzione completa scavalca la plausibilita', MAI la traversata incompleta")
    }

    // Un `cancel()` arrivato fra il click e l'ingresso in `scan` sul thread di lavoro
    // veniva inghiottito dall'azzeramento in cima a `scan`. Ora la cancellazione si
    // consuma in uscita: viene rispettata, e la scansione successiva riparte pulita.
    func testCancelBeforeScan_isHonored() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        indexer.cancel()

        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 0, "un cancel arrivato prima che scan parta non va inghiottito")
        XCTAssertEqual(try store.count(), 0)

        let second = try indexer.scan(root: root)
        XCTAssertEqual(second.hashed, 5, "la scansione successiva riparte pulita")
    }

    /// Hash di riferimento calcolato su un file di appoggio: serve a distinguere
    /// "hash del contenuto intero" da "hash del contenuto troncato".
    private func hashOfString(_ s: String) throws -> String {
        let tmp = tempDir.appendingPathComponent("hash-\(UUID().uuidString).bin")
        try s.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return sha256(of: tmp)!
    }
}
