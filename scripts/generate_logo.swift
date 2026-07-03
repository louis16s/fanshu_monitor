import AppKit
import Foundation

struct LogoRenderer {
    let size: CGFloat

    private var rect: CGRect {
        CGRect(x: 0, y: 0, width: size, height: size)
    }

    func render(to url: URL, transparent: Bool = false) throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
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
        let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: size * 0.225, yRadius: size * 0.225)

        if !transparent {
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
            shadow.shadowBlurRadius = size * 0.055
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow.set()
        }

        NSGradient(colors: [
            NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.085, alpha: 1),
            NSColor(calibratedRed: 0.040, green: 0.205, blue: 0.220, alpha: 1),
            NSColor(calibratedRed: 0.025, green: 0.120, blue: 0.155, alpha: 1)
        ])!.draw(in: iconPath, angle: 135)

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        NSColor.white.withAlphaComponent(0.12).setStroke()
        iconPath.lineWidth = max(size * 0.006, 1)
        iconPath.stroke()

        drawGlow()
        drawPotato()
        drawSignalLine()
        drawBrightnessDot()
    }

    private func drawGlow() {
        let glow = NSBezierPath(ovalIn: CGRect(x: size * 0.20, y: size * 0.18, width: size * 0.64, height: size * 0.66))
        NSGradient(colors: [
            NSColor(calibratedRed: 0.19, green: 0.93, blue: 0.70, alpha: 0.22),
            NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.92, alpha: 0.04),
            NSColor.clear
        ])!.draw(in: glow, relativeCenterPosition: NSPoint(x: -0.18, y: 0.20))
    }

    private func drawPotato() {
        let potato = NSBezierPath()
        potato.move(to: NSPoint(x: size * 0.275, y: size * 0.430))
        potato.curve(
            to: NSPoint(x: size * 0.510, y: size * 0.745),
            controlPoint1: NSPoint(x: size * 0.260, y: size * 0.585),
            controlPoint2: NSPoint(x: size * 0.350, y: size * 0.735)
        )
        potato.curve(
            to: NSPoint(x: size * 0.770, y: size * 0.560),
            controlPoint1: NSPoint(x: size * 0.680, y: size * 0.755),
            controlPoint2: NSPoint(x: size * 0.790, y: size * 0.685)
        )
        potato.curve(
            to: NSPoint(x: size * 0.575, y: size * 0.255),
            controlPoint1: NSPoint(x: size * 0.750, y: size * 0.410),
            controlPoint2: NSPoint(x: size * 0.675, y: size * 0.285)
        )
        potato.curve(
            to: NSPoint(x: size * 0.275, y: size * 0.430),
            controlPoint1: NSPoint(x: size * 0.415, y: size * 0.205),
            controlPoint2: NSPoint(x: size * 0.285, y: size * 0.285)
        )
        potato.close()

        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
        shadow.shadowBlurRadius = size * 0.050
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
        shadow.set()

        NSGradient(colors: [
            NSColor(calibratedRed: 1.000, green: 0.620, blue: 0.275, alpha: 1),
            NSColor(calibratedRed: 0.965, green: 0.345, blue: 0.430, alpha: 1),
            NSColor(calibratedRed: 0.610, green: 0.305, blue: 0.735, alpha: 1)
        ])!.draw(in: potato, angle: 36)

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: size * 0.405, y: size * 0.575))
        highlight.curve(
            to: NSPoint(x: size * 0.540, y: size * 0.635),
            controlPoint1: NSPoint(x: size * 0.445, y: size * 0.675),
            controlPoint2: NSPoint(x: size * 0.520, y: size * 0.680)
        )
        highlight.lineCapStyle = .round
        highlight.lineWidth = max(size * 0.032, 2)
        NSColor.white.withAlphaComponent(0.44).setStroke()
        highlight.stroke()
    }

    private func drawSignalLine() {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: size * 0.260, y: size * 0.374))
        line.line(to: NSPoint(x: size * 0.395, y: size * 0.374))
        line.curve(
            to: NSPoint(x: size * 0.475, y: size * 0.470),
            controlPoint1: NSPoint(x: size * 0.430, y: size * 0.374),
            controlPoint2: NSPoint(x: size * 0.435, y: size * 0.470)
        )
        line.line(to: NSPoint(x: size * 0.610, y: size * 0.470))
        line.curve(
            to: NSPoint(x: size * 0.692, y: size * 0.552),
            controlPoint1: NSPoint(x: size * 0.645, y: size * 0.470),
            controlPoint2: NSPoint(x: size * 0.655, y: size * 0.552)
        )
        line.line(to: NSPoint(x: size * 0.772, y: size * 0.552))
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.lineWidth = max(size * 0.034, 2)

        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = size * 0.022
        shadow.shadowColor = NSColor(calibratedRed: 0.15, green: 1.0, blue: 0.78, alpha: 0.55)
        shadow.set()

        NSColor(calibratedRed: 0.18, green: 0.92, blue: 0.70, alpha: 0.98).setStroke()
        line.stroke()

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func drawBrightnessDot() {
        let center = NSPoint(x: size * 0.722, y: size * 0.705)
        let radius = max(size * 0.038, 2)
        let dot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = size * 0.026
        shadow.shadowColor = NSColor(calibratedRed: 0.64, green: 1.0, blue: 0.74, alpha: 0.55)
        shadow.set()

        NSColor(calibratedRed: 0.74, green: 1.0, blue: 0.72, alpha: 1).setFill()
        dot.fill()

        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        let rayLength = size * 0.058
        let rayGap = size * 0.018
        let rays = NSBezierPath()
        for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
            let rad = CGFloat(angle * .pi / 180)
            let start = NSPoint(x: center.x + cos(rad) * (radius + rayGap), y: center.y + sin(rad) * (radius + rayGap))
            let end = NSPoint(x: center.x + cos(rad) * (radius + rayGap + rayLength), y: center.y + sin(rad) * (radius + rayGap + rayLength))
            rays.move(to: start)
            rays.line(to: end)
        }
        rays.lineWidth = max(size * 0.012, 1)
        rays.lineCapStyle = .round
        NSColor(calibratedRed: 0.74, green: 1.0, blue: 0.72, alpha: 0.44).setStroke()
        rays.stroke()
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputs: [(String, CGFloat, Bool)] = [
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16.png", 16, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png", 32, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32.png", 32, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png", 64, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128.png", 128, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png", 256, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png", 256, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png", 512, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512.png", 512, false),
    ("FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", 1024, false),
    ("docs/images/icon-128.png", 128, false),
    ("docs/images/icon.png", 1254, false),
    ("docs/images/logo.png", 1254, true)
]

for output in outputs {
    let path = root.appendingPathComponent(output.0)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try LogoRenderer(size: output.1).render(to: path, transparent: output.2)
}

print("Generated \(outputs.count) logo assets")
