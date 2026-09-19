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
        XCTAssertNil(JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: false))
    }

    /// Uno spostamento nel Cestino in corso: motivo scritto, non un rifiuto muto.
    func testTrashingInProgress_blocksWithAReason() {
        let reason = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
    }

    /// L'elenco si sta aggiornando: motivo scritto, diverso da quello dello spostamento.
    func testIndexingInProgress_blocksWithAReason() {
        let reason = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("elenco"))
    }

    /// Le due frasi non sono la stessa: un utente che legge il motivo deve poter distinguere
    /// le due cause, come per `LibraryIndexCommandGate`/`DuplicatesStatus`.
    func testTheTwoReasonsDiffer() {
        let trashing = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true)
        let indexing = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false)
        XCTAssertNotEqual(trashing, indexing)
    }

    /// Entrambe le condizioni insieme: vince lo spostamento nel Cestino, la piu' vicina al
    /// danno (e' anche il percorso a danno piu' alto del progetto, ADR-0005).
    func testBothInProgress_trashingWins() {
        let reason = JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: true)
        let trashingOnly = JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true)
        XCTAssertEqual(reason, trashingOnly)
    }

    /// Nessun testo pensato per un utente non tecnico deve nominare i meccanismi interni.
    func testReasonsCarryNoJargon() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache", "entry"]
        for reason in [JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: false),
                       JobStartGate.blockedReason(isIndexing: false, isTrashingDuplicates: true),
                       JobStartGate.blockedReason(isIndexing: true, isTrashingDuplicates: true)] {
            let detto = (reason ?? "").lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola), "gergo nel motivo: '\(parola)' in «\(detto)»")
            }
        }
    }
}
