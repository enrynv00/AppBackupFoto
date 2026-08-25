# Issue tracker: Markdown locale in `Docs/`

Le issue e le spec di questo repo vivono come file markdown sotto `Docs/superpowers/`, non su GitHub.

**Perché non GitHub Issues**: il repo `enrynv00/AppBackupFoto` è **pubblico**. Le skill che incollano output di debug, log e artefatti dentro un ticket (`diagnosing-bugs` in particolare) scriverebbero su una pagina visibile a chiunque, e questo progetto maneggia credenziali S3 Cubbit. Tenendo i ticket in locale restano privati e versionati insieme al codice. Scelta di Enrico, 2026-08-25.

Se un giorno il repo diventasse privato, questa decisione va riaperta: il tracker nativo dà link, stati e blocking gratis.

## Convenzioni

Il progetto ha già una struttura consolidata, che queste skill **riusano invece di duplicare**:

- **Spec**: `Docs/superpowers/specs/YYYY-MM-DD-<nome>-design.md` (34 file esistenti)
- **Piani**: `Docs/superpowers/plans/YYYY-MM-DD-<nome>-plan.md` (33 file esistenti)
- **Ticket**: `Docs/superpowers/tickets/<feature-slug>/NN-<slug>.md`, numerati da `01`, **mai** un unico file con tutti i ticket dentro
- **Roadmap**: `Docs/ROADMAP.md` resta la lista prioritizzata degli interventi, con la numerazione `#N` già in uso. Un ticket che nasce da un punto della roadmap lo cita nel corpo (`Roadmap: #31`).
- **Stato di triage**: una riga `Status:` in cima al file del ticket (le stringhe sono in `triage-labels.md`)
- **Commenti**: si appendono in fondo al file sotto un heading `## Comments`

## Quando una skill dice "publish to the issue tracker"

Crea un file sotto `Docs/superpowers/tickets/<feature-slug>/`, creando la cartella se non esiste. Per una spec, usa invece `Docs/superpowers/specs/` con la convenzione di data già in uso.

## Quando una skill dice "fetch the relevant ticket"

Leggi il file al percorso indicato. Normalmente Enrico passa direttamente il percorso, il numero del ticket, o il numero di roadmap `#N`.

## Operazioni di wayfinding

Usate da `/wayfinder`. La **mappa** è un file con un file **figlio** per ticket.

- **Mappa**: `Docs/superpowers/tickets/<effort>/map.md` (corpo con Notes / Decisions-so-far / Fog)
- **Ticket figlio**: `Docs/superpowers/tickets/<effort>/NN-<slug>.md`, numerati da `01`, con la domanda nel corpo. Una riga `Type:` registra il tipo (`research`/`prototype`/`grilling`/`task`); una riga `Status:` registra `claimed`/`resolved`.
- **Blocking**: una riga `Blocked by: NN, NN` in cima. Un ticket è sbloccato quando ogni file che elenca è `resolved`.
- **Frontiera**: scandisci la cartella cercando i file aperti, sbloccati e non reclamati; vince il numero più basso.
- **Claim**: metti `Status: claimed` e salva **prima** di iniziare a lavorare.
- **Resolve**: appendi la risposta sotto un heading `## Answer`, metti `Status: resolved`, poi appendi un puntatore di contesto (sintesi + link) alle Decisions-so-far in `map.md`.

## Regola di progetto che vale anche qui

Vale la regola assoluta del progetto: **zero delete, zero overwrite**. Un ticket risolto o abbandonato non si cancella e non si sovrascrive — si marca `Status: resolved` o `Status: wontfix` e resta lì come storia.
