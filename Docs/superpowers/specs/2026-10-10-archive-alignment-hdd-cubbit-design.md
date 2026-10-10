# Doppioni su HDD e Cubbit: i tre archivi tornano uguali — design

**Stato:** approvato a voce da Enrico il 2026-10-10. Nessuna riga di codice scritta.
**Progetto 4 di 4** (1 inventario ✅ → 2 riparazione ✅ → 3 doppioni sull'SSD ✅ → **4 doppioni su HDD e Cubbit**).
**Base:** `main` a `48f9f6d` (#44, #45, #46 uniti; 1.266 test).
**Numerazione riservata:** ADR-0019, ROADMAP #47.

## Perché

Il progetto 3 ha tolto dall'SSD 89.442 copie doppie (46 blocchi, 2026-10-06/07) e il Cestino dell'SSD è stato svuotato. HDD e Cubbit hanno ancora tutte quelle copie: circa 164 GB in più su ciascuno. Il backup copia solo ciò che manca, quindi non le toglie mai da solo. Lo scopo è che SSD, HDD e Cubbit tornino ad avere gli stessi file, con una copia per foto in ogni archivio.

## Decisioni di Enrico (2026-10-10)

1. **Quali copie:** solo quelle già tolte dall'SSD, cioè le voci della storia degli spostamenti (`trash-history.jsonl`, `TrashHistoryEntry`). Doppioni che esistono solo su HDD o Cubbit sono fuori da questo progetto.
2. **Quale copia resta:** la stessa che l'SSD ha tenuto (`keptPaths`, relativo alla radice). Verificato il 2026-10-10: tutte le 89.442 voci hanno il percorso tenuto, nessuno vuoto.
3. **HDD:** le copie vanno nel **Cestino dell'HDD** (`trashItem`, stesso volume), come per l'SSD. L'app non lo svuota mai.
4. **Cubbit:** le copie si cancellano con DELETE **solo con le versioni accese sul bucket** e la regola che scarta le versioni vecchie dopo **30 giorni**. Per 30 giorni una copia cancellata si recupera identica togliendo il segno di cancellazione.
5. **Quando accendere le versioni sul bucket vero:** subito prima della prima pulizia vera su Cubbit, non prima. Le accende Claude con Enrico, dal terminale; l'app non cambia mai la configurazione del bucket, la legge soltanto.
6. **Prova della regola dei 30 giorni:** il bucket di prova `backupfoto-prova-versioni` resta fino al 2026-11-10 per verificare che la versione vecchia sparisca da sola.

## Verificato su Cubbit (2026-10-10, bucket di prova)

- `PutBucketVersioning` → `Enabled` accettato.
- La regola di scadenza è accettata **solo nel formato vecchio stile**: `{"Rules":[{"ID":"…","Status":"Enabled","Prefix":"","NoncurrentVersionExpiration":{"NoncurrentDays":30}}]}`. Con `Filter:{Prefix:""}` Cubbit risponde `InvalidRequest`.
- DELETE senza versione → HEAD 404, compare un segno di cancellazione, la versione resta in `ListObjectVersions`.
- DELETE del segno di cancellazione (con il suo `versionId`) → l'oggetto torna, scaricato identico (md5 uguale).
- Non verificato: che la scadenza dei 30 giorni scatti davvero (decisione 6).

## Regole

Per ogni voce della storia (copia uscita `P`, copia tenuta `K`, entrambe relative alla radice) e per ciascun archivio A fra HDD e Cubbit, la copia `P` su A si toglie **solo se tutte** queste condizioni valgono; altrimenti resta e il riepilogo dice perché:

1. **Inventario:** l'ultimo giro è completo su SSD, HDD e Cubbit e nessun backup o import ha scritto dopo l'inizio di quel giro (`ArchiveWriteClock`, stessa regola di ADR-0017). Si ricontrolla prima di ogni blocco.
2. **La copia tenuta c'è su A** con lo stesso contenuto di `P` su A, secondo l'inventario di quel giro: su HDD stesso SHA256; su Cubbit stessa certificazione per contenuto dell'inventario (ETag riconosciuto contro lo SHA256/MD5 della foto, ADR-0015). Mai togliere `P` se `K` su A manca, è diversa o non è certificata.
3. **La copia tenuta c'è ancora sull'SSD**, con lo stesso contenuto, nell'inventario di quel giro. Se l'SSD avesse perso anche `K`, non si tocca niente negli altri archivi.
4. **`P` non è tornata sull'SSD.** Se un backup l'avesse ricopiata (il caso delle copie in «Foto iPhone», ADR-0018), toglierla da HDD o Cubbit sarebbe inutile: il backup successivo la ricopierebbe. Si salta.
5. **`P` ≠ `K`**, confrontati come percorsi normalizzati (componenti canoniche su disco; su Cubbit la chiave dopo la stessa normalizzazione dell'inventario, `display_key`/`path`). Se due chiavi Cubbit diverse si normalizzano allo stesso percorso, il gruppo si salta.
6. **Ricontrollo dal vivo subito prima di togliere:**
   - HDD: rilettura e rihash di `P` e di `K` dal disco, esito identico fra loro e uguale all'inventario; `P` dentro la radice dell'HDD per componenti canoniche; poi `trashItem`.
   - Cubbit: HEAD di `P` e di `K`, ETag e dimensione uguali all'inventario; poi DELETE di `P` senza `versionId` (crea il segno di cancellazione, non tocca la versione).
7. **Solo Cubbit:** prima di ogni blocco l'app legge lo stato delle versioni (`GetBucketVersioning`) e la regola di scadenza; se le versioni non sono `Enabled`, il blocco non parte e lo dice. Mai DELETE con `versionId` su una versione di dati: l'unico DELETE con `versionId` ammesso è quello che toglie un **segno di cancellazione** per annullare.

## Come si usa

Nella finestra Inventario (dove già stanno «Ripara…» e lo stato dei tre archivi), una sezione nuova, per HDD e Cubbit separati:

1. **«Controlla senza togliere»** (dry-run, regola assoluta 4): calcola le condizioni 1-5, non tocca niente, mostra quante copie si toglierebbero, quanti GB, e quante restano e perché.
2. **Riepilogo e conferma** distruttiva, come nel pannello Doppioni.
3. **Corsa a blocchi** con barra, «Interrompi» (si ferma alla fine della copia in corso), mutua esclusione con backup, inventario, riparazione e spostamenti dell'SSD in entrambi i versi (`JobStartGate`).
4. **Registro proprio** per ogni copia tolta, scritto prima di passare alla successiva: archivio, percorso, copia tenuta, data; su HDD dove è finita nel Cestino; su Cubbit il `versionId` del segno di cancellazione restituito dal DELETE.
5. **«Annulla l'ultimo blocco»**: su HDD rimette a posto dal Cestino (stessa cura di `TrashRestorer`, mai sovrascrivere); su Cubbit toglie i segni di cancellazione registrati, solo entro i 30 giorni, e verifica con HEAD che l'oggetto sia tornato con lo stesso ETag.

## La regola assoluta cambia

I punti 1 e 3 della «Regola assoluta» in `Docs/CLAUDE.md` diventano falsi e vanno riscritti nello stesso intervento (stessa ragione del 2026-08-28: una regola che diventa falsa e non viene riscritta è un'eccezione silenziosa). Le due porte nuove sono: il Cestino dell'HDD e il DELETE su Cubbit con le versioni accese, entrambe solo per copie la cui copia tenuta è certificata identica nello stesso archivio e presente sull'SSD. La checklist «IF il codice fa chiamate S3» guadagna l'eccezione del DELETE con le sue condizioni. Il backup resta zero-delete e zero-overwrite.

## Cosa non cambia

- Il backup SSD → HDD e SSD → Cubbit: copia solo ciò che manca, non cancella mai.
- L'SSD non viene toccato.
- L'app non svuota mai il Cestino dell'HDD e non cancella mai versioni di dati su Cubbit: lo spazio su Cubbit si libera da solo dopo 30 giorni.
- L'app non cambia mai la configurazione del bucket (versioni, regole).

## Verifica

- Test automatici sulle regole pure: ogni motivo per cui una copia resta (1-5), la normalizzazione delle chiavi e le collisioni, il blocco che non parte con versioni spente, il registro e la sua compatibilità, l'annullamento (HDD e Cubbit) con un client S3 finto, la mutua esclusione.
- Dal vivo, in quest'ordine:
  1. Inventario fresco.
  2. HDD: «Controlla senza togliere», un blocco piccolo, annullato e verificato, poi la corsa.
  3. Cubbit: accensione di versioni e regola sul bucket `backupfoto` (con Enrico), «Controlla senza togliere», un blocco piccolo, annullato con verifica dell'ETag, poi la corsa.
  4. Inventario finale: i tre archivi con gli stessi file foto/video.

## Fuori da questo progetto

- Doppioni presenti solo su HDD o solo su Cubbit (non passati dall'SSD).
- Svuotare il Cestino dell'HDD dall'app.
- Gestire versioni o regole del bucket dall'app.
- I file bloccati (flag `uchg`) come motivo per saltare un gruppo invece di fermare la corsa: utile anche qui sull'HDD, valutarlo nel piano.
