import SwiftUI

/// « À propos » : l'essentiel pour se servir de l'app (jeux, BIOS, turbo, sauvegardes, dépannage), puis les crédits.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WelcomeView.seenKey) private var welcomeSeen = 0

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
        Engine(name: "DolphiniOS (Dolphin)", version: "5.0.0 bêta 6", consoles: "GameCube, Wii", license: "GPL-2.0+"),
        Engine(name: "mGBA", version: "0.10.5", consoles: "Game Boy, Game Boy Color, Game Boy Advance", license: "MPL-2.0"),
        Engine(name: "melonDS DS", version: "1.4.0", consoles: "Nintendo DS", license: "GPL-3.0"),
        Engine(name: "Azahar", version: "2126.1.2", consoles: "Nintendo 3DS", license: "GPL-2.0+"),
        Engine(name: "MoltenVK", version: "1.4.2", consoles: "Affichage de la 3DS (Vulkan vers Metal)", license: "Apache-2.0"),
        Engine(name: "PCSX-ReARMed", version: "r26", consoles: "PlayStation", license: "GPL-2.0"),
        Engine(name: "PPSSPP", version: "1.20.4", consoles: "PlayStation Portable", license: "GPL-2.0+"),
        Engine(name: "ARMSX2 (PCSX2)", version: "iOS 2.6.0", consoles: "PlayStation 2", license: "GPL-3.0"),
    ]

    /// Formats acceptés, console par console (dans l'ordre de la bibliothèque).
    private let formats: [(console: String, files: String)] = [
        ("NES", ".nes"),
        ("Super Nintendo", ".sfc .smc"),
        ("Nintendo 64", ".z64 .n64 .v64"),
        ("GameCube", ".iso .rvz .gcm .ciso .gcz"),
        ("Wii", ".iso .rvz .wbfs .ciso .gcz"),
        ("Game Boy / Color / Advance", ".gb .gbc .gba"),
        ("Nintendo DS", ".nds"),
        ("Nintendo 3DS", ".3ds .cci .cxi .3dsx (décryptés)"),
        ("PlayStation", ".cue + .bin, .chd, .pbp"),
        ("PlayStation 2", ".iso .chd .cso"),
        ("PlayStation Portable", ".iso .cso .pbp"),
    ]

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            List {
                header

                Section {
                    Button {
                        // La présentation réapparaît par-dessus la bibliothèque, une fois cette page fermée.
                        welcomeSeen = 0
                        dismiss()
                    } label: {
                        Label("Revoir la présentation", systemImage: "sparkles")
                    }
                }

                Section("Ajouter des jeux") {
                    Label("App Fichiers › Sur mon iPhone › PlayTendo › Jeux, ou le bouton « + » de la bibliothèque (.zip acceptés).",
                          systemImage: "folder")
                    DisclosureGroup("Formats acceptés") {
                        ForEach(formats, id: \.console) { format in
                            HStack(alignment: .firstTextBaseline) {
                                Text(format.console)
                                Spacer(minLength: 12)
                                Text(format.files)
                                    .font(Neon.mono(12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                Section("BIOS") {
                    Label("PlayStation 2 : obligatoire. Le BIOS de ta console (fichier .bin de 4 Mo) dans le dossier BIOS.",
                          systemImage: "exclamationmark.circle")
                    Label("PlayStation, DS, GBA : facultatifs. Les autres consoles n'en ont pas besoin.",
                          systemImage: "cpu")
                }

                Section("Mode turbo") {
                    Label("Indispensable pour la PS2, la GameCube, la Wii et la 3DS ; accélère la PSP.",
                          systemImage: "bolt.fill")
                    // Liens : site officiel de StikDebug (celui de son dépôt GitHub) et page App Store de LocalDevVPN
                    // (vérifiés le 2026-10-07).
                    Label {
                        Text("Il faut [StikDebug](https://stikdebug.xyz/) et [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044). Il s'active tout seul au lancement d'un de ces jeux, une fois par ouverture de PlayTendo (détails dans la roue dentée).")
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }

                Section("Sauvegardes") {
                    Label("Dans le jeu : enregistrées toutes seules dans le dossier Sauvegardes.", systemImage: "externaldrive")
                    Label("Rapides : menu pause › Sauvegarder / Charger (une par jeu).", systemImage: "clock.arrow.circlepath")
                    Label("Mise à jour : installe la nouvelle version par-dessus. Supprimer l'app efface jeux et sauvegardes.",
                          systemImage: "arrow.down.app")
                }

                Section("Un souci ?") {
                    Label("Un jeu ne démarre pas : vérifie son format, le BIOS (PS2) et le turbo.", systemImage: "questionmark.circle")
                    ShareLink(item: Paths.logFile) {
                        Label("Partager le journal technique", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("Crédits") {
                    DisclosureGroup("Moteurs d'émulation et licences") {
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
                    Text("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : libretro-thumbnails. Police : Orbitron (OFL). Turbo : StikDebug (app à part).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("App personnelle, construite uniquement avec des logiciels libres. Aucun jeu ni BIOS n'est fourni : utilise les tiens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
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

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                if let logo = UIImage(named: "BootLogo") {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .neonGlow(Neon.cyan, radius: 12)
                }
                Text("PLAYTENDO")
                    .font(.orbitron(26, weight: 900))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                Text("VERSION \(appVersion) · 13 CONSOLES")
                    .font(Neon.mono(12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Neon.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
}
