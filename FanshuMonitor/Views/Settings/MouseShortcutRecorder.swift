import AppKit
import SwiftUI

struct MouseShortcutRecorderButton: View {
    @Binding var shortcut: MouseKeyboardShortcut?
    let slotTitle: String
    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            Text(shortcut?.displayText ?? "录制")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospaced()
                .frame(minWidth: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("录制\(slotTitle)快捷键")
        .popover(isPresented: $isRecording, arrowEdge: .trailing) {
            VStack(spacing: 12) {
                Text("按下要使用的快捷键")
                    .font(.headline)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.45))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                    Text("正在录制…")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    MouseShortcutCaptureView { recordedShortcut in
                        shortcut = recordedShortcut
                        isRecording = false
                    } cancel: {
                        isRecording = false
                    }
                }
                .frame(width: 210, height: 48)

                HStack {
                    if shortcut != nil {
                        Button("清除") {
                            shortcut = nil
                            isRecording = false
                        }
                    }
                    Spacer()
                    Button("取消") {
                        isRecording = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(14)
            .frame(width: 238)
        }
    }
}

private struct MouseShortcutCaptureView: NSViewRepresentable {
    let record: (MouseKeyboardShortcut) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView(record: record, cancel: cancel)
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.record = record
        nsView.cancel = cancel
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var record: (MouseKeyboardShortcut) -> Void
    var cancel: () -> Void

    init(
        record: @escaping (MouseKeyboardShortcut) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.record = record
        self.cancel = cancel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
            return
        }

        record(MouseKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: Self.shortcutModifiers(from: event.modifierFlags),
            keyLabel: Self.keyLabel(for: event)
        ))
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> MouseShortcutModifiers {
        var modifiers: MouseShortcutModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func keyLabel(for event: NSEvent) -> String {
        if let specialName = specialKeyNames[event.keyCode] {
            return specialName
        }
        let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if let characters, !characters.isEmpty {
            return characters
        }
        return "键\(event.keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "Esc",
        76: "⌤", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
