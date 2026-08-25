# L'indice di contenuto è una cache, non una fonte di verità

L'indice SHA256 della libreria (roadmap #31) è trattato come una cache: nulla al suo interno è dato originale, è sempre ricostruibile da zero leggendo l'SSD, e **nessun percorso di codice deve trattarne l'assenza o la corruzione come un errore fatale**.

È la decisione da cui discende quasi tutto il resto del design dell'indice, e va tenuta presente prima di "irrobustirlo".

## Conseguenze

- **Durabilità SQLite accettata così com'è**: su macOS `fsync()` non garantisce la persistenza fisica e la SQLite di sistema può sostituire `F_FULLFSYNC` con `F_BARRIERFSYNC`. Nel caso peggiore si perde l'ultima transazione. Non vale la pena difendersi: si ricostruisce.
- **Uno schema sconosciuto significa "ricostruisci", mai "interpreta al meglio"**.
- **Un indice parziale deve essere valido e utile in ogni istante**: commit a batch, mai uno solo alla fine.
- **Mai promettere all'utente che l'indice è indistruttibile**, e tenere sempre disponibile la ricostruzione completa.

Il rovescio della medaglia è che buttare l'indice non è gratis: costa una ricostruzione da 5-15 minuti, e finché non avviene l'import successivo gira senza dati di dedup e **ricrea i doppioni**. "Ricostruibile" non vuol dire "che si può buttare alla leggera" — vedi ADR-0003.
