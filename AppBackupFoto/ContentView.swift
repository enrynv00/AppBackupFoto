import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import SQLite3
import CryptoKit
import Charts
import ImageIO
import Sparkle
import LocalAuthentication
import WebKit

// MARK: - Design Tokens

/// Palette semantica: ogni colore ha un solo significato in tutta l'app.
/// Stato (successo/errore/warning/in corso) e identità di destinazione (Mac→SSD/SSD→HDD/SSD→Cubbit)
/// non si sovrappongono mai — vedi Docs/superpowers/specs/2026-08-12-design-foundations-design.md.
enum AppColor {
    // Stato
    static let success = Color.green
    static let error = Color.red
    static let warning = Color.orange
    /// Job in corso o conteggio "positivo" generico (es. "Copiati") — usa l'accent di sistema
    /// invece di un colore hardcoded, così segue l'accent scelto dall'utente in Preferenze di Sistema.
    static let inProgress = Color.accentColor

    // Identità destinazione — un hue per destinazione, riusato SOLO per quella destinazione.
    static let macToSSD = Color.blue
    static let ssdToHDD = Color.teal
    static let ssdToCubbit = Color.purple

    // Utility (Tools, Configurazione) — nessuna destinazione, nessuno stato.
    static let utility = Color(NSColor.systemGray)
}

/// Griglia di spacing/padding a 6 valori (base 4pt) + valori del pattern "card".
enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    static let cardCornerRadius: CGFloat = 8
    static let cardOpacity: Double = 0.4
}

/// 5 ruoli di testo con nome — una sola combinazione size/weight per ruolo, riusata ovunque.
enum AppFont {
    static let title = Font.title2.weight(.semibold)
    static let sectionHeader = Font.system(size: 10, weight: .semibold)
    static let body = Font.system(size: 13, weight: .medium)
    static let caption = Font.caption
    static let heroNumber = Font.system(size: 20, weight: .semibold, design: .monospaced)
}

/// 2 taglie per le icone SF Symbols "hero" (grandi, in sheet/empty state).
enum AppIconSize {
    static let heroSmall: CGFloat = 36
    static let heroLarge: CGFloat = 48
}

/// Alert semplice riusato ovunque: cancelTitle nil = solo un bottone (informativo),
/// cancelTitle impostato = conferma a 2 bottoni con onConfirm eseguito sulla scelta primaria.
struct SimpleAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String = ""
    var isDestructive: Bool = false
    var confirmTitle: String = "OK"
    var cancelTitle: String? = nil
    var onConfirm: (() -> Void)? = nil
}

/// Dove far comparire un avviso prodotto dal `BackupRunner`.
///
/// Serve perche' un `SimpleAlert` non e' presentabile da chiunque: `runner.pendingAlert` ha
/// UN SOLO presentatore, il `.alert` di `ContentView`, che vive nella scena
/// `WindowGroup(id: "main")`. Un avviso prodotto da una funzione chiamata dalla finestra
/// "Diagnostica" (scena `Window(id: "tools")`, un'altra scena) finirebbe su un canale che
/// quella finestra non presenta: nessun messaggio a schermo, e se la finestra principale e'
/// chiusa l'avviso salta fuori fuori contesto alla sua riapertura.
///
/// Chi chiama da un'altra finestra passa quindi il proprio canale; chi chiama dalla finestra
/// principale (o da un percorso automatico) non passa niente e resta su `pendingAlert`.
/// L'alternativa — un secondo `.alert(runner.pendingAlert)` dentro `ToolsSheet` — con
/// entrambe le finestre aperte presenterebbe lo stesso avviso due volte.
typealias AlertSink = @MainActor (SimpleAlert) -> Void

/// Sfondo "card" riusato in tutta l'app: stesso corner radius/opacità ovunque.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(AppSpacing.cardOpacity))
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

// MARK: - App entry
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

/// Chiude lo stack Immich prima che l'app termini davvero: non ha senso lasciare acceso
/// un intero stack di container (diversi GB di RAM) con AppBackupFoto chiusa.
///
/// Usa `applicationShouldTerminate` + `.terminateLater` — non `applicationWillTerminate`,
/// che è sincrono e uscirebbe prima che `stop()` abbia finito. C'è comunque una rete di
/// sicurezza: se lo spegnimento si impianta, l'app si chiude lo stesso invece di restare
/// appesa per sempre.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Deve stare sopra la somma dei due timeout di `stop()` (90s + 90s), altrimenti
    /// scatterebbe la rete di sicurezza proprio mentre l'arresto sta ancora lavorando.
    private static let shutdownSafetyNet: TimeInterval = 200

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let immich = ImmichManager.shared

        // Se Immich non è nemmeno installato non si paga nessun ritardo alla chiusura:
        // è il caso di chiunque non usi la finestra Foto.
        guard immich.detectInstalled() else { return .terminateNow }

        // Non ci si fida del solo `isRunning` in memoria (falso dopo un timeout dell'health
        // check su uno stack in realtà partito, e al rilancio dopo un crash/force-quit): si
        // chiede al sistema. Ma `isStarting` va guardato **comunque**, ed è l'unico segnale
        // valido durante `colima start`: lì `detectRunning()` risponde false — la VM non è
        // ancora su — e uscire con `.terminateNow` lascerebbe il processo figlio `colima
        // start` a sopravvivere al padre (su macOS non muore con l'app), finire di accendere
        // la VM e restare acceso senza più nessuno che lo spenga.
        Task {
            await immich.detectRunning()
            let somethingToStop = await MainActor.run { immich.vmPossiblyUp || immich.isStarting }
            if somethingToStop { await immich.stop() }
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownSafetyNet) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BackupFotoEnricoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runner = BackupRunner()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(runner)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 620)
        }
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)
        // Il ripristino automatico delle finestre di macOS riaprirebbe questa scena
        // al rilancio prima dello sblocco: disabilitato come barriera aggiuntiva
        // (il gate vero è dentro ToolsSheet/CatalogView).
        .restorationBehavior(.disabled)

        Window("Catalogo", id: "catalog") {
            CatalogView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("Foto", id: "immich") {
            ImmichView()
                .environmentObject(runner)
        }
        .defaultSize(width: 1000, height: 700)
        // Stessa regola stabilita per #30: ogni nuova Window scene di primo livello va gated
        // (il gate vero è dentro ImmichView) e non deve essere riaperta dal ripristino
        // automatico di macOS prima dello sblocco.
        .restorationBehavior(.disabled)

        Window("Doppioni", id: "duplicates") {
            DuplicatesView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 640)
        // Stessa regola di #30, applicata qui perche' e' la scena piu' sensibile del
        // progetto: elenca percorsi, nomi e miniature di tutte le foto, e puo' spostarle
        // nel Cestino. Il gate vero e' dentro DuplicatesView.
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(runner)
        } label: {
            MenuBarIcon()
                .environmentObject(runner)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
            .onChange(of: runner.stats.percent) { _, _ in updateDockBadge() }
            .onChange(of: runner.isRunning) { _, _ in updateDockBadge() }
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = runner.isRunning ? "\(runner.stats.percent)%" : nil
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var runner: BackupRunner
    @Environment(\.openWindow) private var openWindow
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private var statusText: String {
        if runner.isRunning { return "Backup in corso" }
        if let last = JobHistoryStore.load() {
            return "Ultimo backup: \(dateFormatter.string(from: last.date))"
        }
        return "Nessun backup ancora"
    }

    var body: some View {
        Text(statusText)
        Divider()
        Button("Apri AppBackupFoto") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct CatalogView: View {
    enum CatalogDestination: String, CaseIterable, Identifiable {
        case ssd = "SSD", hdd = "HDD", s3 = "Cubbit S3"
        var id: String { rawValue }
    }
    enum LoadState {
        case idle, loading, loaded([CatalogEntry]), failed(String)
    }

    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var gate = AuthGateManager.shared
    @StateObject private var volumes = VolumeMonitor()
    @State private var destination: CatalogDestination = .ssd
    @State private var searchText = ""
    @State private var loadState: LoadState = .idle
    private let reviewEngine = ReviewEngine()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private func isAvailable(_ d: CatalogDestination) -> Bool {
        switch d {
        case .ssd: return volumes.ssdMounted
        case .hdd: return volumes.hddMounted
        case .s3: return runner.s3Config != nil
        }
    }

    private var filteredEntries: [CatalogEntry] {
        guard case .loaded(let entries) = loadState else { return [] }
        return filterCatalogEntries(entries, matching: searchText)
    }

    /// Gate Touch ID anche qui: "Catalogo" è una scena di primo livello, apribile dal menu
    /// Finestra mentre la finestra principale è ancora bloccata — senza questo controllo
    /// elencherebbe nomi/cartelle/date delle foto senza autenticazione (roadmap #30).
    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Catalogo").font(AppFont.title)

            Picker("Destinazione", selection: $destination) {
                ForEach(CatalogDestination.allCases) { d in
                    Text(isAvailable(d) ? d.rawValue : "\(d.rawValue) (non disponibile)").tag(d)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: destination) { _, _ in loadCurrentDestination() }

            TextField("Cerca per nome o cartella", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Group {
                switch loadState {
                case .idle:
                    Color.clear.onAppear { loadCurrentDestination() }
                case .loading:
                    ProgressView("Sto leggendo \(destination.rawValue)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    Text(message).foregroundStyle(AppColor.error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    if filteredEntries.isEmpty {
                        Text(searchText.isEmpty ? "Nessun file trovato" : "Nessun risultato per \"\(searchText)\"")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(filteredEntries) {
                            TableColumn("Nome") { Text($0.name) }
                            TableColumn("Cartella") { Text($0.relativePath) }
                            TableColumn("Dimensione") { entry in
                                Text(byteFormatter.string(fromByteCount: entry.sizeBytes))
                            }
                            TableColumn("Data") { entry in
                                Text(entry.modified.map { dateFormatter.string(from: $0) } ?? "—")
                            }
                        }
                    }
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(minWidth: 640, minHeight: 480)
    }

    private func loadCurrentDestination() {
        guard isAvailable(destination) else {
            loadState = .failed("\(destination.rawValue) non disponibile al momento")
            return
        }
        loadState = .loading
        let dest = destination
        Task {
            do {
                let entries: [CatalogEntry]
                switch dest {
                case .ssd:
                    guard let url = bm.startAccessing(.ssd) else {
                        throw NSError(domain: "Catalog", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Accesso all'SSD non disponibile"])
                    }
                    defer { bm.stopAccessing(.ssd) }
                    entries = reviewEngine.scanLocalCatalog(rootURL: url)
                case .hdd:
                    guard let url = bm.startAccessing(.hdd) else {
                        throw NSError(domain: "Catalog", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Accesso all'HDD non disponibile"])
                    }
                    defer { bm.stopAccessing(.hdd) }
                    entries = reviewEngine.scanLocalCatalog(rootURL: url)
                case .s3:
                    guard let cfg = runner.s3Config else {
                        throw NSError(domain: "Catalog", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Configurazione Cubbit non disponibile"])
                    }
                    entries = try await S3Syncer().listAllWithDates(config: cfg)
                }
                await MainActor.run {
                    guard dest == destination else { return }
                    loadState = .loaded(entries)
                }
            } catch {
                await MainActor.run {
                    guard dest == destination else { return }
                    loadState = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Immich (finestra "Foto")

/// Finestra "Foto": la web UI di Immich incorporata, con il ciclo di vita dello stack
/// gestito da `ImmichManager`.
///
/// Gate Touch ID anche qui, come per `CatalogView`/`ToolsSheet`: è una scena di primo
/// livello apribile dal menu Finestra mentre la finestra principale è ancora bloccata, e
/// senza gate mostrerebbe l'intera libreria foto senza autenticazione (roadmap #30).
struct ImmichView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    @ObservedObject private var immich = ImmichManager.shared
    @ObservedObject private var bm = BookmarkManager.shared

    /// La libreria da indicizzare è l'SSD già configurato in `BookmarkManager`: nessuna
    /// nuova destinazione, nessun nuovo bookmark (vedi spec).
    private var ssdPath: String? { bm.urls[.ssd]?.path }

    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
                // Riallinea lo stato a com'è davvero il sistema: se i container sono rimasti
                // accesi da una sessione precedente (crash, force-quit) o se lo stack è partito
                // dopo un timeout di `start()`, la finestra mostra Immich invece di offrire un
                // "Avvia" che ripartirebbe su qualcosa di già acceso.
                .task {
                    guard !immich.isStarting else { return }
                    await immich.detectRunning()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !immich.installed {
            ImmichSetupPromptView()
        } else if immich.isStarting {
            ImmichMessageView(
                icon: "hourglass",
                title: "Avvio di Immich…",
                message: "La prima volta richiede diversi minuti: viene avviata una macchina virtuale e scaricate le immagini dei container.",
                showsProgress: true)
        } else if immich.isRunning {
            ImmichWebView(url: ImmichManager.webUIURL)
        } else {
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        if let path = ssdPath {
            ImmichMessageView(
                icon: "photo.on.rectangle.angled",
                title: "Immich è fermo",
                message: "Le foto vengono lette in sola lettura da:\n\(path)",
                error: immich.lastError) {
                    Button("Avvia Immich") {
                        Task { try? await immich.start(sourceLibraryPath: path) }
                    }
                    .buttonStyle(.borderedProminent)
                }
        } else {
            ImmichMessageView(
                icon: "externaldrive.badge.questionmark",
                title: "SSD non configurato",
                message: "Configura prima l'SSD esterno nella schermata iniziale: è la cartella che Immich indicizzerà in sola lettura.")
        }
    }
}

/// Schermata neutra riusata dagli stati non-web della finestra Foto (fermo, in avvio, errore).
struct ImmichMessageView<Actions: View>: View {
    let icon: String
    let title: String
    var message: String = ""
    var error: String? = nil
    var showsProgress: Bool = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: icon)
                .font(.system(size: AppIconSize.heroLarge))
                .foregroundStyle(AppColor.utility)
            Text(title).font(AppFont.title)
            if !message.isEmpty {
                Text(message)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if showsProgress { ProgressView() }
            if let error {
                Text(error)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            actions()
        }
        .padding(AppSpacing.xxl)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

extension ImmichMessageView where Actions == EmptyView {
    init(icon: String, title: String, message: String = "", error: String? = nil, showsProgress: Bool = false) {
        self.init(icon: icon, title: title, message: message, error: error,
                  showsProgress: showsProgress, actions: { EmptyView() })
    }
}

/// Conferma esplicita prima di installare: niente installazioni silenziose, stessa
/// disciplina già seguita per Keychain/rclone.conf. Qui l'utente vede *prima* cosa sta
/// per succedere, quanto spazio serve e quanto ci vorrà.
struct ImmichSetupPromptView: View {
    @ObservedObject private var immich = ImmichManager.shared
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "photo.stack")
                    .font(.system(size: AppIconSize.heroSmall))
                    .foregroundStyle(AppColor.utility)
                Text("Configura Immich").font(AppFont.title)
            }

            Text("Immich è il motore che permette di sfogliare le foto per data, luogo e persone, con ricerca intelligente e riconoscimento dei volti.")
                .font(AppFont.body)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                bullet("arrow.down.circle", "Ora vengono scaricati circa 150 MB di strumenti (Colima, Docker, Lima).")
                bullet("shippingbox", "Al primo avvio vengono scaricate le immagini dei container: diversi GB, può richiedere parecchi minuti.")
                bullet("internaldrive", "Tutto viene salvato sul disco interno del Mac, mai sull'SSD o sull'HDD di backup.")
                bullet("lock.shield", "Le tue foto sull'SSD vengono solo lette, mai modificate o copiate.")
                bullet("wifi.slash", "Il servizio è raggiungibile solo da questo Mac, non dalla rete.")
                bullet("memorychip", "Mentre è acceso occupa parecchia memoria; si spegne da solo quando chiudi l'app.")
            }
            .padding(AppSpacing.md)
            .cardBackground()

            if let error = immich.lastError {
                Text(error)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.error)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                if isInstalling { ProgressView().controlSize(.small) }
                Button(isInstalling ? "Installazione…" : "Installa") {
                    guard !isInstalling else { return }
                    isInstalling = true
                    Task {
                        try? await immich.install()
                        await MainActor.run { isInstalling = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text).font(AppFont.caption).foregroundStyle(.secondary)
        }
    }
}

/// Wrapper minimo attorno a `WKWebView` per mostrare la web UI di Immich.
struct ImmichWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView { WKWebView() }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Solo al primo passaggio: ricaricare a ogni update butterebbe via la navigazione
        // dell'utente dentro Immich a ogni ridisegno della view.
        if webView.url == nil { webView.load(URLRequest(url: url)) }
    }
}

struct RootView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var gate = AuthGateManager.shared
    var body: some View {
        Group {
            if gate.touchIDEnabled && !gate.unlocked { LockScreenView() }
            else if bm.canEnterApp { ContentView() }
            else { SetupView() }
        }
        .onAppear {
            Notifier.requestAuthorization()
            AppearanceManager.shared.apply()
        }
        .alert(bm.pendingAlert?.title ?? "", isPresented: Binding(
            get: { bm.pendingAlert != nil },
            set: { if !$0 { bm.pendingAlert = nil } }
        ), presenting: bm.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}

// MARK: - Notifier
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func send(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - AppearanceManager
final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()
    @Published var mode: String {
        didSet { UserDefaults.standard.set(mode, forKey: "appearanceMode"); apply() }
    }
    private init() { mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "Sistema" }
    func apply() {
        DispatchQueue.main.async {
            switch self.mode {
            case "Chiaro": NSApp.appearance = NSAppearance(named: .aqua)
            case "Scuro":  NSApp.appearance = NSAppearance(named: .darkAqua)
            default:       NSApp.appearance = nil
            }
        }
    }
}

// MARK: - AuthGateManager
final class AuthGateManager: ObservableObject {
    static let shared = AuthGateManager()
    @Published var unlocked: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var lastError: String?

    /// Persistito a mano in UserDefaults (stesso pattern di `AppearanceManager.mode`):
    /// dev'essere `@Published` e non una computed su UserDefaults, altrimenti scriverlo
    /// non emette `objectWillChange` e né il toggle in Impostazioni né `RootView` reagiscono.
    @Published var touchIDEnabled: Bool {
        didSet { UserDefaults.standard.set(touchIDEnabled, forKey: "touchIDEnabled") }
    }

    /// Trattenuto per tutta la durata del prompt: se il `LAContext` viene rilasciato da ARC
    /// mentre la callback è pending, il prompt sparisce (`LAError.appCancel`) e
    /// `isAuthenticating` resterebbe bloccato su `true`.
    private var context: LAContext?

    private init() {
        touchIDEnabled = UserDefaults.standard.object(forKey: "touchIDEnabled") as? Bool ?? true
        // Gate disattivato all'avvio ⇒ questa sessione è già autorizzata: riattivare il toggle
        // a metà sessione vale dal prossimo lancio, non blocca di colpo l'app già aperta
        // (il gate è "solo all'avvio", vedi spec 2026-08-17-touchid-auth-design.md).
        unlocked = !touchIDEnabled
    }

    func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        let context = LAContext()
        self.context = context
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Sblocca AppBackupFoto") { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unlocked = true
                } else {
                    self.lastError = error?.localizedDescription ?? "Autenticazione non riuscita"
                }
            }
        }
    }
}

// MARK: - LockScreenView
struct LockScreenView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Image(systemName: "touchid")
                .font(.system(size: AppIconSize.heroLarge))
                .foregroundStyle(AppColor.utility)
            Text("AppBackupFoto è bloccata").font(AppFont.title)
            if let err = gate.lastError {
                Text(err).font(.caption).foregroundStyle(AppColor.error).multilineTextAlignment(.center)
            }
            Button {
                gate.authenticate()
            } label: {
                Text(gate.isAuthenticating ? "Autenticazione…" : "Sblocca con Touch ID")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .disabled(gate.isAuthenticating)
        }
        .padding(AppSpacing.xxl)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { gate.authenticate() }
    }
}

// MARK: - ImmichManager
/// Ciclo di vita dell'istanza Immich gestita dall'app (Colima + Docker Compose).
/// Stesso stile di `BackupRunner`/`AuthGateManager`: singleton `ObservableObject`.
///
/// Tutto ciò che questa classe scrive vive sotto `~/Library/Application Support/AppBackupFoto/immich/`
/// sul **disco interno** del Mac — mai su SSD/HDD esterni (Postgres vuole storage locale, e se
/// l'SSD viene scollegato il server resta comunque in piedi). La libreria foto sull'SSD viene
/// solo montata in sola lettura come External Library: Immich la legge, non la scrive mai.
final class ImmichManager: ObservableObject {
    static let shared = ImmichManager()
    @Published var installed: Bool = false
    /// **Immich risponde davvero** (health check OK). È questo — e solo questo — a decidere
    /// se mostrare la WebView: la VM accesa non basta, perché una WebView puntata su un
    /// server che non risponde resta bianca e senza via d'uscita.
    @Published var isRunning: Bool = false
    /// La VM Colima risulta accesa, **anche se Immich non risponde**. Serve solo a decidere
    /// se c'è qualcosa da spegnere alla chiusura dell'app: tenerlo separato da `isRunning`
    /// evita che "VM su, container giù" venga scambiato per "Immich pronto".
    @Published var vmPossiblyUp: Bool = false
    @Published var isStarting: Bool = false
    @Published var lastError: String?

    let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppBackupFoto/immich", isDirectory: true)
    }()

    var binDir: URL { appSupportDir.appendingPathComponent("bin", isDirectory: true) }
    var composeFilePath: URL { appSupportDir.appendingPathComponent("docker-compose.yml") }
    var dataDir: URL { appSupportDir.appendingPathComponent("data", isDirectory: true) }

    /// `DOCKER_CONFIG` privato dell'app: qui dentro finiscono il plugin `docker compose`
    /// (`cli-plugins/docker-compose`) e il context Docker creato da Colima. Non tocca mai
    /// il `~/.docker` personale di Enrico.
    var dockerConfigDir: URL { appSupportDir.appendingPathComponent("docker-config", isDirectory: true) }
    /// `LIMA_HOME`/`COLIMA_HOME` privati: la VM e il suo stato non finiscono in `~/.lima`/`~/.colima`.
    var limaHomeDir: URL { appSupportDir.appendingPathComponent("lima-home", isDirectory: true) }
    var colimaHomeDir: URL { appSupportDir.appendingPathComponent("colima-home", isDirectory: true) }

    var colimaBinary: URL { binDir.appendingPathComponent("colima") }
    var limactlBinary: URL { binDir.appendingPathComponent("limactl") }
    var dockerBinary: URL { binDir.appendingPathComponent("docker") }
    var composePluginPath: URL {
        dockerConfigDir.appendingPathComponent("cli-plugins", isDirectory: true)
            .appendingPathComponent("docker-compose")
    }

    /// "Installato" = i quattro binari necessari sono già sul disco. Deliberatamente **non**
    /// l'esistenza del compose file: quello viene (ri)scritto da `start(sourceLibraryPath:)`
    /// a ogni avvio, quindi non dice nulla su cosa sia davvero installato.
    func detectInstalled() -> Bool {
        let fm = FileManager.default
        return [colimaBinary, limactlBinary, dockerBinary, composePluginPath]
            .allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    private init() {
        installed = detectInstalled()
    }
}

extension ImmichManager {
    /// Racchiude un path in una stringa YAML fra virgolette doppie, con escape di `\` e `"`.
    /// Serve perché il path della libreria arriva da un bookmark scelto dall'utente: senza
    /// escape, un nome cartella con una virgoletta romperebbe (o altererebbe) il compose file.
    static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Genera una entry di volume in **long syntax** (`type`/`source`/`target`/`read_only`).
    ///
    /// Non è una preferenza stilistica: la short syntax `- "src":"dst":ro` **non è YAML valido**
    /// (uno scalare double-quoted non può essere seguito da altro testo sulla stessa riga in
    /// block context) e `docker compose` rifiuterebbe il file al parsing. La long syntax regge
    /// inoltre un path che contiene `:` — caso reale su macOS, dove una cartella che in Finder
    /// si chiama "Foto/2020" ha path POSIX `Foto:2020` e romperebbe la short syntax `src:dst:mode`
    /// anche se quotata.
    ///
    /// `indent` è il numero di spazi a cui la entry è ancorata nel template, necessario perché
    /// l'interpolazione di una stringa multi-riga non re-indenta le righe successive alla prima.
    static func bindMountYAML(source: String, target: String, readOnly: Bool, indent: Int) -> String {
        var lines = ["- type: bind",
                     "  source: \(yamlQuoted(source))",
                     "  target: \(yamlQuoted(target))"]
        if readOnly { lines.append("  read_only: true") }
        return lines.joined(separator: "\n" + String(repeating: " ", count: indent))
    }

    /// Contenuto del `docker-compose.yml` di Immich, adattato dal file ufficiale
    /// (`https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml`,
    /// riverificato il 2026-08-17) con tre differenze intenzionali, tutte vincolanti:
    ///
    /// 1. la porta del server è pubblicata **solo su `127.0.0.1:2283`**, mai `0.0.0.0` —
    ///    l'accesso da rete/telefono è fuori scope e sarebbe un rischio inutile;
    /// 2. tutti i volumi dati (upload, Postgres, cache modelli ML) stanno sotto `dataDir`,
    ///    cioè sul disco interno del Mac, mai su SSD/HDD esterni;
    /// 3. la cartella foto sull'SSD è montata **in sola lettura** (`read_only: true`) come
    ///    External Library: Immich la indicizza dove già sta, non la copia e non ci scrive
    ///    mai (coerente con zero-delete/zero-overwrite).
    ///
    /// Funzione pura (dipende solo da `dataDir` e dal parametro) proprio per poter essere
    /// testata senza avviare nulla — stesso criterio di `checkDeepMirrorFreshness(...)`.
    /// I test la ri-parsano con un parser YAML vero: verificare il testo con `contains(...)`
    /// non intercetta un file sintatticamente rotto (lezione di una revisione del 2026-08-17).
    func composeFileContent(sourceLibraryPath: String) -> String {
        let data = dataDir.path
        return """
        name: appbackupfoto-immich
        services:
          immich-server:
            image: ghcr.io/immich-app/immich-server:release
            ports:
              - "127.0.0.1:2283:2283"
            volumes:
              \(Self.bindMountYAML(source: "\(data)/upload", target: "/data", readOnly: false, indent: 6))
              \(Self.bindMountYAML(source: sourceLibraryPath, target: "/external-ssd", readOnly: true, indent: 6))
              - /etc/localtime:/etc/localtime:ro
            environment:
              - DB_HOSTNAME=immich-database
              - DB_USERNAME=postgres
              - DB_PASSWORD=postgres
              - DB_DATABASE_NAME=immich
              - REDIS_HOSTNAME=immich-redis
            depends_on:
              - immich-redis
              - immich-database
            restart: unless-stopped
          immich-machine-learning:
            image: ghcr.io/immich-app/immich-machine-learning:release
            volumes:
              \(Self.bindMountYAML(source: "\(data)/model-cache", target: "/cache", readOnly: false, indent: 6))
            restart: unless-stopped
          immich-redis:
            image: docker.io/valkey/valkey:9
            restart: unless-stopped
          immich-database:
            image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
            environment:
              - POSTGRES_PASSWORD=postgres
              - POSTGRES_USER=postgres
              - POSTGRES_DB=immich
              - POSTGRES_INITDB_ARGS=--data-checksums
            volumes:
              \(Self.bindMountYAML(source: "\(data)/postgres", target: "/var/lib/postgresql/data", readOnly: false, indent: 6))
            shm_size: 128mb
            restart: unless-stopped
        """
    }
}

// MARK: - ImmichManager — ciclo di vita (Colima + Docker Compose)

/// Buffer thread-safe per l'output di un `Process`: senza leggere la pipe *mentre* il processo
/// gira, un comando verboso (`docker compose up` che scarica GB di immagini) riempie i 64KB di
/// buffer del kernel e si blocca per sempre.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

/// Garantisce che una `CheckedContinuation` venga ripresa una volta sola: qui ci arrivano
/// sia la terminazione del processo sia il timeout, e riprenderla due volte è un crash.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

extension ImmichManager {
    enum Failure: LocalizedError {
        case downloadFailed(String)
        case commandFailed(command: String, status: Int32, output: String)
        case commandTimedOut(command: String)
        case startTimedOut
        case checksumMismatch(asset: String, expected: String, actual: String)
        case unsupportedLibraryPath(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedLibraryPath(let path):
                return """
                Il percorso della libreria contiene un carattere non supportato (:) e non può essere usato da Immich.
                Percorso: \(path)
                Rinomina la cartella (in Finder il carattere appare come "/") e riprova.
                """
            case .checksumMismatch(let asset, let expected, let actual):
                return """
                Il file scaricato '\(asset)' non corrisponde alla versione attesa e non è stato installato.
                Attesa:   \(expected)
                Ottenuta: \(actual)
                Riprova; se l'errore si ripete, non forzare l'installazione.
                """
            case .downloadFailed(let what):
                return "Download non riuscito: \(what)"
            case .commandFailed(let command, let status, let output):
                let tail = output.suffix(500)
                return "Comando '\(command)' fallito (codice \(status)).\n\(tail)"
            case .commandTimedOut(let command):
                return "Comando '\(command)' non ha risposto entro il tempo massimo."
            case .startTimedOut:
                return "Immich non è diventato raggiungibile entro il tempo massimo. Riprova, oppure controlla lo stato dei container."
            }
        }
    }

    // MARK: Versioni pinnate
    // Pinnate a mano e non "latest": un aggiornamento a sorpresa di uno di questi quattro
    // pezzi non deve poter rompere l'avvio senza che nessuno se ne accorga. Verificate il
    // 2026-08-17; per aggiornarle basta cambiare qui e rifare l'installazione.

    static let colimaVersion = "v0.10.3"
    static let limaVersion = "2.2.0"
    static let dockerCLIVersion = "29.7.2"
    static let composePluginVersion = "v5.5.0"

    // MARK: SHA256 attesi
    // Ogni file scaricato viene verificato contro questi hash **prima** di essere reso
    // eseguibile o estratto. Senza, l'app si fiderebbe di un HTTP 200 e poi eseguirebbe
    // il risultato con i pieni privilegi dell'utente (app non sandboxata, Full Disk
    // Access): se un asset di release venisse sostituito, non ce ne accorgeremmo.
    // Vanno aggiornati insieme alle versioni qui sopra — un hash sbagliato blocca
    // l'installazione con un errore esplicito, non la fa passare in silenzio.
    //
    // Fonte degli hash (verificati il 2026-08-17):
    // - colima:  <release>/colima-Darwin-<arch>.sha256sum
    // - lima:    <release>/SHA256SUMS
    // - compose: <release>/docker-compose-darwin-<arch>.sha256
    // - docker CLI: **nessun checksum ufficiale pubblicato da Docker** per i binari statici
    //   macOS. Questi due valori sono stati calcolati a mano (`shasum -a 256`) sui tarball
    //   scaricati il 2026-08-17. Attenzione al limite: pinnano *quel* file, ma non provano
    //   nulla sulla sua autenticità all'origine (trust-on-first-use). Proteggono comunque
    //   da una sostituzione successiva e da un download corrotto.

    private static let colimaSHA256 = isARM
        ? "980ad8bf61a4ca370243f4cb41401a61276dcd2c2502bee7b9b86f9250169f34"
        : "3082737fe8a98afda11cba7d9a20b6e56fe80c6153464beda04bec630758770b"
    private static let limaSHA256 = isARM
        ? "bbdef91774885a0d05f7b048c4eb89ae2bcf3a0c252ae7ca7934e63df76d93c3"
        : "0d6f99c19f6e4bc3c92730c4c29d929e6927f0cb0a0ba1a84383367135a8ff31"
    private static let dockerCLISHA256 = isARM
        ? "b8683ed19d1f06048a496f9b8429e2c71d0b088d475b7487c054ea3666c02a3c"
        : "fb1f1aa7ac7af4364165b9eadfda92e96c8ced508fca74f53079719891367438"
    private static let composePluginSHA256 = isARM
        ? "6777710e5a5db5709e5f4b5985844e74b73cc1a6123e3a6690b6ababf2deaf51"
        : "d0f0c867fd740953899a63d6d1a291dc60200b0961de9612a01bcc560e6e29a6"

    /// Web UI di Immich. Loopback, non raggiungibile dalla rete: il compose file pubblica la
    /// porta solo su `127.0.0.1` (vedi `composeFileContent`).
    static let webUIURL = URL(string: "http://127.0.0.1:2283")!

    /// Health-check pubblico di Immich: OpenAPI dichiara `servers: [/api]` + path `/server/ping`,
    /// stabile dalla v2 (riverificato il 2026-08-17). Solo loopback, mai un host di rete.
    static let healthCheckURL = URL(string: "http://127.0.0.1:2283/api/server/ping")!

    /// Nomi degli asset: ogni progetto usa una convenzione diversa per la stessa architettura
    /// (`arm64` per Colima/Lima, `aarch64` per Docker CLI e per il plugin compose).
    private static var isARM: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static var colimaURL: URL {
        URL(string: "https://github.com/abiosoft/colima/releases/download/\(colimaVersion)/colima-Darwin-\(isARM ? "arm64" : "x86_64")")!
    }
    private static var limaURL: URL {
        URL(string: "https://github.com/lima-vm/lima/releases/download/v\(limaVersion)/lima-\(limaVersion)-Darwin-\(isARM ? "arm64" : "x86_64").tar.gz")!
    }
    private static var dockerCLIURL: URL {
        URL(string: "https://download.docker.com/mac/static/stable/\(isARM ? "aarch64" : "x86_64")/docker-\(dockerCLIVersion).tgz")!
    }
    private static var composePluginURL: URL {
        URL(string: "https://github.com/docker/compose/releases/download/\(composePluginVersion)/docker-compose-darwin-\(isARM ? "aarch64" : "x86_64")")!
    }

    // MARK: Installazione

    /// Scarica in `binDir` i quattro pezzi necessari, **senza `sudo` e senza toccare nulla di
    /// globale sul Mac** (niente `/usr/local/bin`, niente Homebrew): deviazione intenzionale
    /// dalla guida ufficiale di Colima.
    ///
    /// Servono tutti e quattro, non solo Colima: `colima` è un wrapper su Lima e senza
    /// `limactl` non parte; il tarball statico di Docker contiene solo la CLI, e `docker compose`
    /// è un plugin distribuito a parte.
    ///
    /// Solo download: **non** avvia la VM e non scarica le immagini Docker di Immich (quelli
    /// sono diversi GB e succedono al primo `start()`, dopo conferma esplicita).
    func install() async throws {
        await MainActor.run { self.lastError = nil }
        do {
            let fm = FileManager.default
            for dir in [binDir, dataDir, dockerConfigDir, limaHomeDir, colimaHomeDir,
                        composePluginPath.deletingLastPathComponent()] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // Ordine deliberato: prima gli archivi che si estraggono (Lima scompatta un intero
            // albero dentro appSupportDir, quindi in teoria potrebbe scrivere su bin/colima o
            // bin/docker), poi i singoli binari. Con la verifica SHA256 un archivio manomesso
            // non arriva comunque mai a `tar`, ma così anche un eventuale buco futuro non
            // lascerebbe un archivio sovrascrivere binari già verificati.
            try await downloadLima()
            try await downloadDockerCLI()
            try await downloadExecutable(from: Self.colimaURL, to: colimaBinary,
                                         expectedSHA256: Self.colimaSHA256)
            try await downloadExecutable(from: Self.composePluginURL, to: composePluginPath,
                                         expectedSHA256: Self.composePluginSHA256)

            let ok = detectInstalled()
            await MainActor.run { self.installed = ok }
            if !ok { throw Failure.downloadFailed("uno dei binari non risulta presente al termine") }
        } catch {
            await MainActor.run {
                self.installed = false
                self.lastError = "Installazione non riuscita: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Scarica un singolo binario, **ne verifica lo SHA256** e solo allora lo rende eseguibile.
    /// La `removeItem` qui tocca **solo** un file che questa stessa funzione ha scaricato dentro
    /// la cartella dell'app (mai foto, mai SSD/HDD): serve a rendere ripetibile un'installazione
    /// interrotta a metà.
    private func downloadExecutable(from url: URL, to destination: URL, expectedSHA256: String) async throws {
        let downloaded = try await downloadToTemporaryFile(url, expectedSHA256: expectedSHA256)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: downloaded, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// Il tarball di Lima si estrae in `bin/` + `share/`: scompattandolo dentro `appSupportDir`
    /// `limactl` finisce esattamente in `binDir` e trova da solo la sua `share/lima` accanto.
    private func downloadLima() async throws {
        let archive = try await downloadToTemporaryFile(Self.limaURL, expectedSHA256: Self.limaSHA256)
        defer { try? FileManager.default.removeItem(at: archive) }
        try await runTar(["-xzf", archive.path, "-C", appSupportDir.path])
    }

    /// Il tgz di Docker contiene `docker/docker`: `--strip-components=1` lo posa dritto in `binDir`.
    private func downloadDockerCLI() async throws {
        let archive = try await downloadToTemporaryFile(Self.dockerCLIURL, expectedSHA256: Self.dockerCLISHA256)
        defer { try? FileManager.default.removeItem(at: archive) }
        try await runTar(["-xzf", archive.path, "-C", binDir.path, "--strip-components=1", "docker/docker"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dockerBinary.path)
    }

    /// Scarica in un file temporaneo e ne verifica l'integrità. Se l'hash non combacia il file
    /// viene cancellato subito e l'errore risale: niente `chmod +x`, niente `tar`, niente
    /// esecuzione — un binario che non è quello atteso non deve mai toccare `binDir`.
    private func downloadToTemporaryFile(_ url: URL, expectedSHA256: String) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw Failure.downloadFailed(url.lastPathComponent)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // `sha256(of:)` legge il file a blocchi con I/O POSIX: memoria costante anche su
        // archivi grandi (stessa funzione e stessa ragione del fix di memoria del 2026-07-30).
        guard let actual = sha256(of: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.downloadFailed("impossibile calcolare lo SHA256 di \(url.lastPathComponent)")
        }
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.checksumMismatch(asset: url.lastPathComponent,
                                           expected: expectedSHA256.lowercased(),
                                           actual: actual)
        }
        return destination
    }

    /// Unica eccezione consapevole alla regola "solo binari in `binDir`": `/usr/bin/tar` è una
    /// utility di sistema di macOS usata soltanto per scompattare gli archivi appena scaricati.
    private func runTar(_ arguments: [String]) async throws {
        _ = try await runProcess(URL(fileURLWithPath: "/usr/bin/tar"), arguments, timeout: 300)
    }

    // MARK: Avvio / arresto

    /// Rifiuta un path di libreria che Colima non saprebbe interpretare.
    ///
    /// Colima fa `strings.SplitN(mount, ":", 3)` sul valore di `--mount` (sorgente upstream
    /// v0.10.3, `cmd/start.go`): un path che contiene `:` verrebbe troncato al primo `:` —
    /// monterebbe una cartella diversa o inesistente, con un errore di avvio poco chiaro — e
    /// un path che finisce per `:w` verrebbe letto come il flag "writable", montando in
    /// **scrittura** dentro la VM una cartella che deve restare in sola lettura.
    ///
    /// Il `read_only: true` del compose file resta come secondo strato e impedirebbe comunque
    /// la scrittura reale, ma la protezione a livello di mount cadrebbe in silenzio: meglio
    /// fermarsi con un messaggio comprensibile che affidarsi al parser di Colima.
    ///
    /// Non è un caso di scuola: su macOS una cartella che in Finder si chiama "Foto/2020" ha
    /// path POSIX `Foto:2020` — la stessa classe di path del bug YAML corretto poco prima.
    /// Funzione pura e testata, come `composeFileContent`.
    static func validateLibraryPath(_ path: String) throws {
        guard !path.contains(":") else { throw Failure.unsupportedLibraryPath(path) }
    }

    /// Scrive il compose file, avvia la VM Colima e lo stack Immich, poi aspetta che il server
    /// risponda davvero prima di dichiararlo pronto (mai una WebView bianca su un server che
    /// non è ancora su).
    func start(sourceLibraryPath: String) async throws {
        guard !isStarting else { return }
        await MainActor.run { self.isStarting = true; self.lastError = nil }
        defer { Task { @MainActor in self.isStarting = false } }

        do {
            // Prima di qualunque effetto collaterale: un path che Colima interpreterebbe male
            // non deve nemmeno arrivare alla riga di comando (vedi `validateLibraryPath`).
            try Self.validateLibraryPath(sourceLibraryPath)
            let fm = FileManager.default
            for dir in [dataDir, dockerConfigDir, limaHomeDir, colimaHomeDir] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try composeFileContent(sourceLibraryPath: sourceLibraryPath)
                .write(to: composeFilePath, atomically: true, encoding: .utf8)

            // I bind mount del compose funzionano solo se il path è visibile *dentro* la VM:
            // Colima monta di suo solo `$HOME`/`/tmp/colima`, quindi entrambi i path vanno
            // dichiarati esplicitamente. `:w` solo sui dati di Immich; la libreria foto è
            // montata senza `:w`, cioè in sola lettura — secondo strato di protezione oltre
            // al `:ro` del compose file.
            var colimaArgs = ["start", "--cpus", "4", "--memory", "8",
                              "--vm-type", "vz", "--mount-type", "virtiofs",
                              "--mount", "\(dataDir.path):w"]
            if !sourceLibraryPath.isEmpty {
                colimaArgs += ["--mount", sourceLibraryPath]
            }
            _ = try await runProcess(colimaBinary, colimaArgs, timeout: 600)
            _ = try await runProcess(dockerBinary,
                                     ["compose", "-f", composeFilePath.path, "up", "-d"],
                                     timeout: 1800)

            // Polling: al primo avvio la VM, Postgres e il servizio ML ci mettono parecchio.
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if await healthCheck() {
                    await MainActor.run { self.isRunning = true }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            throw Failure.startTimedOut
        } catch {
            // Mai dichiarare `isRunning = false` a scatola chiusa: se l'health check è scaduto
            // ma lo stack è realmente su (probabile al primissimo avvio, tra migrazioni Postgres
            // e caricamento del modello ML), quel `false` sarebbe una bugia — l'utente vedrebbe
            // "fermo", chiuderebbe l'app e VM + 4 container resterebbero accesi a sua insaputa.
            // Si chiede al sistema com'è messo davvero. Deliberatamente **non** si forza uno
            // `stop()`: se lo stack sta solo finendo di partire, spegnerlo sarebbe peggio.
            await detectRunning()
            await MainActor.run { self.lastError = error.localizedDescription }
            throw error
        }
    }

    /// Riallinea `isRunning` allo stato reale del sistema, invece di fidarsi di un flag in
    /// memoria. Serve in due casi concreti: dopo un timeout di `start()` su uno stack che in
    /// realtà è partito, e al rilancio dopo un crash/force-quit (dove `isRunning` ripartirebbe
    /// da `false` con i container ancora accesi dalla sessione precedente).
    @discardableResult
    func detectRunning() async -> Bool {
        guard detectInstalled() else {
            await MainActor.run { self.isRunning = false; self.vmPossiblyUp = false }
            return false
        }

        // Due segnali distinti, di proposito. L'health check dice se Immich è **usabile**;
        // `colima status` (exit 0 = VM accesa) copre il caso "VM su, container giù", che
        // consuma comunque risorse e va spento alla chiusura ma **non** deve far comparire
        // la WebView: caricherebbe una pagina bianca su un server che non risponde, senza
        // retry e senza più il bottone "Avvia" (dipende da `!isRunning`) — vicolo cieco da
        // cui si usciva solo chiudendo l'app. Scenario reale: sessione precedente chiusa
        // con un `colima stop` fallito o scaduto.
        let immichUp = await healthCheck()
        // Se Immich risponde, la VM è ovviamente accesa: si evita un processo inutile.
        // (Non si può usare `||`: il suo secondo operando è un autoclosure non async.)
        var vmUp = immichUp
        if !vmUp {
            vmUp = (try? await runProcess(colimaBinary, ["status"], timeout: 15)) != nil
        }

        await MainActor.run {
            self.isRunning = immichUp
            self.vmPossiblyUp = vmUp
        }
        return immichUp
    }

    /// Ferma container e VM. Best-effort e non lancia: viene chiamata anche alla chiusura
    /// dell'app, dove non c'è più nessuna UI a cui riportare un errore.
    ///
    /// Timeout generosi di proposito: fermare 4 container (Postgres incluso, che deve chiudere
    /// il suo checkpoint) più l'arresto della VM può richiedere parecchio, e troncare a metà
    /// un arresto di Postgres è il modo migliore per ritrovarsi un database da riparare.
    /// Nel caso normale ritorna in pochi secondi — questi valori valgono solo per i casi patologici.
    static let stopCommandTimeout: TimeInterval = 90

    /// Attesa fra SIGTERM e SIGKILL per un processo che non risponde al timeout.
    static let sigkillGracePeriod: TimeInterval = 10

    func stop() async {
        _ = try? await runProcess(dockerBinary,
                                  ["compose", "-f", composeFilePath.path, "down"],
                                  timeout: Self.stopCommandTimeout)
        _ = try? await runProcess(colimaBinary, ["stop"], timeout: Self.stopCommandTimeout)
        await MainActor.run { self.isRunning = false; self.vmPossiblyUp = false }
    }

    func healthCheck() async -> Bool {
        var request = URLRequest(url: Self.healthCheckURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Esecuzione processi

    /// Ambiente dei processi figli: PATH con `binDir` davanti (così `colima` trova il *nostro*
    /// `limactl`/`docker` e non eventuali installazioni di sistema), e le tre home
    /// (`DOCKER_CONFIG`/`LIMA_HOME`/`COLIMA_HOME`) dirottate dentro la cartella dell'app.
    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(binDir.path):\(existingPath)"
        env["DOCKER_CONFIG"] = dockerConfigDir.path
        env["LIMA_HOME"] = limaHomeDir.path
        env["COLIMA_HOME"] = colimaHomeDir.path
        return env
    }

    /// Esegue un comando raccogliendone l'output, con timeout: nessun comando può appendere
    /// l'app per sempre (il processo viene terminato allo scadere).
    @discardableResult
    private func runProcess(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = childEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = ProcessOutputBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil } else { buffer.append(chunk) }
        }

        let name = "\(executable.lastPathComponent) \(arguments.first ?? "")"
        return try await withCheckedThrowingContinuation { continuation in
            let resume = ContinuationGuard()

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                guard resume.claim() else { return }
                let output = buffer.text
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: Failure.commandFailed(
                        command: name, status: proc.terminationStatus, output: output))
                }
            }

            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                if resume.claim() { continuation.resume(throwing: error) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()   // SIGTERM: prima si chiede un'uscita pulita.
                // Chi ignora SIGTERM resterebbe orfano per sempre, con la readability handler
                // già staccata e nessuno più in ascolto: dopo la grazia si insiste con SIGKILL.
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.sigkillGracePeriod) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
                if resume.claim() {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: Failure.commandTimedOut(command: name))
                }
            }
        }
    }
}

// MARK: - Models
struct JobStats {
    var percent: Int = 0
    var done: Int = 0
    var total: Int = 0
    var eta: String = "—"
    var elapsed: String = "—"
    var copied: Int = 0
    var skipped: Int = 0
    var errors: Int = 0
    var speed: String = "—"
    var verifiedOk: Int = 0   // file copiati con SHA256 verificato con successo
    var hashErrors: Int = 0   // file con SHA256 mismatch dopo la copia
    var copiedUnverified: Int = 0   // file copiati la cui verifica SHA256 non ha potuto concludersi (vedi FileSyncer.SyncResult)
    var changedSkipped: Int = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
    var duplicatesSkipped: Int = 0   // file gia' presenti altrove in libreria con contenuto identico (roadmap #31)
}

struct SpeedSample: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

enum JobPhase: Equatable {
    case idle, running(String), success(String), failed(String)
    var label: String {
        switch self {
        case .idle: return "Pronto"
        case .running(let s), .success(let s), .failed(let s): return s
        }
    }
    var color: Color {
        switch self {
        case .idle: return .secondary; case .running: return AppColor.inProgress
        case .success: return AppColor.success; case .failed: return AppColor.error
        }
    }
    var icon: String {
        switch self {
        case .idle: return "circle.dotted"; case .running: return "arrow.trianglehead.2.clockwise"
        case .success: return "checkmark.circle.fill"; case .failed: return "xmark.circle.fill"
        }
    }
    var isTerminal: Bool {
        switch self { case .success, .failed: return true; default: return false }
    }
}

// MARK: - Shared utilities

func isLikelyVolumeRoot(_ url: URL) -> Bool {
    // /Volumes/VolumeName ha esattamente 3 componenti: ["/", "Volumes", "Name"]
    url.pathComponents.count <= 3
}

/// True se `source` coincide con, è contenuto in, o contiene uno dei path in
/// `configuredURLs`. Usata dal wizard di import per due scopi: evitare un
/// self-import della libreria dentro se stessa (`configuredURLs` = Libreria
/// Foto/SSD/HDD) e, come guardia strutturale in `runImport`, escludere che
/// destinazione e sorgente si contengano a vicenda.
///
/// I symlink vengono risolti **su entrambi i lati** prima del confronto, mai su uno
/// solo: senza questo, un alias verso una location configurata passerebbe la guardia
/// e `FileSyncer.syncDir` finirebbe per ricorrere dentro la destinazione che ha
/// appena creato (crea `dst` prima di elencare `src`), con una ricorsione runaway
/// fermata solo da PATH_MAX.
///
/// Su path inesistenti (es. `/Volumes/SSD - Enri` con SSD scollegato)
/// `resolvingSymlinksInPath()` restituisce il path invariato — verificato
/// empiricamente — quindi il confronto testuale resta valido anche a volume assente.
/// Limite noto, ereditato dalla piattaforma e documentato in
/// `.claude/rules/architecture.md` (ReviewEngine/`sampleLocalPair`): su macOS
/// `resolvingSymlinksInPath()` lascia di proposito `/var` e `/tmp` non risolti. È
/// irrilevante per i path di questo progetto (`/Users/...`, `/Volumes/...`) ed è
/// comunque simmetrico, dato che il trattamento dei due lati è identico.
func isSourceInsideConfiguredLocations(_ source: URL, configuredURLs: [URL]) -> Bool {
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    for configured in configuredURLs {
        let configuredPath = configured.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath == configuredPath
            || sourcePath.hasPrefix(configuredPath + "/")
            || configuredPath.hasPrefix(sourcePath + "/") {
            return true
        }
    }
    return false
}

/// Limite in **byte UTF-8** per il nome di cartella prodotto da `importFolderSlug`.
/// Margine deliberato sotto i 255 byte reali di HFS+/APFS/ExFAT: il limite del
/// filesystem è in byte, non in caratteri, e ~200 caratteri accentati bastano a
/// superarlo facendo fallire `createDirectory`.
let importFolderSlugMaxBytes = 200

/// Converte un'etichetta libera in un nome di **singola** componente di path, sicuro
/// da passare a `appendingPathComponent` e da creare con `createDirectory`.
///
/// Garanzie (tutte dentro la funzione: i chiamanti non devono sapere nulla):
/// - `/` e `:` diventano `-`, quindi il risultato non può introdurre livelli di path
///   né essere reinterpretato dal Finder;
/// - i caratteri di controllo (incluso `\0`, che farebbe fallire `createDirectory`, e
///   `\n`/`\r` in mezzo alla stringa, che il solo trim sui bordi non toccherebbe)
///   vengono rimossi;
/// - il risultato non è mai `""`, `"."`, `".."` né una sequenza di soli punti — casi
///   in cui `appendingPathComponent` produrrebbe una destinazione che risolve fuori
///   dalla cartella dedicata (`<SSD>/Import/..` scrive nella root dell'SSD) — si
///   ricade su `"Import"`;
/// - la lunghezza è ≤ `importFolderSlugMaxBytes` byte UTF-8; il troncamento avviene
///   **per caratteri**, quindi non spezza mai una sequenza UTF-8 (né un grafema) a metà;
/// - il risultato non inizia mai con `.`, quindi non è mai una cartella **nascosta**.
///   Non è un dettaglio estetico: `.skipsHiddenFiles` è usato in 8 punti di questo file,
///   fra cui `FileSyncer.previewDir`/`syncDir` (la copia SSD→HDD) e
///   `listAvailableFolders`. Un import atterrato in `<SSD>/Import/.EOS_DIGITAL` sarebbe
///   rimasto sull'SSD ma **non sarebbe mai stato copiato su HDD né elencato nella UI**,
///   senza produrre un solo errore — e sarebbe rimasto fuori dall'indice di contenuto
///   (roadmap #31), quindi anche dal dedup. Un punto **interno** all'etichetta
///   ("Canon 5D .backup") è invece innocuo e viene conservato.
func importFolderSlug(_ label: String) -> String {
    var cleaned = String(String.UnicodeScalarView(
        label.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    cleaned = cleaned
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.utf8.count > importFolderSlugMaxBytes {
        var truncated = ""
        var bytes = 0
        for character in cleaned {
            let size = String(character).utf8.count
            if bytes + size > importFolderSlugMaxBytes { break }
            truncated.append(character)
            bytes += size
        }
        cleaned = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Un nome che inizia per "." è una cartella nascosta, e tutto ciò che in questa
    // app enumera il filesystem passa da `.skipsHiddenFiles`: la cartella sarebbe
    // invisibile al backup SSD→HDD, alla sua anteprima, all'elenco cartelle e
    // all'indice di contenuto.
    //
    // Il ciclo è necessario, un solo passaggio NON basta: togliendo i punti resta
    // spesso uno spazio in testa (". Foto"), e il trim che lo rimuove può riportare
    // in testa il punto successivo. Con ". .EOS_DIGITAL" la versione a passaggio
    // singolo produceva ".EOS_DIGITAL" — esattamente il caso che doveva impedire.
    // Termina sempre: a ogni giro la stringa si accorcia o resta uguale, e in quel
    // caso il ciclo esce.
    //
    // Il confronto è sugli scalari Unicode e non sui `Character` perché il
    // filesystem guarda il primo byte: il grafema "." + accento combinante ha un
    // primo `Character` diverso da "." ma primo byte 0x2E, quindi sarebbe nascosto.
    var previous: String
    repeat {
        previous = cleaned
        while cleaned.unicodeScalars.first == "." { cleaned.unicodeScalars.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    } while cleaned != previous

    if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "Import" }
    return cleaned
}

/// File e cartelle di sistema da non trattare come contenuto dell'utente.
///
/// **Chi la usa davvero, oggi**: `FileSyncer` (Mac→SSD e SSD→HDD) e
/// `ReviewEngine.scanLocalCatalog`. **Non** la usano `S3Syncer.previewUpload`,
/// `S3Syncer.sync` e `ReviewEngine.sampleLocalPair`, che hanno una variante più
/// debole (`hasPrefix("._") || name == ".DS_Store"`). Poiché tutti girano dentro un
/// enumerator con `.skipsHiddenFiles`, la divergenza reale è di due soli nomi non
/// nascosti: `lost+found` e `Backups.backupdb`. La direzione è innocua (escludono
/// *meno*, quindi copiano di più, mai di meno) ma non è nulla: un `Backups.backupdb`
/// sull'SSD verrebbe caricato su Cubbit e non copiato su HDD. Da decidere se
/// allinearli — è un cambio di comportamento, non una rifattorizzazione.
///
/// **Il filtro effettivo è `.skipsHiddenFiles` PIÙ questa lista**, non questa lista
/// da sola: 6 degli 8 nomi qui sotto iniziano con un punto e sarebbero già saltati
/// dall'enumerator. Chi scrive un nuovo percorso di scansione deve usare **entrambi**.
/// Usare solo questa lista produrrebbe un insieme più largo di quello che viene
/// copiato — e per l'indice di contenuto (#31) sarebbe una perdita silenziosa: una
/// copia nascosta e byte-identica farebbe saltare un import reale, mentre quella
/// copia non arriva mai né su HDD né su Cubbit.
///
/// **Fonte unica, di proposito.** Questa lista è vissuta a lungo in due copie
/// identiche, in due tipi diversi, ciascuna con il proprio `shouldExclude`. Due
/// liste che "devono restare uguali" divergono appena qualcuno ne aggiorna una
/// sola, e il sintomo è silenzioso: un file escluso dalla copia ma incluso
/// nell'indice (o viceversa) non produce nessun errore, solo un conteggio che non
/// torna. Aggiungere qui, mai nei singoli chiamanti.
enum LibraryExclusions {
    static let names: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb"
    ]

    /// Confronto sull'ultima componente del path, mai sul path intero: una cartella
    /// di passaggio dal nome simile non deve escludere i file che contiene.
    /// `._*` sono i sidecar AppleDouble che macOS crea sui filesystem non-HFS —
    /// l'SSD è ExFAT, quindi ce ne sono ovunque.
    static func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return names.contains(name) || name.hasPrefix("._")
    }
}

/// Forma canonica di un percorso, risolta **dal filesystem** con `realpath(3)`.
///
/// Fonte unica, per lo stesso motivo di `LibraryExclusions`. Esistevano due
/// canonicalizzazioni diverse per lo stesso problema, e producono forme **opposte**
/// (misurato il 2026-08-26):
///
///     realpath("/var/folders/.../SSD")                       -> /private/var/folders/.../SSD
///     URL("/private/var/.../SSD").resolvingSymlinksInPath()  -> /var/folders/.../SSD
///
/// `URL.resolvingSymlinksInPath` lascia `/var`, `/tmp` e `/etc` non risolti **di
/// proposito** (sono symlink verso `/private/...` che Foundation considera parte del
/// nome canonico); `realpath` li risolve. Un codice che usa l'una per costruire le
/// chiavi dell'indice e l'altra per rileggerle produce due insiemi di chiavi disgiunti:
/// l'indice sembra vuoto, l'intera libreria viene rihashata e ogni entry viene
/// duplicata a ogni scansione — il bug corretto il 2026-08-26, che sul volume reale
/// (`/Volumes/SSD - Enri`) sarebbe **invisibile**, perche' li' non ci sono symlink ne'
/// la regola `/private`. Usare questa, mai `resolvingSymlinksInPath`.
///
/// Su un percorso inesistente `realpath` fallisce e si ripiega su `url.path`: e' il
/// caso di un file sparito fra l'enumerazione e la lettura. Innocuo, perche'
/// l'enumeratore restituisce gia' URL in forma `realpath` (misurato: con root
/// `/var/folders/.../SSD` produce `/private/var/...`).
// `nonisolated`: e' pura (una `realpath`) e viene chiamata anche dalla coda di lavoro di
// `FileSyncer`, non solo dal MainActor. Senza, il default `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor` la isola e ogni chiamata da un contesto nonisolated e' un warning (un errore in
// Swift 6).
nonisolated func realResolvedPath(_ url: URL) -> String {
    var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard let r = realpath(url.path, &buf) else { return url.path }
    return String(cString: r)
}

/// Identificativo del dispositivo (`st_dev`) su cui vive `url`, `nil` se `stat`
/// fallisce (percorso sparito).
///
/// E' l'UNICO dei tre candidati provati che rileva davvero lo scollegamento di un
/// volume esterno (misurato il 2026-08-26 su un'immagine exFAT staccata con
/// `hdiutil detach -force` a meta' scansione):
///
/// | candidato | esito |
/// |---|---|
/// | `FileManager.fileExists(atPath:)` | puo' rispondere `true` per secondi dopo lo scollegamento (smontaggio asincrono) |
/// | `URLResourceValues.volumeIdentifier` | invariato, Foundation lo serve dalla cache dell'URL |
/// | `st_dev` inizio vs fine | **cambia** (16777237 -> 16777230), oppure `stat` fallisce |
///
/// Per lo scollegamento di un volume esterno il rilevatore principale resta
/// l'`errorHandler` dell'enumeratore, che non dipende da nessun timing. Ma NON e'
/// una seconda cintura sempre e comunque: se la root sparisce o viene rinominata
/// mentre la scansione gira, l'`errorHandler` **non viene chiamato affatto**
/// (misurato il 2026-08-26 — i fallimenti finiscono in `progress.errors`, che non
/// concorre a `traversalIncomplete`). In quello scenario questo controllo e'
/// l'**unico** che impedisce di scambiare la traversata troncata per completa e di
/// rimuovere le entry non viste. E' il caso coperto da
/// `testRootRenamedDuringScan_...`.
/// Secondo consumatore dal 2026-08-31: `DuplicateTrasher`, che se ne serve per
/// distinguere «il file non c'era» da «il volume e' sparito a meta' blocco» — due
/// guasti che presentano lo **stesso** `NSCocoaErrorDomain/4`. Funzione libera e non
/// metodo privato di `LibraryIndexer` per non pagare una terza volta il prezzo gia'
/// pagato con `LibraryExclusions` e `realResolvedPath`: due copie della stessa logica
/// che divergono in silenzio.
nonisolated func deviceIdentifier(of url: URL) -> dev_t? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return info.st_dev
}

/// Miniatura leggera via ImageIO, **mai** l'immagine intera in memoria (stessa lezione del
/// bug di memoria di `sha256(of:)`). Nata come `BackupRunner.makeThumbnail` per la miniatura
/// live del file corrente (#17, 2026-08-09); estratta qui a funzione libera il 2026-08-31
/// perché il pannello Doppioni (Task 6, #31) ne ha bisogno anche per le miniature dei
/// gruppi, e questo progetto ha già pagato due volte il prezzo di due implementazioni della
/// stessa logica che divergono in silenzio (`LibraryExclusions`, `realResolvedPath`). Fonte
/// unica: nessun secondo `CGImageSourceCreateThumbnailAtIndex` da nessuna parte.
nonisolated func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cgThumb, size: .zero)
}

/// Componenti del percorso canonico di `url`, per confronti fra percorsi.
/// Il confronto va fatto per COMPONENTI, mai per lunghezza di stringa o con
/// `hasPrefix`: `/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`, ma lo e'
/// testualmente. Costo misurato: 12,6 us/file (20.000 file in 0,25s), cioe' nulla
/// rispetto alla lettura del file che segue.
func canonicalPathComponents(of url: URL) -> [String] {
    realResolvedPath(url).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// Percorso di `path` relativo a `rootComponents`, o `nil` se non ci sta sotto.
///
/// Il confronto e' **per componenti**, mai con `hasPrefix` su stringhe: `/Volumes/SSD` non e'
/// un prefisso di `/Volumes/SSD 2`, ma lo e' testualmente — stessa regola documentata su
/// `canonicalPathComponents`. Non usa `realpath`, cosi' funziona anche su un percorso di un
/// file che nel frattempo e' sparito; e' compito del chiamante passare le radici gia'
/// canonicalizzate se gli servono.
nonisolated func relativePath(of path: String, under rootComponents: [String]) -> String? {
    let comps = URL(fileURLWithPath: path).standardizedFileURL.path
        .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard comps.count > rootComponents.count,
          Array(comps.prefix(rootComponents.count)) == rootComponents else { return nil }
    return comps.dropFirst(rootComponents.count).joined(separator: "/")
}

enum FileKind {
    /// Usato dalle miniature (#17). Delega a `IndexableKind` invece di ripetere lo
    /// stesso `UTType(filenameExtension:)` + `conforms(to: .image)`: le due versioni
    /// erano gia' identiche, e tenerle separate significava che la prossima
    /// estensione di una sola delle due le avrebbe fatte divergere in silenzio —
    /// esattamente il problema che `LibraryExclusions` documenta.
    static func isImage(url: URL) -> Bool {
        IndexableKind.of(url: url) == .image
    }
}

/// Classificazione a tre vie per l'indice di contenuto (roadmap #31).
/// Sostituisce una lista di cartelle da escludere scritta a mano: la cartella "Zip"
/// resta fuori dall'indice perche' un archivio non e' ne' immagine ne' video, non
/// perche' si chiama cosi' — cosi' la regola regge anche per sorgenti future.
// `nonisolated` sul tipo: e' una classificazione pura per estensione, senza stato e senza
// UI, e serve sia al MainActor sia alla coda di lavoro di `FileSyncer` (la guardia in
// `isAlreadyInLibrary`). Isolarla al MainActor renderebbe un warning — un errore in Swift 6 —
// anche il solo confronto `!=`, che passa dalla conformance a `Equatable`.
nonisolated enum IndexableKind {
    case image
    case video
    case notIndexable

    /// Classifica per estensione via `UTType`. Limite noto e accettato: non ispeziona
    /// il contenuto, quindi un file con estensione errata/assente o un RAW di un modello
    /// non riconosciuto da macOS finisce in `.notIndexable`. Sbagliare per esclusione e'
    /// il verso sicuro: quel file non partecipa al dedup e viene copiato, mai saltato.
    static func of(url: URL) -> IndexableKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .notIndexable }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return .notIndexable
    }
}

/// Esito della valutazione di attendibilita' di una entry dell'indice.
enum IndexEntryVerdict {
    /// La entry e' attendibile: l'hash memorizzato vale.
    case fresh
    /// Il file e' certamente cambiato: rihashare.
    case stale
    /// Non possiamo escludere un cambiamento: rihashare prima di fidarci in un
    /// percorso ad alto danno (skip in import); accettabile fidarsi in segnalazione.
    case needsVerification
    /// L'mtime e' spostato di esattamente un'ora (o mezz'ora) e la dimensione e'
    /// identica: quasi certamente un cambio di fuso su ExFAT, non una modifica.
    /// Lo scanner adotta il nuovo mtime SENZA rihashare.
    ///
    /// Verdetto SEPARATO da `.needsVerification` di proposito. Quando i due erano
    /// lo stesso caso, la regola DST non faceva assolutamente nulla — entrambi
    /// portavano al rehash — e quindi non evitava affatto il "rihash dell'intera
    /// libreria due volte l'anno" che la spec le attribuisce come unico scopo.
    /// Trovato dal Critic il 2026-08-25.
    case timezoneShift
}

/// Decide se l'hash memorizzato per un file e' ancora attendibile.
///
/// La chiave (percorso, dimensione, mtime) NON e' una garanzia: `mtime` e' riscrivibile
/// da userspace (exiftool, `rsync -t`, restore da Finder). restic e borg si irrobustiscono
/// con inode e ctime, ma su ExFAT — il filesystem dell'SSD — l'inode non e' stabile
/// (documentato da Apple DTS) e quel rinforzo non e' disponibile.
///
/// ATTENZIONE, e' il punto che si fraintende piu' facilmente: **questa funzione non
/// difende dai tre vettori appena elencati**. exiftool, `rsync -t` e il restore da
/// Finder *preservano* l'mtime originale, quindi un file con contenuto diverso e
/// dimensione identica esce di qui come `.fresh`, ed e' corretto che sia cosi'.
/// L'unica difesa reale contro quel caso e' altrove: nel percorso di import il
/// candidato viene **riletto e rihashato** prima di saltare un file (ADR-0003,
/// `Docs/adr/0003-due-livelli-di-fiducia-sullo-stesso-indice.md`). Quella rilettura
/// sembra ridondante — l'indice ha gia' la risposta — e non lo e': e' la sola cosa
/// che impedisce a un hash stantio di far saltare in silenzio una foto diversa.
/// **Non rimuoverla in nome di questa funzione.**
///
/// Le due regole qui sotto servono a un problema diverso e piu' ristretto: contenere
/// i rihash inutili senza aprire buchi. Verificate empiricamente il 2026-08-25
/// (12 milioni di casi simulati: zero `.fresh` con hash stantio entro la granularita'
/// reale del filesystem; il buco si apre solo sopra i 2s di granularita').
///
/// 1. **Regola anti-racy**, presa da git e borg: se il file risulta modificato entro
///    `racyMarginSeconds` da quando ne abbiamo calcolato l'hash, non possiamo escludere
///    che sia cambiato subito dopo la lettura mantenendo lo stesso mtime.
///    Margine 2s e non 10ms: la granularita' misurata su macOS/ExFAT e' 10ms, ma la
///    spec ExFAT prevede 2 secondi e un'altra implementazione potrebbe esporli.
/// 2. **Tolleranza DST**: ExFAT memorizza i timestamp in ora locale, e uno studio forense
///    (DFRWS 2022) documenta divergenze fra implementazioni, macOS inclusa. Uno shift
///    esatto di 3600s o 1800s e' quasi certamente un cambio di fuso, non una modifica:
///    trattarlo come `stale` farebbe rihashare l'intera libreria due volte l'anno.
///    NOTA: questa seconda regola non ha prior art — e' una scelta di questo progetto.
func indexEntryVerdict(storedSize: Int64,
                       storedMTime: Double,
                       storedHashedAt: Double,
                       currentSize: Int64,
                       currentMTime: Double,
                       racyMarginSeconds: Double = 2.0) -> IndexEntryVerdict {
    // La dimensione ha sempre la precedenza: se cambia, il file e' cambiato.
    guard storedSize == currentSize else { return .stale }

    let delta = abs(currentMTime - storedMTime)
    // Tolleranza sulla granularita' ExFAT (10ms), con margine.
    let granularity = 0.05

    if delta <= granularity {
        // mtime invariato: resta solo il dubbio racy.
        return currentMTime >= storedHashedAt - racyMarginSeconds ? .needsVerification : .fresh
    }
    if abs(delta - 3600) <= granularity || abs(delta - 1800) <= granularity {
        // NOTA: qui la regola anti-racy del ramo sopra e' DELIBERATAMENTE sospesa, ed
        // e' l'unico verdetto fiducioso che ne fa a meno. Applicarla anche qui
        // ucciderebbe i cambi di fuso legittimi dei file hashati di recente: uno shift
        // in avanti sposta l'mtime *dopo* `hashedAt` per costruzione, quindi ogni
        // file con hashedAt entro ~1h dal proprio mtime finirebbe a rihashare — cioe'
        // proprio il rihash di massa che questa regola esiste per evitare.
        // Rischio accettato in ADR-0003: perche' sia un errore serve un file cambiato,
        // di dimensione identica AL BYTE, con mtime spostato di esattamente 1800s o
        // 3600s (+/-50ms). Misurato il 2026-08-25: 1 caso su ~37.000 modifiche reali.
        // E anche allora il danno resta confinato al percorso a BASSO danno, perche'
        // l'import rilegge e rihasha comunque il candidato prima di saltarlo.
        return .timezoneShift
    }
    return .stale
}

// MARK: - LibraryIndexStore

/// Una riga dell'indice di contenuto.
struct LibraryIndexEntry {
    /// Chiave normalizzata (NFC + minuscole), relativa alla root dell'SSD.
    let path: String
    /// Percorso come appare davvero su disco, per mostrarlo all'utente.
    let displayPath: String
    let size: Int64
    /// mtime LETTO DALL'SSD, mai quello della sorgente originale: la copia
    /// APFS -> ExFAT tronca a 10ms (misurato), quindi i due non coincidono mai.
    let mtime: Double
    let hash: String
    /// Istante in cui l'hash e' stato calcolato — serve alla regola anti-racy.
    let hashedAt: Double
}

/// Un insieme di entry dell'indice che condividono lo stesso hash: le copie
/// byte-identiche di uno stesso contenuto gia' presenti nella libreria.
///
/// Ha sempre **almeno due membri** e dimensione **maggiore di zero** — chi lo costruisce e'
/// `LibraryIndexStore.duplicateGroups()`, che esclude entrambi i casi (vedi li' il perche'
/// dei file da 0 byte).
struct DuplicateGroup {
    let hash: String
    /// La dimensione **minima** fra quelle dei membri, non la prima incontrata.
    ///
    /// Con un indice coerente le dimensioni dei membri coincidono — hash uguale significa
    /// contenuto uguale — ma l'indice e' una cache e un indice incoerente e' possibile
    /// (ADR-0002): questa invariante **non e' imposta da nessuna parte** e non va data per
    /// vera leggendo il tipo. In quel caso si espone deliberatamente la minima, perche' da
    /// qui esce lo spazio recuperabile scritto nel riepilogo che l'utente legge **prima**
    /// del bottone distruttivo: sottostimarlo e' innocuo, sovrastimarlo significa
    /// raccogliere un consenso su GB che non si libereranno.
    ///
    /// Il gruppo resta comunque visibile: scartarlo farebbe sparire in silenzio una coppia
    /// di doppioni veri per colpa di una terza riga avvelenata. L'incoerenza vera la
    /// intercetta chi cancella, che rilegge e rihasha ogni membro — la copia tenuta
    /// compresa — dallo stesso descrittore aperto e pretende unanimita' (ADR-0005).
    let size: Int64
    let members: [LibraryIndexEntry]
}

/// Normalizza un percorso relativo per usarlo come chiave dell'indice.
/// ExFAT e' case-insensitive/case-preserving e non normalizza l'Unicode; APFS preserva
/// la normalizzazione originale. Senza questo passaggio lo stesso file potrebbe
/// generare due entry distinte (NFC vs NFD, o maiuscole/minuscole diverse).
///
/// PRECONDIZIONE: `relativePath` e' il percorso **relativo alla root della libreria**,
/// come letto dal filesystem. La funzione canonicalizza la forma del percorso — via lo
/// slash iniziale, via i doppi slash, via i segmenti `.` — perche' altrimenti basterebbe
/// che un solo punto del codice costruisse la stringa in modo diverso (root con o senza
/// slash finale) per spostare **tutte** le chiavi: l'indice sembrerebbe vuoto e l'intera
/// libreria verrebbe rihashata, oppure si creerebbe una seconda copia di ogni entry.
/// Non tocca invece gli spazi ai bordi dei nomi (`"a.jpg "` resta diverso da `"a.jpg"`):
/// sono nomi di file legittimi e diversi, non varianti della stessa scrittura.
/// I segmenti `..` non vengono risolti: qui non arrivano mai, e risolverli a stringhe
/// significherebbe indovinare.
///
/// NOTA (nessun fix, e' voluto): `lowercased()` collassa i singleton canonici — K (U+212A
/// KELVIN), Å (U+212B ANGSTROM) e Ω (U+2126 OHM) producono la stessa chiave delle lettere
/// normali. Su ExFAT quei due file possono coesistere davvero, quindi la loro entry si
/// sovrascriverebbe a vicenda. La direzione dell'errore e' quella sicura: l'indice dimentica
/// un file (che verra' rihashato, o al peggio copiato una seconda volta), mai il contrario
/// — non produce mai uno skip sbagliato, perche' lo skip in import rilegge e rihasha
/// comunque il candidato (ADR-0003).
func normalizedIndexKey(_ relativePath: String) -> String {
    let folded = relativePath.precomposedStringWithCanonicalMapping.lowercased()
    return folded.split(separator: "/", omittingEmptySubsequences: true)
        .filter { $0 != "." }
        .joined(separator: "/")
}

// MARK: - Quale copia si tiene, e perche'

/// Il nome della cartella di primo livello che il job Mac -> SSD riempie: e' la libreria
/// principale, quella da cui partono i mirror su HDD e su Cubbit.
///
/// Scritto qui in forma di **chiave normalizzata** (NFC + minuscole) perche' e' cosi' che
/// lo si confronta. La stessa stringa compare come letterale nel job di copia
/// (`grep -n 'appendingPathComponent("Foto iPhone")'`): se un giorno quel nome cambia,
/// vanno cambiati entrambi i punti — qui e li'.
let mainLibraryFolderKey = normalizedIndexKey("Foto iPhone")

/// La cartella di primo livello dove atterrano gli import da schede e dischi
/// (`<SSD>/Import/<etichetta>`, roadmap #27-A). Stessa nota di sopra sul letterale.
let importFolderKey = normalizedIndexKey("Import")

/// Perche' la copia proposta e' quella proposta. Fa parte del risultato e non e' un
/// commento: la decisione 3 di Enrico chiede che la proposta sia **spiegata a parole**, e
/// una spiegazione ricostruita a posteriori dalla UI divergerebbe dalla regola alla prima
/// modifica di una delle due.
enum DuplicateKeepReason {
    /// Sta nella libreria principale, e le altre copie no.
    case mainLibrary
    /// Sta in una cartella organizzata a mano, e le altre copie stanno in un import.
    case notAnImport
    /// Nessuna delle due regole sopra discrimina: e' la piu' vecchia.
    case oldest
    /// Le copie si equivalgono su tutte le regole di prodotto. Non e' una preferenza:
    /// e' la garanzia che la proposta non cambi fra due aperture del pannello.
    case deterministicTieBreak
}

/// La copia che si propone di tenere, con il motivo.
struct DuplicateKeepChoice {
    let keeper: LibraryIndexEntry
    let reason: DuplicateKeepReason
    /// Quante copie restavano **indistinguibili** dopo tutte le regole di prodotto, la
    /// tenuta compresa. `1` significa che una regola ha deciso da sola; `> 1` che a
    /// scegliere e' stato il tie-break, cioe' un criterio che per l'utente non ha nessun
    /// contenuto.
    ///
    /// Serve alla spiegazione, e non e' un dettaglio interno: senza, la frase presenterebbe
    /// come motivata una scelta fatta a pari merito. Il caso concreto: due copie in
    /// `Foto iPhone/` e una fuori. Il motivo e' `.mainLibrary` ed e' vero, ma fra le due
    /// copie in libreria principale — di cui una finisce nel Cestino — ha deciso il
    /// tie-break, e la frase deve dirlo.
    let tiedCandidates: Int

    /// Le chiavi normalizzate dei membri rimasti in gara fino al tie-break, copia tenuta
    /// compresa: cioe' **quali** copie sono a pari merito, non solo quante.
    ///
    /// Aggiunto nel Task 6 (2026-08-31) per lo stesso motivo per cui `tiedCandidates` e'
    /// stato aggiunto nel Task 2: senza, la view non ha modo di dire *a quale riga* si
    /// riferisce «un'altra copia va bene quanto questa» in un gruppo di piu' di due membri —
    /// l'utente legge la frase davanti a piu' righe e non sa quale delle altre e' quella
    /// nominata. Nessun chiamante esistente costruisce `DuplicateKeepChoice` a mano (solo
    /// `duplicateKeepChoice` lo fa), quindi il campo e' additivo e non rompe niente a monte.
    let tiedPaths: Set<String>
}

/// La cartella di primo livello di una chiave, oppure `nil` per un file che sta nella
/// root della libreria.
///
/// Confronto **per componente**, mai `hasPrefix`: `Foto iPhone 2/` ha come prefisso
/// testuale `Foto iPhone` ma e' un'altra cartella, e con un `hasPrefix` le sue copie
/// verrebbero trattate come libreria principale — cioe' proposte per essere TENUTE al
/// posto di quelle vere. Stessa trappola, gia' pagata altrove nel progetto, per cui
/// `/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`.
///
/// Un file nella root non ha cartella: la sua unica componente e' il proprio nome, e un
/// file chiamato "Foto iPhone" non e' la libreria principale.
private func topLevelFolderKey(of key: String) -> String? {
    // `normalizedIndexKey` e' idempotente sulle chiavi dell'indice, che sono gia' NFC +
    // minuscole. Riapplicarlo costa nulla e rende la regola vera anche se un chiamante
    // futuro costruisse un gruppo da percorsi grezzi. Non si guarda MAI `displayPath`:
    // quello conserva maiuscole e forma Unicode originali, quindi confrontarlo
    // renderebbe la regola dipendente da come e' scritto il nome sul disco.
    let components = normalizedIndexKey(key).split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1 else { return nil }
    return String(components[0])
}

private func isInMainLibrary(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == mainLibraryFolderKey
}

private func isInImportFolder(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == importFolderKey
}

/// Sceglie quale copia di un gruppo di doppioni tenere, e dice perche'.
///
/// Funzione **pura**: nessun filesystem, nessun database, nessun ordine di input che conti.
/// Precedenza: libreria principale -> cartella organizzata invece che import -> la piu'
/// vecchia -> tie-break deterministico (percorso piu' corto, poi ordine della chiave).
/// Il motivo riportato e' quello dell'**ultima** regola che ha davvero discriminato: due
/// copie entrambe in `Foto iPhone/` non si distinguono per la prima regola, quindi la
/// scelta (e la frase mostrata all'utente) scende a quella dopo.
///
/// **Layout riconfermato e decisione chiusa il 2026-09-01**, col volume reale collegato.
/// `ls -1` dell'SSD ha dato esattamente il layout su cui la regola era stata scritta il
/// 2026-07-29/30, invariato: `Foto Google Drive`, `Foto iPhone`, `Other`, `Takeout`,
/// `Takeout 2`, `Zip`. La regola **non e' piu' provvisoria**.
///
/// **`Takeout/` e `Takeout 2/` restano alla pari delle altre cartelle** — decisione di
/// Enrico, presa col layout davanti (aveva rimandato la risposta 6 del 2026-08-28 proprio
/// a questo momento). L'argomento per declassarle accanto a `Import/`, che le stesure
/// precedenti di questo commento definivano "forte", e' **respinto**: sono due cartelle
/// distinte, e contengono le **copie originali** di foto estratte da Google. Una copia
/// esiste anche nel cloud, ma i file sull'SSD sono gli originali estratti, non uno scarico
/// rigenerabile. La loro origine automatica non dice niente sul valore del contenuto.
/// **Chi in futuro ripensasse di declassarle: la domanda e' gia' stata fatta e la risposta
/// e' no.** Fra `Takeout/` e `Takeout 2/` decidono quindi la data piu' vecchia e, a parita',
/// il tie-break — arbitrario ma deterministico, e innocuo perche' i membri di un gruppo
/// sono identici per definizione ed entrambe le cartelle sono mirrorate sull'HDD.
///
/// **Nota misurata sulla regola 2**: `Import/` **non esiste** sull'SSD reale (2026-09-01),
/// quindi `notAnImport` oggi non discrimina nulla. Va tenuta comunque — il wizard di #27-A
/// creera' quella cartella — ma chi legge i test non deve credere che sia lei a decidere.
/// Distribuzione reale dei 47.482 file media: `Foto iPhone` 18.180, `Takeout` 13.139,
/// `Takeout 2` 10.708, `Foto Google Drive` 3.947, `Other` 1.508.
///
/// La proposta resta comunque solo una proposta, che l'utente puo' cambiare gruppo per
/// gruppo prima di confermare.
///
/// **Questa funzione non verifica niente.** Percorsi, dimensioni e date vengono dall'indice,
/// che e' una cache e puo' essere stantia (ADR-0002): qui si sceglie *quale* copia proporre,
/// non si accerta che le copie siano davvero identiche. Nessun file puo' essere spostato nel
/// Cestino sulla sola base di questa scelta — a valle resta obbligatoria la rilettura e il
/// rihash di **ogni** membro del gruppo, la copia tenuta compresa, con esito unanime
/// (ADR-0005 e la sezione «La cancellazione — il percorso ad alto danno» della spec). E' la
/// funzione che nomina il sopravvissuto, quindi e' anche quella che un lettore frettoloso
/// scambierebbe per la validazione: non lo e'.
///
/// - Precondition: `group.members` ha **almeno due membri**. E' l'invariante di
///   `DuplicateGroup`, garantita dall'unico costruttore reale,
///   `LibraryIndexStore.duplicateGroups()`. Un gruppo ridotto a un membro solo dai filtri di
///   un chiamante futuro va **saltato**, non passato qui in cerca di una risposta: proporre
///   di "tenere" l'unica copia esistente e' una riga che nel pannello Doppioni dichiara
///   doppione un file che copie non ne ha.
func duplicateKeepChoice(_ group: DuplicateGroup) -> DuplicateKeepChoice {
    precondition(group.members.count > 1, "un gruppo di doppioni ha sempre almeno due membri")

    var candidates = group.members
    var reason = DuplicateKeepReason.deterministicTieBreak

    // Una regola "discrimina" solo se lascia in piedi qualcuno E scarta qualcun altro.
    // Senza la seconda condizione ogni regola sembrerebbe aver deciso — tutte le copie
    // nella libreria principale direbbero "la tengo perche' e' in libreria principale",
    // che non spiega perche' proprio quella.
    //
    // ATTENZIONE a cosa questo NON garantisce: che ne resti una sola. Una regola puo'
    // scartare qualcuno e lasciarne in gara due, e da li' in poi tutte le affermazioni
    // valgono sui **sopravvissuti**, non sul gruppo intero. La spiegazione deve tenerne
    // conto (vedi `tiedCandidates` e `duplicateKeepExplanation`): l'utente legge la frase
    // davanti al gruppo intero, righe delle altre copie comprese.
    func narrow(_ survivors: [LibraryIndexEntry], _ because: DuplicateKeepReason) {
        guard !survivors.isEmpty, survivors.count < candidates.count else { return }
        candidates = survivors
        reason = because
    }

    // 1. La libreria principale vince: e' la cartella che il job Mac -> SSD riscriverebbe
    //    comunque, e da cui partono i mirror su HDD e su Cubbit.
    narrow(candidates.filter(isInMainLibrary), .mainLibrary)
    // 2. Una cartella organizzata a mano batte uno scarico da scheda o disco.
    narrow(candidates.filter { !isInImportFolder($0) }, .notAnImport)
    // 3. A parita', la piu' vecchia: e' quella che l'utente ha da piu' tempo, e le copie
    //    piu' recenti sono quasi sempre il risultato di una ricopiatura.
    if let oldest = candidates.map(\.mtime).min() {
        narrow(candidates.filter { $0.mtime == oldest }, .oldest)
    }

    // 4. Tie-break. Non e' una regola di prodotto: e' cio' che impedisce alla proposta di
    //    cambiare fra due aperture del pannello a parita' di dati. Senza, l'ordine di
    //    arrivo dei membri deciderebbe quale foto finisce nel Cestino, e una proposta
    //    instabile e' una proposta di cui l'utente non puo' fidarsi.
    //    Lunghezza in **byte UTF-8** e non in grafemi: `String.count` dipende dalle regole
    //    di segmentazione della versione Unicode del runtime, `utf8.count` no. La proposta
    //    deve restare la stessa anche dopo un aggiornamento di macOS.
    let keeper = candidates.min { a, b in
        if a.path.utf8.count != b.path.utf8.count { return a.path.utf8.count < b.path.utf8.count }
        return a.path < b.path
    }
    // `min` restituisce nil solo su array vuoto, escluso dalla precondition; il fallback
    // esiste per non far dipendere da un `!` la funzione che decide cosa NON cestinare.
    return DuplicateKeepChoice(keeper: keeper ?? candidates[0],
                               reason: reason,
                               tiedCandidates: candidates.count,
                               tiedPaths: Set(candidates.map(\.path)))
}

/// Come si dice all'utente la scelta di `duplicateKeepChoice`.
///
/// Registro anti-gergo, come per `LibraryIndexStatus`: niente "hash", "indice", "SHA256",
/// "scansione". Chi legge questa frase sta per confermare uno spostamento nel Cestino, e
/// deve capire **quale** copia resta, **dove** sta e **quante** altre ce ne sono.
///
/// **Ogni affermazione qui dentro deve essere vera del gruppo che l'utente ha davanti**, non
/// della sola parte di gruppo su cui ha lavorato l'ultima regola. E' la trappola di questa
/// funzione, e ci e' gia' cascata una volta: `duplicateKeepChoice` restringe i candidati a
/// ogni regola, quindi "e' la piu' vecchia" poteva comparire accanto a un gruppo in cui la
/// copia piu' vecchia era una di quelle destinate al Cestino. Le frasi forti sono percio'
/// ricavate da **fatti ricalcolati sul gruppo intero** (`allOthersAreImports`,
/// `nothingIsOlder`), non dal solo `reason`, e a parita' si usa la variante debole.
///
/// Nemmeno il conteggio e' una certezza: viene dall'elenco delle foto, che e' l'ultima
/// fotografia presa del disco e non il disco (ADR-0002). Per questo la frase dice "risulta"
/// e nomina l'ultimo controllo, invece di affermare che le copie *sono* identiche: la verita'
/// la stabilisce la rilettura al momento della cancellazione, non questa riga.
///
/// - Precondition: `choice` e' la scelta **di questo** gruppo. I due argomenti sono
///   indipendenti e nessuno li lega: passare la scelta di un gruppo e i membri di un altro
///   produrrebbe un numero di copie plausibile accanto al file sbagliato, proprio nella
///   schermata che precede il bottone distruttivo.
func duplicateKeepExplanation(_ choice: DuplicateKeepChoice, in group: DuplicateGroup) -> String {
    precondition(group.members.contains { $0.path == choice.keeper.path },
                 "la copia tenuta non appartiene a questo gruppo")

    // Le altre copie si ricavano dal gruppo per differenza dalla tenuta: cosi' il numero
    // detto all'utente e il file nominato vengono per forza dalla stessa fonte.
    let others = group.members.filter { $0.path != choice.keeper.path }

    // La cartella si dice come e' scritta su disco (`displayPath`), non nella forma
    // minuscola della chiave: l'utente la deve poter ritrovare nel Finder.
    let folders = choice.keeper.displayPath.split(separator: "/", omittingEmptySubsequences: true).dropLast()
    let place = folders.isEmpty
        ? "direttamente sull'SSD, fuori da ogni cartella"
        : "in «\(folders.joined(separator: "/"))»"

    // Fatti ricalcolati sul gruppo intero, non dedotti dal motivo: sono loro a decidere se
    // la frase puo' essere forte ("tutte le altre", "nessun'altra") o deve restare debole.
    let allOthersAreImports = !others.isEmpty && others.allSatisfy(isInImportFolder)
    // `>=` e non `>`: se un'altra copia ha la **stessa** data, "nessun'altra e' piu' vecchia
    // di questa" resta vero, e la variante debole direbbe che esiste una copia piu' vecchia
    // che non esiste. La parita' di data fra doppioni non e' un caso di scuola: `cp -p`,
    // `rsync -t` e il restore da Finder preservano l'mtime.
    let nothingIsOlder = others.allSatisfy { $0.mtime >= choice.keeper.mtime }

    let lead: String
    switch choice.reason {
    case .mainLibrary:
        lead = "Tengo la copia che si trova \(place): è nella tua libreria principale, "
            + "quella che l'app riempie a ogni backup delle foto del Mac."
    case .notAnImport:
        lead = allOthersAreImports
            ? "Tengo la copia che si trova \(place): tutte le altre copie stanno in una cartella di scarico, "
                + "dove i file arrivano alla rinfusa da schede e dischi."
            : "Tengo la copia che si trova \(place): almeno un'altra copia sta in una cartella di scarico, "
                + "dove i file arrivano alla rinfusa da schede e dischi, e questa no."
    case .oldest:
        lead = nothingIsOlder
            ? "Tengo la copia che si trova \(place): ha la data più vecchia, nessun'altra copia è "
                + "più vecchia di questa."
            // "che questa app mette dopo" e non "che questa app considera meno affidabile":
            // l'ordine fra le cartelle e' una regola di questa app, dichiarata provvisoria in
            // attesa dell'`ls -1` dell'SSD, non un giudizio sulla cartella. Con la vecchia
            // formulazione a un utente che ha ordinato "Other/" a mano l'app diceva che la sua
            // cartella e' inaffidabile, sulla base di una regola che potrebbe cambiare.
            : "Tengo la copia che si trova \(place): ha la data più vecchia fra le copie che stanno "
                + "in cartelle altrettanto valide. Una copia più vecchia c'è, ma si trova in una "
                + "cartella che questa app mette dopo."
    case .deterministicTieBreak:
        // Qui la clausola del pari merito qui sotto non si aggiunge: il pari merito e' gia'
        // tutto il motivo, e ripeterlo due volte nella stessa frase la fa leggere peggio
        // proprio dove deve essere letta bene.
        lead = "Le copie si equivalgono: stanno in cartelle dello stesso tipo e hanno la stessa data. "
            + "Tengo quella che si trova \(place): a parità scelgo sempre la stessa, così la "
            + "proposta non cambia da un'apertura all'altra."
    }

    // A pari merito la scelta finale non ha nessun contenuto per l'utente, e va detto: e'
    // l'unico modo perche' "tengo questa perche' sta nella libreria principale" non suoni
    // come una ragione per cestinare l'altra copia che sta nella libreria principale.
    // Nessuna promessa sul percorso piu' corto: a lunghezze pari decide l'ordine
    // alfabetico, e il caso e' tutt'altro che raro (due scatti nella stessa cartella hanno
    // sempre nomi lunghi uguali).
    let equallyGood = choice.reason == .deterministicTieBreak ? 0 : max(0, choice.tiedCandidates - 1)
    let tie: String
    switch equallyGood {
    case 0: tie = ""
    case 1: tie = " Un'altra copia va bene quanto questa: a parità scelgo sempre la stessa, "
        + "così la proposta non cambia da un'apertura all'altra."
    default: tie = " Altre \(equallyGood) copie vanno bene quanto questa: a parità scelgo sempre la stessa, "
        + "così la proposta non cambia da un'apertura all'altra."
    }

    let copies: String
    switch others.count {
    // Irraggiungibile con le due precondition sopra (gruppo di almeno due membri, copia
    // tenuta che appartiene al gruppo). Resta perche' un ramo in piu' costa meno di una
    // frase falsa: `default` direbbe "Ci sono 0 altre copie".
    case ..<1: copies = " Non risultano altre copie di questo file."
    case 1: copies = " C'è 1 altra copia che risulta identica a questa, in base all'ultimo controllo delle foto sull'SSD."
    default: copies = " Ci sono \(others.count) altre copie che risultano identiche a questa, "
        + "in base all'ultimo controllo delle foto sull'SSD."
    }

    return lead + tie + copies
}

/// Quanti file al massimo si cestinano in un blocco solo.
///
/// Il numero **non** viene dalla durata: il cestinamento misura ~56 file/s, quindi 500 file
/// sono ~9 secondi, e il tempo vero se lo prende la rilettura che li precede. Viene dal
/// **raggio di un guasto a meta' blocco**, che la misura 3 della spec mostra essere uno
/// stato reale e non teorico: lo scollegamento dell'SSD a meta' produce lo stesso errore di
/// "file inesistente" (2672 casi indistinguibili misurati), quindi un blocco interrotto
/// lascia un registro di ripristino da leggere a mano. Piu' e' piccolo il blocco, meno c'e'
/// da rimettere a posto.
///
/// Prudente e **ritarabile alla prima passata reale con l'SSD collegato**: nessuno ha ancora
/// visto quanti doppioni ci siano davvero, e 500 potrebbe rivelarsi scomodo in eccesso.
let duplicateBatchFileCap = 500

/// Stesso ragionamento del tetto sui file, sull'altra grandezza che conta.
///
/// **Decimale** (50 × 1000⁴) e non binario, per coerenza con `ByteCountFormatter(.file)`,
/// che e' il modo in cui questa app scrive i byte all'utente ovunque: un tetto binario
/// scatterebbe a un numero diverso da quello mostrato nel riepilogo.
let duplicateBatchByteCap: Int64 = 50_000_000_000

/// Il blocco di doppioni che l'utente sta per confermare: quali gruppi, quale copia si
/// tiene di ognuno, quanti file si spostano, quanto spazio si libera e da quali cartelle.
///
/// E' la **prima delle due conferme** (decisione 4 di Enrico): il riepilogo dettagliato
/// viene prima della conferma vera. Il peso della conferma sta tutto qui — l'alert
/// distruttivo che segue e' corto per definizione, quindi se questo riepilogo e' vago non
/// c'e' alert che tenga.
///
/// **Congela la copia tenuta di ogni gruppo.** `duplicateKeepChoice` gira una volta sola,
/// qui, e il risultato viaggia dentro il blocco fino al `DuplicateTrasher`. Non e' un
/// dettaglio di efficienza: fra il riepilogo che l'utente legge e il cestinamento l'indice
/// puo' essere cambiato, e una scelta ricalcolata su dati nuovi puo' nominare **un'altra
/// copia** — l'utente acconsente a cestinare A e viene cestinato B. Chi consuma questo tipo
/// non deve mai ricalcolare la scelta: deve usare quella che trova qui dentro.
///
/// Logica **pura**: nessun filesystem, nessun database.
struct DuplicateBatch {

    /// Un gruppo insieme alla copia che si e' deciso di tenere. I due viaggiano appaiati
    /// proprio perche' non si possano disallineare.
    struct Entry {
        let group: DuplicateGroup
        let choice: DuplicateKeepChoice

        /// Le copie che se ne vanno: tutte tranne quella tenuta, ricavate **per differenza**
        /// e non con un `dropFirst()`. Nel Task 2 quella scorciatoia e' sopravvissuta a 31
        /// test perche' in ogni fixture la tenuta era il primo membro.
        var leaving: [LibraryIndexEntry] {
            group.members.filter { $0.path != choice.keeper.path }
        }

        /// `size × (copie − 1)`, mai `size × copie`: la copia che resta occupa comunque il
        /// suo spazio. E' l'errore aritmetico piu' facile della feature, ed e' un errore
        /// nella direzione pericolosa — promette all'utente piu' spazio di quanto ne
        /// arrivera'. La dimensione e' quella del gruppo, cioe' la **minima** fra i membri
        /// (vedi `DuplicateGroup.size`), per lo stesso motivo.
        var reclaimableBytes: Int64 {
            group.size * Int64(leaving.count)
        }
    }

    let groups: [Entry]
    /// I **file** che si spostano, non i gruppi: e' il numero che l'utente deve leggere.
    let fileCount: Int
    let reclaimableBytes: Int64
    /// Da quali cartelle se ne vanno, e quanti file per cartella. Solo le cartelle che
    /// **perdono** file: quella della copia tenuta non compare se da li' non esce niente.
    let folderBreakdown: [(folder: String, count: Int)]
    let exceedsCap: Bool

    init(groups: [DuplicateGroup]) {
        // La scelta si calcola qui, una volta, e da qui in poi non si ricalcola piu'.
        // I gruppi ridotti a un solo membro si scartano prima: `duplicateKeepChoice` ha una
        // precondition su almeno due membri, e questo e' il confine dove il filtro va messo
        // (non ammorbidendo la guardia).
        let entries = groups
            .filter { $0.members.count > 1 }
            .map { Entry(group: $0, choice: duplicateKeepChoice($0)) }

        // Ordine: spazio recuperabile decrescente, poi numero di copie decrescente, poi
        // l'hash. La terza chiave non e' decorativa: senza, due gruppi equivalenti sulle
        // prime due si disporrebbero secondo l'ordine di arrivo, e l'elenco che l'utente
        // spunta cambierebbe fra due aperture del pannello. Stessa lezione del tie-break
        // di `duplicateKeepChoice`.
        self.groups = entries.sorted { a, b in
            if a.reclaimableBytes != b.reclaimableBytes { return a.reclaimableBytes > b.reclaimableBytes }
            if a.group.members.count != b.group.members.count { return a.group.members.count > b.group.members.count }
            return a.group.hash < b.group.hash
        }

        self.fileCount = entries.reduce(0) { $0 + $1.leaving.count }
        self.reclaimableBytes = entries.reduce(0) { $0 + $1.reclaimableBytes }

        var perFolder: [String: Int] = [:]
        for entry in entries {
            for file in entry.leaving {
                perFolder[DuplicateBatch.folder(of: file), default: 0] += 1
            }
        }
        // A pari conteggio decide il nome: l'ordine di un dizionario non e' stabile fra due
        // esecuzioni, e un riepilogo che si riordina da solo e' un riepilogo di cui non ci
        // si fida.
        self.folderBreakdown = perFolder
            .map { (folder: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.folder < $1.folder }

        // Il primo dei due che scatta. `>` e non `>=`: alla soglia esatta il blocco passa.
        self.exceedsCap = self.fileCount > duplicateBatchFileCap
            || self.reclaimableBytes > duplicateBatchByteCap
    }

    /// La cartella che contiene il file, come e' scritta su disco: l'utente la deve poter
    /// ritrovare nel Finder, quindi `displayPath` e non la chiave minuscola.
    private static func folder(of entry: LibraryIndexEntry) -> String {
        let components = entry.displayPath.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return components.isEmpty ? "(sull'SSD, fuori da ogni cartella)" : components.joined(separator: "/")
    }

    /// Il testo del riepilogo. Puro, cosi' e' verificabile senza aprire la finestra.
    ///
    /// Registro anti-gergo come `LibraryIndexStatus` e `duplicateKeepExplanation`: niente
    /// "hash", "indice", "SHA256", "scansione". Chi legge sta per spostare le proprie foto.
    func summaryLines() -> [String] {
        // Un blocco vuoto lo dice. "0 file" seguito da una riga sul Cestino sarebbe una
        // schermata che chiede di confermare il nulla.
        guard fileCount > 0 else {
            return ["Non c'è niente da spostare: non hai selezionato nessun gruppo di copie."]
        }

        var out: [String] = []

        out.append("Sposto nel Cestino \(DuplicateBatch.count(fileCount, "file", "file")), "
            + "tenendo una copia di ognuna delle \(DuplicateBatch.count(groups.count, "foto", "foto")) interessate.")

        out.append("Si libereranno circa "
            + "\(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)), "
            + "ma solo quando svuoti il Cestino: fino a quel momento i file restano sul disco e "
            + "lo spazio non torna disponibile.")

        // Le cartelle che perdono file: e' l'informazione che permette di accorgersi in
        // tempo che si sta per svuotare la cartella sbagliata.
        for riga in folderBreakdown {
            out.append("Da «\(riga.folder)»: \(DuplicateBatch.count(riga.count, "file", "file")).")
        }

        out.append("Le copie che stanno sull'HDD e su Cubbit restano dove sono: questa operazione "
            + "tocca soltanto l'SSD.")

        if exceedsCap {
            out.append("Hai selezionato troppi file in una volta sola. Togli qualche gruppo e "
                + "procedi in più passaggi: se qualcosa va storto a metà, un blocco più piccolo "
                + "è molto più facile da rimettere a posto.")
        }

        return out
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

/// Una foto spostata nel Cestino, con tutto il necessario per rimetterla al suo posto.
///
/// `hash` e `size` non sono decorativi: sono il patto fra il momento del cestinamento e
/// quello dell'annullamento. Ripristinare senza riverificarli significherebbe rimettere al
/// posto della foto dell'utente un file che nel frattempo e' diventato un altro file.
struct TrashedItem: Codable, Equatable {
    /// Tutti gli item cestinati nello stesso blocco condividono questo identificatore: e'
    /// cio' che rende «Annulla l'ultimo spostamento» un'operazione su un blocco e non su un
    /// file solo.
    var batchId: String
    /// Il percorso originale come era scritto su disco: e' li' che il file deve tornare.
    var originalDisplayPath: String
    /// La chiave normalizzata corrispondente, per rimettere la riga nell'indice.
    var originalKey: String
    var trashedPath: String
    var size: Int64
    var hash: String
    var trashedAt: Date
}

/// Perche' una voce non e' stata rimessa al suo posto. Ogni caso ha una frase propria:
/// l'utente che preme «Annulla» e non vede tornare tutto deve poter capire quale dei motivi
/// lo riguarda, e cosa puo' farci.
enum RestoreSkipReason: Equatable {
    /// Il file non e' piu' nel Cestino: quasi sempre il Cestino e' stato svuotato.
    case missingInTrash
    /// Il file nel Cestino non e' piu' quello che ci era stato messo.
    case alteredInTrash
    /// Al posto originale c'e' di nuovo qualcosa: non si sovrascrive mai.
    case originalPathOccupied
    /// Lo spostamento e' fallito per un motivo del filesystem.
    case moveFailed(String)

    var explanation: String {
        switch self {
        case .missingInTrash:
            return "Questa foto non è più nel Cestino: probabilmente il Cestino è stato svuotato. "
                + "Una volta svuotato, l'app non può più rimetterla a posto."
        case .alteredInTrash:
            return "La foto che si trova nel Cestino non è più identica a quella che era stata "
                + "spostata, quindi l'app non la rimette al suo posto: preferisce lasciarla dov'è "
                + "e fartelo sapere."
        case .originalPathOccupied:
            return "Al posto di questa foto c'è di nuovo un file con lo stesso nome. L'app non "
                + "sovrascrive mai niente, quindi ha lasciato tutto com'è: la copia nel Cestino "
                + "è ancora lì e puoi spostarla a mano dove preferisci."
        case .moveFailed(let dettaglio):
            return "Non è stato possibile rimettere a posto questa foto (\(dettaglio)). "
                + "La copia nel Cestino non è stata toccata."
        }
    }
}

struct RestoreOutcome {
    var restored: [TrashedItem] = []
    var skipped: [(item: TrashedItem, reason: RestoreSkipReason)] = []
}

/// Il contenuto del registro su disco.
struct TrashManifest: Codable {
    /// Quante voci sono state registrate in tutto. Resta veritiero anche quando `items` e'
    /// stata potata dal tetto: e' questo il numero da mostrare, `items.count` non lo e'.
    /// Stessa forma di `UnverifiedCopies.totalCount`, per lo stesso motivo.
    var totalRecorded: Int = 0
    var items: [TrashedItem] = []
}

extension TrashManifest {
    private enum CodingKeys: String, CodingKey { case totalRecorded, items }

    /// `init(from:)` esplicita con `decodeIfPresent`, **obbligatoria** su ogni tipo
    /// persistito di questo progetto: i default sulle proprieta' non li usa la decodifica
    /// sintetizzata, che lancia `keyNotFound` (fatto misurato n. 5 di #31). Qui il prezzo di
    /// sbagliare e' piu' alto che altrove — un campo aggiunto in una versione futura
    /// farebbe sparire in silenzio **il registro di ripristino**, cioe' la rete di sicurezza
    /// della sola operazione distruttiva dell'app.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRecorded = try c.decodeIfPresent(Int.self, forKey: .totalRecorded) ?? 0
        items = try c.decodeIfPresent([TrashedItem].self, forKey: .items) ?? []
    }
}

extension TrashedItem {
    private enum CodingKeys: String, CodingKey {
        case batchId, originalDisplayPath, originalKey, trashedPath, size, hash, trashedAt
    }

    /// Stessa ragione del tipo contenitore. Qui la decodifica e' **tollerante sui campi
    /// accessori e severa su quelli portanti**: senza `trashedPath`, `size` o `hash` la voce
    /// non e' ripristinabile in sicurezza e non deve entrare nel registro fingendo di
    /// esserlo. `originalKey` invece degrada: serve a rimettere la riga nell'indice, e un
    /// indice incompleto si ricostruisce da solo.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batchId = try c.decodeIfPresent(String.self, forKey: .batchId) ?? ""
        originalDisplayPath = try c.decode(String.self, forKey: .originalDisplayPath)
        originalKey = try c.decodeIfPresent(String.self, forKey: .originalKey) ?? ""
        trashedPath = try c.decode(String.self, forKey: .trashedPath)
        size = try c.decode(Int64.self, forKey: .size)
        hash = try c.decode(String.self, forKey: .hash)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Il registro di ripristino del pannello Doppioni, e l'annullamento che ne dipende.
///
/// **Perche' non ci si appoggia al Finder.** Il record «Rimetti a posto» che macOS scrive
/// quando un file finisce nel Cestino e' scritto in modo **asincrono**: misurato che si
/// perde se il processo muore subito dopo (226/300 e 85/100 in due misure indipendenti;
/// 100/100 solo col processo vivo). Delegargli l'annullamento significherebbe che, proprio
/// nel caso in cui serve — un guasto a meta' blocco — non c'e' piu' nessuna traccia di dove
/// stessero le foto.
///
/// Da cui la regola di questa classe: **`record` scrive subito**, una voce alla volta. Un
/// registro bufferizzato e salvato a fine blocco avrebbe esattamente lo stesso difetto di
/// quello che sta sostituendo.
final class TrashManifestStore {

    enum StoreError: Error, LocalizedError {
        case invalidLocation(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation(let p): return "Posizione non consentita per il registro: \(p)"
            }
        }
    }

    /// Tetto alle voci conservate. Sopra questo numero si potano le **piu' vecchie**: le
    /// piu' recenti sono le sole per cui l'annullamento ha ancora senso. `totalRecorded`
    /// resta a parte, cosi' il numero mostrato non mente a lista troncata.
    static let maxItems = 2000

    private let url: URL
    private var manifest: TrashManifest
    /// `record` puo' arrivare dalla coda di lavoro del `DuplicateTrasher` mentre la UI
    /// legge `lastBatch()`: e' un leggi-modifica-scrivi, e senza lock due cestinamenti
    /// ravvicinati ne perderebbero uno — cioe' un file nel Cestino senza voce nel registro,
    /// il caso peggiore per una rete di sicurezza.
    private let lock = NSLock()

    init(url: URL) throws {
        // Stessa allow-list di `LibraryIndexStore`, non una seconda: il registro nomina i
        // percorsi delle foto e non deve mai finire sul volume sorgente.
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Un registro illeggibile riparte da vuoto e resta usabile: bloccare l'app su un
        // file corrotto toglierebbe anche la possibilita' di registrare i cestinamenti
        // futuri. Stessa disciplina di `LibraryIndexStore` su `SQLITE_NOTADB`.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(TrashManifest.self, from: data) {
            manifest = decoded
        } else {
            manifest = TrashManifest()
        }
    }

    var totalRecorded: Int { lock.withLock { manifest.totalRecorded } }
    var itemCount: Int { lock.withLock { manifest.items.count } }

    /// Registra una voce e **la scrive su disco prima di tornare**.
    func record(_ item: TrashedItem) throws {
        try lock.withLock {
            manifest.items.append(item)
            manifest.totalRecorded += 1
            // Si potano le piu' vecchie, mai le piu' recenti: `suffix` e non `prefix`.
            if manifest.items.count > Self.maxItems {
                manifest.items = Array(manifest.items.suffix(Self.maxItems))
            }
            try writeUnsynchronized()
        }
    }

    /// Le voci dell'ultimo blocco registrato — quello che «Annulla l'ultimo spostamento»
    /// rimette a posto. L'ultimo e' quello **registrato per ultimo**, non quello con la data
    /// piu' alta: due blocchi possono condividere l'istante, l'ordine di scrittura no.
    func lastBatch() -> [TrashedItem] {
        lock.withLock {
            guard let ultimo = manifest.items.last?.batchId else { return [] }
            return manifest.items.filter { $0.batchId == ultimo }
        }
    }

    /// Rimette al loro posto le voci indicate. Non lancia mai: ogni voce che non si riesce a
    /// ripristinare finisce fra gli `skipped` **con il motivo**, e le altre proseguono. Una
    /// voce rotta che interrompesse il ciclo lascerebbe l'annullamento a meta' senza dirlo.
    func restore(_ items: [TrashedItem]) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        let fm = FileManager.default

        for item in items {
            let trashed = URL(fileURLWithPath: item.trashedPath)
            let original = URL(fileURLWithPath: item.originalDisplayPath)

            guard fm.fileExists(atPath: trashed.path) else {
                outcome.skipped.append((item, .missingInTrash)); continue
            }

            // Zero-overwrite, che vale anche in questa direzione. La guardia e' **nostra** e
            // non si delega al rifiuto di `moveItem` (misurato `NSCocoaErrorDomain/516`):
            // due implementazioni della stessa regola divergono, e questa e' la regola piu'
            // importante del progetto.
            guard !fm.fileExists(atPath: original.path) else {
                outcome.skipped.append((item, .originalPathOccupied)); continue
            }

            // Si rilegge e si riverifica **prima** di spostare: il file nel Cestino puo'
            // essere stato modificato da quando ce l'abbiamo messo, e rimettere al posto
            // della foto dell'utente un file diverso sarebbe una sostituzione silenziosa.
            // Dimensione e hash vengono dallo **stesso descrittore aperto** (`sha256Measured`).
            guard let measured = sha256Measured(of: trashed),
                  measured.hash == item.hash, measured.size == item.size else {
                outcome.skipped.append((item, .alteredInTrash)); continue
            }

            do {
                // Le cartelle intermedie possono essere state cancellate fra il cestinamento
                // e l'annullamento: senza ricrearle il ripristino fallirebbe proprio nel
                // caso in cui l'utente ha fatto pulizia e vuole tornare indietro.
                try fm.createDirectory(at: original.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: trashed, to: original)
                outcome.restored.append(item)
            } catch {
                outcome.skipped.append((item, .moveFailed(error.localizedDescription)))
            }
        }
        return outcome
    }

    private func writeUnsynchronized() throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        // `0600` come l'indice, e per lo stesso motivo: il file non contiene foto, ma
        // contiene i **percorsi** di tutte le foto toccate, in chiaro. Best-effort — un
        // registro scritto e' piu' importante di un registro con i permessi giusti.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Il motore di cancellazione

/// Perche' un gruppo di doppioni non e' stato smaltito. Ogni caso ha una frase propria: chi
/// vede un gruppo restare nell'elenco dopo aver confermato deve capire se il problema e'
/// suo, del disco o dell'indice — e cosa puo' farci. Stessa disciplina di
/// `RestoreSkipReason`.
enum DuplicateTrashSkipReason: Equatable {
    /// Un membro — la copia tenuta compresa — non ha piu' lo stesso contenuto degli altri.
    case contentDisagrees(displayPath: String)
    /// Un membro non e' stato rileggibile: sparito, illeggibile, o cambiato durante la lettura.
    case unreadable(displayPath: String)
    /// Un membro ha una dimensione diversa da quella indicizzata.
    case sizeChanged(displayPath: String)
    /// Un membro risolve fuori dalla root della libreria.
    case outsideLibrary(displayPath: String)
    /// Un membro non e' una foto ne' un video.
    case notMedia(displayPath: String)
    /// Il gruppo si e' ridotto a una copia sola: non c'e' niente da cestinare.
    case nothingToTrash
    /// Il cestinamento e' fallito con il volume ancora al suo posto.
    case trashFailed(displayPath: String, detail: String)
    /// La copia da tenere e' sparita a cestinamento gia' iniziato: quanto era stato
    /// spostato e' stato rimesso a posto.
    case keeperVanished(displayPath: String)

    var explanation: String {
        switch self {
        case .contentDisagrees(let p):
            return "Le copie di questo gruppo non sono più identiche fra loro (\(p) è cambiata). "
                + "Non è stato spostato niente: l'app cancella solo quando ogni copia, inclusa "
                + "quella che resta, si rilegge uguale alle altre."
        case .unreadable(let p):
            return "Non è stato possibile rileggere \(p), quindi il gruppo è stato lasciato "
                + "intatto. L'app non cestina mai «quelle che è riuscita a verificare»."
        case .sizeChanged(let p):
            return "La dimensione di \(p) non coincide più con quella registrata: il gruppo è "
                + "stato lasciato intatto."
        case .outsideLibrary(let p):
            return "Il percorso \(p) risolve fuori dalla cartella della libreria: l'app non "
                + "tocca niente che stia fuori."
        case .notMedia(let p):
            return "\(p) non è una foto né un video, quindi non viene mai cestinato."
        case .nothingToTrash:
            return "Di questo gruppo è rimasta una copia sola: non c'era niente da spostare."
        case .trashFailed(let p, let dettaglio):
            return "Non è stato possibile spostare \(p) nel Cestino (\(dettaglio)). "
                + "Il gruppo è stato chiuso qui; quanto era già stato spostato resta annullabile."
        case .keeperVanished(let p):
            return "La copia da tenere (\(p)) è sparita mentre il gruppo veniva smaltito. "
                + "Le copie appena spostate sono state rimesse al loro posto: non sei rimasto "
                + "senza nessuna copia."
        }
    }
}

/// L'esito di un blocco. `trashedFiles` e' il numero **onesto** di file spostati, anche
/// quando il blocco si e' interrotto a meta': e' quello che va mostrato, non il numero di
/// file che si era chiesto di smaltire.
struct DuplicateTrashOutcome {
    var trashedFiles: [TrashedItem] = []
    var skippedGroups: [(group: DuplicateGroup, reason: DuplicateTrashSkipReason)] = []
    /// Il volume e' sparito a meta' blocco: si e' fermato tutto, non solo il gruppo.
    var stoppedBecauseVolumeVanished: Bool = false
    /// L'utente ha interrotto. Un blocco parziale e' uno stato legittimo, va detto.
    var interrupted: Bool = false
}

// MARK: - Righe di stato del pannello Doppioni (Task 6, 2026-08-31)

/// Cosa dire in cima al pannello Doppioni, perche' la cancellazione e' disattivata in questo
/// momento, e come si racconta l'esito di un blocco appena smaltito. Logica **pura**,
/// verificabile senza aprire la finestra — stessa disciplina di `LibraryIndexStatus` e di
/// `duplicateKeepExplanation`: niente "hash", "indice", "SHA256", "entry", "scansione".
enum DuplicatesStatus {
    enum Tone { case ok, info, warning }

    struct Line: Identifiable {
        /// Identita' stabile, non un UUID: le righe si ricalcolano a ogni ridisegno.
        let id: String
        let tone: Tone
        let text: String
    }

    /// La riga in cima al pannello. Non e' la lista dei gruppi: e' quello che l'utente legge
    /// aprendo la finestra, prima di scorrere qualunque cosa.
    ///
    /// `indexBuilt == false` **deve** rimandare alla card, mai leggersi come "non hai
    /// doppioni": e' la stessa classe di errore gia' corretta con `sawNothing` in #31 — un
    /// elenco che non esiste e un elenco costruito e vuoto sono due situazioni opposte.
    static func headerLine(indexBuilt: Bool, groupCount: Int, reclaimableBytes: Int64) -> Line {
        guard indexBuilt else {
            return Line(id: "no-index", tone: .info, text:
                "Non hai ancora creato l'elenco delle foto già salvate sull'SSD. Vai in "
                + "Diagnostica → «Foto già salvate sull'SSD» e crealo da lì, poi torna qui.")
        }
        guard groupCount > 0 else {
            return Line(id: "zero-groups", tone: .ok, text:
                "In base all'ultimo controllo dell'elenco, non ci sono copie doppie da smaltire "
                + "sull'SSD.")
        }
        return Line(id: "groups", tone: .info, text:
            "In base all'ultimo controllo dell'elenco risultano "
            + "\(count(groupCount, "gruppo di copie doppie", "gruppi di copie doppie")), per circa "
            + "\(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)) "
            + "recuperabili sull'SSD.")
    }

    /// Perche' il bottone di cancellazione e' disattivato adesso. `nil` = niente lo impedisce
    /// da qui (restano comunque le due conferme). Stessa disciplina di `RestoreView`: un
    /// bottone disattivato dice sempre perche', non un semplice grigiore.
    static func trashDisabledReason(isRunning: Bool, isIndexing: Bool, ssdMounted: Bool) -> String? {
        guard ssdMounted else {
            return "L'SSD non è collegato in questo momento: senza, l'app non può né "
                + "riverificare né spostare niente."
        }
        guard !isRunning else {
            return "C'è un backup in corso: aspetta che finisca prima di smaltire le copie "
                + "doppie."
        }
        guard !isIndexing else {
            return "L'elenco delle foto già salvate si sta aggiornando in questo momento: "
                + "aspetta che finisca."
        }
        return nil
    }

    /// Se il blocco selezionato puo' procedere alla conferma vera. Sopra il tetto la UI lo
    /// dice invece di rifiutare senza spiegare (deciso il 2026-08-28).
    static func confirmationBlockedReason(exceedsCap: Bool) -> String? {
        guard exceedsCap else { return nil }
        return "Hai selezionato troppi file in una volta sola: procedi in più passaggi più "
            + "piccoli, così un eventuale intoppo a metà resta facile da rimettere a posto."
    }

    /// Come si racconta l'esito di un blocco appena smaltito: mai un silenzio, sempre un
    /// numero onesto — sia sui file gia' spostati sia sui gruppi rimasti intatti.
    static func outcomeLines(_ outcome: DuplicateTrashOutcome) -> [Line] {
        var out: [Line] = []

        if outcome.stoppedBecauseVolumeVanished {
            out.append(Line(id: "volume-vanished", tone: .warning, text:
                "L'SSD si è scollegato mentre spostavo le copie, quindi mi sono fermato subito: "
                + "\(count(outcome.trashedFiles.count, "file era già stato spostato nel Cestino", "file erano già stati spostati nel Cestino")) "
                + "prima dello stop."))
        }
        if outcome.interrupted {
            out.append(Line(id: "interrupted", tone: .info, text:
                "Hai fermato tu lo spostamento: "
                + "\(count(outcome.trashedFiles.count, "file è stato spostato nel Cestino", "file sono stati spostati nel Cestino")) "
                + "prima che ti fermassi."))
        }
        if !outcome.skippedGroups.isEmpty {
            out.append(Line(id: "skipped-count", tone: .warning, text:
                "\(count(outcome.skippedGroups.count, "gruppo non è stato smaltito", "gruppi non sono stati smaltiti")): "
                + "trovi il motivo di ciascuno qui sotto."))
            for (index, skipped) in outcome.skippedGroups.enumerated() {
                out.append(Line(id: "skipped-\(index)", tone: .warning, text: skipped.reason.explanation))
            }
        }
        // Nessun problema da segnalare, ma qualcosa e' comunque successo: un esito pulito lo
        // dice, non resta muto.
        if out.isEmpty, !outcome.trashedFiles.isEmpty {
            out.append(Line(id: "done", tone: .ok, text:
                "Fatto: \(count(outcome.trashedFiles.count, "file spostato nel Cestino", "file spostati nel Cestino"))."))
        }
        return out
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

/// Cache delle miniature del pannello Doppioni: una per gruppo, letta dal file tenuto, pigra.
/// Tetto fisso: senza, scorrere centinaia di gruppi terrebbe in RAM altrettante `NSImage` — su
/// questo progetto una lettura senza tetto e' gia' costata 41 GB una volta (bug di
/// `sha256(of:)`, 2026-07-30). Thread-safe: le richieste arrivano da `.task` di righe diverse
/// della `LazyVStack`, potenzialmente in corse concorrenti fra loro.
final class DuplicateThumbnailCache {
    static let defaultCapacity = 200

    private let capacity: Int
    private let lock = NSLock()
    /// Ordine di uso: il primo elemento e' il piu' vecchio, il prossimo a essere sfrattato.
    private var order: [String] = []
    private var images: [String: NSImage] = [:]

    init(capacity: Int = DuplicateThumbnailCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func image(for key: String) -> NSImage? {
        lock.withLock { images[key] }
    }

    func insert(_ image: NSImage, for key: String) {
        lock.withLock {
            if let existingIndex = order.firstIndex(of: key) { order.remove(at: existingIndex) }
            order.append(key)
            images[key] = image
            // Si sfratta la piu' vecchia, mai una a caso: `removeFirst` sull'ordine di uso,
            // non sull'ordine del dizionario (che in Swift non e' garantito).
            while order.count > capacity {
                let oldest = order.removeFirst()
                images.removeValue(forKey: oldest)
            }
        }
    }

    var count: Int { lock.withLock { images.count } }
}

/// L'unico componente del progetto che sposta un file foto.
///
/// Due invarianti che i test blindano, perche' sono quelle che un'ottimizzazione futura
/// romperebbe per prime:
///
/// - **L'unico modo in cui questo codice tocca un file foto e' `trashItem`.** Mai
///   `removeItem`, in nessun ramo, nemmeno di errore. Mai una scrittura dentro `.Trashes`.
///   Mai uno svuotamento del Cestino. Coperto da `testNoOpTrashFunction_leavesEveryFileOnDisk`.
/// - **La copia tenuta non viene mai passata a `trashItem`.** Coperto da
///   `testKeeperIsNeverPassedToTrash`.
///
/// `trashFunction` e `hashFunction` hanno per default le funzioni reali e sono iniettate
/// **solo dai test**: gli esiti da coprire (un hash che cambia fra la visualizzazione e la
/// cancellazione, uno scollegamento a meta' blocco) non sono producibili su file veri senza
/// una corsa fra thread, e un test basato su una corsa e' verde col bug ogni volta che la
/// corsa va nell'altro verso. Stesso pattern gia' in `FileSyncer.init(hashFunction:)`.
final class DuplicateTrasher {

    /// Cio' che l'utente ha confermato: il gruppo **e** la copia che resta, congelati
    /// insieme al momento della conferma.
    ///
    /// La copia tenuta arriva da fuori e non viene mai ricalcolata qui. Fra il riepilogo che
    /// l'utente legge e il cestinamento l'indice puo' essere cambiato, e una
    /// `duplicateKeepChoice` ricalcolata su dati nuovi puo' nominare **un'altra copia**:
    /// l'utente acconsente a cestinare A e viene cestinato B. La `precondition` di
    /// appartenenza dentro `duplicateKeepExplanation` non intercetta quel caso, perche'
    /// confronta solo il `path`.
    struct Decision {
        let group: DuplicateGroup
        let keeper: LibraryIndexEntry
    }

    private let libraryRoot: URL
    private let store: LibraryIndexStore
    private let manifest: TrashManifestStore
    private let trashFunction: (URL) throws -> URL?
    private let hashFunction: (URL) -> MeasuredHash?
    /// Le due forme canoniche della root, calcolate una volta. Stessa coppia usata da
    /// `isAlreadyInLibrary`: la root puo' essere raggiunta per symlink.
    private let rootForms: [[String]]

    init(libraryRoot: URL,
         store: LibraryIndexStore,
         manifest: TrashManifestStore,
         trashFunction: @escaping (URL) throws -> URL? = { url in
             var resulting: NSURL?
             try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
             return resulting as URL?
         },
         hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) }) {
        self.libraryRoot = libraryRoot
        self.store = store
        self.manifest = manifest
        self.trashFunction = trashFunction
        self.hashFunction = hashFunction
        self.rootForms = [libraryRoot.standardizedFileURL.path, realResolvedPath(libraryRoot)].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
    }

    /// Smaltisce un blocco di gruppi gia' confermati, nell'ordine della sequenza «percorso
    /// ad alto danno» della spec. Non lancia mai: ogni gruppo che non si puo' smaltire
    /// finisce fra gli `skippedGroups` con il motivo, e gli altri proseguono.
    ///
    /// `onProgress` (Task 6, 2026-08-31): quanti gruppi sono stati **processati** (smaltiti o
    /// saltati che siano) sul totale del blocco, per la barra di avanzamento della finestra.
    /// Default no-op, stesso pattern di `FileSyncer.onProgress`: nessun chiamante dei Task 1-5
    /// lo passa, e i loro test restano verdi senza modifiche.
    func run(_ decisions: [Decision],
             batchId: String = UUID().uuidString,
             onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in },
             isCancelled: () -> Bool = { false }) -> DuplicateTrashOutcome {
        var outcome = DuplicateTrashOutcome()
        // `st_dev` della root letto una volta prima di iniziare. Senza questo valore
        // «il file non c'era» e «il volume e' sparito» restano indistinguibili: presentano
        // lo stesso `NSCocoaErrorDomain/4`.
        let deviceAtStart = deviceIdentifier(of: libraryRoot)

        for (index, decision) in decisions.enumerated() {
            // Un'interruzione lascia un blocco parziale: e' uno stato legittimo, e i gruppi
            // gia' chiusi restano chiusi.
            if isCancelled() {
                outcome.interrupted = true
                break
            }
            // Il gruppo che sta per essere processato conta come "fatto" alla fine di questa
            // iterazione, qualunque sia l'esito (smaltito, saltato, o interrotto a meta' dallo
            // scollegamento): la barra di avanzamento misura quanto lavoro e' stato fatto, non
            // quanti gruppi sono stati smaltiti con successo.
            defer { onProgress(index + 1, decisions.count) }

            let group = decision.group
            guard group.members.contains(where: { $0.path != decision.keeper.path }) else {
                outcome.skippedGroups.append((group, .nothingToTrash))
                continue
            }

            // Si rilegge e si rihasha OGNI membro, la copia tenuta compresa, e si pretende
            // unanimita'. Rileggere solo i file da cestinare direbbe che sono uguali fra
            // loro, non che sono uguali a quello che resta.
            let resolved: [(entry: LibraryIndexEntry, url: URL)]
            switch verify(group) {
            case .skip(let reason):
                outcome.skippedGroups.append((group, reason))
                continue
            case .ok(let members):
                resolved = members
            }

            guard let keeperURL = resolved.first(where: { $0.entry.path == decision.keeper.path })?.url else {
                // La copia tenuta non e' fra i membri del gruppo: la coppia e' incoerente e
                // non si tocca niente, invece di indovinare quale tenere.
                outcome.skippedGroups.append((group, .keeperVanished(displayPath: decision.keeper.displayPath)))
                continue
            }

            var trashedInGroup: [TrashedItem] = []
            var groupFailure: DuplicateTrashSkipReason?
            var volumeVanished = false

            for (entry, url) in resolved where entry.path != decision.keeper.path {
                do {
                    let resultingURL = try trashFunction(url)
                    // Percorso **assoluto**: e' quello che `TrashManifestStore.restore`
                    // riapre con `URL(fileURLWithPath:)` per rimettere il file al suo posto.
                    // Il `displayPath` dell'indice e' relativo alla root e li' non serve;
                    // la sua forma normalizzata viaggia a parte, in `originalKey`.
                    let item = TrashedItem(batchId: batchId,
                                           originalDisplayPath: url.path,
                                           originalKey: entry.path,
                                           trashedPath: resultingURL?.path ?? "",
                                           size: entry.size,
                                           hash: group.hash,
                                           trashedAt: Date())
                    // Registrato SUBITO, prima di passare al file successivo. Un registro
                    // scritto a fine blocco si perderebbe proprio nel caso in cui serve — un
                    // guasto a meta' — che e' il difetto misurato del record del Finder.
                    // Se la scrittura fallisce si finisce nel `catch`: il file resta nel
                    // Cestino e recuperabile a mano, ma non viene contato fra i cestinati e
                    // la sua chiave resta nell'indice. E' il verso sicuro.
                    try manifest.record(item)
                    trashedInGroup.append(item)
                } catch {
                    // Stesso errore, due guasti diversi: `NSCocoaErrorDomain/4` arriva sia da
                    // «il file non c'era» sia da «il volume e' sparito», e a distinguerli e'
                    // solo `st_dev`. Non e' mai «era gia' fatto, tutto a posto».
                    if deviceIdentifier(of: libraryRoot) != deviceAtStart {
                        volumeVanished = true
                    } else {
                        groupFailure = .trashFailed(displayPath: entry.displayPath,
                                                    detail: (error as NSError).localizedDescription)
                    }
                    break
                }
            }

            // Lo scollegamento interrompe TUTTO il blocco, e viene prima della
            // post-condizione sul tenuto: se il volume non c'e' piu', il tenuto risulta
            // sparito anche lui e un tentativo di ripristino sposterebbe file su un disco
            // che non e' montato. Il conteggio dei file gia' spostati resta onesto.
            if volumeVanished {
                outcome.trashedFiles.append(contentsOf: trashedInGroup)
                // Le chiavi restano nell'indice: il gruppo non e' chiuso con successo. Una
                // entry fantasma e' innocua (chi salta un file rilegge e rihasha comunque il
                // candidato, ADR-0003, e la rilettura di un file inesistente fallisce);
                // l'ordine inverso lascerebbe un file sul disco senza entry, che al primo
                // import verrebbe ricopiato ricreando il doppione.
                outcome.stoppedBecauseVolumeVanished = true
                break
            }

            // La copia tenuta deve esistere ancora. Se non c'e' — caso che non dovrebbe
            // accadere, e proprio per questo gestito — si rimette a posto subito quanto si e'
            // appena spostato, invece di lasciare l'utente senza nessuna copia.
            if !FileManager.default.fileExists(atPath: keeperURL.path) {
                _ = manifest.restore(trashedInGroup)
                outcome.skippedGroups.append((group, .keeperVanished(displayPath: decision.keeper.displayPath)))
                continue
            }

            outcome.trashedFiles.append(contentsOf: trashedInGroup)

            // Si rimuovono SOLO le chiavi dei file davvero cestinati, e nient'altro. Prima si
            // cestina, poi si rimuove: l'ordine inverso e' quello che ricrea i doppioni.
            if !trashedInGroup.isEmpty {
                try? store.remove(keys: trashedInGroup.map { $0.originalKey })
            }
            if let groupFailure {
                outcome.skippedGroups.append((group, groupFailure))
            }
        }

        return outcome
    }

    private enum Verification {
        case ok([(entry: LibraryIndexEntry, url: URL)])
        case skip(DuplicateTrashSkipReason)
    }

    /// Rilettura e rihash di tutti i membri, con unanimita' obbligatoria. Se anche un solo
    /// membro non soddisfa, l'intero gruppo viene saltato: mai «cestino quelli che ho potuto
    /// verificare».
    private func verify(_ group: DuplicateGroup) -> Verification {
        var resolved: [(entry: LibraryIndexEntry, url: URL)] = []
        for entry in group.members {
            // Confinamento per COMPONENTI canoniche, mai con `hasPrefix`: `/Volumes/SSD` non
            // e' un prefisso di `/Volumes/SSD 2`, ma lo e' testualmente. Senza questa guardia
            // un `displayPath` con `..` uscirebbe dalla libreria e si cestinerebbe un file
            // che non e' nostro.
            guard let url = resolve(entry) else {
                return .skip(.outsideLibrary(displayPath: entry.displayPath))
            }
            // Senza questa guardia un sidecar `.aae` o un `.txt` finito nell'indice verrebbe
            // cestinato come se fosse una foto.
            guard IndexableKind.of(url: url) != .notIndexable else {
                return .skip(.notMedia(displayPath: entry.displayPath))
            }
            // Rilettura dal filesystem: e' il livello di fiducia 3 di ADR-0003, l'unico
            // ammesso sul percorso ad alto danno. Senza, ci si fiderebbe della cache.
            // `nil` non significa mai «coincide»: significa «non lo so», e non si cestina.
            guard let measured = hashFunction(url) else {
                return .skip(.unreadable(displayPath: entry.displayPath))
            }
            guard measured.size == entry.size else {
                return .skip(.sizeChanged(displayPath: entry.displayPath))
            }
            // Confronto con l'hash del GRUPPO, non fra i membri: cosi' un indice stantio su
            // tutti i membri insieme (hash unanimi fra loro ma diversi da quello del gruppo)
            // viene intercettato invece di essere scambiato per unanimita'.
            guard measured.hash == group.hash else {
                return .skip(.contentDisagrees(displayPath: entry.displayPath))
            }
            resolved.append((entry, url))
        }
        return .ok(resolved)
    }

    /// L'URL di una entry, o `nil` se risolve fuori dalla root della libreria.
    private func resolve(_ entry: LibraryIndexEntry) -> URL? {
        let candidate = libraryRoot.appendingPathComponent(entry.displayPath).standardizedFileURL
        guard rootForms.contains(where: { relativePath(of: candidate.path, under: $0) != nil }) else {
            return nil
        }
        return candidate
    }
}


/// Dove un archivio interno dell'app puo' stare: **mai** sul volume sorgente.
///
/// Allow-list e non deny-list su `/Volumes`: una posizione nuova e' vietata per default
/// invece di esserlo solo se qualcuno si ricorda di aggiungerla. Fonte unica, condivisa da
/// `LibraryIndexStore` e da `TrashManifestStore`: il progetto ha gia' pagato due volte la
/// duplicazione della stessa regola (`LibraryExclusions`, `realResolvedPath`), e due guardie
/// diverse per lo stesso problema divergono alla prima modifica di una sola delle due.
func isAllowedStoreLocation(_ url: URL,
                            includingTemporary: Bool = isRunningUnderTests()) -> Bool {
    let dir = url.deletingLastPathComponent()
    let candidates = [dir.standardizedFileURL.path,
                      dir.standardizedFileURL.resolvingSymlinksInPath().path]
    return candidates.contains { candidate in
        storeAllowedRoots(includingTemporary: includingTemporary)
            .contains { isPathInside(candidate, root: $0) }
    }
}

/// Vero solo dentro una corsa di XCTest. La variabile e' impostata dal test runner, non
/// dall'app: in produzione non esiste, e non e' impostabile da chi lancia l'app normalmente.
///
/// Serve a una cosa sola — tenere `NSTemporaryDirectory()` fuori dall'allow-list quando
/// l'app gira davvero (rilievo minore di #31, chiuso il 2026-09-01). Prima la directory
/// temporanea era ammessa **sempre**, con accanto un commento che diceva che serviva ai
/// test: una posizione ammessa "perche' serve ai test" resta una posizione ammessa, e
/// un'allow-list esiste per essere stretta. L'invariante che conta — mai sul volume delle
/// foto — reggeva comunque, perche' `$TMPDIR` e' sul disco interno: questo e' igiene, non
/// la chiusura di un buco.
func isRunningUnderTests() -> Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

private func storeAllowedRoots(includingTemporary: Bool) -> [String] {
    var roots = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    if includingTemporary {
        // I test aprono uno store usa-e-getta per ogni caso. Fuori dai test questa riga non
        // viene eseguita.
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()))
    }
    return roots.flatMap {
        [$0.standardizedFileURL.path, $0.standardizedFileURL.resolvingSymlinksInPath().path]
    }
}

/// Contenimento per **componenti**, non per prefisso di stringa: `/Volumes/SSD` non
/// contiene `/Volumes/SSD 2`.
private func isPathInside(_ path: String, root: String) -> Bool {
    let p = path.hasSuffix("/") ? path : path + "/"
    let r = root.hasSuffix("/") ? root : root + "/"
    return p.hasPrefix(r)
}

/// Persistenza SQLite dell'indice. Scelta su JSON monolitico perche' un aggiornamento
/// incrementale costa O(log n) invece di riscrivere l'intero file, e perche' una
/// corruzione degrada parzialmente invece di rendere tutto illeggibile.
///
/// CONCORRENZA: la SQLite di sistema di macOS e' compilata in modalita' *multi-thread*,
/// non *serialized* (`sqlite3_threadsafe()` ritorna 2, misurato): una connessione aperta
/// non e' condivisibile fra thread. Con i chiamanti reali — lo scanner scrive da una coda
/// di background mentre l'import legge dalla sua e il pannello Revisione conta dal main
/// thread — l'uso non sincronizzato **crasha** dentro `sqlite3_step` (riprodotto, SIGSEGV
/// con 4 thread). Il solo mutex di SQLite non basta: senza serializzazione i `BEGIN` di due
/// batch si accavallano ("cannot start a transaction within a transaction") e il `ROLLBACK`
/// di uno annulla la transazione in volo dell'altro (misurato: 1610 righe su 2000 perse).
/// Quindi: **una coda seriale privata**, ogni metodo pubblico esegue lì dentro, transazione
/// inclusa. `SQLITE_OPEN_FULLMUTEX` resta come cintura aggiuntiva.
/// I metodi privati `...Unsynchronized` presuppongono di essere gia' sulla coda e non
/// devono mai chiamare un metodo pubblico: `queue.sync` annidato e' un deadlock.
///
/// NOTA DI DURABILITA': il database gira in WAL con `synchronous=NORMAL` (il default di
/// macOS; la store imposta solo `journal_mode`). In questa modalita' i commit **non** sono
/// fsyncati: in caso di power loss non si perde "l'ultima transazione", si perde tutto il
/// WAL non ancora checkpointato (~1000 pagine, ~4MB). E' accettato di proposito e non va
/// "corretto" con `synchronous=FULL`: l'indice e' una cache ricostruibile e un fsync per
/// batch su ~100.000 file non si ripaga. Regge perche' il replay del WAL e' atomico per
/// transazione: quello che resta e' un indice **piu' vecchio**, mai un indice sbagliato —
/// e un indice parziale e' esattamente ciò che ADR-0002 mette in conto.
final class LibraryIndexStore {
    static let schemaVersion = 1

    enum StoreError: Error, LocalizedError {
        case cannotOpen(String)
        case sqlFailed(String, code: Int32)
        case invalidLocation(String)
        case notAnIndexFile(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let m): return "Impossibile aprire l'indice: \(m)"
            case .sqlFailed(let m, _): return "Errore nell'indice: \(m)"
            case .invalidLocation(let p): return "Posizione non ammessa per l'indice: \(p)"
            case .notAnIndexFile(let p): return "Non e' un file di indice: \(p)"
            }
        }

        /// Il file esiste ma non e' leggibile come database: va ricostruito, non interpretato.
        var meansFileIsNotAUsableDatabase: Bool {
            guard case .sqlFailed(_, let code) = self else { return false }
            // Solo il codice primario: SQLite espone anche codici estesi (SQLITE_CORRUPT_VTAB...).
            let primary = code & 0xFF
            return primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "AppBackupFoto.LibraryIndexStore")
    /// Il file su cui questa connessione e' aperta. Serve a `deleteIndexAndRecreate()`:
    /// senza, il chiamante dovrebbe ripassare un percorso, e un percorso che arriva da
    /// fuori e' esattamente quello che non vogliamo davanti a una `removeItem`.
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try Self.validateLocation(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try queue.sync {
            do {
                try openUnsynchronized(url)
            } catch let error as StoreError where error.meansFileIsNotAUsableDatabase {
                // Un file che non e' un database SQLite (bytes casuali, un file troncato,
                // una corruzione) renderebbe l'indice inutilizzabile PER SEMPRE: ogni avvio
                // fallirebbe allo stesso modo e il dedup resterebbe spento, ricreando i
                // doppioni a ogni import. E' incoerente con la scelta di ricostruire su
                // schema sconosciuto (ADR-0002): un file illeggibile e' *meno* interpretabile
                // di uno schema sconosciuto. Si cancella SOLO l'indice e i suoi sidecar
                // -wal/-shm — mai nient'altro, e solo dentro la posizione gia' validata
                // sopra — e si riprova UNA volta sola: se fallisce ancora, e' un problema
                // vero (permessi, disco pieno) e deve arrivare al chiamante.
                closeUnsynchronized()
                try Self.deleteDatabaseFiles(at: url)
                try openUnsynchronized(url)
            }
        }
    }

    deinit {
        // close_v2 e non close: smonta la connessione anche se per qualche motivo
        // restasse uno statement vivo, invece di lasciare il handle aperto.
        sqlite3_close_v2(db)
    }

    // MARK: Posizione ammessa

    /// L'indice e' una cache che vive sul Mac e **non deve mai finire sull'SSD** (spec #31:
    /// "mai sull'SSD"), perche' la sorgente si tratta in sola lettura. `init` crea le
    /// directory mancanti a catena, quindi un chiamante distratto che passasse un percorso
    /// sul volume sorgente ci creerebbe dentro cartelle e tre file. La guardia e' una
    /// allow-list e non una deny-list su `/Volumes`: cosi' una posizione nuova e' vietata
    /// per default invece di esserlo solo se qualcuno si ricorda di aggiungerla.
    private static func validateLocation(_ url: URL) throws {
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
    }

    /// L'unica cancellazione di file di tutta la classe. Tre cinture, tutte necessarie:
    ///
    /// 1. **Posizione**: si riusa la stessa allow-list di `init` (`validateLocation`), non se
    ///    ne scrive una seconda — due guardie diverse per lo stesso problema divergono alla
    ///    prima modifica di una sola delle due.
    /// 2. **Estensione**: solo `.sqlite`. La guardia di posizione da sola non basta. Chi
    ///    chiama questa funzione lo fa perche' SQLite ha risposto `SQLITE_NOTADB`, e
    ///    `SQLITE_NOTADB` e' esattamente cio' che SQLite risponde per **qualunque** file che
    ///    non sia un database: un JPEG sotto Application Support verrebbe cancellato. Qui non
    ///    si cancella, si lancia.
    /// 3. **Percorsi espliciti**: tre path costruiti a mano, mai un wildcard, mai una
    ///    ricorsione su directory. Se un giorno servisse cancellare altro, va scritto a mano
    ///    anche quello.
    private static func deleteDatabaseFiles(at url: URL) throws {
        try validateLocation(url)
        guard url.pathExtension.lowercased() == "sqlite" else {
            throw StoreError.notAnIndexFile(url.path)
        }
        let fm = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    /// Permessi `0600` su indice e sidecar. Il file contiene i **percorsi delle foto**
    /// dell'utente — non credenziali, ma dati personali — e non e' cifrato. Application
    /// Support e' gia' protetta dai permessi della home, ma il file nasce `0644`: un altro
    /// utente locale dello stesso Mac potrebbe leggerlo. SQLite crea i sidecar copiando i
    /// permessi del database, quindi stringere il database stringe anche `-wal`/`-shm` che
    /// verranno ricreati dopo un checkpoint — verificato con un ciclo apertura/scrittura/
    /// chiusura in `LibraryIndexStoreTests`, non dedotto dalla documentazione.
    ///
    /// Best-effort di proposito: se `chmod` fallisce l'indice resta perfettamente usabile, e
    /// far fallire l'apertura dell'indice per un problema di permessi contraddirebbe ADR-0002
    /// (l'indice e' una cache, la sua assenza non e' mai un errore fatale).
    private static func restrictPermissions(at url: URL) {
        let fm = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    /// Cancella l'indice dal disco e lo riapre vuoto, pronto per essere ricostruito da zero.
    ///
    /// E' l'unica via d'uscita dalla regola "traversata incompleta ⇒ nessuna rimozione": se
    /// l'utente cancellasse davvero tutte le foto, `sawNothing` renderebbe la traversata
    /// incompleta e le entry fantasma resterebbero per sempre — la ricostruzione completa
    /// (`ignoringStoredHashes`) di proposito non le tocca. Senza questo metodo l'unica uscita
    /// sarebbe cancellare il file a mano dal Finder.
    ///
    /// Non ricostruisce l'indice: lo azzera. Il ripopolamento e' una `LibraryIndexer.scan`
    /// come tutte le altre.
    ///
    /// Se la cancellazione fallisce (permessi, file in uso) lo store viene comunque riaperto
    /// sul vecchio file e resta utilizzabile: l'errore arriva al chiamante, che secondo
    /// ADR-0002 deve mostrarlo e proseguire, mai trattarlo come fatale.
    func deleteIndexAndRecreate() throws {
        try queue.sync {
            closeUnsynchronized()
            do {
                try Self.deleteDatabaseFiles(at: url)
            } catch {
                try? openUnsynchronized(url)
                throw error
            }
            try openUnsynchronized(url)
        }
    }

    // MARK: Apertura

    private func openUnsynchronized(_ url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sconosciuto"
            closeUnsynchronized()
            throw StoreError.cannotOpen(msg)
        }
        do {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA foreign_keys=ON;")
            try createSchemaIfNeeded()
            Self.restrictPermissions(at: url)
        } catch {
            closeUnsynchronized()
            throw error
        }
    }

    private func closeUnsynchronized() {
        sqlite3_close_v2(db)
        db = nil
    }

    // MARK: Helper SQLite

    private func sqlError() -> StoreError {
        StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sconosciuto"
            sqlite3_free(err)
            throw StoreError.sqlFailed(msg, code: rc)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
        return stmt
    }

    /// I bind vanno controllati: un bind fallito (SQLITE_NOMEM, SQLITE_TOOBIG) lascia il
    /// parametro **non legato**, cioe' NULL, e l'INSERT riesce lo stesso — l'indice si
    /// avvelena da solo e il danno emerge molto dopo, in mezzo a un import.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else { throw sqlError() }
    }

    private func bindInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else { throw sqlError() }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else { throw sqlError() }
    }

    /// Esegue un `sqlite3_step` che deve produrre 0 o 1 righe.
    /// `SQLITE_ERROR`/`SQLITE_CORRUPT`/`SQLITE_BUSY` **non** vanno confusi con "nessuna riga":
    /// scambiarli per un risultato vuoto e' esattamente il modo in cui il dedup concluderebbe
    /// "nessuna copia esiste" su un indice rotto, e ricopierebbe il file in silenzio.
    private func stepRow(_ stmt: OpaquePointer?) throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        guard rc == SQLITE_DONE else { throw sqlError() }
        return false
    }

    // MARK: Schema

    private func createSchemaIfNeeded() throws {
        // La versione dello schema e' `PRAGMA user_version`, non una riga di tabella: e' un
        // intero per costruzione (nessun "2.0"/"v2" da interpretare), esiste su qualunque
        // file SQLite e vale 0 sui database nuovi. Con la versione tenuta in una tabella,
        // un valore non numerico veniva letto come "database nuovo" e i dati vecchi
        // venivano adottati — il caso peggiore era irreversibile (schema futuro con colonne
        // diverse: ogni lettura falliva a ogni avvio, per sempre).
        // Qualunque versione diversa da quella attesa — piu' vecchia, piu' nuova, o zero —
        // significa "ricostruisci", mai "interpreta al meglio" (ADR-0002). Buttare l'indice
        // non perde nulla di originale.
        if try userVersionOnDisk() != Int32(Self.schemaVersion) {
            // `meta` non esiste piu' in questo schema: il DROP serve solo a ripulire i
            // database scritti dalla prima versione della store, che la creava.
            try exec("DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS meta;")
        }
        // NOT NULL esplicito sulle colonne TEXT: in una tabella rowid `TEXT PRIMARY KEY`
        // **non** implica NOT NULL e ammette perfino piu' righe NULL (verificato scrivendole
        // da una connessione esterna). Una riga con path NULL faceva poi crashare la lettura.
        try exec("""
        CREATE TABLE IF NOT EXISTS entries (
            path         TEXT PRIMARY KEY NOT NULL,
            display_path TEXT NOT NULL,
            size         INTEGER NOT NULL,
            mtime        REAL NOT NULL,
            hash         TEXT NOT NULL,
            hashed_at    REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(hash);
        CREATE INDEX IF NOT EXISTS idx_entries_size ON entries(size);
        """)
        try exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    private func userVersionOnDisk() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt) else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: API pubblica (tutta serializzata sulla coda privata)

    /// Inserisce o sostituisce entry in una sola transazione: un batch e' atomico,
    /// quindi un'interruzione lascia l'indice parziale ma coerente, mai a meta' riga.
    func upsert(_ entries: [LibraryIndexEntry]) throws {
        try queue.sync { try upsertUnsynchronized(entries) }
    }

    func entry(forKey key: String) throws -> LibraryIndexEntry? {
        try queue.sync { try entryUnsynchronized(forKey: key) }
    }

    /// Tutte le entry con questo hash.
    ///
    /// CONTRATTO (ADR-0003): il risultato e' **corretto ma potenzialmente parziale**. Una
    /// entry puo' mancare perche' il file non e' ancora stato indicizzato, perche' l'ultimo
    /// WAL e' andato perso, o perche' l'indice e' stato ricostruito da poco. Un array vuoto
    /// significa "non lo so", **non** "nessuna copia esiste". E l'inverso vale altrettanto:
    /// una entry presente non prova che quel file sul disco abbia ancora quel contenuto.
    /// Quindi chi decide di **saltare** un file rilegge e rihasha il candidato su disco
    /// prima di dichiarare il doppione, sempre. Fidarsi di questo risultato senza
    /// riverificare trasformerebbe una transazione persa in una foto non copiata.
    func entries(withHash hash: String) throws -> [LibraryIndexEntry] {
        try queue.sync { try entriesUnsynchronized(withHash: hash) }
    }

    /// Tutti i gruppi di copie byte-identiche presenti nell'indice: stesso hash, almeno
    /// due membri, dimensione maggiore di zero. Ordine deterministico (per hash, poi per
    /// chiave), cosi' l'elenco mostrato non cambia fra due aperture a parita' di dati.
    ///
    /// CONTRATTO (ADR-0003 + ADR-0005): il risultato e' **corretto ma potenzialmente
    /// stantio**, esattamente come `entries(withHash:)`. Dice che cosa l'indice ha visto
    /// l'ultima volta che ha guardato, non che cosa c'e' sul disco adesso: un file puo'
    /// essere stato modificato conservando dimensione e mtime (exiftool, `rsync -t`, un
    /// restore da Finder li preservano tutti e tre), e allora la sua entry resta `.fresh`
    /// pur non descrivendo piu' il contenuto reale.
    ///
    /// Serve quindi a **mostrare una lista** — il livello di fiducia 1, quello a basso
    /// danno. **Mai** a decidere una cancellazione: prima di cestinare, ogni membro del
    /// gruppo, **la copia tenuta compresa**, va riletto e rihashato dal disco con esito
    /// unanime. Fidarsi di questo risultato per cestinare significherebbe mandare nel
    /// Cestino una foto che non e' un doppione.
    func duplicateGroups() throws -> [DuplicateGroup] {
        try queue.sync { try duplicateGroupsUnsynchronized() }
    }

    /// Filtro dimensione-prima: se nessun file indicizzato ha questa dimensione,
    /// il file in arrivo non va nemmeno hashato. E' lo stadio 1 del pipeline su cui
    /// convergono rmlint, jdupes e rdfind.
    func hasAnyEntry(withSize size: Int64) throws -> Bool {
        try queue.sync { try hasAnyEntryUnsynchronized(withSize: size) }
    }

    func allKeys() throws -> Set<String> {
        try queue.sync { try allKeysUnsynchronized() }
    }

    func remove(keys: [String]) throws {
        try queue.sync { try removeUnsynchronized(keys: keys) }
    }

    func count() throws -> Int {
        try queue.sync { try countUnsynchronized() }
    }

    // MARK: Implementazioni (gia' sulla coda: non chiamarle dall'esterno)

    private func upsertUnsynchronized(_ entries: [LibraryIndexEntry]) throws {
        guard !entries.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let sql = "INSERT OR REPLACE INTO entries(path,display_path,size,mtime,hash,hashed_at) VALUES(?,?,?,?,?,?);"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for e in entries {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, e.path)
                try bindText(stmt, 2, e.displayPath)
                try bindInt64(stmt, 3, e.size)
                try bindDouble(stmt, 4, e.mtime)
                try bindText(stmt, 5, e.hash)
                try bindDouble(stmt, 6, e.hashedAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Legge una riga, o nil se una colonna TEXT e' NULL.
    /// Il NOT NULL nello schema non protegge le righe scritte prima (o da un'altra
    /// connessione): `String(cString:)` su un puntatore nil fa crashare il processo, quindi
    /// una riga malformata si **salta**. Meglio un'entry in meno — che porta a un rehash o
    /// a una copia in piu' — che un import che muore a meta'.
    private func readEntry(_ stmt: OpaquePointer?) -> LibraryIndexEntry? {
        guard let path = sqlite3_column_text(stmt, 0),
              let displayPath = sqlite3_column_text(stmt, 1),
              let hash = sqlite3_column_text(stmt, 4) else { return nil }
        return LibraryIndexEntry(path: String(cString: path),
                                 displayPath: String(cString: displayPath),
                                 size: sqlite3_column_int64(stmt, 2),
                                 mtime: sqlite3_column_double(stmt, 3),
                                 hash: String(cString: hash),
                                 hashedAt: sqlite3_column_double(stmt, 5))
    }

    private func entryUnsynchronized(forKey key: String) throws -> LibraryIndexEntry? {
        let stmt = try prepare("SELECT path,display_path,size,mtime,hash,hashed_at FROM entries WHERE path=?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, 1, key)
        return try stepRow(stmt) ? readEntry(stmt) : nil
    }

    private func entriesUnsynchronized(withHash hash: String) throws -> [LibraryIndexEntry] {
        let stmt = try prepare("SELECT path,display_path,size,mtime,hash,hashed_at FROM entries WHERE hash=?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, 1, hash)
        var out: [LibraryIndexEntry] = []
        while try stepRow(stmt) {
            if let entry = readEntry(stmt) { out.append(entry) }
        }
        return out
    }

    private func duplicateGroupsUnsynchronized() throws -> [DuplicateGroup] {
        // `size > 0` compare DUE volte, e servono entrambe. Tutti i file vuoti condividono
        // lo stesso SHA256, e nell'indice ci sono solo media (`IndexableKind`): un media da
        // 0 byte e' troncato o corrotto, non la copia di qualcos'altro. Senza l'esclusione
        // nella sottoquery i vuoti farebbero COUNT, gonfiando il numero di copie di file che
        // copie non ne hanno; senza quella esterna comparirebbero fra i membri. Proporre di
        // cestinarli significherebbe proporre di cestinare file **diversi** credendoli
        // copie — lo stesso buco gia' trovato e chiuso una volta con i sidecar `.AAE`.
        let sql = """
        SELECT path,display_path,size,mtime,hash,hashed_at FROM entries
        WHERE size > 0 AND hash IN (
            SELECT hash FROM entries WHERE size > 0 GROUP BY hash HAVING COUNT(*) > 1
        )
        ORDER BY hash, path;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var groups: [DuplicateGroup] = []
        var currentHash: String?
        var members: [LibraryIndexEntry] = []

        // Un gruppo si chiude quando cambia l'hash: l'ORDER BY li tiene contigui.
        // `members.count > 1` non e' ridondante rispetto all'HAVING: una riga malformata
        // saltata da `readEntry` puo' ridurre a uno i membri leggibili, e un gruppo da un
        // membro solo non e' un gruppo — mostrarlo proporrebbe di cestinare l'unica copia.
        func flush() {
            // `min` e non `members[0].size`: se l'indice fosse incoerente (stesso hash,
            // dimensioni diverse) la prima riga incontrata potrebbe far promettere
            // all'utente piu' spazio di quanto se ne libererebbe davvero. Vedi il
            // doc-comment di `DuplicateGroup.size`.
            if let hash = currentHash, members.count > 1,
               let size = members.map(\.size).min() {
                groups.append(DuplicateGroup(hash: hash, size: size, members: members))
            }
            members = []
        }

        // `stepRow` e non `while sqlite3_step(...) == SQLITE_ROW`: quel ciclo esce identico
        // su SQLITE_DONE e su SQLITE_ERROR/CORRUPT/BUSY, cioe' restituirebbe un elenco
        // troncato **senza segnalare niente** — gruppi di doppioni spariti dalla schermata
        // e nessuno che sappia perche'.
        while try stepRow(stmt) {
            // Guardia nil su ogni colonna TEXT: `String(cString:)` su un puntatore nil
            // termina il processo (SIGTRAP), e il NOT NULL dello schema non protegge le
            // righe scritte prima o da un'altra connessione. La riga si salta.
            guard let entry = readEntry(stmt) else { continue }
            if entry.hash != currentHash {
                flush()
                currentHash = entry.hash
            }
            members.append(entry)
        }
        flush()
        return groups
    }

    private func hasAnyEntryUnsynchronized(withSize size: Int64) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM entries WHERE size=? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, 1, size)
        return try stepRow(stmt)
    }

    private func allKeysUnsynchronized() throws -> Set<String> {
        let stmt = try prepare("SELECT path FROM entries;")
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while try stepRow(stmt) {
            if let path = sqlite3_column_text(stmt, 0) { out.insert(String(cString: path)) }
        }
        return out
    }

    private func removeUnsynchronized(keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("DELETE FROM entries WHERE path=?;")
            defer { sqlite3_finalize(stmt) }
            for k in keys {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, k)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func countUnsynchronized() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM entries;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt) else { throw sqlError() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

// MARK: - LibraryIndexer

/// Attraversa la libreria sull'SSD, classifica, hasha e aggiorna l'indice.
/// Interamente in sola lettura sul volume: non scrive, non sposta, non cancella nulla.
///
/// CONCORRENZA: `scan` gira su un thread di lavoro (mai sul main thread: legge per
/// intero ogni foto e video della libreria) mentre la UI puo' chiamare `cancel()` dal
/// main thread. L'unico stato condiviso fra i due e' il flag di cancellazione, ed e'
/// protetto da un lock: senza, sarebbe una data race su un `Bool` letto a ogni file.
/// `onProgress` viene invocato **sul thread che sta scansionando**, non sul main:
/// il chiamante che aggiorna la UI deve pubblicare su `@MainActor` (Task 6).
/// Una singola istanza esegue una scansione per volta (`volumeVanished` e i contatori
/// sono locali alla scansione in corso): non chiamare `scan` da due thread insieme.
final class LibraryIndexer {
    struct Progress {
        var scanned = 0     // file esaminati
        var hashed = 0      // file effettivamente (ri)hashati
        var skipped = 0     // file gia' indicizzati e ancora attendibili
        var errors = 0      // file non indicizzabili per errore di lettura
        var total = 0       // entry totali nell'indice a fine scansione

        /// Entry che risultano sparite dal disco ma che NON sono state rimosse,
        /// perche' la guardia di plausibilita' ha giudicato sospetta la sparizione.
        /// 0 = guardia non scattata. **Va mostrato all'utente** (Task 6): una guardia
        /// che scatta in silenzio e' la stessa classe di problema che questo progetto
        /// teme di piu'. Dopo una riorganizzazione legittima della libreria scatterebbe
        /// a ogni avvio, per sempre, senza che nessuno se ne accorga.
        var vanishedKept = 0

        /// File il cui mtime e' risultato spostato di un'ora esatta (cambio di fuso):
        /// mtime adottato SENZA rihashare. E' il risparmio che la regola DST esiste
        /// per ottenere.
        var rebasedByTimezone = 0

        /// Cartelle (o elementi) che l'enumeratore non e' riuscito ad aprire: permessi,
        /// I/O, volume scollegato. Contate dall'`errorHandler`, che senza di lui
        /// **prosegue in silenzio** — il default di `FileManager.enumerator`.
        /// **Va mostrato all'utente** (Task 6): e' il "quante cartelle non sono
        /// riuscita a leggere" che sostituisce la rimozione quando la traversata non
        /// e' completa.
        var unreadableItems = 0

        /// La traversata NON ha coperto tutta la libreria: cartelle illeggibili,
        /// volume scollegato, o zero file visti su un indice non vuoto. Quando e'
        /// `true` **nessuna entry viene rimossa**, in nessuna modalita' — nemmeno
        /// nella "Ricostruzione completa". Vedi il commento in fondo a `scan`.
        var traversalIncomplete = true

        /// Il volume sotto la root e' sparito (o e' stato rimontato) durante la
        /// scansione. Sottoinsieme di `traversalIncomplete`, tenuto distinto perche'
        /// il messaggio da mostrare e' diverso: "SSD scollegato" non e' "3 cartelle
        /// senza permessi".
        var volumeVanished = false

        /// La lettura e' stata fermata prima della fine: "Interrompi" dell'utente oppure
        /// smontaggio di un volume qualsiasi, che passa dallo stesso `cancel()`.
        /// Sottoinsieme di `traversalIncomplete`, tenuto qui e non ricostruito dalla UI:
        /// la UI conosce solo il primo dei due casi (`indexInterruptedByUser`), e per il
        /// secondo leggerebbe `scanned == 0` senza sapere perche'. E' la differenza fra
        /// dire "non sono riuscita a leggere tutto" ed **eleggere l'unico comando
        /// distruttivo della card** dopo che e' stata espulsa una chiavetta.
        var cancelled = false

        /// File scartati perche' il loro percorso canonico non ricade sotto la root.
        /// Non e' un caso raggiungibile oggi (vedi il commento sul controllo), ma se
        /// lo diventasse il sintomo sarebbe una scansione da zero file senza
        /// spiegazione: contarli e' l'unico modo per vederlo.
        var outsideRoot = 0
    }

    private let store: LibraryIndexStore
    private let fm = FileManager.default

    /// L'utente ha interrotto. Consumato alla FINE di ogni `scan`, non all'inizio:
    /// vedi il commento in cima a `scan`.
    ///
    /// Scritto dal main thread (`cancel()`) e letto a ogni file dal thread di
    /// scansione: l'accesso passa sempre dal lock, mai dallo storage diretto.
    private let cancelLock = NSLock()
    private var cancelledStorage = false
    private var cancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelledStorage }
        set { cancelLock.lock(); defer { cancelLock.unlock() }; cancelledStorage = newValue }
    }

    /// Contatore condiviso con l'`errorHandler` dell'enumeratore. Serve una scatola di
    /// riferimento e non una variabile locale perche' quella closure e' `@escaping`
    /// (l'enumeratore la conserva) e Swift non lascia catturare un `var` locale
    /// mutabile. Nessun lock: `errorHandler` viene invocato in modo sincrono dal thread
    /// che chiama `nextObject()`, cioe' lo stesso che esegue `scan`.
    private final class TraversalFailures {
        var count = 0
    }

    init(store: LibraryIndexStore) { self.store = store }

    func cancel() { cancelled = true }

    // Le esclusioni NON sono ridichiarate qui: `LibraryExclusions` e' la fonte unica
    // condivisa con FileSyncer e ReviewEngine. Una seconda copia "da tenere allineata"
    // e' esattamente il modo in cui le due divergono.
    //
    // ATTENZIONE (trovato dal Security Auditor, 2026-08-25): il filtro effettivo di
    // questo scanner deve essere `.skipsHiddenFiles` sull'enumerator PIU'
    // `LibraryExclusions`, mai una sola delle due. Sei degli otto nomi della lista
    // iniziano con un punto, quindi sono gia' coperti dall'enumerator; ma se qualcuno
    // "semplificasse" togliendo `.skipsHiddenFiles`, l'indice diventerebbe un
    // superset di cio' che FileSyncer copia davvero. Incrociato con ADR-0003, una
    // copia nascosta byte-identica sull'SSD farebbe saltare un import reale mentre
    // quella copia non arriva mai ne' su HDD ne' su Cubbit: perdita silenziosa.
    // L'opzione `.skipsHiddenFiles` piu' sotto NON e' un dettaglio di performance.

    /// Scansione completa con aggiornamento incrementale.
    /// I commit avvengono a batch (non uno per file, non uno solo alla fine): cosi'
    /// un'interruzione lascia un indice parziale ma valido e utile, mai inutilizzabile.
    @discardableResult
    func scan(root: URL, batchSize: Int = 200,
              ignoringStoredHashes: Bool = false,
              onProgress: @escaping (Progress) -> Void = { _ in }) throws -> Progress {
        // La cancellazione si consuma alla FINE della scansione, non all'inizio.
        //
        // Azzerarla qui sembrava equivalente e non lo e': fra il click su "Interrompi"
        // e l'ingresso in `scan` sul thread di lavoro c'e' una finestra in cui
        // `cancel()` arriva ma la scansione non e' ancora partita. Azzerando in cima,
        // quel cancel veniva inghiottito e la scansione partiva lo stesso. Consumandolo
        // in uscita si ottengono entrambe le cose: un cancel arrivato PRIMA che `scan`
        // parta viene rispettato, e un'istanza gia' cancellata torna comunque a
        // scansionare alla chiamata successiva (era il bug del `cancelled` mai
        // resettato: l'indice smetteva di aggiornarsi fino al riavvio dell'app).
        defer { cancelled = false }

        var progress = Progress()
        var batch: [LibraryIndexEntry] = []
        var seenKeys = Set<String>()
        var volumeVanished = false
        let failures = TraversalFailures()
        let knownKeys = try store.allKeys()

        // Identita' del volume all'inizio, per confrontarla alla fine.
        let deviceAtStart = deviceIdentifier(of: root)

        // Root assente (SSD scollegato prima di partire): uscita anticipata.
        // ONESTA' SUL VALORE DI QUESTA GUARDIA: rimuoverla non cambia nulla di
        // osservabile (misurato). `fm.enumerator(at:)` su un percorso inesistente NON
        // restituisce `nil`, restituisce un enumeratore che non produce niente, e il
        // caso viene poi ripreso in fondo dalla regola "zero file visti + indice non
        // vuoto => nessuna rimozione". Resta qui perche' evita una `allKeys()` e
        // un'enumerazione inutili, e perche' distingue nel `Progress` "volume assente"
        // da "cartelle illeggibili". Il commento precedente diceva che senza di lei
        // l'indice INTERO verrebbe cancellato: era falso, ed e' il tipo di commento
        // difensivo di cui il prossimo lettore si fida a torto.
        guard deviceAtStart != nil else {
            progress.volumeVanished = true
            progress.total = try store.count()
            onProgress(progress)
            return progress
        }

        // `errorHandler` NON e' opzionale in senso pratico: il suo default e' "continua
        // in silenzio", ed e' il buco piu' grave trovato in review (misurato il
        // 2026-08-26). Una sottocartella con `chmod 000` fra due scansioni faceva
        // rimuovere le entry dei file esistenti che conteneva, con `errors=0` e nessun
        // segnale; lo scollegamento del volume a meta' scansione lo chiamava invece 43
        // volte con `NSPOSIXErrorDomain Code=6 "Device not configured"`. Sono lo stesso
        // guasto visto da due lati — la traversata non e' completa — e questo e' il solo
        // rilevatore che non dipende da nessun timing.
        // Ritorna `true` (prosegui): l'obiettivo e' contarli tutti e indicizzare quello
        // che si riesce a leggere, non fermarsi al primo.
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in
                                                 failures.count += 1
                                                 return true
                                             }) else {
            // Irraggiungibile per quanto misurato: `enumerator(at:)` non restituisce
            // `nil` ne' su percorso inesistente ne' su un file regolare. Tenuta perche'
            // l'API e' opzionale, ma trattata come traversata fallita, non come
            // "libreria vuota": senza questo ramo un `nil` inatteso porterebbe a
            // rimuovere tutto.
            progress.unreadableItems = 1
            progress.total = try store.count()
            onProgress(progress)
            return progress
        }

        // Il percorso relativo si ricava per COMPONENTI canonicalizzate, mai per
        // lunghezza di stringa. La forma testuale della root e quella degli URL che
        // l'enumeratore restituisce non coincidono per forza: misurato il 2026-08-26,
        // con root `/var/folders/.../SSD` l'enumeratore produce `/private/var/...`
        // (`/var` e' un symlink verso `/private/var` su macOS). Un
        // `dropFirst(root.path.count)` tagliava 8 caratteri di meno e generava chiavi
        // come `40CC/SSD/Foto/a.jpg`: coerenti DENTRO una singola scansione — per
        // questo i conteggi tornavano — ma irrecuperabili per chiave alla scansione
        // successiva. Effetto sul volume reale: indice apparentemente vuoto, ~120.000
        // file rihashati e una seconda copia di ogni entry a ogni scansione. E'
        // esattamente il rischio documentato su `normalizedIndexKey` (rilievo 9 del
        // Task 3), qui col percorso assoluto invece che con gli slash.
        // La canonicalizzazione e' `realResolvedPath`, la stessa usata da ReviewEngine:
        // due forme canoniche diverse applicate ai due lati riprodurrebbero il bug.
        let rootComponents = canonicalPathComponents(of: root)

        // Scrittura del batch + progresso + controllo opportunistico del volume, in un
        // punto solo. Erano due rami distinti e solo quello degli hash faceva progresso
        // e controllo: dopo un cambio d'ora e' invece il ramo `.timezoneShift` a
        // riempire i batch, e li' non si sarebbe visto passare niente.
        func flushBatchIfFull() throws {
            guard batch.count >= batchSize else { return }
            try store.upsert(batch)
            batch.removeAll(keepingCapacity: true)
            progress.total = try store.count()
            onProgress(progress)

            // Volume scollegato (o rimontato) a meta' scansione: fermarsi in modo
            // pulito invece di produrre errori per 100.000 file. Uscita ANTICIPATA
            // opportunistica: la garanzia vera sta nell'`errorHandler` e nel controllo
            // dopo il ciclo, perche' questo gira solo quando un batch si riempie.
            //
            // Nota sul mutation testing, per non farlo sembrare un mutante misterioso:
            // questo controllo e quello dopo il ciclo sono **ridondanti fra loro** —
            // tolto uno, l'altro rileva comunque il volume sparito e imposta
            // `volumeVanished`. Per questo nessuno dei due muore da solo; muoiono
            // insieme (verificato: togliendoli entrambi,
            // `testRootRenamedDuringScan_...` fallisce). Quello che si perde
            // togliendo solo questo e' l'uscita anticipata, cioe' il tempo, non la
            // correttezza.
            if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }
        }

        while let url = enumerator.nextObject() as? URL {
            if cancelled { break }
            if LibraryExclusions.shouldExclude(url) { enumerator.skipDescendants(); continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard IndexableKind.of(url: url) != .notIndexable else { continue }

            // Fuori dalla root una volta risolti i symlink: non e' un file della
            // libreria e non si indicizza. Direzione sicura — un file non indicizzato
            // viene copiato, mai saltato per errore.
            // NON e' raggiungibile oggi (misurato): un symlink ha `isRegularFile ==
            // false` ed e' gia' scartato due righe sopra, e l'enumeratore non lo segue.
            // Resta come invariante strutturale sul calcolo del percorso relativo, ma
            // con un contatore: se scattasse in massa il sintomo sarebbe una scansione
            // da zero file senza spiegazione, e senza contatore sarebbe muta.
            let fileComponents = canonicalPathComponents(of: url)
            guard fileComponents.count > rootComponents.count,
                  Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
                progress.outsideRoot += 1
                continue
            }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")

            progress.scanned += 1

            let key = normalizedIndexKey(relative)
            // La chiave entra in `seenKeys` PRIMA di qualunque possibile errore, ed e'
            // voluto: un file che esiste ma che non riusciamo a leggere non e' un file
            // sparito, quindi la sua entry non va rimossa. Il prezzo e' che l'indice
            // continua a servire al dedup l'hash VECCHIO di quel file. E' coperto solo
            // dalla rilettura di ADR-0003: prima di saltare un file in import il
            // candidato viene riletto e rihashato, quindi un hash stantio non puo' far
            // saltare una foto. Senza quella rilettura, questa riga sarebbe un buco.
            seenKeys.insert(key)

            // Un file di cui non si riesce a leggere dimensione o mtime NON si indicizza.
            // Motivo (code reviewer, 2026-08-25, riprodotto): col fallback `?? 0` un mtime
            // illeggibile per due scansioni di fila produce storedMTime == currentMTime == 0,
            // e indexEntryVerdict risponde `.fresh` per sempre — quel file non verrebbe mai
            // piu' rihashato, qualunque cosa gli succeda a parita' di dimensione. Non e' un
            // difetto della funzione pura (0 e' un timestamp legittimo per lei), e' il `?? 0`
            // del chiamante. Stessa logica gia' adottata per la lettura troncata: meglio non
            // indicizzare che indicizzare male, perche' a valle questo hash decide se saltare
            // un file in import.
            guard let fileSize = values?.fileSize,
                  let modified = values?.contentModificationDate else {
                progress.errors += 1
                continue
            }
            let size = Int64(fileSize)
            // L'mtime si legge PRIMA dell'hash, e l'ordine e' load-bearing: non
            // spostarlo dopo per "leggere una volta sola".
            // Misurato il 2026-08-26 su un file da 400MB modificato a parita' di
            // dimensione durante l'hashing: l'hash risultante non corrisponde al
            // contenuto (la difesa sulle dimensioni non puo' vederlo, la dimensione non
            // e' cambiata). Con l'mtime letto PRIMA, quello memorizzato risulta minore
            // dell'mtime reale, `indexEntryVerdict` risponde `.stale` alla scansione
            // successiva e il file viene rihashato: l'errore si autocorregge.
            // Leggendo l'mtime DOPO l'hash, la stessa entry avvelenata risulterebbe
            // `.fresh` **per sempre**, e a valle deciderebbe di saltare un file in
            // import. Oggi siamo salvi solo per quest'ordine.
            let mtime = modified.timeIntervalSince1970

            // Riuso dell'hash memorizzato quando la entry e' ancora attendibile.
            // In modalita' "verifica completa" non ci si fida di nulla di memorizzato.
            if !ignoringStoredHashes, let existing = try store.entry(forKey: key) {
                let verdict = indexEntryVerdict(storedSize: existing.size,
                                                storedMTime: existing.mtime,
                                                storedHashedAt: existing.hashedAt,
                                                currentSize: size,
                                                currentMTime: mtime)
                if verdict == .fresh {
                    progress.skipped += 1
                    continue
                }
                if verdict == .timezoneShift {
                    // Cambio di fuso, non modifica del file: adotta il nuovo mtime e
                    // TIENI l'hash. E' l'unico punto in cui la regola DST produce un
                    // effetto reale — senza questo ramo rihasheremmo l'intera libreria
                    // due volte l'anno, cioe' esattamente cio' che la spec dice di
                    // voler evitare.
                    //
                    // Sicuro perche' il rischio e' confinato al percorso a BASSO danno
                    // (ADR-0003): perche' sia un errore servirebbe un file cambiato,
                    // di dimensione identica, con mtime spostato di 3600s +/- 50ms. E
                    // anche in quel caso l'import rilegge e rihasha il candidato prima
                    // di saltarlo, quindi nessuna foto verrebbe persa: al massimo una
                    // riga sbagliata nel pannello Doppioni.
                    batch.append(LibraryIndexEntry(path: key, displayPath: relative,
                                                   size: size, mtime: mtime,
                                                   hash: existing.hash,
                                                   hashedAt: existing.hashedAt))
                    progress.rebasedByTimezone += 1
                    try flushBatchIfFull()
                    if volumeVanished { break }
                    continue
                }
                // .stale e .needsVerification portano entrambi al rehash: durante la
                // scansione conviene sempre risolvere il dubbio, il costo e' lo stesso.
            }

            // Hash e dimensione arrivano dallo STESSO descrittore aperto. Il confronto
            // che stava qui — rileggere `fileSizeKey` dallo stesso `url` dopo l'hash —
            // era vero per costruzione, perche' `resourceValues` serve valori in cache
            // sull'istanza di URL (misurato: 5000 -> 5000 su un file troncato a 6 byte).
            // Vedi `sha256Measured`.
            guard let measured = sha256Measured(of: url) else {
                progress.errors += 1
                continue
            }

            // Difesa contro una lettura troncata (volume scollegato, file riscritto da
            // un altro processo): se la dimensione misurata sul descrittore non e'
            // quella letta dalla directory, NON indicizzare. Un hash calcolato su una
            // lettura parziale verrebbe poi usato per saltare un file in import —
            // fallimento silenzioso con perdita di uno scatto.
            guard measured.size == size else {
                progress.errors += 1
                continue
            }

            batch.append(LibraryIndexEntry(path: key, displayPath: relative, size: size,
                                           mtime: mtime, hash: measured.hash,
                                           hashedAt: Date().timeIntervalSince1970))
            progress.hashed += 1

            try flushBatchIfFull()
            if volumeVanished { break }
        }

        if !batch.isEmpty { try store.upsert(batch) }

        if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }

        progress.unreadableItems = failures.count
        progress.volumeVanished = volumeVanished
        progress.cancelled = cancelled

        // ---- Rimozione dei file spariti: solo dopo una traversata COMPLETA ----
        //
        // DECISIONE DI PRODOTTO (Enrico, 2026-08-26), vale in TUTTE le modalita',
        // "Ricostruzione completa" inclusa: se la traversata non e' stata completa, la
        // scansione non rimuove NULLA. Mostra invece quanti elementi non e' riuscita a
        // leggere (`unreadableItems`, `vanishedKept`).
        //
        // Il verso dell'errore non e' simmetrico. Una riga stantia nell'indice e'
        // innocua, perche' prima di saltare un file in import l'app rilegge e rihasha
        // comunque il candidato sul disco (ADR-0003). Una riga cancellata per errore
        // costa dedup spento, doppioni ricreati al primo import e 5-15 minuti di
        // ricostruzione. Nel dubbio si tiene di piu', mai si toglie di piu'.
        //
        // Tre modi in cui la traversata risulta incompleta, tutti misurati:
        // 1. `errorHandler` chiamato almeno una volta (cartella illeggibile, EIO,
        //    volume scollegato). Da solo copre il caso peggiore: stacco al 70% della
        //    scansione, 17.958 entry (30%) cancellate in silenzio, `errors=0`.
        // 2. `st_dev` della root diverso da quello iniziale (o `stat` che fallisce).
        // 3. Zero file visti su un indice NON vuoto: "enumerazione a zero file" non e'
        //    "libreria vuota". Misurato con una root che l'enumeratore non riesce a
        //    percorrere: `scanned=0`, nessun errore, indice azzerato (1 -> 0).
        //    Il prezzo: se l'utente cancella DAVVERO tutte le foto, le entry fantasma
        //    restano finche' non si cancella il file dell'indice — per questo il Task 6
        //    deve offrire un comando esplicito "elimina indice e ricostruisci".
        // 4. L'utente ha interrotto. Una scansione fermata a meta' e' incompleta esattamente
        //    come le altre tre, e prima non lo diceva: misurato il 2026-08-26, scan interrotta
        //    dopo il primo batch -> `scanned=4 traversalIncomplete=false vanishedKept=36`.
        //    Il Task 6 avrebbe letto "traversata completa" dopo un Interrompi.
        let sawNothing = progress.scanned == 0 && !knownKeys.isEmpty
        progress.traversalIncomplete = failures.count > 0 || volumeVanished || sawNothing || cancelled

        let vanished = knownKeys.subtracting(seenKeys)

        // Guardia di plausibilita', indipendente dalle tre sopra: sparire piu' della
        // meta' dell'indice in una scansione completa e' quasi sempre un'interruzione
        // che non abbiamo riconosciuto, non 60.000 cancellazioni reali fatte dall'utente.
        //
        // `ignoringStoredHashes` scavalca QUESTA e solo questa: e' la "Ricostruzione
        // completa", un'azione esplicita che significa "fidati del disco". Senza questa
        // via d'uscita, dopo una cancellazione massiccia VERA le entry fantasma
        // resterebbero per sempre e il pannello Doppioni mostrerebbe gruppi che non
        // esistono piu'. NON scavalca la traversata incompleta: e' la modalita' che dura
        // 5-15 minuti sul volume vero, cioe' quella con la probabilita' piu' alta di
        // essere interrotta da uno scollegamento.
        let plausible = ignoringStoredHashes
            || knownKeys.isEmpty
            || vanished.count * 2 <= knownKeys.count

        if !vanished.isEmpty {
            // `!cancelled` NON compare piu' qui: e' gia' dentro `traversalIncomplete`
            // (motivo 4 sopra). Come condizione separata era anche l'unico pezzo di
            // questa riga che nessun test esercitava — i tre test di cancellazione
            // partono da indice vuoto, quindi `vanished` e' sempre vuoto e la guardia
            // non veniva mai raggiunta: rimuoverla lasciava la suite verde mentre sul
            // volume vero un click su Interrompi durante una Ricostruzione completa
            // cancellava ~110.000 entry (`ignoringStoredHashes` scavalca la guardia di
            // plausibilita', quindi non c'e' nessuna rete sotto).
            if !progress.traversalIncomplete && plausible {
                try store.remove(keys: Array(vanished))
            } else {
                // NON in silenzio: il Task 6 mostra questo numero all'utente. Vale per
                // tutti i motivi per cui non si e' rimosso (traversata incompleta,
                // cancellazione, guardia di plausibilita'), perche' il significato per
                // chi legge e' uno solo: "entry sparite dal disco che ho tenuto".
                progress.vanishedKept = vanished.count
            }
        }

        progress.total = try store.count()
        onProgress(progress)
        return progress
    }
}

// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)

/// I nomi dei comandi della card, in un punto solo. Non e' pignoleria: due dei messaggi
/// dicono all'utente **quale bottone premere**, e se il nome vivesse in due posti la prima
/// rinomina lascerebbe un messaggio che indica un bottone che non esiste piu'.
enum LibraryIndexCommands {
    static let build = "Crea l'elenco"
    static let refresh = "Aggiorna l'elenco"
    static let fullRecheck = "Controlla tutte le foto da capo"
    static let reset = "Svuota l'elenco e ricomincia da zero"
    static let stop = "Interrompi"
}

/// Cosa dire all'utente dopo una lettura della libreria. Logica **pura**: dipende solo dal
/// `Progress` restituito da `LibraryIndexer.scan` e dal fatto che l'utente abbia premuto
/// "Interrompi" — che il `Progress` non puo' sapere, perche' la cancellazione la decide la
/// UI e arriva anche dallo smontaggio automatico di un volume.
///
/// Sta qui e non dentro la View perche' e' l'unica parte della card verificabile senza una
/// corsa reale, ed e' anche quella che sbaglia piu' facilmente: la regola "traversata
/// incompleta => non si toglie niente" ha cause diverse, e ognuna richiede una spiegazione
/// diversa e un numero. Un colore da solo non dice a Enrico perche' il conteggio non torna.
///
/// Registro: nessun gergo. "Indice", "hash", "scansione incrementale" non compaiono, qui
/// dentro come nel resto della card.
enum LibraryIndexStatus {
    enum Tone { case ok, info, warning }

    struct Line: Identifiable {
        /// Identita' stabile e non un UUID: le righe si ricalcolano a ogni ridisegno, e con
        /// un UUID SwiftUI le vedrebbe tutte nuove ogni volta.
        let id: String
        let tone: Tone
        let text: String
    }

    static func lines(for p: LibraryIndexer.Progress, interruptedByUser: Bool) -> [Line] {
        var out: [Line] = []

        // ---- Perche' la lettura non e' arrivata in fondo ----
        // Righe indipendenti, non alternative: "SSD scollegato" e "3 cartelle non lette"
        // possono essere vere insieme e sono due informazioni diverse.
        if p.volumeVanished {
            out.append(Line(id: "volume", tone: .warning, text:
                "L'SSD è stato scollegato mentre l'app stava leggendo, quindi il controllo si è fermato a metà. "
                + "Quello che aveva già letto è stato salvato: ricollega l'SSD e premi di nuovo «\(LibraryIndexCommands.refresh)»."))
        }
        if interruptedByUser {
            out.append(Line(id: "interrotto", tone: .info, text:
                "Hai fermato tu il controllo. Quello che l'app aveva già letto resta salvato e la prossima volta riprende da lì."))
        }
        if p.unreadableItems > 0 {
            out.append(Line(id: "illeggibili", tone: .warning, text:
                "\(count(p.unreadableItems, "cartella non si è lasciata aprire", "cartelle non si sono lasciate aprire")) "
                + "(permessi o errori di lettura): quello che c'era dentro non è entrato nell'elenco."))
        }
        // Zero file visti con l'elenco pieno: "non ho trovato niente" non e' "non c'e'
        // niente". E' il caso in cui l'unica via d'uscita e' svuotare l'elenco, quindi il
        // messaggio deve nominarla: senza, l'utente resta in un vicolo cieco (ADR-0002).
        // Le esclusioni sono tutte lo stesso principio: "non ho trovato niente" vale solo se
        // la lettura ha davvero guardato. Con una cartella illeggibile (root senza permessi,
        // TCC perso, EIO) si ottiene lo stesso `scanned == 0` — e la card finirebbe per dire
        // insieme "non ho letto quella cartella" e "svuota l'elenco": due istruzioni opposte
        // nella stessa schermata, di cui quella sbagliata e' l'unica distruttiva.
        // `p.cancelled` copre lo smontaggio di un ALTRO volume (un DMG, una chiavetta)
        // durante i primi secondi di lettura: ferma la lettura senza essere ne'
        // `volumeVanished` ne' `interruptedByUser`.
        let sawNothing = !p.volumeVanished && !interruptedByUser && !p.cancelled
            && p.unreadableItems == 0 && p.scanned == 0 && p.total > 0
        if sawNothing {
            out.append(Line(id: "vuoto", tone: .warning, text:
                "L'app non ha trovato nessuna foto sull'SSD, ma nell'elenco ce ne sono \(number(p.total)). "
                + "Per sicurezza non ha tolto niente. Se hai davvero svuotato l'SSD, usa «\(LibraryIndexCommands.reset)»."))
        }
        // Residuo: la lettura risulta incompleta per un motivo che non abbiamo saputo
        // spiegare meglio. Meglio una riga generica che il silenzio.
        if p.traversalIncomplete && out.isEmpty {
            out.append(Line(id: "incompleta", tone: .warning, text:
                "Il controllo non è riuscito a leggere tutta la libreria. Per sicurezza non è stata tolta nessuna foto dall'elenco."))
        }

        // ---- Foto sparite dal disco e tenute lo stesso ----
        // Obbligatoria: senza, la guardia scatta in silenzio e dopo una riorganizzazione
        // legittima continuerebbe a scattare a ogni avvio, per sempre.
        if p.vanishedKept > 0 {
            // Il consiglio cambia col motivo, perche' i due comandi non fanno la stessa cosa:
            // la ricontrollata completa scavalca solo la guardia di plausibilita', mai la
            // traversata incompleta. Consigliarla dopo un'interruzione manderebbe l'utente a
            // rifare quindici minuti di lettura per niente.
            let advice = p.traversalIncomplete
                ? "Finché il controllo non riesce ad arrivare in fondo, l'app non toglie niente dall'elenco: riprova con l'SSD collegato e senza interromperlo."
                : "Se hai spostato o riorganizzato le cartelle sull'SSD, usa «\(LibraryIndexCommands.fullRecheck)» per rimettere in pari l'elenco."
            let kept = p.vanishedKept == 1 ? "ed è stata lasciata" : "e sono state lasciate"
            out.append(Line(id: "sparite", tone: .warning, text:
                "\(count(p.vanishedKept, "foto risulta sparita", "foto risultano sparite")) dall'SSD \(kept) nell'elenco per sicurezza. " + advice))
        }

        // ---- Informazioni neutre: non sono problemi, ma spiegano perche' i numeri non tornano ----
        if p.errors > 0 {
            let entrati = p.errors == 1 ? "è entrato" : "sono entrati"
            let copiati = p.errors == 1 ? "verrà copiato" : "verranno copiati"
            out.append(Line(id: "errori", tone: .info, text:
                "\(count(p.errors, "file non si è lasciato leggere", "file non si sono lasciati leggere")) e non \(entrati) nell'elenco: "
                + "in un'importazione \(copiati) comunque."))
        }
        if p.outsideRoot > 0 {
            let ignorati = p.outsideRoot == 1 ? "ed è stato ignorato" : "e sono stati ignorati"
            out.append(Line(id: "fuori", tone: .info, text:
                "\(count(p.outsideRoot, "file si trovava", "file si trovavano")) fuori dall'SSD \(ignorati)."))
        }
        if p.rebasedByTimezone > 0 {
            out.append(Line(id: "fuso", tone: .info, text:
                "\(count(p.rebasedByTimezone, "foto rimessa in pari", "foto rimesse in pari")) dopo un cambio dell'ora: non è un problema."))
        }

        if out.isEmpty {
            out.append(Line(id: "ok", tone: .ok, text:
                "Ultimo controllo completato: l'elenco è in pari con quello che c'è sull'SSD."))
        }
        return out
    }

    private static func number(_ n: Int) -> String { n.formatted() }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(number(n)) \(n == 1 ? singular : plural)"
    }
}

/// Quando i comandi manuali della card possono essere usati, e **perche' no** quando non
/// possono.
///
/// Nasce da un rilievo minore di #31 chiuso il 2026-09-01: l'aggiornamento automatico
/// sapeva di un job di copia in corso (`LibraryIndexAutoRefresh.shouldRun`, parametro
/// `jobIsRunning`) mentre i bottoni della card no — erano disattivati solo durante una
/// lettura. Chi premeva «\(LibraryIndexCommands.refresh)» durante un backup faceva leggere
/// e rihashare per intero l'SSD mentre una copia ci stava scrivendo sopra: le due operazioni
/// si rallentano a vicenda e i file che la copia sta scrivendo proprio ora finiscono contati
/// come illeggibili. E' la stessa classe di problema chiusa il 2026-09-01 nel pannello
/// Doppioni, dove le precondizioni del blocco venivano valutate una volta sola.
///
/// Restituisce **il motivo scritto**, non un booleano: disattivare un bottone senza dire
/// perche' e' la disciplina che questo progetto ha gia' scelto contro, in `RestoreView`
/// (fonti non disponibili) e nel pannello Doppioni.
enum LibraryIndexCommandGate {
    /// `nil` quando i comandi si possono usare. La lettura in corso ha la precedenza sul job
    /// perche' e' la causa piu' vicina a quello che l'utente sta guardando: se sta scorrendo
    /// la barra di avanzamento, la frase sul backup lo confonderebbe.
    static func disabledReason(isIndexing: Bool, jobIsRunning: Bool) -> String? {
        if isIndexing {
            return "L'app sta già leggendo le foto sull'SSD. Aspetta che finisca, "
                + "oppure fermala con «\(LibraryIndexCommands.stop)»."
        }
        if jobIsRunning {
            return "C'è un backup in corso. Leggere tutte le foto dell'SSD mentre una copia "
                + "ci sta scrivendo sopra rallenta entrambe le cose, e i file che vengono "
                + "scritti proprio ora risulterebbero illeggibili. Riprova a backup finito."
        }
        return nil
    }
}

/// Quando l'elenco puo' aggiornarsi da solo. Pura e in un punto solo perche' i richiami sono
/// due (SSD collegato, fine di un job che ha scritto sull'SSD) e devono decidere allo stesso
/// modo.
enum LibraryIndexAutoRefresh {
    static let defaultsKey = "autoRefreshLibraryIndex"

    /// L'interruttore vale `true` finche' l'utente non lo tocca. `UserDefaults.bool` non va
    /// bene: risponde `false` per una chiave mai scritta, e `@AppStorage` la scrive solo al
    /// primo cambiamento — l'aggiornamento automatico resterebbe spento per default, al
    /// contrario di quello che dice l'interruttore in Impostazioni.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// - `indexedFileCount == 0`: la **prima** creazione non parte mai da sola, dura minuti e
    ///   legge per intero ogni foto e ogni video (Task 6, Step 4).
    /// - `isIndexing`: una lettura per volta, sempre sulla stessa istanza dello store.
    /// - `jobIsRunning`: una lettura integrale dell'SSD in parallelo a una copia rallenta
    ///   entrambe e conta come illeggibili i file che la copia sta scrivendo proprio ora.
    static func shouldRun(enabled: Bool, indexedFileCount: Int, isIndexing: Bool, jobIsRunning: Bool) -> Bool {
        enabled && indexedFileCount > 0 && !isIndexing && !jobIsRunning
    }
}

/// Hash di un file **piu' la dimensione misurata sullo stesso descrittore**.
struct MeasuredHash {
    let hash: String
    /// Byte effettivamente letti e hashati. Coincide con la dimensione del file
    /// misurata via `fstat` prima E dopo la lettura, altrimenti l'hash non viene
    /// restituito affatto.
    let size: Int64
}

/// Legge un file una volta sola e restituisce hash e dimensione **dallo stesso
/// descrittore aperto**, oppure `nil` se il file si e' mosso sotto di noi.
///
/// Perche' la dimensione la misura questa funzione e non il chiamante (misurato il
/// 2026-08-26): `URL.resourceValues(forKeys:)` restituisce valori **in cache
/// sull'istanza di URL**, e gli URL prodotti da `FileManager.enumerator` arrivano con
/// i valori gia' prefetchati alla lettura della directory. Rileggere la dimensione
/// dallo stesso `url` dopo l'hash ritorna quindi il valore di prima anche se il file
/// nel frattempo e' stato troncato:
///
///     stessa URL (anche dall'enumeratore): 5000 -> 5000 dopo troncamento a 6 byte
///     URL(fileURLWithPath: url.path) nuova: 6
///
/// Un confronto "dimensione prima vs dimensione dopo" fatto sullo stesso URL e' quindi
/// **vero per costruzione**: era la difesa contro le letture troncate e non poteva
/// scattare. Il caso reale misurato: file da 5000 byte troncato a 6 durante la
/// scansione, entry salvata con `size=5000` e l'hash dei 6 byte. Quell'hash decide poi
/// se **saltare un file in import**: e' il percorso ad alto danno.
///
/// Tre condizioni, tutte sullo stesso `fd`, tutte necessarie:
/// 1. `fstat` prima della lettura,
/// 2. byte effettivamente letti,
/// 3. `fstat` dopo la lettura.
/// Se le tre non coincidono, il file e' cambiato durante la lettura e l'hash non vale
/// niente: meglio nessun hash che un hash su una lettura parziale. Verificato: un file
/// da 200MB troncato a meta' hashing produceva prima un hash valido a tutti gli effetti,
/// ora `nil`; un file stabile non produce mai falsi positivi.
///
/// Uno scollegamento del volume e' invece intercettato PRIMA, da `read()` che fallisce
/// con EIO — verificato su un'immagine exFAT scollegata con `hdiutil detach -force`
/// durante la lettura: `read()` -> errno 5 dopo 31.784.960 byte su 83.886.080. Sono due
/// guardie distinte per due guasti distinti, e nel caso dello scollegamento e' sempre
/// stata la seconda a scattare, mai il confronto sulle dimensioni.
func sha256Measured(of url: URL) -> MeasuredHash? {
    // I/O POSIX a basso livello (open/read/close) invece di FileHandle.readData(ofLength:):
    // su file molto grandi (decine di GB), FileHandle/NSData tende a mantenere le pagine
    // lette residenti in memoria invece di rilasciarle tra una lettura e l'altra, facendo
    // crescere l'uso di RAM in proporzione al file letto anche leggendo a blocchi di 64KB —
    // causa reale di un blocco per esaurimento memoria osservato durante un restore locale
    // con file da 40-50GB (verificato: stesso hash, da 4GB di picco memoria per un file da
    // 2GB con FileHandle a ~60MB con questa versione). Vedi Docs/CLAUDE.md.
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var before = stat()
    guard fstat(fd, &before) == 0 else { return nil }

    var hasher = SHA256()
    let bufSize = 65536
    var buffer = [UInt8](repeating: 0, count: bufSize)
    var bytesRead: Int64 = 0

    while true {
        let n = buffer.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress, bufSize)
        }
        // n < 0: errore di lettura. E' qui che si manifesta uno scollegamento del
        // volume a meta' file (EIO), e non indicizzare e' l'unica risposta corretta.
        if n < 0 { return nil }
        if n == 0 { break }
        bytesRead += Int64(n)
        buffer.withUnsafeBufferPointer { ptr in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: ptr.baseAddress, count: n))
        }
    }

    var after = stat()
    guard fstat(fd, &after) == 0 else { return nil }
    guard before.st_size == after.st_size, bytesRead == Int64(after.st_size) else { return nil }

    return MeasuredHash(hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                        size: bytesRead)
}

/// Hash di un file, senza la dimensione. Delega a `sha256Measured` per non avere due
/// cicli di lettura da tenere allineati.
///
/// Conseguenza voluta del passaggio: un file che **cambia dimensione mentre lo si
/// legge** ora produce `nil` per tutti i chiamanti (verifica post-copia, campione di
/// integrita', confronto con S3), non solo per l'indice. E' il verso sicuro — un hash
/// calcolato su una lettura parziale non deve valere da nessuna parte.
///
/// ATTENZIONE, e' qui che si e' sbagliato una volta: NON e' vero che a valle `nil` sia
/// trattato ovunque come "errore, non fidarsi". Verificato call site per call site il
/// 2026-08-26: e' vero per 4 dei 5 chiamanti di questa funzione
/// (`ImmichManager.downloadToTemporaryFile`, i due hash di `sampleLocalPair`, i due di
/// `sampleS3Pair`) ed era **falso proprio per `FileSyncer.syncFile`**, l'unico ad alto
/// danno: il `nil` cadeva nel ramo `else` del confronto e la copia veniva contata fra
/// quelle verificate. Corretto (contatore `copiedUnverified`). Prima di allargare
/// ancora i casi di `nil`, ricontrollare i chiamanti uno per uno invece di fidarsi di
/// questa frase.
func sha256(of url: URL) -> String? {
    sha256Measured(of: url)?.hash
}

// MARK: - BookmarkManager
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()
    @Published var pendingAlert: SimpleAlert? = nil

    enum Location: String, CaseIterable, Identifiable {
        case photos, ssd, hdd
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .photos: return "Libreria Foto (originals)"
            case .ssd: return "SSD esterno"
            case .hdd: return "HDD esterno"
            }
        }
        var hint: String {
            switch self {
            case .photos: return "Naviga dentro Photos Library.photoslibrary e seleziona la cartella 'originals'"
            case .ssd:    return "Seleziona il volume SSD (es. /Volumes/SSD - Enri)"
            case .hdd:    return "Seleziona il volume HDD (es. /Volumes/BackupHDD)"
            }
        }
    }

    @Published var urls: [Location: URL] = [:]

    private init() {
        for loc in Location.allCases {
            if let url = resolve(loc) {
                urls[loc] = url
                // Backfill dell'UUID di volume per i bookmark salvati prima che esistesse
                // (roadmap #28): finché il volume è montato è l'unico momento in cui si può
                // ricavare. Best-effort e silenzioso, stesso criterio dell'adozione Keychain
                // di `S3Syncer.readConfig()`.
                persistVolumeUUID(for: loc, url: url)
            }
        }
    }

    static func bookmarkKey(_ loc: Location) -> String { "bk_\(loc.rawValue)" }
    static func volumeUUIDKey(_ loc: Location) -> String { "bk_\(loc.rawValue)_volumeUUID" }

    /// True se per questa posizione esiste un bookmark salvato, **anche se in questo momento non
    /// si risolve** (volume scollegato, o collegato ma non montato). Serve a distinguere
    /// "mai configurato" da "configurato ma non disponibile adesso": `urls[loc] == nil` da solo
    /// non permette di distinguerli, e chi deve decidere qualcosa di distruttivo (roadmap #28,
    /// `DiskFormatter`) non può trattare i due casi allo stesso modo.
    func hasSavedBookmark(_ loc: Location) -> Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkKey(loc)) != nil
    }

    /// UUID del volume associato al bookmark, persistito accanto ad esso: a differenza del path
    /// risolto sopravvive allo smontaggio del volume, e a differenza del nome non cambia se
    /// l'utente rinomina il disco.
    func savedVolumeUUID(_ loc: Location) -> String? {
        UserDefaults.standard.string(forKey: Self.volumeUUIDKey(loc))
    }

    /// Verificato empiricamente il 2026-08-23: `volumeUUIDString` coincide esattamente con il
    /// campo `VolumeUUID` del plist di `diskutil` (confrontato su `/Volumes/SSD - Enri` reale e
    /// su un volume ExFAT di prova), ed è per questo che i due possono essere confrontati.
    private func persistVolumeUUID(for loc: Location, url: URL) {
        guard let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
              !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid.uppercased(), forKey: Self.volumeUUIDKey(loc))
    }

    var allConfigured: Bool { Location.allCases.allSatisfy { urls[$0] != nil } }
    // Solo la Libreria Foto è obbligatoria per entrare nell'app: SSD e HDD sono dischi
    // esterni che potrebbero non essere collegati in questo momento, e le operazioni
    // dentro ContentView già gestiscono da sole un volume non disponibile (bottone
    // disattivato) invece di bloccare tutto.
    var canEnterApp: Bool { urls[.photos] != nil }

    private func resolve(_ loc: Location) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey(loc)) else { return nil }
        var stale = false
        // Bookmark non security-scoped: l'app non è sandboxata (ENABLE_APP_SANDBOX = NO) e ha
        // Full Disk Access, quindi non serve il meccanismo di scope — che oltretutto fallisce
        // in modo affidabile sulla root di volumi ExFAT (NSCocoaErrorDomain 256). I bookmark
        // creati in passato con .withSecurityScope si risolvono comunque correttamente qui.
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        return url
    }

    func startAccessing(_ loc: Location) -> URL? {
        urls[loc]
    }

    func stopAccessing(_ loc: Location) {
        // no-op: senza security scope non c'è nulla da rilasciare (vedi resolve()).
    }

    func selectAndSave(_ loc: Location, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = true
            panel.message = loc.hint
            panel.prompt = "Seleziona"
            guard panel.runModal() == .OK, let url = panel.url else { completion(false); return }
            do {
                // Niente .withSecurityScope: fallisce in modo affidabile sulla root di volumi
                // ExFAT (NSCocoaErrorDomain 256) e qui non serve comunque — l'app non è
                // sandboxata e ha Full Disk Access, quindi FileManager legge/scrive ovunque
                // senza bisogno del meccanismo di scope.
                let data = try url.bookmarkData(options: [],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey(loc))
                self.urls[loc] = url
                // L'UUID del volume viene salvato adesso, che è l'unico momento in cui il volume
                // è certamente montato: è il secondo criterio con cui `DiskFormatter` esclude un
                // disco di backup dalla formattazione anche quando non è montato (roadmap #28).
                self.persistVolumeUUID(for: loc, url: url)
                completion(true)
            } catch {
                // Alert mantenuto per diagnosticare eventuali fallimenti futuri (prima di questo
                // fix, un errore qui spariva senza traccia — vedi Docs/CLAUDE.md).
                let nsError = error as NSError
                print("selectAndSave(\(loc.rawValue)) bookmarkData FAILED for \(url.path): domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
                self.pendingAlert = SimpleAlert(
                    title: "Impossibile salvare '\(loc.displayName)'",
                    message: "Percorso: \(url.path)\n\nErrore: \(nsError.localizedDescription)\n(dominio \(nsError.domain), codice \(nsError.code))")
                completion(false)
            }
        }
    }
}

// MARK: - ImportSessionIndex

/// Doppioni interni allo stesso import (roadmap #31): ricorda le coppie
/// (dimensione, hash) dei file copiati in **questo** job, che l'indice persistito
/// non puo' ancora conoscere perche' viene aggiornato solo a import finito.
///
/// Vive in memoria e muore col job: non e' una seconda scrittura sullo store, che
/// resta a batch post-import (ADR-0002 e ADR-0003).
///
/// Ci si registra **solo** un file la cui verifica d'integrita' post-copia e'
/// riuscita: l'hash di una copia con mismatch e' esattamente quello di cui non ci
/// si puo' fidare, e lo stesso vale per una copia non verificabile
/// (`copiedUnverified`), dove la verifica non ha proprio concluso.
///
/// Questi hash **non godono comunque di una fiducia diversa** da quelli dell'indice:
/// anche un candidato copiato in sessione viene riletto e rihashato prima di
/// dichiarare il doppione (ADR-0003). "Quando si salta un file si rilegge, sempre"
/// e' una regola che si ricorda; "si rilegge tranne nel caso X" no.
///
/// Thread-safety: `FileSyncer` gira su una coda di lavoro globale, non sul
/// MainActor. Il lock e' economico (un solo accesso per file) e toglie di mezzo la
/// domanda "e se un giorno la copia diventasse concorrente?".
final class ImportSessionIndex {
    private var bySize: [Int64: [(hash: String, url: URL)]] = [:]
    private let lock = NSLock()

    func record(hash: String, at url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        lock.lock(); defer { lock.unlock() }
        bySize[Int64(size), default: []].append((hash: hash, url: url))
    }

    func candidates(withSize size: Int64) -> [(hash: String, url: URL)] {
        lock.lock(); defer { lock.unlock() }
        return bySize[size] ?? []
    }
}

// MARK: - FileSyncer
final class FileSyncer {
    struct SyncResult {
        var total = 0; var done = 0; var copied = 0; var skipped = 0; var errors = 0
        var hashErrors = 0   // file con SHA256 mismatch dopo la copia
        /// File copiati che NON e' stato possibile verificare: uno dei due hash e'
        /// tornato `nil` (file cresciuto o troncato mentre lo leggevamo, errore di
        /// lettura, volume scollegato). NON e' un mismatch — il file quasi certamente
        /// sta bene, semplicemente non l'abbiamo potuto confermare — e per questo ha un
        /// contatore suo: riusare `hashErrors` sovrastimerebbe le corruzioni e con il
        /// tempo insegnerebbe all'utente a ignorare quell'allarme. Quello che NON puo'
        /// succedere e' che finisca fra i `copied`, cioe' fra i verificati.
        var copiedUnverified = 0
        var changedSkipped = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
        /// File non copiati perche' lo stesso contenuto e' gia' presente altrove nella
        /// libreria (roadmap #31). Un solo contatore per i due scenari — reimport di una
        /// sorgente gia' importata e doppione interno allo stesso import — perche' per
        /// l'utente sono la stessa cosa ("questa foto ce l'avevi gia'").
        /// E' un sottoinsieme di `skipped`, come `changedSkipped`.
        var duplicatesSkipped = 0
        var startDate = Date()
        var percent: Int { total > 0 ? min(100, done * 100 / total) : 0 }
        var elapsedSec: Int { Int(Date().timeIntervalSince(startDate)) }
        var etaSec: Int {
            guard done > 0, total > done else { return 0 }
            let elapsed = Date().timeIntervalSince(startDate)
            guard elapsed > 0.5 else { return 0 }
            return Int(elapsed * Double(total - done) / Double(done))
        }
        static func hms(_ s: Int) -> String {
            String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
        }
    }

    private var cancelled = false
    private let fm = FileManager.default

    /// Funzione di hash usata dalla verifica post-copia. In produzione e' sempre la
    /// vera `sha256(of:)` (parametro con default): l'iniezione esiste perche' i tre
    /// esiti della verifica — verificato, mismatch, non verificabile — non sono
    /// altrimenti producibili da un test senza una corsa fra thread, e un test basato
    /// su una corsa e' verde col bug ogni volta che la corsa va nell'altro verso.
    /// Il ramo "non verificabile" era completamente scoperto fino al 2026-08-26.
    private let hashFunction: (URL) -> String?

    init(hashFunction: @escaping (URL) -> String? = { sha256(of: $0) }) {
        self.hashFunction = hashFunction
    }

    func cancel() { cancelled = true }

    // MARK: - Dry-run preview (solo stat, nessuna copia)
    func previewSync(from src: URL, to dst: URL, deep: Bool) async
        -> (toAdd: Int, toSkip: Int, toAddBytes: Int64, estimatedSec: Int) {
        return await withCheckedContinuation { [self] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cancelled = false
                var toAdd = 0
                var toSkip = 0
                var toAddBytes: Int64 = 0
                self.previewDir(src: src, dst: dst, deep: deep, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
                let estimatedSec = toAdd > 0 ? max(1, toAdd / 50) : 0
                cont.resume(returning: (toAdd: toAdd, toSkip: toSkip, toAddBytes: toAddBytes, estimatedSec: estimatedSec))
            }
        }
    }

    private func previewDir(src: URL, dst: URL, deep: Bool, toAdd: inout Int, toSkip: inout Int, toAddBytes: inout Int64) {
        if cancelled { return }
        guard let items = try? fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if cancelled { return }
            if shouldExclude(item) { continue }
            let vals = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let destItem = dst.appendingPathComponent(item.lastPathComponent)
            if vals?.isDirectory == true {
                previewDir(src: item, dst: destItem, deep: deep, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
            } else if vals?.isRegularFile == true {
                previewFile(src: item, dst: destItem, toAdd: &toAdd, toSkip: &toSkip, toAddBytes: &toAddBytes)
            }
        }
    }

    private func previewFile(src: URL, dst: URL, toAdd: inout Int, toSkip: inout Int, toAddBytes: inout Int64) {
        // Zero-overwrite rule: se il file esiste gia a destinazione sara sempre skippato
        if fm.fileExists(atPath: dst.path) {
            toSkip += 1
        } else {
            toAdd += 1
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            toAddBytes += Int64(size)
        }
    }

    /// - Parameters:
    ///   - isDuplicate: predicato di dedup per contenuto (roadmap #31), consultato **solo**
    ///     per i file che verrebbero copiati davvero. Default no-op: `runMacToSSD`,
    ///     `runSSDToHDD`, `runSyncS3` e `RestoreEngine` non lo passano e si comportano
    ///     identici a prima.
    ///   - onCopied: notifica di copia **verificata** (dst, hash SHA256 gia' calcolato per
    ///     la verifica d'integrita'). Serve a riconoscere i doppioni interni allo stesso
    ///     import senza rileggere nulla in piu'. Default no-op.
    ///   - onUnverified: notifica di copia **non verificata** (dst): la verifica SHA256 non ha
    ///     potuto concludersi. E' un callback e non un campo di `SyncResult` di proposito: il
    ///     debito va scritto nell'istante in cui viene contratto, cosi' sopravvive anche a un
    ///     job interrotto dall'utente o a un errore, dove `SyncResult` non arriva mai al
    ///     chiamante. Default no-op.
    func sync(from src: URL, to dst: URL, deep: Bool,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in },
              isDuplicate: @escaping (URL) -> Bool = { _ in false },
              onCopied: @escaping (URL, String) -> Void = { _, _ in },
              onUnverified: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
        try await withCheckedThrowingContinuation { [self] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cancelled = false
                var result = SyncResult()

                DispatchQueue.main.async { onStatus("Conteggio file in corso...") }
                result.total = self.countFiles(at: src)
                guard result.total > 0 else {
                    DispatchQueue.main.async {
                        onStatus("Nessun file trovato in '\(src.path)' — verifica il bookmark in Impostazioni")
                        onProgress(result)
                    }
                    cont.resume(returning: result)
                    return
                }

                DispatchQueue.main.async {
                    onStatus("Trovati \(result.total) file — avvio sincronizzazione...")
                    onProgress(result)
                }

                do {
                    if !self.fm.fileExists(atPath: dst.path) {
                        try self.fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    }
                    try self.syncDir(src: src, dst: dst, base: src, deep: deep,
                                     result: &result, onStatus: onStatus, onProgress: onProgress,
                                     onCurrentFile: onCurrentFile,
                                     isDuplicate: isDuplicate, onCopied: onCopied,
                                     onUnverified: onUnverified)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func countFiles(at url: URL) -> Int {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        while let f = e.nextObject() as? URL {
            if cancelled { break }
            if shouldExclude(f) { e.skipDescendants(); continue }
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 }
        }
        return n
    }

    private func syncDir(src: URL, dst: URL, base: URL, deep: Bool,
                         result: inout SyncResult,
                         onStatus: @escaping (String) -> Void,
                         onProgress: @escaping (SyncResult) -> Void,
                         onCurrentFile: @escaping (URL) -> Void,
                         // Niente valori di default su `syncDir`/`syncFile`, che sono privati:
                         // un default trasformerebbe una propagazione dimenticata in un cambio
                         // di comportamento silenzioso invece che in un errore di compilazione.
                         // Su `sync`, che e' pubblico, il default e' il punto del pattern.
                         isDuplicate: @escaping (URL) -> Bool,
                         onCopied: @escaping (URL, String) -> Void,
                         onUnverified: @escaping (URL) -> Void) throws {
        if cancelled { return }
        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }
        let items = try fm.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                          .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        for item in items {
            if cancelled { return }
            if shouldExclude(item) { continue }
            let vals = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let destItem = dst.appendingPathComponent(item.lastPathComponent)
            if vals?.isDirectory == true {
                try syncDir(src: item, dst: destItem, base: base, deep: deep,
                            result: &result, onStatus: onStatus, onProgress: onProgress,
                            onCurrentFile: onCurrentFile,
                            isDuplicate: isDuplicate, onCopied: onCopied,
                            onUnverified: onUnverified)
            } else if vals?.isRegularFile == true {
                syncFile(src: item, dst: destItem, deep: deep,
                         result: &result, onStatus: onStatus, onProgress: onProgress,
                         onCurrentFile: onCurrentFile,
                         isDuplicate: isDuplicate, onCopied: onCopied,
                         onUnverified: onUnverified)
            }
        }
    }

    private func syncFile(src: URL, dst: URL, deep: Bool,
                          result: inout SyncResult,
                          onStatus: @escaping (String) -> Void,
                          onProgress: @escaping (SyncResult) -> Void,
                          onCurrentFile: @escaping (URL) -> Void,
                          isDuplicate: @escaping (URL) -> Bool,
                          onCopied: @escaping (URL, String) -> Void,
                          onUnverified: @escaping (URL) -> Void) {
        let needs: Bool
        if !fm.fileExists(atPath: dst.path) {
            needs = true
        } else {
            let sa = try? fm.attributesOfItem(atPath: src.path)
            let da = try? fm.attributesOfItem(atPath: dst.path)
            let ss = sa?[.size] as? Int ?? -1; let ds = da?[.size] as? Int ?? -2
            if deep {
                needs = ss != ds
            } else {
                let sm = sa?[.modificationDate] as? Date ?? .distantPast
                let dm = da?[.modificationDate] as? Date ?? .distantPast
                needs = ss != ds || abs(sm.timeIntervalSince(dm)) > 1.0
            }
        }

        if needs {
            if fm.fileExists(atPath: dst.path) {
                // destination exists but differs — zero-overwrite rule: skip
                result.skipped += 1
                result.changedSkipped += 1
            } else if isDuplicate(src) {
                // Dedup per contenuto (roadmap #31): il file esiste gia' altrove nella
                // libreria con contenuto byte-identico (verificato rileggendo e
                // rihashando il candidato, ADR-0003). Non e' un errore e non e' un file
                // "cambiato": ha un contatore suo, per non confondersi con
                // `changedSkipped` (#13). Conta anche come `skipped`, cosi'
                // copied + skipped + errors + hashErrors + copiedUnverified continua a
                // fare `done`.
                //
                // L'ordine dei due rami e' load-bearing: lo zero-overwrite resta la
                // PRIMA regola, il dedup e' un ramo dello stesso `if` e non un `return`
                // anticipato — un `return` salterebbe `result.done += 1` e la
                // `onProgress` finale, piantando la barra di avanzamento sui doppioni.
                result.skipped += 1
                result.duplicatesSkipped += 1
                let name = src.lastPathComponent
                DispatchQueue.main.async { onStatus("Già in libreria, non copiato: \(name)") }
            } else {
                let snap = result
                DispatchQueue.main.async {
                    onStatus("Copia (\(snap.done + 1)/\(snap.total) — \(snap.percent)%): \(src.lastPathComponent)")
                    onCurrentFile(src)
                }
                do {
                    let parent = dst.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parent.path) {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    try fm.copyItem(at: src, to: dst)
                    DispatchQueue.main.async { onStatus("Verifica integrità: \(src.lastPathComponent)") }
                    // Tre esiti distinti, mai due. Il `nil` (file cresciuto o troncato
                    // mentre lo leggevamo, errore di lettura, volume scollegato) NON e'
                    // un mismatch e NON e' una verifica riuscita: prima finiva nel ramo
                    // `else` insieme agli hash uguali, cioe' una copia non verificata
                    // veniva contata fra quelle verificate. Misurato il 2026-08-26 con
                    // una sorgente da 200MB che cresce durante la verifica post-copia:
                    // `copied=1 hashErrors=0` con src 259MB e dst 210MB, hash diversi.
                    // Per la regola zero-overwrite quel file parziale a destinazione non
                    // verra' MAI ricopiato (le sync successive lo contano
                    // `changedSkipped`), quindi il silenzio qui e' definitivo.
                    let srcHash = hashFunction(src)
                    let dstHash = hashFunction(dst)
                    let name = src.lastPathComponent
                    if let srcHash, let dstHash {
                        if srcHash == dstHash {
                            result.copied += 1
                            // roadmap #31: l'hash della verifica esiste gia', non buttarlo
                            // via. Solo qui, cioe' solo con verifica RIUSCITA su entrambi i
                            // lati: l'hash di una copia con mismatch e' quello di cui non ci
                            // si puo' fidare, e in `copiedUnverified` la verifica non ha
                            // proprio concluso. Verso sicuro: al massimo un doppione interno
                            // non viene riconosciuto e il file viene copiato due volte.
                            onCopied(dst, srcHash)
                        } else {
                            result.hashErrors += 1   // mismatch SHA256: conteggiato separato da errori I/O
                            DispatchQueue.main.async { onStatus("⚠️ HASH MISMATCH: \(name) — copia non integra, controlla il log") }
                        }
                    } else {
                        result.copiedUnverified += 1
                        // Il debito di verifica si annota qui, non a fine job: per la regola
                        // zero-overwrite questo file non verra' MAI ricopiato, quindi se il
                        // percorso si perde nessuno lo ricontrollera' piu'. Lo raccoglie il
                        // campione d'integrita' del pannello Revisione, che gira a distanza
                        // di tempo quando la sorgente non e' piu' in uso.
                        onUnverified(dst)
                        DispatchQueue.main.async { onStatus("⚠️ Copiato ma non verificato: \(name) — la verifica SHA256 non ha potuto concludersi") }
                    }
                } catch { result.errors += 1 }
            }
        } else {
            result.skipped += 1
        }
        result.done += 1
        let snap = result
        DispatchQueue.main.async { onProgress(snap) }
    }

    private func shouldExclude(_ url: URL) -> Bool {
        LibraryExclusions.shouldExclude(url)
    }

}

// MARK: - S3Syncer (native Swift, no rclone subprocess)
final class S3Syncer {

    // BUG-3: una key già presente su S3 non va mai ricaricata, indipendentemente
    // dalla dimensione locale — ricaricare sovrascriverebbe l'oggetto esistente via
    // PUT, violando zero-overwrite. Solo le key davvero assenti vengono caricate.
    static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
        !existingKeys.contains(key)
    }

    // Conteggio informativo per roadmap #13 (segnalazione, non azione): una key già
    // presente su S3 con dimensione diversa da quella locale. Non influenza in alcun
    // modo shouldUpload/la decisione di caricare.
    static func isChangedExistingKey(key: String, size: Int64, existing: [String: Int64]) -> Bool {
        guard let existingSize = existing[key] else { return false }
        return existingSize != size
    }

    struct S3Config {
        let accessKeyId: String
        let secretAccessKey: String
        let endpoint: String
        let region: String
        let bucket: String
    }

    struct S3HTTPError: Error {
        let statusCode: Int
        let message: String
    }

    struct OrphanedMultipartUpload: Identifiable {
        let id = UUID()
        let key: String
        let uploadId: String
        let initiated: Date
    }

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

    struct SyncResult {
        var uploaded = 0; var skipped = 0; var errors = 0
        var total = 0; var done = 0; var startDate = Date()
        var uploadedBytes: Int64 = 0
        var toUploadCount: Int = 0
        var changedSkipped = 0   // key esistente con dimensione diversa (roadmap #13)
        var percent: Int { total > 0 ? min(100, done * 100 / total) : 0 }
        var elapsedSec: Int { Int(Date().timeIntervalSince(startDate)) }
        // ETA basato sugli upload effettivi (non sui file già presenti su S3)
        var etaSec: Int {
            guard uploaded > 0, toUploadCount > uploaded else { return 0 }
            let elapsed = Date().timeIntervalSince(startDate)
            guard elapsed > 0.5 else { return 0 }
            let rate = Double(uploaded) / elapsed
            return Int(Double(toUploadCount - uploaded) / rate)
        }
        static func hms(_ s: Int) -> String {
            String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
        }
    }

    static func readFileInChunks(path: String, chunkSize: Int,
                                  onChunk: (Data) async throws -> Void) async throws {
        // Stesso principio già in produzione per la funzione top-level sha256(of:):
        // open/read/close POSIX con un buffer riutilizzato, invece di
        // FileHandle.readData(ofLength:), che su file molto grandi mantiene le
        // pagine lette residenti in memoria invece di rilasciarle tra una lettura
        // e l'altra (bug reale osservato e corretto in questa sessione).
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: "S3", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile aprire il file: \(path)"])
        }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            if n < 0 {
                throw NSError(domain: "S3", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Errore di lettura: \(path)"])
            }
            if n == 0 { break }
            try await onChunk(Data(bytes: buffer, count: n))
        }
    }

    // Non private: deve restare visibile a @testable import per i test unitari
    // (stesso criterio già usato per validateEndpoint/isRetryable).
    struct AdaptiveLimiterState: Equatable {
        var limit: Int
        var consecutiveSuccesses: Int
    }

    enum AdaptiveLimiterOutcome {
        case success
        case retryableFailure
        case permanentFailure
    }

    // Logica pura AIMD (Additive Increase / Multiplicative Decrease), separata
    // dall'actor sottostante per essere testabile senza rete/timer. Vedi
    // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
    enum AdaptiveLimiter {
        static let floor = 1
        static let growthStep = 2
        static let successesToGrow = 5

        static func applying(_ outcome: AdaptiveLimiterOutcome, to state: AdaptiveLimiterState,
                              ceiling: Int) -> AdaptiveLimiterState {
            switch outcome {
            case .success:
                let successes = state.consecutiveSuccesses + 1
                guard successes >= successesToGrow else {
                    return AdaptiveLimiterState(limit: state.limit, consecutiveSuccesses: successes)
                }
                return AdaptiveLimiterState(limit: min(ceiling, state.limit + growthStep), consecutiveSuccesses: 0)
            case .retryableFailure:
                return AdaptiveLimiterState(limit: max(floor, state.limit / 2), consecutiveSuccesses: 0)
            case .permanentFailure:
                return state
            }
        }
    }

    // Gate di ammissione a capacità variabile: ogni unità di lavoro di rete (un file
    // intero <64MB, o una singola parte multipart) acquisisce uno slot prima di essere
    // letta/inviata, e lo rilascia (con l'esito) al proprio termine — inclusi eventuali
    // retry interni, che restano nella stessa unità di lavoro. Nessun lock manuale:
    // l'intero stato (limite corrente, contatore successi, slot attivi, task in attesa)
    // è isolato dall'actor.
    actor AdaptiveUploadGate {
        private var state: AdaptiveLimiterState
        private let ceiling: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(startingLimit: Int, ceiling: Int) {
            precondition(startingLimit >= 1, "startingLimit deve essere almeno 1")
            self.state = AdaptiveLimiterState(limit: startingLimit, consecutiveSuccesses: 0)
            self.ceiling = ceiling
        }

        func acquire() async {
            if active < state.limit {
                active += 1
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
            // Lo slot è già stato riservato (active incrementato) da release(),
            // subito prima di risvegliare questo continuation — vedi sotto.
        }

        func release(outcome: AdaptiveLimiterOutcome) {
            precondition(active > 0, "release() chiamato senza uno slot acquisito (doppio release?)")
            active -= 1
            state = AdaptiveLimiter.applying(outcome, to: state, ceiling: ceiling)
            while active < state.limit, !waiters.isEmpty {
                active += 1
                waiters.removeFirst().resume()
            }
        }
    }

    // Costanti condivise: ogni unità di lavoro (file <64MB, o parte multipart) ha corpo
    // HTTP ≤ multipartChunkSize, quindi un tetto sul numero di slot è già equivalente a
    // un tetto sui byte in volo — nessuna contabilità separata necessaria.
    static let multipartChunkSize = 64 * 1024 * 1024
    private static let adaptiveMemoryCeilingBytes = 2 * 1024 * 1024 * 1024
    static let adaptiveConcurrencyCeiling = adaptiveMemoryCeilingBytes / multipartChunkSize

    private var cancelled = false
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    func cancel() { cancelled = true }

    static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        try readConfigWithSource(remoteName: remoteName, bucket: bucket).config
    }

    // Come readConfig, ma segnala anche se il risultato viene dal Keychain o da rclone.conf,
    // in un'unica lettura Keychain: usata dove serve entrambe le informazioni (findings di
    // Revisione + card credenziali in ToolsSheet) per evitare letture Keychain ridondanti —
    // ognuna può richiedere una propria autorizzazione interattiva dell'utente.
    static func readConfigWithSource(remoteName: String = "Cubbit",
                                      bucket: String = "backupfoto") throws -> (config: S3Config, fromKeychain: Bool) {
        if let creds = readFromKeychain(remoteName: remoteName) {
            let cleanEp = try validateEndpoint(creds.endpoint)
            return (S3Config(accessKeyId: creds.accessKeyId, secretAccessKey: creds.secretAccessKey,
                            endpoint: cleanEp, region: creds.region, bucket: bucket), true)
        }
        let config = try readConfigFromFile(remoteName: remoteName, bucket: bucket)
        try? writeToKeychain(config: config, remoteName: remoteName)
        return (config, false)
    }

    // Non private: deve restare richiamabile dal bottone "Aggiorna da rclone.conf" in ToolsSheet.
    static func readConfigFromFile(remoteName: String, bucket: String) throws -> S3Config {
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
            throw NSError(domain: "S3", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "rclone.conf ha permessi troppo aperti. Esegui nel Terminale:\nchmod 600 ~/.config/rclone/rclone.conf"])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var inSection = false
        var vals: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(remoteName)]" { inSection = true; continue }
            if t.hasPrefix("[") { if inSection { break }; continue }
            if inSection, t.contains("=") {
                let p = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 { vals[p[0]] = p[1] }
            }
        }
        guard let ak = vals["access_key_id"], let sk = vals["secret_access_key"],
              let ep = vals["endpoint"] else {
            throw NSError(domain: "S3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Credenziali '\(remoteName)' non trovate in rclone.conf"])
        }
        let cleanEp = try validateEndpoint(ep)
        return S3Config(accessKeyId: ak, secretAccessKey: sk, endpoint: cleanEp,
                        region: vals["region"] ?? "us-east-1", bucket: bucket)
    }

    // Non private: deve restare visibile a @testable import per i test unitari.
    static func validateEndpoint(_ raw: String) throws -> String {
        let cleanEp = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard cleanEp.hasPrefix("https://") else {
            throw NSError(domain: "S3", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "L'endpoint S3 deve usare HTTPS. Valore trovato: '\(cleanEp)'. Correggi rclone.conf."])
        }
        // Allow-list: se rclone.conf viene alterato per puntare a un host diverso da quello
        // atteso, le foto verrebbero caricate verso un endpoint arbitrario. Blocca finché
        // l'utente non conferma il nuovo host di proposito (aggiungendolo qui).
        let allowedHosts: Set<String> = ["s3.it.cubbit.org"]
        guard let host = URL(string: cleanEp)?.host, allowedHosts.contains(host) else {
            throw NSError(domain: "S3", code: 13, userInfo: [NSLocalizedDescriptionKey:
                "Endpoint S3 non riconosciuto: '\(cleanEp)'. Se hai cambiato provider di proposito, aggiorna la allow-list in S3Syncer.validateEndpoint."])
        }
        return cleanEp
    }

    // Dry-run: stessa logica di lista+confronto di sync(), senza caricare nulla.
    // Sul modello di FileSyncer.previewSync, usato dai bottoni 👁 anteprima già esistenti
    // per Mac→SSD e SSD→HDD — SSD→S3 ne era rimasto privo.
    func previewUpload(from localURL: URL, config: S3Config) async throws -> (toUpload: Int, toSkip: Int, bytes: Int64) {
        let existing = try await listAll(config: config)
        let fm = FileManager.default
        var toUpload = 0; var toSkip = 0; var bytes: Int64 = 0
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        while let f = enumerator.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            let size = Int64(v?.fileSize ?? 0)
            if existing[rel] == size {
                toSkip += 1
            } else {
                toUpload += 1; bytes += size
            }
        }
        return (toUpload, toSkip, bytes)
    }

    func sync(from localURL: URL, config: S3Config,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
        cancelled = false
        var result = SyncResult()

        DispatchQueue.main.async { onStatus("Connessione a Cubbit S3 — recupero lista file remoti...") }
        let existing = try await listAll(config: config)
        let existingCount = existing.count
        DispatchQueue.main.async { onStatus("Trovati \(existingCount) oggetti su S3 — scansione file locali...") }

        let fm = FileManager.default
        var files: [(url: URL, key: String, size: Int64)] = []
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        while let f = enumerator.nextObject() as? URL {
            if cancelled { break }
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            files.append((url: f, key: rel, size: Int64(v?.fileSize ?? 0)))
        }

        let existingKeys = Set(existing.keys)
        let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
        result.total = files.count
        result.toUploadCount = toUpload.count
        result.changedSkipped = files.filter {
            S3Syncer.isChangedExistingKey(key: $0.key, size: $0.size, existing: existing)
        }.count
        result.skipped = files.count - toUpload.count
        result.done = result.skipped
        let initSnap = result
        DispatchQueue.main.async {
            onStatus("Trovati \(files.count) file locali · \(toUpload.count) da caricare · \(result.skipped) già presenti")
            onProgress(initSnap)
        }

        // Un solo gate condiviso tra tutti i file e tutte le parti multipart di questo
        // job: file piccoli e grandi competono per lo stesso budget adattivo, invece di
        // due meccanismi di concorrenza separati. Vedi
        // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
        let gate = AdaptiveUploadGate(startingLimit: 4, ceiling: Self.adaptiveConcurrencyCeiling)

        // Finestra sul numero di file "in corso" (dal prologo al completamento),
        // separata dal budget adattivo del gate. Senza questa finestra TUTTI i file di
        // toUpload partirebbero insieme (nessun cap, dato che runBounded è stato
        // rimosso): ogni file ≥64MB alloca un buffer da 64MB e ne copia il contenuto in
        // un'altra Data da 64MB PRIMA di acquisire il primo slot dal gate (multipart()
        // inizia a leggere la prima parte prima che quella parte acquisisca uno slot) —
        // su un job con centinaia di file grandi questo bypassa il tetto di memoria da
        // 2GB del gate (bug reale trovato in review: 375 file >64MB misurati sull'SSD
        // reale avrebbero prodotto ~48GB residenti). Il cap è lo stesso tetto del gate
        // (adaptiveConcurrencyCeiling): oltre quel numero di file "in corso" il gate non
        // farebbe comunque salire la concorrenza di rete effettiva, quindi non è un
        // collo di bottiglia per il throughput.
        await withTaskGroup(of: (url: URL, size: Int64, ok: Bool).self) { group in
            var index = 0
            func addNext() {
                guard index < toUpload.count, !self.cancelled, !Task.isCancelled else { return }
                let item = toUpload[index]; index += 1
                group.addTask { [self] in
                    if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                    do {
                        // onStart annuncia "Carico: X" solo quando il file ottiene
                        // davvero il primo slot di rete dal gate (vedi upload()/
                        // multipart()), non appena il suo task parte — altrimenti, con
                        // fino a `adaptiveConcurrencyCeiling` file avviati insieme, il
                        // log/la miniatura corrente corrono avanti rispetto a quello che
                        // sta davvero caricando.
                        try await self.upload(url: item.url, key: item.key, config: config, gate: gate,
                            onStart: {
                                DispatchQueue.main.async {
                                    onStatus("Carico: \(item.url.lastPathComponent)")
                                    onCurrentFile(item.url)
                                }
                            },
                            onStatus: onStatus)
                        return (item.url, item.size, true)
                    } catch {
                        return (item.url, item.size, false)
                    }
                }
            }
            for _ in 0..<Self.adaptiveConcurrencyCeiling { addNext() }
            while let outcome = await group.next() {
                // Dopo un'interruzione tutti i task ancora in coda tornano subito con
                // ok=false senza aver mai caricato nulla: contarli come errori (e
                // ridisegnare la UI per ognuno) produrrebbe decine di migliaia di falsi
                // errori dopo lo stop. Il vecchio runBounded semplicemente non li
                // schedulava — questa guardia ne conserva il comportamento.
                if self.cancelled || Task.isCancelled { continue }
                if outcome.ok { result.uploaded += 1; result.uploadedBytes += outcome.size }
                else { result.errors += 1 }
                result.done += 1
                let snap = result
                DispatchQueue.main.async { onProgress(snap) }
                addNext()
            }
        }
        return result
    }

    func listAll(config: S3Config) async throws -> [String: Int64] {
        var objects: [String: Int64] = [:]
        var token: String? = nil
        repeat {
            if cancelled || Task.isCancelled { break }
            let (objs, next) = try await listPage(config: config, token: token)
            objects.merge(objs) { _, n in n }
            token = next
        } while token != nil
        return objects
    }

    func listMultipartUploads(config: S3Config) async throws -> [OrphanedMultipartUpload] {
        guard let url = URL(string: "\(config.endpoint)/\(config.bucket)?uploads") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list multipart"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista multipart: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let keys = xmlAll(xml, tag: "Key")
        let uploadIds = xmlAll(xml, tag: "UploadId")
        let initiatedStrings = xmlAll(xml, tag: "Initiated")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var results: [OrphanedMultipartUpload] = []
        let count = min(keys.count, uploadIds.count, initiatedStrings.count)
        for i in 0..<count {
            let initiated = fmt.date(from: initiatedStrings[i]) ?? Date()
            results.append(OrphanedMultipartUpload(key: keys[i], uploadId: uploadIds[i], initiated: initiated))
        }
        return results
    }

    private func listPage(config: S3Config, token: String?) async throws -> ([String: Int64], String?) {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        comps.queryItems = qi
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista S3: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let keys = xmlAll(xml, tag: "Key")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        var objs: [String: Int64] = [:]
        for (k, s) in zip(keys, sizes) { objs[k] = s }
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (objs, nextToken)
    }

    // Come listPage, ma per il Catalogo (roadmap #12): estrae anche LastModified, non solo
    // Key/Size. Funzione separata per non toccare listPage/listAll esistenti, usati da
    // preview/restore/orphaned-uploads.
    func parseCatalogEntries(fromListObjectsXML xml: String) -> [CatalogEntry] {
        let keys = xmlAll(xml, tag: "Key")
        let dates = xmlAll(xml, tag: "LastModified")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let count = min(keys.count, dates.count, sizes.count)
        var entries: [CatalogEntry] = []
        for i in 0..<count {
            let key = keys[i]
            entries.append(CatalogEntry(
                name: (key as NSString).lastPathComponent,
                relativePath: key,
                sizeBytes: sizes[i],
                modified: fmt.date(from: dates[i])))
        }
        return entries
    }

    private func listPageWithDates(config: S3Config, token: String?) async throws -> ([CatalogEntry], String?) {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        comps.queryItems = qi
        guard let url = comps.url else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per list"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "S3", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Errore lista S3: \(body.prefix(300))"])
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let entries = parseCatalogEntries(fromListObjectsXML: xml)
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (entries, nextToken)
    }

    func listAllWithDates(config: S3Config) async throws -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        var token: String? = nil
        repeat {
            if cancelled || Task.isCancelled { break }
            let (page, next) = try await listPageWithDates(config: config, token: token)
            entries.append(contentsOf: page)
            token = next
        } while token != nil
        return entries
    }

    private func retrying<T>(key: String, maxAttempts: Int = 3,
                              onStatus: @escaping (String) -> Void,
                              operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard !cancelled, !Task.isCancelled else { throw error }
                guard attempt < maxAttempts, S3Syncer.isRetryable(error) else { throw error }
                let delaySec = pow(2.0, Double(attempt - 1))   // 1s, 2s
                attempt += 1
                let msg = "Errore di rete su \(key), riprovo tra \(Int(delaySec))s (tentativo \(attempt)/\(maxAttempts))"
                DispatchQueue.main.async { onStatus(msg) }
                try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }

    private func upload(url: URL, key: String, config: S3Config, gate: AdaptiveUploadGate,
                         onStart: @escaping () -> Void,
                         onStatus: @escaping (String) -> Void) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.multipartChunkSize {
            try await multipart(url: url, key: key, config: config, gate: gate, onStart: onStart, onStatus: onStatus)
        } else {
            await gate.acquire()
            if cancelled || Task.isCancelled {
                await gate.release(outcome: .permanentFailure)
                throw CancellationError()
            }
            onStart()
            do {
                // La lettura del file sta DENTRO il do: se fallisce (file illeggibile,
                // volume scollegato a metà job, permessi) lo slot già acquisito va
                // comunque rilasciato, altrimenti resta perso per sempre e la capacità
                // del gate condiviso si riduce fino al blocco totale dei task in attesa.
                let data = try Data(contentsOf: url)
                try await retrying(key: key, onStatus: onStatus) {
                    try await self.put(data: data, key: key, config: config)
                }
                await gate.release(outcome: .success)
            } catch {
                await gate.release(outcome: S3Syncer.isRetryable(error) ? .retryableFailure : .permanentFailure)
                throw error
            }
        }
    }

    private func put(data: Data, key: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let putURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        req.httpBody = data
        sign(&req, config: config, body: data, date: Date())
        let (respData, resp) = try await session.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw S3HTTPError(statusCode: statusCode, message: "Errore PUT \(key): \(body.prefix(100))")
        }
    }

    // Registra solo il primo errore permanente incontrato tra le parti concorrenti di un
    // multipart, per far fermare il loop di lettura al più presto (vedi multipart()).
    private actor FirstFailureRecorder {
        private var error: Error?
        func record(_ error: Error) { if self.error == nil { self.error = error } }
        func current() -> Error? { error }
    }

    private func multipart(url: URL, key: String, config: S3Config, gate: AdaptiveUploadGate,
                            onStart: @escaping () -> Void,
                            onStatus: @escaping (String) -> Void) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let initURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploads") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }

        let uploadId = try await retrying(key: key, onStatus: onStatus) { () async throws -> String in
            var initReq = URLRequest(url: initURL)
            initReq.httpMethod = "POST"
            self.sign(&initReq, config: config, body: Data(), date: Date())
            let (initData, initResp) = try await self.session.data(for: initReq)
            guard let code = (initResp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
                let statusCode = (initResp as? HTTPURLResponse)?.statusCode ?? -1
                throw S3HTTPError(statusCode: statusCode, message: "Impossibile avviare multipart per \(key)")
            }
            guard let uploadId = self.xmlFirst(String(data: initData, encoding: .utf8) ?? "", tag: "UploadId") else {
                throw NSError(domain: "S3", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Impossibile avviare multipart per \(key)"])
            }
            return uploadId
        }
        let encId = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId

        // Le parti si leggono in sequenza da disco (I/O locale, veloce) ma si inviano in
        // parallelo: ogni parte viene letta e poi acquisisce uno slot dal gate prima di
        // essere spedita — il loop di lettura resta comunque al passo con la capacità di
        // rete corrente (al più un chunk extra da 64MB oltre al limite corrente resta in
        // memoria in attesa di uno slot libero). Il numero di file ≥64MB che possono
        // essere qui contemporaneamente, ciascuno con questo margine, è a sua volta
        // limitato dalla finestra di sync() (vedi commento lì) — senza quella finestra
        // questo margine non sarebbe affatto trascurabile su un job con centinaia di
        // file grandi.
        var parts: [(partNumber: Int, etag: String)] = []
        var pn = 1
        var announced = false

        // Un fallimento (permanente o da cancellazione) fa uscire il blocco sotto con un
        // throw prima di raggiungere la guardia post-loop (righe sotto) — senza questo
        // do/catch quel throw scavalcherebbe anche l'abort, lasciando orfane sul bucket
        // tutte le parti già caricate invece delle sole poche in volo al momento
        // dell'errore. Non tocca dati già scritti (AbortMultipartUpload è esente dalla
        // regola zero-delete, vedi Docs/CLAUDE.md) e non sostituisce la guardia sotto,
        // che resta necessaria per il caso "tutte le parti completate ma cancellazione
        // richiesta subito dopo l'ultima".
        do {
            try await withThrowingTaskGroup(of: (partNumber: Int, etag: String).self) { group in
                // Un errore permanente su una parte deve fermare la lettura al più presto,
                // non solo essere rilanciato alla fine: senza questo flag il loop di lettura
                // (che non chiama group.next() finché non ha finito) continuerebbe a leggere
                // e caricare tutte le parti restanti di un file da decine di GB prima di
                // accorgersi del fallimento — bug reale trovato in review, il vecchio codice
                // sequenziale si fermava subito. Deve essere un throw, non un return: un
                // return lascerebbe `parts` troncato e la guardia sotto (cancelled/
                // Task.isCancelled) sarebbe falsa, ricreando l'oggetto troncato che la
                // guardia stessa esiste per evitare.
                let firstFailure = FirstFailureRecorder()

                try await S3Syncer.readFileInChunks(path: url.path, chunkSize: Self.multipartChunkSize) { chunk in
                    if let failure = await firstFailure.current() { throw failure }
                    guard !self.cancelled else { return }
                    await gate.acquire()
                    if self.cancelled || Task.isCancelled {
                        await gate.release(outcome: .permanentFailure)
                        return
                    }
                    // Annuncia il file solo ora che la sua prima parte ha davvero
                    // ottenuto uno slot di rete, non quando il file entra in multipart()
                    // (che parte prima di qualunque acquire, vedi sopra) — coerente con
                    // onStart nel ramo file-singolo di upload(). `announced` è letto e
                    // scritto solo da questa closure di lettura, mai dai task figli, che
                    // gira sempre in sequenza: nessuna corsa critica.
                    if !announced { announced = true; onStart() }
                    let partNumber = pn
                    pn += 1
                    guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(partNumber)&uploadId=\(encId)") else {
                        await gate.release(outcome: .permanentFailure)
                        throw NSError(domain: "S3", code: 12,
                            userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(partNumber) di \(key)"])
                    }
                    group.addTask {
                        do {
                            let etag = try await self.retrying(key: "\(key) (parte \(partNumber))", onStatus: onStatus) { () async throws -> String in
                                var pReq = URLRequest(url: pURL)
                                pReq.httpMethod = "PUT"; pReq.httpBody = chunk
                                self.sign(&pReq, config: config, body: chunk, date: Date())
                                let (_, pResp) = try await self.session.data(for: pReq)
                                guard let pHttp = pResp as? HTTPURLResponse, (200...299).contains(pHttp.statusCode) else {
                                    let statusCode = (pResp as? HTTPURLResponse)?.statusCode ?? -1
                                    throw S3HTTPError(statusCode: statusCode, message: "Errore parte \(partNumber) di \(key)")
                                }
                                return pHttp.value(forHTTPHeaderField: "Etag") ?? ""
                            }
                            await gate.release(outcome: .success)
                            return (partNumber, etag)
                        } catch {
                            await gate.release(outcome: S3Syncer.isRetryable(error) ? .retryableFailure : .permanentFailure)
                            await firstFailure.record(error)
                            throw error
                        }
                    }
                }

                while let next = try await group.next() {
                    parts.append(next)
                }
            }
        } catch {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw error
        }

        // Deve coprire ESATTAMENTE le stesse condizioni per cui il loop sopra salta una
        // parte (`self.cancelled || Task.isCancelled`): se una parte è stata saltata, la
        // lista è incompleta e completare il multipart scriverebbe su Cubbit un oggetto
        // troncato sotto la key reale, contato come upload riuscito — un backup corrotto
        // presentato come buono. Meglio abortire l'upload (non tocca dati già scritti).
        if cancelled || Task.isCancelled {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw CancellationError()
        }

        let completeXML = Data(S3Syncer.buildCompleteMultipartXML(parts: parts).utf8)
        guard let cURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per completamento multipart: \(key)"])
        }
        try await retrying(key: key, onStatus: onStatus) {
            var cReq = URLRequest(url: cURL)
            cReq.httpMethod = "POST"; cReq.httpBody = completeXML
            self.sign(&cReq, config: config, body: completeXML, date: Date())
            let (_, cResp) = try await self.session.data(for: cReq)
            guard let code = (cResp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
                let statusCode = (cResp as? HTTPURLResponse)?.statusCode ?? -1
                throw S3HTTPError(statusCode: statusCode, message: "Errore completamento multipart \(key)")
            }
        }
    }

    // AWS S3 richiede le parti in ordine crescente di PartNumber nel body di
    // CompleteMultipartUpload — con l'esecuzione parallela l'ordine di completamento non
    // coincide più con l'ordine di lettura, va quindi ordinato esplicitamente. Non
    // private: testata direttamente da S3SyncerMultipartXMLTests.
    static func buildCompleteMultipartXML(parts: [(partNumber: Int, etag: String)]) -> String {
        let sorted = parts.sorted { $0.partNumber < $1.partNumber }
        let partsXML = sorted.map { "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\($0.etag)</ETag></Part>" }.joined()
        return "<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>"
    }

    func abortMultipartUpload(key: String, uploadId: String, config: S3Config) async throws {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let encId = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId
        guard let abortURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?uploadId=\(encId)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per abort: \(key)"])
        }
        var abortReq = URLRequest(url: abortURL)
        abortReq.httpMethod = "DELETE"
        sign(&abortReq, config: config, body: Data(), date: Date())
        let (_, resp) = try await session.data(for: abortReq)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw S3HTTPError(statusCode: statusCode, message: "Errore abort upload \(key)")
        }
    }

    func downloadToTemp(key: String, config: S3Config) async throws -> URL {
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let getURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)") else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: getURL)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let (tempURL, resp) = try await session.download(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            throw NSError(domain: "S3", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Errore GET \(key)"])
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // Funzione pura, nessuna rete: prende le chiavi del bucket e restituisce i nomi
    // delle cartelle di primo livello (es. "Foto iPhone", "Takeout 2", ...), ordinate.
    static func topLevelFolders(fromKeys keys: [String]) -> [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for key in keys {
            guard key.contains("/"), let first = key.split(separator: "/", maxSplits: 1).first else { continue }
            let name = String(first)
            if !seen.contains(name) { seen.insert(name); ordered.append(name) }
        }
        return ordered.sorted()
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let httpError = error as? S3HTTPError {
            // 429 (Too Many Requests) è esattamente il segnale di congestione che il
            // gate adattivo deve poter interpretare — vedi
            // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
            if httpError.statusCode == 429 { return true }
            return !(400...499).contains(httpError.statusCode)
        }
        if error is URLError { return true }
        return false
    }

    struct DownloadManyResult {
        var downloaded = 0; var skipped = 0; var total = 0; var done = 0
        var problems: [String] = []
    }

    func downloadMany(selectedFolders: Set<String>, config: S3Config, destination: URL,
                       onStatus: @escaping (String) -> Void,
                       onProgress: @escaping (DownloadManyResult) -> Void) async throws -> DownloadManyResult {
        cancelled = false
        var result = DownloadManyResult()
        DispatchQueue.main.async { onStatus("Connessione a Cubbit — recupero elenco file...") }
        let all = try await listAll(config: config)
        let keys = all.keys.filter { key in
            guard let first = key.split(separator: "/", maxSplits: 1).first else { return false }
            return selectedFolders.contains(String(first))
        }
        result.total = keys.count
        let fm = FileManager.default

        for key in keys {
            if cancelled || Task.isCancelled { break }
            let destFile = destination.appendingPathComponent(key)
            if fm.fileExists(atPath: destFile.path) {
                result.skipped += 1
            } else {
                DispatchQueue.main.async { onStatus("Recupero: \(key)") }
                do {
                    let tempURL = try await downloadToTemp(key: key, config: config)
                    let parent = destFile.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parent.path) {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    try fm.moveItem(at: tempURL, to: destFile)
                    result.downloaded += 1
                } catch {
                    result.problems.append("\(key) — \(error.localizedDescription)")
                }
            }
            result.done += 1
            let snap = result
            DispatchQueue.main.async { onProgress(snap) }
        }
        return result
    }

    // Controllo rapido di raggiungibilità (solo per il primo passo del restore):
    // timeout breve dedicato, non condivide la `session` con timeout da 300s usata altrove.
    func checkReachable(config: S3Config, timeoutSec: Double = 4) async -> Bool {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else { return false }
        comps.queryItems = [URLQueryItem(name: "list-type", value: "2"),
                             URLQueryItem(name: "max-keys", value: "1")]
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, config: config, body: Data(), date: Date())
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutSec
        cfg.timeoutIntervalForResource = timeoutSec
        let quickSession = URLSession(configuration: cfg)
        guard let (_, resp) = try? await quickSession.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - AWS Signature V4
    private func sign(_ request: inout URLRequest, config: S3Config, body: Data, date: Date) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")!
        let datetime = fmt.string(from: date)
        let dateOnly = String(datetime.prefix(8))
        let region = config.region == "auto" ? "us-east-1" : config.region
        guard let host = URL(string: config.endpoint)?.host else { return }

        request.setValue(datetime, forHTTPHeaderField: "x-amz-date")
        let payHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        request.setValue(payHash, forHTTPHeaderField: "x-amz-content-sha256")

        let headerVals: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payHash,
            "x-amz-date": datetime
        ]
        let signedNames = headerVals.keys.sorted()
        let canonH = signedNames.map { "\($0):\(headerVals[$0]!)" }.joined(separator: "\n") + "\n"
        let signedH = signedNames.joined(separator: ";")

        let rawPath = request.url?.path ?? "/"
        let s3PathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~/"))
        let uri = rawPath.addingPercentEncoding(withAllowedCharacters: s3PathAllowed) ?? rawPath

        func sigv4Encode(_ s: String) -> String {
            let decoded = s.removingPercentEncoding ?? s
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
            var result = ""
            for scalar in decoded.unicodeScalars {
                if allowed.contains(scalar) {
                    result.append(Character(scalar))
                } else {
                    for byte in String(scalar).utf8 {
                        result += String(format: "%%%02X", byte)
                    }
                }
            }
            return result
        }

        var queryParams: [(String, String)] = []
        if let query = request.url?.query {
            for param in query.split(separator: "&") {
                let parts = param.split(separator: "=", maxSplits: 1)
                let key = parts.count > 0 ? String(parts[0]) : ""
                let val = parts.count > 1 ? String(parts[1]) : ""
                queryParams.append((sigv4Encode(key), sigv4Encode(val)))
            }
        }
        let sortedQuery = queryParams.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let canonReq = [request.httpMethod ?? "GET", uri, sortedQuery, canonH, signedH, payHash]
            .joined(separator: "\n")

        let credScope = "\(dateOnly)/\(region)/s3/aws4_request"
        let reqHash = SHA256.hash(data: Data(canonReq.utf8)).map { String(format: "%02x", $0) }.joined()
        let s2s = "AWS4-HMAC-SHA256\n\(datetime)\n\(credScope)\n\(reqHash)"

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let sigKey = hmac(hmac(hmac(hmac(Data(("AWS4" + config.secretAccessKey).utf8),
            dateOnly), region), "s3"), "aws4_request")
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(s2s.utf8),
            using: SymmetricKey(data: sigKey))).map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(credScope), " +
            "SignedHeaders=\(signedH), Signature=\(sig)",
            forHTTPHeaderField: "Authorization")
    }

    private func xmlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&quot;", with: "\"")
    }
    private func xmlFirst(_ xml: String, tag: String) -> String? {
        guard let s = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>") else { return nil }
        return xmlDecode(String(xml[s.upperBound..<e.lowerBound]))
    }
    private func xmlAll(_ xml: String, tag: String) -> [String] {
        var results: [String] = []; var search = xml
        while let s = search.range(of: "<\(tag)>"), let e = search.range(of: "</\(tag)>") {
            results.append(xmlDecode(String(search[s.upperBound..<e.lowerBound])))
            search = String(search[e.upperBound...])
        }
        return results
    }
}

// MARK: - VolumeMonitor
final class VolumeMonitor: ObservableObject {
    @Published var ssdMounted = false
    @Published var hddMounted = false
    private let ssdPath = "/Volumes/SSD - Enri"
    private let hddPath = "/Volumes/BackupHDD"
    private var timer: Timer?
    init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }
    private func check() {
        let fm = FileManager.default
        DispatchQueue.main.async {
            self.ssdMounted = fm.fileExists(atPath: self.ssdPath)
            self.hddMounted = fm.fileExists(atPath: self.hddPath)
        }
    }
}

// MARK: - DiskFormatter (roadmap #28)

/// Disco esterno fisico proposto per la preparazione di un disco nuovo.
struct CandidateDisk: Identifiable {
    var id: String { identifier }
    let identifier: String        // es. "disk4"
    let name: String
    let sizeBytes: Int64
    let currentFilesystem: String
}

/// Elenca i dischi esterni fisici che **non** risultano già configurati come SSD o HDD di backup.
///
/// Qui si eseguono soltanto comandi di **sola lettura** (`diskutil list`, `diskutil info`): nessuna
/// formattazione. Il vincolo del progetto "mai subprocess per accedere ai volumi esterni"
/// (`Docs/CLAUDE.md`) riguarda la lettura/scrittura di *file* su un volume, che per TCC deve passare
/// da bookmark + `FileManager`: `diskutil` non apre file sui volumi, interroga la topologia dei
/// dischi tramite il servizio di sistema, e non esiste un'API pubblica Swift equivalente.
enum DiskFormatter {
    static let diskutilPath = "/usr/sbin/diskutil"
    /// Un `diskutil` di sola lettura (`list`/`info`) che non risponde non deve poter appendere
    /// per sempre il chiamante — normalmente risponde in decine di millisecondi.
    static let commandTimeout: TimeInterval = 20
    static let sigkillGracePeriod: TimeInterval = 5
    /// Nota di review (2026-08-23, secondo giro): un `eraseDisk` NON usa questo timeout — vedi
    /// `erase(identifier:filesystem:newName:)`, che passa `timeout: nil` a `runDiskutil` di
    /// proposito. Uccidere un formattatore a metà lascerebbe il disco in uno stato peggiore che
    /// aspettare: una partizione riscritta solo in parte è più difficile da recuperare di un
    /// comando che semplicemente impiega più a lungo del previsto.

    enum Failure: LocalizedError {
        case launchFailed(command: String, underlying: Error)
        case commandFailed(command: String, status: Int32, output: String)
        case commandTimedOut(command: String, timeout: TimeInterval)
        case unreadableOutput(command: String)
        case unresolvedBookmark(location: BookmarkManager.Location)
        case unexpectedPlistShape(command: String)
        case inconsistentListing(identifier: String)
        case diskNoLongerEligible(identifier: String)
        case nameConfirmationMismatch

        var errorDescription: String? {
            switch self {
            case .launchFailed(let command, let underlying):
                return "Impossibile eseguire `\(command)`: \(underlying.localizedDescription)"
            case .commandFailed(let command, let status, let output):
                return "`\(command)` è fallito (codice \(status))" + (output.isEmpty ? "" : ": \(output)")
            case .commandTimedOut(let command, let timeout):
                return "`\(command)` non ha risposto entro \(Int(timeout)) secondi"
            case .unreadableOutput(let command):
                return "Output di `\(command)` non interpretabile come plist"
            case .unresolvedBookmark(let location):
                return "'\(location.displayName)' risulta configurato ma non è raggiungibile adesso. "
                     + "Collega e monta i dischi di backup configurati prima di preparare un disco nuovo: "
                     + "senza, l'app non può garantire di riconoscerli ed escluderli dalla formattazione."
            case .unexpectedPlistShape(let command):
                return "Output di `\(command)` in un formato inatteso: elenco dischi non affidabile"
            case .inconsistentListing(let identifier):
                return "Il disco \(identifier) compare tra i dischi fisici ma non nell'elenco completo: "
                     + "elenco dischi non affidabile"
            case .diskNoLongerEligible(let identifier):
                return "Il disco \(identifier) non risulta più tra quelli formattabili (potrebbe essere "
                     + "stato scollegato, o un disco di backup è cambiato di stato nel frattempo). "
                     + "Aggiorna l'elenco e riprova — nessuna formattazione è stata eseguita."
            case .nameConfirmationMismatch:
                return "Il nome digitato non corrisponde esattamente al nome del disco selezionato."
            }
        }
    }

    /// Identità dei volumi di backup già configurati, con cui si escludono i dischi non
    /// formattabili. Due criteri indipendenti perché nessuno dei due copre tutti i casi:
    /// il path esiste solo mentre il volume è montato, l'UUID solo se è stato persistito.
    struct ConfiguredBackupVolumes {
        var paths: [String] = []
        var volumeUUIDs: Set<String> = []
    }

    /// Topologia dei dischi esterni, ricavata da `diskutil list -plist external`.
    struct DiskTopology {
        /// disco fisico intero (es. "disk4") → path attualmente montati che gli appartengono
        var mountPaths: [String: [String]] = [:]
        /// disco fisico intero → UUID dei volumi che ospita, montati **o no**
        var volumeUUIDs: [String: Set<String>] = [:]
        /// dischi fisici che ospitano un container APFS
        var apfsHosts: Set<String> = []
        /// tutti gli identificativi presenti nell'elenco (chiave `AllDisks` del plist)
        var knownIdentifiers: Set<String> = []
    }

    // MARK: Elenco

    /// **Da chiamare fuori dal main thread**: sono processi esterni, e nel caso peggiore possono
    /// arrivare fino a `commandTimeout`. Verificato empiricamente il 2026-08-23 dentro il processo
    /// dell'app: normalmente l'intero elenco costa ~0,4s, ma una volta — al primissimo `diskutil
    /// info` mai eseguito da questo binario — il comando è rimasto appeso oltre 20s ed è stato
    /// chiuso dal watchdog (non riproducibile nelle esecuzioni successive, ~0,1s ciascuna). Sul
    /// main thread quella singola occorrenza sarebbe una finestra congelata.
    static func listEligibleDisks() throws -> [CandidateDisk] {
        let configured = try configuredBackupVolumes()

        let physicalArguments = ["list", "-plist", "external", "physical"]
        let physicalCommand = commandDescription(physicalArguments)
        let physical = try plistDictionary(from: try runDiskutil(physicalArguments), command: physicalCommand)
        guard let physicalEntries = physical["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw Failure.unexpectedPlistShape(command: physicalCommand)
        }
        // Il secondo elenco è SENZA `physical` apposta: vedi topology(fromListPlist:).
        let allArguments = ["list", "-plist", "external"]
        let layout = try topology(fromListPlist: try plistDictionary(from: try runDiskutil(allArguments),
                                                                     command: commandDescription(allArguments)),
                                  command: commandDescription(allArguments))

        var disks: [CandidateDisk] = []
        for entry in physicalEntries {
            guard let identifier = entry["DeviceIdentifier"] as? String else {
                throw Failure.unexpectedPlistShape(command: physicalCommand)
            }
            // Fail-closed: se il disco non compare nemmeno nel secondo elenco, i suoi mount e i
            // suoi UUID non sono stati letti da nessuna parte — e "nessun dato" verrebbe scambiato
            // per "nessun volume di backup", cioè per un disco formattabile.
            guard layout.knownIdentifiers.contains(identifier) else {
                throw Failure.inconsistentListing(identifier: identifier)
            }
            guard isEligible(diskPaths: layout.mountPaths[identifier] ?? [],
                             diskVolumeUUIDs: layout.volumeUUIDs[identifier] ?? [],
                             configured: configured) else { continue }
            let info = try? plistDictionary(from: try runDiskutil(["info", "-plist", identifier]),
                                            command: commandDescription(["info", "-plist", identifier]))
            disks.append(CandidateDisk(
                identifier: identifier,
                name: displayName(fromInfoPlist: info ?? [:], identifier: identifier),
                sizeBytes: (entry["Size"] as? NSNumber)?.int64Value ?? 0,
                currentFilesystem: filesystemLabel(diskEntry: entry, identifier: identifier, topology: layout)))
        }
        return disks
    }

    // MARK: Formattazione

    enum DiskFilesystem: String, CaseIterable, Identifiable {
        case apfs = "APFS", exfat = "ExFAT"
        var id: String { rawValue }
    }

    /// Cancella e riformatta un disco esterno intero. **Operazione distruttiva e irreversibile**
    /// su hardware vero — l'unica barriera prima di questa funzione è la UI che chiede all'utente
    /// di ridigitare il nome esatto del disco, e quella barriera da sola non basta: non protegge
    /// da una selezione rimasta valida in UI ma diventata pericolosa nel frattempo (un disco
    /// diverso collegato con lo stesso identificativo di sistema riassegnato da macOS, o —
    /// scenario più concreto — un disco che nel frattempo *è stato scelto* come nuovo SSD/HDD di
    /// backup in un'altra finestra dell'app, es. Impostazioni aperta in una `Window` indipendente
    /// mentre "Prepara disco nuovo" resta aperta con un elenco ormai stantio).
    ///
    /// Per questo `erase()` NON si fida della lista mostrata dal chiamante: rilancia da sola
    /// `listEligibleDisks()` **subito prima** di eseguire `eraseDisk`, e procede solo se
    /// `identifier` compare ancora tra i risultati freschi. Se `listEligibleDisks()` stessa lancia
    /// (bookmark non raggiungibile, plist inatteso — vedi i fail-closed sopra), quell'errore si
    /// propaga qui e blocca comunque l'erase: un elenco che non si può ricalcolare in modo
    /// affidabile non è una base su cui autorizzare un'operazione irreversibile.
    ///
    /// `newName` deve coincidere esattamente (case-sensitive) con `name` del `CandidateDisk`
    /// riletto fresco in questa stessa chiamata — non con quello mostrato dalla UI al momento
    /// dell'apertura, che potrebbe essere stantio. Ridondante rispetto al controllo di conferma
    /// già fatto in UI (l'utente ridigita il nome per abilitare il bottone), ma questa funzione
    /// non deve dipendere dal fatto che la UI l'abbia fatto correttamente: è lei che autorizza
    /// l'`eraseDisk`, quindi verifica da sola.
    static func erase(identifier: String, filesystem: DiskFilesystem, newName: String) throws {
        let freshlyEligible = try listEligibleDisks()
        guard let disk = freshlyEligible.first(where: { $0.identifier == identifier }) else {
            throw Failure.diskNoLongerEligible(identifier: identifier)
        }
        guard disk.name == newName else { throw Failure.nameConfirmationMismatch }
        // Nessun timeout: vedi il doc-comment di runDiskutil. `eraseDisk` su un disco esterno
        // grande può richiedere più dei 20s usati per list/info, e ucciderlo a metà lascerebbe
        // il disco in uno stato peggiore che aspettare.
        _ = try runDiskutil(["eraseDisk", filesystem.rawValue, newName, identifier], timeout: nil)
    }

    /// Identità dei volumi SSD/HDD/Libreria Foto già configurati: path risolto **e** UUID di
    /// volume persistito. Mai il nome, che l'utente può cambiare in qualsiasi momento.
    ///
    /// **Fail-closed**: se esiste un bookmark salvato che non è raggiungibile ADESSO — non solo
    /// all'avvio dell'app — l'elenco non viene prodotto affatto. Non basta guardare
    /// `BookmarkManager.urls`: è uno snapshot preso una sola volta in `init()` e mai più
    /// aggiornato, quindi un volume presente all'avvio ma scollegato/danneggiato più tardi nella
    /// stessa sessione (la modalità normale di quest'app, dato il backup automatico su
    /// collegamento SSD) resterebbe considerato "raggiungibile" per tutta la sessione. Qui invece
    /// si riverifica con `FileManager.fileExists` al momento della chiamata — cioè al momento in
    /// cui si sta per autorizzare un `eraseDisk`. Vale anche quando l'UUID persistito ci sarebbe:
    /// un disco che non si monta più (filesystem danneggiato) non espone alcun UUID a `diskutil`,
    /// ed è esattamente il disco che qualcuno sarebbe tentato di riformattare. Verificato
    /// empiricamente il 2026-08-23 (secondo giro di review) con un'immagine disco corrotta apposta:
    /// senza questa riverifica, un disco di backup diventato irraggiungibile A METÀ SESSIONE
    /// tornava candidabile alla formattazione.
    static func configuredBackupVolumes() throws -> ConfiguredBackupVolumes {
        let manager = BookmarkManager.shared
        let urls = manager.urls
        let fm = FileManager.default
        let inputs: [ConfiguredLocationInput] = [BookmarkManager.Location.ssd, .hdd, .photos].map { loc in
            let candidateURL = urls[loc]
            let reachableNow = candidateURL.map { fm.fileExists(atPath: $0.path) } ?? false
            let currentVolumeUUID: String? = reachableNow
                ? (try? candidateURL!.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                : nil
            return ConfiguredLocationInput(location: loc,
                                    hasSavedBookmark: manager.hasSavedBookmark(loc),
                                    resolvedPath: reachableNow ? candidateURL?.path : nil,
                                    savedVolumeUUID: manager.savedVolumeUUID(loc),
                                    currentVolumeUUID: currentVolumeUUID)
        }
        return try configuredBackupVolumes(from: inputs)
    }

    /// Stato di una posizione configurata, letto dal `BookmarkManager` una volta sola: tenere la
    /// decisione in una funzione pura la rende testabile senza toccare i `UserDefaults` reali.
    /// `resolvedPath`/`currentVolumeUUID` vanno calcolati dal chiamante **al momento della
    /// chiamata** (non da uno snapshot vecchio) — è la funzione pura a decidere cosa farne.
    struct ConfiguredLocationInput {
        let location: BookmarkManager.Location
        let hasSavedBookmark: Bool
        let resolvedPath: String?
        let savedVolumeUUID: String?
        var currentVolumeUUID: String? = nil
    }

    static func configuredBackupVolumes(from inputs: [ConfiguredLocationInput]) throws -> ConfiguredBackupVolumes {
        var result = ConfiguredBackupVolumes()
        for input in inputs {
            guard input.hasSavedBookmark else { continue }
            guard let path = input.resolvedPath else {
                throw Failure.unresolvedBookmark(location: input.location)
            }
            // Un volume diverso rimontato nel frattempo esattamente sullo stesso path non deve
            // fare da alibi al disco di backup vero: se avevamo un UUID persistito, quello
            // attualmente montato lì deve coincidere.
            if let savedUUID = normalizedUUID(input.savedVolumeUUID) {
                guard let currentUUID = normalizedUUID(input.currentVolumeUUID), currentUUID == savedUUID else {
                    throw Failure.unresolvedBookmark(location: input.location)
                }
                result.volumeUUIDs.insert(savedUUID)
            }
            result.paths.append(path)
        }
        return result
    }

    // MARK: Logica di esclusione (pura, testabile senza eseguire diskutil)

    /// Un disco è candidabile solo se **nessuno** dei suoi path montati coincide con — o sta
    /// dentro, o contiene — un path configurato, **e** nessuno dei suoi volumi ha l'UUID di un
    /// volume configurato.
    ///
    /// I due criteri non sono ridondanti: verificato empiricamente il 2026-08-23 che dopo un
    /// `diskutil unmount` l'entry del volume perde `MountPoint` ma conserva `VolumeUUID`. Con il
    /// solo confronto sui path, un disco di backup collegato ma non montato (espulso dal Finder
    /// senza scollegarlo) risulterebbe formattabile.
    static func isEligible(diskPaths: [String], diskVolumeUUIDs: Set<String>,
                           configured: ConfiguredBackupVolumes) -> Bool {
        // Normalizzati qui e non solo a monte: è la funzione che autorizza un'operazione
        // distruttiva, non deve dipendere dal fatto che chi la chiama abbia normalizzato.
        let diskUUIDs = Set(diskVolumeUUIDs.compactMap { normalizedUUID($0) })
        let configuredUUIDs = Set(configured.volumeUUIDs.compactMap { normalizedUUID($0) })
        if !diskUUIDs.isEmpty && !diskUUIDs.isDisjoint(with: configuredUUIDs) { return false }
        for diskPath in diskPaths {
            for configuredPath in configured.paths where pathsOverlap(diskPath, configuredPath) {
                return false
            }
        }
        return true
    }

    /// UUID normalizzato per il confronto (maiuscolo, senza spazi); `nil` se vuoto o assente.
    static func normalizedUUID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    /// Confronto sui componenti del path, mai su `hasPrefix`: "/Volumes/SSD" non deve risultare
    /// genitore di "/Volumes/SSD - Enri". Il confronto è case-insensitive e su forma Unicode
    /// precomposta perché lo stesso volume può presentarsi con maiuscole/composizione diverse
    /// (ExFAT è case-insensitive, i filesystem Apple restituiscono spesso forma decomposta):
    /// nel dubbio si esclude, mai il contrario.
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        let first = normalizedComponents(a)
        let second = normalizedComponents(b)
        // Un path vuoto (un disco non montato riporta `MountPoint` = "") non è parente di niente.
        guard !first.isEmpty, !second.isEmpty else { return false }
        let shared = min(first.count, second.count)
        return Array(first.prefix(shared)) == Array(second.prefix(shared))
    }

    static func normalizedComponents(_ path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (trimmed as NSString).standardizingPath
            .split(separator: "/")
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    /// "disk4s2" → "disk4"; "disk3s1s1" → "disk3"; "disk4" → "disk4".
    static func wholeDiskIdentifier(for identifier: String) -> String {
        guard identifier.hasPrefix("disk") else { return identifier }
        let digits = identifier.dropFirst("disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? identifier : "disk" + digits
    }

    /// Costruisce la mappa "disco fisico → path montati e UUID di volume".
    ///
    /// Va costruita sull'output **senza** `physical`: verificato empiricamente il 2026-08-23 che
    /// con `physical` i volumi APFS non compaiono affatto (il container APFS è un disco
    /// *sintetizzato*, che `physical` filtra via, e la partizione `Apple_APFS` del disco fisico non
    /// ha `MountPoint`). Un disco esterno formattato APFS — come `BackupHDD` — risulterebbe quindi
    /// senza alcun path montato e passerebbe indisturbato il filtro di esclusione.
    ///
    /// **Lancia** se il plist non ha la forma attesa, invece di restituire una topologia vuota:
    /// "non so niente di questi dischi" e "questi dischi non sono volumi di backup" devono restare
    /// due risposte diverse, altrimenti un output inatteso di `diskutil` renderebbe formattabile
    /// qualunque cosa.
    static func topology(fromListPlist plist: [String: Any], command: String) throws -> DiskTopology {
        guard let entries = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw Failure.unexpectedPlistShape(command: command)
        }
        var result = DiskTopology()
        result.knownIdentifiers = Set((plist["AllDisks"] as? [String]) ?? [])

        func add(_ disk: String, _ rawPath: Any?) {
            guard let path = rawPath as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result.mountPaths[disk, default: []].append(path)
        }

        func addUUID(_ disk: String, _ rawUUID: Any?) {
            guard let uuid = normalizedUUID(rawUUID as? String) else { return }
            result.volumeUUIDs[disk, default: []].insert(uuid)
        }

        for entry in entries {
            // Un container APFS sintetizzato non è un disco fisico: i suoi volumi vanno attribuiti
            // al disco che lo ospita davvero (APFSPhysicalStores → "disk4s2" → "disk4").
            let stores = (entry["APFSPhysicalStores"] as? [[String: Any]])?
                .compactMap { $0["DeviceIdentifier"] as? String } ?? []
            let owners: [String]
            if stores.isEmpty {
                owners = (entry["DeviceIdentifier"] as? String).map { [wholeDiskIdentifier(for: $0)] } ?? []
            } else {
                owners = stores.map { wholeDiskIdentifier(for: $0) }
                for owner in owners { result.apfsHosts.insert(owner) }
            }
            for owner in owners {
                add(owner, entry["MountPoint"])
                addUUID(owner, entry["VolumeUUID"])
                for partition in (entry["Partitions"] as? [[String: Any]]) ?? [] {
                    add(owner, partition["MountPoint"])
                    addUUID(owner, partition["VolumeUUID"])
                }
                for volume in (entry["APFSVolumes"] as? [[String: Any]]) ?? [] {
                    add(owner, volume["MountPoint"])
                    addUUID(owner, volume["VolumeUUID"])
                }
            }
        }
        return result
    }

    /// Contenuti di partizione che non rappresentano il filesystem "utile" del disco: `diskutil
    /// info` su una EFI risponde `FilesystemName` = "MS-DOS FAT32", e senza questo filtro un disco
    /// APFS o ExFAT verrebbe etichettato FAT32.
    static let auxiliaryPartitionContents: Set<String> = [
        "EFI", "Apple_Boot", "Apple_APFS_ISC", "Apple_APFS_Recovery",
        "Apple_partition_map", "Microsoft Reserved"
    ]

    static func dataPartitionIdentifiers(inDiskEntry entry: [String: Any]) -> [String] {
        ((entry["Partitions"] as? [[String: Any]]) ?? []).compactMap { partition in
            guard let identifier = partition["DeviceIdentifier"] as? String else { return nil }
            let content = (partition["Content"] as? String) ?? ""
            return auxiliaryPartitionContents.contains(content) ? nil : identifier
        }
    }

    /// Nome mostrato all'utente: quello dell'**hardware** (`MediaName`, es. "PSSD T7"), non quello
    /// del volume — un disco nuovo da formattare spesso non ha alcun volume montato, e nel passo di
    /// conferma è questo nome che l'utente deve ridigitare.
    static func displayName(fromInfoPlist info: [String: Any], identifier: String) -> String {
        for key in ["MediaName", "IORegistryEntryName", "VolumeName"] {
            if let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return identifier
    }

    /// Etichetta del filesystem attuale. Deliberatamente **non** si usa `Content` della partizione:
    /// verificato empiricamente il 2026-08-23 che un volume ExFAT reale ("SSD - Enri") ha
    /// `Content` = "Windows_NTFS" (il tipo MBR 0x07 copre sia NTFS sia ExFAT), mentre `diskutil
    /// info` sulla stessa partizione riporta `FilesystemName` = "ExFAT".
    static func filesystemLabel(diskEntry: [String: Any], identifier: String, topology: DiskTopology) -> String {
        if topology.apfsHosts.contains(identifier) { return "APFS" }
        for partition in dataPartitionIdentifiers(inDiskEntry: diskEntry) {
            let arguments = ["info", "-plist", partition]
            guard let data = try? runDiskutil(arguments),
                  let info = try? plistDictionary(from: data, command: commandDescription(arguments)),
                  let name = (info["FilesystemName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            return name
        }
        let hasPartitions = !(((diskEntry["Partitions"] as? [[String: Any]]) ?? []).isEmpty)
        return hasPartitions ? "Sconosciuto" : "Non formattato"
    }

    // MARK: Esecuzione di diskutil

    static func commandDescription(_ arguments: [String]) -> String {
        (["diskutil"] + arguments).joined(separator: " ")
    }

    static func plistDictionary(from data: Data, command: String) throws -> [String: Any] {
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = parsed as? [String: Any] else {
            throw Failure.unreadableOutput(command: command)
        }
        return dictionary
    }

    /// Esegue `diskutil` e restituisce lo stdout grezzo. Sincrona di proposito: `list`/`info`
    /// rispondono in decine di millisecondi e il loro output sta in pochi KB, ben sotto il buffer
    /// della pipe (stdout viene comunque letto fino in fondo *prima* di `waitUntilExit`, così non
    /// esiste il deadlock classico).
    ///
    /// `timeout`: se non-nil, un watchdog termina il processo (SIGTERM, poi SIGKILL dopo
    /// `sigkillGracePeriod`) se non risponde entro quel tempo — usato per `list`/`info`, che sono
    /// sola lettura e non hanno alcun side-effect da poter interrompere a metà. Se `nil`, nessun
    /// watchdog: il chiamante aspetta finché il processo non termina da solo, per quanto ci
    /// metta — usato **solo** da `erase(identifier:filesystem:newName:)`, dove uccidere
    /// `eraseDisk` a metà lascerebbe il disco in uno stato peggiore che aspettare.
    static func runDiskutil(_ arguments: [String], timeout: TimeInterval? = commandTimeout) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutilPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let command = commandDescription(arguments)
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(command: command, underlying: error)
        }

        // Flag one-shot condiviso tra watchdog e chiamante: chi arriva primo "vince". Nessun
        // watchdog schedulato affatto se timeout è nil.
        let watchdog = ContinuationGuard()
        if let timeout = timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, watchdog.claim() else { return }
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + sigkillGracePeriod) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        // Se `claim()` fallisce qui, il watchdog è già scattato: il processo è stato ucciso.
        // Con timeout nil il watchdog non è mai stato schedulato, quindi claim() qui riesce
        // sempre (nessun falso "timed out").
        guard watchdog.claim() else { throw Failure.commandTimedOut(command: command, timeout: timeout ?? 0) }
        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(command: command, status: process.terminationStatus,
                                        output: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

// MARK: - BackupRunner
@MainActor
final class BackupRunner: ObservableObject {
    // Config S3/Keychain condivisa da TUTTA l'app (Tools e Ripristina) tramite loadS3ConfigIfNeeded():
    // una sola lettura Keychain per avvio dell'app, non una per finestra. Letta dalla finestra
    // principale se possibile: il Keychain, quando serve un'autorizzazione interattiva, la ottiene
    // in modo affidabile solo se la finestra key/frontmost al momento della richiesta è quella
    // principale (verificato empiricamente: la stessa identica chiamata funziona sempre se
    // triggerata dalla finestra principale, e va in loop se triggerata da dentro la Window
    // Diagnostica indipendente). "Aggiorna da rclone.conf" in Tools resta il modo esplicito per
    // forzare un refresh manuale delle credenziali.
    @Published var s3ConfigLoaded = false
    @Published var s3Config: S3Syncer.S3Config? = nil
    @Published var s3ConfigFromKeychain: Bool = false
    @Published var s3ConfigError: Error? = nil
    @Published var pendingAlert: SimpleAlert? = nil

    func loadS3ConfigIfNeeded() async {
        guard !s3ConfigLoaded else { return }
        s3ConfigLoaded = true
        do {
            let result = try S3Syncer.readConfigWithSource()
            s3Config = result.config
            s3ConfigFromKeychain = result.fromKeychain
        } catch {
            s3ConfigError = error
        }
    }

    @Published var toolsReviewFindings: [ReviewFinding] = []
    @Published var toolsOrphanedUploads: [S3Syncer.OrphanedMultipartUpload] = []
    @Published var output = ""
    @Published var phase: JobPhase = .idle
    @Published var stats = JobStats()
    @Published var startTime: Date? = nil
    @Published var completionSnapshot: (phase: JobPhase, stats: JobStats)? = nil
    @Published var currentStatus = ""
    @Published var currentThumbnail: NSImage?
    private var thumbnailRequestID = UUID()
    @Published var speedHistory: [SpeedSample] = []
    @Published var speedUnit: String = "file/s"

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let syncer = FileSyncer()
    private let s3Syncer = S3Syncer()
    private let bm = BookmarkManager.shared
    /// Indice di contenuto della libreria (roadmap #31). Lazy: se non si riesce ad
    /// aprirlo, il dedup semplicemente non avviene — l'indice e' una cache, mai un
    /// prerequisito per importare (ADR-0002). Nessun percorso di codice deve fallire
    /// per colpa sua, per questo `try?` e non `try`.
    private(set) lazy var libraryIndexStore: LibraryIndexStore? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppBackupFoto")
        return try? LibraryIndexStore(url: dir.appendingPathComponent("library-index.sqlite"))
    }()
    /// Registro di ripristino del pannello Doppioni (Task 6, #31). Stesso pattern lazy di
    /// `libraryIndexStore`, stessa cartella: e' la rete di sicurezza dell'unica operazione
    /// distruttiva del progetto, quindi anche lei sul disco interno, mai sull'SSD.
    private(set) lazy var trashManifestStore: TrashManifestStore? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppBackupFoto")
        return try? TrashManifestStore(url: dir.appendingPathComponent("trash-manifest.json"))
    }()
    private var syncTask: Task<Void, Never>?
    private var wasStopped = false

    // MARK: Elenco delle foto gia' salvate (roadmap #31, Task 6)

    /// Ultimo `Progress` pubblicato dalla lettura. `nil` = non e' mai stata fatta una
    /// lettura da quando l'app e' aperta (o l'elenco e' appena stato svuotato).
    @Published var indexProgress: LibraryIndexer.Progress? = nil
    @Published private(set) var isIndexing = false
    /// Quante foto e video ci sono nell'elenco. Tenuto qui e non letto dalla View con una
    /// `count()` al volo: quella query passa dalla coda seriale dello store, che durante una
    /// lettura e' occupata dalle scritture a batch, e sul main thread bloccherebbe la
    /// finestra a ogni ridisegno.
    @Published private(set) var indexedFileCount = 0
    /// L'utente ha premuto "Interrompi" sull'ultima lettura. Distinto dalla cancellazione
    /// automatica per smontaggio di un volume: `Progress` non puo' saperlo, e i due casi
    /// vanno spiegati in modo diverso.
    @Published private(set) var indexInterruptedByUser = false
    private var indexer: LibraryIndexer? = nil
    private var unmountObserver: NSObjectProtocol? = nil

    init() {
        // ATTENZIONE: le notifiche di NSWorkspace sono pubblicate sul SUO notification
        // center, non su NotificationCenter.default. Registrarsi su quello sbagliato
        // compila, non produce errori a runtime, e semplicemente non scatta mai.
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                // Non si filtra per volume: fermare una lettura in corso a ogni smontaggio e'
                // innocuo (quello che e' stato letto resta valido e la volta dopo si riprende
                // da li'), mentre continuare a leggere da un volume che sta sparendo produce
                // hash calcolati su letture troncate.
                guard let self else { return }
                Task { @MainActor in self.stopIndexingForVolumeChange() }
            }
        refreshIndexedFileCount()
    }

    deinit {
        if let unmountObserver { NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver) }
    }

    func refreshIndexedFileCount() {
        guard let store = libraryIndexStore else { indexedFileCount = 0; return }
        // `guard let self` e non `self?.`: una `var` weak riferita da una closure
        // concorrente e' un errore in Swift 6, e qui una referenza forte per la durata di
        // una query non cambia niente (il runner vive quanto l'app).
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let n = (try? store.count()) ?? 0
            await MainActor.run { self.indexedFileCount = n }
        }
    }

    /// Costruisce o aggiorna l'elenco delle foto gia' presenti sull'SSD.
    /// `full: true` = si rilegge da capo ogni file, senza fidarsi di niente di memorizzato.
    /// `onAlert` = dove mostrare gli avvisi (vedi `AlertSink`): la card della finestra
    /// Diagnostica passa il proprio canale, l'aggiornamento automatico non passa niente.
    func rebuildLibraryIndex(full: Bool = false, onAlert: AlertSink? = nil) {
        guard !isIndexing else { return }
        // L'elenco e' una cache, mai un prerequisito (ADR-0002): se non si apre, si dice e
        // basta. Niente nell'app smette di funzionare.
        guard let store = libraryIndexStore else {
            showIndexAlert(SimpleAlert(
                title: "Elenco non disponibile",
                message: "Non è stato possibile aprire l'elenco delle foto già salvate.\n\nL'importazione funziona lo stesso: senza elenco l'app copia tutto, senza riconoscere le foto che hai già."), via: onAlert)
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd) else {
            showIndexAlert(SimpleAlert(
                title: "Accesso all'SSD non disponibile",
                message: "Vai in Impostazioni e riseleziona l'SSD."), via: onAlert)
            return
        }
        // La root da leggere e' ESATTAMENTE quella che `runImport` passa come `libraryRoot`:
        // la radice del volume, non la sottocartella "Foto iPhone". I percorsi dell'elenco
        // sono relativi a questa; se le due divergessero ogni voce punterebbe a un file
        // inesistente e il riconoscimento dei doppioni smetterebbe di funzionare **senza
        // dire niente** (Task 6, Step 2-ter).
        guard isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            showIndexAlert(SimpleAlert(
                title: "Bookmark SSD non valido",
                message: "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella)."), via: onAlert)
            return
        }
        isIndexing = true
        indexInterruptedByUser = false
        indexProgress = LibraryIndexer.Progress()
        // UNA SOLA istanza di store per file dell'indice: si riusa `libraryIndexStore`, mai
        // una seconda connessione sullo stesso database. La coda seriale che protegge SQLite
        // serializza **per istanza**: due istanze sono lo scenario SIGSEGV misurato tre run
        // su tre (Task 6, Step 2-ter).
        let idx = LibraryIndexer(store: store)
        indexer = idx
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                _ = try idx.scan(root: ssdURL, ignoringStoredHashes: full) { p in
                    // `onProgress` arriva dal thread che sta leggendo, mai dal MainActor:
                    // l'aggiornamento della finestra va pubblicato esplicitamente.
                    Task { @MainActor in
                        self.indexProgress = p
                        self.indexedFileCount = p.total
                    }
                }
            } catch {
                // `scan` e' `throws`, ma un suo errore non deve poter far fallire niente
                // altro: si mostra e si prosegue (ADR-0002).
                await MainActor.run {
                    self.showIndexAlert(SimpleAlert(
                        title: "Il controllo si è fermato",
                        message: "\(error.localizedDescription)\n\nQuello che l'app aveva già letto resta salvato: puoi riprovare più tardi."), via: onAlert)
                }
            }
            // Sempre, anche dopo un errore: senza, "Interrompi" e i bottoni resterebbero
            // disabilitati fino alla chiusura dell'app.
            await MainActor.run {
                self.bm.stopAccessing(.ssd)
                self.isIndexing = false
                self.indexer = nil
            }
        }
    }

    /// Interruzione richiesta dall'utente. Quello che e' stato letto resta salvato: i commit
    /// sono a batch, un elenco parziale e' valido e utile (ADR-0002).
    func cancelIndexing() {
        guard isIndexing else { return }
        indexInterruptedByUser = true
        indexer?.cancel()
    }

    /// Un volume si sta smontando: si ferma la lettura come sopra, ma **non** la si segna
    /// come interruzione dell'utente — il messaggio da mostrare e' un altro.
    private func stopIndexingForVolumeChange() {
        guard isIndexing else { return }
        indexer?.cancel()
    }

    /// Svuota l'elenco (solo l'elenco: il file SQLite sul Mac, mai le foto) e lo riapre
    /// vuoto. La ricostruzione **non** parte da sola: la prima creazione resta manuale.
    func resetLibraryIndex(onAlert: AlertSink? = nil) {
        guard !isIndexing, let store = libraryIndexStore else { return }
        do {
            try store.deleteIndexAndRecreate()
            indexProgress = nil
            indexInterruptedByUser = false
            indexedFileCount = 0
        } catch {
            // Se la cancellazione fallisce lo store resta aperto sul vecchio file ed e'
            // ancora utilizzabile: si mostra l'errore e si prosegue, mai un errore fatale.
            showIndexAlert(SimpleAlert(
                title: "Non è stato possibile svuotare l'elenco",
                message: "\(error.localizedDescription)\n\nL'elenco di prima è ancora al suo posto e funziona."), via: onAlert)
            refreshIndexedFileCount()
        }
    }

    /// Instradamento degli avvisi dell'elenco, in un punto solo: al canale di chi ha
    /// chiamato se ce n'e' uno, altrimenti a `pendingAlert`. Vedi `AlertSink` per il
    /// motivo (le due finestre sono due scene e presentano canali diversi).
    private func showIndexAlert(_ alert: SimpleAlert, via sink: AlertSink?) {
        if let sink { sink(alert) } else { pendingAlert = alert }
    }

    /// Aggiornamento automatico: SSD collegato, oppure fine di un job che ha scritto
    /// sull'SSD. Le condizioni stanno in `LibraryIndexAutoRefresh`, non qui.
    func autoRefreshLibraryIndexIfEnabled() {
        guard LibraryIndexAutoRefresh.shouldRun(enabled: LibraryIndexAutoRefresh.isEnabled(),
                                                indexedFileCount: indexedFileCount,
                                                isIndexing: isIndexing,
                                                jobIsRunning: isRunning) else { return }
        rebuildLibraryIndex()
    }

    private let maxOut = 60_000
    private let maxSpeedSamples = 120
    private let lastDeepKey = "lastDeepMirrorDate"
    private var lastSpeedSampleDate: Date = .distantPast
    private var smoothedEtaSec: Double = 0
    private var elapsedTimer: AnyCancellable?

    private func hasSufficientSpace(bytesNeeded: Int64, atVolumeOf url: URL) -> (ok: Bool, availableBytes: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        let margin = max(Int64(Double(bytesNeeded) * 0.05), 500_000_000)
        return (available >= bytesNeeded + margin, available)
    }

    func runMacToSSD() {
        speedUnit = "file/s"
        guard let photosURL = bm.startAccessing(.photos) else {
            alert("Accesso alla Libreria Foto non disponibile",
                  "Vai in Impostazioni (ingranaggio) e riseleziona la cartella Foto.")
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd) else {
            bm.stopAccessing(.photos)
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.photos); bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        let dst = ssdURL.appendingPathComponent("Foto iPhone")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = await self.syncer.previewSync(from: photosURL, to: dst, deep: false)
            let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: ssdURL)
            guard space.ok else {
                self.bm.stopAccessing(.photos); self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'SSD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path).")
                return
            }
            self.run(label: "MAC -> SSD", refreshesLibraryIndex: true) { [weak self] in
                self?.publishStatus("Foto: \(photosURL.path)  →  SSD: \(dst.path)")
                defer { self?.bm.stopAccessing(.photos); self?.bm.stopAccessing(.ssd) }
                return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) },
                    onUnverified: { UnverifiedCopiesStore.record($0) })
            }
        }
    }

    func runSSDToHDD() {
        speedUnit = "file/s"
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        guard let hddURL = bm.startAccessing(.hdd) else {
            bm.stopAccessing(.ssd)
            alert("Accesso all'HDD non disponibile", "Vai in Impostazioni e riseleziona l'HDD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        if !isLikelyVolumeRoot(hddURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark HDD non valido",
                  "Il percorso '\(hddURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona HDD scegliendo '/Volumes/BackupHDD' (root del volume, non una sottocartella).")
            return
        }
        let now = Date()
        let lastDeep = UserDefaults.standard.object(forKey: lastDeepKey) as? Date ?? .distantPast
        let deep = now.timeIntervalSince(lastDeep) > TimeInterval(30 * 24 * 3600)
        let label = deep ? "SSD -> HDD (deep)" : "SSD -> HDD"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = await self.syncer.previewSync(from: ssdURL, to: hddURL, deep: deep)
            let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: hddURL)
            guard space.ok else {
                self.bm.stopAccessing(.ssd); self.bm.stopAccessing(.hdd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'HDD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(hddURL.path).")
                return
            }
            self.run(label: label) { [weak self] in
                self?.publishStatus("SSD: \(ssdURL.path)  →  HDD: \(hddURL.path)")
                defer { self?.bm.stopAccessing(.ssd); self?.bm.stopAccessing(.hdd) }
                let r = try await self?.syncer.sync(from: ssdURL, to: hddURL, deep: deep,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) },
                    onUnverified: { UnverifiedCopiesStore.record($0) })
                if deep, (r?.errors ?? 1) == 0 {
                    UserDefaults.standard.set(Date(), forKey: self?.lastDeepKey ?? "")
                }
                return r
            }
        }
    }

    func runSyncS3() {
        speedUnit = "MB/s"
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        do {
            let config = try S3Syncer.readConfig()
            run(label: "SSD -> Cubbit S3") { [weak self] in
                guard let s3syncer = self?.s3Syncer else { return nil }
                defer { self?.bm.stopAccessing(.ssd) }
                let r = try await s3syncer.sync(
                    from: ssdURL, config: config,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { [weak self] snap in
                        guard let self else { return }
                        self.stats.percent = snap.percent
                        self.stats.done = snap.done; self.stats.total = snap.total
                        self.stats.copied = snap.uploaded; self.stats.skipped = snap.skipped
                        self.stats.errors = snap.errors
                        self.stats.changedSkipped = snap.changedSkipped
                        self.stats.elapsed = S3Syncer.SyncResult.hms(snap.elapsedSec)
                        self.stats.eta = snap.etaSec > 0 ? self.smoothEta(raw: snap.etaSec) : "—"
                        let elapsed = max(0.1, Date().timeIntervalSince(snap.startDate))
                        if snap.uploadedBytes > 0 {
                            let mbps = Double(snap.uploadedBytes) / 1_048_576.0 / elapsed
                            self.stats.speed = String(format: "%.2f MB/s", mbps)
                            self.appendSpeedSample(mbps)
                        } else if snap.done > 0 {
                            let fps = Double(snap.done) / elapsed
                            self.stats.speed = String(format: "%.0f elem/s", fps)
                        }
                    },
                    onCurrentFile: { self?.publishCurrentFile($0) })
                var fr = FileSyncer.SyncResult()
                fr.copied = r.uploaded; fr.skipped = r.skipped
                fr.errors = r.errors; fr.done = r.done; fr.total = r.total
                fr.changedSkipped = r.changedSkipped
                return fr
            }
        } catch {
            bm.stopAccessing(.ssd)
            alert("Errore configurazione S3", error.localizedDescription)
        }
    }

    /// Decide se un file in arrivo e' gia' presente nella libreria con contenuto identico
    /// (roadmap #31).
    ///
    /// Due stadi, come rmlint/jdupes/rdfind: prima la dimensione (gratis), poi l'hash
    /// (costoso). Un file la cui dimensione non compare ne' nell'indice persistito ne'
    /// fra le copie di questa sessione non viene nemmeno hashato.
    ///
    /// MODELLO DI FIDUCIA (spec #31, ADR-0003): questo e' il percorso AD ALTO DANNO — un
    /// hash stantio qui farebbe saltare in silenzio una foto diversa, e "saltata in
    /// silenzio" significa che non arrivera' mai sull'SSD e nessuno se ne accorgera'.
    /// Percio' NON ci si fida di nessun hash memorizzato, ne' quello dell'indice ne'
    /// quello della sessione corrente: il candidato sul disco viene riletto e rihashato
    /// prima di dichiarare il duplicato. Una regola sola, nessuna eccezione da ricordare.
    /// Costa la lettura di un file per candidato, e solo quando un doppione c'e' davvero.
    /// La rilettura sembra ridondante — l'indice ha gia' la risposta — e non lo e': e'
    /// questa decisione. Non rimuoverla per ottimizzare.
    ///
    /// `nonisolated` perche' viene invocata dal thread di lavoro di `FileSyncer`, non dal
    /// MainActor (stessa lezione di `makeThumbnail` in #17).
    ///
    /// - Parameter libraryRoot: root della libreria a cui sono relativi i `displayPath`
    ///   dell'indice. Passata esplicitamente e non letta da `BookmarkManager.shared`
    ///   perche' `urls` e' `@Published` e verrebbe letta da un thread di background;
    ///   `runImport` ce l'ha gia' risolta. `nil` disattiva il solo stadio sull'indice
    ///   persistito.
    nonisolated static func isAlreadyInLibrary(url: URL,
                                              store: LibraryIndexStore?,
                                              session: ImportSessionIndex,
                                              libraryRoot: URL?) -> Bool {
        // Solo i media partecipano al dedup. `LibraryIndexer.scan` gia' scarta i
        // `.notIndexable` prima di indicizzarli, quindi il ramo dell'indice persistito era
        // gia' coperto; il ramo di sessione no, ed e' li' che il buco si vedeva. Senza questa
        // riga due sidecar byte-identici con nomi diversi (`IMG_0001.AAE` e `IMG_0002.AAE`,
        // entrambi da 0 byte, stesso SHA256) diventano l'uno il doppione dell'altro: sull'SSD
        // ne arriva UNO SOLO, col nome sbagliato rispetto alla foto rimasta senza, e la
        // CompletionSheet dichiara un doppione che non esiste. Il verso sicuro e' quello
        // scritto sul doc-comment di `IndexableKind`: un file non classificato viene copiato,
        // mai saltato.
        guard IndexableKind.of(url: url) != .notIndexable else { return false }
        // Attenzione a questa dimensione: `syncDir` prefetcha `.fileSizeKey` in
        // `contentsOfDirectory`, quindi su questa URL `resourceValues` restituisce il valore
        // MEMORIZZATO al momento in cui la directory e' stata letta, non quello attuale
        // (misurato: dopo un troncamento, stessa URL = 5000, URL nuova = 6). E' lo stesso
        // pattern che in questo piano e' gia' costato due bug — ma qui e' innocuo, e va detto
        // perche' nessuno lo "corregga" credendolo il terzo: la dimensione fa SOLO da filtro
        // a monte, a decidere e' `sha256` sul file riletto. Una dimensione stantia produce al
        // massimo un doppione non riconosciuto, cioe' una copia in piu' — il verso sicuro.
        // Non costruirci sopra nulla che si fidi di questo numero.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        let size64 = Int64(size)

        // Stadio 1 — dimensione, gratis. Sessione corrente e indice persistito insieme.
        let sessionCandidates = session.candidates(withSize: size64)
        var storeHasSize = false
        if let store { storeHasSize = (try? store.hasAnyEntry(withSize: size64)) ?? false }
        guard !sessionCandidates.isEmpty || storeHasSize else { return false }

        // Stadio 2 — hash della sorgente, costoso.
        guard let sourceHash = sha256(of: url) else { return false }

        // Copie fatte in questo stesso job (l'indice persistito non le conosce ancora).
        for candidate in sessionCandidates where candidate.hash == sourceHash {
            if fileOnDisk(candidate.url, matches: sourceHash) { return true }
        }

        // Indice persistito. Un risultato vuoto significa "non lo so", mai "nessuna copia
        // esiste" (contratto di `entries(withHash:)`): nel dubbio si copia.
        guard let store,
              let libraryRoot,
              let entries = try? store.entries(withHash: sourceHash),
              !entries.isEmpty else { return false }
        // `displayPath` viene dall'indice, cioe' da un file su disco che potrebbe essere
        // stato scritto da chiunque. `appendingPathComponent` non confina niente: un
        // `displayPath` relativo con `..` risolve FUORI dalla libreria (misurato; i path
        // assoluti invece vengono appesi e restano dentro). Oggi non e' raggiungibile perche'
        // `LibraryIndexer` costruisce i `displayPath` solo dopo la guardia "dentro la root",
        // ma il commento di `normalizedIndexKey` si appoggia esplicitamente all'assunzione
        // "qui i `..` non arrivano mai": un'assunzione documentata e verificata da nulla e'
        // gia' costata tre bug in questo piano. Un candidato fuori root non e' un doppione:
        // si prosegue, e nel dubbio si copia.
        let rootForms = [libraryRoot.standardizedFileURL.path, realResolvedPath(libraryRoot)].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        for entry in entries {
            let candidate = libraryRoot.appendingPathComponent(entry.displayPath).standardizedFileURL
            guard rootForms.contains(where: { relativePath(of: candidate.path, under: $0) != nil }) else { continue }
            if fileOnDisk(candidate, matches: sourceHash) { return true }
        }
        return false
    }

    /// Riverifica di un candidato: l'hash memorizzato potrebbe essere stantio (mtime
    /// riscrivibile da userspace, inode non affidabili su ExFAT), quindi si rilegge.
    /// Un candidato sparito non e' un doppione: si prosegue col successivo.
    ///
    /// A reggere il caso del candidato sparito e' `sha256`, non `fileExists`: su un file che
    /// non c'e' piu' la `open()` fallisce e `sha256` torna `nil`, che non e' mai uguale a un
    /// hash. Togliendo `fileExists` la suite resta verde (misurato). Resta come precondizione
    /// esplicita ed economica — dice a chi legge che l'assenza e' un caso previsto, non un
    /// incidente — ma NON e' lei la difesa: chi un giorno cambiasse `sha256` deve saperlo.
    private nonisolated static func fileOnDisk(_ url: URL, matches hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && sha256(of: url) == hash
    }

    func runImport(source: URL, label: String) {
        speedUnit = "file/s"
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        let dst = ssdURL.appendingPathComponent("Import").appendingPathComponent(importFolderSlug(label))
        // Guardia strutturale, indipendente da quello che l'utente ha scelto nella UI:
        // se destinazione e sorgente coincidono o si contengono a vicenda (symlink,
        // alias, o un buco residuo dello slug), FileSyncer.syncDir creerebbe dst prima
        // di elencare src, si ritroverebbe la propria destinazione nel listing della
        // sorgente e ricorrerebbe fino a PATH_MAX. Secondo strato rispetto alla guardia
        // self-import del wizard, che questa non sostituisce.
        if isSourceInsideConfiguredLocations(dst, configuredURLs: [source]) {
            bm.stopAccessing(.ssd)
            alert("Import non eseguibile",
                  "La cartella di destinazione '\(dst.path)' e la sorgente '\(source.path)' coincidono o una contiene l'altra.\n\nScegli una sorgente fuori dall'SSD (o cambia l'etichetta di destinazione).")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let preview = await self.syncer.previewSync(from: source, to: dst, deep: false)
            let space = self.hasSufficientSpace(bytesNeeded: preview.toAddBytes, atVolumeOf: ssdURL)
            guard space.ok else {
                self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'SSD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path).")
                return
            }
            // Dedup per contenuto (roadmap #31). Lo store puo' essere `nil`: in quel caso
            // il dedup semplicemente non avviene, l'import prosegue identico a prima —
            // l'indice e' una cache, mai un prerequisito (ADR-0002).
            let store = self.libraryIndexStore
            // Una sessione per import, mai condivisa fra job: muore con questa chiusura.
            let session = ImportSessionIndex()
            self.run(label: "Importa: \(label)", refreshesLibraryIndex: true) { [weak self] in
                self?.publishStatus("Importa: \(source.path)  →  SSD: \(dst.path)")
                defer { self?.bm.stopAccessing(.ssd) }
                return try await self?.syncer.sync(from: source, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) },
                    isDuplicate: { url in
                        BackupRunner.isAlreadyInLibrary(url: url, store: store,
                                                        session: session, libraryRoot: ssdURL)
                    },
                    // Simmetrico alla guardia in `isAlreadyInLibrary`: l'indice persistito non
                    // contiene mai file non-media, e non deve contenerli nemmeno quello di
                    // sessione. Il filtro sta qui e non in `syncFile` di proposito — `FileSyncer`
                    // deve restare ignaro di `IndexableKind`, il dedup e' roba dell'import.
                    onCopied: { dst, hash in
                        guard IndexableKind.of(url: dst) != .notIndexable else { return }
                        session.record(hash: hash, at: dst)
                    },
                    onUnverified: { UnverifiedCopiesStore.record($0) })
            }
        }
    }

    func previewMacToSSD() {
        guard let photosURL = bm.startAccessing(.photos) else {
            alert("Accesso alla Libreria Foto non disponibile",
                  "Vai in Impostazioni (ingranaggio) e riseleziona la cartella Foto.")
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd) else {
            bm.stopAccessing(.photos)
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.photos); bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        let dst = ssdURL.appendingPathComponent("Foto iPhone")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.syncer.previewSync(from: photosURL, to: dst, deep: false)
            self.bm.stopAccessing(.photos)
            self.bm.stopAccessing(.ssd)
            let eta = result.estimatedSec > 0
                ? FileSyncer.SyncResult.hms(result.estimatedSec)
                : "< 1s"
            pendingAlert = SimpleAlert(
                title: "Anteprima MAC -> SSD",
                message: "File da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)")
        }
    }

    func previewSSDToHDD() {
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        guard let hddURL = bm.startAccessing(.hdd) else {
            bm.stopAccessing(.ssd)
            alert("Accesso all'HDD non disponibile", "Vai in Impostazioni e riseleziona l'HDD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        if !isLikelyVolumeRoot(hddURL) {
            bm.stopAccessing(.ssd); bm.stopAccessing(.hdd)
            alert("Bookmark HDD non valido",
                  "Il percorso '\(hddURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona HDD scegliendo '/Volumes/BackupHDD' (root del volume, non una sottocartella).")
            return
        }
        let now = Date()
        let lastDeep = UserDefaults.standard.object(forKey: lastDeepKey) as? Date ?? .distantPast
        let deep = now.timeIntervalSince(lastDeep) > TimeInterval(30 * 24 * 3600)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.syncer.previewSync(from: ssdURL, to: hddURL, deep: deep)
            self.bm.stopAccessing(.ssd)
            self.bm.stopAccessing(.hdd)
            let eta = result.estimatedSec > 0
                ? FileSyncer.SyncResult.hms(result.estimatedSec)
                : "< 1s"
            let modeLabel = deep ? "deep (confronto dimensioni)" : "normale (dimensioni + data)"
            pendingAlert = SimpleAlert(
                title: "Anteprima SSD -> HDD",
                message: "Modalita: \(modeLabel)\nFile da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)")
        }
    }

    func previewSyncS3() {
        guard let ssdURL = bm.startAccessing(.ssd) else {
            alert("Accesso all'SSD non disponibile", "Vai in Impostazioni e riseleziona l'SSD.")
            return
        }
        if !isLikelyVolumeRoot(ssdURL) {
            bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella).")
            return
        }
        do {
            let config = try S3Syncer.readConfig()
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.bm.stopAccessing(.ssd) }
                do {
                    let result = try await self.s3Syncer.previewUpload(from: ssdURL, config: config)
                    let gb = Double(result.bytes) / 1_073_741_824
                    pendingAlert = SimpleAlert(
                        title: "Anteprima SSD -> Cubbit S3",
                        message: "File da caricare: \(result.toUpload) (~\(String(format: "%.1f", gb)) GB)\nFile già presenti (skip): \(result.toSkip)\n\n(il tempo dipende dalla velocità della tua connessione, non stimato qui)")
                } catch {
                    self.alert("Errore anteprima S3", error.localizedDescription)
                }
            }
        } catch {
            bm.stopAccessing(.ssd)
            alert("Errore configurazione S3", error.localizedDescription)
        }
    }

    func stop() {
        wasStopped = true
        let jobLabel = phase.label   // etichetta del job in corso, catturata prima di sovrascrivere phase
        elapsedTimer?.cancel(); elapsedTimer = nil
        syncer.cancel()
        s3Syncer.cancel()
        syncTask?.cancel(); syncTask = nil
        phase = .failed("Interrotto dall'utente")
        completionSnapshot = (phase, stats)
        JobHistoryStore.save(JobSummary(date: Date(), label: jobLabel, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors, hashErrors: stats.hashErrors,
            succeeded: false, changedSkipped: stats.changedSkipped,
            duplicatesSkipped: stats.duplicatesSkipped))
    }

    /// - Parameter refreshesLibraryIndex: il job **scrive** sull'SSD (Mac -> SSD, Importa),
    ///   quindi a fine corsa l'elenco delle foto gia' salvate non e' piu' in pari. Falso per
    ///   SSD -> HDD e SSD -> Cubbit, che sull'SSD leggono soltanto: una lettura integrale
    ///   dopo ognuno di quei job costerebbe minuti per non trovare niente di nuovo.
    private func run(label: String, refreshesLibraryIndex: Bool = false,
                     work: @escaping () async throws -> FileSyncer.SyncResult?) {
        guard !isRunning else { return }
        output = ""; stats = JobStats(); currentStatus = ""; currentThumbnail = nil
        wasStopped = false
        let now = Date()
        completionSnapshot = nil; startTime = now
        speedHistory = [SpeedSample(time: now.addingTimeInterval(-2.0), value: 0),
                        SpeedSample(time: now, value: 0)]
        lastSpeedSampleDate = now.addingTimeInterval(-2.1)
        smoothedEtaSec = 0
        phase = .running(label)

        elapsedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let start = self.startTime else { return }
                self.stats.elapsed = FileSyncer.SyncResult.hms(Int(Date().timeIntervalSince(start)))
            }

        syncTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await work()
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    if let r = result {
                        self.stats.copied = r.copied; self.stats.skipped = r.skipped
                        self.stats.errors = r.errors; self.stats.done = r.done
                        self.stats.total = r.total; self.stats.percent = 100
                        self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
                        self.stats.hashErrors = r.hashErrors          // mismatch SHA256
                        self.stats.verifiedOk = r.copied              // tutti i copied sono verified ok
                        self.stats.copiedUnverified = r.copiedUnverified  // copiati ma non verificabili: fuori da copied/verifiedOk
                        self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
                        self.stats.duplicatesSkipped = r.duplicatesSkipped  // gia' in libreria, non copiati (roadmap #31)
                    }
                    self.phase = .success("Completato: \(label)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: true,
                        changedSkipped: self.stats.changedSkipped,
                        duplicatesSkipped: self.stats.duplicatesSkipped))
                    // Dopo un job riuscito che ha scritto sull'SSD: e' il momento in cui
                    // l'elenco serve aggiornato, ed e' anche l'unico in cui si e' certi che
                    // nessuno stia piu' scrivendo sul volume.
                    if refreshesLibraryIndex { self.autoRefreshLibraryIndexIfEnabled() }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.stats.elapsed = self.makeElapsed()
                    self.phase = .failed("Errore: \(error.localizedDescription)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false,
                        changedSkipped: self.stats.changedSkipped,
                        duplicatesSkipped: self.stats.duplicatesSkipped))
                }
            }
        }
    }

    private func publishStatus(_ s: String) {
        Task { @MainActor [weak self] in
            self?.currentStatus = s
            self?.append("STATUS: \(s)\n")
        }
    }

    private func publishProgress(_ r: FileSyncer.SyncResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stats.percent = r.percent; self.stats.done = r.done; self.stats.total = r.total
            self.stats.copied = r.copied; self.stats.skipped = r.skipped; self.stats.errors = r.errors
            self.stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
            self.stats.hashErrors = r.hashErrors          // mismatch SHA256 in tempo reale
            self.stats.copiedUnverified = r.copiedUnverified  // copiati ma non verificabili, in tempo reale
            self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
            self.stats.duplicatesSkipped = r.duplicatesSkipped  // gia' in libreria, non copiati (roadmap #31)
            self.stats.verifiedOk = r.copied              // tutti i copied sono verified ok
            self.stats.eta = (r.copied > 0 && r.etaSec > 0) ? self.smoothEta(raw: r.etaSec) : "—"
            if r.elapsedSec > 0 {
                if r.copied > 0 {
                    let spd = Double(r.copied) / Double(r.elapsedSec)
                    self.stats.speed = String(format: "%.1f file/s", spd)
                    self.appendSpeedSample(spd)
                } else if r.done > 0 {
                    let spd = Double(r.done) / Double(r.elapsedSec)
                    self.stats.speed = String(format: "%.0f scan/s", spd)
                }
            }
        }
    }

    func publishCurrentFile(_ url: URL) {
        let requestID = UUID()
        thumbnailRequestID = requestID
        if FileKind.isImage(url: url) {
            Task.detached(priority: .utility) { [weak self] in
                let thumb = makeThumbnail(url: url, maxPixelSize: 88)
                await MainActor.run {
                    guard let self, self.thumbnailRequestID == requestID else { return }
                    self.currentThumbnail = thumb
                }
            }
        } else {
            currentThumbnail = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private func appendSpeedSample(_ value: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastSpeedSampleDate) >= 2.0 else { return }
        lastSpeedSampleDate = now
        speedHistory.append(SpeedSample(time: now, value: value))
        if speedHistory.count > maxSpeedSamples { speedHistory.removeFirst() }
    }

    private func smoothEta(raw: Int) -> String {
        smoothedEtaSec = smoothedEtaSec <= 0
            ? Double(raw)
            : 0.15 * Double(raw) + 0.85 * smoothedEtaSec
        return FileSyncer.SyncResult.hms(Int(smoothedEtaSec))
    }

    private func append(_ text: String) {
        output += text
        if output.count > maxOut { output = String(output.suffix(maxOut)) }
    }

    private func makeElapsed() -> String {
        guard let s = startTime else { return "—" }
        let t = Int(Date().timeIntervalSince(s))
        return String(format: "%02d:%02d:%02d", t/3600, (t%3600)/60, t%60)
    }

    private func alert(_ title: String, _ msg: String) {
        pendingAlert = SimpleAlert(title: title, message: msg)
    }

}

// MARK: - Review Engine

struct JobSummary: Codable {
    let date: Date
    let label: String
    let copied: Int
    let skipped: Int
    let errors: Int
    let hashErrors: Int
    let succeeded: Bool
    var changedSkipped: Int = 0   // default: i JobSummary persistiti prima di questo campo restano decodificabili nei test che li costruiscono senza specificarlo
    /// Foto non copiate perche' lo stesso contenuto risultava gia' altrove in libreria
    /// (roadmap #31). Persistito perche' l'asimmetria era al contrario: lo skip *meno*
    /// pericoloso (`changedSkipped`, "il file c'era gia' con quel nome") era persistito da
    /// sempre, mentre il primo percorso del progetto che decide di **non copiare una foto
    /// perche' crede che il contenuto esista altrove** viveva solo nella CompletionSheet e
    /// nel log, che e' troncato a `maxOut`. Come `changedSkipped` ha un default, cosi' i
    /// record scritti da una versione precedente restano decodificabili.
    var duplicatesSkipped: Int = 0

    /// I valori di default sulle proprieta' **non** bastano per la decodifica: la
    /// `init(from:)` sintetizzata da Swift chiama `decode(_:forKey:)` e lancia
    /// `keyNotFound` su una chiave assente, ignorando il default (verificato: il record
    /// scritto prima di `changedSkipped` NON si decodificava, e `JobHistoryStore.load` usa
    /// `try?`, quindi l'ultimo job spariva dal pannello Revisione in silenzio dopo un
    /// aggiornamento dell'app). Il vecchio commento su `changedSkipped` diceva il vero solo
    /// per l'init membro a membro usata dai test, non per i record gia' sul disco.
    ///
    /// Sta in una `extension` e non nel corpo dello struct perche' una init dichiarata nel
    /// corpo sopprimerebbe l'init membro a membro, usata da tutti i chiamanti.
    ///
    /// Regola per chi aggiunge un campo: default sulla proprieta' **e** `decodeIfPresent`
    /// qui. Solo la prima meta' e' una retrocompatibilita' finta.
    /// Invariante: ne' i file copiati-ma-non-verificati ne' i doppioni saltati rendono
    /// "non pulito" un job. Sarebbero allarmi quasi sempre infondati, e un allarme che si
    /// impara a ignorare non serve a niente. I non verificati hanno il loro rimedio in
    /// `UnverifiedCopiesStore` (precedenza nel campione d'integrita'), i doppioni sono il
    /// comportamento voluto.
    var isClean: Bool { succeeded && errors == 0 && hashErrors == 0 }
}

extension JobSummary {
    private enum CodingKeys: String, CodingKey {
        case date, label, copied, skipped, errors, hashErrors, succeeded
        case changedSkipped, duplicatesSkipped
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Campi presenti fin dalla prima versione: la loro assenza e' un record rotto, non un
        // record vecchio, e va trattata come tale (decodifica fallita ⇒ nessun ultimo job).
        date = try c.decode(Date.self, forKey: .date)
        label = try c.decode(String.self, forKey: .label)
        copied = try c.decode(Int.self, forKey: .copied)
        skipped = try c.decode(Int.self, forKey: .skipped)
        errors = try c.decode(Int.self, forKey: .errors)
        hashErrors = try c.decode(Int.self, forKey: .hashErrors)
        succeeded = try c.decode(Bool.self, forKey: .succeeded)
        // Campi aggiunti dopo: assenti nei record gia' sul disco di Enrico.
        changedSkipped = try c.decodeIfPresent(Int.self, forKey: .changedSkipped) ?? 0
        duplicatesSkipped = try c.decodeIfPresent(Int.self, forKey: .duplicatesSkipped) ?? 0
    }
}

enum JobHistoryStore {
    private static let key = "lastJobSummary"

    static func save(_ summary: JobSummary, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> JobSummary? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(JobSummary.self, from: data)
    }
}

/// Debito di verifica: i file **copiati ma non verificati** (`SyncResult.copiedUnverified`),
/// cioe' quelli per cui la verifica SHA256 post-copia non ha potuto concludersi perche' uno
/// dei due hash e' tornato `nil` — tipicamente la sorgente stava cambiando mentre la
/// leggevamo (Foto che riscrive un original durante il backup automatico).
///
/// Perche' esiste. Per la regola zero-overwrite quel file **non verra' mai ricopiato**: se
/// fosse davvero corrotto resterebbe corrotto per sempre. Finora il numero viveva solo nel
/// riepilogo di fine job, che sparisce chiudendo la finestra. Il rimedio scelto **non** e'
/// marcare il job come non pulito (`JobSummary.isClean` resta identico): sarebbe un allarme
/// quasi sempre infondato, e un allarme che si impara a ignorare non serve a niente — lo
/// stesso criterio con cui `copiedUnverified` non riusa `hashErrors`. Il rimedio e' dare a
/// quei file la **precedenza nel campione d'integrita'** del pannello Revisione, che gira a
/// distanza di tempo, quando la sorgente non e' piu' in uso e la verifica riesce davvero.
///
/// Perche' non dentro `JobSummary`. `JobHistoryStore` conserva **solo l'ultimo job**: un job
/// successivo pulito sovrascriverebbe il record e il debito sparirebbe in silenzio, che e'
/// esattamente il problema da risolvere. Il debito e' cumulativo e si chiude un file alla
/// volta, quindi ha una chiave sua.
struct UnverifiedCopies: Codable, Equatable {
    /// Una copia da ricontrollare: il percorso piu' l'istante in cui il debito e' stato
    /// contratto. La data serve solo alla scadenza (`UnverifiedCopiesStore.expiryDays`).
    struct Entry: Codable, Equatable {
        var path: String
        /// `nil` solo nei record scritti dalla versione che non aveva ancora questo campo.
        /// Una voce senza data **non scade mai**: far sparire un debito reale sulla base di
        /// una data inventata sarebbe il verso sbagliato dell'errore, e la voce resta
        /// comunque verificabile dal campione d'integrita'.
        var recordedAt: Date? = nil
    }

    /// Quanti file risultano ancora da ricontrollare. Resta veritiero anche quando `entries`
    /// e' troncata dal tetto: e' il numero da mostrare, `entries.count` non lo e'.
    var totalCount: Int = 0
    /// Voci conservate, al massimo `UnverifiedCopiesStore.maxPaths`. Il tetto esiste perche'
    /// questo record sta in `UserDefaults` e senza limite crescerebbe con il numero di file
    /// copiati, non con il numero di problemi reali.
    var entries: [Entry] = []
    /// L'ultimo istante in cui l'app ha scritto questo record. Serve **solo** a riconoscere
    /// un orologio che salta (vedi `UnverifiedCopiesStore.isImplausibleClockJump`), non alla
    /// scadenza. `nil` nei record scritti dalla versione che non aveva questo campo.
    var lastSeenAt: Date? = nil

    /// Percorsi conservati, nell'ordine di registrazione. Derivata da `entries`: non e' un
    /// secondo elenco da tenere allineato.
    var paths: [String] { entries.map(\.path) }
}

extension UnverifiedCopies {
    private enum CodingKeys: String, CodingKey { case totalCount, entries, lastSeenAt }
    /// Chiavi della forma **vecchia** del record. Enum separata perche' la sintesi di
    /// `encode(to:)` pretende che ogni caso di `CodingKeys` corrisponda a una proprieta'
    /// memorizzata: tenere qui `paths` (che oggi e' derivata) e' l'unico modo per leggerla
    /// senza scrivere a mano una codifica che poi divergerebbe.
    private enum LegacyCodingKeys: String, CodingKey { case paths }

    /// Stessa ragione di `JobSummary.init(from:)`: i default sulle proprieta' non li usa la
    /// decodifica sintetizzata. Qui tutti i campi sono opzionali in lettura perche' l'intero
    /// record e' una comodita': un debito che non si riesce a leggere e' un debito vuoto, mai
    /// un errore.
    ///
    /// `paths` e' la forma **vecchia** del record (percorsi senza data), letta solo se
    /// `entries` non c'e'. Senza questo ramo i debiti gia' scritti sparirebbero in silenzio
    /// al primo aggiornamento dell'app — e' lo stesso errore gia' pagato una volta con
    /// `changedSkipped` in `JobSummary`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        if let decoded = try c.decodeIfPresent([Entry].self, forKey: .entries) {
            entries = decoded
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            entries = (try legacy.decodeIfPresent([String].self, forKey: .paths) ?? [])
                .map { Entry(path: $0, recordedAt: nil) }
        }
    }
}

enum UnverifiedCopiesStore {
    /// Tetto ai percorsi conservati. 200 e' ampiamente sopra il numero di file che una
    /// sorgente in uso puo' rendere non verificabili in un job (misurato: unita'), e sotto
    /// la soglia oltre la quale il record in `UserDefaults` diventa un problema di suo.
    static let maxPaths = 200

    /// Scadenza di un debito. Un file importato da una scheda SD poi scollegata non ha piu'
    /// una sorgente con cui essere confrontato in nessuna coppia campionata: senza scadenza
    /// resterebbe in lista per sempre, occupando uno dei `maxPaths` posti e falsando il
    /// conteggio con un debito che nessuno potra' mai chiudere.
    ///
    /// La regola vale per **tutte** le voci, non solo per quelle da import: una sorgente puo'
    /// sparire in molti modi, e "scade sempre" e' una regola che si ricorda, "scade tranne
    /// quando..." no. Il prezzo e' che una copia davvero corrotta esce dalla lista dopo 30
    /// giorni senza essere stata verificata — ma in quei 30 giorni il campione d'integrita'
    /// l'ha avuta in cima alla precedenza a ogni esecuzione.
    static let expiryDays = 30
    static var expiryInterval: TimeInterval { TimeInterval(expiryDays) * 24 * 3600 }

    private static let key = "unverifiedCopies"
    /// `record` e' chiamata dalla coda di lavoro di `FileSyncer`, non dal MainActor, e fa un
    /// leggi-modifica-scrivi: senza lock due file non verificati nello stesso istante ne
    /// perderebbero uno.
    private static let lock = NSLock()

    /// Il debito, gia' ripulito dalle voci scadute: chi legge non deve ricordarsi di
    /// filtrare. `now` e' un parametro e non `Date()` preso qui dentro perche' altrimenti
    /// il confine della scadenza non sarebbe verificabile se non a cronometro.
    static func load(now: Date = Date(), defaults: UserDefaults = .standard) -> UnverifiedCopies {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(UnverifiedCopies.self, from: data) else {
            return UnverifiedCopies()
        }
        // Se l'orologio e' tornato indietro dall'ultima scrittura, le date non sono
        // affidabili e non si pota niente in questo giro.
        guard !clockWentBackwards(lastSeenAt: decoded.lastSeenAt, now: now) else {
            return decoded
        }
        return pruningExpired(decoded, now: now)
    }

    /// L'orologio di sistema e' tornato indietro rispetto all'ultima scrittura di questo
    /// record: le date non sono affidabili, e in questo giro non si pota niente.
    ///
    /// **Perche' solo all'indietro, e non anche in avanti.** Il rilievo originale era che un
    /// salto in avanti fa scadere tutti i debiti nello stesso istante. E' vero, ma dai soli
    /// timestamp **un salto in avanti e' indistinguibile da un'app rimasta chiusa a lungo**:
    /// un utente che non apre l'app per 40 giorni produce esattamente la stessa lettura di un
    /// orologio spostato di 40 giorni. Rifiutare di potare in quel caso non "corregge un
    /// difetto": spegne la scadenza, che e' una funzione voluta e testata (tre test la
    /// coprono). Provato e scartato il 2026-09-01, con quei tre test rossi a dimostrarlo.
    ///
    /// All'indietro invece il segnale e' **univoco**: nessun trascorrere del tempo puo'
    /// produrre un `now` precedente all'ultima scrittura. Ed e' anche la prima meta' dello
    /// scenario reale — batteria dell'RTC scarica, ripristino da backup — dove l'orologio
    /// prima crolla e poi viene rimesso in pari da NTP.
    ///
    /// **Limite accettato e dichiarato**: un salto in avanti che non sia preceduto da uno
    /// all'indietro osservabile continua a far scadere i debiti in blocco. Il verso resta
    /// innocuo per i file — non se ne perde nessuno, la lista e' solo una precedenza per il
    /// campione d'integrita' — e chiuderlo davvero richiederebbe un riferimento monotono che
    /// sopravviva ai riavvii, che non abbiamo.
    ///
    /// Un record senza `lastSeenAt` (scritto dalla versione precedente) non e' giudicabile:
    /// si pota normalmente, come si e' sempre fatto.
    static func clockWentBackwards(lastSeenAt: Date?, now: Date) -> Bool {
        guard let lastSeenAt else { return false }
        return now < lastSeenAt
    }

    /// Una voce e' scaduta quando ha piu' di `expiryDays` giorni. Il confine (esattamente
    /// `expiryDays` giorni) NON e' scaduto: serve un verso deciso una volta sola, altrimenti
    /// il test del confine sarebbe arbitrario quanto il codice.
    static func isExpired(_ entry: UnverifiedCopies.Entry, now: Date) -> Bool {
        guard let recordedAt = entry.recordedAt else { return false }
        return now.timeIntervalSince(recordedAt) > expiryInterval
    }

    /// Le voci scadute escono **anche dal conteggio**: un numero che comprende debiti che
    /// nessuno ricontrollera' piu' non e' un numero veritiero. Si scala solo di quante voci
    /// si sono davvero tolte — dei debiti oltre il tetto non si conosce nemmeno la data,
    /// quindi non si possono giudicare.
    private static func pruningExpired(_ state: UnverifiedCopies, now: Date) -> UnverifiedCopies {
        var pruned = state
        pruned.entries = state.entries.filter { !isExpired($0, now: now) }
        pruned.totalCount = max(0, state.totalCount - (state.entries.count - pruned.entries.count))
        return pruned
    }

    /// Registra un file da ricontrollare. Idempotente sui percorsi conservati: lo stesso file
    /// registrato due volte conta una volta sola.
    ///
    /// Oltre il tetto si incrementa **solo** il conteggio: il numero resta veritiero, il
    /// percorso si perde. In quel regime un percorso non conservato e registrato di nuovo
    /// conterebbe due volte — caso che lo zero-overwrite rende praticamente irraggiungibile
    /// (un file gia' copiato non viene ricopiato, quindi non torna a essere non verificato).
    static func record(_ url: URL, now: Date = Date(), defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var state = load(now: now, defaults: defaults)
        guard !state.entries.contains(where: { $0.path == url.path }) else { return }
        state.totalCount += 1
        if state.entries.count < maxPaths {
            state.entries.append(UnverifiedCopies.Entry(path: url.path, recordedAt: now))
        }
        save(state, now: now, defaults: defaults)
    }

    /// Il debito si chiude: il file e' stato ricontrollato e corrisponde alla sorgente.
    /// Il conteggio scende solo se il percorso era davvero fra quelli conservati, altrimenti
    /// si scalerebbe un debito di cui non sappiamo nulla.
    static func clear(_ path: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var state = load(now: now, defaults: defaults)
        guard let i = state.entries.firstIndex(where: { $0.path == path }) else { return }
        state.entries.remove(at: i)
        state.totalCount = max(0, state.totalCount - 1)
        save(state, now: now, defaults: defaults)
    }

    /// `now` viene registrato a ogni scrittura: e' il riferimento con cui la lettura
    /// successiva riconosce un salto dell'orologio. Senza, `lastSeenAt` resterebbe `nil` per
    /// sempre e la guardia non si accenderebbe mai.
    private static func save(_ state: UnverifiedCopies, now: Date, defaults: UserDefaults) {
        var state = state
        state.lastSeenAt = now
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

struct ReviewFinding: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
    let detail: String
}

struct IntegrityCheckResult: Identifiable {
    let id = UUID()
    let pairName: String
    var checked: Int = 0
    var matched: Int = 0
    var mismatches: [String] = []
    var skippedNoSource: Int = 0
    /// File che ESISTONO ma di cui non si e' riusciti a calcolare l'hash (lettura
    /// fallita, file cambiato di dimensione durante la lettura). Contarli come
    /// `skippedNoSource` — cioe' riportarli come "sorgente mancante" — era
    /// semplicemente falso, e dal 2026-08-26 il caso e' piu' raggiungibile di prima
    /// (`sha256(of:)` ora restituisce `nil` anche per un file che si muove sotto di noi).
    var skippedUnreadable: Int = 0
    var error: String? = nil
}

// Voce del catalogo backup (roadmap #12) — alimentata sia da ReviewEngine.scanLocalCatalog
// (SSD/HDD) sia da S3Syncer.listAllWithDates (Cubbit), sola lettura, nessuna azione associata.
struct CatalogEntry: Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let sizeBytes: Int64
    let modified: Date?
}

// Filtro di ricerca puro sul catalogo (nome o cartella, case-insensitive) — nessuna dipendenza
// da rete o disco, applicato in memoria sui CatalogEntry già caricati.
func filterCatalogEntries(_ entries: [CatalogEntry], matching query: String) -> [CatalogEntry] {
    guard !query.isEmpty else { return entries }
    let q = query.lowercased()
    return entries.filter { $0.name.lowercased().contains(q) || $0.relativePath.lowercased().contains(q) }
}

final class ReviewEngine {
    private let bm = BookmarkManager.shared
    private let s3Syncer = S3Syncer()
    private let fm = FileManager.default
    /// Dove vive il debito di verifica (`UnverifiedCopiesStore`). Iniettabile solo perche' i
    /// test non devono scrivere in `UserDefaults.standard`; in app e' sempre `.standard`.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // La canonicalizzazione dei percorsi (`realResolvedPath`) e' una funzione globale
    // condivisa con `LibraryIndexer`, non piu' un metodo privato di questa classe:
    // due canonicalizzazioni diverse per lo stesso problema producono forme opposte.
    // Vedi il commento sulla funzione.

    func sampleLocalPair(srcRoot: URL, dstRoot: URL, pairName: String, sampleSize: Int) -> IntegrityCheckResult {
        var result = IntegrityCheckResult(pairName: pairName)
        let resolvedDstRoot = URL(fileURLWithPath: realResolvedPath(dstRoot), isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: resolvedDstRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            result.error = "Impossibile enumerare \(dstRoot.path)"
            return result
        }

        var relPaths: [String] = []
        let base = resolvedDstRoot.path
        while let f = enumerator.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            relPaths.append(String(f.path.dropFirst(base.count).drop(while: { $0 == "/" })))
        }
        guard !relPaths.isEmpty else { return result }

        // Precedenza ai file copiati ma non verificati. Sono gli unici che nessun altro
        // meccanismo ricontrollera' mai: per la regola zero-overwrite non verranno ricopiati,
        // e il conteggio di fine job sparisce con la finestra. Qui la verifica ha buone
        // probabilita' di riuscire, perche' gira a distanza di tempo e la sorgente non e'
        // piu' in uso. Il resto del campione resta casuale come prima.
        let roots = [dstRoot.standardizedFileURL.path, resolvedDstRoot.path].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        let known = Set(relPaths)
        var debtByRel: [String: String] = [:]   // percorso relativo -> percorso assoluto registrato
        var prioritized: [String] = []
        for stored in UnverifiedCopiesStore.load(defaults: defaults).paths {
            guard let rel = roots.lazy.compactMap({ relativePath(of: stored, under: $0) }).first,
                  known.contains(rel), debtByRel[rel] == nil else { continue }
            // Se la sorgente non c'e' piu' il file non e' verificabile in questa coppia (un
            // import da dispositivo: la sorgente era il telefono, ora scollegato). Non gli si
            // da' la precedenza, altrimenti brucerebbe uno slot del campione a ogni
            // esecuzione, per sempre, senza mai potersi chiudere.
            guard fm.fileExists(atPath: srcRoot.appendingPathComponent(rel).path) else { continue }
            debtByRel[rel] = stored
            prioritized.append(rel)
        }

        var sample = Array(prioritized.prefix(sampleSize))
        if sample.count < sampleSize {
            let alreadyChosen = Set(sample)
            sample += relPaths.shuffled()
                .filter { !alreadyChosen.contains($0) }
                .prefix(sampleSize - sample.count)
        }

        for rel in sample {
            let dstFile = dstRoot.appendingPathComponent(rel)
            let srcFile = srcRoot.appendingPathComponent(rel)
            guard fm.fileExists(atPath: srcFile.path) else {
                result.skippedNoSource += 1
                continue
            }
            result.checked += 1
            if let srcHash = sha256(of: srcFile), let dstHash = sha256(of: dstFile), srcHash == dstHash {
                result.matched += 1
                // Il debito si chiude: questo file e' stato ricontrollato e corrisponde alla
                // sorgente. Su mismatch invece resta in lista — e' appena diventato un
                // problema vero, gia' riportato in `mismatches`.
                if let stored = debtByRel[rel] {
                    UnverifiedCopiesStore.clear(stored, defaults: defaults)
                }
            } else {
                result.mismatches.append(rel)
            }
        }
        return result
    }

    // Catalogo backup (roadmap #12): elenca tutti i file sotto rootURL con nome/cartella
    // relativa/dimensione/data. Sola lettura — nessuna azione, nessuna modifica. Stessa
    // esclusione di file di sistema già usata da FileSyncer.
    func scanLocalCatalog(rootURL: URL) -> [CatalogEntry] {
        let resolvedRoot = URL(fileURLWithPath: realResolvedPath(rootURL), isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [CatalogEntry] = []
        let base = resolvedRoot.path
        while let f = enumerator.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            let name = f.lastPathComponent
            if LibraryExclusions.shouldExclude(f) { continue }
            let relativePath = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            entries.append(CatalogEntry(
                name: name,
                relativePath: relativePath,
                sizeBytes: Int64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate))
        }
        return entries
    }

    private func sampleS3Pair(ssdRoot: URL, sampleSize: Int,
                               onProgress: @escaping (String) -> Void) async throws -> IntegrityCheckResult {
        var result = IntegrityCheckResult(pairName: "SSD ↔ S3")
        let config = try S3Syncer.readConfig()
        let remoteKeys = try await s3Syncer.listAll(config: config)
        let candidates = remoteKeys.keys.filter { fm.fileExists(atPath: ssdRoot.appendingPathComponent($0).path) }
        guard !candidates.isEmpty else { return result }

        let sample = candidates.shuffled().prefix(sampleSize)
        for key in sample {
            onProgress("Verifica S3: \(key)")
            let localFile = ssdRoot.appendingPathComponent(key)
            // Il file esiste (`candidates` e' gia' filtrato su `fileExists`): se l'hash
            // non si calcola e' illeggibile o si e' mosso, non "sorgente mancante".
            guard let localHash = sha256(of: localFile) else { result.skippedUnreadable += 1; continue }
            result.checked += 1
            do {
                let tempURL = try await s3Syncer.downloadToTemp(key: key, config: config)
                defer { try? fm.removeItem(at: tempURL) }
                if let remoteHash = sha256(of: tempURL), remoteHash == localHash {
                    result.matched += 1
                } else {
                    result.mismatches.append(key)
                }
            } catch {
                result.mismatches.append("\(key) (errore download: \(error.localizedDescription))")
            }
        }
        return result
    }

    func runIntegritySample(sampleSize: Int = 20,
                             onProgress: @escaping (String) -> Void) async -> [IntegrityCheckResult] {
        var results: [IntegrityCheckResult] = []

        let photosURL = bm.startAccessing(.photos)
        let ssdURL = bm.startAccessing(.ssd)
        let hddURL = bm.startAccessing(.hdd)
        defer {
            if photosURL != nil { bm.stopAccessing(.photos) }
            if ssdURL != nil { bm.stopAccessing(.ssd) }
            if hddURL != nil { bm.stopAccessing(.hdd) }
        }

        onProgress("Campionamento Mac ↔ SSD…")
        if let photosURL, let ssdURL {
            results.append(sampleLocalPair(srcRoot: photosURL,
                                            dstRoot: ssdURL.appendingPathComponent("Foto iPhone"),
                                            pairName: "Mac ↔ SSD", sampleSize: sampleSize))
        } else {
            var r = IntegrityCheckResult(pairName: "Mac ↔ SSD")
            r.error = "Bookmark Foto o SSD non accessibile"
            results.append(r)
        }

        onProgress("Campionamento SSD ↔ HDD…")
        if let ssdURL, let hddURL {
            results.append(sampleLocalPair(srcRoot: ssdURL, dstRoot: hddURL,
                                            pairName: "SSD ↔ HDD", sampleSize: sampleSize))
        } else {
            var r = IntegrityCheckResult(pairName: "SSD ↔ HDD")
            r.error = "Bookmark SSD o HDD non accessibile"
            results.append(r)
        }

        onProgress("Campionamento SSD ↔ S3…")
        if let ssdURL {
            do {
                results.append(try await sampleS3Pair(ssdRoot: ssdURL, sampleSize: sampleSize, onProgress: onProgress))
            } catch {
                var r = IntegrityCheckResult(pairName: "SSD ↔ S3")
                r.error = error.localizedDescription
                results.append(r)
            }
        } else {
            var r = IntegrityCheckResult(pairName: "SSD ↔ S3")
            r.error = "Bookmark SSD non accessibile"
            results.append(r)
        }

        return results
    }

    // s3Config/s3ConfigFromKeychain/s3ConfigError vanno letti UNA SOLA VOLTA dal chiamante
    // (S3Syncer.readConfigWithSource()) e passati qui — ogni lettura Keychain indipendente può
    // richiedere una propria autorizzazione interattiva dell'utente, quindi ripeterla per ogni
    // singolo controllo (come faceva la versione precedente, con una lettura per check) genera
    // più prompt in sequenza invece di uno solo.
    func runConfigChecks(s3Config: S3Syncer.S3Config?, s3ConfigFromKeychain: Bool,
                          s3ConfigError: Error?) -> [ReviewFinding] {
        let deepMirrorFinding = checkDeepMirrorFreshness(hddConfigured: bm.urls[.hdd] != nil)
        return checkBookmarkRoots()
            + [checkRcloneConfPermissions(fromKeychain: s3ConfigFromKeychain),
               checkS3Endpoint(config: s3Config, error: s3ConfigError)]
            + [deepMirrorFinding].compactMap { $0 }
    }

    func findOrphanedMultipartUploads(config: S3Syncer.S3Config) async throws -> [S3Syncer.OrphanedMultipartUpload] {
        try await s3Syncer.listMultipartUploads(config: config)
    }

    private func checkBookmarkRoots() -> [ReviewFinding] {
        [BookmarkManager.Location.ssd, .hdd].compactMap { loc -> ReviewFinding? in
            guard let url = bm.urls[loc] else { return nil }
            let ok = isLikelyVolumeRoot(url)
            let name = loc == .ssd ? "SSD" : "HDD"
            return ReviewFinding(
                title: "Bookmark \(name)", ok: ok,
                detail: ok
                    ? "Punta alla root del volume (\(url.path))"
                    : "Punta a una sottocartella (\(url.path)), non alla root del volume")
        }
    }

    private func checkRcloneConfPermissions(fromKeychain: Bool) -> ReviewFinding {
        if fromKeychain {
            return ReviewFinding(title: "Credenziali S3", ok: true,
                detail: "Salvate nel Keychain — rclone.conf non è più necessario")
        }
        let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "File non trovato in ~/.config/rclone/rclone.conf")
        }
        let perms = attrs[.posixPermissions] as? Int ?? 0
        if perms & 0o077 != 0 {
            return ReviewFinding(title: "Permessi rclone.conf", ok: false,
                detail: "Permessi troppo aperti (\(String(perms, radix: 8))) — esegui: chmod 600 ~/.config/rclone/rclone.conf")
        }
        return ReviewFinding(title: "Permessi rclone.conf", ok: true,
            detail: "0600 — solo il proprietario può leggere/scrivere")
    }

    private func checkS3Endpoint(config: S3Syncer.S3Config?, error: Error?) -> ReviewFinding {
        if let cfg = config {
            return ReviewFinding(title: "Endpoint S3", ok: true, detail: "\(cfg.endpoint) · bucket \(cfg.bucket)")
        }
        return ReviewFinding(title: "Endpoint S3", ok: false,
            detail: error?.localizedDescription ?? "Configurazione S3 non disponibile")
    }

    func checkDeepMirrorFreshness(hddConfigured: Bool,
                                   defaults: UserDefaults = .standard,
                                   now: Date = Date()) -> ReviewFinding? {
        guard hddConfigured else { return nil }
        guard let lastDeep = defaults.object(forKey: "lastDeepMirrorDate") as? Date else {
            return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
                detail: "Mai eseguito — collega l'HDD ed esegui SSD → HDD per avviarlo")
        }
        let days = Int(now.timeIntervalSince(lastDeep) / 86400)
        if days > 45 {
            return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
                detail: "Ultimo deep mirror \(days) giorni fa — collega l'HDD per farlo ripartire")
        }
        return ReviewFinding(title: "Deep mirror SSD → HDD", ok: true,
            detail: "Ultimo deep mirror \(days) giorni fa")
    }
}

// MARK: - Restore

enum RestoreSource: String, Identifiable {
    case ssd, hdd, s3
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ssd: return "Dal mio SSD"
        case .hdd: return "Dal mio HDD"
        case .s3:  return "Da Cubbit (cloud)"
        }
    }
}

struct RestoreProgress {
    var done: Int = 0
    var total: Int = 0
    var startDate: Date = Date()
    var problems: [String] = []
    var percent: Int { total > 0 ? min(100, done * 100 / total) : 0 }
    var etaSec: Int {
        guard done > 0, total > done else { return 0 }
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0.5 else { return 0 }
        return Int(elapsed * Double(total - done) / Double(done))
    }
}

@MainActor
final class RestoreEngine: ObservableObject {
    @Published var phase: JobPhase = .idle
    @Published var progress = RestoreProgress()

    private let syncer = FileSyncer()
    private let s3Syncer = S3Syncer()
    private var wasStopped = false
    private var runTask: Task<Void, Never>?

    func listAvailableFolders(rootURL: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> String? in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard vals?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            return name.hasPrefix(".") ? nil : name
        }.sorted()
    }

    func listAvailableFolders(fromS3Config config: S3Syncer.S3Config) async throws -> [String] {
        let keys = try await s3Syncer.listAll(config: config).keys
        return S3Syncer.topLevelFolders(fromKeys: Array(keys))
    }

    func estimateS3Download(selectedFolders: Set<String>, destination: URL,
                             config: S3Syncer.S3Config) async throws -> (count: Int, bytes: Int64) {
        let all = try await s3Syncer.listAll(config: config)
        let fm = FileManager.default
        var count = 0; var bytes: Int64 = 0
        for (key, size) in all {
            guard let first = key.split(separator: "/", maxSplits: 1).first,
                  selectedFolders.contains(String(first)) else { continue }
            guard !fm.fileExists(atPath: destination.appendingPathComponent(key).path) else { continue }
            count += 1; bytes += size
        }
        return (count, bytes)
    }

    func run(source: RestoreSource, selectedFolders: Set<String>, sourceRootURL: URL?,
             destination: URL, s3Config: S3Syncer.S3Config?) {
        wasStopped = false
        progress = RestoreProgress()
        phase = .running(source.displayName)

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch source {
                case .ssd, .hdd:
                    guard let sourceRootURL else {
                        throw NSError(domain: "Restore", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Cartella sorgente non disponibile"])
                    }
                    try await self.runLocal(sourceRootURL: sourceRootURL, selectedFolders: selectedFolders,
                                             destination: destination)
                case .s3:
                    guard let s3Config else {
                        throw NSError(domain: "Restore", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Configurazione Cubbit non disponibile"])
                    }
                    try await self.runS3(selectedFolders: selectedFolders, destination: destination, config: s3Config)
                }
                guard !self.wasStopped else { return }
                self.phase = .success("Ripristino completato")
            } catch {
                guard !self.wasStopped else { return }
                self.phase = .failed("Errore: \(error.localizedDescription)")
            }
        }
    }

    private func runLocal(sourceRootURL: URL, selectedFolders: Set<String>, destination: URL) async throws {
        let folders = selectedFolders.sorted()
        var combinedTotal = 0
        for folder in folders {
            let preview = await syncer.previewSync(from: sourceRootURL.appendingPathComponent(folder),
                                                     to: destination.appendingPathComponent(folder), deep: false)
            combinedTotal += preview.toAdd + preview.toSkip
        }
        progress.total = combinedTotal

        var offset = 0
        for folder in folders {
            let result = try await syncer.sync(
                from: sourceRootURL.appendingPathComponent(folder),
                to: destination.appendingPathComponent(folder),
                deep: false,
                onStatus: { _ in },
                onProgress: { [weak self] snap in
                    Task { @MainActor [weak self] in
                        self?.progress.done = offset + snap.done
                    }
                })
            offset += result.done
            if result.errors > 0 {
                progress.problems.append("\(folder): \(result.errors) file non recuperati")
            }
        }
        progress.done = offset
    }

    private func runS3(selectedFolders: Set<String>, destination: URL, config: S3Syncer.S3Config) async throws {
        let result = try await s3Syncer.downloadMany(
            selectedFolders: selectedFolders, config: config, destination: destination,
            onStatus: { _ in },
            onProgress: { [weak self] snap in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.progress.done = snap.done
                    self.progress.total = snap.total
                }
            })
        progress.problems.append(contentsOf: result.problems)
    }

    func stop() {
        wasStopped = true
        syncer.cancel()
        s3Syncer.cancel()
        runTask?.cancel()
        runTask = nil
        phase = .failed("Interrotto dall'utente")
    }
}

struct RestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    @StateObject private var volumes = VolumeMonitor()
    @StateObject private var engine = RestoreEngine()
    private let s3Syncer = S3Syncer()

    enum Step { case chooseSource, chooseFolders, chooseDestination, running }
    enum S3Status { case checking, available, unavailable(String) }

    @State private var step: Step = .chooseSource
    @State private var selectedSource: RestoreSource?
    @State private var sourceRootURL: URL?
    @State private var s3Config: S3Syncer.S3Config?
    @State private var s3Status: S3Status = .checking
    @State private var availableFolders: [String] = []
    @State private var selectedFolders: Set<String> = []
    @State private var destinationURL: URL?
    @State private var showS3EstimateAlert = false
    @State private var s3EstimateText = ""
    @State private var hoveredRow: String? = nil

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            switch step {
            case .chooseSource: chooseSourceStep
            case .chooseFolders: chooseFoldersStep
            case .chooseDestination: chooseDestinationStep
            case .running: runningStep
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 440)
        .task { await checkS3Reachability() }
    }

    private var chooseSourceStep: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.down.doc").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
                Text("Da dove vuoi ripristinare?").font(AppFont.title)
            }
            VStack(spacing: AppSpacing.md) {
                restoreSourceRow(.ssd, available: volumes.ssdMounted,
                                  unavailableReason: "non collegato in questo momento")
                restoreSourceRow(.hdd, available: volumes.hddMounted,
                                  unavailableReason: "non collegato in questo momento")
                s3SourceRow
            }
            Spacer()
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private func restoreSourceRow(_ source: RestoreSource, available: Bool, unavailableReason: String) -> some View {
        Button {
            selectedSource = source
            let loc: BookmarkManager.Location = source == .ssd ? .ssd : .hdd
            if let existing = bm.urls[loc] {
                sourceRootURL = existing
                proceedToFolders(rootURL: existing)
            } else {
                bm.selectAndSave(loc) { ok in
                    guard ok, let url = bm.urls[loc] else { return }
                    sourceRootURL = url
                    proceedToFolders(rootURL: url)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(source.displayName).font(AppFont.body)
                    if !available {
                        Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(AppSpacing.md).cardBackground()
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                    .fill(Color.primary.opacity(hoveredRow == source.rawValue ? 0.05 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? source.rawValue : nil }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
    }

    private var s3SourceRow: some View {
        Group {
            switch s3Status {
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifica Cubbit in corso…").font(AppFont.body).foregroundStyle(.secondary)
                    Spacer()
                }.padding(AppSpacing.md).cardBackground()
            case .available:
                Button {
                    selectedSource = .s3
                    proceedToFolders(rootURL: nil)
                } label: {
                    HStack {
                        Text(RestoreSource.s3.displayName).font(AppFont.body)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(AppSpacing.md).cardBackground()
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                            .fill(Color.primary.opacity(hoveredRow == "s3" ? 0.05 : 0))
                    )
                }.buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? "s3" : nil }
                }
            case .unavailable(let reason):
                HStack {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(RestoreSource.s3.displayName).font(AppFont.body)
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(AppSpacing.md).cardBackground()
                .opacity(0.45)
            }
        }
    }

    private func checkS3Reachability() async {
        await runner.loadS3ConfigIfNeeded()
        guard let cfg = runner.s3Config else {
            s3Status = .unavailable("configurazione mancante")
            return
        }
        s3Config = cfg
        let reachable = await s3Syncer.checkReachable(config: cfg)
        s3Status = reachable ? .available : .unavailable("non raggiungibile in questo momento")
    }

    private func proceedToFolders(rootURL: URL?) {
        Task {
            let folders: [String]
            if let rootURL {
                folders = engine.listAvailableFolders(rootURL: rootURL)
            } else if let s3Config {
                folders = (try? await engine.listAvailableFolders(fromS3Config: s3Config)) ?? []
            } else {
                folders = []
            }
            await MainActor.run {
                availableFolders = folders
                selectedFolders = Set(folders)
                step = .chooseFolders
            }
        }
    }

    private var chooseFoldersStep: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "folder").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
                Text("Cosa vuoi ripristinare?").font(AppFont.title)
                Text("Sono già tutte selezionate — deseleziona solo quello che non ti serve.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(availableFolders, id: \.self) { folder in
                        Button {
                            if selectedFolders.contains(folder) { selectedFolders.remove(folder) }
                            else { selectedFolders.insert(folder) }
                        } label: {
                            HStack {
                                Image(systemName: selectedFolders.contains(folder) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedFolders.contains(folder) ? Color.accentColor : Color.secondary)
                                Text(folder).font(AppFont.body)
                                Spacer()
                            }
                            .padding(AppSpacing.md).cardBackground()
                            .overlay(
                                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                                    .fill(Color.primary.opacity(hoveredRow == folder ? 0.05 : 0))
                            )
                        }.buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? folder : nil }
                        }
                    }
                }
            }
            HStack {
                Button("Indietro") { step = .chooseSource }.buttonStyle(.bordered)
                Spacer()
                Button("Continua") { step = .chooseDestination }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFolders.isEmpty)
            }
        }
    }

    private var chooseDestinationStep: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
                Text("Dove vuoi salvare le foto?").font(AppFont.title)
                Text("Dopo potrai trascinarle nell'app Foto quando vuoi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let destinationURL {
                Text(destinationURL.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button(destinationURL == nil ? "Scegli cartella…" : "Cambia cartella…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Scegli"
                if panel.runModal() == .OK, let url = panel.url { destinationURL = url }
            }.buttonStyle(.bordered)
            Spacer()
            HStack {
                Button("Indietro") { step = .chooseFolders }.buttonStyle(.bordered)
                Spacer()
                Button("Ripristina") { startRestore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(destinationURL == nil)
            }
        }
        .alert("Prima di scaricare da Cubbit", isPresented: $showS3EstimateAlert) {
            Button("Annulla", role: .cancel) { }
            Button("Continua") { beginRun() }
        } message: { Text(s3EstimateText) }
    }

    private var runningStep: some View {
        VStack(spacing: AppSpacing.xl) {
            switch engine.phase {
            case .running:
                ProgressView(value: Double(engine.progress.percent), total: 100)
                    .progressViewStyle(.linear).frame(maxWidth: 320)
                Text("Recuperate \(engine.progress.done) di \(engine.progress.total) foto")
                    .font(AppFont.body)
                if engine.progress.etaSec > 0 {
                    Text("Tempo stimato: \(FileSyncer.SyncResult.hms(engine.progress.etaSec))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Interrompi") { engine.stop() }.buttonStyle(.bordered).tint(AppColor.error)
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.success)
                Text("Fatto! Le tue foto sono qui").font(AppFont.title)
                if let destinationURL {
                    Button("Apri cartella") { NSWorkspace.shared.activateFileViewerSelecting([destinationURL]) }
                        .buttonStyle(.bordered)
                }
                if !engine.progress.problems.isEmpty {
                    Text("\(engine.progress.problems.count) file non è stato possibile recuperare")
                        .font(.caption).foregroundStyle(AppColor.warning)
                }
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.warning)
                Text(msg).font(AppFont.body).multilineTextAlignment(.center)
                Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent)
            case .idle:
                ProgressView()
            }
        }
    }

    private func startRestore() {
        guard let selectedSource else { return }
        if selectedSource == .s3, let destinationURL, let s3Config {
            Task {
                let estimate = try? await engine.estimateS3Download(
                    selectedFolders: selectedFolders, destination: destinationURL, config: s3Config)
                await MainActor.run {
                    if let estimate {
                        let gb = Double(estimate.bytes) / 1_073_741_824
                        s3EstimateText = "Stai per scaricare \(estimate.count) file (~\(String(format: "%.1f", gb)) GB). Potrebbe richiedere qualche ora."
                    } else {
                        s3EstimateText = "Impossibile stimare la dimensione — continuo comunque?"
                    }
                    showS3EstimateAlert = true
                }
            }
        } else {
            beginRun()
        }
    }

    private func beginRun() {
        guard let selectedSource, let destinationURL else { return }
        step = .running
        engine.run(source: selectedSource, selectedFolders: selectedFolders,
                   sourceRootURL: sourceRootURL, destination: destinationURL, s3Config: s3Config)
    }
}

// MARK: - SetupView
struct SetupView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    @State private var showRestore = false
    var body: some View {
        VStack(spacing: AppSpacing.xxl) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: AppIconSize.heroLarge)).foregroundStyle(.blue)
                Text("Configurazione Backup Foto")
                    .font(AppFont.title)
                Text("Seleziona le cartelle una volta sola — l'app le ricorderà automaticamente.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: AppSpacing.md) {
                ForEach(BookmarkManager.Location.allCases) { loc in
                    LocationRow(location: loc) { bm.selectAndSave(loc) { _ in } }
                }
            }.padding(.horizontal, AppSpacing.xl)
            Text("Appena selezioni la Libreria Foto l'app si apre — SSD e HDD puoi configurarli quando vuoi, anche più avanti da Impostazioni.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Ho già un backup, voglio ripristinare") { showRestore = true }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(AppSpacing.xxl).frame(minWidth: 500, minHeight: 420)
        .sheet(isPresented: $showRestore) { RestoreView() }
    }
}

struct LocationRow: View {
    @ObservedObject private var bm = BookmarkManager.shared
    let location: BookmarkManager.Location
    let onSelect: () -> Void
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: bm.urls[location] != nil ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(bm.urls[location] != nil ? AppColor.success : .secondary).font(.system(size: 18))
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(location.displayName).font(AppFont.body)
                if let url = bm.urls[location] {
                    Text(url.path).font(AppFont.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(location.hint).font(AppFont.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            Button(bm.urls[location] != nil ? "Cambia" : "Seleziona", action: onSelect)
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).cardBackground()
    }
}

// MARK: - ContentView
struct ContentView: View {
    @EnvironmentObject private var runner: BackupRunner
    @StateObject private var volumes = VolumeMonitor()
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var showHamburger = false
    @State private var activeSpeedTab: SpeedLogTab = .speed
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    @State private var showQuitConfirm = false
    private let reviewEngine = ReviewEngine()
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationSplitView {
                SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
                    .frame(maxHeight: .infinity)
            } detail: {
                VStack(spacing: 0) {
                    HStack(spacing: AppSpacing.sm) {
                        PhaseIndicator(phase: runner.phase, percent: runner.stats.percent)
                        Spacer()
                        Button {
                            activeSpeedTab = .log
                        } label: { Label("Log", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                        if runner.isRunning {
                            Button(role: .destructive) { runner.stop() } label: {
                                Label("Interrompi", systemImage: "stop.fill")
                            }.buttonStyle(.bordered).controlSize(.small).tint(AppColor.error)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.regularMaterial)
                    Divider()
                    SpeedLogPanel(history: runner.speedHistory, output: runner.output, speedUnit: runner.speedUnit, activeTab: $activeSpeedTab)
                        .padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, AppSpacing.sm)
                    if runner.phase != .idle {
                        Divider()
                        StatsPanel(stats: runner.stats, phase: runner.phase, currentStatus: runner.currentStatus, currentThumbnail: runner.currentThumbnail)
                            .padding(AppSpacing.lg)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Esci") { confirmQuit() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            if showHamburger {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showHamburger = false } }
                    .zIndex(9)
                    .transition(.opacity)

                HamburgerPanel(isVisible: $showHamburger, showSettings: $showSettings, onShowLog: {
                    activeSpeedTab = .log
                    withAnimation(.easeInOut(duration: 0.22)) { showHamburger = false }
                })
                    .frame(width: 252, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .leading)
                    .zIndex(10)
                    .transition(.move(edge: .leading))
            }
        }
        .onAppear { Notifier.requestAuthorization() }
        .task {
            await runner.loadS3ConfigIfNeeded()
            runner.toolsReviewFindings = reviewEngine.runConfigChecks(
                s3Config: runner.s3Config,
                s3ConfigFromKeychain: runner.s3ConfigFromKeychain,
                s3ConfigError: runner.s3ConfigError)
        }
        .onChange(of: runner.completionSnapshot?.phase) { _, p in
            if let p, p.isTerminal { showCompletion = true }
        }
        .onChange(of: volumes.ssdMounted) { _, mounted in
            guard mounted else { return }
            if autoBackupEnabled && !runner.isRunning {
                // Il backup automatico scrive sull'SSD: leggerlo per intero nello stesso
                // momento rallenta entrambi e fa risultare illeggibili i file che il backup
                // sta scrivendo proprio ora. L'elenco si aggiorna a fine job, che e' anche
                // il momento in cui serve davvero aggiornato.
                runner.runMacToSSD()
            } else {
                runner.autoRefreshLibraryIndexIfEnabled()
            }
        }
        .sheet(isPresented: $showCompletion) {
            if let snap = runner.completionSnapshot {
                CompletionSheet(phase: snap.phase, stats: snap.stats) { showCompletion = false }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .alert(runner.pendingAlert?.title ?? "", isPresented: Binding(
            get: { runner.pendingAlert != nil },
            set: { if !$0 { runner.pendingAlert = nil } }
        ), presenting: runner.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
        .alert("Chiudere l'app?", isPresented: $showQuitConfirm) {
            Button("Esci", role: .destructive) {
                if runner.isRunning { runner.stop() }
                NSApp.terminate(nil)
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("I processi in corso verranno interrotti.")
        }
    }

    private func confirmQuit() {
        showQuitConfirm = true
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var gate = AuthGateManager.shared
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    @AppStorage(LibraryIndexAutoRefresh.defaultsKey) private var autoRefreshLibraryIndex: Bool = true
    @State private var showDiskPrep = false
    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("Impostazioni").font(AppFont.title)
            Text("Modifica le cartelle selezionate").font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Toggle("Backup automatico Mac → SSD quando colleghi l'SSD", isOn: $autoBackupEnabled)
                Text("Appena colleghi l'SSD, se l'app è aperta, parte da sola l'aggiornamento da Foto a SSD.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppSpacing.xl)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Toggle("Tieni aggiornato da solo l'elenco delle foto già salvate", isOn: $autoRefreshLibraryIndex)
                Text("Quando colleghi l'SSD, o appena finisce una copia, l'app dà un'occhiata veloce solo alle foto nuove. La prima creazione dell'elenco resta manuale, da Diagnostica: quella dura diversi minuti.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppSpacing.xl)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Toggle("Richiedi Touch ID all'avvio", isOn: $gate.touchIDEnabled)
                Text("Se disattivato, l'app si apre senza chiedere l'autenticazione.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppSpacing.xl)
            VStack(spacing: AppSpacing.md) {
                ForEach(BookmarkManager.Location.allCases) { loc in
                    LocationRow(location: loc) { bm.selectAndSave(loc) { _ in } }
                }
            }.padding(.horizontal, AppSpacing.xl)
            Button("Prepara un disco nuovo…") { showDiskPrep = true }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(AppSpacing.xxl).frame(minWidth: 480)
        .sheet(isPresented: $showDiskPrep) { DiskPrepView() }
    }
}

// MARK: - DiskPrepView (roadmap #28)
/// Formattazione guidata di un disco esterno nuovo, mai configurato prima come SSD/HDD di
/// backup. Aperta da Impostazioni → "Prepara un disco nuovo…". `DiskFormatter` fa da sola tutte
/// le verifiche di sicurezza (fail-closed sull'elenco, ri-verifica fresca in `erase()`) — questa
/// view aggiunge solo la conferma umana: digitare il nome esatto del disco più un `.alert` di
/// conferma esplicita prima di eseguire l'operazione irreversibile.
struct DiskPrepView: View {
    @Environment(\.dismiss) private var dismiss
    private enum Step { case list, confirm, result }

    @State private var step: Step = .list
    @State private var candidates: [CandidateDisk] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil

    @State private var selectedDisk: CandidateDisk? = nil
    @State private var filesystem: DiskFormatter.DiskFilesystem = .apfs
    @State private var typedName = ""
    @State private var showEraseConfirmation = false
    @State private var isErasing = false
    @State private var eraseError: String? = nil
    @State private var eraseSucceeded = false

    var body: some View {
        Group {
            switch step {
            case .list: listStep
            case .confirm: confirmStep
            case .result: resultStep
            }
        }
        .padding(AppSpacing.xxl)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { if candidates.isEmpty && loadError == nil { refresh() } }
    }

    private var listStep: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Prepara un disco nuovo").font(AppFont.title)
            Text("Solo dischi esterni mai configurati come SSD o HDD di backup possono essere formattati qui — i tuoi dischi di backup non compaiono mai in questo elenco.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            if isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: AppSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColor.warning)
                    Text(loadError).font(.callout).multilineTextAlignment(.center)
                }.frame(maxHeight: .infinity)
            } else if candidates.isEmpty {
                Text("Nessun disco candidabile trovato. Collega un disco esterno nuovo e premi Aggiorna.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(candidates) { disk in
                            Button {
                                selectedDisk = disk
                                typedName = ""
                                eraseError = nil
                                filesystem = .apfs
                                step = .confirm
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(disk.name).font(.headline)
                                        Text("\(disk.identifier) · \(disk.currentFilesystem) · "
                                             + ByteCountFormatter.string(fromByteCount: disk.sizeBytes, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(AppSpacing.md).cardBackground()
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Button("Aggiorna") { refresh() }.disabled(isLoading)
                Spacer()
                Button("Chiudi") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        if let disk = selectedDisk {
            VStack(spacing: AppSpacing.lg) {
                Text("Formatta \"\(disk.name)\"").font(AppFont.title)
                Text("Cancella TUTTO il contenuto del disco. L'operazione è irreversibile.")
                    .font(.subheadline).foregroundStyle(AppColor.error).multilineTextAlignment(.center)

                Picker("Filesystem", selection: $filesystem) {
                    ForEach(DiskFormatter.DiskFilesystem.allCases) { fs in
                        Text(fs.rawValue).tag(fs)
                    }
                }.pickerStyle(.segmented).padding(.horizontal, AppSpacing.xl)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Per confermare, scrivi esattamente il nome del disco:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(disk.name).font(.callout.weight(.semibold)).textSelection(.enabled)
                    TextField("Nome disco", text: $typedName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isErasing)
                }.padding(.horizontal, AppSpacing.xl)

                if let eraseError {
                    Text(eraseError).font(.callout).foregroundStyle(AppColor.error)
                        .multilineTextAlignment(.center).padding(.horizontal, AppSpacing.xl)
                }
                if isErasing {
                    ProgressView("Formattazione in corso…")
                }

                HStack {
                    Button("Indietro") { step = .list; eraseError = nil }.disabled(isErasing)
                    Spacer()
                    Button("Formatta") { showEraseConfirmation = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(isErasing || typedName != disk.name)
                }
            }
            .alert("Formattare \"\(disk.name)\"?", isPresented: $showEraseConfirmation) {
                Button("Formatta", role: .destructive) { performErase(disk: disk) }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Tutti i dati su questo disco verranno cancellati in modo permanente. Non è possibile recuperarli dopo.")
            }
        }
    }

    private var resultStep: some View {
        VStack(spacing: AppSpacing.lg) {
            if eraseSucceeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.success)
                Text("Disco formattato").font(AppFont.title)
                Text("Ora vai in Impostazioni e seleziona questo disco come SSD o HDD.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.error)
                Text("Formattazione non eseguita").font(AppFont.title)
                if let eraseError {
                    Text(eraseError).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func refresh() {
        isLoading = true
        loadError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let disks = try DiskFormatter.listEligibleDisks()
                DispatchQueue.main.async {
                    candidates = disks
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = error.localizedDescription
                    candidates = []
                    isLoading = false
                }
            }
        }
    }

    private func performErase(disk: CandidateDisk) {
        isErasing = true
        eraseError = nil
        let fs = filesystem
        let name = typedName
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DiskFormatter.erase(identifier: disk.identifier, filesystem: fs, newName: name)
                DispatchQueue.main.async {
                    isErasing = false
                    eraseSucceeded = true
                    step = .result
                }
            } catch {
                DispatchQueue.main.async {
                    isErasing = false
                    eraseError = error.localizedDescription
                    eraseSucceeded = false
                    step = .result
                }
            }
        }
    }
}

// MARK: - CompletionSheet
struct CompletionSheet: View {
    let phase: JobPhase; let stats: JobStats; let onDismiss: () -> Void
    private var ok: Bool { if case .success = phase { return true }; return false }
    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: AppIconSize.heroLarge)).foregroundStyle(ok ? AppColor.success : AppColor.error).symbolRenderingMode(.hierarchical)
            Text(ok ? "Backup completato" : "Backup fallito").font(AppFont.title)
            Text(phase.label).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: AppSpacing.md) {
                StatTile(label: "Copiati",  value: "\(stats.copied)",  accent: AppColor.inProgress, compact: true)
                StatTile(label: "Skippati", value: "\(stats.skipped)", accent: .secondary, compact: true)
                StatTile(label: "Errori",   value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary, compact: true)
                StatTile(label: "Durata",   value: stats.elapsed,      accent: .secondary, compact: true)
            }
            if stats.verifiedOk > 0 {
                Label("\(stats.verifiedOk) file verificati con SHA256 ✓",
                      systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(AppColor.success).multilineTextAlignment(.center)
            }
            if stats.hashErrors > 0 {
                Label("\(stats.hashErrors) hash mismatch — controlla il log",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppColor.warning).multilineTextAlignment(.center)
            }
            if stats.copiedUnverified > 0 {
                Label("Copiati ma non verificati: \(stats.copiedUnverified) — il controllo di integrità non ha potuto concludersi (file in uso durante la copia?)",
                      systemImage: "questionmark.circle.fill")
                    .font(.caption).foregroundStyle(AppColor.warning).multilineTextAlignment(.center)
            }
            if stats.changedSkipped > 0 {
                Label("\(stats.changedSkipped) file locali cambiati, non copiati (regola zero-overwrite)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(AppColor.warning).multilineTextAlignment(.center)
            }
            if stats.duplicatesSkipped > 0 {
                Label("Già presenti in libreria, non copiati: \(stats.duplicatesSkipped)",
                      systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if stats.errors > 0 {
                Label("Controlla il log per i dettagli sugli errori.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppColor.warning).multilineTextAlignment(.center)
            }
            Button(action: onDismiss) { Text("OK").frame(minWidth: 120) }
                .buttonStyle(.borderedProminent).tint(ok ? AppColor.success : AppColor.error).keyboardShortcut(.defaultAction)
        }.padding(AppSpacing.xxl).frame(minWidth: 380)
    }
}

struct StatTile: View {
    let label: String; let value: String; let accent: Color
    var compact: Bool = false
    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                .contentTransition(.numericText())
                .animation(.default, value: value)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: compact ? 58 : nil, maxWidth: compact ? nil : .infinity)
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, compact ? 8 : 0)
        .cardBackground()
    }
}

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            configuration.label
            configuration.content
        }
        .padding(AppSpacing.md)
        .cardBackground()
    }
}

// MARK: - Sidebar
struct SidebarView: View {
    @ObservedObject var volumes: VolumeMonitor
    @ObservedObject var runner: BackupRunner
    @Binding var showHamburger: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showHamburger.toggle() }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showHamburger ? Color.accentColor : Color.primary)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Backup Foto").font(AppFont.title)
                    Text("Backup personale").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, AppSpacing.lg).padding(.bottom, 16)

            Divider()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HamburgerSectionLabel("Volumi")
                VolumeRow(name: "SSD - Enri",  icon: "internaldrive.fill",  mounted: volumes.ssdMounted)
                VolumeRow(name: "BackupHDD",   icon: "externaldrive.fill",  mounted: volumes.hddMounted)
                VolumeRow(name: "Cubbit S3",   icon: "cloud.fill",          mounted: true, alwaysOn: true)
            }.padding(.bottom, AppSpacing.sm)
            Divider()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HamburgerSectionLabel("Operazioni")
                OpsButton(title: "MAC -> SSD", subtitle: "Photos originals → SSD",
                          icon: "photo.on.rectangle.angled", color: AppColor.macToSSD,
                          enabled: !runner.isRunning && volumes.ssdMounted,
                          action: { runner.runMacToSSD() },
                          onPreview: { runner.previewMacToSSD() })
                OpsButton(title: "SSD -> HDD", subtitle: "Mirror locale (deep ogni 30gg)",
                          icon: "externaldrive.badge.plus", color: AppColor.ssdToHDD,
                          enabled: !runner.isRunning && volumes.ssdMounted && volumes.hddMounted,
                          action: { runner.runSSDToHDD() },
                          onPreview: { runner.previewSSDToHDD() })
                OpsButton(title: "SSD -> Cubbit S3", subtitle: "Cloud backup nativo Swift",
                          icon: "icloud.and.arrow.up", color: AppColor.ssdToCubbit,
                          enabled: !runner.isRunning && volumes.ssdMounted,
                          action: { runner.runSyncS3() },
                          onPreview: { runner.previewSyncS3() })
            }
            Spacer()
            if let start = runner.startTime {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Avviato alle").font(AppFont.caption).foregroundStyle(.secondary)
                        Text(start, style: .time).font(.caption).monospacedDigit()
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, AppSpacing.sm)
            }
        }
    }
}

struct VolumeRow: View {
    let name: String; let icon: String; let mounted: Bool; var alwaysOn = false
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundStyle(mounted ? (alwaysOn ? AppColor.ssdToCubbit : Color.primary) : Color.secondary.opacity(0.4))
                .frame(width: 20)
            Text(name).font(AppFont.body).foregroundStyle(mounted ? Color.primary : Color.secondary)
            Spacer()
            Circle().fill(mounted ? (alwaysOn ? AppColor.ssdToCubbit : AppColor.success) : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
        }.padding(.horizontal, 16).padding(.vertical, AppSpacing.xs)
    }
}

struct OpsButton: View {
    let title: String; let subtitle: String; let icon: String
    let color: Color; let enabled: Bool; let action: () -> Void
    var onPreview: (() -> Void)? = nil
    @State private var isHovering = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(enabled ? color : Color.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(title).font(AppFont.body)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Text(subtitle).font(AppFont.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                .background(Color.primary.opacity(isHovering && enabled ? 0.05 : 0))
            }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
            }
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help("Anteprima: mostra quanti file verranno copiati senza avviare il backup")
            }
        }
    }
}

// MARK: - Hamburger Panel
struct HamburgerPanel: View {
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    var onShowLog: (() -> Void)? = nil
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let profileName = "Backup Foto"
    private let profileEmail = ""

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var runner: BackupRunner
    @EnvironmentObject private var updater: UpdaterViewModel
    @ObservedObject private var appearance = AppearanceManager.shared
    @State private var showAppearance = false
    @State private var showRestore = false
    @State private var toolsLoading = false
    private let reviewEngine = ReviewEngine()

    private var initials: String {
        profileName.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
    private var systemLanguageName: String {
        let preferred = Locale.preferredLanguages.first ?? "it"
        let code = Locale(identifier: preferred).language.languageCode?.identifier ?? "it"
        return Locale(identifier: preferred).localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                        Text(initials).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(profileName).font(AppFont.body)
                        Text(profileEmail).font(AppFont.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isVisible = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.top, AppSpacing.lg).padding(.bottom, AppSpacing.md)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HamburgerSectionLabel("Strumenti")
                        HamburgerRow(icon: "doc.text.magnifyingglass", label: "Report Log", iconColor: .blue) {
                            onShowLog?(); close()
                        }
                        HamburgerRow(icon: "arrow.down.doc.fill", label: "Ripristina", iconColor: .green) {
                            showRestore = true
                        }
                        HamburgerRow(icon: "gearshape.fill", label: "Configurazione", iconColor: AppColor.utility) {
                            showSettings = true; close()
                        }
                        HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: AppColor.utility,
                                     alert: !runner.toolsReviewFindings.isEmpty) {
                            guard !toolsLoading else { return }
                            toolsLoading = true
                            let skipOrphanedCheck = runner.isRunning
                            Task {
                                await runner.loadS3ConfigIfNeeded()
                                let findings = reviewEngine.runConfigChecks(
                                    s3Config: runner.s3Config, s3ConfigFromKeychain: runner.s3ConfigFromKeychain,
                                    s3ConfigError: runner.s3ConfigError)
                                let orphaned: [S3Syncer.OrphanedMultipartUpload]
                                if !skipOrphanedCheck, let cfg = runner.s3Config {
                                    orphaned = (try? await reviewEngine.findOrphanedMultipartUploads(config: cfg)) ?? []
                                } else {
                                    orphaned = []
                                }
                                await MainActor.run {
                                    runner.toolsReviewFindings = findings
                                    runner.toolsOrphanedUploads = orphaned
                                    toolsLoading = false
                                    openWindow(id: "tools")
                                }
                            }
                        }

                        HamburgerRow(icon: "magnifyingglass", label: "Catalogo", iconColor: .indigo) {
                            Task {
                                await runner.loadS3ConfigIfNeeded()
                                await MainActor.run { openWindow(id: "catalog") }
                            }
                        }
                        HamburgerRow(icon: "photo.stack", label: "Foto", iconColor: .pink) {
                            openWindow(id: "immich")
                        }
                        HamburgerRow(icon: "arrow.triangle.2.circlepath", label: "Controlla aggiornamenti", iconColor: .cyan) {
                            updater.controller.checkForUpdates(nil)
                        }

                        HamburgerSectionLabel("Preferenze").padding(.top, AppSpacing.xs)
                        HamburgerRow(icon: "paintbrush.fill", label: "Aspetto", iconColor: .orange, badge: appearance.mode) {
                            showAppearance = true
                        }
                        HamburgerRow(icon: "globe", label: "Lingua", iconColor: .teal, badge: systemLanguageName) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Spacer()
                Divider()
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "info.circle").font(AppFont.caption).foregroundStyle(.secondary)
                    Text("Versione \(version)").font(AppFont.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, AppSpacing.sm)
            }
        .frame(width: 252)
        .background(.windowBackground)
        .shadow(color: .black.opacity(0.18), radius: 12, x: 5, y: 0)
        .sheet(isPresented: $showAppearance) { AppearanceSheet() }
        .sheet(isPresented: $showRestore)    { RestoreView() }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.22)) { isVisible = false }
    }
}

struct HamburgerSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.sectionHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, AppSpacing.xs).padding(.bottom, AppSpacing.xs)
    }
}

struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    var alert: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(label)
                    .font(AppFont.body)
                    .foregroundStyle(Color.primary)

                Spacer()

                if alert {
                    Circle().fill(AppColor.error).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
        }
    }
}

// MARK: - Phase & Status
struct PhaseIndicator: View {
    let phase: JobPhase; let percent: Int
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if case .running = phase {
                ProgressView().controlSize(.small)
                Text(percent >= 100 ? "Finalizzando..." : phase.label)
                    .font(AppFont.body).foregroundStyle(phase.color)
            } else {
                Image(systemName: phase.icon).foregroundStyle(phase.color)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: phase)
                Text(phase.label).font(AppFont.body).foregroundStyle(phase.color)
            }
        }
    }
}

struct CurrentFileThumbnail: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2), lineWidth: 1))
    }
}

struct StatusBar: View {
    let status: String; let phase: JobPhase
    var body: some View {
        if !status.isEmpty {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "info.circle.fill").font(.system(size: 11))
                    .foregroundStyle(phase.color.opacity(0.8))
                Text(status).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(phase.color.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(phase.color.opacity(0.2), lineWidth: 1))
        }
    }
}

// MARK: - Stats Panel
struct StatsPanel: View {
    let stats: JobStats; let phase: JobPhase; let currentStatus: String; let currentThumbnail: NSImage?
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            HStack(spacing: AppSpacing.sm) {
                CurrentFileThumbnail(image: currentThumbnail)
                StatusBar(status: currentStatus, phase: phase)
            }
            VStack(spacing: AppSpacing.sm) {
                HStack {
                    Text("Avanzamento").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(stats.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.percent)
                }
                ProgressView(value: Double(stats.percent), total: 100).progressViewStyle(.linear)
                    .tint(phase == .idle ? .secondary : (stats.errors > 0 ? AppColor.error : AppColor.inProgress))
                HStack {
                    Text("\(stats.done) / \(stats.total) file")
                        .font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Text("velocita \(stats.speed)").font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.speed)
                }
            }
            HStack(spacing: AppSpacing.md) {
                StatTile(label: "Copiati",   value: "\(stats.copied)",  accent: AppColor.inProgress)
                StatTile(label: "Skippati",  value: "\(stats.skipped)", accent: .secondary)
                StatTile(label: "Errori",    value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary)
                StatTile(label: "Trascorso", value: stats.elapsed,      accent: .secondary)
                StatTile(label: "ETA",       value: stats.eta,           accent: .secondary)
            }
        }
    }
}


// MARK: - Speed / Log Panel
enum SpeedLogTab: String, CaseIterable {
    case speed = "Speed"
    case log = "Log"
}

struct SpeedLogPanel: View {
    let history: [SpeedSample]
    let output: String
    let speedUnit: String
    @Binding var activeTab: SpeedLogTab

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Picker("", selection: $activeTab) {
                    ForEach(SpeedLogTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Spacer()

                if activeTab == .log {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    } label: { Label("Copia", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small)

                    Button {
                        let p = NSSavePanel()
                        p.allowedContentTypes = [.plainText]
                        p.nameFieldStringValue = "backup_log_\(Int(Date().timeIntervalSince1970)).txt"
                        if p.runModal() == .OK, let url = p.url {
                            try? output.data(using: .utf8)?.write(to: url)
                        }
                    } label: { Label("Salva", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }

            if activeTab == .speed {
                SpeedChartView(history: history, unit: speedUnit)
            } else {
                LogContentView(output: output)
            }
        }
    }
}

struct SpeedChartView: View {
    let history: [SpeedSample]
    let unit: String

    private var yMax: Double {
        let peak = history.map(\.value).max() ?? 1
        return max(peak * 1.25, unit == "MB/s" ? 1.0 : 5.0)
    }

    var body: some View {
        Group {
            if history.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        VStack(spacing: AppSpacing.sm) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary.opacity(0.4))
                            Text("Il grafico velocità appare quando avvii un'operazione")
                                .font(AppFont.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    )
                    .frame(height: 84)
            } else {
                Chart(history) { sample in
                    LineMark(
                        x: .value("Tempo", sample.time),
                        y: .value(unit, sample.value)
                    )
                    .foregroundStyle(AppColor.inProgress)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Tempo", sample.time),
                        y: .value(unit, sample.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppColor.inProgress.opacity(0.22), AppColor.inProgress.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisTick().foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { val in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisTick().foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel {
                            if let v = val.as(Double.self) {
                                Text(v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...yMax)
                .chartYAxisLabel(unit, position: .trailing, alignment: .center)
                .chartXAxisLabel("Tempo", position: .bottom, alignment: .center)
                .animation(.easeInOut(duration: 0.5), value: history.count)
                .padding(.trailing, 4)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 0.5))
                .frame(minHeight: 190, maxHeight: .infinity)
            }
        }
    }
}

struct LogContentView: View {
    let output: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output.isEmpty ? "Nessun output." : output)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(AppSpacing.sm).id("bottom")
            }
            .frame(minHeight: 190, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 0.5))
            .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

// MARK: - Appearance Sheet
struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = AppearanceManager.shared
    private let modes = ["Sistema", "Chiaro", "Scuro"]
    private let icons = ["circle.lefthalf.filled", "sun.max.fill", "moon.fill"]

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("Aspetto Interfaccia").font(AppFont.title)
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(Array(zip(modes, icons)), id: \.0) { mode, icon in
                    Button {
                        appearance.mode = mode
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: appearance.mode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appearance.mode == mode ? Color.accentColor : Color.secondary)
                            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                            Text(mode)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(appearance.mode == mode ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppSpacing.sm).cardBackground()
            Button("OK") { dismiss() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(AppSpacing.xxl).frame(width: 300)
    }
}

// MARK: - Tools / Diagnostics Sheet
struct ToolsSheet: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var gate = AuthGateManager.shared
    @State private var showSecret = false
    @State private var lastJob: JobSummary? = JobHistoryStore.load()
    @State private var integrityResults: [IntegrityCheckResult] = []
    @State private var integrityRunning = false
    @State private var integrityStatus = ""
    @State private var pendingAlert: SimpleAlert? = nil
    private let reviewEngine = ReviewEngine()

    private let jobDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private let uploadDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    private let lastDeepDate: String = {
        if let d = UserDefaults.standard.object(forKey: "lastDeepMirrorDate") as? Date {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: d)
        }
        return "Mai eseguito"
    }()

    private func confirmReveal(_ action: @escaping () -> Void) {
        pendingAlert = SimpleAlert(
            title: "Rivelare le credenziali S3?",
            message: "Chiunque veda o registri lo schermo in questo momento potrà usarle per scrivere o cancellare file sul bucket. Continua solo se sei sicuro che nessuno stia guardando.",
            confirmTitle: "Continua",
            cancelTitle: "Annulla",
            onConfirm: action)
    }

    /// Stesso gate di `CatalogView`: "Diagnostica" è una scena di primo livello, apribile
    /// dal menu Finestra mentre la finestra principale è ancora bloccata (roadmap #30).
    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Diagnostica").font(AppFont.title)

            // Bug reale trovato da Enrico (2026-08-23): senza ScrollView, il contenuto (in
            // particolare "Revisione", che cresce con findings/upload incompleti) poteva superare
            // l'altezza della finestra — nessun modo di scorrere, testo in basso tagliato via
            // sotto il bordo dello schermo. Titolo e bottone "Chiudi" restano fissi fuori dallo
            // ScrollView, solo le card scorrono.
            ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
            GroupBox("Cartelle Configurate") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(BookmarkManager.Location.allCases) { loc in
                        HStack(spacing: AppSpacing.sm) {
                            Image(systemName: bm.urls[loc] != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(bm.urls[loc] != nil ? AppColor.success : AppColor.error)
                                .font(.system(size: 12))
                            Text(loc.displayName).font(.caption).frame(width: 140, alignment: .leading)
                            Text(bm.urls[loc]?.path ?? "Non configurato")
                                .font(AppFont.caption)
                                .foregroundStyle(bm.urls[loc] != nil ? Color.secondary : AppColor.error)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                    }
                }.padding(4)
            }

            GroupBox("S3 — Cubbit") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    if let cfg = runner.s3Config {
                        Text(runner.s3ConfigFromKeychain ? "Origine: Keychain" : "Origine: rclone.conf")
                            .font(AppFont.caption).foregroundStyle(.secondary)
                        DiagRow(label: "Endpoint",  value: cfg.endpoint)
                        DiagRow(label: "Bucket",    value: cfg.bucket)
                        DiagRow(label: "Region",    value: cfg.region)
                        HStack {
                            Text("AccessKey").font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            if showSecret {
                                Text(cfg.accessKeyId)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(String(repeating: "•", count: 20))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        HStack {
                            Text("SecretKey").font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            if showSecret {
                                Text(cfg.secretAccessKey)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(String(repeating: "•", count: 24))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(showSecret ? "Nascondi" : "Mostra") {
                                if showSecret { showSecret = false } else { confirmReveal { showSecret = true } }
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                        Button("Apri rclone.conf in TextEdit") {
                            confirmReveal {
                                let path = NSHomeDirectory() + "/.config/rclone/rclone.conf"
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, AppSpacing.xs)
                        Button("Aggiorna da rclone.conf") {
                            pendingAlert = SimpleAlert(
                                title: "Sovrascrivere le credenziali salvate?",
                                message: "Le credenziali attualmente nel Keychain verranno sostituite con quelle lette ora da rclone.conf.",
                                confirmTitle: "Continua",
                                cancelTitle: "Annulla",
                                onConfirm: {
                                    do {
                                        let config = try S3Syncer.readConfigFromFile(remoteName: "Cubbit", bucket: "backupfoto")
                                        try S3Syncer.writeToKeychain(config: config, remoteName: "Cubbit")
                                        // Stesso motivo di `LibraryIndexCard.alertSink`: qui
                                        // si sta assegnando il binding mentre SwiftUI smonta
                                        // l'alert che ha eseguito questo `onConfirm`.
                                        DispatchQueue.main.async {
                                            pendingAlert = SimpleAlert(title: "Credenziali aggiornate nel Keychain.")
                                        }
                                    } catch {
                                        DispatchQueue.main.async {
                                            pendingAlert = SimpleAlert(title: "Errore", message: error.localizedDescription)
                                        }
                                    }
                                })
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, AppSpacing.xs)
                    } else {
                        Label("rclone.conf non trovato o credenziali mancanti",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(AppColor.warning).font(.caption)
                    }
                }.padding(4)
            }

            GroupBox("Sync Info") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    DiagRow(label: "Ultimo deep", value: lastDeepDate)
                    DiagRow(label: "Log", value: "Visibile nella console principale (tab Log)")
                }.padding(4)
            }

            LibraryIndexCard(runner: runner, pendingAlert: $pendingAlert)

            GroupBox("Revisione") {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(runner.toolsReviewFindings) { finding in
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: finding.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.ok ? AppColor.success : AppColor.warning)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(finding.title).font(.caption).fontWeight(.medium)
                                Text(finding.detail).font(AppFont.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    if let lastJob {
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: lastJob.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(lastJob.isClean ? AppColor.success : AppColor.warning)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text("Ultimo job: \(lastJob.label)").font(.caption).fontWeight(.medium)
                                Text("\(jobDateFormatter.string(from: lastJob.date)) · Copiati \(lastJob.copied) · Skippati \(lastJob.skipped) · Errori \(lastJob.errors) · Hash-mismatch \(lastJob.hashErrors)")
                                    .font(AppFont.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Nessun job registrato").font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    Button(integrityRunning ? "Verifica in corso…" : "Verifica integrità campione (20 file per coppia)") {
                        integrityRunning = true
                        integrityResults = []
                        integrityStatus = ""
                        Task {
                            let results = await reviewEngine.runIntegritySample(onProgress: { status in
                                Task { @MainActor in integrityStatus = status }
                            })
                            await MainActor.run {
                                integrityResults = results
                                integrityRunning = false
                            }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(integrityRunning)

                    if integrityRunning {
                        Text(integrityStatus).font(AppFont.caption).foregroundStyle(.secondary)
                    }

                    ForEach(integrityResults) { result in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            if let error = result.error {
                                Text("\(result.pairName): saltato — \(error)")
                                    .font(AppFont.caption).foregroundStyle(AppColor.warning)
                            } else if result.mismatches.isEmpty {
                                Text("\(result.pairName): \(result.matched)/\(result.checked) verificati, 0 problemi")
                                    .font(AppFont.caption).foregroundStyle(AppColor.success)
                            } else {
                                Text("\(result.pairName): \(result.mismatches.count) mismatch su \(result.checked) verificati — \(result.mismatches.prefix(3).joined(separator: ", "))")
                                    .font(AppFont.caption).foregroundStyle(AppColor.error)
                            }
                        }
                    }

                    Divider()

                    if runner.isRunning {
                        Text("Controllo upload incompleti disponibile a job fermo")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !runner.toolsOrphanedUploads.isEmpty {
                        Text("Upload incompleti trovati").font(.caption).fontWeight(.medium)
                        ForEach(runner.toolsOrphanedUploads) { upload in
                            HStack(alignment: .top, spacing: AppSpacing.sm) {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text((upload.key as NSString).lastPathComponent).font(AppFont.caption)
                                    Text("iniziato il \(uploadDateFormatter.string(from: upload.initiated))")
                                        .font(AppFont.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Elimina") {
                                    pendingAlert = SimpleAlert(
                                        title: "Eliminare questo upload incompleto?",
                                        message: "Rimuove definitivamente le parti già caricate su Cubbit per '\((upload.key as NSString).lastPathComponent)'. Non tocca file già completati né la sorgente.",
                                        isDestructive: true,
                                        confirmTitle: "Elimina",
                                        cancelTitle: "Annulla",
                                        onConfirm: {
                                            Task {
                                                do {
                                                    guard let config = runner.s3Config else {
                                                        throw NSError(domain: "S3", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                                            "Configurazione S3 non disponibile — chiudi e riapri Tools."])
                                                    }
                                                    try await S3Syncer().abortMultipartUpload(
                                                        key: upload.key, uploadId: upload.uploadId, config: config)
                                                    await MainActor.run {
                                                        runner.toolsOrphanedUploads.removeAll { $0.id == upload.id }
                                                    }
                                                } catch {
                                                    await MainActor.run {
                                                        pendingAlert = SimpleAlert(title: "Impossibile eliminare l'upload", message: error.localizedDescription)
                                                    }
                                                }
                                            }
                                        })
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }.padding(4)
            }
            } // fine VStack interno allo ScrollView
            } // fine ScrollView

            HStack {
                Spacer()
                Button("Chiudi") { dismissWindow() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xxl).frame(minWidth: 560, minHeight: 480)
        .groupBoxStyle(CardGroupBoxStyle())
        .alert(bm.pendingAlert?.title ?? "", isPresented: Binding(
            get: { bm.pendingAlert != nil },
            set: { if !$0 { bm.pendingAlert = nil } }
        ), presenting: bm.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
        .alert(pendingAlert?.title ?? "", isPresented: Binding(
            get: { pendingAlert != nil },
            set: { if !$0 { pendingAlert = nil } }
        ), presenting: pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}

/// Card "Foto gia' salvate sull'SSD" del pannello Diagnostica (roadmap #31, Task 6).
///
/// Registro delle stringhe: si dice **a cosa serve**, mai come e' fatto. "Indice",
/// "hash", "SHA256", "scansione incrementale" non compaiono a schermo. Il comando
/// distruttivo dice sempre CHE COSA cancella, perche' "elimina" da solo, su un'app che
/// gestisce foto, si legge come "elimina le foto".
struct LibraryIndexCard: View {
    @ObservedObject var runner: BackupRunner
    @Binding var pendingAlert: SimpleAlert?
    @Environment(\.openWindow) private var openWindow

    /// Il canale d'avviso di QUESTA finestra. Ogni comando della card lo passa a `runner`:
    /// `runner.pendingAlert` e' presentato solo da `ContentView`, che sta in un'altra scena
    /// (vedi `AlertSink`), quindi un errore lasciato li' non comparirebbe mai qui — e la card
    /// resterebbe muta proprio nei casi in cui non e' successo niente (SSD non accessibile,
    /// elenco non apribile, svuotamento fallito).
    /// Perche' i comandi manuali sono disattivati, oppure `nil`. Fonte unica per lo stato
    /// dei bottoni e per la riga che lo spiega: due condizioni separate divergerebbero alla
    /// prima modifica di una sola delle due, ed e' gia' successo altrove in questo progetto.
    private var commandsDisabledReason: String? {
        LibraryIndexCommandGate.disabledReason(isIndexing: runner.isIndexing,
                                               jobIsRunning: runner.isRunning)
    }

    private var commandsDisabled: Bool { commandsDisabledReason != nil }

    /// L'avviso viene pubblicato **al giro di runloop successivo**.
    ///
    /// Rilievo minore di #31, chiuso il 2026-09-01: questi avvisi nascono dentro l'`onConfirm`
    /// di un altro alert (`confirmFirstBuild`, `confirmFullRecheck`, `confirmReset` passano
    /// tutti `alertSink` a `rebuildLibraryIndex`/`resetLibraryIndex`, che possono richiamarlo
    /// **sincronicamente** — per esempio quando l'SSD non e' collegato). Assegnare il binding
    /// mentre SwiftUI sta smontando l'alert che lo ha prodotto e' la ricetta perche' la
    /// seconda presentazione venga inghiottita: l'utente preme «Crea l'elenco», l'elenco non
    /// parte, e non compare niente che spieghi perche'.
    ///
    /// **Non e' stato misurato** e non e' misurabile da un test: servono due presentazioni
    /// SwiftUI vere. Il rinvio di un giro di runloop non e' un rimedio a un difetto
    /// dimostrato, e' cio' che rende la domanda irrilevante — costa un frame e toglie di
    /// mezzo l'unico ordine di eventi in cui il problema puo' esistere. Resta fra le
    /// verifiche manuali: aprire Diagnostica senza SSD e premere «Crea l'elenco».
    private var alertSink: AlertSink {
        { alert in DispatchQueue.main.async { pendingAlert = alert } }
    }

    /// Stima dichiarata prima di partire. Non e' mai stata misurata sul volume vero: e'
    /// scritta come un ordine di grandezza, non come una promessa.
    /// **Numero misurato, non stimato** (2026-09-01, primo collegamento dell'SSD dopo
    /// la scrittura della card). Throughput reale di lettura+SHA256 dall'SSD: 224 MiB/s
    /// su un campione di 300 file distribuiti, contro 237,4 GiB di media indicizzabili
    /// (47.482 file) = **~18 minuti**. La prima stesura diceva "dai 5 ai 15 minuti" ed
    /// era un ordine di grandezza scritto a tavolino, con l'estremo superiore sotto la
    /// misura vera. Se il contenuto dell'SSD cambia sensibilmente, si rimisura: non si
    /// ritocca a occhio.
    private let durata = "di solito servono dai 15 ai 25 minuti"

    var body: some View {
        GroupBox("Foto già salvate sull'SSD") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("L'app tiene un elenco delle foto e dei video che sono già sull'SSD. Serve quando importi da una fotocamera o dal telefono: gli scatti che hai già non vengono ricopiati una seconda volta.")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DiagRow(label: "Elenco",
                        value: runner.indexedFileCount > 0
                            ? "\(runner.indexedFileCount.formatted()) foto e video"
                            : "non ancora creato")

                if runner.isIndexing {
                    HStack(spacing: AppSpacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(progressLine).font(AppFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(LibraryIndexCommands.stop) { runner.cancelIndexing() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }

                HStack(spacing: AppSpacing.sm) {
                    Button(runner.indexedFileCount > 0 ? LibraryIndexCommands.refresh : LibraryIndexCommands.build) {
                        if runner.indexedFileCount > 0 {
                            // Aggiornamento: legge per intero solo le foto nuove o cambiate,
                            // dura poco. Nessuna conferma da chiedere.
                            runner.rebuildLibraryIndex(onAlert: alertSink)
                        } else {
                            confirmFirstBuild()
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(commandsDisabled)

                    Button(LibraryIndexCommands.fullRecheck) { confirmFullRecheck() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(commandsDisabled || runner.indexedFileCount == 0)

                    Spacer()

                    Button(LibraryIndexCommands.reset) { confirmReset() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(AppColor.error)
                        .disabled(commandsDisabled || runner.indexedFileCount == 0)
                }

                // Disattivare **e** dire perche', come `RestoreView` con le fonti non
                // disponibili e come il pannello Doppioni: un bottone grigio senza motivo
                // e' una risposta che l'utente non puo' usare.
                if let reason = commandsDisabledReason, !runner.isIndexing {
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        Image(systemName: icon(.info)).foregroundStyle(color(.info))
                            .font(.system(size: 12))
                        Text(reason).font(AppFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }

                if !runner.isIndexing, let progress = runner.indexProgress {
                    ForEach(LibraryIndexStatus.lines(for: progress,
                                                     interruptedByUser: runner.indexInterruptedByUser)) { line in
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: icon(line.tone))
                                .foregroundStyle(color(line.tone))
                                .font(.system(size: 12))
                            Text(line.text).font(AppFont.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }

                Divider()

                // Unico ingresso al pannello Doppioni (roadmap #31, Task 6): niente voce
                // nell'hamburger, nemmeno disattivata (deciso il 2026-08-28). Il pannello
                // richiede l'elenco, quindi vive accanto a dove l'elenco si crea e si
                // racconta — se non e' mai stato costruito, la finestra stessa lo dice e
                // rimanda qui, invece di offrire una lista vuota.
                Button("Vedi le copie doppie…") { openWindow(id: "duplicates") }
                    .buttonStyle(.bordered).controlSize(.small)
            }.padding(4)
        }
    }

    private var progressLine: String {
        let p = runner.indexProgress ?? LibraryIndexer.Progress()
        return "Lettura in corso — \(p.scanned.formatted()) file guardati, \(p.hashed.formatted()) nuovi o cambiati, \(p.skipped.formatted()) già noti"
    }

    private func icon(_ tone: LibraryIndexStatus.Tone) -> String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ tone: LibraryIndexStatus.Tone) -> Color {
        switch tone {
        case .ok: return AppColor.success
        case .info: return .secondary
        case .warning: return AppColor.warning
        }
    }

    /// La prima creazione legge per intero ogni foto e ogni video dell'SSD: si dice quanto
    /// dura **prima** di partire, e si dice che si puo' fermare.
    private func confirmFirstBuild() {
        pendingAlert = SimpleAlert(
            title: "Creare l'elenco delle foto già salvate?",
            message: "L'app legge una volta sola tutte le foto e tutti i video che sono sull'SSD, per riconoscerli alle importazioni successive: \(durata), a seconda di quanti ne hai.\n\nPuoi fermarti quando vuoi con «\(LibraryIndexCommands.stop)»: la parte già fatta resta salvata e la volta dopo si riprende da lì.\n\nL'SSD viene solo letto: niente viene spostato, modificato o cancellato.",
            confirmTitle: "Crea l'elenco",
            cancelTitle: "Annulla",
            onConfirm: { runner.rebuildLibraryIndex(onAlert: alertSink) })
    }

    private func confirmFullRecheck() {
        pendingAlert = SimpleAlert(
            title: "Controllare tutte le foto da capo?",
            message: "L'app rilegge dall'inizio ogni foto e ogni video sull'SSD, anche quelli che ha già visto: \(durata).\n\nServe dopo che hai spostato o riorganizzato le cartelle sull'SSD, per rimettere in pari l'elenco.\n\nPuoi fermarti quando vuoi. L'SSD viene solo letto: nessuna foto viene toccata.",
            confirmTitle: "Controlla da capo",
            cancelTitle: "Annulla",
            onConfirm: { runner.rebuildLibraryIndex(full: true, onAlert: alertSink) })
    }

    /// L'unica via d'uscita quando restano nell'elenco foto che sull'SSD non ci sono piu'
    /// e nessun controllo riesce a toglierle (ADR-0002). Deve essere raggiungibile, e deve
    /// essere impossibile premerlo credendo di cancellare le foto.
    private func confirmReset() {
        pendingAlert = SimpleAlert(
            title: "Svuotare l'elenco delle foto già salvate?",
            message: "Viene cancellato solo l'elenco che l'app tiene sul Mac. Le tue foto e i tuoi video sull'SSD non vengono toccati: non ne viene cancellato nemmeno uno.\n\nDopo, l'elenco va rifatto da zero (\(durata)) e finché non lo rifai un'importazione può ricopiare foto che hai già.",
            isDestructive: true,
            confirmTitle: "Svuota l'elenco",
            cancelTitle: "Annulla",
            onConfirm: { runner.resetLibraryIndex(onAlert: alertSink) })
    }
}

struct DiagRow: View {
    let label: String; let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Pannello Doppioni (roadmap #31, Task 6)

/// Piccola scatola di riferimento con lock: l'interruzione arriva da un bottone sul thread
/// principale, la lettura arriva dal thread in background che sta eseguendo
/// `DuplicateTrasher.run`. Stesso schema gia' in uso in `LibraryIndexer.cancelled`, qui come
/// tipo a parte perche' `DuplicatesView` e' una `struct` e non puo' tenere un lock su una sua
/// proprieta' di valore.
private final class CancelFlag {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    var isCancelled: Bool { lock.withLock { flag } }
}

/// La finestra "Doppioni": elenca i gruppi di copie byte-identiche gia' presenti sull'SSD,
/// propone e spiega quale copia tenere, e — dopo che l'utente ha spuntato i gruppi, letto un
/// riepilogo dettagliato e confermato con un alert distruttivo — sposta le copie in eccesso
/// nel Cestino del volume, in modo annullabile.
///
/// **NON coperto da test** (Step 7 del Task 6, stessa dichiarazione gia' fatta per la card di
/// #31): questa view, i due sheet/alert di conferma, il gate Touch ID, l'apertura della
/// finestra, e il caricamento/rendering delle miniature. Sono SwiftUI e bookmark veri, non
/// raggiungibili senza una corsa reale. **E' testato tutto cio' che sta ai due capi del
/// cablaggio**: `DuplicatesStatus` (le righe di stato pure) e `DuplicateThumbnailCache` (la
/// cache), in `DuplicatesStatusTests.swift` — piu' tutta la logica dei Task 1-5 che questa
/// view si limita a orchestrare (`LibraryIndexStore.duplicateGroups()`,
/// `duplicateKeepChoice`/`duplicateKeepExplanation`, `DuplicateBatch`, `DuplicateTrasher`,
/// `TrashManifestStore`), gia' coperta nei rispettivi file di test.
struct DuplicatesView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    @EnvironmentObject private var runner: BackupRunner
    @StateObject private var volumes = VolumeMonitor()

    private enum LoadState {
        case idle, loading, loaded([DuplicateGroup]), failed(String)
    }

    @State private var loadState: LoadState = .idle
    @State private var selectedHashes: Set<String> = []

    /// Avvisi **locali della view**, mai `runner.pendingAlert`: quello ha un solo
    /// presentatore, il `.alert` di `ContentView` nella scena `main` (sezione `AlertSink` in
    /// `.claude/rules/architecture.md`). Un secondo presentatore mostrerebbe lo stesso avviso
    /// due volte con entrambe le finestre aperte.
    @State private var pendingAlert: SimpleAlert? = nil

    @State private var showSummarySheet = false
    /// Il blocco congelato nell'istante in cui l'utente ha spuntato i gruppi e ha premuto
    /// "Sposta nel Cestino…": la STESSA istanza alimenta sia il riepilogo sia — se confermato
    /// — il `DuplicateTrasher`, e non si ricalcola mai in mezzo. E' il vincolo nato dall'audit
    /// del Task 2 e ripreso nel Task 4: fra il riepilogo e il cestinamento la scelta di quale
    /// copia tenere non deve poter cambiare sotto i piedi dell'utente.
    @State private var pendingBatch: DuplicateBatch? = nil
    @State private var showDestructiveConfirm = false

    @State private var isTrashing = false
    @State private var trashProgress: (done: Int, total: Int)? = nil
    @State private var activeCancelFlag: CancelFlag? = nil
    @State private var lastOutcome: DuplicateTrashOutcome? = nil

    @State private var thumbnailCache = DuplicateThumbnailCache()

    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Doppioni").font(AppFont.title)

            headerLine

            if let reason = trashDisabledReasonNow {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }

            listArea

            if isTrashing, let progress = trashProgress {
                trashProgressBar(progress)
            }

            if let lastOutcome {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(DuplicatesStatus.outcomeLines(lastOutcome)) { line in
                        Text(line.text).font(AppFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                // `isTrashing` nella condizione non e' ridondante, ed e' il rilievo di
                // review del 2026-09-01: `lastBatch()` e' l'ultimo blocco **registrato**,
                // e durante una corsa quello e' il blocco ancora in esecuzione. Senza
                // questa guardia l'utente che preme qui a meta' corsa non annulla il blocco
                // precedente, come crede: rimette a posto i gruppi gia' smaltiti di quello
                // che sta guardando avanzare, mentre il trasher prosegue sui restanti.
                // Nessun file si corrompe (le guardie di `restore()` reggono), ma salta il
                // modello "blocco atomico" su cui e' costruita tutta la doppia conferma.
                Button("Annulla l'ultimo spostamento") { undoLastBatch() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!hasRestorableBatch || isTrashing)

                Spacer()

                Button("Sposta nel Cestino…") { beginConfirmation() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!canRequestTrash)
            }
        }
        .padding(AppSpacing.lg)
        .frame(minWidth: 640, minHeight: 520)
        .task { if case .idle = loadState { loadGroups() } }
        .sheet(isPresented: $showSummarySheet) {
            if let batch = pendingBatch { summarySheet(batch) }
        }
        .alert("Spostare queste copie nel Cestino?",
               isPresented: $showDestructiveConfirm,
               presenting: pendingBatch) { batch in
            Button("Sposta nel Cestino", role: .destructive) { startTrashing(batch) }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text("Ogni copia viene riverificata sul disco un'ultima volta prima di essere "
                + "spostata. Puoi annullare lo spostamento dopo, con «Annulla l'ultimo "
                + "spostamento».")
        }
        .alert(pendingAlert?.title ?? "", isPresented: Binding(
            get: { pendingAlert != nil },
            set: { if !$0 { pendingAlert = nil } }
        ), presenting: pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }

    // MARK: - Intestazione e stato

    private var headerLine: some View {
        let indexBuilt = runner.indexedFileCount > 0
        let (groupCount, reclaimableBytes): (Int, Int64) = {
            guard case .loaded(let groups) = loadState else { return (0, 0) }
            let batch = DuplicateBatch(groups: groups)
            return (batch.groups.count, batch.reclaimableBytes)
        }()
        return Text(DuplicatesStatus.headerLine(indexBuilt: indexBuilt,
                                                groupCount: groupCount,
                                                reclaimableBytes: reclaimableBytes).text)
            .font(AppFont.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var trashDisabledReasonNow: String? {
        DuplicatesStatus.trashDisabledReason(isRunning: runner.isRunning,
                                             isIndexing: runner.isIndexing,
                                             ssdMounted: volumes.ssdMounted)
    }

    private var canRequestTrash: Bool {
        trashDisabledReasonNow == nil && !selectedHashes.isEmpty && !isTrashing
    }

    private var hasRestorableBatch: Bool {
        !(runner.trashManifestStore?.lastBatch() ?? []).isEmpty
    }

    @ViewBuilder
    private var listArea: some View {
        switch loadState {
        case .idle:
            Color.clear
        case .loading:
            ProgressView("Sto leggendo l'elenco…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message).foregroundStyle(AppColor.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(let groups):
            let batch = DuplicateBatch(groups: groups)
            if batch.groups.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(batch.groups, id: \.group.hash) { entry in
                            DuplicateGroupRow(entry: entry,
                                              isSelected: selectedHashes.contains(entry.group.hash),
                                              libraryRootPath: BookmarkManager.shared.urls[.ssd]?.path,
                                              cache: thumbnailCache) {
                                toggleSelection(entry.group.hash)
                            }
                        }
                    }
                }
            }
        }
    }

    private func trashProgressBar(_ progress: (done: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            HStack {
                Text("Sposto le copie nel Cestino: \(progress.done) di \(progress.total) gruppi")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Interrompi") { activeCancelFlag?.cancel() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    // MARK: - Riepilogo (prima conferma)

    private func summarySheet(_ batch: DuplicateBatch) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Riepilogo dello spostamento").font(AppFont.title)

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(Array(batch.summaryLines().enumerated()), id: \.offset) { _, line in
                        Text(line).font(AppFont.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let capReason = DuplicatesStatus.confirmationBlockedReason(exceedsCap: batch.exceedsCap) {
                Text(capReason).font(AppFont.caption).foregroundStyle(AppColor.warning)
            }

            HStack {
                Spacer()
                Button("Annulla") { showSummarySheet = false }.buttonStyle(.bordered)
                Button("Continua…") {
                    showSummarySheet = false
                    showDestructiveConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(batch.exceedsCap || trashDisabledReasonNow != nil)
            }
        }
        .padding(AppSpacing.xl)
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Azioni

    private func toggleSelection(_ hash: String) {
        if selectedHashes.contains(hash) { selectedHashes.remove(hash) } else { selectedHashes.insert(hash) }
    }

    /// Carica i gruppi **fuori dal main thread**: `duplicateGroups()` passa dalla coda
    /// seriale dello store, occupata dalle scritture a batch dello scanner, e sul main
    /// thread bloccherebbe la finestra a ogni ridisegno (stessa regola gia' applicata a
    /// `BackupRunner.indexedFileCount`).
    private func loadGroups() {
        guard let store = runner.libraryIndexStore else {
            loadState = .failed("Non è stato possibile aprire l'elenco delle foto già salvate.")
            return
        }
        loadState = .loading
        Task.detached(priority: .utility) {
            do {
                let groups = try store.duplicateGroups()
                await MainActor.run { loadState = .loaded(groups) }
            } catch {
                await MainActor.run {
                    loadState = .failed("Non è stato possibile leggere l'elenco delle copie doppie: "
                        + error.localizedDescription)
                }
            }
        }
    }

    /// Congela il blocco selezionato e apre il riepilogo — la prima delle due conferme
    /// (decisione 4 di Enrico). Il blocco non viene piu' ricalcolato da qui in avanti: la
    /// stessa istanza arriva fino a `startTrashing(_:)`.
    private func beginConfirmation() {
        guard case .loaded(let groups) = loadState else { return }
        let selected = groups.filter { selectedHashes.contains($0.hash) }
        guard !selected.isEmpty else { return }
        pendingBatch = DuplicateBatch(groups: selected)
        showSummarySheet = true
    }

    /// La conferma vera: smaltisce il blocco congelato. Gira fuori dal main thread — la
    /// rilettura/rihash di ogni membro puo' richiedere minuti su un SSD USB (spec: 50 GB
    /// sono grosso modo 2-4 minuti) e bloccherebbe la finestra per tutta la durata.
    private func startTrashing(_ batch: DuplicateBatch) {
        // Precondizioni del blocco (item 1 della sequenza in spec: nessun job in corso,
        // nessuna scansione dell'indice in corso, SSD montato), **rivalutate qui**.
        // Rilievo di review del 2026-09-01: valutarle solo all'apertura del riepilogo non
        // basta. Il riepilogo e' fatto per essere letto con calma — e' li' che sta tutto il
        // peso della conferma — e nel frattempo puo' partire un backup automatico al
        // ricollegamento dell'SSD, o l'aggancio automatico dell'indice a fine di un altro
        // job. Cestinare mentre un mirror legge gli stessi file e' esattamente il modo,
        // descritto dalla spec, di trasformare due operazioni corrette in un guasto.
        // Lo `st_dev` del trasher non copre questo caso: intercetta lo scollegamento, non
        // un secondo lettore sul volume ancora montato.
        if let reason = trashDisabledReasonNow {
            pendingAlert = SimpleAlert(title: "Meglio non farlo adesso", message: reason)
            return
        }

        guard let store = runner.libraryIndexStore,
              let manifest = runner.trashManifestStore,
              let root = BookmarkManager.shared.urls[.ssd] else {
            pendingAlert = SimpleAlert(
                title: "Non è stato possibile procedere",
                message: "L'elenco delle foto, il registro di ripristino o l'SSD non sono "
                    + "disponibili in questo momento. Riprova dopo aver ricontrollato "
                    + "Diagnostica.")
            return
        }

        let decisions = batch.groups.map { DuplicateTrasher.Decision(group: $0.group, keeper: $0.choice.keeper) }
        let trasher = DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest)
        let cancelFlag = CancelFlag()
        activeCancelFlag = cancelFlag

        isTrashing = true
        lastOutcome = nil
        trashProgress = (0, decisions.count)

        Task.detached(priority: .utility) {
            let outcome = trasher.run(decisions, onProgress: { done, total in
                Task { @MainActor in trashProgress = (done, total) }
            }, isCancelled: { cancelFlag.isCancelled })

            await MainActor.run {
                isTrashing = false
                trashProgress = nil
                activeCancelFlag = nil
                lastOutcome = outcome
                selectedHashes.removeAll()
                pendingBatch = nil
                // Le chiavi dei file davvero cestinati sono gia' state rimosse dallo store
                // dentro `run(...)`: si ricarica l'elenco per riflettere i gruppi rimasti.
                loadGroups()
            }
        }
    }

    /// «Annulla l'ultimo spostamento»: rimette a posto l'ultimo blocco registrato, se ce n'e'
    /// uno ripristinabile. `TrashManifestStore.restore` non lancia mai: ogni voce che non si
    /// puo' ripristinare finisce fra gli `skipped`, le altre proseguono comunque.
    private func undoLastBatch() {
        guard let manifest = runner.trashManifestStore else { return }
        let items = manifest.lastBatch()
        guard !items.isEmpty else { return }
        let outcome = manifest.restore(items)
        let restoredCount = outcome.restored.count
        let skippedCount = outcome.skipped.count
        pendingAlert = SimpleAlert(
            title: "Spostamento annullato",
            message: skippedCount == 0
                ? "\(restoredCount.formatted()) file sono tornati al loro posto."
                : "\(restoredCount.formatted()) file sono tornati al loro posto. "
                    + "\(skippedCount.formatted()) non sono stati ripristinati: guarda il "
                    + "Cestino del volume per recuperarli a mano.")
        // Il ripristino non reinserisce le entry a mano nell'elenco: la prossima lettura le
        // rivedra' come file nuovi e le rihashera' da sola (stessa regola di ADR-0005).
        loadGroups()
    }
}

/// Una riga della lista: checkbox, miniatura del file tenuto, spiegazione della scelta, e le
/// copie che se ne andrebbero — con quelle a pari merito con la tenuta marcate visivamente
/// (`DuplicateKeepChoice.tiedPaths`), cosi' la frase di `duplicateKeepExplanation` non deve
/// indovinare a quale riga si riferisce.
private struct DuplicateGroupRow: View {
    let entry: DuplicateBatch.Entry
    let isSelected: Bool
    let libraryRootPath: String?
    let cache: DuplicateThumbnailCache
    let toggle: () -> Void

    @State private var thumbnail: NSImage?
    /// Token di richiesta: scarta una miniatura arrivata su una riga gia' superata, stesso
    /// meccanismo di `BackupRunner.thumbnailRequestID`. Serve perche' la lettura gira in un
    /// `Task.detached`, che non eredita la cancellazione automatica del `.task` della view.
    @State private var loadToken = UUID()

    private var keeperURL: URL? {
        guard let libraryRootPath else { return nil }
        return URL(fileURLWithPath: libraryRootPath).appendingPathComponent(entry.choice.keeper.displayPath)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            }.buttonStyle(.plain)

            thumbnailView

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(entry.choice.keeper.displayPath).font(AppFont.body)
                    .lineLimit(1).truncationMode(.middle)

                Text(duplicateKeepExplanation(entry.choice, in: entry.group))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(entry.leaving, id: \.path) { leaving in
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(leaving.displayPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if entry.choice.tiedPaths.contains(leaving.path) {
                            Text("· pari merito con la tenuta")
                                .font(.caption2).italic().foregroundStyle(AppColor.warning)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(AppSpacing.sm)
        .cardBackground()
        .task(id: entry.group.hash) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: isVideo ? "video.fill" : "photo")
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
        }
    }

    private var isVideo: Bool {
        IndexableKind.of(url: keeperURL ?? URL(fileURLWithPath: entry.choice.keeper.displayPath)) == .video
    }

    /// Miniatura pigra: `makeThumbnail` esistente, mai una seconda implementazione, mai
    /// l'immagine intera. Video: solo l'icona di sistema, nessun fotogramma (deciso il
    /// 2026-08-28) — i membri di un gruppo sono byte-identici per definizione, quindi la
    /// miniatura non serve a distinguerli fra loro.
    private func loadThumbnail() async {
        guard let url = keeperURL else { return }
        let key = entry.group.hash
        if let cached = cache.image(for: key) {
            thumbnail = cached
            return
        }
        guard IndexableKind.of(url: url) == .image else { return }
        let token = UUID()
        loadToken = token
        let image = await Task.detached(priority: .utility) {
            makeThumbnail(url: url, maxPixelSize: 96)
        }.value
        // Scartata se questa riga e' stata riusata per un altro gruppo nel frattempo
        // (scroll di una `LazyVStack`).
        guard loadToken == token else { return }
        if let image { cache.insert(image, for: key) }
        thumbnail = image
    }
}
