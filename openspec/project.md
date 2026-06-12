# 番薯Monitor OpenSpec

## Purpose
番薯Monitor 是一款 macOS 菜单栏系统监控与外接显示器控制工具。核心能力包括低开销硬件指标、外接屏亮度控制、系统原生亮度键接管、HiDPI 管理和紧凑 SwiftUI 面板。

第一版以直发版本为主，允许使用非沙盒显示器控制能力；如后续恢复 App Store 目标，必须排除非 App-Store-safe 的显示器控制代码和 UI。

显示器控制应以可用性为先：每台检测到的显示器显示紧凑控制区，亮度、音量、对比度和 HiDPI 按能力启用；不可控时明确显示原因，并让 F1/F2 事件回到系统原生行为。

## Product Direction
- Keep the menu bar minimal: one clear status icon.
- Keep the popover compact: unified hardware metrics and display controls.
- Prioritize readability over raw density.
- Treat CPU, GPU, memory, storage, network, and battery as the core metric set.
- Treat display controls as a Direct-build capability.
- Group display controls by display so multiple external monitors remain understandable.
- Show built-in display controls by default in Direct builds, with a setting to hide built-in displays and show only external displays.
- Keep display-control settings clear and grouped by capability.
- Support system appearance automatically, including light and dark mode.

## Technical Context
- Platform: macOS SwiftUI menu bar app for Apple Silicon Macs only.
- Visual system: SwiftUI Liquid Glass where available.
- Data sources: Mach host stats, filesystem stats, network interfaces, IOKit power sources, IOKit registry/IOAccelerator for GPU.
- Current UI structure: `MenuBarExtra` label, `MonitorPanelView`, `DisplayControlsSection`, `SystemMonitorSampler`.
- Distribution model: one main branch with separate App Store and Direct targets/schemes. Both app targets are arm64-only. The App Store target keeps `ENABLE_APP_SANDBOX = YES` and excludes display-control implementation files. The Direct target disables App Sandbox, uses Developer ID signing and notarization, and compiles display-control code behind build flags such as `DIRECT_DISTRIBUTION` and `DISPLAY_CONTROL`.
- Display control uses native display enumeration, DisplayServices, OSD, and Apple Silicon external display DDC/CI through IOAVService/DCPAVServiceProxy.
- Display-control feasibility: brightness, volume, and contrast are feasible for the Direct build but hardware support varies by monitor, cable, transport, and macOS/Apple Silicon behavior. Unsupported controls should be omitted or disabled per display rather than represented as working sliders.
- App Store constraint: non-sandbox/private display-control paths must not ship in the App Store target. The App Store build should omit display-control UI instead of showing controls that cannot function.
