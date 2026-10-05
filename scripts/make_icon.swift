// Fabrique l'icône de PlayTendo (1024×1024) et le logo de l'animation de démarrage à partir de
// art/logo-source.jpg (logo fourni par l'utilisateur, coins blancs arrondis).
// Les coins blancs sont remplacés par le fond sombre du logo (rouge à gauche, bleu nuit à droite) :
// iOS arrondit lui-même l'icône et ne doit trouver aucun liseré clair.
//   swift scripts/make_icon.swift   (depuis la racine du projet)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let source = "art/logo-source.jpg"
guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Logo introuvable : \(source)")
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)
    // Fond des coins : même dégradé que les bords du logo.
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x160100), color(0x000000), color(0x01071F)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: s, y: 0), options: [])
    // Le logo, sans ses coins blancs : son carré arrondi a un rayon d'environ 20 % du côté.
    let radius = s * 0.215
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(logo, in: CGRect(x: 0, y: 0, width: s, height: s))
    return ctx.makeImage()!
}

func save(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Écriture impossible : \(path)") }
    print("OK  \(path)")
}

save(render(size: 1024), to: "app/PlayTendo/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
save(render(size: 600), to: "app/PlayTendo/Resources/BootLogo.png")
