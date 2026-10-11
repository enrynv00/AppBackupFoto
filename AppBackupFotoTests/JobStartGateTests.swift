import XCTest
@testable import AppBackupFoto

/// `JobStartGate` (Task 4, 2026-09-19, BUG-7): il verso mancante della mutua esclusione fra
/// lo spostamento nel Cestino, la lettura dell'elenco e i job che scrivono. Fino al fix di
/// isolamento MainActor, quello spostamento e quella lettura giravano per errore sul main
/// thread, quindi nessun backup poteva partire mentre erano in corso — l'app era bloccata.
/// Tolto il bug, la mutua esclusione la garantisce questo gate.
///
/// Risposta di Enrico alla domanda aperta 1 della spec (2026-09-19): il backup NON parte, con
/// un messaggio chiaro e senza gergo tecnico.
final class JobStartGateTests: XCTestCase {

    /// Niente in corso: nessun motivo, il job puo' partire.
    func testNothingBlocks_whenAllConditionsAreFine() {
        XCTAssertNil(JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false))
    }

    /// Uno spostamento nel Cestino in corso: motivo scritto, non un rifiuto muto.
    func testTrashingInProgress_blocksWithAReason() {
        let reason = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
    }

    /// L'elenco si sta aggiornando: motivo scritto, diverso da quello dello spostamento.
    func testIndexingInProgress_blocksWithAReason() {
        let reason = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("elenco"))
    }

    /// Le due frasi non sono la stessa: un utente che legge il motivo deve poter distinguere
    /// le due cause, come per `LibraryIndexCommandGate`/`DuplicatesStatus`.
    func testTheTwoReasonsDiffer() {
        let trashing = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let indexing = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotEqual(trashing, indexing)
    }

    /// Entrambe le condizioni insieme: vince lo spostamento nel Cestino, la piu' vicina al
    /// danno (e' anche il percorso a danno piu' alto del progetto, ADR-0005).
    func testBothInProgress_trashingWins() {
        let reason = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let trashingOnly = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertEqual(reason, trashingOnly)
    }

    /// Nessun testo pensato per un utente non tecnico deve nominare i meccanismi interni.
    func testReasonsCarryNoJargon() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache", "entry"]
        for reason in [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)] {
            let detto = (reason ?? "").lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola), "gergo nel motivo: '\(parola)' in «\(detto)»")
            }
        }
    }

    // MARK: - Annullamento in corso (Task 5, ADR-0009)

    /// Un annullamento in corso blocca i job che scrivono, con un motivo scritto.
    func testRestoringInProgress_blocksWithAReason() {
        let reason = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("rimettendo"))
    }

    /// La frase dell'annullamento e' diversa dalle altre due: un utente deve poter capire
    /// quale delle tre operazioni sta bloccando il job.
    func testRestoringReason_differsFromTheOthers() {
        let restoring = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)
        let trashing = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let indexing = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotEqual(restoring, trashing)
        XCTAssertNotEqual(restoring, indexing)
    }

    /// Spostamento e annullamento insieme (impossibile a runtime, ma la precedenza va
    /// fissata comunque): vince lo spostamento, la stessa precedenza di `testBothInProgress_trashingWins`.
    func testTrashingAndRestoring_trashingWins() {
        let reason = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)
        let trashingOnly = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertEqual(reason, trashingOnly)
    }

    // MARK: - Inventario in corso (ROADMAP #44)

    /// L'inventario legge SSD, HDD e Cubbit: un job che ci scrive sopra non parte, con una
    /// frase sua, diversa dalle altre tre.
    func testInventoryInProgress_blocksWithItsOwnReason() {
        let inventory = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false,
                                                   isRestoringFromTrash: false, isInventorying: true, isRepairing: false, isAligning: false)
        XCTAssertNotNil(inventory)
        XCTAssertTrue(inventory!.contains("inventario"))
        for other in [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                      JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)] {
            XCTAssertNotEqual(inventory, other)
        }
    }
}
