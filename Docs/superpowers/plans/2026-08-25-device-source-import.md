# Importazione da sorgenti generiche (roadmap #27, sotto-progetto A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere un wizard "Importa foto" che copia file da una qualsiasi cartella/volume sorgente (fotocamera, drone, vecchio SSD, telefono montato come storage, cartella scaricata da un servizio cloud) in una sottocartella dedicata dell'SSD, riusando la logica di sync già collaudata.

**Architecture:** Nuovo `struct ImportView: View` (sheet, stesso pattern di `RestoreView`) guida l'utente in 3 passi visivi (scegli sorgente → anteprima → etichetta) e delega la copia a un nuovo metodo `BackupRunner.runImport(source:label:)` che segue esattamente lo schema già usato da `runMacToSSD()`/`runSSDToHDD()`: `FileSyncer.previewSync` per l'anteprima, `hasSufficientSpace` per il controllo spazio, `run(label:)` per l'esecuzione con progresso pubblicato su `phase`/`stats` (già mostrati dal pannello principale esistente — nessuna nuova UI di progresso da costruire). Due funzioni pure nuove (`isSourceInsideConfiguredLocations`, `importFolderSlug`) coprono la guardia anti-self-import e la generazione del nome cartella.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest — tutto in `AppBackupFoto/ContentView.swift` (convenzione esplicita del progetto: file unico), nessuna nuova dipendenza.

## Global Constraints

- Zero delete, zero overwrite, read-only sulla sorgente — vale anche qui: la sorgente scelta dall'utente non viene mai scritta né modificata.
- Tutto il codice applicativo va in `AppBackupFoto/ContentView.swift` — convenzione di progetto mai messa in discussione, non creare nuovi file `.swift` per il target app.
- Build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test`) devono restare verdi dopo ogni task.
- Il target `AppBackupFotoTests` **non** è file-system-synchronized: ogni nuovo file di test va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` (4 punti: `PBXBuildFile`, `PBXFileReference`, il gruppo `AppBackupFotoTests`, la `PBXSourcesBuildPhase`) — altrimenti compila ma non viene eseguito, e i test "passano" solo perché non girano affatto.
- Nessun nuovo bookmark persistito per la sorgente di import — resta un'operazione ad-hoc, coerente con la decisione "perlopiù una tantum" della spec.
- Ogni sessione di import atterra in una sottocartella dedicata sotto `<SSD>/Import/<etichetta>/`, mai nella struttura esistente.
- Riferimento spec: `Docs/superpowers/specs/2026-08-25-device-source-import-design.md`.

---

### Task 1: Funzioni pure — guardia self-import e slug etichetta

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1367` (subito dopo `isLikelyVolumeRoot`, prima di `enum FileKind`)
- Create: `AppBackupFotoTests/ImportSourceGuardTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (registrazione del nuovo file di test)

**Interfaces:**
- Produce: `func isSourceInsideConfiguredLocations(_ source: URL, configuredURLs: [URL]) -> Bool`
- Produce: `func importFolderSlug(_ label: String) -> String`
- Consumate da: Task 2 (`BackupRunner.runImport`) e Task 3 (`ImportView.pickSource`)

- [ ] **Step 1: Scrivi il file di test (fallirà: le funzioni non esistono ancora)**

Crea `AppBackupFotoTests/ImportSourceGuardTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class ImportSourceGuardTests: XCTestCase {
    private let configured = [
        URL(fileURLWithPath: "/Users/enrico/Pictures/Photos Library.photoslibrary"),
        URL(fileURLWithPath: "/Volumes/SSD - Enri"),
        URL(fileURLWithPath: "/Volumes/BackupHDD"),
    ]

    func testExactMatch_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri"), configuredURLs: configured))
    }

    func testSubfolderOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri/Foto iPhone"), configuredURLs: configured))
    }

    func testParentOfConfigured_isInside() {
        XCTAssertTrue(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes"), configuredURLs: configured))
    }

    func testUnrelatedPath_isNotInside() {
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), configuredURLs: configured))
    }

    func testSimilarPrefixDifferentVolume_isNotInside() {
        // "/Volumes/SSD - Enri 2" NON è dentro "/Volumes/SSD - Enri" anche se il path
        // condivide lo stesso prefisso testuale senza separatore "/" di mezzo.
        XCTAssertFalse(isSourceInsideConfiguredLocations(
            URL(fileURLWithPath: "/Volumes/SSD - Enri 2"), configuredURLs: configured))
    }

    func testSlug_normalLabel_unchanged() {
        XCTAssertEqual(importFolderSlug("EOS_DIGITAL - 2026-08-25"), "EOS_DIGITAL - 2026-08-25")
    }

    func testSlug_replacesSlash() {
        XCTAssertEqual(importFolderSlug("Foto/Vacanze"), "Foto-Vacanze")
    }

    func testSlug_replacesColon() {
        XCTAssertEqual(importFolderSlug("Nikon: vecchie foto"), "Nikon- vecchie foto")
    }

    func testSlug_emptyAfterTrim_fallsBackToImport() {
        XCTAssertEqual(importFolderSlug("   "), "Import")
    }
}
```

- [ ] **Step 2: Registra il nuovo file di test in `project.pbxproj`**

Genera due ID univoci a 24 caratteri esadecimali (maiuscoli), stesso formato degli ID già presenti nel file:

```bash
FILEREF_ID=$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]' | cut -c1-24)
BUILDFILE_ID=$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]' | cut -c1-24)
echo "FILEREF_ID=$FILEREF_ID"
echo "BUILDFILE_ID=$BUILDFILE_ID"
```

Con i due valori stampati, aggiungi 4 righe in `AppBackupFoto.xcodeproj/project.pbxproj` (usa `grep -n "IsLikelyVolumeRootTests" AppBackupFoto.xcodeproj/project.pbxproj` per trovare le 4 righe gemelle da cui copiare il formato esatto):

1. Nella sezione `PBXBuildFile`, subito dopo la riga di `IsLikelyVolumeRootTests.swift in Sources`:
   ```
   		<BUILDFILE_ID> /* ImportSourceGuardTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEREF_ID> /* ImportSourceGuardTests.swift */; };
   ```
2. Nella sezione `PBXFileReference`, subito dopo la riga di `IsLikelyVolumeRootTests.swift`:
   ```
   		<FILEREF_ID> /* ImportSourceGuardTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = ImportSourceGuardTests.swift; sourceTree = "<group>"; };
   ```
3. Nel gruppo `11123F514533138A989F11C4 /* AppBackupFotoTests */`, dentro `children = ( ... )`, aggiungi una riga:
   ```
   				<FILEREF_ID> /* ImportSourceGuardTests.swift */,
   ```
4. Nella `PBXSourcesBuildPhase` `62FE197CBAC2C2E908580583 /* Sources */`, dentro `files = ( ... )`, aggiungi una riga:
   ```
   				<BUILDFILE_ID> /* ImportSourceGuardTests.swift in Sources */,
   ```

Sostituisci `<BUILDFILE_ID>`/`<FILEREF_ID>` con i valori generati sopra in tutte e 4 le righe.

- [ ] **Step 3: Verifica che il progetto compili e che il nuovo file venga davvero eseguito (deve fallire: le funzioni non esistono)**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/ImportSourceGuardTests 2>&1 | tail -30`
Expected: FAIL — errore di compilazione "cannot find 'isSourceInsideConfiguredLocations' in scope" (conferma che il file è stato trovato e compilato dal target, non semplicemente ignorato).

- [ ] **Step 4: Implementa le due funzioni**

In `AppBackupFoto/ContentView.swift`, subito dopo `isLikelyVolumeRoot` (riga 1367) e prima di `enum FileKind`:

```swift
/// True se `source` coincide con, è contenuto in, o contiene uno dei path già
/// configurati (Libreria Foto/SSD/HDD) — usata dal wizard di import per evitare
/// un self-import senza senso della libreria dentro se stessa.
func isSourceInsideConfiguredLocations(_ source: URL, configuredURLs: [URL]) -> Bool {
    let sourcePath = source.standardizedFileURL.path
    for configured in configuredURLs {
        let configuredPath = configured.standardizedFileURL.path
        if sourcePath == configuredPath
            || sourcePath.hasPrefix(configuredPath + "/")
            || configuredPath.hasPrefix(sourcePath + "/") {
            return true
        }
    }
    return false
}

/// Converte un'etichetta libera in un nome di cartella sicuro per il filesystem
/// (sostituisce "/" e ":" — gli unici caratteri realmente problematici in un path
/// macOS — con "-"), con un fallback se il risultato è vuoto dopo il trim.
func importFolderSlug(_ label: String) -> String {
    let cleaned = label
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Import" : cleaned
}
```

- [ ] **Step 5: Esegui i test e verifica che passino tutti**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/ImportSourceGuardTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 9 test passati (`testExactMatch_isInside`, `testSubfolderOfConfigured_isInside`, `testParentOfConfigured_isInside`, `testUnrelatedPath_isNotInside`, `testSimilarPrefixDifferentVolume_isNotInside`, `testSlug_normalLabel_unchanged`, `testSlug_replacesSlash`, `testSlug_replacesColon`, `testSlug_emptyAfterTrim_fallsBackToImport`).

- [ ] **Step 6: Build e suite completa, poi commit**

Run:
```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **` con 148 test totali (139 esistenti + 9 nuovi).

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ImportSourceGuardTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add isSourceInsideConfiguredLocations/importFolderSlug pure helpers (roadmap #27)"
```

---

### Task 2: `BackupRunner.runImport(source:label:)`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:3483` (subito dopo la chiusura di `runSyncS3()`, prima di `func previewMacToSSD()`)

**Interfaces:**
- Consuma: `isSourceInsideConfiguredLocations`/`importFolderSlug` (Task 1, non usate qui — la guardia self-import vive nella View, Task 3), `BookmarkManager.startAccessing(_:)`/`stopAccessing(_:)`, `isLikelyVolumeRoot(_:)`, `BackupRunner.hasSufficientSpace(bytesNeeded:atVolumeOf:)`, `BackupRunner.run(label:work:)`, `FileSyncer.previewSync`/`sync`, `publishStatus`/`publishProgress`/`publishCurrentFile` — tutte funzioni/metodi già esistenti, nessuna firma nuova da questo task.
- Produce: `func runImport(source: URL, label: String)` — consumata da Task 3 (`ImportView.startImport`).

Nota: questo task non ha un proprio ciclo TDD con test dedicati — coerente con `runMacToSSD()`/`runSSDToHDD()`/`runSyncS3()`, che nel codice esistente non hanno XCTest diretti (sono orchestrazione con side-effect di I/O reale, verificati manualmente e tramite i test sulle funzioni pure che chiamano). Il passo di verifica è build + suite esistente verde, più smoke test manuale in Task 5.

- [ ] **Step 1: Aggiungi il metodo**

In `AppBackupFoto/ContentView.swift`, subito dopo la chiusura di `runSyncS3()` (dopo la riga con `alert("Errore configurazione S3", error.localizedDescription)` seguita da due `}`), prima di `func previewMacToSSD()`:

```swift
func runImport(source: URL, label: String) {
    speedUnit = "file/s"
    guard let ssdURL = bm.startAccessing(.ssd) else {
        alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
        return
    }
    if !isLikelyVolumeRoot(ssdURL) {
        bm.stopAccessing(.ssd)
        alert("Bookmark SSD non valido",
              "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
        return
    }
    let dst = ssdURL.appendingPathComponent("Import").appendingPathComponent(importFolderSlug(label))
    Task { @MainActor [weak self] in
        guard let self else { return }
        let preview = await self.syncer.previewSync(from: source, to: dst, deep: false)
        let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: ssdURL)
        guard space.ok else {
            self.bm.stopAccessing(.ssd)
            pendingAlert = SimpleAlert(
                title: "Spazio insufficiente sull'SSD",
                message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                    + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path).")
            return
        }
        self.run(label: "Importa: \(label)") { [weak self] in
            self?.publishStatus("Importa: \(source.path)  →  SSD: \(dst.path)")
            defer { self?.bm.stopAccessing(.ssd) }
            return try await self?.syncer.sync(from: source, to: dst, deep: false,
                onStatus: { self?.publishStatus($0) },
                onProgress: { self?.publishProgress($0) },
                onCurrentFile: { self?.publishCurrentFile($0) })
        }
    }
}
```

- [ ] **Step 2: Build e verifica che la suite esistente resti verde (nessuna regressione)**

Run:
```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, 148 test (invariati rispetto a Task 1 — questo task non aggiunge test).

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add BackupRunner.runImport(source:label:) (roadmap #27)"
```

---

### Task 3: `ImportView` — wizard a 3 passi

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:4530` (subito dopo la chiusura di `RestoreView`, prima di `// MARK: - SetupView`)

**Interfaces:**
- Consuma: `isSourceInsideConfiguredLocations`/`importFolderSlug` (Task 1), `BackupRunner.runImport(source:label:)` (Task 2), `BookmarkManager.shared.urls: [Location: URL]` (esistente), `FileSyncer.previewSync`/`FileSyncer.SyncResult.hms` (esistenti), `AppSpacing`/`AppFont`/`AppIconSize`/`AppColor` (token esistenti).
- Produce: `struct ImportView: View` (init senza argomenti) — consumata da Task 4 (`.sheet(isPresented:) { ImportView() }`).

- [ ] **Step 1: Aggiungi `ImportView`**

In `AppBackupFoto/ContentView.swift`, subito dopo la riga `}` che chiude `RestoreView` (riga 4530) e prima di `// MARK: - SetupView`:

```swift
// MARK: - ImportView
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    private let previewSyncer = FileSyncer()

    enum Step { case chooseSource, preview, label }

    @State private var step: Step = .chooseSource
    @State private var sourceURL: URL?
    @State private var guardErrorMessage: String?
    @State private var isLoadingPreview = false
    @State private var previewResult: (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int)?
    @State private var label: String = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            switch step {
            case .chooseSource: chooseSourceStep
            case .preview: previewStep
            case .label: labelStep
            }
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 360)
    }

    private var chooseSourceStep: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
                Text("Importa foto da un dispositivo o una cartella").font(AppFont.title)
                Text("Scegli una fotocamera, un drone, un vecchio disco o qualsiasi cartella con foto da importare.")
                    .font(AppFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let guardErrorMessage {
                Text(guardErrorMessage).font(AppFont.caption).foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
            }
            Button("Scegli cartella o dispositivo…") { pickSource() }
                .buttonStyle(.borderedProminent)
            Spacer()
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private var previewStep: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Anteprima").font(AppFont.title)
            if isLoadingPreview {
                ProgressView("Conteggio file in corso…")
            } else if let previewResult {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("File da importare: \(previewResult.toAdd)")
                    Text("Spazio necessario: \(ByteCountFormatter.string(fromByteCount: previewResult.toAddBytes, countStyle: .file))")
                    if previewResult.estimatedSec > 0 {
                        Text("Tempo stimato: \(FileSyncer.SyncResult.hms(previewResult.estimatedSec))")
                    }
                }
                .font(AppFont.body)
            }
            if bm.urls[.ssd] == nil {
                Text("SSD non configurato — vai in Impostazioni per configurarlo prima di importare.")
                    .font(AppFont.caption).foregroundStyle(AppColor.error)
            }
            Spacer()
            HStack {
                Button("Indietro") { step = .chooseSource }.buttonStyle(.bordered)
                Spacer()
                Button("Continua") { step = .label }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoadingPreview || bm.urls[.ssd] == nil)
            }
        }
    }

    private var labelStep: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Nome della cartella di destinazione").font(AppFont.title)
            Text("Le foto verranno copiate in una cartella dedicata sull'SSD, dentro \"Import\".")
                .font(AppFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Etichetta", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Spacer()
            HStack {
                Button("Indietro") { step = .preview }.buttonStyle(.bordered)
                Spacer()
                Button("Avvia importazione") { startImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func pickSource() {
        guardErrorMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Scegli la cartella o il volume da cui importare le foto"
        panel.prompt = "Seleziona"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isSourceInsideConfiguredLocations(url, configuredURLs: Array(bm.urls.values)) {
            guardErrorMessage = "'\(url.lastPathComponent)' fa parte di una cartella già configurata (Libreria Foto, SSD o HDD) — scegli una sorgente diversa."
            return
        }
        sourceURL = url
        label = "\(url.lastPathComponent) - \(Self.dateFormatter.string(from: Date()))"
        previewResult = nil
        step = .preview
        guard let ssdURL = bm.urls[.ssd] else { return }
        isLoadingPreview = true
        // La cartella di destinazione è sempre nuova/vuota (Import/<slug> non esiste ancora),
        // quindi toSkip sarà sempre 0 qui indipendentemente dallo slug esatto usato: il numero
        // non cambia se l'utente modifica l'etichetta al passo successivo.
        let dst = ssdURL.appendingPathComponent("Import").appendingPathComponent(importFolderSlug(label))
        Task { @MainActor in
            let result = await previewSyncer.previewSync(from: url, to: dst, deep: false)
            isLoadingPreview = false
            previewResult = result
        }
    }

    private func startImport() {
        guard let sourceURL else { return }
        runner.runImport(source: sourceURL, label: label)
        dismiss()
    }
}
```

- [ ] **Step 2: Build (nessun test unitario per una View SwiftUI — coerente con `RestoreView`, che non ne ha)**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add ImportView wizard (roadmap #27)"
```

---

### Task 4: Voce nel menu hamburger + sheet

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:5148` (nuovo `@State` in `HamburgerPanel`)
- Modify: `AppBackupFoto/ContentView.swift:5189-5191` (nuova `HamburgerRow`, subito dopo "Ripristina")
- Modify: `AppBackupFoto/ContentView.swift:5258` (nuovo `.sheet`)

**Interfaces:**
- Consuma: `ImportView` (Task 3), `HamburgerRow` (esistente, invariata).

- [ ] **Step 1: Aggiungi lo stato**

In `AppBackupFoto/ContentView.swift`, dentro `struct HamburgerPanel`, subito dopo `@State private var showRestore = false` (riga 5148):

```swift
    @State private var showImport = false
```

- [ ] **Step 2: Aggiungi la voce di menu**

Subito dopo il blocco:
```swift
                        HamburgerRow(icon: "arrow.down.doc.fill", label: "Ripristina", iconColor: .green) {
                            showRestore = true
                        }
```
aggiungi:
```swift
                        HamburgerRow(icon: "square.and.arrow.down.on.square", label: "Importa foto", iconColor: .mint) {
                            showImport = true
                        }
```

- [ ] **Step 3: Aggiungi il sheet**

Subito dopo `.sheet(isPresented: $showRestore)    { RestoreView() }` (riga 5258):

```swift
        .sheet(isPresented: $showImport)     { ImportView() }
```

- [ ] **Step 4: Build e verifica manuale della voce di menu**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

Apri l'app (`open` sul prodotto buildato, o `Cmd+R` da Xcode), apri il menu hamburger, verifica che "Importa foto" compaia tra "Ripristina" e "Configurazione" con icona menta, e che cliccandola si apra il wizard sul passo "Scegli cartella o dispositivo…".

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Wire 'Importa foto' entry into hamburger menu (roadmap #27)"
```

---

### Task 5: Verifica end-to-end reale + aggiornamento documentazione

**Files:**
- Modify: `Docs/ROADMAP.md` (stato #27)
- Modify: `Docs/CLAUDE.md` (se la tabella "Stato attuale" o "Obiettivi futuri" menziona #27)

- [ ] **Step 1: Suite completa verde prima di chiudere**

Run:
```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, 148 test totali.

- [ ] **Step 2: Verifica manuale end-to-end reale (a carico di Enrico, non automatizzabile)**

Con l'app in esecuzione e l'SSD collegato: collega una chiavetta USB o un vecchio disco con qualche foto, apri "Importa foto" dal menu hamburger, scegli quella cartella come sorgente, verifica l'anteprima (numero file/spazio coerente con quanto visto in Finder), dai un'etichetta, avvia. Verifica poi su Finder che `<SSD>/Import/<etichetta>/` contenga i file copiati, che il pannello principale mostri il progresso come per gli altri job, e che il completamento generi la notifica di sistema standard. Verifica anche la guardia: prova a scegliere come sorgente la cartella SSD stessa (o una sua sottocartella) e conferma che il wizard blocchi con il messaggio di errore invece di procedere.

- [ ] **Step 3: Aggiorna `Docs/ROADMAP.md`**

Aggiorna il punto 27 con lo stato: sotto-progetto A (sorgenti locali generiche) implementato e verificato manualmente (data odierna), riferimento a `Docs/superpowers/specs/2026-08-25-device-source-import-design.md` e a questo piano; sotto-progetto B (import cloud Google Foto/iCloud) resta aperto, non affrontato. **Controllo incrociato esplicito**: dopo la modifica, rileggi l'intero file `Docs/ROADMAP.md` (non solo la riga del punto 27) cercando altre righe riassuntive che menzionano lo stato di #27 (es. sezioni di riepilogo a fine capitolo, come già successo per #14/#15/#16) e correggile — non fermarti alla prima occorrenza trovata con un grep.

- [ ] **Step 4: Aggiorna `Docs/CLAUDE.md` se necessario**

Se la sezione "Obiettivi futuri" o la tabella "Stato attuale" menziona #27 o "configuratore generico di dispositivi", aggiornala per riflettere lo stato descritto sopra. Se non lo menziona esplicitamente, non serve alcuna modifica lì.

- [ ] **Step 5: Commit della documentazione**

```bash
git add Docs/ROADMAP.md Docs/CLAUDE.md
git commit -m "docs: mark roadmap #27 sub-project A (local source import) as done"
```
