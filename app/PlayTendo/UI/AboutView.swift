import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Engine: Identifiable {
        let name: String
        let version: String
        let consoles: String
        let license: String
        var id: String { name }
    }

    private let engines = [
        Engine(name: "Mesen", version: "0.9.9", consoles: "NES", license: "GPL-3.0"),
        Engine(name: "bsnes", version: "v115", consoles: "Super Nintendo", license: "GPL-3.0"),
        Engine(name: "Mupen64Plus-Next", version: "3.0 (12edd2c)", consoles: "Nintendo 64", license: "GPL-2.0"),
        Engine(name: "mGBA", version: "0.10.5", consoles: "Game Boy, Game Boy Color, Game Boy Advance", license: "MPL-2.0"),
        Engine(name: "melonDS DS", version: "1.4.0", consoles: "Nintendo DS", license: "GPL-3.0"),
        Engine(name: "PCSX-ReARMed", version: "r26", consoles: "PlayStation", license: "GPL-2.0"),
        Engine(name: "PPSSPP", version: "1.20.4", consoles: "PlayStation Portable", license: "GPL-2.0+"),
    ]

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                            .neonGlow(Neon.cyan, radius: 12)
                        Text("PLAYTENDO")
                            .font(.orbitron(26, weight: 900))
                            .tracking(2)
                            .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                        Text("VERSION \(appVersion)")
                            .font(Neon.mono(12, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(Neon.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section("Moteurs d'émulation") {
                    ForEach(engines) { engine in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(engine.name).font(.headline)
                                Text(engine.version).foregroundStyle(.secondary)
                                Spacer()
                                Text(engine.license)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            Text(engine.consoles)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Bibliothèque") {
                    Text("Jeux reconnus grâce à libretro-database (No-Intro et Redump), jaquettes de libretro-thumbnails, police Orbitron (licence OFL).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Mode turbo") {
                    Text("JIT de la PSP activé par l'app StikDebug (script universal.js), selon le protocole iOS 26 décrit par StikJIT.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Où sont mes fichiers ?") {
                    Label("App Fichiers › Sur mon iPhone › PlayTendo", systemImage: "folder")
                    Label("Jeux : tes jeux (sous-dossiers autorisés)", systemImage: "gamecontroller")
                    Label("BIOS : facultatifs (PS1, DS, GBA)", systemImage: "cpu")
                    Label("Sauvegardes : à copier pour les garder", systemImage: "externaldrive")
                }
                .font(.subheadline)

                Section("Dépannage") {
                    ShareLink(item: Paths.logFile) {
                        Label("Partager le journal technique", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section {
                    Text("PlayTendo est une app personnelle construite uniquement avec des logiciels libres. Aucun jeu ni BIOS n'est fourni.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CyberBackground())
            .navigationTitle("À propos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}
