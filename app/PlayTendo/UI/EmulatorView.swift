import SwiftUI

struct EmulatorView: View {
    let game: Game
    @StateObject private var session: EmulatorSession
    @StateObject private var gamepad = GamepadManager()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMenu = false
    @State private var confirmingReset = false
    @State private var quitting = false
    @State private var screensSwapped: Bool
    @State private var touchSize: DSTouchSize
    @State private var fillScreen: Bool

    init(game: Game) {
        self.game = game
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
        _screensSwapped = State(initialValue: Self.savedSwap(for: game))
        let savedSize = UserDefaults.standard.string(forKey: Self.touchSizeKey) ?? ""
        _touchSize = State(initialValue: DSTouchSize(rawValue: savedSize) ?? .medium)
        _fillScreen = State(initialValue: UserDefaults.standard.object(forKey: Self.fillScreenKey) as? Bool ?? true)
    }

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
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            gamepad.onButton = { [session] button, pressed in session.setButton(button, pressed: pressed) }
            gamepad.onAnalog = { [session] stick, x, y in session.setAnalog(stick: stick, x: x, y: y) }
            gamepad.onMenu = { showingMenu ? closeMenu() : openMenu() }
            gamepad.stickMovesDPad = !game.system.controls.hasAnalogStick
            UIApplication.shared.isIdleTimerDisabled = true
            session.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && session.state == .running { openMenu() }
        }
        .alert("Recommencer le jeu ?", isPresented: $confirmingReset) {
            Button("Recommencer", role: .destructive) {
                session.reset()
                closeMenu()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La progression non sauvegardée sera perdue.")
        }
        .alert("Impossible de lancer le jeu", isPresented: Binding(get: { failureMessage != nil }, set: { _ in })) {
            Button("OK") { dismiss() }
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
            TouchControls(layout: layout, scheme: game.system.controls, session: session, onMenu: openMenu,
                          onTouchDown: { gamepad.deactivate() })
            if session.state == .loading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
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
        let controls = game.system.controls
        return ControlLayout.make(scheme: controls, aspect: session.aspectRatio,
                                  bounds: bounds, safe: Self.safeAreaInsets(),
                                  controllerConnected: gamepad.isConnected,
                                  hideTouchControls: gamepad.isActive,
                                  dual: DualScreenOptions(swapped: screensSwapped, touchSize: touchSize),
                                  fillScreen: controls.canFillScreen && fillScreen)
    }

    /// Les images du jeu (deux pour la DS, une pour les autres consoles).
    private func screens(_ layout: ControlLayout) -> some View {
        ForEach(Array(layout.screens.enumerated()), id: \.offset) { _, screen in
            GameScreen(frameBuffer: session.frameBuffer, source: screen.source)
                .frame(width: screen.frame.width, height: screen.frame.height)
                .position(x: screen.frame.midX, y: screen.frame.midY)
        }
    }

    private func pauseMenu(landscape: Bool) -> some View {
        let controls = game.system.controls
        let swap: (() -> Void)? = controls.usesTouchScreen ? { swapScreens() } : nil
        return PauseMenu(session: session,
                         compact: landscape,
                         onResume: { closeMenu() },
                         onReset: { confirmingReset = true },
                         onSwapScreens: swap,
                         touchSizeLabel: controls.usesTouchScreen && landscape ? touchSize.label : nil,
                         onTouchSize: { nextTouchSize() },
                         imageSizeLabel: controls.canFillScreen && landscape ? (fillScreen ? "Plein écran" : "Réduite") : nil,
                         onImageSize: { toggleFillScreen() },
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

    /// PSP en paysage : image en plein écran (boutons par-dessus) ou réduite (boutons à côté).
    private func toggleFillScreen() {
        fillScreen.toggle()
        UserDefaults.standard.set(fillScreen, forKey: Self.fillScreenKey)
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
        session.stop { dismiss() }
    }

    /// Marges de sécurité de l'écran (encoche, barre d'accueil) dans l'orientation actuelle.
    private static func safeAreaInsets() -> UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? .zero
    }
}

private struct PauseMenu: View {
    @ObservedObject var session: EmulatorSession
    @EnvironmentObject private var metadata: GameMetadata
    /// Paysage : boutons sur deux colonnes pour tenir dans la hauteur de l'écran.
    let compact: Bool
    let onResume: () -> Void
    let onReset: () -> Void
    let onSwapScreens: (() -> Void)?
    /// DS en paysage : taille actuelle de l'écran tactile (nil = réglage masqué).
    let touchSizeLabel: String?
    let onTouchSize: () -> Void
    /// PSP en paysage : taille actuelle de l'image (nil = réglage masqué).
    let imageSizeLabel: String?
    let onImageSize: () -> Void
    let onQuit: () -> Void

    /// PSP : résolution et lissage des textures, choisis directement (gardés pour tous les jeux PSP).
    @AppStorage(PSPSettings.resolutionKey) private var resolution = PSPSettings.Resolution.x2.rawValue
    @AppStorage(PSPSettings.smoothingKey) private var smoothing = PSPSettings.Smoothing.off.rawValue

    private struct Item: Identifiable {
        let title: String
        let icon: String
        var destructive = false
        var enabled = true
        let action: () -> Void
        var id: String { title }
    }

    private var items: [Item] {
        var items = [
            Item(title: "Sauvegarder", icon: "square.and.arrow.down") {
                session.saveState()
                onResume()
            },
            Item(title: "Charger", icon: "clock.arrow.circlepath", enabled: session.hasSaveState) {
                session.loadState()
                onResume()
            },
            Item(title: session.isFastForwarding ? "Vitesse normale" : "Avance rapide ×3",
                 icon: session.isFastForwarding ? "tortoise.fill" : "forward.fill") {
                session.toggleFastForward()
                onResume()
            },
        ]
        if let disk = session.diskInfo {
            items.append(Item(title: "Changer de disque (\(disk.current)/\(disk.count))", icon: "opticaldisc") {
                session.nextDisk()
                onResume()
            })
        }
        if let onSwapScreens {
            items.append(Item(title: "Inverser les écrans", icon: "rectangle.2.swap", action: onSwapScreens))
        }
        if let touchSizeLabel {
            items.append(Item(title: "Écran tactile : \(touchSizeLabel)", icon: "hand.tap", action: onTouchSize))
        }
        if let imageSizeLabel {
            items.append(Item(title: "Image : \(imageSizeLabel)", icon: "arrow.up.left.and.arrow.down.right",
                              action: onImageSize))
        }
        return items
    }

    private var endItems: [Item] {
        [
            Item(title: "Recommencer", icon: "arrow.counterclockwise", action: onReset),
            Item(title: "Quitter le jeu", icon: "xmark", destructive: true, action: onQuit),
        ]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onResume)

            VStack(spacing: compact ? 8 : 10) {
                header
                    .padding(.bottom, compact ? 2 : 6)
                MenuButton(title: "Reprendre", icon: "play.fill", prominent: true, action: onResume)
                if compact {
                    grid(items)
                    if session.game.system == .psp { imageSettings }
                    grid(endItems)
                } else {
                    HStack(spacing: 10) {
                        button(items[0])
                        button(items[1])
                    }
                    ForEach(items.dropFirst(2)) { button($0) }
                    if session.game.system == .psp { imageSettings }
                    ForEach(endItems) { button($0) }
                }
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

    /// Résolution et lissage : tous les choix visibles, un toucher suffit. Appliqués à la reprise du jeu.
    @ViewBuilder private var imageSettings: some View {
        let current = PSPSettings.Resolution(rawValue: resolution) ?? .x2
        let resolutionPicker = NeonSegments(title: "RÉSOLUTION", detail: current.size,
                                            options: PSPSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                                            selection: resolution) { value in
            choose { resolution = value }
        }
        let smoothingPicker = NeonSegments(title: "LISSAGE", detail: nil,
                                           options: PSPSettings.Smoothing.allCases.map { ($0.rawValue, $0.label) },
                                           selection: smoothing) { value in
            choose { smoothing = value }
        }
        if compact {
            HStack(alignment: .top, spacing: 14) {
                resolutionPicker
                smoothingPicker
            }
            .padding(.vertical, 2)
        } else {
            VStack(spacing: 10) {
                resolutionPicker
                smoothingPicker
            }
            .padding(.vertical, 4)
        }
    }

    private func choose(_ change: () -> Void) {
        change()
        UISelectionFeedbackGenerator().selectionChanged()
        session.applyOptions(PSPSettings.coreOptions)
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
                .foregroundStyle(prominent ? Color.black : color)
                .background(Chamfer(cut: 10).fill(prominent ? Neon.cyan : color.opacity(destructive ? 0.1 : 0.07)))
                .overlay(Chamfer(cut: 10).stroke(prominent ? .clear : color.opacity(destructive ? 0.6 : 0.25), lineWidth: 1))
                .shadow(color: prominent ? Neon.cyan.opacity(0.6) : .clear, radius: 10)
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
                    .font(.orbitron(10, weight: 800))
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
                            .font(.orbitron(13, weight: 800))
                            .foregroundStyle(selected ? Color.black : Neon.text)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Chamfer(cut: 7).fill(selected ? Neon.cyan : Color.white.opacity(0.06)))
                            .overlay(Chamfer(cut: 7).stroke(Neon.cyan.opacity(selected ? 0 : 0.35), lineWidth: 1))
                            .shadow(color: selected ? Neon.cyan.opacity(0.6) : .clear, radius: 6)
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
