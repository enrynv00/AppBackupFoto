# CONTEXT — Linguaggio condiviso di AppBackupFoto

Il vocabolario del progetto. Serve a dire in una parola cose che altrimenti richiedono un paragrafo, e a non chiamare la stessa cosa con due nomi diversi in due sessioni diverse.

Regola d'uso: quando scrivi codice, un nome di test, un titolo di ticket o una spec, usa **il termine di questa pagina**, non un sinonimo. Se il concetto che ti serve non è qui, o stai inventando linguaggio che il progetto non usa (ripensaci), o c'è un vuoto reale (aggiungilo).

Le decisioni architetturali stanno in `Docs/adr/`. Lo stato e l'architettura in `Docs/CLAUDE.md`. Questa pagina è solo il dizionario.

---

## Le tre destinazioni

**Sorgente** — la Libreria Foto sul Mac. Read-only, sempre. Nessun percorso di codice ci scrive.

**SSD** — il disco esterno ExFAT (`/Volumes/SSD - Enri`). È la **libreria**: il posto dove le foto vivono davvero, aggregate da sorgenti eterogenee negli anni. Non è un mirror di nulla, è l'originale.

**HDD** e **Cubbit** — mirror dell'SSD, rispettivamente locale (`/Volumes/BackupHDD`) e remoto (S3). Sono copie: se divergono dall'SSD, è l'SSD ad avere ragione.

**Restore** — il verso opposto (SSD/HDD/Cubbit → Mac). Le foto ripristinate atterrano in una cartella normale, mai dentro il database di Foto.app.

---

## La regola assoluta

**Zero delete, zero overwrite, read-only sulla sorgente.** Vale in entrambi i versi, restore incluso. Non è un obiettivo di qualità: è il vincolo che decide quali design sono ammissibili. Un design che la viola è sbagliato, non "da valutare".

**Skip per zero-overwrite** — un file che esiste già a destinazione non viene mai sovrascritto, nemmeno se il contenuto è diverso. Viene saltato e **contato** (`changedSkipped`), mai modificato in silenzio.

**Perdita silenziosa** — la classe di bug che questo progetto teme più di ogni altra: non un errore visibile, ma uno scatto che **non viene copiato** mentre l'app dice che è andato tutto bene. È il criterio con cui si giudicano i design: "in quale caso questo codice salta un file credendo di fare la cosa giusta?"

---

## Indice di contenuto (roadmap #31)

**Indice** — la tabella SQLite che associa a ogni foto/video dell'SSD il suo SHA256. Vive sul disco interno del Mac, mai sull'SSD.

**L'indice è una cache, non una fonte di verità.** Nulla al suo interno è dato originale, è sempre ricostruibile da zero, e nessun percorso di codice deve trattarne l'assenza o la corruzione come un errore fatale. Da qui discende quasi tutto il resto del design.

**Doppione** — due file **byte-identici**, e nient'altro. Non "visivamente uguali", non "stessa foto in formati diversi": stesso SHA256. Foto ricodificate da Takeout, coppie HEIC/JPG e versioni ridimensionate **non** sono doppioni per questo progetto. Scelta deliberata: un falso positivo significherebbe non importare una foto diversa credendola doppione, cioè una perdita silenziosa.

**Entry** — una riga dell'indice: chiave normalizzata, percorso da mostrare, dimensione, mtime, hash, istante di hashing.

**Chiave normalizzata** — il percorso relativo alla root SSD, in NFC e minuscolo. Serve perché ExFAT è case-insensitive e non normalizza l'Unicode mentre APFS preserva la normalizzazione originale: senza, lo stesso file produrrebbe due entry.

**Verdetto** — l'esito della domanda "l'hash memorizzato per questo file vale ancora?". Sono **quattro**, non tre: `fresh` (sì), `stale` (no, il file è cambiato), `needsVerification` (non possiamo escluderlo, si rihasha), `timezoneShift` (cambio di ora legale, si adotta il nuovo mtime **senza** rihashare). È logica pura, senza filesystem né database.

**Percorso a basso danno / percorso ad alto danno** — la distinzione che regge tutto il modello di fiducia. I livelli sono **tre**, non due, dal 2026-08-27 (ADR-0005):

- **Mostrare** un gruppo di doppioni nel pannello è a **basso danno**: ci si fida della cache, e un hash stantio produce una riga sbagliata in un elenco.
- **Saltare** un file durante un import è ad **alto danno**: una foto non importata, in silenzio. Si rilegge e si rihasha **il file candidato** prima di decidere lo skip.
- **Cestinare** un gruppo dal pannello è il **danno più alto dell'intero progetto**: si sposta nel Cestino una foto che sull'SSD era l'unica copia. Si rilegge e si rihasha **ogni membro del gruppo, la copia tenuta compresa**, e si pretende unanimità.

Attenzione a una frase che questa pagina ha portato fino al 2026-08-27: «il pannello Doppioni è il percorso a basso danno». Vale ora **solo per la visualizzazione**. Da quando il pannello può cestinare, mostrare e cancellare sono due usi con due livelli di fiducia diversi dentro la stessa finestra.

**Regola anti-racy** — presa da git e borg: se un file risulta modificato entro un margine da quando ne abbiamo calcolato l'hash, non possiamo escludere che sia cambiato subito dopo la lettura mantenendo lo stesso mtime. Margine 2 secondi.

**Tolleranza DST** — uno shift di mtime di esattamente 3600s o 1800s a dimensione identica è quasi certamente un cambio di fuso su ExFAT, non una modifica: si **adotta il nuovo mtime tenendo l'hash già calcolato** (verdetto `timezoneShift`), invece di invalidare in blocco. Questa pagina diceva "si riverifica": era la prima stesura, e con quella semantica la regola non faceva assolutamente nulla — riverificare significa rihashare, cioè esattamente ciò che la regola esiste per evitare. Corretto nel codice il 2026-08-25 e qui il 2026-08-27. **Senza prior art**: è una scelta di questo progetto, marcata come tale nel codice.

**Guardia di plausibilità** — se una scansione vede sparire più della metà dell'indice, è quasi sempre un'interruzione non riconosciuta, non una cancellazione reale: nel dubbio l'indice si tiene. La **Ricostruzione completa** è la via d'uscita, ma solo da questa guardia: **non** scavalca la regola più forte "traversata incompleta ⇒ non si toglie niente". Se l'utente ha davvero svuotato l'SSD l'unica uscita è **svuotare l'elenco** (`deleteIndexAndRecreate`), che è il solo comando distruttivo della card.

**Ricostruzione completa** (`ignoringStoredHashes`) — rihasha tutto senza fidarsi di nulla di memorizzato. Azione esplicita dell'utente, che significa "fidati del disco". Tutti i tool esaminati (rsync, restic, borg, rmlint) ne offrono una.

**Passo 2 del backup** (2026-09-19, ADR-0007) — l'aggiornamento dell'indice dopo un MAC → SSD o un'importazione, che dal 2026-09-19 non è più una lettura separata avviata *dopo* la fine del job, ma l'ultima parte del job stesso: stessa barra, stesso «Interrompi», riepilogo e notifica solo alla fine. Il job resta «in corso» per tutta la sua durata. Se l'utente interrompe durante il passo 2 il backup risulta comunque **completato** (le foto sono copiate e verificate), con una riga che dice che l'indice non è stato aggiornato — mai «interrotto». Al collegamento dell'SSD non parte più nessuna lettura da sola: l'indice si aggiorna solo come passo 2 di un job, o a mano da Diagnostica.

---

## Pannello Doppioni (roadmap #31)

**Gruppo di doppioni** — l'insieme dei file dell'SSD che condividono lo stesso SHA256, con **almeno due membri**. Un gruppo ridotto a un solo membro non è un gruppo: va saltato, non mostrato. Proporre di "tenere" l'unica copia esistente è una riga che dichiara doppione un file che copie non ne ha.

**Copia tenuta** — il membro del gruppo che l'app propone di **non** cestinare. La proposta segue una gerarchia (libreria principale → cartella organizzata invece che import → la più vecchia → tie-break deterministico sul percorso), ed è **spiegata a parole**, mai solo evidenziata: una proposta evidenziata e non spiegata si conferma senza sapere cosa si sta confermando. Resta una proposta: l'utente può cambiarla gruppo per gruppo prima di confermare.

**Gruppo certificato** (termine nuovo, 2026-10-05, ADR-0017) — un gruppo di doppioni che si può spuntare: l'ultimo inventario è completo su SSD, HDD e Cubbit, nessun backup o import ha scritto dopo l'inizio di quel giro, il contenuto è ✅ «Al sicuro», e ogni copia del gruppo — la tenuta e quelle che escono — è nell'inventario dell'SSD di quel giro con lo stesso contenuto. Un gruppo non certificato resta visibile, con la casella spenta e il motivo. La certificazione si aggiunge alla rilettura dal disco al momento dello spostamento, non la sostituisce.

**Inventario fresco** — completo su tutti e tre gli archivi e più recente dell'ultimo job che scrive sugli archivi (Mac → SSD, SSD → HDD, SSD → Cubbit, import). Lo invecchia anche un job che non ha copiato niente; non lo invecchiano spostamenti nel Cestino, annullamenti, riparazioni, inventario, lettura dell'elenco.

**Percorso tenuto** — nel registro del Cestino e nella storia degli spostamenti, per ogni foto spostata, il percorso della copia rimasta, relativo alla radice dell'SSD: è lo stesso percorso sull'HDD e la stessa chiave su Cubbit, e il progetto 4 terrà quella.

**Membri a pari merito** — le copie che valgono quanto quella tenuta, e fra cui ha deciso solo il tie-break. Vanno **marcate nella lista**, non solo contate: sapere che «un'altra copia va bene quanto questa» senza sapere *quale* è un'informazione vera e non azionabile.

**Blocco** — l'unità di lavoro della cancellazione: un sottoinsieme dei gruppi spuntati dall'utente, smaltito tutto insieme, senza mai spezzare un gruppo fra due blocchi. **Tetto: 2.000 file o 50 GB** (aggiornato il 2026-09-25, ADR-0012 — prima era 500 file o 50 GB), il primo che scatta; 2.000 non è un numero scelto a parte, è la stessa granularità del registro di ripristino (`TrashManifestStore.maxItems`), un invariante protetto da un test dedicato. Il tetto resta scelto sul **raggio del danno**, non sulla durata — un guasto a metà blocco è uno stato reale e misurato.

**Corsa** (termine nuovo, 2026-09-25, ADR-0012) — l'intera selezione confermata dall'utente, divisa in uno o più blocchi al tetto sopra e smaltita **da sola**, un blocco dopo l'altro, senza altro intervento. Alla scala reale (decine di migliaia di gruppi) una selezione supera quasi sempre il tetto di un blocco: la UI non dice più «fallo in più volte» e non rifiuta — mostra quanti blocchi servono e quanto durerà circa, poi li smaltisce tutti. **«Annulla l'ultimo spostamento» copre solo l'ultimo blocco della corsa, non l'intera corsa**: con più di un blocco l'utente lo legge prima di confermare (nel riepilogo e di nuovo nell'alert distruttivo), perché è l'ultimo schermo prima del punto di non ritorno. Non si lavora un gruppo alla volta (600 clic portano a confermare a occhi chiusi) né tutto insieme in un solo blocco senza limite (un guasto a metà comprometterebbe una quantità di file senza raggio contenuto).

**Regola per cartella** (termine nuovo, 2026-09-25, ADR-0011) — una preferenza esplicita dell'utente («tieni la copia in X, sposta nel Cestino quelle in Y, Z…») che entra in `duplicateKeepChoice` **prima** delle euristiche automatiche, e solo sui gruppi che copre davvero (un membro nella cartella da tenere e almeno uno in una cartella da cestinare, nessun membro altrove). Esiste perché alla scala reale decidere gruppo per gruppo non è praticabile: la regola decide una volta per tutti i gruppi che descrive.

**Registro di ripristino** — il file che l'app scrive, sul disco interno e mai sull'SSD, con un record per ogni file cestinato: percorso originale, percorso nel Cestino, dimensione, hash, istante. Scritto **file per file nel momento in cui il file viene spostato**, non a fine blocco, così sopravvive a un blocco interrotto. Esiste perché il record «Rimetti a posto» del Finder è asincrono e **si perde** se l'app muore subito dopo (misurato), e perché `.DS_Store` è un file che decine di strumenti cancellano di routine. È ciò che rende possibile «Annulla l'ultimo spostamento» senza dipendere dal Finder.

**Cestinare non è cancellare, e non libera spazio.** I file vanno nel Cestino del volume (`.Trashes/<uid>`), restano recuperabili, e lo spazio si libera **solo** quando l'utente svuota il Cestino — cosa che l'app non fa mai e non farà. E lo spazio si recupera solo sull'SSD: HDD e Cubbit tengono la loro copia per sempre, perché i mirror non cancellano mai.

---

## Inventario (roadmap #44)

**Archivio** — SSD, HDD o Cubbit, visti come tre posti in cui una foto può stare. Termine nuovo: prima "le tre destinazioni" bastava perché si parlava solo del verso Mac→SSD→HDD/Cubbit; l'inventario guarda ai tre come posti da confrontare fra loro, non come tappe di un backup.

**Inventario** — l'elenco del contenuto dei tre archivi, per contenuto e non per nome; è una cache come l'indice (ADR-0002), mai una fonte di verità. Vive nello stesso SQLite dell'indice.

**Certificato** — su Cubbit, un oggetto è certificato solo se il suo ETag coincide con quello di un file letto sull'SSD o sull'HDD della stessa dimensione (parte unica → MD5, a pezzi → ETag a pezzi da 64 MiB). Mai per ipotesi, mai per nome o percorso uguale.

**Non certificabile** — un oggetto Cubbit che non si può confrontare senza scaricarlo (parti di dimensione diversa da 64 MiB, o un ETag in un formato non riconosciuto). Finisce sempre in ❗, insieme alla foto allo stesso percorso sugli altri archivi.

**Incompleto ≠ assente** — da un archivio non letto per intero (un file o una cartella illeggibile, un disco sparito a metà lettura, una lista di Cubbit non arrivata in fondo) non si dichiara mai assente niente. Un disco scollegato non è un disco vuoto: «manca da X» si dice solo se X è completo.

**Giro** — un aggiornamento dell'inventario. «Presente» vuol dire «visto nell'ultimo giro», non «presente oggi»: un archivio scollegato durante un giro resta con lo stato del giro precedente, mai declassato a mancante.

---

## Riparazione (roadmap #45)

**Copia rovinata** — la copia di una foto, in UN archivio, con un contenuto diverso da quello identico negli altri due. «Diverso» va dimostrato: su un disco un SHA256 diverso, su Cubbit un ETag a parte unica (che è l'MD5) diverso. Un ETag a pezzi che non torna non dimostra niente.

**Regola «2 su 3»** — si scrive su un archivio solo se gli altri due hanno la stessa copia certificata. Senza una maggioranza (tre contenuti diversi, un archivio letto a metà, il percorso che manca da un archivio) non si ripara niente.

**Sorgente e testimone** — la sorgente è il file locale da cui si copia (SSD per riparare HDD o Cubbit, HDD per riparare l'SSD); il testimone è la seconda copia buona (HDD per Cubbit, Cubbit per i dischi). Entrambi si ricontrollano dal vivo prima di toccare qualunque cosa: l'inventario è una cache.

**Quarantena** — la cartella `_quarantena/<AAAA-MM-GG>/<percorso originale>` sullo stesso archivio, dove la riparazione mette da parte la copia che sostituisce, invece di cancellarla. Non rientra mai in backup, elenco, inventario, Doppioni, ripristino. Su Cubbit è idempotente: una copia già messa da parte, in qualunque giorno, con la stessa dimensione e lo stesso ETag della rovinata, vale come fatta. La svuota solo l'utente, dal Finder o da Cubbit.

**Registro delle riparazioni** — `repair-log.json` sul disco interno del Mac, mai su un archivio: una voce scritta «in corso» prima di toccare qualunque archivio, aggiornata con l'esito, con percorsi, impronte prima e dopo e posizione della quarantena.

---

## Import da sorgenti locali (roadmap #27-A)

**Sorgente di import** — una fotocamera, scheda SD, drone, vecchio disco o telefono da cui si importa una tantum. Diversa dalla **Sorgente** (la Libreria Foto), che è un flusso continuo.

**Etichetta** — il nome che l'utente dà a una sessione di import; diventa `<SSD>/Import/<etichetta>/`. Passa sempre da `importFolderSlug`, che è un **costruttore di nome sicuro**, non un abbellitore: garantisce una sola componente di path, niente caratteri di controllo, niente `.`/`..`, un limite in **byte** (non caratteri), e **mai un nome nascosto**.

**Guardia self-import** — il divieto di importare da una posizione che è già configurata (o che contiene la destinazione). Risolve i symlink su **entrambi i lati**; senza, un alias produce una ricorsione runaway.

---

## Come si lavora qui

**Fase di design** — brainstorming (domande una alla volta) → spec in `Docs/superpowers/specs/` → piano in `Docs/superpowers/plans/` → implementazione task per task. Mai saltata perché "sembra piccolo".

**Grilling** — intervista serrata su un piano o un design finché ogni ramo dell'albero delle decisioni è risolto. Trova ciò che il piano dà per assodato e non lo è.

**Verifica empirica** — la regola di prova del progetto: un comportamento non è noto finché non è stato **misurato**, e la lettura del codice non basta. Vale sia per i bug (il picco di memoria da 41GB fu misurato, non dedotto) sia per le assunzioni sull'ambiente (la granularità dei timestamp su ExFAT fu misurata su un'immagine disco usa-e-getta).

**Un test può codificare il bug** invece di trovarlo. Se un test passa sia con il codice giusto sia con quello sbagliato, non è una rete di protezione. Successo già visto tre volte qui: il parsing YAML di Immich testato con `contains`, `testCancelStopsScan`, e il test sulla root sparita che copriva il caso sbagliato.
