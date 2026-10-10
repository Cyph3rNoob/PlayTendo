import SwiftUI
import UIKit

/// Présentation de PlayTendo en 4 cartes (demandée le 2026-10-07) : montrée une fois après l'animation de démarrage
/// (premier lancement, et à chaque nouvelle version de la présentation), et depuis « À propos ».
struct WelcomeView: View {
    /// Version de la présentation déjà vue : l'augmenter la remontre une fois à tout le monde.
    static let seenKey = "presentationVue"
    static let version = 1

    let onFinish: () -> Void

    @State private var page = 0
    private let pageCount = 4

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        ZStack {
            CyberBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Passer", action: onFinish)
                        .font(Neon.mono(14, weight: .semibold))
                        .foregroundStyle(Neon.dim)
                        .opacity(page < pageCount - 1 ? 1 : 0)
                        .disabled(page == pageCount - 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $page) {
                    intro.tag(0)
                    games.tag(1)
                    play.tag(2)
                    turbo.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots.padding(.bottom, 16)
                nextButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: 560)
        }
    }

    // MARK: Cartes

    private var intro: some View {
        WelcomeCard {
            VStack(spacing: 10) {
                if let logo = UIImage(named: "BootLogo") {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .neonGlow(Neon.cyan, radius: 14)
                }
                Text("PLAYTENDO")
                    .font(.orbitron(30, weight: 900))
                    .tracking(2)
                    .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                Text("Tes jeux Nintendo et Sony, sur ton \(device).")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Neon.text)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Text("\(GameSystem.displayOrder.count) CONSOLES")
                .font(.orbitron(12, weight: 800))
                .tracking(2)
                .foregroundStyle(Neon.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 12) {
                ForEach(GameSystem.libraryGroups) { system in
                    SystemBadge(system: system, size: 11)
                }
            }
            WelcomeLine(icon: "sparkles",
                        text: "Une image plus fine qu'à l'origine : jusqu'à 4 fois la résolution (N64, PSP, PS2), 3 fois (GameCube, Wii, 3DS) ou 2 fois (PS1).")
            WelcomeLine(icon: "rectangle.ratio.16.to.9", text: "L'écran large 16:9 pour la N64 et la PS2.")
            WelcomeLine(icon: "clock.arrow.circlepath",
                        text: "Une sauvegarde rapide à tout moment, et « Continuer » pour reprendre là où tu t'étais arrêté.")
            WelcomeLine(icon: "ipad.and.iphone", text: "Sur iPhone et iPad, avec les boutons à l'écran ou une manette.")
        }
    }

    private var games: some View {
        WelcomeCard {
            WelcomeTitle(icon: "folder.fill", title: "AJOUTE TES JEUX", color: Neon.cyan)
            WelcomeLine(icon: "info.circle", text: "PlayTendo ne contient aucun jeu : il fait tourner les tiens.")
            WelcomeLine(icon: "folder", text: "Copie-les dans l'app Fichiers › Sur mon \(device) › PlayTendo › Jeux.")
            WelcomeLine(icon: "plus.circle", text: "Ou touche « + » dans la bibliothèque (les fichiers .zip marchent aussi).")
            WelcomeLine(icon: "cpu", text: "PlayStation 2 : mets aussi le BIOS de ta console dans le dossier BIOS.")
        }
    }

    private var play: some View {
        WelcomeCard {
            WelcomeTitle(icon: "gamecontroller.fill", title: "JOUE", color: Neon.magenta)
            WelcomeLine(icon: "hand.tap", text: "Touche un jeu pour le lancer : des boutons apparaissent à l'écran.")
            WelcomeLine(icon: "gamecontroller",
                        text: "Une manette Bluetooth (Switch, Xbox, PlayStation) marche aussi : les boutons de l'écran s'effacent dès que tu t'en sers.")
            WelcomeLine(icon: "pause.circle", text: "Le bouton menu met le jeu en pause : sauvegarde rapide, options, quitter.")
            WelcomeLine(icon: "externaldrive", text: "Les sauvegardes des jeux s'enregistrent toutes seules.")
        }
    }

    private var turbo: some View {
        WelcomeCard {
            WelcomeTitle(icon: "bolt.fill", title: "MODE TURBO", color: Neon.violet)
#if PLAYTENDO_VITA
            WelcomeLine(icon: "bolt", text: "Obligatoire pour la PS Vita, indispensable pour la PS2, la GameCube, la Wii et la 3DS ; il accélère aussi la PSP. Les autres consoles s'en passent.")
#else
            WelcomeLine(icon: "bolt", text: "Indispensable pour la PS2, la GameCube, la Wii et la 3DS ; il accélère aussi la PSP. Les autres consoles s'en passent.")
#endif
            WelcomeLine(icon: "square.stack.3d.up", text: "Il faut deux apps à part : StikDebug et LocalDevVPN.")
            WelcomeLine(icon: "arrow.triangle.2.circlepath",
                        text: "Il s'active tout seul au lancement d'un de ces jeux, une fois par ouverture de PlayTendo : StikDebug s'ouvre quelques secondes puis te ramène ici.")
            WelcomeLine(icon: "gearshape", text: "Tout est expliqué dans la roue dentée de la bibliothèque.")
        }
    }

    // MARK: Navigation

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Neon.cyan : Neon.dim.opacity(0.4))
                    .frame(width: index == page ? 22 : 8, height: 8)
                    .neonGlow(index == page ? Neon.cyan : .clear, radius: 5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private var nextButton: some View {
        let last = page == pageCount - 1
        let color = last ? Neon.magenta : Neon.cyan
        return Button {
            if last {
                onFinish()
            } else {
                withAnimation { page += 1 }
            }
        } label: {
            Text(last ? "C'EST PARTI !" : "SUIVANT")
                .font(.orbitron(16, weight: 900))
                .tracking(2)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Chamfer(cut: 12).fill(color))
                .neonGlow(color, radius: 10)
        }
        .buttonStyle(.plain)
    }
}

/// Carte de la présentation : contenu centré, défilant si l'écran est petit (iPhone en paysage).
private struct WelcomeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct WelcomeTitle: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(color)
                .neonGlow(color, radius: 14)
            Text(title)
                .font(.orbitron(24, weight: 900))
                .tracking(2)
                .foregroundStyle(Neon.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }
}

private struct WelcomeLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Neon.cyan)
                .frame(width: 24)
            Text(text)
                .font(.body)
                .foregroundStyle(Neon.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
