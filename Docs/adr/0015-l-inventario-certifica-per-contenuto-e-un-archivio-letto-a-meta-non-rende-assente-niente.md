# ADR-0015 — L'inventario certifica per contenuto, e un archivio letto a metà non rende assente niente

**Data:** 2026-09-26
**Stato:** Accettata

## Contesto

Enrico vuole arrivare a una copia sola di ogni foto per archivio (SSD, HDD, Cubbit), mettere al sicuro le foto che stanno in un posto solo e togliere le ridondanze anche da HDD e Cubbit. È stato diviso in quattro progetti; il primo è l'inventario, in sola lettura, su cui gli altri tre decideranno copie e cancellazioni (spec `Docs/superpowers/specs/2026-09-26-cross-store-inventory-design.md`).

Fatti misurati il 2026-09-26: su 219.877 oggetti Cubbit (529,9 GB), 219.629 hanno un ETag uguale all'MD5 del contenuto; i restanti 248 (tutti ≥ 64 MB) sono stati caricati a pezzi da 64 MiB e il loro ETag (`md5(md5(parte1)‖…‖md5(parteN))-N`) si ricalcola dal file sull'SSD (`ASUS/Elba/FILE0056.MOV` → `fc22b3a263f8c63ba9d9f8fbd7a0b713-4` da entrambe le parti). Il bucket non ha versioni.

## Opzioni valutate

- **A. Confronto per percorso e dimensione** (come `rclone check --size-only`). Scartata: non dice niente del contenuto.
- **B. Scaricare da Cubbit e rihashare.** Scartata: ~530 GB di download a ogni giro.
- **C. Confronto per contenuto con l'ETag, senza scaricare (scelta).** Una lettura per file locale produce SHA256, MD5 ed ETag a pezzi da 64 MiB (`ContentHasher`); un oggetto Cubbit è *certificato* solo se il suo ETag coincide con quello di un file letto della stessa dimensione.
- **D. Un secondo database.** Scartata da Enrico (decisione 4): si estende lo stesso SQLite dell'elenco.

## Decisione e motivo

**Cosa l'inventario certifica:** che un contenuto (SHA256) è presente su SSD e/o HDD perché letto per intero nell'ultimo giro; che un oggetto Cubbit contiene quello stesso contenuto, se il suo ETag (parte unica, `-1`, o `-N` con parti da 64 MiB) coincide con quello di un file locale della stessa dimensione; che un oggetto Cubbit a parte unica senza file locale corrispondente è un contenuto presente **solo** su Cubbit, riconosciuto dal suo MD5.

**Cosa non certifica:** un oggetto `-N` caricato con parti di altra dimensione, o con un ETag in un formato non riconosciuto, è *non certificabile* — mai «certificato» per ipotesi — e finisce in ❗ insieme alla foto che sta allo stesso percorso sugli altri archivi. L'inventario è una cache (ADR-0002): prima di ogni copia o cancellazione dei progetti 2-4 il file va riletto dal disco (ADR-0005).

**Incompleto ≠ assente.** Un archivio è *completo* solo se l'ultima lettura è arrivata in fondo senza problemi: nessun file o cartella illeggibile, disco mai sparito, nessuna interruzione, lista di Cubbit finita davvero. «Manca da X» si dice solo se X è completo. «Presente» vuol dire «visto nell'ultimo giro». Un contenuto che mancherebbe solo da archivi incompleti non entra in ⚠️ né in 🔎: resta in «⏳ Non si può ancora dire». Un disco scollegato non è mai un disco vuoto.

**Precedenza:** ❗ > 🔎 > ⚠️ > ✅, residuo ⏳.

**Scelte d'implementazione, con il perché:**
- `InventoryScanner` è nuovo e non `LibraryIndexer` riusato: stessa traversata con le stesse funzioni condivise, e un test di parità che fallisce se i due vedono file diversi. Generalizzare `LibraryIndexer` avrebbe toccato il componente più protetto del progetto.
- La lettura è `ContentHasher.digestFile` (POSIX, buffer da 1 MiB, `fstat` prima/dopo), non `S3Syncer.readFileInChunks`, che è isolato al main e copia ogni parte in un `Data` da 64 MiB.
- Schema 2: dalla versione 1 si sale tenendo l'elenco (schema noto); ogni altra versione ricostruisce tutto.
- La lista di Cubbit per l'inventario si legge blocco `<Contents>` per blocco: accoppiare chiavi ed ETag per posizione metterebbe l'ETag di un oggetto su un altro.

**Cosa si accetta di perdere:** il primo giro rilegge per intero SSD e HDD (misurato ~300 MiB/s di calcolo: decine di minuti per disco); un solo file illeggibile sospende le mancanze da tutto il suo archivio; «Svuota l'elenco» svuota anche l'inventario; oggetti Cubbit caricati da altri strumenti con parti diverse restano ❗ finché non si scaricano (fuori da questo progetto).

**Per riaprirla** serve un argomento nuovo: per esempio un bucket con versioni o checksum SHA256 lato server (che renderebbe superfluo l'ETag), o una misura che mostri molti oggetti non certificabili.

## Risposte di Enrico (S1-S11, D1-D3)

Approvato integralmente il 2026-09-28 (vedi intestazione del piano `Docs/superpowers/plans/2026-09-26-cross-store-inventory.md`).

- **S1-S11**: tutti gli scostamenti approvati nella colonna «Proposta» del piano (nessuna alternativa scelta).
- **D1** — Granularità dell'«incompleto»: **per archivio intero** (raccomandazione accolta).
- **D2** — Ordine delle letture: **in sequenza SSD → HDD → Cubbit** (raccomandazione accolta).
- **D3** — La finestra mostra al **massimo 300 voci per categoria**, con «Qui ne vedi 300 su N».
- **S8** (ribadito esplicitamente): «Svuota l'elenco» svuota anche l'inventario, e il testo di conferma in Diagnostica lo dice.

## Aggiornamento del 2026-09-30: le forme dell'ETag trovate sul bucket reale

Il primo inventario completo (SSD, HDD, Cubbit, 0 file illeggibili) ha messo 496 contenuti in ❗, per 79,6 GB: 318 oggetti caricati a pezzi il cui ETag non coincideva con quello a pezzi da 64 MiB. Verificato ricalcolandoli dai file sull'SSD (in sola lettura):

- **205 oggetti `-1`** hanno l'ETag scritto con la formula «in testo»: `md5` dei 32 caratteri esadecimali dell'MD5, non dei 16 byte. Tutti e 205 coincidono.
- **Gli oggetti `-N` con N che non torna con 64 MiB** sono stati caricati a pezzi da **128 MiB** (da un vecchio programma di caricamento), a volte con la formula standard, a volte con quella «in testo». 6 su 6 verificati.

Quindi l'inventario riconosce anche queste forme: `ContentHasher` calcola, nella stessa lettura, l'ETag a pezzi da 64 MiB con le due formule e quello a pezzi da 128 MiB con le due formule (`ContentDigest.alternativeMultipartETags`); il confronto con un `-1` prova anche la formula «in testo». Nessuna richiesta nuova a Cubbit, nessun download. Le forme in piu' si salvano nella stessa colonna `etag`, separate da uno spazio (nessun cambio di schema); un'impronta salvata prima, di un file sopra i 64 MiB, si rilegge al giro dopo (`needsAlternativeETags`).

Resta vero il principio: un oggetto che non coincide con nessuna di queste forme resta **non certificabile**, mai «certificato» per ipotesi.
