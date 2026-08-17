import XCTest
@testable import AppBackupFoto

/// Blinda i tre vincoli non negoziabili del compose file di Immich (roadmap #29):
/// bind solo su 127.0.0.1, dati propri di Immich sul disco interno, libreria SSD in sola lettura.
/// Nessun container viene avviato: `composeFileContent` è una funzione pura apposta per questo.
///
/// **I test parsano il YAML con un parser vero** invece di cercare sottostringhe. Motivo, da una
/// revisione del 2026-08-17: la prima versione usava `contains(...)` e passava a colori su un file
/// che `docker compose` avrebbe rifiutato al parsing (la short syntax `- "src":"dst":ro` non è
/// YAML valido — uno scalare quotato non può essere seguito da altro testo sulla stessa riga).
/// Otto test verdi su un file irrimediabilmente rotto. Un assert su sottostringhe non può
/// accorgersi di un errore di sintassi: solo un parser può.
///
/// Il parser è Psych, incluso in `/usr/bin/ruby` — nessuna dipendenza nuova aggiunta al progetto.
/// Apple ha deprecato Ruby di sistema: se un giorno sparisse, i test che ne dipendono si
/// auto-skippano (`XCTSkip`) invece di fallire a sproposito, e restano comunque gli assert
/// testuali che non richiedono parsing.
final class ImmichComposeFileTests: XCTestCase {
    private let ssdPath = "/Volumes/SSD - Enri/Foto iPhone"
    private static let rubyPath = "/usr/bin/ruby"

    // MARK: - Parsing helper

    /// Converte il YAML in JSON con un parser reale e lo rilegge come dizionario Swift.
    private func parseYAML(_ yaml: String) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: Self.rubyPath) else {
            throw XCTSkip("\(Self.rubyPath) non disponibile: parsing YAML reale non eseguibile su questo sistema")
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-\(UUID().uuidString).yml")
        try yaml.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.rubyPath)
        process.arguments = ["-ryaml", "-rjson", "-e",
                             "puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))",
                             tempFile.path]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? "errore sconosciuto"
            XCTFail("Il compose file generato non è YAML valido:\n\(message)\n\n--- YAML ---\n\(yaml)")
            throw NSError(domain: "ImmichComposeFileTests", code: 1)
        }
        guard let parsed = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            XCTFail("Output del parser non interpretabile come dizionario")
            throw NSError(domain: "ImmichComposeFileTests", code: 2)
        }
        return parsed
    }

    private func service(_ name: String, in parsed: [String: Any]) throws -> [String: Any] {
        let services = try XCTUnwrap(parsed["services"] as? [String: Any], "chiave 'services' mancante")
        return try XCTUnwrap(services[name] as? [String: Any], "servizio '\(name)' mancante")
    }

    /// Solo le entry di volume in long syntax (dizionari), ignorando gli scalari come
    /// `/etc/localtime:/etc/localtime:ro`.
    private func bindMounts(of service: [String: Any]) -> [[String: Any]] {
        (service["volumes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private func mount(targeting target: String, in service: [String: Any]) -> [String: Any]? {
        bindMounts(of: service).first { $0["target"] as? String == target }
    }

    private func yaml(_ path: String? = nil) -> String {
        ImmichManager.shared.composeFileContent(sourceLibraryPath: path ?? ssdPath)
    }

    // MARK: - Sintassi

    /// Test di regressione del bug bloccante trovato in revisione: prima di qualunque assert
    /// sul contenuto, il file deve essere sintatticamente valido.
    func testGeneratedComposeIsValidYAML() throws {
        let parsed = try parseYAML(yaml())
        XCTAssertEqual(parsed["name"] as? String, "appbackupfoto-immich")
    }

    func testPathContainingColonSurvivesParsing() throws {
        // Caso reale su macOS: una cartella che in Finder si chiama "Foto/2020" ha path
        // POSIX "Foto:2020". Con la short syntax `src:dst:mode` questo path romperebbe la
        // entry anche se quotato — è il motivo per cui si usa la long syntax.
        let colonPath = "/Volumes/SSD - Enri/Foto:2020"
        let server = try service("immich-server", in: try parseYAML(yaml(colonPath)))
        XCTAssertEqual(mount(targeting: "/external-ssd", in: server)?["source"] as? String, colonPath)
    }

    func testPathWithQuoteIsEscapedAndDoesNotBreakYAML() throws {
        let nasty = "/Volumes/SSD \"strano\"/Foto"
        let server = try service("immich-server", in: try parseYAML(yaml(nasty)))
        XCTAssertEqual(mount(targeting: "/external-ssd", in: server)?["source"] as? String, nasty,
                       "Il path deve tornare identico dopo un giro di escape e parsing")
    }

    func testYamlQuotedEscapesBackslashes() {
        XCTAssertEqual(ImmichManager.yamlQuoted("a\\b"), "\"a\\\\b\"")
    }

    // MARK: - Rete: solo loopback

    func testServerPortIsPublishedOnLocalhostOnly() throws {
        let server = try service("immich-server", in: try parseYAML(yaml()))
        XCTAssertEqual(server["ports"] as? [String], ["127.0.0.1:2283:2283"],
                       "La porta del server deve essere pubblicata solo su 127.0.0.1")
        XCTAssertFalse(yaml().contains("0.0.0.0"),
                       "Il server non deve mai essere esposto su 0.0.0.0")
    }

    // MARK: - Libreria SSD: sola lettura

    func testSourceLibraryIsMountedReadOnly() throws {
        let server = try service("immich-server", in: try parseYAML(yaml()))
        let mount = try XCTUnwrap(self.mount(targeting: "/external-ssd", in: server),
                                  "Manca il mount della libreria esterna")
        XCTAssertEqual(mount["type"] as? String, "bind")
        XCTAssertEqual(mount["source"] as? String, ssdPath)
        XCTAssertEqual(mount["read_only"] as? Bool, true,
                       "La libreria sull'SSD deve essere montata in sola lettura")
    }

    func testSourceLibraryIsNeverMountedWritable() throws {
        let text = yaml()
        XCTAssertFalse(text.contains(":rw"), "Nessun mount esplicitamente scrivibile")
        let server = try service("immich-server", in: try parseYAML(text))
        let mount = try XCTUnwrap(self.mount(targeting: "/external-ssd", in: server))
        XCTAssertNotEqual(mount["read_only"] as? Bool, false,
                          "read_only non deve mai essere false sulla libreria sorgente")
        // La cartella sorgente non deve nemmeno essere riusata come storage di Immich.
        for other in bindMounts(of: server) where other["target"] as? String != "/external-ssd" {
            XCTAssertNotEqual(other["source"] as? String, ssdPath,
                              "La libreria sorgente non deve mai essere usata come storage scrivibile")
        }
    }

    // MARK: - Dati sul disco interno

    func testAllDataVolumesLiveUnderDataDir() throws {
        let parsed = try parseYAML(yaml())
        let dataPath = ImmichManager.shared.dataDir.path
        let expected = [("immich-server", "/data"),
                        ("immich-machine-learning", "/cache"),
                        ("immich-database", "/var/lib/postgresql/data")]
        for (serviceName, target) in expected {
            let svc = try service(serviceName, in: parsed)
            let mount = try XCTUnwrap(self.mount(targeting: target, in: svc),
                                      "Manca il volume \(target) in \(serviceName)")
            let source = try XCTUnwrap(mount["source"] as? String)
            XCTAssertTrue(source.hasPrefix(dataPath + "/"),
                          "Il volume \(target) deve stare sotto dataDir (disco interno), invece è \(source)")
        }
    }

    func testDataDirIsOnInternalDiskNotOnExternalVolumes() {
        let dataPath = ImmichManager.shared.dataDir.path
        XCTAssertFalse(dataPath.hasPrefix("/Volumes/"),
                       "I dati di Immich non devono mai finire su un volume esterno")
        XCTAssertTrue(dataPath.contains("Application Support/AppBackupFoto/immich"))
    }

    // MARK: - Validazione del path passato a Colima

    func testLibraryPathWithColonIsRejected() {
        // Colima fa SplitN(mount, ":", 3): un path con ":" verrebbe troncato, e uno che
        // finisce per ":w" verrebbe montato in scrittura dentro la VM. Meglio fermarsi prima.
        XCTAssertThrowsError(try ImmichManager.validateLibraryPath("/Volumes/SSD - Enri/Foto:2020"))
        XCTAssertThrowsError(try ImmichManager.validateLibraryPath("/Volumes/SSD - Enri/Foto:w"))
    }

    func testNormalLibraryPathIsAccepted() {
        XCTAssertNoThrow(try ImmichManager.validateLibraryPath(ssdPath))
        XCTAssertNoThrow(try ImmichManager.validateLibraryPath("/Volumes/SSD - Enri"))
    }

    // MARK: - Struttura

    func testAllFourServicesArePresent() throws {
        let services = try XCTUnwrap(try parseYAML(yaml())["services"] as? [String: Any])
        XCTAssertEqual(Set(services.keys),
                       ["immich-server", "immich-machine-learning", "immich-redis", "immich-database"])
    }
}
