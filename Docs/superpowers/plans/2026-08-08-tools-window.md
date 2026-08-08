# Diagnostica come finestra indipendente Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trasformare il pannello Diagnostica (`ToolsSheet`) da `.sheet()` modale a una `Window` scene SwiftUI indipendente, spostabile e ridimensionabile.

**Architecture:** `BackupRunner` sale da `@StateObject` privato di `ContentView` a `@StateObject` dell'app (`BackupFotoEnricoApp`), condiviso via `.environmentObject` sia con la `WindowGroup` esistente sia con la nuova `Window(id: "tools")`. `ToolsSheet` legge lo stato del job (`runner.isRunning`) dall'environment invece che da un parametro `Bool` statico, così resta aggiornato mentre la finestra rimane aperta. `HamburgerPanel` apre la nuova finestra con `openWindow(id: "tools")` invece di un binding `showTools`.

**Tech Stack:** Swift 5.x, SwiftUI (target reale macOS 15.6 — `Window`, `openWindow`, `dismissWindow`, `.windowResizability` tutti disponibili senza riserve).

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift` (convenzione esplicita del progetto).
- Zero delete, zero overwrite, read-only sulla sorgente — questa feature è puramente di presentazione SwiftUI, non tocca `FileSyncer`/`S3Syncer`/`RestoreEngine`.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit. Nessun nuovo test XCTest previsto (cambio di sola presentazione, nessuna nuova logica di business testabile in isolamento) — i 49 test esistenti devono continuare a passare invariati.
- Fuori scope: `SettingsSheet`, `AppearanceSheet`, `RestoreView`, `CompletionSheet` restano `.sheet()` — non toccarli. Nessuna modifica al layout interno delle sezioni di `ToolsSheet` (stesso contenuto, solo il contenitore cambia).
- Verifica manuale (non eseguibile in headless, la fa l'utente dopo): spostamento/ridimensionamento reale della finestra, comportamento singleton alla riapertura, aggiornamento live di `isRunning` durante un job, refresh dei findings alla riapertura.

---

### Task 1: Condividere `BackupRunner` tra le scene dell'app

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:10-15` (`BackupFotoEnricoApp`)
- Modify: `AppBackupFoto/ContentView.swift:2318` (`ContentView`, dichiarazione `runner`)

**Interfaces:**
- Consumes: `BackupRunner` (classe esistente, `@MainActor final class BackupRunner: ObservableObject`, invariata)
- Produces: `runner: BackupRunner` disponibile nell'environment di entrambe le scene dell'app — Task 2 e Task 3 lo useranno via `@EnvironmentObject private var runner: BackupRunner`

- [ ] **Step 1: Spostare la creazione di `runner` nell'App e condividerla con la `WindowGroup`**

In `AppBackupFoto/ContentView.swift`, trova (righe 10-15):

```swift
@main
struct BackupFotoEnricoApp: App {
    var body: some Scene {
        WindowGroup { RootView().frame(minWidth: 960, minHeight: 620) }
    }
}
```

Sostituisci con:

```swift
@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runner)
                .frame(minWidth: 960, minHeight: 620)
        }
    }
}
```

- [ ] **Step 2: `ContentView` legge `runner` dall'environment invece di crearlo**

Trova (riga 2318):

```swift
    @StateObject private var runner = BackupRunner()
```

Sostituisci con:

```swift
    @EnvironmentObject private var runner: BackupRunner
```

- [ ] **Step 3: Build per verificare che compili (nessun consumer ancora della finestra Tools)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Test per verificare che nulla si sia rotto**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 49 test passano (nessuno aggiunto/rimosso in questo task).

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Move BackupRunner ownership to App level

Needed so the upcoming Diagnostica window can share live job state
with ContentView via environmentObject, instead of ContentView owning
it as a private @StateObject.
EOF
)"
```

---

### Task 2: `ToolsSheet` legge lo stato del job dall'environment

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:3015-3017` (dichiarazioni in `ToolsSheet`)
- Modify: `AppBackupFoto/ContentView.swift:3226` (uso di `isJobRunning`)
- Modify: `AppBackupFoto/ContentView.swift:3273` (uso di `isJobRunning`)
- Modify: `AppBackupFoto/ContentView.swift:3283` (bottone "Chiudi")
- Modify: `AppBackupFoto/ContentView.swift:3286` (frame)

**Interfaces:**
- Consumes: `runner: BackupRunner` dall'environment (prodotto da Task 1); `BackupRunner.isRunning: Bool` (proprietà computata esistente, invariata)
- Produces: `ToolsSheet` senza il parametro init `isJobRunning` — Task 3 aggiorna il call site che oggi lo passa

- [ ] **Step 1: Sostituire `isJobRunning` con `@EnvironmentObject`, e `dismiss` con `dismissWindow`**

Trova (righe 3014-3017):

```swift
struct ToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    var isJobRunning: Bool = false
```

Sostituisci con:

```swift
struct ToolsSheet: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
```

- [ ] **Step 2: Aggiornare i due usi interni di `isJobRunning`**

Trova (riga 3226):

```swift
                    if isJobRunning {
```

Sostituisci con:

```swift
                    if runner.isRunning {
```

Trova (riga 3273):

```swift
                guard !isJobRunning, !orphanedUploadsChecked else { return }
```

Sostituisci con:

```swift
                guard !runner.isRunning, !orphanedUploadsChecked else { return }
```

- [ ] **Step 3: Bottone "Chiudi" usa `dismissWindow`**

Trova (riga 3283):

```swift
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
```

Sostituisci con:

```swift
                Button("Chiudi") { dismissWindow() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
```

- [ ] **Step 4: Aggiungere `minHeight` al frame**

Trova (riga 3286):

```swift
        .padding(28).frame(minWidth: 560)
```

Sostituisci con:

```swift
        .padding(28).frame(minWidth: 560, minHeight: 480)
```

- [ ] **Step 5: Build — atteso un errore di compilazione (nessun call site aggiornato ancora)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -30`

Expected: FAIL — `ContentView.swift:2686` (`ToolsSheet(isJobRunning: isJobRunning)`) non compila più perché `ToolsSheet` non ha più il parametro `isJobRunning`. Confermare che l'errore sia esattamente questo prima di procedere a Task 3 (che lo risolve).

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
ToolsSheet reads job state from environment, resizes to minHeight 480

Replaces the frozen isJobRunning Bool with a live @EnvironmentObject
read of BackupRunner.isRunning, and swaps dismiss() for dismissWindow()
ahead of ToolsSheet becoming a real Window instead of a sheet.

Known-broken build: HamburgerPanel's call site still passes the removed
isJobRunning parameter — fixed in the next commit (Task 3).
EOF
)"
```

Nota: questo commit lascia la build rossa di proposito (il piano lo segnala esplicitamente allo Step 5) — è l'ultimo passo del ciclo TDD-per-refactoring di questo task, il fix arriva nel task successivo che è già pronto a partire. Se preferisci non committare mai uno stato rosso, salta questo commit e accorpa Step 6 di Task 2 con Task 3 in un unico commit — in tal caso esegui comunque gli step nell'ordine scritto, limitandoti a posticipare `git commit`.

---

### Task 3: `Window` scene indipendente e apertura da `HamburgerPanel`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:10-19` (`BackupFotoEnricoApp`, aggiunta della `Window` scene — righe spostate di alcune unità dopo Task 1, verificare col contenuto mostrato qui sotto invece che coi numeri)
- Modify: `AppBackupFoto/ContentView.swift:2603` (`HamburgerPanel`, rimozione `isJobRunning`)
- Modify: `AppBackupFoto/ContentView.swift:2611` (`HamburgerPanel`, rimozione `showTools` state)
- Modify: `AppBackupFoto/ContentView.swift:2658` (azione bottone "Tools")
- Modify: `AppBackupFoto/ContentView.swift:2686` (rimozione riga `.sheet(isPresented: $showTools)`)
- Modify: `AppBackupFoto/ContentView.swift:2369` (call site `HamburgerPanel(...)`, rimozione argomento `isJobRunning`)

**Interfaces:**
- Consumes: `ToolsSheet` senza init param (prodotto da Task 2); `runner` dall'environment (prodotto da Task 1)
- Produces: finestra `Window(id: "tools")` apribile con `openWindow(id: "tools")` da qualunque punto dell'app con accesso a `\.openWindow` — nessun altro consumer previsto in questo piano

- [ ] **Step 1: Aggiungere la `Window` scene in `BackupFotoEnricoApp`**

Trova (contenuto risultante da Task 1, righe 10-19):

```swift
@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runner)
                .frame(minWidth: 960, minHeight: 620)
        }
    }
}
```

Sostituisci con:

```swift
@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runner)
                .frame(minWidth: 960, minHeight: 620)
        }
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 2: `HamburgerPanel` apre la finestra invece di uno sheet**

Trova (righe 2600-2612):

```swift
struct HamburgerPanel: View {
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    var isJobRunning: Bool = false
    var onShowLog: (() -> Void)? = nil
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let profileName = "Enrico Nanni Vicenzi"
    private let profileEmail = "enrynv@gmail.com"

    @ObservedObject private var appearance = AppearanceManager.shared
    @State private var showAppearance = false
    @State private var showTools = false
    @State private var showRestore = false
```

Sostituisci con:

```swift
struct HamburgerPanel: View {
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    var onShowLog: (() -> Void)? = nil
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let profileName = "Enrico Nanni Vicenzi"
    private let profileEmail = "enrynv@gmail.com"

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appearance = AppearanceManager.shared
    @State private var showAppearance = false
    @State private var showRestore = false
```

- [ ] **Step 3: Azione del bottone "Tools" apre la finestra**

Trova (righe 2657-2659):

```swift
                        HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple) {
                            showTools = true
                        }
```

Sostituisci con:

```swift
                        HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple) {
                            openWindow(id: "tools")
                        }
```

- [ ] **Step 4: Rimuovere il modifier `.sheet` per Tools**

Trova (righe 2685-2687):

```swift
        .sheet(isPresented: $showAppearance) { AppearanceSheet() }
        .sheet(isPresented: $showTools)      { ToolsSheet(isJobRunning: isJobRunning) }
        .sheet(isPresented: $showRestore)    { RestoreView() }
```

Sostituisci con:

```swift
        .sheet(isPresented: $showAppearance) { AppearanceSheet() }
        .sheet(isPresented: $showRestore)    { RestoreView() }
```

- [ ] **Step 5: Il call site di `ContentView` smette di passare `isJobRunning`**

Trova (riga 2369):

```swift
                HamburgerPanel(isVisible: $showHamburger, showSettings: $showSettings, isJobRunning: runner.isRunning, onShowLog: {
```

Sostituisci con:

```swift
                HamburgerPanel(isVisible: $showHamburger, showSettings: $showSettings, onShowLog: {
```

- [ ] **Step 6: Build — deve tornare verde**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Test — 49 test invariati**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 49 test passano.

- [ ] **Step 8: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Open Diagnostica as an independent, movable, resizable window

ToolsSheet is now a singleton Window scene (id "tools") opened via
openWindow instead of a modal .sheet() bound to the main window's
title bar. Reopening while already open brings it to front instead
of duplicating it (Window scene default behavior).
EOF
)"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** i 5 punti del design tecnico dello spec (`Window` singleton, `BackupRunner` condiviso, `ToolsSheet` legge da environment, dimensioni finestra, apertura da `HamburgerPanel`) sono coperti rispettivamente da Task 1 (punto 2), Task 1 (punto 2), Task 2 (punti 1/3), Task 2 (punto 4) + Task 3 (punto 1), Task 3 (punti 2-5). Nessun test nuovo previsto, coerente con lo spec.

**Scan placeholder:** nessuno — ogni step ha codice completo, comandi esatti e output atteso.

**Coerenza dei tipi:** `runner: BackupRunner` usato identicamente in Task 1/2/3; `ToolsSheet()` senza argomenti dopo Task 2, coerente con la chiamata `ToolsSheet().environmentObject(runner)` in Task 3; `openWindow(id: "tools")` in Task 3 coerente con `Window("Diagnostica", id: "tools")` dichiarato nello stesso task.
