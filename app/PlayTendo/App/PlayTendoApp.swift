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

    init() {
        // Journal d'abord : la préparation des dossiers peut y écrire (effacement des données de la PS Vita).
        PTLogSetFile(Paths.logFile.path)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        PTLogLine("PlayTendo \(version) démarré — iOS \(UIDevice.current.systemVersion)")
        Paths.prepare()
        BootSound.prepare()
    }

    var body: some Scene {
        WindowGroup {
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
            .onOpenURL { url in library.importFiles([url]) }
            // En arrière-plan, iOS peut arrêter l'app sans prévenir : le journal est mis à jour sur le disque avant.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { PTLogFlush() }
            }
            #if DEBUG
            .onAppear(perform: forceLandscapeForTesting)
            #endif
        }
    }
}

#if DEBUG
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
