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

8. ✅ **Fatto (2026-08-09) — Nessun controllo di spazio libero prima di partire.** `runMacToSSD()`/`runSSDToHDD()` ora controllano lo spazio libero sul volume di destinazione prima di avviare (margine 5%/min 500MB), bloccando con un alert se insufficiente. SSD→S3 escluso (nessun limite pratico su Cubbit). Vedi `Docs/superpowers/specs/2026-08-09-free-space-check-design.md`.

9. ✅ **Fatto (2026-08-02) — Anteprima dry-run assente per SSD → S3.** `S3Syncer.previewUpload` + `previewSyncS3()`, stesso stile delle anteprime già esistenti per Mac→SSD e SSD→HDD.

10. ✅ **Fatto (2026-08-02) — Credenziali S3 in un file di testo, non nel Keychain.** `readConfig()` prova prima il Keychain, fallback a rclone.conf con adozione silenziosa; bottone esplicito "Aggiorna da rclone.conf" in Tools per chi continua a modificare il file a mano. Vedi `Docs/superpowers/specs/2026-08-02-keychain-migration-design.md`.

11. ✅ **Fatto in parte (2026-08-09) — Nessuna modalità menu bar.** Aggiunta icona menu bar come scorciatoia (stato + apertura finestra, `MenuBarExtra`) — scope ridotto rispetto alla stima originale dopo brainstorming con l'utente: l'obiettivo era solo un accesso rapido, non trasformare l'app in un'utility "menu bar only". `LSUIElement`/avvio in background/scheduling automatico ad app chiusa restano fuori scope, non richiesti. Vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`.

## Valore aggiunto — da "buona" a "da mercato" (9)

12. ✅ **Fatto (2026-08-09) — Nessun catalogo/ricerca di cosa è già backuppato.** Nuova finestra "Catalogo" (SSD/HDD/Cubbit S3), ricerca per nome/cartella, scansione dal vivo a ogni apertura, sola lettura. Vedi `Docs/superpowers/specs/2026-08-09-backup-catalog-design.md`.
13. ✅ **Fatto (2026-08-09) — Nessun versioning dei file modificati.** Deciso esplicitamente contro il "versioning vero" (nessun salvataggio automatico di nuove versioni accanto alle esistenti — troppo rischio/complessità per il beneficio). Fatto invece: segnalazione, non azione — `CompletionSheet` mostra un conteggio se dei file locali risultano cambiati rispetto alla copia già presente e sono stati skippati per zero-overwrite, per tutti e tre i job. Durante il brainstorming trovato e risolto separatamente **BUG-3** (`Docs/CLAUDE.md` → Bug aperti): `S3Syncer` sovrascriveva silenziosamente su Cubbit i file cambiati, invece di skippare come già faceva `FileSyncer`. Vedi `Docs/superpowers/specs/2026-08-09-changed-file-reporting-design.md` e `Docs/superpowers/specs/2026-08-09-s3-zero-overwrite-fix-design.md`.
14. ✅ **Fatto (2026-08-09) — Stringhe italiane hardcoded, nessuna localizzazione.** Aggiunto `AppBackupFoto/Localizable.xcstrings` (String Catalog, `sourceLanguage: "it"`), popolato automaticamente dal compilatore (`SWIFT_EMIT_LOC_STRINGS`, già attivo sul target) con le stringhe usate in `Text`/`Button`/`Label` di `ContentView.swift`, incluse quelle con interpolazione. Solo pulizia/preparazione, deciso esplicitamente contro una vera localizzazione multi-lingua (l'app resta solo in italiano, nessun utente non italofono) — go/no-go come per #5. `developmentRegion`/`knownRegions` corretti da `en` a `it` (incoerenza preesistente, mai allineata). Alert/dialoghi/menu costruiti come `String` semplice restano fuori scope. Vedi `Docs/superpowers/specs/2026-08-09-string-catalog-design.md`.
15. ✅ **Fatto (2026-08-09) — Nessun indicatore di progresso in dock/menu bar.** Badge percentuale sull'icona Dock (`NSApp.dockTile.badgeLabel`) durante un job, aggiornato da `runner.stats.percent` già esistente, sparisce subito a fine job. Solo Dock, non menu bar (deciso in brainstorming per tenere l'intervento piccolo). Vedi `Docs/superpowers/specs/2026-08-09-dock-badge-design.md`.
16. ✅ **Fatto in parte (2026-08-09) — Notifiche non azionabili.** Scoperto durante il brainstorming che non esisteva nessuna notifica di errore (solo di successo) — aggiunta quella, senza bottone "Riprova": deciso esplicitamente contro, complessità (categoria + delegate + routing per job) sproporzionata per un'app single-user usata quasi sempre con la finestra a portata di mano. Vedi `Docs/superpowers/specs/2026-08-09-error-notification-design.md`.
17. ✅ **Fatto (2026-08-09) — Nessuna miniatura dell'ultimo file backuppato.** Miniatura live in `StatsPanel` durante un job (foto vera via ImageIO per le immagini, icona di sistema per il resto, es. gli zip nella cartella "Zip") — solo live, non nel riepilogo finale. Vedi `Docs/superpowers/specs/2026-08-09-current-file-thumbnail-design.md`.
    *Fonte: ricerca su pattern UX di Mylio Photos*
18. ✅ **Fatto e verificato end-to-end (2026-08-10/11) — Nessun auto-update.** `SPUStandardUpdaterController` (Sparkle 2.x via SPM), check automatico in background + voce manuale, installazione sempre dietro click esplicito. `Script/release.sh` automatizza build→firma EdDSA→GitHub Release→appcast.xml. Repo pubblico `enrynv00/AppBackupFoto` creato e collegato. **BUG-4** (`Docs/CLAUDE.md`): il primo test reale (v1.1.0) crashava al riavvio post-update per Hardened Runtime + firma ad-hoc — fix (`ENABLE_HARDENED_RUNTIME = NO`) verificato pubblicando v1.1.1 e osservando un self-update reale andato a buon fine. Vedi `Docs/superpowers/specs/2026-08-10-sparkle-auto-update-design.md`.
    *Fonte: ricerca su Sparkle, documentazione ufficiale e best practice code signing 2026*
19. 🚫 **Valutato e deciso esplicitamente contro (2026-08-11) — Firma "ad-hoc", nessuna notarization.** Richiederebbe Developer ID Application ($99/anno) e Hardened Runtime. L'utente ha risposto "fuori questione" al costo ricorrente — decisione presa dopo aver toccato con mano il costo reale del non farlo (BUG-4: `ENABLE_HARDENED_RUNTIME` disattivato per far funzionare #18 senza notarization). Stesso tipo di decisione ponderata già presa per #5 (cifratura) — non riproporre senza un motivo nuovo e concreto.
    *Fonte: ricerca su requisiti Developer ID/notarization macOS 2026*
20. ✅ **Fatto (2026-08-11) — Il pannello Revisione era solo su richiesta.** Ora i controlli economici (`runConfigChecks`, che include `checkDeepMirrorFreshness`) girano una volta all'avvio; un pallino discreto sulla voce "Tools" del menu hamburger segnala se trovano qualcosa. Campione di integrità e upload orfani restano manuali (troppo costosi per un check automatico). Vedi `Docs/superpowers/specs/2026-08-11-review-launch-badge-design.md`.

---

## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #7 scheduling (Mac→SSD su collegamento SSD), #8 controllo spazio, #9 anteprima S3, #10 Keychain, #11 icona menu bar (scorciatoia), #12 catalogo backup, #13 segnalazione file cambiati, #14 String Catalog, #15 badge Dock, #16 notifica errore, #17 miniatura live, #18 auto-update (Sparkle, verificato end-to-end), #20 badge di Revisione all'avvio. #5 (cifratura lato client) e #19 (notarization/Developer ID) valutati e decisi esplicitamente contro — non riproporre senza un motivo nuovo, vedi sopra. Roadmap completa: nessun punto critico/alto/valore-aggiunto resta aperto nella lista originale. #11 è stato scoperto avere obiettivo reale "solo scorciatoia" (non modalità background) — se in futuro si vorrà davvero estendere lo scheduling anche ad app chiusa, quella è una decisione nuova da riaprire, non coperta da #11 così com'è stato fatto.

## Stato aggiornato (2026-08-09)

**BUG-2 risolto** (`Docs/CLAUDE.md` → Bug aperti, commit `0747b26`): la finestra Diagnostica e Ripristina condividono ora un'unica lettura Keychain per avvio app (`BackupRunner.loadS3ConfigIfNeeded()`), verificato con log di sistema reali — nessun blocco, nessun loop di prompt.

**#19 (notarization/Developer ID) valutato e deciso esplicitamente contro (2026-08-11)**: la firma ad-hoc instabile resta la ragione di fondo sia di BUG-2 (Keychain che richiede due volte dopo un rebuild) sia di BUG-4 (Hardened Runtime che rompeva l'auto-update di Sparkle) — ma l'utente ha rifiutato il costo ricorrente ($99/anno) senza ambiguità. Mitigazione applicata per BUG-4: `ENABLE_HARDENED_RUNTIME = NO` (nessuna protezione reale persa, dato che serviva solo da prerequisito alla notarization che non si farà). BUG-2 resta latente (si ripresenta solo se la voce Keychain corrotta viene ricreata dopo un rebuild — fix noto, vedi `Docs/CLAUDE.md`), non bloccante per l'uso quotidiano.

**#18 (auto-update) fatto e verificato end-to-end (2026-08-10/11)**: Sparkle 2.x integrato e testato con due release reali pubblicate (v1.1.0, che ha rivelato BUG-4; v1.1.1, che ne ha confermato il fix), vedi punto 18 sopra e `Docs/CLAUDE.md`.

**#20 (badge di Revisione all'avvio) fatto (2026-08-11)**: i controlli economici di `ReviewEngine` girano una volta all'avvio, con un pallino discreto sulla voce "Tools" del menu hamburger se trovano qualcosa — vedi punto 20 sopra. Roadmap completa: nessun punto resta aperto.

---

## Design polish — da "funziona" a "cutting edge" (2026-08-12)

Nuovo capitolo aperto dopo la chiusura della roadmap tecnica originale (punti 1-20 sopra). Motivazione: l'app è funzionalmente solida ma visivamente "ok, non polished" — audit UI completo (Architect agent) e ricerca su best practice macOS 2025-2026 (Researcher agent) in `Docs/superpowers/specs/` (spec da aggiungere per ciascuna fase). Target macOS alzato a 26 (Tahoe) — Enrico lo usa già, quindi Liquid Glass è disponibile senza vincoli di compatibilità.

**Audit sintetico**: nessuna palette (13 blu, 13 rossi, 12 verdi hardcoded senza semantica), 14 `NSAlert` AppKit mescolati a 2 `.alert` SwiftUI, zero `onHover` su elementi cliccabili custom, zero materials/vibrancy, `HSplitView` invece di `NavigationSplitView`, card copiaincollata 9 volte con 3 opacità/4 corner radius diversi, 16 dimensioni di font numeriche sovrapposte a stili semantici, nessuna griglia di spacing coerente.

Lavoro diviso in 5 fasi indipendenti, ciascuna con il proprio ciclo spec → piano → implementazione (non una mega-spec unica, per restare verificabile e revertibile fase per fase):

21. ✅ **Fatto (2026-08-12) — Fase 1, fondamenta design.** 4 enum di design token (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`) in `ContentView.swift`, migrazione completa di colori/tipografia/spacing/padding/corner-radius del pattern "card" verso i token. Vedi `Docs/superpowers/specs/2026-08-12-design-foundations-design.md` e `Docs/superpowers/plans/2026-08-12-design-foundations.md`.
22. ✅ **Fatto (2026-08-12) — Fase 2, struttura e Liquid Glass.** `HSplitView` → `NavigationSplitView` per la sidebar permanente (pannello hamburger invariato), materiale Liquid Glass su sidebar e barra superiore, più il fix di un bug di dimensione finestra trovato durante la verifica manuale di Fase 1 (mancava `.frame(maxHeight: .infinity)` sulle due colonne). Vedi `Docs/superpowers/specs/2026-08-12-structure-liquid-glass-design.md` e `Docs/superpowers/plans/2026-08-12-structure-liquid-glass.md`.
23. ✅ **Fatto (2026-08-12) — Fase 3, unificazione componenti.** `.cardBackground()` consolida le 9 occorrenze del pattern card; `StatCard`/`CStat` uniti in `StatTile` (parametro `compact: Bool`); i 4 `GroupBox` di `ToolsSheet` allineati al resto dell'app con `CardGroupBoxStyle`. Nessun cambio alla resa visiva, solo consolidamento. Vedi `Docs/superpowers/specs/2026-08-12-component-unification-design.md` e `Docs/superpowers/plans/2026-08-12-component-unification.md`.
24. ✅ **Fatto (2026-08-12) — Fase 4, micro-interazioni.** Hover su righe cliccabili (`HamburgerRow`, `OpsButton`, wizard Ripristina), `contentTransition(.numericText())` sui contatori, `contentTransition(.symbolEffect(.replace))` sull'icona di stato. Skeleton/`.redacted` deliberatamente escluso — nessun caso reale nel codice attuale abbastanza rilevante. Vedi `Docs/superpowers/specs/2026-08-12-micro-interactions-design.md` e `Docs/superpowers/plans/2026-08-12-micro-interactions.md`.
25. ✅ **Fatto (2026-08-12) — Fase 5, migrazione dialoghi.** I 14 `NSAlert` AppKit sostituiti da `.alert` SwiftUI (tipo condiviso `SimpleAlert`, stato pubblicato dove necessario). Chiude il piano di restyling in 5 fasi — nessun punto rimasto aperto nei punti 21-25. Vedi `Docs/superpowers/specs/2026-08-12-dialog-migration-design.md` e `Docs/superpowers/plans/2026-08-12-dialog-migration.md`.

---

## Fonti consultate

- [7 Best Backup Software for macOS: Top Picks for 2026 — MacObserver](https://www.macobserver.com/tips/round-ups/7-best-backup-software-for-macos/)
- [Best Mac Backup Software: Top Solutions Compared — Zmanda](https://www.zmanda.com/blog/best-mac-backup-software-solutions-compared/)
- [Arq Backup Review — Cloudwards](https://www.cloudwards.net/review/arq/)
- [What Is Arq Backup? Complete Review & Guide — ServerSpotter](https://serverspotter.com/blog/what-is-arq-backup)
- [Code Signing and Notarization: Sparkle and Tears — Peter Steinberger](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Sparkle — documentazione ufficiale](https://sparkle-project.org/documentation/)
- [Duplicate & Clutter Cleanup — Mylio](https://mylio.com/duplicate-photo-finder/)
- [Backup and Protect — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/backup-and-protect)
