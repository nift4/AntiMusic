//
// SettingsWindowController.swift
// AntiMusic
//
// 程序化构建的设置窗口（避免改 XIB），面向普通用户分两页：
//  「通用」——选音乐播放器、录播放快捷键、看权限状态、立即播放；
//  「高级」——注入链开关与时序参数（白话命名，保留代号便于对照文档）。
//

import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onConfigChanged: ((WakeConfig) -> Void)?
    var onTestInject: (() -> Void)?
    var onWakeNow: (() -> Void)?
    var statusProvider: (() -> String)?

    private var config = WakeConfig.load()
    private var isRecordingHotkey = false
    private var hotkeyMonitor: Any?
    private var lastNotice = ""
    private var noticeClearTimer: Timer?

    // 通用页
    private let appIconView = NSImageView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let hotkeyDisplay = NSTextField(labelWithString: "")
    private let hotkeyButton = NSButton(title: "录制", target: nil, action: nil)
    private let permInputStatus = NSTextField(labelWithString: "")
    private let permAXStatus = NSTextField(labelWithString: "")
    private let permButton = NSButton(title: "检查权限", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    // 高级页
    private var paramFields: [String: NSTextField] = [:]
    private var chainBoxes: [String: NSButton] = [:]

    private var pageGeneral: NSView!
    private var pageAdvanced: NSView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "AntiMusic 设置"
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
        // 状态/权限实时刷新（窗口可见时每秒一次；只刷新状态行，不动输入中的参数框）
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.refreshStatus()
        }
    }

    func showSettings() {
        config = WakeConfig.load()
        lastNotice = ""
        refreshFields()
        fitWindowToPage()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let segmented = NSSegmentedControl(
            labels: ["通用", "高级"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(segmentChanged(_:)))
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(segmented)

        let pages = NSView()
        pages.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pages)

        pageGeneral = makeGeneralPage()
        pageAdvanced = makeAdvancedPage()
        pages.addSubview(pageGeneral)
        pages.addSubview(pageAdvanced)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            segmented.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pages.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 16),
            pages.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            pages.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            pageGeneral.topAnchor.constraint(equalTo: pages.topAnchor),
            pageGeneral.leadingAnchor.constraint(equalTo: pages.leadingAnchor),
            pageGeneral.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
            pageAdvanced.topAnchor.constraint(equalTo: pages.topAnchor),
            pageAdvanced.leadingAnchor.constraint(equalTo: pages.leadingAnchor),
            pageAdvanced.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
        ])
        pageAdvanced.isHidden = true
        refreshFields()
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        pageGeneral.isHidden = sender.selectedSegment != 0
        pageAdvanced.isHidden = sender.selectedSegment != 1
        fitWindowToPage()
    }

    /// 窗口高度跟随当前页内容（上边距 18+分段控件 24+间距 16，下边距 16）
    private func fitWindowToPage() {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let page: NSView = pageAdvanced.isHidden ? pageGeneral : pageAdvanced
        let neededContentHeight = page.frame.height + 74
        guard neededContentHeight > 150,
              abs(neededContentHeight - content.bounds.height) > 1 else { return }
        var frame = window.frame
        let titlebar = frame.height - content.bounds.height
        let newHeight = neededContentHeight + titlebar
        frame.origin.y += frame.height - newHeight // 顶边不动，底部伸缩
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func makeStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// 通用页：普通用户唯一需要看的一页
    private func makeGeneralPage() -> NSStackView {
        let stack = makeStack()

        // 音乐播放器
        stack.addArrangedSubview(makeHeader("音乐播放器"))
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.setContentHuggingPriority(.required, for: .horizontal)
        appIconView.setContentHuggingPriority(.required, for: .vertical)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let chooseBtn = makeButton("更改…", #selector(chooseApp))
        let appRow = NSStackView(views: [appIconView, targetLabel, makeSpacer(), chooseBtn])
        appRow.orientation = .horizontal
        appRow.alignment = .centerY
        appRow.spacing = 8
        stack.addArrangedSubview(appRow)
        appRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 播放快捷键
        stack.addArrangedSubview(makeHeader("播放快捷键"))
        hotkeyDisplay.font = NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        hotkeyButton.target = self
        hotkeyButton.action = #selector(toggleRecord)
        let hkRow = NSStackView(views: [hotkeyDisplay, hotkeyButton])
        hkRow.orientation = .horizontal
        hkRow.alignment = .centerY
        hkRow.spacing = 10
        stack.addArrangedSubview(hkRow)
        hkRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let hkHint = makeHint("在播放器的「设置 → 快捷键」中启用全局快捷键，并绑定和这里完全相同的组合键；避开 ⌘Space、⌘, 等系统占用键。")
        stack.addArrangedSubview(hkHint)
        hkHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 权限
        let permRow = NSStackView(views: [makeHeader("权限"), permInputStatus, permAXStatus, makeSpacer(), permButton])
        permRow.orientation = .horizontal
        permRow.alignment = .centerY
        permRow.spacing = 10
        permButton.target = self
        permButton.action = #selector(checkPermissions)
        stack.addArrangedSubview(permRow)
        permRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let permHint = makeHint("「输入监控」列表里还要勾选播放器本身（如 QQ音乐），否则它收不到快捷键——这是最容易漏的一步。")
        stack.addArrangedSubview(permHint)
        permHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 操作与状态
        let wakeBtn = makeButton("立即播放", #selector(wakeNow))
        wakeBtn.keyEquivalent = "\r"
        stack.addArrangedSubview(wakeBtn)

        // 状态行固定单行（截断），避免内容变化引起窗口高度跳动
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    /// 高级页：注入链与时序参数，供排查问题时使用
    private func makeAdvancedPage() -> NSStackView {
        let stack = makeStack()

        stack.addArrangedSubview(makeHeader("注入方式（按顺序自动尝试）"))
        for (code, name) in [("P1", "模拟播放快捷键（P1 · 推荐）"),
                             ("P1B", "快捷键广播降级（P1B）"),
                             ("P0", "系统媒体键（P0）"),
                             ("P2", "播放链接唤醒（P2）"),
                             ("P3", "自动点击播放按钮（P3）")] {
            let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(chainToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(code)
            chainBoxes[code] = box
            stack.addArrangedSubview(box)
        }
        let chainHint = makeHint("全部开启时会自动逐级降级，一般无需改动；只有某一种方式出问题时才单独关闭它。")
        stack.addArrangedSubview(chainHint)
        chainHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(makeHeader("时序参数（秒）"))
        let paramRows: [[NSView]] = [
            [paramCell("launchTimeout", "启动等待"), paramCell("readyDelay", "就绪延迟")],
            [paramCell("retryInterval", "重试间隔"), paramCell("verifyTimeout", "出声验证")],
            [paramCell("settleWindow", "静默期"), makeButton("恢复默认", #selector(resetParams))],
        ]
        for rowCells in paramRows {
            let row = NSStackView(views: rowCells)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 24
            row.translatesAutoresizingMaskIntoConstraints = false
            // 右边缘闭合到最后一个子视图，行宽由内容唯一确定（否则整行会被拉伸、列位漂移）
            row.trailingAnchor.constraint(equalTo: rowCells[rowCells.count - 1].trailingAnchor).isActive = true
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(makeButton("测试注入（诊断）", #selector(testInject)))
        return stack
    }

    private func paramCell(_ key: String, _ title: String) -> NSView {
        // 标签与输入框都定宽，保证两列参数上下对齐、输入框不被拉伸/挤压
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 56, height: 22))
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.target = self
        field.action = #selector(paramEdited(_:))
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        paramFields[key] = field
        let cell = NSStackView(views: [label, field])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 6
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.trailingAnchor.constraint(equalTo: field.trailingAnchor).isActive = true
        return cell
    }

    private func makeHeader(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = NSFont.boldSystemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func makeHint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func makeSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func refreshFields() {
        let path = config.playerAppPath
        appIconView.image = NSWorkspace.shared.icon(forFile: path)
        targetLabel.stringValue = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        hotkeyDisplay.stringValue = Self.describeHotkey(flags: config.hotkeyFlags, keyCode: config.hotkeyKeyCode)
        chainBoxes["P1"]?.state = config.enableP1Hotkey ? .on : .off
        chainBoxes["P1B"]?.state = config.enableP1Broadcast ? .on : .off
        chainBoxes["P0"]?.state = config.enableP0MediaKey ? .on : .off
        chainBoxes["P2"]?.state = config.enableP2URLScheme ? .on : .off
        chainBoxes["P3"]?.state = config.enableP3AXPress ? .on : .off
        paramFields["launchTimeout"]?.stringValue = String(format: "%.1f", config.launchTimeout)
        paramFields["readyDelay"]?.stringValue = String(format: "%.1f", config.readyDelay)
        paramFields["retryInterval"]?.stringValue = String(format: "%.1f", config.retryInterval)
        paramFields["verifyTimeout"]?.stringValue = String(format: "%.1f", config.verifyTimeout)
        paramFields["settleWindow"]?.stringValue = String(format: "%.1f", config.settleWindow)
        refreshPermissions()
        refreshStatus()
    }

    private func refreshPermissions() {
        let p = PermissionsChecker.check()
        permInputStatus.stringValue = (p.inputMonitoring ? "✓" : "✗") + " 输入监控"
        permInputStatus.textColor = p.inputMonitoring ? .systemGreen : .systemOrange
        permAXStatus.stringValue = (p.accessibility ? "✓" : "✗") + " 辅助功能"
        permAXStatus.textColor = p.accessibility ? .systemGreen : .systemOrange
        permButton.title = (p.inputMonitoring && p.accessibility) ? "检查权限" : "去授权"
    }

    private func refreshStatus() {
        statusLabel.stringValue = lastNotice.isEmpty ? (statusProvider?() ?? "") : lastNotice
    }

    /// 临时提示：显示 4 秒后自动回到常规状态行
    private func notice(_ message: String) {
        lastNotice = message
        noticeClearTimer?.invalidate()
        noticeClearTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self = self, self.lastNotice == message else { return }
            self.lastNotice = ""
            self.refreshStatus()
        }
        refreshStatus()
    }

    static func describeHotkey(flags: UInt64, keyCode: UInt16) -> String {
        var s = ""
        if flags & (1 << 20) != 0 { s += "⌘" }
        if flags & (1 << 19) != 0 { s += "⌥" }
        if flags & (1 << 18) != 0 { s += "⌃" }
        if flags & (1 << 17) != 0 { s += "⇧" }
        s += Self.characterName(keyCode)
        return s
    }

    private static func characterName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            35: "P", 15: "R", 3: "F", 5: "G", 4: "H", 34: "I", 31: "O", 37: "L",
            46: "M", 45: "N", 1: "S", 17: "T", 0: "A", 11: "B", 14: "E", 40: "K",
            9: "V", 13: "W", 7: "X", 6: "Y", 16: "Z", 12: "Q", 2: "D", 8: "C", 32: "U", 38: "J",
            36: "⏎", 49: "Space", 51: "⌫",
        ]
        return names[code] ?? "key(\(code))"
    }

    // MARK: Actions

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [UTType.application] }
        panel.beginSheetModal(for: window!) { [self] resp in
            guard resp == .OK, let url = panel.url, let _ = window else { return }
            do {
                config.playerAppPath = try NSURL(resolvingAliasFileAt: url, options: []).path ?? url.path
            } catch {
                config.playerAppPath = url.path
            }
            persist()
            let name = URL(fileURLWithPath: config.playerAppPath).deletingPathExtension().lastPathComponent
            notice("已选择 \(name)")
        }
    }

    @objc private func toggleRecord() {
        if isRecordingHotkey { stopRecording(); return }
        isRecordingHotkey = true
        hotkeyButton.title = "按下一个组合键…（Esc 取消）"
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            if event.keyCode == 53 { // Esc
                self.stopRecording()
                return nil
            }
            let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection(mask)
            guard !flags.isEmpty else { return event } // 纯修饰键忽略
            self.config.hotkeyFlags = UInt64(flags.rawValue)
            self.config.hotkeyKeyCode = event.keyCode
            let combo = Self.describeHotkey(flags: self.config.hotkeyFlags, keyCode: self.config.hotkeyKeyCode)
            self.stopRecording()
            self.persist()
            self.notice("已设为 \(combo)，记得在播放器里绑定相同组合键")
            return nil
        }
    }

    private func stopRecording() {
        isRecordingHotkey = false
        hotkeyButton.title = "录制"
        if let monitor = hotkeyMonitor { NSEvent.removeMonitor(monitor); hotkeyMonitor = nil }
        refreshFields()
    }

    @objc private func chainToggled(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        switch code {
        case "P1": config.enableP1Hotkey = on
        case "P1B": config.enableP1Broadcast = on
        case "P0": config.enableP0MediaKey = on
        case "P2": config.enableP2URLScheme = on
        case "P3": config.enableP3AXPress = on
        default: break
        }
        persist()
    }

    @objc private func paramEdited(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        let value = Double(sender.stringValue) ?? 0
        guard value > 0 else { refreshFields(); return }
        switch key {
        case "launchTimeout": config.launchTimeout = value
        case "readyDelay": config.readyDelay = value
        case "retryInterval": config.retryInterval = value
        case "verifyTimeout": config.verifyTimeout = value
        case "settleWindow": config.settleWindow = value
        default: break
        }
        persist()
    }

    @objc private func resetParams() {
        let d = WakeConfig()
        config.launchTimeout = d.launchTimeout
        config.readyDelay = d.readyDelay
        config.retryInterval = d.retryInterval
        config.verifyTimeout = d.verifyTimeout
        config.settleWindow = d.settleWindow
        persist()
        notice("时序参数已恢复默认")
    }

    @objc private func testInject() { onTestInject?() }
    @objc private func wakeNow() { onWakeNow?() }

    @objc private func checkPermissions() {
        if PermissionsChecker.promptIfNeeded(window: window) {
            refreshPermissions()
        } else {
            notice("权限已就绪 ✓")
        }
    }

    private func persist() {
        config.save()
        onConfigChanged?(config)
        refreshFields()
    }
}
