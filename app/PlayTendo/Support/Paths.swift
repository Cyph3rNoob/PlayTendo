import Foundation
import os

/// Emplacements des fichiers de l'app. Tout ce qui est dans Documents est visible
/// dans l'app Fichiers (Sur mon iPhone › PlayTendo).
///
/// Sur Mac (app sans bac à sable), les mêmes dossiers sont rangés à part pour ne rien mêler aux fichiers de
/// l'utilisateur : `documents` = ~/Library/Application Support/PlayTendo (Réglages › Dossiers l'ouvre dans le
/// Finder), `support` = ~/Library/Application Support/com.playtendo.mac (fichiers internes).
enum Paths {
#if os(iOS)
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// Fichiers internes : Application Support de l'app.
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#else
    static let documents = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlayTendo", isDirectory: true)
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.playtendo.mac", isDirectory: true)
#endif
    static let games = documents.appendingPathComponent("Jeux", isDirectory: true)
    static let bios = documents.appendingPathComponent("BIOS", isDirectory: true)
    static let saves = documents.appendingPathComponent("Sauvegardes", isDirectory: true)
    static let logFile = documents.appendingPathComponent("Journal.txt")

    static let states = support
        .appendingPathComponent("Etats", isDirectory: true)

    static func prepare() {
        for folder in [documents, games, bios, saves, states] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        writeReadme()
#if !PLAYTENDO_VITA
        removeVitaLeftovers()
#endif
    }

#if !PLAYTENDO_VITA
    /// PS Vita mise de côté (2026-10-10, rendu de Vita3K trop abîmé sur les puces Apple) : ce qu'une version précédente
    /// de l'app avait installé (jeux, sauvegardes, firmware, réglages et journal du moteur, icônes) est effacé, à sa
    /// demande. Ne trouve plus rien une fois fait.
    private static func removeVitaLeftovers() {
        let manager = FileManager.default
        let folders = [support.appendingPathComponent("Systeme/Vita"), support.appendingPathComponent("Jaquettes/Vita"),
                       thumbnails.appendingPathComponent("Vita"), states.appendingPathComponent("Vita"),
                       saves.appendingPathComponent("Vita")]
        var freed: Int64 = 0
        for folder in folders where manager.fileExists(atPath: folder.path) {
            let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            while let file = files?.nextObject() as? URL {
                freed += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            do {
                try manager.removeItem(at: folder)
            } catch {
                PTLogLine("PS Vita : \(folder.lastPathComponent) impossible à effacer (\(error.localizedDescription))")
            }
        }
        UserDefaults.standard.removeObject(forKey: "precisionVita")
        if freed > 0 {
            PTLogLine(String(format: "PS Vita retirée de l'app : jeux installés et sauvegardes effacés (%.2f Go libérés)",
                             Double(freed) / 1e9))
        }
    }
#endif

    /// Dossier « système » donné au moteur : les BIOS de l'utilisateur, sauf pour la PSP dont le
    /// moteur range ses propres fichiers (embarqués dans l'app) dans un dossier interne.
    static func systemDirectory(for system: GameSystem) -> URL {
        guard system == .psp else { return bios }
        let folder = support
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
    static let ps2Engine = support
        .appendingPathComponent("Systeme/PS2", isDirectory: true)

    /// Dossier interne du moteur GameCube/Wii (réglages, journal `Logs/dolphin.log`, caches). Ses sauvegardes
    /// sont dans Sauvegardes/GameCube (un fichier .gci par sauvegarde, par région) et Sauvegardes/Wii (mémoire
    /// interne de la console).
    static let dolphinEngine = support
        .appendingPathComponent("Systeme/Dolphin", isDirectory: true)

#if PLAYTENDO_VITA
    /// Dossier interne du moteur PS Vita : la mémoire de la console (`vita/` : firmware, jeux installés et
    /// déchiffrés dans ux0/app, sauvegardes des jeux dans ux0/user), réglages, caches et journal `vita3k.log`.
    static let vitaEngine = support
        .appendingPathComponent("Systeme/Vita", isDirectory: true)

    /// Les jeux installés (des Go) et les caches ne vont pas dans la sauvegarde iCloud de l'iPhone. Leur original
    /// quitte Jeux après l'installation : après une restauration, il faut les remettre depuis l'original gardé
    /// ailleurs (Mac, Vita). Les sauvegardes des jeux, elles, restent dans la sauvegarde iCloud.
    static func prepareVitaEngine() {
        for relative in ["vita/ux0/app", "vita/ux0/patch", "vita/ux0/addcont", "cache"] {
            var folder = vitaEngine.appendingPathComponent(relative, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
    }
#endif

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
        saveDirectory(for: game.system).appendingPathComponent(fileName(for: game) + ".srm")
    }

    // MARK: Nom des fichiers d'un jeu

    /// Nom de la sauvegarde (.srm), de la sauvegarde rapide et de la vignette d'un jeu : le nom de son fichier, sauf si
    /// un autre jeu de la même console, rangé ailleurs dans Jeux, l'a déjà (« EU/Zelda.gba » et « US/Zelda.gba ») :
    /// celui arrivé en second (ou rangé plus profond) y ajoute son dossier (« Zelda (US) »). Attribués par
    /// `assignFileNames` à chaque lecture de Jeux. Les sauvegardes que certains moteurs rangent eux-mêmes (PSP, PS2,
    /// GameCube/Wii, 3DS…) ne sont pas concernées.
    static func fileName(for game: Game) -> String {
        fileNames.withLock { $0?[fileNameID(game)] } ?? game.baseName
    }

    /// « dossier de la console/chemin dans Jeux » → nom attribué ; chargé à la première lecture de Jeux.
    private static let fileNames = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
    private static let fileNamesKey = "nomsFichiersJeux"

    private static func fileNameID(_ game: Game) -> String { "\(game.system.folderName)/\(game.key)" }

    /// Donne un nom à chaque nouveau jeu. Un jeu qui n'est plus dans Jeux libère le sien : déplacé dans un autre
    /// dossier, il le reprend, avec ses sauvegardes. Rien n'est libéré si aucun jeu connu n'est trouvé (dossier Jeux
    /// illisible à ce moment-là, par prudence).
    static func assignFileNames(to games: [Game]) {
        let copies = fileNames.withLock { stored -> [(game: Game, name: String)] in
            var copies: [(game: Game, name: String)] = []
            let defaults = UserDefaults.standard
            let firstTime = stored == nil && defaults.object(forKey: fileNamesKey) == nil
            var names = stored ?? (defaults.dictionary(forKey: fileNamesKey) as? [String: String] ?? [:])
            let before = names

            let present = Set(names.keys.filter { id in
                let key = id.drop { $0 != "/" }.dropFirst()
                return FileManager.default.fileExists(atPath: Paths.games.appendingPathComponent(String(key)).path)
            })
            // Noms libérés par les jeux disparus : un jeu du même nom apparu en même temps (déplacé dans Jeux) les reprend.
            var released: [(console: String, base: String, name: String)] = []
            if !present.isEmpty {
                for (id, name) in names where !present.contains(id) {
                    let file = (String(id.drop { $0 != "/" }.dropFirst()) as NSString).lastPathComponent
                    released.append((String(id.prefix { $0 != "/" }), (file as NSString).deletingPathExtension.lowercased(), name))
                }
                names = names.filter { present.contains($0.key) }
            }

            var taken: [String: Set<String>] = [:]
            for (id, name) in names {
                taken[String(id.prefix { $0 != "/" }), default: []].insert(name.lowercased())
            }
            // Les jeux rangés à la racine de Jeux d'abord : ils gardent leur nom, ceux des sous-dossiers prennent le leur.
            let ordered = games.sorted { lhs, rhs in
                let depths = (lhs.key.filter { $0 == "/" }.count, rhs.key.filter { $0 == "/" }.count)
                return depths.0 != depths.1 ? depths.0 < depths.1 : lhs.key < rhs.key
            }
            for game in ordered where names[fileNameID(game)] == nil {
                let console = game.system.folderName
                var name = game.baseName
                if let index = released.firstIndex(where: { $0.console == console && $0.base == game.baseName.lowercased()
                                                             && !taken[console, default: []].contains($0.name.lowercased()) }) {
                    name = released.remove(at: index).name
                    if name != game.baseName { PTLogLine("Sauvegardes de \(game.key) : « \(name) » reprises (jeu déplacé)") }
                } else if taken[console, default: []].contains(name.lowercased()) {
                    let folder = game.key.split(separator: "/").dropLast().joined(separator: " - ")
                    let base = "\(game.baseName) (\(folder.isEmpty ? "Jeux" : folder))"
                    name = base
                    var number = 2
                    while taken[console, default: []].contains(name.lowercased()) {
                        name = "\(base) \(number)"
                        number += 1
                    }
                    // Mise à jour de l'app : jusque-là, ces jeux partageaient les fichiers à leur nom. Chacun garde sa
                    // copie de la progression.
                    if firstTime { copies.append((game, name)) }
                    PTLogLine("Sauvegardes de \(game.key) : nommées « \(name) » (un autre jeu \(game.system.shortName) a le même nom)")
                }
                names[fileNameID(game)] = name
                taken[console, default: []].insert(name.lowercased())
            }
            stored = names
            if names != before || firstTime { defaults.set(names, forKey: fileNamesKey) }
            return copies
        }
        for (game, name) in copies {
            let pairs = [(saveDirectory(for: game.system), "srm"),
                         (states.appendingPathComponent(game.system.folderName), "state"),
                         (thumbnails.appendingPathComponent(game.system.folderName), "png")]
            for (folder, ext) in pairs {
                let shared = folder.appendingPathComponent("\(game.baseName).\(ext)")
                let own = folder.appendingPathComponent("\(name).\(ext)")
                guard FileManager.default.fileExists(atPath: shared.path),
                      !FileManager.default.fileExists(atPath: own.path) else { continue }
                try? FileManager.default.copyItem(at: shared, to: own)
            }
        }
    }

    static let thumbnails = support
        .appendingPathComponent("Vignettes", isDirectory: true)

    static func thumbnailFile(for game: Game) -> URL {
        let folder = thumbnails.appendingPathComponent(game.system.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName(for: game) + ".png")
    }

    static func stateFile(for game: Game) -> URL {
        let folder = states.appendingPathComponent(game.system.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName(for: game) + ".state")
    }

    /// « Lisez-moi.txt » à la racine de Documents (« Read Me.txt » quand l'app est en anglais : l'autre est retiré),
    /// réécrit s'il a changé. Appelé au lancement et quand la langue change.
    static func writeReadme() {
        let english = AppLanguage.isEnglish
        let file = documents.appendingPathComponent(english ? "Read Me.txt" : "Lisez-moi.txt")
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(english ? "Lisez-moi.txt" : "Read Me.txt"))
#if os(iOS)
        let text = english ? readmeTextEnglish : readmeText
#else
        let text = macReadme(english: english)
#endif
        if (try? String(contentsOf: file, encoding: .utf8)) != text {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static let readmeText = """
    PlayTendo — où ranger quoi

    Jeux
      Mets tes jeux ici (tu peux créer des sous-dossiers) :
      NES .nes · Super Nintendo .sfc .smc · Nintendo 64 .z64 .n64 .v64
      Game Boy .gb · Game Boy Color .gbc · Game Boy Advance .gba · Nintendo DS .nds
      PlayStation .chd .pbp .m3u, ou .cue avec ses fichiers .bin
      PlayStation 2 .iso .chd .cso
      PlayStation Portable .iso .cso .pbp
      GameCube et Wii .iso .rvz .gcm .wbfs .wia .ciso .gcz
      Nintendo 3DS .3ds .cci .cxi .3dsx (jeux décryptés)

    """ + readmeVitaGames + """
      Les archives .zip, .7z et .rar sont acceptées avec le bouton « + » de l'app.

    BIOS (facultatif)
      PlayStation : scph5501.bin (ou scph1001.bin…)
      Nintendo DS : bios7.bin, bios9.bin, firmware.bin
      Game Boy Advance : gba_bios.bin
      PlayStation 2 (obligatoire) : le BIOS de ta console, fichier .bin de 4 Mo
        (« SCPH-70004… », n'importe quel nom, PlayTendo le reconnaît),
        ou dans l'app : Réglages › BIOS PS2 › Importer un BIOS PS2

    """ + readmeVitaBIOS + """

    Sauvegardes
      Les sauvegardes de tes jeux. Copie ce dossier pour les mettre à l'abri.

    Journal.txt
      Le journal technique de l'app, utile en cas de problème.
      Journal-precedent.txt : celui de la session d'avant.
    """

    private static let readmeTextEnglish = """
    PlayTendo — what goes where

    Jeux (games)
      Put your games here (you can make subfolders):
      NES .nes · Super Nintendo .sfc .smc · Nintendo 64 .z64 .n64 .v64
      Game Boy .gb · Game Boy Color .gbc · Game Boy Advance .gba · Nintendo DS .nds
      PlayStation .chd .pbp .m3u, or .cue with its .bin files
      PlayStation 2 .iso .chd .cso
      PlayStation Portable .iso .cso .pbp
      GameCube and Wii .iso .rvz .gcm .wbfs .wia .ciso .gcz
      Nintendo 3DS .3ds .cci .cxi .3dsx (decrypted games)

    """ + readmeVitaGamesEnglish + """
      .zip, .7z and .rar archives are accepted with the app's “+” button.

    BIOS (optional)
      PlayStation: scph5501.bin (or scph1001.bin…)
      Nintendo DS: bios7.bin, bios9.bin, firmware.bin
      Game Boy Advance: gba_bios.bin
      PlayStation 2 (required): your console's BIOS, a 4 MB .bin file
        (“SCPH-70004…”, any name, PlayTendo recognizes it),
        or in the app: Settings › PS2 BIOS › Import a PS2 BIOS

    """ + readmeVitaBIOSEnglish + """

    Sauvegardes (saves)
      Your games' saves. Copy this folder to keep them safe.

    Journal.txt
      The app's technical log (in French), useful if something goes wrong.
      Journal-precedent.txt: the one from the previous session.
    """

#if os(macOS)
    /// Lisez-moi du Mac : seulement les consoles déjà dans l'app (elles arrivent étape par étape).
    private static func macReadme(english: Bool) -> String {
        let installed = { (systems: [GameSystem]) in systems.contains(where: EmulatorSession.engineInstalled) }
        let games: [([GameSystem], String, String)] = [
            ([.nes], "NES .nes", "NES .nes"),
            ([.snes], "Super Nintendo .sfc .smc", "Super Nintendo .sfc .smc"),
            ([.n64], "Nintendo 64 .z64 .n64 .v64", "Nintendo 64 .z64 .n64 .v64"),
            ([.gb, .gbc, .gba], "Game Boy .gb · Game Boy Color .gbc · Game Boy Advance .gba",
             "Game Boy .gb · Game Boy Color .gbc · Game Boy Advance .gba"),
            ([.nds], "Nintendo DS .nds", "Nintendo DS .nds"),
            ([.psx], "PlayStation .chd .pbp .m3u, ou .cue avec ses fichiers .bin",
             "PlayStation .chd .pbp .m3u, or .cue with its .bin files"),
            ([.ps2], "PlayStation 2 .iso .chd .cso", "PlayStation 2 .iso .chd .cso"),
            ([.psp], "PlayStation Portable .iso .cso .pbp", "PlayStation Portable .iso .cso .pbp"),
            ([.gameCube, .wii], "GameCube et Wii .iso .rvz .gcm .wbfs .wia .ciso .gcz",
             "GameCube and Wii .iso .rvz .gcm .wbfs .wia .ciso .gcz"),
            ([.n3ds], "Nintendo 3DS .3ds .cci .cxi .3dsx (jeux décryptés)",
             "Nintendo 3DS .3ds .cci .cxi .3dsx (decrypted games)"),
        ]
        let bios: [([GameSystem], String, String)] = [
            ([.psx], "PlayStation : scph5501.bin (ou scph1001.bin…)", "PlayStation: scph5501.bin (or scph1001.bin…)"),
            ([.nds], "Nintendo DS : bios7.bin, bios9.bin, firmware.bin", "Nintendo DS: bios7.bin, bios9.bin, firmware.bin"),
            ([.gba], "Game Boy Advance : gba_bios.bin", "Game Boy Advance: gba_bios.bin"),
            ([.ps2], "PlayStation 2 (obligatoire) : le BIOS de ta console, fichier .bin de 4 Mo\n    (« SCPH-70004… », n'importe quel nom), ou Réglages › BIOS PS2 › Importer un BIOS PS2",
             "PlayStation 2 (required): your console's BIOS, a 4 MB .bin file\n    (“SCPH-70004…”, any name), or Settings › PS2 BIOS › Import a PS2 BIOS"),
        ]
        let gameLines = games.filter { installed($0.0) }.map { "  " + (english ? $0.2 : $0.1) }.joined(separator: "\n")
        let biosLines = bios.filter { installed($0.0) }.map { "  " + (english ? $0.2 : $0.1) }.joined(separator: "\n")
        if english {
            return """
            PlayTendo — what goes where

            Jeux (games)
              Put your games here (you can make subfolders), or drag them into the PlayTendo window:
            \(gameLines)
              .zip, .7z and .rar archives are accepted with the app's “+” button or by dragging them in.

            BIOS (optional)
            \(biosLines)

            Sauvegardes (saves)
              Your games' saves. Copy this folder to keep them safe.

            Journal.txt
              The app's technical log (in French), useful if something goes wrong.
              Journal-precedent.txt: the one from the previous session.
            """
        }
        return """
        PlayTendo — où ranger quoi

        Jeux
          Mets tes jeux ici (tu peux créer des sous-dossiers), ou glisse-les dans la fenêtre de PlayTendo :
        \(gameLines)
          Les archives .zip, .7z et .rar sont acceptées avec le bouton « + » de l'app ou en les glissant.

        BIOS (facultatif)
        \(biosLines)

        Sauvegardes
          Les sauvegardes de tes jeux. Copie ce dossier pour les mettre à l'abri.

        Journal.txt
          Le journal technique de l'app, utile en cas de problème.
          Journal-precedent.txt : celui de la session d'avant.
        """
    }
#endif

#if PLAYTENDO_VITA
    private static let readmeVitaGamesEnglish = """
      PlayStation Vita: the game folder extracted from your Vita (“PCSA00011”…, with its
        license sce_sys/package/work.bin for a retail game) or a .vpk.
        Installed into PlayTendo on first launch, then removed from this folder: keep your
        original elsewhere (leave room for a copy during installation).

    """
    private static let readmeVitaBIOSEnglish = """
      PlayStation Vita (required): PSVUPDAT.PUP, the console's official update,
        and if possible its PSP2UPDAT.PUP fonts

    """
    private static let readmeVitaGames = """
      PlayStation Vita : le dossier du jeu extrait de ta Vita (« PCSA00011 »…, avec sa
        licence sce_sys/package/work.bin pour un jeu du commerce) ou un .vpk.
        Installé dans PlayTendo au premier lancement, puis retiré de ce dossier : garde ton
        original ailleurs (prévois la place d'une copie le temps de l'installation).

    """
    private static let readmeVitaBIOS = """
      PlayStation Vita (obligatoire) : PSVUPDAT.PUP, la mise à jour officielle de la console,
        et si possible ses polices PSP2UPDAT.PUP

    """
#else
    private static let readmeVitaGames = ""
    private static let readmeVitaBIOS = ""
    private static let readmeVitaGamesEnglish = ""
    private static let readmeVitaBIOSEnglish = ""
#endif
}
