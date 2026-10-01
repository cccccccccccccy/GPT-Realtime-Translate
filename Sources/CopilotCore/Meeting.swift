import Foundation

public enum AudioTrack: String, Codable, Sendable, CaseIterable {
    case remote
    case microphone
    public var title: String { self == .remote ? "远端发言" : "我的发言" }
}

public struct SourceReference: Codable, Hashable, Sendable {
    public var id: String
    public var revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var track: AudioTrack
    public var start: Double
    public var end: Double
    public var text: String
    public var revision: Int
    public var isFinal: Bool
    public var manuallyCorrected: Bool = false
    public var translation: String?
    public var translationRevision: Int?
    /// Some decoded words had no duration and were grouped with a neighboring timed word.
    public var timingApproximate: Bool?
    public var reference: SourceReference { .init(id: id, revision: revision) }

    public init(id: String = UUID().uuidString, track: AudioTrack, start: Double,
                end: Double, text: String, revision: Int = 0, isFinal: Bool = false) {
        self.id = id; self.track = track; self.start = start; self.end = end
        self.text = text; self.revision = revision; self.isFinal = isFinal
    }
}

public enum FactKind: String, Codable, Sendable, CaseIterable {
    case confirmedFact, confirmedPlan, unknown, expertProposal, aiProposal
    public var title: String {
        switch self {
        case .confirmedFact: "已确认事实"
        case .confirmedPlan: "已确认计划"
        case .unknown: "待确认信息"
        case .expertProposal: "专家建议"
        case .aiProposal: "AI 建议"
        }
    }
}

public struct ResearchFact: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var content: String
    public var kind: FactKind
    public var origin: String
    public init(content: String, kind: FactKind = .unknown, origin: String = "用户输入") {
        self.content = content; self.kind = kind; self.origin = origin
    }
}

public struct ResearchProfile: Codable, Equatable, Sendable {
    public var identity = "Medical researcher"
    public var project = ""
    public var facts: [ResearchFact] = []
    public var terminology = """
    acute compartment syndrome / ACS / 急性骨筋膜室综合征
    confocal laser endomicroscopy / CLE / 共聚焦激光显微内镜
    ischemia-reperfusion / 缺血再灌注
    fasciotomy / 筋膜切开术
    histopathology / 组织病理学
    near-infrared spectroscopy / NIRS / 近红外光谱
    shear wave elastography / SWE / 剪切波弹性成像
    microcirculation / 微循环
    necrosis / 坏死
    perfusion / 灌注
    intracompartmental pressure / 筋膜室内压力
    skeletal muscle / 骨骼肌
    reversible ischemia / 可逆性缺血
    irreversible injury / 不可逆损伤
    """
    public init() {}
}

public enum UtteranceKind: String, Codable, CaseIterable, Sendable {
    case question = "QUESTION", comment = "COMMENT", suggestion = "SUGGESTION"
    case clarification = "CLARIFICATION", criticism = "CRITICISM"
    case background = "BACKGROUND", smallTalk = "SMALL_TALK", unknown = "UNKNOWN"
}

public enum Addressee: String, Codable, Sendable { case user, other, unclear }

public struct UtteranceAnalysis: Codable, Sendable {
    public var sourceIDs: [String]
    public var kind: UtteranceKind
    public var coreMeaning: String
    public var intent: String
    public var requiresResponse: Bool
    public var addressee: Addressee
    public var reason: String
}

public struct AnswerContent: Codable, Sendable {
    public var sourceIDs: [String]
    public var factIDs: [String]
    public var coreQuestion: String
    public var intent: String
    public var english: String
    public var chinese: String
    public var shortAnswer: String
    public var cautiousAnswer: String
    public var clarification: String
    public var missingInformation: [String]
    public var warnings: [String]
}

public struct AnswerSuggestion: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var createdAt = Date()
    public var sources: [SourceReference]
    public var content: AnswerContent
    public var provider: String
    public var model: String
    public var pinned = false
    public var stale = false
    public var evidenceSegments: [TranscriptSegment]?
    public var evidenceFacts: [ResearchFact]?
    public init(sources: [SourceReference], content: AnswerContent, provider: String, model: String,
                evidenceSegments: [TranscriptSegment]? = nil, evidenceFacts: [ResearchFact]? = nil) {
        self.sources = sources; self.content = content; self.provider = provider; self.model = model
        self.evidenceSegments = evidenceSegments; self.evidenceFacts = evidenceFacts
    }
}

public struct SummaryEntry: Codable, Sendable {
    public var text: String
    public var sourceIDs: [String]
    public var owner: String?
    public var deadline: String?
    public var displayedOwner: String { Self.knownValue(owner) }
    public var displayedDeadline: String { Self.knownValue(deadline) }
    private static func knownValue(_ value: String?) -> String {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "待确认" : value
    }
}

public struct MeetingSummary: Codable, Sendable {
    public var topics: [SummaryEntry]
    public var questions: [SummaryEntry]
    public var actualAnswers: [SummaryEntry]
    public var decisions: [SummaryEntry]
    public var actions: [SummaryEntry]
    public var unresolved: [SummaryEntry]
}

public struct RecordingGap: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var time: Double
    public var reason: String
    public init(time: Double, reason: String) { self.time = time; self.reason = reason }
}

public struct MeetingSession: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: UUID = UUID()
    public var title = "科研会议"
    public var startedAt = Date()
    public var endedAt: Date?
    /// Present only after explicitly opening an interrupted saved session.
    public var recoveredAt: Date?
    public var microphoneIncluded = false
    public var configuration = ""
    public var segments: [TranscriptSegment] = []
    public var answers: [AnswerSuggestion] = []
    public var summary: MeetingSummary?
    public var summaryEvidence: [TranscriptSegment]?
    public var summaryStale = false
    public var gaps: [RecordingGap] = []
    public var profile = ResearchProfile()
    public init() {}

    public var hasRecord: Bool {
        !segments.isEmpty || !gaps.isEmpty || !answers.isEmpty || summary != nil || !configuration.isEmpty
    }

    public mutating func markRecovered(at date: Date = Date()) {
        guard endedAt == nil, recoveredAt == nil, hasRecord else { return }
        recoveredAt = date
        let lastTime = max(segments.map(\.end).max() ?? 0, gaps.map(\.time).max() ?? 0)
        gaps.append(.init(time: lastTime, reason: "会议未正常结束，已恢复最后保存的文字；保存后的内容可能缺失。恢复不会自动开启音频或麦克风。"))
        summaryStale = summary != nil
    }

    /// Reject delayed provider events, final-to-partial regression, and overwrites of manual corrections.
    @discardableResult
    public mutating func upsert(_ segment: TranscriptSegment) -> Bool {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
              segment.end >= segment.start, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            let old = segments[index]
            guard !old.manuallyCorrected, old.track == segment.track,
                  segment.revision > old.revision,
                  !(old.isFinal && !segment.isFinal) else { return false }
            segments[index] = segment
            invalidateSources([segment.id])
        } else {
            segments.append(segment)
            if segment.isFinal { summaryStale = summary != nil }
        }
        segments.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return true
    }

    public mutating func correct(id: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].text = text; segments[i].revision += 1
        segments[i].isFinal = true; segments[i].manuallyCorrected = true
        segments[i].translation = nil; segments[i].translationRevision = nil
        invalidateSources([id])
    }

    public mutating func translate(_ reference: SourceReference, text: String) -> Bool {
        guard let i = segments.firstIndex(where: { $0.reference == reference }) else { return false }
        segments[i].translation = text; segments[i].translationRevision = reference.revision
        return true
    }

    public func containsCurrent(_ references: [SourceReference]) -> Bool {
        !references.isEmpty && references.allSatisfy { reference in
            segments.contains { $0.reference == reference && $0.isFinal }
        }
    }

    private mutating func invalidateSources(_ ids: Set<String>) {
        for i in answers.indices where answers[i].sources.contains(where: { ids.contains($0.id) }) {
            answers[i].stale = true
        }
        summaryStale = summary != nil
    }
}

public enum CopilotError: Error, LocalizedError, Sendable, Equatable {
    case message(String)
    case invalidResponse
    case missingCredential
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .invalidResponse: "模型响应不完整或格式无效，请重试。"
        case .missingCredential: "请在设置中为当前服务保存 API Key。"
        case .http(let code): "服务请求失败（HTTP \(code)）。请检查凭据、额度或稍后重试。"
        }
    }
}
