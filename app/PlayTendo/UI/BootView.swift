import SwiftUI
import UIKit

/// Animation de démarrage : un écran cathodique s'allume sur le logo, une étincelle jaillit entre
/// les deux manettes, puis « PLAYTENDO » s'écrit et quelques lignes de démarrage défilent.
/// Un toucher la passe. Version sobre si « Réduire les animations » est activé.
struct BootView: View {
    let gameCount: Int
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lineWidth: CGFloat = 0
    @State private var lineOpacity = 1.0
    @State private var logoScaleY: CGFloat = 0.004
    @State private var logoOpacity = 0.0
    @State private var flash = 0.0
    @State private var glow = 0.0
    @State private var spark: CGFloat = 0
    @State private var sparkOpacity = 0.0
    @State private var letters = 0
    @State private var lines = 0
    @State private var leaving = false
    @State private var finished = false

    /// Logo rangé à la racine de l'app (hors catalogue d'images, pour garder sa pleine définition).
    private static let logo = UIImage(named: "BootLogo") ?? UIImage()
    private static let title = Array("PLAYTENDO")
    private static let red = Color(red: 1.0, green: 0.12, blue: 0.16)
    private static let blue = Color(red: 0.12, green: 0.45, blue: 1.0)
    private let logoSize: CGFloat = 210

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 30) {
                ZStack {
                    // Trait lumineux de l'écran qui s'allume.
                    Capsule()
                        .fill(Color.white)
                        .frame(width: lineWidth, height: 3)
                        .shadow(color: .white, radius: 6)
                        .shadow(color: Self.blue, radius: 16)
                        .opacity(lineOpacity)

                    Image(uiImage: Self.logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: logoSize, height: logoSize)
                        .overlay(Color.white.opacity(flash))
                        .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.2237, style: .continuous))
                        .shadow(color: Self.red.opacity(0.75 * glow), radius: 28, x: -14)
                        .shadow(color: Self.blue.opacity(0.75 * glow), radius: 28, x: 14)
                        .scaleEffect(x: 1, y: logoScaleY)
                        .opacity(logoOpacity)

                    // Étincelle au point de rencontre des deux manettes.
                    RadialGradient(colors: [.white, Color.white.opacity(0.6), .clear], center: .center,
                                   startRadius: 0, endRadius: 90)
                        .frame(width: 180, height: 180)
                        .scaleEffect(spark)
                        .opacity(sparkOpacity)
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }
                .frame(height: logoSize)
                .background {
                    // Halos rouge et bleu autour du logo, qui se mêlent en violet au milieu.
                    ZStack {
                        RadialGradient(colors: [Self.red.opacity(0.38), .clear], center: UnitPoint(x: 0.4, y: 0.5),
                                       startRadius: 0, endRadius: 330)
                        RadialGradient(colors: [Self.blue.opacity(0.38), .clear], center: UnitPoint(x: 0.6, y: 0.5),
                                       startRadius: 0, endRadius: 330)
                    }
                    .frame(width: 1000, height: 1000)
                    .opacity(glow)
                    .allowsHitTesting(false)
                }

                HStack(spacing: 0) {
                    ForEach(Self.title.indices, id: \.self) { index in
                        Text(String(Self.title[index]))
                            .opacity(index < letters ? 1 : 0)
                            .offset(y: index < letters ? 0 : 6)
                    }
                }
                .font(.orbitron(34, weight: 900))
                .tracking(5)
                .foregroundStyle(LinearGradient(colors: [Self.red, .white, Self.blue], startPoint: .leading, endPoint: .trailing))
                .shadow(color: Self.blue.opacity(0.6 * glow), radius: 12)
                .shadow(color: Self.red.opacity(0.4 * glow), radius: 18)

                VStack(alignment: .leading, spacing: 5) {
                    bootLine("> MOTEURS ............ 7/7 OK", index: 1)
                    bootLine("> BIBLIOTHÈQUE ....... \(gameCount) JEU\(gameCount > 1 ? "X" : "")", index: 2)
                    bootLine("> SYSTÈME PRÊT", index: 3, color: Neon.cyan)
                }
                .frame(width: 270, alignment: .leading)
            }
        }
        .overlay(BootScanlines().ignoresSafeArea())
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving && !reduceMotion ? 1.06 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await run() }
        .accessibilityLabel("PlayTendo")
    }

    private func bootLine(_ text: String, index: Int, color: Color = Neon.dim) -> some View {
        Text(text)
            .font(Neon.mono(12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(color)
            .opacity(lines >= index ? 1 : 0)
    }

    // MARK: Déroulé

    private func run() async {
        if reduceMotion {
            lineOpacity = 0
            logoScaleY = 1
            withAnimation(.easeOut(duration: 0.4)) {
                logoOpacity = 1
                glow = 1
                letters = Self.title.count
                lines = 3
            }
            await pause(1.1)
            finish()
            return
        }

        await pause(0.15)
        withAnimation(.easeOut(duration: 0.22)) { lineWidth = logoSize + 40 }
        await pause(0.26)

        // L'écran s'ouvre verticalement, avec un éclair blanc.
        logoOpacity = 1
        flash = 1
        withAnimation(.easeOut(duration: 0.22)) {
            logoScaleY = 1
            lineOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.4)) { flash = 0 }
        await pause(0.24)

        // Petit grésillement.
        for value in [0.45, 1, 0.7, 1] {
            logoOpacity = value
            await pause(0.04)
        }

        // Étincelle et halos.
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
        sparkOpacity = 1
        withAnimation(.easeOut(duration: 0.5)) {
            spark = 1.7
            sparkOpacity = 0
        }
        withAnimation(.easeInOut(duration: 0.6)) { glow = 1 }
        await pause(0.15)

        for count in 1...Self.title.count {
            withAnimation(.easeOut(duration: 0.12)) { letters = count }
            await pause(0.055)
        }
        for count in 1...3 {
            await pause(0.16)
            withAnimation(.easeOut(duration: 0.15)) { lines = count }
        }
        await pause(0.45)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: 0.35)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onFinish() }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Lignes de balayage par-dessus l'animation, comme un écran cathodique.
private struct BootScanlines: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var y: CGFloat = 0
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(lines, with: .color(.black.opacity(0.22)))
        }
        .allowsHitTesting(false)
    }
}
