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

## Nota (2026-08-27): la cache non può mai essere la sola base di un atto distruttivo

«L'indice è una cache, non una fonte di verità» resta vero, e dal 2026-08-27 diventa più importante: da quella data un consumatore della cache può **spostare file nel Cestino** (pannello Doppioni, ADR-0005).

La conseguenza da aggiungere è una sola, e non ammette eccezioni:

> **Nessun file viene mai spostato, rinominato o rimosso sulla base di ciò che dice l'indice.** Il disco si rilegge sempre prima — ogni membro del gruppo, la copia tenuta compresa — e si pretende unanimità. L'indice serve a *proporre* i candidati, mai ad autorizzare l'operazione.

Chi legge il codice del pannello troverà una rilettura che «sembra ridondante», visto che l'indice ha già gli hash. Non lo è: è questa nota, ed è ADR-0005.

### Precisazione: la rimozione mirata delle chiavi dopo il cestinamento è conoscenza, non inferenza

Dopo un gruppo cestinato con successo, l'app rimuove dall'indice **le chiavi dei file effettivamente cestinati, e nessun'altra**.

Questo **non** ricade sotto la regola «traversata incompleta ⇒ nessuna rimozione dall'indice» stabilita durante il nucleo di #31. Quella regola protegge da un'**inferenza**: «non ho visto questo file durante la scansione, quindi probabilmente non c'è più» — un ragionamento che una traversata interrotta rende falso, e il cui costo è dedup spento e ricostruzione.

Qui non si inferisce niente. L'app **sa** che quel file non è più a quel percorso, perché è stata lei a spostarlo, un file alla volta, e ha il `resultingItemURL` restituito da `trashItem` scritto nel registro di ripristino. È conoscenza diretta di un'azione appena compiuta, non una deduzione da un'assenza.

Verso opposto, per completezza: dopo un **annullamento** le entry **non** vengono reinserite a mano. Ricostruirle significherebbe inventare un `hashedAt`, cioè avvelenare la regola anti-racy per risparmiare una scansione incrementale. Si segna che l'indice va aggiornato e ci pensa la scansione: i file tornati risultano nuovi e vengono rihashati.
