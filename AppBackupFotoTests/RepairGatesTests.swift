import XCTest
@testable import AppBackupFoto

/// La riparazione (ROADMAP #45) scrive su SSD, HDD o Cubbit: non parte durante un backup, una
/// lettura dell'elenco, un inventario, uno spostamento nel Cestino o un annullamento, e
/// viceversa. Stesso schema di `isInventorying`: parametro `isRepairing` SENZA default nei
/// cancelli esistenti, piu' `RepairStartGate` per il verso opposto.
final class RepairGatesTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum", "quarantena"]

    private func assertNoJargon(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        let t = (text ?? "").lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text ?? "")»", file: file, line: line) }
    }

    // MARK: - Verso 1: durante una riparazione non parte nient'altro

    func testJobsDoNotStart_whileRepairing() {
        let r = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                           isInventorying: false, isRepairing: true, isAligning: false)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
        let others = [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: true, isRepairing: false, isAligning: false)]
        XCTAssertFalse(others.contains(r), "una frase sua")
    }

    func testReadingTheList_doesNotStart_whileRepairing() {
        let r = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false,
                                                       isRestoringFromTrash: false, isInventorying: false, isRepairing: true, isAligning: false)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testTrashing_doesNotStart_whileRepairing() {
        let r = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                     isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                     isInventorying: false, isRepairing: true, isAligning: false)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testUndo_doesNotStart_whileRepairing() {
        let summary = RestorableBatchSummary(pendingCount: 1, batchCount: 1, trashedAt: Date())
        let r = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                    isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                    summary: summary, hasEverTrashed: true,
                                                    isInventorying: false, isRepairing: true, isAligning: false)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    func testInventory_doesNotStart_whileRepairing() {
        let r = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                 isRestoringFromTrash: false, isInventorying: false, isRepairing: true, isAligning: false,
                                                 ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        XCTAssertTrue(r?.contains("riparando") == true)
        assertNoJargon(r)
    }

    /// Un'operazione in corso viene prima dei dischi scollegati anche per l'inventario.
    func testInventory_repairComesBeforeMissingDisks() {
        let r = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                 isRestoringFromTrash: false, isInventorying: false, isRepairing: true, isAligning: false,
                                                 ssdMounted: false, hddMounted: false, hasCubbitConfig: false)
        XCTAssertTrue(r?.contains("riparando") == true)
    }

    // MARK: - Verso 2: «Ripara…» non parte durante le altre operazioni

    private func repair(isRunning: Bool = false, isIndexing: Bool = false, isTrashingDuplicates: Bool = false,
                        isRestoringFromTrash: Bool = false, isInventorying: Bool = false, isRepairing: Bool = false, isAligning: Bool = false,
                        ssdMounted: Bool = true, hddMounted: Bool = true, hasCubbitConfig: Bool = true) -> String? {
        RepairStartGate.blockedReason(isRunning: isRunning, isIndexing: isIndexing,
                                      isTrashingDuplicates: isTrashingDuplicates,
                                      isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying,
                                      isRepairing: isRepairing, isAligning: isAligning, ssdMounted: ssdMounted, hddMounted: hddMounted,
                                      hasCubbitConfig: hasCubbitConfig)
    }

    func testRepair_canStart_whenNothingIsInTheWay() {
        XCTAssertNil(repair())
    }

    func testRepair_eachConditionBlocksWithItsOwnReason() {
        let all = [repair(isRunning: true), repair(isIndexing: true), repair(isTrashingDuplicates: true),
                   repair(isRestoringFromTrash: true), repair(isInventorying: true), repair(isRepairing: true, isAligning: false),
                   repair(ssdMounted: false), repair(hddMounted: false), repair(hasCubbitConfig: false)]
        XCTAssertTrue(all.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(all.compactMap { $0 }).count, all.count, "nove motivi, nove frasi diverse")
        for r in all + [RepairStartGate.cubbitUnreachable] { assertNoJargon(r) }
        XCTAssertTrue(repair(ssdMounted: false)!.contains("SSD"))
        XCTAssertTrue(repair(hddMounted: false)!.contains("HDD"))
    }

    /// Precedenza: un'altra riparazione prima di tutto, le operazioni prima dei dischi.
    func testRepair_precedence() {
        XCTAssertEqual(repair(isRunning: true, isTrashingDuplicates: true, isRepairing: true, isAligning: false), repair(isRepairing: true, isAligning: false))
        XCTAssertEqual(repair(isRunning: true, isInventorying: true), repair(isInventorying: true))
        XCTAssertEqual(repair(isRunning: true, ssdMounted: false), repair(isRunning: true))
        XCTAssertEqual(repair(ssdMounted: false, hddMounted: false), repair(ssdMounted: false))
        XCTAssertEqual(repair(hddMounted: false, hasCubbitConfig: false), repair(hddMounted: false))
    }
}
