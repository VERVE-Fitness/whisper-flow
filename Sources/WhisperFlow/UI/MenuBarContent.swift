import SwiftUI
import AppKit

/// Content of the MenuBarExtra dropdown: status line, current mode,
/// "Show Transcript Window", Accessibility permission status (+ Grant…
/// action), and Quit.
struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var accessibility: AccessibilityPermission
    var openTranscriptWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusLine)
            Text("cleanup: \(state.cleanupBackendName)")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

        Divider()

        Button("Show Transcript Window") {
            openTranscriptWindow()
        }

        Divider()

        if accessibility.isTrusted {
            Text("Accessibility: granted")
                .foregroundStyle(.secondary)
        } else {
            Text("Accessibility: not granted")
                .foregroundStyle(.secondary)
            Button("Grant Accessibility…") {
                accessibility.requestAccess()
            }
            Text("Hotkeys and cursor insertion are disabled until granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        Text("Start dictation: ⌘ + Right ⌥")
            .foregroundStyle(.secondary)
        Text("Finish: press any key · Cancel: esc")
            .foregroundStyle(.secondary)

        Divider()

        Button("Quit Whisper Flow") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusLine: String {
        state.phase.label
    }
}
