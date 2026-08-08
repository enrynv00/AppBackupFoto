# Rapporto di revisione tecnica — da "funziona" a "affidabile come Time Machine"

Analisi dello stato attuale di `ContentView.swift` (2026-07-29) incrociata con come lavorano Arq, Carbon Copy Cloner, ChronoSync e Mylio — con l'obiettivo di capire cosa separa questa app da un prodotto da mercato, non solo da un tool personale che funziona.

Versione visiva (con link alle fonti): vedi artifact pubblicato in sessione, oppure questo file.

## Stato aggiornato (2026-08-02)

**Fatti**: #1 Restore guidato, #2 race stop/successo, #3 retry con backoff S3, #4 cleanup multipart orfani, #6 upload paralleli, #9 anteprima dry-run SSD→S3, #10 migrazione credenziali al Keychain. Dettagli e spec/piani in `Docs/superpowers/specs/` e `Docs/superpowers/plans/`.

**Bonus non previsto in questa lista originale, trovato e risolto durante il lavoro sul Restore**: un bug critico di memoria (`sha256(of:)` faceva salire il processo a 41-43GB di RAM su file da 40-50GB, quasi bloccando il Mac). Vedi `Docs/CLAUDE.md`, sezione ReviewEngine/RestoreEngine, per i dettagli — è probabilmente la scoperta più importante di tutta la sessione, più critica di qualunque punto elencato qui sotto.

**#5 (cifratura lato client) valutato e deciso esplicitamente contro, per ora** (2026-08-02): rischio di perdita permanente dei dati (password/chiave persa = foto perse per sempre, nessun recupero) giudicato non accettabile rispetto al beneficio, in tensione diretta con la regola "zero delete, zero overwrite" del progetto. Nessuna implementazione, nessuna spec di design — solo la domanda di go/no-go, con risposta "no". Vedi sotto per i dettagli del trade-off presentato.

**Ancora aperto, con bozza di ricerca pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #7 scheduling (nota: già parzialmente fatto per Mac→SSD, vedi sotto).

**Fatto (2026-08-08)**: alert deep mirror stantio (obiettivo futuro #1 di `Docs/CLAUDE.md`) — nuovo finding in Revisione se il deep mirror SSD→HDD non gira da più di 45 giorni. Vedi `Docs/superpowers/specs/2026-08-08-deep-mirror-staleness-design.md`.

---

## Cosa già fate meglio della media

- **FileManager nativo invece di rsync/rclone in subprocess** — evita il muro TCC sui volumi esterni che affligge molti tool concorrenti su macOS Sequoia+.
- **Verifica SHA256 post-copia reale** — molti backup consumer non ricontrollano l'hash dopo la copia; qui è già in produzione.
- **Zero-delete/zero-overwrite come regola assoluta**, applicata anche al pannello di Revisione — non un'eccezione per una feature, una disciplina.
- **Pannello di diagnostica con campione di integrità S3** — la maggior parte dei tool "set and forget" non offre nulla di simile all'utente finale.

---

## Critico — rischio dati o affidabilità reale (5)

1. ✅ **Fatto (2026-07-29/30) — Nessun percorso di restore.** Ripristino guidato in 4 passi da SSD/HDD/Cubbit, con indicatori di disponibilità in tempo reale e UI volutamente semplice. Vedi `Docs/superpowers/specs/2026-07-29-restore-feature-design.md`.

2. ✅ **Fatto (2026-08-02) — Interrompere un job poteva mostrare "Completato" per errore.** Fix isolato in `BackupRunner.run()`: il ramo di successo ora controlla `wasStopped` come già faceva il ramo d'errore.

3. ✅ **Fatto (2026-08-02) — Nessun retry sui fallimenti di rete verso S3.** Fino a 3 tentativi con backoff (1s/2s) su PUT e singola parte multipart, salta i 4xx. Vedi `Docs/superpowers/specs/2026-08-02-s3-upload-retry-design.md`.

4. ✅ **Fatto (2026-08-02) — Multipart upload interrotti restavano orfani sul bucket.** Scoperta automatica + pulizia manuale nel pannello Revisione (Tools), disattivata mentre un job è in corso. Vedi `Docs/superpowers/specs/2026-08-02-multipart-cleanup-design.md`.

5. 🚫 **Valutato e deciso esplicitamente contro, per ora (2026-08-02) — Nessuna cifratura lato client prima dell'upload.** I file arrivano in chiaro su Cubbit. Arq cifra tutto con AES-256 prima dell'invio (zero-knowledge, chiave solo utente) — per foto private sarebbe lo standard a cui puntare, ma il rischio non è stato ritenuto accettabile: se la password/chiave va persa, le foto cifrate diventano illeggibili per sempre, senza alcun recupero possibile — l'unico scenario in questo progetto dove i dati potrebbero andare persi in modo permanente, in tensione diretta con "zero delete, zero overwrite". Cifrare romperebbe anche la compatibilità con i 120.842 oggetti già su Cubbit (bucket misto o migrazione completa da giorni di banda) e toglierebbe la possibilità di ispezionare il bucket con un tool esterno in caso di bug dell'app. Decisione presa dopo aver presentato esplicitamente il trade-off all'utente — non un oversight, non riproporre senza un motivo nuovo.
   *Fonte: ricerca su Arq Backup*

## Alto — prestazioni e qualità percepita (6)

6. ✅ **Fatto (2026-08-02) — Upload S3 completamente sequenziali.** 4 file caricati in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Bonus non previsto: nello stesso intervento corretto anche un probabile bug di memoria in `multipart()` (stesso pattern già trovato in `sha256(of:)`), prima di parallelizzare. Vedi `Docs/superpowers/specs/2026-08-02-parallel-uploads-design.md`.

7. ✅ **Fatto (2026-08-02) — Zero automazione.** Backup Mac→SSD automatico al collegamento dell'SSD, solo ad app aperta (toggle on/off in Impostazioni). Scope ridotto rispetto all'idea originale dopo discussione con l'utente: niente LaunchAgent/avvio ad app chiusa (dipende dalla modalità menu bar, punto #11, non fatta), niente orario fisso, solo Mac→SSD (non SSD→HDD/S3). Vedi `Docs/superpowers/specs/2026-08-02-ssd-connect-auto-backup-design.md`.
   *Fonte: confronto funzionalità CCC / ChronoSync / Arq*

8. **Nessun controllo di spazio libero prima di partire** — se HDD si riempie a metà copia, l'errore arriva a job già a metà.
   *Effort: basso · `resourceValues(.volumeAvailableCapacityKey)` prima di `run()`*

9. ✅ **Fatto (2026-08-02) — Anteprima dry-run assente per SSD → S3.** `S3Syncer.previewUpload` + `previewSyncS3()`, stesso stile delle anteprime già esistenti per Mac→SSD e SSD→HDD.

10. ✅ **Fatto (2026-08-02) — Credenziali S3 in un file di testo, non nel Keychain.** `readConfig()` prova prima il Keychain, fallback a rclone.conf con adozione silenziosa; bottone esplicito "Aggiorna da rclone.conf" in Tools per chi continua a modificare il file a mano. Vedi `Docs/superpowers/specs/2026-08-02-keychain-migration-design.md`.

11. **Nessuna modalità menu bar / avvio in background** — l'app deve restare aperta con finestra visibile.
    *Effort: alto · `NSStatusItem` + `LSUIElement`, ristruttura RootView*

## Valore aggiunto — da "buona" a "da mercato" (9)

12. **Nessun catalogo/ricerca di cosa è già backuppato** — oggi serve Tools o rclone a mano; un browser dei backup (data/cartella/nome) alzerebbe la fiducia senza toccare la logica di sync.
13. **Nessun versioning dei file modificati** — zero-overwrite skippa un file già presente anche se il contenuto locale è cambiato; nessuno storico se un file viene silenziosamente corrotto prima del backup.
14. **Stringhe italiane hardcoded, nessuna localizzazione** — `STRING_CATALOG_GENERATE_SYMBOLS = YES` già nelle build settings, ma le stringhe non sono estratte in un String Catalog.
15. **Nessun indicatore di progresso in dock/menu bar** — nessun modo di vedere la percentuale senza portare la finestra in primo piano.
16. **Notifiche non azionabili** — un bottone "Riprova" direttamente nella notifica di errore risparmierebbe il giro app→hamburger→rilancio.
17. **Nessuna miniatura dell'ultimo file backuppato** — tocco di fiducia visiva usato da Mylio/PhotoSync.
    *Fonte: ricerca su pattern UX di Mylio Photos*
18. **Nessun auto-update** — ogni build richiede Archive→Distribute→Copy a mano. Sparkle è lo standard open-source, con verifica EdDSA integrata.
    *Fonte: ricerca su Sparkle, documentazione ufficiale e best practice code signing 2026*
19. **Firma "ad-hoc", nessuna notarization** — necessario solo se l'app esce dal Mac attuale. Richiede Developer ID Application ($99/anno) e Hardened Runtime.
    *Fonte: ricerca su requisiti Developer ID/notarization macOS 2026*
20. **Il pannello Revisione resta solo su richiesta** — scelta esplicita in fase di design; renderlo periodico con badge discreto lo trasformerebbe da strumento diagnostico a guardiano silenzioso.

---

## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #7 scheduling (Mac→SSD su collegamento SSD), #9 anteprima S3, #10 Keychain. #5 (cifratura lato client) valutato e deciso esplicitamente contro, per ora — non riproporre senza un motivo nuovo, vedi sopra. Nessun punto critico/alto resta aperto nella lista originale: quello che rimane sono i punti "valore aggiunto" (8, 11-20), ordinabili in base al tempo che si vuole investirci — punto #11 (modalità menu bar/background) è il prerequisito naturale se in futuro si vorrà estendere lo scheduling anche ad app chiusa.

## Priorità per la prossima sessione (2026-08-08, fine giornata)

1. **BUG-2 prima di tutto** (`Docs/CLAUDE.md` → Bug aperti): aprire Diagnostica può bloccare l'app e farla uccidere da macOS durante il prompt Keychain — root cause investigata e documentata con log di sistema reali, ma il fix non è ancora scelto né implementato. Bloccante per usare la finestra Diagnostica appena shippata, quindi va prima di qualunque altro punto della lista sotto.
2. **#19 (notarization/Developer ID) sale di priorità**, non per "qualità percepita da mercato" come nella valutazione originale ma perché la firma ad-hoc instabile è la causa diretta di metà di BUG-2 (re-prompt Keychain a ogni rebuild) — vale la pena deciderlo insieme al fix di BUG-2 invece che come voce isolata "valore aggiunto". Richiede Developer ID Application ($99/anno), da confermare con l'utente prima di procedere (costo ricorrente).
3. Il resto dei punti "valore aggiunto" (8, 11-18, 20) resta nell'ordine libero già indicato sopra, nessuna urgenza nuova rispetto al 2026-08-02.

## Fonti consultate

- [7 Best Backup Software for macOS: Top Picks for 2026 — MacObserver](https://www.macobserver.com/tips/round-ups/7-best-backup-software-for-macos/)
- [Best Mac Backup Software: Top Solutions Compared — Zmanda](https://www.zmanda.com/blog/best-mac-backup-software-solutions-compared/)
- [Arq Backup Review — Cloudwards](https://www.cloudwards.net/review/arq/)
- [What Is Arq Backup? Complete Review & Guide — ServerSpotter](https://serverspotter.com/blog/what-is-arq-backup)
- [Code Signing and Notarization: Sparkle and Tears — Peter Steinberger](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Sparkle — documentazione ufficiale](https://sparkle-project.org/documentation/)
- [Duplicate & Clutter Cleanup — Mylio](https://mylio.com/duplicate-photo-finder/)
- [Backup and Protect — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/backup-and-protect)
