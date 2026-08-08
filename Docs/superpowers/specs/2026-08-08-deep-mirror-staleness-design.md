# Alert deep mirror stantio (SSD→HDD)

Data: 2026-08-08

## Problema

Il deep mirror SSD→HDD (ricalcolo checksum completo invece del confronto data+dimensione) parte solo quando l'utente esegue manualmente SSD→HDD **e** sono passati ≥30 giorni dall'ultimo deep mirror riuscito (`BackupRunner.runSSDToHDD()`, chiave UserDefaults `lastDeepMirrorDate`). Se l'HDD non viene collegato per settimane, il deep mirror smette di girare silenziosamente — nessun avviso lo segnala. Era già annotato come obiettivo futuro #1 in `Docs/CLAUDE.md`.

## Decisioni prese in brainstorming

- **Canale**: solo passivo, nuovo `ReviewFinding` nel pannello Revisione (Tools) — nessuna notifica di sistema. Coerente con gli altri controlli già presenti (bookmark, permessi rclone.conf, endpoint S3), che l'utente controlla su richiesta.
- **Soglia**: 45 giorni da `lastDeepMirrorDate` (15 giorni di margine oltre il ciclo di 30 giorni del deep mirror).
- **Se HDD non configurato**: nessun finding — stesso comportamento silenzioso di `checkBookmarkRoots()` per le location non configurate.
- **Se deep mirror mai eseguito** (`lastDeepMirrorDate` mai scritta, quindi `.distantPast`): finding `ok: false` con dettaglio esplicito "mai eseguito", non un numero di giorni enorme e senza senso.

## Design tecnico

Nuovo metodo privato in `ReviewEngine`, stesso stile di `checkBookmarkRoots()`/`checkRcloneConfPermissions()`:

```swift
private func checkDeepMirrorFreshness(defaults: UserDefaults = .standard,
                                       now: Date = Date()) -> ReviewFinding? {
    guard bm.urls[.hdd] != nil else { return nil }
    guard let lastDeep = defaults.object(forKey: "lastDeepMirrorDate") as? Date else {
        return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
            detail: "Mai eseguito — collega l'HDD ed esegui SSD → HDD per avviarlo")
    }
    let days = Int(now.timeIntervalSince(lastDeep) / 86400)
    if days > 45 {
        return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
            detail: "Ultimo deep mirror \(days) giorni fa — collega l'HDD per farlo ripartire")
    }
    return ReviewFinding(title: "Deep mirror SSD → HDD", ok: true,
        detail: "Ultimo deep mirror \(days) giorni fa")
}
```

`runConfigChecks()` include il risultato (se non `nil`) nell'array restituito, insieme agli altri check esistenti.

Parametri `defaults`/`now` iniettabili solo per i test — la UI chiama sempre con i default (`.standard`, `Date()`), stesso pattern già usato da `JobSummary.save/load(defaults:)`.

La chiave `"lastDeepMirrorDate"` è duplicata come stringa letterale (già lo è in `BackupRunner.lastDeepKey`) — nessuna nuova astrazione condivisa, non ne vale la pena per una sola chiave in due punti.

## Testing

Nuovo test XCTest in `AppBackupFotoTests`, tre casi con `UserDefaults` di test isolato (suite dedicata, ripulita a fine test) e `now` iniettato:
1. Chiave assente → `ok == false`, dettaglio contiene "Mai eseguito"
2. Data 10 giorni fa → `ok == true`
3. Data 50 giorni fa → `ok == false`, dettaglio contiene il numero di giorni

Nessun test copre il caso "HDD non configurato" via `runConfigChecks()` end-to-end, perché `BookmarkManager.shared` è un singleton non facilmente mockabile per questo check isolato — si testa direttamente `checkDeepMirrorFreshness` bypassando il singleton non è possibile senza refactoring più ampio, quindi ci si limita a verificare la logica di soglia/formattazione, che è la parte nuova. Il ramo "HDD non configurato" replica esattamente il pattern già in produzione e non testato di `checkBookmarkRoots()`.

## Fuori scope

- Nessuna notifica di sistema, nessun banner in-app, nessun badge sull'icona Tools.
- Nessun trigger automatico del deep mirror stesso — resta manuale (collegare l'HDD + eseguire SSD→HDD), questo finding è solo un promemoria visibile su richiesta.
