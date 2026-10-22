import SwiftUI

/// Menu pause › Codes de triche : les codes du jeu, écrits à la main ou téléchargés (« Codes disponibles »,
/// CheatLibrary), chacun avec son interrupteur. Ils s'appliquent tout de suite et restent pour ce jeu (Cheats).
struct CheatsView: View {
    @ObservedObject var session: EmulatorSession
    let title: String
    /// Nom officiel du jeu (base No-Intro / Redump de l'app) : pour trouver ses codes.
    let officialName: String?
    @Environment(\.dismiss) private var dismiss
    /// Code ouvert dans l'éditeur (nouveau ou existant) ; nil : la liste.
    @State private var editing: Cheat?
    @State private var deleting: Cheat?
    @State private var downloading = false
    @State private var downloadMessage: String?
    @State private var search = ""

    private var system: GameSystem { session.game.system }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Neon.background.ignoresSafeArea()
            ScrollView {
                // Paresseux : un jeu peut avoir plus de mille codes téléchargés.
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if let editing {
                        CheatEditor(cheat: editing, system: system,
                                    isNew: !session.cheats.contains { $0.id == editing.id },
                                    onSave: save, onCancel: { self.editing = nil })
                    } else {
                        list
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 50)
                .padding(.bottom, 40)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            closeButton
        }
#if os(macOS)
        // Taille fixe, comme la fiche d'un jeu (une feuille Mac prend sinon la taille de son contenu).
        .frame(width: 560, height: 640)
#endif
        .confirmationDialog(tr("Supprimer ce code ?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { cheat in
            Button(tr("Supprimer"), role: .destructive) {
                session.setCheats(session.cheats.filter { $0.id != cheat.id })
            }
            Button(tr("Annuler"), role: .cancel) {}
        } message: { cheat in
            Text(cheat.name)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            NeonSectionTitle(text: tr("CODES DE TRICHE"), color: Neon.magenta,
                             count: session.cheats.isEmpty ? nil : session.cheats.count)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Neon.dim)
                .lineLimit(2)
        }
    }

    // MARK: Liste

    @ViewBuilder private var list: some View {
        let downloaded = session.cheats.filter { $0.source != nil }
        if session.cheats.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Aucun code pour ce jeu."))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Neon.text)
                Text(CheatLibrary.isAvailable(for: system)
                     ? tr("Touche « Codes disponibles » pour récupérer ceux de ce jeu, ou ajoute un code trouvé sur un site spécialisé (GameHacking.org par exemple).")
                     : tr("Trouve des codes pour ce jeu sur un site spécialisé (GameHacking.org par exemple), puis ajoute-les ici."))
                    .font(.system(size: 13))
                    .foregroundStyle(Neon.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        }
        ForEach(session.cheats.filter { $0.source == nil }) { cheat in row(cheat) }
        CheatButton(title: tr("Ajouter un code"), icon: "plus", prominent: true) {
            editing = Cheat(name: "", code: "")
        }
        if CheatLibrary.isAvailable(for: system) {
            CheatButton(title: downloading ? tr("Recherche des codes…") : tr("Codes disponibles"),
                        icon: downloading ? nil : "arrow.down.circle", action: download)
                .disabled(downloading)
            if let downloadMessage {
                Text(downloadMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Neon.cyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !downloaded.isEmpty {
            NeonSectionTitle(text: tr("CODES TÉLÉCHARGÉS"), color: Neon.cyan, count: downloaded.count)
                .padding(.top, 8)
            if downloaded.count > 8 {
                TextField(tr("Chercher un code"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Neon.text)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Chamfer(cut: 8).fill(Neon.text.opacity(0.06)))
                    .overlay(Chamfer(cut: 8).stroke(Neon.text.opacity(0.25), lineWidth: 1))
            }
            ForEach(search.isEmpty ? downloaded : downloaded.filter { $0.name.localizedStandardContains(search) }) { cheat in
                row(cheat)
            }
            CheatButton(title: tr("Retirer les codes téléchargés coupés"), icon: "trash") {
                session.setCheats(session.cheats.filter { $0.source == nil || $0.enabled })
                search = ""
            }
        }
        Text(tr("Les codes s'appliquent tout de suite et restent pour ce jeu. Couper un code arrête son effet, mais ce qu'il a déjà changé dans la partie peut rester. Si un code bloque le jeu : coupe-le, puis Charger ou Recommencer."))
            .font(.system(size: 12))
            .foregroundStyle(Neon.dim)
            .fixedSize(horizontal: false, vertical: true)
        if CheatLibrary.isAvailable(for: system) {
            Text(Cheats.hasKinds(system)
                 ? tr("Codes disponibles : ceux fournis avec Dolphin et la base Gecko codes.rc24.xyz.")
                 : tr("Codes disponibles : base libretro-database (licence CC BY-SA 4.0)."))
                .font(Neon.mono(10, weight: .medium))
                .foregroundStyle(Neon.dim)
        }
#if os(macOS)
        CheatButton(title: tr("Fermer"), icon: nil) { dismiss() }
#endif
    }

    /// « Codes disponibles » : codes trouvés pour ce jeu, ajoutés coupés (sauf ceux déjà là).
    private func download() {
        downloading = true
        downloadMessage = nil
        Task {
            let message: String
            do {
                let result = try await CheatLibrary.download(for: session.game, officialName: officialName)
                let known = Set(session.cheats.map { CheatLibrary.codeKey($0.code) })
                var seen = Set<String>()
                let new = result.cheats.filter { cheat in
                    let key = CheatLibrary.codeKey(cheat.code)
                    return !known.contains(key) && seen.insert(key).inserted
                }
                if result.cheats.isEmpty {
                    message = tr("Aucun code trouvé pour ce jeu.")
                } else if new.isEmpty {
                    message = tr("Tous les codes trouvés sont déjà dans la liste.")
                } else {
                    session.setCheats(session.cheats + new)
                    var lines = [tr("\(new.count) codes ajoutés, coupés : active ceux que tu veux, un à la fois de préférence.")]
                    if new.contains(where: \.isMaster) {
                        lines.append(tr("Les codes « maîtres » (en tête) doivent être activés avec les autres codes du même appareil."))
                    }
                    if let other = result.otherVersion {
                        lines.append(tr("Codes de « \(other) » : ils peuvent ne pas marcher avec ta version."))
                    }
                    if result.skipped > 0 {
                        lines.append(tr("\(result.skipped) codes écartés : format que la console ne lit pas."))
                    }
                    message = lines.joined(separator: "\n")
                }
            } catch CheatLibrary.Failure.unknownGame {
                message = tr("Jeu non reconnu : impossible de trouver ses codes.")
            } catch {
                message = tr("Pas de connexion à Internet : réessaie plus tard.")
            }
            downloading = false
            downloadMessage = message
        }
    }

    private func row(_ cheat: Cheat) -> some View {
        HStack(spacing: 12) {
            Toggle(cheat.name, isOn: Binding(get: { cheat.enabled }, set: { on in
                var changed = cheat
                changed.enabled = on
                update(changed)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Neon.cyan)
            // Toucher le nom ou le code : modifier.
            Button { editing = cheat } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(cheat.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cheat.enabled ? Neon.text : Neon.dim)
                        .lineLimit(2)
                    Text(codeSummary(cheat))
                        .font(Neon.mono(11))
                        .foregroundStyle(Neon.dim)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { deleting = cheat } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Neon.magenta)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Supprimer"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Chamfer(cut: 9).fill(Neon.text.opacity(0.05)))
        .overlay(Chamfer(cut: 9).stroke(cheat.enabled ? Neon.cyan.opacity(0.5) : Neon.text.opacity(0.18), lineWidth: 1))
    }

    /// Le code sur une ligne (GameCube, Wii : précédé de son type ; code téléchargé : de sa source).
    private func codeSummary(_ cheat: Cheat) -> String {
        var parts: [String] = []
        if cheat.isMaster { parts.append(tr("CODE MAÎTRE")) }
        if let source = cheat.source {
            parts.append(source)
        } else if Cheats.hasKinds(system) {
            parts.append(cheat.kind == .gecko ? "Gecko" : "Action Replay")
        }
        parts.append(cheat.code.components(separatedBy: .newlines).joined(separator: " "))
        return parts.joined(separator: " · ")
    }

    private func update(_ cheat: Cheat) {
        var list = session.cheats
        if let index = list.firstIndex(where: { $0.id == cheat.id }) {
            list[index] = cheat
        } else {
            list.append(cheat)
        }
        session.setCheats(list)
    }

    private func save(_ cheat: Cheat) {
        update(cheat)
        editing = nil
    }

    private var closeButton: some View {
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
}

/// Nouveau code ou code modifié : nom, code (une ou plusieurs lignes), formats de la console. Un code dans un format
/// que la console ne connaît pas est refusé avec un message.
private struct CheatEditor: View {
    let original: Cheat
    let system: GameSystem
    let isNew: Bool
    let onSave: (Cheat) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var code: String
    /// GameCube, Wii : Action Replay ou Gecko (au départ : Gecko pour la Wii, où presque tous les codes le sont).
    @State private var kind: Cheat.Kind
    @State private var invalid = false

    init(cheat: Cheat, system: GameSystem, isNew: Bool, onSave: @escaping (Cheat) -> Void, onCancel: @escaping () -> Void) {
        original = cheat
        self.system = system
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: cheat.name)
        _code = State(initialValue: cheat.code)
        _kind = State(initialValue: cheat.kind ?? (system == .wii ? .gecko : .actionReplay))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? tr("NOUVEAU CODE") : tr("MODIFIER LE CODE"))
                .font(.display(12, weight: 800))
                .tracking(1.5)
                .foregroundStyle(Neon.cyan)
            label(tr("Nom"))
            TextField(tr("ex. Vies infinies"), text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Neon.text)
                .padding(10)
                .background(fieldBackground)
            if Cheats.hasKinds(system) {
                label(tr("Type"))
                HStack(spacing: 6) {
                    kindButton(.actionReplay, title: "Action Replay")
                    kindButton(.gecko, title: "Gecko")
                }
            }
            label(tr("Code"))
            TextEditor(text: $code)
                .font(Neon.mono(14))
                .foregroundStyle(Neon.text)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.characters)
#endif
                .frame(minHeight: 110)
                .padding(6)
                .background(fieldBackground)
                .overlay(alignment: .topLeading) {
                    if code.isEmpty {
                        Text(tr("Colle le code ici"))
                            .font(Neon.mono(14))
                            .foregroundStyle(Neon.dim.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: code) { _, _ in invalid = false }
            Text(Cheats.formats(for: system, kind: kind) + " " + tr("Un code sur plusieurs lignes : colle-les toutes."))
                .font(.system(size: 12))
                .foregroundStyle(Neon.dim)
                .fixedSize(horizontal: false, vertical: true)
            if invalid {
                Text(tr("Ce code n'est pas dans un format que cette console connaît. Vérifie qu'il est complet et fait pour cette console."))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Neon.magenta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                CheatButton(title: tr("Annuler"), icon: nil, action: onCancel)
                CheatButton(title: tr("Enregistrer"), icon: "checkmark", prominent: true, action: save)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func kindButton(_ value: Cheat.Kind, title: String) -> some View {
        let selected = value == kind
        return Button {
            kind = value
            invalid = false
        } label: {
            Text(title)
                .font(.display(13, weight: 800))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? Neon.onAccent : Neon.text)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Chamfer(cut: 7).fill(selected ? Neon.cyan : Neon.text.opacity(0.06)))
                .overlay(Chamfer(cut: 7).stroke(Neon.cyan.opacity(selected ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Neon.mono(11, weight: .bold))
            .tracking(1)
            .foregroundStyle(Neon.dim)
    }

    private var fieldBackground: some View {
        Chamfer(cut: 8)
            .fill(Neon.text.opacity(0.06))
            .overlay(Chamfer(cut: 8).stroke(Neon.text.opacity(0.25), lineWidth: 1))
    }

    private func save() {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Cheats.parts(of: text, system: system, kind: kind) != nil else {
            invalid = true
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cheat = original
        cheat.name = title.isEmpty ? tr("Code sans nom") : title
        cheat.code = text
        cheat.kind = Cheats.hasKinds(system) ? kind : nil
        onSave(cheat)
    }
}

/// Bouton de l'écran des codes (Ajouter, Enregistrer, Annuler, Fermer).
private struct CheatButton: View {
    let title: String
    let icon: String?
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Neon.onAccent : Neon.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Chamfer(cut: 10).fill(prominent ? Neon.cyan : Neon.text.opacity(0.07)))
            .overlay(Chamfer(cut: 10).stroke(prominent ? .clear : Neon.text.opacity(0.25), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
