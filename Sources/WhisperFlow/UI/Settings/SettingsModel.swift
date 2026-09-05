import Foundation
import SwiftUI
import AVFoundation

/// Everything the settings window reads from Flow, in one place, so the six sections share
/// one fetch and one refresh instead of six.
///
/// Every write goes out through `act`, and every `act` re-reads afterwards: the server is
/// the truth about phrases, snippets, bots and who is who, and a window that guessed at the
/// result would drift the moment two Macs were open at once.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: FlowSettings?
    @Published private(set) var isLoading = false
    /// Set while a write is in flight, so buttons can go quiet without the whole window
    /// flashing its loading state.
    @Published private(set) var isWorking = false
    /// The last thing that went wrong, in a sentence. Nil once something works.
    @Published var error: String?

    private let flow: FlowClient

    init(flow: FlowClient = .shared) {
        self.flow = flow
    }

    var isConnected: Bool { flow.isConnected }

    /// True once Flow has answered at least once this session.
    var hasSettings: Bool { settings != nil }

    func load() {
        guard flow.isConnected else {
            settings = nil
            error = nil
            return
        }
        guard !isLoading else { return }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await self.flow.settings()
                self.settings = fresh
                self.error = nil
            } catch {
                self.error = Self.sentence(for: error)
            }
            self.isLoading = false
        }
    }

    /// One write, then a re-read. `body` is the same `{ action: ... }` the web page posts.
    func act(_ body: [String: Any]) {
        guard flow.isConnected else {
            error = "This Mac is not connected to Flow."
            return
        }
        guard !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.flow.settingsAction(body)
                self.error = nil
                let fresh = try? await self.flow.settings()
                if let fresh { self.settings = fresh }
            } catch {
                self.error = Self.sentence(for: error)
            }
            self.isWorking = false
        }
    }

    /// Plain English for the window. A device token Flow no longer accepts is the one worth
    /// spelling out, because the fix is a person clicking Connect this Mac again.
    static func sentence(for error: Error) -> String {
        guard let flow = error as? FlowError else { return error.localizedDescription }
        switch flow {
        case .notConnected:
            return "This Mac is not connected to Flow."
        case .unauthorised:
            return "Flow no longer accepts this Mac. Connect it again."
        case .transport:
            return "Could not reach Flow. Everything on this page still works offline."
        default:
            return flow.errorDescription ?? "Flow could not answer."
        }
    }
}

/// Plays one signed clip at a time, so the Who is who queue can have a play button on every
/// row without twenty of them talking over each other.
@MainActor
final class ClipPlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVPlayer?

    func play(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        player?.pause()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingID = id
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.playingID == id { self?.stop() }
            }
        }
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playingID = nil
    }
}
