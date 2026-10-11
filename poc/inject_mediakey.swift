// POC-P0: 定向 post 系统媒体键事件（NX systemDefined subtype 8）给 QQ音乐进程
// 用法: inject_mediakey [--pid PID] [--wait 5]
// 退出码: 0=成功出声 1=未出声 2=环境错误 3=TCC权限不足
import Foundation
import AppKit
import CoreAudio

func argValue(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func log(_ s: String) { FileHandle.standardError.write(("[inject_mediakey] \(s)\n").data(using: .utf8)!); fflush(stderr) }

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

// 定向投递需要辅助功能权限（post 事件）
guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
    print("RESULT: SKIPPED(no-accessibility-permission)")
    print("GUIDE: 给宿主 App 授予「辅助功能」权限后重测")
    exit(3)
}

let targetBundleID = argValue("--bundle") ?? "com.tencent.QQMusicMac"
let pid: pid_t
if let p = argValue("--pid") { pid = pid_t(p) ?? 0 }
else { pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == targetBundleID }?.processIdentifier ?? 0 }
guard pid != 0 else { print("RESULT: FAIL(target-not-running)"); exit(2) }
log("target pid=\(pid)")

let waitSeconds = Double(argValue("--wait") ?? "3") ?? 3
// 前置检查：套件编排下目标应已暂停；--force 跳过
let force = CommandLine.arguments.contains("--force")
if !force && isOutputRunning(pid) {
    print("RESULT: FAIL(target-already-playing)")
    exit(2)
}

let NX_KEYTYPE_PLAY: UInt32 = 16
func post(down: Bool) -> Bool {
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xa00 : 0xb00))
    guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                      modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 8, data1: data1, data2: -1),
          let cg = ev.cgEvent else { return false }
    cg.postToPid(pid)
    return true
}
guard post(down: true) else { print("RESULT: FAIL(post-failed)"); exit(1) }
usleep(20_000)
_ = post(down: false)
log("P0 media key posted to pid \(pid)")

let deadline = Date().addingTimeInterval(waitSeconds)
var playing = false
while Date() < deadline {
    if isOutputRunning(pid) { playing = true; break }
    usleep(200_000)
}
print("RESULT: \(playing ? "PASS(injection-verified-playing)" : "FAIL(injected-but-not-playing)")")
exit(playing ? 0 : 1)
