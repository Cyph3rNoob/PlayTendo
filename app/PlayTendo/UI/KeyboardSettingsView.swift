#if os(macOS)
import AppKit
import SwiftUI

/// Réglages › Clavier (Mac) : la console choisie par des pastilles (au départ celle du dernier jeu lancé), puis ses
/// touches. Pendant une partie, menu pause › Touches clavier montre les mêmes, pour la console en cours
/// (`KeyboardPanel`, EmulatorView).
struct KeyboardSettingsPage: View {
    @ObservedObject private var bindings = KeyBindings.shared
    @StateObject private var capture = KeyCapture()
    /// Console affichée : choisie ici, ou celle du dernier jeu lancé (EmulatorView).
    @AppStorage(KeyCapture.consoleKey) private var chosen = ""

    private var schemes: [ControlScheme] { ControlScheme.keyboardSchemes }
    private var scheme: ControlScheme { schemes.first { $0.keyboardID == chosen } ?? schemes.first ?? .nes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FlowLayout(spacing: 6) {
                    ForEach(schemes, id: \.keyboardID) { scheme in
                        chip(scheme)
                    }
                }
                KeyboardMapping(scheme: scheme, capture: capture)
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Les touches sont à la même place sur un clavier AZERTY ou QWERTY ; leur nom suit ton clavier. Une manette Bluetooth ou USB marche aussi."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(tr("Touches d'origine")) { capture.resetAll() }
                        .disabled(!bindings.isCustomized(scheme))
                }
            }
            .padding(20)
        }
        .onAppear { capture.attach(to: scheme) }
        .onChange(of: scheme.keyboardID) { _, _ in capture.attach(to: scheme) }
        .onDisappear { capture.detach() }
    }

    private func chip(_ option: ControlScheme) -> some View {
        let selected = option == scheme
        return Button {
            chosen = option.keyboardID
        } label: {
            Text(option.keyboardName)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Neon.cyan : Color.primary)
                .background(Capsule().fill(selected ? Neon.cyan.opacity(0.16) : Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(selected ? Neon.cyan.opacity(0.8) : Color.primary.opacity(0.14), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Les touches d'une console : une ligne d'aide (ou ce que fait la dernière touche essayée), les directions disposées
/// comme les flèches du clavier, les boutons, la souris et le menu pause. `neon` : style du menu pause.
struct KeyboardMapping: View {
    let scheme: ControlScheme
    @ObservedObject var capture: KeyCapture
    var neon = false
    @ObservedObject private var bindings = KeyBindings.shared

    private var directions: [KeyboardRow] { scheme.keyboardRows.filter(\.isDirections) }
    private var buttons: [KeyboardRow] { scheme.keyboardRows.filter { !$0.isDirections } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            group(tr("Déplacements")) {
                FlowLayout(spacing: 22, lineSpacing: 12) {
                    ForEach(directions) { row in
                        DirectionKeys(row: row, scheme: scheme, capture: capture, neon: neon)
                    }
                }
                .frame(maxWidth: .infinity)
                if let note = scheme.mouseNote {
                    Label(tr("\(note.action) : \(note.effect)"), systemImage: "computermouse")
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .padding(.top, 4)
                }
            }
            group(tr("Boutons")) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                          alignment: .leading, spacing: 6) {
                    ForEach(buttons) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            KeyCaps(command: row.commands[0], scheme: scheme, capture: capture, neon: neon)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(tr("Menu pause, toutes les consoles"))
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                KeyCaps(command: .menu, scheme: scheme, capture: capture, neon: neon)
            }
            if scheme.isWiimote {
                Text(tr("Un jeu Wii joué avec la manette GameCube (menu pause › Manette) prend les touches de la GameCube."))
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primary: Color { neon ? Neon.text : .primary }
    private var secondary: Color { neon ? Neon.dim : .secondary }

    /// En attente d'une touche, ce que fait la dernière touche essayée, ou l'aide ; « Annuler » après un changement.
    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: capture.command != nil ? "keyboard.badge.ellipsis" : "keyboard")
                .foregroundStyle(capture.command != nil ? Neon.cyan : secondary)
            Text(capture.command != nil
                    ? tr("Appuie sur la nouvelle touche (\(bindings.label(for: .menu, on: scheme)) pour annuler).")
                    : capture.status ?? tr("Clique une touche pour la changer. Appuie sur n'importe quelle touche pour voir à quoi elle sert."))
                .font(.system(size: 12, weight: capture.status == nil || capture.command != nil ? .regular : .semibold))
                .foregroundStyle(capture.command != nil ? Neon.cyan : primary)
                .fixedSize(horizontal: false, vertical: true)
            if capture.canUndo {
                Button(tr("Annuler")) { capture.undo() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Neon.cyan)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
    }

    @ViewBuilder private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        if neon {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.display(10, weight: 800))
                    .tracking(1.5)
                    .foregroundStyle(Neon.dim)
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chamfer(cut: 8).fill(Neon.text.opacity(0.04)))
            .overlay(Chamfer(cut: 8).stroke(Neon.cyan.opacity(0.18), lineWidth: 1))
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Une croix ou un stick : ↑ au-dessus, ← ↓ → dessous, comme les flèches du clavier.
private struct DirectionKeys: View {
    let row: KeyboardRow
    let scheme: ControlScheme
    @ObservedObject var capture: KeyCapture
    let neon: Bool

    var body: some View {
        // Commandes dans l'ordre haut, bas, gauche, droite.
        let commands = row.commands
        VStack(spacing: 4) {
            Text(row.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(neon ? Neon.dim : .secondary)
                .padding(.bottom, 2)
            KeyCaps(command: commands[0], scheme: scheme, capture: capture, neon: neon)
            HStack(spacing: 4) {
                KeyCaps(command: commands[2], scheme: scheme, capture: capture, neon: neon)
                KeyCaps(command: commands[1], scheme: scheme, capture: capture, neon: neon)
                KeyCaps(command: commands[3], scheme: scheme, capture: capture, neon: neon)
            }
        }
    }
}

/// Les touches d'une commande (Start : ↩ et Entrée du pavé), dessinées comme de vraies touches. Un clic attend la
/// nouvelle touche ; un nouveau clic annule.
struct KeyCaps: View {
    let command: KeyCommand
    let scheme: ControlScheme
    @ObservedObject var capture: KeyCapture
    var neon = false
    @ObservedObject private var bindings = KeyBindings.shared

    var body: some View {
        let waiting = capture.command == command
        let keys = bindings.keys(for: command, on: scheme)
        let labels = waiting ? ["…"] : (keys.isEmpty ? ["—"] : keys.map(KeyboardMap.label))
        Button {
            capture.toggle(command)
        } label: {
            HStack(spacing: 3) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    KeyCap(label: label, state: waiting ? .waiting : (capture.lit == command ? .lit : .normal), neon: neon)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scheme.keyboardLabel(for: command))
    }
}

/// Une touche : bord du bas plus épais, comme une touche de clavier.
private struct KeyCap: View {
    enum Look { case normal, waiting, lit }
    let label: String
    let state: Look
    let neon: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(label)
            .font(Neon.mono(12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .frame(minWidth: 32, minHeight: 26)
            .background(shape.fill(face))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .background(shape.fill(border.opacity(0.9)).offset(y: 2))
            .padding(.bottom, 2)
            .animation(.easeOut(duration: 0.15), value: state)
    }

    private var base: Color { neon ? Neon.text : .primary }

    private var textColor: Color {
        switch state {
        case .normal: neon ? Neon.cyan : .primary
        case .waiting: Neon.cyan
        case .lit: .green
        }
    }

    private var face: Color {
        switch state {
        case .normal: neon ? Neon.panel : Color(nsColor: .controlBackgroundColor)
        case .waiting: Neon.cyan.opacity(0.18)
        case .lit: Color.green.opacity(0.22)
        }
    }

    private var border: Color {
        switch state {
        case .normal: base.opacity(0.28)
        case .waiting: Neon.cyan
        case .lit: .green
        }
    }
}

/// Range ses éléments en lignes et passe à la ligne quand la place manque (pastilles, croix et sticks).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Lit le clavier tant que les touches d'une console sont affichées (Réglages › Clavier, menu pause › Touches
/// clavier). Après un clic sur une touche : la prochaine touche la remplace (celle du menu pause annule). Le reste du
/// temps : essai, la touche pressée s'allume et la ligne d'aide dit ce qu'elle fait. Les raccourcis ⌘ passent.
@MainActor
final class KeyCapture: ObservableObject {
    /// Console affichée par Réglages › Clavier (aussi celle du dernier jeu lancé).
    static let consoleKey = "clavierConsole"

    /// Commande qui attend sa nouvelle touche.
    @Published private(set) var command: KeyCommand?
    /// Commande de la dernière touche essayée (allumée un instant).
    @Published private(set) var lit: KeyCommand?
    /// Ce que fait la dernière touche essayée, ou ce qui vient de changer.
    @Published private(set) var status: String?
    @Published private(set) var canUndo = false

    private var scheme: ControlScheme = .nes
    private var monitor: Any?
    private var undoSnapshot: KeyBindings.Snapshot?
    private var unlight: Task<Void, Never>?

    /// Commence (ou continue) à lire le clavier pour cette console.
    func attach(to scheme: ControlScheme) {
        if scheme != self.scheme {
            command = nil
            status = nil
            clearUndo()
        }
        self.scheme = scheme
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        command = nil
        lit = nil
        status = nil
        clearUndo()
    }

    /// Clic sur une touche : elle attend la nouvelle ; un second clic annule.
    func toggle(_ command: KeyCommand) {
        self.command = self.command == command ? nil : command
        if self.command != nil {
            status = nil
            clearUndo()
        }
    }

    func undo() {
        if let undoSnapshot { KeyBindings.shared.restore(undoSnapshot) }
        clearUndo()
        status = tr("Changement annulé.")
    }

    /// Touches d'origine pour la console et le menu pause (annulable).
    func resetAll() {
        command = nil
        let before = KeyBindings.shared.snapshot()
        KeyBindings.shared.reset(scheme)
        undoSnapshot = before
        canUndo = true
        status = tr("Touches d'origine remises pour : \(scheme.keyboardName).")
    }

    private func clearUndo() {
        undoSnapshot = nil
        canUndo = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) { return event }
        let keyCode = Int(event.keyCode)
        if event.type == .flagsChanged {
            // Touche de modification : seulement quand elle s'enfonce (⌘, ⇪ et fn ne sont pas des boutons).
            guard let side = KeyboardMap.modifierKeys[keyCode], event.modifierFlags.rawValue & side != 0 else {
                return command == nil ? event : nil
            }
        }
        let bindings = KeyBindings.shared
        let key = KeyboardMap.label(keyCode)

        if let waiting = command {
            if event.isARepeat { return nil }
            command = nil
            // Touche du menu pause : annule (sans elle, on ne pourrait plus quitter une partie au clavier).
            if waiting != .menu && bindings.isMenuKey(keyCode) {
                status = nil
                return nil
            }
            let before = bindings.snapshot()
            let losers = bindings.assign(keyCode, to: waiting, on: scheme)
            undoSnapshot = before
            canUndo = true
            if let loser = losers.first {
                let name = scheme.keyboardLabel(for: loser)
                status = bindings.keys(for: loser, on: scheme).isEmpty
                    ? tr("\(key) était sur \(name) : \(name) n'a plus de touche.")
                    : tr("\(key) était aussi sur \(name).")
            } else {
                status = tr("\(scheme.keyboardLabel(for: waiting)) : \(key)")
            }
            light(waiting)
            return nil
        }

        // Essai.
        let found = bindings.command(for: keyCode, on: scheme)
        if !event.isARepeat {
            clearUndo()
            if let found {
                status = tr("\(key) : \(scheme.keyboardLabel(for: found))")
                light(found)
            } else {
                status = tr("\(key) : aucune commande sur \(scheme.keyboardName)")
            }
        }
        // Les touches de la console ne vont pas plus loin (Entrée validerait les Réglages, le jeu en pause ne les reçoit
        // pas) ; celle du menu pause continue son chemin (en partie, elle ferme le menu).
        return found == nil || found == .menu ? event : nil
    }

    private func light(_ command: KeyCommand) {
        lit = command
        unlight?.cancel()
        unlight = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.lit = nil
        }
    }
}
#endif
