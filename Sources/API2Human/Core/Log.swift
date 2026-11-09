import Foundation

/// 同时写 NSLog 和 ~/Library/Logs/API2Human.log（`log show` 经常抓不到 NSLog，文件方便排查）
/// 日志里有面试问题原文：文件只给本人读写（0600），超过 maxBytes 轮转成 .log.1（只留一份旧的）
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("API2Human.log")
    }()

    static var rotatedURL: URL { url.appendingPathExtension("1") }

    private static let queue = DispatchQueue(label: "com.api2human.log")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written: UInt64 = 0
    /// 只在 queue 上读写（测试用 setMaxBytes 改）
    nonisolated(unsafe) private static var maxBytes: UInt64 = 5 * 1024 * 1024

    static func info(_ message: String) {
        NSLog("API2Human: %@", message)
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        queue.async {
            if handle == nil { open() }
            guard let handle else { return }          // 目录不可写 / 磁盘满：不计数、不轮转
            let data = Data(line.utf8)
            guard (try? handle.write(contentsOf: data)) != nil else { return }
            written += UInt64(data.count)
            if written >= maxBytes { rotate() }
        }
    }

    /// 等已排队的日志写完（测试、退出前用）
    static func flush() { queue.sync {} }

    /// 测试用：在日志队列上改上限，避免和写日志的线程数据竞争
    static func setMaxBytes(_ n: UInt64) { queue.sync { maxBytes = n } }

    private static func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // 老版本建的文件是 0644：顺手收紧
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try? FileHandle(forWritingTo: url)
        written = (try? handle?.seekToEnd()) ?? 0
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        // 先把当前日志挪到临时名，成功了才替换旧的 .1：挪不动时不能先把好好的 .1 删了
        let staging = url.appendingPathExtension("rotating")
        try? fm.removeItem(at: staging)
        let moved = (try? fm.moveItem(at: url, to: staging)) != nil
        if moved {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: staging, to: rotatedURL)
        }
        open()
        if !moved { written = 0 }   // 挪不动就接着写原文件，别每一行都重试轮转
    }
}
