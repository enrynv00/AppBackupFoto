# Spec — Anteprima vera nel wizard di import (roadmap #27-A / #31, terza parte)

**Stato: APPROVATA da Enrico il 2026-09-01.** Le quattro domande aperte sono chiuse nella sezione «Risposte di Enrico» della spec — leggerla prima di implementare: la risposta 1 non è un sì generico ma un sì condizionato a tre requisiti sull'avanzamento visibile e l'interruzione.

Piano di esecuzione: `Docs/superpowers/plans/2026-09-01-import-preview-dedup.md`.

## Problema

Il wizard di import (`ImportView`, Task 3 di #27-A) mostra «File da importare: N». Quel numero viene da `FileSyncer.previewSync().toAdd`, che conosce **una sola** regola di skip — lo zero-overwrite, cioè «il file esiste già a destinazione». Non conosce il dedup per contenuto introdotto da #31, che `BackupRunner.runImport` invece applica via `isDuplicate:` → `BackupRunner.isAlreadyInLibrary`.

L'anteprima **promette quindi più file di quanti ne verranno copiati**, e sbaglia in modo massimo proprio nello scenario da cui #31 è nato: reimportare una scheda SD non svuotata fra due sessioni. Lì il 100% dei file annunciati diventa 0 file copiati.

C'è un secondo scarto, minore ma sempre presente: i doppioni **interni** allo stesso import (due file byte-identici nella stessa sorgente), che `ImportSessionIndex` fa saltare in copia e che l'anteprima conta due volte.

Il difetto era **noto e dichiarato** — `.claude/rules/architecture.md`, sezione «Il dedup entra in `FileSyncer` senza toccare i job esistenti»: «Nota nota e accettata: `previewSync` non è allineato e sovrastima lo spazio necessario quando la sorgente contiene doppioni — verso sicuro». Era vero finché quel numero serviva solo al controllo di spazio, dove sovrastimare è il verso sicuro. Da quando lo stesso numero è **mostrato all'utente in un wizard**, sovrastimare non è più un verso sicuro: è una promessa falsa.

**Decisione di Enrico (2026-09-01): anteprima vera.** Non un avviso a parole, non un limite dichiarato. Il numero mostrato deve essere quello vero.

---

## Misure (2026-09-01, SSD reale collegato, `/Volumes/SSD - Enri`)

Tutte fatte sul volume vero, non dedotte. L'indice SQLite era vuoto al momento della misura (`SELECT COUNT(*) FROM entries` = 0), quindi le collisioni sono state calcolate direttamente dai `stat` di 127.758 file e verificate rihashando campioni reali.

### La libreria

| | |
| :---- | :---- |
| file totali sul volume | 127.758 |
| file visibili non-AppleDouble | 70.072 |
| **file media** (immagini + video per estensione) | **47.482** |
| byte dei media | **237,4 GiB** |
| dimensione mediana / media di un media | 2,24 MiB / 5,12 MiB |
| media sotto i 100 KB | 1.802 (3,8%) |
| **dimensioni distinte fra i media** | **34.513 (72,7%)** |
| media per dimensione distinta | 1,38 |
| gruppo di dimensione più affollato | **7 file** |

Il conteggio dei media coincide **esattamente** con i 47.482 già registrati in `architecture.md` (fatto misurato n. 12) — una conferma indipendente che il filtro per estensione usato qui approssima bene `IndexableKind`.

### Collisione di dimensione dentro la libreria

25.032 media su 47.482 (**52,7%**, 108,0 GiB) condividono la dimensione con almeno un altro media.

**Questo numero preso da solo è fuorviante e non va usato per dimensionare niente.** Le dimensioni più affollate hanno 5-7 file, non centinaia; la media è 1,38 file per dimensione. È una collisione *larga e sottile*. E soprattutto: gran parte di quelle collisioni sono **doppioni veri**, non collisioni casuali — cioè esattamente i file che l'anteprima deve rilevare, non rumore da filtrare via.

### Collisione fra cartelle diverse — è questo il tasso che conta

Approssima la domanda vera: *un file genuinamente nuovo, quante probabilità ha di collidere per caso con qualcosa già in libreria?* Ogni coppia è stata poi **verificata rihashando un campione reale** di file colliding, per distinguere una collisione casuale da un doppione vero.

| sorgente → destinazione | file | collidono | % | campione rihashato: byte-identici |
| :---- | ---: | ---: | ---: | :---- |
| Foto iPhone → Other | 18.180 | 6 | **0,0%** | — |
| Foto iPhone → Foto Google Drive | 18.180 | 19 | **0,1%** | 7/19 (36,8%) |
| Other → Foto iPhone | 1.508 | 6 | **0,4%** | — |
| Takeout → Takeout 2 | 13.139 | 86 | **0,7%** | 21/40 (52,5%) |
| Takeout 2 → Takeout | 10.708 | 87 | **0,8%** | — |
| Foto Google Drive → Foto iPhone | 3.947 | 35 | **0,9%** | — |
| — coppie che sono doppioni veri fra loro — | | | | |
| Foto Google Drive → Takeout | 3.947 | 3.182 | 80,6% | **40/40 (100%)** |
| Takeout → Foto iPhone | 13.139 | 5.404 | 41,1% | **39/40 (97,5%)** |
| Takeout 2 → Foto iPhone | 10.708 | 3.403 | 31,8% | **40/40 (100%)** |
| Other → Takeout | 1.508 | 396 | 26,3% | **40/40 (100%)** |

**La lettura è netta, e il rihash la dimostra invece di supporla.** Le coppie sopra il 25% collidono perché sono **davvero l'una la copia dell'altra** (Takeout e Takeout 2 sono estrazioni Google delle stesse foto già in `Foto iPhone`): il campione rihashato dà 97,5-100% di file byte-identici. Le coppie fra insiemi di foto genuinamente **diversi** stanno tutte **sotto l'1%**, e perfino di quel meno-dell'1% solo il 37-53% è un doppione vero.

**Conclusione: il filtro sulla dimensione regge, e regge molto bene.** Per un import di foto genuinamente nuove meno dell'1% dei file richiede lettura e hash; il 99% si conta senza toccare il disco.

*Nota di contorno, già utile a un'altra decisione:* `Takeout → Takeout 2` allo 0,7% dice per misura che **quelle due cartelle non sono l'una il doppione dell'altra**, contrariamente a quanto i nomi suggeriscono. Conferma la decisione di Enrico del 2026-09-01 di tenerle alla pari nella regola di proposta del pannello Doppioni.

### Il rovescio: nel reimport il filtro non scarta niente

Nel reimport di una scheda già importata i file sono doppioni **veri**, quindi collidono al ~100%. Il filtro non elimina nulla e l'anteprima finisce per leggere e hashare **l'intera sorgente**. Non è un difetto del filtro: quelle letture sono esattamente il lavoro necessario per produrre il numero vero (0). È però il costo dominante di questa feature, ed è trattato sotto.

### Doppioni interni alla stessa sorgente — non sono trascurabili

Proxy: quanti file, dentro una singola cartella di primo livello, condividono la dimensione con un altro file **della stessa cartella**, e quanti di quei gruppi contengono davvero una coppia byte-identica (campione rihashato).

| cartella | file | in gruppi di dimensione | % | gruppi campionati con una coppia byte-identica vera |
| :---- | ---: | ---: | ---: | :---- |
| Foto iPhone | 18.180 | 491 | **2,7%** | 24/30 (80%) |
| Takeout | 13.139 | 193 | 1,5% | 23/30 (77%) |
| Takeout 2 | 10.708 | 73 | 0,7% | 0/30 (0%) |
| Foto Google Drive | 3.947 | 1.422 | **36,0%** | 29/30 (97%) |
| Other | 1.508 | 31 | 2,1% | 12/15 (80%) |

`Foto iPhone` è il proxy più vicino a «una scheda / un rullino»: **~2,7% dei file in gruppi di dimensione, e l'80% di quei gruppi contiene una coppia davvero identica**. Non è zero. Un'anteprima che ignorasse i doppioni interni sbaglierebbe di qualche punto percentuale su un rullino iPhone e del 35% su una cartella tipo `Foto Google Drive`. **Va gestito, non dichiarato come limite.**

### Velocità di lettura+SHA256 dall'SSD

Misurata rihashando i campioni sopra, sull'SSD reale via USB: **279–616 MiB/s** su sei campioni (mediana ~470 MiB/s). Più alta dei 224 MiB/s registrati in `architecture.md` per `LibraryIndexCard.durata`, che pagava in più un processo per file — coerente con la nota «18 minuti è probabilmente un tetto».

### Costo delle query sull'indice

Database sintetico con le 47.482 righe reali (17,2 MiB, gli stessi due indici dello schema di produzione):

| query | costo |
| :---- | :---- |
| `SELECT DISTINCT size FROM entries` (34.513 righe) | **9,1 ms** |
| 2.000 × `SELECT 1 FROM entries WHERE size=? LIMIT 1` | **9,3 ms totali (≈4,7 µs ciascuna)** |

**Questo risultato smonta un pezzo della direzione ipotizzata in review** (vedi sotto).

---

## Verdetto sulla direzione ipotizzata

L'idea portata all'Architect era: *evitare di hashare ogni file candidato facendo prima **una sola query** all'indice per l'insieme delle dimensioni già presenti in libreria; solo i file la cui dimensione compare in quell'insieme meritano lettura+hash.*

**La metà sostanziale dell'idea è giusta, ed è già implementata.** Il filtro dimensione-prima esiste da #31: è lo «Stadio 1» di `BackupRunner.isAlreadyInLibrary`, che chiama `LibraryIndexStore.hasAnyEntry(withSize:)` prima di hashare qualunque cosa. Le misure sopra ne quantificano per la prima volta l'efficacia sul volume vero: **meno dell'1% di hash per un import di foto nuove**. Regge.

**La metà «una sola query» non serve, e va scartata.** Le 2.000 query per file costano **9,3 ms in totale**, contro 9,1 ms della singola query che le sostituirebbe. Non c'è niente da guadagnare, e ci sarebbe da perdere:

- un nuovo metodo pubblico sullo store (`allSizes()`) da mantenere, testare e documentare;
- un `Set<Int64>` da 34.513 elementi con una semantica di **istantanea** — cioè una seconda nozione di «quando l'indice è stato letto» accanto a quella già esistente;
- soprattutto: **una seconda copia della decisione di dedup**, diversa da quella dell'import. È esattamente la classe di errore che questo progetto ha già pagato tre volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`), e che ADR-0003 chiama per nome.

Sul vincolo 4 (la coda seriale dello store occupata dalle scritture a batch): resta rispettato senza `allSizes()`. Lo scanner committa a batch di 200 entry, cioè — a 224 MiB/s e 5,12 MiB medi per file — **circa un commit ogni 4-5 secondi**. Un'anteprima da 2.000 file che gira per 80 s incrocia una ventina di commit, ciascuno di pochi millisecondi. E la lettura **non è mai sul main thread**: `previewSync` gira già su `DispatchQueue.global(qos: .userInitiated)`, come `BackupRunner.indexedFileCount` e `DuplicatesView` girano fuori dal main.

**Quindi: l'anteprima non introduce alcun nuovo accesso all'indice.** Riusa `isAlreadyInLibrary` così com'è.

---

## Design

### Principio: l'anteprima non è un'approssimazione dell'import, è lo stesso predicato

L'unico modo per garantire «il numero mostrato è quello vero» non è avvicinarsi al comportamento dell'import: è **eseguire lo stesso predicato**. L'anteprima chiama `BackupRunner.isAlreadyInLibrary`, la stessa funzione che `runImport` cabla su `FileSyncer.isDuplicate`. Niente logica parallela, niente seconda soglia di fiducia, niente da tenere allineato a mano.

Ne discende tutto il resto gratis: la guardia `IndexableKind`, il confinamento dei candidati dentro la root, il contratto «array vuoto = non lo so» di `entries(withHash:)`, il filtro dimensione, la rilettura del candidato su disco.

### A quale livello di fiducia si colloca questa lettura (vincolo 5)

ADR-0003, con la nota del 2026-08-27, definisce **tre** livelli:

1. **visualizzazione** (pannello Doppioni): ci si fida della cache;
2. **skip durante un import**: non ci si fida, si rilegge e rihasha il candidato;
3. **cancellazione**: si rilegge ogni membro del gruppo, la copia tenuta compresa, e si pretende unanimità.

**L'anteprima si colloca al livello 2, non al livello 1.** È la decisione meno ovvia di questa spec, quindi va argomentata invece che assunta.

La tentazione è il livello 1: l'anteprima è un percorso a basso danno — un numero sbagliato è un numero sbagliato, non una foto persa — e fidarsi dell'indice senza rileggere l'SSD farebbe risparmiare tutte le letture lato libreria. **Non regge, per due ragioni distinte.**

**Prima ragione: il livello 1 sbaglierebbe il numero, che è l'unica cosa che questo lavoro deve produrre.** L'indice contiene per progetto **entry fantasma** — file non più sul disco la cui riga resta, perché «traversata incompleta ⇒ nessuna rimozione» (decisione di prodotto di Enrico del 2026-08-26, contatore `vanishedKept`, escape hatch `deleteIndexAndRecreate`). Non è un caso limite: è uno stato **voluto e permanente** dell'indice fino allo svuotamento manuale. Con la fiducia di livello 1, ogni entry fantasma fa dichiarare all'anteprima un doppione che l'import non riconoscerà — e il numero **sotto-promette**. Avremmo sostituito un errore in eccesso con un errore in difetto, cioè non avremmo risolto niente.

**Seconda ragione: il livello 1 sarebbe una seconda copia della decisione.** Il livello 1 e il livello 2 divergono in **entrambe** le direzioni — entry fantasma → l'anteprima sotto-conta; hash stantio (exiftool, `rsync -t`, restore da Finder preservano tutti l'mtime) → l'anteprima sovra-conta. Due percorsi che possono discordare in due versi opposti sullo stesso dato sono precisamente ciò che ADR-0003 chiede di non costruire.

**Il prezzo del livello 2 è misurato ed è piccolo.** Le riletture lato SSD avvengono **solo** sui candidati che hanno già superato dimensione e hash, cioè solo sui doppioni veri. Nel caso peggiore (reimport di una scheda da 7 GiB interamente duplicata) sono 7 GiB a ~470 MiB/s ≈ **15 s**, contro i ~78 s di lettura della sorgente. Il 16% del costo, per la sola cosa che rende il numero vero.

Formulato come la contro-domanda che ADR-0005 pone a chi vorrà togliere la rilettura: *chi rimuovesse la rilettura dell'SSD dall'anteprima otterrebbe un numero che descrive l'indice, non il disco — e l'indice, per decisione esplicita, contiene file che sul disco non ci sono più.*

### Dove viene letta la dimensione, e perché quella via è sicura (vincolo 3)

Il fatto misurato n. 1 (`URL.resourceValues` serve dalla cache dell'istanza di URL, e gli URL degli enumeratori arrivano prefetchati) è già costato due bug in questo progetto. Quindi, esplicitamente:

- **Questo design non aggiunge nessuna lettura di dimensione nuova.** Riusa quella che `FileSyncer.previewFile` fa già: `(try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize`, su un URL prodotto da `fm.contentsOfDirectory(at:includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], ...)`. `.fileSizeKey` **non** è nella lista di prefetch, ma va assunto comunque potenzialmente servito dalla cache: la lista è un suggerimento, non un contratto.
- **Quel numero non decide mai niente.** Fa da chiave di bucket in due punti — il filtro dimensione dello Stadio 1 e l'istogramma delle dimensioni della sorgente — e alimenta `toAddBytes`, che è già oggi una stima. A decidere se un file è un doppione è **sempre e solo** `sha256(of:)` su un descrittore riaperto.
- **`sha256` chiude il caso residuo da solo.** Delega a `sha256Measured`, che rilegge `fstat` prima e dopo e restituisce `nil` se dimensione e byte contati non coincidono. Un file che cambia mentre lo leggiamo produce `nil`, `nil` non è mai uguale a un hash, quindi il file **non** viene dichiarato doppione e finisce fra i `toAdd`. Verso sicuro: al massimo l'anteprima promette un file in più.
- **Una dimensione stantia costa al massimo un doppione non riconosciuto**, cioè un file contato in più. Mai un file contato in meno. È lo stesso ragionamento già scritto accanto alla riga in `isAlreadyInLibrary`, e va ripetuto accanto alle righe nuove **perché nessuno lo "corregga" credendolo il terzo bug**.

### `FileSyncer` resta ignaro dello store e di `IndexableKind` (vincoli 1 e 2)

Stesso schema già usato per `isDuplicate`/`onCopied`/`onUnverified` su `FileSyncer.sync`: **un parametro nuovo, con default no-op**.

```swift
extension FileSyncer {
    /// Un file che `previewSync` conterebbe fra i `toAdd`. Coppia neutra: nessun
    /// riferimento all'indice, a `IndexableKind` o allo store.
    struct PreviewCandidate { let url: URL; let size: Int64 }
}

func previewSync(from src: URL, to dst: URL, deep: Bool,
                 duplicateFilter: (([PreviewCandidate]) -> Set<Int>)? = nil) async
    -> (toAdd: Int, toSkip: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int)
```

- `duplicateFilter == nil` (default) ⇒ **nessun array viene costruito**, nessuna chiamata, comportamento byte-per-byte quello di oggi. `runMacToSSD`, `runSSDToHDD`, `previewMacToSSD`, `previewSSDToHDD`, `RestoreEngine.runLocal` e il controllo spazio di `runImport` non lo passano.
- La closure riceve **tutti** i candidati in una volta, non uno per volta. È obbligatorio: per riconoscere due file byte-identici dentro la stessa sorgente bisogna sapere, **prima** di hashare il primo dei due, che esiste un secondo file di quella dimensione. Un predicato `(URL) -> Bool` chiamato in streaming non può saperlo — il primo del paio non verrebbe mai hashato e quindi mai ricordato. Le misure sopra dicono che rinunciarci costerebbe il 2,7% su un rullino iPhone e il 36% su una cartella tipo `Foto Google Drive`: troppo per un limite dichiarato.
- La closure restituisce gli **indici** dei candidati che sono doppioni, non un conteggio e non un insieme di URL. Gli indici tengono l'aritmetica dentro `FileSyncer`, dove non può desincronizzarsi, e non dipendono dall'uguaglianza fra URL (che su ExFAT, fra NFC/NFD e maiuscole, non è una cosa di cui fidarsi). Indici fuori intervallo vengono ignorati: la closure è codice esterno.
- `FileSyncer` non impara niente di nuovo. Non sa cos'è un doppione, non sa cos'è l'indice, non conosce `IndexableKind`. Sa solo che qualcuno gli ha detto quali dei suoi candidati non conteranno.

Il campo nuovo `toSkipDuplicates` vale **0** ogni volta che `duplicateFilter` è `nil`, quindi l'invariante che `RestoreEngine.runLocal` usa oggi (`toAdd + toSkip` = totale) resta vera lì. L'invariante generale diventa `toAdd + toSkip + toSkipDuplicates == file esaminati` ed è fissata da un test.

### `isAlreadyInLibrary` restituisce anche l'hash che ha già calcolato

Un quarto parametro con default no-op, stesso schema:

```swift
nonisolated static func isAlreadyInLibrary(url: URL,
                                          store: LibraryIndexStore?,
                                          session: ImportSessionIndex,
                                          libraryRoot: URL?,
                                          onSourceHash: (String) -> Void = { _ in }) -> Bool
```

Serve solo all'anteprima, per registrare nella propria `ImportSessionIndex` il file **appena hashato e risultato non-doppione**, così che un suo gemello più avanti nella sorgente lo riconosca. Senza, lo stesso file andrebbe hashato due volte. `runImport` non lo passa e resta identico.

Chiamato **solo** quando l'hash è stato davvero calcolato (Stadio 2 raggiunto), mai con un valore inventato.

### Il motore dell'anteprima

Nuova funzione `nonisolated static`, accanto a `isAlreadyInLibrary` in `BackupRunner`, testabile senza SwiftUI:

```swift
nonisolated static func importPreviewDuplicates(
    candidates: [FileSyncer.PreviewCandidate],
    store: LibraryIndexStore?,
    libraryRoot: URL?,
    isCancelled: () -> Bool,
    onProgress: (_ done: Int, _ total: Int) -> Void) -> Set<Int>
```

1. Costruisce `sourceRepeatedSizes` = le dimensioni che compaiono **almeno due volte** fra i candidati. È un `Counter` in memoria, nessun I/O.
2. Crea una `ImportSessionIndex` locale — la stessa classe usata dall'import, con la sola differenza che qui registra **URL della sorgente** invece che di destinazione, perché la copia non è ancora avvenuta.
3. `total` = numero di candidati la cui dimensione sta in `sourceRepeatedSizes` **oppure** che superano lo Stadio 1 di `isAlreadyInLibrary`. Questo numero è noto **prima** di leggere un solo byte ed è ciò che la UI mostra come denominatore della barra («Controllo il contenuto di 70 file su 2.000» oppure «di 1.987 file su 2.000»). È di per sé un'informazione onesta e gratuita.
4. Per ogni candidato in ordine di enumerazione:
   - se la dimensione non è in `sourceRepeatedSizes` **e** `isAlreadyInLibrary` esce allo Stadio 1, non è un doppione: prosegue senza leggere nulla;
   - altrimenti chiama `isAlreadyInLibrary(..., session: previewSession, onSourceHash: { ... })`. Se `true` ⇒ inserisce l'indice nel risultato. Se `false` e l'hash è stato calcolato ⇒ `previewSession.record(hash:at:)`, così il gemello successivo lo trova.
   - dopo ogni candidato: `onProgress`, e `if isCancelled() { ... }`.
5. **Interruzione**: restituisce l'insieme parziale. Il chiamante che ha interrotto **scarta il risultato** (pattern del token di richiesta già usato in `DuplicateGroupRow`) e non mostra alcun numero. Il verso non-sicuro qui è mostrare un numero parziale, non restituirlo.

L'ordine di enumerazione fra `previewDir` e `syncDir` coincide (stessa `contentsOfDirectory`, stesse opzioni, stessa ricorsione). Anche se non coincidesse, *quale* dei due gemelli viene tenuto può cambiare ma il **conteggio** no.

### La UI

`ImportPreviewStatus` — enum di logica **pura**, testabile, sul modello di `LibraryIndexStatus` e `DuplicatesStatus`. Produce:

- la riga «File da importare: N»;
- la riga «Già presenti sull'SSD, non verranno copiati: M», mostrata **solo se M > 0** — senza, un utente che vede «800 foto sulla scheda» e «File da importare: 12» non ha modo di capire cosa sia successo. Stessa formulazione di `CompletionSheet`, che dice già «Già presenti in libreria, non copiati: N» a fine job;
- la riga di avanzamento «Controllo il contenuto di k file su m…»;
- il **motivo scritto** per cui l'anteprima vera non è disponibile: SSD non configurato, o SSD non collegato. Stessa disciplina di `DuplicatesStatus.trashDisabledReason` e di `RestoreView`: un numero che non c'è dice sempre perché.

**Gate obbligatorio: SSD montato.** Senza il volume, `fileOnDisk` fallisce per ogni candidato dell'indice e l'anteprima dichiarerebbe *tutto* nuovo — cioè ricadrebbe esattamente nel difetto che questa spec chiude, senza dirlo. Il wizard oggi controlla solo `bm.urls[.ssd] == nil` (configurato), che non è la stessa cosa di montato. Serve `VolumeMonitor.ssdMounted`, già disponibile e già usato da `DuplicatesView`.

**Non si blocca invece su `runner.isIndexing`.** Un indice che cresce durante l'anteprima può solo renderla più accurata, e bloccare un import perché una lettura di manutenzione è in corso sarebbe sproporzionato. La contesa sulla coda seriale è misurata sopra ed è nell'ordine dei millisecondi.

### Costo, progresso, interruzione (vincolo 6)

Scheda da 2.000 foto, 7 GiB, media 3,5 MiB. La velocità di lettura **della sorgente** (lettore SD / iPhone via USB) **non è stata misurata**: si assumono 90 MB/s per un lettore UHS-I, con 40 MB/s come caso lento. È l'assunzione principale di questa sezione ed è dichiarata come tale.

| scenario | file da hashare | byte dalla sorgente | byte dall'SSD | tempo stimato |
| :---- | ---: | ---: | ---: | ---: |
| **Scheda nuova** (<1% collisione + 2,7% interni) | ~70 | ~245 MiB | ~140 MiB | **3-7 s** |
| **Reimport della stessa scheda** (100% collisione) | 2.000 | 7 GiB | 7 GiB | **95 s (185 s a 40 MB/s)** |

**Serve progresso, e serve l'interruzione.** Nel caso buono l'anteprima è quasi istantanea; nel caso che a Enrico interessa di più sono uno-tre minuti dentro un wizard, con l'utente che aspetta. La barra è **determinata** (il denominatore è noto in anticipo, punto 3 sopra) e il testo dice quanti file su quanti verranno controllati, così l'utente sa in quale dei due mondi si trova prima di iniziare ad aspettare.

«Interrompi» riporta al passo di scelta della sorgente e **non mostra nessun numero**. Non un numero parziale con un asterisco: la decisione di Enrico è che qualunque numero mostrato sia vero, e un numero parziale non lo è.

### L'anteprima paga la lettura una seconda volta, e non si può evitare

Nel reimport la sorgente viene letta **due volte**: una dall'anteprima, una da `isAlreadyInLibrary` dentro il job. Circa 78 s → 156 s a 90 MB/s.

**Riusare gli hash dell'anteprima dentro l'import è stato valutato e va rifiutato.** Non per purismo: perché non esiste un modo di farlo che non violi ADR-0003.

- Il costo sta interamente nella **rilettura della sorgente**, che è precisamente ciò che ADR-0003 impone di fare prima di saltare un file. Il filtro dimensione, l'unica parte che si potrebbe legittimamente riportare avanti, è già gratis. **Non c'è una via di mezzo da negoziare: o si riusa l'hash per decidere lo skip, o non si risparmia niente.**
- Fra l'anteprima e l'avvio del job passa almeno un passo del wizard (digitare l'etichetta) e può passare un alert di spazio insufficiente: **minuti**. In quella finestra l'utente può cambiare scheda SD. L'app non ha nessun controllo di identità del volume fra i due momenti. Un hash della sorgente vecchio di minuti che autorizza uno skip è una foto persa in silenzio — la classe di bug che `Docs/CONTEXT.md` indica come la più temuta.
- Sarebbe la regola «si rilegge sempre, tranne nel caso X». ADR-0003 dice testualmente perché non si fa: *«"quando si salta un file si rilegge, sempre" è una regola che si ricorda; "si rilegge tranne nel caso X" è una regola che qualcuno un giorno applicherà male»*.

**Il doppio costo è quindi accettato consapevolmente, ed è il prezzo del modello di fiducia a tre livelli.** Se Enrico decide che è troppo, la leva giusta **non** è riusare gli hash: è non fare l'anteprima vera (che è l'opzione già scartata) oppure renderla esplicitamente opzionale — vedi le domande aperte.

### Cosa NON cambia

- **Il controllo di spazio dentro `runImport` resta senza dedup.** Vuole un **limite superiore** — sovrastimare rifiuta un import che sarebbe entrato, sottostimare riempie il disco. Renderlo esatto significherebbe pagare una terza volta l'intera lettura della sorgente per rendere *meno* conservativa una guardia di sicurezza. Il verso sicuro resta quello di oggi.
- **`FileSyncer.sync` e il percorso di copia non vengono toccati.**
- **Lo store non guadagna metodi nuovi** (vedi «Verdetto sulla direzione ipotizzata»).
- **`ImportSessionIndex` non cambia.**

---

## Rischi accettati esplicitamente

1. **La sorgente viene letta due volte in un reimport** (~78 s → ~156 s su una scheda da 7 GiB). È il prezzo di ADR-0003, argomentato sopra. È il costo maggiore di questo lavoro e va messo davanti a Enrico prima dell'approvazione, non dopo.
2. **La velocità di lettura della sorgente non è misurata.** Tutte le stime temporali per scheda SD / iPhone poggiano su 90 MB/s assunti. Da misurare alla prima verifica manuale con una scheda vera, e da riportare in `architecture.md` come fatto misurato.
3. **Il wizard e `runImport` possono dare due cifre di spazio diverse.** Il wizard mostrerà «Spazio necessario: 0 B» dove `runImport` continuerà a controllare contro il limite superiore (7 GiB). Con un SSD quasi pieno l'import verrebbe rifiutato con un messaggio che contraddice quanto appena letto. Mitigazione minima proposta: l'alert di `runImport` dice «Servono **al massimo** circa X». Vedi domande aperte.
4. **L'anteprima e l'import possono divergere sui doppioni interni in un caso.** L'import registra in `ImportSessionIndex` solo i file la cui copia è stata **verificata**; l'anteprima registra tutto ciò che ha hashato. Se la prima copia di un paio fallisse la verifica, l'import copierebbe entrambi e l'anteprima ne avrebbe contato uno. Corner case, verso non-sicuro per il numero (sotto-promessa), impossibile da prevedere in anteprima per costruzione.
5. **Sorgenti con molti non-media restano invarianti.** Una cartella Google Takeout ha 22.381 file `.json` che non partecipano mai al dedup (`IndexableKind`) e vengono ricopiati a ogni reimport. L'affermazione «il 100% di ciò che è annunciato diventa 0 copiati» vale per una scheda di soli media, non per un Takeout. È corretto così, ma il numero mostrato lo rifletterà e non va letto come un difetto.
6. **Un cambio di etichetta dopo l'anteprima può invalidare `toSkip`.** Limite già presente oggi (commento a `pickSource`), invariato: vale solo se l'utente sceglie un'etichetta che corrisponde a una cartella `Import/<slug>` già esistente.
7. **La `View` non è coperta da test**, come già dichiarato per `LibraryIndexCard` e `DuplicatesView`. È testato tutto ciò che sta ai due capi del cablaggio.

---

## Fuori scope

- Rendere dedup-aware il controllo di spazio di `runImport`.
- Riusare gli hash dell'anteprima dentro il job.
- Cambiare il pannello Doppioni, lo scanner o lo schema dell'indice.
- Mostrare in anteprima **quali** file sono già presenti (elenco). Solo conteggi.

---

## Risposte di Enrico (2026-09-01) — spec APPROVATA

Le quattro domande sono chiuse. La spec è **approvata** e si può implementare.

1. **Il doppio costo di lettura è accettabile — a una condizione.** Parole di Enrico: *«accettabile, ma il processo deve essere interrompibile, ci deve essere timer o figura che gira per far capire che sta procedendo»*. Quindi non è un sì generico: l'attesa è ammessa **solo se è visibilmente in corso e si può fermare**. Ne discendono tre requisiti non negoziabili per il Task 4, e sono la parte di questa spec che è più facile implementare a metà:
   - **avanzamento visibile e che si muove**, non uno `ProgressView()` indeterminato piantato lì. I dati per una barra determinata ci sono già — il numero di file e i byte della sorgente si conoscono prima di iniziare;
   - **tempo**: trascorso, oppure stimato rimanente. Il progetto ha già `SyncResult.hms` e la macchina dell'ETA usata dai job, e va riusata, non riscritta;
   - **«Interrompi» sempre premibile**, che ferma davvero la lettura e non solo l'aggiornamento della barra.
2. **L'anteprima parte da sola**, come oggi, alla scelta della sorgente. Nessun bottone in più, nessuna soglia: su un import normale è quasi istantanea (sotto l'1% dei file richiede lettura), e il caso lento è quello del reimport, dove l'attesa è coperta dal requisito 1.
3. **La discrepanza sullo spazio si riformula, non si chiude.** Si adotta la proposta minima: l'alert di `runImport` dice **«Servono al massimo circa X»**. Una terza lettura completa della sorgente per rendere dedup-aware anche il controllo di spazio non è giustificata — quel controllo *vuole* un limite superiore, ed è il verso sicuro.
4. **Interrompere non lascia una schermata vuota, e non torna indietro.** Deciso qui, essendo una conseguenza diretta della risposta 1 e non una scelta di prodotto separata: l'interruzione **degrada al conteggio grezzo con una riga che dice la verità** — che il controllo è stato interrotto, e che alcune di quelle foto potrebbero essere già sull'SSD ed essere saltate. È l'opzione «dirlo a parole» che Enrico aveva scartato come soluzione *generale*, e che qui è esattamente giusta come *stato di ripiego*: chi interrompe ha scelto di non aspettare, e ha diritto di procedere lo stesso con un numero dichiarato approssimato invece che con una schermata vuota o con un passo indietro che gli cancella il lavoro fatto.

---

## Domande aperte per Enrico

1. **Il doppio costo di lettura è accettabile?** Su un reimport di una scheda da 7 GiB si passa da ~78 s a ~156 s complessivi, di cui ~78 s dentro il wizard. L'alternativa che lo eliminerebbe (riusare gli hash dell'anteprima per decidere lo skip) è rifiutata sopra con l'argomento di ADR-0003. Se il costo è troppo, la scelta ricade su una delle opzioni già scartate.
2. **L'anteprima vera deve partire da sola o su richiesta?** Oggi il conteggio parte da solo alla scelta della sorgente. Con questa modifica, su un reimport parte un'attesa di uno-tre minuti che l'utente non ha chiesto. Alternativa: mostrare subito il conteggio grezzo insieme a «Controlla quali sono già sull'SSD» come azione esplicita. Costa un click e toglie l'attesa a sorpresa, ma reintroduce per un istante il numero non-vero che questa spec elimina.
3. **La discrepanza sullo spazio (rischio 3) va chiusa o solo riformulata?** La proposta minima è riformulare l'alert di `runImport` in «al massimo circa X». Chiuderla davvero richiederebbe di rendere dedup-aware anche quel controllo, cioè una terza lettura completa della sorgente.
4. **Interrompere deve riportare alla scelta della sorgente, o restare sul passo di anteprima senza numero?** La spec propone il primo; il secondo è meno brusco ma lascia una schermata vuota di cui spiegare il perché.
