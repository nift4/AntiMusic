// fakeplayer — registers as a now-playing app with .playing state and stays alive N seconds.
// Purpose: probe whether MRMediaRemoteGetNowPlayingClient can observe a third-party player on this macOS.
// Usage: fakeplayer [seconds]   (default 20)
import Foundation
import MediaPlayer

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 20 : 20
MPNowPlayingInfoCenter.default().playbackState = .playing
MPNowPlayingInfoCenter.default().nowPlayingInfo = [
    MPMediaItemPropertyTitle: "fakeplayer-probe",
    MPMediaItemPropertyArtist: "AntiMusic-POC",
    MPNowPlayingInfoPropertyPlaybackRate: 1.0,
]
print("fakeplayer: registered .playing for \(seconds)s (pid \(getpid()))")
fflush(stdout)
// also accept commands to prove MPRemoteCommandCenter routing works for us
MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in
    print("fakeplayer: RECEIVED togglePlayPause command"); fflush(stdout); return .success
}
MPRemoteCommandCenter.shared().playCommand.addTarget { _ in
    print("fakeplayer: RECEIVED play command"); fflush(stdout); return .success
}
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    fflush(stdout)
}
print("fakeplayer: done")
fflush(stdout)
