import XCTest
@testable import AppBackupFoto

/// Regressione del 2026-09-19 (BUG-7). Con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` un tipo
/// non annotato e' `@MainActor`, e un suo metodo sincrono chiamato da un `Task.detached` salta
/// sul main thread: era la lettura dell'elenco dopo ogni MAC -> SSD, sei minuti di beachball.
///
/// Tecnica: il lavoro parte in un `Task.detached`, ESATTAMENTE come in produzione, e intanto il
/// test tiene OCCUPATO il main thread aspettando un semaforo. Se il lavoro ha bisogno del main
/// non puo' finire, e il test scade (rosso) invece di restare appeso per sempre. Non e' una
/// corsa: il main e' occupato dal test per costruzione, quindi l'esito non dipende dal timing.
///
/// Limite dichiarato: verifica l'isolamento dei TIPI, non la forma dei call site. Un futuro
/// `await MainActor.run { idx.scan(...) }` scritto in `BackupRunner` passerebbe questi test.
final class MainThreadIsolationTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainThreadIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() throws -> LibraryIndexStore {
        try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
    }

    /// Il test del test. Se l'impalcatura fosse difettosa — per esempio se il semaforo non
    /// tenesse davvero occupato il main — tutti gli altri test passerebbero anche col bug.
    /// Qui il lavoro ha BISOGNO del main per costruzione, e il test si aspetta la scadenza.
    func testHarness_detectsWorkThatNeedsTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await MainActor.run { }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .timedOut,
                       "L'impalcatura non tiene occupato il main thread: gli altri test non provano niente.")
    }

    func testStoreCount_runsWithoutTheMainThread() throws {
        let store = try makeStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? store.count()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexStore.count() ha avuto bisogno del main thread: il tipo e' tornato @MainActor?")
    }

    func testScan_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: root.appendingPathComponent("a.jpg"))
        try Data("due".utf8).write(to: root.appendingPathComponent("b.jpg"))
        let indexer = LibraryIndexer(store: try makeStore())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? indexer.scan(root: root)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexer.scan ha avuto bisogno del main thread: e' il bug dei sei minuti dopo MAC -> SSD.")
    }
}
