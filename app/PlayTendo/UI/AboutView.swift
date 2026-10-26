import SwiftUI

/// « À propos » : l'essentiel pour se servir de l'app (jeux, BIOS, jeu, jeu à plusieurs, succès, turbo, sauvegardes,
/// confidentialité, dépannage), puis les crédits.
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
        Engine(name: "Gambatte", version: "0.5.0 (7809bb6)", consoles: "Game Boy, Game Boy Color", license: "GPL-2.0",
               system: .gb),
        Engine(name: "mGBA", version: "0.10.5", consoles: "Game Boy Advance", license: "MPL-2.0", system: .gba),
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
                    Label(tr("App Fichiers › Sur mon iPhone › PlayTendo › Jeux, ou le bouton « + » de la bibliothèque : fichiers, dossiers, .zip, .7z et .rar."),
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

                if RomPatch.systems.contains(where: EmulatorSession.engineInstalled) {
                    Section(tr("Romhacks")) {
                        Label(tr("Une romhack déjà patchée (.z64, .sfc, .gba…) se joue comme n'importe quel jeu."),
                              systemImage: "checkmark.circle")
                        Label(tr("Un patch (.ips, .bps, .ups) : pose-le dans Jeux avec le jeu d'origine. Il apparaît comme un jeu à part, avec ses sauvegardes."),
                              systemImage: "bandage")
                        Label(tr("Le jeu d'origine n'est jamais modifié : le patch s'applique à une copie au lancement, et un même jeu peut servir à plusieurs romhacks."),
                              systemImage: "lock.shield")
                        Label(tr("Un .bps ou un .ups trouve son jeu d'origine tout seul (ROM N64 en .z64, .v64 ou .n64 ; ROM SNES avec ou sans en-tête). Un .ips, par le nom : « Super Mario World (USA) Kaizo.ips » va avec « Super Mario World (USA).sfc »."),
                              systemImage: "magnifyingglass")
#if os(iOS)
                        Label(tr("Pas de jaquette ? Appui long sur le jeu › Choisir une jaquette."), systemImage: "photo")
#else
                        Label(tr("Pas de jaquette ? Clic droit sur le jeu › Choisir une jaquette."), systemImage: "photo")
#endif
                        Label(tr("Consoles : NES, Super Nintendo, N64, Game Boy et Color, GBA, DS. Un patch absent de la bibliothèque : son jeu d'origine manque, ou ce n'est pas la bonne version."),
                              systemImage: "questionmark.circle")
                    }
                }

                Section(tr("Jouer")) {
#if os(iOS)
                    Label(tr("Avance rapide et retour en arrière : de ×2 à ×5, au choix par un appui long sur leur bouton du menu pause."),
                          systemImage: "forward")
#else
                    Label(tr("Avance rapide et retour en arrière : de ×2 à ×5, au choix par un clic droit sur leur bouton du menu pause."),
                          systemImage: "forward")
#endif
                    Label(tr("« Continuer » reprend la partie là où tu l'as quittée. Si une reprise fait planter le jeu, elle est mise de côté et le jeu repart du début la fois suivante."),
                          systemImage: "clock.arrow.circlepath")
                    if EmulatorSession.engineInstalled(for: .nds) {
                        Label(tr("DS : RÉSOLUTION x1 (par défaut) dessine la 3D exactement comme la console ; x2 à x4 sont plus nets, mais quelques jeux y montrent des textures étirées (Pokémon Noire)."),
                              systemImage: "rectangle.split.1x2")
                    }
                }

                if EmulatorSession.engineInstalled(for: .gb) || EmulatorSession.engineInstalled(for: .nds) {
                    Section(tr("Jouer à plusieurs")) {
                        if EmulatorSession.engineInstalled(for: .gb) {
                            Label(tr("Game Boy et Color : câble link entre deux appareils proches (même pièce, Wi-Fi et Bluetooth activés, pas besoin du même réseau). L'un héberge, l'autre rejoint (menu pause › Câble link) ; l'hôte accepte ou refuse chaque appareil. Une fois accepté, les deux parties reprennent et le câble se branche ; pendant un échange, ne mets pas un jeu en pause (l'autre attendrait, figé)."),
                                  systemImage: "cable.connector")
                        }
                        if EmulatorSession.engineInstalled(for: .nds) {
                            Label(tr("DS en ligne : la Connexion Wi-Fi Nintendo est remplacée par des serveurs de passionnés (Réglages › Nintendo DS en ligne ; Kaeru WFC pour les Pokémon)."),
                                  systemImage: "wifi")
                        }
                        Label(tr("Deux manettes : la deuxième joue le joueur 2 sur les consoles de salon."), systemImage: "person.2")
                    }
                }

                Section("RetroAchievements") {
                    Label(tr("Des succès à débloquer en jouant, avec ton compte gratuit retroachievements.org (Réglages › RetroAchievements). PlayTendo garde seulement un jeton de connexion, jamais ton mot de passe."),
                          systemImage: "trophy")
                    Label(tr("Il faut la version exacte du jeu reconnue par RetroAchievements (No-Intro, Redump) : sinon, un message le dit au lancement."),
                          systemImage: "checkmark.seal")
                    Label(tr("Hardcore : les succès comptent davantage, mais chargement des sauvegardes rapides, retour arrière et codes de triche sont coupés."),
                          systemImage: "flame")
                }

                if EmulatorSession.engineInstalled(for: .n3ds) {
                    Section(tr("Homebrews 3DS")) {
                        Label(tr("Importe leur archive telle quelle : le .3dsx va dans la bibliothèque, et leur dossier 3ds/ sur la carte SD de la 3DS (Sauvegardes › 3DS › Azahar › sdmc)."),
                              systemImage: "sdcard")
                        Label(tr("Le son des homebrews marche sans rien ajouter. Certains changent d'image quand le relief est activé : menu pause › CURSEUR 3D › Levé (Emerald3DS : son monde en voxels, avec aussi ses propres réglages sur l'écran du bas)."),
                              systemImage: "cube")
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
                    // StikDebug reste le parcours de compatibilité pour les versions d'iOS antérieures à iOS 26
                    // et pour LiveContainer.
                    Label {
                        Text(markdown: tr("Sur iOS 26 ou plus, choisis StikJIT intégré dans les réglages; avant iOS 26 ou dans LiveContainer, il faut [StikDebug](https://stikdebug.xyz/) et [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044). Le JIT s'active tout seul au lancement d'un jeu compatible."))
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

                Section(tr("Confidentialité")) {
                    Label(tr("Tes jeux, BIOS et sauvegardes ne quittent jamais ton appareil."), systemImage: "lock.shield")
                    Label(tr("Internet sert seulement à : jaquettes et fiches des jeux (le nom du jeu), codes de triche téléchargés, RetroAchievements (si tu te connectes), jeu en ligne DS et câble link (si tu t'en sers). Toujours par connexion chiffrée."),
                          systemImage: "network")
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
                    Text(tr("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : ScreenScraper (screenscraper.fr), puis libretro-thumbnails et SteamGridDB en secours. Codes de triche : libretro-database (cht, CC BY-SA 4.0), Dolphin, codes.rc24.xyz, pcsx2_cheats_collection et CheatDevicePS2 (GPL-3.0). Succès : rcheevos de RetroAchievements (MIT). Archives : libarchive 3.8.9 (BSD-2-Clause) et xz 5.8.4 (0BSD). Polices : Orbitron et Press Start 2P (OFL). Turbo : StikJIT intégré (MPL-2.0) et StikDebug."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
#else
                    Text(tr("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : ScreenScraper (screenscraper.fr), puis libretro-thumbnails et SteamGridDB en secours. Codes de triche : libretro-database (cht, CC BY-SA 4.0), Dolphin, codes.rc24.xyz, pcsx2_cheats_collection et CheatDevicePS2 (GPL-3.0). Succès : rcheevos de RetroAchievements (MIT). Archives : libarchive 3.8.9 (BSD-2-Clause) et xz 5.8.4 (0BSD). Polices : Orbitron et Press Start 2P (OFL). Turbo : StikJIT intégré (MPL-2.0) et StikDebug."))
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
