//
//  S3ListingTests.swift
//  AppBackupFotoTests
//
//  `S3Syncer.collectPages` (completezza dell'elenco, con un fetcher finto, senza rete) e
//  `S3Syncer.CloudUsageTotals` (somma, correzione a fine sync). Spec `Docs/superpowers/specs/
//  2026-09-19-volume-space-indicator-design.md`, ADR-0008.
//
//  Il test piu' importante di questo file: uno stop PRIMA della prima pagina deve dare un
//  elenco vuoto E incompleto (mai "completo con zero oggetti", che si leggerebbe come "0 byte
//  usati" — il side-finding della spec sull'anteprima dopo uno stop).
//

import XCTest
@testable import AppBackupFoto

final class S3ListingTests: XCTestCase {

    // MARK: collectPages

    func testAllPagesRead_isComplete_keysMerged() async throws {
        let pages: [(objs: [String: Int64], next: String?)] = [
            (["a": 1], "t1"),
            (["b": 2], "t2"),
            (["c": 3], nil),
        ]
        var index = 0
        let listing = try await S3Syncer.collectPages(fetch: { _ in
            let page = pages[index]; index += 1
            return page
        }, shouldStop: { false })

        XCTAssertTrue(listing.isComplete)
        XCTAssertEqual(listing.objects, ["a": 1, "b": 2, "c": 3])
        XCTAssertEqual(index, 3)
    }

    func testStopBeforeFirstPage_isIncomplete_emptyAndFetchNeverCalled() async throws {
        var fetchCalls = 0
        let listing = try await S3Syncer.collectPages(fetch: { _ in
            fetchCalls += 1
            return (["a": 1], nil)
        }, shouldStop: { true })

        XCTAssertFalse(listing.isComplete)
        XCTAssertTrue(listing.objects.isEmpty)
        XCTAssertEqual(fetchCalls, 0)
    }

    func testStopAfterFirstOfThreePages_isIncomplete() async throws {
        let pages: [(objs: [String: Int64], next: String?)] = [
            (["a": 1], "t1"),
            (["b": 2], "t2"),
            (["c": 3], nil),
        ]
        var index = 0
        let listing = try await S3Syncer.collectPages(fetch: { _ in
            let page = pages[index]; index += 1
            return page
        }, shouldStop: { index >= 1 })

        XCTAssertFalse(listing.isComplete)
        XCTAssertEqual(listing.objects, ["a": 1])
    }

    private struct FakeFetchError: Error {}

    func testFetchThrowsAtSecondPage_collectPagesThrows() async {
        var calls = 0
        do {
            _ = try await S3Syncer.collectPages(fetch: { _ in
                calls += 1
                if calls == 2 { throw FakeFetchError() }
                return (["a": 1], "t1")
            }, shouldStop: { false })
            XCTFail("atteso un lancio")
        } catch is FakeFetchError {
            // atteso
        } catch {
            XCTFail("errore inatteso: \(error)")
        }
    }

    // MARK: CloudUsageTotals

    func testTotalsOf_sumsBytesAndCounts() {
        let totals = S3Syncer.CloudUsageTotals.of(["a": 100, "b": 250, "c": 50])
        XCTAssertEqual(totals.bytes, 400)
        XCTAssertEqual(totals.count, 3)
    }

    func testTotalsOf_emptyDictionary_isZero() {
        let totals = S3Syncer.CloudUsageTotals.of([:])
        XCTAssertEqual(totals, S3Syncer.CloudUsageTotals(bytes: 0, count: 0))
    }

    func testAfterSync_notCancelled_correctsWithUploads() {
        let listed = S3Syncer.CloudUsageTotals(bytes: 100, count: 10)
        let result = S3Syncer.CloudUsageTotals.afterSync(listed: listed, uploadedBytes: 50,
                                                           uploadedCount: 2, wasCancelled: false)
        XCTAssertEqual(result, S3Syncer.CloudUsageTotals(bytes: 150, count: 12))
    }

    func testAfterSync_wasCancelled_isNil() {
        let listed = S3Syncer.CloudUsageTotals(bytes: 100, count: 10)
        let result = S3Syncer.CloudUsageTotals.afterSync(listed: listed, uploadedBytes: 50,
                                                           uploadedCount: 2, wasCancelled: true)
        XCTAssertNil(result)
    }

    func testAfterSync_listedNil_isNil() {
        let result = S3Syncer.CloudUsageTotals.afterSync(listed: nil, uploadedBytes: 50,
                                                           uploadedCount: 2, wasCancelled: false)
        XCTAssertNil(result)
    }

    func testAfterSync_zeroUploaded_confirmsTheListedValue() {
        let listed = S3Syncer.CloudUsageTotals(bytes: 812, count: 120_842)
        let result = S3Syncer.CloudUsageTotals.afterSync(listed: listed, uploadedBytes: 0,
                                                           uploadedCount: 0, wasCancelled: false)
        XCTAssertEqual(result, listed)
    }
}
