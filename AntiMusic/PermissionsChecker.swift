//
// PermissionsChecker.swift
// AntiMusic
//
// TCC 权限自检与引导（需求 5.3）。
// 特别注意：主推方案 P1 要求 QQ音乐本体也拥有「输入监控」权限，否则它收不到
// 合成的全局快捷键。QQ音乐侧授权无法用 API 直接读取，只能在“测试注入”
// 失败时给出行为学诊断（见 Injector+WakeEngine 的诊断输出）。
//

import Foundation
import AppKit
import CoreGraphics

struct PermissionStatus {
    let accessibility: Bool      // 辅助功能：post CGEvent / AX 操作
    let inputMonitoring: Bool    // 输入监控：创建监听型 EventTap、发送合成键盘事件
    var postEvents: Bool { accessibility }
}

enum PermissionsChecker {
    static func check() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    static var summary: String {
        let s = check()
        return "Accessibility=\(s.accessibility ? "✓" : "✗") InputMonitoring=\(s.inputMonitoring ? "✓" : "✗")"
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 权限不足时弹窗引导。返回用户选择了“打开设置”与否。
    @discardableResult
    static func promptIfNeeded(window: NSWindow?) -> Bool {
        let s = check()
        if s.accessibility && s.inputMonitoring { return false }
        let alert = NSAlert()
        alert.messageText = "需要授权才能完成唤醒"
        var info = "AntiMusic 需要以下权限：\n"
        if !s.inputMonitoring {
            info += "\n• 输入监控 —— 拦截媒体键、发送合成播放指令"
        }
        if !s.accessibility {
            info += "\n• 辅助功能 —— 向 QQ音乐 定向投递播放指令"
        }
        info += "\n\n另外请在 系统设置→隐私与安全性→输入监控 中确认 QQ音乐 本体已勾选（否则它收不到全局快捷键，表现为“启动了但不出声”）。"
        alert.informativeText = info
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if let window = window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn { openInputMonitoringSettings() }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn { openInputMonitoringSettings() }
        }
        return true
    }
}
