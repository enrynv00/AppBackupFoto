# Review Engine — pannello di revisione in-app

Data: 2026-07-28
Stato: approvato per implementazione

## Contesto

`Docs/CLAUDE.md` definisce una "Regola sul ciclo AI di revisione (obbligatoria)": una checklist if-then che oggi viene eseguita manualmente dall'assistente AI dopo ogni modifica al codice sorgente (FileManager ops, chiamate S3, bookmark security-scoped, aggiornamenti UI async). È un controllo sul *codice*, eseguito in fase di sviluppo.

Obiettivo di questo lavoro: portare l'idea di "agente di revisione" **dentro l'app in esecuzione**, come pannello diagnostico che l'utente può consultare per sapere se la configurazione è sana e se gli ultimi backup sono avvenuti senza problemi — non più un controllo sul codice sorgente, ma un controllo sullo **stato e sui dati reali** dell'app.

## Scope

Dentro scope:
- Sezione "Revisione" nel `ToolsSheet` esistente (hamburger → Tools).
- Controlli di configurazione istantanei, eseguiti ogni volta che il pannello si apre.
- Riepilogo persistito dell'ultimo job eseguito (sopravvive al riavvio dell'app).
- Verifica di integrità a campione (SHA256) su richiesta, per le tre coppie sorgente↔destinazione: Mac↔SSD, SSD↔HDD, SSD↔S3.
- Test automatici per le parti a logica pura (persistenza, validazione root, campionamento/confronto locale).

Fuori scope (esplicitamente, per questa iterazione):
- Nessun controllo automatico in background o dopo ogni job — tutto resta on-demand, attivato dall'apertura del pannello o dalla pressione del bottone.
- Nessuna azione correttiva automatica (nessun ri-copia, nessun overwrite, nessuna cancellazione) — il motore segnala soltanto.
- Nessuna analisi statica del codice sorgente — non è quello il significato di "integrato nell'app" concordato in fase di brainstorming.
- Nessuno split di `ContentView.swift` in più file — tutto il nuovo codice resta nel file unico, per coerenza con la convenzione attuale del progetto.
- Nessun controllo automatico periodico se il deep mirror SSD→HDD non gira da troppo tempo (resta un'idea futura separata, già annotata in `Docs/CLAUDE.md`).

## Architettura

Nuovo blocco `// MARK: - Review Engine` in `AppBackupFoto/ContentView.swift`, tra `BackupRunner` e `SetupView`. Contiene, in quest'ordine:

1. `JobSummary` — modello dati persistibile
2. `JobHistoryStore` — persistenza in UserDefaults
3. `ReviewFinding` — modello di un singolo esito di controllo
4. `IntegrityCheckResult` — modello dell'esito di una coppia nel campione integrità
5. `ReviewEngine` — motore dei controlli (config + campione integrità)

Modifiche a componenti esistenti:
- `BackupRunner` chiama `JobHistoryStore.save(...)` alla fine di ogni job (successo o fallimento), nello stesso punto in cui oggi imposta `completionSnapshot`.
- `BackupRunner.isLikelyVolumeRoot(_:)` (oggi `private`) viene estratta in una funzione libera/utility condivisa (es. top-level `func isLikelyVolumeRoot(_ url: URL) -> Bool` accanto agli altri helper), così sia `BackupRunner` sia `ReviewEngine.runConfigChecks()` la riusano senza duplicarla.
- `ToolsSheet` guadagna una `GroupBox("Revisione")` con lo stato dei config-check, il riepilogo dell'ultimo job, e il bottone per il campione integrità.

## Componenti in dettaglio

### `JobSummary`

```swift
struct JobSummary: Codable {
    let date: Date
    let label: String        // es. "MAC -> SSD", "SSD -> HDD (deep)", "SSD -> Cubbit S3"
    let copied: Int
    let skipped: Int
    let errors: Int
    let hashErrors: Int
    let succeeded: Bool      // false se il job è terminato in .failed (incluso "Interrotto dall'utente")

    var isClean: Bool { succeeded && errors == 0 && hashErrors == 0 }
}
```

### `JobHistoryStore`

```swift
enum JobHistoryStore {
    private static let key = "lastJobSummary"

    static func save(_ summary: JobSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> JobSummary? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(JobSummary.self, from: data)
    }
}
```

`BackupRunner` costruisce il `JobSummary` da `stats` + `phase` + `label` nel punto in cui oggi imposta `completionSnapshot` (sia nel ramo di successo che in quello di errore/interruzione in `run(label:work:)`), e chiama `JobHistoryStore.save(...)`.

### `ReviewFinding`

```swift
struct ReviewFinding: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
    let detail: String
}
```

### `IntegrityCheckResult`

```swift
struct IntegrityCheckResult: Identifiable {
    let id = UUID()
    let pairName: String     // "Mac ↔ SSD" · "SSD ↔ HDD" · "SSD ↔ S3"
    var checked: Int = 0
    var matched: Int = 0
    var mismatches: [String] = []   // path relativi dei file con hash diverso
    var skippedNoSource: Int = 0    // file campionati ma non trovati sul lato sorgente (es. rimossi dall'utente)
    var error: String? = nil        // valorizzato se l'intera coppia non è stata verificabile (volume non montato, bookmark non accessibile, ecc.)
}
```

### `ReviewEngine`

```swift
final class ReviewEngine {
    private let bm = BookmarkManager.shared

    func runConfigChecks() -> [ReviewFinding] { ... }

    func runIntegritySample(
        sampleSize: Int = 20,
        onProgress: @escaping (String) -> Void
    ) async -> [IntegrityCheckResult] { ... }
}
```

**`runConfigChecks()`** — sincrono, nessun accesso a volumi esterni oltre a leggere i bookmark salvati e i metadata del file `rclone.conf`. Produce un `ReviewFinding` per ciascuno di questi controlli:

- Per `.ssd` e `.hdd` (non per `.photos`, che non è un volume): se il bookmark è configurato, verifica `isLikelyVolumeRoot` sull'URL risolto. `ok = false` con dettaglio "punta a una sottocartella, non alla root del volume" se fallisce.
- Permessi di `~/.config/rclone/rclone.conf`: `ok = false` se più aperti di `0600` o se il file non esiste.
- Endpoint S3: chiama `S3Syncer.readConfig()` e interpreta l'esito — se lancia un errore (permessi, HTTPS mancante, host non in allow-list, credenziali mancanti), quello diventa il `detail` del finding con `ok = false`.

Questi controlli **non richiedono che i volumi siano montati** (leggono solo bookmark risolti e file di config), quindi restano sempre disponibili in `ToolsSheet`.

**`runIntegritySample(...)`** — asincrono, chiamato dal bottone dedicato. Per ciascuna delle tre coppie:

1. **Mac ↔ SSD**: apre gli accessi bookmark `.photos` e `.ssd` (con `defer` per lo `stopAccessing`), enumera i file sotto `SSD/Foto iPhone`, ne pesca `sampleSize` a caso, per ciascuno cerca il file con lo stesso nome nella Libreria Foto sorgente, calcola SHA256 di entrambi i lati e confronta. Se il file sorgente non esiste più, incrementa `skippedNoSource` (non è un mismatch: l'utente potrebbe aver cancellato la foto originale dopo il backup, cosa che l'app non deve trattare come un errore).
2. **SSD ↔ HDD**: stesso schema, campiona da HDD e confronta con SSD.
3. **SSD ↔ S3**: lista le chiavi presenti su S3 (riusa la logica di `S3Syncer` — se necessario, esporre un metodo pubblico leggero che restituisce solo le chiavi, senza dover duplicare la paginazione), ne pesca `sampleSize` a caso tra quelle che esistono anche su SSD, scarica ciascun oggetto in un file temporaneo, calcola SHA256, confronta con l'hash del file locale su SSD, poi rimuove subito il file temporaneo scaricato.

Se per una coppia il bookmark non è accessibile o il volume non è montato, `IntegrityCheckResult.error` viene valorizzato e quella coppia viene saltata — nessun crash, nessun alert modale bloccante (il pannello è diagnostico, non un job critico).

**Vincolo di sicurezza esplicito**: `ReviewEngine` non chiama mai `removeItem`, `copyItem` verso una destinazione persistente, né alcuna operazione S3 di scrittura/cancellazione. I soli file scritti sono file temporanei di download per il confronto S3, cancellati subito dopo l'hash. Questo va verificato nella fase 2 (revisione if-then) della regola già esistente in `CLAUDE.md` prima di considerare l'implementazione completa.

## UI — `ToolsSheet`

Nuova `GroupBox("Revisione")`, posizionata dopo quella "S3 — Cubbit" ed prima di "Sync Info" (o unita a "Sync Info", da valutare in fase di implementazione per equilibrio visivo). Contiene:

- Lista dei `ReviewFinding` da `runConfigChecks()`, eseguita in `.onAppear` del sheet — ogni riga con icona ✅/⚠️ e `detail` in caption.
- Riepilogo dell'ultimo job da `JobHistoryStore.load()`: label, data/ora, copiati/skippati/errori/hash-mismatch, con badge verde se `isClean`, arancione altrimenti. Se `nil` (mai eseguito nessun job da quando esiste questa funzione), mostra "Nessun job registrato".
- Bottone "Verifica integrità campione (20 file per coppia)" che avvia `Task { await reviewEngine.runIntegritySample(...) }`, disabilitato mentre è in corso, con un piccolo indicatore di progresso testuale (riusa lo stile già presente per `onStatus` altrove) e poi il risultato per coppia (es. "Mac ↔ SSD: 20/20 verificati, 0 problemi" oppure in rosso se ci sono `mismatches`).

Nessun nuovo sheet, nessuna nuova voce nell'hamburger: tutto dentro `ToolsSheet`.

## Error handling

- Config checks: nessuna eccezione può propagarsi all'utente in modo bloccante — ogni controllo cattura il proprio errore e lo trasforma in un `ReviewFinding` con `ok = false`.
- Integrity sample: errori di rete S3, bookmark non accessibili, volumi non montati → valorizzano `IntegrityCheckResult.error` per quella coppia specifica; le altre coppie proseguono comunque. Nessun `NSAlert` bloccante (diverso dal comportamento dei job veri e propri, dove un `NSAlert` ha senso perché l'operazione si ferma del tutto).
- Se `sampleSize` (20) supera il numero di file effettivamente disponibili in una coppia, si campiona semplicemente tutto quello che c'è (nessun errore).

## Testing

Nuovi test in `AppBackupFotoTests`:

1. **`JobHistoryStoreTests`** — roundtrip save/load su una `UserDefaults` di test isolata (suite dedicata, non `.standard`, per non toccare le preferenze reali durante i test); verifica anche il caso "nessun dato salvato" → `load()` restituisce `nil`.
2. **`IsLikelyVolumeRootTests`** — tabella di URL con diversi numeri di `pathComponents` → verifica che la funzione condivisa estratta da `BackupRunner` restituisca il valore atteso. Questi test bloccano anche eventuali regressioni sul fix del vecchio BUG-1.
3. **`ReviewEngineIntegritySampleTests`** — stesso pattern a directory temporanee reali di `FileSyncerZeroOverwriteTests`: crea una coppia di directory con file identici e un file alterato, verifica che il campionamento locale (Mac↔SSD / SSD↔HDD, stessa logica) trovi correttamente il mismatch e non segnali falsi positivi sui file identici. Il ramo S3 non viene coperto da test automatici (richiederebbe rete o un mock del protocollo S3): resta verificato manualmente prima del rilascio.

## Domande aperte per l'implementazione

Nessuna bloccante. Un dettaglio lasciato alla fase di implementazione: se unire visivamente la `GroupBox("Revisione")` con quella "Sync Info" già esistente in `ToolsSheet`, per non appesantire troppo lo sheet — decisione di dettaglio UI, non architetturale.
