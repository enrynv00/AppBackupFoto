import XCTest
@testable import AppBackupFoto

/// Blinda i tre vincoli non negoziabili del compose file di Immich (roadmap #29):
/// bind solo su 127.0.0.1, dati propri di Immich sul disco interno, libreria SSD in sola lettura.
/// Nessun container viene avviato: `composeFileContent` è una funzione pura apposta per questo.
final class ImmichComposeFileTests: XCTestCase {
    private let ssdPath = "/Volumes/SSD - Enri/Foto iPhone"

    private func content() -> String {
        ImmichManager.shared.composeFileContent(sourceLibraryPath: ssdPath)
    }

    func testServerPortIsPublishedOnLocalhostOnly() {
        let yaml = content()
        XCTAssertTrue(yaml.contains("\"127.0.0.1:2283:2283\""),
                      "La porta del server deve essere pubblicata su 127.0.0.1")
        XCTAssertFalse(yaml.contains("0.0.0.0"),
                       "Il server non deve mai essere esposto su 0.0.0.0")
    }

    func testSourceLibraryIsMountedReadOnly() {
        let yaml = content()
        XCTAssertTrue(yaml.contains("\"\(ssdPath)\":/external-ssd:ro"),
                      "La libreria sull'SSD deve essere montata in sola lettura")
    }

    func testSourceLibraryIsNeverMountedWritable() {
        let yaml = content()
        XCTAssertFalse(yaml.contains("\"\(ssdPath)\":/external-ssd\n"),
                       "Nessun mount scrivibile della libreria sorgente")
        XCTAssertFalse(yaml.contains("\(ssdPath):/data"),
                       "La libreria sorgente non deve mai essere usata come storage di Immich")
    }

    func testAllDataVolumesLiveUnderDataDir() {
        let yaml = content()
        let dataPath = ImmichManager.shared.dataDir.path
        for volume in ["upload", "model-cache", "postgres"] {
            XCTAssertTrue(yaml.contains("\"\(dataPath)/\(volume)\":"),
                          "Il volume \(volume) deve stare sotto dataDir (disco interno)")
        }
    }

    func testDataDirIsOnInternalDiskNotOnExternalVolumes() {
        let dataPath = ImmichManager.shared.dataDir.path
        XCTAssertFalse(dataPath.hasPrefix("/Volumes/"),
                       "I dati di Immich non devono mai finire su un volume esterno")
        XCTAssertTrue(dataPath.contains("Application Support/AppBackupFoto/immich"))
    }

    func testAllFourServicesArePresent() {
        let yaml = content()
        for service in ["immich-server:", "immich-machine-learning:", "immich-redis:", "immich-database:"] {
            XCTAssertTrue(yaml.contains(service), "Servizio mancante nel compose: \(service)")
        }
    }

    func testPathWithQuoteIsEscapedAndDoesNotBreakYAML() {
        let nasty = "/Volumes/SSD \"strano\"/Foto"
        let yaml = ImmichManager.shared.composeFileContent(sourceLibraryPath: nasty)
        XCTAssertTrue(yaml.contains("\"/Volumes/SSD \\\"strano\\\"/Foto\":/external-ssd:ro"),
                      "Le virgolette nel path devono essere escapate, non chiudere la stringa YAML")
    }

    func testYamlQuotedEscapesBackslashes() {
        XCTAssertEqual(ImmichManager.yamlQuoted("a\\b"), "\"a\\\\b\"")
    }
}
