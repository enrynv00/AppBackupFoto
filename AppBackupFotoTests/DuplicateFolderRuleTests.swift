import XCTest
@testable import AppBackupFoto

/// `DuplicateFolderRule` — la regola dell'utente «tieni la copia in X, cestina quelle in Y…»
/// (ADR-0011). Pura: nessun filesystem, nessun database.
///
/// Non è un motore di decisione: `covers` dice solo se un gruppo rientra nella regola. Chi
/// vince fra i sopravvissuti resta compito esclusivo di `duplicateKeepChoice` (Task 4) — qui
/// non si nomina mai un sopravvissuto (regola 3 dei piani di questo progetto).
final class DuplicateFolderRuleTests: XCTestCase {

    private func entry(_ path: String, size: Int64 = 1_000, mtime: Double = 1_700_000_000,
                       hash: String = "h") -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path), displayPath: path,
                          size: size, mtime: mtime, hash: hash, hashedAt: 1_700_003_600)
    }

    private func group(_ members: [LibraryIndexEntry], hash: String = "h") -> DuplicateGroup {
        DuplicateGroup(hash: hash, size: members.map(\.size).min() ?? 0,
                       members: members.map {
                           LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                             mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                       })
    }

    private func rule(keepIn: String, trashIn: Set<String>) -> DuplicateFolderRule {
        DuplicateFolderRule(keepIn: normalizedIndexKey(keepIn), trashIn: Set(trashIn.map(normalizedIndexKey)))
    }

    // MARK: - Coperto / non coperto

    func testCovers_groupSplitBetweenKeepAndTrashFolders() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        XCTAssertTrue(r.covers(g))
    }

    func testDoesNotCover_groupWithACopyInAThirdFolder() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg"), entry("Other/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        XCTAssertFalse(r.covers(g))
    }

    func testDoesNotCover_groupWithNoCopyInTheKeepFolder() {
        let g = group([entry("Takeout/a.jpg"), entry("Takeout 2/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout", "Takeout 2"])
        XCTAssertFalse(r.covers(g))
    }

    func testCovers_groupWithSeveralCopiesInTheKeepFolder() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Foto iPhone/b.jpg"), entry("Takeout/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        XCTAssertTrue(r.covers(g))
    }

    /// Niente da cestinare: se coperto, il pannello proporrebbe un blocco vuoto per questo
    /// gruppo. Non è coperto, per costruzione.
    func testDoesNotCover_groupEntirelyInsideTheKeepFolder() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Foto iPhone/b.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        XCTAssertFalse(r.covers(g))
    }

    // MARK: - Matching

    /// ExFAT e' case-insensitive e non normalizza l'Unicode: la regola confronta chiavi
    /// normalizzate (minuscole, NFC), mai `displayPath`.
    func testMatching_isOnNormalizedKeys_notOnDisplayPath() {
        let nfd = "ASUS".decomposedStringWithCanonicalMapping // forma NFD
        let g = group([entry("asus/a.jpg"), entry("\(nfd)/foto/b.jpg")])
        let r = rule(keepIn: "ASUS", trashIn: [])
        // Nessuna cartella da cestinare: il gruppo e' interamente nella cartella da tenere,
        // quindi non e' coperto — ma la normalizzazione deve comunque riconoscere che
        // "asus" e la forma NFD sono la STESSA cartella di "ASUS" (altrimenti "hasKeepMember"
        // sarebbe vero solo per uno dei due membri e l'altro farebbe fallire la copertura
        // per "terza cartella"). Verifichiamo questo con una seconda regola che cestina.
        XCTAssertFalse(r.covers(g)) // interamente dentro keepIn: nessuna copia da cestinare

        let r2 = rule(keepIn: "ASUS", trashIn: ["Takeout"])
        let g2 = group([entry("asus/a.jpg"), entry("Takeout/a.jpg")])
        XCTAssertTrue(r2.covers(g2))
    }

    /// `ASUS/foto/x.jpg` conta come `ASUS`, mai come `ASUS/foto`.
    func testMatching_isOnTheTopLevelFolderOnly() {
        let g = group([entry("ASUS/foto/recup_dir.37/f1.jpg"), entry("Takeout/f1.jpg")])
        let r = rule(keepIn: "ASUS", trashIn: ["Takeout"])
        XCTAssertTrue(r.covers(g))

        let wrong = rule(keepIn: "ASUS/foto", trashIn: ["Takeout"])
        XCTAssertFalse(wrong.covers(g)) // "ASUS/foto" non e' una cartella di primo livello
    }

    /// Un file sciolto in radice non appartiene a nessuna cartella di primo livello: non e'
    /// coperto da nessuna regola.
    func testFileAtTheRoot_belongsToNoTopLevelFolder() {
        let g = group([entry("a.jpg"), entry("Takeout/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        XCTAssertFalse(r.covers(g))
    }

    // MARK: - Regole degeneri

    func testEmptyRule_coversNothing() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")])
        XCTAssertFalse(DuplicateFolderRule(keepIn: "", trashIn: []).covers(g))
        XCTAssertFalse(DuplicateFolderRule(keepIn: normalizedIndexKey("Foto iPhone"), trashIn: []).covers(g))
    }

    /// Una regola contraddittoria (la stessa cartella da tenere e da cestinare) non si
    /// applica: non si "interpreta al meglio".
    func testKeepFolderAlsoListedAsTrash_isRejected() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")])
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Foto iPhone", "Takeout"])
        XCTAssertFalse(r.covers(g))
    }

    // MARK: - Persistenza

    func testEncodedRule_decodesIdentical() throws {
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout", "Takeout 2"])
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(DuplicateFolderRule.self, from: data)
        XCTAssertEqual(r, decoded)
    }

    func testSaveThenLoad_roundTrips() throws {
        let defaults = try makeIsolatedDefaults()
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        saveDuplicateFolderRule(r, defaults: defaults)
        XCTAssertEqual(loadDuplicateFolderRule(defaults: defaults), r)
    }

    func testSaveNil_removesTheStoredRule() throws {
        let defaults = try makeIsolatedDefaults()
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        saveDuplicateFolderRule(r, defaults: defaults)
        saveDuplicateFolderRule(nil, defaults: defaults)
        XCTAssertNil(loadDuplicateFolderRule(defaults: defaults))
    }

    /// Un valore corrotto decodifica a "nessuna regola", mai a un crash: stessa disciplina
    /// di uno schema inatteso sull'indice (ADR-0002).
    func testGarbageInDefaults_decodesToNoRule() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("non e' JSON valido".data(using: .utf8)!, forKey: duplicateFolderRuleDefaultsKey)
        XCTAssertNil(loadDuplicateFolderRule(defaults: defaults))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let name = "DuplicateFolderRuleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
