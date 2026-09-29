import XCTest
@testable import AppBackupFoto

/// I testi della finestra Inventario (ROADMAP #44): tutti in `InventoryStatus`, nessuno nella
/// View, e nessuna parola tecnica — la finestra la legge Enrico, non un programmatore.
final class InventoryStatusTests: XCTestCase {
    private static let gergo = ["hash", "sha", "md5", "etag", "impronta", "indice", "scansione", "cache",
                                "bucket", "sqlite", "multipart", "checksum"]

    private func assertNoJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = text.lowercased()
        for g in Self.gergo { XCTAssertFalse(t.contains(g), "gergo «\(g)» in «\(text)»", file: file, line: line) }
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func state(_ a: InventoryArchive, complete: Bool, reason: InventoryIncompleteReason? = nil,
                       unreadable: Int = 0, runId: Int64 = 1, startedAt: Double = 0,
                       finishedAt: Double? = 0) -> InventoryArchiveState {
        InventoryArchiveState(archive: a, runId: runId, complete: complete, reason: complete ? nil : reason,
                              unreadable: unreadable, startedAt: startedAt, finishedAt: finishedAt)
    }

    private func item(_ c: InventoryCategory, present: Set<InventoryArchive>, missing: Set<InventoryArchive> = [],
                      unknown: Set<InventoryArchive> = [], reasons: Set<InventoryCheckReason> = []) -> InventoryItem {
        InventoryItem(id: "x", category: c, size: 10, presentOn: present, missingFrom: missing, unknownOn: unknown,
                      checkReasons: reasons, exampleArchive: present.sorted().first ?? .ssd,
                      examplePath: "Foto iPhone/IMG_1.JPG")
    }

    func testTitles_areTheFourOfTheSpec_plusNotYetKnown() {
        XCTAssertEqual(InventoryStatus.displayOrder.map { InventoryStatus.title($0) },
                       ["✅ Al sicuro", "⚠️ Manca da qualche parte", "🔎 Solo fuori dall'SSD",
                        "❗ Da controllare", "⏳ Non si può ancora dire"])
        XCTAssertEqual(Set(InventoryStatus.displayOrder), Set(InventoryCategory.allCases))
    }

    func testCategoryLine_singularAndPlural() {
        XCTAssertTrue(InventoryStatus.categoryLine(.safe, count: 1, bytes: 10).contains("1 foto o video"))
        XCTAssertTrue(InventoryStatus.categoryLine(.safe, count: 2, bytes: 10).contains("2 foto e video"))
    }

    func testArchiveLine_withAndWithoutExtraCopies() {
        let none = InventoryStatus.archiveLine(.hdd, stats: InventoryArchiveStats(files: 3, extraCopies: 0, reclaimableBytes: 0))
        XCTAssertTrue(none.hasPrefix("HDD: 3 foto e video"))
        XCTAssertTrue(none.contains("nessuna copia in più"))
        let one = InventoryStatus.archiveLine(.s3, stats: InventoryArchiveStats(files: 3, extraCopies: 1, reclaimableBytes: 10))
        XCTAssertTrue(one.hasPrefix("Cubbit:"))
        XCTAssertTrue(one.contains("1 copia in più"))
        XCTAssertTrue(one.contains("tenendone una sola"))
        let many = InventoryStatus.archiveLine(.ssd, stats: InventoryArchiveStats(files: 9, extraCopies: 5, reclaimableBytes: 10))
        XCTAssertTrue(many.contains("5 copie in più"))
    }

    func testCompleteness_nothingToSayWhenComplete() {
        XCTAssertNil(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: true)))
    }

    func testCompleteness_neverRead() {
        let line = InventoryStatus.completenessLine(.hdd, state: nil)
        XCTAssertEqual(line?.id, "never-hdd")
        XCTAssertEqual(line?.tone, .info)
    }

    /// Ogni motivo ha la sua frase, e ogni frase dice la regola: da li' non si dichiara
    /// mancante niente.
    func testCompleteness_everyReasonHasItsOwnText_andStatesTheRule() {
        let reasons: [InventoryIncompleteReason] = [.running, .notReached, .interrupted, .volumeVanished,
                                                     .foldersUnreadable, .filesUnreadable, .sawNothing,
                                                     .listingFailed, .listingMalformed, .couldNotSave]
        var texts = Set<String>()
        for r in reasons {
            let line = InventoryStatus.completenessLine(.hdd, state: state(.hdd, complete: false, reason: r, unreadable: 3))
            XCTAssertEqual(line?.tone, .warning)
            XCTAssertTrue(line?.text.contains("non dice mai che una foto manca") == true, "\(r)")
            assertNoJargon(line?.text ?? "")
            texts.insert(line?.text ?? "")
        }
        XCTAssertEqual(texts.count, reasons.count)
    }

    func testCompleteness_unreadableFiles_singularAndPlural() {
        XCTAssertTrue(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: false, reason: .filesUnreadable,
                                                                          unreadable: 1))!.text.contains("1 file non si è lasciato"))
        XCTAssertTrue(InventoryStatus.completenessLine(.ssd, state: state(.ssd, complete: false, reason: .filesUnreadable,
                                                                          unreadable: 4))!.text.contains("4 file non si sono lasciati"))
    }

    func testFreshness_neverDone() {
        let line = InventoryStatus.freshnessLine(states: [:], now: Date(), calendar: utc)
        XCTAssertEqual(line.id, "never")
        XCTAssertEqual(line.tone, .info)
    }

    func testFreshness_completeRun_saysWhen() {
        let finished = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26 00:00 UTC
        let states = Dictionary(uniqueKeysWithValues: InventoryArchive.allCases.map {
            ($0, state($0, complete: true, finishedAt: finished.timeIntervalSince1970))
        })
        let today = InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(3_600), calendar: utc)
        XCTAssertEqual(today.id, "complete")
        XCTAssertTrue(today.text.contains("oggi"))
        XCTAssertTrue(today.text.contains("26 settembre 2026"))
        XCTAssertTrue(InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(86_400),
                                                    calendar: utc).text.contains("ieri"))
        XCTAssertTrue(InventoryStatus.freshnessLine(states: states, now: finished.addingTimeInterval(5 * 86_400),
                                                    calendar: utc).text.contains("5 giorni fa"))
    }

    func testFreshness_incompleteRun_isAWarning() {
        let states: [InventoryArchive: InventoryArchiveState] = [
            .ssd: state(.ssd, complete: true), .hdd: state(.hdd, complete: false, reason: .interrupted),
            .s3: state(.s3, complete: true)]
        let line = InventoryStatus.freshnessLine(states: states, now: Date(timeIntervalSince1970: 0), calendar: utc)
        XCTAssertEqual(line.id, "incomplete")
        XCTAssertEqual(line.tone, .warning)
    }

    func testItemLine_perCategory() {
        XCTAssertTrue(InventoryStatus.itemLine(item(.safe, present: [.ssd, .hdd, .s3])).contains("su SSD, HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.missingSomewhere, present: [.ssd], missing: [.hdd, .s3]))
            .contains("manca da: HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.missingSomewhere, present: [.hdd], missing: [.s3], unknown: [.ssd]))
            .contains("su SSD non si sa ancora"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.onlyOutsideSSD, present: [.hdd, .s3])).contains("c'è solo su HDD e Cubbit"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.toCheck, present: [.ssd], reasons: [.samePathDifferentContent]))
            .contains("stesso nome"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.toCheck, present: [.s3], reasons: [.cubbitNotCertifiable]))
            .contains("senza scaricarla"))
        XCTAssertTrue(InventoryStatus.itemLine(item(.undetermined, present: [.ssd], unknown: [.hdd]))
            .contains("su HDD non si sa ancora"))
    }

    func testProgressLine_saysTheStepOutOfThree() {
        var r = InventoryScanReport(); r.scanned = 12; r.reread = 3
        XCTAssertTrue(InventoryStatus.progressLine(.local(.ssd, r)).hasPrefix("1 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.local(.hdd, r)).hasPrefix("2 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.local(.hdd, r)).contains("12 viste"))
        var c = CubbitReadReport(); c.objectsKept = 7
        XCTAssertTrue(InventoryStatus.progressLine(.cubbit(c)).hasPrefix("3 di 3"))
        XCTAssertTrue(InventoryStatus.progressLine(.cubbit(c)).contains("7"))
    }

    func testSampleLimitLine() {
        XCTAssertNil(InventoryStatus.sampleLimitLine(shown: 3, total: 3))
        XCTAssertEqual(InventoryStatus.sampleLimitLine(shown: 300, total: 450), "Qui ne vedi 300 su 450, in ordine di nome.")
    }

    func testReadOnlyNote_namesAllThreePlaces() {
        for name in ["SSD", "HDD", "Cubbit"] { XCTAssertTrue(InventoryStatus.readOnlyNote.contains(name)) }
    }

    /// Tutte le diramazioni, non un campione.
    func testNoJargon_onEveryText() {
        var texts = [InventoryStatus.readOnlyNote, InventoryStatus.stoppingLine, InventoryStatus.loadingLine,
                     InventoryStatus.refreshButton, InventoryStatus.stopButton,
                     InventoryStatus.freshnessLine(states: [:], now: Date(), calendar: utc).text,
                     InventoryStatus.progressLine(.checkingCubbit), InventoryStatus.progressLine(.classifying),
                     InventoryStatus.progressLine(.cubbit(CubbitReadReport())),
                     InventoryStatus.progressLine(.local(.ssd, InventoryScanReport()))]
        for c in InventoryCategory.allCases {
            texts.append(InventoryStatus.title(c))
            texts.append(InventoryStatus.explanation(c))
            texts.append(InventoryStatus.categoryLine(c, count: 2, bytes: 1_000))
            texts.append(InventoryStatus.itemLine(item(c, present: [.ssd], missing: [.hdd], unknown: [.s3],
                                                       reasons: [.samePathDifferentContent])))
            texts.append(InventoryStatus.itemLine(item(c, present: [.s3], reasons: [.cubbitNotCertifiable])))
        }
        for a in InventoryArchive.allCases {
            texts.append(InventoryStatus.archiveLine(a, stats: InventoryArchiveStats(files: 2, extraCopies: 1, reclaimableBytes: 5)))
            texts.append(InventoryStatus.completenessLine(a, state: nil)!.text)
        }
        texts.forEach { assertNoJargon($0) }
    }
}
