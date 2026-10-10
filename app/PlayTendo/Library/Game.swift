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
        if path.hasPrefix(root + "/") {
            key = String(path.dropFirst(root.count + 1))
            return
        }
#if PLAYTENDO_VITA
        if system == .vita && VitaGame.isInstalledCopy(url) {
            // Jeu PS Vita installé, dont l'original a quitté Jeux : même clé que le dossier « app/PCSA00011 » extrait
            // d'une Vita (la partie reste dans « Continuer »).
            key = "app/" + url.lastPathComponent
            return
        }
#endif
        key = url.lastPathComponent
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
