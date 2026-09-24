# ADR-0013 — L'elenco dice da quando non è aggiornato, prima di un'importazione

**Data:** 2026-09-24
**Stato:** Accettata

## Contesto

Dal 2026-09-19 (ADR-0007) l'elenco delle foto già salvate sull'SSD si aggiorna **solo** come ultimo passo di un backup o di un'importazione, o a mano da Diagnostica: al collegamento dell'SSD non parte più nessuna lettura da sola. La conseguenza era stata dichiarata e accettata in quell'ADR — «se l'SSD viene modificato fuori dall'app (Finder, un altro Mac) l'elenco resta indietro fino al prossimo backup o import — innocuo, perché una voce in più si ricontrolla comunque prima di saltare un file».

Quella frase è vera per le voci **in più**, non per quelle che **mancano**. Un file arrivato sull'SSD dal Finder non è nell'elenco, quindi non fa da riferimento per il dedup: al prossimo import lo stesso contenuto viene ricopiato, e il doppione nasce lì. `runImport` passa già `refreshesLibraryIndex: true`, ma quello è il **passo 2**, che aggiorna l'elenco **dopo** che l'importazione ha già deciso cosa copiare.

Non c'è nessun segnale a costo zero che dica se l'SSD è cambiato: l'unico modo di saperlo è rileggerlo. L'unica informazione disponibile prima di un'importazione è **da quanto tempo l'elenco non viene rimesso in pari**, e oggi l'app non la registra da nessuna parte — né la mostra.

Contorno misurato il 2026-09-24 sullo stesso elenco: **390,6 GB indicizzati** contro i 237,4 GiB del censimento del 2026-09-01. La stima della card (`LibraryIndexCard.durata`, «di solito servono dai 15 ai 25 minuti») era giusta per 237 GiB e oggi è **di nuovo sottostimata**: a 224 MiB/s, 390,6 GB sono ~28 minuti. Ed è la stima della **creazione da zero**, non di un aggiornamento incrementale — che è quello che serve qui, e che non è mai stato misurato.

## Opzioni valutate

**A. Nessun avviso: lasciare che il passo 2 rimetta in pari dopo.** È lo stato di oggi. Il buco resta aperto esattamente nello scenario da cui è nata la feature #31.

**B. Rimettere la lettura automatica al collegamento dell'SSD.** Ribalta ADR-0007 quattro giorni dopo averlo scritto, e reintroduce il problema che quell'ADR ha chiuso: una lettura che l'utente non ha chiesto, che blocca i backup per minuti.

**C. Data dell'ultimo aggiornamento sempre visibile, e un avviso con l'offerta di aggiornare oltre una certa età (scelta).** Prima di un'importazione l'app dice a che giorno risale l'elenco; oltre la soglia lo dice come avviso e offre di aggiornarlo subito, senza obbligare.

**D. Obbligare l'aggiornamento prima di ogni importazione oltre la soglia.** Scartata: l'elenco è una cache (ADR-0002) e non può diventare un prerequisito. E il costo di ignorare l'avviso è una copia in più, non una foto persa.

Per la soglia, due candidate: **14 giorni** (scelta) e **30 giorni**, che avrebbe il pregio della coerenza con l'unica altra soglia di stantìo del progetto (il deep checksum del mirror SSD → HDD).

Per la sorgente della data, due candidate: **`MAX(hashed_at)` dell'elenco** e **l'istante dell'ultima lettura arrivata in fondo** (scelta). La prima sembra gratis e risponde alla domanda sbagliata: una lettura incrementale che non trova niente di nuovo non tocca nessun `hashed_at`, quindi direbbe «tre settimane» un minuto dopo aver rimesso in pari l'elenco.

## Decisione e motivo

**Opzione C, soglia 14 giorni, data = istante dell'ultima lettura arrivata in fondo.**

La soglia a 14 giorni sta fra due errori: a 30 giorni, con il ritmo reale di backup di Enrico, l'avviso non comparirebbe quasi mai e sarebbe decorativo; a 2-3 giorni comparirebbe sempre, e «sovrastimare i problemi insegna a ignorare l'allarme» è un principio che questo progetto ha già applicato (ADR-0007, `copiedUnverified`). Due settimane è abbastanza per avere dimenticato di aver copiato qualcosa dal Finder, abbastanza poco perché rimediare costi pochi minuti.

**La data si scrive solo se la lettura è arrivata in fondo.** Una lettura interrotta, con l'SSD scollegato a metà o con cartelle illeggibili (`traversalIncomplete`, `cancelled`, `volumeVanished`) **non** aggiorna la data: non ha rimesso in pari l'elenco, e registrarla direbbe il contrario. Vale per tutti gli ingressi della lettura, passo 2 compreso, perché passano già tutti da `startLibraryIndexScan`. Svuotare l'elenco azzera la data.

**Se la data non c'è** (elenco costruito prima di questa versione) si usa `MAX(hashed_at)` come **ripiego dichiarato**, calcolato fuori dal main una volta sola all'apertura del wizard. È un limite inferiore: può solo far sembrare l'elenco più vecchio di quanto sia, cioè può solo far comparire un avviso di troppo — mai tacerne uno che serviva. Vale finché la prima lettura completa non scrive la data vera.

**L'offerta è un aggiornamento, non una ricostruzione.** «Ricostruzione completa» (`ignoringStoredHashes`) rilegge e rihasha tutto: ~28 minuti oggi, e non serve a niente per questo problema. Quello che serve è la lettura incrementale, che aggiunge i file che l'app non conosce. La differenza fra le due deve restare visibile nel testo: la ricostruzione completa resta dov'è, in Diagnostica, come azione esplicita.

**Nessuna promessa di durata che non sia stata misurata.** L'aggiornamento incrementale su 141.683 voci non è mai stato cronometrato. Finché non lo è, il testo dice **cosa** fa l'app, non quanto ci mette. E la stima della card (`durata`) va corretta con il numero di oggi (~28 minuti su 390,6 GB), non lasciata al valore del 2026-09-01.

**Cosa si accetta di perdere.** L'avviso non sa se l'SSD è davvero cambiato: parla di tempo, non di contenuto, e può comparire quando non serviva. Un orologio di sistema spostato in avanti lo fa comparire a torto — lo stesso limite già dimostrato e codificato per la scadenza dei debiti di verifica, e qui del tutto innocuo (non si pota niente, si mostra una riga in più). E l'utente che ignora l'avviso ricrea dei doppioni: recuperabili, ora che il pannello Doppioni funziona alla scala vera (ADR-0011, ADR-0012).

**Per riaprire questa decisione** serve un argomento nuovo: per esempio la misura di un aggiornamento incrementale tanto rapido da poterlo fare **sempre** prima di un'importazione, senza chiedere niente. Quella misura cambierebbe il design, non solo la soglia.

## Conseguenze

- Una chiave `UserDefaults` nuova con la data dell'ultima lettura arrivata in fondo, scritta in un punto solo (il `onFinish` di `startLibraryIndexScan`, dove la completezza è già nota) e azzerata da `deleteIndexAndRecreate`.
- Un metodo nuovo sullo store per il ripiego (`MAX(hashed_at)`), con lo stesso contratto di tutte le letture dell'indice: un risultato assente significa «non lo so».
- Un tipo puro nuovo (`LibraryListFreshness`) che produce le righe, usato **sia** dal passo di anteprima del wizard **sia** dalla card di Diagnostica: una sola fonte per il testo, come `LibraryIndexStatus` e `DuplicatesStatus`. Registro anti-gergo invariato: si dice «l'elenco delle foto già salvate sull'SSD», mai «indice», «hash» o «scansione».
- Il wizard guadagna un terzo ingresso sopra `startLibraryIndexScan`, che riusa la funzione esistente e **non** duplica nessuna decisione; a lettura finita l'anteprima si **rifà**, perché l'insieme dei doppioni riconosciuti è cambiato. La mutua esclusione è già scritta: `JobStartGate` impedisce l'avvio dell'importazione durante una lettura.
- `LibraryIndexCard.durata` aggiornata al numero misurato oggi.
- Nessuno schema SQLite nuovo, nessun formato su disco nuovo.

## Risposta di Enrico (2026-09-24, domanda 4 della spec §11)

**«La soglia dell'avviso: 14 giorni o 30?» → 14 giorni**, la raccomandazione di questa ADR. L'argomento resta quello scritto sopra in «Decisione e motivo»: a 30 giorni, con il ritmo reale di backup di Enrico, l'avviso non comparirebbe quasi mai e sarebbe decorativo; a 2-3 giorni comparirebbe sempre e insegnerebbe a ignorarlo. Nessuna correzione all'argomento è necessaria perché la soglia scelta è quella già raccomandata, non i 30 giorni dell'alternativa. Con questa risposta l'ADR passa da Proposta ad Accettata.
