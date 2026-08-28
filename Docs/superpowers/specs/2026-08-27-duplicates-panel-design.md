# Spec — Pannello Doppioni con cancellazione (roadmap #31, seconda parte)

**Stato: domande aperte chiuse il 2026-08-28** (sezione «Risposte alle domande aperte» in coda). Resta da dare l'approvazione finale all'esecuzione del piano: nessuna riga di codice va scritta prima di quella.

## Problema

L'indice di contenuto (#31, nucleo implementato il 2026-08-25/27) ha due consumatori previsti. Il primo — il dedup durante un import — è in produzione. Il secondo — il **pannello Doppioni** — non è mai stato iniziato.

La spec del nucleo (`2026-08-25-library-content-index-design.md`) lo descriveva come **sola segnalazione**, e metteva la cancellazione esplicitamente fuori scope: *"sarebbe la prima operazione di cancellazione su file foto nella storia del progetto e richiede un go/no-go dedicato"*.

Quel go/no-go è avvenuto. In brainstorming (2026-08-27) Enrico ha deciso di **riaprire** la questione e di darle risposta affermativa. Da qui questa spec: non un incremento del pannello previsto, ma una feature diversa, con un profilo di rischio diverso.

## Le quattro decisioni di Enrico (brainstorming 2026-08-27)

Prese, non da rimettere in discussione. Riportate qui perché il design che segue è interamente una conseguenza di queste quattro.

1. **Il pannello può cancellare i doppioni**, con doppia conferma. Riapre esplicitamente una decisione che la spec del nucleo aveva chiuso.
2. **I file vanno nel Cestino, non cancellati definitivamente.** L'errore deve restare annullabile.
3. **L'app propone quale copia tenere, l'utente conferma** — e la proposta va **spiegata a parole** («tengo questa perché sta nella tua libreria principale»), non solo evidenziata. Una proposta evidenziata e non spiegata si conferma senza sapere cosa si sta confermando.
4. **Si lavora a blocchi.** Si spuntano i gruppi da smaltire; la doppia conferma è *riepilogo dettagliato* (quanti file, quali cartelle, quanti GB) **poi** conferma vera. Non un gruppo alla volta — 600 clic portano a confermare a occhi chiusi. Non tutto insieme — la conferma diventa un rituale.

## Il capovolgimento — è il cuore di questa spec

Tutto il nucleo di #31 è stato costruito sulla premessa che il pannello Doppioni fosse il percorso a **basso danno**. ADR-0003 lo dice alla lettera: lì *ci si fida della cache senza rileggere*, perché un hash stantio produce «una riga sbagliata in un elenco» che «l'utente guarda e ignora». Quella frase ha guidato decine di scelte: il modello di fiducia a due livelli, la tolleranza DST, il contratto «risultato corretto ma potenzialmente parziale» di `entries(withHash:)`.

Con la cancellazione la premessa si capovolge. Un hash stantio non produce più una riga sbagliata: **manda nel Cestino una foto che non è un doppione**. E sappiamo per misura che l'mtime è riscrivibile da userspace (exiftool, `rsync -t`, restore da Finder — tutti e tre *preservano* l'mtime, quindi un file con contenuto diverso e dimensione identica esce da `indexEntryVerdict` come `.fresh`) e che su ExFAT non esiste inode stabile con cui irrobustire la chiave.

**Il pannello Doppioni diventa quindi il percorso a danno più alto dell'intero progetto**, più alto dello skip in import: lì si perde una foto *non copiata* dalla sorgente, che sulla sorgente resta; qui si sposta nel Cestino una foto che sull'SSD era l'unica copia.

Da cui la decisione strutturale di questa spec:

> **I livelli di fiducia sullo stesso indice diventano tre, non due.**
>
> | Uso | Fiducia | Costo |
> | :---- | :---- | :---- |
> | **Visualizzazione** dei gruppi nel pannello | ci si fida della cache, nessuna rilettura | invariato rispetto ad ADR-0003 |
> | **Skip durante un import** | si rilegge e si rihasha **il candidato** | una lettura per candidato |
> | **Cancellazione di un gruppo** | si rilegge e si rihasha **ogni file del gruppo, il tenuto compreso**, e si pretende unanimità | una lettura per file del gruppo, solo sui gruppi scelti |

Il terzo livello è più severo del secondo, e la differenza non è un dettaglio: **si rilegge anche la copia che si tiene**. Rileggere solo quelle da cestinare basterebbe a sapere che sono uguali *fra loro*, non che siano uguali a quella che resta — e il caso da escludere è esattamente «il file che tengo è cambiato da quando l'ho indicizzato».

E la rilettura avviene **al momento della cancellazione**, non al momento della visualizzazione: fra i due istanti l'utente può aver fatto qualsiasi cosa, e con il modello a blocchi possono passare minuti.

## Verifiche empiriche (2026-08-27)

Fatte prima di progettare, su un'immagine disco ExFAT sparse da 2 GB creata nello scratchpad, montata **fuori** da `/Volumes` con `-mountpoint`, smontata e cancellata a fine lavoro. **L'SSD reale non era collegato** e non è stato toccato, né la Libreria Foto, né `~/Library/Application Support/AppBackupFoto/`. Vale la regola del progetto: misurare, non dedurre.

### 1. `FileManager.trashItem(at:)` funziona su un volume ExFAT esterno — sì

È la misura che regge o fa cadere l'intera rete di sicurezza scelta da Enrico (decisione 2).

| Caso | Esito misurato |
| :---- | :---- |
| File in una sottocartella | **OK** → `<root>/.Trashes/501/IMG_0001.JPG` |
| `.Trashes/<uid>` non esiste | **Creata da sola**, `drwx------`, con flag *hidden* |
| Secondo e terzo file **omonimo** da cartelle diverse | **OK**, rinominati con un timestamp: `IMG_0001.JPG 21-50-46-682.JPG` (nessuna sovrascrittura) |
| Nome con `:` `|` `?` | **OK**, conservato identico |
| Directory intera | **OK**, con il contenuto |
| Volume pieno (6,2 MB liberi su 2 GB) | **OK** — il cestinamento è una `rename` interna al volume, non richiede spazio |
| File inesistente | **FAIL** `NSCocoaErrorDomain/4` (`fnfErr` sotto) |
| File con flag `immutable` | **FAIL** `NSCocoaErrorDomain/513` — **e il file resta al suo posto** |
| `.Trashes` esiste come **file** invece che come cartella | **FAIL** `NSCocoaErrorDomain/512` — **e il file resta al suo posto** |
| 300 file da 1 MB in un ciclo stretto | 300/300, **55,8 file/s** |

Due conseguenze di prodotto, non evidenti:

- **Cestinare NON libera spazio.** Misurato: spazio libero identico prima e dopo il cestinamento di 300 MB. Lo spazio si libera solo quando l'utente svuota il Cestino. La UI non può quindi dire «recuperi 4,2 GB» al passato: deve dire che lo spazio si libererà svuotando il Cestino.
- **Un fallimento non distrugge nulla.** In tutti i casi di errore misurati il file d'origine è rimasto intatto. `trashItem` è una `rename` o niente.

### 2. Il file è recuperabile dal Finder — sì, ma il record di «Rimetti a posto» è asincrono

Il Finder vede il Cestino del volume esterno (verificato: `tell application "Finder" to count items of trash` restituisce anche i file cestinati sull'immagine ExFAT, con i nomi giusti).

L'informazione di «Rimetti a posto» viene scritta da `trashItem` stesso in `<root>/.Trashes/<uid>/.DS_Store`, come coppie di record `ptbL` (cartella d'origine) e `ptbN` (nome d'origine). Verificato parsando il B-tree del `.DS_Store`: `ptbL = "/foto/"`, `ptbN = "IMG_0001.JPG"`.

**Ma la scrittura è asincrona, e non è durevole quando `trashItem` ritorna.** Misurato:

| Scenario | File nel Cestino | Con record «Rimetti a posto» |
| :---- | :---- | :---- |
| 300 file, processo che esce subito dopo | 300 | **226** (74 persi, gli ultimi 74) |
| 100 file, pacing 50 ms, processo che esce subito dopo | 100 | **85** (15 persi, gli ultimi 15) |
| 100 file, processo **vivo** con RunLoop per 30 s | 100 | **100** |

Nel terzo caso — che è il caso reale di un'app GUI — non si perde niente. I primi due sono un artefatto di un tool a vita breve. Attesa di 20 s e smontaggio/rimontaggio non recuperano i record persi: è una perdita definitiva, non un ritardo di flush.

**Conseguenza di design, non aggirabile:** la recuperabilità non può essere delegata al Finder. Se l'app viene forzata a chiudersi (o crasha) subito dopo un blocco grosso, la coda dei record si perde: i file restano nel Cestino ma il Finder non sa più dove rimetterli. In più `.DS_Store` è un file che decine di strumenti cancellano di routine. Quindi **l'app tiene un proprio registro di ripristino**, scritto da lei, sul disco interno (vedi Design tecnico).

### 3. Lo scollegamento a metà cancellazione è indistinguibile da «il file non c'era» — è la misura più importante

400 file da 256 KB, `hdiutil detach -force` a metà batch:

```
ok=328  errori=["NSCocoaErrorDomain/4": 2672]  (fileExists dice ancora presenti: 0)
```

`NSCocoaErrorDomain/4` è `NSFileNoSuchFileError` — **lo stesso identico errore restituito quando il file semplicemente non esiste** (misura 1, riga «File inesistente»). E `FileManager.fileExists(atPath:)` risponde `false` per tutti, coerentemente con il fatto già misurato durante il nucleo di #31 (fatto misurato n. 2: `fileExists` non rileva lo smontaggio).

Un'implementazione ingenua interpreterebbe 2.672 fallimenti da scollegamento come «erano già spariti, tutto a posto» e riporterebbe un successo. È esattamente la **perdita silenziosa** che `Docs/CONTEXT.md` indica come la classe di bug che questo progetto teme più di ogni altra.

**Contromisura obbligatoria:** al primo fallimento si ricontrolla il `st_dev` della root della libreria (l'unica difesa che ha funzionato durante #31, insieme all'`errorHandler` dell'enumeratore), e se è cambiato si **interrompe l'intero blocco** e si dice all'utente quanti file erano stati cestinati prima. Mai trattare `NSFileNoSuchFileError` come «già fatto».

### 4. L'annullamento applicativo funziona

`moveItem` dal Cestino al percorso originale, ricreando le cartelle intermedie se l'utente le ha nel frattempo cancellate: **riuscito**, contenuto e dimensione intatti.

E `moveItem` su una destinazione **esistente** viene **rifiutata** (`NSCocoaErrorDomain/516`) invece di sovrascrivere: la regola zero-overwrite regge gratis anche sul percorso di ripristino. Va comunque verificata esplicitamente, non data per scontata (è una proprietà dell'API, non del nostro codice).

### 5. Cosa NON è stato misurato, e va misurato prima di fidarsi

- `trashItem` sull'SSD **vero** (`/Volumes/SSD - Enri`), dall'app firmata con Full Disk Access. L'immagine di test è montata `noowners` come un ExFAT esterno reale, ma non è lo stesso volume né lo stesso contesto TCC.
- Se `.Trashes` **esista già** su quel volume e cosa contenga.
- Il layout reale delle cartelle di primo livello dell'SSD (`ls -1`), su cui poggia la regola di proposta.
- «Rimetti a posto» premuto davvero nel Finder su un file cestinato dall'app.

Tutte e quattro vanno nella lista delle verifiche manuali pendenti di `Docs/CLAUDE.md`, accanto a quelle già in attesa dell'SSD.

## Design tecnico

### Dove vive il pannello

**Nuova `Window("Doppioni", id: "duplicates")`, scena di primo livello**, aperta da un bottone dentro la card «Foto già salvate sull'SSD» in Diagnostica.

Perché una finestra e non una scheda dentro Diagnostica: il contenuto è una lista lunga, navigabile, con miniature e selezioni, e Diagnostica ha già quattro `GroupBox`; e il pannello ha un lavoro lungo suo (verifica, cestinamento con progresso) che non deve contendersi lo spazio con la diagnostica.

Perché l'ingresso è nella card e non nell'hamburger: il pannello **non ha senso senza l'indice**, e la card è il posto dove l'indice si crea e si racconta. Mettere «Doppioni» nell'hamburger significherebbe offrire una funzione distruttiva a un utente che non ha ancora costruito l'elenco. **Deciso il 2026-08-28: un solo ingresso, nella card. Nessuna voce nell'hamburger.**

Conseguenze obbligatorie, regola stabilita in #30 e già applicata tre volte:
- **Gate `AuthGateManager`** all'inizio del `body` (`LockScreenView()` al posto del contenuto reale), perché una scena di primo livello nasce fuori da `ContentView` e quindi fuori dal gate — e questa elencherebbe percorsi, nomi e miniature di tutte le foto.
- `.restorationBehavior(.disabled)`.
- Gli avvisi **non** passano da `runner.pendingAlert` (`AlertSink`, sezione dedicata in `.claude/rules/architecture.md`): sono `@State` locali della view, come già fa `ToolsSheet` per i propri.

### Cosa si mostra, e cosa non è un doppione da mostrare

Un **gruppo** è l'insieme delle entry dell'indice che condividono lo stesso SHA256, con almeno due membri. Restano fuori, ciascuno con la sua ragione:

- **I gruppi di dimensione 0 byte.** Tutti i file vuoti hanno lo stesso SHA256. Nell'indice ci sono solo media (`IndexableKind`), quindi un media da 0 byte è un file troncato o corrotto: raggrupparli e proporre di cestinarne tutti tranne uno significherebbe cestinare file **diversi** credendoli copie. È esattamente il buco già trovato e chiuso una volta su questo progetto (i due sidecar `.AAE` da 0 byte, nota del 2026-08-26 in ADR-0003): qui ricomparirebbe con la cancellazione al posto dello skip. **Esclusione esplicita, con test.**
- **Tutto ciò che non è `.image`/`.video`.** L'indice per costruzione non contiene altro, ma il filtro va **riapplicato** nel percorso di cancellazione. È la terza sede della stessa guardia (le altre due sono `isAlreadyInLibrary` e la closure `onCopied` di `runImport`) e non è ridondanza: qui il costo di un non-media che passa non è una copia saltata, è un file cestinato.
- **I sidecar** (`.xmp`, `.aae`, i `.json` di Takeout) restano fuori come conseguenza del punto precedente, non come caso speciale. Nota da dire all'utente in chiaro: **cestinare una foto non cestina il suo sidecar**, che resterà orfano. È una conseguenza accettata, non un difetto da correggere qui.
- **I gruppi di un solo membro** — non sono gruppi.

**I numeri mostrati vengono dalla cache e possono essere stantii.** È il livello 1 di fiducia, invariato rispetto ad ADR-0003. La UI lo dice in linguaggio comune («questo è quello che ho visto l'ultima volta che ho guardato»), e la verità viene stabilita al momento della cancellazione, non prima. Il pannello **non** rilegge il disco per mostrare la lista: su ~120.000 file sarebbe una seconda scansione completa a ogni apertura.

**Se l'indice è vuoto o non è mai stato costruito, il pannello lo dice e rimanda alla card.** Mai una lista vuota, che si legge come «non hai doppioni». È la stessa classe di errore già corretta con `sawNothing` nella card: due schermate identiche per due situazioni opposte.

### La regola di proposta — quale copia si tiene

Una funzione **pura** che, dato l'insieme dei membri di un gruppo, restituisce **il membro da tenere e il motivo**. Il motivo è parte del risultato, non un commento: la decisione 3 di Enrico richiede che la proposta sia *spiegata a parole*, e una spiegazione ricostruita a posteriori dalla UI divergerebbe dalla regola alla prima modifica di una delle due.

Ordine di precedenza proposto:

1. **La libreria principale vince.** Un file sotto `Foto iPhone/` (la cartella che il job Mac→SSD scrive, e da cui partono i mirror HDD e Cubbit) batte tutto. Motivo detto all'utente: «tengo questa perché sta nella tua libreria principale».
2. **Una cartella organizzata batte un import.** A parità del punto 1, un file **non** sotto `Import/` batte uno sotto `Import/<etichetta>/`: gli import sono scarichi una tantum da schede e dischi, le altre cartelle sono organizzazione fatta a mano. Motivo: «tengo questa perché le altre copie stanno in una cartella di import».
3. **A parità, vince la più vecchia** (mtime minore). Motivo: «tengo la più vecchia».
4. **A parità piena, ordine deterministico**: percorso più corto, poi ordine alfabetico della chiave normalizzata. Non è una regola di prodotto, è la garanzia che la proposta **non cambi** fra due aperture del pannello a parità di dati. Una proposta instabile è una proposta di cui non ci si può fidare, e va provata con un test che permuta l'ordine dell'input.

**Questa regola è un'ipotesi, non una misura.** È costruita su ciò che il progetto sa delle proprie cartelle (`Foto iPhone/` è la destinazione di Mac→SSD; `Import/<etichetta>/` è la destinazione di #27-A; esistono estrazioni Takeout, cartelle storiche e una cartella `Zip`).

**Correzione del 2026-08-28 — il layout non è "mai stato censito"**, come diceva questa riga. Risulta verificato il 2026-07-29/30, e le cartelle di primo livello erano: `Foto iPhone`, `Foto Google Drive`, `Other`, `Takeout`, `Takeout 2`, `Zip`. È un rilievo di un mese fa e va riconfermato con un `ls -1`, ma la regola non parte da zero. Provata contro quel layout regge nei due punti alti (`Foto iPhone/` vince — ed è giusto, perché è la cartella che Mac→SSD riscriverebbe comunque; `Zip/` non entra nell'indice perché gli archivi non sono media per `UTType`, quindi esce da sé).

**Punto lasciato deliberatamente aperto (decisione di Enrico, 2026-08-28): dove stanno `Takeout/` e `Takeout 2/` nella gerarchia.** Sono estrazioni automatiche di Google, non organizzazione fatta a mano — quindi hanno lo stesso profilo di `Import/` e l'argomento per declassarle è forte; ma è anche il gruppo di doppioni potenzialmente più grosso dell'SSD, e Enrico ha scelto di deciderlo **con il layout reale davanti** invece che a tavolino. Finché non è deciso, vale l'ordine scritto sopra (Takeout alla pari delle altre cartelle, disambiguato dalla data più vecchia) **come regola provvisoria dichiarata tale**, isolata in una funzione pura con i propri test: fissarla dopo costa un cambio lì e nient'altro.

Non è un blocco all'implementazione: il pannello richiede l'indice, l'indice richiede l'SSD collegato e non è mai stato costruito, quindi questa decisione cade sullo stesso gate delle altre verifiche manuali pendenti. Va nella lista di `Docs/CLAUDE.md`.

**In ogni caso la proposta è solo una proposta**: l'utente può cambiare quale copia tenere dentro ogni gruppo, e nessun gruppo entra in un blocco senza che lui l'abbia spuntato.

### La cancellazione — il percorso ad alto danno

Per ogni gruppo selezionato, nell'ordine:

1. **Precondizioni del blocco**, valutate una volta: nessun job in corso (`BackupRunner.isRunning`), nessuna scansione dell'indice in corso, SSD montato, bookmark risolvibile. Copiare o leggere l'intero volume mentre si cestina è il modo di trasformare due operazioni corrette in un guasto. Precedente già in casa: `LibraryIndexAutoRefresh.shouldRun`.
2. **`st_dev` della root** letto e memorizzato prima di iniziare.
3. Per ogni **file del gruppo, il tenuto compreso**:
   - il percorso è **dentro** la root della libreria, confrontato **per componenti canoniche** (`realResolvedPath` / `canonicalPathComponents`, la fonte unica), mai con `hasPrefix` — `/Volumes/SSD` non è un prefisso di `/Volumes/SSD 2`, ma lo è testualmente;
   - `IndexableKind.of(url:)` è `.image` o `.video`;
   - `sha256Measured(of:)` — hash **e** dimensione dallo stesso descrittore aperto, mai `FileHandle` (il bug di memoria da 41 GB), mai `URL.resourceValues` (che serve dalla cache dell'istanza: fatto misurato n. 1 di #31).
4. **Unanimità obbligatoria**: tutti i membri devono aver prodotto un hash (nessun `nil`), tutti gli hash devono essere **identici fra loro** e **uguali all'hash del gruppo**, e le dimensioni devono coincidere. Se anche un solo membro non soddisfa: **l'intero gruppo viene saltato**, non se ne cestina nemmeno uno, e il gruppo finisce nel resoconto finale con il motivo. Mai «cestino quelli che ho potuto verificare».
5. Solo allora si cestinano **i membri diversi dal tenuto**, uno alla volta, via `FileManager.trashItem(at:resultingItemURL:)`. `resultingItemURL` viene **registrato subito** nel registro di ripristino (vedi sotto), prima di passare al file successivo.
6. **Su qualunque fallimento**: si rilegge il `st_dev` della root. Se è cambiato, si interrompe **tutto il blocco** e si riporta quanti file erano stati cestinati. Se non è cambiato, il gruppo viene chiuso lì (i file già cestinati restano cestinati, sono registrati, sono annullabili) e si prosegue col gruppo successivo, contando il fallimento.
7. **Post-condizione del gruppo**: il file tenuto deve esistere ancora. Se non esiste — caso che non dovrebbe accadere e proprio per questo va gestito — si **rimettono a posto immediatamente** i file appena cestinati di quel gruppo, usando il registro.
8. Solo dopo un gruppo chiuso con successo si **rimuovono dall'indice le chiavi dei file effettivamente cestinati**, e nessun'altra.

Due invarianti da blindare con i test, perché sono quelle che un'ottimizzazione futura romperebbe per prime:

- **L'unico modo in cui questo codice tocca un file foto è `trashItem`.** Mai `removeItem`, in nessun ramo, nemmeno di errore. Mai una scrittura dentro `.Trashes`. Mai uno svuotamento del Cestino.
- **Il file tenuto non viene mai passato a `trashItem`.**

**Tetto per blocco: 500 file o 50 GB**, il primo che scatta — **confermato da Enrico il 2026-08-28**. Ragioni: la misura 3 mostra che un guasto a metà blocco è uno stato reale, il cui raggio va tenuto piccolo. Oltre il tetto la UI dice «fallo in più volte» invece di rifiutare e basta.

Nota sul tempo, per non fraintendere il tetto: il costo di un blocco **non** è il cestinamento (~56 file/s misurati, quindi 500 file ≈ 9 secondi) ma la **rilettura e il rihash** che lo precedono — 50 GB da un SSD USB sono grosso modo 2-4 minuti di barra di progresso. Il tetto è quindi scelto sul raggio del danno, non sulla durata.

Il numero è prudente e scelto **senza sapere quanti doppioni ci siano davvero**: alla prima passata reale con l'SSD si vedrà il volume vero, e alzarlo è una costante da cambiare, non un redesign.

**Progresso e interruzione.** Il blocco mostra avanzamento ed è interrompibile. Un'interruzione lascia un blocco parziale — è uno stato legittimo, va detto con un numero, e tutto ciò che era stato cestinato resta annullabile.

### Il registro di ripristino

Non deleghiamo la recuperabilità al Finder, per la misura 2.

`TrashManifest` — un record per file cestinato: percorso originale (di visualizzazione e chiave normalizzata), percorso nel Cestino restituito da `trashItem`, dimensione, hash, istante. Persistito in `~/Library/Application Support/AppBackupFoto/`, **mai sull'SSD**, con permessi `0600` (contiene i percorsi di tutte le foto in chiaro, stessa igiene già applicata all'indice), e con `init(from:)` esplicita e `decodeIfPresent` sui campi (fatto misurato n. 5: i default sulle proprietà non rendono retrocompatibile un `Codable`, e il `try?` di chi lo legge fa sparire il record in silenzio).

**Scritto incrementalmente, file per file**, non a fine blocco: è lo stesso ragionamento per cui `onUnverified` è un callback e non un campo di `SyncResult` — il debito va scritto nell'istante in cui viene contratto, così sopravvive a un blocco interrotto o fallito. Ed è la lezione diretta della misura 2: il record del Finder si perde proprio perché è differito.

**«Annulla»** rimette a posto l'ultimo blocco. Per ogni voce, nell'ordine: il file esiste ancora nel Cestino → il suo hash coincide con quello registrato → il percorso originale è **libero** → si ricreano le cartelle intermedie → `moveItem`. Se una qualunque condizione cade, quella voce non viene ripristinata e lo si dice; le altre procedono. Il ripristino **non sovrascrive mai** (misurato: `moveItem` rifiuta con 516, ma va verificato esplicitamente dal nostro codice, non dato per scontato).

Dopo un annullamento **non** si reinseriscono le entry nell'indice a mano: si segna che l'indice va aggiornato e ci pensa la scansione incrementale (i file tornati risultano nuovi e vengono rihashati). Reinserire una entry costruita a memoria significherebbe inventare un `hashedAt`, cioè avvelenare la regola anti-racy per risparmiare una scansione incrementale.

### Aggiornamento dell'indice dopo la cancellazione

**La rimozione delle chiavi cestinate NON passa da `LibraryIndexer.scan` e non tocca la regola «traversata incompleta ⇒ nessuna rimozione».**

Va detto esplicitamente perché la somiglianza è ingannevole. Quella regola (decisione di prodotto di Enrico, 2026-08-26, cardine dello scanner) governa le rimozioni **inferite**: la scansione non ha visto un file, quindi *forse* non c'è più — e siccome «non l'ho visto» può voler dire disco scollegato, cartella illeggibile o TCC perso, nel dubbio si tiene.

Qui non c'è inferenza: **abbiamo spostato noi quel file, e `trashItem` ci ha restituito il percorso di destinazione**. È conoscenza diretta. Si rimuovono le chiavi di quei file, e nient'altro, con un `store.remove(keys:)` mirato.

**Ordine: prima il cestinamento, poi la rimozione dall'indice.** Se l'app muore fra i due, resta una entry fantasma: innocua, perché chi decide di saltare un file rilegge e rihasha comunque il candidato (ADR-0003) e la rilettura di un file inesistente fallisce, quindi nessuno skip sbagliato. L'ordine inverso lascerebbe invece un file sul disco senza entry: al primo import verrebbe ricopiato, ricreando il doppione che questa feature esiste per togliere. La direzione sicura è una sola.

Nota collaterale: `.Trashes` è già in `LibraryExclusions` **e** comincia con un punto, quindi è escluso due volte dalla traversata dello scanner. Un file cestinato esce dall'indice e non ci rientra finché resta nel Cestino, senza nessun codice nuovo.

### Cestino svuotato, cestino ripristinato

- **L'utente svuota il Cestino**: i file spariscono davvero. Le entry sono già state rimosse al punto 8, quindi l'indice è già corretto. Le voci del registro di ripristino diventano non ripristinabili: «Annulla» lo rileva (il file non c'è più) e lo dice, invece di fallire. **L'app non svuota mai il Cestino** e non offre di farlo: sarebbe l'unica operazione davvero irreversibile della feature, e non è sua.
- **L'utente fa «Rimetti a posto» dal Finder**: il file torna al suo percorso originale e il doppione ricompare. La prossima scansione incrementale lo rivede come nuovo, lo rihasha e lo rimette nell'indice; il gruppo riappare nel pannello. È il comportamento corretto — l'utente ha annullato, e l'app se ne accorge da sola. Nessun codice speciale, ma va scritto nella spec perché è la domanda che si pone chiunque legga.

### Miniature

**Una miniatura per gruppo, non per file.** I membri sono byte-identici per definizione: mostrarne tre è pagare tre letture per tre immagini indistinguibili. È l'argomento più forte per il costo, e taglia l'I/O per il fattore della dimensione del gruppo.

- Si riusa **`makeThumbnail`** già esistente (#17), che passa da `CGImageSourceCreateThumbnailAtIndex` e non carica mai l'immagine intera. Non se ne scrive una seconda.
- **Pigre**: solo per le righe davvero a schermo (`LazyVStack` + `.task` per riga), con un token di richiesta che scarta le miniature arrivate su righe già superate — stesso meccanismo di `thumbnailRequestID`.
- **Cache limitata** (proposta: 200 miniature a 96 px). Senza tetto, scorrere 600 gruppi tiene in RAM 600 `NSImage`: su questo progetto una lettura senza tetto è già costata 41 GB una volta.
- **La miniatura si legge dal file tenuto**, quello che resterà.
- **Video: icona di sistema**, non fotogramma — **confermato da Enrico il 2026-08-28**. `AVAssetImageGenerator` su centinaia di video da un SSD USB è un costo e una superficie API nuova per un beneficio marginale in questa versione. Regge anche perché i membri di un gruppo sono byte-identici per definizione: la miniatura non serve a distinguerli fra loro, e di un gruppo video restano comunque visibili nome, cartella, dimensione e numero di copie. Riga onesta nella lista dei limiti, non nascosta. Se alla prima passata reale non basta, il fotogramma si aggiunge dopo senza toccare il resto.
- **Se la miniatura non si genera, non è un errore**: si mostra l'icona di sistema. Un doppione senza anteprima resta un doppione.

### Ordinamento e priorità

Default: **spazio recuperabile per gruppo, decrescente** — cioè `dimensione × (numero di copie − 1)`, non `dimensione × numero di copie`: il file che resta occupa comunque il suo spazio. È l'errore aritmetico più facile da fare qui e va ucciso con un test.

La ragione del default: con centinaia di gruppi l'utente non arriverà in fondo. Deve trovare in cima i gruppi dove c'è il valore, non quelli alfabeticamente primi.

Ordinamenti alternativi offerti: numero di copie (decrescente), e cartella. Nessuna ricerca testuale in questa versione.

## Cosa cambia negli ADR esistenti

Da fare nel Task 7 del piano, prima di considerare la feature chiusa.

- **ADR-0005, nuovo — «Il pannello Doppioni può cestinare, e questo capovolge il modello di fiducia».** Registra: la riapertura della decisione chiusa dalla spec del nucleo; Cestino invece di cancellazione; proposta spiegata a parole; lavoro a blocchi con riepilogo + conferma; e soprattutto il **terzo livello di fiducia** (rilettura e rihash di *tutti* i membri, tenuto compreso, con unanimità obbligatoria) e la ragione per cui è più severo del secondo. Registra anche le tre misure che lo giustificano: `trashItem` funziona su ExFAT, il record «Rimetti a posto» è asincrono e perdibile, lo scollegamento è indistinguibile da «file assente».
- **ADR-0003 — nota datata 2026-08-27, non riscrittura.** Il ragionamento dell'ADR resta valido: è la mappatura «pannello Doppioni = basso danno» che non lo è più. La nota dice che quella frase vale ora **solo per la visualizzazione**, che i livelli sono tre e non due, e rimanda ad ADR-0005. Il progetto usa già questo schema: 0002 e 0003 portano entrambi note datate.
- **ADR-0002 — nota datata 2026-08-27.** «L'indice è una cache, non una fonte di verità» resta vero e diventa più importante: ora un consumatore della cache può **spostare file**. La conseguenza da aggiungere è che **la cache non può mai essere la sola base di un atto distruttivo** — il disco si rilegge sempre prima. E la precisazione sulla rimozione mirata delle chiavi dopo il cestinamento: è conoscenza, non inferenza, e quindi non ricade sotto la regola della traversata incompleta.
- **`Docs/CONTEXT.md`** — voci nuove: **Gruppo di doppioni**, **Copia tenuta**, **Blocco**, **Registro di ripristino**, e la correzione della voce «Percorso a basso danno / percorso ad alto danno», che oggi dice che segnalare un doppione è a basso danno senza distinguere segnalazione da cancellazione.

## La regola assoluta cambia, e va scritta come tale

`Docs/CLAUDE.md` oggi dice, sotto «Regola assoluta — Le foto non si toccano»:

> 1. **Zero delete**: nessuna operazione di cancellazione su file foto, né locale né remota, in nessun caso.
> 3. **Read-only sulla sorgente**: la sorgente (Mac Photos Library o SSD) viene solo letta, mai modificata.

Entrambe diventano false con questa feature. **Vanno riscritte come modifica consapevole di una regola assoluta, con la data e il motivo, non lasciate lì come eccezione silenziosa** — un'eccezione non scritta è un'eccezione che qualcuno estenderà.

**Testo approvato da Enrico il 2026-08-28**, parola per parola. Rispetto alla prima stesura è stata aggiunta la clausola sulla rilettura: il testo originale nominava solo la doppia conferma dell'utente, e non la garanzia tecnica che impedisce davvero di cestinare una foto che non è un doppione — chi avesse letto solo la regola avrebbe potuto credere di rispettarla con un alert e nient'altro.

> 1. **Zero delete.** Nessun percorso di codice cancella un file foto. **Unica porta, aperta il 2026-08-27**: il pannello Doppioni può spostare nel **Cestino del volume** (`FileManager.trashItem`) copie byte-identiche di file che restano presenti sull'SSD — e solo dopo che ogni membro del gruppo, **la copia tenuta compresa**, è stato riletto e rihashato dal disco con esito unanime, e dopo che l'utente ha spuntato i gruppi, letto un riepilogo dettagliato e confermato. Anche lì: mai `removeItem` su un file foto, mai uno svuotamento del Cestino, mai un file la cui unica copia sparisce. Tutto il resto del progetto resta a zero delete.
> 3. **Read-only sulla sorgente.** La Libreria Foto del Mac non viene mai modificata, in nessun caso. Sull'SSD l'unica scrittura ammessa oltre alle copie di backup è lo spostamento nel Cestino del punto 1. Nessun'altra funzione scrive sull'SSD.

Va aggiunto anche il ramo mancante nella checklist di revisione AI dello stesso file, che oggi copre `removeItem`/`moveItem`/`copyItem` ma non conosce `trashItem`:

> IF il codice chiama `trashItem`:
>     THEN verifica che il percorso sia dentro la root della libreria, confrontato per componenti canoniche
>     THEN verifica che il file sia stato riletto e rihashato, e che l'intero gruppo sia unanime
>     THEN verifica che il file tenuto non sia fra quelli passati a `trashItem`
>     THEN verifica che il percorso di destinazione sia registrato prima di procedere al file successivo

## Rischi accettati esplicitamente

- **La cancellazione non libera spazio finché l'utente non svuota il Cestino** (misurato). L'app lo dice; non lo risolve, perché svuotare il Cestino da codice toglierebbe la rete di sicurezza che è la ragione della decisione 2 di Enrico.
- **HDD e Cubbit tengono la loro copia per sempre.** SSD→HDD e SSD→S3 non cancellano mai (zero delete, invariato): un doppione cestinato sull'SSD resta sui due mirror. Lo spazio si recupera **solo sull'SSD**. Non è un difetto da correggere qui — propagare le cancellazioni ai mirror sarebbe una feature molto più pericolosa di questa — ma **deve stare nel riepilogo di conferma**, altrimenti l'utente crede di aver liberato tre volte lo spazio che ha liberato.
- **Il job Mac→SSD può ricreare un file cestinato**, se quel file è ancora nella Libreria Foto del Mac e stava sotto `Foto iPhone/`. La regola di proposta lo rende raro (tiene `Foto iPhone/`), ma non impossibile. Conseguenza: spazio non recuperato, nessuna perdita. Va detto nel riepilogo.
- **Cestinare una foto non cestina il suo sidecar** (`.xmp`, `.aae`, `.json` di Takeout): i sidecar sono fuori dall'indice per decisione del nucleo. Restano orfani, occupano poco, non si perde niente.
- **La lista mostrata può essere stantia** (livello 1 di fiducia). Mitigato dal fatto che nessun gruppo viene cestinato senza rilettura unanime al momento della cancellazione: uno stantio produce un gruppo saltato con spiegazione, mai un file sbagliato nel Cestino.
- **Il record «Rimetti a posto» del Finder può perdersi** se l'app viene uccisa subito dopo un blocco grosso (misurato). Mitigato dal registro di ripristino dell'app, che è scritto in modo sincrono e file per file. I file restano comunque nel Cestino: il caso peggiore è rimetterli a posto a mano.
- **`lowercased()` nella chiave normalizzata collassa i singleton canonici** (limite noto del nucleo). Qui la conseguenza cambia verso: una entry persa significa un membro del gruppo non elencato, mai un file cestinato in più. Verso sicuro, invariato.
- **Nessun rilevamento di doppioni non byte-identici** (Takeout ricodificato, HEIC/JPG, ridimensionati): conseguenza diretta di ADR-0001, invariata. Il pannello mostrerà meno di quanto l'utente si aspetta, e va detto nel testo del pannello.

## Fuori scope

- **Svuotare il Cestino dall'app.** È l'unica operazione irreversibile e non è nostra.
- **Propagare le cancellazioni a HDD e Cubbit.** Molto più pericolosa di questa feature, e non richiesta.
- **Doppioni fuzzy/percettivi** — ADR-0001, invariato.
- **Fotogrammi come miniature per i video** in questa versione.
- **Ricerca testuale e filtri per cartella** nel pannello.
- **Regole automatiche** («cestina sempre le copie sotto `Import/`»): l'automazione è esattamente ciò che la doppia conferma esiste per impedire.
- **Cancellazione di file non doppioni** da questo pannello (file singoli, file grandi, file vecchi). Il pannello ha una sola competenza.

## Risposte alle domande aperte (2026-08-28)

Le sei domande lasciate aperte dalla fase Architect, chiuse da Enrico in un giro one-question-at-a-time. Sono decisioni prese: non vanno rimesse in discussione senza un motivo nuovo.

1. **Ingresso: solo nella card di Diagnostica.** Nessuna voce nell'hamburger, nemmeno disattivata. Un unico ingresso per una funzione che può cestinare foto, e il percorso continua a raccontare la dipendenza dall'indice.
2. **Tetto per blocco: 500 file / 50 GB**, il primo che scatta. Da ritarare, se serve, col numero vero di doppioni misurato alla prima passata reale.
3. **Seconda conferma: `.alert` con bottone distruttivo**, non la stringa da ridigitare di `DiskPrepView`. Il peso della conferma sta nel riepilogo dettagliato che la precede. La motivazione è che il cestinamento è reversibile due volte (Cestino di sistema + registro di ripristino dell'app), mentre la ridigitazione resta **il segnale esclusivo dell'unica operazione irreversibile del progetto**, la formattazione di un disco: usarla anche qui la svaluterebbe proprio dove serve.
4. **Video: icona di sistema**, nessun fotogramma in questa versione.
5. **Testo della regola assoluta approvato**, nella variante che include la clausola sulla rilettura unanime (vedi sezione «La regola assoluta cambia»).
6. **Gerarchia di `Takeout/` e `Takeout 2/`: decisione rimandata al layout reale.** Enrico ha scelto di fissarla con un `ls -1` davanti invece che a tavolino. Fino ad allora vale la regola provvisoria descritta sopra. Non blocca l'implementazione — il pannello richiede comunque l'SSD collegato, quindi la decisione cade sullo stesso gate delle altre verifiche pendenti.

Correzione emersa nello stesso giro, già riportata nella sezione della regola di proposta: **la spec affermava che il layout dell'SSD non fosse mai stato censito, e non è vero** — risulta rilevato il 2026-07-29/30. Vale come promemoria che una domanda aperta va cercata nella storia del progetto prima di essere girata a Enrico.
