import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Câble link Game Boy / Game Boy Color entre deux appareils proches (2026-10-24 : échanges et combats Pokémon).
/// Le moteur Gambatte de chaque appareil croit parler à l'autre par son « câble link » réseau (TCP) ; PlayTendo relie
/// les deux par une connexion directe : Bonjour sur le Wi-Fi pair-à-pair et le Bluetooth d'Apple (sans réseau commun),
/// ou par le même Wi-Fi s'il y en a un.
///
/// - Hôte : Gambatte en serveur (port 56400 de l'appareil) ; PlayTendo s'y branche en local et s'annonce aux appareils
///   voisins (`_playtendo-link._tcp`).
/// - Invité : PlayTendo écoute en local (127.0.0.1:56401), Gambatte s'y branche en client, et PlayTendo relaie vers
///   l'hôte choisi.
/// L'invité commence par envoyer son nom (« PTLINK1 nom » et un retour à la ligne) ; l'hôte le montre au joueur, qui
/// accepte ou refuse (audit de sécurité du 2026-10-24 : avant, n'importe quel appareil proche se branchait seul). Accepté,
/// l'hôte répond « PTLINK1 OK » et se branche alors seulement sur son Gambatte ; refusé, il coupe. Ensuite, seuls les
/// octets du câble passent. Gambatte n'écoute que l'appareil lui-même (127.0.0.1, scripts/patch_gambatte.py).
/// Gambatte n'ouvre son câble que pendant que le jeu tourne : une fois l'accord donné (état `.linking`), le menu pause
/// se ferme et la partie reprend d'elle-même des deux côtés (PauseMenu), sinon rien ne se branchait (2026-10-25).
///
/// Les réponses du réseau arrivent sur la file `queue` ; l'état publié change sur le thread principal.
final class LinkCable: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case off
        /// Hôte : en attente d'un autre appareil.
        case hosting
        /// Invité : liste des appareils proches.
        case searching
        case connecting(String)
        /// Hôte : un appareil demande à se brancher ; le joueur accepte ou refuse.
        case request(String)
        /// Invité : en attente de l'accord de l'hôte.
        case waitingApproval(String)
        /// Accord donné : les deux jeux doivent tourner pour que le câble se branche.
        case linking(String)
        case connected(String)
        case failed(String)
    }

    struct Peer: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { endpoint.debugDescription }
    }

    @Published private(set) var state: State = .off
    @Published private(set) var peers: [Peer] = []
    /// Câble branché, mais le jeu ne produit plus d'image depuis plus d'une seconde : Gambatte attend, bloqué, la
    /// réponse de l'autre Game Boy (qui ne répond que quand son jeu se sert aussi du câble). Bandeau dans l'écran de jeu.
    @Published private(set) var waitingForOther = false

    static let service = "_playtendo-link._tcp"
    static let serverPort: UInt16 = 56400
    static let clientPort: UInt16 = 56401

    private weak var session: EmulatorSession?
    private let queue = DispatchQueue(label: "PlayTendo câble link")
    // Utilisés sur `queue` seulement.
    private var listener: NWListener?
    private var localListener: NWListener?
    private var browser: NWBrowser?
    private var remote: NWConnection?
    private var local: NWConnection?
    private var remoteName = ""
    private var piping = false
    private var isHost = false
    private var myName = ""
    /// Nom de l'invité échangé (lu par l'hôte, envoyé par l'invité) ; octets du câble arrivés avec lui.
    private var handshaken = false
    private var pendingToLocal = Data()
    private var retries = 0
    // Surveillance du jeu pendant que le câble est branché (fil principal).
    private var watchTimer: Timer?
    private var watchedFrames: UInt64 = 0
    private var framesChangedAt = Date()
    /// Change à chaque appareil reçu : un délai d'un appareil parti ne touche pas le suivant.
    private var attempt = 0
    private static let header = "PTLINK1 "
    private static let approval = "PTLINK1 OK"

    init(session: EmulatorSession) {
        self.session = session
    }

    var isActive: Bool {
        if case .off = state { return false }
        return true
    }

    /// Nom montré aux appareils voisins : l'appareil et le jeu (deux iPhone s'appellent tous « iPhone »).
    static func displayName(game: String) -> String {
#if os(iOS)
        let device = UIDevice.current.name
#else
        let device = Host.current().localizedName ?? "Mac"
#endif
        return "\(device) · \(game)"
    }

    // MARK: Hôte

    func host(name: String) {
        session?.setLinkMode(.server(Self.serverPort))
        queue.async { [self] in
            closeAll()
            isHost = true
            myName = name
            do {
                let listener = try NWListener(using: Self.peerParameters())
                listener.service = NWListener.Service(name: name, type: Self.service)
                listener.newConnectionHandler = { [weak self] connection in self?.acceptRemote(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.fail(tr("Annonce impossible : \(error.localizedDescription)")) }
                }
                listener.start(queue: queue)
                self.listener = listener
                PTLogLine("Câble link : en attente d'un autre appareil (« \(name) »)")
                publish(.hosting)
            } catch {
                fail(tr("Annonce impossible : \(error.localizedDescription)"))
            }
        }
    }

    /// Un invité arrive. Un seul à la fois ; il a 10 secondes pour donner son nom, puis le joueur décide (`approve`).
    private func acceptRemote(_ connection: NWConnection) {
        guard remote == nil, isHost else {
            connection.cancel()
            return
        }
        remote = connection
        remoteName = Self.name(of: connection.endpoint)
        attempt += 1
        let current = attempt
        watch(connection, side: tr("l'autre appareil"))
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, attempt == current, remote === connection, !handshaken else { return }
            dropGuest(log: "pas de nom reçu en 10 s")
        }
    }

    /// Réponse du joueur (hôte) à une demande de branchement.
    func approve(_ accepted: Bool) {
        queue.async { [self] in
            guard isHost, handshaken, !piping, local == nil, let remote else { return }
            guard accepted else {
                dropGuest(log: "refusé par le joueur")
                return
            }
            PTLogLine("Câble link : « \(remoteName) » accepté")
            remote.send(content: Data((Self.approval + "\n").utf8), completion: .contentProcessed { _ in })
            announceLinking()
            let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.serverPort)!,
                                     using: Self.localParameters())
            self.local = local
            watch(local, side: tr("le jeu"))
            local.start(queue: queue)
        }
    }

    /// Hôte : l'invité refusé, muet ou parti est coupé ; l'annonce continue pour un autre. Sur `queue`.
    private func dropGuest(log: String) {
        PTLogLine("Câble link : appareil « \(remoteName) » écarté (\(log))")
        attempt += 1
        piping = false
        handshaken = false
        pendingToLocal = Data()
        retries = 0
        for connection in [remote, local] { connection?.stateUpdateHandler = nil; connection?.cancel() }
        remote = nil
        local = nil
        remoteName = ""
        publish(.hosting)
    }

    // MARK: Invité

    func search(name: String) {
        queue.async { [self] in
            closeAll()
            isHost = false
            myName = name
            let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: Self.peerParameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let list = results.compactMap { result -> Peer? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Peer(name: Self.cleanName(name), endpoint: result.endpoint)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                DispatchQueue.main.async { self?.peers = list }
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.fail(tr("Recherche impossible : \(error.localizedDescription)")) }
            }
            browser.start(queue: queue)
            self.browser = browser
            publish(.searching)
        }
        session?.setLinkMode(.off)
    }

    func join(_ peer: Peer) {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            remoteName = peer.name
            publish(.connecting(peer.name))
            // Écoute locale d'abord : Gambatte (client) s'y branche dès qu'il passe en mode câble.
            do {
                let parameters = Self.localParameters()
                parameters.requiredInterfaceType = .loopback
                parameters.allowLocalEndpointReuse = true
                // Liée à 127.0.0.1 : rien d'autre que l'appareil ne peut s'y brancher.
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                             port: NWEndpoint.Port(rawValue: Self.clientPort)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.acceptLocal(connection) }
                listener.start(queue: queue)
                localListener = listener
            } catch {
                fail(tr("Câble impossible à préparer : \(error.localizedDescription)"))
                return
            }
            let remote = NWConnection(to: peer.endpoint, using: Self.peerParameters())
            self.remote = remote
            watch(remote, side: tr("l'autre appareil"))
            remote.start(queue: queue)
            DispatchQueue.main.async { self.session?.setLinkMode(.client(Self.clientPort)) }
        }
    }

    private func acceptLocal(_ connection: NWConnection) {
        guard local == nil, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        local = connection
        watch(connection, side: tr("le jeu"))
        connection.start(queue: queue)
    }

    // MARK: Relais

    /// Suit une connexion : une fois les deux prêtes, les octets passent de l'une à l'autre ; une coupure débranche.
    private func watch(_ connection: NWConnection, side: String) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready(connection)
            case .waiting(let error):
                // Le jeu n'écoute pas encore (partie en pause : le moteur prend le câble à la reprise) ou l'autre
                // appareil n'est pas encore joignable : nouvel essai chaque seconde, une minute au plus.
                retries += 1
                if isHost, connection === remote, !piping {
                    dropGuest(log: error.localizedDescription)
                    return
                }
                guard retries <= 60 else {
                    fail(tr("Câble débranché (\(side) : \(error.localizedDescription))"))
                    return
                }
                queue.asyncAfter(deadline: .now() + 1) { [weak connection] in connection?.restart() }
            case .failed(let error):
                if isHost, connection === remote, !piping {
                    dropGuest(log: error.localizedDescription)
                    return
                }
                fail(tr("Câble débranché (\(side) : \(error.localizedDescription))"))
            case .cancelled:
                if piping { fail(tr("Câble débranché par \(side)")) }
            default:
                break
            }
        }
    }

    /// Connexion prête : l'invité envoie son nom puis attend l'accord de l'hôte ; l'hôte lit le nom et le montre au
    /// joueur. Le reste attend que tout soit prêt.
    private func ready(_ connection: NWConnection) {
        guard connection === remote, !handshaken else {
            startPiping()
            return
        }
        if isHost {
            readLine(from: connection, buffer: Data()) { [self] line, rest in
                guard let line, line.hasPrefix(Self.header) else {
                    dropGuest(log: "pas PlayTendo")
                    return
                }
                remoteName = Self.cleanName(String(line.dropFirst(Self.header.count)))
                pendingToLocal = rest
                handshaken = true
                PTLogLine("Câble link : « \(remoteName) » demande à se brancher")
                publish(.request(remoteName))
                let name = remoteName
                DispatchQueue.main.async {
                    self.session?.showMessage(tr("\(name) veut se brancher : menu pause › Câble link"))
                }
                // Sans réponse du joueur en une minute : refusé.
                let current = attempt
                queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, attempt == current, remote === connection, local == nil else { return }
                    dropGuest(log: "pas de réponse du joueur")
                }
            }
        } else {
            connection.send(content: Data((Self.header + myName + "\n").utf8), completion: .contentProcessed { _ in })
            publish(.waitingApproval(remoteName))
            readLine(from: connection, buffer: Data()) { [self] line, rest in
                guard line == Self.approval else {
                    fail(tr("\(remoteName) a refusé le câble link"))
                    return
                }
                pendingToLocal = rest
                handshaken = true
                PTLogLine("Câble link : accepté par « \(remoteName) »")
                announceLinking()
                startPiping()
            }
            let current = attempt
            queue.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard let self, attempt == current, remote === connection, !handshaken else { return }
                fail(tr("\(remoteName) n'a pas accepté le câble link"))
            }
        }
    }

    /// Lit une ligne (512 octets au plus) ; `nil` si la connexion se coupe ou si la ligne est trop longue. Le reste
    /// (octets du câble déjà arrivés derrière) est rendu avec elle. Sur `queue`.
    private func readLine(from connection: NWConnection, buffer: Data, then done: @escaping @Sendable (String?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, finished, error in
            guard let self, remote === connection else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.firstIndex(of: 0x0A), end - buffer.startIndex <= 512 {
                let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                done(line, Data(buffer[buffer.index(after: end)...]))
            } else if finished || error != nil || buffer.count > 512 {
                done(nil, Data())
            } else {
                readLine(from: connection, buffer: buffer, then: done)
            }
        }
    }

    /// Accord donné : l'écran le dit, et la partie va reprendre (PauseMenu) pour que Gambatte ouvre son câble. Sur `queue`.
    private func announceLinking() {
        publish(.linking(remoteName))
        let name = remoteName
        DispatchQueue.main.async { self.session?.showMessage(tr("Câble link : branchement à \(name)…")) }
    }

    private func startPiping() {
        guard !piping, handshaken, let remote, let local, remote.state == .ready, local.state == .ready else { return }
        piping = true
        if !pendingToLocal.isEmpty {
            local.send(content: pendingToLocal, completion: .contentProcessed { _ in })
            pendingToLocal = Data()
        }
        Self.pipe(from: remote, to: local)
        Self.pipe(from: local, to: remote)
        PTLogLine("Câble link : branché à « \(remoteName) »")
        publish(.connected(remoteName))
        let name = remoteName
        DispatchQueue.main.async { self.session?.showMessage(tr("Câble link branché à \(name)")) }
    }

    private static func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, finished, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if finished || error != nil {
                source.cancel()
                return
            }
            pipe(from: source, to: destination)
        }
    }

    // MARK: Arrêt

    func stop() {
        session?.setLinkMode(.off)
        queue.async { [self] in
            closeAll()
            publish(.off)
        }
    }

    private func fail(_ message: String) {
        PTLogLine("Câble link : \(message)")
        closeAll()
        DispatchQueue.main.async {
            self.session?.setLinkMode(.off)
            self.state = .failed(message)
            self.peers = []
            self.updateWatch()
        }
    }

    /// Fil principal : surveillance du jeu tant que le câble est branché.
    private func updateWatch() {
        guard case .connected = state else {
            watchTimer?.invalidate()
            watchTimer = nil
            waitingForOther = false
            return
        }
        guard watchTimer == nil else { return }
        watchedFrames = session?.frameCount ?? 0
        framesChangedAt = Date()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            let frames = session.frameCount
            if frames != self.watchedFrames || session.state != .running {
                self.watchedFrames = frames
                self.framesChangedAt = Date()
            }
            let waiting = Date().timeIntervalSince(self.framesChangedAt) > 1
            if waiting != self.waitingForOther { self.waitingForOther = waiting }
        }
    }

    /// Sur `queue`.
    private func closeAll() {
        attempt += 1
        piping = false
        handshaken = false
        pendingToLocal = Data()
        retries = 0
        for connection in [remote, local] { connection?.stateUpdateHandler = nil; connection?.cancel() }
        remote = nil
        local = nil
        listener?.cancel()
        listener = nil
        localListener?.cancel()
        localListener = nil
        browser?.cancel()
        browser = nil
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async {
            self.state = state
            if state != .searching { self.peers = [] }
            self.updateWatch()
        }
    }

    // MARK: Réglages réseau

    /// Entre appareils : Wi-Fi pair-à-pair et Bluetooth d'Apple permis, envoi immédiat des petits paquets.
    private static func peerParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Sur l'appareil, entre PlayTendo et Gambatte.
    private static func localParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func name(of endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return cleanName(name) }
        return tr("un autre appareil")
    }

    /// Nom venu d'un autre appareil, avant de l'afficher : sans caractères de contrôle ni d'inversion du sens du texte
    /// (qui maquilleraient le nom), 48 caractères au plus.
    static func cleanName(_ name: String) -> String {
        let hidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{2060}\u{FEFF}"))
            .union(CharacterSet(charactersIn: "\u{202A}"..."\u{202E}"))
            .union(CharacterSet(charactersIn: "\u{2066}"..."\u{2069}"))
        let scalars = name.unicodeScalars.filter { !hidden.contains($0) }
        var clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 48 { clean = String(clean.prefix(47)) + "…" }
        return clean.isEmpty ? tr("un autre appareil") : clean
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }
}
