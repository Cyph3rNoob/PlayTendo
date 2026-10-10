import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var metadata: GameMetadata
    @EnvironmentObject private var jit: JITManager
    @State private var importing = false
    @State private var showingAbout = false
    @State private var showingSettings = false
    /// Jeu qui attend l'activation du JIT avant de démarrer.
    @State private var waitingForJIT: Game?
    @State private var jitFailure: JITFailure?
    @State private var playing: Game?
    @State private var search = ""
    @State private var filter: GameSystem?
    @State private var gameToDelete: Game?

    var body: some View {
        ZStack {
            CyberBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if library.games.isEmpty {
                        EmptyLibraryView { importing = true }
                            .padding(.top, 30)
                    } else {
                        searchField
                        filterChips
                        if filter == nil, search.isEmpty {
                            let recent = metadata.recentGames(in: library.games)
                            if !recent.isEmpty { continueRow(recent) }
                        }
                        sections
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { library.refresh() }

            // Fondu sombre derrière l'heure et la batterie quand les cartes défilent dessous.
            GeometryReader { proxy in
                LinearGradient(colors: [Neon.background, Neon.background.opacity(0.85), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: proxy.safeAreaInsets.top + 16)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        // Au retour d'une partie : un jeu PS Vita installé a pu quitter Jeux (sa copie installée le remplace).
        .fullScreenCover(item: $playing, onDismiss: { library.refresh() }) { game in
            EmulatorView(game: game)
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .overlay {
            if let game = waitingForJIT {
                JITActivationView(status: jit.status) {
                    // La préparation continue en arrière-plan : elle servira à la prochaine partie.
                    waitingForJIT = nil
                    launch(game)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: waitingForJIT)
        .alert("Mode turbo non activé", isPresented: Binding(get: { jitFailure != nil }, set: { if !$0 { jitFailure = nil } }),
               presenting: jitFailure) { failure in
            Button("Réessayer") { play(failure.game) }
            // La PS Vita ne peut pas tourner sans (Vita3K n'a pas d'interpréteur).
            if !JITManager.requires(failure.game.system) {
                Button("Jouer sans JIT") { launch(failure.game) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert("Supprimer ce jeu ?", isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } }),
               presenting: gameToDelete) { game in
            Button("Supprimer", role: .destructive) { library.delete(game) }
            Button("Annuler", role: .cancel) {}
        } message: { game in
            let extra = GameLibrary.files(of: game).count - 1
            let companions = extra == 1 ? " avec son fichier associé" : extra > 1 ? " avec ses \(extra) fichiers associés" : ""
            Text("« \(metadata.display(for: game).title) » sera supprimé de l'iPhone\(companions). Ses sauvegardes sont conservées.")
        }
        .overlay(alignment: .bottom) {
            if let message = library.message {
                ToastView(text: message)
                    .padding(.bottom, 30)
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if library.message == message { library.message = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: library.message)
        .animation(.easeInOut(duration: 0.2), value: filter)
        .task(id: library.games) { metadata.update(library.games) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            library.refresh()
        }
    }

    private func play(_ game: Game) {
        guard JITManager.benefits(game.system), jit.method != .off, !jit.isActive else {
            launch(game)
            return
        }
        waitingForJIT = game
        Task {
            do {
                try await jit.activate()
                if waitingForJIT == game {
                    waitingForJIT = nil
                    launch(game)
                }
            } catch {
                if waitingForJIT == game {
                    waitingForJIT = nil
                    let slow = JITManager.requires(game.system)
                        ? "\n\nSans turbo, la \(game.system.name) ne peut pas démarrer."
                        : [.ps2, .gameCube, .wii, .n3ds].contains(game.system)
                        ? "\n\nSans turbo, la \(game.system.name) est très lente (injouable)." : ""
                    jitFailure = JITFailure(game: game, message: error.localizedDescription + slow)
                }
            }
        }
    }

    private func launch(_ game: Game) {
        metadata.markPlayed(game)
        playing = game
    }

    // MARK: Haut de page

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("PLAYTENDO")
                .font(.orbitron(30, weight: 900))
                .tracking(2)
                .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                .shadow(color: Neon.cyan.opacity(0.55), radius: 10)
                .shadow(color: Neon.magenta.opacity(0.35), radius: 18)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            NeonIconButton(systemName: "info", color: Neon.violet) { showingAbout = true }
                .accessibilityLabel("À propos")
            NeonIconButton(systemName: "gearshape.fill", color: Neon.magenta) { showingSettings = true }
                .accessibilityLabel("Réglages")
            NeonIconButton(systemName: "plus") { importing = true }
                .accessibilityLabel("Ajouter des jeux")
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Neon.cyan)
            TextField("", text: $search, prompt: Text("RECHERCHER UN JEU").foregroundStyle(Neon.dim))
                .font(Neon.mono(14, weight: .medium))
                .foregroundStyle(Neon.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Neon.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Chamfer(cut: 10).fill(Color.white.opacity(0.04)))
        .overlay(Chamfer(cut: 10).stroke(LinearGradient(colors: [Neon.cyan.opacity(0.8), Neon.magenta.opacity(0.5)],
                                                         startPoint: .leading, endPoint: .trailing), lineWidth: 1))
    }

    private var presentSystems: [GameSystem] {
        let present = Set(library.games.map(\.system.libraryGroup))
        return GameSystem.libraryGroups.filter(present.contains)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "TOUT", color: Neon.cyan, selected: filter == nil) { filter = nil }
                ForEach(presentSystems) { system in
                    FilterChip(label: system.badgeName, color: system.neon, selected: filter == system) {
                        filter = filter == system ? nil : system
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
        }
        .padding(.vertical, -8)
    }

    // MARK: Continuer

    private func continueRow(_ games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NeonSectionTitle(text: "CONTINUER", color: Neon.magenta)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(games) { game in
                        Button { play(game) } label: { ContinueCard(game: game) }
                            .buttonStyle(CardPressStyle())
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
            }
            .padding(.vertical, -10)
        }
    }

    // MARK: Jeux

    private var sections: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(filter.map { [$0] } ?? GameSystem.libraryGroups) { system in
                let games = filteredGames(for: system)
                if !games.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        NeonSectionTitle(text: system.libraryTitle, color: system.neon, count: games.count)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14, alignment: .top)],
                                  spacing: 20) {
                            ForEach(games) { game in
                                Button { play(game) } label: { GameCard(game: game) }
                                    .buttonStyle(CardPressStyle())
                                    .contextMenu {
                                        Button { metadata.retryCover(for: game) } label: {
                                            Label("Actualiser la jaquette", systemImage: "arrow.clockwise")
                                        }
                                        Button(role: .destructive) { gameToDelete = game } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            if sectionsAreEmpty {
                Text("AUCUN JEU NE CORRESPOND")
                    .font(Neon.mono(13, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Neon.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
        }
    }

    private var sectionsAreEmpty: Bool {
        (filter.map { [$0] } ?? GameSystem.libraryGroups).allSatisfy { filteredGames(for: $0).isEmpty }
    }

    /// Jeux d'une console, triés par titre affiché, filtrés par la recherche.
    /// Jeux d'une catégorie (GB/C : Game Boy et Game Boy Color ensemble).
    private func filteredGames(for system: GameSystem) -> [Game] {
        let games = system.groupMembers.flatMap { library.games(for: $0) }
            .map { ($0, metadata.display(for: $0)) }
            .sorted { $0.1.sortKey.localizedStandardCompare($1.1.sortKey) == .orderedAscending }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return games.map(\.0) }
        return games.filter { game, display in
            display.title.localizedCaseInsensitiveContains(query)
                || (display.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
                || game.baseName.localizedCaseInsensitiveContains(query)
        }.map(\.0)
    }
}

private extension GameDisplay {
    var sortKey: String { subtitle.map { "\(title) \($0)" } ?? title }
}

// MARK: - Éléments

private struct FilterChip: View {
    let label: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.orbitron(12, weight: 800))
                .tracking(1.5)
                .foregroundStyle(selected ? Color.black : color)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Chamfer(cut: 8).fill(selected ? color : color.opacity(0.08)))
                .overlay(Chamfer(cut: 8).stroke(color.opacity(selected ? 0 : 0.55), lineWidth: 1))
                .shadow(color: selected ? color.opacity(0.7) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

/// Carte d'un jeu : jaquette, étiquette de console, titre, sous-titre et région.
private struct GameCard: View {
    @EnvironmentObject private var metadata: GameMetadata
    let game: Game

    var body: some View {
        let display = metadata.display(for: game)
        let color = game.system.neon
        VStack(alignment: .leading, spacing: 9) {
            // Cadre aux proportions fixes : les images se placent dedans sans pouvoir l'agrandir.
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { CoverArt(game: game, title: display.title) }
                .overlay(alignment: .topLeading) {
                    SystemBadge(system: game.system, size: 9).padding(9)
                }
                .clipShape(Chamfer(cut: 16))
                .overlay(Chamfer(cut: 16).stroke(LinearGradient(colors: [color, color.opacity(0.15), Neon.magenta.opacity(0.55)],
                                                                startPoint: .topLeading, endPoint: .bottomTrailing),
                                                 lineWidth: 1.2))
                .shadow(color: color.opacity(0.28), radius: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text(display.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Neon.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle = display.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Neon.text.opacity(0.65))
                        .lineLimit(1)
                }
                if let region = display.region {
                    Text(region.uppercased())
                        .font(Neon.mono(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(color.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Jaquette du jeu sur son propre reflet flouté, ou une jaquette générée en attendant.
private struct CoverArt: View {
    @EnvironmentObject private var metadata: GameMetadata
    let game: Game
    let title: String
    @State private var cover: UIImage?
    @State private var backdrop: UIImage?

    var body: some View {
        ZStack {
            if let cover {
                ZStack {
                    Color.black
                    if let backdrop {
                        Color.clear.overlay {
                            Image(uiImage: backdrop)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fill)
                                .opacity(0.55)
                        }
                        .clipped()
                    }
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                }
                .transition(.opacity)
            } else {
                GeneratedCover(system: game.system, title: title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(game.key)#\(metadata.coverRevision(for: game))") {
            guard let url = metadata.coverFile(for: game) else {
                cover = nil
                return
            }
            // Une version minuscule, agrandie, fait un flou d'arrière-plan qui ne coûte rien.
            backdrop = await CoverImages.load(url, maxPixel: 24)
            let image = await CoverImages.load(url)
            withAnimation(.easeOut(duration: 0.25)) { cover = image }
        }
    }
}

/// Jaquette de remplacement : dégradé de la console, grille et nom en Orbitron.
private struct GeneratedCover: View {
    let system: GameSystem
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [system.neon.opacity(0.35), Neon.panel, Color.black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var lines = Path()
                var x: CGFloat = -size.height
                while x < size.width {
                    lines.move(to: CGPoint(x: x, y: size.height))
                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 14
                }
                context.stroke(lines, with: .color(system.neon.opacity(0.08)), lineWidth: 1)
            }
            VStack(spacing: 10) {
                Text(system.badgeName)
                    .font(.orbitron(34, weight: 900))
                    .foregroundStyle(system.neon.opacity(0.85))
                    .neonGlow(system.neon, radius: 10)
                Text(title.uppercased())
                    .font(.orbitron(11, weight: 700))
                    .tracking(1)
                    .foregroundStyle(Neon.text.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// Carte large de la rangée « Continuer » : dernière image du jeu, jaquette et date.
private struct ContinueCard: View {
    @EnvironmentObject private var metadata: GameMetadata
    let game: Game
    @State private var snapshot: UIImage?
    @State private var cover: UIImage?

    var body: some View {
        let display = metadata.display(for: game)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let snapshot {
                    Image(uiImage: snapshot).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else if let cover {
                    Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill).blur(radius: 6).opacity(0.7)
                } else {
                    GeneratedCover(system: game.system, title: display.title)
                }
            }
            .frame(width: 270, height: 152)
            .clipped()
            .frame(width: 270, height: 152)

            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 10) {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 46, height: 62, alignment: .bottom)
                        .shadow(color: .black, radius: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Neon.text)
                        .lineLimit(1)
                    if let date = metadata.lastPlayedDate(for: game) {
                        Text(Self.relative(date))
                            .font(Neon.mono(10, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(Neon.magenta)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(Chamfer(cut: 7).fill(Neon.cyan))
                    .neonGlow(Neon.cyan, radius: 6)
            }
            .padding(12)
        }
        .frame(width: 270, height: 152)
        .overlay(alignment: .topLeading) { SystemBadge(system: game.system, size: 9).padding(10) }
        .clipShape(Chamfer(cut: 14))
        .overlay(Chamfer(cut: 14).stroke(LinearGradient(colors: [Neon.magenta, Neon.cyan.opacity(0.4)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
        .shadow(color: Neon.magenta.opacity(0.3), radius: 12)
        .task(id: "\(game.key)#\(metadata.coverRevision(for: game))") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { note in
            if note.object as? String == game.id {
                CoverImages.forget(Paths.thumbnailFile(for: game))
                Task { await load() }
            }
        }
    }

    private func load() async {
        snapshot = await CoverImages.load(Paths.thumbnailFile(for: game), maxPixel: 600)
        if let url = metadata.coverFile(for: game) { cover = await CoverImages.load(url) }
    }

    private static func relative(_ date: Date) -> String {
        // Partie qui vient de se terminer : le formateur dirait « dans 0 seconde ».
        guard Date().timeIntervalSince(date) >= 60 else { return "À L'INSTANT" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date()).uppercased()
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 58))
                .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .topLeading, endPoint: .bottomTrailing))
                .neonGlow(Neon.cyan, radius: 14)
            Text("BIBLIOTHÈQUE VIDE")
                .font(.orbitron(20, weight: 900))
                .tracking(2)
                .foregroundStyle(Neon.text)
            Text("Ajoute tes jeux avec le bouton ci-dessous (les .zip sont acceptés), ou dépose-les dans l'app Fichiers : **Sur mon iPhone › PlayTendo › Jeux**.")
                .font(.callout)
                .foregroundStyle(Neon.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(action: onImport) {
                Label("AJOUTER DES JEUX", systemImage: "plus")
                    .font(.orbitron(14, weight: 800))
                    .tracking(1.5)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Chamfer(cut: 12).fill(Neon.cyan))
                    .neonGlow(Neon.cyan, radius: 10)
            }
            .buttonStyle(.plain)

            VStack(spacing: 8) {
                HStack(spacing: 8) { ForEach([GameSystem.nes, .snes, .n64, .gameCube, .wii]) { SystemBadge(system: $0) } }
                HStack(spacing: 8) { ForEach([GameSystem.gb, .gba, .nds, .n3ds]) { SystemBadge(system: $0) } }
                HStack(spacing: 8) { ForEach([GameSystem.psx, .ps2, .psp, .vita]) { SystemBadge(system: $0) } }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }
}
