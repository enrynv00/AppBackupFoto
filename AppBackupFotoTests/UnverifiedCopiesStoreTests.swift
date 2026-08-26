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
}
