import XCTest
import SQLite3
@testable import AppBackupFoto

final class LibraryIndexStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ key: String, size: Int64 = 100, hash: String = "abc") -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(key), displayPath: key,
                          size: size, mtime: 1_700_000_000, hash: hash, hashedAt: 1_700_003_600)
    }

    // Connessione SQLite indipendente sullo stesso file: serve a simulare "scritto da
    // un'altra versione dell'app" o "scritto da un altro processo" senza aggiungere hook
    // di test nel codice di produzione.
    private func withExternalConnection(_ url: URL, _ body: (OpaquePointer?) -> Void) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            XCTFail("impossibile aprire la connessione esterna a \(url.path)")
            return
        }
        defer { sqlite3_close_v2(handle) }
        body(handle)
    }

    private func externalExec(_ handle: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sconosciuto"
            sqlite3_free(err)
            XCTFail("SQL esterno fallito (\(msg)): \(sql)")
        }
    }

    func testEmptyStore_hasNoEntries() throws {
        XCTAssertEqual(try store.count(), 0)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    func testUpsertThenRead() throws {
        try store.upsert([entry("Foto/a.jpg")])
        let got = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))
        XCTAssertEqual(got?.displayPath, "Foto/a.jpg")
        XCTAssertEqual(got?.hash, "abc")
        XCTAssertEqual(got?.size, 100)
    }

    // `path` e' la chiave normalizzata, `displayPath` il percorso come appare su disco:
    // sono due colonne diverse e vanno rilette dalla propria. Senza questa asserzione un
    // `readEntry` che le scambia (o legge due volte la stessa) passa inosservato.
    func testUpsertThenRead_pathIsTheNormalizedKey() throws {
        try store.upsert([entry("Foto/IMG.JPG")])
        let got = try store.entry(forKey: normalizedIndexKey("Foto/IMG.JPG"))
        XCTAssertEqual(got?.path, normalizedIndexKey("Foto/IMG.JPG"))
        XCTAssertEqual(got?.path, "foto/img.jpg")
        XCTAssertEqual(got?.displayPath, "Foto/IMG.JPG")
        XCTAssertNotEqual(got?.path, got?.displayPath)
    }

    // mtime e hashedAt sono i due soli input di `indexEntryVerdict`: se il round-trip li
    // scambia, li tronca o li confonde con un default, la regola anti-racy e la tolleranza
    // DST decidono su numeri sbagliati senza che nulla lo segnali. Valori distinti fra loro,
    // con parte frazionaria, e diversi dai default usati altrove nel file.
    func testRoundTripsMTimeAndHashedAtExactly() throws {
        let mtime = 1_712_345_678.25
        let hashedAt = 1_723_456_789.75
        let e = LibraryIndexEntry(path: normalizedIndexKey("Foto/t.jpg"), displayPath: "Foto/t.jpg",
                                  size: 4242, mtime: mtime, hash: "H", hashedAt: hashedAt)
        try store.upsert([e])

        let got = try XCTUnwrap(try store.entry(forKey: normalizedIndexKey("Foto/t.jpg")))
        XCTAssertEqual(got.mtime, mtime, accuracy: 0.0)
        XCTAssertEqual(got.hashedAt, hashedAt, accuracy: 0.0)
        XCTAssertEqual(got.size, 4242)

        let byHash = try XCTUnwrap(try store.entries(withHash: "H").first)
        XCTAssertEqual(byHash.mtime, mtime, accuracy: 0.0)
        XCTAssertEqual(byHash.hashedAt, hashedAt, accuracy: 0.0)
        XCTAssertEqual(byHash.size, 4242)
    }

    func testUpsertSameKeyTwice_replacesInsteadOfDuplicating() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "vecchio")])
        try store.upsert([entry("Foto/a.jpg", hash: "nuovo")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash, "nuovo")
    }

    func testEntriesWithHash_findsAllCopies() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "H"),
                          entry("Import/b.jpg", hash: "H"),
                          entry("Altro/c.jpg", hash: "DIVERSO")])
        let found = try store.entries(withHash: "H")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.displayPath)), ["Foto/a.jpg", "Import/b.jpg"])
    }

    func testHasAnyEntryWithSize() throws {
        try store.upsert([entry("Foto/a.jpg", size: 500)])
        XCTAssertTrue(try store.hasAnyEntry(withSize: 500))
        XCTAssertFalse(try store.hasAnyEntry(withSize: 501))
    }

    // Stadio 1 del filtro: deve matchare la dimensione ESATTA. Un confronto allentato
    // (>=, <=) matcherebbe quasi tutto e disattiverebbe il filtro senza rumore, facendo
    // hashare file che non andavano nemmeno letti.
    func testHasAnyEntryWithSize_smallerAndLargerDoNotMatch() throws {
        try store.upsert([entry("Foto/a.jpg", size: 500)])
        XCTAssertFalse(try store.hasAnyEntry(withSize: 499))
        XCTAssertFalse(try store.hasAnyEntry(withSize: 1))
        XCTAssertFalse(try store.hasAnyEntry(withSize: 100_000))
    }

    func testRemoveKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        try store.remove(keys: [normalizedIndexKey("Foto/a.jpg")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    // Il pruning del Task 4 rimuove molte chiavi in un colpo solo: un `remove` che si ferma
    // alla prima lascerebbe entry stale per sempre, e con una sola chiave nel test non si
    // vedrebbe.
    func testRemoveKeys_removesAllOfThemNotJustTheFirst() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg"),
                          entry("Foto/c.jpg"), entry("Foto/d.jpg")])
        try store.remove(keys: [normalizedIndexKey("Foto/a.jpg"),
                                normalizedIndexKey("Foto/b.jpg"),
                                normalizedIndexKey("Foto/c.jpg")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/d.jpg")])
        for gone in ["Foto/a.jpg", "Foto/b.jpg", "Foto/c.jpg"] {
            XCTAssertNil(try store.entry(forKey: normalizedIndexKey(gone)), "\(gone) doveva sparire")
        }
    }

    func testAllKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/a.jpg"),
                                             normalizedIndexKey("Foto/b.jpg")])
    }

    func testPersistsAcrossReopen() throws {
        let dbURL = tempDir.appendingPathComponent("persist.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 1)
    }

    func testBatchUpsertIsAtomicPerBatch() throws {
        let many = (0..<500).map { entry("Foto/f\($0).jpg", hash: "h\($0)") }
        try store.upsert(many)
        XCTAssertEqual(try store.count(), 500)
    }

    // Atomicita' vera: una riga che fallisce a meta' batch non deve lasciare nell'indice
    // le righe precedenti (l'indice sarebbe parziale ma il chiamante crederebbe di aver
    // scritto tutto), e soprattutto non deve lasciare una transazione aperta che manda in
    // errore ogni upsert successivo.
    func testBatchUpsertWithAFailingRow_rollsBackAndLeavesTheStoreUsable() throws {
        let dbURL = tempDir.appendingPathComponent("atomic.sqlite")
        let s = try LibraryIndexStore(url: dbURL)
        try s.upsert([entry("Foto/gia-presente.jpg")])
        XCTAssertEqual(try s.count(), 1)

        withExternalConnection(dbURL) { handle in
            externalExec(handle, """
            CREATE TRIGGER blocca_boom BEFORE INSERT ON entries
            WHEN NEW.path = 'foto/boom.jpg'
            BEGIN SELECT RAISE(ABORT, 'riga rifiutata'); END;
            """)
        }

        var batch = (0..<200).map { entry("Foto/b\($0).jpg", hash: "h\($0)") }
        batch.insert(entry("Foto/boom.jpg"), at: 100)
        XCTAssertThrowsError(try s.upsert(batch), "il batch deve fallire, non ingoiare la riga rifiutata")

        XCTAssertEqual(try s.count(), 1, "rollback: nessuna riga del batch fallito resta nell'indice")

        withExternalConnection(dbURL) { handle in
            externalExec(handle, "DROP TRIGGER blocca_boom;")
        }

        // Se il ROLLBACK non fosse avvenuto, qui fallirebbe con "cannot start a transaction
        // within a transaction" o scriverebbe dentro la transazione appesa.
        try s.upsert([entry("Foto/dopo.jpg")])
        XCTAssertEqual(try s.count(), 2)
        XCTAssertNotNil(try s.entry(forKey: normalizedIndexKey("Foto/dopo.jpg")))
    }

    // La SQLite di sistema e' multi-thread ma NON serialized: senza la coda seriale della
    // store, scritture e letture in parallelo crashano dentro sqlite3_step (riprodotto) e,
    // col solo mutex, le transazioni si accavallano perdendo righe in silenzio.
    // I chiamanti reali sono davvero concorrenti: scanner su coda di background, import su
    // un'altra coda, pannello Revisione sul main thread.
    func testConcurrentReadsAndWrites_noCrashAndNoLostRows() throws {
        let threads = 8
        let perThread = 25
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                let key = "Foto/t\(t)-\(i).jpg"
                do {
                    try store.upsert([entry(key, size: Int64(1000 + i), hash: "h\(t)-\(i)")])
                    _ = try store.count()
                    _ = try store.entries(withHash: "h\(t)-\(i)")
                    _ = try store.hasAnyEntry(withSize: Int64(1000 + i))
                    _ = try store.allKeys()
                    _ = try store.entry(forKey: normalizedIndexKey(key))
                } catch {
                    XCTFail("accesso concorrente fallito: \(error)")
                }
            }
        }
        XCTAssertEqual(try store.count(), threads * perThread)
        XCTAssertEqual(try store.allKeys().count, threads * perThread)
    }

    // Normalizzazione della chiave: ExFAT e' case-insensitive e non normalizza
    // l'Unicode, APFS preserva la normalizzazione originale invece di imporne una.
    // Senza normalizzazione lo stesso file produrrebbe due entry distinte.
    func testKeyNormalization_caseInsensitive() {
        XCTAssertEqual(normalizedIndexKey("Foto/IMG.JPG"), normalizedIndexKey("foto/img.jpg"))
    }

    func testKeyNormalization_unicodeNFCvsNFD() {
        let nfc = "Citt\u{00E0}/foto.jpg"        // à precomposta
        let nfd = "Citta\u{0300}/foto.jpg"       // a + accento combinante
        XCTAssertEqual(normalizedIndexKey(nfc), normalizedIndexKey(nfd))
    }

    func testKeyNormalization_preservesDistinctPaths() {
        XCTAssertNotEqual(normalizedIndexKey("Foto/a.jpg"), normalizedIndexKey("Foto/b.jpg"))
    }

    // Il percorso relativo viene ricavato dalla root della libreria: basta che un solo
    // punto del codice produca uno slash iniziale o doppio (root con o senza slash finale)
    // perche' TUTTE le chiavi si spostino — indice apparentemente vuoto, intera libreria
    // rihashata, o una seconda copia di ogni entry.
    func testKeyNormalization_canonicalizesPathForm() {
        let expected = normalizedIndexKey("Foto/a.jpg")
        XCTAssertEqual(expected, "foto/a.jpg")
        for variante in ["Foto//a.jpg", "/Foto/a.jpg", "./Foto/a.jpg", "Foto/./a.jpg",
                         "//Foto///a.jpg", "/./Foto/a.jpg"] {
            XCTAssertEqual(normalizedIndexKey(variante), expected, "variante non canonicalizzata: \(variante)")
        }
    }

    func testKeyNormalization_isStableThroughTheStore() throws {
        try store.upsert([entry("Foto/a.jpg")])
        XCTAssertNotNil(try store.entry(forKey: normalizedIndexKey("/Foto//a.jpg")))
    }

    // Un indice scritto con uno schema diverso non va interpretato: si riparte.
    // La versione viene scritta da una connessione esterna, non da un hook di test nel
    // codice di produzione: e' anche una simulazione piu' fedele di "scritto da una
    // versione futura dell'app".
    func testUnknownSchemaVersion_resetsIndex() throws {
        let dbURL = tempDir.appendingPathComponent("schema.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        XCTAssertEqual(try first.count(), 1)

        withExternalConnection(dbURL) { handle in
            externalExec(handle, "PRAGMA user_version=999;")
        }

        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 0, "schema sconosciuto: l'indice va ricostruito, non letto")
    }

    // Il caso peggiore trovato in revisione: una versione futura che tiene la versione in
    // una riga di tabella con un valore non intero ("2.0") e ha rinominato una colonna.
    // Interpretarlo come "database nuovo" adottava quelle tabelle e rendeva l'indice rotto
    // a ogni avvio, per sempre. Con `user_version` (0 su quel file) si ricostruisce.
    func testSchemaWrittenByAnotherVersionWithNonNumericVersion_isRebuilt() throws {
        let dbURL = tempDir.appendingPathComponent("futuro.sqlite")
        withExternalConnection(dbURL) { handle in
            externalExec(handle, """
            CREATE TABLE entries (
                path TEXT PRIMARY KEY, display_path TEXT, size INTEGER,
                mtime REAL, sha TEXT, hashed_at REAL
            );
            INSERT INTO entries VALUES ('foto/vecchia.jpg','Foto/vecchia.jpg',1,2.0,'H',3.0);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta VALUES ('schema_version','2.0');
            """)
        }

        let s = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try s.count(), 0, "schema sconosciuto: ricostruire, non adottare")
        // E deve essere davvero usabile, non solo vuoto: era questo il caso irreversibile.
        try s.upsert([entry("Foto/nuova.jpg", hash: "N")])
        XCTAssertEqual(try s.entries(withHash: "N").count, 1)
        XCTAssertEqual(try s.count(), 1)
    }

    // Un file che non e' un database SQLite nella posizione dell'indice rendeva l'indice
    // inutilizzabile per sempre (throw a ogni avvio, dedup spento, doppioni ricreati a ogni
    // import). L'indice e' una cache: si ricostruisce.
    func testGarbageFileAtIndexPath_isRebuiltInsteadOfFailingForever() throws {
        let dbURL = tempDir.appendingPathComponent("spazzatura.sqlite")
        var garbage = Data()
        for i in 0..<8192 { garbage.append(UInt8((i * 37 + 11) % 251)) }
        try garbage.write(to: dbURL)

        let s = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try s.count(), 0)
        try s.upsert([entry("Foto/a.jpg")])
        XCTAssertEqual(try s.count(), 1)
    }

    // L'indice non deve MAI finire sul volume sorgente: `init` crea le directory mancanti,
    // quindi senza guardia un percorso sull'SSD ci creerebbe dentro cartelle e file.
    func testIndexOutsideApplicationSupport_isRejectedWithoutCreatingAnything() {
        // Il caso che conta davvero (un percorso sul volume sorgente) e uno in una
        // directory scrivibile ma non ammessa: senza il secondo, il test passerebbe anche
        // solo perche' /Volumes non e' scrivibile su questa macchina.
        let onVolume = URL(fileURLWithPath: "/Volumes/AppBackupFotoTest-\(UUID().uuidString)")
        let writableButNotAllowed = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppBackupFotoTest-\(UUID().uuidString)")

        for root in [onVolume, writableButNotAllowed] {
            let dbURL = root.appendingPathComponent("Foto iPhone/index.sqlite")
            XCTAssertThrowsError(try LibraryIndexStore(url: dbURL)) { error in
                guard case LibraryIndexStore.StoreError.invalidLocation = error else {
                    return XCTFail("errore inatteso per \(dbURL.path): \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                           "la store non deve creare nulla fuori dalla posizione ammessa: \(root.path)")
            try? FileManager.default.removeItem(at: root)
        }
    }

    // `TEXT PRIMARY KEY` in una tabella rowid non implica NOT NULL: una riga con path NULL
    // scritta da un'altra connessione (o da una versione precedente dello schema) faceva
    // crashare il processo alla lettura. Va saltata, non interpretata.
    func testRowWithNullTextColumn_isSkippedNotCrashing() throws {
        let dbURL = tempDir.appendingPathComponent("null.sqlite")
        withExternalConnection(dbURL) { handle in
            externalExec(handle, """
            PRAGMA user_version=\(LibraryIndexStore.schemaVersion);
            CREATE TABLE entries (
                path TEXT PRIMARY KEY, display_path TEXT, size INTEGER,
                mtime REAL, hash TEXT, hashed_at REAL
            );
            CREATE INDEX idx_entries_hash ON entries(hash);
            CREATE INDEX idx_entries_size ON entries(size);
            INSERT INTO entries VALUES (NULL, NULL, 100, 1.0, 'H', 2.0);
            INSERT INTO entries VALUES ('foto/buona.jpg', 'Foto/buona.jpg', 100, 1.0, 'H', 2.0);
            """)
        }

        let s = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try s.count(), 2, "la riga malformata c'e' ancora sul disco")
        XCTAssertEqual(try s.allKeys(), ["foto/buona.jpg"])
        let found = try s.entries(withHash: "H")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.displayPath, "Foto/buona.jpg")
    }

    // MARK: - Cintura sull'estensione

    private func garbage(_ bytes: Int = 8192) -> Data {
        var d = Data()
        for i in 0..<bytes { d.append(UInt8((i * 37 + 11) % 251)) }
        return d
    }

    private func permissions(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    // La guardia di posizione da sola non basta. `deleteDatabaseFiles` scatta quando SQLite
    // risponde `SQLITE_NOTADB` — che e' esattamente cio' che SQLite risponde per QUALUNQUE
    // file che non sia un database. Se un domani qualcuno passasse alla store il percorso di
    // un JPEG sotto Application Support, quel JPEG verrebbe cancellato. Qui si lancia e non
    // si tocca niente.
    func testFileWithANonSqliteExtension_isNeverDeleted() throws {
        let jpeg = tempDir.appendingPathComponent("una-foto.jpg")
        let contents = garbage()
        try contents.write(to: jpeg)

        XCTAssertThrowsError(try LibraryIndexStore(url: jpeg)) { error in
            guard case LibraryIndexStore.StoreError.notAnIndexFile = error else {
                return XCTFail("errore inatteso: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path),
                      "un file che non e' un indice non si cancella, mai")
        XCTAssertEqual(try Data(contentsOf: jpeg), contents, "e non si tocca nemmeno")
    }

    // MARK: - Permessi 0600

    // Il file dell'indice contiene i percorsi delle foto — dati personali, non cifrati — e
    // nasce `0644`: leggibile da un altro utente locale dello stesso Mac. SQLite ricrea i
    // sidecar a ogni checkpoint, quindi i permessi vanno MISURATI dopo un ciclo completo di
    // apertura/scrittura/chiusura, non dedotti dalla documentazione.
    func testIndexAndSidecarsAre0600_afterAFullOpenWriteCloseCycle() throws {
        // Controllo dell'umask: se il processo di test avesse gia' un umask restrittivo, il
        // test sarebbe verde anche senza il `chmod` e non dimostrerebbe niente.
        let control = tempDir.appendingPathComponent("controllo.txt")
        try Data("x".utf8).write(to: control)
        if try permissions(control.path) == 0o600 {
            throw XCTSkip("umask gia' restrittiva: il test non distinguerebbe il fix dal default")
        }

        let dbURL = tempDir.appendingPathComponent("permessi.sqlite")
        var s: LibraryIndexStore? = try LibraryIndexStore(url: dbURL)
        try s?.upsert((0..<50).map { entry("Foto/f\($0).jpg", hash: "h\($0)") })

        XCTAssertEqual(try permissions(dbURL.path), 0o600)
        for side in ["-wal", "-shm"] {
            let p = dbURL.path + side
            XCTAssertTrue(FileManager.default.fileExists(atPath: p), "manca \(side): il ciclo non ha scritto")
            XCTAssertEqual(try permissions(p), 0o600, "permessi larghi su \(side)")
        }

        // Chiusura: SQLite fa il checkpoint e rimuove i sidecar.
        s = nil

        // Secondo ciclo: i sidecar vengono RICREATI da SQLite, non da noi. Devono nascere
        // stretti perche' il database sotto e' stretto.
        let reopened = try LibraryIndexStore(url: dbURL)
        try reopened.upsert([entry("Foto/dopo-riapertura.jpg")])
        XCTAssertEqual(try reopened.count(), 51)
        XCTAssertEqual(try permissions(dbURL.path), 0o600)
        for side in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: dbURL.path + side) {
            XCTAssertEqual(try permissions(dbURL.path + side), 0o600,
                           "permessi larghi su \(side) ricreato da SQLite")
        }
    }

    // MARK: - Elimina indice e ricostruisci

    // L'unica via d'uscita dalla regola "traversata incompleta ⇒ nessuna rimozione": se
    // l'utente cancellasse davvero tutte le foto, le entry fantasma resterebbero per sempre.
    func testDeleteIndexAndRecreate_emptiesTheIndexAndLeavesItUsable() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg", hash: "def")])
        XCTAssertEqual(try store.count(), 2)

        try store.deleteIndexAndRecreate()

        XCTAssertEqual(try store.count(), 0, "l'indice va azzerato")
        try store.upsert([entry("Foto/c.jpg")])
        XCTAssertEqual(try store.count(), 1, "e deve restare scrivibile subito dopo")
    }

    // Che il file sia stato cancellato davvero — e non solo svuotato con un DELETE — si
    // misura dall'inode: un file ricreato ha un inode diverso.
    func testDeleteIndexAndRecreate_reallyRemovesTheFileFromDisk() throws {
        let dbURL = tempDir.appendingPathComponent("inode.sqlite")
        let s = try LibraryIndexStore(url: dbURL)
        try s.upsert([entry("Foto/a.jpg")])
        let before = try XCTUnwrap(try FileManager.default
            .attributesOfItem(atPath: dbURL.path)[.systemFileNumber] as? NSNumber).uint64Value

        try s.deleteIndexAndRecreate()

        let after = try XCTUnwrap(try FileManager.default
            .attributesOfItem(atPath: dbURL.path)[.systemFileNumber] as? NSNumber).uint64Value
        XCTAssertNotEqual(before, after, "il file dell'indice va cancellato, non svuotato")
    }

    // Percorsi espliciti, mai wildcard, mai ricorsione su directory: nella stessa cartella
    // possono starci file di altri componenti dell'app, e questa e' l'unica cancellazione di
    // file di tutta la classe.
    func testDeleteIndexAndRecreate_doesNotTouchAnyOtherFileInTheDirectory() throws {
        let dbURL = tempDir.appendingPathComponent("solo-questo.sqlite")
        let s = try LibraryIndexStore(url: dbURL)
        try s.upsert([entry("Foto/a.jpg")])

        // Vicini scelti per essere il piu' possibile "quasi l'indice": stessa estensione,
        // stesso nome con suffisso, stesso prefisso dei sidecar.
        let neighbours = ["altro.sqlite", "solo-questo.sqlite.backup", "solo-questo.sqliteX",
                          "solo-questo.jpg", "note.txt"]
        for name in neighbours {
            try Data(name.utf8).write(to: tempDir.appendingPathComponent(name))
        }
        let subdir = tempDir.appendingPathComponent("sottocartella", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("dentro".utf8).write(to: subdir.appendingPathComponent("dentro.sqlite"))

        try s.deleteIndexAndRecreate()

        for name in neighbours {
            let url = tempDir.appendingPathComponent(name)
            XCTAssertEqual(try? Data(contentsOf: url), Data(name.utf8),
                           "\(name) non doveva essere toccato")
        }
        XCTAssertEqual(try? Data(contentsOf: subdir.appendingPathComponent("dentro.sqlite")),
                       Data("dentro".utf8), "niente ricorsione nelle sottocartelle")
    }

    // Ricostruzione da zero: dopo la cancellazione l'indice riparte vuoto anche se il file
    // conteneva dati di una libreria che non esiste piu'.
    func testDeleteIndexAndRecreate_thenReopeningFromScratchSeesAnEmptyIndex() throws {
        let dbURL = tempDir.appendingPathComponent("ricostruzione.sqlite")
        let s = try LibraryIndexStore(url: dbURL)
        try s.upsert([entry("Foto/fantasma.jpg")])
        try s.deleteIndexAndRecreate()

        let fresh = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try fresh.count(), 0)
        XCTAssertNil(try fresh.entry(forKey: normalizedIndexKey("Foto/fantasma.jpg")))
    }
}
