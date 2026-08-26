import XCTest
@testable import AppBackupFoto

final class JobHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "JobHistoryStoreTests"

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

    func testLoad_withNoSavedData_returnsNil() {
        XCTAssertNil(JobHistoryStore.load(defaults: defaults))
    }

    func testSaveThenLoad_roundTripsAllFields() {
        let summary = JobSummary(date: Date(timeIntervalSince1970: 1_700_000_000),
                                  label: "MAC -> SSD", copied: 42, skipped: 3,
                                  errors: 1, hashErrors: 0, succeeded: true)
        JobHistoryStore.save(summary, defaults: defaults)
        let loaded = JobHistoryStore.load(defaults: defaults)

        XCTAssertEqual(loaded?.date, summary.date)
        XCTAssertEqual(loaded?.label, "MAC -> SSD")
        XCTAssertEqual(loaded?.copied, 42)
        XCTAssertEqual(loaded?.skipped, 3)
        XCTAssertEqual(loaded?.errors, 1)
        XCTAssertEqual(loaded?.hashErrors, 0)
        XCTAssertEqual(loaded?.succeeded, true)
    }

    func testIsClean_falseWhenErrorsPresent() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 1, hashErrors: 0, succeeded: true)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_falseWhenNotSucceeded() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 0,
                                  errors: 0, hashErrors: 0, succeeded: false)
        XCTAssertFalse(summary.isClean)
    }

    func testIsClean_trueWhenSucceededWithoutErrors() {
        let summary = JobSummary(date: Date(), label: "SSD -> HDD", copied: 10, skipped: 2,
                                  errors: 0, hashErrors: 0, succeeded: true)
        XCTAssertTrue(summary.isClean)
    }

    func testSaveThenLoad_roundTripsDuplicatesSkipped() {
        let summary = JobSummary(date: Date(), label: "Importa: iPhone", copied: 5, skipped: 7,
                                  errors: 0, hashErrors: 0, succeeded: true,
                                  changedSkipped: 2, duplicatesSkipped: 5)
        JobHistoryStore.save(summary, defaults: defaults)

        XCTAssertEqual(JobHistoryStore.load(defaults: defaults)?.duplicatesSkipped, 5)
        XCTAssertEqual(JobHistoryStore.load(defaults: defaults)?.changedSkipped, 2)
    }

    // Enrico ha gia' dei record sul disco, scritti da versioni precedenti dello struct.
    // Se `load` tornasse `nil` (o peggio: se la decodifica fallisse in modo rumoroso) il
    // pannello Revisione perderebbe l'ultimo job all'aggiornamento dell'app. I campi nuovi
    // devono avere un default e i vecchi record devono decodificarsi identici.
    func testRecordWrittenByAPreviousVersion_stillDecodes() throws {
        // JSON esattamente come lo scriveva la versione senza `changedSkipped` e senza
        // `duplicatesSkipped` — costruito a mano, non con l'encoder di oggi, che per
        // definizione non puo' produrre il formato di ieri.
        let legacy = #"{"date":694224000,"label":"MAC -> SSD","copied":120,"skipped":4,"errors":0,"hashErrors":0,"succeeded":true}"#
        defaults.set(Data(legacy.utf8), forKey: "lastJobSummary")

        let loaded = try XCTUnwrap(JobHistoryStore.load(defaults: defaults),
                                    "un record di una versione precedente deve restare leggibile")
        XCTAssertEqual(loaded.label, "MAC -> SSD")
        XCTAssertEqual(loaded.copied, 120)
        XCTAssertEqual(loaded.changedSkipped, 0)
        XCTAssertEqual(loaded.duplicatesSkipped, 0)
        XCTAssertTrue(loaded.isClean)
    }

    // Invariante esplicita: ne' i doppioni saltati ne' i file copiati-ma-non-verificati
    // rendono "non pulito" un job. Sarebbero allarmi quasi sempre infondati, e un allarme
    // che si impara a ignorare non serve a niente. Il rimedio per i non verificati e' la
    // precedenza nel campione d'integrita' (UnverifiedCopiesStore), non un badge rosso.
    func testIsClean_trueEvenWithSkippedDuplicates() {
        let summary = JobSummary(date: Date(), label: "Importa: iPhone", copied: 0, skipped: 30,
                                  errors: 0, hashErrors: 0, succeeded: true,
                                  changedSkipped: 0, duplicatesSkipped: 30)
        XCTAssertTrue(summary.isClean)
    }
}
