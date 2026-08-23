import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
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
    var changedSkipped: Int = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
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

enum FileKind {
    static func isImage(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

func sha256(of url: URL) -> String? {
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

    var hasher = SHA256()
    let bufSize = 65536
    var buffer = [UInt8](repeating: 0, count: bufSize)

    while true {
        let n = buffer.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress, bufSize)
        }
        if n < 0 { return nil }
        if n == 0 { break }
        buffer.withUnsafeBufferPointer { ptr in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: ptr.baseAddress, count: n))
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

// MARK: - FileSyncer
final class FileSyncer {
    struct SyncResult {
        var total = 0; var done = 0; var copied = 0; var skipped = 0; var errors = 0
        var hashErrors = 0   // file con SHA256 mismatch dopo la copia
        var changedSkipped = 0   // file esistente ma diverso dalla sorgente, skippato per zero-overwrite (roadmap #13)
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
    private let excluded: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb"
    ]

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

    func sync(from src: URL, to dst: URL, deep: Bool,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
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
                                     onCurrentFile: onCurrentFile)
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
                         onCurrentFile: @escaping (URL) -> Void) throws {
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
                            onCurrentFile: onCurrentFile)
            } else if vals?.isRegularFile == true {
                syncFile(src: item, dst: destItem, deep: deep,
                         result: &result, onStatus: onStatus, onProgress: onProgress,
                         onCurrentFile: onCurrentFile)
            }
        }
    }

    private func syncFile(src: URL, dst: URL, deep: Bool,
                          result: inout SyncResult,
                          onStatus: @escaping (String) -> Void,
                          onProgress: @escaping (SyncResult) -> Void,
                          onCurrentFile: @escaping (URL) -> Void) {
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
                    if let srcHash = sha256(of: src), let dstHash = sha256(of: dst), srcHash != dstHash {
                        result.hashErrors += 1   // mismatch SHA256: conteggiato separato da errori I/O
                        let name = src.lastPathComponent
                        DispatchQueue.main.async { onStatus("⚠️ HASH MISMATCH: \(name) — copia non integra, controlla il log") }
                    } else {
                        result.copied += 1
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
        let n = url.lastPathComponent
        return excluded.contains(n) || n.hasPrefix("._")
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
    private var syncTask: Task<Void, Never>?
    private var wasStopped = false
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
            self.run(label: "MAC -> SSD") { [weak self] in
                self?.publishStatus("Foto: \(photosURL.path)  →  SSD: \(dst.path)")
                defer { self?.bm.stopAccessing(.photos); self?.bm.stopAccessing(.ssd) }
                return try await self?.syncer.sync(from: photosURL, to: dst, deep: false,
                    onStatus: { self?.publishStatus($0) },
                    onProgress: { self?.publishProgress($0) },
                    onCurrentFile: { self?.publishCurrentFile($0) })
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
                    onCurrentFile: { self?.publishCurrentFile($0) })
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
            succeeded: false, changedSkipped: stats.changedSkipped))
    }

    private func run(label: String, work: @escaping () async throws -> FileSyncer.SyncResult?) {
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
                        self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
                    }
                    self.phase = .success("Completato: \(label)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: true,
                        changedSkipped: self.stats.changedSkipped))
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
                        changedSkipped: self.stats.changedSkipped))
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
            self.stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
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
                let thumb = Self.makeThumbnail(url: url, maxPixelSize: 88)
                await MainActor.run {
                    guard let self, self.thumbnailRequestID == requestID else { return }
                    self.currentThumbnail = thumb
                }
            }
        } else {
            currentThumbnail = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: .zero)
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

    var isClean: Bool { succeeded && errors == 0 && hashErrors == 0 }
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

    // realpath (non URL.resolvingSymlinksInPath, che lascia /var e /tmp non risolti di proposito):
    // l'enumeratore restituisce URL con i symlink di sistema risolti (es. /var -> /private/var),
    // quindi per far combaciare il prefisso serve la stessa risoluzione a livello di filesystem.
    private func realResolvedPath(_ url: URL) -> String {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let r = realpath(url.path, &buf) else { return url.path }
        return String(cString: r)
    }

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

        let sample = relPaths.shuffled().prefix(sampleSize)
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
        let excluded: Set<String> = [
            ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
            ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb"
        ]
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
            if excluded.contains(name) || name.hasPrefix("._") { continue }
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
            guard let localHash = sha256(of: localFile) else { result.skippedNoSource += 1; continue }
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
            if mounted && autoBackupEnabled && !runner.isRunning {
                runner.runMacToSSD()
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
            if stats.changedSkipped > 0 {
                Label("\(stats.changedSkipped) file locali cambiati, non copiati (regola zero-overwrite)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(AppColor.warning).multilineTextAlignment(.center)
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
                                        pendingAlert = SimpleAlert(title: "Credenziali aggiornate nel Keychain.")
                                    } catch {
                                        pendingAlert = SimpleAlert(title: "Errore", message: error.localizedDescription)
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
