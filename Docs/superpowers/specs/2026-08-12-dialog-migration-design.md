# Fase 5 — Migrazione dialoghi (roadmap #25)

Data: 2026-08-12

## Problema

Roadmap #25 (quinto e ultimo capitolo del piano "Design polish", dopo Fase 1-4 — tutte chiuse e verificate). L'audit UI originale (Architect agent, 2026-08-12) aveva segnalato: "**14 NSAlert AppKit contro 2 `.alert` SwiftUI**: i dialoghi rompono il linguaggio visivo" — priorità Alto. `NSAlert` è UI AppKit "a finestra propria" (bordi/tipografia/animazione diversi dal resto dell'app, ormai in `NavigationSplitView` con Liquid Glass dopo Fase 2), mentre `.alert`/`.confirmationDialog` SwiftUI si integrano nativamente con la finestra che li presenta.

Durante l'esplorazione del codice in fase di brainstorming è emersa la vera complessità della migrazione: **14 chiamate dirette a `NSAlert()`**, ma **20+ punti di chiamata effettivi** (molte passano da un helper condiviso `alert(_:_:)` dentro `BackupRunner`). Più della metà delle chiamate vive dentro classi Swift semplici (`BookmarkManager`, `BackupRunner`) — non `View` SwiftUI — che non hanno un posto naturale dove agganciare `.alert()` (richiede uno stato osservato da una `View`). Non è un find-replace: serve introdurre stato pubblicato osservato dalla `View` giusta.

## Decisioni prese in brainstorming

- **Architettura**: stato centralizzato per classe proprietaria, non un `@Published` per singolo alert. `BackupRunner` e `BookmarkManager` guadagnano ciascuna un `@Published var pendingAlert: SimpleAlert?` (tipo condiviso, definito una volta). Le classi che sono già `View` (`ToolsSheet`, `ContentView`) usano `@State` locale invece di `@Published` — non serve pubblicare stato per l'esterno se il consumatore è la view stessa.
- **`ContentView.confirmQuit`**: resta un alert booleano dedicato (`@State private var showQuitConfirm: Bool`), non forzato nel tipo condiviso `SimpleAlert` — caso unico non riusato altrove, non vale la generalizzazione.
- **`BookmarkManager.pendingAlert` va osservato in due punti**, non uno: `RootView` (copre `SetupView`, dove `selectAndSave` viene chiamato durante l'onboarding) e `ToolsSheet` (copre la finestra "Diagnostica", una `Window` scene separata dove `selectAndSave` viene chiamato di nuovo da "Cartelle Configurate" → `LocationRow` → bottone "Cambia"). Sono due finestre macOS indipendenti — un solo `.alert()` in una sola view non intercetterebbe l'evento se scatena dall'altra finestra.
- **`BackupRunner.pendingAlert` va osservato in un solo punto**: `ContentView` — tutte le sue chiamate (`runMacToSSD`/`runSSDToHDD`/`runSyncS3` e le rispettive anteprime) partono da bottoni che esistono solo nella finestra principale.

## Design tecnico

### 1. Tipo condiviso `SimpleAlert`

```swift
struct SimpleAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String = ""
    var isDestructive: Bool = false
    var confirmTitle: String = "OK"
    var cancelTitle: String? = nil   // nil = alert informativo (solo un bottone), altrimenti conferma a 2 bottoni
    var onConfirm: (() -> Void)? = nil
}
```

Consumato ovunque con lo stesso pattern:
```swift
.alert(item: <binding a SimpleAlert?>) { a in
    Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
    if let cancelTitle = a.cancelTitle {
        Button(cancelTitle, role: .cancel) {}
    }
} message: { a in
    Text(a.message)
}
```

Un alert con `cancelTitle: nil` mostra un solo bottone (equivalente ai vecchi `NSAlert` senza `addButton` aggiuntivo, es. quello di `alert(_:_:)`); un alert con `cancelTitle` impostato mostra 2 bottoni (equivalente ai vecchi `NSAlert` con `addButton(withTitle:)` × 2, es. `confirmQuit`/`confirmReveal`).

### 2. `BackupRunner` — 6 punti migrati (helper condiviso + 5 dirette)

`private func alert(_ title: String, _ msg: String)` (oggi riga ~2063, chiamata da ~20 guardie di validazione in `runMacToSSD`/`runSSDToHDD`/`runSyncS3`/le loro anteprime) diventa:
```swift
private func alert(_ title: String, _ msg: String) {
    pendingAlert = SimpleAlert(title: title, message: msg)
}
```
(tutte le ~20 chiamate esistenti `self.alert("...", "...")`/`alert("...", "...")` restano invariate come sintassi — cambia solo l'implementazione dell'helper, zero call site da toccare).

Le 5 chiamate dirette a `NSAlert()` dentro `BackupRunner` (spazio insufficiente SSD/HDD, anteprima Mac→SSD/SSD→HDD/SSD→S3) diventano assegnazioni dirette a `pendingAlert` con lo stesso titolo/messaggio di oggi — quelle con solo "OK" (le 3 anteprime) usano `SimpleAlert(title:message:)` col default `cancelTitle: nil`; le 2 di spazio insufficiente sono anch'esse solo "OK" nel codice attuale (`a.addButton(withTitle: "OK")`, nessun secondo bottone), stesso trattamento.

`ContentView` guadagna:
```swift
.alert(item: $runner.pendingAlert) { a in
    Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
    if let cancelTitle = a.cancelTitle { Button(cancelTitle, role: .cancel) {} }
} message: { a in Text(a.message) }
```

### 3. `BookmarkManager` — 1 punto migrato, osservato in 2 finestre

L'unica chiamata diretta (dentro `selectAndSave`'s completion, su fallimento di `bookmarkData`) diventa `pendingAlert = SimpleAlert(title: "Impossibile salvare '\(loc.displayName)'", message: "...")`. Sia `RootView` sia `ToolsSheet` guadagnano lo stesso blocco `.alert(item: $bm.pendingAlert) { ... }` (stesso schema del punto 2, con `$bm` invece di `$runner`).

### 4. `ToolsSheet` — 5 punti migrati, `@State` locale

`ToolsSheet` guadagna `@State private var pendingAlert: SimpleAlert?` e `.alert(item: $pendingAlert) { ... }` sul proprio `body` (stesso schema generico). I 5 `NSAlert` esistenti diventano:
- `confirmReveal` ("Rivelare le credenziali S3?"): `pendingAlert = SimpleAlert(title: ..., message: ..., confirmTitle: "Continua", cancelTitle: "Annulla", onConfirm: action)`.
- Il flusso "Aggiorna da rclone.conf" (confirm "Sovrascrivere?" → su conferma esegue l'azione, poi mostra "Credenziali aggiornate" oppure un errore): il bottone imposta prima `pendingAlert` con `onConfirm` che esegue l'azione (`try config...; try writeToKeychain...`) e poi, dentro la stessa closure `onConfirm`, reimposta `pendingAlert` a un secondo `SimpleAlert` (successo, `cancelTitle: nil`) o a un terzo (errore dal `catch`, `cancelTitle: nil`) — 3 `NSAlert` di oggi diventano una sequenza di 2-3 assegnazioni a `pendingAlert` nello stesso flusso di codice.
- Il flusso "Elimina" upload orfano (confirm "Eliminare?" → su conferma, `Task` async che su errore mostra un secondo alert): stesso pattern, `onConfirm` avvia il `Task`, il blocco `catch` dentro il `Task` reimposta `pendingAlert` con l'errore invece di costruire un nuovo `NSAlert`.

### 5. `ContentView.confirmQuit` — alert dedicato

```swift
@State private var showQuitConfirm = false
private func confirmQuit() { showQuitConfirm = true }
```
e nel `body`:
```swift
.alert("Chiudere l'app?", isPresented: $showQuitConfirm) {
    Button("Esci", role: .destructive) {
        if runner.isRunning { runner.stop() }
        NSApp.terminate(nil)
    }
    Button("Annulla", role: .cancel) {}
} message: {
    Text("I processi in corso verranno interrotti.")
}
```

## Testing

Nessuna nuova logica di business — solo presentazione UI. Nessun nuovo XCTest sensato (stesso ragionamento delle fasi precedenti — nessuna delle funzioni toccate ha logica pura isolabile diversa da prima, cambia solo *come* l'errore/conferma arriva a schermo). Suite esistente (79 test) va rieseguita dopo ogni task. **Verifica manuale richiesta** (non automatizzabile in ambiente headless, richiede interazione utente reale): innescare almeno un caso per categoria — un alert informativo (es. un'anteprima Mac→SSD), una conferma a 2 bottoni (es. "Chiudere l'app?"), il flusso sequenziale conferma→risultato di "Aggiorna da rclone.conf" in Tools, e il caso `BookmarkManager` da entrambe le finestre (SetupView e Diagnostica) se possibile — per confermare che ogni alert compaia nella finestra giusta con testo/bottoni corretti, e che nessuna azione (es. lo stop del job su "Esci") sia stata persa nella conversione.

## Fuori scope

- Nessun cambio ai design token/componenti/micro-interazioni delle fasi precedenti.
- Nessuna migrazione dei 2 `.alert` SwiftUI già esistenti (già nel formato corretto).
- Nessun `.confirmationDialog` (menu a comparsa con più opzioni) — nessuno dei 14 `NSAlert` attuali ha più di 2 bottoni, `.alert` è sufficiente ovunque, `.confirmationDialog` non serve.
- Nessun cambio al testo/wording dei messaggi esistenti — stesso titolo/messaggio di oggi in ogni alert migrato, solo il meccanismo di presentazione cambia.
