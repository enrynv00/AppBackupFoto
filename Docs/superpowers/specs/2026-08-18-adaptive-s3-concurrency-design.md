# Concorrenza adattiva per upload SSD→S3 (2026-08-18)

## Problema

Upload SSD→Cubbit S3 osservato a 4,31 MB/s durante un job reale, contro ~33 MB/s (267 Mbps) di banda reale misurata con Speedtest sulla stessa connessione — gap 8×. Non è un problema di banda/WiFi: è un problema di concorrenza.

Diagnosi (confermata rileggendo il codice attuale in questa sessione, `ContentView.swift`):

- **Upload paralleli oggi**: `S3Syncer.sync()` carica al massimo **4 file diversi in parallelo** (`runBounded`, `maxConcurrent: 4`, introdotto in roadmap #6, 2026-08-02).
- **Parti di un multipart oggi**: per i file ≥64MB, `S3Syncer.multipart()` (righe ~2238-2308) carica le parti (chunk da 64MB) **una alla volta in sequenza** — ogni `PUT` di parte aspetta il completamento della precedente prima che `readFileInChunks` legga/invii la successiva. Questa scelta era esplicita: la roadmap #6 assumeva "il collo di bottiglia è la banda, non la latenza per richiesta" per i pochi file enormi, un'assunzione che su una connessione da 33 MB/s lascia inutilizzata la maggior parte della banda quando il job sta caricando un file enorme (es. gli zip da 40-50GB nella cartella "Zip" dell'SSD).
- Nel job osservato, 68.890/68.935 file erano già presenti (solo skip): l'upload reale riguardava pochissimi file, quasi certamente un solo video/zip grande caricato in sequenza di parti — nessun beneficio dal parallelismo a 4 file già esistente.

## Obiettivo

Un solo meccanismo di concorrenza adattiva, condiviso sia dai file interi (upload singolo, <64MB) sia dalle parti di un multipart (≥64MB), che sfrutti la connettività reale disponibile senza un tetto fisso scelto a priori — decisione esplicita di Enrico (2026-08-18): niente numero magico, "sfruttare tutta la connettività che ha, no limiti", con un tetto pratico che emerge solo da segnali reali (errori di rete/rate-limit) o da un rischio di memoria, non da una costante scelta a tavolino.

## Non-obiettivi

- Nessuna nuova impostazione utente: nessun toggle/numero configurabile in Impostazioni. Coerente con come sono già gestite oggi le altre costanti di questo file (`maxConcurrent: 4` attuale, chunk da 64MB, 3 tentativi di retry) — tutte hardcoded, mai esposte in UI.
- `FileSyncer` (Mac→SSD, SSD→HDD) resta invariato: sono copie su filesystem locale, non upload di rete, il problema non li riguarda.
- Nessuna modifica alla logica zero-overwrite (`shouldUpload`/`isChangedExistingKey`): questo intervento cambia solo *come* vengono eseguiti gli upload già decisi, non quali file vengono caricati.
- Nessun throttling di banda lato app (nessun limite byte/secondo artificiale) — solo il numero di richieste di rete contemporanee.

## Design

### Componente nuovo: un gate di ammissione a capacità variabile

Un nuovo tipo (`actor`, per sicurezza di accesso concorrente senza lock manuali) sostituisce sia `runBounded` a 4 file fissi sia il loop sequenziale delle parti multipart. Espone due operazioni:

- `acquire()` — attende finché non c'è uno "slot" libero, poi lo occupa. Ogni unità di lavoro di rete (un file intero <64MB, oppure una singola parte ≥64MB) deve acquisire uno slot **prima** di essere letta da disco e inviata.
- `release(outcome:)` — libera lo slot al termine dell'unità di lavoro (successo, fallimento transitorio, o fallimento permanente) e aggiorna il numero di slot concessi in base all'esito:
  - **successo**: dopo N successi consecutivi senza fallimenti nel mezzo, il limite corrente sale (+2, fino al tetto — vedi sotto). Proposta di default: N=5.
  - **fallimento transitorio** (errore di rete ritentabile: timeout, HTTP 5xx, HTTP 429 — vedi nota sotto) — il limite corrente si dimezza immediatamente (minimo 1), il contatore di successi consecutivi si azzera. Nessuna attesa: la riduzione è istantanea al primo segnale di sovraccarico.
  - **fallimento permanente** (HTTP 4xx diverso da 429 — es. credenziali/permessi) — nessun effetto sul limite: non è un segnale di congestione, è un problema di dati/configurazione che il retry non risolverebbe comunque.

Il limite parte da **4** (stesso valore già in produzione oggi, punto di partenza noto e testato) e può salire finché non incontra un tetto pratico.

### Il tetto pratico: dalla memoria, non da un numero scelto a priori

Ogni unità di lavoro (file <64MB, o parte da 64MB) tiene in RAM il proprio corpo HTTP finché l'upload non completa — stessa dinamica già affrontata nel bug critico di memoria di questo progetto (`sha256(of:)`, 2026-07-30: 41GB di picco su un file da 50GB letto senza rilascio). Qui il rischio è diverso (upload paralleli, non un singolo file enorme in RAM) ma la stessa cautela si applica: più slot concorrenti si aprono, più chunk da 64MB restano in RAM contemporaneamente in attesa di risposta dal server.

Per questo il tetto pratico è **derivato dalla memoria**, non un numero di connessioni scelto a piacere: `ceiling = memoryCeilingBytes / chunkSize`. Proposta di default: `memoryCeilingBytes = 2GB` → `ceiling = 32` slot (2GB / 64MB). È una costante facilmente regolabile in futuro senza toccare il resto del design; 32 slot paralleli su una connessione da ~33MB/s sono già abbondanti per nascondere la latenza per richiesta (il vero limite osservato oggi, non la banda) — 2GB è una frazione piccola della RAM di un Mac moderno, lontanissima dai 41GB dell'incidente storico.

**Perché non serve un tracciamento separato dei byte in volo**: poiché ogni unità di lavoro ha corpo ≤64MB (i file ≥64MB vanno sempre in multipart), un limite basato sul *conteggio* di slot, moltiplicato per la dimensione massima di un'unità, è già equivalente a un limite sui byte in volo — nessuna contabilità aggiuntiva necessaria.

### Perché il throttling di lettura da disco è automatico

Per `multipart()`, il loop che legge le parti da disco (`readFileInChunks`) chiama `gate.acquire()` **prima** di leggere ogni parte, non dopo. Se il gate è pieno, la lettura del prossimo chunk resta bloccata finché non si libera uno slot — quindi non si accumulano mai in memoria più chunk di quanti il limite corrente ne permetta. Una volta ottenuto lo slot, l'invio della parte viene affidato a un task figlio (dentro un `TaskGroup` locale a `multipart()`), che libera lo slot al proprio termine — questo permette al loop di lettura di procedere subito alla parte successiva (bloccandosi di nuovo su `acquire()` se necessario) invece di aspettare che la parte corrente finisca di essere inviata, ottenendo il parallelismo cercato.

### Un solo gate condiviso tra file e parti

`S3Syncer.sync()` crea un'istanza del gate all'inizio del job e la passa sia al ciclo sui file (oggi `runBounded`, che viene rimosso) sia a ogni chiamata `multipart()`. Ogni file <64MB e ogni parte di ogni file ≥64MB competono per gli stessi slot — coerente con la richiesta di Enrico di non avere due limiti separati per "file" e "parti", ma un solo budget che si adatta indipendentemente dal fatto che il job stia caricando molti file piccoli, pochi file enormi, o un mix.

Per i file, il ciclo in `sync()` non usa più `runBounded` con un tetto fisso di task creati alla volta: tutti gli item vengono aggiunti subito a un `TaskGroup` (i task Swift sospesi in attesa su `acquire()` sono economici, nessun thread di sistema dedicato), e la concorrenza effettiva è governata solo dal gate.

### Correzione necessaria collegata: HTTP 429 deve essere ritentabile

`S3Syncer.isRetryable(_:)` oggi tratta **tutti** gli errori 4xx (400-499, incluso 429) come permanenti — non ritentati. Ma HTTP 429 è esattamente il segnale "stai andando troppo veloce" che questo design deve poter interpretare: se rimane permanente, un job che incontra rate-limiting fallisce del tutto sul file/parte in questione invece di rallentare e ritentare (cosa che, dopo la riduzione del limite innescata dallo stesso 429, avrebbe buone probabilità di successo). Fix di una riga: `isRetryable` tratta 429 come ritentabile, tutti gli altri 4xx restano permanenti come oggi.

### Correzione necessaria collegata: ordine delle parti nel completamento multipart

Con le parti caricate in parallelo, possono completare in un ordine diverso da quello di lettura. AWS S3 richiede che il body di `CompleteMultipartUpload` elenchi le parti in ordine crescente di `PartNumber`. Il codice attuale si affida implicitamente all'ordine sequenziale di completamento (`parts.append((partNumber, etag))` dentro il loop sequenziale) — con l'esecuzione parallela questo non è più garantito. Fix: raccogliere i risultati dei task figli in un array/dizionario indicizzato per `partNumber`, e ordinare esplicitamente per `partNumber` prima di costruire `partsXML`.

## Testing

- **Logica pura del gate, testabile senza rete né timer**: la transizione di stato (limite corrente + contatore successi consecutivi → nuovo stato, dati un esito) va estratta in un tipo/funzione pura indipendente dall'`actor` (che si occupa solo della sincronizzazione/attesa reale). Test coperti: crescita dopo N successi consecutivi, azzeramento del contatore su un fallimento, dimezzamento con floor a 1, crescita bloccata al tetto, nessun effetto sul limite per fallimenti permanenti.
- **`isRetryable`**: nuovo caso per HTTP 429 (ritentabile), invariati gli altri 4xx (permanenti) e 5xx/URLError (già ritentabili).
- **Ordinamento parti**: test unitario sulla funzione che costruisce `partsXML` con input fuori ordine, verifica che l'XML risultante sia comunque in ordine crescente di `PartNumber`.
- **Non testabile automaticamente** (stesso precedente di `ImmichManager`/Keychain in questo progetto): il comportamento reale di crescita/riduzione della concorrenza sotto un vero upload di rete, e l'effetto sulla velocità/memoria osservate. Verifica manuale necessaria, vedi sotto.

## Verifica manuale (a carico di Enrico)

Questo lavoro chiude anche un punto già pendente da roadmap #6 (2026-08-02): "verificare il comportamento di `multipart()` su un multipart reale con Monitor Attività aperto", mai fatto perché in quel momento le parti erano comunque sequenziali. Un solo test reale copre entrambe le verifiche:

1. Avviare un job SSD→S3 che includa almeno uno degli zip da 40-50GB nella cartella "Zip" dell'SSD.
2. Osservare la velocità di upload nel grafico esistente (`SpeedChartView`): ci si aspetta un avvicinamento sensibile ai ~33 MB/s di banda reale, non più bloccato a ~4 MB/s.
3. Osservare la memoria del processo con Monitor Attività: deve restare ben al di sotto dei livelli dell'incidente storico (41-43GB), coerente con il tetto di 2GB proposto.
4. A fine job, verificare che il file arrivi integro (nessun errore/hash-mismatch riportato) — nessuna verifica automatica di hash è cambiata da questo intervento, solo l'esecuzione parallela.

## Rischi accettati

- **Rate-limit lato Cubbit sconosciuto**: non c'è documentazione pubblica su eventuali limiti per connessioni/secondo di Cubbit. Il design si autocorregge (403/429/5xx fanno scendere il limite), ma il primo minuto di un job molto grande potrebbe generare qualche errore/retry visibile nel log prima che il limite si assesti. Accettato: comportamento atteso e transitorio, non un errore bloccante del job.
- **Nessun tetto assoluto indipendente dalla memoria**: se il tetto derivato dalla memoria (32 slot) si rivelasse comunque troppo aggressivo per Cubbit in pratica, il meccanismo di riduzione su errore lo riporta comunque a livelli sostenibili — non c'è un floor "duro" diverso da 1.
