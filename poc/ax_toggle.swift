// ax_toggle — 通过 Accessibility API 操作 QQ音乐的「播放控制」菜单（P3 兜底 + 测试原语）。
// 用法: ax_toggle [--pid PID] [--bundle com.tencent.QQMusicMac] [--wait 3] [--set paused|playing] [--observe playing|paused]
//   默认：toggle 一次并验证状态翻转
//   --set paused|playing：确保目标处于指定状态（已在则无操作），供测试套件编排
//   --observe playing|paused：纯观察等待状态达成（不按键）——注入验证专用
// 退出码: 0=达到目标状态 1=操作/等待失败 2=环境错误 3=TCC权限不足
//
// 实测发现（QQ音乐 11.10.0，macOS 27）：
//   • 菜单栏「播放控制」菜单的 toggle 项标题是播放状态的瞬时判据（“暂停”=在播，“播放”=已暂停）
//   • CoreAudio 输出流在暂停后滞后归零（保持静音输出一段时间），不能单独作为暂停判据，
//     但“开始播放”方向（0→1）即时有效
import Foundation
import AppKit
import ApplicationServices
import CoreAudio

func argValue(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func log(_ s: String) { FileHandle.standardError.write(("[ax_toggle] \(s)\n").data(using: .utf8)!); fflush(stderr) }

// CoreAudio 出声判定
private let kPID2Process: AudioObjectPropertySelector = (0x69 << 24) | (0x64 << 16) | (0x32 << 8) | 0x70
private let kIsRunningOutput: AudioObjectPropertySelector = (0x70 << 24) | (0x69 << 16) | (0x72 << 8) | 0x6F
private func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
private func isOutputRunning(_ pid: pid_t) -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var p = pid
    var a = addr(kPID2Process)
    var objectID = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafeMutablePointer(to: &p) { ptr in
        AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), ptr, &size, &objectID)
    }
    guard st == noErr, objectID != 0, objectID != kAudioObjectUnknown else { return false }
    var a2 = addr(kIsRunningOutput)
    var v: UInt32 = 0
    var s2 = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &a2, 0, nil, &s2, &v) == noErr else { return false }
    return v != 0
}

guard AXIsProcessTrusted() else {
    print("RESULT: SKIPPED(no-accessibility-permission)")
    print("GUIDE: 给宿主 App 授予「辅助功能」权限后重测")
    exit(3)
}

let bundleID = argValue("--bundle") ?? "com.tencent.QQMusicMac"
let pid: pid_t
if let p = argValue("--pid") { pid = pid_t(p) ?? 0 }
else { pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.processIdentifier ?? 0 }
guard pid != 0 else { print("RESULT: FAIL(target-not-running)"); exit(2) }

let app = AXUIElementCreateApplication(pid)

func axTitle(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
          let t = value as? String else { return nil }
    return t
}
func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return nil }
    return children
}
// 「播放控制」菜单的 toggle 项标题
func axMenuItemTitle() -> String? {
    var menubarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
          let menubar = menubarRef as! AXUIElement? else { return nil }
    guard let menuBarItems = axChildren(menubar) else { return nil }
    for barItem in menuBarItems {
        guard let barTitle = axTitle(barItem), barTitle.contains("播放控制") else { continue }
        guard let menus = axChildren(barItem) else { return nil }
        for menu in menus {
            guard let items = axChildren(menu) else { return nil }
            for item in items {
                guard let itemTitle = axTitle(item), !itemTitle.isEmpty else { continue }
                if itemTitle.contains("暂停") || itemTitle == "播放" { return itemTitle }
            }
        }
    }
    return nil
}
// 点击「播放控制」菜单中的 暂停/播放 项（menu bar item → menu → items 三层）
func pressPlayPauseMenuItem() -> Bool {
    var menubarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
          let menubar = menubarRef as! AXUIElement? else { log("no menubar"); return false }
    guard let menuBarItems = axChildren(menubar) else { log("no menus"); return false }
    for barItem in menuBarItems {
        guard let barTitle = axTitle(barItem), barTitle.contains("播放控制") else { continue }
        guard let menus = axChildren(barItem) else { continue }
        for menu in menus {
            guard let items = axChildren(menu) else { continue }
            for item in items {
                guard let itemTitle = axTitle(item), !itemTitle.isEmpty else { continue }
                let isToggle = itemTitle.contains("暂停") || itemTitle == "播放" || itemTitle.contains("播放/暂停")
                    || itemTitle.lowercased().contains("pause") || itemTitle.lowercased() == "play"
                guard isToggle else { continue }
                let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                log("pressed menu '\(barTitle)' → '\(itemTitle)' err=\(err.rawValue)")
                return err == .success
            }
        }
    }
    log("no play/pause menu item found")
    return false
}

let waitSeconds = Double(argValue("--wait") ?? "3") ?? 3
let setMode = argValue("--set")?.lowercased()          // "paused" | "playing"
let observeMode = argValue("--observe")?.lowercased()  // "paused" | "playing"（纯观察，不按键）
let wantPlaying: Bool?
switch setMode ?? observeMode {
case "paused": wantPlaying = false
case "playing": wantPlaying = true
default: wantPlaying = nil   // toggle 模式
}

// --observe 模式：不按键，纯等待状态达成（注入验证专用）
if observeMode != nil {
    let deadline = Date().addingTimeInterval(waitSeconds)
    while Date() < deadline {
        if let t = axMenuItemTitle() {
            if t.contains("暂停") == (wantPlaying == true) {
                print("RESULT: PASS(observed-\(observeMode!))"); exit(0)
            }
        } else if isOutputRunning(pid) == (wantPlaying == true) {
            print("RESULT: PASS(observed-\(observeMode!))"); exit(0)
        }
        usleep(200_000)
    }
    print("RESULT: FAIL(observe-timeout waiting for \(observeMode!))")
    exit(1)
}

// 状态基线在点击前从 AX 菜单标题读取（瞬时、无歧义）
let baselineTitle = axMenuItemTitle()
let wasPlaying: Bool
if let t = baselineTitle {
    wasPlaying = t.contains("暂停")
    log("baseline menu title: '\(t)' → wasPlaying=\(wasPlaying)")
} else {
    wasPlaying = isOutputRunning(pid)
    log("menu unreadable, CoreAudio baseline wasPlaying=\(wasPlaying)")
}

// --set 模式：已处于目标状态则直接通过
if let want = wantPlaying, wasPlaying == want {
    print("RESULT: PASS(already-\(setMode!))")
    exit(0)
}

if !pressPlayPauseMenuItem() {
    print("RESULT: FAIL(ax-press-failed)")
    exit(1)
}

var toggled = false
let deadline = Date().addingTimeInterval(waitSeconds)
while Date() < deadline {
    if let t = axMenuItemTitle() {
        let playing = t.contains("暂停")
        if let want = wantPlaying {
            if playing == want { toggled = true; break }
        } else if playing != wasPlaying {
            toggled = true; break
        }
    } else if isOutputRunning(pid) != wasPlaying {
        toggled = true; break
    }
    usleep(200_000)
}
let direction = setMode.map { "set-\($0)" } ?? (wasPlaying ? "toggle playing→paused" : "toggle paused→playing")
print("RESULT: \(toggled ? "PASS(ax-toggle-verified \(direction))" : "FAIL(pressed-but-no-state-change)")")
exit(toggled ? 0 : 1)
