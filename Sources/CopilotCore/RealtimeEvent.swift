import Foundation

/// Only protocol fields are decoded. Server error messages may echo user content and are not logged.
public struct RealtimeEvent: Sendable {
    public var type: String
    public var eventID: String?
    public var itemID: String?
    public var previousItemID: String?
    public var text: String?
    public var audioStart: Double?
    public var audioEnd: Double?
    public var errorCode: String?
    public var errorType: String?
    public var failedClientEventID: String?
    public var sessionModel: String?
    public var validTranscriptionSession: Bool
    public var serverVAD: Bool
    public var vadDisabled: Bool

    public init(_ data: Data) throws {
        guard data.count <= 1_048_576,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else { throw CopilotError.invalidResponse }
        self.type = type; eventID = raw["event_id"] as? String; itemID = raw["item_id"] as? String
        previousItemID = raw["previous_item_id"] as? String
        text = type == "conversation.item.input_audio_transcription.completed" ? raw["transcript"] as? String : raw["delta"] as? String
        if ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed"].contains(type) {
            guard let itemID, !itemID.isEmpty else { throw CopilotError.invalidResponse }
        }
        func seconds(_ key: String) throws -> Double? {
            guard let value = raw[key] else { return nil }
            guard let ms = value as? Double, ms.isFinite, ms >= 0 else { throw CopilotError.invalidResponse }
            return ms / 1000
        }
        audioStart = try seconds("audio_start_ms"); audioEnd = try seconds("audio_end_ms")
        let error = raw["error"] as? [String: Any]
        errorCode = error?["code"] as? String; errorType = error?["type"] as? String
        failedClientEventID = error?["event_id"] as? String
        let session = raw["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let format = input?["format"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        sessionModel = transcription?["model"] as? String
        validTranscriptionSession = session?["type"] as? String == "transcription"
            && format?["type"] as? String == "audio/pcm" && format?["rate"] as? Int == 24000
        serverVAD = (input?["turn_detection"] as? [String: Any])?["type"] as? String == "server_vad"
        vadDisabled = input?["turn_detection"] is NSNull
    }
}
