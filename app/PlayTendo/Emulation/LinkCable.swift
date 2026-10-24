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
/// L'invité commence par envoyer son nom (« PTLINK1 nom » et un retour à la ligne), que l'hôte affiche ; ensuite, seuls
/// les octets du câble passent.
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
        case connected(String)
        case failed(String)
    }

    struct Peer: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var state: State = .off
    @Published private(set) var peers: [Peer] = []

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
    private static let header = "PTLINK1 "

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

    /// Un invité arrive : branché sur Gambatte (serveur) de cet appareil. Un seul à la fois.
    private func acceptRemote(_ connection: NWConnection) {
        guard remote == nil else {
            connection.cancel()
            return
        }
        remote = connection
        remoteName = Self.name(of: connection.endpoint)
        publish(.connecting(remoteName))
        watch(connection, side: tr("l'autre appareil"))
        connection.start(queue: queue)
        let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.serverPort)!,
                                 using: Self.localParameters())
        self.local = local
        watch(local, side: tr("le jeu"))
        local.start(queue: queue)
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
                    return Peer(name: name, endpoint: result.endpoint)
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
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.clientPort)!)
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
        guard local == nil else {
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
                guard retries <= 60 else {
                    fail(tr("Câble débranché (\(side) : \(error.localizedDescription))"))
                    return
                }
                queue.asyncAfter(deadline: .now() + 1) { [weak connection] in connection?.restart() }
            case .failed(let error):
                fail(tr("Câble débranché (\(side) : \(error.localizedDescription))"))
            case .cancelled:
                if piping { fail(tr("Câble débranché par \(side)")) }
            default:
                break
            }
        }
    }

    /// Connexion prête : l'invité envoie son nom à l'hôte, l'hôte le lit ; le reste attend que tout soit prêt.
    private func ready(_ connection: NWConnection) {
        guard connection === remote, !handshaken else {
            startPiping()
            return
        }
        if isHost {
            readHeader(from: connection, buffer: Data())
        } else {
            connection.send(content: Data((Self.header + myName + "\n").utf8), completion: .contentProcessed { _ in })
            handshaken = true
            startPiping()
        }
    }

    private func readHeader(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, finished, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                if line.hasPrefix(Self.header) { remoteName = String(line.dropFirst(Self.header.count)) }
                pendingToLocal = Data(buffer[buffer.index(after: end)...])
                handshaken = true
                publish(.connecting(remoteName))
                startPiping()
            } else if finished || error != nil || buffer.count > 512 {
                fail(tr("L'autre appareil n'est pas PlayTendo"))
            } else {
                readHeader(from: connection, buffer: buffer)
            }
        }
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
        }
    }

    /// Sur `queue`.
    private func closeAll() {
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
        if case let .service(name, _, _, _) = endpoint { return name }
        return tr("un autre appareil")
    }
}
