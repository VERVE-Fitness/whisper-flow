import SwiftUI
import AppKit

/// State the floating status pill renders. Only shown for hotkey/toggle
/// dictations (window-button dictations use the M1 in-window flow instead).
enum PillState: Equatable {
    case listening(partial: String)
    case cleaning
    case inserted
    case copiedOnly
    /// Nothing was typed: the clip was near-silent, too short, or the
    /// decoder's own confidence on the re-checked batch pass was too low to
    /// trust (see AppState.stopRecording's silence/confidence gates).
    case discarded
    /// Something went wrong and nothing was typed. Previously the pill just
    /// vanished on error, which read as "it stalled" -- the reason was only
    /// in the menu bar dropdown nobody opens.
    case failed(String)
    /// A meeting is being recorded; the pill shows elapsed time and is the
    /// Stop button. Orange, not the dictation red, so nobody confuses a
    /// meeting that runs for an hour with a dictation that runs for ten
    /// seconds -- and so nobody assumes Right Option will stop it.
    case meeting(elapsed: Double)
    /// Post-meeting work: transcribing, separating speakers, uploading,
    /// waiting on the summary. The payload is whatever the transcriber or the
    /// uploader last reported, including the diariser's percentage, because
    /// the first run of that model downloads 22 MB and an unlabelled spinner
    /// reads as a hang.
    case meetingProcessing(String)
    /// This Mac just connected to Flow. Terminal, so it auto-hides.
    case flowConnected(name: String)
    /// An update landed and macOS dropped the Accessibility grant with it, so
    /// nothing can be typed until the person grants it again. Stays up longer
    /// than the rest: it is the one pill that asks for something.
    case accessibilityAfterUpdate

    var isTerminal: Bool {
        switch self {
        case .inserted, .copiedOnly, .discarded, .failed, .flowConnected, .accessibilityAfterUpdate: return true
        default: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// How long a terminal pill stays up before it hides itself.
    var autoHideSeconds: Double {
        switch self {
        case .accessibilityAfterUpdate: return 8.0
        case .failed: return 3.5
        default: return 1.0
        }
    }
}

private struct PillContentView: View {
    let state: PillState
    var onTapStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .listening(let partial):
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(partial.isEmpty
                     ? "Listening… any key finishes · esc cancels"
                     : "Listening… \(trailing(partial, 60))")
                    .lineLimit(1)
            case .cleaning:
                ProgressView()
                    .controlSize(.small)
                Text("Cleaning…")
            case .inserted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Inserted ✓")
            case .copiedOnly:
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text("Copied — paste with ⌘V")
            case .discarded:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Didn't catch that")
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Didn't work: \(trailing(why, 70))")
                    .lineLimit(1)
            case .meeting(let elapsed):
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text("Recording meeting · \(TranscriptBuilder.stamp(elapsed)) · click to stop")
                    .lineLimit(1)
            case .meetingProcessing(let status):
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .lineLimit(1)
            case .flowConnected(let name):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected to Flow as \(name)")
                    .lineLimit(1)
            case .accessibilityAfterUpdate:
                Image(systemName: "lock.open")
                    .foregroundStyle(.yellow)
                Text(AccessibilityPermission.updatePillText)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color.black.opacity(0.78))
        )
        .contentShape(Capsule())
        .onTapGesture {
            if case .listening = state { onTapStop() }
            else if case .meeting = state { onTapStop() }
        }
        .fixedSize()
    }

    private func trailing(_ text: String, _ n: Int) -> String {
        guard text.count > n else { return text }
        return String(text.suffix(n))
    }
}

/// Small, borderless, non-activating floating panel shown bottom-center of
/// the active screen during hotkey/toggle dictations. Never steals focus —
/// the app is an accessory app, and this panel never becomes key.
@MainActor
final class StatusPillController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var autoHideWorkItem: DispatchWorkItem?

    var onTapStop: (() -> Void)?

    func show(_ state: PillState) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        let panel = panelOrMake()
        update(state)
        positionBottomCenter(panel)
        panel.orderFrontRegardless()

        if state.isTerminal {
            let work = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            autoHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + state.autoHideSeconds, execute: work)
        }
    }

    func update(_ state: PillState) {
        let content = PillContentView(state: state, onTapStop: { [weak self] in
            self?.onTapStop?()
        })
        if let hostingView {
            hostingView.rootView = AnyView(content)
            hostingView.setFrameSize(hostingView.fittingSize)
            panel?.setContentSize(hostingView.fittingSize)
        }
        if let panel {
            positionBottomCenter(panel)
        }
    }

    func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func panelOrMake() -> NSPanel {
        if let panel { return panel }

        let content = PillContentView(state: .listening(partial: ""), onTapStop: { [weak self] in
            self?.onTapStop?()
        })
        let hosting = NSHostingView(rootView: AnyView(content))
        self.hostingView = hosting

        let newPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered,
                                defer: false)
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = hosting
        newPanel.ignoresMouseEvents = false

        self.panel = newPanel
        return newPanel
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        let screen = screenWithKeyboardFocus() ?? NSScreen.main
        guard let screen else { return }
        let size = hostingView?.fittingSize ?? panel.frame.size
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.minY + 64
        panel.setFrame(NSRect(x: x, y: y, width: max(size.width, 40), height: max(size.height, 20)), display: true)
    }

    /// Best-effort "screen with the keyboard focus": macOS has no direct API
    /// for this, so we approximate with the screen containing the mouse
    /// cursor (closest proxy to where the user is actively working), falling
    /// back to the main screen.
    private func screenWithKeyboardFocus() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}
