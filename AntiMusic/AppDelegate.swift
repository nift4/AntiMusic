//
// AppDelegate.swift
// AntiMusic
//
// Created by nift4 on 08.12.2023.
//

import Foundation
import Cocoa
import MediaPlayer

typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
typealias MRNowPlayingClientGetBundleIdentifierFunction = @convention(c) (AnyObject?) -> String
typealias MRMediaRemoteGetNowPlayingClientFunction = @convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void

@MainActor public class AppDelegate: NSObject, NSApplicationDelegate {

    private let MRMediaRemoteGetNowPlayingClient: MRMediaRemoteGetNowPlayingClientFunction
    private let MRMediaRemoteRegisterForNowPlayingNotifications: MRMediaRemoteRegisterForNowPlayingNotificationsFunction
    private let MRNowPlayingClientGetBundleIdentifier: MRNowPlayingClientGetBundleIdentifierFunction
    private var active = false
    // Note: without title specified, we do not get to expanded Now Playing sheet.
    private var fakePlayer: [String : Any] = [MPMediaItemPropertyTitle: "<AntiMusic.app>"]
    // User-facing settings
    var ignoreMediaKey = false
    var playerApp = "/System/Applications/Music.app"

    public override init() {
        let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
        guard let MRMediaRemoteGetNowPlayingClientPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) else { fatalError("can't find MRMediaRemoteGetNowPlayingClient") }
        MRMediaRemoteGetNowPlayingClient = unsafeBitCast(MRMediaRemoteGetNowPlayingClientPointer, to: MRMediaRemoteGetNowPlayingClientFunction.self)
        guard let MRNowPlayingClientGetBundleIdentifierPointer = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString) else { fatalError("can't find MRNowPlayingClientGetBundleIdentifier") }
        MRNowPlayingClientGetBundleIdentifier = unsafeBitCast(MRNowPlayingClientGetBundleIdentifierPointer, to: MRNowPlayingClientGetBundleIdentifierFunction.self)
        guard let MRMediaRemoteRegisterForNowPlayingNotificationsPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) else { fatalError("can't find MRMediaRemoteRegisterForNowPlayingNotifications") }
        MRMediaRemoteRegisterForNowPlayingNotifications = unsafeBitCast(MRMediaRemoteRegisterForNowPlayingNotificationsPointer, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        super.init()

        // NSApp.setActivationPolicy(NSApplication.ActivationPolicy.accessory) <-- this is set in Info.plist, no need to set here
        // Hack to "activate" media player as something that can show up in "Now Playing" (only needs to be done once)
        MPNowPlayingInfoCenter.default().playbackState = .playing
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        // Add command listeners
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in
            // Launch by Media Key / Bluetooth
            DispatchQueue.main.async {
                self.handlePlay(false)
            }
            return .success
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { _ in
            // Launch with Play button in Control Center / Siri
            DispatchQueue.main.async {
                self.handlePlay(true)
            }
            return .success
        }
        // Listen for "Application changed" event to find if another app added/removed player
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"), object: nil, queue: nil) { [self] (notification) in
            DispatchQueue.main.async {
                self.loadSongInfo()
            }
        }
        MRMediaRemoteRegisterForNowPlayingNotifications(DispatchQueue.main)
        DistributedNotificationCenter.default.addObserver(self, selector: #selector(interfaceModeChanged(sender:)), name: NSNotification.Name(rawValue: "AppleInterfaceThemeChangedNotification"), object: nil)
        // Load settings
        ignoreMediaKey = UserDefaults.standard.bool(forKey: "org.nift4.AntiMusic.IgnoreMediaKey")
        playerApp = UserDefaults.standard.string(forKey: "org.nift4.AntiMusic.PlayerApp") ?? playerApp
        refreshFakePlayerMetadata()
        self.loadSongInfo()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Autostart me in the future
        let launchController = LaunchAtLoginController()
        launchController.launchAtLogin = true
    }

    // When user opens app even though it already is open
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (active) {
            return false
        }
        active = true
        // Allow showing in dock & menu bar...
        NSApp.setActivationPolicy(NSApplication.ActivationPolicy.regular)
        // ...and do it
        NSApp.activate(ignoringOtherApps: true)
        // Hacky fix for menu bar not showing
        OperationQueue.main.addOperation {
            NSMenu.setMenuBarVisible(false)
            OperationQueue.main.addOperation {
                NSMenu.setMenuBarVisible(true)
            }
        }
        // Show settings window
        let ctl = NSApp.windows.first?.contentView?.parentViewController as! ViewController
        ctl.delegate = self
        ctl.label.stringValue = playerApp
        ctl.checkbox.state = ignoreMediaKey ? .on : .off
        NSApp.windows.first?.center()
        NSApp.windows.first?.makeKeyAndOrderFront(NSApp)
        return false
    }

    public func applicationDidResignActive(_ notification: Notification) {
        // Hide settings window
        NSApp.windows.first?.close()
        // After the user moved on to do something else, hide dock icon again
        NSApp.setActivationPolicy(NSApplication.ActivationPolicy.accessory)
        active = false
    }

    private func handlePlay(_ fromCC: Bool) {
        if (ignoreMediaKey && !fromCC) {
            return
        }
        if #available(macOS 10.15, *) {
            let url = NSURL(fileURLWithPath: playerApp, isDirectory: true) as URL
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.launchApplication(playerApp)
        }
    }
    
    func refreshFakePlayerMetadata() {
        fakePlayer[MPMediaItemPropertyTitle] = playerApp.split(separator: "/").last
        if #available(macOS 10.13.2, *) {
            let targetSize = CGSize(width: 1024, height: 1024)
            let miniSize = CGSize(width: targetSize.width / 2, height: targetSize.height / 2)
            fakePlayer[MPMediaItemPropertyArtwork] = MPMediaItemArtwork.init(boundsSize: targetSize, requestHandler: {_ in
                let rep = NSWorkspace.shared.icon(forFile: self.playerApp).bestRepresentation(for: NSRect(x: 0, y: 0, width: miniSize.width, height: miniSize.height), context: nil, hints: nil)!
                let image = NSImage(size: rep.size)
                image.addRepresentation(rep)
                let newImage = NSImage(size: targetSize, flipped: false, drawingHandler: { rect in
                    let dark: Bool
                    if #available(macOS 10.14, *) {
                        dark = ([NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(NSApp.effectiveAppearance.name))
                    } else {
                        dark = false
                    }
                    (dark ? NSColor(srgbRed: 0.3529411765, green: 0.3529411765, blue: 0.3764705882, alpha: 1)
                     : NSColor(srgbRed: 0.8274509804, green: 0.8274509804, blue: 0.831372549, alpha: 1)).drawSwatch(in: rect)
                    image.draw(in: CGRect(origin: CGPoint(x: miniSize.width / 2, y: miniSize.height / 2), size: miniSize))
                    return true
                })
                return newImage
            })
        }
    }

    func refreshNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = fakePlayer
    }

    func writeSettings() {
        UserDefaults.standard.set(ignoreMediaKey, forKey: "org.nift4.AntiMusic.IgnoreMediaKey")
        UserDefaults.standard.set(playerApp, forKey: "org.nift4.AntiMusic.PlayerApp")
    }

    private func loadSongInfo() {
        // Check who is currently playing music
        MRMediaRemoteGetNowPlayingClient(DispatchQueue.main, { [self] (client) in
            // If there is a currently playing song and it's not our fake player, hide the fake player
            if (MRNowPlayingClientGetBundleIdentifier(client) != "org.nift4.AntiMusic") {
                // Needs to be in this order for player to instantly disappear
                // Please note: If user is in full-sheet Now Playing, fake player won't disappear until reopening full-sheet. This limitation doesn't seem to be fixable.
                MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled = false
                MPRemoteCommandCenter.shared().playCommand.isEnabled = false
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            } else {
                // If we are the only ones (*newest ones, but we autostart so we should be the oldest player at any given time), show our fake player with user's preffered music player as icon and name.
                refreshNowPlaying()
                MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled = true
                MPRemoteCommandCenter.shared().playCommand.isEnabled = true
            }
        })
    }

    @objc private func interfaceModeChanged(sender: NSNotification) {
        refreshFakePlayerMetadata()
        refreshNowPlaying()
    }
}
