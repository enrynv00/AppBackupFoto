# ADR-0018 — Le copie che la libreria Foto del Mac ha ancora non si spostano mai

**Data:** 2026-10-05
**Stato:** Accettata

## Contesto

Il backup Mac → SSD copia `~/Pictures/Photos Library.photoslibrary/originals/<X>/<file>` in `/Volumes/SSD - Enri/Foto iPhone/<X>/<file>`, e copia solo ciò che manca (zero-overwrite). La libreria Foto contiene doppioni veri (asset diversi, stesso contenuto), quindi l'SSD ha gruppi di doppioni dentro `Foto iPhone/`. Durante la verifica dal vivo di ADR-0017 (#46), il pannello Doppioni ne ha spostato una copia nel Cestino → il backup successivo l'ha **ricopiata**, perché esiste ancora in `originals`. Degli 8 file spostati da `Foto iPhone/`, 6 sono già tornati (es. `1103F08E-…BA1C.mp4`, `F4E891D9-…5B25.mov`). È un difetto del progetto 3 di 4 verso «una copia per archivio» (ADR-0015/0016/0017), trovato prima dell'unione a `main`. Piano: `Docs/superpowers/plans/2026-10-05-photos-library-copies-stay.md`.

## Opzioni valutate

- **1. Una copia in `Foto iPhone/` il cui originale c'è ancora nella libreria Foto del Mac non si sposta mai (scelta di Enrico).** Le altre copie del gruppo (fuori da `Foto iPhone/`, o in `Foto iPhone/` ma non più in Foto) si spostano come prima. Se tutte le copie in più di un gruppo sono «nella libreria», il gruppo non ha niente da spostare: casella spenta, con il motivo e cosa fare (toglierle da Foto, non dall'app).
- **2. Escludere `Foto iPhone/` dai Doppioni.** Scartata: perde i doppioni la cui copia in `Foto iPhone/` non è più in Foto, e quelli fra `Foto iPhone/` e le altre cartelle se la tenuta fosse altrove.
- **3. Il backup salta i file spostati nel Cestino (lista dal registro).** Scartata: tocca il percorso di copia, crea un secondo elenco di «cose da non copiare» che diverge da quello del Cestino, e una foto rimessa apposta in Foto non verrebbe più salvata dal backup.
- **4. Togliere i doppioni dalla libreria Foto direttamente dall'app.** Vietata dalla Regola assoluta, punto 3 (read-only sulla sorgente).

## Decisione e motivo

**Opzione 1.** Nuovo tipo `PhotosLibraryPresence` (`nonisolated`, value type): l'insieme delle chiavi che i file di `originals` avrebbero su `Foto iPhone/`, letto una volta per caricamento del pannello, fuori dal main, dal bookmark `.photos`; `nil` (bookmark non risolto, cartella assente, una sottocartella illeggibile, zero file) = «non si sa» ⇒ **ogni** copia in `Foto iPhone/` conta come «nella libreria» (verso sicuro). `duplicateKeepChoice` guadagna la regola **1b**, dopo la regola 1: fra le copie della libreria principale, preferisce come tenuta quella «nella libreria» (altrimenti resterebbero due copie: il backup non ricopierebbe la tenuta, ma la copia «nella libreria» tenuta ferma lo stesso). `DuplicateBatch.Entry.leaving` esclude le copie «nella libreria»: file, byte, piano a blocchi, riepilogo e progresso contano solo le copie che escono davvero. `DuplicateTrasher`, ultima linea di difesa, ricontrolla dal vivo — subito prima di ogni gruppo — che nessuna copia in uscita in `Foto iPhone/` sia tornata in `originals`; libreria non configurata/assente/vuota o percorso con `.`/`..` ⇒ gruppo saltato (nessuna copia in `Foto iPhone/` si muove).

**D1 — tenuta preferita «nella libreria».** Sì, dopo la regola 1 e non prima: così il caso comune (una copia in `Foto iPhone/`, le altre fuori) mantiene motivo e frase di oggi, e si evita di tenere due copie quando una «nella libreria» perderebbe il confronto per data.

**D2 — la regola per cartella dell'utente può spostare una copia «nella libreria»?** No: la regola resta sovrana sulla tenuta, ma non sposta mai una copia «nella libreria». Con «tieni in Takeout, sposta da Foto iPhone» e un gruppo Takeout + Foto iPhone (ancora in Foto), la copia in `Foto iPhone/` resta e il gruppo non ha niente da spostare (casella spenta, motivo scritto): far vincere la regola 1b contraddirebbe un'istruzione esplicita dell'utente.

**D3 — libreria Foto vuota o letta a metà.** Vale «non si sa»: ogni copia in `Foto iPhone/` resta, con una riga d'avviso in testa su cosa fare. Una libreria vuota e una illeggibile si confondono, e fidarsi di zero file renderebbe spostabile tutto anche quando la libreria semplicemente non si è lasciata leggere.

**D4 — «Ottimizza spazio del Mac» in Foto.** **Spenta**, confermato da Enrico: gli originali sono tutti sul Mac, nessuno è solo su iCloud. Con l'opzione accesa un originale potrebbe mancare da `originals` (solo su iCloud): la copia in `Foto iPhone/` risulterebbe «non più in Foto» e potrebbe uscire; il backup non la ricopierebbe finché Foto non riscarica l'originale, poi sì — nessuna foto si perderebbe (la copia tenuta resta, HDD e Cubbit intatti), solo un doppione che ricompare. Limite dichiarato, non eliminato: se Enrico accendesse quell'opzione in futuro, il comportamento sopra si applicherebbe.

**D6 — dove va il lavoro.** Stesso branch `feature/certified-duplicates-ssd`, prima dell'unione a `main`: è un difetto del progetto 3 (#46) trovato durante la sua verifica dal vivo. Nessun numero ROADMAP nuovo, riga aggiunta a #46.

**Cosa si accetta di perdere:** le 6 copie già tornate in `Foto iPhone/` hanno ora due copie sull'SSD (quella ricopiata e quella nel Cestino dell'SSD); svuotare o no il Cestino resta una scelta di Enrico, l'app non lo fa mai. Il registro del Cestino (`TrashedItem.keptPath`, `TrashHistoryEntry.keptPaths`) annota solo la copia tenuta, non quelle che restano per la libreria Foto: per il progetto 4 (doppioni su HDD e Cubbit), le copie che restano sull'SSD restano anche su HDD e Cubbit.

**Per riaprirla** serve un argomento nuovo: per esempio un modo, permesso dalla Regola assoluta, di sapere quali asset esistono ancora in Foto senza interrogare il suo database privato.

## Risposte di Enrico (D1-D6)

Approvato il 2026-10-06: D1-D3, D5 (testo della Regola assoluta, Task 4 del piano) e D6 approvati come proposti; D4 — «Ottimizza spazio del Mac» è spento, gli originali sono tutti sul Mac.
