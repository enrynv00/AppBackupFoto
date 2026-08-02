# Orphaned Multipart Upload Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scoprire e permettere la pulizia manuale degli upload multipart S3 rimasti orfani (crash, spegnimento, kill del processo a metà upload), integrata nel pannello Revisione già esistente in `ToolsSheet`.

**Architecture:** Due nuove funzioni su `S3Syncer` (`listMultipartUploads`, `abortMultipartUpload` — quest'ultima estratta dalla logica DELETE già inline nel cancel di `multipart(...)`), una nuova funzione su `ReviewEngine` che le orchestra, e una nuova sotto-sezione UI in `ToolsSheet` disattivata mentre un job è in corso.

**Tech Stack:** Swift 5.x, SwiftUI, `URLSession` async/await, macOS 13+.

## Global Constraints

- Tutto il codice nuovo va in `AppBackupFoto/ContentView.swift`; nessuno split di file.
- Nessuna cancellazione automatica — sempre conferma esplicita per singolo upload.
- Scoperta disattivata mentre `runner.isRunning` è vero — mai offrire di cancellare un upload che potrebbe essere ancora in corso.
- Nessuna paginazione di `ListMultipartUploads` (fino a 1000 risultati in una chiamata) — sufficiente per un account personale.
- Nessun test automatico (rete reale verso Cubbit) — verifica manuale.

---

## Task 1: `S3Syncer` — `OrphanedMultipartUpload`, `listMultipartUploads`, `abortMultipartUpload`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `final class S3Syncer`: nuovo struct vicino a `S3HTTPError`, nuove funzioni vicino a `listAll`/`multipart`, e il ramo cancel di `multipart(...)` aggiornato per riusare `abortMultipartUpload`)

**Interfaces:**
- Produce: `S3Syncer.OrphanedMultipartUpload` (struct, `Identifiable`, campi `key: String`, `uploadId: String`, `initiated: Date`); `func listMultipartUploads(config: S3Config) async throws -> [OrphanedMultipartUpload]`; `func abortMultipartUpload(key: String, uploadId: String, config: S3Config) async throws`. Usate dal Task 2 (`ReviewEngine`) e dal Task 3 (UI).

- [ ] **Step 1: Aggiungere `OrphanedMultipartUpload`**

Trova `struct S3HTTPError { ... }` dentro `final class S3Syncer` (subito dopo `struct S3Config`). Subito dopo la sua chiusura, aggiungi:

```swift

    struct OrphanedMultipartUpload: Identifiable {
        let id = UUID()
        let key: String
        let uploadId: String
        let initiated: Date
    }
```

- [ ] **Step 2: Aggiungere `abortMultipartUpload` e riscrivere il ramo cancel di `multipart` per riusarla**

Cerca dentro `multipart(url:key:config:onStatus:)` il blocco:

```swift
        if cancelled {
            if let abortURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") {
                var abortReq = URLRequest(url: abortURL)
                abortReq.httpMethod = "DELETE"
                sign(&abortReq, config: config, body: Data(), date: Date())
                _ = try? await session.data(for: abortReq)
            }
            throw CancellationError()
        }
```

Sostituiscilo con:

```swift
        if cancelled {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw CancellationError()
        }
```

Poi, subito dopo la chiusura della funzione `multipart(url:key:config:onStatus:)` (il `}` che la chiude), aggiungi la nuova funzione:

```swift

    func abortMultipartUpload(key: String, uploadId: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let encId = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId
        guard let abortURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per abort: \(key)"])
        }
        var abortReq = URLRequest(url: abortURL)
        abortReq.httpMethod = "DELETE"
        sign(&abortReq, config: config, body: Data(), date: Date())
        let (_, resp) = try await session.data(for: abortReq)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw S3HTTPError(statusCode: statusCode, message: "Errore abort upload \(key)")
        }
    }
```

- [ ] **Step 3: Aggiungere `listMultipartUploads`**

Trova `func listAll(config: S3Config) async throws -> [String: Int64] { ... }`. Subito dopo la sua chiusura, aggiungi:

```swift

    func listMultipartUploads(config: S3Config) async throws -> [OrphanedMultipartUpload] {
        guard let url = URL(string: "\(config.endpoint)/\(config.bucket)?uploads") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list multipart"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista multipart: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let keys = xmlAll(xml, tag: "Key")
        let uploadIds = xmlAll(xml, tag: "UploadId")
        let initiatedStrings = xmlAll(xml, tag: "Initiated")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var results: [OrphanedMultipartUpload] = []
        let count = min(keys.count, uploadIds.count, initiatedStrings.count)
        for i in 0..<count {
            let initiated = fmt.date(from: initiatedStrings[i]) ?? Date()
            results.append(OrphanedMultipartUpload(key: keys[i], uploadId: uploadIds[i], initiated: initiated))
        }
        return results
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Eseguire l'intera suite per verificare che non ci siano regressioni**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 34 test (nessun nuovo test in questo task).

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add S3Syncer.listMultipartUploads/abortMultipartUpload, dedupe cancel-branch abort logic"
```

---

## Task 2: `ReviewEngine.findOrphanedMultipartUploads()`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `final class ReviewEngine`, vicino a `runConfigChecks`/`runIntegritySample`)

**Interfaces:**
- Consuma: `S3Syncer.readConfig()` (esistente), `s3Syncer.listMultipartUploads(config:)` (Task 1), `s3Syncer` (proprietà già esistente di `ReviewEngine`).
- Produce: `func findOrphanedMultipartUploads() async throws -> [S3Syncer.OrphanedMultipartUpload]`, usata dal Task 3.

- [ ] **Step 1: Individuare il punto di inserimento**

Run: `grep -n "func runConfigChecks" AppBackupFoto/ContentView.swift`

Expected: una riga, dentro `final class ReviewEngine`.

- [ ] **Step 2: Aggiungere la funzione**

Subito dopo `func runConfigChecks() -> [ReviewFinding] { ... }` (la sua chiusura), aggiungi:

```swift

    func findOrphanedMultipartUploads() async throws -> [S3Syncer.OrphanedMultipartUpload] {
        let config = try S3Syncer.readConfig()
        return try await s3Syncer.listMultipartUploads(config: config)
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add ReviewEngine.findOrphanedMultipartUploads"
```

---

## Task 3: Plumbing `isRunning` + sotto-sezione "Upload incompleti" in `ToolsSheet`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:2182-2189` (istanza di `HamburgerPanel` dentro `ContentView`)
- Modify: `AppBackupFoto/ContentView.swift:2402-2413` (dichiarazione di `struct HamburgerPanel`)
- Modify: `AppBackupFoto/ContentView.swift:2487` (`.sheet(isPresented: $showTools) { ToolsSheet() }`)
- Modify: `AppBackupFoto/ContentView.swift:2815-2830` (dichiarazione di `struct ToolsSheet`, nuovo stato)
- Modify: `AppBackupFoto/ContentView.swift:2992-2994` (nuova sotto-sezione dopo "Revisione", prima della chiusura)

**Interfaces:**
- Consuma: `ReviewEngine.findOrphanedMultipartUploads()` (Task 2), `S3Syncer.OrphanedMultipartUpload`, `S3Syncer().abortMultipartUpload(key:uploadId:config:)` (Task 1), `S3Syncer.readConfig()` (esistente), `runner.isRunning` (proprietà già esistente di `BackupRunner`, letta da `ContentView`).

- [ ] **Step 1: Passare `isRunning` da `ContentView` a `HamburgerPanel`**

Cambia:

```swift
                HamburgerPanel(isVisible: $showHamburger, showSettings: $showSettings, onShowLog: {
                    activeSpeedTab = .log
                    withAnimation(.easeInOut(duration: 0.22)) { showHamburger = false }
                })
```

in:

```swift
                HamburgerPanel(isVisible: $showHamburger, showSettings: $showSettings, isJobRunning: runner.isRunning, onShowLog: {
                    activeSpeedTab = .log
                    withAnimation(.easeInOut(duration: 0.22)) { showHamburger = false }
                })
```

- [ ] **Step 2: `HamburgerPanel` accetta e propaga `isJobRunning`**

Cambia:

```swift
struct HamburgerPanel: View {
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    var onShowLog: (() -> Void)? = nil
```

in:

```swift
struct HamburgerPanel: View {
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    var isJobRunning: Bool = false
    var onShowLog: (() -> Void)? = nil
```

Poi cambia:

```swift
        .sheet(isPresented: $showTools)      { ToolsSheet() }
```

in:

```swift
        .sheet(isPresented: $showTools)      { ToolsSheet(isJobRunning: isJobRunning) }
```

- [ ] **Step 3: `ToolsSheet` accetta `isJobRunning` e aggiunge lo stato per gli upload orfani**

Cambia:

```swift
struct ToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    @State private var showSecret = false
    @State private var reviewFindings: [ReviewFinding] = []
    @State private var lastJob: JobSummary? = JobHistoryStore.load()
    @State private var integrityResults: [IntegrityCheckResult] = []
    @State private var integrityRunning = false
    @State private var integrityStatus = ""
    private let reviewEngine = ReviewEngine()
```

in:

```swift
struct ToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    var isJobRunning: Bool = false
    @State private var showSecret = false
    @State private var reviewFindings: [ReviewFinding] = []
    @State private var lastJob: JobSummary? = JobHistoryStore.load()
    @State private var integrityResults: [IntegrityCheckResult] = []
    @State private var integrityRunning = false
    @State private var integrityStatus = ""
    @State private var orphanedUploads: [S3Syncer.OrphanedMultipartUpload] = []
    @State private var orphanedUploadsChecked = false
    private let reviewEngine = ReviewEngine()

    private let uploadDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()
```

- [ ] **Step 4: Aggiungere la sotto-sezione UI e la chiamata di scoperta automatica**

Cambia:

```swift
                }.padding(4)
            }
            .onAppear { reviewFindings = reviewEngine.runConfigChecks() }

            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
```

in:

```swift
                    Divider()

                    if isJobRunning {
                        Text("Controllo upload incompleti disponibile a job fermo")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !orphanedUploads.isEmpty {
                        Text("Upload incompleti trovati").font(.caption).fontWeight(.medium)
                        ForEach(orphanedUploads) { upload in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((upload.key as NSString).lastPathComponent).font(.caption2)
                                    Text("iniziato il \(uploadDateFormatter.string(from: upload.initiated))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Elimina") {
                                    let a = NSAlert()
                                    a.messageText = "Eliminare questo upload incompleto?"
                                    a.informativeText = "Rimuove definitivamente le parti già caricate su Cubbit per '\((upload.key as NSString).lastPathComponent)'. Non tocca file già completati né la sorgente."
                                    a.alertStyle = .warning
                                    a.addButton(withTitle: "Elimina")
                                    a.addButton(withTitle: "Annulla")
                                    guard a.runModal() == .alertFirstButtonReturn else { return }
                                    Task {
                                        do {
                                            let config = try S3Syncer.readConfig()
                                            try await S3Syncer().abortMultipartUpload(
                                                key: upload.key, uploadId: upload.uploadId, config: config)
                                            await MainActor.run {
                                                orphanedUploads.removeAll { $0.id == upload.id }
                                            }
                                        } catch {
                                            await MainActor.run {
                                                let errA = NSAlert()
                                                errA.messageText = "Impossibile eliminare l'upload"
                                                errA.informativeText = error.localizedDescription
                                                errA.alertStyle = .critical
                                                errA.runModal()
                                            }
                                        }
                                    }
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }.padding(4)
            }
            .onAppear {
                reviewFindings = reviewEngine.runConfigChecks()
                guard !isJobRunning, !orphanedUploadsChecked else { return }
                orphanedUploadsChecked = true
                Task {
                    let found = (try? await reviewEngine.findOrphanedMultipartUploads()) ?? []
                    await MainActor.run { orphanedUploads = found }
                }
            }

            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Verifica manuale in app**

Avvia l'app (`Cmd+R`), apri hamburger → Tools con **nessun job in corso**: la sotto-sezione "Upload incompleti" compare in fondo alla sezione Revisione (vuota se non ce ne sono, altrimenti con la lista). Avvia un job qualunque, riapri Tools mentre gira: deve mostrare "Controllo upload incompleti disponibile a job fermo" invece di fare la chiamata di rete.

- [ ] **Step 7: Eseguire l'intera suite**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -10`

Expected: PASS, 34 test.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Upload incompleti section to ToolsSheet, disabled while a job is running"
```

---

## Task 4: Aggiornare `Docs/CLAUDE.md`, `Docs/ROADMAP.md` e verifica finale

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

- [ ] **Step 1: Aggiornare la sottosezione S3Syncer in `Docs/CLAUDE.md`**

Nella sezione `### S3Syncer (upload S3 nativo, SSD→Cubbit)`, dopo la riga sul retry con backoff, aggiungi:

```markdown
- **Pulizia upload multipart orfani**: `listMultipartUploads`/`abortMultipartUpload` (quest'ultima condivisa col cancel già esistente durante un job). Scoperta automatica nel pannello Revisione (Tools) quando nessun job è in corso, cancellazione sempre dietro conferma esplicita per singolo upload — mai automatica.
```

- [ ] **Step 2: Aggiornare la tabella "Stato attuale" in `Docs/CLAUDE.md`**

Aggiorna la riga "Pannello Revisione (ToolsSheet)" aggiungendo "upload multipart orfani" alla descrizione.

- [ ] **Step 3: Marcare il punto 4 come fatto in `Docs/ROADMAP.md`**

Cambia:

```markdown
4. **Multipart upload interrotti restano orfani sul bucket.** `AbortMultipartUpload` viene chiamato solo su Interrompi esplicito. Se l'app va in crash o il Mac si spegne a metà upload multipart, le parti restano su Cubbit — spazio occupato e potenziale costo indefinito a seconda delle lifecycle rule del bucket.
   *Effort: medio · `ListMultipartUploads` + cleanup a inizio job, o verifica lifecycle rule lato Cubbit*
```

in:

```markdown
4. ✅ **Fatto (2026-08-02) — Multipart upload interrotti restavano orfani sul bucket.** Scoperta automatica + pulizia manuale nel pannello Revisione (Tools), disattivata mentre un job è in corso. Vedi `Docs/superpowers/specs/2026-08-02-multipart-cleanup-design.md`.
```

- [ ] **Step 4: Build + suite completa**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10 && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug test 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`, 34 test verdi.

- [ ] **Step 5: Commit**

```bash
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: orphaned multipart cleanup shipped"
```
