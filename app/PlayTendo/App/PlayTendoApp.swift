import SwiftUI

@main
struct PlayTendoApp: App {
    @StateObject private var library = GameLibrary()
    @StateObject private var metadata = GameMetadata()
    @StateObject private var jit = JITManager()
    @State private var showBoot = true
    @AppStorage(WelcomeView.seenKey) private var welcomeSeen = 0
    /// Thème : mode clair ou sombre (heure, batterie, feuilles du système) et couleur des boutons du système.
    @AppStorage(AppTheme.key) private var theme = AppTheme.neon
    @Environment(\.scenePhase) private var scenePhase
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
#endif

    init() {
#if os(macOS)
        // Mac : le dossier PlayTendo n'existe pas encore au tout premier lancement (le journal y est écrit).
        try? FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
#endif
        // Journal d'abord : la préparation des dossiers peut y écrire (effacement des données de la PS Vita).
        PTLogSetFile(Paths.logFile.path)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
#if os(iOS)
        PTLogLine("PlayTendo \(version) démarré — iOS \(UIDevice.current.systemVersion)")
#else
        PTLogLine("PlayTendo \(version) démarré — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        MacAppDelegate.registerFonts()
#endif
        Paths.prepare()
        BootSound.prepare()
    }

    var body: some Scene {
#if os(iOS)
        WindowGroup {
            content
        }
#else
        // Une seule fenêtre : un seul moteur peut tourner à la fois.
        Window("PlayTendo", id: "main") {
            content
                .frame(minWidth: 720, minHeight: 520)
                // Mode turbo : sur Mac, l'app prépare elle-même sa mémoire dès l'ouverture, s'il sert à une console.
                .task {
                    if GameSystem.allCases.contains(where: { JITManager.benefits($0) && EmulatorSession.engineInstalled(for: $0) }) {
                        try? await jit.activate()
                    }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("Ajouter des jeux…")) {
                    NotificationCenter.default.post(name: .playTendoImportGames, object: nil)
                }
                .keyboardShortcut("o")
                Button(tr("Afficher le dossier PlayTendo")) {
                    NSWorkspace.shared.open(Paths.documents)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(tr("Réglages…")) {
                    NotificationCenter.default.post(name: .playTendoShowSettings, object: nil)
                }
                .keyboardShortcut(",")
            }
        }
#endif
    }

    private var content: some View {
        ZStack {
            LibraryView()
            // Présentation : sous l'animation de démarrage, qui s'efface en la dévoilant.
            if welcomeSeen < WelcomeView.version {
                WelcomeView { withAnimation(.easeOut(duration: 0.3)) { welcomeSeen = WelcomeView.version } }
                    .transition(.opacity)
                    .zIndex(1)
            }
            if showBoot {
                BootView { showBoot = false }
                    .zIndex(2)
            }
        }
        .environmentObject(library)
        .environmentObject(metadata)
        .environmentObject(jit)
        .preferredColorScheme(theme.colorScheme)
        .tint(Neon.tint)
#if os(iOS)
        .onOpenURL { url in library.importFiles([url]) }
#else
        .onOpenURL { url in FinderOpen.receive([url]) }
#endif
        // En arrière-plan, iOS peut arrêter l'app sans prévenir : le journal est mis à jour sur le disque avant.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { PTLogFlush() }
        }
#if DEBUG && os(iOS)
        .onAppear(perform: forceLandscapeForTesting)
#endif
    }
}

#if os(macOS)
extension Notification.Name {
    /// Barre des menus : « Ajouter des jeux… » (⌘O) et « Réglages… » (⌘,), reçus par la bibliothèque.
    static let playTendoImportGames = Notification.Name("PlayTendoImportGames")
    static let playTendoShowSettings = Notification.Name("PlayTendoShowSettings")
}

/// Jeux ouverts depuis le Finder (double-clic, « Ouvrir avec », dépôt sur l'icône du Dock) : gardés ici jusqu'à ce que
/// la bibliothèque les prenne (l'app peut avoir été lancée par cette ouverture), qui les ajoute puis lance le jeu.
@MainActor
enum FinderOpen {
    static let notification = Notification.Name("PlayTendoOpenFiles")
    private static var pending: [URL] = []
    private static var recent: [(url: URL, time: Date)] = []

    static func receive(_ urls: [URL]) {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.time) > 2 }
        // Le même fichier peut arriver deux fois (délégué de l'app et SwiftUI) : une seule fois suffit.
        let new = urls.filter { url in !recent.contains { $0.url == url } }
        guard !new.isEmpty else { return }
        recent += new.map { (url: $0, time: now) }
        pending += new
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func take() -> [URL] {
        defer { pending = [] }
        return pending
    }
}

/// Mac : l'app se ferme avec sa fenêtre, après avoir arrêté proprement la partie en cours (sauvegarde du jeu écrite).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var replied = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        FinderOpen.receive(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = EmulatorSession.active else { return .terminateNow }
        switch session.state {
        case .stopped, .failed: return .terminateNow
        default: break
        }
        PTLogLine("Fermeture de PlayTendo : arrêt de la partie en cours")
        replied = false
        session.stop { [self] in DispatchQueue.main.async { self.reply() } }
        // Moteur qui ne s'arrête pas : l'app se ferme quand même.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in reply() }
        return .terminateLater
    }

    private func reply() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Moteurs GameCube/Wii et PS2 arrêtés en règle (manettes, réglages, cartes mémoire, journal) avant la sortie
        // du programme.
        PTDolphinEngine.loaded?.shutdown()
        PTPS2Engine.loaded?.shutdown()
        PTLogFlush()
    }

    /// Polices de l'app (Orbitron, Press Start 2P) : sur iPhone, Info.plist les déclare (UIAppFonts).
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
#endif

#if DEBUG && os(iOS)
/// Tests dans le simulateur : l'argument « -PTLandscape » ou un fichier Documents/PTLandscape
/// bascule l'app en paysage.
private func forceLandscapeForTesting() {
    let flag = FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent("PTLandscape").path)
    guard ProcessInfo.processInfo.arguments.contains("-PTLandscape") || flag,
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
        PTLogLine("Rotation de test impossible : \(error.localizedDescription)")
    }
}
#endif
