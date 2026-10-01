import Foundation
import Testing
@testable import CopilotCore

@Test func citationsDistinguishChangedMissingAndLegacySources() {
    var meeting = MeetingSession()
    let old = TranscriptSegment(id: "q", track: .remote, start: 50, end: 54, text: "old wording", revision: 1, isFinal: true)
    meeting.upsert(old)
    meeting.correct(id: "q", text: "corrected wording")
    let citations = CitationResolver.resolve(["q", "missing", "q"], in: meeting, snapshots: [old])
    #expect(citations.count == 2)
    #expect(citations[0].changed && citations[0].snapshot?.text == "old wording")
    #expect(citations[0].current?.text == "corrected wording")
    #expect(citations[1].current == nil && citations[1].label == "来源不可用")
    let legacy = CitationResolver.resolve(["q"], in: meeting)
    #expect(legacy[0].expectedRevision == nil && legacy[0].label.contains("版本未记录"))
}

@Test func exportedCitationsHaveLocalAnchorsAndRetainOldEvidence() throws {
    var meeting = MeetingSession()
    let source = TranscriptSegment(id: "unsafe\"](<script>)", track: .remote, start: 0, end: 3, text: "Original question", revision: 1, isFinal: true)
    meeting.upsert(source)
    meeting.summary = MeetingSummary(topics: [.init(text: "Topic", sourceIDs: [source.id])], questions: [], actualAnswers: [], decisions: [], actions: [], unresolved: [])
    meeting.summaryEvidence = [source]
    meeting.correct(id: source.id, text: "Corrected question")
    let exported = MarkdownExport.render(meeting)
    #expect(exported.contains("Original question") && exported.contains("Corrected question"))
    #expect(exported.contains("已更正"))
    #expect(!exported.contains("<script>"))
    let regex = try NSRegularExpression(pattern: #"\]\(#(transcript-[a-f0-9]{64})\)"#)
    let ns = exported as NSString
    let match = try #require(regex.firstMatch(in: exported, range: NSRange(location: 0, length: ns.length)))
    let anchor = ns.substring(with: match.range(at: 1))
    #expect(exported.contains("<a id=\"\(anchor)\"></a>"))
    let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(meeting))
    #expect(restored.summaryEvidence?.first?.text == "Original question")
}

@Test func partialSpeechCannotBecomeSummaryEvidenceAndEmptyAssignmentsStayUnknown() {
    let partial = TranscriptSegment(id: "p", track: .microphone, start: 1, end: 2, text: "incomplete", isFinal: false)
    let item = SummaryEntry(text: "Unconfirmed", sourceIDs: ["p"], owner: "  ", deadline: "\n")
    let summary = MeetingSummary(topics: [], questions: [], actualAnswers: [item], decisions: [], actions: [], unresolved: [])
    #expect(throws: CopilotError.self) { try EvidenceValidator.summary(summary, segments: [partial]) }
    #expect(item.displayedOwner == "待确认" && item.displayedDeadline == "待确认")
}

@Test func evidenceSnapshotsRoundTripAndOlderAnswersRemainReadable() throws {
    let source = TranscriptSegment(id: "q", track: .remote, start: 0, end: 1, text: "Why?", revision: 1, isFinal: true)
    let fact = ResearchFact(content: "Histology comparison planned", kind: .confirmedPlan)
    let content = AnswerContent(sourceIDs: ["q"], factIDs: [fact.id], coreQuestion: "Why?", intent: "explain",
        english: "We plan a comparison.", chinese: "计划比较。", shortAnswer: "A comparison.",
        cautiousAnswer: "A comparison.", clarification: "Which comparison?", missingInformation: [], warnings: [])
    let answer = AnswerSuggestion(sources: [source.reference], content: content, provider: "Fixture", model: "offline",
                                  evidenceSegments: [source], evidenceFacts: [fact])
    let encoded = try JSONEncoder().encode(answer)
    let decoded = try JSONDecoder().decode(AnswerSuggestion.self, from: encoded)
    #expect(decoded.evidenceFacts == [fact] && decoded.evidenceSegments == [source])
    var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    old.removeValue(forKey: "evidenceSegments"); old.removeValue(forKey: "evidenceFacts")
    let legacy = try JSONDecoder().decode(AnswerSuggestion.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.evidenceFacts == nil && legacy.evidenceSegments == nil)
    #expect(legacy.sources == [source.reference])
}
