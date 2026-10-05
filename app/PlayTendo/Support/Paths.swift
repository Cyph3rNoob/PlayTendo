import Foundation

/// Emplacements des fichiers de l'app. Tout ce qui est dans Documents est visible
/// dans l'app Fichiers (Sur mon iPhone › PlayTendo).
enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let games = documents.appendingPathComponent("Jeux", isDirectory: true)
    static let bios = documents.appendingPathComponent("BIOS", isDirectory: true)
    static let saves = documents.appendingPathComponent("Sauvegardes", isDirectory: true)
    static let logFile = documents.appendingPathComponent("Journal.txt")
    static let readme = documents.appendingPathComponent("Lisez-moi.txt")

    static let states = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Etats", isDirectory: true)

    static func prepare() {
        for folder in [games, bios, saves, states] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    static func saveDirectory(for system: GameSystem) -> URL {
        let url = saves.appendingPathComponent(system.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func saveRAMFile(for game: Game) -> URL {
        saveDirectory(for: game.system).appendingPathComponent(game.baseName + ".srm")
    }

    static let thumbnails = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vignettes", isDirectory: true)

    static func thumbnailFile(for game: Game) -> URL {
        let folder = thumbnails.appendingPathComponent(game.system.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(game.baseName + ".png")
    }

    static func stateFile(for game: Game) -> URL {
        let folder = states.appendingPathComponent(game.system.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(game.baseName + ".state")
    }

    private static let readmeText = """
    PlayTendo — où ranger quoi

    Jeux
      Mets tes jeux ici (tu peux créer des sous-dossiers) :
      NES .nes · Super Nintendo .sfc .smc · Game Boy .gb · Game Boy Color .gbc
      Game Boy Advance .gba · Nintendo DS .nds
      PlayStation .chd .pbp .m3u, ou .cue avec ses fichiers .bin
      Les .zip sont acceptés avec le bouton « + » de l'app.

    BIOS (facultatif)
      PlayStation : scph5501.bin (ou scph1001.bin…)
      Nintendo DS : bios7.bin, bios9.bin, firmware.bin
      Game Boy Advance : gba_bios.bin

    Sauvegardes
      Les sauvegardes de tes jeux. Copie ce dossier pour les mettre à l'abri.

    Journal.txt
      Le journal technique de l'app, utile en cas de problème.
    """
}
