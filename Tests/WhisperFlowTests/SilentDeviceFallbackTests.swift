import XCTest
import CoreAudio
@testable import WhisperFlow

/// Four dictations on 8 September were captured from "NW AirPods Pro" with an
/// RMS of exactly 0.0 -- the device delivered digital silence and the person
/// got "Didn't catch that" four times in a row. Any device can do this
/// (Bluetooth profile switch, AirPods sitting in the case, built-in mic with
/// the lid shut), so the capture switches away from one that produces nothing
/// but zeros. These are the rules for where it switches to.
final class RankedFallbackTests: XCTestCase {
    private func device(_ name: String, _ uid: String, _ transport: UInt32) -> AudioInputDevice {
        AudioInputDevice(id: AudioDeviceID(abs(uid.hashValue % 100_000)), uid: uid, name: name,
                         transportType: transport)
    }

    private var builtIn: AudioInputDevice { device("MacBook Pro Microphone", "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn) }
    private var airPods: AudioInputDevice { device("NW AirPods Pro", "airpods-uid", kAudioDeviceTransportTypeBluetooth) }
    private var usbMic: AudioInputDevice { device("Shure MV7", "usb-uid", kAudioDeviceTransportTypeUSB) }
    private var blackHole: AudioInputDevice { device("BlackHole 2ch", "BlackHole2ch_UID", kAudioDeviceTransportTypeVirtual) }
    private var aggregate: AudioInputDevice { device("Whisper Flow Aggregate", "agg-uid", kAudioDeviceTransportTypeAggregate) }
    private var iPhone: AudioInputDevice { device("Niall's iPhone Microphone", "continuity-uid", kAudioDeviceTransportTypeContinuityCaptureWireless) }

    func testBuiltInMicWinsWhenTheLidIsOpen() {
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, usbMic, builtIn],
                                                excluding: airPods.uid,
                                                lidClosed: false,
                                                systemDefaultUID: airPods.uid)
        XCTAssertEqual(ranked.first?.uid, builtIn.uid)
    }

    func testBuiltInMicIsSkippedWhenTheLidIsShut() {
        // Clamshell mode disables the built-in mic: it still enumerates and
        // still delivers buffers, every sample zero. Switching to it would
        // land on the same failure we are running from.
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, usbMic, builtIn],
                                                excluding: airPods.uid,
                                                lidClosed: true,
                                                systemDefaultUID: airPods.uid)
        XCTAssertEqual(ranked.first?.uid, usbMic.uid)
        XCTAssertFalse(ranked.contains { $0.isBuiltIn })
    }

    func testTheSilentDeviceIsNeverOffered() {
        let ranked = AudioDevices.rankFallbacks(devices: [builtIn, usbMic],
                                                excluding: builtIn.uid,
                                                lidClosed: false,
                                                systemDefaultUID: builtIn.uid)
        XCTAssertFalse(ranked.contains { $0.uid == self.builtIn.uid })
        XCTAssertEqual(ranked.map(\.uid), [usbMic.uid])
    }

    func testBluetoothAndVirtualDevicesAreNotFallbacks() {
        // Another Bluetooth headset is as likely to be silent as the one we
        // just left, and BlackHole/Aggregate would accept a dictation nobody
        // can hear.
        let otherBluetooth = device("Sony WH-1000XM5", "sony-uid", kAudioDeviceTransportTypeBluetooth)
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, otherBluetooth, blackHole, aggregate],
                                                excluding: airPods.uid,
                                                lidClosed: false,
                                                systemDefaultUID: nil)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testSystemDefaultIsTheLastResort() {
        // Nothing physical to fall back to, but the system default is at
        // least what the rest of the Mac is using.
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, blackHole],
                                                excluding: airPods.uid,
                                                lidClosed: false,
                                                systemDefaultUID: blackHole.uid)
        XCTAssertEqual(ranked.map(\.uid), [blackHole.uid])
    }

    func testContinuityMicCounts() {
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, iPhone],
                                                excluding: airPods.uid,
                                                lidClosed: true,
                                                systemDefaultUID: nil)
        XCTAssertEqual(ranked.map(\.uid), [iPhone.uid])
    }

    func testNothingToSwitchToMeansStayPut() {
        let ranked = AudioDevices.rankFallbacks(devices: [airPods],
                                                excluding: airPods.uid,
                                                lidClosed: false,
                                                systemDefaultUID: airPods.uid)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testNoDeviceIsOfferedTwice() {
        // The built-in mic is also the system default here; it must appear
        // once, not once per rule that matches it.
        let ranked = AudioDevices.rankFallbacks(devices: [airPods, builtIn, usbMic],
                                                excluding: airPods.uid,
                                                lidClosed: false,
                                                systemDefaultUID: builtIn.uid)
        XCTAssertEqual(ranked.map(\.uid), [builtIn.uid, usbMic.uid])
    }
}
