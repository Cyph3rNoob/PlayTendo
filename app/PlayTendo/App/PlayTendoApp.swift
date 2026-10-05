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
        }
    }
}

extension Color {
    static let playTendoAccent = Color(red: 1.0, green: 0.36, blue: 0.40)
    static let playTendoBackground = Color(red: 0.05, green: 0.05, blue: 0.08)
}
