# BUG-3: S3Syncer sovrascrive silenziosamente file cambiati su Cubbit

Data: 2026-08-09

## Problema

Trovato leggendo il codice durante il brainstorming di roadmap #13 (versioning), non ancora confermato con un upload reale contro Cubbit ma la logica è deterministica e inequivocabile.

`S3Syncer.sync(from:config:...)` (`ContentView.swift`, riga indicativa 920) decide quali file caricare così:

```swift
let toUpload = files.filter { existing[$0.key] != $0.size }
```

`existing` è `[String: Int64]` (key S3 → dimensione). Questo filtro include:
- le key **assenti** da `existing` (file nuovi — corretto, vanno caricati)
- le key **presenti** in `existing` ma con dimensione locale diversa (file cambiati — **sbagliato**: vengono ricaricati)

Il caricamento passa da `upload()` → `put()` (righe indicative 1110-1138), che fa una `PUT` HTTP diretta sulla key S3 senza nessun controllo di esistenza — per una key già presente, questo **sovrascrive l'oggetto**.

Questo contraddice direttamente sia la regola assoluta del progetto ("zero delete, zero overwrite") sia quanto documentato in `Docs/CLAUDE.md` per `S3Syncer` ("confronto per key+size per decidere cosa caricare (mai DELETE/overwrite remoto)"). È anche diverso dal comportamento di `FileSyncer` (Mac→SSD, SSD→HDD), che per lo stesso scenario (file esiste ma è cambiato) **salta sempre** (`ContentView.swift`, `syncFile`, commento esplicito "destination exists but differs — zero-overwrite rule: skip").

**Impatto**: qualunque file già presente su Cubbit la cui dimensione locale cambia (modifica, corruzione, o qualunque altra causa) viene silenziosamente sovrascritto al prossimo SSD→S3 — proprio sulla copia offsite pensata per sopravvivere alla perdita di Mac+SSD+HDD insieme.

## Fix

Allineare `S3Syncer.sync()` al comportamento già corretto di `FileSyncer`: se la key esiste già su S3, skippare sempre, indipendentemente dalla dimensione. Solo le key davvero assenti vengono caricate.

Estrarre la decisione in una funzione pura e testabile (nessuna chiamata di rete), stesso stile già usato per `validateEndpoint`/`isLikelyVolumeRoot` in questo progetto:

```swift
static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
    !existingKeys.contains(key)
}
```

`sync()` la usa così:

```swift
let existingKeys = Set(existing.keys)
let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
```

`result.skipped = files.count - toUpload.count` resta invariato (conta correttamente sia le key identiche sia quelle cambiate, ora entrambe skippate come su FileSyncer).

## Testing

Nuovo test XCTest su `shouldUpload` — funzione pura, nessuna dipendenza da rete/disco:
- key assente da `existingKeys` → `true` (va caricata)
- key presente in `existingKeys` → `false` (skip), **indipendentemente dal fatto che nel mondo reale la dimensione coincida o meno** — il punto del fix è proprio che la dimensione non deve più influenzare questa decisione a livello di quali key vengono caricate (il confronto per dimensione resta solo in `previewUpload`, per la sola stima informativa "quanti file mancano", che non tocca la scrittura).

Un test scritto contro la vecchia firma (`existing[$0.key] != $0.size`, replicata inline nel test) e poi contro il fix, per dimostrare esplicitamente il cambio di comportamento su una key esistente con dimensione diversa (prima: verrebbe inclusa in `toUpload`; dopo: no).

## Fuori scope

- Nessuna modifica a `previewUpload` (già corretto, mostra solo stime, non scrive nulla).
- Nessuna segnalazione all'utente di "quanti file sono stati skippati perché cambiati" — quello è il contenuto di roadmap #13, affrontato subito dopo questo fix, ora applicabile in modo uniforme a tutti e tre i job (FileSyncer già corretto, S3Syncer corretto da questo fix).
- Nessuna verifica retroattiva di oggetti eventualmente già sovrascritti in passato su Cubbit — fuori scope tecnico (nessun modo di recuperare un oggetto S3 già sovrascritto senza versioning bucket-level, non presente su questo bucket); se serve, va discusso separatamente con l'utente.
