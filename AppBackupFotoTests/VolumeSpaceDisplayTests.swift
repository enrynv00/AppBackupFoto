//
//  VolumeSpaceDisplayTests.swift
//  AppBackupFotoTests
//
//  Logica pura dell'indicatore di spazio SSD/HDD (`SpaceLevel`, `VolumeSpaceDisplay`,
//  `VolumeSpaceState`, `SpaceFormat`). Spec `Docs/superpowers/specs/2026-09-19-volume-space-
//  indicator-design.md`, ADR-0008.
//
//  Il test piu' importante di questo file e' quello contro i ridisegni: due letture che
//  differiscono di 30MB devono produrre stati `==`, perche' e' questo che impedisce a
//  `VolumeSpaceModel` (Task 3) di ripubblicare a ogni sondaggio durante una copia.
//

import XCTest
@testable import AppBackupFoto

final class VolumeSpaceDisplayTests: XCTestCase {

    // MARK: Soglie (SpaceLevel.forPercentUsed)

    func testThreshold_85_isNormal() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(85), .normal)
    }

    func testThreshold_86_isWarning() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(86), .warning)
    }

    func testThreshold_95_isWarning() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(95), .warning)
    }

    func testThreshold_96_isCritical() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(96), .critical)
    }

    func testThreshold_100_isCritical() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(100), .critical)
    }

    func testThreshold_0_isNormal() {
        XCTAssertEqual(SpaceLevel.forPercentUsed(0), .normal)
    }

    // MARK: Percentuale per difetto (VolumeSpaceDisplay)

    func testPercent_roundsDown_never100WithFreeSpaceLeft() {
        let display = VolumeSpaceDisplay(total: 1000, available: 1, volumeName: "SSD")
        XCTAssertEqual(display.percentUsed, 99)
    }

    func testPercent_zeroAvailable_is100() {
        let display = VolumeSpaceDisplay(total: 1000, available: 0, volumeName: "SSD")
        XCTAssertEqual(display.percentUsed, 100)
    }

    func testPercent_availableAboveTotal_clampedToZeroPercent_noCrash() {
        let display = VolumeSpaceDisplay(total: 1000, available: 5000, volumeName: "SSD")
        XCTAssertEqual(display.percentUsed, 0)
    }

    func testPercent_negativeAvailable_treatedAsZero() {
        let display = VolumeSpaceDisplay(total: 1000, available: -500, volumeName: "SSD")
        XCTAssertEqual(display.percentUsed, 100)
    }

    // MARK: VolumeSpaceState.from

    func testFrom_totalZero_isUnreadable() {
        let state = VolumeSpaceState.from(mounted: true, reading: .measured(total: 0, available: 0),
                                           volumeName: "SSD")
        XCTAssertEqual(state, .unreadable)
    }

    func testFrom_notMounted_isDisconnectedEvenWithAValidReading() {
        let state = VolumeSpaceState.from(mounted: false,
                                           reading: .measured(total: 1000, available: 500),
                                           volumeName: "SSD")
        XCTAssertEqual(state, .disconnected)
    }

    func testFrom_notAMountPoint_isUnreadable() {
        let state = VolumeSpaceState.from(mounted: true, reading: .notAMountPoint, volumeName: "SSD")
        XCTAssertEqual(state, .unreadable)
    }

    func testFrom_readingUnreadable_isUnreadable() {
        let state = VolumeSpaceState.from(mounted: true, reading: .unreadable, volumeName: "SSD")
        XCTAssertEqual(state, .unreadable)
    }

    // MARK: Il test contro i ridisegni

    func testTwoReadingsDiffering30MB_produceEqualStates() {
        let total: Int64 = 1_000_170_717_184
        let a = VolumeSpaceState.from(mounted: true, reading: .measured(total: total, available: 448_056_262_656),
                                       volumeName: "SSD")
        let b = VolumeSpaceState.from(mounted: true, reading: .measured(total: total, available: 448_026_262_656),
                                       volumeName: "SSD")
        XCTAssertEqual(a, b, "una differenza di 30MB non deve produrre un ridisegno")
    }

    func testTwoReadingsDiffering2GB_produceDifferentStates() {
        let total: Int64 = 1_000_170_717_184
        let a = VolumeSpaceState.from(mounted: true, reading: .measured(total: total, available: 448_056_262_656),
                                       volumeName: "SSD")
        let b = VolumeSpaceState.from(mounted: true,
                                       reading: .measured(total: total, available: 448_056_262_656 - 2_000_000_000),
                                       volumeName: "SSD")
        XCTAssertNotEqual(a, b)
    }

    func testLevelChangeAtSameText_producesDifferentStates() {
        // 85% e 86% sullo stesso totale: livello diverso (normal -> warning), percentUsed
        // diverso -> stati != anche se il testo del "liberi su" potesse restare simile.
        let total: Int64 = 1_000_000_000_000
        let avail85: Int64 = 150_000_000_000 // used 850/1000 = 85%
        let avail86: Int64 = 140_000_000_000 // used 860/1000 = 86%
        let a = VolumeSpaceState.from(mounted: true, reading: .measured(total: total, available: avail85),
                                       volumeName: "SSD")
        let b = VolumeSpaceState.from(mounted: true, reading: .measured(total: total, available: avail86),
                                       volumeName: "SSD")
        XCTAssertNotEqual(a, b)
        if case .measured(let da) = a, case .measured(let db) = b {
            XCTAssertEqual(da.level, .normal)
            XCTAssertEqual(db.level, .warning)
        } else {
            XCTFail("attesi entrambi .measured")
        }
    }

    // MARK: Testo

    func testFreeLine_composedFromSpaceFormat() {
        let total: Int64 = 1_000_170_717_184
        let available: Int64 = 448_056_262_656
        let display = VolumeSpaceDisplay(total: total, available: available, volumeName: "SSD")
        XCTAssertEqual(display.freeLine, "\(SpaceFormat.bytes(available)) liberi su \(SpaceFormat.bytes(total))")
        XCTAssertTrue(display.freeLine.contains("448 GB"), "atteso '448 GB', trovato: \(display.freeLine)")
    }

    // MARK: Parole vietate (regola 7 del piano)

    private let forbiddenWords = ["byte", "capacità", "volume", "montato"]

    private func assertNoForbiddenWords(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        for word in forbiddenWords {
            if word == "byte" && lower.contains("0 byte") { continue } // eccezione esplicita
            XCTAssertFalse(lower.contains(word), "'\(word)' trovata in: \(text)", file: file, line: line)
        }
    }

    func testNoForbiddenWords_disconnected() {
        assertNoForbiddenWords(VolumeSpaceState.disconnected.statusText)
    }

    func testNoForbiddenWords_unreadable() {
        assertNoForbiddenWords(VolumeSpaceState.unreadable.statusText)
    }

    func testNoForbiddenWords_measured() {
        let state = VolumeSpaceState.from(mounted: true,
                                           reading: .measured(total: 1_000_170_717_184, available: 448_056_262_656),
                                           volumeName: "SSD")
        assertNoForbiddenWords(state.statusText)
        if case .measured(let display) = state {
            assertNoForbiddenWords(display.accessibilityLabel)
        } else {
            XCTFail("atteso .measured")
        }
    }
}
