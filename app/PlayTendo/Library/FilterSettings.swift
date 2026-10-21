import Foundation

/// Consoles 2D (NES, Super Nintendo, Game Boy, Game Boy Color, Game Boy Advance) : filtre de l'image, fait par l'écran
/// de jeu de PlayTendo (Shaders.metal, gameFragment), gardé pour chaque console. Menu pause › IMAGE › FILTRE.
enum FilterSettings {
    enum Filter: Int, CaseIterable, Identifiable {
        /// Pixels nets (« sharp bilinear »), comme avant ce réglage.
        case sharp = 0
        /// Image lissée (agrandissement bilinéaire).
        case smooth
        /// Lignes d'un écran cathodique (consoles de salon) ou grille d'un écran LCD (consoles portables).
        case screen

        var id: Int { rawValue }
    }

    static let systems: Set<GameSystem> = [.nes, .snes, .gb, .gbc, .gba]

    /// Consoles portables : écran LCD ; de salon : écran cathodique (CRT).
    private static func isHandheld(_ system: GameSystem) -> Bool { [.gb, .gbc, .gba].contains(system) }

    static func key(for system: GameSystem) -> String { "filtre.\(system.rawValue)" }

    static func label(_ filter: Filter, system: GameSystem) -> String {
        switch filter {
        case .sharp: tr("Net")
        case .smooth: tr("Lissé")
        case .screen: isHandheld(system) ? "LCD" : "CRT"
        }
    }

    /// Mode du shader : 0 net, 1 lissé, 2 lignes CRT, 3 grille LCD.
    static func shaderMode(_ filter: Filter, system: GameSystem) -> Int {
        switch filter {
        case .sharp: 0
        case .smooth: 1
        case .screen: isHandheld(system) ? 3 : 2
        }
    }
}
