# ADR-0007 — L'aggiornamento dell'elenco è l'ultimo passo del backup

**Data:** 2026-09-19
**Stato:** Accettata

## Contesto

Dopo ogni MAC → SSD e ogni importazione l'elenco delle foto già salvate va rimesso in pari, perché il job ha scritto sull'SSD. Fino al 2026-09-19 lo faceva una lettura avviata *dopo* la fine del job: il backup risultava finito, i pulsanti tornavano attivi, e premerli produceva un avviso (`JobStartGate`) che rimandava a un'altra finestra («Interrompi in Diagnostica»). Una lettura che l'utente non ha chiesto si presentava come un ostacolo.

Spec: `Docs/superpowers/specs/2026-09-19-index-refresh-as-backup-step-design.md`. Piano: `Docs/superpowers/plans/2026-09-19-index-refresh-as-backup-step.md`. Parte dal `main` post-merge di `fix/mainactor-isolation` (ADR-0006): il lavoro presuppone `LibraryIndexer.scan` fuori dal main thread, altrimenti un job che resta «in corso» per diversi minuti sarebbe peggio di oggi.

## Opzioni valutate

**A. La lettura come ultimo passo del job, che resta `.running` fino alla fine (scelta).** Il job non risulta «finito» finché anche l'elenco non è aggiornato: stessa barra, stesso «Interrompi», riepilogo e notifica solo alla fine. Riusa tutti i controlli che già leggono `isRunning` (pulsanti dei tre backup, wizard di importazione, `MenuBarIcon`, cestinamento doppioni, `LibraryIndexCommandGate`, conferma di uscita) senza toccarli.

**B. Un terzo stato «backup finito ma elenco in aggiornamento», consultato da ogni pulsante.** Obbliga a toccare ogni sito che oggi legge `isRunning` — la stessa lista dell'opzione A — e il primo dimenticato riapre esattamente il problema di partenza.

**C. Lasciare la lettura separata e disattivare i pulsanti durante `isIndexing` con il motivo scritto.** Meno invasivo, ma non risolve il problema di fondo: un backup «finito» che in realtà blocca ancora gli altri backup resta una menzogna nella UI, solo con un avviso più chiaro sopra.

Per «Interrompi» durante il passo 2, tre esiti valutati: «completato con nota» (i dati sono al sicuro, si segnala solo che l'elenco non è aggiornato), «interrotto» (coerente col pulsante premuto ma falso sulle foto: sono già copiate e verificate), «completato senza nota» (nessun testo nuovo, ma nasconde una fermata — la classe di problema che il progetto teme di più).

## Decisione e motivo

**(A)**, con «Interrompi» durante il passo 2 ⇒ **«Backup completato»** più una riga che dice che l'elenco non è stato aggiornato («Hai fermato l'aggiornamento dell'elenco delle foto sull'SSD. Le foto sono state copiate lo stesso: l'elenco si rimetterà in pari al prossimo backup.»). Il job che resta `.running` riusa gratis tutti i controlli che già leggono `isRunning`; l'opzione B li avrebbe dovuti toccare tutti, e il primo dimenticato riapre il problema. «Completato» perché le foto sono copiate e verificate (il `JobSummary` è già salvato come riuscito alla fine del passo 1): dire «interrotto» o «fallito» insegnerebbe a diffidare di un backup riuscito — lo stesso principio già applicato a `copiedUnverified` («sovrastimare i problemi insegna a ignorare l'allarme»).

Decisioni collegate, prese da Enrico il 2026-09-19:

1. **Collegamento dell'SSD con il backup automatico spento**: si toglie la lettura automatica al collegamento (`autoRefreshLibraryIndexIfEnabled`/`LibraryIndexAutoRefresh.shouldRun` rimossi). L'elenco si aggiorna solo come ultimo passo di un backup/importazione, o a mano da Diagnostica. La chiave `UserDefaults` (`autoRefreshLibraryIndex`) non cambia — solo il testo dell'interruttore in Impostazioni.
2. **«Interrompi» durante il passo 2**: riepilogo «Backup completato» (verde) con la riga «Hai fermato l'aggiornamento dell'elenco…», non «interrotto».
3. **«passo 1 di 2» durante la copia**: sì, per non far comparire il passo 2 a sorpresa quando la barra è già al 100%.

**Cosa si accetta di perdere**: dopo un MAC → SSD gli altri backup (SSD → HDD, SSD → Cubbit) aspettano la fine della lettura, o «Interrompi». Il registro dell'ultimo job (`JobHistoryStore`) non dice se l'elenco è stato aggiornato — lo dice solo la card in Diagnostica. Con la lettura automatica al collegamento rimossa, se l'SSD viene modificato fuori dall'app (Finder, un altro Mac) l'elenco resta indietro fino al prossimo backup o import — innocuo, perché una voce in più si ricontrolla comunque prima di saltare un file (ADR-0003).

**Per riaprire la decisione** serve un argomento nuovo: per esempio una lettura così lenta da rendere il passo 2 più lungo della copia nella maggior parte dei backup.

## Conseguenze

- `BackupRunner.run` finisce in due tempi: `finishCopyStep(result:label:)` salva il `JobSummary` e decide se parte il passo 2; `finishJob(label:listOutcome:)` è l'unico punto in cui il job finisce davvero (`phase = .success`, notifica, `completionSnapshot`).
- La lettura ha due ingressi sopra un'unica `startLibraryIndexScan(full:onFinish:)`: il passo 2, silenzioso (nessun avviso, qualunque esito finisce nel riepilogo), e il comando manuale da Diagnostica, con i suoi avvisi invariati.
- `LibraryIndexer.scan` guadagna un avanzamento (`onProgress`) anche sui file invariati (parametro `progressEvery`, default 250) e `Progress.total` parte dal numero di voci già in elenco invece che da 0 — cambiamento additivo, nessuna decisione di rimozione/rehash toccata.
- Al collegamento dell'SSD non parte più nessuna lettura da sola: solo il backup automatico (se acceso).
- Nessuno schema SQLite, nessun formato su disco, nessuna chiave `UserDefaults` nuova o rinominata. `JobSummary` identico. L'esito del passo 2 viaggia in `JobStats.listStepOutcome`, non persistito.
