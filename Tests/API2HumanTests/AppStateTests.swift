import XCTest
import AppKit
@testable import API2Human

/// AppState 的问答状态机：用假的流式 LLM，不联网
@MainActor
final class AppStateTests: XCTestCase {
    /// 慢速假 LLM：记录每次请求的最后一条用户消息，按固定间隔吐字
    final class FakeLLM: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        var requests: [String] { lock.withLock { _requests } }
        let chunks: [String]
        let delay: Duration
        /// 按问题内容决定回答（不设置就用 chunks）
        var responder: (@Sendable (String) -> [String])?

        init(chunks: [String] = Array(repeating: "答", count: 10), delay: Duration = .milliseconds(300)) {
            self.chunks = chunks
            self.delay = delay
        }

        func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let question = history.last?.content ?? ""
            lock.withLock { _requests.append(question) }
            let chunks = responder?(question) ?? chunks, delay = delay
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for c in chunks {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled { break }
                        continuation.yield(c)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func makeState(_ llm: FakeLLM) -> AppState {
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "fake") }
        state.makeProvider = { _ in llm }
        return state
    }

    private func say(_ state: AppState, _ text: String) {
        state.handleTranscript(TranscriptEvent(source: .remote, text: text, isFinal: true))
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: 补充提问

    func testFollowUpsWhileAnsweringAreAppendedAfterCurrentAnswer() async {
        let llm = FakeLLM()   // 每次回答 10 段 × 0.3s
        let state = makeState(llm)
        say(state, "说一下你最有挑战的项目")
        await wait(1.0)                       // 防抖 0.8s 后开始回答
        XCTAssertTrue(state.answerInFlight)
        say(state, "具体讲讲性能优化")          // 回答中补充：不打断
        await wait(0.3)
        say(state, "用了哪些工具")
        XCTAssertEqual(state.question, "说一下你最有挑战的项目\n具体讲讲性能优化\n用了哪些工具")
        XCTAssertEqual(llm.requests.count, 1, "当前回答不应被取消重答")
        await wait(3.6)                       // 第一题写完（0.8s 开始 + 3s）+ 防抖 0.8s 后才答补充
        XCTAssertTrue(state.reply.hasPrefix("答答答答答答答答答答"), "原回答完整保留：\(state.reply)")
        XCTAssertTrue(state.reply.contains("**补充：具体讲讲性能优化 用了哪些工具**"))
        XCTAssertTrue(llm.requests.last?.hasPrefix("面试官补充：具体讲讲性能优化 用了哪些工具") == true, "\(llm.requests)")
        await wait(3.5)
        XCTAssertFalse(state.answerInFlight)
        XCTAssertTrue(state.reply.hasSuffix("答答答答答答答答答答"), "补充的回答接在后面")
    }

    /// 第一次请求等一会儿后报错（401，不触发重试），之后正常
    final class FailFirstLLM: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        var requests: [String] { lock.withLock { _requests } }
        func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let n = lock.withLock { _requests.append(history.last?.content ?? ""); return _requests.count }
            return AsyncThrowingStream { c in
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if n == 1 { c.finish(throwing: LLMError.http(401, "bad key")) } else { c.yield("好"); c.finish() }
                }
            }
        }
    }

    func testSupplementAfterFailedAnswerIsAskedTogether() async {
        let llm = FailFirstLLM()
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "fake") }
        state.makeProvider = { _ in llm }
        say(state, "介绍下你的项目")
        await wait(1.0)                       // 防抖后开始回答，0.5s 后会失败
        say(state, "重点讲性能优化")            // 回答进行中补充
        await wait(2.0)
        XCTAssertEqual(llm.requests.count, 2, "\(llm.requests)")
        XCTAssertEqual(llm.requests.last, "面试官：介绍下你的项目 重点讲性能优化", "原问题没答上，和补充合成一题")
        XCTAssertFalse(state.reply.contains("⚠️"), "不接在错误提示下面：\(state.reply)")
        XCTAssertEqual(state.reply, "好")
    }

    /// 回答中有补充排队时按 ⌃⌥A：不截断当前回答，写完照常接着答补充
    func testManualAnswerDuringSupplementDoesNotTruncate() async {
        let llm = FakeLLM()   // 10 段 × 0.3s
        let state = makeState(llm)
        say(state, "说一下你最有挑战的项目")
        await wait(1.0)
        say(state, "具体讲讲性能优化")
        await wait(0.3)
        state.answerNow()
        XCTAssertEqual(llm.requests.count, 1, "当前回答不应被取消")
        await wait(3.8)                       // 第一题 3.8s 左右写完 + 补充防抖 0.8s
        XCTAssertTrue(state.reply.hasPrefix("答答答答答答答答答答"), "原回答完整：\(state.reply)")
        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertTrue(llm.requests.last?.hasPrefix("面试官补充：具体讲讲性能优化") == true)
    }

    /// 同文案的两次等待重叠：先结束的不能清掉后一次的提示
    func testOverlappingWaitNoticesKeepNewerOne() async {
        let state = makeState(FakeLLM())
        async let first: Void = state.withWaitNotice("加载中", after: .zero) { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .milliseconds(100))
        async let second: Void = state.withWaitNotice("加载中", after: .zero) { try? await Task.sleep(for: .milliseconds(600)) }
        _ = await first
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.waitNotice, "加载中", "后一次还在等，提示要留着")
        _ = await second
        XCTAssertNil(state.waitNotice)
    }

    /// 补充那次请求失败：原回答保留，错误接在下面
    func testFailedSupplementKeepsOriginalAnswer() async {
        final class FailSecondLLM: LLMProvider, @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
                let k = lock.withLock { n += 1; return n }
                return AsyncThrowingStream { c in
                    Task {
                        try? await Task.sleep(for: .milliseconds(20))
                        if k == 2 { c.finish(throwing: LLMError.http(401, "bad key")) } else { c.yield("原回答"); c.finish() }
                    }
                }
            }
        }
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "fake") }
        let llm = FailSecondLLM()           // 共用一个实例：计数要跨请求
        state.makeProvider = { _ in llm }
        say(state, "Redis 为什么这么快")
        await wait(1.2)
        say(state, "单线程为什么还快")          // 4 秒内接着问 → 补充
        await wait(1.3)
        XCTAssertTrue(state.reply.hasPrefix("原回答"), state.reply)
        XCTAssertTrue(state.reply.contains("⚠️ 补充没答上"), state.reply)
    }

    /// 一句被判"无需回答"期间面试官又说了一句：两句合成新问题答，不能当成更早那题的补充
    func testNoAnswerVerdictWithQueuedFollowUpBecomesNewQuestion() async {
        let llm = FakeLLM(chunks: ["好"], delay: .milliseconds(150))
        llm.responder = { q in q == "面试官：我们稍等一下" ? ["（无需回答）"] : ["好"] }
        let state = makeState(llm)
        say(state, "Redis 为什么这么快？")
        await wait(1.0)                        // Q0 已答
        await wait(3.5)                        // 出了 4 秒补充窗口
        say(state, "我们稍等一下")
        await wait(0.9)                        // X 正在请求（判无需回答要 150ms）
        say(state, "你先讲讲项目里的缓存设计")     // 回答中来的一句 → 先按补充排队
        await wait(1.5)
        XCTAssertEqual(llm.requests.last, "面试官：我们稍等一下 你先讲讲项目里的缓存设计", "\(llm.requests)")
        XCTAssertFalse(state.reply.contains("**补充"), state.reply)
    }

    func testQuickFollowUpAfterAnswerIsSupplement() async {
        let llm = FakeLLM(chunks: ["好"], delay: .milliseconds(10))
        let state = makeState(llm)
        say(state, "Redis 为什么这么快")
        await wait(1.2)
        say(state, "单线程为什么还快")          // 答完 4 秒内接着问
        await wait(1.2)
        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertTrue(llm.requests[1].hasPrefix("面试官补充：单线程为什么还快"))
        XCTAssertTrue(state.reply.hasPrefix("好\n\n**补充：单线程为什么还快**"))
    }

    // MARK: 过短过滤

    func testShortChineseFollowUpIsAnswered() async {
        let llm = FakeLLM(chunks: ["好"], delay: .milliseconds(10))
        let state = makeState(llm)
        say(state, "为什么？")
        await wait(1.0)
        XCTAssertEqual(llm.requests, ["面试官：为什么？"])
    }

    /// 问题说完、防抖期间面试官"嗯"了一声：partial 取消了防抖，语气词被过滤后问题仍要回答
    func testFillerDuringDebounceStillAnswersQuestion() async {
        let llm = FakeLLM(chunks: ["好"], delay: .milliseconds(10))
        let state = makeState(llm)
        say(state, "介绍下你的项目")
        await wait(0.2)
        state.handleTranscript(TranscriptEvent(source: .remote, text: "嗯", isFinal: false))
        say(state, "嗯")
        await wait(1.2)
        XCTAssertEqual(llm.requests, ["面试官：介绍下你的项目"])
    }

    /// 半句出现又消失（没有 final）：之前的问题仍要回答
    func testVanishedPartialStillAnswersQuestion() async {
        let llm = FakeLLM(chunks: ["好"], delay: .milliseconds(10))
        let state = makeState(llm)
        say(state, "介绍下你的项目")
        await wait(0.2)
        state.handleTranscript(TranscriptEvent(source: .remote, text: "那个", isFinal: false))
        state.handleTranscript(TranscriptEvent(source: .remote, text: "", isFinal: false))
        await wait(1.2)
        XCTAssertEqual(llm.requests, ["面试官：介绍下你的项目"])
    }

    func testFillerIsIgnoredAndPreviousQuestionStays() async {
        let llm = FakeLLM(chunks: ["回答"], delay: .milliseconds(10))
        let state = makeState(llm)
        say(state, "Redis 为什么这么快")
        await wait(1.2)
        XCTAssertEqual(llm.requests.count, 1)
        say(state, "嗯")
        await wait(1.0)
        XCTAssertEqual(llm.requests.count, 1, "嗯 不应该发给 AI")
        XCTAssertEqual(state.question, "Redis 为什么这么快", "被过滤后应恢复显示上一题")
        state.answerNow()                      // ⌃⌥A 重新生成：应该是上一题
        await wait(0.2)
        XCTAssertEqual(llm.requests.last, "面试官：Redis 为什么这么快")
    }
}

final class FillerTests: XCTestCase {
    func testCompleteQuestionDetection() {
        for t in ["Redis 为什么这么快？", "Why do you want to join us?", "你能接受加班吗", "你觉得呢。", "那这样可以么"] {
            XCTAssertTrue(AppState.looksLikeCompleteQuestion(t), t)
        }
        for t in ["说一下你最有挑战的项目", "我们先聊聊", "那我们开始吧", "先做个自我介绍"] {
            XCTAssertFalse(AppState.looksLikeCompleteQuestion(t), t)
        }
    }

    func testFillers() {
        for t in ["嗯", "嗯。", "哦？", "啊？", "好的", "好的！", "对对", "OK", "Okay.", "yeah", "谢谢", "Got it"] {
            XCTAssertTrue(AppState.isFiller(t), t)
        }
    }

    func testShortQuestionsAreNotFillers() {
        for t in ["为什么？", "怎么做", "然后呢", "Why?", "How so?", "举个例子", "Redis 为什么这么快", "谁？", "啥？", "哪？", "几个？"] {
            XCTAssertFalse(AppState.isFiller(t), t)
        }
    }
}

@MainActor
final class ScreenSearchTests: XCTestCase {
    private func codeImage() throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "code", withExtension: "png", subdirectory: "Fixtures"))
        return try XCTUnwrap(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testCrossCheckTimeoutReallyStopsWaiting() async throws {
        let main = AppStateTests.FakeLLM(chunks: ["**大概在做什么**：x\n**发现的问题**：没看到明显问题。"], delay: .milliseconds(10))
        let slow = AppStateTests.FakeLLM(chunks: Array(repeating: "慢", count: 20), delay: .seconds(1))
        let state = AppState()
        state.loadConfig = {
            var c = LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main")
            c.screenCheckModel = "slow"
            return c
        }
        state.makeProvider = { $0.model == "slow" ? slow : main }
        state.crossCheckTimeout = .seconds(1)

        _ = try await TextRecognizer.recognize(try codeImage())   // 预热 OCR（冷启动要十几秒，和超时无关）
        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .seconds(4))   // OCR + 主路 + 1 秒超时，远小于慢路的 20 秒
        XCTAssertFalse(state.answerInFlight)
        XCTAssertFalse(state.crossChecking, "第二路 20 秒才出结果，1 秒超时后必须结束核对")
        XCTAssertTrue(state.reply.contains("没看到明显问题"))
    }

    /// 主回答写完这一轮就结束（不等第二路）；第二路晚到且结论不同，回答还在屏幕上时追加提醒
    func testCrossCheckRunsInBackgroundAndAppendsLateNote() async throws {
        let clean = "**大概在做什么**：x\n**发现的问题**：没看到明显问题。\n**在项目里的作用**：y"
        let withBug = "**大概在做什么**：x\n**发现的问题**：mask 方向反了。\n**在项目里的作用**：y"
        let main = AppStateTests.FakeLLM(chunks: [clean], delay: .milliseconds(10))
        let slow = AppStateTests.FakeLLM(chunks: [withBug], delay: .seconds(2))
        let state = AppState()
        state.loadConfig = {
            var c = LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main")
            c.screenCheckModel = "slow"
            return c
        }
        state.makeProvider = { $0.model == "slow" ? slow : main }
        _ = try await TextRecognizer.recognize(try codeImage())

        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertFalse(state.answerInFlight, "主回答写完就结束，不等第二路")
        XCTAssertTrue(state.crossChecking)
        XCTAssertEqual(state.reply, clean)

        try? await Task.sleep(for: .seconds(2))
        XCTAssertFalse(state.crossChecking)
        XCTAssertTrue(state.reply.hasPrefix(clean))
        XCTAssertTrue(state.reply.contains("mask 方向反了"), "核对不一致的提醒追加在末尾：\(state.reply)")
    }

    /// 核对还在跑时开始演示（新一轮）：核对作废，提示立刻消失，晚到的结果不写进回答
    func testDemoCancelsPendingCrossCheck() async throws {
        let clean = "**大概在做什么**：x\n**发现的问题**：没看到明显问题。\n**在项目里的作用**：y"
        let withBug = "**大概在做什么**：x\n**发现的问题**：mask 方向反了。\n**在项目里的作用**：y"
        let main = AppStateTests.FakeLLM(chunks: [clean], delay: .milliseconds(10))
        let slow = AppStateTests.FakeLLM(chunks: [withBug], delay: .seconds(2))
        let state = AppState()
        state.loadConfig = {
            var c = LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main")
            c.screenCheckModel = "slow"
            return c
        }
        state.makeProvider = { $0.model == "slow" ? slow : main }
        _ = try await TextRecognizer.recognize(try codeImage())

        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(state.crossChecking)
        state.runDemo()
        XCTAssertFalse(state.crossChecking)
        XCTAssertNil(state.headerHint)
        try? await Task.sleep(for: .seconds(2.5))
        XCTAssertFalse(state.reply.contains("mask 方向反了"), "作废的核对不应写进回答：\(state.reply)")
    }

    /// 核对期间来了新问题：立刻回答；核对结果晚到不覆盖新回答
    func testLateCrossCheckDoesNotTouchNewAnswer() async throws {
        let clean = "**大概在做什么**：x\n**发现的问题**：没看到明显问题。\n**在项目里的作用**：y"
        let withBug = "**大概在做什么**：x\n**发现的问题**：mask 方向反了。\n**在项目里的作用**：y"
        let main = AppStateTests.FakeLLM(chunks: [clean], delay: .milliseconds(10))
        main.responder = { $0.contains("Redis") ? ["Redis 单线程", "，内存操作"] : [clean] }
        let slow = AppStateTests.FakeLLM(chunks: [withBug], delay: .seconds(3))
        let state = AppState()
        state.loadConfig = {
            var c = LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main")
            c.screenCheckModel = "slow"
            return c
        }
        state.makeProvider = { $0.model == "slow" ? slow : main }
        _ = try await TextRecognizer.recognize(try codeImage())

        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .seconds(1.2))
        state.handleTranscript(TranscriptEvent(source: .remote, text: "Redis 为什么这么快？", isFinal: true))
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(state.reply, "Redis 单线程，内存操作", "核对期间的新问题照常回答")
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(state.reply, "Redis 单线程，内存操作", "晚到的核对提醒不改新回答")
    }

    /// 语音回答中有补充排队 → 圈选 → 圈选期间来了新问题：新问题按新题答，不能当成圈选回答的"补充"
    func testQueuedQuestionAfterLassoIsNotSupplement() async throws {
        let screenReply = "**大概在做什么**：x\n**发现的问题**：没看到明显问题。"
        let llm = AppStateTests.FakeLLM(chunks: Array(repeating: "答", count: 10), delay: .milliseconds(150))
        llm.responder = { q in q.contains("屏幕") || q.contains("OCR") || q.contains("圈") ? [screenReply] : Array(repeating: "答", count: 10) }
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main") }
        state.makeProvider = { _ in llm }
        state.crossCheckTimeout = .milliseconds(100)
        _ = try await TextRecognizer.recognize(try codeImage())

        state.handleTranscript(TranscriptEvent(source: .remote, text: "说一下你的项目", isFinal: true))
        try? await Task.sleep(for: .seconds(1.0))          // 语音回答进行中
        state.handleTranscript(TranscriptEvent(source: .remote, text: "重点讲讲难点", isFinal: true))   // 补充排队
        state.answerScreen(try codeImage())                  // 圈选打断
        try? await Task.sleep(for: .milliseconds(300))
        state.handleTranscript(TranscriptEvent(source: .remote, text: "Redis 为什么这么快", isFinal: true))
        try? await Task.sleep(for: .seconds(4))
        let last = try XCTUnwrap(llm.requests.last)
        XCTAssertEqual(last, "面试官：Redis 为什么这么快", "\(llm.requests)")
        XCTAssertFalse(state.reply.contains("**补充"), state.reply)
    }

    /// 圈选后按 ⌃⌥A：不能把圈选之前的语音问题拿出来重答（会冲掉圈选回答）
    func testManualRegenerateAfterLassoDoesNotReaskVoiceQuestion() async throws {
        let llm = AppStateTests.FakeLLM(chunks: ["**大概在做什么**：x\n**发现的问题**：没看到明显问题。"], delay: .milliseconds(10))
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main") }
        state.makeProvider = { _ in llm }
        state.crossCheckTimeout = .milliseconds(100)
        _ = try await TextRecognizer.recognize(try codeImage())
        state.handleTranscript(TranscriptEvent(source: .remote, text: "Redis 为什么这么快", isFinal: true))
        try? await Task.sleep(for: .seconds(1.2))
        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .seconds(1.0))
        let before = llm.requests.count
        state.answerNow()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(llm.requests.dropFirst(before).contains("面试官：Redis 为什么这么快"), "\(llm.requests)")
        XCTAssertTrue(state.reply.contains("没看到明显问题"))
    }

    func testSpeechDuringScreenSearchIsQueuedNotMerged() async throws {
        let screenReply = "**大概在做什么**：x\n**发现的问题**：mask 方向反了。"
        let llm = AppStateTests.FakeLLM(chunks: Array(repeating: screenReply, count: 1) + Array(repeating: "。", count: 6),
                                        delay: .milliseconds(300))
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "main") }
        state.makeProvider = { _ in llm }
        state.crossCheckTimeout = .milliseconds(100)
        _ = try await TextRecognizer.recognize(try codeImage())

        // 先有一个已回答的语音问题，lastQuestionSegments 有值
        state.handleTranscript(TranscriptEvent(source: .remote, text: "Redis 为什么这么快", isFinal: true))
        try? await Task.sleep(for: .seconds(3.5))
        let before = llm.requests.count

        state.answerScreen(try codeImage())
        try? await Task.sleep(for: .milliseconds(600))
        state.handleTranscript(TranscriptEvent(source: .remote, text: "这段代码怎么改", isFinal: true))
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(state.reply.contains("mask 方向反了"), "圈选回答不应被打断")
        XCTAssertFalse(llm.requests.contains { $0.contains("Redis 为什么这么快 这段代码怎么改") }, "不应和旧问题合并")

        try? await Task.sleep(for: .seconds(4))   // 圈选结束后，排队的问题再回答
        let after = Array(llm.requests.dropFirst(before))
        XCTAssertEqual(after.count, 3, "圈选主路 + 第二路 + 排队的问题：\(after)")
        XCTAssertEqual(after.last, "面试官：这段代码怎么改")
    }
}

@MainActor
final class DemoTests: XCTestCase {
    func testDemoCancelsInFlightAnswer() async {
        let llm = AppStateTests.FakeLLM(chunks: Array(repeating: "旧", count: 20), delay: .milliseconds(200))
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "m") }
        state.makeProvider = { _ in llm }
        state.handleTranscript(TranscriptEvent(source: .remote, text: "说一下 TCP 三次握手", isFinal: true))
        try? await Task.sleep(for: .seconds(1.3))
        XCTAssertTrue(state.answerInFlight)
        state.runDemo()
        XCTAssertFalse(state.answerInFlight)
        try? await Task.sleep(for: .seconds(4))
        XCTAssertFalse(state.reply.contains("旧"), "演示开始后旧回答不应再写进 reply")
        XCTAssertTrue(state.reply.contains("actor"))
    }
}


@MainActor
final class SessionTests: XCTestCase {
    func testLateFinalFromPreviousSessionIsDropped() async {
        let llm = AppStateTests.FakeLLM(chunks: ["答"], delay: .milliseconds(10))
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "m") }
        state.makeProvider = { _ in llm }
        state.sessionID = 2
        state.handleTranscript(TranscriptEvent(source: .remote, text: "上一轮的最后一句", isFinal: true, session: 1))
        state.handleTranscript(TranscriptEvent(source: .remote, text: "这一轮的问题是什么", isFinal: true, session: 2))
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(llm.requests, ["面试官：这一轮的问题是什么"])
    }
}

@MainActor
final class NoAnswerRestoreTests: XCTestCase {
    func testFillerLikeSupplementKeepsFullAnswer() async {
        let llm = AppStateTests.FakeLLM(delay: .milliseconds(150))
        llm.responder = { q in
            if q.contains("嗯，好的，我们继续") { return ["（无需回答）"] }
            return Array(repeating: "第二题", count: 10)
        }
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "m") }
        state.makeProvider = { _ in llm }

        state.handleTranscript(TranscriptEvent(source: .remote, text: "第二题说一下 Kafka", isFinal: true))
        try? await Task.sleep(for: .seconds(1.4))            // 回答到一半
        state.handleTranscript(TranscriptEvent(source: .remote, text: "嗯，好的，我们继续", isFinal: true))
        try? await Task.sleep(for: .seconds(3.5))            // 写完 -> 补充被判"无需回答"
        XCTAssertEqual(state.reply, String(repeating: "第二题", count: 10), "完整保留第二题的回答，不带补充标题")
        XCTAssertEqual(state.question, "第二题说一下 Kafka")
    }
}

@MainActor
final class LatencyTests: XCTestCase {
    func testCompleteQuestionIsAnsweredWithoutFullDebounce() async {
        let llm = AppStateTests.FakeLLM(chunks: ["答"], delay: .milliseconds(10))
        let state = AppState()
        state.loadConfig = { LLMConfig(baseURL: "https://example.invalid", authToken: "t", model: "m") }
        state.makeProvider = { _ in llm }
        state.handleTranscript(TranscriptEvent(source: .remote, text: "Redis 为什么这么快？", isFinal: true))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(llm.requests, ["面试官：Redis 为什么这么快？"], "问号结尾应在 0.15s 后就发出")
    }
}
