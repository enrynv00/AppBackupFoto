import XCTest
import SQLite3
@testable import AppBackupFoto

/// `LibraryIndexStore.duplicateGroups()` — i gruppi di file byte-identici letti dall'indice.
///
/// Database temporanei reali, nessun mock, come in `LibraryIndexStoreTests`: la query e'
/// la cosa da provare, e su un finto store non proverebbe niente.
final class DuplicateGroupsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DuplicateGroupsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ key: String, size: Int64 = 100, hash: String = "H",
                       mtime: Double = 1_700_000_000, hashedAt: Double = 1_700_003_600) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(key), displayPath: key,
                          size: size, mtime: mtime, hash: hash, hashedAt: hashedAt)
    }

    // Connessione SQLite indipendente sullo stesso file: serve a scrivere righe che il
    // codice di produzione non scriverebbe mai (una colonna TEXT a NULL) senza aggiungere
    // hook di test dentro la store. Stessa forma gia' usata in `LibraryIndexStoreTests`.
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

    /// Sequenza `(hash, chiave)` di tutti i membri, nell'ordine in cui la query li ha
    /// restituiti: e' la forma su cui si misura il determinismo.
    private func shape(_ groups: [DuplicateGroup]) -> [String] {
        groups.flatMap { g in g.members.map { "\(g.hash)|\($0.path)" } }
    }

    // MARK: - Gruppi

    func testEmptyIndex_hasNoGroups() throws {
        XCTAssertTrue(try store.duplicateGroups().isEmpty)
    }

    func testTwoEntriesSameHash_areOneGroupOfTwo() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", hash: "H"),
                          entry("Import/Scheda/b.jpg", hash: "H")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 2)
        XCTAssertEqual(Set(groups.first?.members.map(\.displayPath) ?? []),
                       ["Foto iPhone/a.jpg", "Import/Scheda/b.jpg"])
    }

    func testThreeEntriesSameHash_areOneGroupOfThree() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", hash: "H"),
                          entry("Takeout/b.jpg", hash: "H"),
                          entry("Other/c.jpg", hash: "H")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 3)
    }

    // Un file con hash unico non e' un doppione. Se la soglia scivolasse a
    // `COUNT(*) >= 1` il pannello proporrebbe di cestinare copie che non esistono.
    func testUniqueHash_isNotAGroup() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", hash: "H1"),
                          entry("Foto iPhone/b.jpg", hash: "H2"),
                          entry("Foto iPhone/c.jpg", hash: "H3")])

        XCTAssertTrue(try store.duplicateGroups().isEmpty,
                      "tre hash distinti non sono un gruppo di doppioni")
    }

    func testUniqueHashAlongsideADuplicate_isNotIncludedInAnyGroup() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", hash: "H"),
                          entry("Takeout/b.jpg", hash: "H"),
                          entry("Other/solo.jpg", hash: "SOLO")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.hash, "H")
        XCTAssertFalse(shape(groups).contains { $0.hasSuffix(normalizedIndexKey("Other/solo.jpg")) },
                       "il file senza copie non deve comparire in nessun gruppo")
    }

    func testTwoDistinctGroups_areNotMixed() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", size: 100, hash: "H1"),
                          entry("Takeout/a.jpg", size: 100, hash: "H1"),
                          entry("Foto iPhone/b.mov", size: 200, hash: "H2"),
                          entry("Takeout/b.mov", size: 200, hash: "H2"),
                          entry("Other/b.mov", size: 200, hash: "H2")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 2)
        for g in groups {
            XCTAssertTrue(g.members.allSatisfy { $0.hash == g.hash },
                          "membri di gruppi diversi mescolati nel gruppo \(g.hash)")
        }
        XCTAssertEqual(Set(groups.map { $0.members.count }), [2, 3])
    }

    // MARK: - File da 0 byte

    // TUTTI i file vuoti condividono lo stesso SHA256, e nell'indice ci sono solo media:
    // un media da 0 byte e' troncato o corrotto, non una copia di qualcos'altro.
    // Raggrupparli significherebbe proporre di cestinare file DIVERSI credendoli copie —
    // lo stesso buco gia' trovato e chiuso una volta con i sidecar `.AAE` (ADR-0003).
    func testZeroByteFiles_areNotAGroup() throws {
        try store.upsert([entry("Foto iPhone/vuoto1.jpg", size: 0, hash: "SHA256-DEL-VUOTO"),
                          entry("Takeout/vuoto2.jpg", size: 0, hash: "SHA256-DEL-VUOTO"),
                          entry("Other/vuoto3.jpg", size: 0, hash: "SHA256-DEL-VUOTO")])

        XCTAssertTrue(try store.duplicateGroups().isEmpty,
                      "tre file da 0 byte con lo stesso hash non sono tre copie dello stesso file")
    }

    // I file vuoti non devono nemmeno "contaminare" un gruppo altrimenti sano: se
    // l'esclusione valesse solo per la riga esterna e non per il conteggio, un file da
    // 0 byte farebbe salire a due il numero di copie di un file che copie non ne ha.
    func testZeroByteMemberWithANonEmptyOne_isNotAGroup() throws {
        try store.upsert([entry("Foto iPhone/vuoto.jpg", size: 0, hash: "H"),
                          entry("Takeout/pieno.jpg", size: 100, hash: "H")])

        XCTAssertTrue(try store.duplicateGroups().isEmpty,
                      "dati incoerenti (stesso hash, dimensioni diverse di cui una nulla): niente gruppo")
    }

    // Le due occorrenze di `size > 0` NON sono simmetriche, e questo e' il caso che lo
    // dimostra: qui l'hash ha gia' due copie vere, quindi la sottoquery lo mette comunque
    // nell'elenco degli hash duplicati — a escludere il file vuoto dai MEMBRI resta solo
    // il filtro esterno. Senza quello, il file da 0 byte (troncato o corrotto, non una
    // copia) diventerebbe il terzo membro del gruppo: un candidato al cestinamento, o
    // peggio la copia che la regola di proposta sceglie di TENERE al posto di una buona.
    // Gli altri test sui file vuoti non lo vedono: la' l'hash e' escluso dalla sottoquery.
    func testZeroByteMemberInsideARealGroup_isNotAMember() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", size: 100, hash: "H"),
                          entry("Takeout/a.jpg", size: 100, hash: "H"),
                          entry("Other/troncato.jpg", size: 0, hash: "H")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 2,
                       "il file da 0 byte non e' una copia: non e' un membro")
        XCTAssertFalse(groups.first?.members.contains { $0.displayPath == "Other/troncato.jpg" } ?? true,
                       "il file troncato non deve finire fra le copie da cestinare")
    }

    func testZeroByteFiles_doNotHideTheRealGroups() throws {
        try store.upsert([entry("Foto iPhone/vuoto1.jpg", size: 0, hash: "SHA256-DEL-VUOTO"),
                          entry("Takeout/vuoto2.jpg", size: 0, hash: "SHA256-DEL-VUOTO"),
                          entry("Foto iPhone/vera.jpg", size: 100, hash: "H"),
                          entry("Takeout/vera.jpg", size: 100, hash: "H")])

        let groups = try store.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.hash, "H")
    }

    // MARK: - Contenuto delle righe

    func testGroupCarriesTheSharedHashAndSize() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", size: 4242, hash: "HASH-CONDIVISO"),
                          entry("Takeout/a.jpg", size: 4242, hash: "HASH-CONDIVISO")])

        let group = try XCTUnwrap(try store.duplicateGroups().first)
        XCTAssertEqual(group.hash, "HASH-CONDIVISO")
        XCTAssertEqual(group.size, 4242)
        XCTAssertTrue(group.members.allSatisfy { $0.size == 4242 })
    }

    // Hash uguale dovrebbe significare dimensione uguale, ma l'indice e' una cache e puo'
    // essere incoerente (ADR-0002): il codice non lo impone e non puo' imporlo. In quel
    // caso si espone la dimensione MINIMA, mai la prima incontrata. Il numero finisce nel
    // riepilogo che l'utente legge prima del bottone distruttivo, e lo spazio recuperabile
    // dichiarato non deve mai essere sovrastimato: sottostimare e' innocuo, promettere GB
    // che non si liberano e' consenso raccolto su un numero falso.
    // Il gruppo resta comunque visibile — nasconderlo farebbe sparire due doppioni veri
    // per colpa di una terza riga avvelenata — e l'incoerenza vera la intercetta il
    // percorso di cancellazione, che rilegge, rihasha e pretende unanimita'.
    func testIncoherentSizesForTheSameHash_exposeTheSmallestSize() throws {
        try store.upsert([entry("Foto iPhone/a.jpg", size: 900, hash: "H"),
                          entry("Takeout/a.jpg", size: 100, hash: "H"),
                          entry("Other/a.jpg", size: 500, hash: "H")])

        let group = try XCTUnwrap(try store.duplicateGroups().first)
        XCTAssertEqual(group.members.count, 3)
        XCTAssertEqual(group.size, 100, "mai sovrastimare lo spazio recuperabile")
    }

    // I membri arrivano dalle colonne dell'indice, non ricostruiti: `displayPath` e' il
    // percorso come appare su disco (il Task 4 lo usa per rileggere il file), `mtime` e
    // `hashedAt` sono gli input della regola di proposta e della regola anti-racy.
    // Valori distinti fra loro e con parte frazionaria: se il round-trip li scambia o li
    // tronca, qui si vede.
    func testMemberFieldsAreTheStoredOnes() throws {
        let mtime = 1_712_345_678.25
        let hashedAt = 1_723_456_789.75
        try store.upsert([entry("Foto iPhone/IMG_0001.JPG", size: 777, hash: "H",
                                mtime: mtime, hashedAt: hashedAt),
                          entry("Takeout/altra.jpg", size: 777, hash: "H")])

        let group = try XCTUnwrap(try store.duplicateGroups().first)
        let member = try XCTUnwrap(group.members.first { $0.displayPath == "Foto iPhone/IMG_0001.JPG" })
        XCTAssertEqual(member.path, normalizedIndexKey("Foto iPhone/IMG_0001.JPG"))
        XCTAssertNotEqual(member.path, member.displayPath, "chiave normalizzata e percorso di visualizzazione sono due colonne diverse")
        XCTAssertEqual(member.size, 777)
        XCTAssertEqual(member.mtime, mtime, accuracy: 0.0)
        XCTAssertEqual(member.hashedAt, hashedAt, accuracy: 0.0)
        XCTAssertEqual(member.hash, "H")
    }

    // MARK: - Determinismo

    // La proposta di quale copia tenere (Task 2) e il riepilogo del blocco (Task 3)
    // poggiano su questo elenco: se cambiasse ordine fra due letture, l'utente vedrebbe
    // una proposta diversa senza che sia cambiato niente.
    func testResultIsStableAcrossTwoCalls() throws {
        // Dimensione legata all'hash, non all'indice del ciclo: contenuto uguale significa
        // dimensione uguale, e una fixture in cui lo stesso hash ha dimensioni diverse
        // sarebbe un indice che non puo' esistere — il test piu' "realistico" del file
        // girerebbe su dati impossibili.
        var entries: [LibraryIndexEntry] = []
        for i in 0..<20 {
            entries.append(entry("Foto iPhone/f\(i).jpg", size: Int64(100 + i % 5), hash: "H\(i % 5)"))
            entries.append(entry("Takeout/f\(i).jpg", size: Int64(100 + i % 5), hash: "H\(i % 5)"))
        }
        try store.upsert(entries)

        let first = try store.duplicateGroups()
        let second = try store.duplicateGroups()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(shape(first), shape(second))
    }

    func testOrderDoesNotDependOnInsertionOrder() throws {
        let batch = [entry("Takeout/z.jpg", hash: "H1"),
                     entry("Foto iPhone/a.jpg", hash: "H1"),
                     entry("Other/m.jpg", hash: "H2"),
                     entry("Foto iPhone/b.jpg", hash: "H2")]

        try store.upsert(batch)
        let direct = try store.duplicateGroups()

        let reversedStore = try LibraryIndexStore(url: tempDir.appendingPathComponent("rovescio.sqlite"))
        try reversedStore.upsert(batch.reversed())
        let reversed = try reversedStore.duplicateGroups()

        XCTAssertEqual(shape(direct), shape(reversed),
                       "l'ordine di inserimento non deve cambiare l'elenco mostrato")
    }

    // MARK: - Righe malformate e database rotto

    // `TEXT PRIMARY KEY` in una tabella rowid non implica NOT NULL, e il vincolo dello
    // schema non protegge le righe scritte prima o da un'altra connessione.
    // `String(cString:)` su un puntatore nil TERMINA il processo (SIGTRAP): una riga
    // malformata si salta. Se la guardia mancasse, questo test non fallirebbe — farebbe
    // fuori l'intero test runner, che e' comunque un rosso impossibile da ignorare.
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
            INSERT INTO entries VALUES ('foto/buona1.jpg', 'Foto/buona1.jpg', 100, 1.0, 'H', 2.0);
            INSERT INTO entries VALUES ('foto/buona2.jpg', 'Foto/buona2.jpg', 100, 1.0, 'H', 2.0);
            """)
        }

        let s = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try s.count(), 3, "la riga malformata c'e' ancora sul disco")

        let groups = try s.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 2, "la riga malformata va saltata, non interpretata")
        XCTAssertEqual(Set(groups.first?.members.map(\.displayPath) ?? []),
                       ["Foto/buona1.jpg", "Foto/buona2.jpg"])
    }

    // La regola "almeno due copie" e' scritta in due punti — l'`HAVING COUNT(*) > 1` della
    // query e il conteggio dei membri leggibili in Swift — e servono entrambi, come per il
    // doppio `size > 0`. Il secondo copre il caso che il primo non puo' vedere: la query
    // conta le RIGHE, ma una riga malformata viene saltata in lettura, quindi un gruppo di
    // due righe puo' arrivare all'utente con un solo membro leggibile. Un "gruppo" da un
    // membro solo non e' un gruppo: mostrerebbe come doppione un file che copie non ne ha.
    //
    // NOTA DI MUTATION TESTING: e' proprio per questa ridondanza che mutare da solo
    // l'`HAVING COUNT(*) > 1` in `>= 1` non cambia il risultato (cambia solo quante righe
    // si leggono). Il mutante che conta e' la rimozione della regola da ENTRAMBI i punti,
    // uccisa da `testUniqueHash_isNotAGroup`; questo test uccide quella dal solo lato Swift.
    func testGroupReducedToASingleReadableMember_isNotAGroup() throws {
        let dbURL = tempDir.appendingPathComponent("ridotto.sqlite")
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
        XCTAssertEqual(try s.count(), 2, "le due righe ci sono entrambe sul disco")
        XCTAssertTrue(try s.duplicateGroups().isEmpty,
                      "con una sola riga leggibile non c'e' nessun doppione da mostrare")
    }

    // Un indice illeggibile deve LANCIARE, mai restituire un elenco vuoto o troncato: un
    // elenco troncato in silenzio e' un gruppo di doppioni che sparisce dalla schermata
    // senza che nessuno sappia perche'.
    //
    // Un ciclo `while sqlite3_step(...) == SQLITE_ROW` esce identico su `SQLITE_DONE` e su
    // `SQLITE_CORRUPT`: con quel ciclo questo test diventa rosso, perche' la corruzione
    // si presenta al primo `step` e non al `prepare` (misurato con la SQLite di sistema,
    // 3.51.0: `prepare` legge lo schema dalla prima pagina, integra; le pagine dei dati
    // sono rotte e `step` risponde SQLITE_CORRUPT).
    func testCorruptDatabase_throws() throws {
        let dbURL = tempDir.appendingPathComponent("corrotto.sqlite")
        var s: LibraryIndexStore? = try LibraryIndexStore(url: dbURL)
        try s?.upsert([entry("Foto iPhone/a.jpg", hash: "H"),
                       entry("Takeout/a.jpg", hash: "H")])
        s = nil  // chiude la connessione: SQLite fa il checkpoint e rimuove il WAL

        try smashEveryPageButTheFirst(dbURL)

        let reopened = try LibraryIndexStore(url: dbURL)
        XCTAssertThrowsError(try reopened.duplicateGroups()) { error in
            guard case LibraryIndexStore.StoreError.sqlFailed = error else {
                return XCTFail("errore inatteso: \(error)")
            }
        }
    }

    /// Rende illeggibili le pagine dei dati lasciando intatta l'intestazione (prima
    /// pagina): il database si apre e lo schema si legge, ma leggere le righe fallisce.
    /// E' la sola forma di corruzione misurata che arriva fino a `sqlite3_step` —
    /// troncare il file, per esempio, viene gia' rilevato all'apertura.
    private func smashEveryPageButTheFirst(_ url: URL) throws {
        var data = try Data(contentsOf: url)
        // Dimensione di pagina: interi 16-17 dell'intestazione, big-endian; il valore 1
        // significa 65536 (SQLite file format).
        let raw = Int(data[16]) << 8 | Int(data[17])
        let pageSize = raw == 1 ? 65536 : raw
        try XCTSkipIf(data.count <= pageSize, "il database sta in una pagina sola: niente pagine dati da rompere")
        for i in pageSize..<data.count { data[i] = 0xA5 }
        try data.write(to: url)
    }
}
