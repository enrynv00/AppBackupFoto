# Rapporto di revisione tecnica — da "funziona" a "affidabile come Time Machine"

Analisi dello stato attuale di `ContentView.swift` (2026-07-29) incrociata con come lavorano Arq, Carbon Copy Cloner, ChronoSync e Mylio — con l'obiettivo di capire cosa separa questa app da un prodotto da mercato, non solo da un tool personale che funziona.

Versione visiva (con link alle fonti): vedi artifact pubblicato in sessione, oppure questo file.

## Stato aggiornato (2026-08-02)

**Fatti**: #1 Restore guidato, #2 race stop/successo, #3 retry con backoff S3, #9 anteprima dry-run SSD→S3. Dettagli e spec/piani in `Docs/superpowers/specs/` e `Docs/superpowers/plans/`.

**Bonus non previsto in questa lista originale, trovato e risolto durante il lavoro sul Restore**: un bug critico di memoria (`sha256(of:)` faceva salire il processo a 41-43GB di RAM su file da 40-50GB, quasi bloccando il Mac). Vedi `Docs/CLAUDE.md`, sezione ReviewEngine/RestoreEngine, per i dettagli — è probabilmente la scoperta più importante di tutta la sessione, più critica di qualunque punto elencato qui sotto.

**Ancora aperti, con bozze di design pronte in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #5 cifratura lato client, #10 Keychain, #7 scheduling.

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

5. **Nessuna cifratura lato client prima dell'upload.** I file arrivano in chiaro su Cubbit. Arq cifra tutto con AES-256 prima dell'invio (zero-knowledge, chiave solo utente) — per foto private è lo standard a cui puntare.
   *Fonte: ricerca su Arq Backup*

## Alto — prestazioni e qualità percepita (6)

6. ✅ **Fatto (2026-08-02) — Upload S3 completamente sequenziali.** 4 file caricati in parallelo (`S3Syncer.runBounded`, finestra fissa non configurabile). Bonus non previsto: nello stesso intervento corretto anche un probabile bug di memoria in `multipart()` (stesso pattern già trovato in `sha256(of:)`), prima di parallelizzare. Vedi `Docs/superpowers/specs/2026-08-02-parallel-uploads-design.md`.

7. **Zero automazione** — ogni backup parte solo a bottone premuto. CCC, ChronoSync e Arq offrono tutti scheduling nativo ("ogni notte se l'SSD è collegato").
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

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #9 anteprima S3, #10 Keychain. Restano 2 interventi con bozza di ricerca già pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`: **#5 cifratura lato client** (il più delicato — tocca decisioni di sicurezza/UX che richiedono una discussione attenta con l'utente) e **#7 scheduling** (automazione backup, ricerca non ancora approfondita). Il resto della lista (punti 8, 11-20) è ordinabile in base al tempo che si vuole investirci.

## Fonti consultate

- [7 Best Backup Software for macOS: Top Picks for 2026 — MacObserver](https://www.macobserver.com/tips/round-ups/7-best-backup-software-for-macos/)
- [Best Mac Backup Software: Top Solutions Compared — Zmanda](https://www.zmanda.com/blog/best-mac-backup-software-solutions-compared/)
- [Arq Backup Review — Cloudwards](https://www.cloudwards.net/review/arq/)
- [What Is Arq Backup? Complete Review & Guide — ServerSpotter](https://serverspotter.com/blog/what-is-arq-backup)
- [Code Signing and Notarization: Sparkle and Tears — Peter Steinberger](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Sparkle — documentazione ufficiale](https://sparkle-project.org/documentation/)
- [Duplicate & Clutter Cleanup — Mylio](https://mylio.com/duplicate-photo-finder/)
- [Backup and Protect — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/backup-and-protect)
