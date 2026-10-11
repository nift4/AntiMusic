// sendcmd — sends a media command to the current now-playing app via MRMediaRemoteSendCommand.
// Simulates what rcd does when a media key is pressed; no TCC needed. Used by the test harness
// to drive the fake player / AntiMusic without a physical key press.
// Usage: sendcmd [play|pause|toggle|next|previous]   (default play)
import Foundation

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt, AnyObject?) -> Void

guard let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
    print("ERR: MRMediaRemoteSendCommand symbol missing"); exit(3)
}
let send = unsafeBitCast(p, to: MRMediaRemoteSendCommandFunction.self)

// kMRSendCommand constants (reverse-engineered, widely reproduced):
// 0=Play 1=Pause 2=TogglePlayPause 3=Stop 4=NextTrack 5=PreviousTrack
let map: [String: UInt] = ["play": 0, "pause": 1, "toggle": 2, "next": 4, "previous": 5]
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "play"
guard let cmd = map[arg] else { print("usage: sendcmd [play|pause|toggle|next|previous]"); exit(2) }
send(cmd, nil)
print("sent \(arg) (\(cmd))")
