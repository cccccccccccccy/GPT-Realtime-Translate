import Foundation
import CryptoKit
@preconcurrency import WhisperKit
import CopilotCore

public struct SpeechDecodeTrace: Codable, Sendable {
    public var track: AudioTrack
    public var windowStart: Double
    public var windowEnd: Double
    public var isFinal: Bool
    public var language: String?
    public var promptTokenCount: Int
    public var text: String
    public var words: [RecognizedWord]
    /// Decoder token-derived scores for diagnostics only; not calibrated correctness probabilities.
    public var wordScores: [Float]?
    public var windowID: String?
    public var revision: Int?
    public var commitEnd: Double?
}

/// One-shot decode outcome for offline diagnostics; bypasses the streaming pipeline on purpose.
public struct SpeechProbeResult: Codable, Sendable {
    public var text: String
    public var words: [RecognizedWord]
    /// Decoder token-derived scores for diagnostics only; not calibrated correctness probabilities.
    public var wordScores: [Float]
    public var language: String?
    public var promptTokenCount: Int
}

public struct LocalModelResources: Codable, Sendable {
    public var modelFolder: String
    public var tokenizerFolder: String
    public var integrityRecord: String
    public var vocabularySize: Int
    public var embeddingSize: Int
}

public actor WhisperKitProvider: SpeechRecognitionProvider {
    public nonisolated let sampleRate = 16000
    public private(set) var preparedResources: LocalModelResources?
    private var kit: WhisperKit?
    private var segmenters: [AudioTrack: SpeechSegmenter] = [:]
    private var queue = SpeechWorkQueue()
    private var worker: Task<Void, Never>?
    private var accepting = false
    private var preparing = false
    private var assembler = WindowTranscriptAssembler()
    private var languageByTrack: [AudioTrack: (utterance: String, language: String)] = [:]
    private var promptTokensByTrack: [AudioTrack: [Int]] = [:]
    private var trace: (@Sendable (SpeechDecodeTrace) async -> Void)?
    private var emit: @Sendable (SpeechEvent) async -> Void = { _ in }

    public init() {}

    public func prepare(model: String, folder: String, allowDownload: Bool, cacheDirectory: URL? = nil,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> String {
        guard !accepting, !preparing else { throw CopilotError.message("请先停止会议或等待本次准备结束，再更换语音模型。") }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        preparedResources = nil
        if let existing = kit { await existing.unloadModels(); kit = nil }
        let root = try cacheDirectory ?? MeetingRepository.applicationDirectory().appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory: URL
        if folder.isEmpty {
            guard allowDownload else { throw CopilotError.message("请先下载模型或导入已有模型目录。") }
            await progress("正在下载语音模型，首次准备可能需要几分钟…")
            let reporter = ModelDownloadProgress(update: progress)
            do {
                directory = try await ModelAssets.downloadModel(model, root: root) { state in
                    let fraction = state.fractionCompleted
                    Task { await reporter.report(fraction) }
                }
                await reporter.finish()
            } catch {
                await reporter.finish()
                throw error
            }
        } else {
            directory = URL(fileURLWithPath: folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { throw CopilotError.message("本地模型目录不存在。") }
        }
        try Task.checkCancellation()
        let metadata = try WhisperModelMetadata(folder: directory)
        await progress("正在检查本地模型与配套分词资源…")
        try ModelIntegrity.verifyIfPresent(directory)
        let (tokenizerFolder, tokenizer) = try await ModelAssets.prepareTokenizer(modelFolder: directory, root: root,
            metadata: metadata, allowDownload: allowDownload, progress: progress)
        let baseline = try ModelIntegrity.resourceBaseline(model: directory, tokenizer: tokenizerFolder, root: root)
        try Task.checkCancellation()
        await progress("正在编译、加载并预热本地模型；首次可能需要一分钟…")
        let config = WhisperKitConfig(modelFolder: directory.path, tokenizerFolder: root,
                                      segmentSeeker: PromptAlignedSegmentSeeker(),
                                      verbose: false, logLevel: .none, prewarm: false, load: false, download: false)
        let loaded = try await WhisperKit(config)
        // Supplying a validated tokenizer prevents WhisperKit's implicit network fallback.
        loaded.tokenizer = tokenizer
        loaded.textDecoder.isModelMultilingual = metadata.isMultilingual
        do {
            try Task.checkCancellation()
            try await loaded.prewarmModels()
            try Task.checkCancellation()
            try await loaded.loadModels()
            try Task.checkCancellation()
            guard loaded.textDecoder.logitsSize == metadata.vocabularySize,
                  loaded.audioEncoder.embedSize == metadata.embeddingSize else {
                throw CopilotError.message("模型实际维度与 config.json 不一致，未启用。")
            }
            _ = try await loaded.transcribe(audioArray: [Float](repeating: 0, count: sampleRate))
            try Task.checkCancellation()
            try ModelIntegrity.record(baseline)
        } catch {
            await loaded.unloadModels()
            throw error
        }
        kit = loaded
        preparedResources = .init(modelFolder: directory.path, tokenizerFolder: tokenizerFolder.path,
                                  integrityRecord: baseline.path.path, vocabularySize: metadata.vocabularySize,
                                  embeddingSize: metadata.embeddingSize)
        await progress("本地模型已就绪")
        if Task.isCancelled { kit = nil; preparedResources = nil; await loaded.unloadModels(); throw CancellationError() }
        return directory.path
    }

    /// Offline diagnostic: decode a complete sample buffer in one call, outside the streaming
    /// segmenter/queue/assembler. Used to separate model decoding behavior from pipeline effects.
    /// A non-nil promptText is a diagnostic probe condition only; it is never an evaluation input.
    public func decodeProbe(samples: [Float], language: String?, wordTimestamps: Bool,
                            promptText: String?, temperature: Float?, topK: Int?) async throws -> SpeechProbeResult {
        guard !preparing, let kit else { throw CopilotError.message("请先准备本地语音模型。") }
        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.wordTimestamps = wordTimestamps
        options.language = language
        options.detectLanguage = language == nil
        if let temperature {
            options.temperature = temperature
            options.temperatureFallbackCount = 0
            options.temperatureIncrementOnFallback = 0
        }
        if let topK { options.topK = topK }
        if let promptText, let tokenizer = kit.tokenizer {
            options.promptTokens = Array(tokenizer.encode(text: promptText).suffix(192))
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let decodedWords = results.flatMap(\.allWords)
        return SpeechProbeResult(text: results.map(\.text).joined(separator: " "),
                                 words: decodedWords.map { RecognizedWord(text: $0.word, start: Double($0.start), end: Double($0.end)) },
                                 wordScores: decodedWords.map(\.probability),
                                 language: results.first?.language,
                                 promptTokenCount: options.promptTokens?.count ?? 0)
    }

    public func start(silence: Double, terminology: String = "",
                      trace: (@Sendable (SpeechDecodeTrace) async -> Void)? = nil,
                      emit: @escaping @Sendable (SpeechEvent) async -> Void) throws {
        guard !preparing, let kit else { throw CopilotError.message("请先准备本地语音模型。") }
        self.emit = emit
        self.trace = trace
        segmenters = Dictionary(uniqueKeysWithValues: AudioTrack.allCases.map {
            ($0, SpeechSegmenter(track: $0, silenceDuration: silence))
        })
        queue.clear(); assembler = .init(); accepting = true
        languageByTrack = [:]; promptTokensByTrack = [:]
        if let tokenizer = kit.tokenizer, !terminology.isEmpty {
            let glossary = String(terminology.prefix(4000))
            let english = glossary.split(separator: "\n").map { String($0.split(separator: "/").first ?? $0) }.joined(separator: ", ")
            promptTokensByTrack[.remote] = Array(tokenizer.encode(text: english).suffix(192))
            promptTokensByTrack[.microphone] = Array(tokenizer.encode(text: glossary).suffix(192))
        }
    }

    public func accept(_ frame: AudioFrame) async {
        guard accepting else { return }
        if let window = segmenters[frame.track]?.append(frame) { await enqueue(window) }
    }

    private func enqueue(_ window: SpeechWindow) async {
        if let dropped = queue.enqueue(window), dropped.isFinal {
            await emit(.retractPartial(id: dropped.id))
            await emit(.gap(.init(time: dropped.start, reason: "本地识别积压，部分音频未能处理。请使用较小模型或关闭本人音轨。")))
        }
        if worker == nil { worker = Task { await process() } }
    }

    private func process() async {
        while let window = queue.pop(), !Task.isCancelled {
            guard let kit else { break }
            do {
                var options = DecodingOptions()
                options.verbose = false
                options.task = .transcribe
                options.wordTimestamps = true
                // A nil language does not enable detection in WhisperKit's default configuration.
                let utterance = window.utteranceID ?? window.id
                let prior = languageByTrack[window.track]
                options.language = window.track == .remote ? "en" : (prior?.utterance == utterance ? prior?.language : nil)
                options.detectLanguage = options.language == nil
                options.promptTokens = promptTokensByTrack[window.track]
                let results = try await kit.transcribe(audioArray: window.samples, decodeOptions: options)
                if options.detectLanguage, window.end - window.start >= 2.5,
                   let language = results.first?.language, !language.isEmpty {
                    languageByTrack[window.track] = (utterance, language)
                }
                let decodedWords = results.flatMap(\.allWords)
                let words = decodedWords.map { RecognizedWord(text: $0.word, start: Double($0.start), end: Double($0.end)) }
                await trace?(.init(track: window.track, windowStart: window.start, windowEnd: window.end,
                                  isFinal: window.isFinal, language: results.first?.language,
                                  promptTokenCount: options.promptTokens?.count ?? 0,
                                  text: results.map(\.text).joined(separator: " "), words: words,
                                  wordScores: decodedWords.map(\.probability), windowID: window.id,
                                  revision: window.revision, commitEnd: window.commitEnd))
                switch assembler.reconcile(words: words, window: window) {
                case .segment(let segment):
                    await emit(.segment(segment))
                case .noNewWords:
                    if window.isFinal { await emit(.retractPartial(id: window.id)) }
                case .missingTranscript:
                    if window.isFinal {
                        await emit(.retractPartial(id: window.id))
                        await emit(.gap(.init(time: window.start, reason: "\(window.track.title)此段检测到音频活动，但未获得有效转写，可能有遗漏。")))
                    }
                }
            } catch {
                if window.isFinal {
                    await emit(.retractPartial(id: window.id))
                    await emit(.gap(.init(time: window.start, reason: "本地识别失败，此段未能转写。")))
                }
            }
        }
        worker = nil
    }

    public func finish() async {
        accepting = false
        for track in AudioTrack.allCases {
            if let window = segmenters[track]?.flush() { await enqueue(window) }
        }
        await worker?.value
        segmenters.removeAll(); queue.clear()
        languageByTrack = [:]; promptTokensByTrack = [:]
        trace = nil
    }
}

private actor ModelDownloadProgress {
    private var finished = false
    private var percent = -1
    private let update: @Sendable (String) async -> Void
    init(update: @escaping @Sendable (String) async -> Void) { self.update = update }
    func report(_ fraction: Double) async {
        guard !finished, fraction.isFinite else { return }
        let next = Int(min(1, max(0, fraction)) * 100)
        guard next > percent else { return }
        percent = next
        await update("正在下载语音模型：\(next)%")
    }
    func finish() { finished = true }
}

/// Detect changes to a previously loaded model. First-import hashes are a local integrity baseline,
/// not an assertion that an arbitrary imported model is authenticated by its publisher.
enum ModelIntegrity {
    private static let name = "researchcopilot-integrity.json"
    private static func hashes(_ folder: URL) throws -> [String: String] {
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw CopilotError.message("无法读取模型目录。")
        }
        var results: [String: String] = [:]
        for case let file as URL in iterator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CopilotError.message("模型资源包含符号链接，请导入包含实际文件的完整模型目录。") }
            guard values.isRegularFile == true, values.isSymbolicLink != true, file.lastPathComponent != name else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                try Task.checkCancellation(); hasher.update(data: block)
            }
            let relative = String(file.path.dropFirst(folder.path.count + 1))
            results[relative] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard !results.isEmpty else { throw CopilotError.message("模型目录为空。") }
        return results
    }

    static func verifyIfPresent(_ folder: URL) throws {
        let manifest = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        // Legacy manifests covered only acoustic files. A newly bundled tokenizer is verified separately.
        let actual = try hashes(folder).filter { !$0.key.hasPrefix("Tokenizer/") || expected[$0.key] != nil }
        guard actual == expected else { throw CopilotError.message("模型文件与本地完整性记录不一致，请重新导入或下载。") }
    }

    struct Baseline: Sendable {
        let path: URL
        let data: Data
    }

    static func resourceBaseline(model: URL, tokenizer: URL, root: URL) throws -> Baseline {
        var values = try Dictionary(uniqueKeysWithValues: hashes(model).map { ("model/" + $0.key, $0.value) })
        for name in ModelAssets.tokenizerFiles {
            try Task.checkCancellation()
            let data = try Data(contentsOf: tokenizer.appendingPathComponent(name))
            values["tokenizer/" + name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let identity = model.standardizedFileURL.path + "|" + tokenizer.standardizedFileURL.path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = root.appendingPathComponent("ResourceIntegrity/" + key + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))
            guard expected == values else { throw CopilotError.message("模型或分词资源与此前准备时的完整性记录不一致，请重新导入配套资源。") }
        }
        return .init(path: path, data: try JSONEncoder().encode(values))
    }

    static func record(_ baseline: Baseline) throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: baseline.path.path) else { return }
        try FileManager.default.createDirectory(at: baseline.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try baseline.data.write(to: baseline.path, options: [.atomic])
    }
}
