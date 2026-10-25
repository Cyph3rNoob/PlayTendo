import Foundation

/// Image de la DS (essai du 2026-10-11) : en x2 à x4, rendu OpenGL de melonDS adapté à l'OpenGL ES de l'iPhone
/// (ds/PTGLESCompat), la 3D dessinée plus finement ; en x1, rendu logiciel (2026-10-25). Réglé dans le menu pause et
/// gardé pour tous les jeux DS ; les décors et personnages en 2D gardent leurs pixels d'origine. Le moteur applique le
/// changement dès la reprise (rechargé, partie gardée, quand on passe de l'un à l'autre rendu).
enum DSSettings {
    /// Définition de rendu, en multiple de l'écran de la DS (256×192, pour chacun des deux écrans).
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(256 * rawValue)×\(192 * rawValue)" }

        /// x1 : rendu logiciel de melonDS (le plus fidèle, sur son propre fil) ; x2 à x4 : rendu OpenGL, seul à monter
        /// en définition (2026-10-25 : Pokémon Noire montrait des textures étirées en OpenGL, en x1 comme ailleurs).
        var isSoftware: Bool { self == .x1 }
        /// Ligne sous RÉSOLUTION dans le menu pause.
        var detail: String { isSoftware ? size + " · " + tr("rendu fidèle") : size }
    }

    static let resolutionKey = "resolutionDS"

    /// x1 par défaut (2026-10-25) : le rendu logiciel est le plus fidèle ; l'OpenGL (x2 à x4) étire certaines textures
    /// sur Apple (arbres et hautes herbes de Pokémon Noire).
    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    /// Jeu en ligne (2026-10-24) : la Connexion Wi-Fi Nintendo, fermée en 2014, est remplacée par des serveurs de fans
    /// (échanges et combats Pokémon, Mario Kart DS…). melonDS DS émule le Wi-Fi de la DS (mode « indirect », sans
    /// réglage) et dirige le jeu vers le serveur choisi par son DNS. Pris en compte au prochain lancement d'un jeu.
    enum WiFiServer: String, CaseIterable, Identifiable {
        case kaeru, wiimmfi, altwfc, off

        var id: String { rawValue }

        var label: String {
            switch self {
            case .kaeru: "Kaeru WFC"
            case .wiimmfi: "Wiimmfi"
            case .altwfc: "AltWFC"
            case .off: tr("Désactivé")
            }
        }

        /// Adresse du serveur, donnée au moteur (valeurs de melonds_firmware_wfc_dns).
        var dns: String {
            switch self {
            case .kaeru, .off: "178.62.43.212"
            case .wiimmfi: "95.217.77.181"
            case .altwfc: "172.104.88.237"
            }
        }
    }

    static let wifiServerKey = "serveurWifiDS"

    static var wifiServer: WiFiServer {
        WiFiServer(rawValue: UserDefaults.standard.string(forKey: wifiServerKey) ?? "") ?? .kaeru
    }

    /// Réglages correspondants du moteur melonDS DS (OpenGL ES sur iPhone, OpenGL « core » sur Mac).
    static var coreOptions: [String: String] {
        [
            "melonds_render_mode": resolution.isSoftware ? "software" : "opengl",
            "melonds_threaded_renderer": "enabled",
            "melonds_opengl_resolution": "\(resolution.rawValue)",
            "melonds_network_mode": wifiServer == .off ? "disabled" : "indirect",
            "melonds_firmware_wfc_dns": wifiServer.dns,
        ]
    }
}
