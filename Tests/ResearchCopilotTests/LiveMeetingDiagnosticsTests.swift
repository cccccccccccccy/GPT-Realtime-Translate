import Testing
import Foundation
import AVFoundation
import CryptoKit
import CopilotCore
import CopilotSpeech
@testable import ResearchCopilot

/// Opt-in only: uses local model files and the existing default DeepSeek credential.
/// Normal test runs never load audio/models, access credentials, or call a network API.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RESEARCH_COPILOT_LIVE_E2E"] == "1"),
      .timeLimit(.minutes(10)))
@MainActor func syntheticLocalSpeechToDeepSeekMeeting() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let outputPath = ProcessInfo.processInfo.environment["RESEARCH_COPILOT_E2E_OUTPUT"] else {
        throw CopilotError.message("Set an explicit empty RESEARCH_COPILOT_E2E_OUTPUT directory.")
    }
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
        throw CopilotError.message("Live diagnostic output must be empty; previous runs are never overwritten.")
    }
    let cache = root.appendingPathComponent(".build/models")
    let model = try String(contentsOf: cache.appendingPathComponent("prepared-model-path.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for name in ["timepoint", "necrosis"] {
        let fixture = root.appendingPathComponent(".build/fixtures/\(name).aiff")
        let referenceURL = root.appendingPathComponent("Fixtures/ASR/\(name).txt")
        let labelsURL = root.appendingPathComponent("Fixtures/ASR/\(name)-critical.json")
        let samples = try LiveFixtureAudio.read(fixture)
        let reference = try String(contentsOf: referenceURL, encoding: .utf8)
        let labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: labelsURL))
        let capture = LiveFixtureCapture()
        let starter = LiveLocalSpeechStarter(cache: cache, model: model)
        let storage = LiveMemoryStorage()
        let controller = MeetingController(audio: capture, speechStarter: starter, repositoryFactory: { storage })
        await controller.initialize()
        controller.configuration.cloudTextEnabled = true
        controller.configuration.captureMicrophone = false
        controller.configuration.automaticAnswers = true
        guard controller.configuration.speechProvider == .whisperKit,
              controller.selectedText.kind == .deepSeek,
              controller.selectedText.baseURL == "https://api.deepseek.com" else {
            throw CopilotError.message("This diagnostic is restricted to local ASR and the default DeepSeek endpoint.")
        }
        controller.profile.identity = "Synthetic medical researcher"
        controller.profile.project = "Synthetic development test. No study facts, completed results, or confirmed plans are supplied."
        controller.profile.facts = []
        controller.meeting.title = "Synthetic integration: " + name
        await controller.refreshApplications()
        var report = LiveMeetingReport(fixture: name, configuration: controller.configuration)
        report.fixtureSHA256 = try ["audio": fixture, "reference": referenceURL, "critical-terms": labelsURL]
            .mapValues { SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() }
        report.audioSeconds = Double(samples.count) / 16000
        report.lastVoiceSeconds = LiveFixtureAudio.lastVoiceEnd(samples)
        let reportURL = output.appendingPathComponent(name + ".json")
        try report.save(reportURL)
        await controller.start()
        report.modelPreparationSeconds = starter.preparationSeconds
        report.preparedResources = starter.resources
        if controller.isRecording {
            let playback = Task { try await capture.play(samples) }
            let deadline = capture.elapsed + report.audioSeconds + 70
            var sawAnswerBusy = false
            var lastCheckpoint = -1.0
            while capture.elapsed < deadline {
                let now = capture.elapsed
                let final = controller.meeting.segments.filter(\.isFinal)
                if report.firstTextSeconds == nil, controller.meeting.segments.contains(where: { !$0.text.isEmpty }) {
                    report.firstTextSeconds = now
                }
                if report.firstPartialSeconds == nil, controller.meeting.segments.contains(where: { !$0.isFinal && !$0.text.isEmpty }) {
                    report.firstPartialSeconds = now
                }
                if report.firstFinalSeconds == nil, !final.isEmpty { report.firstFinalSeconds = now }
                if report.firstTranslationSeconds == nil, final.contains(where: { $0.translationRevision == $0.revision }) {
                    report.firstTranslationSeconds = now
                }
                if report.analysisSeconds == nil, let analysis = controller.analysis {
                    report.analysisSeconds = now; report.analysis = analysis
                }
                if report.firstEnglishDraftSeconds == nil, StreamingDraft.english(in: controller.answerDraft) != nil {
                    report.firstEnglishDraftSeconds = now
                }
                sawAnswerBusy = sawAnswerBusy || controller.answerBusy
                if let answer = controller.currentAnswer, report.answerPublishedSeconds == nil {
                    report.answerPublishedSeconds = now
                    report.automaticAnswerPublished = report.manualAnswerRequestedSeconds == nil
                    report.publishedAnswer = answer
                }
                if let error = controller.errorMessage, !report.errors.contains(error) { report.errors.append(error) }
                // Exercise the same manual action only when automatic analysis explicitly
                // declines or fails. Its timing is never counted as automatic latency.
                let automaticDeclined = controller.analysis.map({ !$0.requiresResponse || $0.addressee != .user }) == true
                    || controller.textStatus == "理解分析暂不可用"
                if now > report.audioSeconds + 2, !final.isEmpty, !sawAnswerBusy,
                   report.manualAnswerRequestedSeconds == nil, automaticDeclined {
                    report.manualAnswerRequestedSeconds = now
                    report.manualReason = controller.analysis == nil ? "Automatic analysis unavailable" : "Automatic analysis did not request a response to the user"
                    controller.generateAnswer(selected: final)
                    sawAnswerBusy = controller.answerBusy
                }
                report.meeting = controller.meeting
                if now - lastCheckpoint >= 1 { try report.save(reportURL); lastCheckpoint = now }
                if now > report.audioSeconds + 2, !final.isEmpty,
                   final.allSatisfy({ $0.translationRevision == $0.revision }),
                   (controller.currentAnswer != nil || (sawAnswerBusy && !controller.answerBusy)) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            playback.cancel()
            do { try await playback.value } catch is CancellationError {} catch { controller.fail(error) }
            await controller.stop()
            let summaryStart = ContinuousClock.now
            await controller.summarize()
            report.summarySeconds = LiveFixtureCapture.seconds(summaryStart.duration(to: .now))
        }
        if let error = controller.errorMessage, !report.errors.contains(error) { report.errors.append(error) }
        report.meeting = controller.meeting
        report.latestAnalysis = controller.analysis
        report.metrics = .init(reference: reference, hypothesis: controller.meeting.segments.filter { $0.isFinal && $0.track == .remote }.map(\.text).joined(separator: " "), criticalTerms: labels)
        report.finished = true
        let final = controller.meeting.segments.filter(\.isFinal)
        report.translationComplete = !final.isEmpty && final.allSatisfy { $0.translationRevision == $0.revision }
        report.remoteOnly = !controller.meeting.microphoneIncluded && !final.isEmpty && final.allSatisfy { $0.track == .remote }
        report.answerAfterLastVoiceSeconds = report.answerPublishedSeconds.map { $0 - report.lastVoiceSeconds }
        report.summaryProduced = controller.meeting.summary != nil
        report.savedToIsolatedMemory = await storage.lastSaved?.id == controller.meeting.id
        report.pipelineOutputComplete = report.analysis != nil && report.answerPublishedSeconds != nil
            && report.translationComplete && report.summaryProduced && report.savedToIsolatedMemory && report.remoteOnly
        try report.save(reportURL)
        try MarkdownExport.render(controller.meeting).write(to: output.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        controller.configuration.cloudTextEnabled = false
        _ = await controller.prepareForTermination()
        print("Synthetic integration \(name): answer=\(report.answerPublishedSeconds != nil), automatic=\(report.automaticAnswerPublished), summary=\(report.summaryProduced), criticalMissing=\(report.metrics?.missingCriticalTerms.count ?? -1)")
        #expect(report.pipelineOutputComplete,
                "Integration output missing; retained the complete diagnostic report.")
    }
}

private struct LiveMeetingReport: Codable {
    var scope = "Synthetic audio through production meeting controller, local ASR and DeepSeek; fake capture and memory storage; no real Zoom, microphone or UI-render latency validation"
    var fixture: String
    var configuration: AppConfiguration
    var fixtureSHA256: [String: String] = [:]
    var audioSeconds = 0.0
    var lastVoiceSeconds = 0.0
    var voiceThreshold = 0.008
    var pollingSeconds = 0.05
    var modelPreparationSeconds: Double?
    var preparedResources: LocalModelResources?
    var firstTextSeconds: Double?
    var firstPartialSeconds: Double?
    var firstFinalSeconds: Double?
    var firstTranslationSeconds: Double?
    var analysisSeconds: Double?
    var firstEnglishDraftSeconds: Double?
    var answerPublishedSeconds: Double?
    var answerAfterLastVoiceSeconds: Double?
    var manualAnswerRequestedSeconds: Double?
    var manualReason: String?
    var automaticAnswerPublished = false
    var summarySeconds: Double?
    var summaryProduced = false
    var translationComplete = false
    var remoteOnly = false
    var pipelineOutputComplete = false
    var savedToIsolatedMemory = false
    var finished = false
    var errors: [String] = []
    var analysis: UtteranceAnalysis?
    var latestAnalysis: UtteranceAnalysis?
    var publishedAnswer: AnswerSuggestion?
    var metrics: RecognitionMetrics?
    var meeting: MeetingSession?
    func save(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

@MainActor private final class LiveFixtureCapture: AudioCapturing {
    var hasOutstandingStream = false
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private var origin = ContinuousClock.now
    var elapsed: Double { Self.seconds(origin.duration(to: .now)) }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    func applications() async throws -> [CaptureApplication] { [.init(id: 1, name: "Synthetic fixture", bundleID: "test.fixture")] }
    func start(applicationID: Int32, microphone: Bool, sampleRate: Int,
               onFrame: @escaping @Sendable (AudioFrame) -> Void,
               onFailure: @escaping @Sendable (CaptureIssue) -> Void) async throws {
        guard !microphone, sampleRate == 16000 else { throw CopilotError.message("Fixture capture supports remote 16 kHz only.") }
        self.onFrame = onFrame; origin = .now; hasOutstandingStream = true
    }
    func play(_ samples: [Float]) async throws {
        let padded = samples + [Float](repeating: 0, count: 32000)
        for offset in stride(from: 0, to: padded.count, by: 1600) {
            try Task.checkCancellation()
            guard let onFrame else { return }
            let end = min(offset + 1600, padded.count)
            onFrame(.init(track: .remote, samples: Array(padded[offset..<end]), sampleRate: 16000, start: Double(offset) / 16000))
            let remaining = Double(end) / 16000 - elapsed
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
    }
    func stopForwarding() { onFrame = nil }
    func stop() async throws { stopForwarding(); hasOutstandingStream = false }
    func disableMicrophone() async throws {}
}

@MainActor private final class LiveLocalSpeechStarter: SpeechSessionStarting {
    let cache: URL
    let model: String
    var preparationSeconds: Double?
    var resources: LocalModelResources?
    init(cache: URL, model: String) { self.cache = cache; self.model = model }
    func start(configuration: AppConfiguration, profile: ResearchProfile, local: WhisperKitProvider,
               localReady: Bool, emit: @escaping @Sendable (SpeechEvent) async -> Void) async throws -> any SpeechRecognitionProvider {
        let before = ContinuousClock.now
        _ = try await local.prepare(model: configuration.localModel, folder: model, allowDownload: false, cacheDirectory: cache) { _ in }
        preparationSeconds = LiveFixtureCapture.seconds(before.duration(to: .now))
        resources = await local.preparedResources
        return try await SpeechSessionStarter().start(configuration: configuration, profile: profile, local: local, localReady: true, emit: emit)
    }
}

private actor LiveMemoryStorage: MeetingStorage {
    var lastSaved: MeetingSession?
    func save(_ meeting: MeetingSession) { lastSaved = meeting }
    func load(_ id: UUID) throws -> MeetingSession { throw CopilotError.message("Fixture storage has no history.") }
    func delete(_ id: UUID) {}
    func listIDs() -> [UUID] { [] }
    func saveConfiguration(_ configuration: AppConfiguration) {}
    func loadConfiguration() -> AppConfiguration? { nil }
    func saveProfile(_ profile: ResearchProfile) {}
    func loadProfile() -> ResearchProfile? { nil }
}

private enum LiveFixtureAudio {
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate < 60,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CopilotError.message("Expected a nonempty synthetic fixture under one minute.")
        }
        try file.read(into: input)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 64
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CopilotError.message("Fixture conversion unavailable.") }
        let source = LiveFixtureBuffer(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in source.take(status) }
        guard error == nil, let values = output.floatChannelData?[0], output.frameLength > 0 else { throw CopilotError.message("Fixture conversion failed.") }
        return Array(UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
    }
    static func lastVoiceEnd(_ samples: [Float]) -> Double {
        var last = 0
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let end = min(offset + 1600, samples.count)
            let rms = sqrt(samples[offset..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end - offset))
            if rms >= 0.008 { last = end }
        }
        return Double(last) / 16000
    }
}

private final class LiveFixtureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { status.pointee = .noDataNow; return nil }
        self.buffer = nil; status.pointee = .haveData; return buffer
    }
}
