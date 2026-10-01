import Foundation
import Testing
@testable import CopilotCore

private func semanticFixtures() throws -> SemanticCorpus {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try SemanticCorpus.read(Data(contentsOf: root.appendingPathComponent("Fixtures/Semantics/cases.json")))
}

private actor SemanticStub: TextModelProvider {
    var requests: [TextRequest] = []
    let failAnalysis: Bool
    init(failAnalysis: Bool = false) { self.failAnalysis = failAnalysis }
    func complete(_ request: TextRequest, onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        requests.append(request)
        switch request.schemaName {
        case "analysis":
            if failAnalysis { throw CopilotError.message("Synthetic unavailable service") }
            return #"{"sourceIDs":["selected"],"kind":"QUESTION","coreMeaning":"时间点及验证","intent":"寻求解释","requiresResponse":true,"addressee":"user","reason":"直接询问"}"#
        case "answer":
            return #"{"sourceIDs":["selected"],"factIDs":["fact-1"],"coreQuestion":"时间点及验证","intent":"解释","english":"We plan to compare imaging with histology.","chinese":"我们计划比较影像和组织学。","shortAnswer":"We plan to compare imaging with histology.","cautiousAnswer":"We plan to compare imaging with histology.","clarification":"Which aspect would you like us to clarify?","missingInformation":[],"warnings":[]}"#
        default:
            // An explicit rejection must be retained even when the response has a valid JSON schema.
            return #"{"approved":false,"issues":["合成核对拒绝样本"]}"#
        }
    }
}

@Test func semanticDraftsCannotMasqueradeAsReviewedAcceptance() throws {
    let corpus = try semanticFixtures()
    #expect(corpus.cases.count == 60)
    #expect(Set(corpus.cases.map(\.category)).count == 9)
    #expect(corpus.cases.allSatisfy { $0.review.status == .draft && $0.partition == .development })
    #expect(throws: CopilotError.self) { try SemanticBenchmark.select(corpus, includeDrafts: false, limit: nil) }
    #expect(try SemanticBenchmark.select(corpus, includeDrafts: true, limit: 2).count == 2)
    var forged = corpus.cases[0]
    forged.review.status = .humanReviewed
    #expect(throws: CopilotError.self) { try forged.validate() }
    var duplicate = corpus
    duplicate.cases.append(duplicate.cases[0])
    #expect(throws: CopilotError.self) { try SemanticCorpus.read(JSONEncoder().encode(duplicate)) }
}

@Test func semanticReplayUsesCurrentFinalsAndDoesNotLeakLabels() async throws {
    let corpus = try semanticFixtures()
    let revision = try #require(corpus.cases.first { $0.id == "long_revision-04" })
    let (_, selected) = try revision.materialize()
    #expect(selected.count == 1)
    #expect(selected[0].revision == 1)
    #expect(selected[0].text.contains("48 hours"))
    #expect(!selected[0].text.contains("24 hours"))
    var item = corpus.cases[0]
    item.expected.answerRubric = ["SECRET_EXPECTED_LABEL_DO_NOT_SEND"]
    item.expected.forbiddenClaims = ["SECRET_FORBIDDEN_CLAIM_DO_NOT_SEND"]
    let stub = SemanticStub()
    let result = try await SemanticBenchmark.run(item, service: .init(provider: stub), configuration: .init(kind: .deepSeek), answers: true)
    let requests = await stub.requests
    #expect(requests.map(\.schemaName) == ["analysis", "answer", "answer_review"])
    #expect(requests.allSatisfy { !$0.input.contains("SECRET_") && !$0.system.contains("SECRET_") })
    #expect(requests.allSatisfy { !$0.input.contains("answerRubric") && !$0.input.contains("shouldOfferAnswer") })
    #expect(result.predictedOfferAnswer == true)
    #expect(result.candidate != nil)
    #expect(result.answerReview?.approved == false)
    #expect(result.answerFailure != nil)
    #expect(result.humanAnswerAssessment == "pending")
}

@Test func semanticMetricsExposeFailuresAndSeparateDraftsFromHoldout() async throws {
    let item = try semanticFixtures().cases[0]
    let config = TextProviderConfiguration(kind: .deepSeek)
    let success = try await SemanticBenchmark.run(item, service: .init(provider: SemanticStub()), configuration: config, answers: false)
    let failure = try await SemanticBenchmark.run(item, service: .init(provider: SemanticStub(failAnalysis: true)), configuration: config, answers: false)
    var report = SemanticBenchmarkReport(datasetID: "test", corpusSHA256: "test", configuration: config, answersEnabled: false)
    report.append(success); report.append(failure)
    let draft = try #require(report.metrics.first { $0.labelStatus == .draft && $0.partition == .development })
    #expect(draft.attempted == 2 && draft.validAnalyses == 1 && draft.failedAnalyses == 1)
    #expect(draft.precision == 1 && draft.recall == 1)
    #expect(draft.coverage == 0.5 && draft.correctDecisionsPerAttempt == 0.5)
    let holdout = try #require(report.metrics.first { $0.labelStatus == .humanReviewed && $0.partition == .holdout })
    #expect(holdout.attempted == 0 && holdout.precision == nil && holdout.recall == nil)
    let roundTrip = try JSONDecoder().decode(SemanticBenchmarkReport.self, from: JSONEncoder().encode(report))
    #expect(roundTrip.metrics[0].coverage == 0.5)
    #expect(roundTrip.results[1].analysisFailure != nil)
}

@Test func cancelledSemanticBenchmarkMakesNoRequests() async throws {
    let item = try semanticFixtures().cases[0]
    let provider = SemanticStub()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SemanticBenchmark.run(item, service: .init(provider: provider), configuration: .init(kind: .deepSeek), answers: true)
    }
    do { _ = try await task.value; Issue.record("Cancelled semantic run returned a result") }
    catch is CancellationError { }
    #expect(await provider.requests.isEmpty)
}

@Test func analysisCanCiteItsActualContextButNotInventedOrUnselectedSpeech() throws {
    var (meeting, selected) = try semanticFixtures().cases[0].materialize()
    let references = (selected + PromptBuilder.relevantContext(in: meeting, selected: selected)).map(\.reference)
    var analysis = UtteranceAnalysis(sourceIDs: ["context", "selected"], kind: .question,
        coreMeaning: "问题", intent: "询问", requiresResponse: true, addressee: .user, reason: "前文指定对象")
    try EvidenceValidator.analysis(analysis, meeting: meeting, selected: selected)
    #expect(meeting.containsCurrent(references))
    analysis.sourceIDs = ["context"]
    #expect(throws: CopilotError.self) { try EvidenceValidator.analysis(analysis, meeting: meeting, selected: selected) }
    analysis.sourceIDs = ["selected", "invented-source"]
    #expect(throws: CopilotError.self) { try EvidenceValidator.analysis(analysis, meeting: meeting, selected: selected) }
    meeting.correct(id: "context", text: "This question is for Dr. Patel, not Dr. Chen.")
    #expect(!meeting.containsCurrent(references))
}

@Test func actualDeepSeekContextResponsesPassTheCorrectedEvidenceCheck() throws {
    struct Observed: Decodable { var caseID: String; var analysis: UtteranceAnalysis }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/Semantics/context-responses.json"))
    let responses = try JSONDecoder().decode([Observed].self, from: data)
    let corpus = try semanticFixtures()
    #expect(responses.count == 4)
    for observed in responses {
        let item = try #require(corpus.cases.first { $0.id == observed.caseID })
        let (meeting, selected) = try item.materialize()
        // These exact responses were incorrectly rejected by the selected-only check in the first live run.
        #expect(throws: CopilotError.self) { try EvidenceValidator.sources(observed.analysis.sourceIDs, in: selected) }
        try EvidenceValidator.analysis(observed.analysis, meeting: meeting, selected: selected)
    }
}
