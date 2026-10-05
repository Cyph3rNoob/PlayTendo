// Dessine l'icône de PlayTendo (1024×1024) : une manette sur un dégradé
// « rouge Nintendo → bleu PlayStation ».  Usage : swift make_icon.swift sortie.png
import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Repère avec l'origine en haut à gauche.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Fond : dégradé diagonal.
let background = CGGradient(colorsSpace: space,
                            colors: [color(0xF2353F), color(0x7A2D9B), color(0x1F4FE0)] as CFArray,
                            locations: [0, 0.52, 1])!
ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: size, y: size), options: [])

// Reflet doux en haut à gauche.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 200), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 200), endRadius: 620, options: [])

// Corps de la manette (rectangle arrondi + deux poignées).
// Tout le dessin de la manette est remonté pour être centré visuellement.
ctx.translateBy(x: 0, y: -46)
let body = CGMutablePath()
body.addRoundedRect(in: CGRect(x: 158, y: 380, width: 708, height: 270), cornerWidth: 135, cornerHeight: 135)
for (cx, angle) in [(CGFloat(292), CGFloat(0.42)), (CGFloat(732), CGFloat(-0.42))] {
    // Poignées : ellipses inclinées vers l'extérieur.
    let transform = CGAffineTransform(translationX: cx, y: 600).rotated(by: angle)
    body.addEllipse(in: CGRect(x: -128, y: -170, width: 256, height: 340), transform: transform)
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 48, color: color(0x000000, 0.38))
ctx.addPath(body)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath(using: .winding)
ctx.restoreGState()

// Croix directionnelle.
ctx.setFillColor(color(0x23243A))
let dpad = CGPoint(x: 322, y: 520)
let arm: CGFloat = 66
let length: CGFloat = 196
let horizontal = CGPath(roundedRect: CGRect(x: dpad.x - length / 2, y: dpad.y - arm / 2, width: length, height: arm),
                        cornerWidth: 14, cornerHeight: 14, transform: nil)
let vertical = CGPath(roundedRect: CGRect(x: dpad.x - arm / 2, y: dpad.y - length / 2, width: arm, height: length),
                      cornerWidth: 14, cornerHeight: 14, transform: nil)
ctx.addPath(horizontal)
ctx.addPath(vertical)
ctx.fillPath(using: .winding)

// Quatre boutons aux couleurs PlayStation, en losange façon Nintendo.
let face = CGPoint(x: 702, y: 520)
let spacing: CGFloat = 66
let radius: CGFloat = 34
let buttons: [(CGFloat, CGFloat, UInt32)] = [
    (0, -1, 0x2FC79C), (1, 0, 0xFF4F5A), (0, 1, 0x4A86FF), (-1, 0, 0xF27AD6),
]
for (dx, dy, hex) in buttons {
    ctx.setFillColor(color(hex))
    ctx.fillEllipse(in: CGRect(x: face.x + dx * spacing - radius, y: face.y + dy * spacing - radius,
                               width: radius * 2, height: radius * 2))
}

// Select / Start.
ctx.setFillColor(color(0xC3C6D6))
for x in [452.0, 532.0] {
    let pill = CGPath(roundedRect: CGRect(x: x - 4, y: 600, width: 48, height: 18), cornerWidth: 9, cornerHeight: 9,
                      transform: nil)
    ctx.addPath(pill)
    ctx.fillPath()
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output) as CFURL
let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Icône écrite : \(output)")
