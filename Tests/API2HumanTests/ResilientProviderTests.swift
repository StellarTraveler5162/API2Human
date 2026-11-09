import XCTest
@testable import API2Human

final class ResilientProviderTests: XCTestCase {
    /// 按预设脚本表现的假接口：先抛错 / 先出几个字再抛错 / 一直不出字 / 正常
    final class ScriptedLLM: LLMProvider, @unchecked Sendable {
        enum Behavior { case fail(Error), partialThenFail([String], Error), hang, ok([String]) }
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        let behavior: Behavior
        init(_ b: Behavior) { behavior = b }

        func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            lock.withLock { _calls += 1 }
            let b = behavior
            return AsyncThrowingStream { c in
                let t = Task {
                    switch b {
                    case .fail(let e): c.finish(throwing: e)
                    case .partialThenFail(let chunks, let e): chunks.forEach { c.yield($0) }; c.finish(throwing: e)
                    case .hang: try? await Task.sleep(for: .seconds(60)); c.finish()
                    case .ok(let chunks): chunks.forEach { c.yield($0) }; c.finish()
                    }
                }
                c.onTermination = { _ in t.cancel() }
            }
        }
    }

    private func collect(_ p: ResilientProvider) async -> (String, Error?) {
        var text = ""
        do {
            for try await c in p.streamReply(system: "", history: []) { text += c }
            return (text, nil)
        } catch { return (text, error) }
    }

    private func make(_ ps: [ScriptedLLM]) -> ResilientProvider {
        var p = ResilientProvider(attempts: ps.enumerated().map { ("p\($0.offset)", $0.element as any LLMProvider) })
        p.retryDelay = .milliseconds(1)
        p.firstChunkTimeout = .milliseconds(300)
        return p
    }

    func testRetriesOn503ThenSucceeds() async {
        let a = ScriptedLLM(.fail(LLMError.http(503, "busy"))), b = ScriptedLLM(.ok(["好", "的"]))
        let (text, err) = await collect(make([a, b]))
        XCTAssertNil(err)
        XCTAssertEqual(text, "好的")
        XCTAssertEqual(a.calls + b.calls, 2)
    }

    func testFallsBackAfterTwoFailures() async {
        let a = ScriptedLLM(.fail(LLMError.http(429, "rate"))), b = ScriptedLLM(.fail(URLError(.timedOut)))
        let c = ScriptedLLM(.ok(["备用"]))
        let (text, err) = await collect(make([a, b, c]))
        XCTAssertNil(err)
        XCTAssertEqual(text, "备用")
    }

    func testNoRetryAfterFirstChunk() async {
        let a = ScriptedLLM(.partialThenFail(["半句"], LLMError.api("连接中断，回答可能不完整")))
        let b = ScriptedLLM(.ok(["另一个回答"]))
        let (text, err) = await collect(make([a, b]))
        XCTAssertNotNil(err)
        XCTAssertEqual(text, "半句", "已经出字就不换回答")
        XCTAssertEqual(b.calls, 0)
    }

    func testAuthErrorIsNotRetried() async {
        let a = ScriptedLLM(.fail(LLMError.http(401, "bad key"))), b = ScriptedLLM(.ok(["x"]))
        let (_, err) = await collect(make([a, b]))
        XCTAssertNotNil(err)
        XCTAssertEqual(b.calls, 0)
    }

    func testFirstChunkTimeoutMovesOn() async {
        let a = ScriptedLLM(.hang), b = ScriptedLLM(.ok(["快"]))
        let started = ContinuousClock.now
        let (text, err) = await collect(make([a, b]))
        XCTAssertNil(err)
        XCTAssertEqual(text, "快")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testRetryableClassificationUsesPhrases() {
        XCTAssertTrue(ResilientProvider.isRetryable(LLMError.api("Overloaded")))
        XCTAssertTrue(ResilientProvider.isRetryable(LLMError.api("Internal server error")))
        XCTAssertTrue(ResilientProvider.isRetryable(LLMError.api("Rate limit exceeded")))
        XCTAssertTrue(ResilientProvider.isRetryable(LLMError.api("连接中断，回答可能不完整")))
        XCTAssertFalse(ResilientProvider.isRetryable(LLMError.api("failed to generate: content moderated")))
        XCTAssertFalse(ResilientProvider.isRetryable(LLMError.api("invalid model separate_x")))
        XCTAssertFalse(ResilientProvider.isRetryable(LLMError.http(401, "bad key")))
        XCTAssertTrue(ResilientProvider.isRetryable(LLMError.http(529, "overloaded")))
    }

    func testThinkingGetsLongerFirstChunkTimeout() {
        XCTAssertEqual(ResilientProvider.firstChunkTimeout(thinking: true, base: .seconds(12)), .seconds(60))
        XCTAssertEqual(ResilientProvider.firstChunkTimeout(thinking: false, base: .seconds(12)), .seconds(12))
        XCTAssertEqual(ResilientProvider.firstChunkTimeout(thinking: nil, base: .milliseconds(300)), .milliseconds(300))
    }

    func testAccountErrorJumpsStraightToFallback() async {
        let a = ScriptedLLM(.fail(LLMError.http(402, "Insufficient Balance"))), b = ScriptedLLM(.ok(["不该调"]))
        let c = ScriptedLLM(.ok(["备用"]))
        var p = make([a, b, c])
        p.fallbackStart = 2
        let (text, err) = await collect(p)
        XCTAssertNil(err)
        XCTAssertEqual(text, "备用")
        XCTAssertEqual(b.calls, 0, "Key/余额问题不在主接口上重试")
    }

    func testPerAttemptTimeoutOverride() async {
        // 主接口 300ms 超时；备用接口（比如开了思考）单独放宽，慢一点出字也不算失败
        final class SlowStart: LLMProvider, @unchecked Sendable {
            func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    let t = Task { try? await Task.sleep(for: .milliseconds(600)); c.yield("想好了"); c.finish() }
                    c.onTermination = { _ in t.cancel() }
                }
            }
        }
        var p = ResilientProvider(attempts: [("主", ScriptedLLM(.hang)), ("备用", SlowStart())])
        p.retryDelay = .milliseconds(1)
        p.firstChunkTimeout = .milliseconds(300)
        p.timeoutOverrides[1] = .seconds(2)
        let (text, err) = await collect(p)
        XCTAssertNil(err)
        XCTAssertEqual(text, "想好了")
    }

    func testEmptyReplyIsRetried() async {
        let a = ScriptedLLM(.ok([])), b = ScriptedLLM(.ok(["有内容"]))
        let (text, err) = await collect(make([a, b]))
        XCTAssertNil(err)
        XCTAssertEqual(text, "有内容")
    }

    func testChainMatchesConfig() {
        var c = LLMConfig(baseURL: "https://a", authToken: "t", model: "m", thinking: true)
        var p = ResilientProvider.chain(for: c) { _ in ScriptedLLM(.ok(["x"])) }
        XCTAssertEqual(p.attempts.count, 2)
        XCTAssertNil(p.fallbackStart)
        XCTAssertEqual(p.firstChunkTimeout, .seconds(60), "主接口开了思考")
        c.fallback = .init(model: "m2", thinking: false)
        p = ResilientProvider.chain(for: c) { _ in ScriptedLLM(.ok(["x"])) }
        XCTAssertEqual(p.attempts.count, 3)
        XCTAssertEqual(p.fallbackStart, 2)
        XCTAssertEqual(p.timeoutOverrides[2], .seconds(12), "备用没开思考，用默认超时")
    }

    func testAccountErrorWithoutFallbackFailsFast() async {
        let a = ScriptedLLM(.fail(LLMError.http(401, "bad key"))), b = ScriptedLLM(.ok(["x"]))
        let (_, err) = await collect(make([a, b]))
        XCTAssertNotNil(err)
        XCTAssertEqual(b.calls, 0)
    }

    func testFallbackTokenOnlyInheritedOnSameHost() {
        var c = LLMConfig(baseURL: "https://api.deepseek.com/anthropic", authToken: "primary", model: "m")
        c.fallback = .init(baseURL: "https://other.example.com", model: "x")
        XCTAssertNil(c.fallbackConfig, "换了服务器又没填 Key：不能把主 Key 发过去")
        c.fallback = .init(baseURL: "https://other.example.com", authToken: "other", model: "x")
        XCTAssertEqual(c.fallbackConfig?.authToken, "other")
        c.fallback = .init(baseURL: "https://API.deepseek.com/anthropic", model: "x")
        XCTAssertEqual(c.fallbackConfig?.authToken, "primary", "同一服务器沿用主 Key")
        c.fallback = .init(baseURL: "http://api.deepseek.com/anthropic", model: "x")
        XCTAssertNil(c.fallbackConfig, "换成 http 不能沿用 Key（明文）")
        c.fallback = .init(baseURL: "https://api.deepseek.com:8443", model: "x")
        XCTAssertNil(c.fallbackConfig, "端口不同算别的服务")
    }

    /// llm.json 只写部分字段，其余从环境变量补（文档承诺的行为）
    func testPartialLLMJSONFallsBackToEnv() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-llm-\(UUID()).json")
        try Data(#"{"model":"m-from-file"}"#.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            unsetenv("A2H_LLM_JSON"); unsetenv("ANTHROPIC_AUTH_TOKEN"); unsetenv("ANTHROPIC_BASE_URL")
        }
        setenv("A2H_LLM_JSON", url.path, 1)
        setenv("ANTHROPIC_AUTH_TOKEN", "tok-from-env", 1)
        setenv("ANTHROPIC_BASE_URL", "https://env.example.com", 1)
        let c = try LLMConfig.load()
        XCTAssertEqual(c.model, "m-from-file")
        XCTAssertEqual(c.authToken, "tok-from-env")
        XCTAssertEqual(c.baseURL, "https://env.example.com")
    }

    func testFallbackConfigInheritsAndSkipsIdentical() {
        var c = LLMConfig(baseURL: "https://a", authToken: "t", model: "m")
        XCTAssertNil(c.fallbackConfig)
        c.fallback = .init(model: "m")
        XCTAssertNil(c.fallbackConfig, "和主接口一样就不算备用")
        c.fallback = .init(model: "m2")
        XCTAssertEqual(c.fallbackConfig?.model, "m2")
        XCTAssertEqual(c.fallbackConfig?.baseURL, "https://a")
        XCTAssertEqual(c.fallbackConfig?.authToken, "t")
    }
}
