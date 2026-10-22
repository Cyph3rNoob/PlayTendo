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
        /// Console servie par ce moteur : il n'est cité que s'il est dans l'app (sur Mac, les consoles arrivent
        /// étape par étape).
        let system: GameSystem
        var id: String { name }
    }

    private let engines: [Engine] = ([
        Engine(name: "Mesen", version: "0.9.9", consoles: "NES", license: "GPL-3.0", system: .nes),
        Engine(name: "bsnes", version: "v115", consoles: "Super Nintendo", license: "GPL-3.0", system: .snes),
        Engine(name: "Mupen64Plus-Next", version: "3.0 (12edd2c)", consoles: "Nintendo 64", license: "GPL-2.0", system: .n64),
        Engine(name: "DolphiniOS (Dolphin)", version: tr("5.0.0 bêta 6"), consoles: "GameCube, Wii", license: "GPL-2.0+",
               system: .gameCube),
        Engine(name: "mGBA", version: "0.10.5", consoles: "Game Boy, Game Boy Color, Game Boy Advance", license: "MPL-2.0",
               system: .gba),
        Engine(name: "melonDS DS", version: "1.4.0", consoles: "Nintendo DS", license: "GPL-3.0", system: .nds),
        Engine(name: "Azahar", version: "2126.1.2", consoles: "Nintendo 3DS", license: "GPL-2.0+", system: .n3ds),
        Engine(name: "MoltenVK", version: "1.4.2", consoles: AboutView.moltenVKConsoles, license: "Apache-2.0", system: .n3ds),
        Engine(name: "PCSX-ReARMed", version: "r26", consoles: "PlayStation", license: "GPL-2.0", system: .psx),
        Engine(name: "PPSSPP", version: "1.20.4", consoles: "PlayStation Portable", license: "GPL-2.0+", system: .psp),
        Engine(name: "ARMSX2 (PCSX2)", version: "iOS 2.6.0", consoles: "PlayStation 2", license: "GPL-3.0", system: .ps2),
    ] + AboutView.vitaEngines).filter { EmulatorSession.engineInstalled(for: $0.system) }

#if PLAYTENDO_VITA
    private static let vitaEngines = [Engine(name: "Vita3K", version: "build 4135 (681f695)", consoles: tr("PlayStation Vita (expérimental : encore peu stable)"),
                                             license: "GPL-2.0+", system: .vita)]
    private static var moltenVKConsoles: String { tr("Affichage de la 3DS et de la PS Vita (Vulkan vers Metal)") }
    private static var vitaFormats: [(systems: [GameSystem], console: String, files: String)] {
        [([.vita], "PlayStation Vita", tr("dossier extrait de la console, .vpk"))]
    }
#else
    private static let vitaEngines: [Engine] = []
    private static var moltenVKConsoles: String { tr("Affichage de la 3DS (Vulkan vers Metal)") }
    private static let vitaFormats: [(systems: [GameSystem], console: String, files: String)] = []
#endif

    /// Formats acceptés, console par console (dans l'ordre de la bibliothèque), pour les consoles de l'app.
    private let formats: [(systems: [GameSystem], console: String, files: String)] = ([
        ([.nes], "NES", ".nes"),
        ([.snes], "Super Nintendo", ".sfc .smc"),
        ([.n64], "Nintendo 64", ".z64 .n64 .v64"),
        ([.gameCube], "GameCube", ".iso .rvz .gcm .wia .ciso .gcz"),
        ([.wii], "Wii", ".iso .rvz .wbfs .wia .ciso .gcz"),
        ([.gb, .gbc, .gba], "Game Boy / Color / Advance", ".gb .gbc .gba"),
        ([.nds], "Nintendo DS", ".nds"),
        ([.n3ds], "Nintendo 3DS", tr(".3ds .cci .cxi .3dsx (décryptés)")),
        ([.psx], "PlayStation", ".cue + .bin, .chd, .pbp, .m3u"),
        ([.ps2], "PlayStation 2", ".iso .chd .cso"),
        ([.psp], "PlayStation Portable", ".iso .cso .pbp"),
    ] + AboutView.vitaFormats).filter { $0.systems.contains(where: EmulatorSession.engineInstalled) }

    /// Consoles de l'app (13 sur iPhone ; sur Mac, celles déjà arrivées).
    private var consoleCount: Int {
        GameSystem.allCases.filter(EmulatorSession.engineInstalled).count
    }

    /// Une des consoles qui profitent du mode turbo est dans l'app.
    private var hasTurboConsoles: Bool {
        GameSystem.allCases.contains { JITManager.benefits($0) && EmulatorSession.engineInstalled(for: $0) }
    }

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
                        Label(tr("Revoir la présentation"), systemImage: "sparkles")
                    }
                }

                Section(tr("Ajouter des jeux")) {
#if os(iOS)
                    Label(tr("App Fichiers › Sur mon iPhone › PlayTendo › Jeux, ou le bouton « + » de la bibliothèque (.zip, .7z et .rar acceptés)."),
                          systemImage: "folder")
#else
                    Label(tr("Le bouton « + » de la bibliothèque, ou glisse-les dans la fenêtre (.zip, .7z et .rar acceptés). Ils sont rangés dans le dossier Jeux (Réglages › Dossiers)."),
                          systemImage: "folder")
#endif
                    DisclosureGroup(tr("Formats acceptés")) {
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
                    if EmulatorSession.engineInstalled(for: .ps2) {
                        Label(tr("PlayStation 2 : obligatoire. Le BIOS de ta console (fichier .bin de 4 Mo) : Réglages › BIOS PS2 › Importer, ou copié dans le dossier BIOS."),
                              systemImage: "exclamationmark.circle")
                    }
#if PLAYTENDO_VITA
                    Label(tr("PlayStation Vita : obligatoire. PSVUPDAT.PUP (mise à jour officielle de la console), et si possible ses polices PSP2UPDAT.PUP, dans le dossier BIOS."),
                          systemImage: "exclamationmark.circle")
#endif
                    Label(tr("PlayStation, DS, GBA : facultatifs. Les autres consoles n'en ont pas besoin."),
                          systemImage: "cpu")
                }

#if os(macOS)
                if hasTurboConsoles {
                    Section(tr("Mode turbo")) {
                        Label(tr("Sur Mac, il s'active tout seul : rien à installer."), systemImage: "bolt.fill")
                    }
                }
#else
                Section(tr("Mode turbo")) {
#if PLAYTENDO_VITA
                    Label(tr("Indispensable pour la PS2, la PS Vita, la GameCube, la Wii et la 3DS ; accélère la PSP."),
                          systemImage: "bolt.fill")
#else
                    Label(tr("Indispensable pour la PS2, la GameCube, la Wii et la 3DS ; accélère la PSP."), systemImage: "bolt.fill")
#endif
                    // Liens : site officiel de StikDebug (celui de son dépôt GitHub) et page App Store de LocalDevVPN
                    // (vérifiés le 2026-10-07).
                    Label {
                        Text(markdown: tr("Il faut [StikDebug](https://stikdebug.xyz/) et [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044). Il s'active tout seul au lancement d'un de ces jeux, une fois par ouverture de PlayTendo (détails dans la roue dentée)."))
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
#endif

                Section(tr("Sauvegardes")) {
                    Label(tr("Dans le jeu : enregistrées toutes seules dans le dossier Sauvegardes."), systemImage: "externaldrive")
#if PLAYTENDO_VITA
                    Label(tr("Rapides : menu pause › Sauvegarder / Charger (une par jeu ; pas sur PS Vita)."), systemImage: "clock.arrow.circlepath")
#else
                    Label(tr("Rapides : menu pause › Sauvegarder / Charger (une par jeu)."), systemImage: "clock.arrow.circlepath")
#endif
#if os(iOS)
                    Label(tr("Mise à jour : installe la nouvelle version par-dessus. Supprimer l'app efface jeux et sauvegardes."),
                          systemImage: "arrow.down.app")
#else
                    Label(tr("Mise à jour : remplace l'app par la nouvelle version. Tes jeux et sauvegardes restent dans le dossier PlayTendo."),
                          systemImage: "arrow.down.app")
#endif
                }

                Section(tr("Un souci ?")) {
                    Label(tr("Un jeu ne démarre pas : vérifie son format, le BIOS (PS2) et le turbo."), systemImage: "questionmark.circle")
                    ShareLink(item: Paths.logFile) {
                        Label(tr("Partager le journal technique"), systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section(tr("Crédits")) {
                    DisclosureGroup(tr("Moteurs d'émulation et licences")) {
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
                                        .background(Neon.text.opacity(0.1), in: Capsule())
                                }
                                Text(engine.consoles)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
#if os(iOS)
                    Text(tr("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : ScreenScraper (screenscraper.fr), puis libretro-thumbnails et SteamGridDB en secours. Archives : libarchive 3.8.9 (BSD-2-Clause) et xz 5.8.4 (0BSD). Polices : Orbitron et Press Start 2P (OFL). Turbo : StikDebug (app à part)."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
#else
                    Text(tr("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : ScreenScraper (screenscraper.fr), puis libretro-thumbnails et SteamGridDB en secours. Archives : libarchive 3.8.9 (BSD-2-Clause) et xz 5.8.4 (0BSD). Polices : Orbitron et Press Start 2P (OFL)."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
#endif
                }

                Section {
                    Text(tr("Application construite uniquement avec des logiciels libres. Aucun jeu ni BIOS n'est fourni."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .scrollContentBackground(.hidden)
            .background(CyberBackground())
            .navigationTitle(tr("À propos"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 560, idealHeight: 720)
#endif
    }

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                if let logo = PlatformImage(named: "BootLogo") {
                    Image(platformImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .neonGlow(Neon.cyan, radius: 12)
                }
                Text("PLAYTENDO")
                    .font(.display(26, weight: 900))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                Text("VERSION \(appVersion) · \(consoleCount) CONSOLES")
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
