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
        if (try? String(contentsOf: readme, encoding: .utf8)) != readmeText {
            try? readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Dossier « système » donné au moteur : les BIOS de l'utilisateur, sauf pour la PSP dont le
    /// moteur range ses propres fichiers (embarqués dans l'app) dans un dossier interne.
    static func systemDirectory(for system: GameSystem) -> URL {
        guard system == .psp else { return bios }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Systeme", isDirectory: true)
        installBundledFiles(named: "PPSSPP", into: folder)
        return folder
    }

    /// Recopie un dossier embarqué dans l'app quand il manque ou que l'app a changé.
    private static func installBundledFiles(named name: String, into folder: URL) {
        let fileManager = FileManager.default
        guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { return }
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        let marker = destination.appendingPathComponent(".version")
        let executableDate = Bundle.main.executableURL
            .flatMap { try? fileManager.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let version = "\(executableDate?.timeIntervalSince1970 ?? 0)"
        if (try? String(contentsOf: marker, encoding: .utf8)) == version { return }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            try version.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            PTLogLine("Copie des fichiers \(name) impossible : \(error.localizedDescription)")
        }
    }

    /// Dossier interne du moteur PS2 (réglages, journal `logs/emulog.txt`, caches). Ses BIOS sont dans BIOS
    /// avec les autres, ses cartes mémoire dans Sauvegardes/PS2.
    static let ps2Engine = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Systeme/PS2", isDirectory: true)

    /// Dossier interne du moteur GameCube/Wii (réglages, journal `Logs/dolphin.log`, caches). Ses sauvegardes
    /// sont dans Sauvegardes/GameCube (un fichier .gci par sauvegarde, par région) et Sauvegardes/Wii (mémoire
    /// interne de la console).
    static let dolphinEngine = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Systeme/Dolphin", isDirectory: true)

    /// Dossier « sauvegardes » donné au moteur. Pour la PSP, c'est la carte mémoire entière : la
    /// console y range ses sauvegardes dans PSP/SAVEDATA, comme sur une vraie carte. (Un dossier
    /// nommé « PSP » faisait passer PPSSPP dans un mode de compatibilité qui crée les dossiers de
    /// sauvegarde mais pas leurs fichiers sur un système sensible aux majuscules, comme l'iPhone.)
    static func coreSaveDirectory(for system: GameSystem) -> URL {
        guard system == .psp else { return saveDirectory(for: system) }
        removeEmptyPSPSaveFolders()
        return saves
    }

    /// Les dossiers de sauvegarde PSP restés vides à cause de ce bug font dire « données
    /// corrompues » au jeu : on retire ceux qui ne contiennent absolument rien.
    private static func removeEmptyPSPSaveFolders() {
        let fileManager = FileManager.default
        let folder = saves.appendingPathComponent("PSP/SAVEDATA", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for entry in entries where (try? fileManager.contentsOfDirectory(atPath: entry.path))?.isEmpty == true {
            try? fileManager.removeItem(at: entry)
            PTLogLine("Dossier de sauvegarde PSP vide retiré : \(entry.lastPathComponent)")
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
      NES .nes · Super Nintendo .sfc .smc · Nintendo 64 .z64 .n64 .v64
      Game Boy .gb · Game Boy Color .gbc · Game Boy Advance .gba · Nintendo DS .nds
      PlayStation .chd .pbp .m3u, ou .cue avec ses fichiers .bin
      PlayStation Portable .iso .cso .pbp
      PlayStation 2 .iso .chd .cso
      GameCube et Wii .iso .rvz .gcm .wbfs .wia .ciso .gcz
      Nintendo 3DS .3ds .cci .cxi .3dsx (jeux décryptés)
      Les .zip sont acceptés avec le bouton « + » de l'app.

    BIOS (facultatif)
      PlayStation : scph5501.bin (ou scph1001.bin…)
      Nintendo DS : bios7.bin, bios9.bin, firmware.bin
      Game Boy Advance : gba_bios.bin
      PlayStation 2 (obligatoire) : le BIOS de ta console, fichier .bin de 4 Mo
        (« SCPH-70004… », n'importe quel nom, PlayTendo le reconnaît)

    Sauvegardes
      Les sauvegardes de tes jeux. Copie ce dossier pour les mettre à l'abri.

    Journal.txt
      Le journal technique de l'app, utile en cas de problème.
      Journal-precedent.txt : celui de la session d'avant.
    """
}
