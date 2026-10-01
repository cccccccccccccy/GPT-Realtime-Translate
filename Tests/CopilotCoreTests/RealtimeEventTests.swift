import Foundation
import Testing
@testable import CopilotCore

private func rt(_ json: String) throws -> RealtimeEvent { try .init(Data(json.utf8)) }

@Test func cloudFinalsKeepSpeechEndDespiteLaterAudioAndDuplicateDeltas() throws {
    var reducer = RealtimeTranscriptReducer(track: .remote, namespace: "connection-1")
    reducer.timeOffset = 50
    _ = try reducer.consume(rt(#"{"type":"input_audio_buffer.speech_started","item_id":"one","audio_start_ms":1000}"#), fallbackTime: 52)
    _ = try reducer.consume(rt(#"{"type":"input_audio_buffer.speech_stopped","item_id":"one","audio_end_ms":3000}"#), fallbackTime: 54)
    let delta = try rt(#"{"type":"conversation.item.input_audio_transcription.delta","event_id":"delta-1","item_id":"one","delta":"not "}"#)
    _ = try reducer.consume(delta, fallbackTime: 90)
    #expect(try reducer.consume(delta, fallbackTime: 91) == nil)
    let finalValue = try reducer.consume(rt(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"not necrosis"}"#), fallbackTime: 100)
    let final = try #require(finalValue)
    #expect(final.start == 51 && final.end == 53)
    #expect(final.id == "remote:connection-1:one")
    #expect(reducer.pendingCount == 0)
    var next = RealtimeTranscriptReducer(track: .remote, namespace: "connection-2")
    next.timeOffset = 120
    let otherValue = try next.consume(rt(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"new"}"#), fallbackTime: 121)
    let other = try #require(otherValue)
    #expect(other.id != final.id && other.start == 120)
}

@Test func cloudCommittedOrderAndManualItemReplacementKeepCaptureTiming() throws {
    var reducer = RealtimeTranscriptReducer(track: .microphone)
    reducer.timeOffset = 10
    _ = try reducer.consume(rt(#"{"type":"input_audio_buffer.speech_started","item_id":"active","audio_start_ms":2000}"#), fallbackTime: 12)
    _ = try reducer.consume(rt(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"active","delta":"draft"}"#), fallbackTime: 14)
    #expect(reducer.replaceActiveItems(["active"], with: "committed") == ["microphone:active"])
    _ = try reducer.consume(rt(#"{"type":"input_audio_buffer.committed","item_id":"committed","previous_item_id":null}"#), fallbackTime: 14)
    _ = try reducer.consume(rt(#"{"type":"input_audio_buffer.committed","item_id":"second","previous_item_id":"committed"}"#), fallbackTime: 17)
    let secondValue = try reducer.consume(rt(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"second","transcript":"second"}"#), fallbackTime: 40)
    let second = try #require(secondValue)
    let firstValue = try reducer.consume(rt(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"committed","transcript":"first"}"#), fallbackTime: 41)
    let first = try #require(firstValue)
    #expect(first.start == 12 && first.end == 14)
    #expect(second.start == 14 && second.end == 17)
    #expect(reducer.pendingCount == 0)
    #expect(try reducer.consume(rt(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"active","delta":"late old draft"}"#), fallbackTime: 50) == nil)
}

@Test func cloudEventsValidateTimingAndRetainOnlySafeErrorMetadata() throws {
    #expect(throws: CopilotError.self) { try rt(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":-1}"#) }
    let error = try rt(#"{"type":"error","error":{"event_id":"finish-1","type":"invalid_request_error","code":"input_audio_buffer_commit_empty","message":"Do not surface this arbitrary server message"}}"#)
    #expect(error.failedClientEventID == "finish-1")
    #expect(error.errorCode == "input_audio_buffer_commit_empty")
    let missingFormat = try rt(#"{"type":"session.updated","session":{"type":"transcription","audio":{"input":{"transcription":{"model":"gpt-live-transcribe"},"turn_detection":null}}}}"#)
    #expect(!missingFormat.validTranscriptionSession && missingFormat.vadDisabled)
}
