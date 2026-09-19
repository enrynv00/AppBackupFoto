//
//  CloudUsageTextTests.swift
//  AppBackupFotoTests
//
//  `CloudUsageText` (le frasi sotto Cubbit) e `CloudUsageRefreshGate` (perche' il bottone ↻ e'
//  disattivato). Spec `Docs/superpowers/specs/2026-09-19-volume-space-indicator-design.md`,
//  ADR-0008.
//
//  Calendario, fuso e locale sono FISSATI (Europe/Rome, it_IT): senza, i test su oggi/ieri
//  fallirebbero a cavallo della mezzanotte o su un Mac con lingua diversa.
//

import XCTest
@testable import AppBackupFoto

final class CloudUsageTextTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        return cal
    }
    private let locale = Locale(identifier: "it_IT")

    private func snapshot(usedBytes: Int64 = 812_000_000_000, objectCount: Int = 120_842,
                           measuredAt: Date, bucket: String = "backupfoto") -> CloudUsageSnapshot {
        CloudUsageSnapshot(usedBytes: usedBytes, objectCount: objectCount, measuredAt: measuredAt, bucket: bucket)
    }

    // MARK: usedLine

    func testUsedLine_containsUsatiAndTheFormattedBytes() {
        let line = CloudUsageText.usedLine(snapshot(usedBytes: 812_345_678_901, measuredAt: Date()))
        XCTAssertTrue(line.contains("usati"))
        XCTAssertTrue(line.contains(SpaceFormat.bytes(812_345_678_901)))
    }

    func testUsedLine_nilSnapshot_saysNotYetCalculated() {
        XCTAssertEqual(CloudUsageText.usedLine(nil), "Spazio usato non ancora calcolato")
    }

    // MARK: updatedLine

    func testUpdatedLine_today() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 32))!
        let line = CloudUsageText.updatedLine(snapshot(measuredAt: now), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(line.hasPrefix("aggiornato oggi alle "), "trovato: \(line)")
    }

    func testUpdatedLine_yesterday() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 9, minute: 0))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 20, minute: 10))!
        let line = CloudUsageText.updatedLine(snapshot(measuredAt: yesterday), now: now,
                                               calendar: calendar, locale: locale)
        XCTAssertTrue(line.hasPrefix("aggiornato ieri alle "), "trovato: \(line)")
    }

    func testUpdatedLine_sameYear_omitsTheYear() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19))!
        let measured = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 10))!
        let line = CloudUsageText.updatedLine(snapshot(measuredAt: measured), now: now,
                                               calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("3 settembre"), "trovato: \(line)")
        XCTAssertFalse(line.contains("2026"), "l'anno non va mostrato se e' lo stesso: \(line)")
    }

    func testUpdatedLine_differentYear_includesTheYear() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19))!
        let measured = calendar.date(from: DateComponents(year: 2025, month: 9, day: 3, hour: 10))!
        let line = CloudUsageText.updatedLine(snapshot(measuredAt: measured), now: now,
                                               calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("2025"), "trovato: \(line)")
    }

    func testUpdatedLine_nilSnapshot_suggestsTheNextBackup() {
        let now = Date()
        let line = CloudUsageText.updatedLine(nil, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(line, "Si aggiorna al prossimo backup su Cubbit")
    }

    // MARK: Parole vietate

    private let forbiddenWords = ["byte", "capacità", "bucket", "oggetti", "s3", "elenco"]

    private func assertNoForbiddenWords(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        for word in forbiddenWords {
            XCTAssertFalse(lower.contains(word), "'\(word)' trovata in: \(text)", file: file, line: line)
        }
    }

    func testNoForbiddenWords_usedLine() {
        assertNoForbiddenWords(CloudUsageText.usedLine(snapshot(measuredAt: Date())))
        assertNoForbiddenWords(CloudUsageText.usedLine(nil))
    }

    func testNoForbiddenWords_updatedLine() {
        let now = Date()
        assertNoForbiddenWords(CloudUsageText.updatedLine(snapshot(measuredAt: now), now: now,
                                                            calendar: calendar, locale: locale))
        assertNoForbiddenWords(CloudUsageText.updatedLine(nil, now: now, calendar: calendar, locale: locale))
    }

    // MARK: CloudUsageRefreshGate

    func testGate_jobRunning_hasAReason() {
        XCTAssertNotNil(CloudUsageRefreshGate.disabledReason(jobIsRunning: true, isRefreshing: false))
    }

    func testGate_refreshingInProgress_hasAReason() {
        XCTAssertNotNil(CloudUsageRefreshGate.disabledReason(jobIsRunning: false, isRefreshing: true))
    }

    func testGate_neither_isNil() {
        XCTAssertNil(CloudUsageRefreshGate.disabledReason(jobIsRunning: false, isRefreshing: false))
    }
}
