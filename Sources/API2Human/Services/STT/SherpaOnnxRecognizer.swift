import Foundation
import CSherpaOnnx

/// sherpa-onnx 流式识别器的薄封装（C API）。
/// 非线程安全：只能在同一个串行队列上使用（由 StreamingTranscriber 保证），
/// 标 @unchecked Sendable 只是为了能把它从加载线程交给那个队列。
final class SherpaOnnxRecognizer: @unchecked Sendable {
    struct ModelFiles {
        let encoder: URL
        let decoder: URL
        let joiner: URL
        let tokens: URL
        /// 热词需要的 BPE 词表（由 bpe.model 导出；没有就不能用热词）
        let bpeVocab: URL?

        /// 目录里按文件名找：encoder*.onnx / decoder*.onnx / joiner*.onnx / tokens.txt（优先 int8）
        init(directory: URL) throws {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            func pick(_ prefix: String) throws -> URL {
                let candidates = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".onnx") }.sorted()
                guard let name = candidates.first(where: { $0.contains("int8") }) ?? candidates.first else {
                    throw STTError.modelMissing("\(directory.lastPathComponent)/\(prefix)*.onnx")
                }
                return directory.appendingPathComponent(name)
            }
            encoder = try pick("encoder")
            decoder = try pick("decoder")
            joiner = try pick("joiner")
            tokens = directory.appendingPathComponent("tokens.txt")
            let vocab = directory.appendingPathComponent("bpe.vocab")
            bpeVocab = FileManager.default.fileExists(atPath: vocab.path) ? vocab : nil
            guard FileManager.default.fileExists(atPath: tokens.path) else {
                throw STTError.modelMissing("\(directory.lastPathComponent)/tokens.txt")
            }
        }
    }

    struct Endpoint {
        /// 还没识别出任何字时，静音多久算一句结束
        var silenceBeforeSpeech: Float = 2.4
        /// 识别出字之后，静音多久算一句结束（面试官提问中途停顿通常 < 1s）
        var silenceAfterSpeech: Float = 1.0
        /// 一句最长多少秒，超过强制断句
        var maxUtterance: Float = 30
    }

    static let sampleRate: Int32 = 16_000

    private let recognizer: OpaquePointer
    private var stream: OpaquePointer

    /// - hotwords: 热词（技术术语等），识别时提高这些词的概率；需要模型目录里有 bpe.vocab
    init(model: ModelFiles, endpoint: Endpoint = .init(), threads: Int32 = 2,
         hotwords: [String] = [], hotwordScore: Float = Hotwords.defaultScore) throws {
        // C 字符串在 Create 调用期间必须有效，调用后由 sherpa 自己拷贝
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = Self.sampleRate
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(model.encoder.path)
        config.model_config.transducer.decoder = c(model.decoder.path)
        config.model_config.transducer.joiner = c(model.joiner.path)
        config.model_config.tokens = c(model.tokens.path)
        config.model_config.num_threads = threads
        config.model_config.provider = c("cpu")
        config.model_config.debug = 0
        // 热词只在 modified_beam_search 下生效；没有热词时用更快的 greedy_search
        let words = hotwords.map(Hotwords.encodeForModel).filter { !$0.isEmpty }
        if !words.isEmpty, let vocab = model.bpeVocab {
            config.decoding_method = c("modified_beam_search")
            config.model_config.modeling_unit = c("bpe")
            config.model_config.bpe_vocab = c(vocab.path)
            let buf = words.joined(separator: "\n")
            config.hotwords_buf = c(buf)
            config.hotwords_buf_size = Int32(buf.utf8.count)
            config.hotwords_score = hotwordScore
        } else {
            config.decoding_method = c("greedy_search")
        }
        config.max_active_paths = 4
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = endpoint.silenceBeforeSpeech
        config.rule2_min_trailing_silence = endpoint.silenceAfterSpeech
        config.rule3_min_utterance_length = endpoint.maxUtterance

        guard let r = SherpaOnnxCreateOnlineRecognizer(&config) else {
            throw STTError.initFailed("创建识别器失败，检查模型文件：\(model.encoder.deletingLastPathComponent().path)")
        }
        guard let s = SherpaOnnxCreateOnlineStream(r) else {
            SherpaOnnxDestroyOnlineRecognizer(r)
            throw STTError.initFailed("创建识别流失败")
        }
        recognizer = r
        stream = s
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    /// 送入 16kHz 单声道 [-1, 1] 采样，并尽可能多地解码
    func accept(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Self.sampleRate, base, Int32(samples.count))
        decodeReady()
    }

    /// 输入结束（停止监听时）：把缓冲里剩下的音频解码完
    func inputFinished() {
        SherpaOnnxOnlineStreamInputFinished(stream)
        decodeReady()
    }

    var text: String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let t = result.pointee.text else { return "" }
        return String(cString: t)
    }

    var isEndpoint: Bool { SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 }

    /// 一句结束后重置，开始下一句（同一轮监听内）
    func reset() { SherpaOnnxOnlineStreamReset(recognizer, stream) }

    /// 新一轮监听：重建识别流。c-api.h 规定 InputFinished 之后不能再往同一个 stream 送数据，
    /// 当前版本 Reset 恰好也能恢复，但不依赖这个实现细节。重建 stream 不需要重新加载模型。
    func restartStream() {
        guard let fresh = SherpaOnnxCreateOnlineStream(recognizer) else {
            Log.info("重建识别流失败，退回 Reset")
            reset()
            return
        }
        SherpaOnnxDestroyOnlineStream(stream)
        stream = fresh
    }

    private func decodeReady() {
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
    }
}

enum STTError: LocalizedError {
    case modelMissing(String)
    case initFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let what): "找不到语音识别模型：\(what)"
        case .initFailed(let why): why
        }
    }
}
