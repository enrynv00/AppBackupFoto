# Backup automatico Mac→SSD al collegamento dell'SSD

Data: 2026-08-02
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto alto #7: "Zero automazione — ogni backup parte solo a bottone premuto. CCC, ChronoSync e Arq offrono tutti scheduling nativo." Ricerca preliminare in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md` (sezione 6, mai approfondita) confrontava `NSBackgroundActivityScheduler` (semplice, richiede l'app aperta) e un vero `LaunchAgent` via `SMAppService` (avvia l'app anche se chiusa, più invasivo). Approfondito con ricerca web in questa sessione: `SMAppService` (macOS 13+, già il target del progetto) è l'API moderna per LaunchAgent, ma introdurrebbe un helper esterno da installare/rimuovere e — dato che l'app non ha oggi una modalità menu bar/background (roadmap alto #11, non fatto) — un avvio automatico ad app chiusa aprirebbe comunque la finestra intera ogni volta, invasivo senza il prerequisito del punto #11.

## Decisioni (dall'utente, in fase di brainstorming)

1. **Solo se l'app è già aperta** — nessun LaunchAgent/SMAppService, nessun avvio automatico ad app chiusa. Rimandato a dopo un'eventuale modalità menu bar (#11), se mai richiesta.
2. **Trigger: quando l'SSD si collega** — non un orario fisso notturno.
3. **Solo il job Mac → SSD** parte automaticamente. SSD→HDD e SSD→S3 restano manuali (richiedono un secondo device o banda/tempo lunghi, l'utente preferisce deciderli lui quando vuole).

## Scope

Dentro scope:
- Trigger automatico di `BackupRunner.runMacToSSD()` quando `VolumeMonitor.ssdMounted` passa da `false` a `true`, con l'app aperta.
- Toggle on/off persistito (`@AppStorage`), default acceso, in `SettingsSheet`.
- Nessuna nuova validazione/gestione errori: riuso di `runMacToSSD()` e `run(label:work:)` esistenti così come sono (guardia bookmark, guardia `isRunning`, notifica di completamento).

Fuori scope (esplicitamente, per questa iterazione):
- LaunchAgent/`SMAppService`, avvio ad app chiusa — deciso esplicitamente fuori scope, dipende dal punto #11 (modalità menu bar) non ancora fatto.
- Scheduling a orario fisso (es. ogni notte) — deciso esplicitamente fuori scope, solo trigger su collegamento SSD.
- Automazione di SSD→HDD o SSD→S3 — deciso esplicitamente fuori scope, solo Mac→SSD.
- Debounce/cooldown aggiuntivo oltre a quello naturale di `.onChange` — non necessario, riesecuzioni ripetute sono cheap grazie a zero-overwrite.

## Architettura

Tutto in `AppBackupFoto/ContentView.swift`.

### Toggle persistito

```swift
@AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
```

Aggiunta sia in `ContentView` (per leggerla nel trigger) sia in `SettingsSheet` (per mostrarla/modificarla) — stessa chiave, sincronizzazione automatica via `@AppStorage`/`UserDefaults`, nessuno stato condiviso da progettare a mano.

### UI — `SettingsSheet`

Sopra la lista cartelle esistente (`ForEach(BookmarkManager.Location.allCases)`):

```swift
Toggle("Backup automatico Mac → SSD quando colleghi l'SSD", isOn: $autoBackupEnabled)
Text("Appena colleghi l'SSD, se l'app è aperta, parte da sola l'aggiornamento da Foto a SSD.")
    .font(.caption).foregroundStyle(.secondary)
```

### Trigger — `ContentView`

```swift
.onChange(of: volumes.ssdMounted) { _, mounted in
    if mounted && autoBackupEnabled && !runner.isRunning {
        runner.runMacToSSD()
    }
}
```

`VolumeMonitor` pubblica `ssdMounted` ogni 3s (polling già esistente, invariato), ma `.onChange(of:)` di SwiftUI invoca la closure solo quando il valore cambia effettivamente rispetto al precedente — quindi il trigger scatta una sola volta per transizione `false→true`, non ad ogni tick di polling, senza bisogno di tracciare manualmente lo stato precedente.

Nessuna modifica a `VolumeMonitor` o `BackupRunner`: entrambi restano disaccoppiati, `ContentView` è l'unico punto che li osserva entrambi e decide di collegarli, coerente con l'architettura attuale (stesso pattern già usato per `.onChange(of: runner.completionSnapshot?.phase)` poco più sotto nello stesso file).

## Gestione errori

Nessuna nuova gestione: `runMacToSSD()` già mostra un `NSAlert` se i bookmark Foto/SSD non sono validi, e `run(label:work:)` già ignora silenziosamente la chiamata se un job è già in corso (`guard !isRunning else { return }`). Il completamento genera la stessa notifica di sistema già esistente per ogni job (`Notifier`), automatico o manuale che sia.

## Testing

Nessun test automatico significativo: la logica del trigger è tre condizioni booleane su una riga (`mounted && autoBackupEnabled && !runner.isRunning`), già leggibile senza bisogno di essere estratta in una funzione pura testabile — estrarla solo per testarla sarebbe over-engineering per questo caso. Verifica manuale: scollegare/ricollegare l'SSD con il toggle acceso e controllare che il backup parta una volta sola per collegamento; disattivare il toggle e controllare che non parta più.

## Domande aperte per l'implementazione

Nessuna bloccante.
