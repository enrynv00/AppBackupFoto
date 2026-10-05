# Doppioni sull'SSD con garanzia — design

**Stato:** approvato a voce da Enrico il 2026-10-05. Nessuna riga di codice scritta.
**Progetto 3 di 4** (2 riparazione ✅ → **3 doppioni sull'SSD con garanzia** → 4 doppioni su HDD e Cubbit).
**Base:** `main` a `3731335` (#44 inventario e #45 riparazione fatti; ❗ = 0, tutte le 141.686 foto e video certificate sui tre archivi il 2026-10-05).
**Numerazione riservata:** ADR-0017, ROADMAP #46.

## Perché

Il pannello Doppioni sposta oggi nel Cestino dell'SSD copie byte-identiche, dopo una rilettura dal vivo (ADR-0005), ma non sa se la foto esiste anche su HDD e Cubbit. Con l'inventario certificato (ADR-0015) lo si sa per contenuto. La garanzia nuova: **sull'SSD si toglie una copia doppia solo se quella foto è al sicuro su tutti e tre gli archivi.** Oggi vale per tutti i circa 142 GB di copie in più sull'SSD.

## Decisioni di Enrico (2026-10-05)

1. **Freschezza:** l'inventario deve essere **completo** e **più recente dell'ultimo backup o import** (qualunque job che scrive sull'SSD, sull'HDD o su Cubbit finito dopo l'inizio dell'ultimo giro d'inventario lo rende vecchio). Gli spostamenti nel Cestino e le riparazioni non lo invecchiano.
2. **Gruppi non certificati:** **visibili ma non spuntabili**, con una riga che dice perché.
3. **Copia tenuta:** stessa regola di oggi (data, regole per cartella); il registro del Cestino annota **quale percorso è stato tenuto** per ogni gruppo, perché il progetto 4 tenga lo stesso percorso su HDD e Cubbit.

## Regole

Un gruppo di doppioni sull'SSD (stesso SHA256, ADR-0001) è **spuntabile** solo se:

- l'ultimo inventario è completo su tutti e tre gli archivi (ADR-0015, incompleto ≠ assente);
- nessun backup/import è finito dopo l'inizio di quel giro;
- il contenuto del gruppo è nella categoria ✅ «Al sicuro» dell'inventario (stesso SHA256);
- la copia tenuta e le copie che escono sono tutte nell'inventario SSD di quel giro con lo stesso SHA256 (un file letto dopo, o cambiato, non è coperto).

Altrimenti il gruppo resta nell'elenco con la casella disattivata e uno dei motivi, in italiano semplice: inventario mai fatto / incompleto / più vecchio dell'ultimo backup («aggiornalo, ci vogliono pochi minuti») / foto non certificata su tutti e tre / file cambiato dopo l'inventario. La selezione in massa e le regole per cartella saltano i gruppi non spuntabili e lo dicono nel conteggio.

Al momento dello spostamento resta **tutto** quello che c'è oggi: riepilogo, conferma, rilettura dal vivo di ogni membro del gruppo (ADR-0005), Cestino dell'SSD, blocchi, «Annulla l'ultimo spostamento». In più, subito prima dello spostamento, il controllo di freschezza si rifà (un backup partito nel frattempo è già escluso dalla mutua esclusione, ma la regola si ricontrolla lo stesso).

## Registro

Ogni voce del registro del Cestino (`TrashManifest`) guadagna il percorso **tenuto** del gruppo (campo nuovo, letto con `decodeIfPresent`: le voci vecchie restano valide). Il progetto 4 lo userà per tenere lo stesso percorso su HDD e Cubbit.

## Cosa non cambia

- HDD e Cubbit non vengono toccati (progetto 4).
- L'app non svuota mai il Cestino: lo spazio si libera quando Enrico lo svuota.
- La regola zero-delete resta com'è: l'unica porta resta il Cestino dell'SSD, ora con una condizione in più.

## Verifica

- Test automatici sulle regole pure (ogni motivo di «non spuntabile», la freschezza rispetto ai job, il conteggio della selezione in massa che salta i gruppi esclusi, il campo nuovo del registro e la compatibilità con le voci vecchie).
- Dal vivo: con l'inventario fresco, un blocco piccolo spostato nel Cestino e annullato; poi un backup e il pannello che chiede di aggiornare l'inventario; poi un blocco vero.

## Fuori da questo progetto

- Cancellare da HDD e Cubbit (progetto 4).
- Svuotare il Cestino dall'app.
- Doppioni fuori dal perimetro foto/video.
