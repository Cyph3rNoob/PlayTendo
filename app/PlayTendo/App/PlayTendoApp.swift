import SwiftUI

@main
struct PlayTendoApp: App {
    @StateObject private var library = GameLibrary()
    @StateObject private var metadata = GameMetadata()
    @StateObject private var jit = JITManager()
    @State private var showBoot = true

    init() {
        Paths.prepare()
        PTLogSetFile(Paths.logFile.path)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        PTLogLine("PlayTendo \(version) démarré — iOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                LibraryView()
                if showBoot {
                    BootView { showBoot = false }
                        .zIndex(1)
                }
            }
            .environmentObject(library)
            .environmentObject(metadata)
            .environmentObject(jit)
            .preferredColorScheme(.dark)
            .tint(.playTendoAccent)
            .onOpenURL { url in library.importFiles([url]) }
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

extension Color {
    static let playTendoAccent = Color(red: 1.0, green: 0.36, blue: 0.40)
}
