# ADR-0011 — Una sola scelta di quale copia tenere, anche con la selezione in massa

**Data:** 2026-09-24
**Stato:** Accettata

## Contesto

La prima passata reale sull'elenco dell'SSD ha dato i numeri che il pannello Doppioni non aveva ancora mai visto: **141.683 voci, 27.798 gruppi, 89.541 copie in eccesso, 156,3 GB recuperabili**. Il pannello oggi ha **un clic per gruppo** (`DuplicatesView.toggleSelection(_ hash:)`), nessun filtro e nessun «seleziona tutti»: per smaltire quella libreria servono ~90.000 clic distribuiti su ~180 blocchi. La feature è completa e corretta, e alla scala vera è inutilizzabile.

Due fatti misurati che decidono la forma della soluzione:

1. **Due terzi del lavoro non hanno niente a che fare con le cartelle.** 11.082 gruppi (59.591 copie, 19,3 GB) hanno **tutte** le copie dentro `ASUS/`, in gran parte sotto `ASUS/foto/recup_dir.NN/` — un recupero PhotoRec da un PC morto, con nomi generati dal tool (`f200571080.jpg`, `t200571016.jpg`). Per questi gruppi una regola «tieni in X, cestina in Y» **non può dire niente**: non c'è nessuna X e nessuna Y. Ma `duplicateKeepChoice` ha già un vincitore deterministico per loro (data più vecchia, poi tie-break sul percorso), e le copie sono identiche per definizione di gruppo.
2. **Le sovrapposizioni fra cartelle sono il resto**, e lì la scelta ha un contenuto: `{Takeout, Foto Google Drive, ASUS}` 2.262 gruppi per **48,4 GB** (il maggior recupero in byte dell'intera libreria), `{Takeout, Foto iPhone}` 5.367 gruppi, `{Takeout 2, Foto iPhone}` 3.383.

Il vincolo che stringe il design è scritto nel doc-comment di `DuplicateBatch`: la scelta di quale copia tenere **si calcola una volta sola** e viaggia congelata fino al `DuplicateTrasher`, perché fra il riepilogo che l'utente legge e il cestinamento l'indice può cambiare e una scelta ricalcolata può nominare **un'altra copia** — l'utente acconsente a cestinare A e viene cestinato B. Il progetto ha già pagato tre volte la classe di errore «due copie della stessa decisione» (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).

**Decisione già chiusa e non riaperta qui** (2026-09-24, Enrico): `ASUS/` è una cartella di **pari dignità**, come `Takeout/` e `Takeout 2/` (2026-09-01). Nessun declassamento di `recup_dir.*`, nessuna regola che la consideri scarto a priori: l'origine automatica non dice niente sul valore del contenuto. 17.101 contenuti esistono **solo** dentro `ASUS/`, per 32,5 GB.

## Opzioni valutate

**A. Un ordine di priorità fra le cartelle di primo livello, che l'utente riordina, applicato come regola 0 a tutti i gruppi.** Un solo meccanismo per tutto. Scartata per due motivi: scavalca in silenzio la regola «la libreria principale vince» su **tutti** i gruppi, compresi quelli su cui l'utente non stava pensando; e obbliga a ragionare su un ordine totale fra sette cartelle per esprimere un'intenzione che di solito riguarda due.

**B. Un secondo motore di decisione a valle di `duplicateKeepChoice`**, che riscrive la copia tenuta dei gruppi che soddisfano la regola. Scartata senza discussione: è letteralmente la seconda copia della decisione che il doc-comment di `DuplicateBatch` esiste per impedire. Due funzioni che nominano il sopravvissuto divergono alla prima modifica di una sola delle due, e qui il prezzo della divergenza è una foto nel Cestino al posto di un'altra.

**C. Due meccanismi con due scopi, e una sola scelta (scelta).** (1) **Filtri + «seleziona tutti quelli visibili»**, che accettano in blocco la proposta che il codice già calcola: è il gesto per i gruppi interni a una cartella, cioè i due terzi del lavoro. (2) **Una regola per cartella nella forma «tieni la copia in X, cestina quelle in Y…»**, che entra **dentro** `duplicateKeepChoice` come un filtro in più prima delle sue tre regole, non dopo. Un solo motore, un solo punto in cui si nomina il sopravvissuto, un motivo in più (`DuplicateKeepReason`) e una frase in più in `duplicateKeepExplanation`.

**D. Un filtro testuale sui percorsi.** Scartata per questa passata: cercare su 141.683 percorsi a ogni tasto premuto è il profilo esatto del bug di prestazioni già pagato in questo pannello il 2026-09-02. I filtri sono controlli discreti (cartella, tipo di gruppo), il cui risultato si ricalcola fuori dal main solo quando il filtro cambia.

## Decisione e motivo

**Opzione C.** La regola dell'utente **precede** le tre regole esistenti, ma **solo sui gruppi che la soddisfano**; tutti gli altri conservano esattamente la proposta di oggi. È la risposta alla domanda «la regola dell'utente sostituisce, precede o segue le regole dell'app?»: **precede, e solo dove l'utente l'ha chiesto.** Le tre regole dell'app sono euristiche che l'app si è inventata per decidere quando nessuno le ha detto niente; un'istruzione esplicita dell'utente vale più di un'euristica, e un'euristica vale più del silenzio.

Forma esatta della regola: **una cartella da tenere e un insieme di cartelle da cestinare**. Un gruppo la soddisfa se ha **almeno una** copia sotto la cartella da tenere e **tutte** le altre sotto una di quelle da cestinare. Se resta una copia in una terza cartella, il gruppo **non** è coperto: non si cestina una parte di gruppo. Questo tiene intatto il contratto del `DuplicateTrasher` (un gruppo si smaltisce tutto tranne la copia tenuta) e evita di introdurre lo stato «gruppo smaltito a metà», che ricomparirebbe alla prossima apertura senza che nessuno capisca perché.

Quando più copie stanno nella cartella da tenere, **fra loro decide la gerarchia esistente**, non una regola nuova: la regola dell'utente è un `narrow(candidates.filter { è sotto X }, .userFolderRule)` messo davanti agli altri tre. Nessun tie-break nuovo, nessuna aritmetica nuova.

**I gruppi che la regola non copre hanno una risposta esplicita, non un silenzio.** Il pannello dice quanti sono, li si può isolare con un filtro («tutte le copie nella stessa cartella») e accettarne la proposta automatica in blocco. La frase che l'utente legge dice *quale* criterio ha deciso (la data più vecchia, e a parità il percorso più corto) e che le copie sono comunque identiche fra loro. Non «l'app ha scelto», che non è un'informazione.

**Il sottoinsieme non ricalcola niente.** `beginConfirmation()` oggi ricostruisce un `DuplicateBatch` dai gruppi selezionati, e quindi richiama `duplicateKeepChoice`: con una regola dell'utente che può cambiare fra la lista e la conferma, quel ricalcolo è esattamente il modo in cui l'utente confermerebbe A e vedrebbe cestinato B. Il blocco da confermare si ricava **filtrando le `Entry` già congelate**, che portano dentro di sé la scelta; si ricalcolano solo i totali. Cambiare la regola **azzera la selezione** e la ricostruisce, una volta, fuori dal main, dicendolo.

**Cosa si accetta di perdere.** Una regola per cartella non copre i gruppi che pescano da tre cartelle di cui due da cestinare e una terza estranea: restano da fare con una seconda regola o a mano. La regola non è memoria di lungo periodo del *perché* (il registro di ripristino registra i file spostati, non la regola che li ha scelti). E il filtro testuale non c'è: si filtra per cartella e per tipo di gruppo, non per nome di file.

**Per riaprire questa decisione** serve un argomento nuovo: per esempio una passata reale in cui Enrico si accorge che la forma «tieni in X, cestina in Y» lo costringe a ripetere la stessa operazione su decine di coppie di cartelle, e che un ordine di priorità globale (opzione A) gliela farebbe esprimere una volta sola.

## Conseguenze

- `duplicateKeepChoice` guadagna un parametro **senza default** (`rule: DuplicateFolderRule?`) e `DuplicateKeepReason` un caso (`userFolderRule`); `duplicateKeepExplanation` una frase. I chiamanti esistenti nei test aggiornano la chiamata, **non** ciò che asseriscono.
- `DuplicateBatch` guadagna un costruttore che parte da `[Entry]` già congelate (per il sottoinsieme) e la regola nel costruttore da gruppi. `folderBreakdown` passa dalla cartella genitrice completa alla **cartella di primo livello**: con 89.541 file sparsi su migliaia di `recup_dir.NN`, il riepilogo di oggi produrrebbe migliaia di righe, cioè la prima delle due conferme diventerebbe illeggibile proprio dove sta tutto il peso della conferma (ADR-0005, decisione 4).
- Tre filtri puri (cartella, gruppi interni/incrociati, gruppi coperti dalla regola), applicati fuori dal main e ricalcolati solo al cambio di filtro. Nessuna piega nuova nel `body`.
- La selezione sopravvive al cambio di filtro, quindi l'intestazione dice **sempre** il totale selezionato, non il visibile: «vedi N gruppi su 27.798, ne hai selezionati M».
- Nessuno schema SQLite nuovo. La regola per cartella **persiste** in `UserDefaults` (chiave nuova): la stessa libreria si smaltisce in più sessioni, e una regola riscritta a memoria alla seconda sessione è un'altra regola.
- ADR-0001 (doppione = byte-identico), ADR-0002, ADR-0003 e ADR-0005 invariati. La rilettura e il rihash unanime di ogni membro, la copia tenuta compresa, **non si toccano**: la selezione in massa moltiplica i gruppi confermati, non salta una sola verifica.

## Risposta di Enrico (2026-09-24, domanda 6 della spec §11)

**«La regola per cartella persiste fra le sessioni?» → sì, in `UserDefaults`, non solo per la sessione.** Motivo di Enrico: 45 blocchi non si fanno in una sessione, quindi una regola che sopravvive solo mentre l'app è aperta obbligherebbe a riscriverla identica a ogni riapertura. Questo chiude l'ultimo punto aperto di questa ADR e la porta da Proposta ad Accettata.
