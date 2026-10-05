import Foundation

struct Game: Identifiable, Hashable {
    let url: URL
    let system: GameSystem

    var id: String { url.path }
    var baseName: String { url.deletingPathExtension().lastPathComponent }

    /// Titre sans les mentions entre parenthèses ou crochets : « Tetris (Europe) » → « Tetris ».
    var title: String {
        let name = baseName
        let cut = name.firstIndex { $0 == "(" || $0 == "[" } ?? name.endIndex
        let title = name[..<cut].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? name : title
    }

    /// Première mention entre parenthèses (souvent la région).
    var detail: String? {
        let name = baseName
        guard let open = name.firstIndex(of: "("),
              let close = name[open...].firstIndex(of: ")") else { return nil }
        let text = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
