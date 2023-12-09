# AntiMusic

AntiMusic allows you to change the music player used by "Media keys" and "Now Playing" in Control Center on your Mac. If you are annoyed because your headset keeps opening Apple Music or because you want to use another music player instead of Apple Music when nothing is active, this app is for you!

## Installation

Download, extract and move the .app to `/Applications`, then open it. It adds itself to auto-start automatically. To open the app settings, just open the app while it's already running. To quit the app, open the app settings, then press on the app name and quit in the menu bar - or press Cmd-Q.

## Features

- Change music player app used by Control Center "Now Playing" widget.
- Change music player app started by media keys.
- Disable starting music player app with media keys.
- Media keys and "Now Playing" work in player apps in any configuration.
- Full Apple Music compatibility.
- macOS 14.1 Sonoma support.

## How does it work?

This app displays a "fake" Music Player only while no other app is playing music. It uses private APIs to notice when another app starts playing Music and releases control over Media keys and Control Center, and when the music player is closing again, it reclaims Media keys and Control Center to avoid Apple Music being started.

## Caveats

- This uses a little bit of CPU every second while another app is playing music because the private APIs to notice when another app plays Music send every update to the app, including progression of position slider. However, when music is paused, CPU usage instantly returns to zero.
- The Control Center displays removed entries in "Now Playing", so if you open and expand it fast enough, you can see the fake player and real player at the same time. However, this cannot be observed during normal usage.
- The generated fake album cover that contains the app icon of your chosen music player does not have a transparent background, unlike the real cover generated by the Control Center. Colors are chosen on a best effort basis.
- The app should be launched before music players start playing music (to avoid overriding the real music player with a fake player), which can be achieved using auto-start.
- Only tested on macOS 14.1 Sonoma.

## Alternatives

- `launchctl unload -w /System/Library/LaunchAgents/com.apple.rcd.plist`
    - However, this disables media keys entirely (not just launching an app from media keys).
- [noTunes](https://github.com/tombonez/noTunes)
    - Similar to this app, it does use a tiny bit of CPU in the background, however, noTunes listens to application open events instead of music change events which might use slightly more energy.
    - Similar to this app, it supports opening an alternative music player app, but you have to use command line to configure it. Additionally, Control Center will still display the wrong icon and name ("Music.app" and Apple Music icon). However, noTunes supports opening a website as replacement, which this app does not support.
    - If you configure a replacement, it will be opened every time Apple Music would be opening, so you cannot use both a replacement and avoid your headset launching a music player when connecting. This also implies that the Control Center shortcut is useless if media key launching is disabled.
    - noTunes does not support usage with Apple Music. If you want to use Apple Music, you have to close the app or keep an additional menu bar item around for this.
    - Each time something (e.g. media keys) tries to start Apple Music (even if the request gets redirected), its dock icon will jump once.
 - [Music Decoy](https://github.com/FuzzyIdeas/MusicDecoy)
    - Music Decoy uses less energy because it does not do anything.
    - However, you cannot choose to launch an alternative app via media keys instead of disabling app launch via media keys.
    - Additionally, the Control Center shortcut to start a music player will not work when using this app.
    - Apple Music cannot be started if this app is running, and it is hard to stop the app manually, as it requires use of Activity Monitor or command line.
    - Third-party applications trying to access Apple Music may crash when talking with Music Decoy, for example VLC.
    - Each time something (e.g. media keys) tries to start Apple Music, its dock icon will jump once.
 - Uninstalling Apple Music
    - This requires disabling System Integrity Protection which causes a major decrease in security of your computer.
 
## Credits
[Music Decoy](https://github.com/FuzzyIdeas/MusicDecoy) for the app icon and inspiration
