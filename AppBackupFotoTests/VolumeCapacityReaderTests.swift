//
//  VolumeCapacityReaderTests.swift
//  AppBackupFotoTests
//
//  `VolumeCapacityReader.read(path:)` su file veri, niente mock. Spec `Docs/superpowers/
//  specs/2026-09-19-volume-space-indicator-design.md`, ADR-0008.
//
//  Il caso piu' importante: una cartella normale al posto di un volume deve dare
//  `.notAMountPoint`, non la capacita' del disco che la contiene — altrimenti un SSD
//  scollegato con una cartella omonima rimasta sul disco interno mostrerebbe lo spazio del
//  Mac sotto il nome dell'SSD.
//

import XCTest
@testable import AppBackupFoto

final class VolumeCapacityReaderTests: XCTestCase {

    func testRoot_isMeasured_totalPositive_availableWithinTotal() {
        let reading = VolumeCapacityReader.read(path: "/")
        guard case .measured(let total, let available) = reading else {
            XCTFail("atteso .measured, trovato \(reading)"); return
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThanOrEqual(available, 0)
        XCTAssertLessThanOrEqual(available, total)
    }

    func testOrdinaryFolder_isNotAMountPoint_notTheCapacityOfTheDiskThatContainsIt() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeCapacityReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reading = VolumeCapacityReader.read(path: dir.path)
        XCTAssertEqual(reading, .notAMountPoint)
    }

    func testNonexistentPath_isUnreadable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        XCTAssertEqual(VolumeCapacityReader.read(path: missing), .unreadable)
    }

    func testTrailingSlash_givesSameOutcomeAsWithout() {
        // Copre anche la trappola /var <-> /private/var della directory temporanea: il
        // confronto e' per componenti canoniche, non per stringa.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeCapacityReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let withoutSlash = VolumeCapacityReader.read(path: dir.path)
        let withSlash = VolumeCapacityReader.read(path: dir.path + "/")
        XCTAssertEqual(withoutSlash, withSlash)
        XCTAssertEqual(withoutSlash, .notAMountPoint)
    }

    // MARK: - ROADMAP #40: una cartella al posto del disco non e' il disco

    func testIsMounted_folderInPlaceOfTheDisk_isNotMounted() {
        XCTAssertFalse(VolumeCapacityReader.isMounted(exists: true, reading: .notAMountPoint))
    }

    func testIsMounted_realVolume_isMounted() {
        XCTAssertTrue(VolumeCapacityReader.isMounted(exists: true, reading: .measured(total: 10, available: 5)))
    }

    func testIsMounted_unreadableCapacity_staysMounted() {
        // Un HDD che dorme puo' non rispondere alla lettura di capacita': non e' un motivo
        // per disattivare i pulsanti. Solo "non e' un punto di montaggio" lo e'.
        XCTAssertTrue(VolumeCapacityReader.isMounted(exists: true, reading: .unreadable))
    }

    func testIsMounted_missingPath_isNotMounted() {
        XCTAssertFalse(VolumeCapacityReader.isMounted(exists: false, reading: nil))
    }
}
