// trigger_wake — 远程触发 AntiMusic 的唤醒流程（免 TCC 权限）。
// 通过 DistributedNotificationCenter 投递（跨进程，LSUIElement App 可收）。
// 这是闭环测试架构的“自动化手指”：只要求 AntiMusic.app 本身持有权限，
// 测试终端无需任何授权。
// 用法: trigger_wake [wake|testinject]     默认 wake
// 退出码: 0=已投递
import Foundation

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "wake"
let name: String
switch arg {
case "wake": name = "org.nift4.AntiMusic.Wake"
case "testinject": name = "org.nift4.AntiMusic.TestInject"
default:
    FileHandle.standardError.write(("usage: trigger_wake [wake|testinject]\n").data(using: .utf8)!)
    exit(2)
}
DistributedNotificationCenter.default().post(
    name: Notification.Name(name), object: nil, userInfo: nil)
print("RESULT: OK(notified \(name))")
exit(0)
