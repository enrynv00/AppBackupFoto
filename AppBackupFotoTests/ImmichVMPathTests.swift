//
//  ImmichVMPathTests.swift
//  AppBackupFotoTests
//
//  Il limite di lunghezza del socket UNIX della VM (roadmap #29).
//
//  Perche' questo file esiste: il 2026-09-03, provando per la prima volta ad avviare davvero
//  Colima, e' emerso che `LIMA_HOME` sotto Application Support produceva un percorso di socket
//  da **117 caratteri** contro un massimo di sistema di **104**. `colima start` moriva sempre,
//  subito, con un errore di Lima che non nomina la causa vera. La feature era "codice completo"
//  da tre settimane e **non poteva funzionare**: nessuno l'aveva mai eseguita.
//
//  Questi test fissano il limite in modo che non possa tornare in silenzio: se qualcuno
//  riportera' quelle cartelle sotto Application Support "per coerenza", diventano rossi.
//

import XCTest
@testable import AppBackupFoto

final class ImmichVMPathTests: XCTestCase {

    /// Il percorso che il codice usava prima della correzione. Fissato come **letterale**, non
    /// ricostruito dalle costanti dell'app: se un domani qualcuno cambia le costanti, questo
    /// test deve continuare a dire "quella forma li' non ci sta", che e' il fatto storico.
    func testTheOldApplicationSupportPath_didNotFit() {
        let vecchio = "/Users/enriconannivicenzi/Library/Application Support/AppBackupFoto/immich/lima-home"
        XCTAssertFalse(ImmichManager.vmSocketPathFits(limaHome: vecchio),
                       "il percorso storico deve risultare troppo lungo: e' il bug che questo file documenta")
        XCTAssertEqual(ImmichManager.socketPathLength(limaHome: vecchio), 117)
    }

    /// Il percorso attuale ci sta, e con margine.
    func testTheCurrentPrivateHome_fits() {
        let attuale = "/Users/enriconannivicenzi/.appbackupfoto-vm/lima"
        XCTAssertTrue(ImmichManager.vmSocketPathFits(limaHome: attuale))
        let lunghezza = ImmichManager.socketPathLength(limaHome: attuale)
        XCTAssertLessThanOrEqual(lunghezza, 104)
        XCTAssertLessThanOrEqual(lunghezza, 90, "serve margine, non il pelo: \(lunghezza)")
    }

    /// Il confine esatto, in entrambi i versi. 104 passa, 105 no.
    func testTheBoundaryIsExactlyOneHundredAndFour() {
        // "/x" + riempimento + "/colima/ssh.sock.1234567890123456" (33 caratteri)
        let coda = "/colima/ssh.sock.1234567890123456".count
        let home104 = String(repeating: "a", count: 104 - coda)
        XCTAssertEqual(ImmichManager.socketPathLength(limaHome: home104), 104)
        XCTAssertTrue(ImmichManager.vmSocketPathFits(limaHome: home104))

        let home105 = String(repeating: "a", count: 105 - coda)
        XCTAssertEqual(ImmichManager.socketPathLength(limaHome: home105), 105)
        XCTAssertFalse(ImmichManager.vmSocketPathFits(limaHome: home105))
    }

    /// Un nome utente molto lungo puo' far sforare anche il percorso nuovo: e' il caso che la
    /// guardia in `start` esiste per intercettare con un messaggio comprensibile invece di un
    /// errore di Lima.
    func testAVeryLongUsername_canStillOverflow_andIsDetected() {
        let lungo = "/Users/\(String(repeating: "e", count: 80))/.appbackupfoto-vm/lima"
        XCTAssertFalse(ImmichManager.vmSocketPathFits(limaHome: lungo))
    }
}
