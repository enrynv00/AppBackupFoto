import XCTest
@testable import AppBackupFoto

/// `ProgressThrottle` (ADR-0010, ROADMAP #37): al massimo un aggiornamento ogni
/// `minimumIntervalNanos`, sempre l'ultimo. Logica pura, nessun cronometro reale nel test.
final class ProgressThrottleTests: XCTestCase {

    func testFirstUpdate_isAlwaysEmitted() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100)
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 0, isFinal: false))
    }

    func testUpdateWithinInterval_isSuppressed() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100_000_000)
        _ = throttle.shouldEmit(nowNanos: 0, isFinal: false)
        XCTAssertFalse(throttle.shouldEmit(nowNanos: 50_000_000, isFinal: false))
    }

    func testUpdateAfterInterval_isEmitted() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100_000_000)
        _ = throttle.shouldEmit(nowNanos: 0, isFinal: false)
        // Il bordo e' `>=`: esattamente 100ms dopo deve emettere.
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 100_000_000, isFinal: false))
    }

    func testFinalUpdate_isAlwaysEmitted_evenWithinInterval() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100_000_000)
        _ = throttle.shouldEmit(nowNanos: 0, isFinal: false)
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 1, isFinal: true))
    }

    /// Un aggiornamento soppresso non deve spostare il riferimento: altrimenti una serie di
    /// aggiornamenti ravvicinati (piu' veloci dell'intervallo) non emetterebbe MAI piu' nulla,
    /// perche' ogni tentativo riazzererebbe la finestra da capo.
    func testSuppressedUpdate_doesNotMoveTheReference() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100_000_000)
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 0, isFinal: false))           // emesso, riferimento = 0
        XCTAssertFalse(throttle.shouldEmit(nowNanos: 60_000_000, isFinal: false)) // soppresso
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 100_000_000, isFinal: false)) // 100ms da 0, non da 60
    }

    func testClockGoingBackwards_emitsAndResets() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 100_000_000)
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 1_000_000_000, isFinal: false))
        // L'orologio torna indietro (non dovrebbe con `DispatchTime`, ma non deve incastrarsi).
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 500_000_000, isFinal: false))
        XCTAssertFalse(throttle.shouldEmit(nowNanos: 550_000_000, isFinal: false))
    }

    func testZeroInterval_emitsEverything() {
        var throttle = ProgressThrottle(minimumIntervalNanos: 0)
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 0, isFinal: false))
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 1, isFinal: false))
        XCTAssertTrue(throttle.shouldEmit(nowNanos: 2, isFinal: false))
    }
}
