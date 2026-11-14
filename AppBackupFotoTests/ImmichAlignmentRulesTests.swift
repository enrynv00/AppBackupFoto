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
        ]
        XCTAssertEqual(ImmichAlignmentRules.assetsToArchive(assets, alreadyArchived: ["tiny-unarchived-by-enrico"]), ["tiny"])
    }

    // MARK: - Blocchi

    func testChunksOf500() {
        let ids = (0..<1201).map(String.init)
        let chunks = ImmichAlignmentRules.chunks(ids)
        XCTAssertEqual(chunks.map(\.count), [500, 500, 201])
        XCTAssertEqual(chunks.flatMap { $0 }, ids)
        XCTAssertEqual(ImmichAlignmentRules.chunks([]), [])
    }
}
