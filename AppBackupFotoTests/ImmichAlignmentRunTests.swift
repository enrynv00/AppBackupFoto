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
    /// Chiamate a `jobs` (contate da 1) che rispondono «occupato», oltre a `busyPolls`.
    var busyOnCalls: Set<Int> = []
    /// Errore da lanciare alla n-esima chiamata a `archive` (contata da 1).
    var archiveFailsAtCall: [Int: ImmichAlignmentFailure] = [:]

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
        let busy = jobsCalls <= busyPolls || busyOnCalls.contains(jobsCalls)
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
    private var archiveCalls = 0
    func archive(ids: [String]) async throws {
        calls.append("archive"); archiveCalls += 1
        if let error = archiveFailsAtCall[archiveCalls] { throw error }
        archived.append(ids)
    }
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

    /// Stato con un riferimento gia' ricordato: l'unico caso in cui l'app toglie le offline
    /// senza chiedere (N1). I test che non parlano di conferma partono da qui.
    private let known = ImmichAlignmentState(healthyActiveCount: 100)
    private struct SaveFailed: Error {}

    private func run(_ api: FakeImmichAPI, state: ImmichAlignmentState = ImmichAlignmentState(),
                     allowance: Int = 0, acceptedMissing: Int? = nil, stateWasUnreadable: Bool = false,
                     env: ImmichAlignmentRun.Environment = immichTestEnv()) async throws
        -> (ImmichAlignmentReport, ImmichAlignmentState) {
        try await ImmichAlignmentRun.run(api: api, state: state, allowance: allowance, acceptedMissing: acceptedMissing,
                                         stateWasUnreadable: stateWasUnreadable, env: env)
    }

    func testHappyPathDoesEveryStepInOrder() async throws {
        let api = FakeImmichAPI()
        api.totals = [100, 112]
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true),
                             immichTestAsset("by-hand", trashed: true)]
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2", width: 10, height: 10)])]
        api.imageAssets = [immichTestAsset("tiny", width: 200, height: 100), immichTestAsset("big")]

        let (report, state) = try await run(api, state: known)

        XCTAssertEqual(api.calls, ["libraries", "statistics", "scan", "jobs", "statistics", "search-offline",
                                   "jobs", "statistics", "delete", "duplicates", "stack", "search-images", "archive"])
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

    func testAcceptedMissingLetsTheConfirmedDropThroughAndResetsTheBaseline() async throws {
        let api = FakeImmichAPI(); api.totals = [40000, 40000]
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptedMissing: 12139)
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

    /// B1: una scansione non finita puo' avere lasciato fuori l'SSD dal conteggio: le offline
    /// non si cercano e non si tolgono, e il riferimento resta com'era. Pile e archivio proseguono.
    func testStopsWaitingAtTheLimitAndGoesOnWithoutRemovingAnything() async throws {
        let api = FakeImmichAPI(); api.busyPolls = 10_000
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        let saved = SavedStates()
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 90),
                                            env: immichTestEnv(saved: saved, waitLimit: 60))
        XCTAssertTrue(report.scanTimedOut)
        XCTAssertTrue(report.offlineSkipped)
        XCTAssertEqual(report.offlineRemoved, 0)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertFalse(api.calls.contains("search-offline"))
        XCTAssertEqual(state.healthyActiveCount, 90)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == 90 })
        XCTAssertEqual(api.stacks.count, 1)
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
        let (report, _) = try await run(api, state: known)
        XCTAssertEqual(api.deleted.map(\.count), [500, 500, 201])
        XCTAssertEqual(report.offlineRemoved, 1201)
    }

    // MARK: - B2: «Togli comunque» legato al numero confermato

    func testAcceptedMissingOf600WithExactly600MissingRemoves() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51539]   // mancano 600
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptedMissing: 600)
        XCTAssertEqual(report.offlineRemoved, 1)
        XCTAssertEqual(state.healthyActiveCount, 51539)
    }

    /// L'SSD sparisce dopo che Enrico ha confermato 600: la conferma non copre 52.139.
    func testAcceptedMissingOf600DoesNotCoverAVanishedSSD() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let saved = SavedStates()
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptedMissing: 600,
                              env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertFalse(api.calls.contains("search-offline"))
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testAcceptedMissingToleranceIsTheConfirmedNumberPlusTheThreshold() async throws {
        let ok = FakeImmichAPI(); ok.totals = [52139, 52139 - 1100]   // 600 + 500
        _ = try await run(ok, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptedMissing: 600)
        XCTAssertTrue(ok.calls.contains("search-offline"))
        let over = FakeImmichAPI(); over.totals = [52139, 52139 - 1101]
        do {
            _ = try await run(over, state: ImmichAlignmentState(healthyActiveCount: 52139), acceptedMissing: 600)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 1101)) }
    }

    // MARK: - C1: riferimento salvato quando la guardia scatta

    func testTrippedGuardSavesTheUnloweredReference() async {
        let api = FakeImmichAPI(); api.totals = [0, 0]
        let saved = SavedStates()
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: 1000,
                              env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 51139)) }
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testTwoTrippedRunsInARowDoNotLowerTheReference() async {
        var state = ImmichAlignmentState(healthyActiveCount: 52139)
        for _ in 0..<2 {
            let api = FakeImmichAPI(); api.totals = [0, 0]
            let saved = SavedStates()
            do {
                _ = try await run(api, state: state, allowance: 1000, env: immichTestEnv(saved: saved))
                XCTFail("doveva fermarsi")
            } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 51139)) }
            state = saved.all.last ?? state
            XCTAssertEqual(state.healthyActiveCount, 52139)
        }
    }

    func testFirstRunTrippedGuardSavesTheCountBeforeTheScan() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        let saved = SavedStates()
        do { _ = try await run(api, allowance: 1000, env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 51139)) }
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    // MARK: - C2: tetto al margine

    func testEffectiveAllowanceIsClampedBetweenZeroAndAQuarterOfTheReference() {
        XCTAssertEqual(ImmichAlignmentRules.effectiveAllowance(-5, healthy: 52139), 0)
        XCTAssertEqual(ImmichAlignmentRules.effectiveAllowance(1000, healthy: 52139), 1000)
        XCTAssertEqual(ImmichAlignmentRules.effectiveAllowance(1_000_000_000, healthy: 52139), 13034)
        XCTAssertEqual(ImmichAlignmentRules.effectiveAllowance(5, healthy: 0), 0)
    }

    func testNegativeAllowanceCountsAsZero() async {
        let api = FakeImmichAPI(); api.totals = [52139, 51638]   // -501: scatta come con 0
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: -1000)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 501)) }
    }

    func testHugeAllowanceIsCapped() async throws {
        // tetto = 52139 / 4 = 13034, quindi il riferimento in memoria e' 39105
        let ok = FakeImmichAPI(); ok.totals = [52139, 39105 - 500]
        _ = try await run(ok, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: 1_000_000_000)
        XCTAssertTrue(ok.calls.contains("search-offline"))
        let over = FakeImmichAPI(); over.totals = [52139, 39105 - 501]
        do {
            _ = try await run(over, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: 1_000_000_000)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 501)) }
    }

    func testEmptyMountWithHugeAllowanceStillTripsTheGuard() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), allowance: Int.max)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 39105)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    // MARK: - C3: solo la libreria dell'SSD

    func testAnAssetOfAnotherLibraryIsNeverStacked() async throws {
        let api = FakeImmichAPI()
        api.duplicateGroups = [
            ImmichDuplicateGroup(duplicateId: "mixed", assets: [immichTestAsset("s1"), immichTestAsset("s2", width: 10, height: 10),
                                                                  immichTestAsset("other", library: "altra")]),
            ImmichDuplicateGroup(duplicateId: "left-with-one", assets: [immichTestAsset("t1"), immichTestAsset("t2", library: "altra")]),
        ]
        let (report, state) = try await run(api)
        XCTAssertEqual(api.stacks, [["s1", "s2"]])
        XCTAssertEqual(report.stacksCreated, 1)
        XCTAssertEqual(state.stackedDuplicateIds, ["mixed"])
    }

    func testAnAssetOfAnotherLibraryIsNeverArchived() async throws {
        let api = FakeImmichAPI()
        api.imageAssets = [immichTestAsset("tiny", width: 100, height: 100),
                           immichTestAsset("tiny-other", width: 100, height: 100, library: "altra")]
        let (report, state) = try await run(api)
        XCTAssertEqual(api.archived, [["tiny"]])
        XCTAssertEqual(report.archived, 1)
        XCTAssertEqual(state.archivedAssetIds, ["tiny"])
    }

    // MARK: - C4: stato salvato a ogni passo

    func testArchiveErrorAtTheSecondBlockKeepsTheFirstBlockInTheSavedState() async {
        let api = FakeImmichAPI()
        api.imageAssets = (0..<1200).map { immichTestAsset("t\($0)", width: 100, height: 100) }
        api.archiveFailsAtCall = [2: .notReachable]
        let saved = SavedStates()
        do { _ = try await run(api, env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .notReachable) }
        XCTAssertEqual(api.archived.map(\.count), [500])
        XCTAssertEqual(saved.all.last?.archivedAssetIds, Set(api.archived[0]))
    }

    func testStackIsSavedRightAfterEachSuccessfulStack() async {
        let api = FakeImmichAPI()
        api.duplicateGroups = [
            ImmichDuplicateGroup(duplicateId: "g1", assets: [immichTestAsset("a1"), immichTestAsset("a2", width: 1, height: 1)]),
            ImmichDuplicateGroup(duplicateId: "g2", assets: [immichTestAsset("b1"), immichTestAsset("b2", width: 1, height: 1)]),
        ]
        api.stackErrors = ["b1": .notReachable]
        let saved = SavedStates()
        do { _ = try await run(api, env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .notReachable) }
        XCTAssertEqual(saved.all.last?.stackedDuplicateIds, ["g1"])
    }

    // MARK: - C5: ricontrollo prima di ogni blocco di delete

    private func offlineBlocks(_ api: FakeImmichAPI, count: Int = 1201) {
        api.offlineAssets = (0..<count).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
    }

    func testSSDVanishingBetweenBlock1AndBlock2StopsAfterOneBlock() async {
        let api = FakeImmichAPI(); offlineBlocks(api)
        // chiamate: prima della scansione, dopo la scansione, blocco 1, blocco 2
        let mounted = MountedSequence([true, true, true, false])
        do { _ = try await run(api, state: known, env: immichTestEnv(mounted: mounted)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .ssdNotMounted) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
    }

    func testSSDVanishingRightAfterTheSearchRemovesNothing() async {
        let api = FakeImmichAPI(); offlineBlocks(api)
        let mounted = MountedSequence([true, true, false])
        do { _ = try await run(api, state: known, env: immichTestEnv(mounted: mounted)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .ssdNotMounted) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testLibraryQueueBecomingActiveBetweenBlocksStopsRemovingButGoesOn() async throws {
        let api = FakeImmichAPI(); offlineBlocks(api)
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.busyOnCalls = [3]   // 1 = attesa della scansione, 2 = blocco 1, 3 = blocco 2
        let (report, _) = try await run(api, state: known)
        XCTAssertEqual(api.deleted.map(\.count), [500])
        XCTAssertEqual(report.offlineRemoved, 500)
        XCTAssertTrue(report.removalStopped)
        XCTAssertEqual(api.stacks.count, 1)   // il resto del giro prosegue
    }

    func testLibraryQueueActiveBeforeTheFirstBlockRemovesNothing() async throws {
        let api = FakeImmichAPI(); offlineBlocks(api)
        api.busyOnCalls = [2]
        let (report, _) = try await run(api, state: known)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertTrue(report.removalStopped)
    }

    func testStatisticsCollapsingBetweenBlock1AndBlock2TripsTheGuard() async {
        let api = FakeImmichAPI(); offlineBlocks(api)
        api.totals = [52139, 52139, 52139, 0]   // prima, dopo, blocco 1, blocco 2
        let saved = SavedStates()
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testStatisticsCollapsingRightAfterTheSearchRemovesNothing() async {
        let api = FakeImmichAPI(); offlineBlocks(api)
        api.totals = [52139, 52139, 0]
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    // MARK: - M2: file di stato illeggibile

    func testUnreadableStateRemovesNoOfflineButDoesTheRest() async throws {
        let api = FakeImmichAPI(); offlineBlocks(api, count: 10)
        api.totals = [100, 120]
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        let (report, state) = try await run(api, stateWasUnreadable: true)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertTrue(api.calls.contains("search-offline"))   // N1: ora si cerca, per poter chiedere conferma
        XCTAssertTrue(report.offlineSkipped)
        XCTAssertTrue(report.stateWasUnreadable)
        XCTAssertEqual(api.stacks.count, 1)
        XCTAssertNil(state.healthyActiveCount)   // N1: nessun riferimento finche' Enrico non conferma
    }


    // MARK: - N1: senza riferimento affidabile non si toglie niente senza conferma

    private func offline(_ api: FakeImmichAPI, _ count: Int) {
        api.offlineAssets = (0..<count).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
    }

    func testFirstRunWithoutConfirmationRemovesNothingAndKeepsNoReference() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 25)
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.imageAssets = [immichTestAsset("tiny", width: 100, height: 100)]
        let saved = SavedStates()
        let (report, state) = try await run(api, env: immichTestEnv(saved: saved))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 25))
        XCTAssertEqual(api.stacks.count, 1)       // pile e archivio proseguono
        XCTAssertEqual(api.archived, [["tiny"]])
    }

    /// Il caso reale: il cron di mezzanotte con il mount vuoto aveva marcato tutto offline,
    /// quindi `before` vale 0 e non e' un riferimento.
    func testUnreadableStateWithBeforeZeroRemovesNothingAndTheNextRunAsksAgain() async throws {
        let api = FakeImmichAPI(); api.totals = [0, 10]; offline(api, 25)
        let (report, state) = try await run(api, stateWasUnreadable: true)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 25))
        // Il giro dopo: file di stato leggibile ma senza riferimento, ancora nessuna conferma.
        let again = FakeImmichAPI(); again.totals = [10, 10]; offline(again, 25)
        let (second, secondState) = try await run(again, state: state)
        XCTAssertTrue(again.deleted.isEmpty)
        XCTAssertNil(secondState.healthyActiveCount)
        XCTAssertEqual(second.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 25))
    }

    func testConfirmedFirstRemovalDeletesAndTheReferenceBecomesAfter() async throws {
        let api = FakeImmichAPI(); api.totals = [0, 10]; offline(api, 25)
        let (report, state) = try await run(api, acceptedMissing: 25, stateWasUnreadable: true)
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(report.offlineRemoved, 25)
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertEqual(state.healthyActiveCount, 10)
    }

    func testConfirmedFirstRemovalOnAnEmptyStateAlsoSetsTheReference() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 25)
        let (_, state) = try await run(api, acceptedMissing: 25)
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(state.healthyActiveCount, 10)
    }

    /// Conferma di 25 con 10 foto viste: molte piu' offline dopo la conferma (SSD sparito?) non passano.
    func testAMuchBiggerRemovalAfterTheConfirmationAsksAgainWithTheNewNumbers() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 40)
        let (report, state) = try await run(api, acceptedMissing: 25)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 40))
    }

    /// Il confine: conferma + soglia (2 % di 1000 = 20).
    func testFirstRemovalToleranceIsTheConfirmedNumberPlusTheThreshold() async throws {
        let ok = FakeImmichAPI(); ok.totals = [1000, 1000]; offline(ok, 45)
        let (report, state) = try await run(ok, acceptedMissing: 25)
        XCTAssertEqual(ok.deleted.map(\.count), [45])
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertEqual(state.healthyActiveCount, 1000)
        let over = FakeImmichAPI(); over.totals = [1000, 1000]; offline(over, 46)
        let (overReport, overState) = try await run(over, acceptedMissing: 25)
        XCTAssertTrue(over.deleted.isEmpty)
        XCTAssertNil(overState.healthyActiveCount)
        XCTAssertEqual(overReport.needsFirstConfirmation, ImmichFirstRemoval(active: 1000, toRemove: 46))
    }

    /// Senza nulla da togliere non c'e' niente da confermare, e nessun riferimento si inventa.
    func testNothingOfflineAndNoReferenceAsksNothingAndSavesNoReference() async throws {
        let api = FakeImmichAPI(); api.totals = [0, 0]
        let (report, state) = try await run(api)
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertNil(state.healthyActiveCount)
    }

    /// Con riferimento non affidabile ogni blocco si confronta con l'`after` confermato.
    func testBlocksOfAConfirmedFirstRemovalAreGuardedAgainstTheConfirmedAfter() async {
        let api = FakeImmichAPI(); offline(api, 1201)
        api.totals = [5000, 5000, 5000, 0]   // prima, dopo, blocco 1, blocco 2 (SSD sparito)
        let saved = SavedStates()
        do { _ = try await run(api, acceptedMissing: 1201, env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 5000)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })   // nessun riferimento inventato
    }

    // MARK: - N4: il salvataggio dello stato non e' silenzioso

    func testSaveFailingWhenTheGuardTripsReportsStateNotSavedInsteadOfDropGuard() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        var env = immichTestEnv()
        env.saveState = { _ in throw SaveFailed() }
        do { _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139), env: env); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .stateNotSaved) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testSaveFailingBeforeTheFirstDeleteBlockRemovesNothing() async {
        let api = FakeImmichAPI(); offline(api, 3)
        var env = immichTestEnv()
        env.saveState = { _ in throw SaveFailed() }
        do { _ = try await run(api, state: known, env: env); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .stateNotSaved) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testASuccessfulSaveHappensBeforeTheFirstDeleteBlock() async throws {
        let api = FakeImmichAPI(); offline(api, 3)
        let saved = SavedStates()
        var env = immichTestEnv(saved: saved)
        let beforeDelete = SavedStates()
        env.saveState = { state in
            saved.all.append(state)
            if api.deleted.isEmpty { beforeDelete.all.append(state) }
        }
        _ = try await run(api, state: known, env: env)
        XCTAssertEqual(beforeDelete.all.first, known)
    }

    func testSaveFailingAfterAStackStopsTheRun() async {
        let api = FakeImmichAPI()
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.imageAssets = [immichTestAsset("tiny", width: 100, height: 100)]
        var env = immichTestEnv()
        env.saveState = { state in if !state.stackedDuplicateIds.isEmpty { throw SaveFailed() } }
        do { _ = try await run(api, env: env); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .stateNotSaved) }
        XCTAssertTrue(api.archived.isEmpty)
    }

    // MARK: - 403 su una pila

    /// Accettato: un 403 (chiave non piu' valida) su una pila ferma il giro prima dell'archiviazione.
    func testAForbiddenStackStopsTheRunBeforeArchiving() async {
        let api = FakeImmichAPI()
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.imageAssets = [immichTestAsset("tiny", width: 100, height: 100)]
        api.stackErrors = ["s1": .unauthorized]
        do { _ = try await run(api); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertFalse(api.calls.contains("search-images"))
        XCTAssertTrue(api.archived.isEmpty)
    }

    func testUnauthorizedStopsEverything() async {
        let api = FakeImmichAPI(); api.scanError = .unauthorized
        do { _ = try await run(api); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertTrue(api.deleted.isEmpty)
    }
}

// MARK: - Coordinatore

nonisolated final class MemoryKeyStore: ImmichKeyStore, @unchecked Sendable {
    var key: String?
    init(_ key: String?) { self.key = key }
    func load() -> String? { key }
    func save(_ key: String) throws { self.key = key }
    func delete() { key = nil }
}

final class ImmichAlignerTests: XCTestCase {
    private func makeAligner(api: FakeImmichAPI, key: String? = "K", running: Bool = true,
                             state: ImmichAlignmentState? = nil) throws -> (ImmichAligner, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aligner-\(UUID().uuidString)")
        let stateURL = dir.appendingPathComponent("immich-alignment.json")
        let logURL = dir.appendingPathComponent("immich-alignment.log")
        if let state { try ImmichAlignmentStateStore.save(state, to: stateURL) }
        let aligner = ImmichAligner()
        aligner.keyStore = MemoryKeyStore(key)
        aligner.makeAPI = { _ in api }
        aligner.isImmichRunning = { running }
        aligner.ssdMounted = { true }
        aligner.stateURL = stateURL
        aligner.logURL = logURL
        aligner.sleep = { _ in }
        return (aligner, stateURL, logURL)
    }

    func testDoesNothingWhileImmichIsOff() throws {
        let api = FakeImmichAPI()
        let (aligner, _, _) = try makeAligner(api: api, running: false)
        aligner.request(.backupFinished)
        XCTAssertNil(aligner.currentTask)
        XCTAssertEqual(aligner.status, .idle)
    }

    func testWithoutAKeyAsksForThePassword() async throws {
        let api = FakeImmichAPI()
        let (aligner, _, _) = try makeAligner(api: api, key: nil)
        aligner.request(.immichStarted)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .needsKey)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testRequestsWhileRunningCollapseIntoOneMoreRun() async throws {
        let api = FakeImmichAPI()
        let (aligner, _, _) = try makeAligner(api: api)
        aligner.request(.backupFinished)
        aligner.request(.backupFinished)
        aligner.request(.duplicatesMoved(count: 3))
        await aligner.currentTask?.value
        XCTAssertEqual(api.scanCount, 2)
        XCTAssertNil(aligner.currentTask)
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
    }

    func testUnauthorizedForgetsTheKey() async throws {
        let api = FakeImmichAPI(); api.scanError = .unauthorized
        let (aligner, _, _) = try makeAligner(api: api)
        let store = aligner.keyStore as! MemoryKeyStore
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .needsKey)
        XCTAssertNil(store.key)
    }

    func testDropGuardThenAcceptDrop() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        aligner.acceptDropAndRetry(missing: 12139)
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 40000)
    }

    /// B2: la conferma vale per il numero mostrato, e per un solo giro.
    func testAcceptedNumberCoversOnlyThatDropAndOnlyOnce() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.request(.manual)
        await aligner.currentTask?.value
        aligner.acceptDropAndRetry(missing: 600)   // l'utente ha confermato 600, ma ne mancano 12.139
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
        aligner.request(.manual)   // senza nuova conferma: scatta ancora
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
    }

    /// C1: «Riprova» dopo una guardia scattata non abbassa il riferimento in modo cumulativo.
    func testRetryAfterATrippedGuardKeepsTheAllowanceAndTheReference() async throws {
        let api = FakeImmichAPI(); api.totals = [0]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.request(.duplicatesMoved(count: 1000))
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 51139))
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 51139))   // stesso margine, non 1000 + 1000
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
    }

    /// M2: un file di stato illeggibile si mette da parte e quel giro non toglie niente.
    func testUnreadableStateFileIsSetAsideAndTheRunRemovesNothing() async throws {
        let api = FakeImmichAPI()
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (aligner, stateURL, _) = try makeAligner(api: api)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ non e' json".utf8).write(to: stateURL)
        aligner.request(.manual)
        await aligner.currentTask?.value
        // N1: senza riferimento si chiede conferma (non c'e' piu' un `.done` con il report).
        XCTAssertEqual(aligner.status, .confirmFirstRemoval(active: 100, toRemove: 1))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("illeggibile").path))
        // Il giro dopo, senza conferma, non toglie ancora niente.
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertTrue(api.deleted.isEmpty)
        // Con la conferma di Enrico toglie le offline.
        aligner.acceptDropAndRetry(missing: 1)
        await aligner.currentTask?.value
        XCTAssertEqual(api.deleted, [["off"]])
    }

    func testDuplicatesMovedWhileImmichIsOffStillCount() async throws {
        let api = FakeImmichAPI(); api.totals = [51139]
        var running = false
        let (aligner, _, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.isImmichRunning = { running }
        aligner.request(.duplicatesMoved(count: 1000))
        running = true
        aligner.request(.immichStarted)
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
    }


    // MARK: - N1: conferma alla prima rimozione

    func testFirstRemovalAsksForConfirmationThenAcceptDeletes() async throws {
        let api = FakeImmichAPI(); api.totals = [10]
        api.offlineAssets = (0..<25).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let (aligner, stateURL, _) = try makeAligner(api: api)
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .confirmFirstRemoval(active: 10, toRemove: 25))
        XCTAssertEqual(aligner.status.missingToConfirm, 25)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount)
        aligner.acceptDropAndRetry(missing: 25)
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 10)
    }

    // MARK: - N2: la conferma non resta appesa

    func testConfirmationGivenWhileImmichIsOffDoesNotSurviveToALaterRun() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        var running = false
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.isImmichRunning = { running }
        aligner.acceptDropAndRetry(missing: 12139)   // Immich spento: nessun giro parte
        XCTAssertNil(aligner.currentTask)
        running = true
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
    }

    func testConfirmationGivenWithoutAKeyDoesNotSurviveToALaterRun() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        let (aligner, _, _) = try makeAligner(api: api, key: nil, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.acceptDropAndRetry(missing: 12139)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .needsKey)
        (aligner.keyStore as! MemoryKeyStore).key = "K"
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        XCTAssertTrue(api.deleted.isEmpty)
    }

    // MARK: - N3: il margine dei doppioni torna solo se il riferimento non e' avanzato

    func testAllowanceUsedBeforeAFailureAfterTheDeleteIsNotSubtractedAgain() async throws {
        let api = FakeImmichAPI()
        api.totals = [51139, 51139, 50139]   // giro 1: prima, dopo; giro 2: prima (poi resta 50139)
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.stackErrors = ["s1": .notReachable]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.request(.duplicatesMoved(count: 1000))
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .failed(.notReachable))   // errore dopo che il riferimento e' avanzato
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 51139)
        aligner.request(.manual)
        await aligner.currentTask?.value
        // Il margine e' stato usato: un altro calo di 1000 scatta (con il margine restituito passerebbe).
        XCTAssertEqual(aligner.status, .dropGuard(missing: 1000))
    }

    func testAllowanceIsKeptWhenASuccessfulRunTimedOutAndSoTheReferenceDidNotAdvance() async throws {
        let api = FakeImmichAPI(); api.totals = [51139]; api.busyPolls = 1
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139))
        aligner.scanWaitLimit = 0
        aligner.request(.duplicatesMoved(count: 1000))
        await aligner.currentTask?.value
        guard case .done(let report, _) = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertTrue(report.scanTimedOut)
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
        aligner.request(.manual)
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("il margine doveva restare: \(aligner.status)") }
    }

    // MARK: - N4: stato non salvato

    func testAnUnwritableStateFileStopsTheRunWithStateNotSaved() async throws {
        let api = FakeImmichAPI()
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 100))
        // Il file di stato si legge ma la sua cartella non e' piu' scrivibile: il salvataggio atomico fallisce.
        let dir = stateURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .failed(.stateNotSaved))
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testWritesOneLogLinePerRunWithoutTheKey() async throws {
        let api = FakeImmichAPI()
        let (aligner, _, logURL) = try makeAligner(api: api, key: "CHIAVE-SEGRETA")
        aligner.request(.manual)
        await aligner.currentTask?.value
        // la scrittura del log e' in un Task staccato: si aspetta che compaia
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: logURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
        XCTAssertTrue(log.contains("Immich aggiornato alle "))
        XCTAssertFalse(log.contains("CHIAVE-SEGRETA"))
    }
}
