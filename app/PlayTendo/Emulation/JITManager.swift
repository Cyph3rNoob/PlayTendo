import SwiftUI
import UIKit

/// Mode turbo (JIT) : la PSP, la PS2 et la GameCube/Wii traduisent leur code en instructions de l'iPhone au lieu
/// de l'interpréter.
///
/// Sur iOS 26 avec TXM (A15 et suivantes), seul un débogueur peut rendre de la mémoire exécutable.
/// PlayTendo demande à StikDebug (adresse `stikdebug://enable-jit`) de s'attacher avec son script
/// « universal.js », puis prépare sa réserve de mémoire et le laisse repartir (PTJIT.m). Une fois par
/// ouverture de l'app : la réserve reste valable jusqu'à sa fermeture.
@MainActor
final class JITManager: ObservableObject {
    enum Method: String, CaseIterable, Identifiable {
        case stikDebug
        case off

        var id: String { rawValue }
        var label: String {
            switch self {
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

    /// PSP : le JIT de PPSSPP prend 16 Mo et son décodeur de sommets 256 Ko (32 Mo laissent de la marge).
    /// PS2 : les recompilateurs d'ARMSX2 prennent 305 Mo d'un seul bloc (320 Mo prévus). GameCube/Wii : celui de
    /// Dolphin 256 Mo, plus des petits blocs (décodeurs de sommets), dans la même part : une seule de ces deux
    /// consoles tourne à la fois. La réserve n'occupe que des adresses tant que les moteurs n'y écrivent pas.
    nonisolated static let poolSize = (32 + 320) << 20
    private static let methodKey = "methodeJIT"
    private static let lastSuccessKey = "dernierTurboReussi"
    private static let scriptName = "universal.js"

    @Published var method: Method {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey) }
    }
    @Published private(set) var status: Status
    /// Dernière activation réussie : preuve que le fichier de jumelage et le mode développeur sont en place.
    @Published private(set) var lastSuccess: Date?

    private var running: Task<Void, Error>?

    init() {
        method = Method(rawValue: UserDefaults.standard.string(forKey: Self.methodKey) ?? "") ?? .stikDebug
        status = PTJITIsActive() ? .active : .inactive
        lastSuccess = UserDefaults.standard.object(forKey: Self.lastSuccessKey) as? Date
    }

    /// Le turbo a déjà marché sur cet iPhone (maintenant ou lors d'une ouverture précédente).
    var hasWorked: Bool { isActive || lastSuccess != nil }

    /// LocalDevVPN est connecté : une interface tunnel (utun) a une adresse dans 10.7.0.0/16, celle du tunnel de
    /// LocalDevVPN. Lecture locale des interfaces, sans rien envoyer.
    nonisolated static var isLocalDevVPNConnected: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  String(cString: entry.ifa_name).hasPrefix("utun") else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == (10 << 8 | 7) { return true }
        }
        return false
    }

    var isActive: Bool { PTJITIsActive() }

    /// Consoles dont le moteur sait se servir du JIT.
    nonisolated static func benefits(_ system: GameSystem) -> Bool { [.psp, .ps2, .gameCube, .wii, .n3ds].contains(system) || system.isVita }

    /// Consoles qui ne peuvent pas tourner sans JIT : la PS Vita (Vita3K n'a pas d'interpréteur).
    nonisolated static func requires(_ system: GameSystem) -> Bool { system.isVita }

    var isStikDebugInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "stikdebug://")!)
    }

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
            lastSuccess = Date()
            UserDefaults.standard.set(lastSuccess, forKey: Self.lastSuccessKey)
        } catch {
            running = nil
            status = .failed(error.localizedDescription)
            PTLogLine("JIT non activé : \(error.localizedDescription)")
            throw error
        }
    }

    private func run() async throws {
#if targetEnvironment(simulator)
        // Pas de StikDebug dans le simulateur : même réserve, sans débogueur, pour tester les moteurs.
        status = .activating("Préparation de la mémoire…")
        try await Self.preparePool(simulated: true)
#else
        guard method != .off else {
            throw Failure(message: "Le mode turbo est désactivé dans les réglages.")
        }
        guard PTJITHasGetTaskAllow() else {
            throw Failure(message: "Cette installation de PlayTendo ne peut pas recevoir de débogueur. Réinstalle-la avec AltStore.")
        }
        if !PTJITIsTraced() {
            guard let url = stikDebugURL() else {
                throw Failure(message: "Adresse StikDebug impossible à créer.")
            }
            status = .activating("Ouverture de StikDebug…")
            PTLogLine("JIT : demande envoyée à StikDebug")
            guard await UIApplication.shared.open(url) else {
                throw Failure(message: "StikDebug n'est pas installé (ou pas activé dans AltStore).")
            }
            status = .activating("En attente de StikDebug…")
            // StikDebug s'attache puis rouvre PlayTendo tout seul.
            let deadline = Date().addingTimeInterval(120)
            while !PTJITIsTraced() {
                if Date() > deadline {
                    throw Failure(message: "StikDebug n'a pas répondu. Vérifie que LocalDevVPN est connecté et que ton fichier de jumelage est importé dans StikDebug, puis réessaie.")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        status = .activating("Préparation de la mémoire…")
        try await Self.preparePool(simulated: false)
#endif
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
}
