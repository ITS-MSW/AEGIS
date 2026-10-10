import AppKit
import SwiftUI

enum DictationPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case inserting
    case inserted
    case pasteUnverified
    case transcriptReady
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .requestingPermission:
            return "Preparing microphone…"
        case .recording:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .inserting:
            return "Inserting text…"
        case .pasteUnverified:
            return "Check pasted text"
        case .transcriptReady:
            return "Copied to clipboard"
        case .inserted:
            return "Text inserted"
        case .failed:
            return "Dictation stopped"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .requestingPermission, .recording:
            return "mic.fill"
        case .transcribing, .inserting:
            return "waveform"
        case .pasteUnverified, .transcriptReady:
            return "doc.on.clipboard"
        case .inserted:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }

    var accent: Color {
        switch self {
        case .recording:
            return Color(red: 0.77, green: 0.45, blue: 1)
        case .inserted:
            return Color(red: 0.35, green: 0.86, blue: 0.64)
        case .failed:
            return Color(red: 1, green: 0.42, blue: 0.45)
        default:
            return Color(red: 0.63, green: 0.42, blue: 1)
        }
    }

    var detail: String? {
        if case .pasteUnverified = self { return "Transcript saved in Settings" }
        if case .transcriptReady = self { return "Check the field before pasting" }
        if case .failed(let message) = self { return message }
        if case .requestingPermission = self { return "Allow microphone access if prompted" }
        return nil
    }
}

@MainActor
final class DictationNotchModel: ObservableObject {
    @Published var stopHint = "Release Shift"
    var title: String { phase.title }
    @Published var recordingStartedAt: Date?
    @Published var phase: DictationPhase = .idle {
        didSet { if phase == .recording, oldValue != .recording { recordingStartedAt = Date() } }
    }
    @Published var level: Double = 0
}

struct DictationNotchView: View {
    @ObservedObject var model: DictationNotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                waveform(mirrored: false)
                ZStack {
                    Circle().fill(model.phase.accent.opacity(0.12))
                    Circle().stroke(
                        LinearGradient(colors: [Color(red: 0.85, green: 0.53, blue: 1), Color(red: 0.57, green: 0.17, blue: 1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
                        .shadow(color: model.phase.accent.opacity(0.55), radius: 10)
                    Image(systemName: model.phase.symbol)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating,
                            isActive: (model.phase == .transcribing || model.phase == .inserting) && !reduceMotion)
                }
                .frame(width: 68, height: 68)
                waveform(mirrored: true)
            }
            Text(model.phase == .recording ? "Recording…" : model.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            if model.phase == .recording, let start = model.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .monospacedDigit()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.67, green: 0.57, blue: 0.84))
            } else {
                Text(model.phase.detail ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 28)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, ScreenDetector.notchHeight / 0.7 + 15)
        .frame(width: 420, height: ScreenDetector.notchHeight / 0.7 + 170)
        .background {
            ZStack {
                Color.black
                RadialGradient(colors: [model.phase.accent.opacity(0.18), .clear],
                    center: .center, startRadius: 12, endRadius: 170)
            }
        }
        .clipShape(NotchShape(cornerRadius: 42))
        .scaleEffect(0.7, anchor: .top)
        .frame(width: 294, height: ScreenDetector.notchHeight + 119, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityHint(model.phase == .recording ? model.stopHint : "")
    }

    private func waveform(mirrored: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<6) { index in
                let position = mirrored ? 5 - index : index
                let profile: [CGFloat] = [8, 12, 22, 38, 22, 16]
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.57, blue: 1), model.phase.accent],
                        startPoint: .top, endPoint: .bottom))
                    .opacity(model.phase == .recording ? 0.45 + model.level * 0.55 : 0.25)
                    .frame(width: 4, height: model.phase == .recording ? 5 + profile[position] * model.level : 5)
            }
        }
        .frame(width: 49, height: 44)
        .shadow(color: model.phase.accent.opacity(0.4), radius: 7)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: model.level)
        .accessibilityHidden(true)
    }
}

@MainActor
final class DictationNotchWindowController: NSWindowController {
    init(model: DictationNotchModel) {
        let frame = NSRect(x: 0, y: 0, width: 294,
            height: ScreenDetector.notchHeight + 119)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: 28)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        let container = NSView(frame: frame)
        let hosting = NSHostingView(rootView: DictationNotchView(model: model))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        let screen = ScreenDetector.notchScreen
        let x = screen.frame.midX - window.frame.width / 2
        let y = screen.frame.maxY - window.frame.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
    }
}
