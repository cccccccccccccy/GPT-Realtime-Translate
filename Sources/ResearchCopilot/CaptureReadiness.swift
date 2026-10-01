import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum CaptureFailure: Error, LocalizedError, Equatable {
    case screenPermission, microphonePermission, microphoneUnavailable, sourceUnavailable, displayUnavailable
    case system(operation: String, code: Int?)

    var errorDescription: String? {
        switch self {
        case .screenPermission:
            "尚未允许本应用录屏与系统录音。请在系统设置 → 隐私与安全性 → 录屏与系统录音中开启 ResearchCopilot，按系统提示重新打开应用，然后刷新音源。软件按你选择的 Zoom 应用筛选音频。"
        case .microphonePermission:
            "本人麦克风未获授权。可以关闭“记录我的发言”，继续只捕获 Zoom；需要本人发言时再到系统设置开启麦克风权限。"
        case .microphoneUnavailable:
            "本人麦克风不可用或正在切换。请检查系统输入设备后重试，也可关闭“记录我的发言”继续只捕获 Zoom。"
        case .sourceUnavailable:
            "所选 Zoom 音源已退出或发生变化。请打开 Zoom，刷新并重新选择音源；未扩大到整个系统。"
        case .displayUnavailable:
            "当前没有可用显示器，无法建立 Zoom 音频过滤。请解锁或连接显示器后重试。"
        case .system(let operation, let code):
            "\(operation)未完成" + (code.map { "（系统错误码 \($0)）" } ?? "") + "。请重试；若持续出现，请重新打开应用。"
        }
    }

    static func classify(_ error: any Error, operation: String) -> CaptureFailure {
        if let known = error as? CaptureFailure { return known }
        let platform = error as NSError
        guard platform.domain == SCStreamErrorDomain else { return .system(operation: operation, code: nil) }
        switch platform.code {
        case SCStreamError.userDeclined.rawValue: return .screenPermission
        case SCStreamError.noCaptureSource.rawValue,
             SCStreamError.failedNoMatchingApplicationContext.rawValue: return .sourceUnavailable
        case SCStreamError.noDisplayList.rawValue: return .displayUnavailable
        default: return .system(operation: operation, code: platform.code)
        }
    }
}

struct CapturePermissionStatus {
    let screenGranted: Bool
    let microphone: AVAuthorizationStatus
    static func read() -> Self {
        .init(screenGranted: CGPreflightScreenCaptureAccess(), microphone: AVCaptureDevice.authorizationStatus(for: .audio))
    }
    var text: String {
        let mic: String
        switch microphone {
        case .authorized: mic = "已允许"
        case .denied, .restricted: mic = "未允许（关闭本人轨时不需要）"
        default: mic = "未请求（关闭本人轨时不需要）"
        }
        return "录屏与系统录音：\(screenGranted ? "已允许" : "未允许") · 本人麦克风：\(mic)"
    }
}
