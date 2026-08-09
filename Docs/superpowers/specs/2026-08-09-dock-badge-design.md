# Roadmap #15: Badge percentuale sul Dock

Data: 2026-08-09

## Problema

`Docs/ROADMAP.md` punto #15: "Nessun indicatore di progresso in dock/menu bar — nessun modo di vedere la percentuale senza portare la finestra in primo piano." Il `MenuBarExtra` (roadmap #11, fatto 2026-08-09) mostra già un'icona che pulsa durante un job e un dropdown con testo di stato, ma nessuna percentuale è visibile da nessuna parte senza aprire la finestra principale o il dropdown della menu bar.

## Decisioni prese in brainstorming

- **Dove**: solo badge sull'icona Dock (non testo accanto all'icona menu bar — scartato per tenere l'intervento piccolo, il Dock è il posto dove si guarda già per badge/notifiche di altre app).
- **Fine job**: il badge sparisce subito (successo, errore o stop manuale) — nessuno stato residuo, nessun "✓" temporaneo.

## Contesto tecnico verificato

`runner.stats.percent` (`Int`, 0-100) è già pubblicato da `BackupRunner` (`@MainActor ObservableObject`) ed è aggiornato in modo uniforme per tutti e tre i job:
- `runMacToSSD()`/`runSSDToHDD()` → passano per `run(label:work:)` (`ContentView.swift:1808`), che imposta `stats.percent = r.percent` (riga 1879) e `stats.percent = 100` a completamento (riga 1837).
- `runSyncS3()` → imposta `stats.percent = snap.percent` direttamente (riga 1652).

`runner.isRunning` (riga 1509) è già `true` solo quando `phase` è `.running`. Nessuna modifica necessaria a `BackupRunner` o ai tre metodi `run*()` — l'unica fonte di verità (`stats.percent` + `isRunning`) esiste già e viene solo letta.

`MenuBarIcon` (`ContentView.swift:45-51`) è la view già presente che osserva `runner.isRunning` per pilotare `.symbolEffect(.pulse, isActive: runner.isRunning)` sull'icona — è montata in modo persistente per tutta la durata dell'app (parte del `MenuBarExtra` label, non una view lazy come un popover), quindi è il posto naturale per osservare anche `stats.percent` senza introdurre nuovo stato.

## Design tecnico

Estendere `MenuBarIcon` con due `.onChange` che aggiornano `NSApp.dockTile.badgeLabel` in modo imperativo:

```swift
private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
            .onChange(of: runner.stats.percent) { _, _ in updateDockBadge() }
            .onChange(of: runner.isRunning) { _, _ in updateDockBadge() }
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = runner.isRunning ? "\(runner.stats.percent)%" : nil
    }
}
```

Nessun nuovo file, nessuna nuova proprietà pubblicata, nessuna modifica a `BackupRunner`. Il badge si aggiorna automaticamente a ogni variazione di `stats.percent` durante il job, e sparisce (`nil`) non appena `isRunning` torna `false` — comportamento identico indipendentemente da quale dei tre job è in corso, dato che tutti aggiornano la stessa proprietà.

## Fuori scope

- Nessun testo percentuale accanto all'icona nella menu bar.
- Nessuno stato residuo dopo la fine del job (niente "✓" o "100%" temporaneo).
- Nessuna modifica a `BackupRunner`/ai metodi `run*()` — il dato (`stats.percent`) esiste già.

## Testing

Nessun XCTest sensato: `NSApp.dockTile.badgeLabel` è una chiamata AppKit imperativa legata al ciclo di vita reale dell'app (Dock icon), non logica pura testabile in isolamento — coerente con come è stata verificata la feature #11 (menu bar), stesso tipo di modifica. Verifica manuale richiesta: avviare un job reale (uno qualsiasi dei tre) e controllare che il badge compaia sull'icona Dock, si aggiorni durante il job, e sparisca a fine job (successo, errore, stop).
