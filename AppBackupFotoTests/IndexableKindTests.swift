import XCTest
@testable import AppBackupFoto

final class IndexableKindTests: XCTestCase {
    private func kind(_ name: String) -> IndexableKind {
        IndexableKind.of(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testJpeg_isImage()  { XCTAssertEqual(kind("IMG_0001.jpg"), .image) }
    func testHeic_isImage()  { XCTAssertEqual(kind("IMG_0002.heic"), .image) }
    func testPng_isImage()   { XCTAssertEqual(kind("shot.png"), .image) }
    func testMov_isVideo()   { XCTAssertEqual(kind("clip.mov"), .video) }
    func testMp4_isVideo()   { XCTAssertEqual(kind("drone.mp4"), .video) }

    func testZip_isNotIndexable()  { XCTAssertEqual(kind("Takeout.zip"), .notIndexable) }
    func testJson_isNotIndexable() { XCTAssertEqual(kind("metadata.json"), .notIndexable) }
    func testXmp_isNotIndexable()  { XCTAssertEqual(kind("IMG_0001.xmp"), .notIndexable) }
    func testAae_isNotIndexable()  { XCTAssertEqual(kind("IMG_0001.aae"), .notIndexable) }
    func testNoExtension_isNotIndexable() { XCTAssertEqual(kind("README"), .notIndexable) }

    func testUppercaseExtension_isImage() {
        // Le fotocamere scrivono spesso estensioni maiuscole (DSC0001.JPG)
        XCTAssertEqual(kind("DSC0001.JPG"), .image)
    }

    func testUnknownExtension_isNotIndexable() {
        // Un formato non riconosciuto resta fuori dall'indice: sbagliare per
        // esclusione e' il verso sicuro (il file viene copiato, mai saltato).
        XCTAssertEqual(kind("foto.formatoinventato"), .notIndexable)
    }
}
