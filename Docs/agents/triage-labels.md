# Triage Labels

Le skill ragionano su cinque ruoli canonici di triage. Questa tabella li mappa sulle stringhe effettivamente usate in questo repo.

Il tracker è **markdown locale** (vedi `issue-tracker.md`), quindi queste non sono etichette di GitHub: sono i valori ammessi della riga `Status:` in cima a ogni file di ticket. Non è stata creata nessuna label su GitHub.

| Ruolo in mattpocock/skills | Stringa in questo repo | Significato                                      |
| -------------------------- | ---------------------- | ------------------------------------------------ |
| `needs-triage`             | `needs-triage`         | Da valutare, non ancora deciso se e come farlo   |
| `needs-info`               | `needs-info`           | Fermo in attesa di una risposta di Enrico        |
| `ready-for-agent`          | `ready-for-agent`      | Completamente specificato, un agente può partire |
| `ready-for-human`          | `ready-for-human`      | Richiede una decisione o un'azione manuale       |
| `wontfix`                  | `wontfix`              | Deciso di non farlo                              |

Quando una skill nomina un ruolo (es. "apply the AFK-ready triage label"), usa la stringa corrispondente nella colonna centrale.

Esempio in cima a un file di ticket:

```markdown
# Indice contenuto libreria

Status: ready-for-agent
Roadmap: #31
Blocked by: —
```

Per cambiare vocabolario, modifica la colonna centrale: le skill leggono da qui.

## Nota su `wontfix`

Un ticket `wontfix` **non si cancella**, coerentemente con la regola zero-delete del progetto. Resta come traccia della decisione — e serve: `Docs/CLAUDE.md` registra già decisioni esplicite da non riproporre (es. il no alla cifratura lato client), e un `wontfix` con la motivazione scritta evita di rimetterle in discussione a distanza di mesi.
