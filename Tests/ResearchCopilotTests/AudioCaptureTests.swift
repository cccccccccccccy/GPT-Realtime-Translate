import Testing
import Foundation
import ScreenCaptureKit
import AppKit
import CopilotCore
import CopilotSpeech
@testable import ResearchCopilot

@MainActor
private final class ProbeCapture: AudioCapturing {
    var hasOutstandingStream = false
    var microphoneRequested: Bool?
    var rate: Int?
    var startCalls = 0
    var failStop = false
    var holdStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var onFrame: (@Sendable (AudioFrame) -> Void)?
    var onFailure: (@Sendable (CaptureIssue) -> Void)?
    var stopCalls = 0
    func applications() async throws -> [CaptureApplication] { [.init(id: 42, name: "Zoom", bundleID: "us.zoom.xos")] }
    func start(applicationID: Int32, microphone: Bool, sampleRate: Int,
               onFrame: @escaping @Sendable (AudioFrame) -> Void,
               onFailure: @escaping @Sendable (CaptureIssue) -> Void) async throws {
        startCalls += 1; microphoneRequested = microphone; rate = sampleRate
        self.onFrame = onFrame; self.onFailure = onFailure; hasOutstandingStream = true
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
    }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
    func stop() async throws {
        stopCalls += 1
        stopForwarding()
        if failStop { throw CaptureFailure.system(operation: "停止采集", code: -3819) }
        hasOutstandingStream = false; onFrame = nil
    }
    func stopForwarding() { onFrame = nil }
    func disableMicrophone() async throws {}
}

private actor CaptureTestSpeech: SpeechRecognitionProvider {
    nonisolated let sampleRate = 16000
    var finishCalls = 0
    func accept(_ frame: AudioFrame) {}
    func finish() { finishCalls += 1 }
}

@MainActor
private final class CaptureTestSpeechStarter: SpeechSessionStarting {
    let speech = CaptureTestSpeech()
    var holdStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    func start(configuration: AppConfiguration, profile: ResearchProfile, local: WhisperKitProvider,
               localReady: Bool, emit: @escaping @Sendable (SpeechEvent) async -> Void) async throws -> any SpeechRecognitionProvider {
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        return speech
    }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
}

private actor CaptureTestStorage: MeetingStorage {
    var saved: MeetingSession?
    func save(_ meeting: MeetingSession) { saved = meeting }
    func load(_ id: UUID) throws -> MeetingSession { throw CopilotError.message("unused") }
    func delete(_ id: UUID) {}
    func listIDs() -> [UUID] { [] }
    func saveConfiguration(_ configuration: AppConfiguration) {}
    func loadConfiguration() -> AppConfiguration? { nil }
    func saveProfile(_ profile: ResearchProfile) {}
    func loadProfile() -> ResearchProfile? { nil }
}

@MainActor
private func captureWaitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CopilotError.message("capture test timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct AudioCaptureTests {
    @Test @MainActor func processObservationCanBeReleasedRepeatedly() {
        // Native KVO lifecycle exercise; observes only this test process and never
        // launches, terminates, captures, or changes permissions of another app.
        for _ in 0..<100 {
            autoreleasepool {
                var token: ApplicationTerminationObservation? = .init(application: .current) {}
                #expect(token != nil)
                token = nil
            }
        }
    }

    @Test func environmentEventsMatchOnlyTheSelectedSources() {
        let policy = CaptureEnvironmentPolicy(applicationID: 42, microphoneUID: "test-mic", defaultInputID: 7)
        #expect(policy.applicationTerminated(41) == nil)
        #expect(policy.applicationTerminated(42)?.contains("Zoom") == true)
        #expect(policy.microphoneDisconnected("other-mic") == nil)
        #expect(policy.microphoneDisconnected("test-mic")?.contains("断开") == true)
        #expect(policy.defaultInputChanged(7) == nil)
        #expect(policy.defaultInputChanged(8)?.contains("切换") == true)
        #expect(policy.defaultInputChanged(nil) != nil)
        let remoteOnly = CaptureEnvironmentPolicy(applicationID: 42, microphoneUID: nil, defaultInputID: nil)
        #expect(remoteOnly.defaultInputChanged(8) == nil && remoteOnly.microphoneDisconnected("test-mic") == nil)
    }

    @Test func interruptionClosesDeliveryOnceAndIgnoresDisabledMicrophone() {
        let gate = CaptureFrameGate(microphone: true)
        gate.disableMicrophone()
        #expect(!gate.interrupt(microphoneOnly: true))
        var delivered = 0
        let frame = AudioFrame(track: .remote, samples: [0.1], sampleRate: 16000, start: 0)
        gate.deliver(frame) { _ in delivered += 1 }
        #expect(gate.interrupt())
        #expect(!gate.interrupt())
        gate.deliver(frame) { _ in delivered += 1 }
        #expect(delivered == 1)
        let manuallyStopped = CaptureFrameGate(microphone: true)
        manuallyStopped.stop()
        #expect(!manuallyStopped.interrupt())
    }

    @Test @MainActor func sleepDuringProbeStartupClosesHandoffAndNeverResumes() async throws {
        let capture = ProbeCapture(); capture.holdStart = true
        let controller = MeetingController(audio: capture)
        await controller.refreshApplications()
        let startup = Task { await controller.startAudioTest() }
        try await captureWaitUntil { capture.startWaiter != nil }
        await controller.handleSystemSleep()
        #expect(capture.onFrame == nil && !controller.isRecording)
        capture.releaseStart(); await startup.value
        #expect(!capture.hasOutstandingStream && !controller.isTestingAudio)
        #expect(controller.audioProbeReport?.stopConfirmed == true)
        #expect(controller.audioProbeReport?.issues.contains(where: { $0.contains("睡眠") }) == true)
        #expect(!controller.meeting.hasRecord)
    }

    @Test @MainActor func sleepWhileSpeechStartsPreventsAudioStartup() async throws {
        let capture = ProbeCapture(); let starter = CaptureTestSpeechStarter(); starter.holdStart = true
        let storage = CaptureTestStorage()
        let controller = MeetingController(audio: capture, speechStarter: starter, repositoryFactory: { storage })
        await controller.initialize(); await controller.refreshApplications()
        let startup = Task { await controller.start() }
        try await captureWaitUntil { starter.startWaiter != nil }
        await controller.handleSystemSleep()
        starter.releaseStart(); await startup.value
        #expect(capture.startCalls == 0 && !controller.isRecording && !controller.isStarting)
        #expect(controller.captureStatus.contains("睡眠"))
        #expect(controller.meeting.gaps.contains(where: { $0.reason.contains("睡眠") }))
        #expect(await starter.speech.finishCalls == 1)
        let saved = await storage.saved
        #expect(saved?.endedAt != nil && saved?.gaps.contains(where: { $0.reason.contains("睡眠") }) == true)
    }

    @Test @MainActor func sleepWhileCaptureStartsCleansUpBeforeReportingRecording() async throws {
        let capture = ProbeCapture(); capture.holdStart = true
        let starter = CaptureTestSpeechStarter(); let storage = CaptureTestStorage()
        let controller = MeetingController(audio: capture, speechStarter: starter, repositoryFactory: { storage })
        await controller.initialize(); await controller.refreshApplications()
        let startup = Task { await controller.start() }
        try await captureWaitUntil { capture.startWaiter != nil }
        await controller.handleSystemSleep()
        #expect(capture.onFrame == nil)
        capture.releaseStart(); await startup.value
        #expect(!controller.isRecording && !capture.hasOutstandingStream)
        #expect(controller.captureStatus.contains("睡眠"))
        #expect(await starter.speech.finishCalls == 1)
    }

    @Test @MainActor func recordingSleepPersistsGapAndFailedStopStillBlocksRestart() async {
        let capture = ProbeCapture(); let starter = CaptureTestSpeechStarter(); let storage = CaptureTestStorage()
        let controller = MeetingController(audio: capture, speechStarter: starter, repositoryFactory: { storage })
        await controller.initialize(); await controller.refreshApplications(); await controller.start()
        #expect(controller.isRecording)
        capture.failStop = true
        await controller.handleSystemSleep()
        #expect(!controller.isRecording && controller.captureStopUnconfirmed)
        #expect(controller.captureStatus.contains("停止尚未确认"))
        let saved = await storage.saved
        #expect(saved?.gaps.contains(where: { $0.reason.contains("睡眠") }) == true)
        #expect(saved?.endedAt != nil)
        await controller.start()
        #expect(capture.startCalls == 1)
        capture.failStop = false; await controller.retryCaptureStop()
        #expect(!controller.captureStopUnconfirmed)
    }

    @Test @MainActor func oldStreamInterruptionCannotStopTheNextMeeting() async throws {
        let capture = ProbeCapture(); let starter = CaptureTestSpeechStarter(); let storage = CaptureTestStorage()
        let controller = MeetingController(audio: capture, speechStarter: starter, repositoryFactory: { storage })
        await controller.initialize(); await controller.refreshApplications(); await controller.start()
        let oldFailure = capture.onFailure
        capture.onFailure?(.interrupted("Synthetic selected Zoom exit"))
        try await captureWaitUntil { !controller.isRecording && !controller.isStopping }
        #expect(controller.meeting.gaps.contains(where: { $0.reason == "Synthetic selected Zoom exit" }))
        await controller.start()
        #expect(controller.isRecording)
        oldFailure?(.interrupted("Old event must not affect new recording"))
        await Task.yield()
        #expect(controller.isRecording && controller.meeting.gaps.isEmpty)
        await controller.stop()
    }

    @Test func classifiesOnlyKnownScreenCaptureErrors() {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "private content"])
        #expect(CaptureFailure.classify(denied, operation: "读取") == .screenPermission)
        let unrelated = NSError(domain: "unrelated", code: denied.code,
                                userInfo: [NSLocalizedDescriptionKey: "private content"])
        let safe = CaptureFailure.classify(unrelated, operation: "读取")
        #expect(safe == .system(operation: "读取", code: nil))
        #expect(!safe.localizedDescription.contains("private content"))
        let source = NSError(domain: SCStreamErrorDomain, code: SCStreamError.noCaptureSource.rawValue)
        #expect(CaptureFailure.classify(source, operation: "读取") == .sourceUnavailable)
    }

    @Test func probeMeasuresSoundRejectsInvalidFramesAndFreezesOnFinish() {
        let probe = AudioSourceProbe(applicationID: 42, bundleID: "us.zoom.xos")
        probe.accept(.init(track: .remote, samples: Array(repeating: 0.25, count: 160), sampleRate: 16000, start: 0))
        probe.accept(.init(track: .remote, samples: [.nan], sampleRate: 16000, start: 0))
        probe.accept(.init(track: .microphone, samples: [0.25], sampleRate: 16000, start: 0))
        let report = probe.finish(confirmed: true)
        #expect(report.remoteFrames == 1 && report.remoteSamples == 160)
        #expect(report.nonSilentFrames == 1 && report.peakRMS == 0.25)
        #expect(report.microphoneFrames == 1 && report.issues.count == 1)
        #expect(report.currentRMS == 0 && report.stopConfirmed)
        probe.accept(.init(track: .remote, samples: [1], sampleRate: 16000, start: 0))
        #expect(probe.snapshot().remoteFrames == 1)
    }

    @Test func gateClosesMicrophoneAndThenAllFrames() {
        let gate = CaptureFrameGate(microphone: true)
        let remote = AudioFrame(track: .remote, samples: [0], sampleRate: 16000, start: 0)
        let microphone = AudioFrame(track: .microphone, samples: [0], sampleRate: 16000, start: 0)
        var tracks: [AudioTrack] = []
        gate.deliver(microphone) { tracks.append($0.track) }
        gate.disableMicrophone()
        gate.deliver(microphone) { tracks.append($0.track) }
        gate.deliver(remote) { tracks.append($0.track) }
        gate.stop()
        gate.deliver(remote) { tracks.append($0.track) }
        #expect(tracks == [.microphone, .remote])
    }

    @Test @MainActor func probeNeverStartsASROrCreatesMeeting() async {
        let capture = ProbeCapture()
        let controller = MeetingController(audio: capture)
        controller.configuration.captureMicrophone = true
        await controller.refreshApplications()
        let original = controller.meeting
        await controller.startAudioTest()
        #expect(controller.isTestingAudio && !controller.isRecording && !controller.modelReady)
        #expect(capture.microphoneRequested == false && capture.rate == 16000)
        capture.onFrame?(.init(track: .remote, samples: [0.5], sampleRate: 16000, start: 0))
        await controller.stopAudioTest()
        #expect(controller.audioProbeReport?.remoteFrames == 1)
        #expect(controller.audioProbeReport?.microphoneFrames == 0)
        #expect(controller.audioProbeReport?.stopConfirmed == true)
        #expect(controller.meeting.id == original.id && !controller.meeting.hasRecord)
        #expect(!controller.isTestingAudio && !controller.libraryActionsDisabled)
    }

    @Test @MainActor func failedStopBlocksRestartUntilRetrySucceeds() async {
        let capture = ProbeCapture(); let controller = MeetingController(audio: capture)
        await controller.refreshApplications(); await controller.startAudioTest()
        capture.failStop = true; await controller.stopAudioTest()
        #expect(controller.captureStopUnconfirmed && controller.libraryActionsDisabled)
        #expect(controller.audioProbeReport?.stopConfirmed == false)
        await controller.startAudioTest()
        #expect(capture.startCalls == 1)
        #expect(await controller.prepareForTermination() == false)
        capture.failStop = false; await controller.retryCaptureStop()
        #expect(!controller.captureStopUnconfirmed && !controller.libraryActionsDisabled)
        #expect(controller.audioProbeReport?.stopConfirmed == true)
    }

    @Test @MainActor func stopDuringStartupEndsProbeOnceStartupReturns() async {
        let capture = ProbeCapture(); capture.holdStart = true
        let controller = MeetingController(audio: capture)
        await controller.refreshApplications()
        let start = Task { await controller.startAudioTest() }
        for _ in 0..<1000 {
            if capture.startWaiter != nil { break }
            await Task.yield()
        }
        #expect(capture.startWaiter != nil)
        await controller.stopAudioTest()
        capture.releaseStart(); await start.value
        #expect(!capture.hasOutstandingStream && !controller.isTestingAudio)
        #expect(controller.audioProbeReport?.stopConfirmed == true)
    }
}
