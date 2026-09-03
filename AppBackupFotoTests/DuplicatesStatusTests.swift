import XCTest
@testable import AppBackupFoto

/// Le sole parti pure della finestra "Doppioni": le righe di stato (`DuplicatesStatus`) e la
/// cache delle miniature (`DuplicateThumbnailCache`). La view, i due sheet di conferma, il
/// gate e l'apertura della finestra non sono testabili senza una corsa reale (Step 7 del
/// Task 6, dichiarato anche in testa a `DuplicatesView`).
final class DuplicatesStatusTests: XCTestCase {

    // MARK: - Intestazione del pannello

    /// Indice mai costruito: la riga deve rimandare alla card, MAI leggersi come "non hai
    /// doppioni" — stessa classe di errore già corretta con `sawNothing` in #31.
    func testNeverBuilt_pointsToTheCard() {
        let line = DuplicatesStatus.headerLine(indexBuilt: false, groupCount: 0, reclaimableBytes: 0)
        XCTAssertTrue(line.text.contains("Diagnostica"), "deve rimandare alla card")
        XCTAssertFalse(line.text.lowercased().contains("non ci sono copie"),
                       "non deve leggersi come 'niente da segnalare': l'elenco non esiste proprio")
    }

    /// Indice costruito, zero gruppi: riga diversa dalla precedente, altrimenti le due
    /// situazioni opposte (elenco mai fatto / elenco fatto e pulito) sarebbero indistinguibili.
    func testBuiltZeroGroups_differsFromNeverBuilt() {
        let never = DuplicatesStatus.headerLine(indexBuilt: false, groupCount: 0, reclaimableBytes: 0)
        let zero = DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertNotEqual(never.text, zero.text)
        XCTAssertNotEqual(never.id, zero.id)
    }

    /// N gruppi: la riga nomina sia il numero di gruppi sia i byte recuperabili.
    func testNGroups_namesCountAndBytes() {
        let line = DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 7, reclaimableBytes: 3_000_000_000)
        XCTAssertTrue(line.text.contains("7"))
        XCTAssertTrue(line.text.contains(ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)))
    }

    // MARK: - Perché la cancellazione è disattivata

    /// Job in corso: motivo scritto, non un bottone grigio senza spiegazione.
    func testJobRunning_explainsWhyTrashDisabled() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("backup"))
    }

    /// Scansione dell'indice in corso: stessa disciplina, motivo diverso da quello del job.
    func testIndexingRunning_explainsWhyTrashDisabled() {
        let indexing = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: true, ssdMounted: true)
        let running = DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true)
        XCTAssertNotNil(indexing)
        XCTAssertNotEqual(indexing, running, "i due motivi non devono essere la stessa frase")
    }

    /// SSD scollegato: riga PROPRIA, diversa da "nessun doppione" — non sono la stessa cosa:
    /// uno è "non ho niente da segnalare", l'altro è "non posso controllare adesso".
    func testSSDDisconnected_ownReason_differsFromNoGroups() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: false)
        let noGroupsLine = DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertNotNil(reason)
        XCTAssertNotEqual(reason!, noGroupsLine.text)
        XCTAssertTrue(reason!.contains("SSD"))
    }

    /// Nessuna delle tre condizioni: `nil`, cioè niente lo impedisce da qui (restano
    /// comunque le due conferme). Una funzione che restituisse sempre un motivo non
    /// distinguerebbe "disattivato" da "attivo".
    func testNothingBlocksTrash_whenAllConditionsAreFine() {
        XCTAssertNil(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true))
    }

    // MARK: - Tetto del blocco

    /// Sopra il tetto: la UI dice "fallo in più volte", non un rifiuto muto.
    func testExceedsCap_saysDoItInMultiplePasses() {
        let reason = DuplicatesStatus.confirmationBlockedReason(exceedsCap: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("più pass") || reason!.lowercased().contains("più volte"))
    }

    /// Sotto il tetto: nessun motivo di blocco.
    func testWithinCap_noBlockingReason() {
        XCTAssertNil(DuplicatesStatus.confirmationBlockedReason(exceedsCap: false))
    }

    // MARK: - Esito di un blocco

    private func skipReasonSample(_ path: String) -> DuplicateTrashSkipReason {
        .unreadable(displayPath: path)
    }

    /// Esito con gruppi saltati: riga con IL NUMERO e il motivo, mai un silenzio.
    func testOutcomeWithSkippedGroups_namesCountAndReason() {
        var outcome = DuplicateTrashOutcome()
        let g1 = DuplicateGroup(hash: "h1", size: 10,
                                members: [LibraryIndexEntry(path: "a", displayPath: "a.jpg", size: 10,
                                                            mtime: 0, hash: "h1", hashedAt: 0)])
        let g2 = DuplicateGroup(hash: "h2", size: 10,
                                members: [LibraryIndexEntry(path: "b", displayPath: "b.jpg", size: 10,
                                                            mtime: 0, hash: "h2", hashedAt: 0)])
        outcome.skippedGroups = [(g1, skipReasonSample("a.jpg")), (g2, .nothingToTrash)]

        let lines = DuplicatesStatus.outcomeLines(outcome)
        let joined = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("2"), "deve nominare il numero di gruppi saltati")
        XCTAssertTrue(joined.contains(skipReasonSample("a.jpg").explanation))
        XCTAssertTrue(joined.contains(DuplicateTrashSkipReason.nothingToTrash.explanation))
    }

    /// Esito interrotto dallo scollegamento: riga PROPRIA con quanti file erano già stati
    /// spostati prima dello stop — non un numero generico, il conteggio onesto.
    func testOutcomeInterruptedByDisconnection_namesFilesMoved() {
        var outcome = DuplicateTrashOutcome()
        outcome.stoppedBecauseVolumeVanished = true
        outcome.trashedFiles = [TrashedItem(batchId: "b", originalDisplayPath: "/x/a.jpg", originalKey: "a",
                                            trashedPath: "/x/.Trashes/a.jpg", size: 1, hash: "h",
                                            trashedAt: Date())]
        let lines = DuplicatesStatus.outcomeLines(outcome)
        let joined = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("1"))
        XCTAssertTrue(joined.lowercased().contains("scollegat") || joined.lowercased().contains("ssd"))
    }

    /// Esito interrotto dall'utente: riga diversa da quella dello scollegamento, stesso
    /// bisogno di un conteggio onesto.
    func testOutcomeInterruptedByUser_differsFromDisconnection() {
        var outcome = DuplicateTrashOutcome()
        outcome.interrupted = true
        outcome.trashedFiles = [TrashedItem(batchId: "b", originalDisplayPath: "/x/a.jpg", originalKey: "a",
                                            trashedPath: "/x/.Trashes/a.jpg", size: 1, hash: "h",
                                            trashedAt: Date())]
        let userLines = DuplicatesStatus.outcomeLines(outcome).map(\.text).joined(separator: " ")

        var disconnected = DuplicateTrashOutcome()
        disconnected.stoppedBecauseVolumeVanished = true
        disconnected.trashedFiles = outcome.trashedFiles
        let disconnectedLines = DuplicatesStatus.outcomeLines(disconnected).map(\.text).joined(separator: " ")

        XCTAssertNotEqual(userLines, disconnectedLines)
    }

    /// Nessuno dei tre problemi ed esito con almeno un file spostato: un esito pulito lo dice,
    /// non resta muto.
    func testCleanOutcome_saysSomething() {
        var outcome = DuplicateTrashOutcome()
        outcome.trashedFiles = [TrashedItem(batchId: "b", originalDisplayPath: "/x/a.jpg", originalKey: "a",
                                            trashedPath: "/x/.Trashes/a.jpg", size: 1, hash: "h",
                                            trashedAt: Date())]
        XCTAssertFalse(DuplicatesStatus.outcomeLines(outcome).isEmpty)
    }

    // MARK: - Registro anti-gergo

    /// Nessuna delle diramazioni usa gergo tecnico: chi legge sta per confermare uno
    /// spostamento nel Cestino, non deve capire cosa sia un "hash" per farlo.
    func testAntiJargonRegister_acrossAllBranches() {
        let forbidden = ["hash", "indice", "sha256", "entry", "scansione"]
        var allTexts: [String] = []

        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: false, groupCount: 0, reclaimableBytes: 0).text)
        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 0, reclaimableBytes: 0).text)
        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 3, reclaimableBytes: 1_000).text)
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true) ?? "")
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: true, ssdMounted: true) ?? "")
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: false) ?? "")
        allTexts.append(DuplicatesStatus.confirmationBlockedReason(exceedsCap: true) ?? "")

        var skipped = DuplicateTrashOutcome()
        skipped.skippedGroups = [(DuplicateGroup(hash: "h", size: 1,
                                                 members: [LibraryIndexEntry(path: "a", displayPath: "a.jpg", size: 1,
                                                                             mtime: 0, hash: "h", hashedAt: 0)]),
                                 .nothingToTrash)]
        allTexts.append(contentsOf: DuplicatesStatus.outcomeLines(skipped).map(\.text))

        var vanished = DuplicateTrashOutcome()
        vanished.stoppedBecauseVolumeVanished = true
        allTexts.append(contentsOf: DuplicatesStatus.outcomeLines(vanished).map(\.text))

        // Le due diramazioni che la prima stesura di questo test non toccava (rilievo di
        // review del 2026-09-01). "Su tutte le diramazioni" deve voler dire tutte:
        // un registro verificato su sette casi su nove e' un registro non verificato.
        var interrupted = DuplicateTrashOutcome()
        interrupted.interrupted = true
        allTexts.append(contentsOf: DuplicatesStatus.outcomeLines(interrupted).map(\.text))

        allTexts.append(contentsOf: DuplicatesStatus.outcomeLines(DuplicateTrashOutcome()).map(\.text))

        for text in allTexts {
            let lower = text.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word), "'\(word)' non deve comparire in: \(text)")
            }
        }
    }

    // MARK: - Cache delle miniature

    /// Oltre il tetto la più vecchia viene sfrattata.
    func testThumbnailCache_evictsOldestBeyondCap() {
        let cache = DuplicateThumbnailCache(capacity: 3)
        cache.insert(NSImage(), for: "a")
        cache.insert(NSImage(), for: "b")
        cache.insert(NSImage(), for: "c")
        cache.insert(NSImage(), for: "d")

        XCTAssertNil(cache.image(for: "a"), "la più vecchia deve essere sfrattata")
        XCTAssertNotNil(cache.image(for: "b"))
        XCTAssertNotNil(cache.image(for: "c"))
        XCTAssertNotNil(cache.image(for: "d"))
    }

    /// La dimensione non supera mai il tetto, qualunque sia il numero di inserimenti.
    func testThumbnailCache_sizeNeverExceedsCap() {
        let cache = DuplicateThumbnailCache(capacity: 5)
        for i in 0..<50 {
            cache.insert(NSImage(), for: "k\(i)")
            XCTAssertLessThanOrEqual(cache.count, 5)
        }
        XCTAssertEqual(cache.count, 5)
    }

    // MARK: - La garanzia sui mirror va detta nel pannello (direttiva di Enrico, 2026-09-02)

    /// Enrico ha chiesto esplicitamente che l'HDD resti un archivio completo, doppioni
    /// compresi. Il comportamento era gia' quello, ma il pannello lo diceva **solo** nel
    /// riepilogo finale — cioe' dopo che aveva gia' scelto cosa spuntare. Questa riga lo dice
    /// mentre decide.
    func testMirrorsUntouchedNote_namesBothMirrorsAndSaysOnlyTheSSDIsTouched() {
        let nota = DuplicatesStatus.mirrorsUntouchedNote().lowercased()
        XCTAssertTrue(nota.contains("hdd"), "la nota non nomina l'HDD: «\(nota)»")
        XCTAssertTrue(nota.contains("cubbit"), "la nota non nomina Cubbit: «\(nota)»")
        XCTAssertTrue(nota.contains("ssd"), "la nota non dice che si tocca solo l'SSD")
        XCTAssertTrue(nota.contains("doppioni"),
                      "la nota deve dire esplicitamente che il backup tiene ANCHE i doppioni")
    }

    /// Registro anti-gergo anche qui.
    func testMirrorsUntouchedNote_carriesNoJargon() {
        let gergo = ["hash", "indice", "sha256", "dedup", "scansione", "entry", "mirror"]
        let nota = DuplicatesStatus.mirrorsUntouchedNote().lowercased()
        for parola in gergo {
            XCTAssertFalse(nota.contains(parola), "gergo: '\(parola)' in «\(nota)»")
        }
    }

}
