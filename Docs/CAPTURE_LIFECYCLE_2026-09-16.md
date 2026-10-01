# 采集中断与启动取消验证

日期：2026-09-16。对应 v3 的睡眠、Zoom 退出、设备变化及停止边界。真实多人会议和 90 分钟验收仍未完成。

## 修复与行为

原有睡眠处理只检查“正在录制”，忽略了等待语音服务或系统捕获启动的阶段。因此，睡眠发生在“启动中”时，返回的异步操作仍可能开启采集。

现在睡眠会立即关闭音频转交入口，并记住启动取消。无论正在等待语音服务还是系统捕获，都要结束当前启动、停止和收尾；有中断信息的会议会保存结束时间和缺口。唤醒不会自动重启。停止尚未得到系统确认时，继续阻止新采集，保留重试入口。

只观察本次所选 Zoom 进程。它退出时，立即关闭音频转交、记录中断并停止；新进程需要刷新后手动选择。本人麦克风启用时，固定到启动时系统默认输入设备的唯一标识；监听设备断开与默认输入变化，发生变化则停止并提示确认设备。本人轨关闭后，不再因麦克风变化中断远端轨，也不注册新的麦克风监听。

音频门控只允许每个流发布一次终止中断，忽略主动停止后的迟到错误。控制器按采集批次过滤回调，旧流事件不能停止下一场会议。系统捕获在等待权限、读取音源和启动返回后均检查取消状态，不扩大到其他音源。

## 本轮真机发现的崩溃

初始实现通过 87 项回归后，原生检测在停止时仍发生崩溃。系统崩溃栈显示：`CaptureEnvironmentMonitor.deinit` 释放 `NSRunningApplication` 后，Swift KVO token 的清理再次调用其 `removeObserver`，触发 `EXC_BAD_ACCESS`。该轮不是通过结果。

修复采用独立观察器所有者，在被观察对象仍存活时显式 `invalidate`，然后释放 token。回调只做进程匹配和门控，不操作主线程界面；设备通知回调明确为可跨线程调用。增加原生 KVO 创建/释放 100 次的回归，并重新执行应用真机停止测试。

已检查 Apple 的 [NSRunningApplication.isTerminated 可观察属性](https://developer.apple.com/documentation/appkit/nsrunningapplication/isterminated)、[NSRunningApplication 的线程及生命周期说明](https://developer.apple.com/documentation/appkit/nsrunningapplication) 和 [Core Audio 属性监听接口](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))。麦克风设备标识遵循本机 SDK `SCStreamConfiguration.microphoneCaptureDeviceID` 的约定，即 `AVCaptureDevice.uniqueID`。

## 自动回归

`bash Scripts/test.sh`：88 项通过。本轮新增 8 项，覆盖：

- 只匹配所选进程、所选麦克风及实际默认输入变化。
- 中断只发布一次；本人轨关闭后忽略其迟到事件。
- 检测启动中睡眠，关闭转交并在启动返回后结束。
- 会议语音服务启动中睡眠，不启动系统音频。
- 系统音频启动中睡眠，不发布“正在录制”。
- 睡眠时保存缺口；停止失败仍阻止重启，重试成功后恢复。
- 旧采集回调不能影响新会议。
- 当前测试进程的原生 KVO 观察器反复创建和释放。

会议控制器通过可注入的语音启动器测试上述时序；测试替身不访问模型、Keychain、云端或真实音频。生产启动器仍使用原来的 WhisperKit / OpenAI 路径，不改变供应商或默认 ASR 策略。

## 原生应用验证

崩溃修复版二进制 SHA-256：`70c03209a996b49d9aa67842ccdbb41852c1ddf0bdc16e305b0e1776d7ad9184`。构建与严格签名验证通过；ad-hoc 更新后，在用户此前批准的同一范围内恢复录屏与系统录音权限，没有启用本人麦克风。

在空闲 Zoom 上运行数值音源检测，语音模型和云端文字均未启用，没有会议录音或语言转写：

| 场景 | 已观察的结果 | 原生导出 |
| --- | --- | --- |
| 手动停止 | 411 帧，约 8.2 秒，麦克风 0 帧，无异常，停止确认；副驾保持运行 | [正常停止](Validation/2026-09-16/zoom-audio/zoom-environment-manual-stop.json) |
| 退出所选 Zoom | 435 帧，约 8.7 秒，麦克风 0 帧，明确“所选 Zoom 已退出”，停止确认；副驾保持运行 | [Zoom 退出](Validation/2026-09-16/zoom-audio/zoom-environment-terminated.json) |
| 30 秒自动停止 | 1,502 帧，约 30.0 秒，麦克风 0 帧，无异常，停止确认；副驾保持运行 | [自动停止](Validation/2026-09-16/zoom-audio/zoom-environment-auto-stop.json) |

Zoom 退出后刷新列表，界面显示“请先打开 Zoom”；尝试检测时提示“请先刷新并选择 Zoom 音源”。重新打开 Zoom、刷新音源后，可再次手动启动检测，不自动接续旧捕获。这验证没有可选 Zoom 时的启动边界，不等于对其他应用声音隔离质量的完整验收。

最终已在普通应用中离线加载原有默认模型，主界面显示“本地模型已就绪”，并将空白转写区域提示改为确认音源后开始会议；保持空闲，麦克风和云端文字关闭。设置中的设备切换说明也已在原生界面确认。

## 仍待验证

- 实际睡眠/唤醒、蓝牙及 USB 麦克风切换/断开、真实权限撤销；本轮自动测试不能替代这些硬件场景。
- 真机系统停止失败后的恢复；自动回归覆盖了模拟失败。
- 其他应用声音排除、真实双轨与长期负载。
- 医学 ASR 关键错误、端到端回答质量与延迟、人工保留测试集和正式签名发布。

原始崩溃报告含系统标识，未复制到项目；验证目录仅保存必要的故障类型、相关调用栈及文件摘要。

[验证清单](Validation/2026-09-16/capture-lifecycle/verification.json) 记录源码、运行应用、原生导出和测试/构建日志的摘要；[初次失败的脱敏调用栈](Validation/2026-09-16/capture-lifecycle/initial-kvo-teardown-failure.json) 保留本轮未通过的证据。
