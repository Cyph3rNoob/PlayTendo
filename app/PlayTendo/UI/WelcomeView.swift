import SwiftUI

/// Présentation de PlayTendo en 4 cartes (demandée le 2026-10-07) : montrée une fois après l'animation de démarrage
/// (premier lancement, et à chaque nouvelle version de la présentation), et depuis « À propos ».
struct WelcomeView: View {
    /// Version de la présentation déjà vue : l'augmenter la remontre une fois à tout le monde.
    static let seenKey = "presentationVue"
    static let version = 1

    let onFinish: () -> Void

    @State private var page = 0
    private var pageCount: Int { showsTurbo ? 4 : 3 }

#if os(iOS)
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    private let showsTurbo = true
#else
    private let device = "Mac"
    /// Sur Mac, la carte du mode turbo n'apparaît qu'avec une console qui s'en sert.
    private let showsTurbo = GameSystem.allCases.contains { JITManager.benefits($0) && EmulatorSession.engineInstalled(for: $0) }
#endif

    /// Consoles de l'app (sur Mac, celles déjà arrivées).
    private let systems = GameSystem.libraryGroups.filter { $0.groupMembers.contains(where: EmulatorSession.engineInstalled) }

    var body: some View {
        ZStack {
            CyberBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(tr("Passer"), action: onFinish)
                        .font(Neon.mono(14, weight: .semibold))
                        .foregroundStyle(Neon.dim)
                        .opacity(page < pageCount - 1 ? 1 : 0)
                        .disabled(page == pageCount - 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

#if os(iOS)
                TabView(selection: $page) {
                    intro.tag(0)
                    games.tag(1)
                    play.tag(2)
                    turbo.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
#else
                // Mac : une carte à la fois (les points du bas permettent de revenir en arrière).
                Group {
                    switch page {
                    case 0: intro
                    case 1: games
                    case 2: play
                    default: turbo
                    }
                }
                .id(page)
                .transition(.opacity)
#endif

                dots.padding(.bottom, 16)
                nextButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: 560)
        }
    }

    // MARK: Cartes

    private var intro: some View {
        WelcomeCard {
            VStack(spacing: 10) {
                if let logo = PlatformImage(named: "BootLogo") {
                    Image(platformImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .neonGlow(Neon.cyan, radius: 14)
                }
                Text("PLAYTENDO")
                    .font(.display(30, weight: 900))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                Text(tr("Tes jeux Nintendo et Sony, sur ton \(device)."))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Neon.text)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Text("\(GameSystem.displayOrder.filter(EmulatorSession.engineInstalled).count) CONSOLES")
                .font(.display(12, weight: 800))
                .tracking(2)
                .foregroundStyle(Neon.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 12) {
                ForEach(systems) { system in
                    SystemBadge(system: system, size: 11)
                }
            }
            if let resolutionText {
                WelcomeLine(icon: "sparkles", text: resolutionText)
            }
            if EmulatorSession.engineInstalled(for: .n64) {
                WelcomeLine(icon: "rectangle.ratio.16.to.9",
                            text: EmulatorSession.engineInstalled(for: .ps2)
                                ? tr("L'écran large 16:9 pour la N64 et la PS2.") : tr("L'écran large 16:9 pour la N64."))
            }
            WelcomeLine(icon: "clock.arrow.circlepath",
                        text: tr("Une sauvegarde rapide à tout moment, et « Continuer » pour reprendre là où tu t'étais arrêté."))
#if os(iOS)
            WelcomeLine(icon: "ipad.and.iphone", text: tr("Sur iPhone et iPad, avec les boutons à l'écran ou une manette."))
#else
            WelcomeLine(icon: "keyboard", text: tr("Au clavier ou à la manette (Switch, Xbox, PlayStation)."))
#endif
        }
    }

    /// « jusqu'à 4 fois la résolution (N64, DS…), 3 fois (GameCube, Wii) ou 2 fois (PS1) », d'après les consoles de
    /// l'app et le plus haut choix de leur réglage RÉSOLUTION (sur Mac, la 3DS et la PS Vita vont plus haut que sur
    /// iPhone). Nil si aucune console de l'app n'en a.
    private var resolutionText: String? {
        var groups: [(factor: Int, names: [String])] = []
        for system in GameSystem.displayOrder where EmulatorSession.engineInstalled(for: system) {
            guard let factor = Self.highestResolution(of: system) else { continue }
            if let index = groups.firstIndex(where: { $0.factor == factor }) {
                groups[index].names.append(Self.resolutionName(of: system))
            } else {
                groups.append((factor, [Self.resolutionName(of: system)]))
            }
        }
        groups.sort { $0.factor > $1.factor }
        let parts = groups.enumerated().map { index, group in
            let names = group.names.joined(separator: ", ")
            return index == 0 ? tr("\(group.factor) fois la résolution (\(names))") : tr("\(group.factor) fois (\(names))")
        }
        guard let last = parts.last else { return nil }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + tr(" ou ") + last : last
#if os(macOS)
        return tr("Une image plus fine qu'à l'origine : jusqu'à \(list), en fenêtre ou en plein écran.")
#else
        return tr("Une image plus fine qu'à l'origine : jusqu'à \(list).")
#endif
    }

    /// Plus haut choix du réglage RÉSOLUTION du menu pause (x4 → 4), ou nil pour une console sans ce réglage.
    private static func highestResolution(of system: GameSystem) -> Int? {
        switch system {
        case .n64: N64Settings.Resolution.allCases.map(\.rawValue).max()
        case .gameCube, .wii: DolphinSettings.Resolution.allCases.map(\.rawValue).max()
        case .nds: DSSettings.Resolution.allCases.map(\.rawValue).max()
        case .n3ds: N3DSSettings.Resolution.allCases.map(\.rawValue).max()
        case .psx: PS1Settings.Resolution.allCases.map(\.rawValue).max()
        case .ps2: PS2Settings.Resolution.allCases.map(\.rawValue).max()
        case .psp: PSPSettings.Resolution.allCases.map(\.rawValue).max()
#if PLAYTENDO_VITA
        case .vita: VitaSettings.Resolution.allCases.map(\.rawValue).max()
#endif
        default: nil
        }
    }

    private static func resolutionName(of system: GameSystem) -> String {
        switch system {
        case .gameCube: "GameCube"
#if PLAYTENDO_VITA
        case .vita: "PS Vita"
#endif
        default: system.shortName
        }
    }

    private var games: some View {
        WelcomeCard {
            WelcomeTitle(icon: "folder.fill", title: tr("AJOUTE TES JEUX"), color: Neon.cyan)
            WelcomeLine(icon: "info.circle", text: tr("PlayTendo ne contient aucun jeu : il fait tourner les tiens."))
#if os(iOS)
            WelcomeLine(icon: "folder", text: tr("Copie-les dans l'app Fichiers › Sur mon \(device) › PlayTendo › Jeux."))
            WelcomeLine(icon: "plus.circle", text: tr("Ou touche « + » dans la bibliothèque (les .zip, .7z et .rar marchent aussi)."))
#else
            WelcomeLine(icon: "folder", text: tr("Glisse-les dans la fenêtre de PlayTendo depuis le Finder."))
            WelcomeLine(icon: "plus.circle", text: tr("Ou clique sur « + » dans la bibliothèque (les .zip, .7z et .rar marchent aussi)."))
#endif
            if EmulatorSession.engineInstalled(for: .ps2) {
                WelcomeLine(icon: "cpu", text: tr("PlayStation 2 : importe aussi le BIOS de ta console (Réglages › BIOS PS2)."))
            }
        }
    }

    private var play: some View {
        WelcomeCard {
            WelcomeTitle(icon: "gamecontroller.fill", title: tr("JOUE"), color: Neon.magenta)
#if os(iOS)
            WelcomeLine(icon: "hand.tap", text: tr("Touche un jeu pour le lancer : des boutons apparaissent à l'écran."))
            WelcomeLine(icon: "gamecontroller",
                        text: tr("Une manette Bluetooth (Switch, Xbox, PlayStation) marche aussi : les boutons de l'écran s'effacent dès que tu t'en sers."))
            WelcomeLine(icon: "pause.circle", text: tr("Le bouton menu met le jeu en pause : sauvegarde rapide, options, quitter."))
#else
            WelcomeLine(icon: "cursorarrow.click", text: tr("Clique sur un jeu pour le lancer ; les touches du clavier sont dans les Réglages."))
            WelcomeLine(icon: "gamecontroller", text: tr("Une manette Bluetooth ou USB (Switch, Xbox, PlayStation) marche aussi."))
            WelcomeLine(icon: "pause.circle", text: tr("Échap met le jeu en pause : sauvegarde rapide, options, plein écran, quitter."))
#endif
            WelcomeLine(icon: "externaldrive", text: tr("Les sauvegardes des jeux s'enregistrent toutes seules."))
        }
    }

    private var turbo: some View {
        WelcomeCard {
            WelcomeTitle(icon: "bolt.fill", title: tr("MODE TURBO"), color: Neon.violet)
#if os(macOS)
#if PLAYTENDO_VITA
            WelcomeLine(icon: "bolt", text: tr("Il accélère la PSP, la PS Vita, la PS2, la GameCube, la Wii et la 3DS."))
#else
            WelcomeLine(icon: "bolt", text: tr("Il accélère la PSP, la PS2, la GameCube, la Wii et la 3DS."))
#endif
            WelcomeLine(icon: "checkmark.circle", text: tr("Sur Mac, il s'active tout seul : rien à installer."))
#else
#if PLAYTENDO_VITA
            WelcomeLine(icon: "bolt", text: tr("Indispensable pour la PS Vita, la PS2, la GameCube, la Wii et la 3DS ; il accélère aussi la PSP. Les autres consoles s'en passent."))
#else
            WelcomeLine(icon: "bolt", text: tr("Indispensable pour la PS2, la GameCube, la Wii et la 3DS ; il accélère aussi la PSP. Les autres consoles s'en passent."))
#endif
            WelcomeLine(icon: "square.stack.3d.up", text: tr("Il faut deux apps à part : StikDebug et LocalDevVPN."))
            WelcomeLine(icon: "arrow.triangle.2.circlepath",
                        text: tr("Il s'active tout seul au lancement d'un de ces jeux, une fois par ouverture de PlayTendo : StikDebug s'ouvre quelques secondes puis te ramène ici."))
            WelcomeLine(icon: "gearshape", text: tr("Tout est expliqué dans la roue dentée de la bibliothèque."))
#endif
        }
    }

    // MARK: Navigation

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Neon.cyan : Neon.dim.opacity(0.4))
                    .frame(width: index == page ? 22 : 8, height: 8)
                    .neonGlow(index == page ? Neon.cyan : .clear, radius: 5)
#if os(macOS)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { page = index } }
#endif
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private var nextButton: some View {
        let last = page == pageCount - 1
        let color = last ? Neon.magenta : Neon.cyan
        return Button {
            if last {
                onFinish()
            } else {
                withAnimation { page += 1 }
            }
        } label: {
            Text(last ? tr("C'EST PARTI !") : tr("SUIVANT"))
                .font(.display(16, weight: 900))
                .tracking(2)
                .foregroundStyle(Neon.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Chamfer(cut: 12).fill(color))
                .neonGlow(color, radius: 10)
        }
        .buttonStyle(.plain)
    }
}

/// Carte de la présentation : contenu centré, défilant si l'écran est petit (iPhone en paysage).
private struct WelcomeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct WelcomeTitle: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(color)
                .neonGlow(color, radius: 14)
            Text(title)
                .font(.display(24, weight: 900))
                .tracking(2)
                .foregroundStyle(Neon.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }
}

private struct WelcomeLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Neon.cyan)
                .frame(width: 24)
            Text(text)
                .font(.body)
                .foregroundStyle(Neon.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
