# Due livelli di fiducia sullo stesso indice

La terna `(percorso, dimensione, mtime)` non è una garanzia che il contenuto di un file non sia cambiato: `mtime` è riscrivibile da userspace (exiftool, `rsync -t`, restore da Finder). restic e borg si irrobustiscono con inode e ctime, ma **su ExFAT l'inode non è stabile** (documentato da Apple DTS), quindi quel rinforzo qui non esiste: la nostra chiave di invalidazione è **strutturalmente più debole** della loro, non equivalente.

Invece di inseguire una chiave perfetta, abbiamo deciso che **lo stesso indice si usa con due livelli di fiducia diversi**, perché il costo di un errore non è lo stesso nei due usi:

- **Segnalazione nel pannello Doppioni** (basso danno): ci si fida della cache. Un hash stantio produce una riga sbagliata in un elenco.
- **Skip durante un import** (alto danno): **non ci si fida**. Il file candidato sull'SSD viene riletto e rihashato prima di decidere lo skip, perché un hash stantio qui significa una foto non importata in silenzio.

Costa la lettura di un solo file per candidato duplicato — trascurabile, dato che il file sorgente va comunque letto per hasharlo.

## Conseguenze

Chi legge il codice dell'import troverà una rilettura che "sembra ridondante", visto che l'indice ha già la risposta. Non lo è: è questa decisione. Non rimuoverla per ottimizzare.

A rinforzo, tre difese: la regola anti-racy (da git/borg), la tolleranza DST sugli shift di 3600s/1800s (**senza prior art, scelta di questo progetto**) e la modalità di verifica completa.

## Nota (2026-08-25): la regola DST ha un verdetto proprio, e serve

Nella prima stesura di questa ADR lo shift di fuso e il dubbio anti-racy producevano lo **stesso** verdetto `.needsVerification`, e lo scanner li trattava in modo identico: entrambi portavano al rehash. Il Critic ha fatto notare che così la regola DST **non aveva alcun effetto osservabile** — e quindi non otteneva ciò che questa ADR le attribuisce come unico scopo, cioè evitare che un cambio di ora legale faccia rihashare l'intera libreria due volte l'anno.

Sono ora due verdetti distinti. `.needsVerification` (dubbio anti-racy) rihasha, perché il file **potrebbe** davvero essere cambiato. `.timezoneShift` no: adotta il nuovo mtime e tiene l'hash già calcolato.

È sicuro proprio per la distinzione che questa ADR stabilisce. Perché sia un errore servirebbe un file modificato, di dimensione identica al byte, con mtime spostato di esattamente 3600s (±50ms). E anche in quel caso il danno è confinato al percorso a **basso** danno: l'import rilegge e rihasha comunque il candidato prima di saltarlo, quindi nessuna foto viene persa — al massimo una riga sbagliata nel pannello Doppioni.

**Se qualcuno in futuro pensasse di semplificare unendo i due verdetti**: leggere prima questa nota. Unirli riporta il rihash semestrale dell'intera libreria, in silenzio.

## Nota (2026-08-25): la regola vale anche per la memoria del job corrente

Il dedup copre anche i doppioni **interni allo stesso import** (spec #31, sezione omonima): `ImportSessionIndex` ricorda in memoria le coppie `(dimensione, hash)` dei file copiati nel job in corso, che l'indice persistito non può ancora conoscere.

Quegli hash sono più affidabili di quelli dell'indice — li ha calcolati questo stesso processo pochi secondi prima, e li ha verificati contro il file di destinazione. **Non gode comunque di una fiducia diversa**: anche il candidato copiato in sessione viene riletto e rihashato prima di dichiarare il doppione. Non perché il rischio sia concreto, ma perché "quando si salta un file si rilegge, sempre" è una regola che si ricorda; "si rilegge tranne nel caso X" è una regola che qualcuno un giorno applicherà male. Costa una lettura locale, e solo quando un doppione c'è davvero.

La memoria di sessione **non** è una seconda scrittura sullo store: vive in RAM, muore col job, e la persistenza resta a batch post-import come stabilito in ADR-0002.

## Nota (2026-08-26): la fiducia riguarda i media, e il filtro serve in due punti

Questa ADR parla di quanto ci si fida di un hash. C'è una domanda a monte: **di quali file esiste un hash di cui valga la pena parlare**. La risposta è in `IndexableKind`: solo immagini e video partecipano al dedup, e "sbagliare per esclusione è il verso sicuro — quel file non partecipa al dedup e viene copiato, mai saltato".

Il ramo dell'indice persistito la rispettava già, perché `LibraryIndexer.scan` scarta i `.notIndexable` prima di indicizzarli. Il ramo di sessione (la memoria del job corrente, nota precedente) no, e lì la regola si rompeva in modo vistoso: due sidecar da 0 byte con nomi diversi hanno lo stesso SHA256, quindi il secondo veniva dichiarato doppione del primo — e a destinazione arrivava **un solo sidecar, col nome sbagliato** rispetto alla foto rimasta senza.

Il filtro sta ora in due punti, e servono entrambi: in `isAlreadyInLibrary` (lato "salto") e nella closure `onCopied` di `runImport` (lato "ricordo"). Il secondo non è ridondanza: tiene i due rami simmetrici — l'indice persistito non contiene mai non-media, e non deve contenerli nemmeno quello di sessione — mentre il primo chiude il buco per qualunque *altra* via con cui un non-media potesse finire in un indice.

Il filtro non sta in `FileSyncer`, che deve restare ignaro di `IndexableKind`: il dedup è roba dell'import, e il predicato è no-op per Mac→SSD e SSD→HDD.

## Nota (2026-08-27): i livelli sono tre, e «pannello Doppioni = basso danno» vale solo per la visualizzazione

Il ragionamento di questa ADR **resta valido**: è la mappatura fra i due usi e i due livelli che non è più completa.

Quando questa ADR è stata scritta, il pannello Doppioni **segnalava e basta**, e la frase «un hash stantio produce una riga sbagliata in un elenco» era vera. Il 2026-08-27 Enrico ha deciso che il pannello può anche **spostare i doppioni nel Cestino**. Da quel momento un hash stantio, nello stesso pannello, può mandare nel Cestino una foto che non è un doppione.

Quindi:

- **«Pannello Doppioni = basso danno» vale ora solo per la visualizzazione dei gruppi.** Lì la fiducia nella cache resta quella descritta qui, invariata.
- **La cancellazione è un terzo livello, più severo del secondo**: si rilegge e si rihasha **ogni membro del gruppo, la copia tenuta compresa**, e si pretende unanimità. Rileggere solo le copie da cestinare direbbe che sono uguali *fra loro*, non che siano uguali a quella che resta.
- Il terzo livello non annulla né indebolisce niente di quanto scritto sopra. Le tre difese (regola anti-racy, tolleranza DST, verifica completa) e la distinzione fra `.needsVerification` e `.timezoneShift` restano esattamente come sono.

Il ragionamento completo, le misure che lo giustificano e la contro-domanda per chi vorrà togliere la rilettura del file tenuto stanno in **ADR-0005**.

## Nota (2026-09-01): l'anteprima dell'import sta al livello 2, non al livello 1

Il wizard di import mostra «File da importare: N». Fino al 2026-09-01 quel numero veniva da `FileSyncer.previewSync`, che non conosceva il dedup: **prometteva più file di quanti ne venivano copiati**, e nel caso del reimport di una scheda già importata — cioè precisamente lo scenario da cui #31 è nato — poteva promettere 400 file e copiarne 0.

Sembrerebbe naturale collocare quella lettura al **livello 1**: è un numero in una schermata, un errore non perde nessuna foto, e l'indice ha già tutti gli hash. **È sbagliato, e il motivo non è ovvio.**

L'indice contiene, **per decisione di prodotto e in modo permanente**, file che sul disco non ci sono più. È la regola «traversata incompleta ⇒ nessuna rimozione dall'indice» (`vanishedKept`): le righe stantie sono innocue per l'import, che rilegge comunque, e cancellarle per errore costerebbe il dedup spento e una ricostruzione da quindici minuti. Quelle entry fantasma **restano**, ed è giusto così.

Ma un'anteprima che si fidasse della cache le conterebbe come doppioni presenti. Direbbe «di questi 400 file, 380 li hai già» quando 100 di quei 380 sull'SSD non ci sono più. Il numero diventerebbe **sotto-promettente**: l'utente vedrebbe 20 file da importare e ne verrebbero copiati 120.

Avremmo scambiato un errore in eccesso con uno in difetto — e quello in difetto è peggiore, perché una promessa mantenuta *in più* si nota e si perdona, una foto che l'utente non si aspettava di importare no. Quindi: **l'anteprima rilegge e rihasha il candidato**, esattamente come lo skip in import. Livello 2.

Costo misurato: ~15 s su ~95 s nel caso peggiore. Il prefiltro sulla dimensione lo tiene basso — le dimensioni di una libreria fotografica sono quasi uniche (72,7% distinte, misurato) — tranne nel reimport, dove ogni file collide perché ogni file è davvero un doppione.

**La contro-domanda, per chi un giorno vorrà spostare questa lettura al livello 1** — «è solo un numero a schermo, l'indice ce l'ha già»:

> L'indice ha l'hash dei file che ha visto **l'ultima volta che è arrivato in fondo**, e per regola esplicita tiene anche quelli che nel frattempo sono spariti dal disco. Quante di quelle entry corrispondono ancora a un file che esiste? Non lo sai senza guardare. E il numero che stai per mostrare dice all'utente quante foto **non** verranno importate: se lo sbagli in difetto, gli stai dicendo che ha già delle foto che non ha.

## Nota (2026-09-01): gli hash calcolati per l'anteprima non vengono riusati dall'import

Conseguenza diretta della nota sopra, e va scritta perché è un'ottimizzazione che verrà riproposta.

L'anteprima hasha i candidati. Pochi minuti dopo, `runImport` li hasha di nuovo per decidere lo skip. Su una scheda da 7 GiB sono ~78 s pagati due volte, e la tentazione di passare avanti gli hash dell'anteprima è forte.

**Rifiutato**, e non per purismo: fra i due momenti passa **un passo del wizard**. L'utente sceglie l'etichetta, ci pensa, magari va a prendere un caffè. Può scollegare la scheda e attaccarne un'altra. Può spostare i file. E **non esiste nessun controllo di identità del volume** fra l'anteprima e l'avvio: gli hash riportati avanti sarebbero hash di un insieme di file che nessuno ha verificato essere ancora lo stesso.

Non c'è nemmeno una via di mezzo utile: l'unica parte davvero riportabile avanti sarebbe il filtro sulla dimensione, che però costa già **4,7 µs a chiamata** — è gratis, e non c'è niente da risparmiare.

È il caso concreto per cui la regola «prima di decidere si rilegge» esiste in forma assoluta invece che con delle eccezioni: un'eccezione qui sarebbe stata ragionevole in ogni singolo passaggio del ragionamento, e sbagliata alla fine.
