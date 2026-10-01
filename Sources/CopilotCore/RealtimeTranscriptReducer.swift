import Foundation

/// Server completion order is not audio order. A stable item ID owns timing, text and revisions.
public struct RealtimeTranscriptReducer: Sendable {
    private var items: [String: TranscriptSegment] = [:]
    private var completed: Set<String> = []
    private var completionOrder: [String] = []
    private var seenEvents: Set<String> = []
    private var eventOrder: [String] = []
    private var stopped: Set<String> = []
    private var lastCommittedEnd: Double = 0
    public let track: AudioTrack
    public let namespace: String
    public var timeOffset: Double = 0
    public var pendingSegments: [TranscriptSegment] { Array(items.values) }
    public var pendingCount: Int { items.count }
    public init(track: AudioTrack, namespace: String = "") { self.track = track; self.namespace = namespace }

    public func segmentID(_ itemID: String) -> String {
        namespace.isEmpty ? "\(track.rawValue):\(itemID)" : "\(track.rawValue):\(namespace):\(itemID)"
    }

    public mutating func discard(itemID: String) {
        items.removeValue(forKey: itemID); stopped.remove(itemID)
        rememberCompletion(itemID)
    }

    /// Manual commit during active VAD may create a different item ID. Keep its captured start time.
    public mutating func replaceActiveItems(_ oldIDs: Set<String>, with id: String) -> [String] {
        let old = oldIDs.filter { $0 != id }.compactMap { items[$0] }
        guard let start = old.map(\.start).min() else { return [] }
        for oldID in oldIDs where oldID != id { discard(itemID: oldID) }
        if var current = items[id] {
            current.start = min(current.start, start); items[id] = current
        } else {
            items[id] = .init(id: segmentID(id), track: track, start: start, end: start, text: "")
        }
        return old.filter { !$0.text.isEmpty }.map(\.id)
    }

    public mutating func consume(_ data: Data, fallbackTime: Double) throws -> TranscriptSegment? {
        try consume(RealtimeEvent(data), fallbackTime: fallbackTime)
    }

    public mutating func consume(_ event: RealtimeEvent, fallbackTime: Double) throws -> TranscriptSegment? {
        guard fallbackTime.isFinite, fallbackTime >= 0 else { throw CopilotError.invalidResponse }
        if let eventID = event.eventID {
            guard seenEvents.insert(eventID).inserted else { return nil }
            eventOrder.append(eventID)
            if eventOrder.count > 4096 { seenEvents.remove(eventOrder.removeFirst()) }
        }
        if event.type == "error" || event.type == "conversation.item.input_audio_transcription.failed" {
            throw CopilotError.message("云端转写返回错误；此段可能未识别，请检查模型权限或网络。")
        }
        guard let id = event.itemID, !id.isEmpty, !completed.contains(id) else { return nil }
        var segment = items[id] ?? .init(id: segmentID(id), track: track,
            start: max(timeOffset, lastCommittedEnd), end: max(timeOffset, lastCommittedEnd), text: "")
        switch event.type {
        case "input_audio_buffer.speech_started":
            if let time = event.audioStart { segment.start = max(0, timeOffset + time) }
            segment.end = max(segment.start, segment.end)
        case "input_audio_buffer.speech_stopped":
            if let time = event.audioEnd { segment.end = max(segment.start, timeOffset + time); stopped.insert(id) }
        case "input_audio_buffer.committed":
            if !stopped.contains(id) { segment.end = max(segment.start, fallbackTime); stopped.insert(id) }
            lastCommittedEnd = max(lastCommittedEnd, segment.end)
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event.text else { throw CopilotError.invalidResponse }
            segment.text += delta
            if !stopped.contains(id) { segment.end = max(segment.end, fallbackTime) }
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = event.text else { throw CopilotError.invalidResponse }
            segment.text = transcript; segment.isFinal = true
            if !stopped.contains(id) { segment.end = max(segment.end, fallbackTime) }
            rememberCompletion(id); stopped.remove(id)
        default: return nil
        }
        guard segment.text.utf8.count <= 262_144 else { throw CopilotError.message("云端单段转写超过处理上限。") }
        segment.revision += 1
        if segment.isFinal { items.removeValue(forKey: id) } else { items[id] = segment }
        guard items.count <= 128 else { throw CopilotError.message("云端转写待完成片段过多，请重新连接。") }
        return segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : segment
    }

    private mutating func rememberCompletion(_ id: String) {
        if completed.insert(id).inserted { completionOrder.append(id) }
        if completionOrder.count > 2048 { completed.remove(completionOrder.removeFirst()) }
    }
}
