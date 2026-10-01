# 本地语音诊断材料

这些文本是专门构造的测试材料，不是用户真实课题事实，也不是实际会议记录。

- `timepoint.txt`、`necrosis.txt`：实施计划保留的两条专家问题。
- `numbers-negation.txt`：测试数字、单位及否定。数字仅为合成测试内容。
- `chinese.txt`：本人中文发言测试。
- `reversible-control.txt`、`irreversible-control.txt`：相反含义的开发对照，防止提示词把不同发言都偏向同一个术语。
- `necrosis-samantha.aiff`（生成文件）：`necrosis.txt` 的另一种合成声音版本；参考文字不变。
- `*-critical.json`：选定关键短语的字面保留检查，仅读入评测器，不传入识别模型。大小写和标点按 WER 规则归一化，要求连续完整词元；`irreversible` 不能满足 `reversible`，`130` 不能满足 `30`。短语出现不证明其否定范围、说话人归属或语义正确。
- `balanced-medical-hints.txt`：实验用短术语提示，包含可逆与不可逆两种词形，不包含参考句或期望结论。仅通过诊断命令显式启用；没有改变应用默认提示策略。

使用 macOS `say` 生成测试音频至 `.build/fixtures`。音频只作为开发用测试输入；应用仍不保存实际会议原始音频。

合成语音通常比真实会议清晰，不能替代不同口音、噪声、重叠发言或真实 Zoom 音源的质量验收。WER 以小写词元计算，保留词内连字符、撇号和小数点；不自动将拼写数字与阿拉伯数字视为等价。CER 忽略标点、空白与大小写。

## 关键短语对照

```bash
bash Scripts/create-asr-fixtures.sh
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /bin/bash Scripts/run-asr-critical-comparison.sh .build/models .build/benchmarks-critical
python3 Scripts/summarize-asr-comparison.py .build/benchmarks-critical
```

先编译诊断程序并准备缓存模型。生成音频和 Core ML 推理需正常访问 macOS 系统服务；如果沙箱产生零长度音频，脚本会拒绝继续。对照脚本运行两组各七次，包含六个单轨样例和一组中英双轨。两组使用完全相同的音频与参考文字；汇总器核对文件哈希、模型资源和标签一致性。单轨汇总不重复计入双轨中的英文。

对照脚本可用第三个参数 `baseline` 或 `balanced-hints` 只运行其中一组，默认 `all`。比较不同模型时可各运行 `baseline`，保持提示策略相同；原提示对照汇总器仍要求完整的两组结果。

也可以在单条 `CopilotDiagnostics transcribe` 命令中指定 `--critical-terms FILE` 和 `--hint-file FILE`。前者需要参考文字，并要求每条标签确实出现在参考中；后者与 `--use-glossary` 互斥。诊断报告记录输入文件哈希，`--decode-trace` 可额外保存模型逐词分数。这些分数未经正确率校准，不能作为重要事实可靠性的保证。

`checkedCriticalTerms` 缺失表示旧报告没有记录检查范围；空数组表示本次未检查。旧报告中 `missingCriticalTerms: []` 不能解释成所有医学术语、数字或否定均正确。数字样例目前选择 48 小时、30、not 13 和否定/验证短语；其他数值及单位仍需结合完整转写人工核对。关键短语检查没有覆盖全部医学语义，也不替代人工审核的保留测试集。
