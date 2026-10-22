import SwiftUI

/// Fiche d'un jeu, ouverte en touchant sa boîte dans la bibliothèque : grande jaquette, titre, bouton JOUER, puis ce que
/// ScreenScraper sait du jeu (résumé, sortie, éditeur, joueurs, genres, note) et le fichier. Les infos sont gardées
/// (GameMetadata) ; une fiche ouverte avant qu'elles soient venues les demande à ScreenScraper.
struct GameDetailView: View {
    let game: Game
    let onPlay: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var metadata: GameMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var cover: PlatformImage?
    @State private var state: Load = .loading
    @State private var expanded = false

    private enum Load { case loading, ready, missing, offline }

    var body: some View {
        let display = metadata.display(for: game)
        let info = metadata.details(for: game)
        ZStack(alignment: .topTrailing) {
            Neon.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero(display)
                    playButton
                    if let info { highlights(info) }
                    synopsis(info)
                    facts(info, display: display)
                    actions
#if os(macOS)
                    MenuCloseButton { dismiss() }
#endif
                    Text(tr("Infos et jaquettes : ScreenScraper.fr"))
                        .font(Neon.mono(10, weight: .medium))
                        .foregroundStyle(Neon.dim)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22)
                .padding(.top, 50)
                .padding(.bottom, 40)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            // Fond flou derrière la fiche, sans compter dans sa taille.
            .background(alignment: .top) { backdrop }
            closeButton
        }
#if os(macOS)
        // Taille fixe : une feuille Mac prend sinon la taille de son contenu (plus haute que l'écran, bouton de
        // fermeture hors d'atteinte).
        .frame(width: 600, height: 700)
#endif
        .task(id: metadata.coverRevision(for: game)) {
            if let file = metadata.coverFile(for: game) { cover = await CoverImages.load(file) }
        }
        .task {
            state = .loading
            switch await metadata.loadDetails(for: game) {
            case .ready: state = .ready
            case .missing: state = .missing
            case .offline: state = .offline
            }
        }
    }

    // MARK: Haut de la fiche

    /// La jaquette elle-même, très floue, en fond du haut de la fiche.
    @ViewBuilder private var backdrop: some View {
        if let cover {
            Image(platformImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 380)
                .frame(maxWidth: .infinity)
                .clipped()
                .blur(radius: 40)
                .opacity(0.35)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
    }

    private func hero(_ display: GameDisplay) -> some View {
        VStack(spacing: 16) {
            Group {
                if let cover {
                    Image(platformImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
                } else {
                    GeneratedCover(system: game.system, title: display.title)
                        .aspectRatio(BoxArt.aspect(for: game.system), contentMode: .fit)
                        .clipShape(Chamfer(cut: 16))
                }
            }
            .frame(maxHeight: BoxArt.aspect(for: game.system) > 1 ? 190 : 300)
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                SystemBadge(system: game.system, size: 10)
                Text(display.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Neon.text)
                    .multilineTextAlignment(.center)
                if let subtitle = display.subtitle {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Neon.text.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                if let region = display.region {
                    Text(region.uppercased())
                        .font(Neon.mono(11, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(game.system.neon)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var playButton: some View {
        let resumes = FileManager.default.fileExists(atPath: Paths.resumeFile(for: game).path)
        return VStack(spacing: 8) {
            Button {
                onPlay()
                dismiss()
            } label: {
                Label(tr("JOUER"), systemImage: "play.fill")
                    .font(.display(17, weight: 900))
                    .tracking(2)
                    .foregroundStyle(Neon.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Chamfer(cut: 12).fill(Neon.cyan))
                    .themedShadow(Neon.cyan.opacity(0.6), radius: 12)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            if resumes {
                Text(tr("Reprend là où tu t'étais arrêté."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Neon.dim)
            }
        }
    }

    // MARK: Infos ScreenScraper

    private var language: String { AppLanguage.isEnglish ? "en" : "fr" }

    /// Année, joueurs, genre et note, en pastilles.
    private func highlights(_ info: GameDetails) -> some View {
        let year = info.released.map { String($0.prefix(4)) }
        let genre = (info.genres[language] ?? info.genres.values.first)?.first
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                if let year { Chip(text: year, icon: "calendar") }
                if let players = info.players { Chip(text: playersText(players), icon: "person.2.fill") }
                if let genre { Chip(text: genre, icon: "tag.fill") }
            }
            if let rating = info.rating, rating > 0 { Stars(rating: rating) }
        }
        .frame(maxWidth: .infinity)
    }

    private func playersText(_ players: String) -> String {
        players == "1" ? tr("1 joueur") : tr("\(players) joueurs")
    }

    @ViewBuilder private func synopsis(_ info: GameDetails?) -> some View {
        let text = info.flatMap { $0.synopsis[language] ?? $0.synopsis.values.first }
        VStack(alignment: .leading, spacing: 10) {
            NeonSectionTitle(text: tr("RÉSUMÉ"), color: game.system.neon)
            if let text {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Neon.text.opacity(0.9))
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 320 {
                    Button(expanded ? tr("Réduire") : tr("Lire la suite")) {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Neon.cyan)
                }
            } else {
                switch state {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(tr("Recherche des infos sur ScreenScraper…"))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Neon.dim)
                case .offline:
                    note(tr("Infos indisponibles pour l'instant (pas de réseau, ou ScreenScraper surchargé). Rouvre la fiche plus tard."))
                case .ready, .missing:
                    note(tr("Pas de résumé pour ce jeu."))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Neon.dim)
    }

    /// Éditeur, développeur, sortie, joueurs, genres, puis le fichier.
    private func facts(_ info: GameDetails?, display: GameDisplay) -> some View {
        var rows: [(String, String)] = []
        if let info {
            if let publisher = info.publisher { rows.append((tr("Éditeur"), publisher)) }
            if let developer = info.developer, developer != info.publisher { rows.append((tr("Développeur"), developer)) }
            if let released = info.released { rows.append((tr("Sortie"), releaseText(released))) }
            if let players = info.players { rows.append((tr("Joueurs"), players)) }
            if let genres = info.genres[language] ?? info.genres.values.first, !genres.isEmpty {
                rows.append((tr("Genre"), genres.joined(separator: ", ")))
            }
        }
        rows.append((tr("Console"), game.system.name))
        rows.append((tr("Fichier"), game.url.lastPathComponent))
        if let size = fileSize { rows.append((tr("Taille"), size)) }
        if game.discs.count > 1 { rows.append((tr("Disques"), "\(game.discs.count)")) }
        return VStack(alignment: .leading, spacing: 10) {
            NeonSectionTitle(text: tr("INFOS"), color: game.system.neon)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.0)
                            .font(Neon.mono(12, weight: .semibold))
                            .foregroundStyle(Neon.dim)
                            .frame(width: 110, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Neon.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 9)
                    if index < rows.count - 1 {
                        Rectangle().fill(Neon.text.opacity(0.08)).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Chamfer(cut: 12).fill(Neon.panel.opacity(0.85)))
            .overlay(Chamfer(cut: 12).stroke(game.system.neon.opacity(0.25), lineWidth: 1))
        }
    }

    /// « 1997-03-01 » → « 1 mars 1997 » (ou « March 1, 1997 ») ; une année seule reste telle quelle.
    private func releaseText(_ value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard value.count == 10, let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.isEnglish ? "en_US" : "fr_FR")
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private var fileSize: String? {
        let files = game.discs.count > 1 ? game.discs : [game.url]
        let total = files.compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }.reduce(0, +)
        guard total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            ActionButton(title: tr("Actualiser la jaquette"), icon: "arrow.clockwise", color: Neon.text) {
                metadata.retryCover(for: game)
            }
            ActionButton(title: tr("Supprimer"), icon: "trash", color: Neon.magenta) {
                onDelete()
                dismiss()
            }
        }
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

/// Pastille d'info (année, joueurs, genre).
private struct Chip: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Neon.text)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Chamfer(cut: 7).fill(Neon.text.opacity(0.08)))
            .overlay(Chamfer(cut: 7).stroke(Neon.text.opacity(0.18), lineWidth: 1))
    }
}

/// Note de ScreenScraper (sur 20) en cinq étoiles, demi-étoiles comprises.
private struct Stars: View {
    let rating: Int

    var body: some View {
        let halves = Int((Double(rating) / 20 * 10).rounded())
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                let filled = halves - index * 2
                Image(systemName: filled >= 2 ? "star.fill" : filled == 1 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
            }
            Text("\(rating)/20")
                .font(Neon.mono(12, weight: .semibold))
                .foregroundStyle(Neon.dim)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Note : \(rating) sur 20"))
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Chamfer(cut: 9).fill(color.opacity(0.08)))
                .overlay(Chamfer(cut: 9).stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
/// Bas de la fiche (Mac) : Fermer, en plus de la croix et de la touche Échap.
private struct MenuCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tr("Fermer"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Neon.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Chamfer(cut: 9).fill(Neon.text.opacity(0.06)))
                .overlay(Chamfer(cut: 9).stroke(Neon.text.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
#endif
