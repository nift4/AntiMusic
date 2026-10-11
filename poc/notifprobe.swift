// notifprobe — listens for MediaRemote now-playing notifications (legacy AntiMusic handoff path)
// and reports whether they still fire on this macOS. Run it, then in another terminal start/stop
// a fake player (poc/fakeplayer) or play music in any app.
// Usage: notifprobe [seconds]  (default 20)
import Foundation
import Cocoa

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
typealias RegFn = @convention(c) (DispatchQueue) -> Void
if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
    let reg = unsafeBitCast(p, to: RegFn.self)
    reg(DispatchQueue.main)
    print("registered for MR notifications"); fflush(stdout)
} else {
    print("MRMediaRemoteRegisterForNowPlayingNotifications missing")
}

let names = [
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
]
for n in names {
    NotificationCenter.default.addObserver(forName: NSNotification.Name(n), object: nil, queue: nil) { note in
        print("GOT NSNotification: \(n) userInfo=\(note.userInfo ?? [:])"); fflush(stdout)
    }
    DistributedNotificationCenter.default.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { note in
        print("GOT DistributedNotification: \(n) userInfo=\(note.userInfo ?? [:])"); fflush(stdout)
    }
}
let secondsDefault: Double = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 20 : 20
print("listening \(Int(secondsDefault))s...") ; fflush(stdout)
let end = Date().addingTimeInterval(secondsDefault)
while Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    fflush(stdout)
}
print("done")
fflush(stdout)
