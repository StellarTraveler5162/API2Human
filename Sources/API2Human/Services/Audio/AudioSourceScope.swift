import CoreAudio
import Darwin

/// 系统里一个用到音频的进程（CoreAudio 进程对象的快照）
struct AudioProcess: Equatable, Sendable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
}

/// 系统内录录谁的声音。
/// 默认只录会议软件：微信提示音、浏览器视频、音乐等其他声音不会被当成面试官的问题。
enum AudioSourceScope: String, CaseIterable, Sendable {
    case meetingApps   // 只录会议软件（找不到会议软件时临时录全部）
    case allSystem     // 全部系统声音（网页会议、微信视频时用）

    var title: String {
        switch self {
        case .meetingApps: "只录会议软件（腾讯会议 / 飞书 / Teams / Zoom / 钉钉 / Webex）"
        case .allSystem: "全部系统声音（网页会议、微信视频选这个）"
        }
    }

    /// 会议软件的 Bundle ID 前缀（含辅助进程，比如飞书的 com.electron.lark.helper）。
    /// 不含微信：消息提示音就从微信进程发出，正是要排除的；不含浏览器：会混进其他网页的声音。
    static let meetingBundlePrefixes = [
        "com.tencent.meeting", "com.tencent.wemeet",           // 腾讯会议
        "com.electron.lark", "com.bytedance.lark", "com.larksuite", "com.bytedance.feishu",   // 飞书 / Lark
        "com.microsoft.teams",                                   // Teams
        "us.zoom",                                               // Zoom
        "com.alibaba.DingTalkMac", "com.alibaba.dingtalk",       // 钉钉
        "com.cisco.webex", "com.webex",                          // Webex
    ]

    /// 从进程列表里挑出会议软件的进程。额外的匹配名（调试用）按进程名精确匹配
    static func meetingProcesses(in processes: [AudioProcess], extraNames: [String] = []) -> [AudioProcess] {
        processes.filter { p in
            let bundle = p.bundleID.lowercased()
            return meetingBundlePrefixes.contains { bundle.hasPrefix($0.lowercased()) } || extraNames.contains(p.name)
        }
    }

    /// 给人看的名字：腾讯会议 / 飞书 …
    static func displayName(of processes: [AudioProcess]) -> String {
        var names: [String] = []
        for p in processes {
            let b = p.bundleID.lowercased()
            let name = b.hasPrefix("com.tencent") ? "腾讯会议"
                : (b.contains("lark") || b.contains("feishu")) ? "飞书"
                : b.hasPrefix("com.microsoft.teams") ? "Teams"
                : b.hasPrefix("us.zoom") ? "Zoom"
                : b.contains("dingtalk") ? "钉钉"
                : b.contains("webex") ? "Webex"
                : p.name
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: "、")
    }
}

extension HAL {
    /// CoreAudio 里所有用到音频的进程
    static func audioProcesses() -> [AudioProcess] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            let pid = (try? get(id, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            var buf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buf, UInt32(buf.count))
            return AudioProcess(object: id, pid: pid,
                                bundleID: (try? string(id, kAudioProcessPropertyBundleID)) ?? "",
                                name: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
