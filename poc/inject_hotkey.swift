// POC-P1: 模拟 QQ音乐全局快捷键（主推方案的实弹验证）
// 在 QQ音乐运行但暂停时，构造组合键事件投递，观察是否开始播放。
// 出声判定使用 CoreAudio 公开 API（poc/audioprobe.swift 已验证）。
//
// 用法: inject_hotkey [--pid PID] [--code 35] [--flags 180000] [--wait 3] [--variant broadcast|targeted-private|targeted-hid|auto]
//   --variant auto（默认）: 先 broadcast（实测定向投递不触发 QQ音乐全局热键处理器），
//                          失败再 targeted-private → targeted-hid
// 退出码: 0=注入后出声(成功) 1=注入后未出声 2=参数/环境错误 3=TCC权限不足
import Foundation
import CoreGraphics
import AppKit
import CoreAudio

func argValue(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func log(_ s: String) { FileHandle.standardError.write(("[inject_hotkey] \(s)\n").data(using: .utf8)!); fflush(stderr) }

// CoreAudio 出声判定（同 poc/audioprobe.swift，'piro' 查询，无需任何权限）
private let kProcessPID: AudioObjectPropertySelector = (0x70 << 24) | (0x70 << 16) | (0x69 << 8) | 0x64        // 'ppid'
private let kIsRunningOutput: AudioObjectPropertySelector = (0x70 << 24) | (0x69 << 16) | (0x72 << 8) | 0x6F   // 'piro'
private let kPID2Process: AudioObjectPropertySelector = (0x69 << 24) | (0x64 << 16) | (0x32 << 8) | 0x70       // 'id2p'
private func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
private func getData<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, as: T.Type) -> T? {
    var a = addr(sel)
    var value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    defer { value.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, value) == noErr else { return nil }
    return value.load(as: T.self)
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
    return (getData(objectID, kIsRunningOutput, as: UInt32.self) ?? 0) != 0
}

// TCC 门控：无辅助功能权限时 postToPid 的事件会被系统静默丢弃（结果必然假阴性）
guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
    print("RESULT: SKIPPED(no-accessibility-permission)")
    print("GUIDE: 给运行本工具的宿主 App 授予「辅助功能」权限后重测（系统设置→隐私与安全性→辅助功能）")
    exit(3)
}

let targetBundleID = argValue("--bundle") ?? "com.tencent.QQMusicMac"
var pid: pid_t = 0
if let p = argValue("--pid") {
    pid = pid_t(p) ?? 0
} else {
    pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == targetBundleID }?.processIdentifier ?? 0
}
guard pid != 0 else { print("RESULT: FAIL(target-not-running)"); exit(2) }
log("target pid=\(pid)")

let keyCode = CGKeyCode(argValue("--code").flatMap { UInt16($0) } ?? 35)
let flagsRaw = argValue("--flags").flatMap { UInt64($0, radix: 16) } ?? 0x180000 // ⌘⌥
let waitSeconds = Double(argValue("--wait") ?? "3") ?? 3
let variant = argValue("--variant") ?? "auto"

// 前置检查：套件编排下（先 ax_toggle --set paused）目标应已暂停；
// --force 跳过前置检查（由调用方负责状态编排）
let force = CommandLine.arguments.contains("--force")
if !force && isOutputRunning(pid) {
    print("RESULT: FAIL(target-already-playing)")
    exit(2)
}

// 投递变体
func postHotkey(_ kind: String) -> Bool {
    let flags = CGEventFlags(rawValue: flagsRaw)
    func make(_ down: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let ev = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
        ev.flags = flags
        return ev
    }
    guard let down = make(true), let up = make(false) else { return false }
    if kind == "broadcast" {
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    } else {
        down.postToPid(pid)
        usleep(20_000)
        up.postToPid(pid)
    }
    log("posted via \(kind)")
    return true
}

let plan: [String]
switch variant {
case "broadcast": plan = ["broadcast"]
case "targeted-private": plan = ["targeted-private"]
case "targeted-hid": plan = ["targeted-hid"]
default: plan = ["broadcast", "targeted-private", "targeted-hid"]
}

var postedKind: String?
for kind in plan {
    if postHotkey(kind) { postedKind = kind; break }
}
guard postedKind != nil else { print("RESULT: FAIL(post-failed)"); exit(1) }

let deadline = Date().addingTimeInterval(waitSeconds)
var playing = false
while Date() < deadline {
    if isOutputRunning(pid) { playing = true; break }
    usleep(200_000)
}
print("RESULT: \(playing ? "PASS(injection-verified-playing via \(postedKind!))" : "FAIL(injected-but-not-playing via \(postedKind!))")")
if !playing {
    print("DIAG: 若各变体均失败，依次检查：①QQ音乐设置里的全局快捷键是否绑定为同一组合键 ②QQ音乐本体是否已授予「输入监控」 ③组合键是否与其他 App 冲突")
}
exit(playing ? 0 : 1)
