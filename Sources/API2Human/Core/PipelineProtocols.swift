import Foundation
import AVFoundation

// 后续步骤的可插拔接口，Step 1 只定义契约，不实现。

/// 音频来源：区分"对方（系统声音）"和"我（麦克风）"，STT 只把 .remote 的话当作问题。
enum AudioSource: Sendable { case remote, local }

struct AudioChunk: @unchecked Sendable {
    let source: AudioSource
    let buffer: AVAudioPCMBuffer   // 统一重采样到 16kHz / mono / Float32
    let hostTime: UInt64
}

/// Step 2：系统音频（Core Audio Process Tap / ScreenCaptureKit）+ 麦克风（AVAudioEngine + VoiceProcessing）
protocol AudioCaptureService: AnyObject, Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    func start() async throws
    func stop() async
    func setMicMuted(_ muted: Bool)
}

struct TranscriptEvent: Sendable {
    let source: AudioSource
    let text: String
    let isFinal: Bool          // partial 用于实时显示，final 才触发 LLM
    var session = 0            // 产生它的监听轮次：上一轮晚到的结果不能混进新一轮
}

/// Step 3：可插拔 STT（Apple SpeechAnalyzer / OpenAI Realtime / Deepgram / whisper.cpp）
protocol STTProvider: Sendable {
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error>
}

struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String
}

/// Step 4：流式 LLM（Anthropic / OpenAI），每次 yield 一个增量文本片段
protocol LLMProvider: Sendable {
    func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}
