import Foundation

public struct TextDiagnosticResult: Identifiable, Codable, Sendable {
    public var id: String
    public var model: String
    public var seconds: Double
    public var preview: String
    public var responseJSON: String?
    public var reviewJSON: String?
    public var failure: String?
}

/// Exercises production requests with fixed synthetic data, never the user's meeting/profile.
public enum TextServiceDiagnostics {
    public static func run(configuration: TextProviderConfiguration, service: IntelligenceService,
                           verifyRejection: Bool = false,
                           onResult: @escaping @Sendable (TextDiagnosticResult) async -> Void) async throws {
        var meeting = MeetingSession()
        meeting.profile = ResearchProfile()
        meeting.profile.identity = "Dr. Chen, the researcher being addressed in this synthetic connectivity test"
        meeting.profile.project = "Synthetic test only. No real study information or results."
        meeting.profile.facts = [.init(content: "We plan to compare imaging findings with histology.", kind: .confirmedPlan)]
        meeting.microphoneIncluded = true
        let question = TranscriptSegment(id: "diagnostic-question", track: .remote, start: 0, end: 5,
            text: "Dr. Chen, could you explain how you plan to validate these imaging changes using histology?", isFinal: true)
        let answer = TranscriptSegment(id: "diagnostic-actual-answer", track: .microphone, start: 6, end: 10,
            text: "Our plan is to compare imaging findings with histology. No results are supplied in this synthetic test.", isFinal: true)
        meeting.segments = [question, answer]

        for task in [IntelligenceTask.translation, .analysis, .answer, .summary] {
            try Task.checkCancellation()
            let model = (task == .translation || task == .analysis) ? configuration.fastModel : configuration.answerModel
            let selected = task == .summary ? meeting.segments : [question]
            let request = try PromptBuilder.request(task: task, meeting: meeting, selected: selected, model: model)
            let start = Date()
            var preview = ""
            var responseJSON: String?
            var reviewJSON: String?
            var failure: String?
            do {
            switch task {
            case .translation:
                let result = try await service.perform(TranslationResult.self, request: request)
                responseJSON = try encode(result)
                preview = result.translation
                try EvidenceValidator.sources(result.sourceIDs, in: selected)
                guard containsChinese(result.translation) else { throw CopilotError.invalidResponse }
            case .analysis:
                let result = try await service.perform(UtteranceAnalysis.self, request: request)
                responseJSON = try encode(result)
                preview = result.coreMeaning + " / " + result.intent + "\n回应：\(result.requiresResponse)，对象：\(result.addressee.rawValue)。" + result.reason
                try EvidenceValidator.sources(result.sourceIDs, in: selected)
                guard result.requiresResponse, result.addressee == .user else {
                    throw CopilotError.message("接口已返回结果，但未正确识别测试中直接向用户提出的问题。")
                }
                guard containsChinese(result.coreMeaning), containsChinese(result.intent) else {
                    throw CopilotError.message("接口响应正常，但理解字段没有按要求使用中文。")
                }
            case .answer:
                let result = try await service.perform(AnswerContent.self, request: request)
                responseJSON = try encode(result)
                preview = result.english + "\n" + result.chinese
                let checked = try EvidenceValidator.answer(result, meeting: meeting, selected: selected)
                let review = try await service.reviewAnswer(checked, meeting: meeting, selected: selected, model: configuration.fastModel)
                reviewJSON = try encode(review)
                try review.requireApproval()
                let lower = checked.english.lowercased()
                let spoken = [checked.english, checked.shortAnswer, checked.cautiousAnswer].joined(separator: " ").lowercased()
                guard checked.chinese.contains("我们"), checked.chinese.contains("计划"), !checked.factIDs.isEmpty,
                      lower.contains("histolog"), ["plan", "aim", "intend", "propos"].contains(where: lower.contains),
                      !lower.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"),
                      !["supplied information", "supplied evidence", "information provided", "provided information", "not yet", "haven't", "have not"].contains(where: spoken.contains) else {
                    throw CopilotError.message("回答通过结构检查，但未正确使用测试中已确认的研究计划或中英文格式。")
                }
            case .summary:
                let result = try await service.perform(MeetingSummary.self, request: request)
                responseJSON = try encode(result)
                preview = (result.questions + result.actualAnswers).map(\.text).joined(separator: "\n")
                try EvidenceValidator.summary(result, segments: selected)
                guard !result.questions.isEmpty, !result.actualAnswers.isEmpty else {
                    throw CopilotError.message("接口已返回结果，但遗漏了测试中实际记录的问题或本人回答。")
                }
                guard (result.questions + result.actualAnswers).allSatisfy({ containsChinese($0.text) }) else {
                    throw CopilotError.message("总结通过结构检查，但未按要求使用中文。")
                }
            }
            } catch {
                try Task.checkCancellation()
                failure = error.localizedDescription
            }
            try Task.checkCancellation()
            await onResult(.init(id: task.rawValue, model: model, seconds: Date().timeIntervalSince(start),
                                 preview: preview, responseJSON: responseJSON, reviewJSON: reviewJSON, failure: failure))
        }
        if verifyRejection {
            try Task.checkCancellation()
            // A prior real response invented these endpoints from the glossary. Keep it as a negative fixture.
            let unsafe = AnswerContent(sourceIDs: [question.id], factIDs: meeting.profile.facts.map(\.id),
                coreQuestion: "组织学验证计划", intent: "说明验证方式",
                english: "We plan to compare imaging findings with histology. Our planned endpoints include tissue necrosis and perfusion changes.",
                chinese: "我们计划将影像与组织学比较，计划的终点包括组织坏死和灌注变化。",
                shortAnswer: "We plan to compare imaging findings with histology.",
                cautiousAnswer: "Our planned endpoints include tissue necrosis and perfusion changes.",
                clarification: "Which aspect would you like us to clarify?", missingInformation: [], warnings: [])
            let started = Date()
            var reviewJSON: String?
            var failure: String?
            do {
                let review = try await service.reviewAnswer(unsafe, meeting: meeting, selected: [question], model: configuration.fastModel)
                reviewJSON = try encode(review)
                guard !review.approved, !review.issues.isEmpty else {
                    throw CopilotError.message("内容核对未拦截虚构的研究终点，不能视为通过。")
                }
            } catch {
                try Task.checkCancellation()
                failure = error.localizedDescription
            }
            await onResult(.init(id: "answer_guard", model: configuration.fastModel,
                seconds: Date().timeIntervalSince(started), preview: "负例：应拒绝把坏死、灌注擅自扩写为已确认的研究终点。",
                responseJSON: try encode(unsafe), reviewJSON: reviewJSON, failure: failure))
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
}
