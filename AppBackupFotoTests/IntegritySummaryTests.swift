//
//  IntegritySummaryTests.swift
//  AppBackupFotoTests
//
//  Le righe del campione d'integrita' (`IntegritySummary`), logica pura.
//
//  Perche' esistono: fino al 2026-09-03 la view mostrava solo `matched/checked` e buttava via
//  `skippedNoSource` e `skippedUnreadable`. Il secondo e' un sospetto di file illeggibile —
//  cioe' proprio la cosa che un campione d'integrita' esiste per trovare — e spariva in
//  silenzio. Il primo diventa normale e frequente dopo il pannello Doppioni, e taceva il
//  motivo per cui il campione risultava piu' piccolo di quello richiesto.
//

import XCTest
@testable import AppBackupFoto

final class IntegritySummaryTests: XCTestCase {

    private func risultato(_ mutate: (inout IntegrityCheckResult) -> Void) -> IntegrityCheckResult {
        var r = IntegrityCheckResult(pairName: "SSD ↔ HDD")
        mutate(&r)
        return r
    }

    // MARK: Esito

    func testCleanRun_saysNoDifference() {
        let lines = IntegritySummary.lines(for: risultato { $0.checked = 50; $0.matched = 50 })
        let esito = lines.first { $0.id == "esito" }
        XCTAssertEqual(esito?.tone, .ok)
        XCTAssertTrue(esito?.text.contains("nessuna differenza") ?? false)
    }

    func testMismatches_areReportedAsWarningWithTheCount() {
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 50; $0.matched = 48; $0.mismatches = ["a.jpg", "b.jpg"]
        })
        let esito = lines.first { $0.id == "esito" }
        XCTAssertEqual(esito?.tone, .warning)
        XCTAssertTrue(esito?.text.contains("2") ?? false)
    }

    func testError_isTheOnlyLine() {
        let lines = IntegritySummary.lines(for: risultato { $0.error = "HDD non collegato" })
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.tone, .warning)
    }

    // MARK: I due contatori che prima sparivano

    /// Dopo il pannello Doppioni questo caso diventa la norma: il campione enumera l'HDD, e i
    /// doppioni tolti dall'SSD non hanno piu' un gemello da confrontare. **Non e' un guasto**,
    /// ed e' precisamente cio' che Enrico ha chiesto (l'HDD conserva tutto). Ma va detto,
    /// altrimenti il campione sembra piu' piccolo di quello richiesto senza spiegazione.
    func testFilesWithNoSource_areReportedAsNormal_notAsAProblem() {
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 30; $0.matched = 30; $0.skippedNoSource = 70
        })
        guard let riga = lines.first(where: { $0.id == "senza-origine" }) else {
            return XCTFail("i file senza origine non vengono riportati affatto")
        }
        XCTAssertEqual(riga.tone, .info, "non e' un guasto: e' il comportamento voluto")
        XCTAssertTrue(riga.text.contains("70"))
        XCTAssertTrue(riga.text.lowercased().contains("normale"),
                      "deve rassicurare, non allarmare: «\(riga.text)»")
    }

    /// Questo invece **e'** un sospetto: il file c'e' ma non si e' lasciato leggere.
    /// Nasconderlo era il difetto peggiore dei due.
    func testUnreadableFiles_areReportedAsWarning() {
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 30; $0.matched = 30; $0.skippedUnreadable = 3
        })
        guard let riga = lines.first(where: { $0.id == "illeggibili" }) else {
            return XCTFail("i file illeggibili non vengono riportati affatto")
        }
        XCTAssertEqual(riga.tone, .warning)
        XCTAssertTrue(riga.text.contains("3"))
    }

    /// I due contatori sono situazioni diverse e devono restare distinte.
    func testTheTwoSkipKinds_areDifferentLinesWithDifferentTones() {
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 10; $0.matched = 10; $0.skippedNoSource = 5; $0.skippedUnreadable = 2
        })
        let senza = lines.first { $0.id == "senza-origine" }
        let ill = lines.first { $0.id == "illeggibili" }
        XCTAssertNotNil(senza); XCTAssertNotNil(ill)
        XCTAssertNotEqual(senza?.tone, ill?.tone)
        XCTAssertNotEqual(senza?.text, ill?.text)
    }

    /// A zero non compaiono: una riga «0 file saltati» e' rumore.
    func testZeroCounters_produceNoExtraLines() {
        let lines = IntegritySummary.lines(for: risultato { $0.checked = 10; $0.matched = 10 })
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: Registro

    func testNoJargonReachesTheScreen() {
        let gergo = ["hash", "sha256", "mismatch", "indice", "entry", "dedup"]
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 10; $0.matched = 8; $0.mismatches = ["x.jpg"]
            $0.skippedNoSource = 4; $0.skippedUnreadable = 1
        })
        for line in lines {
            for parola in gergo {
                XCTAssertFalse(line.text.lowercased().contains(parola),
                               "gergo: '\(parola)' in «\(line.text)»")
            }
        }
    }

    func testIdsAreUnique() {
        let lines = IntegritySummary.lines(for: risultato {
            $0.checked = 10; $0.matched = 8; $0.mismatches = ["x.jpg"]
            $0.skippedNoSource = 4; $0.skippedUnreadable = 1
        })
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
    }
}
