# Upload S3 paralleli + fix memoria multipart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Nota per questo progetto: `subagent-driven-development` e `executing-plans` non sono disponibili in questo ambiente. Esegui i task in sequenza in questa stessa sessione, con build+test verificati e un commit dopo ogni task, come fatto per tutti gli interventi precedenti (retry S3, cleanup multipart, restore).

**Goal:** Rendere gli upload S3 verso Cubbit più veloci (4 file in parallelo invece di 1) senza amplificare un bug di memoria già noto, correggendolo prima nel percorso multipart.

**Architecture:** Due funzioni pure e testabili aggiunte a `S3Syncer` — `readFileInChunks` (lettura POSIX low-level, sostituisce `FileHandle` in `multipart()`) e `runBounded` (concorrenza limitata generica via `withTaskGroup`, usata da `sync()` per caricare fino a 4 file contemporaneamente). Nessuna nuova astrazione oltre queste due: il resto del comportamento (retry, cancellazione, conteggi) resta quello già in produzione, solo ricollegato.

**Tech Stack:** Swift 5.x, SwiftUI, async/await, XCTest, macOS 13+. Tutto il codice di produzione in `AppBackupFoto/ContentView.swift` (convenzione consolidata del progetto — nessuno split di file).

## Global Constraints

- Zero delete, zero overwrite, read-only sulla sorgente — questo intervento non tocca percorsi di cancellazione/scrittura, ma ogni modifica deve restare coerente con la regola.
- 4 upload concorrenti, valore **fisso** nel codice — non aggiungere un'impostazione utente per questo numero.
- Parallelismo **solo tra file diversi** — non parallelizzare le parti di un singolo multipart upload.
- `cancelled`/`Task.isCancelled` vanno controllati dentro ogni task figlio, prima di ogni chiamata di rete — non solo nel loop esterno di schedulazione.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit — mai commit con build rotta.
- Nuovi test XCTest richiedono editing manuale di `AppBackupFoto.xcodeproj/project.pbxproj` (nessun gruppo auto-sync).

---

### Task 1: `S3Syncer.readFileInChunks` — lettura POSIX low-level

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (aggiunta dentro `final class S3Syncer { ... }`, subito dopo la chiusura di `struct SyncResult` a riga 486, prima di `private var cancelled = false` a riga 488)
- Create: `AppBackupFotoTests/FileChunkReaderTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Produces: `S3Syncer.readFileInChunks(path: String, chunkSize: Int, onChunk: (Data) async throws -> Void) async throws` — static, lancia se il file non si apre o la lettura fallisce; propaga qualunque errore lanciato da `onChunk`.

- [ ] **Step 1: Scrivi il test che fallisce**

Crea `AppBackupFotoTests/FileChunkReaderTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class FileChunkReaderTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("FileChunkReaderTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testChunksReconstructOriginalContent_nonMultipleSize() async throws {
        // 250 byte con chunk da 100: 3 chunk (100, 100, 50) — l'ultimo parziale
        // è il caso che rompe un off-by-one nel loop di lettura.
        var data = Data()
        for i in 0..<250 { data.append(UInt8(i % 256)) }
        let file = root.appendingPathComponent("data.bin")
        try data.write(to: file)

        var received: [Data] = []
        try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { chunk in
            received.append(chunk)
        }

        XCTAssertEqual(received.map(\.count), [100, 100, 50])
        XCTAssertEqual(received.reduce(Data(), +), data)
    }

    func testEmptyFile_producesNoChunks() async throws {
        let file = root.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        var callCount = 0
        try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { _ in callCount += 1 }

        XCTAssertEqual(callCount, 0)
    }

    func testNonExistentFile_throws() async {
        do {
            try await S3Syncer.readFileInChunks(path: root.appendingPathComponent("missing.bin").path, chunkSize: 100) { _ in }
            XCTFail("Doveva lanciare un errore")
        } catch {
            // atteso
        }
    }

    func testOnChunkError_propagates() async throws {
        let data = Data(repeating: 0xAB, count: 300)
        let file = root.appendingPathComponent("data.bin")
        try data.write(to: file)

        struct TestError: Error {}
        do {
            try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { _ in throw TestError() }
            XCTFail("Doveva propagare l'errore di onChunk")
        } catch is TestError {
            // atteso
        }
    }
}
```

- [ ] **Step 2: Registra il file in project.pbxproj**

Genera due ID:
```bash
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
```

Nel file `AppBackupFoto.xcodeproj/project.pbxproj`, replicando esattamente il pattern già usato per `Sha256Tests.swift` (righe 16, 39, 88, 225 attuali):

1. In `PBXBuildFile` (vicino a riga 17, dopo la riga di `S3SyncerRetryTests.swift`): aggiungi
   `		<ID_BUILDFILE> /* FileChunkReaderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_FILEREF> /* FileChunkReaderTests.swift */; };`
2. In `PBXFileReference` (vicino a riga 40): aggiungi
   `		<ID_FILEREF> /* FileChunkReaderTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = FileChunkReaderTests.swift; sourceTree = "<group>"; };`
3. Nei `children` del gruppo `AppBackupFotoTests` (vicino a riga 89): aggiungi
   `				<ID_FILEREF> /* FileChunkReaderTests.swift */,`
4. Nella `PBXSourcesBuildPhase` del target test (vicino a riga 226): aggiungi
   `				<ID_BUILDFILE> /* FileChunkReaderTests.swift in Sources */,`

- [ ] **Step 3: Esegui i test per verificare che falliscano**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/FileChunkReaderTests 2>&1 | tail -40`

Expected: FAIL — `readFileInChunks` non esiste ancora su `S3Syncer` (errore di compilazione).

- [ ] **Step 4: Implementa `readFileInChunks`**

In `AppBackupFoto/ContentView.swift`, subito dopo la chiusura di `struct SyncResult` (dopo la riga `}` che chiude `hms(_:)`, prima di `private var cancelled = false`):

```swift

    static func readFileInChunks(path: String, chunkSize: Int,
                                  onChunk: (Data) async throws -> Void) async throws {
        // Stesso principio già in produzione per la funzione top-level sha256(of:):
        // open/read/close POSIX con un buffer riutilizzato, invece di
        // FileHandle.readData(ofLength:), che su file molto grandi mantiene le
        // pagine lette residenti in memoria invece di rilasciarle tra una lettura
        // e l'altra (bug reale osservato e corretto in questa sessione).
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: "S3", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile aprire il file: \(path)"])
        }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            if n < 0 {
                throw NSError(domain: "S3", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Errore di lettura: \(path)"])
            }
            if n == 0 { break }
            try await onChunk(Data(bytes: buffer, count: n))
        }
    }
```

- [ ] **Step 5: Esegui i test per verificare che passino**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/FileChunkReaderTests 2>&1 | tail -40`

Expected: PASS — tutti e 4 i test verdi.

- [ ] **Step 6: Build completa e commit**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/FileChunkReaderTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add S3Syncer.readFileInChunks (POSIX low-level read, same fix pattern as sha256)"
```

---

### Task 2: Riscrivi `multipart()` per usare `readFileInChunks`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:756-832` (funzione `private func multipart(...)`)

**Interfaces:**
- Consumes: `S3Syncer.readFileInChunks(path:chunkSize:onChunk:)` da Task 1; `retrying(key:maxAttempts:onStatus:operation:)` (esistente, riga 707); `abortMultipartUpload(key:uploadId:config:)` (esistente, riga 834).
- Produces: nessuna nuova interfaccia — `multipart()` resta `private`, stessa firma di oggi.

Nessun test automatico per questo task (rete reale verso Cubbit — stesso limite già accettato per il resto di `S3Syncer`). Verifica: build verde + verifica manuale differita (vedi nota a fine task).

- [ ] **Step 1: Sostituisci il ciclo di lettura in `multipart()`**

In `AppBackupFoto/ContentView.swift`, la funzione `multipart()` (riga 756) contiene oggi questo blocco (righe 780-809):

```swift
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
```

Sostituiscilo con:

```swift
        let chunkSize = 64 * 1024 * 1024
        var parts: [(Int, String)] = []
        var pn = 1
        try await S3Syncer.readFileInChunks(path: url.path, chunkSize: chunkSize) { chunk in
            guard !self.cancelled else { return }
            guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(pn)&uploadId=\(encId)") else {
                throw NSError(domain: "S3", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(pn) di \(key)"])
            }
            let partNumber = pn
            let etag = try await self.retrying(key: "\(key) (parte \(partNumber))", onStatus: onStatus) { () async throws -> String in
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
            parts.append((partNumber, etag))
            pn += 1
        }
```

Nota: `let fileSize = ...` (riga 782 originale) va rimossa insieme al resto — non serve più (era usata solo per il confronto `offset < fileSize` del vecchio ciclo). Verifica con grep che `fileSize` non sia usato altrove in `multipart()` prima di rimuoverlo:

```bash
grep -n "fileSize" /Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/ContentView.swift
```

Se compare solo nel blocco che stai sostituendo, rimuovilo. Il resto di `multipart()` (init upload prima del blocco, gestione `if cancelled` e completamento dopo) resta invariato.

- [ ] **Step 2: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -30`

Expected: `BUILD SUCCEEDED`. Se il compilatore lamenta la cattura di `self`/variabili mutabili (`pn`, `parts`) dentro la closure `onChunk` (che è `async throws`, non `@Sendable` — nessun problema atteso dato che `readFileInChunks` esegue tutto sequenzialmente sullo stesso task, ma verifica): se serve, marca la closure come non-escaping esplicitamente o consulta la nota su warning Sendable stale già documentata in `Docs/CLAUDE.md` (SourceKit a volte segnala falsi positivi che `xcodebuild` reale non conferma).

- [ ] **Step 3: Esegui la suite di test completa (nessun nuovo test qui, ma verifica di non aver rotto nulla)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`

Expected: tutti i test esistenti passano (nessuna regressione).

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Fix multipart() memory: read parts via readFileInChunks instead of FileHandle"
```

**Nota per l'utente**: la verifica che il picco di memoria sia davvero basso su un multipart reale (uno degli zip da 40-50GB, con Monitor Attività aperto) resta manuale — va fatta quando l'utente ha tempo per un upload così lungo, non blocca il resto del piano.

---

### Task 3: `S3Syncer.runBounded` — concorrenza limitata generica

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (aggiunta subito dopo `readFileInChunks`, dentro `S3Syncer`)
- Create: `AppBackupFotoTests/RunBoundedTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Consumes: nessuna dipendenza da task precedenti.
- Produces: `S3Syncer.runBounded<Item, Outcome>(items: [Item], maxConcurrent: Int, isCancelled: @escaping () -> Bool, operation: @escaping (Item) async -> Outcome, onOutcome: (Outcome) -> Void) async` — static, generica, usata da Task 4.

- [ ] **Step 1: Scrivi il test che fallisce**

Crea `AppBackupFotoTests/RunBoundedTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class RunBoundedTests: XCTestCase {

    private actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var completedCount = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func exit() {
            current -= 1
            completedCount += 1
        }
    }

    func testPeakConcurrency_neverExceedsMax() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<20)
        var processed: [Int] = []

        await S3Syncer.runBounded(
            items: items,
            maxConcurrent: 4,
            isCancelled: { false },
            operation: { item -> Int in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
                await tracker.exit()
                return item
            },
            onOutcome: { outcome in processed.append(outcome) }
        )

        let peak = await tracker.peak
        let completed = await tracker.completedCount
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(completed, 20)
        XCTAssertEqual(Set(processed), Set(0..<20))
    }

    func testEmptyItems_completesImmediately() async {
        var processed: [Int] = []
        await S3Syncer.runBounded(
            items: [Int](),
            maxConcurrent: 4,
            isCancelled: { false },
            operation: { item -> Int in item },
            onOutcome: { outcome in processed.append(outcome) }
        )
        XCTAssertTrue(processed.isEmpty)
    }

    func testCancelledBeforeStart_schedulesNothing() async {
        var processed: [Int] = []
        await S3Syncer.runBounded(
            items: Array(0..<10),
            maxConcurrent: 4,
            isCancelled: { true },
            operation: { item -> Int in item },
            onOutcome: { outcome in processed.append(outcome) }
        )
        XCTAssertTrue(processed.isEmpty)
    }
}
```

- [ ] **Step 2: Registra il file in project.pbxproj**

Genera due nuovi ID (stesso comando dello Step 2 del Task 1) e aggiungi le 4 righe corrispondenti (`PBXBuildFile`, `PBXFileReference`, `children` del gruppo, `PBXSourcesBuildPhase`) seguendo esattamente lo stesso pattern usato per `FileChunkReaderTests.swift` nel Task 1.

- [ ] **Step 3: Esegui i test per verificare che falliscano**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/RunBoundedTests 2>&1 | tail -40`

Expected: FAIL — `runBounded` non esiste ancora su `S3Syncer`.

- [ ] **Step 4: Implementa `runBounded`**

In `AppBackupFoto/ContentView.swift`, subito dopo la chiusura di `readFileInChunks` (Task 1):

```swift

    static func runBounded<Item, Outcome>(
        items: [Item], maxConcurrent: Int,
        isCancelled: @escaping () -> Bool,
        operation: @escaping (Item) async -> Outcome,
        onOutcome: (Outcome) -> Void
    ) async {
        await withTaskGroup(of: Outcome.self) { group in
            var index = 0
            func addNext() {
                guard index < items.count, !isCancelled() else { return }
                let item = items[index]; index += 1
                group.addTask { await operation(item) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let outcome = await group.next() {
                onOutcome(outcome)
                addNext()
            }
        }
    }
```

Nota di correttezza (da riportare come commento sopra la funzione, una riga): solo il chiamante di `onOutcome` (loop `while let ... = await group.next()`, a thread singolo) deve mutare stato condiviso — i task figli restituiscono un `Outcome`, non toccano nulla di condiviso.

- [ ] **Step 5: Esegui i test per verificare che passino**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/RunBoundedTests 2>&1 | tail -40`

Expected: PASS — tutti e 3 i test verdi (in particolare `testPeakConcurrency_neverExceedsMax`, che è probabilistico solo nell'ordine di completamento, non nel vincolo verificato — il picco osservato è deterministicamente ≤ 4 dato che `addNext()` viene chiamato solo dopo un `group.next()`).

- [ ] **Step 6: Build completa e commit**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/RunBoundedTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add S3Syncer.runBounded: generic fixed-window concurrency helper"
```

---

### Task 4: Riscrivi `sync()` per caricare 4 file in parallelo

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:570-632` (funzione `sync(from:config:onStatus:onProgress:)`)

**Interfaces:**
- Consumes: `S3Syncer.runBounded(items:maxConcurrent:isCancelled:operation:onOutcome:)` da Task 3.
- Produces: nessuna nuova interfaccia — `sync()` resta pubblica, stessa firma e stesso `SyncResult` di ritorno di oggi.

Nessun test automatico per questo task (rete reale). Verifica: build verde + suite di test esistente verde + verifica manuale differita.

- [ ] **Step 1: Sostituisci il ciclo di upload in `sync()`**

In `AppBackupFoto/ContentView.swift`, la funzione `sync()` (riga 570) contiene oggi questo blocco finale (righe 612-631, dopo la costruzione di `files` e il calcolo di `toUploadCount`/`localCount`/`alreadyPresent`):

```swift
        for item in files {
            if cancelled { break }
            if existing[item.key] == item.size {
                result.skipped += 1
            } else {
                let msg = "Upload (\(result.done + 1)/\(result.total) — \(result.percent)%): \(item.url.lastPathComponent)"
                DispatchQueue.main.async { onStatus(msg) }
                do {
                    try await upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
                    result.uploaded += 1
                    result.uploadedBytes += item.size
                } catch {
                    result.errors += 1
                }
            }
            result.done += 1
            let snap = result
            DispatchQueue.main.async { onProgress(snap) }
        }
        return result
    }
```

Sostituisci **anche** il blocco immediatamente precedente che calcola `toUploadCount`/`localCount`/`alreadyPresent` e li pubblica (righe 601-610):

```swift
        let toUploadCount = files.filter { existing[$0.key] != $0.size }.count
        result.total = files.count
        result.toUploadCount = toUploadCount
        let localCount = files.count
        let alreadyPresent = localCount - toUploadCount
        let initSnap = result
        DispatchQueue.main.async {
            onStatus("Trovati \(localCount) file locali · \(toUploadCount) da caricare · \(alreadyPresent) già presenti")
            onProgress(initSnap)
        }
```

Il blocco combinato (righe 601-631) diventa:

```swift
        let toUpload = files.filter { existing[$0.key] != $0.size }
        result.total = files.count
        result.toUploadCount = toUpload.count
        result.skipped = files.count - toUpload.count
        result.done = result.skipped
        let initSnap = result
        DispatchQueue.main.async {
            onStatus("Trovati \(files.count) file locali · \(toUpload.count) da caricare · \(result.skipped) già presenti")
            onProgress(initSnap)
        }

        await S3Syncer.runBounded(
            items: toUpload, maxConcurrent: 4,
            isCancelled: { self.cancelled },
            operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
                if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                DispatchQueue.main.async { onStatus("Carico: \(item.url.lastPathComponent)") }
                do {
                    try await self.upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
                    return (item.url, item.size, true)
                } catch {
                    return (item.url, item.size, false)
                }
            },
            onOutcome: { outcome in
                if outcome.ok { result.uploaded += 1; result.uploadedBytes += outcome.size }
                else { result.errors += 1 }
                result.done += 1
                let snap = result
                DispatchQueue.main.async { onProgress(snap) }
            }
        )
        return result
    }
```

Nota: quando `outcome.ok == false` non distinguiamo più "skip volontario per cancellazione" da "errore di rete" nel conteggio `result.errors` — stesso comportamento ambiguo già presente oggi nel ramo `catch` del ciclo sequenziale (un errore generico incrementa sempre `errors`, anche se causato da `cancelled`). Nessuna regressione: la UI di stop già interrompe il job a un livello più alto (`BackupRunner.stop()`) indipendentemente da questo conteggio.

- [ ] **Step 2: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -30`

Expected: `BUILD SUCCEEDED`. Se il compilatore segnala che `result` (var locale) non può essere mutata dentro la closure `onOutcome` perché "escaping": `onOutcome` è dichiarata non-`@escaping` in `runBounded` (Task 3) proprio per permettere questa cattura diretta — se l'errore persiste, verificare che la firma di `runBounded` non abbia marcato `onOutcome` come `@escaping` per errore.

- [ ] **Step 3: Esegui la suite di test completa**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`

Expected: tutti i test passano (nessuna regressione — inclusi i test S3 esistenti che non toccano la rete).

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Parallelize S3Syncer.sync() uploads: 4 concurrent files via runBounded"
```

**Nota per l'utente**: la verifica del comportamento parallelo reale (più file che avanzano "insieme" nei log, tempo totale ridotto su una cartella con molti file piccoli) resta manuale — va fatta con una connessione reale verso Cubbit, non riproducibile in questo ambiente.

---

### Task 5: Aggiorna la documentazione

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

- [ ] **Step 1: Aggiorna la sezione S3Syncer in `Docs/CLAUDE.md`**

Trova questa riga (riga 105 attuale):

```
- PUT per file < 64MB, multipart per file ≥ 64MB (chunk da 64MB)
```

Sostituiscila con:

```
- PUT per file < 64MB, multipart per file ≥ 64MB (chunk da 64MB), lettura parti via `readFileInChunks` (POSIX low-level, stesso fix di `sha256(of:)` — vedi sezione dedicata sotto)
- **Upload paralleli**: `sync()` carica fino a 4 file diversi in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Le parti di un singolo multipart restano sequenziali (parallelizzarle non aiuterebbe: sui pochi file enormi il collo di bottiglia è la banda, non la latenza per richiesta). Cancellazione controllata dentro ogni task figlio prima di ogni chiamata di rete, non solo nel loop di schedulazione.
```

- [ ] **Step 2: Aggiungi una sezione sul fix di memoria multipart, accanto a quella di sha256**

Dopo il paragrafo che termina con "Lezione per il futuro: se un'altra funzione in questo progetto legge file di grandi dimensioni via `FileHandle`..." (fine della sezione "Bug critico risolto: `sha256(of:)` e file molto grandi", circa riga 147), aggiungi:

```

### Stessa lezione applicata: `multipart()` upload (2026-08-02)

Rileggendo il codice durante il brainstorming per gli upload paralleli, `multipart()` (upload dei file ≥64MB verso Cubbit) usava lo stesso pattern a rischio: `FileHandle(forReadingFrom:)` + `readData(ofLength: chunkSize)` in un ciclo per leggere le parti da 64MB. Non è stato ancora misurato empiricamente un picco di memoria su un multipart reale (serve un upload di ore su uno degli zip da 40-50GB), ma è la stessa firma di codice del bug già trovato — corretto preventivamente riusando `S3Syncer.readFileInChunks` (stesso `open`/`read`/`close` POSIX con buffer riutilizzato). Verifica manuale con Monitor Attività ancora da fare da parte dell'utente.
```

- [ ] **Step 3: Aggiorna la tabella "Stato attuale"**

Trova (riga 175 attuale):

```
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, retry con backoff, grafico MB/s |
```

Sostituisci con:

```
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, retry con backoff, upload paralleli (4 file), grafico MB/s |
```

Trova (riga 184 attuale):

```
| Test automatici | ✅ 34 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3) |
```

Sostituisci con (aggiorna il numero di test al conteggio reale dopo Task 1 e Task 3 — verifica con `xcodebuild ... test` quanti test totali risultano, atteso 34 + 4 + 3 = 41):

```
| Test automatici | ✅ 41 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3, lettura file a blocchi, concorrenza limitata) |
```

- [ ] **Step 4: Aggiorna `Docs/ROADMAP.md`**

Trova (riga 13 attuale):

```
**Ancora aperti, con bozze di design pronte in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #4 cleanup multipart orfani, #5 cifratura lato client, #6 upload paralleli, #10 Keychain, #7 scheduling.
```

Sostituisci con:

```
**Ancora aperti, con bozze di design pronte in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #5 cifratura lato client, #10 Keychain, #7 scheduling.
```

Trova (riga 41-42 attuali):

```
6. **Upload S3 completamente sequenziali** — un file alla volta, e anche le parti multipart una alla volta, nessun parallelismo in `S3Syncer.sync`. Su ~69.000 file è probabilmente il collo di bottiglia più grande sulla velocità reale.
   *Effort: medio · `TaskGroup` con 4-8 upload/parti concorrenti, limite configurabile*
```

Sostituisci con:

```
6. ✅ **Fatto (2026-08-02) — Upload S3 completamente sequenziali.** 4 file caricati in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Bonus non previsto: nello stesso intervento corretto anche un probabile bug di memoria in `multipart()` (stesso pattern già trovato in `sha256(of:)`), prima di parallelizzare. Vedi `Docs/superpowers/specs/2026-08-02-parallel-uploads-design.md`.
```

Trova (riga 75-77 attuali, sezione "Da dove partire"):

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #9 anteprima S3. Il prossimo con più impatto è probabilmente **#4 (cleanup multipart orfani)** o **#6 (upload paralleli)** — entrambi hanno già ricerca e opzioni pronte in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`. Il resto è ordinabile in base al tempo che vuoi investirci.
```

Sostituisci con:

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #9 anteprima S3. Restano 3 interventi con bozza di ricerca già pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`: **#5 cifratura lato client** (il più delicato — tocca decisioni di sicurezza/UX che richiedono una discussione attenta con l'utente), **#10 Keychain** (migrazione credenziali, medio rischio), **#7 scheduling** (automazione backup). Il resto della lista (punti 8, 11-20) è ordinabile in base al tempo che si vuole investirci.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: parallel S3 uploads + multipart memory fix shipped"
```

---

## Riepilogo finale per l'utente

Dopo tutti i task: build verde, 41 test passano, 5 commit (uno per task). Restano da fare, manualmente e senza fretta:
1. Upload reale di uno degli zip da 40-50GB con Monitor Attività aperto — confermare che la memoria resti bassa (~60-100MB, non 40+GB).
2. Upload SSD→S3 reale su una cartella con molti file piccoli — osservare nei log/stato che più file avanzano "insieme" invece che uno alla volta.
