import Foundation

public struct TextRequest: Sendable {
    public var model: String
    public var system: String
    public var input: String
    public var schema: Data
    public var schemaName: String
    public init(model: String, system: String, input: String, schema: Data, schemaName: String) {
        self.model = model; self.system = system; self.input = input
        self.schema = schema; self.schemaName = schemaName
    }
}

public protocol TextModelProvider: Sendable {
    func complete(_ request: TextRequest, onDelta: @escaping @Sendable (String) async -> Void) async throws -> String
}

public struct SSEEvent: Equatable, Sendable {
    public var name: String
    public var data: String
}

public enum StreamingDraft {
    /// Extract only a JSON string field for a clearly labelled, unvalidated preview.
    public static func english(in json: String) -> String? {
        guard let range = json.range(of: #""english"\s*:\s*""#, options: .regularExpression) else { return nil }
        var content = ""; var escaped = false
        for character in json[range.upperBound...] {
            if character == "\"" && !escaped { break }
            content.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        // A stream can end in a partial escape or Unicode sequence. Remove only that unfinished suffix.
        for _ in 0..<12 {
            if let value = try? JSONDecoder().decode(String.self, from: Data(("\"" + content + "\"").utf8)) { return value.isEmpty ? nil : value }
            guard !content.isEmpty else { return nil }
            content.removeLast()
        }
        return nil
    }
}

public struct SSEDecoder: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var name = "message"
    private var eventSize = 0
    public var maxEventBytes = 262_144
    public init() {}

    public mutating func append(_ byte: UInt8) throws -> SSEEvent? {
        if byte != 10 {
            line.append(byte)
            guard line.count + eventSize <= maxEventBytes else { throw CopilotError.invalidResponse }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let text = String(bytes: line, encoding: .utf8) else { throw CopilotError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); name = "message"; eventSize = 0 }
            return dataLines.isEmpty ? nil : SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "data" { dataLines.append(value); eventSize += value.utf8.count + 1 }
        if field == "event" { name = value }
        return nil
    }
}

public struct TextStreamAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var complete = false
    private var sawFinish = false
    public let apiProtocol: TextProtocol
    public init(apiProtocol: TextProtocol) { self.apiProtocol = apiProtocol }

    public mutating func consume(_ event: SSEEvent) throws -> String? {
        if event.data == "[DONE]" {
            guard apiProtocol == .chatCompletions, sawFinish else { throw CopilotError.invalidResponse }
            complete = true; return nil
        }
        guard let data = event.data.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CopilotError.invalidResponse }
        if object["error"] != nil { throw CopilotError.invalidResponse }
        var delta: String?
        switch apiProtocol {
        case .chatCompletions:
            if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
                if let reason = choice["finish_reason"] as? String {
                    guard reason == "stop" else { throw CopilotError.invalidResponse }
                    sawFinish = true
                }
                let content = choice["delta"] as? [String: Any]
                if let refusal = content?["refusal"] as? String, !refusal.isEmpty { throw CopilotError.invalidResponse }
                delta = content?["content"] as? String
            }
        case .responses:
            let type = object["type"] as? String ?? event.name
            switch type {
            case "response.output_text.delta": delta = object["delta"] as? String
            case "response.completed":
                guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else {
                    throw CopilotError.invalidResponse
                }
                complete = true
            case "response.failed", "response.incomplete", "error", "response.refusal.delta": throw CopilotError.invalidResponse
            default: break
            }
        }
        if let delta { text += delta }
        guard text.utf8.count <= 1_048_576 else { throw CopilotError.invalidResponse }
        return delta
    }

    public func validatedText() throws -> String {
        guard complete, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.invalidResponse }
        return text
    }
}

private final class DenyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct HTTPTextProvider: TextModelProvider {
    public let configuration: TextProviderConfiguration
    private let key: String
    public init(configuration: TextProviderConfiguration, key: String) {
        self.configuration = configuration; self.key = key
    }

    public func makeURLRequest(_ request: TextRequest) throws -> URLRequest {
        let base = try configuration.validatedBaseURL()
        guard !key.isEmpty else { throw CopilotError.missingCredential }
        guard !request.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw CopilotError.message("请先设置模型名称。") }
        let path = configuration.apiProtocol == .responses ? "responses" : "chat/completions"
        var result = URLRequest(url: base.appendingPathComponent(path))
        result.httpMethod = "POST"; result.timeoutInterval = 45
        result.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let schema = try JSONSerialization.jsonObject(with: request.schema)
        let format: [String: Any]
        switch configuration.structure {
        case .schema: format = ["type": "json_schema", "name": request.schemaName, "strict": true, "schema": schema]
        case .jsonObject: format = ["type": "json_object"]
        case .promptOnly: format = ["type": "text"]
        }
        let messages = [["role": "system", "content": request.system], ["role": "user", "content": request.input]]
        var body: [String: Any] = ["model": request.model, "stream": true]
        if configuration.apiProtocol == .responses {
            body["input"] = messages; body["store"] = false
            body["max_output_tokens"] = 6000; body["text"] = ["format": format]
            if configuration.usesReasoningControl { body["reasoning"] = ["effort": "low"] }
        } else {
            body["messages"] = messages; body["max_tokens"] = 6000
            if configuration.structure == .schema {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": request.schemaName, "strict": true, "schema": schema]]
            } else if configuration.structure == .jsonObject { body["response_format"] = ["type": "json_object"] }
            if configuration.kind == .deepSeek { body["thinking"] = ["type": "disabled"] }
        }
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }

    public func complete(_ request: TextRequest, onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        let request = try makeURLRequest(request)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 45; sessionConfig.timeoutIntervalForResource = 90
        sessionConfig.urlCache = nil; sessionConfig.httpCookieStorage = nil
        let session = URLSession(configuration: sessionConfig, delegate: DenyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Retry only a pre-stream 429 / 5xx. Never replay after a visible partial response.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CopilotError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if attempt < 2 && (http.statusCode == 429 || (500..<600).contains(http.statusCode)) {
                    let delay = min(5, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt)))
                    try await Task.sleep(for: .seconds(max(0.2, delay)))
                    continue
                }
                throw CopilotError.http(http.statusCode)
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw CopilotError.invalidResponse
            }
            var decoder = SSEDecoder()
            var result = TextStreamAccumulator(apiProtocol: configuration.apiProtocol)
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try decoder.append(byte) {
                    if let delta = try result.consume(event) { await onDelta(delta) }
                    if result.complete { break }
                }
            }
            return try result.validatedText()
        }
        throw CopilotError.invalidResponse
    }
}
