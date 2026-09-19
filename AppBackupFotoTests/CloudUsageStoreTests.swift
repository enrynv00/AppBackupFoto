//
//  CloudUsageStoreTests.swift
//  AppBackupFotoTests
//
//  Persistenza dello spazio usato su Cubbit (`CloudUsageSnapshot`, `CloudUsageStore.record`).
//  Spec `Docs/superpowers/specs/2026-09-19-volume-space-indicator-design.md`, ADR-0008.
//
//  Il test piu' importante: un record senza `objectCount` (forma piu' vecchia del campo, che
//  non esiste ancora oggi ma che il fatto misurato n. 5 di #31 insegna a non dare per
//  scontato) deve decodificare comunque, non far sparire tutto lo snapshot.
//

import XCTest
@testable import AppBackupFoto

final class CloudUsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CloudUsageStoreTests"
    private let key = "cloudUsageSnapshot"

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

    func testRecord_thenNewStoreOnSameDefaults_readsTheSameSnapshot() {
        let store = CloudUsageStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(S3Syncer.CloudUsageTotals(bytes: 812_000_000_000, count: 120_842),
                     bucket: "backupfoto", at: date)

        let reloaded = CloudUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot?.usedBytes, 812_000_000_000)
        XCTAssertEqual(reloaded.snapshot?.objectCount, 120_842)
        XCTAssertEqual(reloaded.snapshot?.bucket, "backupfoto")
        XCTAssertEqual(reloaded.snapshot?.measuredAt, date)
    }

    func testEmptyDefaults_snapshotIsNil() {
        let store = CloudUsageStore(defaults: defaults)
        XCTAssertNil(store.snapshot)
    }

    func testNonJSONDataUnderKey_snapshotIsNil_noCrash() {
        defaults.set("non e' JSON".data(using: .utf8)!, forKey: key)
        let store = CloudUsageStore(defaults: defaults)
        XCTAssertNil(store.snapshot)
    }

    func testJSONWithoutObjectCount_decodesWithZero() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {"usedBytes": 500, "measuredAt": \(date.timeIntervalSinceReferenceDate), "bucket": "backupfoto"}
        """
        defaults.set(json.data(using: .utf8)!, forKey: key)
        let store = CloudUsageStore(defaults: defaults)
        XCTAssertEqual(store.snapshot?.usedBytes, 500)
        XCTAssertEqual(store.snapshot?.objectCount, 0)
        XCTAssertEqual(store.snapshot?.bucket, "backupfoto")
    }

    func testRecord_updatesThePublishedSnapshot() {
        let store = CloudUsageStore(defaults: defaults)
        XCTAssertNil(store.snapshot)
        store.record(S3Syncer.CloudUsageTotals(bytes: 100, count: 5), bucket: "backupfoto")
        XCTAssertEqual(store.snapshot?.usedBytes, 100)
    }

    func testRecord_withDifferentBucket_overwritesTheSnapshot() {
        let store = CloudUsageStore(defaults: defaults)
        store.record(S3Syncer.CloudUsageTotals(bytes: 100, count: 5), bucket: "backupfoto")
        store.record(S3Syncer.CloudUsageTotals(bytes: 200, count: 9), bucket: "altro-bucket")
        XCTAssertEqual(store.snapshot?.usedBytes, 200)
        XCTAssertEqual(store.snapshot?.bucket, "altro-bucket")
    }

    // Rilievo di review del 2026-09-19: un ↻ partito prima di un SSD -> Cubbit non deve
    // sovrascrivere, arrivando per ultimo, il totale esatto registrato dal backup.
    func testRecordUnlessSuperseded_newerRecordArrivedMeanwhile_isDiscarded() {
        let store = CloudUsageStore(defaults: defaults)
        let token = store.recordCount                       // il ↻ parte
        store.record(S3Syncer.CloudUsageTotals(bytes: 900, count: 12), bucket: "backupfoto")  // il backup finisce
        let recorded = store.recordUnlessSuperseded(S3Syncer.CloudUsageTotals(bytes: 800, count: 10),
                                                    bucket: "backupfoto", since: token)       // il ↻ arriva
        XCTAssertFalse(recorded)
        XCTAssertEqual(store.snapshot?.usedBytes, 900)
        XCTAssertEqual(CloudUsageStore(defaults: defaults).snapshot?.usedBytes, 900)
    }

    func testRecordUnlessSuperseded_nothingNewer_records() {
        let store = CloudUsageStore(defaults: defaults)
        store.record(S3Syncer.CloudUsageTotals(bytes: 500, count: 5), bucket: "backupfoto")
        let token = store.recordCount
        let recorded = store.recordUnlessSuperseded(S3Syncer.CloudUsageTotals(bytes: 800, count: 10),
                                                    bucket: "backupfoto", since: token)
        XCTAssertTrue(recorded)
        XCTAssertEqual(store.snapshot?.usedBytes, 800)
    }
}
