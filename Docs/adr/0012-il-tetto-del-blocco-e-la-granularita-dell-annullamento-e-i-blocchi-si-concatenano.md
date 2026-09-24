# ADR-0012 — Il tetto del blocco è la granularità dell'annullamento, e i blocchi si concatenano

**Data:** 2026-09-24
**Stato:** Accettata

## Contesto

Il doc-comment di `duplicateBatchFileCap` dice che 500 è «prudente e ritarabile alla prima passata reale con l'SSD collegato: nessuno ha ancora visto quanti doppioni ci siano davvero». Ora il numero c'è: **89.541 copie in eccesso in 27.798 gruppi, 156,3 GB**. Con il tetto di oggi sono **180 blocchi**, ognuno con riepilogo e conferma distruttiva.

Il tetto non è stato scelto sulla durata ma sul **raggio di un guasto a metà blocco** (ADR-0005, misura 3): lo scollegamento dell'SSD produce 2.672 errori indistinguibili da «il file non esiste», e un blocco interrotto lascia un registro di ripristino da rimettere a posto. Quindi alzare il tetto non è un ritocco di un numero: bisogna dire che cosa protegge al posto suo.

Tre fatti, due misurati e uno letto nel codice, che decidono la risposta:

1. **Il costo della libreria intera è ~40 minuti di macchina, non di clic.** Byte da rileggere per verificare tutti i gruppi: 156,3 GB di copie in eccesso più ~48,5 GB di copie tenute = **~205 GB**, che a 224 MiB/s (misurato sull'SSD vero, 2026-09-01) sono **~15 minuti**; più 89.541 `trashItem` a 55,8 file/s = **~27 minuti**. Il problema non è mai stato il tempo.
2. **Il tetto sui byte non scatta quasi mai su questa libreria.** La copia in eccesso media pesa 1,75 MB, quindi 500 file sono ~0,87 GB: il tetto dei 50 GB è **57 volte più largo** di quello sui file. È il file cap a decidere tutto; alzare i byte non cambierebbe niente.
3. **Il registro di ripristino tiene 2.000 voci** (`TrashManifestStore.maxItems`) e **pota le più vecchie**. Nessun ADR l'aveva messo in relazione col tetto del blocco, e la relazione è vincolante: **se un blocco superasse 2.000 file, il registro poterebbe le voci del blocco stesso mentre lo sta scrivendo**, e «Annulla l'ultimo spostamento» rimetterebbe a posto solo l'ultima parte — senza saperlo e senza dirlo. Un annullamento che mente è esattamente ciò che ADR-0009 esiste per impedire.

E il fatto che rende il tema una decisione e non un calcolo: **l'annullamento è a un solo livello** (ADR-0009, decisione di Enrico). Concatenare 45 blocchi significa che «Annulla l'ultimo spostamento» ne rimette a posto **uno**.

## Opzioni valutate

**A. Tetto più alto e blocchi concatenati automaticamente, annullamento che resta su un blocco (scelta).** Il tetto sale a **2.000 file** (= il tetto del registro, non un numero a caso) e i 50 GB restano; l'utente conferma **una corsa**, l'app la divide in blocchi al tetto e li smaltisce di fila con progresso, «Interrompi» e un resoconto unico. Ogni blocco ha il suo `batchId`, quindi l'annullamento copre **l'ultimo blocco per intero** — che è il massimo che il registro può garantire.

**B. Un unico blocco gigante: alzare il tetto a 90.000 file.** Il registro poterebbe 87.000 voci su 89.541: l'annullamento coprirebbe le ultime 2.000 e le altre resterebbero nel Cestino **senza che nessuno sappia più da dove venivano** (il record «Rimetti a posto» del Finder è asincrono e si perde, misurato). Scartata: trasforma la rete di sicurezza in una finzione.

**C. Registro append-only (una riga per file, JSONL) e annullamento su tutta la corsa.** Tolto il tetto delle 2.000 voci — oggi `record` riscrive l'intero JSON a ogni file, cioè un costo quadratico che a 90.000 voci è dell'ordine dei terabyte scritti — si potrebbe tenere la storia completa e annullare l'intera corsa. Scartata **per questo intervento**, non in assoluto: riscrive il formato dell'unico registro da cui dipende l'unica operazione distruttiva dell'app, e ribalta la decisione «annullamento a un solo livello» che Enrico ha preso 4 giorni fa con argomenti che non sono cambiati.

**D. Tenere il tetto a 500 e non concatenare.** Resta la situazione di oggi: 180 conferme. Scartata perché è il problema.

## Decisione e motivo

**Opzione A**, con quattro conseguenze dichiarate invece di scoperte dopo.

1. **`duplicateBatchFileCap` = 2.000, `duplicateBatchByteCap` = 50 GB invariato**, e un invariante nuovo protetto da un test: **`duplicateBatchFileCap <= TrashManifestStore.maxItems`**. Il tetto sui file non è più «un numero prudente»: è **la granularità dell'annullamento automatico**, e il registro ne fissa il massimo. 2.000 file sono ~3,5 GB, ~55 secondi di blocco: il raggio di un guasto resta un minuto di lavoro e un blocco interamente coperto dall'annullamento.
2. **Il tetto non blocca più la conferma: la divide.** `DuplicatesStatus.confirmationBlockedReason(exceedsCap:)` viene sostituita dal testo che descrive il piano della corsa («lo faccio in 45 blocchi da al massimo 2.000 file, circa 40 minuti»). Le **due conferme restano** (decisione di Enrico): il riepilogo dettagliato e poi l'alert distruttivo, con in più il numero di blocchi, la durata stimata e la frase sull'annullamento.
3. **La corsa si ferma al primo guasto vero, non al primo gruppo saltato.** Un blocco che finisce con `stoppedBecauseVolumeVanished` o con un `trashFailed` **interrompe la catena**: sono guasti del volume, e proseguire su altri 40 blocchi moltiplicherebbe per 40 il raggio del danno. I gruppi saltati dalla verifica (hash non unanime, file illeggibile, non-media, copia tenuta sparita) **non** fermano niente: su questa libreria sono la normalità (l'indice contiene per decisione di prodotto voci di file che non ci sono più, ADR-0002) e fermarsi lì vorrebbe dire non arrivare mai in fondo. Finiscono tutti nel resoconto unico, contati, con il motivo.
4. **Quello che sostituisce la protezione del blocco piccolo**, dato che una corsa può toccare 89.541 file mentre il registro ne ricorda 2.000, è una **storia degli spostamenti** append-only: un file sul disco interno (mai sull'SSD, `0600`, come indice e registro) su cui l'app scrive **una riga per blocco concluso** con i percorsi originali dei file di quel blocco. Non è un secondo annullamento e non aggiunge nessun percorso distruttivo: è la sola cosa che rende possibile, a mano, ritrovare da dove venivano le foto di un blocco vecchio. Costa una scrittura per blocco (non per file), quindi non riapre il costo quadratico dell'opzione C.

**Cosa si accetta di perdere, e va detto all'utente prima di partire, non dopo.** Dopo una corsa di 45 blocchi, «Annulla l'ultimo spostamento» rimette a posto **fino a 2.000 foto: quelle dell'ultimo blocco**. Le altre restano nel Cestino dell'SSD, recuperabili a mano (la storia degli spostamenti dice da dove venivano) e comunque presenti su HDD e Cubbit, che non cancellano mai. La frase va nel riepilogo e nell'alert distruttivo quando i blocchi sono più di uno.

**Prerequisito.** Una corsa dura decine di minuti, e oggi chiudere e riaprire la finestra Doppioni fa perdere barra e «Interrompi» (ROADMAP #41, spec e piano del 2026-09-20 già scritti e non ancora eseguiti). Concatenare blocchi **senza** #41 significa consegnare un'operazione a danno alto, lunga 40 minuti, che l'utente non può più fermare se chiude la finestra. #41 va **prima**.

**Per riaprire questa decisione** serve un argomento nuovo: per esempio una passata reale in cui Enrico ha davvero bisogno di annullare una corsa intera e non solo il suo ultimo blocco — che è anche l'argomento che riaprirebbe ADR-0009 e giustificherebbe l'opzione C.

## Conseguenze

- Un tipo puro nuovo (`DuplicateRunPlan`) divide `[DuplicateBatch.Entry]` in blocchi ai due tetti, nell'ordine già deterministico del pannello, e stima la durata dai due numeri misurati (224 MiB/s di rilettura, 55,8 file/s di cestinamento). Puro e testabile: nessun filesystem.
- `BackupRunner` orchestra la corsa (un `batchId` per blocco, progresso «blocco K di N», stop fra blocchi oltre a quello fra gruppi già esistente). `DuplicateTrasher.run` **non cambia di una riga**: continua a smaltire un blocco.
- La storia degli spostamenti è un tipo nuovo `nonisolated` con la riga sul perché è thread-safe, scritto dal thread della corsa. Non ha nessun percorso di lettura distruttivo e nessun bottone.
- `duplicateBatchFileCap` da 500 a 2.000 **dopo** la misura del costo di scrittura del registro a 2.000 voci (`record` riscrive l'intero JSON a ogni file): se quella misura dicesse che un blocco al tetto spende più di ~30 s nel registro, il tetto scende al valore che la misura consente. Il numero si misura, non si ritocca a occhio.
- Nessuno schema SQLite nuovo. Il registro di ripristino **non cambia formato**: `TrashedItem`, `maxItems` e `pendingInLastBatch()` restano esattamente come li ha lasciati ADR-0009.

## Risposte di Enrico (2026-09-24, domande 2, 3 e 5 della spec §11)

**Domanda 2 — il tetto a 2.000 file: sì**, condizionato alla misura del Task 2 del piano: se scrivere 2.000 voci nel registro di ripristino supera ~30 s, il tetto non è 2.000 ma il valore più alto sotto quella soglia (si prova 1.500, poi 1.000). Il numero misurato va nel doc-comment del tetto, in aggiunta a questa ADR.

**Domanda 3 — la storia degli spostamenti (§3.5, punto 4): sì**, il Task 8 del piano si esegue. Motivo di Enrico: dopo una corsa da 89.541 file il registro ne ricorda solo 2.000 e il record «Rimetti a posto» del Finder è asincrono e si perde; senza la storia degli spostamenti il Cestino dell'SSD diventerebbe una cartella piatta di foto di cui nessuno saprebbe più il percorso d'origine.

**Domanda 5 — la sostituzione di `DuplicatesStatus.confirmationBlockedReason(exceedsCap:)`: assenso esplicito.** Enrico autorizza a cambiare **cosa** asseriscono le 3 asserzioni su `confirmationBlockedReason` in `DuplicatesStatusTests` (e, per la stessa ragione, le 4 stringhe attese di `folderBreakdown` in `DuplicateBatchTests`, §2.7). Sono le **sole due eccezioni** alla regola «un'asserzione esistente non cambia cosa verifica» per questo intervento: ogni altra asserzione che «deve» cambiare resta un segnale da rimandare all'Architect.

Con queste tre risposte l'ADR passa da Proposta ad Accettata.
