import Foundation
import CopilotCore

/// Independent, bounded audio tracks. Reconnect never changes provider or replays uncertain audio.
public actor OpenAITranscriptionProvider: SpeechRecognitionProvider {
    public nonisolated let sampleRate = 24000
    public static let credentialAccount = "speech.openai.api.openai.com"
    struct Limits: Sendable {
        var handshakeSeconds = 15.0
        var sendSeconds = 10.0
        var finishSeconds = 8.0
        var reconnectDelays: [Double] = [1, 2, 4]
        var maximumQueuedSamples = 48000
    }
    private struct Settings {
        var key: String
        var model: String
        var silence: Double
        var terminology: String
    }
    private final class Link {
        let id = UUID()
        let socket: any RealtimeSocket
        var ready = false
        var reducer: RealtimeTranscriptReducer
        var queue: [AudioFrame] = []
        var queuedSamples = 0
        var sender: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var origin: Double?
        var expectedNextStart: Double?
        var sentEnd: Double = 0
        var lastFinalEnd: Double?
        var hasSentAudio = false
        var vadDisabled = false
        var finalCommitID: String?
        var finalCommitResolved = false
        var finalCommitFailed = false
        var activeSpeech: Set<String> = []
        var seenEvents: Set<String> = []
        var eventOrder: [String] = []
        init(socket: any RealtimeSocket, track: AudioTrack) {
            self.socket = socket
            reducer = .init(track: track, namespace: id.uuidString)
        }
        func close() { sender?.cancel(); reader?.cancel(); socket.close() }
    }
    private let makeSocket: @Sendable (URLRequest) throws -> any RealtimeSocket
    private let limits: Limits
    private var settings: Settings?
    private var links: [AudioTrack: Link] = [:]
    private var recoveries: [AudioTrack: Task<Void, Never>] = [:]
    private var attempts: [AudioTrack: Int] = [:]
    private var latestTime: [AudioTrack: Double] = [:]
    private var outageStart: [AudioTrack: Double] = [:]
    private var configuredTracks: Set<AudioTrack> = []
    private var runID: UUID?
    private var stopping = false
    private var emit: @Sendable (SpeechEvent) async -> Void = { _ in }

    public init() { makeSocket = { FoundationRealtimeSocket(request: $0) }; limits = .init() }
    init(limits: Limits = .init(), makeSocket: @escaping @Sendable (URLRequest) throws -> any RealtimeSocket) {
        self.limits = limits; self.makeSocket = makeSocket
    }

    public func start(key: String, model: String, microphone: Bool, silence: Double, terminology: String,
                      emit: @escaping @Sendable (SpeechEvent) async -> Void) async throws {
        guard runID == nil else { throw CopilotError.message("云端语音已经启动。") }
        guard !key.isEmpty else { throw CopilotError.missingCredential }
        guard !model.isEmpty, silence.isFinite, (0.1...5).contains(silence) else { throw CopilotError.invalidResponse }
        _ = try Self.configuration(model: model, track: .remote, silence: silence, terminology: terminology)
        let id = UUID(); runID = id; stopping = false; self.emit = emit
        settings = .init(key: key, model: model, silence: silence, terminology: terminology)
        configuredTracks = microphone ? Set(AudioTrack.allCases) : [.remote]
        do {
            for track in AudioTrack.allCases where configuredTracks.contains(track) { try await connect(track, run: id) }
            try Task.checkCancellation()
            guard runID == id, !stopping else { throw CancellationError() }
            guard configuredTracks.allSatisfy({ links[$0]?.ready == true }) else { throw CopilotError.message("部分云端音轨在启动期间断开。") }
            await emit(.status("OpenAI 云端语音已连接"))
        } catch { if runID == id { closeAll() }; throw error }
    }

    static func request(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    static func configuration(model: String, track: AudioTrack, silence: Double, terminology: String) throws -> Data {
        guard model == "gpt-live-transcribe" else {
            throw CopilotError.message("当前云端语音适配使用 gpt-live-transcribe；其他模型需要独立验证参数与分段协议。")
        }
        let keywords = terminology.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(50).map {
            String($0.prefix(120)).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").replacingOccurrences(of: "\r", with: "")
        }.filter { !$0.isEmpty }
        return try json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": model, "languages": track == .remote ? ["en"] : ["en", "zh"], "keywords": keywords, "delay": "low"],
            "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": Int(silence * 1000)]
        ]]]])
    }

    private func connect(_ track: AudioTrack, run: UUID) async throws {
        guard runID == run, !stopping, let settings else { throw CancellationError() }
        let socket = try makeSocket(Self.request(key: settings.key))
        let link = Link(socket: socket, track: track); links[track] = link
        let timeout = Self.watchdog(socket, seconds: limits.handshakeSeconds)
        defer { timeout.cancel() }
        do {
            try await socket.send(Self.configuration(model: settings.model, track: track, silence: settings.silence, terminology: settings.terminology))
            var acknowledged = false
            for _ in 0..<20 {
                let event = try RealtimeEvent(await socket.receive())
                try Task.checkCancellation()
                guard runID == run, links[track]?.id == link.id, !stopping else { throw CancellationError() }
                if event.type == "error" { throw CopilotError.message("OpenAI 语音会话配置失败，请检查模型与账户权限。") }
                if event.type == "session.updated" {
                    guard event.validTranscriptionSession, event.sessionModel == settings.model, event.serverVAD else {
                        throw CopilotError.message("OpenAI 未确认所选模型、音频格式或分段方式。")
                    }
                    acknowledged = true; break
                }
            }
            guard acknowledged else { throw CopilotError.message("OpenAI 语音会话未确认配置。") }
            link.ready = true
            link.reader = Task { await self.readLoop(track, linkID: link.id, socket: socket) }
        } catch {
            link.close()
            if links[track]?.id == link.id { links.removeValue(forKey: track) }
            throw error
        }
    }

    public func accept(_ frame: AudioFrame) async {
        guard runID != nil, !stopping, configuredTracks.contains(frame.track), frame.sampleRate == sampleRate,
              frame.start.isFinite, frame.start >= 0, !frame.samples.isEmpty else { return }
        latestTime[frame.track] = max(latestTime[frame.track] ?? 0, frame.start + frame.duration)
        guard let link = links[frame.track], link.ready else { return }
        if let expected = link.expectedNextStart, abs(frame.start - expected) > 0.05 {
            await failed(frame.track, linkID: link.id, reason: "音频时间轴出现缺口，重新建立语音连接以避免时间戳错位。", lostAt: min(frame.start, expected))
            return
        }
        guard link.queuedSamples + frame.samples.count <= limits.maximumQueuedSamples else {
            await failed(frame.track, linkID: link.id, reason: "云端音频发送积压，部分音频未处理。", lostAt: frame.start)
            return
        }
        link.queue.append(frame); link.queuedSamples += frame.samples.count
        link.expectedNextStart = frame.start + frame.duration
        if link.sender == nil { link.sender = Task { await self.sendLoop(frame.track, linkID: link.id) } }
    }

    private func sendLoop(_ track: AudioTrack, linkID: UUID) async {
        while let link = links[track], link.id == linkID, !Task.isCancelled {
            guard !link.queue.isEmpty else { link.sender = nil; return }
            let frame = link.queue.removeFirst(); link.queuedSamples -= frame.samples.count
            if link.origin == nil { link.origin = frame.start; link.reducer.timeOffset = frame.start }
            link.hasSentAudio = true; link.sentEnd = frame.start + frame.duration
            do { try await send(Self.audio(frame.samples), socket: link.socket) }
            catch { await failed(track, linkID: linkID, reason: "云端音频发送中断。") ; return }
        }
    }

    private func readLoop(_ track: AudioTrack, linkID: UUID, socket: any RealtimeSocket) async {
        do {
            while !Task.isCancelled {
                let event = try RealtimeEvent(await socket.receive())
                guard let link = links[track], link.id == linkID else { return }
                if let id = event.eventID {
                    guard link.seenEvents.insert(id).inserted else { continue }
                    link.eventOrder.append(id)
                    if link.eventOrder.count > 4096 { link.seenEvents.remove(link.eventOrder.removeFirst()) }
                }
                if event.type == "session.updated" {
                    if stopping && event.validTranscriptionSession && event.sessionModel == settings?.model && event.vadDisabled { link.vadDisabled = true }
                    continue
                }
                if event.type == "error" {
                    if let commit = link.finalCommitID, event.failedClientEventID == commit {
                        // An empty final commit must not terminate the reader before older items complete.
                        link.finalCommitResolved = true
                        link.finalCommitFailed = event.errorCode != "input_audio_buffer_commit_empty"
                        if link.finalCommitFailed { await emit(.gap(.init(time: link.sentEnd, reason: "\(track.title)尾部提交失败，可能有遗漏。"))) }
                        continue
                    }
                    throw CopilotError.invalidResponse
                }
                if event.type == "conversation.item.input_audio_transcription.failed", let id = event.itemID {
                    link.reducer.discard(itemID: id); link.activeSpeech.remove(id)
                    await emit(.retractPartial(id: link.reducer.segmentID(id)))
                    await emit(.gap(.init(time: link.sentEnd, reason: "\(track.title)有一段云端转写失败。")))
                    continue
                }
                if let id = event.itemID {
                    if event.type == "input_audio_buffer.speech_started" { link.activeSpeech.insert(id) }
                    if event.type == "input_audio_buffer.speech_stopped" || event.type == "conversation.item.input_audio_transcription.completed" { link.activeSpeech.remove(id) }
                }
                if event.type == "input_audio_buffer.committed", let id = event.itemID, link.finalCommitID != nil {
                    link.finalCommitResolved = true
                    let replaced = link.reducer.replaceActiveItems(link.activeSpeech, with: id)
                    link.activeSpeech.removeAll()
                    for oldID in replaced { await emit(.retractPartial(id: oldID)) }
                }
                if let segment = try link.reducer.consume(event, fallbackTime: link.sentEnd) {
                    if segment.isFinal { link.lastFinalEnd = max(link.lastFinalEnd ?? 0, segment.end) }
                    await emit(.segment(segment))
                } else if event.type == "conversation.item.input_audio_transcription.completed", let id = event.itemID,
                          event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    await emit(.retractPartial(id: link.reducer.segmentID(id)))
                    await emit(.gap(.init(time: link.sentEnd, reason: "\(track.title)云端返回空转写，可能有遗漏。")))
                }
            }
        } catch {
            if links[track]?.id == linkID { await failed(track, linkID: linkID, reason: "云端语音连接中断或返回无效事件。") }
        }
    }

    private func failed(_ track: AudioTrack, linkID: UUID, reason: String, lostAt: Double? = nil) async {
        guard let link = links[track], link.id == linkID else { return }
        links.removeValue(forKey: track); link.close()
        let earliest = link.reducer.pendingSegments.map(\.start).min() ?? link.lastFinalEnd ?? link.origin ?? lostAt ?? latestTime[track] ?? 0
        let lostFrom = min(earliest, lostAt ?? earliest)
        outageStart[track] = outageStart[track] ?? lostFrom
        for pending in link.reducer.pendingSegments where !pending.text.isEmpty { await emit(.retractPartial(id: pending.id)) }
        await emit(.gap(.init(time: lostFrom, reason: "\(track.title)：\(reason) 未确认的音频不自动重放。")))
        guard !stopping, let run = runID, recoveries[track] == nil else { return }
        recoveries[track] = Task { await self.recover(track, run: run) }
    }

    private func recover(_ track: AudioTrack, run: UUID) async {
        defer {
            if runID == run {
                recoveries[track] = nil
                // A new socket may fail immediately after its handshake while this recovery task is
                // emitting status. Continue within the same per-run budget instead of losing that fault.
                if !stopping, links[track] == nil, attempts[track, default: 0] < limits.reconnectDelays.count {
                    recoveries[track] = Task { await self.recover(track, run: run) }
                }
            }
        }
        while runID == run, !stopping, !Task.isCancelled {
            let attempt = attempts[track, default: 0]
            guard attempt < limits.reconnectDelays.count else {
                await emit(.status("\(track.title)云端重连已达上限，请停止后重新开始；未切换供应商")); return
            }
            attempts[track] = attempt + 1
            await emit(.status("\(track.title)云端重连 \(attempt + 1)/\(limits.reconnectDelays.count)…"))
            do {
                try await Task.sleep(for: .seconds(limits.reconnectDelays[attempt]))
                try Task.checkCancellation()
                try await connect(track, run: run)
                guard runID == run, !stopping else { return }
                guard links[track]?.ready == true else { continue }
                if let start = outageStart.removeValue(forKey: track) {
                    await emit(.gap(.init(time: start, reason: "\(track.title)重连期间至 \(String(format: "%.1f", latestTime[track] ?? start)) 秒的音频可能遗漏；新音频已恢复。")))
                }
                await emit(.status("\(track.title)云端语音已恢复")); return
            } catch is CancellationError { return }
            catch { /* The same track has a fixed retry budget for this capture run. */ }
        }
    }

    public func finish() async {
        guard runID != nil, !stopping else { return }
        stopping = true
        for task in recoveries.values { task.cancel() }; recoveries.removeAll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.finishSeconds))
        // Both tracks share one overall deadline, rather than adding sequential fixed sleeps.
        let tasks = Array(links.keys).map { track in Task { await self.finishTrack(track, deadline: deadline) } }
        for task in tasks { await task.value }
        for (track, start) in outageStart {
            await emit(.gap(.init(time: start, reason: "\(track.title)断线后至 \(String(format: "%.1f", latestTime[track] ?? start)) 秒未恢复识别。")))
        }
        closeAll()
    }

    private func finishTrack(_ track: AudioTrack, deadline: ContinuousClock.Instant) async {
        guard let link = links[track] else { return }
        do {
            try await waitUntil(deadline) { self.links[track]?.id != link.id || link.sender == nil }
            guard links[track]?.id == link.id, link.ready else { return }
            guard link.hasSentAudio else { link.close(); links.removeValue(forKey: track); return }
            // Freeze server VAD and wait for its effective configuration before the one manual commit.
            try await send(Self.json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": ["turn_detection": NSNull()]]]]), socket: link.socket, deadline: deadline)
            try await waitUntil(deadline) { self.links[track]?.id != link.id || link.vadDisabled }
            guard links[track]?.id == link.id else { return }
            let commit = "finish-" + UUID().uuidString; link.finalCommitID = commit
            try await send(Self.json(["type": "input_audio_buffer.commit", "event_id": commit]), socket: link.socket, deadline: deadline)
            try await waitUntil(deadline) {
                self.links[track]?.id != link.id || (link.finalCommitResolved && link.reducer.pendingCount == 0)
            }
        } catch {
            if links[track]?.id == link.id {
                for pending in link.reducer.pendingSegments where !pending.text.isEmpty { await emit(.retractPartial(id: pending.id)) }
                await emit(.gap(.init(time: link.reducer.pendingSegments.map(\.start).min() ?? link.sentEnd,
                    reason: "\(track.title)结束等待超时或尾部未获确认，最后一段可能遗漏。")))
            }
        }
        if links[track]?.id == link.id { links.removeValue(forKey: track); link.close() }
    }

    private func waitUntil(_ deadline: ContinuousClock.Instant, _ condition: () -> Bool) async throws {
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CopilotError.message("云端语音等待超时。") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func closeAll() {
        runID = nil; stopping = true
        for task in recoveries.values { task.cancel() }
        for link in links.values { link.close() }
        links.removeAll(); recoveries.removeAll(); attempts.removeAll(); latestTime.removeAll()
        outageStart.removeAll(); configuredTracks.removeAll(); settings = nil
    }
    private func send(_ data: Data, socket: any RealtimeSocket, deadline: ContinuousClock.Instant? = nil) async throws {
        let interval: Double
        if let deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            interval = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard interval > 0 else { throw CopilotError.message("云端语音等待超时。") }
        } else { interval = limits.sendSeconds }
        let timeout = Self.watchdog(socket, seconds: min(limits.sendSeconds, interval))
        defer { timeout.cancel() }
        try await socket.send(data)
        try Task.checkCancellation()
    }
    private static func watchdog(_ socket: any RealtimeSocket, seconds: Double) -> Task<Void, Never> {
        Task { do { try await Task.sleep(for: .seconds(seconds)); socket.close() } catch {} }
    }
    private static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    static func audio(_ samples: [Float]) throws -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for value in samples {
            let safe = value.isFinite ? min(1, max(-1, value)) : 0
            var integer = Int16(safe * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &integer) { pcm.append(contentsOf: $0) }
        }
        return try json(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }
}
