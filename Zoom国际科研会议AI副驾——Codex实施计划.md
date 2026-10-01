# 项目名称

Zoom Medical Research Copilot  
中文名：Zoom 国际科研会议 AI 副驾

## 一、工作模式要求

你现在处于 Plan Mode。

在用户明确批准实施之前：

- 不创建或修改任何代码文件。
- 不安装依赖。
- 不修改系统设置。
- 不执行具有副作用的命令。
- 不申请额外系统权限。
- 不部署任何服务。
- 先检查本机开发环境和可用 API，再输出最终实施方案。
- 如果实际环境与本计划冲突，优先修改计划，不要擅自开始实施。

用户批准后再进入 implementation mode。

---

# 二、项目目标

开发一个运行于 macOS 的轻量级实时会议助手，用于 Zoom 国际医学科研课题组会。

软件需要完成以下流程：

Zoom 外国专家英语语音

→ 捕获 Zoom 系统音频

→ 英语实时语音识别

→ 实时显示英文原文

→ 自动判断专家是否提出了一个需要回答的问题

→ 提炼中文核心意思

→ 判断专家意图

→ 根据用户的身份、课题背景和当前会议上下文

→ 自动生成适合科研会议现场直接说出口的英文回答

→ 显示推荐答案、简短答案和谨慎答案

→ 用户本人决定最终说哪一个答案

严禁软件自动把 AI 生成的语音发送进入 Zoom。

---

# 三、用户角色

用户是一名：

- 临床医生
- 医学科研人员
- 国际医学科研课题组会参与者

AI 回答风格要求：

- 专业
- 自然
- 谦逊但不卑微
- 符合国际医学科研会议口语习惯
- 尽量使用短句
- 避免复杂难发音句型
- 不使用论文式长句
- 不虚构实验结果
- 不虚构数据
- 不虚构参考文献
- 数据不确定时明确采用谨慎表达

重点适配医学科研讨论，例如：

- experimental design
- animal model
- sample size
- histology
- imaging
- sensitivity / specificity
- clinical translation
- mechanism
- innovation
- study endpoint
- statistics
- feasibility
- limitations
- confounding factors
- future validation

---

# 四、总体技术架构

优先开发一个原生 macOS 应用。

技术栈：

- Swift
- SwiftUI
- ScreenCaptureKit
- AVFoundation / AVAudioConverter
- URLSession WebSocket
- OpenAI Realtime / Live Transcription API
- OpenAI Responses API
- macOS Keychain

避免 MVP 阶段使用：

- Electron
- Docker
- BlackHole
- Loopback
- 浏览器插件
- Zoom SDK
- 复杂服务器部署

原则是：

**依赖越少越好，安装越简单越好，会议现场越稳定越好。**

---

# 五、系统数据流

## Step 1：捕获 Zoom 音频

使用 macOS ScreenCaptureKit。

要求：

1. 枚举当前运行应用。
2. 找到 Zoom。
3. 用户在界面中选择 Zoom 作为音频来源。
4. 使用 SCContentFilter 尽可能只捕获 Zoom。
5. 开启：
   - capturesAudio
6. 不采集本应用自己的声音。
7. 第一版默认不采集用户麦克风。

这样主要分析国外专家发言，而不是把用户自己的回答再次识别成专家问题。

同时保留一个开关：

“Include microphone”

默认关闭。

---

# 六、音频处理模块

创建 AudioCaptureService。

职责：

- 接收 ScreenCaptureKit 的 CMSampleBuffer。
- 转换为 AVAudioPCMBuffer。
- 转换成 OpenAI 实时接口支持的 PCM 格式。
- 单声道。
- 按适合实时传输的小块持续发送。
- 不保存原始会议音频，除非用户主动开启录音。

需要重点处理：

- sample rate conversion
- channel conversion
- buffer queue
- dropped buffer
- reconnect
- audio silence

会议不能因为短暂网络抖动导致整个应用崩溃。

---

# 七、实时英文转写

首选：

gpt-live-transcribe

用途：

Zoom audio

→ streaming transcription

要求：

1. 使用持续 WebSocket / Live session。
2. 实时接收 partial transcript。
3. partial transcript 用灰色显示。
4. finalized transcript 用正常字体显示。
5. 保留最近约 5–10 分钟会议上下文。
6. 不把整场会议无限发送给回答模型。

加入医学关键词提示，提高识别率。

例如：

acute compartment syndrome  
ACS  
confocal laser endomicroscopy  
CLE  
ischemia-reperfusion  
fasciotomy  
skeletal muscle  
histopathology  
near-infrared spectroscopy  
NIRS  
shear wave elastography  
SWE  
microcirculation  
necrosis  
perfusion  
intracompartmental pressure

关键词列表以后应支持用户编辑。

---

# 八、专家发言分段

建立 TranscriptTurnDetector。

不要每收到几个词就请求一次大模型。

判断一个专家发言结束，可以综合：

- speech pause
- finalized transcription
- 标点
- 句尾语义
- 静音时间

建议设置可调 debounce。

初始可以尝试：

约 0.8–1.5 秒静音后进入“可能发言结束”状态。

如果讲话继续，则取消触发。

目标：

降低重复回答和 API 请求次数。

---

# 九、问题检测

并不是专家每说一句都需要生成回答。

系统需要判断：

QUESTION  
COMMENT  
SUGGESTION  
CLARIFICATION  
CRITICISM  
BACKGROUND  
SMALL_TALK  
UNKNOWN

可以采用两级机制。

## Level 1：本地快速判断

检查：

- question mark
- why
- how
- what
- whether
- could you
- can you
- have you
- do you
- would you
- I'm wondering
- I'm curious
- my question is
- could you explain

如果明确是问题，则直接进入 AI 分析。

## Level 2：轻量模型判断

对于不明确的长发言，可以使用低成本模型判断是否需要用户回应。

推荐：

gpt-5.6-luna

只输出结构化结果，例如：

{
  "requires_response": true,
  "intent": "experimental_design_question",
  "confidence": 0.92
}

如果 requires_response=false：

只显示转写，不生成回答。

---

# 十、回答生成

真正需要回答时使用：

gpt-5.6-sol

优先低延迟配置。

不要进行不必要的深度推理。

输入包括：

1. 专家刚刚完整发言。
2. 前面少量会议上下文。
3. 用户研究者身份。
4. 用户研究课题背景。
5. 已知实验信息。
6. 明确的防幻觉指令。

输出采用结构化 JSON。

建议 schema：

{
  "original_question": "",
  "core_question_cn": "",
  "intent_cn": "",
  "recommended_answer_en": "",
  "recommended_answer_cn": "",
  "short_answer_en": "",
  "cautious_answer_en": "",
  "clarification_question_en": "",
  "confidence": 0.0,
  "warning": ""
}

---

# 十一、回答逻辑

## 推荐回答

目标：

约 20–40 秒可以说完。

结构根据问题自动选择。

常见结构：

Acknowledgement

→ direct answer

→ brief rationale

→ next step / limitation

例如：

“That's a very important point. Our current thinking is that…”

## 简短回答

约 10–15 秒。

适合：

- Zoom 节奏快
- 对方只需要简单确认
- 用户需要立即回答

## 谨慎回答

出现以下情况必须优先提供：

- 用户没有给出相关实验数据
- 专家询问尚未获得的结果
- 专家要求统计结果但上下文没有数据
- AI 无法确定实验方案细节
- 问题存在多种解释

典型表达：

“We don't have enough data to answer that definitively at this stage…”

或者：

“I don't want to overinterpret our preliminary findings…”

---

# 十二、绝对禁止幻觉

System Prompt 中加入硬规则：

NEVER invent:

- sample size
- P values
- sensitivity
- specificity
- experimental results
- histological findings
- patient numbers
- unpublished results
- references
- dates
- device performance

如果信息不存在：

明确说不知道。

然后提供一个专业的谨慎回答。

例如：

“We haven't completed that analysis yet, so I would prefer not to draw a firm conclusion at this stage.”

---

# 十三、上下文系统

建立 ResearchContext。

建议文件：

research_profile.md

内容包括：

## User

Medical researcher.

## Research interests

用户自行维护。

## Current project

用户自行维护。

## Known experimental design

用户自行维护。

## Terminology

用户自行维护。

回答模型每次不要读取过长全文。

启动会议时加载研究背景。

每次回答只注入：

- 稳定用户身份
- 当前课题摘要
- 最近若干轮会议上下文
- 当前专家问题

---

# 十四、用户界面

使用 SwiftUI。

窗口建议采用三栏/四区布局。

## 顶部状态栏

显示：

🟢 Zoom Audio Connected  
🟢 OpenAI Connected  
🎤 Expert Speaking  
🧠 Analyzing  
✅ Answer Ready

不要使用复杂动画。

---

## 左栏：Live Transcript

标题：

Expert — English

实时英文字幕。

最近发言突出显示。

---

## 中栏：核心问题

显示：

中文核心问题

例如：

“专家在问：为什么动物实验每组只设置 6 只，以及样本量计算依据是什么？”

下面显示：

专家意图：

“质疑样本量设计依据”

---

## 右栏：推荐回答

最明显的位置显示：

⭐ Recommended Answer

英文大字号。

方便用户直接看着屏幕说。

下面小字：

中文意思。

---

## 底部

两个折叠区域：

Short Answer

Cautious Answer

不要一开始同时显示大量英文，以免会议现场增加阅读负担。

---

# 十五、关键交互

必须有以下按钮：

Start Listening

Stop Listening

Generate Answer

Regenerate

Shorter

More Academic

More Conversational

Clarify Question

Pin Answer

Copy

---

# 十六、会议现场快捷键

设计全局快捷键，但 MVP 如果实现复杂可以延后。

优先考虑：

Option + A

强制针对最近一次专家发言生成答案。

Option + S

生成更短答案。

Option + C

生成澄清问题。

Option + P

固定当前答案，防止被下一次专家发言覆盖。

---

# 十七、非常重要：不要自动说话

应用只能：

听

→ 分析

→ 显示建议

绝对不要：

自动打开麦克风

自动向 Zoom 播放 TTS

自动替用户回答专家

最终发言必须由用户自己决定。

---

# 十八、问题识别错误的人工兜底

自动识别一定会偶尔出错。

因此必须保留：

“Answer latest transcript”

按钮。

如果软件没有判断专家是在提问，用户只需点击一次即可强制生成回答。

同时提供：

“Use last 30 seconds”

如果专家问题特别长，可以重新分析最近约 30 秒完整上下文。

---

# 十九、延迟优化

目标不是追求复杂功能，而是让回答尽快出现。

优先级：

1. 转写低延迟。
2. 正确检测发言结束。
3. 快速输出核心问题。
4. 推荐英文回答开始流式显示。
5. 中文解释可以稍后完成。

回答模型开启 streaming。

不要等整个 JSON 全部生成完才显示。

如果技术允许：

先显示：

Core Question

再显示：

Recommended Answer

最后生成：

Short / Cautious Answer

---

# 二十、失败降级策略

必须设计三层降级。

## Level A

正常：

Realtime transcription + AI answer.

## Level B

如果问题识别模块失败：

继续显示实时英文字幕。

用户手动点击：

Generate Answer.

## Level C

如果回答模型暂时不可用：

保留完整专家英文问题。

提供按钮：

Copy transcript.

任何 API 错误都不能导致字幕界面崩溃。

---

# 二十一、网络断线

需要：

- WebSocket 自动重连
- 状态提示
- exponential backoff
- 保留最近本地 transcript
- 重连后继续工作

不要因为一次掉线退出程序。

---

# 二十二、隐私

默认：

不保存原始音频。

默认：

会议结束后允许清除 transcript。

提供：

Clear Session

按钮。

API Key：

不得硬编码在源码。

个人本地版本优先：

从环境变量读取或者保存到 macOS Keychain。

不得提交到 Git。

.gitignore 必须包含：

.env

任何 credentials 文件。

---

# 二十三、权限

首次运行需要向用户明确解释：

应用需要 macOS Screen & System Audio Recording 权限，是为了读取 Zoom 的会议音频。

不要申请：

Accessibility

Microphone

Camera

除非功能确实需要。

MVP 默认不需要麦克风和摄像头。

---

# 二十四、MVP 范围

第一版只实现以下六件事：

1. 选择 Zoom。
2. 捕获 Zoom 音频。
3. 实时英文转写。
4. 自动检测一个专家问题。
5. 生成中文核心问题。
6. 生成推荐英文回答。

第一版不要实现：

- 自动 TTS
- 会议总结
- Speaker diarization
- 专家身份识别
- 数据库
- 云端同步
- 用户账户系统
- Zoom 插件
- 复杂设置页面
- 录音管理

先保证核心链路稳定。

---

# 二十五、MVP 验收标准

必须通过以下真实场景测试。

播放一句英文医学科研问题：

“What is the rationale for selecting this time point, and how do you plan to validate it histologically?”

应用需要：

1. 自动获得英文 transcript。
2. 识别这是科研问题。
3. 中文显示：

“专家询问为什么选择该观察时间点，以及如何通过组织学进行验证。”

4. 自动生成一个不虚构数据的英文回答。
5. 回答可以直接在科研组会上说。
6. 用户不需要复制字幕或截图。

---

# 二十六、复杂问题测试

测试：

“I'm not entirely convinced that the imaging changes you're seeing necessarily represent irreversible muscle injury. How are you going to distinguish reversible ischemic changes from actual necrosis?”

系统应理解核心问题为：

如何区分可逆性肌肉缺血改变和真正不可逆坏死，并验证影像学表现。

答案不能凭空声称已有实验结果。

应该采用类似逻辑：

Acknowledgement

→ explain proposed correlation

→ histological validation

→ longitudinal/time-point assessment

→ acknowledge this is a key research question

---

# 二十七、医学科研答复 Prompt

核心 system instruction：

You are a real-time scientific meeting copilot for a trauma orthopedic surgeon and medical researcher.

Your job is not merely to translate.

Your job is to understand what the international expert is asking and help the researcher formulate a scientifically appropriate spoken response.

The response must sound natural when spoken during an international research meeting.

Prioritize:
accuracy,
clarity,
scientific caution,
and brevity.

Never fabricate results or data.

If information is missing, explicitly produce a cautious response rather than guessing.

The recommended answer should normally take approximately 20–40 seconds to speak.

Avoid unnecessarily complicated vocabulary and long sentences.

---

# 二十八、项目目录建议

ZoomMedicalCopilot/

App/

Audio/

AudioCaptureService.swift

AudioConverter.swift

Transcription/

RealtimeTranscriptionService.swift

TranscriptStore.swift

TurnDetector.swift

AI/

QuestionClassifier.swift

AnswerGenerator.swift

PromptBuilder.swift

Models/

MeetingTurn.swift

ExpertQuestion.swift

SuggestedAnswer.swift

Context/

ResearchContext.swift

research_profile.md

UI/

MainView.swift

TranscriptView.swift

QuestionView.swift

AnswerView.swift

StatusBar.swift

Settings/

APISettings.swift

Security/

KeychainService.swift

Tests/

README.md

.gitignore

---

# 二十九、实施顺序

严格按以下顺序开发。

Phase 1

建立 macOS SwiftUI 空项目。

Phase 2

完成 ScreenCaptureKit Zoom 音频捕获。

在进入下一步前先确认：

能稳定获得 Zoom audio buffer。

Phase 3

接入实时转写。

确认：

专家英语可以持续出现在窗口。

Phase 4

实现发言分段。

Phase 5

实现问题检测。

Phase 6

实现 GPT 回答生成。

Phase 7

建立三栏 UI。

Phase 8

实现错误恢复。

Phase 9

添加研究背景 context。

Phase 10

使用医学科研问题进行完整模拟。

不要同时开发多个模块后才测试。

每完成一个 Phase 都运行测试。

---

# 三十、测试策略

至少测试：

正常英语

快速英语

不同口音英语

科研专业术语

专家长问题

专家连续提出两个问题

专家只是陈述观点而非提问

专家给建议

专家批评研究设计

网络短暂中断

Zoom 静音

没有 Zoom 打开的情况

API Key 无效

API rate limit

---

# 三十一、最终交付

最终应该得到：

一个可运行的 macOS 应用。

用户操作流程必须非常简单：

1. 打开 Zoom。
2. 打开 Zoom Medical Copilot。
3. 选择 Zoom。
4. 点击 Start Listening。
5. 开会。

之后：

专家讲话 → 自动显示英文。

专家提问 → 自动出现中文核心问题和推荐英文回答。

用户无需：

截图

复制 Zoom 字幕

切换窗口粘贴文本

手动输入专家问题。

---

# 三十二、Plan Mode 当前任务

现在先不要写代码。

请先完成以下事项：

1. 检查当前 Mac 的 macOS 版本。
2. 检查 Xcode / Swift 开发环境。
3. 判断 ScreenCaptureKit API 是否满足 Zoom 独立音频捕获需求。
4. 检查 OpenAI 当前 realtime transcription API 的准确调用方式。
5. 检查 gpt-live-transcribe 和 gpt-5.6-sol 当前接口。
6. 检查需要哪些 macOS entitlements / Info.plist 权限。
7. 找出本计划中可能导致今晚无法运行的技术风险。
8. 给出最终项目架构。
9. 给出即将创建的文件列表。
10. 给出测试方法。
11. 给出 MVP 与后续增强功能的明确边界。

最后输出：

IMPLEMENTATION PLAN READY

然后停止。

必须等待用户明确输入：

APPROVE AND IMPLEMENT MVP

之后才能开始创建文件、安装依赖、运行代码或修改系统配置。