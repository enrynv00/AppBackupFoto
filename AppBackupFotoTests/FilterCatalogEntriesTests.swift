//
//  FilterCatalogEntriesTests.swift
//  AppBackupFotoTests
//
//  Verifica filterCatalogEntries: filtro puro per nome/cartella, case-insensitive.
//

import XCTest
@testable import AppBackupFoto

final class FilterCatalogEntriesTests: XCTestCase {
    private func entry(name: String, path: String) -> CatalogEntry {
        CatalogEntry(name: name, relativePath: path, sizeBytes: 100, modified: nil)
    }

    func testEmptyQuery_returnsAllEntries() {
        let entries = [entry(name: "a.jpg", path: "2024/a.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        XCTAssertEqual(filterCatalogEntries(entries, matching: "").count, 2)
    }

    func testMatchByName_isCaseInsensitive() {
        let entries = [entry(name: "IMG_001.jpg", path: "2024/IMG_001.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        let result = filterCatalogEntries(entries, matching: "img_001")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "IMG_001.jpg")
    }

    func testMatchByFolderPath_notJustFileName() {
        let entries = [entry(name: "a.jpg", path: "Takeout/2019/a.jpg"), entry(name: "b.jpg", path: "2024/b.jpg")]
        let result = filterCatalogEntries(entries, matching: "takeout")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "a.jpg")
    }

    func testNoMatch_returnsEmptyArray() {
        let entries = [entry(name: "a.jpg", path: "2024/a.jpg")]
        XCTAssertTrue(filterCatalogEntries(entries, matching: "zzz").isEmpty)
    }
}
