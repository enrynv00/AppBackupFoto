# Il pannello Doppioni può cestinare, e questo capovolge il modello di fiducia

Data: 2026-08-27. Decisioni di Enrico prese nel brainstorming dello stesso giorno, verifiche empiriche eseguite prima di progettare, testo consolidato al termine dell'implementazione (2026-09-01).

## La decisione che viene riaperta

La spec del nucleo di #31 aveva **chiuso** la questione: il pannello Doppioni segnala, non cancella. ADR-0003 ha costruito su quella chiusura, definendo il pannello «percorso a **basso danno**» e giustificando così il modello di fiducia a due livelli, la tolleranza DST e il contratto «risultato corretto ma potenzialmente parziale» di `entries(withHash:)`.

Il 2026-08-27 Enrico ha riaperto la decisione. Quattro scelte, prese e non da rimettere in discussione:

1. **Il pannello può cancellare i doppioni**, con doppia conferma.
2. **I file vanno nel Cestino, non cancellati definitivamente.** L'errore deve restare annullabile.
3. **L'app propone quale copia tenere, l'utente conferma** — e la proposta va **spiegata a parole**, non solo evidenziata. Una proposta evidenziata e non spiegata si conferma senza sapere cosa si sta confermando.
4. **Si lavora a blocchi**, con riepilogo dettagliato *e poi* conferma vera. Non un gruppo alla volta (600 clic portano a confermare a occhi chiusi), non tutto insieme (la conferma diventa un rituale).

## Il capovolgimento

Finché il pannello segnalava soltanto, un hash stantio produceva **una riga sbagliata in un elenco**. Con la cancellazione lo stesso hash stantio **manda nel Cestino una foto che non è un doppione**.

E sappiamo per misura che la nostra chiave di invalidazione è debole: l'`mtime` è riscrivibile da userspace, ed exiftool, `rsync -t` e il restore da Finder lo **preservano** — quindi un file con contenuto diverso e dimensione identica esce da `indexEntryVerdict` come `.fresh`. Su ExFAT non esiste un inode stabile con cui irrobustire la chiave (ADR-0003).

Ne segue il fatto che questa ADR esiste per registrare:

> **Il pannello Doppioni è il percorso a danno più alto dell'intero progetto**, più alto dello skip in import. Nello skip si perde una foto *non copiata* dalla sorgente, che sulla sorgente resta. Qui si sposta nel Cestino una foto che sull'SSD era l'unica copia.

## I livelli di fiducia diventano tre, non due

| Uso | Fiducia | Costo |
| :---- | :---- | :---- |
| **Visualizzazione** dei gruppi nel pannello | ci si fida della cache, nessuna rilettura | invariato rispetto ad ADR-0003 |
| **Skip durante un import** | si rilegge e si rihasha **il candidato** | una lettura per candidato |
| **Cancellazione di un gruppo** | si rilegge e si rihasha **ogni file del gruppo, il tenuto compreso**, e si pretende **unanimità** | una lettura per file del gruppo, solo sui gruppi scelti |

Due proprietà del terzo livello che non sono dettagli implementativi:

- **Si rilegge anche la copia che si tiene.** Rileggere solo quelle da cestinare basterebbe a sapere che sono uguali *fra loro*, non che siano uguali a quella che resta — e il caso da escludere è esattamente «il file che tengo è cambiato da quando l'ho indicizzato».
- **La rilettura avviene al momento della cancellazione, non della visualizzazione.** Fra i due istanti l'utente può aver fatto qualsiasi cosa, e col modello a blocchi possono passare minuti.

L'unanimità è **per gruppo, non per file**: se anche un solo membro non produce un hash, o produce un hash diverso, **l'intero gruppo viene saltato** e finisce nel resoconto col motivo. Mai «cestino quelli che ho potuto verificare».

## Le tre misure che giustificano tutto questo

Fatte il 2026-08-27 su un'immagine disco ExFAT creata apposta, **prima** di progettare. Confermate sul volume reale il 2026-09-01 (vedi in coda).

1. **`FileManager.trashItem(at:)` funziona su un volume ExFAT esterno.** È la misura che regge o fa cadere la rete di sicurezza scelta con la decisione 2. Verificato anche il comportamento sui casi scomodi: omonimi rinominati con timestamp senza sovrascrittura; volume pieno (il cestinamento è una `rename` interna, non richiede spazio); e — decisivo — **in ogni caso di errore il file d'origine resta intatto**. `trashItem` è una `rename` o niente. Misurata anche la velocità: **55,8 file/s**.
2. **Il record «Rimetti a posto» del Finder è asincrono e perdibile.** `trashItem` lo scrive in `<root>/.Trashes/<uid>/.DS_Store` come coppie `ptbL`/`ptbN`, ma la scrittura non è durevole quando la chiamata ritorna: con un processo a vita breve si perdono gli ultimi record di un blocco (74 su 300 misurati). Attesa e rimontaggio non li recuperano. In più `.DS_Store` è un file che decine di strumenti cancellano di routine. **Da qui il registro di ripristino scritto dall'app**, sul disco interno, in modo sincrono e file per file.
3. **Lo scollegamento del volume a metà cancellazione è indistinguibile da «il file non c'era».** Con `hdiutil detach -force` a metà batch: `ok=328`, e 2.672 fallimenti tutti con `NSCocoaErrorDomain/4` — **lo stesso identico errore restituito quando il file semplicemente non esiste**. E `fileExists` risponde `false` per tutti, coerentemente col fatto misurato n. 2 di #31. Un'implementazione ingenua riporterebbe 2.672 perdite come «erano già spariti, tutto a posto»: è la **perdita silenziosa** che `Docs/CONTEXT.md` indica come la classe di bug che questo progetto teme più di ogni altra. **Contromisura obbligatoria**: `st_dev` della root riletto al primo fallimento, e se è cambiato si interrompe l'intero blocco dicendo quanti file erano stati cestinati.

## Conseguenze

- La **regola assoluta** del progetto cambia, ed è riscritta come tale in `Docs/CLAUDE.md` (punti 1 e 3, testo approvato il 2026-08-28). Zero delete resta la regola ovunque tranne che per **una porta sola**, descritta lì per esteso.
- Il **tetto per blocco è 500 file o 50 GB**, il primo che scatta. Scelto sul **raggio del danno**, non sulla durata: il cestinamento di 500 file è ~9 secondi, la rilettura di 50 GB è 2-4 minuti. Oltre il tetto la UI dice «fallo in più volte», non rifiuta e basta.
- **Cestinare non libera spazio** finché l'utente non svuota il Cestino (misurato). La UI non può dire «hai recuperato 4,2 GB» al passato.
- **HDD e Cubbit tengono la loro copia per sempre**: i mirror non cancellano mai. Lo spazio si recupera solo sull'SSD, e va detto nel riepilogo.
- **Svuotare il Cestino dall'app è fuori scope, permanentemente.** È l'unica operazione irreversibile, e toglierebbe la rete di sicurezza che è la ragione stessa della decisione 2.

## La contro-domanda, per chi un giorno vorrà togliere la rilettura del file tenuto

Prima o poi qualcuno — persona o modello — guarderà questo codice, vedrà che si rilegge dal disco un file di cui l'indice ha già l'hash, e proporrà di toglierlo: *«è ridondante, l'indice ce l'ha già»*.

**La risposta è no, e la domanda da rivolgergli è questa:**

> L'indice ha l'hash che quel file aveva **quando è stato indicizzato**. Tu stai per cestinare le altre copie fidandoti del fatto che siano identiche *a questa*. Cosa te lo garantisce, se questa non l'hai riletta?

E il seguito, se insiste che l'`mtime` lo direbbe:

> `exiftool`, `rsync -t` e il restore da Finder **preservano** l'mtime. Un file con contenuto diverso e dimensione identica esce da `indexEntryVerdict` come `.fresh`. Su ExFAT non hai un inode stabile con cui accorgertene. Il risparmio che proponi è **una lettura per gruppo, solo sui gruppi che l'utente ha scelto**. Il costo dell'errore è una foto irrecuperabile nel Cestino, e l'utente che ha appena confermato di volerlo.

Se la rilettura del file tenuto sparisce, questa ADR è violata anche se i test restano verdi: nessun test può produrre il caso reale — un file modificato fuori dall'app fra l'indicizzazione e la conferma — senza simularlo, e chi rimuove la rilettura rimuoverà anche la simulazione.

## Verifiche sul volume reale (2026-09-01)

Le misure sopra erano state fatte su un'immagine disco. Con SSD e HDD collegati sono state ripetute sul volume vero:

- **L'SSD è exFAT montato via FSKit** (l'implementazione nuova di macOS, non il driver storico su cui girava l'immagine di test). **L'HDD è APFS.**
- **`trashItem` sull'SSD vero: funziona.** Destinazione `/Volumes/SSD - Enri/.Trashes/501/`, stesso volume, contenuto integro, origine rimossa. `.Trashes/501/` esisteva già da febbraio 2025.
- **Il record «Rimetti a posto» viene scritto anche lì**: `ptbL = "/_prova_cestino_claude/"`, `ptbN = "doppione_finto.txt"`, letti decodificando il B-tree del `.DS_Store`. Su un file singolo non si è perso, coerentemente con la misura 2 (le perdite erano sugli ultimi file di blocchi da 100-300). **Il registro proprio dell'app resta comunque necessario**: la misura 2 non è smentita, è confermata nel suo verso.
- **Resta non verificato**: `trashItem` dall'**app firmata con Full Disk Access** (la sonda gira da `swift` a riga di comando, contesto TCC diverso), e «Rimetti a posto» premuto davvero nel Finder.
- **exFAT produce 57.560 sidecar AppleDouble `._`, di cui 34.969 con estensione da foto.** Senza l'esclusione già presente in `LibraryExclusions` formerebbero migliaia di gruppi di doppioni fasulli da 4096 byte, che questo pannello proporrebbe di cestinare. La difesa era scritta a tavolino: ora si sa che il caso è reale e di massa.

## Vedi anche

- ADR-0001 — doppione significa byte-identico (invariata: nessun rilevamento fuzzy).
- ADR-0002 — l'indice è una cache, non una fonte di verità (nota del 2026-08-27).
- ADR-0003 — due livelli di fiducia sullo stesso indice (nota del 2026-08-27: i livelli sono tre).
- `Docs/superpowers/specs/2026-08-27-duplicates-panel-design.md` — la spec completa, con tutte le misure.
