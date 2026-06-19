import SwiftUI

enum SettingsRoute: Hashable {
    case general
    case mouse
    case module(MonitorKind)
    #if DISPLAY_CONTROL
    case displayModule
    #endif
    case about
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsRoute
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        List(selection: $selection) {
            Section {
                Label(String(localized: "settings.sidebar.general"), systemImage: "gearshape")
                    .tag(SettingsRoute.general)

                Label("鼠标", systemImage: "computermouse")
                    .tag(SettingsRoute.mouse)
            }

            Section(String(localized: "settings.sidebar.modules")) {
                ForEach(MonitorKind.allCases) { kind in
                    Label {
                        Text(kind == .codex ? "Codex" : kind.title)
                            .foregroundStyle(settings.isVisible(kind) ? .primary : .secondary)
                            .strikethrough(!settings.isVisible(kind), color: .secondary)
                    } icon: {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(settings.isVisible(kind) ? .primary : .secondary)
                            .opacity(settings.isVisible(kind) ? 1 : 0.48)
                    }
                        .tag(SettingsRoute.module(kind))
                }

                #if DISPLAY_CONTROL
                Label(String(localized: "settings.sidebar.display"), systemImage: "display")
                    .tag(SettingsRoute.displayModule)
                #endif
            }

            Section {
                Label(String(localized: "settings.sidebar.about"), systemImage: "info.circle")
                    .tag(SettingsRoute.about)
            }
        }
        .listStyle(.sidebar)
        .controlSize(.small)
        .font(.callout)
    }
}
