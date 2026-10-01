import Testing
@testable import CopilotCore

@Test func longSpeechKeepsAudioAcrossBoundary() throws {
    var segmenter = SpeechSegmenter(track: .remote, sampleRate: 100)
    segmenter.maxDuration = 6; segmenter.overlapDuration = 2
    var forced: SpeechWindow?
    for i in 0..<6 {
        let result = segmenter.append(.init(track: .remote, samples: [Float](repeating: 0.2, count: 100), sampleRate: 100, start: Double(i)))
        if result?.isFinal == true { forced = result }
    }
    let first = try #require(forced)
    #expect(first.commitEnd == 5)
    let remaining = segmenter.flush()
    let tail = try #require(remaining)
    #expect(tail.start == 4)
    #expect(tail.samples.count == 200)
    #expect(tail.id != first.id)
    #expect(tail.utteranceID == first.utteranceID)
    _ = segmenter.append(.init(track: .remote, samples: [Float](repeating: 0.2, count: 100), sampleRate: 100, start: 7))
    let following = segmenter.flush()
    #expect(following?.utteranceID != first.utteranceID)
}

@Test func overlapIsRemovedButRealRepetitionsRemain() throws {
    var assembler = WindowTranscriptAssembler()
    let first = SpeechWindow(id: "a", track: .remote, samples: [], start: 0, end: 12, revision: 1, isFinal: true, commitEnd: 11)
    let initial = assembler.assemble(words: [
        .init(text: "We", start: 8, end: 8.5), .init(text: " need", start: 9, end: 9.5),
        .init(text: " validation", start: 10, end: 10.8), .init(text: " before", start: 11, end: 11.7)
    ], window: first)
    #expect(initial?.text == "We need validation")
    let second = SpeechWindow(id: "b", track: .remote, samples: [], start: 10, end: 16, revision: 1, isFinal: true)
    let continued = assembler.assemble(words: [
        .init(text: " validation", start: 0, end: 0.85), .init(text: " before", start: 1, end: 1.7),
        .init(text: " validation", start: 2, end: 2.8)
    ], window: second)
    #expect(continued?.text == "before validation")
}

@Test func partialRevisionsDoNotAdvanceCommittedAudioAndTracksAreIndependent() {
    var assembler = WindowTranscriptAssembler()
    var window = SpeechWindow(id: "a", track: .remote, samples: [], start: 0, end: 2, revision: 1, isFinal: false)
    let words: [RecognizedWord] = [.init(text: "No necrosis", start: 0, end: 1)]
    #expect(assembler.assemble(words: words, window: window)?.text == "No necrosis")
    window.isFinal = true; window.revision = 2
    #expect(assembler.assemble(words: words, window: window)?.text == "No necrosis")
    window.track = .microphone; window.id = "self-a"
    #expect(assembler.assemble(words: words, window: window)?.text == "No necrosis")
}

@Test func emptyOrInvalidDecoderResultsAreDistinctFromAnAlreadyCommittedOverlap() {
    var assembler = WindowTranscriptAssembler()
    let window = SpeechWindow(id: "first", track: .remote, samples: [], start: 0, end: 2, revision: 1, isFinal: true)
    let word = RecognizedWord(text: "Speech", start: 0.1, end: 1.5)
    #expect(assembler.assemble(words: [word], window: window)?.text == "Speech")
    if case .noNewWords = assembler.reconcile(words: [word], window: window) {} else {
        Issue.record("Repeated overlap must not be reported as recognition loss")
    }
    for words: [RecognizedWord] in [[], [.init(text: "invalid", start: .nan, end: 1)],
                                    [.init(text: "invalid", start: 0, end: 0)],
                                    [.init(text: "invalid", start: 1, end: 99)]] {
        if case .missingTranscript = assembler.reconcile(words: words, window: window) {} else {
            Issue.record("Empty or invalid timing must be surfaced as a missing transcript")
        }
    }
    let deferred = SpeechWindow(id: "next", track: .remote, samples: [], start: 2, end: 4,
                                revision: 1, isFinal: true, commitEnd: 3)
    if case .noNewWords = assembler.reconcile(words: [.init(text: "tail", start: 1.1, end: 1.9)], window: deferred) {} else {
        Issue.record("A word deliberately deferred to the next decode is not a recognition failure")
    }
}

@Test func decodedNegationWithZeroDurationIsPreservedWithItsTimedNeighbor() throws {
    // First three timings from the actual short-hint necrosis diagnostic. The decoder
    // said "I'm not entirely"; the old assembler silently removed "I'm not".
    var assembler = WindowTranscriptAssembler()
    let window = SpeechWindow(id: "negative", track: .remote, samples: [], start: 0, end: 1, revision: 1, isFinal: true)
    let result = assembler.assemble(words: [
        .init(text: " I'm", start: 0, end: 0), .init(text: " not", start: 0, end: 0),
        .init(text: " entirely", start: 0, end: 0.18), .init(text: " convinced", start: 0.18, end: 0.6)
    ], window: window)
    let segment = try #require(result)
    #expect(segment.text == "I'm not entirely convinced")
    #expect(segment.timingApproximate == true)
    #expect(segment.start == 0 && segment.end == 0.6)
    var meeting = MeetingSession(); meeting.upsert(segment)
    #expect(MarkdownExport.render(meeting).contains("部分词语缺少独立时长"))
}

@Test func untimedWordsFollowTheirAnchorAcrossOverlapWithoutDuplication() throws {
    var assembler = WindowTranscriptAssembler()
    let first = SpeechWindow(id: "first", track: .remote, samples: [], start: 0, end: 12,
                             revision: 1, isFinal: true, commitEnd: 11)
    let words: [RecognizedWord] = [.init(text: "This is", start: 9, end: 10.5),
        .init(text: " not", start: 10.5, end: 10.5), .init(text: " proven", start: 10.5, end: 11.5)]
    #expect(assembler.assemble(words: words, window: first)?.text == "This is")
    let second = SpeechWindow(id: "second", track: .remote, samples: [], start: 10, end: 14,
                              revision: 1, isFinal: true)
    let next: [RecognizedWord] = [.init(text: "This is", start: 0, end: 0.5),
        .init(text: " not", start: 0.5, end: 0.5), .init(text: " proven", start: 0.5, end: 1.5),
        .init(text: ".", start: 1.5, end: 1.5)]
    let result = assembler.assemble(words: next, window: second)
    let segment = try #require(result)
    #expect(segment.text == "not proven.")
    #expect(segment.timingApproximate == true)
    if case .noNewWords = assembler.reconcile(words: next, window: second) {} else {
        Issue.record("The anchor and its untimed words must be deduplicated together")
    }
}
