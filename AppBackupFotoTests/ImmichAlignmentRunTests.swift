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
    /// Offline restituite prima della scansione; `nil` = le stesse di `offlineAssets`.
    var offlineAssetsBeforeScan: [ImmichAsset]? = nil
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
        case .offline where scanCount == 0:
            calls.append("search-offline-before"); return offlineAssetsBeforeScan ?? offlineAssets
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
nonisolated final class SignalCounter: @unchecked Sendable { var count = 0 }

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
    private let known = ImmichAlignmentState(healthyActiveCount: 100, referenceConfirmed: true)
    private struct SaveFailed: Error {}

    private func run(_ api: FakeImmichAPI, state: ImmichAlignmentState = ImmichAlignmentState(),
                     allowance: Int = 0, accepted: ImmichConfirmation? = nil, stateWasUnreadable: Bool = false,
                     env: ImmichAlignmentRun.Environment = immichTestEnv()) async throws
        -> (ImmichAlignmentReport, ImmichAlignmentState) {
        try await ImmichAlignmentRun.run(api: api, state: state, allowance: allowance, accepted: accepted,
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

        XCTAssertEqual(api.calls, ["libraries", "statistics", "search-offline-before", "scan", "jobs", "statistics", "search-offline",
                                   "jobs", "statistics", "delete", "duplicates", "stack", "search-images", "archive"])
        XCTAssertEqual(report, ImmichAlignmentReport(newAssets: 12, offlineRemoved: 1, stacksCreated: 1, archived: 1))
        XCTAssertEqual(api.deleted, [["off"]])
        XCTAssertEqual(api.stacks, [["s1", "s2"]])
        XCTAssertEqual(api.archived, [["tiny"]])
        XCTAssertEqual(state, ImmichAlignmentState(archivedAssetIds: ["tiny"], stackedDuplicateIds: ["d1"], healthyActiveCount: 112,
                                                   referenceConfirmed: true))
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

    /// Senza riferimento affidabile la guardia del calo non blocca: si chiede conferma (Q1), e
    /// non si salva nessun candidato. Resta zero delete.
    func testEmptyMountWithoutAReliableReferenceAsksInsteadOfTrippingTheGuard() async throws {
        let api = FakeImmichAPI()
        api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let saved = SavedStates()
        let (report, state) = try await run(api, env: immichTestEnv(saved: saved))
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 0, toRemove: 10, before: 52139))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })
    }

    /// Il caso che la guardia esiste per chiudere: «Riprova» con l'SSD ancora vuoto dentro la
    /// VM. Prima della scansione il numero e' gia' crollato; conta il riferimento ricordato.
    func testRetryWithTheSSDStillEmptyTripsAgain() async {
        let api = FakeImmichAPI()
        api.totals = [0, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testADropOfExactly500Passes() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51639]
        _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        XCTAssertTrue(api.calls.contains("search-offline"))
    }

    func testDuplicatesMovedByTheAppLowerTheBaseline() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51139]
        _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: 1000)
        XCTAssertTrue(api.calls.contains("search-offline"))
    }

    func testAcceptedMissingLetsTheConfirmedDropThroughAndResetsTheBaseline() async throws {
        let api = FakeImmichAPI(); api.totals = [40000, 40000]
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), accepted: .drop(missing: 12139))
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
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 90, referenceConfirmed: true),
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

    /// SSD staccato con Immich acceso (2026-11-18): Immich aveva segnato offline quasi tutto, la
    /// scansione le ritrova. Non sono foto nuove: si contano a parte, e non si toglie niente.
    /// La parte video nascosta di una Live Photo non conta, come in `statistics`.
    func testPhotosBackFromOffline_areNotCountedAsNew() async throws {
        let api = FakeImmichAPI()
        api.totals = [10, 15]
        api.offlineAssetsBeforeScan = [immichTestAsset("a", offline: true, trashed: true),
                                       immichTestAsset("b", offline: true, trashed: true),
                                       immichTestAsset("c", offline: true),
                                       immichTestAsset("v", type: "VIDEO", offline: true, trashed: true, visibility: "hidden")]
        api.offlineAssets = []

        let (report, _) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 15, referenceConfirmed: true))

        XCTAssertEqual(report.returnedAssets, 3)
        XCTAssertEqual(report.newAssets, 2)
        XCTAssertEqual(report.offlineRemoved, 0)
        XCTAssertTrue(api.deleted.isEmpty)
    }

    /// Un'offline che resta offline (file davvero tolto dall'SSD) non e' una foto ritrovata:
    /// l'aumento e' tutto di foto nuove.
    func testOfflineThatStaysOffline_doesNotHideNewPhotos() async throws {
        let api = FakeImmichAPI()
        api.totals = [100, 103]
        api.offlineAssets = [immichTestAsset("gone", offline: true, trashed: true)]

        let (report, _) = try await run(api, state: known)

        XCTAssertEqual(report.newAssets, 3)
        XCTAssertEqual(report.returnedAssets, 0)
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
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), accepted: .drop(missing: 600))
        XCTAssertEqual(report.offlineRemoved, 1)
        XCTAssertEqual(state.healthyActiveCount, 51539)
    }

    /// L'SSD sparisce dopo che Enrico ha confermato 600: la conferma non copre 52.139.
    func testAcceptedMissingOf600DoesNotCoverAVanishedSSD() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let saved = SavedStates()
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), accepted: .drop(missing: 600),
                              env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertFalse(api.calls.contains("search-offline"))
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testAcceptedMissingToleranceIsTheConfirmedNumberPlusTheThreshold() async throws {
        let ok = FakeImmichAPI(); ok.totals = [52139, 52139 - 1100]   // 600 + 500
        _ = try await run(ok, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), accepted: .drop(missing: 600))
        XCTAssertTrue(ok.calls.contains("search-offline"))
        let over = FakeImmichAPI(); over.totals = [52139, 52139 - 1101]
        do {
            _ = try await run(over, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), accepted: .drop(missing: 600))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 1101)) }
    }

    // MARK: - C1: riferimento salvato quando la guardia scatta

    func testTrippedGuardSavesTheUnloweredReference() async {
        let api = FakeImmichAPI(); api.totals = [0, 0]
        let saved = SavedStates()
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: 1000,
                              env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 51139)) }
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testTwoTrippedRunsInARowDoNotLowerTheReference() async {
        var state = ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true)
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

    /// Al primo giro un calo oltre la soglia non scatta piu' (Q1): senza nulla da togliere non si
    /// chiede niente, non si toglie niente e non si salva nessun riferimento.
    func testFirstRunWithADropAndNothingOfflineDoesNotTripNorSaveAReference() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        let saved = SavedStates()
        let (report, state) = try await run(api, allowance: 1000, env: immichTestEnv(saved: saved))
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })
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
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: -1000)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 501)) }
    }

    func testHugeAllowanceIsCapped() async throws {
        // tetto = 52139 / 4 = 13034, quindi il riferimento in memoria e' 39105
        let ok = FakeImmichAPI(); ok.totals = [52139, 39105 - 500]
        _ = try await run(ok, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: 1_000_000_000)
        XCTAssertTrue(ok.calls.contains("search-offline"))
        let over = FakeImmichAPI(); over.totals = [52139, 39105 - 501]
        do {
            _ = try await run(over, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: 1_000_000_000)
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 501)) }
    }

    func testEmptyMountWithHugeAllowanceStillTripsTheGuard() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), allowance: Int.max)
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
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), env: immichTestEnv(saved: saved))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
        XCTAssertEqual(saved.all.last?.healthyActiveCount, 52139)
    }

    func testStatisticsCollapsingRightAfterTheSearchRemovesNothing() async {
        let api = FakeImmichAPI(); offlineBlocks(api)
        api.totals = [52139, 52139, 0]
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
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
        let (report, state) = try await run(api, accepted: .firstRemoval(active: 10, toRemove: 25), stateWasUnreadable: true)
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(report.offlineRemoved, 25)
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertEqual(state.healthyActiveCount, 10)
    }

    func testConfirmedFirstRemovalOnAnEmptyStateAlsoSetsTheReference() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 25)
        let (_, state) = try await run(api, accepted: .firstRemoval(active: 10, toRemove: 25))
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(state.healthyActiveCount, 10)
    }

    /// Conferma di 25 con 10 foto viste: molte piu' offline dopo la conferma (SSD sparito?) non passano.
    func testAMuchBiggerRemovalAfterTheConfirmationAsksAgainWithTheNewNumbers() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 40)
        let (report, state) = try await run(api, accepted: .firstRemoval(active: 10, toRemove: 25))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 40))
    }

    /// Il confine: conferma + soglia (2 % di 1000 = 20).
    func testFirstRemovalToleranceIsTheConfirmedNumberPlusTheThreshold() async throws {
        let ok = FakeImmichAPI(); ok.totals = [1000, 1000]; offline(ok, 45)
        let (report, state) = try await run(ok, accepted: .firstRemoval(active: 1000, toRemove: 25))
        XCTAssertEqual(ok.deleted.map(\.count), [45])
        XCTAssertNil(report.needsFirstConfirmation)
        XCTAssertEqual(state.healthyActiveCount, 1000)
        let over = FakeImmichAPI(); over.totals = [1000, 1000]; offline(over, 46)
        let (overReport, overState) = try await run(over, accepted: .firstRemoval(active: 1000, toRemove: 25))
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
        do { _ = try await run(api, accepted: .firstRemoval(active: 5000, toRemove: 1201), env: immichTestEnv(saved: saved)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 5000)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })   // nessun riferimento inventato
    }

    // MARK: - P1: la conferma e' tipata

    /// La falla: Enrico apre la conferma del primo giro (89.514 da togliere); mentre l'alert e'
    /// aperto un giro in background con l'SSD vuoto fa scattare la guardia e salva un riferimento
    /// affidabile. Il suo clic non puo' diventare una tolleranza di calo di 89.514 + 500.
    func testAFirstRemovalConfirmationNeverWidensTheDropGuardOfAReliableReference() async {
        let api = FakeImmichAPI(); api.totals = [0, 0]   // SSD vuoto
        offline(api, 10)
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true),
                              accepted: .firstRemoval(active: 52139, toRemove: 89514))
            XCTFail("la guardia doveva scattare")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 52139)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    func testAFirstRemovalConfirmationIsIgnoredWithAReliableReferenceAndNoExtraToleranceApplies() async throws {
        // Calo di 501 con riferimento affidabile: scatta come senza conferma, anche se la
        // conferma di prima rimozione avrebbe una tolleranza enorme.
        let api = FakeImmichAPI(); api.totals = [52139, 52139 - 501]
        do {
            _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true),
                              accepted: .firstRemoval(active: 52139, toRemove: 89514))
            XCTFail("doveva fermarsi")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 501)) }
    }

    func testADropConfirmationIsIgnoredWithAnUnreliableReferenceAndAsksAgain() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 25)
        let (report, state) = try await run(api, accepted: .drop(missing: 25))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 10, toRemove: 25))
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertFalse(state.referenceConfirmed)
    }

    func testADropConfirmationIsIgnoredWhenTheReferenceIsNotConfirmed() async throws {
        let api = FakeImmichAPI(); api.totals = [1000, 1000]; offline(api, 25)
        let (report, _) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 1000),
                                        accepted: .drop(missing: 1000))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 1000, toRemove: 25))
    }

    /// `after` crollato rispetto all'`active` che Enrico ha visto: nessun delete.
    func testAFirstRemovalConfirmationWithACollapsedAfterDeletesNothing() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 5000]; offline(api, 25)
        let (report, state) = try await run(api, accepted: .firstRemoval(active: 52139, toRemove: 25))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 5000, toRemove: 25))
        XCTAssertNil(state.healthyActiveCount)
        XCTAssertFalse(state.referenceConfirmed)
    }

    /// I casi limite: `after >= active - soglia` (2 % di 1000 = 20) e `offline <= toRemove + soglia`.
    func testFirstRemovalBoundariesOfActiveAndToRemove() async throws {
        let atActiveEdge = FakeImmichAPI(); atActiveEdge.totals = [980, 980]; offline(atActiveEdge, 25)
        _ = try await run(atActiveEdge, accepted: .firstRemoval(active: 1000, toRemove: 25))
        XCTAssertEqual(atActiveEdge.deleted.map(\.count), [25])
        let underActiveEdge = FakeImmichAPI(); underActiveEdge.totals = [979, 979]; offline(underActiveEdge, 25)
        let (report, _) = try await run(underActiveEdge, accepted: .firstRemoval(active: 1000, toRemove: 25))
        XCTAssertTrue(underActiveEdge.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 979, toRemove: 25))
        // La soglia sul numero da togliere e' quella di `active`, non quella di `after`.
        let atRemoveEdge = FakeImmichAPI(); atRemoveEdge.totals = [980, 980]; offline(atRemoveEdge, 45)
        _ = try await run(atRemoveEdge, accepted: .firstRemoval(active: 1000, toRemove: 25))
        XCTAssertEqual(atRemoveEdge.deleted.map(\.count), [45])
        let overRemoveEdge = FakeImmichAPI(); overRemoveEdge.totals = [980, 980]; offline(overRemoveEdge, 46)
        _ = try await run(overRemoveEdge, accepted: .firstRemoval(active: 1000, toRemove: 25))
        XCTAssertTrue(overRemoveEdge.deleted.isEmpty)
        // toRemove e active a zero: nessuna tolleranza.
        let zero = FakeImmichAPI(); zero.totals = [0, 0]; offline(zero, 1)
        _ = try await run(zero, accepted: .firstRemoval(active: 0, toRemove: 0))
        XCTAssertTrue(zero.deleted.isEmpty)
    }

    /// Ogni blocco si confronta con l'`active` confermato da Enrico (non con l'`after` del giro).
    func testBlocksOfAConfirmedFirstRemovalAreGuardedAgainstTheConfirmedActive() async {
        let api = FakeImmichAPI(); offline(api, 1201)
        api.totals = [5000, 4950, 4950, 4890]   // prima, dopo, blocco 1, blocco 2: 110 sotto `active`
        do { _ = try await run(api, accepted: .firstRemoval(active: 5000, toRemove: 1201)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 110)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
    }

    // MARK: - P4: un riferimento non confermato non diventa affidabile da solo

    /// `before` avvelenato (Immich aveva gia' marcato quasi tutto offline): da Q1 la guardia non
    /// scatta piu' senza riferimento affidabile e non salva nessun candidato. Un candidato non
    /// confermato puo' comunque esistere (file di stato scritto da una versione precedente): il
    /// giro dopo non lo tratta come affidabile.
    func testAPoisonedCandidateReferenceDoesNotMakeTheNextRunRemoveAnything() async throws {
        let first = FakeImmichAPI(); first.totals = [600, 0]; offline(first, 10)
        let saved = SavedStates()
        let (firstReport, firstState) = try await run(first, env: immichTestEnv(saved: saved))
        XCTAssertTrue(first.deleted.isEmpty)
        XCTAssertEqual(firstReport.needsFirstConfirmation, ImmichFirstRemoval(active: 0, toRemove: 10, before: 600))
        XCTAssertNil(firstState.healthyActiveCount)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == nil })   // nessun candidato salvato
        let candidate = ImmichAlignmentState(healthyActiveCount: 600)
        XCTAssertFalse(candidate.referenceConfirmed)
        // Giro dopo: l'SSD e' ancora (quasi) vuoto, il conteggio e' dentro la soglia del candidato.
        let second = FakeImmichAPI(); second.totals = [600, 590]; offline(second, 52000)
        let (report, state) = try await run(second, state: candidate)
        XCTAssertTrue(second.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 590, toRemove: 52000))
        XCTAssertFalse(state.referenceConfirmed)
        XCTAssertEqual(state.healthyActiveCount, 600)
    }

    func testAConfirmedReferenceStaysConfirmedAcrossTwoSuccessfulRuns() async throws {
        let one = FakeImmichAPI(); one.totals = [100, 110]
        let (_, afterOne) = try await run(one, state: known)
        XCTAssertEqual(afterOne.healthyActiveCount, 110)
        XCTAssertTrue(afterOne.referenceConfirmed)
        let two = FakeImmichAPI(); two.totals = [110, 120]; offline(two, 3)
        let (report, afterTwo) = try await run(two, state: afterOne)
        XCTAssertEqual(two.deleted.map(\.count), [3])
        XCTAssertEqual(report.offlineRemoved, 3)
        XCTAssertEqual(afterTwo.healthyActiveCount, 120)
        XCTAssertTrue(afterTwo.referenceConfirmed)
    }

    func testAnAcceptedFirstRemovalMakesTheReferenceConfirmed() async throws {
        let api = FakeImmichAPI(); api.totals = [10, 10]; offline(api, 25)
        let (_, state) = try await run(api, accepted: .firstRemoval(active: 10, toRemove: 25))
        XCTAssertEqual(state.healthyActiveCount, 10)
        XCTAssertTrue(state.referenceConfirmed)
    }

    /// Da Q1, con un riferimento non affidabile il calo non scatta e non si salva nessun candidato:
    /// un riferimento non confermato resta com'e' (qui un candidato di una versione precedente).
    func testADropWithAnUnreliableReferenceKeepsItUnconfirmedAndSavesNoNewCandidate() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 0]; offline(api, 10)
        let saved = SavedStates()
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 700),
                                            env: immichTestEnv(saved: saved))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 0, toRemove: 10, before: 52139))
        XCTAssertEqual(state.healthyActiveCount, 700)
        XCTAssertFalse(state.referenceConfirmed)
        XCTAssertTrue(saved.all.allSatisfy { $0.healthyActiveCount == 700 && !$0.referenceConfirmed })
    }


    // MARK: - Q1: senza riferimento affidabile la guardia del calo non blocca, si chiede conferma

    /// Il ciclo di prima: 600 foto tolte dall'SSD, la guardia scattava, `.drop(600)` si ignorava e
    /// la guardia riscattava. Ora si va alla richiesta, che dice anche quante foto c'erano prima.
    func testAnUnconfirmedReferenceWithADropOverTheThresholdAsksWithBeforeAndRemovesNothing() async throws {
        let api = FakeImmichAPI(); api.totals = [52139, 51539]; offline(api, 600)
        let saved = SavedStates()
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139),
                                            env: immichTestEnv(saved: saved))
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 51539, toRemove: 600, before: 52139))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertFalse(state.referenceConfirmed)
        XCTAssertEqual(state.healthyActiveCount, 52139)   // il candidato di prima resta com'era, nessun salvataggio nuovo
    }

    func testTheFirstRemovalAskedAfterADropIsAcceptedWithTheSameNumbersAndDeletes() async throws {
        let ask = FakeImmichAPI(); ask.totals = [52139, 51539]; offline(ask, 600)
        let (report, _) = try await run(ask)
        let first = try XCTUnwrap(report.needsFirstConfirmation)
        XCTAssertEqual(first.before, 52139)
        XCTAssertTrue(ask.deleted.isEmpty)
        let again = FakeImmichAPI(); again.totals = [52139, 51539]; offline(again, 600)
        let (done, state) = try await run(again, accepted: .firstRemoval(active: first.active, toRemove: first.toRemove))
        XCTAssertEqual(again.deleted.map(\.count), [500, 100])
        XCTAssertEqual(done.offlineRemoved, 600)
        XCTAssertNil(done.needsFirstConfirmation)
        XCTAssertEqual(state.healthyActiveCount, 51539)
        XCTAssertTrue(state.referenceConfirmed)
    }

    /// SSD vuoto con un riferimento non affidabile: si arriva alla richiesta con `active` 0 e il `before`.
    func testAnEmptySSDWithAnUnconfirmedReferenceAsksWithActiveZeroAndBefore() async throws {
        let api = FakeImmichAPI(); api.totals = [1000, 0]; offline(api, 40)
        let (report, state) = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 1000))
        XCTAssertEqual(report.needsFirstConfirmation, ImmichFirstRemoval(active: 0, toRemove: 40, before: 1000))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertFalse(state.referenceConfirmed)
    }

    /// `before` solo quando `before - after > soglia(before)` (2 % di 1000 = 20): 20 no, 21 si.
    func testBeforeIsReportedOnlyWhenTheDropExceedsTheThreshold() async throws {
        let atEdge = FakeImmichAPI(); atEdge.totals = [1000, 980]; offline(atEdge, 5)
        let (edge, _) = try await run(atEdge)
        XCTAssertEqual(edge.needsFirstConfirmation, ImmichFirstRemoval(active: 980, toRemove: 5))
        XCTAssertNil(edge.needsFirstConfirmation?.before)
        let over = FakeImmichAPI(); over.totals = [1000, 979]; offline(over, 5)
        let (overReport, _) = try await run(over)
        XCTAssertEqual(overReport.needsFirstConfirmation, ImmichFirstRemoval(active: 979, toRemove: 5, before: 1000))
        let grew = FakeImmichAPI(); grew.totals = [10, 1000]; offline(grew, 5)
        let (grewReport, _) = try await run(grew)
        XCTAssertNil(grewReport.needsFirstConfirmation?.before)
        XCTAssertTrue(over.deleted.isEmpty && atEdge.deleted.isEmpty && grew.deleted.isEmpty)
    }

    /// Con un riferimento affidabile la guardia del calo scatta come prima.
    func testAReliableReferenceStillTripsTheDropGuardAfterTheScan() async {
        let api = FakeImmichAPI(); api.totals = [52139, 51539]; offline(api, 600)
        do { _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 600)) }
        XCTAssertTrue(api.deleted.isEmpty)
    }

    /// Il ricontrollo prima di ogni blocco resta, e con un riferimento non affidabile si confronta
    /// con l'`active` confermato: un crollo a meta' si ferma anche dopo la richiesta saltata.
    func testTheCheckBeforeEachBlockStillComparesWithTheConfirmedActiveAfterADrop() async {
        let api = FakeImmichAPI(); offline(api, 1201)
        api.totals = [52139, 5000, 5000, 4000]   // prima, dopo, blocco 1, blocco 2 (crollo)
        do { _ = try await run(api, accepted: .firstRemoval(active: 5000, toRemove: 1201)); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .dropGuard(missing: 1000)) }
        XCTAssertEqual(api.deleted.map(\.count), [500])
    }

    // MARK: - P5: il segnale che il riferimento e' avanzato

    func testRunSignalsWhenTheReferenceAdvancesEvenIfALaterStepFails() async {
        let api = FakeImmichAPI(); api.totals = [100, 100]
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.stackErrors = ["s1": .notReachable]
        let signals = SignalCounter()
        var env = immichTestEnv()
        env.referenceAdvanced = { signals.count += 1 }
        do { _ = try await run(api, state: known, env: env); XCTFail("doveva fermarsi") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .notReachable) }
        XCTAssertEqual(signals.count, 1)
    }

    func testRunDoesNotSignalWhenTheReferenceDoesNotAdvance() async throws {
        let api = FakeImmichAPI(); api.busyPolls = 10_000
        let signals = SignalCounter()
        var env = immichTestEnv(waitLimit: 60)
        env.referenceAdvanced = { signals.count += 1 }
        _ = try await run(api, state: known, env: env)
        XCTAssertEqual(signals.count, 0)
    }

    // MARK: - N4: il salvataggio dello stato non e' silenzioso

    func testSaveFailingWhenTheGuardTripsReportsStateNotSavedInsteadOfDropGuard() async {
        let api = FakeImmichAPI(); api.totals = [52139, 0]
        var env = immichTestEnv()
        env.saveState = { _ in throw SaveFailed() }
        do { _ = try await run(api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true), env: env); XCTFail("doveva fermarsi") }
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
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        aligner.accept(.drop(missing: 12139))
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 40000)
    }

    /// B2: la conferma vale per il numero mostrato, e per un solo giro.
    func testAcceptedNumberCoversOnlyThatDropAndOnlyOnce() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.request(.manual)
        await aligner.currentTask?.value
        aligner.accept(.drop(missing: 600))   // l'utente ha confermato 600, ma ne mancano 12.139
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
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
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
        aligner.accept(.firstRemoval(active: 100, toRemove: 1))
        await aligner.currentTask?.value
        XCTAssertEqual(api.deleted, [["off"]])
    }

    func testDuplicatesMovedWhileImmichIsOffStillCount() async throws {
        let api = FakeImmichAPI(); api.totals = [51139]
        var running = false
        let (aligner, _, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
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
        XCTAssertEqual(aligner.status.confirmationToAccept, .firstRemoval(active: 10, toRemove: 25))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertNil(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount)
        aligner.accept(.firstRemoval(active: 10, toRemove: 25))
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertEqual(api.deleted.map(\.count), [25])
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 10)
    }

    /// Q1 sul coordinatore: dopo un calo oltre la soglia con riferimento non affidabile lo stato
    /// porta il `before`, la conferma resta `(active, toRemove)`, e accettarla toglie le foto.
    func testFirstRemovalAfterADropShowsBeforeAndAcceptDeletes() async throws {
        let api = FakeImmichAPI(); api.totals = [600, 0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let (aligner, _, _) = try makeAligner(api: api)
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .confirmFirstRemoval(active: 0, toRemove: 10, before: 600))
        XCTAssertEqual(aligner.status.firstRemovalBefore, 600)
        XCTAssertEqual(aligner.status.confirmationToAccept, .firstRemoval(active: 0, toRemove: 10))
        XCTAssertTrue(api.deleted.isEmpty)
        aligner.accept(.firstRemoval(active: 0, toRemove: 10))
        await aligner.currentTask?.value
        XCTAssertEqual(api.deleted.map(\.count), [10])
    }

    // MARK: - N2: la conferma non resta appesa

    func testConfirmationGivenWhileImmichIsOffDoesNotSurviveToALaterRun() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        var running = false
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.isImmichRunning = { running }
        aligner.accept(.drop(missing: 12139))   // Immich spento: nessun giro parte
        XCTAssertNil(aligner.currentTask)
        running = true
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 12139))
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
    }

    func testConfirmationGivenWithoutAKeyDoesNotSurviveToALaterRun() async throws {
        let api = FakeImmichAPI(); api.totals = [40000]
        let (aligner, _, _) = try makeAligner(api: api, key: nil, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.accept(.drop(missing: 12139))
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
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
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
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
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

    /// P5: il margine si restituisce in base al segnale, non al confronto dei valori: un riferimento
    /// avanzato a un valore identico al precedente ha comunque usato il margine.
    func testAllowanceUsedByARunWhoseReferenceAdvancedToTheSameValueIsNotReturned() async throws {
        let api = FakeImmichAPI(); api.totals = [51139, 52139]   // giro 1: before 51139, after 52139 (= riferimento)
        api.duplicateGroups = [ImmichDuplicateGroup(duplicateId: "d1", assets: [immichTestAsset("s1"), immichTestAsset("s2")])]
        api.stackErrors = ["s1": .notReachable]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.request(.duplicatesMoved(count: 1000))
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .failed(.notReachable))
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)   // identico al precedente
        api.stackErrors = [:]
        api.totals = [51139]   // un calo di 1000: senza margine scatta (con il margine restituito passerebbe)
        aligner.request(.manual)
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 1000))
    }

    /// P1 sul coordinatore: la conferma della prima rimozione, arrivata a un giro con riferimento
    /// affidabile e SSD vuoto, non toglie niente e non allarga la guardia.
    func testAFirstRemovalConfirmationReachingAReliableEmptyRunRemovesNothing() async throws {
        let api = FakeImmichAPI(); api.totals = [0]
        api.offlineAssets = (0..<10).map { immichTestAsset("o\($0)", offline: true, trashed: true) }
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 52139, referenceConfirmed: true))
        aligner.accept(.firstRemoval(active: 52139, toRemove: 89514))
        await aligner.currentTask?.value
        XCTAssertEqual(aligner.status, .dropGuard(missing: 52139))
        XCTAssertTrue(api.deleted.isEmpty)
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).state.healthyActiveCount, 52139)
    }

    // MARK: - N4: stato non salvato

    func testAnUnwritableStateFileStopsTheRunWithStateNotSaved() async throws {
        let api = FakeImmichAPI()
        api.offlineAssets = [immichTestAsset("off", offline: true, trashed: true)]
        let (aligner, stateURL, _) = try makeAligner(api: api, state: ImmichAlignmentState(healthyActiveCount: 100, referenceConfirmed: true))
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
