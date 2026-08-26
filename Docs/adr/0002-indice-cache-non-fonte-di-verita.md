# L'indice di contenuto è una cache, non una fonte di verità

L'indice SHA256 della libreria (roadmap #31) è trattato come una cache: nulla al suo interno è dato originale, è sempre ricostruibile da zero leggendo l'SSD, e **nessun percorso di codice deve trattarne l'assenza o la corruzione come un errore fatale**.

È la decisione da cui discende quasi tutto il resto del design dell'indice, e va tenuta presente prima di "irrobustirlo".

## Conseguenze

- **Durabilità SQLite accettata così com'è**: su macOS `fsync()` non garantisce la persistenza fisica e la SQLite di sistema può sostituire `F_FULLFSYNC` con `F_BARRIERFSYNC`. Nel caso peggiore si perde l'ultima transazione. Non vale la pena difendersi: si ricostruisce.
- **Uno schema sconosciuto significa "ricostruisci", mai "interpreta al meglio"**.
- **Un indice parziale deve essere valido e utile in ogni istante**: commit a batch, mai uno solo alla fine.
- **Mai promettere all'utente che l'indice è indistruttibile**, e tenere sempre disponibile la ricostruzione completa.

Il rovescio della medaglia è che buttare l'indice non è gratis: costa una ricostruzione da 5-15 minuti, e finché non avviene l'import successivo gira senza dati di dedup e **ricrea i doppioni**. "Ricostruibile" non vuol dire "che si può buttare alla leggera" — vedi ADR-0003.

## Nota (2026-08-26): l'escape hatch va reso raggiungibile dall'app

"Ricostruibile da zero" resta vero solo se l'utente ha un modo di farlo **dall'app**. La regola "traversata incompleta ⇒ nessuna rimozione" (più "zero file visti non autorizza rimozioni") implica che se l'utente cancellasse davvero tutte le foto, le entry fantasma resterebbero per sempre: `sawNothing` rende `traversalIncomplete = true`, e la Ricostruzione completa **di proposito** non lo scavalca — `ignoringStoredHashes` scavalca solo la guardia di plausibilità. Fino a oggi l'unica uscita era cancellare il file dal Finder, cioè un escape hatch che dall'app non esisteva.

Da qui `LibraryIndexStore.deleteIndexAndRecreate()`: chiude la connessione, cancella l'indice e i suoi `-wal`/`-shm`, riapre vuoto. Il prezzo del verso sicuro scelto (tenere di più, mai togliere di più) si paga con un comando esplicito, non con un vicolo cieco.

Tre vincoli, tutti conseguenza di questa ADR:

- **Solo dentro la posizione consentita**, riusando la stessa allow-list di `init` — non una seconda guardia scritta apposta, che divergerebbe alla prima modifica di una sola delle due.
- **Solo file con estensione `.sqlite`**. La guardia di posizione da sola non basta: la cancellazione scatta quando SQLite risponde `SQLITE_NOTADB`, che è esattamente ciò che SQLite risponde per *qualunque* file che non sia un database. Senza il controllo sull'estensione, un JPEG passato per errore alla store verrebbe cancellato.
- **Percorsi espliciti**, mai wildcard né ricorsione su directory.

E se la cancellazione fallisce, non si fallisce: lo store viene riaperto sul vecchio file, l'errore arriva al chiamante che lo mostra e prosegue. Un'app che non parte perché non è riuscita a cancellare una cache contraddirebbe questa ADR alla lettera.

## Nota (2026-08-26): la cache contiene dati personali

L'indice non contiene foto, ma contiene i **percorsi** di tutte le foto di Enrico, in chiaro. Vive sotto Application Support — già protetta dai permessi della home — ma nasceva `0644`, cioè leggibile da un altro utente locale dello stesso Mac. Ora indice e sidecar sono `0600`.

È una misura di igiene, non una difesa crittografica: chi ha accesso alla home ha comunque accesso alle foto. Vale la pena solo perché costa una `chmod`. Coerentemente con questa ADR è **best-effort**: se la `chmod` fallisce, l'indice resta perfettamente usabile e non si lancia niente.

Da misurare, non dedurre: SQLite ricrea `-wal`/`-shm` a ogni checkpoint, copiando i permessi del database. Il test che protegge questa nota verifica i permessi **dopo** un ciclo completo di apertura/scrittura/chiusura/riapertura, e si salta da solo se l'umask del processo di test è già restrittiva — altrimenti sarebbe verde senza dimostrare niente.
