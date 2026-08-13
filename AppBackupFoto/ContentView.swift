import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit
import Charts
import ImageIO
import Sparkle

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

@main
struct BackupFotoEnricoApp: App {
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

        Window("Catalogo", id: "catalog") {
            CatalogView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)

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

    var body: some View {
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

struct RootView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    var body: some View {
        Group {
            if bm.canEnterApp { ContentView() }
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
            if let url = resolve(loc) { urls[loc] = url }
        }
    }

    var allConfigured: Bool { Location.allCases.allSatisfy { urls[$0] != nil } }
    // Solo la Libreria Foto è obbligatoria per entrare nell'app: SSD e HDD sono dischi
    // esterni che potrebbero non essere collegati in questo momento, e le operazioni
    // dentro ContentView già gestiscono da sole un volume non disponibile (bottone
    // disattivato) invece di bloccare tutto.
    var canEnterApp: Bool { urls[.photos] != nil }

    private func resolve(_ loc: Location) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "bk_\(loc.rawValue)") else { return nil }
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
                UserDefaults.standard.set(data, forKey: "bk_\(loc.rawValue)")
                self.urls[loc] = url
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

    // Solo il chiamante di onOutcome (il loop while sotto, a thread singolo) muta
    // stato condiviso: i task figli restituiscono un Outcome, non toccano nulla
    // di condiviso — nessun lock/actor necessario.
    static func runBounded<Item, Outcome>(
        items: [Item], maxConcurrent: Int,
        isCancelled: @escaping () -> Bool,
        operation: @escaping (Item) async -> Outcome,
        onOutcome: (Outcome) -> Void
    ) async {
        await withTaskGroup(of: Outcome.self) { group in
            var index = 0
            func addNext() {
                guard index < items.count, !isCancelled() else { return }
                let item = items[index]; index += 1
                group.addTask { await operation(item) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let outcome = await group.next() {
                onOutcome(outcome)
                addNext()
            }
        }
    }

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

        await S3Syncer.runBounded(
            items: toUpload, maxConcurrent: 4,
            isCancelled: { self.cancelled },
            operation: { [self] item -> (url: URL, size: Int64, ok: Bool) in
                if self.cancelled || Task.isCancelled { return (item.url, item.size, false) }
                DispatchQueue.main.async {
                    onStatus("Carico: \(item.url.lastPathComponent)")
                    onCurrentFile(item.url)
                }
                do {
                    try await self.upload(url: item.url, key: item.key, config: config, onStatus: onStatus)
                    return (item.url, item.size, true)
                } catch {
                    return (item.url, item.size, false)
                }
            },
            onOutcome: { outcome in
                if outcome.ok { result.uploaded += 1; result.uploadedBytes += outcome.size }
                else { result.errors += 1 }
                result.done += 1
                let snap = result
                DispatchQueue.main.async { onProgress(snap) }
            }
        )
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

    private func upload(url: URL, key: String, config: S3Config, onStatus: @escaping (String) -> Void) async throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 64 * 1024 * 1024 {
            try await multipart(url: url, key: key, config: config, onStatus: onStatus)
        } else {
            let data = try Data(contentsOf: url)
            try await retrying(key: key, onStatus: onStatus) {
                try await self.put(data: data, key: key, config: config)
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

    private func multipart(url: URL, key: String, config: S3Config, onStatus: @escaping (String) -> Void) async throws {
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

        let chunkSize = 64 * 1024 * 1024
        var parts: [(Int, String)] = []
        var pn = 1
        try await S3Syncer.readFileInChunks(path: url.path, chunkSize: chunkSize) { chunk in
            guard !self.cancelled else { return }
            guard let pURL = URL(string: "\(config.endpoint)/\(config.bucket)/\(encKey)?partNumber=\(pn)&uploadId=\(encId)") else {
                throw NSError(domain: "S3", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "URL non valido per parte \(pn) di \(key)"])
            }
            let partNumber = pn
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
            parts.append((partNumber, etag))
            pn += 1
        }

        if cancelled {
            _ = try? await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw CancellationError()
        }

        let partsXML = parts.map { "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>" }.joined()
        let completeXML = Data("<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
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
        if let httpError = error as? S3HTTPError { return !(400...499).contains(httpError.statusCode) }
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
    }

    private func confirmQuit() {
        let a = NSAlert(); a.messageText = "Chiudere l'app?"
        a.informativeText = "I processi in corso verranno interrotti."
        a.alertStyle = .warning; a.addButton(withTitle: "Esci"); a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn {
            if runner.isRunning { runner.stop() }
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("Impostazioni").font(AppFont.title)
            Text("Modifica le cartelle selezionate").font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Toggle("Backup automatico Mac → SSD quando colleghi l'SSD", isOn: $autoBackupEnabled)
                Text("Appena colleghi l'SSD, se l'app è aperta, parte da sola l'aggiornamento da Foto a SSD.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppSpacing.xl)
            VStack(spacing: AppSpacing.md) {
                ForEach(BookmarkManager.Location.allCases) { loc in
                    LocationRow(location: loc) { bm.selectAndSave(loc) { _ in } }
                }
            }.padding(.horizontal, AppSpacing.xl)
            Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(AppSpacing.xxl).frame(minWidth: 480)
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
    @State private var showSecret = false
    @State private var lastJob: JobSummary? = JobHistoryStore.load()
    @State private var integrityResults: [IntegrityCheckResult] = []
    @State private var integrityRunning = false
    @State private var integrityStatus = ""
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
        let a = NSAlert()
        a.messageText = "Rivelare le credenziali S3?"
        a.informativeText = "Chiunque veda o registri lo schermo in questo momento potrà usarle per scrivere o cancellare file sul bucket. Continua solo se sei sicuro che nessuno stia guardando."
        a.alertStyle = .warning
        a.addButton(withTitle: "Continua")
        a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn { action() }
    }

    var body: some View {
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
                                let ok = NSAlert()
                                ok.messageText = "Credenziali aggiornate nel Keychain."
                                ok.runModal()
                            } catch {
                                let err = NSAlert()
                                err.messageText = "Errore"
                                err.informativeText = error.localizedDescription
                                err.alertStyle = .critical
                                err.runModal()
                            }
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
                                    let a = NSAlert()
                                    a.messageText = "Eliminare questo upload incompleto?"
                                    a.informativeText = "Rimuove definitivamente le parti già caricate su Cubbit per '\((upload.key as NSString).lastPathComponent)'. Non tocca file già completati né la sorgente."
                                    a.alertStyle = .warning
                                    a.addButton(withTitle: "Elimina")
                                    a.addButton(withTitle: "Annulla")
                                    guard a.runModal() == .alertFirstButtonReturn else { return }
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
                                                let errA = NSAlert()
                                                errA.messageText = "Impossibile eliminare l'upload"
                                                errA.informativeText = error.localizedDescription
                                                errA.alertStyle = .critical
                                                errA.runModal()
                                            }
                                        }
                                    }
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
