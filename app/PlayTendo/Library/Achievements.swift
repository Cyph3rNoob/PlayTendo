import Foundation
import Security

/// RetroAchievements côté interface (Réglages › RetroAchievements) : compte du joueur, mode Hardcore et notifications
/// pendant la partie. Le joueur se connecte avec son propre compte retroachievements.org ; l'app ne garde que le jeton
/// de connexion, dans le Trousseau (jamais le mot de passe). Le suivi des succès est fait par PTAchievements (rcheevos).
@MainActor
final class Achievements: ObservableObject {
    static let shared = Achievements()

    /// Nom affiché du joueur connecté.
    @Published private(set) var userName: String?
    @Published private(set) var score = 0
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    /// Hardcore : succès qui comptent davantage, sans chargement de sauvegarde rapide, retour arrière ni triche.
    @Published var hardcore: Bool {
        didSet {
            UserDefaults.standard.set(hardcore, forKey: Self.hardcoreKey)
            PTAchievements.shared.hardcore = hardcore
        }
    }
    /// Notifications montrées par-dessus le jeu (succès débloqué, classement…), quelques secondes chacune.
    @Published private(set) var banners: [Banner] = []

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let badge: URL?
        let points: Int?
    }

    var isLoggedIn: Bool { userName != nil }

    private static let userKey = "retroAchievementsCompte"
    private static let hardcoreKey = "retroAchievementsHardcore"
    private static let keychainService = "PlayTendo RetroAchievements"

    private init() {
        hardcore = UserDefaults.standard.bool(forKey: Self.hardcoreKey)
        PTAchievements.shared.hardcore = hardcore
        PTAchievements.shared.eventHandler = { [weak self] event, achievement, message in
            MainActor.assumeIsolated { self?.handle(event, achievement: achievement, message: message) }
        }
        // Reconnexion au lancement avec le jeton gardé.
        if let user = UserDefaults.standard.string(forKey: Self.userKey), let token = Self.readToken(user: user) {
            reconnect(user: user, token: token)
        }
    }

    private func reconnect(user: String, token: String) {
        busy = true
        PTAchievements.shared.login(withUser: user, token: token) { [weak self] name, score, _, error, rejected in
            MainActor.assumeIsolated {
                self?.finishLogin(user: user, name: name, score: score, token: nil, error: error, rejected: rejected)
            }
        }
    }

    /// Au lancement d'un jeu : reconnexion si elle avait échoué faute de réseau (jeton toujours gardé).
    func reconnectIfNeeded() {
        guard !isLoggedIn, !busy, let user = UserDefaults.standard.string(forKey: Self.userKey),
              let token = Self.readToken(user: user) else { return }
        reconnect(user: user, token: token)
    }

    func login(user: String, password: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        PTAchievements.shared.login(withUser: user, password: password) { [weak self] name, score, token, error, rejected in
            MainActor.assumeIsolated {
                self?.finishLogin(user: user, name: name, score: score, token: token, error: error, rejected: rejected)
            }
        }
    }

    private func finishLogin(user: String, name: String?, score: Int, token: String?, error: String?, rejected: Bool) {
        busy = false
        guard let name else {
            guard rejected else {
                self.error = tr("RetroAchievements injoignable : vérifie ta connexion à Internet.")
                return
            }
            self.error = error.map { tr("Connexion refusée : \($0)") } ?? tr("Connexion refusée")
            // Jeton périmé ou retiré : il faudra se reconnecter avec le mot de passe.
            if UserDefaults.standard.string(forKey: Self.userKey) == user {
                Self.deleteToken(user: user)
                UserDefaults.standard.removeObject(forKey: Self.userKey)
            }
            return
        }
        if let token {
            Self.saveToken(token, user: user)
            UserDefaults.standard.set(user, forKey: Self.userKey)
        }
        userName = name
        self.score = score
        self.error = nil
    }

    func logout() {
        PTAchievements.shared.logout()
        if let user = UserDefaults.standard.string(forKey: Self.userKey) { Self.deleteToken(user: user) }
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        userName = nil
        score = 0
    }

    // MARK: Notifications

    private func handle(_ event: PTAchievementEvent, achievement: PTAchievement?, message: String?) {
        switch event {
        case .unlocked:
            guard let achievement else { return }
            show(Banner(title: achievement.title, detail: achievement.detail,
                        badge: achievement.badgeURL.flatMap(URL.init(string:)), points: Int(achievement.points)))
        case .mastered:
            show(Banner(title: tr("Jeu maîtrisé !"), detail: tr("Tous les succès de ce jeu sont débloqués."), badge: nil, points: nil))
        case .leaderboardStarted:
            show(Banner(title: tr("Classement lancé"), detail: message ?? "", badge: nil, points: nil))
        case .leaderboardFailed:
            show(Banner(title: tr("Classement raté"), detail: message ?? "", badge: nil, points: nil))
        case .leaderboardSubmitted:
            show(Banner(title: tr("Score envoyé"), detail: message ?? "", badge: nil, points: nil))
        case .disconnected:
            show(Banner(title: tr("RetroAchievements injoignable"), detail: tr("Tes succès seront envoyés dès le retour du réseau."),
                        badge: nil, points: nil))
        case .reconnected:
            show(Banner(title: tr("RetroAchievements de retour"), detail: tr("Les succès en attente sont envoyés."), badge: nil, points: nil))
        case .serverError:
            show(Banner(title: tr("Erreur de RetroAchievements"), detail: message ?? "", badge: nil, points: nil))
        case .resetRequested:
            break
        @unknown default:
            break
        }
    }

    private func show(_ banner: Banner) {
        banners.append(banner)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.banners.removeAll { $0.id == banner.id }
        }
    }

    // MARK: Trousseau

    private static func query(user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: user]
    }

    private static func saveToken(_ token: String, user: String) {
        SecItemDelete(query(user: user) as CFDictionary)
        var item = query(user: user)
        item[kSecValueData as String] = Data(token.utf8)
        // Jamais recopié vers un autre appareil par une sauvegarde ou une restauration.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func readToken(user: String) -> String? {
        var item = query(user: user)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        // Jeton rangé avant le 2026-10-24 : passé aussi en « cet appareil seulement ».
        SecItemUpdate(query(user: user) as CFDictionary,
                      [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken(user: String) {
        SecItemDelete(query(user: user) as CFDictionary)
    }
}
