# Migrazione credenziali S3 al Keychain — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Nota per questo progetto: `subagent-driven-development` e `executing-plans` non sono disponibili in questo ambiente. Esegui i task in sequenza in questa stessa sessione, con build+test verificati e un commit dopo ogni task, come fatto per tutti gli interventi precedenti (retry S3, cleanup multipart, restore, upload paralleli).

**Goal:** Spostare le credenziali S3 (Cubbit) da `rclone.conf` in chiaro al Keychain di macOS, senza rompere il flusso esistente di modifica manuale del file.

**Architecture:** `S3Syncer.readConfig()` prova prima il Keychain; se vuoto, legge `rclone.conf` come oggi e lo adotta silenziosamente nel Keychain (best-effort). Un bottone esplicito in Tools permette di forzare un nuovo adottamento quando l'utente modifica ancora il file. Nessuna astrazione oltre a un piccolo wrapper Keychain e all'estrazione di due funzioni pure già esistenti implicitamente (`validateEndpoint`, `readConfigFromFile`).

**Tech Stack:** Swift 5.x, SwiftUI, framework Security (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`), XCTest, macOS 13+. Tutto il codice di produzione in `AppBackupFoto/ContentView.swift` (convenzione consolidata del progetto).

## Global Constraints

- Nessun form di inserimento credenziali nell'app — l'utente continua a modificare `rclone.conf` a mano.
- Nessun rilevamento automatico di modifiche a `rclone.conf` — solo il bottone esplicito "Aggiorna da rclone.conf" forza un nuovo adottamento.
- L'adozione automatica nel Keychain (dentro `readConfig()`) è sempre best-effort (`try?`), mai bloccante.
- Nessun test automatico tocca il Keychain reale (rischio di prompt interattivi durante `xcodebuild test`).
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Nuovi test XCTest richiedono editing manuale di `AppBackupFoto.xcodeproj/project.pbxproj` (nessun gruppo auto-sync).

---

### Task 1: `S3Syncer.validateEndpoint` — estrazione e test

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:547-586` (funzione `S3Syncer.readConfig`)
- Create: `AppBackupFotoTests/ValidateEndpointTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Produces: `S3Syncer.validateEndpoint(_ raw: String) throws -> String` — private static. Rimuove uno slash finale, poi lancia `NSError(domain: "S3", code: 10, ...)` se non HTTPS, `NSError(domain: "S3", code: 13, ...)` se l'host non è in allow-list (`["s3.it.cubbit.org"]`), altrimenti ritorna l'endpoint pulito.

- [ ] **Step 1: Scrivi il test che fallisce**

Crea `AppBackupFotoTests/ValidateEndpointTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class ValidateEndpointTests: XCTestCase {
    func testHTTPEndpoint_isRejected() {
        XCTAssertThrowsError(try S3Syncer.validateEndpoint("http://s3.it.cubbit.org")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "S3")
            XCTAssertEqual(nsError.code, 10)
        }
    }

    func testHTTPSHostNotInAllowList_isRejected() {
        XCTAssertThrowsError(try S3Syncer.validateEndpoint("https://evil.example.com")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "S3")
            XCTAssertEqual(nsError.code, 13)
        }
    }

    func testHTTPSCubbitEndpoint_isAccepted() throws {
        let result = try S3Syncer.validateEndpoint("https://s3.it.cubbit.org")
        XCTAssertEqual(result, "https://s3.it.cubbit.org")
    }

    func testHTTPSCubbitEndpoint_trailingSlashIsRemoved() throws {
        let result = try S3Syncer.validateEndpoint("https://s3.it.cubbit.org/")
        XCTAssertEqual(result, "https://s3.it.cubbit.org")
    }
}
```

Nota: `validateEndpoint` è `private`, ma i test in `AppBackupFotoTests` vedono i membri `private` di tipi dichiarati in `AppBackupFoto` grazie a `@testable import AppBackupFoto` — stesso meccanismo già usato per `S3Syncer.isRetryable` in `S3SyncerRetryTests.swift` (anch'esso privato).

- [ ] **Step 2: Registra il file in project.pbxproj**

Genera due ID:
```bash
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
```

Nel file `AppBackupFoto.xcodeproj/project.pbxproj`, replicando esattamente il pattern già usato per `FileChunkReaderTests.swift`/`RunBoundedTests.swift`:

1. In `PBXBuildFile` (dentro `/* Begin PBXBuildFile section */ ... /* End PBXBuildFile section */`): aggiungi
   `		<ID_BUILDFILE> /* ValidateEndpointTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_FILEREF> /* ValidateEndpointTests.swift */; };`
2. In `PBXFileReference`: aggiungi
   `		<ID_FILEREF> /* ValidateEndpointTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ValidateEndpointTests.swift; sourceTree = "<group>"; };`
3. Nei `children` del gruppo `AppBackupFotoTests`: aggiungi
   `				<ID_FILEREF> /* ValidateEndpointTests.swift */,`
4. Nella `PBXSourcesBuildPhase` del target test: aggiungi
   `				<ID_BUILDFILE> /* ValidateEndpointTests.swift in Sources */,`

- [ ] **Step 3: Esegui i test per verificare che falliscano**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/ValidateEndpointTests 2>&1 | tail -30`

Expected: FAIL — `validateEndpoint` non esiste ancora su `S3Syncer`.

- [ ] **Step 4: Estrai `validateEndpoint` da `readConfig`**

In `AppBackupFoto/ContentView.swift`, la funzione `readConfig` (righe 547-586) contiene oggi:

```swift
    static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
            throw NSError(domain: "S3", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "rclone.conf ha permessi troppo aperti. Esegui nel Terminale:\nchmod 600 ~/.config/rclone/rclone.conf"])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var inSection = false
        var vals: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(remoteName)]" { inSection = true; continue }
            if t.hasPrefix("[") { if inSection { break }; continue }
            if inSection, t.contains("=") {
                let p = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 { vals[p[0]] = p[1] }
            }
        }
        guard let ak = vals["access_key_id"], let sk = vals["secret_access_key"],
              let ep = vals["endpoint"] else {
            throw NSError(domain: "S3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Credenziali '\(remoteName)' non trovate in rclone.conf"])
        }
        let cleanEp = ep.hasSuffix("/") ? String(ep.dropLast()) : ep
        guard cleanEp.hasPrefix("https://") else {
            throw NSError(domain: "S3", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "L'endpoint S3 deve usare HTTPS. Valore trovato: '\(cleanEp)'. Correggi rclone.conf."])
        }
        // Allow-list: se rclone.conf viene alterato per puntare a un host diverso da quello
        // atteso, le foto verrebbero caricate verso un endpoint arbitrario. Blocca finché
        // l'utente non conferma il nuovo host di proposito (aggiungendolo qui).
        let allowedHosts: Set<String> = ["s3.it.cubbit.org"]
        guard let host = URL(string: cleanEp)?.host, allowedHosts.contains(host) else {
            throw NSError(domain: "S3", code: 13, userInfo: [NSLocalizedDescriptionKey:
                "Endpoint S3 non riconosciuto: '\(cleanEp)'. Se hai cambiato provider di proposito, aggiorna la allow-list in S3Syncer.readConfig."])
        }
        return S3Config(accessKeyId: ak, secretAccessKey: sk, endpoint: cleanEp,
                        region: vals["region"] ?? "us-east-1", bucket: bucket)
    }
```

Sostituiscila con:

```swift
    static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
            throw NSError(domain: "S3", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "rclone.conf ha permessi troppo aperti. Esegui nel Terminale:\nchmod 600 ~/.config/rclone/rclone.conf"])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var inSection = false
        var vals: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(remoteName)]" { inSection = true; continue }
            if t.hasPrefix("[") { if inSection { break }; continue }
            if inSection, t.contains("=") {
                let p = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 { vals[p[0]] = p[1] }
            }
        }
        guard let ak = vals["access_key_id"], let sk = vals["secret_access_key"],
              let ep = vals["endpoint"] else {
            throw NSError(domain: "S3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Credenziali '\(remoteName)' non trovate in rclone.conf"])
        }
        let cleanEp = try validateEndpoint(ep)
        return S3Config(accessKeyId: ak, secretAccessKey: sk, endpoint: cleanEp,
                        region: vals["region"] ?? "us-east-1", bucket: bucket)
    }

    private static func validateEndpoint(_ raw: String) throws -> String {
        let cleanEp = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard cleanEp.hasPrefix("https://") else {
            throw NSError(domain: "S3", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "L'endpoint S3 deve usare HTTPS. Valore trovato: '\(cleanEp)'. Correggi rclone.conf."])
        }
        // Allow-list: se rclone.conf viene alterato per puntare a un host diverso da quello
        // atteso, le foto verrebbero caricate verso un endpoint arbitrario. Blocca finché
        // l'utente non conferma il nuovo host di proposito (aggiungendolo qui).
        let allowedHosts: Set<String> = ["s3.it.cubbit.org"]
        guard let host = URL(string: cleanEp)?.host, allowedHosts.contains(host) else {
            throw NSError(domain: "S3", code: 13, userInfo: [NSLocalizedDescriptionKey:
                "Endpoint S3 non riconosciuto: '\(cleanEp)'. Se hai cambiato provider di proposito, aggiorna la allow-list in S3Syncer.validateEndpoint."])
        }
        return cleanEp
    }
```

(Nota: il messaggio d'errore del code 13 ora dice "in S3Syncer.validateEndpoint" invece di "in S3Syncer.readConfig" — riflette dove va davvero aggiornata la allow-list.)

- [ ] **Step 5: Esegui i test per verificare che passino**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/ValidateEndpointTests 2>&1 | tail -30`

Expected: PASS — tutti e 4 i test verdi.

- [ ] **Step 6: Build completa, suite intera, commit**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -10 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `BUILD SUCCEEDED`, tutti i test esistenti passano (nessuna regressione — 45 test attesi: 41 + 4 nuovi).

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ValidateEndpointTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Extract S3Syncer.validateEndpoint (HTTPS + allow-list check), add tests"
```

---

### Task 2: Wrapper Keychain in `S3Syncer`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (aggiunta dentro `final class S3Syncer { ... }`, subito dopo la chiusura di `struct S3HTTPError`/`struct OrphanedMultipartUpload`, prima di `struct SyncResult` — o in qualunque punto dentro la classe prima del suo utilizzo; posizionala subito dopo `struct OrphanedMultipartUpload` per tenere insieme i piccoli tipi di supporto)

**Interfaces:**
- Consumes: `S3Config` (esistente, riga ~448).
- Produces: `S3Syncer.hasKeychainCredentials(remoteName: String = "Cubbit") -> Bool` (static, internal); `S3Syncer.writeToKeychain(config: S3Config, remoteName: String) throws` (static, internal); `S3Syncer.readFromKeychain(remoteName: String) -> KeychainCredentials?` (static, private) — usata da Task 3.

Nessun test automatico (Keychain reale). Verifica: solo build verde.

- [ ] **Step 1: Aggiungi il wrapper Keychain**

In `AppBackupFoto/ContentView.swift`, dentro `final class S3Syncer { ... }`, subito dopo la chiusura di `struct OrphanedMultipartUpload` (le tre righe che chiudono quello struct, prima di `struct SyncResult`):

```swift

    private struct KeychainCredentials: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let endpoint: String
        let region: String
    }

    private static func keychainQuery(remoteName: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AppBackupFoto",
         kSecAttrAccount as String: remoteName]
    }

    static func hasKeychainCredentials(remoteName: String = "Cubbit") -> Bool {
        readFromKeychain(remoteName: remoteName) != nil
    }

    private static func readFromKeychain(remoteName: String) -> KeychainCredentials? {
        var query = keychainQuery(remoteName: remoteName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeychainCredentials.self, from: data)
    }

    // internal (non private): richiamata anche dal bottone "Aggiorna da rclone.conf" in ToolsSheet.
    static func writeToKeychain(config: S3Config, remoteName: String) throws {
        let creds = KeychainCredentials(accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey,
                                         endpoint: config.endpoint, region: config.region)
        let data = try JSONEncoder().encode(creds)
        let query = keychainQuery(remoteName: remoteName)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
                throw NSError(domain: "S3", code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Impossibile salvare le credenziali nel Keychain"])
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: "S3", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile aggiornare le credenziali nel Keychain"])
        }
    }
```

- [ ] **Step 2: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`. Se il compilatore lamenta `Security` non importato: verifica l'inizio del file — `import Foundation` è già presente e il framework Security fa parte del namespace di sistema disponibile senza `import` esplicito su macOS quando si usano solo i tipi C (`SecItemAdd` ecc.) tramite Foundation; se necessario aggiungi `import Security` in cima al file, accanto agli altri `import`.

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Add S3Syncer Keychain wrapper (read/write/hasCredentials)"
```

---

### Task 3: `readConfig()` — Keychain prima, poi file con adozione silenziosa

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (funzione `S3Syncer.readConfig`, riscritta dal Task 1)

**Interfaces:**
- Consumes: `S3Syncer.readFromKeychain(remoteName:)`, `S3Syncer.writeToKeychain(config:remoteName:)`, `S3Syncer.validateEndpoint(_:)` (tutte da Task 1/2).
- Produces: `S3Syncer.readConfigFromFile(remoteName: String, bucket: String) throws -> S3Config` (static, **internal**, non `private` — richiamata anche dal bottone "Aggiorna da rclone.conf" in Task 4). `readConfig(remoteName:bucket:)` resta pubblica, stessa firma di oggi — nessun call site esistente cambia.

Nessun test automatico (dipende dal Keychain reale). Verifica: build + suite completa esistente verde (nessuna regressione sugli ~8 call site esistenti di `readConfig`).

- [ ] **Step 1: Rinomina il corpo attuale di `readConfig` in `readConfigFromFile`, e riscrivi `readConfig`**

Dopo il Task 1, `readConfig` è:

```swift
    static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
            throw NSError(domain: "S3", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "rclone.conf ha permessi troppo aperti. Esegui nel Terminale:\nchmod 600 ~/.config/rclone/rclone.conf"])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var inSection = false
        var vals: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(remoteName)]" { inSection = true; continue }
            if t.hasPrefix("[") { if inSection { break }; continue }
            if inSection, t.contains("=") {
                let p = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 { vals[p[0]] = p[1] }
            }
        }
        guard let ak = vals["access_key_id"], let sk = vals["secret_access_key"],
              let ep = vals["endpoint"] else {
            throw NSError(domain: "S3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Credenziali '\(remoteName)' non trovate in rclone.conf"])
        }
        let cleanEp = try validateEndpoint(ep)
        return S3Config(accessKeyId: ak, secretAccessKey: sk, endpoint: cleanEp,
                        region: vals["region"] ?? "us-east-1", bucket: bucket)
    }
```

Sostituiscila con:

```swift
    static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        if let creds = readFromKeychain(remoteName: remoteName) {
            let cleanEp = try validateEndpoint(creds.endpoint)
            return S3Config(accessKeyId: creds.accessKeyId, secretAccessKey: creds.secretAccessKey,
                            endpoint: cleanEp, region: creds.region, bucket: bucket)
        }
        let config = try readConfigFromFile(remoteName: remoteName, bucket: bucket)
        try? writeToKeychain(config: config, remoteName: remoteName)
        return config
    }

    static func readConfigFromFile(remoteName: String, bucket: String) throws -> S3Config {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
            throw NSError(domain: "S3", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "rclone.conf ha permessi troppo aperti. Esegui nel Terminale:\nchmod 600 ~/.config/rclone/rclone.conf"])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var inSection = false
        var vals: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(remoteName)]" { inSection = true; continue }
            if t.hasPrefix("[") { if inSection { break }; continue }
            if inSection, t.contains("=") {
                let p = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 { vals[p[0]] = p[1] }
            }
        }
        guard let ak = vals["access_key_id"], let sk = vals["secret_access_key"],
              let ep = vals["endpoint"] else {
            throw NSError(domain: "S3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Credenziali '\(remoteName)' non trovate in rclone.conf"])
        }
        let cleanEp = try validateEndpoint(ep)
        return S3Config(accessKeyId: ak, secretAccessKey: sk, endpoint: cleanEp,
                        region: vals["region"] ?? "us-east-1", bucket: bucket)
    }
```

- [ ] **Step 2: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Suite completa**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: tutti i test passano (45 test — nessuna regressione: `ValidateEndpointTests` continua a passare dato che `readConfigFromFile` usa lo stesso `validateEndpoint`).

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "S3Syncer.readConfig: try Keychain first, fall back to rclone.conf with silent adoption"
```

**Nota per l'utente**: da questo commit in poi, il primo avvio dell'app dopo l'aggiornamento adotta automaticamente le credenziali esistenti nel Keychain (silenzioso, nessuna azione richiesta). Verifica manuale suggerita: dopo aver aggiornato l'app, aprire Tools → Diagnostica e controllare che le credenziali siano ancora visibili correttamente (comportamento invariato dall'esterno).

---

### Task 4: UI — bottone "Aggiorna da rclone.conf" ed etichetta origine

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `ToolsSheet`, `GroupBox("S3 — Cubbit")`, circa righe 2978-3023 attuali)

**Interfaces:**
- Consumes: `S3Syncer.hasKeychainCredentials()`, `S3Syncer.readConfigFromFile(remoteName:bucket:)`, `S3Syncer.writeToKeychain(config:remoteName:)` (da Task 2/3).

Nessun test automatico (UI + Keychain reale). Verifica: build verde + verifica manuale.

- [ ] **Step 1: Aggiungi l'etichetta origine e il bottone**

In `AppBackupFoto/ContentView.swift`, dentro `ToolsSheet.body`, la `GroupBox("S3 — Cubbit")` (circa riga 2978) contiene oggi, subito dopo `if let cfg = try? S3Syncer.readConfig() {`:

```swift
                    if let cfg = try? S3Syncer.readConfig() {
                        DiagRow(label: "Endpoint",  value: cfg.endpoint)
```

Aggiungi l'etichetta origine subito prima di `DiagRow(label: "Endpoint", ...)`:

```swift
                    if let cfg = try? S3Syncer.readConfig() {
                        Text(S3Syncer.hasKeychainCredentials() ? "Origine: Keychain" : "Origine: rclone.conf")
                            .font(.caption2).foregroundStyle(.secondary)
                        DiagRow(label: "Endpoint",  value: cfg.endpoint)
```

Poi, il bottone "Apri rclone.conf in TextEdit" esistente (circa riga 3012):

```swift
                        Button("Apri rclone.conf in TextEdit") {
                            confirmReveal {
                                let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
```

Aggiungi subito dopo (stesso livello, dentro lo stesso `VStack`):

```swift
                        Button("Aggiorna da rclone.conf") {
                            let a = NSAlert()
                            a.messageText = "Sovrascrivere le credenziali salvate?"
                            a.informativeText = "Le credenziali attualmente nel Keychain verranno sostituite con quelle lette ora da rclone.conf."
                            a.alertStyle = .warning
                            a.addButton(withTitle: "Continua")
                            a.addButton(withTitle: "Annulla")
                            guard a.runModal() == .alertFirstButtonReturn else { return }
                            do {
                                let config = try S3Syncer.readConfigFromFile(remoteName: "Cubbit", bucket: "backupfoto")
                                try S3Syncer.writeToKeychain(config: config, remoteName: "Cubbit")
                                let ok = NSAlert()
                                ok.messageText = "Credenziali aggiornate nel Keychain."
                                ok.runModal()
                            } catch {
                                let err = NSAlert()
                                err.messageText = "Errore"
                                err.informativeText = error.localizedDescription
                                err.alertStyle = .critical
                                err.runModal()
                            }
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
```

- [ ] **Step 2: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Add 'Aggiorna da rclone.conf' button and credential origin label in ToolsSheet"
```

**Nota per l'utente**: verifica manuale in app — aprire hamburger → Tools → Diagnostica, controllare che "Origine" mostri il valore corretto, provare "Aggiorna da rclone.conf" (con conferma) e controllare l'alert di esito.

---

### Task 5: `ReviewEngine.checkRcloneConfPermissions()` — aggiornato

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1704-1717` (funzione `checkRcloneConfPermissions`)

**Interfaces:**
- Consumes: `S3Syncer.hasKeychainCredentials(remoteName:)` (da Task 2).

Nessun nuovo test automatico. Verifica: build + suite completa esistente verde (`ReviewEngineIntegritySampleTests.swift` non testa direttamente questa funzione, ma verifica che non regredisca nulla).

- [ ] **Step 1: Aggiorna la funzione**

In `AppBackupFoto/ContentView.swift`, `checkRcloneConfPermissions` (riga 1704) è oggi:

```swift
    private func checkRcloneConfPermissions() -> ReviewFinding {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "File non trovato in ~/.config/rclone/rclone.conf")
        }
        let perms = attrs[.posixPermissions] as? Int ?? 0
        if perms & 0o077 != 0 {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "Permessi troppo aperti (\(String(perms, radix: 8))) — esegui: chmod 600 ~/.config/rclone/rclone.conf")
        }
        return ReviewFinding(title: "Permessi rclone.conf", ok: true,
            detail: "0600 — solo il proprietario può leggere/scrivere")
    }
```

Sostituiscila con:

```swift
    private func checkRcloneConfPermissions() -> ReviewFinding {
        if S3Syncer.hasKeychainCredentials(remoteName: "Cubbit") {
            return ReviewFinding(title: "Credenziali S3", ok: true,
                detail: "Salvate nel Keychain — rclone.conf non è più necessario")
        }
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "File non trovato in ~/.config/rclone/rclone.conf")
        }
        let perms = attrs[.posixPermissions] as? Int ?? 0
        if perms & 0o077 != 0 {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "Permessi troppo aperti (\(String(perms, radix: 8))) — esegui: chmod 600 ~/.config/rclone/rclone.conf")
        }
        return ReviewFinding(title: "Permessi rclone.conf", ok: true,
            detail: "0600 — solo il proprietario può leggere/scrivere")
    }
```

- [ ] **Step 2: Build e suite completa**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -10 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `BUILD SUCCEEDED`, tutti i 45 test passano.

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "ReviewEngine: skip rclone.conf permission check once credentials are in Keychain"
```

---

### Task 6: Aggiorna la documentazione

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

- [ ] **Step 1: Aggiorna la sezione S3Syncer in `Docs/CLAUDE.md`**

Trova la riga:

```
- Legge credenziali da `~/.config/rclone/rclone.conf`, sezione `[Cubbit]`
```

Sostituiscila con:

```
- **Credenziali nel Keychain**: `readConfig()` prova prima il Keychain (`kSecAttrService: "AppBackupFoto"`), fallback a `~/.config/rclone/rclone.conf` (sezione `[Cubbit]`) se vuoto, con adozione silenziosa best-effort nel Keychain al primo utilizzo utile. Nessun form di inserimento credenziali nell'app: l'utente continua a modificare `rclone.conf` a mano e forza un nuovo adottamento con il bottone "Aggiorna da rclone.conf" in Tools (nessun rilevamento automatico delle modifiche al file — scelta deliberata, coerente con "mai azioni automatiche su dati sensibili").
```

- [ ] **Step 2: Aggiorna la tabella "Stato attuale"**

Trova:

```
| Test automatici | ✅ 41 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3, lettura file a blocchi, concorrenza limitata) |
```

Sostituisci con (verifica il conteggio reale con `xcodebuild ... test` prima di scrivere il numero — atteso 41 + 4 = 45):

```
| Test automatici | ✅ 45 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3, lettura file a blocchi, concorrenza limitata, validazione endpoint S3) |
```

- [ ] **Step 3: Aggiorna `Docs/ROADMAP.md`**

Trova:

```
10. **Credenziali S3 in un file di testo, non nel Keychain** — `~/.config/rclone/rclone.conf` funziona ed è protetto da permessi POSIX 0600, ma il Keychain è pensato esattamente per questo.
    *Effort: medio · migrazione a Security framework, fallback di lettura da rclone.conf per compatibilità*
```

Sostituisci con:

```
10. ✅ **Fatto (2026-08-02) — Credenziali S3 in un file di testo, non nel Keychain.** `readConfig()` prova prima il Keychain, fallback a rclone.conf con adozione silenziosa; bottone esplicito "Aggiorna da rclone.conf" in Tools per chi continua a modificare il file a mano. Vedi `Docs/superpowers/specs/2026-08-02-keychain-migration-design.md`.
```

Trova la sezione "Da dove partire":

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #9 anteprima S3. Restano 3 interventi con bozza di ricerca già pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`: **#5 cifratura lato client** (il più delicato — tocca decisioni di sicurezza/UX che richiedono una discussione attenta con l'utente), **#10 Keychain** (migrazione credenziali, medio rischio), **#7 scheduling** (automazione backup). Il resto della lista (punti 8, 11-20) è ordinabile in base al tempo che si vuole investirci.
```

Sostituisci con:

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #9 anteprima S3, #10 Keychain. Restano 2 interventi con bozza di ricerca già pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`: **#5 cifratura lato client** (il più delicato — tocca decisioni di sicurezza/UX che richiedono una discussione attenta con l'utente) e **#7 scheduling** (automazione backup, ricerca non ancora approfondita). Il resto della lista (punti 8, 11-20) è ordinabile in base al tempo che si vuole investirci.
```

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: S3 credentials Keychain migration shipped"
```

---

## Riepilogo finale per l'utente

Dopo tutti i task: build verde, 45 test passano, 6 commit (uno per task). Restano da fare, manualmente e senza fretta:
1. Avviare l'app aggiornata e controllare in Tools → Diagnostica che "Origine" passi da "rclone.conf" a "Keychain" al primo avvio utile.
2. Rinominare temporaneamente `rclone.conf` (es. `mv rclone.conf rclone.conf.bak`) e confermare che l'app continui a funzionare — legge dal Keychain, non serve più il file.
3. Ripristinare il file, modificarne un valore, premere "Aggiorna da rclone.conf" in Tools e confermare che il Keychain rifletta il cambiamento.
