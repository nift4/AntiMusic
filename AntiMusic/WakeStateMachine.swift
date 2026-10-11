//
// WakeStateMachine.swift
// AntiMusic
//
// 唤醒流程状态机（需求 5.1）。纯 Foundation 逻辑、无 AppKit 依赖，
// 可独立编译跑单元测试（tests/StateMachineTests.swift）。
//
//  Idle       : 目标 App 未播放，本程序持有媒体键
//  Launching  : 已发出启动命令，轮询等待进程出现（超时 launchTimeout 判失败）
//  Ready      : 进程存在但未播放，等待播放器内核就绪（readyDelay）
//  Injecting  : 正在构造并定向投递注入事件
//  HandedOff  : 目标 App 已出声，控制权已释放，程序不再干预
//

import Foundation

public enum WakeState: String, Codable {
    case idle = "Idle"
    case launching = "Launching"
    case ready = "Ready"
    case injecting = "Injecting"
    case handedOff = "HandedOff"

    /// 面向普通用户的中文状态名（设置窗口状态行用）
    public var friendlyName: String {
        switch self {
        case .idle: return "空闲"
        case .launching: return "正在启动播放器"
        case .ready: return "播放器就绪"
        case .injecting: return "正在发送播放指令"
        case .handedOff: return "播放中"
        }
    }
}

public enum InjectionDecision {
    case retry
    case handoff
    case giveUp
}

public final class WakeStateMachine {
    public private(set) var state: WakeState = .idle
    public private(set) var attempts: Int = 0
    public private(set) var pid: pid_t = 0

    /// injectRetry × 注入链长度 = 总尝试预算
    public let maxAttempts: Int
    public var onTransition: ((WakeState, WakeState) -> Void)?
    /// 状态不可用原因（诊断/测试断言用）
    public private(set) var lastRejectReason: String?

    public init(injectRetry: Int, chainLength: Int) {
        self.maxAttempts = max(1, injectRetry) * max(1, chainLength)
    }

    public var isBusy: Bool { state != .idle && state != .handedOff }

    private func transition(to newState: WakeState) {
        guard newState != state else { return }
        let old = state
        state = newState
        onTransition?(old, newState)
    }

    /// Idle → Launching。已在唤醒流程中时拒绝（需求 5.2：同一时刻只允许一个唤醒流程）。
    @discardableResult
    public func beginWake() -> Bool {
        guard state == .idle || state == .handedOff else {
            lastRejectReason = "wake already in progress (\(state.rawValue))"
            return false
        }
        attempts = 0
        pid = 0
        lastRejectReason = nil
        transition(to: .launching)
        return true
    }

    /// Launching → Ready（进程出现并拿到 PID）
    public func processFound(_ pid: pid_t) {
        guard state == .launching else {
            lastRejectReason = "processFound ignored in state \(state.rawValue)"
            return
        }
        self.pid = pid
        lastRejectReason = nil
        transition(to: .ready)
    }

    /// Launching → Idle（启动超时/失败）
    public func launchFailed() {
        guard state == .launching else { return }
        lastRejectReason = nil
        transition(to: .idle)
    }

    /// Ready → Injecting
    public func beginInject() {
        guard state == .ready else {
            lastRejectReason = "beginInject ignored in state \(state.rawValue)"
            return
        }
        lastRejectReason = nil
        transition(to: .injecting)
    }

    /// Injecting 内部：每次注入尝试的结果评估。
    /// 成功 → HandedOff；失败且预算未用尽 → retry（保持 Injecting）；预算用尽 → giveUp（→ Idle）。
    @discardableResult
    public func evaluateInjection(ok: Bool) -> InjectionDecision {
        guard state == .injecting else { return ok ? .handoff : .retry }
        if ok {
            lastRejectReason = nil
            transition(to: .handedOff)
            return .handoff
        }
        attempts += 1
        if attempts >= maxAttempts {
            transition(to: .idle)
            return .giveUp
        }
        return .retry
    }

    /// 注入预算用尽后的显式放弃（giveUp 时已回 Idle，此函数兼容外部调用）。
    public func giveUp() {
        guard state == .injecting else {
            if state == .idle { return }
            transition(to: .idle)
            return
        }
        transition(to: .idle)
    }

    /// HandedOff → Idle（目标 App 退出，媒体键回收）。其余状态忽略。
    public func handoffLost() {
        guard state == .handedOff else { return }
        pid = 0
        transition(to: .idle)
    }

    /// 任意状态复位到 Idle（测试/异常恢复用）。
    public func reset() {
        attempts = 0
        pid = 0
        transition(to: .idle)
    }
}
