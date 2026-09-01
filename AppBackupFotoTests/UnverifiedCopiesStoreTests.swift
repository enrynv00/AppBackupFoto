//
//  UnverifiedCopiesStoreTests.swift
//  AppBackupFotoTests
//
//  Debito di verifica: i file copiati la cui verifica SHA256 post-copia non ha potuto
//  concludersi (`SyncResult.copiedUnverified`).
//
//  Perche' questo store esiste: per la regola zero-overwrite quel file non verra' MAI
//  ricopiato. Se fosse davvero corrotto resterebbe corrotto per sempre, e finora il numero
//  viveva solo nel riepilogo di fine job, che sparisce chiudendo la finestra. Qui si
//  conservano i PERCORSI, perche' il conteggio da solo non permette di dare la precedenza a
//  quei file nel campione d'integrita' del pannello Revisione.
//

import XCTest
@testable import AppBackupFoto

final class UnverifiedCopiesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "UnverifiedCopiesStoreTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/foto/IMG_\(n).JPG") }

    func testEmptyStore_hasNoDebt() {
        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 0)
        XCTAssertTrue(state.paths.isEmpty)
    }

    func testRecord_keepsCountAndPath() {
        UnverifiedCopiesStore.record(url(1), defaults: defaults)
        UnverifiedCopiesStore.record(url(2), defaults: defaults)

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertEqual(state.paths, [url(1).path, url(2).path])
    }

    func testRecordSameFileTwice_countsOnce() {
        UnverifiedCopiesStore.record(url(1), defaults: defaults)
        UnverifiedCopiesStore.record(url(1), defaults: defaults)

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 1)
        XCTAssertEqual(state.paths, [url(1).path])
    }

    // Il tetto e il conteggio insieme: senza tetto il record in UserDefaults crescerebbe con
    // il numero di file copiati invece che con il numero di problemi; senza conteggio totale
    // il numero mostrato all'utente diventerebbe falso non appena la lista viene troncata.
    func testCap_truncatesThePathsButTheCountStaysTruthful() {
        let extra = 37
        for i in 0..<(UnverifiedCopiesStore.maxPaths + extra) {
            UnverifiedCopiesStore.record(url(i), defaults: defaults)
        }

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.paths.count, UnverifiedCopiesStore.maxPaths,
                       "la lista dei percorsi deve fermarsi al tetto")
        XCTAssertEqual(state.totalCount, UnverifiedCopiesStore.maxPaths + extra,
                       "il conteggio deve restare veritiero anche con la lista troncata")
        XCTAssertEqual(state.paths.first, url(0).path, "si conservano i primi, non gli ultimi")
        XCTAssertFalse(state.paths.contains(url(UnverifiedCopiesStore.maxPaths).path))
    }

    func testClear_closesTheDebtForThatFileOnly() {
        UnverifiedCopiesStore.record(url(1), defaults: defaults)
        UnverifiedCopiesStore.record(url(2), defaults: defaults)

        UnverifiedCopiesStore.clear(url(1).path, defaults: defaults)

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.paths, [url(2).path])
        XCTAssertEqual(state.totalCount, 1)
    }

    // Scalare un debito che non risulta significherebbe far scendere il numero senza aver
    // ricontrollato niente.
    func testClear_unknownPath_leavesTheDebtUntouched() {
        UnverifiedCopiesStore.record(url(1), defaults: defaults)

        UnverifiedCopiesStore.clear("/tmp/foto/mai-vista.JPG", defaults: defaults)

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.paths, [url(1).path])
        XCTAssertEqual(state.totalCount, 1)
    }

    // Un record scritto da una versione precedente (o corrotto) non deve far crashare
    // l'apertura del pannello Revisione: si riparte da un debito vuoto.
    func testUndecodableRecord_loadsAnEmptyDebtInsteadOfCrashing() {
        defaults.set(Data("questo non e' JSON".utf8), forKey: "unverifiedCopies")

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 0)
        XCTAssertTrue(state.paths.isEmpty)
    }

    // I campi hanno un default, quindi un record scritto quando lo struct aveva meno campi
    // resta decodificabile.
    func testRecordWithMissingFields_decodesWithDefaults() {
        defaults.set(Data("{\"totalCount\":5}".utf8), forKey: "unverifiedCopies")

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 5)
        XCTAssertTrue(state.paths.isEmpty)
    }

    // MARK: Retrocompatibilita' della forma vecchia (percorsi senza data)

    // Il record scritto prima che le voci avessero una data usava `paths: [String]`. Se non
    // lo si legge piu', i debiti gia' contratti spariscono in silenzio al primo
    // aggiornamento dell'app: e' esattamente l'errore gia' pagato con `changedSkipped`.
    func testLegacyRecordWithoutDates_isStillRead() {
        defaults.set(Data("{\"totalCount\":2,\"paths\":[\"/tmp/foto/A.JPG\",\"/tmp/foto/B.JPG\"]}".utf8),
                     forKey: "unverifiedCopies")

        let state = UnverifiedCopiesStore.load(defaults: defaults)
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertEqual(state.paths, ["/tmp/foto/A.JPG", "/tmp/foto/B.JPG"])
    }

    // Una voce senza data non si puo' giudicare: non scade. Farla scadere su una data
    // inventata farebbe sparire un debito reale, che e' il verso sbagliato dell'errore.
    func testLegacyEntryWithoutADate_neverExpires() {
        defaults.set(Data("{\"totalCount\":1,\"paths\":[\"/tmp/foto/A.JPG\"]}".utf8),
                     forKey: "unverifiedCopies")

        let fraDieciAnni = Date().addingTimeInterval(10 * 365 * 24 * 3600)
        let state = UnverifiedCopiesStore.load(now: fraDieciAnni, defaults: defaults)
        XCTAssertEqual(state.totalCount, 1)
        XCTAssertEqual(state.paths, ["/tmp/foto/A.JPG"])
    }

    // MARK: Scadenza

    // Un file importato da una scheda SD poi scollegata non ha piu' una sorgente con cui
    // essere confrontato in nessuna coppia: senza scadenza resterebbe in lista per sempre,
    // occupando uno dei 200 posti e falsando un conteggio che nessuno potra' mai chiudere.
    func testEntryOlderThanTheExpiry_leavesBothTheListAndTheCount() {
        let now = Date()
        // Letterale e non `expiryInterval`: se qualcuno cambiasse la costante, questo test
        // deve accorgersene invece di seguirla.
        UnverifiedCopiesStore.record(url(1), now: now.addingTimeInterval(-31 * 24 * 3600), defaults: defaults)

        let state = UnverifiedCopiesStore.load(now: now, defaults: defaults)
        XCTAssertTrue(state.paths.isEmpty, "una voce scaduta non resta in lista")
        XCTAssertEqual(state.totalCount, 0, "e non deve nemmeno restare nel conteggio")
    }

    func testEntryYoungerThanTheExpiry_stays() {
        let now = Date()
        UnverifiedCopiesStore.record(url(1), now: now.addingTimeInterval(-29 * 24 * 3600), defaults: defaults)

        let state = UnverifiedCopiesStore.load(now: now, defaults: defaults)
        XCTAssertEqual(state.paths, [url(1).path])
        XCTAssertEqual(state.totalCount, 1)
    }

    // Il confine e' deciso una volta sola: esattamente 30 giorni NON e' scaduto, un secondo
    // dopo si'. L'istante e' iniettato, quindi non e' una corsa.
    func testTheExpiryBoundaryIsDeterministic() {
        let now = Date()
        let trentaGiorni: TimeInterval = 30 * 24 * 3600
        let sulFilo = UnverifiedCopies.Entry(path: url(1).path,
                                             recordedAt: now.addingTimeInterval(-trentaGiorni))
        let unSecondoOltre = UnverifiedCopies.Entry(path: url(2).path,
                                                    recordedAt: now.addingTimeInterval(-trentaGiorni - 1))

        XCTAssertFalse(UnverifiedCopiesStore.isExpired(sulFilo, now: now))
        XCTAssertTrue(UnverifiedCopiesStore.isExpired(unSecondoOltre, now: now))
    }

    // La scadenza non deve toccare le voci ancora buone che stanno accanto a una scaduta.
    func testOnlyTheExpiredEntriesAreDropped() {
        let now = Date()
        UnverifiedCopiesStore.record(url(1), now: now.addingTimeInterval(-40 * 24 * 3600), defaults: defaults)
        UnverifiedCopiesStore.record(url(2), now: now.addingTimeInterval(-40 * 24 * 3600), defaults: defaults)
        UnverifiedCopiesStore.record(url(3), now: now.addingTimeInterval(-1 * 24 * 3600), defaults: defaults)

        let state = UnverifiedCopiesStore.load(now: now, defaults: defaults)
        XCTAssertEqual(state.paths, [url(3).path])
        XCTAssertEqual(state.totalCount, 1)
    }

    // Il posto liberato da una voce scaduta torna disponibile: e' il motivo per cui la
    // scadenza esiste.
    func testAnExpiredEntryGivesItsSlotBack() {
        let now = Date()
        for i in 0..<UnverifiedCopiesStore.maxPaths {
            UnverifiedCopiesStore.record(url(i), now: now.addingTimeInterval(-40 * 24 * 3600), defaults: defaults)
        }
        UnverifiedCopiesStore.record(url(9999), now: now, defaults: defaults)

        let state = UnverifiedCopiesStore.load(now: now, defaults: defaults)
        XCTAssertEqual(state.paths, [url(9999).path])
        XCTAssertEqual(state.totalCount, 1)
    }

    // La data e' quella del momento in cui il debito e' stato contratto, non quella della
    // lettura: se `record` non la scrivesse, nessuna voce scadrebbe mai.
    func testRecordStampsTheEntryWithTheInstantItWasContracted() {
        let quando = Date().addingTimeInterval(-3600)
        UnverifiedCopiesStore.record(url(1), now: quando, defaults: defaults)

        let entry = UnverifiedCopiesStore.load(now: quando, defaults: defaults).entries.first
        XCTAssertEqual(entry?.recordedAt?.timeIntervalSince1970 ?? 0,
                       quando.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Orologio di sistema (rilievo minore di #31, affrontato il 2026-09-01)

    /// Il caso **univoco**: l'orologio e' tornato indietro dall'ultima scrittura. Nessun
    /// trascorrere del tempo puo' produrre questa lettura, quindi le date non sono
    /// affidabili e in quel giro non si pota niente.
    func testClockWentBackwards_isDetected() {
        let scritto = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(UnverifiedCopiesStore.clockWentBackwards(
            lastSeenAt: scritto, now: scritto.addingTimeInterval(-3600)))
        XCTAssertFalse(UnverifiedCopiesStore.clockWentBackwards(
            lastSeenAt: scritto, now: scritto.addingTimeInterval(3600)))
    }

    /// Un record scritto dalla versione precedente non ha `lastSeenAt` e non e' giudicabile:
    /// si pota normalmente, come si e' sempre fatto.
    func testARecordWithoutLastSeen_isPrunedAsBefore() {
        XCTAssertFalse(UnverifiedCopiesStore.clockWentBackwards(lastSeenAt: nil, now: Date()))
    }

    /// Con l'orologio all'indietro il debito **resta**, invece di sparire per una data che
    /// non vuol dire niente.
    func testClockGoingBackwards_keepsTheDebt() {
        let d = defaults!
        let scritto = Date(timeIntervalSince1970: 1_700_000_000)
        UnverifiedCopiesStore.record(URL(fileURLWithPath: "/a.jpg"), now: scritto, defaults: d)

        // L'orologio crolla indietro di anni (batteria dell'RTC, ripristino da backup): da
        // li' ogni voce risulterebbe "nel futuro", e senza guardia il record verrebbe letto
        // e riscritto su basi false.
        let crollato = scritto.addingTimeInterval(-5 * 365 * 24 * 3600)
        let stato = UnverifiedCopiesStore.load(now: crollato, defaults: d)
        XCTAssertEqual(stato.paths, ["/a.jpg"])
        XCTAssertEqual(stato.totalCount, 1)
    }

    /// Una data nel futuro non e' una voce scaduta — l'altra faccia dello stesso caso.
    func testAnEntryDatedInTheFuture_isNotExpired() {
        let registrata = Date(timeIntervalSince1970: 1_700_000_000)
        let adesso = registrata.addingTimeInterval(-90 * 24 * 3600)
        let voce = UnverifiedCopies.Entry(path: "/a.jpg", recordedAt: registrata)
        XCTAssertFalse(UnverifiedCopiesStore.isExpired(voce, now: adesso))
    }

    /// **Limite accettato, non difetto risolto.** Un salto in avanti fa ancora scadere i
    /// debiti in blocco, perche' dai soli timestamp e' indistinguibile da un'app rimasta
    /// chiusa a lungo. Questo test **codifica il limite** invece di lasciarlo implicito: se
    /// un giorno qualcuno trovera' un riferimento monotono che sopravvive ai riavvii, sara'
    /// questo test a dover cambiare, e cambiandolo leggera' il perche'.
    func testForwardJump_stillExpiresInBulk_acceptedLimit() {
        let d = defaults!
        let inizio = Date(timeIntervalSince1970: 1_700_000_000)
        UnverifiedCopiesStore.record(URL(fileURLWithPath: "/a.jpg"), now: inizio, defaults: d)
        UnverifiedCopiesStore.record(URL(fileURLWithPath: "/b.jpg"), now: inizio, defaults: d)

        let unAnnoDopo = inizio.addingTimeInterval(365 * 24 * 3600)
        let stato = UnverifiedCopiesStore.load(now: unAnnoDopo, defaults: d)

        XCTAssertTrue(stato.entries.isEmpty,
                      "limite noto: un salto in avanti resta indistinguibile da una lunga assenza")
        XCTAssertEqual(stato.totalCount, 0)
    }

}
