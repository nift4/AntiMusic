//
// MediaKeyTap.swift
// AntiMusic
//
// 通道A：CGEventTap 直通拦截媒体键（systemDefined / subtype 8）。
// 在 QQ音乐正在出声时放行事件（交由 rcd 正常路由），
// 否则吞掉事件并回调引擎执行唤醒流程——Apple Music 因此不会被唤起。
// 需要「输入监控」（创建监听 tap）+「辅助功能」（filter 型 tap）权限。
// 创建失败时引擎回退到通道B（fake player + MPRemoteCommandCenter）。
//

import Foundation
import CoreGraphics
import AppKit
import os

final class MediaKeyTap {
    typealias Handler = (_ keyCode: UInt32, _ keyDown: Bool) -> Bool

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: Handler
    private(set) var isActive = false

    /// 需要拦截的媒体键：PLAY/NEXT/PREVIOUS/FAST/REWIND（需求 §9：外接键盘可能发 FAST/REWIND）
    static let handledKeyCodes: Set<UInt32> = [16, 17, 18, 19, 20]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    private static let systemDefinedRawValue: UInt32 = 14 // kCGEventSystemDefined
    private static var systemDefinedType: CGEventType { CGEventType(rawValue: systemDefinedRawValue)! }

    /// 创建并启用 tap。失败多半是权限缺失。
    func start() -> Bool {
        guard tap == nil else { return isActive }
        let eventMask = CGEventMask(1 << MediaKeyTap.systemDefinedRawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: MediaKeyTap.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            WakeLog.shared.info("MediaKeyTap: create failed (permissions?) — falling back to fake player channel")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        WakeLog.shared.info("MediaKeyTap: active (hid, headInsert, filter)")
        return true
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        isActive = false
    }

    /// 交棒模式：不拦截任何事件，全部放行（rcd 会路由给正在播放的 QQ音乐）。
    func setPassthrough(_ enabled: Bool) {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: !enabled)
        isActive = !enabled
        WakeLog.shared.info("MediaKeyTap passthrough=\(enabled)")
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == MediaKeyTap.systemDefinedRawValue else {
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = nsEvent.data1
        let keyCode = UInt32((data & 0xFFFF0000) >> 16)
        let keyDown = ((data & 0xFF00) >> 8) == 0x0A
        guard MediaKeyTap.handledKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        let swallow = me.handler(keyCode, keyDown)
        if swallow {
            WakeLog.shared.debugOnly("MediaKeyTap: swallowed keyCode \(keyCode) down=\(keyDown)")
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

extension WakeLog {
    func debugOnly(_ message: String) {
        // 高频事件不进文件日志，只进 os_log
        Logger(subsystem: "org.nift4.AntiMusic", category: "wake").debug("\(message, privacy: .public)")
    }
}
