import SwiftUI

struct MonitorPalette {
    let preference: MonitorColorSchemePreference
    let colorScheme: ColorScheme

    private var isDark: Bool {
        colorScheme == .dark
    }

    var primaryText: Color {
        isDark ? Color.white.opacity(0.96) : Color(hex: 0x171D2A)
    }

    var valueText: Color {
        isDark ? Color.white.opacity(0.90) : Color(hex: 0x2F3747)
    }

    var secondaryText: Color {
        isDark ? Color.white.opacity(0.82) : Color(hex: 0x465164)
    }

    var captionText: Color {
        isDark ? Color.white.opacity(0.68) : Color(hex: 0x5A6475)
    }

    var trackFill: Color {
        isDark ? Color.white.opacity(0.08) : Color(hex: 0x3C485A).opacity(0.08)
    }

    func liveDot(for loadLevel: MenuBarComputeLoadLevel) -> Color {
        Color(nsColor: loadLevel.coreColor(darkMode: isDark))
    }

    var displayTint: Color {
        switch preference {
        case .systemBlue:
            Color(hex: 0x4E7FD9)
        case .graphite:
            Color(hex: 0x64748B)
        case .teal:
            Color(hex: 0x14B8A6)
        case .rose:
            Color(hex: 0xD7547F)
        }
    }

    func moduleTint(for kind: MonitorKind) -> Color {
        switch preference {
        case .systemBlue:
            systemBlueModuleTint(for: kind)
        case .graphite:
            graphiteModuleTint(for: kind)
        case .teal:
            tealModuleTint(for: kind)
        case .rose:
            roseModuleTint(for: kind)
        }
    }

    func severityTint(for severity: MonitorSeverity) -> Color {
        switch severity {
        case .calm:
            Color(hex: 0x2F9E64)
        case .warning:
            Color(hex: 0xB8872E)
        case .critical:
            Color(hex: 0xD94848)
        }
    }

    func rowGlassTint(for kind: MonitorKind) -> Color {
        switch preference {
        case .systemBlue, .graphite:
            neutralGlassTint
        case .teal, .rose:
            moduleTint(for: kind).opacity(isDark ? 0.16 : 0.08)
        }
    }

    func rowSeparator(for kind: MonitorKind) -> Color {
        switch preference {
        case .systemBlue, .graphite:
            neutralSeparator
        case .teal, .rose:
            moduleTint(for: kind).opacity(isDark ? 0.28 : 0.18)
        }
    }

    var displayGlassTint: Color {
        switch preference {
        case .systemBlue, .graphite:
            neutralGlassTint
        case .teal, .rose:
            displayTint.opacity(isDark ? 0.16 : 0.08)
        }
    }

    var displaySeparator: Color {
        switch preference {
        case .systemBlue, .graphite:
            neutralSeparator
        case .teal, .rose:
            displayTint.opacity(isDark ? 0.28 : 0.18)
        }
    }

    var displayBadgeFill: Color {
        switch preference {
        case .systemBlue, .graphite:
            Color(hex: 0x7A91B4).opacity(isDark ? 0.16 : 0.10)
        case .teal, .rose:
            displayTint.opacity(isDark ? 0.18 : 0.10)
        }
    }

    func badgeFill(for kind: MonitorKind) -> Color {
        switch preference {
        case .systemBlue, .graphite:
            moduleTint(for: kind).opacity(isDark ? 0.18 : 0.10)
        case .teal, .rose:
            moduleTint(for: kind).opacity(isDark ? 0.20 : 0.12)
        }
    }

    private var neutralGlassTint: Color {
        Color(hex: 0x7A91B4).opacity(isDark ? 0.12 : 0.06)
    }

    private var neutralSeparator: Color {
        Color(hex: 0x7A91B4).opacity(isDark ? 0.22 : 0.14)
    }

    private func systemBlueModuleTint(for kind: MonitorKind) -> Color {
        switch kind {
        case .cpu:
            Color(hex: 0xD27A4A)
        case .gpu:
            Color(hex: 0x5D8CF0)
        case .memory:
            Color(hex: 0x42A39A)
        case .storage:
            Color(hex: 0x9A865E)
        case .network:
            Color(hex: 0x43A6A0)
        case .battery:
            Color(hex: 0x65AF52)
        case .codex:
            Color(hex: 0x0A84FF)
        }
    }

    private func graphiteModuleTint(for kind: MonitorKind) -> Color {
        switch kind {
        case .cpu:
            Color(hex: 0xC2410C)
        case .gpu:
            Color(hex: 0x475569)
        case .memory:
            Color(hex: 0x0F766E)
        case .storage:
            Color(hex: 0xA16207)
        case .network:
            Color(hex: 0x0369A1)
        case .battery:
            Color(hex: 0x4D7C0F)
        case .codex:
            Color(hex: 0x7C3AED)
        }
    }

    private func tealModuleTint(for kind: MonitorKind) -> Color {
        switch kind {
        case .cpu:
            Color(hex: 0xEA580C)
        case .gpu:
            Color(hex: 0x0EA5E9)
        case .memory:
            Color(hex: 0x10B981)
        case .storage:
            Color(hex: 0xD97706)
        case .network:
            Color(hex: 0x6366F1)
        case .battery:
            Color(hex: 0x65A30D)
        case .codex:
            Color(hex: 0x06B6D4)
        }
    }

    private func roseModuleTint(for kind: MonitorKind) -> Color {
        switch kind {
        case .cpu:
            Color(hex: 0xE11D48)
        case .gpu:
            Color(hex: 0x7C3AED)
        case .memory:
            Color(hex: 0x0891B2)
        case .storage:
            Color(hex: 0xD97706)
        case .network:
            Color(hex: 0x2563EB)
        case .battery:
            Color(hex: 0x16A34A)
        case .codex:
            Color(hex: 0xDB2777)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
