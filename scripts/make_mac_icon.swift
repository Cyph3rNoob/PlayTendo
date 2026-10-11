// Icône Mac de PlayTendo, tirée de l'icône iPhone (AppIcon.appiconset/icon-1024.png, carrée, que l'iPhone arrondit
// lui-même) : posée dans la forme arrondie des apps Mac (824 × 824 px sur une toile de 1024, coins « continus »,
// légère ombre), puis déclinée aux tailles du Mac (16 à 1024 px) dans le même appiconset.
//   swift scripts/make_mac_icon.swift
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("app/PlayTendo/Assets.xcassets/AppIcon.appiconset")
guard let source = NSImage(contentsOf: set.appendingPathComponent("icon-1024.png")),
      let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("icon-1024.png illisible")
}

func render(_ pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = Path(roundedRect: body, cornerRadius: 185, style: .continuous).cgPath
    // Ombre douce sous l'icône (grille d'Apple : décalée vers le bas).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()
    context.addPath(shape)
    context.clip()
    context.interpolationQuality = .high
    context.draw(sourceImage, in: body)
    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = [
    ["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "mac-\(points)@\(scale)x.png"
        try! render(pixels).write(to: set.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: set.appendingPathComponent("Contents.json"))
print("Icône Mac : \(images.count - 1) images dans \(set.lastPathComponent)")
