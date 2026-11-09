import Foundation

/// API2Human 面试者角色卡（.a2hcard v1）解析器。
/// 规范：skills/api2human-candidate-card/references/a2hcard-spec.md
struct CandidateCard {
    enum Section: String, CaseIterable {
        case pitch, profile, experience, projects, skills, stories, talkingPoints, redLines, target, voice

        var zh: String {
            switch self {
            case .pitch: "一句话定位"
            case .profile: "基本信息"
            case .experience: "工作经历"
            case .projects: "项目经历"
            case .skills: "技能边界"
            case .stories: "故事库"
            case .talkingPoints: "求职口径"
            case .redLines: "红线"
            case .target: "目标岗位"
            case .voice: "表达风格"
            }
        }

        var en: String {
            switch self {
            case .pitch: "Pitch"
            case .profile: "Profile"
            case .experience: "Experience"
            case .projects: "Projects"
            case .skills: "Skills"
            case .stories: "Stories"
            case .talkingPoints: "Talking Points"
            case .redLines: "Red Lines"
            case .target: "Target Role"
            case .voice: "Voice"
            }
        }

        static func match(_ title: String) -> Section? {
            let t = title.trimmingCharacters(in: .whitespaces)
            return allCases.first { t == $0.zh || t.caseInsensitiveCompare($0.en) == .orderedSame }
        }
    }

    static let fileExtension = "a2hcard"
    static let supportedVersion = 1

    var meta: [String: String] = [:]
    var sections: [Section: String] = [:]
    var unknownSections: [(title: String, body: String)] = []

    var version: Int { Int(meta["a2hcard"] ?? "") ?? 0 }

    enum ParseError: LocalizedError {
        case notACard(String)
        var errorDescription: String? {
            switch self { case .notACard(let why): "不是有效的 API2Human 角色卡：\(why)" }
        }
    }

    init(text raw: String) throws {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw ParseError.notACard("第一行必须是 ---")
        }
        lines = lines.dropFirst()
        var closed = false
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            if let colon = line.firstIndex(of: ":") {
                meta[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard closed else { throw ParseError.notACard("头部元信息没有结束的 ---") }
        guard version > 0 else { throw ParseError.notACard("缺少 a2hcard 版本号") }

        // 正文按 "## " 切章节；第一个章节之前的内容归入一句话定位
        var current: (section: Section?, title: String) = (.pitch, "")
        var buffer: [String] = []
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            if let s = current.section {
                sections[s] = [sections[s], body].compactMap { $0 }.joined(separator: "\n\n")
            } else {
                unknownSections.append((current.title, body))
            }
        }
        // 先去注释再切章节：注释里的 "## 旧项目" 不能变成一个章节、把注释掉的内容发给 AI
        let body = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        for line in body.components(separatedBy: "\n") {
            // 和 validate_a2hcard.py 一样：^##\s+(.+?)\s*$（"##\t标题" 算，"## " 后面没字不算）
            if !line.hasPrefix("###"), let r = line.range(of: #"^##\s+\S.*$"#, options: .regularExpression) {
                flush(); buffer = []
                let title = String(line[r].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                current = (Section.match(title), title)
            } else {
                buffer.append(line)
            }
        }
        flush()
    }

    /// 发给面试 AI 前的清洗（规范第 3、4 节；与 validate_a2hcard.py 的 ai_view 保持一致）：
    /// - 删除 <!-- 注释 -->
    /// - 带 [待确认…] / [待补充…] 的分句整句删除（分句以 ，,、；;。 分隔，括号里的不算）
    /// - 删完只剩 "- 字段：" 前缀的行整行删除；标题行只去标记
    static func forAI(_ text: String) -> String {
        text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .compactMap(filterLine)
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 整份 .a2hcard 文件发给 AI 的样子，逐行对齐 validate_a2hcard.py 的 ai_view（--selftest-card-ai-view 用来对比两边）：
    /// 去 BOM、CRLF→LF、去注释；front-matter 里带标记的行整行删除，其余行同 forAI
    /// （正式路径按字段调 forAI；字段正文里的 "---" 是分隔线，不能当 front-matter，所以分成两个函数）
    static func forAIFile(_ text: String) -> String {
        // Python 的 lstrip("\ufeff") 去掉所有开头 BOM；文本模式读文件会把单独的 \r 也变成换行
        var t = String(String.UnicodeScalarView(text.unicodeScalars.drop { $0 == "\u{FEFF}" }))
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        var out: [String] = [], inMeta = false, metaDone = false
        for line in t.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "---" && !metaDone {
                inMeta.toggle()
                metaDone = !inMeta
                out.append(line)
            } else if inMeta {
                if !line.contains("[待确认") && !line.contains("[待补充") { out.append(line) }
            } else if let kept = filterLine(line) {
                out.append(kept)
            }
        }
        return out.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static let marker = #"\[(待确认|待补充)[^\]]*\]"#
    private static let linePrefix = #"^(\s*(?:[-*]\s+)?(?:[^：:\n\[\]]{1,12}[：:])?\s*)"#

    private static func hasMarker(_ s: String) -> Bool {
        s.range(of: marker, options: .regularExpression) != nil
    }

    private static func filterLine(_ line: String) -> String? {
        guard hasMarker(line) else { return line }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return line.replacingOccurrences(of: marker, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        let prefixRange = line.range(of: linePrefix, options: .regularExpression)!
        let prefix = String(line[prefixRange])
        let kept = splitClauses(String(line[prefixRange.upperBound...])).filter { !hasMarker($0) }
        let content = kept.joined().trimmingCharacters(in: CharacterSet(charactersIn: "，,、；;。 \t"))
        return content.isEmpty ? nil : prefix + content
    }

    private static func splitClauses(_ s: String) -> [String] {
        // 按 Unicode 码点遍历（和 Python 一致）：按 Character 遍历时，"。"后面跟变体选择符 / 组合符会并成一个字形，认不出分隔符
        var out: [String] = [], buf = String.UnicodeScalarView(), depth = 0
        let open = Set("（(「【[".unicodeScalars), close = Set("）)」】]".unicodeScalars), delims = Set("，,、；;。".unicodeScalars)
        for u in s.unicodeScalars {
            buf.append(u)
            if open.contains(u) { depth += 1 }
            else if close.contains(u) { depth = max(0, depth - 1) }
            else if delims.contains(u) && depth == 0 { out.append(String(buf)); buf = String.UnicodeScalarView() }
        }
        if !buf.isEmpty { out.append(String(buf)) }
        return out
    }

    /// 映射到面试资料窗口的三栏（规范第 5 节）
    var interviewContext: InterviewContext {
        func block(_ s: Section) -> String? {
            guard let body = sections[s] else { return nil }
            return "## \(s.zh)\n\(body)"
        }
        // 带标记的元信息不进资料（例如 years: 6 [待确认]）
        func value(_ key: String) -> String? {
            // 和 Python 一样按 "[待确认" / "[待补充" 子串判断：没写闭合 ] 的标记也要挡住
            guard let v = meta[key], !v.isEmpty, !v.contains("[待确认"), !v.contains("[待补充") else { return nil }
            return v
        }
        var header: [String] = []
        if let name = value("name") { header.append("姓名：\(name)") }
        if let role = value("role") { header.append("职位：\(role)") }
        // 纯数字（可带 + 或小数）才补"年"："6年""6 years""6年+" 原样保留
        if let years = value("years") {
            let numeric = years.range(of: #"^\d+(\.\d+)?\+?$"#, options: .regularExpression) != nil
            header.append("工作年限：\(years)" + (numeric ? " 年" : ""))
        }

        let resumeSections: [Section] = [.pitch, .profile, .experience, .projects, .skills, .stories, .voice]
        let resume = ([header.joined(separator: "｜")] + resumeSections.compactMap(block)
                      + unknownSections.map { "## \($0.title)\n\($0.body)" })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let notes = [Section.talkingPoints, .redLines].compactMap(block).joined(separator: "\n\n")
        return InterviewContext(resume: resume,
                                jobDescription: sections[.target] ?? "",
                                notes: notes)
    }

    /// 统计：还有多少待确认 / 待补充
    static func markerCounts(_ text: String) -> (unconfirmed: Int, missing: Int) {
        // 与校验脚本一致：[待确认] 和 [待确认：提示] 都算，注释里的不算
        let body = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        func count(_ pattern: String) -> Int {
            (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body)) ?? 0
        }
        return (count(#"\[待确认[^\]]*\]"#), count(#"\[待补充[^\]]*\]"#))
    }
}
