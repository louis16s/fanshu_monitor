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

struct PanelWindowVisibilityTracker: NSViewRepresentable {
    let onVisibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        PanelWindowVisibilityTrackingView(onVisibilityChanged: onVisibilityChanged)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let trackingView = nsView as? PanelWindowVisibilityTrackingView else {
            return
        }
        trackingView.onVisibilityChanged = onVisibilityChanged
        trackingView.reportCurrentVisibility()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? PanelWindowVisibilityTrackingView)?.stopTracking(reportHidden: true)
    }
}

@MainActor
private final class PanelWindowVisibilityTrackingView: NSView {
    var onVisibilityChanged: (Bool) -> Void
    private weak var trackedWindow: NSWindow?
    private var visibilityObservation: NSKeyValueObservation?
    private var lastReportedVisibility: Bool?
    private var reportTask: Task<Void, Never>?

    init(onVisibilityChanged: @escaping (Bool) -> Void) {
        self.onVisibilityChanged = onVisibilityChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard trackedWindow !== window else {
            reportCurrentVisibility()
            return
        }

        stopTracking(reportHidden: false)
        trackedWindow = window
        guard let window else {
            report(visible: false)
            return
        }

        let tracker = WeakPanelWindowVisibilityTracker(self)
        visibilityObservation = window.observe(\.isVisible, options: [.initial, .new]) { _, change in
            Task { @MainActor in
                await Task.yield()
                tracker.value?.scheduleReport(visible: change.newValue == true)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidOrderOffScreen(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    func reportCurrentVisibility() {
        scheduleReport(visible: trackedWindow?.isVisible == true)
    }

    func stopTracking(reportHidden: Bool) {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let trackedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: trackedWindow
            )
        }
        trackedWindow = nil
        if reportHidden {
            scheduleReport(visible: false)
        }
    }

    @objc private func windowDidOrderOffScreen(_ notification: Notification) {
        scheduleReport(visible: false)
    }

    private func scheduleReport(visible: Bool) {
        reportTask?.cancel()
        reportTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.report(visible: visible)
        }
    }

    private func report(visible: Bool) {
        guard lastReportedVisibility != visible else { return }
        lastReportedVisibility = visible
        onVisibilityChanged(visible)
    }
}

nonisolated private final class WeakPanelWindowVisibilityTracker: @unchecked Sendable {
    weak var value: PanelWindowVisibilityTrackingView?

    init(_ value: PanelWindowVisibilityTrackingView) {
        self.value = value
    }
}

private final class TransparentBackgroundView: NSView {
    private weak var configuredWindow: NSWindow?
    private var appliedAppearanceName: NSAppearance.Name?
    private var currentColorSchemeOverride: ColorScheme?
    private var applyTask: Task<Void, Never>?

    deinit {
        applyTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        scheduleApply()
    }

    func apply(colorSchemeOverride: ColorScheme?) {
        currentColorSchemeOverride = colorSchemeOverride
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let window = self.window else { return }
            self.configure(window)
            self.applyAppearance(to: window)
        }
    }

    private func applyAppearance(to window: NSWindow) {
        guard let currentColorSchemeOverride else {
            guard appliedAppearanceName != nil else { return }
            appliedAppearanceName = nil
            window.appearance = nil
            window.contentView?.appearance = nil
            return
        }

        let appearanceName: NSAppearance.Name = currentColorSchemeOverride == .dark ? .darkAqua : .aqua
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
