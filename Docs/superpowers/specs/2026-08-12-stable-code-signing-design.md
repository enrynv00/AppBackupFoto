# Firma stabile con certificato Apple Development esistente

Data: 2026-08-12

## Problema

L'app è firmata ad-hoc (`"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-"`, solo sul target app, sia Debug sia Release) — ogni ricompilazione cambia il cdhash del binario, e macOS tratta ogni build come un'app "diversa" ai fini di Keychain/TCC. Effetto pratico: ogni volta che l'app viene ricompilata, macOS richiede di nuovo l'accesso al Keychain (voce "AppBackupFoto", credenziali Cubbit S3), invece di ricordare "Consenti sempre" come farebbe per un'identità stabile. Comportamento già in parte documentato come residuo di BUG-2 in `.claude/rules/bug-history.md` ("se ricompilando la app la voce Keychain torna a chiedere due volte... è di nuovo il disallineamento cdhash/build"). Durante le sessioni di sviluppo con ricompilazioni frequenti (come la Fase 1/2 del restyling), il problema diventa fastidioso: Enrico si è ritrovato a dover confermare il prompt del Keychain ripetutamente nella stessa sessione.

## Decisione presa in brainstorming

- **Niente Developer ID a pagamento** ($99/anno, roadmap #19) — decisione già presa e confermata, non riproposta.
- **Niente certificato self-signed creato da zero**: verificato con `security find-identity -v -p codesigning` che esiste già un certificato valido e utilizzabile — `Apple Development: enrico.nannivicenzi@icloud.com (CTYG776ZL6)`, legato all'Apple ID personale gratuito di Enrico. Il progetto ha già `DEVELOPMENT_TEAM = 653B4PS24A` configurato (stesso team dell'Apple ID) e `CODE_SIGN_STYLE = Automatic` — ma 2 righe esplicite forzano comunque la firma ad-hoc sopra questa configurazione. La causa è storica: introdotte nello stesso commit che disabilitava `ENABLE_APP_SANDBOX` (probabilmente per evitare la gestione di provisioning profile quando il Sandbox venne disattivato), non una scelta deliberata contro l'uso del certificato reale.
- **Scope**: stessa identità per build di sviluppo (Debug, xcodebuild/Xcode) e build di release ufficiali (Release, pubblicate via `Script/release.sh`) — un solo cambio di configurazione copre entrambe, dato che lo script di release non referenzia la firma direttamente (verificato: nessuna occorrenza di `codesign`/`CODE_SIGN`/`identity` in `Script/release.sh`), eredita le impostazioni del progetto Xcode.
- **Nessun cambio a `ENABLE_HARDENED_RUNTIME`** (resta `NO`) — la mitigazione di BUG-4 (Sparkle self-update rotto da Hardened Runtime + firma instabile) non viene toccata, sono impostazioni indipendenti.
- **Nessuna notarization, nessun cambio alla distribuzione pubblica/Gatekeeper** — l'obiettivo è solo stabilità locale della firma per Keychain/TCC, non l'iter di notarization completo.

## Design tecnico

### 1. Rimuovere la forzatura ad-hoc

In `AppBackupFoto.xcodeproj/project.pbxproj`, rimuovere le 2 occorrenze di:
```
"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
```
(una nella configurazione Debug del target app, una nella Release — righe 478 e 510 al momento della scrittura di questa spec, verificate con `grep -n "CODE_SIGN_IDENTITY"`). Nessun'altra riga va toccata: `CODE_SIGN_STYLE = Automatic` e `DEVELOPMENT_TEAM = 653B4PS24A` restano come sono, sono già corretti e puntano al certificato giusto. Il target `AppBackupFotoTests` non ha mai avuto questa forzatura (verificato) — nessun cambio necessario lì.

Dopo la rimozione, una build (`xcodebuild build` o Xcode) dovrebbe firmare automaticamente con `Apple Development: enrico.nannivicenzi@icloud.com` invece di ad-hoc, senza bisogno di generare un nuovo certificato (già presente in Keychain) né di interazione con Xcode GUI per il provisioning (nessun App Sandbox, nessuna capability che richieda un profilo scaricato da Apple).

### 2. Pulizia della voce Keychain esistente

La voce Keychain "AppBackupFoto" (credenziali Cubbit S3, servizio `AppBackupFoto`, account `Cubbit`) è stata creata sotto l'ACL della vecchia identità ad-hoc — va cancellata una volta per lasciarla ricreare pulita sotto la nuova identità stabile, stessa mitigazione già documentata per BUG-2:
```bash
security delete-generic-password -s "AppBackupFoto" -a "Cubbit"
```
Dopo questo comando, il primo avvio dell'app successivo al cambio di firma richiederà un'ultima volta il consenso Keychain (per ricreare la voce sotto la nuova identità) — da quel momento in poi, restando la firma stabile, non dovrebbe più chiederlo ad ogni ricompilazione.

### 3. Full Disk Access da ri-concedere

La nuova identità di firma è diversa da quella ad-hoc precedente agli occhi di TCC (Transparency, Consent, and Control) — è probabile che il grant esistente di Full Disk Access in System Settings → Privacy & Security → Full Disk Access smetta di applicarsi. Questo è un passo manuale che **solo Enrico può fare** (richiede interazione GUI in System Settings, nessun modo per automatizzarlo da terminale): rimuovere la vecchia voce "AppBackupFoto" dalla lista (se presente e non più funzionante) e ri-aggiungerla — stesso passo già documentato in `Docs/CLAUDE.md` sotto "Build e distribuzione" per il caso di reinstallazione.

### 4. Verifica end-to-end di Sparkle self-update

Non modifichiamo Hardened Runtime, quindi il fix di BUG-4 non è a rischio in teoria — ma BUG-4 stesso è stato scoperto con un self-update reale, non ipotizzato dal codice. Dopo il cambio, va rifatto un test reale di self-update (pubblicare una release di verifica con `Script/release.sh`, installare la versione precedente, lasciare che si aggiorni da sola) per confermare che non riemerga un problema simile con la nuova identità di firma. Non bloccante per il merge del cambio di firma in sé, ma da fare prima di considerare il cambio completamente verificato.

## Testing

Nessuna nuova logica di business — solo configurazione di build. Nessun nuovo XCTest sensato. Build e suite esistente (79 test) vanno comunque verificati dopo il cambio, per assicurarsi che la build firmata diversamente non rompa nulla (es. problemi di code signing che impediscono l'esecuzione dei test).

**Verifica manuale richiesta** (non automatizzabile, richiede Enrico):
- Dopo il cambio, riavviare l'app una prima volta e confermare l'eventuale prompt Keychain (atteso, una tantum).
- Ricompilare almeno una seconda volta e verificare che il Keychain **non** richieda di nuovo il consenso (questo è il vero criterio di successo del cambio).
- Ri-concedere Full Disk Access se necessario (System Settings).
- Verifica end-to-end di un self-update Sparkle reale (vedi punto 4 sopra) — può essere fatta in un momento successivo, non blocca la chiusura di questo intervento.

## Fuori scope

- Nessuna notarization, nessun Developer ID a pagamento (roadmap #19, già deciso contro).
- Nessun cambio a `ENABLE_HARDENED_RUNTIME`.
- Nessun cambio a `Script/release.sh` (eredita automaticamente la nuova configurazione di firma, nessuna riga da toccare lì).
- Nessun cambio al target `AppBackupFotoTests` (mai stato ad-hoc).
- Nessuna migrazione di credenziali diversa da quella già prevista (cancellazione + ricreazione automatica della voce Keychain esistente).
