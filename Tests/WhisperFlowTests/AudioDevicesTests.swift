import XCTest
@testable import WhisperFlow

final class InputDeviceSelectionTests: XCTestCase {
    private let key = "inputDeviceSelection"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultIsBuiltInMicrophone() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(InputDeviceSelection.saved, .builtIn)
    }

    func testRoundTripSystemDefault() {
        InputDeviceSelection.saved = .systemDefault
        XCTAssertEqual(InputDeviceSelection.saved, .systemDefault)
    }

    func testRoundTripSpecificDevice() {
        InputDeviceSelection.saved = .device(uid: "BlackHole2ch_UID")
        XCTAssertEqual(InputDeviceSelection.saved, .device(uid: "BlackHole2ch_UID"))
    }

    func testGarbageFallsBackToBuiltIn() {
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(InputDeviceSelection.saved, .builtIn)
    }
}

final class AudioDevicesTests: XCTestCase {
    /// Every input device CoreAudio reports must have a UID and a name; the
    /// built-in mic, when present, must be classified as built-in. On a Mac
    /// with any microphone at all, `resolve(.builtIn)` must return something.
    func testEnumerationIsWellFormed() {
        let devices = AudioDevices.allInputDevices()
        for d in devices {
            XCTAssertFalse(d.uid.isEmpty, "device \(d.id) has empty uid")
            XCTAssertFalse(d.name.isEmpty, "device \(d.id) has empty name")
        }
        if let mic = AudioDevices.builtInMicrophone() {
            XCTAssertTrue(mic.isBuiltIn)
            XCTAssertTrue(devices.contains(mic))
        }
        if !devices.isEmpty {
            let (resolved, follows) = AudioDevices.resolve(.builtIn)
            XCTAssertNotNil(resolved)
            if AudioDevices.builtInMicrophone() != nil {
                XCTAssertFalse(follows, "built-in selection must pin, not follow the system default")
            }
        }
    }

    func testUnknownDeviceUIDFallsBack() {
        guard !AudioDevices.allInputDevices().isEmpty else { return }
        let (resolved, _) = AudioDevices.resolve(.device(uid: "does-not-exist-\(UUID().uuidString)"))
        XCTAssertNotNil(resolved, "a vanished saved device must fall back, not fail the dictation")
    }
}

final class UpdateCheckTests: XCTestCase {
    func testDevBuildNeverReportsUpdate() async {
        // No stamped commit (swift build / swift run) must never nag, even
        // when GitHub is reachable.
        let r = await UpdateCheck.check(currentCommit: nil)
        XCTAssertNil(r)
        let r2 = await UpdateCheck.check(currentCommit: "unknown")
        XCTAssertNil(r2)
    }
}
