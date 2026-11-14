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

    func testNoRequestSendsOrStoresCookies() {
        let requests = [ImmichRequests.libraries(apiKey: "K"), ImmichRequests.statistics(libraryId: "L", apiKey: "K"),
                        ImmichRequests.scan(libraryId: "L", apiKey: "K"), ImmichRequests.jobs(apiKey: "K"),
                        ImmichRequests.duplicates(apiKey: "K"),
                        ImmichRequests.search(.offline(libraryId: "L"), token: nil, apiKey: "K"),
                        ImmichRequests.search(.images(libraryId: "L"), token: .page(2), apiKey: "K"),
                        ImmichRequests.deleteAssets(ids: ["a"], apiKey: "K"),
                        ImmichRequests.createStack(assetIds: ["a", "b"], apiKey: "K"),
                        ImmichRequests.archive(ids: ["a"], apiKey: "K"),
                        ImmichRequests.login(email: "e", password: "p"),
                        ImmichRequests.createKey(bearer: "T"), ImmichRequests.logout(bearer: "T")]
        for r in requests { XCTAssertFalse(r.httpShouldHandleCookies, r.url?.path ?? "") }
    }

    // MARK: - ID nei percorsi

    func testNormalIDsAreUnchangedInPaths() {
        let uuid = "0b9d7a4e-1c2f-4f6a-9d3e-5a8b7c6d5e4f"
        XCTAssertEqual(ImmichRequests.statistics(libraryId: uuid, apiKey: "K").url?.absoluteString,
                       "http://127.0.0.1:2283/api/libraries/\(uuid)/statistics")
        XCTAssertEqual(ImmichRequests.scan(libraryId: "lib1", apiKey: "K").url?.absoluteString,
                       "http://127.0.0.1:2283/api/libraries/lib1/scan")
    }

    func testAnIDCannotChangeTheEndpoint() throws {
        for evil in ["../x", "a/b", "..", "x/../../jobs", "a?b=c", "a#b", "100%"] {
            for r in [ImmichRequests.statistics(libraryId: evil, apiKey: "K"), ImmichRequests.scan(libraryId: evil, apiKey: "K")] {
                let url = try XCTUnwrap(r.url, evil)
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
                XCTAssertEqual(segments.count, 5, "\(evil) -> \(url)")   // "", api, libraries, <id>, statistics|scan
                XCTAssertNil(components.query, evil)
                XCTAssertNil(components.fragment, evil)
                XCTAssertFalse(segments.contains(".."), evil)
                XCTAssertFalse(segments.contains("."), evil)
            }
        }
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

    // MARK: - Ricerca oltre il tetto delle pagine

    func testSearchBeyondMaxPagesFailsInsteadOfReturningAPartialList() async {
        var calls = 0
        do {
            _ = try await ImmichHTTPClient.collectPages(maxPages: 3) { _ in
                calls += 1
                return ImmichSearchResponse.Page(items: [], nextPage: nil, nextCursor: "C\(calls)")
            }
            XCTFail("doveva lanciare")
        } catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .badResponse) }
        XCTAssertEqual(calls, 3)
    }

    func testSearchEndingExactlyAtMaxPagesIsComplete() async throws {
        var calls = 0
        let all = try await ImmichHTTPClient.collectPages(maxPages: 3) { _ in
            calls += 1
            return ImmichSearchResponse.Page(items: [immichTestAsset("a\(calls)")], nextPage: nil,
                                             nextCursor: calls < 3 ? "C" : nil)
        }
        XCTAssertEqual(all.map(\.id), ["a1", "a2", "a3"])
    }

    func testBadJSONIsBadResponse() {
        XCTAssertThrowsError(try ImmichHTTPClient.decode(ImmichLibraryStats.self, from: Data("{}".utf8))) {
            XCTAssertEqual($0 as? ImmichAlignmentFailure, .badResponse)
        }
    }

    // MARK: - Creazione della chiave

    private nonisolated final class Recorder: @unchecked Sendable {
        var paths: [String] = []
        var failCreate = false
        var failLogin = false
        /// Se true, la richiesta di creazione cancella il task che sta eseguendo `makeKey`.
        var cancelDuringCreate = false
        var logoutSawCancellation: Bool?
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
                if rec.cancelDuringCreate { withUnsafeCurrentTask { $0?.cancel() } }
                if rec.failCreate { throw ImmichAlignmentFailure.http(400) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
                return Data(#"{"secret":"CHIAVE"}"#.utf8)
            case "/api/auth/logout":
                rec.logoutSawCancellation = Task.isCancelled
                return Data("{}".utf8)
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

    func testLogoutStillRunsWhenTheTaskIsCancelledAfterCreation() async throws {
        let rec = Recorder(); rec.cancelDuringCreate = true
        let key = try await ImmichKeyMaker.makeKey(email: "e", password: "p", send: send(rec))
        XCTAssertEqual(key, "CHIAVE")
        XCTAssertEqual(rec.paths.last, "/api/auth/logout")
        XCTAssertEqual(rec.logoutSawCancellation, false, "il logout non deve ereditare la cancellazione")
    }

    func testLogoutStillRunsWhenTheTaskIsCancelledAndCreationFails() async {
        let rec = Recorder(); rec.cancelDuringCreate = true; rec.failCreate = true
        do { _ = try await ImmichKeyMaker.makeKey(email: "e", password: "p", send: send(rec)); XCTFail("doveva fallire") }
        catch { XCTAssertEqual(error as? ImmichAlignmentFailure, .http(400)) }
        XCTAssertEqual(rec.paths.last, "/api/auth/logout")
        XCTAssertEqual(rec.logoutSawCancellation, false)
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
