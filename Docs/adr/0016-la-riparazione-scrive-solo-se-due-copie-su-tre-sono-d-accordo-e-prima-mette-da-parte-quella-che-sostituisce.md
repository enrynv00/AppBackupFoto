# ADR-0016 — La riparazione scrive solo se due copie su tre sono d'accordo, e prima mette da parte quella che sostituisce

**Data:** 2026-10-04
**Stato:** Accettata

## Contesto

Il primo inventario completo (ADR-0015, ROADMAP #44) ha trovato una foto rovinata su Cubbit: `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic`, integra e identica su SSD e HDD, su Cubbit con la stessa dimensione e gli ultimi 38.796 byte a zero (verificato scaricandola, 2026-10-01). Il backup non se ne accorge perché confronta solo la dimensione, e per la regola zero-overwrite non la ricaricherebbe comunque. Ripararla vuol dire sovrascrivere un file: la prima eccezione a zero-overwrite. Lo stesso meccanismo servirà ai progetti 3 e 4 (doppioni con garanzia). Spec: `Docs/superpowers/specs/2026-10-01-repair-from-majority-design.md`; piano: `Docs/superpowers/plans/2026-10-04-repair-from-majority.md`.

Fatti verificati prima di progettare (2026-10-04): Cubbit accetta la copia lato server (`CopyObject`, provata con `rclone copyto` sulla `.heic`: ETag identico); il bucket non ha versioni.

## Opzioni valutate

- **A. Ricaricare la foto a mano con rclone.** Scartata: nessun ricontrollo, nessuna traccia, e la prossima foto rovinata si ripresenta uguale.
- **B. Sovrascrivere la copia diversa con quella dell'SSD, sempre.** Scartata: l'SSD può essere lui la copia rovinata (decisione 2 di Enrico: si ripara anche l'SSD), e una sovrascrittura senza quarantena non è annullabile.
- **C. Regola «2 su 3» con quarantena (scelta).** Si scrive solo se due archivi hanno lo stesso contenuto certificato e il terzo uno dimostrato diverso; prima si ricontrolla tutto dal vivo (l'inventario è una cache, ADR-0002), si mette da parte la copia diversa in `_quarantena/<giorno>/<percorso>` sullo stesso archivio, poi si scrive e si verifica.
- **D. Svuotare la quarantena dall'app.** Scartata da Enrico (decisione 4): la svuota lui dal Finder o da Cubbit.

## Decisione e motivo

**Quando:** tre archivi completi nell'ultimo giro; stesso percorso, una volta, in ciascuno; due d'accordo (SHA256 fra SSD e HDD; su Cubbit l'ETag che certifica quel contenuto); il terzo dimostrato diverso — su un disco un SHA256 diverso, su Cubbit un ETag a parte unica (l'MD5) diverso. Un ETag a pezzi che non torna non dimostra niente e la voce resta in ❗. Una riparazione alla volta, con riepilogo e conferma.

**Da dove:** sempre da un file locale — l'SSD per riparare HDD o Cubbit, l'HDD per riparare l'SSD; la seconda copia buona (HDD per Cubbit, Cubbit per i dischi) deve coincidere anche lei, al ricontrollo.

**Come, senza perdere mai una copia:** su disco solo `rename(2)` sullo stesso volume (mai `removeItem`, mai `FileManager.moveItem`, che fra due volumi copia e cancella); la copia buona si prepara e si rilegge **prima** di spostare quella rovinata, così un fallimento non lascia mai il percorso vuoto. Su Cubbit: copia lato server in quarantena (idempotente: una copia già messa da parte un altro giorno, con la stessa dimensione e lo stesso ETag, vale), HEAD della copia, poi la sola sovrascrittura del progetto con l'`upload` del backup, poi HEAD con l'ETag atteso. Un registro sul Mac (`repair-log.json`) scritto **prima** di toccare qualunque archivio e aggiornato con l'esito.

**La quarantena non rientra mai** in backup, elenco, inventario, Doppioni, ripristino, campione d'integrità: un nome solo (`LibraryExclusions.quarantineFolderName`), confrontato senza maiuscole, e un test di parità che lo pretende da ogni lettore.

**Cosa si accetta di perdere:** su Cubbit le chiavi con `+`, apostrofo e simili non si riparano ancora (caricamento e richieste nuove codificano il percorso in modo diverso); un ETag a pezzi non coincidente resta in ❗; la quarantena occupa spazio finché Enrico non la svuota; dopo una riparazione l'inventario va riaggiornato a mano per confermarla.

**Per riaprirla** serve un argomento nuovo: un bucket con versioni (la quarantena su Cubbit diventerebbe superflua), checksum SHA256 lato server, o una prova dal vivo che copra le chiavi con caratteri speciali.

## Risposte di Enrico (S1-S11, D1-D4)

Risposte date il 2026-10-05: S1-S11 approvati come proposti nel piano; D1 (testo della «Regola assoluta») approvato così com'è; D2 registro illeggibile = riparte vuoto; D3 nessun inventario automatico dopo una riparazione; D4 cartella `_quarantena`, anche su Cubbit.
