import Security
import SwiftUI
import UIKit
import notify

/// Mode turbo (JIT) : la PSP traduit son code en instructions de l'iPhone au lieu de l'interpréter.
///
/// Sur iOS 26 avec TXM (A15 et suivantes), seul un débogueur peut rendre de la mémoire exécutable.
/// Méthode « Intégré » : l'extension PlayTendoJIT attache ce débogueur avec StikJIT (fichier de jumelage
/// + LocalDevVPN). Méthode « Via StikDebug » : on le demande à l'app StikDebug (`stikdebug://enable-jit`).
/// Dans les deux cas le script « universal.js » répond à PlayTendo, qui prépare sa réserve de mémoire puis
/// le laisse repartir (PTJIT.m). Une fois par ouverture de l'app : la réserve reste valable jusqu'à sa fermeture.
@MainActor
final class JITManager: ObservableObject {
    enum Method: String, CaseIterable, Identifiable {
        case builtIn
        case stikDebug
        case off

        var id: String { rawValue }
        var label: String {
            switch self {
            case .builtIn: "Intégré"
            case .stikDebug: "Via StikDebug"
            case .off: "Désactivé"
            }
        }
    }

    enum Status: Equatable {
        case inactive
        case activating(String)
        case active
        case failed(String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Le JIT de PPSSPP prend 16 Mo et son décodeur de sommets 256 Ko : 32 Mo laissent de la marge.
    nonisolated static let poolSize = 32 << 20
    private static let methodKey = "methodeJIT"
    private static let scriptName = "universal.js"
    /// Étapes annoncées par l'extension (notifications Darwin « playtendo.jit.etape.<nom> »).
    private static let steps: [(name: String, text: String)] = [
        ("connexion", "Connexion à l'iPhone…"),
        ("verification", "Vérification de l'image disque…"),
        ("telechargement", "Téléchargement de l'image disque (première fois seulement)…"),
        ("montage", "Montage de l'image disque…"),
        ("debogueur", "Attache du débogueur…"),
    ]

    @Published var method: Method {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey) }
    }
    @Published private(set) var status: Status
    @Published private(set) var hasPairingFile = PairingStore.exists
    /// Protection TXM détectée par StikJIT (nil tant qu'inconnue).
    @Published private(set) var txmPresent: Bool?
    /// Résultat du dernier bouton « Vérifier » ou « Réinitialiser » des réglages.
    @Published private(set) var checkMessage: String?
    @Published private(set) var checking = false

    private var running: Task<Void, Error>?
    private var stepTokens: [Int32] = []

    init() {
        method = Method(rawValue: UserDefaults.standard.string(forKey: Self.methodKey) ?? "") ?? .builtIn
        status = PTJITIsActive() ? .active : .inactive
        importPairingFileFromDocuments()
        for step in Self.steps {
            var token: Int32 = 0
            let text = step.text
            notify_register_dispatch("playtendo.jit.etape.\(step.name)", &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .activating = self.status { self.status = .activating(text) }
                    if self.checking { self.checkMessage = text }
                }
            }
            stepTokens.append(token)
        }
    }

    var isActive: Bool { PTJITIsActive() }

    /// Consoles dont le moteur sait se servir du JIT.
    nonisolated static func benefits(_ system: GameSystem) -> Bool { system == .psp }

    var isStikDebugInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "stikdebug://")!)
    }

    // MARK: Activation

    /// Active le JIT s'il ne l'est pas déjà. Une seule activation à la fois : un second appel attend la première.
    func activate() async throws {
        if isActive {
            status = .active
            return
        }
        let task: Task<Void, Error>
        if let running {
            task = running
        } else {
            task = Task { try await self.run() }
            running = task
        }
        do {
            try await task.value
            running = nil
            status = .active
        } catch {
            running = nil
            status = .failed(error.localizedDescription)
            PTLogLine("JIT non activé : \(error.localizedDescription)")
            throw error
        }
    }

    private func run() async throws {
#if targetEnvironment(simulator)
        // Pas de débogueur possible dans le simulateur : même réserve, sans lui, pour tester les moteurs.
        status = .activating("Préparation de la mémoire…")
        try await Self.preparePool(simulated: true)
#else
        guard PTJITHasGetTaskAllow() else {
            throw Failure(message: "Cette installation de PlayTendo ne peut pas recevoir de débogueur. Réinstalle-la avec AltStore.")
        }
        var helper: HelperOutcome?
        if !PTJITIsTraced() {
            switch method {
            case .builtIn: helper = try startBuiltIn()
            case .stikDebug: try await openStikDebug()
            case .off: throw Failure(message: "Le mode turbo est désactivé dans les réglages.")
            }
            try await waitForDebugger(helper: helper)
        }
        status = .activating("Préparation de la mémoire…")
        try await Self.preparePool(simulated: false)
        // L'extension répond quand le débogueur s'est détaché : on attend sa réponse un court instant.
        if let helper {
            for _ in 0..<50 where helper.result == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if case .success(let response)? = helper.result, let txm = response["txm"] as? Bool {
                txmPresent = txm
            }
        }
#endif
    }

    /// Réponse de l'extension, remplie quand elle a fini (sur le fil principal).
    private final class HelperOutcome {
        var result: Result<[String: Any], Error>?
    }

    private func startBuiltIn() throws -> HelperOutcome {
        guard let pairing = PairingStore.load() else {
            throw Failure(message: "Importe d'abord ton fichier de jumelage (pairingFile.plist) dans Réglages › Mode turbo.")
        }
        status = .activating("Démarrage de l'aide JIT…")
        PTLogLine("JIT : activation intégrée (StikJIT)")
        let outcome = HelperOutcome()
        let request: [String: Any] = ["operation": "enable", "pid": NSNumber(value: getpid()), "pairing": pairing]
        Task {
            do {
                outcome.result = .success(try await JITHelperClient.send(request))
            } catch {
                outcome.result = .failure(error)
            }
        }
        return outcome
    }

    private func openStikDebug() async throws {
        guard let url = stikDebugURL() else {
            throw Failure(message: "Adresse StikDebug impossible à créer.")
        }
        status = .activating("Ouverture de StikDebug…")
        PTLogLine("JIT : demande envoyée à StikDebug")
        guard await UIApplication.shared.open(url) else {
            throw Failure(message: "StikDebug n'est pas installé sur cet iPhone.")
        }
        status = .activating("En attente de StikDebug…")
    }

    /// Attend que le débogueur soit attaché (P_TRACED) ; s'arrête si l'extension a fini avant (échec).
    private func waitForDebugger(helper: HelperOutcome?) async throws {
        // La première fois, l'image disque développeur se télécharge : on laisse du temps.
        let deadline = Date().addingTimeInterval(180)
        while !PTJITIsTraced() {
            if let result = helper?.result {
                switch result {
                case .failure(let error): throw error
                case .success(let response):
                    if let txm = response["txm"] as? Bool { txmPresent = txm }
                    throw Failure(message: response["message"] as? String ?? "L'aide JIT s'est arrêtée sans attacher le débogueur.")
                }
            }
            if Date() > deadline {
                throw Failure(message: method == .stikDebug
                    ? "StikDebug n'a pas répondu. Vérifie que LocalDevVPN est connecté et que ton fichier de jumelage est importé dans StikDebug."
                    : "Le débogueur ne s'est pas attaché à temps. Vérifie que LocalDevVPN est connecté, puis réessaie.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js (identifiant réel de l'installation,
    /// AltStore y ajoute celui de l'équipe).
    private func stikDebugURL() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-name", value: Self.scriptName),
        ]
        return components.url
    }

    nonisolated private static func preparePool(simulated: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            var buffer = [CChar](repeating: 0, count: 256)
            let ready = simulated
                ? PTJITPrepareSimulatedPool(poolSize, &buffer, buffer.count)
                : PTJITPreparePool(poolSize, &buffer, buffer.count)
            if !ready {
                throw Failure(message: "Préparation de la mémoire impossible : \(String(cString: buffer))")
            }
        }.value
    }

    // MARK: Réglages

    /// Vérifie que l'iPhone est joignable et prépare l'image disque développeur (bouton « Vérifier »).
    func checkDevice() async {
        guard let pairing = PairingStore.load() else {
            checkMessage = "Importe d'abord ton fichier de jumelage."
            return
        }
        await runCheck(["operation": "prepare", "pairing": pairing])
    }

    /// Efface l'image disque développeur gardée par l'extension (elle sera retéléchargée).
    func resetDiskImage() async {
        await runCheck(["operation": "resetDDI"])
    }

    private func runCheck(_ request: [String: Any]) async {
        checking = true
        checkMessage = "Démarrage de l'aide JIT…"
        do {
            let response = try await JITHelperClient.send(request)
            if let txm = response["txm"] as? Bool { txmPresent = txm }
            let ok = response["success"] as? Bool ?? false
            checkMessage = (ok ? "✓ " : "✗ ") + (response["message"] as? String ?? "Pas de réponse.")
        } catch {
            checkMessage = "✗ " + error.localizedDescription
        }
        checking = false
    }

    /// Importe un fichier de jumelage choisi dans Fichiers.
    func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try savePairing(try Data(contentsOf: url))
        PTLogLine("JIT : fichier de jumelage importé")
    }

    func deletePairingFile() {
        PairingStore.delete()
        hasPairingFile = false
        checkMessage = nil
    }

    private func savePairing(_ data: Data) throws {
        // Un fichier de jumelage est une liste de propriétés (dictionnaire) ; son contenu n'est jamais journalisé.
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw Failure(message: "Ce fichier n'est pas un fichier de jumelage.")
        }
        try PairingStore.save(data)
        hasPairingFile = true
        checkMessage = nil
    }

    /// Un fichier posé dans Fichiers › PlayTendo (pairingFile.plist, ou StikJIT/pairingFile.plist) est rangé
    /// dans le trousseau puis effacé du dossier, que tout le monde peut parcourir.
    private func importPairingFileFromDocuments() {
        for path in ["pairingFile.plist", "StikJIT/pairingFile.plist"] {
            let url = Paths.documents.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                try savePairing(data)
                try? FileManager.default.removeItem(at: url)
                PTLogLine("JIT : fichier de jumelage trouvé dans Fichiers, rangé dans le trousseau")
            } catch {
                PTLogLine("JIT : \(path) ignoré (\(error.localizedDescription))")
            }
        }
    }
}

/// Fichier de jumelage gardé dans le trousseau de l'iPhone (chiffré, lisible seulement par PlayTendo, sur cet
/// appareil, déverrouillé) : c'est une clé de l'iPhone, il ne va donc pas dans Documents.
enum PairingStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.playtendo.jit",
        kSecAttrAccount as String: "pairingFile",
    ]

    static var exists: Bool { load() != nil }

    static func load() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func save(_ data: Data) throws {
        delete()
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw JITManager.Failure(message: "Impossible de ranger le fichier dans le trousseau (erreur \(status)).")
        }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
