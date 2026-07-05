import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status line
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(state.phase.label)
                    .font(.headline)
                Spacer()
                Text("cleanup: \(state.cleanupBackendName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Record / Stop
            Button(action: { state.toggleRecording() }) {
                Label(state.isRecording ? "Stop" : "Record",
                      systemImage: state.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.space, modifiers: [])
            .controlSize(.large)
            .disabled(!(state.canRecord || state.isRecording))

            // Raw transcript (live partials)
            Text("Raw transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(state.rawTranscript.isEmpty ? " " : state.rawTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))

            // Cleaned output
            HStack {
                Text("Cleaned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { state.copyCleaned() }
                    .disabled(state.cleanedTranscript.isEmpty && state.rawTranscript.isEmpty)
            }
            ScrollView {
                Text(state.cleanedTranscript.isEmpty ? " " : state.cleanedTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))

            // Latency readout
            if let stt = state.lastSttMs, let cleanup = state.lastCleanupMs {
                Text("stt finalize: \(stt) ms · cleanup: \(cleanup) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 460)
        .onAppear { state.onLaunch() }
    }

    private var statusColor: Color {
        switch state.phase {
        case .loadingModels: return .yellow
        case .idle, .done: return .green
        case .recording: return .red
        case .cleaning: return .orange
        case .error: return .gray
        }
    }
}
