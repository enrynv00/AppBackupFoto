# Rapporto di revisione tecnica — da "funziona" a "affidabile come Time Machine"

Analisi dello stato attuale di `ContentView.swift` (2026-07-29) incrociata con come lavorano Arq, Carbon Copy Cloner, ChronoSync e Mylio — con l'obiettivo di capire cosa separa questa app da un prodotto da mercato, non solo da un tool personale che funziona.

Versione visiva (con link alle fonti): vedi artifact pubblicato in sessione, oppure questo file.

---

## Cosa già fate meglio della media

- **FileManager nativo invece di rsync/rclone in subprocess** — evita il muro TCC sui volumi esterni che affligge molti tool concorrenti su macOS Sequoia+.
- **Verifica SHA256 post-copia reale** — molti backup consumer non ricontrollano l'hash dopo la copia; qui è già in produzione.
- **Zero-delete/zero-overwrite come regola assoluta**, applicata anche al pannello di Revisione — non un'eccezione per una feature, una disciplina.
- **Pannello di diagnostica con campione di integrità S3** — la maggior parte dei tool "set and forget" non offre nulla di simile all'utente finale.

---

## Critico — rischio dati o affidabilità reale (5)

1. **Nessun percorso di restore.** L'app sa solo copiare in avanti (Mac→SSD→HDD→S3). Se il Mac si guasta, il recupero da SSD/HDD/S3 richiede sapere già cosa si sta facendo — non c'è una schermata "Ripristina" guidata. È la funzione singola più importante che manca a un'app di backup.
   *Effort: alto · componente nuovo (RestoreView + logica inversa in FileSyncer)*

2. **Interrompere un job può mostrare "Completato" per errore.** `BackupRunner.stop()` imposta subito `.failed("Interrotto")`, ma il `Task` in background può terminare poco dopo e sovrascrivere silenziosamente lo stato con `.success` e statistiche parziali — il ramo di successo in `run(label:work:)` non controlla `wasStopped` come fa invece il ramo d'errore.
   *Trovato leggendo ContentView.swift:1100-1121 in sessione — confermato dal codice, non ancora riprodotto in app.*

3. **Nessun retry sui fallimenti di rete verso S3.** Un errore di rete su un file lo marca "errore" e il job prosegue — corretto per non bloccarsi, ma senza retry con backoff ogni blip di WiFi diventa un file permanentemente non backuppato finché non rilanci l'intero job.
   *Effort: medio · retry loop in `S3Syncer.upload`/`multipart`*

4. **Multipart upload interrotti restano orfani sul bucket.** `AbortMultipartUpload` viene chiamato solo su Interrompi esplicito. Se l'app va in crash o il Mac si spegne a metà upload multipart, le parti restano su Cubbit — spazio occupato e potenziale costo indefinito a seconda delle lifecycle rule del bucket.
   *Effort: medio · `ListMultipartUploads` + cleanup a inizio job, o verifica lifecycle rule lato Cubbit*

5. **Nessuna cifratura lato client prima dell'upload.** I file arrivano in chiaro su Cubbit. Arq cifra tutto con AES-256 prima dell'invio (zero-knowledge, chiave solo utente) — per foto private è lo standard a cui puntare.
   *Fonte: ricerca su Arq Backup*

## Alto — prestazioni e qualità percepita (6)

6. **Upload S3 completamente sequenziali** — un file alla volta, e anche le parti multipart una alla volta, nessun parallelismo in `S3Syncer.sync`. Su ~69.000 file è probabilmente il collo di bottiglia più grande sulla velocità reale.
   *Effort: medio · `TaskGroup` con 4-8 upload/parti concorrenti, limite configurabile*

7. **Zero automazione** — ogni backup parte solo a bottone premuto. CCC, ChronoSync e Arq offrono tutti scheduling nativo ("ogni notte se l'SSD è collegato").
   *Fonte: confronto funzionalità CCC / ChronoSync / Arq*

8. **Nessun controllo di spazio libero prima di partire** — se HDD si riempie a metà copia, l'errore arriva a job già a metà.
   *Effort: basso · `resourceValues(.volumeAvailableCapacityKey)` prima di `run()`*

9. **Anteprima dry-run assente per SSD → S3** — presente per Mac→SSD e SSD→HDD, manca proprio dove il job è più lungo e costoso.
   *Effort: basso · `previewSyncS3()` sul modello di `previewSSDToHDD()`*

10. **Credenziali S3 in un file di testo, non nel Keychain** — `~/.config/rclone/rclone.conf` funziona ed è protetto da permessi POSIX 0600, ma il Keychain è pensato esattamente per questo.
    *Effort: medio · migrazione a Security framework, fallback di lettura da rclone.conf per compatibilità*

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

## Da dove partire

**Il restore (1)**, perché è l'unica cosa che rende questa un'app di backup e non solo un sincronizzatore. **La race stop/successo (2)**, perché è un bug di correttezza reale già confermato nel codice, non un'ipotesi. Il resto è ordinabile in base al tempo che vuoi investirci.

## Fonti consultate

- [7 Best Backup Software for macOS: Top Picks for 2026 — MacObserver](https://www.macobserver.com/tips/round-ups/7-best-backup-software-for-macos/)
- [Best Mac Backup Software: Top Solutions Compared — Zmanda](https://www.zmanda.com/blog/best-mac-backup-software-solutions-compared/)
- [Arq Backup Review — Cloudwards](https://www.cloudwards.net/review/arq/)
- [What Is Arq Backup? Complete Review & Guide — ServerSpotter](https://serverspotter.com/blog/what-is-arq-backup)
- [Code Signing and Notarization: Sparkle and Tears — Peter Steinberger](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Sparkle — documentazione ufficiale](https://sparkle-project.org/documentation/)
- [Duplicate & Clutter Cleanup — Mylio](https://mylio.com/duplicate-photo-finder/)
- [Backup and Protect — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/backup-and-protect)
