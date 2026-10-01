import SwiftUI
import AppKit
import CopilotCore

@main
struct ResearchCopilotApp: App {
    @StateObject private var controller = MeetingController.forApplication()
    @NSApplicationDelegateAdaptor(CopilotAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("科研会议 AI 副驾") {
            ContentView(controller: controller)
                .frame(minWidth: 1000, minHeight: 660)
                .task { delegate.controller = controller; await controller.initialize() }
        }
        .defaultSize(width: 1250, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建会议") { Task { await controller.newMeeting() } }.disabled(controller.libraryActionsDisabled)
                Button("导出会议记录…") { controller.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("隐藏副驾") { NSApplication.shared.hide(nil) }.keyboardShortcut("h", modifiers: [.command])
            }
        }
        Settings {
            if controller.reviewOnly {
                Text("界面验证副本不读取或配置任何 API Key。").padding(30)
            } else { SettingsView(controller: controller).frame(width: 760, height: 680) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: MeetingController
    @State private var tab = "live"
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var showEdit = false
    @State private var deletingMeeting: MeetingSession?
    @State private var sourceFocus: SourceFocus?
    private struct SourceFocus: Equatable { var id: String; var requestID = UUID() }
    var body: some View {
        VStack(spacing: 0) {
            if controller.reviewOnly {
                Text("界面验证副本 · 全部为虚构材料 · 不采集音频、不调用 API、不访问个人记录")
                    .font(.caption.bold()).foregroundStyle(.orange).padding(8)
            }
            header
            Divider()
            HStack(spacing: 20) {
                Label(controller.captureStatus, systemImage: "waveform")
                Label(controller.modelStatus, systemImage: "desktopcomputer")
                Label(controller.textStatus, systemImage: "text.bubble")
                Spacer()
                if controller.isRecording && controller.configuration.captureMicrophone {
                    Label("副驾麦克风正在采集 · 与 Zoom 静音独立", systemImage: "mic.fill").foregroundStyle(.orange)
                    Button("关闭副驾麦克风") { Task { await controller.disableMicrophone() } }
                }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
            Divider()
            switch tab {
            case "summary": summaryPanel
            case "history": historyPanel
            default: livePanel
            }
            Divider()
            HStack {
                Label(controller.reviewOnly ? "虚构示例仅保存在内存" : controller.storageStatus, systemImage: "lock.shield")
                if !controller.storageReady {
                    Button("重试本地存储") { Task { await controller.initialize() } }.disabled(controller.isInitializingStorage)
                } else if controller.hasUnsavedChanges {
                    Button("重试保存") { Task { await controller.saveNow() } }.disabled(controller.isSaving || controller.isLibraryBusy || controller.isQuitting)
                }
                Text("音频不落盘")
                Spacer()
                Text("共享整个桌面时，副驾窗口可能可见")
                Button("隐藏") { NSApplication.shared.hide(nil) }
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .alert("需要处理", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .sheet(isPresented: $showEdit) {
            VStack(alignment: .leading, spacing: 16) {
                Text("更正转写").font(.headline)
                Text("更正后，相关翻译与回答建议将需要更新。").foregroundStyle(.secondary)
                TextEditor(text: $editingText).frame(minHeight: 180)
                HStack {
                    Button("取消") { showEdit = false }
                    Spacer()
                    Button("保存更正") { if let editingID { controller.correct(id: editingID, text: editingText) }; showEdit = false }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 560)
        }
        .confirmationDialog("删除这场会议的本地文字记录？", isPresented: Binding(get: { deletingMeeting != nil }, set: { if !$0 { deletingMeeting = nil } })) {
            Button("删除会议记录", role: .destructive) {
                if let session = deletingMeeting { Task { await controller.deleteMeeting(session) } }
                deletingMeeting = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 32)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text("科研会议 AI 副驾").font(.title2.bold())
                TextField("会议标题", text: $controller.meeting.title).textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(controller.isLibraryBusy || controller.isQuitting)
            }
            Spacer()
            Picker("页面", selection: $tab) {
                Text("实时会议").tag("live"); Text("会后总结").tag("summary"); Text("历史记录").tag("history")
            }.pickerStyle(.segmented).frame(width: 270)
            SettingsLink { Image(systemName: "gearshape") }.help("模型、密钥与研究背景").disabled(controller.reviewOnly || controller.isTestingAudio)
            Button(controller.isRecording ? "停止采集" : "开始会议") {
                Task { if controller.isRecording { await controller.stop() } else { await controller.start() } }
            }.buttonStyle(.borderedProminent).tint(controller.isRecording ? .red : .teal)
                .disabled(controller.reviewOnly || controller.isTestingAudio || controller.captureStopUnconfirmed || controller.isStarting || controller.isPreparing || controller.isStopping || controller.isLibraryBusy || controller.isQuitting)
        }.padding(18)
    }

    private var livePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Zoom 音源", selection: $controller.selectedApplication) {
                    Text("选择 Zoom").tag(Optional<Int32>.none)
                    ForEach(controller.applications) { app in Text(app.name).tag(Optional(app.id)) }
                }.frame(width: 220).disabled(controller.libraryActionsDisabled)
                Button("刷新音源") { Task { await controller.refreshApplications() } }.disabled(controller.libraryActionsDisabled || controller.reviewOnly)
                ProgressView(value: controller.remoteLevel).frame(width: 90).tint(.teal)
                Toggle("记录我的发言", isOn: $controller.configuration.captureMicrophone).disabled(controller.libraryActionsDisabled)
                Spacer()
                Button("重试翻译") { controller.retryTranslations() }
            }.padding(12)
            if !controller.reviewOnly {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Button(controller.isTestingAudio ? "停止检测" : "检测 Zoom 音源（30 秒）") {
                            Task { if controller.isTestingAudio { await controller.stopAudioTest() } else { await controller.startAudioTest() } }
                        }.disabled(controller.isRecording || controller.isPreparing || controller.isStopping || controller.isLibraryBusy || controller.isQuitting || controller.captureStopUnconfirmed)
                        Text("仅检查声音强度；麦克风关闭，不转写、不调用云端、不创建会议记录。")
                        Spacer()
                        if controller.audioProbeReport != nil {
                            Button("导出检测报告") { controller.exportAudioProbe() }.disabled(controller.isTestingAudio || controller.isStopping)
                        }
                    }
                    Text(controller.permissionStatus.text).foregroundStyle(.secondary)
                    if let report = controller.audioProbeReport {
                        Text(report.text + (report.endedAt == nil ? "" : report.stopConfirmed ? " · 已确认停止" : " · 停止未确认"))
                            .monospacedDigit().accessibilityIdentifier("audioProbeReport")
                        if let issue = report.issues.last { Text(issue).foregroundStyle(.orange) }
                    }
                    if controller.captureStopUnconfirmed {
                        HStack {
                            Text("系统采集停止尚未确认；音频已停止传送。请重试停止。").foregroundStyle(.orange)
                            Button("重试停止采集") { Task { await controller.retryCaptureStop() } }.disabled(controller.isStopping)
                        }
                    }
                }.font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            HSplitView {
                transcriptPanel.frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                understandingPanel.frame(minWidth: 220, idealWidth: 260, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
                answerPanel.frame(minWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("实时原文与翻译").font(.headline); Spacer(); Text("⌘ 多选片段").font(.caption).foregroundStyle(.secondary) }.padding()
            if let notice = controller.sourceNavigationNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.teal)
                    Spacer()
                    Button("关闭定位提示") { controller.sourceNavigationNotice = nil }.font(.caption)
                }.padding(.horizontal).padding(.bottom, 8)
            }
            if controller.meeting.segments.isEmpty {
                ContentUnavailableView("等待发言", systemImage: "waveform", description: Text(
                    controller.isRecording ? "正在等待可识别的发言。" :
                    controller.modelReady || controller.configuration.speechProvider == .openAI
                        ? "确认 Zoom 音源后，点击“开始会议”。"
                        : "在设置中准备语音模型，然后选择 Zoom 并开始会议。"))
            } else {
                ScrollViewReader { proxy in
                List(selection: $controller.selectedSegments) {
                    ForEach(controller.meeting.segments) { segment in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(segment.track.title).font(.caption.bold()).foregroundStyle(segment.track == .remote ? .teal : .orange)
                                Text(MarkdownExport.timestamp(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                if !segment.isFinal { Text(controller.isRecording ? "识别中" : "未确认转写").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(segment.text).font(.system(size: 15)).foregroundStyle(segment.isFinal ? .primary : .secondary).textSelection(.enabled)
                            if segment.timingApproximate == true {
                                Label("部分词语的时间定位不精确", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let translation = segment.translation { Text(translation).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(.vertical, 9).tag(segment.id).id(segment.id)
                            .contextMenu {
                                Button("更正转写…") { editingID = segment.id; editingText = segment.text; showEdit = true }
                                Button("针对这段生成建议") { controller.generateAnswer(selected: [segment]) }.disabled(!segment.isFinal)
                            }
                    }
                }.listStyle(.inset)
                    .task(id: sourceFocus?.requestID) {
                        guard let sourceFocus else { return }
                        await Task.yield()
                        proxy.scrollTo(sourceFocus.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var understandingPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("理解与回应").font(.headline)
                if let analysis = controller.analysis {
                    Text(analysis.coreMeaning).font(.title3.weight(.medium))
                    Label(analysis.intent, systemImage: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
                    Text(analysis.reason).font(.callout)
                    sourceLinks(analysis.sourceIDs)
                    if analysis.addressee == .unclear { Text("回应对象尚不明确，可手动生成建议。").font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("专家的核心意思与回应需求会显示在这里。也可以选择左侧片段，手动生成建议。").foregroundStyle(.secondary)
                }
                Divider()
                Button("生成回答建议") { controller.generateAnswer() }.buttonStyle(.borderedProminent).tint(.teal)
                    .keyboardShortcut("a", modifiers: [.option]).disabled(controller.answerBusy)
                Toggle("自动生成回应建议", isOn: $controller.configuration.automaticAnswers)
                Text("选择多个片段可覆盖长问题。AI 建议仅供参考，由你决定实际发言。").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private var answerPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("英文回答建议").font(.headline)
                    Spacer()
                    if controller.answerBusy { ProgressView().controlSize(.small) }
                }
                if let answer = controller.currentAnswer {
                    if answer.stale { Label("来源已更正，请重新生成", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if answer.pinned { Label("已固定此建议", systemImage: "pin.fill").font(.caption).foregroundStyle(.teal) }
                    Text(answer.content.english).font(.system(size: 24, weight: .medium)).lineSpacing(6).textSelection(.enabled)
                    Text(answer.content.chinese).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button(answer.pinned ? "取消固定" : "固定") { controller.togglePin() }.keyboardShortcut("p", modifiers: [.option])
                        Button("复制") { controller.copyAnswer() }
                        Button("重新生成") { controller.generateAnswer() }.disabled(controller.answerBusy)
                    }
                    HStack {
                        Button("更短") { controller.generateAnswer(style: "Use one short sentence.") }.keyboardShortcut("s", modifiers: [.option])
                        Button("更口语化") { controller.generateAnswer(style: "Use very simple spoken English.") }
                        Button("澄清问题") { controller.generateAnswer(style: "Offer a clarification question as the primary English answer.") }.keyboardShortcut("c", modifiers: [.option])
                    }.disabled(controller.answerBusy)
                    DisclosureGroup("简短 / 谨慎 / 澄清表达") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(answer.content.shortAnswer); Text(answer.content.cautiousAnswer); Text(answer.content.clarification)
                        }.padding(.top, 10).textSelection(.enabled)
                    }
                    if !answer.content.warnings.isEmpty || !answer.content.missingInformation.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("开口前核实", systemImage: "checkmark.shield").font(.subheadline.bold())
                            ForEach(Array((answer.content.warnings + answer.content.missingInformation).enumerated()), id: \.offset) { _, item in Text(item).font(.caption) }
                        }.padding().background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("\(answer.provider) · \(answer.model) · \(answer.sources.count) 个来源片段").font(.caption).foregroundStyle(.secondary)
                    sourceLinks(answer.sources.map(\.id), references: answer.sources, snapshots: answer.evidenceSegments)
                    if !answer.content.factIDs.isEmpty {
                        DisclosureGroup("采用的研究信息") {
                            if answer.evidenceFacts == nil {
                                Text("旧记录未保存生成时的事实快照；以下为当前信息。").font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(answer.evidenceFacts ?? controller.meeting.profile.facts.filter { answer.content.factIDs.contains($0.id) }) { fact in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fact.kind.title).font(.caption.bold())
                                    Text(fact.content).font(.callout).textSelection(.enabled)
                                    Text("录入来源：" + fact.origin).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("准备好后再开口", systemImage: "text.bubble", description: Text("简洁的英文建议和中文意思会显示在这里。"))
                }
                if controller.answerBusy {
                    Text("正在生成草稿并核对事实、翻译与来源…").font(.callout).foregroundStyle(.secondary)
                    if controller.currentAnswer?.pinned != true, let draft = StreamingDraft.english(in: controller.answerDraft) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("草稿 · 尚未校验").font(.caption.bold()).foregroundStyle(.orange)
                            Text(draft).font(.title3).foregroundStyle(.secondary)
                        }.padding().background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if controller.meeting.answers.count > 1 {
                    Picker("其他建议", selection: $controller.currentAnswerID) {
                        ForEach(controller.meeting.answers.reversed()) { answer in
                            Text(answer.content.coreQuestion.prefix(32)).tag(Optional(answer.id))
                        }
                    }
                }
            }.padding(22)
        }.background(.teal.opacity(0.025))
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("会后总结").font(.title2.bold())
                Spacer()
                Button("导出 Markdown…") { controller.export() }
                Button(controller.summaryBusy ? "正在总结…" : "生成 / 更新总结") { Task { await controller.summarize() } }
                    .buttonStyle(.borderedProminent).disabled(controller.summaryBusy)
            }
            if !controller.meeting.microphoneIncluded { Text("未采集本人发言，不能据 AI 建议推断实际回答。").font(.callout).foregroundStyle(.secondary) }
            if !controller.meeting.gaps.isEmpty {
                DisclosureGroup("记录缺口与局限（\(controller.meeting.gaps.count)）") {
                    ForEach(controller.meeting.gaps) { gap in
                        Text("\(MarkdownExport.timestamp(gap.time)) · \(gap.reason)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if controller.meeting.summaryStale { Text("转写已更新，请重新生成总结。").foregroundStyle(.orange) }
            if let summary = controller.meeting.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summarySection("讨论主题", summary.topics)
                        summarySection("专家问题", summary.questions)
                        summarySection("记录到的本人回答", summary.actualAnswers)
                        summarySection("明确决定", summary.decisions)
                        summarySection("待办事项", summary.actions, actions: true)
                        summarySection("未解决问题", summary.unresolved)
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("保留讨论的来龙去脉", systemImage: "doc.text.magnifyingglass", description: Text("总结依据实际转写；AI 回答建议不会被当成你说过的话。"))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
    }

    private func summarySection(_ title: String, _ entries: [SummaryEntry], actions: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if entries.isEmpty { Text("未记录到").foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                    if actions { Text("负责人：\(entry.displayedOwner) · 日期：\(entry.displayedDeadline)").font(.caption).foregroundStyle(.secondary) }
                    sourceLinks(entry.sourceIDs, snapshots: controller.meeting.summaryEvidence)
                }
            }
        }
    }

    private func sourceLinks(_ ids: [String], references: [SourceReference] = [], snapshots: [TranscriptSegment]? = nil) -> some View {
        let citations = CitationResolver.resolve(ids, in: controller.meeting, references: references, snapshots: snapshots)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(citations) { citation in
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        if controller.selectSource(citation) {
                            sourceFocus = SourceFocus(id: citation.id)
                            tab = "live"
                        }
                    } label: {
                        Label(citation.label, systemImage: "text.quote").font(.caption)
                    }.buttonStyle(.link).disabled(citation.current == nil)
                        .help("定位到实际转写；只选择原文，不自动生成回答。")
                    if citation.changed || citation.current == nil, let snapshot = citation.snapshot {
                        DisclosureGroup("生成时采用的原文") {
                            Text(snapshot.text).font(.caption).textSelection(.enabled)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("历史记录").font(.title2.bold())
                Spacer()
                Button("刷新记录") { Task { await controller.loadHistory() } }.disabled(controller.historyLoading || controller.isLibraryBusy)
            }.padding(.horizontal)
            if !controller.unreadableMeetingIDs.isEmpty {
                Text("有 \(controller.unreadableMeetingIDs.count) 条记录无法读取，原文件已保留。其余记录可正常打开；请检查加密密钥、文件完整性或应用版本后刷新。")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal)
            }
            List {
            ForEach(controller.history) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.title).font(.headline)
                        Text("\(session.startedAt.formatted()) · \(session.segments.count) 段转写").font(.caption).foregroundStyle(.secondary)
                        if session.endedAt == nil { Text(session.recoveredAt == nil ? "未正常结束 · 可恢复已保存文字" : "已恢复文字 · 记录可能不完整").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button("打开") { Task { if await controller.openMeeting(session) { tab = "live" } } }.disabled(controller.libraryActionsDisabled)
                    Button("删除", role: .destructive) { deletingMeeting = session }.disabled(controller.libraryActionsDisabled)
                }.padding(.vertical, 8)
            }
            }.overlay {
                if controller.historyLoading { ProgressView("正在读取记录…") }
                else if controller.history.isEmpty && controller.unreadableMeetingIDs.isEmpty {
                    ContentUnavailableView("还没有历史记录", systemImage: "clock")
                }
            }
        }.padding(.top, 16).task { await controller.loadHistory() }
    }
}

@MainActor
final class CopilotAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: MeetingController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        Task {
            let saved = await controller.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
