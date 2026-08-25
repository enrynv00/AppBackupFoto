# SQLite invece di un JSON monolitico per l'indice

L'indice contiene ~120.000 record e viene aggiornato in modo incrementale (all'avvio con SSD collegato, dopo ogni import). Con un JSON monolitico ogni aggiornamento costa O(n) — deserializzare, mutare, riserializzare, riscrivere 25-30MB anche per un solo record — contro O(log n) di SQLite, presente di sistema su macOS senza aggiungere dipendenze.

Il criterio decisivo non è il numero di record ma la **frequenza degli aggiornamenti**: non esiste una soglia "oltre N record il JSON non va più bene".

## Conseguenze

L'asimmetria che conta più della performance: un JSON troncato è **completamente illeggibile**, mentre una corruzione SQLite tipicamente compromette alcune pagine e lascia il resto recuperabile. Su una cache ricostruibile (ADR-0002) è comunque un vantaggio, non una necessità.

Costo accettato: `import SQLite3` significa API C in Swift (`OpaquePointer`, `sqlite3_bind_*`, `unsafeBitCast` per `SQLITE_TRANSIENT`) dentro un file che per il resto è SwiftUI idiomatico. Confinato in `LibraryIndexStore`: nessun altro tipo tocca SQLite direttamente.
