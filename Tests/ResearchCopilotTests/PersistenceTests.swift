import Testing
import Foundation
import CryptoKit
@testable import CopilotCore
@testable import ResearchCopilot

private actor FaultStorage: MeetingStorage {
    var meetings: [UUID: MeetingSession] = [:]
    var failSave = false
    var failDelete = false
    var failConfiguration = false
    var holdSave = false
    var saveWaiter: CheckedContinuation<Void, Never>?
    var saveCalls = 0
    var deleteCalls = 0

    func configure(saveFailure: Bool = false, deleteFailure: Bool = false,
                   configurationFailure: Bool = false, hold: Bool = false) {
        failSave = saveFailure; failDelete = deleteFailure
        failConfiguration = configurationFailure; holdSave = hold
    }
    func seed(_ meeting: MeetingSession) { meetings[meeting.id] = meeting }
    func releaseSave() { holdSave = false; saveWaiter?.resume(); saveWaiter = nil }
    func save(_ meeting: MeetingSession) async throws {
        saveCalls += 1
        if holdSave { await withCheckedContinuation { saveWaiter = $0 } }
        if failSave { throw CopilotError.message("injected write failure") }
        meetings[meeting.id] = meeting
    }
    func load(_ id: UUID) throws -> MeetingSession {
        guard let meeting = meetings[id] else { throw CopilotError.message("missing") }
        return meeting
    }
    func delete(_ id: UUID) throws {
        deleteCalls += 1
        if failDelete { throw CopilotError.message("injected delete failure") }
        meetings.removeValue(forKey: id)
    }
    func listIDs() -> [UUID] { Array(meetings.keys) }
    func saveConfiguration(_ configuration: AppConfiguration) {}
    func loadConfiguration() throws -> AppConfiguration? {
        if failConfiguration { throw CopilotError.message("injected settings failure") }
        return nil
    }
    func saveProfile(_ profile: ResearchProfile) {}
    func loadProfile() -> ResearchProfile? { nil }
}

private func session(ended: Bool = true) -> MeetingSession {
    var result = MeetingSession()
    result.title = "Synthetic storage validation"
    result.endedAt = ended ? Date() : nil
    result.upsert(.init(id: "remote-1", track: .remote, start: 1, end: 3,
                        text: "What evidence supports the time point?", isFinal: true))
    return result
}

private func waitForSave(_ storage: FaultStorage) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await storage.saveCalls == 0 {
        if ContinuousClock.now >= deadline { throw CopilotError.message("save did not start") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func missingRepositoryCannotReportSuccessfulSave() async {
    let controller = MeetingController(repositoryFactory: { throw CopilotError.message("unavailable") })
    await controller.initialize()
    controller.meeting = session()
    let saved = await controller.saveNow()
    #expect(!saved && !controller.storageReady && controller.hasUnsavedChanges)
    #expect(controller.storageStatus.contains("保存失败"))
}

@Test @MainActor func saveFailureKeepsCurrentMeetingDuringNavigationAndQuit() async {
    let storage = FaultStorage()
    let target = session()
    await storage.seed(target)
    await storage.configure(saveFailure: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    let current = session()
    controller.meeting = current
    let created = await controller.newMeeting()
    let opened = await controller.openMeeting(target)
    let canQuit = await controller.prepareForTermination()
    #expect(!created && !opened && !canQuit)
    #expect(controller.meeting.id == current.id && controller.hasUnsavedChanges)
    #expect(!controller.isQuitting && !controller.isLibraryBusy)
    await storage.configure()
    let recovered = await controller.newMeeting()
    #expect(recovered && controller.meeting.id != current.id)
    let persisted = try? await storage.load(current.id)
    #expect(persisted?.segments.first?.text == current.segments.first?.text)
}

@Test @MainActor func titleEditsAreAutosavedWithoutAnotherTranscriptEvent() async throws {
    let storage = FaultStorage()
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    controller.meeting = session()
    let firstSave = await controller.saveNow()
    #expect(firstSave)
    controller.meeting.title = "Edited title awaiting autosave"
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.hasUnsavedChanges && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let persisted = try await storage.load(controller.meeting.id)
    #expect(persisted.title == controller.meeting.title)
    #expect(!controller.hasUnsavedChanges)
}

@Test @MainActor func openingCurrentHistoryRowReloadsAfterSaving() async throws {
    let storage = FaultStorage()
    let old = session()
    await storage.seed(old)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    controller.meeting = old
    controller.correct(id: "remote-1", text: "Corrected before reopening an old history row")
    let opened = await controller.openMeeting(old)
    #expect(opened)
    #expect(controller.meeting.segments[0].manuallyCorrected)
    #expect(controller.meeting.segments[0].text.hasPrefix("Corrected"))
    #expect(!controller.hasUnsavedChanges)
}

@Test @MainActor func corruptHistoryFileDoesNotHideHealthyEncryptedMeetings() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = SymmetricKey(size: .bits256)
    let repository = try MeetingRepository(directory: folder, key: key)
    let good = session(ended: false)
    try await repository.save(good)
    let corruptID = UUID()
    try Data("invalid encrypted record".utf8).write(to: folder.appendingPathComponent(corruptID.uuidString + ".meeting"))
    let reopened = try MeetingRepository(directory: folder, key: key)
    let controller = MeetingController(repositoryFactory: { reopened })
    await controller.initialize()
    await controller.loadHistory()
    #expect(controller.history.map(\.id) == [good.id])
    #expect(controller.unreadableMeetingIDs == [corruptID])
    let opened = await controller.openMeeting(good)
    #expect(opened && !controller.isRecording && !controller.isStarting)
    #expect(controller.meeting.recoveredAt != nil && controller.meeting.endedAt == nil)
    #expect(controller.meeting.gaps.count == 1)
    #expect(controller.meeting.segments[0].text == good.segments[0].text)
    let saveDeadline = ContinuousClock.now + .seconds(2)
    while controller.hasUnsavedChanges && ContinuousClock.now < saveDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let recoveredOnDisk = try await reopened.load(good.id)
    #expect(!controller.hasUnsavedChanges && recoveredOnDisk.recoveredAt != nil)
    let openedAgain = await controller.openMeeting(good)
    #expect(openedAgain && controller.meeting.gaps.count == 1)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(corruptID.uuidString + ".meeting").path))
}

@Test @MainActor func deletionWaitsForPendingWriteAndDoesNotResurrectRecord() async throws {
    let storage = FaultStorage()
    await storage.configure(hold: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    let current = session()
    controller.meeting = current
    let save = Task { await controller.saveNow() }
    try await waitForSave(storage)
    let deletion = Task { await controller.deleteMeeting(current) }
    await Task.yield()
    #expect(await storage.deleteCalls == 0)
    await storage.releaseSave()
    #expect(await save.value)
    await deletion.value
    #expect(await storage.deleteCalls == 1)
    #expect(await storage.meetings[current.id] == nil)
    #expect(controller.meeting.id != current.id)
    #expect(!controller.isSaving && !controller.hasUnsavedChanges)
}

@Test @MainActor func deletionFailurePreservesCurrentRecordAndCanBeRetried() async {
    let storage = FaultStorage()
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    let current = session()
    controller.meeting = current
    _ = await controller.saveNow()
    await storage.configure(deleteFailure: true)
    await controller.deleteMeeting(current)
    #expect(controller.meeting.id == current.id)
    #expect(await storage.meetings[current.id] != nil)
    await storage.configure()
    await controller.deleteMeeting(current)
    #expect(controller.meeting.id != current.id)
    #expect(await storage.meetings[current.id] == nil)
}

@Test @MainActor func inFlightSaveDoesNotMarkNewerEditsAsSaved() async throws {
    let storage = FaultStorage()
    await storage.configure(hold: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    controller.meeting = session()
    let first = Task { await controller.saveNow() }
    try await waitForSave(storage)
    controller.meeting.title = "Newer revision"
    await storage.releaseSave()
    #expect(await first.value)
    #expect(controller.hasUnsavedChanges)
    #expect(controller.storageStatus == "有更改待保存")
    let latest = await controller.saveNow()
    #expect(latest && !controller.hasUnsavedChanges)
    let persisted = try await storage.load(controller.meeting.id)
    #expect(persisted.title == "Newer revision")
}

@Test @MainActor func storageInitializationCanRecoverAfterFailure() async {
    let storage = FaultStorage()
    await storage.configure(configurationFailure: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    #expect(!controller.storageReady && !controller.isInitializingStorage)
    await storage.configure()
    await controller.initialize()
    #expect(controller.storageReady && !controller.isInitializingStorage)
}

@Test @MainActor func terminationWaitsForSavedSnapshot() async throws {
    let storage = FaultStorage()
    await storage.configure(hold: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    controller.meeting = session()
    let quitting = Task { await controller.prepareForTermination() }
    try await waitForSave(storage)
    #expect(controller.isQuitting && controller.isSaving)
    await storage.releaseSave()
    #expect(await quitting.value)
    #expect(!controller.hasUnsavedChanges && !controller.isSaving)
}

@Test @MainActor func overlappingSavesCommitInOrder() async throws {
    let storage = FaultStorage()
    await storage.configure(hold: true)
    let controller = MeetingController(repositoryFactory: { storage })
    await controller.initialize()
    controller.meeting = session()
    let older = Task { await controller.saveNow() }
    try await waitForSave(storage)
    controller.meeting.title = "Latest revision wins"
    let newer = Task { await controller.saveNow() }
    await Task.yield()
    #expect(await storage.saveCalls == 1)
    await storage.releaseSave()
    #expect(await older.value)
    #expect(await newer.value)
    let persisted = try await storage.load(controller.meeting.id)
    #expect(persisted.title == "Latest revision wins")
    #expect(!controller.hasUnsavedChanges && !controller.isSaving)
}

@Test @MainActor func encryptedHistoryPreservesPinnedAnswersCorrectionsAndExportSeparation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = SymmetricKey(size: .bits256)
    let repository = try MeetingRepository(directory: folder, key: key)
    var original = session()
    original.microphoneIncluded = true
    original.profile.facts = [.init(content: "Histology comparison is planned.", kind: .confirmedPlan)]
    original.upsert(.init(id: "self-1", track: .microphone, start: 4, end: 6,
                          text: "We plan to compare the imaging with histology.", isFinal: true))
    _ = original.translate(original.segments[0].reference, text: "这个时间点有什么依据？")
    let content = AnswerContent(sourceIDs: ["remote-1"], factIDs: [], coreQuestion: "Time point rationale",
        intent: "Clarification", english: "Could you clarify the comparison?", chinese: "您能澄清比较对象吗？",
        shortAnswer: "Could you clarify?", cautiousAnswer: "We need to confirm that.",
        clarification: "Which comparison?", missingInformation: [], warnings: [])
    var pinned = AnswerSuggestion(sources: [original.segments[0].reference], content: content, provider: "Fixture", model: "offline")
    pinned.pinned = true
    original.answers = [pinned, AnswerSuggestion(sources: [original.segments[0].reference], content: content, provider: "Fixture", model: "offline")]
    original.summary = MeetingSummary(topics: [], questions: [],
        actualAnswers: [.init(text: "We plan to compare the imaging with histology.", sourceIDs: ["self-1"])],
        decisions: [], actions: [], unresolved: [])
    try await repository.save(original)
    let controller = MeetingController(repositoryFactory: { repository })
    await controller.initialize()
    let opened = await controller.openMeeting(original)
    #expect(opened && controller.currentAnswerID == pinned.id && controller.currentAnswer?.pinned == true)
    controller.correct(id: "remote-1", text: "What evidence supports this timing?")
    #expect(controller.currentAnswer?.stale == true && controller.meeting.summaryStale)
    #expect(controller.meeting.segments[0].translation == nil)
    let saved = await controller.saveNow()
    #expect(saved)
    let freshRepository = try MeetingRepository(directory: folder, key: key)
    let recovered = try await freshRepository.load(original.id)
    #expect(recovered.profile.facts == original.profile.facts)
    #expect(recovered.segments.map(\.track) == [.remote, .microphone])
    #expect(recovered.answers[0].pinned && recovered.answers[0].stale)
    #expect(recovered.segments[0].manuallyCorrected && recovered.summaryStale)
    let exported = MarkdownExport.render(recovered)
    let sections = exported.components(separatedBy: "## AI 回答建议（不代表实际发言）")
    #expect(sections.count == 2)
    #expect(!sections[0].contains(content.english) && sections[1].contains(content.english))
    #expect(sections[0].contains("What evidence supports this timing?"))
    #expect(sections[0].contains("We plan to compare the imaging with histology."))
}

@Test @MainActor func citationNavigationSelectsExactSourceAndDoesNotGenerateAnswers() {
    let controller = MeetingController(reviewOnly: true, repositoryFactory: { FaultStorage() })
    controller.meeting = session()
    let original = controller.meeting.segments[0]
    controller.meeting.correct(id: original.id, text: "A corrected question")
    let citations = CitationResolver.resolve([original.id, "missing"], in: controller.meeting, snapshots: [original])
    let selected = controller.selectSource(citations[0])
    #expect(selected && controller.selectedSegments == [original.id])
    #expect(controller.sourceNavigationNotice?.contains("较早版本") == true)
    #expect(controller.meeting.answers.isEmpty && !controller.answerBusy && !controller.isRecording)
    let missing = controller.selectSource(citations[1])
    #expect(!missing && controller.selectedSegments == [original.id])
}
