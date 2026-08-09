//
//  S3SyncerShouldUploadTests.swift
//  AppBackupFotoTests
//
//  Regressione per BUG-3: S3Syncer.sync() ricaricava (sovrascrivendo) le key già
//  presenti su S3 con dimensione locale diversa, violando zero-overwrite sulla
//  copia offsite Cubbit. shouldUpload deve rispondere "no" per qualunque key già
//  presente, indipendentemente dalla dimensione.
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerShouldUploadTests: XCTestCase {

    func testNewKey_notInExisting_shouldUpload() {
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertTrue(S3Syncer.shouldUpload(key: "Foto iPhone/2024/new.jpg", existingKeys: existingKeys))
    }

    func testExistingKey_evenWithDifferentLocalSize_shouldNotUpload() {
        // Il punto centrale del fix: la dimensione locale NON deve più influenzare
        // questa decisione. Una key già presente su S3 va sempre skippata, anche se
        // il file locale è cambiato — mai sovrascrivere.
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertFalse(S3Syncer.shouldUpload(key: "Foto iPhone/2024/a.jpg", existingKeys: existingKeys))
    }

    func testEmptyExistingKeys_anyKeyShouldUpload() {
        XCTAssertTrue(S3Syncer.shouldUpload(key: "any.jpg", existingKeys: []))
    }
}
