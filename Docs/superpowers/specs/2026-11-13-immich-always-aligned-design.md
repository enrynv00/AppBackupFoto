# Immich sempre allineato con l'SSD — design

**Stato:** approvato a voce da Enrico il 2026-11-13. Nessuna riga di codice scritta.
**Progetto A di 2** per #29 (A «sempre allineato» → B «veloce»: miniature, ricerca, volti, interfaccia).
**Base:** `main` a `9d48e24` (1.525 test).
**Numerazione riservata:** ADR-0021, ROADMAP #50.

## Perché

Enrico vuole che la finestra Foto funzioni «stile Google Foto»: le foto nuove compaiono da sole, niente doppioni o foto rotte, niente avvio a mano. Oggi l'app avvia e ferma Immich e mostra la sua interfaccia web, nient'altro. Lo stato misurato il 2026-11-13, leggendo il database di Immich 3.2.0 in sola lettura:

| Cosa | Numero | Causa |
|---|---|---|
| Ultima scansione della libreria `SSD - Enri` | 2026-10-11 00:00 | Immich scansiona solo con il suo cron di mezzanotte, e solo se a quell'ora l'app è aperta |
| Foto attive in Immich | 52.139 | contro 52.590 file censiti sull'SSD dall'inventario: le foto arrivate dopo l'11/10 mancano |
| Foto offline, già nel Cestino di Immich | 89.514 | le copie doppie tolte dall'SSD a ottobre (#46). Il Cestino di Immich si svuota solo col cron di mezzanotte |
| Foto cestinate a mano in Immich, non offline | 31 | gesto di Enrico dentro Immich |
| Foto in gruppi di «simili» di Immich | 22.392 | contenuto diverso byte per byte (checksum tutti distinti), quindi fuori dal pannello Doppioni dell'app. Per cartella: ASUS 13.526, Takeout 4.585, Takeout 2 2.237, Other 1.077, Foto Google Drive 540, Foto iPhone 399, Import 28 |
| Foto non ancora passate dal rilevamento simili | 19.076 | coda ML ancora in corso: i gruppi cresceranno |
| Immagini con lato lungo sotto i 400 px | 4.561 | soprattutto anteprime recuperate (`ASUS/foto/recup_dir.*`): in griglia sembrano rotte |
| Foto senza miniatura | 57 | da guardare nel progetto B |

## Decisioni di Enrico (2026-11-13)

1. **Avvio:** Immich parte da solo all'apertura dell'app se l'SSD è collegato, e quando l'SSD viene collegato dopo. Si ferma alla chiusura dell'app (come oggi) e quando l'SSD viene scollegato.
2. **Quando allineare:** dopo ogni backup Mac → SSD, dopo ogni import, dopo ogni spostamento di doppioni nel Cestino, e a ogni avvio di Immich.
3. **Simili e minuscole:** le foto simili vengono **impilate** (una davanti, le altre dietro). Le immagini con lato lungo sotto i 400 px vengono **archiviate** (escono dalla griglia, restano in «Archivio» di Immich). Nessun file sull'SSD viene toccato.
4. **Strada:** l'app guida Immich con la sua API (scartate: solo impostazioni dentro Immich, che non impilano e girano solo col cron; scrittura diretta nel database di Immich, che si rompe al primo aggiornamento).

## Regole

1. **L'SSD resta in sola lettura per Immich.** Non cambia niente: bind mount `:ro` nel compose e montaggio di Colima senza `:w`. Tutto quello che l'allineamento fa (togliere offline, impilare, archiviare) tocca **solo il database di Immich**.
2. **Mai «risolvi duplicati» di Immich** (`POST /duplicates/resolve`, `DELETE /duplicates`): cancellano. Solo pile (`POST /stacks`).
3. **Mai scansionare senza SSD.** Una scansione con il punto di montaggio vuoto segnerebbe offline tutte le 52.139 foto, e il passo 2 le toglierebbe da Immich con volti, album e pile. Due guardie:
   - prima della scansione, e di nuovo prima di togliere le offline: `VolumeMonitor.ssdMounted` vero (che conta solo un vero punto di montaggio, `VolumeCapacityReader.isMounted`, #40);
   - dopo la scansione: se le foto attive della libreria sono calate di più di **500** o di più del **2 %** rispetto a un **riferimento ricordato**, le offline non si tolgono, l'allineamento si ferma e la finestra Foto lo dice. Le foto restano nel Cestino di Immich, recuperabili. Il riferimento è il numero di foto attive dopo l'ultimo allineamento riuscito, salvato in `immich-alignment.json`; al primo giro è il numero prima della scansione, e **viene salvato subito anche quando la guardia scatta**. Così un «Riprova» con l'SSD ancora vuoto dentro la macchina virtuale scatta di nuovo invece di confrontarsi con un numero già crollato. Uno spostamento di doppioni dell'app abbassa il riferimento di quanti file ha spostato. Per un calo voluto e più grande, la finestra offre «Togli comunque», dopo una conferma che dice quante foto escono da Immich; il riferimento diventa allora il numero attuale. Soglia scelta perché il blocco più grande dei Doppioni (#46) è di 500 file.
   - Verificato il 2026-11-13 che Immich non indicizza le cartelle nascoste: 0 foto con un componente nascosto nel percorso (`.Trashes` compreso, che sull'SSD esiste). Le copie spostate nel Cestino dell'SSD diventano offline, non doppioni.
4. **Si toglie solo ciò che è offline e già nel Cestino di Immich**, e appartiene alla libreria dell'SSD (`importPaths` contiene `/external-ssd`). Le 31 cestinate a mano restano.
5. **Ciò che Enrico disfa non si rifà.** Se toglie una foto dall'Archivio o separa una pila, l'allineamento successivo non la riarchivia e non la reimpila. L'app tiene l'elenco degli ID già archiviati e dei gruppi già impilati in `~/Library/Application Support/AppBackupFoto/immich-alignment.json` (mai sull'SSD).
6. **Idempotente.** Rifare l'allineamento su uno stato già allineato non cambia niente in Immich.
7. **Un errore di Immich non fa mai fallire un backup.** L'allineamento parte dopo che il job ha finito, in background, e il suo esito si vede solo nella finestra Foto.

## Componenti

### 1. Avvio e arresto automatici (`ImmichAutoStart`)

- All'avvio dell'app: se Immich è installato e `ssdMounted` è vero, `ImmichManager.start(sourceLibraryPath:)`.
- Su `ssdMounted` falso → vero: stessa cosa. Su vero → falso: `ImmichManager.stop()`.
- Funzione pura `ImmichAutoStart.action(installed:ssdMounted:wasMounted:isRunning:isStarting:) -> .start | .stop | .none`, testata da sola.
- Finestra Foto: sparisce il pulsante «Avvia Immich». Restano gli stati «Immich non installato» (con «Installa»), «Avvio di Immich…», «SSD non collegato», l'interfaccia web e l'errore di avvio con un pulsante «Riprova».

### 2. Chiave API (`ImmichCredentials`)

- Al primo allineamento senza chiave, la finestra Foto mostra un foglio con email e password di Immich (senza chiave l'app non può leggere l'email da Immich, quindi il campo parte vuoto).
- L'app fa `POST /auth/login`, con il token crea una chiave (`POST /api-keys`, nome «AppBackupFoto — allineamento») e poi `POST /auth/logout`. La password non viene mai salvata né scritta nel log.
- Chiave nel Portachiavi: servizio `AppBackupFoto`, account `immich-api-key`, stesso schema di `S3Syncer.writeToKeychain`.
- **Permessi della chiave**, lista chiusa: `library.read`, `library.update`, `asset.read`, `asset.update`, `asset.delete`, `duplicate.read`, `stack.create`, `stack.read`, `job.read`, `library.statistics`. Esclusi di proposito: `library.delete`, `duplicate.delete`, `user.*`, `apiKey.*`, `stack.delete`. `asset.delete` serve per togliere le offline (`DELETE /assets` con `force: true`) e tocca solo il database: la regola 1 vale comunque.
- Su 401 o 403: la chiave si considera non valida e la finestra chiede di nuovo la password.
- La vecchia chiave «AppBackupFoto» creata a mano il 2026-09-13 resta com'è.

### 3. Client API (`ImmichAPIClient`)

Sottile, `nonisolated`, `URLSession`, header `x-api-key`, solo verso `ImmichManager.webUIURL` (`127.0.0.1:2283`). Endpoint usati:

| Scopo | Endpoint |
|---|---|
| trovare la libreria dell'SSD | `GET /libraries` (quella con `/external-ssd` negli `importPaths`; la vecchia «New External Library» senza percorsi si ignora) |
| scansione | `POST /libraries/{id}/scan` |
| attendere la fine della scansione | `GET /jobs` (coda `library` senza lavori attivi, in attesa o rimandati). Non si aspetta la coda `duplicateDetection`: con 19.076 foto ancora da analizzare terrebbe fermo ogni allineamento per il tetto intero; le pile si fanno con i gruppi che ci sono e crescono ai giri dopo |
| offline nel Cestino | `POST /search/metadata` con `libraryId`, `isOffline: true`, `withDeleted: true`, a pagine |
| togliere le offline | `DELETE /assets` `{ids, force: true}`, a blocchi di 500 |
| gruppi di simili | `GET /duplicates` |
| impilare | `POST /stacks` `{assetIds}` (il primo è quello davanti) |
| minuscole | `POST /search/metadata` con `libraryId`, `type: IMAGE`, `visibility: timeline`, `withExif: true`, a pagine |
| archiviare | `PUT /assets` `{ids, visibility: "archive"}`, a blocchi di 500 |

`PUT /assets` è segnato «Deprecated» in 3.2.0 (sostituto `updateAssets`) ma funziona: il piano verifica il sostituto e usa quello se è già stabile.

### 4. Logica pura (`ImmichAlignmentRules`)

Testabile senza Immich:

- `offlineToRemove(assets, libraryId)`: solo `isOffline && isTrashed && libraryId` uguale.
- `offlineGuardTripped(newOffline:activeCount:)`: vero oltre 500 o oltre il 2 %.
- `stackPrimary(group)`: più pixel (`exifImageWidth × exifImageHeight`); a parità il file più grande; a parità l'ID più piccolo (ordine stabile). Membri senza dimensioni vanno in fondo.
- `groupsToStack(groups, state)`: salta i gruppi già impilati (registrati in `immich-alignment.json`) e i gruppi in cui una foto è già in una pila, per non fondere pile fatte da Enrico.
- `isTiny(asset)`: solo immagini, lato lungo sotto 400 px; senza dimensioni → no.
- `assetsToArchive(assets, state)`: minuscole, ancora in griglia, mai archiviate prima dall'app.

### 5. Allineamento (`ImmichAligner`)

Un solo allineamento alla volta. Una richiesta mentre ne gira uno lo rifà **una** volta alla fine (non si accodano N giri). Passi:

1. Guardie della regola 3 (prima parte). Chiave presente. Libreria trovata.
2. Scansione, poi attesa della fine (tetto 30 minuti, poi si prosegue con quello che c'è).
3. Guardia della regola 3 (seconda parte), poi toglie le offline.
4. Impila i gruppi di simili.
5. Archivia le minuscole.
6. Salva `immich-alignment.json` e l'esito.

Chiamato da: fine di `runMacToSSD`, fine di `runImport`, fine di uno spostamento di doppioni andato a buon fine, `ImmichManager.start` riuscito. Se Immich non è acceso, la richiesta resta in sospeso fino al prossimo avvio (che allinea comunque).

### 6. Esito nella finestra Foto

Una riga discreta sopra l'interfaccia web:

- durante: «Aggiorno Immich con le foto dell'SSD…»;
- fine: «Immich aggiornato alle 22:41: 12 foto nuove, 89.514 offline tolte, 340 pile, 4.561 archiviate» (si mostrano solo i numeri non zero; «foto nuove» è la differenza fra le foto attive della libreria prima e dopo la scansione, `GET /libraries/{id}/statistics`, che si aggiunge così ai permessi già elencati: `library.statistics`);
- errore: «Immich non aggiornato: <motivo>», con «Riprova» e, per la chiave, «Inserisci la password».

L'esito va anche nel log dell'app, mai la chiave o la password.

### 7. Versione di Immich fissata

Il compose oggi usa `immich-server:release` e `immich-machine-learning:release`, che cambiano da soli a ogni versione nuova. Si fissano a `v3.2.0` (quella in uso e su cui gli endpoint sopra sono verificati). Nessun cambio per lo stack acceso oggi: `release` è già 3.2.0. Aggiornare Immich diventa una scelta, con il numero cambiato nel codice.

## Test

- **Automatici:** `ImmichAutoStart.action` (tutte le combinazioni), le funzioni di `ImmichAlignmentRules` (offline, guardia, foto davanti, gruppi saltati, minuscole, già archiviate), elenco dei permessi della chiave (nessun permesso escluso), compose con `v3.2.0` (estende `ImmichComposeFileTests`), decodifica delle risposte JSON reali di Immich 3.2.0 salvate come fixture, unione delle richieste di allineamento.
- **Dal vivo** con Enrico:
  1. avvio dell'app con l'SSD collegato → Immich parte da solo;
  2. prima chiave: password inserita, chiave nel Portachiavi, nessuna password nel log;
  3. primo allineamento: le 89.514 offline spariscono dal Cestino di Immich, le 31 restano; le foto dopo l'11/10 compaiono; pile e Archivio con i numeri attesi;
  4. import di una foto nuova → compare in Immich senza toccare niente;
  5. una foto tolta a mano dall'Archivio non ci torna al giro dopo;
  6. SSD scollegato → Immich si ferma; ricollegato → riparte e allinea.

## Fuori da questo progetto

- Velocità di miniature, ricerca e volti, le 57 senza miniatura, l'interfaccia (progetto B).
- Cosa tenere delle foto simili **sull'SSD**: Immich le impila soltanto. Se un giorno si vorrà toglierle dall'SSD servirà un progetto con le garanzie di #46.
- Accesso da telefono, Immich acceso ad app chiusa.
