import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit

/// Types de l'interface propres à chaque système : UIKit sur iPhone et iPad, AppKit sur Mac.
typealias PlatformImage = UIImage
typealias PlatformView = UIView
typealias PlatformColor = UIColor
#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformView = NSView
typealias PlatformColor = NSColor

/// Marges de sécurité de l'écran (encoche, barre d'accueil sur iPhone ; aucune dans une fenêtre du Mac).
typealias UIEdgeInsets = NSEdgeInsets

extension NSEdgeInsets {
    static let zero = NSEdgeInsetsZero
}

extension CGRect {
    func inset(by insets: NSEdgeInsets) -> CGRect {
        CGRect(x: minX + insets.left, y: minY + insets.top, width: width - insets.left - insets.right,
               height: height - insets.top - insets.bottom)
    }
}

/// Fenêtre de PlayTendo sur Mac.
@MainActor
enum MacWindow {
    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    static var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    static func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
#endif

extension Image {
    init(platformImage image: PlatformImage) {
#if os(iOS)
        self.init(uiImage: image)
#else
        self.init(nsImage: image)
#endif
    }
}

extension PlatformImage {
    /// Image à partir d'une image Core Graphics (un pixel = un point).
    static func make(_ image: CGImage) -> PlatformImage {
#if os(iOS)
        UIImage(cgImage: image)
#else
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
#endif
    }

    /// Image Core Graphics (nil si l'image n'en a pas).
    var cgImageValue: CGImage? {
#if os(iOS)
        cgImage
#else
        cgImage(forProposedRect: nil, context: nil, hints: nil)
#endif
    }
}

/// Lecture et écriture d'images avec Core Graphics (pareil sur iPhone et sur Mac).
enum ImageCoding {
    /// Vrai si `data` est une image lisible (PNG, JPEG…).
    static func isImage(_ data: Data) -> Bool {
        decode(data) != nil
    }

    /// Plus grand côté d'une image décodée : une jaquette fait 1 000 à 2 000 pixels. Une image plus grande (piégée, ou
    /// énorme photo) est décodée réduite à cette taille au lieu d'épuiser la mémoire (audit de sécurité du 2026-10-24).
    static let maxPixelSize = 4096

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return image(from: source)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return image(from: source)
    }

    /// Première image, en taille réelle si elle reste raisonnable, sinon réduite (sans jamais la décoder en entier).
    private static func image(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        if max(width, height) <= maxPixelSize { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Image réduite à `width` pixels de large (gardée telle quelle si elle est déjà plus petite).
    static func resized(_ image: CGImage, width: Int) -> CGImage {
        guard image.width > width else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
