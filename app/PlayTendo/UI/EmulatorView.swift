import SwiftUI

struct EmulatorView: View {
    let game: Game
    /// Mac : la partie est posée par-dessus la bibliothèque (et non présentée en plein écran) ; ferme-la.
    private let onClose: (() -> Void)?
    @StateObject private var session: EmulatorSession
    @StateObject private var gamepad = GamepadManager()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMenu = false
    @State private var confirmingReset = false
    @State private var quitting = false
    /// Chargement de plus de 3 s : le bouton « Quitter le jeu » apparaît sous la roue.
    @State private var loadingIsSlow = false
    @State private var screensSwapped: Bool
    @State private var touchSize: DSTouchSize
    @State private var fillScreen: Bool
    /// Wii : Wiimote + Nunchuk ou manette GameCube (choix retenu par jeu).
    @State private var wiiController: DolphinSettings.WiiController
    /// PS1 : lissage des bords, fait par l'écran de jeu (filtre FXAA de PlayTendo).
    @AppStorage(PS1Settings.smoothingKey) private var ps1Smoothing = PS1Settings.Smoothing.off.rawValue
    /// Consoles 2D : filtre de l'image (FilterSettings), gardé pour chaque console.
    @AppStorage private var screenFilter: Int

    init(game: Game, onClose: (() -> Void)? = nil) {
        self.game = game
        self.onClose = onClose
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
        _screensSwapped = State(initialValue: Self.savedSwap(for: game))
        let savedSize = UserDefaults.standard.string(forKey: Self.touchSizeKey) ?? ""
        _touchSize = State(initialValue: DSTouchSize(rawValue: savedSize) ?? .medium)
        let fillKey = Self.fillScreenKey(for: game.system)
        _fillScreen = State(initialValue: UserDefaults.standard.object(forKey: fillKey) as? Bool
                                          ?? (fillKey == Self.fillScreenKeyAnalog))
        _screenFilter = AppStorage(wrappedValue: FilterSettings.Filter.sharp.rawValue, FilterSettings.key(for: game.system))
        _wiiController = State(initialValue: DolphinSettings.controller(for: game))
    }

    /// Commandes affichées : celles de la console, ou pour un jeu Wii la manette choisie.
    private var controls: ControlScheme {
        guard game.system == .wii else { return game.system.controls }
        return wiiController == .wiimote ? .wiimote : .gameCube
    }

    /// PS2 avec une manette branchée : en paysage, l'image prend toute la hauteur (comme « Plein écran »), quel que
    /// soit le réglage Image (demandé le 2026-10-07). En portrait, elle prend déjà toute la largeur.
    private var ps2FillsForController: Bool { game.system == .ps2 && gamepad.isConnected }

    private static let touchSizeKey = "tailleEcranTactileDS"
    /// Taille de l'image en paysage : consoles à stick (N64, PSP, PS2, GameCube, Wii, PS Vita), plein écran par défaut
    /// (clé historique « pleinEcranPSP ») ; consoles 2D et PS1, leur propre choix, réduite par défaut (comme avant).
    private static let fillScreenKeyAnalog = "pleinEcranPSP"
    private static let fillScreenKey2D = "pleinEcran2D"

    private static func fillScreenKey(for system: GameSystem) -> String {
        system.controls.hasAnalogStick ? fillScreenKeyAnalog : fillScreenKey2D
    }

    /// Clé du choix « Inverser les écrans » : le chemin du jeu dans Jeux, qui ne change pas d'une mise à
    /// jour à l'autre (contrairement au chemin complet, utilisé avant).
    private static func swapKey(for game: Game) -> String { "ecransInverses.\(game.key)" }

    private static func savedSwap(for game: Game) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: swapKey(for: game)) != nil { return defaults.bool(forKey: swapKey(for: game)) }
        // Ancienne clé (chemin complet) : reprise une fois.
        let old = "ecransInverses.\(game.id)"
        guard defaults.object(forKey: old) != nil else { return false }
        let swapped = defaults.bool(forKey: old)
        defaults.set(swapped, forKey: swapKey(for: game))
        defaults.removeObject(forKey: old)
        return swapped
    }

    var body: some View {
        GeometryReader { geometry in
            stage(size: geometry.size)
        }
        .ignoresSafeArea()
#if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
#endif
        .onAppear {
            // Manette : la gâchette L2 recule sur les consoles qui n'en ont pas (NES, Super Nintendo, Game Boy, GBA).
            let rewindTrigger = session.rewindAvailable && [.nes, .snes, .gb, .gbc, .gba].contains(game.system)
            gamepad.onButton = { [session] button, pressed in
                // Retour en arrière lancé du menu pause : un bouton l'arrête (sans aller au jeu).
                if session.isRewindingFromMenu {
                    if pressed { session.stopRewind() }
                } else if rewindTrigger && button == .l2 {
                    session.setRewinding(pressed)
                } else {
                    session.setButton(button, pressed: pressed)
                }
            }
            gamepad.onAnalog = { [session] stick, x, y in session.setAnalog(stick: stick, x: x, y: y) }
            gamepad.onMenu = { showingMenu ? closeMenu() : openMenu() }
            gamepad.stickMovesDPad = !controls.hasAnalogStick
            gamepad.nintendoLetters = controls.nintendoLetters
            ScreenAwake.hold(.playing)
#if os(macOS)
            // Réglages › Clavier s'ouvrira sur les touches de cette console.
            UserDefaults.standard.set(controls.keyboardID, forKey: KeyCapture.consoleKey)
#endif
            session.setWiimote(controls.isWiimote)
            session.start()
        }
        .onDisappear {
            ScreenAwake.release(.playing)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && session.state == .running { openMenu() }
        }
        .alert(tr("Recommencer le jeu ?"), isPresented: $confirmingReset) {
            Button(tr("Recommencer"), role: .destructive) {
                session.reset()
                closeMenu()
            }
            Button(tr("Annuler"), role: .cancel) {}
        } message: {
            Text(tr("La progression non sauvegardée sera perdue."))
        }
        .alert(tr("Impossible de lancer le jeu"), isPresented: Binding(get: { failureMessage != nil }, set: { _ in })) {
            Button("OK") { close() }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /// L'écran de jeu pour une taille donnée : images du jeu, boutons, menu pause et messages.
    @ViewBuilder
    private func stage(size: CGSize) -> some View {
        let bounds = CGRect(origin: .zero, size: size)
        let landscape = size.width > size.height
        let layout = makeLayout(bounds: bounds)
        ZStack {
            Color.black
            screens(layout)
#if os(iOS)
            TouchControls(layout: layout, scheme: controls, session: session, onMenu: openMenu,
                          onTouchDown: { gamepad.deactivate() })
#else
            MacInput(layout: layout, scheme: controls, session: session,
                     onMenu: { showingMenu ? closeMenu() : openMenu() },
                     onKeyboard: { session.stopRewind() })
#endif
            if session.state == .loading {
                // Étape longue (installation PS Vita, reprise d'une partie) : fond noir, le démarrage de la console
                // ne se voit pas.
                if session.loadingDetail != nil {
                    Color.black.ignoresSafeArea()
                }
                VStack(spacing: 22) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                    // Étape longue (installation du firmware ou d'un jeu PS Vita).
                    if let detail = session.loadingDetail {
                        Text(detail)
                            .font(Neon.mono(13, weight: .semibold))
                            .foregroundStyle(Neon.text)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    // Chargement qui dure (installation PS Vita, moteur bloqué au démarrage) : on peut toujours revenir
                    // à la bibliothèque. Une installation en cours va d'abord au bout de son étape.
                    if loadingIsSlow {
                        Button { quit() } label: {
                            Text((quitting ? tr("Fermeture…") : tr("Quitter le jeu")).uppercased())
                                .font(.display(12, weight: 800))
                                .tracking(1.5)
                                .foregroundStyle(Neon.magenta)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .overlay(Chamfer(cut: 8).stroke(Neon.magenta.opacity(0.7), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(quitting)
                        .transition(.opacity)
                    }
                }
                .task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { loadingIsSlow = true }
                }
            }
            if session.isRewindingFromMenu && !showingMenu {
                rewindOverlay(bounds: bounds, layout: layout)
            }
            if showingMenu {
                pauseMenu(landscape: landscape)
                    .transition(.opacity)
            }
            if let toast = session.toast {
                ToastView(text: toast)
                    .position(x: bounds.midX, y: max(layout.gameRect.minY, 20) + 34)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingMenu)
        .animation(.easeInOut(duration: 0.2), value: session.toast)
    }

    /// Retour en arrière lancé depuis le menu pause : bandeau en haut ; la partie recule jusqu'à ce qu'on touche
    /// l'écran (ou un bouton de la manette, une touche du clavier).
    private func rewindOverlay(bounds: CGRect, layout: ControlLayout) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.stopRewind() }
            VStack(spacing: 4) {
                Label(session.rewindReachedStart ? tr("Impossible de reculer plus loin") : tr("Retour en arrière"),
                      systemImage: "backward.fill")
                    .font(Neon.mono(13, weight: .semibold))
                    .foregroundStyle(Neon.cyan)
                Text(rewindHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Neon.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Chamfer(cut: 8).fill(Neon.panel.opacity(0.95)))
            .overlay(Chamfer(cut: 8).stroke(Neon.cyan.opacity(0.7), lineWidth: 1))
            .neonGlow(Neon.cyan, radius: 6)
            .allowsHitTesting(false)
            .position(x: bounds.midX, y: max(layout.gameRect.minY, 20) + 40)
        }
    }

    private var rewindHint: String {
#if os(macOS)
        tr("Clique ou appuie sur une touche pour reprendre")
#else
        gamepad.isConnected ? tr("Appuie sur un bouton pour reprendre") : tr("Touche l'écran pour reprendre")
#endif
    }

    /// Place des écrans et des boutons selon l'orientation, la manette et les réglages.
    private func makeLayout(bounds: CGRect) -> ControlLayout {
#if os(macOS)
        // Mac : aucun bouton à l'écran, l'image prend toute la fenêtre.
        return ControlLayout.makeForWindow(scheme: controls, aspect: session.aspectRatio, bounds: bounds,
                                           dual: DualScreenOptions(swapped: screensSwapped, touchSize: touchSize))
#else
        return ControlLayout.make(scheme: controls, aspect: session.aspectRatio,
                                  bounds: bounds, safe: Self.safeAreaInsets(),
                                  controllerConnected: gamepad.isConnected,
                                  hideTouchControls: gamepad.isActive,
                                  dual: DualScreenOptions(swapped: screensSwapped, touchSize: touchSize),
                                  fillScreen: controls.canFillScreen && (fillScreen || ps2FillsForController))
#endif
    }

    /// Les images du jeu (deux pour la DS, une pour les autres consoles ; la PS2 et la GameCube/Wii dessinent
    /// elles-mêmes dans leur vue).
    @ViewBuilder
    private func screens(_ layout: ControlLayout) -> some View {
        if let engineView = session.engineView {
            if let screen = layout.screens.first {
                EngineScreen(renderView: engineView)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .position(x: screen.frame.midX, y: screen.frame.midY)
            }
        } else {
            ForEach(Array(layout.screens.enumerated()), id: \.offset) { _, screen in
                GameScreen(frameBuffer: session.frameBuffer, source: screen.source, paused: session.state == .paused,
                           smoothing: game.system == .psx && ps1Smoothing == PS1Settings.Smoothing.on.rawValue,
                           filter: FilterSettings.systems.contains(game.system)
                               ? FilterSettings.shaderMode(FilterSettings.Filter(rawValue: screenFilter) ?? .sharp,
                                                           system: game.system)
                               : 0)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .position(x: screen.frame.midX, y: screen.frame.midY)
            }
        }
    }

    private func pauseMenu(landscape: Bool) -> some View {
        let swap: (() -> Void)? = controls.usesTouchScreen ? { swapScreens() } : nil
        let touch = Binding(get: { touchSize }, set: { setTouchSize($0) })
        let fill = Binding(get: { fillScreen }, set: { setFillScreen($0) })
        let wii = Binding(get: { wiiController }, set: { setWiiController($0) })
        return PauseMenu(session: session,
                         scheme: controls,
                         compact: landscape,
                         onResume: { closeMenu() },
                         onReset: { confirmingReset = true },
                         onQuit: { quit() },
                         onSwapScreens: swap,
                         touchSize: controls.usesTouchScreen && landscape ? touch : nil,
                         fillScreen: Self.hasTouchControls && controls.canFillScreen && landscape && !ps2FillsForController
                            ? fill : nil,
                         filter: FilterSettings.systems.contains(game.system) ? $screenFilter : nil,
                         wiiController: game.system == .wii ? wii : nil)
    }

    private var failureMessage: String? {
        if case .failed(let message) = session.state { message } else { nil }
    }

    /// DS : échange l'écran principal et l'écran tactile (choix retenu pour ce jeu).
    private func swapScreens() {
        screensSwapped.toggle()
        UserDefaults.standard.set(screensSwapped, forKey: Self.swapKey(for: game))
        closeMenu()
    }

    /// DS et 3DS en paysage : écran tactile petit, moyen ou grand (choix retenu pour tous les jeux).
    private func setTouchSize(_ size: DSTouchSize) {
        touchSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.touchSizeKey)
    }

    /// En paysage : image en plein écran (boutons par-dessus) ou réduite (boutons à côté). Choix commun aux consoles
    /// à stick, et un autre pour les consoles 2D et la PS1.
    private func setFillScreen(_ fill: Bool) {
        fillScreen = fill
        UserDefaults.standard.set(fill, forKey: Self.fillScreenKey(for: game.system))
    }

    /// Wii : Wiimote + Nunchuk ou manette GameCube (choix retenu pour ce jeu).
    private func setWiiController(_ controller: DolphinSettings.WiiController) {
        guard controller != wiiController else { return }
        wiiController = controller
        DolphinSettings.setController(controller, for: game)
        session.clearInput()
        session.setWiimote(controller == .wiimote)
        gamepad.nintendoLetters = controls.nintendoLetters
    }

    private func openMenu() {
        guard !showingMenu, session.state == .running else { return }
        session.stopRewind()
        session.clearInput()
        session.pause()
        showingMenu = true
        // Menu pause : l'écran peut s'éteindre comme d'habitude (il restait allumé tant que la partie était ouverte).
        ScreenAwake.release(.playing)
    }

    private func closeMenu() {
        showingMenu = false
        ScreenAwake.hold(.playing)
        session.resume()
    }

    private func quit() {
        guard !quitting else { return }
        quitting = true
        session.stop { close() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Boutons à l'écran (iPhone, iPad) ; sur Mac : clavier, souris et manette.
    private static var hasTouchControls: Bool {
#if os(iOS)
        true
#else
        false
#endif
    }

#if os(iOS)
    /// Marges de sécurité de l'écran (encoche, barre d'accueil) dans l'orientation actuelle.
    private static func safeAreaInsets() -> UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? .zero
    }
#endif
}

private struct PauseMenu: View {
    @ObservedObject var session: EmulatorSession
    @EnvironmentObject private var metadata: GameMetadata
    /// Commandes de la partie (Wii : celles de la manette choisie).
    let scheme: ControlScheme
    /// Paysage : le cadre (reprendre, sauvegardes, quitter) à gauche, les réglages de la console à droite.
    let compact: Bool
    let onResume: () -> Void
    let onReset: () -> Void
    let onQuit: () -> Void
    /// DS et 3DS : échange des deux écrans (nil = pas de bloc ÉCRANS).
    let onSwapScreens: (() -> Void)?
    /// DS et 3DS en paysage : taille de l'écran tactile (nil = réglage masqué).
    let touchSize: Binding<DSTouchSize>?
    /// En paysage : image réduite (boutons à côté) ou plein écran (boutons par-dessus) ; nil = réglage masqué.
    let fillScreen: Binding<Bool>?
    /// Consoles 2D : filtre de l'image (`FilterSettings.Filter`) ; nil pour les autres.
    let filter: Binding<Int>?
    /// Wii : manette utilisée (nil = réglage masqué).
    let wiiController: Binding<DolphinSettings.WiiController>?

    /// PSP : résolution et lissage des textures, choisis directement (gardés pour tous les jeux PSP).
    @AppStorage(PSPSettings.resolutionKey) private var resolution = PSPSettings.Resolution.x2.rawValue
    @AppStorage(PSPSettings.smoothingKey) private var smoothing = PSPSettings.Smoothing.off.rawValue
    /// PS2 : résolution et lissage des bords (gardés pour tous les jeux PS2).
    @AppStorage(PS2Settings.resolutionKey) private var ps2Resolution = PS2Settings.Resolution.x1.rawValue
    @AppStorage(PS2Settings.smoothingKey) private var ps2Smoothing = PS2Settings.Smoothing.off.rawValue
    @AppStorage(PS2Settings.formatKey) private var ps2Format = PS2Settings.Format.standard.rawValue
    /// GameCube et Wii : résolution et lissage des bords (gardés pour tous leurs jeux).
    @AppStorage(DolphinSettings.resolutionKey) private var dolphinResolution = DolphinSettings.Resolution.x1.rawValue
    @AppStorage(DolphinSettings.smoothingKey) private var dolphinSmoothing = DolphinSettings.Smoothing.off.rawValue
    /// GameCube : écran large forcé (gardé pour tous ses jeux).
    @AppStorage(DolphinSettings.formatKey) private var dolphinFormat = DolphinSettings.Format.standard.rawValue
    /// 3DS : résolution et lissage des textures (gardés pour tous ses jeux).
    @AppStorage(N3DSSettings.resolutionKey) private var n3dsResolution = N3DSSettings.Resolution.x1.rawValue
    @AppStorage(N3DSSettings.smoothingKey) private var n3dsSmoothing = N3DSSettings.Smoothing.off.rawValue
    /// DS : résolution (gardée pour tous ses jeux).
    @AppStorage(DSSettings.resolutionKey) private var dsResolution = DSSettings.Resolution.x2.rawValue
#if PLAYTENDO_VITA
    @AppStorage(VitaSettings.resolutionKey) private var vitaResolution = VitaSettings.Resolution.standard.rawValue
#endif
    /// N64 et PS1 : résolution et lissage (gardés pour tous leurs jeux).
    @AppStorage(N64Settings.resolutionKey) private var n64Resolution = N64Settings.Resolution.x2.rawValue
    @AppStorage(N64Settings.formatKey) private var n64Format = N64Settings.Format.standard.rawValue
    @AppStorage(PS1Settings.resolutionKey) private var ps1Resolution = PS1Settings.Resolution.x1.rawValue
    @AppStorage(PS1Settings.smoothingKey) private var ps1Smoothing = PS1Settings.Smoothing.off.rawValue
#if os(macOS)
    /// Mac : touches du clavier de la console en cours, à la place des boutons du menu.
    @State private var showingKeys = false
#endif

    private var isDolphin: Bool { session.game.system == .gameCube || session.game.system == .wii }
    private var hasImageSettings: Bool {
        [.psp, .ps2, .gameCube, .wii, .n3ds, .nds, .n64, .psx].contains(session.game.system) || session.game.system.isVita
    }
    /// Vita3K n'a ni sauvegarde rapide, ni avance rapide, ni « recommencer » : seules les sauvegardes des jeux existent.
    /// Les boutons restent à leur place, éteints, pour que le menu ait la même forme pour toutes les consoles.
    private var hasEngineExtras: Bool { !session.game.system.isVita }

    /// Bloc IMAGE : réglages du moteur, taille, filtre (et plein écran de la fenêtre sur Mac).
    private var hasImageBlock: Bool {
#if os(macOS)
        true
#else
        hasImageSettings || fillScreen != nil || filter != nil
#endif
    }

    private var hasControlsBlock: Bool {
#if os(macOS)
        true
#else
        wiiController != nil
#endif
    }

    private var hasBlocks: Bool {
        hasImageBlock || onSwapScreens != nil || session.diskInfo != nil || hasControlsBlock
    }

    /// Onglets du menu en paysage et sur Mac. Une nouvelle option prend place dans l'onglet qui lui correspond.
    private enum MenuTab: Hashable {
        case game, image, screens, controls

        var title: String {
            switch self {
            case .game: tr("Partie")
            case .image: tr("Image")
            case .screens: tr("Écrans")
            case .controls: tr("Commandes")
            }
        }

        var icon: String {
            switch self {
            case .game: "play.rectangle"
            case .image: "sparkles.tv"
            case .screens: "rectangle.split.2x1"
            case .controls: "gamecontroller"
            }
        }
    }

    /// Onglets de cette console : Partie toujours, les autres seulement s'ils ont quelque chose à montrer.
    private var tabs: [MenuTab] {
        var tabs: [MenuTab] = [.game]
        if hasImageBlock { tabs.append(.image) }
        if onSwapScreens != nil { tabs.append(.screens) }
        if hasControlsBlock { tabs.append(.controls) }
        return tabs
    }

    @State private var tab: MenuTab = .game
    @State private var showingCheats = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onResume)
            if compact {
                tabbedMenu
            } else {
                portraitMenu
            }
        }
        .sheet(isPresented: $showingCheats) {
            CheatsView(session: session, title: metadata.display(for: session.game).title,
                       officialName: metadata.officialName(for: session.game))
        }
    }

    // MARK: Paysage et Mac : onglets

    /// Panneau de taille fixe (la même pour toutes les consoles) : à gauche le jeu, Reprendre, les onglets et Quitter ;
    /// à droite le contenu de l'onglet choisi, qui défile s'il est trop long.
    private var tabbedMenu: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                    .background(Color.black.opacity(0.22))
                Rectangle()
                    .fill(Neon.cyan.opacity(0.2))
                    .frame(width: 1)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(tab.title.uppercased())
                            .font(.display(13, weight: 800))
                            .tracking(2)
                            .foregroundStyle(Neon.cyan)
                        tabContent
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipShape(Chamfer(cut: 22))
            .background(Chamfer(cut: 22).fill(Neon.panel.opacity(0.97)))
            .overlay(Chamfer(cut: 22).stroke(LinearGradient(colors: [Neon.cyan, Neon.magenta.opacity(0.6)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                                            lineWidth: 1.2))
            .neonGlow(Neon.cyan, radius: 14)
            .frame(width: min(geometry.size.width - 32, 720), height: min(geometry.size.height - 24, 440))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SystemBadge(system: session.game.system)
                Text(metadata.display(for: session.game).title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Neon.text)
                    .lineLimit(2)
            }
            MenuButton(title: tr("Reprendre"), icon: "play.fill", prominent: true, action: onResume)
            VStack(spacing: 4) {
                ForEach(tabs, id: \.self) { item in
                    TabRow(title: item.title, icon: item.icon, selected: item == tab) {
                        tab = item
#if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
#endif
                    }
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 8)
            MenuButton(title: tr("Quitter le jeu"), icon: "xmark", destructive: true, small: true, action: onQuit)
        }
        .padding(16)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .game:
            quickActions
            cheatsButton
            if let disk = session.diskInfo { discPicker(disk, showsTitle: true) }
            MenuButton(title: tr("Recommencer"), icon: "arrow.counterclockwise", action: onReset)
                .disabled(!hasEngineExtras)
                .opacity(hasEngineExtras ? 1 : 0.4)
        case .image:
            imageSection
        case .screens:
            screensSection
        case .controls:
            if let wiiController { wiiPicker(wiiController) }
#if os(macOS)
            MacKeysSection(scheme: scheme)
#endif
        }
    }

    // MARK: Portrait

    /// Une colonne : Reprendre, sauvegardes, les blocs de la console, puis Recommencer et Quitter.
    private var portraitMenu: some View {
        VStack(spacing: 10) {
            header
                .padding(.bottom, 6)
#if os(macOS)
            if showingKeys {
                KeyboardPanel(scheme: scheme, onBack: { showingKeys = false })
            } else {
                portraitContent
            }
#else
            portraitContent
#endif
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(Chamfer(cut: 22).fill(Neon.panel.opacity(0.94)))
        .overlay(Chamfer(cut: 22).stroke(LinearGradient(colors: [Neon.cyan, Neon.magenta.opacity(0.6)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: 1.2))
        .neonGlow(Neon.cyan, radius: 14)
        .padding(24)
    }

    @ViewBuilder private var portraitContent: some View {
        MenuButton(title: tr("Reprendre"), icon: "play.fill", prominent: true, action: onResume)
        quickActions
        cheatsButton
        if hasBlocks {
            ViewThatFits(in: .vertical) {
                blocks
                ScrollView(showsIndicators: false) { blocks }
            }
            .padding(.vertical, 4)
        }
        HStack(spacing: 8) {
            MenuButton(title: tr("Recommencer"), icon: "arrow.counterclockwise", small: true, action: onReset)
                .disabled(!hasEngineExtras)
                .opacity(hasEngineExtras ? 1 : 0.4)
            MenuButton(title: tr("Quitter le jeu"), icon: "xmark", destructive: true, small: true, action: onQuit)
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasImageBlock {
                MenuBlock(title: tr("IMAGE")) { imageSection }
            }
            if onSwapScreens != nil {
                MenuBlock(title: tr("ÉCRANS")) { screensSection }
            }
            if let disk = session.diskInfo {
                MenuBlock(title: tr("DISQUE")) { discPicker(disk, showsTitle: false) }
            }
            if hasControlsBlock {
                MenuBlock(title: tr("COMMANDES")) {
                    if let wiiController { wiiPicker(wiiController) }
#if os(macOS)
                    MenuButton(title: tr("Touches clavier"), icon: "keyboard") { showingKeys = true }
#endif
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Contenus (communs au portrait et aux onglets)

    /// Sauvegarder, Charger, Retour arrière, Avance rapide : à la même place pour toutes les consoles (éteints quand le
    /// moteur ne les a pas : PS Vita ; retour en arrière seulement NES, SNES, Game Boy, GBA, N64 et PS1).
    @ViewBuilder private var quickActions: some View {
        HStack(spacing: 8) {
            QuickButton(title: tr("Sauvegarder"), icon: "square.and.arrow.down", enabled: hasEngineExtras) {
                session.saveState()
                onResume()
            }
            QuickButton(title: tr("Charger"), icon: "clock.arrow.circlepath", enabled: hasEngineExtras && session.hasSaveState) {
                session.loadState()
                onResume()
            }
            QuickButton(title: tr("Retour arrière"), icon: "backward.fill", enabled: session.rewindAvailable) {
                session.startRewind()
                onResume()
            }
            QuickButton(title: session.isFastForwarding ? tr("Vitesse normale") : tr("Avance rapide ×3"),
                        icon: session.isFastForwarding ? "tortoise.fill" : "forward.fill", enabled: hasEngineExtras) {
                session.toggleFastForward()
                onResume()
            }
        }
        if !hasEngineExtras {
            Text(tr("PS Vita : seules les sauvegardes faites dans le jeu existent."))
                .font(.caption)
                .foregroundStyle(Neon.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Codes de triche : leur écran, avec le nombre de codes actifs (éteint si le moteur de la console ne les lit pas).
    private var cheatsButton: some View {
        let supported = Cheats.supported(session.game.system)
        let active = session.cheats.filter(\.enabled).count
        return MenuButton(title: active > 0 ? tr("Codes de triche") + " · \(active)" : tr("Codes de triche"),
                          icon: "wand.and.stars") {
            showingCheats = true
        }
        .disabled(!supported)
        .opacity(supported ? 1 : 0.4)
    }

    @ViewBuilder private var imageSection: some View {
        if hasImageSettings { imageSettings }
        if let fillScreen {
            NeonSegments(title: tr("TAILLE"), detail: nil,
                         options: [(0, tr("Réduite")), (1, tr("Plein écran"))],
                         selection: fillScreen.wrappedValue ? 1 : 0) { value in
                pick { fillScreen.wrappedValue = value == 1 }
            }
        }
        if let filter {
            NeonSegments(title: tr("FILTRE"), detail: nil,
                         options: FilterSettings.Filter.allCases.map {
                             ($0.rawValue, FilterSettings.label($0, system: session.game.system))
                         },
                         selection: filter.wrappedValue) { value in
                pick { filter.wrappedValue = value }
            }
        }
#if os(macOS)
        let fullScreen = MacWindow.isFullScreen
        MenuButton(title: fullScreen ? tr("Quitter le plein écran") : tr("Plein écran"),
                   icon: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            MacWindow.toggleFullScreen()
            onResume()
        }
#endif
    }

    @ViewBuilder private var screensSection: some View {
        if let onSwapScreens {
            MenuButton(title: tr("Inverser les écrans"), icon: "rectangle.2.swap", action: onSwapScreens)
        }
        if let touchSize {
            NeonSegments(title: tr("ÉCRAN TACTILE"), detail: nil,
                         options: DSTouchSize.allCases.enumerated().map { ($0.offset, $0.element.label) },
                         selection: DSTouchSize.allCases.firstIndex(of: touchSize.wrappedValue) ?? 0) { value in
                pick { touchSize.wrappedValue = DSTouchSize.allCases[value] }
            }
        }
    }

    private func discPicker(_ disk: EmulatorSession.DiskInfo, showsTitle: Bool) -> some View {
        NeonSegments(title: tr("DISQUE"), showsTitle: showsTitle, detail: nil,
                     options: (0..<disk.count).map { ($0, "\($0 + 1)") },
                     selection: disk.current - 1) { value in
            guard value != disk.current - 1 else { return }
            session.selectDisk(value)
            onResume()
        }
    }

    private func wiiPicker(_ controller: Binding<DolphinSettings.WiiController>) -> some View {
        NeonSegments(title: tr("MANETTE"), detail: nil,
                     options: [(0, DolphinSettings.WiiController.wiimote.label),
                               (1, DolphinSettings.WiiController.gameCube.label)],
                     selection: controller.wrappedValue == .wiimote ? 0 : 1) { value in
            pick { controller.wrappedValue = value == 0 ? .wiimote : .gameCube }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            SystemBadge(system: session.game.system)
            Text(metadata.display(for: session.game).title)
                .font(.headline)
                .foregroundStyle(Neon.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    /// Résolution et lissage : tous les choix visibles, un toucher suffit. Appliqués à la reprise du jeu (PS Vita : au
    /// prochain lancement, Vita3K ne lit sa résolution qu'au démarrage).
    @ViewBuilder private var imageSettings: some View {
#if PLAYTENDO_VITA
        if session.game.system.isVita {
            let chosen = VitaSettings.Resolution(rawValue: vitaResolution) ?? .standard
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: session.vitaResolution.map { $0 != chosen } == true
                                            ? tr("au prochain lancement") : chosen.size,
                                         options: VitaSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: vitaResolution) { value in
                    choose { vitaResolution = value }
                })
        } else {
            consoleImageSettings
        }
#else
        consoleImageSettings
#endif
    }

    @ViewBuilder private var consoleImageSettings: some View {
        if isDolphin {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (DolphinSettings.Resolution(rawValue: dolphinResolution) ?? .x1).detail,
                                         options: DolphinSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: dolphinResolution) { value in
                    choose { dolphinResolution = value }
                },
                smoothing: NeonSegments(title: tr("LISSAGE"), detail: nil,
                                        options: DolphinSettings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                        selection: dolphinSmoothing) { value in
                    choose { dolphinSmoothing = value }
                },
                format: session.game.system == .gameCube
                    ? NeonSegments(title: tr("FORMAT"), detail: nil,
                                   options: DolphinSettings.Format.allCases.map { ($0.rawValue, $0.label) },
                                   selection: dolphinFormat) { value in
                        choose { dolphinFormat = value }
                    }
                    : nil)
        } else if session.game.system == .n64 {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (N64Settings.Resolution(rawValue: n64Resolution) ?? .x2)
                                            .size(wide: n64Format == N64Settings.Format.wide.rawValue),
                                         options: N64Settings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: n64Resolution) { value in
                    choose { n64Resolution = value }
                },
                smoothing: NeonSegments(title: tr("FORMAT"), detail: nil,
                                        options: N64Settings.Format.allCases.map { ($0.rawValue, $0.label) },
                                        selection: n64Format) { value in
                    choose { n64Format = value }
                })
        } else if session.game.system == .psx {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (PS1Settings.Resolution(rawValue: ps1Resolution) ?? .x1).detail,
                                         options: PS1Settings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: ps1Resolution) { value in
                    choose { ps1Resolution = value }
                },
                smoothing: NeonSegments(title: tr("LISSAGE"), detail: nil,
                                        options: PS1Settings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                        selection: ps1Smoothing) { value in
                    choose { ps1Smoothing = value }
                })
        } else if session.game.system == .n3ds {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (N3DSSettings.Resolution(rawValue: n3dsResolution) ?? .x1).size,
                                         options: N3DSSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: n3dsResolution) { value in
                    choose { n3dsResolution = value }
                },
                smoothing: NeonSegments(title: tr("LISSAGE"), detail: nil,
                                        options: N3DSSettings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                        selection: n3dsSmoothing) { value in
                    choose { n3dsSmoothing = value }
                })
        } else if session.game.system == .nds {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (DSSettings.Resolution(rawValue: dsResolution) ?? .x2).size,
                                         options: DSSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: dsResolution) { value in
                    choose { dsResolution = value }
                })
        } else if session.game.system == .ps2 {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (PS2Settings.Resolution(rawValue: ps2Resolution) ?? .x1).detail,
                                         options: PS2Settings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: ps2Resolution) { value in
                    choose { ps2Resolution = value }
                },
                smoothing: NeonSegments(title: tr("LISSAGE"), detail: nil,
                                        options: PS2Settings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                        selection: ps2Smoothing) { value in
                    choose { ps2Smoothing = value }
                },
                format: NeonSegments(title: tr("FORMAT"),
                                     // 16:9 choisi mais image restée en 4:3 : ce jeu n'a pas de correctif écran large.
                                     detail: ps2Format == PS2Settings.Format.wide.rawValue && session.aspectRatio < 1.5
                                        ? tr("reste en 4:3") : nil,
                                     options: PS2Settings.Format.allCases.map { ($0.rawValue, $0.label) },
                                     selection: ps2Format) { value in
                    choose { ps2Format = value }
                })
        } else {
            imageSettings(
                resolution: NeonSegments(title: tr("RÉSOLUTION"),
                                         detail: (PSPSettings.Resolution(rawValue: resolution) ?? .x2).size,
                                         options: PSPSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                         selection: resolution) { value in
                    choose { resolution = value }
                },
                smoothing: NeonSegments(title: tr("LISSAGE"), detail: nil,
                                        options: PSPSettings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                        selection: smoothing) { value in
                    choose { smoothing = value }
                })
        }
    }

    /// `resolution` : premier réglage ; `smoothing` : second (le format pour la N64) ; `format` : troisième (PS2).
    @ViewBuilder private func imageSettings(resolution resolutionPicker: NeonSegments,
                                            smoothing smoothingPicker: NeonSegments? = nil,
                                            format formatPicker: NeonSegments? = nil) -> some View {
        resolutionPicker
        if let smoothingPicker { smoothingPicker }
        if let formatPicker { formatPicker }
    }

    /// Réglage de l'écran de jeu (taille, filtre, écran tactile, manette) : rien à renvoyer au moteur.
    private func pick(_ change: () -> Void) {
        change()
#if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
    }

    /// Réglage d'image du moteur : appliqué tout de suite.
    private func choose(_ change: () -> Void) {
        pick(change)
        // PS Vita : retenue pour le prochain lancement (EmulatorSession la donne au moteur avant chaque démarrage).
        if session.game.system.isVita { return }
        if isDolphin {
            session.applyDolphinImage()
        } else if session.game.system == .n3ds {
            session.applyOptions(N3DSSettings.coreOptions)
        } else if session.game.system == .nds {
            session.applyOptions(DSSettings.coreOptions)
        } else if session.game.system == .n64 {
            // Lu seulement au démarrage du jeu : moteur rechargé à la reprise, partie gardée.
            session.requestCoreReload()
        } else if session.game.system == .psx {
            session.applyOptions(PS1Settings.coreOptions)
        } else if session.game.system == .ps2 {
            session.applyPS2Image()
        } else {
            session.applyOptions(PSPSettings.coreOptions)
        }
    }

}

/// Bloc de réglages du menu pause : titre néon, puis ses réglages.
private struct MenuBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Neon.magenta)
                    .frame(width: 3, height: 12)
                Text(title)
                    .font(.display(11, weight: 800))
                    .tracking(2)
                    .foregroundStyle(Neon.text)
                Rectangle()
                    .fill(LinearGradient(colors: [Neon.magenta.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
            }
            content
        }
    }
}

/// Onglet du menu en paysage : icône et nom, allumé quand il est choisi.
private struct TabRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Neon.cyan : Neon.text.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Chamfer(cut: 7).fill(selected ? Neon.cyan.opacity(0.12) : .clear))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Neon.cyan)
                        .frame(width: 3, height: 20)
                        .themedShadow(Neon.cyan.opacity(0.8), radius: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Sauvegarder, Charger, Retour arrière, Avance rapide : quatre petits boutons côte à côte, à la même place sur toutes les consoles
/// (éteints quand le moteur ne les a pas).
private struct QuickButton: View {
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                // Un seul mot (« Sauvegarder ») : réduit plutôt que coupé en deux lignes.
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(title.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Neon.text)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 3)
            .background(Chamfer(cut: 9).fill(Neon.text.opacity(0.07)))
            .overlay(Chamfer(cut: 9).stroke(Neon.text.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct MenuButton: View {
    let title: String
    let icon: String
    var prominent = false
    var destructive = false
    /// Demi-largeur (Recommencer, Quitter le jeu) : texte plus petit pour tenir sans être coupé.
    var small = false
    let action: () -> Void

    var body: some View {
        let color = prominent ? Neon.cyan : (destructive ? Neon.magenta : Neon.text)
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: small ? 14 : 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(prominent ? Neon.onAccent : color)
                .background(Chamfer(cut: 10).fill(prominent ? Neon.cyan : color.opacity(destructive ? 0.1 : 0.07)))
                .overlay(Chamfer(cut: 10).stroke(prominent ? .clear : color.opacity(destructive ? 0.6 : 0.25), lineWidth: 1))
                .themedShadow(prominent ? Neon.cyan.opacity(0.6) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
    }
}

/// Rangée de pastilles néon : tous les choix visibles, celui en cours allumé.
private struct NeonSegments: View {
    let title: String
    /// Faux quand le titre du bloc suffit (DISQUE) ; il sert encore à VoiceOver.
    var showsTitle = true
    let detail: String?
    let options: [(Int, String)]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.display(10, weight: 800))
                        .tracking(1.5)
                        .foregroundStyle(Neon.dim)
                    if let detail {
                        Text(detail)
                            .font(Neon.mono(10, weight: .semibold))
                            .foregroundStyle(Neon.cyan)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { value, label in
                    let selected = value == selection
                    Button { onSelect(value) } label: {
                        Text(label)
                            .font(.display(13, weight: 800))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selected ? Neon.onAccent : Neon.text)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Chamfer(cut: 7).fill(selected ? Neon.cyan : Neon.text.opacity(0.06)))
                            .overlay(Chamfer(cut: 7).stroke(Neon.cyan.opacity(selected ? 0 : 0.35), lineWidth: 1))
                            .themedShadow(selected ? Neon.cyan.opacity(0.6) : .clear, radius: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title.capitalized) \(label)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
/// Onglet Commandes (Mac) : les touches du clavier de la console en cours, à changer sur place.
private struct MacKeysSection: View {
    let scheme: ControlScheme
    @ObservedObject private var bindings = KeyBindings.shared
    @StateObject private var capture = KeyCapture()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("TOUCHES CLAVIER"))
                .font(.display(10, weight: 800))
                .tracking(1.5)
                .foregroundStyle(Neon.dim)
            KeyboardMapping(scheme: scheme, capture: capture, neon: true)
            MenuButton(title: tr("Touches d'origine"), icon: "arrow.uturn.backward") { capture.resetAll() }
                .disabled(!bindings.isCustomized(scheme))
                .opacity(bindings.isCustomized(scheme) ? 1 : 0.4)
        }
        .onAppear { capture.attach(to: scheme) }
        .onDisappear { capture.detach() }
    }
}

/// Menu pause › Touches clavier (Mac) : les touches de la console en cours seulement, comme dans Réglages › Clavier
/// (clic sur une touche puis la nouvelle, essai en direct, « Annuler »). Elles servent dès la reprise du jeu.
private struct KeyboardPanel: View {
    let scheme: ControlScheme
    let onBack: () -> Void
    @ObservedObject private var bindings = KeyBindings.shared
    @StateObject private var capture = KeyCapture()

    var body: some View {
        VStack(spacing: 10) {
            // Tout est visible si la fenêtre est assez haute, sinon la liste défile.
            ViewThatFits(in: .vertical) {
                mapping
                ScrollView { mapping }
            }
            HStack(spacing: 8) {
                MenuButton(title: tr("Touches d'origine"), icon: "arrow.uturn.backward") { capture.resetAll() }
                    .disabled(!bindings.isCustomized(scheme))
                    .opacity(bindings.isCustomized(scheme) ? 1 : 0.4)
                MenuButton(title: tr("Retour"), icon: "chevron.left", action: onBack)
            }
        }
        .onAppear { capture.attach(to: scheme) }
        .onDisappear { capture.detach() }
    }

    private var mapping: some View {
        KeyboardMapping(scheme: scheme, capture: capture, neon: true)
    }
}
#endif
