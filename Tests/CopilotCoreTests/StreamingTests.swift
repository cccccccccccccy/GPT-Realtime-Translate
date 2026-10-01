import Foundation
import Testing
@testable import CopilotCore

@Test func sseHandlesUTF8CRLFAndMultipleDataLines() throws {
    let input = ": keepalive\r\nevent: transcript\r\ndata: 中文\r\ndata: second\r\n\r\n"
    var decoder = SSEDecoder(); var events: [SSEEvent] = []
    for byte in input.utf8 { if let event = try decoder.append(byte) { events.append(event) } }
    #expect(events == [.init(name: "transcript", data: "中文\nsecond")])
}

@Test func streamedDraftHandlesIncompleteEscapesWithoutClaimingCompletion() {
    #expect(StreamingDraft.english(in: #"{"english":"We can clarify"#) == "We can clarify")
    #expect(StreamingDraft.english(in: #"{"english":"Line\nTwo"}"#) == "Line\nTwo")
    #expect(StreamingDraft.english(in: #"{"english":"Hello \u4f"#) == "Hello ")
    #expect(StreamingDraft.english(in: #"{"sourceIDs":["q"]}"#) == nil)
}

@Test func truncatedCompletionIsNeverReady() throws {
    var stream = TextStreamAccumulator(apiProtocol: .chatCompletions)
    _ = try stream.consume(.init(name: "message", data: #"{"choices":[{"delta":{"content":"{}"}}]}"#))
    #expect(throws: CopilotError.self) { try stream.validatedText() }
    #expect(throws: CopilotError.self) {
        try stream.consume(.init(name: "message", data: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#))
    }
}

@Test func completedChatAndResponsesAreParsedSeparately() throws {
    var chat = TextStreamAccumulator(apiProtocol: .chatCompletions)
    _ = try chat.consume(.init(name: "message", data: #"{"choices":[{"delta":{"content":"{\"translation\":\"你好\"}"},"finish_reason":"stop"}]}"#))
    _ = try chat.consume(.init(name: "message", data: "[DONE]"))
    #expect(try chat.validatedText() == #"{"translation":"你好"}"#)
    var responses = TextStreamAccumulator(apiProtocol: .responses)
    _ = try responses.consume(.init(name: "message", data: #"{"type":"response.output_text.delta","delta":"{}"}"#))
    _ = try responses.consume(.init(name: "message", data: #"{"type":"response.completed","response":{"status":"completed"}}"#))
    #expect(try responses.validatedText() == "{}")
}

@Test func excessiveSSEEventsAreBounded() {
    var decoder = SSEDecoder(); decoder.maxEventBytes = 8
    #expect(throws: CopilotError.self) { for byte in "data: aaaaaaaaaaaa".utf8 { _ = try decoder.append(byte) } }
}

@Test func silenceDoesNotCreateTranscriptWindows() {
    var segmenter = SpeechSegmenter(track: .remote, sampleRate: 100)
    for i in 0..<500 {
        #expect(segmenter.append(.init(track: .remote, samples: [Float](repeating: 0, count: 100), sampleRate: 100, start: Double(i))) == nil)
    }
    #expect(segmenter.flush() == nil)
}

@Test func voiceFinalizesAfterSilenceAndKeepsTrackIdentity() {
    var segmenter = SpeechSegmenter(track: .microphone, sampleRate: 100, silenceDuration: 0.8)
    _ = segmenter.append(.init(track: .microphone, samples: [Float](repeating: 0.2, count: 100), sampleRate: 100, start: 0))
    let final = segmenter.append(.init(track: .microphone, samples: [Float](repeating: 0, count: 100), sampleRate: 100, start: 1))
    #expect(final?.isFinal == true)
    #expect(final?.track == .microphone)
    #expect(segmenter.flush() == nil)
}

@Test func queueCoalescesPartialAndReportsOverflow() {
    func window(_ id: String, revision: Int, final: Bool) -> SpeechWindow {
        .init(id: id, track: .remote, samples: [0.1], start: 0, end: 1, revision: revision, isFinal: final)
    }
    var queue = SpeechWorkQueue(capacity: 1)
    #expect(queue.enqueue(window("a", revision: 1, final: false)) == nil)
    #expect(queue.enqueue(window("a", revision: 2, final: true)) == nil)
    #expect(queue.enqueue(window("b", revision: 1, final: true))?.id == "b")
    #expect(queue.pop()?.revision == 2)
}

@Test func providerUsesCorrectProtocolAndNeverStoresOpenAIResponses() throws {
    let config = TextProviderConfiguration(kind: .openAI)
    let provider = HTTPTextProvider(configuration: config, key: "test-not-a-real-key")
    let request = TextRequest(model: config.fastModel, system: "Return JSON", input: "test", schema: try PromptBuilder.schema(for: .translation), schemaName: "translation")
    let built = try provider.makeURLRequest(request)
    #expect(built.url?.absoluteString == "https://api.openai.com/v1/responses")
    let data = try #require(built.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["store"] as? Bool == false)
    #expect(body["messages"] == nil)
    #expect(body["input"] != nil)
}
