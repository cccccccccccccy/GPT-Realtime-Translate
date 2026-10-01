import SwiftUI
import AppKit
import Combine
import CopilotCore
import CopilotSpeech

@MainActor
final class MeetingController: ObservableObject {
    @Published var meeting = MeetingSession() {
        didSet {
            meetingRevision &+= 1
            if !isReplacingMeeting { scheduleSave() }
        }
    }
    @Published var configuration = AppConfiguration() {
        didSet {
            if oldValue.cloudTextEnabled != configuration.cloudTextEnabled || oldValue.selectedText != configuration.selectedText {
                cancelTextTasks()
                analysis = nil
                textStatus = configuration.cloudTextEnabled ? "文字服务待命" : "文字服务未启用"
            }
        }
    }
    @Published var profile = ResearchProfile()
    @Published var applications: [CaptureApplication] = []
    @Published var selectedApplication: Int32?
    @Published var selectedSegments: Set<String> = []
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var isPreparing = false
    @Published var isCancellingPreparation = false
    @Published var modelReady = false
    @Published var modelStatus = "尚未准备"
    @Published var captureStatus = "尚未连接"
    @Published var textStatus = "文字服务未启用"
    @Published var storageStatus = "正在准备本地存储"
    @Published var errorMessage: String?
    @Published var analysis: UtteranceAnalysis?
    @Published var currentAnswerID: String?
    @Published var answerBusy = false
    @Published var answerDraft = ""
    @Published var summaryBusy = false
    @Published var remoteLevel: Double = 0
    @Published var microphoneLevel: Double = 0
    @Published var history: [MeetingSession] = []
    @Published var unreadableMeetingIDs: [UUID] = []
    @Published var historyLoading = false
    @Published var storageReady = false
    @Published var isInitializingStorage = false
    @Published var isLibraryBusy = false
    @Published var isSaving = false
    @Published var isQuitting = false
    @Published var sourceNavigationNotice: String?
    @Published var isTestingAudio = false
    @Published var audioProbeReport: AudioSourceProbeReport?
    @Published var captureStopUnconfirmed = false
    @Published var permissionStatus = CapturePermissionStatus.read()
    let reviewOnly: Bool

    let credentials = CredentialStore()
    private let audio: any AudioCapturing
    private let speechStarter: any SpeechSessionStarting
    private var audioProbe: AudioSourceProbe?
    private var probeTask: Task<Void, Never>?
    private var probeRunID: UUID?
    private var stopProbeRequested = false
    private let localASR = WhisperKitProvider()
    private var activeASR: (any SpeechRecognitionProvider)?
    private var repository: (any MeetingStorage)?
    private let repositoryFactory: () throws -> any MeetingStorage
    private var meetingRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var savedMeetingID: UUID?
    private var isReplacingMeeting = false
    private var persistenceTail: Task<Bool, Never>?
    private var queuedWrites = 0
    private var saveScheduleID = UUID()
    private var cancelStartup = false
    private var frames: AsyncStream<AudioFrame>.Continuation?
    private var frameTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var summaryRequestID = UUID()
    private var translations: [SourceReference] = []
    private var translationWorkerID = UUID()
    private var requestID = UUID()
    private var lastMeterUpdate: [AudioTrack: Date] = [:]
    private var captureRunID: UUID?
    private var captureStartupFailure: String?
    private var lastRemoteVoice = Date.distantPast
    private var sleepObserver: AnyCancellable?

    init(reviewOnly: Bool = false, audio: any AudioCapturing = AudioCaptureService(),
         speechStarter: any SpeechSessionStarting = SpeechSessionStarter(), repositoryFactory: @escaping () throws -> any MeetingStorage = {
        try MeetingRepository.openDefault(credentials: CredentialStore())
    }) {
        self.repositoryFactory = repositoryFactory; self.reviewOnly = reviewOnly; self.audio = audio
        self.speechStarter = speechStarter
    }

    var hasUnsavedChanges: Bool {
        meeting.hasRecord && (savedMeetingID != meeting.id || savedRevision != meetingRevision)
    }
    var libraryActionsDisabled: Bool { isRecording || isTestingAudio || captureStopUnconfirmed || isStarting || isStopping || isLibraryBusy || isQuitting }

    var currentAnswer: AnswerSuggestion? { meeting.answers.first { $0.id == currentAnswerID } }
    var selectedText: TextProviderConfiguration { configuration.selectedText }
    var elapsed: Double { Date().timeIntervalSince(meeting.startedAt) }
    var selectedTranscript: [TranscriptSegment] {
        let explicit = meeting.segments.filter { selectedSegments.contains($0.id) && $0.isFinal }
        return explicit.isEmpty ? latestRemoteTurn() : explicit
    }

    func initialize() async {
        guard repository == nil, !isInitializingStorage else { return }
        isInitializingStorage = true
        defer { isInitializingStorage = false }
        storageStatus = "正在准备本地存储"
        if sleepObserver == nil { sleepObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.handleSystemSleep() }
            } }
        do {
            let readyRepository = try repositoryFactory()
            let storedConfiguration = try await readyRepository.loadConfiguration()
            let storedProfile = try await readyRepository.loadProfile()
            if let storedConfiguration { configuration = storedConfiguration }
            if let storedProfile { profile = storedProfile }
            repository = readyRepository
            storageReady = true
            meeting.profile = profile
            storageStatus = "本地加密保存已就绪"
            textStatus = configuration.cloudTextEnabled ? "文字服务待命" : "文字服务未启用"
            if reviewOnly {
                await loadHistory()
                if let example = history.first { await openMeeting(example) }
            }
        } catch { storageReady = false; storageStatus = "本地保存不可用，可重试"; fail(error) }
    }

    func handleSystemSleep() async {
        guard isRecording || isStarting || isTestingAudio else { return }
        let reason = "系统进入睡眠，记录可能中断。唤醒后请检查音源并手动开始。"
        audio.stopForwarding()
        if isTestingAudio {
            audioProbe?.recordIssue(reason)
            await stopAudioTest()
            if !captureStopUnconfirmed { captureStatus = reason }
        } else if isStarting {
            cancelStartup = true
            captureStartupFailure = reason
            addGap(reason)
            captureStatus = reason
        } else {
            addGap(reason)
            await stop()
            if !captureStopUnconfirmed { captureStatus = reason }
        }
    }

    func refreshApplications() async {
        guard !reviewOnly, !libraryActionsDisabled else { return }
        permissionStatus = .read()
        do {
            applications = try await audio.applications()
            if !applications.contains(where: { $0.id == selectedApplication }) { selectedApplication = applications.first?.id }
            captureStatus = applications.isEmpty ? "请先打开 Zoom" : "已找到 Zoom，尚未采集"
        } catch {
            captureStatus = (error as? CaptureFailure) == .screenPermission ? "需要录屏与系统录音权限" : "无法读取 Zoom 音源"
            fail(error)
        }
        permissionStatus = .read()
    }

    func startAudioTest() async {
        guard !reviewOnly, !libraryActionsDisabled, !isPreparing else { return }
        guard let application = applications.first(where: { $0.id == selectedApplication }) else {
            errorMessage = "请先刷新并选择 Zoom 音源。"; return
        }
        isTestingAudio = true; isStarting = true; stopProbeRequested = false
        let runID = UUID(); probeRunID = runID
        let probe = AudioSourceProbe(applicationID: application.id, bundleID: application.bundleID)
        audioProbe = probe; audioProbeReport = probe.snapshot()
        remoteLevel = 0; microphoneLevel = 0
        captureStatus = "正在启动音源检测（麦克风关闭）"
        do {
            try await audio.start(applicationID: application.id, microphone: false, sampleRate: 16000,
                onFrame: { frame in probe.accept(frame) }, onFailure: { [weak self] issue in
                    Task { @MainActor in
                        guard let self, self.probeRunID == runID else { return }
                        switch issue {
                        case .missingAudio(let reason): probe.recordIssue(reason)
                        case .interrupted(let reason):
                            probe.recordIssue(reason); await self.stopAudioTest()
                        }
                    }
                })
            isStarting = false
            if stopProbeRequested || isQuitting { await stopAudioTest(); return }
            captureStatus = "检测 Zoom 音源中 · 30 秒后自动停止 · 麦克风关闭"
            probeTask = Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(30)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, self.probeRunID == runID else { return }
                    let report = probe.snapshot(); self.audioProbeReport = report
                    self.remoteLevel = min(1, report.currentRMS * 12)
                    if ContinuousClock.now >= deadline { await self.stopAudioTest(); return }
                }
            }
        } catch {
            isStarting = false; probeRunID = nil
            let stopped = await stopCapture()
            audioProbeReport = probe.finish(confirmed: stopped, issue: CaptureFailure.classify(error, operation: "检测音源").localizedDescription)
            isTestingAudio = false; remoteLevel = 0
            captureStatus = stopped ? "音源检测未启动" : "采集停止尚未确认，请重试停止"
            fail(error)
        }
        permissionStatus = .read()
    }

    func stopAudioTest() async {
        guard isTestingAudio, !isStopping else { return }
        stopProbeRequested = true
        guard !isStarting else { return }
        isStopping = true; probeRunID = nil
        probeTask?.cancel(); probeTask = nil
        let stopped = await stopCapture()
        audioProbeReport = audioProbe?.finish(confirmed: stopped)
        isTestingAudio = false; isStopping = false; remoteLevel = 0; microphoneLevel = 0
        captureStatus = stopped ? "音源检测已结束" : "采集停止尚未确认，请重试停止"
    }

    private func stopCapture() async -> Bool {
        do { try await audio.stop() } catch { fail(error) }
        captureStopUnconfirmed = audio.hasOutstandingStream
        return !captureStopUnconfirmed
    }

    func retryCaptureStop() async {
        guard captureStopUnconfirmed, !isStarting, !isStopping else { return }
        isStopping = true
        let stopped = await stopCapture()
        if let audioProbe { audioProbeReport = audioProbe.finish(confirmed: stopped) }
        captureStatus = stopped ? "已停止采集" : "采集停止尚未确认，请重试停止"
        isStopping = false
    }

    func exportAudioProbe() {
        guard !isTestingAudio, let report = audioProbeReport else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "zoom-audio-probe.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch { errorMessage = "检测报告导出失败，请检查保存位置。" }
    }

    func beginModelPreparation(download: Bool) {
        guard !reviewOnly else { return }
        guard !libraryActionsDisabled && !isPreparing else { return }
        isPreparing = true; modelReady = false
        isCancellingPreparation = false
        let model = configuration.localModel, folder = configuration.modelFolder
        modelPreparationTask = Task { [weak self] in
            await self?.prepareModel(model: model, folder: folder, download: download)
        }
    }

    func cancelModelPreparation() {
        guard isPreparing else { return }
        isCancellingPreparation = true
        modelStatus = "正在取消；若正在编译模型，将在当前步骤结束后释放资源…"
        modelPreparationTask?.cancel()
    }

    private func prepareModel(model: String, folder: String, download: Bool) async {
        defer { isPreparing = false; isCancellingPreparation = false; modelPreparationTask = nil }
        do {
            let folder = try await localASR.prepare(model: model, folder: folder,
                                                   allowDownload: download) { [weak self] message in
                await MainActor.run { if self?.isCancellingPreparation == false { self?.modelStatus = message } }
            }
            try Task.checkCancellation()
            configuration.modelFolder = folder; modelReady = true
            await saveSettings()
        } catch {
            if Task.isCancelled || error is CancellationError {
                modelStatus = "模型准备已取消；可重新下载或加载。"
            } else { modelStatus = "模型准备失败"; fail(error) }
        }
    }

    func chooseModelFolder() {
        guard !isPreparing && !isRecording && !isStarting else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "导入模型目录"
        if panel.runModal() == .OK, let folder = panel.url {
            configuration.modelFolder = folder.path; modelReady = false; modelStatus = "已选择目录，请加载模型"
        }
    }

    func saveSettings() async {
        guard !isLibraryBusy && !isQuitting else { return }
        do {
            guard let repository else { throw CopilotError.message("本地存储尚未就绪，设置未能保存。") }
            if configuration.cloudTextEnabled { _ = try configuration.selectedText.validatedBaseURL() }
            try await repository.saveConfiguration(configuration)
            try await repository.saveProfile(profile)
            if meeting.profile != profile {
                meeting.profile = profile
                for index in meeting.answers.indices { meeting.answers[index].stale = true }
                meeting.summaryStale = meeting.summary != nil
                cancelTextTasks()
            }
            textStatus = configuration.cloudTextEnabled ? "文字服务待命" : "文字服务未启用"
            scheduleSave()
        } catch { fail(error) }
    }

    func start() async {
        guard !reviewOnly else { return }
        guard !libraryActionsDisabled else { return }
        guard repository != nil else { errorMessage = "本地加密存储尚未就绪，请先处理存储错误。"; return }
        guard let application = selectedApplication else { errorMessage = "请先刷新并选择 Zoom 音源。"; return }
        if meeting.hasRecord, !(await newMeeting()) { return }
        guard !isQuitting else { return }
        isStarting = true; cancelStartup = false
        defer { isStarting = false }
        let runID = UUID()
        captureRunID = runID; captureStartupFailure = nil
        meeting.startedAt = Date(); meeting.microphoneIncluded = configuration.captureMicrophone
        meeting.profile = profile
        meeting.configuration = "\(configuration.speechProvider.rawValue) / \(selectedText.kind.title) / \(selectedText.fastModel) / \(selectedText.answerModel)"
        do {
            let sessionID = meeting.id
            let onSpeech: @Sendable (SpeechEvent) async -> Void = { [weak self] event in
                await self?.handleSpeech(event, sessionID: sessionID)
            }
            let speech = try await speechStarter.start(configuration: configuration, profile: profile,
                                                       local: localASR, localReady: modelReady, emit: onSpeech)
            activeASR = speech
            let captureRate = await speech.sampleRate
            guard !cancelStartup else { throw CancellationError() }
            let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(200))
            frames = continuation
            frameTask = Task { [weak self] in
                for await frame in stream {
                    guard let self, !Task.isCancelled else { break }
                    self.updateMeters(frame)
                    await self.activeASR?.accept(frame)
                }
            }
            try await audio.start(applicationID: application, microphone: configuration.captureMicrophone,
                                  sampleRate: captureRate, onFrame: { [weak self] frame in
                if case .dropped = continuation.yield(frame) {
                    Task { @MainActor in self?.addGap("音频输入积压，有片段未处理。") }
                }
            }, onFailure: { [weak self] issue in
                Task { @MainActor in await self?.handleCaptureIssue(issue, runID: runID) }
            })
            guard !cancelStartup else { throw CancellationError() }
            if let failure = captureStartupFailure { throw CopilotError.message(failure) }
            isRecording = true; captureStatus = "正在采集 Zoom"
            scheduleSave()
        } catch {
            captureRunID = nil
            let stopped = await stopCapture()
            frames?.finish(); frames = nil
            await frameTask?.value; frameTask = nil
            await activeASR?.finish(); activeASR = nil
            captureStatus = stopped ? (captureStartupFailure ?? "采集未启动，请检查音源和权限") : "采集停止尚未确认，请重试停止"
            if captureStartupFailure != nil {
                meeting.endedAt = Date()
                await saveNow()
            }
            if !(error is CancellationError) { fail(error) }
        }
    }

    func stop() async {
        guard isRecording else { return }
        isStopping = true
        defer { isStopping = false }
        captureRunID = nil
        isRecording = false; captureStatus = "正在结束并保存…"
        let stopped = await stopCapture()
        if !stopped { addGap("停止采集尚未确认；已停止向识别器传送新音频，请重试停止。") }
        frames?.finish(); frames = nil
        await frameTask?.value; frameTask = nil
        await activeASR?.finish(); activeASR = nil
        meeting.endedAt = Date(); remoteLevel = 0; microphoneLevel = 0
        captureStatus = stopped ? "已停止采集" : "采集停止尚未确认，请重试停止"
        analysisTask?.cancel()
        await saveNow()
    }

    private func handleCaptureIssue(_ issue: CaptureIssue, runID: UUID) async {
        guard captureRunID == runID else { return }
        switch issue {
        case .missingAudio(let reason): addGap(reason)
        case .interrupted(let reason):
            addGap(reason)
            if isStarting { captureStartupFailure = reason }
            else {
                await stop()
                if !captureStopUnconfirmed { captureStatus = reason }
            }
        }
    }

    func disableMicrophone() async {
        do {
            try await audio.disableMicrophone()
            configuration.captureMicrophone = false; microphoneLevel = 0
            addGap("用户关闭本人麦克风，之后未记录本人发言。")
        } catch {
            configuration.captureMicrophone = false; microphoneLevel = 0
            addGap("关闭本人麦克风未获系统确认，正在停止全部采集。")
            await stop(); fail(CaptureFailure.classify(error, operation: "关闭本人麦克风"))
        }
    }

    private func updateMeters(_ frame: AudioFrame) {
        let rms = sqrt(frame.samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, frame.samples.count)))
        if frame.track == .remote && rms >= 0.008 { lastRemoteVoice = Date() }
        if Date().timeIntervalSince(lastMeterUpdate[frame.track] ?? .distantPast) >= 0.15 {
            if frame.track == .remote { remoteLevel = min(1, rms * 12) }
            else { microphoneLevel = min(1, rms * 12) }
            lastMeterUpdate[frame.track] = Date()
        }
    }

    private func handleSpeech(_ event: SpeechEvent, sessionID: UUID) {
        guard meeting.id == sessionID else { return }
        switch event {
        case .segment(let segment):
            guard meeting.upsert(segment) else { return }
            if segment.isFinal {
                scheduleSave()
                if configuration.cloudTextEnabled && !isQuitting {
                    translations.removeAll { $0.id == segment.id }; translations.append(segment.reference)
                    runTranslations()
                    if segment.track == .remote { scheduleAnalysis() }
                }
            }
        case .gap(let gap): meeting.gaps.append(gap); scheduleSave()
        case .retractPartial(let id): meeting.segments.removeAll { $0.id == id && !$0.isFinal && !$0.manuallyCorrected }
        case .status(let message): modelStatus = message
        }
    }

    private func addGap(_ reason: String) {
        if let previous = meeting.gaps.last, previous.reason == reason, elapsed - previous.time < 5 { return }
        meeting.gaps.append(.init(time: elapsed, reason: reason)); scheduleSave()
    }

    private func service() throws -> IntelligenceService {
        guard !reviewOnly else { throw CopilotError.message("界面验证副本不调用云端服务。") }
        guard configuration.cloudTextEnabled else { throw CopilotError.message("请在设置中启用文字服务。") }
        return .init(provider: HTTPTextProvider(configuration: selectedText, key: try credentials.apiKey(for: selectedText)))
    }

    private func runTranslations() {
        guard translationTask == nil else { return }
        let sessionID = meeting.id
        let workerID = UUID(); translationWorkerID = workerID
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.translationWorkerID == workerID { self.translationTask = nil } }
            while !self.translations.isEmpty && !Task.isCancelled && self.meeting.id == sessionID && self.configuration.cloudTextEnabled {
                let reference = self.translations.removeFirst()
                guard let segment = self.meeting.segments.first(where: { $0.reference == reference }) else { continue }
                do {
                    let service = try self.service()
                    let request = try PromptBuilder.request(task: .translation, meeting: self.meeting, selected: [segment], model: self.selectedText.fastModel)
                    let result = try await service.perform(TranslationResult.self, request: request)
                    try Task.checkCancellation()
                    guard self.meeting.id == sessionID else { return }
                    try EvidenceValidator.sources(result.sourceIDs, in: [segment])
                    if self.meeting.translate(reference, text: result.translation) { self.scheduleSave() }
                    self.textStatus = "文字服务正常"
                } catch is CancellationError { return }
                catch {
                    guard self.meeting.id == sessionID && self.translationWorkerID == workerID else { return }
                    self.textStatus = "翻译暂停，可重试未翻译片段"
                    self.translations.insert(reference, at: 0)
                    self.fail(error); return
                }
            }
        }
    }

    func retryTranslations() {
        translations = meeting.segments.filter { $0.isFinal && $0.translationRevision != $0.revision }.map(\.reference)
        runTranslations()
    }

    private func scheduleAnalysis() {
        analysisTask?.cancel()
        let sessionID = meeting.id
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(0.8))
                while Date().timeIntervalSince(self.lastRemoteVoice) < self.configuration.vadSilenceSeconds {
                    try await Task.sleep(for: .milliseconds(300))
                }
                let selected = self.latestRemoteTurn()
                guard !selected.isEmpty else { return }
                let snapshot = self.meeting
                let references = (selected + PromptBuilder.relevantContext(in: snapshot, selected: selected)).map(\.reference)
                let request = try PromptBuilder.request(task: .analysis, meeting: snapshot, selected: selected, model: self.selectedText.fastModel)
                let result = try await self.service().perform(UtteranceAnalysis.self, request: request)
                try Task.checkCancellation()
                guard self.meeting.id == sessionID && self.meeting.containsCurrent(references) else { return }
                try EvidenceValidator.analysis(result, meeting: snapshot, selected: selected)
                self.analysis = result
                if result.requiresResponse && result.addressee == .user && self.configuration.automaticAnswers {
                    self.generateAnswer(selected: selected)
                }
            } catch is CancellationError {} catch { self.textStatus = "理解分析暂不可用" }
        }
    }

    private func latestRemoteTurn() -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in meeting.segments.filter(\.isFinal).reversed() {
            if segment.track != .remote { if result.isEmpty { continue }; break }
            if let next = result.last, next.start - segment.end > 2.5 { break }
            result.append(segment)
            if result.count >= 8 { break }
        }
        return result.reversed()
    }

    func generateAnswer(selected: [TranscriptSegment]? = nil, style: String = "") {
        guard !isLibraryBusy && !isQuitting else { return }
        let chosen = selected ?? selectedTranscript
        guard !chosen.isEmpty else { errorMessage = "请先选择已完成的转写片段。"; return }
        let service: IntelligenceService
        do { service = try self.service() } catch { fail(error); return }
        answerTask?.cancel(); requestID = UUID()
        let token = requestID, sessionID = meeting.id, references = chosen.map(\.reference)
        let snapshot = meeting, provider = selectedText
        answerBusy = true; answerDraft = ""
        answerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.answerBusy = false } }
            do {
                // A draft rejected by the evidence review used to be a dead end: the user saw only an
                // error for a genuine question. Regenerate once with the review feedback, then require
                // the same checks again; a second rejection surfaces like before.
                var attemptStyle = style
                var lastRejection: Error?
                for attempt in 0...1 {
                    if attempt > 0, let lastRejection {
                        let feedback = "A previous draft was rejected by the evidence and consistency review: \(lastRejection.localizedDescription) Draft a corrected answer that resolves every listed problem."
                        attemptStyle = style.isEmpty ? feedback : "\(style) \(feedback)"
                        if self.requestID == token { self.answerDraft = "" }
                    }
                    let request = try PromptBuilder.request(task: .answer, meeting: snapshot, selected: chosen, model: provider.answerModel, style: attemptStyle)
                    let result = try await service.perform(AnswerContent.self, request: request) { [weak self] delta in
                        await MainActor.run { if self?.requestID == token { self?.answerDraft += delta } }
                    }
                    try Task.checkCancellation()
                    guard self.requestID == token, self.meeting.id == sessionID, self.meeting.containsCurrent(references) else { return }
                    let checked = try EvidenceValidator.answer(result, meeting: snapshot, selected: chosen)
                    let review = try await service.reviewAnswer(checked, meeting: snapshot, selected: chosen, model: provider.fastModel)
                    do {
                        try review.requireApproval()
                    } catch {
                        lastRejection = error
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.requestID == token, self.meeting.id == sessionID, self.meeting.containsCurrent(references) else { return }
                    let cited = snapshot.segments.filter { checked.sourceIDs.contains($0.id) }.map(\.reference)
                    guard self.meeting.containsCurrent(cited) else { return }
                    let answer = AnswerSuggestion(sources: cited, content: checked, provider: provider.kind.title, model: provider.answerModel,
                        evidenceSegments: snapshot.segments.filter { checked.sourceIDs.contains($0.id) },
                        evidenceFacts: snapshot.profile.facts.filter { checked.factIDs.contains($0.id) })
                    self.meeting.answers.append(answer)
                    if self.currentAnswer?.pinned != true { self.currentAnswerID = answer.id }
                    self.scheduleSave()
                    return
                }
                throw lastRejection ?? CopilotError.message("回答未通过事实与中英文一致性核对，未采用。")
            } catch is CancellationError {} catch { self.fail(error) }
        }
    }

    func togglePin() {
        guard !isLibraryBusy && !isQuitting else { return }
        guard let i = meeting.answers.firstIndex(where: { $0.id == currentAnswerID }) else { return }
        meeting.answers[i].pinned.toggle(); scheduleSave()
    }

    func correct(id: String, text: String) {
        guard !isLibraryBusy && !isQuitting else { return }
        let previous = meeting.segments.first { $0.id == id }?.reference
        meeting.correct(id: id, text: text)
        guard previous != meeting.segments.first(where: { $0.id == id })?.reference else { return }
        analysisTask?.cancel(); analysis = nil
        scheduleSave()
        if configuration.cloudTextEnabled { retryTranslations() }
    }

    func summarize() async {
        guard !summaryBusy && !isLibraryBusy && !isQuitting else { return }
        let snapshot = meeting
        let segments = snapshot.segments.filter(\.isFinal)
        guard !segments.isEmpty else { errorMessage = "还没有可总结的转写。"; return }
        let token = UUID(); summaryRequestID = token
        let provider = selectedText
        summaryBusy = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.generateSummary(snapshot: snapshot, segments: segments, provider: provider, token: token)
        }
        summaryTask = task
        await task.value
        if summaryRequestID == token { summaryBusy = false; summaryTask = nil }
    }

    private func generateSummary(snapshot: MeetingSession, segments: [TranscriptSegment],
                                 provider: TextProviderConfiguration, token: UUID) async {
        do {
            try Task.checkCancellation()
            let service = try service()
            var chunks: [[TranscriptSegment]] = [[]]
            var size = 0
            for segment in segments {
                if size + segment.text.count > 16000 && !chunks[chunks.count - 1].isEmpty { chunks.append([]); size = 0 }
                chunks[chunks.count - 1].append(segment); size += segment.text.count
            }
            var summaries: [MeetingSummary] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let request = try PromptBuilder.request(task: .summary, meeting: snapshot, selected: chunk, model: provider.answerModel)
                let summary = try await service.perform(MeetingSummary.self, request: request)
                try Task.checkCancellation()
                try EvidenceValidator.summary(summary, segments: chunk)
                summaries.append(summary)
            }
            var result = summaries[0]
            if summaries.count > 1 {
                let schema = try PromptBuilder.schema(for: .summary)
                let input = String(decoding: try JSONEncoder().encode(summaries), as: UTF8.self)
                let request = TextRequest(model: provider.answerModel,
                    system: PromptBuilder.rules + "\nMerge these source-backed section summaries. Preserve original sourceIDs, distinguish proposals from decisions, remove duplicates. JSON schema: " + String(decoding: schema, as: UTF8.self),
                    input: input, schema: schema, schemaName: "summary")
                result = try await service.perform(MeetingSummary.self, request: request)
            }
            try Task.checkCancellation()
            try EvidenceValidator.summary(result, segments: segments)
            guard summaryRequestID == token, meeting.id == snapshot.id else { return }
            meeting.summary = result
            let citedIDs = Set((result.topics + result.questions + result.actualAnswers + result.decisions + result.actions + result.unresolved).flatMap(\.sourceIDs))
            meeting.summaryEvidence = segments.filter { citedIDs.contains($0.id) }
            meeting.summaryStale = meeting.segments.map(\.reference) != snapshot.segments.map(\.reference)
            await saveNow()
        } catch is CancellationError {} catch {
            if summaryRequestID == token { fail(error) }
        }
    }

    func copyAnswer() {
        guard let answer = currentAnswer else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer.content.english, forType: .string)
    }

    @discardableResult
    func selectSource(_ citation: SourceCitation) -> Bool {
        guard let current = meeting.segments.first(where: { $0.id == citation.id }) else {
            errorMessage = "这条来源已不可用，未跳转到其他发言。"
            return false
        }
        selectedSegments = [current.id]
        if let revision = citation.expectedRevision, revision != current.revision {
            sourceNavigationNotice = "已定位到更正后的原文；此生成内容使用的是较早版本，请重新核对。"
        } else if citation.expectedRevision == nil {
            sourceNavigationNotice = "已定位到当前原文；这份旧记录没有保存生成时的来源版本。"
        } else { sourceNavigationNotice = "已定位到所引用的发言。" }
        return true
    }

    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "科研会议记录.md"
        panel.message = "导出的普通文本包含会议内容和单独标记的 AI 建议。请选择合适的保存位置。"
        if panel.runModal() == .OK, let url = panel.url {
            do { try MarkdownExport.render(meeting).write(to: url, atomically: true, encoding: .utf8) }
            catch { fail(error) }
        }
    }

    func loadHistory() async {
        guard !historyLoading else { return }
        historyLoading = true
        defer { historyLoading = false }
        do {
            guard let repository else { throw CopilotError.message("本地存储尚未就绪，请重试本地存储。") }
            var readable: [MeetingSession] = [], unreadable: [UUID] = []
            for id in try await repository.listIDs() {
                do { readable.append(try await repository.load(id)) }
                catch { unreadable.append(id) }
            }
            history = readable; unreadableMeetingIDs = unreadable
        } catch { fail(error) }
    }

    @discardableResult
    func openMeeting(_ session: MeetingSession) async -> Bool {
        guard !libraryActionsDisabled else { return false }
        isLibraryBusy = true
        var opened = false
        defer {
            isLibraryBusy = false
            if opened && hasUnsavedChanges { scheduleSave() }
        }
        cancelTextTasks()
        guard await flushCurrentMeeting() else { return false }
        do {
            guard let repository else { throw CopilotError.message("本地存储尚未就绪。") }
            // History rows are snapshots: always reload after saving, including the current row.
            let latest = try await repository.load(session.id)
            installMeeting(latest, persisted: true)
            if latest.endedAt == nil, latest.recoveredAt == nil { meeting.markRecovered() }
            captureStatus = "历史记录 · 未采集音频"
            opened = true
            return true
        } catch { fail(error); return false }
    }

    func deleteMeeting(_ session: MeetingSession) async {
        guard !libraryActionsDisabled else { return }
        isLibraryBusy = true
        let deletingCurrent = meeting.id == session.id
        defer {
            isLibraryBusy = false
            if !deletingCurrent && hasUnsavedChanges { scheduleSave() }
        }
        if deletingCurrent { cancelScheduledSave(); cancelTextTasks() }
        do {
            guard let repository else { throw CopilotError.message("本地存储尚未就绪，未删除记录。") }
            // A queued save must finish before deletion, so it cannot resurrect the file.
            _ = await persistenceTail?.value
            try await repository.delete(session.id)
            if deletingCurrent { installMeeting(makeNewMeeting(), persisted: false) }
            await loadHistory()
        } catch { fail(error) }
    }

    @discardableResult
    func newMeeting() async -> Bool {
        guard !libraryActionsDisabled else { return false }
        isLibraryBusy = true
        defer { isLibraryBusy = false }
        cancelTextTasks()
        guard await flushCurrentMeeting() else { return false }
        installMeeting(makeNewMeeting(), persisted: false)
        captureStatus = "尚未连接"
        return true
    }

    private func makeNewMeeting() -> MeetingSession {
        var session = MeetingSession(); session.profile = profile; return session
    }

    private func installMeeting(_ session: MeetingSession, persisted: Bool) {
        cancelScheduledSave()
        isReplacingMeeting = true; meeting = session; isReplacingMeeting = false
        savedMeetingID = persisted ? session.id : nil; savedRevision = meetingRevision
        selectedSegments = []; analysis = nil; answerDraft = ""; sourceNavigationNotice = nil
        currentAnswerID = (session.answers.last(where: \.pinned) ?? session.answers.last)?.id
        storageStatus = persisted ? "文字已加密保存" : "本地加密保存已就绪"
    }

    private func flushCurrentMeeting() async -> Bool {
        cancelScheduledSave()
        // A title edit or a finishing task may arrive during a write. Persist that revision too.
        repeat {
            guard await saveNow() else { return false }
        } while hasUnsavedChanges
        return true
    }

    func prepareForTermination() async -> Bool {
        guard !isQuitting else { return false }
        isQuitting = true; cancelStartup = true; stopProbeRequested = true
        cancelModelPreparation(); cancelTextTasks()
        defer { isQuitting = false }
        let deadline = ContinuousClock.now + .seconds(30)
        while isStarting || isStopping || isLibraryBusy {
            if ContinuousClock.now >= deadline {
                errorMessage = "仍在结束当前操作，应用未退出。请稍后重试。"
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await stopAudioTest()
        await stop()
        if captureStopUnconfirmed { await retryCaptureStop() }
        guard !captureStopUnconfirmed else { return false }
        return await flushCurrentMeeting()
    }

    private func cancelTextTasks() {
        answerTask?.cancel(); analysisTask?.cancel(); translationTask?.cancel()
        summaryTask?.cancel(); summaryTask = nil; summaryRequestID = UUID(); summaryBusy = false
        translationTask = nil; translations = []; requestID = UUID(); answerBusy = false; answerDraft = ""
        translationWorkerID = UUID()
    }

    private func scheduleSave() {
        guard repository != nil, meeting.hasRecord, saveTask == nil, !isLibraryBusy, !isQuitting else { return }
        let token = UUID(); saveScheduleID = token
        storageStatus = "有更改待保存"
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self, self.saveScheduleID == token else { return }
                let saved = await self.saveNow()
                guard self.saveScheduleID == token else { return }
                self.saveTask = nil
                if saved && self.hasUnsavedChanges { self.scheduleSave() }
            } catch {}
        }
    }

    private func cancelScheduledSave() {
        saveScheduleID = UUID(); saveTask?.cancel(); saveTask = nil
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard meeting.hasRecord else { return true }
        guard let repository else {
            storageStatus = "保存失败 · 本地存储未就绪"
            errorMessage = "本地存储尚未就绪，当前文字未保存。请重试本地存储或导出记录。"
            return false
        }
        guard hasUnsavedChanges else { return true }
        let snapshot = meeting, revision = meetingRevision
        let previous = persistenceTail
        queuedWrites += 1; isSaving = true
        let write = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            defer { self.queuedWrites -= 1; self.isSaving = self.queuedWrites > 0 }
            do {
                try await repository.save(snapshot)
                if self.meeting.id == snapshot.id {
                    self.savedMeetingID = snapshot.id; self.savedRevision = revision
                    self.storageStatus = self.hasUnsavedChanges ? "有更改待保存" : "文字已加密保存"
                }
                return true
            } catch {
                self.storageStatus = "保存失败 · 当前文字仍在内存中"
                self.errorMessage = "会议文字未能保存，当前记录已保留。请重试保存或导出 Markdown；应用不会因切换会议或退出而丢弃它。"
                return false
            }
        }
        persistenceTail = write
        return await write.value
    }

    func fail(_ error: any Error) {
        if let safe = error as? CopilotError { errorMessage = safe.localizedDescription }
        else if let capture = error as? CaptureFailure { errorMessage = capture.localizedDescription }
        else if error is URLError { errorMessage = "网络请求未完成，本地转写仍可继续。请检查网络后重试。" }
        else { errorMessage = "操作未完成，请检查模型、文件或系统权限后重试。" }
    }
}
