import Foundation
import AppKit
import ApplicationServices

/// Tracks and requests the Accessibility (AXIsProcessTrusted) permission that
/// global hotkey monitoring and synthetic keystrokes (Cmd+V insertion) need.
@MainActor
final class AccessibilityPermission: ObservableObject {
    @Published private(set) var isTrusted: Bool

    private var pollTimer: Timer?

    /// The app version this Mac last checked Accessibility against. macOS
    /// drops the grant when the signed binary changes, so an update looks to
    /// the person like the app silently stopped typing.
    static let lastVersionDefaultsKey = "lastAccessibilityCheckVersion"

    /// Exactly what the pill says when an update cost the grant. Short enough
    /// to read at a glance, and it names the cause so nobody thinks the app
    /// broke.
    static let updatePillText = "Update installed: grant Accessibility again"

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Pure, so the one decision here is testable: re-ask only when this
    /// launch is a NEW version of an app that ran before and no longer has
    /// the grant. A first ever install has no stored version, and its missing
    /// grant is the normal first-run prompt, not an update.
    nonisolated static func shouldReaskAfterUpdate(currentVersion: String,
                                       lastCheckedVersion: String?,
                                       isTrusted: Bool) -> Bool {
        guard !isTrusted else { return false }
        guard let last = lastCheckedVersion, !last.isEmpty else { return false }
        return last != currentVersion
    }

    /// Call at launch, before `checkAndPromptIfNeeded`. Returns true when the
    /// caller should show the "Update installed" pill; the system prompt has
    /// already been opened by then.
    @discardableResult
    func handleVersionChange(version: String = AccessibilityPermission.currentVersion,
                             defaults: UserDefaults = .standard) -> Bool {
        refresh()
        let last = defaults.string(forKey: Self.lastVersionDefaultsKey)
        let reask = Self.shouldReaskAfterUpdate(currentVersion: version,
                                                lastCheckedVersion: last,
                                                isTrusted: isTrusted)
        // Recorded either way, and once: the prompt is opened on the first
        // launch of a new version and never again for that version.
        defaults.set(version, forKey: Self.lastVersionDefaultsKey)
        if reask {
            FileHandle.standardError.write(Data("[access] version changed from \(last ?? "?") to \(version) and Accessibility is not granted; asking again\n".utf8))
            requestAccess()
        }
        return reask
    }

    /// Call once at launch. Refreshes current trust state and, if not
    /// trusted, prompts the system dialog once (which deep-links to
    /// System Settings > Privacy & Security > Accessibility).
    func checkAndPromptIfNeeded() {
        refresh()
        guard !isTrusted else { return }
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startPolling()
    }

    /// User-initiated "Grant…" action from the menu: re-prompt and start
    /// polling for the user flipping the toggle in System Settings.
    func requestAccess() {
        refresh()
        if isTrusted { return }
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startPolling()
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = AXIsProcessTrusted()
                if now != self.isTrusted {
                    self.isTrusted = now
                }
                if now {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }
}
