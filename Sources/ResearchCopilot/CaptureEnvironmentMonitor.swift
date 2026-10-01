import AppKit
import AVFoundation
import Combine
import CoreAudio

/// IDs are used only to match live device/app events, never written to meeting text.
struct CaptureEnvironmentPolicy: Sendable {
    let applicationID: Int32
    let microphoneUID: String?
    let defaultInputID: AudioDeviceID?

    func applicationTerminated(_ id: Int32) -> String? {
        guard id == applicationID else { return nil }
        return "所选 Zoom 已退出，音频捕获中断。重新打开 Zoom 后请刷新音源并手动开始。"
    }
    func microphoneDisconnected(_ uid: String) -> String? {
        guard let microphoneUID, microphoneUID == uid else { return nil }
        return "正在使用的本人麦克风已断开，记录可能中断。请检查设备后手动开始。"
    }
    func defaultInputChanged(_ id: AudioDeviceID?) -> String? {
        guard let defaultInputID, id != defaultInputID else { return nil }
        return "系统默认麦克风已切换或不可用，记录可能中断。请确认设备后手动开始。"
    }
}

/// Owns registrations for one capture run; releasing it removes every listener.
@MainActor
final class CaptureEnvironmentMonitor {
    private var appObservation: ApplicationTerminationObservation?
    private var microphoneObservation: AnyCancellable?
    private var inputObservation: CoreAudioInputObservation?

    init(policy: CaptureEnvironmentPolicy,
         interrupt: @escaping @Sendable (String, Bool) -> Void) throws {
        guard let application = NSRunningApplication(processIdentifier: policy.applicationID), !application.isTerminated else {
            throw CaptureFailure.sourceUnavailable
        }
        appObservation = ApplicationTerminationObservation(application: application) {
            if let reason = policy.applicationTerminated(policy.applicationID) { interrupt(reason, false) }
        }
        if policy.microphoneUID != nil {
            microphoneObservation = NotificationCenter.default
                .publisher(for: AVCaptureDevice.wasDisconnectedNotification)
                .sink { @Sendable notification in
                    guard let device = notification.object as? AVCaptureDevice,
                          let reason = policy.microphoneDisconnected(device.uniqueID) else { return }
                    interrupt(reason, true)
                }
            inputObservation = try CoreAudioInputObservation {
                if let reason = policy.defaultInputChanged(CoreAudioInputObservation.defaultDevice()) {
                    interrupt(reason, true)
                }
            }
            // Close the registration race: the default may have changed since selection.
            if let reason = policy.defaultInputChanged(CoreAudioInputObservation.defaultDevice()) {
                interrupt(reason, true)
            }
        }
    }

    func disableMicrophone() {
        microphoneObservation = nil
        inputObservation = nil
    }
}

/// Invalidate KVO while the observed process object is still alive. Releasing the
/// NSRunningApplication before its Swift KVO token crashed during native teardown.
/// This nonisolated owner also keeps the system callback independent of MainActor.
final class ApplicationTerminationObservation {
    private let application: NSRunningApplication
    private var observation: NSKeyValueObservation?

    init(application: NSRunningApplication, terminated: @escaping @Sendable () -> Void) {
        self.application = application
        // Unlike workspace termination notifications, this covers LSUIElement apps.
        observation = application.observe(\.isTerminated, options: [.initial, .new]) { _, change in
            if change.newValue == true { terminated() }
        }
    }
    deinit {
        withExtendedLifetime(application) {
            observation?.invalidate()
            observation = nil
        }
    }
}

/// Immutable registration state. Core Audio may call its block off the actor; the
/// callback only reads a device ID and enters the lock-protected capture gate.
private final class CoreAudioInputObservation: @unchecked Sendable {
    private let block: AudioObjectPropertyListenerBlock
    private static var address: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultInputDevice,
              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice() -> AudioDeviceID? {
        var address = address
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    init(changed: @escaping @Sendable () -> Void) throws {
        block = { _, _ in changed() }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        guard status == noErr else {
            throw CaptureFailure.system(operation: "监听本人麦克风设备变化", code: Int(status))
        }
    }

    deinit {
        var address = Self.address
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}

extension CaptureEnvironmentPolicy {
    /// Called only for an explicitly enabled, authorized microphone.
    @MainActor static func selected(applicationID: Int32, microphone: Bool) throws -> Self {
        guard microphone else { return .init(applicationID: applicationID, microphoneUID: nil, defaultInputID: nil) }
        guard let inputID = CoreAudioInputObservation.defaultDevice(),
              let device = AVCaptureDevice.default(for: .audio),
              CoreAudioInputObservation.defaultDevice() == inputID else {
            throw CaptureFailure.microphoneUnavailable
        }
        return .init(applicationID: applicationID, microphoneUID: device.uniqueID, defaultInputID: inputID)
    }
}
