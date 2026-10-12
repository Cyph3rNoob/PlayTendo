#if os(macOS)
import AppKit
import SwiftUI

/// Réglages › Clavier (Mac) : la touche de chaque commande, changée en cliquant dessus puis en appuyant sur la
/// nouvelle. Une touche prise par une autre commande lui est retirée ; celle du menu pause annule.
struct KeyboardSettingsSections: View {
    @ObservedObject private var bindings = KeyBindings.shared
    @StateObject private var capture = KeyCapture()

    private static let buttons: [(KeyCommand, String)] = [
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.l, "L"), (.r, "R"), (.l2, "L2 / ZL"), (.r2, "R2 / ZR"),
        (.start, "Start"), (.select, "Select"), (.home, "HOME (Wii), R3"),
    ]

    var body: some View {
        Section {
            row(tr("Croix"), [.up, .down, .left, .right])
            ForEach(Self.buttons, id: \.0) { command, name in
                row(name, [command])
            }
            row(tr("Stick gauche (consoles à stick)"), [.stickUp, .stickDown, .stickLeft, .stickRight])
            row(tr("Croix (consoles à stick)"), [.padUp, .padDown, .padLeft, .padRight])
            row(tr("Stick droit, boutons C (N64), C-Stick (GameCube, 3DS)"), [.cUp, .cDown, .cLeft, .cRight])
            row(tr("Menu pause"), [.menu])
            Button(tr("Rétablir les touches d'origine")) {
                capture.stop()
                bindings.resetAll()
            }
            .disabled(!bindings.isCustomized)
        } header: {
            Text(tr("Clavier"))
        } footer: {
            Text(tr("Clique sur une touche pour la changer, puis appuie sur la nouvelle (\(bindings.label(for: .menu)) pour annuler). Les touches sont à la même place sur un clavier AZERTY ou QWERTY ; leur nom suit ton clavier. Une manette Bluetooth ou USB (Xbox, PlayStation, Switch…) marche aussi, et prend la main dès qu'on s'en sert."))
        }
        .onDisappear { capture.stop() }

        Section {
            ForEach(KeyboardMap.consoleNotes, id: \.0) { action, keys in
                LabeledContent(action) {
                    Text(keys).font(Neon.mono(13, weight: .semibold)).foregroundStyle(Neon.cyan)
                }
            }
        } header: {
            Text(tr("Selon la console"))
        }
    }

    private func row(_ name: String, _ commands: [KeyCommand]) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                ForEach(commands) { command in
                    keyButton(command)
                }
            }
        }
    }

    private func keyButton(_ command: KeyCommand) -> some View {
        let waiting = capture.command == command
        return Button {
            if waiting {
                capture.stop()
            } else {
                capture.start(command) { keyCode in
                    // Touche du menu pause : annule (sans elle, on ne pourrait plus quitter une partie au clavier).
                    if command != .menu && bindings.isMenuKey(keyCode) { return }
                    bindings.assign(keyCode, to: command)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let arrow = command.arrow {
                    Text(arrow).foregroundStyle(.secondary)
                }
                Text(waiting ? tr("Appuie…") : bindings.label(for: command))
                    .foregroundStyle(waiting ? Neon.magenta : Neon.cyan)
            }
            .font(Neon.mono(13, weight: .semibold))
            .frame(minWidth: 40)
        }
        .buttonStyle(.bordered)
    }
}

/// Attend la prochaine touche du clavier (fenêtre de PlayTendo) pour une commande, et l'empêche d'aller ailleurs
/// (Échap fermerait les Réglages). Les raccourcis ⌘ passent.
@MainActor
private final class KeyCapture: ObservableObject {
    @Published private(set) var command: KeyCommand?
    private var monitor: Any?

    func start(_ command: KeyCommand, onKey: @escaping (Int) -> Void) {
        stop()
        self.command = command
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.modifierFlags.contains(.command) { return event }
            let keyCode = Int(event.keyCode)
            if event.type == .flagsChanged {
                // Touche de modification : seulement quand elle s'enfonce (⌘, ⇪ et fn ne sont pas des boutons).
                guard let side = KeyboardMap.modifierKeys[keyCode], event.modifierFlags.rawValue & side != 0 else {
                    return nil
                }
            } else if event.isARepeat {
                return nil
            }
            onKey(keyCode)
            self?.stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        command = nil
    }
}
#endif
