import Foundation
import Testing
import CopilotCore
@testable import CopilotSpeech

private final class FakeRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    enum Commit: Sendable { case empty, complete, noReply, pending }
    private let lock = NSLock()
    private var messages: [Result<Data, Error>] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    private var sent: [Data] = []
    let acknowledge: Bool
    let commit: Commit
    init(acknowledge: Bool = true, commit: Commit = .empty) { self.acknowledge = acknowledge; self.commit = commit }

    static func ack(disabled: Bool = false) -> Data {
        let vad: Any = disabled ? NSNull() : ["type": "server_vad"]
        return try! JSONSerialization.data(withJSONObject: ["type": "session.updated", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000], "transcription": ["model": "gpt-live-transcribe"], "turn_detection": vad
        ]]]])
    }
    func push(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            if let pending = waiter { waiter = nil; pending.resume(returning: data) }
            else { messages.append(.success(data)) }
        }
    }
    func event(_ json: String) { push(Data(json.utf8)) }
    func drop() {
        lock.withLock {
            let failure = URLError(.networkConnectionLost)
            if let pending = waiter { waiter = nil; pending.resume(throwing: failure) }
            else { messages.append(.failure(failure)) }
        }
    }
    var isClosed: Bool { lock.withLock { closed } }
    func count(_ type: String) -> Int {
        lock.withLock { sent.filter { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["type"] as? String == type }.count }
    }
    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !closed else { throw URLError(.cancelled) }
            sent.append(data)
        }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if object["type"] as? String == "session.update", acknowledge {
            let session = object["session"] as! [String: Any], audio = session["audio"] as! [String: Any], input = audio["input"] as! [String: Any]
            push(Self.ack(disabled: input["turn_detection"] is NSNull))
        }
        if object["type"] as? String == "input_audio_buffer.commit" {
            switch commit {
            case .empty:
                push(try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["code": "input_audio_buffer_commit_empty", "event_id": object["event_id"]!]]))
            case .complete:
                event(#"{"type":"input_audio_buffer.committed","item_id":"tail","previous_item_id":null}"#)
                event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"tail","transcript":"final tail"}"#)
            case .pending:
                event(#"{"type":"input_audio_buffer.committed","item_id":"tail","previous_item_id":null}"#)
            case .noReply: break
            }
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: URLError(.cancelled)) }
                else if !messages.isEmpty { continuation.resume(with: messages.removeFirst()) }
                else { precondition(waiter == nil); waiter = continuation }
            }
        }
    }
    func close() {
        lock.withLock {
            closed = true
            waiter?.resume(throwing: URLError(.cancelled)); waiter = nil
        }
    }
}

private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [FakeRealtimeSocket]
    private var index = 0
    init(_ values: [FakeRealtimeSocket]) { self.values = values }
    var count: Int { lock.withLock { index } }
    func make(_ request: URLRequest) throws -> any RealtimeSocket {
        try lock.withLock {
            guard request.url?.host == "api.openai.com", index < values.count else { throw URLError(.cannotConnectToHost) }
            defer { index += 1 }
            return values[index]
        }
    }
}

private actor CloudEvents {
    var segments: [TranscriptSegment] = []
    var gaps: [RecordingGap] = []
    var retractions: [String] = []
    var statuses: [String] = []
    func append(_ event: SpeechEvent) {
        switch event {
        case .segment(let value): segments.append(value)
        case .gap(let value): gaps.append(value)
        case .retractPartial(let id): retractions.append(id)
        case .status(let value): statuses.append(value)
        }
    }
}

private func cloudLimits() -> OpenAITranscriptionProvider.Limits {
    var limits = OpenAITranscriptionProvider.Limits()
    limits.handshakeSeconds = 0.4; limits.sendSeconds = 0.4; limits.finishSeconds = 0.4
    limits.reconnectDelays = [0.001, 0.002, 0.004]
    return limits
}

private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for controlled cloud event")
}

private func startCloud(_ provider: OpenAITranscriptionProvider, events: CloudEvents, microphone: Bool = false) async throws {
    try await provider.start(key: "synthetic-key-not-real", model: "gpt-live-transcribe", microphone: microphone,
                             silence: 1, terminology: "test") { await events.append($0) }
}

@Test func emptyShutdownCommitDoesNotLoseAnOlderDelayedTranscript() async throws {
    let socket = FakeRealtimeSocket(), events = CloudEvents()
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: { _ in socket })
    try await startCloud(provider, events: events)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.1, count: 2400), sampleRate: 24000, start: 10))
    try await waitFor { socket.count("input_audio_buffer.append") == 1 }
    socket.event(#"{"type":"input_audio_buffer.speech_started","item_id":"earlier","audio_start_ms":0}"#)
    socket.event(#"{"type":"input_audio_buffer.speech_stopped","item_id":"earlier","audio_end_ms":100}"#)
    socket.event(#"{"type":"input_audio_buffer.committed","item_id":"earlier","previous_item_id":null}"#)
    let finishing = Task { await provider.finish() }
    try await waitFor { socket.count("input_audio_buffer.commit") == 1 }
    #expect(!socket.isClosed)
    socket.event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"earlier","transcript":"delayed final"}"#)
    await finishing.value
    let final = try #require(await events.segments.last)
    #expect(final.isFinal && final.text == "delayed final" && final.start == 10 && final.end == 10.1)
    #expect(await events.gaps.isEmpty)
    #expect(socket.isClosed)
}

@Test func shutdownWaitsForFinalAndMarksUnconfirmedTailAtDeadline() async throws {
    let socket = FakeRealtimeSocket(commit: .pending), events = CloudEvents()
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: { _ in socket })
    try await startCloud(provider, events: events)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.2, count: 2400), sampleRate: 24000, start: 0))
    let started = ContinuousClock.now
    await provider.finish()
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(socket.isClosed)
    #expect(await events.gaps.contains { $0.reason.contains("最后一段可能遗漏") })
    #expect(await events.segments.isEmpty)
}

@Test func reconnectUsesNewTimelineAndDoesNotReplayOrChangeProvider() async throws {
    let first = FakeRealtimeSocket(), second = FakeRealtimeSocket(commit: .complete), events = CloudEvents()
    let factory = SocketSequence([first, second])
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: factory.make)
    try await startCloud(provider, events: events)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.1, count: 2400), sampleRate: 24000, start: 1))
    try await waitFor { first.count("input_audio_buffer.append") == 1 }
    first.event(#"{"type":"input_audio_buffer.speech_started","item_id":"reused","audio_start_ms":0}"#)
    first.event(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"reused","delta":"old partial"}"#)
    try await waitFor { await events.segments.count == 1 }
    first.drop()
    try await waitFor { await events.statuses.contains { $0.contains("已恢复") } }
    #expect(factory.count == 2 && first.isClosed)
    #expect(second.count("input_audio_buffer.append") == 0)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.1, count: 2400), sampleRate: 24000, start: 50))
    try await waitFor { second.count("input_audio_buffer.append") == 1 }
    second.event(#"{"type":"input_audio_buffer.speech_started","item_id":"reused","audio_start_ms":0}"#)
    second.event(#"{"type":"input_audio_buffer.speech_stopped","item_id":"reused","audio_end_ms":100}"#)
    second.event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"reused","transcript":"new final"}"#)
    try await waitFor { await events.segments.contains { $0.text == "new final" } }
    let segments = await events.segments
    #expect(segments[0].id != segments[1].id && segments[1].start == 50)
    #expect(await events.retractions.contains(segments[0].id))
    await provider.finish()
}

@Test func reconnectBudgetIsFiniteAndStoppingCancelsFurtherRecovery() async throws {
    let first = FakeRealtimeSocket(), bad1 = FakeRealtimeSocket(acknowledge: false), bad2 = FakeRealtimeSocket(acknowledge: false)
    let factory = SocketSequence([first,bad1,bad2]), events = CloudEvents()
    var limits = cloudLimits(); limits.handshakeSeconds = 0.03; limits.reconnectDelays = [0.001,0.001]
    let provider = OpenAITranscriptionProvider(limits: limits, makeSocket: factory.make)
    try await startCloud(provider, events: events)
    first.drop()
    try await waitFor { await events.statuses.contains { $0.contains("已达上限") } }
    #expect(factory.count == 3)
    await provider.finish()
    #expect(bad1.isClosed && bad2.isClosed)
    #expect(await events.gaps.contains { $0.reason.contains("未恢复识别") })
}

@Test func oneTrackFailureDoesNotCloseTheOtherTrack() async throws {
    let remote = FakeRealtimeSocket(), microphone = FakeRealtimeSocket(commit: .complete), events = CloudEvents()
    let factory = SocketSequence([remote,microphone])
    var limits = cloudLimits(); limits.reconnectDelays = []
    let provider = OpenAITranscriptionProvider(limits: limits, makeSocket: factory.make)
    try await startCloud(provider, events: events, microphone: true)
    remote.drop()
    try await waitFor { remote.isClosed }
    #expect(!microphone.isClosed)
    await provider.accept(.init(track: .microphone, samples: Array(repeating: 0.2, count: 2400), sampleRate: 24000, start: 5))
    await provider.finish()
    #expect(await events.segments.contains { $0.track == .microphone && $0.text == "final tail" })
}

@Test func noAudioFinishesWithoutAnEmptyCommitAndPCMIsBounded() async throws {
    let socket = FakeRealtimeSocket(), events = CloudEvents()
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: { _ in socket })
    try await startCloud(provider, events: events)
    await provider.finish()
    #expect(socket.count("input_audio_buffer.commit") == 0 && socket.isClosed)
    let data = try OpenAITranscriptionProvider.audio([.nan, .infinity, -2, 2])
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let pcm = try #require(Data(base64Encoded: object["audio"] as! String))
    #expect(Array(pcm) == [0,0,0,0,1,128,255,127])
}

@Test func stoppingDuringHandshakeClosesItWithoutPublishingReady() async throws {
    let socket = FakeRealtimeSocket(acknowledge: false), events = CloudEvents()
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: { _ in socket })
    let startup = Task { try await startCloud(provider, events: events) }
    try await waitFor { socket.count("session.update") == 1 }
    await provider.finish()
    do { try await startup.value; Issue.record("Unconfirmed session became ready") } catch { }
    #expect(socket.isClosed)
    #expect(await events.statuses.isEmpty)
    #expect(socket.count("input_audio_buffer.append") == 0)
}

@Test func activeVADItemCanBecomeADifferentManualCommitItemOnStop() async throws {
    let socket = FakeRealtimeSocket(commit: .complete), events = CloudEvents()
    let provider = OpenAITranscriptionProvider(limits: cloudLimits(), makeSocket: { _ in socket })
    try await startCloud(provider, events: events)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.1, count: 24000), sampleRate: 24000, start: 20))
    try await waitFor { socket.count("input_audio_buffer.append") == 1 }
    socket.event(#"{"type":"input_audio_buffer.speech_started","item_id":"old-active","audio_start_ms":300}"#)
    socket.event(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"old-active","delta":"partial"}"#)
    try await waitFor { await events.segments.count == 1 }
    await provider.finish()
    let last = try #require(await events.segments.last)
    #expect(last.isFinal && last.text == "final tail")
    #expect(last.start == 20.3 && last.end == 21)
    #expect(await events.retractions.count == 1)
    #expect(await events.gaps.isEmpty)
}

@Test func audioQueueOverloadCreatesAGapInsteadOfUnboundedBuffering() async throws {
    let socket = FakeRealtimeSocket(), events = CloudEvents()
    var limits = cloudLimits(); limits.maximumQueuedSamples = 2000; limits.reconnectDelays = []
    let provider = OpenAITranscriptionProvider(limits: limits, makeSocket: { _ in socket })
    try await startCloud(provider, events: events)
    await provider.accept(.init(track: .remote, samples: Array(repeating: 0.1, count: 2400), sampleRate: 24000, start: 25))
    #expect(socket.isClosed && socket.count("input_audio_buffer.append") == 0)
    #expect(await events.gaps.contains { $0.time == 25 && $0.reason.contains("积压") })
    await provider.finish()
}

@Test func transcriptionConfigurationDoesNotApplyParametersToUnadaptedModels() throws {
    let data = try OpenAITranscriptionProvider.configuration(model: "gpt-live-transcribe", track: .microphone,
        silence: 1, terminology: "NIRS\n<necrosis>\r\nperfusion")
    let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let session = raw["session"] as! [String: Any], audio = session["audio"] as! [String: Any]
    let input = audio["input"] as! [String: Any], transcription = input["transcription"] as! [String: Any]
    #expect(raw["type"] as? String == "session.update" && session["type"] as? String == "transcription")
    #expect(transcription["languages"] as? [String] == ["en","zh"])
    #expect(transcription["language"] == nil)
    #expect(transcription["keywords"] as? [String] == ["NIRS", "necrosis", "perfusion"])
    #expect(throws: CopilotError.self) {
        try OpenAITranscriptionProvider.configuration(model: "gpt-transcribe", track: .remote, silence: 1, terminology: "")
    }
    let request = OpenAITranscriptionProvider.request(key: "synthetic-only")
    #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
}
