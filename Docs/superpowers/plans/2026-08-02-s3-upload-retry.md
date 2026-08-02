# S3 Upload Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere retry con backoff esponenziale (3 tentativi, 1s/2s) sugli upload S3 di AppBackupFoto — sul singolo PUT e su ogni singola parte multipart — distinguendo errori permanenti (HTTP 4xx) da errori transitori (rete, HTTP 5xx) da ritentare.

**Architecture:** Un nuovo tipo di errore `S3HTTPError` che porta il codice HTTP reale, una funzione pura `isRetryable(_:)` per classificarlo, e un helper generico `retrying(key:onStatus:operation:)` che avvolge ogni singola chiamata HTTP di upload (`put`, init/parte/complete di `multipart`). Tutto dentro `final class S3Syncer` in `AppBackupFoto/ContentView.swift`, nessun nuovo file di produzione.

**Tech Stack:** Swift 5.x, `URLSession` async/await, XCTest, macOS 13+.

## Global Constraints

- Tutto il codice nuovo va in `AppBackupFoto/ContentView.swift`, dentro `final class S3Syncer` — nessuno split di file.
- Fino a 3 tentativi totali (1 iniziale + 2 retry), attese 1s poi 2s tra un tentativo e l'altro (backoff esponenziale: `pow(2.0, Double(attempt - 1))`).
- Ritenta: `URLError` (rete/timeout), `S3HTTPError` con codice fuori dall'intervallo 400-499.
- Non ritenta: `S3HTTPError` con codice 400-499, `CancellationError`, qualunque altro errore (es. URL malformato).
- Prima di ogni attesa di backoff, controlla `cancelled`/`Task.isCancelled` e propaga subito se l'utente ha interrotto — stessa garanzia già data al fix del 2026-07-30 per `RestoreEngine`.
- Un file fallito dopo tutti i tentativi resta contato in `result.errors` come oggi — nessuna modifica a `JobStats`/`StatsPanel`/`CompletionSheet`.
- La firma pubblica `sync(from:config:onStatus:onProgress:)` non cambia — solo le funzioni private `upload`/`put`/`multipart` guadagnano un parametro `onStatus`.
- Nessun retry sui download (`downloadToTemp`) o sulle chiamate di lista (`listPage`/`listAll`) — fuori scope.

---

## Task 1: `S3HTTPError` e `isRetryable(_:)`, con test

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:431` (dentro `final class S3Syncer`, subito dopo `struct S3Config`), e vicino a `topLevelFolders(fromKeys:)` per `isRetryable`
- Test: `AppBackupFotoTests/S3SyncerRetryTests.swift` (nuovo)

**Interfaces:**
- Produce: `S3Syncer.S3HTTPError` (struct, `Error`, campi `statusCode: Int`, `message: String`); `static func S3Syncer.isRetryable(_ error: Error) -> Bool`. Usati dal Task 2 (`retrying`) e dal Task 3 (i punti che lanciano errori HTTP).

- [ ] **Step 1: Scrivere i test (falliranno finché i tipi non esistono)**

Crea `AppBackupFotoTests/S3SyncerRetryTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class S3SyncerRetryTests: XCTestCase {
    func testURLError_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(URLError(.notConnectedToInternet)))
    }

    func testHTTP403_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 403, message: "Forbidden")))
    }

    func testHTTP404_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 404, message: "Not Found")))
    }

    func testHTTP500_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 500, message: "Server Error")))
    }

    func testHTTP503_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 503, message: "Unavailable")))
    }

    func testGenericNSError_isNotRetryable() {
        let error = NSError(domain: "S3", code: 12, userInfo: [NSLocalizedDescriptionKey: "URL non valido"])
        XCTAssertFalse(S3Syncer.isRetryable(error))
    }

    func testCancellationError_isNotRetryable() {
        XCTAssertFalse(S3Syncer.isRetryable(CancellationError()))
    }
}
```

- [ ] **Step 2: Registrare il file nel target di test**

Stesso schema già usato per gli altri file di test in questa sessione (`PBXBuildFile`, `PBXFileReference`, entry nel gruppo `AppBackupFotoTests`, entry nel `PBXSourcesBuildPhase` del target test, in `AppBackupFoto.xcodeproj/project.pbxproj`):

```bash
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
```

Usa il primo ID per `PBXBuildFile`/Sources, il secondo per `PBXFileReference`/gruppo.

- [ ] **Step 3: Eseguire i test e verificare che falliscano**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/S3SyncerRetryTests 2>&1 | tail -20`

Expected: FAIL — `cannot find 'S3HTTPError' in scope` / `cannot find 'isRetryable' in scope`.

- [ ] **Step 4: Implementare `S3HTTPError` e `isRetryable`**

Dentro `final class S3Syncer`, subito dopo la chiusura di `struct S3Config` (riga 431 in poi, prima di `static func readConfig`), aggiungi:

```swift

    struct S3HTTPError: Error {
        let statusCode: Int
        let message: String
    }
```

Poi, subito dopo `static func topLevelFolders(fromKeys keys: [String]) -> [String] { ... }` (già esistente, funzione pura per il restore), aggiungi:

```swift

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let httpError = error as? S3HTTPError { return !(400...499).contains(httpError.statusCode) }
        if error is URLError { return true }
        return false
    }
```

- [ ] **Step 5: Eseguire i test e verificare che passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/S3SyncerRetryTests 2>&1 | tail -20`

Expected: PASS — 7 test eseguiti, 0 falliti.

- [ ] **Step 6: Eseguire l'intera suite per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS — 34 test totali (27 già esistenti + 7 nuovi).

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerRetryTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add S3HTTPError and isRetryable(_:) with tests"
```

---

## Task 2: `retrying(key:onStatus:operation:)` — helper generico

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `final class S3Syncer`, subito prima di `private func upload`)

**Interfaces:**
- Consuma: `S3Syncer.isRetryable(_:)` (Task 1), `cancelled` (proprietà esistente di `S3Syncer`).
- Produce: `private func retrying<T>(key: String, maxAttempts: Int = 3, onStatus: @escaping (String) -> Void, operation: () async throws -> T) async throws -> T`, usata dal Task 3.

Nessun test automatico dedicato (richiede simulare fallimenti di rete reali) — build come verifica, poi verificato end-to-end manualmente nel Task 3.

- [ ] **Step 1: Individuare il punto di inserimento**

Run: `grep -n "private func upload(url: URL, key: String, config: S3Config) async throws" AppBackupFoto/ContentView.swift`

Expected: una riga, subito sopra `private func put`.

- [ ] **Step 2: Aggiungere `retrying`**

Subito prima di `private func upload(url: URL, key: String, config: S3Config) async throws {`, inserisci:

```swift

    private func retrying<T>(key: String, maxAttempts: Int = 3,
                              onStatus: @escaping (String) -> Void,
                              operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard !cancelled, !Task.isCancelled else { throw error }
                guard attempt < maxAttempts, S3Syncer.isRetryable(error) else { throw error }
                let delaySec = pow(2.0, Double(attempt - 1))   // 1s, 2s
                attempt += 1
                let msg = "Errore di rete su \(key), riprovo tra \(Int(delaySec))s (tentativo \(attempt)/\(maxAttempts))"
                DispatchQueue.main.async { onStatus(msg) }
                try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **` (la funzione non è ancora chiamata da nessuno, ma deve compilare da sola).

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add S3Syncer.retrying generic backoff helper"
```

---

## Task 3: Wire `retrying`/`S3HTTPError` in `put`, `multipart`, `upload`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:558-620` (`sync`, un solo call site da aggiornare)
- Modify: `AppBackupFoto/ContentView.swift:666-763` (`upload`, `put`, `multipart`, riscritte)

**Interfaces:**
- Consuma: `retrying(key:onStatus:operation:)` (Task 2), `S3HTTPError` (Task 1).
- Produce: `upload(url:key:config:onStatus:)` e `multipart(url:key:config:onStatus:)` con la nuova firma — non consumate da nessun task successivo (ultimo pezzo della catena), ma **rompono** la firma precedente: verificare che l'unico chiamante (`sync`) sia aggiornato nello stesso task.

- [ ] **Step 1: Aggiornare l'unico call site in `sync`**

Cambia:

```swift
                do {
                    try await upload(url: item.url, key: item.key, config: config)
                    result.uploaded += 1
                    result.uploadedBytes += item.size
                } catch {
                    result.errors += 1
                }
```

in:

```swift
                do {
                    try await upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
                    result.uploaded += 1
                    result.uploadedBytes += item.size
                } catch {
                    result.errors += 1
                }
```

- [ ] **Step 2: Riscrivere `upload`**

Cambia:

```swift
    private func upload(url: URL, key: String, config: S3Config) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 64 * 1024 * 1024 {
            try await multipart(url: url, key: key, config: config)
        } else {
            let data = try Data(contentsOf: url)
            try await put(data: data, key: key, config: config)
        }
    }
```

in:

```swift
    private func upload(url: URL, key: String, config: S3Config, onStatus: @escaping (String) -> Void) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 64 * 1024 * 1024 {
            try await multipart(url: url, key: key, config: config, onStatus: onStatus)
        } else {
            let data = try Data(contentsOf: url)
            try await retrying(key: key, onStatus: onStatus) {
                try await self.put(data: data, key: key, config: config)
            }
        }
    }
```

- [ ] **Step 3: Riscrivere `put` per lanciare `S3HTTPError`**

Cambia:

```swift
    private func put(data: Data, key: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let putURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        req.httpBody = data
        sign(&req, config: config, body: data, date: Date())
        let (respData, resp) = try await session.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Errore PUT \(key): \(body.prefix(100))"])
        }
    }
```

in:

```swift
    private func put(data: Data, key: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let putURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        req.httpBody = data
        sign(&req, config: config, body: data, date: Date())
        let (respData, resp) = try await session.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw S3HTTPError(statusCode: statusCode, message: "Errore PUT \(key): \(body.prefix(100))")
        }
    }
```

- [ ] **Step 4: Riscrivere `multipart` per lanciare `S3HTTPError`, accettare `onStatus` e ritentare init/parte/complete**

Cambia l'intera funzione da:

```swift
    private func multipart(url: URL, key: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let initURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploads") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var initReq = URLRequest(url: initURL)
        initReq.httpMethod = "POST"
        sign(&initReq, config: config, body: Data(), date: Date())
        let (initData, initResp) = try await session.data(for: initReq)
        guard (initResp as? HTTPURLResponse)?.statusCode == 200,
              let uploadId = xmlFirst(String(data: initData, encoding: .utf8) ?? "", tag: "UploadId") else {
            throw NSError(domain: "S3", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile avviare multipart per \(key)"])
        }
        let encId = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let chunkSize = 64 * 1024 * 1024
        var parts: [(Int, String)] = []
        var offset: Int64 = 0; var pn = 1
        while offset < fileSize {
            if cancelled { break }
            fileHandle.seek(toFileOffset: UInt64(offset))
            let chunk = fileHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(pn)&uploadId=\(encId)") else {
                throw NSError(domain: "S3", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(pn) di \(key)"])
            }
            var pReq = URLRequest(url: pURL)
            pReq.httpMethod = "PUT"; pReq.httpBody = chunk
            sign(&pReq, config: config, body: chunk, date: Date())
            let (_, pResp) = try await session.data(for: pReq)
            guard let pHttp = pResp as? HTTPURLResponse, (200...299).contains(pHttp.statusCode) else {
                throw NSError(domain: "S3", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Errore parte \(pn) di \(key)"])
            }
            let etag = (pResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Etag") ?? ""
            parts.append((pn, etag))
            offset += Int64(chunkSize); pn += 1
        }

        if cancelled {
            if let abortURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") {
                var abortReq = URLRequest(url: abortURL)
                abortReq.httpMethod = "DELETE"
                sign(&abortReq, config: config, body: Data(), date: Date())
                _ = try? await session.data(for: abortReq)
            }
            throw CancellationError()
        }

        let partsXML = parts.map { "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>" }.joined()
        let completeXML = Data("<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
        guard let cURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per completamento multipart: \(key)"])
        }
        var cReq = URLRequest(url: cURL)
        cReq.httpMethod = "POST"; cReq.httpBody = completeXML
        sign(&cReq, config: config, body: completeXML, date: Date())
        let (_, cResp) = try await session.data(for: cReq)
        guard (cResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "S3", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Errore completamento multipart \(key)"])
        }
    }
```

in:

```swift
    private func multipart(url: URL, key: String, config: S3Config, onStatus: @escaping (String) -> Void) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let initURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploads") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }

        let uploadId = try await retrying(key: key, onStatus: onStatus) { () async throws -> String in
            var initReq = URLRequest(url: initURL)
            initReq.httpMethod = "POST"
            self.sign(&initReq, config: config, body: Data(), date: Date())
            let (initData, initResp) = try await self.session.data(for: initReq)
            guard let code = (initResp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
                let statusCode = (initResp as? HTTPURLResponse)?.statusCode ?? -1
                throw S3HTTPError(statusCode: statusCode, message: "Impossibile avviare multipart per \(key)")
            }
            guard let uploadId = self.xmlFirst(String(data: initData, encoding: .utf8) ?? "", tag: "UploadId") else {
                throw NSError(domain: "S3", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Impossibile avviare multipart per \(key)"])
            }
            return uploadId
        }
        let encId = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let chunkSize = 64 * 1024 * 1024
        var parts: [(Int, String)] = []
        var offset: Int64 = 0; var pn = 1
        while offset < fileSize {
            if cancelled { break }
            fileHandle.seek(toFileOffset: UInt64(offset))
            let chunk = fileHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(pn)&uploadId=\(encId)") else {
                throw NSError(domain: "S3", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(pn) di \(key)"])
            }
            let partNumber = pn
            let etag = try await retrying(key: "\(key) (parte \(partNumber))", onStatus: onStatus) { () async throws -> String in
                var pReq = URLRequest(url: pURL)
                pReq.httpMethod = "PUT"; pReq.httpBody = chunk
                self.sign(&pReq, config: config, body: chunk, date: Date())
                let (_, pResp) = try await self.session.data(for: pReq)
                guard let pHttp = pResp as? HTTPURLResponse, (200...299).contains(pHttp.statusCode) else {
                    let statusCode = (pResp as? HTTPURLResponse)?.statusCode ?? -1
                    throw S3HTTPError(statusCode: statusCode, message: "Errore parte \(partNumber) di \(key)")
                }
                return pHttp.value(forHTTPHeaderField: "Etag") ?? ""
            }
            parts.append((pn, etag))
            offset += Int64(chunkSize); pn += 1
        }

        if cancelled {
            if let abortURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") {
                var abortReq = URLRequest(url: abortURL)
                abortReq.httpMethod = "DELETE"
                sign(&abortReq, config: config, body: Data(), date: Date())
                _ = try? await session.data(for: abortReq)
            }
            throw CancellationError()
        }

        let partsXML = parts.map { "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>" }.joined()
        let completeXML = Data("<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
        guard let cURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per completamento multipart: \(key)"])
        }
        try await retrying(key: key, onStatus: onStatus) {
            var cReq = URLRequest(url: cURL)
            cReq.httpMethod = "POST"; cReq.httpBody = completeXML
            self.sign(&cReq, config: config, body: completeXML, date: Date())
            let (_, cResp) = try await self.session.data(for: cReq)
            guard let code = (cResp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
                let statusCode = (cResp as? HTTPURLResponse)?.statusCode ?? -1
                throw S3HTTPError(statusCode: statusCode, message: "Errore completamento multipart \(key)")
            }
        }
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Eseguire l'intera suite**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 34 test.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Wire retrying/S3HTTPError into put, multipart and upload"
```

*Verifica manuale da fare quando possibile (non ora, richiede una vera interruzione di rete durante un upload): avviare SSD→S3, staccare temporaneamente il Wi-Fi per qualche secondo durante il caricamento di un file, osservare nel tab Log i messaggi "riprovo tra Xs", confermare che il file completi dopo il ripristino della connessione. Verificare anche che Interrompi durante un'attesa di retry si fermi subito.*

---

## Task 4: Aggiornare `Docs/CLAUDE.md` e verifica finale

**Files:**
- Modify: `Docs/CLAUDE.md`

- [ ] **Step 1: Aggiornare la sottosezione S3Syncer**

Nella sezione `### S3Syncer (upload S3 nativo, SSD→Cubbit)`, aggiungi una riga:

```markdown
- **Retry con backoff**: ogni chiamata HTTP di upload (PUT singolo, init/parte/complete multipart) viene ritentata fino a 3 volte (1s poi 2s di attesa) per errori transitori (`URLError`, HTTP 5xx) — non per errori permanenti (HTTP 4xx) né se l'utente interrompe (`cancelled`/`Task.isCancelled` controllati prima di ogni attesa). Vedi `S3Syncer.retrying`/`isRetryable`/`S3HTTPError`.
```

- [ ] **Step 2: Aggiornare la tabella "Stato attuale" e il conteggio dei test**

Aggiorna la riga "SSD → S3" aggiungendo "retry con backoff" alla descrizione, e la riga "Test automatici" con il nuovo conteggio (34).

- [ ] **Step 3: Build + suite completa**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`, 34 test verdi.

- [ ] **Step 4: Commit**

```bash
git add Docs/CLAUDE.md
git commit -m "Update Docs/CLAUDE.md: S3 upload retry shipped"
```
