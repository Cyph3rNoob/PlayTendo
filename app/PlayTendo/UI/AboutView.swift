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

    private let engines: [Engine] = [
        Engine(name: "Mesen", version: "0.9.9", consoles: "NES", license: "GPL-3.0"),
        Engine(name: "bsnes", version: "v115", consoles: "Super Nintendo", license: "GPL-3.0"),
        Engine(name: "Mupen64Plus-Next", version: "3.0 (12edd2c)", consoles: "Nintendo 64", license: "GPL-2.0"),
        Engine(name: "DolphiniOS (Dolphin)", version: tr("5.0.0 bêta 6"), consoles: "GameCube, Wii", license: "GPL-2.0+"),
        Engine(name: "mGBA", version: "0.10.5", consoles: "Game Boy, Game Boy Color, Game Boy Advance", license: "MPL-2.0"),
        Engine(name: "melonDS DS", version: "1.4.0", consoles: "Nintendo DS", license: "GPL-3.0"),
        Engine(name: "Azahar", version: "2126.1.2", consoles: "Nintendo 3DS", license: "GPL-2.0+"),
        Engine(name: "MoltenVK", version: "1.4.2", consoles: AboutView.moltenVKConsoles, license: "Apache-2.0"),
        Engine(name: "PCSX-ReARMed", version: "r26", consoles: "PlayStation", license: "GPL-2.0"),
        Engine(name: "PPSSPP", version: "1.20.4", consoles: "PlayStation Portable", license: "GPL-2.0+"),
        Engine(name: "ARMSX2 (PCSX2)", version: "iOS 2.6.0", consoles: "PlayStation 2", license: "GPL-3.0"),
    ] + AboutView.vitaEngines

#if PLAYTENDO_VITA
    private static let vitaEngines = [Engine(name: "Vita3K", version: "build 4135 (681f695)", consoles: "PlayStation Vita", license: "GPL-2.0+")]
    private static var moltenVKConsoles: String { tr("Affichage de la 3DS et de la PS Vita (Vulkan vers Metal)") }
    private static var vitaFormats: [(console: String, files: String)] { [("PlayStation Vita", tr("dossier extrait de la console, .vpk"))] }
#else
    private static let vitaEngines: [Engine] = []
    private static var moltenVKConsoles: String { tr("Affichage de la 3DS (Vulkan vers Metal)") }
    private static let vitaFormats: [(console: String, files: String)] = []
#endif

    /// Formats acceptés, console par console (dans l'ordre de la bibliothèque).
    private let formats: [(console: String, files: String)] = [
        ("NES", ".nes"),
        ("Super Nintendo", ".sfc .smc"),
        ("Nintendo 64", ".z64 .n64 .v64"),
        ("GameCube", ".iso .rvz .gcm .wia .ciso .gcz"),
        ("Wii", ".iso .rvz .wbfs .wia .ciso .gcz"),
        ("Game Boy / Color / Advance", ".gb .gbc .gba"),
        ("Nintendo DS", ".nds"),
        ("Nintendo 3DS", tr(".3ds .cci .cxi .3dsx (décryptés)")),
        ("PlayStation", ".cue + .bin, .chd, .pbp, .m3u"),
        ("PlayStation 2", ".iso .chd .cso"),
        ("PlayStation Portable", ".iso .cso .pbp"),
    ] + AboutView.vitaFormats

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
                    Label(tr("App Fichiers › Sur mon iPhone › PlayTendo › Jeux, ou le bouton « + » de la bibliothèque (.zip, .7z et .rar acceptés)."),
                          systemImage: "folder")
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
                    Label(tr("PlayStation 2 : obligatoire. Le BIOS de ta console (fichier .bin de 4 Mo) : Réglages › BIOS PS2 › Importer, ou copié dans le dossier BIOS."),
                          systemImage: "exclamationmark.circle")
#if PLAYTENDO_VITA
                    Label(tr("PlayStation Vita : obligatoire. PSVUPDAT.PUP (mise à jour officielle de la console), et si possible ses polices PSP2UPDAT.PUP, dans le dossier BIOS."),
                          systemImage: "exclamationmark.circle")
#endif
                    Label(tr("PlayStation, DS, GBA : facultatifs. Les autres consoles n'en ont pas besoin."),
                          systemImage: "cpu")
                }

                Section(tr("Mode turbo")) {
#if PLAYTENDO_VITA
                    Label(tr("Obligatoire pour la PS Vita ; indispensable pour la PS2, la GameCube, la Wii et la 3DS ; accélère la PSP."),
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

                Section(tr("Sauvegardes")) {
                    Label(tr("Dans le jeu : enregistrées toutes seules dans le dossier Sauvegardes."), systemImage: "externaldrive")
#if PLAYTENDO_VITA
                    Label(tr("Rapides : menu pause › Sauvegarder / Charger (une par jeu ; pas sur PS Vita)."), systemImage: "clock.arrow.circlepath")
#else
                    Label(tr("Rapides : menu pause › Sauvegarder / Charger (une par jeu)."), systemImage: "clock.arrow.circlepath")
#endif
                    Label(tr("Mise à jour : installe la nouvelle version par-dessus. Supprimer l'app efface jeux et sauvegardes."),
                          systemImage: "arrow.down.app")
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
                    Text(tr("Reconnaissance des jeux : libretro-database (No-Intro, Redump). Jaquettes : libretro-thumbnails, et SteamGridDB en secours. Archives : libarchive 3.8.9 (BSD-2-Clause) et xz 5.8.4 (0BSD). Polices : Orbitron et Press Start 2P (OFL). Turbo : StikDebug (app à part)."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(tr("App personnelle, construite uniquement avec des logiciels libres. Aucun jeu ni BIOS n'est fourni : utilise les tiens."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .scrollContentBackground(.hidden)
            .background(CyberBackground())
            .navigationTitle(tr("À propos"))
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
                    .font(.display(26, weight: 900))
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
