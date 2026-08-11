# Badge di Revisione all'avvio (roadmap #20)

Data: 2026-08-11

## Problema

Roadmap #20: "Il pannello Revisione resta solo su richiesta — scelta esplicita in fase di design; renderlo periodico con badge discreto lo trasformerebbe da strumento diagnostico a guardiano silenzioso." Oggi `ReviewEngine` (in `ToolsSheet`, `Window` scene indipendente) espone i suoi controlli solo quando l'utente apre manualmente Tools → Revisione — nessun modo di sapere che c'è un problema (es. bookmark rotto, deep mirror scaduto) senza aprire quel pannello.

## Decisione presa in brainstorming: go/no-go

Stessa domanda di fondo già fatta per #5/#13/#14/#19 (una scelta di design originale messa in discussione): l'utente ha confermato di voler rendere periodico il pannello, ribaltando la scelta iniziale "solo su richiesta". Decisioni di scope, in ordine:

- **Quali controlli**: solo quelli economici e sincroni — `ReviewEngine.runConfigChecks()` (bookmark/permessi rclone.conf/endpoint S3) e `checkDeepMirrorFreshness()` (deep mirror SSD→HDD scaduto). Esclusi esplicitamente `runIntegritySample()` (campiona file, scarica da S3, richiede volumi montati) e la scoperta upload multipart orfani (rete S3) — restano solo su richiesta esplicita in Tools, come oggi.
- **Quando**: solo all'avvio dell'app, una volta. Niente timer periodico mentre l'app resta aperta — scartato esplicitamente per tenere l'intervento minimo, coerente con la scelta.
- **Dove**: un pallino rosso discreto sulla voce "Tools" nel menu hamburger, visibile solo aprendo il menu — non sul Dock né sulla menu bar, entrambi già riservati allo stato dei job in corso (roadmap #11/#15), per evitare di confondere "job in corso" con "trovato un problema di configurazione".
- **Nessuna azione automatica**: resta solo segnalazione passiva, coerente con la regola generale del progetto "mai azioni automatiche senza conferma esplicita" — qui non si applica comunque, dato che non c'è nessuna azione correttiva, solo un badge.

## Design tecnico

### 1. Trigger all'avvio

In `RootView` (o dove oggi si chiama `loadS3ConfigIfNeeded()` la prima volta), un nuovo `Task` avviato una tantum in `.task { }` (non `.onAppear`, per evitare ri-esecuzioni su re-render):

```swift
.task {
    await runner.loadS3ConfigIfNeeded()
    let findings = reviewEngine.runConfigChecks(
        s3Config: runner.s3Config,
        s3ConfigFromKeychain: runner.s3ConfigFromKeychain,
        s3ConfigError: runner.s3ConfigError
    )
    let deepMirrorFinding = reviewEngine.checkDeepMirrorFreshness(
        hddConfigured: BookmarkManager.shared.hddURL != nil,
        defaults: .standard,
        now: Date()
    )
    await MainActor.run {
        runner.toolsReviewFindings = findings + (deepMirrorFinding.map { [$0] } ?? [])
    }
}
```

(Le firme esatte di `runConfigChecks`/`checkDeepMirrorFreshness` vanno verificate contro l'implementazione reale in `ContentView.swift` durante il piano — sopra è lo scheletro concettuale, non il codice finale.) Riusa `ReviewEngine` — nessuna nuova istanza necessaria se `RootView` ne ha già accesso, altrimenti una `private let reviewEngine = ReviewEngine()` locale, stesso pattern già usato in `HamburgerPanel`.

`runner.toolsReviewFindings` è lo stesso campo già pubblicato e usato da `ToolsSheet` — aprire Tools manualmente dopo l'avvio continua a ricalcolare tutto (incluso upload orfani) come già fa oggi, sovrascrivendo semplicemente questo stato con un set più completo.

### 2. Badge sulla voce Tools

`HamburgerRow` guadagna un nuovo parametro opzionale:

```swift
struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    var alert: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    // ... invariato
                Text(label)
                    // ... invariato
                Spacer()
                if alert {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        // ... invariato
                }
                Image(systemName: "chevron.right")
                    // ... invariato
            }
            // ... invariato
        }
        .buttonStyle(.plain)
    }
}
```

Il call site della voce "Tools" in `HamburgerPanel` passa `alert: !runner.toolsReviewFindings.isEmpty`. Nessun altro call site di `HamburgerRow` cambia (default `false`, nessun impatto visivo altrove).

### 3. Nessun nuovo stato pubblicato

Non serve un nuovo `@Published` — `toolsReviewFindings` esiste già su `BackupRunner`. Il badge è puramente derivato (`!isEmpty`), calcolato nel `body` di `HamburgerPanel` dove il campo è già letto.

## Testing

Nessun nuovo XCTest sensato: il trigger è legato al ciclo di vita della view (`.task` su `RootView`) e il rendering è puramente dichiarativo — stesso ragionamento già applicato a #11 (menu bar) e #15 (badge Dock), nessuna logica di business nuova isolabile (`runConfigChecks`/`checkDeepMirrorFreshness` sono già testate). Suite esistente (79 test) va comunque rieseguita per assicurarsi che il nuovo `.task` non introduca regressioni.

**Verifica manuale richiesta dopo l'implementazione** (non eseguibile in ambiente headless): aprire l'app con un problema di configurazione noto (es. `rclone.conf` con permessi troppo aperti, o deep mirror non eseguito da >45 giorni) e verificare che il pallino compaia sulla voce Tools aprendo il menu hamburger; verificare che sparisca al riavvio successivo se il problema è stato risolto nel frattempo.

## Fuori scope

- Nessun timer periodico mentre l'app resta aperta — solo un controllo all'avvio.
- Campione di integrità (`runIntegritySample`) e scoperta upload multipart orfani restano manuali, non contribuiscono al badge.
- Nessuna notifica di sistema — solo il pallino nel menu hamburger.
- Nessuna azione correttiva automatica.
