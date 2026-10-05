import SwiftUI

@main
struct PlayTendoApp: App {
    @StateObject private var library = GameLibrary()

    init() {
        Paths.prepare()
        PTLogSetFile(Paths.logFile.path)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        PTLogLine("PlayTendo \(version) démarré — iOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
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
/// Tests dans le simulateur : lancer l'app avec « -PTLandscape » la bascule en paysage.
private func forceLandscapeForTesting() {
    guard ProcessInfo.processInfo.arguments.contains("-PTLandscape"),
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
        PTLogLine("Rotation de test impossible : \(error.localizedDescription)")
    }
}
#endif

extension Color {
    static let playTendoAccent = Color(red: 1.0, green: 0.36, blue: 0.40)
    static let playTendoBackground = Color(red: 0.05, green: 0.05, blue: 0.08)
}
