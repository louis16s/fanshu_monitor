import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var mouseController: MouseControlController
    @ObservedObject var lockScreenController: LockScreenPolicyController
    @State private var selection: SettingsRoute = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, settings: settings)
                .frame(width: SettingsWindowMetrics.sidebarWidth)
                .background(.bar)

            Divider()

            detailView
                .frame(
                    width: SettingsWindowMetrics.width - SettingsWindowMetrics.sidebarWidth - 1,
                    height: SettingsWindowMetrics.height
                )
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
        .fixedSize()
        .background(SettingsWindowTracker(selection: $selection))
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralSettingsView(settings: settings)
        case .lockScreen:
            LockScreenSettingsView(settings: settings, controller: lockScreenController)
        case .mouse:
            MouseSettingsView(settings: settings, controller: mouseController)
        case .module(let kind):
            ModuleSettingsView(kind: kind, settings: settings)
        #if DISPLAY_CONTROL
        case .displayModule:
            DisplayModuleSettingsView(settings: settings)
        #endif
        case .about:
            AboutSettingsView(settings: settings)
        }
    }
}

struct SettingsWindowTracker: NSViewRepresentable {
    @Binding var selection: SettingsRoute

    func makeNSView(context: Context) -> NSView {
        SettingsWindowTrackingView(frame: .zero) { tab in
            Task { @MainActor in
                if let route = tab.route {
                    selection = route
                }
            }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Task { @MainActor in
            window.setStableSettingsSize()
            SettingsWindowPresenter.register(window)
        }

        if let view = nsView as? SettingsWindowTrackingView {
            view.onTabChanged = { tab in
                Task { @MainActor in
                    if let route = tab.route {
                        selection = route
                    }
                }
            }
        }
    }
}

private final class SettingsWindowTrackingView: NSView {
    var onTabChanged: ((SettingsTab) -> Void)?
    private var observer: NSObjectProtocol?

    init(frame frameRect: NSRect, onTabChanged: @escaping (SettingsTab) -> Void) {
        self.onTabChanged = onTabChanged
        super.init(frame: frameRect)

        observer = NotificationCenter.default.addObserver(
            forName: SettingsWindowPresenter.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let tabValue = note.userInfo?[SettingsWindowPresenter.tabUserInfoKey] as? String,
                  let tab = SettingsTab(rawValue: tabValue) else { return }
            self?.onTabChanged?(tab)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else {
            return
        }

        Task { @MainActor in
            window.setStableSettingsSize()
            SettingsWindowPresenter.register(window)
        }
    }
}

private extension NSWindow {
    func setStableSettingsSize() {
        let size = SettingsWindowMetrics.contentSize
        contentMinSize = size
        contentMaxSize = size
        guard abs(contentView?.frame.width ?? 0 - size.width) > 0.5 ||
              abs(contentView?.frame.height ?? 0 - size.height) > 0.5 else {
            return
        }
        setContentSize(size)
    }
}

extension SettingsTab {
    var route: SettingsRoute? {
        switch self {
        case .general:
            return .general
        case .lockScreen:
            return .lockScreen
        case .mouse:
            return .mouse
        case .modules:
            return nil
        case .about:
            return .about
        }
    }
}
