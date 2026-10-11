// POC-0: Environment & capability audit
// Verifies on the CURRENT macOS whether every pillar of the design still works:
//   1. MediaRemote private APIs (MRMediaRemoteGetNowPlayingClient / MRNowPlayingClientGetBundleIdentifier)
//      -> foundation for "detect who is playing / hand off control"
//   2. Accessibility permission (CGEvent posting)
//   3. Input Monitoring / listen permission (event tap, and receiving synthetic hotkeys)
//   4. MPRemoteCommandCenter + MPNowPlayingInfoCenter (fake player registration)
// Usage: swiftc -o /tmp/envcheck poc/envcheck.swift && /tmp/envcheck

import Foundation
import Cocoa
import MediaPlayer

func header(_ s: String) { print("\n== \(s) ==") }

header("System")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("arch: \(ProcessInfo.processInfo.processorCount)v CPU")

header("TCC permissions (of this process)")
print("AXIsProcessTrusted (Accessibility): \(AXIsProcessTrusted())")
print("CGPreflightListenEventAccess (Input Monitoring): \(CGPreflightListenEventAccess())")
print("CGPreflightPostEventAccess (post events): \(CGPreflightPostEventAccess())")

header("MediaRemote private framework")
let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))

typealias MRMediaRemoteGetNowPlayingClientFunction = @convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void
typealias MRNowPlayingClientGetBundleIdentifierFunction = @convention(c) (AnyObject?) -> String
typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void

var mrGetClient: MRMediaRemoteGetNowPlayingClientFunction?
var mrClientBundleId: MRNowPlayingClientGetBundleIdentifierFunction?
var mrRegister: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?

if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) {
    mrGetClient = unsafeBitCast(p, to: MRMediaRemoteGetNowPlayingClientFunction.self)
    print("symbol MRMediaRemoteGetNowPlayingClient: FOUND")
} else {
    print("symbol MRMediaRemoteGetNowPlayingClient: MISSING")
}
if let p = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString) {
    mrClientBundleId = unsafeBitCast(p, to: MRNowPlayingClientGetBundleIdentifierFunction.self)
    print("symbol MRNowPlayingClientGetBundleIdentifier: FOUND")
} else {
    print("symbol MRNowPlayingClientGetBundleIdentifier: MISSING")
}
if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
    mrRegister = unsafeBitCast(p, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
    print("symbol MRMediaRemoteRegisterForNowPlayingNotifications: FOUND")
} else {
    print("symbol MRMediaRemoteRegisterForNowPlayingNotifications: MISSING")
}

// Live query: who is the current now-playing client?
if let f = mrGetClient {
    let sem = DispatchSemaphore(value: 0)
    var result = "TIMEOUT/EMPTY"
    f(DispatchQueue.global()) { client in
        if let f2 = mrClientBundleId {
            result = f2(client)
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 3)
    print("current now-playing bundle id: '\(result)'")
}

header("Fake player (MPMediaItem/MPRemoteCommandCenter)")
MPNowPlayingInfoCenter.default().playbackState = .playing
MPNowPlayingInfoCenter.default().playbackState = .stopped
MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "envcheck-probe"]
MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in
    print(">>> togglePlayPauseCommand RECEIVED (media keys currently routed to this process)")
    return .success
}
print("MPRemoteCommandCenter/MPNowPlayingInfoCenter: initialized OK (watch log for command reception)")

// Note: this process would only receive a real media key if rcd routes to it,
// which requires it to be the active now-playing app. We register briefly, then exit.
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
print("\nDONE")
