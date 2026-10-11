//
// StatusMenuController.swift
// AntiMusic
//
// 菜单栏：状态显示、设置入口、权限检查、退出（唤醒/测试均收进设置窗口，需求 5.4）。
//

import Foundation
import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    weak var engine: WakeEngine?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let stateItem = NSMenuItem(title: "状态：Idle", action: nil, keyEquivalent: "")

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "AntiMusic") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = "♫"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "检查权限", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AntiMusic", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        item.menu = menu
        statusItem = item
        updateState(engine?.machine.state ?? .idle)
    }

    func updateState(_ state: WakeState) {
        stateItem.title = "状态：\(state.rawValue)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateState(engine?.machine.state ?? .idle)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkPermissions() {
        PermissionsChecker.promptIfNeeded(window: nil)
    }

    @objc private func quit() {
        onQuit?()
    }
}
