import Foundation
import AppKit
import ApplicationServices

/// Tracks and requests the Accessibility (AXIsProcessTrusted) permission that
/// global hotkey monitoring and synthetic keystrokes (Cmd+V insertion) need.
@MainActor
final class AccessibilityPermission: ObservableObject {
    @Published private(set) var isTrusted: Bool

    private var pollTimer: Timer?

    init() {
        isTrusted = AXIsProcessTrusted()
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
