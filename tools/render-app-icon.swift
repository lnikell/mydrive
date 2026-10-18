import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Renders MyDrive.icns from the square artwork in MacApp/Resources/AppIconArtwork.png.
// The artwork is masked to Apple's macOS app icon grid: an 824 pt continuous-corner
// shape centred on a 1024 pt canvas, with the standard soft drop shadow below it.
private enum Grid {
    static let canvas = 1024.0
    static let body = 824.0
    static let radius = 185.4
    static let shadowOffset = 12.0
    static let shadowBlur = 24.0
    static let shadowOpacity = 0.28
}

private enum Failure: Error { case render, artwork }

private func render(_ artwork: CGImage, size: Int) throws -> CGImage {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.render }
    let scale = Double(size) / Grid.canvas
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let inset = (Grid.canvas - Grid.body) / 2
    let body = CGRect(x: inset, y: inset, width: Grid.body, height: Grid.body)
    let shape = RoundedRectangle(cornerRadius: Grid.radius, style: .continuous).path(in: body).cgPath

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -Grid.shadowOffset * scale),
        blur: Grid.shadowBlur * scale, color: CGColor(gray: 0, alpha: Grid.shadowOpacity))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: body)
    context.restoreGState()

    guard let image = context.makeImage() else { throw Failure.render }
    return image
}

private func writePNG(_ image: CGImage, to url: URL, dpi: Double) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
        UTType.png.identifier as CFString, 1, nil) else { throw Failure.render }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure.render }
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: render-app-icon <artwork.png> <output-directory>\n".utf8))
    exit(64)
}
let artworkURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height, artwork.width >= Int(Grid.body) else { throw Failure.artwork }

let iconset = output.appendingPathComponent("MyDrive.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
var images: [(CGImage, Double)] = []
for (name, size) in sizes {
    let image = try render(artwork, size: size)
    let dpi = name.contains("@2x") ? 144.0 : 72.0
    try writePNG(image, to: iconset.appendingPathComponent(name + ".png"), dpi: dpi)
    if size == 1024 { try writePNG(image, to: output.appendingPathComponent("MyDrive-1024.png"), dpi: 72) }
    images.append((image, dpi))
}
// Use the system ImageIO ICNS writer directly as well as retaining the standard
// iconset. This has no dependency on iconutil's directory-import environment.
guard let family = CGImageDestinationCreateWithURL(output.appendingPathComponent("MyDrive.icns") as CFURL,
    "com.apple.icns" as CFString, sizes.count, nil) else { throw Failure.render }
for (image, dpi) in images {
    CGImageDestinationAddImage(family, image, [kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
}
guard CGImageDestinationFinalize(family) else { throw Failure.render }
