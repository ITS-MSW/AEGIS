import AppKit
import SwiftUI

enum DictationPhase: Equatable {
    case idle, preparing, recording, transcribing, copied
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Starting microphone…"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing…"
        case .copied: return "Copied to clipboard"
        case .failed(let message): return message
        }
    }
}

@MainActor
final class DictationCapsuleModel: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var levels = [Double](repeating: 0, count: 13)
    @Published var held = false
    @Published var recoveryText: String?
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}
    var onCopy: () -> Void = {}

    func appendLevel(_ value: Double) {
        let previous = levels.last ?? 0
        let smoothed = previous + (value - previous) * (value > previous ? 0.8 : 0.35)
        levels = Array(levels.dropFirst()) + [smoothed]
    }
}

struct DictationCapsuleView: View {
    @ObservedObject var model: DictationCapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if case .failed(let message) = model.phase {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        control("Dismiss", symbol: "xmark", action: model.onCancel)
                    }
                    if let text = model.recoveryText {
                        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 110)
                        Button("Copy text", action: model.onCopy)
                    }
                }
                .padding(14)
            } else {
                HStack(spacing: 6) {
                    if model.phase == .copied {
                        Image(systemName: "checkmark")
                        Text(model.phase.title)
                    } else {
                        control("Cancel dictation", symbol: "xmark", action: model.onCancel)
                        if model.phase == .recording {
                            HStack(spacing: 2.5) {
                                ForEach(model.levels.indices, id: \.self) { index in
                                    Capsule().fill(.white.opacity(0.35 + Double(index) / 20))
                                        .frame(width: 2.5, height: 3 + model.levels[index] * 20)
                                }
                            }
                            .frame(width: 63, height: 24)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: model.levels)
                            .accessibilityLabel("Listening")
                            .accessibilityElement(children: .ignore)
                            if !model.held { control("Finish dictation", symbol: "checkmark", action: model.onFinish) }
                        } else {
                            ProgressView().controlSize(.small).frame(width: 30)
                                .accessibilityLabel(model.phase.title)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.12)) }
            else { RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 20))) }
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(contrast == .increased ? 0.8 : 0.18), lineWidth: 1))
        .padding(4)
        .preferredColorScheme(.dark)
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

private final class DictationPanel: NSPanel {
    var allowsFocus = false
    override var canBecomeKey: Bool { allowsFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DictationCapsuleWindowController: NSWindowController {
    private let model: DictationCapsuleModel
    private let hosting: NSHostingView<DictationCapsuleView>
    private var screen: NSScreen?

    init(model: DictationCapsuleModel) {
        self.model = model
        hosting = NSHostingView(rootView: DictationCapsuleView(model: model))
        hosting.sizingOptions = []
        let panel = DictationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        super.init(window: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        reposition()
        window.orderFrontRegardless()
        NSAccessibility.post(element: hosting, notification: .announcementRequested, userInfo: [
            .announcement: model.phase.title,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    @objc private func reposition() {
        guard let panel = window as? DictationPanel else { return }
        let activeScreen = NSScreen.screens.first { $0 == screen } ?? NSScreen.main
        guard let frame = activeScreen?.visibleFrame else { return }
        let size: NSSize
        if case .failed = model.phase {
            size = NSSize(width: min(360, frame.width - 24), height: model.recoveryText == nil ? 112 : 244)
        } else {
            let width: CGFloat = model.phase == .copied ? 208 : (model.phase == .recording ? (model.held ? 128 : 168) : 96)
            size = NSSize(width: width, height: 48)
        }
        panel.allowsFocus = model.recoveryText != nil
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 12, width: size.width, height: size.height), display: true)
    }

    func dismiss() { window?.orderOut(nil) }
}
