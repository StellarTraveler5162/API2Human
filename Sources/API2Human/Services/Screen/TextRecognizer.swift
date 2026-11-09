import Vision
import CoreGraphics
import Foundation

/// 本机文字识别（Vision）：圈选区域 -> 纯文本，不联网。
///
/// 实测三类截图（M4）：
/// | 方式           | 纯代码       | 中文题目     | 代码 + 中文注释/字符串 |
/// | 英文优先       | ✅ 逐字正确  | ❌ 中文全乱码 | ❌ 中文乱码           |
/// | 中文优先       | ❌ 全角括号、q→9、bool→boo1 | ✅ | 中文对，代码符号错 |
/// | 自动检测语言   | ✅           | ✅           | 代码和注释对，中文字符串"结果："→"Æ:" |
/// 所以：主结果用自动检测；如果"中文优先"多认出了汉字（自动检测漏了中文），两份都交给模型对照。
/// 冷启动每种识别约 14 秒（加载模型），之后 0.1~0.2 秒，App 启动时预热。
enum TextRecognizer {
    private static let warmLock = NSLock()
    nonisolated(unsafe) private static var _isWarm = false
    /// 识别模型已经加载过（预热完成或成功识别过一次）：之后每次只要 0.1~0.2 秒
    static var isWarm: Bool { warmLock.withLock { _isWarm } }

    private static func run(_ image: CGImage, languages: [String]?) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false        // 代码和变量名不要被"纠正"
        if let languages {
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        // 从上到下、从左到右，保留行序（缩进识别不出来）
        let results = request.results ?? []
        return readingOrder(results.map(\.boundingBox))
            .compactMap { results[$0].topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 阅读顺序（返回下标）：按 midY 从上到下分行（和这一行第一个框差不到容差算同一行），行内从左到右。
    /// 容差默认取"文字框高度中位数的一半"：坐标是相对选区归一化的，固定 0.01 在很高的选区里会大过行高、把相邻两行并成一行
    /// 不能直接用"差不多就比 X"的比较器排序：那不是严格弱序，密集排版时行序会乱
    /// Vision 坐标原点在左下，midY 越大越靠上
    static func readingOrder(_ boxes: [CGRect], rowTolerance: CGFloat? = nil) -> [Int] {
        let heights = boxes.map(\.height).sorted()
        let tolerance = rowTolerance ?? (heights.isEmpty ? 0 : heights[heights.count / 2] * 0.5)
        let byY = boxes.indices.sorted { boxes[$0].midY > boxes[$1].midY }
        var rows: [[Int]] = []
        var rowY: CGFloat = .infinity
        for i in byY {
            if rows.isEmpty || rowY - boxes[i].midY > tolerance {
                rows.append([i])
                rowY = boxes[i].midY
            } else {
                rows[rows.count - 1].append(i)
            }
        }
        return rows.flatMap { $0.sorted { boxes[$0].minX < boxes[$1].minX } }
    }

    private static func hanCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }

    /// 返回给模型看的文字：主结果，必要时附上"中文优先"的结果
    static func recognize(_ image: CGImage) async throws -> String {
        async let auto = Task.detached(priority: .userInitiated) { try run(image, languages: nil) }.value
        async let chinese = Task.detached(priority: .userInitiated) { try run(image, languages: ["zh-Hans", "en-US"]) }.value
        // 中文优先那一遍只是补充：它出错不能让整个 OCR 失败
        let primary = try await auto
        let zh = (try? await chinese) ?? ""
        warmLock.withLock { _isWarm = true }
        guard hanCount(zh) > hanCount(primary) else { return primary }
        // 只附上含汉字的行：中文优先识别的代码符号错误很多（全角括号、0→e），不给模型制造"假 bug"
        let chineseLines = zh.split(separator: "\n").filter { hanCount(String($0)) > 0 }.joined(separator: "\n")
        return primary + "\n\n（以下几行是同一区域里的中文，按中文优先重新识别，中文内容以这里为准）\n" + chineseLines
    }

    /// 启动时用一张小图预热两种识别，避免第一次圈选等十几秒
    static func warmUp() {
        Task.detached(priority: .background) {
            let width = 160, height = 40
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = ctx.makeImage() else { return }
            let t = ContinuousClock.now
            _ = try? await recognize(image)
            Log.info("OCR 预热完成：\(ContinuousClock.now - t)")
        }
    }
}
