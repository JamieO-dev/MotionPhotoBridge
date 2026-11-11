#!/usr/bin/env swift
// Draw a vector-based icon directly with AppKit; no external assets or packages.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawIcon() {
    let base = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
                            xRadius: 218, yRadius: 218)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.17, green: 0.14, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.22, blue: 0.81, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.47, blue: 0.91, alpha: 1)
    ])!
    gradient.draw(in: base, angle: 42)

    NSColor.white.withAlphaComponent(0.16).setStroke()
    base.lineWidth = 3
    base.stroke()

    NSGraphicsContext.saveGraphicsState()
    base.addClip()
    let glow = NSGradient(starting: NSColor(srgbRed: 0.55, green: 0.85, blue: 1, alpha: 0.2),
                          ending: NSColor.clear)!
    glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 330, y: 400, width: 850, height: 850)),
              relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 252
    for (start, end) in [(28.0, 190.0), (208.0, 370.0)] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: CGFloat(start), endAngle: CGFloat(end), clockwise: false)
        arc.lineWidth = 43
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.96).setStroke()
        arc.stroke()
    }

    let innerRing = NSBezierPath(ovalIn: NSRect(x: 365, y: 365, width: 294, height: 294))
    innerRing.lineWidth = 24
    NSColor.white.withAlphaComponent(0.76).setStroke()
    innerRing.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 468, y: 468, width: 88, height: 88)).fill()

    // Two small moving points make the paired photo/video idea legible at 16px.
    let accent = NSColor(srgbRed: 0.52, green: 0.96, blue: 0.88, alpha: 1)
    for angle in [19.0, 199.0] {
        let radians = CGFloat(angle * .pi / 180)
        let point = NSPoint(x: center.x + cos(radians) * radius,
                            y: center.y + sin(radians) * radius)
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)).fill()
    }
}

func writeIcon(pixels: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels,
                                        pixelsHigh: pixels,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MotionPhotoBridge.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Couldn't create the icon drawing context."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MotionPhotoBridge.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Couldn't encode an icon PNG."])
    }
    try png.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    try writeIcon(pixels: points, filename: "icon_\(points)x\(points).png")
    try writeIcon(pixels: points * 2, filename: "icon_\(points)x\(points)@2x.png")
}
