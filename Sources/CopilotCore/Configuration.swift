import Foundation
import CryptoKit

public enum TextProviderKind: String, Codable, CaseIterable, Sendable {
    case deepSeek, openAI, compatible
    public var title: String {
        switch self { case .deepSeek: "DeepSeek"; case .openAI: "OpenAI"; case .compatible: "自定义兼容服务" }
    }
}

public enum TextProtocol: String, Codable, CaseIterable, Sendable { case chatCompletions, responses }
public enum StructuredOutputMode: String, Codable, CaseIterable, Sendable { case schema, jsonObject, promptOnly }
public enum SpeechProviderKind: String, Codable, CaseIterable, Sendable { case whisperKit, openAI }

public struct TextProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: TextProviderKind
    public var baseURL: String
    public var apiProtocol: TextProtocol
    public var structure: StructuredOutputMode
    public var fastModel: String
    public var answerModel: String
    public var usesReasoningControl = false
    public init(kind: TextProviderKind) {
        self.kind = kind; id = kind.rawValue
        switch kind {
        case .deepSeek:
            baseURL = "https://api.deepseek.com"; apiProtocol = .chatCompletions
            fastModel = "deepseek-flash"; answerModel = "deepseek-v4-pro"; structure = .jsonObject
        case .openAI:
            baseURL = "https://api.openai.com/v1"; apiProtocol = .responses
            fastModel = "gpt-5.6-luna"; answerModel = "gpt-5.6-sol"; structure = .schema
        case .compatible:
            baseURL = ""; apiProtocol = .chatCompletions
            fastModel = ""; answerModel = ""; structure = .jsonObject
        }
    }

    public func validatedBaseURL() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw CopilotError.message("服务地址必须是无用户名、密码或查询参数的 HTTPS 地址。")
        }
        // Go is intentionally reserved until meeting workloads are confirmed as supported.
        guard !(host == "opencode.ai" && url.path.contains("/go")) else {
            throw CopilotError.message("OpenCode Go 暂为预留选项，请选择适用于会议用途的服务。")
        }
        return url
    }

    public var credentialAccount: String {
        // Binding includes the complete normalized base path, not just provider display name.
        let identity = id + "|" + baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "provider." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AppConfiguration: Codable, Sendable {
    public var selectedTextProvider: TextProviderKind = .deepSeek
    public var textProviders = TextProviderKind.allCases.map(TextProviderConfiguration.init)
    public var speechProvider: SpeechProviderKind = .whisperKit
    public var localModel = "large-v3-v20240930_626MB"
    public var modelFolder = ""
    public var openAISpeechModel = "gpt-live-transcribe"
    public var captureMicrophone = false
    public var automaticAnswers = true
    public var cloudTextEnabled = false
    public var vadSilenceSeconds = 1.0
    public init() {}
    public var selectedText: TextProviderConfiguration {
        textProviders.first { $0.kind == selectedTextProvider } ?? .init(kind: selectedTextProvider)
    }
}
