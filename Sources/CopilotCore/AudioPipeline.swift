import Foundation

public struct AudioFrame: Sendable {
    public var track: AudioTrack
    public var samples: [Float]
    public var sampleRate: Int
    public var start: Double
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
    public init(track: AudioTrack, samples: [Float], sampleRate: Int, start: Double) {
        self.track = track; self.samples = samples; self.sampleRate = sampleRate; self.start = start
    }
}

public struct SpeechWindow: Sendable {
    public var id: String
    public var track: AudioTrack
    public var samples: [Float]
    public var start: Double
    public var end: Double
    public var revision: Int
    public var isFinal: Bool
    /// A forced window boundary holds its trailing audio for the next overlapping decode.
    public var commitEnd: Double? = nil
    /// Remains stable across overlapping windows until a silence boundary or explicit flush.
    public var utteranceID: String? = nil
}

/// A bounded, per-track VAD segmenter. Inference consumes snapshots off the capture callback.
public struct SpeechSegmenter: Sendable {
    public let sampleRate: Int
    public var silenceDuration: Double
    public var threshold: Float
    public var maxDuration: Double = 12
    public var partialInterval: Double = 1.2
    public var overlapDuration: Double = 2
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var id = UUID().uuidString
    private var utteranceID = UUID().uuidString
    private var start = 0.0
    private var end = 0.0
    private var silence = 0.0
    private var nextPartial = 1.2
    private var revision = 0
    private var voicedDuration = 0.0
    private var track: AudioTrack

    public init(track: AudioTrack, sampleRate: Int = 16000, silenceDuration: Double = 1,
                threshold: Float = 0.008) {
        self.track = track; self.sampleRate = sampleRate
        self.silenceDuration = silenceDuration; self.threshold = threshold
    }

    public mutating func append(_ frame: AudioFrame) -> SpeechWindow? {
        guard frame.track == track, frame.sampleRate == sampleRate, !frame.samples.isEmpty else { return nil }
        let energy = sqrt(frame.samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(frame.samples.count))
        let voiced = energy >= threshold
        if samples.isEmpty && !voiced {
            preRoll.append(contentsOf: frame.samples)
            preRoll = Array(preRoll.suffix(sampleRate / 4))
            return nil
        }
        if samples.isEmpty {
            start = max(0, frame.start - Double(preRoll.count) / Double(sampleRate))
            samples = preRoll; preRoll.removeAll(keepingCapacity: true)
        }
        samples.append(contentsOf: frame.samples)
        end = frame.start + frame.duration
        silence = voiced ? 0 : silence + frame.duration
        if voiced { voicedDuration += frame.duration }
        let duration = Double(samples.count) / Double(sampleRate)
        if silence >= silenceDuration { return flush() }
        if duration >= maxDuration {
            revision += 1
            var window = snapshot(final: true)
            let overlap = min(overlapDuration, maxDuration / 3)
            window.commitEnd = end - overlap / 2
            let tail = Array(samples.suffix(Int(overlap * Double(sampleRate))))
            let previousEnd = end
            let continuingUtterance = utteranceID
            reset()
            utteranceID = continuingUtterance
            samples = tail; start = previousEnd - Double(tail.count) / Double(sampleRate); end = previousEnd
            voicedDuration = Double(tail.count) / Double(sampleRate)
            nextPartial = voicedDuration + partialInterval
            return window
        }
        if duration >= nextPartial && voicedDuration >= 0.2 {
            revision += 1; nextPartial = duration + partialInterval
            return snapshot(final: false)
        }
        return nil
    }

    public mutating func flush() -> SpeechWindow? {
        defer { reset() }
        guard voicedDuration >= 0.2 else { return nil }
        revision += 1
        return snapshot(final: true)
    }

    private func snapshot(final: Bool) -> SpeechWindow {
        .init(id: id, track: track, samples: samples, start: start, end: end, revision: revision, isFinal: final,
              utteranceID: utteranceID)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true); preRoll.removeAll(keepingCapacity: true)
        id = UUID().uuidString; silence = 0; revision = 0; voicedDuration = 0; nextPartial = partialInterval
        utteranceID = UUID().uuidString
    }
}

public enum SpeechEvent: Sendable {
    case segment(TranscriptSegment)
    case retractPartial(id: String)
    case gap(RecordingGap)
    case status(String)
}

public struct RecognizedWord: Codable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// Keeps overlap decisions tied to audio time; a repeated word spoken later must be preserved.
public enum WindowTranscriptResult: Sendable {
    case segment(TranscriptSegment)
    /// Valid timed words were already committed or deferred to the next overlapping window.
    case noNewWords
    /// The decoder returned no usable timed words for a window selected by VAD.
    case missingTranscript
}

public struct WindowTranscriptAssembler: Sendable {
    private var committedThrough: [AudioTrack: Double] = [:]
    private struct TimedGroup {
        var text: String
        var start: Double
        var end: Double
        var approximate = false
    }
    public init() {}
    public mutating func assemble(words: [RecognizedWord], window: SpeechWindow) -> TranscriptSegment? {
        if case .segment(let segment) = reconcile(words: words, window: window) { return segment }
        return nil
    }
    public mutating func reconcile(words: [RecognizedWord], window: SpeechWindow) -> WindowTranscriptResult {
        let committed = committedThrough[window.track] ?? -Double.infinity
        let cut = window.commitEnd ?? window.end
        let valid = words.filter { word in
            word.start.isFinite && word.end.isFinite && word.end >= word.start && word.start >= -0.03
                && word.end <= window.end - window.start + 0.03
                && !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // DTW can give real decoded words (including "not") zero duration. Dropping those
        // words changes meaning. Keep them with the next timed word, or the previous one
        // at the tail. The entire group shares its anchor's overlap/commit decision.
        var groups: [TimedGroup] = []
        var untimed = ""
        for word in valid {
            if word.end == word.start { untimed += word.text; continue }
            groups.append(.init(text: untimed + word.text, start: word.start, end: word.end,
                                approximate: !untimed.isEmpty))
            untimed = ""
        }
        guard !groups.isEmpty else { return .missingTranscript }
        if !untimed.isEmpty {
            groups[groups.count - 1].text += untimed
            groups[groups.count - 1].approximate = true
        }
        let accepted = groups.filter { word in
            let start = window.start + word.start, end = window.start + word.end
            // Use the midpoint to absorb small timing shifts in a re-decoded overlap.
            return (start + end) / 2 > committed + 0.03 && (!window.isFinal || end <= cut + 0.03)
        }
        guard let first = accepted.first, let last = accepted.last else { return .noNewWords }
        let text = accepted.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let start = max(window.start + first.start, max(0, committed.isFinite ? committed : 0))
        let end = max(start, min(window.end, window.start + last.end))
        if window.isFinal { committedThrough[window.track] = end }
        var segment = TranscriptSegment(id: window.id, track: window.track, start: start, end: end, text: text,
                                        revision: window.revision, isFinal: window.isFinal)
        if accepted.contains(where: \.approximate) { segment.timingApproximate = true }
        return .segment(segment)
    }
}

public protocol SpeechRecognitionProvider: Actor {
    var sampleRate: Int { get }
    func accept(_ frame: AudioFrame) async
    func finish() async
}

/// Coalesces partials, keeps finals, and explicitly reports overload instead of unbounded latency.
public struct SpeechWorkQueue: Sendable {
    public var capacity: Int
    public private(set) var windows: [SpeechWindow] = []
    public init(capacity: Int = 6) { self.capacity = max(1, capacity) }
    @discardableResult public mutating func enqueue(_ window: SpeechWindow) -> SpeechWindow? {
        if let i = windows.firstIndex(where: { $0.id == window.id }) {
            if window.revision > windows[i].revision { windows[i] = window }
            return nil
        }
        if windows.count >= capacity {
            if let partial = windows.firstIndex(where: { !$0.isFinal }) { windows.remove(at: partial) }
            else { return window }
        }
        windows.append(window)
        return nil
    }
    public mutating func pop() -> SpeechWindow? { windows.isEmpty ? nil : windows.removeFirst() }
    public mutating func clear() { windows.removeAll() }
}
