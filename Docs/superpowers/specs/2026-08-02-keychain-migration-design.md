# Migrazione credenziali S3 al Keychain

Data: 2026-08-02
Stato: approvato per implementazione

## Contesto

`Docs/ROADMAP.md`, punto alto #10: le credenziali S3 (Cubbit) vivono oggi in `~/.config/rclone/rclone.conf`, testo in chiaro protetto solo da permessi POSIX 0600. Il Keychain di macOS è pensato esattamente per questo caso d'uso. Approfondito nel briefing `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md` (sezione 5) e discusso con l'utente.

`S3Syncer.readConfig(remoteName:bucket:) throws -> S3Config` (`AppBackupFoto/ContentView.swift:547`) è oggi l'unico punto che legge le credenziali: funzione static, ~8 call site (BackupRunner, ReviewEngine, ToolsSheet). Legge il file, valida permessi (rifiuta se più aperti di 0600), parsa la sezione `[Cubbit]`, valida che l'endpoint sia HTTPS e in una allow-list host (solo `s3.it.cubbit.org`).

## Decisioni (dall'utente, in fase di brainstorming)

1. **Nessun form di inserimento credenziali nell'app.** L'utente continua a modificare `rclone.conf` a mano (flusso attuale, bottone "Apri rclone.conf in TextEdit" già esistente in `ToolsSheet`). L'app adotta automaticamente il contenuto del file nel Keychain alla prima lettura utile dopo l'aggiornamento — nessuna migrazione forzata, nessuna nuova superficie UI per inserire chiavi lunghe a mano.
2. **Nessun rilevamento automatico di modifiche a rclone.conf.** Una volta adottate nel Keychain, le credenziali diventano la fonte di verità: l'app non guarda più il file automaticamente. Se l'utente modifica ancora `rclone.conf` in futuro, deve premere un bottone esplicito "Aggiorna da rclone.conf" in Tools per far sì che il Keychain venga sovrascritto — coerente con la regola del progetto di non fare mai azioni automatiche/silenziose su dati sensibili (stessa logica già applicata a zero-delete e alla pulizia multipart orfani).

## Scope

Dentro scope:
- Wrapper Keychain minimale in `S3Syncer` (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`, framework Security, nessuna dipendenza esterna).
- `readConfig()` riscritta: prova il Keychain, fallback a `rclone.conf` con adozione silenziosa best-effort.
- Estrazione di `validateEndpoint(_:)` (HTTPS + allow-list) come funzione pura condivisa e testabile — oggi duplicata implicitamente nell'unico percorso file, va isolata per essere riusata anche dal percorso Keychain.
- Bottone "Aggiorna da rclone.conf" in `ToolsSheet`, con conferma esplicita prima di sovrascrivere.
- Aggiornamento di `ReviewEngine.checkRcloneConfPermissions()`: se le credenziali sono già nel Keychain, il controllo permessi sul file non è più rilevante.
- Etichetta "Origine: Keychain" / "Origine: rclone.conf" nella diagnostica esistente di `ToolsSheet`.
- Nuovi test per `validateEndpoint` (nessuna copertura oggi, logica di sicurezza critica).

Fuori scope (esplicitamente, per questa iterazione):
- Form di inserimento credenziali nell'app — deciso esplicitamente fuori scope.
- Rilevamento automatico di modifiche a `rclone.conf` — deciso esplicitamente fuori scope.
- Test automatici che toccano il Keychain reale — rischio di prompt interattivi durante `xcodebuild test`, stesso limite già accettato per rete/filesystem reali in questo progetto.
- Migrazione di altre credenziali (non ce ne sono altre nel progetto).

## Architettura

Tutto in `AppBackupFoto/ContentView.swift`, dentro `S3Syncer`.

### Wrapper Keychain

```swift
private struct KeychainCredentials: Codable {
    let accessKeyId: String
    let secretAccessKey: String
    let endpoint: String
    let region: String
}

private static func keychainQuery(remoteName: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "AppBackupFoto",
     kSecAttrAccount as String: remoteName]
}

static func hasKeychainCredentials(remoteName: String = "Cubbit") -> Bool {
    readFromKeychain(remoteName: remoteName) != nil
}

private static func readFromKeychain(remoteName: String) -> KeychainCredentials? {
    var query = keychainQuery(remoteName: remoteName)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return try? JSONDecoder().decode(KeychainCredentials.self, from: data)
}

// internal (non private): richiamata anche dal bottone "Aggiorna da rclone.conf" in ToolsSheet.
static func writeToKeychain(config: S3Config, remoteName: String) throws {
    let creds = KeychainCredentials(accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey,
                                     endpoint: config.endpoint, region: config.region)
    let data = try JSONEncoder().encode(creds)
    let query = keychainQuery(remoteName: remoteName)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "S3", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile salvare le credenziali nel Keychain"])
        }
    } else if updateStatus != errSecSuccess {
        throw NSError(domain: "S3", code: 15,
            userInfo: [NSLocalizedDescriptionKey: "Impossibile aggiornare le credenziali nel Keychain"])
    }
}
```

`kSecAttrService` fisso `"AppBackupFoto"`, `kSecAttrAccount` = `remoteName` (oggi sempre `"Cubbit"`, ma la funzione resta generica come il resto di `S3Syncer`). `writeToKeychain` prende direttamente un `S3Config` (non un `KeychainCredentials` separato) perché tutti i chiamanti — l'adozione automatica in `readConfig()` e il bottone "Aggiorna da rclone.conf" — hanno già un `S3Config` in mano.

### `readConfig()` — Keychain prima, poi file con adozione silenziosa

```swift
static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
    if let creds = readFromKeychain(remoteName: remoteName) {
        let cleanEp = try validateEndpoint(creds.endpoint)
        return S3Config(accessKeyId: creds.accessKeyId, secretAccessKey: creds.secretAccessKey,
                        endpoint: cleanEp, region: creds.region, bucket: bucket)
    }
    let config = try readConfigFromFile(remoteName: remoteName, bucket: bucket)
    try? writeToKeychain(config: config, remoteName: remoteName)
    return config
}
```

`readConfigFromFile(remoteName:bucket:)` (anch'essa `internal`, non `private`, per lo stesso motivo — richiamata anche dal bottone) è il corpo esatto dell'attuale `readConfig()` (lettura permessi, parsing sezione, controllo `access_key_id`/`secret_access_key`/`endpoint`), con la validazione HTTPS/allow-list estratta in:

```swift
private static func validateEndpoint(_ raw: String) throws -> String {
    let cleanEp = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    guard cleanEp.hasPrefix("https://") else {
        throw NSError(domain: "S3", code: 10, userInfo: [NSLocalizedDescriptionKey:
            "L'endpoint S3 deve usare HTTPS. Valore trovato: '\(cleanEp)'."])
    }
    let allowedHosts: Set<String> = ["s3.it.cubbit.org"]
    guard let host = URL(string: cleanEp)?.host, allowedHosts.contains(host) else {
        throw NSError(domain: "S3", code: 13, userInfo: [NSLocalizedDescriptionKey:
            "Endpoint S3 non riconosciuto: '\(cleanEp)'. Se hai cambiato provider di proposito, aggiorna la allow-list in S3Syncer.validateEndpoint."])
    }
    return cleanEp
}
```

Stessi codici errore (10, 13) e stessi messaggi di oggi — solo spostati in una funzione condivisa, nessun cambiamento di comportamento per il percorso file. L'adozione (`try? writeToKeychain(...)`) è **best-effort**: se fallisce (es. Keychain temporaneamente bloccato), l'app continua comunque a funzionare leggendo il file, e ritenta l'adozione alla chiamata successiva — nessuna regressione rispetto al comportamento di oggi.

### Bottone "Aggiorna da rclone.conf" — `ToolsSheet`

Nella `GroupBox("S3 — Cubbit")`, accanto al bottone "Apri rclone.conf in TextEdit" già esistente:

```swift
Button("Aggiorna da rclone.conf") {
    let a = NSAlert()
    a.messageText = "Sovrascrivere le credenziali salvate?"
    a.informativeText = "Le credenziali attualmente nel Keychain verranno sostituite con quelle lette ora da rclone.conf."
    a.alertStyle = .warning
    a.addButton(withTitle: "Continua")
    a.addButton(withTitle: "Annulla")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    do {
        let config = try S3Syncer.readConfigFromFile(remoteName: "Cubbit", bucket: "backupfoto")
        try S3Syncer.writeToKeychain(config: config, remoteName: "Cubbit")
        let ok = NSAlert(); ok.messageText = "Credenziali aggiornate nel Keychain."; ok.runModal()
    } catch {
        let err = NSAlert(); err.messageText = "Errore"; err.informativeText = error.localizedDescription
        err.alertStyle = .critical; err.runModal()
    }
}.buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
```

### `ReviewEngine.checkRcloneConfPermissions()` — aggiornato

```swift
private func checkRcloneConfPermissions() -> ReviewFinding {
    if S3Syncer.hasKeychainCredentials(remoteName: "Cubbit") {
        return ReviewFinding(title: "Credenziali S3", ok: true,
            detail: "Salvate nel Keychain — rclone.conf non è più necessario")
    }
    // ...corpo attuale invariato (controllo permessi 0600 sul file)...
}
```

### Diagnostica — etichetta origine

Nella stessa `GroupBox("S3 — Cubbit")` di `ToolsSheet`, sopra le righe esistenti:

```swift
Text(S3Syncer.hasKeychainCredentials() ? "Origine: Keychain" : "Origine: rclone.conf")
    .font(.caption2).foregroundStyle(.secondary)
```

## Gestione errori

- Lettura Keychain fallita/vuota → fallback trasparente al file, stesso errore di oggi se anche il file manca (`"Credenziali 'Cubbit' non trovate in rclone.conf"`).
- Scrittura Keychain fallita durante l'adozione automatica → ignorata (`try?`), non blocca l'uso dell'app.
- Scrittura Keychain fallita durante "Aggiorna da rclone.conf" (azione esplicita) → `NSAlert` con l'errore, Keychain non toccato se lo status non è `errSecSuccess`.

## Testing

- **`validateEndpoint`**: nuovi test automatici (nessuna I/O) — endpoint HTTP (rifiutato), endpoint HTTPS su host non in allow-list (rifiutato), endpoint HTTPS su `s3.it.cubbit.org` con e senza slash finale (accettato, slash rimosso).
- **Keychain reale (lettura/scrittura/adozione)**: verifica manuale, stesso limite già accettato per rete/filesystem reali in questo progetto. Nessun test automatico tocca il Keychain vero, per evitare prompt interattivi durante `xcodebuild test`.
- Verifica manuale suggerita: primo avvio dopo l'aggiornamento con `rclone.conf` esistente → controllare in Tools che "Origine" passi a "Keychain"; poi rinominare temporaneamente `rclone.conf` e confermare che l'app continui a funzionare (legge dal Keychain); poi provare "Aggiorna da rclone.conf" con un valore modificato nel file e confermare che il Keychain rifletta il cambiamento.

## Domande aperte per l'implementazione

Nessuna bloccante.
