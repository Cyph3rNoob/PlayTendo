import SwiftUI

/// Réglages de l'app : pour l'instant le mode turbo (JIT) de la PSP.
struct SettingsView: View {
    @EnvironmentObject private var jit: JITManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stikDebugInstalled = false
    @State private var vpnConnected = false
    @AppStorage(PSPSettings.resolutionKey) private var resolution = PSPSettings.Resolution.x2.rawValue
    @AppStorage(PSPSettings.smoothingKey) private var smoothing = PSPSettings.Smoothing.off.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Résolution", selection: $resolution) {
                        ForEach(PSPSettings.Resolution.allCases) { option in
                            Text("\(option.label) · \(option.size)").tag(option.rawValue)
                        }
                    }
                    Picker("Lissage des textures", selection: $smoothing) {
                        ForEach(PSPSettings.Smoothing.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                } header: {
                    Text("Image PSP")
                } footer: {
                    Text("Résolution : plus elle est haute, plus l'image est nette, mais plus la puce graphique travaille (x4 ≈ 1080p). Lissage : rend les décors moins pixelisés, mais demande du calcul au processeur et peut ralentir les jeux lourds. Les deux se changent aussi en pleine partie, depuis le menu pause.")
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

                    Picker("Activation", selection: $jit.method) {
                        ForEach(JITManager.Method.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    if jit.method != .off && !jit.isActive {
                        Button {
                            Task { try? await jit.activate() }
                        } label: {
                            Label("Activer maintenant", systemImage: "bolt.fill")
                        }
                        .disabled(isActivating)
                    }
                } header: {
                    Text("Mode turbo (JIT)")
                } footer: {
                    Text("Accélère la PSP : son code est traduit pour l'iPhone au lieu d'être interprété. Il s'active une fois par ouverture de PlayTendo, tout seul au lancement d'un jeu PSP, et reste actif jusqu'à la fermeture de l'app.")
                }

                if jit.method == .stikDebug {
                    Section {
                        Requirement(text: "StikDebug installé", done: stikDebugInstalled)
                        Requirement(text: "Ton fichier de jumelage importé dans StikDebug", done: jit.hasWorked ? true : nil)
                        // Le VPN ne sert qu'au moment de l'activation : turbo actif, son absence n'est pas une erreur.
                        Requirement(text: "LocalDevVPN connecté (en Wi-Fi de préférence)",
                                    done: vpnConnected ? true : (jit.isActive ? nil : false))
                        Requirement(text: "Mode développeur activé (Réglages › Confidentialité et sécurité)", done: jit.hasWorked ? true : nil)
                    } header: {
                        Text("Ce qu'il faut")
                    } footer: {
                        Text("Au lancement d'un jeu PSP, StikDebug s'ouvre quelques secondes puis te ramène dans PlayTendo. LocalDevVPN ne sert qu'à ce moment-là. PlayTendo ne peut pas lire le fichier de jumelage ni le mode développeur : leurs cases se cochent dès qu'un turbo a réussi. Avec un compte Apple gratuit (3 apps), StikDebug doit être activé dans AltStore : désactive une autre app le temps de jouer si besoin.")
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .onAppear(perform: refreshChecks)
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
    }

    private var isActivating: Bool {
        if case .activating = jit.status { true } else { false }
    }

    private var statusTitle: String {
        if jit.isActive { return "Actif" }
        switch jit.status {
        case .activating: return "Activation…"
        case .failed: return "Échec de l'activation"
        default: return jit.method == .off ? "Désactivé" : "Inactif"
        }
    }

    private var statusDetail: String? {
        if jit.isActive { return "Les jeux PSP lancés maintenant en profitent." }
        switch jit.status {
        case .activating(let step): return step
        case .failed(let message): return message
        default: return jit.method == .off ? "Les jeux PSP utilisent l'interpréteur." : "S'activera au prochain jeu PSP."
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

/// Panneau affiché pendant l'activation du JIT, avant le lancement d'un jeu PSP.
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
                Text("MODE TURBO")
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
                    Text("JOUER SANS JIT")
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
        return "Activation…"
    }
}
