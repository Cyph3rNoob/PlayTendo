// Affiche la couleur d'un pixel (x y en pixels) pour chaque image PNG donnée.
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
let x = Int(args[1])!, y = Int(args[2])!
for path in args.dropFirst(3) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    print(String(format: "%@ #%02X%02X%02X", (path as NSString).lastPathComponent, pixel[0], pixel[1], pixel[2]))
}
