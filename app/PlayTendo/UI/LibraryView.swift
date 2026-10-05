import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: GameLibrary
    @State private var importing = false
    @State private var showingAbout = false
    @State private var playing: Game?
    @State private var search = ""
    @State private var gameToDelete: Game?

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.games.isEmpty {
                    EmptyLibraryView { importing = true }
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(GameSystem.displayOrder) { system in
                            let games = filteredGames(for: system)
                            if !games.isEmpty {
                                SystemSection(system: system, games: games,
                                              onPlay: { playing = $0 },
                                              onDelete: { gameToDelete = $0 })
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .background(LibraryBackground())
            .navigationTitle("PlayTendo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("À propos")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Ajouter des jeux")
                }
            }
            .searchable(text: $search, prompt: "Rechercher un jeu")
            .refreshable { library.refresh() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .fullScreenCover(item: $playing) { game in
            EmulatorView(game: game)
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .alert("Supprimer ce jeu ?", isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } }),
               presenting: gameToDelete) { game in
            Button("Supprimer", role: .destructive) { library.delete(game) }
            Button("Annuler", role: .cancel) {}
        } message: { game in
            Text("« \(game.title) » sera supprimé de l'iPhone. Ses sauvegardes sont conservées.")
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            library.refresh()
        }
    }

    private func filteredGames(for system: GameSystem) -> [Game] {
        let games = library.games(for: system)
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return games }
        return games.filter { $0.baseName.localizedCaseInsensitiveContains(query) }
    }
}

private struct SystemSection: View {
    let system: GameSystem
    let games: [Game]
    let onPlay: (Game) -> Void
    let onDelete: (Game) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SystemBadge(system: system)
                Text(system.name)
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(games.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(games) { game in
                    Button { onPlay(game) } label: { GameTile(game: game) }
                        .buttonStyle(TileButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) { onDelete(game) } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
}

struct SystemBadge: View {
    let system: GameSystem

    var body: some View {
        Text(system.shortName)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LinearGradient(colors: system.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Capsule())
    }
}

private struct GameTile: View {
    let game: Game
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: game.system.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Text(game.system.shortName)
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(height: 104)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let detail = game.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .task(id: game.id) { loadThumbnail() }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { note in
            if note.object as? String == game.id { loadThumbnail() }
        }
    }

    private func loadThumbnail() {
        thumbnail = UIImage(contentsOfFile: Paths.thumbnailFile(for: game).path)
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [.playTendoAccent, Color(red: 0.25, green: 0.45, blue: 1)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Ta bibliothèque est vide")
                .font(.title2.weight(.bold))
            Text("Ajoute tes jeux avec le bouton ci-dessous (les .zip sont acceptés), ou dépose-les dans l'app Fichiers : **Sur mon iPhone › PlayTendo › Jeux**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button(action: onImport) {
                Label("Ajouter des jeux", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)

            FlowBadges()
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowBadges: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach([GameSystem.nes, .snes, .gb, .gbc]) { SystemBadge(system: $0) }
            }
            HStack(spacing: 8) {
                ForEach([GameSystem.gba, .nds, .psx]) { SystemBadge(system: $0) }
            }
        }
    }
}

struct LibraryBackground: View {
    var body: some View {
        ZStack {
            Color.playTendoBackground
            RadialGradient(colors: [Color.playTendoAccent.opacity(0.16), .clear], center: .topLeading,
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.2, green: 0.35, blue: 1).opacity(0.14), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
