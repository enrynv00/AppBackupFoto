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

    private nonisolated final class Recorder: @unchecked Sendable {
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
