# Riparazione di una copia rovinata, con la regola «2 su 3» — design

**Stato:** approvato a voce da Enrico il 2026-10-01. Nessuna riga di codice scritta.
**Progetto 2 di 4** (vedi `2026-09-26-cross-store-inventory-design.md`): 2 riparazione → 3 doppioni sull'SSD con garanzia → 4 doppioni su HDD e Cubbit.
**Base:** `main` a `4e37795` (inventario #44 fatto).
**Numerazione riservata:** ADR-0016, ROADMAP #45 (ADR-0014 e #43 restano al piano `2026-09-26-s3-upload-failures-visible`).

## Perché

Il primo inventario completo ha mostrato che ⚠️ «manca da qualche parte» e 🔎 «solo fuori dall'SSD» sono a zero: non c'è niente da copiare. Ha però trovato una **foto rovinata su Cubbit**: `Foto iPhone/3/370C9D23-60F3-46BA-A534-E5554027365B.heic` (12/02/2023), integra e identica su SSD e HDD, su Cubbit con la stessa dimensione ma gli ultimi 38.796 byte a zero (verificato scaricandola, 2026-10-01). Il backup non se ne accorge perché confronta solo la dimensione.

Ripararla vuol dire **sovrascrivere un file**: la prima eccezione controllata alla regola zero-overwrite. Lo stesso meccanismo («scrivo solo se due copie su tre sono d'accordo, e prima metto da parte quella che sostituisco») servirà ai progetti 3 e 4.

## Decisioni di Enrico (2026-10-01)

1. **La copia rovinata va in quarantena**, mai sovrascritta direttamente: `_quarantena/<AAAA-MM-GG>/<percorso originale>` sullo stesso archivio.
2. **Si ripara anche l'SSD**, con la stessa regola 2 su 3.
3. **Una riparazione alla volta, con conferma**: «Ripara…» su ogni voce riparabile, un riepilogo, poi la conferma.
4. Nessun pulsante per svuotare la quarantena in questa versione: la svuota Enrico dal Finder (o da Cubbit) quando vuole.

## Quando una foto è riparabile

Dall'ultimo inventario, per un **percorso** presente su tutti e tre gli archivi:

- tutti e tre gli archivi sono **completi** nell'ultimo giro (regola «incompleto ≠ assente», ADR-0015);
- **due** archivi hanno lo **stesso contenuto certificato** (stesso SHA256 fra SSD e HDD; su Cubbit l'ETag certifica quel contenuto);
- il **terzo** ha a quel percorso un contenuto **diverso** (SHA256 diverso su un disco, oppure su Cubbit un ETag che non certifica il contenuto degli altri due);
- la dimensione della copia buona è la stessa nei due archivi d'accordo.

In ogni altro caso (tre contenuti diversi, un archivio letto a metà, il percorso che manca da un archivio, oggetto Cubbit non certificabile per formato) la voce resta in ❗ **senza** «Ripara…».

## Cosa succede quando si ripara

In quest'ordine. Il primo passo che fallisce ferma tutto, senza toccare i successivi, e dice cosa è successo.

1. **Ricontrollo dal vivo** (l'inventario è una cache, ADR-0002): rilettura e SHA256 della copia buona sorgente; rilettura (o ETag letto ora da Cubbit con una richiesta HEAD) della seconda copia buona: deve coincidere; la copia rovinata deve essere ancora quella vista dall'inventario (stessa dimensione e stesso SHA256 / ETag). La sorgente è **sempre un file locale**: per riparare Cubbit o l'HDD si usa l'SSD; per riparare l'SSD si usa l'HDD.
2. **Quarantena**:
   - su SSD o HDD: spostamento (`rename`) nello stesso volume in `_quarantena/<data>/<percorso>`, creando le cartelle; mai `removeItem`;
   - su Cubbit: copia lato server (`CopyObject`) in `_quarantena/<data>/<chiave>`, poi HEAD della copia: stessa dimensione e stesso ETag della rovinata. **Prima di implementare**, `CopyObject` va provato una volta su Cubbit; se non funziona, il piano ripiega su scaricare la copia rovinata e ricaricarla in quarantena con le funzioni già collaudate.
3. **Scrittura** della copia buona al percorso originale: su un disco con le funzioni di copia esistenti (lettura POSIX, verifica dell'hash); su Cubbit con `S3Syncer.upload` esistente.
4. **Verifica finale**: rilettura e SHA256 (disco) o HEAD con ETag uguale a quello atteso dalla sorgente (Cubbit). Se non coincide: avviso esplicito, la copia rovinata resta in quarantena, nessun altro tentativo automatico.
5. **Registro** sul Mac (`Application Support/AppBackupFoto/repair-log.json`, stesso schema di `TrashManifest`): percorso, archivio riparato, sorgente usata, impronte prima/dopo, posizione della quarantena, data, esito.

Dopo una riparazione riuscita la voce resta nell'inventario fino al giro successivo, con la scritta «riparata il …, aggiorna l'inventario per confermarlo».

## Le cartelle di quarantena non devono rientrare da nessuna parte

`_quarantena` va **esclusa** (come `.Trashes`) da: backup SSD → HDD, backup SSD → Cubbit, elenco delle foto (`LibraryIndexer`), inventario (scanner e lettore Cubbit), Doppioni, ripristino. Altrimenti il backup ricaricherebbe su Cubbit la copia rovinata, o i Doppioni la vedrebbero come una copia. Un test di parità deve pretendere che tutti questi percorsi usino la stessa esclusione.

## Convivenza

La riparazione scrive su un archivio: non parte durante un backup, una lettura dell'elenco, un inventario, uno spostamento nel Cestino o un annullamento, e viceversa (stesso schema di `isInventorying`, cancelli senza default). Richiede SSD e HDD collegati e Cubbit raggiungibile.

## Verifica

- Test automatici sulle regole pure: quando una voce è riparabile (ogni caso sopra), quale archivio è la minoranza, quale sorgente si usa, i percorsi di quarantena (data, caratteri speciali come `+` e apostrofo, nessuna uscita dalla cartella con `..`), l'esclusione di `_quarantena` ovunque.
- Test su cartelle temporanee per la riparazione su disco (spostamento in quarantena, copia, verifica, fallimento a ogni passo che lascia tutto com'era).
- Su Cubbit niente test automatici con la rete; la prova vera è la `.heic`: dopo la riparazione l'ETag su Cubbit deve essere l'MD5 della copia sull'SSD (`b59917c9c6e38fccab5ce3f30c90d13a`) e la copia rovinata deve stare in `_quarantena/…`.
- Dopo la riparazione, un nuovo inventario deve dare ❗ = 0.

## Fuori da questo progetto

- Svuotare la quarantena dall'app.
- Riparare quando non c'è una maggioranza 2 su 3.
- Riparazioni in blocco.
- Cancellare doppioni (progetti 3 e 4).
