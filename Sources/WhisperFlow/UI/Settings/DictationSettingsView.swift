import SwiftUI
import AppKit

/// Dictation: the microphone, what the keys do, whether the app learns from corrections,
/// whether it starts with the Mac, and what the cleanup model is doing. All of it local, so
/// this section is the same with or without a connection.
struct DictationSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var accessibility: AccessibilityPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsBlock(title: "Microphone",
                          caption: "The built-in microphone is the default even when AirPods are connected: it is the one that stays the same from room to room. Pick something else here if you record in a noisy room or with the lid shut.") {
                // A Menu rather than a Picker: InputDeviceSelection carries a device uid and
                // is only Equatable, and a Picker tag has to be Hashable.
                Menu(state.activeMicrophoneName) {
                    micChoice("Built-in Mac microphone (recommended)", .builtIn)
                    micChoice("System default, follows AirPods and headsets", .systemDefault)
                    if !state.inputDevices.isEmpty {
                        Divider()
                        ForEach(state.inputDevices) { device in
                            micChoice(device.name + (device.isBluetooth ? "  (Bluetooth)" : ""),
                                      .device(uid: device.uid))
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)

                Button("Refresh the list") { state.refreshInputDevices() }
                    .buttonStyle(.link)
            }

            SettingsBlock(title: "Keys",
                          caption: "Hotkeys are fixed for now. They need Accessibility, which is why the app asks for it on the first launch after an update.") {
                VStack(alignment: .leading, spacing: 6) {
                    keyRow("Hold Right Option", "Talk while you hold it. Let go and the text is typed where the cursor is.")
                    keyRow("Command and Right Option", "Hands free. Any key finishes it, escape throws it away.")
                }
                HStack(spacing: 8) {
                    Image(systemName: accessibility.isTrusted ? "checkmark.circle" : "exclamationmark.triangle")
                    if accessibility.isTrusted {
                        Text("Accessibility is granted.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Accessibility is not granted, so the keys and typing at the cursor are off.")
                            .font(.callout)
                        Button("Grant Accessibility…") { accessibility.requestAccess() }
                    }
                }
                .padding(.top, 4)
            }

            SettingsBlock(title: "Learning and startup") {
                Toggle("Auto-learn corrections", isOn: Binding(
                    get: { CorrectionLearner.isEnabled },
                    set: { UserDefaults.standard.set($0, forKey: CorrectionLearner.enabledDefaultsKey) }
                ))
                Text("When you fix a word straight after dictating it, the app remembers the fix for this Mac and offers it to the team as a phrase. Nothing changes for anyone else until somebody accepts it under Dictionary and phrases.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Start Whisper Flow when I log in", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .padding(.top, 6)
            }

            SettingsBlock(title: "Cleanup model",
                          caption: "Dictation is tidied up on this Mac before it is typed. Nothing is sent anywhere for it.") {
                Text("Now using \(state.cleanupBackendName)")
                    .font(.callout)
                if state.llmStatus != .ready && state.llmStatus != .notStarted {
                    Text("Language model: \(state.llmStatus.label)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Copy diagnostics") { state.copyDiagnostics() }
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func micChoice(_ label: String, _ selection: InputDeviceSelection) -> some View {
        Button {
            state.setInputSelection(selection)
        } label: {
            if state.inputSelection == selection {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ keys: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(keys)
                .font(.callout.monospaced())
                .frame(width: 210, alignment: .leading)
            Text(what)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
