# Ticket

Il tracker di questo progetto. Un file per ticket, mai un unico file con tutti i ticket dentro.

```
Docs/superpowers/tickets/<feature-slug>/NN-<slug>.md   # numerati da 01
Docs/superpowers/tickets/<feature-slug>/map.md         # solo per /wayfinder
```

In cima a ogni ticket:

```markdown
# Titolo del ticket

Status: needs-triage        # vedi Docs/agents/triage-labels.md
Roadmap: #31                # se nasce da un punto di Docs/ROADMAP.md, altrimenti ometti
Blocked by: 01, 02          # oppure "—"
```

Regole complete in `Docs/agents/issue-tracker.md`. Vale la regola zero-delete: un ticket chiuso si marca `resolved` o `wontfix`, non si cancella.
