import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CopilotCore

struct CaptureApplication: Identifiable, Hashable {
    let id: Int32
    let name: String
    let bundleID: String
}

enum CaptureIssue: Sendable {
    case interrupted(String)
    case missingAudio(String)
}

@MainActor
protocol AudioCapturing: AnyObject {
    var hasOutstandingStream: Bool { get }
    func applications() async throws -> [CaptureApplication]
    func start(applicationID: Int32, microphone: Bool, sampleRate: Int,
               onFrame: @escaping @Sendable (AudioFrame) -> Void,
               onFailure: @escaping @Sendable (CaptureIssue) -> Void) async throws
    func stop() async throws
    /// Immediately closes the audio handoff, independently of asynchronous OS stop.
    func stopForwarding()
    func disableMicrophone() async throws
}

@MainActor
final class AudioCaptureService: AudioCapturing {
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var configuration: SCStreamConfiguration?
    private var environment: CaptureEnvironmentMonitor?
    private var starting = false
    private var startCancelled = false
    private let queue = DispatchQueue(label: "org.researchcopilot.audio", qos: .userInitiated)
    var hasOutstandingStream: Bool { stream != nil }

    func applications() async throws -> [CaptureApplication] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return content.applications.filter { $0.bundleIdentifier == "us.zoom.xos" || $0.bundleIdentifier.hasPrefix("us.zoom.") }
                .map { CaptureApplication(id: $0.processID, name: $0.applicationName, bundleID: $0.bundleIdentifier) }
        } catch { throw CaptureFailure.classify(error, operation: "读取 Zoom 音源") }
    }

    func start(applicationID: Int32, microphone: Bool, sampleRate: Int,
               onFrame: @escaping @Sendable (AudioFrame) -> Void,
               onFailure: @escaping @Sendable (CaptureIssue) -> Void) async throws {
        guard stream == nil, !starting else { throw CopilotError.message("音频采集已在运行或启动中。") }
        starting = true; startCancelled = false
        defer { starting = false }
        if microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CaptureFailure.microphonePermission
            }
        }
        guard !startCancelled else { throw CancellationError() }
        let environmentPolicy = try CaptureEnvironmentPolicy.selected(applicationID: applicationID, microphone: microphone)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw CaptureFailure.classify(error, operation: "读取 Zoom 音源") }
        guard !startCancelled else { throw CancellationError() }
        guard let app = content.applications.first(where: { $0.processID == applicationID }),
              app.bundleIdentifier == "us.zoom.xos" || app.bundleIdentifier.hasPrefix("us.zoom.") else {
            throw CaptureFailure.sourceUnavailable
        }
        guard let display = content.displays.first else { throw CaptureFailure.displayUnavailable }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        configuration.captureMicrophone = microphone
        configuration.microphoneCaptureDeviceID = environmentPolicy.microphoneUID
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.showsCursor = false
        let sink = CaptureSink(sampleRate: sampleRate, microphone: microphone, onFrame: onFrame, onFailure: onFailure)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: queue)
        environment = try CaptureEnvironmentMonitor(policy: environmentPolicy) { [weak sink] reason, microphoneOnly in
            sink?.interrupt(reason, microphoneOnly: microphoneOnly)
        }
        self.sink = sink; self.stream = stream; self.configuration = configuration
        do { try await stream.startCapture() }
        catch {
            sink.stopForwarding(); environment = nil
            self.stream = nil; self.sink = nil; self.configuration = nil
            throw CaptureFailure.classify(error, operation: "启动音频采集")
        }
        // Keep the stream available for the controller's stop/retry path when a
        // cancellation arrives while ScreenCaptureKit is starting asynchronously.
        guard !startCancelled else { throw CancellationError() }
    }

    func stop() async throws {
        stopForwarding()
        guard let previous = stream else { return }
        do { try await previous.stopCapture() }
        catch {
            let platform = error as NSError
            guard platform.domain == SCStreamErrorDomain,
                  platform.code == SCStreamError.attemptToStopStreamState.rawValue else {
                throw CaptureFailure.classify(error, operation: "停止采集")
            }
        }
        stream = nil; sink = nil; configuration = nil
    }

    func stopForwarding() {
        if starting { startCancelled = true }
        sink?.stopForwarding()
        environment = nil
    }

    func disableMicrophone() async throws {
        guard let stream, let configuration else { return }
        sink?.disableMicrophone()
        environment?.disableMicrophone()
        configuration.captureMicrophone = false
        try await stream.updateConfiguration(configuration)
    }
}

/// Mutable converter state is accessed only by the serial sampleHandlerQueue.
private final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private let sampleRate: Int
    private let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    private let onFrame: @Sendable (AudioFrame) -> Void
    private let onFailure: @Sendable (CaptureIssue) -> Void
    private var converters: [AudioTrack: AVAudioConverter] = [:]
    private let gate: CaptureFrameGate

    init(sampleRate: Int, microphone: Bool, onFrame: @escaping @Sendable (AudioFrame) -> Void,
         onFailure: @escaping @Sendable (CaptureIssue) -> Void) {
        self.sampleRate = sampleRate
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        self.onFrame = onFrame; self.onFailure = onFailure
        self.gate = CaptureFrameGate(microphone: microphone)
    }

    func stopForwarding() { gate.stop() }
    func disableMicrophone() { gate.disableMicrophone() }
    func interrupt(_ reason: String, microphoneOnly: Bool = false) {
        guard gate.interrupt(microphoneOnly: microphoneOnly) else { return }
        onFailure(.interrupted(reason))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Avoid logging potentially sensitive platform error payloads.
        interrupt("Zoom 音频捕获已中断，请检查权限或重新选择音源。")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: sourceDescription) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, count <= 48000 * 2,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else {
            onFailure(.missingAudio("音频缓冲转换失败，记录可能有缺口。")); return
        }
        let track: AudioTrack = type == .microphone ? .microphone : .remote
        if converters[track]?.inputFormat != format { converters[track] = AVAudioConverter(from: format, to: outputFormat) }
        guard let converter = converters[track],
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(count) * outputFormat.sampleRate / format.sampleRate)) + 32) else { return }
        let input = ConverterInput(pcm)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            input.take(status)
        }
        guard conversionError == nil else {
            onFailure(.missingAudio("音频格式转换失败，记录可能有缺口。")); return
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds - origin
        guard time.isFinite else { return }
        gate.deliver(.init(track: track, samples: samples, sampleRate: sampleRate, start: max(0, time)), to: onFrame)
    }
}

/// The converter invokes this synchronously; the lock also enforces one-time buffer handoff.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { status.pointee = .noDataNow; return nil }
        self.buffer = nil; status.pointee = .haveData; return buffer
    }
}
