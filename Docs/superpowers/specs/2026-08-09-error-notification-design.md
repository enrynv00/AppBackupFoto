# Roadmap #16: Notifica di errore (senza bottone Riprova)

Data: 2026-08-09

## Problema

`Docs/ROADMAP.md` punto #16: "Notifiche non azionabili — un bottone 'Riprova' direttamente nella notifica di errore risparmierebbe il giro app→hamburger→rilancio." Il punto presupponeva che una notifica di errore esistesse già, a cui aggiungere solo un'azione.

**Scoperta durante il brainstorming**: non è così. `Notifier` (`ContentView.swift:234-243`) ha un solo call site in tutto il file, `ContentView.swift:1850`, e scatta SOLO sul ramo di successo di `BackupRunner.run()`. Il ramo `catch`/errore (righe 1858-1870) e `stop()` (righe 1800-1812) non inviano nessuna notifica oggi — se un job fallisce mentre l'utente non guarda l'app, non se ne accorge finché non la riapre.

## Decisione presa in brainstorming: scope ridotto, go/no-go come per #5/#13/#14

Il problema più grande oggi non è l'assenza di un bottone Riprova, è l'assenza totale di una notifica di errore. Deciso: **solo aggiungere la notifica di errore mancante**, nessun bottone Riprova. Un bottone Riprova funzionante richiederebbe una `UNNotificationCategory` con azione registrata, un `UNUserNotificationCenterDelegate` (non esistente oggi) per gestire il tap, e un modo per identificare quale dei tre job (Mac→SSD, SSD→HDD, SSD→S3) rilanciare — complessità sproporzionata per un'app single-user usata quasi sempre con la finestra a portata di mano. Se in futuro servisse davvero, è una decisione nuova da riaprire con un motivo concreto, non ora.

## Contesto tecnico verificato

Tutti e tre i job (`runMacToSSD()`, `runSSDToHDD()`, `runSyncS3()`) passano per lo stesso `run(label:work:)` (`ContentView.swift:1814`) — un solo punto di modifica copre tutti e tre.

Il ramo `catch` (righe 1858-1870) ha già `guard !self.wasStopped else { return }` (riga 1862): quando l'utente interrompe manualmente un job, `stop()` imposta `wasStopped = true` **prima** di cancellare il task, quindi quando il `catch` del task cancellato viene eseguito (asincrono, più tardi), la guard lo fa uscire subito senza effetti — **il ramo catch scatta solo per errori reali** (rete, I/O), mai per uno stop manuale. Nessuna modifica necessaria a `stop()` per escludere la notifica: è già escluso.

## Design tecnico

Aggiungere una chiamata a `Notifier.send(...)` nel ramo `catch` di `run()`, subito dopo l'impostazione di `phase` (riga 1864), stesso stile della notifica di successo esistente (riga 1850-1851):

```swift
} catch {
    await MainActor.run {
        guard let self else { return }
        self.elapsedTimer?.cancel(); self.elapsedTimer = nil
        guard !self.wasStopped else { return }
        self.stats.elapsed = self.makeElapsed()
        self.phase = .failed("Errore: \(error.localizedDescription)")
        Notifier.send(self.phase.label,
            "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
        self.completionSnapshot = (self.phase, self.stats)
        JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
            skipped: self.stats.skipped, errors: self.stats.errors,
            hashErrors: self.stats.hashErrors, succeeded: false,
            changedSkipped: self.stats.changedSkipped))
    }
}
```

Titolo notifica: `self.phase.label`, che per questo ramo vale sempre `"Errore: <descrizione localizzata dell'errore>"` (`JobPhase.label`, `ContentView.swift:287-292`, restituisce direttamente la stringa associata al case `.failed`). Corpo: stesso formato "Copiati · Skippati · Errori" già usato per la notifica di successo, letto dallo stato parziale accumulato fino al momento del fallimento.

Nessuna modifica a `Notifier` stesso (`requestAuthorization()`/`send()` restano invariati), nessuna modifica a `stop()`, nessuna modifica ai tre metodi `run*()` chiamanti.

## Fuori scope

- Nessun bottone "Riprova", nessuna `UNNotificationCategory`, nessun `UNUserNotificationCenterDelegate`.
- Nessuna notifica su stop manuale (già escluso dalla guard esistente, nessuna modifica necessaria).
- Nessuna modifica al formato/contenuto della notifica di successo già esistente.

## Testing

Nessun XCTest sensato: `UNUserNotificationCenter` è una chiamata di sistema legata a un permesso interattivo dell'utente, non logica pura testabile in isolamento — coerente con la notifica di successo esistente, mai stata testata automaticamente. Verifica manuale richiesta: far fallire un job reale (es. staccare l'SSD/scollegare la rete a metà copia) e controllare che arrivi la notifica di errore con titolo e corpo corretti, e che uno stop manuale NON generi nessuna notifica.
