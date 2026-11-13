# ADR-0020 — I file che una copia locale non ha copiato si elencano, con un motivo da disco e non da rete

**Data:** 2026-11-13
**Stato:** Accettata (2026-11-13)

## Contesto

ADR-0014 ha reso visibili i file non caricati su Cubbit e ha lasciato apposta lo stesso buco nelle copie locali (D4 = A, ROADMAP #49). In `FileSyncer.syncFile` (Mac → SSD, SSD → HDD, Importa) un errore di `createDirectory` o `copyItem` faceva `errors += 1` e basta, e una copia non identica all'originale lasciava solo «HASH MISMATCH: <nome>», senza percorso, per un file che la regola zero-overwrite non ricopierà mai. Il percorso è quello della regola assoluta: nessun comportamento di copia può cambiare. Misurato il 2026-11-13 su immagini APFS ed exFAT (FSKit): disco pieno = 640/28 e nessuna copia parziale; sorgente illeggibile e cartella non scrivibile danno lo stesso 513/13; una destinazione comparsa dopo il controllo dà 516/17 e resta intatta; `contentsOfDirectory` restituisce `/private/var` per `/var`. Piano: `Docs/superpowers/plans/2026-11-13-local-copy-failures-visible.md`.

## Opzioni valutate

- **Riusare `failedFiles` di #43.** Scartata: titolo, rassicurazione e fondo del registro dicono «Cubbit» e i test di #43 li fissano; servirebbe un indicatore di provenienza con un default che su un lato nessun test copre. Scelto un elenco a parte, `failedCopies`.
- **Motivo dal codice Cocoa o dal codice di sistema.** Il Cocoa da solo confonde «permesso negato» (13) e «macOS non ha permesso» (1, file bloccato o «Accesso completo al disco» perso): si decide prima sul codice di sistema, si mostrano entrambi.
- **Percorso relativo togliendo la radice** (scartato: sbaglia con i collegamenti, misurato) **o costruito cartella per cartella** (scelto).
- **Molti errori:** una riga per file (scelta, come #43: si aggiunge una riga alla «Copia (n/N)» che ogni file tentato manda già), un tetto alle righe, o fermare il job al disco pieno (scartato qui: cambierebbe la copia).
- **Copie non identiche nell'elenco o no**: decisione di Enrico, vedi sotto.

## Decisione e motivo

Ogni file non copiato lascia «Non copiato: «percorso» — motivo.» e finisce in `FileSyncer.SyncResult.failedCopies`; ogni copia non identica lascia «Copia non identica: «percorso» — …» e finisce nello stesso elenco; `errors + hashErrors` e la lunghezza dell'elenco si muovono insieme, da due soli punti. Il percorso è relativo alla cartella sorgente del job, uguale sotto la destinazione. Il motivo è una frase semplice con «(codice Cocoa/sistema)» (`LocalCopyText`, puro, `nonisolated`). Il riepilogo di fine job mostra al massimo 8 righe con le stesse regole di #43; l'elenco completo va in fondo al registro su disco di ADR-0014. Le copie del risultato inviate al progresso non portano l'elenco, che viaggia solo nel risultato finale.

**Cosa si accetta di perdere.** (1) Il motivo «permesso negato» non sa dire se il problema è il file di partenza o la cartella di destinazione: macOS dà lo stesso errore. (2) Un job interrotto o fallito a metà non porta l'elenco nel riepilogo; le righe per file restano nel registro, salvo quelle arrivate dopo la chiusura (ADR-0014, punto 4). (3) Disco pieno o HDD staccato producono migliaia di righe: il registro le tiene tutte, la scheda Log le ultime 60.000 lettere. (4) Il ripristino guidato non elenca i nomi: fuori scope. (5) Errori a metà copia diversi dal disco pieno (lettura, disco staccato) non sono misurati: la riga non promette che il prossimo backup lo rifarà.

**Per riaprire questa decisione** serve un backup vero in cui le righe mostrino un motivo sbagliato o un caso frequente finito in «errore imprevisto», o in cui le migliaia di righe di un disco pieno rendano la finestra inutilizzabile.

## Conseguenze

- Tipi nuovi, `nonisolated`: `LocalCopyText`, `LocalCopySummary`. `SyncResult`: `failedCopies`, `recordCopyFailure`, `recordCopyMismatch`, `progressSnapshot`. `JobStats.failedCopies` (non persistito).
- `syncDir`/`syncFile` ricevono il percorso relativo (parametri privati, senza default). Nessuna `copyItem`/`moveItem`/`removeItem`/`createDirectory` aggiunta, tolta o spostata; zero-overwrite invariato.
- La riga «HASH MISMATCH» è sostituita; la `CompletionSheet` mostra l'elenco e tiene le righe generiche solo quando l'elenco manca.

## Vocabolario dei motivi (tabella di riferimento per `LocalCopyText.reason`)

Si decide prima sul codice di sistema, poi sul codice Cocoa. Dopo la frase: «(codice C/S)», oppure «(codice N)» se ce n'è uno solo.

| Codice di sistema | Codice Cocoa | Frase |
|---|---|---|
| 28 | 640 | «il disco di destinazione è pieno» |
| 30 | 642 | «il disco di destinazione è in sola lettura» |
| 13 | 513, 257 | «permesso negato: il Mac non ha potuto leggere il file o scrivere nella cartella di destinazione» |
| 1 | — | «macOS non ha permesso l'operazione: il file potrebbe essere bloccato, oppure l'app ha perso «Accesso completo al disco»» |
| 2 | 260, 4 | «il file o la sua cartella non c'è più: spostato, cancellato o disco scollegato» |
| 17 | 516 | «a destinazione è comparso un file con lo stesso nome, che non è stato sovrascritto» |
| 63 | 514 | «il nome del file è troppo lungo per il disco di destinazione» |
| 20 | — | «a destinazione, al posto di una cartella, c'è un file con lo stesso nome» |
| 27 | — | «il file è troppo grande per il disco di destinazione» |
| 92 | — | «il nome del file contiene caratteri che il disco di destinazione non accetta» (non misurato) |
| 5 | — | «errore di lettura o scrittura del disco» |
| 6 | — | «il disco non risponde più: forse è stato scollegato» |
| — | altri 256…511 | «il file non si è potuto leggere» |
| — | altri 512…767 | «non si è potuto scrivere a destinazione» |
| tutto il resto | | «errore imprevisto»; il dominio non compare mai |

## Decisioni di Enrico (2026-11-13)

- **D1 = A.** Anche le copie non identiche all'originale entrano nell'elenco e nel riepilogo, con un motivo loro.
- **D2 = A.** Testo per le copie non identiche: «Le copie non identiche restano come sono: l'app non sovrascrive mai, quindi non le rifà da sola. Vanno controllate a mano.»
- **D3 = A.** Branch nuovo `fix/local-copy-failures-visible` sopra `fix/s3-upload-failures-visible`; verifica dal vivo insieme al Task 10 di #43.

