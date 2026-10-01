import Foundation
import CopilotCore

protocol RealtimeSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// A new ephemeral transport for each connection. Redirects are rejected before credential forwarding.
final class FoundationRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        task = session.webSocketTask(with: request); task.maximumMessageSize = 1_048_576
        task.resume()
    }
    func send(_ data: Data) async throws { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw CopilotError.invalidResponse
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
