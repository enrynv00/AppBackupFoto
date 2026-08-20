import XCTest
@testable import AppBackupFoto

final class S3SyncerMultipartXMLTests: XCTestCase {
    func testBuildCompleteMultipartXML_sortsOutOfOrderParts() {
        let xml = S3Syncer.buildCompleteMultipartXML(parts: [
            (partNumber: 3, etag: "etag3"),
            (partNumber: 1, etag: "etag1"),
            (partNumber: 2, etag: "etag2"),
        ])
        let expected = "<CompleteMultipartUpload>"
            + "<Part><PartNumber>1</PartNumber><ETag>etag1</ETag></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>etag2</ETag></Part>"
            + "<Part><PartNumber>3</PartNumber><ETag>etag3</ETag></Part>"
            + "</CompleteMultipartUpload>"
        XCTAssertEqual(xml, expected)
    }

    func testBuildCompleteMultipartXML_singlePart() {
        let xml = S3Syncer.buildCompleteMultipartXML(parts: [(partNumber: 1, etag: "onlyone")])
        XCTAssertEqual(xml, "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>onlyone</ETag></Part></CompleteMultipartUpload>")
    }
}
