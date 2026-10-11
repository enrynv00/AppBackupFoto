# ADR-0019 — Le copie già tolte dall'SSD si tolgono da HDD e Cubbit solo se la copia tenuta è identica lì e c'è ancora sull'SSD

**Data:** 2026-10-10 (spec), piano dello stesso giorno
**Stato:** Accettata (2026-10-11)

## Contesto

Il progetto 3 (ADR-0017, ROADMAP #46) ha tolto dall'SSD 89.442 copie doppie (47 blocchi, 2026-10-06/07); HDD e Cubbit le hanno ancora tutte, 144 GB ciascuno. Il backup copia solo ciò che manca e non cancella mai, quindi non le toglierà da solo. È il progetto 4 di 4 verso «una copia per archivio» (ADR-0015/0016/0017). Togliere una copia dall'HDD o da Cubbit apre due porte nuove nella regola «zero delete»: il Cestino dell'HDD e il DELETE su Cubbit. Spec `Docs/superpowers/specs/2026-10-10-archive-alignment-hdd-cubbit-design.md`; piano `Docs/superpowers/plans/2026-10-10-archive-alignment-hdd-cubbit.md`.

Fatti verificati prima di progettare (2026-10-10): su un bucket di prova Cubbit accetta le versioni e la regola di scadenza solo «vecchio stile» (`Prefix` vuoto); un DELETE senza versione crea un segno di cancellazione e la versione resta; togliere il segno con la sua versione fa tornare l'oggetto identico. Sul bucket vero le versioni non sono accese. L'inventario di oggi certifica tutte le 89.442 copie su entrambi gli archivi; Cubbit risponde ~110 ms a richiesta; sull'HDD nessuna copia è bloccata.

## Opzioni valutate

- **A. Lasciare tutto com'è.** Scartata da Enrico: 144 GB in più su HDD e Cubbit, e tre archivi diversi.
- **B. Rifare il pannello Doppioni su HDD e su Cubbit** (gruppi propri di ciascun archivio). Scartata (decisione 1 di Enrico): la scelta di cosa tenere è già stata fatta e verificata sull'SSD; rifarla altrove potrebbe tenere copie diverse nei tre archivi. I doppioni che esistono solo su HDD o Cubbit restano fuori.
- **C. Uno specchio che cancella** (l'HDD e Cubbit diventano uguali all'SSD togliendo tutto ciò che sull'SSD non c'è). Scartata: è esattamente il «delete» che la regola assoluta esiste per impedire; un SSD letto a metà o rovinato si propagherebbe agli altri due.
- **D. Togliere solo le copie della storia degli spostamenti, con la stessa copia tenuta, a condizioni verificate (scelta).**

## Decisione e motivo

**Quali copie:** solo quelle nella storia degli spostamenti dell'SSD (`trash-history.jsonl`), con la copia che l'SSD ha tenuto (`keptPaths`). La storia, che fino a ADR-0012 non si leggeva mai per decidere, diventa l'elenco di partenza (`TrashHistoryReader`); una riga illeggibile non porta copie.

**Quando una copia si toglie da un archivio** (tutte le condizioni): inventario completo sui tre archivi e più recente dell'ultimo backup o import (stessa regola e stessa funzione di ADR-0017), ricontrollato prima di ogni blocco; la copia tenuta c'è sull'archivio con lo stesso contenuto (HDD: stesso SHA256; Cubbit: stessa certificazione per contenuto dell'inventario, ADR-0015) ed è la stessa che c'è sull'SSD; la copia uscita non è tornata sull'SSD; i due percorsi sono diversi e nessuno dei due collide con un altro senza maiuscole; ricontrollo dal vivo subito prima: SSD (la copia non c'è, la tenuta c'è con la stessa dimensione), HDD (rilettura e rihash di entrambe) o Cubbit (HEAD di entrambe); su Cubbit le versioni accese e le regole lette prima di ogni blocco.

**Come:** sull'HDD `trashItem` nel Cestino dell'HDD (stesso volume); su Cubbit DELETE senza versione (il segno di cancellazione lascia la versione per 30 giorni). Una copia alla volta, a blocchi da 2.000, dopo un controllo senza togliere, un riepilogo e una conferma. Registro in sola aggiunta sul Mac, una riga prima di toccare la copia e una dopo. «Annulla l'ultimo blocco»: dal Cestino con la cura di `TrashRestorer`; su Cubbit togliendo solo un segno di cancellazione registrato, confermato come segno e ultimo stato della chiave, entro i giorni della regola, con la HEAD dopo. Una corsa alla volta, in mutua esclusione con backup, inventario, riparazione e Doppioni, nei due versi.

**L'app non cambia mai la configurazione del bucket**: legge versioni e regole, non le scrive. Le versioni le accende Enrico con Claude, dal terminale, subito prima della prima pulizia vera.

**Cosa si accetta di perdere:** l'HDD libera spazio solo quando Enrico svuota il suo Cestino; Cubbit dopo 30 giorni; una corsa su Cubbit dura ore (una copia alla volta, ~0,35 s); l'SSD deve restare collegato durante le corse (D6); un DELETE senza segno, se Cubbit lo facesse nonostante le versioni lette accese, cancella quella copia per sempre prima che la corsa si fermi (la copia tenuta resta su Cubbit, SSD e HDD); dopo una corsa l'inventario va aggiornato perché la finestra Inventario rifletta i nuovi numeri.

**Per riaprirla** serve un argomento nuovo: per esempio doppioni che esistono solo su HDD o Cubbit (un progetto a parte), checksum SHA256 lato server su Cubbit, o una misura che mostri copie della storia che le condizioni bloccano in massa.

## Risposte di Enrico (D1-D12)

Approvate da Enrico il 2026-10-11 tutte con la raccomandazione del piano: D1 sezione in fondo alla finestra Inventario; D2 blocchi da 2.000 copie o 50 GB; D3 file «Bloccato» sull'HDD saltati con il motivo; D4 versioni e regole lette prima di ogni blocco Cubbit; D5 corse separate, prima l'HDD; D6 SSD collegato e ricontrollato dal vivo; D7 Cubbit una copia alla volta; D8 due registri in sola aggiunta sul Mac; D9 anche le chiavi con parentesi, apostrofo o `+`; D10 «Annulla» sull'HDD riusa `TrashRestorer`; D11 testi della regola assoluta e della checklist come nel piano; D12 branch `feature/archive-alignment`.
