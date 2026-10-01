# irreversible 关键错误一次性解码探针与语音覆盖

日期：2026-09-16 晚，Kimi3 接手后。接续 [关键字词验证](ASR_CRITICAL_WORDS_2026-09-16.md) 的未解决项：默认模型把 Daniel 合成的 `irreversible muscle injury` 识别为 `a reversible muscle injury`。

## 标签确认（机器可完成部分）

- `necrosis.aiff` 由 `say -v Daniel -f Fixtures/ASR/necrosis.txt` 生成（`Scripts/create-asr-fixtures.sh`），参考文本即合成输入，标签无转写歧义；音频 SHA-256 `6c43cb65…c470` 与完整链路诊断报告一致。
- **人工核听已完成（2026-09-16 晚，用户本人）**：播放 Daniel 原音频两遍与 Samantha 对照一遍后，用户判断 **Daniel 版 `ir-` 首音节对人耳同样含糊**。该样本人工定级为**声学边界样本**：标签（合成输入）为 `irreversible` 无误，但音频实现本身接近 `a reversible`，不能作为“清晰语音被模型误识别”的强证据。
- 机器流程不能替代的另一半判断——该合成音对真实会议口音的代表性——仍未完成；真实发言中类似的首音节弱化会出现，因此含义反转风险类别仍然成立。

## 管线嫌疑排除（既有解码轨迹，无新代码）

[asr-critical-fixed](Validation/2026-09-16/asr-critical-fixed/baseline/necrosis.json) 的逐窗解码轨迹显示：10 个窗口（含覆盖完整 11.16 秒问题的最终窗）原始模型输出全部已是 `a reversible`（逐词分数 0.99），首个 6 秒窗在语音完整覆盖该词后即出错。装配/去重/修订逻辑未改变该词。**流式管线、窗口边界、装配器均不是成因。**

## 新增工具

`CopilotDiagnostics decode-probe`：绕过 SpeechSegmenter/队列/装配器，对整段或剪辑音频做单次 `kit.transcribe` 调用；支持 `--start/--end`、`--language`、`--no-word-timestamps`、`--prompt-text/--prompt-file`、`--temperature`、`--top-k`、`--repeat`。报告含输入哈希与全部参数。提示词条件仅为诊断探针，不是评测输入，不能据此宣称识别质量。

## 探针结果（报告原件：[decode-probes](Validation/2026-09-16/decode-probes/)）

| 条件（necrosis，Daniel，r160/165） | 结果 |
| --- | --- |
| 一次性整段解码 | `a reversible`（与管线最终文字一致） |
| 无词时间戳纯文本 | 同上 |
| 剪辑 3.0–6.5s（仅该句） | `a reversible` |
| 剪辑 4.2–5.6s（仅该词附近） | `present a reversible muscle` |
| 参考前缀 teacher-forcing 提示 | 仍 `a reversible` |
| 温度 0.6 ×5、温度 1.0 ×5 | 10/10 全部 `a reversible`，零波动 |
| reversible-control（Daniel） | 参考的 `irreversible necrosis` → `a reversible necrosis`（**第二处独立复现**） |
| irreversible-control（Samantha）、necrosis-samantha | 正确 |

## 语音覆盖（同一文本 10 种 macOS 英语声音，r160）

- **仅 Daniel（en_GB compact）出错**，且在 r140/r160/r165/r180/r200 全语速复现。
- Fred、Karen(en_AU)、Kathy、Moira(en_IE)、Rishi(en_IN)、Samantha、Tara(en_IN)、Tessa(en_ZA)、Aman(en_IN) 九种声音同一句子全部正确保留 `irreversible`。
- reversible-control 交叉验证：Samantha、Fred、Karen 均正确（含 `irreversible necrosis`）。

## 结论

1. 这是**模型在声学边界样本上的系统性错选**：Daniel 合成音的 `irreversible` 首音节实现对人耳也含糊（用户核听确认），模型稳定映射为 `a re-`，置信度 0.99，与解码参数、提示、温度、剪辑、管线均无关。该样本不再作为“清晰语音被误识别”的强证据，但保留为困难对照。
2. 触发面窄（10 种合成声音中 1 种）但后果是含义反转；真正的产品风险是**模型在含糊音频上输出满置信度、无任何不确定信号**——不能用“其他声音正确”或总体 WER 宣称该问题已解除。
3. 解码层面无解：前缀提示、温度采样、一次性解码全部无效；自动替词仍被禁止（会把真实的 `reversible` 改错）。
4. 后续方向（人工核听已完成，见上）：替代引擎比较（同一音频喂给 whisper.cpp 或其他引擎，观察更强语言先验能否利用上下文纠正含糊音频；人耳已含糊时预期改善有限）；扩展真实口音材料（重点收集首音节弱化的真实 `irreversible`）；以及作为产品层的**易混词对提示**（标注而非替换，需另行设计与评估）。

## 复现命令

```bash
bash Scripts/test.sh   # 编译 CopilotDiagnostics
M="$(cat .build/models/prepared-model-path.txt)"
.build/debug/CopilotDiagnostics decode-probe --cache .build/models --folder "$M" \
  --audio .build/fixtures/necrosis.aiff --report .build/decode-probes/necrosis-full.json
```

Core ML 需要正常 macOS 执行权限；额外沙箱拦截 `~/Library/Caches` 会导致零输出，应与产品错误分开记录。本轮为本地合成与离线解码，无网络调用。
