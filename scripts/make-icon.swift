#!/usr/bin/env swift
// Renders Support/AppIcon.icns: a squircle with the Pulse gradient and a heartbeat line.
// Usage: swift scripts/make-icon.swift [output.icns]

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.icns"

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let context = NSGraphicsContext.current?.cgContext else { return image }

    // Apple's icon grid leaves ~10% transparent margin around the squircle.
    let inset = size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.setFillColor(NSColor.black.cgColor)
    context.addPath(squircle)
    context.fillPath()
    context.restoreGState()

    // Base gradient: indigo → pink → orange, matching the in-app mark.
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let colors = [
        NSColor(red: 0.55, green: 0.49, blue: 1.00, alpha: 1).cgColor,
        NSColor(red: 0.93, green: 0.28, blue: 0.60, alpha: 1).cgColor,
        NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Soft top-left highlight for depth.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.2),
        startRadius: 0,
        endCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.2),
        endRadius: rect.width * 0.8,
        options: []
    )

    // Dark vignette at the bottom so the white line pops.
    let vignette = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.22).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(vignette, start: CGPoint(x: 0, y: rect.midY), end: CGPoint(x: 0, y: rect.minY), options: [])
    context.restoreGState()

    // Heartbeat line.
    let line = CGMutablePath()
    let w = rect.width * 0.62
    let h = rect.height * 0.34
    let origin = CGPoint(x: rect.midX - w / 2, y: rect.midY - h * 0.45)
    let midY = origin.y + h * 0.45
    line.move(to: CGPoint(x: origin.x, y: midY))
    line.addLine(to: CGPoint(x: origin.x + w * 0.22, y: midY))
    line.addLine(to: CGPoint(x: origin.x + w * 0.34, y: origin.y + h * 0.22))
    line.addLine(to: CGPoint(x: origin.x + w * 0.50, y: origin.y + h * 1.0))
    line.addLine(to: CGPoint(x: origin.x + w * 0.64, y: origin.y))
    line.addLine(to: CGPoint(x: origin.x + w * 0.74, y: midY))
    line.addLine(to: CGPoint(x: origin.x + w, y: midY))

    context.saveGState()
    context.setShadow(offset: .zero, blur: size * 0.03, color: NSColor.white.withAlphaComponent(0.6).cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(size * 0.062)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(line)
    context.strokePath()
    context.restoreGState()

    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentPulse-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(draw(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}

let outputURL = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("wrote \(outputURL.path)")
