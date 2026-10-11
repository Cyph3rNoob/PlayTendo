import Foundation

/// Réglages d'image de la PS1, communs à tous les jeux : choisis dans le menu pause, appliqués à la reprise.
enum PS1Settings {
    /// « Résolution améliorée » de PCSX-ReARMed : la 3D est dessinée en deux fois plus fin (les décors et textes en
    /// 2D ne changent pas). Calculée par le processeur ; x1 par défaut.
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var detail: String { self == .x1 ? tr("origine") : tr("3D plus fine") }
    }

    /// Lissage des bords en escalier (filtre FXAA de PlayTendo, à l'affichage : le moteur n'en a pas).
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? tr("Non") : tr("Oui") }
    }

    static let resolutionKey = "resolutionPS1"
    static let smoothingKey = "lissagePS1"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    /// Réglages correspondants du moteur (le lissage, lui, est fait par l'écran de jeu).
    static var coreOptions: [String: String] {
        ["pcsx_rearmed_neon_enhancement_enable": resolution == .x2 ? "enabled" : "disabled"]
    }
}
