import Foundation
import PDFKit
import AppKit

/// 面试前准备的背景资料：简历、岗位 JD、补充信息。拼进 system prompt，让回答和"我"的真实经历一致。
/// 存在 ~/Library/Application Support/API2Human/context.json（不进代码仓库）。
struct InterviewContext: Codable, Equatable, Sendable {
    var resume = ""          // 我的简历 / 背景
    var jobDescription = ""  // 目标岗位 JD
    var notes = ""           // 补充：公司业务、面试官、想突出的点、要回避的话题

    /// 单栏上限：防止误贴整本书。约 2 万字 ≈ 1.5 万 token，DeepSeek 前缀缓存后几乎不影响首字延迟
    static let maxCharsPerField = 20_000
    static let didChange = Notification.Name("API2Human.InterviewContextDidChange")

    static var fileURL: URL {
        AudioCaptureManager.recordingsRoot.deletingLastPathComponent().appendingPathComponent("context.json")
    }

    var isEmpty: Bool {
        [resume, jobDescription, notes].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func load() -> InterviewContext {
        guard let data = try? Data(contentsOf: fileURL),
              let ctx = try? JSONDecoder().decode(InterviewContext.self, from: data) else { return .init() }
        return ctx
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: [.atomic])
        // 简历属于个人隐私：只有本人可读
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    static let maxImportBytes = 20 * 1_048_576

    /// HTML -> 纯文本：去掉 script/style、标签换成空白、解常见实体
    static func plainText(fromHTML html: String) -> String {
        var t = html.replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// 从文件读出纯文本：txt / md / pdf / docx / doc / rtf / html
    static func importText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        // 简历 / JD 不会这么大：防止误选视频、整本书把内存撑爆
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxImportBytes else {
            throw LLMError.config("\(url.lastPathComponent) 太大（\(size / 1_048_576)MB），资料文件请控制在 \(maxImportBytes / 1_048_576)MB 以内")
        }
        var text: String?
        switch ext {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "txt", "text", "md", "markdown":
            // UTF-8 读不了就按 GB18030（Windows 上存的中文 txt 常见）
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: gb))
        case "html", "htm":
            // 不走 NSAttributedString 的 HTML 导入：它基于 WebKit，会去拉网页里引用的远程图片 / 样式
            text = (try? String(contentsOf: url, encoding: .utf8)).map(plainText(fromHTML:))
        case "docx", "doc", "rtf", "rtfd", "odt":
            text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            throw LLMError.config("不支持 .\(ext) 文件，请用 txt / md / pdf / docx / doc / rtf / html")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.config("没能从 \(url.lastPathComponent) 读出文字（扫描版 PDF 需要先转成文字）")
        }
        // 合并 PDF 抽取常见的多余空行
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
