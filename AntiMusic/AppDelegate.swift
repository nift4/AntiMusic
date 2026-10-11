//
// AppDelegate.swift
// AntiMusic
//
// 基于 nift4/AntiMusic 改造（2026）：
//  - 通道A：CGEventTap 直通拦截媒体键（主，MediaKeyTap）
//  - 通道B：fake player + MPRemoteCommandCenter（兜底/兼容旧系统，原版机制）
//  - 唤醒链：启动目标 App → 就绪 → 注入（P1 主推）→ CoreAudio 验证出声 → 交棒
//  - 兼容：macOS < 15.4 且 MediaRemote 读取可用时，保留原版“检测他人播放→释放”逻辑
//

import Foundation
import Cocoa
import MediaPlayer

typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
typealias MRNowPlayingClientGetBundleIdentifierFunction = @convention(c) (AnyObject?) -> String
typealias MRMediaRemoteGetNowPlayingClientFunction = @convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void

@MainActor public class AppDelegate: NSObject, NSApplicationDelegate {

    private let MRMediaRemoteGetNowPlayingClient: MRMediaRemoteGetNowPlayingClientFunction?
    private let MRMediaRemoteRegisterForNowPlayingNotifications: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private let MRNowPlayingClientGetBundleIdentifier: MRNowPlayingClientGetBundleIdentifierFunction?
    private var active = false
    // Note: without title specified, we do not get to expanded Now Playing sheet.
    private var fakePlayer: [String : Any] = [MPMediaItemPropertyTitle: "<AntiMusic.app>"]

    // Legacy MediaRemote 读取是否可用（启动时自探测；macOS 27 实测为 false）
    private var mediaRemoteReadWorks = false
    private var legacyNotificationObserver: NSObjectProtocol?

    // 新架构组件
    var engine: WakeEngine!
    var config = WakeConfig.load()
    let statusMenu = StatusMenuController()
    var settingsWindow: SettingsWindowController?

    public override init() {
        let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
        var getClient: MRMediaRemoteGetNowPlayingClientFunction?
        var clientBundleId: MRNowPlayingClientGetBundleIdentifierFunction?
        var register: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString) {
            getClient = unsafeBitCast(p, to: MRMediaRemoteGetNowPlayingClientFunction.self)
        }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString) {
            clientBundleId = unsafeBitCast(p, to: MRNowPlayingClientGetBundleIdentifierFunction.self)
        }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            register = unsafeBitCast(p, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }
        MRMediaRemoteGetNowPlayingClient = getClient
        MRNowPlayingClientGetBundleIdentifier = clientBundleId
        MRMediaRemoteRegisterForNowPlayingNotifications = register
        super.init()

        // NSApp.setActivationPolicy(NSApplication.ActivationPolicy.accessory) <-- this is set in Info.plist, no need to set here
        // Hack to "activate" media player as something that can show up in "Now Playing" (only needs to be done once)
        MPNowPlayingInfoCenter.default().playbackState = .playing
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        // Add command listeners（通道B）
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                self.engine?.handleMediaKeyRequest(source: "command-center:toggle")
            }
            return .success
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { _ in
            DispatchQueue.main.async {
                self.engine?.handleMediaKeyRequest(source: "command-center:play")
            }
            return .success
        }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { _ in return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { _ in return .success }

        refreshFakePlayerMetadata()
        refreshNowPlaying()
        DistributedNotificationCenter.default.addObserver(self, selector: #selector(interfaceModeChanged(sender:)), name: NSNotification.Name(rawValue: "AppleInterfaceThemeChangedNotification"), object: nil)
        probeLegacyMediaRemote()
    }

    /// 兼容旧 XIB 设置窗口（ViewController）的读写入口
    var playerApp: String {
        get { config.playerAppPath }
        set {
            config.playerAppPath = newValue
            config.save()
            engine?.reload(config: config)
            refreshFakePlayerMetadata()
            if engine?.machine.state != .handedOff { refreshNowPlaying() }
        }
    }
    var ignoreMediaKey: Bool {
        get { config.ignoreMediaKey }
        set {
            config.ignoreMediaKey = newValue
            config.save()
            engine?.reload(config: config)
        }
    }

    func writeSettings() {
        config.save()
        engine?.reload(config: config)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let launchController = LaunchAtLoginController()
        launchController.launchAtLogin = true

        engine = WakeEngine(config: config)
        engine.onStateChange = { [weak self] state in
            self?.statusMenu.updateState(state)
        }
        engine.onNotice = { [weak self] message, critical in
            self?.postUserNotice(message, critical: critical)
        }
        engine.onHandoff = { [weak self] in
            self?.releaseFakePlayer()
        }
        engine.onReclaim = { [weak self] in
            self?.reassertFakePlayer()
        }
        engine.watchTargetTermination()
        let tapActive = engine.startEventTap()
        WakeLog.shared.info("launch done. bundleID=\(config.targetBundleID ?? "?") tap=\(tapActive) legacyMediaRemote=\(mediaRemoteReadWorks) \(PermissionsChecker.summary)")

        // 测试/自动化远程触发通道（免 TCC）：
        //   trigger_wake（tools/）通过 DistributedNotificationCenter + Darwin 通知投递
        //   notify_post("org.nift4.AntiMusic.Wake")        触发一次完整唤醒流程
        //   notify_post("org.nift4.AntiMusic.TestInject")  等价菜单栏「测试注入」
        // 闭环测试架构（tests/acceptance.sh、tune_params.sh）依赖此通道驱动 App，
        // 从而只要求 App 本身持有权限，而不要求运行测试的终端有任何授权。
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.nift4.AntiMusic.Wake"), object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.engine?.handleMediaKeyRequest(source: "remote-trigger") }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.nift4.AntiMusic.TestInject"), object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.engine?.testInjectNow() }
        }
        // Darwin 通知中心（notify_post）的桥接监听：回调是 C 指针，经 Unmanaged 转回实例
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(darwinCenter, observerPtr, { _, observer, name, _, _ in
            guard let observer = observer, let rawName = name?.rawValue as String? else { return }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                switch rawName {
                case "org.nift4.AntiMusic.Wake":
                    appDelegate.engine?.handleMediaKeyRequest(source: "remote-trigger-darwin")
                case "org.nift4.AntiMusic.TestInject":
                    appDelegate.engine?.testInjectNow()
                default: break
                }
            }
        }, "org.nift4.AntiMusic.Wake" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(darwinCenter, observerPtr, { _, observer, name, _, _ in
            guard let observer = observer, let rawName = name?.rawValue as String? else { return }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                if rawName == "org.nift4.AntiMusic.TestInject" {
                    appDelegate.engine?.testInjectNow()
                }
            }
        }, "org.nift4.AntiMusic.TestInject" as CFString, nil, .deliverImmediately)

        statusMenu.engine = engine
        statusMenu.onOpenSettings = { [weak self] in self?.openSettings() }
        statusMenu.onQuit = { NSApp.terminate(nil) }
        statusMenu.install()

        if !tapActive {
            // 无 tap 时提示一次权限（不阻塞；fake player 已兜底防 Apple Music）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                PermissionsChecker.promptIfNeeded(window: nil)
            }
        }
    }

    // MARK: - Fake player (通道B / rcd 占位)

    func refreshFakePlayerMetadata() {
        fakePlayer[MPMediaItemPropertyTitle] = playerAppName
        if #available(macOS 10.13.2, *) {
            let targetSize = CGSize(width: 1024, height: 1024)
            let miniSize = CGSize(width: targetSize.width / 2, height: targetSize.height / 2)
            fakePlayer[MPMediaItemPropertyArtwork] = MPMediaItemArtwork.init(boundsSize: targetSize, requestHandler: {_ in
                let rep = NSWorkspace.shared.icon(forFile: self.config.playerAppPath).bestRepresentation(for: NSRect(x: 0, y: 0, width: miniSize.width, height: miniSize.height), context: nil, hints: nil)!
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
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled = true
        MPRemoteCommandCenter.shared().playCommand.isEnabled = true
    }

    private func releaseFakePlayer() {
        // 交棒：清 now playing、禁用命令（若 tap 在拦截，命令本就不会来）
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled = false
        MPRemoteCommandCenter.shared().playCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func reassertFakePlayer() {
        refreshNowPlaying()
    }

    private var playerAppName: String {
        config.playerAppPath.split(separator: "/").last.map(String.init) ?? "<AntiMusic.app>"
    }

    // MARK: - Legacy MediaRemote（仅旧 macOS 生效）

    /// 启动自探测：注册 fake player 后查询，若能读回自己的 bundle id，说明读取 API 可用 → 保留原版释放逻辑。
    private func probeLegacyMediaRemote() {
        guard let getClient = MRMediaRemoteGetNowPlayingClient,
              let clientBundleId = MRNowPlayingClientGetBundleIdentifier else { return }
        let sem = DispatchSemaphore(value: 0)
        var bid = ""
        // 注意：回调不能落在 main 队列（此处跑在 main 线程上，会等不到回调）
        getClient(DispatchQueue.global()) { client in
            bid = clientBundleId(client)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
        mediaRemoteReadWorks = (bid == Bundle.main.bundleIdentifier)
        WakeLog.shared.info("legacy mediaRemote probe: read='\(bid)' works=\(mediaRemoteReadWorks)")
        if mediaRemoteReadWorks {
            legacyNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"), object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.loadSongInfo() }
            }
            MRMediaRemoteRegisterForNowPlayingNotifications?(DispatchQueue.main)
            loadSongInfo()
        }
    }

    /// 原版逻辑：有其他 App 在播放时隐藏 fake player 并禁用命令（仅 mediaRemoteReadWorks 时启用）。
    private func loadSongInfo() {
        guard let getClient = MRMediaRemoteGetNowPlayingClient,
              let clientBundleId = MRNowPlayingClientGetBundleIdentifier else { return }
        getClient(DispatchQueue.main, { [weak self] (client) in
            guard let self = self else { return }
            if (clientBundleId(client) != Bundle.main.bundleIdentifier) {
                self.releaseFakePlayer()
            } else {
                self.refreshNowPlaying()
            }
        })
    }

    // MARK: - UI

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (active) { return false }
        active = true
        NSApp.setActivationPolicy(NSApplication.ActivationPolicy.regular)
        NSApp.activate(ignoringOtherApps: true)
        OperationQueue.main.addOperation {
            NSMenu.setMenuBarVisible(false)
            OperationQueue.main.addOperation {
                NSMenu.setMenuBarVisible(true)
            }
        }
        openSettings()
        return false
    }

    public func applicationDidResignActive(_ notification: Notification) {
        settingsWindow?.window?.close()
        NSApp.setActivationPolicy(NSApplication.ActivationPolicy.accessory)
        active = false
    }

    private func openSettings() {
        if settingsWindow == nil {
            let ctl = SettingsWindowController()
            ctl.onConfigChanged = { [weak self] config in
                self?.config = config
                self?.engine?.reload(config: config)
                self?.refreshFakePlayerMetadata()
                if self?.engine?.machine.state != .handedOff {
                    self?.refreshNowPlaying()
                }
            }
            ctl.onTestInject = { [weak self] in self?.engine?.testInjectNow() }
            ctl.onWakeNow = { [weak self] in self?.engine?.handleMediaKeyRequest(source: "settings-wake") }
            ctl.statusProvider = { [weak self] in
                guard let self = self else { return "" }
                return "当前状态：\(self.engine.machine.state.friendlyName)"
            }
            settingsWindow = ctl
        }
        settingsWindow?.showSettings()
    }

    private func postUserNotice(_ message: String, critical: Bool) {
        // 成功类通知只进日志（菜单栏已显示状态），避免每次交棒都弹模态框
        // 打扰用户、并阻塞主线程的分布式通知处理；仅错误用非阻塞浮窗提示。
        guard critical else { return }
        let alert = NSAlert()
        alert.messageText = "AntiMusic"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.layout()
        alert.window.center()
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func interfaceModeChanged(sender: NSNotification) {
        refreshFakePlayerMetadata()
        if engine?.machine.state != .handedOff {
            refreshNowPlaying()
        }
    }
}
