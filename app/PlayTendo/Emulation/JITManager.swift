import SwiftUI
#if os(iOS)
import Darwin
#endif

/// Mode turbo (JIT) : la PSP, la PS2, la GameCube/Wii et la 3DS traduisent leur code en instructions de l'iPhone au
/// lieu de l'interpréter.
///
/// Sur Mac, l'app rend elle-même sa mémoire exécutable : la réserve est prête dès l'ouverture, sans rien à installer.
///
/// Sur iOS, StikDebug reste la voie compatible avec iOS antérieur à 26 et LiveContainer. Sur iOS 26 installé
/// normalement, StikJIT peut faire le même travail depuis l'extension d'aide intégrée. Le script « universal.js »
/// et le protocole `brk #0xf00d` restent communs aux voies debugger; l'app prépare ensuite sa réserve (PTJIT.m).
/// Une fois par ouverture : elle reste valable jusqu'à la fermeture de l'app.
@MainActor
final class JITManager: ObservableObject {
    enum Method: String, CaseIterable, Identifiable {
        case stikDebug
        case stikJIT
        case off

        var id: String { rawValue }
        var label: String {
            switch self {
            case .stikDebug: tr("Via StikDebug")
            case .stikJIT: tr("Intégré avec StikJIT")
            case .off: tr("Désactivé")
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
    /// Dolphin 256 Mo, plus des petits blocs (décodeurs de sommets), dans la même part. 3DS : 32 Mo par cœur émulé
    /// (jusqu'à 4), dans la même part aussi : une seule de ces consoles tourne à la fois. La réserve n'occupe que des
    /// adresses tant que les moteurs n'y écrivent pas.
    nonisolated static let poolSize = (32 + 320) << 20
    private static let methodKey = "methodeJIT"
    private static let lastSuccessKey = "dernierTurboReussi"
    private static let forceScriptKey = "stikJITForceScript"
    private static let scriptName = "universal.js"
#if os(iOS)
    private static let pairingFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StikJIT", isDirectory: true)
        .appendingPathComponent("pairingFile.plist")
#endif

    @Published var method: Method {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey) }
    }
    @Published private(set) var status: Status
    /// Dernière activation réussie : preuve que le fichier de jumelage et le mode développeur sont en place.
    @Published private(set) var lastSuccess: Date?
    @Published var forceStikJITScript: Bool {
        didSet { UserDefaults.standard.set(forceStikJITScript, forKey: Self.forceScriptKey) }
    }
    @Published private(set) var hasPairingFile = false
    @Published private(set) var txmPresence: Bool?
    @Published private(set) var preparationStatus: String?

    private var running: Task<Void, Error>?

    init() {
        if let savedMethod = UserDefaults.standard.string(forKey: Self.methodKey),
           let method = Method(rawValue: savedMethod) {
            self.method = method
        } else {
            method = Self.canUseStikJIT ? .stikJIT : .stikDebug
        }
        status = PTJITIsActive() ? .active : .inactive
        lastSuccess = UserDefaults.standard.object(forKey: Self.lastSuccessKey) as? Date
        forceStikJITScript = UserDefaults.standard.bool(forKey: Self.forceScriptKey)
        refreshPairingFileStatus()
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

    /// StikJIT utilise un processus d'extension public disponible à partir d'iOS 26.
    static var canUseStikJIT: Bool {
#if os(iOS)
        if #available(iOS 26.0, *) { return !isRunningInLiveContainer }
#endif
        return false
    }

#if os(iOS)
    static var isRunningInLiveContainer: Bool { getenv("LC_HOME_PATH") != nil }
#else
    static var isRunningInLiveContainer: Bool { false }
#endif

    /// Consoles dont le moteur sait se servir du JIT.
    nonisolated static func benefits(_ system: GameSystem) -> Bool { [.psp, .ps2, .gameCube, .wii, .n3ds].contains(system) || system.isVita }

    /// Consoles qui ne peuvent pas tourner sans JIT : aucune, sauf la PS Vita dans une app compilée avec elle (Vita3K
    /// n'a pas d'interpréteur).
    nonisolated static func requires(_ system: GameSystem) -> Bool { system.isVita }

    var isStikDebugInstalled: Bool {
#if os(iOS)
        UIApplication.shared.canOpenURL(URL(string: "stikdebug://")!)
#else
        false
#endif
    }

    func refreshPairingFileStatus() {
#if os(iOS)
        hasPairingFile = FileManager.default.isReadableFile(atPath: Self.pairingFileURL.path)
#else
        hasPairingFile = false
#endif
    }

    /// Copie le plist de jumelage dans Application Support/StikJIT, hors du dossier visible dans Fichiers.
    func importPairingFile(from sourceURL: URL) throws {
#if os(iOS)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: sourceURL)
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              plist is [String: Any] else {
            throw Failure(message: tr("Ce fichier de jumelage n'est pas un plist lisible."))
        }
        let directory = Self.pairingFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try data.write(to: Self.pairingFileURL, options: [.atomic, .completeFileProtection])
        hasPairingFile = true
        lastSuccess = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSuccessKey)
        preparationStatus = nil
#else
        throw Failure(message: tr("Le fichier de jumelage StikJIT ne peut être importé que sur iPhone ou iPad."))
#endif
    }

    /// Lit TXM dans le processus d'aide. L'opération n'a pas besoin du fichier de jumelage.
    func refreshTXMPresence() async {
#if os(iOS)
        guard Self.canUseStikJIT else { txmPresence = nil; return }
        do {
            let response = try await requestStikJIT(action: "txm")
            txmPresence = response.txm
        } catch {
            txmPresence = nil
            PTLogLine("StikJIT : détection TXM impossible — \(error.localizedDescription)")
        }
#endif
    }

    /// Prépare le Developer Disk Image à la demande, sans activer le JIT. Au lancement d'un jeu, l'app
    /// appelle cette même préparation automatiquement avant enableJIT.
    func prepareStikJIT() async throws {
#if os(iOS)
        let pairingData = try stikJITPairingData()
        preparationStatus = tr("Préparation du Developer Disk Image…")
        status = .activating(tr("Connexion à l'iPhone…"))
        do {
            let response = try await requestStikJIT(action: "prepare", pairingData: pairingData)
            txmPresence = response.txm
            guard response.ok else {
                throw Failure(message: response.error ?? tr("Préparation StikJIT impossible."))
            }
            preparationStatus = tr("iPhone prêt pour le JIT.")
            status = .inactive
        } catch {
            preparationStatus = error.localizedDescription
            status = .failed(error.localizedDescription)
            throw error
        }
#else
        throw Failure(message: tr("StikJIT intégré est disponible uniquement sur iPhone ou iPad."))
#endif
    }

    func resetStikJITCache() async throws {
#if os(iOS)
        guard Self.canUseStikJIT else {
            throw Failure(message: tr("StikJIT intégré demande iOS 26 et ne fonctionne pas dans LiveContainer."))
        }
        let response = try await requestStikJIT(action: "reset")
        guard response.ok else {
            throw Failure(message: response.error ?? tr("Réinitialisation du Developer Disk Image impossible."))
        }
        preparationStatus = tr("Cache du Developer Disk Image effacé.")
#else
        throw Failure(message: tr("Le cache StikJIT ne peut être réinitialisé que sur iPhone ou iPad."))
#endif
    }

    /// Le mode turbo s'active tout seul, sans app extérieure (Mac, simulateur).
    nonisolated static var isAutomatic: Bool {
#if os(macOS) || targetEnvironment(simulator)
        true
#else
        false
#endif
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
#if targetEnvironment(simulator) || os(macOS)
        // Pas de StikDebug dans le simulateur ni sur Mac : même réserve, sans débogueur.
        status = .activating(tr("Préparation de la mémoire…"))
        try await Self.preparePool(simulated: true)
#else
        guard method != .off else {
            throw Failure(message: tr("Le mode turbo est désactivé dans les réglages."))
        }
        guard PTJITHasGetTaskAllow() else {
            throw Failure(message: tr("Cette installation de PlayTendo ne peut pas recevoir de débogueur. Réinstalle-la avec AltStore."))
        }
        if method == .stikJIT {
            try await runStikJIT()
            return
        }
        if !PTJITIsTraced() {
            guard let url = stikDebugURL() else {
                throw Failure(message: tr("Adresse StikDebug impossible à créer."))
            }
            status = .activating(tr("Ouverture de StikDebug…"))
            PTLogLine("JIT : demande envoyée à StikDebug")
            guard await UIApplication.shared.open(url) else {
                throw Failure(message: tr("StikDebug n'est pas installé (ou pas activé dans AltStore)."))
            }
            status = .activating(tr("En attente de StikDebug…"))
            // StikDebug s'attache puis rouvre PlayTendo tout seul.
            let deadline = Date().addingTimeInterval(120)
            while !PTJITIsTraced() {
                if Date() > deadline {
                    throw Failure(message: tr("StikDebug n'a pas répondu. Vérifie que LocalDevVPN est connecté et que ton fichier de jumelage est importé dans StikDebug, puis réessaie."))
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        status = .activating(tr("Préparation de la mémoire…"))
        try await Self.preparePool(simulated: false)
#endif
    }

    private func runStikJIT() async throws {
#if os(iOS)
        let pairingData = try stikJITPairingData()
        status = .activating(tr("Préparation du Developer Disk Image…"))

        // Cette préparation interne permet de connaître TXM avant de choisir la voie du script.
        // enableJIT refait ensuite son propre contrôle de préparation avant d'attacher le débogueur.
        let preparation = try await requestStikJIT(action: "prepare", pairingData: pairingData)
        txmPresence = preparation.txm
        guard preparation.ok else {
            throw Failure(message: preparation.error ?? tr("Préparation StikJIT impossible."))
        }
        guard txmPresence != nil || forceStikJITScript else {
            throw Failure(message: tr("iOS n'a pas permis de détecter TXM/SPTM. Active « Forcer le script JIT » pour continuer."))
        }

        status = .activating(tr("Activation de StikJIT…"))
        let forceScript = forceStikJITScript
        let txmPresent = txmPresence == true || forceScript
        let enableTask = Task {
            try await self.requestStikJIT(action: "enable",
                                          targetPID: Int32(getpid()),
                                          pairingData: pairingData,
                                          forceScript: forceScript)
        }

        if !txmPresent {
            let response = try await enableTask.value
            try Self.requireSuccess(response, fallback: tr("StikJIT n'a pas activé le JIT."))
            status = .activating(tr("Préparation de la mémoire…"))
            try await Self.preparePool(simulated: false, unrestricted: true)
            return
        }

        do {
            // Sur TXM, le script reste attaché jusqu'à ce que l'app prépare sa réserve via brk #0xf00d.
            // Les deux tâches doivent donc progresser ensemble : StikJIT dans l'extension, allocation ici.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let deadline = Date().addingTimeInterval(120)
                    while !PTJITIsTraced() {
                        guard Date() < deadline else {
                            throw Failure(message: tr("StikJIT n'a pas attaché son débogueur à PlayTendo."))
                        }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    await MainActor.run { self.status = .activating(tr("Préparation de la mémoire…")) }
                    try await Self.preparePool(simulated: false)
                }
                group.addTask {
                    let response = try await enableTask.value
                    try Self.requireSuccess(response, fallback: tr("StikJIT n'a pas activé le JIT."))
                }
                try await group.waitForAll()
            }
        } catch {
            enableTask.cancel()
            throw error
        }
#else
        throw Failure(message: tr("StikJIT intégré est disponible uniquement sur iPhone ou iPad."))
#endif
    }

#if os(iOS)
    private func stikJITPairingData() throws -> Data {
        guard Self.canUseStikJIT else {
            throw Failure(message: tr("StikJIT intégré demande iOS 26 et ne fonctionne pas dans LiveContainer."))
        }
        guard PTJITHasGetTaskAllow() else {
            throw Failure(message: tr("Cette installation de PlayTendo ne peut pas recevoir de débogueur. Réinstalle-la avec AltStore."))
        }
        guard FileManager.default.isReadableFile(atPath: Self.pairingFileURL.path) else {
            throw Failure(message: tr("Importe ton fichier de jumelage dans les réglages StikJIT avant de continuer."))
        }
        let data = try Data(contentsOf: Self.pairingFileURL)
        guard !data.isEmpty else { throw Failure(message: tr("Le fichier de jumelage StikJIT est vide.")) }
        return data
    }

    private func requestStikJIT(action: String,
                                targetPID: Int32 = 0,
                                pairingData: Data? = nil,
                                forceScript: Bool = false) async throws -> PTJITHelperResponse {
        guard #available(iOS 26.0, *) else {
            throw Failure(message: tr("StikJIT intégré demande iOS 26 ou plus."))
        }
        guard !Self.isRunningInLiveContainer else {
            throw Failure(message: tr("StikJIT intégré ne fonctionne pas dans LiveContainer. Choisis StikDebug."))
        }
        return try await PTStikJITExtensionHost.perform(action: action,
                                                        targetPID: targetPID,
                                                        pairingData: pairingData,
                                                        forceScript: forceScript)
    }

    nonisolated private static func requireSuccess(_ response: PTJITHelperResponse, fallback: String) throws {
        guard response.ok else {
            throw Failure(message: response.error ?? fallback)
        }
    }
#endif

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

    nonisolated private static func preparePool(simulated: Bool, unrestricted: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            var buffer = [CChar](repeating: 0, count: 256)
            let ready: Bool
            if simulated {
                ready = PTJITPrepareSimulatedPool(poolSize, &buffer, buffer.count)
            } else if unrestricted {
                ready = PTJITPrepareUnrestrictedPool(poolSize, &buffer, buffer.count)
            } else {
                ready = PTJITPreparePool(poolSize, &buffer, buffer.count)
            }
            if !ready {
                // Raison écrite par PTJIT.m (en français) : traduite si c'est une des phrases connues.
                throw Failure(message: tr("Préparation de la mémoire impossible : \(trMessage(String(cString: buffer)))"))
            }
        }.value
    }
}
