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

    init(game: Game, onClose: (() -> Void)? = nil) {
        self.game = game
        self.onClose = onClose
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
        _screensSwapped = State(initialValue: Self.savedSwap(for: game))
        let savedSize = UserDefaults.standard.string(forKey: Self.touchSizeKey) ?? ""
        _touchSize = State(initialValue: DSTouchSize(rawValue: savedSize) ?? .medium)
        _fillScreen = State(initialValue: UserDefaults.standard.object(forKey: Self.fillScreenKey) as? Bool ?? true)
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
    private static let fillScreenKey = "pleinEcranPSP"

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
            gamepad.onButton = { [session] button, pressed in session.setButton(button, pressed: pressed) }
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
                     onMenu: { showingMenu ? closeMenu() : openMenu() })
#endif
            if session.state == .loading {
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
                GameScreen(frameBuffer: session.frameBuffer, source: screen.source,
                           smoothing: game.system == .psx && ps1Smoothing == PS1Settings.Smoothing.on.rawValue)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .position(x: screen.frame.midX, y: screen.frame.midY)
            }
        }
    }

    private func pauseMenu(landscape: Bool) -> some View {
        let swap: (() -> Void)? = controls.usesTouchScreen ? { swapScreens() } : nil
        return PauseMenu(session: session,
                         scheme: controls,
                         compact: landscape,
                         onResume: { closeMenu() },
                         onReset: { confirmingReset = true },
                         onSwapScreens: swap,
                         touchSizeLabel: controls.usesTouchScreen && landscape ? touchSize.label : nil,
                         onTouchSize: { nextTouchSize() },
                         imageSizeLabel: Self.hasTouchControls && controls.canFillScreen && landscape && !ps2FillsForController
                            ? (fillScreen ? tr("Plein écran") : tr("Réduite")) : nil,
                         onImageSize: { toggleFillScreen() },
                         controllerLabel: game.system == .wii ? wiiController.label : nil,
                         onController: { switchWiiController() },
                         onQuit: { quit() })
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

    /// DS en paysage : écran tactile petit → moyen → grand (choix retenu pour tous les jeux).
    private func nextTouchSize() {
        touchSize = touchSize.next
        UserDefaults.standard.set(touchSize.rawValue, forKey: Self.touchSizeKey)
        closeMenu()
    }

    /// N64, PSP, PS2, GameCube et Wii en paysage : image en plein écran (boutons par-dessus) ou réduite (boutons à
    /// côté). Choix commun à ces consoles (clé historique « pleinEcranPSP »).
    private func toggleFillScreen() {
        fillScreen.toggle()
        UserDefaults.standard.set(fillScreen, forKey: Self.fillScreenKey)
        closeMenu()
    }

    /// Wii : passe de la Wiimote à la manette GameCube ou l'inverse (choix retenu pour ce jeu).
    private func switchWiiController() {
        wiiController = wiiController.other
        DolphinSettings.setController(wiiController, for: game)
        session.clearInput()
        session.setWiimote(wiiController == .wiimote)
        gamepad.nintendoLetters = controls.nintendoLetters
        closeMenu()
    }

    private func openMenu() {
        guard !showingMenu, session.state == .running else { return }
        session.clearInput()
        session.pause()
        showingMenu = true
    }

    private func closeMenu() {
        showingMenu = false
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
    /// Paysage : boutons sur deux colonnes pour tenir dans la hauteur de l'écran.
    let compact: Bool
    let onResume: () -> Void
    let onReset: () -> Void
    let onSwapScreens: (() -> Void)?
    /// DS en paysage : taille actuelle de l'écran tactile (nil = réglage masqué).
    let touchSizeLabel: String?
    let onTouchSize: () -> Void
    /// En paysage (N64, PSP, PS2, GameCube, Wii) : taille actuelle de l'image (nil = réglage masqué).
    let imageSizeLabel: String?
    let onImageSize: () -> Void
    /// Wii : manette en cours (nil = réglage masqué).
    let controllerLabel: String?
    let onController: () -> Void
    let onQuit: () -> Void

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
    private var hasEngineExtras: Bool { !session.game.system.isVita }

    private struct Item: Identifiable {
        let title: String
        let icon: String
        var destructive = false
        var enabled = true
        let action: () -> Void
        var id: String { title }
    }

    private var items: [Item] {
        var items: [Item] = []
        if hasEngineExtras {
            items += [
                Item(title: tr("Sauvegarder"), icon: "square.and.arrow.down") {
                    session.saveState()
                    onResume()
                },
                Item(title: tr("Charger"), icon: "clock.arrow.circlepath", enabled: session.hasSaveState) {
                    session.loadState()
                    onResume()
                },
                Item(title: session.isFastForwarding ? tr("Vitesse normale") : tr("Avance rapide ×3"),
                     icon: session.isFastForwarding ? "tortoise.fill" : "forward.fill") {
                    session.toggleFastForward()
                    onResume()
                },
            ]
        }
        if let disk = session.diskInfo {
            items.append(Item(title: tr("Changer de disque (\(disk.current)/\(disk.count))"), icon: "opticaldisc") {
                session.nextDisk()
                onResume()
            })
        }
        if let onSwapScreens {
            items.append(Item(title: tr("Inverser les écrans"), icon: "rectangle.2.swap", action: onSwapScreens))
        }
        if let touchSizeLabel {
            items.append(Item(title: tr("Écran tactile : \(touchSizeLabel)"), icon: "hand.tap", action: onTouchSize))
        }
        if let imageSizeLabel {
            items.append(Item(title: tr("Image : \(imageSizeLabel)"), icon: "arrow.up.left.and.arrow.down.right",
                              action: onImageSize))
        }
        if let controllerLabel {
            items.append(Item(title: tr("Manette : \(controllerLabel)"), icon: "gamecontroller", action: onController))
        }
#if os(macOS)
        let fullScreen = MacWindow.isFullScreen
        items.append(Item(title: fullScreen ? tr("Quitter le plein écran") : tr("Plein écran"),
                          icon: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            MacWindow.toggleFullScreen()
            onResume()
        })
        items.append(Item(title: tr("Touches clavier"), icon: "keyboard") { showingKeys = true })
#endif
        return items
    }

    private var endItems: [Item] {
        let quit = Item(title: tr("Quitter le jeu"), icon: "xmark", destructive: true, action: onQuit)
        guard hasEngineExtras else { return [quit] }
        return [Item(title: tr("Recommencer"), icon: "arrow.counterclockwise", action: onReset), quit]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onResume)

            VStack(spacing: compact ? 8 : 10) {
                header
                    .padding(.bottom, compact ? 2 : 6)
#if os(macOS)
                if showingKeys {
                    KeyboardPanel(scheme: scheme, onBack: { showingKeys = false })
                } else {
                    menuContent
                }
#else
                menuContent
#endif
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: compact ? 540 : 340)
            .background(Chamfer(cut: 22).fill(Neon.panel.opacity(0.94)))
            .overlay(Chamfer(cut: 22).stroke(LinearGradient(colors: [Neon.cyan, Neon.magenta.opacity(0.6)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                                            lineWidth: 1.2))
            .neonGlow(Neon.cyan, radius: 14)
            .padding(compact ? 12 : 24)
        }
    }

    /// Boutons du menu, réglages d'image, recommencer et quitter.
    @ViewBuilder private var menuContent: some View {
        MenuButton(title: tr("Reprendre"), icon: "play.fill", prominent: true, action: onResume)
        if compact {
            grid(items)
            if hasImageSettings { imageSettings }
            grid(endItems)
        } else {
            if hasEngineExtras {
                HStack(spacing: 10) {
                    button(items[0])
                    button(items[1])
                }
                ForEach(items.dropFirst(2)) { button($0) }
            } else {
                ForEach(items) { button($0) }
            }
            if hasImageSettings { imageSettings }
            ForEach(endItems) { button($0) }
        }
    }

    @ViewBuilder private var header: some View {
        if compact {
            HStack(spacing: 8) {
                SystemBadge(system: session.game.system)
                Text(metadata.display(for: session.game).title)
                    .font(.headline)
                    .foregroundStyle(Neon.text)
                    .lineLimit(1)
            }
        } else {
            VStack(spacing: 4) {
                SystemBadge(system: session.game.system)
                Text(metadata.display(for: session.game).title)
                    .font(.headline)
                    .foregroundStyle(Neon.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func grid(_ items: [Item]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(items) { button($0) }
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
                })
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
        if compact {
            HStack(alignment: .top, spacing: 14) {
                resolutionPicker
                if let smoothingPicker { smoothingPicker }
                if let formatPicker { formatPicker }
            }
            .padding(.vertical, 2)
        } else {
            VStack(spacing: 10) {
                resolutionPicker
                if let smoothingPicker { smoothingPicker }
                if let formatPicker { formatPicker }
            }
            .padding(.vertical, 4)
        }
    }

    private func choose(_ change: () -> Void) {
        change()
#if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
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

    private func button(_ item: Item) -> some View {
        MenuButton(title: item.title, icon: item.icon, destructive: item.destructive, action: item.action)
            .disabled(!item.enabled)
            .opacity(item.enabled ? 1 : 0.4)
    }
}

private struct MenuButton: View {
    let title: String
    let icon: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        let color = prominent ? Neon.cyan : (destructive ? Neon.magenta : Neon.text)
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
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
    let detail: String?
    let options: [(Int, String)]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { value, label in
                    let selected = value == selection
                    Button { onSelect(value) } label: {
                        Text(label)
                            .font(.display(13, weight: 800))
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
