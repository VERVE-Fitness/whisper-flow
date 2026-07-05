import Foundation
import AppKit
import Carbon.HIToolbox

/// Owns both global hotkey routes:
///
/// 1. Push-to-talk: hold RIGHT Option (keyCode 61) to start, release to stop.
///    Watched via NSEvent flagsChanged monitors (global + local, so it also
///    fires when our own UI has focus). Left Option is never touched.
/// 2. Hands-free toggle: Control+Option+Space, registered as a Carbon hot key
///    so it works system-wide even without an NSEvent monitor.
///
/// Both call back into the same start/stop closures the window Record button
/// uses. Requires Accessibility trust to receive global (out-of-process)
/// events; when untrusted, the monitors are simply never installed and the
/// caller is responsible for reflecting that in the UI.
@MainActor
final class HotkeyManager {
    private static let rightOptionKeyCode: CGKeyCode = 61

    /// Ignore Right-Option holds shorter than this (accidental taps).
    private let pttDebounce: TimeInterval = 0.150

    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggle: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    private var pttDown = false
    private var pttDownAt: Date?
    private var pttDebounceWorkItem: DispatchWorkItem?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    private var isInstalled = false

    /// Install monitors. Safe to call multiple times; no-ops if already
    /// installed. Should only be called once Accessibility is trusted —
    /// the global flagsChanged monitor silently receives nothing otherwise,
    /// and it's cleaner to gate installation than to install unconditionally.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }

        registerToggleHotKey()
    }

    func uninstall() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        unregisterToggleHotKey()
        isInstalled = false
    }

    // MARK: - Push-to-talk (Right Option)

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let optionHeld = event.modifierFlags.contains(.option)

        if optionHeld {
            guard !pttDown else { return }
            pttDown = true
            pttDownAt = Date()
            // Debounce: only fire start after the hold has lasted long enough.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pttDown else { return }
                self.onPushToTalkStart?()
            }
            pttDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pttDebounce, execute: work)
        } else {
            guard pttDown else { return }
            pttDown = false
            let heldFor = Date().timeIntervalSince(pttDownAt ?? Date())
            pttDownAt = nil

            if heldFor < pttDebounce {
                // Accidental tap: cancel the pending start before it fires.
                pttDebounceWorkItem?.cancel()
                pttDebounceWorkItem = nil
                return
            }
            pttDebounceWorkItem?.cancel()
            pttDebounceWorkItem = nil
            onPushToTalkStop?()
        }
    }

    // MARK: - Hands-free toggle (Control+Option+Space) via Carbon

    private func registerToggleHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x5757_464C /* 'WWFL' */), id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: OSType(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            var receivedID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                               nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if receivedID.id == 1 {
                Task { @MainActor in
                    manager.onToggle?()
                }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyEventHandler)

        let modifiers = UInt32(controlKey | optionKey)
        let keyCode = UInt32(kVK_Space)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterToggleHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }
}
