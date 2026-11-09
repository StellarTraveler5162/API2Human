import XCTest
import AVFoundation
@testable import API2Human

/// 配置、语音识别文字清理、资料导入等小工具
final class UtilityTests: XCTestCase {
    private func config(_ base: String) -> LLMConfig {
        LLMConfig(baseURL: base, authToken: "t", model: "m")
    }

    func testMessagesURLNormalization() {
        for base in ["https://api.deepseek.com/anthropic", "https://api.deepseek.com/anthropic/",
                     "https://api.deepseek.com/anthropic/v1", "  https://api.deepseek.com/anthropic/v1/  "] {
            XCTAssertEqual(config(base).messagesURL?.absoluteString, "https://api.deepseek.com/anthropic/v1/messages", base)
        }
    }

    func testTranscriptCleanup() {
        XCTAssertEqual(StreamingTranscriber.clean(" 项目， 以及 性能 "), "项目，以及 性能")
        XCTAssertEqual(StreamingTranscriber.clean("你对 React 和 Swift U I 的理解"), "你对 React 和 Swift UI 的理解")
        XCTAssertEqual(StreamingTranscriber.clean("说一下 T C P 三次握手"), "说一下 TCP 三次握手")
        XCTAssertEqual(StreamingTranscriber.clean("I am fine"), "I am fine", "单个字母单词不能被合并")
    }

    func testDownmixAveragesChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for i in 0..<4 {
            buffer.floatChannelData![0][i] = 1
            buffer.floatChannelData![1][i] = 0
        }
        let mono = try XCTUnwrap(StreamingTranscriber.downmix(buffer))
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 4)
        XCTAssertEqual(mono.floatChannelData![0][2], 0.5, accuracy: 1e-6)
    }

    func testDownmixRejectsEmptyBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        XCTAssertNil(StreamingTranscriber.downmix(buffer))
    }

    func testImportTextHandlesGB18030() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-gbk-\(UUID()).txt")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try XCTUnwrap("张三 | 后端工程师".data(using: gb)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try InterviewContext.importText(from: url), "张三 | 后端工程师")
    }

    func testHTMLImportIsPlainTextWithoutWebKit() throws {
        let html = """
        <html><head><style>p{color:red}</style><script>alert(1)</script></head>
        <body><h1>张三</h1><p>后端&amp;架构</p><img src="https://example.com/x.png"><br>Go &lt;熟练&gt;</body></html>
        """
        let t = InterviewContext.plainText(fromHTML: html)
        XCTAssertTrue(t.contains("张三"))
        XCTAssertTrue(t.contains("后端&架构"))
        XCTAssertTrue(t.contains("Go <熟练>"))
        XCTAssertFalse(t.contains("alert"))
        XCTAssertFalse(t.contains("color"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-\(UUID()).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try InterviewContext.importText(from: url).contains("张三"))
    }

    func testImportRejectsUnknownAndHugeFiles() throws {
        let dir = FileManager.default.temporaryDirectory
        let mp4 = dir.appendingPathComponent("a2h-\(UUID()).mp4")
        try Data("x".utf8).write(to: mp4)
        defer { try? FileManager.default.removeItem(at: mp4) }
        XCTAssertThrowsError(try InterviewContext.importText(from: mp4))

        let big = dir.appendingPathComponent("a2h-\(UUID()).txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: big) }
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(InterviewContext.maxImportBytes + 1))   // 稀疏文件，不真占磁盘
        try h.close()
        XCTAssertThrowsError(try InterviewContext.importText(from: big)) { e in
            XCTAssertTrue(e.localizedDescription.contains("太大"), e.localizedDescription)
        }
    }

    func testImportTextRejectsEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-empty-\(UUID()).txt")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try InterviewContext.importText(from: url))
    }
}

final class RecordingFileNameTests: XCTestCase {
    func testRollingFileNamesNeverOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-roll-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 48k -> 16k -> 48k -> 16k：第二次 16k 不能覆盖第一次
        var names: [String] = []
        for rate in [16_000.0, 48_000, 16_000, 16_000] {
            let url = AudioCaptureManager.nextFileURL(in: dir, base: "system", sampleRate: rate)
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            names.append(url.lastPathComponent)
        }
        XCTAssertEqual(names, ["system-16000Hz.wav", "system-48000Hz.wav", "system-16000Hz-2.wav", "system-16000Hz-3.wav"])
    }
}

final class MicrophoneTests: XCTestCase {
    func testFirstChannelFollowsBufferSampleRate() throws {
        for rate in [48_000.0, 16_000, 44_100] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            buffer.frameLength = 8
            for i in 0..<8 { buffer.floatChannelData![0][i] = Float(i); buffer.floatChannelData![1][i] = -1 }
            let mono = try XCTUnwrap(MicrophoneCapture.firstChannel(of: buffer), "\(rate)")
            XCTAssertEqual(mono.format.sampleRate, rate)
            XCTAssertEqual(mono.format.channelCount, 1)
            XCTAssertEqual(mono.floatChannelData![0][5], 5)
        }
    }
}

final class TranscriptCorrectionTests: XCTestCase {
    func testCommonInterviewMisrecognitionsAreFixed() {
        XCTAssertEqual(StreamingTranscriber.clean("说一下 TCP 三四握手和四次挥手的过程"), "说一下 TCP 三次握手和四次挥手的过程")
        XCTAssertEqual(StreamingTranscriber.clean("说一下进城和县城的区别"), "说一下进程和线程的区别")
        XCTAssertEqual(StreamingTranscriber.clean("说一下晋城和县城的区别"), "说一下进程和线程的区别")
    }

    func testAmbiguousWordsAreLeftAlone() {
        XCTAssertEqual(StreamingTranscriber.clean("我之前在携程做后端"), "我之前在携程做后端")
        XCTAssertEqual(StreamingTranscriber.clean("周末去县城看了看"), "周末去县城看了看")
    }
}

final class HotwordsTests: XCTestCase {
    func testEncodeSpacesCJKOnly() {
        XCTAssertEqual(Hotwords.encodeForModel("进程"), "进 程")
        XCTAssertEqual(Hotwords.encodeForModel("三次握手"), "三 次 握 手")
        XCTAssertEqual(Hotwords.encodeForModel("B+树"), "B+ 树")
        XCTAssertEqual(Hotwords.encodeForModel("Redis"), "Redis")
    }

    func testSkillLinesExtractChineseTerms() {
        let card = """
        ## 技能边界
        - 熟练：Go、MySQL（分库分表、慢查询优化）、Redis
        - 用过：Java/Spring Boot、RocketMQ、链路追踪
        - 了解或没用过：Kafka（只看过原理）、Kubernetes（只会写 yaml 部署）
        我负责履约调度系统
        """
        XCTAssertEqual(Hotwords.fromSkillLines(card), ["分库分表", "慢查询优化", "链路追踪"])
    }

    func testHedgesOnlyFilteredInsideParentheses() {
        let card = """
        - 熟练：简单工厂模式、只读事务
        - 用过：做过大型项目、Redis（简单用过）
        """
        XCTAssertEqual(Hotwords.fromSkillLines(card), ["简单工厂模式", "只读事务"])
    }

    func testListDedupsAndCaps() {
        let list = Hotwords.list(context: "- 熟练：进程、自研网关")
        XCTAssertEqual(list.filter { $0 == "进程" }.count, 1)
        XCTAssertTrue(list.contains("自研网关"))
        XCTAssertLessThanOrEqual(list.count, Hotwords.maxCount)
    }

    /// 有歧义的纠错只在技术语境里生效，不误伤日常说法
    func testAmbiguousCorrectionsNeedContext() {
        XCTAssertEqual(StreamingTranscriber.clean("你了解多县城吗"), "你了解多线程吗")
        XCTAssertEqual(StreamingTranscriber.clean("我们去了很多县城"), "我们去了很多县城")
        XCTAssertEqual(StreamingTranscriber.clean("那么多县城都跑过了"), "那么多县城都跑过了")
        XCTAssertEqual(StreamingTranscriber.clean("怎么保证县城安全"), "怎么保证线程安全")
        XCTAssertEqual(StreamingTranscriber.clean("这个县城安全吗"), "这个县城安全吗")
        XCTAssertEqual(StreamingTranscriber.clean("他冲我三次挥手"), "他冲我三次挥手")
        XCTAssertEqual(StreamingTranscriber.clean("多线程下怎么避免死所"), "多线程下怎么避免死锁")
        XCTAssertEqual(StreamingTranscriber.clean("县城池塘边"), "县城池塘边")
        for normal in ["较多县城还没通高铁", "大多县城都有", "差不多县城的规模", "越来越多县城", "这些县城安全问题不少", "Google 在很多县城都有"] {
            XCTAssertEqual(StreamingTranscriber.clean(normal), normal, normal)
        }
        XCTAssertEqual(StreamingTranscriber.clean("说一下多县城"), "说一下多线程")
        XCTAssertEqual(StreamingTranscriber.clean("多县城编程要注意什么"), "多线程编程要注意什么")
        XCTAssertEqual(StreamingTranscriber.clean("Go 里怎么保证县城安全"), "Go 里怎么保证线程安全")
    }

    /// 纠错规则的正则写错时 range(of:options:.regularExpression) 只会返回 nil，规则悄悄失效：逐条编译确认
    func testAllCorrectionAnchorsCompile() {
        for c in StreamingTranscriber.contextualCorrections {
            XCTAssertNoThrow(try NSRegularExpression(pattern: c.anchor), "\(c.wrong) 的锚点正则无效：\(c.anchor)")
        }
        XCTAssertEqual(StreamingTranscriber.clean("用 Golang 写的服务怎么避免死所"), "用 Golang 写的服务怎么避免死锁")
        XCTAssertEqual(StreamingTranscriber.clean("Google 那边的县城池子"), "Google 那边的县城池子", "Go 不能命中 Google")
        XCTAssertEqual(StreamingTranscriber.clean("CPU 密集的县城池怎么配"), "CPU 密集的线程池怎么配")
        XCTAssertEqual(StreamingTranscriber.clean("TCP 能不能三次挥手"), "TCP 能不能三次挥手", "三次挥手本身是一道题，不能改")
    }

    /// 第三轮：中文里紧挨着的英文锚点、常见问法都要纠正；数量词开头的"多县城"保持原样
    func testCommonInterviewPhrasingsAreCorrected() {
        let fixes = [
            ("用Go语言写多县城", "用Go语言写多线程"),
            ("什么是死所", "什么是死锁"), ("你了解县城池吗", "你了解线程池吗"), ("什么是县城安全", "什么是线程安全"),
            ("用Go写多县城", "用Go写多线程"), ("多县城有什么问题", "多线程有什么问题"), ("如何实现多县城", "如何实现多线程"),
            ("多县城的好处", "多线程的好处"),
        ]
        for (wrong, right) in fixes { XCTAssertEqual(StreamingTranscriber.clean(wrong), right, wrong) }
        for normal in ["较多县城的人口", "大多县城的风景", "差不多县城那么大", "这个县城安全吗", "县城池塘边", "他冲我三次挥手"] {
            XCTAssertEqual(StreamingTranscriber.clean(normal), normal, normal)
        }
    }

    func testCoroutineCorrection() {
        XCTAssertEqual(StreamingTranscriber.clean("说说携程和县城有什么不同"), "说说协程和线程有什么不同")
        XCTAssertEqual(StreamingTranscriber.clean("我订了携程的机票"), "我订了携程的机票")
    }
}

final class MicWAVTests: XCTestCase {
    /// 双声道麦克风：回调送来的是 firstChannel 拷出的单声道，单声道文件必须能写进去
    func testStereoMicFirstChannelWritesToMonoFile() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480))
        buf.frameLength = 480
        for i in 0..<960 { buf.floatChannelData![0][i] = i % 2 == 0 ? 0.5 : -0.5 }
        let mono = try XCTUnwrap(MicrophoneCapture.firstChannel(of: buf))
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.floatChannelData![0][3], 0.5, "只取第一个声道")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-mic-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let monoFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let file = try AudioCaptureManager.makeWAV(at: url, format: monoFormat)
        XCTAssertNoThrow(try file.write(from: mono))
        XCTAssertEqual(file.length, 480)
    }
}

@MainActor
final class SpeechServiceTests: XCTestCase {
    /// 被 stop 的旧条目的结束回调晚到：不能把新条目的"正在播"改掉
    func testLateEndOfOldUtteranceIsIgnored() {
        let speech = SpeechService()
        speech.speak("第一条")
        speech.speak("第二条")   // 内部先 stop 第一条
        speech.utteranceEnded(AVSpeechUtterance(string: "别的"))
        XCTAssertTrue(speech.isSpeaking)
        speech.stop()
        XCTAssertFalse(speech.isSpeaking)
    }
}

final class LogTests: XCTestCase {
    func testLogFileIsPrivateAndRotates() throws {
        Log.info("权限检查")
        Log.flush()
        let perms = try FileManager.default.attributesOfItem(atPath: Log.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "日志含面试原文，只给本人读写")

        defer { Log.setMaxBytes(5 * 1024 * 1024) }
        Log.setMaxBytes(1)        // 下一行写完就轮转
        Log.info("触发轮转")
        Log.flush()
        Log.setMaxBytes(5 * 1024 * 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Log.rotatedURL.path))
        let rotated = try String(contentsOf: Log.rotatedURL, encoding: .utf8)
        XCTAssertTrue(rotated.contains("触发轮转"))
        Log.info("轮转后继续写")
        Log.flush()
        XCTAssertTrue(try String(contentsOf: Log.url, encoding: .utf8).contains("轮转后继续写"))
    }
}

final class ReadingOrderTests: XCTestCase {
    func testRowsTopToBottomThenLeftToRight() {
        // 两行：上行 y≈0.8（右边的框略低 0.005，仍算同一行），下行 y=0.5
        let boxes = [CGRect(x: 0.5, y: 0.795, width: 0.1, height: 0.01),   // 上行右
                     CGRect(x: 0.1, y: 0.495, width: 0.1, height: 0.01),   // 下行左
                     CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.01)]     // 上行左
        XCTAssertEqual(TextRecognizer.readingOrder(boxes), [2, 0, 1])
    }

    /// 很高的选区：每行只占 0.008 高、行距 0.009，固定 0.01 的容差会把相邻行并起来
    func testTallSelectionKeepsAdjacentLinesApart() {
        let lines = (0..<6).map { i in CGRect(x: i % 2 == 0 ? 0.3 : 0.05, y: 0.9 - Double(i) * 0.009, width: 0.2, height: 0.008) }
        XCTAssertEqual(TextRecognizer.readingOrder(lines), [0, 1, 2, 3, 4, 5])
    }

    func testDenseChainDoesNotScramble() {
        // 一串每次只低 0.006 的框：旧比较器在这里不满足传递性；新算法输出必须是确定的从上到下
        let boxes = (0..<20).map { CGRect(x: Double($0 % 3) * 0.3, y: 0.9 - Double($0) * 0.006, width: 0.1, height: 0.004) }
        let order = TextRecognizer.readingOrder(boxes.shuffled())
        XCTAssertEqual(order.count, 20)
        XCTAssertEqual(Set(order).count, 20)
    }
}
