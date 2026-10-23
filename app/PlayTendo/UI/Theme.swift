import CoreText
import SwiftUI

/// Thème de l'interface (Réglages › Thème), appliqué tout de suite : Néon (cyberpunk, d'origine), Rétro 8-bit (gris
/// des consoles des années 80-90, rouge et bleu marine, coins carrés, police pixel) ou Minimal sombre (bleu nuit avec
/// des vagues de lumière immobiles, texte blanc, un accent bleu, coins arrondis). L'image des jeux, leurs boutons tactiles et l'animation
/// de démarrage ne changent pas.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case neon
    case retro
    case minimal

    var id: String { rawValue }

    static let key = "theme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .neon
    }

    var label: String {
        switch self {
        case .neon: tr("Néon")
        case .retro: tr("Rétro 8-bit")
        case .minimal: tr("Minimal sombre")
        }
    }

    var colorScheme: ColorScheme { self == .retro ? .light : .dark }

    /// Couleur d'une console dans ce thème : néon telle quelle, plus sombre et franche en Rétro, adoucie en Minimal.
    func consoleColor(_ neon: Color) -> Color {
        guard self != .neon else { return neon }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
#if os(iOS)
        UIColor(neon).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
#else
        (NSColor(neon).usingColorSpace(.sRGB) ?? .white)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
#endif
        return self == .retro
            ? Color(hue: hue, saturation: min(1, saturation * 1.1 + 0.15), brightness: brightness * 0.62)
            : Color(hue: hue, saturation: saturation * 0.5, brightness: min(0.82, brightness))
    }
}

/// Couleurs et polices du thème choisi (les noms viennent du thème Néon d'origine : `cyan` est la couleur principale,
/// `magenta` la seconde).
enum Neon {
    private static func pick(_ neon: Color, _ retro: Color, _ minimal: Color) -> Color {
        switch AppTheme.current {
        case .neon: neon
        case .retro: retro
        case .minimal: minimal
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    static var background: Color { pick(rgb(0.016, 0.016, 0.047), rgb(0.78, 0.78, 0.75), rgb(0.039, 0.051, 0.082)) }
    static var cyan: Color { pick(rgb(0.0, 0.94, 1.0), rgb(0.10, 0.18, 0.52), rgb(0.04, 0.52, 1.0)) }
    static var magenta: Color { pick(rgb(1.0, 0.17, 0.84), rgb(0.80, 0.08, 0.12), rgb(0.40, 0.70, 1.0)) }
    static var violet: Color { pick(rgb(0.54, 0.30, 1.0), rgb(0.40, 0.20, 0.55), rgb(0.55, 0.62, 1.0)) }
    static var text: Color { pick(rgb(0.90, 0.95, 1.0), rgb(0.08, 0.08, 0.10), rgb(0.96, 0.96, 0.97)) }
    static var dim: Color { pick(rgb(0.50, 0.56, 0.68), rgb(0.30, 0.30, 0.32), rgb(0.56, 0.56, 0.60)) }
    static var panel: Color { pick(rgb(0.05, 0.06, 0.13), rgb(0.90, 0.90, 0.87), rgb(0.10, 0.115, 0.16)) }
    /// Texte posé sur la couleur principale (bouton « Reprendre », pastille choisie).
    static var onAccent: Color { pick(.black, .white, .white) }
    /// Texte posé sur la couleur d'une console (étiquettes « N64 »…).
    static var onConsole: Color { pick(.black, .white, .black) }
    /// Fond sous les jaquettes.
    static var coverBase: Color { pick(.black, rgb(0.16, 0.16, 0.18), .black) }
    /// Couleur des listes et boutons du système (Réglages, À propos).
    static var tint: Color { pick(rgb(1.0, 0.36, 0.40), rgb(0.80, 0.08, 0.12), rgb(0.04, 0.52, 1.0)) }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: AppTheme.current == .minimal ? .rounded : .monospaced)
    }
}


extension GameSystem {
    /// Nom sur les pastilles et étiquettes : le Game Boy et la Game Boy Color partagent « GB/C » (`libraryGroup`).
    /// `shortName` reste précis (journal).
    var badgeName: String { libraryGroup == .gb ? "GB/C" : shortName }

    /// Titre de la section de la bibliothèque.
    var libraryTitle: String { self == .gb ? "GAME BOY / COLOR" : name.uppercased() }

    /// Couleur de la console dans le thème choisi (la Game Boy Color prend le vert du Game Boy : une seule
    /// catégorie GB/C).
    var neon: Color { AppTheme.current.consoleColor(neonOriginal) }

    /// Couleur néon d'origine.
    private var neonOriginal: Color {
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
#if PLAYTENDO_VITA
        case .vita: Color(red: 0.50, green: 0.70, blue: 1.0)
#endif
        }
    }
}

extension Font {
    /// Orbitron (police libre, licence OFL) ; `weight` de 400 (normal) à 900 (noir). Toujours elle, quel que soit le
    /// thème (animation de démarrage) ; ailleurs, `display`.
    static func orbitron(_ size: CGFloat, weight: CGFloat = 700) -> Font {
        Font(orbitronFont(size, weight: weight))
    }

    /// Police des titres et boutons du thème : Orbitron (Néon), Press Start 2P (Rétro, police pixel libre OFL, plus
    /// petite car très large) ou police du système arrondie (Minimal).
    static func display(_ size: CGFloat, weight: CGFloat = 700) -> Font {
        switch AppTheme.current {
        case .neon:
            orbitron(size, weight: weight)
        case .retro:
            .custom("PressStart2P-Regular", fixedSize: (size * 0.72).rounded())
        case .minimal:
            .system(size: size * 0.95, weight: weight >= 850 ? .heavy : weight >= 750 ? .bold : weight >= 600 ? .semibold : .medium,
                    design: .rounded)
        }
    }
}

/// Orbitron à la graisse voulue. Police « variable » : la graisse se règle par l'axe « wght ».
private func orbitronFont(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: "Orbitron",
                                       kCTFontVariationAttribute: [0x7767_6874: weight]]
    return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
}

extension View {
    /// Halo lumineux autour d'un élément (Néon) ; ombre portée nette (Rétro) ; rien sur le noir du Minimal.
    func neonGlow(_ color: Color, radius: CGFloat = 8) -> some View {
        let theme = AppTheme.current
        return shadow(color: theme == .neon ? color.opacity(0.75) : Self.plainShadow(theme, visible: color != .clear),
                      radius: theme == .neon ? radius / 3 : theme == .retro ? 0 : radius * 0.6,
                      x: theme == .retro ? 2 : 0, y: theme == .neon ? 0 : 2)
            .shadow(color: theme == .neon ? color.opacity(0.35) : .clear, radius: radius)
    }

    /// Ombre colorée (Néon), remplacée par l'ombre du thème ailleurs.
    func themedShadow(_ color: Color, radius: CGFloat) -> some View {
        let theme = AppTheme.current
        return shadow(color: theme == .neon ? color : Self.plainShadow(theme, visible: color != .clear),
                      radius: theme == .neon ? radius : theme == .retro ? 0 : radius * 0.6,
                      x: theme == .retro ? 2 : 0, y: theme == .neon ? 0 : 2)
    }

    private static func plainShadow(_ theme: AppTheme, visible: Bool) -> Color {
        visible && theme == .retro ? .black.opacity(0.28) : .clear
    }
}

/// Forme des cadres et boutons : coins coupés en biais, haut gauche et bas droit (Néon), carrés (Rétro) ou arrondis
/// (Minimal, rayon `cut`).
struct Chamfer: InsettableShape {
    var cut: CGFloat = 14
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(cut - inset, r.width / 3, r.height / 3))
        switch AppTheme.current {
        case .retro: return Path(r)
        case .minimal: return Path(roundedRect: r, cornerRadius: c, style: .continuous)
        case .neon: break
        }
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

/// Fond de l'app selon le thème. Néon : nuit violette, halos cyan et magenta, grille en perspective et lignes de
/// balayage. Rétro : gris clair à motif de pixels. Minimal : bleu nuit, vagues de lumière en bas.
struct CyberBackground: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.neon

    var body: some View {
        ZStack {
            switch theme {
            case .neon:
                LinearGradient(colors: [Color(red: 0.05, green: 0.02, blue: 0.13), Neon.background,
                                        Color(red: 0.03, green: 0.01, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Neon.cyan.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Neon.magenta.opacity(0.14), .clear], center: UnitPoint(x: 1.05, y: 0.5),
                               startRadius: 0, endRadius: 440)
                PerspectiveGrid()
                Scanlines()
            case .retro:
                Neon.background
                PixelPattern()
            case .minimal:
                LinearGradient(colors: [Neon.background, Color(red: 0.063, green: 0.086, blue: 0.16)],
                               startPoint: .top, endPoint: .bottom)
                LightWaves()
            }
        }
        .ignoresSafeArea()
    }
}

/// Petits carrés réguliers, comme les points d'un vieil écran (thème Rétro).
private struct PixelPattern: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = (Int(y / 8) % 2 == 0) ? 0 : 4
                while x < size.width {
                    dots.addRect(CGRect(x: x, y: y, width: 2, height: 2))
                    x += 8
                }
                y += 8
            }
            context.fill(dots, with: .color(.black.opacity(0.06)))
        }
        .allowsHitTesting(false)
    }
}

/// Vagues de lumière du thème Minimal : quatre couches ondulées bleues et violettes en bas de l'écran, liseré clair
/// sur chaque crête. Immobiles : dessinées une fois (redessinées seulement si la taille change), sans dépense de
/// batterie.
private struct LightWaves: View {
    /// Haut de la couche (part de la hauteur), amplitude (part de la hauteur), ondes sur la largeur, décalage, couleur.
    private static let layers: [(top: CGFloat, amplitude: CGFloat, waves: CGFloat, phase: CGFloat, color: Color)] = [
        (0.56, 0.037, 1.0, 0, Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.10)),
        (0.66, 0.044, 0.9, 2, Color(red: 0.51, green: 0.43, blue: 1.0).opacity(0.12)),
        (0.76, 0.033, 1.2, 4, Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.16)),
        (0.86, 0.030, 1.1, 1, Color(red: 0.16, green: 0.24, blue: 0.51).opacity(0.45)),
    ]

    var body: some View {
        Canvas { context, size in
            for layer in Self.layers {
                var crest = Path()
                var x: CGFloat = 0
                while x <= size.width + 4 {
                    let angle = x / max(size.width, 1) * layer.waves * 2 * .pi + layer.phase
                    let point = CGPoint(x: x, y: size.height * (layer.top + layer.amplitude * sin(angle)))
                    if x == 0 { crest.move(to: point) } else { crest.addLine(to: point) }
                    x += 4
                }
                var fill = crest
                fill.addLine(to: CGPoint(x: size.width + 4, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .color(layer.color))
                context.stroke(crest, with: .color(Color(red: 0.55, green: 0.70, blue: 1.0).opacity(0.25)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
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
            .font(.display(size, weight: 900))
            .tracking(1)
            .foregroundStyle(Neon.onConsole)
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
                .font(.display(14, weight: 800))
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
            .background(Chamfer(cut: 8).fill(Neon.panel.opacity(0.95)))
            .overlay(Chamfer(cut: 8).stroke(Neon.cyan.opacity(0.7), lineWidth: 1))
            .neonGlow(Neon.cyan, radius: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
