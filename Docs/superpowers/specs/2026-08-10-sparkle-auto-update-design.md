# Auto-update con Sparkle

Data: 2026-08-10

## Problema

Roadmap #18: "Nessun auto-update — ogni build richiede Archive→Distribute→Copy a mano." Sparkle è lo standard open-source per macOS, con verifica di firma EdDSA integrata.

## Vincolo guida (posto dall'utente il 2026-08-10)

L'obiettivo finale del progetto è poter distribuire l'app fuori da questo Mac in futuro. Il meccanismo di update va quindi progettato per reggere anche dopo un eventuale passaggio a notarization/Developer ID (roadmap #19, non ancora fatta) — non solo per l'uso locale attuale. Questo design rispetta il vincolo isolando la differenza "ad-hoc oggi / Developer ID domani" al solo metodo di export nello script di release (vedi sotto): l'architettura Sparkle/EdDSA/GitHub resta identica in entrambi i casi.

## Decisioni prese in brainstorming (go/no-go)

- **Farlo ora**, non rimandare — anche con un solo utente reale oggi, l'utente preferisce avere il meccanismo pronto e rodato prima della distribuzione futura.
- **Dipendenza esterna accettata**: Sparkle via Swift Package Manager — prima dipendenza esterna del progetto (finora zero dipendenze).
- **Hosting**: GitHub Releases, repo pubblico (necessario: le Releases private richiederebbero autenticazione, incompatibile con le richieste HTTP semplici di Sparkle). L'utente non ha ancora un account GitHub — lo crea lui e passa lo username; nel frattempo questo design usa un placeholder (`<github-username>`) ovunque serva l'URL reale.
- **Automazione check**: automatico in background (1 volta/giorno), ma l'installazione richiede sempre un click esplicito dell'utente sull'alert standard di Sparkle — mai silenzioso, coerente con "mai azioni automatiche su dati/stato dell'app senza conferma esplicita" già seguito altrove nel progetto (es. Keychain, pulizia multipart orfani).
- **Processo di release**: script (`Script/release.sh`), non passaggi manuali — build, firma, upload e aggiornamento appcast in un comando solo.
- **Backup della chiave privata EdDSA**: passo esplicito e documentato (aggiunto dopo revisione del design con l'utente) — vedi sezione dedicata.

## Design tecnico

### 1. Dipendenza Sparkle

Aggiunta come Swift Package (Xcode → File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle`, ultima versione 2.x stabile). L'app non è sandboxata (`ENABLE_APP_SANDBOX = NO`) — integrazione standard, nessun servizio XPC separato da configurare (necessario solo per app sandboxate).

### 2. Generazione e gestione della chiave EdDSA

Una tantum, con il tool CLI incluso nel package Sparkle (`bin/generate_keys` dopo aver risolto le dipendenze SPM):

```
generate_keys
```

Questo salva la chiave privata nel Keychain di questo Mac (voce "Private key for signing Sparkle updates") e stampa la chiave pubblica da incollare in `Info.plist` (`SUPublicEDKey`) — pubblica per definizione, va committata in git senza problemi.

**Backup esplicito della chiave privata (passo obbligatorio, non opzionale)**: subito dopo la generazione, esportarla con:

```
generate_keys -x eddsa-private-key-backup.txt
```

Il file va trattato come le altre credenziali del progetto (stesso principio già applicato a `rclone.conf`/Keychain S3): **mai in git** (aggiungere `eddsa-private-key-backup.txt` a `.gitignore` accanto a `Script/*.csv`), copiato invece in un posto sicuro fuori dal repo scelto dall'utente (es. password manager, backup cifrato). Motivazione: se questo Mac viene perso o formattato senza backup, tutte le copie dell'app già distribuite smetterebbero di potersi fidare di aggiornamenti futuri (firmati con una chiave diversa) — nessun modo di recuperare, coerente in gravità con le altre regole "zero perdita" del progetto anche se qui il dato a rischio è la chiave, non le foto.

### 3. Integrazione nell'app

In `BackupFotoEnricoApp` (`ContentView.swift`), un nuovo `@StateObject` per il controller Sparkle, accanto a `runner`:

```swift
import Sparkle

@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(runner)
                .environmentObject(updaterController)
                .frame(minWidth: 960, minHeight: 620)
        }
        // ... resto invariato (Window "tools", MenuBarExtra)
    }
}
```

`SPUStandardUpdaterController` con `startingUpdater: true` avvia da solo il ciclo di check automatico appena l'app parte — nessun codice nostro deve orchestrarlo. L'UI di "trovata una nuova versione" (alert con Installa/Salta questa versione/Ricorda più tardi) è quella standard di Sparkle: nessuna view custom nostra, stesso principio di minimalismo già seguito per #11/#15/#16.

### 4. Check manuale on-demand

Nuova voce in `HamburgerPanel` (accanto a Report Log, Ripristina, Configurazione, Tools, Aspetto, Lingua):

```swift
@EnvironmentObject private var updaterController: SPUStandardUpdaterController
// ...
Button("Controlla aggiornamenti") {
    updaterController.checkForUpdates(nil)
}
```

### 5. Configurazione Info.plist

| Chiave | Valore |
| :---- | :---- |
| `SUFeedURL` | `https://raw.githubusercontent.com/<github-username>/AppBackupFoto/main/appcast.xml` |
| `SUPublicEDKey` | chiave pubblica generata al passo 2 |
| `SUEnableAutomaticChecks` | `YES` |
| `SUScheduledCheckInterval` | `86400` (1 giorno) |

`<github-username>` è un placeholder: da sostituire con il valore reale non appena l'utente crea l'account e lo comunica. Finché non è sostituito, il check automatico fallirà silenziosamente (comportamento standard di Sparkle su feed non raggiungibile — nessun crash, nessun alert d'errore invasivo) senza bloccare l'uso dell'app.

### 6. Hosting: repo pubblico + GitHub Releases

- Repo pubblico `AppBackupFoto` su GitHub (da creare dall'utente — passo manuale, non automatizzabile da qui).
- `appcast.xml` vive nella root del repo, sul branch `main` — letto dall'app via URL raw stabile (`raw.githubusercontent.com/.../main/appcast.xml`), nessun bisogno di GitHub Pages o hosting separato.
- Ogni release: uno zip firmato dell'app come asset di una GitHub Release (`gh release create`), taggata con la versione (es. `v1.1.0`).

### 7. Script di release (`Script/release.sh`)

Input: numero di versione (es. `1.1.0`). Passi:

1. Bump `MARKETING_VERSION` (e `CURRENT_PROJECT_VERSION`, incrementale) nel progetto Xcode.
2. `xcodebuild archive` → `xcodebuild -exportArchive` con lo stesso metodo di export ad-hoc già usato oggi manualmente (`Distribute → Custom → Copy App`, replicato da riga di comando). **Unico punto che cambierà con #19**: se in futuro arriva Developer ID, qui si passerà al metodo `developer-id` — nessun'altra parte dello script o dell'app cambia.
3. Zip dell'app esportata.
4. Firma dello zip con il tool CLI Sparkle `sign_update` (legge la chiave privata dal Keychain, nessun parametro segreto sulla riga di comando).
5. `gh release create v<versione> <zip> --title ... --notes ...` (richiede `gh` autenticato, già presente nell'ambiente).
6. Rigenera `appcast.xml` con il tool CLI Sparkle `generate_appcast` (scansiona gli zip firmati, produce/aggiorna il feed).
7. Commit + push di `appcast.xml` su `main`.

Lo script assume che il repo GitHub esista già — la primissima esecuzione reale richiede che l'utente abbia completato la creazione dell'account/repo.

### 8. `.gitignore`

Aggiunta una riga:

```
eddsa-private-key-backup.txt
```

(oltre a quanto già escluso: `Log/`, `Script/*.log`, `Script/*.csv`).

## Testing

Nessun XCTest sensato per l'integrazione Sparkle in sé (dipende da rete, GitHub, UI di sistema, Keychain) — stesso ragionamento già applicato a #11 (menu bar) e #15 (badge Dock), nessuna nuova logica di business isolabile.

**Verifica manuale richiesta dopo l'implementazione** (non eseguibile in ambiente headless):
- Voce "Controlla aggiornamenti" in `HamburgerPanel` apre l'alert standard di Sparkle (anche se non trova nulla di nuovo, con lo stesso numero di versione).
- Dopo la prima release reale pubblicata (richiede repo GitHub esistente + `appcast.xml` valido raggiungibile), verificare che una build precedente installata trovi, scarichi e installi correttamente la nuova versione, con la firma EdDSA verificata (Sparkle rifiuta update non firmati correttamente — utile testare anche il caso di firma mancante/errata per confermare che il rifiuto funzioni).
- Verificare che il check automatico in background non produca alcun popup/interruzione quando non c'è nulla di nuovo.

## Fuori scope

- Canali beta/stable separati — un solo canale, un solo appcast.
- UI changelog/release notes custom — si usa il campo note standard di Sparkle/GitHub Release.
- Notarization/Developer ID (roadmap #19) — resta un punto separato; questo design è scritto per non richiedere modifiche architetturali quando #19 verrà fatto, solo il cambio del metodo di export nello script di release (vedi punto 7.2).
- Creazione dell'account/repo GitHub — passo manuale dell'utente, fuori dallo scope implementabile da qui.
