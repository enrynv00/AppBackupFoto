//
//  S3SyncerChangedKeyTests.swift
//  AppBackupFotoTests
//
//  Verifica S3Syncer.isChangedExistingKey — funzione pura, nessuna rete.
//  Conteggio informativo per il roadmap #13, non influenza la decisione di
//  upload (S3Syncer.shouldUpload, già corretta dal fix di BUG-3).
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerChangedKeyTests: XCTestCase {

    func testKeyAbsentFromExisting_isNotChanged() {
        // Una key assente è un file NUOVO, non "cambiato" — shouldUpload la caricherà,
        // isChangedExistingKey non deve contarla come cambiata.
        XCTAssertFalse(S3Syncer.isChangedExistingKey(key: "new.jpg", size: 1000, existing: [:]))
    }

    func testKeyPresentWithDifferentSize_isChanged() {
        let existing: [String: Int64] = ["a.jpg": 500]
        XCTAssertTrue(S3Syncer.isChangedExistingKey(key: "a.jpg", size: 1000, existing: existing))
    }

    func testKeyPresentWithSameSize_isNotChanged() {
        let existing: [String: Int64] = ["a.jpg": 1000]
        XCTAssertFalse(S3Syncer.isChangedExistingKey(key: "a.jpg", size: 1000, existing: existing))
    }
}
