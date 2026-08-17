# Spec — Touch ID all'avvio dell'app (roadmap #30)

## Problema

L'app oggi non ha nessuna forma di autenticazione: chiunque apra il Mac di Enrico può aprire AppBackupFoto e vedere/gestire il backup delle foto. Enrico vuole un gate di Touch ID all'apertura.

## Decisioni prese in brainstorming (2026-08-17, one-question-at-a-time)

- **Quando scatta**: solo all'avvio dell'app (apertura da zero, icona Dock/menu bar). Non ad ogni ritorno in primo piano, non solo su azioni sensibili — una volta sbloccata, l'app resta sbloccata finché non viene chiusa del tutto.
- **Fallback**: se Touch ID fallisce o non è disponibile (Mac senza sensore, utente annulla), fallback automatico alla password del Mac — comportamento nativo di sistema, non gestito a mano dall'app.
- **On/off**: toggle disattivabile in Impostazioni, default **attivo**. Disattivarlo non richiede a sua volta un'autenticazione (stesso livello di frizione degli altri toggle esistenti, es. backup automatico).

## Design tecnico

**API**: `LocalAuthentication` (`import LocalAuthentication`), `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason:reply:)`. La policy `.deviceOwnerAuthentication` (non `.deviceOwnerAuthenticationWithBiometrics`) è quella che offre il fallback a password del Mac automaticamente lato sistema — copre esattamente il requisito sopra senza codice aggiuntivo per gestire il fallback.

**Stato**: nuovo singleton `AuthGateManager` (`ObservableObject`, stesso stile di `AppearanceManager` — vedi `.claude/rules/architecture.md`), non un `@AppStorage` diretto in `RootView` perché lo stato "sbloccato" deve sopravvivere a re-render/riaperture della finestra principale nella stessa sessione app, non essere per-view:
- `@Published var unlocked: Bool = false`
- `@Published var isAuthenticating: Bool = false`
- `func authenticate()` — chiama `evaluatePolicy`, su successo `unlocked = true` sul main thread; su fallimento resta `false`, nessun retry automatico (l'utente rilancia dal bottone nella lock screen)
- Toggle letto/scritto da `UserDefaults` chiave `"touchIDEnabled"` (default `true` se assente — stesso pattern manuale di `AppearanceManager.mode`, non `@AppStorage` dato che la classe non è una `View`)

**UI**: `RootView` (unico punto d'ingresso, `WindowGroup(id: "main")`) guadagna un terzo stato oltre a `canEnterApp`/`SetupView`:
```
if AuthGateManager.shared.touchIDEnabled && !AuthGateManager.shared.unlocked {
    LockScreenView()   // nuova view: icona lucchetto/Touch ID, bottone "Sblocca", messaggio di errore se fallisce
} else if bm.canEnterApp {
    ContentView()
} else {
    SetupView()
}
```
`LockScreenView.onAppear` chiama `authenticate()` automaticamente (prompt immediato, l'utente non deve cliccare per il primo tentativo) — il bottone serve solo per ritentare dopo un fallimento/annullamento.

**Impostazioni**: nuovo `Toggle("Richiedi Touch ID all'avvio", isOn: ...)` in `SettingsSheet`, stesso stile del toggle "Backup automatico" già presente (riga sotto, stessa `VStack` con caption esplicativa).

## Fuori scope (deciso esplicitamente)

- **MenuBarExtra non gated**: l'icona/menu nella barra dei menu (stato job + bottone "Apri AppBackupFoto") resta accessibile senza sblocco — non mostra foto né credenziali, solo stato testuale del job. Cliccare "Apri" porta comunque alla `LockScreenView` se non sbloccata, quindi non è un modo per bypassare il gate, solo per raggiungerlo.
- **Window "Diagnostica"/"Catalogo" non hanno un gate proprio**: sono raggiungibili solo dal pannello hamburger dentro `ContentView`, che è già dietro il gate — nessun percorso per aprirle prima dello sblocco.
- Nessuna cifratura aggiuntiva dei dati: Touch ID protegge solo l'*accesso all'interfaccia*, non è un livello di cifratura dei file (coerente con la decisione già presa contro la cifratura lato client, roadmap #5 — stesso confine).

## Test

- Unit test non applicabili a `LAContext` reale (richiede hardware/interazione) — nessun test automatico per `authenticate()` stesso (come già per altre azioni AppKit imperative, es. badge Dock #15).
- Verifica manuale (a implementazione fatta): avvio app → prompt Touch ID compare subito; Annulla → lock screen con bottone Riprova; disattiva toggle in Impostazioni → riavvio senza prompt; riattiva → prompt torna.
