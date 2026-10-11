// npq — Now Playing Query: prints current now-playing client bundle id (and info if available).
// Used by POCs and the test harness to answer "is QQMusic playing right now?" without TCC.
// Exit codes: 0 = got a bundle id, 1 = no client/empty, 2 = timeout
import Foundation
import Cocoa

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
typealias MRMediaRemoteGetNowPlayingClientFunction = @convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void
typealias MRNowPlayingClientGetBundleIdentifierFunction = @convention(c) (AnyObject?) -> String
typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void

guard let p1 = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) else { print("ERR: MRMediaRemoteGetNowPlayingClient missing"); exit(3) }
guard let p2 = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString) else { print("ERR: MRNowPlayingClientGetBundleIdentifier missing"); exit(3) }
let getClient = unsafeBitCast(p1, to: MRMediaRemoteGetNowPlayingClientFunction.self)
let clientBundleId = unsafeBitCast(p2, to: MRNowPlayingClientGetBundleIdentifierFunction.self)
var getInfo: MRMediaRemoteGetNowPlayingInfoFunction? = nil
if let p3 = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
    getInfo = unsafeBitCast(p3, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
}

let sem = DispatchSemaphore(value: 0)
var bid = ""
getClient(DispatchQueue.global()) { client in
    bid = clientBundleId(client)
    sem.signal()
}
if sem.wait(timeout: .now() + 3) == .timedOut { print("TIMEOUT"); exit(2) }
print("bundleId: \(bid.isEmpty ? "(empty)" : bid)")

if let gf = getInfo {
    let sem2 = DispatchSemaphore(value: 0)
    var info: [String: Any] = [:]
    gf(DispatchQueue.global()) { dict in
        if let d = dict as? [String: Any] { info = d }
        sem2.signal()
    }
    if sem2.wait(timeout: .now() + 3) != .timedOut {
        if info.isEmpty {
            print("info: (empty — API may be restricted to third-party on this macOS)")
        } else {
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] ?? "?"
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] ?? "?"
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?? "?"
            print("info: title=\(title) artist=\(artist) rate=\(rate) keys=\(info.keys.count)")
        }
    }
}
exit(bid.isEmpty ? 1 : 0)
