import Foundation
import AppKit
import Carbon.HIToolbox

/// Owns the global dictation hotkey scheme:
///
/// 1. **Activate: ⌘ + Right Option** (pressed in either order). Watched via
///    NSEvent flagsChanged monitors (global + local). Right Option is
///    distinguished from Left Option via the device-dependent flag bit, so
///    typing special characters with Left Option is never affected.
/// 2. **While dictating**, a CGEventTap swallows every key press system-wide:
///    any key finishes the dictation (text gets inserted), Escape discards it.
///    The swallowed key never reaches the frontmost app, and the matching
///    key-up is drained so apps never see an orphan keystroke.
///
/// Requires Accessibility trust for both the monitors and the event tap;
/// AppState only calls `install()` once trust is granted.
@MainActor
final class HotkeyManager {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let leftCommandKeyCode: UInt16 = 55
    private static let rightCommandKeyCode: UInt16 = 54
    private static let escapeKeyCode: Int64 = 53
    /// NX_DEVICERALTKEYMASK — set while the RIGHT Option key is physically down.
    private static let rightOptionDeviceMask: UInt = 0x40

    /// ⌘ + Right ⌥ pressed while idle.
    var onActivate: (() -> Void)?
    /// Any non-Escape key pressed while capturing → finish and insert.
    var onFinish: (() -> Void)?
    /// Escape pressed while capturing → discard the dictation.
    var onDiscard: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isInstalled = false

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private(set) var isCapturing = false
    /// Key whose key-up we still need to swallow after the deciding key-down.
    private var drainKeyCode: Int64?

    // MARK: - Activation combo (⌘ + Right ⌥)

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
    }

    func uninstall() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        endCaptureMode()
        isInstalled = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isCapturing else { return }
        // Fire when the combo completes in either order: the event is either
        // the Right Option press (with ⌘ already down) or a Command press
        // (with Right Option already physically down, per the device bit).
        let isComboKey = event.keyCode == Self.rightOptionKeyCode
            || event.keyCode == Self.leftCommandKeyCode
            || event.keyCode == Self.rightCommandKeyCode
        guard isComboKey else { return }

        let flags = event.modifierFlags
        let rightOptionDown = (flags.rawValue & Self.rightOptionDeviceMask) != 0
        guard rightOptionDown, flags.contains(.command), flags.contains(.option) else { return }
        onActivate?()
    }

    // MARK: - Any-key capture while dictating

    /// Start swallowing key presses system-wide. The first key-down decides:
    /// Escape → onDiscard, anything else → onFinish. Its key-up is drained,
    /// then the tap tears itself down.
    func beginCaptureMode() {
        drainKeyCode = nil
        if eventTap != nil {
            isCapturing = true
            return
        }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run-loop source lives on the main run loop, so this
            // callback always runs on the main thread.
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
            // Tap creation failed (permission edge). Dictation can still be
            // finished by clicking the pill; keys just aren't captured.
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isCapturing = true
    }

    /// Tear the tap down immediately (pill click, cancel paths, uninstall).
    /// Safe to call at any time, including mid-drain.
    func endCaptureMode() {
        isCapturing = false
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
            guard isCapturing else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            isCapturing = false
            drainKeyCode = keyCode
            if keyCode == Self.escapeKeyCode {
                onDiscard?()
            } else {
                onFinish?()
            }
            return nil

        case .keyUp:
            if isCapturing { return nil }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let drain = drainKeyCode, drain == keyCode {
                drainKeyCode = nil
                endCaptureMode()
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
