//
// WakeLog.swift
// AntiMusic
//
// 统一日志：os_log + 文件（~/Library/Logs/AntiMusic/wake.log）。
// 文件日志是闭环测试架构的数据源（scenario/tune 脚本解析各阶段耗时）。
//

import Foundation
import os

final class WakeLog {
    static let shared = WakeLog()
    private let queue = DispatchQueue(label: "org.nift4.AntiMusic.log")
    private let logger = Logger(subsystem: "org.nift4.AntiMusic", category: "wake")
    private let fileURL: URL
    private var mirrorToStdout = false

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AntiMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("wake.log")
        mirrorToStdout = ProcessInfo.processInfo.environment["ANTIMUSIC_LOG_STDOUT"] != nil
    }

    /// 供测试环境把日志镜像到 stdout（CLI harness 解析）
    static func enableStdoutMirror() { shared.mirrorToStdout = true }

    func info(_ message: String) {
        let line = "\(Self.stamp()) [wake] \(message)"
        logger.info("\(message, privacy: .public)")
        queue.async {
            if let data = (line + "\n").data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: self.fileURL)
                }
            }
            if self.mirrorToStdout { FileHandle.standardError.write((line + "\n").data(using: .utf8)!) }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
