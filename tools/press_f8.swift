// press_f8 — 模拟一次真实的媒体键按下/抬起（广播到 HID 层，rcd 会像收到实体按键一样处理）。
// 这是自动化 E2E 测试的“虚拟手指”：需要宿主进程有「辅助功能」权限。
// 用法: press_f8 [play|next|previous|fast|rewind]   默认 play
// 退出码: 0=已发送 2=环境错误 3=TCC权限不足
import Foundation
import CoreGraphics
import AppKit

guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
    print("RESULT: SKIPPED(no-accessibility-permission)")
    exit(3)
}

let map: [String: UInt32] = ["play": 16, "next": 17, "previous": 18, "fast": 19, "rewind": 20]
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "play"
guard let nxKey = map[arg] else { print("usage: press_f8 [play|next|previous|fast|rewind]"); exit(2) }

func post(_ down: Bool) -> Bool {
    let data1 = Int((nxKey << 16) | (down ? 0xa00 : 0xb00))
    guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                      modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 8, data1: data1, data2: -1),
          let cg = ev.cgEvent else { return false }
    cg.post(tap: .cghidEventTap)
    return true
}
guard post(true) else { print("RESULT: FAIL(post-failed)"); exit(1) }
usleep(30_000)
_ = post(false)
print("RESULT: OK(sent \(arg))")
exit(0)
