import XCTest
@testable import AppBackupFoto

/// Mutua esclusione del progetto 4 (ROADMAP #47, ADR-0019) nei due versi: una corsa su HDD o
/// Cubbit ferma backup, lettura dell'elenco, inventario, riparazione, spostamenti e annullamenti
/// dell'SSD; e non parte mentre una di quelle e' in corso. Parametro `isAligning` SENZA default:
/// un cancello che lo dimentica non compila.
final class AlignmentGatesTests: XCTestCase {
    private let jargon = ["hash", "etag", "md5", "bucket", "versionid", "delete", "indice", "scansione", "cache"]

    private func assertNoJargon(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let t = text?.lowercased() else { return XCTFail("nessun motivo", file: file, line: line) }
        for w in jargon { XCTAssertFalse(t.contains(w), "«\(w)» in: \(t)", file: file, line: line) }
    }

    // MARK: - Il verso «la corsa ferma le altre»

    func testJobsDoNotStartDuringAnAlignment() {
        let r = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                           isInventorying: false, isRepairing: false, isAligning: true)
        XCTAssertNotNil(r)
        XCTAssertTrue(r?.contains("HDD o Cubbit") ?? false)
        assertNoJargon(r)
    }

    func testListReadingDoesNotStartDuringAnAlignment() {
        let r = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false,
                                                       isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                       isAligning: true)
        XCTAssertNotNil(r)
        assertNoJargon(r)
    }

    func testSSDTrashAndUndoDoNotStartDuringAnAlignment() {
        let trash = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                         isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                         isInventorying: false, isRepairing: false, isAligning: true)
        let undo = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                       isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                       summary: RestorableBatchSummary(pendingCount: 1, batchCount: 1, trashedAt: Date()),
                                                       hasEverTrashed: true, isInventorying: false, isRepairing: false, isAligning: true)
        XCTAssertNotNil(trash)
        XCTAssertNotNil(undo)
        assertNoJargon(trash)
        assertNoJargon(undo)
    }

    func testInventoryAndRepairDoNotStartDuringAnAlignment() {
        let inv = InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                   isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                   isAligning: true, ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        let rep = RepairStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                isAligning: true, ssdMounted: true, hddMounted: true, hasCubbitConfig: true)
        XCTAssertNotNil(inv)
        XCTAssertNotNil(rep)
        assertNoJargon(inv)
        assertNoJargon(rep)
    }

    func testWithoutAnAlignment_theOtherGatesSayNothingNew() {
        XCTAssertNil(JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                isInventorying: false, isRepairing: false, isAligning: false))
        XCTAssertNil(InventoryStartGate.blockedReason(isRunning: false, isIndexing: false, isTrashingDuplicates: false,
                                                      isRestoringFromTrash: false, isInventorying: false, isRepairing: false,
                                                      isAligning: false, ssdMounted: true, hddMounted: true, hasCubbitConfig: true))
    }

    // MARK: - Il verso «le altre fermano la corsa»

    private func gate(_ archive: AlignmentArchive = .hdd, isRunning: Bool = false, isIndexing: Bool = false,
                      isTrashingDuplicates: Bool = false, isRestoringFromTrash: Bool = false, isInventorying: Bool = false,
                      isRepairing: Bool = false, isAligning: Bool = false, ssdMounted: Bool = true, hddMounted: Bool = true,
                      hasCubbitConfig: Bool = true) -> String? {
        AlignmentStartGate.blockedReason(archive: archive, isRunning: isRunning, isIndexing: isIndexing,
                                         isTrashingDuplicates: isTrashingDuplicates, isRestoringFromTrash: isRestoringFromTrash,
                                         isInventorying: isInventorying, isRepairing: isRepairing, isAligning: isAligning,
                                         ssdMounted: ssdMounted, hddMounted: hddMounted, hasCubbitConfig: hasCubbitConfig)
    }

    func testAlignmentStarts_onlyWhenNothingElseRuns() {
        XCTAssertNil(gate(.hdd))
        XCTAssertNil(gate(.cubbit))
    }

    func testEveryOtherOperation_blocksTheAlignment_withItsOwnReason() {
        let reasons = [gate(isRunning: true), gate(isIndexing: true), gate(isTrashingDuplicates: true),
                       gate(isRestoringFromTrash: true), gate(isInventorying: true), gate(isRepairing: true), gate(isAligning: true)]
        XCTAssertTrue(reasons.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(reasons.compactMap { $0 }).count, reasons.count, "ogni causa ha la sua frase")
        reasons.forEach { assertNoJargon($0) }
    }

    func testTheSSDIsAlwaysNeeded_theHDDOnlyForTheHDD_CubbitOnlyForCubbit() {
        XCTAssertNotNil(gate(.hdd, ssdMounted: false))
        XCTAssertNotNil(gate(.cubbit, ssdMounted: false))
        XCTAssertNotNil(gate(.hdd, hddMounted: false))
        XCTAssertNil(gate(.cubbit, hddMounted: false))
        XCTAssertNotNil(gate(.cubbit, hasCubbitConfig: false))
        XCTAssertNil(gate(.hdd, hasCubbitConfig: false))
    }

    func testPrecedence_anotherAlignmentFirst_thenTheSSDTrash() {
        XCTAssertEqual(gate(isRunning: true, isTrashingDuplicates: true, isAligning: true), gate(isAligning: true))
        XCTAssertEqual(gate(isRunning: true, isTrashingDuplicates: true), gate(isTrashingDuplicates: true))
        XCTAssertEqual(gate(isRunning: true, ssdMounted: false), gate(isRunning: true))
    }
}
