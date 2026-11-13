# Immich sempre allineato con l'SSD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'app avvia Immich da sola con l'SSD collegato e, dopo ogni backup che scrive sull'SSD, ogni spostamento di doppioni e ogni avvio di Immich, lo riallinea all'SSD: scansione, offline tolte, foto simili impilate, minuscole archiviate.

**Architecture:** tipi puri `nonisolated` (modelli JSON, regole, testi, richieste HTTP) testati da soli; un orchestratore `ImmichAlignmentRun.run` che parla con Immich solo attraverso il protocollo `ImmichAlignmentAPI` (finto nei test, `ImmichHTTPClient` dal vivo); un coordinatore `@MainActor` `ImmichAligner` che unisce le richieste e pubblica lo stato per la finestra Foto; un coordinatore `ImmichAutoStartCoordinator` che avvia/ferma Immich seguendo `VolumeMonitor.ssdMounted`.

**Tech Stack:** Swift 5 language mode, SwiftUI, `URLSession` (configurazione `.ephemeral`), Security framework (Portachiavi), Combine, XCTest. API di Immich **v3.2.0** su `http://127.0.0.1:2283/api`.

**Spec:** `Docs/superpowers/specs/2026-11-13-immich-always-aligned-design.md` (approvata il 2026-11-13). **ADR-0021, ROADMAP #50.**

## Global Constraints

- Tutto il codice dell'app va in `AppBackupFoto/ContentView.swift` (file unico del target, vedi `Docs/CLAUDE.md`). Ogni tipo nuovo va nella sezione `// MARK: - Immich sempre allineato (ROADMAP #50, ADR-0021)`, inserita **subito prima** della riga `// MARK: - ImmichManager — ciclo di vita (Colima + Docker Compose)`. I tipi della sezione vanno in quest'ordine: modelli (Task 2), regole (Task 2), stato/testi/stato finestra (Task 3), richieste/client/chiave (Task 4), orchestratore (Task 5), coordinatore (Task 6), avvio automatico (Task 7).
- Il progetto ha `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: **ogni tipo puro va annotato `nonisolated`**, compresi i tipi annidati. Solo `ImmichAligner`, `ImmichAutoStartCoordinator` e le view restano sul main.
- L'SSD resta in sola lettura per Immich: nessun task tocca i mount `:ro` del compose né il `--mount` senza `:w` di Colima.
- Mai chiamare `POST /duplicates/resolve` né `DELETE /duplicates`. Mai salvare o scrivere nel log la password o la chiave.
- Permessi della chiave, lista chiusa: `library.read`, `library.update`, `library.statistics`, `asset.read`, `asset.update`, `asset.delete`, `duplicate.read`, `stack.create`, `stack.read`, `job.read`.
- Soglie: lato lungo minuscole **400 px**; guardia del calo **più di 500 o più del 2 %** rispetto al riferimento; blocchi da **500** ID; attesa della scansione al massimo **1.800 s**, controllo ogni **5 s**.
- File locali dell'app (mai sull'SSD): `~/Library/Application Support/AppBackupFoto/immich-alignment.json` (stato), `~/Library/Logs/AppBackupFoto/immich-alignment.log` (esito, una riga per giro). Portachiavi: servizio `AppBackupFoto`, account `immich-api-key`.
- Versione di Immich fissata: `v3.2.0`.
- Comando di test (una classe): `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -derivedDataPath "$DD" test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -25`, con `DD=/private/tmp/claude-501/-Users-enriconannivicenzi-Desktop-AppBackupFoto/69fe056f-2cbf-4503-8ee7-5b593d28e0e9/scratchpad/dd`. Build: stesso comando con `build` al posto di `test -only-testing:…`.
- **File di test nuovi** (tre), registrati a mano in `AppBackupFoto.xcodeproj/project.pbxproj` nei 4 punti — `PBXBuildFile`, `PBXFileReference`, figli del gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase` — subito dopo le righe di `S3UploadTextTests.swift` (`DC2CC96B22A4D122F6F6E4CE` / `F901D97C39FFEDA58D187B40`). ID controllati assenti il 2026-11-13:

  | File | PBXBuildFile | PBXFileReference |
  |---|---|---|
  | `ImmichAlignmentRulesTests.swift` | `C887CC0D70D973B2A07A6B4C` | `B9D204B744626C805A7F3333` |
  | `ImmichRequestsTests.swift` | `1C2B935F3FE231ADF40C7CE9` | `EC3FF8E5DB0E8DBB86A4ECAD` |
  | `ImmichAlignmentRunTests.swift` | `2BBE54C1CF781EF1E533E6DF` | `9089A3D7756DC381561BE56D` |

  Righe da aggiungere (esempio per il primo; gli altri uguali con i loro ID e nome):
  ```
  C887CC0D70D973B2A07A6B4C /* ImmichAlignmentRulesTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B9D204B744626C805A7F3333 /* ImmichAlignmentRulesTests.swift */; };
  B9D204B744626C805A7F3333 /* ImmichAlignmentRulesTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ImmichAlignmentRulesTests.swift; sourceTree = "<group>"; };
  B9D204B744626C805A7F3333 /* ImmichAlignmentRulesTests.swift */,
  C887CC0D70D973B2A07A6B4C /* ImmichAlignmentRulesTests.swift in Sources */,
  ```
- Dopo ogni task che modifica il codice: `graphify update .` (regola del `CLAUDE.md` del progetto).
- Messaggi di commit in italiano, chiusi da `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Branch: `feat/immich-always-aligned`.

---

### Task 1: versione di Immich fissata e destinazione del mount in una costante

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `ImmichManager` (costanti, vicino a `static let webUIURL`) e `composeFileContent(sourceLibraryPath:)` nell'`extension ImmichManager`
- Test: `AppBackupFotoTests/ImmichComposeFileTests.swift` (in coda alla classe)

**Interfaces:**
- Produces: `ImmichManager.immichVersion: String` (`nonisolated static let`, `"v3.2.0"`), `ImmichManager.ssdMountTarget: String` (`nonisolated static let`, `"/external-ssd"`).

- [ ] **Step 1: test che falliscono.** In coda a `ImmichComposeFileTests`, prima dell'ultima `}`:

```swift
    // MARK: - Versione fissata (ROADMAP #50, ADR-0021)

    /// `release` cambia da solo a ogni versione nuova di Immich: l'allineamento parla con l'API
    /// di Immich e va verificato su una versione precisa (v3.2.0, spec 2026-11-13 §7).
    func testImmichImagesArePinnedToTheVerifiedVersion() throws {
        let parsed = try parseYAML(yaml())
        for name in ["immich-server", "immich-machine-learning"] {
            let image = try XCTUnwrap(try service(name, in: parsed)["image"] as? String)
            XCTAssertTrue(image.hasSuffix(":\(ImmichManager.immichVersion)"), "\(name) usa \(image)")
        }
        XCTAssertEqual(ImmichManager.immichVersion, "v3.2.0")
    }

    func testNoImmichImageUsesTheFloatingReleaseTag() {
        XCTAssertFalse(yaml().contains(":release"))
    }

    /// L'allineamento riconosce la libreria dell'SSD dal suo percorso dentro il container:
    /// compose e regole devono usare la stessa costante.
    func testSSDIsMountedWhereTheAlignerLooksForIt() throws {
        let parsed = try parseYAML(yaml())
        let server = try service("immich-server", in: parsed)
        let ssd = try XCTUnwrap(mount(targeting: ImmichManager.ssdMountTarget, in: server))
        XCTAssertEqual(ssd["read_only"] as? Bool, true)
        XCTAssertEqual(ImmichManager.ssdMountTarget, "/external-ssd")
    }
```

- [ ] **Step 2: eseguili.** `… test -only-testing:AppBackupFotoTests/ImmichComposeFileTests`. Atteso: errore di compilazione, `immichVersion`/`ssdMountTarget` non esistono.

- [ ] **Step 3: implementa.** In `ImmichManager`, subito prima di `static let webUIURL`:

```swift
    /// Versione di Immich su cui l'app e' verificata (API dell'allineamento, ROADMAP #50).
    /// Fissata di proposito: con `release` un aggiornamento di Immich arriverebbe da solo e
    /// potrebbe cambiare l'API sotto i piedi dell'app. Aggiornare Immich = cambiare questo numero.
    nonisolated static let immichVersion = "v3.2.0"

    /// Dove il compose monta l'SSD dentro il container. L'allineamento riconosce la libreria
    /// dell'SSD da questo percorso (`ImmichAlignmentRules.ssdLibrary`).
    nonisolated static let ssdMountTarget = "/external-ssd"
```

In `composeFileContent(sourceLibraryPath:)` sostituisci le tre occorrenze:
- `image: ghcr.io/immich-app/immich-server:release` → `image: ghcr.io/immich-app/immich-server:\(Self.immichVersion)`
- `image: ghcr.io/immich-app/immich-machine-learning:release` → `image: ghcr.io/immich-app/immich-machine-learning:\(Self.immichVersion)`
- `target: "/external-ssd"` → `target: Self.ssdMountTarget`

- [ ] **Step 4: esegui i test.** Atteso: tutti i test di `ImmichComposeFileTests` verdi (anche i vecchi).

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichComposeFileTests.swift
git commit -m "Immich sempre allineato (#50), task 1: versione v3.2.0 fissata nel compose"
```
Nota per il collaudo: al primo avvio dopo questo task `docker compose up -d` ricrea i due container (il nome dell'immagine è cambiato). L'immagine `v3.2.0` ha lo stesso contenuto di `release` di oggi: niente da riscaricare di grosso, dati e database restano.

---

### Task 2: modelli JSON e regole pure

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — nuova sezione `// MARK: - Immich sempre allineato (ROADMAP #50, ADR-0021)` prima di `// MARK: - ImmichManager — ciclo di vita (Colima + Docker Compose)`
- Create: `AppBackupFotoTests/ImmichAlignmentRulesTests.swift` (+ pbxproj, vedi Global Constraints)

**Interfaces:**
- Consumes: `ImmichManager.ssdMountTarget` (Task 1).
- Produces: `ImmichLibrary`, `ImmichLibraryStats`, `ImmichExif`, `ImmichStackRef`, `ImmichAsset` (con `pixelWidth`/`pixelHeight`), `ImmichDuplicateGroup`, `ImmichSearchResponse` (`.assets: Page` con `items`, `nextPage`, `nextCursor`), `ImmichJobCounts`, `ImmichJobs` (`libraryIsIdle`), `ImmichLoginResponse`, `ImmichAPIKeyCreated`, `ImmichStackPlan`, `ImmichAlignmentRules` (funzioni sotto). La funzione di test `immichTestAsset(...)` (nel file di test) è usata anche dal Task 5.

- [ ] **Step 1: crea il file di test** `AppBackupFotoTests/ImmichAlignmentRulesTests.swift` e registralo nei 4 punti del pbxproj:

```swift
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
```

- [ ] **Step 2: eseguili.** `… -only-testing:AppBackupFotoTests/ImmichAlignmentRulesTests`. Atteso: errore di compilazione, i tipi non esistono.

- [ ] **Step 3: implementa.** In `ContentView.swift`, subito prima di `// MARK: - ImmichManager — ciclo di vita (Colima + Docker Compose)`:

```swift
// MARK: - Immich sempre allineato (ROADMAP #50, ADR-0021)
//
// L'app guida Immich con la sua API dopo ogni backup che scrive sull'SSD, ogni spostamento di
// doppioni e ogni avvio di Immich: scansione della libreria dell'SSD, offline tolte, foto simili
// impilate, minuscole archiviate. Tutto tocca SOLO il database di Immich: l'SSD resta montato in
// sola lettura due volte (compose `:ro` + Colima senza `:w`). Spec
// `Docs/superpowers/specs/2026-11-13-immich-always-aligned-design.md`.

// MARK: Modelli JSON (Immich v3.2.0). Solo i campi che servono: gli altri si ignorano.

nonisolated struct ImmichLibrary: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let importPaths: [String]
}

nonisolated struct ImmichLibraryStats: Decodable, Equatable, Sendable {
    let photos: Int
    let videos: Int
    let total: Int
}

nonisolated struct ImmichExif: Decodable, Equatable, Sendable {
    var exifImageWidth: Int? = nil
    var exifImageHeight: Int? = nil
    var fileSizeInByte: Int64? = nil
}

nonisolated struct ImmichStackRef: Decodable, Equatable, Sendable {
    let id: String
    let primaryAssetId: String
}

nonisolated struct ImmichAsset: Decodable, Equatable, Sendable {
    let id: String
    /// "IMAGE", "VIDEO", "AUDIO", "OTHER".
    let type: String
    var libraryId: String? = nil
    var isOffline: Bool = false
    var isTrashed: Bool = false
    /// "timeline", "archive", "hidden" (la parte video delle Live Photo), "locked".
    var visibility: String = "timeline"
    var width: Int? = nil
    var height: Int? = nil
    var exifInfo: ImmichExif? = nil
    var stack: ImmichStackRef? = nil

    var pixelWidth: Int? { exifInfo?.exifImageWidth ?? width }
    var pixelHeight: Int? { exifInfo?.exifImageHeight ?? height }
}

nonisolated struct ImmichDuplicateGroup: Decodable, Equatable, Sendable {
    let duplicateId: String
    let assets: [ImmichAsset]
}

nonisolated struct ImmichSearchResponse: Decodable, Sendable {
    nonisolated struct Page: Decodable, Sendable {
        let items: [ImmichAsset]
        var nextPage: String? = nil
        var nextCursor: String? = nil
    }
    let assets: Page
}

nonisolated struct ImmichJobCounts: Decodable, Equatable, Sendable {
    let active: Int
    let waiting: Int
    let delayed: Int
}

/// Risposta di `GET /jobs`: di tutte le code serve solo `library`, quella della scansione.
/// La coda `duplicateDetection` non si aspetta di proposito (spec §3).
nonisolated struct ImmichJobs: Decodable, Sendable {
    nonisolated struct Queue: Decodable, Sendable { let jobCounts: ImmichJobCounts }
    let library: Queue

    var libraryIsIdle: Bool {
        library.jobCounts.active + library.jobCounts.waiting + library.jobCounts.delayed == 0
    }
}

nonisolated struct ImmichLoginResponse: Decodable, Sendable { let accessToken: String }
nonisolated struct ImmichAPIKeyCreated: Decodable, Sendable { let secret: String }

nonisolated struct ImmichStackPlan: Equatable, Sendable {
    let duplicateId: String
    /// Il primo e' quello che resta davanti nella griglia.
    let assetIds: [String]
}

// MARK: Regole pure

nonisolated enum ImmichAlignmentRules {
    /// Lato lungo sotto il quale un'immagine si archivia (spec, decisione 3).
    static let tinyLongSide = 400
    /// Guardia del calo: piu' di 500 foto o piu' del 2 % in meno rispetto al riferimento
    /// fermano l'allineamento prima di togliere le offline (spec, regola 3).
    static let dropGuardAbsolute = 500
    static let dropGuardFraction = 0.02
    /// Quanti ID per richiesta di cancellazione/archiviazione.
    static let chunkSize = 500

    static func ssdLibrary(in libraries: [ImmichLibrary]) -> ImmichLibrary? {
        libraries.first { $0.importPaths.contains(ImmichManager.ssdMountTarget) }
    }

    /// Solo cio' che e' offline, gia' nel Cestino di Immich e della libreria dell'SSD: le foto
    /// cestinate a mano dentro Immich (non offline) restano dove sono (spec, regola 4).
    static func offlineToRemove(_ assets: [ImmichAsset], libraryId: String) -> [String] {
        assets.filter { $0.isOffline && $0.isTrashed && $0.libraryId == libraryId }.map(\.id)
    }

    static func dropThreshold(baseline: Int) -> Int {
        let fraction = Int((Double(max(0, baseline)) * dropGuardFraction).rounded(.down))
        return min(dropGuardAbsolute, fraction)
    }

    static func dropGuardTripped(baseline: Int, activeAfter: Int) -> Bool {
        baseline - activeAfter > dropThreshold(baseline: baseline)
    }

    private static func pixels(_ asset: ImmichAsset) -> Int? {
        guard let w = asset.pixelWidth, let h = asset.pixelHeight, w > 0, h > 0 else { return nil }
        return w * h
    }

    /// Ordine di una pila: piu' pixel; a parita' il file piu' grande; a parita' l'ID piu'
    /// piccolo (stabile). Senza dimensioni in fondo.
    static func stackOrder(_ assets: [ImmichAsset]) -> [String] {
        assets.sorted { l, r in
            let lp = pixels(l), rp = pixels(r)
            if (lp != nil) != (rp != nil) { return lp != nil }
            if let lp, let rp, lp != rp { return lp > rp }
            let ls = l.exifInfo?.fileSizeInByte ?? -1, rs = r.exifInfo?.fileSizeInByte ?? -1
            if ls != rs { return ls > rs }
            return l.id < r.id
        }.map(\.id)
    }

    /// Gruppi da impilare: mai uno gia' impilato dall'app (Enrico potrebbe averlo separato,
    /// spec regola 5), mai uno con una foto gia' in una pila (non si fondono pile altrui).
    /// Le foto cestinate o offline non entrano nella pila.
    static func groupsToStack(_ groups: [ImmichDuplicateGroup], alreadyStacked: Set<String>) -> [ImmichStackPlan] {
        groups.compactMap { group in
            guard !alreadyStacked.contains(group.duplicateId) else { return nil }
            let live = group.assets.filter { !$0.isTrashed && !$0.isOffline }
            guard live.count >= 2, live.allSatisfy({ $0.stack == nil }) else { return nil }
            return ImmichStackPlan(duplicateId: group.duplicateId, assetIds: stackOrder(live))
        }
    }

    static func isTiny(_ asset: ImmichAsset) -> Bool {
        guard asset.type == "IMAGE", let w = asset.pixelWidth, let h = asset.pixelHeight,
              w > 0, h > 0 else { return false }
        return max(w, h) < tinyLongSide
    }

    /// Minuscole ancora in griglia e mai archiviate prima dall'app: una foto che Enrico ha
    /// tolto dall'Archivio non ci torna (spec, regola 5).
    static func assetsToArchive(_ assets: [ImmichAsset], alreadyArchived: Set<String>) -> [String] {
        assets.filter { isTiny($0) && $0.visibility == "timeline" && !$0.isTrashed
                        && !alreadyArchived.contains($0.id) }.map(\.id)
    }

    static func chunks(_ ids: [String], size: Int = chunkSize) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }
}
```

- [ ] **Step 4: esegui i test.** Atteso: `ImmichAlignmentRulesTests` tutti verdi.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichAlignmentRulesTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Immich sempre allineato (#50), task 2: modelli JSON e regole pure"
```

---

### Task 3: stato salvato, testi, stato della finestra

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — stessa sezione, dopo `ImmichAlignmentRules`
- Test: `AppBackupFotoTests/ImmichAlignmentRulesTests.swift` (in coda alla classe)

**Interfaces:**
- Produces: `ImmichAlignmentState` (`archivedAssetIds: Set<String>`, `stackedDuplicateIds: Set<String>`, `healthyActiveCount: Int?`), `ImmichAlignmentStateStore.load(from:)`/`save(_:to:)`/`defaultURL`, `ImmichAlignmentReport` (`newAssets`, `offlineRemoved`, `stacksCreated`, `archived`, `scanTimedOut`), `ImmichAlignmentFailure` (`ssdNotMounted`, `libraryNotFound`, `dropGuard(missing:)`, `unauthorized`, `notReachable`, `http(Int)`, `badResponse`, `keychain`), `ImmichAlignmentReason` (`backupFinished`, `duplicatesMoved(count:)`, `immichStarted`, `keyAdded`, `manual`), `ImmichAlignmentText` (costanti e funzioni sotto), `ImmichAlignmentBarAction`, `ImmichAlignmentStatus` (`line(timeZone:)`, `isProblem`, `actions`), `ImmichAlignmentLog.append(_:at:to:)`/`line(_:at:)`/`defaultURL`, `ImmichWindowState.of(...)`.

- [ ] **Step 1: test che falliscono.** In coda a `ImmichAlignmentRulesTests`:

```swift
    // MARK: - Stato salvato

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-align-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    func testStateRoundTripsAndMissingFileIsEmpty() throws {
        let url = tempURL("immich-alignment.json")
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: url), ImmichAlignmentState())
        let state = ImmichAlignmentState(archivedAssetIds: ["a"], stackedDuplicateIds: ["d"], healthyActiveCount: 52139)
        try ImmichAlignmentStateStore.save(state, to: url)
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: url), state)
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
```

Il timestamp `1_794_606_060` è `2026-11-13T21:41:00Z`: verificalo con `date -u -r 1794606060` prima di eseguire. Se non coincide, correggi il numero nel test, non l'atteso.

- [ ] **Step 2: eseguili.** Atteso: errore di compilazione.

- [ ] **Step 3: implementa**, dopo `ImmichAlignmentRules`:

```swift
// MARK: Stato salvato sul Mac (mai sull'SSD)

/// Cio' che l'app ricorda fra un allineamento e l'altro (spec, regole 3 e 5).
nonisolated struct ImmichAlignmentState: Codable, Equatable, Sendable {
    /// Minuscole archiviate dall'app: se Enrico ne toglie una dall'Archivio, non ci torna.
    var archivedAssetIds: Set<String> = []
    /// Gruppi di simili gia' impilati dall'app: se Enrico separa una pila, non si rifa'.
    var stackedDuplicateIds: Set<String> = []
    /// Foto attive della libreria dopo l'ultimo allineamento riuscito: il riferimento della
    /// guardia del calo. Salvato anche quando la guardia scatta (spec, regola 3).
    var healthyActiveCount: Int? = nil

    enum CodingKeys: String, CodingKey { case archivedAssetIds, stackedDuplicateIds, healthyActiveCount }

    init(archivedAssetIds: Set<String> = [], stackedDuplicateIds: Set<String> = [], healthyActiveCount: Int? = nil) {
        self.archivedAssetIds = archivedAssetIds
        self.stackedDuplicateIds = stackedDuplicateIds
        self.healthyActiveCount = healthyActiveCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archivedAssetIds = try c.decodeIfPresent(Set<String>.self, forKey: .archivedAssetIds) ?? []
        stackedDuplicateIds = try c.decodeIfPresent(Set<String>.self, forKey: .stackedDuplicateIds) ?? []
        healthyActiveCount = try c.decodeIfPresent(Int.self, forKey: .healthyActiveCount)
    }
}

nonisolated enum ImmichAlignmentStateStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppBackupFoto/immich-alignment.json")
    }

    /// File assente o illeggibile = stato vuoto. Conseguenza accettata: senza riferimento la
    /// guardia del calo usa il numero prima della scansione (come al primo giro).
    static func load(from url: URL) -> ImmichAlignmentState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ImmichAlignmentState.self, from: data) else {
            return ImmichAlignmentState()
        }
        return state
    }

    static func save(_ state: ImmichAlignmentState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

// MARK: Esito, errori, motivi

nonisolated struct ImmichAlignmentReport: Equatable, Sendable {
    var newAssets = 0
    var offlineRemoved = 0
    var stacksCreated = 0
    var archived = 0
    var scanTimedOut = false
}

nonisolated enum ImmichAlignmentFailure: Error, Equatable, Sendable {
    case ssdNotMounted
    case libraryNotFound
    case dropGuard(missing: Int)
    case unauthorized
    case notReachable
    case http(Int)
    case badResponse
    case keychain
}

nonisolated enum ImmichAlignmentReason: Equatable, Sendable {
    case backupFinished
    /// Quanti file la corsa dei Doppioni ha spostato: abbassano il riferimento della guardia.
    case duplicatesMoved(count: Int)
    case immichStarted
    case keyAdded
    case manual
}

// MARK: Testi

nonisolated enum ImmichAlignmentText {
    static let scanning = "Aggiorno Immich con le foto dell'SSD…"
    static let cleaning = "Tolgo da Immich le foto che non sono più sull'SSD…"
    static let stacking = "Impilo le foto simili…"
    static let archiving = "Archivio le immagini minuscole…"
    static let needsKey = "Per aggiornare Immich da solo serve la tua password di Immich, una volta sola."

    static func number(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "it_IT"))) }

    static func time(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func done(_ r: ImmichAlignmentReport, at date: Date, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if r.newAssets > 0 { parts.append(r.newAssets == 1 ? "1 foto nuova" : "\(number(r.newAssets)) foto nuove") }
        if r.offlineRemoved > 0 {
            parts.append(r.offlineRemoved == 1 ? "1 tolta perché non più sull'SSD"
                                               : "\(number(r.offlineRemoved)) tolte perché non più sull'SSD")
        }
        if r.stacksCreated > 0 { parts.append(r.stacksCreated == 1 ? "1 pila" : "\(number(r.stacksCreated)) pile") }
        if r.archived > 0 { parts.append(r.archived == 1 ? "1 archiviata" : "\(number(r.archived)) archiviate") }
        var line = "Immich aggiornato alle \(time(date, timeZone: timeZone))"
        line += parts.isEmpty ? ": niente da cambiare." : ": " + parts.joined(separator: ", ") + "."
        if r.scanTimedOut { line += " La scansione non è finita in 30 minuti: il resto entra al prossimo giro." }
        return line
    }

    static func failure(_ f: ImmichAlignmentFailure) -> String {
        switch f {
        case .ssdNotMounted: return "Immich non aggiornato: l'SSD non è collegato."
        case .libraryNotFound: return "Immich non aggiornato: dentro Immich non trovo la libreria dell'SSD (\(ImmichManager.ssdMountTarget))."
        case .dropGuard(let missing):
            return "Immich non aggiornato: dopo la scansione mancano \(number(missing)) foto rispetto all'ultima volta. Non tolgo niente: controlla che l'SSD sia collegato bene e premi «Riprova». Le foto sono nel Cestino di Immich."
        case .unauthorized: return needsKey
        case .notReachable: return "Immich non aggiornato: Immich non risponde."
        case .http(let code): return "Immich non aggiornato: Immich ha risposto con un errore (codice \(code))."
        case .badResponse: return "Immich non aggiornato: Immich ha risposto in un modo che l'app non capisce (è ancora la versione \(ImmichManager.immichVersion)?)."
        case .keychain: return "Immich non aggiornato: non riesco a salvare la chiave nel Portachiavi."
        }
    }

    static func acceptDropConfirmation(missing: Int) -> String {
        "Dopo la scansione mancano \(number(missing)) foto rispetto all'ultima volta. Se le hai tolte tu dall'SSD, Immich le toglie anche dal suo archivio, con volti e album. I file sull'SSD non vengono toccati."
    }
}

// MARK: Stato pubblicato per la finestra Foto

nonisolated enum ImmichAlignmentBarAction: Hashable, Sendable { case retry, enterPassword, acceptDrop }

nonisolated enum ImmichAlignmentStatus: Equatable, Sendable {
    case idle
    case running(String)
    case done(ImmichAlignmentReport, Date)
    case needsKey
    case dropGuard(missing: Int)
    case failed(ImmichAlignmentFailure)

    func line(timeZone: TimeZone = .current) -> String {
        switch self {
        case .idle: return ""
        case .running(let text): return text
        case .done(let report, let date): return ImmichAlignmentText.done(report, at: date, timeZone: timeZone)
        case .needsKey: return ImmichAlignmentText.needsKey
        case .dropGuard(let missing): return ImmichAlignmentText.failure(.dropGuard(missing: missing))
        case .failed(let failure): return ImmichAlignmentText.failure(failure)
        }
    }

    var isProblem: Bool {
        switch self {
        case .needsKey, .dropGuard, .failed: return true
        case .idle, .running, .done: return false
        }
    }

    var actions: [ImmichAlignmentBarAction] {
        switch self {
        case .needsKey: return [.enterPassword]
        case .dropGuard: return [.retry, .acceptDrop]
        case .failed: return [.retry]
        case .idle, .running, .done: return []
        }
    }
}

// MARK: Log dell'allineamento (una riga per giro, mai chiave o password)

nonisolated enum ImmichAlignmentLog {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AppBackupFoto/immich-alignment.log")
    }

    static func line(_ text: String, at date: Date) -> String {
        ISO8601DateFormatter().string(from: date) + " " + text + "\n"
    }

    static func append(_ text: String, at date: Date = Date(), to url: URL) {
        let data = Data(line(text, at: date).utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: Cosa mostra la finestra Foto

nonisolated enum ImmichWindowState: Equatable, Sendable {
    case notInstalled, starting, ready, ssdNotConfigured, ssdNotConnected
    case stopped(error: String?)

    static func of(installed: Bool, isStarting: Bool, isRunning: Bool,
                   ssdPathKnown: Bool, ssdMounted: Bool, lastError: String?) -> ImmichWindowState {
        if !installed { return .notInstalled }
        if isStarting { return .starting }
        if isRunning { return .ready }
        if !ssdPathKnown { return .ssdNotConfigured }
        if !ssdMounted { return .ssdNotConnected }
        return .stopped(error: lastError)
    }
}
```

- [ ] **Step 4: esegui i test.** Atteso: `ImmichAlignmentRulesTests` verdi. Se `number(4561)` desse `4561` senza punto (raggruppamento minimo della lingua), correggi l'implementazione con `.grouping(.always)` (`n.formatted(.number.grouping(.always).locale(Locale(identifier: "it_IT")))`), non l'atteso.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichAlignmentRulesTests.swift
git commit -m "Immich sempre allineato (#50), task 3: stato salvato, testi, stato della finestra"
```

---

### Task 4: richieste HTTP, client, chiave e Portachiavi

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — stessa sezione, dopo `ImmichWindowState`
- Create: `AppBackupFotoTests/ImmichRequestsTests.swift` (+ pbxproj)

**Interfaces:**
- Consumes: modelli e `ImmichAlignmentFailure` (Task 2-3).
- Produces: `ImmichSearch` (`.offline(libraryId:)`, `.images(libraryId:)`), `ImmichPageToken` (`.cursor(String)`, `.page(Int)`), `ImmichRequests` (funzioni sotto), `ImmichKeyPermissions.granted`/`neverGranted`, `protocol ImmichAlignmentAPI`, `ImmichHTTPClient(apiKey:)` con `static func send(_:session:)`, `static func check(statusCode:)`, `static func decode(_:from:)`, `protocol ImmichKeyStore` (`load`, `save`, `delete`), `KeychainImmichKeyStore`, `ImmichKeyMaker.makeKey(email:password:send:)`.

- [ ] **Step 1: crea `AppBackupFotoTests/ImmichRequestsTests.swift`** e registralo nel pbxproj:

```swift
import XCTest
@testable import AppBackupFoto

/// Richieste verso Immich, permessi della chiave, creazione della chiave (ROADMAP #50).
final class ImmichRequestsTests: XCTestCase {

    private func json(_ r: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(r.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Indirizzo e intestazioni

    func testEveryRequestGoesToLoopbackOnly() {
        let requests = [ImmichRequests.libraries(apiKey: "K"), ImmichRequests.jobs(apiKey: "K"),
                        ImmichRequests.login(email: "e", password: "p")]
        for r in requests {
            XCTAssertEqual(r.url?.host, "127.0.0.1")
            XCTAssertEqual(r.url?.port, 2283)
            XCTAssertTrue(r.url?.path.hasPrefix("/api/") ?? false, r.url?.path ?? "")
        }
    }

    func testAPIKeyHeaderIsSetAndLoginHasNone() {
        XCTAssertEqual(ImmichRequests.libraries(apiKey: "K").value(forHTTPHeaderField: "x-api-key"), "K")
        XCTAssertNil(ImmichRequests.login(email: "e", password: "p").value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(ImmichRequests.createKey(bearer: "T").value(forHTTPHeaderField: "Authorization"), "Bearer T")
    }

    // MARK: - Metodi, percorsi, corpi

    func testScanStatisticsJobsDuplicates() {
        let scan = ImmichRequests.scan(libraryId: "L", apiKey: "K")
        XCTAssertEqual(scan.httpMethod, "POST"); XCTAssertEqual(scan.url?.path, "/api/libraries/L/scan")
        let stats = ImmichRequests.statistics(libraryId: "L", apiKey: "K")
        XCTAssertEqual(stats.httpMethod, "GET"); XCTAssertEqual(stats.url?.path, "/api/libraries/L/statistics")
        XCTAssertEqual(ImmichRequests.jobs(apiKey: "K").url?.path, "/api/jobs")
        XCTAssertEqual(ImmichRequests.duplicates(apiKey: "K").url?.path, "/api/duplicates")
        XCTAssertEqual(ImmichRequests.duplicates(apiKey: "K").httpMethod, "GET")
    }

    func testDeleteAssetsIsForcedAndOnlyForTheGivenIDs() throws {
        let r = ImmichRequests.deleteAssets(ids: ["a", "b"], apiKey: "K")
        XCTAssertEqual(r.httpMethod, "DELETE"); XCTAssertEqual(r.url?.path, "/api/assets")
        let body = try json(r)
        XCTAssertEqual(body["ids"] as? [String], ["a", "b"])
        XCTAssertEqual(body["force"] as? Bool, true)
    }

    func testCreateStackAndArchive() throws {
        let stack = ImmichRequests.createStack(assetIds: ["p", "q"], apiKey: "K")
        XCTAssertEqual(stack.httpMethod, "POST"); XCTAssertEqual(stack.url?.path, "/api/stacks")
        XCTAssertEqual(try json(stack)["assetIds"] as? [String], ["p", "q"])
        let archive = ImmichRequests.archive(ids: ["t"], apiKey: "K")
        XCTAssertEqual(archive.httpMethod, "PUT"); XCTAssertEqual(archive.url?.path, "/api/assets")
        XCTAssertEqual(try json(archive)["ids"] as? [String], ["t"])
        XCTAssertEqual(try json(archive)["visibility"] as? String, "archive")
    }

    func testSearchBodies() throws {
        let offline = try json(ImmichRequests.search(.offline(libraryId: "L"), token: nil, apiKey: "K"))
        XCTAssertEqual(offline["libraryId"] as? String, "L")
        XCTAssertEqual(offline["isOffline"] as? Bool, true)
        XCTAssertEqual(offline["withDeleted"] as? Bool, true)
        XCTAssertEqual(offline["size"] as? Int, 1000)
        XCTAssertNil(offline["cursor"]); XCTAssertNil(offline["page"])

        let images = try json(ImmichRequests.search(.images(libraryId: "L"), token: .cursor("C"), apiKey: "K"))
        XCTAssertEqual(images["type"] as? String, "IMAGE")
        XCTAssertEqual(images["visibility"] as? String, "timeline")
        XCTAssertEqual(images["withExif"] as? Bool, true)
        XCTAssertEqual(images["cursor"] as? String, "C")

        let paged = try json(ImmichRequests.search(.images(libraryId: "L"), token: .page(3), apiKey: "K"))
        XCTAssertEqual(paged["page"] as? Int, 3)
        XCTAssertEqual(ImmichRequests.search(.offline(libraryId: "L"), token: nil, apiKey: "K").url?.path, "/api/search/metadata")
    }

    func testNextTokenPrefersCursorThenPage() {
        typealias P = ImmichSearchResponse.Page
        XCTAssertEqual(ImmichRequests.nextToken(after: P(items: [], nextPage: "2", nextCursor: "C")), .cursor("C"))
        XCTAssertEqual(ImmichRequests.nextToken(after: P(items: [], nextPage: "2", nextCursor: nil)), .page(2))
        XCTAssertEqual(ImmichRequests.nextToken(after: P(items: [], nextPage: "2", nextCursor: "")), .page(2))
        XCTAssertNil(ImmichRequests.nextToken(after: P(items: [], nextPage: nil, nextCursor: nil)))
    }

    // MARK: - Permessi della chiave

    func testKeyAsksExactlyTheGrantedPermissions() throws {
        let body = try json(ImmichRequests.createKey(bearer: "T"))
        XCTAssertEqual(body["permissions"] as? [String], ImmichKeyPermissions.granted)
        XCTAssertEqual(body["name"] as? String, "AppBackupFoto — allineamento")
        XCTAssertEqual(Set(ImmichKeyPermissions.granted), [
            "library.read", "library.update", "library.statistics", "asset.read", "asset.update",
            "asset.delete", "duplicate.read", "stack.create", "stack.read", "job.read"])
    }

    func testKeyNeverGetsDangerousPermissions() {
        XCTAssertTrue(Set(ImmichKeyPermissions.granted).isDisjoint(with: ImmichKeyPermissions.neverGranted))
        XCTAssertTrue(ImmichKeyPermissions.neverGranted.contains("all"))
        XCTAssertTrue(ImmichKeyPermissions.neverGranted.contains("duplicate.delete"))
        XCTAssertTrue(ImmichKeyPermissions.neverGranted.contains("library.delete"))
    }

    // MARK: - Codici di risposta

    func testStatusCodes() {
        XCTAssertNoThrow(try ImmichHTTPClient.check(statusCode: 200))
        XCTAssertNoThrow(try ImmichHTTPClient.check(statusCode: 204))
        XCTAssertThrowsError(try ImmichHTTPClient.check(statusCode: 401)) { XCTAssertEqual($0 as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertThrowsError(try ImmichHTTPClient.check(statusCode: 403)) { XCTAssertEqual($0 as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertThrowsError(try ImmichHTTPClient.check(statusCode: 400)) { XCTAssertEqual($0 as? ImmichAlignmentFailure, .http(400)) }
        XCTAssertThrowsError(try ImmichHTTPClient.check(statusCode: 0)) { XCTAssertEqual($0 as? ImmichAlignmentFailure, .http(0)) }
    }

    func testBadJSONIsBadResponse() {
        XCTAssertThrowsError(try ImmichHTTPClient.decode(ImmichLibraryStats.self, from: Data("{}".utf8))) {
            XCTAssertEqual($0 as? ImmichAlignmentFailure, .badResponse)
        }
    }

    // MARK: - Creazione della chiave

    private final class Recorder: @unchecked Sendable {
        var paths: [String] = []
        var failCreate = false
        var failLogin = false
    }

    private func send(_ rec: Recorder) -> @Sendable (URLRequest) async throws -> Data {
        { request in
            let path = request.url?.path ?? ""
            rec.paths.append(path)
            switch path {
            case "/api/auth/login":
                if rec.failLogin { throw ImmichAlignmentFailure.unauthorized }
                return Data(#"{"accessToken":"TOKEN"}"#.utf8)
            case "/api/api-keys":
                if rec.failCreate { throw ImmichAlignmentFailure.http(400) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
                return Data(#"{"secret":"CHIAVE"}"#.utf8)
            default:
                return Data("{}".utf8)
            }
        }
    }

    func testMakeKeyLogsInCreatesTheKeyAndLogsOut() async throws {
        let rec = Recorder()
        let key = try await ImmichKeyMaker.makeKey(email: "e@x", password: "pw", send: send(rec))
        XCTAssertEqual(key, "CHIAVE")
        XCTAssertEqual(rec.paths, ["/api/auth/login", "/api/api-keys", "/api/auth/logout"])
    }

    func testMakeKeyLogsOutEvenWhenCreationFails() async {
        let rec = Recorder(); rec.failCreate = true
        do { _ = try await ImmichKeyMaker.makeKey(email: "e", password: "p", send: send(rec)); XCTFail("doveva fallire") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .http(400)) }
        XCTAssertEqual(rec.paths, ["/api/auth/login", "/api/api-keys", "/api/auth/logout"])
    }

    func testWrongPasswordStopsAtLogin() async {
        let rec = Recorder(); rec.failLogin = true
        do { _ = try await ImmichKeyMaker.makeKey(email: "e", password: "p", send: send(rec)); XCTFail("doveva fallire") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .unauthorized) }
        XCTAssertEqual(rec.paths, ["/api/auth/login"])
    }

    func testLoginBodyCarriesTheCredentials() throws {
        let body = try json(ImmichRequests.login(email: "e@x", password: "pw"))
        XCTAssertEqual(body["email"] as? String, "e@x")
        XCTAssertEqual(body["password"] as? String, "pw")
    }

    // MARK: - Portachiavi

    func testKeychainCoordinates() {
        XCTAssertEqual(KeychainImmichKeyStore.service, "AppBackupFoto")
        XCTAssertEqual(KeychainImmichKeyStore.account, "immich-api-key")
    }
}
```

Nessun test scrive nel Portachiavi vero: `KeychainImmichKeyStore` si prova dal vivo (Task 10).

- [ ] **Step 2: eseguili.** `… -only-testing:AppBackupFotoTests/ImmichRequestsTests`. Atteso: errore di compilazione.

- [ ] **Step 3: implementa**, dopo `ImmichWindowState`:

```swift
// MARK: Richieste verso Immich (pure, testabili)

nonisolated enum ImmichSearch: Equatable, Sendable {
    case offline(libraryId: String)
    case images(libraryId: String)
}

nonisolated enum ImmichPageToken: Equatable, Sendable {
    case cursor(String)
    case page(Int)
}

nonisolated enum ImmichRequests {
    /// Solo loopback: lo stesso indirizzo di `ImmichManager.webUIURL`, con il prefisso `/api`.
    static let apiBase = URL(string: "http://127.0.0.1:2283/api")!
    static let pageSize = 1000

    static func make(_ method: String, _ path: String, apiKey: String? = nil, bearer: String? = nil,
                     json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return request
    }

    static func libraries(apiKey: String) -> URLRequest { make("GET", "libraries", apiKey: apiKey) }
    static func statistics(libraryId: String, apiKey: String) -> URLRequest { make("GET", "libraries/\(libraryId)/statistics", apiKey: apiKey) }
    static func scan(libraryId: String, apiKey: String) -> URLRequest { make("POST", "libraries/\(libraryId)/scan", apiKey: apiKey) }
    static func jobs(apiKey: String) -> URLRequest { make("GET", "jobs", apiKey: apiKey) }
    static func duplicates(apiKey: String) -> URLRequest { make("GET", "duplicates", apiKey: apiKey) }

    static func search(_ search: ImmichSearch, token: ImmichPageToken?, apiKey: String) -> URLRequest {
        var body: [String: Any]
        switch search {
        case .offline(let id):
            body = ["libraryId": id, "isOffline": true, "withDeleted": true, "size": pageSize]
        case .images(let id):
            body = ["libraryId": id, "type": "IMAGE", "visibility": "timeline", "withExif": true, "size": pageSize]
        }
        switch token {
        case .cursor(let c): body["cursor"] = c
        case .page(let p): body["page"] = p
        case nil: break
        }
        return make("POST", "search/metadata", apiKey: apiKey, json: body)
    }

    /// `page` e' deprecato in v3.2.0 ma ancora presente: si usa il cursore quando c'e'.
    static func nextToken(after page: ImmichSearchResponse.Page) -> ImmichPageToken? {
        if let cursor = page.nextCursor, !cursor.isEmpty { return .cursor(cursor) }
        if let next = page.nextPage, let number = Int(next) { return .page(number) }
        return nil
    }

    /// Toglie dal database di Immich. I file sull'SSD restano: e' montato in sola lettura.
    static func deleteAssets(ids: [String], apiKey: String) -> URLRequest {
        make("DELETE", "assets", apiKey: apiKey, json: ["ids": ids, "force": true])
    }

    static func createStack(assetIds: [String], apiKey: String) -> URLRequest {
        make("POST", "stacks", apiKey: apiKey, json: ["assetIds": assetIds])
    }

    /// `PUT /assets` e' segnato «Deprecated» in v3.2.0 ma e' l'unico modo di cambiare la
    /// visibilita' di piu' foto insieme: funziona sulla versione fissata (Task 10 lo verifica).
    static func archive(ids: [String], apiKey: String) -> URLRequest {
        make("PUT", "assets", apiKey: apiKey, json: ["ids": ids, "visibility": "archive"])
    }

    static func login(email: String, password: String) -> URLRequest {
        make("POST", "auth/login", json: ["email": email, "password": password])
    }

    static func createKey(bearer: String) -> URLRequest {
        make("POST", "api-keys", bearer: bearer,
             json: ["name": ImmichKeyMaker.keyName, "permissions": ImmichKeyPermissions.granted])
    }

    static func logout(bearer: String) -> URLRequest { make("POST", "auth/logout", bearer: bearer) }
}

nonisolated enum ImmichKeyPermissions {
    /// Lista chiusa (spec §2). `asset.delete` serve per togliere le offline e tocca solo il
    /// database di Immich.
    static let granted = ["library.read", "library.update", "library.statistics", "asset.read",
                          "asset.update", "asset.delete", "duplicate.read", "stack.create",
                          "stack.read", "job.read"]
    /// Mai, per nessun motivo: blindato da un test.
    static let neverGranted: Set<String> = ["all", "library.create", "library.delete", "duplicate.delete",
                                            "stack.update", "stack.delete", "apiKey.create", "apiKey.update",
                                            "apiKey.delete", "user.delete", "adminUser.delete",
                                            "asset.upload", "asset.download", "systemConfig.update"]
}

// MARK: Client verso Immich

nonisolated protocol ImmichAlignmentAPI: Sendable {
    func libraries() async throws -> [ImmichLibrary]
    func statistics(libraryId: String) async throws -> ImmichLibraryStats
    func scan(libraryId: String) async throws
    func jobs() async throws -> ImmichJobs
    func searchAll(_ search: ImmichSearch) async throws -> [ImmichAsset]
    func deleteAssets(ids: [String]) async throws
    func duplicates() async throws -> [ImmichDuplicateGroup]
    func createStack(assetIds: [String]) async throws
    func archive(ids: [String]) async throws
}

nonisolated struct ImmichHTTPClient: ImmichAlignmentAPI {
    let apiKey: String
    /// `.ephemeral`: nessun cookie o cache su disco (il login della chiave lascia un cookie).
    var session: URLSession = URLSession(configuration: .ephemeral)
    /// Tetto di sicurezza alle pagine di una ricerca (1.000 x 1.000 foto).
    static let maxPages = 1000

    static func check(statusCode: Int) throws {
        if statusCode == 401 || statusCode == 403 { throw ImmichAlignmentFailure.unauthorized }
        guard (200..<300).contains(statusCode) else { throw ImmichAlignmentFailure.http(statusCode) }
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ImmichAlignmentFailure.notReachable }
        try check(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ImmichAlignmentFailure.badResponse }
    }

    private func fetch<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        try Self.decode(type, from: try await Self.send(request, session: session))
    }

    private func perform(_ request: URLRequest) async throws {
        _ = try await Self.send(request, session: session)
    }

    func libraries() async throws -> [ImmichLibrary] { try await fetch(ImmichRequests.libraries(apiKey: apiKey), as: [ImmichLibrary].self) }
    func statistics(libraryId: String) async throws -> ImmichLibraryStats { try await fetch(ImmichRequests.statistics(libraryId: libraryId, apiKey: apiKey), as: ImmichLibraryStats.self) }
    func scan(libraryId: String) async throws { try await perform(ImmichRequests.scan(libraryId: libraryId, apiKey: apiKey)) }
    func jobs() async throws -> ImmichJobs { try await fetch(ImmichRequests.jobs(apiKey: apiKey), as: ImmichJobs.self) }
    func deleteAssets(ids: [String]) async throws { try await perform(ImmichRequests.deleteAssets(ids: ids, apiKey: apiKey)) }
    func duplicates() async throws -> [ImmichDuplicateGroup] { try await fetch(ImmichRequests.duplicates(apiKey: apiKey), as: [ImmichDuplicateGroup].self) }
    func createStack(assetIds: [String]) async throws { try await perform(ImmichRequests.createStack(assetIds: assetIds, apiKey: apiKey)) }
    func archive(ids: [String]) async throws { try await perform(ImmichRequests.archive(ids: ids, apiKey: apiKey)) }

    func searchAll(_ search: ImmichSearch) async throws -> [ImmichAsset] {
        var all: [ImmichAsset] = []
        var token: ImmichPageToken? = nil
        for _ in 0..<Self.maxPages {
            let page = try await fetch(ImmichRequests.search(search, token: token, apiKey: apiKey),
                                       as: ImmichSearchResponse.self).assets
            all += page.items
            guard let next = ImmichRequests.nextToken(after: page) else { return all }
            token = next
        }
        return all
    }
}

// MARK: Chiave API nel Portachiavi

nonisolated protocol ImmichKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String) throws
    func delete()
}

/// Stesso schema delle credenziali di Cubbit (`S3Syncer.writeToKeychain`): servizio
/// `AppBackupFoto`, un account per credenziale.
nonisolated struct KeychainImmichKeyStore: ImmichKeyStore {
    static let service = "AppBackupFoto"
    static let account = "immich-api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ImmichAlignmentFailure.keychain }
        } else if status != errSecSuccess {
            throw ImmichAlignmentFailure.keychain
        }
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}

/// Crea la chiave una volta sola con email e password di Immich. La password vive solo nel
/// corpo della richiesta di login: non si salva, non si scrive nel log.
nonisolated enum ImmichKeyMaker {
    static let keyName = "AppBackupFoto — allineamento"

    static func makeKey(email: String, password: String,
                        send: @Sendable (URLRequest) async throws -> Data) async throws -> String {
        let login = try ImmichHTTPClient.decode(ImmichLoginResponse.self,
            from: try await send(ImmichRequests.login(email: email, password: password)))
        do {
            let created = try ImmichHTTPClient.decode(ImmichAPIKeyCreated.self,
                from: try await send(ImmichRequests.createKey(bearer: login.accessToken)))
            _ = try? await send(ImmichRequests.logout(bearer: login.accessToken))
            return created.secret
        } catch {
            _ = try? await send(ImmichRequests.logout(bearer: login.accessToken))
            throw error
        }
    }
}
```

- [ ] **Step 4: esegui i test.** Atteso: `ImmichRequestsTests` verdi.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichRequestsTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Immich sempre allineato (#50), task 4: richieste, client, chiave nel Portachiavi"
```

---

### Task 5: l'allineamento (orchestratore)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — stessa sezione, dopo `ImmichKeyMaker`
- Create: `AppBackupFotoTests/ImmichAlignmentRunTests.swift` (+ pbxproj)

**Interfaces:**
- Consumes: tutto quanto sopra; `immichTestAsset(...)` dal file di test del Task 2.
- Produces: `ImmichAlignmentRun.Environment` (campi `ssdMounted`, `sleep`, `now`, `scanWaitLimit`, `pollInterval`, `saveState`, `progress`), `ImmichAlignmentRun.run(api:state:allowance:acceptDrop:env:) async throws -> (ImmichAlignmentReport, ImmichAlignmentState)`. Nel file di test: `FakeImmichAPI`, `TestClock`, `MountedSequence`, `SavedStates` (usati anche dal Task 6).

- [ ] **Step 1: crea `AppBackupFotoTests/ImmichAlignmentRunTests.swift`** e registralo nel pbxproj:

```swift
import XCTest
@testable import AppBackupFoto

// MARK: - Doppi di prova (interni: li usa anche ImmichAlignerTests nello stesso file)

final class FakeImmichAPI: ImmichAlignmentAPI, @unchecked Sendable {
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

final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
final class MountedSequence: @unchecked Sendable {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> Bool { values.count > 1 ? values.removeFirst() : (values.first ?? true) }
}
final class SavedStates: @unchecked Sendable { var all: [ImmichAlignmentState] = [] }

func immichTestEnv(mounted: MountedSequence = MountedSequence([true]), clock: TestClock = TestClock(),
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
```

- [ ] **Step 2: eseguili.** `… -only-testing:AppBackupFotoTests/ImmichAlignmentRunTests`. Atteso: errore di compilazione.

- [ ] **Step 3: implementa**, dopo `ImmichKeyMaker`:

```swift
// MARK: L'allineamento

nonisolated enum ImmichAlignmentRun {
    nonisolated struct Environment: Sendable {
        var ssdMounted: @Sendable () async -> Bool
        var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        var now: @Sendable () -> Date = { Date() }
        var scanWaitLimit: TimeInterval = 1800
        var pollInterval: TimeInterval = 5
        var saveState: @Sendable (ImmichAlignmentState) -> Void = { _ in }
        var progress: @Sendable (String) async -> Void = { _ in }
    }

    /// Un giro completo (spec §5). Lancia `ImmichAlignmentFailure`; lo stato viene salvato con
    /// `env.saveState` a ogni passo che lo cambia, cosi' un errore a meta' non perde quanto fatto.
    ///
    /// - Parameters:
    ///   - allowance: file che l'app stessa ha spostato dall'SSD (Doppioni) dall'ultimo giro.
    ///   - acceptDrop: Enrico ha confermato «Togli comunque»: la guardia del calo non si applica.
    static func run(api: any ImmichAlignmentAPI, state start: ImmichAlignmentState,
                    allowance: Int, acceptDrop: Bool, env: Environment) async throws
        -> (ImmichAlignmentReport, ImmichAlignmentState) {
        var state = start
        var report = ImmichAlignmentReport()

        guard let library = ImmichAlignmentRules.ssdLibrary(in: try await api.libraries()) else {
            throw ImmichAlignmentFailure.libraryNotFound
        }
        let before = try await api.statistics(libraryId: library.id).total
        let baseline = max(0, (state.healthyActiveCount ?? before) - max(0, allowance))

        // Regola 3, prima guardia: mai una scansione con l'SSD staccato.
        guard await env.ssdMounted() else { throw ImmichAlignmentFailure.ssdNotMounted }
        await env.progress(ImmichAlignmentText.scanning)
        try await api.scan(libraryId: library.id)

        let started = env.now()
        await env.sleep(env.pollInterval)
        while !(try await api.jobs().libraryIsIdle) {
            if env.now().timeIntervalSince(started) >= env.scanWaitLimit {
                report.scanTimedOut = true
                break
            }
            await env.sleep(env.pollInterval)
        }

        let after = try await api.statistics(libraryId: library.id).total
        report.newAssets = max(0, after - before)

        // Regola 3, seconda guardia: il riferimento si salva anche quando scatta, cosi' un
        // «Riprova» su un SSD ancora vuoto nella VM scatta di nuovo.
        if !acceptDrop && ImmichAlignmentRules.dropGuardTripped(baseline: baseline, activeAfter: after) {
            state.healthyActiveCount = baseline
            env.saveState(state)
            throw ImmichAlignmentFailure.dropGuard(missing: baseline - after)
        }
        guard await env.ssdMounted() else { throw ImmichAlignmentFailure.ssdNotMounted }

        await env.progress(ImmichAlignmentText.cleaning)
        let offline = ImmichAlignmentRules.offlineToRemove(try await api.searchAll(.offline(libraryId: library.id)),
                                                           libraryId: library.id)
        for chunk in ImmichAlignmentRules.chunks(offline) {
            try await api.deleteAssets(ids: chunk)
            report.offlineRemoved += chunk.count
        }
        state.healthyActiveCount = after
        env.saveState(state)

        await env.progress(ImmichAlignmentText.stacking)
        for plan in ImmichAlignmentRules.groupsToStack(try await api.duplicates(),
                                                       alreadyStacked: state.stackedDuplicateIds) {
            do {
                try await api.createStack(assetIds: plan.assetIds)
                report.stacksCreated += 1
                state.stackedDuplicateIds.insert(plan.duplicateId)
            } catch ImmichAlignmentFailure.http(let code) where (400..<500).contains(code) {
                // Una pila rifiutata (foto impilata nel frattempo, gruppo cambiato) non ferma
                // le altre e non si ricorda: si riprova al prossimo giro.
                continue
            }
        }
        env.saveState(state)

        await env.progress(ImmichAlignmentText.archiving)
        let tiny = ImmichAlignmentRules.assetsToArchive(try await api.searchAll(.images(libraryId: library.id)),
                                                        alreadyArchived: state.archivedAssetIds)
        for chunk in ImmichAlignmentRules.chunks(tiny) {
            try await api.archive(ids: chunk)
            report.archived += chunk.count
            state.archivedAssetIds.formUnion(chunk)
        }
        env.saveState(state)
        return (report, state)
    }
}
```

- [ ] **Step 4: esegui i test.** Atteso: `ImmichAlignmentRunTests` verdi.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichAlignmentRunTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Immich sempre allineato (#50), task 5: l'allineamento con le due guardie sull'SSD"
```

---

### Task 6: il coordinatore `ImmichAligner`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — stessa sezione, dopo `ImmichAlignmentRun`
- Test: `AppBackupFotoTests/ImmichAlignmentRunTests.swift` (nuova classe `ImmichAlignerTests` in coda al file)

**Interfaces:**
- Consumes: `ImmichAlignmentRun`, `ImmichKeyStore`, `ImmichAlignmentStateStore`, `ImmichAlignmentLog`, `ImmichAlignmentStatus`, `FakeImmichAPI`/`immichTestEnv` (test).
- Produces: `final class ImmichAligner: ObservableObject` (`@MainActor` per default), `static let shared`, `init()`, `@Published private(set) var status: ImmichAlignmentStatus`, `private(set) var currentTask: Task<Void, Never>?`, `func request(_ reason: ImmichAlignmentReason)`, `func acceptDropAndRetry()`, proprietà iniettabili `keyStore`, `makeAPI`, `isImmichRunning`, `ssdMounted`, `stateURL`, `logURL`, `scanWaitLimit`, `pollInterval`, `sleep`.

- [ ] **Step 1: test che falliscono.** In coda a `ImmichAlignmentRunTests.swift`:

```swift
// MARK: - Coordinatore

final class MemoryKeyStore: ImmichKeyStore, @unchecked Sendable {
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
        aligner.acceptDropAndRetry()
        await aligner.currentTask?.value
        guard case .done = aligner.status else { return XCTFail("stato \(aligner.status)") }
        XCTAssertEqual(ImmichAlignmentStateStore.load(from: stateURL).healthyActiveCount, 40000)
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
```

- [ ] **Step 2: eseguili.** `… -only-testing:AppBackupFotoTests/ImmichAlignerTests`. Atteso: errore di compilazione.

- [ ] **Step 3: implementa**, dopo `ImmichAlignmentRun`:

```swift
// MARK: Coordinatore (main actor): unisce le richieste, pubblica lo stato

/// Un solo allineamento alla volta; le richieste che arrivano nel frattempo si riducono a
/// UN giro in piu' alla fine (spec §5). Se Immich e' spento la richiesta si lascia cadere:
/// il prossimo avvio di Immich allinea comunque (`ImmichManager.start`). Fanno eccezione i
/// file spostati dai Doppioni, che si sommano comunque al margine della guardia.
final class ImmichAligner: ObservableObject {
    static let shared = ImmichAligner()

    @Published private(set) var status: ImmichAlignmentStatus = .idle
    private(set) var currentTask: Task<Void, Never>?
    private var rerunRequested = false
    private var pendingAllowance = 0
    private var acceptDropOnce = false

    // Iniettabili per i test.
    var keyStore: any ImmichKeyStore = KeychainImmichKeyStore()
    var makeAPI: (String) -> any ImmichAlignmentAPI = { ImmichHTTPClient(apiKey: $0) }
    var isImmichRunning: () -> Bool = { ImmichManager.shared.isRunning }
    var ssdMounted: @MainActor @Sendable () -> Bool = { VolumeMonitor.shared.ssdMounted }
    var stateURL: URL = ImmichAlignmentStateStore.defaultURL
    var logURL: URL? = ImmichAlignmentLog.defaultURL
    var scanWaitLimit: TimeInterval = 1800
    var pollInterval: TimeInterval = 5
    var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    init() {}

    func request(_ reason: ImmichAlignmentReason) {
        if case .duplicatesMoved(let count) = reason { pendingAllowance += max(0, count) }
        guard isImmichRunning() else { return }
        if currentTask != nil { rerunRequested = true; return }
        currentTask = Task { await self.loop() }
    }

    /// «Togli comunque», dopo la conferma della finestra Foto.
    func acceptDropAndRetry() {
        acceptDropOnce = true
        request(.manual)
    }

    private func loop() async {
        repeat {
            rerunRequested = false
            await runOnce()
        } while rerunRequested
        currentTask = nil
    }

    private func runOnce() async {
        guard let key = keyStore.load() else { status = .needsKey; return }
        let api = makeAPI(key)
        let allowance = pendingAllowance
        pendingAllowance = 0
        let acceptDrop = acceptDropOnce
        acceptDropOnce = false
        let stateURL = self.stateURL
        let mounted = self.ssdMounted
        let state = ImmichAlignmentStateStore.load(from: stateURL)
        status = .running(ImmichAlignmentText.scanning)

        let env = ImmichAlignmentRun.Environment(
            ssdMounted: { await mounted() },
            sleep: sleep,
            scanWaitLimit: scanWaitLimit,
            pollInterval: pollInterval,
            saveState: { try? ImmichAlignmentStateStore.save($0, to: stateURL) },
            progress: { [weak self] line in await MainActor.run { self?.status = .running(line) } })

        do {
            let (report, _) = try await ImmichAlignmentRun.run(api: api, state: state, allowance: allowance,
                                                               acceptDrop: acceptDrop, env: env)
            let now = Date()
            status = .done(report, now)
            log(ImmichAlignmentText.done(report, at: now))
        } catch {
            let failure = (error as? ImmichAlignmentFailure) ?? .notReachable
            switch failure {
            case .unauthorized:
                keyStore.delete()
                status = .needsKey
            case .dropGuard(let missing):
                status = .dropGuard(missing: missing)
            default:
                // Il margine dei Doppioni non e' stato usato: resta per il prossimo giro.
                pendingAllowance += allowance
                status = .failed(failure)
            }
            log(ImmichAlignmentText.failure(failure))
        }
    }

    private func log(_ text: String) {
        guard let url = logURL else { return }
        Task.detached { ImmichAlignmentLog.append(text, to: url) }
    }
}
```

- [ ] **Step 4: esegui i test.** `… -only-testing:AppBackupFotoTests/ImmichAlignerTests` e `… /ImmichAlignmentRunTests`. Atteso: tutti verdi.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichAlignmentRunTests.swift
git commit -m "Immich sempre allineato (#50), task 6: coordinatore che unisce le richieste"
```

---

### Task 7: avvio e arresto automatici

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — stessa sezione (dopo `ImmichAligner`); `AppDelegate` (nuovo `applicationDidFinishLaunching`); `ImmichManager.start(sourceLibraryPath:)` (ramo di successo); `ImmichSetupPromptView` (dopo `install()`)
- Test: `AppBackupFotoTests/ImmichAlignmentRulesTests.swift` (in coda)

**Interfaces:**
- Consumes: `ImmichManager` (`detectInstalled`, `detectRunning`, `start`, `stop`, `isRunning`, `isStarting`, `vmPossiblyUp`), `VolumeMonitor.shared.$ssdMounted`, `BookmarkManager.shared.urls[.ssd]`, `ImmichAligner.shared.request(_:)`.
- Produces: `ImmichAutoStart.action(installed:ssdMounted:ssdPathKnown:isRunning:isStarting:vmPossiblyUp:) -> ImmichAutoStart.Action` (`.start`, `.stop`, `.none`), `final class ImmichAutoStartCoordinator` con `static let shared`, `func begin()`, `func react() async`.

- [ ] **Step 1: test che falliscono.** In coda a `ImmichAlignmentRulesTests`:

```swift
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
```

- [ ] **Step 2: eseguili.** Atteso: errore di compilazione.

- [ ] **Step 3: implementa la parte pura e il coordinatore**, dopo `ImmichAligner`:

```swift
// MARK: Avvio e arresto automatici (spec §1)

nonisolated enum ImmichAutoStart {
    nonisolated enum Action: Equatable, Sendable { case start, stop, none }

    /// Con l'SSD collegato Immich deve essere acceso; senza, spento. Mai a meta' di un avvio:
    /// fermare un `colima start` in corso lascerebbe la VM in uno stato incerto.
    static func action(installed: Bool, ssdMounted: Bool, ssdPathKnown: Bool,
                       isRunning: Bool, isStarting: Bool, vmPossiblyUp: Bool) -> Action {
        guard installed, !isStarting else { return .none }
        if ssdMounted { return (ssdPathKnown && !isRunning) ? .start : .none }
        return (isRunning || vmPossiblyUp) ? .stop : .none
    }
}

/// Segue `VolumeMonitor.ssdMounted`: SSD collegato → Immich acceso, scollegato → spento.
/// Avviato una volta sola da `AppDelegate.applicationDidFinishLaunching`.
final class ImmichAutoStartCoordinator {
    static let shared = ImmichAutoStartCoordinator()
    private var cancellable: AnyCancellable?

    func begin() {
        guard cancellable == nil else { return }
        cancellable = VolumeMonitor.shared.$ssdMounted
            .removeDuplicates()
            .sink { _ in Task { await ImmichAutoStartCoordinator.shared.react() } }
    }

    /// Legge lo stato di adesso (non quello di quando e' stato chiamato) e agisce.
    func react() async {
        let immich = ImmichManager.shared
        guard immich.detectInstalled() else { return }
        await immich.detectRunning()
        let path = BookmarkManager.shared.urls[.ssd]?.path
        let action = ImmichAutoStart.action(installed: true,
                                            ssdMounted: VolumeMonitor.shared.ssdMounted,
                                            ssdPathKnown: path != nil,
                                            isRunning: immich.isRunning,
                                            isStarting: immich.isStarting,
                                            vmPossiblyUp: immich.vmPossiblyUp)
        switch action {
        case .start:
            guard let path else { return }
            try? await immich.start(sourceLibraryPath: path)
            // L'SSD puo' essere sparito durante l'avvio (minuti): il segnale di allora non
            // ha fermato niente perche' l'avvio era in corso, quindi si ricontrolla qui.
            if !VolumeMonitor.shared.ssdMounted { await react() }
        case .stop:
            await immich.stop()
        case .none:
            break
        }
    }
}
```

- [ ] **Step 4: cablaggio.**

In `AppDelegate`, prima di `func applicationShouldTerminate`:

```swift
    /// Immich parte da solo con l'SSD collegato e si ferma quando lo si scollega (ROADMAP #50).
    func applicationDidFinishLaunching(_ notification: Notification) {
        ImmichAutoStartCoordinator.shared.begin()
    }
```

In `ImmichManager.start(sourceLibraryPath:)`, nel ciclo di health check, sostituisci:

```swift
                if await healthCheck() {
                    await MainActor.run { self.isRunning = true }
                    return
                }
```
con:
```swift
                if await healthCheck() {
                    await MainActor.run {
                        self.isRunning = true
                        // Ogni avvio riallinea Immich all'SSD (spec, decisione 2).
                        ImmichAligner.shared.request(.immichStarted)
                    }
                    return
                }
```

In `ImmichSetupPromptView`, nel bottone «Installa», sostituisci:
```swift
                    Task {
                        try? await immich.install()
                        await MainActor.run { isInstalling = false }
                    }
```
con:
```swift
                    Task {
                        try? await immich.install()
                        await MainActor.run { isInstalling = false }
                        // Appena installato parte da solo, se l'SSD e' collegato.
                        await ImmichAutoStartCoordinator.shared.react()
                    }
```

- [ ] **Step 5: test e build.** `… -only-testing:AppBackupFotoTests/ImmichAlignmentRulesTests` verde; poi build completo: `BUILD SUCCEEDED`.

- [ ] **Step 6: commit.**
```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImmichAlignmentRulesTests.swift
git commit -m "Immich sempre allineato (#50), task 7: Immich parte e si ferma con l'SSD"
```

---

### Task 8: richieste di allineamento dai job e finestra Foto

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `BackupRunner` (`run(label:refreshesLibraryIndex:work:)`, `finishJob(label:listOutcome:)`, fine di `startDuplicateTrashRun`), `ImmichView`, nuove view `ImmichAlignmentBar` e `ImmichKeySheet` subito dopo `ImmichSetupPromptView`
- Test: nessuno nuovo (view SwiftUI e cablaggio); le funzioni pure che le guidano sono già coperte (`ImmichWindowState`, `ImmichAlignmentStatus`). Build + suite Immich.

**Interfaces:**
- Consumes: `ImmichAligner.shared` (`status`, `request`, `acceptDropAndRetry`, `keyStore`), `ImmichWindowState`, `ImmichAlignmentStatus`, `ImmichAlignmentText`, `ImmichKeyMaker`, `ImmichHTTPClient.send`, `ImmichAutoStartCoordinator.shared.react()`.

- [ ] **Step 1: richieste dai job.** In `BackupRunner`, accanto alle altre proprietà private del job (es. vicino a `private var wasStopped`), aggiungi:

```swift
    /// Il job in corso scrive sull'SSD (Mac -> SSD, Importa): a fine job si riallinea Immich
    /// (ROADMAP #50). Impostato in `run`, letto in `finishJob`.
    private var jobWritesToSSD = false
```

In `run(label:refreshesLibraryIndex:work:)`, subito dopo `wasStopped = false`:
```swift
        jobWritesToSSD = refreshesLibraryIndex
```

In `finishJob(label:listOutcome:)`, dopo `closeJobLog()`:
```swift
        // Dopo il log chiuso: un errore di Immich non tocca mai l'esito del backup.
        if jobWritesToSSD { ImmichAligner.shared.request(.backupFinished) }
```

In `startDuplicateTrashRun`, nel blocco `await MainActor.run { … }` finale, dopo `self.lastDuplicateRunOutcome = finalOutcome`:
```swift
                if !finalOutcome.trashedFiles.isEmpty {
                    ImmichAligner.shared.request(.duplicatesMoved(count: finalOutcome.trashedFiles.count))
                }
```

- [ ] **Step 2: finestra Foto.** Sostituisci in `ImmichView` le proprietà, `content` e `idle` (il `body` resta com'è) con:

```swift
    @ObservedObject private var gate = AuthGateManager.shared
    @ObservedObject private var immich = ImmichManager.shared
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var volumes = VolumeMonitor.shared
    @ObservedObject private var aligner = ImmichAligner.shared
    @State private var showsKeySheet = false
    @State private var confirmsDrop = false

    /// La libreria da indicizzare è l'SSD già configurato in `BookmarkManager`: nessuna
    /// nuova destinazione, nessun nuovo bookmark (vedi spec).
    private var ssdPath: String? { bm.urls[.ssd]?.path }

    private var windowState: ImmichWindowState {
        .of(installed: immich.installed, isStarting: immich.isStarting, isRunning: immich.isRunning,
            ssdPathKnown: ssdPath != nil, ssdMounted: volumes.ssdMounted, lastError: immich.lastError)
    }

    private var missingAfterScan: Int {
        if case .dropGuard(let missing) = aligner.status { return missing }
        return 0
    }

    @ViewBuilder
    private var content: some View {
        switch windowState {
        case .notInstalled:
            ImmichSetupPromptView()
        case .starting:
            ImmichMessageView(
                icon: "hourglass",
                title: "Avvio di Immich…",
                message: "La prima volta richiede diversi minuti: viene avviata una macchina virtuale e scaricate le immagini dei container.",
                showsProgress: true)
        case .ready:
            VStack(spacing: 0) {
                ImmichAlignmentBar(status: aligner.status,
                                   onRetry: { aligner.request(.manual) },
                                   onEnterPassword: { showsKeySheet = true },
                                   onAcceptDrop: { confirmsDrop = true })
                ImmichWebView(url: ImmichManager.webUIURL)
            }
            .sheet(isPresented: $showsKeySheet) { ImmichKeySheet { showsKeySheet = false } }
            .alert("Togliere comunque le foto da Immich?", isPresented: $confirmsDrop) {
                Button("Togli comunque", role: .destructive) { aligner.acceptDropAndRetry() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text(ImmichAlignmentText.acceptDropConfirmation(missing: missingAfterScan))
            }
        case .ssdNotConfigured:
            ImmichMessageView(
                icon: "externaldrive.badge.questionmark",
                title: "SSD non configurato",
                message: "Configura prima l'SSD esterno nella schermata iniziale: è la cartella che Immich indicizzerà in sola lettura.")
        case .ssdNotConnected:
            ImmichMessageView(
                icon: "externaldrive.badge.xmark",
                title: "SSD non collegato",
                message: "Collega l'SSD: Immich parte da solo e si aggiorna con le foto nuove.")
        case .stopped(let error):
            ImmichMessageView(
                icon: "photo.on.rectangle.angled",
                title: "Immich è fermo",
                message: "Le foto vengono lette in sola lettura da:\n\(ssdPath ?? "")",
                error: error) {
                    Button("Riprova") {
                        Task { await ImmichAutoStartCoordinator.shared.react() }
                    }
                    .buttonStyle(.borderedProminent)
                }
        }
    }
```

Elimina la vecchia `private var idle: some View` (non serve più).

- [ ] **Step 3: le due view nuove**, subito dopo la chiusura di `struct ImmichSetupPromptView`:

```swift
/// Riga sopra l'interfaccia di Immich: cosa sta facendo l'allineamento e, se serve, cosa fare.
struct ImmichAlignmentBar: View {
    let status: ImmichAlignmentStatus
    let onRetry: () -> Void
    let onEnterPassword: () -> Void
    let onAcceptDrop: () -> Void

    var body: some View {
        if status != .idle {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.sm) {
                    if case .running = status { ProgressView().controlSize(.small) }
                    Text(status.line())
                        .font(AppFont.caption)
                        .foregroundStyle(status.isProblem ? AppColor.error : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()
                    ForEach(status.actions, id: \.self) { action in
                        switch action {
                        case .retry: Button("Riprova", action: onRetry)
                        case .enterPassword: Button("Inserisci la password", action: onEnterPassword)
                        case .acceptDrop: Button("Togli comunque…", action: onAcceptDrop)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                Divider()
            }
        }
    }
}

/// Email e password di Immich, una volta sola: l'app crea la chiave e dimentica la password.
struct ImmichKeySheet: View {
    let onDone: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Collega l'app a Immich").font(AppFont.title)
            Text("Serve una volta sola. Con la password l'app crea una chiave per aggiornare Immich da sola e la salva nel Portachiavi. La password non viene salvata.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            TextField("Email di Immich", text: $email)
                .textContentType(.username)
            SecureField("Password di Immich", text: $password)
                .textContentType(.password)
            if let error {
                Text(error).font(AppFont.caption).foregroundStyle(AppColor.error)
            }
            HStack {
                Spacer()
                Button("Annulla", role: .cancel, action: onDone)
                Button(isWorking ? "Collego…" : "Collega") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 420)
    }

    private func connect() {
        isWorking = true
        error = nil
        let email = self.email
        let password = self.password
        Task {
            do {
                let session = URLSession(configuration: .ephemeral)
                let key = try await ImmichKeyMaker.makeKey(email: email, password: password) {
                    try await ImmichHTTPClient.send($0, session: session)
                }
                try ImmichAligner.shared.keyStore.save(key)
                self.password = ""
                isWorking = false
                onDone()
                ImmichAligner.shared.request(.keyAdded)
            } catch {
                isWorking = false
                let failure = (error as? ImmichAlignmentFailure) ?? .notReachable
                self.error = failure == .unauthorized ? "Email o password non corrette."
                                                      : ImmichAlignmentText.failure(failure)
            }
        }
    }
}
```

- [ ] **Step 4: build e test.** Build completo: `BUILD SUCCEEDED`, nessun warning nuovo di isolamento (`grep -i "actor-isolated"` sull'output vuoto). Poi le classi `ImmichComposeFileTests`, `ImmichAlignmentRulesTests`, `ImmichRequestsTests`, `ImmichAlignmentRunTests`, `ImmichAlignerTests` verdi.

- [ ] **Step 5: commit.**
```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Immich sempre allineato (#50), task 8: allineamento dopo i job e finestra Foto"
```

---

### Task 9: suite completa e documentazione

**Files:**
- Create: `Docs/adr/0021-immich-si-allinea-da-solo-all-ssd-toccando-solo-il-suo-database.md`
- Modify: `Docs/ROADMAP.md` (nuovo punto 50, nota sotto il 29), `Docs/CLAUDE.md` (riga Immich #29 della tabella stato, riga test automatici), `.claude/rules/architecture.md` (sezione nuova sull'allineamento di Immich)

- [ ] **Step 1: suite completa.** `xcodebuild … -derivedDataPath "$DD" test 2>&1 | tail -40`. Atteso: `TEST SUCCEEDED`, 0 fallimenti. Annota il numero di test (era 1.525) e quanti sono nuovi per file.

- [ ] **Step 2: ADR-0021.** Formato degli ADR esistenti (leggi `Docs/adr/0020-*.md` e copiane la struttura). Contenuto: contesto (Immich fermo all'11/10, 89.514 offline, 22.392 simili, 4.561 minuscole), decisione (l'app guida Immich con l'API; solo database di Immich; mai `resolve`; chiave con permessi chiusi; guardia del calo con riferimento ricordato; versione fissata), alternative scartate (impostazioni di Immich, scrittura nel database), conseguenze (chiave con `asset.delete`, mitigata dal doppio mount in sola lettura; «Togli comunque» per cali voluti; un aggiornamento di Immich richiede di cambiare `immichVersion` e riverificare gli endpoint).

- [ ] **Step 3: ROADMAP.** Aggiungi dopo il punto 48:

```markdown
50. ⏳ **Implementato il <data>, verifica dal vivo ancora da fare — Immich sempre allineato con l'SSD (progetto A di #29).** Spec `Docs/superpowers/specs/2026-11-13-immich-always-aligned-design.md`, piano `Docs/superpowers/plans/2026-11-13-immich-always-aligned.md`, ADR-0021. Immich parte e si ferma con l'SSD; dopo ogni Mac → SSD, import, spostamento di doppioni e avvio di Immich l'app scansiona la libreria, toglie dal database di Immich le offline già nel suo Cestino, impila le foto simili e archivia le immagini sotto i 400 px. Solo il database di Immich: l'SSD resta in sola lettura. Progetto B (velocità, miniature, ricerca, volti) ancora da fare.
```

e sotto il punto 29, in coda: `**2026-11-13:** diviso in due progetti — A «sempre allineato» (#50) e B «veloce» (da fare).`

- [ ] **Step 4: `Docs/CLAUDE.md`.** Riga `| Immich (#29) |`: aggiungi che dal 2026-11-13 si avvia da solo con l'SSD e si riallinea dopo i job (#50, verifica dal vivo da fare). Riga `| Test automatici |`: il numero nuovo con il dettaglio dei file nuovi (`ImmichAlignmentRulesTests`, `ImmichRequestsTests`, `ImmichAlignmentRunTests` con `ImmichAlignerTests`) e l'estensione di `ImmichComposeFileTests` (+3).

- [ ] **Step 5: `.claude/rules/architecture.md`.** Sezione «Allineamento di Immich (#50, ADR-0021)»: i tipi della sezione e cosa fa ciascuno, chi chiama `ImmichAligner.request` (fine di `finishJob` con `jobWritesToSSD`, fine di `startDuplicateTrashRun`, successo di `ImmichManager.start`, foglio della chiave), l'ordine dei passi di `ImmichAlignmentRun.run`, le due guardie, dove stanno stato/log/chiave, e che `PUT /assets` è deprecato in v3.2.0.

- [ ] **Step 6: `graphify update .`, poi commit.**
```bash
git add Docs/ .claude/rules/architecture.md
git commit -m "Immich sempre allineato (#50), task 9: ADR-0021, ROADMAP, documentazione"
```

---

### Task 10: verifica dal vivo con Enrico

Nessun codice nuovo, salvo correzioni trovate qui (ognuna con il suo test e commit). Prima di iniziare:
- app esportata e installata in `/Applications` come per #49 (archive + `-exportArchive`, vecchia copia salvata in zip, `lsregister -f`);
- **copia del database di Immich**, perché il passo 3 toglie per sempre dal database le 89.514 offline (i file sull'SSD non c'entrano): con Immich acceso, `docker exec appbackupfoto-immich-immich-database-1 pg_dump -U postgres immich | gzip > ~/Documents/immich-db-prima-di-50.sql.gz` (con `DOCKER_CONFIG`/`DOCKER_HOST` dell'app e il `docker` in `~/Library/Application Support/AppBackupFoto/immich/bin`). Controlla che il file non sia vuoto.

- [ ] **1. Avvio automatico.** App chiusa, SSD collegato → apri l'app. Atteso: Immich parte da solo, la finestra Foto mostra «Avvio di Immich…» e poi l'interfaccia. I due container `immich-server` e `immich-machine-learning` girano con l'immagine `v3.2.0` (`docker ps --format '{{.Names}} {{.Image}}'`).
- [ ] **2. Chiave.** Compare «Per aggiornare Immich da solo serve la tua password…» → «Inserisci la password» → email e password di Enrico. Atteso: chiave nel Portachiavi (`security find-generic-password -s AppBackupFoto -a immich-api-key` trova la voce), in Immich (Impostazioni account → Chiavi API) c'è «AppBackupFoto — allineamento» con i 10 permessi, nessuna password in `~/Library/Logs/AppBackupFoto/immich-alignment.log`.
- [ ] **3. Primo allineamento.** Atteso, dal database di Immich in sola lettura: 0 asset offline nel Cestino (erano 89.514), le 31 cestinate a mano ancora lì, la libreria `SSD - Enri` con `refreshedAt` di oggi, le foto arrivate dopo l'11/10 presenti (confronto col numero dell'inventario, 52.590 file), pile create, minuscole con `visibility = 'archive'`. Riga di esito nella finestra e nel log. **Verifica anche** che `GET /libraries/{id}/statistics` `total` coincida con le foto non cestinate della libreria (query `select count(*) from asset where "libraryId"=… and "deletedAt" is null`): se non coincide, la guardia del calo conta la cosa sbagliata, va corretta prima di proseguire.
- [ ] **4. Foto nuova.** Import di una foto di prova (come per #49) → senza toccare niente, entro pochi minuti la foto è nella griglia di Immich e la riga dice «1 foto nuova».
- [ ] **5. Disfatto a mano.** Togli una minuscola dall'Archivio in Immich, separa una pila → «Riprova» → né l'una né l'altra tornano.
- [ ] **6. SSD scollegato e ricollegato.** Espelli l'SSD → Immich si ferma (container giù, finestra «SSD non collegato»). Ricollega → riparte e allinea, nessuna foto tolta.
- [ ] **7. Pulizia.** Foto di prova dell'import nel Cestino come per #49; aggiorna ROADMAP #50 a ✅ con l'esito, `Docs/CLAUDE.md` e il piano (task spuntati), commit.

## Self-review

- Copertura della spec: avvio/arresto (Task 7), chiave e permessi (Task 4, 8), client ed endpoint (Task 4), regole (Task 2), allineamento e guardie (Task 5), coordinatore e richieste unite (Task 6), esito nella finestra e nel log (Task 3, 6, 8), versione fissata (Task 1), test dal vivo (Task 10), documentazione (Task 9).
- Nomi coerenti fra task: `ImmichAlignmentFailure`, `ImmichAlignmentStatus`, `ImmichAlignmentRun.Environment`, `ImmichAligner.request(_:)`, `ImmichAutoStartCoordinator.react()`, `ImmichManager.ssdMountTarget`/`immichVersion`.
