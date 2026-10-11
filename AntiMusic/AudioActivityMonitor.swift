//
// AudioActivityMonitor.swift
// AntiMusic
//
// 用 CoreAudio 公开 API（macOS 14.2+）检测“某个进程是否真的在出声”。
// 关键点：不依赖 MediaRemote 私有 API（其在 macOS 15.4+ 已对第三方收紧，macOS 27 实测读取全空），
// 也不需要任何 TCC 权限。已通过 poc/audioprobe.swift 实测验证。
//

import Foundation
import CoreAudio

enum AudioActivityMonitor {
    // 与 SDK 头文件 AudioHardware.h 一致的公开属性选择器（FourCC）。
    // 自行声明以兼容旧 SDK 的编译（值即 Apple 公开文档值）。
    private static func fourcc(_ v: UInt32) -> AudioObjectPropertySelector { v }
    private static let kAMHardwarePropertyProcessObjectList = fourcc((0x70 << 24) | (0x72 << 16) | (0x73 << 8) | 0x23)   // 'prs#'
    private static let kAMHardwarePropertyTranslatePIDToProcessObject = fourcc((0x69 << 24) | (0x64 << 16) | (0x32 << 8) | 0x70) // 'id2p'
    private static let kAMProcessPropertyPID = fourcc((0x70 << 24) | (0x70 << 16) | (0x69 << 8) | 0x64)                  // 'ppid'
    private static let kAMProcessPropertyIsRunningOutput = fourcc((0x70 << 24) | (0x69 << 16) | (0x72 << 8) | 0x6F)      // 'piro'

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func getData<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type) -> T? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        var readSize = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &readSize, value) == noErr else { return nil }
        return value.load(as: T.self)
    }

    /// 把 PID 翻译成 CoreAudio 进程对象；不在播放/无音频会话时可能返回 nil。
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var pidVar = pid
        var addr = address(kAMHardwarePropertyTranslatePIDToProcessObject)
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidVar) { pidPtr in
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown, objectID != 0 else { return nil }
        return objectID
    }

    /// 该进程当前是否正在输出音频（即“真的在放歌”）。
    static func isOutputRunning(_ pid: pid_t) -> Bool {
        guard let object = processObject(for: pid) else { return false }
        let running = getData(object, kAMProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0
        return running != 0
    }

    /// 当前正在输出音频的所有进程 PID（诊断用）。
    static func processesOutputtingAudio() -> [pid_t] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAMHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [pid_t] = []
        for id in ids {
            if let pid = getData(id, kAMProcessPropertyPID, as: pid_t.self),
               (getData(id, kAMProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0 {
                result.append(pid)
            }
        }
        return result
    }

    /// 轮询直到目标进程出声或超时。返回是否出声。
    /// - Parameters:
    ///   - interval: 轮询间隔（默认 0.2s）
    static func waitUntilOutputting(_ pid: pid_t, timeout: TimeInterval, interval: TimeInterval = 0.2, shouldAbort: @escaping () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if shouldAbort() { return false }
            if isOutputRunning(pid) { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return isOutputRunning(pid)
    }
}
