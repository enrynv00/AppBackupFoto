# Icona menu bar (scorciatoia) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere un'icona nella menu bar di macOS come scorciatoia rapida (stato + apertura finestra), senza cambiare il comportamento dell'app come app normale (Dock icon, finestra visibile, backup automatico solo ad app aperta).

**Architecture:** Nuova scene `MenuBarExtra` in `BackupFotoEnricoApp`, accanto alla `WindowGroup` (che guadagna `id: "main"`) e alla `Window("Diagnostica", id: "tools")` già esistente. Due nuove view SwiftUI: `MenuBarIcon` (label dell'icona, reattiva a `runner.isRunning`) e `MenuBarContent` (corpo del menu a discesa: stato + bottone "Apri AppBackupFoto").

**Tech Stack:** Swift 5.x, SwiftUI (`MenuBarExtra` disponibile da macOS 13+, `.symbolEffect` da macOS 14+ — target reale macOS 15.6, nessun problema di compatibilità).

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift` (convenzione esplicita del progetto).
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Nessun nuovo test XCTest previsto (cambio di sola presentazione SwiftUI, nessuna nuova logica di business testabile in isolamento) — i test esistenti devono continuare a passare invariati.
- Fuori scope: `LSUIElement`/modalità background, azioni di avvio backup dal menu bar, bottone Esci nel menu — non implementarli.
- Verifica manuale (non eseguibile in headless, la fa l'utente dopo): icona compare in menu bar, testo di stato corretto nei tre casi (mai eseguito/in corso/con data ultimo backup), icona pulsa durante un job e si ferma a fine job, "Apri AppBackupFoto" porta la finestra in primo piano sia se già aperta sia se era stata chiusa.

---

### Task 1: `MenuBarExtra` con icona reattiva e menu di stato

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:9-27` (`BackupFotoEnricoApp` — `WindowGroup` guadagna `id: "main"`, aggiunta scene `MenuBarExtra`)
- Modify: `AppBackupFoto/ContentView.swift` (aggiunta delle due nuove struct `MenuBarIcon`/`MenuBarContent`, subito dopo `BackupFotoEnricoApp`, prima di `struct RootView`)

**Interfaces:**
- Consumes: `BackupRunner.isRunning: Bool` (proprietà computata esistente, invariata); `JobHistoryStore.load() -> JobSummary?` (funzione esistente, invariata, `JobSummary.date: Date`)
- Produces: `MenuBarIcon: View`, `MenuBarContent: View` — nessun altro consumer previsto in questo piano

- [ ] **Step 1: `WindowGroup` guadagna `id: "main"` e viene aggiunta la scene `MenuBarExtra`**

Trova (`ContentView.swift`, righe 9-27):

```swift
// MARK: - App entry
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

Sostituisci con:

```swift
// MARK: - App entry
@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()

    var body: some Scene {
        WindowGroup(id: "main") {
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

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(runner)
        } label: {
            MenuBarIcon()
                .environmentObject(runner)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var runner: BackupRunner
    @Environment(\.openWindow) private var openWindow
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private var statusText: String {
        if runner.isRunning { return "Backup in corso" }
        if let last = JobHistoryStore.load() {
            return "Ultimo backup: \(dateFormatter.string(from: last.date))"
        }
        return "Nessun backup ancora"
    }

    var body: some View {
        Text(statusText)
        Divider()
        Button("Apri AppBackupFoto") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
```

- [ ] **Step 2: Build per verificare che compili**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Eseguire l'intera suite di test per verificare che nulla si sia rotto**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: `TEST SUCCEEDED`, 54 test passano (invariati — nessun test nuovo in questo piano, vedi Global Constraints).

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add menu bar icon shortcut (status + open window)

MenuBarExtra alongside the existing WindowGroup/Diagnostica scenes —
the app stays a normal foreground app (Dock icon, visible window,
automatic backup only while open), this just adds a quick-access menu
bar icon. Icon pulses while a job is running; the dropdown shows a
one-line status and a button to bring the main window forward.
EOF
)"
```

---

### Task 2: Aggiornare la documentazione del progetto

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:**
- Consumes: nessuna (solo modifiche testuali)
- Produces: nessuna

- [ ] **Step 1: Aggiornare `Docs/CLAUDE.md`**

Nella sezione `## UI (SwiftUI views in ContentView.swift)`, dopo la riga che descrive `HamburgerPanel`, aggiungi:

```
- **MenuBarExtra (2026-08-09)** — icona nella menu bar (SF Symbol `photo.stack`, pulsa con `.symbolEffect(.pulse)` mentre un job è in corso) con menu a discesa: riga di stato (job in corso / data ultimo backup / nessun backup) + bottone "Apri AppBackupFoto" (`openWindow(id: "main")` + `NSApp.activate`). Solo scorciatoia — l'app resta un'app normale con Dock icon e finestra, nessun `LSUIElement`, nessuna estensione dello scheduling automatico ad app chiusa (deliberatamente fuori scope, vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`).
```

- [ ] **Step 2: Aggiornare `Docs/ROADMAP.md`**

Trova il punto 11 nella sezione `## Alto — prestazioni e qualità percepita (6)`:

```
11. **Nessuna modalità menu bar / avvio in background** — l'app deve restare aperta con finestra visibile.
    *Effort: alto · `NSStatusItem` + `LSUIElement`, ristruttura RootView*
```

Sostituisci con:

```
11. ✅ **Fatto in parte (2026-08-09) — Nessuna modalità menu bar.** Aggiunta icona menu bar come scorciatoia (stato + apertura finestra, `MenuBarExtra`) — scope ridotto rispetto alla stima originale dopo brainstorming con l'utente: l'obiettivo era solo un accesso rapido, non trasformare l'app in un'utility "menu bar only". `LSUIElement`/avvio in background/scheduling automatico ad app chiusa restano fuori scope, non richiesti. Vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`.
```

Nella sezione `## Da dove partire (aggiornato 2026-08-02)`, aggiungi `#11 icona menu bar (scorciatoia)` all'elenco dei punti "Fatti".

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: menu bar shortcut icon shipped"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** i punti del design tecnico dello spec (id `WindowGroup`, `MenuBarIcon`, `MenuBarContent`, testo di stato dai tre casi, apertura finestra) sono tutti coperti da Task 1, codice ripreso identico dallo spec. Le esclusioni esplicite dello spec (niente `LSUIElement`, niente azioni di avvio backup, niente bottone Esci) sono rispettate — nessun task le implementa.

**Scan placeholder:** nessuno — l'unico step di codice ha il contenuto completo, comandi e output attesi espliciti.

**Coerenza dei tipi:** `MenuBarIcon`/`MenuBarContent` usano `@EnvironmentObject private var runner: BackupRunner` coerentemente con il pattern già in uso in `ContentView`/`HamburgerPanel`/`ToolsSheet`/`RestoreView` (tutti letti dallo stesso `.environmentObject(runner)` impostato a livello App). `openWindow(id: "main")` coerente con il nuovo `WindowGroup(id: "main")` introdotto nello stesso task.
