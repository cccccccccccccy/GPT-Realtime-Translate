import Testing
import Foundation
import CryptoKit
@testable import CopilotCore

@Test func lateUpdatesCannotOverwriteFinalOrCorrections() {
    var meeting = MeetingSession()
    let original = TranscriptSegment(id: "remote-1", track: .remote, start: 1, end: 2, text: "six", revision: 1, isFinal: true)
    let inserted = meeting.upsert(original)
    #expect(inserted)
    let regressed = meeting.upsert(.init(id: original.id, track: .remote, start: 1, end: 2, text: "sixty", revision: 2, isFinal: false))
    #expect(!regressed)
    meeting.correct(id: original.id, text: "six animals")
    let overwritten = meeting.upsert(.init(id: original.id, track: .remote, start: 1, end: 2, text: "wrong", revision: 4, isFinal: true))
    #expect(!overwritten)
    #expect(meeting.segments[0].text == "six animals")
    let translated = meeting.translate(original.reference, text: "过期翻译")
    #expect(!translated)
}

@Test func outOfOrderSegmentsFollowAudioTimeline() {
    var meeting = MeetingSession()
    meeting.upsert(.init(id: "later", track: .microphone, start: 5, end: 6, text: "My reply", isFinal: true))
    meeting.upsert(.init(id: "earlier", track: .remote, start: 1, end: 4, text: "Question", isFinal: true))
    #expect(meeting.segments.map(\.id) == ["earlier", "later"])
    #expect(meeting.segments.map(\.track) == [.remote, .microphone])
}

@Test func credentialsAreBoundToEndpoint() throws {
    var config = TextProviderConfiguration(kind: .deepSeek)
    let original = config.credentialAccount
    config.baseURL = "https://different.example/v1"
    #expect(original != config.credentialAccount)
    config.baseURL = "http://different.example/v1"
    #expect(throws: CopilotError.self) { try config.validatedBaseURL() }
    config.baseURL = "https://user:secret@example.com/v1"
    #expect(throws: CopilotError.self) { try config.validatedBaseURL() }
}

@Test func encryptedRepositoryRoundTripsAndRejectsTampering() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try MeetingRepository(directory: directory, key: SymmetricKey(size: .bits256))
    var meeting = MeetingSession()
    meeting.title = "PRIVATE_RESEARCH_TEXT"
    try await repo.save(meeting)
    let recovered = try await repo.load(meeting.id)
    #expect(recovered.title == meeting.title)
    let path = directory.appendingPathComponent(meeting.id.uuidString + ".meeting")
    var sealed = try Data(contentsOf: path)
    #expect(sealed.range(of: Data(meeting.title.utf8)) == nil)
    sealed[sealed.count / 2] ^= 0x01
    try sealed.write(to: path)
    await #expect(throws: (any Error).self) { try await repo.load(meeting.id) }
}
