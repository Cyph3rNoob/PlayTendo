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
    /// Langue changée dans les Réglages : le contenu de la bibliothèque est refait aussitôt dans la nouvelle langue.
    @AppStorage(AppLanguage.key) private var language = AppLanguage.automatic
    /// Thème changé dans les Réglages : même chose.
    @AppStorage(AppTheme.key) private var theme = AppTheme.neon
#if os(macOS)
    /// Présentation pas encore vue : un jeu ouvert depuis le Finder est seulement ajouté (elle le cacherait).
    @AppStorage(WelcomeView.seenKey) private var welcomeSeen = 0
#endif

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
                .id("\(language.rawValue)-\(theme.rawValue)")
            }
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#endif
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
        // Bibliothèque relue au retour d'une partie (app compilée avec la PS Vita : un jeu installé a pu quitter Jeux,
        // sa copie installée le remplace).
#if os(iOS)
        .fullScreenCover(item: $playing, onDismiss: { library.refresh() }) { game in
            EmulatorView(game: game)
        }
#else
        // Mac : jeux glissés dans la fenêtre depuis le Finder.
        .dropDestination(for: URL.self) { urls, _ in
            guard playing == nil, !urls.isEmpty else { return false }
            library.importFiles(urls)
            return true
        }
        // Barre des menus (PlayTendoApp) : Ajouter des jeux, Réglages.
        .onReceive(NotificationCenter.default.publisher(for: .playTendoImportGames)) { _ in
            if playing == nil { importing = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playTendoShowSettings)) { _ in
            if playing == nil { showingSettings = true }
        }
        // Jeux ouverts depuis le Finder : ajoutés, puis lancés (un seul jeu, et aucune partie en cours).
        .onReceive(NotificationCenter.default.publisher(for: FinderOpen.notification)) { _ in openFromFinder() }
        .onAppear(perform: openFromFinder)
        .onChange(of: library.gameToLaunch) { _, game in
            guard let game else { return }
            library.gameToLaunch = nil
            guard playing == nil, waitingForJIT == nil, welcomeSeen >= WelcomeView.version else { return }
            showingSettings = false
            showingAbout = false
            play(game)
        }
#endif
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
        .alert(tr("Mode turbo non activé"), isPresented: Binding(get: { jitFailure != nil }, set: { if !$0 { jitFailure = nil } }),
               presenting: jitFailure) { failure in
            Button(tr("Réessayer")) { play(failure.game) }
            // Toujours proposé, sauf pour la PS Vita (app compilée avec elle : Vita3K n'a pas d'interpréteur).
            if !JITManager.requires(failure.game.system) {
                Button(tr("Jouer sans JIT")) { launch(failure.game) }
            }
            Button(tr("Annuler"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert(tr("Supprimer ce jeu ?"), isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } }),
               presenting: gameToDelete) { game in
#if PLAYTENDO_VITA
            // PS Vita : ses sauvegardes peuvent partir aussi (sinon gardées pour le réinstaller sans perdre la partie).
            if game.system == .vita {
                Button(tr("Supprimer, garder les sauvegardes")) { library.delete(game) }
                Button(tr("Tout supprimer, sauvegardes comprises"), role: .destructive) {
                    library.delete(game, removingSaves: true)
                }
            } else {
                Button(tr("Supprimer"), role: .destructive) { library.delete(game) }
            }
#else
            Button(tr("Supprimer"), role: .destructive) { library.delete(game) }
#endif
            Button(tr("Annuler"), role: .cancel) {}
        } message: { game in
            Text(deleteMessage(for: game))
        }
        .alert(library.importFailures.count == 1 ? tr("Fichier non ajouté") : tr("Fichiers non ajoutés"),
               isPresented: Binding(get: { !library.importFailures.isEmpty },
                                    set: { if !$0 { library.importFailures = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importFailures.joined(separator: "\n"))
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let progress = library.importProgress {
                    ImportProgressView(progress: progress, cancelling: library.importCancelRequested) {
                        library.cancelImport()
                    }
                }
                if let message = library.message {
                    ToastView(text: message)
                        .task(id: message) {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if library.message == message { library.message = nil }
                        }
                }
            }
            .padding(.bottom, 30)
        }
        .animation(.easeInOut(duration: 0.25), value: library.message)
        .animation(.easeInOut(duration: 0.25), value: library.importProgress == nil)
        .animation(.easeInOut(duration: 0.2), value: filter)
        .task(id: library.games) { metadata.update(library.games) }
#if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            library.refresh()
        }
#else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if playing == nil { library.refresh() }
        }
        // Partie : par-dessus tout le reste, dans la fenêtre (Échap ouvre le menu pause).
        .overlay {
            if let game = playing {
                EmulatorView(game: game) {
                    playing = nil
                    library.refresh()
                }
            }
        }
#endif
    }

#if PLAYTENDO_VITA
    /// PS Vita, menu du jeu : version (celle de sa mise à jour si elle est installée), DLC installés, et DLC ou mise à
    /// jour rangés dans Jeux qui seront installés au prochain lancement.
    private func vitaContentSummary(for game: Game) -> String? {
        guard let titleID = VitaGame.titleID(of: game.url) else { return nil }
        let installed = VitaGame.installedContent(titleID: titleID)
        let pending = VitaGame.pendingAddons(for: titleID).filter { !$0.isInstalled }.count
        var parts: [String] = []
        if let version = installed.version ?? VitaGame.version(of: game.url) { parts.append(tr("Version \(version)")) }
        if installed.dlcCount > 0 { parts.append(tr("\(installed.dlcCount) DLC")) }
        if pending > 0 { parts.append(tr("\(pending) à installer au prochain lancement")) }
        if VitaGame.rePatchFolder(for: titleID) != nil { parts.append("rePatch") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
#endif

    /// Message de la confirmation de suppression (fichiers associés, sauvegardes).
    private func deleteMessage(for game: Game) -> String {
        let title = metadata.display(for: game).title
#if PLAYTENDO_VITA
        if game.system == .vita {
#if os(iOS)
            return tr("« \(title) » sera supprimé de l'iPhone. Tu peux garder ses sauvegardes, pour le réinstaller sans perdre ta partie, ou les supprimer aussi.")
#else
            return tr("« \(title) » sera supprimé de ce Mac. Tu peux garder ses sauvegardes, pour le réinstaller sans perdre ta partie, ou les supprimer aussi.")
#endif
        }
#endif
        let extra = GameLibrary.files(of: game).count - 1
        let companions = extra == 1 ? tr(" avec son fichier associé")
            : extra > 1 ? tr(" avec ses \(extra) fichiers associés") : ""
#if os(iOS)
        return tr("« \(title) » sera supprimé de l'iPhone\(companions). Ses sauvegardes sont conservées.")
#else
        return tr("« \(title) » sera supprimé de ce Mac\(companions). Ses sauvegardes sont conservées.")
#endif
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
                        ? tr("\n\nSans turbo, la \(game.system.name) ne peut pas démarrer.")
                        : [.ps2, .gameCube, .wii, .n3ds].contains(game.system)
                        ? tr("\n\nSans turbo, la \(game.system.name) est très lente (injouable).") : ""
                    jitFailure = JITFailure(game: game, message: error.localizedDescription + slow)
                }
            }
        }
    }

    private func launch(_ game: Game) {
        metadata.markPlayed(game)
        playing = game
    }

#if os(macOS)
    private func openFromFinder() {
        let urls = FinderOpen.take()
        guard !urls.isEmpty else { return }
        library.importFiles(urls, launch: true)
    }
#endif

    // MARK: Haut de page

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("PLAYTENDO")
                .font(.display(30, weight: 900))
                .tracking(2)
                .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                .themedShadow(Neon.cyan.opacity(0.55), radius: 10)
                .shadow(color: theme == .neon ? Neon.magenta.opacity(0.35) : .clear, radius: 18)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            NeonIconButton(systemName: "info", color: Neon.violet) { showingAbout = true }
                .accessibilityLabel(tr("À propos"))
            NeonIconButton(systemName: "gearshape.fill", color: Neon.magenta) { showingSettings = true }
                .accessibilityLabel(tr("Réglages"))
            NeonIconButton(systemName: "plus") { importing = true }
                .accessibilityLabel(tr("Ajouter des jeux"))
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Neon.cyan)
            TextField("", text: $search, prompt: Text(tr("RECHERCHER UN JEU")).foregroundStyle(Neon.dim))
                .font(Neon.mono(14, weight: .medium))
                .foregroundStyle(Neon.text)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
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
        .background(Chamfer(cut: 10).fill(Neon.text.opacity(0.05)))
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
                FilterChip(label: tr("TOUT"), color: Neon.cyan, onColor: Neon.onAccent, selected: filter == nil) { filter = nil }
                ForEach(presentSystems) { system in
                    FilterChip(label: system.badgeName, note: system.isExperimental ? tr("EXPÉRIMENTAL") : nil,
                               color: system.neon, selected: filter == system) {
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
            NeonSectionTitle(text: tr("CONTINUER"), color: Neon.magenta)
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
#if PLAYTENDO_VITA
                                        if game.system == .vita, let summary = vitaContentSummary(for: game) {
                                            Text(summary)
                                        }
#endif
                                        Button { metadata.retryCover(for: game) } label: {
                                            Label(tr("Actualiser la jaquette"), systemImage: "arrow.clockwise")
                                        }
                                        Button(role: .destructive) { gameToDelete = game } label: {
                                            Label(tr("Supprimer"), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            if sectionsAreEmpty {
                Text(tr("AUCUN JEU NE CORRESPOND"))
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
    /// Petit mot après le nom (« EXPÉRIMENTAL » pour la PS Vita).
    var note: String?
    let color: Color
    /// Couleur du texte une fois la pastille choisie (posé sur `color`).
    var onColor = Neon.onConsole
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.display(12, weight: 800))
                    .tracking(1.5)
                if let note {
                    Text(note)
                        .font(.display(8, weight: 700))
                        .tracking(1)
                        .opacity(0.8)
                }
            }
                .foregroundStyle(selected ? onColor : color)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Chamfer(cut: 8).fill(selected ? color : color.opacity(0.08)))
                .overlay(Chamfer(cut: 8).stroke(color.opacity(selected ? 0 : 0.55), lineWidth: 1))
                .themedShadow(selected ? color.opacity(0.7) : .clear, radius: 8)
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
            CoverArt(game: game, title: display.title)

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

/// Jaquette du jeu seule, sans cadre (boîte 3D sur fond transparent), dans une place à la forme des boîtes de sa
/// console (BoxArt.aspect : couchée pour la N64, haute et étroite pour la PS Vita…) : toutes les boîtes d'une rangée ont
/// la même hauteur et reposent sur la même ligne. Sans jaquette : une jaquette générée, dans un cadre aux couleurs de
/// la console.
private struct CoverArt: View {
    @EnvironmentObject private var metadata: GameMetadata
    let game: Game
    let title: String
    @State private var cover: PlatformImage?

    var body: some View {
        let color = game.system.neon
        let file = metadata.coverFile(for: game)
        // Déjà en mémoire : affichée tout de suite, la carte garde sa taille en défilant.
        let shown = cover ?? file.flatMap { CoverImages.cached($0) }
        let aspect = BoxArt.aspect(for: game.system)
        Group {
            if let shown {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        Image(platformImage: shown)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 4)
                    }
                    .transition(.opacity)
            } else if file != nil {
                // Jaquette en cours de lecture : sa place, vide.
                Color.clear.aspectRatio(aspect, contentMode: .fit)
            } else {
                GeneratedCover(system: game.system, title: title)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        SystemBadge(system: game.system, size: 9).padding(9)
                    }
                    .clipShape(Chamfer(cut: 16))
                    .overlay(Chamfer(cut: 16).stroke(LinearGradient(colors: [color, color.opacity(0.15),
                                                                             Neon.magenta.opacity(0.55)],
                                                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                                     lineWidth: 1.2))
                    .themedShadow(color.opacity(0.28), radius: 12)
            }
        }
        .task(id: "\(game.key)#\(metadata.coverRevision(for: game))") {
            guard let file else {
                cover = nil
                return
            }
            let image = await CoverImages.load(file)
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
            LinearGradient(colors: [system.neon.opacity(0.35), Neon.panel, Neon.coverBase],
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
                    .font(.display(34, weight: 900))
                    .foregroundStyle(system.neon.opacity(0.85))
                    .neonGlow(system.neon, radius: 10)
                Text(title.uppercased())
                    .font(.display(11, weight: 700))
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
    @State private var snapshot: PlatformImage?
    @State private var cover: PlatformImage?

    var body: some View {
        let display = metadata.display(for: game)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let snapshot {
                    Image(platformImage: snapshot).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else if let cover {
                    Image(platformImage: cover).resizable().aspectRatio(contentMode: .fill).blur(radius: 6).opacity(0.7)
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
                    Image(platformImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 46, height: 62, alignment: .bottom)
                        .shadow(color: .black, radius: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    // Toujours clair : posé sur l'image du jeu assombrie, quel que soit le thème.
                    Text(display.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(white: 0.95))
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
                    .foregroundStyle(Neon.onAccent)
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
        .themedShadow(Neon.magenta.opacity(0.3), radius: 12)
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
        guard Date().timeIntervalSince(date) >= 60 else { return tr("À L'INSTANT") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
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

    private var hint: String {
#if os(iOS)
        tr("Ajoute tes jeux avec le bouton ci-dessous (les .zip, .7z et .rar sont acceptés), ou dépose-les dans l'app Fichiers : **Sur mon iPhone › PlayTendo › Jeux**.")
#else
        tr("Ajoute tes jeux avec le bouton ci-dessous, ou glisse-les dans cette fenêtre depuis le Finder (les .zip, .7z et .rar sont acceptés).")
#endif
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 58))
                .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .topLeading, endPoint: .bottomTrailing))
                .neonGlow(Neon.cyan, radius: 14)
            Text(tr("BIBLIOTHÈQUE VIDE"))
                .font(.display(20, weight: 900))
                .tracking(2)
                .foregroundStyle(Neon.text)
            Text(markdown: hint)
                .font(.callout)
                .foregroundStyle(Neon.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(action: onImport) {
                Label(tr("AJOUTER DES JEUX"), systemImage: "plus")
                    .font(.display(14, weight: 800))
                    .tracking(1.5)
                    .foregroundStyle(Neon.onAccent)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Chamfer(cut: 12).fill(Neon.cyan))
                    .neonGlow(Neon.cyan, radius: 10)
            }
            .buttonStyle(.plain)

            VStack(spacing: 8) {
                HStack(spacing: 8) { ForEach([GameSystem.nes, .snes, .n64, .gameCube, .wii]) { SystemBadge(system: $0) } }
                HStack(spacing: 8) { ForEach([GameSystem.gb, .gba, .nds, .n3ds]) { SystemBadge(system: $0) } }
                HStack(spacing: 8) { ForEach(GameSystem.displayOrder.filter { $0.brand == .sony }) { SystemBadge(system: $0) } }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Bandeau d'avancement de l'import : décompression ou copie d'un jeu, avec annulation.
struct ImportProgressView: View {
    let progress: GameLibrary.ImportProgress
    let cancelling: Bool
    let cancel: () -> Void

    private var fraction: Double? {
        progress.total > 0 ? min(1, Double(progress.done) / Double(progress.total)) : nil
    }

    private var title: String {
        let step = progress.step == .extracting ? tr("DÉCOMPRESSION") : tr("COPIE")
        return progress.count > 1 ? "\(step) · \(progress.index)/\(progress.count)" : step
    }

    private var detail: String {
        let format = AppLanguage.bytes
        if cancelling { return tr("Annulation…") }
        if let fraction { return tr("\(format(progress.done)) sur \(format(progress.total)) · \(Int(fraction * 100)) %") }
        return progress.done > 0 ? format(progress.done) : tr("Préparation…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: progress.step == .extracting ? "archivebox" : "doc.on.doc")
                    .foregroundStyle(Neon.cyan)
                Text(title)
                    .font(.display(11))
                    .foregroundStyle(Neon.cyan)
                Spacer()
                Button(action: cancel) {
                    Text(tr("ANNULER"))
                        .font(.display(10))
                        .foregroundStyle(Neon.magenta)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(Chamfer(cut: 5).stroke(Neon.magenta.opacity(0.8), lineWidth: 1))
                }
                .disabled(cancelling)
                .opacity(cancelling ? 0.4 : 1)
            }
            Text(progress.fileName)
                .font(Neon.mono(12, weight: .semibold))
                .foregroundStyle(Neon.text)
                .lineLimit(1)
                .truncationMode(.middle)
            bar
            Text(detail)
                .font(Neon.mono(11))
                .foregroundStyle(Neon.dim)
                .monospacedDigit()
        }
        .padding(14)
        .background(Chamfer(cut: 10).fill(Neon.panel.opacity(0.95)))
        .overlay(Chamfer(cut: 10).stroke(Neon.cyan.opacity(0.7), lineWidth: 1))
        .neonGlow(Neon.cyan, radius: 6)
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Neon.text.opacity(0.1))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * fraction))
                        .animation(.linear(duration: 0.1), value: fraction)
                } else {
                    // Taille inconnue : un trait qui va et vient.
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let position = (phase < 0.5 ? phase : 1 - phase) * 2 * proxy.size.width * 0.7
                        Capsule()
                            .fill(Neon.cyan)
                            .frame(width: proxy.size.width * 0.3)
                            .offset(x: position)
                    }
                }
            }
        }
        .frame(height: 6)
    }
}
