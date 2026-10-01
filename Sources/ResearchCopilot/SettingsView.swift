import SwiftUI
import AppKit
import CopilotCore
import CopilotSpeech

struct SettingsView: View {
    @ObservedObject var controller: MeetingController
    @State private var key = ""
    @State private var message = ""
    @State private var testing = false
    @State private var factText = ""
    @State private var factKind: FactKind = .unknown
    @State private var speechKey = ""
    @State private var diagnosticResults: [TextDiagnosticResult] = []
    @State private var diagnosticTask: Task<Void, Never>?

    private var provider: Binding<TextProviderConfiguration> {
        Binding(get: { controller.selectedText }, set: { value in
            if let i = controller.configuration.textProviders.firstIndex(where: { $0.kind == controller.configuration.selectedTextProvider }) {
                controller.configuration.textProviders[i] = value
            }
        })
    }

    var body: some View {
        TabView {
            speechSettings.tabItem { Label("语音识别", systemImage: "waveform") }
            textSettings.tabItem { Label("文字模型", systemImage: "text.bubble") }
            researchSettings.tabItem { Label("研究背景", systemImage: "book.closed") }
        }.padding(14)
            .onChange(of: controller.selectedText.credentialAccount) { _, _ in key = ""; message = "" }
            .onChange(of: controller.selectedText) { _, _ in
                diagnosticTask?.cancel(); diagnosticResults = []; message = ""
            }
            .onDisappear { diagnosticTask?.cancel() }
    }

    private var speechSettings: some View {
        Form {
            Picker("语音引擎", selection: $controller.configuration.speechProvider) {
                Text("本地 WhisperKit").tag(SpeechProviderKind.whisperKit)
                Text("OpenAI 云端转写").tag(SpeechProviderKind.openAI)
            }.disabled(controller.isRecording || controller.isStarting || controller.isPreparing)
            Section("本地 WhisperKit") {
                Text("语音在本机识别，无需 OpenAI API Key。“下载并准备”允许下载模型和分词资源；“离线加载”只读取本地文件。")
                    .foregroundStyle(.secondary)
                TextField("模型标识", text: $controller.configuration.localModel)
                    .disabled(controller.isRecording || controller.isStarting || controller.isPreparing)
                    .onChange(of: controller.configuration.localModel) { _, _ in
                        controller.modelReady = false; controller.configuration.modelFolder = ""
                    }
                LabeledContent("模型目录") { Text(controller.configuration.modelFolder.isEmpty ? "尚未选择" : controller.configuration.modelFolder).lineLimit(2).truncationMode(.middle) }
                HStack {
                    Button("下载并准备模型") { controller.beginModelPreparation(download: true) }
                    Button("导入目录…") { controller.chooseModelFolder() }
                    Button("离线加载已有模型") { controller.beginModelPreparation(download: false) }.disabled(controller.configuration.modelFolder.isEmpty)
                }.disabled(controller.isRecording || controller.isPreparing || controller.isStarting)
                if controller.isPreparing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button(controller.isCancellingPreparation ? "正在取消…" : "取消准备") { controller.cancelModelPreparation() }
                            .disabled(controller.isCancellingPreparation)
                    }
                }
                Text(controller.modelStatus).foregroundStyle(controller.modelReady ? .teal : .secondary)
                Text("默认使用多语言压缩模型；下载体积与运行内存不同。请在会议前完成模型准备。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("离线导入需配套分词文件。可将 config.json、tokenizer.json、tokenizer_config.json 放入模型目录内的 Tokenizer 子目录；完整缓存目录也可直接导入。默认模型来自 Argmax / WhisperKit，下载约 606 MiB；首次预热另需时间与缓存空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("发言分段") {
                Slider(value: $controller.configuration.vadSilenceSeconds, in: 0.8...1.5, step: 0.1) {
                    Text("停顿阈值：\(controller.configuration.vadSilenceSeconds, specifier: "%.1f") 秒")
                }.disabled(controller.isRecording)
                Toggle("默认记录我的发言", isOn: $controller.configuration.captureMicrophone).disabled(controller.isRecording)
                Text("请使用耳机。副驾麦克风与 Zoom 静音状态独立，开启后会显示持续采集提示。").font(.caption).foregroundStyle(.secondary)
                Text("本人轨使用启动时的系统默认麦克风。设备切换或断开时会停止采集并标记中断；请确认设备后手动重新开始。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("其他语音服务") {
                Text("选择 OpenAI 后，会议音频将发送到 OpenAI，按其 API 规则计费；与文字模型选择独立。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("语音模型", text: $controller.configuration.openAISpeechModel)
                Text("当前适配 gpt-live-transcribe；其他语音模型需单独验证。云端语音仍处于开发测试阶段。")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("OpenAI 语音 API Key", text: $speechKey)
                Button("保存语音密钥") {
                    do {
                        let trimmed = speechKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        try controller.credentials.write(Data(trimmed.utf8), account: OpenAITranscriptionProvider.credentialAccount)
                        speechKey = ""; message = "OpenAI 语音密钥已保存。"
                    } catch { controller.fail(error) }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.teal) }
            }
            Button("保存设置") { Task { await controller.saveSettings() } }
        }.formStyle(.grouped)
    }

    private var textSettings: some View {
        Form {
            Section("文字服务") {
                Toggle("启用云端翻译、理解、回答与总结", isOn: $controller.configuration.cloudTextEnabled)
                Text("开启后，所需转写文字与研究背景会发送给你选择的服务。各服务有独立的数据使用与计费政策。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("供应商", selection: $controller.configuration.selectedTextProvider) {
                    ForEach(TextProviderKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Base URL", text: provider.baseURL)
                Picker("协议", selection: provider.apiProtocol) {
                    Text("Chat Completions").tag(TextProtocol.chatCompletions)
                    Text("OpenAI Responses").tag(TextProtocol.responses)
                }
                TextField("翻译 / 理解模型", text: provider.fastModel)
                TextField("回答 / 总结模型", text: provider.answerModel)
                Picker("结构化能力", selection: provider.structure) {
                    Text("JSON 模式").tag(StructuredOutputMode.jsonObject)
                    Text("原生 JSON Schema").tag(StructuredOutputMode.schema)
                    Text("仅提示词约束").tag(StructuredOutputMode.promptOnly)
                }
                SecureField("API Key（保存在本机钥匙串）", text: $key)
                HStack {
                    Button("保存密钥") {
                        do {
                            _ = try controller.selectedText.validatedBaseURL()
                            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { message = "请输入密钥。"; return }
                            try controller.credentials.write(Data(trimmed.utf8), account: controller.selectedText.credentialAccount)
                            key = ""; message = "密钥已保存到当前服务的钥匙串项目。"
                        } catch { controller.fail(error) }
                    }
                    Button("删除此服务密钥", role: .destructive) {
                        do { try controller.credentials.delete(controller.selectedText.credentialAccount); message = "已删除此服务密钥。" }
                        catch { controller.fail(error) }
                    }
                    Button(testing ? "测试中…" : "测试文字功能") {
                        diagnosticTask = Task { await testConnection() }
                    }.disabled(testing)
                    if testing { Button("取消测试") { diagnosticTask?.cancel() } }
                }
                Text("测试翻译、理解、回答和总结；回答另有一次内容核对。只发送固定的非敏感示例，会产生少量 API 用量。修改地址后需要为新地址重新保存密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.teal) }
                ForEach(diagnosticResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.id) · \(result.model) · \(result.seconds, specifier: "%.1f") 秒").font(.caption.bold())
                        Text(result.preview).font(.caption).textSelection(.enabled)
                        if let failure = result.failure { Text("未通过：" + failure).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section("OpenCode Go") {
                Text("按已确认方案预留。其服务主要面向编码代理；会议用途确认后再启用。当前请使用 DeepSeek、OpenAI 或适用的兼容服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("保存设置") { Task { await controller.saveSettings() } }.buttonStyle(.borderedProminent)
        }.formStyle(.grouped)
    }

    private var researchSettings: some View {
        Form {
            Section("研究者与课题") {
                TextField("身份", text: $controller.profile.identity)
                TextField("课题背景（作为背景信息，不自动确认为结果）", text: $controller.profile.project, axis: .vertical).lineLimit(3...6)
                Button("导入研究背景 Markdown…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let data = try Data(contentsOf: url)
                            guard data.count <= 100_000, let text = String(data: data, encoding: .utf8) else {
                                throw CopilotError.message("请导入小于 100 KB 的 UTF-8 Markdown 文件。")
                            }
                            controller.profile.project = text
                        } catch { controller.fail(error) }
                    }
                }
            }
            Section("事实与计划") {
                ForEach($controller.profile.facts) { $fact in
                    HStack(alignment: .top) {
                        TextField("内容", text: $fact.content, axis: .vertical)
                        Picker("状态", selection: $fact.kind) { ForEach(FactKind.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 150)
                        Button { controller.profile.facts.removeAll { $0.id == fact.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
                TextField("新增一条事实 / 计划 / 待确认信息", text: $factText, axis: .vertical)
                HStack {
                    Picker("类别", selection: $factKind) { ForEach(FactKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Button("添加") {
                        controller.profile.facts.append(.init(content: factText, kind: factKind)); factText = ""; factKind = .unknown
                    }.disabled(factText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("只有你标记为已确认的事实与计划，才能支持针对本研究的明确陈述。未知不等于尚未完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("术语表") { TextEditor(text: $controller.profile.terminology).frame(minHeight: 100) }
            Button("保存研究背景") { Task { await controller.saveSettings() } }.buttonStyle(.borderedProminent)
        }.formStyle(.grouped)
    }

    private func testConnection() async {
        testing = true; message = ""; diagnosticResults = []; defer { testing = false }
        do {
            let config = controller.selectedText
            let service = IntelligenceService(provider: HTTPTextProvider(configuration: config, key: try controller.credentials.apiKey(for: config)))
            try await TextServiceDiagnostics.run(configuration: config, service: service) { result in
                await MainActor.run { if controller.selectedText == config { diagnosticResults.append(result) } }
            }
            guard controller.selectedText == config else { return }
            let failures = diagnosticResults.filter { $0.failure != nil }.count
            message = failures == 0 ? "四项文字功能的示例响应、流式解析和来源检查通过。会议质量仍需单独验收。"
                : "测试完成，\(failures) 项未通过。请查看对应结果；连接成功不代表内容正确。"
        } catch is CancellationError { message = "测试已取消。" }
        catch { controller.fail(error) }
    }
}
