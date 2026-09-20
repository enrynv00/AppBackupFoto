import XCTest
@testable import AppBackupFoto

/// `FreeSpaceCheck` (ROADMAP #39): il margine e' copiato identico da `hasSufficientSpace`
/// (rimossa), non riscritto — questi test fissano il confine.
final class FreeSpaceCheckTests: XCTestCase {

    func testExactlyEnough_isEnough() {
        let needed: Int64 = 1_000_000_000
        let margin = max(Int64(Double(needed) * 0.05), 500_000_000)
        let verdict = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                             reading: .measured(total: 10_000_000_000, available: needed + margin))
        XCTAssertEqual(verdict, .enough)
    }

    func testOneByteShort_isNotEnough() {
        let needed: Int64 = 1_000_000_000
        let margin = max(Int64(Double(needed) * 0.05), 500_000_000)
        let verdict = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                             reading: .measured(total: 10_000_000_000, available: needed + margin - 1))
        guard case .notEnough = verdict else { return XCTFail("atteso .notEnough, trovato \(verdict)") }
    }

    func testSmallJob_usesTheMinimumMarginOf500MB() {
        // Job piccolo: 5% sarebbe pochissimo, deve valere il minimo di 500 MB.
        let needed: Int64 = 10_000_000   // 10 MB, 5% = 500.000 byte
        let verdict = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                             reading: .measured(total: 1_000_000_000, available: needed + 500_000_000 - 1))
        guard case .notEnough = verdict else { return XCTFail("il margine minimo di 500 MB non e' stato applicato") }
        let verdictOk = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                               reading: .measured(total: 1_000_000_000, available: needed + 500_000_000))
        XCTAssertEqual(verdictOk, .enough)
    }

    func testLargeJob_usesFivePercent() {
        // Bordo dove il 5% supera 500 MB: 10 GB → 5% = 500 MB esatti; oltre, il 5% vince.
        let needed: Int64 = 20_000_000_000   // 20 GB, 5% = 1 GB > 500 MB
        let margin: Int64 = 1_000_000_000
        let verdict = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                             reading: .measured(total: 100_000_000_000, available: needed + margin - 1))
        guard case .notEnough = verdict else { return XCTFail("il 5% non e' stato applicato sopra il minimo") }
        let verdictOk = FreeSpaceCheck.verdict(bytesNeeded: needed,
                                               reading: .measured(total: 100_000_000_000, available: needed + margin))
        XCTAssertEqual(verdictOk, .enough)
    }

    func testNothingToCopy_stillRequiresTheMinimumMargin() {
        let verdict = FreeSpaceCheck.verdict(bytesNeeded: 0,
                                             reading: .measured(total: 1_000_000_000, available: 400_000_000))
        guard case .notEnough = verdict else { return XCTFail("bytesNeeded 0 deve comunque pretendere il margine minimo") }
        let verdictOk = FreeSpaceCheck.verdict(bytesNeeded: 0,
                                               reading: .measured(total: 1_000_000_000, available: 500_000_000))
        XCTAssertEqual(verdictOk, .enough)
    }

    func testNotAMountPoint_isNotADisk() {
        XCTAssertEqual(FreeSpaceCheck.verdict(bytesNeeded: 1000, reading: .notAMountPoint), .notADisk)
    }

    func testUnreadable_isUnreadable_neverEnough() {
        XCTAssertEqual(FreeSpaceCheck.verdict(bytesNeeded: 1000, reading: .unreadable), .unreadable)
    }

    func testMessages_carryNoJargon() {
        let testi = [FreeSpaceCheck.notADiskMessage(diskName: "SSD"),
                     FreeSpaceCheck.notADiskMessage(diskName: "HDD"),
                     FreeSpaceCheck.unreadableMessage(diskName: "SSD"),
                     FreeSpaceCheck.unreadableMessage(diskName: "HDD")]
        for testo in testi {
            XCTAssertFalse(testo.isEmpty)
            for parola in ["hash", "indice", "scansione", "sqlite", "cache", "entry", "mtime"] {
                XCTAssertFalse(testo.lowercased().contains(parola), "gergo in «\(testo)»")
            }
        }
        // I due dischi hanno frasi distinte (nominano il disco giusto).
        XCTAssertNotEqual(FreeSpaceCheck.notADiskMessage(diskName: "SSD"),
                          FreeSpaceCheck.notADiskMessage(diskName: "HDD"))
    }
}
