//
// StateMachineTests.swift
// AntiMusic
//
// WakeStateMachine 纯逻辑单元测试。独立编译运行（无需 Xcode test target / 无需硬件）：
//   swiftc AntiMusic/WakeStateMachine.swift tests/StateMachineTests.swift -o /tmp/smt && /tmp/smt
// CI（GitHub Actions）跑的就是这条命令。
//

import Foundation

var passed = 0
var failed = 0
var failures: [String] = []

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        failures.append("\(label): expected \(expected), got \(actual) (line \(line))")
        print("  ✗ \(label): expected \(expected), got \(actual)")
    }
}

func assertTrue(_ cond: Bool, _ label: String, line: UInt = #line) {
    assertEqual(cond, true, label, line: line)
}

func testCase(_ name: String, _ body: () -> Void) {
    print("● \(name)")
    body()
}

// MARK: - 场景1 冷启动成功路径
testCase("cold start success: idle→launching→ready→injecting→handedOff") {
    let m = WakeStateMachine(injectRetry: 2, chainLength: 4)
    assertTrue(m.state == .idle, "starts idle")
    assertTrue(m.beginWake(), "beginWake accepted")
    assertTrue(m.state == .launching, "→ launching")
    m.processFound(1234)
    assertTrue(m.state == .ready && m.pid == 1234, "→ ready with pid")
    m.beginInject()
    assertTrue(m.state == .injecting, "→ injecting")
    let d = m.evaluateInjection(ok: true)
    assertEqual(d, .handoff, "first injection verified → handoff")
    assertTrue(m.state == .handedOff, "→ handedOff")
}

// MARK: - 场景2 重试预算（budget = injectRetry × 注入链长度）
testCase("retry budget semantics") {
    let m = WakeStateMachine(injectRetry: 2, chainLength: 4)
    m.beginWake(); m.processFound(1); m.beginInject()
    for _ in 0..<7 { assertEqual(m.evaluateInjection(ok: false), .retry, "attempts 1..7 retry (budget 8)") }
    assertEqual(m.evaluateInjection(ok: false), .giveUp, "attempt 8 → giveUp")
    let m3 = WakeStateMachine(injectRetry: 2, chainLength: 1)
    m3.beginWake(); m3.processFound(1); m3.beginInject()
    assertEqual(m3.evaluateInjection(ok: false), .retry, "budget=2 fail#1 retry")
    assertEqual(m3.evaluateInjection(ok: false), .giveUp, "budget=2 fail#2 giveUp")
}

// MARK: - 场景3 并发请求拒绝（需求 5.2 isWaking）
testCase("concurrent wake request rejected while busy") {
    let m = WakeStateMachine(injectRetry: 2, chainLength: 4)
    assertTrue(m.beginWake(), "first beginWake ok")
    assertTrue(!m.beginWake(), "second beginWake rejected")
    assertEqual(m.lastRejectReason?.contains("already in progress"), true, "reject reason present")
    m.processFound(7); m.beginInject()
    assertTrue(!m.beginWake(), "beginWake rejected while injecting")
    m.evaluateInjection(ok: true)
    assertTrue(m.beginWake(), "beginWake ok again after handoff")
}

// MARK: - 场景4 启动超时回 Idle
testCase("launch timeout returns to idle") {
    let m = WakeStateMachine(injectRetry: 2, chainLength: 4)
    m.beginWake()
    m.launchFailed()
    assertTrue(m.state == .idle, "back to idle on launch failure")
    assertTrue(!m.isBusy, "not busy")
}

// MARK: - 场景5 交棒丢失（目标退出）→ Idle → 可再次唤醒
testCase("handoff lost re-arms wake") {
    let m = WakeStateMachine(injectRetry: 1, chainLength: 2)
    m.beginWake(); m.processFound(9); m.beginInject(); m.evaluateInjection(ok: true)
    assertTrue(m.state == .handedOff, "handed off")
    m.handoffLost()
    assertTrue(m.state == .idle, "reclaimed to idle")
    assertTrue(m.pid == 0, "pid cleared")
    assertTrue(m.beginWake(), "can wake again")
}

// MARK: - 场景6 非法迁移被忽略（状态机防御性）
testCase("invalid transitions are ignored") {
    let m = WakeStateMachine(injectRetry: 1, chainLength: 1)
    m.processFound(5)      // 未 beginWake，忽略
    assertTrue(m.state == .idle, "processFound ignored in idle")
    m.beginInject()        // 未 ready，忽略
    assertTrue(m.state == .idle, "beginInject ignored in idle")
    m.handoffLost()        // 非 handedOff，忽略
    assertTrue(m.state == .idle, "handoffLost ignored in idle")
}

// MARK: - 场景7 reset 从任意状态复位
testCase("reset from any state") {
    let m = WakeStateMachine(injectRetry: 2, chainLength: 4)
    m.beginWake(); m.processFound(2); m.beginInject(); m.evaluateInjection(ok: false)
    m.reset()
    assertTrue(m.state == .idle && !m.isBusy, "reset to idle")
    assertEqual(m.attempts, 0, "attempts cleared")
}

// MARK: - 场景8 需求5.1 状态语义完整性
testCase("state machine matches spec §5.1 semantics") {
    // Launching → Ready 由进程出现触发（轮询 NSWorkspace，超时 5s 判失败）
    // Ready → Injecting 等待 readyDelay 后触发
    // Injecting → HandedOff 投递后检测到播放
    // 冷启动与已运行共用 Injecting 路径：直接 processFound + beginInject
    let cold = WakeStateMachine(injectRetry: 2, chainLength: 4)
    cold.beginWake(); cold.processFound(11); cold.beginInject()
    assertEqual(cold.state, .injecting, "cold start reaches injecting")
    let warm = WakeStateMachine(injectRetry: 2, chainLength: 4)
    warm.beginWake(); warm.processFound(12); warm.beginInject()
    assertEqual(warm.state, .injecting, "warm start (already running) same path")
}

print("\n──────────────────────────────")
print("PASSED: \(passed)  FAILED: \(failed)")
if failed > 0 {
    print("Failures:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
exit(0)
