# Firma stabile con certificato Apple Development esistente — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sostituire la firma ad-hoc del target app con il certificato "Apple Development" già esistente e valido nel Keychain, per rendere l'identità di firma stabile tra una ricompilazione e l'altra ed eliminare i prompt Keychain ripetuti.

**Architecture:** Un solo cambio di configurazione (`project.pbxproj`), nessun nuovo certificato da generare. Segue la pulizia della voce Keychain esistente (creata sotto la vecchia identità, va lasciata ricreare) e una nota di documentazione sul passo manuale di Full Disk Access che solo Enrico può eseguire.

**Tech Stack:** Xcode build settings, `security` CLI. Nessun codice Swift toccato.

## Global Constraints

- Nessun nuovo certificato da creare — riusa `Apple Development: enrico.nannivicenzi@icloud.com (CTYG776ZL6)`, già presente e valido (verificato con `security find-identity -v -p codesigning`).
- Nessun cambio a `ENABLE_HARDENED_RUNTIME` (resta `NO`, mitigazione BUG-4 invariata).
- Nessun cambio a `Script/release.sh` — eredita automaticamente la nuova configurazione di firma dal progetto Xcode.
- Nessun cambio al target `AppBackupFotoTests` — non ha mai avuto la forzatura ad-hoc.
- Ogni task che tocca `project.pbxproj` termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi) prima del commit.

---

### Task 1: Rimuovere la forzatura di firma ad-hoc

**Files:**
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (2 occorrenze di `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";`, target app, Debug e Release — righe 478 e 510 al momento della scrittura di questo piano)

**Interfaces:**
- Consumes: nessuna.
- Produces: build firmate con l'identità stabile `Apple Development: enrico.nannivicenzi@icloud.com`, usata dai task successivi.

- [ ] **Step 1: Verifica il certificato disponibile e le righe da rimuovere**

```bash
security find-identity -v -p codesigning
grep -n "CODE_SIGN_IDENTITY" AppBackupFoto.xcodeproj/project.pbxproj
```

Atteso: 1 identità valida (`Apple Development: enrico.nannivicenzi@icloud.com`), e 2 righe `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";`. Se l'identità non risulta più presente o valida, fermati e segnala — questo piano assume che esista già.

- [ ] **Step 2: Rimuovi le 2 righe**

In ciascuna delle 2 occorrenze, elimina la riga:
```
				"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
```
(l'intera riga, incluso il punto e virgola finale — non lasciare una riga vuota al suo posto, elimina la riga stessa). Non toccare `CODE_SIGN_STYLE = Automatic;` né `DEVELOPMENT_TEAM = 653B4PS24A;` nelle stesse sezioni, restano invariate.

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Cerca nell'output (o con `codesign -dv` sul binario risultante) conferma che la firma non sia più ad-hoc:
```bash
codesign -dv "$(find ~/Library/Developer/Xcode/DerivedData -iname 'AppBackupFoto.app' -maxdepth 6 -newer AppBackupFoto.xcodeproj/project.pbxproj | head -1)" 2>&1 | grep -i "Authority\|Signature"
```
Expected: una riga `Authority=Apple Development: enrico.nannivicenzi@icloud.com (CTYG776ZL6)` (o simile, non più `Signature=adhoc`). Se la build fallisce chiedendo un provisioning profile o un errore di firma che questo piano non prevede, fermati e segnala l'errore esatto invece di tentare fix improvvisati.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi (nessuna logica toccata, solo firma).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Use stable Apple Development identity instead of ad-hoc signing

Rimosse le 2 forzature "CODE_SIGN_IDENTITY[sdk=macosx*]" = "-" sul
target app (Debug/Release) — CODE_SIGN_STYLE = Automatic e
DEVELOPMENT_TEAM erano già configurati correttamente, la
forzatura ad-hoc le sovrascriveva. Ora ogni build usa lo stesso
certificato "Apple Development: enrico.nannivicenzi@icloud.com",
stabile tra una ricompilazione e l'altra — elimina i prompt
Keychain ripetuti dovuti al cdhash che cambiava ad ogni build
(residuo di BUG-2, vedi .claude/rules/bug-history.md). Nessun
costo, nessun Developer ID a pagamento (roadmap #19 resta
respinto), Hardened Runtime invariato (NO, mitigazione BUG-4).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Pulire la voce Keychain esistente

**Files:** nessuno (solo comando `security`, nessun file di progetto toccato).

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna — pulizia di stato locale (Keychain), non codice.

**Nota**: la voce Keychain "AppBackupFoto"/"Cubbit" contiene le credenziali S3 reali di Enrico. Cancellarla non perde dati: l'app la ricrea automaticamente al primo utilizzo successivo, leggendo di nuovo da `~/.config/rclone/rclone.conf` (stesso comportamento già documentato per BUG-2, non un'operazione nuova o rischiosa). Non è comunque un'operazione di questo piano su file di progetto — nessun edit, nessun grep di verifica prima di un edit, solo un comando diretto.

- [ ] **Step 1: Cancella la voce Keychain esistente**

```bash
security delete-generic-password -s "AppBackupFoto" -a "Cubbit"
```

Expected: `password has been deleted.` oppure (se la voce non esisteva già, es. primo setup) `SecKeychainItemDelete: The specified item could not be found in the keychain.` — in entrambi i casi il task è completo, nessun errore bloccante.

- [ ] **Step 2: Avvia l'app e verifica che il Keychain si ricrei correttamente**

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -iname 'AppBackupFoto.app' -maxdepth 6 | head -1)"
```

Apri la voce Tools/Diagnostica dall'app (manualmente o via automazione se preferisci) per innescare una lettura della config S3 — questo dovrebbe far comparire UN SOLO prompt Keychain (l'ultima volta, per ricreare la voce sotto la nuova identità). Conferma il prompt quando compare. Poi chiudi l'app:

```bash
osascript -e 'tell application "AppBackupFoto" to quit'
```

Se il prompt non compare affatto o compare più di una volta in sequenza, non è necessariamente un errore bloccante (dipende da quale funzionalità della UI hai innescato) — annota cosa hai osservato nel riepilogo finale, non serve fermarsi per questo dettaglio.

- [ ] **Step 3: Nessun commit per questo task** (nessun file di progetto modificato — è un'operazione di stato locale, non di codice).

---

### Task 3: Documentare il cambio e il passo manuale residuo

**Files:**
- Modify: `.claude/rules/bug-history.md`

**Interfaces:** nessuna — task di documentazione.

- [ ] **Step 1: Aggiungi una nota alla sezione BUG-2 in `.claude/rules/bug-history.md`**

Trova il paragrafo che inizia con `**BUG-2 (2026-08-08, risolto 2026-08-09)...` e, subito dopo il suo ultimo paragrafo (quello che inizia con `*Nota per il futuro*:`), aggiungi:

```markdown

**Aggiornamento (2026-08-12) — causa radice del residuo cdhash risolta**: il target app usava `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-"` (firma ad-hoc forzata sopra `CODE_SIGN_STYLE = Automatic`/`DEVELOPMENT_TEAM` già configurati), introdotta per errore nello stesso commit che disabilitava `ENABLE_APP_SANDBOX`. Rimossa: ora ogni build usa il certificato reale già disponibile in Keychain (`Apple Development: enrico.nannivicenzi@icloud.com`, Apple ID personale gratuito, nessun costo) — identità stabile tra una ricompilazione e l'altra, il cdhash non cambia più ad ogni build. La nota "se ricompilando la app la voce Keychain torna a chiedere due volte, ripetere `security delete-generic-password`" sopra resta valida come procedura di emergenza, ma non dovrebbe più essere necessaria di routine durante lo sviluppo attivo. **Passo manuale residuo per Enrico** (non automatizzabile da terminale): dopo questo cambio, Full Disk Access in System Settings → Privacy & Security potrebbe richiedere di essere ri-concesso una volta (rimuovere la vecchia voce "AppBackupFoto" se presente/non funzionante, ri-aggiungerla) — la nuova identità di firma è diversa da quella ad-hoc precedente agli occhi di TCC. Verifica end-to-end di un self-update Sparkle reale con la nuova firma ancora da fare (non bloccante, vedi `Docs/superpowers/specs/2026-08-12-stable-code-signing-design.md`).
```

- [ ] **Step 2: Commit**

```bash
git add .claude/rules/bug-history.md
git commit -m "$(cat <<'EOF'
docs: documenta il fix della causa radice del residuo BUG-2

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
