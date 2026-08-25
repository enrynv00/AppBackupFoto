import XCTest
@testable import AppBackupFoto

final class IndexEntryVerdictTests: XCTestCase {
    // Scenario base: file hashato molto tempo dopo l'ultima modifica.
    private let mtime: Double = 1_700_000_000
    private var hashedAt: Double { mtime + 3600 }   // ben oltre il margine racy

    private func verdict(size: Int64 = 100, mtime m: Double? = nil,
                         storedSize: Int64 = 100, storedMTime: Double? = nil,
                         hashedAt h: Double? = nil) -> IndexEntryVerdict {
        indexEntryVerdict(storedSize: storedSize,
                          storedMTime: storedMTime ?? mtime,
                          storedHashedAt: h ?? hashedAt,
                          currentSize: size,
                          currentMTime: m ?? mtime)
    }

    func testUnchanged_isFresh() {
        XCTAssertEqual(verdict(), .fresh)
    }

    func testSizeChanged_isStale() {
        XCTAssertEqual(verdict(size: 101), .stale)
    }

    func testMTimeChanged_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 42), .stale)
    }

    // Regola anti-racy (da git/borg): se il file risulta modificato entro il margine
    // rispetto a quando l'hash e' stato calcolato, non possiamo escludere che sia
    // cambiato subito dopo la lettura mantenendo lo stesso mtime.
    func testModifiedWithinRacyMarginOfHashing_needsVerification() {
        XCTAssertEqual(verdict(hashedAt: mtime + 1.0), .needsVerification)
    }

    func testModifiedExactlyAtRacyMarginBoundary_needsVerification() {
        XCTAssertEqual(verdict(hashedAt: mtime + 2.0), .needsVerification)
    }

    func testModifiedWellBeforeHashing_isFresh() {
        XCTAssertEqual(verdict(hashedAt: mtime + 2.5), .fresh)
    }

    // Tolleranza DST: uno shift esatto di un'ora (o mezz'ora, per i fusi a offset :30)
    // e' quasi certamente un cambio di fuso su ExFAT, non una modifica del file.
    // NON si riverifica e NON si rihasha: si adotta il nuovo mtime tenendo l'hash
    // gia' calcolato. "Riverificare" sarebbe il rehash, cioe' esattamente quello che
    // succederebbe trattandolo come `stale` — la regola non farebbe nulla. Vedi
    // ADR-0003 e testTimezoneShiftIsNotNeedsVerification qui sotto.
    func testDstShiftForward_isTimezoneShift() {
        XCTAssertEqual(verdict(mtime: mtime + 3600), .timezoneShift)
    }

    func testDstShiftBackward_isTimezoneShift() {
        XCTAssertEqual(verdict(mtime: mtime - 3600), .timezoneShift)
    }

    func testHalfHourShift_isTimezoneShift() {
        XCTAssertEqual(verdict(mtime: mtime + 1800), .timezoneShift)
    }

    func testShiftWithin10msGranularityOfDst_isTimezoneShift() {
        // ExFAT ha granularita' 10ms: uno shift DST puo' non essere esatto al microsecondo.
        XCTAssertEqual(verdict(mtime: mtime + 3600.01), .timezoneShift)
    }

    func testNearlyButNotDstShift_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 3500), .stale)
    }

    // I tre test qui sotto ancorano le tolleranze al loro valore VERO invece che a
    // 42s e 3500s, che erano i negativi piu' vicini. Aggiunti dopo un mutation test
    // (2026-08-25) che ha dimostrato il buco: `granularity` allargata da 0.05 a 2.0
    // — errore di copia-incolla plausibile, e' il valore di racyMarginSeconds due
    // righe sopra — lasciava verdi tutti e 13 i test originali, mentre un file
    // modificato 1,5s dopo l'mtime memorizzato sarebbe uscito `.fresh`. Idem per la
    // finestra DST, che sopravviveva allargata fino a 99 secondi.
    func testChangeJustAboveGranularity_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 0.2), .stale)
    }

    func testJustOutsideDstWindow_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 3600.2), .stale)
    }

    func testTwoHourShift_isStale() {
        // Nessuna tolleranza per gli shift multipli: solo 1800s e 3600s sono fusi.
        XCTAssertEqual(verdict(mtime: mtime + 7200), .stale)
    }

    // Il verdetto DST deve restare DISTINTO da needsVerification: se collassassero,
    // la regola tornerebbe a non fare nulla (entrambi -> rehash) e il rihash
    // semestrale dell'intera libreria tornerebbe.
    func testTimezoneShiftIsNotNeedsVerification() {
        XCTAssertNotEqual(verdict(mtime: mtime + 3600), .needsVerification)
        XCTAssertEqual(verdict(hashedAt: mtime + 1.0), .needsVerification)
    }

    // La dimensione ha la precedenza: se e' cambiata, il file e' cambiato, punto.
    // Nessuna tolleranza DST puo' salvarlo.
    func testDstShiftButSizeAlsoChanged_isStale() {
        XCTAssertEqual(verdict(size: 999, mtime: mtime + 3600), .stale)
    }
}
