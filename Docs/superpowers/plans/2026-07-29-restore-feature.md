# Restore Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere ad AppBackupFoto un percorso di restore guidato in 4 passi (fonte → cartelle → destinazione → avanzamento) da SSD, HDD o Cubbit S3 verso una cartella normale sul Mac, con linguaggio semplice e indicatori di disponibilità in tempo reale per ciascuna fonte.

**Architecture:** Nuovo `RestoreEngine` (separato da `BackupRunner`, riusa `FileSyncer` invariato) e nuova `RestoreView` a 4 step, entrambi in `AppBackupFoto/ContentView.swift`. Due aggiunte di download a `S3Syncer` (`downloadMany`, `checkReachable`) più una funzione pura (`topLevelFolders(fromKeys:)`). Include un fix isolato a `BackupRunner.run()` per una race condition già trovata.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest, macOS 13+.

## Global Constraints

- Tutto il codice nuovo va in `AppBackupFoto/ContentView.swift`; nessuno split di file.
- Zero delete, zero overwrite, read-only sulla sorgente — vale anche in direzione restore.
- La UI di avanzamento del restore è deliberatamente più semplice di `StatsPanel`: solo barra, "Recuperate X di Y foto", tempo stimato — niente copiati/skippati/errori/hash-mismatch esposti.
- Nessuna scrittura diretta nella libreria interna di Foto.app — solo cartella normale sul Mac.
- Le tre fonti (SSD/HDD/Cubbit) mostrano subito il loro stato reale nel primo passo — nessun bottone sempre-cliccabile che poi fallisce.
- Nessun test automatico per codice che richiede rete reale (`downloadMany`, `checkReachable`) — verifica manuale, coerente con il resto di `S3Syncer`.

---

## Task 1: Fix race stop()/successo in `BackupRunner.run()`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1105-1126` (dentro `private func run(label:work:)`)

**Interfaces:** Nessuna — fix isolato, nessun nuovo tipo.

- [ ] **Step 1: Applicare il fix**

Nel ramo di successo di `run(label:work:)`, subito dopo la riga che cancella `elapsedTimer`, aggiungere il controllo `wasStopped` già presente nel ramo `catch`. Cambia:

```swift
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    if let r = result {
```

in:

```swift
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    if let r = result {
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Eseguire la suite di test esistente per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: `** TEST SUCCEEDED **`, tutti i 19 test già esistenti verdi.

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Fix stop()/success race: a job that was stopped can no longer report Completato"
```

---

## Task 2: `S3Syncer.topLevelFolders(fromKeys:)` — funzione pura, con test

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:733-734` (dentro `final class S3Syncer`, tra `downloadToTemp` e `// MARK: - AWS Signature V4`)
- Test: `AppBackupFotoTests/RestoreS3FolderParsingTests.swift` (nuovo)

**Interfaces:**
- Produce: `static func topLevelFolders(fromKeys keys: [String]) -> [String]` su `S3Syncer`, usata da `RestoreEngine.listAvailableFolders(fromS3Config:)` nel Task 4.

- [ ] **Step 1: Scrivere il test (fallirà finché la funzione non esiste)**

Crea `AppBackupFotoTests/RestoreS3FolderParsingTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class RestoreS3FolderParsingTests: XCTestCase {
    func testMultipleFolders_areExtractedAndSorted() {
        let keys = ["Foto iPhone/a.jpg", "Takeout/b.jpg", "Foto iPhone/c.heic"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Foto iPhone", "Takeout"])
    }

    func testKeysWithoutSlash_areIgnored() {
        let keys = ["root-file.txt", "Foto iPhone/a.jpg"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Foto iPhone"])
    }

    func testDuplicateFolderNames_areDeduplicated() {
        let keys = ["Zip/a.jpg", "Zip/b.jpg", "Zip/nested/c.jpg"]
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: keys), ["Zip"])
    }

    func testEmptyList_returnsEmpty() {
        XCTAssertEqual(S3Syncer.topLevelFolders(fromKeys: []), [])
    }
}
```

- [ ] **Step 2: Registrare il file nel target di test**

Il progetto usa `PBXFileReference`/`PBXBuildFile` espliciti per `AppBackupFotoTests` (non un gruppo sincronizzato automaticamente). Genera due ID univoci e aggiungi le 4 voci necessarie in `AppBackupFoto.xcodeproj/project.pbxproj`, seguendo lo stesso schema già usato per `ReviewEngineIntegritySampleTests.swift` (`PBXBuildFile`, `PBXFileReference`, entry nel gruppo `AppBackupFotoTests`, entry nel `PBXSourcesBuildPhase` del target test):

```bash
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
python3 -c "import secrets; print(secrets.token_hex(12).upper())"
```

Usa il primo ID per `PBXBuildFile`/Sources, il secondo per `PBXFileReference`/gruppo.

- [ ] **Step 3: Eseguire il test e verificare che fallisca**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/RestoreS3FolderParsingTests 2>&1 | tail -20`

Expected: FAIL — `cannot find 'topLevelFolders' in scope` (o errore di compilazione equivalente).

- [ ] **Step 4: Implementare la funzione**

Dentro `final class S3Syncer`, subito dopo `downloadToTemp` (riga 733, `}`) e prima di `// MARK: - AWS Signature V4`, aggiungi:

```swift

    // Funzione pura, nessuna rete: prende le chiavi del bucket e restituisce i nomi
    // delle cartelle di primo livello (es. "Foto iPhone", "Takeout 2", ...), ordinate.
    static func topLevelFolders(fromKeys keys: [String]) -> [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for key in keys {
            guard key.contains("/"), let first = key.split(separator: "/", maxSplits: 1).first else { continue }
            let name = String(first)
            if !seen.contains(name) { seen.insert(name); ordered.append(name) }
        }
        return ordered.sorted()
    }
```

- [ ] **Step 5: Eseguire il test e verificare che passi**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test -only-testing:AppBackupFotoTests/RestoreS3FolderParsingTests 2>&1 | tail -20`

Expected: PASS — 4 test eseguiti, 0 falliti.

- [ ] **Step 6: Eseguire l'intera suite per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS — 23 test totali.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/RestoreS3FolderParsingTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add S3Syncer.topLevelFolders(fromKeys:) with tests"
```

---

## Task 3: `S3Syncer.downloadMany` e `checkReachable`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `final class S3Syncer`, subito dopo `topLevelFolders` aggiunta nel Task 2)

**Interfaces:**
- Consuma: `listAll(config:) async throws -> [String: Int64]` (esistente), `downloadToTemp(key:config:) async throws -> URL` (esistente), `S3Config` (esistente, nested type).
- Produce:
  - `struct DownloadManyResult` con `downloaded: Int = 0`, `skipped: Int = 0`, `total: Int = 0`, `done: Int = 0`, `problems: [String] = []`.
  - `func downloadMany(selectedFolders: Set<String>, config: S3Config, destination: URL, onStatus: @escaping (String) -> Void, onProgress: @escaping (DownloadManyResult) -> Void) async throws -> DownloadManyResult`, usata da `RestoreEngine.runS3` nel Task 4.
  - `func checkReachable(config: S3Config, timeoutSec: Double = 4) async -> Bool`, usata da `RestoreView` nel Task 5.

Nessun test automatico (rete reale) — build + nota di verifica manuale.

- [ ] **Step 1: Implementare `downloadMany` e `checkReachable`**

Subito dopo `topLevelFolders` (Task 2), aggiungi:

```swift

    struct DownloadManyResult {
        var downloaded = 0; var skipped = 0; var total = 0; var done = 0
        var problems: [String] = []
    }

    func downloadMany(selectedFolders: Set<String>, config: S3Config, destination: URL,
                       onStatus: @escaping (String) -> Void,
                       onProgress: @escaping (DownloadManyResult) -> Void) async throws -> DownloadManyResult {
        var result = DownloadManyResult()
        DispatchQueue.main.async { onStatus("Connessione a Cubbit — recupero elenco file...") }
        let all = try await listAll(config: config)
        let keys = all.keys.filter { key in
            guard let first = key.split(separator: "/", maxSplits: 1).first else { return false }
            return selectedFolders.contains(String(first))
        }
        result.total = keys.count
        let fm = FileManager.default

        for key in keys {
            let destFile = destination.appendingPathComponent(key)
            if fm.fileExists(atPath: destFile.path) {
                result.skipped += 1
            } else {
                DispatchQueue.main.async { onStatus("Recupero: \(key)") }
                do {
                    let tempURL = try await downloadToTemp(key: key, config: config)
                    let parent = destFile.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parent.path) {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    try fm.moveItem(at: tempURL, to: destFile)
                    result.downloaded += 1
                } catch {
                    result.problems.append("\(key) — \(error.localizedDescription)")
                }
            }
            result.done += 1
            let snap = result
            DispatchQueue.main.async { onProgress(snap) }
        }
        return result
    }

    // Controllo rapido di raggiungibilità (solo per il primo passo del restore):
    // timeout breve dedicato, non condivide la `session` con timeout da 300s usata altrove.
    func checkReachable(config: S3Config, timeoutSec: Double = 4) async -> Bool {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else { return false }
        comps.queryItems = [URLQueryItem(name: "list-type", value: "2"),
                             URLQueryItem(name: "max-keys", value: "1")]
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSec
        cfg.timeoutIntervalForResource = timeoutSec
        let quickSession = URLSession(configuration: cfg)
        guard let (_, resp) = try? await quickSession.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Eseguire la suite esistente**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 23 test.

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add S3Syncer.downloadMany and checkReachable for restore"
```

*Verifica manuale da fare più avanti (Task 8), non ora: nessun disco/rete garantiti disponibili durante lo sviluppo di questo singolo task.*

---

## Task 4: `RestoreEngine` (motore, nessuna UI)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo blocco `// MARK: - Restore`, subito dopo la chiusura di `final class ReviewEngine` e prima di `// MARK: - SetupView`)

**Interfaces:**
- Consuma: `FileSyncer.previewSync(from:to:deep:) async -> (toAdd: Int, toSkip: Int, estimatedSec: Int)`, `FileSyncer.sync(from:to:deep:onStatus:onProgress:) async throws -> FileSyncer.SyncResult`, `FileSyncer.cancel()` (tutti esistenti, invariati). `S3Syncer.downloadMany(...)`, `S3Syncer.listAll(config:)`, `S3Syncer.topLevelFolders(fromKeys:)` (Task 2/3). `JobPhase` (esistente enum idle/running/success/failed).
- Produce: `RestoreSource`, `RestoreProgress`, `final class RestoreEngine: ObservableObject` con `phase: JobPhase`, `progress: RestoreProgress`, `listAvailableFolders(rootURL:) -> [String]`, `listAvailableFolders(fromS3Config:) async throws -> [String]`, `estimateS3Download(selectedFolders:destination:config:) async throws -> (count: Int, bytes: Int64)`, `run(source:selectedFolders:sourceRootURL:destination:s3Config:)`, `stop()` — tutti usati da `RestoreView` nei Task 5-6.

Nessun test automatico dedicato (richiede bookmark reali o rete) — build come verifica.

- [ ] **Step 1: Individuare il punto di inserimento**

Run: `grep -n "^final class ReviewEngine\|^// MARK: - SetupView" AppBackupFoto/ContentView.swift`

Expected: due righe, la chiusura di `ReviewEngine` è la riga `}` immediatamente prima di `// MARK: - SetupView`.

- [ ] **Step 2: Aggiungere il blocco `RestoreEngine`**

Subito dopo la chiusura di `final class ReviewEngine` e prima di `// MARK: - SetupView`, inserisci:

```swift

// MARK: - Restore

enum RestoreSource: String, Identifiable {
    case ssd, hdd, s3
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ssd: return "Dal mio SSD"
        case .hdd: return "Dal mio HDD"
        case .s3:  return "Da Cubbit (cloud)"
        }
    }
}

struct RestoreProgress {
    var done: Int = 0
    var total: Int = 0
    var startDate: Date = Date()
    var problems: [String] = []
    var percent: Int { total > 0 ? min(100, done * 100 / total) : 0 }
    var etaSec: Int {
        guard done > 0, total > done else { return 0 }
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0.5 else { return 0 }
        return Int(elapsed * Double(total - done) / Double(done))
    }
}

@MainActor
final class RestoreEngine: ObservableObject {
    @Published var phase: JobPhase = .idle
    @Published var progress = RestoreProgress()

    private let syncer = FileSyncer()
    private let s3Syncer = S3Syncer()
    private var wasStopped = false

    func listAvailableFolders(rootURL: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> String? in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard vals?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            return name.hasPrefix(".") ? nil : name
        }.sorted()
    }

    func listAvailableFolders(fromS3Config config: S3Syncer.S3Config) async throws -> [String] {
        let keys = try await s3Syncer.listAll(config: config).keys
        return S3Syncer.topLevelFolders(fromKeys: Array(keys))
    }

    func estimateS3Download(selectedFolders: Set<String>, destination: URL,
                             config: S3Syncer.S3Config) async throws -> (count: Int, bytes: Int64) {
        let all = try await s3Syncer.listAll(config: config)
        let fm = FileManager.default
        var count = 0; var bytes: Int64 = 0
        for (key, size) in all {
            guard let first = key.split(separator: "/", maxSplits: 1).first,
                  selectedFolders.contains(String(first)) else { continue }
            guard !fm.fileExists(atPath: destination.appendingPathComponent(key).path) else { continue }
            count += 1; bytes += size
        }
        return (count, bytes)
    }

    func run(source: RestoreSource, selectedFolders: Set<String>, sourceRootURL: URL?,
             destination: URL, s3Config: S3Syncer.S3Config?) {
        wasStopped = false
        progress = RestoreProgress()
        phase = .running(source.displayName)

        Task { [weak self] in
            guard let self else { return }
            do {
                switch source {
                case .ssd, .hdd:
                    guard let sourceRootURL else {
                        throw NSError(domain: "Restore", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Cartella sorgente non disponibile"])
                    }
                    try await self.runLocal(sourceRootURL: sourceRootURL, selectedFolders: selectedFolders,
                                             destination: destination)
                case .s3:
                    guard let s3Config else {
                        throw NSError(domain: "Restore", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Configurazione Cubbit non disponibile"])
                    }
                    try await self.runS3(selectedFolders: selectedFolders, destination: destination, config: s3Config)
                }
                guard !self.wasStopped else { return }
                self.phase = .success("Ripristino completato")
            } catch {
                guard !self.wasStopped else { return }
                self.phase = .failed("Errore: \(error.localizedDescription)")
            }
        }
    }

    private func runLocal(sourceRootURL: URL, selectedFolders: Set<String>, destination: URL) async throws {
        let folders = selectedFolders.sorted()
        var combinedTotal = 0
        for folder in folders {
            let preview = await syncer.previewSync(from: sourceRootURL.appendingPathComponent(folder),
                                                     to: destination.appendingPathComponent(folder), deep: false)
            combinedTotal += preview.toAdd + preview.toSkip
        }
        progress.total = combinedTotal

        var offset = 0
        for folder in folders {
            let result = try await syncer.sync(
                from: sourceRootURL.appendingPathComponent(folder),
                to: destination.appendingPathComponent(folder),
                deep: false,
                onStatus: { _ in },
                onProgress: { [weak self] snap in
                    Task { @MainActor [weak self] in
                        self?.progress.done = offset + snap.done
                    }
                })
            offset += result.done
            if result.errors > 0 {
                progress.problems.append("\(folder): \(result.errors) file non recuperati")
            }
        }
        progress.done = offset
    }

    private func runS3(selectedFolders: Set<String>, destination: URL, config: S3Syncer.S3Config) async throws {
        let result = try await s3Syncer.downloadMany(
            selectedFolders: selectedFolders, config: config, destination: destination,
            onStatus: { _ in },
            onProgress: { [weak self] snap in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.progress.done = snap.done
                    self.progress.total = snap.total
                }
            })
        progress.problems.append(contentsOf: result.problems)
    }

    func stop() {
        wasStopped = true
        syncer.cancel()
        phase = .failed("Interrotto dall'utente")
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`. Se il compilatore segnala ambiguità su `onProgress` catturando `offset` (var mutabile in una closure `@escaping`), usa una copia locale immutabile all'interno della closure prima di sommare (`let base = offset`) — verificalo in base all'esito reale del build, non è un problema noto ma Swift a volte richiede questa cautela con var catturate da closure `@escaping` invocate più volte.

- [ ] **Step 4: Eseguire la suite esistente**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 23 test (nessun nuovo test in questo task).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add RestoreEngine: local (SSD/HDD) and S3 restore, simplified progress model"
```

---

## Task 5: `RestoreView` — passo 1 (scelta fonte con indicatori di disponibilità)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuova `struct RestoreView`, subito dopo il blocco `RestoreEngine` del Task 4, prima di `// MARK: - SetupView`)

**Interfaces:**
- Consuma: `VolumeMonitor` (esistente: `ssdMounted`, `hddMounted`), `BookmarkManager.shared` (`urls[.ssd]`, `urls[.hdd]`, `selectAndSave(_:completion:)`), `S3Syncer.readConfig()`, `S3Syncer().checkReachable(config:)` (Task 3), `RestoreEngine` (Task 4).
- Produce: `struct RestoreView: View` con step interno `chooseSource` funzionante; gli altri step sono placeholder minimi in questo task, completati nel Task 6.

- [ ] **Step 1: Creare lo scheletro di `RestoreView` con lo step `chooseSource`**

Subito dopo la chiusura di `final class RestoreEngine` (Task 4) e prima di `// MARK: - SetupView`, aggiungi:

```swift

struct RestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    @StateObject private var volumes = VolumeMonitor()
    @StateObject private var engine = RestoreEngine()
    private let s3Syncer = S3Syncer()

    enum Step { case chooseSource, chooseFolders, chooseDestination, running }
    enum S3Status { case checking, available, unavailable(String) }

    @State private var step: Step = .chooseSource
    @State private var selectedSource: RestoreSource?
    @State private var sourceRootURL: URL?
    @State private var s3Config: S3Syncer.S3Config?
    @State private var s3Status: S3Status = .checking
    @State private var availableFolders: [String] = []
    @State private var selectedFolders: Set<String> = []
    @State private var destinationURL: URL?
    @State private var showS3EstimateAlert = false
    @State private var s3EstimateText = ""

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .chooseSource: chooseSourceStep
            case .chooseFolders: Text("Passo 2 — cartelle (Task 6)")
            case .chooseDestination: Text("Passo 3 — destinazione (Task 6)")
            case .running: Text("Passo 4 — avanzamento (Task 6)")
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 440)
        .task { await checkS3Reachability() }
    }

    private var chooseSourceStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 40)).foregroundStyle(.blue)
                Text("Da dove vuoi ripristinare?").font(.title2).fontWeight(.semibold)
            }
            VStack(spacing: 10) {
                restoreSourceRow(.ssd, available: volumes.ssdMounted,
                                  unavailableReason: "non collegato in questo momento")
                restoreSourceRow(.hdd, available: volumes.hddMounted,
                                  unavailableReason: "non collegato in questo momento")
                s3SourceRow
            }
            Spacer()
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private func restoreSourceRow(_ source: RestoreSource, available: Bool, unavailableReason: String) -> some View {
        Button {
            selectedSource = source
            let loc: BookmarkManager.Location = source == .ssd ? .ssd : .hdd
            if let existing = bm.urls[loc] {
                sourceRootURL = existing
                proceedToFolders(rootURL: existing)
            } else {
                bm.selectAndSave(loc) { ok in
                    guard ok, let url = bm.urls[loc] else { return }
                    sourceRootURL = url
                    proceedToFolders(rootURL: url)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName).font(.system(size: 14, weight: .medium))
                    if !available {
                        Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
    }

    private var s3SourceRow: some View {
        Group {
            switch s3Status {
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifica Cubbit in corso…").font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(14).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
            case .available:
                Button {
                    selectedSource = .s3
                    proceedToFolders(rootURL: nil)
                } label: {
                    HStack {
                        Text(RestoreSource.s3.displayName).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            case .unavailable(let reason):
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RestoreSource.s3.displayName).font(.system(size: 14, weight: .medium))
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.45)
            }
        }
    }

    private func checkS3Reachability() async {
        do {
            let cfg = try S3Syncer.readConfig()
            s3Config = cfg
            let reachable = await s3Syncer.checkReachable(config: cfg)
            s3Status = reachable ? .available : .unavailable("non raggiungibile in questo momento")
        } catch {
            s3Status = .unavailable("configurazione mancante")
        }
    }

    private func proceedToFolders(rootURL: URL?) {
        Task {
            let folders: [String]
            if let rootURL {
                folders = engine.listAvailableFolders(rootURL: rootURL)
            } else if let s3Config {
                folders = (try? await engine.listAvailableFolders(fromS3Config: s3Config)) ?? []
            } else {
                folders = []
            }
            await MainActor.run {
                availableFolders = folders
                selectedFolders = Set(folders)
                step = .chooseFolders
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add RestoreView step 1: source picker with live availability indicators"
```

---

## Task 6: `RestoreView` — passi 2-4 (cartelle, destinazione, avanzamento)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `struct RestoreView`, Task 5)

**Interfaces:**
- Consuma: `RestoreEngine.run(...)`, `RestoreEngine.stop()`, `RestoreEngine.estimateS3Download(...)`, `RestoreProgress`, `JobPhase` (Task 4).

- [ ] **Step 1: Sostituire i tre placeholder con le view reali**

Nel `body` di `RestoreView`, cambia:

```swift
            case .chooseFolders: Text("Passo 2 — cartelle (Task 6)")
            case .chooseDestination: Text("Passo 3 — destinazione (Task 6)")
            case .running: Text("Passo 4 — avanzamento (Task 6)")
```

in:

```swift
            case .chooseFolders: chooseFoldersStep
            case .chooseDestination: chooseDestinationStep
            case .running: runningStep
```

- [ ] **Step 2: Aggiungere le tre view, dopo `proceedToFolders`**

```swift

    private var chooseFoldersStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(.blue)
                Text("Cosa vuoi ripristinare?").font(.title2).fontWeight(.semibold)
                Text("Sono già tutte selezionate — deseleziona solo quello che non ti serve.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(availableFolders, id: \.self) { folder in
                        Button {
                            if selectedFolders.contains(folder) { selectedFolders.remove(folder) }
                            else { selectedFolders.insert(folder) }
                        } label: {
                            HStack {
                                Image(systemName: selectedFolders.contains(folder) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedFolders.contains(folder) ? Color.accentColor : Color.secondary)
                                Text(folder).font(.system(size: 14))
                                Spacer()
                            }
                            .padding(10).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Indietro") { step = .chooseSource }.buttonStyle(.bordered)
                Spacer()
                Button("Continua") { step = .chooseDestination }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFolders.isEmpty)
            }
        }
    }

    private var chooseDestinationStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 36)).foregroundStyle(.blue)
                Text("Dove vuoi salvare le foto?").font(.title2).fontWeight(.semibold)
                Text("Dopo potrai trascinarle nell'app Foto quando vuoi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let destinationURL {
                Text(destinationURL.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button(destinationURL == nil ? "Scegli cartella…" : "Cambia cartella…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Scegli"
                if panel.runModal() == .OK, let url = panel.url { destinationURL = url }
            }.buttonStyle(.bordered)
            Spacer()
            HStack {
                Button("Indietro") { step = .chooseFolders }.buttonStyle(.bordered)
                Spacer()
                Button("Ripristina") { startRestore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(destinationURL == nil)
            }
        }
        .alert("Prima di scaricare da Cubbit", isPresented: $showS3EstimateAlert) {
            Button("Annulla", role: .cancel) { }
            Button("Continua") { beginRun() }
        } message: { Text(s3EstimateText) }
    }

    private var runningStep: some View {
        VStack(spacing: 20) {
            switch engine.phase {
            case .running:
                ProgressView(value: Double(engine.progress.percent), total: 100)
                    .progressViewStyle(.linear).frame(maxWidth: 320)
                Text("Recuperate \(engine.progress.done) di \(engine.progress.total) foto")
                    .font(.system(size: 15, weight: .medium))
                if engine.progress.etaSec > 0 {
                    Text("Tempo stimato: \(FileSyncer.SyncResult.hms(engine.progress.etaSec))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Interrompi") { engine.stop() }.buttonStyle(.bordered).tint(.red)
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("Fatto! Le tue foto sono qui").font(.title3).fontWeight(.semibold)
                if let destinationURL {
                    Button("Apri cartella") { NSWorkspace.shared.activateFileViewerSelecting([destinationURL]) }
                        .buttonStyle(.bordered)
                }
                if !engine.progress.problems.isEmpty {
                    Text("\(engine.progress.problems.count) file non è stato possibile recuperare")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                Text(msg).font(.system(size: 14)).multilineTextAlignment(.center)
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent)
            case .idle:
                ProgressView()
            }
        }
    }

    private func startRestore() {
        guard let selectedSource else { return }
        if selectedSource == .s3, let destinationURL, let s3Config {
            Task {
                let estimate = try? await engine.estimateS3Download(
                    selectedFolders: selectedFolders, destination: destinationURL, config: s3Config)
                await MainActor.run {
                    if let estimate {
                        let gb = Double(estimate.bytes) / 1_073_741_824
                        s3EstimateText = "Stai per scaricare \(estimate.count) file (~\(String(format: "%.1f", gb)) GB). Potrebbe richiedere qualche ora."
                    } else {
                        s3EstimateText = "Impossibile stimare la dimensione — continuo comunque?"
                    }
                    showS3EstimateAlert = true
                }
            }
        } else {
            beginRun()
        }
    }

    private func beginRun() {
        guard let selectedSource, let destinationURL else { return }
        step = .running
        engine.run(source: selectedSource, selectedFolders: selectedFolders,
                   sourceRootURL: sourceRootURL, destination: destinationURL, s3Config: s3Config)
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Eseguire la suite esistente**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 23 test.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Complete RestoreView: folder selection, destination picker, simplified progress screen"
```

---

## Task 7: Punti di accesso — hamburger e SetupView

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1755-1756` (dentro `struct HamburgerPanel`, aggiungere `@State`)
- Modify: `AppBackupFoto/ContentView.swift` (dentro `HamburgerPanel.body`, riga della sezione "Strumenti")
- Modify: `AppBackupFoto/ContentView.swift:1826-1827` (aggiungere il nuovo `.sheet`)
- Modify: `AppBackupFoto/ContentView.swift` (dentro `struct SetupView`, sotto i tre `LocationRow`)

**Interfaces:** Consuma `RestoreView` (Task 5-6). Nessuna nuova interfaccia prodotta.

- [ ] **Step 1: Aggiungere lo stato e la riga nell'hamburger**

Cambia:

```swift
    @State private var showAppearance = false
    @State private var showTools = false
```

in:

```swift
    @State private var showAppearance = false
    @State private var showTools = false
    @State private var showRestore = false
```

Poi, dentro la sezione "Strumenti", subito dopo la riga "Report Log" e prima di "Configurazione":

```swift
                        HamburgerRow(icon: "doc.text.magnifyingglass", label: "Report Log", iconColor: .blue) {
                            onShowLog?(); close()
                        }
                        HamburgerRow(icon: "arrow.down.doc.fill", label: "Ripristina", iconColor: .green) {
                            showRestore = true; close()
                        }
                        HamburgerRow(icon: "gearshape.fill", label: "Configurazione", iconColor: Color(NSColor.systemGray)) {
```

(sostituisce le prime 3 righe esistenti con queste 6, inserendo la nuova `HamburgerRow` in mezzo)

- [ ] **Step 2: Aggiungere il nuovo `.sheet`**

Cambia:

```swift
        .sheet(isPresented: $showAppearance) { AppearanceSheet() }
        .sheet(isPresented: $showTools)      { ToolsSheet() }
```

in:

```swift
        .sheet(isPresented: $showAppearance) { AppearanceSheet() }
        .sheet(isPresented: $showTools)      { ToolsSheet() }
        .sheet(isPresented: $showRestore)    { RestoreView() }
```

- [ ] **Step 3: Aggiungere il bottone in `SetupView`**

Dentro `struct SetupView`, aggiungi lo stato e il bottone. Cambia:

```swift
struct SetupView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    var body: some View {
        VStack(spacing: 28) {
```

in:

```swift
struct SetupView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    @State private var showRestore = false
    var body: some View {
        VStack(spacing: 28) {
```

Poi cambia:

```swift
            Text("Appena selezioni la Libreria Foto l'app si apre — SSD e HDD puoi configurarli quando vuoi, anche più avanti da Impostazioni.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(40).frame(minWidth: 500, minHeight: 420)
    }
}
```

in:

```swift
            Text("Appena selezioni la Libreria Foto l'app si apre — SSD e HDD puoi configurarli quando vuoi, anche più avanti da Impostazioni.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Ho già un backup, voglio ripristinare") { showRestore = true }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(40).frame(minWidth: 500, minHeight: 420)
        .sheet(isPresented: $showRestore) { RestoreView() }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Avviare l'app e verificare visivamente**

Run (da Xcode, `Cmd+R`), poi controlla a occhio: la riga "Ripristina" compare nell'hamburger con icona verde; il bottone "Ho già un backup, voglio ripristinare" compare in fondo alla schermata di Configurazione; entrambi aprono la stessa schermata a 4 passi; nel primo passo SSD/HDD mostrano lo stato reale (collegato/non collegato) e Cubbit mostra "Verifica in corso…" poi si assesta su selezionabile o "non raggiungibile".

- [ ] **Step 6: Eseguire la suite esistente**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 23 test.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Wire Restore entry points: hamburger row and SetupView button"
```

---

## Task 8: Aggiornare `Docs/CLAUDE.md` e verifica finale

**Files:**
- Modify: `Docs/CLAUDE.md`

- [ ] **Step 1: Aggiungere la sezione Restore all'architettura**

Nella sezione `## Architettura Swift`, dopo la sottosezione `### ReviewEngine`, aggiungi:

```markdown

### RestoreEngine e RestoreView (ripristino guidato)

- `RestoreEngine` — separato da `BackupRunner`, riusa `FileSyncer` invariato per SSD/HDD; per Cubbit usa `S3Syncer.downloadMany`. Modello di progresso volutamente semplice (`RestoreProgress`: done/total/eta/problems), non `JobStats`.
- `RestoreView` — 4 passi: scelta fonte (con indicatori di disponibilità in tempo reale: `VolumeMonitor` per SSD/HDD, `S3Syncer.checkReachable` per Cubbit), scelta cartelle, scelta destinazione, avanzamento. Le foto atterrano in una cartella normale sul Mac, non nella libreria di Foto.app — l'utente le importa lui in Foto con un paio di click.
- Raggiungibile da hamburger → Ripristina, e da un bottone secondario in `SetupView` (visibile anche a configurazione incompleta, grazie a `canEnterApp`).
```

- [ ] **Step 2: Aggiornare la tabella "Stato attuale"**

Aggiungi una riga:

```markdown
| Restore guidato (SSD/HDD/Cubbit → cartella) | ✅ Implementato — 4 passi, indicatori di disponibilità in tempo reale |
```

E aggiorna la riga dei test automatici con il nuovo conteggio (23).

- [ ] **Step 3: Build + suite completa**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`, tutti i 23 test verdi.

- [ ] **Step 4: Commit**

```bash
git add Docs/CLAUDE.md
git commit -m "Update Docs/CLAUDE.md: restore feature shipped"
```
