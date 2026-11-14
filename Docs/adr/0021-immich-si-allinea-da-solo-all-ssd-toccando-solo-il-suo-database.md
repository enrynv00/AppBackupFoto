# ADR-0021 — Immich si allinea da solo all'SSD, toccando solo il suo database

**Data:** 2026-11-14
**Stato:** Accettata (2026-11-13), implementata il 2026-11-14, verifica dal vivo da fare

## Contesto

Enrico vuole che la finestra Foto funzioni «stile Google Foto»: foto nuove che compaiono da sole, niente doppioni o foto rotte, niente avvio a mano. Lo stato misurato il 2026-11-13 leggendo il database di Immich 3.2.0 in sola lettura:

- ultima scansione della libreria dell'SSD: 2026-10-11. Immich scansiona solo con il suo cron di mezzanotte, e solo se a quell'ora l'app è aperta;
- 52.139 foto attive in Immich contro 52.590 file censiti sull'SSD: mancano quelle arrivate dopo l'11/10;
- 89.514 foto offline, già nel Cestino di Immich: le copie doppie tolte dall'SSD a ottobre (#46);
- 22.392 foto in gruppi di «simili», con contenuto diverso byte per byte, quindi fuori dal pannello Doppioni dell'app;
- 4.561 immagini con lato lungo sotto i 400 px, soprattutto anteprime recuperate: in griglia sembrano rotte.

Il vincolo è la regola assoluta: l'SSD resta in sola lettura per Immich (bind mount `:ro`, montaggio di Colima senza `:w`). Tutto quello che si fa tocca solo il database di Immich. Spec: `Docs/superpowers/specs/2026-11-13-immich-always-aligned-design.md`. Piano: `Docs/superpowers/plans/2026-11-13-immich-always-aligned.md`. ROADMAP #50.

Il pericolo vero è uno solo: una scansione con il punto di montaggio vuoto segna offline tutte le foto, e toglierle da Immich perderebbe volti, album e pile. Per questo la parte più lunga della decisione è la guardia.

## Opzioni valutate

- **Solo impostazioni dentro Immich.** Scartata: non impila le foto simili e gira solo con il cron di mezzanotte.
- **Scrivere direttamente nel database di Immich.** Scartata: si rompe al primo aggiornamento e salta tutte le regole di Immich.
- **Guidare Immich con la sua API** (scelta).
- **`POST /duplicates/resolve` e `DELETE /duplicates`** per i simili. Scartati per sempre: cancellano. Si impila soltanto (`POST /stacks`).
- **Riferimento del calo preso dal numero prima della scansione.** Scartato: se Immich ha già marcato tutto offline (il cron di mezzanotte con il mount vuoto) il numero vale 0 e la guardia è cieca. Si ricorda il riferimento da un giro riuscito.
- **Conferma come numero nudo.** Scartata: lo stesso numero poteva voler dire due cose diverse (foto mancanti, oppure foto da togliere alla prima rimozione). La conferma è tipata.
- **Aspettare anche la coda dei simili prima di impilare.** Scartato: con 19.076 foto ancora da analizzare terrebbe fermo ogni allineamento. Le pile si fanno con i gruppi che ci sono.

## Decisione e motivo

**L'app guida Immich con la sua API.** Immich parte e si ferma con l'SSD, ma solo se è installato (`ImmichAutoStartCoordinator`). Dopo ogni job riuscito che scrive sull'SSD, dopo lo spostamento dei doppioni, dopo l'avvio di Immich e dopo l'inserimento della chiave, `ImmichAligner` scansiona la libreria, toglie dal database di Immich le foto offline già nel suo Cestino, impila le foto simili e archivia le immagini sotto i 400 px. Le richieste in arrivo durante un giro si uniscono in un solo giro in più. Un errore di Immich non fa mai fallire un backup: l'esito si vede solo nella finestra Foto e nel registro.

**Mai** `/duplicates/resolve` né `DELETE /duplicates`. Il compose fissa le immagini a `v3.2.0` (`ImmichManager.immichVersion`).

**Chiave con permessi chiusi.** Login con email e password, creazione della chiave con 10 permessi (`library.read`, `library.update`, `asset.read`, `asset.update`, `asset.delete`, `duplicate.read`, `stack.create`, `stack.read`, `job.read`, `library.statistics`), logout fuori dalla cancellazione. Esclusi di proposito `library.delete`, `duplicate.delete`, `user.*`, `apiKey.*`, `stack.delete`. Sessione `.ephemeral` separata, `httpShouldHandleCookies = false`. La chiave sta nel Portachiavi (servizio `AppBackupFoto`, account `immich-api-key`); la password non si salva e non si scrive mai nel log. Se la chiave non vale più (401) l'app la cancella e la richiede; quella vecchia va revocata a mano dalle impostazioni di Immich.

**Guardia del calo con riferimento ricordato.** In `immich-alignment.json` stanno `healthyActiveCount` e `referenceConfirmed`.

- Con un riferimento confermato, un calo delle foto attive di più di min(500, 2 %) ferma il giro e non toglie niente. Il riferimento salvato non si abbassa: un «Riprova» con l'SSD ancora vuoto scatta di nuovo.
- Senza un riferimento confermato (primo giro, stato illeggibile messo da parte in `.illeggibile`, candidato mai confermato) non si toglie niente finché Enrico non conferma la prima rimozione, `.firstRemoval(active, toRemove)`. La conferma vale solo se poi `offline ≤ toRemove + soglia` e `after ≥ active − soglia`. Se il calo è grosso il testo mostra anche il numero «prima della scansione».
- La conferma è tipata (`ImmichConfirmation`: `.drop(missing)` oppure `.firstRemoval`) e vale per un solo giro, solo nella situazione per cui è stata chiesta. L'alert congela la conferma e al clic `shouldAccept(frozen:current:)` ricontrolla che lo stato sia ancora quello.

**Prima e durante il delete.** Il delete avviene solo dopo la seconda verifica dell'SSD. Se la scansione arriva al tetto (1.800 s), in quel giro non si toglie niente. Prima di ogni blocco di 500 si ricontrollano tre cose: SSD montato, coda `library` ferma (con `paused` contato) e statistiche contro la guardia. Lo stato deve essere stato salvato prima del primo blocco: se il disco non scrive, `stateNotSaved` ferma il giro.

**Margine dei doppioni spostati dall'app.** Un riferimento si abbassa, solo nel confronto in memoria, di quanti file l'app ha spostato dall'SSD con i Doppioni. Il margine ha un tetto: il 25 % del riferimento. Si restituisce solo se il riferimento non è avanzato (segnale `referenceAdvanced`). Sta in memoria: un riavvio lo azzera, che è il lato sicuro.

**Pile e archiviazione** solo per le foto della libreria SSD (filtro `libraryId` lato client: i gruppi di simili di Immich attraversano le librerie). Lo stato si salva dopo ogni pila e dopo ogni blocco. Un 4xx su una pila si salta; 401 e 403 fermano il giro. Ciò che Enrico disfa non si rifà: l'app ricorda gli ID già archiviati e i gruppi già impilati.

**Cosa si accetta di perdere.**

- Foto nuove nella stessa scansione possono mascherare foto mancanti: 600 mancanti e 200 nuove danno un calo netto di 400, sotto la soglia. Le foto tolte restano nel Cestino di Immich.
- Cali ripetuti sotto la soglia passano: la guardia protegge dal calo improvviso, non dalla lenta erosione.
- `PUT /assets` è segnato «Deprecated» in Immich 3.2.0 ma funziona. Si cambia quando il sostituto sarà stabile.
- Da verificare dal vivo che `GET /duplicates` restituisca `libraryId` per ogni foto (il filtro lato client dipende da questo).

**Per riaprire questa decisione** serve una verifica dal vivo in cui la guardia scatta a torto (giri falliti con un SSD sano) o, peggio, lascia passare un calo che avrebbe dovuto fermare.

## Conseguenze

- La chiave ha `asset.delete`. Mitigazione: l'SSD è montato `:ro` due volte (compose e Colima), quindi anche una chiave abusata può togliere righe dal database di Immich ma non file dall'SSD. Le tolte restano comunque recuperabili finché Immich non le svuota.
- Un calo voluto più grande della soglia si toglie con «Togli comunque…», dopo una conferma che dice quante foto escono da Immich.
- Aggiornare Immich richiede di cambiare `immichVersion` e riverificare gli endpoint.
- Lo stato sta in `~/Library/Application Support/AppBackupFoto/immich-alignment.json` (mai sull'SSD), l'esito in `~/Library/Logs/AppBackupFoto/immich-alignment.log`. Mai la chiave o la password.
- Tipi nuovi, tutti `nonisolated` salvo l'aligner e il coordinatore: `ImmichAlignmentRules`, `ImmichAlignmentRun`, `ImmichRequests`, `ImmichKeyPermissions`, `ImmichKeyMaker`, `ImmichConfirmation`, `ImmichAutoStart`. Nessuna `copyItem`, `moveItem`, `removeItem` o `trashItem` aggiunta sull'SSD: la regola assoluta non cambia.
