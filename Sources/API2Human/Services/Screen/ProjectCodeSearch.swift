import Foundation

/// 本地项目代码检索：给"即圈即搜"的第三段"这段代码在项目里的作用"提供真实依据，而不是让模型猜。
/// 1. 定位：用 OCR 识别出的较长代码行，在项目文件里逐行比对（忽略空白），找出所在文件、行号、外层 class/def
/// 2. 调用链：从外层符号往外查两层引用（谁用了它、又是谁用了那个）
enum ProjectCodeSearch {
    static let defaultsKey = "projectDirs"

    static var projectDirs: [URL] {
        get {
            var paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
            if let env = ProcessInfo.processInfo.environment["A2H_PROJECT_DIRS"] {   // 调试用
                paths += env.split(separator: ":").map(String.init)
            }
            return paths.map { URL(fileURLWithPath: $0) }
        }
    }

    static func addProjectDir(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if !paths.contains(url.path) { paths.append(url.path) }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }

    static func clearProjectDirs() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    // MARK: - 文件

    private static let codeExtensions: Set<String> = ["py", "swift", "js", "ts", "tsx", "jsx", "go", "java", "kt",
                                                      "c", "cc", "cpp", "h", "hpp", "rs", "rb", "m", "mm", "cs", "lua"]
    private static let skipDirs: Set<String> = [".git", "node_modules", "venv", ".venv", "env", "__pycache__", ".build",
                                                "build", "dist", "DerivedData", "Pods", ".idea", ".vscode",
                                                "site-packages", "checkpoints", "logs", "runs", "wandb", ".swiftpm"]
    private static let maxFiles = 4000
    private static let maxFileBytes = 400_000
    /// 一次检索最多读这么多字节：误把超大目录（比如整个 home）加进来时不至于卡住
    private static let maxTotalBytes = 40_000_000

    struct SourceFile {
        let root: URL
        let url: URL
        let lines: [String]
        var relativePath: String {
            // 只去掉开头的根目录（replacingOccurrences 会把路径中间同名的一段也删掉）
            // 先解析符号链接：/var → /private/var、用户选的目录本身是链接时，枚举出来的文件路径和 root 前缀对不上
            let rootPath = root.resolvingSymlinksInPath().path, filePath = url.resolvingSymlinksInPath().path
            let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let rel = filePath.hasPrefix(base) ? String(filePath.dropFirst(base.count)) : url.lastPathComponent
            return root.lastPathComponent + "/" + rel
        }
    }

    static func loadFiles(in roots: [URL]) -> [SourceFile] {
        var files: [SourceFile] = []
        var totalBytes = 0
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if files.count >= maxFiles { return files }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skipDirs.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard codeExtensions.contains(url.pathExtension.lowercased()),
                      (values?.fileSize ?? 0) <= maxFileBytes,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                totalBytes += values?.fileSize ?? 0
                if totalBytes > maxTotalBytes {
                    Log.info("项目检索：已读 \(files.count) 个文件、超过 \(maxTotalBytes / 1_000_000)MB，停止读取（目录是不是选得太大了？）")
                    return files
                }
                files.append(SourceFile(root: root, url: url, lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")))   // CRLF 文件不留 \r
            }
        }
        return files
    }

    // MARK: - 检索


    private static let definitionPattern =
        #"^(\s*)(?:async\s+|export\s+|public\s+|private\s+|static\s+|final\s+)*(?:def|class|func|function|fn|struct|enum|interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    // 逐行调用，正则只编译一次
    private static let definitionRegex = try! NSRegularExpression(pattern: definitionPattern)

    private static func definition(in line: String) -> (indent: Int, name: String)? {
        // 快速排除：不含这些关键字的行不可能是定义
        guard line.contains("def ") || line.contains("class ") || line.contains("func ") || line.contains("function ")
                || line.contains("fn ") || line.contains("struct ") || line.contains("enum ")
                || line.contains("interface ") || line.contains("protocol ") else { return nil }
        let regex = definitionRegex
        guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let indentRange = Range(m.range(at: 1), in: line),
              let nameRange = Range(m.range(at: 2), in: line) else { return nil }
        return (line[indentRange].count, String(line[nameRange]))
    }

    /// 从某一行往上找外层的 def/class 链，例如 ["CausalSelfAttention", "forward"]
    private static func enclosingSymbols(_ file: SourceFile, line index: Int) -> [String] {
        var chain: [String] = []
        var currentIndent = Int.max
        var i = index
        while i >= 0 {
            let line = file.lines[i]
            if let def = definition(in: line), def.indent < currentIndent {
                chain.insert(def.name, at: 0)
                currentIndent = def.indent
                if currentIndent == 0 { break }
            }
            i -= 1
        }
        return chain
    }

    struct Location {
        let file: SourceFile
        let firstLine: Int   // 0 起
        let lastLine: Int
        let symbols: [String]
    }

    /// OCR 文字 -> 项目里的位置
    static func locate(ocr: String, files: [SourceFile]) -> Location? {
        let probes = ocr.components(separatedBy: "\n").map(confusable).filter { $0.count >= 12 }
        guard !probes.isEmpty else { return nil }
        var best: (file: SourceFile, normalized: [String], hits: [Int])?
        for file in files {
            let normalized = file.lines.map(confusable)
            // 先精确匹配（字典查找），查不到再逐行做包含比较
            var exact: [String: Int] = [:]
            for (i, line) in normalized.enumerated() where line.count >= 12 && exact[line] == nil { exact[line] = i }
            var hits: [Int] = []
            for probe in probes {
                if let idx = exact[probe] ?? normalized.firstIndex(where: { $0.count >= 12 && ($0.contains(probe) || probe.contains($0)) }) {
                    hits.append(idx)
                }
            }
            if hits.count > (best?.hits.count ?? 0) { best = (file, normalized, hits) }
        }
        // 至少命中 2 行；或者只命中 1 行但这一行足够长（≥30 字符，不太可能是巧合）——
        // 常见于只圈了两三行、其中一行正是被改动的那行
        guard let best else { return nil }
        let hitLine = best.normalized[best.hits[0]]
        let longSingleHit = best.hits.count == 1 && probes.contains { $0.count >= 30 && hitLine.contains($0) }
        guard best.hits.count >= min(2, probes.count) || longSingleHit else { return nil }
        let sorted = best.hits.sorted()
        // 去掉离群命中（同一行内容在文件别处重复出现），取最密集的一段
        let median = sorted[sorted.count / 2]
        let near = sorted.filter { abs($0 - median) <= max(40, probes.count * 3) }
        let first = near.first ?? median, last = near.last ?? median
        return Location(file: best.file, firstLine: first, lastLine: last,
                        symbols: enclosingSymbols(best.file, line: first))
    }

    struct Reference {
        let file: SourceFile
        let line: Int
        var text: String { file.lines[line].trimmingCharacters(in: .whitespaces) }
        var enclosing: [String] { enclosingSymbols(file, line: line) }
    }

    /// 某个符号在项目里被用到的地方（不含它自己的定义行）
    static func references(of name: String, files: [SourceFile], limit: Int = 4) -> [Reference] {
        guard name.count >= 3, let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b") else { return [] }
        var refs: [Reference] = []
        for file in files {
            for (i, line) in file.lines.enumerated() {
                guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                      definition(in: line)?.name != name,
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                refs.append(Reference(file: file, line: i))
                if refs.count >= limit { return refs }
            }
        }
        return refs
    }

    /// OCR 里出现的 self.NAME，在外层类的范围内找 `self.NAME =` 或 register_buffer("NAME", …)
    private static func memberDefinitions(ocr: String, location loc: Location) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"self\.([A-Za-z_][A-Za-z0-9_]*)"#) else { return [] }
        var names: [String] = []
        for m in regex.matches(in: ocr, range: NSRange(ocr.startIndex..., in: ocr)) {
            if let r = Range(m.range(at: 1), in: ocr), !names.contains(String(ocr[r])) { names.append(String(ocr[r])) }
        }
        guard !names.isEmpty else { return [] }
        // 外层类的行范围：从类定义行往下，直到下一个同级或更外层的定义
        var classStart = loc.firstLine
        while classStart > 0, definition(in: loc.file.lines[classStart])?.indent != 0 { classStart -= 1 }
        var classEnd = classStart + 1
        while classEnd < loc.file.lines.count, definition(in: loc.file.lines[classEnd])?.indent != 0 { classEnd += 1 }

        var found: [String] = []
        for name in names.prefix(12) {
            let assign = "self.\(name) ="
            let buffer = "register_buffer(\"\(name)\""
            for i in classStart..<classEnd where !(loc.firstLine...loc.lastLine).contains(i) {
                let line = loc.file.lines[i]
                if line.contains(assign) || line.contains(buffer) || line.contains("register_buffer('\(name)'") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    found.append("第 \(i + 1) 行 `\(String(text.prefix(140)))`")
                    break
                }
            }
        }
        return found
    }

    // MARK: - OCR 校正

    /// 全角标点 -> 半角（只用在看起来像代码的行）
    private static let halfWidthMap: [Character: Character] = [
        "（": "(", "）": ")", "［": "[", "］": "]", "｛": "{", "｝": "}", "：": ":", "，": ",", "；": ";", "＝": "=",
        "＋": "+", "－": "-", "＊": "*", "／": "/", "＜": "<", "＞": ">", "＂": "\"", "＇": "'", "　": " "]

    static func halfWidth(_ s: String) -> String {
        String(s.map { halfWidthMap[$0] ?? $0 })
    }

    private static func looksLikeCode(_ s: String) -> Bool {
        s.range(of: #"[A-Za-z_][A-Za-z0-9_]*\s*[（(=\[.]"#, options: .regularExpression) != nil
    }

    /// 按 OCR 常见混淆归一化：全角/半角、O/o↔0、l/I/|↔1、. ↔ -、大小写、空白
    /// 单次遍历完成：截掉注释、全角→半角、ASCII 小写、去空白、混淆字符归一（每个项目文件的每一行都要算，必须快）
    static func confusable(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for u in s.unicodeScalars {
            if u == "#" { break }                                   // # 注释
            if u == "/" && previous == "/" { out.removeLast(); break } // // 注释
            previous = u
            var v = u.value
            if v >= 0xFF01 && v <= 0xFF5E { v -= 0xFEE0 }           // 全角 ASCII → 半角
            if v == 0x3000 || v == 0x20 || v == 0x09 || v == 0x0D || v == 0x0A { continue }   // 空白
            if v >= 0x41 && v <= 0x5A { v += 0x20 }                 // A-Z → a-z
            switch v {
            case 0x6F: v = 0x30                                     // o → 0
            case 0x6C, 0x69, 0x7C: v = 0x31                         // l i | → 1
            case 0x2D, 0xB7: v = 0x2E                               // - · → .
            default: break
            }
            out.append(Unicode.Scalar(v) ?? u)
        }
        return String(out)
    }

    /// 用源文件校正 OCR：某一行在混淆规则下和定位范围附近的源码行相同 -> 换成源码原文。
    /// 真正的改动（比如 == 0 改成 == 1）在混淆规则下不相同，保留 OCR 原样。
    static func correctOCR(_ ocr: String, file: SourceFile, near loc: Location) -> (text: String, replaced: Int) {
        let lo = max(0, loc.firstLine - 5), hi = min(file.lines.count - 1, loc.lastLine + 5)
        let candidates = (lo...hi).map { (confusable(file.lines[$0]), file.lines[$0].trimmingCharacters(in: .whitespaces)) }
            .filter { $0.0.count >= 6 }
        var replaced = 0
        let lines = ocr.components(separatedBy: "\n").map { line -> String in
            let key = confusable(line)
            guard key.count >= 6 else { return line }
            if let match = candidates.first(where: { $0.0 == key }) {
                if match.1 != line.trimmingCharacters(in: .whitespaces) { replaced += 1 }
                return match.1
            }
            return looksLikeCode(line) ? halfWidth(line) : line
        }
        return (lines.joined(separator: "\n"), replaced)
    }

    struct Result {
        let context: String?        // 给模型的检索结果
        let correctedOCR: String    // 用源文件校正后的 OCR 文字
    }

    /// 检索 + OCR 校正；没配置目录或找不到时 context 为 nil，OCR 只做全角转半角
    static func search(ocr: String) -> Result {
        let plain = ocr.components(separatedBy: "\n").map { looksLikeCode($0) ? halfWidth($0) : $0 }.joined(separator: "\n")
        let roots = projectDirs
        guard !roots.isEmpty else { return Result(context: nil, correctedOCR: plain) }
        let started = Date()
        let files = loadFiles(in: roots)
        guard let loc = locate(ocr: ocr, files: files) else {
            Log.info("项目检索：\(files.count) 个文件里没找到圈选的代码（\(String(format: "%.2f", Date().timeIntervalSince(started)))s）")
            return Result(context: nil, correctedOCR: plain)
        }
        let corrected = correctOCR(ocr, file: loc.file, near: loc)
        if corrected.replaced > 0 { Log.info("项目检索：用源文件校正了 \(corrected.replaced) 行 OCR") }
        return Result(context: context(ocr: ocr, files: files, loc: loc, started: started), correctedOCR: corrected.text)
    }

    private static func context(ocr: String, files: [SourceFile], loc: Location, started: Date) -> String {

        var lines: [String] = []
        let where_ = loc.symbols.isEmpty ? "" : "，在 " + loc.symbols.joined(separator: " → ") + " 里"
        lines.append("- 圈选的代码位于 \(loc.file.relativePath) 第 \(loc.firstLine + 1)~\(loc.lastLine + 1) 行\(where_)")

        // 圈选代码里用到的 self.xxx 成员，在本类里是怎么定义的（往往在 __init__ 里，不在圈选范围内）
        let memberDefs = memberDefinitions(ocr: ocr, location: loc)
        if !memberDefs.isEmpty {
            lines.append("- 圈选代码用到的成员在本类里的定义（不在圈选范围内，供推断用）：" + memberDefs.joined(separator: "；"))
        }

        // 同文件里的其他顶层定义：帮助理解文件的分工
        let siblings = loc.file.lines.compactMap { definition(in: $0) }.filter { $0.indent == 0 }.map(\.name)
            .filter { $0 != loc.symbols.first }
        if !siblings.isEmpty {
            lines.append("- 同一文件里的其他顶层定义：\(siblings.prefix(8).joined(separator: "、"))")
        }

        // 两层调用链：外层符号被谁用 -> 那个地方又被谁用
        var seen = Set(loc.symbols)
        var frontier = [loc.symbols.first].compactMap { $0 }
        for depth in 1...2 {
            var next: [String] = []
            for symbol in frontier {
                let refs = references(of: symbol, files: files, limit: 4)
                    .filter { !($0.file.url == loc.file.url && (loc.firstLine...loc.lastLine).contains($0.line)) }
                guard !refs.isEmpty else {
                    if depth == 1 { lines.append("- 项目里没有找到其他地方引用 \(symbol)") }
                    continue
                }
                let described = refs.map { ref -> String in
                    let owner = ref.enclosing.isEmpty ? "文件顶层" : ref.enclosing.joined(separator: " → ")
                    return "\(ref.file.relativePath):\(ref.line + 1)（\(owner)）`\(String(ref.text.prefix(100)))`"
                }
                lines.append("- \(symbol) 被使用：" + described.joined(separator: "；"))
                for ref in refs { if let owner = ref.enclosing.first, seen.insert(owner).inserted { next.append(owner) } }
            }
            frontier = Array(next.prefix(3))
        }
        Log.info("项目检索：定位到 \(loc.file.relativePath):\(loc.firstLine + 1)，耗时 \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return lines.joined(separator: "\n")
    }
}
