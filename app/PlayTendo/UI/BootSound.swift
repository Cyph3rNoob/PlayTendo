import AVFoundation

/// Son du démarrage, « Puissance iPhone » (synthèse maison : scripts/make_boot_sounds.py, version 4b : le grave passe
/// par ses harmoniques, audibles sur le haut-parleur de l'iPhone), calé sur l'animation de BootView
/// lancée en même temps : battement sourd quand l'écran s'ouvre (0,41 s), impact à l'étincelle (0,81 s). Muet en
/// mode silencieux (comme le son des jeux) ; réglage « Son au démarrage ».
enum BootSound {
    static let enabledKey = "sonDemarrage"
    private static var player: AVAudioPlayer?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Chargé dès le lancement de l'app, pour partir sans délai avec l'animation.
    static func prepare() {
        guard isEnabled, let url = Bundle.main.url(forResource: "BootSound", withExtension: "m4a") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    static func play() {
        player?.play()
    }
}
