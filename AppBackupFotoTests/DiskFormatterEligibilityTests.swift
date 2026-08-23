import XCTest
@testable import AppBackupFoto

/// Blinda la logica che decide quali dischi possono essere proposti per la formattazione.
/// È l'unica barriera tra un `diskutil eraseDisk` (irreversibile) e un disco di backup reale,
/// quindi è testata su path finti, senza mai eseguire `diskutil`.
final class DiskFormatterEligibilityTests: XCTestCase {

    private let ssd = "/Volumes/SSD - Enri"
    private let hdd = "/Volumes/BackupHDD"

    // MARK: - isEligible

    func testDiskWithNoMountedPath_isEligible() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: [], configuredPaths: [ssd, hdd]))
    }

    func testDiskMountedExactlyOnConfiguredSSD_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: [ssd], configuredPaths: [ssd, hdd]))
    }

    func testDiskMountedExactlyOnConfiguredHDD_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: [hdd], configuredPaths: [ssd, hdd]))
    }

    /// Caso BUG-1 storico: il bookmark punta a una sottocartella, non alla root del volume.
    /// Il disco che ospita quella sottocartella non va comunque mai proposto.
    func testDiskMountedOnParentOfConfiguredSubfolder_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: [ssd],
                                                configuredPaths: ["\(ssd)/Foto iPhone"]))
    }

    func testDiskMountedInsideConfiguredPath_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: ["\(ssd)/Foto iPhone"],
                                                configuredPaths: [ssd]))
    }

    /// Un `hasPrefix` ingenuo direbbe che "/Volumes/SSD" contiene "/Volumes/SSD - Enri":
    /// il confronto deve avvenire per componenti di path.
    func testDifferentVolumeSharingATextualPrefix_isEligible() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: ["/Volumes/SSD"], configuredPaths: [ssd]))
    }

    func testUnrelatedVolume_isEligible() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: ["/Volumes/Chiavetta"],
                                               configuredPaths: [ssd, hdd]))
    }

    func testCaseDifferentPath_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: ["/volumes/ssd - enri"],
                                                configuredPaths: [ssd]))
    }

    func testTrailingSlashAndDoubleSlash_areNormalized() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: ["\(ssd)/"], configuredPaths: [ssd]))
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: ["/Volumes//BackupHDD"], configuredPaths: [hdd]))
    }

    /// Stesso nome di volume in forma Unicode decomposta (come lo restituiscono i filesystem
    /// Apple) contro forma precomposta: deve comunque risultare lo stesso path.
    func testDecomposedUnicodePath_isNotEligible() {
        let precomposed = "/Volumes/Citt\u{00E0}"      // "Città"
        let decomposed = "/Volumes/Citta\u{0300}"      // "Citta" + accento combinante
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: [decomposed], configuredPaths: [precomposed]))
    }

    /// Un disco non montato riporta `MountPoint` = "": non deve combaciare con niente.
    func testEmptyMountPath_isEligible() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: ["", "   "], configuredPaths: [ssd, hdd]))
    }

    /// Un path configurato vuoto non deve escludere tutti i dischi.
    func testEmptyConfiguredPath_doesNotExcludeEverything() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: ["/Volumes/Chiavetta"], configuredPaths: [""]))
    }

    func testNoConfiguredPaths_everythingIsEligible() {
        XCTAssertTrue(DiskFormatter.isEligible(diskPaths: [ssd], configuredPaths: []))
    }

    /// Un disco con più volumi montati: basta che uno solo sia configurato per escluderlo.
    func testOneOfSeveralMountedPathsIsConfigured_isNotEligible() {
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: ["/Volumes/Scratch", hdd],
                                                configuredPaths: [hdd]))
    }

    // MARK: - wholeDiskIdentifier

    func testWholeDiskIdentifier() {
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk4"), "disk4")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk4s2"), "disk4")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk3s1s1"), "disk3")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk12s7"), "disk12")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "qualcosaltro"), "qualcosaltro")
    }

    // MARK: - topology (parsing dell'output di `diskutil list -plist external`)

    /// Struttura verificata empiricamente il 2026-08-23 su "SSD - Enri" reale (ExFAT, MBR).
    private func exfatDiskEntry() -> [String: Any] {
        [
            "Content": "FDisk_partition_scheme",
            "DeviceIdentifier": "disk4",
            "Size": NSNumber(value: 1_000_204_886_016 as Int64),
            "Partitions": [[
                "Content": "Windows_NTFS",
                "DeviceIdentifier": "disk4s1",
                "MountPoint": "/Volumes/SSD - Enri",
                "VolumeName": "SSD - Enri",
                "Size": NSNumber(value: 1_000_203_091_968 as Int64)
            ]]
        ]
    }

    /// Struttura verificata empiricamente il 2026-08-23 su un disco APFS reale: il container è un
    /// disco *sintetizzato* separato, i cui volumi vanno riattribuiti al disco fisico che lo ospita.
    private func apfsPlist() -> [String: Any] {
        [
            "AllDisksAndPartitions": [
                [
                    "Content": "GUID_partition_scheme",
                    "DeviceIdentifier": "disk6",
                    "Size": NSNumber(value: 2_000_398_934_016 as Int64),
                    "Partitions": [
                        ["Content": "EFI", "DeviceIdentifier": "disk6s1",
                         "Size": NSNumber(value: 209_715_200 as Int64)],
                        ["Content": "Apple_APFS", "DeviceIdentifier": "disk6s2",
                         "Size": NSNumber(value: 2_000_187_768_832 as Int64)]
                    ]
                ],
                [
                    "APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"]],
                    "APFSVolumes": [[
                        "DeviceIdentifier": "disk7s1",
                        "MountPoint": "/Volumes/BackupHDD",
                        "VolumeName": "BackupHDD",
                        "Size": NSNumber(value: 2_000_187_768_832 as Int64)
                    ]],
                    "Content": "EF57347C-0000-11AA-AA11-0030654",
                    "DeviceIdentifier": "disk7",
                    "Size": NSNumber(value: 2_000_187_768_832 as Int64)
                ]
            ]
        ]
    }

    func testTopology_partitionMountPointIsAttributedToWholeDisk() {
        let layout = DiskFormatter.topology(fromListPlist: ["AllDisksAndPartitions": [exfatDiskEntry()]])
        XCTAssertEqual(layout.mountPaths["disk4"], ["/Volumes/SSD - Enri"])
        XCTAssertTrue(layout.apfsHosts.isEmpty)
    }

    /// Regressione centrale: senza la riattribuzione via `APFSPhysicalStores`, un HDD APFS già
    /// configurato risulterebbe senza path montati e verrebbe proposto per la formattazione.
    func testTopology_apfsVolumeIsAttributedToPhysicalHostDisk() {
        let layout = DiskFormatter.topology(fromListPlist: apfsPlist())
        XCTAssertEqual(layout.mountPaths["disk6"], ["/Volumes/BackupHDD"])
        XCTAssertNil(layout.mountPaths["disk7"])
        XCTAssertTrue(layout.apfsHosts.contains("disk6"))
    }

    func testConfiguredAPFSDisk_isNotEligible() {
        let layout = DiskFormatter.topology(fromListPlist: apfsPlist())
        XCTAssertFalse(DiskFormatter.isEligible(diskPaths: layout.mountPaths["disk6"] ?? [],
                                                configuredPaths: [hdd]))
    }

    func testTopology_emptyMountPointsAreIgnored() {
        let plist: [String: Any] = ["AllDisksAndPartitions": [[
            "DeviceIdentifier": "disk8",
            "MountPoint": "",
            "Partitions": [["DeviceIdentifier": "disk8s1", "Content": "Apple_HFS", "MountPoint": ""]]
        ]]]
        let layout = DiskFormatter.topology(fromListPlist: plist)
        XCTAssertNil(layout.mountPaths["disk8"])
    }

    func testTopology_malformedPlistYieldsEmptyTopology() {
        let layout = DiskFormatter.topology(fromListPlist: ["Qualcosa": "di inatteso"])
        XCTAssertTrue(layout.mountPaths.isEmpty)
        XCTAssertTrue(layout.apfsHosts.isEmpty)
    }

    // MARK: - dataPartitionIdentifiers

    func testDataPartitions_skipAuxiliaryOnes() {
        let entry: [String: Any] = ["Partitions": [
            ["Content": "EFI", "DeviceIdentifier": "disk6s1"],
            ["Content": "Apple_APFS", "DeviceIdentifier": "disk6s2"],
            ["Content": "Apple_APFS_Recovery", "DeviceIdentifier": "disk6s3"]
        ]]
        XCTAssertEqual(DiskFormatter.dataPartitionIdentifiers(inDiskEntry: entry), ["disk6s2"])
    }

    func testDataPartitions_diskWithoutPartitions() {
        XCTAssertEqual(DiskFormatter.dataPartitionIdentifiers(inDiskEntry: [:]), [])
    }

    // MARK: - displayName / filesystemLabel

    func testDisplayName_prefersMediaName() {
        let info: [String: Any] = ["MediaName": "PSSD T7",
                                   "IORegistryEntryName": "Samsung PSSD T7 Media",
                                   "VolumeName": "SSD - Enri"]
        XCTAssertEqual(DiskFormatter.displayName(fromInfoPlist: info, identifier: "disk4"), "PSSD T7")
    }

    func testDisplayName_fallsBackThroughEmptyValues() {
        let info: [String: Any] = ["MediaName": "  ", "IORegistryEntryName": "Generic USB Media"]
        XCTAssertEqual(DiskFormatter.displayName(fromInfoPlist: info, identifier: "disk9"),
                       "Generic USB Media")
        XCTAssertEqual(DiskFormatter.displayName(fromInfoPlist: [:], identifier: "disk9"), "disk9")
    }

    func testFilesystemLabel_apfsHostIsRecognizedWithoutInspectingPartitions() {
        var layout = DiskFormatter.DiskTopology()
        layout.apfsHosts.insert("disk6")
        XCTAssertEqual(DiskFormatter.filesystemLabel(diskEntry: [:], identifier: "disk6", topology: layout),
                       "APFS")
    }

    func testFilesystemLabel_diskWithoutPartitionsIsReportedAsUnformatted() {
        XCTAssertEqual(DiskFormatter.filesystemLabel(diskEntry: ["Partitions": []],
                                                     identifier: "disk9",
                                                     topology: DiskFormatter.DiskTopology()),
                       "Non formattato")
    }

    // MARK: - plistDictionary

    func testPlistDictionary_rejectsNonPlistOutput() {
        XCTAssertThrowsError(try DiskFormatter.plistDictionary(from: Data("non un plist".utf8),
                                                               command: "diskutil list -plist")) { error in
            guard case DiskFormatter.Failure.unreadableOutput = error else {
                return XCTFail("Errore inatteso: \(error)")
            }
        }
    }
}
