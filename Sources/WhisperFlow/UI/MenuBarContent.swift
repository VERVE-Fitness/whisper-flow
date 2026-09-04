import SwiftUI
import AppKit

/// Content of the MenuBarExtra dropdown: status line, current mode,
/// microphone picker, "Show Transcript Window", Accessibility permission
/// status (+ Grant… action), and Quit.
struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var accessibility: AccessibilityPermission
    var openTranscriptWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusLine)
            Text("cleanup: \(state.cleanupBackendName)")
                .foregroundStyle(.secondary)
            if state.llmStatus != .ready && state.llmStatus != .notStarted {
                Text("language model: \(state.llmStatus.label)")
                    .foregroundStyle(.secondary)
            }
            Text("Whisper Flow \(AppState.versionLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onAppear { state.refreshInputDevices() }

        Divider()

        // Microphone picker. Default is the built-in mic even when AirPods
        // are connected -- see InputDeviceSelection for the reasoning; the
        // "System default" entry is the opt-out for people who genuinely
        // want the headset mic (clamshell Macs, noisy rooms).
        Menu("Microphone: \(state.activeMicrophoneName)") {
            micChoice(label: "Built-in Mac microphone (recommended)",
                      selection: .builtIn,
                      isSelected: state.inputSelection == .builtIn)
            micChoice(label: "System default (follows AirPods / headsets)",
                      selection: .systemDefault,
                      isSelected: state.inputSelection == .systemDefault)
            if !state.inputDevices.isEmpty {
                Divider()
                ForEach(state.inputDevices) { device in
                    micChoice(label: device.name + (device.isBluetooth ? "  (Bluetooth)" : ""),
                              selection: .device(uid: device.uid),
                              isSelected: state.inputSelection == .device(uid: device.uid))
                }
            }
        }

        Button("Show Transcript Window") {
            openTranscriptWindow()
        }

        Toggle("Start at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Toggle("Auto-learn corrections", isOn: Binding(
            get: { CorrectionLearner.isEnabled },
            set: { UserDefaults.standard.set($0, forKey: CorrectionLearner.enabledDefaultsKey) }
        ))

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

        Text("Hold Right ⌥: talk while held, stop on release")
            .foregroundStyle(.secondary)
        Text("⌘ + Right ⌥: hands-free — any key finishes, esc cancels")
            .foregroundStyle(.secondary)

        Divider()

        Button("Quit Whisper Flow") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    @ViewBuilder
    private func micChoice(label: String, selection: InputDeviceSelection, isSelected: Bool) -> some View {
        Button {
            state.setInputSelection(selection)
        } label: {
            if isSelected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var statusLine: String {
        state.phase.label
    }
}
