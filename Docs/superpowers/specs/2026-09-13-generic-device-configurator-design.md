# Spec — Configuratore generico di dispositivi (roadmap #27)

## Problema

L'app conosce **quattro ruoli fissi**, scelti una volta in Setup e cablati nel codice: `photos` (la Libreria Foto del Mac), `ssd`, `hdd`, `s3`. Non si può aggiungere un secondo disco di backup, collegare un disco USB al volo, importare da una fotocamera o da una scheda SD senza passare dal wizard di #27-A, né usare un provider S3 diverso da Cubbit.

Enrico vuole poter **aggiungere e togliere dispositivi liberamente**, sia come sorgente sia come destinazione, invece di avere quattro caselle prestabilite.

## Decisioni prese (2026-09-13, domande one-at-a-time)

1. **Riscrittura pulita**, non migrazione incrementale: il concetto di ruolo fisso sparisce dal codice, non resta nascosto sotto un adattatore. *Scelta di Enrico contro la mia raccomandazione* (avevo proposto l'incrementale per non far mai vedere all'app uno stato riconfigurabile).
   **Correttivo di disegno**: la riscrittura pulita **non comporta riconfigurazione manuale**. I tre bookmark esistenti vengono convertiti in record di dispositivo da una migrazione una tantum al primo avvio (vedi «Migrazione»). Il modello dati è pulito, l'utente non rifà niente. Il costo che avevo attribuito a questa opzione era del *modo* di realizzarla, non dell'opzione.
2. **Topologia a stella, con una libreria al centro**: una sorgente principale raccoglie tutto (oggi l'SSD), N destinazioni la rispecchiano. Non coppie libere sorgente→destinazione, non regole per cartella.
3. **Solo dispositivi a blocchi montati localmente** nel primo incremento: volumi in `/Volumes/*`, dischi USB, SSD, HDD, schede SD, lettori di fotocamere. NAS in rete e provider S3 diversi da Cubbit restano in roadmap, fuori da questo incremento.

## Il fatto che rende la riscrittura fattibile

Contati nel codice: **124 riferimenti diretti ai ruoli fissi** (`.ssd` 67, `.hdd` 24, `.s3` 18, `.photos` 15), **tre metodi di backup cablati** (`runMacToSSD`, `runSSDToHDD`, `runSyncS3`) e **due enum paralleli e disallineati** — `BookmarkManager.Location` (`photos`, `ssd`, `hdd`) e `RestoreSource` (`ssd`, `hdd`, `s3`): il Mac non è una sorgente di ripristino, S3 non è un bookmark. Il disallineamento fra i due enum è di per sé un sintomo che il modello a ruoli fissi non regge più.

**Ma lo strato di I/O è già generico.** `FileSyncer.sync(from: URL, to: URL, deep: Bool, …)` prende due URL e non sa nulla di ruoli; `S3Syncer.sync(from: URL, config: S3Config, …)` prende un URL e una configurazione. Nessuna delle due funzioni contiene la parola `ssd` o `hdd`.

Quindi **il ruolo fisso vive nella configurazione e nel cablaggio dei job, non nella copia dei file**. Questo è ciò che rende la riscrittura un lavoro di rimpiazzo di uno strato, non una riscrittura del motore: `FileSyncer` e `S3Syncer` **non vanno toccati**, e la regola zero-delete/zero-overwrite che vive lì dentro non viene rimessa in discussione da questa spec.

## Design tecnico

### Il modello

Un solo tipo di record al posto dei quattro ruoli:

```
Device
  id            UUID              stabile, mai riusato
  name          String            scelto dall'utente ("HDD di scorta")
  kind          .localFolder | .localVolume | .s3Bucket
  role          .source | .destination | .library
  bookmark      Data?             per i dispositivi locali
  volumeUUID    String?           sopravvive allo smontaggio e al rinominamento
  s3ConfigRef   String?           riferimento alla voce Keychain, mai la credenziale
  addedAt       Date
```

**`volumeUUID` è il vero identificatore di un disco, non il path e non il nome.** È già persistito oggi accanto a ogni bookmark (`bk_<role>_volumeUUID`, verificato il 2026-08-23 coincidere col campo `VolumeUUID` di `diskutil`) e va promosso a chiave di riconoscimento: è ciò che permette di dire «questo è l'HDD che conosci» quando l'utente lo ricollega, anche se macOS lo monta su un path diverso o l'utente l'ha rinominato.

**`role` è un attributo del dispositivo, non la sua identità.** È la differenza sostanziale rispetto a oggi: `ssd` era *insieme* un'identità e un ruolo, e infatti l'SSD compare come destinazione in un job e come sorgente in altri due.

### La stella

Esattamente **un** dispositivo ha `role == .library`. Tutti i backup sono raggi di quella stella:

```
   sorgenti  ──→  [ libreria ]  ──→  destinazioni
  Mac, SD,          (SSD)            HDD, Cubbit,
  fotocamera                         disco nuovo…
```

I job non sono più scritti a mano ma **derivati**: per ogni sorgente configurata un job sorgente→libreria, per ogni destinazione un job libreria→destinazione. I tre job di oggi diventano tre righe generate, con lo stesso comportamento visibile.

**Vincolo**: la libreria dev'essere **una sola**, e cambiarla è un'operazione esplicita e rara, non un menu a tendina sempre disponibile. Una seconda libreria trasformerebbe la stella in un grafo e con essa la domanda «dove sta questa foto?», che è esattamente ciò che la scelta 2 voleva evitare.

### Migrazione (una tantum, al primo avvio della versione nuova)

```
bk_photos  + bk_photos_volumeUUID   →  Device(name: "Mac",    kind: .localFolder, role: .source)
bk_ssd     + bk_ssd_volumeUUID      →  Device(name: "SSD",    kind: .localVolume, role: .library)
bk_hdd     + bk_hdd_volumeUUID      →  Device(name: "HDD",    kind: .localVolume, role: .destination)
voce Keychain S3 esistente          →  Device(name: "Cubbit", kind: .s3Bucket,    role: .destination)
```

Regole della migrazione:

- **I `Data` dei bookmark vengono copiati, non ricreati.** Ricrearli richiederebbe un pannello di selezione file per ogni disco, cioè proprio la riconfigurazione manuale che vogliamo evitare — e sui volumi ExFAT la riselezione della root è già nota per essere fragile.
- **Le vecchie chiavi `UserDefaults` non vengono cancellate** dalla migrazione. Restano lì, inerti: se la migrazione ha un difetto scoperto dopo, la sorgente di verità originale esiste ancora. Si rimuovono in una versione successiva, quando la nuova avrà girato abbastanza.
- **Un dispositivo non configurato non produce un record.** Se l'HDD non era mai stato impostato, non nasce un dispositivo "HDD" vuoto da cancellare a mano.
- **La migrazione è idempotente** e marcata da un flag di versione dello schema: rieseguirla non duplica i dispositivi.

### Aggiungere un dispositivo

Il caso che deve essere ovvio per chi non è tecnico: **collego un disco USB e voglio che ci finiscano anche lì le mie foto.**

`VolumeMonitor` già rileva il collegamento di un volume (ed è già stato corretto il 2026-09-02 per non bloccare il main thread). Al collegamento di un volume sconosciuto — `volumeUUID` che non corrisponde a nessun `Device` — l'app propone **una domanda sola**:

> **Disco «Foto Viaggi» collegato.**
> Vuoi tenerci una copia delle tue foto?
> [ Sì, copia anche qui ]  [ No, è solo di passaggio ]  [ Non chiedermelo per questo disco ]

Il terzo bottone è necessario: senza, ogni chiavetta collegata per altri motivi ripropone la domanda all'infinito. La scelta si registra sul `volumeUUID`, non sul nome.

Non si chiede all'utente di scegliere un «ruolo»: la domanda è «copia anche qui?», e il ruolo `.destination` lo deduce l'app. La parola "ruolo" non compare mai a schermo — stessa regola già applicata all'indice di contenuto, dove non compaiono "indice", "hash" e "scansione".

### Togliere un dispositivo

Rimuovere un dispositivo **non tocca nessun file** su quel disco: smette solo di copiarci sopra. Va detto **nella schermata di rimozione, mentre l'utente decide** — non in un riepilogo successivo. È la lezione già pagata con la garanzia sull'HDD (2026-09-02), dove la garanzia esisteva ma era scritta dopo il punto in cui serviva.

Non si può rimuovere il dispositivo `.library` senza prima designarne un altro.

### Cosa NON cambia

- `FileSyncer` e `S3Syncer`: nessuna modifica. Prendono già URL e configurazioni.
- Le regole zero-delete / zero-overwrite / sola lettura sulla sorgente.
- L'indice di contenuto (#31) e il pannello Doppioni: lavorano sulla **libreria**, che dopo la migrazione è il dispositivo `.library`. Il pannello Doppioni continua a operare **solo** su quella, e i mirror restano intoccati.
- Immich (#29): monta la libreria in sola lettura. Legge il path dal dispositivo `.library` invece che dal bookmark `.ssd`.

## Fuori scope (deciso esplicitamente)

- **NAS in rete (SMB/AFP)**: introduce credenziali di rete, montaggio/smontaggio, cadute a metà copia, timeout e riprese — una classe di errori che l'app oggi non conosce. Enrico ha un NAS in casa ma è un progetto separato.
- **Provider S3 diversi da Cubbit**: `S3Syncer` è già quasi generico (endpoint configurabile), ma multipart e checksum differiscono fra provider e senza un account di prova per ciascuno si «verificherebbe» solo a parole.
- **Coppie libere sorgente→destinazione** e **regole per cartella**: scartate esplicitamente con la scelta 2.
- **Più di una libreria.**

## Rischi noti

- **La migrazione è il punto di rottura.** Se sbaglia, Enrico si ritrova l'app che non sa più dove sono i suoi dischi. Mitigazioni: bookmark copiati e non ricreati, chiavi vecchie non cancellate, idempotenza. Va provata **con i suoi dischi reali collegati**, non solo in test.
- **124 riferimenti da riscrivere** significa che una svista lascia un ramo di codice che parla ancora di `.ssd`. La suite (568 test) copre la logica pura, non il cablaggio: dopo la riscrittura, un `grep` che non trova più `\.ssd`/`\.hdd`/`\.photos` è un criterio di completamento migliore dei test.
- **`role` come attributo permette configurazioni assurde** (un dispositivo sorgente e destinazione di se stesso). Serve una validazione, e va scritta nel piano.

## Da definire in fase di piano

- Dove vivono i `Device`: `UserDefaults` (come oggi i bookmark) o un file JSON dedicato. Non SQLite — non è una cache e non serve interrogarlo (ADR-0004 riguarda l'indice, non questo).
- Se `RestoreSource` sparisce del tutto assorbito da `Device`, o resta come proiezione dei soli dispositivi da cui ha senso ripristinare.
- Come si presenta la stella in `SidebarView` senza disegnare un grafo.
- Ordine dei task, con il vincolo che l'app resti buildabile e la suite verde dopo ognuno.

## Prossimo passo

Piano di implementazione task per task. **Nessuna riga di codice è stata scritta**: questo documento è solo progettazione, l'app oggi funziona esattamente come prima.
