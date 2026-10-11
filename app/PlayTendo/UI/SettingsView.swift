import SwiftUI
import UniformTypeIdentifiers

/// Réglages de l'app : la langue, le mode turbo (JIT) de la PSP, de la PS2, de la GameCube/Wii et de la 3DS, le BIOS PS2
/// et le son du démarrage.
struct SettingsView: View {
    @EnvironmentObject private var jit: JITManager
    @AppStorage(BootSound.enabledKey) private var bootSound = true
    @AppStorage(AppLanguage.key) private var language = AppLanguage.automatic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stikDebugInstalled = false
    @State private var vpnConnected = false
    @State private var biosList: [PS2BIOS.Info] = []
    @State private var biosInUse: PS2BIOS.Info?
    @State private var importingBIOS = false
    @State private var biosBusy = false
    @State private var biosAlert: (title: String, text: String)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(tr("Langue"), selection: $language) {
                        ForEach(AppLanguage.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } footer: {
                    Text(tr("Automatique : la langue de l'iPhone (le français s'il passe avant l'anglais, sinon l'anglais)."))
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(statusColor)
                            .neonGlow(statusColor, radius: 6)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle).font(.headline)
                            if let detail = statusDetail {
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Picker(tr("Activation"), selection: $jit.method) {
                        ForEach(JITManager.Method.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    if jit.method != .off && !jit.isActive {
                        Button {
                            Task { try? await jit.activate() }
                        } label: {
                            Label(tr("Activer maintenant"), systemImage: "bolt.fill")
                        }
                        .disabled(isActivating)
                    }
                } header: {
                    Text(tr("Mode turbo (JIT)"))
                } footer: {
                    Text(tr("Accélère la PSP, la PS2, la GameCube, la Wii et la 3DS : leur code est traduit pour l'iPhone au lieu d'être interprété (sans lui, la PS2, la GameCube, la Wii et la 3DS sont injouables). Il s'active une fois par ouverture de PlayTendo, tout seul au lancement d'un de ces jeux, et reste actif jusqu'à la fermeture de l'app."))
                }

                if jit.method == .stikDebug {
                    Section {
                        Requirement(text: tr("StikDebug installé"), done: stikDebugInstalled)
                        Requirement(text: tr("Ton fichier de jumelage importé dans StikDebug"), done: jit.hasWorked ? true : nil)
                        // Le VPN ne sert qu'au moment de l'activation : turbo actif, son absence n'est pas une erreur.
                        Requirement(text: tr("LocalDevVPN connecté (en Wi-Fi de préférence)"),
                                    done: vpnConnected ? true : (jit.isActive ? nil : false))
                        Requirement(text: tr("Mode développeur activé (Réglages › Confidentialité et sécurité)"), done: jit.hasWorked ? true : nil)
                    } header: {
                        Text(tr("Ce qu'il faut"))
                    } footer: {
                        Text(tr("Au lancement d'un jeu PSP, PS2, GameCube, Wii ou 3DS, StikDebug s'ouvre quelques secondes puis te ramène dans PlayTendo. LocalDevVPN ne sert qu'à ce moment-là. PlayTendo ne peut pas lire le fichier de jumelage ni le mode développeur : leurs cases se cochent dès qu'un turbo a réussi. Avec un compte Apple gratuit (3 apps), StikDebug doit être activé dans AltStore : désactive une autre app le temps de jouer si besoin."))
                    }
                }

                Section {
                    if biosList.isEmpty {
                        Requirement(text: tr("Aucun BIOS PS2"), done: false)
                    }
                    ForEach(biosList) { bios in
                        let used = bios.fileName == biosInUse?.fileName
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bios.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text([bios.summary ?? tr("Version inconnue"), used ? tr("utilisé par la PS2") : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(used ? Neon.cyan : Neon.dim)
                            }
                        } icon: {
                            Image(systemName: used ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(used ? Color.green : Neon.dim)
                        }
                    }
                    Button {
                        importingBIOS = true
                    } label: {
                        if biosBusy {
                            Label(tr("Import…"), systemImage: "hourglass")
                        } else {
                            Label(tr("Importer un BIOS PS2…"), systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(biosBusy)
                } header: {
                    Text(tr("BIOS PS2"))
                } footer: {
                    Text(tr("Obligatoire pour la PS2. Choisis le BIOS de ta console (fichier de 4 Mo, souvent « SCPH-… », n'importe quel nom ; dans un .zip, .7z ou .rar aussi) : PlayTendo vérifie que c'en est bien un et le range dans le dossier BIOS. PlayTendo n'en fournit aucun."))
                }

                Section {
                    Toggle(tr("Son au démarrage"), isOn: $bootSound)
                } header: {
                    Text(tr("Démarrage"))
                } footer: {
                    Text(tr("Joué avec l'animation d'ouverture de PlayTendo. Muet en mode silencieux, comme le son des jeux."))
                }
            }
            .navigationTitle(tr("Réglages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .onAppear(perform: refreshChecks)
            .onChange(of: language) { _, _ in
                // Tout s'affiche aussitôt dans la nouvelle langue ; le Lisez-moi suit, et les BIOS sont relus.
                Paths.writeReadme()
                refreshBIOS()
            }
            .fileImporter(isPresented: $importingBIOS, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { importBIOS(url) }
            }
            .alert(biosAlert?.title ?? "", isPresented: Binding(get: { biosAlert != nil },
                                                                set: { if !$0 { biosAlert = nil } })) {
                Button("OK") {}
            } message: {
                Text(biosAlert?.text ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshChecks() }
            }
            .task {
                // LocalDevVPN peut se connecter pendant que les réglages sont ouverts.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    vpnConnected = JITManager.isLocalDevVPNConnected
                }
            }
        }
        .tint(.playTendoAccent)
        .preferredColorScheme(.dark)
    }

    private func refreshChecks() {
        stikDebugInstalled = jit.isStikDebugInstalled
        vpnConnected = JITManager.isLocalDevVPNConnected
        refreshBIOS()
    }

    private func refreshBIOS() {
        biosList = PS2BIOS.installed()
        biosInUse = PS2BIOS.inUse(among: biosList)
    }

    /// Vérifie et range le fichier choisi (hors du fil principal : une archive peut prendre un moment), puis le dit.
    private func importBIOS(_ url: URL) {
        biosBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { PS2BIOS.importFile(url) }.value
            biosBusy = false
            refreshBIOS()
            switch result {
            case .added(let info):
                var text = tr("« \(info.fileName) » (\(info.summary ?? tr("version inconnue"))) est rangé dans le dossier BIOS.")
                if let used = biosInUse, used.fileName != info.fileName {
                    text += tr(" La PS2 garde pour l'instant « \(used.fileName) ».")
                }
                biosAlert = (tr("BIOS PS2 ajouté"), text)
            case .alreadyThere(let name):
                biosAlert = (tr("Déjà là"), tr("Ce BIOS est déjà dans le dossier BIOS (« \(name) »). Rien n'a été ajouté."))
            case .notBIOS:
                biosAlert = (tr("Ce n'est pas un BIOS PS2"),
                             tr("Un BIOS PS2 est un fichier de 4 Mo (8 Mo pour certains modèles) copié depuis ta console. Rien n'a été ajouté."))
            case .failed(let message):
                biosAlert = (tr("Import impossible"), message)
            }
        }
    }

    private var isActivating: Bool {
        if case .activating = jit.status { true } else { false }
    }

    private var statusTitle: String {
        if jit.isActive { return tr("Actif") }
        switch jit.status {
        case .activating: return tr("Activation…")
        case .failed: return tr("Échec de l'activation")
        default: return jit.method == .off ? tr("Désactivé") : tr("Inactif")
        }
    }

    private var statusDetail: String? {
        if jit.isActive { return tr("Les jeux PSP, PS2, GameCube, Wii et 3DS lancés maintenant en profitent.") }
        switch jit.status {
        case .activating(let step): return step
        case .failed(let message): return message
        default: return jit.method == .off ? tr("Les jeux PSP, PS2, GameCube, Wii et 3DS utilisent l'interpréteur.") : tr("S'activera au prochain de ces jeux.")
        }
    }

    private var statusIcon: String {
        if jit.isActive { return "bolt.fill" }
        if case .failed = jit.status { return "exclamationmark.triangle.fill" }
        return "bolt.slash"
    }

    private var statusColor: Color {
        if jit.isActive { return Neon.cyan }
        if case .failed = jit.status { return Neon.magenta }
        return Neon.dim
    }
}

/// Ligne de la liste « Ce qu'il faut » (coche verte, croix, ou simple puce quand l'app ne peut pas vérifier).
private struct Requirement: View {
    let text: String
    let done: Bool?

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            switch done {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil: Image(systemName: "circle").foregroundStyle(Neon.dim)
            }
        }
    }
}

/// Jeu en attente du JIT, et la raison de l'échec.
struct JITFailure {
    let game: Game
    let message: String
}

/// Panneau affiché pendant l'activation du JIT, avant le lancement d'un jeu PSP, PS2, GameCube, Wii ou 3DS.
struct JITActivationView: View {
    let status: JITManager.Status
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Neon.cyan)
                    .neonGlow(Neon.cyan, radius: 12)
                Text(tr("MODE TURBO"))
                    .font(.orbitron(18, weight: 900))
                    .tracking(3)
                    .foregroundStyle(Neon.text)
                HStack(spacing: 10) {
                    ProgressView().tint(Neon.cyan)
                    Text(stepText)
                        .font(Neon.mono(13, weight: .semibold))
                        .foregroundStyle(Neon.dim)
                }
                Button(action: onSkip) {
                    Text(tr("JOUER SANS JIT"))
                        .font(.orbitron(12, weight: 800))
                        .tracking(1.5)
                        .foregroundStyle(Neon.magenta)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(Chamfer(cut: 8).stroke(Neon.magenta.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(28)
            .background(Chamfer(cut: 18).fill(Neon.panel))
            .overlay(Chamfer(cut: 18).stroke(LinearGradient(colors: [Neon.cyan, Neon.magenta],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                                             lineWidth: 1.5))
            .neonGlow(Neon.cyan, radius: 10)
            .padding(32)
        }
    }

    private var stepText: String {
        if case .activating(let step) = status { return step }
        return tr("Activation…")
    }
}
