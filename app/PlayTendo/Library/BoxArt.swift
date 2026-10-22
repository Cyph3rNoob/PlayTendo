import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

/// Boîtes 3D des jaquettes. ScreenScraper fournit des boîtes déjà en 3D ; quand la jaquette vient d'ailleurs (libretro,
/// SteamGridDB, boîte 2D de ScreenScraper), PlayTendo fabrique la boîte lui-même dans le même style : face légèrement
/// tournée, tranche sur le côté (ou dessous pour les boîtes couchées) aux couleurs du boîtier de la console, titre
/// écrit dessus, mêmes proportions que les boîtes de ScreenScraper. Toutes les boîtes d'une console ont ainsi la même
/// forme (`aspect`), et la bibliothèque les aligne à la même hauteur.
enum BoxArt {
    /// Forme des boîtes de la console (largeur / hauteur de l'image), mesurée sur celles de ScreenScraper
    /// (2026-10-22) : la bibliothèque leur donne cette place.
    static func aspect(for system: GameSystem) -> CGFloat { look(for: system).aspect }

    /// Boîte 3D fabriquée à partir d'une jaquette plate, en PNG transparent. nil si l'image est illisible.
    static func make(from data: Data, system: GameSystem, title: String) -> Data? {
        guard let art = ImageCoding.decode(data), let box = render(art: art, look: look(for: system), title: title)
        else { return nil }
        return ImageCoding.png(box)
    }

    /// Boîte déjà en 3D (ScreenScraper) : bords transparents retirés, pour qu'elle remplisse sa place comme les autres.
    static func trimmed(_ data: Data) -> Data? {
        guard let image = ImageCoding.decode(data), let trimmed = trimTransparentBorder(image) else { return nil }
        return ImageCoding.png(trimmed)
    }

    /// Vrai si l'image est une jaquette plate (coins opaques), faux pour une boîte 3D (fond transparent autour).
    static func isFlat(_ data: Data) -> Bool {
        guard let image = ImageCoding.decode(data) else { return false }
        let size = 16
        guard let context = rgbaContext(width: size, height: size) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let corners = [0, size - 1, (size - 1) * size, size * size - 1]
        return corners.allSatisfy { pixels[$0 * 4 + 3] > 240 }
    }

    // MARK: Styles des boîtiers

    private enum Style {
        /// Boîtier fin, tranche étroite à gauche (DVD, PS Vita, PSP, DS, 3DS).
        case keepCase
        /// Boîte carton ou boîtier CD, tranche large à gauche (NES, Game Boy, PS1).
        case thick
        /// Boîte couchée, tranche dessous (N64, Super Nintendo).
        case landscape
    }

    private struct Look {
        let style: Style
        /// Largeur / hauteur de l'image finale.
        let aspect: CGFloat
        /// Largeur / hauteur de la face avant à plat (la jaquette y est recadrée).
        let frontAspect: CGFloat
        /// Couleur de la tranche ; nil : prise sur le bord de la jaquette (boîtes carton).
        let spine: (CGFloat, CGFloat, CGFloat)?
        /// Bandeau en haut de la tranche (bleu de la PS Vita, rouge de la 3DS).
        var band: (CGFloat, CGFloat, CGFloat)? = nil
        let label: String
        /// Texte clair (tranche sombre) ou foncé (tranche claire).
        let lightText: Bool
    }

    private static func look(for system: GameSystem) -> Look {
        let black = (0.07, 0.07, 0.08) as (CGFloat, CGFloat, CGFloat)
        switch system {
        case .nes: return Look(style: .thick, aspect: 0.54, frontAspect: 0.72, spine: black, label: "NES", lightText: true)
        case .snes: return Look(style: .landscape, aspect: 1.85, frontAspect: 1.38, spine: (0.16, 0.16, 0.18),
                                label: "SUPER NINTENDO", lightText: true)
        case .n64: return Look(style: .landscape, aspect: 1.85, frontAspect: 1.38, spine: black, label: "NINTENDO 64",
                               lightText: true)
        case .gb: return Look(style: .thick, aspect: 0.77, frontAspect: 0.75, spine: nil, label: "GAME BOY", lightText: true)
        case .gbc: return Look(style: .thick, aspect: 0.77, frontAspect: 0.75, spine: nil, label: "GAME BOY COLOR",
                               lightText: true)
        case .gba: return Look(style: .thick, aspect: 0.77, frontAspect: 0.75, spine: nil, label: "GAME BOY ADVANCE",
                               lightText: true)
        case .nds: return Look(style: .keepCase, aspect: 0.79, frontAspect: 0.89, spine: (0.92, 0.92, 0.93),
                               label: "NINTENDO DS", lightText: false)
        case .n3ds: return Look(style: .keepCase, aspect: 0.79, frontAspect: 0.89, spine: (0.94, 0.94, 0.95),
                                band: (0.80, 0.05, 0.10), label: "NINTENDO 3DS", lightText: false)
        case .psx: return Look(style: .thick, aspect: 0.79, frontAspect: 1.0, spine: black, label: "PlayStation",
                               lightText: true)
        case .ps2: return Look(style: .keepCase, aspect: 0.51, frontAspect: 0.71, spine: (0.05, 0.05, 0.06),
                               label: "PlayStation 2", lightText: true)
        case .psp: return Look(style: .keepCase, aspect: 0.45, frontAspect: 0.58, spine: black, label: "PSP", lightText: true)
        case .gameCube: return Look(style: .keepCase, aspect: 0.51, frontAspect: 0.70, spine: black,
                                    label: "NINTENDO GAMECUBE", lightText: true)
        case .wii: return Look(style: .keepCase, aspect: 0.51, frontAspect: 0.71, spine: (0.95, 0.95, 0.96), label: "Wii",
                               lightText: false)
#if PLAYTENDO_VITA
        case .vita: return Look(style: .keepCase, aspect: 0.51, frontAspect: 0.58, spine: (0.86, 0.87, 0.89),
                                band: (0.15, 0.38, 0.80), label: "PS VITA", lightText: false)
#endif
        }
    }

    // MARK: Fabrication

    /// Hauteur des boîtes debout (largeur des boîtes couchées), en pixels : comme les images de ScreenScraper.
    private static let size: CGFloat = 640

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

    /// Quatre coins d'une face dans l'image (repère du haut à gauche).
    private struct Quad {
        var topLeft, topRight, bottomRight, bottomLeft: CGPoint
    }

    private static func render(art: CGImage, look: Look, title: String) -> CGImage? {
        let landscape = look.style == .landscape
        let width = (landscape ? size : size * look.aspect).rounded()
        let height = (landscape ? size / look.aspect : size).rounded()
        let spineColor = look.spine ?? edgeColor(of: art)

        // Faces à plat : jaquette recadrée au format de la face avant, tranche dessinée.
        let frontSize = landscape ? CGSize(width: width, height: (width / look.frontAspect).rounded())
                                  : CGSize(width: (height * look.frontAspect).rounded(), height: height)
        let spineSize = landscape ? CGSize(width: width, height: (width * 0.09).rounded())
                                  : CGSize(width: (height * (look.style == .thick ? 0.22 : 0.085)).rounded(), height: height)
        guard let front = frontFace(art, size: frontSize),
              let spine = spineFace(look: look, color: spineColor, title: title, size: spineSize, horizontal: landscape)
        else { return nil }

        // Placement en perspective : la tranche fuit vers la gauche (ou vers le bas), la face avant vers la droite.
        let (spineQuad, frontQuad) = landscape ? landscapeQuads(width, height) : portraitQuads(width, height, look.style)
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(color: .clear).cropped(to: canvasRect)
        for (face, quad) in [(spine, spineQuad), (front, frontQuad)] {
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = CIImage(cgImage: face)
            // Core Image compte les hauteurs depuis le bas.
            func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }
            filter.topLeft = flip(quad.topLeft)
            filter.topRight = flip(quad.topRight)
            filter.bottomRight = flip(quad.bottomRight)
            filter.bottomLeft = flip(quad.bottomLeft)
            guard let output = filter.outputImage else { return nil }
            image = output.composited(over: image)
        }
        guard let composed = ciContext.createCGImage(image, from: canvasRect, format: .RGBA8, colorSpace: sRGB),
              let context = rgbaContext(width: Int(width), height: Int(height)) else { return nil }
        context.draw(composed, in: canvasRect)
        // Arête claire entre la tranche et la face avant.
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
        context.setLineWidth(2)
        let edgeStart = landscape ? frontQuad.bottomLeft : frontQuad.topLeft
        let edgeEnd = landscape ? frontQuad.bottomRight : frontQuad.bottomLeft
        context.move(to: CGPoint(x: edgeStart.x, y: height - edgeStart.y))
        context.addLine(to: CGPoint(x: edgeEnd.x, y: height - edgeEnd.y))
        context.strokePath()
        return context.makeImage()
    }

    private static func portraitQuads(_ width: CGFloat, _ height: CGFloat, _ style: Style) -> (Quad, Quad) {
        let outer = width * 0.015
        let inner = outer + width * (style == .thick ? 0.24 : 0.105)
        let right = width * 0.985
        let near: CGFloat = height * 0.01                          // arête la plus proche : la plus haute
        let far = height * (style == .thick ? 0.055 : 0.04)        // bord droit de la face avant, plus loin
        let spineFar = height * 0.035                              // bord gauche de la tranche
        let spine = Quad(topLeft: CGPoint(x: outer, y: spineFar), topRight: CGPoint(x: inner, y: near),
                         bottomRight: CGPoint(x: inner, y: height - near), bottomLeft: CGPoint(x: outer, y: height - spineFar))
        let front = Quad(topLeft: CGPoint(x: inner, y: near), topRight: CGPoint(x: right, y: far),
                         bottomRight: CGPoint(x: right, y: height - far), bottomLeft: CGPoint(x: inner, y: height - near))
        return (spine, front)
    }

    private static func landscapeQuads(_ width: CGFloat, _ height: CGFloat) -> (Quad, Quad) {
        let edge = height * 0.77                                   // bas de la face avant, haut de la tranche
        let front = Quad(topLeft: CGPoint(x: width * 0.025, y: height * 0.02), topRight: CGPoint(x: width * 0.975, y: height * 0.02),
                         bottomRight: CGPoint(x: width * 0.99, y: edge), bottomLeft: CGPoint(x: width * 0.01, y: edge))
        let spine = Quad(topLeft: CGPoint(x: width * 0.01, y: edge), topRight: CGPoint(x: width * 0.99, y: edge),
                         bottomRight: CGPoint(x: width * 0.975, y: height * 0.98), bottomLeft: CGPoint(x: width * 0.025, y: height * 0.98))
        return (spine, front)
    }

    /// Face avant : la jaquette au format du boîtier, avec un léger ombrage. Une jaquette d'un autre format est un peu
    /// resserrée (au plus 12 %, à peine visible) puis recadrée pour le reste : le titre reste entier le plus souvent.
    private static func frontFace(_ art: CGImage, size: CGSize) -> CGImage? {
        guard let context = rgbaContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        let artAspect = CGFloat(art.width) / CGFloat(art.height)
        let target = size.width / size.height
        let squeeze = min(1.12, max(1 / 1.12, artAspect / target))   // > 1 : jaquette plus large que la face
        let scale = max(size.width * squeeze / CGFloat(art.width), size.height / CGFloat(art.height))
        let drawn = CGSize(width: CGFloat(art.width) * scale / squeeze, height: CGFloat(art.height) * scale)
        context.interpolationQuality = .high
        context.draw(art, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                     width: drawn.width, height: drawn.height))
        // Plus sombre vers le bord qui s'éloigne.
        let shade = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06),
                                                           CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16)] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(shade, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
        return context.makeImage()
    }

    /// Tranche à plat : couleur du boîtier, bandeau éventuel, nom de la console et titre du jeu (écrits de haut en bas,
    /// ou en travers pour une boîte couchée), un peu assombrie (elle est de côté).
    private static func spineFace(look: Look, color: (CGFloat, CGFloat, CGFloat), title: String, size: CGSize,
                                  horizontal: Bool) -> CGImage? {
        guard let context = rgbaContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        let full = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(full)
        let light = look.lightText
        let textColor = light ? CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
                              : CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        let text = title.uppercased()

        if horizontal {
            // Boîte couchée : console à gauche, titre au milieu.
            let thickness = size.height
            let labelLength = draw(look.label, size: thickness * 0.34, color: textColor, in: context,
                                   origin: CGPoint(x: thickness * 0.5, y: thickness * 0.33), maxLength: size.width * 0.25)
            let titleSize = thickness * 0.5
            let room = size.width - labelLength - thickness * 1.5
            let length = measure(text, size: titleSize, maxLength: room)
            _ = draw(text, size: titleSize, color: textColor, in: context,
                     origin: CGPoint(x: (size.width - length) / 2 + labelLength / 2, y: thickness * 0.3), maxLength: room)
        } else {
            let thickness = size.width
            if look.style == .thick {
                // Boîte carton, boîtier CD : titre en haut, nom de la console en bas, écrits de haut en bas.
                let titleSize = thickness * 0.36
                let titleRoom = size.height * 0.56
                let length = measure(text, size: titleSize, maxLength: titleRoom)
                drawVertical(text, size: titleSize, color: textColor, in: context, centerX: thickness / 2,
                             top: size.height * 0.96 - max(0, (titleRoom - length) / 2), maxLength: titleRoom)
                drawVertical(look.label, size: thickness * 0.24, color: textColor, in: context, centerX: thickness / 2,
                             top: size.height * 0.36, maxLength: size.height * 0.32)
            } else {
                // Boîtier fin : bandeau et nom de la console en haut, titre dessous, écrits de haut en bas.
                var top = size.height
                let bandHeight = size.height * 0.14
                if let band = look.band {
                    context.setFillColor(CGColor(srgbRed: band.0, green: band.1, blue: band.2, alpha: 1))
                    context.fill(CGRect(x: 0, y: size.height - bandHeight, width: thickness, height: bandHeight))
                }
                let labelColor = look.band != nil ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : textColor
                drawVertical(look.label, size: thickness * 0.42, color: labelColor, in: context, centerX: thickness / 2,
                             top: top - thickness * 0.25, maxLength: bandHeight - thickness * 0.4)
                top -= bandHeight + thickness * 0.3
                let titleSize = thickness * 0.55
                let room = top - size.height * 0.06
                let length = measure(text, size: titleSize, maxLength: room)
                drawVertical(text, size: titleSize, color: textColor, in: context, centerX: thickness / 2,
                             top: top - max(0, (room - length) / 2), maxLength: room)
            }
        }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        context.fill(full)
        return context.makeImage()
    }

    // MARK: Texte

    private static func font(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    private static func line(_ text: String, size: CGFloat, color: CGColor, maxLength: CGFloat) -> CTLine {
        var fontSize = size
        func make(_ string: String) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(fontSize),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        }
        var result = make(text)
        // Trop long : plus petit (jusqu'à la moitié), puis coupé avec « … ».
        while CTLineGetTypographicBounds(result, nil, nil, nil) > maxLength && fontSize > size * 0.5 {
            fontSize *= 0.92
            result = make(text)
        }
        if CTLineGetTypographicBounds(result, nil, nil, nil) > maxLength {
            result = CTLineCreateTruncatedLine(result, Double(maxLength), .end, make("…")) ?? result
        }
        return result
    }

    private static func measure(_ text: String, size: CGFloat, maxLength: CGFloat) -> CGFloat {
        min(maxLength, CGFloat(CTLineGetTypographicBounds(line(text, size: size, color: CGColor(gray: 0, alpha: 1),
                                                                maxLength: maxLength), nil, nil, nil)))
    }

    /// Texte en travers ; renvoie sa longueur.
    @discardableResult
    private static func draw(_ text: String, size: CGFloat, color: CGColor, in context: CGContext, origin: CGPoint,
                             maxLength: CGFloat) -> CGFloat {
        let textLine = line(text, size: size, color: color, maxLength: maxLength)
        context.textPosition = origin
        CTLineDraw(textLine, context)
        return CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
    }

    /// Texte écrit de haut en bas (haut des lettres vers la droite, comme sur une tranche), centré sur `centerX`.
    private static func drawVertical(_ text: String, size: CGFloat, color: CGColor, in context: CGContext,
                                     centerX: CGFloat, top: CGFloat, maxLength: CGFloat) {
        guard maxLength > 0 else { return }
        let textLine = line(text, size: size, color: color, maxLength: maxLength)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(textLine, &ascent, &descent, nil)
        context.saveGState()
        context.translateBy(x: centerX - (ascent - descent) / 2, y: top)
        context.rotate(by: -.pi / 2)
        context.textPosition = .zero
        CTLineDraw(textLine, context)
        context.restoreGState()
    }

    // MARK: Pixels

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Couleur moyenne du bord gauche de la jaquette, assombrie : tranche des boîtes carton (l'image s'y prolonge).
    private static func edgeColor(of art: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        guard let edge = art.cropping(to: CGRect(x: 0, y: 0, width: max(1, art.width / 6), height: art.height)),
              let context = rgbaContext(width: 1, height: 1),
              let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return (0.1, 0.1, 0.12) }
        context.interpolationQuality = .medium
        context.draw(edge, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(pixel[0]) / 255 * 0.7, CGFloat(pixel[1]) / 255 * 0.7, CGFloat(pixel[2]) / 255 * 0.7)
    }

    /// Image recadrée sur ce qui n'est pas transparent (2 pixels de marge).
    private static func trimTransparentBorder(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = rgbaContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // Les lignes du contexte vont du haut vers le bas, comme celles de l'image.
        let rect = CGRect(x: max(0, minX - 2), y: max(0, minY - 2),
                          width: min(width, maxX + 3) - max(0, minX - 2), height: min(height, maxY + 3) - max(0, minY - 2))
        return image.cropping(to: rect) ?? image
    }
}
