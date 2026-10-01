import Foundation
import Testing
@testable import CopilotCore

@Test func answerReviewFailsClosedOnRejectionOrContradictoryVerdict() throws {
    #expect(throws: CopilotError.self) { try AnswerReview(approved: false, issues: []).requireApproval() }
    #expect(throws: CopilotError.self) {
        try AnswerReview(approved: true, issues: ["中文没有翻译英文回答"]).requireApproval()
    }
    try AnswerReview(approved: true, issues: []).requireApproval()
}

@Test func reviewEvidenceExcludesGlossaryAndUnconfirmedStudyMaterial() throws {
    var meeting = MeetingSession()
    meeting.profile.project = "UNCONFIRMED_PROJECT_DETAIL"
    meeting.profile.terminology = "GLOSSARY_NOT_A_STUDY_PLAN"
    meeting.profile.facts = [.init(content: "UNKNOWN_FACT", kind: .unknown),
                             .init(content: "CONFIRMED_PLAN", kind: .confirmedPlan)]
    let question = TranscriptSegment(id: "q", track: .remote, start: 0, end: 1, text: "What is your plan?", isFinal: true)
    let candidate = AnswerContent(sourceIDs: ["q"], factIDs: [], coreQuestion: "计划", intent: "询问",
        english: "Could you clarify?", chinese: "请问具体指哪方面？", shortAnswer: "Could you clarify?",
        cautiousAnswer: "Could you clarify?", clarification: "Could you clarify?", missingInformation: [], warnings: [])
    let request = try PromptBuilder.answerReview(candidate, meeting: meeting, selected: [question], model: "fixture")
    #expect(request.input.contains("CONFIRMED_PLAN"))
    #expect(!request.input.contains("UNKNOWN_FACT"))
    #expect(!request.input.contains("UNCONFIRMED_PROJECT_DETAIL"))
    #expect(!request.input.contains("GLOSSARY_NOT_A_STUDY_PLAN"))
}
