import XCTest
@testable import AppBackupFoto

// MARK: - Doppi di prova (interni: li usa anche ImmichAlignerTests nello stesso file)

nonisolated final class FakeImmichAPI: ImmichAlignmentAPI, @unchecked Sendable {
    var librariesResult = [ImmichLibrary(id: "lib", name: "SSD - Enri", importPaths: ["/external-ssd"])]
    /// Totali restituiti da `statistics`, in ordine; l'ultimo si ripete.
    var totals = [100, 100]
    /// Quante chiamate a `jobs` rispondono «occupato» prima di «libero».
    var busyPolls = 0
    var offlineAssets: [ImmichAsset] = []
    var imageAssets: [ImmichAsset] = []
    var duplicateGroups: [ImmichDuplicateGroup] = []
    /// Primo ID di una pila → errore da lanciare per quella pila.
    var stackErrors: [String: ImmichAlignmentFailure] = [:]
    var scanError: ImmichAlignmentFailure?

    private(set) var calls: [String] = []
    private(set) var deleted: [[String]] = []
    private(set) var stacks: [[String]] = []
    private(set) var archived: [[String]] = []
    private var statsCalls = 0
    private var jobsCalls = 0

    func libraries() async throws -> [ImmichLibrary] { calls.append("libraries"); return librariesResult }
    func statistics(libraryId: String) async throws -> ImmichLibraryStats {
        calls.append("statistics")
        let total = totals[min(statsCalls, totals.count - 1)]; statsCalls += 1
        return ImmichLibraryStats(photos: total, videos: 0, total: total)
    }
    func scan(libraryId: String) async throws { calls.append("scan"); if let scanError { throw scanError } }
    func jobs() async throws -> ImmichJobs {
        calls.append("jobs"); jobsCalls += 1
        let busy = jobsCalls <= busyPolls
        return ImmichJobs(library: .init(jobCounts: .init(active: busy ? 1 : 0, waiting: 0, delayed: 0)))
    }
    func searchAll(_ search: ImmichSearch) async throws -> [ImmichAsset] {
        switch search {
        case .offline: calls.append("search-offline"); return offlineAssets
        case .images: calls.append("search-images"); return imageAssets
        }
    }
    func deleteAssets(ids: [String]) async throws { calls.append("delete"); deleted.append(ids) }
    func duplicates() async throws -> [ImmichDuplicateGroup] { calls.append("duplicates"); return duplicateGroups }
    func createStack(assetIds: [String]) async throws {
        calls.append("stack")
        if let first = assetIds.first, let error = stackErrors[first] { throw error }
        stacks.append(assetIds)
    }
    func archive(ids: [String]) async throws { calls.append("archive"); archived.append(ids) }
    var scanCount: Int { calls.filter { $0 == "scan" }.count }
}

nonisolated final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
nonisolated final class MountedSequence: @unchecked Sendable {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> Bool { values.count > 1 ? values.removeFirst() : (values.first ?? true) }
}
nonisolated final class SavedStates: @unchecked Sendable { var all: [ImmichAlignmentState] = [] }

nonisolated func immichTestEnv(mounted: MountedSequence = MountedSequence([true]), clock: TestClock = TestClock(),
                   saved: SavedStates = SavedStates(), waitLimit: TimeInterval = 60) -> ImmichAlignmentRun.Environment {
    ImmichAlignmentRun.Environment(
        ssdMounted: { mounted.next() },
        sleep: { clock.now += $0 },
        now: { clock.now },
        scanWaitLimit: waitLimit,
        pollInterval: 5,
        saveState: { saved.all.append($0) })
}

// MARK: - Orchestratore

final class ImmichAlignmentRunTests: XCTestCase {

    private func run(_ api: FakeImmichAPI, state: ImmichAlignmentState = ImmichAlignmentState(),
                     allowance: Int = 0, acceptDrop: Bool = false,
                     env: ImmichAlignmentRun.Environment = immichTestEnv()) async throws
        -> (ImmichAlignmentReport, ImmichAlignmentState) {
        try await ImmichAlignmentRun.run(api: api, state: state, allowance: allowance, acceptDrop: acceptDrop, env: env)
    }

    func testHappyPathDoesEveryStepInOrder() async throws {
        let api = FakeImmichAPI()
        api.totals = [100, 112]
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true),
                             immichTestAsset("by-hand", trashed: true)]
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2", width: 10, height: 10)])]
        api.imageAssets = [immichTestAsset("tiny", width: 200, height: 100), immichTestAsset("big")]

        let (report, state) = try await run(api)

        XCTAssertEqual(api.calls, ["libraries", "statistics", "scan", "jobs", "statistics", "search-offline",
                                   "delete", "duplicates", "stack", "search-images", "archive"])
        XCTAssertEqual(report, ImmichAlignmentReport(newAssets: 12, offlineRemoved: 1, stacksCreated: 1, archived: 1))
        XCTAssertEqual(api.deleted, [["off"]])
        XCTAssertEqual(api.stacks, [["s1", "s2"]])
        XCTAssertEqual(api.archived, [["tiny"]])
        XCTAssertEqual(state, ImmichAlignmentState(archivedAssetIds: ["tiny"], stackedDuplicateIds: ["d1"], healthyActiveCount: 112))
    }

    func testNoScanWithoutSSD() async {
        let api = FakeImmichAPI()
        do { _ = try await run(api, env: immichTestEnv(mounted: MountedSequence([false]))); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .ssdNotMounted) }
        XCTAssertFalse(api.calls.contains("scan"))
    }

    func testSSDVanishingDuringTheScanRemovesNothing() async {
        let api = FakeImmichAPI()
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        do { _ = try await run(api, env: immichTestEnv(mounted: MountedSequence([true, false]))); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .ssdNotMounted) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testLibraryNotFound() async {
        let api = FakeImmichAPI()
        api.librariesResult = [ImmichLibrary(id: "x", name: "New External Library", importPaths: [])]
        do { _ = try await run(api); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .libraryNotFound) }
        XCTAssertFalse(api.calls.contains("scan"))
    }

    // MARK: - Guardia del calo (spec, regola 3)

    func testEmptyMountTripsTheGuardAndRemembersTheBaseline() async {
        let api = FakeImmichAPI()
        api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let saved = SavedStates()
        do { _ = try await run(api, env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    /// Il caso che la guardia esiste per chiudere: «Riprova» con l'SSD ancora vuoto dentro la
    /// VM. Prima della scansione il numero e' gia' crollato; conta il riferimento ricordato.
    func testRetryWithTheSSDStillEmptyTripsAgain() async {
        let api = FakeImmichAPI()
        api.totals = [0, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testADropOfExactly500Passes() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51639]
        _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        XCTAssertTrue(api.calls.contains("search-offline"))
    }

    func testDuplicatesMovedByTheAppLowerTheBaseline() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51139]
        _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: 1000)
        XCTAssertTrue(api.calls.contains("search-offline"))
    }

    func testAcceptDropSkipsTheGuardAndResetsTheBaseline() async throws {
        let api = FakeImmichAPI(); api.totals = [40000, 40000]
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptDrop: true)
        XCTAssertEqual(report.offlineRemoved, 1)
        XCTAssertEqual(state.healthyActiveCount, 40000)
    }

    // MARK: - Attesa della scansione

    func testWaitsUntilTheLibraryQueueIsIdle() async throws {
        let api = FakeImmichAPI(); api.busyPolls = 3
        let (report, _) = try await run(api)
        XCTAssertEqual(api.calls.filter { $0 == "jobs" }.count, 4)
        XCTAssertFalse(report.scanTimedOut)
    }

    func testStopsWaitingAtTheLimitAndGoesOn() async throws {
        let api = FakeImmichAPI(); api.busyPolls = 10_000
        let (report, _) = try await run(api, env: immichTestEnv(waitLimit: 60))
        XCTAssertTrue(report.scanTimedOut)
        XCTAssertTrue(api.calls.contains("search-images"))
        XCTAssertLessThan(api.calls.filter { $0 == "jobs" }.count, 20)
    }

    // MARK: - Pile, minuscole, stato

    func testAFailedStackIsSkippedAndNotRemembered() async throws {
        let api = FakeImmichAPI()
        api.duplicateGroups = [
            ImmichDuplicateGroup(duplicateId: "bad", assets: [immichTestAsset("b1"), immichTestAsset("b2", width: 1, height: 1)]),
            ImmichDuplicateGroup(duplicateId: "good", assets: [immichTestAsset("g1"), immichTestAsset("g2", width: 1, height: 1)]),
        ]
        api.stackErrors = ["b1": .http(400)]
        let (report, state) = try await run(api)
        XCTAssertEqual(report.stacksCreated, 1)
        XCTAssertEqual(state.stackedDuplicateIds, ["good"])
    }

    func testRemembersWhatItStackedAndArchivedAndDoesNotRedoIt() async throws {
        let api = FakeImmichAPI()
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.imageAssets = [immichTestAsset("tiny", width: 100, height: 100)]
        let (_, first) = try await run(api)
        let again = FakeImmichAPI()
        again.duplicateGroups = api.duplicateGroups
        again.imageAssets = api.imageAssets   // Enrico ha tolto «tiny» dall'Archivio e separato la pila
        let (report, _) = try await run(again, state: first)
        XCTAssertEqual(report.stacksCreated, 0)
        XCTAssertEqual(report.archived, 0)
        XCTAssertTrue(again.stacks.isEmpty)
        XCTAssertTrue(again.archived.isEmpty)
    }

    func testRemovesOfflineInBlocksOf500() async throws {
        let api = FakeImmichAPI()
        api.offlineAssets = (0..<1201).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let (report, _) = try await run(api)
        XCTAssertEqual(api.deleted.map(\.count), [500, 500, 201])
        XCTAssertEqual(report.offlineRemoved, 1201)
    }

    func testUnauthorizedStopsEverything() async {
        let api = FakeImmichAPI(); api.scanError = .unauthorized
        do { _ = try await run(api); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertTrue(api.deleted.isEmpty)
    }
}
