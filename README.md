# 科研会议 AI 副驾

本公开版本从脱敏源码快照建立独立提交历史。研究身份为通用示例，测试数据为合成材料。`Docs/Validation` 保留历史开发验证记录；其中的时间、哈希与测试结果对应当时的开发版本，不代表当前公开快照已重新通过全部验证。

按 [v3 实施计划](Zoom国际科研会议AI副驾——Codex实施计划_v3.md) 开发的原生 macOS 应用。默认 WhisperKit 本地语音识别，文字服务可独立选择 DeepSeek、OpenAI 或兼容接口。

目前处于开发验证阶段，已运行本地模型与 DeepSeek 的合成材料测试，并完成 Zoom 内置扬声器测试音的本地捕获。尚未完成真实多人会议、实际医学会议质量和 90 分钟稳定性验收；语音样例中仍存在 `irreversible` 被识别成 `a reversible` 的含义反转。详细结果见 [实施状态](Docs/IMPLEMENTATION_STATUS.md)。

## 开发运行

要求 Apple Silicon Mac、macOS 15+ 和 Swift 6 工具链。推荐安装完整 Xcode；本工程也提供 Swift Package 命令行构建路径。

```bash
bash Scripts/test.sh
bash Scripts/build-app.sh
open build/ResearchCopilot.app
```

首次构建需要下载已固定的 WhisperKit 依赖。`Package.resolved` 锁定具体提交。脚本把编译缓存放在项目的 `.build` 中，不修改系统工具链选择。

本地构建使用 ad-hoc 签名，只用于开发。发布给其他用户前仍需正式签名、公证、权限与兼容性验证。

## 首次配置

1. 打开应用设置，在“语音识别”中下载并准备模型，或导入含配套分词资源的 WhisperKit 目录并点击“离线加载已有模型”。后者不会自动联网补文件。详见[模型准备与导入](Docs/MODEL_PREPARATION.md)。
2. “文字模型”中选择 DeepSeek、OpenAI 或自定义服务，设置模型并将 API Key 保存到钥匙串。
3. 点击“测试文字功能”，依次检查翻译、理解、回答和总结。只发送固定的虚构材料，有少量 API 用量；每项结果或失败原因会显示在设置中。
4. 开启云端文字功能，保存设置。文字和必要研究背景会发送给所选服务；本地语音无需 OpenAI Key。
5. 在“研究背景”中录入确认事实、计划与术语，未知项保留为待确认。
6. 打开 Zoom 并使用耳机，在应用中刷新音源；按 macOS 提示授予屏幕与系统音频录制权限。
7. 如需记录自己的发言，单独开启麦克风。副驾麦克风与 Zoom 静音状态不联动。
8. 开始会议，可多选转写片段生成回答；结束后生成总结并导出 Markdown。

可先点击“检测 Zoom 音源（30 秒）”，配合 Zoom 自带的扬声器测试确认能否收到声音。此检测不需要模型或 API Key，强制关闭副驾麦克风，不创建会议记录，30 秒后自动停止。实测结果和开发版权限排错见 [Zoom 音源验证](Docs/ZOOM_AUDIO_CAPTURE_2026-09-16.md)。

睡眠、所选 Zoom 退出或正在使用的麦克风变化时，程序停止采集并提示手动恢复；不会自动切到其他音源。Zoom 退出已做原生实测，实际睡眠与麦克风硬件切换仍待验证，见[中断恢复记录](Docs/CAPTURE_LIFECYCLE_2026-09-16.md)。

## 数据与凭据

- 会议文字、设置及研究背景：`~/Library/Application Support/ResearchCopilot`，加密存储。
- API Key 和本地加密密钥：macOS Keychain。
- 原始会议音频：只用于内存中的识别队列，不写入录音文件。
- 模型资源：Application Support 下的 `Models` 目录或用户导入的目录；模型与分词完整性基线位于模型缓存的 `ResourceIntegrity` 中。
- 导出的 Markdown 是普通文本，包含实际转写与单独标记的 AI 建议。
- 改变服务地址不会自动向新地址发送旧密钥；不自动跨供应商重试。
- OpenCode Go 保持预留，会议用途确认前不启用。

保存失败时，当前会议保留在内存中，正常退出或切换会议会暂停；可使用底部的重试入口，或主动导出 Markdown。历史记录中未正常结束的会议可恢复最后已保存的文字，恢复不会自动开启音频采集。损坏记录会单独提示，原文件保留。验证范围及局限见[保存与恢复验证](Docs/STORAGE_RECOVERY_2026-09-16.md)。

## 代码结构

- `Sources/CopilotCore`：转写与事实模型、加密存储、VAD 与有界队列、文字接口、证据检查、Markdown 导出。
- `Sources/CopilotSpeech`：WhisperKit 加载、双音轨推理、语言检测与对齐、可选 OpenAI 语音传输与恢复。
- `Sources/ResearchCopilot`：SwiftUI 界面、会议控制器、ScreenCaptureKit 与供应商接入设置。
- `Sources/CopilotDiagnostics`：固定材料的真实模型/API 诊断与测量，不采集会议音源。
- `Tests/CopilotCoreTests`、`Tests/CopilotSpeechTests`、`Tests/ResearchCopilotTests`：时序、存储、格式、流式行为、词时间戳对齐及应用控制器故障恢复回归。
- `Templates`：研究背景模板。
- `Resources`：应用元数据。
- `Scripts`：测试与 `.app` 打包。

## 可复现的开发验证

先执行 `bash Scripts/test.sh`，确保诊断程序已编译。以下语音测试只使用专门构造的音频，不调用付费 API。

```bash
bash Scripts/create-asr-fixtures.sh
.build/debug/CopilotDiagnostics prepare-model --cache .build/models
bash Scripts/run-asr-benchmarks.sh .build/models .build/benchmarks-local
```

首次准备会下载模型和分词文件并进行 Core ML 预热；缓存齐全后可离线识别。终端所在的额外沙箱若禁止 GPU / Core ML 缓存访问，需要在正常 macOS 运行环境执行。模型文件约 606 MiB，不能据此推断运行内存。

文字测试通过 macOS 钥匙串读取应用中已经保存的默认端点凭据，不需要把 Key 放到命令行。macOS 可能要求为单独的诊断程序确认钥匙串访问；也可以直接在应用设置中测试。

```bash
.build/debug/CopilotDiagnostics test-text --provider deepSeek \
  --report .build/benchmarks-local/deepseek.json
```

该命令使用供应商默认端点与默认模型，发送四项虚构示例；回答另有一次事实与中英文一致性核对，因此通常共五次 API 请求，会产生少量用量。不读取会议和个人研究背景。加上 `--check-answer-guard` 可另测一次虚构研究结论的拦截。自定义端点或自选模型请在应用设置中测试。报告包含示例输出、核对结果与失败详情，不含密钥；未通过时退出码为 1。

正式回答也经过同一供应商的独立核对，核对失败或请求异常时不发布新建议。模型核对仍可能误判，不能视为零幻觉保证；它也会增加一次 API 调用和相应延迟。

已增加 [60 条语义开发用例与评测说明](Fixtures/Semantics/README.md)，提供离线测试集校验及付费 API 分类/回答评测。全部初始标签待人工审核；草稿测试、人工保留集和接口调用成功分别报告。

另有默认关闭的 [本地 ASR → DeepSeek 完整链路诊断](Docs/MEETING_INTEGRATION_2026-09-16.md)，以固定合成音频驱动生产会议控制器，并保存阶段计时、翻译、回答、总结及失败报告。运行会调用付费 API；目前测试代码已就绪，真实链路尚待授权执行。

可选云端语音的有限重连、尾部等待和故障测试见 [云端语音验证记录](Docs/CLOUD_TRANSCRIPTION_2026-09-16.md)。该功能尚未完成真实 OpenAI 音频会话验证；默认本地语音不依赖它。

识别评测已增加关键短语检查和相反含义对照，并修复了后处理丢弃零时长否定词的问题。界面和导出会标记此类片段的时间定位局限。模型自身的术语错误仍需解决，详见[关键字词与遗漏验证](Docs/ASR_CRITICAL_WORDS_2026-09-16.md)。

建议和总结中的来源可点击定位原文；更正后可查看生成时的旧版本。Markdown 导出也包含文件内部的来源链接。原生交互验证和独立虚构会议副本的运行方法见[来源追溯说明](Docs/SOURCE_TRACEABILITY_2026-09-16.md)。

详细验收以 v3 计划为准。模型输出需要人工核实；源片段关联与数字检查不能证明语义上绝无错误。
