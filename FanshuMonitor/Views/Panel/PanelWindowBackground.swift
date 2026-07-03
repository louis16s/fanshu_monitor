import AppKit
import SwiftUI

struct TransparentWindowBackground: NSViewRepresentable {
    let colorSchemeOverride: ColorScheme?

    func makeNSView(context: Context) -> NSView {
        let nsView = TransparentBackgroundView()
        nsView.apply(colorSchemeOverride: colorSchemeOverride)
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let nsView = nsView as? TransparentBackgroundView else {
            return
        }

        nsView.apply(colorSchemeOverride: colorSchemeOverride)
    }
}

private final class TransparentBackgroundView: NSView {
    private weak var configuredWindow: NSWindow?
    private var appliedAppearanceName: NSAppearance.Name?
    private var currentColorSchemeOverride: ColorScheme?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        configure(window)

        apply(colorSchemeOverride: currentColorSchemeOverride)
    }

    func apply(colorSchemeOverride: ColorScheme?) {
        currentColorSchemeOverride = colorSchemeOverride

        guard let window else { return }
        configure(window)

        guard let colorSchemeOverride else {
            guard appliedAppearanceName != nil else { return }
            appliedAppearanceName = nil
            window.appearance = nil
            window.contentView?.appearance = nil
            return
        }

        let appearanceName: NSAppearance.Name = colorSchemeOverride == .dark ? .darkAqua : .aqua
        guard appliedAppearanceName != appearanceName else { return }

        appliedAppearanceName = appearanceName
        let appearance = NSAppearance(named: appearanceName)
        window.appearance = appearance
        window.contentView?.appearance = appearance
    }

    private func configure(_ window: NSWindow) {
        guard configuredWindow !== window else { return }
        configuredWindow = window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor

        var parent = superview
        while let current = parent {
            current.wantsLayer = true
            current.layer?.backgroundColor = NSColor.clear.cgColor
            parent = current.superview
        }
    }
}
