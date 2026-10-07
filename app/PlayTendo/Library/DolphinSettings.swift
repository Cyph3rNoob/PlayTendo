import Foundation

/// Image de la GameCube et de la Wii, réglée dans le menu pause et gardée pour tous leurs jeux ; manette des
/// jeux Wii, retenue par jeu.
enum DolphinSettings {
    /// Définition de rendu, en multiple de celle de la console (640×528). Au-delà de x3, l'image dépasse
    /// l'écran de l'iPhone : inutile. x1 par défaut (le processeur graphique reste libre pour la vitesse).
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var detail: String {
            switch self {
            case .x1: "origine"
            case .x2: "≈ 720p"
            case .x3: "≈ 1080p"
            }
        }
    }

    /// Lissage des bords en escalier (filtre FXAA de Dolphin, peu coûteux), comme pour la PS2.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? "Non" : "Oui" }
    }

    /// Manette d'un jeu Wii : la Wiimote avec son Nunchuk (la plupart des jeux) ou la manette GameCube (Smash
    /// Bros. Brawl, Mario Kart Wii…).
    enum WiiController: String {
        case wiimote, gameCube

        var label: String { self == .wiimote ? "Wiimote" : "GameCube" }
        var other: WiiController { self == .wiimote ? .gameCube : .wiimote }
    }

    static let resolutionKey = "resolutionGCWii"
    static let smoothingKey = "lissageGCWii"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    static var smoothing: Smoothing {
        Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off
    }

    private static func controllerKey(for game: Game) -> String { "manetteWii.\(game.key)" }

    /// Wiimote par défaut.
    static func controller(for game: Game) -> WiiController {
        WiiController(rawValue: UserDefaults.standard.string(forKey: controllerKey(for: game)) ?? "") ?? .wiimote
    }

    static func setController(_ controller: WiiController, for game: Game) {
        UserDefaults.standard.set(controller.rawValue, forKey: controllerKey(for: game))
    }
}
