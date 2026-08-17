# Spec — Guida anti-idiota per setup + formattazione dischi (roadmap #28)

## Problema

Onboarding fragile: se un passo di configurazione va storto (es. bookmark non sulla root di un volume, come il BUG-1 storico) o serve aggiungere/sostituire un dispositivo dopo il primo setup, oggi non c'è un percorso guidato — solo rifare da capo o capire da soli dove intervenire in Impostazioni. Enrico vuole anche poter formattare un disco nuovo direttamente dall'app.

## Cosa è già coperto (non reinventare)

Verificato nel codice reale prima di progettare: due dei tre scenari di guida chiesti in brainstorming sono **già gestiti** dal codice esistente, non serve nuova logica:

- **Aggiungere un dispositivo dopo**: `SettingsSheet` mostra già `LocationRow` per SSD/HDD/Libreria Foto con bottone "Seleziona" se non configurato — raggiungibile in qualsiasi momento da Impostazioni, nessun bisogno di rifare il Setup.
- **Sostituire un dispositivo esistente**: stessa `LocationRow`, bottone "Cambia" se già configurato — richiama `BookmarkManager.selectAndSave(loc)`, stesso meccanismo.

Il lavoro reale di questa spec si riduce quindi a due pezzi genuinamente nuovi:
1. **Formattazione di un disco nuovo dall'app.**
2. **Rendere azionabili le segnalazioni già esistenti** (`ReviewEngine.checkBookmarkRoots`, roadmap #20) — oggi sono solo informative in Tools → Revisione, non hanno un bottone che porta dritto alla correzione.

## Decisioni prese in brainstorming (2026-08-17, one-question-at-a-time)

- **Formattazione**: permessa **solo su dischi mai configurati prima** — mai su un disco che risulta già SSD o HDD configurato (bookmark salvato che si risolve a quel disco). Operazione distruttiva reale, mitigata così.
- **Filesystem**: l'app **chiede ogni volta** quale usare, con **APFS pre-selezionato** come default consigliato (nativo macOS, nessun limite di dimensione file — rilevante per gli zip da 40-50GB nella cartella "Zip"). ExFAT resta un'opzione se Enrico vuole leggibilità cross-platform.

## Design tecnico

### Formattazione disco

**Tech Stack**: nessuna API pubblica Swift per formattare un disco — serve `diskutil` via `Process` (stesso genere di operazione di sistema di `security` già usato altrove nel progetto per il Keychain).

- **Elenco dischi candidabili**: `diskutil list -plist external physical` (via `Process`, parsing plist) → filtra ai soli dischi fisici esterni. Esclude qualunque disco il cui path risolto corrisponda al bookmark SSD o HDD attualmente salvato (confronto sul path risolto, non sul nome — un disco può essere rinominato).
- **Conferma esplicita, pattern "digita il nome"**: mostra nome/dimensione/filesystem attuale del disco scelto, richiede che l'utente digiti il nome esatto del disco per abilitare il bottone "Formatta" — stesso livello di attrito di operazioni distruttive equivalenti (coerente con "mai un'azione distruttiva a un click"). Nessun'altra conferma "soft" (NSAlert semplice) è sufficiente per un'operazione irreversibile come questa.
- **Esecuzione**: `diskutil eraseDisk <APFS|ExFAT> <nomeScelto> <identificativoDisco>` via `Process`, cattura output/errori, mostra esito.
- **Dopo il successo**: nessuna nuova logica di selezione — l'app rimanda l'utente alla `LocationRow` già esistente in Impostazioni ("Ora seleziona questo disco come SSD o HDD da Impostazioni") invece di duplicare quel meccanismo.
- **Punto d'ingresso UI**: nuova voce "Prepara un disco nuovo" in `SettingsSheet`, separata dalle `LocationRow` esistenti (non le modifica).

### Segnalazioni azionabili in Revisione

`ToolsSheet`, sezione Revisione (`ReviewFinding` da `checkBookmarkRoots`/`checkRcloneConfPermissions`/ecc., roadmap #20): oggi ogni riga è solo testo con ✅/❌. Per i finding che hanno una correzione nota e sicura (oggi: solo "Bookmark non sulla root", che si corregge riselezionando la cartella giusta), aggiungere un bottone "Correggi" che richiama lo stesso `BookmarkManager.selectAndSave(loc)` già usato da `LocationRow` — nessuna nuova logica di correzione, solo un aggancio UI in più al meccanismo esistente. I finding senza una correzione automatica sicura (es. "Endpoint S3" con errore di rete, "Deep mirror mai eseguito" che richiede l'HDD collegato) restano solo informativi come oggi — non forzare un bottone dove non c'è un'azione sicura a un click.

## Fuori scope (deciso esplicitamente)

- Nessuna modifica a `FileSyncer`/`S3Syncer`/regole zero-delete-zero-overwrite — questa feature tocca solo dischi *non ancora* usati come destinazione, mai quelli già in produzione.
- Nessuna guida "anti-idiota" per il primo passo del Setup stesso (`SetupView`) — quello resta invariato, già abbastanza semplice (3 righe, un bottone ciascuna). Il problema era la fase *successiva* al primo setup, non il primo setup in sé.
- Nessun supporto a formattazione di partizioni multiple su un disco — l'app opera sempre sul disco fisico intero (`eraseDisk`, non `eraseVolume`), coerente con l'uso previsto (un disco dedicato per intero al backup).

## Rischi noti, accettati esplicitamente

- `diskutil eraseDisk` è **irreversibile** — la mitigazione è il vincolo "solo dischi mai configurati" + conferma a digitazione nome, non un undo (che non esiste a livello di sistema).
- Il filtro "disco non configurato" si basa sul path bookmark risolto — se un disco già usato in passato viene scollegato, il suo bookmark smette di risolversi e potrebbe *non* comparire come "già configurato" nel filtro se nel frattempo il bookmark è stato sovrascritto da un altro disco. Rischio giudicato basso (richiede una sequenza di eventi inconsueta) e comunque mitigato dalla conferma a digitazione nome, che mostra sempre nome/dimensione reali del disco prima di formattare.
