import XCTest
@testable import AppBackupFoto

/// BUG-10 (2026-09-28): quando Xcode avvia l'app come test host, `BackupRunner.init()`
/// valuta le sue `lazy var` (`libraryIndexStore`, `trashManifestStore`, `trashHistoryStore`)
/// prima che qualunque test scelga a mano il proprio store usa-e-getta — e quelle `lazy var`
/// puntavano SEMPRE a `~/Library/Application Support/AppBackupFoto/`, la cartella vera
/// dell'utente, senza mai controllare `isRunningUnderTests()`. Con lo schema 2 del Task 4
/// dell'inventario, questo ha migrato il `library-index.sqlite` reale di Enrico.
///
/// `backupRunnerStoreRoot(isRunningUnderTests:)` e' la funzione pura che decide quella radice:
/// sotto test punta a una cartella temporanea del processo, mai alla posizione vera.
final class BackupRunnerStoreRootTests: XCTestCase {

    func testUnderTests_pointsToATemporaryDirectory_neverToApplicationSupport() {
        let root = backupRunnerStoreRoot(isRunningUnderTests: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        XCTAssertTrue(root.standardizedFileURL.path.hasPrefix(tmp),
                      "sotto test la radice deve stare nella directory temporanea, non in \(root.path)")

        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else {
            return XCTFail("Application Support non raggiungibile")
        }
        XCTAssertFalse(root.standardizedFileURL.path.hasPrefix(support.standardizedFileURL.path),
                       "sotto test la radice non deve mai coincidere con Application Support")
    }

    func testInProduction_pointsToApplicationSupportAppBackupFoto() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else {
            return XCTFail("Application Support non raggiungibile")
        }
        let expected = support.appendingPathComponent("AppBackupFoto", isDirectory: true)
        let root = backupRunnerStoreRoot(isRunningUnderTests: false)
        XCTAssertEqual(root.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    /// La radice sotto test e' comunque una posizione ammessa dall'allow-list esistente
    /// (`isAllowedStoreLocation`, `includingTemporary: true`): niente seconda regola che possa
    /// divergere dalla prima.
    func testUnderTests_isAnAllowedStoreLocation() {
        let root = backupRunnerStoreRoot(isRunningUnderTests: true)
        let file = root.appendingPathComponent("library-index.sqlite")
        XCTAssertTrue(isAllowedStoreLocation(file, includingTemporary: true))
    }

    /// BUG-10, seconda parte: sotto test niente Sparkle e niente scritture nelle preferenze.
    func testUserStateAtLaunch_isTouchedOnlyOutsideTests() {
        XCTAssertFalse(appTouchesUserStateAtLaunch(isRunningUnderTests: true))
        XCTAssertTrue(appTouchesUserStateAtLaunch(isRunningUnderTests: false))
    }
}
