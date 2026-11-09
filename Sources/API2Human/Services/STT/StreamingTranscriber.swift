import AVFoundation

/// 一路音频的流式转写：任意格式 PCM -> 单声道 16kHz -> sherpa-onnx -> partial / final 事件。
///
/// - `accept(_:)` 可在音频回调线程调用：只拷贝采样，然后丢给自己的串行队列，
///   重采样和解码都不在音频线程里做，不会卡住采集。
/// - 遇到停顿（端点检测）发 final，否则文字有变化就发 partial。
final class StreamingTranscriber: @unchecked Sendable {
    typealias Handler = @Sendable (TranscriptEvent) -> Void

    let source: AudioSource
    private let queue: DispatchQueue
    private let recognizer: SherpaOnnxRecognizer
    private let handler: Handler

    // 以下只在 queue 上访问
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0
    private var lastPartial = ""
    private var session = 0

    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: Double(SherpaOnnxRecognizer.sampleRate),
                                                    channels: 1, interleaved: false)!

    init(source: AudioSource, recognizer: SherpaOnnxRecognizer, handler: @escaping Handler) {
        self.source = source
        self.recognizer = recognizer
        self.handler = handler
        self.queue = DispatchQueue(label: "com.api2human.stt.\(source)", qos: .userInitiated)
    }

    /// 任意线程。buffer 可能是 bufferListNoCopy 的（回调结束就失效），所以这里先拷贝成单声道。
    func accept(_ buffer: AVAudioPCMBuffer) {
        // 拷贝出来的新 buffer 只交给队列使用，不再被其他线程碰
        guard let mono = Self.downmix(buffer).map(OwnedBuffer.init) else { return }
        queue.async { [self] in process(mono.buffer) }
    }

    /// 停止监听时调用：把最后半句也识别完并作为 final 发出
    func finish() {
        queue.async { [self] in
            // 流式模型要"看到"句尾之后一段音频才能解出最后一个词；实时场景里停顿自然提供了，
            // 停止监听时音频戛然而止，补 2 秒静音，否则最后一个字会丢（实测 0.8s 仍会丢"过程"的"程"，2s 稳定；多解码约 80ms）
            let padding = [Float](repeating: 0, count: Int(SherpaOnnxRecognizer.sampleRate) * 2)
            padding.withUnsafeBufferPointer { recognizer.accept($0) }
            recognizer.inputFinished()
            emitFinal(recognizer.text)
            recognizer.restartStream()     // InputFinished 之后旧 stream 不能再用
            converter?.reset()
        }
    }

    /// 开始新一轮监听前清空状态（上一轮剩下的半句话丢掉）
    func reset(session newSession: Int = 0) {
        queue.async { [self] in
            session = newSession
            recognizer.restartStream()
            converter = nil
            lastPartial = ""
        }
    }

    /// 等队列里已排队的工作全部跑完（测试用）
    func drain() { queue.sync {} }

    // MARK: - 队列内

    private func process(_ mono: AVAudioPCMBuffer) {
        guard let pcm = resample(mono), let data = pcm.floatChannelData else { return }
        recognizer.accept(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)))

        let text = recognizer.text
        if recognizer.isEndpoint {
            emitFinal(text)
            recognizer.reset()
        } else if text != lastPartial {
            lastPartial = text
            handler(TranscriptEvent(source: source, text: Self.clean(text), isFinal: false, session: session))
        }
    }

    private func emitFinal(_ raw: String) {
        let text = Self.clean(raw)
        lastPartial = ""
        if !text.isEmpty {
            handler(TranscriptEvent(source: source, text: text, isFinal: true, session: session))
        } else {
            // 一句话结束但没识别出字（噪音/咳嗽）：发一个空 partial 让 UI 清掉临时文字
            handler(TranscriptEvent(source: source, text: "", isFinal: false, session: session))
        }
    }

    private func resample(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inRate = mono.format.sampleRate
        if inRate == Self.targetFormat.sampleRate { return mono }

        if converter == nil || converterInputRate != inRate {
            converter = AVAudioConverter(from: mono.format, to: Self.targetFormat)
            converterInputRate = inRate
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(Double(mono.frameLength) * Self.targetFormat.sampleRate / inRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }

        // 流式转换：每次只喂这一块，然后告诉 converter "暂时没数据了"，它会保留滤波器状态
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return mono
        }
        if status == .error {
            Log.info("重采样失败 \(error?.localizedDescription ?? "")")
            return nil
        }
        return out
    }

    // MARK: - 工具

    /// 多声道平均成单声道 Float32（同时完成拷贝）
    static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard n > 0, channels > 0, let src = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData?[0] else { return nil }

        if channels == 1 {
            dst.update(from: src[0], count: n)
        } else if buffer.format.isInterleaved {
            let p = src[0]
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += p[i * channels + c] }
                dst[i] = sum * scale
            }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[i] = sum * scale
            }
        }
        out.frameLength = AVAudioFrameCount(n)
        return out
    }

    /// 模型输出的小毛病：
    /// - 中文标点后带空格："项目， 以及" -> "项目，以及"
    /// - 缩写被拆成单字母："Swift U I" -> "Swift UI"，"T C P" -> "TCP"
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"([，。？！、；：])\s+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\b[A-Z]) (?=[A-Z]\b)"#, with: "", options: .regularExpression)
        for (wrong, right) in corrections { t = t.replacingOccurrences(of: wrong, with: right) }
        // "县城池塘""县城池子"是正常说法，其余"县城池"都是线程池
        t = t.replacingOccurrences(of: "县城池(?![塘子])", with: "线程池", options: .regularExpression)
        for c in contextualCorrections where t.contains(c.wrong) && t.range(of: c.anchor, options: .regularExpression) != nil {
            t = t.replacingOccurrences(of: c.wrong, with: c.right)
        }
        return t
    }

    /// 面试里常见、且没有歧义的识别错误（整词组替换；单独的"进城"等可能是正常说法的词不动）。
    /// 热词（见 Hotwords）纠不过来的同音错误，按上下文做文本纠错
    /// 单独出现也可能是正常说法的（"很多县城""县城安全吗""挥手三次"）：同一句里有技术词才改
    static let contextualCorrections: [(wrong: String, right: String, anchor: String)] = {
        // 英文词前后不能是字母（"Go" 不命中 "Google"）。不用 \b：ICU 把汉字也当单词字符，"TCP的""用Go语言" 里 \b 不成立
        func en(_ words: String) -> String { #"(?<![A-Za-z])("# + words + #")(?![A-Za-z])"# }
        let concurrency = "(?i)线程|进程|协程|并发|锁|异步|内存|编程|调度|HashMap|单例|" + en("cpu|java|go|golang")
        let asking = "什么是|为什么|如何|怎么|说说|说一下|讲讲|讲一下|聊聊|介绍一下|了解|熟悉|请问"
        // "多线程"常被单独问：认问法和技术后缀；前面是数量词的（很多/较多/大多/差不多/越来越多……县城）是正常说法
        let manyThreads = "(" + asking + "|用过|实现)[^，。？！]{0,4}多县城"
            + "|(?<![很许好太么更最较大诸过挺不再越差少])多县城(是什么|怎么|吗|的|有|和|与|编程|并发|模型|环境|下|场景|[。？?！]|$)"
        return [
            // 不纠"三次挥手"：TCP 能不能三次挥手本身就是一道面试题，改成"四次"会把问题意思改反
            ("多县城", "多线程", concurrency + "|" + manyThreads),
            ("县城安全", "线程安全", concurrency + "|保证|集合|容器|" + asking),
        ]
    }()

    static let corrections: [(String, String)] = [
        ("三四握手", "三次握手"), ("四四挥手", "四次挥手"),
        ("进城和县城", "进程和线程"), ("晋城和县城", "进程和线程"), ("进城与县城", "进程与线程"),
        ("进城和线程", "进程和线程"), ("进程和县城", "进程和线程"),
        ("携程和线程", "协程和线程"), ("线程和携程", "线程和协程"),
        ("携程和县城", "协程和线程"), ("县城和携程", "线程和协程"), ("进程和携程", "进程和协程"), ("死所", "死锁"), ("哈西表", "哈希表"), ("红黑书", "红黑树"),
        ("B加树", "B+树"), ("B 加树", "B+树"), ("索引下推", "索引下推"), ("分布式所", "分布式锁"),
        ("消息对列", "消息队列"), ("缓存击穿", "缓存击穿"), ("缓存穿透", "缓存穿透"), ("负载均很", "负载均衡"),
        ("rate limit of the republic", "rate limiter for a public"),
    ].filter { $0.0 != $0.1 }
}

private struct OwnedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// 模型位置：App 包内 Resources/Models，或 ~/Library/Application Support/API2Human/Models
enum STTModelLocator {
    static let modelName = "sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"

    static func locate() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["A2H_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: override))   // 调试：换模型对比
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Models/\(modelName)"))
        }
        candidates.append(AudioCaptureManager.recordingsRoot.deletingLastPathComponent()
            .appendingPathComponent("Models/\(modelName)"))
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }
        throw STTError.modelMissing(candidates.map(\.path).joined(separator: " 或 "))
    }

    /// 加载约 170MB 模型，耗时几百毫秒，不要在主线程调用
    static func makeRecognizer(hotwords: [String] = []) throws -> SherpaOnnxRecognizer {
        try SherpaOnnxRecognizer(model: .init(directory: try locate()), hotwords: hotwords)
    }
}
