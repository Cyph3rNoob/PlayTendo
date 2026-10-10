import SwiftUI
import UIKit

/// Style cyberpunk de PlayTendo : fond nuit, néons cyan et magenta, coins coupés, police Orbitron.
enum Neon {
    static let background = Color(red: 0.016, green: 0.016, blue: 0.047)
    static let cyan = Color(red: 0.0, green: 0.94, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.17, blue: 0.84)
    static let violet = Color(red: 0.54, green: 0.30, blue: 1.0)
    static let text = Color(red: 0.90, green: 0.95, blue: 1.0)
    static let dim = Color(red: 0.50, green: 0.56, blue: 0.68)
    static let panel = Color(red: 0.05, green: 0.06, blue: 0.13)

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension GameSystem {
    /// Nom sur les pastilles et étiquettes : le Game Boy et la Game Boy Color partagent « GB/C » (`libraryGroup`).
    /// `shortName` reste précis (journal).
    var badgeName: String { libraryGroup == .gb ? "GB/C" : shortName }

    /// Titre de la section de la bibliothèque.
    var libraryTitle: String { self == .gb ? "GAME BOY / COLOR" : name.uppercased() }

    /// Couleur néon de la console (la Game Boy Color prend le vert du Game Boy : une seule catégorie GB/C).
    var neon: Color {
        switch self {
        case .nes: Color(red: 1.0, green: 0.27, blue: 0.40)
        case .snes: Color(red: 0.70, green: 0.48, blue: 1.0)
        case .n64: Color(red: 0.20, green: 1.0, blue: 0.55)
        case .gb, .gbc: Color(red: 0.74, green: 1.0, blue: 0.26)
        case .gba: Color(red: 0.42, green: 0.55, blue: 1.0)
        case .nds: Color(red: 0.36, green: 0.90, blue: 1.0)
        case .n3ds: Color(red: 1.0, green: 0.30, blue: 0.30)
        case .psx: Color(red: 0.26, green: 0.60, blue: 1.0)
        case .psp: Color(red: 0.86, green: 0.92, blue: 1.0)
        case .ps2: Color(red: 0.36, green: 0.44, blue: 1.0)
        case .gameCube: Color(red: 0.62, green: 0.40, blue: 1.0)
        case .wii: Color(red: 0.80, green: 0.86, blue: 0.92)
        case .vita: Color(red: 0.50, green: 0.70, blue: 1.0)
        }
    }
}

extension Font {
    /// Orbitron (police libre, licence OFL) ; `weight` de 400 (normal) à 900 (noir).
    static func orbitron(_ size: CGFloat, weight: CGFloat = 700) -> Font {
        Font(UIFont.orbitron(size, weight: weight) as CTFont)
    }
}

extension UIFont {
    static func orbitron(_ size: CGFloat, weight: CGFloat) -> UIFont {
        // Police « variable » : la graisse se règle par l'axe « wght ».
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [.family: "Orbitron", variation: [0x7767_6874: weight]])
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension View {
    /// Halo lumineux autour d'un élément.
    func neonGlow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.75), radius: radius / 3)
            .shadow(color: color.opacity(0.35), radius: radius)
    }
}

/// Rectangle aux coins coupés en biais (haut gauche et bas droit).
struct Chamfer: InsettableShape {
    var cut: CGFloat = 14
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(cut - inset, r.width / 3, r.height / 3))
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Chamfer {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// Fond de l'app : nuit violette, halos cyan et magenta, grille en perspective et lignes de balayage.
struct CyberBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.02, blue: 0.13), Neon.background,
                                    Color(red: 0.03, green: 0.01, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Neon.cyan.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Neon.magenta.opacity(0.14), .clear], center: UnitPoint(x: 1.05, y: 0.5),
                           startRadius: 0, endRadius: 440)
            PerspectiveGrid()
            Scanlines()
        }
        .ignoresSafeArea()
    }
}

/// Grille néon qui file vers l'horizon, en bas de l'écran.
private struct PerspectiveGrid: View {
    var body: some View {
        Canvas { context, size in
            let horizon = size.height * 0.64
            let vanishing = CGPoint(x: size.width / 2, y: horizon)
            let fade = Gradient(colors: [Neon.magenta.opacity(0), Neon.magenta.opacity(0.22)])
            let shading = GraphicsContext.Shading.linearGradient(fade, startPoint: CGPoint(x: 0, y: horizon),
                                                                 endPoint: CGPoint(x: 0, y: size.height))
            var lines = Path()
            for i in -12...12 {
                let x = size.width / 2 + CGFloat(i) * size.width / 7
                lines.move(to: vanishing)
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            var y = horizon + 4
            var step: CGFloat = 5
            while y < size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                step *= 1.32
                y += step
            }
            context.stroke(lines, with: shading, lineWidth: 1)
            // Ligne d'horizon lumineuse.
            var horizonLine = Path()
            horizonLine.move(to: CGPoint(x: 0, y: horizon))
            horizonLine.addLine(to: CGPoint(x: size.width, y: horizon))
            context.stroke(horizonLine, with: .color(Neon.magenta.opacity(0.18)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Fines lignes horizontales, comme un vieil écran.
private struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var y: CGFloat = 0
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(lines, with: .color(.black.opacity(0.18)))
        }
        .allowsHitTesting(false)
    }
}

/// Étiquette de console (« N64 ») aux couleurs néon.
struct SystemBadge: View {
    let system: GameSystem
    var size: CGFloat = 10

    var body: some View {
        Text(system.badgeName)
            .font(.orbitron(size, weight: 900))
            .tracking(1)
            .foregroundStyle(.black)
            .padding(.horizontal, size * 0.7)
            .padding(.vertical, size * 0.35)
            .background(Chamfer(cut: size * 0.5).fill(system.neon))
            .neonGlow(system.neon, radius: 6)
    }
}

/// Bouton rond cerclé de néon (barre du haut).
struct NeonIconButton: View {
    let systemName: String
    var color: Color = Neon.cyan
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(Chamfer(cut: 10).fill(color.opacity(0.08)))
                .overlay(Chamfer(cut: 10).stroke(color.opacity(0.7), lineWidth: 1))
                .neonGlow(color, radius: 6)
        }
        .buttonStyle(.plain)
    }
}

/// Titre de rubrique : barre lumineuse, nom en Orbitron, trait qui s'estompe, compteur.
struct NeonSectionTitle: View {
    let text: String
    let color: Color
    var count: Int?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(color).frame(width: 4, height: 18).neonGlow(color, radius: 6)
            Text(text)
                .font(.orbitron(14, weight: 800))
                .tracking(2)
                .foregroundStyle(Neon.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            LinearGradient(colors: [color.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            if let count {
                Text(String(format: "%02d", count))
                    .font(Neon.mono(12, weight: .bold))
                    .foregroundStyle(color)
            }
        }
    }
}

/// Message temporaire en bas de l'écran.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Neon.mono(13, weight: .semibold))
            .foregroundStyle(Neon.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Chamfer(cut: 8).fill(Color.black.opacity(0.8)))
            .overlay(Chamfer(cut: 8).stroke(Neon.cyan.opacity(0.7), lineWidth: 1))
            .neonGlow(Neon.cyan, radius: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
