# Icona menu bar (scorciatoia)

Data: 2026-08-09

## Problema

Roadmap #11: "Nessuna modalità menu bar / avvio in background — l'app deve restare aperta con finestra visibile. Effort: alto · NSStatusItem + LSUIElement, ristruttura RootView".

## Decisione presa in brainstorming: scope ridotto rispetto alla stima originale

La voce di roadmap confondeva due obiettivi diversi. Chiarito con l'utente: l'obiettivo reale è **solo un'icona nella menu bar come scorciatoia** (stato + apertura rapida della finestra), non la trasformazione dell'app in un'utility "menu bar only" con backup automatici ad app chiusa. Questo secondo obiettivo (`LSUIElement`, nessuna icona nel Dock, lifecycle in background) resta fuori scope — non richiesto, effort molto più alto, tocca lo scheduling già deciso il 2026-08-02 (Mac→SSD automatico solo ad app aperta). Se in futuro servisse, va ridiscusso separatamente.

Con lo scope ridotto, l'effort è medio, non alto: nessuna ristrutturazione di `RootView`, nessun `NSStatusItem`/AppDelegate manuale — `MenuBarExtra` (SwiftUI, disponibile da macOS 13+, nessun problema di compatibilità sul deployment target reale 15.6) copre tutto.

## Decisioni di design

- **Contenuto del menu**: solo una riga di stato non interattiva + un bottone "Apri AppBackupFoto". Niente azioni di avvio backup dal menu bar (duplicherebbero `SidebarView`), niente bottone Esci (Cmd+Q e Dock restano il modo per chiudere, invariato).
- **Icona**: SF Symbol `photo.stack` a riposo; quando `BackupRunner.isRunning == true`, applica `.symbolEffect(.pulse)` per un'animazione nativa senza bisogno di asset icona multipli.
- **Riga di stato**: "Backup in corso" se un job è attivo; altrimenti l'orario dell'ultimo backup da `JobHistoryStore.load()` (già esistente, usato da `ToolsSheet`), o "Nessun backup ancora" se non c'è storico.

## Design tecnico

### 1. `WindowGroup` guadagna un id esplicito

In `BackupFotoEnricoApp` (`ContentView.swift:10-27`):

```swift
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
```

Nessun altro punto del codice referenzia l'id della `WindowGroup` (verificato: solo `openWindow(id: "tools")` esiste oggi) — aggiungere `id: "main"` non ha effetti collaterali.

### 2. `MenuBarIcon` (label dell'icona, reattiva allo stato)

```swift
private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
    }
}
```

### 3. `MenuBarContent` (corpo del menu)

```swift
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

`NSApp.activate(ignoringOtherApps: true)` garantisce che la finestra vada davvero in primo piano anche se un'altra app aveva il focus (comportamento standard per bottoni "apri finestra" da menu bar/Dock su macOS) — `openWindow` da solo crea/riattiva la finestra ma non forza il cambio di app attiva.

## Testing

Nessun nuovo test XCTest: è un cambio puramente di presentazione SwiftUI (icona + menu), stesso ragionamento già applicato per la finestra Diagnostica (`Docs/superpowers/specs/2026-08-08-tools-window-design.md`) — nessuna logica di business nuova da testare in isolamento. `JobHistoryStore.load()` è già testato (`JobHistoryStoreTests.swift`).

**Verifica manuale richiesta dopo l'implementazione**: icona compare nella menu bar all'avvio; il testo di stato è corretto nei tre casi (mai eseguito un backup, backup in corso, ultimo backup con data); l'icona pulsa visibilmente durante un job attivo e si ferma a job concluso; "Apri AppBackupFoto" porta in primo piano la finestra sia se è già aperta (dietro ad altre finestre) sia se era stata chiusa.

## Fuori scope

- `LSUIElement` / modalità "menu bar only" — l'app resta un'app normale con Dock icon e finestra, questo era il punto chiarito in brainstorming.
- Nessuna estensione dello scheduling automatico ad app chiusa.
- Nessuna azione di avvio backup dal menu del menu bar.
- Nessun bottone Esci nel menu.
