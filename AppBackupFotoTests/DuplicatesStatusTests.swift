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
        let line = DuplicatesStatus.headerLine(indexBuilt: false, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertTrue(line.text.contains("Diagnostica"), "deve rimandare alla card")
        XCTAssertFalse(line.text.lowercased().contains("non ci sono copie"),
                       "non deve leggersi come 'niente da segnalare': l'elenco non esiste proprio")
    }

    /// Indice costruito, zero gruppi: riga diversa dalla precedente, altrimenti le due
    /// situazioni opposte (elenco mai fatto / elenco fatto e pulito) sarebbero indistinguibili.
    func testBuiltZeroGroups_differsFromNeverBuilt() {
        let never = DuplicatesStatus.headerLine(indexBuilt: false, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        let zero = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertNotEqual(never.text, zero.text)
        XCTAssertNotEqual(never.id, zero.id)
    }

    /// N gruppi: la riga nomina sia il numero di gruppi sia i byte recuperabili.
    func testNGroups_namesCountAndBytes() {
        let line = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 7, reclaimableBytes: 3_000_000_000)
        XCTAssertTrue(line.text.contains("7"))
        XCTAssertTrue(line.text.contains(ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)))
    }

    /// `groupsKnown == false` (ROADMAP #41): l'elenco non e' ancora stato letto in questa
    /// finestra. Non deve MAI leggersi come "non ci sono doppioni" — un elenco che non si
    /// conosce e un elenco vuoto sono due situazioni opposte.
    func testHeaderLine_groupsUnknown_neverSaysThereAreNoDuplicates() {
        let line = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: false, groupCount: 0, reclaimableBytes: 0)
        let zeroGroupsLine = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertNotEqual(line.text, zeroGroupsLine.text)
        XCTAssertNotEqual(line.id, "zero-groups")
    }

    /// Il conteggio non e' attendibile quando l'elenco non e' stato letto: non si mostra,
    /// qualunque sia il valore passato.
    func testHeaderLine_groupsUnknown_ignoresTheCount() {
        let withoutCount = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: false, groupCount: 0, reclaimableBytes: 0)
        let withCount = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: false, groupCount: 12, reclaimableBytes: 0)
        XCTAssertEqual(withoutCount.text, withCount.text)
        XCTAssertEqual(withoutCount.id, withCount.id)
    }

    /// `groupsKnown == true` non cambia nessuna delle tre diramazioni di oggi rispetto a
    /// prima che il parametro esistesse.
    func testHeaderLine_groupsKnown_keepsTodaysThreeBranches() {
        let noIndex = DuplicatesStatus.headerLine(indexBuilt: false, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertEqual(noIndex.id, "no-index")
        let zeroGroups = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertEqual(zeroGroups.id, "zero-groups")
        let groups = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 3, reclaimableBytes: 1_000)
        XCTAssertEqual(groups.id, "groups")
    }

    // MARK: - `trashProgressLine`

    /// I due numeri devono comparire NELL'ORDINE giusto: `done` prima di `total`, non solo
    /// presenti da qualche parte nel testo.
    func testTrashProgressLine_showsBothNumbers() {
        let text = DuplicatesStatus.trashProgressLine(done: 3, total: 10)
        guard let doneRange = text.range(of: "3"), let totalRange = text.range(of: "10") else {
            return XCTFail("mancano i due numeri in: \(text)")
        }
        XCTAssertTrue(doneRange.lowerBound < totalRange.lowerBound, "«3» deve venire prima di «10»: \(text)")
    }

    func testTrashProgressLine_singularTotal() {
        let text = DuplicatesStatus.trashProgressLine(done: 0, total: 1)
        XCTAssertTrue(text.contains("gruppo"))
        XCTAssertFalse(text.contains("gruppi"))
    }

    func testTrashProgressLine_pluralTotal() {
        let text = DuplicatesStatus.trashProgressLine(done: 0, total: 2)
        XCTAssertTrue(text.contains("gruppi"))
    }

    /// Il mutante da uccidere: decidere il plurale su `done` invece che su `total`.
    func testTrashProgressLine_singularDependsOnTotal_notOnDone() {
        let text = DuplicatesStatus.trashProgressLine(done: 1, total: 4)
        XCTAssertTrue(text.contains("gruppi"), "il plurale deve seguire `total` (4), non `done` (1): \(text)")
    }

    func testTrashProgressLine_hasNoJargon() {
        let forbidden = ["hash", "indice", "sha256", "entry", "scansione"]
        let text = DuplicatesStatus.trashProgressLine(done: 3, total: 10).lowercased()
        for word in forbidden {
            XCTAssertFalse(text.contains(word), "'\(word)' non deve comparire in: \(text)")
        }
    }

    // MARK: - `trashStoppingLine`

    func testTrashStoppingLine_isNotEmptyAndHasNoJargon() {
        let forbidden = ["hash", "indice", "sha256", "entry", "scansione"]
        let text = DuplicatesStatus.trashStoppingLine
        XCTAssertFalse(text.isEmpty)
        let lower = text.lowercased()
        for word in forbidden {
            XCTAssertFalse(lower.contains(word), "'\(word)' non deve comparire in: \(text)")
        }
    }

    /// `DuplicateTrasher.run` controlla l'interruzione solo fra un gruppo e l'altro: la riga
    /// non deve promettere uno stop immediato.
    func testTrashStoppingLine_doesNotPromiseAnImmediateStop() {
        let lower = DuplicatesStatus.trashStoppingLine.lowercased()
        XCTAssertFalse(lower.contains("subito"))
        XCTAssertFalse(lower.contains("immediat"))
    }

    // MARK: - `DuplicatesPanelLoad.shouldLoadOnAppear`

    func testLoadsOnAppear_whenIdleAndNothingIsRunning() {
        XCTAssertTrue(DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: true, isTrashingDuplicates: false, isRestoringFromTrash: false))
    }

    /// Elenco gia' caricato o in caricamento (`isIdle == false`): non si rilegge, qualunque
    /// sia lo stato delle altre due operazioni — tutte e quattro le combinazioni.
    func testDoesNotLoad_whenNotIdle() {
        for isTrashing in [false, true] {
            for isRestoring in [false, true] {
                XCTAssertFalse(DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: false, isTrashingDuplicates: isTrashing, isRestoringFromTrash: isRestoring),
                                "isTrashing=\(isTrashing) isRestoring=\(isRestoring)")
            }
        }
    }

    func testDoesNotLoad_whileTrashing() {
        XCTAssertFalse(DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: true, isTrashingDuplicates: true, isRestoringFromTrash: false))
    }

    func testDoesNotLoad_whileRestoringFromTrash() {
        XCTAssertFalse(DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: true, isTrashingDuplicates: false, isRestoringFromTrash: true))
    }

    /// Combinazione impossibile per la mutua esclusione (spostamento e annullamento non
    /// possono coesistere), ma il predicato non deve dipendere da quell'ipotesi.
    func testDoesNotLoad_whileBothFlagsSomehowTrue() {
        XCTAssertFalse(DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: true, isTrashingDuplicates: true, isRestoringFromTrash: true))
    }

    // MARK: - Perché la cancellazione è disattivata

    /// Job in corso: motivo scritto, non un bottone grigio senza spiegazione.
    func testJobRunning_explainsWhyTrashDisabled() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("backup"))
    }

    /// Scansione dell'indice in corso: stessa disciplina, motivo diverso da quello del job.
    func testIndexingRunning_explainsWhyTrashDisabled() {
        let indexing = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: true, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false)
        let running = DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false)
        XCTAssertNotNil(indexing)
        XCTAssertNotEqual(indexing, running, "i due motivi non devono essere la stessa frase")
    }

    /// SSD scollegato: riga PROPRIA, diversa da "nessun doppione" — non sono la stessa cosa:
    /// uno è "non ho niente da segnalare", l'altro è "non posso controllare adesso".
    func testSSDDisconnected_ownReason_differsFromNoGroups() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: false, isTrashingDuplicates: false, isRestoringFromTrash: false)
        let noGroupsLine = DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 0, reclaimableBytes: 0)
        XCTAssertNotNil(reason)
        XCTAssertNotEqual(reason!, noGroupsLine.text)
        XCTAssertTrue(reason!.contains("SSD"))
    }

    /// Nessuna delle tre condizioni: `nil`, cioè niente lo impedisce da qui (restano
    /// comunque le due conferme). Una funzione che restituisse sempre un motivo non
    /// distinguerebbe "disattivato" da "attivo".
    func testNothingBlocksTrash_whenAllConditionsAreFine() {
        XCTAssertNil(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false))
    }

    /// Uno spostamento nel Cestino gia' in corso (Task 4, 2026-09-19): un secondo non puo'
    /// partire mentre il primo gira. Valutato DOPO isIndexing, come tutte le altre condizioni:
    /// e' la garanzia che sostituisce il vecchio `@State isTrashing` che si azzerava riaprendo
    /// la finestra.
    func testTrashingAlreadyInProgress_explainsWhyTrashDisabled() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true, isTrashingDuplicates: true, isRestoringFromTrash: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
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

        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: false, groupsKnown: true, groupCount: 0, reclaimableBytes: 0).text)
        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 0, reclaimableBytes: 0).text)
        allTexts.append(DuplicatesStatus.headerLine(indexBuilt: true, groupsKnown: true, groupCount: 3, reclaimableBytes: 1_000).text)
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: true, isIndexing: false, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false) ?? "")
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: true, ssdMounted: true, isTrashingDuplicates: false, isRestoringFromTrash: false) ?? "")
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: false, isTrashingDuplicates: false, isRestoringFromTrash: false) ?? "")
        allTexts.append(DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true, isTrashingDuplicates: true, isRestoringFromTrash: false) ?? "")
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

    // MARK: - Un annullamento in corso disattiva lo spostamento (Task 5, ADR-0009)

    func testTrashDisabled_whileRestoring() {
        let reason = DuplicatesStatus.trashDisabledReason(isRunning: false, isIndexing: false, ssdMounted: true,
                                                           isTrashingDuplicates: false, isRestoringFromTrash: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("rimettendo"))
    }

    // MARK: - `undoDisabledReason` (Task 5, ADR-0009)

    private func summary(pending: Int = 3) -> RestorableBatchSummary {
        RestorableBatchSummary(pendingCount: pending, batchCount: pending, trashedAt: Date())
    }

    func testUndoDisabled_ssdNotMounted() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: false, isRunning: false, isIndexing: false,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("SSD"))
    }

    /// `ssdMounted == false` ha la precedenza su TUTTO il resto (Task 6, ROADMAP #41): anche
    /// con un job, uno spostamento e un annullamento tutti "in corso" insieme, la frase deve
    /// restare quella sull'SSD scollegato — e' il motivo che `startTrashRestore` rivaluta
    /// prima dell'alert generico.
    func testUndoDisabled_ssdNotMounted_takesPrecedenceOverEverythingElse() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: false, isRunning: true, isIndexing: true,
                                                          isTrashingDuplicates: true, isRestoringFromTrash: true,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("SSD"))
    }

    func testUndoDisabled_trashingInProgress() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                          isTrashingDuplicates: true, isRestoringFromTrash: false,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
    }

    func testUndoDisabled_restoringAlreadyInProgress() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: true,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
    }

    func testUndoDisabled_jobRunning() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: true, isIndexing: false,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("backup"))
    }

    func testUndoDisabled_indexing() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: true,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          summary: summary(), hasEverTrashed: true)
        XCTAssertNotNil(reason)
    }

    /// Niente da rimettere a posto E non si e' mai spostato niente da qui: frase diversa da
    /// "gia' annullato".
    func testUndoDisabled_neverTrashedAnything() {
        let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          summary: nil, hasEverTrashed: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("non hai ancora"))
    }

    /// Niente da rimettere a posto ma SI e' gia' spostato e annullato: frase diversa dalla
    /// precedente.
    func testUndoDisabled_alreadyRestored() {
        let neverTrashed = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                                isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                                summary: nil, hasEverTrashed: false)
        let alreadyRestored = DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                                   isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                                   summary: nil, hasEverTrashed: true)
        XCTAssertNotNil(alreadyRestored)
        XCTAssertNotEqual(neverTrashed, alreadyRestored)
    }

    /// `nil` quando c'e' davvero qualcosa da rimettere a posto e nient'altro lo impedisce.
    func testUndoDisabled_nilWhenSomethingIsPendingAndNothingBlocks() {
        XCTAssertNil(DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                          summary: summary(), hasEverTrashed: true))
    }

    /// Ogni ramo di `undoDisabledReason` e' davvero raggiunto dal proprio caso — stile
    /// `testEveryBranchIsActuallyReachedByItsCase` di `LibraryIndexStatus`.
    func testUndoDisabled_everyBranchIsReachedByItsCase() {
        let cases: [(String, String?)] = [
            ("ssd", DuplicatesStatus.undoDisabledReason(ssdMounted: false, isRunning: false, isIndexing: false,
                isTrashingDuplicates: false, isRestoringFromTrash: false, summary: summary(), hasEverTrashed: true)),
            ("trashing", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                isTrashingDuplicates: true, isRestoringFromTrash: false, summary: summary(), hasEverTrashed: true)),
            ("restoring", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                isTrashingDuplicates: false, isRestoringFromTrash: true, summary: summary(), hasEverTrashed: true)),
            ("running", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: true, isIndexing: false,
                isTrashingDuplicates: false, isRestoringFromTrash: false, summary: summary(), hasEverTrashed: true)),
            ("indexing", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: true,
                isTrashingDuplicates: false, isRestoringFromTrash: false, summary: summary(), hasEverTrashed: true)),
            ("never-trashed", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                isTrashingDuplicates: false, isRestoringFromTrash: false, summary: nil, hasEverTrashed: false)),
            ("already-restored", DuplicatesStatus.undoDisabledReason(ssdMounted: true, isRunning: false, isIndexing: false,
                isTrashingDuplicates: false, isRestoringFromTrash: false, summary: nil, hasEverTrashed: true)),
        ]
        for (name, reason) in cases {
            XCTAssertNotNil(reason, "il caso '\(name)' non ha prodotto un motivo")
        }
        let allReasons = Set(cases.compactMap(\.1))
        XCTAssertEqual(allReasons.count, cases.count, "due casi diversi condividono la stessa frase")
    }
}
