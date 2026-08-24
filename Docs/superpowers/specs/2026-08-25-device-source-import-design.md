# Spec — Importazione da sorgenti generiche (roadmap #27, sotto-progetto A)

## Problema

Enrico ha foto sparse su molti dispositivi vecchi e nuovi di brand diversi (fotocamere, droni, telefoni fuori produzione, vecchi SSD) e vuole poterle importare nel sistema in modo semplice, anche in vista dell'obiettivo dichiarato il 2026-08-10 di distribuire l'app in futuro a persone senza competenze tecniche.

Il testo originale di roadmap #27 immaginava un "configuratore generico di dispositivi" che sostituisse i 4 ruoli fissi attuali (Mac/SSD/HDD/S3) sia per le sorgenti sia per le destinazioni — un cambio architetturale profondo. In brainstorming (2026-08-25, one-question-at-a-time) lo scope è stato ridotto e scomposto:

- **Le destinazioni restano fisse** (SSD/HDD/Cubbit S3 come oggi) — nessun lavoro su `BookmarkManager`/`S3Syncer` per destinazioni generiche in questa fase.
- **L'importazione da servizi cloud di terzi** (Google Foto, iCloud) è un sotto-progetto separato ("B"), non affrontato qui: richiede OAuth/API di terzi, complessità/rischio paragonabili a Immich (#29), va affrontato con una ricerca preliminare dedicata quando Enrico deciderà di riprenderlo.
- **Questa spec copre solo il sotto-progetto "A"**: importare foto da sorgenti locali generiche (dispositivi collegati live via USB/lettore SD, o cartelle/dischi già esistenti con foto scaricate in passato) verso l'SSD.
- **La consultazione via Immich (#29) non richiede modifiche**: una volta che le foto arrivano sull'SSD, da qualunque sorgente, Immich le indicizza comunque tramite la External Library già prevista.

## Decisioni prese in brainstorming (2026-08-25, one-question-at-a-time)

- **Uso dell'app**: resta single-user/single-installazione (nessun multi-utente, nessun accesso remoto) — "persone senza competenze" si riferisce a un futuro utente non tecnico su una propria installazione, non a più persone sullo stesso Mac o account condivisi.
- **Natura dell'import**: perlopiù **una tantum** — si collega un vecchio dispositivo/disco, si importa tutto una volta, non lo si ricollega più. Niente sistema di "dispositivi configurati" persistenti (niente nuovi bookmark, niente nuovo modello dati) — ogni import è un'operazione indipendente.
- **Trigger**: **wizard su richiesta** (Approccio 1, scelto su un rilevamento automatico al collegamento — quest'ultimo rimandato a un'eventuale iterazione futura una volta verificato che il flusso base funziona). Una nuova voce "Importa foto" nel menu hamburger, sempre disponibile.
- **Destinazione sull'SSD**: **una sottocartella dedicata per ogni import** (non una struttura condivisa), per eliminare alla radice il rischio di collisione tra nomi file generici che si ripetono da dispositivo a dispositivo (es. `IMG_0001.jpg`, `DSC0001.jpg` sono comunissimi su vecchie fotocamere/telefoni) — con una struttura condivisa, il controllo zero-overwrite basato sul nome rischierebbe di scartare per errore foto diverse con lo stesso nome.

## Design tecnico

### Punto d'ingresso

Nuova voce "Importa foto" nel menu hamburger (`HamburgerRow`), accanto a "Ripristina". Sempre abilitata — non richiede che SSD/HDD siano già collegati per aprirsi, solo per completare l'import (la sorgente scelta potrebbe anche non essere ancora nota all'apertura del wizard).

### `ImportView` — wizard a 4 passi

Nuova `View`, presentata come `.sheet` da `ContentView` (stesso pattern di `RestoreView`, **non** una nuova `Window` scene — eredita quindi il gate Touch ID già attivo su `ContentView`, nessun gating aggiuntivo da scrivere).

1. **Scelta sorgente**: `NSOpenPanel` (`canChooseDirectories: true`, `canChooseFiles: false`, `allowsMultipleSelection: false`) — funziona per qualsiasi cartella/volume visibile al Mac: SD card, vecchio SSD o telefono montato come storage, cartella scaricata a mano da Google Foto/iCloud.
   - **Guardia self-import**: se il path scelto coincide con (o è contenuto in, o contiene) uno dei path già configurati in `BookmarkManager` (Libreria Foto, SSD, HDD), mostra un alert esplicito e blocca — evita un import senza senso della libreria dentro sé stessa.
2. **Anteprima**: riuso **invariato** di `FileSyncer.previewSync(from:to:deep:)` — numero di file da copiare, spazio necessario. Riuso di `hasSufficientSpace` (stesso controllo già usato da Mac→SSD e SSD→HDD, margine 5%/min 500MB) contro lo spazio libero sull'SSD.
3. **Etichetta destinazione**: campo di testo precompilato con `<nome volume o cartella sorgente> - <data odierna>` (es. "EOS_DIGITAL - 2026-08-25"), modificabile liberamente. Slug per un nome cartella sicuro (rimozione caratteri non validi in un path, es. `/`, `:`).
4. **Copia**: `BackupRunner.runImport(source: URL, label: String)` (nuovo metodo, stesso schema di `runMacToSSD`/`runSSDToHDD` — vedi `.claude/rules/architecture.md`) chiama `FileSyncer.sync(from: source, to: ssdURL/Import/<slug>, deep: false, ...)`, **invariato**. Stessa UI di progresso già esistente (`StatsPanel`, miniatura file corrente via `onCurrentFile`, grafico velocità, `CompletionSheet` a fine job).

### Dove atterrano i file

`<SSD>/Import/<etichetta-slug>/` — nuova sottocartella dedicata per ogni sessione di import, mai dentro la struttura esistente ("Foto iPhone", "Foto Google Drive", ecc.). Nessun nuovo bookmark: riusa `BookmarkManager.urls[.ssd]` già esistente, stessa validazione `isLikelyVolumeRoot` sul bookmark SSD già presente negli altri flussi. Nessuna logica nuova per la creazione della cartella `Import/`: `FileSyncer.sync` già crea `dst` (con `withIntermediateDirectories: true`) se non esiste — verificato leggendo il codice attuale, comportamento identico a come "Foto iPhone" viene creata al primo Mac→SSD.

### Cosa NON cambia

- `FileSyncer`/`S3Syncer`/`BookmarkManager`: nessuna modifica. Zero-overwrite, verifica SHA256 post-copia, esclusioni (`.DS_Store` ecc.) restano quelli già collaudati.
- `VolumeMonitor`: invariato, resta sui 2 path fissi SSD/HDD — nessun rilevamento automatico di nuovi volumi in questa fase.
- Nessuna nuova destinazione, nessuna modifica alle 3 destinazioni fisse esistenti (SSD/HDD/Cubbit).

## Fuori scope (deciso esplicitamente)

- Rilevamento automatico al collegamento del dispositivo (Approccio 2) — possibile iterazione futura, non bloccante per questa spec.
- Import da servizi cloud di terzi (Google Foto, iCloud) — sotto-progetto B separato, richiede ricerca preliminare dedicata.
- Configurazione persistente/riusabile di un dispositivo (bookmark dedicato, re-import solo dei file nuovi) — scartata: la maggior parte dei casi reali di Enrico è un'importazione una tantum.
- Destinazioni generiche (NAS, altri provider S3) — restano SSD/HDD/Cubbit fissi.
- Qualsiasi modifica alla consultazione via Immich (#29) — resta invariata, indicizza l'SSD indipendentemente da come le foto ci sono arrivate.

## Rischi noti, accettati esplicitamente

- **Nessuno strutturale**: questa feature riusa quasi interamente codice già collaudato (`FileSyncer.sync`/`previewSync`, `hasSufficientSpace`, pattern `run(label:)` di `BackupRunner`) — il rischio principale è la correttezza della guardia self-import e dello slug etichetta→nome cartella, entrambi coperti da test.
- **Proliferazione di sottocartelle in `Import/`**: ogni import una tantum crea una cartella propria — nel tempo `Import/` potrebbe accumulare molte sottocartelle. Accettato: coerente con la scelta di isolare ogni import per evitare collisioni di nomi file; Immich (se disponibile) resta comunque il modo previsto per *consultare* le foto per metadati, non per cartella.

## Prossimo passo

Spec da approvare esplicitamente da Enrico prima del piano di implementazione.
