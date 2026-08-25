# Spec — Indice di contenuto della libreria (roadmap #31)

## Problema

L'SSD sta diventando una libreria che aggrega sorgenti eterogenee: Libreria Foto del Mac, estrazioni di Google Takeout, cartelle storiche, e — con roadmap #27 — fotocamere, droni, schede SD, vecchi dischi e telefoni fuori produzione. Formati e generazioni diverse che devono coesistere in un unico sistema.

Da qui due bisogni concreti, entrambi espressi da Enrico:
1. **Non ricreare doppioni durante un import**: reimportare la stessa scheda o la stessa cartella non deve produrre una seconda copia degli stessi file.
2. **Sapere quali doppioni ci sono già oggi** sull'SSD, accumulati negli anni da flussi diversi.

Nessuna delle due è risolvibile con il confronto per nome+dimensione già usato da `FileSyncer`: vecchie fotocamere e telefoni riusano nomi generici (`IMG_0001.jpg`, `DSC0001.JPG`) che collidono tra dispositivi diversi, e lo stesso file può trovarsi sotto percorsi diversi. Serve un confronto per **contenuto**.

Questo punto nasce durante il brainstorming di #27 (sotto-progetto A): il wizard di import aveva bisogno del dedup, ma il dedup è una capacità di sistema che serve a più funzioni. È stato quindi separato come punto di roadmap a sé, che #27-A **consuma** invece di contenere.

## Decisioni prese in brainstorming (2026-08-25, one-question-at-a-time)

- **Definizione di doppione: solo byte-identico**, via SHA256. Scartato esplicitamente il matching fuzzy/percettivo (hash percettivo, EXIF+timestamp). Motivo: un falso positivo su un match fuzzy significherebbe **non importare una foto diversa credendola doppione** — l'unico vettore realistico di perdita di uno scatto in un progetto la cui regola assoluta è non perdere nulla. Con SHA256 byte-identico quel rischio è azzerato. Conseguenza accettata: le foto ricodificate da Takeout, le coppie HEIC/JPG e le versioni ridimensionate **restano duplicate** e non vengono riconosciute.
- **Cosa si indicizza: solo l'SSD.** HDD e Cubbit ne sono mirror, indicizzarli sarebbe ridondante e per S3 richiederebbe download o fiducia negli ETag remoti.
- **Classificazione automatica, non lista di esclusioni scritta a mano.** Richiesta esplicita di Enrico: "vorrei che l'indicizzazione capisse in automatico cosa può indicizzare o meno". Si indicizza ciò che è conforme a `UTType` `.image` o `.movie`; tutto il resto è ignorato. La cartella "Zip" esce dall'indice **da sé** perché gli archivi non sono foto, non perché si chiama così — e la stessa regola reggerà per le sorgenti future senza modifiche al codice.
- **Foto e video insieme.** Droni e fotocamere producono MP4/MOV e le Live Photo sono coppie HEIC+MOV: escludere i video lascerebbe metà di uno scatto fuori dall'indice, e i video sono i file dove un doppione pesa di più.
- **L'indice serve a due cose**: dedup durante l'import, e un nuovo pannello **Doppioni** che elenca i gruppi di file identici già presenti. Il pannello è di **sola segnalazione**: nessuna cancellazione, nemmeno dietro conferma — scartata esplicitamente in brainstorming come incompatibile con la regola zero-delete senza un go/no-go dedicato.
- **Costruzione iniziale esplicita, aggiornamenti automatici.** La prima costruzione (lunga, legge tutti i file) parte solo su richiesta dell'utente, con stima mostrata prima, progresso e interruzione. Gli aggiornamenti incrementali sono automatici — all'avvio con SSD collegato e dopo ogni import — con toggle in Impostazioni, default acceso, stesso idioma del backup automatico al collegamento SSD.

## Ricerca preliminare

### Misure empiriche su ExFAT (2026-08-25, immagine disco temporanea, SSD reale non collegato)

Il filesystem dell'SSD è ExFAT, che ha limiti reali su timestamp e nomi. Verificato direttamente su un'immagine ExFAT da 64MB creata, montata, testata e cancellata — mai toccato il volume reale:

| Misura | Risultato |
| :---- | :---- |
| Granularità `st_mtime` | **10 millisecondi** (impostato `…001.756` → riletto `…001.75`; anche una scrittura normale produce frazioni a passi di 10ms) |
| Arrotondamento a 2 secondi (stile FAT32) | **Assente** — i secondi dispari si conservano |
| Caratteri `? * \| " < > \ :` nei nomi | **Accettati** da macOS, creati e riletti identici |
| Copia APFS → ExFAT | mtime **troncato a 10ms** (`…001.123456` → `…001.120000`) |
| Inode attraverso un rename | Stabile nel test (33 → 33) — **ma vedi sotto, non ci si fa affidamento** |

Due di queste misure risolvono questioni che la letteratura lasciava aperte o su cui è in conflitto:

- **Granularità**: nessuna fonte documenta cosa il driver ExFAT di macOS esponga via `stat()`; la spec ExFAT prevede 2 secondi di base più campi `10msIncrement` per Create e LastModified. La misura dice che macOS espone i 10ms. La finestra "racy" reale è quindi molto più stretta dei 2 secondi teorici.
- **Caratteri**: la spec Microsoft vieta `/ \ : * ? " < > |` e U+0000–U+001F, ma **l'implementazione macOS è più permissiva** e li accetta. Vale la misura per il comportamento reale su questo Mac; vale la spec per la portabilità — un SSD scritto qui con quei nomi darebbe problemi collegato a Windows.
- **Inode**: qui la misura **non** vince sulla letteratura. Un ingegnere Apple DTS documenta che i filesystem senza eredità Unix devono sintetizzare `st_ino` e che il processo "non funziona del tutto"; un caso riportato mostra più file appena creati con `st_ino = 1` su ExFAT/macOS; nella famiglia FAT l'inode è tipicamente derivato dalla posizione della directory entry, quindi un rename può cambiarlo. Un singolo rename su un'immagine da 64MB non basta a ribaltare queste fonti: **l'inode non viene usato**, né come identità del file né come rinforzo della chiave di invalidazione.

### Letteratura e prior art (Researcher agent, 2026-08-25)

- **Pipeline a stadi crescenti di costo**: `rmlint`, `jdupes`/`fdupes`, `rdfind` convergono tutti sullo stesso schema — dimensione prima, poi hash parziale, poi hash completo, eventualmente confronto byte-a-byte. È la convergenza più forte emersa dalla ricerca. Nota controintuitiva di `rdfind`: il filtro sui **primi** byte è poco discriminante perché i file dello stesso tipo condividono i preamboli — e una libreria fotografica (header JPEG/HEIC/MP4 + blocchi EXIF) è il caso peggiore possibile per quel filtro.
- **`(percorso, dimensione, mtime)` non è una garanzia, e su questo le fonti sono concordi.** `mtime` è scrivibile da userspace: `borg` usa `ctime` di default proprio perché "non può essere impostato da userspace", `restic` pretende mtime **e** ctime, `rsync` accetta size+mtime ma offre `--checksum` proprio perché non basta. `rmlint`, che è il caso più vicino a questo design (cache di hash invalidata su mtime), avverte esplicitamente del rischio di falsi positivi "se il contenuto viene modificato senza cambiare la data". Nel dominio di questo progetto i tool che riscrivono mtime esistono davvero: `exiftool` dopo l'editing dei metadati, `rsync -t`, restore da Time Machine/Finder.
- **Il rinforzo usato da restic e borg non è disponibile qui**: entrambi si appoggiano a inode e ctime, ed entrambi documentano che quel rinforzo salta sui filesystem che non assegnano inode stabili. Su ExFAT/macOS è esattamente il caso. **La chiave di invalidazione di questo progetto è quindi strutturalmente più debole di quella di restic/borg**, non equivalente — ed è la ragione per cui il modello di fiducia sotto è necessario e non opzionale.
- **Il problema "racy"** è documentato in modo esemplare da `git`: se un file cambia due volte così in fretta che mtime non cambia, e la dimensione resta identica, la cache resta ingannevolmente valida. Difesa di git: se l'mtime del file è uguale o più recente del timestamp dell'indice stesso, **confronta comunque i contenuti**. `borg` fa l'equivalente escludendo dalla cache i file con timestamp uguale al più recente dell'archivio.
- **Fuso orario e ora legale su ExFAT**: ExFAT memorizza i timestamp in **ora locale** più campi `UtcOffset`. Uno studio forense DFRWS 2022 che ha testato Windows, Linux e macOS ha trovato divergenze sostanziali fra implementazioni, incluse anomalie di inversione di segno dell'offset proprio su macOS; un'altra analisi conclude che fra le implementazioni testate "ci sono più anomalie che coerenze". Conseguenza pratica documentata altrove (FreeFileSync ha una pagina di manuale dedicata, Syncthing un'issue aperta): dopo un cambio DST gli mtime possono apparire shiftati di un'ora. Non è perdita di dati, ma invaliderebbe in blocco la cache e forzerebbe il re-hash di tutta la libreria.
- **Normalizzazione Unicode e case**: ExFAT è case-insensitive/case-preserving e non normalizza i nomi (li memorizza in UTF-16 così come arrivano); APFS **preserva** la normalizzazione originale invece di imporne una. Conseguenza: lo stesso file può presentarsi con due stringhe di percorso diverse (NFC vs NFD, maiuscole/minuscole), e senza normalizzazione della chiave si otterrebbero due entry distinte per lo stesso file.
- **Collisioni SHA256: non meritano una riga di codice difensivo.** NIST attribuisce a SHA256 128 bit di resistenza alle collisioni; con 120.000 file la probabilità per birthday bound è nell'ordine di 10⁻⁶⁷. Aggiungere un confronto byte-a-byte "per sicurezza" alla maniera di `fdupes` significherebbe spendere I/O costoso contro un rischio di 10⁻⁶⁷ mentre i rischi reali sono altrove (vedi sotto).
- **Formato di archiviazione**: per ~120k record aggiornati in modo incrementale, la documentazione SQLite presenta esattamente questo come il proprio caso d'uso canonico ("media cataloging"), e il ragionamento regge indipendentemente: con un JSON monolitico ogni aggiornamento costa O(n) — deserializzare, mutare, riserializzare e riscrivere ~25-30MB anche per un solo record — contro O(log n) di SQLite. Non esiste una soglia documentata "oltre N record il JSON non va più bene": il criterio vero è la **frequenza degli aggiornamenti**, non il conteggio. Asimmetria più importante della performance: un JSON troncato è **completamente illeggibile**, mentre una corruzione SQLite tipicamente compromette alcune pagine e lascia il resto recuperabile.

## Design tecnico

### Cosa entra nell'indice

Attraversamento dell'SSD dalla root del bookmark `.ssd` già esistente in `BookmarkManager` (nessun nuovo bookmark). Un file entra nell'indice se e solo se:
- il suo `UTType` è conforme a `.image` **oppure** a `.movie`, e
- non è escluso dalle regole già in vigore in `FileSyncer` (`.DS_Store`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `lost+found`, `Backups.backupdb`, `._*`).

Nessuna lista di cartelle da escludere. "Zip", i sidecar (`.xmp`, `.aae`, i `.json` di Takeout) e qualunque file non-immagine/non-video restano fuori per conseguenza della regola, non per caso speciale.

`FileKind.isImage(url:)` esiste già (scritto per le miniature, #17) e usa esattamente questo meccanismo — `UTType(filenameExtension:)` più `conforms(to: .image)`. Va quindi **esteso o affiancato**, non duplicato: serve una classificazione a tre vie (immagine / video / non indicizzabile). `UniformTypeIdentifiers` è già importato in `ContentView.swift`, quindi nessuna nuova dipendenza.

**Limite noto di questo meccanismo**: `UTType(filenameExtension:)` classifica per **estensione**, non ispezionando il contenuto. Un file con estensione errata o assente viene classificato male — un RAW di un modello esotico non riconosciuto da macOS resterebbe fuori dall'indice. Accettato: sbagliare per esclusione è il verso sicuro (il file semplicemente non partecipa al dedup e viene copiato, mai saltato per errore). Da verificare al primo run reale se qualche formato presente nella libreria di Enrico non venga riconosciuto.

### Record dell'indice

Per ogni file indicizzato:

| Campo | Note |
| :---- | :---- |
| percorso relativo alla root SSD | chiave — **normalizzata**: `precomposedStringWithCanonicalMapping` (NFC) e case-folding, per le ragioni Unicode/case-insensitivity sopra |
| dimensione in byte | dal filesystem |
| mtime | **letto dall'SSD**, mai quello della sorgente originale: la copia APFS→ExFAT tronca a 10ms (misurato), quindi l'mtime dell'origine non coincide mai con quello di destinazione |
| SHA256 | esadecimale |
| istante di calcolo dell'hash | necessario per la regola anti-racy (vedi sotto) |
| versione dello schema | a livello di indice, non di record: un indice di versione sconosciuta significa "ricostruisci", mai "interpreta male" |

### Modello di fiducia sull'mtime — il cuore della spec

La ricerca è netta: `(percorso, dimensione, mtime)` non è una garanzia, e qui è più debole che in restic/borg perché inode e ctime non sono utilizzabili su ExFAT. Il punto decisivo è che **il costo di un errore non è lo stesso nei due usi dell'indice**:

- **Segnalazione nel pannello Doppioni** — un hash stantio produce una riga sbagliata in un elenco. L'utente guarda e ignora. Danno: basso.
- **Skip durante l'import** — un hash stantio può far saltare un file che in realtà è diverso: **una foto non importata, in silenzio**. È l'unico vettore realistico di perdita di uno scatto in tutto il progetto, nonostante la regola zero-delete.

Da qui, **due livelli di fiducia sullo stesso indice**:

1. **Percorso a basso danno (pannello Doppioni)**: ci si fida della cache. Nessuna rilettura.
2. **Percorso ad alto danno (skip in import)**: **non ci si fida della cache**. Quando l'indice indica che un file in arrivo è già presente, il file candidato sull'SSD viene **riletto e rihashato** prima di decidere lo skip. Costa la lettura di un solo file per ogni candidato duplicato — trascurabile, perché i candidati sono pochi, e il file sorgente va comunque letto per calcolarne l'hash.

A questo si aggiungono tre difese, tutte con precedente documentato:

- **Regola anti-racy (da `git`/`borg`)**: una entry il cui mtime è ≥ (istante di calcolo dell'hash − margine) è trattata come sospetta e riverificata. Margine: **2 secondi**, non 10ms — la granularità misurata su questo Mac è 10ms, ma la spec ExFAT prevede 2 secondi e un'altra implementazione potrebbe esporli. Il margine più prudente costa pochissimo.
- **Tolleranza DST/fuso orario**: se percorso e dimensione coincidono ma la differenza di mtime è **esattamente** 3600s o 1800s, non invalidare in blocco: trattare come probabile shift di fuso orario e riverificare, invece di far ripartire un re-hash dell'intera libreria. Questa **non è prior art** — la ricerca non ha trovato nessuno strumento che lo faccia per un indice di hash; è una scelta di questo progetto, e va marcata come tale nel codice.
- **Modalità "verifica completa / ignora mtime"**: disponibile su richiesta dell'utente. Tutti e quattro i tool esaminati dalla ricerca ne offrono una — è un segnale forte che serva.

### Confronto: dimensione prima, hash poi

Coerente con la convergenza di `rmlint`/`jdupes`/`rdfind`: un file in arrivo la cui dimensione non compare in nessuna entry dell'indice **non viene nemmeno hashato**, si copia e basta. L'hash del file sorgente si calcola solo quando esiste almeno un candidato di pari dimensione.

Deliberatamente **non** si implementa l'hash parziale sui primi N byte: la ricerca documenta che è il filtro peggiore proprio su una libreria fotografica (header e blocchi EXIF condivisi tra file dello stesso tipo), e aggiungerebbe un secondo valore da mantenere coerente nell'indice in cambio di un guadagno dubbio.

**Nota di aspettativa da non travisare**: il dedup fa risparmiare **spazio**, non tempo. Il file sorgente va comunque letto per intero per hasharlo, quindi un import con molti doppioni non è più veloce di uno senza — è solo meno ingombrante.

### Dove vive l'indice

`~/Library/Application Support/AppBackupFoto/`, sul disco interno del Mac — **mai sull'SSD**. Tre ragioni convergenti: coerenza col precedente già stabilito per Immich (#29); l'indice resta consultabile a SSD scollegato; e sul volume delle foto non si scrive nulla. (Nota: l'approccio di `rmlint`, che salva gli hash negli extended attributes dei file stessi, sarebbe comunque impraticabile qui — ExFAT non ha xattr nativi e macOS li emula con file `._*`.)

**Formato: SQLite** (presente di sistema su macOS, nessuna nuova dipendenza), per le ragioni della ricerca: aggiornamento incrementale O(log n) invece di riscrivere 25-30MB a ogni modifica, e degradazione parziale invece di perdita totale in caso di corruzione.

**Sul rischio di durabilità**: su macOS `fsync()` non garantisce la persistenza fisica (serve `F_FULLFSYNC`), e un'analisi di terze parti basata su tracing dei syscall riporta che la SQLite di sistema sostituisce `F_FULLFSYNC` con `F_BARRIERFSYNC`, che ritorna prima della sincronizzazione effettiva. **Rischio accettato consapevolmente**: la conseguenza peggiore è perdere l'ultima transazione in caso di kernel panic o power loss. L'indice è una **cache, non una fonte di verità** — nulla al suo interno è dato originale, ed è sempre ricostruibile da zero. Da qui la regola di prodotto: non promettere mai all'utente che l'indice è indistruttibile, e tenere sempre disponibile un percorso di ricostruzione completa.

### Ciclo di vita

- **Prima costruzione**: esplicita, da un bottone. Mostra una stima prima di partire, una barra di progresso durante, ed è interrompibile. **L'indice deve essere valido e utile in ogni istante**, non solo a fine scansione: commit periodici a batch (non uno per file, non uno solo alla fine), così un'interruzione lascia un indice parziale ma corretto. Va distinto esplicitamente lo stato "file non ancora indicizzato" da "file assente" — hanno conseguenze diverse sull'import.
- **Aggiornamento incrementale**: automatico all'avvio con SSD collegato e dopo ogni import; toggle in Impostazioni, default acceso. Rihasha solo ciò che è nuovo o la cui terna (percorso, dimensione, mtime) è cambiata.
- **Ricostruzione completa**: sempre disponibile su richiesta.

**Un file rinominato o spostato appare come nuovo** e viene rihashato — conseguenza diretta dell'assenza di inode stabili su ExFAT, non un difetto correggibile. Se una riorganizzazione massiccia della libreria dovesse renderlo pesante, un indice secondario su `(dimensione, hash)` permetterebbe almeno di riconoscere "già visto altrove" senza segnalarlo come nuovo duplicato — ma richiederebbe comunque di leggere il file per hasharlo, quindi non evita l'I/O. Fuori scope per ora.

### Sicurezza della scansione

- **Hashing**: riuso di `sha256(of:)` esistente, che usa I/O POSIX a basso livello. Mai `FileHandle` — è il bug di memoria da 41GB già pagato una volta su questo progetto.
- **Lettura troncata**: verificare che il numero di byte letti coincida con la dimensione con cui il file è stato indicizzato. Una discrepanza significa **non indicizzare**, mai "indicizza quello che ho": un hash calcolato su una lettura parziale verrebbe poi usato per saltare un file in import, ed è un fallimento silenzioso.
- **Scollegamento a metà scansione**: intercettare `NSWorkspace.willUnmountNotification`/`didUnmountNotification` e fermare la scansione, invece di produrre errori per 100.000 file. ExFAT non è journaled, quindi un'espulsione sporca può danneggiare il volume stesso — motivo in più per fermarsi in modo pulito.
- **Nessuna scrittura sull'SSD, nessuna cancellazione**: l'intera feature è in sola lettura sul volume delle foto.

### I due consumatori

**1. Dedup in import (#27-A).** `runImport` consulta l'indice attraverso un'interfaccia stretta. I file già presenti con contenuto identico vengono saltati e conteggiati, e il conteggio compare nel riepilogo di fine job come riga condizionale, stesso stile della riga "file cambiati non copiati" già esistente (#13). Rientra qui anche il **suffisso progressivo automatico** sull'etichetta di destinazione, deciso in brainstorming: se `<SSD>/Import/<etichetta>` esiste già, l'app propone `<etichetta> (2)`, mostrato e modificabile nel wizard prima di avviare.

**2. Pannello Doppioni.** Nuova vista che elenca i gruppi di file identici già presenti: quanti gruppi, quanto spazio occupano, dove stanno i file di ciascun gruppo. **Sola lettura, nessuna azione distruttiva.** Se diventa una nuova `Window` scene di primo livello va gated con `AuthGateManager` come tutte le altre (regola stabilita in #30 e già applicata a Diagnostica/Catalogo/Foto).

## Fuori scope (deciso esplicitamente)

- Matching fuzzy/percettivo — deciso in brainstorming, con la motivazione di rischio sopra.
- **Cancellazione dei doppioni**, anche dietro conferma: sarebbe la prima operazione di cancellazione su file foto nella storia del progetto e richiede un go/no-go dedicato, non è un dettaglio di questa spec.
- Indicizzazione di HDD e Cubbit.
- Indicizzazione dei contenuti **dentro** gli archivi.
- Hash parziale sui primi N byte — valutato e scartato con motivazione.
- Uso dell'inode come identità del file — valutato e scartato con motivazione.
- Riconoscimento di file spostati/rinominati senza re-hash.

## Rischi noti, accettati esplicitamente

- **La chiave di invalidazione è più debole che in restic/borg**, perché ExFAT non offre inode stabili né ctime affidabile. Mitigato dal modello di fiducia a due livelli, non eliminato.
- **Durabilità SQLite su macOS**: si può perdere l'ultima transazione in caso di power loss. Accettato perché l'indice è ricostruibile.
- **Costo della prima costruzione**: legge per intero ogni foto e video dell'SSD. Stima nell'ordine dei 5-15 minuti per ~200GB su SSD esterno, **non misurata** — l'SSD non era collegato al momento della scrittura di questa spec. Il numero reale si saprà al primo run e va corretto qui.
- **Ora legale**: la tolleranza sui delta di 3600s/1800s è una mitigazione progettata qui, senza prior art. Se si rivelasse insufficiente, la conseguenza è un re-hash completo — costoso ma non distruttivo.
- **I doppioni non byte-identici restano invisibili**: Takeout ricodificato, HEIC vs JPG, versioni ridimensionate. Conseguenza diretta e accettata della scelta byte-identica.

## Da definire in fase di piano

- Schema SQLite preciso e indici (almeno su hash e su dimensione).
- Se estendere `FileKind` o affiancargli un tipo nuovo per la classificazione a tre vie.
- Dimensione del batch di commit durante la scansione.
- Se il pannello Doppioni sia una `Window` scene indipendente o un pannello dentro Diagnostica.
- Sequenza di rilascio: l'indice più il dedup in import sono il nucleo; il pannello Doppioni può essere un incremento successivo.

## Prossimo passo

Spec da approvare esplicitamente da Enrico prima del piano di implementazione. Alla sua approvazione, #27-A riprende dal Task 3 (`ImportView`), che consumerà l'indice.

---

## Nota post-implementazione (2026-08-25, Task 1) — copertura reale di `UTType`

La spec lasciava aperto: *"Da verificare al primo run reale se qualche formato presente nella libreria di Enrico non venga riconosciuto"*. Verificato subito dopo il Task 1, eseguendo la stessa logica di `IndexableKind.of` su questo Mac (macOS 26). **SSD non collegato**, quindi questa è la copertura dei formati, non un censimento di ciò che c'è davvero sull'SSD: quello resta da fare al primo run.

**Riconosciuti correttamente**: tutti i formati foto comuni (jpg, jpeg, heic, heif, png, gif, tiff, tif, bmp, webp, **avif**, **jxl**) e **14 RAW su 15** (cr2, cr3, nef, nrw, arw, srf, raf, orf, rw2, dng, pef, srw, 3fr, iiq). Video: mov, mp4, m4v, avi, mts, m2ts, 3gp. I sidecar e gli archivi restano fuori come previsto (xmp, aae, json, zip, thm, srt).

**Non riconosciuti** — restano fuori dall'indice, quindi fuori dal dedup:

| Estensione | Cos'è | Impatto |
| :---- | :---- | :---- |
| `.mkv` | Matroska | **Il più rilevante**: container video diffuso, non prodotto da fotocamere ma possibile da altre sorgenti |
| `.x3f` | RAW Sigma Foveon | Trascurabile senza una Sigma |
| `.hevc` | stream HEVC grezzo | Raro come estensione di file |
| `.insv` | video Insta360 | Rilevante solo con una camera 360 |
| `.lrv` | proxy a bassa risoluzione GoPro/DJI | **Escluderli va bene**: sono file usa-e-getta |

**Nessuna azione richiesta ora.** Vale il principio già stabilito: sbagliare per esclusione è il verso sicuro — un file non classificato non partecipa al dedup e **viene copiato, mai saltato**. Se al primo run reale l'SSD contiene `.mkv` in quantità, la correzione è una riga (un insieme di estensioni aggiuntive in `IndexableKind`), non un cambio di design.

**Da fare al primo run con SSD collegato**: censire le estensioni realmente presenti (`find <SSD> -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn`) e confrontarle con questa tabella.
