//
// Injector.swift
// AntiMusic
//
// 注入链（需求 §3.5 主推 + §4 候选，逐级降级）：
//   P1 模拟 QQ音乐全局快捷键（postToPid 定向投递，主推）
//   P0 定向 post 系统媒体键事件给 QQ音乐进程
//   P2 qqmusicmac:// URL scheme（实测仅能拉起，兜底启动）
//   P3 Accessibility 点击播放按钮（最后兜底）
//
// 注意：inject(...) 返回值只表示“投递动作已发出”，是否真正开始播放
// 由 WakeEngine 用 AudioActivityMonitor 验证（需求：不要用返回值冒充成功）。
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// 虚拟键码（HID Usage / IOHIDFamily 公开常量）
let kAMKeyANSI_P: CGKeyCode = 35          // kVK_ANSI_P
let kAMNXKeyTypePlay: UInt32 = 16         // NX_KEYTYPE_PLAY
let kAMNXKeyTypeNext: UInt32 = 17
let kAMNXKeyTypePrevious: UInt32 = 18
let kAMNXKeyTypeFast: UInt32 = 19
let kAMNXKeyTypeRewind: UInt32 = 20

enum InjectionMethod: String, CaseIterable {
    case hotkey = "P1-hotkey"
    case mediaKey = "P0-mediakey"
    case urlScheme = "P2-urlscheme"
    case axPress = "P3-axpress"

    static func from(chainCode: String) -> InjectionMethod? {
        switch chainCode {
        case "P1": return .hotkey
        case "P0": return .mediaKey
        case "P2": return .urlScheme
        case "P3": return .axPress
        default: return nil
        }
    }
}

/// P1 的三种投递变体。实测（macOS 27 + QQ音乐 11.10.0）：
/// 定向投递（targeted*）posted 但 QQ 音乐不响应——其全局热键处理器收不到
/// 定向合成事件；broadcast 把组合键广播进系统事件流，可触发
/// Carbon RegisterEventHotKey / 全局事件监听型热键。
enum HotkeyVariant: String {
    case targetedPrivate = "targeted-privateState"
    case targetedHid = "targeted-hidSystemState"
    case broadcast = "broadcast-hid"
}

final class Injector {
    var config: WakeConfig
    /// 诊断日志回调（供菜单栏“测试注入”展示 / 测试报告采集）
    var diagnostics: ((String) -> Void)?

    init(config: WakeConfig) {
        self.config = config
    }

    private func log(_ s: String) {
        WakeLog.shared.info("Injector: \(s)")
        diagnostics?(s)
    }

    /// 投递一次播放指令。返回 false 表示该手段在当前条件下不可用（未投递）。
    func inject(_ method: InjectionMethod, targetPID: pid_t) -> Bool {
        switch method {
        case .hotkey:
            return injectHotkey(pid: targetPID, variant: .targetedPrivate)
        case .mediaKey:
            return injectMediaKey(pid: targetPID)
        case .urlScheme:
            return injectURLScheme()
        case .axPress:
            return axPressPlay(pid: targetPID)
        }
    }

    // MARK: - P1 模拟全局快捷键（主推）

    /// 按指定变体投递组合键（需求 3.5.3(b)：定向优先；3.5.4 风险点1：合成源可能被忽略 → 广播降级）。
    func injectHotkey(pid: pid_t, variant: HotkeyVariant) -> Bool {
        let ok: Bool
        switch variant {
        case .targetedPrivate:
            ok = postHotkey(pid, sourceState: .privateState)
        case .targetedHid:
            ok = postHotkey(pid, sourceState: .hidSystemState)
        case .broadcast:
            ok = postHotkeyBroadcast()
        }
        log(ok ? "P1 hotkey posted to pid \(pid) via \(variant.rawValue)" : "P1 hotkey(\(variant.rawValue)): could not create/post CGEvent")
        return ok
    }

    private func postHotkey(_ pid: pid_t, sourceState: CGEventSourceStateID) -> Bool {
        let flags = CGEventFlags(rawValue: config.hotkeyFlags)
        let keyCode = config.hotkeyKeyCode
        guard let source = CGEventSource(stateID: sourceState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        usleep(20_000) // 20ms 键程，给目标 App 足够的识别窗口
        up.postToPid(pid)
        return true
    }

    /// 广播变体：组合键进入系统事件流（HID 层），QQ 音乐的全局热键
    /// （Carbon/全局监听实现）由此触发。副作用：其他监听同名组合键的 App 也会收到。
    private func postHotkeyBroadcast() -> Bool {
        let flags = CGEventFlags(rawValue: config.hotkeyFlags)
        let keyCode = config.hotkeyKeyCode
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - P0 定向媒体键

    /// 构造 NX systemDefined(subtype=8) 媒体键事件，定向投递给目标进程。
    func injectMediaKey(pid: pid_t, nxKey: UInt32 = kAMNXKeyTypePlay) -> Bool {
        func post(down: Bool) -> Bool {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((nxKey << 16) | (down ? 0xa00 : 0xb00))
            guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                              location: .zero,
                                              modifierFlags: flags,
                                              timestamp: 0,
                                              windowNumber: 0,
                                              context: nil,
                                              subtype: 8,
                                              data1: data1,
                                              data2: -1),
                  let cg = ev.cgEvent else { return false }
            cg.postToPid(pid)
            return true
        }
        guard post(down: true) else {
            log("P0 mediaKey: event creation failed")
            return false
        }
        usleep(20_000)
        let ok = post(down: false)
        log(ok ? "P0 mediaKey posted to pid \(pid)" : "P0 mediaKey: event creation failed")
        return ok
    }

    /// P0 的“activate + 广播”降级路径（默认关闭；会短暂抢焦点，且必须配合内部触发屏蔽）。
    func injectMediaKeyBroadcast(pid: pid_t) -> Bool {
        guard config.enableP0Broadcast else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let previous = NSWorkspace.shared.frontmostApplication
        app.activate()
        usleep(150_000)
        var success = false
        if let cg = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: Int((kAMNXKeyTypePlay << 16) | 0xa00), data2: -1)?.cgEvent {
            cg.post(tap: .cghidEventTap)   // 广播：可能被 rcd 分回本程序 → 引擎侧 settleWindow 屏蔽自触发
            usleep(20_000)
            if let cgUp = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: Int((kAMNXKeyTypePlay << 16) | 0xb00), data2: -1)?.cgEvent {
                cgUp.post(tap: .cghidEventTap)
            }
            success = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            previous?.activate()
        }
        log("P0 broadcast posted (frontmost switched temporarily)")
        return success
    }

    // MARK: - P2 URL scheme

    /// 实测（docs/FEASIBILITY.md #8）：qqmusicmac:// 能拉起 QQ音乐；未观察到可靠触发播放。
    /// 作为兜底“启动”手段，而不是可靠播放手段。
    func injectURLScheme() -> Bool {
        let urls = [
            "qqmusicmac://qq.com/media/playRadio?p={\"radioId\":\"199\",\"action\":\"play\",\"cache\":\"1\"}",
            "qqmusicmac://today?mid=31&k1=2&k4=0",
        ]
        for u in urls {
            if let url = URL(string: u), NSWorkspace.shared.open(url) {
                log("P2 urlScheme opened: \(u)")
                return true
            }
        }
        log("P2 urlScheme: no handler accepted the URL")
        return false
    }

    // MARK: - P3 AX 点击播放按钮（兜底）

    // MARK: - P3 AX 点击播放控制（兜底）

    /// 实测（QQ音乐 11.10.0）：菜单栏有「播放控制」菜单（暂停/上一首/下一首…）。
    /// 点击其中 暂停/播放 项即可 toggle；菜单标题同时是播放状态的瞬时判据
    /// （“暂停”=在播，“播放”=已暂停）。
    func axTogglePlayPause(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var menubarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
              let menubar = menubarRef as! AXUIElement? else {
            log("P3: no menubar"); return false
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menubar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let menuBarItems = childrenRef as? [AXUIElement] else { log("P3: no menus"); return false }
        for barItem in menuBarItems {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXTitleAttribute as CFString, &t) == .success,
                  let barTitle = t as? String else { continue }
            let isPlayMenu = barTitle.contains("播放控制") || barTitle.contains("控制")
                || barTitle.lowercased().contains("playback") || barTitle.lowercased().contains("control")
            guard isPlayMenu else { continue }
            var subRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let menus = subRef as? [AXUIElement] else { continue }
            for menu in menus {
                var itemRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemRef) == .success,
                      let items = itemRef as? [AXUIElement] else { continue }
                for item in items {
                    var it: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &it) == .success,
                          let itemTitle = it as? String, !itemTitle.isEmpty else { continue }
                    let isToggle = itemTitle.contains("暂停") || itemTitle == "播放" || itemTitle.contains("播放/暂停")
                        || itemTitle.lowercased().contains("pause") || itemTitle.lowercased() == "play"
                    guard isToggle else { continue }
                    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    log("P3 axToggle: pressed '\(barTitle)' → '\(itemTitle)' err=\(err.rawValue)")
                    return err == .success
                }
            }
        }
        log("P3: play/pause menu item not found")
        return false
    }

    /// AX 读取播放状态（菜单 toggle 项标题）。返回 nil = 菜单不可读（或非 QQ音乐类结构）。
    func axReadPlaying(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        var menubarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
              let menubar = menubarRef as! AXUIElement? else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menubar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let menuBarItems = childrenRef as? [AXUIElement] else { return nil }
        for barItem in menuBarItems {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXTitleAttribute as CFString, &t) == .success,
                  let barTitle = t as? String, barTitle.contains("播放控制") else { continue }
            var subRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let menus = subRef as? [AXUIElement] else { continue }
            for menu in menus {
                var itemRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemRef) == .success,
                      let items = itemRef as? [AXUIElement] else { continue }
                for item in items {
                    var it: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &it) == .success,
                          let itemTitle = it as? String, !itemTitle.isEmpty else { continue }
                    if itemTitle.contains("暂停") { return true }
                    if itemTitle == "播放" { return false }
                }
            }
        }
        return nil
    }

    func axPressPlay(pid: pid_t) -> Bool {
        // 优先菜单项（实测有效），失败再遍历窗口按钮
        if axTogglePlayPause(pid: pid) {
            return true
        }
        if pressWindowButton(app: AXUIElementCreateApplication(pid)) {
            return true
        }
        log("P3: no play control found (UI 改版或未取得辅助功能权限)")
        return false
    }

    private func pressWindowButton(app: AXUIElement) -> Bool {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            if pressButtonRecursive(window, depth: 0) { return true }
        }
        return false
    }

    private func axTitle(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let t = value as? String else { return nil }
        return t
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        return children
    }

    private func pressButtonRecursive(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 6, let children = axChildren(element) else { return false }
        for child in children {
            var roleRef: CFTypeRef?
            var isButton = false
            var role = ""
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               let r = roleRef as? String {
                role = r
                isButton = (r == kAXButtonRole)
            }
            if isButton, let t = axTitle(child) {
                if t.contains("播放") || t.lowercased().contains("play") {
                    if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success { return true }
                }
            }
            if pressButtonRecursive(child, depth: depth + 1) { return true }
        }
        return false
    }
}
