# 关键字词与零时长词遗漏验证

日期：2026-09-16。此记录属于开发验证，不是实际医学会议验收。

## 发现与修复

此前报告中的 `missingCriticalTerms: []` 没有传入检查词表，不能表示重要术语全部正确。本轮将关键短语作为独立评测输入，记录 `checkedCriticalTerms`，并按连续完整词元比较，防止把 `irreversible` 中的 `reversible` 或 `130` 中的 `30` 当作命中。旧报告保留原样，缺失检查范围的记录按“未检查”解释。

同一问题由 Daniel 合成时，默认模型仍把 `irreversible muscle injury` 识别为 `a reversible muscle injury`；改用 Samantha 合成的同文样例可以识别正确。该结果提示错误与输入声音有关，不能替代人对音频清晰度和口音的评估。出错词 `reversible` 的模型逐词分数约为 0.99，因此不能用高模型分数来断言重要事实可靠。

短术语提示的对照还发现一个独立的软件问题：解码文本保留了 `I'm not`，但词时间均为 `[0, 0]`。后处理此前只接受结束时间大于开始时间的词，从而丢掉了否定。此次修复不改变解码文字：把零时长词与下一有效时间词作为同一组处理；尾部零时长词附着到上一组。整组共同接受重叠去重和跨窗口提交判断，避免单独丢掉否定词。

至少仍须有一个有效时间锚点；全部词均无有效时长时保留原来的缺口处理。出现此类分组的片段写入 `timingApproximate`，界面和 Markdown 导出显示时间定位不精确。它是时间说明，不是对转写正确性的确认，也没有从参考答案补词或自动替换模型误识别的 `a reversible`。

## 对照方法

- 继续使用本机已缓存的 `large-v3-v20240930_626MB`，WhisperKit 1.1.0。模型配置为 32 层编码器、4 层解码器，默认模型与提示策略未更换。
- 两个配置：不加 ASR 提示；显式传入 7 个简短术语，包含 `reversible` 和 `irreversible` 两种词形。提示不包含参考句或期望结论。
- 六个单轨样例：原有时间点、坏死问题、数字与否定；新增可逆对照、不可逆对照，以及坏死问题的 Samantha 版本。另测一组 Daniel 英语与 Tingting 中文双轨。
- 以 100 ms 音频帧按播放速度经过生产识别管线。只运行显式生成的测试文件，诊断进程通过 `sandbox-exec` 禁止联网，没有会议捕获或 API 请求。
- 关键短语表只用于本地评测，不传给模型。两组各检查 23 个单轨短语；双轨的重复英语不计入单轨汇总。字面出现不证明否定范围或语义正确，数字及单位的等价表达仍需人工复核。
- 报告记录音频、参考文本、短语表、提示文件的 SHA-256。汇总器核对成对输入及模型资源是否相同，并拒绝缺少检查范围的旧报告。

修复前的完整 14 次结果保存在 [asr-critical-before](Validation/2026-09-16/asr-critical-before/comparison.json)，不会用修复后的结果覆盖。

## 验证结果

修复前六个单轨样例的字面 WER：不加提示为 6/160（3.75%），短提示为 20/160（12.50%）。缺失选定关键短语分别为 2/23 与 4/23。短提示没有解决 `irreversible` 的误识别，并暴露出上述丢词。其双轨最长 final 延迟约 13.98 秒，中文 CER 约 16.95%，记录 1 处缺口；因此不应直接启用。

修复后的完整 14 次结果保存在 [asr-critical-fixed](Validation/2026-09-16/asr-critical-fixed/comparison.json)。两组都使用相同音频文件哈希；默认配置各轨最终文字与修复前保持一致。短提示下 `I'm not`、`What is` 等已不再被后处理删除。

| 样例 | 修复后默认 WER | 修复后短提示 WER | 默认 / 短提示缺失关键短语数 |
| --- | ---: | ---: | ---: |
| 时间点 | 0% | 0% | 0 / 0 |
| 坏死问题，Daniel | 7.41% | 7.41% | 1 / 1 |
| 数字与否定 | 5.13% | 12.82% | 0 / 0 |
| 可逆对照，Daniel | 7.69% | 7.69% | 1 / 1 |
| 不可逆对照，Samantha | 0% | 0% | 0 / 0 |
| 坏死问题，Samantha | 0% | 0% | 0 / 0 |
| 中英双轨中的英语 | 7.41% | 7.41% | 1 / 1 |

六个单轨汇总：默认 6/160（3.75%），短提示 9/160（5.625%）；两者均有 2/23 个选定关键短语未保留。默认的两个问题均为 `irreversible` → `a reversible`。短提示的数字样例重复了 `of mercury, not 13`，没有解决术语错误。

本轮默认双轨中文 CER=0，短提示约 13.56%；两组均无报告缺口，但短提示的中文内容仍有误。默认双轨最长 final 延迟约 8.40 秒，短提示约 12.80 秒。两轮系统负载与冷缓存不完全相同，不能把前后延迟差归因于这次修复；该延迟也不是问题结束至回答就绪时间。默认策略继续关闭 ASR 术语提示。

80 项自动回归已通过，包括实际观察到的 `I'm not` 零时长词、跨窗口否定词分组与去重、专项词边界和旧报告兼容。

原生界面验证副本已确认时间定位提示正常显示，并通过原生保存对话框导出 [synthetic-timing-review.md](Validation/2026-09-16/ui-review/synthetic-timing-review.md)。该副本只使用虚构材料及内存存储，不调用模型、读取个人记录或请求音频权限。

修复已打包到普通 `ResearchCopilot.app` 并启动；同一授权范围内恢复录屏与系统录音后，重新完成 30 秒 Zoom 内置测试音捕获，麦克风 0 帧，自动停止成功。见[更新应用的捕获复测](ZOOM_AUDIO_CAPTURE_2026-09-16.md#asr-丢词修复版的捕获复测)。

## 完整 large-v3 压缩模型比较

从相同固定提交单独准备 `openai_whisper-large-v3_947MB`。实际配置为 32 层编码器、32 层解码器，词表 51866、维度 1280；默认模型解码器为 4 层。包括下载、校验、分词准备和预热共约 842.71 秒，缓存约 914 MiB。首次直接连接曾超时，沿用用户已有的系统代理下载成功，没有修改代理设置。

较大模型随后在禁止联网的诊断进程中，使用相同七组音频、参考文本、关键短语表和生产管线运行。两模型均未加 ASR 提示，输入哈希与管线版本已逐项核对。原始报告和模型配置保存于 [asr-large-v3](Validation/2026-09-16/asr-large-v3/model-comparison.json)。

| 指标 | 默认 626MB 模型 | 947MB 模型 |
| --- | ---: | ---: |
| 六个单轨字面 WER | 6/160，3.75% | 5/160，3.125% |
| 未保留的选定关键短语 | 2/23 | 2/23 |
| 双轨英语 WER | 7.41% | 7.41% |
| 双轨中文 CER | 0% | 3.39% |
| 单轨最长 final 延迟 | 4.20 秒 | 8.89 秒 |
| 双轨最长 final 延迟 | 8.40 秒 | 24.13 秒 |
| 本轮进程峰值 RSS 范围 | 759–933 MiB | 527–1006 MiB |
| 报告缺口数 | 0 | 0 |

较大模型仍在两个 Daniel 样例中把 `irreversible` 识别成 `a reversible`，对应最终文字完全相同。字面 WER 的一词改善来自 `mm` 与 `millimeters` 的单位写法差异，不代表新增医学语义正确性。其双轨中文把“与”转成“育”，并漏掉“您”；无报告缺口不等于文字无遗漏。

两组非同时运行，系统负载和缓存未严格控制，因此延迟与 RSS 是本轮观测值；没有据此推算 90 分钟表现或回答就绪延迟。本轮没有解决关键含义错误，且双轨延迟更高，**保留原应用默认模型，不启用较大模型或短术语提示**。资源已缓存，可用于后续独立语料验证。

## 可复现命令

```bash
bash Scripts/test.sh
bash Scripts/create-asr-fixtures.sh
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /bin/bash Scripts/run-asr-critical-comparison.sh .build/models .build/benchmarks-critical-fixed
python3 Scripts/summarize-asr-comparison.py .build/benchmarks-critical-fixed
bash Scripts/build-ui-review.sh
```

界面验证构建现在直接写入 `ResearchCopilotReview.app`，不会重新签名普通应用。普通应用构建仍使用 `bash Scripts/build-app.sh`。这避免仅验证界面时使之前的 ad-hoc 录屏授权失效。

较大模型比较（先按模型准备流程生成对应缓存）：

```bash
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /bin/bash Scripts/run-asr-critical-comparison.sh .build/models-large-v3 .build/benchmarks-critical-large-v3 baseline
python3 Scripts/compare-asr-models.py \
  Docs/Validation/2026-09-16/asr-critical-fixed/baseline \
  .build/benchmarks-critical-large-v3/baseline \
  .build/benchmarks-critical-large-v3/model-comparison.json
```

模型汇总器要求两组使用相同音频哈希、参考哈希、标签、管线版本和实时输入模式；每一组内部必须使用相同模型资源。单轨汇总排除双轨中的重复英语。

## 尚未完成

- **2026-09-16 晚更新（Kimi3）**：根因已定位为模型对 Daniel 合成音 `irreversible` 的声学错选，流式管线/窗口/装配器经解码轨迹与一次性解码探针排除嫌疑；前缀提示、温度采样、剪辑、较大模型均无效；10 种合成英语声音中仅 Daniel 出错（全语速），其余 9 种正确。用户本人核听后定级为**声学边界样本**（`ir-` 对人耳也含糊），不再作为清晰语音误识别的强证据，保留为困难对照；产品风险转为“含糊音频上输出满置信度、无不确定信号”。详见 [一次性解码探针与语音覆盖](ASR_CRITICAL_PROBE_2026-09-16.md)。仍待：替代引擎比较、真实口音材料。
- 默认模型在 Daniel 样例中的关键术语误识别仍未解决；本轮完整 large-v3 压缩模型也出现相同错误，仍需人工核听源音频并使用代表性实际口音材料验证。
- 未将合成开发样例称为人工审核保留集；没有改变参考文字来消除错误。
- 未完成真实医学会议质量、端到端回答延迟及 90 分钟稳定性验收。现有数量与声音覆盖不足以给出具有代表性的医学 ASR 通过阈值。
