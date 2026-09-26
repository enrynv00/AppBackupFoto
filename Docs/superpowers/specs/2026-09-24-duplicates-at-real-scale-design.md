# Il pannello Doppioni alla scala reale — selezione in massa, blocchi concatenati, e l'elenco che dice da quando non è aggiornato

**Stato: BOZZA — in attesa dell'approvazione esplicita di Enrico.** Nessuna riga di codice scritta. Piano collegato: `Docs/superpowers/plans/2026-09-24-duplicates-at-real-scale.md`. ADR: **0011** (selezione in massa e regola per cartella), **0012** (tetto del blocco e blocchi concatenati), **0013** (elenco stantio prima di un'importazione).

**Base:** `main` **dopo** il merge di ROADMAP **#41** (`Docs/superpowers/plans/2026-09-20-trash-progress-survives-window-close.md`). Vedi §3.6: senza #41 questo lavoro consegna un'operazione da decine di minuti che l'utente non può più fermare se chiude la finestra.

Tre direzioni approvate da Enrico, più un quarto filone emerso durante l'analisi e **deliberatamente fuori dal piano**:

| # | Cosa | Priorità |
| :--- | :--- | :--- |
| **1** | Selezione in massa, filtri, regola per cartella | **alta** — è ciò che rende la feature usabile |
| **2** | Tetto ritarato e blocchi concatenati con progresso e stop | alta — senza, la direzione 1 produce 45 conferme invece di 180 |
| **3** | Avviso di elenco non aggiornato prima di un'importazione | media — chiude il buco aperto da ADR-0007 |
| **4** | Il dedup in importazione è cieco alla cartella | **§5, non nel piano**: è una decisione di prodotto che richiede un ADR proprio |

Regole che valgono per tutto l'intervento (da `Docs/CLAUDE.md`, `Docs/CONTEXT.md`, `.claude/rules/architecture.md`):

- **ADR-0005 resta intero.** Il pannello Doppioni è l'unico percorso che rimuove file, solo `FileManager.trashItem`, mai `removeItem`, mai un file la cui unica copia sparisce. Zero delete vale per tutto il resto.
- **La rilettura e il rihash unanime di ogni membro, la copia tenuta compresa, non si tocca e non si ottimizza.** La selezione in massa moltiplica i gruppi confermati; non salta una sola verifica. Nessun diff di questo intervento entra in `DuplicateTrasher.verify`.
- **Una sola copia della decisione.** `DuplicateBatch` congela la copia tenuta e nessuno la ricalcola a valle (§2.5). È la classe di errore già pagata tre volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).
- **ADR-0002/0003**: l'indice è una cache; un risultato vuoto significa «non lo so». Mostrare = livello 1, cestinare = livello 3.
- **Le due conferme restano** (riepilogo dettagliato, poi alert distruttivo): decisione di Enrico.
- **ADR-0006**: isolamento MainActor di default; ogni lavoro pesante `nonisolated` e fuori dal main, con accanto la riga che dice perché è sicuro. `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in Debug: zero warning.
- **Lessico**: a schermo non si scrivono «indice», «hash», «scansione», «registro», «cache». Si dice «l'elenco delle foto già salvate sull'SSD». Tutti i testi vivono in tipi puri, mai costruiti nella View.
- **`Takeout/`, `Takeout 2/` e `ASUS/` sono cartelle di pari dignità** (decisioni chiuse il 2026-09-01 e il 2026-09-24): nessun declassamento a priori. Se una regola dell'utente le declassa, è l'utente a deciderlo.

---

## 0. Le misure — già fatte, da usare e non rifare

Fonte: copia di `~/Library/Application Support/AppBackupFoto/library-index.sqlite` (49 MB, `hashed_at` massimo 2026-09-21 22:26), letta il 2026-09-24 con l'SSD **scollegato**.

| Grandezza | Valore |
| :--- | :--- |
| Voci nell'elenco | **141.683** |
| Contenuti distinti | 52.142 |
| Copie in eccesso | **89.541** in **27.798 gruppi** |
| Byte indicizzati / contenuto unico / recuperabile | 390,6 GB / 234,3 GB / **156,3 GB (40%)** |
| File da 0 byte | 3 (già esclusi da `duplicateGroups()`) |
| Copia in eccesso media | **1,75 MB** |

**Cartelle di primo livello** (`display_path`): `ASUS` 93.824, `Foto iPhone` 18.530, `Takeout` 13.138, `Takeout 2` 10.708, `Foto Google Drive` 3.945, `Other` 1.508, `Import` 30.

Due scoperte che i documenti del progetto non conoscevano:

- **`ASUS/` non è documentata da nessuna parte.** Il censimento del 2026-09-01 parlava di cinque cartelle e 47.482 media; `ASUS` è comparsa dopo ed è oggi **due terzi dell'elenco**. `ASUS/foto` sono 75.269 delle sue 93.824 voci, con percorsi `ASUS/foto/recup_dir.NN/<f|t><numero>.jpg`: è un **recupero PhotoRec/TestDisk da un PC morto** (`recup_dir.N` è il nome delle directory di output di PhotoRec, `f`/`t` la sua nomenclatura, `t` = thumbnail carvata a parte). **Decisione di Enrico del 2026-09-24: la cartella si tiene, di pari dignità, e `recup_dir.*` non si declassa.** L'argomento «è un'estrazione automatica, quindi vale meno» è lo stesso già respinto per `Takeout/`, e la risposta è la stessa: l'origine automatica non dice niente sul valore del contenuto. **Non riaprire.**
- **`Import/` ora esiste** (30 voci): la regola 2 di `duplicateKeepChoice` (`notAnImport`), che il 2026-09-01 era documentata come «non discrimina nulla oggi», **si attiva davvero**. Il doc-comment va aggiornato.

**Distribuzione dei gruppi per numero di copie**: 2 copie 14.966 gruppi, 3 copie 4.621, 4 copie 2.124, 5 copie 1.594, 6 copie 1.293, poi coda lunga fino a oltre 16.

**Sovrapposizione fra cartelle di primo livello** (insiemi esatti — gruppi / copie in eccesso / GB recuperabili):

| Insieme | Gruppi | Copie in eccesso | GB |
| :--- | ---: | ---: | ---: |
| `ASUS` da sola | **11.082** | **59.591** | 19,3 |
| `{Takeout, Foto Google Drive, ASUS}` | 2.262 | 10.331 | **48,4** |
| `{Takeout, Foto iPhone}` | 5.367 | 5.400 | 21,4 |
| `{Takeout 2, Foto iPhone}` | 3.383 | 3.411 | 15,7 |
| `{Takeout 2, ASUS}` | 2.186 | 2.921 | 25,2 |
| `{Other, ASUS}` | 1.085 | 2.122 | 7,3 |
| `{Takeout, Other, ASUS}` | 371 | 3.056 | 2,6 |
| `{Takeout, ASUS}` | 993 | 1.093 | 7,1 |
| `{Foto Google Drive, ASUS}` | 506 | 751 | 3,3 |
| `Foto iPhone` da sola | 150 | 166 | 3,8 |

**Due letture di questa tabella decidono il design.** La prima: **il 66,6% delle copie in eccesso (59.591 su 89.541) sta in gruppi interamente interni a `ASUS`**, dove una regola «tieni in X, cestina in Y» non ha né X né Y. La seconda: il maggior recupero in byte non è lì ma in `{Takeout, Foto Google Drive, ASUS}` — 48,4 GB in soli 2.262 gruppi, cioè **31% dei byte in 8% dei gruppi**.

**Contenuti presenti solo dentro `ASUS`**: 17.101, per **32,5 GB**. Non sono in discussione: nessuna copia unica sparisce (lo garantisce ADR-0005, e qui è anche una volontà espressa da Enrico). 7.501 contenuti di `ASUS` esistono anche fuori.

**Costo di macchina dell'intera libreria**, ricavato dalle due misure sul volume vero (rilettura+SHA256 a 224 MiB/s, 2026-09-01; `trashItem` a 55,8 file/s, 2026-08-27):

- byte da rileggere per verificare tutti i gruppi: 156,3 GB (copie in eccesso) + ~48,5 GB (copie tenute) = **~205 GB → ~15 minuti**;
- 89.541 `trashItem` → **~27 minuti**;
- **totale ~40-45 minuti.** Il problema non è mai stato il tempo: sono i 90.000 clic e le 180 conferme.

---

## 1. Cosa c'è oggi — letto nel codice, non dedotto

### Il pannello

`DuplicatesView.listArea` mette **tutti** i gruppi in una `LazyVStack` dentro una `ScrollView`, con un `DuplicateGroupRow` per gruppo e un clic per selezionarlo (`toggleSelection(_ hash:)` su `selectedHashes: Set<String>`). **Nessun filtro, nessun «seleziona tutti», nessuna selezione per cartella.** `headerLine` legge `loadedBatch` in O(1) (correzione del bug di prestazioni del 2026-09-02: `DuplicateBatch(groups:)` veniva ricostruito a ogni ridisegno).

`beginConfirmation()` fa `groups.filter { selectedHashes.contains($0.hash) }` e poi **`DuplicateBatch(groups: selected)`**, cioè **richiama `duplicateKeepChoice` su tutti i gruppi selezionati, sul main thread**. Oggi è innocuo per due ragioni che stanno per cadere insieme: la selezione è limitata da quanti clic una persona è disposta a fare, e la funzione è pura, quindi ricalcolarla dà lo stesso risultato. Con «seleziona tutti» diventa un ricalcolo di 27.798 gruppi sul main; con una regola dell'utente diventa anche un ricalcolo che **può dare un risultato diverso** da quello mostrato (§2.5).

`DuplicateBatch.folderBreakdown` raggruppa per **cartella genitrice completa** (`displayPath` meno l'ultimo componente): su questa libreria le copie in eccesso sono sparse su migliaia di `ASUS/foto/recup_dir.NN`, quindi `summaryLines()` produrrebbe **migliaia di righe** nel riepilogo. La prima delle due conferme è il punto dove sta tutto il peso della decisione (ADR-0005, decisione 4): illeggibile lì significa conferma a occhi chiusi.

### Il tetto

`duplicateBatchFileCap = 500` file, `duplicateBatchByteCap = 50 GB` (decimale), il primo che scatta; `DuplicateBatch.exceedsCap` con `>` (alla soglia esatta passa). Sopra il tetto `DuplicatesStatus.confirmationBlockedReason(exceedsCap:)` **blocca** il bottone «Continua…» del riepilogo e dice «procedi in più passaggi più piccoli». Il doc-comment del tetto dichiara il numero «ritarabile alla prima passata reale con l'SSD collegato».

Due cose che il tetto non sa, e che questa spec mette in relazione per la prima volta:

1. **Il registro di ripristino tiene 2.000 voci** (`TrashManifestStore.maxItems`) e pota **le più vecchie** (`suffix`). Un blocco più grande di 2.000 file poterebbe le voci **del blocco stesso** mentre lo sta scrivendo: «Annulla l'ultimo spostamento» rimetterebbe a posto solo l'ultima parte, senza saperlo e senza dirlo. È il vincolo duro sul tetto.
2. **`record` riscrive l'intero JSON a ogni file** (`JSONEncoder().encode(manifest).write(to:options:.atomic)`, più una `chmod`). Il costo è quadratico nel numero di voci vive: a 2.000 voci ogni file riscrive ~800 KB. Va **misurato** prima di alzare il tetto (Task 2 del piano), non stimato.

### L'annullamento

ADR-0009: **un solo livello.** «Annulla l'ultimo spostamento» rimette a posto `pendingInLastBatch()`, cioè le voci del **`batchId` scritto per ultimo** non ancora marcate. Un blocco più vecchio resta nel registro come storia e recuperabile solo a mano dal Cestino.

### L'importazione

`runImport` passa `refreshesLibraryIndex: true`, che accende il **passo 2** (ADR-0007): l'elenco si aggiorna **dopo** che l'importazione ha già deciso cosa copiare. Nessun punto del codice registra **quando** l'elenco è stato rimesso in pari per l'ultima volta: né una chiave `UserDefaults`, né una colonna. `LibraryIndexCard` mostra quante foto sono in elenco, non da quando.

`BackupRunner.isAlreadyInLibrary` cerca `store.entries(withHash:)` su **tutto** l'elenco e salta il candidato se una qualunque copia riverificata esiste sotto la root dell'SSD: nessuna nozione di cartella (§5).

---

## 2. Direzione 1 — selezione in massa e regola per cartella

### 2.1 Due meccanismi, due scopi (D1)

Il pannello guadagna **due** meccanismi distinti, e la spec dice quale copre cosa perché la tentazione è scriverne uno che prova a coprire tutto.

| Meccanismo | A cosa serve | Quanta parte della libreria |
| :--- | :--- | :--- |
| **Filtri + «Seleziona tutti quelli visibili»** | accettare in blocco la proposta che il codice **già calcola** | i gruppi interni a una cartella: **11.232 gruppi, 59.757 copie (66,7%)** — 11.082 di questi dentro `ASUS`, 150 dentro `Foto iPhone` |
| **Regola «tieni in X, cestina in Y…»** | decidere dove, fra due o più cartelle, la copia deve restare | le sovrapposizioni: ~16.150 gruppi, ~29.100 copie, **~131 GB** (insiemi misurati di §0; il resto sono combinazioni minori) |

Il primo **non** è un motore di decisione: è un gesto di assenso su `duplicateKeepChoice`. Il secondo entra **dentro** `duplicateKeepChoice`. Nessuno dei due nomina un sopravvissuto per conto proprio.

### 2.2 I filtri (D2)

Tre controlli discreti, nessun campo di testo (§2.8 per il perché):

1. **Cartella** — un menu con «Tutte» più le cartelle di primo livello **che compaiono davvero fra i membri dei gruppi**, con il conteggio accanto. L'elenco si ricava dai gruppi già in memoria, non da una query nuova: è anche l'insieme onesto (le cartelle che hanno doppioni, non quelle che esistono). Predicato: «il gruppo ha almeno una copia sotto questa cartella».
2. **Tipo di gruppo** — «Tutti» / «Tutte le copie nella stessa cartella» / «Copie in cartelle diverse». È il controllo che separa i due meccanismi di §2.1 e che rende raggiungibile in un gesto la fetta più numerosa della libreria.
3. **Solo i gruppi coperti dalla regola** — visibile solo quando una regola è attiva.

I tre predicati stanno in un tipo puro (`DuplicateFilter`), sono componibili in AND, e il risultato filtrato si calcola **fuori dal main** e si memorizza: si ricalcola solo quando il filtro cambia, mai a ogni ridisegno. È la stessa disciplina del `loadedBatch`.

### 2.3 Selezione in massa senza mentire (D3)

- **«Seleziona tutti quelli visibili»** e **«Togli la selezione da quelli visibili»**, entrambi sul **solo** insieme filtrato.
- **La selezione sopravvive al cambio di filtro** — serve a costruirla cartella per cartella — e quindi l'intestazione dice **sempre due numeri distinti**: quanti gruppi si vedono e quanti sono selezionati in tutto. Una riga che dicesse solo il visibile sarebbe falsa nel momento esatto in cui l'utente sta per confermare.
- Sotto la lista, una riga di selezione aggiornata in O(1) da valori precalcolati: «Selezionati N gruppi: M file da spostare, circa X GB recuperabili sull'SSD». Mai «hai recuperato» al passato (ADR-0005): lo spazio torna solo svuotando il Cestino.
- Se la selezione supera il tetto di un blocco, la riga **non** dice «troppi»: dice in quanti blocchi verrà fatta (§3).
- **Nessuna scorciatoia «seleziona tutto» senza filtro attivo.** Non per paternalismo: il gesto che seleziona 27.798 gruppi in un clic senza aver guardato niente è il gesto che questa spec esiste per non incoraggiare. Con il filtro su «Tutte» + «Tutti» il risultato è lo stesso, ma è stato chiesto.

### 2.4 La regola per cartella: forma, e dove si inserisce (D4)

**Forma.** Una cartella **da tenere** e un insieme di cartelle **da cestinare**, scelte fra quelle presenti (§2.2): «Tieni la copia in «Foto iPhone», sposta nel Cestino quelle in «Takeout» e «Takeout 2»».

**Quando un gruppo la soddisfa.** Almeno una copia sotto la cartella da tenere, e **tutte** le altre sotto una di quelle da cestinare. Se resta una copia in una terza cartella, **il gruppo non è coperto**: non si cestina una parte di gruppo. Il motivo non è estetico — il `DuplicateTrasher` smaltisce un gruppo tranne la copia tenuta, e introdurre «gruppo smaltito a metà» aggiunge uno stato che ricompare alla prossima apertura senza che nessuno capisca perché.

**Dove si inserisce.** Come **primo** filtro dentro `duplicateKeepChoice`, davanti alle sue tre regole:

```
0. la cartella che l'utente ha chiesto di tenere   ← nuovo, solo sui gruppi coperti
1. libreria principale
2. cartella organizzata invece che import
3. la più vecchia
4. tie-break deterministico (percorso più corto, poi ordine della chiave)
```

Precede, e **solo dove l'utente l'ha chiesto**: i gruppi non coperti conservano esattamente la proposta di oggi. Le regole 1-3 sono euristiche che l'app si è inventata per decidere quando nessuno le ha detto niente; un'istruzione esplicita vale più di un'euristica, un'euristica vale più del silenzio.

Quando **più** copie stanno nella cartella da tenere, fra loro decidono le regole 1-4 già esistenti, applicate ai soli sopravvissuti — esattamente come fa oggi `narrow`. **Nessun tie-break nuovo.**

**Conseguenze sul codice, tutte additive:**
- `duplicateKeepChoice(_ group:, rule:)` — parametro **senza default** (stessa disciplina di ADR-0009 sui quattro gate: un default silenzierebbe una dimenticanza invece di farla fallire in compilazione).
- `DuplicateKeepReason.userFolderRule` e la frase corrispondente in `duplicateKeepExplanation`: «Tengo la copia che si trova in «X»: hai chiesto di tenere le copie che stanno lì.» La clausola sul pari merito e il conteggio delle altre copie restano come sono.
- Un tipo puro `DuplicateFolderRule { keepIn: String, trashIn: Set<String> }`, con il confronto sulle **chiavi normalizzate** (minuscolo, NFC) e non su `displayPath`: ExFAT è case-insensitive e non normalizza l'Unicode, e una regola che dipende da come è scritto il nome sul disco è una regola che smette di funzionare senza dirlo. Lo stesso `topLevelFolderKey` già usato da `isInMainLibrary`.
- La regola **persiste** in `UserDefaults` (chiave nuova, JSON del valore): 45 blocchi non si fanno in una sessione, e una regola riscritta a memoria alla seconda sessione è un'altra regola.

**Una regola può contraddire «la libreria principale vince»** (per esempio «tieni in Takeout, cestina in Foto iPhone»). È ammesso — è l'utente a deciderlo — e non serve nessun avviso speciale: il riepilogo dice già quali cartelle perdono file e quante, che è l'informazione con cui accorgersene (§2.7).

### 2.5 I gruppi che la regola non copre (D5)

Sono la maggioranza e hanno **una risposta esplicita, non un silenzio**. Tre categorie, tutte visibili come tali:

1. **Tutte le copie nella stessa cartella** — 11.082 gruppi solo dentro `ASUS`, il caso più numeroso della libreria. Il filtro «Tutte le copie nella stessa cartella» li isola, e sopra la lista compare la riga che dice **con quale criterio** l'app ha scelto: «Queste copie stanno tutte nella stessa cartella: tengo quella con la data più vecchia e, a parità, quella col percorso più corto. Le copie sono identiche fra loro, quindi qualunque delle due si tenga il contenuto resta.» Poi «Seleziona tutti quelli visibili». **Non** «l'app ha scelto per te», che non è un'informazione.
2. **Copie in cartelle diverse, ma non quelle della regola** — restano con la proposta automatica; l'utente può aggiungere una seconda regola o selezionarli a mano.
3. **Gruppi con una terza cartella estranea** — esclusi dalla regola per costruzione (§2.4), contati nella riga di stato della regola: «La regola copre N gruppi; K hanno una copia anche in un'altra cartella e restano fuori.»

### 2.6 Il sottoinsieme non ricalcola la scelta (D6)

`beginConfirmation()` **non** ricostruisce più il blocco dai gruppi: lo ricava **filtrando le `Entry` già congelate** di `loadedBatch`, che portano dentro di sé la `choice`. Si ricalcolano solo i totali (`fileCount`, `reclaimableBytes`, la ripartizione per cartella, i tetti).

Non è un'ottimizzazione, è una correzione: oggi la rilettura è innocua **solo** perché `duplicateKeepChoice` è pura e l'input identico. Con una regola dell'utente che può cambiare fra la lista e la pressione del bottone, il ricalcolo può nominare un'altra copia — l'utente acconsente a cestinare A e viene cestinato B, che è precisamente ciò che il doc-comment di `DuplicateBatch` esiste per impedire.

Da cui: `DuplicateBatch` guadagna un costruttore `init(entries: [Entry])` che non chiama `duplicateKeepChoice` **nemmeno una volta**, e `init(groups:rule:)` resta il solo punto in cui la scelta si calcola.

**Cambiare la regola azzera la selezione**, ricostruisce il blocco una volta fuori dal main, e lo dice: una selezione fatta su una proposta e confermata su un'altra è lo stesso difetto visto dall'altro lato.

### 2.7 La ripartizione per cartella diventa di primo livello (D7)

`DuplicateBatch.folderBreakdown` passa dalla cartella genitrice completa alla **cartella di primo livello**, più una riga di coda che dice da quante cartelle diverse in tutto escono file. Motivo in §1: con migliaia di `recup_dir.NN` il riepilogo di oggi produce migliaia di righe.

Quattro test esistenti di `DuplicateBatchTests` cambiano **la stringa attesa**, non la proprietà verificata (`"Other/vecchie"` → `"Other"`, `"Import/Scheda"` → `"Import"`): la fusione dei gruppi che condividono una cartella, il conteggio delle sole copie che se ne vanno e il determinismo a pari conteggio restano esattamente ciò che verificano. **Autorizzato esplicitamente qui**, per la regola 6 dei piani di questo progetto.

### 2.8 Prestazioni: dove questo pannello si è già rotto una volta (D8)

Il pannello ha già pagato un bug di prestazioni per aver ricostruito `DuplicateBatch` a ogni ridisegno. Alla scala vera i punti da tenere d'occhio sono cinque, e la disciplina è sempre la stessa: **calcolare una volta, fuori dal main, e memorizzare**.

1. **Nessun `filter`, `map` o `reduce` su 27.798 gruppi dentro il `body`**, nemmeno indiretto. Filtro, selezione e totali sono `@State` precalcolati.
2. **Niente ricerca testuale** sui percorsi: 141.683 percorsi filtrati a ogni tasto premuto sono il profilo esatto del bug del 2026-09-02. Se un giorno servisse, si fa fuori dal main con un ritardo, non nel `body`.
3. **Il ricalcolo al cambio di filtro o di regola gira in `Task.detached`**, con uno stato «sto applicando…» al posto di una finestra che si ferma. `DuplicateFilter` e `DuplicateFolderRule` sono `nonisolated` e puri.
4. **La cache delle miniature resta a 200** e la lista resta `LazyVStack`: le righe non viste non leggono niente dal disco.
5. **La memoria è già quella di oggi**: 117.339 `LibraryIndexEntry` in RAM (~30 MB). Questo intervento non la aumenta — i filtri lavorano su indici, non su copie degli array.

---

## 3. Direzione 2 — il tetto ritarato e i blocchi concatenati

### 3.1 Il nuovo tetto, con l'argomento numerico (D9)

**`duplicateBatchFileCap`: 500 → 2.000. `duplicateBatchByteCap`: 50 GB, invariato.**

L'argomento non è «2.000 sembra ragionevole», sono tre vincoli che si incontrano:

- **Il registro fissa il massimo.** `TrashManifestStore.maxItems = 2000` con potatura delle voci più vecchie: sopra 2.000 file per blocco, il registro pota le voci **del blocco corrente** e l'annullamento copre solo la coda. Da cui un invariante nuovo, protetto da un test: **`duplicateBatchFileCap <= TrashManifestStore.maxItems`**.
- **Il tetto sui byte non è vincolante su questa libreria.** A 1,75 MB per copia in eccesso, 2.000 file sono ~3,5 GB: i 50 GB restano 14 volte più larghi (a 500 file erano 57 volte). Il tetto sui byte resta come guardia per una selezione fatta di video — che è il suo lavoro — e alzarlo non cambierebbe niente.
- **Un blocco al tetto costa ~55 secondi**: ~4,5 GB da rileggere (copie in eccesso più copie tenute) a 224 MiB/s ≈ 19 s, più 2.000 `trashItem` a 55,8 file/s ≈ 36 s. Il raggio di un guasto resta un minuto di lavoro, e il blocco è **interamente coperto** dall'annullamento automatico.

**Il tetto sui file non è più «un numero prudente»: è la granularità dell'annullamento automatico.** Dirlo così serve a chi un giorno volesse alzarlo di nuovo: la domanda da farsi non è «quanto tempo dura un blocco» ma «quante foto voglio poter rimettere a posto con un clic».

**Il numero è condizionato a una misura** (Task 2 del piano): `record` riscrive l'intero JSON a ogni file, quindi un blocco al tetto spende ~2.000 riscritture di file fino a ~800 KB. Se la misura dicesse che un blocco al tetto spende più di ~30 s nel solo registro, il tetto scende al valore che la misura consente. Si misura, non si ritocca a occhio.

### 3.2 Il piano della corsa (D10)

Una **corsa** è la sequenza ordinata di blocchi in cui si divide la selezione confermata. Un tipo puro nuovo, `DuplicateRunPlan`:

- divide `[DuplicateBatch.Entry]` in blocchi ai due tetti, **nell'ordine già deterministico del pannello** (spazio recuperabile decrescente, poi numero di copie, poi hash) — così il piano è riproducibile e i primi blocchi sono quelli che recuperano più spazio;
- riempie ogni blocco con la regola del «primo che scatta», e un gruppo non viene mai spezzato fra due blocchi;
- **un gruppo la cui dimensione da sola supera un tetto** finisce in un blocco da solo, e il piano lo dice: è l'unico caso in cui un blocco supera il tetto, e rifiutare il gruppo lo renderebbe inarrivabile per sempre;
- stima la durata dai due numeri misurati (224 MiB/s, 55,8 file/s), dichiarata come **circa** e mostrata con `FileSyncer.SyncResult.hms`, mai come una promessa.

### 3.3 Le due conferme, con il piano dentro (D11)

**Restano due** (decisione di Enrico), con tre righe in più nel riepilogo quando i blocchi sono più di uno:

1. «Lo faccio in **45 blocchi** da al massimo 2.000 file ciascuno. In tutto circa **40 minuti**: puoi fermarti alla fine di ogni blocco.»
2. «Se qualcosa va storto, **«Annulla l'ultimo spostamento» rimette a posto solo l'ultimo blocco** (fino a 2.000 foto). Le altre restano nel Cestino dell'SSD, da cui puoi rimetterle a posto dal Finder, e restano comunque sull'HDD e su Cubbit.»
3. La ripartizione per cartella di primo livello (§2.7), che a questa scala è l'unica cosa che permette di accorgersi in tempo di aver puntato la cartella sbagliata.

La riga 2 è la conseguenza di ADR-0009 (annullamento a un solo livello) portata in superficie **prima** dell'operazione. È il punto che il brief chiedeva di progettare e non di scoprire dopo: concatenare 45 blocchi con un annullamento che ne copre uno è accettabile **solo** se l'utente lo sa mentre conferma. La stessa frase, in forma breve, entra anche nell'alert distruttivo.

### 3.4 Progresso, stop, e quando la catena si ferma (D12)

- **Progresso a due livelli**: «Blocco 3 di 45 · 1.240 file su 59.591». Il secondo numero è il totale della corsa, non del blocco: una barra che riparte da zero 45 volte non dice niente.
- **«Interrompi» funziona a due granularità**: fra un gruppo e l'altro (il `CancelFlag` di oggi, invariato) e fra un blocco e l'altro. Fermarsi lascia una corsa parziale, che è uno stato legittimo e va raccontato come tale.
- **La catena si ferma da sola su un guasto vero**: un blocco che finisce con `stoppedBecauseVolumeVanished` **o** con un `trashFailed` interrompe la corsa. Sono guasti del volume, e proseguire su altri 40 blocchi moltiplicherebbe per 40 il raggio del danno.
- **I gruppi saltati dalla verifica non fermano niente**: hash non unanime, file illeggibile, non-media, copia tenuta sparita, «niente da cestinare». Su questa libreria sono la normalità — l'elenco contiene per decisione di prodotto voci di file che non esistono più (ADR-0002) — e fermarsi lì vorrebbe dire non arrivare mai in fondo. Finiscono **tutti** nel resoconto unico, contati e con il motivo, senza troncamenti silenziosi: se i motivi sono cento, si dice quanti sono per tipo e si elencano i primi, mai «e altri».
- **L'elenco si ricarica una volta sola, alla fine della corsa**, non dopo ogni blocco: le scelte dei blocchi successivi sono già congelate e il `DuplicateTrasher` rilegge comunque dal disco, quindi ricaricare a metà costerebbe minuti e non aggiungerebbe nessuna sicurezza.

### 3.5 Cosa sostituisce la protezione del blocco piccolo (D13)

Il tetto piccolo proteggeva dal **raggio di un guasto a metà blocco**. Con i blocchi concatenati il raggio da guardare non è più il blocco ma la **corsa**, e la protezione è composta da quattro cose, di cui una nuova:

1. **Il raggio per guasto non cambia**: la catena si ferma alla fine del blocco che ha avuto il guasto (D12), quindi un guasto tocca al massimo un blocco, come oggi.
2. **Il blocco è interamente coperto dall'annullamento automatico**, perché il tetto è ≤ al tetto del registro (D9). Oggi questa garanzia esisteva per caso; ora è un invariante con un test.
3. **`st_dev` a ogni fallimento** in `DuplicateTrasher` e in `TrashRestorer`: invariato, e continua a distinguere «il file non c'era» da «il volume è sparito».
4. **Nuovo: la storia degli spostamenti.** Un file append-only sul disco interno (mai sull'SSD, `0600`, accanto all'indice e al registro) su cui l'app scrive **una riga per blocco concluso**, con i percorsi originali delle foto di quel blocco. Non è un secondo annullamento e non aggiunge nessun percorso distruttivo: è la sola cosa che, dopo una corsa di 45 blocchi, permette di ritrovare a mano da dove venivano le foto che il registro ha potato. Costa **una scrittura per blocco**, non per file, quindi non riapre il costo quadratico di `record`.

Il punto 4 è la risposta alla domanda «cosa protegge al posto del cap piccolo», e vale la pena dire perché serve: il registro ricorda 2.000 voci, il record «Rimetti a posto» del Finder è asincrono e si perde (misurato: 74 su 300), e `trashItem` rinomina gli omonimi con un timestamp. Dopo una corsa da 89.541 file, senza la storia degli spostamenti il Cestino dell'SSD sarebbe una cartella piatta di foto di cui nessuno sa più il percorso d'origine. **Mitigante che esiste già e che non va dimenticato**: HDD e Cubbit conservano tutto per sempre, quindi nessuna foto è perduta in nessun caso — la storia serve a rimetterle *dove stavano*, non a non perderle.

### 3.6 Prerequisito: ROADMAP #41 (D14)

`trashProgress` e `activeCancelFlag` sono ancora `@State` di `DuplicatesView`: chiudere e riaprire la finestra durante uno spostamento fa perdere barra e «Interrompi» (#41, spec e piano del 2026-09-20 già scritti, non ancora eseguiti). Oggi il danno è limitato perché un blocco dura ~10 secondi. Con una corsa da 40 minuti diventa: **un'operazione a danno alto, lunga decine di minuti, che l'utente non può più fermare.**

**#41 va prima.** Le alternative — assorbirlo in questo piano, o consegnare la concatenazione senza — sono peggiori: la prima mescola due interventi con due spec, la seconda consegna un difetto noto amplificato. È un punto da confermare con Enrico (§11).

---

## 4. Direzione 3 — l'elenco dice da quando non è aggiornato

### 4.1 Da dove viene la data (D15)

Una chiave `UserDefaults` nuova con **l'istante dell'ultima lettura arrivata in fondo**, scritta in **un punto solo**: il `onFinish` di `startLibraryIndexScan`, dove la completezza è già nota. Non si scrive se la lettura è stata interrotta o è incompleta (`traversalIncomplete`, `cancelled`, `volumeVanished`): non ha rimesso in pari l'elenco, e registrarla direbbe il contrario. Vale per **tutti** gli ingressi, passo 2 compreso, perché passano già tutti da quella funzione. `deleteIndexAndRecreate` la azzera.

**Perché non `MAX(hashed_at)`** come sorgente principale: una lettura incrementale che non trova niente di nuovo non tocca nessun `hashed_at`, quindi risponderebbe «tre settimane» un minuto dopo aver rimesso in pari l'elenco. Resta come **ripiego dichiarato** per gli elenchi costruiti prima di questa versione (un metodo nuovo sullo store, letto fuori dal main una volta sola all'apertura del wizard). È un limite inferiore: può solo far sembrare l'elenco più vecchio di quanto è, cioè al più un avviso di troppo, mai un avviso taciuto.

### 4.2 La soglia (D16)

**14 giorni.** Sotto, l'app dice solo la data. Sopra, la dice come avviso e offre di aggiornare.

L'argomento è l'asimmetria fra i due errori: a 30 giorni — la soglia dell'altro stantìo del progetto, il deep checksum del mirror — con il ritmo reale di backup l'avviso non comparirebbe quasi mai e sarebbe decorativo; a 2-3 giorni comparirebbe sempre, e «sovrastimare i problemi insegna a ignorare l'allarme» è un principio già applicato in questo progetto (ADR-0007). Due settimane è abbastanza per aver dimenticato di aver copiato qualcosa dal Finder, abbastanza poco perché rimediare costi pochi minuti. **30 giorni resta l'alternativa da mettere davanti a Enrico** (§11).

### 4.3 I testi, senza le parole vietate (D17)

Un tipo puro nuovo, `LibraryListFreshness`, usato **sia** dal passo di anteprima del wizard **sia** dalla card di Diagnostica: una sola fonte per il testo, come `LibraryIndexStatus` e `DuplicatesStatus`. Cinque diramazioni, non due:

1. **Elenco mai creato** — «Non hai ancora creato l'elenco delle foto già salvate sull'SSD: l'app non può sapere quali di queste foto hai già, e le copierà tutte.» Tono: avviso. È l'unica diramazione in cui il numero dell'anteprima è *giusto* e il risultato *indesiderato*.
2. **Aggiornato di recente** (sotto soglia) — «L'elenco delle foto già sull'SSD è aggiornato a martedì 21 settembre.» Tono: neutro.
3. **Non aggiornato da un po'** (sopra soglia) — «L'elenco delle foto già sull'SSD è fermo al 21 settembre, tre settimane fa. Se da allora hai copiato foto sull'SSD dal Finder, l'app non le conosce e potrebbe importarle di nuovo.» Tono: avviso. Con l'offerta (D18).
4. **Data non disponibile** (ripiego di §4.1 non utilizzabile) — «L'app non sa da quando l'elenco delle foto già sull'SSD non viene rimesso in pari.» Tono: neutro, con la stessa offerta.
5. **Lettura in corso** — «L'app sta controllando l'SSD per rimettere in pari l'elenco: aspetta che finisca.» Tono: neutro; il bottone di avvio è già disattivato da `JobStartGate`.

Nessuna delle frasi contiene «indice», «hash», «scansione», «registro» o «cache». Le date si scrivono in parole come già fa la conferma dell'annullamento («spostate il 2 settembre»).

### 4.4 L'offerta (D18)

Nel passo di anteprima, accanto all'avviso: **«Aggiorna l'elenco adesso»** e **«Continua così»**.

- «Aggiorna l'elenco adesso» chiama `startLibraryIndexScan(full: false, ...)` — **l'aggiornamento incrementale, non la ricostruzione completa.** `ignoringStoredHashes` rilegge e rihasha tutto (~28 minuti oggi) e non serve a niente per questo problema; resta dov'è, in Diagnostica, come azione esplicita.
- È il **terzo ingresso** sopra `startLibraryIndexScan` e non duplica nessuna decisione. La mutua esclusione è già scritta: `JobStartGate` impedisce l'avvio dell'importazione durante una lettura, e `LibraryIndexCommandGate` impedisce la lettura durante un job.
- **A lettura finita l'anteprima si rifà**, perché l'insieme dei doppioni riconosciuti è cambiato. Non mostrare un numero calcolato prima dell'aggiornamento è tutto il punto dell'avviso.
- **Nessuna promessa di durata**: l'aggiornamento incrementale su 141.683 voci non è mai stato cronometrato. Il testo dice cosa fa l'app, non quanto ci mette, finché non c'è una misura (§9).
- Se l'SSD si scollega durante l'aggiornamento, valgono i percorsi di oggi: la lettura si ferma, la data **non** si aggiorna (§4.1), e il wizard mostra il motivo scritto che già ha (`ImportPreviewStatus.unavailableReason`).

### 4.5 Un numero da correggere (D19)

`LibraryIndexCard.durata` dice «di solito servono dai 15 ai 25 minuti»: era il numero misurato su 237,4 GiB il 2026-09-01. L'elenco oggi copre **390,6 GB**, che a 224 MiB/s sono **~28 minuti**. Il doc-comment dice già «se il contenuto dell'SSD cambia sensibilmente, si rimisura: non si ritocca a occhio» — è cambiato, e il testo va aggiornato con il numero derivato dai byte reali.

---

## 5. Il quarto filone — il dedup in importazione è cieco alla cartella (NON in questo piano)

**Non è nel piano, e non è nemmeno silenziato.** Richiede una decisione di prodotto di Enrico e un ADR proprio.

`BackupRunner.isAlreadyInLibrary` salta un candidato se **qualunque** copia riverificata esiste sotto la root dell'SSD. Nessuna nozione di «libreria principale»: `mainLibraryFolderKey` e le tre regole di `duplicateKeepChoice` vivono solo nel pannello Doppioni.

**Cosa succede ora che `ASUS/` esiste.** Enrico importa il rullino dell'iPhone e una foto viene **saltata** perché il suo contenuto esiste già come `ASUS/foto/recup_dir.69/f248392008.jpg`. Nessun byte è perso, e la foto è anche sull'HDD e su Cubbit. Ma non entra in `Foto iPhone/`: resta solo col nome generato da PhotoRec dentro un dump di recupero. È l'opposto dell'intento — il dedup serve a non ricopiare la stessa foto nella stessa libreria, non a impedire a una foto di entrare nella libreria principale perché ne esiste una scheggia carvata altrove.

**Opzioni, con il verso del rischio segnato.**

- **S4-A. Nessun cambiamento.** Zero rischio, lo scenario fondatore di #31 intatto, il difetto resta.
- **S4-B. Dedup limitato alla cartella di destinazione.** Un import in `Import/2026-09` non salterebbe più ciò che sta in `Foto iPhone/`: ricopierebbe interi rullini. **Da scartare.**
- **S4-C. Una nozione di «cartelle che contano come libreria»**, con `ASUS/` (o i soli `recup_dir.*`) fuori. Direzione **sicura** (restringe il dedup ⇒ più copie, mai meno), chiude il difetto, e non tocca lo scenario fondatore: un reimport della stessa scheda in `Import/<etichetta B>` continua a saltare ciò che sta in `Import/<etichetta A>`, perché `Import/` conta.
- **S4-D. La stessa gerarchia del pannello.** Elegante sulla carta, ma per risolvere il caso reale dovrebbe **declassare `ASUS`** — che è esattamente ciò che Enrico ha rifiutato il 2026-09-24. Equivale a S4-C con più accoppiamento.
- **S4-E. Nessun cambio di politica, ma rendere visibile lo skip.** L'anteprima dice già «N file sono già presenti sull'SSD»; direbbe anche **dove**: «di questi, 312 esistono solo dentro «ASUS»». Informazione, non politica: l'utente decide. Richiede che `importPreviewDuplicates` riporti la cartella della copia che ha fatto scattare lo skip.

**L'asimmetria che rende questa domanda diversa da quella già chiusa su `ASUS`.** Nel pannello, declassare `ASUS` significherebbe **cestinare** le sue copie: Enrico ha detto no, e il costo di sbagliare è una foto nel Cestino. Nell'importazione, trattare `ASUS` come «non conta» significa **copiare un file in più**: il costo di sbagliare è un doppione, cioè il verso sicuro che tutto quel file già codifica («nel dubbio si copia, mai si salta»). **L'argomento rifiutato là non si trasferisce automaticamente qui, perché il costo dell'errore è opposto.** Va detto a Enrico così, e deciso da lui.

**Raccomandazione:** **S4-E prima, S4-C solo se Enrico lo chiede**, in una spec a sé. S4-E non cambia nessuna decisione, è reversibile e produce l'informazione con cui decidere se serve S4-C. Qualunque cosa si scelga vale **da un punto solo** per l'import e per l'anteprima, perché l'anteprima riusa lo stesso predicato per decisione di prodotto («l'anteprima non è un'approssimazione dell'import, è lo stesso predicato»).

---

## 6. Cosa NON cambia

- **`DuplicateTrasher.verify`**: nessun diff. Rilettura e rihash di ogni membro, copia tenuta compresa, unanimità per gruppo, `st_dev` a ogni fallimento, registro scritto file per file.
- **`DuplicateTrasher.run`**: nessun diff. Continua a smaltire **un** blocco; è il chiamante che gliene passa 45 di fila.
- **Il formato del registro di ripristino.** `TrashedItem`, `maxItems = 2000`, `pendingInLastBatch()`, `restorableSummary()`: esattamente come li ha lasciati ADR-0009. La storia degli spostamenti (§3.5) è un **file a parte**, non un campo in più.
- **L'annullamento resta a un solo livello** (ADR-0009). Nessun annullamento a più livelli, nessuna coda di blocchi annullabili.
- **Le due conferme** (riepilogo dettagliato, poi alert distruttivo).
- **Il tetto sui byte**: 50 GB, decimale.
- **`duplicateGroups()`**: nessuna query nuova, nessun `ORDER BY` diverso, `size > 0` in entrambi i punti. I filtri lavorano in memoria sui gruppi già letti.
- **L'ordinamento dei gruppi** nel pannello (spazio recuperabile, poi copie, poi hash) e il **tie-break** di `duplicateKeepChoice` (percorso più corto in byte UTF-8, poi ordine della chiave).
- **`Takeout/`, `Takeout 2/`, `ASUS/` restano di pari dignità.** Nessun declassamento a priori, nessun riconoscimento di `recup_dir.*` come «cartella di scarto».
- **La cache delle miniature** (200) e la `LazyVStack`.
- **`ImportSessionIndex`** e il dedup interno allo stesso import.
- **La lettura automatica al collegamento dell'SSD resta rimossa** (ADR-0007): l'avviso di §4 non la reintroduce.
- **Zero delete altrove.** Nessun `removeItem`, nessun `trashItem` nuovo, nessuna richiesta S3 nuova. L'unico `moveItem` sui file foto resta quello del ripristino dal Cestino.
- **Svuotare il Cestino dall'app resta fuori scope, permanentemente** (ADR-0005).

---

## 7. Test

Tutta la logica nuova è **pura** e testabile senza aprire una finestra. Le View restano dichiarate non coperte, come già `LibraryIndexCard` e `DuplicatesView`.

| File | Cosa copre | Ordine di grandezza |
| :--- | :--- | ---: |
| `DuplicateFolderRuleTests` (nuovo) | quali gruppi la regola copre e quali no (terza cartella, cartella assente, tutte le copie nella cartella da tenere), confronto su chiavi normalizzate, persistenza | ~16 |
| `DuplicateKeepChoiceTests` (esteso) | la regola precede le tre esistenti; non cambia niente sui gruppi non coperti; `userFolderRule` come motivo; il tie-break dentro la cartella tenuta resta quello di prima | +~10 |
| `DuplicateFilterTests` (nuovo) | i tre predicati, la composizione in AND, l'elenco delle cartelle ricavato dai gruppi, gruppi interni vs incrociati | ~14 |
| `DuplicateBatchTests` (esteso) | `init(entries:)` non ricalcola la scelta; ripartizione per cartella di primo livello; 4 stringhe attese aggiornate (§2.7) | +~8 |
| `DuplicateRunPlanTests` (nuovo) | divisione ai due tetti, gruppo mai spezzato, gruppo più grande del tetto in un blocco da solo, ordine deterministico, stima della durata, corsa vuota | ~18 |
| `DuplicatesStatusTests` (esteso) | riga di selezione (visibile vs selezionato), piano della corsa, frase sull'annullamento a un livello, progresso a due livelli, resoconto aggregato; **le 3 asserzioni su `confirmationBlockedReason` sono sostituite** (§11, punto 5) | +~16 |
| `TrashHistoryTests` (nuovo) | una riga per blocco, append-only, `0600`, posizione consentita, un file illeggibile non fa fallire niente | ~10 |
| `DuplicateCapInvariantTests` (nuovo) | **`duplicateBatchFileCap <= TrashManifestStore.maxItems`** | 1 |
| `LibraryListFreshnessTests` (nuovo) | le 5 diramazioni, la soglia ai due bordi, plurali e date in parole, **nessuna parola vietata** | ~18 |
| `LibraryIndexStatusTests` (esteso) | la data si scrive solo a lettura completa; non si scrive su interruzione/incompletezza; si azzera con lo svuotamento | +~8 |
| `MainThreadIsolationTests` (esteso) | filtro, regola, piano della corsa e storia degli spostamenti girano senza il main thread | +~4 |

**Un test che non deve esistere**: nessun test che verifichi la selezione in massa *saltando* la verifica. Se un test della selezione in massa non passa per il `DuplicateTrasher` vero (o per il suo doppio con `trashFunction`/`hashFunction` iniettate), sta verificando qualcosa che non è la feature.

**Registro anti-gergo**: come già per `LibraryIndexStatus`, il test sul gergo deve coprire **tutte** le diramazioni dei testi nuovi, non un campione. Il progetto ha già pagato una volta un registro verificato su 6 diramazioni su 10.

---

## 8. Rischi

1. **Il rischio principale è il gesto stesso.** Un clic che seleziona 11.082 gruppi è un clic che sposta 59.591 foto. La difesa non è tecnica: sono le due conferme, la ripartizione per cartella, «Mostra nel Finder» su ogni riga, i badge RESTA/NEL CESTINO, e la verifica per gruppo che non si tocca. Se in review qualcosa di tutto questo appare «ridondante alla scala grande», la risposta è no: alla scala grande serve più di prima.
2. **Una regola sbagliata sbaglia su migliaia di gruppi in un colpo.** Mitigato dal fatto che la regola **seleziona e propone**, non esegue: fra la regola e il Cestino ci sono ancora due conferme e un riepilogo che dice quali cartelle perdono file. Un modo per accorgersene prima: dopo aver applicato una regola, guardare la ripartizione per cartella nel riepilogo, che è esattamente lì per questo.
3. **Il ricalcolo al cambio di regola su 27.798 gruppi** può durare abbastanza da sembrare un blocco. Mitigato con lo stato «sto applicando…» e il lavoro in `Task.detached`. Da misurare (Task 1).
4. **Il costo di scrittura del registro a 2.000 voci** non è misurato, ed è il motivo per cui il nuovo tetto è condizionato (D9).
5. **Una corsa da 40 minuti tiene fermi tutti gli altri backup** (`isTrashingDuplicates` in `JobStartGate`). È coerente con la mutua esclusione esistente, ma è un fatto nuovo per durata: va nel riepilogo.
6. **Il tetto delle 55,8 file/s è stato misurato su un'immagine disco**, non sull'SSD vero via FSKit. La stima della durata della corsa ne dipende; per questo è dichiarata come «circa» e verrà corretta dopo la prima corsa reale.
7. **`ASUS` non è nei backup documentati del progetto.** Il mirror SSD → HDD verificato cartella per cartella il 2026-09-01 riguardava cinque cartelle e 47.482 media; **nessuno ha verificato che `ASUS/` sia sull'HDD.** La frase «le copie sull'HDD e su Cubbit restano dove sono» resta vera (i mirror non cancellano), ma la rassicurazione implicita «comunque ce l'hai anche altrove» **non è verificata per `ASUS`**. Va detto a Enrico (§11) e verificato prima di una corsa grande su quella cartella.

---

## 9. Verifiche manuali (con Enrico, SSD collegato)

1. **Misura dell'aggiornamento incrementale dell'elenco** su 141.683 voci, dall'app: è il numero che manca per poter (eventualmente) dare una durata nell'offerta di §4.4.
2. **Misura della prima corsa reale**: durata per blocco, file/s effettivi di `trashItem` sull'SSD via FSKit, tempo speso nel registro. Poi si correggono le costanti della stima.
3. **Selezione in massa su un filtro piccolo e verificabile** (per esempio `Foto iPhone` da sola: 150 gruppi, 166 copie, 3,8 GB) **prima** di qualunque corsa grande, con controllo nel Finder di 3-4 gruppi presi a mano.
4. **Interruzione a metà corsa** e lettura del resoconto: i numeri dei blocchi già fatti devono tornare.
5. **«Annulla l'ultimo spostamento» dopo una corsa di più blocchi**: deve rimettere a posto l'ultimo blocco e **dire** che gli altri restano nel Cestino.
6. **Scollegamento dell'SSD a metà corsa** (a freddo, su una selezione piccola): la catena si deve fermare, il resoconto deve dire quanti file erano già stati spostati, e la data dell'elenco non deve aggiornarsi.
7. **Avviso di elenco non aggiornato**: aprire il wizard di importazione con l'elenco vecchio di più di 14 giorni e verificare che l'avviso compaia **in quella finestra** (stessa classe della verifica ancora aperta su `AlertSink` in Diagnostica).
8. **Verificare se `ASUS/` esiste sull'HDD** (rischio 7).

---

## 10. Scoperte collaterali (fuori scope, non corrette qui)

1. **`Takeout` è passata da 13.139 a 13.138 voci** fra il 2026-09-01 e oggi. Una voce in meno in una cartella che nessuno ha toccato: non allarmante (l'indice tiene le voci sparite per scelta, quindi una voce *in meno* è una rimozione passata da `remove(keys:)`, cioè da un cestinamento riuscito), ma vale la pena sapere che è successo.
2. **L'elenco è cresciuto da 237,4 GiB a 390,6 GB** senza che nessun documento lo registrasse. Il numero di `LibraryIndexCard.durata` ne è la conseguenza visibile (§4.5); la conseguenza invisibile è che tutte le stime di durata scritte nei documenti del 2026-09-01 valgono per una libreria che non esiste più.
3. **`Zip/` non compare fra le cartelle dell'elenco**, coerentemente (gli zip non sono media). Utile ricordarlo: il campione d'integrità però li legge, e lì stanno file da 40-50 GB.
4. **3 file da 0 byte** sono nell'elenco e già esclusi dai gruppi. Non sono un problema; sono la dimostrazione che la doppia guardia `size > 0` di `duplicateGroupsUnsynchronized` serve davvero.

---

## 11. Domande aperte per Enrico (con raccomandazione)

1. **#41 prima?** La concatenazione dei blocchi consegna un'operazione da decine di minuti; senza #41, chiudere la finestra Doppioni fa perdere barra e «Interrompi». **Raccomandazione: eseguire #41 prima di questo piano** (spec e piano esistono già). Alternativa: assorbirlo qui, mescolando due interventi.
2. **Il tetto a 2.000 file** (= tetto del registro), byte invariati a 50 GB, con la misura del costo del registro come condizione. **Raccomandazione: sì.** Se preferisci un tetto più basso (1.000), la corsa diventa 90 blocchi invece di 45 e l'annullamento copre metà delle foto.
3. **La storia degli spostamenti** (§3.5, punto 4): un file in più sul disco interno, una riga per blocco, nessun bottone. **Raccomandazione: sì** — è ciò che sostituisce la protezione del blocco piccolo. Se la consideri superflua perché HDD e Cubbit conservano tutto, si può togliere: la conseguenza è che dopo una corsa grande i percorsi d'origine delle foto nel Cestino si perdono.
4. **La soglia dell'avviso: 14 giorni** (raccomandata) **o 30** (coerente con il deep checksum del mirror)?
5. **`DuplicatesStatus.confirmationBlockedReason(exceedsCap:)` viene sostituita** dal testo che descrive il piano della corsa: tre asserzioni esistenti in `DuplicatesStatusTests` cambiano. È un cambio di contratto deliberato, non una svista — **serve il tuo assenso** perché la regola del progetto è che un'asserzione esistente non si cambia.
6. **La regola per cartella persiste fra le sessioni** (`UserDefaults`). **Raccomandazione: sì**; l'alternativa (solo per la sessione) evita una chiave nuova ma fa ripartire da zero ogni volta.
7. **Il quarto filone (§5)**: vuoi che il dedup in importazione smetta di essere cieco alla cartella? **Raccomandazione: prima S4-E** (rendere visibile *dove* sta la copia che fa saltare il file), in una spec a sé. S4-C (una nozione di «cartelle che contano») è la correzione vera, va nella direzione sicura, e richiede un ADR proprio.
8. **`ASUS/` è sull'HDD?** (rischio 7). Se non lo è, quella cartella non ha un mirror, e una corsa grande su di lei va fatta dopo averlo verificato.
