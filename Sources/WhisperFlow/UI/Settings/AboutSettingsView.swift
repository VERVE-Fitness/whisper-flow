import SwiftUI
import AppKit

/// About: which build this is, whether there is a newer one, and the two pages on Flow that
/// go with the app. Local, so it works with no connection; the update check needs the
/// internet and says so when it has nothing to report.
struct AboutSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsBlock(title: "This build") {
                Text("Whisper Flow \(AppState.versionLabel)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)

                if let update = state.updateAvailable {
                    Text("Version \(update.tag) is out.")
                        .font(.callout)
                    HStack(spacing: 10) {
                        Button(state.isInstallingUpdate ? "Updating…" : "Update now") {
                            state.installUpdate()
                        }
                        .disabled(state.isInstallingUpdate)
                        Button("Download it instead") {
                            NSWorkspace.shared.open(update.downloadPage)
                        }
                        .buttonStyle(.link)
                    }
                    Text("Update now downloads it, checks the copy is ours, swaps the running app and restarts. Nothing to drag.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Button("Check now") { state.checkForUpdateNow() }
                        Text("This is the newest build the Mac knows about.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsBlock(title: "Pages on Flow",
                          caption: "The window covers everything the pages do, apart from connecting a Mac in the first place.") {
                HStack(spacing: 14) {
                    Button("Open the Whisper page") { state.openFlowSettings() }
                    Button("Open the meetings page") { state.openFlowMeetings() }
                }
                Text(state.flowMenuLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
