import Foundation

struct Game: Identifiable, Hashable {
    let url: URL
    let system: GameSystem
    /// Identifiant stable : le chemin dans Jeux (le chemin complet change à chaque mise à jour de l'app).
    let key: String

    init(url: URL, system: GameSystem) {
        self.url = url
        self.system = system
        let root = Paths.games.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        key = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    var id: String { url.path }
    var baseName: String { url.deletingPathExtension().lastPathComponent }

    /// Titre sans les mentions entre parenthèses ou crochets : « Tetris (Europe) » → « Tetris ».
    var title: String {
        let name = baseName
        let cut = name.firstIndex { $0 == "(" || $0 == "[" } ?? name.endIndex
        let title = name[..<cut].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? name : title
    }
}
