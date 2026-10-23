import SwiftUI

/// Menu pause › Commandes › Touches de la manette : pour la console en cours, ce que fait chaque bouton de la manette
/// (par sa place : bouton du bas, de droite…), un autre bouton de la console ou rien. Gardé tout de suite
/// (GamepadMapping) ; la croix et les sticks ne changent pas.
struct GamepadMappingView: View {
    let scheme: ControlScheme
    let title: String
    /// La manette branchée est une manette Nintendo (ses A, B, X, Y peuvent faire leur lettre d'origine).
    let nintendoPad: Bool
    let onChange: (GamepadMapping) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mapping: GamepadMapping

    init(scheme: ControlScheme, title: String, nintendoPad: Bool, onChange: @escaping (GamepadMapping) -> Void) {
        self.scheme = scheme
        self.title = title
        self.nintendoPad = nintendoPad
        self.onChange = onChange
        _mapping = State(initialValue: GamepadMapping.load(for: scheme))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Neon.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        NeonSectionTitle(text: tr("TOUCHES DE LA MANETTE"), color: Neon.magenta)
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Neon.dim)
                    }
                    .padding(.bottom, 6)
                    ForEach(GamepadInput.allCases, id: \.self) { input in row(input) }
                    Button {
                        mapping = GamepadMapping()
                        apply()
                    } label: {
                        Label(tr("Touches d'origine"), systemImage: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Neon.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Chamfer(cut: 10).fill(Neon.text.opacity(0.07)))
                            .overlay(Chamfer(cut: 10).stroke(Neon.text.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(mapping.changes.isEmpty)
                    .opacity(mapping.changes.isEmpty ? 0.4 : 1)
                    .padding(.top, 6)
                    Text(tr("Pour cette console seulement, gardé tout de suite. La croix et les sticks ne changent pas ; le bouton HOME ouvre toujours le menu pause."))
                        .font(.system(size: 12))
                        .foregroundStyle(Neon.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.top, 50)
                .padding(.bottom, 40)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Neon.text)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Neon.panel.opacity(0.9)))
                    .overlay(Circle().stroke(Neon.text.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(tr("Fermer"))
            .padding(14)
        }
#if os(macOS)
        .frame(width: 520, height: 640)
#endif
    }

    private func row(_ input: GamepadInput) -> some View {
        let original = input.defaultButton(letters: scheme.nintendoLetters, nintendoPad: nintendoPad)
        let current = mapping.button(for: input, default: original)
        let changed = mapping.changes[input] != nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(input.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Neon.text)
                if let detail = input.detail {
                    Text(detail)
                        .font(Neon.mono(11))
                        .foregroundStyle(Neon.dim)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(tr("D'origine") + (scheme.gamepadTargetName(original).map { " (\($0))" } ?? "")) {
                    set(input, nil)
                }
                ForEach(scheme.gamepadTargets, id: \.button) { target in
                    Button(target.name) { set(input, target.button.rawValue) }
                }
                Button(tr("Rien"), role: .destructive) { set(input, -1) }
            } label: {
                HStack(spacing: 6) {
                    Text(current.flatMap(scheme.gamepadTargetName) ?? tr("Rien"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(changed ? Neon.cyan : Neon.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Neon.dim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Chamfer(cut: 7).fill(Neon.text.opacity(0.07)))
                .overlay(Chamfer(cut: 7).stroke((changed ? Neon.cyan : Neon.text).opacity(0.35), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Chamfer(cut: 9).fill(Neon.text.opacity(0.04)))
    }

    /// Bouton choisi (numéro RetroPad), -1 pour rien, nil pour celui d'origine.
    private func set(_ input: GamepadInput, _ value: Int?) {
        mapping.changes[input] = value
        apply()
    }

    private func apply() {
        GamepadMapping.save(mapping, for: scheme)
        onChange(mapping)
    }
}
