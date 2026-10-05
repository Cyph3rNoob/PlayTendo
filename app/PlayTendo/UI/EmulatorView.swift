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

    init(game: Game) {
        self.game = game
        _session = StateObject(wrappedValue: EmulatorSession(game: game))
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = ControlLayout.make(scheme: game.system.controls, aspect: session.aspectRatio,
                                            bounds: bounds, safe: Self.safeAreaInsets(),
                                            gamepad: gamepad.isConnected)
            ZStack {
                Color.black

                GameScreen(frameBuffer: session.frameBuffer)
                    .frame(width: layout.gameRect.width, height: layout.gameRect.height)
                    .position(x: layout.gameRect.midX, y: layout.gameRect.midY)

                TouchControls(layout: layout, scheme: game.system.controls, session: session, onMenu: openMenu)

                if session.state == .loading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }

                if showingMenu {
                    PauseMenu(session: session,
                              onResume: closeMenu,
                              onReset: { confirmingReset = true },
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
    let onResume: () -> Void
    let onReset: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onResume)

            VStack(spacing: 10) {
                VStack(spacing: 4) {
                    SystemBadge(system: session.game.system)
                    Text(session.game.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 6)

                MenuButton(title: "Reprendre", icon: "play.fill", prominent: true, action: onResume)
                HStack(spacing: 10) {
                    MenuButton(title: "Sauvegarder", icon: "square.and.arrow.down") {
                        session.saveState()
                        onResume()
                    }
                    MenuButton(title: "Charger", icon: "clock.arrow.circlepath") {
                        session.loadState()
                        onResume()
                    }
                    .disabled(!session.hasSaveState)
                    .opacity(session.hasSaveState ? 1 : 0.4)
                }
                MenuButton(title: session.isFastForwarding ? "Vitesse normale" : "Avance rapide ×3",
                           icon: session.isFastForwarding ? "tortoise.fill" : "forward.fill") {
                    session.toggleFastForward()
                    onResume()
                }
                if let disk = session.diskInfo {
                    MenuButton(title: "Changer de disque (\(disk.current)/\(disk.count))", icon: "opticaldisc") {
                        session.nextDisk()
                        onResume()
                    }
                }
                MenuButton(title: "Recommencer", icon: "arrow.counterclockwise", action: onReset)
                MenuButton(title: "Quitter le jeu", icon: "xmark", destructive: true, action: onQuit)
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .padding(24)
        }
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
