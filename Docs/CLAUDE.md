# AppBackupFoto — Contesto per Claude Code

Questo file definisce regole, architettura e obiettivi del progetto. Leggilo integralmente prima di toccare qualsiasi file. Il dettaglio dell'architettura Swift (componente per componente) e lo storico bug sono in `.claude/rules/architecture.md` e `.claude/rules/bug-history.md` — si caricano automaticamente quando lavori su `ContentView.swift` o `AppBackupFotoTests/`.

Altre due letture brevi che questo file **non** sostituisce: le **decisioni architetturali** stanno in `Docs/adr/` (una pagina per decisione, con il perché e le conseguenze — oggi 4, tutte sull'indice di contenuto e sul concetto di doppione), e il **vocabolario del progetto** in `Docs/CONTEXT.md`. Se stai per riproporre una scelta che un ADR ha già chiuso, l'ADR dice anche quale argomento nuovo servirebbe per riaprirla.

---

## Identità del progetto

App macOS nativa (SwiftUI, Swift 5.x, target macOS 26+) per il backup automatico delle foto di **Enrico Nanni Vicenzi** su tre destinazioni:

- **Mac → SSD** — copia Photos Library originals in `/Volumes/SSD - Enri/Foto iPhone`
- **SSD → HDD** — mirror locale (deep checksum automatico ogni 30 giorni)
- **SSD → Cubbit S3** — cloud backup sul bucket `backupfoto`

File principale e unico: `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/ContentView.swift` (**~8.400 righe** al 2026-08-27 — il "~2000" scritto qui fino a oggi era fermo a luglio; non fidarti dei numeri di riga per localizzare una funzione, usa `grep -n`). Non esistono altri file Swift nel target app oltre agli Assets — l'entry point `@main` (`BackupFotoEnricoApp`) vive anch'esso in questo file (`AppBackupFotoApp.swift` è stato rimosso perché ridondante).

Target di test separato `AppBackupFotoTests/`: **31 file XCTest** su directory temporanee reali (nessun mock), capostipite `FileSyncerZeroOverwriteTests.swift`, che blinda l'invariante zero-overwrite. **Il target non è file-system-synchronized**: ogni nuovo file di test va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`), altrimenti compila ma non viene mai eseguito e i test "passano" solo perché non girano — verificare sempre il **conteggio totale atteso**, mai il solo `** TEST SUCCEEDED **`.

---

## Regola assoluta — Le foto non si toccano

Le foto sono dati irrecuperabili. Ogni modifica al codice deve rispettare questi vincoli senza eccezioni:

1. **Zero delete**: nessuna operazione di cancellazione su file foto, né locale né remota, in nessun caso.
2. **Zero overwrite**: un file di destinazione esistente non viene mai sovrascritto. Si skippa e si logga.
3. **Read-only sulla sorgente**: la sorgente (Mac Photos Library o SSD) viene solo letta, mai modificata.
4. **Dry-run prima di ogni nuova operazione di sync**: qualsiasi nuova funzione di sincronizzazione deve avere modalità dry-run verificabile prima di essere attivata in produzione.
5. **Confronto sempre esplicito**: prima di copiare, il codice deve verificare esplicitamente che il file di destinazione non esista già.
6. **Mai committare dati foto o credenziali in git** — vedi `.gitignore`: `Log/` (foto reali, non log testuali) e `Script/*.csv` (export credenziali rclone/S3) sono esclusi. Una scrittura su `Log/` da un tool automatico è bloccata anche a livello di hook (`.claude/hooks/protect_log_dir.py`).

---

## Regola sul ciclo AI di revisione (obbligatoria)

Ogni modifica al codice deve passare attraverso un ciclo in due fasi:

**Fase 1 — Scrittura**: scrivi o modifica il codice per soddisfare il requisito.

**Fase 2 — Revisione AI (if-then)**: dopo aver scritto il codice, esegui mentalmente questa checklist come agente di revisione separato:

IF il codice contiene operazioni FileManager (removeItem, moveItem, copyItem):

    THEN verifica che nessuna tocchi file sorgente

    THEN verifica che copyItem abbia guardia di esistenza prima dell'esecuzione

IF il codice fa chiamate S3 (PUT, DELETE, COPY):

    THEN verifica che non ci siano DELETE (eccetto AbortMultipartUpload su cancel, che non tocca dati già scritti)

    THEN verifica che PUT controlli esistenza remota prima di inviare

IF il codice usa bookmark security-scoped:

    THEN verifica che startAccessing() sia chiamato prima dell'uso

    THEN verifica che stopAccessing() sia chiamato in defer o finally

IF il codice aggiorna la UI da contesto async:

    THEN verifica che sia wrappato in Task { @MainActor in }

IF trovi bug in questa revisione:

    THEN documentalo nel log di output e correggilo prima di presentare il risultato finale

Presenta sempre l'output della revisione insieme al codice. Questa checklist è il minimo: se il progetto opera con i ruoli Code Reviewer/Security Auditor (vedi "Team di sviluppo" sotto), la copre in aggiunta, non in sostituzione.

---

## Vincolo tecnico macOS Sequoia (critico)

Qualsiasi subprocess (rsync, bash, rclone, Process()) lanciato da un'app GUI **non riceve i permessi TCC per i volumi esterni**, indipendentemente da Full Disk Access. L'unica soluzione senza firma Apple è: **bookmark + FileManager nativo** (dal 2026-07-29 bookmark normali, non più security-scoped — vedi `.claude/rules/architecture.md` per `BookmarkManager`: il meccanismo di scope non serve dato che l'app non è sandboxata e ha Full Disk Access, e su ExFAT è addirittura rotto). Non proporre mai soluzioni basate su subprocess per accedere a volumi esterni.

---

## Stato attuale (aggiornato 2026-08-27)

La data sopra vale per l'intera tabella. Se ci lavori, aggiornala: fino a oggi diceva 2026-07-29 mentre alcune righe erano già state riscritte al 2026-08-18, e il conteggio dei test era fermo a 139 su 346 reali.

| Funzione | Stato |
| :---- | :---- |
| Mac → SSD | ✅ Funziona, con anteprima dry-run e verifica SHA256 post-copia |
| SSD → HDD | ✅ Funziona; validazione volume-root con alert esplicito impedisce più il caso 0/0 silenzioso |
| SSD → S3 | ✅ Funziona, con allow-list endpoint, abort su multipart fallito/cancellato, retry con backoff, concorrenza adattiva condivisa tra file e parti multipart (2026-08-18), grafico MB/s |
| Ripristino guidato (SSD/HDD/Cubbit → cartella) | ✅ Implementato — 4 passi, indicatori di disponibilità in tempo reale, UI volutamente semplice |
| Sheet completamento | ✅ Funziona |
| Notifiche sistema | ✅ Funzionano |
| SetupView | ✅ Funziona; basta la Libreria Foto per entrare nell'app (`canEnterApp`) |
| SettingsSheet / ToolsSheet / AppearanceSheet | ✅ Funzionano |
| Sidebar hamburger (Report Log, Ripristina, Configurazione, Tools, Catalogo, Foto, Controlla aggiornamenti, Aspetto, Lingua) | ✅ Implementata — l'elenco scritto qui fino al 2026-08-27 era fermo a 6 voci e ne ometteva 3 già in produzione |
| Grafico velocità real-time | ✅ Implementato (Charts, MB/s per S3, file/s locale) |
| Pannello Revisione (ToolsSheet) | ✅ Implementato — config checks, ultimo job persistito, campione integrità SHA256 (con **precedenza ai file copiati e mai verificati**, 2026-08-26), pulizia upload multipart orfani |
| Backup automatico Mac→SSD | ✅ Implementato — trigger su collegamento SSD, toggle on/off in Impostazioni, solo ad app aperta |
| Gate Touch ID all'avvio (#30) | ✅ Implementato — `AuthGateManager` + `LockScreenView`, copre anche le finestre di primo livello Diagnostica/Catalogo/Foto. Verifica con Touch ID reale ancora da fare |
| Catalogo backup (#12) e auto-update Sparkle (#18) | ✅ Implementati — il secondo verificato end-to-end con due release reali |
| Indice di contenuto della libreria + dedup in import (#31) | ✅ **Nucleo implementato (2026-08-25/27)** — indice SHA256 SQLite delle foto/video dell'SSD in `~/Library/Application Support/AppBackupFoto/`, mai sull'SSD; card «Foto già salvate sull'SSD» in Diagnostica; durante un import non si ricopia un file il cui contenuto è già in libreria, né un doppione interno allo stesso import. **Il pannello Doppioni non è mai stato iniziato**; alcune verifiche manuali con l'SSD collegato sono pendenti (vedi sotto). Dettagli in `.claude/rules/architecture.md`, decisioni in `Docs/adr/` |
| Formattazione disco guidata (#28) e Immich (#29) | ⏳ Codice completo e buildabile, **mai eseguiti davvero** — nessun `diskutil eraseDisk`, nessun container avviato. Non marcarli "fatti" |
| Test automatici | ✅ **346 test XCTest passano** (era 139 fino al 2026-07-29, numero rimasto fermo qui per un mese). 31 file in `AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256 (incluso il file che cambia dimensione mentre lo si legge), classificazione retry S3, lettura file a blocchi, logica AIMD del gate adattivo, ordinamento parti multipart, validazione endpoint S3, generazione docker-compose Immich verificata con parser YAML reale, esclusione dischi formattabili `DiskFormatter`, guardia self-import e slug etichetta, e gli otto file nati da #31 (`IndexableKindTests`, `IndexEntryVerdictTests`, `LibraryIndexStoreTests`, `LibraryIndexerTests`, `LibraryIndexStatusTests`, `ImportDedupTests`, `UnverifiedCopiesStoreTests`, `FileSyncerHashVerificationTests`) |
| Build | ✅ `xcodebuild ... build` e `... test` verdi su questo stato (commit `23be5d0`) |

Storico bug (risolti e aperti): vedi `.claude/rules/bug-history.md`.

---

## Verifiche manuali e obiettivi aperti

(Il titolo diceva "Obiettivi futuri (non ancora iniziati)" mentre la sezione elencava anche verifiche già fatte.)

**Prossimo incremento naturale**: il **pannello Doppioni** di #31, previsto dalla spec e **mai iniziato** — nessuna riga di codice, nessun piano. È il secondo consumatore dell'indice, quello a **basso danno**, dove ci si fida della cache invece di rileggere. Subito dopo, o prima, #27-A riprende dal Task 3 (il wizard di import), fermato a suo tempo proprio in attesa di #31.

**Verifica manuale — campione di integrità: fatta (2026-08-23)**. Eseguita da Enrico con SSD e HDD collegati: zero problemi su tutte e 3 le coppie (Mac↔SSD, SSD↔HDD, SSD↔S3). Confermato anche che `sampleS3Pair` cancella davvero i file temporanei scaricati da S3 per il confronto (`defer { try? fm.removeItem(at: tempURL) }`, nessun residuo trovato in `$TMPDIR` dopo il check). Badge di Revisione (#20) già confermato in una sessione precedente (2026-08-16).

**Verifiche manuali ancora pendenti**, in stand-by su richiesta esplicita di Enrico (2026-08-23) — vedi memoria di progetto: test TCC/formattazione reale per #28 (`Docs/superpowers/plans/2026-08-17-setup-guide-formatting.md`, Task 4 Step 5) e per #29/Immich (`Docs/superpowers/plans/2026-08-17-immich-integration.md`, Task 5 Step 4), verifica upload S3 reale con Monitor Attività, conferma Touch ID reale.

**Verifiche manuali pendenti per #31 (indice di contenuto), tutte con l'SSD collegato** — Enrico non ha l'SSD a disposizione per qualche giorno (2026-08-27). Sono l'unico step non spuntato del piano `Docs/superpowers/plans/2026-08-25-library-content-index.md` (Task 6, Step 5) più quanto emerso dalle review:

1. **Prima costruzione reale dell'elenco dall'app**: aprire Diagnostica → «Foto già salvate sull'SSD» → «Crea l'elenco», guardare progresso e «Interrompi». È l'unico percorso della card mai eseguito davvero.
2. **Misurare la durata.** La card dichiara «di solito servono dai 5 ai 15 minuti» (`LibraryIndexCard.durata`) e **quel numero non è mai stato misurato**: è un ordine di grandezza scritto a tavolino. Va sostituito con la misura vera sul volume reale.
3. **Censire le estensioni realmente presenti sull'SSD.** `IndexableKind` classifica per `UTType`, e `.mkv`, `.x3f`, `.hevc`, `.insv`, `.lrv` **non** risultano media: quei file non entrano nell'indice e non partecipano al dedup. È il verso sicuro (vengono copiati, mai saltati), ma se sull'SSD ce ne sono molti il dedup li ignora in silenzio.
4. **`ls -a "/Volumes/SSD - Enri"`** — chiude la questione lasciata aperta su `lost+found` e `Backups.backupdb`: sono nella lista `LibraryExclusions`, ma nessuno ha mai verificato se esistano davvero su quel volume.
5. **Un avviso della card deve comparire nella finestra Diagnostica.** Aprire Diagnostica **senza SSD collegato** e premere «Crea l'elenco»: il messaggio deve apparire *in quella finestra*. È il rilievo chiuso il 2026-08-27 con `AlertSink`, e per costruzione non è verificabile da un test (due scene SwiftUI).

**Rilievi minori di #31 lasciati aperti** (non richiedono l'SSD, nessuno è bloccante): il registro anti-gergo delle righe di stato è coperto su 6 diramazioni su 9; plurali e `id` delle righe di `LibraryIndexStatus` non sono testati; i debiti di verifica delle copie non confermate **scadono in blocco se l'orologio di sistema salta in avanti** (verso non sicuro, ma il danno è una lista di priorità svuotata, non un file perso); la lettura manuale dell'elenco e i job di copia non si guardano a vicenda (i bottoni della card non sanno di un job in corso, mentre l'aggiornamento automatico sì); `NSTemporaryDirectory()` resta nell'allow-list delle posizioni valide per il file dell'indice anche in produzione, non solo nei test; e non è escluso che SwiftUI inghiotta una seconda presentazione quando l'avviso nasce dentro l'`onConfirm` di un altro alert.

---

## Build e distribuzione

- Compilare: `Cmd+B` (o `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`)
- Testare: `Cmd+U` (o target `AppBackupFotoTests` via `xcodebuild ... test`)
- Distribuire: Product → Archive → Distribute → Custom → Copy App → sostituisci in /Applications → ri-aggiungi in System Settings → Privacy → Full Disk Access

---

## Team di sviluppo (aggiornato 2026-08-16)

Questo progetto usa il workflow a ruoli espliciti descritto in `~/.claude/docs/specs/2026-08-11-agent-role-orchestration-design.md`: fase Architect (brainstorming → spec → piano, sempre con approvazione esplicita di Enrico) seguita da un team autonomo (Implementer + Code Reviewer + Security/Rules Auditor, ruoli globali in `~/.claude/agents/`) che esegue tutti i task del piano fino in fondo, con un solo checkpoint umano a fine intervento (eccetto blocchi reali che richiedono una decisione di Enrico).

**Sostituisce la vecchia regola "Pattern Advisor"**: non serve chiedere conferma prima di ogni dispatch. Dal 2026-08-31 Implementer, Code Reviewer e Security/Rules Auditor girano su **Sonnet 5** — scrivere codice su una spec già decisa, cercare pattern noti e fare audit di sicurezza sono lavori meccanici, e i subagenti sono la quasi totalità del consumo. **Architect resta su Opus 5**: il ragionamento architetturale è l'unico punto in cui il modello grande si ripaga, ed è circa il 2% del consumo. (Fino al 2026-08-30 giravano tutti su Opus 5.)

Gate automatici attivi su questo progetto (vedi `.claude/settings.json`): un hook blocca la scrittura sotto `Log/`, un hook blocca la fine sessione se `ContentView.swift`/i test sono stati modificati senza un build/test verde successivo, e un hook blocca i comandi git distruttivi (`push`, `reset --hard`, `clean -f`, `branch -D`, `checkout .`, `restore .`) prima che vengano eseguiti — `git add` e `git commit` restano liberi.

---

## Agent skills

Dal 2026-08-25 questo progetto ha installate le 25 skill di [mattpocock/skills](https://github.com/mattpocock/skills) v1.2.3 in `.claude/skills/`, **solo a livello di progetto**, in prova. Sono complementari ai ruoli sopra, non li sostituiscono: i ruoli dicono *chi* fa il lavoro, le skill *come* si fa.

### Issue tracker

Le issue vivono come markdown in `Docs/superpowers/tickets/`, non su GitHub — il repo è pubblico e questo progetto maneggia credenziali S3. Vedi `Docs/agents/issue-tracker.md`.

### Triage labels

Le cinque etichette canoniche (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), usate come valori della riga `Status:` nei file di ticket. Vedi `Docs/agents/triage-labels.md`.

### Domain docs

Layout single-context, tutto sotto `Docs/` (non alla root). Vedi `Docs/agents/domain.md`.

### Cautele

- **`/code-review`**: la skill di mattpocock ha lo stesso nome del built-in di Claude Code e lo shadowa in questo progetto. È voluto — controlla Standards + Spec invece di cacciare bug. Il ruolo Code Reviewer usa questa.
- **`/research`**: non usarla, ha un bug di ricorsione noto (#530) che spawna run duplicate. Usa la `deep-research` globale.
- **`/wizard`**: in fase di scoping legge i file `.env*`. Qui non ce ne sono, ma le credenziali S3 stanno in `rclone.conf` e nel Keychain: tienilo presente se un giorno ne aggiungi uno.
- **`/diagnosing-bugs`**: fa incollare output e artefatti di debug nei ticket. Redigi tu i segreti — l'issue upstream sul redacting automatico (#674) è aperta.

---

## Progettazione prima dell'implementazione

Il rapporto da tenere è: **più progettazione a monte, meno implementazione a caso**. Regole vincolanti.

**Quando serve l'Architect.** Per ogni modifica non banale si consulta *prima* l'Architect per un piano, e solo dopo si passa il piano all'Implementer. Una modifica è non banale se ricade in almeno uno di questi casi:

- tocca più di un file;
- cambia un'interfaccia (firma pubblica, protocollo, contratto fra tipi);
- cambia uno schema dati (schema SQLite dell'indice, formato di un file su disco, formato di un ticket o di un log);
- tocca un flusso di autenticazione o di credenziali (Keychain, `rclone.conf`, chiavi S3, firma/notarizzazione);
- aggiunge una dipendenza (package Swift, tool esterno, servizio).

Sotto questa soglia — fix di una riga, rinomina locale, correzione di un commento o di un test isolato — si va diretti all'Implementer senza piano.

**L'Implementer esegue piani, non li inventa.** Riceve un task alla volta, con il testo esatto preso dal piano. Se la richiesta è ambigua, incompleta o in conflitto con il codice che trova, **non improvvisa e non "interpreta"**: la rimanda all'Architect (via `SendMessage`) e aspetta un piano aggiornato. Scoprire a metà task che serve una decisione di design è un motivo valido per fermarsi e rimbalzare, non per scegliere da soli.

**Le decisioni architetturali si scrivono.** Ogni decisione di design presa dall'Architect e approvata va registrata in `Docs/adr/` come file numerato progressivamente (`NNNN-titolo-in-kebab-case.md`, continuando la numerazione esistente). Ogni ADR contiene:

1. **Contesto** — qual era il problema e quali vincoli erano in gioco;
2. **Opzioni valutate** — le alternative considerate davvero, non solo quella scelta;
3. **Decisione e motivo** — cosa si è scelto e *perché*, incluso cosa si accetta di perdere.

Un ADR si scrive prima che l'Implementer parta, non dopo. Gli ADR esistenti (`0001`–`0004`) sono il modello di riferimento per tono e lunghezza.

---

## Regole di lettura dei file

Regole operative per non sprecare contesto (e token) durante una sessione.

- **Non rileggere file interi già letti in questa sessione.** Se serve ricontrollare un punto preciso, rileggi solo quel punto.
- **Per cercare si usa Grep, non Read.** Read serve quando sai già dove guardare; se stai ancora cercando *dove* si trova qualcosa, la risposta è Grep (o Glob per i nomi di file).
- **Sui file grandi leggi porzioni mirate**, con `offset`/`limit` attorno alla zona che ti interessa, invece di caricare tutto il file. Vale in particolare per `ContentView.swift`.
- **Non incollare output lunghi nel contesto** — log, dump, elenchi di file, output di build. Filtra prima alla fonte con `grep`, `head`, `tail`, `wc -l`, e porta dentro solo le righe che servono davvero.

---

## Come iniziare una sessione

Leggi questo file, poi leggi `ContentView.swift`, poi affronta il primo obiettivo futuro aperto (vedi sopra). Non fare assunzioni sul codice senza averlo letto prima.
