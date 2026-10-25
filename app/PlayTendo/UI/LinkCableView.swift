import SwiftUI

/// Menu pause › Câble link (Game Boy, Game Boy Color) : héberger, rejoindre un appareil proche, débrancher.
struct LinkCableView: View {
    @ObservedObject var link: LinkCable
    let gameTitle: String
    @Environment(\.dismiss) private var dismiss

    private var deviceName: String { LinkCable.displayName(game: gameTitle) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    content
                } footer: {
                    Text(tr("Les deux appareils doivent être proches (même pièce), avec le Wi-Fi et le Bluetooth activés : pas besoin d'être sur le même réseau. Chacun lance son jeu (par exemple Pokémon Rouge et Pokémon Bleu), puis l'un héberge et l'autre rejoint. Dans Pokémon, parle ensuite à l'hôtesse du Club Câble, au Centre Pokémon."))
                }
            }
            .navigationTitle(tr("Câble link"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
#endif
    }

    @ViewBuilder private var content: some View {
        switch link.state {
        case .off, .failed:
            if case .failed(let message) = link.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button { link.host(name: deviceName) } label: {
                Label(tr("Héberger"), systemImage: "antenna.radiowaves.left.and.right")
            }
            Button { link.search(name: deviceName) } label: {
                Label(tr("Rejoindre un appareil proche"), systemImage: "magnifyingglass")
            }
        case .hosting:
            HStack(spacing: 12) {
                ProgressView()
                Text(tr("En attente d'un autre appareil… Sur l'autre : menu pause › Câble link › Rejoindre."))
            }
            Button(tr("Annuler"), role: .destructive) { link.stop() }
        case .searching:
            if link.peers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(tr("Recherche des appareils proches…"))
                }
            }
            ForEach(link.peers) { peer in
                Button { link.join(peer) } label: {
                    Label(peer.name, systemImage: "gamecontroller")
                }
            }
            Button(tr("Annuler"), role: .destructive) { link.stop() }
        case .request(let name):
            Label(tr("\(name) veut se brancher"), systemImage: "cable.connector")
                .font(.headline)
            Text(tr("N'accepte que l'appareil de quelqu'un que tu connais, à côté de toi : il pourra échanger avec ton jeu."))
                .foregroundStyle(.secondary)
            Button { link.approve(true) } label: {
                Label(tr("Accepter"), systemImage: "checkmark.circle")
            }
            Button(role: .destructive) { link.approve(false) } label: {
                Label(tr("Refuser"), systemImage: "xmark.circle")
            }
        case .waitingApproval(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text(tr("En attente de l'accord de \(name)…"))
            }
            Button(tr("Annuler"), role: .destructive) { link.stop() }
        case .linking(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text(tr("Accepté : branchement à \(name)… La partie reprend : le câble se branche quand les deux jeux tournent."))
            }
            Button(tr("Annuler"), role: .destructive) { link.stop() }
        case .connecting(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text(tr("Connexion à \(name)…"))
            }
            Button(tr("Annuler"), role: .destructive) { link.stop() }
        case .connected(let name):
            Label(tr("Branché à \(name)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(tr("Le câble reste branché tant que les deux jeux sont ouverts. Pendant un échange, ne mets pas un jeu en pause : l'autre attendrait, figé."))
                .foregroundStyle(.secondary)
            Button(tr("Débrancher"), role: .destructive) { link.stop() }
        }
    }
}
