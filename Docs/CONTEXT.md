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

---

## Pannello Doppioni (roadmap #31)

**Gruppo di doppioni** — l'insieme dei file dell'SSD che condividono lo stesso SHA256, con **almeno due membri**. Un gruppo ridotto a un solo membro non è un gruppo: va saltato, non mostrato. Proporre di "tenere" l'unica copia esistente è una riga che dichiara doppione un file che copie non ne ha.

**Copia tenuta** — il membro del gruppo che l'app propone di **non** cestinare. La proposta segue una gerarchia (libreria principale → cartella organizzata invece che import → la più vecchia → tie-break deterministico sul percorso), ed è **spiegata a parole**, mai solo evidenziata: una proposta evidenziata e non spiegata si conferma senza sapere cosa si sta confermando. Resta una proposta: l'utente può cambiarla gruppo per gruppo prima di confermare.

**Membri a pari merito** — le copie che valgono quanto quella tenuta, e fra cui ha deciso solo il tie-break. Vanno **marcate nella lista**, non solo contate: sapere che «un'altra copia va bene quanto questa» senza sapere *quale* è un'informazione vera e non azionabile.

**Blocco** — l'unità di lavoro della cancellazione: i gruppi che l'utente ha spuntato, smaltiti insieme dopo un riepilogo dettagliato e una conferma. **Tetto: 500 file o 50 GB**, il primo che scatta. Il tetto è scelto sul **raggio del danno**, non sulla durata — un guasto a metà blocco è uno stato reale e misurato. Oltre il tetto la UI dice «fallo in più volte», non rifiuta e basta. Non si lavora un gruppo alla volta (600 clic portano a confermare a occhi chiusi) né tutto insieme (la conferma diventa un rituale).

**Registro di ripristino** — il file che l'app scrive, sul disco interno e mai sull'SSD, con un record per ogni file cestinato: percorso originale, percorso nel Cestino, dimensione, hash, istante. Scritto **file per file nel momento in cui il file viene spostato**, non a fine blocco, così sopravvive a un blocco interrotto. Esiste perché il record «Rimetti a posto» del Finder è asincrono e **si perde** se l'app muore subito dopo (misurato), e perché `.DS_Store` è un file che decine di strumenti cancellano di routine. È ciò che rende possibile «Annulla l'ultimo spostamento» senza dipendere dal Finder.

**Cestinare non è cancellare, e non libera spazio.** I file vanno nel Cestino del volume (`.Trashes/<uid>`), restano recuperabili, e lo spazio si libera **solo** quando l'utente svuota il Cestino — cosa che l'app non fa mai e non farà. E lo spazio si recupera solo sull'SSD: HDD e Cubbit tengono la loro copia per sempre, perché i mirror non cancellano mai.

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
