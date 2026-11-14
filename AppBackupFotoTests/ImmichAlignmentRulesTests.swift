import XCTest
@testable import AppBackupFoto

/// Una foto finta di Immich. Interna (non privata): la usa anche `ImmichAlignmentRunTests`.
func immichTestAsset(_ id: String, type: String = "IMAGE", width: Int? = 4000, height: Int? = 3000,
                     size: Int64? = 2_000_000, offline: Bool = false, trashed: Bool = false,
                     visibility: String = "timeline", library: String? = "lib",
                     stack: ImmichStackRef? = nil) -> ImmichAsset {
    ImmichAsset(id: id, type: type, libraryId: library, isOffline: offline, isTrashed: trashed,
                visibility: visibility,
                exifInfo: ImmichExif(exifImageWidth: width, exifImageHeight: height, fileSizeInByte: size),
                stack: stack)
}

/// Regole pure dell'allineamento di Immich (ROADMAP #50, ADR-0021). Nessuna rete, nessun Immich.
final class ImmichAlignmentRulesTests: XCTestCase {

    // MARK: - Decodifica (forme di Immich v3.2.0, dalla sua specifica OpenAPI)

    func testDecodesAnAssetWithExifAndStack() throws {
        let json = """
        {"id":"a1","type":"IMAGE","libraryId":"lib","isOffline":false,"isTrashed":true,
         "visibility":"timeline","width":null,"height":null,"originalPath":"/external-ssd/x.jpg",
         "exifInfo":{"exifImageWidth":320,"exifImageHeight":240,"fileSizeInByte":12345,"make":"Apple"},
         "stack":{"id":"s1","primaryAssetId":"a1","assetCount":2},"checksum":"abc"}
        """
        let asset = try JSONDecoder().decode(ImmichAsset.self, from: Data(json.utf8))
        XCTAssertEqual(asset.id, "a1")
        XCTAssertTrue(asset.isTrashed)
        XCTAssertEqual(asset.pixelWidth, 320)
        XCTAssertEqual(asset.pixelHeight, 240)
        XCTAssertEqual(asset.exifInfo?.fileSizeInByte, 12345)
        XCTAssertEqual(asset.stack?.primaryAssetId, "a1")
    }

    func testAssetWithoutExifFallsBackToTopLevelSize() throws {
        let json = #"{"id":"a2","type":"VIDEO","libraryId":null,"isOffline":true,"isTrashed":false,"visibility":"hidden","width":1920,"height":1080,"stack":null}"#
        let asset = try JSONDecoder().decode(ImmichAsset.self, from: Data(json.utf8))
        XCTAssertNil(asset.libraryId)
        XCTAssertNil(asset.exifInfo)
        XCTAssertEqual(asset.pixelWidth, 1920)
        XCTAssertEqual(asset.pixelHeight, 1080)
        XCTAssertNil(asset.stack)
    }

    func testPixelSizeComesFromOneSourceOnly() {
        // exif con la sola larghezza + primo livello completo: vale la coppia di primo livello.
        let mixed = ImmichAsset(id: "m", type: "IMAGE", width: 1920, height: 1080,
                                exifInfo: ImmichExif(exifImageWidth: 320, exifImageHeight: nil))
        XCTAssertEqual(mixed.pixelWidth, 1920)
        XCTAssertEqual(mixed.pixelHeight, 1080)
        // exif completo: vince sul primo livello.
        let exifWins = ImmichAsset(id: "e", type: "IMAGE", width: 1920, height: 1080,
                                   exifInfo: ImmichExif(exifImageWidth: 320, exifImageHeight: 240))
        XCTAssertEqual(exifWins.pixelWidth, 320)
        XCTAssertEqual(exifWins.pixelHeight, 240)
        // nessuna coppia completa: nil per tutte e due.
        let half = ImmichAsset(id: "h", type: "IMAGE", width: 1920, height: nil,
                               exifInfo: ImmichExif(exifImageWidth: nil, exifImageHeight: 240))
        XCTAssertNil(half.pixelWidth)
        XCTAssertNil(half.pixelHeight)
    }

    func testDecodesSearchPageLibrariesStatsJobsAndKey() throws {
        let page = try JSONDecoder().decode(ImmichSearchResponse.self, from: Data(#"""
        {"albums":{"total":0,"count":0,"items":[],"facets":[]},
         "assets":{"total":1,"count":1,"facets":[],"nextPage":"2","nextCursor":null,
                   "items":[{"id":"a1","type":"IMAGE","isOffline":false,"isTrashed":false,"visibility":"timeline"}]}}
        """#.utf8))
        XCTAssertEqual(page.assets.items.map(\.id), ["a1"])
        XCTAssertEqual(page.assets.nextPage, "2")
        XCTAssertNil(page.assets.nextCursor)

        let libs = try JSONDecoder().decode([ImmichLibrary].self, from: Data(#"""
        [{"id":"l1","ownerId":"u","name":"SSD - Enri","assetCount":5,"importPaths":["/external-ssd"],
          "exclusionPatterns":["**/._*"],"createdAt":"x","updatedAt":"y","refreshedAt":null}]
        """#.utf8))
        XCTAssertEqual(libs, [ImmichLibrary(id: "l1", name: "SSD - Enri", importPaths: ["/external-ssd"])])

        let stats = try JSONDecoder().decode(ImmichLibraryStats.self,
            from: Data(#"{"photos":40000,"videos":12139,"total":52139,"usage":1}"#.utf8))
        XCTAssertEqual(stats.total, 52139)

        let busy = try JSONDecoder().decode(ImmichJobs.self, from: Data(#"""
        {"library":{"queueStatus":{"isActive":true,"isPaused":false},
                    "jobCounts":{"active":1,"completed":0,"failed":0,"delayed":0,"waiting":3,"paused":0}},
         "thumbnailGeneration":{"queueStatus":{"isActive":true,"isPaused":false},
                    "jobCounts":{"active":9,"completed":0,"failed":0,"delayed":0,"waiting":900,"paused":0}}}
        """#.utf8))
        XCTAssertFalse(busy.libraryIsIdle)
        XCTAssertTrue(ImmichJobs(library: .init(jobCounts: .init(active: 0, waiting: 0, delayed: 0))).libraryIsIdle)

        let key = try JSONDecoder().decode(ImmichAPIKeyCreated.self, from: Data(#"""
        {"id":"k","name":"n","createdAt":"x","updatedAt":"y","permissions":["asset.read"],"secret":"SEGRETO",
         "apiKey":{"id":"k","name":"n","createdAt":"x","updatedAt":"y","permissions":["asset.read"]}}
        """#.utf8))
        XCTAssertEqual(key.secret, "SEGRETO")
        let login = try JSONDecoder().decode(ImmichLoginResponse.self, from: Data(#"{"accessToken":"T","userId":"u","userEmail":"e","name":"n","profileImagePath":"","isAdmin":true,"shouldChangePassword":false,"isOnboarded":true}"#.utf8))
        XCTAssertEqual(login.accessToken, "T")
    }

    // MARK: - Libreria dell'SSD

    func testFindsTheSSDLibraryByMountTargetAndIgnoresTheEmptyOne() {
        let libs = [ImmichLibrary(id: "old", name: "New External Library", importPaths: []),
                    ImmichLibrary(id: "ssd", name: "SSD - Enri", importPaths: ["/external-ssd"])]
        XCTAssertEqual(ImmichAlignmentRules.ssdLibrary(in: libs)?.id, "ssd")
        XCTAssertNil(ImmichAlignmentRules.ssdLibrary(in: [libs[0]]))
    }

    // MARK: - Offline

    func testRemovesOnlyOfflineAssetsAlreadyInTheTrashOfTheSSDLibrary() {
        let assets = [
            immichTestAsset("offline-trashed", offline: true, trashed: true),
            immichTestAsset("offline-not-trashed", offline: true, trashed: false),
            immichTestAsset("trashed-by-hand", offline: false, trashed: true),
            immichTestAsset("other-library", offline: true, trashed: true, library: "altra"),
            immichTestAsset("uploaded", offline: true, trashed: true, library: nil),
        ]
        XCTAssertEqual(ImmichAlignmentRules.offlineToRemove(assets, libraryId: "lib"), ["offline-trashed"])
    }

    // MARK: - Guardia del calo

    func testDropThresholdIsTheSmallerOf500AndTwoPercent() {
        XCTAssertEqual(ImmichAlignmentRules.dropThreshold(baseline: 52139), 500)
        XCTAssertEqual(ImmichAlignmentRules.dropThreshold(baseline: 10000), 200)
        XCTAssertEqual(ImmichAlignmentRules.dropThreshold(baseline: 30), 0)
        XCTAssertEqual(ImmichAlignmentRules.dropThreshold(baseline: -5), 0)
    }

    func testDropGuardTripsOnlyAboveTheThreshold() {
        XCTAssertFalse(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 51639)) // -500
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 51638))  // -501
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 0))      // SSD vuoto nella VM
        XCTAssertFalse(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 60000)) // foto nuove
        XCTAssertFalse(ImmichAlignmentRules.dropGuardTripped(baseline: 10000, activeAfter: 9800))   // -2 % esatto
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 10000, activeAfter: 9799))    // oltre il 2 %
        XCTAssertFalse(ImmichAlignmentRules.dropGuardTripped(baseline: 0, activeAfter: 0))          // niente da perdere
    }

    func testDropGuardWithAConfirmedNumberToleratesThatNumberPlusTheThreshold() {
        XCTAssertFalse(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 52139 - 1100, acceptedMissing: 600))
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 52139 - 1101, acceptedMissing: 600))
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 0, acceptedMissing: 600))
        // senza conferma resta la regola di sempre; una conferma negativa non allarga niente
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 51638, acceptedMissing: nil))
        XCTAssertTrue(ImmichAlignmentRules.dropGuardTripped(baseline: 52139, activeAfter: 51638, acceptedMissing: -50))
    }

    // MARK: - Coda in pausa (M1)

    func testPausedJobsMakeTheLibraryQueueNotIdle() throws {
        XCTAssertFalse(ImmichJobs(library: .init(jobCounts: .init(active: 0, waiting: 0, delayed: 0, paused: 2))).libraryIsIdle)
        let paused = try JSONDecoder().decode(ImmichJobs.self, from: Data(#"{"library":{"jobCounts":{"active":0,"completed":5,"failed":0,"delayed":0,"waiting":0,"paused":4}}}"#.utf8))
        XCTAssertFalse(paused.libraryIsIdle)
        let noPausedKey = try JSONDecoder().decode(ImmichJobs.self, from: Data(#"{"library":{"jobCounts":{"active":0,"waiting":0,"delayed":0}}}"#.utf8))
        XCTAssertTrue(noPausedKey.libraryIsIdle)
    }

    // MARK: - Pile

    func testStackPrimaryIsMostPixelsThenBiggestFileThenSmallestID() {
        let group = [
            immichTestAsset("c", width: 1000, height: 1000, size: 9_000_000),
            immichTestAsset("b", width: 4000, height: 3000, size: 1_000),
            immichTestAsset("a", width: 4000, height: 3000, size: 1_000),
            immichTestAsset("z", width: 4000, height: 3000, size: 5_000),
            immichTestAsset("n", width: nil, height: nil, size: 99_000_000),
        ]
        XCTAssertEqual(ImmichAlignmentRules.stackOrder(group), ["z", "a", "b", "c", "n"])
    }

    func testGroupsToStackSkipsAlreadyStackedTrashedAndTooSmallGroups() {
        let stackRef = ImmichStackRef(id: "s", primaryAssetId: "x")
        let groups = [
            ImmichDuplicateGroup(duplicateId: "ok", assets: [immichTestAsset("1"), immichTestAsset("2", width: 100, height: 100)]),
            ImmichDuplicateGroup(duplicateId: "done-before", assets: [immichTestAsset("3"), immichTestAsset("4")]),
            ImmichDuplicateGroup(duplicateId: "has-stack", assets: [immichTestAsset("5", stack: stackRef), immichTestAsset("6")]),
            ImmichDuplicateGroup(duplicateId: "one-left", assets: [immichTestAsset("7"), immichTestAsset("8", trashed: true)]),
            ImmichDuplicateGroup(duplicateId: "trashed-member-ignored",
                                 assets: [immichTestAsset("9"), immichTestAsset("10"), immichTestAsset("11", offline: true, trashed: true)]),
        ]
        let plans = ImmichAlignmentRules.groupsToStack(groups, alreadyStacked: ["done-before"])
        XCTAssertEqual(plans, [ImmichStackPlan(duplicateId: "ok", assetIds: ["1", "2"]),
                               ImmichStackPlan(duplicateId: "trashed-member-ignored", assetIds: ["10", "9"])])
    }

    func testGroupsToStackKeepsOnlyAssetsOfTheGivenLibrary() {
        let groups = [
            ImmichDuplicateGroup(duplicateId: "mixed", assets: [immichTestAsset("1"), immichTestAsset("2"), immichTestAsset("x", library: "altra")]),
            ImmichDuplicateGroup(duplicateId: "one-left", assets: [immichTestAsset("3"), immichTestAsset("y", library: "altra")]),
            ImmichDuplicateGroup(duplicateId: "no-library", assets: [immichTestAsset("4"), immichTestAsset("z", library: nil)]),
        ]
        XCTAssertEqual(ImmichAlignmentRules.groupsToStack(groups, alreadyStacked: [], libraryId: "lib"),
                       [ImmichStackPlan(duplicateId: "mixed", assetIds: ["1", "2"])])
        // senza libreria nessun filtro (comportamento di prima)
        XCTAssertEqual(ImmichAlignmentRules.groupsToStack(groups, alreadyStacked: []).count, 3)
    }

    // MARK: - Minuscole

    func testTinyIsAnImageWithLongSideUnder400() {
        XCTAssertTrue(ImmichAlignmentRules.isTiny(immichTestAsset("a", width: 399, height: 120)))
        XCTAssertFalse(ImmichAlignmentRules.isTiny(immichTestAsset("b", width: 400, height: 120)))
        XCTAssertFalse(ImmichAlignmentRules.isTiny(immichTestAsset("c", type: "VIDEO", width: 160, height: 120)))
        XCTAssertFalse(ImmichAlignmentRules.isTiny(immichTestAsset("d", width: nil, height: nil)))
        XCTAssertFalse(ImmichAlignmentRules.isTiny(immichTestAsset("e", width: 0, height: 0)))
    }

    func testArchivesTinyTimelineAssetsNeverArchivedBefore() {
        let assets = [
            immichTestAsset("tiny", width: 200, height: 150),
            immichTestAsset("big"),
            immichTestAsset("tiny-already-archived", width: 200, height: 150, visibility: "archive"),
            immichTestAsset("tiny-hidden", width: 200, height: 150, visibility: "hidden"),
            immichTestAsset("tiny-trashed", width: 200, height: 150, trashed: true),
            immichTestAsset("tiny-unarchived-by-enrico", width: 200, height: 150),
            immichTestAsset("tiny-offline", width: 200, height: 150, offline: true),
        ]
        XCTAssertEqual(ImmichAlignmentRules.assetsToArchive(assets, alreadyArchived: ["tiny-unarchived-by-enrico"]), ["tiny"])
    }

    func testAssetsToArchiveKeepsOnlyTheGivenLibrary() {
        let assets = [immichTestAsset("mine", width: 100, height: 100),
                      immichTestAsset("other", width: 100, height: 100, library: "altra"),
                      immichTestAsset("none", width: 100, height: 100, library: nil)]
        XCTAssertEqual(ImmichAlignmentRules.assetsToArchive(assets, alreadyArchived: [], libraryId: "lib"), ["mine"])
        XCTAssertEqual(ImmichAlignmentRules.assetsToArchive(assets, alreadyArchived: []).count, 3)
    }

    // MARK: - Blocchi

    func testChunksOf500() {
        let ids = (0..<1201).map(String.init)
        let chunks = ImmichAlignmentRules.chunks(ids)
        XCTAssertEqual(chunks.map(\.count), [500, 500, 201])
        XCTAssertEqual(chunks.flatMap { $0 }, ids)
        XCTAssertEqual(ImmichAlignmentRules.chunks([]), [])
    }

    // MARK: - Stato salvato

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-align-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    func testStateRoundTripsAndMissingFileIsEmpty() throws {
        let url = tempURL("immich-alignment.json")
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: url).state, ImmichAlignmentState())
        XCTAssertFalse(ImmichAlignmentStateStore.load(from: url).wasUnreadable)   // assente non e' illeggibile
        let state = ImmichAlignmentState(archivedAssetIds: ["a"], stackedDuplicateIds: ["d"], healthyActiveCount: 52139,
                                         referenceConfirmed: true)
        try ImmichAlignmentStateStore.save(state, to: url)
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: url).state, state)
        XCTAssertFalse(ImmichAlignmentStateStore.load(from: url).wasUnreadable)
    }

    func testUnreadableStateFileIsMovedAsideAndReportedAsUnreadable() throws {
        let url = tempURL("immich-alignment.json")
        let aside = url.appendingPathExtension("illeggibile")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("spazzatura".utf8).write(to: url)
        let loaded = ImmichAlignmentStateStore.load(from: url)
        XCTAssertEqual(loaded.state, ImmichAlignmentState())
        XCTAssertTrue(loaded.wasUnreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "spazzatura")
        XCTAssertEqual(aside.lastPathComponent, "immich-alignment.json.illeggibile")
        // una seconda copia di scarto sostituisce la prima
        try Data("altra spazzatura".utf8).write(to: url)
        XCTAssertTrue(ImmichAlignmentStateStore.load(from: url).wasUnreadable)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "altra spazzatura")
        // e dopo, senza file, torna uno stato vuoto non segnalato
        XCTAssertFalse(ImmichAlignmentStateStore.load(from: url).wasUnreadable)
    }

    func testStateWithMissingKeysDecodesWithDefaults() throws {
        let state = try JSONDecoder().decode(ImmichAlignmentState.self, from: Data(#"{"archivedAssetIds":["x"]}"#.utf8))
        XCTAssertEqual(state, ImmichAlignmentState(archivedAssetIds: ["x"]))
    }

    func testStateLivesOnTheMacNeverOnTheSSD() {
        let path = ImmichAlignmentStateStore.defaultURL.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/AppBackupFoto/immich-alignment.json"), path)
        XCTAssertFalse(path.hasPrefix("/Volumes/"))
        XCTAssertTrue(ImmichAlignmentLog.defaultURL.path.hasSuffix("Library/Logs/AppBackupFoto/immich-alignment.log"))
    }

    // MARK: - Testi

    private let rome = TimeZone(identifier: "Europe/Rome")!
    /// 2026-11-13 21:41 UTC = 22:41 a Roma.
    private let date = Date(timeIntervalSince1970: 1_794_606_060)

    func testDoneLineListsOnlyNonZeroNumbers() {
        let report = ImmichAlignmentReport(newAssets: 12, offlineRemoved: 89514, stacksCreated: 340, archived: 4561)
        XCTAssertEqual(ImmichAlignmentText.done(report, at: date, timeZone: rome),
            "Immich aggiornato alle 22:41: 12 foto nuove, 89.514 tolte perché non più sull'SSD, 340 pile, 4.561 archiviate.")
        XCTAssertEqual(ImmichAlignmentText.done(ImmichAlignmentReport(newAssets: 1, offlineRemoved: 1, stacksCreated: 1, archived: 1), at: date, timeZone: rome),
            "Immich aggiornato alle 22:41: 1 foto nuova, 1 tolta perché non più sull'SSD, 1 pila, 1 archiviata.")
        XCTAssertEqual(ImmichAlignmentText.done(ImmichAlignmentReport(), at: date, timeZone: rome),
            "Immich aggiornato alle 22:41: niente da cambiare.")
    }

    func testDoneLineSaysWhenTheScanDidNotFinish() {
        var report = ImmichAlignmentReport(); report.scanTimedOut = true
        XCTAssertTrue(ImmichAlignmentText.done(report, at: date, timeZone: rome)
            .hasSuffix(" La scansione non è finita in 30 minuti: il resto entra al prossimo giro."))
    }

    func testDoneLineSaysWhenNoOfflinePhotoWasRemovedAndWhy() {
        var timedOut = ImmichAlignmentReport(); timedOut.scanTimedOut = true; timedOut.offlineSkipped = true
        XCTAssertTrue(ImmichAlignmentText.done(timedOut, at: date, timeZone: rome)
            .hasSuffix(" Immich sta ancora leggendo l'SSD: le foto che non ci sono più le tolgo al prossimo giro."))
        var unreadable = ImmichAlignmentReport(); unreadable.offlineSkipped = true; unreadable.stateWasUnreadable = true
        XCTAssertTrue(ImmichAlignmentText.done(unreadable, at: date, timeZone: rome)
            .hasSuffix(" Il file dell'allineamento non si leggeva ed è stato messo da parte: prima di togliere foto da Immich ti chiederò conferma."))
        var busy = ImmichAlignmentReport(); busy.removalStopped = true
        XCTAssertTrue(ImmichAlignmentText.done(busy, at: date, timeZone: rome)
            .hasSuffix(" Immich ha iniziato una nuova scansione: le foto che non ci sono più le tolgo al prossimo giro."))
    }

    func testFailureLines() {
        XCTAssertEqual(ImmichAlignmentText.failure(.ssdNotMounted), "Immich non aggiornato: l'SSD non è collegato.")
        XCTAssertEqual(ImmichAlignmentText.failure(.unauthorized), ImmichAlignmentText.needsKey)
        XCTAssertEqual(ImmichAlignmentText.failure(.http(500)), "Immich non aggiornato: Immich ha risposto con un errore (codice 500).")
        XCTAssertEqual(ImmichAlignmentText.failure(.dropGuard(missing: 52139)),
            "Immich non aggiornato: dopo la scansione mancano 52.139 foto rispetto all'ultima volta. Non tolgo niente: controlla che l'SSD sia collegato bene e premi «Riprova». Le foto sono nel Cestino di Immich.")
        for failure: ImmichAlignmentFailure in [.libraryNotFound, .notReachable, .badResponse, .keychain] {
            XCTAssertTrue(ImmichAlignmentText.failure(failure).hasPrefix("Immich non aggiornato: "), "\(failure)")
        }
    }

    func testConfirmationToAccept_isTypedAndOnlyForTheTwoConfirmableStates() {
        XCTAssertEqual(ImmichAlignmentStatus.dropGuard(missing: 52139).confirmationToAccept, .drop(missing: 52139))
        XCTAssertEqual(ImmichAlignmentStatus.confirmFirstRemoval(active: 10, toRemove: 25).confirmationToAccept,
                       .firstRemoval(active: 10, toRemove: 25))
        XCTAssertNil(ImmichAlignmentStatus.idle.confirmationToAccept)
        XCTAssertNil(ImmichAlignmentStatus.running("x").confirmationToAccept)
        XCTAssertNil(ImmichAlignmentStatus.needsKey.confirmationToAccept)
        XCTAssertNil(ImmichAlignmentStatus.failed(.notReachable).confirmationToAccept)
        XCTAssertNil(ImmichAlignmentStatus.failed(.dropGuard(missing: 7)).confirmationToAccept)
        XCTAssertNil(ImmichAlignmentStatus.done(ImmichAlignmentReport(), Date()).confirmationToAccept)
    }

    // MARK: - P2: il clic conferma solo lo stato che l'alert ha mostrato

    func testShouldAccept_confirmsOnlyWhenTheStateIsStillTheFrozenOne() {
        let frozen = ImmichConfirmation.firstRemoval(active: 52139, toRemove: 89514)
        XCTAssertEqual(ImmichConfirmation.shouldAccept(frozen: frozen, current: frozen), frozen)
        // lo stato e' diventato un'altra richiesta, o numeri diversi, o nessuna richiesta
        XCTAssertNil(ImmichConfirmation.shouldAccept(frozen: frozen, current: .drop(missing: 89514)))
        XCTAssertNil(ImmichConfirmation.shouldAccept(frozen: frozen, current: .firstRemoval(active: 52139, toRemove: 89515)))
        XCTAssertNil(ImmichConfirmation.shouldAccept(frozen: frozen, current: .firstRemoval(active: 0, toRemove: 89514)))
        XCTAssertNil(ImmichConfirmation.shouldAccept(frozen: frozen, current: nil))
        XCTAssertNil(ImmichConfirmation.shouldAccept(frozen: .drop(missing: 5), current: .drop(missing: 6)))
        XCTAssertEqual(ImmichConfirmation.shouldAccept(frozen: .drop(missing: 5), current: .drop(missing: 5)), .drop(missing: 5))
    }

    func testConfirmationTextComesFromTheFrozenConfirmation() {
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: ImmichConfirmation.firstRemoval(active: 52139, toRemove: 89514)),
            "89.514 foto escono da Immich (solo dal suo elenco: i file sull'SSD non vengono toccati). Le 52.139 foto che Immich vede restano.")
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: ImmichConfirmation.drop(missing: 600)),
                       ImmichAlignmentText.acceptDropConfirmation(missing: 600))
    }

    // MARK: - P4: il riferimento confermato sopravvive al file e un file vecchio non lo e'

    func testReferenceConfirmedSurvivesSaveAndLoad() throws {
        let url = tempURL("immich-alignment.json")
        try ImmichAlignmentStateStore.save(ImmichAlignmentState(healthyActiveCount: 7, referenceConfirmed: true), to: url)
        XCTAssertTrue(ImmichAlignmentStateStore.load(from: url).state.referenceConfirmed)
        try ImmichAlignmentStateStore.save(ImmichAlignmentState(healthyActiveCount: 7, referenceConfirmed: false), to: url)
        XCTAssertFalse(ImmichAlignmentStateStore.load(from: url).state.referenceConfirmed)
    }

    func testAnOldStateFileWithoutTheFieldDecodesAsNotConfirmed() throws {
        let state = try JSONDecoder().decode(ImmichAlignmentState.self,
                                             from: Data(#"{"archivedAssetIds":[],"healthyActiveCount":52139,"stackedDuplicateIds":[]}"#.utf8))
        XCTAssertEqual(state.healthyActiveCount, 52139)
        XCTAssertFalse(state.referenceConfirmed)
    }

    func testConfirmFirstRemovalStatus() {
        let status = ImmichAlignmentStatus.confirmFirstRemoval(active: 52139, toRemove: 89514)
        XCTAssertEqual(status.line(),
            "Prima di togliere foto da Immich mi serve un tuo sì: Immich vede 52.139 foto sull'SSD e ne toglierebbe 89.514 che sull'SSD non ci sono più.")
        XCTAssertFalse(status.isProblem)
        XCTAssertEqual(status.actions, [.acceptDrop])
        XCTAssertEqual(status.confirmationToAccept, .firstRemoval(active: 52139, toRemove: 89514))
    }

    func testConfirmationTextPerStatus() {
        XCTAssertEqual(ImmichAlignmentText.firstRemovalConfirmation(active: 52139, toRemove: 89514),
            "89.514 foto escono da Immich (solo dal suo elenco: i file sull'SSD non vengono toccati). Le 52.139 foto che Immich vede restano.")
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: .confirmFirstRemoval(active: 10, toRemove: 25)),
                       ImmichAlignmentText.firstRemovalConfirmation(active: 10, toRemove: 25))
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: .dropGuard(missing: 600)),
                       ImmichAlignmentText.acceptDropConfirmation(missing: 600))
        XCTAssertNil(ImmichAlignmentText.confirmation(for: .idle))
        XCTAssertNil(ImmichAlignmentText.confirmation(for: .needsKey))
        XCTAssertNil(ImmichAlignmentText.confirmation(for: .failed(.notReachable)))
        XCTAssertNil(ImmichAlignmentText.confirmation(for: .done(ImmichAlignmentReport(), Date())))
    }

    // MARK: - Q1: quante foto c'erano prima della scansione

    func testFirstRemovalLineAddsTheBeforeWhenKnown() {
        let status = ImmichAlignmentStatus.confirmFirstRemoval(active: 51539, toRemove: 600, before: 52139)
        XCTAssertEqual(status.line(),
            "Prima di togliere foto da Immich mi serve un tuo sì: Immich vede 51.539 foto sull'SSD e ne toglierebbe 600 che sull'SSD non ci sono più. Attenzione: prima della scansione Immich ne vedeva 52.139.")
        // il `before` e' solo informativo: non entra nella conferma
        XCTAssertEqual(status.confirmationToAccept, .firstRemoval(active: 51539, toRemove: 600))
        XCTAssertEqual(status.firstRemovalBefore, 52139)
        XCTAssertNil(ImmichAlignmentStatus.confirmFirstRemoval(active: 1, toRemove: 2).firstRemovalBefore)
        XCTAssertFalse(ImmichAlignmentStatus.confirmFirstRemoval(active: 1, toRemove: 2).line().contains("Attenzione"))
    }

    func testFirstRemovalAlertTextAddsTheBeforeWhenKnown() {
        let confirmation = ImmichConfirmation.firstRemoval(active: 51539, toRemove: 600)
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: confirmation, before: 52139),
            "600 foto escono da Immich (solo dal suo elenco: i file sull'SSD non vengono toccati). Le 51.539 foto che Immich vede restano. Attenzione: prima della scansione Immich ne vedeva 52.139.")
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: .confirmFirstRemoval(active: 51539, toRemove: 600, before: 52139)),
                       ImmichAlignmentText.confirmation(for: confirmation, before: 52139))
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: confirmation),
                       ImmichAlignmentText.firstRemovalConfirmation(active: 51539, toRemove: 600))
        // il `before` non riguarda il blocco del calo
        XCTAssertEqual(ImmichAlignmentText.confirmation(for: ImmichConfirmation.drop(missing: 600), before: 52139),
                       ImmichAlignmentText.acceptDropConfirmation(missing: 600))
    }

    // MARK: - Q2: l'alert non si chiude a ogni aggiornamento di avanzamento

    func testAlertMustCloseOnlyWhenTheFrozenConfirmationIsNoLongerAsked() {
        let frozen = ImmichConfirmation.firstRemoval(active: 10, toRemove: 25)
        XCTAssertFalse(ImmichConfirmation.alertMustClose(frozen: frozen, current: frozen))
        XCTAssertTrue(ImmichConfirmation.alertMustClose(frozen: frozen, current: nil))
        XCTAssertTrue(ImmichConfirmation.alertMustClose(frozen: frozen, current: .firstRemoval(active: 10, toRemove: 26)))
        XCTAssertTrue(ImmichConfirmation.alertMustClose(frozen: frozen, current: .drop(missing: 25)))
        XCTAssertFalse(ImmichConfirmation.alertMustClose(frozen: nil, current: nil))
        XCTAssertFalse(ImmichConfirmation.alertMustClose(frozen: nil, current: frozen))
    }

    /// Gli aggiornamenti di avanzamento non cambiano la conferma richiesta, quindi non chiudono l'alert.
    func testProgressUpdatesDoNotChangeTheConfirmationToAccept() {
        let a = ImmichAlignmentStatus.running(ImmichAlignmentText.scanning)
        let b = ImmichAlignmentStatus.running(ImmichAlignmentText.cleaning)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.confirmationToAccept, b.confirmationToAccept)
        XCTAssertFalse(ImmichConfirmation.alertMustClose(frozen: nil, current: b.confirmationToAccept))
    }

    func testStateNotSavedLine() {
        XCTAssertEqual(ImmichAlignmentText.failure(.stateNotSaved),
            "Non riesco a salvare il file dell'allineamento sul Mac: per sicurezza non tolgo nessuna foto da Immich.")
    }

    func testStatusActionsAndProblems() {
        XCTAssertEqual(ImmichAlignmentStatus.idle.actions, [])
        XCTAssertEqual(ImmichAlignmentStatus.running("x").actions, [])
        XCTAssertEqual(ImmichAlignmentStatus.done(ImmichAlignmentReport(), date).actions, [])
        XCTAssertEqual(ImmichAlignmentStatus.needsKey.actions, [.enterPassword])
        XCTAssertEqual(ImmichAlignmentStatus.dropGuard(missing: 1).actions, [.retry, .acceptDrop])
        XCTAssertEqual(ImmichAlignmentStatus.failed(.notReachable).actions, [.retry])
        XCTAssertFalse(ImmichAlignmentStatus.running("x").isProblem)
        XCTAssertTrue(ImmichAlignmentStatus.needsKey.isProblem)
        XCTAssertTrue(ImmichAlignmentStatus.dropGuard(missing: 1).isProblem)
        XCTAssertEqual(ImmichAlignmentStatus.running("Impilo…").line(), "Impilo…")
        XCTAssertEqual(ImmichAlignmentStatus.idle.line(), "")
    }

    func testAcceptDropConfirmationSaysTheSSDIsNotTouched() {
        let text = ImmichAlignmentText.acceptDropConfirmation(missing: 1200)
        XCTAssertTrue(text.contains("1.200"))
        XCTAssertTrue(text.contains("I file sull'SSD non vengono toccati."))
    }

    // MARK: - Log

    func testLogAppendsOneLinePerCall() throws {
        let url = tempURL("immich-alignment.log")
        ImmichAlignmentLog.append("primo", at: date, to: url)
        ImmichAlignmentLog.append("secondo", at: date, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first.map(String.init), "2026-11-13T21:41:00Z primo")
    }

    // MARK: - Stato della finestra Foto

    func testWindowState() {
        func of(installed: Bool = true, starting: Bool = false, running: Bool = false,
                pathKnown: Bool = true, mounted: Bool = true, error: String? = nil) -> ImmichWindowState {
            ImmichWindowState.of(installed: installed, isStarting: starting, isRunning: running,
                                 ssdPathKnown: pathKnown, ssdMounted: mounted, lastError: error)
        }
        XCTAssertEqual(of(installed: false, running: true), .notInstalled)
        XCTAssertEqual(of(starting: true, running: true), .starting)
        XCTAssertEqual(of(running: true, mounted: false), .ready)
        XCTAssertEqual(of(pathKnown: false), .ssdNotConfigured)
        XCTAssertEqual(of(mounted: false), .ssdNotConnected)
        XCTAssertEqual(of(error: "boom"), .stopped(error: "boom"))
        XCTAssertEqual(of(), .stopped(error: nil))
    }

    // MARK: - Avvio automatico

    func testAutoStartAction() {
        func act(installed: Bool = true, mounted: Bool = true, path: Bool = true, running: Bool = false,
                 starting: Bool = false, vm: Bool = false) -> ImmichAutoStart.Action {
            ImmichAutoStart.action(installed: installed, ssdMounted: mounted, ssdPathKnown: path,
                                   isRunning: running, isStarting: starting, vmPossiblyUp: vm)
        }
        XCTAssertEqual(act(), .start)
        XCTAssertEqual(act(vm: true), .start)                          // VM su, Immich giu': si rilancia
        XCTAssertEqual(act(running: true), .none)
        XCTAssertEqual(act(starting: true), .none)
        XCTAssertEqual(act(path: false), .none)                        // SSD mai configurato
        XCTAssertEqual(act(installed: false), .none)
        XCTAssertEqual(act(mounted: false, running: true), .stop)
        XCTAssertEqual(act(mounted: false, vm: true), .stop)
        XCTAssertEqual(act(mounted: false), .none)
        XCTAssertEqual(act(mounted: false, running: true, starting: true), .none) // mai a meta' di un avvio
    }
}
