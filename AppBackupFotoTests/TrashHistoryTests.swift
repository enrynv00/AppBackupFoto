import XCTest
@testable import AppBackupFoto

/// `TrashHistory` — la storia degli spostamenti (ADR-0012, D13 punto 4).
///
/// Non e' un annullamento: nessun test qui verifica che la storia venga letta per decidere
/// qualcosa, perche' non deve succedere mai. Su directory temporanee reali, come tutto il
/// resto del progetto.
final class TrashHistoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trashhistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var historyURL: URL { root.appendingPathComponent("trash-history.jsonl") }

    private func item(path: String, batch: String = "b1") -> TrashedItem {
        TrashedItem(batchId: batch,
                   originalDisplayPath: path,
                   originalKey: normalizedIndexKey(path),
                   trashedPath: "/Volumes/SSD - Enri/.Trashes/501/\(UUID().uuidString).jpg",
                   size: 1_000,
                   hash: "h",
                   trashedAt: Date())
    }

    /// Legge il file riga per riga, senza fidarsi di un'unica `String(contentsOf:)` che
    /// potrebbe includere una riga vuota finale: `split` con `omittingEmptySubsequences`.
    private func linesOfFile(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Append-only

    /// La prova diretta che l'append non riscrive mai: la prima riga, letta byte per byte,
    /// deve restare identica anche dopo un secondo blocco E dopo aver riaperto lo store da
    /// zero (una nuova istanza sullo stesso file, come farebbe l'app dopo un riavvio).
    func testAppendsOneLinePerBlock_andNeverRewritesThePreviousOnes() throws {
        let h1 = try TrashHistory(url: historyURL)
        h1.append(blockId: "b1", trashed: [item(path: "/SSD/Foto iPhone/a.jpg", batch: "b1")])
        let firstLineAfterFirstAppend = try linesOfFile(historyURL)[0]

        h1.append(blockId: "b2", trashed: [item(path: "/SSD/Takeout/b.jpg", batch: "b2")])
        let linesAfterSecond = try linesOfFile(historyURL)
        XCTAssertEqual(linesAfterSecond.count, 2)
        XCTAssertEqual(linesAfterSecond[0], firstLineAfterFirstAppend,
                       "la prima riga non deve cambiare mai, byte per byte")

        // Riapri da zero: una nuova istanza sullo stesso file, come dopo un riavvio dell'app.
        let h2 = try TrashHistory(url: historyURL)
        h2.append(blockId: "b3", trashed: [item(path: "/SSD/Other/c.jpg", batch: "b3")])
        let linesAfterThird = try linesOfFile(historyURL)
        XCTAssertEqual(linesAfterThird.count, 3)
        XCTAssertEqual(linesAfterThird[0], firstLineAfterFirstAppend)
        XCTAssertEqual(linesAfterThird[1], linesAfterSecond[1])
    }

    /// Un blocco senza file spostati non produce nessuna riga: non c'e' niente da ricordare.
    func testEmptyBlock_writesNothing() throws {
        let history = try TrashHistory(url: historyURL)
        history.append(blockId: "b1", trashed: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }

    // MARK: - Sicurezza della posizione e dei permessi

    func testFileIs0600() throws {
        let history = try TrashHistory(url: historyURL)
        history.append(blockId: "b1", trashed: [item(path: "/SSD/Foto iPhone/a.jpg")])
        let attrs = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    /// Riusa `isAllowedStoreLocation`, la stessa allow-list di `TrashManifestStore` e
    /// `LibraryIndexStore` — non una seconda scritta apposta, che divergerebbe alla prima
    /// modifica di una sola delle due.
    func testRefusesALocationOutsideTheAllowedOne() {
        let outside = URL(fileURLWithPath: "/Volumes/SSD - Enri/trash-history.jsonl")
        XCTAssertThrowsError(try TrashHistory(url: outside))
    }

    // MARK: - Un file corrotto non blocca niente

    /// E' una storia, non un prerequisito: se il percorso e' occupato da qualcosa che non si
    /// puo' scrivere (qui, una cartella al posto del file), `append` non deve ne' lanciare
    /// ne' bloccare il chiamante. La prova che il blocco non si e' fermato e' che queste
    /// righe vengono eseguite fino in fondo, senza crash.
    func testUnreadableFile_doesNotFailTheWrite() throws {
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        let history = try TrashHistory(url: historyURL)
        history.append(blockId: "b1", trashed: [item(path: "/SSD/Foto iPhone/a.jpg")])
        // Nessuna eccezione, nessun blocco: il test arriva qui, ed e' la prova.
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
    }

    // MARK: - Cosa viene registrato

    func testRecordedPaths_areTheOriginalAbsolutePaths() throws {
        let history = try TrashHistory(url: historyURL)
        let paths = ["/Volumes/SSD - Enri/ASUS/foto/recup_dir.37/f1.jpg",
                     "/Volumes/SSD - Enri/ASUS/foto/recup_dir.37/f2.jpg"]
        history.append(blockId: "b1", trashed: paths.map { item(path: $0) })

        let line = try linesOfFile(historyURL)[0]
        let decoded = try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.blockId, "b1")
        XCTAssertEqual(Set(decoded.originalPaths), Set(paths))
    }

    // MARK: - Concorrenza

    /// Due thread che scrivono in contemporanea non devono perdere righe ne' interfogliarle:
    /// ogni riga deve restare JSON valido, e il conteggio totale deve tornare esatto.
    func testAppend_isSafeFromTwoThreads() throws {
        let history = try TrashHistory(url: historyURL)
        let iterations = 40
        let group = DispatchGroup()
        for t in 0..<2 {
            group.enter()
            DispatchQueue.global().async { [self] in
                for i in 0..<iterations {
                    history.append(blockId: "t\(t)-\(i)", trashed: [item(path: "/SSD/A/\(t)-\(i).jpg")])
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)

        let lines = try linesOfFile(historyURL)
        XCTAssertEqual(lines.count, iterations * 2, "nessuna riga persa o interfogliata")
        for line in lines {
            XCTAssertNoThrow(try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(line.utf8)),
                             "riga non decodificabile: una scrittura interfogliata l'avrebbe spezzata")
        }
    }

    // MARK: - Il percorso tenuto (ROADMAP #46, ADR-0017)

    /// Una riga per blocco, e per ogni foto spostata il percorso della copia tenuta, nello
    /// stesso ordine dei percorsi originali (due gruppi diversi nello stesso blocco: l'ordine
    /// conta, un mutante che li scambiasse direbbe a ogni foto la tenuta sbagliata).
    func testKeptPaths_followTheOrderOfTheOriginals() throws {
        let history = try TrashHistory(url: historyURL)
        var a = item(path: "/Volumes/SSD - Enri/Takeout/a.jpg")
        a.keptPath = "Foto iPhone/a.jpg"
        var b = item(path: "/Volumes/SSD - Enri/Takeout 2/b.jpg")
        b.keptPath = "Foto Google Drive/b.jpg"
        let senza = item(path: "/Volumes/SSD - Enri/Other/c.jpg")
        history.append(blockId: "b1", trashed: [a, b, senza])

        let decoded = try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(try linesOfFile(historyURL)[0].utf8))
        XCTAssertEqual(decoded.originalPaths, [a.originalDisplayPath, b.originalDisplayPath, senza.originalDisplayPath])
        XCTAssertEqual(decoded.keptPaths, ["Foto iPhone/a.jpg", "Foto Google Drive/b.jpg", ""])
    }

    /// Le righe gia' scritte prima di questo campo restano leggibili.
    func testOldLineWithoutKeptPaths_stillDecodes() throws {
        let vecchia = #"{"blockId":"b0","trashedAt":770000000,"originalPaths":["/x/a.jpg"]}"#
        let decoded = try JSONDecoder().decode(TrashHistoryEntry.self, from: Data(vecchia.utf8))
        XCTAssertEqual(decoded.originalPaths, ["/x/a.jpg"])
        XCTAssertNil(decoded.keptPaths)
    }
}
