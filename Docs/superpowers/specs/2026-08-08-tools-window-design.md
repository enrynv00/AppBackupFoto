# Diagnostica come finestra indipendente

Data: 2026-08-08

## Problema

Il pannello Diagnostica (`ToolsSheet`) è presentato con `.sheet(isPresented: $showTools) { ToolsSheet(isJobRunning: isJobRunning) }` (in `HamburgerPanel`, `ContentView.swift`). Su macOS gli sheet SwiftUI sono per design agganciati alla title bar della finestra principale: non si possono mai spostare, e questo in particolare ha solo `.frame(minWidth: 560)` (nessun `minHeight`/`maxWidth`/`maxHeight`), quindi non è nemmeno ridimensionabile in pratica. L'utente lo trova scomodo, soprattutto perché il pannello ha diverse sezioni (cartelle configurate, credenziali S3, Revisione, campione integrità, upload orfani) che possono richiedere più spazio di quanto lo sheet fisso conceda.

## Decisione presa in brainstorming

Trasformare `ToolsSheet` in una vera finestra macOS indipendente (`Window` scene SwiftUI, non `WindowGroup`), non più uno sheet modale. Si sposta, si ridimensiona liberamente trascinando i bordi, ha titlebar nativa con i tre pulsanti standard. Conseguenza esplicitamente accettata: non è più modale — l'utente può interagire con la finestra principale mentre Diagnostica resta aperta.

Fuori scope: nessun'altra modifica ai pannelli esistenti (`SettingsSheet`, `AppearanceSheet`, `RestoreView`, `CompletionSheet` restano `.sheet()` come oggi — solo Diagnostica è stata segnalata come problema). Nessuna modifica al layout interno di `ToolsSheet` (stesse sezioni, stesso contenuto).

Target di deployment reale del progetto: macOS 15.6 (verificato in `project.pbxproj`, `MACOSX_DEPLOYMENT_TARGET`) — molto oltre il "13+" descritto in `Docs/CLAUDE.md`, quindi nessun vincolo di compatibilità: `Window` scene, `openWindow`/`dismissWindow` sono tutte API disponibili senza riserve.

## Design tecnico

### 1. Scene `Window` singleton

In `BackupFotoEnricoApp` (`ContentView.swift:10-15`):

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

`Window` (non `WindowGroup`) è per definizione a istanza singola: richiamare `openWindow(id: "tools")` mentre è già aperta la porta in primo piano invece di duplicarla — nessuna guardia manuale necessaria.

`.windowResizability(.contentSize)` permette alla finestra di essere ridimensionata liberamente in base ai vincoli di frame del contenuto (`minWidth`/`minHeight` impostati su `ToolsSheet`, vedi punto 4), senza un tetto massimo.

### 2. `BackupRunner` condiviso tra le due scene

`ContentView` oggi possiede `runner` come `@StateObject` proprio (`ContentView.swift:2318`). Le due `Scene` di SwiftUI (`WindowGroup` e `Window`) sono indipendenti e non condividono l'environment a meno di iniettarlo esplicitamente in entrambe — per questo `runner` sale a livello App (vedi punto 1) e viene passato via `.environmentObject` a entrambe le radici.

Modifica in `ContentView` (`ContentView.swift:2318`):

```swift
// prima
@StateObject private var runner = BackupRunner()
// dopo
@EnvironmentObject private var runner: BackupRunner
```

`RootView` (`ContentView.swift:17-29`) non ha bisogno di modifiche: propaga già l'environment ai figli (`ContentView`) automaticamente, essendo `.environmentObject` applicato a `RootView()` stesso in `BackupFotoEnricoApp`.

### 3. `ToolsSheet` legge lo stato del job dall'environment, non da un parametro statico

Oggi `ToolsSheet.isJobRunning: Bool` (`ContentView.swift:3017`) è un valore congelato al momento dell'apertura dello sheet. Con la finestra che resta aperta durante l'uso dell'app, deve riflettere lo stato reale in ogni istante.

```swift
// prima
struct ToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    ...
    var isJobRunning: Bool = false
// dopo
struct ToolsSheet: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var runner: BackupRunner
    ...
    // isJobRunning rimosso: si usa runner.isRunning ovunque serviva
```

I due punti d'uso interni (`ContentView.swift:3226` `if isJobRunning {`, `ContentView.swift:3273` `guard !isJobRunning, ...`) diventano `runner.isRunning`. Il pulsante "Chiudi" (`ContentView.swift:3283`, oggi `Button("Chiudi") { dismiss() }`) diventa `Button("Chiudi") { dismissWindow() }`.

### 4. Dimensioni della finestra

`ToolsSheet.body` (`ContentView.swift:3286`, oggi `.padding(28).frame(minWidth: 560)`) diventa:

```swift
.padding(28).frame(minWidth: 560, minHeight: 480)
```

Nessun `maxWidth`/`maxHeight`: la finestra cresce liberamente. La dimensione iniziale è governata dalla `Window` scene (`.defaultSize(width: 640, height: 640)`, punto 1), non dal frame del contenuto.

### 5. Apertura da `HamburgerPanel`

`HamburgerPanel` (`ContentView.swift:2600` e seguenti) perde il parametro `isJobRunning` (`ContentView.swift:2603`, oggi inoltrato solo a `ToolsSheet` — diventa morto). Il chiamante in `ContentView` (`ContentView.swift:2369`) smette di passarlo.

```swift
// prima (HamburgerPanel)
var isJobRunning: Bool = false
...
HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple) {
    showTools = true
}
...
.sheet(isPresented: $showTools) { ToolsSheet(isJobRunning: isJobRunning) }

// dopo
@Environment(\.openWindow) private var openWindow
...
HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple) {
    openWindow(id: "tools")
}
// niente più .sheet(isPresented: $showTools) — showTools (@State, riga 2611) rimosso
```

## Testing

Nessun nuovo test XCTest: è un cambio puramente di presentazione SwiftUI (scene/finestra), non introduce logica di business testabile in isolamento — coerente con l'assenza di test sulle view esistenti nel progetto (`SettingsSheet`, `AppearanceSheet`, ecc. non sono testate, solo la logica sottostante lo è).

**Verifica manuale richiesta dopo l'implementazione** (non eseguibile in ambiente headless): aprire Tools dall'hamburger, verificare che la finestra si sposti e si ridimensioni trascinando i bordi; aprirla una seconda volta e verificare che non se ne apra una copia ma venga portata in primo piano; avviare un backup mentre Diagnostica è aperta e verificare che i controlli legati a `isRunning` (disabilitazione pulizia upload orfani) reagiscano correttamente; chiudere con "Chiudi" e con il pulsante rosso nativo, riverificare che riaprendola lo stato interno (findings, upload orfani) si aggiorni di nuovo (`onAppear` già presente).

## Fuori scope

- Nessuna modifica a `SettingsSheet`, `AppearanceSheet`, `RestoreView`, `CompletionSheet` — restano `.sheet()`.
- Nessuna modifica al contenuto/layout interno di `ToolsSheet`.
- Nessun ScrollView aggiuntivo o restructuring del contenuto — il ridimensionamento libero della finestra è considerato la soluzione sufficiente al problema segnalato.
