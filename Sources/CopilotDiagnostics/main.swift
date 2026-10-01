import Foundation
import AVFoundation
import CopilotCore
import CopilotSpeech
import Darwin
import CryptoKit

@main
struct CopilotDiagnostics {
    static func main() async {
        do { try await run() }
        catch { print("Diagnostic failed: \(error.localizedDescription)"); exit(1) }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["prepare-model", "transcribe", "decode-probe", "test-text", "validate-semantics", "test-semantics"].contains(command) else {
            print("""
            CopilotDiagnostics prepare-model --cache DIRECTORY [--model MODEL] [--folder DIRECTORY]
            CopilotDiagnostics transcribe --cache DIRECTORY --folder DIRECTORY --audio FILE --report FILE [--reference TEXT_FILE] [--critical-terms JSON_FILE] [--microphone-audio FILE | --dual] [--microphone-reference TEXT_FILE] [--realtime] [--decode-trace] [--use-glossary | --hint-file TEXT_FILE]
            CopilotDiagnostics decode-probe --cache DIRECTORY --folder DIRECTORY --audio FILE --report FILE [--start SEC] [--end SEC] [--language CODE] [--no-word-timestamps] [--prompt-text TEXT | --prompt-file FILE] [--temperature F] [--top-k N] [--repeat N]
            CopilotDiagnostics test-text --provider deepSeek --report FILE [--check-answer-guard]
            CopilotDiagnostics validate-semantics --corpus FILE
            CopilotDiagnostics test-semantics --corpus FILE --provider deepSeek --report FILE [--include-drafts] [--limit N] [--answers]
            Audio commands use the actual WhisperKit pipeline with explicit test fixtures, no capture or paid API.
            test-text uses the provider's default endpoint/models and existing Keychain entry. Four synthetic functions include a separate answer review and incur API usage. --check-answer-guard also checks rejection of an invented study claim. No meetings or research profiles are read.
            validate-semantics is offline and does not access credentials. test-semantics sends the explicit corpus to the selected provider and incurs API usage. Labels/rubrics stay local. Drafts require --include-drafts; --answers also generates and reviews answers for predicted response cases. Reports are checkpointed after each case.
            """)
            return
        }
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        if command == "validate-semantics" || command == "test-semantics" {
            guard let path = option("--corpus") else { throw CopilotError.message("--corpus FILE is required") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let corpus = try SemanticCorpus.read(data)
            let reviewed = corpus.cases.filter { $0.review.status == .humanReviewed }.count
            print("Corpus \(corpus.datasetID): \(corpus.cases.count) cases, \(reviewed) human-reviewed; SHA256 \(SemanticCorpus.digest(data))")
            if command == "validate-semantics" { return }
            guard let kind = option("--provider").flatMap(TextProviderKind.init(rawValue:)), kind == .deepSeek || kind == .openAI,
                  let path = option("--report") else { throw CopilotError.message("Specify --provider deepSeek or openAI and --report FILE") }
            if let value = option("--limit"), Int(value) == nil { throw CopilotError.message("--limit must be an integer") }
            let selected = try SemanticBenchmark.select(corpus, includeDrafts: args.contains("--include-drafts"), limit: option("--limit").flatMap(Int.init))
            let configuration = TextProviderConfiguration(kind: kind)
            _ = try configuration.validatedBaseURL()
            let answers = args.contains("--answers")
            var report = SemanticBenchmarkReport(datasetID: corpus.datasetID, corpusSHA256: SemanticCorpus.digest(data), configuration: configuration, answersEnabled: answers)
            report.requestedCaseIDs = selected.map(\.id)
            let output = URL(fileURLWithPath: path)
            guard output.standardizedFileURL.resolvingSymlinksInPath() != URL(fileURLWithPath: option("--corpus")!).standardizedFileURL.resolvingSymlinksInPath() else {
                throw CopilotError.message("测试报告不能覆盖语义测试集。")
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Validate output access before requesting credentials or incurring API usage.
            try encoder.encode(report).write(to: output, options: .atomic)
            let service = IntelligenceService(provider: HTTPTextProvider(configuration: configuration, key: try CredentialStore().apiKey(for: configuration)))
            for item in selected {
                let result = try await SemanticBenchmark.run(item, service: service, configuration: configuration, answers: answers)
                report.append(result)
                try encoder.encode(report).write(to: output, options: .atomic)
                print("\(item.id): analysis \(result.analysisFailure == nil ? "returned" : "FAILED"), answer \(result.answerFailure == nil ? (result.candidate == nil ? "not requested" : "reviewed") : "FAILED")")
            }
            report.completed = true
            try encoder.encode(report).write(to: output, options: .atomic)
            print("Semantic report: \(output.path). Human answer assessment remains pending.")
            guard report.results.allSatisfy({ $0.analysisFailure == nil && $0.answerFailure == nil }) else {
                throw CopilotError.message("语义测试有调用、校验或内容核对失败，已保留逐例报告；其他分类指标请另行审阅。")
            }
            return
        }
        if command == "test-text" {
            guard let kind = option("--provider").flatMap(TextProviderKind.init(rawValue:)), kind != .compatible,
                  let report = option("--report") else { throw CopilotError.message("Specify --provider deepSeek or openAI and --report FILE") }
            let configuration = TextProviderConfiguration(kind: kind)
            _ = try configuration.validatedBaseURL()
            let service = IntelligenceService(provider: HTTPTextProvider(configuration: configuration,
                key: try CredentialStore().apiKey(for: configuration)))
            let recorder = TextDiagnosticRecorder()
            try await TextServiceDiagnostics.run(configuration: configuration, service: service,
                                                verifyRejection: args.contains("--check-answer-guard")) { result in
                await recorder.append(result)
                print("\(result.id): \(result.failure == nil ? "checks passed" : "FAILED") (\(String(format: "%.2f", result.seconds))s)")
            }
            let results = await recorder.results
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(results)
            let output = URL(fileURLWithPath: report)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
            print("Synthetic diagnostic report: \(output.path)")
            guard results.allSatisfy({ $0.failure == nil }) else {
                throw CopilotError.message("部分示例内容检查未通过，失败详情已保存到报告。")
            }
            return
        }
        guard let cachePath = option("--cache") else { throw CopilotError.message("--cache is required") }
        var samples: [Float] = []
        var ownSamples: [Float]?
        var reference: String?
        var microphoneReference: String?
        var criticalTerms: [String] = []
        var fixtureSHA256: [String: String] = [:]
        var terminology = ""
        if command == "transcribe" {
            guard let audioPath = option("--audio"), option("--report") != nil else {
                throw CopilotError.message("--audio and --report are required")
            }
            samples = try readFixture(URL(fileURLWithPath: audioPath))
            ownSamples = try option("--microphone-audio").map { try readFixture(URL(fileURLWithPath: $0)) }
            reference = try option("--reference").map { try String(contentsOfFile: $0, encoding: .utf8) }
            microphoneReference = try option("--microphone-reference").map { try String(contentsOfFile: $0, encoding: .utf8) }
            if let path = option("--critical-terms") {
                guard let reference else { throw CopilotError.message("--critical-terms requires --reference; labels are evaluated locally only") }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 100_000 else { throw CopilotError.message("Critical phrase file exceeds the diagnostic limit") }
                criticalTerms = try JSONDecoder().decode([String].self, from: data)
                guard !criticalTerms.isEmpty, criticalTerms.count <= 200,
                      Set(criticalTerms).count == criticalTerms.count,
                      criticalTerms.allSatisfy({ $0.count <= 200 && RecognitionMetrics.containsPhrase($0, in: reference) }) else {
                    throw CopilotError.message("Critical phrases must be unique, nonempty literal phrases present in the reference")
                }
            }
            guard !(args.contains("--use-glossary") && option("--hint-file") != nil) else {
                throw CopilotError.message("Select either --use-glossary or --hint-file, not both")
            }
            if let path = option("--hint-file") {
                terminology = try String(contentsOfFile: path, encoding: .utf8)
                guard !terminology.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, terminology.count <= 4000 else {
                    throw CopilotError.message("ASR hint file must contain 1–4000 characters")
                }
            } else if args.contains("--use-glossary") { terminology = ResearchProfile().terminology }
            for flag in ["--audio", "--reference", "--critical-terms", "--microphone-audio", "--microphone-reference", "--hint-file"] {
                if let path = option(flag) { fixtureSHA256[String(flag.dropFirst(2))] = try fixtureDigest(URL(fileURLWithPath: path)) }
            }
        }
        var probeClipStart = 0.0, probeClipEnd = 0.0
        var probePrompt: String?, probePromptFile: String?, probePromptSHA256: String?
        if command == "decode-probe" {
            guard let audioPath = option("--audio"), option("--report") != nil else {
                throw CopilotError.message("--audio and --report are required")
            }
            samples = try readFixture(URL(fileURLWithPath: audioPath))
            fixtureSHA256["audio"] = try fixtureDigest(URL(fileURLWithPath: audioPath))
            func clipBound(_ name: String, _ valid: @escaping (Double) -> Bool) throws -> Double? {
                guard let raw = option(name) else { return nil }
                guard let value = Double(raw), valid(value) else { throw CopilotError.message("\(name) has an invalid numeric value") }
                return value
            }
            probeClipStart = try clipBound("--start", { $0 >= 0 }) ?? 0
            probeClipEnd = try clipBound("--end", { $0 > 0 }) ?? Double(samples.count) / 16000
            guard probeClipEnd > probeClipStart else { throw CopilotError.message("--end must be greater than --start") }
            guard !(option("--prompt-text") != nil && option("--prompt-file") != nil) else {
                throw CopilotError.message("Select either --prompt-text or --prompt-file, not both")
            }
            if let path = option("--prompt-file") {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else {
                    throw CopilotError.message("Probe prompt file must contain 1–2000 characters")
                }
                probePrompt = text; probePromptFile = path
                probePromptSHA256 = try fixtureDigest(URL(fileURLWithPath: path))
            } else { probePrompt = option("--prompt-text") }
        }
        let cache = URL(fileURLWithPath: cachePath, isDirectory: true).standardizedFileURL
        let provider = WhisperKitProvider()
        let preparationStart = Date()
        let folder = try await provider.prepare(model: option("--model") ?? "large-v3-v20240930_626MB",
                                               folder: option("--folder") ?? "", allowDownload: command == "prepare-model",
                                               cacheDirectory: cache) { message in print(message) }
        let prepareSeconds = Date().timeIntervalSince(preparationStart)
        print("Model ready after \(String(format: "%.2f", prepareSeconds)) seconds")
        if command == "prepare-model" {
            try folder.write(to: cache.appendingPathComponent("prepared-model-path.txt"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(await provider.preparedResources).write(to: cache.appendingPathComponent("prepared-assets.json"), options: .atomic)
            print("Prepared model: \(folder)")
            return
        }
        if command == "decode-probe" {
            let reportPath = option("--report")!
            let languageArg = option("--language")
            let language = languageArg == "auto" ? nil : (languageArg ?? "en")
            let wordTimestamps = !args.contains("--no-word-timestamps")
            func numericArg(_ name: String) throws -> Double? {
                guard let raw = option(name) else { return nil }
                guard let value = Double(raw) else { throw CopilotError.message("\(name) must be numeric") }
                return value
            }
            let temperature = try numericArg("--temperature").map { Float($0) }
            if let temperature { guard (0...1.5).contains(temperature) else { throw CopilotError.message("--temperature must be 0–1.5") } }
            let topK = try numericArg("--top-k").map { Int($0) }
            if let topK { guard topK > 0 else { throw CopilotError.message("--top-k must be positive") } }
            let repeatCount = Int(try numericArg("--repeat") ?? 1)
            guard (1...20).contains(repeatCount) else { throw CopilotError.message("--repeat must be 1–20") }
            let startIndex = max(0, Int((probeClipStart * 16000).rounded(.down)))
            let endIndex = min(samples.count, Int((probeClipEnd * 16000).rounded(.up)))
            guard startIndex < endIndex else { throw CopilotError.message("Probe clip is empty") }
            let clip = Array(samples[startIndex..<endIndex])
            if probePrompt != nil { print("Note: the prompt is a diagnostic probe condition, not an evaluation input.") }
            var runs: [SpeechProbeResult] = []
            for iteration in 1...repeatCount {
                let result = try await provider.decodeProbe(samples: clip, language: language,
                                                            wordTimestamps: wordTimestamps, promptText: probePrompt,
                                                            temperature: temperature, topK: topK)
                runs.append(result)
                print("probe \(iteration)/\(repeatCount): \(result.text)")
            }
            let report = DecodeProbeReport(note: "One-shot decode outside the streaming pipeline; diagnostic probe only. Prompt conditions are not evaluation inputs and cannot be used to claim recognition quality. Word scores are decoder-derived and not calibrated correctness probabilities.",
                                           fixtureSHA256: fixtureSHA256.merging(["prompt-file": probePromptSHA256].compactMapValues { $0 }) { _, new in new },
                                           clipStartSeconds: probeClipStart, clipEndSeconds: probeClipEnd,
                                           language: language, wordTimestamps: wordTimestamps,
                                           temperature: temperature, topK: topK,
                                           promptFile: probePromptFile, promptText: probePrompt,
                                           modelFolder: folder, preparationSeconds: prepareSeconds,
                                           preparedResources: await provider.preparedResources, runs: runs)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = URL(fileURLWithPath: reportPath)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: output, options: .atomic)
            print("Probe report: \(output.path)")
            return
        }
        guard let reportPath = option("--report") else { throw CopilotError.message("--report is required") }
        let tracks: [AudioTrack] = args.contains("--dual") || ownSamples != nil ? [.remote, .microphone] : [.remote]
        let frameCount = max(samples.count, ownSamples?.count ?? 0)
        let recorder = BenchmarkRecorder()
        let traceCallback: @Sendable (SpeechDecodeTrace) async -> Void = { trace in await recorder.trace(trace) }
        let decodeTrace = args.contains("--decode-trace") ? traceCallback : nil
        try await provider.start(silence: 1.0, terminology: terminology, trace: decodeTrace) { event in await recorder.receive(event) }
        let start = Date()
        await recorder.begin(at: start)
        let chunkSize = 1600
        for offset in stride(from: 0, to: frameCount, by: chunkSize) {
            for track in tracks {
                let source = track == .microphone ? ownSamples ?? samples : samples
                guard offset < source.count else { continue }
                let slice = Array(source[offset..<min(offset + chunkSize, source.count)])
                await provider.accept(.init(track: track, samples: slice, sampleRate: 16000, start: Double(offset) / 16000))
            }
            if args.contains("--realtime") {
                let target = Double(min(offset + chunkSize, frameCount)) / 16000
                let remaining = target - Date().timeIntervalSince(start)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
        }
        await provider.finish()
        let duration = Double(frameCount) / 16000
        var report = await recorder.report(audioDuration: duration, elapsed: Date().timeIntervalSince(start),
                                           prepareSeconds: prepareSeconds, modelFolder: folder,
                                           realtime: args.contains("--realtime"), tracks: tracks)
        report.glossaryConditioning = !terminology.isEmpty
        report.preparedResources = await provider.preparedResources
        report.fixtureSHA256 = fixtureSHA256
        if let reference {
            let hypothesis = report.finalSegments.filter { $0.track == .remote }.map(\.text).joined(separator: " ")
            report.remoteMetrics = .init(reference: reference, hypothesis: hypothesis, criticalTerms: criticalTerms)
        }
        if let reference = microphoneReference {
            let hypothesis = report.finalSegments.filter { $0.track == .microphone }.map(\.text).joined(separator: " ")
            report.microphoneMetrics = .init(reference: reference, hypothesis: hypothesis)
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { report.processPeakResidentBytes = Int64(usage.ru_maxrss) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: [.atomic])
        print("Wrote \(report.finalSegments.count) final segments; \(report.gaps.count) gaps; report: \(output.path)")
        if !criticalTerms.isEmpty, let metrics = report.remoteMetrics {
            print("Critical phrases preserved: \(criticalTerms.count - metrics.missingCriticalTerms.count)/\(criticalTerms.count); missing: \(metrics.missingCriticalTerms.joined(separator: "; "))")
        }
    }

    static func fixtureDigest(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readFixture(_ path: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: path)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard file.length > 0, duration.isFinite, duration <= 60 * 30, file.length <= Int64(UInt32.max) else {
            throw CopilotError.message("Fixture is empty or exceeds the 30-minute diagnostic limit")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CopilotError.message("Cannot allocate fixture buffer")
        }
        try file.read(into: input)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 64) else {
            throw CopilotError.message("Cannot convert fixture")
        }
        let source = FixtureInput(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in source.take(status) }
        if let error { throw error }
        guard let values = output.floatChannelData?[0] else { throw CopilotError.message("Fixture contains no PCM samples") }
        return Array(UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
    }
}

private final class FixtureInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { status.pointee = .endOfStream; return nil }
        self.buffer = nil; status.pointee = .haveData; return buffer
    }
}

private struct BenchmarkReport: Codable, Sendable {
    var generatedAt: Date
    var modelFolder: String
    var preparationSeconds: Double
    var audioDuration: Double
    var processingWallSeconds: Double
    var realtimeInput: Bool
    var tracks: [AudioTrack]
    var firstPartialSeconds: Double?
    var finalSegments: [TranscriptSegment]
    var finalDelays: [Double]
    var gaps: [RecordingGap]
    var remoteMetrics: RecognitionMetrics?
    var microphoneMetrics: RecognitionMetrics?
    var processPeakResidentBytes: Int64?
    var decodeTraces: [SpeechDecodeTrace] = []
    var glossaryConditioning = false
    var preparedResources: LocalModelResources?
    var fixtureSHA256: [String: String]?
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var pipelineVersion = "whisperkit-1.1.0-untimed-word-groups-v3"
    var note = "Synthetic or explicitly supplied diagnostic fixture; not medical meeting quality or 90-minute acceptance. Peak RSS includes model preparation, excludes other processes, and is not total GPU/ANE memory."
}

private actor TextDiagnosticRecorder {
    private(set) var results: [TextDiagnosticResult] = []
    func append(_ result: TextDiagnosticResult) { results.append(result) }
}

private actor BenchmarkRecorder {
    private var meeting = MeetingSession()
    private var origin = Date()
    private var firstPartial: Double?
    private var delays: [Double] = []
    private var traces: [SpeechDecodeTrace] = []
    func trace(_ trace: SpeechDecodeTrace) { if traces.count < 500 { traces.append(trace) } }
    func begin(at date: Date) { origin = date }
    func receive(_ event: SpeechEvent) {
        switch event {
        case .segment(let segment):
            meeting.upsert(segment)
            let elapsed = Date().timeIntervalSince(origin)
            if !segment.isFinal && firstPartial == nil { firstPartial = elapsed }
            if segment.isFinal { delays.append(elapsed - segment.end) }
        case .gap(let gap): meeting.gaps.append(gap)
        case .retractPartial(let id): meeting.segments.removeAll { $0.id == id && !$0.isFinal }
        case .status(let status): print(status)
        }
    }
    func report(audioDuration: Double, elapsed: Double, prepareSeconds: Double, modelFolder: String,
                realtime: Bool, tracks: [AudioTrack]) -> BenchmarkReport {
        .init(generatedAt: Date(), modelFolder: modelFolder, preparationSeconds: prepareSeconds, audioDuration: audioDuration,
              processingWallSeconds: elapsed, realtimeInput: realtime, tracks: tracks, firstPartialSeconds: firstPartial,
              finalSegments: meeting.segments.filter(\.isFinal), finalDelays: realtime ? delays : [], gaps: meeting.gaps,
              decodeTraces: traces)
    }
}

private struct DecodeProbeReport: Codable {
    var note: String
    var fixtureSHA256: [String: String]
    var clipStartSeconds: Double
    var clipEndSeconds: Double
    var language: String?
    var wordTimestamps: Bool
    var temperature: Float?
    var topK: Int?
    var promptFile: String?
    var promptText: String?
    var modelFolder: String
    var preparationSeconds: Double
    var preparedResources: LocalModelResources?
    var runs: [SpeechProbeResult]
}
