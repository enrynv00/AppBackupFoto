//
//  S3SyncerCatalogParsingTests.swift
//  AppBackupFotoTests
//
//  Verifica S3Syncer.parseCatalogEntries su frammenti XML di ListObjectsV2 —
//  funzione pura, nessuna chiamata di rete.
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerCatalogParsingTests: XCTestCase {

    func testEmptyXML_returnsEmptyArray() {
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: "<ListBucketResult></ListBucketResult>")
        XCTAssertTrue(entries.isEmpty)
    }

    func testSingleEntry_parsesNameRelativePathSizeAndDate() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>Foto iPhone/2024/IMG_001.jpg</Key>
                <LastModified>2024-03-15T10:30:00.000Z</LastModified>
                <ETag>"abc123"</ETag>
                <Size>2048576</Size>
                <StorageClass>STANDARD</StorageClass>
            </Contents>
            <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "IMG_001.jpg")
        XCTAssertEqual(entries[0].relativePath, "Foto iPhone/2024/IMG_001.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 2_048_576)
        XCTAssertNotNil(entries[0].modified)
        if let modified = entries[0].modified {
            let comps = Calendar(identifier: .gregorian).dateComponents(
                in: TimeZone(identifier: "UTC")!, from: modified)
            XCTAssertEqual(comps.year, 2024); XCTAssertEqual(comps.month, 3); XCTAssertEqual(comps.day, 15)
        }
    }

    func testMultipleEntries_parsedInDocumentOrder() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>Foto iPhone/2024/IMG_001.jpg</Key>
                <LastModified>2024-03-15T10:30:00.000Z</LastModified>
                <Size>1000</Size>
            </Contents>
            <Contents>
                <Key>Foto iPhone/2024/IMG_002.jpg</Key>
                <LastModified>2024-03-16T11:00:00.000Z</LastModified>
                <Size>2000</Size>
            </Contents>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "IMG_001.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 1000)
        XCTAssertEqual(entries[1].name, "IMG_002.jpg")
        XCTAssertEqual(entries[1].sizeBytes, 2000)
    }

    func testKeyWithNoSubfolder_relativePathEqualsName() {
        let xml = """
        <ListBucketResult>
            <Contents>
                <Key>root-file.jpg</Key>
                <LastModified>2024-01-01T00:00:00.000Z</LastModified>
                <Size>500</Size>
            </Contents>
        </ListBucketResult>
        """
        let entries = S3Syncer().parseCatalogEntries(fromListObjectsXML: xml)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "root-file.jpg")
        XCTAssertEqual(entries[0].relativePath, "root-file.jpg")
    }
}
