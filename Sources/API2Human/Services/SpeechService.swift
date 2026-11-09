import AVFoundation
import NaturalLanguage
import Observation

/// "Say" 按钮背后的系统 TTS。
/// 注意：TTS 从扬声器播出后会被系统音频采集到 —— Step 2 里会通过
/// "排除本进程音频"（SCStreamConfiguration.excludesCurrentProcessAudio / Process Tap 排除自身 PID）解决。
@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// 正在播的那一条：被 stop 掉的旧条目的 didCancel 可能晚到，不能把新条目的状态改成"没在播"
    /// 持有对象本身（不存 ObjectIdentifier：旧对象释放后地址可能被新对象复用）
    @ObservationIgnored private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let cleaned = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        if let lang = NLLanguageRecognizer.dominantLanguage(for: cleaned) {
            let code = lang == .simplifiedChinese ? "zh-CN" : lang.rawValue
            utterance.voice = AVSpeechSynthesisVoice(language: code)
        }
        current = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        // 刚 speak 完 synthesizer.isSpeaking 可能还是 false：只看它的话，马上按 Stop 会什么都不做
        guard isSpeaking || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        current = nil
        isSpeaking = false
    }

    /// 某一条播完或被取消：只有它还是当前条目时才更新状态
    func utteranceEnded(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        isSpeaking = false
    }

    // MARK: AVSpeechSynthesizerDelegate（回调线程不确定，回主线程更新状态）

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        nonisolated(unsafe) let u = u   // AVSpeechUtterance 不是 Sendable；只在主线程上拿来比较身份
        Task { @MainActor in self.utteranceEnded(u) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        nonisolated(unsafe) let u = u
        Task { @MainActor in self.utteranceEnded(u) }
    }
}
