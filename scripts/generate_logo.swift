import AppKit
import Foundation

struct LogoRenderer {
    let size: CGFloat
    let scale: CGFloat

    private var rect: CGRect {
        CGRect(x: 0, y: 0, width: size, height: size)
    }

    func render(to url: URL, transparent: Bool = false) throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size * scale),
            pixelsHigh: Int(size * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

        draw(transparent: transparent)

        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private func draw(transparent: Bool) {
        NSColor.clear.setFill()
        rect.fill()

        let iconRect = rect.insetBy(dx: size * 0.055, dy: size * 0.055)
        let corner = size * 0.215
        let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: corner, yRadius: corner)

        if !transparent {
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
            shadow.shadowBlurRadius = size * 0.07
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
            shadow.set()
        }

        NSGradient(colors: [
            NSColor(calibratedRed: 0.025, green: 0.09, blue: 0.13, alpha: 1),
            NSColor(calibratedRed: 0.02, green: 0.25, blue: 0.29, alpha: 1),
            NSColor(calibratedRed: 0.035, green: 0.13, blue: 0.18, alpha: 1)
        ])!.draw(in: iconPath, angle: 135)

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        NSColor.white.withAlphaComponent(0.16).setStroke()
        iconPath.lineWidth = size * 0.008
        iconPath.stroke()

        drawSoftGlow()
        drawMonitorOutline()
        drawSweetPotato()
        drawPulseRing()
        drawBottomSpark()
    }

    private func drawSoftGlow() {
        let glowRect = CGRect(x: size * 0.18, y: size * 0.2, width: size * 0.64, height: size * 0.64)
        let glow = NSBezierPath(ovalIn: glowRect)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.95, blue: 0.76, alpha: 0.24),
            NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.92, alpha: 0.04),
            NSColor.clear
        ])!.draw(in: glow, relativeCenterPosition: NSPoint(x: -0.18, y: 0.22))
    }

    private func drawMonitorOutline() {
        let monitor = CGRect(x: size * 0.22, y: size * 0.30, width: size * 0.56, height: size * 0.39)
        let path = NSBezierPath(roundedRect: monitor, xRadius: size * 0.055, yRadius: size * 0.055)

        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = size * 0.018
        shadow.shadowColor = NSColor(calibratedRed: 0.20, green: 0.78, blue: 1, alpha: 0.33)
        shadow.set()

        NSColor(calibratedRed: 0.36, green: 0.72, blue: 1, alpha: 0.96).setStroke()
        path.lineWidth = size * 0.034
        path.stroke()

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        let base = NSBezierPath()
        base.move(to: NSPoint(x: size * 0.43, y: size * 0.245))
        base.line(to: NSPoint(x: size * 0.57, y: size * 0.245))
        base.move(to: NSPoint(x: size * 0.50, y: size * 0.30))
        base.line(to: NSPoint(x: size * 0.50, y: size * 0.245))
        base.lineCapStyle = .round
        base.lineWidth = size * 0.034
        NSColor(calibratedRed: 0.36, green: 0.72, blue: 1, alpha: 0.90).setStroke()
        base.stroke()
    }

    private func drawSweetPotato() {
        let potato = NSBezierPath()
        potato.move(to: NSPoint(x: size * 0.37, y: size * 0.43))
        potato.curve(
            to: NSPoint(x: size * 0.61, y: size * 0.65),
            controlPoint1: NSPoint(x: size * 0.32, y: size * 0.56),
            controlPoint2: NSPoint(x: size * 0.47, y: size * 0.71)
        )
        potato.curve(
            to: NSPoint(x: size * 0.66, y: size * 0.37),
            controlPoint1: NSPoint(x: size * 0.76, y: size * 0.58),
            controlPoint2: NSPoint(x: size * 0.78, y: size * 0.42)
        )
        potato.curve(
            to: NSPoint(x: size * 0.37, y: size * 0.43),
            controlPoint1: NSPoint(x: size * 0.55, y: size * 0.28),
            controlPoint2: NSPoint(x: size * 0.42, y: size * 0.31)
        )
        potato.close()

        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.014)
        shadow.shadowBlurRadius = size * 0.035
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.set()

        NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.30, alpha: 1),
            NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.39, alpha: 1),
            NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.55, alpha: 1)
        ])!.draw(in: potato, angle: 35)

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: size * 0.45, y: size * 0.55))
        highlight.curve(
            to: NSPoint(x: size * 0.58, y: size * 0.59),
            controlPoint1: NSPoint(x: size * 0.49, y: size * 0.62),
            controlPoint2: NSPoint(x: size * 0.55, y: size * 0.63)
        )
        highlight.lineCapStyle = .round
        highlight.lineWidth = size * 0.022
        NSColor.white.withAlphaComponent(0.42).setStroke()
        highlight.stroke()
    }

    private func drawPulseRing() {
        let ringRect = CGRect(x: size * 0.225, y: size * 0.205, width: size * 0.55, height: size * 0.55)
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY),
            radius: ringRect.width * 0.5,
            startAngle: 214,
            endAngle: 506,
            clockwise: false
        )
        ring.lineWidth = size * 0.042
        ring.lineCapStyle = .round

        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = size * 0.02
        shadow.shadowColor = NSColor(calibratedRed: 0.22, green: 1.0, blue: 0.72, alpha: 0.36)
        shadow.set()

        NSColor(calibratedRed: 0.18, green: 0.94, blue: 0.68, alpha: 0.96).setStroke()
        ring.stroke()

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        let dot = NSBezierPath(ovalIn: CGRect(x: size * 0.690, y: size * 0.674, width: size * 0.060, height: size * 0.060))
        NSColor(calibratedRed: 0.58, green: 1.0, blue: 0.76, alpha: 1).setFill()
        dot.fill()
    }

    private func drawBottomSpark() {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: size * 0.34, y: size * 0.186))
        line.line(to: NSPoint(x: size * 0.66, y: size * 0.186))
        line.lineCapStyle = .round
        line.lineWidth = size * 0.018
        NSColor.white.withAlphaComponent(0.20).setStroke()
        line.stroke()
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconDir = root.appendingPathComponent("FanshuMonitor/Assets.xcassets/AppIcon.appiconset")
let docsDir = root.appendingPathComponent("docs/images")

let outputs: [(String, CGFloat, CGFloat, Bool)] = [
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16.png", 16, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png", 32, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32.png", 32, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png", 64, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128.png", 128, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png", 256, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png", 256, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png", 512, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512.png", 512, 1, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", 1024, 1, false),
    ("docs/images/icon-128.png", 128, 1, false),
    ("docs/images/icon.png", 1254, 1, false),
    ("docs/images/logo.png", 1254, 1, true)
]

for output in outputs {
    let path = root.appendingPathComponent(output.0)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try LogoRenderer(size: output.1, scale: output.2).render(to: path, transparent: output.3)
}

print("Generated \(outputs.count) logo assets")
