# Catalogo backup (SSD, HDD, Cubbit S3)

Data: 2026-08-09

## Problema

Roadmap #12: nessun modo di sfogliare o cercare cosa è già stato backuppato — oggi serve aprire Tools o ispezionare `rclone`/Finder a mano. Un browser con ricerca per nome/cartella alzerebbe la fiducia nell'app senza toccare la logica di sync.

## Decisioni prese in brainstorming

- **Ambito**: tutte e tre le destinazioni (SSD, HDD, Cubbit S3), con un selettore per scegliere quale sfogliare — non solo Cubbit.
- **Aggiornamento dati**: scansione dal vivo a ogni apertura del catalogo (riuso di `FileManager` per SSD/HDD, nuova funzione S3 dedicata per Cubbit), nessun indice persistito da mantenere sincronizzato. Costo accettato: qualche secondo di attesa alla prima apertura su Cubbit (120.842 oggetti), poi ricerca/scroll istantanei sui dati già in memoria per quella sessione di apertura.
- **Presentazione**: nuova voce "Catalogo" nell'hamburger, apre una `Window` scene indipendente (stesso pattern già usato per Diagnostica) — spostabile/ridimensionabile, utile per una lista lunga.
- **Sola lettura**: nessun bottone di cancellazione o azione sugli elementi elencati — coerente con zero-delete/zero-overwrite. Il catalogo mostra, non modifica.
- **Credenziali S3**: riusa `BackupRunner.s3Config`/`loadS3ConfigIfNeeded()` (cache condivisa già introdotta per Diagnostica/Ripristina, risolve BUG-2) — nessuna nuova lettura Keychain indipendente.

## Design tecnico

### 1. Nuova funzione S3 dedicata (non tocca `listAll`/`listPage` esistenti)

`S3Syncer.listAll(config:)` oggi restituisce `[String: Int64]` (key → size), scartando `LastModified` pur essendo presente nella risposta XML di `ListObjectsV2`. Modificarla toccherebbe ogni chiamante esistente (`previewUpload`, `sampleS3Pair`, restore, orphaned-uploads) — fuori scope ("un browser dei backup... senza toccare la logica di sync"). Aggiungo invece un metodo nuovo e isolato, che riusa gli stessi helper privati di parsing XML (`xmlAll`, già usati da `listPage`):

```swift
struct CatalogEntry: Identifiable {
    let id = UUID()
    let name: String        // ultimo componente del path/key
    let relativePath: String
    let sizeBytes: Int64
    let modified: Date?
}

extension S3Syncer {
    func listAllWithDates(config: S3Config) async throws -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        var token: String? = nil
        repeat {
            if cancelled || Task.isCancelled { break }
            let (page, next) = try await listPageWithDates(config: config, token: token)
            entries.append(contentsOf: page)
            token = next
        } while token != nil
        return entries
    }

    private func listPageWithDates(config: S3Config, token: String?) async throws -> ([CatalogEntry], String?) {
        // stessa richiesta HTTP di listPage; in più xmlAll(xml, tag: "LastModified"),
        // zip a tre (keys, dates, sizes) invece di due, parse ISO8601 per la data.
    }
}
```

`CatalogEntry` è la struct condivisa che alimenta la UI per tutte e tre le destinazioni (locali e S3).

### 2. Scansione locale (SSD/HDD) → `[CatalogEntry]`

Nuovo metodo su `ReviewEngine` (già enumera SSD/HDD/S3 per il campione integrità, home naturale per questa logica di sola lettura cross-destinazione): `func scanLocalCatalog(rootURL: URL) -> [CatalogEntry]`, enumerazione ricorsiva con `FileManager.enumerator(at:includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])`, escludendo gli stessi file di sistema già esclusi altrove (`.DS_Store`, `._*`, ecc. — stessa lista già usata in `sampleLocalPair`). Costruisce `CatalogEntry` per ogni file regolare.

### 3. `CatalogView` (Window scene indipendente)

Nuova `Window("Catalogo", id: "catalog")` in `BackupFotoEnricoApp`, aperta da una nuova `HamburgerRow` in `HamburgerPanel` (stesso pattern usato per "Tools": se serve la config S3, chiamare `await runner.loadS3ConfigIfNeeded()` dalla finestra principale prima di `openWindow(id: "catalog")`, così l'eventuale prompt Keychain avviene nel contesto che sappiamo funzionare in modo affidabile — vedi BUG-2).

Contenuto:
- Un `Picker` in alto: SSD / HDD / Cubbit S3. Ogni opzione disattivata se la destinazione non è disponibile in quel momento (SSD/HDD: `volumes.ssdMounted`/`hddMounted`, stesso segnale già usato in `RestoreView`; S3: `runner.s3Config != nil`).
- Una `TextField` di ricerca sopra la lista: filtra `entries` per `name`/`relativePath` (substring, case-insensitive), applicato in memoria sui dati già caricati — nessuna nuova richiesta di rete/disco per la ricerca.
- Una `List`/`Table` con nome, cartella relativa, dimensione (formattata con `ByteCountFormatter`, già usato per il controllo spazio), data.
- Stato di caricamento (`ProgressView` + testo "Sto leggendo [destinazione]…") mentre la scansione è in corso; ricaricamento automatico quando l'utente cambia destinazione nel Picker.

## Testing

Nuovi test XCTest sulla logica pura, non sulla UI:
- Parsing XML: `listPageWithDates` (o la funzione di parsing isolata al suo interno) su un frammento XML di esempio con `Key`/`LastModified`/`Size`, verificando che `CatalogEntry` risultanti abbiano i campi corretti — stesso stile dei test XML già esistenti per `S3Syncer` (`S3SyncerRetryTests.swift` e affini).
- Enumerazione locale: su directory temporanee reali (stesso pattern di `ReviewEngineIntegritySampleTests.swift`), verificare che `CatalogEntry` prodotte per un set di file noti abbiano nome/path relativo/dimensione corretti, ed escludano `.DS_Store`/`._*`.
- Filtro di ricerca: funzione pura che filtra `[CatalogEntry]` per substring case-insensitive su nome o path — facile da isolare e testare senza toccare rete o disco.

**Verifica manuale richiesta dopo l'implementazione**: aprire Catalogo, cambiare destinazione nel Picker, verificare tempi di caricamento accettabili su Cubbit (120k oggetti), cercare un file noto e verificare che compaia, verificare che le destinazioni non disponibili risultino disattivate con motivazione.

## Fuori scope

- Nessuna azione sugli elementi elencati (niente elimina/scarica/apri dal catalogo — solo lettura).
- Nessun indice persistito tra un'apertura e l'altra.
- Nessuna modifica a `S3Syncer.listAll`/`listPage` esistenti o ai loro chiamanti.
- Nessuna miniatura delle foto nel catalogo (tocca roadmap #17 "miniatura ultimo file", voce separata).
