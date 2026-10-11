//
// WakeConfig.swift
// AntiMusic
//
// 持久化配置：目标 App、全局热键组合、注入链开关、时序参数。
// 所有参数均有默认值； UserDefaults 键统一使用 org.nift4.AntiMusic.* 前缀。
//

import Foundation

private let configPrefix = "org.nift4.AntiMusic."

struct WakeConfig {
    // 目标播放器
    var playerAppPath: String = "/Applications/QQMusic.app"
    var hotkeyFlags: UInt64 = (1 << 20) | (1 << 19)        // CGEventFlags: .maskCommand | .maskAlternate  => ⌘⌥
    var hotkeyKeyCode: UInt16 = 35                         // kVK_ANSI_P

    // 时序参数（需求 3.5.3(d)）
    var launchTimeout: Double = 5.0      // 等待目标进程出现
    var readyDelay: Double = 1.5         // 进程出现后、注入前的最低等待
    var injectRetry: Int = 2             // 每种注入手段的重试次数
    var retryInterval: Double = 0.8      // 重试间隔
    var settleWindow: Double = 3.0       // 注入成功后的静默期
    var verifyTimeout: Double = 3.0      // 注入后等待“目标真正出声”的超时

    // 注入链（按优先级逐级降级；P1 为主推方案）
    var enableP1Hotkey: Bool = true      // 模拟 QQ音乐全局快捷键
    var enableP1Broadcast: Bool = true   // P1 广播降级（定向投递无效时把组合键广播进系统事件流）
    var enableP0MediaKey: Bool = true    // 定向 post 系统媒体键事件
    var enableP2URLScheme: Bool = true   // qqmusicmac:// URL scheme（实测可触发播放，兜底）
    var enableP3AXPress: Bool = true     // AX 点击播放按钮（最后兜底）
    var enableP0Broadcast: Bool = false  // P0 失败后是否允许“activate+广播”降级（会抢焦点，默认关）

    // 拦截通道
    var useEventTap: Bool = true         // 通道A：CGEventTap 直通拦截（需 输入监控+辅助功能）
    var ignoreMediaKey: Bool = false     // 沿用原 AntiMusic 设置：不响应媒体键
    var enableForwardWhenPlaying: Bool = true // 命令到达但目标在播时，转发热键实现 toggle（rcd 不路由给第三方时的兜底）

    var targetBundleID: String? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: playerAppPath)) else { return nil }
        return bundle.bundleIdentifier
    }

    var enabledChain: [String] {
        var chain: [String] = []
        if enableP1Hotkey { chain.append("P1") }
        if enableP0MediaKey { chain.append("P0") }
        if enableP2URLScheme { chain.append("P2") }
        if enableP3AXPress { chain.append("P3") }
        return chain
    }

    // MARK: Persistence


    static func load() -> WakeConfig {
        var c = WakeConfig()
        let d = UserDefaults.standard
        let player = d.string(forKey: configPrefix + "PlayerApp")
        if let player = player, FileManager.default.fileExists(atPath: player) {
            c.playerAppPath = player
        } else if !FileManager.default.fileExists(atPath: c.playerAppPath) {
            c.playerAppPath = "/System/Applications/Music.app"
        }
        c.hotkeyFlags = UInt64(d.double(forKey: configPrefix + "HotkeyFlags")) == 0
            ? c.hotkeyFlags : UInt64(d.double(forKey: configPrefix + "HotkeyFlags"))
        let kc = d.integer(forKey: configPrefix + "HotkeyKeycode")
        if kc > 0 { c.hotkeyKeyCode = UInt16(kc) }
        c.launchTimeout = readDouble(d, "LaunchTimeout", fallback: c.launchTimeout)
        c.readyDelay = readDouble(d, "ReadyDelay", fallback: c.readyDelay)
        c.injectRetry = Int(readDouble(d, "InjectRetry", fallback: Double(c.injectRetry)))
        c.retryInterval = readDouble(d, "RetryInterval", fallback: c.retryInterval)
        c.settleWindow = readDouble(d, "SettleWindow", fallback: c.settleWindow)
        c.verifyTimeout = readDouble(d, "VerifyTimeout", fallback: c.verifyTimeout)
        c.enableP1Hotkey = readBool(d, "EnableP1Hotkey", fallback: c.enableP1Hotkey)
        c.enableP1Broadcast = readBool(d, "EnableP1Broadcast", fallback: c.enableP1Broadcast)
        c.enableP0MediaKey = readBool(d, "EnableP0MediaKey", fallback: c.enableP0MediaKey)
        c.enableP2URLScheme = readBool(d, "EnableP2URLScheme", fallback: c.enableP2URLScheme)
        c.enableP3AXPress = readBool(d, "EnableP3AXPress", fallback: c.enableP3AXPress)
        c.enableP0Broadcast = d.bool(forKey: configPrefix + "EnableP0Broadcast")
        c.useEventTap = readBool(d, "UseEventTap", fallback: c.useEventTap)
        c.ignoreMediaKey = d.bool(forKey: configPrefix + "IgnoreMediaKey")
        c.enableForwardWhenPlaying = readBool(d, "EnableForwardWhenPlaying", fallback: c.enableForwardWhenPlaying)
        return c
    }

    func save() {
        let d = UserDefaults.standard
        d.set(playerAppPath, forKey: configPrefix + "PlayerApp")
        d.set(Double(hotkeyFlags), forKey: configPrefix + "HotkeyFlags")
        d.set(Int(hotkeyKeyCode), forKey: configPrefix + "HotkeyKeycode")
        d.set(launchTimeout, forKey: configPrefix + "LaunchTimeout")
        d.set(readyDelay, forKey: configPrefix + "ReadyDelay")
        d.set(Double(injectRetry), forKey: configPrefix + "InjectRetry")
        d.set(retryInterval, forKey: configPrefix + "RetryInterval")
        d.set(settleWindow, forKey: configPrefix + "SettleWindow")
        d.set(verifyTimeout, forKey: configPrefix + "VerifyTimeout")
        d.set(enableP1Hotkey, forKey: configPrefix + "EnableP1Hotkey")
        d.set(enableP1Broadcast, forKey: configPrefix + "EnableP1Broadcast")
        d.set(enableP0MediaKey, forKey: configPrefix + "EnableP0MediaKey")
        d.set(enableP2URLScheme, forKey: configPrefix + "EnableP2URLScheme")
        d.set(enableP3AXPress, forKey: configPrefix + "EnableP3AXPress")
        d.set(enableP0Broadcast, forKey: configPrefix + "EnableP0Broadcast")
        d.set(useEventTap, forKey: configPrefix + "UseEventTap")
        d.set(ignoreMediaKey, forKey: configPrefix + "IgnoreMediaKey")
        d.set(enableForwardWhenPlaying, forKey: configPrefix + "EnableForwardWhenPlaying")
    }

    private static func readDouble(_ d: UserDefaults, _ key: String, fallback: Double) -> Double {
        let v = d.double(forKey: configPrefix + key)
        return v > 0 ? v : fallback
    }
    private static func readBool(_ d: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        if d.object(forKey: configPrefix + key) == nil { return fallback }
        return d.bool(forKey: configPrefix + key)
    }
}
