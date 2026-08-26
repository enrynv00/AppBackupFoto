//
//  ImportDedupTests.swift
//  AppBackupFotoTests
//
//  Dedup per contenuto durante un import (roadmap #31, Task 5).
//
//  E' il percorso AD ALTO DANNO della feature: saltare un file per errore significa
//  una foto che non arriva mai sull'SSD, in silenzio, senza errori a schermo. I test
//  qui dentro blindano le due regole che lo tengono in piedi:
//   - un doppione si dichiara SOLO dopo aver riletto e rihashato il candidato su disco
//     (ADR-0003): nessun hash memorizzato — ne' dell'indice ne' della sessione — e'
//     creduto sulla parola;
//   - la dimensione da sola non decide MAI (testSameSizeDifferentContentAreBothCopied).
//
//  Niente mock: si lavora su directory temporanee reali, come
//  FileSyncerZeroOverwriteTests.
//

import XCTest
@testable import AppBackupFoto

final class ImportDedupTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportDedupTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil; srcDir = nil; dstDir = nil
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

    /// Esegue un import con il dedup collegato esattamente come lo collega `runImport`.
    /// `session` e' esplicita e senza valore di default: un default
    /// `ImportSessionIndex()` viene valutato in un contesto isolato al MainActor
    /// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) e produce un warning.
    /// `hashFunction` usa il seam gia' esistente su `FileSyncer.init` (vedi il commento
    /// accanto alla proprieta'): i tre esiti della verifica post-copia — verificato,
    /// mismatch, non verificabile — non sono producibili su file veri senza una corsa fra
    /// thread, e un test basato su una corsa e' verde col bug meta' delle volte.
    private func runSync(store: LibraryIndexStore? = nil,
                         libraryRoot: URL? = nil,
                         session: ImportSessionIndex,
                         hashFunction: ((URL) -> String?)? = nil)
        async throws -> FileSyncer.SyncResult {
        let syncer = hashFunction.map { FileSyncer(hashFunction: $0) } ?? FileSyncer()
        return try await syncer.sync(from: srcDir, to: dstDir, deep: false,
            onStatus: { _ in },
            onProgress: { _ in },
            onCurrentFile: { _ in },
            isDuplicate: { url in
                BackupRunner.isAlreadyInLibrary(url: url, store: store,
                                                session: session, libraryRoot: libraryRoot)
            },
            onCopied: { copied, hash in
                // Il filtro `IndexableKind` sta nella closure, non in `FileSyncer`, ed e'
                // ricopiato qui perche' questa funzione promette di collegare il dedup
                // "esattamente come lo collega `runImport`": se le due divergono, i test
                // proteggono un cablaggio che in app non esiste.
                guard IndexableKind.of(url: copied) != .notIndexable else { return }
                session.record(hash: hash, at: copied)
            })
    }

    /// L'identita' dei contatori: ogni file esaminato finisce in una e una sola casella.
    /// `duplicatesSkipped` e' un sottoinsieme di `skipped`, non una casella in piu' —
    /// se lo si dimenticasse dentro `skipped` la barra di avanzamento non tornerebbe.
    private func assertCountersAddUp(_ r: FileSyncer.SyncResult,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.copied + r.skipped + r.errors + r.hashErrors + r.copiedUnverified,
                       r.done, "i contatori non tornano: \(r)", file: file, line: line)
        XCTAssertLessThanOrEqual(r.duplicatesSkipped, r.skipped,
                                 "un duplicato deve contare anche fra gli skipped",
                                 file: file, line: line)
    }

    // MARK: - ImportSessionIndex (logica pura)

    func testSessionIndexIgnoresUnknownSize() {
        let session = ImportSessionIndex()
        XCTAssertTrue(session.candidates(withSize: 1234).isEmpty)
    }

    func testSessionIndexRecordsAndFindsBySize() throws {
        let url = try writeFile(srcDir.appendingPathComponent("a.jpg"), "otto byt")
        let session = ImportSessionIndex()
        session.record(hash: "hash-a", at: url)

        let found = session.candidates(withSize: try fileSize(url))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.hash, "hash-a")
        XCTAssertEqual(found.first?.url, url)
    }

    func testSessionIndexKeepsDistinctHashesOfSameSize() throws {
        // E' il bucket a dover reggere la collisione di dimensione, non l'hash: due file
        // di pari dimensione e contenuto diverso devono convivere ed essere entrambi
        // recuperabili, altrimenti il secondo "sparirebbe" dietro il primo.
        let a = try writeFile(srcDir.appendingPathComponent("a.jpg"), "AAAAAAAA")
        let b = try writeFile(srcDir.appendingPathComponent("b.jpg"), "BBBBBBBB")
        XCTAssertEqual(try fileSize(a), try fileSize(b))

        let session = ImportSessionIndex()
        session.record(hash: "hash-a", at: a)
        session.record(hash: "hash-b", at: b)

        let found = session.candidates(withSize: try fileSize(a))
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.hash)), ["hash-a", "hash-b"])
        XCTAssertEqual(Set(found.map(\.url)), [a, b])
    }

    // MARK: - Dedup interno allo stesso import

    func testIntraImportDuplicateIsCopiedOnce() async throws {
        // Stesso contenuto, sottocartelle e nomi diversi: l'indice persistito non puo'
        // saperlo (viene aggiornato solo a import finito), lo sa solo la sessione.
        try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "contenuto identico")
        try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "contenuto identico")

        let result = try await runSync(session: ImportSessionIndex())

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.duplicatesSkipped, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.errors, 0)
        XCTAssertEqual(result.hashErrors, 0)
        XCTAssertEqual(result.copiedUnverified, 0)
        XCTAssertEqual(result.changedSkipped, 0, "un doppione non e' un file 'cambiato' (#13)")
        XCTAssertEqual(result.done, 2, "anche il doppione deve far avanzare la barra")
        assertCountersAddUp(result)

        let copiedOne = fm.fileExists(atPath: dstDir.appendingPathComponent("A/uno.jpg").path)
        let copiedTwo = fm.fileExists(atPath: dstDir.appendingPathComponent("B/due.jpg").path)
        XCTAssertTrue(copiedOne != copiedTwo, "a destinazione deve esistere uno solo dei due")
    }

    func testSameSizeDifferentContentAreBothCopied() async throws {
        // IL TEST DI SICUREZZA. Due file di dimensione identica ma contenuto diverso
        // superano lo stadio 1 (la dimensione) e devono essere copiati ENTRAMBI. Se un
        // giorno qualcuno degradasse il confronto alla sola dimensione, qui si perderebbe
        // una foto: questo test deve fallire prima che accada.
        try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "AAAAAAAA")
        try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "BBBBBBBB")

        let result = try await runSync(session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 0)
        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.done, 2)
        assertCountersAddUp(result)

        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("A/uno.jpg"), encoding: .utf8),
                       "AAAAAAAA")
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("B/due.jpg"), encoding: .utf8),
                       "BBBBBBBB")
    }

    // MARK: - Rilettura del candidato (ADR-0003)

    func testSessionHashIsNotTrustedWithoutRereadingTheCandidate() async throws {
        // ADR-0003, nota del 2026-08-25: nemmeno l'hash calcolato da questo stesso
        // processo gode di una fiducia diversa. Qui il file copiato viene alterato dopo
        // la registrazione (a parita' di dimensione, cosi' lo stadio 1 passa comunque):
        // la rilettura se ne accorge e il file in arrivo viene copiato, non saltato.
        let sourceContent = "AAAAAAAA"
        try writeFile(srcDir.appendingPathComponent("uno.jpg"), sourceContent)

        let already = try writeFile(dstDir.appendingPathComponent("gia-copiato.jpg"), sourceContent)
        let session = ImportSessionIndex()
        session.record(hash: try XCTUnwrap(sha256(of: already)), at: already)
        // Il candidato cambia contenuto sotto i nostri piedi: l'hash in memoria e' stantio.
        try Data("ZZZZZZZZ".utf8).write(to: already)

        let result = try await runSync(session: session)

        XCTAssertEqual(result.duplicatesSkipped, 0, "un hash stantio non deve far saltare una foto")
        XCTAssertEqual(result.copied, 1)
        assertCountersAddUp(result)
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("uno.jpg"), encoding: .utf8),
                       sourceContent)
    }

    func testFileAlreadyInPersistedIndexIsSkipped() async throws {
        // Reimport di una sorgente gia' importata in passato: la copia sta nella libreria
        // (fuori dalla cartella di destinazione di questo import) e l'indice la conosce.
        let library = root.appendingPathComponent("library", isDirectory: true)
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "una foto vera")
        try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "una foto vera")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("Foto/vecchia.jpg"),
                                            displayPath: "Foto/vecchia.jpg",
                                            size: try fileSize(existing),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: existing)),
                                            hashedAt: 1_700_003_600)])

        let result = try await runSync(store: store, libraryRoot: library, session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 1)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.done, 1)
        assertCountersAddUp(result)
        XCTAssertFalse(fm.fileExists(atPath: dstDir.appendingPathComponent("nuova.jpg").path))
    }

    func testStaleIndexHashIsNotTrustedWithoutRereadingTheCandidate() async throws {
        // Lo stesso di sopra, ma la entry dell'indice e' STANTIA: dice che quel percorso
        // contiene la foto in arrivo, mentre sul disco c'e' altro (mtime riscrivibile da
        // userspace, inode non affidabili su ExFAT). Senza la rilettura di ADR-0003 la
        // foto verrebbe saltata e non arriverebbe mai sull'SSD.
        let library = root.appendingPathComponent("library", isDirectory: true)
        let candidate = try writeFile(library.appendingPathComponent("Foto/altra.jpg"), "ZZZZZZZZ")
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "AAAAAAAA")
        XCTAssertEqual(try fileSize(candidate), try fileSize(incoming),
                       "pari dimensione: lo stadio 1 deve passare, a decidere e' l'hash")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("Foto/altra.jpg"),
                                            displayPath: "Foto/altra.jpg",
                                            size: try fileSize(incoming),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: incoming)),
                                            hashedAt: 1_700_003_600)])

        let result = try await runSync(store: store, libraryRoot: library, session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 0, "un hash stantio non deve far saltare una foto")
        XCTAssertEqual(result.copied, 1)
        assertCountersAddUp(result)
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("nuova.jpg"), encoding: .utf8),
                       "AAAAAAAA")
        // La libreria non viene toccata: la feature e' in sola lettura sulla sorgente.
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "ZZZZZZZZ")
    }

    // MARK: - Ordine dei controlli e fiducia nella verifica post-copia

    func testExistingDifferentDestination_isZeroOverwriteNotDuplicate() async throws {
        // Lo zero-overwrite resta la PRIMA regola: se a destinazione c'e' gia' un file
        // diverso, quel file e' `changedSkipped` (#13) anche quando il contenuto in
        // arrivo esiste altrove in libreria. Se qualcuno spostasse il controllo di
        // duplicato prima di quello di esistenza, la stessa situazione verrebbe
        // riportata come "gia' in libreria" e il caso zero-overwrite sparirebbe dal
        // riepilogo — l'utente non saprebbe piu' di avere un file locale divergente.
        let library = root.appendingPathComponent("library", isDirectory: true)
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "foto in arrivo")
        try writeFile(srcDir.appendingPathComponent("a.jpg"), "foto in arrivo")
        try writeFile(dstDir.appendingPathComponent("a.jpg"), "altro contenuto locale")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("Foto/vecchia.jpg"),
                                            displayPath: "Foto/vecchia.jpg",
                                            size: try fileSize(existing),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: existing)),
                                            hashedAt: 1_700_003_600)])

        let result = try await runSync(store: store, libraryRoot: library,
                                       session: ImportSessionIndex())

        XCTAssertEqual(result.changedSkipped, 1, "zero-overwrite e' la prima regola")
        XCTAssertEqual(result.duplicatesSkipped, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.copied, 0)
        assertCountersAddUp(result)
        // Il file locale non e' stato toccato.
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("a.jpg"), encoding: .utf8),
                       "altro contenuto locale")
    }

    func testUnverifiableCopy_isNotRecordedAsDedupCandidate() async throws {
        // La verifica d'integrita' non conclude (uno dei due hash e' `nil`): la copia
        // finisce in `copiedUnverified`, ed e' esattamente la copia di cui non ci si puo'
        // fidare. Registrarla come candidato di dedup farebbe saltare il file successivo
        // sulla parola di una verifica mai avvenuta.
        try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "contenuto identico")
        try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "contenuto identico")

        let dstPath = dstDir.path
        let result = try await runSync(session: ImportSessionIndex(),
                                       hashFunction: { url in
                                           // La destinazione non e' rileggibile: verifica
                                           // impossibile. La sorgente si legge davvero,
                                           // cosi' l'hash "buono" esiste ed e' quello che
                                           // un mutante registrerebbe.
                                           url.path.hasPrefix(dstPath) ? nil : sha256(of: url)
                                       })

        XCTAssertEqual(result.copiedUnverified, 2)
        XCTAssertEqual(result.duplicatesSkipped, 0, "una copia non verificata non e' un candidato")
        XCTAssertEqual(result.copied, 0)
        assertCountersAddUp(result)
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("A/uno.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("B/due.jpg").path))
    }

    func testMismatchedCopy_isNotRecordedAsDedupCandidate() async throws {
        // Stesso principio, esito diverso: la verifica conclude e dice MISMATCH. L'hash
        // di una copia non integra e' proprio quello di cui non ci si puo' fidare.
        try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "contenuto identico")
        try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "contenuto identico")

        let dstPath = dstDir.path
        let result = try await runSync(session: ImportSessionIndex(),
                                       hashFunction: { url in
                                           url.path.hasPrefix(dstPath)
                                               ? "0000000000000000000000000000000000000000000000000000000000000000"
                                               : sha256(of: url)
                                       })

        XCTAssertEqual(result.hashErrors, 2)
        XCTAssertEqual(result.duplicatesSkipped, 0, "una copia con mismatch non e' un candidato")
        XCTAssertEqual(result.copied, 0)
        assertCountersAddUp(result)
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("A/uno.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("B/due.jpg").path))
    }

    func testUnreadableSourceFile_isNeverDeclaredDuplicate() async throws {
        // Un file che non riusciamo a leggere non e' un doppione: e' un errore, e deve
        // arrivare all'utente come tale. Se `isAlreadyInLibrary` rispondesse "si'" quando
        // l'hash della sorgente non e' calcolabile, un file illeggibile verrebbe
        // archiviato come "gia' in libreria" — cioe' il guasto sparirebbe dal riepilogo
        // e la foto non arriverebbe mai sull'SSD. Il verso sicuro e' il contrario: nel
        // dubbio si copia (e qui la copia fallisce e viene contata).
        let library = root.appendingPathComponent("library", isDirectory: true)
        let existing = try writeFile(library.appendingPathComponent("Foto/vecchia.jpg"), "AAAAAAAA")
        // Contenuto IDENTICO alla copia gia' in libreria: e' il caso in cui una
        // implementazione frettolosa sarebbe tentata di rispondere "duplicato".
        let incoming = try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "AAAAAAAA")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("Foto/vecchia.jpg"),
                                            displayPath: "Foto/vecchia.jpg",
                                            size: try fileSize(existing),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: existing)),
                                            hashedAt: 1_700_003_600)])

        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: incoming.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: incoming.path) }
        XCTAssertNil(sha256(of: incoming), "precondizione: la sorgente non deve essere leggibile")

        let result = try await runSync(store: store, libraryRoot: library,
                                       session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 0, "illeggibile non vuol dire duplicato")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.errors, 1, "il guasto deve restare visibile")
        assertCountersAddUp(result)
    }

    // MARK: - Solo i media partecipano al dedup

    // Il doc-comment di `IndexableKind` e la spec dicono la stessa cosa: un file non
    // classificato viene COPIATO, mai saltato. Il ramo dell'indice persistito lo rispettava
    // gia' (`LibraryIndexer.scan` scarta i `.notIndexable` prima di indicizzarli), il ramo di
    // sessione no. I sidecar da 0 byte sono il caso deterministico: sono tutti byte-identici,
    // quindi senza il filtro il secondo e il terzo diventano doppioni del primo e sull'SSD ne
    // arriva UNO SOLO, col nome sbagliato rispetto alle foto rimaste senza.
    func testNonMediaSidecars_areAllCopiedNeverDeduplicated() async throws {
        for n in ["0001", "0002", "0003"] {
            try writeFile(srcDir.appendingPathComponent("IMG_\(n).JPG"), "foto \(n)")
            try writeFile(srcDir.appendingPathComponent("IMG_\(n).AAE"), "")   // 0 byte, tutti identici
        }

        let result = try await runSync(session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 0, "un sidecar non-media non e' mai un doppione")
        XCTAssertEqual(result.copied, 6)
        XCTAssertEqual(result.done, 6)
        assertCountersAddUp(result)
        for n in ["0001", "0002", "0003"] {
            XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("IMG_\(n).AAE").path),
                          "IMG_\(n).AAE non e' arrivato a destinazione")
        }
    }

    // La guardia sta in DUE punti e servono entrambi. Questo prova quello sul lato "salto",
    // isolato dal filtro su `onCopied`: se l'indice — di sessione o persistito — contenesse
    // per qualunque ragione un non-media, non dovrebbe comunque poter far saltare un file.
    // Senza questo test il mutante che toglie la guardia da `isAlreadyInLibrary` sopravvive,
    // perche' il filtro su `onCopied` gli impedisce di manifestarsi (misurato).
    func testNonMediaFile_isNeverDeclaredDuplicate_evenIfTheIndexKnowsIt() throws {
        let alreadyThere = try writeFile(dstDir.appendingPathComponent("IMG_0001.AAE"), "")
        let incoming = try writeFile(srcDir.appendingPathComponent("IMG_0002.AAE"), "")
        let session = ImportSessionIndex()
        session.record(hash: try XCTUnwrap(sha256(of: alreadyThere)), at: alreadyThere)

        XCTAssertFalse(BackupRunner.isAlreadyInLibrary(url: incoming, store: nil,
                                                       session: session, libraryRoot: nil),
                       "un non-media non e' mai un doppione, nemmeno se l'indice lo conosce")
    }

    // L'altra meta' della simmetria: il file non-media non deve nemmeno essere RICORDATO.
    // L'indice persistito non contiene mai non-media; nemmeno quello di sessione deve.
    func testNonMediaFile_isNotRecordedInTheSessionIndex() async throws {
        try writeFile(srcDir.appendingPathComponent("IMG_0001.JPG"), "una foto")
        try writeFile(srcDir.appendingPathComponent("IMG_0001.AAE"), "")

        let session = ImportSessionIndex()
        let result = try await runSync(session: session)

        XCTAssertEqual(result.copied, 2)
        XCTAssertTrue(session.candidates(withSize: 0).isEmpty,
                      "un sidecar da 0 byte non deve entrare nell'indice di sessione")
        XCTAssertEqual(session.candidates(withSize: try fileSize(srcDir.appendingPathComponent("IMG_0001.JPG"))).count, 1,
                       "la foto invece si")
    }

    // MARK: - Confinamento del candidato dell'indice

    // `libraryRoot.appendingPathComponent(displayPath)` non confina niente: un `displayPath`
    // relativo con `..` risolve FUORI dalla libreria. Oggi `LibraryIndexer` non produce
    // percorsi simili, ma il commento di `normalizedIndexKey` si appoggia esplicitamente a
    // quell'assunzione, e un'assunzione verificata da nulla e' gia' costata tre bug qui.
    func testIndexCandidateOutsideTheLibraryRoot_isIgnoredAndTheFileIsCopied() async throws {
        let library = root.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        // Fuori dalla libreria, ma raggiungibile da dentro risalendo con `..`.
        let outside = try writeFile(root.appendingPathComponent("fuori/gia-vista.jpg"), "una foto vera")
        try writeFile(srcDir.appendingPathComponent("nuova.jpg"), "una foto vera")

        let store = try LibraryIndexStore(url: root.appendingPathComponent("index.sqlite"))
        try store.upsert([LibraryIndexEntry(path: normalizedIndexKey("../fuori/gia-vista.jpg"),
                                            displayPath: "../fuori/gia-vista.jpg",
                                            size: try fileSize(outside),
                                            mtime: 1_700_000_000,
                                            hash: try XCTUnwrap(sha256(of: outside)),
                                            hashedAt: 1_700_003_600)])

        let result = try await runSync(store: store, libraryRoot: library, session: ImportSessionIndex())

        XCTAssertEqual(result.duplicatesSkipped, 0,
                       "un candidato fuori dalla root non e' un doppione: nel dubbio si copia")
        XCTAssertEqual(result.copied, 1)
        assertCountersAddUp(result)
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("nuova.jpg").path))
    }

    // MARK: - Lato giusto della copia, dimensione illeggibile

    // `onCopied` deve registrare la DESTINAZIONE, non la sorgente. Registrando la sorgente la
    // rilettura di ADR-0003 finirebbe sul lato sbagliato della copia: si riverificherebbe il
    // file sulla scheda SD invece della copia in libreria. Il guasto si vede solo se la copia
    // sparisce dopo la verifica (SSD smontato a metà import): il file identico successivo
    // verrebbe confrontato con la sorgente, che e' ancora li' e ancora identica, e saltato —
    // zero copie sull'SSD invece di due.
    func testCandidateIsTheCopyNotTheSource_soALostCopyIsRecopied() async throws {
        try writeFile(srcDir.appendingPathComponent("A/uno.jpg"), "contenuto identico")
        try writeFile(srcDir.appendingPathComponent("B/due.jpg"), "contenuto identico")

        let session = ImportSessionIndex()
        let syncer = FileSyncer()
        let firstCopy = dstDir.appendingPathComponent("A/uno.jpg")
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
            onStatus: { _ in },
            onProgress: { _ in },
            onCurrentFile: { _ in },
            isDuplicate: { url in
                // La prima copia sparisce prima che il secondo file venga esaminato: il
                // candidato registrato non esiste piu' sul disco.
                try? self.fm.removeItem(at: firstCopy)
                return BackupRunner.isAlreadyInLibrary(url: url, store: nil,
                                                       session: session, libraryRoot: nil)
            },
            onCopied: { copied, hash in session.record(hash: hash, at: copied) })

        XCTAssertEqual(result.duplicatesSkipped, 0,
                       "il candidato e' la copia, non la sorgente: se la copia non c'e' piu' non e' un doppione")
        XCTAssertEqual(result.copied, 2)
        assertCountersAddUp(result)
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("B/due.jpg").path))
    }

    // Gemello di `testUnreadableSourceFile_isNeverDeclaredDuplicate`, un guard piu' su:
    // "dimensione illeggibile" non puo' voler dire "e' un doppione". Nessun dato mancante
    // autorizza a saltare una foto.
    func testUnreadableSizeIsNeverDeclaredDuplicate() throws {
        let missing = srcDir.appendingPathComponent("sparito.jpg")   // non esiste: nessuna dimensione
        XCTAssertFalse(BackupRunner.isAlreadyInLibrary(url: missing, store: nil,
                                                       session: ImportSessionIndex(), libraryRoot: nil))
    }
}
