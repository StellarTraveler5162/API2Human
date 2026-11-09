import Foundation

/// 面试中接口抖一下不能让 Reply 框只剩一行错误：
/// 出字之前遇到可重试的错误（429 / 5xx / 过载 / 网络错误 / 迟迟不出字），先在主接口重试一次，再换备用接口。
/// 已经出了字就不再重试（否则你正在看的回答会被换掉），直接把错误抛出去。
struct ResilientProvider: LLMProvider {
    let attempts: [(label: String, provider: any LLMProvider)]
    /// attempts 里从这个下标起是备用接口。主接口 Key 失效 / 余额不足（401/402/403）时直接跳过去，不在主接口上重试
    var fallbackStart: Int?
    /// 个别接口单独的首字超时（备用接口开不开思考可能和主接口不同），没写的用 firstChunkTimeout
    var timeoutOverrides: [Int: Duration] = [:]
    /// 多久没出第一个字就当作失败、换下一个
    var firstChunkTimeout: Duration = .seconds(12)
    /// 重试前等一下，避开瞬时的限流
    var retryDelay: Duration = .milliseconds(400)
    /// 每次重试或切换时回调（顶栏显示"重试中"）
    var onRetry: (@Sendable (String) -> Void)?

    static let primaryRetryLabel = "主接口重试"

    /// App 和 --selftest-llm 共用的组装：主接口 → 主接口重试 → 备用（llm.json 的 fallback）。
    /// 首字超时按各自是否思考放宽；Key / 余额问题直接跳到备用
    static func chain(for config: LLMConfig, baseTimeout: Duration = .seconds(12),
                      make: (LLMConfig) -> any LLMProvider) -> ResilientProvider {
        var attempts: [(label: String, provider: any LLMProvider)] = [("主接口", make(config)), (primaryRetryLabel, make(config))]
        let fallbackStart = attempts.count
        var p = ResilientProvider(attempts: attempts)
        if let fb = config.fallbackConfig {
            attempts.append(("备用 \(fb.model)", make(fb)))
            p = ResilientProvider(attempts: attempts)
            p.fallbackStart = fallbackStart
            p.timeoutOverrides[fallbackStart] = firstChunkTimeout(thinking: fb.thinking, base: baseTimeout)
        }
        p.firstChunkTimeout = firstChunkTimeout(thinking: config.thinking, base: baseTimeout)
        return p
    }

    /// 开了思考的模型先"想"再出字（思考内容不算出字），首字超时要放宽，否则会误判超时、白白重试
    static func firstChunkTimeout(thinking: Bool?, base: Duration) -> Duration {
        thinking == true ? max(base, .seconds(60)) : base
    }

    func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let attempts = attempts, timeout = firstChunkTimeout, delay = retryDelay, onRetry = onRetry
        let fallbackStart = fallbackStart, overrides = timeoutOverrides
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = LLMError.api("没有可用的模型接口")
                var skipTo = 0
                for (i, attempt) in attempts.enumerated() {
                    if i < skipTo { continue }
                    if i > 0 {
                        onRetry?(attempt.label)
                        Log.info("LLM 重试（\(attempt.label)）：上次 \(lastError.localizedDescription)")
                        try? await Task.sleep(for: delay)
                    }
                    if Task.isCancelled { break }
                    let started = FirstChunkFlag()
                    do {
                        try await Self.run(attempt.provider, system: system, history: history, timeout: overrides[i] ?? timeout,
                                           firstChunk: started) { continuation.yield($0) }
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled || error is CancellationError { break }
                        if !started.value, let fb = fallbackStart, i < fb, Self.isAccountError(error) {
                            lastError = error
                            skipTo = fb
                            continue
                        }
                        if started.value || !Self.isRetryable(error) {
                            continuation.finish(throwing: error)
                            return
                        }
                        lastError = error
                    }
                }
                continuation.finish(throwing: Task.isCancelled ? CancellationError() : lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 读一路流；第一个字在 timeout 内没到就抛 firstChunkTimeout
    private static func run(_ provider: any LLMProvider, system: String, history: [ChatTurn], timeout: Duration,
                            firstChunk: FirstChunkFlag, yield: @escaping @Sendable (String) -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await chunk in provider.streamReply(system: system, history: history) {
                    try Task.checkCancellation()
                    firstChunk.set()
                    yield(chunk)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if !firstChunk.value { throw ResilienceError.firstChunkTimeout(timeout) }
                try await Task.sleep(for: .seconds(1_000_000))   // 已经出字：不再计时，等主任务结束
            }
            try await group.next()
            group.cancelAll()
        }
        // 正常结束却一个字都没有：当失败处理（可重试），别让 Reply 框空着
        if !firstChunk.value { throw ResilienceError.emptyReply }
    }

    /// Key 失效、余额不足、无权限：主接口重试没用，但换备用接口（另一个 Key / 另一家）有用
    static func isAccountError(_ error: Error) -> Bool {
        if case LLMError.http(let code, _) = error { return [401, 402, 403].contains(code) }
        return false
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case ResilienceError.firstChunkTimeout, ResilienceError.emptyReply: return true
        case LLMError.http(let code, _): return code == 408 || code == 429 || code >= 500
        case LLMError.api(let msg):
            // 按完整短语匹配："rate" 这种短词会误中 "generate""moderate"
            let m = msg.lowercased()
            return ["overloaded", "rate limit", "rate_limit", "too many requests", "server error", "api_error",
                    "service unavailable", "temporarily unavailable", "timed out", "timeout", "busy",
                    "连接中断", "繁忙", "限流", "过载", "超时"].contains { m.contains($0) }
        case let e as URLError:
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(e.code)
        default: return false
        }
    }
}

enum ResilienceError: LocalizedError {
    case firstChunkTimeout(Duration)
    case emptyReply
    var errorDescription: String? {
        switch self {
        case .firstChunkTimeout(let d): "模型 \(d.components.seconds) 秒没有返回内容"
        case .emptyReply: "模型返回了空回答"
        }
    }
}

private final class FirstChunkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
