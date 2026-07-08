import Foundation
import AppKit
import os

private let hkLog = Logger(subsystem: "com.niallwogan.whisperflow", category: "hotkeys")

/// Two ways to dictate, sharing one state machine:
///
/// 1. **Push-to-talk**: hold Right Option alone → listens while held, stops
///    the instant you release it.
/// 2. **Hands-free**: hold ⌘ + Right Option → keeps listening after you let
///    go of both keys; only a later key press ends it (Escape discards
///    instead of inserting). You can also add ⌘ *while already holding*
///    Right Option mid-dictation to switch from "stop on release" to
///    "stop on next key" without restarting the recording.
///
/// Right Option is identified by key code (61) AND the device-specific
/// modifier bit, so Left Option — used for typing accented characters and
/// symbols — is never touched. Requires Accessibility trust for both the
/// flagsChanged monitors and the event tap; AppState only calls `install()`
/// once trust is granted.
@MainActor
final class HotkeyManager {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let leftCommandKeyCode: UInt16 = 55
    private static let rightCommandKeyCode: UInt16 = 54
    private static let escapeKeyCode: Int64 = 53
    /// NX_DEVICERALTKEYMASK — set while the RIGHT Option key is physically down.
    private static let rightOptionDeviceMask: UInt = 0x40

    /// Ignore Right-Option holds shorter than this before committing to a
    /// plain push-to-talk start (accidental taps never start a dictation).
    /// Not applied to the ⌘+Option hands-free chord, which is intentional and
    /// instantaneous by nature.
    private let pttDebounce: TimeInterval = 0.150

    /// Called exactly once when a dictation begins, regardless of which path
    /// triggered it.
    var onStart: (() -> Void)?
    /// Called when the dictation ends and should be inserted (Option
    /// released in push-to-talk mode, or any key pressed in hands-free mode).
    var onFinish: (() -> Void)?
    /// Called when a hands-free dictation is discarded via Escape.
    var onCancel: (() -> Void)?

    private enum State {
        case idle
        /// Right Option down, no ⌘ yet, waiting out the debounce.
        case pendingPTT
        /// Recording; ends when Right Option is released.
        case recordingPTT
        /// Recording; ends only via a key press (any-key-finish tap active).
        case recordingHandsFree
    }
    private var state: State = .idle

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isInstalled = false

    private var downAt: Date?
    private var debounceWorkItem: DispatchWorkItem?
    /// The global and local flagsChanged monitors are meant to be mutually
    /// exclusive (global fires when another app is frontmost, local when we
    /// are), but AppKit can hand the SAME physical key event to both -- each
    /// delivery independently reads the state machine as "recording" and
    /// calls onFinish, producing two full stop-clean-insert cycles for one
    /// key release (observed 2026-07-08: "which type of site..." typed
    /// twice, both log entries carrying identical audio_seconds/rms -- same
    /// captured buffer, processed twice). NSEvent.timestamp reflects the
    /// underlying hardware event, so a duplicate delivery of the same
    /// physical event carries the identical timestamp even though the two
    /// monitors invoke us at slightly different wall-clock moments -- unlike
    /// a real second key press, which always gets a new timestamp.
    private var lastHandledFlagsTimestamp: TimeInterval?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var drainKeyCode: Int64?

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
        hkLog.info("flags monitors installed (global: \(self.globalFlagsMonitor != nil))")
    }

    /// Force back to idle and tear down the event tap, regardless of current
    /// state. Called by AppState if a dictation errors out from underneath a
    /// hands-free session, so a stuck tap never keeps swallowing keystrokes.
    func reset() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        teardownEventTap()
        state = .idle
    }

    func uninstall() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        teardownEventTap()
        state = .idle
        isInstalled = false
    }

    // MARK: - flagsChanged: Right Option down/up, ⌘ down

    private func handleFlagsChanged(_ event: NSEvent) {
        // Drop a redundant delivery of the identical physical event (see
        // lastHandledFlagsTimestamp's doc comment) before it reaches any
        // state-machine logic.
        guard event.timestamp != lastHandledFlagsTimestamp else {
            // Logged deliberately: this is the only direct evidence that the
            // diagnosed duplicate-delivery mechanism is what's actually
            // happening. If duplicate dictation recurs WITHOUT this line
            // appearing in Console.app (search "hotkeys" / "duplicate
            // flagsChanged"), the cause is something else and this fix
            // didn't address it.
            hkLog.info("suppressed duplicate flagsChanged delivery (same hardware timestamp)")
            return
        }
        lastHandledFlagsTimestamp = event.timestamp

        let flags = event.modifierFlags
        let rightOptionPhysicallyDown = (flags.rawValue & Self.rightOptionDeviceMask) != 0
        let cmdDown = flags.contains(.command)

        if event.keyCode == Self.rightOptionKeyCode {
            if rightOptionPhysicallyDown {
                handleRightOptionDown(cmdAlreadyDown: cmdDown)
            } else {
                handleRightOptionUp()
            }
        } else if event.keyCode == Self.leftCommandKeyCode || event.keyCode == Self.rightCommandKeyCode {
            if cmdDown && rightOptionPhysicallyDown {
                handleCmdJoinedWhileOptionHeld()
            }
        }
    }

    private func handleRightOptionDown(cmdAlreadyDown: Bool) {
        guard state == .idle else { return }

        if cmdAlreadyDown {
            hkLog.info("hands-free start (⌘ already down)")
            state = .recordingHandsFree
            onStart?()
            setupEventTap()
            return
        }

        downAt = Date()
        state = .pendingPTT
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .pendingPTT else { return }
            hkLog.info("push-to-talk start")
            self.state = .recordingPTT
            self.onStart?()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pttDebounce, execute: work)
    }

    private func handleCmdJoinedWhileOptionHeld() {
        switch state {
        case .pendingPTT:
            // Cmd landed before the debounce fired: skip straight to
            // hands-free instead of also starting a plain PTT dictation.
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            hkLog.info("hands-free start (⌘ joined before debounce)")
            state = .recordingHandsFree
            onStart?()
            setupEventTap()
        case .recordingPTT:
            // Already recording via push-to-talk: switch how it ends, don't
            // restart the dictation.
            hkLog.info("upgrading push-to-talk -> hands-free mid-dictation")
            state = .recordingHandsFree
            setupEventTap()
        case .idle, .recordingHandsFree:
            break
        }
    }

    private func handleRightOptionUp() {
        switch state {
        case .pendingPTT:
            // Released before the debounce fired: accidental tap, nothing started.
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            state = .idle
        case .recordingPTT:
            hkLog.info("push-to-talk stop (release)")
            state = .idle
            onFinish?()
        case .recordingHandsFree:
            // Hands-free persists after the key is released; only a
            // subsequent key press (via the event tap) ends it.
            break
        case .idle:
            break
        }
    }

    // MARK: - Any-key-finish / Escape-cancel while hands-free

    private func setupEventTap() {
        guard eventTap == nil else { return }
        drainKeyCode = nil

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                manager.handleTapEvent(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Tap creation failed (permission edge). Hands-free dictation can
            // still be finished by clicking the pill.
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownEventTap() {
        drainKeyCode = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            guard state == .recordingHandsFree else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            state = .idle
            drainKeyCode = keyCode
            if keyCode == Self.escapeKeyCode {
                hkLog.info("hands-free cancel (esc)")
                onCancel?()
            } else {
                hkLog.info("hands-free finish (key)")
                onFinish?()
            }
            return nil

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let drain = drainKeyCode, drain == keyCode {
                drainKeyCode = nil
                teardownEventTap()
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
