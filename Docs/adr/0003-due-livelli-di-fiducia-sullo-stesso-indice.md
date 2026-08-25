# Due livelli di fiducia sullo stesso indice

La terna `(percorso, dimensione, mtime)` non è una garanzia che il contenuto di un file non sia cambiato: `mtime` è riscrivibile da userspace (exiftool, `rsync -t`, restore da Finder). restic e borg si irrobustiscono con inode e ctime, ma **su ExFAT l'inode non è stabile** (documentato da Apple DTS), quindi quel rinforzo qui non esiste: la nostra chiave di invalidazione è **strutturalmente più debole** della loro, non equivalente.

Invece di inseguire una chiave perfetta, abbiamo deciso che **lo stesso indice si usa con due livelli di fiducia diversi**, perché il costo di un errore non è lo stesso nei due usi:

- **Segnalazione nel pannello Doppioni** (basso danno): ci si fida della cache. Un hash stantio produce una riga sbagliata in un elenco.
- **Skip durante un import** (alto danno): **non ci si fida**. Il file candidato sull'SSD viene riletto e rihashato prima di decidere lo skip, perché un hash stantio qui significa una foto non importata in silenzio.

Costa la lettura di un solo file per candidato duplicato — trascurabile, dato che il file sorgente va comunque letto per hasharlo.

## Conseguenze

Chi legge il codice dell'import troverà una rilettura che "sembra ridondante", visto che l'indice ha già la risposta. Non lo è: è questa decisione. Non rimuoverla per ottimizzare.

A rinforzo, tre difese: la regola anti-racy (da git/borg), la tolleranza DST sugli shift di 3600s/1800s (**senza prior art, scelta di questo progetto**) e la modalità di verifica completa.

## Nota (2026-08-25): la regola DST ha un verdetto proprio, e serve

Nella prima stesura di questa ADR lo shift di fuso e il dubbio anti-racy producevano lo **stesso** verdetto `.needsVerification`, e lo scanner li trattava in modo identico: entrambi portavano al rehash. Il Critic ha fatto notare che così la regola DST **non aveva alcun effetto osservabile** — e quindi non otteneva ciò che questa ADR le attribuisce come unico scopo, cioè evitare che un cambio di ora legale faccia rihashare l'intera libreria due volte l'anno.

Sono ora due verdetti distinti. `.needsVerification` (dubbio anti-racy) rihasha, perché il file **potrebbe** davvero essere cambiato. `.timezoneShift` no: adotta il nuovo mtime e tiene l'hash già calcolato.

È sicuro proprio per la distinzione che questa ADR stabilisce. Perché sia un errore servirebbe un file modificato, di dimensione identica al byte, con mtime spostato di esattamente 3600s (±50ms). E anche in quel caso il danno è confinato al percorso a **basso** danno: l'import rilegge e rihasha comunque il candidato prima di saltarlo, quindi nessuna foto viene persa — al massimo una riga sbagliata nel pannello Doppioni.

**Se qualcuno in futuro pensasse di semplificare unendo i due verdetti**: leggere prima questa nota. Unirli riporta il rihash semestrale dell'intera libreria, in silenzio.
