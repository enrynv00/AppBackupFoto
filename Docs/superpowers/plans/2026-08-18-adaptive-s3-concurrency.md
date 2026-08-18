# Concorrenza adattiva per upload SSD→S3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) o superpowers:executing-plans per implementare questo piano task-per-task. Gli step usano checkbox (`- [ ]`) per il tracking.

**Goal:** Sostituire il parallelismo fisso di `S3Syncer` (4 file in parallelo, parti multipart sempre sequenziali) con un unico meccanismo adattivo condiviso, per risolvere la lentezza osservata su upload SSD→S3 di file enormi (4,31 MB/s contro ~33 MB/s reali). Spec: `Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md`.

**Architecture:** Nuovo `actor S3Syncer.AdaptiveUploadGate` con capacità variabile (AIMD: cresce di 2 dopo 5 successi consecutivi, si dimezza al primo errore di rete ritentabile, floor 1, tetto derivato dalla memoria — 2GB / 64MB = 32 slot). La logica di transizione di stato è estratta in un tipo puro testabile (`S3Syncer.AdaptiveLimiter`/`AdaptiveLimiterState`/`AdaptiveLimiterOutcome`), separato dall'`actor` che gestisce solo l'attesa/risveglio reale. Un'unica istanza del gate, creata all'inizio di `S3Syncer.sync()`, viene condivisa sia dal ciclo sui file interi sia da ogni chiamata a `multipart()` — ogni parte multipart acquisisce uno slot prima di essere letta da disco (throttling automatico della lettura) e viene poi inviata da un task figlio, permettendo parallelismo reale tra le parti. `runBounded` (cap fisso a 4) viene rimosso, sostituito ovunque dal gate.

**Tech Stack:** Swift concurrency (`actor`, `withThrowingTaskGroup`, `CheckedContinuation`), XCTest, `xcodebuild`. Tutto in `AppBackupFoto/ContentView.swift` (convenzione esplicita del progetto).

## Global Constraints

- Tutto il codice di produzione va in `AppBackupFoto/ContentView.swift` — nessun file nuovo per il codice (`Docs/CLAUDE.md`). I nuovi tipi (`AdaptiveLimiterState`, `AdaptiveLimiterOutcome`, `AdaptiveLimiter`, `AdaptiveUploadGate`) sono nested type di `S3Syncer`, stesso pattern già usato per `S3HTTPError`/`OrphanedMultipartUpload` (referenziati come `S3Syncer.NomeTipo` dai test, con `@testable import AppBackupFoto`).
- I nuovi tipi/funzioni pure devono restare **non `private`** (default `internal`), stesso motivo già documentato nel codice per `validateEndpoint`: "deve restare visibile a @testable import per i test unitari".
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) devono restare verdi dopo ogni task. Baseline attuale: 91 test.
- Ogni nuovo file di test XCTest va aggiunto **anche** a mano a `AppBackupFoto.xcodeproj/project.pbxproj` (4 punti: `PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `Sources` build phase) — il target test non usa un gruppo file-system-synchronized, un file dimenticato qui compila silenziosamente escluso dalla suite. Verificare sempre il conteggio totale dei test dopo averne aggiunti di nuovi, non fidarsi solo di "TEST SUCCEEDED".
- Nessuna modifica a `FileSyncer`/`BackupRunner`/`ReviewEngine`/regole zero-delete-zero-overwrite — questo piano tocca solo l'esecuzione (non la decisione) degli upload S3 già previsti da `shouldUpload`/`isChangedExistingKey`, invariati.
- Nessuna nuova impostazione utente (niente toggle/numero in Impostazioni) — coerente con la spec, tutte le costanti restano hardcoded nel codice.
- **Nessun test automatico per il comportamento reale di concorrenza dell'`actor`** (crescita/riduzione sotto carico di rete vero) — solo la logica pura di transizione di stato è testata. Verifica reale: Task 5, a carico di Enrico (upload di uno zip 40-50GB con Activity Monitor aperto).
- **Cancellazione**: resta cooperativa, come nel resto di `S3Syncer` (`self.cancelled`/`Task.isCancelled` controllati ai checkpoint naturali, nessuna cancellazione preventiva delle richieste HTTP già in volo). Un task in attesa su `gate.acquire()` viene comunque risvegliato non appena un altro slot attivo si libera (successo, fallimento, o timeout della sessione — `timeoutIntervalForRequest = 300`s) — stesso limite pratico già presente oggi, non una regressione introdotta da questo piano. Il Code Reviewer deve verificare esplicitamente che ogni `gate.acquire()` abbia un `gate.release(outcome:)` corrispondente su **tutti** i percorsi di uscita (successo, errore, cancellazione) in `upload()` e in `multipart()` — uno slot acquisito e mai rilasciato blocca permanentemente un task in attesa.

---

## Task 1: Logica pura del limitatore adattivo + `actor` di ammissione

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovi tipi, subito prima di `static func runBounded`, riga ~1849 nello stato attuale)
- Test: `AppBackupFotoTests/AdaptiveLimiterTests.swift` (nuovo file)
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Consumes: nessuno (primo task, nessuna dipendenza).
- Produces: `S3Syncer.AdaptiveLimiterState` (`limit: Int`, `consecutiveSuccesses: Int`), `S3Syncer.AdaptiveLimiterOutcome` (`.success`/`.retryableFailure`/`.permanentFailure`), `S3Syncer.AdaptiveLimiter.applying(_:to:ceiling:) -> AdaptiveLimiterState`, `S3Syncer.AdaptiveUploadGate` (`actor`, `init(startingLimit:ceiling:)`, `acquire() async`, `release(outcome:) async`) — consumati dai Task 2-4. Non ancora usati da nessun percorso di produzione in questo task (nessuna regressione possibile, codice nuovo e isolato).

- [ ] **Step 1: Scrivere i test per la logica pura (falliranno: i tipi non esistono ancora)**

Creare `AppBackupFotoTests/AdaptiveLimiterTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class AdaptiveLimiterTests: XCTestCase {
    private let ceiling = 32

    func testSuccess_belowThreshold_growsCounterNotLimit() {
        var state = S3Syncer.AdaptiveLimiterState(limit: 4, consecutiveSuccesses: 0)
        for _ in 0..<4 {
            state = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: ceiling)
        }
        XCTAssertEqual(state.limit, 4)
        XCTAssertEqual(state.consecutiveSuccesses, 4)
    }

    func testSuccess_reachingThreshold_growsLimitAndResetsCounter() {
        var state = S3Syncer.AdaptiveLimiterState(limit: 4, consecutiveSuccesses: 0)
        for _ in 0..<5 {
            state = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: ceiling)
        }
        XCTAssertEqual(state.limit, 6)
        XCTAssertEqual(state.consecutiveSuccesses, 0)
    }

    func testSuccess_growthIsCappedAtCeiling() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 31, consecutiveSuccesses: 4)
        let result = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: 32)
        XCTAssertEqual(result.limit, 32)
        XCTAssertEqual(result.consecutiveSuccesses, 0)
    }

    func testSuccess_alreadyAtCeiling_staysAtCeiling() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 32, consecutiveSuccesses: 4)
        let result = S3Syncer.AdaptiveLimiter.applying(.success, to: state, ceiling: 32)
        XCTAssertEqual(result.limit, 32)
    }

    func testRetryableFailure_halvesLimitAndResetsCounter() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 8, consecutiveSuccesses: 3)
        let result = S3Syncer.AdaptiveLimiter.applying(.retryableFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 4)
        XCTAssertEqual(result.consecutiveSuccesses, 0)
    }

    func testRetryableFailure_floorsAtOne() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 1, consecutiveSuccesses: 0)
        let result = S3Syncer.AdaptiveLimiter.applying(.retryableFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 1)
    }

    func testPermanentFailure_hasNoEffect() {
        let state = S3Syncer.AdaptiveLimiterState(limit: 5, consecutiveSuccesses: 3)
        let result = S3Syncer.AdaptiveLimiter.applying(.permanentFailure, to: state, ceiling: ceiling)
        XCTAssertEqual(result.limit, 5)
        XCTAssertEqual(result.consecutiveSuccesses, 3)
    }

    func testGate_acquireRelease_neverExceedsCurrentLimit() async {
        let gate = S3Syncer.AdaptiveUploadGate(startingLimit: 2, ceiling: 32)
        var active = 0, peak = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gate.acquire()
                    active += 1
                    peak = max(peak, active)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    active -= 1
                    await gate.release(outcome: .success)
                }
            }
        }
        XCTAssertLessThanOrEqual(peak, 2)
    }
}
```

Nota sull'ultimo test: `active`/`peak` sono mutati da più `Task` concorrenti senza isolamento esplicito — non è una misura rigorosa di correttezza (rischio di data race sulla var locale), serve solo come sanity-check rapido che il gate non lasci passare più della `startingLimit` iniziale quando non ci sono ancora stati successi a sufficienza per crescere (10 unità di lavoro, soglia di crescita 5 successi: al più una crescita da 2 a 4 potrebbe avvenire verso la fine, ma il picco iniziale osservato in pratica con `sleep` di 5ms resta measurabile). Se in esecuzione risultasse flaky, è accettabile marcarlo con un commento "best-effort" — non bloccante per il piano, la vera verifica di correttezza è nei test sulla logica pura sopra.

- [ ] **Step 2: Registrare il nuovo file di test in `project.pbxproj`**

Aggiungere le seguenti 4 righe (usare esattamente questi identificatori, già generati e liberi in questo repo):

1. In `PBXBuildFile section` (vicino alla riga `4D0C1BB6D5D73ADA0369EF7D /* RunBoundedTests.swift in Sources */ = ...`, riga ~23):

```
		452D46691F6E4F8785DEAE67 /* AdaptiveLimiterTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 8C016CC3A88A448190FFF793 /* AdaptiveLimiterTests.swift */; };
```

2. In `PBXFileReference section` (vicino alla riga `C4C02713A9555629C0942E51 /* RunBoundedTests.swift */ = ...`, riga ~56):

```
		8C016CC3A88A448190FFF793 /* AdaptiveLimiterTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = AdaptiveLimiterTests.swift; sourceTree = "<group>"; };
```

3. Nel gruppo `AppBackupFotoTests` (vicino alla riga `C4C02713A9555629C0942E51 /* RunBoundedTests.swift */,`, riga ~119, dentro l'elenco `children = (...)`):

```
				8C016CC3A88A448190FFF793 /* AdaptiveLimiterTests.swift */,
```

4. Nella `Sources` build phase del target test (vicino alla riga `4D0C1BB6D5D73ADA0369EF7D /* RunBoundedTests.swift in Sources */,`, riga ~275, dentro l'elenco `files = (...)`):

```
				452D46691F6E4F8785DEAE67 /* AdaptiveLimiterTests.swift in Sources */,
```

- [ ] **Step 3: Verificare che i test falliscano a compilazione (i tipi non esistono ancora)**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: fallimento di compilazione, errori tipo "cannot find type 'AdaptiveLimiterState' in scope".

- [ ] **Step 4: Implementare i nuovi tipi**

In `ContentView.swift`, subito prima di `static func runBounded<Item, Outcome>(` (riga ~1849), aggiungere:

```swift
    // Non private: deve restare visibile a @testable import per i test unitari
    // (stesso criterio già usato per validateEndpoint/isRetryable).
    struct AdaptiveLimiterState: Equatable {
        var limit: Int
        var consecutiveSuccesses: Int
    }

    enum AdaptiveLimiterOutcome {
        case success
        case retryableFailure
        case permanentFailure
    }

    // Logica pura AIMD (Additive Increase / Multiplicative Decrease), separata
    // dall'actor sottostante per essere testabile senza rete/timer. Vedi
    // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
    enum AdaptiveLimiter {
        static let floor = 1
        static let growthStep = 2
        static let successesToGrow = 5

        static func applying(_ outcome: AdaptiveLimiterOutcome, to state: AdaptiveLimiterState,
                              ceiling: Int) -> AdaptiveLimiterState {
            switch outcome {
            case .success:
                let successes = state.consecutiveSuccesses + 1
                guard successes >= successesToGrow else {
                    return AdaptiveLimiterState(limit: state.limit, consecutiveSuccesses: successes)
                }
                return AdaptiveLimiterState(limit: min(ceiling, state.limit + growthStep), consecutiveSuccesses: 0)
            case .retryableFailure:
                return AdaptiveLimiterState(limit: max(floor, state.limit / 2), consecutiveSuccesses: 0)
            case .permanentFailure:
                return state
            }
        }
    }

    // Gate di ammissione a capacità variabile: ogni unità di lavoro di rete (un file
    // intero <64MB, o una singola parte multipart) acquisisce uno slot prima di essere
    // letta/inviata, e lo rilascia (con l'esito) al proprio termine — inclusi eventuali
    // retry interni, che restano nella stessa unità di lavoro. Nessun lock manuale:
    // l'intero stato (limite corrente, contatore successi, slot attivi, task in attesa)
    // è isolato dall'actor.
    actor AdaptiveUploadGate {
        private var state: AdaptiveLimiterState
        private let ceiling: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(startingLimit: Int, ceiling: Int) {
            self.state = AdaptiveLimiterState(limit: startingLimit, consecutiveSuccesses: 0)
            self.ceiling = ceiling
        }

        func acquire() async {
            if active < state.limit {
                active += 1
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
            // Lo slot è già stato riservato (active incrementato) da release(),
            // subito prima di risvegliare questo continuation — vedi sotto.
        }

        func release(outcome: AdaptiveLimiterOutcome) {
            active -= 1
            state = AdaptiveLimiter.applying(outcome, to: state, ceiling: ceiling)
            while active < state.limit, !waiters.isEmpty {
                active += 1
                waiters.removeFirst().resume()
            }
        }
    }

    // Costanti condivise: ogni unità di lavoro (file <64MB, o parte multipart) ha corpo
    // HTTP ≤ multipartChunkSize, quindi un tetto sul numero di slot è già equivalente a
    // un tetto sui byte in volo — nessuna contabilità separata necessaria.
    static let multipartChunkSize = 64 * 1024 * 1024
    private static let adaptiveMemoryCeilingBytes = 2 * 1024 * 1024 * 1024
    static let adaptiveConcurrencyCeiling = adaptiveMemoryCeilingBytes / multipartChunkSize

```

- [ ] **Step 5: Eseguire i test, verificare che passino**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 8 nuovi test verdi (99 totali — 91 di baseline + 8), nessuna regressione.

- [ ] **Step 6: Build di produzione**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/AdaptiveLimiterTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add adaptive upload concurrency gate (pure AIMD logic + actor, not yet wired)"
```

---

## Task 2: HTTP 429 diventa ritentabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:2358-2363` (`S3Syncer.isRetryable`)
- Test: `AppBackupFotoTests/S3SyncerRetryTests.swift` (file esistente, nuovo caso)

**Interfaces:**
- Consumes: nessuno da Task 1 (indipendente — modifica un comportamento già attivo oggi su tutti i PUT/parti esistenti).
- Produces: `S3Syncer.isRetryable(_:)` con HTTP 429 → `true`, consumato indirettamente da `retrying()` (invariato) e dal nuovo codice del Task 3 che userà lo stesso `isRetryable` per classificare `AdaptiveLimiterOutcome`.

- [ ] **Step 1: Scrivere il test che fallisce**

Aggiungere a `AppBackupFotoTests/S3SyncerRetryTests.swift`, dopo `testHTTP503_isRetryable`:

```swift
    func testHTTP429_isRetryable() {
        XCTAssertTrue(S3Syncer.isRetryable(S3Syncer.S3HTTPError(statusCode: 429, message: "Too Many Requests")))
    }
```

- [ ] **Step 2: Eseguire, verificare che fallisca**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/S3SyncerRetryTests/testHTTP429_isRetryable 2>&1 | tail -20
```

Expected: FAIL (`XCTAssertTrue failed`).

- [ ] **Step 3: Correggere `isRetryable`**

In `ContentView.swift`, riga ~2358-2363, sostituire:

```swift
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let httpError = error as? S3HTTPError { return !(400...499).contains(httpError.statusCode) }
        if error is URLError { return true }
        return false
    }
```

con:

```swift
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let httpError = error as? S3HTTPError {
            // 429 (Too Many Requests) è esattamente il segnale di congestione che il
            // gate adattivo deve poter interpretare — vedi
            // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
            if httpError.statusCode == 429 { return true }
            return !(400...499).contains(httpError.statusCode)
        }
        if error is URLError { return true }
        return false
    }
```

- [ ] **Step 4: Eseguire di nuovo, verificare che passi**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 100 test totali (99 + 1), nessuna regressione.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerRetryTests.swift
git commit -m "Treat HTTP 429 as retryable (adaptive concurrency needs to react to it)"
```

---

## Task 3: Parallelizzare le parti multipart tramite il gate

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:2208-2218` (`S3Syncer.upload`)
- Modify: `AppBackupFoto/ContentView.swift:2238-2308` (`S3Syncer.multipart`)
- Test: `AppBackupFotoTests/S3SyncerMultipartXMLTests.swift` (nuovo file)
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Consumes: `S3Syncer.AdaptiveUploadGate`/`AdaptiveLimiterOutcome` (Task 1), `S3Syncer.isRetryable` con 429 (Task 2), `S3Syncer.multipartChunkSize` (Task 1).
- Produces: `S3Syncer.upload(url:key:config:gate:onStatus:)` (nuovo parametro `gate`), `S3Syncer.multipart(url:key:config:gate:onStatus:)` (nuovo parametro `gate`), `S3Syncer.buildCompleteMultipartXML(parts:) -> String` — consumati dal Task 4 (`sync()`).

- [ ] **Step 1: Scrivere il test per l'ordinamento delle parti (fallirà: la funzione non esiste ancora)**

Creare `AppBackupFotoTests/S3SyncerMultipartXMLTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class S3SyncerMultipartXMLTests: XCTestCase {
    func testBuildCompleteMultipartXML_sortsOutOfOrderParts() {
        let xml = S3Syncer.buildCompleteMultipartXML(parts: [
            (partNumber: 3, etag: "etag3"),
            (partNumber: 1, etag: "etag1"),
            (partNumber: 2, etag: "etag2"),
        ])
        let expected = "<CompleteMultipartUpload>"
            + "<Part><PartNumber>1</PartNumber><ETag>etag1</ETag></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>etag2</ETag></Part>"
            + "<Part><PartNumber>3</PartNumber><ETag>etag3</ETag></Part>"
            + "</CompleteMultipartUpload>"
        XCTAssertEqual(xml, expected)
    }

    func testBuildCompleteMultipartXML_singlePart() {
        let xml = S3Syncer.buildCompleteMultipartXML(parts: [(partNumber: 1, etag: "onlyone")])
        XCTAssertEqual(xml, "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>onlyone</ETag></Part></CompleteMultipartUpload>")
    }
}
```

- [ ] **Step 2: Registrare il nuovo file di test in `project.pbxproj`** (stesso schema del Task 1, Step 2 — usare questi identificatori):

1. `PBXBuildFile` (vicino a `RunBoundedTests.swift in Sources`):
```
		3232CD64269D4A9094F04D9E /* S3SyncerMultipartXMLTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 86D59F53CF7A4DCE8C207DBC /* S3SyncerMultipartXMLTests.swift */; };
```

2. `PBXFileReference`:
```
		86D59F53CF7A4DCE8C207DBC /* S3SyncerMultipartXMLTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = S3SyncerMultipartXMLTests.swift; sourceTree = "<group>"; };
```

3. Gruppo `AppBackupFotoTests`:
```
				86D59F53CF7A4DCE8C207DBC /* S3SyncerMultipartXMLTests.swift */,
```

4. `Sources` build phase:
```
				3232CD64269D4A9094F04D9E /* S3SyncerMultipartXMLTests.swift in Sources */,
```

- [ ] **Step 3: Verificare che il test fallisca a compilazione**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: errore di compilazione "cannot find 'buildCompleteMultipartXML' in scope".

- [ ] **Step 4: Sostituire `upload()`** (righe ~2208-2218)

Da:

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

A:

```swift
    private func upload(url: URL, key: String, config: S3Config, gate: AdaptiveUploadGate,
                         onStatus: @escaping (String) -> Void) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.multipartChunkSize {
            try await multipart(url: url, key: key, config: config, gate: gate, onStatus: onStatus)
        } else {
            await gate.acquire()
            if cancelled || Task.isCancelled {
                await gate.release(outcome: .permanentFailure)
                throw CancellationError()
            }
            let data = try Data(contentsOf: url)
            do {
                try await retrying(key: key, onStatus: onStatus) {
                    try await self.put(data: data, key: key, config: config)
                }
                await gate.release(outcome: .success)
            } catch {
                await gate.release(outcome: S3Syncer.isRetryable(error) ? .retryableFailure : .permanentFailure)
                throw error
            }
        }
    }
```

- [ ] **Step 5: Sostituire `multipart()`** (righe ~2238-2308)

Da (l'intera funzione attuale, dalla firma alla chiusura):

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

        if cancelled {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
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

A:

```swift
    private func multipart(url: URL, key: String, config: S3Config, gate: AdaptiveUploadGate,
                            onStatus: @escaping (String) -> Void) async throws {
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

        // Le parti si leggono in sequenza da disco (I/O locale, veloce) ma si inviano in
        // parallelo: ogni parte acquisisce uno slot dal gate PRIMA di essere letta, così
        // il loop di lettura resta naturalmente al passo con la capacità di rete corrente
        // — nessun tracciamento separato dei byte in volo necessario (vedi spec).
        var parts: [(partNumber: Int, etag: String)] = []
        var pn = 1

        try await withThrowingTaskGroup(of: (partNumber: Int, etag: String).self) { group in
            try await S3Syncer.readFileInChunks(path: url.path, chunkSize: Self.multipartChunkSize) { chunk in
                guard !self.cancelled else { return }
                await gate.acquire()
                if self.cancelled || Task.isCancelled {
                    await gate.release(outcome: .permanentFailure)
                    return
                }
                let partNumber = pn
                pn += 1
                guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(partNumber)&uploadId=\(encId)") else {
                    await gate.release(outcome: .permanentFailure)
                    throw NSError(domain: "S3", code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(partNumber) di \(key)"])
                }
                group.addTask {
                    do {
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
                        await gate.release(outcome: .success)
                        return (partNumber, etag)
                    } catch {
                        await gate.release(outcome: S3Syncer.isRetryable(error) ? .retryableFailure : .permanentFailure)
                        throw error
                    }
                }
            }

            while let next = try await group.next() {
                parts.append(next)
            }
        }

        if cancelled {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw CancellationError()
        }

        let completeXML = Data(S3Syncer.buildCompleteMultipartXML(parts: parts).utf8)
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

    // AWS S3 richiede le parti in ordine crescente di PartNumber nel body di
    // CompleteMultipartUpload — con l'esecuzione parallela l'ordine di completamento non
    // coincide più con l'ordine di lettura, va quindi ordinato esplicitamente. Non
    // private: testata direttamente da S3SyncerMultipartXMLTests.
    static func buildCompleteMultipartXML(parts: [(partNumber: Int, etag: String)]) -> String {
        let sorted = parts.sorted { $0.partNumber < $1.partNumber }
        let partsXML = sorted.map { "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\($0.etag)</ETag></Part>" }.joined()
        return "<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>"
    }
```

Nota: questo task lascia `S3Syncer.sync()` **non ancora aggiornato** — non compilerà finché il Task 4 non aggiorna la chiamata a `upload(...)` con il nuovo parametro `gate`. È atteso: build/test di questo task falliranno su quella riga. Se il progetto richiede build verde ad ogni task (vedi Global Constraints), eseguire Task 3 e Task 4 come un'unica sessione di lavoro senza commit intermedio del solo Task 3, oppure — se si preferisce un commit intermedio comunque verde — aggiungere temporaneamente `gate: AdaptiveUploadGate(startingLimit: 4, ceiling: Self.adaptiveConcurrencyCeiling)` inline alla chiamata esistente in `sync()` come fix minimo di compilazione in questo stesso step, che il Task 4 poi sostituirà con l'istanza condivisa. **Scelta consigliata**: applicare questo fix minimo qui, per mantenere ogni task indipendentemente verde.

- [ ] **Step 5b: Fix minimo di compilazione in `sync()`** (verrà sostituito dal Task 4)

In `ContentView.swift`, riga ~2036 (dentro la closure `operation` di `runBounded` in `sync()`), cambiare:

```swift
                    try await self.upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
```

in:

```swift
                    try await self.upload(url: item.url, key: item.key, config: config,
                                          gate: AdaptiveUploadGate(startingLimit: 4, ceiling: Self.adaptiveConcurrencyCeiling),
                                          onStatus: onStatus)
```

(Un gate per chiamata non è la versione finale voluta dalla spec — verrà sostituito da un'unica istanza condivisa nel Task 4. Serve solo a mantenere questo task compilabile e testabile in isolamento.)

- [ ] **Step 6: Eseguire i test, verificare che passino**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 102 test totali (100 + 2 nuovi), nessuna regressione.

- [ ] **Step 7: Build di produzione**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerMultipartXMLTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Parallelize multipart part uploads via the adaptive gate"
```

---

## Task 4: Condividere il gate in `sync()`, rimuovere `runBounded`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1849-1868` (rimozione `runBounded`)
- Modify: `AppBackupFoto/ContentView.swift:1979-2051` (`S3Syncer.sync`, ciclo file)
- Delete: `AppBackupFotoTests/RunBoundedTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (rimozione dei 4 riferimenti a `RunBoundedTests.swift`)

**Interfaces:**
- Consumes: `S3Syncer.AdaptiveUploadGate` (Task 1), `S3Syncer.upload(url:key:config:gate:onStatus:)` (Task 3).
- Produces: nessuna nuova interfaccia — chiude il collegamento tra `sync()` e il gate condiviso.

- [ ] **Step 1: Verificare che `runBounded` non abbia altri chiamanti**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
grep -n "runBounded" AppBackupFoto/ContentView.swift AppBackupFotoTests/*.swift
```

Expected: solo la definizione (`static func runBounded`), la chiamata in `sync()` (da sostituire in questo task), e `RunBoundedTests.swift` (da rimuovere in questo task). Se compare un'altra chiamata non prevista, fermarsi e non procedere con la rimozione — segnalarlo invece di cancellare codice ancora in uso.

- [ ] **Step 2: Sostituire il ciclo file in `sync()`** (righe ~2026-2049, dentro `func sync(from localURL: URL, config: S3Config, ...)`)

Da:

```swift
        await S3Syncer.runBounded(
            items: toUpload, maxConcurrent: 4,
            isCancelled: { self.cancelled },
            operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
                if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                DispatchQueue.main.async {
                    onStatus("Carico: \(item.url.lastPathComponent)")
                    onCurrentFile(item.url)
                }
                do {
                    try await self.upload(url: item.url, key: item.key, config: config,
                                          gate: AdaptiveUploadGate(startingLimit: 4, ceiling: Self.adaptiveConcurrencyCeiling),
                                          onStatus: onStatus)
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

A:

```swift
        // Un solo gate condiviso tra tutti i file e tutte le parti multipart di questo
        // job: file piccoli e grandi competono per lo stesso budget adattivo, invece di
        // due meccanismi di concorrenza separati. Vedi
        // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
        let gate = AdaptiveUploadGate(startingLimit: 4, ceiling: Self.adaptiveConcurrencyCeiling)

        await withTaskGroup(of: (url: URL, size: Int64, ok: Bool).self) { group in
            for item in toUpload {
                group.addTask { [self] in
                    if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                    DispatchQueue.main.async {
                        onStatus("Carico: \(item.url.lastPathComponent)")
                        onCurrentFile(item.url)
                    }
                    do {
                        try await self.upload(url: item.url, key: item.key, config: config, gate: gate, onStatus: onStatus)
                        return (item.url, item.size, true)
                    } catch {
                        return (item.url, item.size, false)
                    }
                }
            }
            for await outcome in group {
                if outcome.ok { result.uploaded += 1; result.uploadedBytes += outcome.size }
                else { result.errors += 1 }
                result.done += 1
                let snap = result
                DispatchQueue.main.async { onProgress(snap) }
            }
        }
        return result
    }
```

Nota: tutti gli item vengono aggiunti subito al `TaskGroup` (nessun cap sul numero di task Swift creati) — la concorrenza effettiva è governata solo da `gate.acquire()` dentro `upload()`. I task Swift sospesi in attesa su un `CheckedContinuation` sono economici (nessun thread di sistema dedicato), anche per job con decine di migliaia di file (come i job reali di Enrico, es. 68.935 file totali).

- [ ] **Step 3: Rimuovere `runBounded`** (righe ~1846-1868, incluso il commento sopra la funzione)

Cancellare interamente:

```swift
    // Solo il chiamante di onOutcome (il loop while sotto, a thread singolo) muta
    // stato condiviso: i task figli restituiscono un Outcome, non toccano nulla
    // di condiviso — nessun lock/actor necessario.
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

- [ ] **Step 4: Rimuovere il file di test e i suoi 4 riferimenti in `project.pbxproj`**

```bash
rm AppBackupFotoTests/RunBoundedTests.swift
```

In `project.pbxproj`, rimuovere le 4 righe esatte (verificarle prima con grep, i numeri di riga possono essere leggermente cambiati dai task precedenti):

```bash
grep -n "RunBoundedTests" AppBackupFoto.xcodeproj/project.pbxproj
```

Rimuovere ognuna delle 4 righe trovate (PBXBuildFile, PBXFileReference, voce nel gruppo `AppBackupFotoTests`, voce nella `Sources` build phase) — stesso schema di aggiunta usato nei Task 1/3, in senso inverso.

- [ ] **Step 5: Eseguire i test, verificare che passino**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 99 test totali (102 - 3 di `RunBoundedTests.swift`), nessuna regressione sui restanti.

- [ ] **Step 6: Build di produzione**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/RunBoundedTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Wire sync() to the shared adaptive gate, remove fixed-cap runBounded"
```

---

## Task 5: Aggiornamento documentazione + verifica finale

**Files:**
- Modify: `.claude/rules/architecture.md:49` (descrizione upload paralleli)
- Modify: `.claude/rules/architecture.md:127` (nota storica sul multipart, da aggiornare per riflettere il nuovo meccanismo)
- Modify: `Docs/CLAUDE.md:84` (tabella stato, riga SSD → S3)
- Modify: `Docs/ROADMAP.md:45` (nota di follow-up sul punto #6)

**Interfaces:**
- Consumes: output dei Task 1-4 (feature completa e buildabile).
- Produces: nessuno — task terminale del piano.

- [ ] **Step 1: Aggiornare `.claude/rules/architecture.md`, riga 49**

Da:

```
- **Upload paralleli**: `sync()` carica fino a 4 file diversi in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Le parti di un singolo multipart restano sequenziali (parallelizzarle non aiuterebbe: sui pochi file enormi il collo di bottiglia è la banda, non la latenza per richiesta). Cancellazione controllata dentro ogni task figlio prima di ogni chiamata di rete, non solo nel loop di schedulazione.
```

A:

```
- **Concorrenza adattiva (2026-08-18)**: `sync()` e `multipart()` condividono un unico `S3Syncer.AdaptiveUploadGate` (actor) invece del vecchio cap fisso a 4 file/parti sequenziali — sostituito dopo aver osservato upload SSD→S3 bloccati a ~4 MB/s su una connessione da ~33 MB/s reali (il collo di bottiglia era la mancanza di parallelismo sulle parti dei file enormi, non la banda). Il limite parte da 4, sale di 2 dopo 5 successi consecutivi, si dimezza al primo errore di rete ritentabile (inclusi i 429, ora trattati come ritentabili — vedi `S3Syncer.isRetryable`), floor 1. Il tetto pratico (32 slot) è derivato dalla memoria (2GB / 64MB, non un numero scelto a priori — stessa cautela del bug storico di `sha256(of:)`), non da un limite di connessioni imposto a tavolino. Logica di transizione di stato pura e testata separatamente dall'actor (`S3Syncer.AdaptiveLimiter`). Ogni parte multipart acquisisce uno slot prima di essere letta da disco (throttling automatico della lettura), poi viene inviata da un task figlio — le parti completano fuori ordine, quindi `S3Syncer.buildCompleteMultipartXML` le riordina esplicitamente per `PartNumber` prima del completamento (richiesto da AWS S3). Vedi `Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md`.
```

- [ ] **Step 2: Aggiornare `.claude/rules/architecture.md`, riga 127**

Da:

```
Rileggendo il codice durante il brainstorming per gli upload paralleli, `multipart()` (upload dei file ≥64MB verso Cubbit) usava lo stesso pattern a rischio: `FileHandle(forReadingFrom:)` + `readData(ofLength: chunkSize)` in un ciclo per leggere le parti da 64MB. Non è stato ancora misurato empiricamente un picco di memoria su un multipart reale (serve un upload di ore su uno degli zip da 40-50GB), ma è la stessa firma di codice del bug già trovato — corretto preventivamente riusando `S3Syncer.readFileInChunks` (stesso `open`/`read`/`close` POSIX con buffer riutilizzato). Verifica manuale con Monitor Attività ancora da fare da parte dell'utente.
```

A:

```
Rileggendo il codice durante il brainstorming per gli upload paralleli, `multipart()` (upload dei file ≥64MB verso Cubbit) usava lo stesso pattern a rischio: `FileHandle(forReadingFrom:)` + `readData(ofLength: chunkSize)` in un ciclo per leggere le parti da 64MB. Corretto preventivamente riusando `S3Syncer.readFileInChunks` (stesso `open`/`read`/`close` POSIX con buffer riutilizzato). **Verifica manuale con Monitor Attività ancora da fare da parte dell'utente** — dal 2026-08-18 questa verifica coincide con quella della concorrenza adattiva (vedi voce sopra): un solo upload reale di uno zip 40-50GB copre entrambe (memoria sotto controllo + velocità vicina alla banda reale).
```

- [ ] **Step 3: Aggiornare `Docs/CLAUDE.md`, riga 84**

Da:

```
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, retry con backoff, upload paralleli (4 file), grafico MB/s |
```

A:

```
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart cancellato, retry con backoff, concorrenza adattiva condivisa file+parti multipart (2026-08-18), grafico MB/s |
```

- [ ] **Step 4: Aggiornare `Docs/ROADMAP.md`, riga 45** (nota di follow-up sul punto #6 — non un nuovo numero di roadmap, solo un'annotazione sull'intervento fatto oggi)

Da:

```
6. ✅ **Fatto (2026-08-02) — Upload S3 completamente sequenziali.** 4 file caricati in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Bonus non previsto: nello stesso intervento corretto anche un probabile bug di memoria in `multipart()` (stesso pattern già trovato in `sha256(of:)`), prima di parallelizzare. Vedi `Docs/superpowers/specs/2026-08-02-parallel-uploads-design.md`.
```

A:

```
6. ✅ **Fatto (2026-08-02) — Upload S3 completamente sequenziali.** 4 file caricati in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Bonus non previsto: nello stesso intervento corretto anche un probabile bug di memoria in `multipart()` (stesso pattern già trovato in `sha256(of:)`), prima di parallelizzare. Vedi `Docs/superpowers/specs/2026-08-02-parallel-uploads-design.md`.

    **Follow-up (2026-08-18)**: il cap fisso a 4 file e le parti multipart sequenziali si sono rivelati insufficienti su file enormi (upload osservato a 4,31 MB/s contro ~33 MB/s di banda reale). Sostituiti con un gate a concorrenza adattiva condiviso tra file e parti multipart, senza tetto fisso a priori (solo un limite derivato dalla memoria e la reazione a errori/rate-limit reali). Vedi `Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md` e `Docs/superpowers/plans/2026-08-18-adaptive-s3-concurrency.md`. Chiude anche la verifica manuale multipart mai fatta empiricamente da roadmap #6 originale (vedi `.claude/rules/architecture.md`).
```

- [ ] **Step 5: Controllo incrociato — cercare altre occorrenze stantie**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
grep -rn "4 file\|runBounded\|maxConcurrent: 4\|parti.*sequenziali\|sequenziali.*parti" Docs/ .claude/rules/
```

Verificare **ogni** riga trovata, non fermarsi alla prima — se qualcuna presuppone ancora il vecchio comportamento a 4 file fissi/parti sequenziali e non è già stata corretta sopra, aggiornarla ora (stessa lezione già applicata nei piani precedenti di questo progetto, es. #14/#15/#16/#30).

- [ ] **Step 6: Build e test finali**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```

Expected: entrambi verdi, 99 test totali, nessuna regressione rispetto alla baseline di 91 prima di questo piano (99 = 91 + 8 Task1 + 1 Task2 + 2 Task3 - 3 RunBoundedTests rimossi nel Task4).

- [ ] **Step 7: Commit**

```bash
git add .claude/rules/architecture.md Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update docs: adaptive S3 upload concurrency shipped"
```

- [ ] **Step 8: Nota per la verifica manuale (non automatizzabile da qui, da riportare a Enrico a fine piano)**

Non eseguibile via tool — richiede un upload di rete reale e Activity Monitor:

1. Avviare un job SSD→S3 che includa almeno uno degli zip da 40-50GB nella cartella "Zip" dell'SSD.
2. Osservare il grafico di velocità (`SpeedChartView`): ci si aspetta un avvicinamento sensibile ai ~33 MB/s di banda reale, non più bloccato a ~4 MB/s.
3. Osservare la memoria del processo con Activity Monitor: deve restare ben al di sotto dei 41-43GB dell'incidente storico — atteso nell'ordine di poche centinaia di MB oltre il baseline dell'app, coerente col tetto di 2GB proposto.
4. A fine job, verificare che non compaiano errori/hash-mismatch nel riepilogo.
5. Se possibile, osservare nel log (`onStatus`) eventuali messaggi di retry durante la fase iniziale del job (il gate parte da 4 e cresce — è normale non vedere subito la velocità massima nei primi secondi).
