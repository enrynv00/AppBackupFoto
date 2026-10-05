import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import SQLite3
import CryptoKit
import Charts
import ImageIO
import AVFoundation
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
            startingUpdater: appTouchesUserStateAtLaunch(),
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
        // (il gate vero è dentro ToolsSheet).
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

        Window("Inventario", id: "inventory") {
            InventoryView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 680)
        // Stessa regola di #30: ogni Window scene di primo livello va gated (il gate vero e'
        // dentro InventoryView: elenca percorsi e nomi di tutte le foto) e non deve essere
        // riaperta dal ripristino automatico di macOS prima dello sblocco.
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
            .onChange(of: runner.displayPercent) { _, _ in updateDockBadge() }
            .onChange(of: runner.isRunning) { _, _ in updateDockBadge() }
    }

    private func updateDockBadge() {
        // Durante il passo 2 del backup scende da 100% a pochi punti: accettato (D5 della
        // spec), e' lo stesso numero della barra della finestra, che intanto dice "passo 2
        // di 2".
        NSApp.dockTile.badgeLabel = runner.isRunning ? "\(runner.displayPercent)%" : nil
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

// MARK: - Immich (finestra "Foto")

/// Finestra "Foto": la web UI di Immich incorporata, con il ciclo di vita dello stack
/// gestito da `ImmichManager`.
///
/// Gate Touch ID anche qui, come per `ToolsSheet`: è una scena di primo
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
    ///
    /// **Perche' NON stanno sotto Application Support come tutto il resto** (corretto il
    /// 2026-09-03, dopo averlo visto fallire davvero): Lima crea un socket UNIX dentro
    /// `LIMA_HOME`, e un socket UNIX non puo' superare **104 caratteri** di percorso
    /// (`UNIX_PATH_MAX`). Con il percorso precedente
    /// — `~/Library/Application Support/AppBackupFoto/immich/lima-home/colima/ssh.sock.<16 cifre>` —
    /// si arrivava a **117 caratteri**, e `colima start` moriva subito con
    /// «instance name too long ... must be less than UNIX_PATH_MAX=104». **Sempre.** La
    /// feature non poteva funzionare, e non se n'era accorto nessuno perche' non era mai
    /// stata eseguita davvero.
    ///
    /// Non e' un capriccio di Lima: e' il motivo per cui Lima e Colima usano di default
    /// `~/.lima` e `~/.colima`, cioe' percorsi corti. Lo scopo del percorso privato era
    /// **isolare** lo stato da quello personale di Enrico, non stare per forza dentro
    /// Application Support: una cartella nascosta dedicata ottiene l'isolamento e sta nel
    /// limite. Con questo percorso il socket misura 77 caratteri, 27 di margine.
    ///
    /// `binDir` resta invece sotto Application Support: i binari non creano socket.
    var privateVMHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".appbackupfoto-vm", isDirectory: true)
    }
    var limaHomeDir: URL { privateVMHome.appendingPathComponent("lima", isDirectory: true) }
    var colimaHomeDir: URL { privateVMHome.appendingPathComponent("colima", isDirectory: true) }

    /// Il percorso del socket che Lima creera', e se ci sta nel limite del sistema.
    ///
    /// Pura e testabile apposta: e' l'unico modo di impedire che questo difetto torni in
    /// silenzio. Un nome utente molto lungo puo' ancora far sforare il limite — e' un caso
    /// che qui non si verifica ma che non e' impossibile su un altro Mac, ed e' meglio un
    /// messaggio che lo dice di un errore di Lima che nessuno sa interpretare.
    static func vmSocketPathFits(limaHome: String, instance: String = "colima") -> Bool {
        socketPathLength(limaHome: limaHome, instance: instance) <= 104
    }

    static func socketPathLength(limaHome: String, instance: String = "colima") -> Int {
        // Forma reale del socket creato da Lima: `<LIMA_HOME>/<istanza>/ssh.sock.<16 cifre>`.
        "\(limaHome)/\(instance)/ssh.sock.1234567890123456".count
    }

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
// `nonisolated`: handler di `Pipe` su thread arbitrari (non il main). Aveva gia' `NSLock` e
// `@unchecked Sendable`, mancava solo l'annotazione.
private nonisolated final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

/// Garantisce che una `CheckedContinuation` venga ripresa una volta sola: qui ci arrivano
/// sia la terminazione del processo sia il timeout, e riprenderla due volte è un crash.
// `nonisolated`: handler di `Process` su thread arbitrari, stessa ragione di sopra.
private nonisolated final class ContinuationGuard: @unchecked Sendable {
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
        case vmPathTooLong(length: Int)

        var errorDescription: String? {
            switch self {
            case .vmPathTooLong(let length):
                return """
                Non è possibile avviare il motore delle foto su questo Mac: il percorso interno che
                deve usare è troppo lungo (\(length) caratteri, il massimo di sistema è 104).
                Di solito dipende da un nome utente molto lungo.
                Non è un problema delle tue foto e non è stato modificato niente.
                """
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
            // Prima di scaricare immagini e avviare VM: se il socket non ci sta nel limite,
            // `colima start` fallirebbe comunque, ma con un errore di Lima incomprensibile.
            guard Self.vmSocketPathFits(limaHome: limaHomeDir.path) else {
                throw Failure.vmPathTooLong(
                    length: Self.socketPathLength(limaHome: limaHomeDir.path))
            }
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
    /// Esito del passo 2 del backup (2026-09-19), `nil` = nessun passo 2 per questo job.
    /// NON persistito (`JobStats` non e' `Codable`) e nessun conteggio lo legge: i numeri
    /// del passo 1 sopra restano quelli della copia, invariati. Serve solo a CompletionSheet
    /// e alla notifica di fine job.
    var listStepOutcome: BackupListStep.Outcome? = nil
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

    // Un'etichetta uguale a un nome escluso (`_quarantena`, `lost+found`, ...) farebbe
    // atterrare l'importazione in una cartella che backup, elenco e inventario saltano: le
    // foto resterebbero sull'SSD senza mai arrivare su HDD e Cubbit (ROADMAP #45).
    if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) || LibraryExclusions.isExcludedName(cleaned) {
        return "Import"
    }
    return cleaned
}

/// Motivo scritto (non un bottone semplicemente grigio) quando il wizard di import non può
/// partire perché un'altra copia è già in corso — un backup avviato a mano, uno scattato da
/// solo al collegamento dell'SSD, o un'importazione precedente. `nil` quando si può procedere.
///
/// Stessa lezione pagata due volte il 2026-09-01 su `LibraryIndexCommandGate` (i bottoni della
/// card «Foto già salvate sull'SSD») e sul pannello Doppioni: fra la scelta dell'etichetta e il
/// click su "Avvia importazione" possono passare minuti, e in quel tempo un job può partire senza
/// che l'utente lo sappia. Una guardia valutata solo quando il bottone viene disegnato non basta:
/// va rivalutata anche dentro `BackupRunner.runImport`, al momento dell'avvio vero — altrimenti
/// l'unica reazione a una corsa persa sarebbe il `guard !isRunning` silenzioso di
/// `BackupRunner.run(label:...)`, che chiude lo sheet senza copiare nulla e senza dirlo.
/// Un'unica sorgente per il testo: usata sia per il messaggio sotto il bottone sia per
/// l'alert se la corsa scatta comunque fra il click e l'avvio.
func importStartDisabledReason(jobIsRunning: Bool) -> String? {
    guard jobIsRunning else { return nil }
    // La parentesi elenca le cause **vere**, e la prima e' quella che il testo precedente
    // non nominava: un backup avviato a mano da Enrico dalla finestra principale (rilievo di
    // review del 2026-09-01). Dire "un backup automatico" a chi ha appena premuto lui stesso
    // "SSD -> HDD" e' una spiegazione che non corrisponde a quello che sta vedendo, ed e'
    // peggio di nessuna spiegazione: lo manda a cercare un automatismo che non c'entra.
    return "C'è già una copia in corso: un backup che hai avviato tu, uno partito da solo al "
        + "collegamento dell'SSD, oppure un'importazione precedente non ancora finita. "
        + "Aspetta che finisca, poi riprova."
}

/// Le righe che il wizard di import mostra nel passo `.preview` (roadmap #27-A, Task 3 del
/// piano `2026-09-01-import-preview-dedup.md`). Logica **pura**: nessun filesystem, nessun
/// database, nessuna View — stesso ruolo di `LibraryIndexStatus.lines` e di `DuplicatesStatus`.
/// **Nessuna stringa duplicata fra questo enum e `ImportView`**: se una riga esiste, esiste
/// qui, è la sola fonte.
enum ImportPreviewStatus {
    enum Tone: Equatable { case ok, info, warning }

    struct Line: Identifiable {
        /// Identità stabile e non un UUID: le righe si ricalcolano a ogni ridisegno, e con
        /// un UUID SwiftUI le vedrebbe tutte nuove ogni volta.
        let id: String
        let tone: Tone
        let text: String
    }

    /// Perché l'anteprima non può nemmeno partire. `nil` quando può. I due motivi sono
    /// DISTINTI apposta: "non configurato" e "non collegato" chiedono all'utente due azioni
    /// diverse (aprire le Impostazioni vs collegare fisicamente il volume), e confonderle
    /// manda a cercare il rimedio sbagliato.
    static func unavailableReason(ssdConfigured: Bool, ssdMounted: Bool) -> String? {
        guard ssdConfigured else {
            return "Non hai ancora scelto l'SSD di destinazione: aprilo nelle Impostazioni prima "
                + "di poter vedere quali foto verranno davvero importate."
        }
        guard ssdMounted else {
            return "L'SSD non è collegato in questo momento: collegalo per vedere quali foto "
                + "verranno davvero importate."
        }
        return nil
    }

    /// Le righe del passo `.preview`. `toAdd`/`toSkipDuplicates` sono conteggi già dedotti dal
    /// motore dell'anteprima (`BackupRunner.importPreviewDuplicates`), `toAddBytes` e
    /// `estimatedSec` vengono da `FileSyncer.previewSync`.
    ///
    /// Quattro diramazioni, non due: "sorgente vuota" (nessun file trovato) e "tutto già
    /// presente sull'SSD" (reimport) sono situazioni OPPOSTE — la prima dice "non ho guardato
    /// niente di utile", la seconda "ho guardato e non c'è niente di nuovo" — e vanno tenute
    /// distinte per la stessa ragione per cui `sawNothing` in #31 non si legge come "libreria
    /// vuota" quando in realtà la lettura non e' arrivata in fondo.
    ///
    /// - Parameter interrupted: l'utente ha premuto "Interrompi" (Task 4, requisito 3 della
    ///   condizione di Enrico: "interrompi" ferma davvero la lettura e degrada al conteggio
    ///   grezzo, MAI a uno schermo vuoto — spec, «Risposte di Enrico», risposta 4). Richiesto e
    ///   non con default, come `LibraryIndexStatus.lines(for:interruptedByUser:)`: `toAdd`/
    ///   `toSkipDuplicates` da soli non possono saperlo, e un default silenzierebbe una
    ///   dimenticanza invece di farla fallire in compilazione. Quando `true`:
    ///   - la diramazione "sorgente vuota" non scatta MAI, anche con `toAdd`/`toSkipDuplicates`
    ///     entrambi a zero: quella riga e' un'affermazione confidente ("non c'e' niente qui")
    ///     che un controllo troncato non ha il diritto di fare — potrebbe semplicemente non
    ///     essere arrivato abbastanza lontano da trovare qualcosa;
    ///   - la diramazione "le hai già tutte" (`toAdd == 0`, buona notizia confidente sul
    ///     reimport COMPLETO) non scatta nemmeno lei, per lo stesso motivo;
    ///   - viene sempre aggiunta una riga dedicata che dice la verita': il controllo si e'
    ///     fermato prima della fine, e il numero sopra potrebbe contare foto gia' sull'SSD che
    ///     l'importazione vera salterebbe comunque (verso non-sicuro dichiarato, mai nascosto).
    /// Come e' finito il controllo. **Non e' un booleano**, ed e' il rilievo di review del
    /// 2026-09-01: le due interruzioni possibili sbagliano il numero in due direzioni
    /// **opposte**, e una riga sola non puo' dire la verita' su entrambe.
    ///
    /// - `duringCount`: fermato mentre l'app stava ancora **contando** i file della cartella.
    ///   `toAdd` non e' un totale sovrastimato: e' un **frammento**. Su una sorgente da 18.000
    ///   file, fermarsi dopo due secondi puo' dare «47 file nuovi» — che l'utente legge come
    ///   «ecco cosa importero'». Stessa classe di errore di `sawNothing` in #31.
    /// - `duringCheck`: la camminata era finita — `toAdd` e' il totale vero — e si e' fermato
    ///   il controllo su quali fossero gia' sull'SSD. Qui, e **solo** qui, il numero e' una
    ///   sovrastima, e si puo' rassicurare l'utente che l'importazione vera salta comunque i
    ///   doppioni.
    enum PreviewInterruption: Equatable { case none, duringCount, duringCheck }

    static func lines(toAdd: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int,
                      interruption: PreviewInterruption) -> [Line] {
        let interrupted = interruption != .none
        var out: [Line] = []

        if !interrupted && toAdd == 0 && toSkipDuplicates == 0 {
            // Sorgente vuota: nessun file trovato da controllare. Riga isolata, MAI insieme
            // alla riga "già presenti" (che qui non ha nulla da dire, essendo anch'essa zero).
            out.append(Line(id: "empty-source", tone: .warning, text:
                "Non ho trovato nessuna foto da controllare in questa cartella: forse è vuota, "
                + "oppure non contiene foto o video che l'app riconosce."))
            return out
        }

        if toAdd == 0 && toSkipDuplicates > 0 && !interrupted {
            // e' lo scenario del reimport COMPLETO, la ragione stessa per cui esiste questo
            // lavoro. Va detto a parole, mai lasciato leggere come un silenzio o un errore:
            // e' una buona notizia, non un guasto. Solo a controllo arrivato in fondo:
            // interrotto, non si puo' affermare con la stessa sicurezza (vedi sopra).
            out.append(Line(id: "toAdd", tone: .ok, text:
                "Non c'è nessuna foto nuova da importare: le hai già tutte sull'SSD."))
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: toAddBytes, countStyle: .file)
            out.append(Line(id: "toAdd", tone: .info, text:
                "\(count(toAdd, "file nuovo da importare", "file nuovi da importare")), circa "
                + "\(bytes), tempo stimato circa \(FileSyncer.SyncResult.hms(estimatedSec))."))
        }

        if toSkipDuplicates > 0 {
            let already = count(toSkipDuplicates,
                                 "file è già presente sull'SSD: non verrà ricopiato",
                                 "file sono già presenti sull'SSD: non verranno ricopiati")
            out.append(Line(id: "already-present", tone: .info, text: "\(already)."))
        }

        switch interruption {
        case .none:
            break
        case .duringCount:
            out.append(Line(id: "interrupted", tone: .warning, text:
                "Hai fermato il controllo mentre l'app stava ancora contando: quello che vedi "
                + "qui sopra è solo una parte di quello che c'è nella cartella, non il totale. "
                + "Scegli di nuovo la cartella per rifare il conto da capo."))
        case .duringCheck:
            out.append(Line(id: "interrupted", tone: .warning, text:
                "Il controllo è stato interrotto prima della fine: il numero qui sopra potrebbe "
                + "contare foto già presenti sull'SSD, che l'importazione vera salterà comunque."))
        }

        return out
    }

    /// La riga di avanzamento durante il controllo. Deve dire **quanti su quanti**, e nominare
    /// anche il totale della sorgente quando il denominatore (i soli candidati che superano il
    /// prefiltro sulla dimensione) è molto più piccolo: è l'informazione che dice all'utente se
    /// aspetterà 3 secondi o 3 minuti — un terzo della condizione posta da Enrico per accettare
    /// questo lavoro (vedi le «Risposte di Enrico» nella spec).
    ///
    /// - Parameter elapsedSec: il tempo trascorso dall'inizio del controllo, formattato con
    ///   **la stessa** `FileSyncer.SyncResult.hms` usata dai job — non riscritta apposta (Task
    ///   4, secondo requisito della condizione di Enrico: *"ci deve essere timer... per far
    ///   capire che sta procedendo"*). Il trascorso, non lo stimato-rimanente: quest'ultimo
    ///   richiederebbe una seconda copia della formula di ETA gia' presente due volte su
    ///   `SyncResult` (una duplicazione che questo progetto ha gia' pagato piu' volte), mentre
    ///   il trascorso basta da solo a soddisfare la richiesta di Enrico ed e' un dato che questa
    ///   funzione pura puo' calcolare da un solo numero, senza velocita' o medie mobili.
    static func progressLine(done: Int, total: Int, sourceFileCount: Int, elapsedSec: Int) -> String {
        let base = "Controllati \(number(done)) di \(number(total))"
        let elapsed = ", trascorsi \(FileSyncer.SyncResult.hms(elapsedSec))."
        guard sourceFileCount > total else { return base + elapsed }
        return base + ", su \(number(sourceFileCount)) file della sorgente" + elapsed
    }

    private static func number(_ n: Int) -> String { n.formatted() }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(number(n)) \(n == 1 ? singular : plural)"
    }
}

/// File e cartelle di sistema da non trattare come contenuto dell'utente.
///
/// **Chi la usa davvero, oggi**: `FileSyncer` (Mac→SSD e SSD→HDD) e l'indicizzatore
/// della libreria. **Non** la usano `S3Syncer.previewUpload`,
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
// `nonisolated`: classificazione pura per nome file, nessuno stato. Chiamata sia dal
// MainActor sia dalla coda di lavoro di `FileSyncer` e da `LibraryIndexer.scan` (coda di
// background) — senza l'annotazione, il default `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
// la isolerebbe e ogni chiamata da un contesto non isolato sarebbe un warning (un salto sul
// main thread a runtime).
nonisolated enum LibraryExclusions {
    /// La cartella in cui la riparazione (ROADMAP #45, ADR-0016) mette da parte la copia
    /// rovinata che sostituisce, alla radice di SSD, HDD e Cubbit. NON e' contenuto
    /// dell'utente: se rientrasse nel backup, il backup ricaricherebbe su Cubbit (o copierebbe
    /// sull'HDD) proprio la copia rovinata, e i Doppioni la vedrebbero come una copia in piu'.
    /// Il nome vive QUI e in nessun altro posto: anche `RepairPaths` lo legge da qui.
    static let quarantineFolderName = "_quarantena"

    static let names: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        ".fseventsd", ".DocumentRevisions-V100", "lost+found", "Backups.backupdb",
        quarantineFolderName
    ]

    /// Vero per la cartella di quarantena, senza distinguere maiuscole e minuscole: l'SSD e'
    /// exFAT e non le distingue, quindi `_Quarantena` creata a mano e' la stessa cartella in
    /// cui la riparazione scriverebbe. Verificato il 2026-10-04 sull'elenco e sull'inventario
    /// salvati: nessun percorso di SSD, HDD o Cubbit contiene oggi `quarantena`.
    static func isQuarantineName(_ name: String) -> Bool {
        name.compare(quarantineFolderName, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    /// Il confronto su UNA componente di percorso, condiviso da `shouldExclude` (dischi) e da
    /// `InventoryPerimeter` (chiavi di Cubbit): i nomi della lista, i sidecar `._` e la
    /// cartella di quarantena.
    static func isExcludedName(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._") || isQuarantineName(name)
    }

    /// Confronto sull'ultima componente del path, mai sul path intero: una cartella
    /// di passaggio dal nome simile non deve escludere i file che contiene.
    /// `._*` sono i sidecar AppleDouble che macOS crea sui filesystem non-HFS —
    /// l'SSD è ExFAT, quindi ce ne sono ovunque.
    static func shouldExclude(_ url: URL) -> Bool {
        isExcludedName(url.lastPathComponent)
    }

    /// Per i percorsi che non si scorrono con `shouldExclude` (le chiavi di Cubbit nel
    /// campione d'integrita'): vero se UNA componente del percorso relativo e' la cartella di
    /// quarantena.
    static func isInsideQuarantine(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { isQuarantineName(String($0)) }
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
// `FileSyncer` e da `LibraryIndexer.scan` (coda di background, dal 2026-09-19), non solo dal
// MainActor. Senza, il default `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` la isola e ogni
// chiamata da un contesto nonisolated e' un warning (un errore in Swift 6) — e a runtime un
// salto implicito sul main thread (BUG-7, `.claude/rules/bug-history.md`).
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

/// Un fotogramma di un video, da usare come miniatura.
///
/// **Funzione separata da `makeThumbnail` di proposito.** Quella usa ImageIO e serve anche la
/// miniatura del file corrente durante un job di copia (#17): allargarla ai video vi
/// aggiungerebbe una decodifica video dentro il percorso caldo di un backup, che e' gia'
/// vincolato dall'I/O. Qui il costo si paga solo nel pannello Doppioni, una volta per gruppo,
/// fuori dal main thread e con il risultato in cache.
///
/// Riapre una decisione del 2026-08-28 («video: solo icona di sistema, nessun
/// `AVAssetImageGenerator` in questa versione»). Il motivo di allora era che i membri di un
/// gruppo sono byte-identici, quindi la miniatura non serve a **distinguerli fra loro** — vero,
/// e resta vero. Ma Enrico il 2026-09-03 ha chiesto un'altra cosa: vedere **cosa sta per
/// spostare**, e i suoi doppioni piu' grossi sono video da centinaia di MB che mostravano solo
/// un'icona generica. Distinguere le copie fra loro e riconoscere il contenuto sono due
/// bisogni diversi; il secondo non era coperto.
///
/// Due accorgimenti che contano su un SSD esterno via USB:
/// - **tolleranze di ricerca ampie**: senza, `AVAssetImageGenerator` decodifica fino al
///   fotogramma esatto; con 2 secondi di tolleranza prende il keyframe piu' vicino, che su un
///   file da 600 MB e' un'altra cosa in termini di tempo.
/// - **non il fotogramma 0**: l'inizio di un video e' spesso nero o sfocato. Si prende a 1s,
///   o a meta' per i video piu' corti di 2 secondi.
/// Misurato il 2026-09-03 su un video da 100+ MB dell'SSD reale: **0,14 s**, fotogramma
/// 90x160 con l'orientamento verticale corretto. Le API usate sono quelle **asincrone**
/// (`load(.duration)`, `image(at:)`): le equivalenti sincrone sono deprecate da macOS 13 e 15,
/// e questo progetto ha come target macOS 26.
nonisolated func makeVideoThumbnail(url: URL, maxPixelSize: Int) async -> NSImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    // Tolleranze ampie: senza, si decodifica fino al fotogramma esatto. Con 2 secondi si
    // prende il keyframe piu' vicino — su un file da 600 MB via USB e' un'altra cosa.
    generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

    // Mai il fotogramma 0: l'inizio di un video e' spesso nero o sfocato.
    let seconds: Double
    if let duration = try? await asset.load(.duration) {
        let d = CMTimeGetSeconds(duration)
        seconds = d.isFinite && d > 2 ? 1.0 : max(d / 2, 0)
    } else {
        seconds = 0
    }

    guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    else { return nil }
    return NSImage(cgImage: result.image, size: .zero)
}

/// Componenti del percorso canonico di `url`, per confronti fra percorsi.
/// Il confronto va fatto per COMPONENTI, mai per lunghezza di stringa o con
/// `hasPrefix`: `/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`, ma lo e'
/// testualmente. Costo misurato: 12,6 us/file (20.000 file in 0,25s), cioe' nulla
/// rispetto alla lettura del file che segue.
// `nonisolated`: pura, chiamata da `LibraryIndexer.scan` (coda di background) oltre che dal
// MainActor — stessa ragione di `realResolvedPath` qui sopra.
nonisolated func canonicalPathComponents(of url: URL) -> [String] {
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
// `nonisolated`: valore puro senza stato, prodotto e consumato da `LibraryIndexer.scan`
// (coda di background).
nonisolated enum IndexEntryVerdict {
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
// `nonisolated`: pura (nessun filesystem, nessun database), chiamata da `LibraryIndexer.scan`
// sulla coda di background.
nonisolated func indexEntryVerdict(storedSize: Int64,
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
// `nonisolated`: value type senza stato mutabile condiviso, costruito e letto dalla coda
// seriale di `LibraryIndexStore` e da `LibraryIndexer.scan`.
nonisolated struct LibraryIndexEntry {
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
// `nonisolated`: costruito da `LibraryIndexStore.duplicateGroups()` sulla coda seriale dello
// store, letto dal pannello Doppioni fuori dal main thread. Nessuno stato mutabile.
nonisolated struct DuplicateGroup {
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
// `nonisolated`: pura, chiamata da `LibraryIndexer.scan` sulla coda di background.
nonisolated func normalizedIndexKey(_ relativePath: String) -> String {
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
// `nonisolated`: valutata una volta dal runtime Swift, usata da `duplicateKeepChoice` fuori
// dal main thread (pannello Doppioni, Task 5).
nonisolated let mainLibraryFolderKey = normalizedIndexKey("Foto iPhone")

/// La cartella di primo livello dove atterrano gli import da schede e dischi
/// (`<SSD>/Import/<etichetta>`, roadmap #27-A). Stessa nota di sopra sul letterale.
nonisolated let importFolderKey = normalizedIndexKey("Import")

/// Perche' la copia proposta e' quella proposta. Fa parte del risultato e non e' un
/// commento: la decisione 3 di Enrico chiede che la proposta sia **spiegata a parole**, e
/// una spiegazione ricostruita a posteriori dalla UI divergerebbe dalla regola alla prima
/// modifica di una delle due.
nonisolated enum DuplicateKeepReason {
    /// L'utente ha chiesto di tenere le copie in questa cartella (ADR-0011, regola 0):
    /// precede le tre euristiche sotto, ma solo sui gruppi che la regola copre.
    case userFolderRule
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
// `nonisolated`: costruita da `duplicateKeepChoice` fuori dal main thread.
nonisolated struct DuplicateKeepChoice {
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
private nonisolated func topLevelFolderKey(of key: String) -> String? {
    // `normalizedIndexKey` e' idempotente sulle chiavi dell'indice, che sono gia' NFC +
    // minuscole. Riapplicarlo costa nulla e rende la regola vera anche se un chiamante
    // futuro costruisse un gruppo da percorsi grezzi. Non si guarda MAI `displayPath`:
    // quello conserva maiuscole e forma Unicode originali, quindi confrontarlo
    // renderebbe la regola dipendente da come e' scritto il nome sul disco.
    let components = normalizedIndexKey(key).split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1 else { return nil }
    return String(components[0])
}

private nonisolated func isInMainLibrary(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == mainLibraryFolderKey
}

private nonisolated func isInImportFolder(_ entry: LibraryIndexEntry) -> Bool {
    topLevelFolderKey(of: entry.path) == importFolderKey
}

/// La regola dell'utente «tieni la copia in X, cestina quelle in Y…» (ADR-0011).
///
/// **Non e' un secondo motore di decisione.** `covers` dice solo se un gruppo rientra nella
/// regola; chi vince fra i sopravvissuti lo decide sempre e solo `duplicateKeepChoice`
/// (Task 4) — qui non si nomina mai un sopravvissuto. E' la classe di errore («due copie
/// della stessa decisione») gia' pagata tre volte in questo progetto (`LibraryExclusions`,
/// `realResolvedPath`, `makeThumbnail`).
///
/// **Forma**: una cartella da tenere e un insieme di cartelle da cestinare, entrambe come
/// **cartelle di primo livello**. Un gruppo e' coperto solo se ha almeno una copia sotto
/// `keepIn` e **tutte** le altre sotto una delle cartelle di `trashIn`: se resta una copia
/// in una terza cartella, il gruppo non e' coperto — non si cestina mai una parte di
/// gruppo, altrimenti "gruppo smaltito a meta'" diventerebbe uno stato che ricompare alla
/// prossima apertura senza che nessuno capisca perche' (ADR-0011).
///
/// `keepIn`/`trashIn` sono chiavi **gia' normalizzate** (minuscole, NFC): il confronto e'
/// per cartella di primo livello via `topLevelFolderKey`, mai su `displayPath`. ExFAT e'
/// case-insensitive e non normalizza l'Unicode, quindi una regola confrontata sulla forma
/// scritta su disco smetterebbe di funzionare senza dirlo.
// `nonisolated`: value type puro, nessuno stato mutabile condiviso.
nonisolated struct DuplicateFolderRule: Codable, Equatable {
    let keepIn: String
    let trashIn: Set<String>

    /// Vero se il gruppo e' coperto da questa regola (vedi il doc-comment del tipo). Una
    /// regola vuota o contraddittoria (`trashIn` che contiene `keepIn`) non copre niente:
    /// non si "interpreta al meglio" una regola che l'utente non ha davvero espresso.
    func covers(_ group: DuplicateGroup) -> Bool {
        guard !keepIn.isEmpty, !trashIn.isEmpty, !trashIn.contains(keepIn) else { return false }
        var hasKeepMember = false
        var hasTrashMember = false
        for member in group.members {
            // Un file sciolto in radice non ha cartella di primo livello: non appartiene
            // a nessuna regola, quindi il gruppo che lo contiene non e' coperto.
            guard let folder = topLevelFolderKey(of: member.path) else { return false }
            if folder == keepIn {
                hasKeepMember = true
            } else if trashIn.contains(folder) {
                hasTrashMember = true
            } else {
                return false
            }
        }
        // Serve almeno un membro da tenere E almeno uno da cestinare: un gruppo
        // interamente dentro `keepIn` non ha niente da smaltire, e proporlo come coperto
        // gonfierebbe il numero di gruppi confermati senza nessun file da spostare.
        return hasKeepMember && hasTrashMember
    }
}

/// Chiave `UserDefaults` della regola per cartella. Persiste fra le sessioni (ADR-0011,
/// domanda 6 della spec, risposta di Enrico): 45 blocchi non si fanno in una sola sessione,
/// e una regola riscritta a memoria alla seconda sessione e' un'altra regola.
nonisolated let duplicateFolderRuleDefaultsKey = "duplicateFolderRule"

/// Legge la regola persistita. Un valore assente o corrotto decodifica a `nil` — «nessuna
/// regola», mai un crash: stessa disciplina di uno schema inatteso sull'indice (ADR-0002).
nonisolated func loadDuplicateFolderRule(defaults: UserDefaults = .standard) -> DuplicateFolderRule? {
    guard let data = defaults.data(forKey: duplicateFolderRuleDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(DuplicateFolderRule.self, from: data)
}

/// Scrive la regola, o la rimuove se `nil` (l'utente ha tolto la regola attiva).
nonisolated func saveDuplicateFolderRule(_ rule: DuplicateFolderRule?, defaults: UserDefaults = .standard) {
    guard let rule else {
        defaults.removeObject(forKey: duplicateFolderRuleDefaultsKey)
        return
    }
    if let data = try? JSONEncoder().encode(rule) {
        defaults.set(data, forKey: duplicateFolderRuleDefaultsKey)
    }
}

/// Sceglie quale copia di un gruppo di doppioni tenere, e dice perche'.
///
/// Funzione **pura**: nessun filesystem, nessun database, nessun ordine di input che conti.
/// Precedenza: **la regola dell'utente, se copre il gruppo** -> libreria principale ->
/// cartella organizzata invece che import -> la piu' vecchia -> tie-break deterministico
/// (percorso piu' corto, poi ordine della chiave). Il motivo riportato e' quello
/// dell'**ultima** regola che ha davvero discriminato: due copie entrambe in `Foto iPhone/`
/// non si distinguono per la prima regola, quindi la scelta (e la frase mostrata
/// all'utente) scende a quella dopo.
///
/// **Regola 0 — la regola per cartella dell'utente (ADR-0011, 2026-09-24).** `rule` precede
/// le tre euristiche sotto, ma **solo sui gruppi che `rule.covers(group)` copre**: sugli
/// altri gruppi non cambia nulla, bit per bit, rispetto a `rule: nil`. Un'istruzione
/// esplicita dell'utente vale piu' di un'euristica, un'euristica vale piu' del silenzio.
/// Quando piu' copie stanno nella cartella da tenere, fra loro decidono le tre regole 1-3
/// gia' esistenti, applicate ai soli sopravvissuti — esattamente come fa gia' `narrow` per
/// ognuna di esse: **nessun tie-break nuovo**. Il parametro non ha un default apposta
/// (stessa disciplina dei quattro gate di ADR-0009): un chiamante che dimentica di passarlo
/// deve fallire in compilazione, non silenziosamente ignorare la regola.
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
/// **Nota misurata sulla regola 2, corretta il 2026-09-24**: fino a quel giorno qui si
/// leggeva che `Import/` non esiste sull'SSD reale, quindi `notAnImport` non discrimina
/// nulla. **Non e' piu' vero**: la passata del 2026-09-24 ha trovato `Import/` con 30 voci
/// (il wizard di #27-A l'ha creata). La regola si attiva davvero, anche se raramente.
///
/// **`ASUS/` e' comparsa dopo il censimento del 2026-09-01 e oggi e' due terzi
/// dell'elenco** (93.824 voci su 141.683, in gran parte `ASUS/foto/recup_dir.NN/`, un
/// recupero PhotoRec/TestDisk da un PC morto). **Decisione di Enrico del 2026-09-24: resta
/// di pari dignita' con le altre cartelle, `recup_dir.*` non si declassa** — stesso
/// argomento gia' usato per `Takeout/`: l'origine automatica non dice niente sul valore del
/// contenuto. **Non riaprire.** Distribuzione reale (2026-09-24, 141.683 voci): `ASUS`
/// 93.824, `Foto iPhone` 18.530, `Takeout` 13.138, `Takeout 2` 10.708, `Foto Google Drive`
/// 3.945, `Other` 1.508, `Import` 30.
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
// `nonisolated`: pura, chiamata dal pannello Doppioni fuori dal main thread (Task 5).
nonisolated func duplicateKeepChoice(_ group: DuplicateGroup, rule: DuplicateFolderRule?) -> DuplicateKeepChoice {
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

    // 0. La regola dell'utente, solo sui gruppi che copre (ADR-0011): un'istruzione
    //    esplicita precede le euristiche sotto. `covers` garantisce gia' almeno un membro
    //    sotto `keepIn`, quindi questo filtro non svuota mai i candidati; il guard di
    //    `narrow` resta comunque la difesa strutturale, non duplicata qui.
    if let rule, rule.covers(group) {
        narrow(candidates.filter { topLevelFolderKey(of: $0.path) == rule.keepIn }, .userFolderRule)
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
    case .userFolderRule:
        lead = "Tengo la copia che si trova \(place): hai chiesto di tenere le copie che stanno lì."
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

/// Vero se **tutte** le copie del gruppo stanno sotto la stessa cartella di primo livello
/// (ADR-0011, spec §2.2): il caso più numeroso della libreria (11.082 gruppi solo dentro
/// `ASUS/`). Un file in radice (nessuna cartella) non ha una cartella con cui accomunarsi:
/// un gruppo che ne contiene uno **non** è mai interno, anche se l'altro membro sta in una
/// cartella vera — non c'è una cartella comune da nominare.
// `nonisolated`: pura, nessuno stato.
nonisolated func duplicateGroupIsInternal(_ group: DuplicateGroup) -> Bool {
    let keys = group.members.map { topLevelFolderKey(of: $0.path) }
    guard let first = keys.first, let firstKey = first else { return false }
    return keys.allSatisfy { $0 == firstKey }
}

/// Le cartelle di primo livello che compaiono **davvero** fra i membri dei gruppi, con
/// quanti gruppi hanno almeno una copia lì — l'elenco onesto (solo le cartelle che hanno
/// doppioni, non tutte quelle che esistono sull'SSD), ricavato dai gruppi già in memoria:
/// **nessuna query nuova**, coerente con `duplicateGroups()` che non cambia (regola 3 dei
/// piani di questo progetto). Il conteggio è **per gruppo, non per file**: un gruppo con
/// tre copie nella stessa cartella conta una volta sola. Un file in radice non ha cartella
/// e non produce nessuna voce. Ordine alfabetico sulla chiave normalizzata, per un elenco
/// che non cambia posizione da un'apertura all'altra a parità di dati.
// `nonisolated`: pura, chiamata dal pannello Doppioni fuori dal main thread.
nonisolated func duplicateFolderList(_ groups: [DuplicateGroup]) -> [(folder: String, count: Int)] {
    var counts: [String: Int] = [:]
    for group in groups {
        let foldersInGroup = Set(group.members.compactMap { topLevelFolderKey(of: $0.path) })
        for folder in foldersInGroup {
            counts[folder, default: 0] += 1
        }
    }
    return counts.map { (folder: $0.key, count: $0.value) }.sorted { $0.folder < $1.folder }
}

/// I tre filtri del pannello Doppioni alla scala reale (ADR-0011, spec §2.2): per cartella,
/// per tipo di gruppo (interno/incrociato), per copertura della regola dell'utente.
///
/// **Nessuno dei tre è un motore di decisione**: restringono quali gruppi si vedono, non
/// nominano mai un sopravvissuto (regola 3 dei piani di questo progetto — quello resta
/// compito esclusivo di `duplicateKeepChoice`). I tre campi sono opzionali e si compongono
/// **in AND**: `nil` significa "nessun vincolo su questo filtro".
///
/// `apply(to:)` restituisce **indici**, non copie di gruppi: alla scala reale (27.798
/// gruppi) copiare l'array a ogni cambio di filtro sarebbe il profilo esatto del bug di
/// prestazioni del 2026-09-02.
// `nonisolated`: value type puro, nessuno stato mutabile condiviso — nessuna riga di
// sicurezza necessaria.
nonisolated struct DuplicateFilter {
    /// Cartella di primo livello richiesta, o `nil` per "Tutte". Un gruppo la soddisfa se
    /// **almeno una** copia sta sotto questa cartella — non tutte: è il filtro «dov'è
    /// successo», non «è tutto lì dentro» (quello è `internalOnly`).
    var folder: String?
    /// `nil` = "Tutti"; `true` = solo i gruppi **interni** (tutte le copie nella stessa
    /// cartella di primo livello); `false` = solo quelli **incrociati** — il complemento
    /// esatto: ogni gruppo è nell'uno o nell'altro, mai in entrambi, mai in nessuno dei due.
    var internalOnly: Bool?
    /// Se non `nil`, tiene solo i gruppi che la regola dell'utente copre (ADR-0011).
    var rule: DuplicateFolderRule?

    func apply(to groups: [DuplicateGroup]) -> [Int] {
        groups.indices.filter { matches(groups[$0]) }
    }

    private func matches(_ group: DuplicateGroup) -> Bool {
        if let folder, !group.members.contains(where: { topLevelFolderKey(of: $0.path) == folder }) {
            return false
        }
        if let internalOnly, duplicateGroupIsInternal(group) != internalOnly {
            return false
        }
        if let rule, !rule.covers(group) {
            return false
        }
        return true
    }
}

/// Quanti file al massimo si cestinano in un blocco solo.
///
/// **Non e' piu' "un numero prudente": e' la granularita' dell'annullamento automatico**
/// (ADR-0012, 2026-09-24). Il registro di ripristino tiene al massimo
/// `TrashManifestStore.maxItems` voci e pota le piu' vecchie: sopra quel numero, un blocco
/// poterebbe le voci **del blocco stesso** mentre le sta ancora scrivendo, e «Annulla
/// l'ultimo spostamento» rimetterebbe a posto solo l'ultima parte — senza saperlo e senza
/// dirlo. Da cui l'invariante protetto da un test (`DuplicateCapInvariantTests`):
/// **`duplicateBatchFileCap <= TrashManifestStore.maxItems`**. La domanda da farsi, per chi
/// un giorno volesse alzare questo numero, non e' "quanto dura un blocco" ma "quante foto
/// voglio poter rimettere a posto con un clic".
///
/// **Il numero (2.000) e' condizionato a una misura, non scelto a tavolino** (Task 2 del
/// piano `2026-09-24-duplicates-at-real-scale`): `TrashManifestStore.record` riscrive
/// l'intero registro a ogni file, quindi il costo di un blocco al tetto e' quello del
/// registro — misurato **il 2026-09-24: 6,58 secondi per 2.000 voci** scritte con percorsi
/// di forma realistica (`ASUS/foto/recup_dir.NN/f<numero>.jpg`), ben sotto la soglia di
/// decisione di ~30 s fissata da Enrico. Se in futuro la libreria crescesse abbastanza da
/// spostare quel numero sopra i 30 s, il tetto scende al valore che la misura consente (si
/// riprova 1.500, poi 1.000) — non si ritocca a occhio.
///
/// **Numeri della prima passata reale** (2026-09-24, 141.683 voci nell'elenco): 89.541
/// copie in eccesso in 27.798 gruppi, 1,75 MB medi per copia. A 2.000 file per blocco sono
/// **45 blocchi**; un blocco al tetto costa **~55 secondi** (~4,5 GB da rileggere — copie
/// in eccesso piu' copie tenute — a 224 MiB/s misurati sull'SSD reale il 2026-09-01 ≈ 19 s,
/// piu' 2.000 `trashItem` a 55,8 file/s misurati il 2026-08-27 ≈ 36 s): il raggio di un
/// guasto resta un minuto di lavoro, e il blocco e' **interamente coperto**
/// dall'annullamento automatico.
nonisolated let duplicateBatchFileCap = 2_000

/// Stesso ragionamento del tetto sui file, sull'altra grandezza che conta.
///
/// **Decimale** (50 × 1000⁴) e non binario, per coerenza con `ByteCountFormatter(.file)`,
/// che e' il modo in cui questa app scrive i byte all'utente ovunque: un tetto binario
/// scatterebbe a un numero diverso da quello mostrato nel riepilogo.
///
/// **Non si alza insieme al tetto sui file** (ADR-0012): sulla libreria reale, a 1,75 MB
/// medi per copia in eccesso, 2.000 file sono ~3,5 GB — i 50 GB restano **14 volte piu'
/// larghi** del tetto sui file (erano 57 volte a 500). E' quasi sempre il tetto sui file a
/// decidere; quello sui byte resta una guardia per una selezione fatta di video, che e' il
/// suo lavoro, e alzarlo non cambierebbe niente sulla libreria di oggi.
nonisolated let duplicateBatchByteCap: Int64 = 50_000_000_000

/// Il blocco di doppioni che l'utente sta per confermare: quali gruppi, quale copia si
/// tiene di ognuno, quanti file si spostano, quanto spazio si libera e da quali cartelle.
///
/// E' la **prima delle due conferme** (decisione 4 di Enrico): il riepilogo dettagliato
/// viene prima della conferma vera. Il peso della conferma sta tutto qui — l'alert
/// distruttivo che segue e' corto per definizione, quindi se questo riepilogo e' vago non
/// c'e' alert che tenga.
///
/// **Congela la copia tenuta di ogni gruppo.** `duplicateKeepChoice` gira una volta sola,
/// dentro `init(groups:rule:)`, e il risultato viaggia dentro il blocco fino al
/// `DuplicateTrasher`. Non e' un dettaglio di efficienza: fra il riepilogo che l'utente
/// legge e il cestinamento l'indice puo' essere cambiato, e una scelta ricalcolata su dati
/// nuovi puo' nominare **un'altra copia** — l'utente acconsente a cestinare A e viene
/// cestinato B. Chi consuma questo tipo non deve mai ricalcolare la scelta: deve usare
/// quella che trova qui dentro.
///
/// **Il congelamento vale anche attraverso un sottoinsieme (ADR-0011, 2026-09-24).**
/// `init(entries:)` costruisce un blocco filtrando `Entry` gia' congelate altrove — senza
/// chiamare `duplicateKeepChoice` nemmeno una volta — proprio perche' un secondo calcolo su
/// un sottoinsieme e' la stessa trappola: con una regola dell'utente che puo' cambiare fra
/// la lista e la conferma, ricalcolare puo' nominare un sopravvissuto diverso da quello che
/// l'utente ha visto. E' per questo che questo costruttore esiste.
///
/// Logica **pura**: nessun filesystem, nessun database.
// `nonisolated`: costruita dal pannello Doppioni fuori dal main thread (Task 5) — e' il tipo
// del bug di prestazioni del 2026-09-02, che allora era stato "corretto" solo spostando il
// PUNTO in cui si ricalcolava, non il thread su cui girava.
nonisolated struct DuplicateBatch {

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
    /// I byte che si **rileggono** per verificare l'intero blocco: **ogni** membro di ogni
    /// gruppo, la copia tenuta compresa — e' la rilettura che precede il cestinamento
    /// (ADR-0005), non lo spazio che si libera. **Non e' `reclaimableBytes`**: quella
    /// esclude la copia tenuta, questa la include, perche' anche lei viene riletta e
    /// rihashata per pretendere l'unanimita' del gruppo.
    let verifiedBytes: Int64
    /// Da quali **cartelle di primo livello** se ne vanno, e quanti gruppi per cartella.
    /// Solo le cartelle che **perdono** file: quella della copia tenuta non compare se da
    /// li' non esce niente. Cartella di primo livello e non genitore completo (ADR-0011,
    /// 2026-09-24): con le copie in eccesso sparse su migliaia di `ASUS/foto/recup_dir.NN`,
    /// la cartella genitrice completa produrrebbe migliaia di righe nel riepilogo — proprio
    /// dove sta tutto il peso della prima conferma (ADR-0005, decisione 4).
    let folderBreakdown: [(folder: String, count: Int)]
    let exceedsCap: Bool

    /// Punto **unico** in cui la scelta si calcola: `duplicateKeepChoice` gira una volta
    /// per gruppo, qui, con la regola dell'utente passata esplicitamente (parametro senza
    /// default, stessa disciplina dei quattro gate di ADR-0009).
    init(groups: [DuplicateGroup], rule: DuplicateFolderRule?) {
        // I gruppi ridotti a un solo membro si scartano prima: `duplicateKeepChoice` ha una
        // precondition su almeno due membri, e questo e' il confine dove il filtro va messo
        // (non ammorbidendo la guardia).
        let entries = groups
            .filter { $0.members.count > 1 }
            .map { Entry(group: $0, choice: duplicateKeepChoice($0, rule: rule)) }
        self.init(entries: entries)
    }

    /// Costruisce il blocco da `Entry` **già congelate altrove** — non chiama mai
    /// `duplicateKeepChoice`, nemmeno una volta: ricalcola solo i totali (ordine, conteggi,
    /// ripartizione per cartella, tetto) sul sottoinsieme ricevuto. È il modo corretto di
    /// ricavare un blocco da una selezione: filtrare le `Entry` di un blocco già costruito,
    /// mai ricostruire dai gruppi.
    init(entries: [Entry]) {
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
        // Ogni membro del gruppo, copia tenuta compresa: `group.size` e' la stessa
        // grandezza usata da `reclaimableBytes`, moltiplicata per TUTTI i membri e non
        // solo per quelli che se ne vanno.
        self.verifiedBytes = entries.reduce(0) { $0 + $1.group.size * Int64($1.group.members.count) }

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

    /// La cartella di **primo livello** che contiene il file, come e' scritta su disco:
    /// l'utente la deve poter ritrovare nel Finder, quindi `displayPath` e non la chiave
    /// minuscola. Non l'intero percorso genitore (ADR-0011): vedi il doc-comment di
    /// `folderBreakdown`.
    ///
    /// Non piu' `private` da Task 11 (Step 1): `DuplicatesView` la riusa per mostrare i nomi
    /// dei filtri con le maiuscole vere, invece di duplicare questa stessa trasformazione
    /// una seconda volta — la classe di errore gia' pagata da `LibraryExclusions`/
    /// `realResolvedPath`/`makeThumbnail`. Solo la visibilita' e' cambiata, zero righe di
    /// comportamento.
    static func folder(of entry: LibraryIndexEntry) -> String {
        let components = entry.displayPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1, let first = components.first else {
            return "(sull'SSD, fuori da ogni cartella)"
        }
        return String(first)
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
        // Riga di coda, solo se le cartelle sono piu' di una: a questa scala e' l'unico
        // modo per accorgersi subito di aver puntato la cartella sbagliata, senza dover
        // contare le righe sopra a mano.
        if folderBreakdown.count > 1 {
            out.append("In tutto, i file escono da "
                + "\(DuplicateBatch.count(folderBreakdown.count, "cartella", "cartelle")) diverse.")
        }

        out.append("Le copie che stanno sull'HDD e su Cubbit restano dove sono: questa operazione "
            + "tocca soltanto l'SSD.")

        // La riga "Hai selezionato troppi file in una volta sola..." (che invitava a togliere
        // gruppi a mano) e' stata rimossa il 2026-09-25, assenso di Enrico — TERZA eccezione
        // autorizzata alla regola 6/7 dei piani di questo progetto (oltre a folderBreakdown e
        // confirmationBlockedReason): con la corsa a piu' blocchi (ADR-0012) una selezione
        // sopra il tetto non e' piu' rifiutata, si smaltisce da sola in blocchi automatici, e
        // quella frase — pensata per il vecchio tetto che bloccava — diceva ora il contrario
        // di quello che il riepilogo (DuplicatesStatus.runPlanLine/undoScopeLine, Task 9/11)
        // dice un rigo sopra. Due frasi per la stessa informazione, di cui una falsa, erano
        // una di troppo. `exceedsCap` resta sul tipo (usato altrove, es. duplicateBatchFileCap)
        // ma non produce piu' nessuna riga qui.

        return out
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

/// La sequenza di blocchi in cui si divide una selezione confermata — **una corsa**
/// (ADR-0012, spec §3.2). L'utente conferma la corsa intera; `BackupRunner` (Task 10) la
/// smaltisce un blocco alla volta, con `DuplicateTrasher.run` invariato.
///
/// **Divide ai due tetti (file e byte), il primo che scatta, e non spezza mai un gruppo fra
/// due blocchi**: le `Entry` di un gruppo restano sempre tutte nello stesso blocco. Un
/// gruppo la cui sola dimensione supera gia' un tetto finisce comunque in un blocco tutto
/// suo — rifiutarlo lo renderebbe inarrivabile per sempre, ed e' l'unico caso in cui un
/// blocco puo' superare il tetto.
///
/// **Ordine**: quello gia' deterministico del pannello, cosi' com'e' nell'array ricevuto —
/// nessun riordino qui. `DuplicateBatch.groups` arriva gia' ordinato (spazio recuperabile
/// decrescente, poi copie, poi hash), quindi il piano e' riproducibile e i primi blocchi
/// sono quelli che recuperano piu' spazio.
///
/// **La stima della durata** usa due costanti **misurate sul volume reale**, non stimate a
/// tavolino: 224 MiB/s di lettura+SHA256 (misurato 2026-09-01) e 55,8 file/s di `trashItem`
/// (misurato 2026-08-27, su un'immagine disco — non ancora sull'SSD vero via FSKit, rischio
/// noto della spec §8 punto 6). E' dichiarata come "circa", mai come una promessa.
// `nonisolated`: value type puro, nessuno stato mutabile condiviso.
nonisolated struct DuplicateRunPlan {
    /// Misurato sull'SSD reale il 2026-09-01 (campione di 300 file, 1103 MiB in 4,9 s).
    static let measuredReadThroughputBytesPerSecond: Double = 224 * 1024 * 1024
    /// Misurato su immagine disco ExFAT il 2026-08-27.
    static let measuredTrashItemsPerSecond: Double = 55.8

    let blocks: [[DuplicateBatch.Entry]]
    /// "Circa" quanto dura l'intera corsa: rilettura+rihash di ogni membro (copia tenuta
    /// compresa, ADR-0005) piu' i `trashItem` dei file che se ne vanno. Mai zero per una
    /// corsa non vuota: anche una manciata di file richiede un tempo reale non nullo, e "0
    /// secondi" si leggerebbe come "istantaneo".
    let estimatedSeconds: Double

    init(entries: [DuplicateBatch.Entry],
         fileCap: Int = duplicateBatchFileCap,
         byteCap: Int64 = duplicateBatchByteCap) {
        var blocks: [[DuplicateBatch.Entry]] = []
        var current: [DuplicateBatch.Entry] = []
        var currentFiles = 0
        var currentBytes: Int64 = 0

        for entry in entries {
            let entryFiles = entry.leaving.count
            let entryBytes = entry.reclaimableBytes
            // Il gruppo che farebbe sforare un tetto chiude il blocco corrente — ma solo se
            // il blocco corrente non e' vuoto: un gruppo da solo sopra il tetto deve avere
            // comunque un blocco, mai essere scartato. `>` e non `>=`: alla soglia esatta
            // il blocco resta lo stesso, stessa regola di `DuplicateBatch.exceedsCap`.
            if !current.isEmpty,
               (currentFiles + entryFiles > fileCap || currentBytes + entryBytes > byteCap) {
                blocks.append(current)
                current = []
                currentFiles = 0
                currentBytes = 0
            }
            current.append(entry)
            currentFiles += entryFiles
            currentBytes += entryBytes
        }
        if !current.isEmpty { blocks.append(current) }
        self.blocks = blocks

        // La rilettura tocca OGNI membro, la copia tenuta compresa (ADR-0005): stessa
        // grandezza di `DuplicateBatch.verifiedBytes`, sommata qui sull'intera corsa.
        let totalBytesToVerify = entries.reduce(Int64(0)) { $0 + $1.group.size * Int64($1.group.members.count) }
        let totalFilesToTrash = entries.reduce(0) { $0 + $1.leaving.count }
        let readSeconds = Double(totalBytesToVerify) / Self.measuredReadThroughputBytesPerSecond
        let trashSeconds = Double(totalFilesToTrash) / Self.measuredTrashItemsPerSecond
        self.estimatedSeconds = entries.isEmpty ? 0 : max(readSeconds + trashSeconds, 1)
    }
}

/// Una foto spostata nel Cestino, con tutto il necessario per rimetterla al suo posto.
///
/// `hash` e `size` non sono decorativi: sono il patto fra il momento del cestinamento e
/// quello dell'annullamento. Ripristinare senza riverificarli significherebbe rimettere al
/// posto della foto dell'utente un file che nel frattempo e' diventato un altro file.
// `nonisolated`: value type senza stato condiviso, scritto da `DuplicateTrasher.run` fuori
// dal main thread e letto da `TrashManifestStore` (dietro `lock`).
nonisolated struct TrashedItem: Codable, Equatable {
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
    /// `nil` = ancora nel Cestino. Impostata da `TrashManifestStore.markRestored` non appena
    /// `TrashRestorer` rimette la foto al suo posto (ADR-0009): senza, «Annulla» non sa cosa
    /// e' gia' tornato e una seconda pressione racconterebbe «Cestino svuotato» su foto che
    /// invece sono al loro posto. Campo accessorio: un registro scritto da una versione senza
    /// questo campo si decodifica con `restoredAt == nil`, comportamento di oggi.
    var restoredAt: Date? = nil
    /// Il percorso della copia TENUTA del gruppo (ROADMAP #46, ADR-0017), relativo alla radice
    /// dell'SSD e scritto com'e' sul disco (`LibraryIndexEntry.displayPath` del tenuto): e' lo
    /// stesso percorso relativo che quella foto ha sull'HDD e la stessa chiave che ha su Cubbit,
    /// ed e' quello che il progetto 4 terra' su HDD e Cubbit. Relativo e non assoluto (come
    /// invece `originalDisplayPath`) apposta: la radice dell'SSD cambia nome se macOS lo monta
    /// come «SSD - Enri 1». `nil` nelle voci scritte prima di questo campo: «non si sa», mai
    /// un percorso inventato.
    var keptPath: String? = nil
}

/// Perche' una voce non e' stata rimessa al suo posto. Ogni caso ha una frase propria:
/// l'utente che preme «Annulla» e non vede tornare tutto deve poter capire quale dei motivi
/// lo riguarda, e cosa puo' farci.
nonisolated enum RestoreSkipReason: Hashable {
    /// Il file non e' piu' nel Cestino: quasi sempre il Cestino e' stato svuotato.
    case missingInTrash
    /// Il file nel Cestino non e' piu' quello che ci era stato messo.
    case alteredInTrash
    /// Al posto originale c'e' di nuovo qualcosa: non si sovrascrive mai.
    case originalPathOccupied
    /// Lo spostamento e' fallito per un motivo del filesystem.
    case moveFailed(String)
    /// Il file nel Cestino c'e', ma non e' stato possibile rileggerlo per riverificarlo — e
    /// il disco e' rimasto lo stesso (altrimenti sarebbe uno scollegamento). Non e'
    /// `alteredInTrash`: quello dice "e' cambiata", questo dice "non ho potuto controllare".
    case unreadableInTrash
    /// Il percorso originale o quello nel Cestino risolvono fuori dalla root della libreria
    /// (registro alterato a mano, o un `..` nel percorso): l'app non tocca niente fuori dalla
    /// libreria, per lo stesso motivo per cui `DuplicateTrasher` non lo fa.
    case outsideLibrary

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
        case .unreadableInTrash:
            return "Non è stato possibile rileggere questa foto nel Cestino, quindi è rimasta lì. "
                + "Riprova più tardi; se il problema resta, puoi spostarla a mano."
        case .outsideLibrary:
            return "Questa foto doveva tornare in un posto fuori dall'SSD delle foto, quindi "
                + "l'app non l'ha toccata: è ancora nel Cestino."
        }
    }
}

nonisolated struct RestoreOutcome {
    var restored: [TrashedItem] = []
    var skipped: [(item: TrashedItem, reason: RestoreSkipReason)] = []
    /// Voci trovate gia' al loro posto (ADR-0009, D3): il file non e' piu' nel Cestino, il
    /// disco e' quello di prima, e al percorso originale c'e' un file con la stessa
    /// dimensione e lo stesso hash registrati. Si marcano come tornate, senza muovere niente.
    var alreadyInPlace: [TrashedItem] = []
    /// L'utente ha premuto "Interrompi".
    var interrupted: Bool = false
    /// Il volume della libreria e' sparito a meta' ripristino: si e' fermato tutto.
    var stoppedBecauseVolumeVanished: Bool = false
    /// Voci mai tentate (scollegamento, interruzione, o volume assente all'avvio).
    var notAttempted: Int = 0
}

/// Riepilogo piccolo e puro di cosa resta da rimettere a posto — quello che la UI legge in
/// O(1), invece di rifare il filtro di `pendingInLastBatch()` a ogni ridisegno (ADR-0009, D8).
/// `nil` (fuori da questo tipo, nel punto in cui viene prodotto) = niente da rimettere a posto.
// Nessuna riga di sicurezza: value type senza stato condiviso.
nonisolated struct RestorableBatchSummary: Equatable {
    var pendingCount: Int
    var batchCount: Int
    /// Il piu' vecchio istante di cestinamento fra le voci ancora da rimettere a posto: e'
    /// la data che la conferma mostra all'utente ("le foto spostate il 2 settembre").
    var trashedAt: Date
}

/// Il contenuto del registro su disco.
// `nonisolated`: value type senza stato condiviso, letto/scritto da `TrashManifestStore`
// sempre dietro `lock`.
nonisolated struct TrashManifest: Codable {
    /// Quante voci sono state registrate in tutto. Resta veritiero anche quando `items` e'
    /// stata potata dal tetto: e' questo il numero da mostrare, `items.count` non lo e'.
    /// Stessa forma di `UnverifiedCopies.totalCount`, per lo stesso motivo.
    var totalRecorded: Int = 0
    var items: [TrashedItem] = []
}

nonisolated extension TrashManifest {
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

nonisolated extension TrashedItem {
    private enum CodingKeys: String, CodingKey {
        case batchId, originalDisplayPath, originalKey, trashedPath, size, hash, trashedAt, restoredAt
        case keptPath
    }

    /// Stessa ragione del tipo contenitore. Qui la decodifica e' **tollerante sui campi
    /// accessori e severa su quelli portanti**: senza `trashedPath`, `size` o `hash` la voce
    /// non e' ripristinabile in sicurezza e non deve entrare nel registro fingendo di
    /// esserlo. `originalKey` invece degrada: serve a rimettere la riga nell'indice, e un
    /// indice incompleto si ricostruisce da solo. `restoredAt` degrada a `nil`: un registro
    /// scritto prima di ADR-0009 non aveva questo campo, e "non ancora tornato" e' la lettura
    /// corretta della sua assenza.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batchId = try c.decodeIfPresent(String.self, forKey: .batchId) ?? ""
        originalDisplayPath = try c.decode(String.self, forKey: .originalDisplayPath)
        originalKey = try c.decodeIfPresent(String.self, forKey: .originalKey) ?? ""
        trashedPath = try c.decode(String.self, forKey: .trashedPath)
        size = try c.decode(Int64.self, forKey: .size)
        hash = try c.decode(String.self, forKey: .hash)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt) ?? Date(timeIntervalSince1970: 0)
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
        // Campo accessorio (ROADMAP #46): le voci scritte prima non l'hanno, e restano valide.
        keptPath = try c.decodeIfPresent(String.self, forKey: .keptPath)
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
// `nonisolated`: `record` viene chiamato dal trasher fuori dal main thread, `markRestored` da
// `TrashRestorer` (anche lei fuori dal main, ADR-0009), `lastBatch`/`pendingInLastBatch`/
// `restorableSummary` da entrambi i thread e dal main. Ogni accesso a `manifest` avviene dentro
// `lock.withLock`, scrittura su disco compresa; `url` e' `let`. Vedi ADR-0006, ADR-0009.
nonisolated final class TrashManifestStore: @unchecked Sendable {

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

    /// Le voci dell'ultimo blocco registrato. L'ultimo e' quello **registrato per ultimo**,
    /// non quello con la data piu' alta: due blocchi possono condividere l'istante, l'ordine
    /// di scrittura no. Da ADR-0009 «Annulla l'ultimo spostamento» non usa piu' questo metodo
    /// direttamente: usa `pendingInLastBatch()`, che esclude le voci gia' marcate tornate.
    /// Resta usata dai test e per raccontare la storia del blocco.
    func lastBatch() -> [TrashedItem] {
        lock.withLock {
            guard let ultimo = manifest.items.last?.batchId else { return [] }
            return manifest.items.filter { $0.batchId == ultimo }
        }
    }

    /// Le voci dell'ultimo blocco **non ancora rimesse a posto**. E' questo, non `lastBatch()`,
    /// che «Annulla l'ultimo spostamento» rimette a posto (ADR-0009, D1): un annullamento
    /// interrotto a meta' lascia alcune voci marcate e altre no, e una seconda pressione deve
    /// riprendere solo da quelle rimaste, non ritentare quelle gia' tornate.
    func pendingInLastBatch() -> [TrashedItem] {
        lock.withLock {
            guard let ultimo = manifest.items.last?.batchId else { return [] }
            return manifest.items.filter { $0.batchId == ultimo && $0.restoredAt == nil }
        }
    }

    /// Marca una voce come tornata al suo posto e **scrive su disco prima di tornare** —
    /// stessa disciplina di `record`: un annullamento interrotto o un crash non deve poter
    /// disallineare il registro da quello che e' davvero successo sul disco.
    ///
    /// L'identita' e' `batchId` + `trashedPath` + `originalDisplayPath`, mai `==` sull'intero
    /// valore: due voci con lo stesso `originalDisplayPath` in blocchi diversi (lo stesso file
    /// cestinato, rimesso, e ricestinato) non si devono confondere. Una voce con
    /// `trashedPath` vuoto non si marca mai: non era ripristinabile, e non e' mai stata
    /// davvero spostata dal Cestino.
    func markRestored(_ item: TrashedItem, at date: Date) throws {
        guard !item.trashedPath.isEmpty else { return }
        try lock.withLock {
            guard let i = manifest.items.firstIndex(where: {
                $0.batchId == item.batchId && $0.trashedPath == item.trashedPath
                    && $0.originalDisplayPath == item.originalDisplayPath
            }) else { return }
            manifest.items[i].restoredAt = date
            try writeUnsynchronized()
        }
    }

    /// Cosa resta da rimettere a posto nell'ultimo blocco, o `nil` se non c'e' niente
    /// (nessun blocco mai registrato, o l'ultimo e' completamente tornato). Valore piccolo e
    /// puro: la UI lo legge in O(1) invece di rifare il filtro a ogni ridisegno (ADR-0009, D8).
    func restorableSummary() -> RestorableBatchSummary? {
        lock.withLock {
            guard let ultimo = manifest.items.last?.batchId else { return nil }
            let batch = manifest.items.filter { $0.batchId == ultimo }
            let pending = batch.filter { $0.restoredAt == nil }
            // La data e' quella delle voci ANCORA da rimettere a posto, non dell'intero blocco
            // (rilievo di review del 2026-09-20): in un annullamento ripreso, la conferma deve
            // parlare di cio' che sta per succedere adesso.
            guard !pending.isEmpty, let oldest = pending.map(\.trashedAt).min() else { return nil }
            return RestorableBatchSummary(pendingCount: pending.count, batchCount: batch.count,
                                          trashedAt: oldest)
        }
    }

    private func writeUnsynchronized() throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        // `0600` come l'indice, e per lo stesso motivo: il file non contiene foto, ma
        // contiene i **percorsi** di tutte le foto toccate, in chiaro. Best-effort — un
        // registro scritto e' piu' importante di un registro con i permessi giusti.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Una riga della storia degli spostamenti (`TrashHistory`): un blocco concluso, con i
/// percorsi originali assoluti di tutte le foto che quel blocco ha spostato.
nonisolated struct TrashHistoryEntry: Codable {
    let blockId: String
    let trashedAt: Date
    /// Percorsi **assoluti**, come `TrashedItem.originalDisplayPath`: e' li' che la foto
    /// stava prima di finire nel Cestino.
    let originalPaths: [String]
    /// Per ogni voce di `originalPaths`, nello stesso ordine, il percorso della copia TENUTA
    /// del suo gruppo (`TrashedItem.keptPath`, relativo alla radice dell'SSD; stringa vuota se
    /// non si sa). Serve al progetto 4: il registro di ripristino ricorda solo le ultime
    /// `TrashManifestStore.maxItems` voci, questa storia le ricorda tutte. Opzionale: le righe
    /// scritte prima di questo campo non ce l'hanno (la decodifica sintetizzata di un
    /// opzionale usa `decodeIfPresent`).
    let keptPaths: [String]?
}

/// La storia degli spostamenti (ADR-0012, D13 punto 4): un file append-only sul disco
/// interno, mai sull'SSD, su cui l'app scrive **una riga per blocco concluso** (JSON su una
/// riga, `.jsonl`) con i percorsi originali delle foto di quel blocco.
///
/// **Non e' un annullamento.** Non ha bottoni, non legge mai il proprio contenuto per
/// decidere niente, e non aggiunge nessun percorso distruttivo: `TrashManifestStore` resta
/// l'unico documento da cui «Annulla l'ultimo spostamento» rimette a posto le foto. Questa
/// storia esiste perche' il registro di ripristino ricorda al massimo
/// `TrashManifestStore.maxItems` voci (2.000) e le pota, mentre una corsa puo' toccarne
/// 89.541: dopo 45 blocchi, senza questa storia, il Cestino dell'SSD diventerebbe una
/// cartella piatta di foto di cui nessuno saprebbe piu' il percorso d'origine. Si legge a
/// mano, dal Finder o da un editor di testo, solo se serve ritrovare da dove veniva una foto
/// che il registro ha gia' potato.
///
/// **Costa una scrittura per blocco, non per file**: non riapre il costo quadratico che ha
/// condizionato il tetto di `duplicateBatchFileCap` (`TrashManifestStore.record` riscrive
/// l'intero registro a ogni file; qui si aggiunge solo una riga, una volta per blocco).
///
/// **Il fallimento della scrittura non deve mai far fallire il blocco**: e' una storia, non
/// un prerequisito del cestinamento. `append` non lancia: un file illeggibile, un permesso
/// negato, qualunque guaio di I/O restano confinati qui dentro.
// `nonisolated`: chiamata da `BackupRunner` (Task 10) fuori dal main thread, una volta per
// blocco concluso. Sicura per costruzione: l'unico stato mutabile e' il file su disco,
// toccato solo dentro `lock.withLock`; `url` e' `let`.
nonisolated final class TrashHistory: @unchecked Sendable {

    enum StoreError: Error, LocalizedError {
        case invalidLocation(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation(let p): return "Posizione non consentita per la storia degli spostamenti: \(p)"
            }
        }
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL) throws {
        // Stessa allow-list di `TrashManifestStore`/`LibraryIndexStore`, non una seconda:
        // questo file nomina i percorsi delle foto e non deve mai finire sul volume sorgente.
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// Scrive una riga per il blocco appena concluso. Un blocco senza file spostati non
    /// produce nessuna riga: non c'e' niente da ricordare. Best-effort e silenzioso su
    /// qualunque errore di I/O — vedi il doc-comment del tipo.
    func append(blockId: String, trashed: [TrashedItem], at date: Date = Date()) {
        guard !trashed.isEmpty else { return }
        let entry = TrashHistoryEntry(blockId: blockId, trashedAt: date,
                                      originalPaths: trashed.map(\.originalDisplayPath),
                                      keptPaths: trashed.map { $0.keptPath ?? "" })
        guard let data = try? JSONEncoder().encode(entry) else { return }
        lock.withLock {
            appendLineUnsynchronized(data)
        }
    }

    /// Apertura POSIX a basso livello in **sola append**: `O_APPEND` garantisce che ogni
    /// `write` finisca alla fine del file, atomicamente rispetto ad altri scrittori sullo
    /// stesso file — e' cio' che rende impossibile riscrivere le righe precedenti, a
    /// differenza di un `Data.write(to:)` che sostituirebbe l'intero contenuto. `O_CREAT`
    /// crea il file con permessi `0600` se non esiste ancora; `fchmod` e' una seconda difesa
    /// best-effort per il caso in cui il file esistesse gia' con permessi diversi.
    private func appendLineUnsynchronized(_ data: Data) {
        let fd = open(url.path, O_APPEND | O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        var line = data
        line.append(0x0A) // newline: una riga per blocco.
        _ = line.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }
}

/// Rimette al loro posto le foto di un blocco — il motore dietro «Annulla l'ultimo
/// spostamento» (ADR-0009). Stessa cura del cestinamento (`DuplicateTrasher`), letta al
/// contrario: una voce alla volta, registro aggiornato subito dopo ogni successo, `st_dev`
/// riletto a ogni fallimento, mai `NSFileNoSuchFileError` interpretato come "gia' fatto",
/// interruzione solo fra una foto e l'altra. Sostituisce `TrashManifestStore.restore`
/// (rimossa): tenerla come involucro avrebbe lasciato due strade per la stessa operazione,
/// una senza `st_dev` — la classe di errore gia' pagata tre volte (`LibraryExclusions`,
/// `realResolvedPath`, `makeThumbnail`).
///
/// `moveFunction`/`hashFunction`/`volumeIdentity` hanno per default le funzioni reali e sono
/// iniettate **solo dai test**: gli esiti da coprire (uno scollegamento a meta' ripristino,
/// un hash che cambia, un occupante che compare proprio prima della mossa) non sono
/// producibili su file veri senza una corsa fra thread. Stesso pattern di `DuplicateTrasher`.
// `nonisolated`: `run` deve girare fuori dal main thread — la rilettura di ogni foto puo'
// richiedere minuti (blocco fino a 50 GB). Solo proprieta' `let`; lo stato di `run` e' tutto
// locale. Uno alla volta: lo garantisce `BackupRunner.isRestoringFromTrash`. Il registro e'
// protetto dal proprio lock (`TrashManifestStore`). Vedi ADR-0006, ADR-0009.
nonisolated final class TrashRestorer: @unchecked Sendable {
    private let libraryRoot: URL
    private let manifest: TrashManifestStore
    private let moveFunction: (URL, URL) throws -> Void
    private let hashFunction: (URL) -> MeasuredHash?
    private let volumeIdentity: (URL) -> dev_t?
    private let now: () -> Date
    /// Le due forme canoniche della root, calcolate una volta — stessa coppia usata da
    /// `DuplicateTrasher`/`isAlreadyInLibrary`: la root puo' essere raggiunta per symlink.
    private let rootForms: [[String]]

    init(libraryRoot: URL,
         manifest: TrashManifestStore,
         moveFunction: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         hashFunction: @escaping (URL) -> MeasuredHash? = { sha256Measured(of: $0) },
         volumeIdentity: @escaping (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         now: @escaping () -> Date = Date.init) {
        self.libraryRoot = libraryRoot
        self.manifest = manifest
        self.moveFunction = moveFunction
        self.hashFunction = hashFunction
        self.volumeIdentity = volumeIdentity
        self.now = now
        self.rootForms = [libraryRoot.standardizedFileURL.path, realResolvedPath(libraryRoot)].map {
            $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
    }

    /// Rimette al loro posto le voci indicate. Non lancia mai: ogni voce che non si riesce a
    /// ripristinare finisce fra gli `skipped` **con il motivo**, e le altre proseguono — a
    /// meno che il volume della libreria non sia sparito, nel qual caso l'intero ripristino
    /// si ferma (mai un tentativo di scrivere su un disco che non e' piu' quello di prima).
    func run(_ items: [TrashedItem],
             onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
             isCancelled: () -> Bool = { false }) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        let fm = FileManager.default

        // `st_dev` della root letto una volta prima di iniziare. Senza questo valore «il file
        // non c'era» e «il volume e' sparito» restano indistinguibili: presentano lo stesso
        // `NSCocoaErrorDomain/4`. Se il volume non c'e' gia' all'inizio, nessuna voce viene
        // tentata: scrivere sul disco interno al posto dell'SSD sarebbe il guasto peggiore.
        guard let deviceAtStart = volumeIdentity(libraryRoot) else {
            outcome.stoppedBecauseVolumeVanished = true
            outcome.notAttempted = items.count
            return outcome
        }

        for (index, item) in items.enumerated() {
            // Un'interruzione lascia un blocco parziale: e' uno stato legittimo, e le foto
            // gia' rimesse a posto restano marcate. Solo FRA una voce e l'altra: una foto a
            // meta' non esiste, perche' `moveItem` e' una rename.
            if isCancelled() {
                outcome.interrupted = true
                outcome.notAttempted += items.count - index
                break
            }
            // Il conteggio "fatto" misura il lavoro tentato su questa voce, qualunque sia
            // l'esito (tornata, saltata, o l'ultima prima di uno stop per scollegamento).
            defer { onProgress(index + 1, items.count) }

            let original = URL(fileURLWithPath: item.originalDisplayPath)
            let trashed = URL(fileURLWithPath: item.trashedPath)

            // Confinamento dell'origine, per COMPONENTI canoniche, mai `hasPrefix`: il
            // registro e' un file JSON scrivibile dall'utente, e un percorso con `..` o su un
            // altro disco non deve poter diventare la destinazione di una mossa.
            guard rootForms.contains(where: { relativePath(of: original.path, under: $0) != nil }) else {
                outcome.skipped.append((item, .outsideLibrary))
                continue
            }

            guard fm.fileExists(atPath: trashed.path) else {
                // Stesso `NSCocoaErrorDomain/4` per due guasti diversi: solo `st_dev` li
                // distingue. Il volume c'e' ancora ⇒ il Cestino e' stato davvero svuotato (o
                // il file spostato a mano), MAI "gia' fatto" senza controllare.
                guard volumeIdentity(libraryRoot) == deviceAtStart else {
                    outcome.stoppedBecauseVolumeVanished = true
                    outcome.notAttempted += items.count - index - 1
                    break
                }
                // Riconciliazione (ADR-0009, D3): il file non e' piu' nel Cestino, ma se al
                // percorso originale c'e' gia' un file con la stessa dimensione e lo stesso
                // hash registrati, la foto e' semplicemente gia' al suo posto — seconda
                // pressione dopo un annullamento riuscito, "Rimetti a posto" fatto dal
                // Finder, o un crash fra la mossa e la marcatura del registro.
                if let measured = hashFunction(original),
                   measured.hash == item.hash, measured.size == item.size {
                    outcome.alreadyInPlace.append(item)
                    // La foto e' tornata: se la scrittura del registro fallisce non si
                    // ritenta qui, la prossima esecuzione la riconoscera' comunque via D3.
                    try? manifest.markRestored(item, at: now())
                } else {
                    outcome.skipped.append((item, .missingInTrash))
                }
                continue
            }

            // Il file nel Cestino deve stare sullo stesso disco della libreria: garantisce
            // anche che la mossa sotto sia sempre una rename, mai una copia fra volumi.
            guard volumeIdentity(trashed) == deviceAtStart else {
                outcome.skipped.append((item, .outsideLibrary))
                continue
            }

            // Zero-overwrite, che vale anche in questa direzione. La guardia e' **nostra** e
            // non si delega al solo rifiuto di `moveItem` (misurato `NSCocoaErrorDomain/516`
            // sul pannello Doppioni): due implementazioni della stessa regola divergono, ed
            // e' la regola piu' importante del progetto. Resta comunque un secondo strato
            // sotto (`moveFunction` rifiuta anch'essa una destinazione occupata).
            guard !fm.fileExists(atPath: original.path) else {
                outcome.skipped.append((item, .originalPathOccupied))
                continue
            }

            // Si rilegge e si riverifica PRIMA di spostare: il file nel Cestino puo' essere
            // stato modificato da quando ce l'abbiamo messo. Dimensione e hash dallo stesso
            // descrittore aperto (`sha256Measured`, iniettato come `hashFunction`).
            guard let measured = hashFunction(trashed) else {
                // Un hash illeggibile su un file che ESISTE non e' "e' cambiata" — puo'
                // essere lo scollegamento che sta iniziando proprio ora.
                guard volumeIdentity(libraryRoot) == deviceAtStart else {
                    outcome.stoppedBecauseVolumeVanished = true
                    outcome.notAttempted += items.count - index - 1
                    break
                }
                outcome.skipped.append((item, .unreadableInTrash))
                continue
            }
            guard measured.hash == item.hash, measured.size == item.size else {
                outcome.skipped.append((item, .alteredInTrash))
                continue
            }

            // Ricontrollo del disco SUBITO PRIMA di scrivere: e' la difesa nostra contro un
            // `createDirectory` che ricreerebbe `/Volumes/SSD - Enri/…` sul disco del Mac se
            // il volume sparisse proprio fra la rilettura e la scrittura.
            guard volumeIdentity(libraryRoot) == deviceAtStart else {
                outcome.stoppedBecauseVolumeVanished = true
                outcome.notAttempted += items.count - index - 1
                break
            }

            do {
                // Le cartelle intermedie possono essere state cancellate fra il cestinamento
                // e l'annullamento: senza ricrearle il ripristino fallirebbe proprio nel caso
                // in cui l'utente ha fatto pulizia e vuole tornare indietro.
                try fm.createDirectory(at: original.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try moveFunction(trashed, original)
                outcome.restored.append(item)
                // Foto tornata: se la scrittura del registro fallisce non si ritenta qui, la
                // prossima esecuzione la riconosce comunque via D3.
                try? manifest.markRestored(item, at: now())
            } catch {
                // Mai "gia' fatto": si ricontrolla `st_dev` anche su un fallimento della
                // mossa, non solo su un file mancante.
                guard volumeIdentity(libraryRoot) == deviceAtStart else {
                    outcome.stoppedBecauseVolumeVanished = true
                    outcome.notAttempted += items.count - index - 1
                    break
                }
                outcome.skipped.append((item, .moveFailed((error as NSError).localizedDescription)))
            }
        }
        return outcome
    }
}

/// Cosa dice l'app durante e dopo «Annulla l'ultimo spostamento» (ADR-0009). Logica **pura**,
/// stessa disciplina di `DuplicatesStatus`/`LibraryIndexStatus`: niente "hash", "indice",
/// "registro", "manifest", "volume", "scansione", "entry", "cache", "sha" in nessun testo.
enum TrashRestoreStatus {
    /// Titolo e messaggio della conferma non distruttiva prima di partire (decisione 2 di
    /// Enrico, 2026-09-20): numero di foto e data dello spostamento, in linguaggio comune.
    struct Confirmation {
        let title: String
        let message: String
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = Locale(identifier: "it_IT")
        return f
    }()

    static func confirmation(summary: RestorableBatchSummary) -> Confirmation {
        let data = dateFormatter.string(from: summary.trashedAt)
        return Confirmation(
            title: "Rimettere a posto le foto?",
            message: "Rimetto a posto \(count(summary.pendingCount, "foto spostata", "foto spostate")) "
                + "nel Cestino il \(data). Ogni foto viene ricontrollata prima di essere spostata, "
                + "quindi può volerci qualche minuto. Se al posto di una foto nel frattempo c'è un "
                + "altro file, l'app non lo sovrascrive: la lascia nel Cestino e te lo dice.")
    }

    static func progressLine(done: Int, total: Int) -> String {
        "Rimetto a posto le foto: \(done) di \(total)"
    }

    static let stoppingLine = "Mi fermo dopo la foto in corso…"

    /// Le righe dell'esito, nell'ordine in cui l'utente deve leggerle: prima cosa e' successo
    /// (tutto / interrotto / scollegamento), poi cosa non e' tornato e perche', poi
    /// l'avvertenza sull'elenco. Restano nel pannello (non un alert): cosi' si vedono ancora
    /// riaprendo la finestra.
    static func outcomeLines(_ outcome: RestoreOutcome) -> [DuplicatesStatus.Line] {
        var out: [DuplicatesStatus.Line] = []
        // "Ancora nel Cestino" sono le voci NON tornate: quelle saltate (restano fisicamente
        // li', tranne il caso limite di un Cestino svuotato a mano) piu' quelle mai tentate
        // per uno stop o uno scollegamento. NON `total - restored`: quello conterebbe come
        // "ancora nel Cestino" anche le voci `alreadyInPlace`, che invece sono gia' al posto
        // giusto e non sono mai state nel Cestino durante questa corsa.
        let stillInTrash = outcome.skipped.count + outcome.notAttempted

        if outcome.stoppedBecauseVolumeVanished {
            out.append(DuplicatesStatus.Line(id: "volume-vanished", tone: .warning, text:
                "L'SSD si è scollegato mentre rimettevo a posto le foto: "
                + "\(count(outcome.restored.count, "foto è tornata", "foto sono tornate")) al loro posto, "
                + "\(count(stillInTrash, "altra è ancora", "altre sono ancora")) nel Cestino dell'SSD. "
                + "Ricollegalo e premi di nuovo «Annulla l'ultimo spostamento» per finire."))
        } else if outcome.interrupted {
            out.append(DuplicatesStatus.Line(id: "interrupted", tone: .info, text:
                "Ti sei fermato a metà: "
                + "\(count(outcome.restored.count, "foto è tornata", "foto sono tornate")) al loro posto, "
                + "\(count(stillInTrash, "altra è ancora", "altre sono ancora")) nel Cestino, al sicuro. "
                + "Premi di nuovo «Annulla l'ultimo spostamento» per finire."))
        } else if !outcome.restored.isEmpty {
            out.append(DuplicatesStatus.Line(id: "done", tone: .ok, text:
                "\(count(outcome.restored.count, "foto è tornata", "foto sono tornate")) al loro posto."))
        }

        if !outcome.alreadyInPlace.isEmpty {
            out.append(DuplicatesStatus.Line(id: "already-in-place", tone: .info, text:
                "\(count(outcome.alreadyInPlace.count, "era già al suo posto", "erano già al loro posto")) "
                + "(forse le avevi rimesse tu dal Finder)."))
        }

        if !outcome.skipped.isEmpty {
            let byReason = Dictionary(grouping: outcome.skipped, by: { $0.reason })
            for (index, reason) in Array(byReason.keys).enumerated() {
                let n = byReason[reason]?.count ?? 0
                out.append(DuplicatesStatus.Line(id: "skipped-\(index)", tone: .warning, text:
                    "\(n.formatted()) foto — \(reason.explanation)"))
            }
        }

        // Vero oggi e non detto altrove: ADR-0005 vieta di reinserire a mano le voci
        // nell'elenco, quindi le foto tornate ricompaiono solo al prossimo aggiornamento.
        if !outcome.restored.isEmpty {
            out.append(DuplicatesStatus.Line(id: "reappears", tone: .info, text:
                "Le foto tornate a posto ricompariranno fra le copie doppie dopo il prossimo "
                + "aggiornamento dell'elenco."))
        }

        return out
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

// MARK: - Il motore di cancellazione

/// Perche' un gruppo di doppioni non e' stato smaltito. Ogni caso ha una frase propria: chi
/// vede un gruppo restare nell'elenco dopo aver confermato deve capire se il problema e'
/// suo, del disco o dell'indice — e cosa puo' farci. Stessa disciplina di
/// `RestoreSkipReason`.
nonisolated enum DuplicateTrashSkipReason: Equatable {
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
// `nonisolated`: value type senza stato, restituito da `DuplicateTrasher.run` fuori dal main.
nonisolated struct DuplicateTrashOutcome {
    var trashedFiles: [TrashedItem] = []
    var skippedGroups: [(group: DuplicateGroup, reason: DuplicateTrashSkipReason)] = []
    /// Il volume e' sparito a meta' blocco: si e' fermato tutto, non solo il gruppo.
    var stoppedBecauseVolumeVanished: Bool = false
    /// L'utente ha interrotto. Un blocco parziale e' uno stato legittimo, va detto.
    var interrupted: Bool = false
}

/// Perche' una **corsa** (la sequenza di blocchi di un `DuplicateRunPlan`) si e' fermata
/// prima dell'ultimo blocco pianificato (ADR-0012, D12). Un blocco che finisce con
/// `.volumeVanished` o `.trashFailed` interrompe l'intera catena — sono guasti del volume,
/// e proseguire su altri blocchi moltiplicherebbe il raggio del danno. I gruppi saltati
/// dalla verifica (`DuplicateTrashSkipReason`, diversi da `trashFailed`) **non** fermano
/// niente: su questa libreria sono la normalita' (ADR-0002), e fermarsi li' vorrebbe dire
/// non arrivare mai in fondo a una corsa vera.
nonisolated enum DuplicateRunStopReason: Equatable {
    case volumeVanished
    case trashFailed(displayPath: String, detail: String)
    case interrupted
}

/// L'esito di un'intera corsa: l'aggregazione di tutti i blocchi smaltiti prima che la
/// catena si fermasse — per un guasto vero, per l'utente, o perche' e' arrivata in fondo
/// (`stopReason == nil`). Puro: `BackupRunner` (Task 10) lo costruisce accumulando i
/// `DuplicateTrashOutcome` di ogni blocco via `DuplicateTrasher.run`, invariato.
// `nonisolated`: value type senza stato condiviso.
nonisolated struct DuplicateRunOutcome {
    /// Blocchi del piano arrivati in fondo con successo (smaltiti, non necessariamente senza
    /// gruppi saltati). Non conta il blocco su cui la corsa si e' eventualmente fermata.
    var blocksCompleted: Int = 0
    var totalBlocks: Int = 0
    /// Tutti i file spostati nel Cestino, di ogni blocco della corsa.
    var trashedFiles: [TrashedItem] = []
    /// Tutti i gruppi saltati, di ogni blocco della corsa.
    var skippedGroups: [(group: DuplicateGroup, reason: DuplicateTrashSkipReason)] = []
    var stopReason: DuplicateRunStopReason? = nil
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
    /// Che l'HDD e Cubbit non vengano toccati **va detto qui**, nel pannello, mentre l'utente
    /// sta ancora decidendo — non solo nel riepilogo finale, dove arriva dopo aver gia' scelto.
    ///
    /// Direttiva esplicita di Enrico (2026-09-02): «l'HDD non lo tocchiamo, e' un backup,
    /// voglio che mi tenga tutto, anche i doppioni». Il comportamento era gia' quello — i
    /// mirror non cancellano mai — ma il pannello non lo diceva nel momento in cui serviva
    /// saperlo, cioe' mentre si spuntano i gruppi. Una garanzia che non si vede non
    /// tranquillizza nessuno.
    static func mirrorsUntouchedNote() -> String {
        "Questa operazione tocca soltanto l'SSD. Le copie sull'HDD e su Cubbit restano dove "
            + "sono: il backup continua a conservare tutto, doppioni compresi."
    }

    /// `groupsKnown` (ROADMAP #41, senza valore di default): un chiamante vecchio che non lo
    /// passasse comincerebbe a compilare col comportamento sbagliato — esattamente il modo in
    /// cui questa classe di bug sopravvive (stessa disciplina dei parametri di gate aggiunti
    /// in #34, nessuno dei quali ha un default). `false` significa "l'elenco non e' ancora
    /// stato letto in questa finestra" — durante il caricamento iniziale, o perche' la
    /// finestra e' stata riaperta a meta' di uno spostamento nel Cestino e la lista non si
    /// ricarica finche' non finisce (D4 della spec del 2026-09-20). E' la stessa classe di
    /// errore gia' corretta con `sawNothing` in #31: un elenco che non si conosce e un elenco
    /// costruito e vuoto sono due situazioni opposte, e la seconda non deve mai leggersi al
    /// posto della prima.
    static func headerLine(indexBuilt: Bool, groupsKnown: Bool, groupCount: Int, reclaimableBytes: Int64) -> Line {
        guard indexBuilt else {
            return Line(id: "no-index", tone: .info, text:
                "Non hai ancora creato l'elenco delle foto già salvate sull'SSD. Vai in "
                + "Diagnostica → «\(LibraryIndexCommands.cardTitle)» e crealo da lì, poi torna qui.")
        }
        guard groupsKnown else {
            return Line(id: "groups-unknown", tone: .info, text:
                "L'elenco delle copie doppie non è ancora stato letto in questa finestra.")
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

    /// Quanti gruppi sono stati processati sul totale del blocco (ROADMAP #41), stesso testo
    /// di oggi ma con il plurale corretto — deciso su `total`, non su `done`: un blocco da 4
    /// gruppi comincia dicendo "1 di 4 gruppi", non "1 di 4 gruppo".
    static func trashProgressLine(done: Int, total: Int) -> String {
        "Sposto le copie nel Cestino: \(done) di \(count(total, "gruppo", "gruppi"))"
    }

    /// Gemella di `TrashRestoreStatus.stoppingLine`, riferita al gruppo e non alla foto:
    /// `DuplicateTrasher.run` controlla l'interruzione solo fra un gruppo e l'altro, e un
    /// gruppo in corso puo' contenere file grandi da rileggere e rihashare — non deve
    /// promettere lo stop immediato.
    static let trashStoppingLine = "Mi fermo dopo il gruppo in corso…"

    /// Perche' il bottone di cancellazione e' disattivato adesso. `nil` = niente lo impedisce
    /// da qui (restano comunque le due conferme). Stessa disciplina di `RestoreView`: un
    /// bottone disattivato dice sempre perche', non un semplice grigiore.
    static func trashDisabledReason(isRunning: Bool, isIndexing: Bool, ssdMounted: Bool,
                                    isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                                    isInventorying: Bool, isRepairing: Bool) -> String? {
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
        // Dopo isIndexing, non prima: e' la causa piu' vicina se l'utente sta guardando
        // proprio questa finestra (un secondo spostamento non puo' partire finche' il primo
        // non e' finito — vedi `BackupRunner.isTrashingDuplicates`).
        guard !isTrashingDuplicates else {
            return "Uno spostamento nel Cestino è già in corso: aspetta che finisca."
        }
        // Stesso principio: un annullamento in corso e uno spostamento non possono coesistere
        // (`BackupRunner.beginDuplicateTrashing`), ma la frase deve dirlo se mai capitasse.
        guard !isRestoringFromTrash else {
            return "L'app sta rimettendo a posto le foto dell'ultimo spostamento: aspetta che "
                + "finisca."
        }
        guard !isInventorying else {
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit: aspetta che finisca "
                + "prima di spostare copie nel Cestino."
        }
        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di spostare copie nel Cestino."
        }
        return nil
    }

    /// Perche' «Annulla l'ultimo spostamento» e' disattivato adesso, `nil` se si puo' premere
    /// (ADR-0009). Stessa disciplina di `trashDisabledReason`: un bottone disattivato dice
    /// sempre perche'. `summary` e' `nil` quando non c'e' niente da rimettere a posto — due
    /// frasi diverse a seconda che non si sia MAI spostato niente da qui (`hasEverTrashed ==
    /// false`) o che l'ultimo blocco sia gia' stato rimesso a posto per intero.
    static func undoDisabledReason(ssdMounted: Bool, isRunning: Bool, isIndexing: Bool,
                                   isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                                   summary: RestorableBatchSummary?, hasEverTrashed: Bool,
                                   isInventorying: Bool, isRepairing: Bool) -> String? {
        guard ssdMounted else {
            return "L'SSD non è collegato: le foto da rimettere a posto sono nel suo Cestino. "
                + "Ricollegalo e riprova."
        }
        guard !isTrashingDuplicates else {
            return "Uno spostamento nel Cestino è in corso: aspetta che finisca prima di "
                + "annullare quello precedente."
        }
        guard !isRestoringFromTrash else {
            return "C'è già un annullamento in corso."
        }
        guard !isRunning else {
            return "C'è un backup in corso: aspetta che finisca."
        }
        guard !isIndexing else {
            return "L'elenco delle foto già salvate si sta aggiornando in questo momento: "
                + "aspetta che finisca."
        }
        guard !isInventorying else {
            return "L'app sta facendo l'inventario: aspetta che finisca prima di annullare lo "
                + "spostamento."
        }
        guard !isRepairing else {
            return "L'app sta riparando una foto: aspetta che finisca prima di annullare lo spostamento."
        }
        guard summary != nil else {
            return hasEverTrashed
                ? "L'ultimo spostamento è già stato annullato."
                : "Da qui non hai ancora spostato niente nel Cestino."
        }
        return nil
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

    // MARK: - Righe della corsa (Task 9, ADR-0011/0012, 2026-09-25)

    /// Quanto e' selezionato adesso, rispetto a quanto e' visibile (una regola cartella puo'
    /// nascondere gruppi, ADR-0011) e a quanto esiste in tutto. Mostra SEMPRE sia il visibile
    /// sia il selezionato — mai uno solo dei due, altrimenti "quanti gruppi vedo" e "quanti ne
    /// ho scelti" si confondono. Dice sempre "recuperabili" (potenziale): niente e' stato
    /// ancora spostato qui, la corsa non e' nemmeno cominciata.
    static func selectionLine(visibleGroups: Int, totalGroups: Int, selectedGroups: Int,
                              files: Int, reclaimableBytes: Int64) -> String {
        let visibility = "\(visibleGroups.formatted()) di \(totalGroups.formatted()) gruppi visibili"
        guard selectedGroups > 0 else {
            return "\(visibility): non hai ancora selezionato niente."
        }
        let bytesText = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
        return "\(visibility) · hai selezionato \(count(selectedGroups, "gruppo", "gruppi")), "
            + "\(count(files, "file", "file")), \(bytesText) recuperabili."
    }

    /// Quanti blocchi servira' la corsa e quanto durera' all'incirca (ADR-0012). Un solo
    /// blocco e' il caso comune: la frase non deve nominare "blocco"/"blocchi" in quel caso,
    /// altrimenti l'utente si chiede cosa sia un blocco quando per lui non esiste.
    static func runPlanLine(blockCount: Int, files: Int, estimatedSeconds: Double) -> String {
        let duration = FileSyncer.SyncResult.hms(Int(estimatedSeconds.rounded()))
        guard blockCount > 1 else {
            return "Sposterò \(count(files, "file", "file")) nel Cestino, in circa \(duration)."
        }
        return "Sposterò \(count(files, "file", "file")) nel Cestino in \(count(blockCount, "blocco", "blocchi")), "
            + "in circa \(duration) in totale."
    }

    /// Cosa copre davvero «Annulla l'ultimo spostamento» quando la corsa e' divisa in piu' di
    /// un blocco: solo l'ultimo. L'utente deve saperlo PRIMA di confermare, non scoprirlo dopo
    /// un guasto a meta' corsa. `nil` con un blocco solo: non c'e' niente da spiegare, "annulla"
    /// copre gia' tutto.
    static func undoScopeLine(blockCount: Int, fileCapPerBlock: Int) -> String? {
        guard blockCount > 1 else { return nil }
        return "«Annulla l'ultimo spostamento» rimette a posto solo l'ultimo blocco (fino a "
            + "\(count(fileCapPerBlock, "foto", "foto")) alla volta). Le altre restano nel Cestino "
            + "dell'SSD, da dove puoi comunque recuperarle a mano — e restano comunque anche "
            + "sull'HDD e su Cubbit."
    }

    /// L'avanzamento durante una corsa a piu' blocchi: `filesTotal` e' il totale di TUTTA la
    /// corsa, non del solo blocco in esecuzione — altrimenti la barra ripartirebbe da zero
    /// percepito a ogni blocco, quando invece sta continuando a lavorare sulla stessa corsa.
    static func runProgressLine(blockIndex: Int, blockCount: Int, filesDone: Int, filesTotal: Int) -> String {
        "Blocco \(blockIndex) di \(blockCount) · \(filesDone.formatted()) di \(count(filesTotal, "file", "file"))"
    }

    /// Una categoria stabile per raggruppare i gruppi saltati di un'intera corsa: due gruppi
    /// saltati per lo stesso motivo diventano una riga sola con un conteggio, mai due righe
    /// identiche ne' un "e altri" che ne nasconde qualcuno.
    private static func skipCategoryKey(_ reason: DuplicateTrashSkipReason) -> String {
        switch reason {
        case .contentDisagrees: return "content-disagrees"
        case .unreadable: return "unreadable"
        case .sizeChanged: return "size-changed"
        case .outsideLibrary: return "outside-library"
        case .notMedia: return "not-media"
        case .nothingToTrash: return "nothing-to-trash"
        case .trashFailed: return "trash-failed"
        case .keeperVanished: return "keeper-vanished"
        }
    }

    private static func skipCategoryDescription(_ reason: DuplicateTrashSkipReason) -> String {
        switch reason {
        case .contentDisagrees:
            return "perché il contenuto non era più identico fra le copie"
        case .unreadable:
            return "perché una copia non si è lasciata rileggere"
        case .sizeChanged:
            return "perché una dimensione non coincideva più con quella registrata"
        case .outsideLibrary:
            return "perché un percorso risolveva fuori dalla libreria"
        case .notMedia:
            return "perché non erano foto né video"
        case .nothingToTrash:
            return "perché era rimasta una copia sola"
        case .trashFailed:
            return "perché lo spostamento è fallito"
        case .keeperVanished:
            return "perché la copia da tenere è sparita a metà"
        }
    }

    /// Come si racconta l'esito di un'intera corsa (piu' blocchi, ADR-0012) — non di un
    /// blocco solo, quella resta `outcomeLines`. Il motivo dello stop, se c'e' n'e' uno, viene
    /// prima di tutto; i gruppi saltati sono raggruppati per motivo su tutta la corsa, mai
    /// troncati con "e altri".
    static func runOutcomeLines(_ outcome: DuplicateRunOutcome) -> [Line] {
        var out: [Line] = []

        switch outcome.stopReason {
        case .volumeVanished:
            out.append(Line(id: "run-volume-vanished", tone: .warning, text:
                "L'SSD si è scollegato durante la corsa, quindi mi sono fermato subito: "
                + "\(count(outcome.blocksCompleted, "blocco è stato completato", "blocchi sono stati completati")) "
                + "su \(count(outcome.totalBlocks, "previsto", "previsti")), "
                + "\(count(outcome.trashedFiles.count, "file era già stato spostato nel Cestino", "file erano già stati spostati nel Cestino")) in totale."))
        case .trashFailed(let path, let detail):
            out.append(Line(id: "run-trash-failed", tone: .warning, text:
                "Non è stato possibile spostare \(path) nel Cestino (\(detail)): mi sono fermato qui. "
                + "\(count(outcome.blocksCompleted, "blocco è stato completato", "blocchi sono stati completati")) "
                + "su \(count(outcome.totalBlocks, "previsto", "previsti"))."))
        case .interrupted:
            out.append(Line(id: "run-interrupted", tone: .info, text:
                "Hai fermato tu la corsa: "
                + "\(count(outcome.blocksCompleted, "blocco è stato completato", "blocchi sono stati completati")) "
                + "su \(count(outcome.totalBlocks, "previsto", "previsti"))."))
        case nil:
            out.append(Line(id: "run-completed", tone: .ok, text:
                "Fatto: \(count(outcome.totalBlocks, "blocco completato", "blocchi completati")), "
                + "\(count(outcome.trashedFiles.count, "file spostato nel Cestino", "file spostati nel Cestino"))."))
        }

        if !outcome.skippedGroups.isEmpty {
            var order: [String] = []
            var counts: [String: Int] = [:]
            var descriptions: [String: String] = [:]
            for skipped in outcome.skippedGroups {
                let key = skipCategoryKey(skipped.reason)
                if counts[key] == nil {
                    order.append(key)
                    descriptions[key] = skipCategoryDescription(skipped.reason)
                }
                counts[key, default: 0] += 1
            }
            out.append(Line(id: "run-skipped-count", tone: .warning, text:
                "\(count(outcome.skippedGroups.count, "gruppo non è stato smaltito", "gruppi non sono stati smaltiti")) "
                + "in tutta la corsa: trovi il motivo di ciascuno qui sotto."))
            for key in order {
                out.append(Line(id: "run-skipped-\(key)", tone: .warning, text:
                    "\(count(counts[key] ?? 0, "gruppo", "gruppi")) \(descriptions[key] ?? "")."))
            }
        }

        return out
    }

    // MARK: - Filtri e regola per cartella (Task 11, Step 1-4, ADR-0011)

    /// Mostrato mentre filtro o regola vengono applicati fuori dal main (~5s su tutta la
    /// libreria, misurato — Regola 9 del piano): uno stato, non una barra di progresso, che
    /// il piano vieta esplicitamente di aggiungere per un ricalcolo di questa durata.
    static let applyingLine = "Sto applicando…"

    /// La riga sopra la lista quando il filtro «Tutte le copie nella stessa cartella» è
    /// attivo (spec §2.5, categoria 1): dice **con quale criterio** l'app ha scelto, non
    /// «l'app ha scelto per te», che non è un'informazione. Fissa (nessun parametro): il
    /// criterio non cambia da un gruppo interno all'altro, è sempre lo stesso — data più
    /// vecchia, poi percorso più corto.
    static let internalGroupsCriterionLine =
        "Queste copie stanno tutte nella stessa cartella: tengo quella con la data più vecchia "
        + "e, a parità, quella col percorso più corto. Le copie sono identiche fra loro, quindi "
        + "qualunque delle due si tenga il contenuto resta."

    /// Quanti gruppi copre la regola per cartella attiva, e quanti la toccano ma restano
    /// fuori perché hanno una copia anche in una terza cartella (spec §2.4/§2.5, categoria 3).
    static func ruleCoverageLine(covered: Int, excludedByThirdFolder: Int) -> String {
        let coveredText = "La regola copre \(count(covered, "gruppo", "gruppi"))"
        guard excludedByThirdFolder > 0 else { return "\(coveredText)." }
        let subject = excludedByThirdFolder == 1 ? "gruppo ha" : "gruppi hanno"
        let verb = excludedByThirdFolder == 1 ? "resta" : "restano"
        return "\(coveredText); \(excludedByThirdFolder.formatted()) \(subject) una copia anche "
            + "in un'altra cartella e \(verb) fuori."
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

/// Quando la finestra Doppioni deve rileggere l'elenco all'apertura (ROADMAP #41, D4 della
/// spec del 2026-09-20). L'elenco letto a meta' di uno spostamento nel Cestino e' un bersaglio
/// in movimento — il trasher toglie chiavi dallo stesso elenco mentre rilegge e rihasha sullo
/// stesso volume — ed e' gia' vecchio quando compare: costa il percorso pesante misurato il
/// 2026-09-02 (`DuplicateBatch.init` su migliaia di gruppi) proprio mentre il volume e' occupato
/// da un'altra operazione, e il bottone e' comunque disattivato con il motivo scritto
/// (`DuplicatesStatus.trashDisabledReason`/`undoDisabledReason`). L'elenco arriva da solo
/// quando l'operazione finisce, via `.onChange`.
enum DuplicatesPanelLoad {
    static func shouldLoadOnAppear(isIdle: Bool, isTrashingDuplicates: Bool, isRestoringFromTrash: Bool) -> Bool {
        isIdle && !isTrashingDuplicates && !isRestoringFromTrash
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
// `nonisolated`: `run` deve poter girare fuori dal main thread — la rilettura/rihash di ogni
// membro puo' richiedere minuti su un SSD USB. Solo proprieta' `let`; lo stato di `run` e'
// tutto locale. `run` puo' girare su qualunque thread, uno alla volta per blocco (lo
// garantisce `BackupRunner.isTrashingDuplicates`, Task 4). Vedi ADR-0006.
nonisolated final class DuplicateTrasher: @unchecked Sendable {

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
                                           trashedAt: Date(),
                                           keptPath: decision.keeper.displayPath)
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
                _ = TrashRestorer(libraryRoot: libraryRoot, manifest: manifest).run(trashedInGroup)
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
// `nonisolated`: pura, valutata dall'`init` di `LibraryIndexStore`/`TrashManifestStore`, non
// solo dal MainActor.
nonisolated func isAllowedStoreLocation(_ url: URL,
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
nonisolated func isRunningUnderTests() -> Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// La radice dei file di persistenza che `BackupRunner` apre da solo, senza che nessun test
/// li abbia scelti (BUG-10, 2026-09-28): `libraryIndexStore`/`trashManifestStore`/
/// `trashHistoryStore` sono `lazy var`, valutate da `BackupRunner.init()` — che gira
/// sempre, sia che `RootView` mostri `SetupView` sia `ContentView` — non da un percorso
/// opzionale che un test possa evitare di toccare.
///
/// Quando Xcode avvia l'app come test host di `xcodebuild test`, e' questo stesso
/// `BackupRunner()` reale a partire, e prima di questo fix puntava sempre a
/// `~/Library/Application Support/AppBackupFoto/`, la cartella vera dell'utente — mai una
/// posizione temporanea, a differenza di `storeAllowedRoots`/`isAllowedStoreLocation`, che
/// gia' distinguono i due regimi da #31. Con lo schema 2 del Task 4 dell'inventario, questo
/// ha migrato il `library-index.sqlite` reale di Enrico durante una corsa di test.
///
/// Pura e parametrizzata (default `isRunningUnderTests()`, mai chiamata da un test con
/// l'argomento omesso): sotto test punta a una cartella nella directory temporanea del
/// processo — la stessa gia' ammessa da `isAllowedStoreLocation(_:includingTemporary: true)`,
/// nessuna seconda regola che possa divergere da quella. Non e' isolata per singolo test:
/// tutti i test la condividono per la durata dell'intero test host, ma nessun test la usa
/// direttamente (ognuno apre il proprio store usa-e-getta con un URL esplicito) — serve solo
/// a tenere `BackupRunner`, mai visto da un test, lontano dai file veri.
nonisolated func backupRunnerStoreRoot(isRunningUnderTests: Bool = isRunningUnderTests()) -> URL {
    if isRunningUnderTests {
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppBackupFotoTestHost", isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppBackupFoto", isDirectory: true)
}

/// BUG-10, seconda parte (2026-09-29): il test host ha lo stesso bundle id dell'app, quindi
/// le stesse preferenze vere. Sotto test l'app non avvia Sparkle (rete + scritture nelle
/// preferenze) e non riscrive l'UUID dei volumi dei bookmark all'avvio.
nonisolated func appTouchesUserStateAtLaunch(isRunningUnderTests: Bool = isRunningUnderTests()) -> Bool {
    !isRunningUnderTests
}

private nonisolated func storeAllowedRoots(includingTemporary: Bool) -> [String] {
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
private nonisolated func isPathInside(_ path: String, root: String) -> Bool {
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
/// di background mentre l'import legge dalla sua e il pannello Revisione conta fuori dal
/// main thread (dal 2026-09-19: prima ci tornava per il bug di isolamento, BUG-7) —
/// l'uso non sincronizzato **crasha** dentro `sqlite3_step` (riprodotto, SIGSEGV
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
// `nonisolated`: usata da scansione, import, pannello Doppioni, trasher e conteggio, tutti
// fuori dal MainActor. Sicura per costruzione: TUTTO lo stato mutabile (`db`) si tocca solo
// dentro `queue.sync`; `url` e' `let`; `deinit` ha accesso esclusivo per definizione.
// L'annotazione rende verificabile dal compilatore un invariante gia' scritto sopra
// (CONCORRENZA), non lo cambia. Vedi ADR-0006.
nonisolated final class LibraryIndexStore: @unchecked Sendable {
    /// 2 dal 2026-09-26 (ROADMAP #44): si aggiungono le tabelle dell'inventario.
    static let schemaVersion = 2
    /// L'unica versione diversa da `schemaVersion` da cui si sale SENZA buttare l'elenco:
    /// la 1 ha `entries` identica a quella della 2 (vedi `createSchemaIfNeeded`, ADR-0015).
    static let upgradableFromVersion: Int32 = 1

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
        //
        // Tre casi, e solo tre (ADR-0002, ADR-0015):
        // - versione attesa: niente da fare;
        // - versione 1 (`upgradableFromVersion`): e' lo schema di prima dell'inventario, con
        //   `entries` IDENTICA a quella di oggi. Si tiene l'elenco e si ricreano VUOTE le
        //   tabelle dell'inventario: una build vecchia riaperta su un file nuovo le lascia
        //   orfane, con dati di un giro che nessuno ha piu' controllato;
        // - qualunque altra versione — piu' vecchia, piu' nuova, o zero — significa
        //   "ricostruisci tutto", mai "interpreta al meglio". Buttare l'indice non perde
        //   nulla di originale.
        let onDisk = try userVersionOnDisk()
        if onDisk == Self.upgradableFromVersion {
            try exec(Self.dropInventoryTablesSQL)
        } else if onDisk != Int32(Self.schemaVersion) {
            // `meta` non esiste piu' in questo schema: il DROP serve solo a ripulire i
            // database scritti dalla prima versione della store, che la creava.
            try exec("DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS meta; " + Self.dropInventoryTablesSQL)
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
        try exec(Self.createInventoryTablesSQL)
        try exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    // MARK: Schema dell'inventario (ROADMAP #44, ADR-0015)

    /// Le tre tabelle dell'inventario. Vivono nello STESSO file dell'elenco (decisione 4
    /// della spec del 2026-09-26: si estende l'elenco, non un secondo database), quindi
    /// "Svuota l'elenco" svuota anche l'inventario.
    ///
    /// - `inventory_local`: un file foto/video letto su SSD o HDD. `sha256`/`md5` sono NULL
    ///   se la lettura non e' riuscita (`status` diverso da `ok`); `etag` e' NULL anche per
    ///   i file fino a 64 MiB compresi, che Cubbit riceve con un caricamento unico.
    /// - `inventory_s3`: un oggetto del bucket nel perimetro (foto e video). La chiave
    ///   primaria e' la chiave VERA (`display_key`): su Cubbit maiuscole e minuscole
    ///   contano, e due oggetti che differiscono solo per quello non devono sovrascriversi.
    /// - `inventory_state`: com'e' andata l'ultima lettura di ciascun archivio.
    ///
    /// `run_id` dice in quale giro la riga e' stata vista l'ultima volta. Conta come
    /// "presente" solo una riga del giro registrato in `inventory_state`: le altre sono solo
    /// una memoria per non rileggere i file invariati (e dopo un giro completo si cancellano).
    static let createInventoryTablesSQL = """
    CREATE TABLE IF NOT EXISTS inventory_local (
        archive      TEXT NOT NULL,
        path         TEXT NOT NULL,
        display_path TEXT NOT NULL,
        size         INTEGER NOT NULL,
        mtime        REAL NOT NULL,
        status       TEXT NOT NULL,
        sha256       TEXT,
        md5          TEXT,
        etag         TEXT,
        hashed_at    REAL NOT NULL,
        run_id       INTEGER NOT NULL,
        PRIMARY KEY (archive, path)
    );
    CREATE INDEX IF NOT EXISTS idx_inventory_local_run ON inventory_local(archive, run_id);
    CREATE TABLE IF NOT EXISTS inventory_s3 (
        display_key  TEXT PRIMARY KEY NOT NULL,
        path         TEXT NOT NULL,
        size         INTEGER NOT NULL,
        etag         TEXT,
        run_id       INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_inventory_s3_run ON inventory_s3(run_id);
    CREATE TABLE IF NOT EXISTS inventory_state (
        archive      TEXT PRIMARY KEY NOT NULL,
        run_id       INTEGER NOT NULL,
        complete     INTEGER NOT NULL,
        reason       TEXT,
        unreadable   INTEGER NOT NULL,
        started_at   REAL NOT NULL,
        finished_at  REAL
    );
    """

    static let dropInventoryTablesSQL =
        "DROP TABLE IF EXISTS inventory_local; DROP TABLE IF EXISTS inventory_s3; DROP TABLE IF EXISTS inventory_state;"

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

    /// `MAX(hashed_at)` su tutte le entry, o `nil` su un indice vuoto (Task 12, D15 della
    /// spec 2026-09-24). **Ripiego dichiarato**, non la fonte principale: quella e'
    /// `libraryListLastCompleteReadDefaultsKey`, scritta una volta a lettura finita. Questo
    /// numero serve solo per gli elenchi costruiti prima che quella chiave esistesse, o se
    /// per qualunque motivo manca. E' un limite **inferiore**: una lettura incrementale che
    /// non trova niente di nuovo non tocca nessun `hashed_at`, quindi puo' far sembrare
    /// l'elenco PIU' vecchio di quanto e' — mai il contrario, mai un avviso taciuto.
    func newestHashedAt() throws -> Double? {
        try queue.sync { try newestHashedAtUnsynchronized() }
    }

    // MARK: Inventario (ROADMAP #44, ADR-0015) — API pubblica, serializzata sulla coda

    /// Apre un giro: i tre archivi risultano "in corso", quindi INCOMPLETI, finche' ognuno
    /// non viene chiuso da `finishInventoryArchive`. Se l'app si chiude a meta', resta
    /// scritto che il giro non e' finito: mai un vecchio "completo" che sembra di oggi.
    func beginInventoryRun(runId: Int64, startedAt: Double) throws {
        try queue.sync { try beginInventoryRunUnsynchronized(runId: runId, startedAt: startedAt) }
    }

    /// Le righe di SSD o HDD rimaste dal giro precedente (qualunque `run_id`), per chiave.
    /// Servono solo a non rileggere i file invariati.
    func inventoryLocalRows(_ archive: InventoryArchive) throws -> [String: InventoryLocalFile] {
        try queue.sync { try inventoryLocalRowsUnsynchronized(archive) }
    }

    /// Un lotto di righe di SSD o HDD, in una sola transazione (ADR-0002: un inventario
    /// parziale e' valido in ogni istante).
    func upsertInventoryLocal(_ rows: [InventoryLocalFile], archive: InventoryArchive, runId: Int64) throws {
        try queue.sync { try upsertInventoryLocalUnsynchronized(rows, archive: archive, runId: runId) }
    }

    /// Una pagina di oggetti Cubbit, in una sola transazione.
    func upsertInventoryS3(_ rows: [InventoryS3Object], runId: Int64) throws {
        try queue.sync { try upsertInventoryS3Unsynchronized(rows, runId: runId) }
    }

    /// Chiude la lettura di un archivio. Solo se `complete`, cancella le righe di quel
    /// archivio viste in un giro precedente e non in questo: e' l'unico momento in cui
    /// "non l'ho visto" vuol dire "non c'e' piu'" (stessa regola di `LibraryIndexer`).
    func finishInventoryArchive(_ archive: InventoryArchive, runId: Int64, complete: Bool,
                                reason: InventoryIncompleteReason?, unreadable: Int,
                                finishedAt: Double) throws {
        try queue.sync {
            try finishInventoryArchiveUnsynchronized(archive, runId: runId, complete: complete,
                                                     reason: reason, unreadable: unreadable,
                                                     finishedAt: finishedAt)
        }
    }

    /// Lo stato dell'ultima lettura di ogni archivio. Un archivio mai letto non compare.
    func inventoryStates() throws -> [InventoryArchive: InventoryArchiveState] {
        try queue.sync { try inventoryStatesUnsynchronized() }
    }

    /// Tutto quello che serve a `InventoryClassifier`: per ogni archivio, SOLO le righe del
    /// giro registrato nel suo stato. In ordine di percorso, cosi' il risultato non dipende
    /// dall'ordine in cui SQLite restituisce le righe.
    func inventorySnapshot() throws -> InventorySnapshot {
        try queue.sync { try inventorySnapshotUnsynchronized() }
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

    private func newestHashedAtUnsynchronized() throws -> Double? {
        let stmt = try prepare("SELECT MAX(hashed_at) FROM entries;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt) else { throw sqlError() }
        // MAX su una tabella vuota restituisce NULL, non un errore: si legge il TIPO della
        // colonna, non un valore surrogato (0.0) che si confonderebbe con una data vera
        // (1 gennaio 1970).
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    // MARK: Inventario — implementazioni (gia' sulla coda)

    /// Come `bindText`, ma un valore assente diventa NULL di proposito (non per un bind fallito).
    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        guard let value else {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqlError() }
            return
        }
        try bindText(stmt, index, value)
    }

    private func optionalText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let p = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: p)
    }

    private func beginInventoryRunUnsynchronized(runId: Int64, startedAt: Double) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_state(archive,run_id,complete,reason,unreadable,started_at,finished_at)
            VALUES(?,?,0,?,0,?,NULL);
            """)
            defer { sqlite3_finalize(stmt) }
            for archive in InventoryArchive.allCases {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, archive.rawValue)
                try bindInt64(stmt, 2, runId)
                try bindText(stmt, 3, InventoryIncompleteReason.running.rawValue)
                try bindDouble(stmt, 4, startedAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func readLocalRow(_ stmt: OpaquePointer?) -> InventoryLocalFile? {
        // Stessa guardia nil di `readEntry`: una riga malformata si salta, non si interpreta.
        guard let path = sqlite3_column_text(stmt, 0),
              let display = sqlite3_column_text(stmt, 1),
              let statusText = sqlite3_column_text(stmt, 4),
              let status = InventoryReadStatus(rawValue: String(cString: statusText)) else { return nil }
        let size = sqlite3_column_int64(stmt, 2)
        var digest: ContentDigest? = nil
        if status == .ok {
            // Una riga "ok" senza impronte non e' una riga ok: si legge come illeggibile,
            // cosi' il giro dopo la rilegge invece di fidarsi.
            guard let sha = optionalText(stmt, 5), let md5 = optionalText(stmt, 6) else {
                return InventoryLocalFile(key: String(cString: path), displayPath: String(cString: display),
                                          size: size, mtime: sqlite3_column_double(stmt, 3),
                                          status: .unreadable, digest: nil,
                                          hashedAt: sqlite3_column_double(stmt, 8))
            }
            let etags = ContentDigest.splitStoredETagColumn(optionalText(stmt, 7))
            digest = ContentDigest(size: size, sha256: sha, md5: md5, multipartETag: etags.primary,
                                   alternativeMultipartETags: etags.alternatives)
        }
        return InventoryLocalFile(key: String(cString: path), displayPath: String(cString: display),
                                  size: size, mtime: sqlite3_column_double(stmt, 3),
                                  status: status, digest: digest,
                                  hashedAt: sqlite3_column_double(stmt, 8))
    }

    private static let localColumns = "path,display_path,size,mtime,status,sha256,md5,etag,hashed_at"

    private func inventoryLocalRowsUnsynchronized(_ archive: InventoryArchive) throws -> [String: InventoryLocalFile] {
        let stmt = try prepare("SELECT \(Self.localColumns) FROM inventory_local WHERE archive=?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, 1, archive.rawValue)
        var out: [String: InventoryLocalFile] = [:]
        while try stepRow(stmt) {
            if let row = readLocalRow(stmt) { out[row.key] = row }
        }
        return out
    }

    private func upsertInventoryLocalUnsynchronized(_ rows: [InventoryLocalFile], archive: InventoryArchive,
                                                    runId: Int64) throws {
        precondition(archive != .s3, "inventory_local contiene solo SSD e HDD")
        guard !rows.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_local(archive,path,display_path,size,mtime,status,sha256,md5,etag,hashed_at,run_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, archive.rawValue)
                try bindText(stmt, 2, r.key)
                try bindText(stmt, 3, r.displayPath)
                try bindInt64(stmt, 4, r.size)
                try bindDouble(stmt, 5, r.mtime)
                try bindText(stmt, 6, r.status.rawValue)
                try bindOptionalText(stmt, 7, r.digest?.sha256)
                try bindOptionalText(stmt, 8, r.digest?.md5)
                try bindOptionalText(stmt, 9, r.digest?.storedETagColumn)
                try bindDouble(stmt, 10, r.hashedAt)
                try bindInt64(stmt, 11, runId)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func upsertInventoryS3Unsynchronized(_ rows: [InventoryS3Object], runId: Int64) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO inventory_s3(display_key,path,size,etag,run_id) VALUES(?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                try bindText(stmt, 1, r.displayKey)
                try bindText(stmt, 2, r.key)
                try bindInt64(stmt, 3, r.size)
                try bindOptionalText(stmt, 4, r.etag)
                try bindInt64(stmt, 5, runId)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func finishInventoryArchiveUnsynchronized(_ archive: InventoryArchive, runId: Int64, complete: Bool,
                                                      reason: InventoryIncompleteReason?, unreadable: Int,
                                                      finishedAt: Double) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            let stmt = try prepare("""
            UPDATE inventory_state SET complete=?, reason=?, unreadable=?, finished_at=?
            WHERE archive=? AND run_id=?;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, 1, complete ? 1 : 0)
            try bindOptionalText(stmt, 2, complete ? nil : (reason ?? .interrupted).rawValue)
            try bindInt64(stmt, 3, Int64(unreadable))
            try bindDouble(stmt, 4, finishedAt)
            try bindText(stmt, 5, archive.rawValue)
            try bindInt64(stmt, 6, runId)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            // Nessuna riga aggiornata = non e' il giro aperto (un giro vecchio arrivato tardi):
            // non si cancella niente, altrimenti sparirebbero le righe del giro vero.
            if complete && sqlite3_changes(db) == 1 {
                let sql = archive == .s3
                    ? "DELETE FROM inventory_s3 WHERE run_id<>?;"
                    : "DELETE FROM inventory_local WHERE archive=? AND run_id<>?;"
                let del = try prepare(sql)
                defer { sqlite3_finalize(del) }
                if archive == .s3 {
                    try bindInt64(del, 1, runId)
                } else {
                    try bindText(del, 1, archive.rawValue)
                    try bindInt64(del, 2, runId)
                }
                guard sqlite3_step(del) == SQLITE_DONE else { throw sqlError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func inventoryStatesUnsynchronized() throws -> [InventoryArchive: InventoryArchiveState] {
        let stmt = try prepare("""
        SELECT archive,run_id,complete,reason,unreadable,started_at,finished_at FROM inventory_state;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [InventoryArchive: InventoryArchiveState] = [:]
        while try stepRow(stmt) {
            guard let a = sqlite3_column_text(stmt, 0),
                  let archive = InventoryArchive(rawValue: String(cString: a)) else { continue }
            let finished = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            // "Completo" vale solo con una data di fine: un giro mai chiuso non e' completo.
            let complete = sqlite3_column_int64(stmt, 2) == 1 && finished != nil
            // Un motivo che questa versione non conosce non rende l'archivio completo: resta
            // incompleto, col motivo generico.
            let reason = optionalText(stmt, 3).map { InventoryIncompleteReason(rawValue: $0) ?? .interrupted }
            out[archive] = InventoryArchiveState(archive: archive, runId: sqlite3_column_int64(stmt, 1),
                                                 complete: complete,
                                                 reason: complete ? nil : (reason ?? .interrupted),
                                                 unreadable: Int(sqlite3_column_int64(stmt, 4)),
                                                 startedAt: sqlite3_column_double(stmt, 5),
                                                 finishedAt: finished)
        }
        return out
    }

    private func inventorySnapshotUnsynchronized() throws -> InventorySnapshot {
        let states = try inventoryStatesUnsynchronized()
        var snap = InventorySnapshot(states: states)
        for archive in [InventoryArchive.ssd, .hdd] {
            guard let state = states[archive] else { continue }
            let stmt = try prepare("""
            SELECT \(Self.localColumns) FROM inventory_local WHERE archive=? AND run_id=? ORDER BY path;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, archive.rawValue)
            try bindInt64(stmt, 2, state.runId)
            var rows: [InventoryLocalFile] = []
            while try stepRow(stmt) {
                if let row = readLocalRow(stmt) { rows.append(row) }
            }
            if archive == .ssd { snap.ssd = rows } else { snap.hdd = rows }
        }
        if let state = states[.s3] {
            let stmt = try prepare("""
            SELECT display_key,path,size,etag FROM inventory_s3 WHERE run_id=? ORDER BY display_key;
            """)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, 1, state.runId)
            while try stepRow(stmt) {
                guard let display = sqlite3_column_text(stmt, 0),
                      let path = sqlite3_column_text(stmt, 1) else { continue }
                snap.s3.append(InventoryS3Object(key: String(cString: path), displayKey: String(cString: display),
                                                 size: sqlite3_column_int64(stmt, 2), etag: optionalText(stmt, 3)))
            }
        }
        return snap
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
// `nonisolated`: `store`/`fm` sono `let` (`FileManager.default` e' thread-safe per queste
// operazioni); `cancelled` passa gia' da `cancelLock`; tutto il resto dello stato di una
// scansione e' LOCALE a `scan`. Il contratto "una scansione per volta" resta, ed e'
// semantico (consumo del cancel), non di memoria: lo garantisce `BackupRunner.isIndexing`
// sul MainActor. Vedi ADR-0006.
nonisolated final class LibraryIndexer: @unchecked Sendable {
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
              progressEvery: Int = 250,
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
        // `total` = voci nell'elenco in questo momento (passo 2 del backup, 2026-09-19):
        // senza questa riga il primo avanzamento farebbe leggere "0 foto" alla card,
        // perche' `total` restava a 0 finche' non si svuotava il primo blocco.
        progress.total = knownKeys.count

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

            // Avanzamento anche sui file invariati (2026-09-19, passo 2 del backup): i blocchi si
            // riempiono solo con file da rileggere, e dopo un backup normale quasi nessuno lo e' —
            // senza questa riga la barra resterebbe ferma per minuti. Non scrive e non decide niente.
            if progressEvery > 0 && progress.scanned % progressEvery == 0 { onProgress(progress) }

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

// MARK: - Inventario certificato: il modello dei dati (ROADMAP #44, ADR-0015)
//
// Tutti value type senza stato condiviso: `nonisolated` perche' li producono e li leggono lo
// scanner, il lettore di Cubbit e il confronto, fuori dal main (ADR-0006).

/// I tre posti in cui stanno le foto. L'ordine (`rank`) e' quello in cui la finestra li nomina.
nonisolated enum InventoryArchive: String, CaseIterable, Sendable, Comparable {
    case ssd, hdd, s3

    var rank: Int {
        switch self {
        case .ssd: return 0
        case .hdd: return 1
        case .s3: return 2
        }
    }

    static func < (a: InventoryArchive, b: InventoryArchive) -> Bool { a.rank < b.rank }
}

/// Com'e' andata la lettura di un file su SSD o HDD.
nonisolated enum InventoryReadStatus: String, Sendable {
    case ok
    /// Non si e' aperto o la lettura si e' interrotta (permessi, errore del disco, disco sparito).
    case unreadable
    /// Letto, ma e' cambiato mentre lo si leggeva: le impronte non valgono niente.
    case changedWhileReading
}

/// Un file foto o video letto su SSD o HDD.
nonisolated struct InventoryLocalFile: Equatable, Sendable {
    /// `normalizedIndexKey` del percorso relativo alla radice del disco: la stessa chiave
    /// dell'elenco dei Doppioni, cosi' "stesso percorso" vuol dire la stessa cosa ovunque.
    let key: String
    /// Il percorso com'e' sul disco, da mostrare.
    let displayPath: String
    let size: Int64
    /// Data di modifica letta PRIMA della lettura del contenuto (vedi `InventoryScanner`).
    let mtime: Double
    let status: InventoryReadStatus
    /// `nil` se `status != .ok`.
    let digest: ContentDigest?
    /// Quando le impronte sono state calcolate: serve alla regola anti-racy di `indexEntryVerdict`.
    let hashedAt: Double
}

/// Un oggetto del bucket, nel perimetro (foto e video).
nonisolated struct InventoryS3Object: Equatable, Sendable {
    /// `normalizedIndexKey` della chiave: per il confronto dei percorsi con SSD e HDD.
    let key: String
    /// La chiave vera, con maiuscole e minuscole: su Cubbit contano.
    let displayKey: String
    let size: Int64
    /// L'ETag come arriva dalla lista (virgolette comprese); `nil` se la lista non lo dava.
    let etag: String?
}

/// Perche' la lettura di un archivio non vale come completa.
nonisolated enum InventoryIncompleteReason: String, Sendable {
    /// Scritto all'inizio di ogni giro: resta se l'app si chiude prima della fine.
    case running
    /// Il giro si e' fermato prima di arrivare a questo archivio.
    case notReached
    /// Fermato da «Interrompi» o dallo scollegamento di un disco qualsiasi.
    case interrupted
    case volumeVanished
    case foldersUnreadable
    case filesUnreadable
    /// Zero foto viste dove la volta prima ce n'erano.
    case sawNothing
    case listingFailed
    case listingMalformed
    case couldNotSave
}

/// Com'e' andata l'ultima lettura di un archivio.
nonisolated struct InventoryArchiveState: Equatable, Sendable {
    let archive: InventoryArchive
    let runId: Int64
    /// Vero SOLO se la lettura e' arrivata in fondo senza nessun problema. Finche' e' falso,
    /// da questo archivio non si dichiara assente niente (la regola «incompleto non e' assente»).
    let complete: Bool
    /// `nil` se completo.
    let reason: InventoryIncompleteReason?
    /// File che non si sono lasciati leggere per intero.
    let unreadable: Int
    let startedAt: Double
    /// `nil` finche' la lettura di questo archivio non e' finita.
    let finishedAt: Double?
}

/// Quello che il confronto riceve: per ogni archivio le righe dell'ultimo giro, e i tre stati.
nonisolated struct InventorySnapshot: Equatable, Sendable {
    var ssd: [InventoryLocalFile] = []
    var hdd: [InventoryLocalFile] = []
    var s3: [InventoryS3Object] = []
    var states: [InventoryArchive: InventoryArchiveState] = [:]

    func isComplete(_ archive: InventoryArchive) -> Bool { states[archive]?.complete == true }
}

/// Com'e' andata la lettura di SSD o HDD per l'inventario.
nonisolated struct InventoryScanReport: Equatable, Sendable {
    /// Foto e video visti (nel perimetro di `IndexableKind`).
    var scanned = 0
    /// Letti davvero in questo giro.
    var reread = 0
    /// Impronte riprese dal giro precedente: dimensione e data invariate.
    var reused = 0
    /// File che non si sono lasciati leggere per intero, o cambiati mentre li si leggeva.
    var unreadableFiles = 0
    /// Cartelle che non si sono lasciate aprire (contate dall'`errorHandler`).
    var unreadableFolders = 0
    /// File il cui percorso canonico non ricade sotto la radice (non raggiungibile oggi).
    var outsideRoot = 0
    var volumeVanished = false
    var cancelled = false
    /// Zero file visti, ma il giro precedente ne aveva: "non ho trovato niente" non e'
    /// "non c'e' niente".
    var sawNothing = false

    var isComplete: Bool { incompleteReason == nil }

    /// Il motivo principale per cui la lettura non vale come completa, `nil` se e' completa.
    /// Precedenza: dal guasto piu' grave (il disco e' sparito) al piu' circoscritto.
    var incompleteReason: InventoryIncompleteReason? {
        if volumeVanished { return .volumeVanished }
        if cancelled { return .interrupted }
        if unreadableFolders > 0 { return .foldersUnreadable }
        if unreadableFiles > 0 { return .filesUnreadable }
        if sawNothing { return .sawNothing }
        return nil
    }
}

/// Legge SSD o HDD per l'inventario: stessa traversata di `LibraryIndexer.scan` (stesse
/// esclusioni, stesso `.skipsHiddenFiles`, stesso filtro `IndexableKind`, stesso calcolo del
/// percorso relativo per componenti, stesso `st_dev` inizio/fine, stesso `errorHandler` che
/// conta), ma scrive nelle tabelle dell'inventario e calcola tre impronte per file in una
/// lettura (`ContentHasher`). NON e' `LibraryIndexer` riusato: vedi ADR-0015 per il perche',
/// e `InventoryScannerTests.testSeesExactlyTheFilesTheListSees` per la guardia contro le
/// divergenze fra i due.
///
/// Sola lettura sul volume: non scrive, non sposta, non cancella niente.
// `nonisolated`: `store`, `cancelFlag` e `fm` sono `let` (`LibraryIndexStore` serializza da
// se' sulla propria coda, `CancelFlag` sta dietro il proprio lock, `FileManager.default` e'
// thread-safe per queste operazioni); tutto lo stato di un giro e' LOCALE a `scan`. Vedi ADR-0006.
nonisolated final class InventoryScanner: @unchecked Sendable {
    private let store: LibraryIndexStore
    private let cancelFlag: CancelFlag
    private let fm = FileManager.default

    /// Stessa scatola di `LibraryIndexer.TraversalFailures`: l'`errorHandler` e' `@escaping` e
    /// viene chiamato in modo sincrono dal thread che chiama `nextObject()`, cioe' questo.
    private final class TraversalFailures { var count = 0 }

    init(store: LibraryIndexStore, cancelFlag: CancelFlag) {
        self.store = store
        self.cancelFlag = cancelFlag
    }

    @discardableResult
    func scan(root: URL, archive: InventoryArchive, runId: Int64, batchSize: Int = 200,
              progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos,
              onProgress: @escaping (InventoryScanReport) -> Void = { _ in }) throws -> InventoryScanReport {
        precondition(archive != .s3, "InventoryScanner legge solo SSD e HDD")
        var report = InventoryScanReport()
        var throttle = ProgressThrottle(minimumIntervalNanos: progressIntervalNanos)
        var batch: [InventoryLocalFile] = []
        let failures = TraversalFailures()
        let previous = try store.inventoryLocalRows(archive)

        let deviceAtStart = deviceIdentifier(of: root)
        guard deviceAtStart != nil else {
            // Disco assente prima di partire: un disco scollegato non e' mai un disco vuoto.
            report.volumeVanished = true
            onProgress(report)
            return report
        }
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in
                                                 failures.count += 1
                                                 return true
                                             }) else {
            report.unreadableFolders = 1
            onProgress(report)
            return report
        }
        let rootComponents = canonicalPathComponents(of: root)
        var volumeVanished = false

        func flush() throws {
            guard !batch.isEmpty else { return }
            try store.upsertInventoryLocal(batch, archive: archive, runId: runId)
            batch.removeAll(keepingCapacity: true)
            // Uscita anticipata opportunistica, come in `LibraryIndexer`: la garanzia vera e'
            // il controllo dopo il ciclo.
            if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }
        }

        walk: while let url = enumerator.nextObject() as? URL {
            if cancelFlag.isCancelled { break }
            if LibraryExclusions.shouldExclude(url) { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard IndexableKind.of(url: url) != .notIndexable else { continue }

            let fileComponents = canonicalPathComponents(of: url)
            guard fileComponents.count > rootComponents.count,
                  Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
                report.outsideRoot += 1
                continue
            }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            report.scanned += 1
            let key = normalizedIndexKey(relative)

            // Senza dimensione o data non c'e' niente da confrontare: il file non entra, e
            // l'archivio risulta incompleto (e' un file che c'e' e che non conosciamo).
            guard let fileSize = values?.fileSize, let modified = values?.contentModificationDate else {
                report.unreadableFiles += 1
                continue
            }
            let size = Int64(fileSize)
            // La data si legge PRIMA della lettura, come in `LibraryIndexer`: un file che cambia
            // mentre lo si legge risulta cambiato al giro dopo, invece che invariato per sempre.
            let mtime = modified.timeIntervalSince1970

            if let old = previous[key], old.status == .ok, let digest = old.digest, !digest.needsAlternativeETags {
                let verdict = indexEntryVerdict(storedSize: old.size, storedMTime: old.mtime,
                                                storedHashedAt: old.hashedAt,
                                                currentSize: size, currentMTime: mtime)
                if verdict == .fresh || verdict == .timezoneShift {
                    batch.append(InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                                    status: .ok, digest: digest, hashedAt: old.hashedAt))
                    report.reused += 1
                    if batch.count >= batchSize { try flush(); if volumeVanished { break walk } }
                    if throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds, isFinal: false) {
                        onProgress(report)
                    }
                    continue
                }
            }

            let now = Date().timeIntervalSince1970
            let row: InventoryLocalFile
            switch ContentHasher.digestFile(at: url, isCancelled: { self.cancelFlag.isCancelled }) {
            case .digest(let digest) where digest.size == size:
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .ok, digest: digest, hashedAt: now)
                report.reread += 1
            case .digest, .changedWhileReading:
                // Letto per intero ma con una dimensione diversa da quella della cartella, o
                // cambiato durante la lettura: le impronte non valgono niente.
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .changedWhileReading, digest: nil, hashedAt: now)
                report.unreadableFiles += 1
            case .unreadable:
                row = InventoryLocalFile(key: key, displayPath: relative, size: size, mtime: mtime,
                                         status: .unreadable, digest: nil, hashedAt: now)
                report.unreadableFiles += 1
            case .cancelled:
                break walk
            }
            batch.append(row)
            if batch.count >= batchSize { try flush(); if volumeVanished { break walk } }
            if throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds, isFinal: false) {
                onProgress(report)
            }
        }

        try flush()
        if deviceIdentifier(of: root) != deviceAtStart { volumeVanished = true }
        report.unreadableFolders = failures.count
        report.volumeVanished = volumeVanished
        report.cancelled = cancelFlag.isCancelled
        report.sawNothing = report.scanned == 0 && !previous.isEmpty
        onProgress(report)
        return report
    }
}

/// Com'e' andata la lettura dell'elenco di Cubbit per l'inventario.
nonisolated struct CubbitReadReport: Equatable, Sendable {
    var pages = 0
    /// Oggetti elencati, di qualunque tipo.
    var objectsListed = 0
    /// Oggetti nel perimetro (foto e video), quelli salvati.
    var objectsKept = 0
    /// Voci della lista senza chiave o senza dimensione leggibile.
    var malformedEntries = 0
    /// La lista dice "ce n'e' ancora" ma non dice da dove ripartire.
    var truncatedWithoutToken = false
    /// L'ultima pagina e' arrivata: la lista e' finita davvero.
    var reachedEnd = false
    var cancelled = false
    /// Testo dell'errore di rete o di salvataggio, per il registro. Mai mostrato cosi' com'e'.
    var failure: String? = nil
    var couldNotSave = false

    var isComplete: Bool { incompleteReason == nil }

    var incompleteReason: InventoryIncompleteReason? {
        if couldNotSave { return .couldNotSave }
        if cancelled { return .interrupted }
        if failure != nil { return .listingFailed }
        if malformedEntries > 0 || truncatedWithoutToken { return .listingMalformed }
        if !reachedEnd { return .interrupted }
        return nil
    }
}

/// Foto e video: lo stesso perimetro dei dischi, applicato alle chiavi di Cubbit.
// `nonisolated`: pura, chiamata dal lettore di Cubbit fuori dal main.
nonisolated enum InventoryPerimeter {
    /// Vero se un oggetto con questa chiave sarebbe stato letto dallo scanner dei dischi:
    /// nessuna componente nascosta (`.skipsHiddenFiles`, e quindi anche i `._` AppleDouble),
    /// nessuna componente esclusa da `LibraryExclusions.isExcludedName` (quindi nemmeno la
    /// cartella di quarantena della riparazione, ADR-0016), e `IndexableKind` foto o video.
    static func includesS3Key(_ key: String) -> Bool {
        let components = key.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !key.hasSuffix("/") else { return false }
        for c in components where c.hasPrefix(".") || LibraryExclusions.isExcludedName(String(c)) {
            return false
        }
        return IndexableKind.of(url: URL(fileURLWithPath: key)) != .notIndexable
    }
}

/// Legge l'elenco del bucket con l'ETag di ogni oggetto e lo salva a pagine. Nessun download,
/// nessuna scrittura su Cubbit: solo `ListObjectsV2`, la stessa richiesta di `S3Syncer.listPage`.
// `nonisolated`: `store` e `cancelFlag` sono `let`, custoditi rispettivamente dalla coda
// seriale dello store e dal lock di `CancelFlag`; il resto e' locale a `read`. `read` e'
// `@concurrent` (regola del progetto per le funzioni di fondo `async`, ADR-0006): senza, con
// `NonisolatedNonsendingByDefault` girerebbe sul thread di chi la chiama.
nonisolated final class InventoryCubbitReader: @unchecked Sendable {
    private let store: LibraryIndexStore
    private let cancelFlag: CancelFlag

    init(store: LibraryIndexStore, cancelFlag: CancelFlag) {
        self.store = store
        self.cancelFlag = cancelFlag
    }

    @concurrent
    func read(runId: Int64,
              fetchPage: @escaping @Sendable (String?) async throws -> String,
              onProgress: @escaping @Sendable (CubbitReadReport) -> Void = { _ in }) async -> CubbitReadReport {
        var report = CubbitReadReport()
        var token: String? = nil
        while true {
            if cancelFlag.isCancelled { report.cancelled = true; break }
            let xml: String
            do {
                xml = try await fetchPage(token)
            } catch {
                report.failure = error.localizedDescription
                break
            }
            let page = S3Syncer.parseListPage(xml)
            report.pages += 1
            report.objectsListed += page.objects.count
            report.malformedEntries += page.malformedEntries
            let rows = page.objects
                .filter { InventoryPerimeter.includesS3Key($0.key) }
                .map { InventoryS3Object(key: normalizedIndexKey($0.key), displayKey: $0.key,
                                         size: $0.size, etag: $0.etag) }
            do {
                try store.upsertInventoryS3(rows, runId: runId)
            } catch {
                report.couldNotSave = true
                report.failure = error.localizedDescription
                break
            }
            report.objectsKept += rows.count
            onProgress(report)
            guard page.isTruncated else { report.reachedEnd = true; break }
            guard let next = page.nextToken else { report.truncatedWithoutToken = true; break }
            token = next
        }
        onProgress(report)
        return report
    }
}

/// In quale categoria cade un contenuto. L'ordine dei casi e' la PRECEDENZA della spec
/// (❗ > 🔎 > ⚠️ > ✅), con «non si puo' ancora dire» per ultimo: non e' un esito, e' il posto
/// dei contenuti su cui la regola «incompleto non e' assente» sospende il giudizio.
nonisolated enum InventoryCategory: String, CaseIterable, Sendable {
    case toCheck
    case onlyOutsideSSD
    case missingSomewhere
    case safe
    case undetermined
}

nonisolated enum InventoryCheckReason: String, Hashable, Sendable {
    /// Stesso percorso relativo, contenuto diverso, fra due archivi.
    case samePathDifferentContent
    /// Un oggetto Cubbit che non si riesce a confrontare senza scaricarlo — lui, e la foto
    /// che sta allo stesso percorso su SSD o HDD.
    case cubbitNotCertifiable
}

/// Un contenuto (non un file): tutte le copie con la stessa impronta, nei tre archivi.
nonisolated struct InventoryItem: Equatable, Sendable, Identifiable {
    /// L'SHA256; `md5:<md5>` per un contenuto che c'e' solo su Cubbit, riconosciuto dal suo
    /// MD5; `s3:<chiave>` per un oggetto Cubbit non certificabile (contenuto sconosciuto).
    let id: String
    let category: InventoryCategory
    let size: Int64
    let presentOn: Set<InventoryArchive>
    /// Archivi COMPLETI da cui manca: solo qui si puo' dire «manca».
    let missingFrom: Set<InventoryArchive>
    /// Archivi incompleti da cui non risulta: «non si sa ancora».
    let unknownOn: Set<InventoryArchive>
    let checkReasons: Set<InventoryCheckReason>
    /// Un percorso da mostrare: quello dell'SSD se c'e', poi HDD, poi Cubbit; a parita', il
    /// primo in ordine alfabetico. Cosi' il risultato non dipende dall'ordine delle righe.
    let exampleArchive: InventoryArchive
    let examplePath: String
}

/// I numeri in testa alla finestra, per archivio.
nonisolated struct InventoryArchiveStats: Equatable, Sendable {
    /// File foto e video letti (anche quelli illeggibili: ci sono, anche se non si sa cosa
    /// contengono) o oggetti Cubbit nel perimetro.
    var files = 0
    /// Copie in piu' dello stesso contenuto nello stesso archivio.
    var extraCopies = 0
    /// Spazio che si libererebbe tenendone una sola per contenuto.
    var reclaimableBytes: Int64 = 0
}

/// Dai tre elenchi alle categorie. Logica PURA: nessun disco, nessuna rete, nessun database.
/// E' il pezzo su cui i progetti 2-4 decideranno copie e cancellazioni (sempre rileggendo i
/// file prima, ADR-0005), quindi e' il piu' testato (`InventoryClassifierTests`).
///
/// Due confronti, come nella spec:
/// 1. **per contenuto** — SHA256 fra SSD e HDD; verso Cubbit con l'ETag (`S3ETagMatcher`),
///    solo contro file letti della stessa dimensione;
/// 2. **per percorso** — stesso percorso relativo (chiave normalizzata) su due archivi con
///    contenuto diverso: ❗ per entrambi i contenuti.
///
/// La regola che conta di piu': si dice «manca da X» solo se X e' stato letto per intero.
nonisolated enum InventoryClassifier {
    private struct Content {
        var size: Int64
        var present: Set<InventoryArchive> = []
        var reasons: Set<InventoryCheckReason> = []
        var example: (archive: InventoryArchive, path: String)
    }

    static func classify(_ s: InventorySnapshot) -> (items: [InventoryItem], stats: [InventoryArchive: InventoryArchiveStats]) {
        var contents: [String: Content] = [:]
        var stats: [InventoryArchive: InventoryArchiveStats] = [.ssd: .init(), .hdd: .init(), .s3: .init()]
        var copies: [InventoryArchive: [String: Int]] = [.ssd: [:], .hdd: [:], .s3: [:]]
        var byPath: [String: [InventoryArchive: Set<String>]] = [:]
        var uncertainS3Paths = Set<String>()

        func record(id: String, size: Int64, archive: InventoryArchive, key: String, displayPath: String) {
            if var c = contents[id] {
                c.present.insert(archive)
                if (archive, displayPath) < (c.example.archive, c.example.path) { c.example = (archive, displayPath) }
                contents[id] = c
            } else {
                contents[id] = Content(size: size, present: [archive], example: (archive, displayPath))
            }
            copies[archive]![id, default: 0] += 1
            byPath[key, default: [:]][archive, default: []].insert(id)
        }

        // 1. SSD e HDD: un contenuto per SHA256. Un file illeggibile conta come file, non come
        //    contenuto, e non puo' certificare niente su Cubbit.
        var candidatesBySize: [Int64: [S3ETagMatcher.Candidate]] = [:]
        var knownSha = Set<String>()
        for (archive, files) in [(InventoryArchive.ssd, s.ssd), (.hdd, s.hdd)] {
            for f in files {
                stats[archive]!.files += 1
                guard f.status == .ok, let d = f.digest else { continue }
                record(id: d.sha256, size: f.size, archive: archive, key: f.key, displayPath: f.displayPath)
                if knownSha.insert(d.sha256).inserted {
                    candidatesBySize[f.size, default: []].append(
                        .init(size: f.size, sha256: d.sha256, md5: d.md5, multipartETag: d.multipartETag,
                              alternativeETags: d.alternativeMultipartETags))
                }
            }
        }

        // 2. Cubbit: certificato, riconosciuto dal solo MD5, o non certificabile.
        for o in s.s3 {
            stats[.s3]!.files += 1
            switch S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: candidatesBySize[o.size] ?? []) {
            case .certified(let sha):
                record(id: sha, size: o.size, archive: .s3, key: o.key, displayPath: o.displayKey)
            case .identifiedOnlyByMD5(let md5):
                record(id: "md5:" + md5, size: o.size, archive: .s3, key: o.key, displayPath: o.displayKey)
            case .notCertifiable:
                contents["s3:" + o.displayKey] = Content(size: o.size, present: [.s3], reasons: [.cubbitNotCertifiable],
                                                         example: (.s3, o.displayKey))
                uncertainS3Paths.insert(o.key)
            }
        }

        // 3. Per percorso: stesso percorso su almeno due archivi, piu' di un contenuto.
        for (_, perArchive) in byPath where perArchive.count >= 2 {
            let ids = perArchive.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            guard ids.count > 1 else { continue }
            for id in ids { contents[id]!.reasons.insert(.samePathDifferentContent) }
        }
        // Un oggetto Cubbit non certificabile rende incerta anche la foto allo stesso percorso:
        // su Cubbit potrebbe esserci come no.
        for key in uncertainS3Paths {
            for (archive, ids) in byPath[key] ?? [:] where archive != .s3 {
                for id in ids { contents[id]!.reasons.insert(.cubbitNotCertifiable) }
            }
        }

        // 4. Copie in piu' per archivio. I file vuoti hanno tutti la stessa impronta e non sono
        //    copie l'uno dell'altro (stessa regola di `LibraryIndexStore.duplicateGroups`).
        for archive in InventoryArchive.allCases {
            for (id, n) in copies[archive]! where n > 1 {
                let size = contents[id]!.size
                guard size > 0 else { continue }
                stats[archive]!.extraCopies += n - 1
                stats[archive]!.reclaimableBytes += Int64(n - 1) * size
            }
        }

        // 5. Categorie, con la precedenza della spec.
        var items: [InventoryItem] = []
        items.reserveCapacity(contents.count)
        for (id, c) in contents {
            let missing = Set(InventoryArchive.allCases).subtracting(c.present)
            let missingKnown = missing.filter { s.isComplete($0) }
            let unknown = missing.subtracting(missingKnown)
            let category: InventoryCategory
            if !c.reasons.isEmpty {
                category = .toCheck
            } else if !c.present.contains(.ssd) && s.isComplete(.ssd) {
                category = .onlyOutsideSSD
            } else if !missingKnown.isEmpty {
                category = .missingSomewhere
            } else if missing.isEmpty {
                category = .safe
            } else {
                category = .undetermined
            }
            items.append(InventoryItem(id: id, category: category, size: c.size, presentOn: c.present,
                                       missingFrom: missingKnown, unknownOn: unknown, checkReasons: c.reasons,
                                       exampleArchive: c.example.archive, examplePath: c.example.path))
        }
        let order = Dictionary(uniqueKeysWithValues: InventoryCategory.allCases.enumerated().map { ($1, $0) })
        items.sort { a, b in
            if a.category != b.category { return order[a.category]! < order[b.category]! }
            if a.examplePath != b.examplePath { return a.examplePath < b.examplePath }
            return a.id < b.id
        }
        return (items, stats)
    }
}

/// Quello che la finestra Inventario mostra, calcolato una volta fuori dal main: numeri per
/// categoria e per archivio, e un campione limitato di voci per categoria. L'elenco completo
/// (centinaia di migliaia di contenuti) non viaggia verso la UI.
nonisolated struct InventorySummary: Equatable, Sendable {
    /// Quante voci per categoria si mostrano al massimo. La finestra dice sempre quante sono
    /// in tutto (`InventoryStatus.sampleLimitLine`): mai un elenco tagliato in silenzio.
    static let defaultSampleLimit = 300

    let states: [InventoryArchive: InventoryArchiveState]
    let stats: [InventoryArchive: InventoryArchiveStats]
    let counts: [InventoryCategory: Int]
    let bytes: [InventoryCategory: Int64]
    let samples: [InventoryCategory: [InventoryItem]]
    /// Le voci in ❗ che si possono riparare con la regola «2 su 3» (ROADMAP #45). Tutte, non
    /// un campione: sono poche (oggi una), e ognuna ha il suo «Ripara…».
    let repairCandidates: [RepairCandidate]

    init(_ snapshot: InventorySnapshot, sampleLimit: Int) {
        let (items, stats) = InventoryClassifier.classify(snapshot)
        var counts: [InventoryCategory: Int] = [:]
        var bytes: [InventoryCategory: Int64] = [:]
        var samples: [InventoryCategory: [InventoryItem]] = [:]
        for item in items {
            counts[item.category, default: 0] += 1
            bytes[item.category, default: 0] += item.size
            if samples[item.category, default: []].count < sampleLimit {
                samples[item.category, default: []].append(item)
            }
        }
        self.states = snapshot.states
        self.stats = stats
        self.counts = counts
        self.bytes = bytes
        self.samples = samples
        self.repairCandidates = RepairRules.candidates(in: snapshot)
    }

    func count(_ c: InventoryCategory) -> Int { counts[c] ?? 0 }
    func bytes(_ c: InventoryCategory) -> Int64 { bytes[c] ?? 0 }
}

/// A che punto e' un aggiornamento dell'inventario, per la barra della finestra.
nonisolated enum InventoryProgress: Equatable, Sendable {
    case checkingCubbit
    case local(InventoryArchive, InventoryScanReport)
    case cubbit(CubbitReadReport)
    case classifying
}

/// Com'e' finito un aggiornamento: il riepilogo nuovo, oppure il motivo per cui non c'e'.
nonisolated struct InventoryRefreshOutcome: Sendable {
    let summary: InventorySummary?
    /// Testo per il registro, mai mostrato cosi' com'e'.
    let failure: String?
}

/// L'aggiornamento completo: SSD, poi HDD, poi Cubbit, poi il confronto. Separato da
/// `BackupRunner` perche' sia verificabile da un test con cartelle temporanee e un Cubbit
/// finto; `BackupRunner` ci mette solo i bookmark, il cancello e la pubblicazione sul main.
// `nonisolated`: nessuno stato, tutto e' nei parametri. `@concurrent`: e' una funzione di fondo
// `async`, e senza girerebbe sul thread di chi la chiama (ADR-0006).
nonisolated enum InventoryRefresh {
    @concurrent
    static func run(store: LibraryIndexStore, ssdRoot: URL, hddRoot: URL, runId: Int64,
                    cancelFlag: CancelFlag,
                    sampleLimit: Int = InventorySummary.defaultSampleLimit,
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                    fetchPage: @escaping @Sendable (String?) async throws -> String,
                    onProgress: @escaping @Sendable (InventoryProgress) -> Void) async -> InventoryRefreshOutcome {
        do {
            try store.beginInventoryRun(runId: runId, startedAt: now())
        } catch {
            return InventoryRefreshOutcome(summary: nil, failure: error.localizedDescription)
        }
        let scanner = InventoryScanner(store: store, cancelFlag: cancelFlag)
        for (archive, root) in [(InventoryArchive.ssd, ssdRoot), (.hdd, hddRoot)] {
            guard !cancelFlag.isCancelled else {
                try? store.finishInventoryArchive(archive, runId: runId, complete: false, reason: .notReached,
                                                  unreadable: 0, finishedAt: now())
                continue
            }
            do {
                let report = try scanner.scan(root: root, archive: archive, runId: runId) { r in
                    onProgress(.local(archive, r))
                }
                try store.finishInventoryArchive(archive, runId: runId, complete: report.isComplete,
                                                 reason: report.incompleteReason,
                                                 unreadable: report.unreadableFiles, finishedAt: now())
            } catch {
                try? store.finishInventoryArchive(archive, runId: runId, complete: false, reason: .couldNotSave,
                                                  unreadable: 0, finishedAt: now())
            }
        }
        if cancelFlag.isCancelled {
            try? store.finishInventoryArchive(.s3, runId: runId, complete: false, reason: .notReached,
                                              unreadable: 0, finishedAt: now())
        } else {
            let reader = InventoryCubbitReader(store: store, cancelFlag: cancelFlag)
            let report = await reader.read(runId: runId, fetchPage: fetchPage) { r in onProgress(.cubbit(r)) }
            try? store.finishInventoryArchive(.s3, runId: runId, complete: report.isComplete,
                                              reason: report.incompleteReason, unreadable: 0, finishedAt: now())
        }
        onProgress(.classifying)
        do {
            let snapshot = try store.inventorySnapshot()
            return InventoryRefreshOutcome(summary: InventorySummary(snapshot, sampleLimit: sampleLimit), failure: nil)
        } catch {
            return InventoryRefreshOutcome(summary: nil, failure: error.localizedDescription)
        }
    }
}

/// Perche' «Aggiorna l'inventario» non puo' partire adesso, `nil` se puo'. Il verso opposto
/// (niente backup, lettura dell'elenco, spostamento o annullamento durante l'inventario) sta
/// nei cancelli di quelle operazioni, col parametro `isInventorying`.
enum InventoryStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
        if isInventorying { return "L'inventario si sta già aggiornando." }
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino delle copie doppie: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca, "
                + "altrimenti l'inventario leggerebbe l'SSD mentre cambia."
        }
        if isRepairing {
            return "L'app sta riparando una foto: aspetta che finisca, poi aggiorna l'inventario per "
                + "confermare la riparazione."
        }
        if isRunning {
            return "C'è un backup in corso: aspetta che finisca, altrimenti l'inventario "
                + "leggerebbe i dischi mentre cambiano."
        }
        if isIndexing {
            return "L'app sta aggiornando l'elenco delle foto sull'SSD: aspetta che finisca."
        }
        if !ssdMounted {
            return "L'SSD non è collegato: l'inventario ha bisogno di SSD, HDD e Cubbit insieme."
        }
        if !hddMounted {
            return "L'HDD non è collegato: l'inventario ha bisogno di SSD, HDD e Cubbit insieme."
        }
        if !hasCubbitConfig {
            return "L'app non ha letto le credenziali di Cubbit: controlla in Diagnostica, poi riprova."
        }
        return nil
    }

    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."

    /// Un disco si sta smontando durante l'inventario: ci si ferma solo se e' l'SSD o l'HDD
    /// (o se macOS non dice quale, per prudenza). Diverso dalla lettura dell'elenco, che si
    /// ferma a ogni smontaggio: li' costa poco, qui un giro dura decine di minuti, ed espellere
    /// una chiavetta non deve buttarlo via. Il confronto e' per componenti, mai per prefisso
    /// di stringa (`/Volumes/SSD` non e' `/Volumes/SSD 2`).
    static func volumeChangeStopsInventory(unmounting volume: URL?, ssdRoot: URL?, hddRoot: URL?) -> Bool {
        guard let volume else { return true }
        let target = volume.standardizedFileURL.pathComponents
        return [ssdRoot, hddRoot].compactMap { $0 }.contains { $0.standardizedFileURL.pathComponents == target }
    }
}

/// Perche' «Ripara…» non puo' partire adesso, `nil` se puo' (ROADMAP #45). Il verso opposto
/// (niente backup, lettura dell'elenco, inventario, spostamento o annullamento durante una
/// riparazione) sta nei cancelli di quelle operazioni, col parametro `isRepairing`. Precedenza
/// scritta a parole: un'altra riparazione > spostamento/annullamento > inventario > backup >
/// lettura dell'elenco > dischi non collegati > Cubbit non configurato.
enum RepairStartGate {
    static func blockedReason(isRunning: Bool, isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool,
                              ssdMounted: Bool, hddMounted: Bool, hasCubbitConfig: Bool) -> String? {
        if isRepairing { return "C'è già una riparazione in corso: le foto si riparano una alla volta." }
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino delle copie doppie: aspetta che finisca."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto delle foto dal Cestino: aspetta che finisca."
        }
        if isInventorying {
            return "L'inventario si sta aggiornando: aspetta che finisca, poi ripara."
        }
        if isRunning {
            return "C'è un backup in corso: aspetta che finisca, altrimenti la riparazione scriverebbe "
                + "mentre il backup copia."
        }
        if isIndexing {
            return "L'app sta aggiornando l'elenco delle foto sull'SSD: aspetta che finisca."
        }
        if !ssdMounted {
            return "L'SSD non è collegato: per riparare una foto servono SSD, HDD e Cubbit insieme."
        }
        if !hddMounted {
            return "L'HDD non è collegato: per riparare una foto servono SSD, HDD e Cubbit insieme."
        }
        if !hasCubbitConfig {
            return "L'app non ha letto le credenziali di Cubbit: controlla in Diagnostica, poi riprova."
        }
        return nil
    }

    static let cubbitUnreachable =
        "Cubbit non risponde in questo momento: controlla la connessione a Internet e riprova."
}

/// I testi della finestra Inventario. Logica pura, come `DuplicatesStatus`: nessuna stringa
/// nasce dentro la View. Registro: niente gergo («hash», «impronta», «ETag», «MD5», «indice»,
/// «scansione», «bucket», «cache»): Enrico legge SSD, HDD, Cubbit, foto e video.
enum InventoryStatus {
    enum Tone: Equatable { case ok, info, warning }

    struct Line: Identifiable, Equatable {
        let id: String
        let tone: Tone
        let text: String
    }

    /// Ordine in cui la finestra mostra le categorie: quello della tabella della spec, con
    /// «non si può ancora dire» in fondo.
    static let displayOrder: [InventoryCategory] = [.safe, .missingSomewhere, .onlyOutsideSSD, .toCheck, .undetermined]

    static let readOnlyNote = "L'inventario guarda soltanto: non copia, non sposta e non cancella "
        + "niente, né sull'SSD né sull'HDD né su Cubbit. L'unica cosa che da qui può scrivere è "
        + "«Ripara…», una foto alla volta e solo dopo la tua conferma."
    static let refreshButton = "Aggiorna l'inventario"
    static let stopButton = "Interrompi"
    static let stoppingLine = "Mi fermo appena finisco il file o la pagina dell'elenco che sto leggendo…"
    static let loadingLine = "Leggo l'ultimo inventario salvato…"

    static func archiveName(_ a: InventoryArchive) -> String {
        switch a {
        case .ssd: return "SSD"
        case .hdd: return "HDD"
        case .s3: return "Cubbit"
        }
    }

    static func title(_ c: InventoryCategory) -> String {
        switch c {
        case .safe: return "✅ Al sicuro"
        case .missingSomewhere: return "⚠️ Manca da qualche parte"
        case .onlyOutsideSSD: return "🔎 Solo fuori dall'SSD"
        case .toCheck: return "❗ Da controllare"
        case .undetermined: return "⏳ Non si può ancora dire"
        }
    }

    static func explanation(_ c: InventoryCategory) -> String {
        switch c {
        case .safe:
            return "Ci sono sull'SSD, sull'HDD e su Cubbit, e l'app ha verificato che sono identiche in tutti e tre i posti."
        case .missingSomewhere:
            return "Ci sono in uno o due posti ma mancano dagli altri: per ognuna l'app dice da dove manca."
        case .onlyOutsideSSD:
            return "Ci sono sull'HDD o su Cubbit, ma sull'SSD non ci sono più."
        case .toCheck:
            return "Con lo stesso nome c'è un contenuto diverso in due posti, oppure la copia su Cubbit "
                + "non si può confrontare senza scaricarla. Queste non verranno mai toccate in automatico."
        case .undetermined:
            return "Mancano da un posto che l'app non è riuscita a leggere per intero: finché non lo "
                + "legge tutto, non dice che mancano."
        }
    }

    static func categoryLine(_ c: InventoryCategory, count: Int, bytes: Int64) -> String {
        "\(title(c)): \(photos(count)) (\(size(bytes)))"
    }

    static func archiveLine(_ a: InventoryArchive, stats: InventoryArchiveStats) -> String {
        guard stats.extraCopies > 0 else {
            return "\(archiveName(a)): \(photos(stats.files)) · nessuna copia in più"
        }
        let copies = stats.extraCopies == 1 ? "1 copia in più" : "\(number(stats.extraCopies)) copie in più"
        return "\(archiveName(a)): \(photos(stats.files)) · \(copies) · \(size(stats.reclaimableBytes)) "
            + "si possono recuperare tenendone una sola"
    }

    /// `nil` se l'archivio e' stato letto per intero nell'ultimo aggiornamento.
    static func completenessLine(_ a: InventoryArchive, state: InventoryArchiveState?) -> Line? {
        let name = archiveName(a)
        guard let state else {
            return Line(id: "never-\(a.rawValue)", tone: .info, text: "\(name): non ancora letto.")
        }
        guard !state.complete else { return nil }
        let why: String
        switch state.reason ?? .interrupted {
        case .running:
            why = "l'ultimo aggiornamento non è arrivato in fondo (l'app si è chiusa a metà)."
        case .notReached:
            why = "non è stato letto, perché l'aggiornamento si è fermato prima di arrivarci."
        case .interrupted:
            why = "la lettura è stata fermata prima della fine."
        case .volumeVanished:
            why = "il disco è stato scollegato mentre l'app lo leggeva."
        case .foldersUnreadable:
            why = "alcune cartelle non si sono lasciate aprire (permessi o errori di lettura)."
        case .filesUnreadable:
            why = state.unreadable == 1
                ? "1 file non si è lasciato leggere per intero."
                : "\(number(state.unreadable)) file non si sono lasciati leggere per intero."
        case .sawNothing:
            why = "l'app non ha trovato nessuna foto, mentre la volta prima ce n'erano."
        case .listingFailed:
            why = "l'elenco si è interrotto per un problema di rete."
        case .listingMalformed:
            why = "l'elenco è arrivato con delle voci che l'app non ha saputo leggere."
        case .couldNotSave:
            why = "l'app non è riuscita a salvare quello che leggeva."
        }
        return Line(id: "incomplete-\(a.rawValue)", tone: .warning, text:
            "\(name): \(why) Finché non viene letto per intero, l'app non dice mai che una foto manca da lì.")
    }

    static func freshnessLine(states: [InventoryArchive: InventoryArchiveState], now: Date,
                              calendar: Calendar = .current) -> Line {
        guard !states.isEmpty else {
            return Line(id: "never", tone: .info, text:
                "L'inventario non è mai stato fatto. La prima volta l'app rilegge per intero l'SSD e "
                + "l'HDD, e ci vogliono decine di minuti.")
        }
        let runIds = Set(states.values.map(\.runId))
        let allComplete = InventoryArchive.allCases.allSatisfy { states[$0]?.complete == true }
        let started = states.values.map(\.startedAt).max() ?? 0
        let finished = states.values.compactMap(\.finishedAt).max() ?? started
        if allComplete && runIds.count == 1 {
            return Line(id: "complete", tone: .ok, text:
                "Inventario completo, aggiornato \(when(finished, now: now, calendar: calendar)).")
        }
        return Line(id: "incomplete", tone: .warning, text:
            "L'ultimo aggiornamento (\(when(started, now: now, calendar: calendar))) non è completo: "
            + "qui sotto trovi quali posti non sono stati letti per intero.")
    }

    static func itemLine(_ item: InventoryItem) -> String {
        let place = "«\(item.examplePath)» (\(archiveName(item.exampleArchive)))"
        switch item.category {
        case .safe:
            return "\(place) — su SSD, HDD e Cubbit"
        case .missingSomewhere:
            var text = "\(place) — manca da: \(names(item.missingFrom))"
            if !item.unknownOn.isEmpty { text += "; su \(names(item.unknownOn)) non si sa ancora" }
            return text
        case .onlyOutsideSSD:
            return "\(place) — c'è solo su \(names(item.presentOn))"
        case .toCheck:
            if item.checkReasons.contains(.samePathDifferentContent) {
                return "\(place) — con lo stesso nome, altrove c'è un contenuto diverso"
            }
            return "\(place) — la copia su Cubbit non si può confrontare senza scaricarla"
        case .undetermined:
            return "\(place) — c'è su \(names(item.presentOn)); su \(names(item.unknownOn)) non si sa ancora"
        }
    }

    static func progressLine(_ p: InventoryProgress) -> String {
        switch p {
        case .checkingCubbit:
            return "Controllo che Cubbit risponda…"
        case .local(let archive, let r):
            let step = archive == .ssd ? "1 di 3" : "2 di 3"
            return "\(step) · Leggo le foto sull'\(archiveName(archive)): \(number(r.scanned)) viste, "
                + "\(number(r.reread)) lette da capo"
        case .cubbit(let r):
            return "3 di 3 · Chiedo a Cubbit l'elenco delle foto: \(number(r.objectsKept)) finora"
        case .classifying:
            return "Metto a confronto SSD, HDD e Cubbit…"
        }
    }

    /// `nil` quando si vedono tutte.
    static func sampleLimitLine(shown: Int, total: Int) -> String? {
        guard total > shown else { return nil }
        return "Qui ne vedi \(number(shown)) su \(number(total)), in ordine di nome."
    }

    // MARK: - Aiuti

    private static func photos(_ n: Int) -> String { n == 1 ? "1 foto o video" : "\(number(n)) foto e video" }
    private static func number(_ n: Int) -> String { n.formatted() }
    private static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private static func names(_ set: Set<InventoryArchive>) -> String {
        let list = set.sorted().map { archiveName($0) }
        guard list.count > 1 else { return list.first ?? "" }
        return list.dropLast().joined(separator: ", ") + " e " + list.last!
    }

    private static func when(_ t: Double, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .long
        f.timeStyle = .none
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let ago: String
        switch days {
        case ..<1: ago = "oggi"
        case 1: ago = "ieri"
        default: ago = "\(days) giorni fa"
        }
        return "\(ago), il \(f.string(from: date))"
    }
}

// MARK: - Riparazione con la regola «2 su 3»: le regole pure (ROADMAP #45, ADR-0016)

/// Dove la riparazione mette le copie, come percorsi RELATIVI alla radice di un archivio (SSD,
/// HDD) o come chiavi di Cubbit. Logica pura: nessun disco, nessuna rete.
// `nonisolated`: pura, chiamata dal motore della riparazione fuori dal main.
nonisolated enum RepairPaths {
    /// Lo stesso nome che backup, elenco, inventario e ripristino escludono (una fonte sola).
    static var quarantineFolder: String { LibraryExclusions.quarantineFolderName }

    /// Il calendario dei nomi delle cartelle per giorno: gregoriano, nel fuso del Mac.
    static var defaultCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// `AAAA-MM-GG` del giorno di `date` nel calendario dato.
    static func dayFolder(for date: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// Le componenti di un percorso relativo, o `nil` se non e' sicuro da usare: vuoto,
    /// assoluto, con componenti vuote, `.` o `..` (uscirebbe dalla cartella), oppure gia'
    /// dentro la quarantena (non si mette in quarantena una quarantena).
    static func safeComponents(_ relative: String) -> [String]? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !LibraryExclusions.isQuarantineName(parts[0]) else { return nil }
        return parts
    }

    /// `_quarantena/<AAAA-MM-GG>/<percorso originale>`: stessa chiave relativa, caratteri
    /// speciali compresi, sullo stesso archivio. `nil` se il percorso non e' sicuro.
    static func quarantinePath(for relative: String, date: Date, calendar: Calendar) -> String? {
        guard safeComponents(relative) != nil else { return nil }
        return quarantineFolder + "/" + dayFolder(for: date, calendar: calendar) + "/" + relative
    }

    /// Dove si prepara la copia buona prima di metterla al suo posto (solo SSD e HDD): accanto
    /// alla copia in quarantena, con un suffisso unico. Se la riparazione si ferma prima della
    /// fine, quello che resta sta dentro la quarantena (che nessuno legge) e non va cancellato.
    static func stagingPath(for relative: String, date: Date, calendar: Calendar, token: String) -> String? {
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }),
              let q = quarantinePath(for: relative, date: date, calendar: calendar) else { return nil }
        return q + ".in-arrivo-" + token
    }

    /// Vero se `key` e' `_quarantena/<un giorno qualsiasi>/<relative>`: serve alla quarantena
    /// IDEMPOTENTE su Cubbit (una copia messa da parte un altro giorno, per esempio dalla prova
    /// con `rclone` del 2026-10-04, vale come gia' fatta).
    static func isQuarantineCopy(_ key: String, of relative: String) -> Bool {
        let prefix = quarantineFolder + "/"
        guard key.hasPrefix(prefix) else { return false }
        let rest = key.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return isDayFolder(rest[..<slash]) && rest[rest.index(after: slash)...] == relative[...]
    }

    private static func isDayFolder(_ s: Substring) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}

/// Una foto rovinata in UN archivio, integra e identica negli altri due: si puo' riparare.
/// Viene dall'inventario, che e' una cache (ADR-0002): il motore ricontrolla tutto dal vivo.
nonisolated struct RepairCandidate: Equatable, Sendable, Identifiable {
    /// `normalizedIndexKey` del percorso: lo stesso nei tre archivi.
    let key: String
    /// La minoranza: l'archivio con la copia diversa.
    let target: InventoryArchive
    /// Da dove si copia: sempre un file locale — l'SSD per riparare HDD o Cubbit, l'HDD per
    /// riparare l'SSD.
    let source: InventoryArchive
    /// La seconda copia buona, che deve coincidere anche lei al ricontrollo.
    let witness: InventoryArchive
    /// Il percorso com'e' scritto in ciascun archivio (su Cubbit con le maiuscole vere).
    let paths: [InventoryArchive: String]
    /// Le impronte della copia buona, lette per intero nell'ultimo inventario.
    let good: ContentDigest
    /// Cosa l'inventario ha visto nella copia rovinata.
    let badSize: Int64
    /// Su SSD o HDD.
    let badSHA256: String?
    /// Su Cubbit, cosi' come arriva dalla lista.
    let badETag: String?

    var id: String { key }
}

/// Quando una voce dell'inventario si puo' riparare. Logica PURA sul `InventorySnapshot`.
// `nonisolated`: pura, calcolata insieme al riepilogo dell'inventario fuori dal main.
nonisolated enum RepairRules {
    /// L'archivio da cui si copia per riparare `target`.
    static func source(forTarget target: InventoryArchive) -> InventoryArchive {
        target == .ssd ? .hdd : .ssd
    }

    /// La seconda copia buona per riparare `target`.
    static func witness(forTarget target: InventoryArchive) -> InventoryArchive {
        target == .s3 ? .hdd : .s3
    }

    /// L'ETag che Cubbit dara' alla copia buona dopo `S3Syncer.upload`: l'MD5 fino a 64 MiB
    /// compresi, l'ETag a pezzi da 64 MiB sopra (stessa soglia di `upload`).
    static func expectedCubbitETag(for good: ContentDigest) -> String {
        good.multipartETag ?? good.md5
    }

    /// Un ETag senza virgolette, spazi e maiuscole, per confrontarne due.
    static func normalizedETag(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        return s.isEmpty ? nil : s
    }

    /// Una chiave di Cubbit si puo' riparare solo se il caricamento (che usa la codifica di
    /// sempre del backup, `.urlPathAllowed`) e le richieste nuove (HEAD e copia, con
    /// `encodeKeyStrict`) mandano lo STESSO percorso. Vale per lettere (accentate comprese:
    /// fuori dall'ASCII le due codifiche coincidono), cifre, spazi e `-_.~/` — la foto del
    /// 2026-10-01 compresa. Con `+`, apostrofo e gli altri segni che `.urlPathAllowed` lascia
    /// passare (`!$&'()*+,;=:@`) divergono, e la sovrascrittura potrebbe finire su una chiave
    /// diversa da quella controllata: quelle voci restano in ❗ finche' una prova dal vivo non
    /// le copre.
    static func cubbitKeyIsRepairable(_ key: String) -> Bool {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) == S3Syncer.encodeKeyStrict(key)
    }

    /// Le voci riparabili, in ordine di percorso. Le condizioni (spec, «Quando una foto e'
    /// riparabile»), tutte necessarie:
    /// - tutti e tre gli archivi COMPLETI nell'ultimo giro (incompleto non e' assente, ADR-0015);
    /// - lo stesso percorso, una sola volta, in ciascuno dei tre (una collisione di maiuscole
    ///   dentro un archivio non si ripara);
    /// - SSD e HDD letti per intero;
    /// - due archivi con lo stesso contenuto certificato e la stessa dimensione, il terzo con un
    ///   contenuto DIMOSTRATO diverso.
    ///
    /// «Dimostrato» su Cubbit vuol dire: un ETag a parte unica (e' l'MD5 del contenuto) diverso
    /// dall'MD5 della copia buona. Un ETag a pezzi che non torna non dimostra niente (potrebbe
    /// essere lo stesso contenuto caricato con parti di altra dimensione): la voce resta in ❗.
    static func candidates(in s: InventorySnapshot) -> [RepairCandidate] {
        guard InventoryArchive.allCases.allSatisfy({ s.isComplete($0) }) else { return [] }
        let ssd = Dictionary(grouping: s.ssd, by: \.key)
        let hdd = Dictionary(grouping: s.hdd, by: \.key)
        let s3 = Dictionary(grouping: s.s3, by: \.key)
        var out: [RepairCandidate] = []
        for (key, ssdRows) in ssd {
            guard !LibraryExclusions.isInsideQuarantine(relativePath: key),
                  ssdRows.count == 1, let hddRows = hdd[key], hddRows.count == 1,
                  let s3Rows = s3[key], s3Rows.count == 1 else { continue }
            let a = ssdRows[0], b = hddRows[0], o = s3Rows[0]
            guard a.status == .ok, b.status == .ok, let da = a.digest, let db = b.digest,
                  da.size == a.size, db.size == b.size else { continue }
            let paths: [InventoryArchive: String] = [.ssd: a.displayPath, .hdd: b.displayPath, .s3: o.displayKey]

            if da.sha256 == db.sha256 {
                // SSD e HDD d'accordo: Cubbit e' la minoranza solo se dimostrato diverso.
                guard case .singlePart(let md5) = S3ETag.parse(o.etag), md5 != da.md5,
                      cubbitKeyIsRepairable(o.displayKey) else { continue }
                out.append(RepairCandidate(key: key, target: .s3, source: .ssd, witness: .hdd, paths: paths,
                                           good: da, badSize: o.size, badSHA256: nil, badETag: o.etag))
                continue
            }
            // SSD e HDD diversi: decide Cubbit, solo se certifica uno dei due (stesso
            // confronto dell'inventario, `S3ETagMatcher`, fra i due contenuti in gioco).
            let both = [da, db].map {
                S3ETagMatcher.Candidate(size: $0.size, sha256: $0.sha256, md5: $0.md5,
                                        multipartETag: $0.multipartETag, alternativeETags: $0.alternativeMultipartETags)
            }
            guard case .certified(let sha) = S3ETagMatcher.verdict(etag: o.etag, size: o.size, candidates: both) else {
                continue
            }
            if sha == da.sha256 && o.size == da.size {
                out.append(RepairCandidate(key: key, target: .hdd, source: .ssd, witness: .s3, paths: paths,
                                           good: da, badSize: b.size, badSHA256: db.sha256, badETag: nil))
            } else if sha == db.sha256 && o.size == db.size {
                out.append(RepairCandidate(key: key, target: .ssd, source: .hdd, witness: .s3, paths: paths,
                                           good: db, badSize: a.size, badSHA256: da.sha256, badETag: nil))
            }
        }
        return out.sorted { $0.key < $1.key }
    }
}

// MARK: - Riparazione: il registro sul Mac (ROADMAP #45, ADR-0016)

/// I passi della riparazione, nell'ordine in cui avvengono (spec, «Cosa succede quando si
/// ripara»). Su SSD e HDD la copia buona si PREPARA prima di mettere da parte quella rovinata
/// (scostamento S4 del piano): il passo `write` compare quindi due volte, prima e dopo
/// `quarantine`.
nonisolated enum RepairStep: String, Codable, Sendable {
    case liveCheck
    case quarantine
    case write
    case finalCheck
    case log
}

/// Com'e' finita una riparazione, per il registro.
nonisolated enum RepairOutcomeKind: String, Codable, Sendable {
    /// Scritto PRIMA di toccare qualunque archivio: se l'app si chiude a meta', il registro
    /// dice che una riparazione era cominciata e dove stava la copia messa da parte.
    case inProgress
    case repaired
    /// Fermata a un passo, con il motivo. Se il passo e' `liveCheck` non e' stato toccato niente.
    case failed
    /// Scritta, ma la verifica finale non torna: la copia rovinata resta in quarantena e non si
    /// ritenta da soli.
    case verificationFailed
}

/// Una riparazione nel registro. Tutti i campi che servono a ricostruire cosa e' successo
/// senza l'inventario: percorso, archivio riparato, sorgente, impronte prima e dopo, dove e'
/// finita la copia rovinata, quando, com'e' andata.
// `nonisolated`: value type, scritto dal motore fuori dal main e letto dalla finestra.
nonisolated struct RepairRecord: Codable, Equatable, Sendable {
    var repairId: String
    var key: String
    /// Il percorso nell'archivio riparato (su Cubbit, la chiave vera).
    var displayPath: String
    var target: String
    var source: String
    var witness: String
    var goodSHA256: String
    var goodSize: Int64
    var badSize: Int64
    var badSHA256: String? = nil
    var badETag: String? = nil
    var afterSHA256: String? = nil
    var afterETag: String? = nil
    /// Dove sta la copia rovinata messa da parte (relativo alla radice, o chiave di Cubbit).
    var quarantinePath: String? = nil
    /// Vero se su Cubbit la copia rovinata era gia' in quarantena (anche con un'altra data).
    var reusedQuarantineCopy: Bool = false
    var startedAt: Date
    var finishedAt: Date? = nil
    var outcome: RepairOutcomeKind
    var failedStep: RepairStep? = nil
    /// Testo per chi legge il registro a mano; mai mostrato cosi' com'e' nella finestra.
    var detail: String? = nil
}

nonisolated extension RepairRecord {
    private enum CodingKeys: String, CodingKey {
        case repairId, key, displayPath, target, source, witness, goodSHA256, goodSize, badSize, badSHA256, badETag,
             afterSHA256, afterETag, quarantinePath, reusedQuarantineCopy, startedAt, finishedAt, outcome, failedStep, detail
    }

    /// `init(from:)` esplicita con `decodeIfPresent` (regola del progetto per i tipi
    /// persistiti, fatto misurato n. 5 di #31). Severa sui campi portanti — senza identita',
    /// percorso, archivio, data o esito la voce non racconta niente — tollerante sugli altri.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repairId = try c.decode(String.self, forKey: .repairId)
        key = try c.decode(String.self, forKey: .key)
        displayPath = try c.decodeIfPresent(String.self, forKey: .displayPath) ?? ""
        target = try c.decode(String.self, forKey: .target)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        witness = try c.decodeIfPresent(String.self, forKey: .witness) ?? ""
        goodSHA256 = try c.decodeIfPresent(String.self, forKey: .goodSHA256) ?? ""
        goodSize = try c.decodeIfPresent(Int64.self, forKey: .goodSize) ?? 0
        badSize = try c.decodeIfPresent(Int64.self, forKey: .badSize) ?? 0
        badSHA256 = try c.decodeIfPresent(String.self, forKey: .badSHA256)
        badETag = try c.decodeIfPresent(String.self, forKey: .badETag)
        afterSHA256 = try c.decodeIfPresent(String.self, forKey: .afterSHA256)
        afterETag = try c.decodeIfPresent(String.self, forKey: .afterETag)
        quarantinePath = try c.decodeIfPresent(String.self, forKey: .quarantinePath)
        reusedQuarantineCopy = try c.decodeIfPresent(Bool.self, forKey: .reusedQuarantineCopy) ?? false
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outcome = try c.decode(RepairOutcomeKind.self, forKey: .outcome)
        failedStep = try c.decodeIfPresent(RepairStep.self, forKey: .failedStep)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Il contenuto di `repair-log.json`: stesso schema di `TrashManifest` (`totalRecorded` +
/// `items`), per la stessa ragione — il numero vero resta anche quando la lista e' potata.
// `nonisolated`: value type, letto e scritto da `RepairLogStore` sempre dietro `lock`.
nonisolated struct RepairLog: Codable {
    var totalRecorded: Int = 0
    var items: [RepairRecord] = []
}

nonisolated extension RepairLog {
    private enum CodingKeys: String, CodingKey { case totalRecorded, items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRecorded = try c.decodeIfPresent(Int.self, forKey: .totalRecorded) ?? 0
        items = try c.decodeIfPresent([RepairRecord].self, forKey: .items) ?? []
    }
}

/// Il registro delle riparazioni, sul disco interno (`Application Support/AppBackupFoto/
/// repair-log.json`), mai su un archivio. Stessa disciplina di `TrashManifestStore`: allow-list
/// della posizione, ogni scrittura su disco PRIMA di tornare, `0600`, un file illeggibile
/// riparte da vuoto senza bloccare niente.
// `nonisolated`: `record` arriva dal motore della riparazione fuori dal main, `records` dal
// main. Ogni accesso a `log` avviene dentro `lock.withLock`, scrittura su disco compresa;
// `url` e' `let`. Vedi ADR-0006.
nonisolated final class RepairLogStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case invalidLocation(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation(let p): return "Posizione non consentita per il registro delle riparazioni: \(p)"
            }
        }
    }

    /// Le riparazioni sono una alla volta e con conferma: 2.000 voci sono anni di storia.
    static let defaultMaxItems = 2000

    private let url: URL
    private let maxItems: Int
    private var log: RepairLog
    private let lock = NSLock()

    /// `maxItems` e' iniettato solo dai test (la potatura si prova con poche voci).
    init(url: URL, maxItems: Int = RepairLogStore.defaultMaxItems) throws {
        guard isAllowedStoreLocation(url) else { throw StoreError.invalidLocation(url.path) }
        self.url = url
        self.maxItems = max(1, maxItems)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(RepairLog.self, from: data) {
            log = decoded
        } else {
            log = RepairLog()
        }
    }

    var totalRecorded: Int { lock.withLock { log.totalRecorded } }

    /// Aggiunge la voce, o aggiorna quella con lo stesso `repairId` (la stessa riparazione che
    /// passa da «in corso» al suo esito), e **scrive su disco prima di tornare**.
    func record(_ r: RepairRecord) throws {
        try lock.withLock {
            if let i = log.items.firstIndex(where: { $0.repairId == r.repairId }) {
                log.items[i] = r
            } else {
                log.items.append(r)
                log.totalRecorded += 1
                if log.items.count > maxItems { log.items = Array(log.items.suffix(maxItems)) }
            }
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
            // Best-effort, come il registro dei Doppioni: contiene i percorsi delle foto.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func records() -> [RepairRecord] { lock.withLock { log.items } }
}

// MARK: - Riparazione: il motore (ROADMAP #45, ADR-0016)

/// Quello che la riparazione chiede a Cubbit. In produzione `S3RepairCloud` (sopra
/// `S3Syncer`); nei test un Cubbit finto in memoria.
nonisolated protocol RepairCloud: Sendable {
    /// `nil` = l'oggetto non c'e'.
    func head(key: String) async throws -> S3Syncer.S3ObjectHead?
    /// Tutti gli oggetti sotto `prefix`; lancia se la lista non arriva in fondo.
    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo]
    /// Copia lato server; la sorgente non viene toccata.
    func copy(from sourceKey: String, to destinationKey: String) async throws
    /// La sola sovrascrittura: la copia buona al posto di quella rovinata.
    func replace(key: String, withFileAt url: URL) async throws
}

/// Perche' una riparazione si e' fermata. Ogni caso ha la sua frase in `RepairStatus`.
nonisolated enum RepairFailure: Equatable, Sendable {
    case volumeMissing(InventoryArchive)
    case unsafePath
    case sourceChanged
    case witnessChanged
    case badCopyMissing
    case badCopyChanged
    case cubbitError(String)
    case logNotWritten(String)
    case quarantineOccupied
    case quarantineFailed(String)
    case quarantineCopyMismatch
    case stagingFailed(String)
    case stagingMismatch
    case writeFailed(String)
    case finalCheckFailed
}

/// Com'e' andata una riparazione, per la finestra.
nonisolated struct RepairOutcome: Equatable, Sendable {
    let key: String
    let target: InventoryArchive
    /// Il percorso nell'archivio riparato.
    let displayPath: String
    /// Controllo senza riparare (S11): il ricontrollo e' stato fatto, niente e' stato scritto
    /// (nemmeno nel registro); `quarantinePath` dice dove andrebbe la copia diversa.
    var wasDryRun = false
    var succeeded = false
    var failedStep: RepairStep? = nil
    var failure: RepairFailure? = nil
    /// Dove sta la copia rovinata messa da parte; `nil` se non e' stata spostata (o e' stata
    /// rimessa al suo posto).
    var quarantinePath: String? = nil
    var reusedQuarantineCopy = false
    /// Su SSD/HDD: la scrittura e' fallita dopo la quarantena, e la copia rovinata e' stata
    /// rimessa dov'era — tutto com'era prima.
    var restoredOriginal = false
    /// Su SSD/HDD: la copia buona preparata e rimasta dentro la quarantena (non si cancella).
    var leftoverStagingPath: String? = nil
    var afterSHA256: String? = nil
    var afterETag: String? = nil
    var finishedAt: Date
    /// Il registro non si e' potuto aggiornare alla fine: la riparazione e' andata come dice
    /// `succeeded`, ma il registro dice ancora «in corso».
    var logError: String? = nil
}

/// La riparazione di UNA foto, nei passi della spec: ricontrollo dal vivo, quarantena,
/// scrittura, verifica finale, registro. Il primo passo che fallisce ferma tutto e dice cosa
/// e' successo.
///
/// - Su **Cubbit**: quarantena = copia lato server in `_quarantena/<giorno>/<chiave>`,
///   IDEMPOTENTE (una copia gia' messa da parte, anche un altro giorno, con la stessa
///   dimensione e lo stesso ETag della rovinata, vale come fatta); poi HEAD della copia;
///   scrittura = `S3Syncer.upload` (la sola sovrascrittura); verifica = HEAD con l'ETag atteso.
/// - Su **SSD/HDD**: la copia buona si PREPARA prima (copia + rilettura dentro la quarantena,
///   scostamento S4), poi la rovinata si sposta in quarantena con `rename(2)` sullo stesso
///   volume, poi la preparata va al suo posto con un altro `rename(2)`. Se quest'ultimo
///   fallisce la rovinata torna dov'era. Mai `removeItem`, mai `FileManager.moveItem` (fra due
///   volumi copierebbe e poi cancellerebbe).
///
/// Le funzioni di disco, di hash e il Cubbit sono iniettati: i fallimenti da coprire (un
/// `rename` che fallisce, un disco che cambia, una copia che non torna) non si producono su
/// file veri senza una corsa. In produzione sono quelle vere (default), stesso schema di
/// `TrashRestorer`.
// `nonisolated`: `run` gira fuori dal main (rilegge file interi). Solo proprieta' `let`
// (closure `@Sendable`, URL, `Calendar`); lo stato di una riparazione e' tutto locale a `run`.
// Una alla volta: lo garantisce `BackupRunner.isRepairing`. `run` e' `@concurrent` (ADR-0006).
nonisolated final class RepairEngine: @unchecked Sendable {
    enum FileError: Error, LocalizedError {
        case destinationExists(String)
        var errorDescription: String? {
            switch self {
            case .destinationExists(let p): return "Esiste gia' un file in \(p)"
            }
        }
    }

    private let ssdRoot: URL
    private let hddRoot: URL
    private let cloud: any RepairCloud
    private let record: @Sendable (RepairRecord) throws -> Void
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let hashFile: @Sendable (URL) -> ContentReadOutcome
    private let copyFile: @Sendable (URL, URL) throws -> Void
    private let renameFile: @Sendable (URL, URL) throws -> Void
    private let volumeIdentity: @Sendable (URL) -> dev_t?
    private let makeToken: @Sendable () -> String

    init(ssdRoot: URL, hddRoot: URL, cloud: any RepairCloud,
         record: @escaping @Sendable (RepairRecord) throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = RepairPaths.defaultCalendar,
         hashFile: @escaping @Sendable (URL) -> ContentReadOutcome = { ContentHasher.digestFile(at: $0) },
         copyFile: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
         renameFile: @escaping @Sendable (URL, URL) throws -> Void = { try RepairEngine.renameWithoutOverwriting(from: $0, to: $1) },
         volumeIdentity: @escaping @Sendable (URL) -> dev_t? = { deviceIdentifier(of: $0) },
         makeToken: @escaping @Sendable () -> String = {
             String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
         }) {
        self.ssdRoot = ssdRoot
        self.hddRoot = hddRoot
        self.cloud = cloud
        self.record = record
        self.now = now
        self.calendar = calendar
        self.hashFile = hashFile
        self.copyFile = copyFile
        self.renameFile = renameFile
        self.volumeIdentity = volumeIdentity
        self.makeToken = makeToken
    }

    /// `rename(2)` senza mai sovrascrivere: se la destinazione esiste ci si ferma (zero-overwrite
    /// anche dentro la quarantena). Non `FileManager.moveItem`: fra due volumi diversi copia e
    /// poi CANCELLA l'originale, mentre `rename(2)` fallisce con `EXDEV` e non tocca niente. Il
    /// controllo e lo spostamento non sono atomici fra loro: la finestra e' di microsecondi, e
    /// nessun'altra operazione dell'app scrive mentre una riparazione e' in corso (`isRepairing`).
    nonisolated static func renameWithoutOverwriting(from: URL, to: URL) throws {
        guard !itemExists(to) else { throw FileError.destinationExists(to.path) }
        guard rename(from.path, to.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// `lstat`: vero anche per un link rotto (che `fileExists` darebbe come assente).
    nonisolated static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// `root/relative`, solo se il percorso e' sicuro e la sua cartella, risolta dal
    /// filesystem, sta davvero sotto la radice (per componenti, mai per prefisso di stringa).
    nonisolated static func confined(_ root: URL, _ relative: String) -> URL? {
        guard RepairPaths.safeComponents(relative) != nil else { return nil }
        let url = root.appendingPathComponent(relative)
        return isInside(url.deletingLastPathComponent(), root: root) ? url : nil
    }

    nonisolated static func isInside(_ dir: URL, root: URL) -> Bool {
        let r = canonicalPathComponents(of: root)
        let d = canonicalPathComponents(of: dir)
        return !r.isEmpty && d.count >= r.count && Array(d.prefix(r.count)) == r
    }

    private func root(_ a: InventoryArchive) -> URL? {
        switch a {
        case .ssd: return ssdRoot
        case .hdd: return hddRoot
        case .s3: return nil
        }
    }

    private static func isGood(_ r: ContentReadOutcome, _ good: ContentDigest) -> Bool {
        if case .digest(let d) = r { return d.sha256 == good.sha256 && d.size == good.size }
        return false
    }

    /// Una copia della rovinata gia' in quarantena su Cubbit, in un giorno qualsiasi, con la
    /// stessa dimensione e lo stesso ETag: la quarantena IDEMPOTENTE. `nil` se non c'e'.
    private func existingQuarantineCopy(of relative: String, size: Int64, etag: String?) async throws -> String? {
        try await cloud.list(prefix: RepairPaths.quarantineFolder + "/")
            .filter { RepairPaths.isQuarantineCopy($0.key, of: relative) && $0.size == size
                      && RepairRules.normalizedETag($0.etag) == etag }
            .map(\.key).sorted().first
    }

    /// `dryRun` (S11, regola 4 di `Docs/CLAUDE.md`): fa il ricontrollo dal vivo, dice dove
    /// andrebbe la copia diversa e si ferma. Nessuna scrittura su nessun archivio, nessuna voce
    /// nel registro.
    @concurrent
    func run(_ c: RepairCandidate, dryRun: Bool = false,
             onStep: @escaping @Sendable (RepairStep) -> Void = { _ in }) async -> RepairOutcome {
        let started = now()
        var out = RepairOutcome(key: c.key, target: c.target, displayPath: c.paths[c.target] ?? "", finishedAt: started)
        out.wasDryRun = dryRun
        var rec = RepairRecord(repairId: UUID().uuidString, key: c.key, displayPath: out.displayPath,
                               target: c.target.rawValue, source: c.source.rawValue, witness: c.witness.rawValue,
                               goodSHA256: c.good.sha256, goodSize: c.good.size, badSize: c.badSize,
                               badSHA256: c.badSHA256, badETag: c.badETag, startedAt: started, outcome: .inProgress)

        func finish(_ kind: RepairOutcomeKind, step: RepairStep? = nil, _ failure: RepairFailure? = nil) -> RepairOutcome {
            out.succeeded = kind == .repaired
            out.failedStep = step
            out.failure = failure
            out.finishedAt = now()
            rec.outcome = kind
            rec.failedStep = step
            rec.detail = failure.map { "\($0)" }
            rec.finishedAt = out.finishedAt
            rec.quarantinePath = out.quarantinePath
            rec.reusedQuarantineCopy = out.reusedQuarantineCopy
            rec.afterSHA256 = out.afterSHA256
            rec.afterETag = out.afterETag
            if case .logNotWritten = failure { return out }
            if out.wasDryRun { return out }
            do { try record(rec) } catch { out.logError = error.localizedDescription }
            return out
        }

        // 1. RICONTROLLO DAL VIVO. Niente e' ancora stato toccato.
        onStep(.liveCheck)
        guard c.source == RepairRules.source(forTarget: c.target), c.witness == RepairRules.witness(forTarget: c.target),
              let srcRel = c.paths[c.source], let tgtRel = c.paths[c.target], let witRel = c.paths[c.witness],
              RepairPaths.safeComponents(tgtRel) != nil, RepairPaths.safeComponents(witRel) != nil,
              c.target != .s3 || RepairRules.cubbitKeyIsRepairable(tgtRel),
              let srcRoot = root(c.source) else {
            return finish(.failed, step: .liveCheck, .unsafePath)
        }
        guard volumeIdentity(srcRoot) != nil else { return finish(.failed, step: .liveCheck, .volumeMissing(c.source)) }
        guard let srcURL = Self.confined(srcRoot, srcRel) else { return finish(.failed, step: .liveCheck, .unsafePath) }
        guard Self.isGood(hashFile(srcURL), c.good) else { return finish(.failed, step: .liveCheck, .sourceChanged) }

        if c.witness == .s3 {
            let candidate = S3ETagMatcher.Candidate(size: c.good.size, sha256: c.good.sha256, md5: c.good.md5,
                                                    multipartETag: c.good.multipartETag,
                                                    alternativeETags: c.good.alternativeMultipartETags)
            do {
                guard let h = try await cloud.head(key: witRel), h.size == c.good.size,
                      S3ETagMatcher.verdict(etag: h.etag, size: h.size, candidates: [candidate]) == .certified(sha256: c.good.sha256)
                else { return finish(.failed, step: .liveCheck, .witnessChanged) }
            } catch {
                return finish(.failed, step: .liveCheck, .cubbitError(error.localizedDescription))
            }
        } else if let witRoot = root(c.witness) {
            guard volumeIdentity(witRoot) != nil else { return finish(.failed, step: .liveCheck, .volumeMissing(c.witness)) }
            guard let witURL = Self.confined(witRoot, witRel), Self.isGood(hashFile(witURL), c.good) else {
                return finish(.failed, step: .liveCheck, .witnessChanged)
            }
        }

        let badETag = RepairRules.normalizedETag(c.badETag)
        var target: (root: URL, device: dev_t, url: URL)? = nil
        if c.target == .s3 {
            do {
                guard let h = try await cloud.head(key: tgtRel) else { return finish(.failed, step: .liveCheck, .badCopyMissing) }
                guard badETag != nil, h.size == c.badSize, RepairRules.normalizedETag(h.etag) == badETag else {
                    return finish(.failed, step: .liveCheck, .badCopyChanged)
                }
            } catch {
                return finish(.failed, step: .liveCheck, .cubbitError(error.localizedDescription))
            }
        } else if let tgtRoot = root(c.target) {
            guard let device = volumeIdentity(tgtRoot) else { return finish(.failed, step: .liveCheck, .volumeMissing(c.target)) }
            guard let url = Self.confined(tgtRoot, tgtRel) else { return finish(.failed, step: .liveCheck, .unsafePath) }
            guard Self.itemExists(url) else { return finish(.failed, step: .liveCheck, .badCopyMissing) }
            guard case .digest(let d) = hashFile(url), d.size == c.badSize, d.sha256 == c.badSHA256 else {
                return finish(.failed, step: .liveCheck, .badCopyChanged)
            }
            target = (tgtRoot, device, url)
        }

        // CONTROLLO SENZA RIPARARE: il ricontrollo e' fatto; si dice dove andrebbe la copia diversa
        // e ci si ferma, senza scrivere niente.
        if dryRun {
            if c.target == .s3 {
                do {
                    if let existing = try await existingQuarantineCopy(of: tgtRel, size: c.badSize, etag: badETag) {
                        out.quarantinePath = existing
                        out.reusedQuarantineCopy = true
                    } else {
                        guard let fresh = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                            return finish(.failed, step: .quarantine, .unsafePath)
                        }
                        if let h = try await cloud.head(key: fresh),
                           !(h.size == c.badSize && RepairRules.normalizedETag(h.etag) == badETag) {
                            return finish(.failed, step: .quarantine, .quarantineOccupied)
                        }
                        out.quarantinePath = fresh
                    }
                } catch {
                    return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
                }
            } else if let t = target {
                guard let qRel = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                    return finish(.failed, step: .quarantine, .unsafePath)
                }
                guard !Self.itemExists(t.root.appendingPathComponent(qRel)) else {
                    return finish(.failed, step: .quarantine, .quarantineOccupied)
                }
                out.quarantinePath = qRel
            }
            return finish(.repaired)
        }

        // Il registro PRIMA di toccare qualunque archivio.
        do {
            try record(rec)
        } catch {
            return finish(.failed, step: .log, .logNotWritten(error.localizedDescription))
        }

        if c.target == .s3 {
            // 2. QUARANTENA su Cubbit: copia lato server, idempotente.
            onStep(.quarantine)
            do {
                let qKey: String
                if let existing = try await existingQuarantineCopy(of: tgtRel, size: c.badSize, etag: badETag) {
                    qKey = existing
                    out.reusedQuarantineCopy = true
                } else {
                    guard let fresh = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar) else {
                        return finish(.failed, step: .quarantine, .unsafePath)
                    }
                    if let h = try await cloud.head(key: fresh) {
                        // Zero-overwrite anche in quarantena: si riusa solo se e' proprio lei.
                        guard h.size == c.badSize, RepairRules.normalizedETag(h.etag) == badETag else {
                            return finish(.failed, step: .quarantine, .quarantineOccupied)
                        }
                        out.reusedQuarantineCopy = true
                    } else {
                        try await cloud.copy(from: tgtRel, to: fresh)
                    }
                    qKey = fresh
                }
                out.quarantinePath = qKey
                guard let h = try await cloud.head(key: qKey), h.size == c.badSize,
                      RepairRules.normalizedETag(h.etag) == badETag else {
                    return finish(.failed, step: .quarantine, .quarantineCopyMismatch)
                }
            } catch {
                return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
            }

            // 3. SCRITTURA: la sola sovrascrittura del progetto.
            onStep(.write)
            do {
                try await cloud.replace(key: tgtRel, withFileAt: srcURL)
            } catch {
                return finish(.failed, step: .write, .writeFailed(error.localizedDescription))
            }

            // 4. VERIFICA FINALE: l'ETag deve essere quello della copia buona.
            onStep(.finalCheck)
            do {
                let h = try await cloud.head(key: tgtRel)
                out.afterETag = h?.etag
                guard let h, h.size == c.good.size,
                      RepairRules.normalizedETag(h.etag) == RepairRules.expectedCubbitETag(for: c.good) else {
                    return finish(.verificationFailed, step: .finalCheck, .finalCheckFailed)
                }
            } catch {
                return finish(.verificationFailed, step: .finalCheck, .cubbitError(error.localizedDescription))
            }
        } else if let t = target {
            let token = makeToken()
            guard let qRel = RepairPaths.quarantinePath(for: tgtRel, date: started, calendar: calendar),
                  let stRel = RepairPaths.stagingPath(for: tgtRel, date: started, calendar: calendar, token: token) else {
                return finish(.failed, step: .write, .unsafePath)
            }
            let qURL = t.root.appendingPathComponent(qRel)
            let stURL = t.root.appendingPathComponent(stRel)
            let qDir = qURL.deletingLastPathComponent()

            // 2a. PREPARAZIONE della copia buona, dentro la quarantena: la foto non e' ancora toccata.
            onStep(.write)
            guard volumeIdentity(t.root) == t.device else { return finish(.failed, step: .write, .volumeMissing(c.target)) }
            guard !Self.itemExists(qURL) else { return finish(.failed, step: .write, .quarantineOccupied) }
            do {
                try FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)
            } catch {
                return finish(.failed, step: .write, .stagingFailed(error.localizedDescription))
            }
            // `createDirectory` su un disco appena sparito creerebbe la cartella sul disco del
            // Mac: dopo averla creata, deve stare sullo stesso disco e sotto la radice.
            guard volumeIdentity(qDir) == t.device, Self.isInside(qDir, root: t.root) else {
                return finish(.failed, step: .write, .unsafePath)
            }
            do {
                try copyFile(srcURL, stURL)
            } catch {
                if Self.itemExists(stURL) { out.leftoverStagingPath = stRel }
                return finish(.failed, step: .write, .stagingFailed(error.localizedDescription))
            }
            out.leftoverStagingPath = stRel
            guard Self.isGood(hashFile(stURL), c.good) else { return finish(.failed, step: .write, .stagingMismatch) }

            // 2b. QUARANTENA: la copia rovinata si sposta, sullo stesso volume.
            onStep(.quarantine)
            guard volumeIdentity(t.root) == t.device else { return finish(.failed, step: .quarantine, .volumeMissing(c.target)) }
            do {
                try renameFile(t.url, qURL)
            } catch {
                return finish(.failed, step: .quarantine, .quarantineFailed(error.localizedDescription))
            }
            out.quarantinePath = qRel

            // 3. SCRITTURA: la copia preparata al suo posto. Se fallisce, la rovinata torna dov'era.
            onStep(.write)
            do {
                try renameFile(stURL, t.url)
                out.leftoverStagingPath = nil
            } catch {
                if (try? renameFile(qURL, t.url)) != nil {
                    out.restoredOriginal = true
                    out.quarantinePath = nil
                }
                return finish(.failed, step: .write, .writeFailed(error.localizedDescription))
            }

            // 4. VERIFICA FINALE: rilettura della foto al suo posto.
            onStep(.finalCheck)
            let after = hashFile(t.url)
            if case .digest(let d) = after { out.afterSHA256 = d.sha256 }
            guard Self.isGood(after, c.good) else { return finish(.verificationFailed, step: .finalCheck, .finalCheckFailed) }
        } else {
            return finish(.failed, step: .liveCheck, .unsafePath)
        }

        // 5. REGISTRO.
        onStep(.log)
        return finish(.repaired)
    }
}

// MARK: - Riparazione: i testi (ROADMAP #45, ADR-0016)

/// I testi della riparazione nella finestra Inventario. Logica pura, come `InventoryStatus`:
/// nessuna stringa nasce dentro la View. Registro: niente gergo («hash», «impronta», «ETag»,
/// «MD5», «bucket»...). La cartella «_quarantena» si nomina, tra virgolette: e' quella che
/// Enrico vedra' nel Finder e svuotera' lui (decisione 4 della spec).
enum RepairStatus {
    static let buttonTitle = "Ripara…"
    static let continueButton = "Continua…"
    static let cancelButton = "Annulla"
    static let confirmTitle = "Riparare questa foto?"
    static let confirmButton = "Ripara"
    static let summaryTitle = "Riparazione di una foto"
    /// Il controllo senza riparare (S11): rilegge e ricontrolla, non scrive niente.
    static let dryRunButton = "Controlla senza riparare"

    static func sectionTitle(count: Int) -> String {
        count == 1 ? "1 foto si può riparare" : "\(count.formatted()) foto si possono riparare"
    }

    static let sectionExplanation = "Per ognuna, due posti su tre hanno la stessa copia integra e il terzo una "
        + "copia diversa. L'app può rimettere a posto la copia diversa, una foto alla volta: prima ricontrolla "
        + "tutto, poi mette da parte la copia diversa senza cancellarla."

    static func candidateLine(_ c: RepairCandidate) -> String {
        "«\(c.paths[c.target] ?? c.key)» — diversa \(on(c.target)); uguale \(on(c.source)) e \(on(c.witness))"
    }

    /// Il riepilogo prima della conferma: cosa e' diverso, cosa l'app ricontrolla, dove va la
    /// copia diversa, cosa scrive al suo posto, cosa non tocca.
    static func summaryLines(_ c: RepairCandidate, date: Date, calendar: Calendar) -> [String] {
        let path = c.paths[c.target] ?? c.key
        let q = RepairPaths.quarantinePath(for: path, date: date, calendar: calendar) ?? "«\(RepairPaths.quarantineFolder)»"
        var lines = ["Foto: «\(path)»."]
        lines.append("\(capitalized(on(c.target))) la copia è diversa da quella \(on(c.source)) e da quella "
                     + "\(on(c.witness)), che sono identiche fra loro.")
        lines.append("Prima di toccare qualcosa l'app rilegge per intero la copia \(on(c.source)), ricontrolla "
                     + "quella \(on(c.witness)) e quella \(on(c.target)): se anche una sola non è più com'era "
                     + "nell'ultimo inventario, si ferma senza toccare niente.")
        if c.target == .s3 {
            lines.append("La copia diversa non viene cancellata: viene messa da parte su Cubbit, in «\(q)». Se "
                         + "era già stata messa da parte un altro giorno, l'app usa quella.")
            lines.append("Al suo posto l'app carica la copia \(on(c.source)), poi controlla che Cubbit abbia "
                         + "proprio quella.")
        } else {
            lines.append("La copia diversa non viene cancellata: viene spostata \(on(c.target)) stesso, in «\(q)».")
            lines.append("Al suo posto l'app copia quella \(on(c.source)), la rilegge e controlla che sia identica.")
        }
        lines.append("Non viene toccato nient'altro. La cartella «\(RepairPaths.quarantineFolder)» la svuoti tu, "
                     + "quando vuoi.")
        return lines
    }

    static func confirmMessage(_ c: RepairCandidate) -> String {
        "La copia \(on(c.target)) di «\(c.paths[c.target] ?? c.key)» verrà sostituita da quella "
            + "\(on(c.source)). La copia diversa resta da parte in «\(RepairPaths.quarantineFolder)»."
    }

    static func progressLine(_ step: RepairStep?) -> String {
        switch step {
        case nil: return "Controllo che Cubbit risponda…"
        case .liveCheck: return "Ricontrollo le tre copie…"
        case .quarantine: return "Metto da parte la copia diversa…"
        case .write: return "Scrivo la copia buona…"
        case .finalCheck: return "Controllo la foto riparata…"
        case .log: return "Annoto la riparazione sul Mac…"
        }
    }

    /// La riparazione riuscita di questa voce, se e' piu' recente dell'ultimo inventario: la voce
    /// resta in ❗ fino al giro successivo, con «riparata il …» al posto di «Ripara…».
    static func awaitingConfirmation(_ c: RepairCandidate, records: [RepairRecord],
                                     states: [InventoryArchive: InventoryArchiveState]) -> RepairRecord? {
        let lastInventory = Date(timeIntervalSince1970: states.values.map(\.startedAt).max() ?? 0)
        return records
            .filter { $0.key == c.key && $0.target == c.target.rawValue && $0.outcome == .repaired
                      && ($0.finishedAt ?? $0.startedAt) > lastInventory }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }

    static func repairedLine(_ r: RepairRecord, calendar: Calendar = .current) -> String {
        "Riparata il \(day(r.finishedAt ?? r.startedAt, calendar: calendar)): aggiorna l'inventario per confermarlo."
    }

    static func failureText(_ f: RepairFailure) -> String {
        switch f {
        case .volumeMissing(let a):
            return "\(name(a)) non è collegato, o è stato scollegato proprio mentre l'app lavorava."
        case .unsafePath:
            return "Il percorso di questa foto non è sicuro da usare: l'app non scrive fuori dalla sua cartella."
        case .sourceChanged:
            return "La copia da cui l'app avrebbe copiato non è più quella vista nell'ultimo inventario, "
                + "oppure non si lascia leggere."
        case .witnessChanged:
            return "La seconda copia buona non è più identica alla prima: senza due copie d'accordo l'app non ripara."
        case .badCopyMissing:
            return "La copia diversa non c'è più dove l'inventario l'aveva vista."
        case .badCopyChanged:
            return "La copia diversa è cambiata dall'ultimo inventario."
        case .cubbitError:
            return "Cubbit non ha risposto come doveva."
        case .logNotWritten:
            return "L'app non è riuscita a scrivere sul Mac il registro delle riparazioni, quindi non ha cominciato."
        case .quarantineOccupied:
            return "In «\(RepairPaths.quarantineFolder)» c'è già un file con lo stesso nome ma diverso: l'app non "
                + "lo sovrascrive."
        case .quarantineFailed:
            return "Non è stato possibile mettere da parte la copia diversa."
        case .quarantineCopyMismatch:
            return "La copia messa da parte non è risultata identica a quella diversa: l'app si è fermata prima di scrivere."
        case .stagingFailed:
            return "Non è stato possibile preparare la copia buona (spazio o permessi sul disco)."
        case .stagingMismatch:
            return "La copia buona preparata non è risultata identica all'originale."
        case .writeFailed:
            return "Non è stato possibile mettere la copia buona al suo posto."
        case .finalCheckFailed:
            return "Dopo la scrittura la foto non è risultata identica alla copia buona."
        }
    }

    /// Com'e' andata, sempre con un numero onesto di cosa e' cambiato e dove sta ogni copia.
    static func outcomeLines(_ o: RepairOutcome) -> [InventoryStatus.Line] {
        typealias Line = InventoryStatus.Line
        var out: [Line] = []
        let path = "«\(o.displayPath)»"
        if o.wasDryRun {
            if o.succeeded {
                out.append(Line(id: "dry-ok", tone: .ok, text:
                    "\(path): controllo riuscito, non è stato toccato niente. Le tre copie sono come "
                    + "nell'ultimo inventario."))
                if let q = o.quarantinePath {
                    out.append(Line(id: "dry-where", tone: .info, text: o.reusedQuarantineCopy
                        ? "La copia diversa è già da parte in «\(q)»: riparando, l'app userebbe quella."
                        : "Riparando, la copia diversa andrebbe in «\(q)» \(on(o.target))."))
                }
            } else {
                out.append(Line(id: "dry-failed", tone: .warning, text:
                    "\(path): il controllo si è fermato, non è stato toccato niente."))
                if let f = o.failure { out.append(Line(id: "repair-why", tone: .warning, text: failureText(f))) }
            }
            return out
        }
        if o.succeeded {
            var text = "\(path) riparata \(on(o.target))."
            if let q = o.quarantinePath {
                text += o.reusedQuarantineCopy
                    ? " La copia diversa era già da parte in «\(q)»."
                    : " La copia diversa è da parte in «\(q)»."
            }
            out.append(Line(id: "repair-done", tone: .ok, text: text))
            out.append(Line(id: "repair-confirm", tone: .info, text: "Aggiorna l'inventario per confermarlo."))
        } else {
            out.append(Line(id: "repair-failed", tone: .warning, text: "\(path): riparazione non fatta."))
            if let f = o.failure { out.append(Line(id: "repair-why", tone: .warning, text: failureText(f))) }
            out.append(Line(id: "repair-state", tone: .info, text: stateLine(o)))
            if let st = o.leftoverStagingPath {
                out.append(Line(id: "repair-staging", tone: .info, text:
                    "La copia buona preparata è rimasta in «\(st)»: puoi lasciarla lì, se ne va quando svuoti "
                    + "«\(RepairPaths.quarantineFolder)»."))
            }
        }
        if o.logError != nil {
            out.append(Line(id: "repair-log", tone: .warning, text:
                "L'app non è riuscita ad annotare sul Mac come è finita: il registro dice ancora «in corso»."))
        }
        return out
    }

    private static func stateLine(_ o: RepairOutcome) -> String {
        if o.failedStep == .finalCheck {
            let q = o.quarantinePath.map { " resta in «\($0)»" } ?? " resta da parte"
            return "La copia diversa\(q). L'app non riprova da sola: aggiorna l'inventario e guarda di nuovo "
                + "questa foto."
        }
        if o.failedStep == .liveCheck || o.failedStep == .log || (o.quarantinePath == nil && o.target != .s3) {
            return o.restoredOriginal
                ? "La copia diversa è tornata al suo posto: tutto è com'era prima."
                : "Non è stato toccato niente."
        }
        if o.target == .s3 {
            if let q = o.quarantinePath {
                return "Su Cubbit la copia diversa è ancora al suo posto, e una copia è anche in «\(q)»."
            }
            return "Su Cubbit la copia diversa è ancora al suo posto."
        }
        return "La copia diversa è da parte in «\(o.quarantinePath ?? RepairPaths.quarantineFolder)» "
            + "\(on(o.target)) e non è andata persa, ma al suo posto per ora non c'è niente."
    }

    // MARK: - Aiuti

    private static func name(_ a: InventoryArchive) -> String { InventoryStatus.archiveName(a) }

    private static func on(_ a: InventoryArchive) -> String {
        switch a {
        case .ssd: return "sull'SSD"
        case .hdd: return "sull'HDD"
        case .s3: return "su Cubbit"
        }
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static func day(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: d)
    }
}

// MARK: - Riparazione: il Cubbit vero (ROADMAP #45, ADR-0016)

/// `RepairCloud` sopra un `S3Syncer` DEDICATO alla riparazione — mai `BackupRunner.s3Syncer`,
/// che condivide il flag di interruzione con i job (stessa regola dell'inventario e del
/// ricalcolo dello spazio di Cubbit).
// `nonisolated`: solo proprieta' `let`. `S3Syncer` e' isolato al MainActor (quindi `Sendable`):
// ogni chiamata salta sul main per il tempo di costruire e firmare la richiesta, l'attesa di
// rete no. `replaceObjectForRepair` legge il file come il backup (`Data(contentsOf:)` fino a
// 64 MiB, a pezzi sopra): per una foto sono millisecondi.
nonisolated final class S3RepairCloud: RepairCloud, @unchecked Sendable {
    private let syncer: S3Syncer
    private let config: S3Syncer.S3Config

    init(syncer: S3Syncer, config: S3Syncer.S3Config) {
        self.syncer = syncer
        self.config = config
    }

    func head(key: String) async throws -> S3Syncer.S3ObjectHead? {
        try await syncer.headObject(config: config, key: key)
    }

    func list(prefix: String) async throws -> [S3Syncer.S3ObjectInfo] {
        try await syncer.listObjects(config: config, prefix: prefix)
    }

    func copy(from sourceKey: String, to destinationKey: String) async throws {
        try await syncer.copyObject(config: config, from: sourceKey, to: destinationKey)
    }

    func replace(key: String, withFileAt url: URL) async throws {
        try await syncer.replaceObjectForRepair(config: config, key: key, withFileAt: url)
    }
}

// MARK: - Testi e regole della card "Foto gia' salvate" (roadmap #31, Task 6)

/// I nomi dei comandi della card, in un punto solo. Non e' pignoleria: due dei messaggi
/// dicono all'utente **quale bottone premere**, e se il nome vivesse in due posti la prima
/// rinomina lascerebbe un messaggio che indica un bottone che non esiste piu'.
enum LibraryIndexCommands {
    /// Titolo della card di Diagnostica. In un punto solo perche' compare anche fuori dalla
    /// card (il rimando di `DuplicatesStatus.headerLine` e, dal 2026-09-19, il riepilogo del
    /// passo 2 del backup quando c'e' qualcosa da controllare in Diagnostica).
    static let cardTitle = "Foto già salvate sull'SSD"
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
/// sapeva di un job di copia in corso (allora `LibraryIndexAutoRefresh.shouldRun`, parametro
/// `jobIsRunning` — quella funzione e' stata rimossa il 2026-09-19, vedi la nota su
/// `LibraryIndexAutoRefresh`) mentre i bottoni della card no — erano disattivati solo durante
/// una lettura. Chi premeva «\(LibraryIndexCommands.refresh)» durante un backup faceva leggere
/// e rihashare per intero l'SSD mentre una copia ci stava scrivendo sopra: le due operazioni
/// si rallentano a vicenda e i file che la copia sta scrivendo proprio ora finiscono contati
/// come illeggibili. E' la stessa classe di problema chiusa il 2026-09-01 nel pannello
/// Doppioni, dove le precondizioni del blocco venivano valutate una volta sola.
///
/// Restituisce **il motivo scritto**, non un booleano: disattivare un bottone senza dire
/// perche' e' la disciplina che questo progetto ha gia' scelto contro, in `RestoreView`
/// (fonti non disponibili) e nel pannello Doppioni.
/// Perche' un job che scrive (MAC -> SSD, SSD -> HDD, SSD -> Cubbit, importazione) non puo'
/// partire adesso, oppure `nil`. Consultato da `BackupRunner.run(label:...)`, il punto da cui
/// passano tutti.
///
/// Esiste dal 2026-09-19. Fino a quel giorno lo spostamento nel Cestino e la lettura
/// dell'elenco giravano per errore sul main thread, e nessun backup poteva partire mentre
/// erano in corso perche' l'app era bloccata: la mutua esclusione la garantiva il bug. Tolto
/// il bug (BUG-7), la garantisce questo gate. Il verso opposto (niente spostamento durante un
/// job o una lettura) e' in `DuplicatesStatus.trashDisabledReason` e `LibraryIndexCommandGate`.
///
/// Risposta di Enrico alla domanda aperta 1 della spec (2026-09-19): il backup NON parte e
/// l'app spiega perche' con un messaggio chiaro, senza gergo tecnico.
///
/// NON `nonisolated`: chiamato solo da `BackupRunner.run(label:...)`, gia' sul MainActor, e
/// la sua frase su `isIndexing` cita `LibraryIndexCommands.stop`, che e' anch'esso
/// MainActor per il default del target — nessun motivo di annotarlo diversamente.
enum JobStartGate {
    /// Precedenza (Task 5, ADR-0009): spostamento nel Cestino > annullamento dell'ultimo
    /// spostamento > lettura dell'elenco. Le due operazioni sul Cestino sono le piu' vicine
    /// al percorso a danno piu' alto del progetto (ADR-0005); non possono comunque coesistere
    /// fra loro (si escludono a vicenda in `BackupRunner`), ma l'ordine qui fissa comunque
    /// quale frase l'utente legge se mai lo stato risultasse incoerente.
    static func blockedReason(isIndexing: Bool, isTrashingDuplicates: Bool,
                              isRestoringFromTrash: Bool, isInventorying: Bool, isRepairing: Bool) -> String? {
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino le copie doppie che hai confermato. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto le foto che avevi spostato nel Cestino. "
                + "Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni."
        }
        // ROADMAP #45: la riparazione scrive su SSD, HDD o Cubbit; un job che copia negli
        // stessi posti nello stesso momento potrebbe copiare la foto a meta' riparazione.
        if isRepairing {
            return "L'app sta riparando una foto. Aspetta che finisca: di solito bastano pochi secondi."
        }
        // ROADMAP #44: l'inventario legge SSD, HDD e Cubbit; un job che ci scrive sopra
        // renderebbe falso quello che sta leggendo.
        if isInventorying {
            return "L'app sta facendo l'inventario di SSD, HDD e Cubbit. Aspetta che finisca, "
                + "oppure fermalo con «\(InventoryStatus.stopButton)» nella finestra Inventario."
        }
        if isIndexing {
            return "L'app sta leggendo le foto sull'SSD per aggiornare l'elenco. Aspetta che "
                + "finisca, oppure fermala con «\(LibraryIndexCommands.stop)» in Diagnostica."
        }
        return nil
    }
}

enum LibraryIndexCommandGate {
    /// `nil` quando i comandi si possono usare. La lettura in corso ha la precedenza sul job
    /// perche' e' la causa piu' vicina a quello che l'utente sta guardando: se sta scorrendo
    /// la barra di avanzamento, la frase sul backup lo confonderebbe.
    static func disabledReason(isIndexing: Bool, jobIsRunning: Bool,
                               isTrashingDuplicates: Bool, isRestoringFromTrash: Bool,
                               isInventorying: Bool, isRepairing: Bool) -> String? {
        // Lo spostamento nel Cestino ha la precedenza sulle altre: da quando gira
        // davvero fuori dal main (2026-09-19, BUG-7) puo' essere in corso insieme a
        // un'altra causa, ed e' quella piu' vicina al danno se qualcuno lo ignorasse.
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino le copie doppie che hai confermato: "
                + "leggere le foto adesso darebbe un elenco sbagliato. Riprova quando ha finito."
        }
        if isRestoringFromTrash {
            return "L'app sta rimettendo a posto le foto spostate nel Cestino: leggere le foto "
                + "adesso darebbe un elenco sbagliato. Riprova quando ha finito."
        }
        if isRepairing {
            return "L'app sta riparando una foto: leggere le foto adesso potrebbe trovarla a metà. "
                + "Riprova quando ha finito."
        }
        if isInventorying {
            return "L'app sta facendo l'inventario e sta leggendo le stesse foto: aggiornare "
                + "l'elenco adesso rallenterebbe entrambe le cose. Riprova quando ha finito."
        }
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

    /// Lo svuotamento ha un motivo **suo**: non legge l'SSD, quindi la frase sulla lettura
    /// concorrente sarebbe falsa. Il danno e' un altro — un'importazione in corso si appoggia
    /// all'elenco per non ricopiare foto che ci sono gia', e togliergielo sotto significa
    /// ricopiarle.
    /// Non guarda la riparazione (ROADMAP #45), di proposito: la riparazione non scrive in
    /// questo elenco (il suo registro e' un file a parte) e non lo legge mentre lavora.
    static func resetDisabledReason(isIndexing: Bool, jobIsRunning: Bool,
                                    isTrashingDuplicates: Bool, isInventorying: Bool) -> String? {
        if isTrashingDuplicates {
            return "L'app sta spostando nel Cestino le copie doppie e intanto aggiorna "
                + "l'elenco: svuotarlo adesso lo lascerebbe a metà. Riprova quando ha finito."
        }
        if isInventorying {
            return "L'inventario sta scrivendo in questo stesso elenco: svuotarlo adesso lo "
                + "lascerebbe a metà. Riprova quando ha finito."
        }
        if isIndexing {
            return "L'app sta leggendo le foto sull'SSD proprio ora. Fermala con "
                + "«\(LibraryIndexCommands.stop)» prima di svuotare l'elenco."
        }
        if jobIsRunning {
            return "C'è un backup in corso, e si sta appoggiando a questo elenco per non "
                + "ricopiare foto che hai già. Svuotarlo adesso gliele farebbe ricopiare. "
                + "Riprova a backup finito."
        }
        return nil
    }
}

/// Chiave e stato dell'interruttore "Aggiorna l'elenco delle foto alla fine di ogni backup"
/// in Impostazioni. Fino al 2026-09-19 questo tipo decideva anche **quando** una lettura
/// automatica poteva partire da sola (`shouldRun`, rimossa: vedi la nota accanto a
/// `BackupRunner.rebuildLibraryIndex`) — quella decisione ora vive in
/// `BackupListStep.shouldRun`, perche' il passo 2 del backup **e'** il job: non c'e' piu' un
/// "in parallela a un job" da escludere, c'e' solo "dentro il job".
enum LibraryIndexAutoRefresh {
    static let defaultsKey = "autoRefreshLibraryIndex"

    /// L'interruttore vale `true` finche' l'utente non lo tocca. `UserDefaults.bool` non va
    /// bene: risponde `false` per una chiave mai scritta, e `@AppStorage` la scrive solo al
    /// primo cambiamento — l'aggiornamento automatico resterebbe spento per default, al
    /// contrario di quello che dice l'interruttore in Impostazioni.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

// MARK: - Da quando l'elenco non e' aggiornato (Task 12, D15-D17)

/// Chiave `UserDefaults` dell'istante dell'ultima lettura arrivata **in fondo** (D15, spec
/// 2026-09-24 §4.1). Scritta in **un punto solo**: il `onFinish` di
/// `BackupRunner.startLibraryIndexScan`, dove la completezza e' gia' nota. Vale per tutti gli
/// ingressi (bottone manuale, passo 2 del backup): passano tutti da quella funzione.
/// `deleteIndexAndRecreate()` la azzera.
nonisolated let libraryListLastCompleteReadDefaultsKey = "libraryListLastCompleteReadAt"

/// Da quanto l'elenco delle foto gia' sull'SSD non viene rimesso in pari. Usato **sia** dal
/// passo di anteprima del wizard di import **sia** dalla card di Diagnostica: una sola fonte
/// per il testo, come `LibraryIndexStatus`/`DuplicatesStatus`. Registro anti-gergo: niente
/// "indice"/"hash"/"scansione"/"registro"/"cache" in nessuna delle cinque diramazioni.
nonisolated enum LibraryListFreshness {
    enum Tone { case ok, info, warning }
    struct Line: Identifiable { let id: String; let tone: Tone; let text: String }

    /// 14 giorni (D16): l'asimmetria fra i due errori — a 30 giorni l'avviso comparirebbe
    /// troppo raramente, col ritmo reale di backup, per essere utile; a 2-3 giorni
    /// comparirebbe sempre, e "sovrastimare i problemi insegna a ignorare l'allarme" e' un
    /// principio gia' applicato in questo progetto (ADR-0007). Due settimane e' abbastanza
    /// per aver dimenticato di aver copiato qualcosa dal Finder, abbastanza poco perche'
    /// rimediare costi pochi minuti.
    static let thresholdDays = 14

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    /// Vero solo se la lettura e' arrivata davvero in fondo: niente lanciato, e la
    /// traversata ha coperto tutta la libreria. `traversalIncomplete` include GIA'
    /// `cancelled`/`volumeVanished`/le cartelle illeggibili (vedi i doc-comment su
    /// `LibraryIndexer.Progress` e la riga che li assegna in `scan`): un controllo solo, non
    /// tre che potrebbero divergere silenziosamente l'uno dall'altro in futuro.
    static func readReachedTheEnd(progress: LibraryIndexer.Progress?, error: Error?) -> Bool {
        guard error == nil, let progress else { return false }
        return !progress.traversalIncomplete
    }

    /// La riga da mostrare — cinque diramazioni (spec §4.3), non due: "mai creato" e "data
    /// non disponibile" sono situazioni diverse (la prima non ha nessuna foto conosciuta, la
    /// seconda ne ha ma non sa da quando), e leggerle come la stessa cosa direbbe il falso
    /// in una delle due.
    ///
    /// - Parameter hasAnyEntries: l'elenco esiste (almeno una foto conosciuta)? Se `false`,
    ///   `lastCompleteReadAt` non conta: e' sempre la diramazione 1, mai la 4.
    /// - Parameter lastCompleteReadAt: la data dell'ultima lettura arrivata in fondo, letta
    ///   dalla chiave dedicata — o il ripiego `LibraryIndexStore.newestHashedAt()` se quella
    ///   manca. E' un limite **inferiore**: una lettura incrementale che non trova niente di
    ///   nuovo non tocca nessun `hashed_at`, quindi il ripiego puo' far sembrare l'elenco PIU'
    ///   vecchio di quanto e' — mai il contrario, mai un avviso taciuto.
    /// - Parameter isReading: una lettura e' in corso adesso — precede tutto il resto; il
    ///   bottone di avvio e' comunque gia' disattivato da `JobStartGate`.
    static func line(hasAnyEntries: Bool, lastCompleteReadAt: Date?, isReading: Bool,
                     now: Date = Date()) -> Line {
        if isReading {
            return Line(id: "reading", tone: .info, text:
                "L'app sta controllando l'SSD per rimettere in pari l'elenco: aspetta che finisca.")
        }
        guard hasAnyEntries else {
            return Line(id: "never-built", tone: .warning, text:
                "Non hai ancora creato l'elenco delle foto già salvate sull'SSD: l'app non può "
                    + "sapere quali di queste foto hai già, e le copierà tutte.")
        }
        guard let lastCompleteReadAt else {
            return Line(id: "unknown", tone: .info, text:
                "L'app non sa da quando l'elenco delle foto già sull'SSD non viene rimesso in pari.")
        }
        // Giorni interi trascorsi, mai frazionari: alla soglia esatta (14 giorni, zero
        // secondi in piu') deve scattare l'avviso, non restare neutro per un arrotondamento.
        let days = Int(now.timeIntervalSince(lastCompleteReadAt) / 86_400)
        let dateText = dateFormatter.string(from: lastCompleteReadAt)
        guard days >= thresholdDays else {
            return Line(id: "fresh", tone: .ok, text:
                "L'elenco delle foto già sull'SSD è aggiornato a \(dateText).")
        }
        return Line(id: "stale", tone: .warning, text:
            "L'elenco delle foto già sull'SSD è fermo al \(dateText), \(agoText(days: days)). Se "
                + "da allora hai copiato foto sull'SSD dal Finder, l'app non le conosce e "
                + "potrebbe importarle di nuovo.")
    }

    /// "tre settimane fa" — mai una cifra grezza di giorni sopra la soglia: si scrive in
    /// settimane, come l'esempio della spec. Sotto una settimana resta in giorni, col
    /// plurale giusto. **Non `private`**, apposta: con `thresholdDays == 14` la diramazione
    /// "stale" di `line(...)` non raggiunge mai `weeks < 2`, quindi i plurali di giorni e la
    /// settimana singola sono testabili solo chiamando questa funzione **direttamente** — la
    /// stessa ragione per cui `FileSyncer.SyncResult.hms` non e' `private`.
    static func agoText(days: Int) -> String {
        let weeks = days / 7
        guard weeks > 0 else { return days == 1 ? "un giorno fa" : "\(days) giorni fa" }
        return weeks == 1 ? "una settimana fa" : "\(weeks) settimane fa"
    }
}

// MARK: - Il passo 2 del backup: l'elenco si aggiorna come ultima parte del job (2026-09-19)

/// Logica **pura** del passo 2 di MAC -> SSD e di un'importazione (spec
/// `Docs/superpowers/specs/2026-09-19-index-refresh-as-backup-step-design.md`, ADR-0007):
/// se e quando parte, la stima e la percentuale mostrate mentre gira, l'esito con cui
/// finisce e ogni testo che arriva a schermo. Nessun accesso a filesystem/SQLite qui dentro
/// — quello resta in `BackupRunner.startLibraryIndexScan`. Stesso stile isolamento di
/// `LibraryIndexAutoRefresh`: chiamato solo dal MainActor e dai test.
///
/// Registro: nessun gergo ("indice", "hash", "scansione", "sqlite", ...) in nessun testo
/// prodotto — stessa lista di `LibraryIndexStatusTests`.
enum BackupListStep {
    /// Stato del passo 2, pubblicato da `BackupRunner` per la durata dell'intero job.
    /// `nil` = nessun passo 2 previsto per questo job (job che non scrive sull'SSD, o
    /// condizioni che lo escludono). `.planned` = previsto, il passo 1 (la copia) e' ancora
    /// in corso. `.running` = il passo 1 e' finito e la lettura sta girando.
    enum State: Equatable {
        case planned
        case running(estimate: Int)
    }

    /// Come e' andato il passo 2, precedenza dall'alto in basso — non alternative
    /// indipendenti: piu' condizioni possono essere vere insieme (es. l'utente ha premuto
    /// Interrompi mentre l'SSD stava anche per scollegarsi), e conta solo la prima che si
    /// applica.
    enum Outcome: Equatable {
        case couldNotUpdate       // non e' partito, o la lettura ha lanciato un errore
        case stoppedByYou         // "Interrompi" dell'utente
        case ssdDisconnected      // l'SSD (la root che si stava leggendo) e' sparito
        case stoppedByAnotherDisk // smontato un disco diverso: l'osservatore non filtra per volume
        case updatedWithRemarks   // completato, ma la card di Diagnostica avrebbe un avviso
        case updated              // completato, niente da segnalare
    }

    /// Cosa mostrare in `StatsPanel` durante il passo 2. Valore puro calcolato dal runner
    /// (`BackupRunner.listStepPresentation`) da `stats`/`indexProgress`/`listStepState`:
    /// nessuna stringa nasce nella View.
    struct Presentation {
        let copyDone: (text: String, clean: Bool)
        let runningLine: String
        let countLine: String
    }

    /// Parte solo se il job scrive sull'SSD, l'interruttore e' acceso, l'elenco esiste gia'
    /// (la prima creazione resta manuale, dura minuti), e non c'e' gia' un'altra lettura o
    /// uno spostamento nel Cestino in corso. Non riceve `jobIsRunning`: e' chiamata da
    /// dentro il job stesso, che a questo punto e' per definizione in corso.
    static func shouldRun(refreshesLibraryIndex: Bool, enabled: Bool, indexedFileCount: Int,
                          isIndexing: Bool, isTrashingDuplicates: Bool) -> Bool {
        refreshesLibraryIndex && enabled && indexedFileCount > 0 && !isIndexing && !isTrashingDuplicates
    }

    /// Stima di quanti file la lettura controllera': le voci gia' in elenco piu' i file
    /// copiati dal passo 1 (verificati o no). Il totale vero non si conosce prima che la
    /// lettura finisca — costerebbe una seconda traversata dell'SSD per saperlo prima.
    static func estimate(indexedBefore: Int, copied: Int, copiedUnverified: Int) -> Int {
        indexedBefore + copied + copiedUnverified
    }

    /// Percentuale e totale mostrati mentre il passo 2 gira. Il totale mostrato non torna
    /// mai indietro (segue `scanned` se supera la stima), e la percentuale non tocca mai il
    /// 100: quello lo scrive solo la fine del job.
    static func progress(scanned: Int, estimate: Int) -> (percent: Int, shownTotal: Int) {
        let shownTotal = max(estimate, scanned)
        guard shownTotal > 0 else { return (0, 0) }
        let raw = Int((Double(scanned) / Double(shownTotal) * 100).rounded(.down))
        return (min(99, raw), shownTotal)
    }

    /// Esito finale, con le precedenze della spec (tabella D6). `progress` e' quello
    /// restituito da `LibraryIndexer.scan` quando e' arrivata a finire (anche se fermata a
    /// meta'); `couldNotStart`/`scanFailed` coprono i casi in cui non c'e' un `Progress`
    /// utilizzabile.
    static func outcome(progress: LibraryIndexer.Progress?, interruptedByUser: Bool,
                        couldNotStart: Bool, scanFailed: Bool) -> Outcome {
        if couldNotStart || scanFailed { return .couldNotUpdate }
        guard let p = progress else { return .couldNotUpdate }
        if interruptedByUser { return .stoppedByYou }
        if p.volumeVanished { return .ssdDisconnected }
        if p.cancelled { return .stoppedByAnotherDisk }
        // Stessa definizione di "qualcosa non torna" della card di Diagnostica — una sola
        // fonte: se domani la card cambia idea su un caso, il riepilogo cambia con lei.
        if LibraryIndexStatus.lines(for: p, interruptedByUser: false).contains(where: { $0.tone == .warning }) {
            return .updatedWithRemarks
        }
        return .updated
    }

    /// Intestazione della finestra durante il job. `nil` = nessun passo 2 previsto: etichetta
    /// invariata, esattamente come prima di questa spec.
    static func header(label: String, state: State?) -> String {
        switch state {
        case .none: return label
        case .planned: return "\(label) — passo 1 di 2"
        case .running: return "\(label) — passo 2 di 2"
        }
    }

    /// Riga "Foto copiate" del passo 2, con `clean == false` (niente spunta verde) se ci sono
    /// stati errori. "nuove" = copiate, verificate o no; "già presenti" = skippate perche'
    /// gia' a destinazione o perche' riconosciute come doppioni gia' in libreria.
    static func copyDoneLine(stats: JobStats) -> (text: String, clean: Bool) {
        let new = stats.copied + stats.copiedUnverified
        let alreadyThere = stats.skipped + stats.duplicatesSkipped
        let problems = stats.errors + stats.hashErrors
        var text = "Foto copiate (\(new.formatted()) \(new == 1 ? "nuova" : "nuove"), "
            + "\(alreadyThere.formatted()) \(alreadyThere == 1 ? "già presente" : "già presenti")"
        if problems > 0 {
            text += ", \(problems.formatted()) \(problems == 1 ? "non copiata per errore" : "non copiate per errore")"
        }
        text += ")"
        return (text, problems == 0)
    }

    static let runningLine = "Aggiorno l'elenco delle foto sull'SSD…"

    static func countLine(scanned: Int, shownTotal: Int) -> String {
        "\(scanned.formatted()) / \(shownTotal.formatted()) file controllati"
    }

    static let stoppingLabel = "Mi fermo…"

    /// Riga aggiunta al riepilogo di fine job quando c'e' stato un passo 2. Il titolo e
    /// l'icona del riepilogo restano quelli di oggi ("Backup completato", verde): il job e'
    /// riuscito per costruzione, le foto sono copiate e verificate anche quando il passo 2
    /// si e' fermato.
    static func completionLine(_ o: Outcome) -> (text: String, tone: LibraryIndexStatus.Tone) {
        switch o {
        case .couldNotUpdate:
            return ("Non è stato possibile aggiornare l'elenco delle foto sull'SSD. "
                + "Le foto sono state copiate lo stesso: l'app riproverà al prossimo backup.", .warning)
        case .stoppedByYou:
            return ("Hai fermato l'aggiornamento dell'elenco delle foto sull'SSD. "
                + "Le foto sono state copiate lo stesso: l'elenco si rimetterà in pari al prossimo backup.", .info)
        case .ssdDisconnected:
            return ("L'SSD è stato scollegato prima che l'elenco delle foto fosse aggiornato. "
                + "Le foto erano già state copiate: l'elenco si rimetterà in pari al prossimo backup.", .warning)
        case .stoppedByAnotherDisk:
            return ("L'aggiornamento dell'elenco delle foto si è fermato perché è stato scollegato un disco. "
                + "Le foto erano già state copiate: l'elenco si rimetterà in pari al prossimo backup.", .warning)
        case .updatedWithRemarks:
            return ("Elenco delle foto sull'SSD aggiornato, ma qualcosa non torna: trovi i dettagli "
                + "in Diagnostica, alla voce «\(LibraryIndexCommands.cardTitle)».", .warning)
        case .updated:
            return ("Elenco delle foto sull'SSD aggiornato.", .ok)
        }
    }

    /// Corpo della notifica di sistema, inviata una sola volta alla fine del job (successo).
    /// `outcome == nil` = nessun passo 2: corpo identico a quello di sempre. Un esito diverso
    /// da "aggiornato" (con o senza avvisi) aggiunge una riga; `updatedWithRemarks` non
    /// aggiunge niente, perche' i dettagli stanno nella card, non nella notifica.
    static func notificationBody(stats: JobStats, outcome: Outcome?) -> String {
        var body = "Copiati \(stats.copied) · Skippati \(stats.skipped) · Errori \(stats.errors)"
        if let outcome, outcome != .updated, outcome != .updatedWithRemarks {
            body += " · Elenco delle foto non aggiornato"
        }
        return body
    }
}

/// Hash di un file **piu' la dimensione misurata sullo stesso descrittore**.
// `nonisolated`: value type senza stato, restituito da `sha256Measured`.
nonisolated struct MeasuredHash {
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
// `nonisolated`: I/O POSIX a basso livello su un descrittore locale, nessuno stato condiviso.
// Chiamata dalla verifica post-copia di `FileSyncer` (coda di lavoro) e da `LibraryIndexer.scan`.
nonisolated func sha256Measured(of url: URL) -> MeasuredHash? {
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
// `nonisolated`: delega a `sha256Measured`, stessa ragione.
nonisolated func sha256(of url: URL) -> String? {
    sha256Measured(of: url)?.hash
}

// MARK: - ContentHasher: una lettura, tre impronte (ROADMAP #44, ADR-0015)

/// Le tre impronte di un contenuto.
// `nonisolated`: value type senza stato, prodotto e letto fuori dal main.
nonisolated struct ContentDigest: Equatable, Sendable {
    let size: Int64
    /// Quella dell'elenco dei Doppioni (ADR-0001): e' l'identita' del contenuto.
    let sha256: String
    /// L'ETag che Cubbit da' a un file caricato in un colpo solo.
    let md5: String
    /// L'ETag che Cubbit da' a un file caricato a pezzi da 64 MiB:
    /// `md5(md5(parte1) ‖ … ‖ md5(parteN))-N`. `nil` per i file fino a 64 MiB COMPRESI, perche'
    /// `S3Syncer.upload` passa ai pezzi solo con `size > multipartChunkSize`: un file di
    /// esattamente 64 MiB va su con un caricamento unico, e il suo ETag e' l'MD5.
    let multipartETag: String?
    /// Le altre forme con cui Cubbit puo' aver scritto l'ETag di un file caricato a pezzi
    /// (misurato il 2026-09-30 sul bucket reale): parti da 64 MiB con la formula «in testo»
    /// (`md5` della concatenazione degli MD5 esadecimali delle parti), e parti da 128 MiB con
    /// entrambe le formule. Vuota per i file fino a 64 MiB compresi.
    var alternativeMultipartETags: [String] = []

    /// Vero per un'impronta salvata prima che le forme alternative esistessero: il file va
    /// riletto, altrimenti un oggetto caricato a pezzi da 128 MiB resterebbe non certificabile.
    var needsAlternativeETags: Bool {
        size > Int64(S3Syncer.multipartChunkSize) && alternativeMultipartETags.isEmpty
    }

    /// Come si salvano nella colonna `etag` di `inventory_local`: la prima e' `multipartETag`,
    /// le altre seguono separate da uno spazio. Nessuna nuova colonna, nessun cambio di schema.
    var storedETagColumn: String? {
        guard let multipartETag else { return nil }
        return ([multipartETag] + alternativeMultipartETags).joined(separator: " ")
    }

    static func splitStoredETagColumn(_ column: String?) -> (primary: String?, alternatives: [String]) {
        guard let parts = column?.split(separator: " ").map(String.init), let first = parts.first else {
            return (nil, [])
        }
        return (first, Array(parts.dropFirst()))
    }
}

/// Accumula SHA256, MD5 e l'MD5 di ogni parte da `partSize` byte mentre i byte arrivano, in
/// UNA passata. Puro: non sa da dove vengono i byte (un file, un `Data` in un test). Le parti
/// si contano sui byte, non sulle letture: un `read()` che restituisce meno byte di quanti
/// chiesti non sposta i confini.
// `nonisolated`: value type; ogni istanza vive sullo stack del thread che legge.
nonisolated struct ContentHasher {
    let partSize: Int
    private var sha = SHA256()
    private var whole = Insecure.MD5()
    private var part = Insecure.MD5()
    private var partFill = 0
    private var partDigests = Data()
    private var partCount = 0
    let legacyPartSize: Int
    private var legacyPart = Insecure.MD5()
    private var legacyFill = 0
    private var legacyDigests = Data()
    private var legacyCount = 0
    private(set) var byteCount: Int64 = 0

    /// `partSize` e `legacyPartSize` sono iniettabili solo per i test (confini visibili con
    /// pochi byte); in produzione sono le dimensioni delle parti viste su Cubbit.
    init(partSize: Int = S3Syncer.multipartChunkSize,
         legacyPartSize: Int = S3Syncer.legacyMultipartChunkSize) {
        precondition(partSize > 0 && legacyPartSize > 0, "le dimensioni delle parti devono essere positive")
        self.partSize = partSize
        self.legacyPartSize = legacyPartSize
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        sha.update(bufferPointer: bytes)
        whole.update(bufferPointer: bytes)
        byteCount += Int64(bytes.count)
        var offset = 0
        while offset < bytes.count {
            let n = min(bytes.count - offset, partSize - partFill)
            part.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + n)]))
            partFill += n
            offset += n
            if partFill == partSize { closePart() }
        }
        offset = 0
        while offset < bytes.count {
            let n = min(bytes.count - offset, legacyPartSize - legacyFill)
            legacyPart.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + n)]))
            legacyFill += n
            offset += n
            if legacyFill == legacyPartSize { closeLegacyPart() }
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    private mutating func closePart() {
        partDigests.append(contentsOf: part.finalize())
        partCount += 1
        part = Insecure.MD5()
        partFill = 0
    }

    private mutating func closeLegacyPart() {
        legacyDigests.append(contentsOf: legacyPart.finalize())
        legacyCount += 1
        legacyPart = Insecure.MD5()
        legacyFill = 0
    }

    /// Le due formule dell'ETag a pezzi: quella standard (MD5 dei 16 byte di ogni parte) e
    /// quella «in testo» (MD5 della concatenazione degli MD5 esadecimali), trovata sul bucket.
    private static func multipartETags(_ digests: Data, parts: Int) -> (binary: String, text: String) {
        let text = stride(from: 0, to: digests.count, by: 16)
            .map { hex(digests[digests.index(digests.startIndex, offsetBy: $0)..<digests.index(digests.startIndex, offsetBy: $0 + 16)]) }
            .joined()
        return (hex(Insecure.MD5.hash(data: digests)) + "-\(parts)",
                hex(Insecure.MD5.hash(data: Data(text.utf8))) + "-\(parts)")
    }

    func finalize() -> ContentDigest {
        var copy = self
        if copy.partFill > 0 { copy.closePart() }
        if copy.legacyFill > 0 { copy.closeLegacyPart() }
        var etag: String? = nil
        var alternatives: [String] = []
        if byteCount > Int64(partSize) {
            let standard = Self.multipartETags(copy.partDigests, parts: copy.partCount)
            etag = standard.binary
            alternatives.append(standard.text)
            if byteCount > Int64(legacyPartSize) {
                let legacy = Self.multipartETags(copy.legacyDigests, parts: copy.legacyCount)
                alternatives += [legacy.binary, legacy.text]
            }
        }
        return ContentDigest(size: byteCount, sha256: Self.hex(sha.finalize()),
                             md5: Self.hex(whole.finalize()), multipartETag: etag,
                             alternativeMultipartETags: alternatives)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Esito della lettura di un file per l'inventario.
nonisolated enum ContentReadOutcome: Equatable, Sendable {
    case digest(ContentDigest)
    /// Non si apre, o `read()` fallisce (permessi, EIO, disco scollegato a meta').
    case unreadable
    /// `fstat` prima e dopo, o i byte letti, non coincidono: il file si e' mosso sotto di noi.
    case changedWhileReading
    case cancelled
}

extension ContentHasher {
    /// 1 MiB, riusato per tutto il file: la memoria resta costante anche su un video da 40 GB.
    nonisolated static let readBufferSize = 1 << 20

    /// Legge `url` una volta sola e restituisce le tre impronte.
    ///
    /// Stesso schema di `sha256Measured`, e per le stesse ragioni: I/O POSIX a basso livello
    /// (`open`/`read`/`close`, buffer riusato), MAI `FileHandle.readData` — e' il bug di memoria
    /// da 41 GB (`.claude/rules/architecture.md`); dimensione misurata sullo stesso descrittore
    /// prima e dopo, perche' `URL.resourceValues` serve valori in cache. NON usa
    /// `S3Syncer.readFileInChunks`, che segue lo stesso principio ma e' un metodo `async` di un
    /// tipo `@MainActor` (girerebbe sul main, ADR-0006) e copia ogni parte da 64 MiB in un
    /// `Data` nuovo (vedi ADR-0015).
    ///
    /// `isCancelled` si chiede prima di ogni blocco da 1 MiB: «Interrompi» risponde anche a meta'
    /// di un file grande.
    nonisolated static func digestFile(at url: URL, partSize: Int = S3Syncer.multipartChunkSize,
                                       isCancelled: () -> Bool = { false }) -> ContentReadOutcome {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else { return .unreadable }

        var hasher = ContentHasher(partSize: partSize)
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while true {
            if isCancelled() { return .cancelled }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, readBufferSize) }
            if n < 0 { return .unreadable }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }

        var after = stat()
        guard fstat(fd, &after) == 0 else { return .unreadable }
        guard before.st_size == after.st_size, hasher.byteCount == Int64(after.st_size) else {
            return .changedWhileReading
        }
        return .digest(hasher.finalize())
    }
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
                // di `S3Syncer.readConfig()`. Mai sotto test (BUG-10): scriverebbe le
                // preferenze vere dell'utente.
                if appTouchesUserStateAtLaunch() { persistVolumeUUID(for: loc, url: url) }
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
// `nonisolated`: `bySize` si tocca solo sotto `lock`. Vedi ADR-0006.
nonisolated final class ImportSessionIndex: @unchecked Sendable {
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
// `nonisolated`: non segnalato da nessun warning (caso B della spec — girava gia' su
// `DispatchQueue.global` senza saltare sul main), ma era una data race vera: `cancelled` era
// un `private var` nudo, scritto dal main (`cancel()`) e letto dalla coda di lavoro senza
// nessuna protezione. Unico stato mutabile: `cancelFlag`, dietro lock (Task 5/6, `CancelFlag`
// condiviso). `fm` e `hashFunction` sono `let`. Vedi ADR-0006.
nonisolated final class FileSyncer: @unchecked Sendable {
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

    /// Flag di interruzione condiviso del progetto (Task 5/6, `CancelFlag`). Unico stato
    /// mutabile della classe: tutto dietro `NSLock`.
    private let cancelFlag = CancelFlag()
    private var cancelled: Bool { cancelFlag.isCancelled }
    private let fm = FileManager.default

    /// Funzione di hash usata dalla verifica post-copia. In produzione e' sempre la
    /// vera `sha256(of:)` (parametro con default): l'iniezione esiste perche' i tre
    /// esiti della verifica — verificato, mismatch, non verificabile — non sono
    /// altrimenti producibili da un test senza una corsa fra thread, e un test basato
    /// su una corsa e' verde col bug ogni volta che la corsa va nell'altro verso.
    /// Il ramo "non verificabile" era completamente scoperto fino al 2026-08-26.
    private let hashFunction: (URL) -> String?

    /// Intervallo minimo fra due `onProgress` pubblicati (ADR-0010, ROADMAP #37): in
    /// produzione e' sempre `ProgressThrottle.defaultMinimumIntervalNanos` (~10/s). Iniettato
    /// **solo dai test**, stesso schema di `hashFunction`: con un intervallo di un'ora un
    /// test sa esattamente quali aggiornamenti arrivano, senza cronometro. `internal`, non
    /// `private`, perche' `testDefaultInterval_isTheShared100ms` lo legge.
    let progressIntervalNanos: UInt64

    init(hashFunction: @escaping (URL) -> String? = { sha256(of: $0) },
         progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos) {
        self.hashFunction = hashFunction
        self.progressIntervalNanos = progressIntervalNanos
    }

    func cancel() { cancelFlag.cancel() }

    // MARK: - Dry-run preview (solo stat, nessuna copia)
    /// Un file che `previewSync` conterebbe fra i `toAdd`. Coppia neutra: nessun
    /// riferimento all'indice, a `IndexableKind` o allo store — `FileSyncer` resta
    /// ignaro di cos'è un doppione.
    ///
    /// `size` viene dalla stessa `resourceValues(forKeys: [.fileSizeKey])` già usata da
    /// `previewFile` per calcolare `toAddBytes` — nessuna lettura di dimensione nuova
    /// (fatto misurato n. 1: può essere servita dalla cache dell'istanza di URL). Ed è
    /// sicuro perché questo numero non decide mai niente: fa solo da chiave di bucket e
    /// da stima di byte per chi riceve i candidati. A decidere se un file è un doppione
    /// è sempre e solo `sha256`, a valle, su un descrittore riaperto — mai questo campo.
    struct PreviewCandidate {
        let url: URL
        let size: Int64
    }


    /// - Parameters:
    ///   - duplicateFilter: dedup per contenuto nell'anteprima (roadmap #27-A/#31, terza
    ///     parte). Riceve **tutti** i `PreviewCandidate` in un solo lotto — mai uno per
    ///     volta — e restituisce gli indici di quelli che sono doppioni. E' un lotto e
    ///     non un predicato `(PreviewCandidate) -> Bool` chiamato in streaming *per
    ///     costruzione*: per riconoscere due file byte-identici dentro la stessa sorgente
    ///     bisogna sapere, **prima** di hashare il primo dei due, che esiste un secondo
    ///     file di quella dimensione — un predicato in streaming non può saperlo, perché
    ///     il primo del paio non verrebbe mai hashato e quindi mai ricordato. Indici fuori
    ///     intervallo sono ignorati: la closure è codice esterno. Default `nil`: `FileSyncer`
    ///     non impara cos'è un doppione, non conosce l'indice né `IndexableKind` — la
    ///     decisione vive fuori, in `BackupRunner` (Task 2). `runMacToSSD`, `runSSDToHDD`,
    ///     `RestoreEngine` e il controllo spazio di `runImport` non lo passano: si
    ///     comportano identici a prima, perché quando è `nil` **non si alloca l'array dei
    ///     candidati e non si appende niente** — vedi `previewDir`/`previewFile`.
    func previewSync(from src: URL, to dst: URL, deep: Bool,
                      duplicateFilter: (([PreviewCandidate]) -> Set<Int>)? = nil) async
        -> (toAdd: Int, toSkip: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int,
            countComplete: Bool) {
        return await withCheckedContinuation { [self] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cancelFlag.reset()
                var toAdd = 0
                var toSkip = 0
                var toAddBytes: Int64 = 0
                // Alloca l'array SOLO se qualcuno ha chiesto un duplicateFilter: è questo,
                // non un `if` a valle, a rendere il default davvero a costo zero per i
                // chiamanti che non optano in.
                var candidates: [PreviewCandidate]? = duplicateFilter != nil ? [] : nil
                self.previewDir(src: src, dst: dst, deep: deep, toAdd: &toAdd, toSkip: &toSkip,
                                 toAddBytes: &toAddBytes, candidates: &candidates)
                // Se l'utente ha fermato tutto durante la camminata, i candidati raccolti
                // sono un frammento e non ha senso controllarli: si dichiara la camminata
                // incompleta e si lascia al chiamante il compito di dirlo (rilievo di review
                // del 2026-09-01 — prima si chiamava `duplicateFilter` comunque, e il numero
                // parziale arrivava a schermo con un avviso che ne sbagliava la direzione).
                let countComplete = !self.cancelled
                var toSkipDuplicates = 0
                if countComplete, let duplicateFilter, let candidates {
                    let duplicateIndices = duplicateFilter(candidates)
                    for i in duplicateIndices where candidates.indices.contains(i) {
                        toAdd -= 1
                        toSkipDuplicates += 1
                        toAddBytes -= candidates[i].size
                    }
                }
                // Un doppione costa al job una lettura completa del file sorgente,
                // esattamente come una copia (vedi doc-comment su duplicateFilter): la
                // stima del tempo conta anche i doppioni, non solo toAdd. Con la vecchia
                // formula (toAdd / 50) un reimport interamente duplicato mostrerebbe
                // "Tempo stimato: 00:00:00" per un job che in realtà dura minuti —
                // avremmo corretto il numero di file e lasciato sbagliato il tempo.
                // toSkipDuplicates è 0 per chi non passa duplicateFilter, quindi la
                // formula non cambia per loro.
                let workUnits = toAdd + toSkipDuplicates
                let estimatedSec = workUnits > 0 ? max(1, workUnits / 50) : 0
                // L'ordine segue quello dichiarato nel tipo di ritorno: Swift accetta ancora
                // un riordino implicito ma lo deprecato, e in una versione futura del
                // linguaggio sara' un errore.
                cont.resume(returning: (toAdd: toAdd, toSkip: toSkip, toSkipDuplicates: toSkipDuplicates,
                                        toAddBytes: toAddBytes, estimatedSec: estimatedSec,
                                        countComplete: countComplete))
            }
        }
    }

    // Niente valori di default su `previewDir`/`previewFile`, che sono privati: un
    // default trasformerebbe una propagazione dimenticata in un cambio di comportamento
    // silenzioso invece che in un errore di compilazione (stessa regola già scritta
    // accanto a `syncDir`/`syncFile`).
    private func previewDir(src: URL, dst: URL, deep: Bool, toAdd: inout Int, toSkip: inout Int,
                             toAddBytes: inout Int64, candidates: inout [PreviewCandidate]?) {
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
                previewDir(src: item, dst: destItem, deep: deep, toAdd: &toAdd, toSkip: &toSkip,
                           toAddBytes: &toAddBytes, candidates: &candidates)
            } else if vals?.isRegularFile == true {
                previewFile(src: item, dst: destItem, toAdd: &toAdd, toSkip: &toSkip,
                            toAddBytes: &toAddBytes, candidates: &candidates)
            }
        }
    }

    private func previewFile(src: URL, dst: URL, toAdd: inout Int, toSkip: inout Int,
                              toAddBytes: inout Int64, candidates: inout [PreviewCandidate]?) {
        // Zero-overwrite rule: se il file esiste gia a destinazione sara sempre skippato
        if fm.fileExists(atPath: dst.path) {
            toSkip += 1
        } else {
            toAdd += 1
            // Stessa lettura già presente prima di questa modifica — nessuna lettura di
            // dimensione nuova (fatto misurato n. 1: `resourceValues` può essere servita
            // dalla cache dell'istanza di URL, ed è sicuro perché qui la dimensione non
            // decide mai niente, vedi doc-comment su `PreviewCandidate`).
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            toAddBytes += Int64(size)
            // Candidato raccolto SOLO se `candidates` non è nil (qualcuno ha chiesto un
            // duplicateFilter) — e SOLO qui, dopo la guardia zero-overwrite: un file già
            // a destinazione non deve mai comparire fra i candidati, stesso ordine dei
            // rami già rispettato da `syncFile`.
            if candidates != nil {
                candidates!.append(PreviewCandidate(url: src, size: Int64(size)))
            }
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
                self.cancelFlag.reset()
                var result = SyncResult()
                var throttle = ProgressThrottle(minimumIntervalNanos: self.progressIntervalNanos)

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
                                     result: &result, progress: &throttle,
                                     onStatus: onStatus, onProgress: onProgress,
                                     onCurrentFile: onCurrentFile,
                                     isDuplicate: isDuplicate, onCopied: onCopied,
                                     onUnverified: onUnverified)
                    // Sempre l'ultimo valore, qualunque sia stato l'ultimo aggiornamento
                    // diradato (ADR-0010): coincide con `result`, quindi arrivare dopo
                    // `finishCopyStep` non cambia i numeri finali — non dipende da
                    // `done == total`, che puo' non verificarsi mai su un'interruzione.
                    let snap = result
                    DispatchQueue.main.async { onProgress(snap) }
                    cont.resume(returning: result)
                } catch {
                    let snap = result
                    DispatchQueue.main.async { onProgress(snap) }
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
                         progress: inout ProgressThrottle,
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
                            result: &result, progress: &progress, onStatus: onStatus, onProgress: onProgress,
                            onCurrentFile: onCurrentFile,
                            isDuplicate: isDuplicate, onCopied: onCopied,
                            onUnverified: onUnverified)
            } else if vals?.isRegularFile == true {
                syncFile(src: item, dst: destItem, deep: deep,
                         result: &result, progress: &progress, onStatus: onStatus, onProgress: onProgress,
                         onCurrentFile: onCurrentFile,
                         isDuplicate: isDuplicate, onCopied: onCopied,
                         onUnverified: onUnverified)
            }
        }
    }

    private func syncFile(src: URL, dst: URL, deep: Bool,
                          result: inout SyncResult,
                          progress: inout ProgressThrottle,
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
        // Diradato alla fonte (ADR-0010, ROADMAP #37): al massimo ~10 aggiornamenti al
        // secondo, sempre quello finale (`isFinal` quando il conteggio combacia — non e' la
        // sola garanzia: `sync` pubblica comunque un ultimo valore su ogni uscita).
        if progress.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds,
                               isFinal: snap.done == snap.total) {
            DispatchQueue.main.async { onProgress(snap) }
        }
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
    nonisolated static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
        !existingKeys.contains(key)
    }

    /// Conteggio dell'anteprima SSD → Cubbit, con la STESSA regola di `sync()`: una key gia'
    /// presente sul bucket non viene mai ricaricata, qualunque sia la dimensione locale
    /// (zero-overwrite, BUG-3). Fino al 2026-09-19 l'anteprima confrontava anche la
    /// dimensione e contava "da caricare" file che il backup vero avrebbe saltato.
    nonisolated static func previewCount(files: [(key: String, size: Int64)], existingKeys: Set<String>)
        -> (toUpload: Int, toSkip: Int, bytes: Int64) {
        var toUpload = 0, toSkip = 0
        var bytes: Int64 = 0
        for f in files {
            if shouldUpload(key: f.key, existingKeys: existingKeys) { toUpload += 1; bytes += f.size }
            else { toSkip += 1 }
        }
        return (toUpload, toSkip, bytes)
    }

    // Conteggio informativo per roadmap #13 (segnalazione, non azione): una key già
    // presente su S3 con dimensione diversa da quella locale. Non influenza in alcun
    // modo shouldUpload/la decisione di caricare.
    static func isChangedExistingKey(key: String, size: Int64, existing: [String: Int64]) -> Bool {
        guard let existingSize = existing[key] else { return false }
        return existingSize != size
    }

    // `nonisolated`: la lettura delle credenziali gira fuori dal main dal 2026-09-03
    // (`loadS3ConfigIfNeeded`, caso F della spec: una closure sincrona dentro `Result { }`).
    // L'annotazione lo dichiara al compilatore, non cambia il comportamento.
    nonisolated struct S3Config {
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

    private nonisolated struct KeychainCredentials: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let endpoint: String
        let region: String
    }

    private nonisolated static func keychainQuery(remoteName: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AppBackupFoto",
         kSecAttrAccount as String: remoteName]
    }

    private nonisolated static func readFromKeychain(remoteName: String) -> KeychainCredentials? {
        var query = keychainQuery(remoteName: remoteName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeychainCredentials.self, from: data)
    }

    // internal (non private): richiamata anche dal bottone "Aggiorna da rclone.conf" in ToolsSheet.
    nonisolated static func writeToKeychain(config: S3Config, remoteName: String) throws {
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
        /// Spazio usato su Cubbit corretto a fine `sync()` (indicatore di spazio, ADR-0008):
        /// `nil` se non si può correggere (elenco iniziale incompleto, o job interrotto — vedi
        /// `CloudUsageTotals.afterSync`). Non persistito: `JobStats` non è `Codable` e nessun
        /// conteggio del riepilogo lo legge, lo consuma solo `sync()` per notificare il sink.
        var cloudUsageAfter: CloudUsageTotals? = nil
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
    // `nonisolated`: value type senza stato, chiamato dall'actor AdaptiveUploadGate.
    nonisolated struct AdaptiveLimiterState: Equatable {
        var limit: Int
        var consecutiveSuccesses: Int
    }

    nonisolated enum AdaptiveLimiterOutcome {
        case success
        case retryableFailure
        case permanentFailure
    }

    // Logica pura AIMD (Additive Increase / Multiplicative Decrease), separata
    // dall'actor sottostante per essere testabile senza rete/timer. Vedi
    // Docs/superpowers/specs/2026-08-18-adaptive-s3-concurrency-design.md.
    // `nonisolated`: pura, chiamata dall'actor AdaptiveUploadGate.
    nonisolated enum AdaptiveLimiter {
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
    // `nonisolated`: una costante; la legge anche `ContentHasher`, fuori dal main (ROADMAP #44).
    nonisolated static let multipartChunkSize = 64 * 1024 * 1024
    /// Dimensione delle parti usata da un vecchio programma di caricamento: il 2026-09-30 81
    /// oggetti del bucket risultavano caricati a pezzi da 128 MiB (verificato ricalcolandoli
    /// dai file sull'SSD). Serve solo all'inventario per certificarli (ADR-0015).
    nonisolated static let legacyMultipartChunkSize = 128 * 1024 * 1024
    private static let adaptiveMemoryCeilingBytes = 2 * 1024 * 1024 * 1024
    static let adaptiveConcurrencyCeiling = adaptiveMemoryCeilingBytes / multipartChunkSize

    /// Flag di interruzione condiviso del progetto (Task 5/6, `CancelFlag`), invece del
    /// `private var cancelled = false` nudo di prima (produceva due dei 29 warning di
    /// isolamento, perche' l'accesso da un `Task.detached`/gruppo di task era una lettura
    /// da un contesto non isolato su una proprieta' `@MainActor`).
    private let cancelFlag = CancelFlag()
    // `nonisolated`: solo la lettura del flag, dietro lock in `CancelFlag`. S3Syncer resta
    // `@MainActor` per il resto (default del target).
    nonisolated private var cancelled: Bool { cancelFlag.isCancelled }
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    // MARK: Spazio usato su Cubbit (indicatore di spazio, Task 5, ADR-0008)

    /// Elenco di uno o più pagine di `ListObjectsV2`. `isComplete` vale `true` SOLO se il
    /// ciclo è uscito perché il token di continuazione è `nil` — mai perché `shouldStop()` ha
    /// interrotto il giro, nemmeno con zero pagine lette. La distinzione esiste perché
    /// `listAll` oggi esce in silenzio su stop e restituisce un dizionario troncato senza
    /// errore: un gancio ingenuo sommerebbe quel dizionario troncato e mostrerebbe, per
    /// esempio, «0 byte usati» dopo un'anteprima lanciata subito dopo uno stop (vedi
    /// «Scoperte collaterali» della spec — non corretto qui, side-finding pre-esistente).
    struct S3Listing: Equatable {
        let objects: [String: Int64]
        let isComplete: Bool
    }

    /// Somma di byte/oggetti di un elenco — quello che si mostra come «spazio usato su
    /// Cubbit». Logica pura, nessuna rete.
    struct CloudUsageTotals: Equatable, Codable {
        let bytes: Int64
        let count: Int

        static func of(_ objects: [String: Int64]) -> CloudUsageTotals {
            CloudUsageTotals(bytes: objects.values.reduce(0, +), count: objects.count)
        }

        /// Corregge il numero registrato **all'inizio** di `sync()` con gli upload riusciti
        /// **alla fine**, invece di rifare un secondo elenco completo: per la regola
        /// zero-overwrite `sync` carica solo chiavi assenti (`shouldUpload`), quindi lo
        /// spazio usato dopo il job è esattamente `listed + uploadedBytes` — MA solo se
        /// l'elenco iniziale era completo (altrimenti non si sa da cosa si parte) e il job
        /// non è stato interrotto (dopo uno stop il ciclo degli esiti scarta con `continue`
        /// anche i caricamenti finiti, quindi `uploadedBytes` sarebbe per difetto). In tutti
        /// gli altri casi si restituisce `nil`: il valore registrato in precedenza resta
        /// quello, con la sua data — più vecchio, mai sbagliato.
        static func afterSync(listed: CloudUsageTotals?, uploadedBytes: Int64,
                               uploadedCount: Int, wasCancelled: Bool) -> CloudUsageTotals? {
            guard !wasCancelled, let listed else { return nil }
            return CloudUsageTotals(bytes: listed.bytes + uploadedBytes, count: listed.count + uploadedCount)
        }
    }

    /// Dove va a finire il numero calcolato da un elenco completo. Tipo di chiusura SENZA
    /// `@MainActor`: come default argument di un `init` la sua conversione perderebbe
    /// l'isolamento (errore in Swift 6 mode), quindi il salto sul main è esplicito nel corpo
    /// del default, non nella firma — stesso pattern già in produzione altrove nel progetto
    /// (`Task { @MainActor in ... }`). I test passano un sink sincrono che registra le
    /// chiamate, senza bisogno del main.
    typealias CloudUsageSink = (CloudUsageTotals, _ bucket: String) -> Void

    static let defaultUsageSink: CloudUsageSink = { totals, bucket in
        Task { @MainActor in CloudUsageStore.shared.record(totals, bucket: bucket) }
    }

    private let usageSink: CloudUsageSink

    /// `usageSink` è iniettabile SOLO per i test: nessun chiamante di produzione ne passa uno
    /// diverso dal default (verificato: `grep -n "S3Syncer()"` mostra solo istanze col default,
    /// vedi Task 7). La firma resta compatibile con `S3Syncer()` esistente in tutti i call site.
    init(usageSink: @escaping CloudUsageSink = S3Syncer.defaultUsageSink) {
        self.usageSink = usageSink
    }

    /// Ciclo di paginazione, estratto per essere testabile senza rete (Task 5). `listAll` e
    /// `sync` lo usano entrambi: `listAll` tramite `listAllDetailed`, `sync` direttamente,
    /// così la rete non viene interrogata due volte per lo stesso job.
    nonisolated static func collectPages(fetch: (String?) async throws -> ([String: Int64], String?),
                                          shouldStop: () -> Bool) async throws -> S3Listing {
        var objects: [String: Int64] = [:]
        var token: String? = nil
        repeat {
            if shouldStop() { return S3Listing(objects: objects, isComplete: false) }
            let (objs, next) = try await fetch(token)
            objects.merge(objs) { _, new in new }
            token = next
        } while token != nil
        return S3Listing(objects: objects, isComplete: true)
    }

    func cancel() { cancelFlag.cancel() }

    /// Azzera l'interruzione lasciata da un'operazione precedente. Va chiamata in testa a
    /// ogni operazione nuova su un'istanza riusata (ROADMAP #38, 2026-09-19): `sync` e
    /// `downloadMany` lo facevano gia', l'anteprima e le letture del Ripristina no — dopo
    /// uno stop leggevano un elenco del bucket VUOTO senza errore (`collectPages` esce
    /// subito se il flag e' alzato), e l'anteprima dichiarava tutto "da caricare".
    func beginNewOperation() { cancelFlag.reset() }

    nonisolated static func readConfig(remoteName: String = "Cubbit", bucket: String = "backupfoto") throws -> S3Config {
        try readConfigWithSource(remoteName: remoteName, bucket: bucket).config
    }

    // Come readConfig, ma segnala anche se il risultato viene dal Keychain o da rclone.conf,
    // in un'unica lettura Keychain: usata dove serve entrambe le informazioni (findings di
    // Revisione + card credenziali in ToolsSheet) per evitare letture Keychain ridondanti —
    // ognuna può richiedere una propria autorizzazione interattiva dell'utente.
    // `nonisolated`: gira fuori dal main dal 2026-09-03 (`loadS3ConfigIfNeeded`, caso F).
    nonisolated static func readConfigWithSource(remoteName: String = "Cubbit",
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
    nonisolated static func readConfigFromFile(remoteName: String, bucket: String) throws -> S3Config {
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
    nonisolated static func validateEndpoint(_ raw: String) throws -> String {
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
        beginNewOperation()
        let existingKeys = Set(try await listAll(config: config).keys)
        guard let files = Self.localUploadFiles(root: localURL) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
        }
        return Self.previewCount(files: files.map { (key: $0.key, size: $0.size) }, existingKeys: existingKeys)
    }

    /// I file dell'SSD che il backup SSD → Cubbit considera, con la chiave che avrebbero su
    /// Cubbit. UNA sola traversata per `sync` e `previewUpload` (prima erano due copie dello
    /// stesso ciclo). Stesse regole di prima — `.skipsHiddenFiles`, niente `._*` e
    /// `.DS_Store` — piu' la cartella di quarantena della riparazione (ADR-0016), saltata con
    /// tutto il suo contenuto: senza, il backup ricaricherebbe su Cubbit la copia rovinata messa
    /// da parte sull'SSD. NON usa `LibraryExclusions.shouldExclude` per intero: allineare anche
    /// `lost+found`/`Backups.backupdb` e' un cambio di comportamento ancora da decidere (vedi il
    /// commento di `LibraryExclusions`). `nil` se la radice non si lascia scorrere.
    // `nonisolated`: nessuno stato dell'istanza; il flag di interruzione arriva come closure.
    nonisolated static func localUploadFiles(root localURL: URL, isCancelled: () -> Bool = { false })
        -> [(url: URL, key: String, size: Int64)]? {
        let fm = FileManager.default
        var files: [(url: URL, key: String, size: Int64)] = []
        let base = localURL.path
        guard let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        while let f = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            let name = f.lastPathComponent
            if LibraryExclusions.isQuarantineName(name) { enumerator.skipDescendants(); continue }
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let rel = String(f.path.dropFirst(base.count).drop(while: { $0 == "/" }))
            files.append((url: f, key: rel, size: Int64(v?.fileSize ?? 0)))
        }
        return files
    }

    func sync(from localURL: URL, config: S3Config,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in }) async throws -> SyncResult {
        cancelFlag.reset()
        var result = SyncResult()

        DispatchQueue.main.async { onStatus("Connessione a Cubbit S3 — recupero lista file remoti...") }
        // `listAllDetailed`, non `listAll`: questa funzione deve sapere se l'elenco che ha
        // appena letto era COMPLETO, per poter correggere lo spazio usato su Cubbit a fine job
        // (vedi CloudUsageTotals.afterSync, più sotto) senza rifare un secondo elenco.
        let listing = try await listAllDetailed(config: config)
        let existing = listing.objects
        let existingCount = existing.count
        DispatchQueue.main.async { onStatus("Trovati \(existingCount) oggetti su S3 — scansione file locali...") }

        guard let files = Self.localUploadFiles(root: localURL, isCancelled: { self.cancelled }) else {
            throw NSError(domain: "S3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile enumerare i file locali"])
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

        // Correzione esatta dello spazio usato su Cubbit (indicatore di spazio, ADR-0008):
        // solo se l'elenco iniziale era completo E il job non è stato interrotto (dopo uno
        // stop il ciclo degli esiti sopra scarta con `continue` anche i caricamenti finiti,
        // quindi `result.uploadedBytes` sarebbe per difetto — vedi CloudUsageTotals.afterSync).
        let listedTotals: CloudUsageTotals? = listing.isComplete ? .of(listing.objects) : nil
        result.cloudUsageAfter = CloudUsageTotals.afterSync(listed: listedTotals, uploadedBytes: result.uploadedBytes,
                                                              uploadedCount: result.uploaded,
                                                              wasCancelled: cancelled || Task.isCancelled)
        if let totals = result.cloudUsageAfter { usageSink(totals, config.bucket) }
        return result
    }

    /// Come `listAll`, ma restituisce anche se l'elenco era COMPLETO, e non chiama il sink —
    /// lo notifica il solo chiamante che ha davvero bisogno di sapere quando registrare
    /// (`listAll` stessa, se completo; `sync`, con la correzione di fine job). Senza questa
    /// separazione i due dovrebbero interrogare la rete due volte per lo stesso elenco.
    func listAllDetailed(config: S3Config) async throws -> S3Listing {
        try await Self.collectPages(
            fetch: { token in try await self.listPage(config: config, token: token) },
            shouldStop: { self.cancelled || Task.isCancelled })
    }

    func listAll(config: S3Config) async throws -> [String: Int64] {
        let listing = try await listAllDetailed(config: config)
        // Si notifica il sink SOLO se l'elenco è completo: un'uscita anticipata per stop
        // (isComplete == false) non deve mai far credere che lo spazio usato sia 0 o
        // parziale — vedi il doc-comment di `S3Listing.isComplete`.
        if listing.isComplete { usageSink(.of(listing.objects), config.bucket) }
        return listing.objects
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

    /// Una pagina di `ListObjectsV2` cosi' com'e' arrivata, senza interpretarla. Estratta da
    /// `listPage` il 2026-09-26 (ROADMAP #44): l'inventario ha bisogno anche dell'ETag, che
    /// `listPage` non legge. La richiesta resta UNA — stessa URL, stessa firma, stesse
    /// correzioni di BUG-8 (`encodePlusInQuery`, `xmlDecode`) — e i chiamanti di `listPage`
    /// ricevono esattamente quello che ricevevano prima.
    /// `prefix` (ROADMAP #45, default `nil` = la richiesta di sempre): la riparazione elenca
    /// solo `_quarantena/` per sapere se una copia rovinata e' gia' stata messa da parte.
    func fetchListPageXML(config: S3Config, token: String?, prefix: String? = nil) async throws -> String {
        guard var comps = URLComponents(string: "\(config.endpoint)/\(config.bucket)") else {
            throw NSError(domain: "S3", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il bucket: \(config.bucket)"])
        }
        var qi = [URLQueryItem(name: "list-type", value: "2"),
                  URLQueryItem(name: "max-keys", value: "1000")]
        if let t = token { qi.append(URLQueryItem(name: "continuation-token", value: t)) }
        if let prefix { qi.append(URLQueryItem(name: "prefix", value: prefix)) }
        comps.queryItems = qi
        comps.percentEncodedQuery = Self.encodePlusInQuery(comps.percentEncodedQuery)
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
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func listPage(config: S3Config, token: String?) async throws -> ([String: Int64], String?) {
        let xml = try await fetchListPageXML(config: config, token: token)
        let keys = xmlAll(xml, tag: "Key")
        let sizes = xmlAll(xml, tag: "Size").compactMap { Int64($0) }
        var objs: [String: Int64] = [:]
        for (k, s) in zip(keys, sizes) { objs[k] = s }
        let isTruncated = xmlFirst(xml, tag: "IsTruncated") == "true"
        let nextToken = isTruncated ? xmlFirst(xml, tag: "NextContinuationToken") : nil
        return (objs, nextToken)
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
            // La quarantena della riparazione (ADR-0016) non e' una cartella da ripristinare.
            if LibraryExclusions.isQuarantineName(name) { continue }
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
        cancelFlag.reset()
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

    // MARK: - Richieste della riparazione (ROADMAP #45, ADR-0016)
    //
    // HEAD (sola lettura), copia lato server (in quarantena) e la sola sovrascrittura del
    // progetto. Le chiavi viaggiano codificate con `encodeKeyStrict` e la firma riceve lo
    // stesso identico percorso (`canonicalURI`): niente doppie codifiche diverse fra cio' che
    // si manda e cio' che si firma, la classe di errore di BUG-8.

    /// Codifica di una chiave (o del nome del bucket) per il percorso di una richiesta e per
    /// `x-amz-copy-source`: tutto tranne `A-Z a-z 0-9 - _ . ~` e `/`, byte per byte in UTF-8.
    /// `+` diventa `%2B` (in un percorso Cubbit potrebbe leggerlo come spazio), l'apostrofo
    /// `%27`, `è` `%C3%A8`. E' la codifica che SigV4 si aspetta per il percorso canonico.
    // `nonisolated`: pura.
    nonisolated static func encodeKeyStrict(_ key: String) -> String {
        var out = ""
        for byte in key.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E, 0x2F:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Il percorso di un oggetto, `/<bucket>/<chiave>`, codificato con `encodeKeyStrict`: lo
    /// stesso testo va nella richiesta e nella firma.
    nonisolated static func objectRequestPath(bucket: String, key: String) -> String {
        "/" + encodeKeyStrict(bucket) + "/" + encodeKeyStrict(key)
    }

    /// Il valore di `x-amz-copy-source`: `<bucket>/<chiave>` codificati, senza la barra
    /// iniziale — la forma che `rclone copyto` ha usato nella prova su Cubbit del 2026-10-04.
    nonisolated static func copySourceHeader(bucket: String, key: String) -> String {
        encodeKeyStrict(bucket) + "/" + encodeKeyStrict(key)
    }

    /// Come leggere la risposta a una HEAD: 404 = l'oggetto non c'e' (`nil`), 200 con una
    /// dimensione leggibile = l'oggetto, ogni altra cosa = errore (mai «non c'e'» per
    /// sbaglio: un 403 o un 500 non dicono niente sull'oggetto).
    nonisolated static func parseHead(statusCode: Int, contentLength: String?, etag: String?,
                                      key: String) throws -> S3ObjectHead? {
        if statusCode == 404 { return nil }
        guard statusCode == 200 else {
            throw S3HTTPError(statusCode: statusCode, message: "Errore HEAD \(key)")
        }
        guard let text = contentLength?.trimmingCharacters(in: .whitespaces),
              let size = Int64(text), size >= 0 else {
            throw S3HTTPError(statusCode: statusCode, message: "HEAD \(key) senza una dimensione leggibile")
        }
        return S3ObjectHead(size: size, etag: etag)
    }

    /// Una copia lato server e' riuscita solo se la risposta e' 2xx E il corpo e' un
    /// `<CopyObjectResult>`: S3 puo' rispondere 200 e mettere l'errore nel corpo.
    nonisolated static func copyObjectSucceeded(statusCode: Int, body: String) -> Bool {
        (200...299).contains(statusCode) && body.contains("<CopyObjectResult") && !body.contains("<Error>")
    }

    /// HEAD di un oggetto: dimensione ed ETag letti ADESSO da Cubbit (l'inventario e' una
    /// cache, ADR-0002). `nil` se l'oggetto non c'e'. Sola lettura.
    func headObject(config: S3Config, key: String) async throws -> S3ObjectHead? {
        let path = Self.objectRequestPath(bucket: config.bucket, key: key)
        guard let url = URL(string: config.endpoint + path) else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(key)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw S3HTTPError(statusCode: -1, message: "HEAD \(key): risposta non HTTP")
        }
        return try Self.parseHead(statusCode: http.statusCode,
                                  contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                                  etag: http.value(forHTTPHeaderField: "ETag"), key: key)
    }

    /// Copia lato server (`CopyObject`) di `sourceKey` in `destinationKey`, nello stesso
    /// bucket: la sorgente non viene toccata. La usa SOLO la riparazione, per mettere in
    /// quarantena la copia rovinata (ADR-0016); chi chiama ha gia' controllato con
    /// `headObject` che `destinationKey` non esista (zero-overwrite anche in quarantena).
    /// Provata su Cubbit il 2026-10-04 con `rclone copyto`: copia lato server, ETag identico.
    func copyObject(config: S3Config, from sourceKey: String, to destinationKey: String) async throws {
        let path = Self.objectRequestPath(bucket: config.bucket, key: destinationKey)
        guard let url = URL(string: config.endpoint + path) else {
            throw NSError(domain: "S3", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "URL non valido per il file: \(destinationKey)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        sign(&req, config: config, body: Data(), date: Date(), canonicalURI: path,
             extraSignedHeaders: ["x-amz-copy-source": Self.copySourceHeader(bucket: config.bucket, key: sourceKey)])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        guard Self.copyObjectSucceeded(statusCode: code, body: body) else {
            throw S3HTTPError(statusCode: code, message: "Errore copia \(sourceKey): \(body.prefix(200))")
        }
    }

    /// Tutti gli oggetti sotto `prefix`, pagina dopo pagina. Lancia se la lista non arriva in
    /// fondo pulita: chi decide in base a cosa c'e' gia' in quarantena non deve leggere una
    /// lista a meta'.
    func listObjects(config: S3Config, prefix: String) async throws -> [S3ObjectInfo] {
        var out: [S3ObjectInfo] = []
        var token: String? = nil
        repeat {
            let page = Self.parseListPage(try await fetchListPageXML(config: config, token: token, prefix: prefix))
            guard page.malformedEntries == 0 else {
                throw S3HTTPError(statusCode: 200, message: "Lista di \(prefix) illeggibile")
            }
            out += page.objects
            if page.isTruncated {
                guard let next = page.nextToken else {
                    throw S3HTTPError(statusCode: 200, message: "Lista di \(prefix) troncata senza seguito")
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil
        return out
    }

    /// LA SOLA SOVRASCRITTURA SU CUBBIT DEL PROGETTO (ADR-0016): rimette al suo posto la copia
    /// buona di una foto la cui copia rovinata e' gia' in quarantena, verificata. Usa la stessa
    /// `upload` del backup (PUT unico fino a 64 MiB compresi, a pezzi sopra) con un gate tutto
    /// suo da uno slot. NON va chiamata da nessun'altra parte: il backup resta zero-overwrite
    /// (`shouldUpload`, BUG-3). Un'istanza dedicata di `S3Syncer`, mai quella dei job.
    func replaceObjectForRepair(config: S3Config, key: String, withFileAt url: URL) async throws {
        beginNewOperation()
        let gate = AdaptiveUploadGate(startingLimit: 1, ceiling: 1)
        try await upload(url: url, key: key, config: config, gate: gate, onStart: {}, onStatus: { _ in })
    }

    // MARK: - AWS Signature V4

    /// Firma una richiesta. `internal` e non piu' `private` (ROADMAP #45) solo perche'
    /// `S3SignatureTests` possa bloccare la firma di una richiesta di lista con un valore
    /// calcolato a parte; nessun chiamante nuovo fuori da questa classe.
    ///
    /// Due parametri nuovi, entrambi con un default che lascia la firma di oggi IDENTICA per
    /// tutte le richieste esistenti:
    /// - `canonicalURI`: il percorso esattamente come viaggia nella richiesta. Le richieste
    ///   della riparazione (HEAD, copia) costruiscono il percorso con `encodeKeyStrict`; senza
    ///   questo parametro la firma ricalcolerebbe il percorso da `url.path` con una codifica
    ///   diversa per `+`, apostrofo e lettere accentate (la stessa famiglia di BUG-8).
    /// - `extraSignedHeaders`: intestazioni `x-amz-*` in piu', impostate sulla richiesta E
    ///   firmate. `x-amz-copy-source` della copia lato server va firmata: S3 rifiuta le
    ///   intestazioni `x-amz-*` presenti ma non firmate.
    func sign(_ request: inout URLRequest, config: S3Config, body: Data, date: Date,
              canonicalURI: String? = nil, extraSignedHeaders: [String: String] = [:]) {
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

        var headerVals: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payHash,
            "x-amz-date": datetime
        ]
        for (name, value) in extraSignedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
            headerVals[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }

        let uri: String
        if let canonicalURI {
            uri = canonicalURI
        } else {
            let rawPath = request.url?.path ?? "/"
            let s3PathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~/"))
            uri = rawPath.addingPercentEncoding(withAllowedCharacters: s3PathAllowed) ?? rawPath
        }

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

        let signed = Self.sigV4Signature(method: request.httpMethod ?? "GET", canonicalURI: uri,
                                         canonicalQuery: sortedQuery, headers: headerVals,
                                         payloadHash: payHash, amzDate: datetime,
                                         secretAccessKey: config.secretAccessKey, region: region)
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(dateOnly)/\(region)/s3/aws4_request, " +
            "SignedHeaders=\(signed.signedHeaders), Signature=\(signed.signature)",
            forHTTPHeaderField: "Authorization")
    }

    /// Il cuore di SigV4, PURO: dalla richiesta canonica alla firma. Estratto da `sign` il
    /// 2026-10 (ROADMAP #45) con le stesse identiche operazioni, per poterlo provare con i
    /// valori pubblicati da AWS (`S3SignatureTests`) prima di mandare a Cubbit la prima copia
    /// lato server. `headers`: nomi gia' in minuscolo, valori gia' ripuliti.
    // `nonisolated`: pura.
    nonisolated static func sigV4Signature(method: String, canonicalURI: String, canonicalQuery: String,
                                           headers: [String: String], payloadHash: String, amzDate: String,
                                           secretAccessKey: String, region: String)
        -> (signedHeaders: String, signature: String) {
        let signedNames = headers.keys.sorted()
        let canonH = signedNames.map { "\($0):\(headers[$0]!)" }.joined(separator: "\n") + "\n"
        let signedH = signedNames.joined(separator: ";")
        let canonReq = [method, canonicalURI, canonicalQuery, canonH, signedH, payloadHash]
            .joined(separator: "\n")
        let dateOnly = String(amzDate.prefix(8))
        let credScope = "\(dateOnly)/\(region)/s3/aws4_request"
        let reqHash = SHA256.hash(data: Data(canonReq.utf8)).map { String(format: "%02x", $0) }.joined()
        let s2s = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credScope)\n\(reqHash)"

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let sigKey = hmac(hmac(hmac(hmac(Data(("AWS4" + secretAccessKey).utf8),
            dateOnly), region), "s3"), "aws4_request")
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(s2s.utf8),
            using: SymmetricKey(data: sigKey))).map { String(format: "%02x", $0) }.joined()
        return (signedH, sig)
    }

    // Cubbit usa come continuation-token la chiave stessa. URLComponents lascia il `+` nella
    // query e il server lo legge come spazio: la pagina dopo una chiave con `+` fallisce con
    // SignatureDoesNotMatch. `sign()` decodifica e ricodifica, quindi `%2B` resta coerente.
    static func encodePlusInQuery(_ query: String?) -> String? {
        query?.replacingOccurrences(of: "+", with: "%2B")
    }

    // Una sola passata, così `&amp;#39;` resta il testo `&#39;` e non diventa un apostrofo.
    // Cubbit scrive l'apostrofo come `&#39;`: senza i riferimenti numerici la chiave letta
    // era sbagliata, e il token ricavato da lei faceva fallire la lista con InvalidRequest.
    // `nonisolated`: pura; la usa anche `parseListPage`, chiamata dall'inventario fuori dal main.
    nonisolated static func xmlDecode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [Substring: String] = ["amp": "&", "lt": "<", "gt": ">", "apos": "'", "quot": "\""]
        var out = ""
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            let afterAmp = rest.index(after: amp)
            guard let semi = rest[afterAmp...].firstIndex(of: ";") else { break }
            let entity = rest[afterAmp..<semi]
            var decoded: String? = named[entity]
            if decoded == nil, entity.hasPrefix("#") {
                let num = entity.dropFirst()
                let code = num.hasPrefix("x") || num.hasPrefix("X")
                    ? UInt32(num.dropFirst(), radix: 16) : UInt32(num, radix: 10)
                decoded = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if let decoded {
                out += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[afterAmp...]
            }
        }
        return out + rest
    }
    private func xmlFirst(_ xml: String, tag: String) -> String? {
        guard let s = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>") else { return nil }
        return Self.xmlDecode(String(xml[s.upperBound..<e.lowerBound]))
    }
    private func xmlAll(_ xml: String, tag: String) -> [String] {
        var results: [String] = []; var search = xml
        while let s = search.range(of: "<\(tag)>"), let e = search.range(of: "</\(tag)>") {
            results.append(Self.xmlDecode(String(search[s.upperBound..<e.lowerBound])))
            search = String(search[e.upperBound...])
        }
        return results
    }

    // MARK: Lista con ETag, per l'inventario (ROADMAP #44, ADR-0015)

    /// Un oggetto della lista, con l'ETag (`nil` se la voce non lo porta).
    nonisolated struct S3ObjectInfo: Equatable, Sendable {
        let key: String
        let size: Int64
        let etag: String?
    }

    /// Dimensione ed ETag di un oggetto, letti con una HEAD (ROADMAP #45).
    nonisolated struct S3ObjectHead: Equatable, Sendable {
        let size: Int64
        /// Cosi' come arriva nell'intestazione (virgolette comprese); `nil` se manca.
        let etag: String?
    }

    /// Una pagina di `ListObjectsV2` letta oggetto per oggetto.
    nonisolated struct S3ListPage: Equatable, Sendable {
        let objects: [S3ObjectInfo]
        let isTruncated: Bool
        /// `nil` anche quando `isTruncated` e' vero ma la pagina non dice da dove ripartire:
        /// chi legge deve trattarlo come lista incompleta, non come lista finita.
        let nextToken: String?
        /// Voci `<Contents>` senza chiave, senza dimensione leggibile o non chiuse.
        let malformedEntries: Int
    }

    /// Legge una pagina blocco `<Contents>` per blocco `<Contents>`: chiave, dimensione ed ETag
    /// di un oggetto vengono dallo STESSO blocco. `listPage` accoppia per posizione due liste
    /// separate (chiavi e dimensioni): per l'ETag non basterebbe, perche' un oggetto senza ETag
    /// sposterebbe tutti i successivi di un posto — l'ETag di un file finirebbe su un altro, e
    /// un contenuto risulterebbe «certificato» su una chiave che non lo contiene.
    ///
    /// Scorre la stringa per intervalli, senza ricopiarne il resto a ogni voce. `nonisolated`
    /// e statica: l'inventario la chiama fuori dal main, e non tocca niente dell'istanza.
    nonisolated static func parseListPage(_ xml: String) -> S3ListPage {
        func firstValue(_ tag: String, in range: Range<String.Index>) -> String? {
            guard let open = xml.range(of: "<\(tag)>", range: range),
                  let close = xml.range(of: "</\(tag)>", range: open.upperBound..<range.upperBound) else { return nil }
            return xmlDecode(String(xml[open.upperBound..<close.lowerBound]))
        }
        var objects: [S3ObjectInfo] = []
        // Una risposta senza l'involucro della lista (vuota, non UTF-8, un <Error>, un corpo
        // troncato) non e' "una pagina senza oggetti": e' una pagina che non si e' letta.
        // Senza questa riga, una risposta illeggibile chiuderebbe la lista come COMPLETA e
        // VUOTA, e ogni foto risulterebbe mancante da Cubbit.
        var malformed = (xml.contains("<ListBucketResult") && xml.contains("</ListBucketResult>")) ? 0 : 1
        var cursor = xml.startIndex
        while let open = xml.range(of: "<Contents>", range: cursor..<xml.endIndex) {
            guard let close = xml.range(of: "</Contents>", range: open.upperBound..<xml.endIndex) else {
                malformed += 1
                break
            }
            let block = open.upperBound..<close.lowerBound
            if let key = firstValue("Key", in: block),
               let sizeText = firstValue("Size", in: block),
               let size = Int64(sizeText), size >= 0 {
                objects.append(S3ObjectInfo(key: key, size: size, etag: firstValue("ETag", in: block)))
            } else {
                malformed += 1
            }
            cursor = close.upperBound
        }
        // I tag di controllo si cercano in tutta la pagina: dentro una chiave non possono
        // comparire, perche' la lista scrive `<` come `&lt;`.
        let whole = xml.startIndex..<xml.endIndex
        let isTruncated = firstValue("IsTruncated", in: whole) == "true"
        // Un token vuoto non permette di proseguire: con `""` si richiederebbe di nuovo la
        // prima pagina, all'infinito. Vale come assente, cioe' lista troncata senza token.
        let rawToken = isTruncated ? firstValue("NextContinuationToken", in: whole) : nil
        let token = rawToken.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return S3ListPage(objects: objects, isTruncated: isTruncated, nextToken: token, malformedEntries: malformed)
    }
}

// MARK: - ETag di Cubbit (ROADMAP #44, ADR-0015)

/// La forma di un ETag di Cubbit. Tre casi, nient'altro: tutto quello che non e' riconosciuto
/// con certezza e' `.unrecognized`, e un ETag non riconosciuto non certifica mai niente.
// `nonisolated`: pura, chiamata dal confronto fuori dal main.
nonisolated enum S3ETag: Equatable, Sendable {
    /// Caricamento unico: l'ETag e' l'MD5 del contenuto.
    case singlePart(md5: String)
    /// Caricamento a pezzi: `md5(md5(parte1) ‖ … ‖ md5(parteN))-N`.
    case multipart(digest: String, parts: Int)
    case unrecognized

    /// Accetta l'ETag con o senza virgolette (la lista le manda come `&quot;`, gia' decodificate
    /// da `S3Syncer.xmlDecode`), in maiuscolo o minuscolo, con spazi ai bordi. Esadecimale solo
    /// ASCII; `N` fra 1 e 10.000 (il massimo di S3), scritto senza zeri davanti.
    static func parse(_ raw: String?) -> S3ETag {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return .unrecognized }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        func isHex32(_ t: Substring) -> Bool { t.count == 32 && t.allSatisfy { $0.isASCII && $0.isHexDigit } }
        let pieces = s.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count == 1, isHex32(pieces[0]) { return .singlePart(md5: String(pieces[0])) }
        if pieces.count == 2, isHex32(pieces[0]), let n = Int(pieces[1]), n >= 1, n <= 10_000, String(n) == pieces[1] {
            return .multipart(digest: String(pieces[0]), parts: n)
        }
        return .unrecognized
    }
}

/// Decisione 1 di Enrico: «certificato» su Cubbit vuol dire contenuto, confrontato con l'ETag
/// senza scaricare. Un oggetto che non si riesce a confrontare cosi' e' NON CERTIFICABILE, mai
/// «certificato» per ipotesi.
// `nonisolated`: pura.
nonisolated enum S3ETagMatcher {
    /// Un file letto su SSD o HDD, con le sue impronte.
    struct Candidate: Equatable, Sendable {
        let size: Int64
        let sha256: String
        let md5: String
        let multipartETag: String?
        /// `ContentDigest.alternativeMultipartETags`: parti da 128 MiB e formula «in testo».
        var alternativeETags: [String] = []
    }

    enum NotCertifiableReason: String, Equatable, Sendable {
        case unrecognizedFormat
        /// `-N` con un numero di parti che non torna con 64 MiB: caricato con un'altra
        /// dimensione delle parti (per esempio da rclone). Ricalcolarlo vorrebbe dire scaricarlo.
        case differentPartSize
        /// Formato giusto, ma nessun file locale della stessa dimensione lo produce.
        case noLocalFileProducesIt
        /// Due contenuti locali diversi producono lo stesso ETag (una collisione MD5): non si
        /// sceglie a caso.
        case ambiguous
    }

    enum Verdict: Equatable, Sendable {
        case certified(sha256: String)
        /// ETag a parte unica che nessun file locale riproduce: e' l'MD5 vero di un contenuto
        /// che c'e' solo su Cubbit. Si riconosce, ma non ha un SHA256.
        case identifiedOnlyByMD5(md5: String)
        case notCertifiable(NotCertifiableReason)
    }

    /// Quante parti da `partSize` produce `S3Syncer.upload` per un file di `size` byte (un
    /// file vuoto o fino a `partSize` compresi e' una parte sola).
    static func expectedParts(size: Int64, partSize: Int) -> Int {
        guard size > 0 else { return 1 }
        return Int((size + Int64(partSize) - 1) / Int64(partSize))
    }

    /// ETag di un caricamento a pezzi con UNA parte: l'MD5 dei 16 byte dell'MD5 del file. Non
    /// dipende dalla dimensione delle parti, quindi si ricalcola da qualunque file locale.
    static func md5OfMD5Hex(_ md5Hex: String) -> String? {
        var bytes: [UInt8] = []
        var i = md5Hex.startIndex
        while i < md5Hex.endIndex {
            let j = md5Hex.index(i, offsetBy: 2, limitedBy: md5Hex.endIndex) ?? md5Hex.endIndex
            guard let b = UInt8(md5Hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        guard bytes.count == 16 else { return nil }
        return Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// La formula «in testo» per una parte sola: l'MD5 dei 32 caratteri esadecimali.
    static func md5OfMD5Text(_ md5Hex: String) -> String {
        Insecure.MD5.hash(data: Data(md5Hex.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Solo i candidati della STESSA dimensione contano (spec: «di almeno un file letto su SSD
    /// o HDD con la stessa dimensione»): il filtro e' qui, non affidato a chi chiama.
    static func verdict(etag: String?, size: Int64, candidates: [Candidate],
                        partSize: Int = S3Syncer.multipartChunkSize) -> Verdict {
        let sameSize = candidates.filter { $0.size == size }
        let matching: [Candidate]
        switch S3ETag.parse(etag) {
        case .unrecognized:
            return .notCertifiable(.unrecognizedFormat)
        case .singlePart(let md5):
            matching = sameSize.filter { $0.md5 == md5 }
            if matching.isEmpty { return .identifiedOnlyByMD5(md5: md5) }
        case .multipart(let digest, 1):
            // Una parte sola: non dipende dalla dimensione delle parti. Due formule, quella
            // standard e quella «in testo» (MD5 dell'MD5 esadecimale), entrambe trovate sul
            // bucket reale il 2026-09-30.
            matching = sameSize.filter { md5OfMD5Hex($0.md5) == digest || md5OfMD5Text($0.md5) == digest }
            if matching.isEmpty { return .notCertifiable(.noLocalFileProducesIt) }
        case .multipart(let digest, let parts):
            let wanted = "\(digest)-\(parts)"
            matching = sameSize.filter { $0.multipartETag == wanted || $0.alternativeETags.contains(wanted) }
            if matching.isEmpty {
                return .notCertifiable(parts == expectedParts(size: size, partSize: partSize)
                                       ? .noLocalFileProducesIt : .differentPartSize)
            }
        }
        let shas = Set(matching.map(\.sha256))
        guard shas.count == 1, let sha = shas.first else { return .notCertifiable(.ambiguous) }
        return .certified(sha256: sha)
    }
}

// MARK: - Spazio usato su Cubbit
//
// Persistenza e testo di "X usati · aggiornato...". Spec `Docs/superpowers/specs/2026-09-19-
// volume-space-indicator-design.md`, ADR-0008.

/// Ultimo numero conosciuto di spazio usato su Cubbit, con la data in cui è stato calcolato.
/// Persistito in `UserDefaults` — il numero resta visibile anche ad app appena aperta, con la
/// sua data.
struct CloudUsageSnapshot: Codable, Equatable {
    let usedBytes: Int64
    let objectCount: Int
    let measuredAt: Date
    let bucket: String
}

extension CloudUsageSnapshot {
    private enum CodingKeys: String, CodingKey { case usedBytes, objectCount, measuredAt, bucket }

    /// `init(from:)` esplicita con `decodeIfPresent` FIN DAL PRIMO GIORNO — regola nata dal
    /// fatto misurato n. 5 di #31 (`JobSummary`): i default sulle proprietà NON rendono
    /// retrocompatibile un `Codable`, la `init(from:)` sintetizzata lancia `keyNotFound` su una
    /// chiave assente e ignora il default. Qui non c'è ancora un campo "vecchio": è scritta
    /// così da subito per non dover riscoprire la stessa lezione una quarta volta. Un record
    /// che non decodifica per un campo davvero mancante è un record rotto, non recuperabile:
    /// `CloudUsageStore.load` lo tratta come "mai misurato" (nessun crash).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedBytes = try c.decode(Int64.self, forKey: .usedBytes)
        objectCount = try c.decodeIfPresent(Int.self, forKey: .objectCount) ?? 0
        measuredAt = try c.decode(Date.self, forKey: .measuredAt)
        bucket = try c.decode(String.self, forKey: .bucket)
    }
}

/// Motivo per cui il bottone ↻ di Cubbit è disattivato, o `nil` se è cliccabile. Logica pura,
/// niente gergo ("indice"/"hash"/"scansione" non compaiono, come da regola del progetto).
enum CloudUsageRefreshGate {
    static func disabledReason(jobIsRunning: Bool, isRefreshing: Bool) -> String? {
        if jobIsRunning {
            return "Disponibile a backup finito: un backup su Cubbit lo aggiorna già da solo"
        }
        if isRefreshing {
            return "Sto già calcolando lo spazio usato…"
        }
        return nil
    }
}

/// Le frasi mostrate sotto Cubbit nella sidebar. Logica pura: `now`/`calendar`/`locale`
/// iniettati per essere testabile a cavallo della mezzanotte e indipendentemente dalla lingua
/// di sistema — stesso criterio di `checkDeepMirrorFreshness`.
enum CloudUsageText {
    static func usedLine(_ snapshot: CloudUsageSnapshot?) -> String {
        guard let snapshot else { return "Spazio usato non ancora calcolato" }
        return "\(SpaceFormat.bytes(snapshot.usedBytes)) usati"
    }

    static func updatedLine(_ snapshot: CloudUsageSnapshot?, now: Date,
                             calendar: Calendar, locale: Locale) -> String {
        guard let snapshot else { return "Si aggiorna al prossimo backup su Cubbit" }
        let day = calendar.startOfDay(for: snapshot.measuredAt)
        let today = calendar.startOfDay(for: now)
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = locale
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        let time = timeFormatter.string(from: snapshot.measuredAt)

        if day == today {
            return "aggiornato oggi alle \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "aggiornato ieri alle \(time)"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = locale
        let sameYear = calendar.component(.year, from: snapshot.measuredAt) == calendar.component(.year, from: now)
        dateFormatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMMM" : "d MMMM yyyy")
        return "aggiornato il \(dateFormatter.string(from: snapshot.measuredAt))"
    }
}

/// Persistenza del numero di Cubbit — `ObservableObject` singleton `@MainActor`, osservato
/// SOLO dalla riga di Cubbit (stesso motivo di `VolumeSpaceModel`: non deve far ridisegnare
/// niente che non mostra questo numero). La lettura di `UserDefaults` all'avvio è in memoria e
/// non tocca né la rete né il Keychain.
@MainActor final class CloudUsageStore: ObservableObject {
    static let shared = CloudUsageStore()

    @Published private(set) var snapshot: CloudUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshFailed = false

    private let defaults: UserDefaults
    private static let key = "cloudUsageSnapshot"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = Self.load(defaults: defaults)
    }

    private static func load(defaults: UserDefaults) -> CloudUsageSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CloudUsageSnapshot.self, from: data)
    }

    /// Registra un nuovo totale — chiamato dal sink di default di `S3Syncer` (da tutti e sei i
    /// chiamanti di `listAll` che completano un elenco) e da `refresh()` sotto.
    func record(_ totals: S3Syncer.CloudUsageTotals, bucket: String, at date: Date = Date()) {
        recordCount += 1
        let newSnapshot = CloudUsageSnapshot(usedBytes: totals.bytes, objectCount: totals.count,
                                              measuredAt: date, bucket: bucket)
        snapshot = newSnapshot
        guard let data = try? JSONEncoder().encode(newSnapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Quante volte `record` e' stato chiamato da quando l'app e' aperta. Serve a
    /// `recordUnlessSuperseded`: un ricalcolo che dura minuti non deve sovrascrivere un numero
    /// registrato *mentre* contava (rilievo di review del 2026-09-19).
    private(set) var recordCount = 0

    /// Registra solo se nessun altro `record` e' arrivato dopo `token` (il `recordCount` letto
    /// all'inizio della lettura). Scenario: ↻ parte, intanto un SSD → Cubbit finisce e registra
    /// il totale esatto con i file appena caricati; il ↻, partito prima, arriva per ultimo con
    /// un elenco che quei file non li vedeva. Senza questo controllo vincerebbe l'ultimo ad
    /// arrivare — il numero piu' vecchio, per di piu' con la data "adesso". Confrontare le date
    /// non basterebbe: entrambe sono prese alla fine, e il ↻ finisce dopo.
    @discardableResult
    func recordUnlessSuperseded(_ totals: S3Syncer.CloudUsageTotals, bucket: String,
                                since token: Int, at date: Date = Date()) -> Bool {
        guard recordCount == token else { return false }
        record(totals, bucket: bucket, at: date)
        return true
    }

    /// Ricalcolo manuale (bottone ↻, Task 7). Usa un'istanza NUOVA e dedicata di `S3Syncer`,
    /// non quella dei job (`runner.s3Syncer`): quella condivide il proprio `cancelFlag` con i
    /// job in corso, e dopo uno stop darebbe un elenco vuoto (side-finding della spec).
    func refresh(config: S3Syncer.S3Config) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let token = recordCount
        do {
            let syncer = S3Syncer()
            let listing = try await syncer.listAllDetailed(config: config)
            if listing.isComplete {
                recordUnlessSuperseded(.of(listing.objects), bucket: config.bucket, since: token)
                lastRefreshFailed = false
            } else {
                lastRefreshFailed = true
            }
        } catch {
            lastRefreshFailed = true
        }
    }

    /// Chiamato dal bottone ↻ (Task 7) quando la configurazione S3 non è disponibile
    /// (`runner.s3Config == nil` dopo `loadS3ConfigIfNeeded()`): senza una config non c'è
    /// nessun elenco da chiedere, ma l'utente ha comunque premuto un bottone e merita di
    /// vedere che qualcosa non ha funzionato, non un silenzio.
    func markConfigUnavailable() {
        lastRefreshFailed = true
    }
}

// MARK: - Spazio dei volumi
//
// Indicatore di spazio per SSD, HDD (barra + "X liberi su Y") e Cubbit (solo "X usati").
// Spec `Docs/superpowers/specs/2026-09-19-volume-space-indicator-design.md`, ADR-0008.
//
// Logica pura (questo blocco, Task 1) + lettura fuori dal main (Task 2, sotto) + cablaggio in
// VolumeMonitor (Task 3, sezione VolumeMonitor) + UI (Task 4, sezione SidebarView/VolumeRow).

/// Soglie di colore sulla percentuale intera mostrata — le stesse parole di Enrico
/// ("sopra l'85%") prese alla lettera: 85 resta `.normal`, 86 è già `.warning`; 95 resta
/// `.warning`, 96 è già `.critical`.
enum SpaceLevel: Equatable {
    case normal, warning, critical

    static func forPercentUsed(_ percentUsed: Int) -> SpaceLevel {
        if percentUsed > 95 { return .critical }
        if percentUsed > 85 { return .warning }
        return .normal
    }
}

/// Fonte UNICA di formattazione byte per i dischi e per Cubbit (`CloudUsageText` la riusa,
/// Task 6). `isAdaptive = false` dà tre cifre significative ("448 GB" invece di "448,06 GB"):
/// si legge meglio, e con tre cifre il testo cambia ogni ~1GB su un disco da 1TB invece che
/// ogni 10MB — è ciò che tiene bassa la frequenza dei ridisegni durante una copia (vedi
/// VolumeSpaceState, più sotto). `allowsNonnumericFormatting = false` fa leggere "0 byte"
/// invece di "Zero KB" sul caso limite del disco pieno.
enum SpaceFormat {
    static func bytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: n)
    }
}

/// Esito della lettura di capacità di un volume (Task 2, `VolumeCapacityReader`). Dichiarato
/// qui perché `VolumeSpaceState.from` lo consuma; l'implementazione `nonisolated` che lo
/// produce sta subito dopo questo blocco di tipi puri.
enum VolumeCapacityReading: Equatable {
    /// Il percorso esiste ma non è la radice di un volume (es. una cartella normale lasciata
    /// al posto dell'SSD scollegato): mostrare la capacità letta lì sarebbe quella del disco
    /// che la contiene, non quella del volume che il nome sulla riga promette.
    case notAMountPoint
    /// La lettura è fallita, o il totale riportato è ≤ 0.
    case unreadable
    case measured(total: Int64, available: Int64)
}

/// Cosa si vede per un disco (SSD/HDD): percentuale intera, livello di colore e i due testi
/// già pronti per la UI e per VoiceOver. Contiene TESTO GIÀ FORMATTATO e non i byte grezzi di
/// proposito: l'uguaglianza (`Equatable`, sintetizzata sui quattro campi) è quello che decide
/// se `VolumeSpaceModel` ripubblica o no (Task 3) — due letture che differiscono di 30MB
/// producono lo stesso `freeLine` (tre cifre significative) e la stessa `percentUsed`, quindi
/// lo stesso `VolumeSpaceDisplay`, quindi NESSUN ridisegno. Se questo tipo conservasse i byte
/// grezzi, ogni giro di sondaggio (ogni 3s) produrrebbe un valore diverso e si tornerebbe al
/// difetto del 2026-09-03 (VolumeMonitor che ridisegna tutte le view che lo osservano, questa
/// volta anche durante una copia). Non "ottimizzare" spostando qui i byte grezzi.
struct VolumeSpaceDisplay: Equatable {
    let percentUsed: Int
    let level: SpaceLevel
    let freeLine: String
    let accessibilityLabel: String

    /// `available` è limitato a `0...total` prima del calcolo: una lettura anomala (che sulla
    /// carta non dovrebbe capitare, ma non è garantita dal sistema operativo) non deve produrre
    /// una percentuale negativa o sopra 100, né un crash.
    init(total: Int64, available: Int64, volumeName: String) {
        let clampedAvailable = min(max(available, 0), total)
        // Arrotondamento per DIFETTO (mai al più vicino): "100%" deve comparire solo quando il
        // disco è pieno davvero, mai quando restano ancora alcuni GB liberi.
        let usedFraction = total > 0 ? Double(total - clampedAvailable) / Double(total) : 0
        let percent = Int((usedFraction * 100).rounded(.down))
        self.percentUsed = percent
        self.level = SpaceLevel.forPercentUsed(percent)
        self.freeLine = "\(SpaceFormat.bytes(clampedAvailable)) liberi su \(SpaceFormat.bytes(total))"
        self.accessibilityLabel = "\(volumeName), \(freeLine), occupato al \(percent)%"
    }
}

/// Cosa mostra la riga sotto un volume nella sidebar. Nessun gergo: niente "capacità",
/// "volume", "byte" (a parte "0 byte" sul disco pieno), "montato" — i test di parole vietate
/// lo garantiscono.
enum VolumeSpaceState: Equatable {
    /// `mounted == false`: SEMPRE questo caso, qualunque sia l'esito della lettura — un volume
    /// scollegato non ha uno stato di spazio "vecchio" da mostrare, ha "Non collegato".
    case disconnected
    case unreadable
    case measured(VolumeSpaceDisplay)

    static func from(mounted: Bool, reading: VolumeCapacityReading?, volumeName: String) -> VolumeSpaceState {
        guard mounted else { return .disconnected }
        guard let reading else { return .unreadable }
        switch reading {
        case .notAMountPoint, .unreadable:
            // Per l'utente la conseguenza è la stessa in entrambi i casi: non si sa quanto
            // spazio resta, e non si mostra un numero su cui non ci si può fidare.
            return .unreadable
        case .measured(let total, let available):
            guard total > 0 else { return .unreadable }
            return .measured(VolumeSpaceDisplay(total: total, available: available, volumeName: volumeName))
        }
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Non collegato"
        case .unreadable: return "Spazio libero non disponibile"
        case .measured(let display): return display.freeLine
        }
    }
}

/// Legge la capacità totale/disponibile di un volume — chiamata dalla `probeQueue` di
/// `VolumeMonitor` (Task 3) e, una volta per job, da `BackupRunner` (`FreeSpaceCheck`,
/// ROADMAP #39, via `Task.detached`): sempre fuori dal main thread, mai su di esso.
///
/// Tre regole, ciascuna con un motivo misurato o documentato (spec, ADR-0008):
///
/// 1. **Un `URL` NUOVO a ogni chiamata**, mai tenuto in una proprietà. `resourceValues`
///    risponde dalla cache dell'istanza di `URL`, e l'invalidazione di quella cache è legata
///    ai giri del run loop **del main thread** (Apple DTS:
///    https://developer.apple.com/forums/thread/813641). Su una coda in background senza run
///    loop non è garantito che la cache scada mai: con un URL riusato la barra resterebbe
///    ferma al primo valore letto per sempre.
/// 2. **Guardia sul punto di montaggio.** Si legge anche `volumeURLKey` e si confronta, PER
///    COMPONENTI CANONICHE (stessa regola di `canonicalPathComponents`, mai `hasPrefix` né
///    confronto di stringa), col percorso richiesto. Se una cartella normale prende il posto
///    dell'SSD scollegato (una copia fatta a SSD staccato, uno smontaggio sporco),
///    `fileExists` risponde `true` e la capacità letta sarebbe quella del volume che CONTIENE
///    quella cartella — il disco interno, non l'SSD il cui nome sta sulla riga.
/// 3. **Mai `volumeAvailableCapacityForImportantUsageKey`.** Misurato il 2026-09-19 sull'SSD
///    ExFAT/FSKit reale: restituisce **0**, non `nil`. Un indicatore costruito su quella
///    chiave mostrerebbe l'SSD pieno al 100%, in rosso, sempre — un falso allarme permanente
///    sul disco più importante del progetto. Si usa `volumeAvailableCapacityKey`, che risponde
///    correttamente (confermato con `df`) — dal 2026-09-20 la stessa chiave che
///    `FreeSpaceCheck` usa per il controllo di spazio prima di un job (ROADMAP #39, `Task 2`
///    dell'indicatore di spazio riusato invece di una seconda lettura scritta a parte).
enum VolumeCapacityReader {
    nonisolated static func read(path: String) -> VolumeCapacityReading {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeURLKey
        ]) else { return .unreadable }
        guard let volumeURL = values.volume,
              canonicalPathComponents(of: volumeURL) == canonicalPathComponents(of: url) else {
            return .notAMountPoint
        }
        guard let total = values.volumeTotalCapacity, total > 0 else { return .unreadable }
        let available = values.volumeAvailableCapacity ?? 0
        return .measured(total: Int64(total), available: Int64(available))
    }

    /// Il disco conta come collegato se il percorso esiste **ed e' davvero un punto di
    /// montaggio** (ROADMAP #40, decisione di Enrico del 2026-09-19): una cartella normale
    /// rimasta al posto di `/Volumes/SSD - Enri` dopo uno scollegamento brusco abilitava i
    /// pulsanti dei backup, che avrebbero scritto sul disco del Mac. Una capacita' illeggibile
    /// (`.unreadable`, per esempio un HDD che dorme) NON basta a dichiararlo scollegato: solo
    /// `.notAMountPoint` e' la prova che li' non c'e' il disco.
    nonisolated static func isMounted(exists: Bool, reading: VolumeCapacityReading?) -> Bool {
        exists && reading != .notAMountPoint
    }
}

/// Se c'e' abbastanza spazio per un job, con un motivo onesto quando non si puo' saperlo
/// (ROADMAP #39). MainActor di default: e' logica pura, costa nulla girare sul main — solo la
/// LETTURA che produce `VolumeCapacityReading` va fuori dal main (`VolumeCapacityReader.read`,
/// gia' `nonisolated`, chiamata da `BackupRunner` via `Task.detached`).
enum FreeSpaceCheck {
    enum Verdict: Equatable {
        case enough
        case notEnough(available: Int64)
        /// Al posto del volume c'e' una cartella normale (`.notAMountPoint`): fino al
        /// 2026-09-19 `hasSufficientSpace` lasciava partire il job in questo caso, scrivendo
        /// sul disco del Mac — lo stesso buco che #40 ha chiuso per `ssdMounted`.
        case notADisk
        case unreadable
    }

    /// Il margine e' **copiato** da `BackupRunner.hasSufficientSpace` (rimossa), non
    /// riscritto: stesso `max(5% di bytesNeeded, 500 MB)`, stesso confronto
    /// `available >= bytesNeeded + margin`.
    static func verdict(bytesNeeded: Int64, reading: VolumeCapacityReading) -> Verdict {
        switch reading {
        case .notAMountPoint: return .notADisk
        case .unreadable: return .unreadable
        case .measured(_, let available):
            let margin = max(Int64(Double(bytesNeeded) * 0.05), 500_000_000)
            return available >= bytesNeeded + margin ? .enough : .notEnough(available: available)
        }
    }

    static func notADiskMessage(diskName: String) -> String {
        "L'\(diskName) non sembra collegato: al suo posto c'è una cartella normale del Mac. "
            + "Ricollega l'\(diskName) e riprova."
    }

    static func unreadableMessage(diskName: String) -> String {
        "Non riesco a leggere quanto spazio libero c'è sull'\(diskName) in questo momento "
            + "(può succedere se il disco si sta ancora svegliando). Riprova tra qualche secondo."
    }
}

/// Spazio libero/usato di SSD e HDD, pubblicato SEPARATO da `VolumeMonitor` (Task 3, indicatore
/// di spazio, ADR-0008).
///
/// **Perché separato, e perché non toccarlo.** SwiftUI propaga `objectWillChange` a chi osserva
/// un `ObservableObject` quando cambia una SUA `@Published` — ma NON quando cambia una
/// `@Published` di un `ObservableObject` annidato al suo interno. Le cinque view che osservano
/// `VolumeMonitor` (`ContentView`, `RestoreView`, `ImportView`, `DuplicatesView`, `SetupView`)
/// leggono solo `ssdMounted`/`hddMounted`: se lo spazio diventasse una `@Published` DI
/// `VolumeMonitor` stesso, ogni cambio di spazio (fino a una volta ogni ~5-6s durante una copia,
/// vedi `VolumeSpaceState`) ridisegnerebbe tutte e cinque, anche quelle che lo spazio non lo
/// mostrano nemmeno — lo stesso difetto n. 3 del 2026-09-03 su `VolumeMonitor`, che questa
/// feature aggraverebbe invece di risolvere. Con l'oggetto separato, solo `VolumeSpaceLine`
/// (Task 4), che osserva `VolumeMonitor.shared.space` e non `VolumeMonitor.shared`, si
/// ridisegna. Se un giorno qualcuno "semplificasse" spostando `ssd`/`hdd` dentro `VolumeMonitor`
/// per avere "un solo oggetto da osservare", reintrodurrebbe il bug del 2026-09-03 durante ogni
/// copia — non toccare senza aver riletto questo commento.
final class VolumeSpaceModel: ObservableObject {
    @Published var ssd: VolumeSpaceState = .disconnected
    @Published var hdd: VolumeSpaceState = .disconnected
}

// MARK: - VolumeMonitor
/// Sorveglia la presenza dei due volumi esterni, con un sondaggio ogni 3 secondi.
///
/// **Riscritta il 2026-09-03 dopo un beachball riprodotto da Enrico.** La versione precedente
/// aveva tre difetti che si sommavano, e insieme rendevano lenta l'INTERA app:
///
/// 1. **`fileExists` girava sul main thread.** `check()` faceva `DispatchQueue.main.async` e
///    *poi* dentro chiamava `fm.fileExists` sui due volumi: esattamente al contrario. Una
///    `stat()` su un volume esterno — SSD exFAT via FSKit, o un HDD che si e' addormentato —
///    puo' bloccare per centinaia di millisecondi. Bloccarla sul main thread e' un beachball.
/// 2. **Cinque istanze, cinque timer.** `ContentView`, `RestoreView`, `ImportView`,
///    `DuplicatesView` e `SetupView` creavano ognuna il proprio `VolumeMonitor` con
///    `@StateObject`: dieci `stat()` bloccanti ogni 3 secondi invece di due. Ora c'e' una
///    **istanza sola** (`shared`), come gia' fanno `BookmarkManager`, `AppearanceManager` e
///    `AuthGateManager`.
/// 3. **Ripubblicava lo stesso valore ogni 3 secondi.** Assegnare a un `@Published` fa scattare
///    `objectWillChange` anche quando il valore non e' cambiato: ogni view che osservava questo
///    monitor si ridisegnava **ogni 3 secondi, per sempre**, senza motivo. Combinato col bug del
///    pannello Doppioni corretto il giorno prima (che ricostruiva l'intero batch a ogni
///    ridisegno), quello era un ricalcolo completo garantito ogni 3 secondi.
///
/// Perche' il profiler non lo trovava: una `stat()` in attesa del disco **non consuma CPU**.
/// Quattro campionature con `sample` mostravano un processo "inattivo" mentre il thread
/// principale era fermo in attesa di I/O. Cercavo calcoli, il problema era attesa.
///
/// **Spazio (2026-09-19, indicatore di spazio, ADR-0008).** `check()` legge anche la capacita'
/// dei volumi presenti (`VolumeCapacityReader.read`, fuori dal main come il resto) e pubblica
/// il risultato in `space` (`VolumeSpaceModel`, oggetto SEPARATO apposta — vedi il suo
/// doc-comment), ognuno SOLO se cambiato, nello stesso salto sul main che pubblica
/// `ssdMounted`/`hddMounted`: non c'e' un istante in cui un volume risulta scollegato con la
/// barra ancora piena. `probeInFlight` (letto/scritto SOLO sul main, dove il timer scatta e
/// dove torna il salto di ritorno) evita l'accumulo di sondaggi se una lettura dura piu' di 3s
/// (un HDD che si sveglia, o ora anche la lettura di capacita'): senza, il timer accoderebbe
/// un altro `check()` sulla `probeQueue` a ogni giro, sempre di piu'.
final class VolumeMonitor: ObservableObject {
    /// Istanza unica. Le view la osservano con `@ObservedObject`, non la creano.
    static let shared = VolumeMonitor()

    @Published var ssdMounted = false
    @Published var hddMounted = false
    /// Spazio di SSD/HDD, oggetto separato apposta — vedi `VolumeSpaceModel`.
    let space = VolumeSpaceModel()
    private let ssdPath = "/Volumes/SSD - Enri"
    private let hddPath = "/Volumes/BackupHDD"
    private var timer: Timer?
    /// I `stat()` sui volumi esterni vivono qui. Mai sul main thread.
    private let probeQueue = DispatchQueue(label: "AppBackupFoto.VolumeMonitor", qos: .utility)
    /// Un sondaggio e' gia' in corso: il prossimo scatto del timer va saltato invece di
    /// accodare un altro `check()` sulla `probeQueue`. Letto e scritto SOLO sul main thread —
    /// il timer scatta li' e il salto di ritorno di `check()` arriva li' — quindi non serve
    /// un lock.
    private var probeInFlight = false

    private init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    deinit { timer?.invalidate() }

    private func check() {
        guard !probeInFlight else { return }
        probeInFlight = true
        probeQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let ssd = fm.fileExists(atPath: self.ssdPath)
            let hdd = fm.fileExists(atPath: self.hddPath)
            // La lettura di capacita' ha senso solo per i volumi presenti: su un volume
            // scollegato produrrebbe solo `.unreadable`/`.notAMountPoint` a costo zero
            // aggiunto, ma non c'e' motivo di pagare nemmeno quello.
            let ssdReading = ssd ? VolumeCapacityReader.read(path: self.ssdPath) : nil
            let hddReading = hdd ? VolumeCapacityReader.read(path: self.hddPath) : nil
            let ssdIsDisk = VolumeCapacityReader.isMounted(exists: ssd, reading: ssdReading)
            let hddIsDisk = VolumeCapacityReader.isMounted(exists: hdd, reading: hddReading)
            DispatchQueue.main.async {
                // Si pubblica SOLO se il valore e' cambiato davvero: un `@Published`
                // riassegnato allo stesso valore fa comunque ridisegnare ogni osservatore.
                if self.ssdMounted != ssdIsDisk { self.ssdMounted = ssdIsDisk }
                if self.hddMounted != hddIsDisk { self.hddMounted = hddIsDisk }
                let ssdSpace = VolumeSpaceState.from(mounted: ssdIsDisk, reading: ssdReading, volumeName: "SSD - Enri")
                let hddSpace = VolumeSpaceState.from(mounted: hddIsDisk, reading: hddReading, volumeName: "BackupHDD")
                if self.space.ssd != ssdSpace { self.space.ssd = ssdSpace }
                if self.space.hdd != hddSpace { self.space.hdd = hddSpace }
                self.probeInFlight = false
            }
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
        // BUG-10 (2026-09-28): sotto il test host di `xcodebuild test` questa funzione parte
        // comunque, chiamata dalla `.task` di `ContentView` — nessun test la chiama a mano.
        // Senza questa guardia leggerebbe il Keychain vero (`kSecAttrService: "AppBackupFoto"`)
        // e, in fallback, `~/.config/rclone/rclone.conf` dell'utente a ogni corsa di test.
        // Restare con `s3Config == nil` e' lo stato che l'app gestisce gia' (nessuna config
        // trovata): nessun nuovo ramo per i chiamanti.
        guard !isRunningUnderTests() else { return }
        // `BackupRunner` e' `@MainActor`, quindi questo corpo girerebbe TUTTO sul main thread —
        // inclusa `readConfigWithSource`, che legge il **Keychain** e, in fallback, un file di
        // configurazione. Un accesso al Keychain puo' costare centinaia di millisecondi, e
        // questa funzione e' chiamata dalla `.task` di `ContentView`, cioe' all'avvio: era il
        // secondo blocco del thread principale al lancio (2026-09-03). La lettura va fuori, il
        // risultato torna qui.
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try S3Syncer.readConfigWithSource() }
        }.value
        switch outcome {
        case .success(let result):
            s3Config = result.config
            s3ConfigFromKeychain = result.fromKeychain
        case .failure(let error):
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

    // MARK: Passo 2 del backup: l'elenco si aggiorna come ultima parte del job (2026-09-19)

    /// `nil` = nessun passo 2 previsto per il job in corso. `.planned` = previsto, il passo 1
    /// (la copia) e' ancora in corso: l'intestazione dice "passo 1 di 2". `.running` = il
    /// passo 1 e' finito, la lettura sta girando: "passo 2 di 2". Il job resta `.running`
    /// (`isRunning == true`) per TUTTO il passo 2 (D1 della spec): e' la scelta che tiene
    /// disattivati i pulsanti di backup, il wizard di importazione e lo spostamento nel
    /// Cestino senza dover toccare ognuno di quei siti — leggono gia' tutti `isRunning`.
    @Published private(set) var listStepState: BackupListStep.State? = nil
    /// "Interrompi" e' stato premuto durante il passo 2: il pulsante resta visibile ma
    /// disattivato con "Mi fermo…" finche' `scan` non torna. Non e' `wasStopped`: quel flag
    /// farebbe leggere il job come fallito, mentre qui il job finisce comunque "completato"
    /// (D3).
    @Published private(set) var listStopRequested = false

    /// Percentuale mostrata da barra della finestra, `PhaseIndicator` e badge del Dock:
    /// quella del passo 2 mentre gira, altrimenti quella del passo 1 di sempre. Un solo
    /// numero, in un posto solo — nessun chiamante deve piu' decidere da se' quale dei due
    /// leggere.
    var displayPercent: Int {
        if case .running(let estimate) = listStepState {
            return BackupListStep.progress(scanned: indexProgress?.scanned ?? 0, estimate: estimate).percent
        }
        return stats.percent
    }

    /// `nil` finche' il passo 2 non e' davvero in corso (`.planned` non basta: durante la
    /// copia `StatsPanel` mostra ancora miniatura + stato). Valori gia' calcolati, nessuna
    /// stringa costruita nella View.
    var listStepPresentation: BackupListStep.Presentation? {
        guard case .running(let estimate) = listStepState else { return nil }
        let scanned = indexProgress?.scanned ?? 0
        let shownTotal = BackupListStep.progress(scanned: scanned, estimate: estimate).shownTotal
        return BackupListStep.Presentation(copyDone: BackupListStep.copyDoneLine(stats: stats),
                                           runningLine: BackupListStep.runningLine,
                                           countLine: BackupListStep.countLine(scanned: scanned, shownTotal: shownTotal))
    }

    /// Vero mentre `DuplicateTrasher.run` sta spostando un blocco nel Cestino. Vive QUI,
    /// non in uno `@State` di `DuplicatesView`: uno `@State` torna `false` quando la finestra
    /// si riapre, permettendo un secondo spostamento in parallelo al primo — esattamente il
    /// caso che il pannello Doppioni vieta (ADR-0005, "cestinare mentre un mirror legge gli
    /// stessi file trasforma due operazioni corrette in un guasto"). Vive nel runner come
    /// `isRunning`/`isIndexing`, cosi' tutti e tre si controllano nello stesso posto.
    @Published private(set) var isTrashingDuplicates = false

    /// Prova ad avviare uno spostamento nel Cestino. Rifiuta (restituendo l'avviso da
    /// mostrare) se e' gia' in corso uno spostamento, un job o una lettura dell'elenco;
    /// altrimenti imposta il flag e restituisce `nil`. Controllo e impostazione sono
    /// atomici rispetto a ogni altro gate perche' girano entrambi sul MainActor.
    func beginDuplicateTrashing() -> SimpleAlert? {
        guard !isTrashingDuplicates, !isRunning, !isIndexing, !isRestoringFromTrash, !isInventorying,
              !isRepairing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, una riparazione, un altro spostamento nel Cestino o "
                    + "un annullamento). Aspetta che finisca.")
        }
        isTrashingDuplicates = true
        return nil
    }

    /// Chiamato SEMPRE dallo stesso `MainActor.run` che pubblica l'esito dello spostamento —
    /// `DuplicateTrasher.run` non lancia mai, quindi nessun percorso lo salta.
    func endDuplicateTrashing() {
        isTrashingDuplicates = false
    }

    /// Vero mentre `TrashRestorer.run` sta rimettendo a posto l'ultimo blocco spostato nel
    /// Cestino (ADR-0009). Stesso motivo di `isTrashingDuplicates`: vive nel runner, non in
    /// uno `@State` di `DuplicatesView` — riaprire la finestra non deve far perdere la
    /// mutua esclusione con un job, una lettura o uno spostamento in corso.
    @Published private(set) var isRestoringFromTrash = false

    /// Prova ad avviare un annullamento. Rifiuta (restituendo l'avviso da mostrare) se e'
    /// gia' in corso uno spostamento nel Cestino, un job, una lettura dell'elenco o un altro
    /// annullamento; altrimenti imposta il flag e restituisce `nil`. Controllo e
    /// impostazione sono atomici perche' girano entrambi sul MainActor.
    func beginTrashRestore() -> SimpleAlert? {
        guard !isRestoringFromTrash, !isTrashingDuplicates, !isRunning, !isIndexing, !isInventorying,
              !isRepairing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura "
                    + "dell'elenco, un inventario, una riparazione, uno spostamento nel Cestino o un "
                    + "altro annullamento). Aspetta che finisca.")
        }
        isRestoringFromTrash = true
        return nil
    }

    /// Vero mentre una riparazione scrive su SSD, HDD o Cubbit (ROADMAP #45, ADR-0016). Vive QUI
    /// e non in uno `@State` di `InventoryView`, per la stessa ragione di `isTrashingDuplicates`:
    /// riaprire la finestra non deve permettere una seconda riparazione in parallelo, ne' un
    /// backup, una lettura, un inventario, uno spostamento o un annullamento.
    @Published private(set) var isRepairing = false

    /// Prova ad avviare una riparazione: rifiuta se c'e' gia' un'altra operazione in corso,
    /// altrimenti alza il flag. Controllo e impostazione sono atomici: entrambi sul MainActor.
    func beginRepair() -> SimpleAlert? {
        guard !isRepairing, !isTrashingDuplicates, !isRestoringFromTrash, !isInventorying, !isRunning,
              !isIndexing else {
            return SimpleAlert(title: "Meglio non farlo adesso",
                message: "C'è già un'altra operazione in corso (un backup, una lettura dell'elenco, "
                    + "un inventario, uno spostamento nel Cestino, un annullamento o un'altra "
                    + "riparazione). Aspetta che finisca.")
        }
        isRepairing = true
        return nil
    }

    /// Chiamato SEMPRE dall'unico punto in cui una riparazione finisce (`finishRepair`).
    func endRepair() {
        isRepairing = false
    }

    /// Chiamato SEMPRE dallo stesso `MainActor.run` che pubblica l'esito dell'annullamento —
    /// `TrashRestorer.run` non lancia mai, quindi nessun percorso lo salta.
    func endTrashRestore() {
        isRestoringFromTrash = false
    }

    // MARK: Annullamento dell'ultimo spostamento (Task 7, ADR-0009)

    /// Stato dell'annullamento vive QUI, non in `@State` di `DuplicatesView` — stesso motivo
    /// di `isRestoringFromTrash`: chiudere e riaprire la finestra Doppioni non deve far
    /// perdere barra e «Interrompi» di un annullamento ancora in corso (e' esattamente il
    /// difetto gia' noto dello spostamento nel Cestino, vedi ROADMAP #41).
    ///
    /// `private(set)` da quando #41 e' stato chiuso allo stesso modo (2026-09-24): l'unico
    /// scrittore esterno che restava (`DuplicatesView.startTrashing`, che azzerava
    /// `lastTrashRestoreOutcome` all'avvio di uno spostamento) e' stato spostato dentro il
    /// runner — oggi `startDuplicateTrashRun` (Task 10/11, il percorso a blocco singolo di
    /// #41 e' stato rimosso il 2026-09-25) — l'invariante "un `begin` riuscito e' sempre
    /// seguito da un `end` nello stesso `MainActor.run` che pubblica l'esito" e' verificabile
    /// leggendo una sola funzione solo se nessun altro puo' muovere questo stato.
    @Published private(set) var trashRestoreProgress: (done: Int, total: Int)? = nil
    @Published private(set) var trashRestoreStopRequested = false
    @Published private(set) var lastTrashRestoreOutcome: RestoreOutcome? = nil
    /// Cosa resta da rimettere a posto, calcolato fuori dal main (D8): la UI lo legge in O(1)
    /// invece di rifare `pendingInLastBatch()` a ogni ridisegno.
    @Published private(set) var restorableBatch: RestorableBatchSummary? = nil
    private var trashRestoreCancelFlag: CancelFlag? = nil

    /// Ricalcola `restorableBatch` fuori dal main. Chiamato all'apertura della finestra
    /// Doppioni, a fine spostamento e a fine annullamento.
    func refreshRestorableBatch() {
        guard let manifest = trashManifestStore else { restorableBatch = nil; return }
        // `guard let self` e non `self?.`: una `var` weak riferita da una closure
        // concorrente e' un errore in Swift 6, e qui una referenza forte per la durata di
        // una query non cambia niente (il runner vive quanto l'app) — stesso schema di
        // `refreshIndexedFileCount`.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let summary = manifest.restorableSummary()
            await MainActor.run {
                // Non ripubblicare lo stesso valore (lezione del 2026-09-03): evita un
                // ridisegno che nessuno ha chiesto.
                guard self.restorableBatch != summary else { return }
                self.restorableBatch = summary
            }
        }
    }

    /// Avvia l'annullamento dell'ultimo blocco non ancora rimesso a posto. `onAlert` e' il
    /// canale della finestra Doppioni (regola `AlertSink`): mai `pendingAlert`, che ha un
    /// solo presentatore nella finestra principale.
    func startTrashRestore(onAlert: @escaping (SimpleAlert) -> Void) {
        // Stessa disciplina di `startDuplicateTrashRun` sotto: il motivo
        // **specifico** prima dell'alert generico. Senza questa rivalutazione, uno
        // scollegamento dell'SSD mentre la conferma non distruttiva e' aperta farebbe
        // comunque partire l'annullamento — si fermerebbe da solo con un esito onesto
        // (`TrashRestorer` legge `st_dev` prima di toccare qualunque cosa), ma con una frase
        // piu' tortuosa di «L'SSD non è collegato» (domanda 3 della spec del 2026-09-20,
        // decisa: si').
        if let reason = DuplicatesStatus.undoDisabledReason(ssdMounted: VolumeMonitor.shared.ssdMounted,
                                                             isRunning: isRunning, isIndexing: isIndexing,
                                                             isTrashingDuplicates: isTrashingDuplicates,
                                                             isRestoringFromTrash: isRestoringFromTrash,
                                                             summary: restorableBatch, hasEverTrashed: (trashManifestStore?.totalRecorded ?? 0) > 0,
                                                             isInventorying: isInventorying, isRepairing: isRepairing) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        if let alert = beginTrashRestore() {
            onAlert(alert)
            return
        }
        guard let manifest = trashManifestStore, let root = BookmarkManager.shared.urls[.ssd] else {
            endTrashRestore()
            onAlert(SimpleAlert(title: "Non è stato possibile procedere",
                message: "Il registro di ripristino o l'SSD non sono disponibili in questo "
                    + "momento. Riprova dopo aver ricontrollato Diagnostica."))
            return
        }

        let flag = CancelFlag()
        trashRestoreCancelFlag = flag
        trashRestoreStopRequested = false
        lastTrashRestoreOutcome = nil
        // Invalidazione reciproca (D5, ROADMAP #41): un annullamento rende obsoleto l'esito
        // di una corsa mostrato in precedenza, riguardava blocchi diversi. Dal 2026-09-25
        // (Task 14) il percorso a blocco singolo e' rimosso: si invalida `lastDuplicateRunOutcome`.
        lastDuplicateRunOutcome = nil
        let items = manifest.pendingInLastBatch()
        trashRestoreProgress = (0, items.count)

        Task.detached(priority: .utility) {
            let restorer = TrashRestorer(libraryRoot: root, manifest: manifest)
            var throttle = ProgressThrottle()
            let outcome = restorer.run(items, onProgress: { done, total in
                guard throttle.shouldEmit(nowNanos: DispatchTime.now().uptimeNanoseconds,
                                          isFinal: done == total) else { return }
                Task { @MainActor in self.trashRestoreProgress = (done, total) }
            }, isCancelled: { flag.isCancelled })

            await MainActor.run {
                self.endTrashRestore()
                self.trashRestoreProgress = nil
                self.trashRestoreStopRequested = false
                self.trashRestoreCancelFlag = nil
                self.lastTrashRestoreOutcome = outcome
                self.refreshRestorableBatch()
            }
        }
    }

    /// «Interrompi» durante l'annullamento. Una foto grande puo' richiedere secondi di
    /// rilettura prima che l'interruzione abbia effetto: la rilettura non si interrompe a
    /// meta' per poi spostare comunque il file.
    func stopTrashRestore() {
        guard !trashRestoreStopRequested else { return }
        trashRestoreStopRequested = true
        trashRestoreCancelFlag?.cancel()
    }

    // MARK: Corsa a piu' blocchi (Task 10, ADR-0011/0012)
    //
    // Il percorso a blocco singolo (`startDuplicateTrashing`/`stopDuplicateTrashing`/
    // `duplicateTrashProgress`/`duplicateTrashStopRequested`/`lastDuplicateTrashOutcome`/
    // `duplicateTrashCancelFlag`, nati con ROADMAP #41 il 2026-09-24) e' stato **rimosso il
    // 2026-09-25 (Task 14)**: la corsa a piu' blocchi qui sotto li ha sostituiti per intero
    // — `DuplicatesView` non li chiamava piu' da quando il Task 11 ha ricablato
    // `startTrashing(_:)` su `startDuplicateTrashRun`, e `grep` su tutto il progetto (test
    // compresi) confermava zero chiamanti rimasti. Vedi la nota in coda ad ADR-0009.

    /// Stato di una **corsa** (la sequenza di blocchi di un `DuplicateRunPlan`) — vive QUI,
    /// non in `@State` di `DuplicatesView`: chiudere e riaprire la finestra Doppioni non deve
    /// far perdere barra, «Interrompi» o l'esito di una corsa in corso — lo stesso principio
    /// gia' scritto sopra per l'annullamento e per il percorso a blocco singolo che questi
    /// campi hanno sostituito (rimosso il 2026-09-25, vedi la nota sopra).
    @Published private(set) var duplicateRunProgress: (blockIndex: Int, blockCount: Int, filesDone: Int, filesTotal: Int)? = nil
    @Published private(set) var duplicateRunStopRequested = false
    @Published private(set) var lastDuplicateRunOutcome: DuplicateRunOutcome? = nil
    private var duplicateRunCancelFlag: CancelFlag? = nil

    /// Avvia una corsa a piu' blocchi su un piano gia' diviso ai tetti (`DuplicateRunPlan`,
    /// ADR-0012). `onAlert` e' il canale della finestra Doppioni (regola `AlertSink`).
    ///
    /// `beginDuplicateTrashing()`/`endDuplicateTrashing()` vengono chiamati **una volta per
    /// l'intera corsa**, non per blocco: due chiamate per blocco riaprirebbero, fra un blocco
    /// e l'altro, la finestra in cui un altro job/lettura/annullamento potrebbe partire —
    /// esattamente la garanzia che `isTrashingDuplicates` esiste per chiudere (ADR-0009).
    /// Conseguenza diretta e voluta: per tutta la durata della corsa nessun'altra operazione
    /// puo' partire (`JobStartGate`/`LibraryIndexCommandGate`/`beginTrashRestore` guardano
    /// tutti `isTrashingDuplicates`), quindi l'unica precondizione che puo' davvero cambiare
    /// fra un blocco e l'altro — non gia' impedita alla fonte da questo stesso flag — e' lo
    /// scollegamento fisico dell'SSD, controllato di nuovo prima di ogni blocco qui sotto.
    ///
    /// `DuplicateTrasher.run`/`verify` non cambiano di una riga: questa funzione li chiama,
    /// uno per blocco.
    ///
    /// **La catena si ferma** se l'esito di un blocco ha `stoppedBecauseVolumeVanished` o
    /// contiene un gruppo saltato con motivo `.trashFailed` — mai per gli altri gruppi
    /// saltati dalla verifica (`DuplicateTrashSkipReason`), che su questa libreria sono la
    /// normalita' (ADR-0002): fermarsi li' vorrebbe dire non arrivare mai in fondo a una
    /// corsa vera.
    func startDuplicateTrashRun(_ plan: DuplicateRunPlan, onAlert: @escaping (SimpleAlert) -> Void) {
        guard !plan.blocks.isEmpty else { return }

        let reason = DuplicatesStatus.trashDisabledReason(isRunning: isRunning,
                                                           isIndexing: isIndexing,
                                                           ssdMounted: VolumeMonitor.shared.ssdMounted,
                                                           isTrashingDuplicates: isTrashingDuplicates,
                                                           isRestoringFromTrash: isRestoringFromTrash,
                                                           isInventorying: isInventorying,
                                                           isRepairing: isRepairing)
        if let reason {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }

        guard let store = libraryIndexStore,
              let manifest = trashManifestStore,
              let history = trashHistoryStore,
              let root = BookmarkManager.shared.urls[.ssd] else {
            onAlert(SimpleAlert(
                title: "Non è stato possibile procedere",
                message: "L'elenco delle foto, il registro di ripristino, la storia degli "
                    + "spostamenti o l'SSD non sono disponibili in questo momento. Riprova "
                    + "dopo aver ricontrollato Diagnostica."))
            return
        }

        if let alert = beginDuplicateTrashing() {
            onAlert(alert)
            return
        }

        let cancelFlag = CancelFlag()
        duplicateRunCancelFlag = cancelFlag
        duplicateRunStopRequested = false
        lastDuplicateRunOutcome = nil
        // Invalidazione reciproca (D5): una
        // nuova corsa rende obsoleto l'ultimo esito di annullamento mostrato.
        lastTrashRestoreOutcome = nil
        let totalBlocks = plan.blocks.count
        let totalFiles = plan.blocks.reduce(0) { $0 + $1.reduce(0) { $0 + $1.leaving.count } }
        duplicateRunProgress = (blockIndex: 1, blockCount: totalBlocks, filesDone: 0, filesTotal: totalFiles)

        Task.detached(priority: .utility) {
            var runOutcome = DuplicateRunOutcome(totalBlocks: totalBlocks)
            var filesDoneSoFar = 0

            for (index, block) in plan.blocks.enumerated() {
                if cancelFlag.isCancelled {
                    runOutcome.stopReason = .interrupted
                    break
                }
                guard await MainActor.run(body: { VolumeMonitor.shared.ssdMounted }) else {
                    runOutcome.stopReason = .volumeVanished
                    break
                }

                let batchId = UUID().uuidString
                let decisions = block.map { DuplicateTrasher.Decision(group: $0.group, keeper: $0.choice.keeper) }
                let trasher = DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest)
                // Catturato per valore prima della corsa del blocco: l'`onProgress` sotto
                // legge solo questa costante, mai `filesDoneSoFar` direttamente — quella
                // cambia solo DOPO che il blocco e' finito, ma una chiusura che catturasse la
                // `var` per riferimento potrebbe eseguire in ritardo (e' un `Task {}` non
                // strutturato) e leggere il valore gia' aggiornato del blocco successivo.
                let doneBeforeThisBlock = filesDoneSoFar

                // `done`/`total` di `DuplicateTrasher.run` contano GRUPPI processati, non
                // file: per il conteggio in file (quello che `DuplicatesStatus.runProgressLine`
                // si aspetta) si sommano i file dei soli gruppi gia' processati in questo
                // blocco (`block` e `decisions` condividono lo stesso ordine). Un gruppo
                // saltato conta comunque come "processato", stessa filosofia del trasher
                // stesso (il lavoro fatto, non solo quello riuscito).
                let blockOutcome = trasher.run(decisions, batchId: batchId, onProgress: { done, _ in
                    let filesInBlockSoFar = block.prefix(done).reduce(0) { $0 + $1.leaving.count }
                    Task { @MainActor in
                        self.duplicateRunProgress = (blockIndex: index + 1, blockCount: totalBlocks,
                                                     filesDone: doneBeforeThisBlock + filesInBlockSoFar,
                                                     filesTotal: totalFiles)
                    }
                }, isCancelled: { cancelFlag.isCancelled })

                // Scritta per OGNI blocco su cui `run` e' tornato, completo o interrotto che
                // sia: e' una storia di quello che e' successo, non solo dei blocchi finiti
                // senza intoppi (`TrashHistory.append` non fa nulla se `trashed` e' vuoto).
                history.append(blockId: batchId, trashed: blockOutcome.trashedFiles)

                runOutcome.trashedFiles.append(contentsOf: blockOutcome.trashedFiles)
                runOutcome.skippedGroups.append(contentsOf: blockOutcome.skippedGroups)
                filesDoneSoFar += blockOutcome.trashedFiles.count

                if blockOutcome.interrupted {
                    runOutcome.stopReason = .interrupted
                    break
                }
                if blockOutcome.stoppedBecauseVolumeVanished {
                    runOutcome.stopReason = .volumeVanished
                    break
                }
                if let failed = blockOutcome.skippedGroups.first(where: {
                    if case .trashFailed = $0.reason { return true }
                    return false
                }), case .trashFailed(let path, let detail) = failed.reason {
                    runOutcome.stopReason = .trashFailed(displayPath: path, detail: detail)
                    break
                }

                runOutcome.blocksCompleted += 1
            }

            // Snapshot immutabile: il ciclo sopra e' finito qui, in sequenza (non c'e' nessuna
            // corsa da coprire), ma `runOutcome` resta un `var` mutato nel ciclo e Swift 6 non
            // permette di catturarlo cosi' com'e' in una chiusura che esegue concorrentemente
            // (`await MainActor.run`). Un `let` non annota niente e non allarga l'isolamento
            // di nessun tipo: la sua correttezza si legge per intero in queste due righe.
            let finalOutcome = runOutcome

            await MainActor.run {
                // `endDuplicateTrashing()` nello STESSO blocco che pubblica l'esito, stessa
                // disciplina di `startTrashRestore`: nessun percorso di questo ciclo
                // salta questa chiamata e lascia il flag bloccato a `true` per sempre.
                self.endDuplicateTrashing()
                self.duplicateRunProgress = nil
                self.duplicateRunStopRequested = false
                self.duplicateRunCancelFlag = nil
                self.lastDuplicateRunOutcome = finalOutcome
                self.refreshRestorableBatch()
            }
        }
    }

    /// «Interrompi» durante una corsa (idempotente, come `stopTrashRestore`): `DuplicateTrasher.run`
    /// controlla l'interruzione solo fra un gruppo e l'altro, quindi un gruppo in corso viene
    /// chiuso, mai lasciato a meta' — e un blocco in corso finisce di essere processato
    /// prima che la corsa si fermi davvero.
    func stopDuplicateTrashRun() {
        guard !duplicateRunStopRequested else { return }
        duplicateRunStopRequested = true
        duplicateRunCancelFlag?.cancel()
    }

    private let syncer = FileSyncer()
    private let s3Syncer = S3Syncer()
    private let bm = BookmarkManager.shared
    /// Indice di contenuto della libreria (roadmap #31). Lazy: se non si riesce ad
    /// aprirlo, il dedup semplicemente non avviene — l'indice e' una cache, mai un
    /// prerequisito per importare (ADR-0002). Nessun percorso di codice deve fallire
    /// per colpa sua, per questo `try?` e non `try`.
    private(set) lazy var libraryIndexStore: LibraryIndexStore? = {
        let dir = backupRunnerStoreRoot()
        return try? LibraryIndexStore(url: dir.appendingPathComponent("library-index.sqlite"))
    }()
    /// Registro di ripristino del pannello Doppioni (Task 6, #31). Stesso pattern lazy di
    /// `libraryIndexStore`, stessa cartella: e' la rete di sicurezza dell'unica operazione
    /// distruttiva del progetto, quindi anche lei sul disco interno, mai sull'SSD.
    private(set) lazy var trashManifestStore: TrashManifestStore? = {
        let dir = backupRunnerStoreRoot()
        return try? TrashManifestStore(url: dir.appendingPathComponent("trash-manifest.json"))
    }()
    /// La storia degli spostamenti (Task 8, ADR-0012 D13 punto 4). Stesso pattern lazy e
    /// stessa cartella di `trashManifestStore`/`libraryIndexStore`: mai sull'SSD, sempre sul
    /// disco interno. `TrashHistory.init` fallisce solo se la posizione non e' consentita —
    /// non c'e' un formato di file da poter corrompere come per SQLite/JSON, quindi nessun
    /// meccanismo di "riprova una volta" e' necessario qui.
    private(set) lazy var trashHistoryStore: TrashHistory? = {
        let dir = backupRunnerStoreRoot()
        return try? TrashHistory(url: dir.appendingPathComponent("trash-history.jsonl"))
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
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
                // Non si filtra per volume per la lettura dell'elenco: fermarla a ogni smontaggio e'
                // innocuo (quello che e' stato letto resta valido e la volta dopo si riprende
                // da li'), mentre continuare a leggere da un volume che sta sparendo produce
                // hash calcolati su letture troncate. L'inventario invece si ferma solo per
                // l'SSD o l'HDD (ROADMAP #44, S10): un suo giro dura decine di minuti.
                guard let self else { return }
                // L'URL si estrae qui: la notifica non attraversa il salto sul MainActor, l'URL si'.
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor in
                    self.stopIndexingForVolumeChange()
                    self.stopInventoryForVolumeChange(volume)
                }
            }
        // NON qui in modo sincrono: `refreshIndexedFileCount` tocca `libraryIndexStore`, che
        // e' `lazy` — valutarla APRE il database SQLite, e con un WAL da recuperare quella
        // apertura e' I/O vero (misurato il 2026-09-03: 18 MB di database piu' 2 MB di WAL).
        // Farlo dentro `init` significa farlo sul main thread PRIMA che la finestra compaia:
        // l'app sembra "lavorare per partire". Rimandandolo di un giro di run loop la finestra
        // appare subito e il conteggio si riempie un istante dopo. La semantica della `lazy`
        // resta intatta: chi ha bisogno dello store lo ottiene comunque su richiesta.
        Task { @MainActor [weak self] in self?.refreshIndexedFileCount() }
    }

    deinit {
        if let unmountObserver { NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver) }
    }

    func refreshIndexedFileCount() {
        guard let store = libraryIndexStore else { indexedFileCount = 0; return }
        // `guard let self` e non `self?.`: una `var` weak riferita da una closure
        // concorrente e' un errore in Swift 6, e qui una referenza forte per la durata di
        // una query non cambia niente (il runner vive quanto l'app).
        //
        // `store.count()` gira DAVVERO fuori dal main thread dal 2026-09-19 (Task 3 del
        // fix di isolamento, BUG-7): prima di allora `LibraryIndexStore` non era annotato
        // `nonisolated`, quindi il default `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` lo
        // isolava e questa chiamata, pur dentro un `Task.detached`, saltava comunque sul
        // main actor a runtime (con un warning silenzioso). Il `Task.detached` sembrava
        // gia' corretto: non lo era.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let n = (try? store.count()) ?? 0
            await MainActor.run { self.indexedFileCount = n }
        }
    }

    /// Perche' `startLibraryIndexScan` non e' potuta partire. Le stesse tre cause che
    /// `rebuildLibraryIndex` mostrava direttamente prima del 2026-09-19 (passo 2 del
    /// backup): ora il motivo torna al chiamante invece di aprire un avviso, cosi' il
    /// passo 2 silenzioso puo' trasformarlo nell'esito del job invece che in una finestra.
    enum ListScanStartFailure {
        case storeUnavailable
        case ssdUnavailable
        case notVolumeRoot(path: String)
    }

    /// Fa **tutto** quello che serve per eseguire una lettura dell'elenco — apertura dello
    /// store, accesso all'SSD, controllo della radice del volume, avvio dello stesso
    /// `Task.detached` su `LibraryIndexer` di sempre — senza passare dal gate dei comandi
    /// manuali (`LibraryIndexCommandGate`) e senza mostrare avvisi. Due ingressi sopra
    /// questa unica funzione: `rebuildLibraryIndex` (manuale, con gate e avvisi) e il passo
    /// 2 del backup (`BackupRunner.startListStep`, senza gate perche' i pulsanti sono gia'
    /// disattivati, senza avvisi perche' un'operazione automatica non fa comparire finestre
    /// — l'esito finisce nel riepilogo del job).
    ///
    /// Restituisce **il motivo** se non e' partita (invece di mostrare un avviso); se e'
    /// partita, `onFinish` viene chiamato **sempre** alla fine (successo o errore) con il
    /// `Progress` finale e l'eventuale errore di `scan` — mai scartato con `_ =` come prima
    /// del 2026-09-19.
    private func startLibraryIndexScan(full: Bool,
                                       onFinish: @escaping @MainActor (LibraryIndexer.Progress?, Error?) -> Void) -> ListScanStartFailure? {
        // L'elenco e' una cache, mai un prerequisito (ADR-0002): se non si apre, si dice e
        // basta. Niente nell'app smette di funzionare.
        guard let store = libraryIndexStore else { return .storeUnavailable }
        guard let ssdURL = bm.startAccessing(.ssd) else { return .ssdUnavailable }
        // La root da leggere e' ESATTAMENTE quella che `runImport` passa come `libraryRoot`:
        // la radice del volume, non la sottocartella "Foto iPhone". I percorsi dell'elenco
        // sono relativi a questa; se le due divergessero ogni voce punterebbe a un file
        // inesistente e il riconoscimento dei doppioni smetterebbe di funzionare **senza
        // dire niente** (Task 6, Step 2-ter).
        guard isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            return .notVolumeRoot(path: ssdURL.path)
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
            // `let`, non `var`: due assegnazioni possibili (successo/errore), ciascuna una
            // sola volta lungo il percorso — evita la cattura di una `var` mutabile
            // attraverso il confine di attore del successivo `MainActor.run`.
            let finalProgress: LibraryIndexer.Progress?
            let finalError: Error?
            do {
                finalProgress = try idx.scan(root: ssdURL, ignoringStoredHashes: full) { p in
                    // `onProgress` arriva dal thread che sta leggendo, mai dal MainActor:
                    // l'aggiornamento della finestra va pubblicato esplicitamente.
                    Task { @MainActor in
                        self.indexProgress = p
                        self.indexedFileCount = p.total
                    }
                }
                finalError = nil
            } catch {
                // `scan` e' `throws`, ma un suo errore non deve poter far fallire niente
                // altro: torna al chiamante tramite `onFinish`, non mostrato qui (ADR-0002).
                finalProgress = nil
                finalError = error
            }
            // Sempre, anche dopo un errore: senza, "Interrompi" e i bottoni resterebbero
            // disabilitati fino alla chiusura dell'app.
            await MainActor.run {
                self.bm.stopAccessing(.ssd)
                self.isIndexing = false
                self.indexer = nil
                // Scritta in QUESTO punto solo (Task 12, D15): vale per ogni ingresso — il
                // bottone manuale e il passo 2 del backup passano entrambi da qui. Non si
                // scrive su una lettura interrotta o incompleta: non ha rimesso in pari
                // l'elenco, e registrarla direbbe il contrario.
                if LibraryListFreshness.readReachedTheEnd(progress: finalProgress, error: finalError) {
                    UserDefaults.standard.set(Date().timeIntervalSince1970,
                                              forKey: libraryListLastCompleteReadDefaultsKey)
                }
                onFinish(finalProgress, finalError)
            }
        }
        return nil
    }

    /// Costruisce o aggiorna l'elenco delle foto gia' presenti sull'SSD, da comando manuale
    /// (card di Diagnostica). `full: true` = si rilegge da capo ogni file, senza fidarsi di
    /// niente di memorizzato. `onAlert` = dove mostrare gli avvisi (vedi `AlertSink`): la
    /// card della finestra Diagnostica passa il proprio canale, l'aggiornamento automatico
    /// non passa niente. **Il comportamento non cambia di una virgola** dal 2026-09-19: gli
    /// stessi tre avvisi, con lo stesso testo, ora costruiti da `ListScanStartFailure`
    /// invece che inline.
    func rebuildLibraryIndex(full: Bool = false, onAlert: AlertSink? = nil) {
        // Precondizioni rivalutate **qui**, all'avvio vero, non solo sul bottone che ha
        // aperto il flusso. Rilievo di review del 2026-09-01: fra il click e la conferma sta
        // un alert che l'utente puo' lasciare aperto per minuti (il messaggio stesso parla di
        // 25-35 minuti di lettura — 390,6 GB a 224 MiB/s, ricalcolato Task 12 — quindi ci si
        // pensa), e in quel tempo puo' partire un
        // backup — a mano o da solo al ricollegamento dell'SSD. Il gate sul bottone da solo
        // riaprirebbe esattamente il difetto che questo commit dichiara chiuso. E' la stessa
        // lezione gia' pagata nel pannello Doppioni, dove le precondizioni del blocco erano
        // valutate una volta sola: qui non era stata applicata a se stessa.
        //
        // Silenzioso quando non c'e' un canale (`onAlert == nil`): oggi tutti i chiamanti da
        // Diagnostica ne passano uno, ma la firma resta difensiva — un futuro chiamante
        // automatico (come lo era, fino al 2026-09-19, il collegamento dell'SSD) non deve
        // far comparire niente.
        if let reason = LibraryIndexCommandGate.disabledReason(isIndexing: isIndexing,
                                                              jobIsRunning: isRunning,
                                                              isTrashingDuplicates: isTrashingDuplicates,
                                                              isRestoringFromTrash: isRestoringFromTrash,
                                                              isInventorying: isInventorying,
                                                              isRepairing: isRepairing) {
            onAlert?(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        let failure = startLibraryIndexScan(full: full) { [weak self] _, error in
            guard let self else { return }
            if let error {
                // `scan` e' `throws`, ma un suo errore non deve poter far fallire niente
                // altro: si mostra e si prosegue (ADR-0002).
                self.showIndexAlert(SimpleAlert(
                    title: "Il controllo si è fermato",
                    message: "\(error.localizedDescription)\n\nQuello che l'app aveva già letto resta salvato: puoi riprovare più tardi."), via: onAlert)
            }
        }
        guard let failure else { return }
        switch failure {
        case .storeUnavailable:
            showIndexAlert(SimpleAlert(
                title: "Elenco non disponibile",
                message: "Non è stato possibile aprire l'elenco delle foto già salvate.\n\nL'importazione funziona lo stesso: senza elenco l'app copia tutto, senza riconoscere le foto che hai già."), via: onAlert)
        case .ssdUnavailable:
            showIndexAlert(SimpleAlert(
                title: "Accesso all'SSD non disponibile",
                message: "Vai in Impostazioni e riseleziona l'SSD."), via: onAlert)
        case .notVolumeRoot(let path):
            showIndexAlert(SimpleAlert(
                title: "Bookmark SSD non valido",
                message: "Il percorso '\(path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD scegliendo '/Volumes/SSD - Enri' (root del volume, non una sottocartella)."), via: onAlert)
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
        // Stessa rivalutazione di `rebuildLibraryIndex`, con il motivo proprio dello
        // svuotamento: qui non si legge l'SSD, si toglie l'elenco a un'importazione che ci si
        // sta appoggiando per non ricopiare foto gia' presenti.
        if let reason = LibraryIndexCommandGate.resetDisabledReason(isIndexing: isIndexing,
                                                                   jobIsRunning: isRunning,
                                                                   isTrashingDuplicates: isTrashingDuplicates,
                                                                   isInventorying: isInventorying) {
            onAlert?(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let store = libraryIndexStore else { return }
        do {
            try store.deleteIndexAndRecreate()
            indexProgress = nil
            indexInterruptedByUser = false
            indexedFileCount = 0
            // Lo stesso file conteneva l'inventario (S8): la finestra lo rilegge, e ora dira'
            // «mai fatto».
            inventorySummary = nil
            // L'elenco appena svuotato non e' "aggiornato ad oggi": e' vuoto, e la
            // prossima lettura (manuale, la ricostruzione non parte da sola) e' la prima
            // vera dopo lo svuotamento (Task 12, D15).
            UserDefaults.standard.removeObject(forKey: libraryListLastCompleteReadDefaultsKey)
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

    // MARK: Inventario certificato (ROADMAP #44, ADR-0015)

    /// Vero mentre l'inventario legge SSD, HDD e Cubbit. Vive QUI e non in uno `@State` di
    /// `InventoryView`, per la stessa ragione di `isTrashingDuplicates`: chiudere e riaprire la
    /// finestra non deve far perdere ne' la mutua esclusione con job, letture, spostamenti e
    /// annullamenti, ne' la barra e «Interrompi» (regola D3 di ROADMAP #41).
    @Published private(set) var isInventorying = false
    @Published private(set) var inventoryProgress: InventoryProgress? = nil
    @Published private(set) var inventoryStopRequested = false
    /// L'ultimo confronto calcolato. `nil` = non ancora letto in questa sessione, o elenco
    /// appena svuotato: la finestra lo chiede con `loadInventoryIfNeeded()`.
    @Published private(set) var inventorySummary: InventorySummary? = nil
    @Published private(set) var isLoadingInventory = false
    private var inventoryCancelFlag: CancelFlag? = nil

    /// «Aggiorna l'inventario». Le precondizioni si rivalutano QUI, all'avvio vero (stessa
    /// disciplina di `rebuildLibraryIndex`), e `isInventorying` si alza PRIMA della domanda a
    /// Cubbit: da quel momento nessun backup, lettura, spostamento o annullamento puo' partire.
    func startInventoryRefresh(onAlert: @escaping AlertSink) {
        if let reason = InventoryStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let store = libraryIndexStore, let config = s3Config else {
            onAlert(SimpleAlert(title: "Inventario non disponibile",
                                message: "Non è stato possibile aprire sul Mac l'elenco in cui l'inventario viene salvato."))
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd), isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            onAlert(SimpleAlert(title: "SSD non valido",
                                message: "Vai in Impostazioni e riseleziona l'SSD scegliendo '/Volumes/SSD - Enri' (la radice del disco, non una cartella)."))
            return
        }
        guard let hddURL = bm.startAccessing(.hdd), isLikelyVolumeRoot(hddURL) else {
            bm.stopAccessing(.ssd)
            bm.stopAccessing(.hdd)
            onAlert(SimpleAlert(title: "HDD non valido",
                                message: "Vai in Impostazioni e riseleziona l'HDD scegliendo '/Volumes/BackupHDD' (la radice del disco, non una cartella)."))
            return
        }
        let flag = CancelFlag()
        isInventorying = true
        inventoryStopRequested = false
        inventoryCancelFlag = flag
        inventoryProgress = .checkingCubbit
        // Un `S3Syncer` DEDICATO, come il ricalcolo dello spazio di Cubbit: `s3Syncer` del
        // runner condivide il proprio flag di interruzione con i job.
        let syncer = S3Syncer()
        Task { @MainActor in
            let reachable = await syncer.checkReachable(config: config)
            guard reachable, !flag.isCancelled else {
                self.finishInventoryRefresh(summary: nil)
                if !reachable {
                    onAlert(SimpleAlert(title: "Cubbit non risponde", message: InventoryStartGate.cubbitUnreachable))
                }
                return
            }
            let runId = Int64(Date().timeIntervalSince1970 * 1000)
            Task.detached(priority: .utility) {
                let outcome = await InventoryRefresh.run(
                    store: store, ssdRoot: ssdURL, hddRoot: hddURL, runId: runId, cancelFlag: flag,
                    fetchPage: { token in try await syncer.fetchListPageXML(config: config, token: token) },
                    onProgress: { p in Task { @MainActor in self.inventoryProgress = p } })
                await MainActor.run {
                    self.finishInventoryRefresh(summary: outcome.summary)
                    if outcome.summary == nil {
                        onAlert(SimpleAlert(title: "L'inventario si è fermato",
                                            message: "Non è stato possibile salvare o rileggere l'inventario sul Mac. "
                                                + "Le foto non sono state toccate: puoi riprovare più tardi."))
                    }
                }
            }
        }
    }

    /// L'UNICO punto in cui un aggiornamento finisce, su ogni percorso: accessi chiusi, flag
    /// giu', esito pubblicato. Un esito `nil` lascia quello di prima (piu' vecchio, mai sbagliato).
    private func finishInventoryRefresh(summary: InventorySummary?) {
        bm.stopAccessing(.ssd)
        bm.stopAccessing(.hdd)
        isInventorying = false
        inventoryCancelFlag = nil
        inventoryProgress = nil
        inventoryStopRequested = false
        if let summary { inventorySummary = summary }
    }

    /// «Interrompi» (idempotente). Lo scanner si ferma fra un blocco da 1 MiB e l'altro, il
    /// lettore di Cubbit fra una pagina e l'altra: quello che e' stato letto resta salvato.
    func stopInventoryRefresh() {
        guard isInventorying, !inventoryStopRequested else { return }
        inventoryStopRequested = true
        inventoryCancelFlag?.cancel()
    }

    /// Un volume si sta smontando: l'inventario si ferma solo se e' l'SSD o l'HDD (S10), senza
    /// segnarlo come «fermato da te».
    private func stopInventoryForVolumeChange(_ volume: URL?) {
        guard isInventorying,
              InventoryStartGate.volumeChangeStopsInventory(unmounting: volume, ssdRoot: bm.urls[.ssd],
                                                            hddRoot: bm.urls[.hdd]) else { return }
        inventoryCancelFlag?.cancel()
    }

    /// Legge l'ultimo inventario salvato e ne calcola il confronto, fuori dal main. Chiamata
    /// all'apertura della finestra; non fa niente se c'e' gia' un risultato o se un
    /// aggiornamento e' in corso (arrivera' da quello).
    func loadInventoryIfNeeded() {
        guard inventorySummary == nil, !isLoadingInventory, !isInventorying,
              let store = libraryIndexStore else { return }
        isLoadingInventory = true
        Task.detached(priority: .userInitiated) {
            let snapshot = (try? store.inventorySnapshot()) ?? InventorySnapshot()
            let summary = InventorySummary(snapshot, sampleLimit: InventorySummary.defaultSampleLimit)
            await MainActor.run {
                self.isLoadingInventory = false
                self.inventorySummary = summary
            }
        }
    }

    // MARK: Riparazione con la regola «2 su 3» (ROADMAP #45, ADR-0016)

    /// Il registro delle riparazioni, sul disco interno come gli altri file dell'app (BUG-10:
    /// sotto test in una cartella temporanea). Lazy e `try?`: senza registro la riparazione non
    /// parte, ma niente altro ne dipende.
    private(set) lazy var repairLogStore: RepairLogStore? = {
        try? RepairLogStore(url: backupRunnerStoreRoot().appendingPathComponent("repair-log.json"))
    }()
    /// Il passo in corso, per la riga sotto la voce. `nil` mentre si controlla che Cubbit risponda.
    @Published private(set) var repairStep: RepairStep? = nil
    /// La voce in riparazione (`RepairCandidate.key`).
    @Published private(set) var repairingKey: String? = nil
    @Published private(set) var lastRepairOutcome: RepairOutcome? = nil
    /// Le voci del registro, lette fuori dal main: la finestra ci trova «riparata il …».
    @Published private(set) var repairRecords: [RepairRecord] = []

    /// Rilegge il registro fuori dal main e pubblica solo se e' cambiato.
    func refreshRepairRecords() {
        guard let log = repairLogStore else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let records = log.records()
            await MainActor.run {
                guard self.repairRecords != records else { return }
                self.repairRecords = records
            }
        }
    }

    /// «Ripara» confermato, o «Controlla senza riparare» (`dryRun`, S11: stesso ricontrollo,
    /// nessuna scrittura). Le precondizioni si rivalutano QUI, all'avvio vero (fra «Ripara…» e
    /// la conferma l'utente puo' aver lasciato aperto il riepilogo per minuti), poi
    /// `isRepairing` si alza PRIMA della domanda a Cubbit. `onAlert` e' il canale della finestra
    /// Inventario (regola `AlertSink`).
    func startRepair(_ candidate: RepairCandidate, dryRun: Bool, onAlert: @escaping AlertSink) {
        if let reason = RepairStartGate.blockedReason(
            isRunning: isRunning, isIndexing: isIndexing, isTrashingDuplicates: isTrashingDuplicates,
            isRestoringFromTrash: isRestoringFromTrash, isInventorying: isInventorying, isRepairing: isRepairing,
            ssdMounted: VolumeMonitor.shared.ssdMounted, hddMounted: VolumeMonitor.shared.hddMounted,
            hasCubbitConfig: s3Config != nil) {
            onAlert(SimpleAlert(title: "Meglio non farlo adesso", message: reason))
            return
        }
        guard let log = repairLogStore, let config = s3Config else {
            onAlert(SimpleAlert(title: "Riparazione non disponibile",
                                message: "Non è stato possibile aprire sul Mac il registro delle riparazioni."))
            return
        }
        guard let ssdURL = bm.startAccessing(.ssd), isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            onAlert(SimpleAlert(title: "SSD non valido",
                                message: "Vai in Impostazioni e riseleziona l'SSD scegliendo '/Volumes/SSD - Enri' (la radice del disco, non una cartella)."))
            return
        }
        guard let hddURL = bm.startAccessing(.hdd), isLikelyVolumeRoot(hddURL) else {
            bm.stopAccessing(.ssd)
            bm.stopAccessing(.hdd)
            onAlert(SimpleAlert(title: "HDD non valido",
                                message: "Vai in Impostazioni e riseleziona l'HDD scegliendo '/Volumes/BackupHDD' (la radice del disco, non una cartella)."))
            return
        }
        if let alert = beginRepair() {
            bm.stopAccessing(.ssd)
            bm.stopAccessing(.hdd)
            onAlert(alert)
            return
        }
        repairingKey = candidate.key
        repairStep = nil
        lastRepairOutcome = nil
        let syncer = S3Syncer()
        Task { @MainActor in
            guard await syncer.checkReachable(config: config) else {
                self.finishRepair(nil)
                onAlert(SimpleAlert(title: "Cubbit non risponde", message: RepairStartGate.cubbitUnreachable))
                return
            }
            let cloud = S3RepairCloud(syncer: syncer, config: config)
            Task.detached(priority: .userInitiated) {
                let engine = RepairEngine(ssdRoot: ssdURL, hddRoot: hddURL, cloud: cloud,
                                          record: { try log.record($0) })
                let outcome = await engine.run(candidate, dryRun: dryRun, onStep: { step in
                    Task { @MainActor in if self.isRepairing { self.repairStep = step } }
                })
                await MainActor.run { self.finishRepair(outcome) }
            }
        }
    }

    /// L'UNICO punto in cui una riparazione finisce, su ogni percorso: accessi chiusi, flag giu',
    /// esito pubblicato, registro riletto.
    private func finishRepair(_ outcome: RepairOutcome?) {
        bm.stopAccessing(.ssd)
        bm.stopAccessing(.hdd)
        endRepair()
        repairStep = nil
        repairingKey = nil
        if let outcome { lastRepairOutcome = outcome }
        refreshRepairRecords()
    }

    // `autoRefreshLibraryIndexIfEnabled()` e `LibraryIndexAutoRefresh.shouldRun` sono stati
    // rimossi il 2026-09-19 (decisione di Enrico, domanda aperta 1 della spec del passo 2 del
    // backup): al collegamento dell'SSD non parte piu' nessuna lettura da sola. L'elenco si
    // aggiorna solo come ultimo passo di un backup/importazione (`BackupListStep.shouldRun`,
    // chiamato da `finishCopyStep`) o a mano da Diagnostica (`rebuildLibraryIndex`).

    private let maxOut = 60_000
    private let maxSpeedSamples = 120
    private let lastDeepKey = "lastDeepMirrorDate"
    private var lastSpeedSampleDate: Date = .distantPast
    private var smoothedEtaSec: Double = 0
    private var elapsedTimer: AnyCancellable?

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
            // Fuori dal main (ROADMAP #39): `VolumeCapacityReader.read` gira gia' su una
            // coda di background, `hasSufficientSpace` invece leggeva `resourceValues`
            // direttamente dentro questo `Task { @MainActor }`.
            let ssdPath = ssdURL.path
            let reading = await Task.detached(priority: .userInitiated) {
                VolumeCapacityReader.read(path: ssdPath)
            }.value
            switch FreeSpaceCheck.verdict(bytesNeeded: preview.toAddBytes, reading: reading) {
            case .enough:
                break
            case .notEnough(let available):
                self.bm.stopAccessing(.photos); self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'SSD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) su \(ssdURL.path).")
                return
            case .notADisk:
                self.bm.stopAccessing(.photos); self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(title: "SSD non disponibile",
                    message: FreeSpaceCheck.notADiskMessage(diskName: "SSD"))
                return
            case .unreadable:
                self.bm.stopAccessing(.photos); self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(title: "Spazio libero non disponibile",
                    message: FreeSpaceCheck.unreadableMessage(diskName: "SSD"))
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
            let hddPath = hddURL.path
            let reading = await Task.detached(priority: .userInitiated) {
                VolumeCapacityReader.read(path: hddPath)
            }.value
            switch FreeSpaceCheck.verdict(bytesNeeded: preview.toAddBytes, reading: reading) {
            case .enough:
                break
            case .notEnough(let available):
                self.bm.stopAccessing(.ssd); self.bm.stopAccessing(.hdd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'HDD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) su \(hddURL.path).")
                return
            case .notADisk:
                self.bm.stopAccessing(.ssd); self.bm.stopAccessing(.hdd)
                pendingAlert = SimpleAlert(title: "HDD non disponibile",
                    message: FreeSpaceCheck.notADiskMessage(diskName: "HDD"))
                return
            case .unreadable:
                self.bm.stopAccessing(.ssd); self.bm.stopAccessing(.hdd)
                pendingAlert = SimpleAlert(title: "Spazio libero non disponibile",
                    message: FreeSpaceCheck.unreadableMessage(diskName: "HDD"))
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
    /// - Parameter onSourceHash: notifica l'hash del file sorgente **appena calcolato**,
    ///   chiamata SOLO quando lo Stadio 2 e' stato davvero raggiunto (mai con un valore
    ///   inventato, mai per un file scartato allo Stadio 1 o per un `.notIndexable`).
    ///   Serve alla sola anteprima dell'import (roadmap #27-A/#31, terza parte, Task 2):
    ///   senza ricalcolare l'hash una seconda volta, permette al chiamante di registrare
    ///   nella propria `ImportSessionIndex` un candidato appena hashato e risultato
    ///   NON doppione, cosi' un suo gemello piu' avanti nella sorgente lo riconosce.
    ///   Default no-op: `runImport` non lo passa e si comporta identico a prima.
    nonisolated static func isAlreadyInLibrary(url: URL,
                                              store: LibraryIndexStore?,
                                              session: ImportSessionIndex,
                                              libraryRoot: URL?,
                                              onSourceHash: (String) -> Void = { _ in }) -> Bool {
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
        onSourceHash(sourceHash)

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

    /// Il motore dell'anteprima vera del wizard di import (roadmap #27-A / #31, terza
    /// parte, Task 2): decide quali `FileSyncer.PreviewCandidate` l'import salterebbe
    /// davvero, PRIMA di avviare il job.
    ///
    /// PRINCIPIO GUIDA (spec, "L'anteprima non e' un'approssimazione dell'import, e' lo
    /// stesso predicato"): questa funzione riusa **la stessa** `isAlreadyInLibrary` che
    /// `runImport` cabla su `FileSyncer.isDuplicate`. Nessuna logica di dedup parallela,
    /// nessuna seconda soglia di fiducia da tenere allineata a mano.
    ///
    /// LIVELLO DI FIDUCIA 2, non 1 (ADR-0003; spec, sezione "A quale livello di fiducia
    /// si colloca questa lettura"). La tentazione sarebbe fidarsi dell'indice senza
    /// rileggere l'SSD: l'anteprima e' "a basso danno" (un numero sbagliato, non una
    /// foto persa), e risparmierebbe tutte le letture lato libreria. Non regge: l'indice
    /// contiene per DECISIONE DI PRODOTTO delle entry fantasma (file rimossi dal disco
    /// la cui riga resta — "traversata incompleta => nessuna rimozione", 2026-08-26).
    /// Con la fiducia di livello 1 ognuna di quelle entry farebbe dichiarare un doppione
    /// che l'import non riconoscera' mai: l'anteprima SOTTO-prometterebbe, l'errore
    /// opposto a quello che questo lavoro corregge. `isAlreadyInLibrary` rilegge e
    /// rihasha invece il candidato sull'SSD (livello 2), esattamente come fa l'import:
    /// stesso codice, stesso esito, nessuna seconda copia della decisione che potrebbe
    /// divergere. Non rimuovere la rilettura per "ottimizzare".
    ///
    /// NESSUNA QUERY NUOVA SULLO STORE. Il prefiltro usa solo `hasAnyEntry(withSize:)`,
    /// gia' esistente — misurato (2026-09-01): 2.000 chiamate = 9,3 ms totali, contro
    /// 9,1 ms di una singola `SELECT DISTINCT size` che le sostituirebbe. Non c'e' nulla
    /// da guadagnare introducendo un metodo nuovo sullo store (es. `allSizes()`), e c'e'
    /// da perdere: un `Set` con semantica di istantanea da mantenere, e soprattutto una
    /// seconda copia della decisione di dedup — la classe di errore che questo progetto
    /// ha gia' pagato tre volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).
    ///
    /// - Parameter candidates: TUTTI i candidati della sorgente, non solo quelli che
    ///   supereranno il prefiltro: serve il lotto intero per costruire l'istogramma
    ///   delle dimensioni e riconoscere i doppioni INTERNI alla stessa sorgente, che
    ///   l'indice persistito non puo' ancora conoscere (misurato: 2,7% dei file su un
    ///   rullino iPhone, 36,0% su una cartella tipo "Foto Google Drive" — vanno
    ///   riconosciuti, non dichiarati come limite).
    /// - Parameter isCancelled: controllata a ogni iterazione, PRIMA di leggere un solo
    ///   byte del candidato di turno — e' cosi' che "Interrompi" ferma davvero la
    ///   lettura, non solo l'aggiornamento della barra.
    /// - Parameter onProgress: `total` e' noto PRIMA che venga letto un solo byte (un
    ///   primo giro guarda solo la dimensione), e conta SOLO i candidati che superano il
    ///   prefiltro — e' il denominatore onesto della barra determinata del wizard.
    /// - Returns: gli indici, in `candidates`, dei file che l'import salterebbe. Se
    ///   `isCancelled` diventa vero a meta', l'insieme restituito e' PARZIALE: il
    ///   chiamante che ha interrotto deve SCARTARLO, mai mostrarlo (spec: "Interrompi...
    ///   non un numero parziale con un asterisco").
    nonisolated static func importPreviewDuplicates(
        candidates: [FileSyncer.PreviewCandidate],
        store: LibraryIndexStore?,
        libraryRoot: URL?,
        isCancelled: () -> Bool,
        onProgress: (_ done: Int, _ total: Int) -> Void
    ) -> Set<Int> {
        // Istogramma delle dimensioni della sorgente — solo memoria, nessun I/O. E' il
        // solo modo di riconoscere un doppione INTERNO prima di aver hashato il primo
        // dei due: senza sapere in anticipo che esiste un secondo file di quella
        // dimensione, il primo del paio non verrebbe mai selezionato per l'hash e il
        // paio non sarebbe mai riconosciuto (vedi doc-comment su
        // `FileSyncer.duplicateFilter`, stesso argomento).
        var sizeCounts: [Int64: Int] = [:]
        for c in candidates { sizeCounts[c.size, default: 0] += 1 }
        let sourceRepeatedSizes = Set(sizeCounts.filter { $0.value >= 2 }.map { $0.key })

        // Sessione LOCALE a questa chiamata — mai condivisa con un job. Registra gli URL
        // della SORGENTE (non della destinazione: la copia non e' ancora avvenuta) dei
        // candidati gia' hashati e risultati NON doppioni, cosi' un loro gemello piu'
        // avanti nella stessa sorgente li trova senza bisogno di rihasharli.
        let previewSession = ImportSessionIndex()

        // Un candidato merita la lettura (Stadio 2) se la sua dimensione e' condivisa
        // da un altro candidato della sorgente, OPPURE se lo store la conosce gia'.
        // Ripete qui il solo Stadio 1 di `isAlreadyInLibrary` (dimensione, gratis) senza
        // duplicarne la DECISIONE: la decisione — hash e confronto — resta sempre e solo
        // dentro `isAlreadyInLibrary`, chiamata sotto.
        func passesPrefilter(_ size: Int64) -> Bool {
            if sourceRepeatedSizes.contains(size) { return true }
            guard let store else { return false }
            return (try? store.hasAnyEntry(withSize: size)) ?? false
        }

        // `total` calcolato in un primo giro che guarda SOLO la dimensione — noto prima
        // di leggere un solo byte, e' il denominatore che la barra determinata del
        // wizard mostra.
        let total = candidates.reduce(into: 0) { count, c in
            if passesPrefilter(c.size) { count += 1 }
        }
        onProgress(0, total)

        var result: Set<Int> = []
        var done = 0
        for (index, candidate) in candidates.enumerated() {
            // Controllata ad OGNI iterazione, anche per i candidati che il prefiltro
            // scarterebbe subito dopo: e' cosi' che l'interruzione ferma davvero la
            // lettura, non solo l'avanzamento della barra.
            if isCancelled() { break }

            guard passesPrefilter(candidate.size) else { continue }

            var sourceHash: String?
            let isDuplicate = isAlreadyInLibrary(url: candidate.url,
                                                 store: store,
                                                 session: previewSession,
                                                 libraryRoot: libraryRoot,
                                                 onSourceHash: { sourceHash = $0 })
            if isDuplicate {
                result.insert(index)
            } else if let sourceHash {
                // `isAlreadyInLibrary` ha raggiunto lo Stadio 2 (di solito perche' lo
                // store conosceva gia' questa dimensione) ma il file non e' un
                // doppione: si registra comunque il suo hash, cosi' un gemello INTERNO
                // successivo lo trova tramite la stessa `isAlreadyInLibrary`.
                previewSession.record(hash: sourceHash, at: candidate.url)
            } else if sourceRepeatedSizes.contains(candidate.size),
                      IndexableKind.of(url: candidate.url) != .notIndexable,
                      let hash = sha256(of: candidate.url) {
                // `isAlreadyInLibrary` e' uscita al proprio Stadio 1 (ne' lo store ne'
                // — finora — questa sessione conoscevano questa dimensione): da sola
                // non avrebbe MAI hashato il primo file di un paio tutto interno alla
                // sorgente, e il paio non sarebbe mai stato riconosciuto (ne' un
                // candidato ne' l'altro, mai). Si hasha qui — riusando la STESSA
                // `sha256` di livello 2, non una versione piu' leggera — solo per
                // seminare la sessione: la DECISIONE su un futuro gemello resta
                // comunque dentro `isAlreadyInLibrary`, alla chiamata successiva. La
                // guardia `IndexableKind` e' la stessa ragione di ADR-0003 nota
                // 2026-08-26: senza, un sidecar non indicizzabile potrebbe "insegnare"
                // il proprio hash a un file indicizzabile byte-identico per puro caso.
                previewSession.record(hash: hash, at: candidate.url)
            }

            done += 1
            onProgress(done, total)
        }
        return result
    }

    func runImport(source: URL, label: String) {
        // Rivalutata qui, non solo sul bottone del wizard: fra la scelta dell'etichetta e
        // questo avvio vero possono passare minuti in cui un altro job e' partito (vedi
        // `importStartDisabledReason`). Senza questo controllo il `guard !isRunning` di
        // `run(label:...)` più sotto farebbe fallire l'import in silenzio, con lo sheet
        // già chiuso e nessun messaggio per l'utente.
        if let reason = importStartDisabledReason(jobIsRunning: isRunning) {
            alert("Import non avviato", reason)
            return
        }
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
            // Questo `previewSync` NON passa `duplicateFilter` di proposito (spec, "Cosa NON
            // cambia": il controllo di spazio resta senza dedup). Vuole un LIMITE SUPERIORE —
            // sovrastimare rifiuta un import che sarebbe entrato, sottostimare riempie il
            // disco — e renderlo esatto costerebbe una TERZA lettura completa della sorgente
            // (dopo quella dell'anteprima del wizard e quella dell'import vero) per rendere
            // *meno* conservativa una guardia di sicurezza: non è mai stata la direzione
            // giusta per una guardia. Da qui in avanti `preview.toAddBytes` può quindi essere
            // più alto del numero già mostrato al wizard (che invece dedup lo applica), e
            // l'alert sotto lo dice esplicitamente ("al massimo") per non contraddire quanto
            // l'utente ha appena letto un passo prima.
            let preview = await self.syncer.previewSync(from: source, to: dst, deep: false)
            let ssdPath = ssdURL.path
            let reading = await Task.detached(priority: .userInitiated) {
                VolumeCapacityReader.read(path: ssdPath)
            }.value
            switch FreeSpaceCheck.verdict(bytesNeeded: preview.toAddBytes, reading: reading) {
            case .enough:
                break
            case .notEnough(let available):
                self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'SSD",
                    message: "Servono al massimo circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) su \(ssdURL.path).")
                return
            case .notADisk:
                self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(title: "SSD non disponibile",
                    message: FreeSpaceCheck.notADiskMessage(diskName: "SSD"))
                return
            case .unreadable:
                self.bm.stopAccessing(.ssd)
                pendingAlert = SimpleAlert(title: "Spazio libero non disponibile",
                    message: FreeSpaceCheck.unreadableMessage(diskName: "SSD"))
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

    /// Durante il passo 2 (`listStepState == .running`) "Interrompi" NON fa quello che fa
    /// durante la copia: il job non risulta "interrotto" (D3 della spec) — le foto sono gia'
    /// copiate e verificate, il `JobSummary` e' gia' salvato come riuscito. Ferma solo la
    /// lettura (`cancelIndexing()`) e aspetta che `scan` se ne accorga; il pulsante resta
    /// visibile ma disattivato ("Mi fermo…") finche' non arriva `finishJob`. Un secondo click
    /// mentre si sta gia' fermando non fa niente (`listStopRequested` gia' vero).
    func stop() {
        if case .running = listStepState {
            guard !listStopRequested else { return }
            listStopRequested = true
            cancelIndexing()
            return
        }
        wasStopped = true
        let jobLabel = phase.label   // etichetta del job in corso, catturata prima di sovrascrivere phase
        elapsedTimer?.cancel(); elapsedTimer = nil
        syncer.cancel()
        s3Syncer.cancel()
        syncTask?.cancel(); syncTask = nil
        listStepState = nil   // un job interrotto durante la copia non deve lasciare "passo 1 di 2" sull'intestazione
        phase = .failed("Interrotto dall'utente")
        completionSnapshot = (phase, stats)
        JobHistoryStore.save(JobSummary(date: Date(), label: jobLabel, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors, hashErrors: stats.hashErrors,
            succeeded: false, changedSkipped: stats.changedSkipped,
            duplicatesSkipped: stats.duplicatesSkipped))
    }

    /// La copia (passo 1) e' finita con successo. Aggiorna `stats` dal `SyncResult` e salva
    /// subito il `JobSummary` — esattamente come faceva `run` prima del 2026-09-19, stesso
    /// ordine: il registro dell'ultimo backup racconta le foto, che a questo punto sono
    /// copiate e verificate, indipendentemente da come andra' il passo 2. Poi decide se c'e'
    /// un passo 2 da fare (`BackupListStep.shouldRun`) e lo avvia, altrimenti il job finisce
    /// qui.
    private func finishCopyStep(result: FileSyncer.SyncResult?, label: String, refreshesLibraryIndex: Bool) {
        guard !wasStopped else { return }
        if let r = result {
            stats.copied = r.copied; stats.skipped = r.skipped
            stats.errors = r.errors; stats.done = r.done
            stats.total = r.total; stats.percent = 100
            stats.elapsed = FileSyncer.SyncResult.hms(r.elapsedSec)
            stats.hashErrors = r.hashErrors          // mismatch SHA256
            stats.verifiedOk = r.copied              // tutti i copied sono verified ok
            stats.copiedUnverified = r.copiedUnverified  // copiati ma non verificabili: fuori da copied/verifiedOk
            stats.changedSkipped = r.changedSkipped  // file cambiati, non copiati (roadmap #13)
            stats.duplicatesSkipped = r.duplicatesSkipped  // gia' in libreria, non copiati (roadmap #31)
        }
        JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: stats.copied,
            skipped: stats.skipped, errors: stats.errors,
            hashErrors: stats.hashErrors, succeeded: true,
            changedSkipped: stats.changedSkipped,
            duplicatesSkipped: stats.duplicatesSkipped))

        if BackupListStep.shouldRun(refreshesLibraryIndex: refreshesLibraryIndex,
                                    enabled: LibraryIndexAutoRefresh.isEnabled(),
                                    indexedFileCount: indexedFileCount,
                                    isIndexing: isIndexing,
                                    isTrashingDuplicates: isTrashingDuplicates) {
            startListStep(label: label)
        } else {
            finishJob(label: label, listOutcome: nil)
        }
    }

    /// Avvia il passo 2: la stessa lettura di sempre, silenziosa (nessun avviso in nessun
    /// ramo — D4/D6: qualunque cosa vada storta diventa l'esito del passo, scritto nel
    /// riepilogo finale, non una finestra a comparsa). `stats.percent` resta 100 (la copia e'
    /// finita): durante il passo 2 tutti leggono `displayPercent`, non `stats.percent`.
    private func startListStep(label: String) {
        stats.percent = 100
        listStepState = .running(estimate: BackupListStep.estimate(indexedBefore: indexedFileCount,
                                                                    copied: stats.copied,
                                                                    copiedUnverified: stats.copiedUnverified))
        append("STATUS: \(BackupListStep.runningLine)\n")
        let failure = startLibraryIndexScan(full: false) { [weak self] progress, error in
            guard let self else { return }
            let outcome = BackupListStep.outcome(progress: progress,
                                                 interruptedByUser: self.indexInterruptedByUser,
                                                 couldNotStart: false, scanFailed: error != nil)
            self.finishJob(label: label, listOutcome: outcome)
        }
        // Non dovrebbe quasi mai succedere (shouldRun ha gia' verificato indexedFileCount >
        // 0 e nessuna lettura/trashing in corso), ma se lo store non si apre o l'SSD sparisce
        // proprio in questo istante, il job finisce comunque: mai bloccato in "passo 2".
        if failure != nil {
            finishJob(label: label, listOutcome: .couldNotUpdate)
        }
    }

    /// L'UNICO punto in cui il job finisce davvero, con o senza passo 2. `listOutcome == nil`
    /// = nessun passo 2 per questo job: fine identica a prima del 2026-09-19. Non salva un
    /// `JobSummary`: e' gia' stato salvato da `finishCopyStep` alla fine del passo 1.
    private func finishJob(label: String, listOutcome: BackupListStep.Outcome?) {
        elapsedTimer?.cancel(); elapsedTimer = nil
        stats.elapsed = makeElapsed()
        stats.listStepOutcome = listOutcome
        listStepState = nil
        listStopRequested = false
        phase = .success("Completato: \(label)")
        Notifier.send(phase.label, BackupListStep.notificationBody(stats: stats, outcome: listOutcome))
        if let listOutcome {
            append("STATUS: \(BackupListStep.completionLine(listOutcome).text)\n")
        }
        completionSnapshot = (phase, stats)
    }

    /// - Parameter refreshesLibraryIndex: il job **scrive** sull'SSD (Mac -> SSD, Importa),
    ///   quindi a fine passo 1 l'elenco delle foto gia' salvate non e' piu' in pari — se le
    ///   condizioni lo permettono (`BackupListStep.shouldRun`), il passo 2 lo aggiorna prima
    ///   che il job finisca (`finishCopyStep`). Falso per SSD -> HDD e SSD -> Cubbit, che
    ///   sull'SSD leggono soltanto: un passo 2 dopo ognuno di quei job costerebbe minuti per
    ///   non trovare niente di nuovo.
    private func run(label: String, refreshesLibraryIndex: Bool = false,
                     work: @escaping () async throws -> FileSyncer.SyncResult?) {
        guard !isRunning else { return }
        if let reason = JobStartGate.blockedReason(isIndexing: isIndexing,
                                                    isTrashingDuplicates: isTrashingDuplicates,
                                                    isRestoringFromTrash: isRestoringFromTrash,
                                                    isInventorying: isInventorying,
                                                    isRepairing: isRepairing) {
            pendingAlert = SimpleAlert(title: "Meglio non farlo adesso", message: reason)
            return
        }
        output = ""; stats = JobStats(); currentStatus = ""; currentThumbnail = nil
        wasStopped = false
        let now = Date()
        completionSnapshot = nil; startTime = now
        speedHistory = [SpeedSample(time: now.addingTimeInterval(-2.0), value: 0),
                        SpeedSample(time: now, value: 0)]
        lastSpeedSampleDate = now.addingTimeInterval(-2.1)
        smoothedEtaSec = 0
        // Calcolato subito, con le condizioni di ORA: se previsto, l'intestazione dice
        // "passo 1 di 2" gia' durante la copia, cosi' il passo 2 non compare a sorpresa
        // quando la barra e' gia' al 100% (D2 della spec). Ricalcolato in `finishCopyStep`
        // con le condizioni di quel momento: possono cambiare (interruttore spento a meta'),
        // e in quel caso raro il job finisce dopo il passo 1 anche se l'intestazione diceva
        // "di 2".
        listStepState = BackupListStep.shouldRun(refreshesLibraryIndex: refreshesLibraryIndex,
                                                 enabled: LibraryIndexAutoRefresh.isEnabled(),
                                                 indexedFileCount: indexedFileCount,
                                                 isIndexing: isIndexing,
                                                 isTrashingDuplicates: isTrashingDuplicates) ? .planned : nil
        listStopRequested = false
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
                await MainActor.run { [weak self] in
                    self?.finishCopyStep(result: result, label: label, refreshesLibraryIndex: refreshesLibraryIndex)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.listStepState = nil   // un job fallito non deve lasciare "passo 1 di 2" sull'intestazione
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
                await MainActor.run { [weak self] in
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
// `nonisolated`: value type senza stato condiviso — vedi il commento su `UnverifiedCopiesStore`,
// che decodifica/codifica questo tipo fuori dal main dal 2026-09-20 (ROADMAP #33).
nonisolated struct UnverifiedCopies: Codable, Equatable {
    /// Una copia da ricontrollare: il percorso piu' l'istante in cui il debito e' stato
    /// contratto. La data serve solo alla scadenza (`UnverifiedCopiesStore.expiryDays`).
    nonisolated struct Entry: Codable, Equatable {
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

nonisolated extension UnverifiedCopies {
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

// `nonisolated` (2026-09-20, ROADMAP #33): `record` e' gia' chiamato dalla coda di lavoro di
// `FileSyncer`, fuori dal MainActor — il commento su `record` lo dice da sempre. `load`/
// `clear` sono ora chiamati anche da `integritySampleLocalPair`, fuori dal main (Task.detached
// da `ReviewEngine.runIntegritySample`). Thread-safe per costruzione: `record`/`clear` sono
// dietro il proprio `NSLock` (leggi-modifica-scrivi), `load`/`save` toccano solo `UserDefaults`
// (thread-safe di suo). Nessuno stato mutabile fuori da quello protetto dal lock.
nonisolated enum UnverifiedCopiesStore {
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

// `nonisolated` (2026-09-20, ROADMAP #33): value type senza stato condiviso, costruito e
// restituito da `integritySampleLocalPair`, fuori dal main.
nonisolated struct IntegrityCheckResult: Identifiable {
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

/// Il campione d'integrita' Mac<->SSD / SSD<->HDD, fuori dal main (2026-09-20, ROADMAP #33).
///
/// Misurato con Enrico il 2026-09-19 (`sample`, ~80s, 20 file Mac<->SSD): i frame di
/// `sampleLocalPair`/`sha256` erano presenti sul main in ogni istantanea, ma solo ~0,4-1,3%
/// del tempo, perche' i file del campione erano piccoli. Il rischio vero e' un file grande:
/// sull'SSD ci sono zip da 40-50 GB (cartella `Zip/`), e quella lettura bloccherebbe l'app per
/// minuti se restasse sul MainActor. `ReviewEngine` resta `@MainActor` (default del target);
/// solo questa funzione — enumerazione + SHA256, il lavoro pesante — e' `nonisolated`, chiamata
/// da `runIntegritySample` tramite `Task.detached`. Nessun cambio al criterio di
/// campionamento, alla precedenza di `UnverifiedCopiesStore`, ne' agli esiti mostrati: e'
/// esattamente il corpo che prima stava dentro `ReviewEngine.sampleLocalPair`.
// `nonisolated`: nessuno stato condiviso proprio. `fm`/`defaults` sono thread-safe di suo
// (`FileManager`, `UserDefaults`); `UnverifiedCopiesStore` e' a sua volta `nonisolated`,
// protetta dal proprio `NSLock`.
nonisolated func integritySampleLocalPair(srcRoot: URL, dstRoot: URL, pairName: String, sampleSize: Int,
                                           defaults: UserDefaults) -> IntegrityCheckResult {
    let fm = FileManager.default
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
        let name = f.lastPathComponent
        // La quarantena della riparazione (ADR-0016) non e' una copia di backup da campionare.
        if LibraryExclusions.isQuarantineName(name) { enumerator.skipDescendants(); continue }
        let vals = try? f.resourceValues(forKeys: [.isRegularFileKey])
        guard vals?.isRegularFile == true else { continue }
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

    /// Involucro sul MainActor: chiamato direttamente dai test (che girano sul MainActor,
    /// XCTestCase lo e' di suo) e da `runIntegritySample` tramite `Task.detached` (ROADMAP
    /// #33) — il vero lavoro e' in `integritySampleLocalPair`, `nonisolated`, cosi' puo'
    /// girare davvero fuori dal main quando lo chiama `runIntegritySample`. Nessun cambio al
    /// criterio di campionamento ne' alle priorita' di `UnverifiedCopiesStore`.
    func sampleLocalPair(srcRoot: URL, dstRoot: URL, pairName: String, sampleSize: Int) -> IntegrityCheckResult {
        integritySampleLocalPair(srcRoot: srcRoot, dstRoot: dstRoot, pairName: pairName,
                                 sampleSize: sampleSize, defaults: defaults)
    }

    private func sampleS3Pair(ssdRoot: URL, sampleSize: Int,
                               onProgress: @escaping (String) -> Void) async throws -> IntegrityCheckResult {
        var result = IntegrityCheckResult(pairName: "SSD ↔ S3")
        let config = try S3Syncer.readConfig()
        let remoteKeys = try await s3Syncer.listAll(config: config)
        let candidates = remoteKeys.keys.filter {
            // La quarantena della riparazione (ADR-0016) non e' una copia di backup da campionare.
            !LibraryExclusions.isInsideQuarantine(relativePath: $0)
                && fm.fileExists(atPath: ssdRoot.appendingPathComponent($0).path)
        }
        guard !candidates.isEmpty else { return result }

        let sample = candidates.shuffled().prefix(sampleSize)
        for key in sample {
            onProgress("Verifica S3: \(key)")
            let localFile = ssdRoot.appendingPathComponent(key)
            // Il file esiste (`candidates` e' gia' filtrato su `fileExists`): se l'hash
            // non si calcola e' illeggibile o si e' mosso, non "sorgente mancante". Lo SHA256
            // gira fuori dal main (ROADMAP #33, `sha256(of:)` e' gia' `nonisolated`): sull'SSD
            // ci sono zip da 40-50 GB, e quella lettura bloccherebbe l'app per minuti se
            // restasse qui sul MainActor come faceva fino al 2026-09-20.
            guard let localHash = await Task.detached(priority: .utility, operation: { sha256(of: localFile) }).value
            else { result.skippedUnreadable += 1; continue }
            result.checked += 1
            do {
                let tempURL = try await s3Syncer.downloadToTemp(key: key, config: config)
                defer { try? fm.removeItem(at: tempURL) }
                let remoteHash = await Task.detached(priority: .utility, operation: { sha256(of: tempURL) }).value
                if let remoteHash, remoteHash == localHash {
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
            // Fuori dal main (ROADMAP #33): chiama direttamente la funzione `nonisolated`,
            // non `self.sampleLocalPair` (che e' sul MainActor e vanificherebbe il
            // `Task.detached` — caso A della tabella dei sei casi, `.claude/rules/architecture.md`).
            let dst = ssdURL.appendingPathComponent("Foto iPhone")
            let usedDefaults = defaults
            results.append(await Task.detached(priority: .utility) {
                integritySampleLocalPair(srcRoot: photosURL, dstRoot: dst, pairName: "Mac ↔ SSD",
                                         sampleSize: sampleSize, defaults: usedDefaults)
            }.value)
        } else {
            var r = IntegrityCheckResult(pairName: "Mac ↔ SSD")
            r.error = "Bookmark Foto o SSD non accessibile"
            results.append(r)
        }

        onProgress("Campionamento SSD ↔ HDD…")
        if let ssdURL, let hddURL {
            let usedDefaults = defaults
            results.append(await Task.detached(priority: .utility) {
                integritySampleLocalPair(srcRoot: ssdURL, dstRoot: hddURL, pairName: "SSD ↔ HDD",
                                         sampleSize: sampleSize, defaults: usedDefaults)
            }.value)
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
            // La quarantena della riparazione (ADR-0016) non e' una cartella da ripristinare.
            return name.hasPrefix(".") || LibraryExclusions.isQuarantineName(name) ? nil : name
        }.sorted()
    }

    func listAvailableFolders(fromS3Config config: S3Syncer.S3Config) async throws -> [String] {
        s3Syncer.beginNewOperation()
        let keys = try await s3Syncer.listAll(config: config).keys
        return S3Syncer.topLevelFolders(fromKeys: Array(keys))
    }

    func estimateS3Download(selectedFolders: Set<String>, destination: URL,
                             config: S3Syncer.S3Config) async throws -> (count: Int, bytes: Int64) {
        s3Syncer.beginNewOperation()
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
    @ObservedObject private var volumes = VolumeMonitor.shared
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

// MARK: - ImportView
/// Wizard di import a tre passi (source -> preview -> label), roadmap #27-A. Il passo
/// `.preview` fa girare l'anteprima VERA del wizard di import (roadmap #27-A / #31, terza
/// parte — spec `2026-09-01-import-preview-dedup-design.md`, piano
/// `2026-09-01-import-preview-dedup.md`, Task 4): il numero mostrato e' quello che
/// l'importazione copierebbe davvero, dedup per contenuto incluso, e non solo lo
/// zero-overwrite.
///
/// **La doppia lettura della sorgente e' stata accettata da Enrico a UNA condizione**
/// (spec, «Risposte di Enrico», risposta 1): *"il processo deve essere interrompibile, ci
/// deve essere timer o figura che gira per far capire che sta procedendo"*. Tre requisiti
/// separati, tutti cablati qui:
/// 1. **Avanzamento determinato** — `previewProgressView` mostra un `ProgressView(value:
///    total:)` non appena `BackupRunner.importPreviewDuplicates` conosce il denominatore
///    (`onProgress`, chiamato PRIMA di leggere un solo byte), non uno spinner indeterminato
///    che gira a vuoto.
/// 2. **Tempo trascorso** — `ImportPreviewStatus.progressLine(elapsedSec:)`, calcolato da
///    `previewStartDate` e formattato con `FileSyncer.SyncResult.hms`, MAI riscritta.
/// 3. **"Interrompi" che ferma davvero la lettura** — DUE meccanismi distinti, perche' la
///    camminata della sorgente vive dentro `FileSyncer` (`previewSyncer.cancel()`) e
///    l'hashing vive nella closure `duplicateFilter` (`previewCancelFlag.cancel()`, letto
///    da `isCancelled` dentro `importPreviewDuplicates`): alzarne uno solo lascia in piedi
///    l'altra meta' della lettura. Vanno alzati insieme, ovunque compaia il bottone.
///
/// **L'interruzione non torna indietro e non lascia una schermata vuota** (spec, risposta
/// 4): degrada al conteggio grezzo — il risultato parziale gia' calcolato, che puo'
/// sovrastimare `toAdd` perche' non tutti i doppioni sono stati verificati in tempo — con
/// una riga dedicata che lo dichiara (`ImportPreviewStatus.lines(interrupted:)`). La riga,
/// non una frase scritta qui: nessuna stringa duplicata fra questo file e l'enum.
///
/// **Token di richiesta** (`previewToken`, stesso schema di `DuplicateGroupRow.loadToken`):
/// l'utente puo' tornare indietro o scegliere un'altra sorgente mentre l'anteprima gira in
/// background. Un risultato — o anche un solo aggiornamento di avanzamento — arrivato per
/// un token non piu' corrente viene scartato, mai mostrato: e' per costruzione riferito a
/// una sorgente che non e' piu' quella in vista.
///
/// **Gate obbligatorio: SSD montato** (spec, "Gate obbligatorio: SSD montato"). Senza il
/// volume `isAlreadyInLibrary` fallirebbe la rilettura per ogni candidato e l'anteprima
/// dichiarerebbe tutto nuovo — cioe' ricadrebbe esattamente nel difetto che questo lavoro
/// chiude, senza dirlo. `ImportPreviewStatus.unavailableReason` distingue "non configurato"
/// da "non collegato" (due azioni diverse per l'utente), controllato sia all'avvio
/// dell'anteprima sia — via `onChange(of: volumes.ssdMounted)` — se il volume viene
/// scollegato mentre il wizard e' gia' aperto sul passo `.preview`: senza, un numero gia'
/// mostrato resterebbe a schermo anche dopo che l'SSD non c'e' piu', silenziosamente
/// sbagliato (verifica manuale n. 4 del piano).
///
/// **NON coperto da test** (stessa disciplina di `LibraryIndexCard` e `DuplicatesView`):
/// questa view, la barra di avanzamento, il bottone "Interrompi", il gate `VolumeMonitor`.
/// Sono SwiftUI e volumi veri, non raggiungibili senza una corsa reale. **E' testato tutto
/// cio' che sta ai due capi del cablaggio**: `FileSyncer.previewSync(duplicateFilter:)`
/// (`FileSyncerPreviewDedupTests`), `BackupRunner.importPreviewDuplicates`
/// (`ImportPreviewDedupTests`), e `ImportPreviewStatus` (`ImportPreviewStatusTests`).
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var volumes = VolumeMonitor.shared
    private let previewSyncer = FileSyncer()

    enum Step { case chooseSource, preview, label }

    @State private var step: Step = .chooseSource
    @State private var sourceURL: URL?
    @State private var guardErrorMessage: String?
    @State private var isLoadingPreview = false
    @State private var previewResult: (toAdd: Int, toSkip: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int, countComplete: Bool)?
    @State private var previewUnavailableReason: String?
    @State private var previewInterruption: ImportPreviewStatus.PreviewInterruption = .none
    @State private var previewProgress: (done: Int, total: Int, sourceFileCount: Int, elapsedSec: Int)?
    @State private var previewStartDate: Date?
    /// Token di richiesta (vedi doc-comment della struct): incrementato ogni volta che si
    /// riparte da `.chooseSource`, cosi' un risultato o un avanzamento della vecchia
    /// anteprima arrivato in ritardo viene riconosciuto come non piu' pertinente e scartato.
    @State private var previewToken = UUID()
    /// Vive per la durata di UNA sola anteprima (nuova istanza a ogni `pickSource()`), mai
    /// condivisa fra job. Riusa la classe gia' esistente (vedi in coda al file) — non
    /// scriverne una seconda, e' la lezione gia' pagata tre volte da `LibraryExclusions`/
    /// `realResolvedPath`/`makeThumbnail`.
    @State private var previewCancelFlag: CancelFlag?
    @State private var label: String = ""
    /// Da quanto l'elenco non e' aggiornato (Task 12, spec §4): calcolato quando si entra
    /// nel passo di anteprima e ricalcolato quando una lettura in corso finisce. `nil` solo
    /// finche' non e' ancora stato calcolato la prima volta.
    @State private var libraryListFreshness: LibraryListFreshness.Line?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            switch step {
            case .chooseSource: chooseSourceStep
            case .preview: previewStep
            case .label: labelStep
            }
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 360)
        .onChange(of: volumes.ssdMounted) { _, mounted in
            // Il volume e' stato scollegato mentre il wizard era gia' aperto sul passo di
            // anteprima: ferma subito la lettura (entrambi i meccanismi, come "Interrompi")
            // e mostra il motivo scritto al posto di un numero che l'assenza del volume
            // renderebbe silenziosamente sbagliato (verifica manuale n. 4 del piano).
            guard step == .preview else { return }
            guard !mounted else {
                // Ricollegato mentre il wizard era fermo sul motivo scritto: si toglie il
                // motivo, cosi' l'utente puo' riprovare senza tornare indietro e riscegliere
                // la cartella. Senza questo ramo restava bloccato su «SSD non collegato»
                // anche dopo averlo ricollegato (rilievo di review del 2026-09-01).
                previewUnavailableReason = ImportPreviewStatus.unavailableReason(
                    ssdConfigured: bm.urls[.ssd] != nil, ssdMounted: true)
                return
            }
            previewCancelFlag?.cancel()
            previewSyncer.cancel()
            previewToken = UUID()
            isLoadingPreview = false
            previewResult = nil
            previewProgress = nil
            previewUnavailableReason = ImportPreviewStatus.unavailableReason(
                ssdConfigured: bm.urls[.ssd] != nil, ssdMounted: false)
        }
        // A lettura finita (bottone "Aggiorna l'elenco adesso" qui sotto, o qualunque altra
        // lettura in corso altrove — Diagnostica, il passo 2 di un backup) l'anteprima si
        // rifa': l'insieme dei doppioni riconosciuti e' cambiato, e mostrare un numero
        // calcolato PRIMA dell'aggiornamento e' tutto il punto contro cui l'avviso esiste
        // (Task 12, D18).
        .onChange(of: runner.isIndexing) { _, isIndexing in
            guard step == .preview, !isIndexing else { return }
            refreshLibraryListFreshness()
            startPreview()
        }
    }

    private var chooseSourceStep: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
                Text("Importa foto da un dispositivo o una cartella").font(AppFont.title)
                Text("Scegli una fotocamera, un drone, un vecchio disco o qualsiasi cartella con foto da importare.")
                    .font(AppFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let guardErrorMessage {
                Text(guardErrorMessage).font(AppFont.caption).foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
            }
            Button("Scegli cartella o dispositivo…") { pickSource() }
                .buttonStyle(.borderedProminent)
            Spacer()
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private var previewStep: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Anteprima").font(AppFont.title)
            // Le righe di freschezza dell'elenco stanno SOPRA quelle dell'anteprima (Task 12,
            // D18): l'utente deve sapere se il numero che sta per leggere e' calcolato su un
            // elenco vecchio PRIMA di leggerlo, non dopo.
            if let freshness = libraryListFreshness {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Image(systemName: icon(freshness.tone)).foregroundStyle(color(freshness.tone))
                        .font(.system(size: 12))
                    Text(freshness.text).font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if freshness.id == "stale" || freshness.id == "unknown" {
                    HStack {
                        Button("Aggiorna l'elenco adesso") { refreshLibraryListNow() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(runner.isIndexing)
                        Button("Continua così") {}
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                    }
                }
            }
            if let previewUnavailableReason {
                Text(previewUnavailableReason).font(AppFont.caption).foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
            } else if isLoadingPreview {
                previewProgressView
            } else if let previewResult {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(ImportPreviewStatus.lines(
                        toAdd: previewResult.toAdd,
                        toSkipDuplicates: previewResult.toSkipDuplicates,
                        toAddBytes: previewResult.toAddBytes,
                        estimatedSec: previewResult.estimatedSec,
                        interruption: previewInterruption)) { line in
                        HStack(alignment: .top, spacing: AppSpacing.sm) {
                            Image(systemName: icon(line.tone))
                                .foregroundStyle(color(line.tone)).font(.system(size: 12))
                            Text(line.text).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
                .font(AppFont.body)
            }
            Spacer()
            HStack {
                Button("Indietro") {
                    // Il token cambia comunque (vedi sotto), ma senza fermare anche la
                    // lettura in corso l'anteprima abbandonata continuerebbe a leggere e
                    // hashare in background per conto di nessuno: stessi due meccanismi di
                    // "Interrompi", stesso motivo.
                    previewCancelFlag?.cancel()
                    previewSyncer.cancel()
                    previewToken = UUID()
                    step = .chooseSource
                }.buttonStyle(.bordered)
                Spacer()
                Button("Continua") { step = .label }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoadingPreview || previewUnavailableReason != nil)
            }
        }
    }

    @ViewBuilder
    private var previewProgressView: some View {
        VStack(spacing: AppSpacing.sm) {
            if let p = previewProgress, p.total > 0 {
                // Barra DETERMINATA (requisito 1 di Enrico): il denominatore e' noto prima
                // di leggere un solo byte (`BackupRunner.importPreviewDuplicates`), non uno
                // spinner che gira mentre non si muove niente.
                ProgressView(value: Double(p.done), total: Double(p.total))
                Text(ImportPreviewStatus.progressLine(
                    done: p.done, total: p.total, sourceFileCount: p.sourceFileCount, elapsedSec: p.elapsedSec))
                    .font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                // Fase iniziale: la sola camminata della sorgente (stat, nessun hash), il
                // cui denominatore per la dedup non e' ancora noto.
                //
                // **ASSUNTA** trascurabile rispetto all'hashing, **non misurata** — rilievo
                // di review del 2026-09-01: la stesura precedente di questo commento diceva
                // «misurata trascurabile (spec)», e nella spec quella misura non c'e'. Su un
                // progetto che distingue con cura «misurato» da «assunto» in tutta la
                // documentazione, citare una misura inesistente e' peggio che non citarne
                // nessuna: la prossima persona la prende per un fatto verificato.
                // La conferma e' la verifica manuale n. 1 del piano, ancora da fare: se su
                // una scheda vera questa fase durasse a lungo, qui serve una barra
                // determinata anche per la camminata, non uno spinner.
                ProgressView("Conteggio file in corso…")
            }
            // Requisito 3 di Enrico: SEMPRE premibile durante l'attesa, in entrambe le fasi
            // sopra. Alza ENTRAMBI i meccanismi di interruzione — la camminata vive dentro
            // `FileSyncer`, l'hashing vive nella closure — perche' non si sa in quale delle
            // due fasi ci si trova quando l'utente preme il bottone.
            Button("Interrompi") {
                previewCancelFlag?.cancel()
                previewSyncer.cancel()
            }.buttonStyle(.bordered).tint(AppColor.error)
        }
    }

    private func icon(_ tone: ImportPreviewStatus.Tone) -> String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ tone: ImportPreviewStatus.Tone) -> Color {
        switch tone {
        case .ok: return AppColor.success
        case .info: return .secondary
        case .warning: return AppColor.warning
        }
    }

    /// Overload per `LibraryListFreshness.Tone` (Task 12): stessi tre casi, stessa mappa —
    /// due enum diversi con gli stessi nomi di caso, non un motivo per due funzioni con nomi
    /// diversi.
    private func icon(_ tone: LibraryListFreshness.Tone) -> String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ tone: LibraryListFreshness.Tone) -> Color {
        switch tone {
        case .ok: return AppColor.success
        case .info: return .secondary
        case .warning: return AppColor.warning
        }
    }

    private var labelStep: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Nome della cartella di destinazione").font(AppFont.title)
            Text("Le foto verranno copiate in una cartella dedicata sull'SSD, dentro \"Import\".")
                .font(AppFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Etichetta", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            // Motivo scritto se un'altra copia e' gia' in corso — vedi doc-comment di
            // `importStartDisabledReason`: fra la scelta dell'etichetta e il click possono
            // passare minuti in cui un backup automatico o un import precedente e' partito.
            if let reason = importStartDisabledReason(jobIsRunning: runner.isRunning) {
                Text(reason).font(AppFont.caption).foregroundStyle(AppColor.error)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            HStack {
                Button("Indietro") { step = .preview }.buttonStyle(.bordered)
                Spacer()
                Button("Avvia importazione") { startImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                        || importStartDisabledReason(jobIsRunning: runner.isRunning) != nil)
            }
        }
    }

    private func pickSource() {
        guardErrorMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Scegli la cartella o il volume da cui importare le foto"
        panel.prompt = "Seleziona"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isSourceInsideConfiguredLocations(url, configuredURLs: Array(bm.urls.values)) {
            guardErrorMessage = "'\(url.lastPathComponent)' fa parte di una cartella già configurata (Libreria Foto, SSD o HDD) — scegli una sorgente diversa."
            return
        }
        sourceURL = url
        label = "\(url.lastPathComponent) - \(Self.dateFormatter.string(from: Date()))"
        step = .preview
        refreshLibraryListFreshness()
        startPreview()
    }

    /// Calcola `libraryListFreshness` (Task 12, D15/D17): prova prima la data dell'ultima
    /// lettura arrivata in fondo (`libraryListLastCompleteReadDefaultsKey`); se manca, il
    /// ripiego `LibraryIndexStore.newestHashedAt()`, letto fuori dal main — e' una query
    /// SQLite, non va fatta sul MainActor (stessa regola di `BackupRunner.indexedFileCount`).
    private func refreshLibraryListFreshness() {
        let hasAnyEntries = runner.indexedFileCount > 0
        let isReading = runner.isIndexing
        if let ts = UserDefaults.standard.object(forKey: libraryListLastCompleteReadDefaultsKey) as? Double {
            libraryListFreshness = LibraryListFreshness.line(hasAnyEntries: hasAnyEntries,
                                                              lastCompleteReadAt: Date(timeIntervalSince1970: ts),
                                                              isReading: isReading)
            return
        }
        guard let store = runner.libraryIndexStore else {
            libraryListFreshness = LibraryListFreshness.line(hasAnyEntries: hasAnyEntries,
                                                              lastCompleteReadAt: nil, isReading: isReading)
            return
        }
        Task.detached(priority: .utility) {
            let fallbackTimestamp = try? store.newestHashedAt()
            await MainActor.run {
                let date = fallbackTimestamp.map { Date(timeIntervalSince1970: $0) }
                self.libraryListFreshness = LibraryListFreshness.line(hasAnyEntries: hasAnyEntries,
                                                                      lastCompleteReadAt: date, isReading: isReading)
            }
        }
    }

    /// «Aggiorna l'elenco adesso» (Task 12, D18): l'aggiornamento **incrementale**
    /// (`full: false`), mai la ricostruzione completa — quella resta un'azione esplicita
    /// separata, in Diagnostica. L'anteprima si rifa' da sola quando la lettura finisce,
    /// tramite `.onChange(of: runner.isIndexing)` nel `body`.
    private func refreshLibraryListNow() {
        runner.rebuildLibraryIndex(full: false, onAlert: { previewUnavailableReason = $0.message })
    }

    /// Il corpo di `pickSource()` da `guard let url = sourceURL` in avanti, estratto per
    /// poter essere richiamato anche dopo un aggiornamento dell'elenco (Task 12, D18):
    /// l'insieme dei doppioni riconosciuti e' cambiato, e mostrare un numero calcolato PRIMA
    /// dell'aggiornamento e' tutto il punto contro cui l'avviso di freschezza esiste.
    private func startPreview() {
        guard let url = sourceURL else { return }
        previewResult = nil
        previewInterruption = .none
        previewProgress = nil
        previewUnavailableReason = nil

        // Gate obbligatorio (spec, "Gate obbligatorio: SSD montato"): senza il volume,
        // `isAlreadyInLibrary` fallirebbe la rilettura per ogni candidato e l'anteprima
        // dichiarerebbe tutto nuovo — cioè ricadrebbe esattamente nel difetto che questo
        // lavoro chiude, senza dirlo. I due motivi sono DISTINTI apposta (configurare vs
        // collegare — `ImportPreviewStatus.unavailableReason`).
        let ssdConfigured = bm.urls[.ssd] != nil
        if let reason = ImportPreviewStatus.unavailableReason(ssdConfigured: ssdConfigured, ssdMounted: volumes.ssdMounted) {
            previewUnavailableReason = reason
            return
        }
        // `ssdConfigured` è già vero qui: il guard resta solo per non forzare l'unwrap.
        guard let ssdURL = bm.urls[.ssd] else { return }
        // Letta QUI, sul MainActor, PRIMA di entrare nel Task qui sotto: `bm.urls` è
        // `@Published`, e leggerla da un thread di background è il difetto già chiuso una
        // volta in `isAlreadyInLibrary` col parametro `libraryRoot`.
        let libraryRoot = ssdURL
        // Stesso motivo: `runner.libraryIndexStore` catturato una volta sola qui, non
        // riletto dentro la closure che gira sulla coda di lavoro di `previewSync` — stesso
        // pattern già in uso in `BackupRunner.runImport`, che cattura `store` sul MainActor
        // prima di passarlo al job vero e proprio.
        let store = runner.libraryIndexStore

        isLoadingPreview = true
        previewStartDate = Date()
        let token = UUID()
        previewToken = token
        let flag = CancelFlag()
        previewCancelFlag = flag

        // La cartella di destinazione è sempre nuova/vuota (Import/<slug> non esiste ancora),
        // quindi toSkip sarà sempre 0 qui indipendentemente dallo slug esatto usato: il numero
        // non cambia se l'utente modifica l'etichetta al passo successivo.
        let dst = ssdURL.appendingPathComponent("Import").appendingPathComponent(importFolderSlug(label))
        Task { @MainActor in
            let result = await previewSyncer.previewSync(from: url, to: dst, deep: false, duplicateFilter: { candidates in
                // Gira sulla coda di lavoro di `previewSync`, MAI sul MainActor: qualunque
                // cosa tocchi lo stato della View passa da un `Task { @MainActor in }`
                // separato — stessa regola di `DuplicatesView`/`BackupRunner.indexedFileCount`.
                BackupRunner.importPreviewDuplicates(
                    candidates: candidates,
                    store: store,
                    libraryRoot: libraryRoot,
                    isCancelled: { flag.isCancelled },
                    onProgress: { done, total in
                        Task { @MainActor in
                            // Token di richiesta: scarta anche un solo aggiornamento di
                            // avanzamento arrivato per una sorgente non più corrente, non
                            // solo il risultato finale — altrimenti la barra di UNA
                            // anteprima abbandonata continuerebbe a muoversi sullo schermo
                            // di quella nuova.
                            guard token == previewToken else { return }
                            let elapsed = previewStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
                            previewProgress = (done: done, total: total, sourceFileCount: candidates.count, elapsedSec: elapsed)
                        }
                    })
            })
            // Token di richiesta (vedi doc-comment della struct): un risultato arrivato per
            // una sorgente non più corrente non va MAI mostrato — è per costruzione
            // riferito a un'altra scelta dell'utente.
            guard token == previewToken else { return }
            isLoadingPreview = false
            // Le due interruzioni sbagliano il numero in direzioni OPPOSTE, e la riga che
            // l'utente legge deve dire quale delle due e' capitata (rilievo di review del
            // 2026-09-01). `countComplete` viene da `previewSync` e dice se la camminata e'
            // arrivata in fondo: se no, `toAdd` non e' un totale sovrastimato ma un frammento.
            previewInterruption = flag.isCancelled ? (result.countComplete ? .duringCheck : .duringCount)
                                                   : .none
            previewResult = result
        }
    }

    private func startImport() {
        guard let sourceURL else { return }
        // Difesa sul click, oltre a quella dentro `BackupRunner.runImport` (vedi doc-comment
        // di `importStartDisabledReason`): il bottone e' gia' disabilitato in questo caso, ma
        // un secondo controllo qui evita di chiudere lo sheet inutilmente in caso di corsa.
        guard importStartDisabledReason(jobIsRunning: runner.isRunning) == nil else { return }
        runner.runImport(source: sourceURL, label: label)
        dismiss()
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
    @ObservedObject private var volumes = VolumeMonitor.shared
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
                        PhaseIndicator(phase: runner.phase, percent: runner.displayPercent,
                                      title: BackupListStep.header(label: runner.phase.label, state: runner.listStepState))
                        Spacer()
                        Button {
                            activeSpeedTab = .log
                        } label: { Label("Log", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                        if runner.isRunning {
                            Button(role: .destructive) { runner.stop() } label: {
                                Label(runner.listStopRequested ? BackupListStep.stoppingLabel : "Interrompi",
                                     systemImage: "stop.fill")
                            }.buttonStyle(.bordered).controlSize(.small).tint(AppColor.error)
                            .disabled(runner.listStopRequested)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.regularMaterial)
                    Divider()
                    SpeedLogPanel(history: runner.speedHistory, output: runner.output, speedUnit: runner.speedUnit, activeTab: $activeSpeedTab)
                        .padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, AppSpacing.sm)
                    if runner.phase != .idle {
                        Divider()
                        StatsPanel(stats: runner.stats, phase: runner.phase, currentStatus: runner.currentStatus,
                                  currentThumbnail: runner.currentThumbnail, displayPercent: runner.displayPercent,
                                  listStep: runner.listStepPresentation)
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
            // Decisione di Enrico (2026-09-19, domanda aperta 1 della spec del passo 2 del
            // backup): al collegamento dell'SSD non parte piu' nessuna lettura da sola.
            // L'elenco si aggiorna solo come ultimo passo di un backup/importazione, o a
            // mano da Diagnostica — mai piu' come attivita' separata al collegamento.
            // BUG-10 (2026-09-28): sotto il test host di `xcodebuild test` un backup vero
            // scriverebbe file reali dell'utente sull'SSD/Libreria Foto veri se il volume
            // venisse montato/smontato durante una corsa di test.
            guard !isRunningUnderTests(), mounted, autoBackupEnabled, !runner.isRunning else { return }
            runner.runMacToSSD()
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
                Toggle("Aggiorna l'elenco delle foto alla fine di ogni backup", isOn: $autoRefreshLibraryIndex)
                Text("Dopo ogni copia verso l'SSD l'app controlla le foto che ci sono e aggiunge all'elenco quelle nuove: è l'ultimo passo del backup, e puoi fermarlo con «Interrompi». La prima creazione dell'elenco resta manuale, da Diagnostica: quella dura diversi minuti.")
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
            // Passo 2 del backup (2026-09-19): solo se c'e' stato. Titolo e icona del
            // riepilogo restano quelli di sopra ("Backup completato", verde) — il job e'
            // riuscito per costruzione, anche quando il passo 2 si e' fermato (D3 della spec).
            if let listStepOutcome = stats.listStepOutcome {
                let (text, tone) = BackupListStep.completionLine(listStepOutcome)
                Label(text, systemImage: tone == .ok ? "checkmark.circle.fill"
                    : tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(tone == .ok ? AppColor.success : tone == .warning ? AppColor.warning : .secondary)
                    .multilineTextAlignment(.center)
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
                VolumeSpaceLine(kind: .ssd)
                VolumeRow(name: "BackupHDD",   icon: "externaldrive.fill",  mounted: volumes.hddMounted)
                VolumeSpaceLine(kind: .hdd)
                VolumeRow(name: "Cubbit S3",   icon: "cloud.fill",          mounted: true, alwaysOn: true)
                CloudUsageLine(runner: runner)
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

/// Quale disco con barra di spazio: SSD o HDD. Porta con sé il colore "normale" della propria
/// barra — quello della DESTINAZIONE (`AppColor.macToSSD`/`ssdToHDD`), non un token unico
/// legato all'accent di sistema: decisione di Enrico (ADR-0008, deviazione dalla spec
/// originale). Blu e teal non sono confondibili con l'arancione/rosso delle soglie
/// (`AppColor.warning`/`error`): tre hue diversi sulla ruota dei colori.
enum VolumeKind {
    case ssd, hdd

    var normalColor: Color {
        switch self {
        case .ssd: return AppColor.macToSSD
        case .hdd: return AppColor.ssdToHDD
        }
    }
}

/// Barra sottile disegnata a mano con due `Capsule` sovrapposte, non una `ProgressView`: su
/// macOS il `.tint` di una barra lineare non è garantito.
struct SpaceBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// Riga sotto un `VolumeRow` (SSD o HDD) con la barra di spazio e il testo "X liberi su Y · N%".
/// Osserva `VolumeMonitor.shared.space` da sola: `SidebarView` non le passa nessun parametro
/// nuovo, quindi non si abbona allo spazio e non si ridisegna quando cambia.
struct VolumeSpaceLine: View {
    let kind: VolumeKind
    @ObservedObject private var space = VolumeMonitor.shared.space

    private var state: VolumeSpaceState {
        switch kind {
        case .ssd: return space.ssd
        case .hdd: return space.hdd
        }
    }

    var body: some View {
        Group {
            switch state {
            case .measured(let display):
                VStack(alignment: .leading, spacing: 2) {
                    SpaceBar(fraction: Double(display.percentUsed) / 100, color: color(for: display.level))
                    HStack {
                        Text(display.freeLine)
                        Spacer()
                        Text("\(display.percentUsed)%").monospacedDigit()
                    }
                }
            case .disconnected, .unreadable:
                Text(state.statusText)
            }
        }
        .font(AppFont.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 44).padding(.trailing, 16).padding(.bottom, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func color(for level: SpaceLevel) -> Color {
        switch level {
        case .normal: return kind.normalColor
        case .warning: return AppColor.warning
        case .critical: return AppColor.error
        }
    }

    private var accessibilityText: String {
        if case .measured(let display) = state { return display.accessibilityLabel }
        return state.statusText
    }
}

/// Riga sotto la `VolumeRow` di Cubbit: «X usati» + «aggiornato…», più il bottone ↻ per il
/// ricalcolo manuale (decisione di Enrico, ADR-0008: sì). Riceve `runner` come parametro —
/// niente `@ObservedObject runner` aggiuntivo altrove, `SidebarView` lo passa già.
struct CloudUsageLine: View {
    @ObservedObject var runner: BackupRunner
    @ObservedObject private var store = CloudUsageStore.shared

    private var refreshDisabledReason: String? {
        CloudUsageRefreshGate.disabledReason(jobIsRunning: runner.isRunning, isRefreshing: store.isRefreshing)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                if store.isRefreshing {
                    HStack(spacing: AppSpacing.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Sto calcolando lo spazio usato…")
                    }
                } else {
                    Text(CloudUsageText.usedLine(store.snapshot))
                }
                // Durante il primo calcolo "Si aggiorna al prossimo backup" contraddirebbe la riga
                // sopra (visto dal vivo il 2026-09-19): la si nasconde finche' non c'e' un numero.
                if !(store.isRefreshing && store.snapshot == nil) {
                    Text(CloudUsageText.updatedLine(store.snapshot, now: Date(), calendar: .current, locale: .current))
                        .foregroundStyle(.secondary)
                }
                if store.lastRefreshFailed && !store.isRefreshing {
                    Text("Cubbit non raggiungibile, riprova più tardi").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task {
                    await runner.loadS3ConfigIfNeeded()
                    if let config = runner.s3Config {
                        await store.refresh(config: config)
                    } else {
                        store.markConfigUnavailable()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(refreshDisabledReason != nil)
            .help(refreshDisabledReason ?? "Ricalcola lo spazio usato su Cubbit. Può richiedere un paio di minuti.")
        }
        .font(AppFont.caption)
        .padding(.leading, 44).padding(.trailing, 16).padding(.bottom, AppSpacing.xs)
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
    @State private var showImport = false
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
                        // Non disattivata durante un job, di proposito: l'anteprima legge la
                        // SORGENTE (scheda, disco esterno), non l'SSD, quindi non contende
                        // niente a un backup in corso, e guardare cosa si sta per importare e'
                        // legittimo mentre una copia gira. E' l'avvio vero a essere bloccato,
                        // con il motivo scritto (`importStartDisabledReason`) sia sul bottone
                        // sia dentro `BackupRunner.runImport`.
                        HamburgerRow(icon: "square.and.arrow.down.on.square", label: "Importa foto", iconColor: .mint) {
                            showImport = true
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

                        HamburgerRow(icon: "photo.stack", label: "Foto", iconColor: .pink) {
                            openWindow(id: "immich")
                        }
                        HamburgerRow(icon: "checklist", label: "Inventario", iconColor: .indigo) {
                            openWindow(id: "inventory")
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
        .sheet(isPresented: $showImport)     { ImportView() }
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
    /// Etichetta durante `.running`: normalmente identica a `phase.label`, ma durante il
    /// passo 2 del backup diventa "<label> — passo 2 di 2" (`BackupListStep.header`, mai
    /// calcolata qui). `percent` durante il passo 2 e' `BackupRunner.displayPercent`, che
    /// non tocca mai 100 finche' la lettura non e' finita — per questo "Finalizzando..." non
    /// puo' comparire nel passo 2.
    var title: String? = nil
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if case .running = phase {
                ProgressView().controlSize(.small)
                Text(percent >= 100 ? "Finalizzando..." : (title ?? phase.label))
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
    /// Percentuale da mostrare: `BackupRunner.displayPercent` (quella del passo 2 mentre
    /// gira, altrimenti `stats.percent` — lo decide il chiamante, non questa view).
    var displayPercent: Int
    /// Presente solo durante il passo 2 (`BackupRunner.listStepPresentation`): sostituisce
    /// miniatura/stato e "done / total file", azzera velocita' ed ETA. Nessuna stringa nasce
    /// qui dentro: arriva gia' pronta da `BackupListStep`.
    var listStep: BackupListStep.Presentation? = nil

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            if let listStep {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Label {
                        Text(listStep.copyDone.text)
                    } icon: {
                        Image(systemName: listStep.copyDone.clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(listStep.copyDone.clean ? AppColor.success : AppColor.error)
                    }
                    Label {
                        Text(listStep.runningLine)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(AppFont.body)
            } else {
                HStack(spacing: AppSpacing.sm) {
                    CurrentFileThumbnail(image: currentThumbnail)
                    StatusBar(status: currentStatus, phase: phase)
                }
            }
            VStack(spacing: AppSpacing.sm) {
                HStack {
                    Text("Avanzamento").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(displayPercent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: displayPercent)
                }
                ProgressView(value: Double(displayPercent), total: 100).progressViewStyle(.linear)
                    .tint(phase == .idle ? .secondary : (stats.errors > 0 ? AppColor.error : AppColor.inProgress))
                HStack {
                    if let listStep {
                        Text(listStep.countLine)
                            .font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("\(stats.done) / \(stats.total) file")
                            .font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("velocita \(listStep != nil ? "—" : stats.speed)").font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.speed)
                }
            }
            HStack(spacing: AppSpacing.md) {
                StatTile(label: "Copiati",   value: "\(stats.copied)",  accent: AppColor.inProgress)
                StatTile(label: "Skippati",  value: "\(stats.skipped)", accent: .secondary)
                StatTile(label: "Errori",    value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary)
                StatTile(label: "Trascorso", value: stats.elapsed,      accent: .secondary)
                StatTile(label: "ETA",       value: listStep != nil ? "—" : stats.eta, accent: .secondary)
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

    /// Stesso gate delle altre scene: "Diagnostica" è una scena di primo livello, apribile
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
                                        // Stesso motivo di `LibraryIndexCard.postAlert`: qui
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
                            // Nessuna stringa scritta qui: `IntegritySummary` e' la fonte unica,
                            // e mostra anche i due contatori che questa view buttava via.
                            ForEach(IntegritySummary.lines(for: result)) { line in
                                Text(line.text)
                                    .font(AppFont.caption)
                                    .foregroundStyle(line.tone == .ok ? AppColor.success
                                                     : line.tone == .warning ? AppColor.error
                                                     : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
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
                                               jobIsRunning: runner.isRunning,
                                               isTrashingDuplicates: runner.isTrashingDuplicates,
                                               isRestoringFromTrash: runner.isRestoringFromTrash,
                                               isInventorying: runner.isInventorying,
                                               isRepairing: runner.isRepairing)
    }

    private var commandsDisabled: Bool { commandsDisabledReason != nil }

    /// L'avviso viene pubblicato **al giro di runloop successivo**.
    ///
    /// Rilievo minore di #31, chiuso il 2026-09-01: questi avvisi nascono dentro l'`onConfirm`
    /// di un altro alert (`confirmFirstBuild`, `confirmFullRecheck`, `confirmReset` passano
    /// tutti una closure `{ postAlert($0) }` a `rebuildLibraryIndex`/`resetLibraryIndex`, che possono richiamarla
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
    private func postAlert(_ alert: SimpleAlert) {
        DispatchQueue.main.async { pendingAlert = alert }
    }

    /// Stima dichiarata prima di partire. Non e' mai stata misurata sul volume vero: e'
    /// scritta come un ordine di grandezza, non come una promessa.
    /// **Numero misurato, non stimato** (2026-09-01, primo collegamento dell'SSD dopo
    /// la scrittura della card). Throughput reale di lettura+SHA256 dall'SSD: 224 MiB/s
    /// su un campione di 300 file distribuiti, contro 237,4 GiB di media indicizzabili
    /// (47.482 file) = ~18 minuti. La prima stesura diceva "dai 5 ai 15 minuti" ed
    /// era un ordine di grandezza scritto a tavolino, con l'estremo superiore sotto la
    /// misura vera.
    ///
    /// **Ricalcolato il 2026-09-25 (Task 12): la libreria e' cresciuta a 390,6 GB**
    /// (`ASUS/foto/recup_dir.NN/` misurato il 2026-09-24, vedi `duplicateKeepChoice`) —
    /// allo stesso throughput di 224 MiB/s fanno **~28 minuti**, non piu' i ~18 di
    /// settembre. "Dai 15 ai 25" era di nuovo sottostimato, con lo stesso errore della
    /// prima stesura: l'estremo superiore sotto la misura vera. Se il contenuto dell'SSD
    /// cambia sensibilmente, si rimisura: non si ritocca a occhio.
    private let durata = "di solito servono dai 25 ai 35 minuti"

    var body: some View {
        GroupBox(LibraryIndexCommands.cardTitle) {
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
                            runner.rebuildLibraryIndex(onAlert: { postAlert($0) })
                        } else {
                            confirmFirstBuild()
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(commandsDisabled)

                    Spacer()

                    // I due comandi rari stanno dietro un menu, non in fila con quello di
                    // tutti i giorni (2026-09-03, richiesta di Enrico: «dev'essere sicuro e
                    // semplice, se non e' facile da usare ci possono essere errori»).
                    //
                    // Prima erano tre bottoni affiancati, della stessa dimensione, con nomi
                    // che si somigliano — «Aggiorna l'elenco», «Controlla tutte le foto da
                    // capo», «Svuota l'elenco e ricomincia da zero» — e l'unico distruttivo
                    // era distinguibile solo dal colore. Un clic di troppo a destra e si
                    // buttava via un elenco che costa venti minuti a ricostruire.
                    //
                    // Lo svuotamento **resta raggiungibile**, ed e' un vincolo, non un
                    // dettaglio: ADR-0002 lo indica come l'unica via d'uscita quando restano
                    // in elenco foto che sull'SSD non ci sono piu'. Nasconderlo del tutto
                    // lascerebbe l'utente in un vicolo cieco. Qui e' a due gesti invece che a
                    // uno, che e' esattamente la differenza fra "raggiungibile" e "a portata
                    // di clic distratto".
                    Menu {
                        Button(LibraryIndexCommands.fullRecheck) { confirmFullRecheck() }
                            .disabled(commandsDisabled || runner.indexedFileCount == 0)
                        Divider()
                        Button(LibraryIndexCommands.reset, role: .destructive) { confirmReset() }
                            .disabled(commandsDisabled || runner.indexedFileCount == 0)
                    } label: {
                        Label("Altro", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Controlli meno frequenti su questo elenco")
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
            onConfirm: { runner.rebuildLibraryIndex(onAlert: { postAlert($0) }) })
    }

    private func confirmFullRecheck() {
        pendingAlert = SimpleAlert(
            title: "Controllare tutte le foto da capo?",
            message: "L'app rilegge dall'inizio ogni foto e ogni video sull'SSD, anche quelli che ha già visto: \(durata).\n\nServe dopo che hai spostato o riorganizzato le cartelle sull'SSD, per rimettere in pari l'elenco.\n\nPuoi fermarti quando vuoi. L'SSD viene solo letto: nessuna foto viene toccata.",
            confirmTitle: "Controlla da capo",
            cancelTitle: "Annulla",
            onConfirm: { runner.rebuildLibraryIndex(full: true, onAlert: { postAlert($0) }) })
    }

    /// L'unica via d'uscita quando restano nell'elenco foto che sull'SSD non ci sono piu'
    /// e nessun controllo riesce a toglierle (ADR-0002). Deve essere raggiungibile, e deve
    /// essere impossibile premerlo credendo di cancellare le foto.
    private func confirmReset() {
        pendingAlert = SimpleAlert(
            title: "Svuotare l'elenco delle foto già salvate?",
            message: "Viene cancellato solo l'elenco che l'app tiene sul Mac. Le tue foto e i tuoi video sull'SSD non vengono toccati: non ne viene cancellato nemmeno uno.\n\nDopo, l'elenco va rifatto da zero (\(durata)) e finché non lo rifai un'importazione può ricopiare foto che hai già.\n\nInsieme all'elenco si svuota anche l'inventario (finestra Inventario), che andrà aggiornato di nuovo.",
            isDestructive: true,
            confirmTitle: "Svuota l'elenco",
            cancelTitle: "Annulla",
            onConfirm: { runner.resetLibraryIndex(onAlert: { postAlert($0) }) })
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

/// Dirada gli aggiornamenti di progresso verso la UI: al massimo uno ogni `minimumIntervalNanos`,
/// e **sempre** quello finale. Nasce da una misura del 2026-09-19 (ROADMAP #37): durante un
/// MAC -> SSD con quasi tutti i file gia' presenti (~575 file/s) il main thread era al ~100%
/// in ridisegno, perche' ogni file pubblicava il proprio progresso. Il tempo e non il numero di
/// file: a 575 file/s e a 5 file/s serve la stessa cadenza a schermo (ADR-0010).
// `nonisolated`: value type senza stato condiviso; ogni istanza vive sullo stack del thread
// che la usa (il thread di `FileSyncer.sync`, quello di `TrashRestorer.run`).
nonisolated struct ProgressThrottle {
    static let defaultMinimumIntervalNanos: UInt64 = 100_000_000
    let minimumIntervalNanos: UInt64
    private var lastEmitNanos: UInt64?

    init(minimumIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos) {
        self.minimumIntervalNanos = minimumIntervalNanos
    }

    /// `true` se l'aggiornamento va pubblicato adesso. `isFinal` pubblica sempre. Un orologio
    /// che va all'indietro (non dovrebbe: i chiamanti usano `DispatchTime.now().uptimeNanoseconds`,
    /// monotono) pubblica e riparte da li', mai un silenzio permanente.
    mutating func shouldEmit(nowNanos: UInt64, isFinal: Bool) -> Bool {
        guard !isFinal, let last = lastEmitNanos, nowNanos >= last else {
            lastEmitNanos = nowNanos
            return true
        }
        guard nowNanos - last >= minimumIntervalNanos else { return false }
        lastEmitNanos = nowNanos
        return true
    }
}

// MARK: - Pannello Doppioni (roadmap #31, Task 6)

/// Piccola scatola di riferimento con lock: l'interruzione arriva da un bottone sul thread
/// principale, la lettura arriva dal thread in background che sta eseguendo
/// `DuplicateTrasher.run`. Stesso schema gia' in uso in `LibraryIndexer.cancelled`, qui come
/// tipo a parte perche' `DuplicatesView` e' una `struct` e non puo' tenere un lock su una sua
/// proprieta' di valore.
///
/// Dal 2026-09-19 (Task 5/6 del fix di isolamento, BUG-7) e' il flag di interruzione
/// **condiviso** del progetto: non piu' `private`, usato anche da `FileSyncer`/`S3Syncer` al
/// posto dei loro `private var cancelled = false` nudi (data race non protetta in
/// `FileSyncer`, due warning di isolamento in `S3Syncer`). `reset()` serve a quei due
/// chiamanti: un nuovo `sync()` deve poter ripartire dopo un `cancel()` precedente.
// `nonisolated`: `flag` si tocca solo dentro `lock.withLock`.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    func reset() { lock.withLock { flag = false } }
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
    @ObservedObject private var volumes = VolumeMonitor.shared

    private enum LoadState {
        case idle, loading, loaded([DuplicateGroup]), failed(String)
    }

    @State private var loadState: LoadState = .idle
    /// Il batch **gia' calcolato**, aggiornato in blocco con `loadState` dentro `loadGroups()`.
    ///
    /// Bug reale trovato il 2026-09-02 misurando il processo vivo (`sample`, non a deduzione):
    /// `headerLine` e `listArea` ricostruivano `DuplicateBatch(groups:)` da zero **a ogni
    /// ridisegno di SwiftUI**, cioe' ogni volta che una checkbox cambiava, una miniatura
    /// finiva di caricare, o qualunque altro `@State` di questa view veniva toccato.
    /// `DuplicateBatch.init` ordina l'intero elenco e per ogni gruppo richiama
    /// `duplicateKeepChoice` e filtra i membri piu' volte: con le migliaia di gruppi reali
    /// prodotti da un SSD vero (`Foto Google Drive` collide con `Takeout` all'80,6%,
    /// misurato il 2026-09-01), un `sample` del processo ha mostrato il thread principale
    /// bloccato al 100% dentro questo identico percorso per l'intera finestra di
    /// campionamento — la causa del pannello che "non rispondeva piu'". Ora si calcola
    /// **una volta sola**, fuori dal main thread, quando i gruppi arrivano.
    @State private var loadedBatch: DuplicateBatch? = nil
    @State private var selectedHashes: Set<String> = []
    /// Indice `hash → Entry` sul `loadedBatch` corrente, per leggere `leaving`/
    /// `reclaimableBytes` di una foto selezionata in O(1) — mai filtrando di nuovo
    /// `loadedBatch.groups` (27.798 elementi) per ogni checkbox (Regola 9).
    @State private var entryByHash: [String: DuplicateBatch.Entry] = [:]
    /// Totali della selezione, ricalcolati SOLO sull'insieme selezionato (tipicamente
    /// piccolo), mai su tutti i gruppi: la riga di selezione li legge in O(1).
    @State private var selectionStats: (files: Int, bytes: Int64) = (0, 0)

    // MARK: - Filtri e regola per cartella (Task 11, Step 1-4, ADR-0011)

    /// I tre filtri del pannello, componibili in AND (`DuplicateFilter`, ADR-0011). Il
    /// ricalcolo dell'insieme filtrato non avviene mai qui dentro un `.onChange`: ogni
    /// mutazione passa da una delle funzioni sotto, che chiama `rebuildBatch(from:rule:)`
    /// subito dopo — un solo punto che ricalcola, mai una `.onChange` implicita da cui e'
    /// facile perdere un caso.
    @State private var filter = DuplicateFilter()
    /// Indici in `loadedBatch.groups` che soddisfano `filter` — mai una copia dei gruppi
    /// (spec §2.8, punto 1): l'elenco stesso resta quello di sempre, `visibleIndices` dice
    /// solo quali righe mostrare.
    @State private var visibleIndices: [Int] = []
    /// Le cartelle di primo livello che compaiono nei gruppi, con il conteggio — da
    /// `duplicateFolderList`, ricalcolato insieme al resto in `rebuildBatch`.
    @State private var folderList: [(folder: String, count: Int)] = []
    /// Nome da mostrare per ogni cartella (maiuscole vere, `DuplicateBatch.folder(of:)`),
    /// perche' `folderList`/`DuplicateFilter` lavorano sulla chiave normalizzata
    /// (minuscola, NFC) e mostrarla cosi' com'e' sarebbe illeggibile e non ritrovabile nel
    /// Finder.
    @State private var folderDisplayNames: [String: String] = [:]
    /// Vero mentre filtro o regola vengono applicati fuori dal main: uno stato «sto
    /// applicando…» (`DuplicatesStatus.applyingLine`), non una barra — il ricalcolo dura
    /// pochi secondi su tutta la libreria, non minuti (Regola 9 del piano).
    @State private var isApplyingFilter = false

    /// La regola per cartella attiva, o `nil`. Caricata da `UserDefaults` una volta
    /// all'apertura della finestra (ADR-0011: persiste fra le sessioni) — un valore
    /// assente o corrotto decodifica a `nil` da `loadDuplicateFolderRule` stesso.
    @State private var folderRule: DuplicateFolderRule? = loadDuplicateFolderRule()
    @State private var showRuleEditor = false
    /// Campi temporanei dell'editor della regola, popolati da `folderRule` quando si apre
    /// la sheet — mai scritti in `folderRule` finche' l'utente non preme "Applica".
    @State private var ruleEditorKeepIn: String?
    @State private var ruleEditorTrashIn: Set<String> = []
    /// Quanti gruppi la regola attiva copre, e quanti la toccano ma restano fuori perche'
    /// hanno una copia anche in una terza cartella (spec §2.4/§2.5) — `nil` se non c'e'
    /// nessuna regola attiva.
    @State private var ruleCoverage: (covered: Int, excludedByThirdFolder: Int)? = nil

    private enum GroupKindFilter: Hashable { case all, sameFolder, crossFolder }

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
    /// Il piano della corsa (ADR-0012) per `pendingBatch`, congelato nello stesso istante e
    /// dalla stessa funzione (`beginConfirmation()`) — mai ricalcolato dentro `summarySheet`,
    /// che SwiftUI puo' richiamare a ogni ridisegno: `DuplicateRunPlan.init` gira su tutta la
    /// selezione, e ricalcolarlo nel `body` e' esattamente il bug del 2026-09-02 (regola 9).
    @State private var pendingPlan: DuplicateRunPlan? = nil
    @State private var showDestructiveConfirm = false

    /// Conferma non distruttiva prima di «Annulla l'ultimo spostamento» (ADR-0009, decisione
    /// 2 di Enrico): numero di foto e data, mai un semplice clic diretto — l'operazione ora
    /// dura minuti e ferma i backup per quel tempo.
    @State private var showUndoConfirm = false

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

            Label(DuplicatesStatus.mirrorsUntouchedNote(), systemImage: "externaldrive.badge.checkmark")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = trashDisabledReasonNow {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }

            filterBar

            if filter.internalOnly == true {
                Text(DuplicatesStatus.internalGroupsCriterionLine)
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isApplyingFilter {
                Text(DuplicatesStatus.applyingLine).font(AppFont.caption).foregroundStyle(.secondary)
            }

            listArea

            HStack {
                Button("Seleziona tutti quelli visibili") { selectAllVisible() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(visibleIndices.isEmpty)
                Button("Togli la selezione da quelli visibili") { deselectAllVisible() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(visibleIndices.isEmpty)
                Spacer()
            }

            selectionStatusLine

            if runner.isTrashingDuplicates, let progress = runner.duplicateRunProgress {
                duplicateRunProgressBar(progress)
            }

            if let outcome = runner.lastDuplicateRunOutcome {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(DuplicatesStatus.runOutcomeLines(outcome)) { line in
                        Text(line.text).font(AppFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if runner.isRestoringFromTrash, let progress = runner.trashRestoreProgress {
                trashRestoreProgressBar(progress)
            }

            if let outcome = runner.lastTrashRestoreOutcome {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(TrashRestoreStatus.outcomeLines(outcome)) { line in
                        Text(line.text).font(AppFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let reason = undoDisabledReasonNow {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Annulla l'ultimo spostamento") { showUndoConfirm = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(undoDisabledReasonNow != nil)

                Spacer()

                Button("Sposta nel Cestino…") { beginConfirmation() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!canRequestTrash)
            }
        }
        .padding(AppSpacing.lg)
        .frame(minWidth: 640, minHeight: 520)
        .task {
            // Rilegge l'elenco all'apertura solo se non c'e' un'operazione in corso che lo
            // rende un bersaglio in movimento (ROADMAP #41, D4) — vedi doc-comment su
            // `DuplicatesPanelLoad`. Scritto come booleano leggibile, non un'espressione
            // compressa dentro la chiamata.
            if DuplicatesPanelLoad.shouldLoadOnAppear(isIdle: loadStateIsIdle,
                                                       isTrashingDuplicates: runner.isTrashingDuplicates,
                                                       isRestoringFromTrash: runner.isRestoringFromTrash) {
                loadGroups()
            }
            runner.refreshRestorableBatch()
        }
        .onChange(of: runner.isRestoringFromTrash) { _, isRestoring in
            // A fine annullamento l'elenco potrebbe essere cambiato (le foto tornate a posto
            // non ricompaiono come doppioni finche' non si rifa' l'elenco, ma un blocco
            // interrotto puo' aver cambiato lo store): si ricarica come dopo uno spostamento.
            if !isRestoring { loadGroups() }
        }
        // Gemella di quella sopra, ma per lo spostamento — deliberatamente SEPARATA e non
        // fusa in un `if !isTrashing && !isRestoring` (rischio 5 della spec): le due
        // operazioni si escludono a vicenda, ma un `if` unico ricaricherebbe anche
        // all'apertura della finestra, non solo a fine operazione. Qui finisce quello che
        // prima stava nel blocco finale del `Task.detached` di `startTrashing`: le chiavi dei
        // file davvero cestinati sono gia' state tolte dall'elenco dentro `run(...)`, quindi
        // si rilegge per mostrare i gruppi rimasti.
        .onChange(of: runner.isTrashingDuplicates) { _, isTrashing in
            if !isTrashing {
                selectedHashes.removeAll()
                pendingBatch = nil
                pendingPlan = nil
                loadGroups()
            }
        }
        .sheet(isPresented: $showSummarySheet) {
            if let batch = pendingBatch { summarySheet(batch) }
        }
        .sheet(isPresented: $showRuleEditor) { ruleEditorSheet }
        .alert("Spostare queste copie nel Cestino?",
               isPresented: $showDestructiveConfirm,
               presenting: pendingBatch) { batch in
            Button("Sposta nel Cestino", role: .destructive) { startTrashing(batch) }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            // Rilievo di review del 2026-09-25: con più di un blocco (ADR-0012), «Annulla
            // l'ultimo spostamento» copre SOLO l'ultimo blocco — l'utente l'ha già letto in
            // `undoScopeLine` dentro il riepilogo, ma questo alert (l'ultimo schermo prima del
            // punto di non ritorno) diceva senza qualifica «puoi annullare lo spostamento dopo»,
            // contraddicendolo. Riusa `DuplicatesStatus.undoScopeLine` (già testata) invece di
            // scrivere qui una seconda frase sullo stesso fatto: con un blocco solo resta `nil`
            // e il testo è quello di sempre.
            let base = "Ogni copia viene riverificata sul disco un'ultima volta prima di essere spostata. "
            if let scope = DuplicatesStatus.undoScopeLine(blockCount: pendingPlan?.blocks.count ?? 1,
                                                           fileCapPerBlock: duplicateBatchFileCap) {
                Text(base + scope)
            } else {
                Text(base + "Puoi annullare lo spostamento dopo, con «Annulla l'ultimo spostamento».")
            }
        }
        .alert(undoConfirmationText?.title ?? "Rimettere a posto le foto?",
               isPresented: $showUndoConfirm) {
            Button("Rimetti a posto") { startUndo() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(undoConfirmationText?.message ?? "")
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
        // Lettura O(1) dal batch gia' calcolato — vedi doc-comment su `loadedBatch`.
        let groupCount = loadedBatch?.groups.count ?? 0
        let reclaimableBytes = loadedBatch?.reclaimableBytes ?? 0
        return Text(DuplicatesStatus.headerLine(indexBuilt: indexBuilt,
                                                groupsKnown: loadedBatch != nil,
                                                groupCount: groupCount,
                                                reclaimableBytes: reclaimableBytes).text)
            .font(AppFont.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var trashDisabledReasonNow: String? {
        DuplicatesStatus.trashDisabledReason(isRunning: runner.isRunning,
                                             isIndexing: runner.isIndexing,
                                             ssdMounted: volumes.ssdMounted,
                                             isTrashingDuplicates: runner.isTrashingDuplicates,
                                             isRestoringFromTrash: runner.isRestoringFromTrash,
                                             isInventorying: runner.isInventorying,
                                             isRepairing: runner.isRepairing)
    }

    private var canRequestTrash: Bool {
        trashDisabledReasonNow == nil && !selectedHashes.isEmpty && !runner.isTrashingDuplicates
    }

    /// Letto da `.task` per `DuplicatesPanelLoad.shouldLoadOnAppear` — scritto come booleano
    /// leggibile invece che dentro un `if case` compresso nella chiamata.
    private var loadStateIsIdle: Bool {
        if case .idle = loadState { return true }
        return false
    }

    /// Perche' «Annulla l'ultimo spostamento» e' disattivato adesso, o `nil` se si puo'
    /// premere. `hasEverTrashed` distingue "non hai mai spostato niente da qui" da "l'ultimo
    /// spostamento e' gia' stato annullato" — due frasi diverse per lo stesso `nil` di
    /// `restorableBatch`.
    private var undoDisabledReasonNow: String? {
        DuplicatesStatus.undoDisabledReason(
            ssdMounted: volumes.ssdMounted, isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            summary: runner.restorableBatch, hasEverTrashed: (runner.trashManifestStore?.totalRecorded ?? 0) > 0,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing)
    }

    private var undoConfirmationText: TrashRestoreStatus.Confirmation? {
        guard let summary = runner.restorableBatch else { return nil }
        return TrashRestoreStatus.confirmation(summary: summary)
    }

    /// La barra dei filtri (Task 11, Step 1). Tre controlli discreti, come da spec §2.2 —
    /// nessun campo di testo: cercare per testo su 141.683 percorsi a ogni tasto premuto e'
    /// il profilo esatto del bug di prestazioni del 2026-09-02.
    private var filterBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Menu {
                Button("Tutte (\(loadedBatch?.groups.count ?? 0))") { setFolder(nil) }
                if !folderList.isEmpty { Divider() }
                ForEach(folderList, id: \.folder) { entry in
                    Button("\(folderDisplayNames[entry.folder] ?? entry.folder) (\(entry.count))") {
                        setFolder(entry.folder)
                    }
                }
            } label: {
                Label(filter.folder.map { folderDisplayNames[$0] ?? $0 } ?? "Tutte le cartelle",
                     systemImage: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize()

            Picker("", selection: Binding(get: { groupKindSelection }, set: { setGroupKind($0) })) {
                Text("Tutti").tag(GroupKindFilter.all)
                Text("Tutte le copie nella stessa cartella").tag(GroupKindFilter.sameFolder)
                Text("Copie in cartelle diverse").tag(GroupKindFilter.crossFolder)
            }
            .pickerStyle(.menu)
            .fixedSize()

            if folderRule != nil {
                Toggle("Solo i gruppi coperti dalla regola", isOn: Binding(
                    get: { filter.rule != nil },
                    set: { setRuleFilterOnly($0) }
                )).toggleStyle(.checkbox)
            }

            Spacer()

            Button(folderRule == nil ? "Regola per cartella…" : "Modifica regola…") {
                ruleEditorKeepIn = folderRule?.keepIn
                ruleEditorTrashIn = folderRule?.trashIn ?? []
                showRuleEditor = true
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var groupKindSelection: GroupKindFilter {
        switch filter.internalOnly {
        case .some(true): return .sameFolder
        case .some(false): return .crossFolder
        case .none: return .all
        }
    }

    /// «Selezionati N gruppi: M file da spostare, circa X GB recuperabili» (Task 9,
    /// `DuplicatesStatus.selectionLine`) — valori tutti precalcolati, mai un `reduce` qui.
    private var selectionStatusLine: some View {
        Text(DuplicatesStatus.selectionLine(visibleGroups: visibleIndices.count,
                                            totalGroups: loadedBatch?.groups.count ?? 0,
                                            selectedGroups: selectedHashes.count,
                                            files: selectionStats.files,
                                            reclaimableBytes: selectionStats.bytes))
            .font(AppFont.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// L'editor della regola per cartella (Task 11, Step 3, ADR-0011).
    private var ruleEditorSheet: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Regola per cartella").font(AppFont.title)
            Text("Scegli una cartella da tenere e una o più cartelle da cestinare: un gruppo "
                + "con una copia in ognuna e nessun'altra copia altrove verrà proposto così, "
                + "senza dover spuntarlo a mano.")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Tieni la copia in", selection: $ruleEditorKeepIn) {
                Text("Scegli…").tag(String?.none)
                ForEach(folderList, id: \.folder) { entry in
                    Text(folderDisplayNames[entry.folder] ?? entry.folder).tag(String?.some(entry.folder))
                }
            }

            Text("Sposta nel Cestino le copie in:").font(AppFont.body)
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(folderList, id: \.folder) { entry in
                        if entry.folder != ruleEditorKeepIn {
                            Toggle(folderDisplayNames[entry.folder] ?? entry.folder, isOn: Binding(
                                get: { ruleEditorTrashIn.contains(entry.folder) },
                                set: { on in
                                    if on { ruleEditorTrashIn.insert(entry.folder) }
                                    else { ruleEditorTrashIn.remove(entry.folder) }
                                }
                            )).toggleStyle(.checkbox)
                        }
                    }
                }
            }.frame(maxHeight: 180)

            if isApplyingFilter {
                Text(DuplicatesStatus.applyingLine).font(AppFont.caption).foregroundStyle(.secondary)
            } else if let coverage = ruleCoverage {
                Text(DuplicatesStatus.ruleCoverageLine(covered: coverage.covered,
                                                       excludedByThirdFolder: coverage.excludedByThirdFolder))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if folderRule != nil {
                    Button("Rimuovi regola", role: .destructive) {
                        ruleEditorKeepIn = nil
                        ruleEditorTrashIn = []
                        applyRule(nil)
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Chiudi") { showRuleEditor = false }.buttonStyle(.bordered)
                Button("Applica") {
                    guard let keepIn = ruleEditorKeepIn, !ruleEditorTrashIn.isEmpty else { return }
                    applyRule(DuplicateFolderRule(keepIn: keepIn, trashIn: ruleEditorTrashIn))
                }
                .buttonStyle(.borderedProminent)
                .disabled(ruleEditorKeepIn == nil || ruleEditorTrashIn.isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .frame(minWidth: 460, minHeight: 420)
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
        case .loaded:
            // `loadedBatch`, non una ricostruzione da `groups` — vedi doc-comment sul
            // `@State`. `loadState`/`loadedBatch` sono pubblicati insieme in `loadGroups()`,
            // quindi sono sempre coerenti quando si arriva qui. L'elenco mostrato e'
            // `visibleIndices`, non `batch.groups` per intero (Task 11, Step 1): un semplice
            // giro su un array di indici gia' calcolato, non un filtro dentro il `body`.
            if let batch = loadedBatch, !visibleIndices.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(visibleIndices, id: \.self) { i in
                            let entry = batch.groups[i]
                            DuplicateGroupRow(entry: entry,
                                              isSelected: selectedHashes.contains(entry.group.hash),
                                              libraryRootPath: BookmarkManager.shared.urls[.ssd]?.path,
                                              cache: thumbnailCache) {
                                toggleSelection(entry.group.hash)
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
    }

    /// Barra di avanzamento di una **corsa** a piu' blocchi (Task 10/11, ADR-0012) — non di
    /// un blocco solo: `DuplicatesStatus.runProgressLine` conta i file di TUTTA la corsa, non
    /// del solo blocco in esecuzione.
    private func duplicateRunProgressBar(_ progress: (blockIndex: Int, blockCount: Int, filesDone: Int, filesTotal: Int)) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ProgressView(value: Double(progress.filesDone), total: Double(max(progress.filesTotal, 1)))
            HStack {
                Text(DuplicatesStatus.runProgressLine(blockIndex: progress.blockIndex, blockCount: progress.blockCount,
                                                       filesDone: progress.filesDone, filesTotal: progress.filesTotal))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                if runner.duplicateRunStopRequested {
                    Text(DuplicatesStatus.trashStoppingLine)
                        .font(AppFont.caption).foregroundStyle(.secondary)
                } else {
                    Button("Interrompi") { runner.stopDuplicateTrashRun() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private func trashRestoreProgressBar(_ progress: (done: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            HStack {
                Text(TrashRestoreStatus.progressLine(done: progress.done, total: progress.total))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                if runner.trashRestoreStopRequested {
                    Text(TrashRestoreStatus.stoppingLine)
                        .font(AppFont.caption).foregroundStyle(.secondary)
                } else {
                    Button("Interrompi") { runner.stopTrashRestore() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
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

            // Il piano della corsa (ADR-0012) e — solo se piu' di un blocco — la frase
            // sull'annullamento a un livello: Enrico deve saperlo PRIMA di confermare, non
            // scoprirlo dopo un guasto a meta' corsa. `pendingPlan` e' gia' calcolato,
            // congelato insieme a `batch` in `beginConfirmation()` — mai ricalcolato qui,
            // che SwiftUI puo' richiamare a ogni ridisegno (regola 9).
            if let plan = pendingPlan {
                Text(DuplicatesStatus.runPlanLine(blockCount: plan.blocks.count, files: batch.fileCount,
                                                  estimatedSeconds: plan.estimatedSeconds))
                    .font(AppFont.body)
                if let undoScope = DuplicatesStatus.undoScopeLine(blockCount: plan.blocks.count,
                                                                   fileCapPerBlock: duplicateBatchFileCap) {
                    Text(undoScope).font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Annulla") { showSummarySheet = false }.buttonStyle(.bordered)
                Button("Continua…") {
                    showSummarySheet = false
                    showDestructiveConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(trashDisabledReasonNow != nil)
            }
        }
        .padding(AppSpacing.xl)
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Azioni

    private func toggleSelection(_ hash: String) {
        if selectedHashes.contains(hash) { selectedHashes.remove(hash) } else { selectedHashes.insert(hash) }
        recomputeSelectionStats()
    }

    /// «Seleziona tutti quelli visibili» (Task 11, Step 2, spec §2.3) — sul solo insieme
    /// filtrato, mai su tutti i gruppi. La selezione **sopravvive** al cambio di filtro: qui
    /// si aggiunge soltanto, non si sostituisce l'insieme selezionato.
    private func selectAllVisible() {
        guard let loadedBatch else { return }
        for i in visibleIndices { selectedHashes.insert(loadedBatch.groups[i].group.hash) }
        recomputeSelectionStats()
    }

    private func deselectAllVisible() {
        guard let loadedBatch else { return }
        for i in visibleIndices { selectedHashes.remove(loadedBatch.groups[i].group.hash) }
        recomputeSelectionStats()
    }

    /// Ricalcola i totali della selezione **solo sull'insieme selezionato**, mai filtrando
    /// di nuovo tutti i gruppi (Regola 9): `entryByHash` da' l'`Entry` di ogni hash selezionato
    /// in O(1), quindi il costo e' proporzionale a quanto e' selezionato, non alla libreria.
    private func recomputeSelectionStats() {
        var files = 0
        var bytes: Int64 = 0
        for hash in selectedHashes {
            guard let entry = entryByHash[hash] else { continue }
            files += entry.leaving.count
            bytes += entry.reclaimableBytes
        }
        selectionStats = (files, bytes)
    }

    private func setFolder(_ folder: String?) {
        filter.folder = folder
        reapplyFilter()
    }

    private func setGroupKind(_ kind: GroupKindFilter) {
        switch kind {
        case .all: filter.internalOnly = nil
        case .sameFolder: filter.internalOnly = true
        case .crossFolder: filter.internalOnly = false
        }
        reapplyFilter()
    }

    private func setRuleFilterOnly(_ on: Bool) {
        filter.rule = on ? folderRule : nil
        reapplyFilter()
    }

    /// Ricalcola solo l'insieme filtrato (`rebuildBatch` senza toccare il blocco stesso): un
    /// cambio di filtro non cambia mai la scelta di chi tenere, quindi non serve
    /// ricostruire `DuplicateBatch` — solo `DuplicateFilter.apply(to:)` sul batch che c'e'
    /// gia'. Usa comunque `Task.detached` con lo stato «sto applicando…» (Regola 9): alla
    /// scala reale anche un solo `filter` su 27.798 gruppi non va fatto nel `body`.
    private func reapplyFilter() {
        guard let loadedBatch else { return }
        isApplyingFilter = true
        let currentFilter = filter
        let groupsOnly = loadedBatch.groups.map(\.group)
        Task.detached(priority: .utility) {
            let indices = currentFilter.apply(to: groupsOnly)
            await MainActor.run {
                self.visibleIndices = indices
                self.isApplyingFilter = false
            }
        }
    }

    /// Applica (o rimuove) la regola per cartella: persiste la scelta, **azzera la
    /// selezione** (spec §2.6 — una selezione fatta su una proposta e confermata su
    /// un'altra e' lo stesso difetto che questo pannello esiste per chiudere), e ricostruisce
    /// il blocco una volta, fuori dal main.
    private func applyRule(_ rule: DuplicateFolderRule?) {
        folderRule = rule
        saveDuplicateFolderRule(rule)
        selectedHashes.removeAll()
        selectionStats = (0, 0)
        showRuleEditor = false
        guard case .loaded(let groups) = loadState else { return }
        rebuildBatch(from: groups, rule: rule)
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
        let rule = folderRule
        Task.detached(priority: .utility) {
            do {
                let groups = try store.duplicateGroups()
                await MainActor.run {
                    self.loadState = .loaded(groups)
                    self.rebuildBatch(from: groups, rule: rule)
                }
            } catch {
                await MainActor.run {
                    self.loadState = .failed("Non è stato possibile leggere l'elenco delle copie doppie: "
                        + error.localizedDescription)
                }
            }
        }
    }

    /// Ricostruisce `DuplicateBatch`, l'elenco delle cartelle, l'indice per hash, l'insieme
    /// filtrato e — se una regola e' attiva — quanti gruppi copre, **sempre insieme, fuori
    /// dal main**, con uno stato «sto applicando…» (Regola 9 della spec): filtro e regola
    /// non toccano mai i 27.798 gruppi dentro il `body`. `duplicateKeepChoice` gira qui
    /// dentro (via `DuplicateBatch(groups:rule:)`), **una volta sola**, esattamente come
    /// prima — non e' un secondo posto che scelga fra i membri di un gruppo, e' l'unico
    /// posto, chiamato di nuovo perche' la regola e' cambiata.
    private func rebuildBatch(from rawGroups: [DuplicateGroup], rule: DuplicateFolderRule?) {
        isApplyingFilter = true
        let currentFilter = filter
        Task.detached(priority: .utility) {
            let batch = DuplicateBatch(groups: rawGroups, rule: rule)
            let groupsOnly = batch.groups.map(\.group)
            let folders = duplicateFolderList(groupsOnly)
            var byHash: [String: DuplicateBatch.Entry] = [:]
            var displayNames: [String: String] = [:]
            for entry in batch.groups {
                byHash[entry.group.hash] = entry
                for member in entry.group.members {
                    guard let key = topLevelFolderKey(of: member.path), displayNames[key] == nil else { continue }
                    displayNames[key] = DuplicateBatch.folder(of: member)
                }
            }
            let indices = currentFilter.apply(to: groupsOnly)
            var coverage: (covered: Int, excludedByThirdFolder: Int)? = nil
            if let rule {
                let covered = groupsOnly.filter { rule.covers($0) }.count
                let excluded = groupsOnly.filter { g in
                    guard !rule.covers(g) else { return false }
                    return g.members.contains(where: {
                        guard let f = topLevelFolderKey(of: $0.path) else { return false }
                        return f == rule.keepIn || rule.trashIn.contains(f)
                    })
                }.count
                coverage = (covered, excluded)
            }
            // Snapshot immutabili prima del salto sul main: `byHash`/`displayNames`/`coverage`
            // sono `var` mutate qui sopra, e Swift 6 non permette di catturarle cosi' come
            // sono in una chiusura che esegue concorrentemente (`await MainActor.run`) — lo
            // stesso fix di `startDuplicateTrashRun` nel runner (Task 10).
            let finalByHash = byHash
            let finalDisplayNames = displayNames
            let finalCoverage = coverage
            await MainActor.run {
                self.loadedBatch = batch
                self.folderList = folders
                self.folderDisplayNames = finalDisplayNames
                self.entryByHash = finalByHash
                self.visibleIndices = indices
                self.ruleCoverage = finalCoverage
                self.isApplyingFilter = false
                // Difesa, non l'azzeramento richiesto dalla spec (quello lo fa `applyRule`
                // ESPLICITAMENTE, prima di arrivare qui): un hash selezionato che non esiste
                // piu' nel batch appena ricostruito (rilettura dopo un annullamento, un
                // gruppo scomparso) non deve restare a contare in `selectionStats`.
                self.selectedHashes = self.selectedHashes.filter { finalByHash[$0] != nil }
                self.recomputeSelectionStats()
            }
        }
    }

    /// Congela il blocco selezionato e apre il riepilogo — la prima delle due conferme
    /// (decisione 4 di Enrico). Il blocco non viene piu' ricalcolato da qui in avanti: la
    /// stessa istanza arriva fino a `startTrashing(_:)`.
    ///
    /// **Filtra le `Entry` gia' congelate di `loadedBatch`, non ricostruisce dai gruppi
    /// grezzi** (fix del difetto latente di ADR-0011, 2026-09-25): `DuplicateBatch(entries:)`
    /// non richiama mai `duplicateKeepChoice` — quella e' gia' stata decisa una volta sola in
    /// `loadGroups()`. Ricostruire da `DuplicateBatch(groups:rule:)` qui aprirebbe un secondo
    /// posto in cui la scelta di quale copia tenere potrebbe, in futuro, divergere da quella
    /// mostrata nella lista — la classe di errore che questo progetto ha gia' pagato tre
    /// volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).
    ///
    /// **Deviazione dichiarata dal piano (Task 11 Step 5, 2026-09-25)**: resta sincrona sul
    /// main, non "fuori dal main se la selezione e' grande". E' un `filter` su un array di
    /// `Entry` gia' calcolate (non un `init(groups:)`, che e' il costo che causo' l'incidente
    /// del 2026-09-02) — costo non misurato sul caso peggiore (27.798 gruppi selezionati). Vedi
    /// la nota nel piano prima di "correggerlo" senza prima misurarlo.
    private func beginConfirmation() {
        guard let loadedBatch else { return }
        let selected = loadedBatch.groups.filter { selectedHashes.contains($0.group.hash) }
        guard !selected.isEmpty else { return }
        let batch = DuplicateBatch(entries: selected)
        pendingBatch = batch
        pendingPlan = DuplicateRunPlan(entries: batch.groups)
        showSummarySheet = true
    }

    /// Avvia lo spostamento nel Cestino, dopo la doppia conferma: avvia
    /// `BackupRunner.startDuplicateTrashRun` (Task 10, ADR-0012) sul piano gia' calcolato in
    /// `beginConfirmation()`, che gira fuori dal main tramite il runner e smaltisce la corsa
    /// un blocco alla volta. Barra, «Interrompi» ed esito arrivano da li' — la selezione e
    /// l'elenco si ricaricano da `.onChange(of: runner.isTrashingDuplicates)` sopra, non da
    /// qui. Simmetrica a `startUndo()` sotto.
    private func startTrashing(_ batch: DuplicateBatch) {
        let plan = pendingPlan ?? DuplicateRunPlan(entries: batch.groups)
        runner.startDuplicateTrashRun(plan, onAlert: { pendingAlert = $0 })
    }

    /// «Annulla l'ultimo spostamento», dopo la conferma non distruttiva: avvia
    /// `TrashRestorer.run` fuori dal main tramite il runner (ADR-0009). Barra, «Interrompi»
    /// ed esito arrivano da li' — questa funzione fa solo partire.
    private func startUndo() {
        runner.startTrashRestore(onAlert: { pendingAlert = $0 })
    }
}

/// Una riga della lista: checkbox, miniatura del file tenuto, spiegazione della scelta, e le
/// copie che se ne andrebbero — con quelle a pari merito con la tenuta marcate visivamente
/// (`DuplicateKeepChoice.tiedPaths`), cosi' la frase di `duplicateKeepExplanation` non deve
/// indovinare a quale riga si riferisce.
/// Le righe del campione d'integrita', in logica pura — stesso ruolo di `LibraryIndexStatus`,
/// `DuplicatesStatus` e `ImportPreviewStatus`.
///
/// Nasce da un difetto trovato il 2026-09-03: la view mostrava solo `matched/checked` e
/// **buttava via due contatori**, `skippedNoSource` e `skippedUnreadable`.
///
/// - `skippedNoSource` diventa normale e frequente **dopo il pannello Doppioni**: il campione
///   enumera l'HDD e cerca il gemello sull'SSD, e i doppioni tolti dall'SSD non ce l'hanno
///   piu'. Non e' un guasto — e' esattamente quello che Enrico ha chiesto (l'HDD tiene tutto,
///   l'SSD no) — ma tacerlo fa sembrare il campione piu' piccolo di quanto richiesto senza
///   dire perche'.
/// - `skippedUnreadable` e' invece un **sospetto vero**: il file c'e' ma non si e' riusciti a
///   leggerlo. Nasconderlo era la cosa peggiore delle due.
enum IntegritySummary {
    /// `ok` = niente da segnalare, `info` = spiegazione neutra, `warning` = merita attenzione.
    enum Tone { case ok, info, warning }
    struct Line: Identifiable { let id: String; let tone: Tone; let text: String }

    static func lines(for r: IntegrityCheckResult) -> [Line] {
        if let error = r.error {
            return [Line(id: "error", tone: .warning, text: "\(r.pairName): saltato — \(error)")]
        }

        var out: [Line] = []

        if r.mismatches.isEmpty {
            out.append(Line(id: "esito", tone: .ok, text:
                "\(r.pairName): \(r.matched) su \(r.checked) verificati, nessuna differenza."))
        } else {
            out.append(Line(id: "esito", tone: .warning, text:
                "\(r.pairName): \(r.mismatches.count) su \(r.checked) verificati NON corrispondono — "
                + r.mismatches.prefix(3).joined(separator: ", ")))
        }

        if r.skippedNoSource > 0 {
            out.append(Line(id: "senza-origine", tone: .info, text:
                "\(r.skippedNoSource) file del backup non esistono più sull'SSD e non sono stati "
                + "confrontati. È normale se hai tolto delle copie doppie: il backup le conserva "
                + "comunque, ed è quello che deve fare."))
        }

        if r.skippedUnreadable > 0 {
            out.append(Line(id: "illeggibili", tone: .warning, text:
                "\(r.skippedUnreadable) file esistono ma non si sono lasciati leggere: non è stato "
                + "possibile confrontarli. Vale la pena controllarli a mano."))
        }

        return out
    }
}

/// Dice a parole se questo file **resta** o **va nel Cestino**, invece di lasciarlo dedurre
/// dalla posizione nella lista. Rilievo di Enrico del 2026-09-03: davanti a un'operazione che
/// sposta file veri, una freccia e un rientro non bastano a capire cosa si sta confermando.
private struct DuplicateRoleBadge: View {
    enum Kind { case kept, leaving }
    let kind: Kind

    var body: some View {
        Text(kind == .kept ? "RESTA" : "NEL CESTINO")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(kind == .kept ? AppColor.success : AppColor.warning)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill((kind == .kept ? AppColor.success : AppColor.warning).opacity(0.15)))
            .accessibilityLabel(kind == .kept ? "Questa copia resta sull'SSD"
                                              : "Questa copia viene spostata nel Cestino")
    }
}

/// «Mostra nel Finder» per un singolo file. **È l'unico modo che ha l'utente di verificare con
/// i propri occhi** cosa sta per spostare, invece di fidarsi di una riga di testo: apre il
/// Finder con il file gia' selezionato, cosi' puo' aprirlo, guardarlo con Anteprima, e
/// decidere. Nessuna scrittura, nessun effetto sul file — solo `activateFileViewerSelecting`.
private struct RevealInFinderButton: View {
    let url: URL?

    var body: some View {
        Button {
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "magnifyingglass.circle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(url == nil)
        .help("Mostra nel Finder")
    }
}

/// Dimensione esatta e hash di UN file del gruppo, letti direttamente da
/// `LibraryIndexEntry` — nessun calcolo, sono gia' nel record dell'indice.
///
/// Nasce dal rilievo di Enrico del 2026-09-02: la view mostrava solo la spiegazione a
/// parole di quale copia teneva e i percorsi delle altre, senza numeri con cui
/// verificare a occhio "sono davvero lo stesso file?". L'hash mostrato qui e' quello
/// dell'INDICE (livello 1, ADR-0003) — una cache che puo' essere stantia (ADR-0002) — non
/// e' la riprova crittografica che decide se cestinare: quella resta la rilettura dal
/// disco al momento del blocco (ADR-0005), invariata. Questa riga serve a **far vedere**
/// il dato che gia' esiste, non a spostare la decisione qui.
///
/// Hash troncato a 12 caratteri esadecimali: basta a un confronto visivo fra righe
/// (un SHA256 vero che collide sui primi 12 caratteri per caso non e' uno scenario
/// realistico), e un hash intero da 64 caratteri renderebbe la riga illeggibile.
private struct DuplicateFileDetail: View {
    let entry: LibraryIndexEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
            Text("·").foregroundStyle(.tertiary)
            // La data c'e' perche' la spiegazione della scelta la CITA («ha la data piu'
            // vecchia») mentre la riga non la mostrava: l'utente leggeva un'affermazione che
            // non poteva verificare. Rilievo di Enrico del 2026-09-03.
            Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: entry.mtime)))
            Text("·").foregroundStyle(.tertiary)
            Text(String(entry.hash.prefix(12)))
                .font(.system(.caption2, design: .monospaced))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

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

    private var keeperURL: URL? { url(for: entry.choice.keeper) }

    /// Percorso su disco di un qualunque membro del gruppo. Serve a "Mostra nel Finder",
    /// che e' l'unico modo che ha Enrico di verificare **con i propri occhi** cosa sta per
    /// spostare, invece di fidarsi di una riga di testo (rilievo del 2026-09-03).
    private func url(for member: LibraryIndexEntry) -> URL? {
        guard let libraryRootPath else { return nil }
        return URL(fileURLWithPath: libraryRootPath).appendingPathComponent(member.displayPath)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            thumbnailView

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    // Etichetta esplicita, non solo una posizione nella lista. Rilievo di
                    // Enrico del 2026-09-03: "non si capisce cosa stia eliminando o meno".
                    // La distinzione fra la copia tenuta e quelle in uscita era affidata a
                    // una freccia e a un rientro — troppo poco davanti a un'operazione che
                    // sposta file veri.
                    DuplicateRoleBadge(kind: .kept)
                    Text(entry.choice.keeper.displayPath).font(AppFont.body)
                        .lineLimit(1).truncationMode(.middle)
                    RevealInFinderButton(url: url(for: entry.choice.keeper))
                }

                // Dimensione e hash del file TENUTO, per esteso — rilievo di Enrico del
                // 2026-09-02: prima della sola frase di spiegazione non c'era modo di
                // verificare a occhio cosa stesse per essere spostato. Valori letti
                // direttamente da `LibraryIndexEntry`, nessun calcolo nuovo: sono gia' nel
                // record dell'indice. L'hash e' il livello 1 di fiducia (ADR-0003) — quello
                // che DECIDE se cestinare e' sempre la rilettura al momento del blocco
                // (ADR-0005), questa riga e' solo per farla vedere a chi guarda, non
                // sostituisce quella verifica.
                DuplicateFileDetail(entry: entry.choice.keeper)

                Text(duplicateKeepExplanation(entry.choice, in: entry.group))
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(entry.leaving, id: \.path) { leaving in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpacing.xs) {
                            DuplicateRoleBadge(kind: .leaving)
                            Text(leaving.displayPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            RevealInFinderButton(url: url(for: leaving))
                            if entry.choice.tiedPaths.contains(leaving.path) {
                                Text("· pari merito con la tenuta")
                                    .font(.caption2).italic().foregroundStyle(AppColor.warning)
                            }
                        }
                        DuplicateFileDetail(entry: leaving).padding(.leading, AppSpacing.md)
                    }
                }
            }
            Spacer()
        }
        .padding(AppSpacing.sm)
        .cardBackground()
        .task(id: entry.group.hash) { await loadThumbnail() }
    }

    // `.allowsHitTesting(false)`: con `scaledToFill` un fotogramma 16:9 sborda di ~28 punti
    // oltre il riquadro da 72, e `clipShape` taglia solo il disegno, non l'area che riceve
    // i clic. Quella parte invisibile copriva la casella accanto: dopo il caricamento delle
    // miniature le caselle non si spuntavano piu' (2026-09-26).
    private var thumbnailView: some View {
        thumbnailImage.allowsHitTesting(false)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable().scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    // Sulla miniatura di un video resta un segno che lo dice: il fotogramma
                    // da solo non distingue una foto da un filmato.
                    if isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(3)
                    }
                }
        } else {
            Image(systemName: isVideo ? "video.fill" : "photo")
                .frame(width: 72, height: 72)
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
        let kind = IndexableKind.of(url: url)
        guard kind == .image || kind == .video else { return }
        let token = UUID()
        loadToken = token
        let image: NSImage?
        if kind == .video {
            // `makeVideoThumbnail` e' gia' asincrona e AVFoundation lavora per conto suo
            // fuori dal main thread: non serve incapsularla in un `Task.detached`.
            image = await makeVideoThumbnail(url: url, maxPixelSize: 160)
        } else {
            image = await Task.detached(priority: .utility) {
                makeThumbnail(url: url, maxPixelSize: 160)
            }.value
        }
        // Scartata se questa riga e' stata riusata per un altro gruppo nel frattempo
        // (scroll di una `LazyVStack`).
        guard loadToken == token else { return }
        if let image { cache.insert(image, for: key) }
        thumbnail = image
    }
}

// MARK: - Pannello Inventario (ROADMAP #44, ADR-0015)

/// La finestra "Inventario": per ogni contenuto foto/video, in quale dei tre posti (SSD, HDD,
/// Cubbit) c'e' davvero, e cosa non torna. L'inventario e' SOLA LETTURA; l'unico bottone che
/// scrive e' «Ripara…» sulle voci riparabili in ❗ (ROADMAP #45, ADR-0016): una foto alla volta,
/// dopo un riepilogo e una conferma.
///
/// **NON coperta da test** (stessa dichiarazione di `DuplicatesView` e `LibraryIndexCard`):
/// questa view, il gate Touch ID, l'apertura della finestra. E' testato tutto cio' che sta ai
/// due capi del cablaggio: `InventoryStatus` (testi), `InventoryStartGate`, `InventorySummary`/
/// `InventoryClassifier`, `InventoryRefresh`.
struct InventoryView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    @EnvironmentObject private var runner: BackupRunner
    @ObservedObject private var volumes = VolumeMonitor.shared

    /// Avvisi LOCALI della finestra (vedi `AlertSink`): `runner.pendingAlert` ha un solo
    /// presentatore, nella finestra principale.
    @State private var alert: SimpleAlert? = nil
    @State private var expanded: Set<InventoryCategory> = []
    /// La voce di cui si sta leggendo il riepilogo (stato della conversazione: resta nella view,
    /// regola D3 di ROADMAP #41). `confirmRepair` passa la voce all'alert dopo la chiusura del
    /// foglio, perche' un alert non si presenta mentre un foglio si sta chiudendo.
    @State private var pendingRepair: RepairCandidate? = nil
    @State private var confirmRepair: RepairCandidate? = nil

    var body: some View {
        if gate.touchIDEnabled && !gate.unlocked {
            LockScreenView()
        } else {
            content
        }
    }

    private var startDisabledReason: String? {
        InventoryStartGate.blockedReason(
            isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted,
            hasCubbitConfig: runner.s3Config != nil)
    }

    private var repairDisabledReason: String? {
        RepairStartGate.blockedReason(
            isRunning: runner.isRunning, isIndexing: runner.isIndexing,
            isTrashingDuplicates: runner.isTrashingDuplicates, isRestoringFromTrash: runner.isRestoringFromTrash,
            isInventorying: runner.isInventorying, isRepairing: runner.isRepairing,
            ssdMounted: volumes.ssdMounted, hddMounted: volumes.hddMounted, hasCubbitConfig: runner.s3Config != nil)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Inventario").font(AppFont.title)
            Label(InventoryStatus.readOnlyNote, systemImage: "eye")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = runner.inventorySummary {
                lineView(InventoryStatus.freshnessLine(states: summary.states, now: Date()))
                ForEach(InventoryArchive.allCases, id: \.self) { archive in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(InventoryStatus.archiveLine(archive, stats: summary.stats[archive] ?? InventoryArchiveStats()))
                            .font(AppFont.body)
                        if let line = InventoryStatus.completenessLine(archive, state: summary.states[archive]) {
                            lineView(line)
                        }
                    }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(InventoryStatus.displayOrder, id: \.self) { category in
                            categoryRow(category, summary: summary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(InventoryStatus.loadingLine).font(AppFont.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(AppSpacing.lg)
        .frame(minWidth: 560, minHeight: 480, alignment: .topLeading)
        .task {
            runner.loadInventoryIfNeeded()
            runner.refreshRepairRecords()
        }
        .sheet(item: $pendingRepair, onDismiss: {
            guard let c = confirmRepair else { return }
            confirmRepair = nil
            alert = SimpleAlert(title: RepairStatus.confirmTitle, message: RepairStatus.confirmMessage(c),
                                isDestructive: true, confirmTitle: RepairStatus.confirmButton,
                                cancelTitle: RepairStatus.cancelButton,
                                onConfirm: { runner.startRepair(c, dryRun: false, onAlert: { alert = $0 }) })
        }) { c in
            repairSummarySheet(c)
        }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        ), presenting: alert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle { Button(cancelTitle, role: .cancel) {} }
        } message: { a in
            Text(a.message)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: InventoryCategory, summary: InventorySummary) -> some View {
        let count = summary.count(category)
        // «Non si puo' ancora dire» compare solo se c'e' qualcosa: non e' una categoria della
        // spec, e' il posto dei contenuti su cui il giudizio e' sospeso.
        if category != .undetermined || count > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(category) },
                set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } }
            )) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(InventoryStatus.explanation(category))
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if category == .toCheck && !summary.repairCandidates.isEmpty {
                        repairSection(summary)
                    }
                    let items = summary.samples[category] ?? []
                    ForEach(items) { item in
                        Text(InventoryStatus.itemLine(item))
                            .font(AppFont.caption)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let more = InventoryStatus.sampleLimitLine(shown: items.count, total: count) {
                        Text(more).font(AppFont.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, AppSpacing.md)
            } label: {
                Text(InventoryStatus.categoryLine(category, count: count, bytes: summary.bytes(category)))
                    .font(AppFont.body)
            }
        }
    }

    /// Le voci riparabili, in testa a ❗: tutte (sono poche), ognuna con «Ripara…», con la riga
    /// del passo in corso, o con «riparata il …» finche' un nuovo inventario non la conferma.
    @ViewBuilder
    private func repairSection(_ summary: InventorySummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(RepairStatus.sectionTitle(count: summary.repairCandidates.count)).font(AppFont.body)
            Text(RepairStatus.sectionExplanation)
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.repairCandidates) { c in
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(RepairStatus.candidateLine(c))
                        .font(AppFont.caption)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: AppSpacing.sm)
                    if let done = RepairStatus.awaitingConfirmation(c, records: runner.repairRecords, states: summary.states) {
                        Label(RepairStatus.repairedLine(done), systemImage: "checkmark.circle.fill")
                            .font(AppFont.caption).foregroundStyle(AppColor.success)
                    } else if runner.repairingKey == c.key {
                        HStack(spacing: AppSpacing.xs) {
                            ProgressView().controlSize(.small)
                            Text(RepairStatus.progressLine(runner.repairStep)).font(AppFont.caption)
                        }
                    } else {
                        Button(RepairStatus.buttonTitle) { pendingRepair = c }
                            .disabled(repairDisabledReason != nil)
                    }
                }
            }
            if let reason = repairDisabledReason, !runner.isRepairing {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = runner.lastRepairOutcome {
                ForEach(RepairStatus.outcomeLines(outcome)) { lineView($0) }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    /// Il riepilogo prima della conferma (decisione 3 di Enrico): «Continua…» chiude il foglio e
    /// apre la conferma vera, con il bottone distruttivo; «Controlla senza riparare» fa solo il
    /// ricontrollo (S11).
    private func repairSummarySheet(_ c: RepairCandidate) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(RepairStatus.summaryTitle).font(AppFont.title)
            ForEach(Array(RepairStatus.summaryLines(c, date: Date(), calendar: RepairPaths.defaultCalendar).enumerated()),
                    id: \.offset) { _, line in
                Text(line).font(AppFont.body).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(RepairStatus.cancelButton, role: .cancel) { pendingRepair = nil }
                    .keyboardShortcut(.cancelAction)
                // Regola 4 di `Docs/CLAUDE.md` (S11): lo stesso ricontrollo, senza scrivere niente.
                Button(RepairStatus.dryRunButton) {
                    pendingRepair = nil
                    runner.startRepair(c, dryRun: true, onAlert: { alert = $0 })
                }
                .disabled(repairDisabledReason != nil)
                Button(RepairStatus.continueButton) {
                    confirmRepair = c
                    pendingRepair = nil
                }
                .disabled(repairDisabledReason != nil)
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 520)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if runner.isInventorying {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(runner.inventoryStopRequested
                         ? InventoryStatus.stoppingLine
                         : runner.inventoryProgress.map { InventoryStatus.progressLine($0) } ?? InventoryStatus.progressLine(.checkingCubbit))
                        .font(AppFont.caption)
                }
                Button(InventoryStatus.stopButton) { runner.stopInventoryRefresh() }
                    .disabled(runner.inventoryStopRequested)
            } else {
                Button(InventoryStatus.refreshButton) {
                    runner.startInventoryRefresh(onAlert: { alert = $0 })
                }
                .disabled(startDisabledReason != nil)
                if let reason = startDisabledReason {
                    Label(reason, systemImage: "info.circle")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lineView(_ line: InventoryStatus.Line) -> some View {
        Label(line.text, systemImage: line.tone == .ok ? "checkmark.circle.fill"
              : line.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(AppFont.caption)
            .foregroundStyle(line.tone == .ok ? AppColor.success : line.tone == .warning ? AppColor.warning : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
