import Foundation
import CopilotCore

struct AudioSourceProbeReport: Codable, Sendable {
    var startedAt = Date()
    var endedAt: Date?
    var applicationID: Int32
    var applicationBundleID: String
    var remoteFrames = 0
    var microphoneFrames = 0
    var remoteSamples = 0
    var peakRMS = 0.0
    var currentRMS = 0.0
    var nonSilentFrames = 0
    var sampleRate = 16000
    var issues: [String] = []
    var stopConfirmed = false
    var receivedAudioSeconds: Double { Double(remoteSamples) / Double(sampleRate) }
    var text: String {
        "收到 \(remoteFrames) 帧 / \(String(format: "%.1f", receivedAudioSeconds)) 秒音频 · 有声音 \(nonSilentFrames) 帧 · 麦克风 \(microphoneFrames) 帧"
    }
}

/// Numeric diagnostics only. Audio arrays are never retained or written to disk.
final class AudioSourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var report: AudioSourceProbeReport
    init(applicationID: Int32, bundleID: String) {
        report = .init(applicationID: applicationID, applicationBundleID: bundleID)
    }
    func accept(_ frame: AudioFrame) {
        lock.lock(); defer { lock.unlock() }
        guard report.endedAt == nil else { return }
        guard frame.track == .remote else { report.microphoneFrames += 1; return }
        guard frame.sampleRate == report.sampleRate, !frame.samples.isEmpty,
              frame.samples.allSatisfy(\.isFinite) else {
            if report.issues.count < 20 { report.issues.append("音频帧格式异常") }
            return
        }
        let rms = sqrt(frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.samples.count))
        report.remoteFrames += 1; report.remoteSamples += frame.samples.count
        report.currentRMS = rms; report.peakRMS = max(report.peakRMS, rms)
        if rms >= 0.002 { report.nonSilentFrames += 1 }
    }
    func snapshot() -> AudioSourceProbeReport { lock.lock(); defer { lock.unlock() }; return report }
    func recordIssue(_ issue: String) {
        lock.lock(); defer { lock.unlock() }
        if report.endedAt == nil, report.issues.count < 20 { report.issues.append(issue) }
    }
    func finish(confirmed: Bool, issue: String? = nil) -> AudioSourceProbeReport {
        lock.lock(); defer { lock.unlock() }
        report.endedAt = report.endedAt ?? Date(); report.currentRMS = 0; report.stopConfirmed = confirmed
        if let issue, report.issues.count < 20 { report.issues.append(issue) }
        return report
    }
}

/// Stopping or closing the microphone waits for any already executing handoff to finish.
/// The handoff must stay short and must not synchronously hop to another queue.
final class CaptureFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var microphone: Bool
    init(microphone: Bool) { self.microphone = microphone }
    func disableMicrophone() { lock.lock(); microphone = false; lock.unlock() }
    func stop() { lock.lock(); active = false; lock.unlock() }
    /// Atomically closes delivery once. A late microphone-only event is ignored after
    /// the user has disabled that track; an old stream cannot interrupt a newer run.
    func interrupt(microphoneOnly: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, !microphoneOnly || microphone else { return false }
        active = false
        return true
    }
    func deliver(_ frame: AudioFrame, to receive: (AudioFrame) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard active, frame.track != .microphone || microphone else { return }
        receive(frame)
    }
}
