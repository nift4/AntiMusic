//
// WakeEngine.swift
// AntiMusic
//
// 唤醒编排器：把「拦截 → 判断 → 启动 → 就绪 → 注入 → 验证 → 交棒」串成完整链路（需求 §3.5.2 时序）。
// 验证判据 = CoreAudio 检测目标进程真实出声（AudioActivityMonitor），
// 不依赖任何已失效的 MediaRemote 读取接口。
//

import Foundation
import AppKit

final class WakeEngine {
    private(set) var config: WakeConfig
    let machine: WakeStateMachine
    let injector: Injector
    private var tap: MediaKeyTap?
    private(set) var tapActive = false

    // 需求 5.2 去抖/并发/静默
    private var lastRequestAt: Date?
    private var settleUntil: Date?
    private var suppressUntil: Date?
    static let debounceInterval: TimeInterval = 0.3

    var onStateChange: ((WakeState) -> Void)?
    var onNotice: ((String, Bool) -> Void)?
    /// 交棒/回收时回调 AppDelegate 维护 fake player
    var onHandoff: (() -> Void)?
    var onReclaim: (() -> Void)?

    private var terminateObserver: NSObjectProtocol?

    let queue = DispatchQueue(label: "org.nift4.AntiMusic.wake")

    init(config: WakeConfig) {
        self.config = config
        self.machine = WakeStateMachine(injectRetry: config.injectRetry, chainLength: max(1, config.enabledChain.count))
        self.injector = Injector(config: config)
        machine.onTransition = { [weak self] _, newState in
            WakeLog.shared.info("state → \(newState.rawValue)")
            DispatchQueue.main.async { self?.onStateChange?(newState) }
        }
    }

    // MARK: - Startup

    /// 启动通道A（EventTap）。返回 false 表示不可用（权限缺失/被禁用），调用方应保留通道B。
    func startEventTap() -> Bool {
        guard config.useEventTap else {
            WakeLog.shared.info("event tap disabled by config — using fake player channel only")
            return false
        }
        let perms = PermissionsChecker.check()
        guard perms.inputMonitoring, perms.accessibility else {
            WakeLog.shared.info("event tap skipped, permissions missing (\(PermissionsChecker.summary))")
            return false
        }
        let tap = MediaKeyTap { [weak self] keyCode, keyDown in
            guard let self = self else { return false }
            return self.handleTapEvent(keyCode: keyCode, keyDown: keyDown)
        }
        self.tap = tap
        tapActive = tap.start()
        return tapActive
    }

    func watchTargetTermination() {
        guard terminateObserver == nil else { return }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name(rawValue: "NSWorkspaceDidTerminateNotification"), object: nil, queue: nil
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.config.targetBundleID else { return }
            WakeLog.shared.info("target app quit — reclaiming media keys")
            self.queue.async { self.reclaim() }
        }
    }

    func reload(config: WakeConfig) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let oldTarget = self.config.playerAppPath
            self.config = config
            self.injector.config = config
            if oldTarget != config.playerAppPath {
                WakeLog.shared.info("target app changed → \(config.playerAppPath)")
                // 目标切换后重新评估放行状态
                self.syncPassthroughWithTarget()
            }
        }
    }

    // MARK: - Media key entry points

    /// 通道A 回调。返回 true = 吞掉事件（阻止 rcd 唤起 Apple Music）。
    func handleTapEvent(keyCode: UInt32, keyDown: Bool) -> Bool {
        let targetPID = runningPID()
        let targetPlaying = targetPID.map { isTargetPlaying($0) } ?? false
        if targetPlaying {
            // 交棒状态/目标已自行播放：放行，rcd 会路由给 QQ音乐
            return false
        }
        if !keyDown {
            // 未在播放，且拦截态：down/up 一起吞
            return true
        }
        handleMediaKeyRequest(source: "tap:\(keyCode)")
        return true
    }

    /// 通道B（MPRemoteCommandCenter）与菜单栏手动触发共用入口。
    func handleMediaKeyRequest(source: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            if let settle = self.settleUntil, now < settle {
                WakeLog.shared.info("request(\(source)) ignored: settle window")
                return
            }
            if let suppress = self.suppressUntil, now < suppress {
                WakeLog.shared.info("request(\(source)) ignored: internal trigger suppression")
                return
            }
            if let last = self.lastRequestAt, now.timeIntervalSince(last) < Self.debounceInterval {
                WakeLog.shared.info("request(\(source)) ignored: debounce")
                return
            }
            self.lastRequestAt = now
            if self.config.ignoreMediaKey && source.hasPrefix("tap") {
                WakeLog.shared.info("request(\(source)) ignored: IgnoreMediaKey setting")
                return
            }
            if self.machine.isBusy {
                WakeLog.shared.info("request(\(source)) ignored: \(self.machine.lastRejectReason ?? "busy")")
                return
            }
            self.wakeFlow(source: source)
        }
    }

    // MARK: - Wake flow (runs on engine queue; blocking sleeps allowed)

    private func wakeFlow(source: String) {
        guard machine.beginWake() else {
            WakeLog.shared.info("wake(\(source)) rejected: \(machine.lastRejectReason ?? "?")")
            return
        }
        // 目标已在出声：区分两种情况——
        //  a) 媒体键/命令源：rcd 把命令路由给了我们（macOS 27 上第三方 now-playing
        //     注册受限，交棒后 rcd 可能仍把 F8 给 fake player）→ 转发热键给目标，
        //     实现“播放中按 F8 = 暂停”的 toggle 语义，并用出声→静默验证。
        //  b) 远程触发/手动/测试源：测试工具探活，不动播放状态，直接复位。
        if let pid = runningPID(), isTargetPlaying(pid) {
            let mediaKeySource = source == "command-center:toggle" || source == "command-center:play"
                || source.hasPrefix("tap:")
            if mediaKeySource && config.enableForwardWhenPlaying {
                WakeLog.shared.info("wake(\(source)): target playing → forwarding play/pause toggle")
                machine.reset()
                var done = false
                // ① 热键广播（App 进程发布的合成事件实测可触发 QQ音乐全局热键）
                if injector.injectHotkey(pid: pid, variant: config.enableP1Broadcast ? .broadcast : .targetedPrivate) {
                    done = waitForToggle(pid, from: true, timeout: 3.0)
                }
                // ② AX 点击「播放控制」菜单（实测瞬时可靠）
                if !done {
                    injector.axTogglePlayPause(pid: pid)
                    done = waitForToggle(pid, from: true, timeout: 3.0)
                }
                WakeLog.shared.info("forward toggle result: paused=\(done)")
                settleUntil = Date().addingTimeInterval(config.settleWindow)
                return
            }
            WakeLog.shared.info("wake(\(source)) aborted: target already playing (no forward for this source)")
            machine.reset()
            completeHandoff(pid: pid)
            return
        }
        WakeLog.shared.info("wake flow started (source=\(source)) t0")
        let bundleID = config.targetBundleID
        guard let bundleID else {
            machine.launchFailed()
            notice("目标 App 路径无效：\(config.playerAppPath)", critical: true)
            return
        }

        // ③ 冷启动：未运行 → 启动 + 轮询等待进程（launchTimeout）
        var pid = runningPID()
        if pid == nil {
            launchTargetApp(path: config.playerAppPath)
            let deadline = Date().addingTimeInterval(config.launchTimeout)
            while Date() < deadline {
                if let p = runningPID() { pid = p; break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard let launched = pid else {
                machine.launchFailed()
                notice("等待 \(bundleID) 启动超时（launchTimeout=\(config.launchTimeout)s）", critical: true)
                return
            }
            WakeLog.shared.info("target launched, pid=\(launched)")
        }
        guard let targetPID = pid else { machine.launchFailed(); return }
        machine.processFound(targetPID)

        // ③ Ready：等待播放器内核就绪（readyDelay；分片睡眠以便随时复位）
        var waited: TimeInterval = 0
        while waited < config.readyDelay && machine.state == .ready {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        guard machine.state == .ready else { return }

        // ④ Injecting：注入链 × injectRetry，逐级降级
        machine.beginInject()
        let chain = config.enabledChain.compactMap(InjectionMethod.from)
        guard !chain.isEmpty else {
            machine.giveUp()
            notice("注入链为空：请至少启用一种注入方式", critical: true)
            return
        }
        let perms = PermissionsChecker.check()
        WakeLog.shared.info("injecting chain=\(chain.map { $0.rawValue }.joined(separator: ",")) perms=\(PermissionsChecker.summary)")

        var methodIdx = 0
        var perMethodAttempt = 0
        while methodIdx < chain.count && machine.state == .injecting {
            let method = chain[methodIdx]
            perMethodAttempt += 1
            let attemptNo = machine.attempts + 1
            WakeLog.shared.info("inject try#\(attemptNo) method=\(method.rawValue)")

            // P1 变体序列：广播优先（本机实测定向投递不触发 QQ音乐热键处理器，
            // 广播可触发 Carbon/全局监听型实现）；未启用广播时交替尝试两种定向源。
            var posted: Bool
            if method == .hotkey {
                let variant: HotkeyVariant
                if config.enableP1Broadcast {
                    let seq: [HotkeyVariant] = [.broadcast, .targetedPrivate, .targetedHid]
                    variant = seq[min(perMethodAttempt - 1, seq.count - 1)]
                } else {
                    variant = perMethodAttempt % 2 == 1 ? .targetedPrivate : .targetedHid
                }
                posted = injector.injectHotkey(pid: targetPID, variant: variant)
            } else {
                posted = injector.inject(method, targetPID: targetPID)
            }
            var verified = false
            if posted {
                verified = AudioActivityMonitor.waitUntilOutputting(
                    targetPID,
                    timeout: config.verifyTimeout,
                    shouldAbort: { [weak self] in self?.machine.state != .injecting }
                )
                WakeLog.shared.info("inject result: posted=\(posted) verifiedPlaying=\(verified)")
            } else {
                WakeLog.shared.info("inject result: not posted (method unavailable)")
            }
            // 广播注入可能被 rcd 分回本程序 → 短暂屏蔽自身事件（需求 5.2 isInternalTrigger）
            if method == .mediaKey && config.enableP0Broadcast {
                suppressUntil = Date().addingTimeInterval(config.settleWindow)
            }
            let decision = machine.evaluateInjection(ok: verified)
            switch decision {
            case .handoff:
                completeHandoff(pid: targetPID)
                notice("已交棒：\(config.playerAppPath.components(separatedBy: "/").last ?? "目标") 正在播放")
                return
            case .retry:
                if perMethodAttempt > config.injectRetry {
                    methodIdx += 1
                    perMethodAttempt = 0
                    WakeLog.shared.info("moving to next method (\(methodIdx + 1)/\(chain.count))")
                } else {
                    Thread.sleep(forTimeInterval: config.retryInterval)
                }
            case .giveUp:
                notice("唤醒失败：所有注入手段均已尝试（含重试 \(config.injectRetry) 次）。若使用 P1，请检查 QQ音乐的「输入监控」授权与全局快捷键设置。", critical: true)
                return
            }
        }
        machine.giveUp()
    }

    private func launchTargetApp(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                WakeLog.shared.info("openApplication error: \(error.localizedDescription)")
            }
        }
    }

    /// 轮询验证播放状态翻转（AX 菜单标题优先——CoreAudio 对暂停的检测滞后）。
    /// `from` 为转发前的状态；翻转到相反状态即成功。
    private func waitForToggle(_ pid: pid_t, from wasPlaying: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let playing = injector.axReadPlaying(pid: pid) {
                if playing != wasPlaying { return true }
            } else if !AudioActivityMonitor.isOutputRunning(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// 目标是否正在播放：AX 菜单标题（瞬时、无歧义）优先，CoreAudio 回退。
    /// 实测：QQ音乐暂停后 CoreAudio 输出流滞后归零，不能单独作为暂停判据。
    func isTargetPlaying(_ pid: pid_t) -> Bool {
        if let playing = injector.axReadPlaying(pid: pid) { return playing }
        return AudioActivityMonitor.isOutputRunning(pid)
    }

    // MARK: - Handoff / reclaim

    private func completeHandoff(pid: pid_t) {
        settleUntil = Date().addingTimeInterval(config.settleWindow)
        syncPassthroughWithTarget()
        DispatchQueue.main.async { self.onHandoff?() }
        WakeLog.shared.info("handoff complete pid=\(pid) settle=\(config.settleWindow)s")
    }

    /// 目标在出声 → 放行（tap 禁用，事件自然流向 rcd → QQ音乐）
    private func syncPassthroughWithTarget() {
        let pid = runningPID()
        let playing = pid.map { isTargetPlaying($0) } ?? false
        if playing {
            tap?.setPassthrough(true)
            tapActive = false
        } else {
            tap?.setPassthrough(false)
            tapActive = tap != nil
        }
    }

    private func reclaim() {
        machine.handoffLost()
        settleUntil = nil
        suppressUntil = nil
        tap?.setPassthrough(false)
        tapActive = tap != nil
        DispatchQueue.main.async { self.onReclaim?() }
    }

    // MARK: - Menu bar actions

    /// 「测试注入」：单独执行一次唤醒链（QQ音乐已运行但暂停时验证热键配置与权限，需求 §6#10）
    func testInjectNow() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.machine.isBusy {
                self.notice("唤醒流程进行中，稍后再试")
                return
            }
            self.machine.reset()
            self.wakeFlow(source: "test-inject")
        }
    }

    func checkPermissionsNow() {
        let perms = PermissionsChecker.check()
        DispatchQueue.main.async {
            PermissionsChecker.promptIfNeeded(window: nil)
        }
    }

    // MARK: - Helpers

    func runningPID() -> pid_t? {
        guard let bundleID = config.targetBundleID else { return nil }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .processIdentifier
    }

    private func notice(_ message: String, critical: Bool = false) {
        WakeLog.shared.info("notice: \(message)")
        DispatchQueue.main.async { self.onNotice?(message, critical) }
    }
}
