import Foundation
import CryptoKit

/// Synthetic or consented text fixtures. Labels and rubrics are never included in a model request.
public struct SemanticCorpus: Codable, Sendable {
    public var schemaVersion: Int
    public var datasetID: String
    public var provenance: String
    public var cases: [SemanticCase]

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 10_000_000 else { throw CopilotError.message("语义测试集超过 10 MB。") }
        let corpus = try JSONDecoder().decode(Self.self, from: data)
        guard corpus.schemaVersion == 1, !corpus.datasetID.isEmpty, !corpus.cases.isEmpty,
              corpus.cases.count <= 1000, Set(corpus.cases.map(\.id)).count == corpus.cases.count else {
            throw CopilotError.message("语义测试集版本、数量或用例 ID 无效。")
        }
        for item in corpus.cases { try item.validate() }
        return corpus
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct SemanticCase: Codable, Sendable {
    public enum ReviewStatus: String, Codable, Sendable { case draft, humanReviewed }
    public enum Partition: String, Codable, Sendable { case development, holdout }
    public struct Review: Codable, Sendable {
        public var status: ReviewStatus
        public var reviewer: String?
        public var reviewedAt: String?
    }
    public struct Fact: Codable, Sendable {
        public var id: String
        public var kind: FactKind
        public var content: String
    }
    public struct Expected: Codable, Sendable {
        public var shouldOfferAnswer: Bool
        public var addressee: Addressee
        public var acceptableKinds: [UtteranceKind]
        public var answerRubric: [String]
        public var forbiddenClaims: [String]
    }
    public var id: String
    public var category: String
    public var partition: Partition
    public var review: Review
    public var identity: String
    public var project: String
    public var terminology: String
    public var facts: [Fact]
    public var events: [TranscriptSegment]
    public var selectedIDs: [String]
    public var expected: Expected

    public func validate() throws {
        guard !id.isEmpty, !category.isEmpty, !events.isEmpty, events.count <= 500,
              !selectedIDs.isEmpty, Set(selectedIDs).count == selectedIDs.count,
              Set(facts.map(\.id)).count == facts.count, facts.allSatisfy({ !$0.id.isEmpty && !$0.content.isEmpty }),
              !expected.acceptableKinds.isEmpty, !expected.answerRubric.isEmpty,
              events.allSatisfy({ !$0.id.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.revision >= 0 && !$0.text.isEmpty }) else {
            throw CopilotError.message("语义用例 \(id) 的结构无效。")
        }
        if review.status == .humanReviewed {
            guard let reviewer = review.reviewer, !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = review.reviewedAt, ISO8601DateFormatter().date(from: date) != nil else {
                throw CopilotError.message("语义用例 \(id) 缺少人工审核人或有效审核时间。")
            }
        }
        let (_, selected) = try materialize()
        guard !expected.shouldOfferAnswer || (expected.addressee == .user && selected.allSatisfy({ $0.track == .remote })) else {
            throw CopilotError.message("语义用例 \(id) 的回应标签与音轨或对象矛盾。")
        }
    }

    /// Replay revisions with the production reducer; stale/duplicate events cannot overwrite a final segment.
    public func materialize() throws -> (MeetingSession, [TranscriptSegment]) {
        var meeting = MeetingSession()
        meeting.profile.identity = identity
        meeting.profile.project = project
        meeting.profile.terminology = terminology
        meeting.profile.facts = facts.map { item in
            var fact = ResearchFact(content: item.content, kind: item.kind, origin: "synthetic fixture")
            fact.id = item.id
            return fact
        }
        meeting.microphoneIncluded = events.contains { $0.track == .microphone }
        for event in events { meeting.upsert(event) }
        let selected = selectedIDs.compactMap { id in meeting.segments.first { $0.id == id } }
        guard selected.count == selectedIDs.count, selected.allSatisfy(\.isFinal) else {
            throw CopilotError.message("语义用例 \(id) 选择了不存在或尚未稳定的转写。")
        }
        return (meeting, selected)
    }
}

public struct SemanticCaseResult: Codable, Sendable {
    public var caseID: String
    public var category: String
    public var partition: SemanticCase.Partition
    public var labelStatus: SemanticCase.ReviewStatus
    public var expected: SemanticCase.Expected
    public var analysis: UtteranceAnalysis?
    public var predictedOfferAnswer: Bool?
    public var candidate: AnswerContent?
    public var answerReview: AnswerReview?
    public var analysisSeconds: Double?
    public var answerSeconds: Double?
    public var analysisFailure: String?
    public var answerFailure: String?
    public var analysisRequestSHA256: String
    public var answerRequestSHA256: String?
    public var humanAnswerAssessment = "pending"
}

public struct SemanticMetrics: Codable, Sendable {
    public var labelStatus: SemanticCase.ReviewStatus
    public var partition: SemanticCase.Partition
    public var attempted: Int
    public var validAnalyses: Int
    public var failedAnalyses: Int
    public var truePositive: Int
    public var falsePositive: Int
    public var trueNegative: Int
    public var falseNegative: Int
    public var addresseeCorrect: Int
    public var kindCorrect: Int
    public var answerCandidates: Int
    public var answerFailures: Int
    public var precision: Double? { ratio(truePositive, truePositive + falsePositive) }
    public var recall: Double? { ratio(truePositive, truePositive + falseNegative) }
    /// Failures do not silently disappear from the coverage or overall correct-decision denominator.
    public var coverage: Double? { ratio(validAnalyses, attempted) }
    public var correctDecisionsPerAttempt: Double? { ratio(truePositive + trueNegative, attempted) }
    private func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }
    private enum CodingKeys: String, CodingKey {
        case labelStatus, partition, attempted, validAnalyses, failedAnalyses, truePositive, falsePositive, trueNegative, falseNegative
        case addresseeCorrect, kindCorrect, answerCandidates, answerFailures, precision, recall, coverage, correctDecisionsPerAttempt
    }
    // Computed rates must be present in the report; decoding recomputes them from the counts.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelStatus = try c.decode(SemanticCase.ReviewStatus.self, forKey: .labelStatus)
        partition = try c.decode(SemanticCase.Partition.self, forKey: .partition)
        attempted = try c.decode(Int.self, forKey: .attempted); validAnalyses = try c.decode(Int.self, forKey: .validAnalyses)
        failedAnalyses = try c.decode(Int.self, forKey: .failedAnalyses)
        truePositive = try c.decode(Int.self, forKey: .truePositive); falsePositive = try c.decode(Int.self, forKey: .falsePositive)
        trueNegative = try c.decode(Int.self, forKey: .trueNegative); falseNegative = try c.decode(Int.self, forKey: .falseNegative)
        addresseeCorrect = try c.decode(Int.self, forKey: .addresseeCorrect); kindCorrect = try c.decode(Int.self, forKey: .kindCorrect)
        answerCandidates = try c.decode(Int.self, forKey: .answerCandidates); answerFailures = try c.decode(Int.self, forKey: .answerFailures)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(labelStatus, forKey: .labelStatus); try c.encode(partition, forKey: .partition)
        try c.encode(attempted, forKey: .attempted); try c.encode(validAnalyses, forKey: .validAnalyses)
        try c.encode(failedAnalyses, forKey: .failedAnalyses)
        try c.encode(truePositive, forKey: .truePositive); try c.encode(falsePositive, forKey: .falsePositive)
        try c.encode(trueNegative, forKey: .trueNegative); try c.encode(falseNegative, forKey: .falseNegative)
        try c.encode(addresseeCorrect, forKey: .addresseeCorrect); try c.encode(kindCorrect, forKey: .kindCorrect)
        try c.encode(answerCandidates, forKey: .answerCandidates); try c.encode(answerFailures, forKey: .answerFailures)
        try c.encode(precision, forKey: .precision); try c.encode(recall, forKey: .recall)
        try c.encode(coverage, forKey: .coverage); try c.encode(correctDecisionsPerAttempt, forKey: .correctDecisionsPerAttempt)
    }
    public init(results: [SemanticCaseResult], status: SemanticCase.ReviewStatus, partition: SemanticCase.Partition) {
        self.labelStatus = status; self.partition = partition
        let group = results.filter { $0.labelStatus == status && $0.partition == partition }
        attempted = group.count
        let valid = group.filter { $0.predictedOfferAnswer != nil && $0.analysisFailure == nil }
        validAnalyses = valid.count; failedAnalyses = attempted - valid.count
        truePositive = valid.filter { $0.expected.shouldOfferAnswer && $0.predictedOfferAnswer == true }.count
        falsePositive = valid.filter { !$0.expected.shouldOfferAnswer && $0.predictedOfferAnswer == true }.count
        trueNegative = valid.filter { !$0.expected.shouldOfferAnswer && $0.predictedOfferAnswer == false }.count
        falseNegative = valid.filter { $0.expected.shouldOfferAnswer && $0.predictedOfferAnswer == false }.count
        addresseeCorrect = valid.filter { $0.analysis?.addressee == $0.expected.addressee }.count
        kindCorrect = valid.filter { item in item.analysis.map { item.expected.acceptableKinds.contains($0.kind) } ?? false }.count
        answerCandidates = group.filter { $0.candidate != nil }.count
        answerFailures = group.filter { $0.answerFailure != nil }.count
    }
}

public struct SemanticBenchmarkReport: Codable, Sendable {
    public var generatedAt = Date()
    public var datasetID: String
    public var corpusSHA256: String
    public var provider: String
    public var fastModel: String
    public var answerModel: String
    public var answersEnabled: Bool
    public var requestedCaseIDs: [String] = []
    public var completed = false
    public var results: [SemanticCaseResult] = []
    public var metrics: [SemanticMetrics] = []
    public var note = "Text-only diagnostics. Draft labels and development data are not held-out human acceptance. Answer review is model-based; human semantic assessment is still required. No ASR, capture, UI concurrency, or end-to-end latency is measured."

    public init(datasetID: String, corpusSHA256: String, configuration: TextProviderConfiguration, answersEnabled: Bool) {
        self.datasetID = datasetID; self.corpusSHA256 = corpusSHA256; self.provider = configuration.kind.rawValue
        self.fastModel = configuration.fastModel; self.answerModel = configuration.answerModel; self.answersEnabled = answersEnabled
    }
    public mutating func append(_ result: SemanticCaseResult) {
        results.append(result)
        metrics = [SemanticCase.ReviewStatus.draft, .humanReviewed].flatMap { status in
            [SemanticCase.Partition.development, .holdout].map { SemanticMetrics(results: results, status: status, partition: $0) }
        }
    }
}

public enum SemanticBenchmark {
    public static func select(_ corpus: SemanticCorpus, includeDrafts: Bool, limit: Int?) throws -> [SemanticCase] {
        if let limit, !(1...1000).contains(limit) { throw CopilotError.message("--limit 必须介于 1 到 1000。") }
        let eligible = corpus.cases.filter { includeDrafts || $0.review.status == .humanReviewed }
        guard !eligible.isEmpty else { throw CopilotError.message("没有经人工审核的语义用例；开发测试需显式添加 --include-drafts。") }
        return Array(eligible.prefix(limit ?? eligible.count))
    }

    public static func run(_ item: SemanticCase, service: IntelligenceService, configuration: TextProviderConfiguration,
                           answers: Bool) async throws -> SemanticCaseResult {
        try item.validate()
        try Task.checkCancellation()
        let (meeting, selected) = try item.materialize()
        let request = try PromptBuilder.request(task: .analysis, meeting: meeting, selected: selected, model: configuration.fastModel)
        var result = SemanticCaseResult(caseID: item.id, category: item.category, partition: item.partition,
            labelStatus: item.review.status, expected: item.expected, analysisRequestSHA256: digest(request))
        let started = Date()
        do {
            let analysis = try await service.perform(UtteranceAnalysis.self, request: request)
            result.analysis = analysis
            try EvidenceValidator.analysis(analysis, meeting: meeting, selected: selected)
            result.predictedOfferAnswer = analysis.requiresResponse && analysis.addressee == .user && selected.allSatisfy { $0.track == .remote }
        } catch {
            try Task.checkCancellation()
            result.analysisFailure = error.localizedDescription
        }
        result.analysisSeconds = Date().timeIntervalSince(started)
        if answers && result.predictedOfferAnswer == true {
            let started = Date()
            do {
                let request = try PromptBuilder.request(task: .answer, meeting: meeting, selected: selected, model: configuration.answerModel)
                result.answerRequestSHA256 = digest(request)
                let candidate = try await service.perform(AnswerContent.self, request: request)
                result.candidate = candidate
                let checked = try EvidenceValidator.answer(candidate, meeting: meeting, selected: selected)
                let review = try await service.reviewAnswer(checked, meeting: meeting, selected: selected, model: configuration.fastModel)
                result.answerReview = review
                try review.requireApproval()
            } catch {
                try Task.checkCancellation()
                result.answerFailure = error.localizedDescription
            }
            result.answerSeconds = Date().timeIntervalSince(started)
        }
        try Task.checkCancellation()
        return result
    }

    private static func digest(_ request: TextRequest) -> String {
        SemanticCorpus.digest(Data((request.system + "\n" + request.input + "\n" + request.model).utf8))
    }
}
