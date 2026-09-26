# Inventario certificato su SSD, HDD e Cubbit — design

**Stato:** approvato a voce da Enrico il 2026-09-26, sezione per sezione. In attesa di rilettura di questo documento. Nessuna riga di codice scritta.
**Base:** `main` a `c4ab5d3` (dopo l'unione di `feature/duplicates-at-real-scale`, 861 test).
**Numerazione riservata:** ADR-0015, ROADMAP #44 (ADR-0014 e #43 sono già presi dal piano `2026-09-26-s3-upload-failures-visible`).

## Perché

Enrico vuole, alla fine, **una copia sola di ogni foto per ogni archivio** (SSD, HDD, Cubbit), mettere al sicuro le foto che stanno su un solo archivio, e poter togliere le ridondanze anche da HDD e Cubbit — superando la regola zero-delete, ma con processi abbastanza solidi da non commettere errori.

È troppo per un progetto solo. È stato diviso in quattro, dal più sicuro al più delicato, ognuno con il suo ciclo spec → piano → implementazione:

| # | Progetto | Scrive? |
| :--- | :--- | :--- |
| **1** | **Inventario certificato** (questo documento) | No, solo lettura |
| 2 | Messa in sicurezza: copiare le foto che mancano da qualche archivio | Solo copie, zero overwrite |
| 3 | Doppioni sull'SSD con garanzia: cestinare solo contenuti certificati su tutti e 3 | Cestino SSD, come oggi |
| 4 | Ridondanze su HDD e Cubbit: la regola zero-delete cade, con quarantena e attese | Sì — da progettare per ultimo |

L'inventario è la base di tutti gli altri: nessuna copia e nessuna cancellazione dei progetti 2-4 si decide senza.

## Fatti verificati il 2026-09-26 (non ipotesi)

- **L'HDD ha la stessa struttura di cartelle dell'SSD** (`ASUS`, `Foto iPhone`, `Takeout`, …): lo stesso percorso relativo indica lo stesso file atteso.
- **Cubbit ha ~530 GB, l'SSD ~510 GB**: su Cubbit c'è materiale che sull'SSD non c'è più (effetto dello zero-delete).
- **Il bucket Cubbit è senza versioni** (`rclone backend versioning` → `Unversioned`): oggi una cancellazione su Cubbit è definitiva. Riguarda il progetto 4, non questo.
- **Cubbit si certifica senza scaricare.** Su 219.877 oggetti (529,9 GB), 219.629 hanno un ETag che è l'MD5 diretto del contenuto. I restanti 248 (71,1 GB, tutti ≥ 64 MB) sono stati caricati a pezzi: il loro ETag (`md5(concatenazione degli MD5 delle parti)-N`) è stato **ricalcolato dal file sull'SSD con parti da 64 MB e coincide** (`ASUS/Elba/FILE0056.MOV` → `fc22b3a263f8c63ba9d9f8fbd7a0b713-4` da entrambe le parti). 64 MB è `S3Syncer.multipartChunkSize`.

## Decisioni di Enrico

1. **«Certificato» su Cubbit vuol dire contenuto**, confrontato con l'ETag senza scaricare. Un oggetto che non si riesce a confrontare così è **non certificabile**, mai «certificato» per ipotesi.
2. **Perimetro: solo foto e video**, gli stessi tipi del pannello Doppioni (`IndexableKind`).
3. **Aggiornamento a mano, col bottone.** Nessun aggiornamento automatico in coda ai backup. I progetti 2-4 rifiuteranno di partire su un inventario vecchio (la soglia si decide nel progetto 2).
4. **Approccio A: si estende l'elenco delle foto esistente** (`LibraryIndexStore`, SQLite), non un secondo database.
5. **Si parte da `main` con i Doppioni già uniti** (fatto: `c4ab5d3`).

## Cosa mostra

Pannello **Inventario**, nuova finestra come Doppioni e Diagnostica. L'unità è il **contenuto** (impronta), non il nome del file. Ogni contenuto cade in **una sola** categoria:

| Categoria | Regola |
| :--- | :--- |
| ✅ **Al sicuro** | Presente su SSD, HDD e Cubbit, contenuto certificato identico su tutti e tre |
| ⚠️ **Manca da qualche parte** | Presente e certificato su 1 o 2 archivi, assente dagli altri — il pannello dice quali |
| 🔎 **Solo fuori dall'SSD** | Presente su HDD e/o Cubbit, assente dall'SSD |
| ❗ **Da controllare** | Stesso percorso relativo con contenuto diverso tra due archivi, oppure oggetto Cubbit non certificabile |

Precedenza, quando più regole valgono insieme: ❗ vince su tutto; poi 🔎; poi ⚠️; ✅ solo se nessuna delle altre vale.

In testa, per ogni archivio: numero di foto, numero di copie in più dello stesso contenuto, spazio recuperabile tenendone una sola per archivio. Sotto: da quando l'inventario non è aggiornato, il bottone «Aggiorna l'inventario», l'avanzamento, «Interrompi».

**Il pannello è solo lettura**: nessun bottone copia, sposta o cancella. Un contenuto in ❗ non potrà essere toccato in automatico nemmeno dai progetti successivi.

## Come legge ogni archivio

### SSD e HDD

- **Stesso scanner** dell'elenco attuale (`LibraryIndexer`), puntato sulla radice dell'SSD (bookmark `.ssd`) o dell'HDD (bookmark `.hdd`), stesso filtro `IndexableKind`.
- **Una sola lettura per file, tre impronte**: SHA256 (quella di oggi, ADR-0001), MD5, e l'ETag a pezzi da 64 MB (`md5(md5(parte1)‖…‖md5(parteN))-N`, calcolato solo per i file > 64 MB).
- **Incrementale**: dopo il primo giro si rileggono solo i file con dimensione o data di modifica cambiata. Il primo giro rilegge anche l'SSD una volta, perché le impronte MD5/ETag oggi non ci sono.
- **Lettura**: file aperti in sola lettura con I/O POSIX a blocchi (`S3Syncer.readFileInChunks`, lo stesso del fix per il bug di memoria da 41 GB). Mai `FileHandle.readData`.
- **Fuori dal main thread** (`nonisolated`, ADR-0006), **salvataggio a lotti** (ADR-0002: un inventario parziale è valido in ogni istante), interrompibile.

### Cubbit

- Stessa lista del bucket che l'app usa già (`S3Syncer.listPage`/`listAllDetailed`, con le correzioni di BUG-8), da cui si tiene per ogni oggetto: chiave, dimensione, ETag. Nessun download. **Oggi `S3Listing` tiene solo chiave e dimensione**: `listPage` va esteso a leggere anche `<ETag>` (nell'XML arriva tra virgolette, `&quot;…&quot;`, già gestite da `xmlDecode`), senza cambiare cosa ricevono i chiamanti attuali. `S3Listing.isComplete` è la completezza dell'archivio Cubbit.
- **Certificato** se l'ETag coincide con l'MD5 (oggetto a parte unica) o con l'ETag a pezzi (oggetto `-N`) di almeno un file letto su SSD o HDD con la stessa dimensione.
- **Non certificabile** se l'ETag è `-N` e nessun file locale della stessa dimensione produce quell'ETag con parti da 64 MB (per esempio un oggetto caricato da rclone con parti diverse), o se l'ETag non ha un formato riconosciuto.

### Confronto

1. **Per contenuto**: si raggruppa per impronta (SHA256 fra SSD e HDD; MD5/ETag verso Cubbit) → categorie ✅ ⚠️ 🔎.
2. **Per percorso**: se lo stesso percorso relativo esiste su due archivi con contenuto diverso → ❗.

### Lettura incompleta ≠ assente

La regola più importante del progetto, perché i progetti 2-4 agiranno sulle categorie.

- Se un file non si legge, o un volume si scollega a metà, o la lista Cubbit si interrompe, quella parte dell'inventario è **incompleta**.
- Finché un archivio è incompleto, **nessun contenuto può essere dichiarato assente da quell'archivio**: le foto coinvolte non entrano in ⚠️ né in 🔎 per colpa sua, e il pannello dice chiaramente quale archivio è incompleto e perché.
- Un volume scollegato non è mai un volume vuoto. Stessa logica di `traversalIncomplete` nell'elenco di oggi (ADR-0002).

## Com'è fatto

Tutto dentro `ContentView.swift`, come da convenzione del progetto. Ogni pezzo ha un compito solo:

| Pezzo | Compito | Puro? |
| :--- | :--- | :--- |
| `ContentHasher` | Da un file: SHA256, MD5, ETag a pezzi, in una lettura | Sì (dato un lettore) |
| `S3ETagMatcher` | Dato un ETag Cubbit e i candidati locali: certificato / non certificabile | Sì |
| Scanner HDD | Lo scanner di oggi con radice e tabella diverse | No (disco) |
| Lettore Cubbit | Lista del bucket con l'ETag di ogni oggetto | No (rete) |
| `InventoryClassifier` | Dai dati letti alle categorie, con la regola «incompleto ≠ assente» | Sì — il più testato |
| Pannello Inventario | Bottone, avanzamento, numeri | No (UI) |

**Dati**: nuove tabelle nello stesso SQLite dell'elenco, per archivio (`ssd`, `hdd`, `s3`): percorso/chiave, dimensione, data, SHA256, MD5, ETag, esito della lettura; più lo stato di completezza di ogni archivio per l'ultimo aggiornamento. Aumento della versione di schema: uno schema sconosciuto significa «ricostruisci» (ADR-0002). I dettagli delle tabelle vanno nel piano.

**Convivenza**: l'aggiornamento parte solo con SSD e HDD collegati e Cubbit raggiungibile; non gira insieme a un backup, a un aggiornamento dell'elenco o a uno spostamento nel Cestino (stesso cancello dei job, `JobStartGate`). Non scrive su nessun archivio.

**L'inventario non è mai la prova finale.** È una cache (ADR-0002): prima di ogni copia o cancellazione dei progetti 2-4 il file viene riletto dal disco, come fa oggi `DuplicateTrasher` (ADR-0005).

## Verifica

- **Test automatici** su `ContentHasher` (valori di riferimento calcolati a parte, incluso un file > 64 MB e i casi limite: 0 byte, esattamente 64 MB, 64 MB + 1), `S3ETagMatcher` (parte unica, `-N` giusto, `-N` con parti diverse, formato sconosciuto), `InventoryClassifier` (ogni categoria, ogni precedenza, archivio incompleto, percorso uguale con contenuto diverso).
- **Prova sui dati veri**: i numeri dell'inventario devono coincidere con un confronto indipendente con `rclone check` (riferimento del 2026-09-26: 97.558 file identici fra SSD e Cubbit nella sola cartella `ASUS`).
- **Prova di robustezza**: HDD scollegato a metà lettura → nessuna foto passa in ⚠️/🔎 per quel motivo, l'HDD risulta «incompleto».

## Fuori da questo progetto

- Copiare, spostare o cancellare qualunque cosa (progetti 2-4).
- File che non sono foto o video.
- Aggiornamento automatico in coda ai backup.
- Attivare le versioni sul bucket Cubbit (decisione del progetto 4).
