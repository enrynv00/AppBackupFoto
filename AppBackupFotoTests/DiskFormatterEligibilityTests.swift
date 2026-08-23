import XCTest
@testable import AppBackupFoto

/// Blinda la logica che decide quali dischi possono essere proposti per la formattazione.
/// È l'unica barriera tra un `diskutil eraseDisk` (irreversibile) e un disco di backup reale,
/// quindi è testata su dati finti, senza mai eseguire `diskutil`.
final class DiskFormatterEligibilityTests: XCTestCase {

    private let ssd = "/Volumes/SSD - Enri"
    private let hdd = "/Volumes/BackupHDD"
    private let ssdUUID = "47E67C92-22D6-3BDD-87A6-6697A37BC7B9"
    private let hddUUID = "98D88CA7-A667-3DBD-8F3A-EE88807D6AB3"

    private func configured(paths: [String] = [],
                            uuids: Set<String> = []) -> DiskFormatter.ConfiguredBackupVolumes {
        DiskFormatter.ConfiguredBackupVolumes(paths: paths, volumeUUIDs: uuids)
    }

    private func isEligible(paths: [String] = [],
                            uuids: Set<String> = [],
                            configured: DiskFormatter.ConfiguredBackupVolumes) -> Bool {
        DiskFormatter.isEligible(diskPaths: paths, diskVolumeUUIDs: uuids, configured: configured)
    }

    // MARK: - isEligible, confronto sui path

    func testDiskUnknownToTheApp_isEligible() {
        XCTAssertTrue(isEligible(configured: configured(paths: [ssd, hdd], uuids: [ssdUUID])))
    }

    func testDiskMountedExactlyOnConfiguredSSD_isNotEligible() {
        XCTAssertFalse(isEligible(paths: [ssd], configured: configured(paths: [ssd, hdd])))
    }

    func testDiskMountedExactlyOnConfiguredHDD_isNotEligible() {
        XCTAssertFalse(isEligible(paths: [hdd], configured: configured(paths: [ssd, hdd])))
    }

    /// Caso BUG-1 storico: il bookmark punta a una sottocartella, non alla root del volume.
    /// Il disco che ospita quella sottocartella non va comunque mai proposto.
    func testDiskMountedOnParentOfConfiguredSubfolder_isNotEligible() {
        XCTAssertFalse(isEligible(paths: [ssd], configured: configured(paths: ["\(ssd)/Foto iPhone"])))
    }

    func testDiskMountedInsideConfiguredPath_isNotEligible() {
        XCTAssertFalse(isEligible(paths: ["\(ssd)/Foto iPhone"], configured: configured(paths: [ssd])))
    }

    /// Un `hasPrefix` ingenuo direbbe che "/Volumes/SSD" contiene "/Volumes/SSD - Enri":
    /// il confronto deve avvenire per componenti di path.
    func testDifferentVolumeSharingATextualPrefix_isEligible() {
        XCTAssertTrue(isEligible(paths: ["/Volumes/SSD"], configured: configured(paths: [ssd])))
    }

    func testUnrelatedVolume_isEligible() {
        XCTAssertTrue(isEligible(paths: ["/Volumes/Chiavetta"], configured: configured(paths: [ssd, hdd])))
    }

    func testCaseDifferentPath_isNotEligible() {
        XCTAssertFalse(isEligible(paths: ["/volumes/ssd - enri"], configured: configured(paths: [ssd])))
    }

    func testTrailingSlashAndDoubleSlash_areNormalized() {
        XCTAssertFalse(isEligible(paths: ["\(ssd)/"], configured: configured(paths: [ssd])))
        XCTAssertFalse(isEligible(paths: ["/Volumes//BackupHDD"], configured: configured(paths: [hdd])))
    }

    /// Stesso nome di volume in forma Unicode decomposta (come lo restituiscono i filesystem
    /// Apple) contro forma precomposta: deve comunque risultare lo stesso path.
    func testDecomposedUnicodePath_isNotEligible() {
        let precomposed = "/Volumes/Citt\u{00E0}"      // "Città"
        let decomposed = "/Volumes/Citta\u{0300}"      // "Citta" + accento combinante
        XCTAssertFalse(isEligible(paths: [decomposed], configured: configured(paths: [precomposed])))
    }

    /// Un volume non montato riporta `MountPoint` = "": non deve combaciare con niente.
    func testEmptyMountPath_matchesNothing() {
        XCTAssertTrue(isEligible(paths: ["", "   "], configured: configured(paths: [ssd, hdd])))
    }

    /// Un path configurato vuoto non deve escludere tutti i dischi.
    func testEmptyConfiguredPath_doesNotExcludeEverything() {
        XCTAssertTrue(isEligible(paths: ["/Volumes/Chiavetta"], configured: configured(paths: [""])))
    }

    func testNothingConfigured_everythingIsEligible() {
        XCTAssertTrue(isEligible(paths: [ssd], configured: configured()))
    }

    /// Un disco con più volumi montati: basta che uno solo sia configurato per escluderlo.
    func testOneOfSeveralMountedPathsIsConfigured_isNotEligible() {
        XCTAssertFalse(isEligible(paths: ["/Volumes/Scratch", hdd], configured: configured(paths: [hdd])))
    }

    // MARK: - isEligible, confronto sull'UUID di volume

    /// Il caso che il solo confronto sui path non copre: disco di backup collegato ma **non
    /// montato** (espulso dal Finder senza scollegarlo, o filesystem che non monta). Verificato
    /// empiricamente il 2026-08-23 che dopo `diskutil unmount` l'entry perde `MountPoint` ma
    /// conserva `VolumeUUID`.
    func testUnmountedDiskWithConfiguredVolumeUUID_isNotEligible() {
        XCTAssertFalse(isEligible(uuids: [ssdUUID], configured: configured(paths: [ssd], uuids: [ssdUUID])))
    }

    func testUnmountedDiskWithUnknownVolumeUUID_isEligible() {
        XCTAssertTrue(isEligible(uuids: ["11111111-2222-3333-4444-555555555555"],
                                 configured: configured(paths: [ssd], uuids: [ssdUUID])))
    }

    func testVolumeUUIDComparisonIgnoresCaseAndSpaces() {
        XCTAssertFalse(isEligible(uuids: [ssdUUID.lowercased()], configured: configured(uuids: [ssdUUID])))
        // Stringa grezza con spazi, non pre-normalizzata: deve essere isEligible stessa a
        // normalizzarla internamente (altrimenti questa asserzione non testa nulla in più
        // della precedente).
        XCTAssertFalse(isEligible(uuids: ["  \(ssdUUID)  "], configured: configured(uuids: [ssdUUID])))
    }

    /// Un disco con più volumi: basta che uno solo abbia l'UUID configurato.
    func testOneOfSeveralVolumeUUIDsIsConfigured_isNotEligible() {
        XCTAssertFalse(isEligible(uuids: ["11111111-2222-3333-4444-555555555555", hddUUID],
                                  configured: configured(uuids: [hddUUID])))
    }

    func testNormalizedUUID() {
        XCTAssertEqual(DiskFormatter.normalizedUUID("  47e67c92-22d6  "), "47E67C92-22D6")
        XCTAssertNil(DiskFormatter.normalizedUUID(nil))
        XCTAssertNil(DiskFormatter.normalizedUUID("   "))
    }

    // MARK: - configuredBackupVolumes (fail-closed su bookmark non risolto)

    // `currentUUID` è sempre esplicito, senza default: un default tipo `currentUUID ?? uuid`
    // non potrebbe distinguere "non specificato" da "esplicitamente nil" (Swift risolve entrambi
    // allo stesso valore nel corpo della funzione) — un bug reale trovato scrivendo
    // `testConfiguredVolumes_currentVolumeUUIDMissingWhenSavedThrows` sotto, che con quel default
    // non testava affatto lo scenario "nessun UUID leggibile adesso".
    private func input(_ location: BookmarkManager.Location, hasBookmark: Bool,
                       path: String?, uuid: String?,
                       currentUUID: String?) -> DiskFormatter.ConfiguredLocationInput {
        DiskFormatter.ConfiguredLocationInput(location: location, hasSavedBookmark: hasBookmark,
                                              resolvedPath: path, savedVolumeUUID: uuid,
                                              currentVolumeUUID: currentUUID)
    }

    func testConfiguredVolumes_collectsPathsAndUUIDs() throws {
        let result = try DiskFormatter.configuredBackupVolumes(from: [
            input(.ssd, hasBookmark: true, path: ssd, uuid: ssdUUID.lowercased(), currentUUID: ssdUUID),
            input(.hdd, hasBookmark: true, path: hdd, uuid: nil, currentUUID: nil)
        ])
        XCTAssertEqual(result.paths, [ssd, hdd])
        XCTAssertEqual(result.volumeUUIDs, [ssdUUID])
    }

    func testConfiguredVolumes_locationNeverConfiguredIsIgnored() throws {
        let result = try DiskFormatter.configuredBackupVolumes(from: [
            input(.ssd, hasBookmark: true, path: ssd, uuid: nil, currentUUID: nil),
            input(.hdd, hasBookmark: false, path: nil, uuid: nil, currentUUID: nil)
        ])
        XCTAssertEqual(result.paths, [ssd])
    }

    /// Scenario reale: app aperta con l'SSD scollegato (il bookmark si risolve solo in
    /// `BookmarkManager.init()`, e non ci si riprova più). Senza fail-closed il filtro
    /// diventerebbe un no-op silenzioso e l'SSD di backup comparirebbe tra i formattabili.
    func testConfiguredVolumes_savedButUnresolvedBookmarkThrows() {
        XCTAssertThrowsError(try DiskFormatter.configuredBackupVolumes(from: [
            input(.ssd, hasBookmark: true, path: nil, uuid: ssdUUID, currentUUID: nil)
        ])) { error in
            guard case DiskFormatter.Failure.unresolvedBookmark(let location) = error else {
                return XCTFail("Errore inatteso: \(error)")
            }
            XCTAssertEqual(location, .ssd)
        }
    }

    /// Fail-closed anche quando l'UUID persistito ci sarebbe: un disco che non si monta più
    /// (filesystem danneggiato) non espone alcun UUID a `diskutil`, ed è proprio quello che
    /// verrebbe la tentazione di riformattare.
    func testConfiguredVolumes_unresolvedBookmarkThrowsEvenWithSavedUUID() {
        XCTAssertThrowsError(try DiskFormatter.configuredBackupVolumes(from: [
            input(.hdd, hasBookmark: true, path: nil, uuid: hddUUID, currentUUID: nil)
        ]))
    }

    /// Bug trovato nel secondo giro di review (2026-08-23): `BookmarkManager.urls` è uno
    /// snapshot preso una sola volta in `init()`. Se un volume di backup diventa irraggiungibile
    /// A METÀ SESSIONE (non solo all'avvio), il vecchio path risolto restava comunque presente
    /// nello snapshot e il disco reale — corrotto/scollegato — non esponeva più né MountPoint né
    /// VolumeUUID a `diskutil`, risultando quindi candidabile. Qui si simula esattamente il
    /// disallineamento: un path che sembra ancora risolto ma il cui volume montato lì ora ha un
    /// UUID diverso da quello persistito (un altro volume rimontato sullo stesso path non deve
    /// fare da alibi al disco di backup vero).
    func testConfiguredVolumes_currentVolumeUUIDMismatchThrows() {
        XCTAssertThrowsError(try DiskFormatter.configuredBackupVolumes(from: [
            input(.ssd, hasBookmark: true, path: ssd, uuid: ssdUUID, currentUUID: hddUUID)
        ])) { error in
            guard case DiskFormatter.Failure.unresolvedBookmark(let location) = error else {
                return XCTFail("Errore inatteso: \(error)")
            }
            XCTAssertEqual(location, .ssd)
        }
    }

    /// Stesso bug, variante "nessun UUID leggibile adesso": il volume che risponde al momento
    /// della chiamata non espone alcun VolumeUUID (es. filesystem danneggiato), pur avendone uno
    /// persistito da quando era stato configurato correttamente.
    func testConfiguredVolumes_currentVolumeUUIDMissingWhenSavedThrows() {
        XCTAssertThrowsError(try DiskFormatter.configuredBackupVolumes(from: [
            input(.ssd, hasBookmark: true, path: ssd, uuid: ssdUUID, currentUUID: nil)
        ]))
    }

    // MARK: - topology (parsing dell'output di `diskutil list -plist external`)

    /// Struttura verificata empiricamente il 2026-08-23 su "SSD - Enri" reale (ExFAT, MBR).
    private func exfatDiskEntry(mounted: Bool = true) -> [String: Any] {
        var partition: [String: Any] = [
            "Content": "Windows_NTFS",
            "DeviceIdentifier": "disk4s1",
            "VolumeName": "SSD - Enri",
            "VolumeUUID": ssdUUID,
            "Size": NSNumber(value: 1_000_203_091_968 as Int64)
        ]
        // Verificato: dopo `diskutil unmount` sparisce `MountPoint`, restano `VolumeName`/`VolumeUUID`.
        if mounted { partition["MountPoint"] = ssd }
        return [
            "Content": "FDisk_partition_scheme",
            "DeviceIdentifier": "disk4",
            "Size": NSNumber(value: 1_000_204_886_016 as Int64),
            "Partitions": [partition]
        ]
    }

    private func exfatPlist(mounted: Bool = true) -> [String: Any] {
        ["AllDisks": ["disk4", "disk4s1"], "AllDisksAndPartitions": [exfatDiskEntry(mounted: mounted)]]
    }

    /// Struttura verificata empiricamente il 2026-08-23 su un disco APFS reale: il container è un
    /// disco *sintetizzato* separato, i cui volumi vanno riattribuiti al disco fisico che lo ospita.
    private func apfsPlist() -> [String: Any] {
        [
            "AllDisks": ["disk6", "disk6s1", "disk6s2", "disk7", "disk7s1"],
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
                        "MountPoint": hdd,
                        "VolumeName": "BackupHDD",
                        "VolumeUUID": hddUUID,
                        "Size": NSNumber(value: 2_000_187_768_832 as Int64)
                    ]],
                    "Content": "EF57347C-0000-11AA-AA11-0030654",
                    "DeviceIdentifier": "disk7",
                    "Size": NSNumber(value: 2_000_187_768_832 as Int64)
                ]
            ]
        ]
    }

    func testTopology_partitionMountPointAndUUIDAreAttributedToWholeDisk() throws {
        let layout = try DiskFormatter.topology(fromListPlist: exfatPlist(), command: "diskutil list")
        XCTAssertEqual(layout.mountPaths["disk4"], [ssd])
        XCTAssertEqual(layout.volumeUUIDs["disk4"], [ssdUUID])
        XCTAssertEqual(layout.knownIdentifiers, ["disk4", "disk4s1"])
        XCTAssertTrue(layout.apfsHosts.isEmpty)
    }

    /// Il disco smontato non ha più path, ma resta riconoscibile dall'UUID.
    func testTopology_unmountedDiskStillExposesVolumeUUID() throws {
        let layout = try DiskFormatter.topology(fromListPlist: exfatPlist(mounted: false),
                                                command: "diskutil list")
        XCTAssertNil(layout.mountPaths["disk4"])
        XCTAssertEqual(layout.volumeUUIDs["disk4"], [ssdUUID])
        XCTAssertFalse(isEligible(paths: layout.mountPaths["disk4"] ?? [],
                                  uuids: layout.volumeUUIDs["disk4"] ?? [],
                                  configured: configured(paths: [ssd], uuids: [ssdUUID])))
    }

    /// Regressione centrale: senza la riattribuzione via `APFSPhysicalStores`, un HDD APFS già
    /// configurato risulterebbe senza path montati e verrebbe proposto per la formattazione.
    func testTopology_apfsVolumeIsAttributedToPhysicalHostDisk() throws {
        let layout = try DiskFormatter.topology(fromListPlist: apfsPlist(), command: "diskutil list")
        XCTAssertEqual(layout.mountPaths["disk6"], [hdd])
        XCTAssertEqual(layout.volumeUUIDs["disk6"], [hddUUID])
        XCTAssertNil(layout.mountPaths["disk7"])
        XCTAssertTrue(layout.apfsHosts.contains("disk6"))
    }

    func testConfiguredAPFSDisk_isNotEligible() throws {
        let layout = try DiskFormatter.topology(fromListPlist: apfsPlist(), command: "diskutil list")
        XCTAssertFalse(isEligible(paths: layout.mountPaths["disk6"] ?? [],
                                  uuids: layout.volumeUUIDs["disk6"] ?? [],
                                  configured: configured(paths: [hdd], uuids: [hddUUID])))
    }

    func testTopology_emptyMountPointsAreIgnored() throws {
        let plist: [String: Any] = ["AllDisks": ["disk8", "disk8s1"], "AllDisksAndPartitions": [[
            "DeviceIdentifier": "disk8",
            "MountPoint": "",
            "Partitions": [["DeviceIdentifier": "disk8s1", "Content": "Apple_HFS", "MountPoint": ""]]
        ]]]
        let layout = try DiskFormatter.topology(fromListPlist: plist, command: "diskutil list")
        XCTAssertNil(layout.mountPaths["disk8"])
        XCTAssertNil(layout.volumeUUIDs["disk8"])
    }

    /// Fail-closed: un plist di forma inattesa non deve tradursi in "nessun disco è di backup".
    func testTopology_unexpectedPlistShapeThrows() {
        for plist in [["Qualcosa": "di inatteso"], ["AllDisksAndPartitions": "non un array"]] {
            XCTAssertThrowsError(try DiskFormatter.topology(fromListPlist: plist,
                                                            command: "diskutil list")) { error in
                guard case DiskFormatter.Failure.unexpectedPlistShape = error else {
                    return XCTFail("Errore inatteso: \(error)")
                }
            }
        }
    }

    /// Un elenco vuoto è invece legittimo (nessun disco esterno collegato).
    func testTopology_emptyListIsNotAnError() throws {
        let layout = try DiskFormatter.topology(fromListPlist: ["AllDisksAndPartitions": []],
                                                command: "diskutil list")
        XCTAssertTrue(layout.mountPaths.isEmpty)
        XCTAssertTrue(layout.knownIdentifiers.isEmpty)
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

    // MARK: - wholeDiskIdentifier

    func testWholeDiskIdentifier() {
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk4"), "disk4")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk4s2"), "disk4")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk3s1s1"), "disk3")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "disk12s7"), "disk12")
        XCTAssertEqual(DiskFormatter.wholeDiskIdentifier(for: "qualcosaltro"), "qualcosaltro")
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
