import XCTest
@testable import AppBackupFoto

/// Le risposte di Cubbit che il progetto 4 legge (ROADMAP #47, ADR-0019): stato delle versioni,
/// regole di scadenza, esito di un DELETE, elenco delle versioni; e la regola che decide se
/// Cubbit e' pronto per togliere copie. Esempi nella forma della documentazione S3 e di quella
/// provata su Cubbit il 2026-10-10 (regola «vecchio stile» con `<Prefix>` vuoto).
final class S3AlignmentRequestsTests: XCTestCase {
    private typealias Rule = S3Syncer.LifecycleRule

    // MARK: - Versioni

    func testVersioning_enabledSuspendedNeverAndUnknown() {
        let ns = "xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration \(ns)><Status>Enabled</Status></VersioningConfiguration>"), .enabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>"), .suspended)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration \(ns)/>"), .neverEnabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration></VersioningConfiguration>"), .neverEnabled)
        XCTAssertEqual(S3Syncer.parseVersioning("<VersioningConfiguration><Status>Forse</Status></VersioningConfiguration>"), .unrecognized("Forse"))
    }

    // MARK: - Regole di scadenza

    private func lifecycle(_ rules: String) -> String { "<LifecycleConfiguration>\(rules)</LifecycleConfiguration>" }

    func testLifecycle_oldStyleWholeBucketRule_asAcceptedByCubbit() throws {
        let xml = lifecycle("<Rule><ID>r1</ID><Prefix></Prefix><Status>Enabled</Status><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays></NoncurrentVersionExpiration></Rule>")
        XCTAssertEqual(try S3Syncer.parseLifecycle(statusCode: 200, body: xml),
                       [Rule(id: "r1", enabled: true, wholeBucket: true, noncurrentDays: 30, expiresCurrentObjects: false)])
    }

    func testLifecycle_prefixAndFilterForms() throws {
        func whole(_ body: String) throws -> Bool { try S3Syncer.parseLifecycle(statusCode: 200, body: lifecycle("<Rule><Status>Enabled</Status>\(body)</Rule>"))[0].wholeBucket }
        XCTAssertTrue(try whole("<Prefix/>"))
        XCTAssertTrue(try whole(""))
        XCTAssertTrue(try whole("<Filter><Prefix></Prefix></Filter>"))
        XCTAssertTrue(try whole("<Filter/>"))
        XCTAssertFalse(try whole("<Prefix>Takeout/</Prefix>"))
        XCTAssertFalse(try whole("<Filter><Prefix>Takeout/</Prefix></Filter>"))
        XCTAssertFalse(try whole("<Filter><Tag><Key>a</Key><Value>b</Value></Tag></Filter>"))
        XCTAssertFalse(try whole("<Filter><And><Prefix></Prefix><Tag><Key>a</Key><Value>b</Value></Tag></And></Filter>"))
    }

    func testLifecycle_disabledRule_andExpirationForms() throws {
        let rules = try S3Syncer.parseLifecycle(statusCode: 200, body: lifecycle(
            "<Rule><ID>a</ID><Status>Disabled</Status><Prefix></Prefix><NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays></NoncurrentVersionExpiration></Rule>"
            + "<Rule><ID>b</ID><Status>Enabled</Status><Prefix></Prefix><Expiration><Days>30</Days></Expiration></Rule>"
            + "<Rule><ID>c</ID><Status>Enabled</Status><Prefix></Prefix><Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule>"))
        XCTAssertEqual(rules.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(rules[0].enabled)
        XCTAssertEqual(rules[0].noncurrentDays, 1)
        XCTAssertTrue(rules[1].expiresCurrentObjects)
        XCTAssertFalse(rules[2].expiresCurrentObjects)
    }

    func testLifecycle_noConfigurationIsNoRules_otherErrorsThrow() {
        XCTAssertEqual(try S3Syncer.parseLifecycle(statusCode: 404, body: "<Error><Code>NoSuchLifecycleConfiguration</Code></Error>"), [])
        XCTAssertThrowsError(try S3Syncer.parseLifecycle(statusCode: 403, body: "<Error/>"))
        XCTAssertThrowsError(try S3Syncer.parseLifecycle(statusCode: 500, body: ""))
    }

    // MARK: - Cubbit pronto?

    private func rule(_ days: Int?, whole: Bool = true, enabled: Bool = true, expires: Bool = false) -> Rule {
        Rule(id: "r", enabled: enabled, wholeBucket: whole, noncurrentDays: days, expiresCurrentObjects: expires)
    }

    func testSafety_readyOnlyWithVersionsAndThirtyDays() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30)]), .ready(days: 30))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(60)]), .ready(days: 60))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(1, enabled: false), rule(30)]), .ready(days: 30))
    }

    func testSafety_versionsNotEnabled() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .neverEnabled, rules: [rule(30)]), .versioningNotEnabled(.neverEnabled))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .suspended, rules: [rule(30)]), .versioningNotEnabled(.suspended))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .unrecognized("x"), rules: [rule(30)]), .versioningNotEnabled(.unrecognized("x")))
    }

    func testSafety_missingOrShortOrDangerousRules() {
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: []), .noExpiryRule)
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30, whole: false)]), .noExpiryRule)
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(7)]), .expiryTooShort(days: 7))
        // Anche una regola per una sola cartella, se piu' corta, accorcia l'annullamento li'.
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30), rule(1, whole: false)]), .expiryTooShort(days: 1))
        XCTAssertEqual(AlignmentCubbitSafety.evaluate(versioning: .enabled, rules: [rule(30), rule(nil, expires: true)]), .expiresCurrentPhotos)
    }

    // MARK: - DELETE

    func testDelete_markerAndVersionFromTheHeaders() throws {
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "true", versionId: "v-123", key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: true, versionId: "v-123"))
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "True ", versionId: " v ", key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: true, versionId: "v"))
    }

    func testDelete_withoutMarker_isReportedAsSuch() throws {
        // Versioni spente: nessun segno, nessuna versione. Il motore deve fermarsi.
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: nil, versionId: nil, key: "a.jpg"),
                       S3Syncer.DeleteResult(isDeleteMarker: false, versionId: nil))
        XCTAssertEqual(try S3Syncer.parseDelete(statusCode: 204, deleteMarker: "true", versionId: "", key: "a.jpg").versionId, nil)
    }

    func testDelete_errorsThrow() {
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: 403, deleteMarker: nil, versionId: nil, key: "a.jpg"))
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: 404, deleteMarker: nil, versionId: nil, key: "a.jpg"))
        XCTAssertThrowsError(try S3Syncer.parseDelete(statusCode: -1, deleteMarker: nil, versionId: nil, key: "a.jpg"))
    }

    // MARK: - Elenco delle versioni

    func testVersionsPage_versionsAndMarkersInDocumentOrder() {
        let xml = """
        <ListVersionsResult><Name>b</Name><Prefix>a.jpg</Prefix><IsTruncated>false</IsTruncated>
        <DeleteMarker><Key>a.jpg</Key><VersionId>m1</VersionId><IsLatest>true</IsLatest></DeleteMarker>
        <Version><Key>a.jpg</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><ETag>&quot;abc&quot;</ETag><Size>12</Size></Version>
        <Version><Key>a.jpg.json</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><ETag>"d"</ETag><Size>3</Size></Version>
        </ListVersionsResult>
        """
        let p = S3Syncer.parseVersionsPage(xml)
        XCTAssertEqual(p.entries, [
            .init(key: "a.jpg", versionId: "m1", isLatest: true, isDeleteMarker: true, etag: nil, size: nil),
            .init(key: "a.jpg", versionId: "v1", isLatest: false, isDeleteMarker: false, etag: "\"abc\"", size: 12),
            .init(key: "a.jpg.json", versionId: "v2", isLatest: true, isDeleteMarker: false, etag: "\"d\"", size: 3)])
        XCTAssertFalse(p.isTruncated)
        XCTAssertEqual(p.malformedEntries, 0)
    }

    func testVersionsPage_truncatedWithMarkers_andBrokenEntriesCounted() {
        let xml = "<ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>a.jpg</NextKeyMarker><NextVersionIdMarker>v9</NextVersionIdMarker>"
            + "<Version><Key>a.jpg</Key><IsLatest>true</IsLatest></Version></ListVersionsResult>"
        let p = S3Syncer.parseVersionsPage(xml)
        XCTAssertTrue(p.isTruncated)
        XCTAssertEqual(p.nextKeyMarker, "a.jpg")
        XCTAssertEqual(p.nextVersionIdMarker, "v9")
        XCTAssertEqual(p.malformedEntries, 1)
        XCTAssertTrue(p.entries.isEmpty)
    }
}
