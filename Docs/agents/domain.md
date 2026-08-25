# Domain Docs

Come le skill di engineering devono consumare la documentazione di dominio di questo repo.

Layout: **single-context** (un solo contesto, niente monorepo). Tutta la documentazione sta sotto `Docs/`, **non** alla root: è la convenzione già in uso nel progetto.

> Nota: il filesystem è case-insensitive, quindi `docs/` e `Docs/` sono la stessa cartella. Scrivi sempre `Docs/` per non creare confusione con un secondo albero apparente.

## Prima di esplorare, leggi questi

In ordine:

1. **`Docs/CLAUDE.md`** — architettura, stato attuale, decisioni esplicite già prese. È la fonte primaria del progetto e va letta **per intera** prima di toccare il codice.
2. **`Docs/ROADMAP.md`** — gli interventi prioritizzati con stato fatto/aperto, numerati `#N`.
3. **`Docs/CONTEXT.md`** — il glossario del dominio, se esiste.
4. **`Docs/adr/`** — le ADR che toccano l'area su cui stai per lavorare, se esistono.
5. **`Docs/superpowers/specs/` e `Docs/superpowers/plans/`** — lo storico di spec e piani di ogni feature, incluse le bozze non approvate. Se stai per riprogettare qualcosa, molto probabilmente esiste già una spec che spiega perché è com'è.

Se `CONTEXT.md` o `Docs/adr/` non esistono, **procedi in silenzio**. Non segnalarne l'assenza e non proporre di crearli in anticipo: `/domain-modeling` (raggiunta da `/grill-with-docs` e `/improve-codebase-architecture`) li crea pigramente, quando un termine o una decisione viene effettivamente risolta.

## Struttura dei file

```
/
├── Docs/
│   ├── CLAUDE.md              ← architettura + stato (fonte primaria)
│   ├── ROADMAP.md             ← interventi prioritizzati #N
│   ├── CONTEXT.md             ← glossario di dominio (creato pigramente)
│   ├── adr/                   ← decisioni architetturali (creato pigramente)
│   │   └── 0001-<slug>.md
│   ├── agents/                ← configurazione per le skill (questi file)
│   └── superpowers/
│       ├── specs/             ← spec per feature, datate
│       ├── plans/             ← piani di implementazione, datati
│       └── tickets/           ← ticket (vedi issue-tracker.md)
├── AppBackupFoto/
│   └── ContentView.swift      ← ~2500 righe, per convenzione TUTTO il codice sta qui
└── AppBackupFotoTests/
```

## Usa il vocabolario del glossario

Quando il tuo output nomina un concetto di dominio (titolo di un ticket, proposta di refactoring, ipotesi, nome di un test), usa il termine come definito in `Docs/CONTEXT.md`. Non derivare verso sinonimi che il glossario evita esplicitamente.

Se il concetto che ti serve non è ancora nel glossario, è un segnale: o stai inventando un linguaggio che il progetto non usa (ripensaci), oppure c'è un vuoto reale (annotalo per `/domain-modeling`).

## Segnala i conflitti con le ADR

Se il tuo output contraddice una ADR esistente, dillo esplicitamente invece di scavalcarla in silenzio:

> _Contraddice ADR-0007 (nome), ma vale la pena riaprirla perché…_

Lo stesso vale per le **decisioni esplicite registrate in `Docs/CLAUDE.md`**, che qui hanno lo stesso peso di una ADR. Alcune sono marcate come da non riproporre senza un motivo nuovo (es. il no alla cifratura lato client, 2026-08-02): trattale come vincoli, non come questioni aperte.

## Vincolo che sovrasta tutto

**Zero delete, zero overwrite, read-only sulla sorgente** — vale anche in direzione restore. Nessuna proposta di design, refactoring o ottimizzazione può violarlo. Se un'idea lo richiede, l'idea è sbagliata: portala a Enrico come domanda esplicita, non come modifica.
