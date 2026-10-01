import Foundation
import Testing
@testable import CopilotCore

private func answerJSON(english: String = "Could you clarify the validation you have in mind?", sources: [String] = ["q"], facts: [String] = []) throws -> AnswerContent {
    let object: [String: Any] = ["sourceIDs": sources, "factIDs": facts, "coreQuestion": "组织学验证", "intent": "clarification",
        "english": english, "chinese": "请澄清验证方式", "shortAnswer": "", "cautiousAnswer": "", "clarification": "",
        "missingInformation": ["validation results"], "warnings": []]
    return try JSONDecoder().decode(AnswerContent.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func inventedNumbersAndUnconfirmedFactReferencesAreRejected() throws {
    var meeting = MeetingSession()
    let q = TranscriptSegment(id: "q", track: .remote, start: 0, end: 4, text: "How will you validate the results histologically?", isFinal: true)
    meeting.upsert(q)
    #expect(throws: CopilotError.self) {
        try EvidenceValidator.answer(answerJSON(english: "We studied 24 animals."), meeting: meeting, selected: [q])
    }
    meeting.profile.facts = [.init(content: "24 animals", kind: .unknown)]
    let fact = meeting.profile.facts[0]
    #expect(throws: CopilotError.self) {
        try EvidenceValidator.answer(answerJSON(english: "We studied 24 animals.", facts: [fact.id]), meeting: meeting, selected: [q])
    }
    let result = try EvidenceValidator.answer(answerJSON(), meeting: meeting, selected: [q])
    #expect(!result.warnings.isEmpty)
}

@Test func correctionsInvalidatePinnedSuggestionsWithoutChangingTheirContent() throws {
    var meeting = MeetingSession()
    let q = TranscriptSegment(id: "q", track: .remote, start: 0, end: 1, text: "Why this time point?", isFinal: true)
    meeting.upsert(q)
    var answer = AnswerSuggestion(sources: [q.reference], content: try answerJSON(), provider: "test", model: "fixture")
    answer.pinned = true; meeting.answers.append(answer)
    meeting.correct(id: q.id, text: "Why this endpoint?")
    #expect(meeting.answers[0].stale)
    #expect(meeting.answers[0].pinned)
    #expect(meeting.answers[0].content.english == answer.content.english)
}

@Test func promptsAndSummariesDoNotTreatAISuggestionsAsActualSpeech() throws {
    var meeting = MeetingSession()
    let q = TranscriptSegment(id: "q", track: .remote, start: 0, end: 1, text: "What is next?", isFinal: true)
    meeting.upsert(q)
    meeting.answers.append(.init(sources: [q.reference], content: try answerJSON(english: "UNSPOKEN_AI_SUGGESTION"), provider: "test", model: "fixture"))
    let request = try PromptBuilder.request(task: .summary, meeting: meeting, selected: [q], model: "fixture")
    #expect(!request.input.contains("UNSPOKEN_AI_SUGGESTION"))
    let invalid = MeetingSummary(topics: [], questions: [], actualAnswers: [.init(text: "The user agreed.", sourceIDs: ["q"], owner: nil, deadline: nil)], decisions: [], actions: [], unresolved: [])
    #expect(throws: CopilotError.self) { try EvidenceValidator.summary(invalid, segments: [q]) }
    let export = MarkdownExport.render(meeting)
    #expect(export.contains("AI 回答建议（不代表实际发言）"))
    #expect(export.contains("未采集，不能确认实际回答"))
}

@Test func realtimeCompletionsUseItemTimingDespiteReordering() throws {
    var reducer = RealtimeTranscriptReducer(track: .remote)
    var meeting = MeetingSession()
    func event(_ text: String) -> Data { Data(text.utf8) }
    _ = try reducer.consume(event(#"{"type":"input_audio_buffer.speech_started","item_id":"a","audio_start_ms":1000}"#), fallbackTime: 1)
    _ = try reducer.consume(event(#"{"type":"input_audio_buffer.speech_started","item_id":"b","audio_start_ms":5000}"#), fallbackTime: 5)
    let eventB = try reducer.consume(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"second"}"#), fallbackTime: 6)
    let eventA = try reducer.consume(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"first"}"#), fallbackTime: 7)
    let b = try #require(eventB)
    let a = try #require(eventA)
    meeting.upsert(b); meeting.upsert(a)
    #expect(meeting.segments.map(\.text) == ["first", "second"])
    let duplicate = try reducer.consume(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"duplicate"}"#), fallbackTime: 8)
    #expect(duplicate == nil)
}
