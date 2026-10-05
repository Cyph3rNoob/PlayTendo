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

    init(game: Game) {
        self.game = game
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
        _screensSwapped = State(initialValue: UserDefaults.standard.bool(forKey: Self.swapKey(for: game)))
        let savedSize = UserDefaults.standard.string(forKey: Self.touchSizeKey) ?? ""
        _touchSize = State(initialValue: DSTouchSize(rawValue: savedSize) ?? .medium)
    }

    private static let touchSizeKey = "tailleEcranTactileDS"

    private static func swapKey(for game: Game) -> String { "ecransInverses.\(game.id)" }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let landscape = geometry.size.width > geometry.size.height
            let layout = ControlLayout.make(scheme: game.system.controls, aspect: session.aspectRatio,
                                            bounds: bounds, safe: Self.safeAreaInsets(),
                                            controllerConnected: gamepad.isConnected,
                                            hideTouchControls: gamepad.isActive,
                                            dual: DualScreenOptions(swapped: screensSwapped, touchSize: touchSize))
            ZStack {
                Color.black

                ForEach(Array(layout.screens.enumerated()), id: \.offset) { _, screen in
                    GameScreen(frameBuffer: session.frameBuffer, source: screen.source)
                        .frame(width: screen.frame.width, height: screen.frame.height)
                        .position(x: screen.frame.midX, y: screen.frame.midY)
                }

                TouchControls(layout: layout, scheme: game.system.controls, session: session, onMenu: openMenu,
                              onTouchDown: { gamepad.deactivate() })

                if session.state == .loading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }

                if showingMenu {
                    PauseMenu(session: session,
                              compact: landscape,
                              onResume: closeMenu,
                              onReset: { confirmingReset = true },
                              onSwapScreens: game.system.controls.usesTouchScreen ? swapScreens : nil,
                              touchSizeLabel: game.system.controls.usesTouchScreen && landscape ? touchSize.label : nil,
                              onTouchSize: nextTouchSize,
                              onQuit: quit)
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
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            gamepad.onButton = { [session] button, pressed in session.setButton(button, pressed: pressed) }
            gamepad.onAnalog = { [session] stick, x, y in session.setAnalog(stick: stick, x: x, y: y) }
            gamepad.onMenu = { showingMenu ? closeMenu() : openMenu() }
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
    /// Paysage : boutons sur deux colonnes pour tenir dans la hauteur de l'écran.
    let compact: Bool
    let onResume: () -> Void
    let onReset: () -> Void
    let onSwapScreens: (() -> Void)?
    /// DS en paysage : taille actuelle de l'écran tactile (nil = réglage masqué).
    let touchSizeLabel: String?
    let onTouchSize: () -> Void
    let onQuit: () -> Void

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
        items.append(Item(title: "Recommencer", icon: "arrow.counterclockwise", action: onReset))
        items.append(Item(title: "Quitter le jeu", icon: "xmark", destructive: true, action: onQuit))
        return items
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
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(items) { button($0) }
                    }
                } else {
                    HStack(spacing: 10) {
                        button(items[0])
                        button(items[1])
                    }
                    ForEach(items.dropFirst(2)) { button($0) }
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: compact ? 540 : 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .padding(compact ? 12 : 24)
        }
    }

    @ViewBuilder private var header: some View {
        if compact {
            HStack(spacing: 8) {
                SystemBadge(system: session.game.system)
                Text(session.game.title)
                    .font(.headline)
                    .lineLimit(1)
            }
        } else {
            VStack(spacing: 4) {
                SystemBadge(system: session.game.system)
                Text(session.game.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
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
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(prominent ? .white : (destructive ? Color.playTendoAccent : .primary))
                .background(prominent ? Color.playTendoAccent : Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
