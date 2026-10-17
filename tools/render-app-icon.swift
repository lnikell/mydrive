import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original MyDrive geometry. This file is the editable vector source; the SVG
// and PNGs are generated from the same drawing commands, without external art.
private struct Color {
    let hex: String
    let alpha: Double
    init(_ hex: String, _ alpha: Double = 1) { self.hex = hex; self.alpha = alpha }
    var cg: CGColor {
        let value = UInt32(hex, radix: 16)!
        return CGColor(red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
}

private final class Drawing {
    let context: CGContext
    private(set) var svg: [String] = []
    private var gradientID = 0

    init(size: Int) throws {
        guard let context = CGContext(data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.render }
        self.context = context
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><defs><filter id=\"shadow\" x=\"-30%\" y=\"-30%\" width=\"160%\" height=\"170%\"><feDropShadow dx=\"0\" dy=\"14\" stdDeviation=\"14\" flood-color=\"#102D44\" flood-opacity=\"0.20\"/></filter></defs>")
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double,
              _ color: Color, end: Color? = nil, shadow: Bool = false) {
        let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: r, cornerHeight: r, transform: nil)
        context.saveGState()
        if shadow { context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: Color("102D44", 0.20).cg) }
        context.addPath(path); context.setFillColor(color.cg); context.fillPath()
        context.restoreGState()
        var fill = "#" + color.hex
        if let end {
            gradientID += 1
            let identifier = "g\(gradientID)"
            svg.append("<defs><linearGradient id=\"\(identifier)\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop stop-color=\"#\(color.hex)\"/><stop offset=\"1\" stop-color=\"#\(end.hex)\"/></linearGradient></defs>")
            fill = "url(#\(identifier))"
            context.saveGState()
            context.addPath(path); context.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [color.cg, end.cg] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: x, y: y),
                end: CGPoint(x: x, y: y + h), options: [])
            context.restoreGState()
        }
        svg.append("<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"\(r)\" fill=\"\(fill)\" fill-opacity=\"\(color.alpha)\"\(shadow ? " filter=\"url(#shadow)\"" : "")/>")
    }

    func outline(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double,
                 _ width: Double, _ color: Color) {
        context.setLineWidth(width); context.setStrokeColor(color.cg)
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: r, cornerHeight: r, transform: nil)); context.strokePath()
        svg.append("<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"\(r)\" fill=\"none\" stroke=\"#\(color.hex)\" stroke-opacity=\"\(color.alpha)\" stroke-width=\"\(width)\"/>")
    }

    func circle(_ x: Double, _ y: Double, _ radius: Double, _ color: Color) {
        context.setFillColor(color.cg)
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        svg.append("<circle cx=\"\(x)\" cy=\"\(y)\" r=\"\(radius)\" fill=\"#\(color.hex)\" fill-opacity=\"\(color.alpha)\"/>")
    }

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
              _ width: Double, _ color: Color) {
        context.setStrokeColor(color.cg); context.setLineWidth(width); context.setLineCap(.round)
        context.move(to: CGPoint(x: x1, y: y1)); context.addLine(to: CGPoint(x: x2, y: y2)); context.strokePath()
        svg.append("<path d=\"M\(x1) \(y1)L\(x2) \(y2)\" fill=\"none\" stroke=\"#\(color.hex)\" stroke-opacity=\"\(color.alpha)\" stroke-width=\"\(width)\" stroke-linecap=\"round\"/>")
    }

    func draw() {
        // The transparent 8% margin keeps the silhouette clear in the Dock.
        rect(82, 82, 860, 860, 190, Color("557F9F"), end: Color("2B516F"), shadow: true)
        outline(84, 84, 856, 856, 188, 2, Color("FFFFFF", 0.25))

        // One simple enclosure with two large bays survives at 16 pixels.
        rect(272, 242, 480, 550, 66, Color("F1F5F7"), end: Color("C9D4DE"), shadow: true)
        outline(273, 243, 478, 548, 65, 2, Color("FFFFFF", 0.7))
        rect(292, 262, 440, 510, 49, Color("DEE6EC"), end: Color("CFDAE2"))
        for x in [320.0, 530.0] {
            rect(x, 298, 174, 345, 26, Color("2D506A"), end: Color("1C384E"))
            outline(x + 1, 299, 172, 343, 25, 2, Color("102B3F", 0.42))
            line(x + 25, 324, x + 149, 324, 2, Color("BBD1DF", 0.16))
            rect(x + 25, 567, 124, 7, 3.5, Color("102B3F", 0.7))
            rect(x + 25, 581, 124, 14, 7, Color("8199AA"))
            circle(x + 87, 620, 6, Color("A0D0BB"))
        }

        // A small three-port link, drawn from basic geometry rather than a glyph.
        line(442, 702, 582, 702, 12, Color("3D627B"))
        line(512, 702, 512, 735, 12, Color("3D627B"))
        rect(428, 688, 28, 28, 7, Color("3D627B"))
        rect(568, 688, 28, 28, 7, Color("3D627B"))
        rect(496, 727, 32, 26, 7, Color("3D627B"))
    }

    func png(to url: URL, dpi: Double = 72) throws {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.render }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.render }
    }
}

private enum Failure: Error { case render }
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-app-icon <output-directory>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("MyDrive.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in sizes {
    let drawing = try Drawing(size: size); drawing.draw()
    try drawing.png(to: iconset.appendingPathComponent(name + ".png"), dpi: name.contains("@2x") ? 144 : 72)
    if size == 1024 {
        try drawing.png(to: output.appendingPathComponent("MyDrive-1024.png"))
        try (drawing.svg.joined(separator: "\n") + "\n</svg>\n")
            .write(to: output.appendingPathComponent("MyDrive.svg"), atomically: true, encoding: .utf8)
    }
    if name == "icon_32x32" { try drawing.png(to: output.appendingPathComponent("MyDrive-32.png")) }
    if name == "icon_16x16" { try drawing.png(to: output.appendingPathComponent("MyDrive-16.png")) }
}
// Use the system ImageIO ICNS writer directly as well as retaining the standard
// iconset. This has no dependency on iconutil's directory-import environment.
guard let family = CGImageDestinationCreateWithURL(output.appendingPathComponent("MyDrive.icns") as CFURL,
    "com.apple.icns" as CFString, sizes.count, nil) else { throw Failure.render }
for (name, _) in sizes {
    guard let source = CGImageSourceCreateWithURL(iconset.appendingPathComponent(name + ".png") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.render }
    let dpi = name.contains("@2x") ? 144.0 : 72.0
    CGImageDestinationAddImage(family, image, [kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
}
guard CGImageDestinationFinalize(family) else { throw Failure.render }
