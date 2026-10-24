import Foundation

/// Réglages d'image de la 3DS, communs à tous les jeux (sauf le curseur 3D, retenu par jeu) : choisis dans le menu
/// pause, en pleine partie (le moteur les applique dès la reprise).
enum N3DSSettings {
    /// Définition de rendu, en multiple de l'écran du haut (400×240). Au-delà de x3, l'écran de l'iPhone
    /// n'afficherait rien de plus ; sur Mac (fenêtre en plein écran), x4. x1 par défaut.
    enum Resolution: Int, CaseIterable, Identifiable {
#if os(macOS)
        case x1 = 1, x2, x3, x4
#else
        case x1 = 1, x2, x3
#endif

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(400 * rawValue)×\(240 * rawValue)" }
    }

    /// Lissage des textures (filtre ScaleForce d'Azahar, par le processeur graphique) : décors moins pixelisés.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? tr("Non") : tr("Oui") }
    }

    /// Curseur 3D de la console (relief). Certains jeux et homebrews changent d'image quand il est levé (Emerald3DS :
    /// son monde en voxels). L'image reste en 2D (pas d'affichage en relief : `citra_render_3d` reste coupé), mais un
    /// jeu qui voit le curseur levé dessine une image par œil : plus lent, donc baissé par défaut.
    enum Slider: Int, CaseIterable, Identifiable {
        case down = 0, up = 100

        var id: Int { rawValue }
        var label: String { self == .down ? tr("Baissé") : tr("Levé") }
    }

    static let resolutionKey = "resolution3DS"
    static let smoothingKey = "lissage3DS"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    static var smoothing: Smoothing {
        Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off
    }

    private static func sliderKey(for game: Game) -> String { "curseur3D.\(game.key)" }

    static func slider(for game: Game) -> Slider {
        Slider(rawValue: UserDefaults.standard.integer(forKey: sliderKey(for: game))) ?? .down
    }

    static func setSlider(_ slider: Slider, for game: Game) {
        UserDefaults.standard.set(slider.rawValue, forKey: sliderKey(for: game))
    }

    /// Position du curseur 3D pour le moteur (relue par la console à chaque lecture des boutons).
    static func sliderOptions(for game: Game) -> [String: String] {
        ["citra_factor_3d": "\(slider(for: game).rawValue)"]
    }

    /// Les homebrews (bibliothèque libctru) n'allument le son que s'ils trouvent le programme de la puce son de la
    /// console, `sdmc:/3ds/dspfirm.cdc`, normalement copié depuis une vraie 3DS. Le moteur imite cette puce sans s'en
    /// servir (émulation « HLE », il n'en lit pas le contenu) : un fichier factice, sans rien de Nintendo, suffit.
    /// Créé seulement s'il n'y en a pas (un vrai fichier posé par le joueur reste).
    static func prepareSoundFirmware() {
        let file = Paths.n3dsSDCard.appendingPathComponent("3ds/dspfirm.cdc")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let text = "PlayTendo : fichier factice. Le moteur 3DS imite la puce son sans ce programme ;\n"
            + "il existe seulement parce que les homebrews le cherchent avant d'allumer le son.\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            PTLogLine("3DS : fichier son factice créé sur la carte SD (3ds/dspfirm.cdc), pour le son des homebrews")
        } catch {
            PTLogLine("3DS : fichier son factice impossible à créer : \(error.localizedDescription)")
        }
    }

    /// Réglages correspondants du moteur Azahar.
    static var coreOptions: [String: String] {
        [
            "citra_resolution_factor": "\(resolution.rawValue)",
            "citra_texture_filter": smoothing == .on ? "ScaleForce" : "none",
        ]
    }
}
