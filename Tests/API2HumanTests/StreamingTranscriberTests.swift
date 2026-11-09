import XCTest
import AVFoundation
@testable import API2Human

/// 用真实模型跑流式识别（模型不在时跳过）：重点覆盖"同一个识别器跨多轮监听复用"
final class StreamingTranscriberTests: XCTestCase {
    private var modelDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/\(STTModelLocator.modelName)")
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _finals: [String] = []
        var finals: [String] { lock.withLock { _finals } }
        func add(_ e: TranscriptEvent) { if e.isFinal { lock.withLock { _finals.append(e.text) } } }
    }

    private func feed(_ transcriber: StreamingTranscriber) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "question-zh", withExtension: "wav", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            try file.read(into: buf, frameCount: chunk)
            transcriber.accept(buf)
        }
    }

    func testRecognizerKeepsWorkingAcrossSessions() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path), "没有下载模型")
        let recognizer = try SherpaOnnxRecognizer(model: .init(directory: modelDir))
        let collector = Collector()
        let transcriber = StreamingTranscriber(source: .remote, recognizer: recognizer) { collector.add($0) }

        // 第 1 轮：送完音频 -> 停止监听（finish 会调用 InputFinished）
        try feed(transcriber)
        transcriber.finish()
        transcriber.drain()
        let first = collector.finals.joined()
        XCTAssertTrue(first.contains("状态管理"), "第 1 轮：\(first)")

        // 第 2 轮：开始新一轮监听（reset）后再送同样的音频，必须还能识别
        transcriber.reset()
        try feed(transcriber)
        transcriber.finish()
        transcriber.drain()
        let second = collector.finals.dropFirst(collector.finals.count > 1 ? 1 : 0).joined()
        XCTAssertEqual(collector.finals.count, 2, "第 2 轮没有产出结果：\(collector.finals)")
        XCTAssertTrue(second.contains("状态管理"), "第 2 轮：\(second)")
    }
}
