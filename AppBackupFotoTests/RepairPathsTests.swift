import XCTest
@testable import AppBackupFoto

/// `RepairPaths` (ROADMAP #45, ADR-0016): dove va la copia rovinata e dove si prepara quella
/// buona. Stessa chiave relativa, caratteri speciali compresi, mai un'uscita dalla cartella.
final class RepairPathsTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    /// 2026-10-03T22:30:00Z: a Roma (UTC+2) e' gia' il 4 ottobre.
    private let lateEvening = Date(timeIntervalSince1970: 1_791_066_600)

    func testQuarantineFolder_isTheExcludedOne() {
        XCTAssertEqual(RepairPaths.quarantineFolder, LibraryExclusions.quarantineFolderName,
                       "la riparazione deve scrivere proprio nella cartella che tutti escludono")
    }

    func testDayFolder_isTheLocalDay() {
        XCTAssertEqual(RepairPaths.dayFolder(for: lateEvening, calendar: calendar("Europe/Rome")), "2026-10-04")
        XCTAssertEqual(RepairPaths.dayFolder(for: lateEvening, calendar: calendar("UTC")), "2026-10-03")
        XCTAssertEqual(RepairPaths.dayFolder(for: Date(timeIntervalSince1970: 0), calendar: calendar("UTC")), "1970-01-01")
    }

    func testDefaultCalendar_isGregorianInTheMacTimeZone() {
        XCTAssertEqual(RepairPaths.defaultCalendar.identifier, .gregorian)
        XCTAssertEqual(RepairPaths.defaultCalendar.timeZone, TimeZone.current)
    }

    func testQuarantinePath_keepsTheSameRelativePath() {
        let rome = calendar("Europe/Rome")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic",
                                                  date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "Foto/l'isola+mare è.jpg", date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/Foto/l'isola+mare è.jpg", "+ e apostrofo restano come sono")
        XCTAssertEqual(RepairPaths.quarantinePath(for: "a.jpg", date: lateEvening, calendar: rome),
                       "_quarantena/2026-10-04/a.jpg")
    }

    func testUnsafePaths_areRefused() {
        let rome = calendar("Europe/Rome")
        for bad in ["", "/assoluto.jpg", "../fuori.jpg", "Foto/../../fuori.jpg", "Foto/./a.jpg", "Foto//a.jpg",
                    "Foto/", ".", "..", "_quarantena/2026-10-04/a.jpg", "_Quarantena/a.jpg"] {
            XCTAssertNil(RepairPaths.quarantinePath(for: bad, date: lateEvening, calendar: rome), bad)
            XCTAssertNil(RepairPaths.safeComponents(bad), bad)
        }
        XCTAssertEqual(RepairPaths.safeComponents("Foto/..a/b..jpg"), ["Foto", "..a", "b..jpg"],
                       "i punti dentro un nome non sono un'uscita")
    }

    func testStagingPath_sitsNextToTheQuarantineCopy() {
        let rome = calendar("Europe/Rome")
        XCTAssertEqual(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: "1a2b3c4d"),
                       "_quarantena/2026-10-04/Foto/a.jpg.in-arrivo-1a2b3c4d")
        XCTAssertNil(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: ""))
        XCTAssertNil(RepairPaths.stagingPath(for: "Foto/a.jpg", date: lateEvening, calendar: rome, token: "../x"))
        XCTAssertNil(RepairPaths.stagingPath(for: "../a.jpg", date: lateEvening, calendar: rome, token: "ab"))
    }

    /// Quarantena idempotente: una copia messa da parte un altro giorno vale.
    func testQuarantineCopy_isRecognizedOnAnyDay() {
        let rel = "Foto iPhone/3/X.heic"
        XCTAssertTrue(RepairPaths.isQuarantineCopy("_quarantena/2026-10-04/Foto iPhone/3/X.heic", of: rel))
        XCTAssertTrue(RepairPaths.isQuarantineCopy("_quarantena/2027-01-31/Foto iPhone/3/X.heic", of: rel))
        for other in ["_quarantena/2026-10-4/Foto iPhone/3/X.heic", "_quarantena/oggi/Foto iPhone/3/X.heic",
                      "_quarantena/2026-10-04/altro/Foto iPhone/3/X.heic",
                      "_quarantena/2026-10-04/Foto iPhone/3/X.heic.in-arrivo-ab",
                      "_quarantena/2026-10-04/foto iphone/3/x.heic", "Foto iPhone/3/X.heic",
                      "_quarantena/Foto iPhone/3/X.heic", "_quarantena/2026-10-04"] {
            XCTAssertFalse(RepairPaths.isQuarantineCopy(other, of: rel), other)
        }
    }
}
