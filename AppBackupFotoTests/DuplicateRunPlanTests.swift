import XCTest
@testable import AppBackupFoto

/// `DuplicateRunPlan` — la divisione di una selezione confermata in blocchi (ADR-0012).
/// Pura: nessun filesystem, nessun I/O.
final class DuplicateRunPlanTests: XCTestCase {

    private func entry(_ path: String, size: Int64 = 1_000, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path), displayPath: path,
                          size: size, mtime: mtime, hash: "h", hashedAt: 1_700_003_600)
    }

    /// Un `Entry` gia' congelato, come arriverebbe da un `DuplicateBatch` vero: un gruppo
    /// con la copia tenuta indicata piu' `leavingCount` copie in eccesso, tutte della stessa
    /// dimensione. `hash` distinto per non confondere due entry fra loro.
    private func runEntry(hash: String, keptSize: Int64 = 1_000, leavingCount: Int) -> DuplicateBatch.Entry {
        let keeper = entry("A-\(hash)/keep.jpg", size: keptSize)
        var members = [keeper]
        for i in 0..<leavingCount {
            members.append(entry("A-\(hash)/leave\(i).jpg", size: keptSize))
        }
        let group = DuplicateGroup(hash: hash, size: keptSize,
                                   members: members.map {
                                       LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                                         mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                                   })
        let choice = DuplicateKeepChoice(keeper: keeper, reason: .oldest, tiedCandidates: 1, tiedPaths: [])
        return DuplicateBatch.Entry(group: group, choice: choice)
    }

    // MARK: - Divisione ai tetti

    func testSplitsAtTheFileCap() {
        // Tre entry da 1 file in eccesso ciascuna, tetto a 2 file: il terzo entry deve
        // aprire un blocco nuovo, non restare nel primo.
        let entries = (0..<3).map { runEntry(hash: "h\($0)", leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries, fileCap: 2, byteCap: .max)
        XCTAssertEqual(plan.blocks.map { $0.count }, [2, 1])
    }

    func testSplitsAtTheByteCap() {
        // Ogni entry libera 1000 byte (1 copia in eccesso da 1000). Tetto a 2000 byte:
        // stesso schema del test sui file, ma sul tetto sui byte.
        let entries = (0..<3).map { runEntry(hash: "h\($0)", keptSize: 1_000, leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries, fileCap: .max, byteCap: 2_000)
        XCTAssertEqual(plan.blocks.map { $0.count }, [2, 1])
    }

    /// Alla soglia esatta il blocco non si divide: `>` e non `>=`, stessa regola di
    /// `DuplicateBatch.exceedsCap`. Due entry da 1 file, tetto a 2: devono stare insieme.
    func testDoesNotSplitAtTheExactBoundary() {
        let entries = (0..<2).map { runEntry(hash: "h\($0)", leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries, fileCap: 2, byteCap: .max)
        XCTAssertEqual(plan.blocks.count, 1)
        XCTAssertEqual(plan.blocks.first?.count, 2)
    }

    /// Nessun gruppo puo' comparire spezzato fra due blocchi: concatenando i blocchi si
    /// deve ritrovare esattamente l'elenco di partenza, un `Entry` intero alla volta.
    func testNeverSplitsAGroupAcrossBlocks() {
        let entries = (0..<7).map { runEntry(hash: "h\($0)", leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries, fileCap: 3, byteCap: .max)
        XCTAssertEqual(plan.blocks.flatMap { $0.map(\.group.hash) }, entries.map(\.group.hash))
        // Nessun blocco deve superare il tetto (qui non c'e' nessun gruppo sopra il tetto
        // da solo, quindi la regola e' netta).
        for block in plan.blocks {
            XCTAssertLessThanOrEqual(block.reduce(0) { $0 + $1.leaving.count }, 3)
        }
    }

    /// Un gruppo la cui sola dimensione supera gia' il tetto ottiene comunque un blocco
    /// tutto suo — non viene scartato, ed e' l'unico caso in cui un blocco supera il tetto.
    func testGroupBiggerThanTheCap_getsABlockOfItsOwn() {
        let huge = runEntry(hash: "huge", leavingCount: 5) // 5 file, tetto a 2
        let normal = runEntry(hash: "normal", leavingCount: 1)
        let plan = DuplicateRunPlan(entries: [huge, normal], fileCap: 2, byteCap: .max)
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertEqual(plan.blocks[0].map(\.group.hash), ["huge"])
        XCTAssertEqual(plan.blocks[0].first?.leaving.count, 5, "il gruppo grande non viene scartato")
        XCTAssertEqual(plan.blocks[1].map(\.group.hash), ["normal"])
    }

    // MARK: - Ordine

    func testBlockOrder_followsThePanelOrder() {
        // Ordine deliberatamente "innaturale" (non per dimensione): il piano non deve
        // riordinare nulla, solo dividere in blocchi cosi' com'e'.
        let entries = ["zeta", "alfa", "medio"].map { runEntry(hash: $0, leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries, fileCap: .max, byteCap: .max)
        XCTAssertEqual(plan.blocks.flatMap { $0.map(\.group.hash) }, ["zeta", "alfa", "medio"])
    }

    // MARK: - Casi limite

    func testEmptySelection_producesNoBlocks() {
        let plan = DuplicateRunPlan(entries: [])
        XCTAssertTrue(plan.blocks.isEmpty)
        XCTAssertEqual(plan.estimatedSeconds, 0)
    }

    func testSingleBlock_whenUnderBothCaps() {
        let entries = (0..<5).map { runEntry(hash: "h\($0)", leavingCount: 1) }
        let plan = DuplicateRunPlan(entries: entries) // tetti di produzione, ampiamente sufficienti
        XCTAssertEqual(plan.blocks.count, 1)
        XCTAssertEqual(plan.blocks.first?.count, 5)
    }

    // MARK: - Stima della durata

    func testEstimatedSeconds_growsWithBytesAndFiles() {
        let small = DuplicateRunPlan(entries: [runEntry(hash: "h1", keptSize: 1_000, leavingCount: 1)])
        let big = DuplicateRunPlan(entries: [runEntry(hash: "h1", keptSize: 1_000_000_000, leavingCount: 50)])
        XCTAssertGreaterThan(big.estimatedSeconds, small.estimatedSeconds)
    }

    func testEstimatedSeconds_isNeverZeroForANonEmptyRun() {
        let plan = DuplicateRunPlan(entries: [runEntry(hash: "h1", keptSize: 1, leavingCount: 1)])
        XCTAssertGreaterThan(plan.estimatedSeconds, 0)
    }

    // MARK: - Determinismo

    func testPlan_isDeterministic() {
        let entries = (0..<9).map { runEntry(hash: "h\($0)", leavingCount: 1) }
        let first = DuplicateRunPlan(entries: entries, fileCap: 3, byteCap: .max)
        let second = DuplicateRunPlan(entries: entries, fileCap: 3, byteCap: .max)
        XCTAssertEqual(first.blocks.map { $0.map(\.group.hash) }, second.blocks.map { $0.map(\.group.hash) })
        XCTAssertEqual(first.estimatedSeconds, second.estimatedSeconds)
    }
}
