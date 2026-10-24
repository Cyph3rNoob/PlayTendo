import SwiftUI

/// Réglages › RetroAchievements : connexion avec le compte du joueur, mode Hardcore, déconnexion.
struct RetroAchievementsSection: View {
    @ObservedObject private var achievements = Achievements.shared
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Section {
            if let name = achievements.userName {
                LabeledContent(tr("Compte")) {
                    Text(tr("\(name) · \(achievements.score) points"))
                }
                Toggle(isOn: $achievements.hardcore) {
                    Label(tr("Mode Hardcore"), systemImage: "flame")
                }
                Button(tr("Se déconnecter"), role: .destructive) { achievements.logout() }
            } else {
                TextField(tr("Nom d'utilisateur"), text: $user)
                    .textContentType(.username)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                SecureField(tr("Mot de passe"), text: $password)
                    .textContentType(.password)
                Button {
                    achievements.login(user: user, password: password)
                    password = ""
                } label: {
                    if achievements.busy {
                        ProgressView()
                    } else {
                        Label(tr("Se connecter"), systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || achievements.busy)
                if let error = achievements.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("RetroAchievements")
        } footer: {
            Text(tr("Des succès à débloquer en jouant, avec ton compte gratuit retroachievements.org : NES, Super Nintendo, N64, Game Boy, GBA, DS, PS1, PSP, PS2 et GameCube. Il faut la bonne version du jeu (No-Intro, Redump). PlayTendo garde seulement un jeton de connexion, jamais ton mot de passe."))
            Text(tr("Hardcore : les succès comptent davantage, mais le chargement des sauvegardes rapides, le retour arrière et les codes de triche sont coupés. Pris en compte au prochain jeu lancé."))
        }
    }
}

/// Notifications RetroAchievements par-dessus le jeu (succès débloqué, classement…).
struct AchievementBanners: View {
    @ObservedObject private var achievements = Achievements.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(achievements.banners) { banner in
                HStack(spacing: 10) {
                    AchievementBadge(url: banner.badge, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Neon.text)
                        if !banner.detail.isEmpty {
                            Text(banner.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Neon.dim)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let points = banner.points {
                        Text("+\(points)")
                            .font(Neon.mono(14, weight: .bold))
                            .foregroundStyle(Neon.cyan)
                    }
                }
                .padding(10)
                .frame(maxWidth: 420)
                .background(Chamfer(cut: 10).fill(Neon.panel.opacity(0.95)))
                .overlay(Chamfer(cut: 10).stroke(Neon.cyan.opacity(0.6), lineWidth: 1))
                .neonGlow(Neon.cyan, radius: 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.25), value: achievements.banners)
        .allowsHitTesting(false)
    }
}

/// Badge d'un succès (image de RetroAchievements), une coupe en attendant.
struct AchievementBadge: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().interpolation(.none)
        } placeholder: {
            Image(systemName: "trophy.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(Neon.cyan)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Menu pause › Succès : la liste des succès du jeu, débloqués et à débloquer, avec leur progression.
struct AchievementsListView: View {
    let title: String
    let hardcore: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var list: [PTAchievement] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(list, id: \.identifier) { achievement in
                        HStack(spacing: 12) {
                            AchievementBadge(url: achievement.badgeURL.flatMap(URL.init(string:)), size: 48)
                                .opacity(achievement.unlocked ? 1 : 0.6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(achievement.title)
                                    .font(.headline)
                                Text(achievement.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !achievement.unlocked && !achievement.progress.isEmpty {
                                    Text(achievement.progress)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Image(systemName: achievement.unlocked ? "checkmark.seal.fill" : "lock.fill")
                                    .foregroundStyle(achievement.unlocked ? Color.green : Color.secondary)
                                Text(tr("\(Int(achievement.points)) pts"))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(tr("\(list.filter(\.unlocked).count) succès sur \(list.count)"))
                } footer: {
                    if hardcore {
                        Text(tr("Hardcore : chargement des sauvegardes rapides, retour arrière et codes de triche coupés pour ce jeu."))
                    }
                }
            }
            .navigationTitle(title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .onAppear { list = PTAchievements.shared.achievements() }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
#endif
    }
}
