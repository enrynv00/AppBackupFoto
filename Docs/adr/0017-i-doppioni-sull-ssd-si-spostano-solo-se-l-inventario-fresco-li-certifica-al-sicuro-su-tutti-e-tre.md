# ADR-0017 — I doppioni sull'SSD si spostano solo se un inventario fresco li certifica al sicuro su tutti e tre gli archivi

**Data:** 2026-10-05
**Stato:** Accettata

## Contesto

Il pannello Doppioni (ADR-0005) sposta nel Cestino dell'SSD copie byte-identiche (ADR-0001) dopo una rilettura dal vivo di ogni membro del gruppo, ma non sapeva se quella foto esiste anche su HDD e Cubbit. Con l'inventario certificato (ADR-0015, ROADMAP #44) lo si sa per contenuto, e dopo la riparazione (ADR-0016, #45) tutte le foto risultano su tutti e tre. È il progetto 3 di 4 verso «una copia per archivio»: prima l'SSD, poi (progetto 4) HDD e Cubbit. Spec: `Docs/superpowers/specs/2026-10-05-certified-duplicates-ssd-design.md`; piano: `Docs/superpowers/plans/2026-10-05-certified-duplicates-ssd.md`.

## Opzioni valutate

- **A. Lasciare il pannello com'è.** Scartata: la garanzia «la foto resta al sicuro altrove» sarebbe solo un'abitudine (i backup), non una verifica.
- **B. Ricontrollare HDD e Cubbit dal vivo al momento dello spostamento.** Scartata: per decine di migliaia di gruppi vorrebbe dire rileggere l'HDD e chiedere a Cubbit per ore a ogni corsa; l'inventario esiste apposta.
- **C. Fidarsi dell'inventario, a condizione che sia completo e più recente dell'ultimo backup (scelta).** Un gruppo si può spuntare solo se il suo contenuto è ✅ nell'ultimo giro completo, nessun job che scrive sugli archivi è finito (o partito) dopo l'inizio di quel giro, e ogni sua copia sull'SSD è nell'inventario di quel giro con lo stesso contenuto. Allo spostamento resta la rilettura di ADR-0005, più un ricontrollo della freschezza prima di ogni blocco.

## Decisione e motivo

**Freschezza** (decisione 1 di Enrico): l'inventario vale se è completo su tutti e tre gli archivi (ADR-0015: incompleto non è assente) e nessun job che passa da `BackupRunner.run(label:)` — Mac → SSD, SSD → HDD, SSD → Cubbit, import — ha scritto dopo l'inizio del giro. «Ha scritto» = la più recente fra la fine dell'ultimo job (`JobHistoryStore`) e l'inizio dell'ultimo job (`lastArchiveWriteJobStartedAt`, scritta prima di ogni scrittura: copre il job interrotto da una chiusura forzata). Spostamenti nel Cestino, annullamenti, riparazioni, inventario e lettura dell'elenco non lo invecchiano.

**Gruppi non certificati** (decisione 2): visibili, casella spenta, una riga col motivo; selezione in massa e regola per cartella li saltano e lo dicono. Un gruppo che la certificazione non conosce non è mai spuntabile.

**Una regola sola per ✅**: `InventoryClassifier.classify`, la stessa della finestra Inventario, calcolata una volta fuori dal main e tenuta in memoria finché gli stati dei tre archivi non cambiano.

**Copia tenuta** (decisione 3): stessa scelta di oggi; il registro del Cestino (`TrashedItem.keptPath`) e la storia degli spostamenti (`TrashHistoryEntry.keptPaths`) annotano il percorso tenuto, relativo alla radice dell'SSD, per il progetto 4.

**Cosa si accetta di perdere:** dopo ogni backup, anche uno che non ha copiato niente, serve un aggiornamento dell'inventario prima di spostare doppioni (l'ultimo è durato 5 minuti, il secondo giro misurato 75); un gruppo con una copia comparsa sull'SSD dopo l'inventario resta bloccato finché l'inventario non la vede; la base in memoria occupa decine di MB mentre l'app è aperta.

**Per riaprirla** serve un argomento nuovo: per esempio un modo di sapere dal vivo, in pochi secondi, che HDD e Cubbit hanno ancora quel contenuto (checksum SHA256 lato server su Cubbit), che renderebbe superfluo fidarsi dell'inventario.

## Risposte di Enrico (S1-S9, D1-D3)

Risposte del 2026-10-05: S1-S9 approvati come proposti; D1 testo del punto 1 della «Regola assoluta» approvato così com'è; D2 conta anche un job che non ha copiato niente; D3 la base di certificazione resta in memoria nel runner.
