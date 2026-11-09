import SwiftUI
import Observation

/// 流水线状态：Listen -> STT -> LLM -> Display/Say
enum PipelineStatus: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case answering
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: "待机"
        case .listening: "监听中"
        case .transcribing: "识别中"
        case .thinking: "思考中"
        case .answering: "生成中"
        case .speaking: "朗读中"
        case .error(let msg): "错误：\(msg)"
        }
    }

    var color: Color {
        switch self {
        case .idle: .gray
        case .listening: .green
        case .transcribing: .teal
        case .thinking, .answering: .orange
        case .speaking: .purple
        case .error: .red
        }
    }
}

/// 全局单一数据源。后续 Step 2~5 的 AudioCapture / STT / LLM 服务都通过它驱动 UI。
@MainActor
@Observable
final class AppState {
    // 控制栏
    private(set) var isRecording = false
    private(set) var isStarting = false
    var isMicMuted = false
    var status: PipelineStatus = .idle

    // 音频（Step 2）
    /// 麦克风录制方式（只影响复盘用的 mic.wav，不影响识别和回答）；下次开始监听生效
    var micMode: MicrophoneSelector.Mode = MicrophoneSelector.Mode(rawValue: UserDefaults.standard.string(forKey: "micMode") ?? "") ?? .auto {
        didSet { if !micModeIsTemporary { UserDefaults.standard.set(micMode.rawValue, forKey: "micMode") } }
    }
    /// 系统内录范围：默认只录会议软件（微信提示音、视频、音乐不会被当成问题）；下次开始监听生效
    var audioScope: AudioSourceScope = AudioSourceScope(rawValue: UserDefaults.standard.string(forKey: "audioScope") ?? "") ?? .meetingApps {
        didSet { UserDefaults.standard.set(audioScope.rawValue, forKey: "audioScope") }
    }
    /// 调试参数 --no-mic 只影响这次运行，不改保存的设置
    @ObservationIgnored var micModeIsTemporary = false
    private(set) var remoteLevel: Float = 0 // 对方（系统音频）
    private(set) var localLevel: Float = 0  // 我（麦克风）
    private(set) var lastSession: AudioCaptureManager.Session?

    // 悬浮窗内容
    var question = ""              // 已断句的部分（final）
    var questionPartial = ""       // 正在说的半句（partial，实时变化）
    var reply = ""

    // 语音识别（Step 3）
    private(set) var sttIssue: String?          // 模型加载失败等，非致命：照常录音
    private(set) var transcript: [TranscriptLine] = []   // 本轮监听的完整记录，Step 4 给 LLM 做上下文
    private static let maxQuestionLines = 6

    // LLM（Step 4）
    private(set) var llmIssue: String?

    // 即圈即搜
    private(set) var screenThumbnail: NSImage?
    private(set) var isScreenSearching = false
    /// 面试官一句话说完后再等多久没有新的话，才认为问题问完了
    private static let answerDebounce: Duration = .milliseconds(800)
    /// 带给模型的历史问答轮数
    private static let historyTurns = 3
    /// 上一题发出后这么短时间内面试官又开口，视为同一题的延续（候选人此时通常还没开始答）
    private static let continuationWindow: Duration = .seconds(4)
    /// 被判"无需回答"的句子，在这段时间内和下一句合并
    private static let unansweredCarryWindow: Duration = .seconds(10)

    // 悬浮窗外观
    var isPanelVisible = true
    var isReaderMode = false
    var panelOpacity: Double = 0.95
    var resetPanelPositionToken = 0

    let speech = SpeechService()

    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private let capture = AudioCaptureManager()
    @ObservationIgnored private var transcriber: StreamingTranscriber?
    /// 背景资料改过：识别器的热词过期了，下次 prepareTranscriber 时重建
    @ObservationIgnored private var hotwordsStale = false
    /// 最近一次回答以错误结束：之后的"补充"要连同原问题一起重答
    @ObservationIgnored private var lastAnswerFailed = false
    @ObservationIgnored private var recordingStartedAt = Date()
    /// 上一次停止监听（后台执行）；下一次开始前要等它完成，避免 start/stop 并发操作 CoreAudio
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// 启动过程中（加载模型、打开 CoreAudio 可能要几秒到几十秒）用户按了停止：启动完成后立刻停
    @ObservationIgnored private var stopRequested = false
    /// 当前监听轮次；识别事件带着它，晚到的上一轮结果直接丢弃
    @ObservationIgnored var sessionID = 0
    @ObservationIgnored private var pendingSegments: [String] = []     // 还没交给 AI 的问题片段
    @ObservationIgnored private var lastQuestionSegments: [String] = [] // 最近一次交给 AI 的问题
    @ObservationIgnored private var questionAnswered = false            // 当前 Question 框里的问题是否已发出
    @ObservationIgnored private var chatHistory: [ChatTurn] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var answerInFlight = false
    /// 正在生成的是"即圈即搜"的回答：这时面试官说的话先排队，不打断圈选
    @ObservationIgnored private var screenInFlight = false
    /// pendingSegments 是对上一题的补充（回答会接在原回答下面），而不是新问题
    @ObservationIgnored private var pendingIsSupplement = false
    /// 注入点（测试用假的流式客户端、假配置；正式运行用 DeepSeek / Anthropic 接口）
    @ObservationIgnored var makeProvider: @Sendable (LLMConfig) -> any LLMProvider = { AnthropicMessagesProvider(config: $0) }
    @ObservationIgnored var loadConfig: () throws -> LLMConfig = { try LLMConfig.load() }
    /// 即圈即搜第二路（交叉核对）最多等多久；第二路是 Flash + 思考，实测 8~31 秒
    @ObservationIgnored var crossCheckTimeout: Duration = .seconds(30)
    /// 多久不出第一个字就重试（测试里调短）
    @ObservationIgnored var firstChunkTimeout: Duration = .seconds(12)
    @ObservationIgnored var retryDelay: Duration = .milliseconds(400)
    /// 出字前失败自动重试 / 切备用接口时显示在顶栏，出字后清掉
    private(set) var retryNotice: String?
    /// 顶栏状态后面的小字提示：重试 > 交叉核对 > 预热
    var headerHint: String? {
        retryNotice ?? waitNotice ?? (crossChecking ? "交叉核对中" : nil)
    }
    /// 慢操作（OCR 首次加载、音频设备迟迟不响应、识别模型加载）超过 1.5 秒还没完成时的提示
    private(set) var waitNotice: String?
    @ObservationIgnored private var waitNoticeSeq = 0
    @ObservationIgnored private var waitNoticeOwner: Int?

    /// op 超过 after 还没完成就在顶栏显示 notice，完成后清掉
    func withWaitNotice<T: Sendable>(_ notice: String, after: Duration = .milliseconds(1500),
                                             _ op: () async throws -> T) async rethrows -> T {
        waitNoticeSeq += 1
        let mine = waitNoticeSeq
        let timer = Task { [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled, let self else { return }
            self.waitNotice = notice
            self.waitNoticeOwner = mine
        }
        defer {
            timer.cancel()
            // 只清自己设的：同文案的另一次调用（比如新的圈选）可能已经接管了提示
            if waitNoticeOwner == mine { waitNotice = nil; waitNoticeOwner = nil }
        }
        return try await op()
    }
    /// 即圈即搜的第二路在后台核对：主回答写完就结束这一轮，核对结果晚到也不挡新问题
    @ObservationIgnored private var crossCheckTask: Task<Void, Never>?
    /// 顶栏小字提示"交叉核对中"，不写进回答正文
    private(set) var crossChecking = false
    @ObservationIgnored private var lastQuestionSentAt: ContinuousClock.Instant?
    @ObservationIgnored private var unansweredCarry: (segments: [String], at: ContinuousClock.Instant)?
    @ObservationIgnored private var lastShownQuestion = ""          // 当前 Reply 对应的问题（用于"无需回答"时恢复）
    @ObservationIgnored private var lastShownSegments: [String] = []
    @ObservationIgnored private var lastShownReply = ""

    init() {
        capture.onSourceChange = { [weak self] source in
            Task { @MainActor in self?.lastSession?.systemSource = source }
        }
        NotificationCenter.default.addObserver(forName: InterviewContext.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interviewContextDidChange() }
        }
        capture.onLevel = { [weak self] source, level in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                switch source {
                case .remote: self.remoteLevel = level
                case .local: self.localLevel = level
                }
            }
        }
    }

    // MARK: - Actions

    func toggleRecording() {
        // 启动过程中再按一次也是"停止"（会在启动完成后立刻停）
        if isRecording || isStarting { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        stopRequested = false
        status = .listening
        Task {
            await withWaitNotice("上次的音频还没停完，请稍候") { await stopTask?.value }
            resetConversation()
            sessionID += 1
            await withWaitNotice("加载语音识别模型…") { await prepareTranscriber() }
            let folder: URL
            do {
                defer { isStarting = false }
                capture.setMicMuted(isMicMuted)
                // CoreAudio 偶尔要几十秒才响应（蓝牙耳机切换模式时），不能卡住主线程/悬浮窗
                let session = try await withWaitNotice("音频设备响应慢（蓝牙耳机可能在切换模式），请稍候") {
                    try await Task.detached(priority: .userInitiated) { [capture, audioScope] in
                        try capture.start(scope: audioScope)
                    }.value
                }
                folder = session.folder
                lastSession = session
                recordingStartedAt = Date()
                isRecording = true
                if !answerInFlight { status = .listening }   // 等 stopTask 期间旧回答可能把状态改成了"生成中"
                Log.info("开始录制 \(session.folder.path) system=\(session.systemFormat)")
                if stopRequested {
                    Log.info("启动期间收到停止请求，立即停止")
                    stopRecording()
                    return
                }
            } catch {
                status = .error(error.localizedDescription)
                return
            }
            // 麦克风后台启动，不阻塞面试官声音的识别
            let mic = await capture.startMicrophone(mode: micMode)
            guard isRecording, lastSession?.folder == folder else { return }
            lastSession?.micFormat = mic.format
            lastSession?.micIssue = mic.issue
            lastSession?.micDevice = mic.device
            Log.info("麦克风：\(mic.device.map { "\($0)（\(mic.format ?? "")）" } ?? "不录（\(mic.issue ?? "")）")")
        }
    }

    func stopRecording() {
        guard isRecording else {
            if isStarting { stopRequested = true }
            return
        }
        // 不取消防抖：面试官在停止前刚问完的那一题仍然要回答
        // CoreAudio 的停止调用在蓝牙耳机切换模式时可能卡几十秒，放到后台，悬浮窗不冻结。
        // 先停采集（保证之后不会再有音频送进识别器），再让识别器收尾：最后半句会以 final 异步回来
        let capture = self.capture, transcriber = self.transcriber
        stopTask = Task.detached(priority: .userInitiated) {
            capture.stop()
            transcriber?.finish()
        }
        isRecording = false
        remoteLevel = 0
        localLevel = 0
        status = .idle
    }

    /// 结束正在生成的回答（语音问答或圈选），让新的内容独占 reply / status
    private func cancelInFlightAnswer() {
        pendingIsSupplement = false
        answerTask?.cancel()
        answerInFlight = false
        screenInFlight = false
        // 新一轮对话 / 演示：上一次圈选的核对和重试提示都作废（只有这两处调用，语音新问题不走这里）
        pendingSegments = []
        crossCheckTask?.cancel()
        crossChecking = false
        retryNotice = nil
        lastAnswerFailed = false
    }

    /// 新一轮监听 = 新一场对话：清掉上一轮的问题片段、历史、在途回答
    private func resetConversation() {
        demoTask?.cancel()
        debounceTask?.cancel()
        cancelInFlightAnswer()
        speech.stop()
        question = ""
        questionPartial = ""
        reply = ""
        transcript = []
        pendingSegments = []
        lastQuestionSegments = []
        lastQuestionSentAt = nil
        unansweredCarry = nil
        questionAnswered = false
        chatHistory = []
        screenThumbnail = nil
        lastShownQuestion = ""
        lastShownSegments = []
        lastShownReply = ""
    }

    // MARK: - 语音识别

    /// 首次监听时加载模型（约 170MB，后台线程，之后复用），并把系统音频接到识别器
    private func prepareTranscriber() async {
        if hotwordsStale {
            hotwordsStale = false      // 先清标记再读资料：读之后又改了，会再标一次
            transcriber = nil
        }
        if transcriber == nil {
            do {
                let ctx = InterviewContext.load()
                let hotwords = Hotwords.list(context: ctx.resume + "\n" + ctx.notes)
                let recognizer = try await Task.detached(priority: .userInitiated) {
                    try STTModelLocator.makeRecognizer(hotwords: hotwords)
                }.value
                Log.info("语音识别热词 \(hotwords.count) 个")
                transcriber = StreamingTranscriber(source: .remote, recognizer: recognizer) { [weak self] event in
                    Task { @MainActor in self?.handleTranscript(event) }
                }
                sttIssue = nil
            } catch {
                sttIssue = error.localizedDescription
                Log.info("语音识别不可用：\(error.localizedDescription)")
            }
        }
        transcriber?.reset(session: sessionID)
        // 只识别对方（系统音频）：面试官的话才是问题
        capture.onBuffer = { [transcriber] source, buffer in
            if source == .remote { transcriber?.accept(buffer) }
        }
    }

    func handleTranscript(_ event: TranscriptEvent) {
        guard event.source == .remote else { return }
        guard event.session == sessionID else {
            if event.isFinal { Log.info("丢弃上一轮晚到的识别结果：\(event.text)") }
            return
        }
        if !event.isFinal && !event.text.isEmpty && questionPartial.isEmpty {
            Log.info("STT 开始一句：\(event.text)")
        }
        if event.isFinal {
            let line = TranscriptLine(source: event.source,
                                      offset: Date().timeIntervalSince(recordingStartedAt),
                                      text: event.text)
            transcript.append(line)
            appendToTranscriptFile(line)
            Log.info("STT final: \(event.text)")
            questionPartial = ""
            addQuestionSegment(event.text)
            if isRecording { status = answerInFlight ? status : .listening }
        } else {
            questionPartial = event.text
            if !event.text.isEmpty {
                debounceTask?.cancel()   // 面试官还在说，先别答
            } else {
                resumePendingAnswer()    // 半句又消失了（没出 final）：别让刚才的问题一直挂着
            }
            if isRecording && !answerInFlight {
                status = event.text.isEmpty ? .listening : .transcribing
            }
        }
    }

    // MARK: - 回答（Step 4）

    /// 不需要回答的语气词/应答："嗯""好的""OK"……（去掉标点后整句匹配，或有效字符不到 2 个）。
    /// "为什么""怎么做"这类短追问不算。
    nonisolated static let singleCharQuestions: Set<String> = ["谁", "啥", "哪", "咋", "几", "何"]

    nonisolated static func isFiller(_ text: String) -> Bool {
        let core = text.lowercased().filter { $0.isLetter || $0.isNumber }
        // 单字追问（"谁？""啥？""哪？"）是真问题，靠对话历史就能接上；"嗯""哦""啊"这类单字仍算语气词
        if core.count == 1, singleCharQuestions.contains(core) { return false }
        if core.count < 2 { return true }
        let fillers: Set<String> = ["嗯嗯", "嗯哼", "好的", "好好", "好吧", "对对", "对的", "是的", "行的", "可以",
                                    "明白", "了解", "知道了", "没问题", "收到", "谢谢", "ok", "okay", "yes", "yeah",
                                    "yep", "sure", "right", "hmm", "um", "uh", "cool", "nice", "gotit", "thanks", "thankyou"]
        return fillers.contains(core)
    }

    private func addQuestionSegment(_ text: String) {
        // 语气词只看这一句本身：既不触发回答，也不和上一题合并，显示保持不变
        if Self.isFiller(text) {
            Log.info("忽略语气词：\(text)")
            resumePendingAnswer()   // 语气词的 partial 取消过防抖：把前面那个问题重新排上
            return
        }
        if screenInFlight {
            // 圈选分析还在进行：新问题先排队（不合并旧题、不打断圈选），圈选结束后再答
            pendingSegments.append(text)
            Log.info("圈选进行中，问题排队：\(text)")
            return
        }
        if answerInFlight {
            // 回答还在生成时面试官补了一句：不打断你正在看的回答，等它写完再把补充接在下面回答
            pendingSegments.append(text)
            pendingIsSupplement = true
            question = (lastQuestionSegments + pendingSegments).suffix(Self.maxQuestionLines).joined(separator: "\n")
            Log.info("回答进行中有补充，写完后接着答：\(text)")
            return
        }
        let sinceLastQuestion = lastQuestionSentAt.map { ContinuousClock.now - $0 }
        if pendingSegments.isEmpty, let since = sinceLastQuestion, since < Self.continuationWindow,
           !lastQuestionSegments.isEmpty {
            // 刚答完不久面试官又开口：当作补充，回答接在原回答下面
            pendingIsSupplement = true
            Log.info("\(since.formatted(.units(allowed: [.milliseconds]))) 内接着说，作为补充回答")
        } else if pendingIsSupplement && !pendingSegments.isEmpty {
            // 补充还没说完（防抖期间又来一句）：继续累积
        } else {
            pendingIsSupplement = false
            if let carry = unansweredCarry, ContinuousClock.now - carry.at < Self.unansweredCarryWindow,
               pendingSegments.isEmpty {
                // 上一句被模型判"无需回答"，可能其实是半个问题：带上它
                pendingSegments = carry.segments
            }
            if questionAnswered {
                question = ""   // 新问题：清掉上一题
                screenThumbnail = nil
            }
        }
        unansweredCarry = nil
        questionAnswered = false
        pendingSegments.append(text)
        let shown = pendingIsSupplement ? lastQuestionSegments + pendingSegments : pendingSegments
        question = shown.suffix(Self.maxQuestionLines).joined(separator: "\n")
        scheduleAnswer()
    }

    /// 一句话明显是问完了（问号结尾，或"吗/呢/么/嘛"结尾）：不用再等防抖
    nonisolated static func looksLikeCompleteQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        if last == "？" || last == "?" { return true }
        let core = t.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!，, "))
        return ["吗", "呢", "么", "嘛"].contains { core.hasSuffix($0) }
    }

    /// 被打断的防抖（语气词、消失的半句）重新排上；正在回答 / 圈选时由 finishAnswer 负责
    private func resumePendingAnswer() {
        guard !pendingSegments.isEmpty, !answerInFlight, !screenInFlight else { return }
        scheduleAnswer()
    }

    /// 防抖：面试官停下 answerDebounce 后还没继续说，就回答 pendingSegments；明显问完的句子只等 0.15s
    private func scheduleAnswer() {
        debounceTask?.cancel()
        let delay: Duration = pendingSegments.last.map(Self.looksLikeCompleteQuestion) == true ? .milliseconds(150) : Self.answerDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.questionPartial.isEmpty else { return }
            self.answerNow(manual: false)
        }
    }

    /// ⌃⌥A：立即回答当前问题；没有新问题时重新生成上一题
    func answerNow(manual: Bool = true) {
        // 回答还在写、补充在排队：手动 ⌃⌥A 不打断（否则原回答被截断、也进不了历史），写完会接着答补充
        if manual && answerInFlight && pendingIsSupplement && !pendingSegments.isEmpty {
            Log.info("⌃⌥A：当前回答写完后接着答补充")
            return
        }
        debounceTask?.cancel()
        var segments = pendingSegments
        if segments.isEmpty && manual { segments = lastQuestionSegments }
        // 上一题失败了（Reply 框里是错误提示）：原问题 + 补充合成一题重新答，不接在错误下面
        if pendingIsSupplement && lastAnswerFailed && !pendingSegments.isEmpty {
            segments = lastQuestionSegments + pendingSegments
        }
        let questionText = segments.joined(separator: " ")
        guard !questionText.isEmpty else { return }
        // 补充：接在当前回答下面答，不覆盖（⌃⌥A 重新生成整题时不算补充）
        let isSupplement = pendingIsSupplement && !pendingSegments.isEmpty && !reply.isEmpty && !lastAnswerFailed
        pendingIsSupplement = false
        if isSupplement {
            answerSupplement(segments)
            return
        }
        pendingSegments = []
        lastQuestionSegments = segments
        lastQuestionSentAt = .now
        questionAnswered = true
        screenThumbnail = nil
        question = segments.suffix(Self.maxQuestionLines).joined(separator: "\n")

        // 模型若判定"无需回答"（寒暄等），要能恢复成上一题的内容
        // 恢复用"上一次完整显示的问答"，不用当前 reply（它可能是刚被取消的半截回答）
        let previous = (question: lastShownQuestion, reply: lastShownReply, segments: lastShownSegments)
        answerTask?.cancel()
        demoTask?.cancel()
        speech.stop()
        reply = ""
        status = .thinking
        answerInFlight = true
        screenInFlight = false

        let config: LLMConfig
        do {
            config = try loadConfig()
            llmIssue = nil
        } catch {
            finishAnswer(error: error)
            return
        }
        let history = Array(chatHistory.suffix(Self.historyTurns * 2))
            + [ChatTurn(role: .user, content: InterviewPrompt.userMessage(question: questionText))]
        let provider = resilientProvider(config)
        let system = InterviewPrompt.system(context: InterviewContext.load(), legacyProfile: config.profile)
        Log.info("LLM 请求（\(config.model)）：\(questionText)")

        answerTask = Task { [weak self] in
            let started = ContinuousClock.now
            var firstTokenAt: Duration?
            var answer = ""
            do {
                for try await chunk in provider.streamReply(system: system, history: history) {
                    guard let self, !Task.isCancelled else { return }
                    if firstTokenAt == nil {
                        firstTokenAt = ContinuousClock.now - started
                        self.status = .answering
                        self.retryNotice = nil
                    }
                    answer += chunk
                    self.reply = answer
                }
                guard let self, !Task.isCancelled else { return }
                if answer.contains(InterviewPrompt.noAnswerMarker) && answer.count < 20 {
                    Log.info("模型判定无需回答：\(questionText)，保留上一题")
                    self.unansweredCarry = (segments, .now)
                    self.lastQuestionSentAt = nil
                    self.question = previous.question
                    self.reply = previous.reply
                    self.lastQuestionSegments = previous.segments
                    // 判"无需回答"期间面试官又说了一句：那句不是上一题的补充，连同被判掉的这句一起当新问题答
                    let queuedAsNew = self.pendingIsSupplement && !self.pendingSegments.isEmpty
                    if queuedAsNew {
                        self.pendingIsSupplement = false
                        self.pendingSegments = segments + self.pendingSegments
                        self.unansweredCarry = nil
                    }
                    self.finishAnswer(error: nil)
                    if queuedAsNew { self.resumePendingAnswer() }
                    return
                }
                self.lastShownQuestion = self.question
                self.lastShownReply = self.reply
                self.lastShownSegments = segments
                let total = ContinuousClock.now - started
                Log.info("LLM 完成：首字 \(firstTokenAt?.formatted(.units(allowed: [.milliseconds])) ?? "-")，总计 \(total.formatted(.units(allowed: [.milliseconds])))，\(answer.count) 字")
                self.chatHistory += [history.last!, ChatTurn(role: .assistant, content: InterviewPrompt.forHistory(answer))]
                self.appendToTranscriptFile(TranscriptLine(source: .local,
                                                           offset: Date().timeIntervalSince(self.recordingStartedAt),
                                                           text: "[AI] " + answer.replacingOccurrences(of: "\n", with: " ")))
                self.finishAnswer(error: nil)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.finishAnswer(error: error)
            }
        }
    }

    /// 补充提问：保留原回答，下面接"补充：…"和针对补充的回答；历史里带着前面的问答，模型只答补充的部分
    private func answerSupplement(_ segments: [String]) {
        // 原问题用上一题本身（question 此时已经把补充拼进去显示了）
        let base = (question: lastQuestionSegments.suffix(Self.maxQuestionLines).joined(separator: "\n"),
                    reply: reply, segments: lastQuestionSegments)
        let supplementText = segments.joined(separator: " ")
        pendingSegments = []
        lastQuestionSegments = base.segments + segments
        lastQuestionSentAt = .now
        questionAnswered = true
        question = lastQuestionSegments.suffix(Self.maxQuestionLines).joined(separator: "\n")

        answerTask?.cancel()
        demoTask?.cancel()
        speech.stop()
        let prefix = base.reply + "\n\n**补充：\(supplementText)**\n"
        reply = prefix
        status = .thinking
        answerInFlight = true
        screenInFlight = false

        let config: LLMConfig
        do {
            config = try loadConfig()
            llmIssue = nil
        } catch {
            reply = base.reply
            finishAnswer(error: error, keepingReply: true)
            return
        }
        let user = ChatTurn(role: .user, content: InterviewPrompt.supplementMessage(supplementText))
        let history = Array(chatHistory.suffix(Self.historyTurns * 2)) + [user]
        let provider = resilientProvider(config)
        let system = InterviewPrompt.system(context: InterviewContext.load(), legacyProfile: config.profile)
        Log.info("LLM 请求（\(config.model)，补充）：\(supplementText)")

        answerTask = Task { [weak self] in
            var answer = ""
            do {
                for try await chunk in provider.streamReply(system: system, history: history) {
                    guard let self, !Task.isCancelled else { return }
                    if answer.isEmpty { self.status = .answering; self.retryNotice = nil }
                    answer += chunk
                    self.reply = prefix + answer
                }
                guard let self, !Task.isCancelled else { return }
                if answer.contains(InterviewPrompt.noAnswerMarker) && answer.count < 20 {
                    // 补充只是寒暄/过渡：去掉"补充"标题，原回答原样保留
                    Log.info("补充被判定无需回答：\(supplementText)")
                    self.reply = base.reply
                    self.question = base.question
                    self.lastQuestionSegments = base.segments
                    self.finishAnswer(error: nil)
                    return
                }
                self.lastShownQuestion = self.question
                self.lastShownReply = self.reply
                self.lastShownSegments = self.lastQuestionSegments
                self.chatHistory += [user, ChatTurn(role: .assistant, content: InterviewPrompt.forHistory(answer))]
                self.appendToTranscriptFile(TranscriptLine(source: .local,
                                                           offset: Date().timeIntervalSince(self.recordingStartedAt),
                                                           text: "[AI 补充] " + answer.replacingOccurrences(of: "\n", with: " ")))
                self.finishAnswer(error: nil)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.reply = base.reply
                self.finishAnswer(error: error, keepingReply: true)
            }
        }
    }

    // MARK: - 即圈即搜

    /// ⌃⌥F：定格屏幕 -> 圈选 -> 本机 OCR -> 交给 AI
    func startScreenSearch() {
        guard !isScreenSearching else { return }
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            ScreenCapture.openPrivacySettings()
            showScreenSearchError("即圈即搜需要「屏幕与系统录音」权限：在 系统设置 › 隐私与安全性 › 屏幕与系统录音 里打开 API2Human，然后退出并重新打开 App。")
            return
        }
        isScreenSearching = true
        Task { [weak self] in
            do {
                let shots = try await ScreenCapture.captureAllScreens()
                LassoOverlay.present(shots: shots) { [weak self] image in
                    guard let self else { return }
                    self.isScreenSearching = false
                    if let image { self.answerScreen(image) }
                }
            } catch {
                self?.isScreenSearching = false
                self?.showScreenSearchError("截屏失败：\(error.localizedDescription)")
            }
        }
    }

    /// 圈选还没开始就失败（没权限、截屏出错）：不打断正在生成的回答（也不弄丢圈选期间排队的问题），
    /// 有回答在生成时只记日志；空闲时才把错误显示在 Reply 框
    private func showScreenSearchError(_ message: String) {
        Log.info("即圈即搜失败：\(message)")
        guard !answerInFlight else { return }
        reply = "⚠️ \(message)"
        status = .error("即圈即搜失败")
        lastQuestionSentAt = nil   // 下一句是新问题，别当成"补充"接在这条错误下面
        lastAnswerFailed = true    // 已经在排的补充：连同原问题重答，不接在这条错误下面
    }

    /// 面试官最近 60 秒说的话（最多 3 句）+ 正在说的半句：给圈选内容配上"他问的是什么"
    private func recentInterviewerSpeech() -> String {
        let now = Date().timeIntervalSince(recordingStartedAt)
        var lines = transcript.filter { $0.source == .remote && now - $0.offset < 60 }.suffix(3).map(\.text)
        if !questionPartial.isEmpty { lines.append(questionPartial) }
        return lines.joined(separator: " ")
    }

    func answerScreen(_ image: CGImage) {
        debounceTask?.cancel()
        answerTask?.cancel()
        crossCheckTask?.cancel()     // 上一次圈选的核对已经没意义了
        crossChecking = false
        demoTask?.cancel()
        speech.stop()

        let speechText = isRecording ? recentInterviewerSpeech() : ""
        pendingSegments = []            // 面试官刚才的话已经随圈选一起发出
        pendingIsSupplement = false     // 圈选是新的一题：之前排着的"补充"状态作废，否则圈选期间排队的问题会被当成补充
        lastAnswerFailed = false
        lastQuestionSegments = []       // ⌃⌥A 不能重答圈选之前的语音问题（它可能刚被圈选打断、根本没答过）
        questionAnswered = true
        lastQuestionSentAt = nil
        screenThumbnail = NSImage(cgImage: image, size: .zero)
        question = "🔍 屏幕圈选" + (speechText.isEmpty ? "" : "\n\(speechText)")
        reply = ""
        status = .thinking
        answerInFlight = true
        screenInFlight = true

        answerTask = Task { [weak self] in
            do {
                let ocrStarted = ContinuousClock.now
                let rawOCR = TextRecognizer.isWarm
                    ? try await TextRecognizer.recognize(image)
                    : try await self?.withWaitNotice("文字识别首次加载，约 10~30 秒", after: .zero) {
                        try await TextRecognizer.recognize(image)
                    } ?? ""
                guard let self, !Task.isCancelled else { return }
                guard !rawOCR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finishAnswer(error: LLMError.api("圈选区域里没有识别出文字，换个范围再圈一次"))
                    return
                }
                Log.info("即圈即搜 OCR \(ContinuousClock.now - ocrStarted)，\(rawOCR.count) 字")

                var config = try self.loadConfig()
                config.model = config.screenModel ?? config.model
                // 圈选的输出 = 隐藏推演 + 三段，800 token 容易被截断
                config.maxTokens = max(config.maxTokens ?? 800, 1600)
                let found = await Task.detached(priority: .userInitiated) { ProjectCodeSearch.search(ocr: rawOCR) }.value
                guard !Task.isCancelled else { return }
                let ocr = found.correctedOCR
                let user = ChatTurn(role: .user, content: InterviewPrompt.screenMessage(ocr: ocr, speech: speechText, project: found.context))
                let history = Array(self.chatHistory.suffix(Self.historyTurns * 2)) + [user]
                let system = InterviewPrompt.system(context: InterviewContext.load(), legacyProfile: config.profile)
                Log.info("LLM 请求（\(config.model)，屏幕圈选，双路交叉核对）")
                let provider = self.resilientProvider(config)

                // 第二路：同样的请求在后台跑完，用来和显示的那一路比较结论
                var checkConfig = config
                checkConfig.model = config.screenCheckModel ?? config.model
                checkConfig.thinking = config.screenCheckThinking ?? config.thinking
                let checkProvider = self.makeProvider(checkConfig)
                let checker = Task.detached(priority: .userInitiated) { () -> String? in
                    var text = ""
                    do {
                        for try await chunk in checkProvider.streamReply(system: system, history: history) { text += chunk }
                    } catch { return nil }
                    return InterviewPrompt.forHistory(text)
                }
                // 主路没写完就被取消（新圈选、手动打断）或出错时，第二路一起停
                var mainFinished = false
                defer { if !mainFinished { checker.cancel() } }

                let started = ContinuousClock.now
                var first: Duration?
                var answer = ""
                for try await chunk in provider.streamReply(system: system, history: history) {
                    guard !Task.isCancelled else { return }
                    answer += chunk
                    let visible = InterviewPrompt.stripTrace(answer)
                    if first == nil && !visible.isEmpty { first = ContinuousClock.now - started; self.status = .answering; self.retryNotice = nil }
                    self.reply = visible
                }
                guard !Task.isCancelled else { return }
                Log.info("LLM 完成（屏幕圈选）：首字 \(first.map { "\($0)" } ?? "-")，\(answer.count) 字")
                answer = InterviewPrompt.stripTrace(answer)

                // 记进对话历史：面试官接着问"那怎么改"时 AI 知道说的是这段代码
                self.chatHistory += [user, ChatTurn(role: .assistant, content: InterviewPrompt.forHistory(answer))]
                self.lastShownQuestion = self.question
                self.lastShownReply = self.reply
                self.lastShownSegments = []
                self.appendToTranscriptFile(TranscriptLine(source: .local,
                                                           offset: Date().timeIntervalSince(self.recordingStartedAt),
                                                           text: "[屏幕圈选] " + ocr.replacingOccurrences(of: "\n", with: " ⏎ ")))
                self.appendToTranscriptFile(TranscriptLine(source: .local,
                                                           offset: Date().timeIntervalSince(self.recordingStartedAt),
                                                           text: "[AI] " + answer.replacingOccurrences(of: "\n", with: " ")))
                mainFinished = true
                self.startCrossCheck(checker, shown: answer)
                self.finishAnswer(error: nil)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.finishAnswer(error: error)
            }
        }
    }

    /// 等第二路（Flash + 思考，实测 8~31 秒，最多等 crossCheckTimeout），结论不一致时：
    /// 屏幕上还是这条回答就在末尾追加提醒；已经换成别的回答就只改对话历史，不打扰正在看的内容
    private func startCrossCheck(_ checker: Task<String?, Never>, shown answer: String) {
        crossChecking = true
        let timeout = crossCheckTimeout
        crossCheckTask = Task { [weak self] in
            let other = await withTaskGroup(of: String?.self) { group in
                // Task.value 本身不响应取消：要把取消转给第二路，超时时 cancelAll 才能真正结束等待
                group.addTask { await withTaskCancellationHandler { await checker.value } onCancel: { checker.cancel() } }
                group.addTask { try? await Task.sleep(for: timeout); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, !Task.isCancelled else { return }
            self.crossChecking = false
            guard let other, let note = InterviewPrompt.crossCheckNote(shown: answer, other: other) else {
                Log.info(other == nil ? "交叉核对：第二路超时或失败，跳过" : "交叉核对：两次结论一致")
                return
            }
            Log.info("交叉核对不一致")
            let old = InterviewPrompt.forHistory(answer)
            if let i = self.chatHistory.lastIndex(where: { $0.role == .assistant && $0.content == old }) {
                self.chatHistory[i] = ChatTurn(role: .assistant, content: InterviewPrompt.forHistory(answer + note))
            }
            if self.reply == answer {
                self.reply = answer + note
                if self.lastShownReply == answer { self.lastShownReply = self.reply }
            }
        }
    }

    /// 主接口（失败重试一次）→ 备用接口（llm.json 的 fallback）
    private func resilientProvider(_ config: LLMConfig) -> any LLMProvider {
        retryNotice = nil
        var p = ResilientProvider.chain(for: config, baseTimeout: firstChunkTimeout, make: makeProvider)
        p.retryDelay = retryDelay
        p.onRetry = { [weak self] label in
            Task { @MainActor in
                // 回调晚到（回答已结束或被取消）就不显示，否则提示会一直挂着
                guard let self, self.answerInFlight else { return }
                self.retryNotice = label == ResilientProvider.primaryRetryLabel ? "接口出错，重试中" : "改用\(label)"
            }
        }
        return p
    }

    /// keepingReply：补充没答上时，原回答好好的，错误接在它下面，而不是整个换成错误提示
    private func finishAnswer(error: Error?, keepingReply: Bool = false) {
        let wasScreen = screenInFlight
        // 只有语音问答失败才需要"补充连同原问题重答"；圈选失败和之前的语音问题无关；
        // 补充失败时原回答还在，下一句照常当补充接着答
        lastAnswerFailed = error != nil && !wasScreen && !keepingReply
        answerInFlight = false
        screenInFlight = false
        retryNotice = nil
        // 圈选期间排队的问题、回答期间面试官的补充：这一轮结束后照常回答
        if (wasScreen || pendingIsSupplement), !pendingSegments.isEmpty {
            questionAnswered = false
            scheduleAnswer()
        }
        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            llmIssue = message
            reply = keepingReply && !reply.isEmpty ? reply + "\n\n⚠️ 补充没答上：\(message)" : "⚠️ \(message)"
            Log.info("LLM 失败：\(message)")
            status = .error("AI 回答失败")
        } else {
            status = isRecording ? .listening : .idle
        }
    }

    /// 每轮录音目录里同时写一份 transcript.txt，方便对照 system.wav 检查识别效果
    private func appendToTranscriptFile(_ line: TranscriptLine) {
        guard let folder = lastSession?.folder else { return }
        let url = folder.appendingPathComponent("transcript.txt")
        let entry = Data((line.formatted + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: entry)
        } else {
            try? entry.write(to: url)
        }
    }

    /// 退出前同步收尾：停止采集并关闭录音文件（AVAudioFile 析构时才写好 WAV 头，直接退出会留下损坏的文件）
    func shutdown() {
        // 不看 isRecording：刚点了停止、后台 stopTask 还没跑完时退出也要收尾。
        // capture.stop() 幂等，并和后台的 start/stop 串行（AudioCaptureManager 内部加锁），这里会等它们跑完
        capture.stop()
        Log.info("退出前已停止录音")
    }

    func toggleMute() {
        isMicMuted.toggle()
        capture.setMicMuted(isMicMuted)
    }

    func openRecordingsFolder() {
        let url = lastSession?.folder ?? AudioCaptureManager.recordingsRoot
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// 面试资料是否已填写（悬浮窗用来提醒）
    private(set) var hasInterviewContext = !InterviewContext.load().isEmpty

    func openInterviewContext() {
        ContextWindowController.shared.show()
    }

    /// 资料窗口保存后调用
    func interviewContextDidChange() {
        hasInterviewContext = !InterviewContext.load().isEmpty
        // 热词来自角色卡技能档：标记过期，下次开始监听时按新资料重建识别器
        // （不在这里直接置空：录音中 / 启动中置空会和 prepareTranscriber、stopRecording 抢同一个实例）
        hotwordsStale = true
    }

    /// 菜单：添加 / 清空代码项目目录（即圈即搜用来定位代码在项目里的位置）
    func addProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择代码项目目录：圈选代码时会在这里查它属于哪个文件、被谁调用"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(ProjectCodeSearch.addProjectDir)
        projectDirCount = ProjectCodeSearch.projectDirs.count
    }

    func clearProjectDirectories() {
        ProjectCodeSearch.clearProjectDirs()
        projectDirCount = 0
    }

    private(set) var projectDirCount = ProjectCodeSearch.projectDirs.count

    /// 菜单"编辑 AI 配置"：新设备上还没有 llm.json 时先生成模板（不含任何密钥），再用文本编辑打开
    func openLLMConfig() {
        let url = LLMConfig.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            {
              "baseURL": "https://api.deepseek.com/anthropic",
              "authToken": "在这里填你的 API Key",
              "model": "deepseek-flash",
              "thinking": false,
              "maxTokens": 800,
              "screenModel": "deepseek-flash",
              "screenCheckModel": "deepseek-flash",
              "screenCheckThinking": true,
              "profile": ""
            }
            """
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func say() {
        if speech.isSpeaking {
            speech.stop()
        } else if !reply.isEmpty {
            // 监听中（在开会）且外放：朗读声会从扬声器传进会议麦克风，对方能听见 -> 不读
            let output = HAL.defaultOutputInfo()
            if isRecording && OutputRoute.isSpeaker(transport: output.transport, dataSource: output.dataSource) {
                Log.info("外放中，取消朗读")
                status = .error("外放时不朗读：会被会议麦克风收进去，戴耳机后再用")
                return
            }
            // 错误提示（"⚠️ …"）不读出来，只读回答本身
            let spoken = reply.components(separatedBy: "\n").filter { !$0.hasPrefix("⚠️") }.joined(separator: "\n")
            if !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speech.speak(spoken) }
        }
    }

    func toggleReaderMode() {
        speech.stop()
        isReaderMode.toggle()
    }

    /// Step 1 用的假数据：模拟"识别 -> 思考 -> 流式输出"，用于验证悬浮窗渲染效果。
    func runDemo() {
        demoTask?.cancel()
        debounceTask?.cancel()
        cancelInFlightAnswer()
        speech.stop()
        demoTask = Task { [weak self] in
            guard let self else { return }
            let q = "能介绍一下 Swift 里 actor 和 class 的区别吗？在什么场景下你会选择 actor？"
            let a = """
            **核心区别**
            1. actor 是引用类型，但自带数据隔离：同一时间只有一个任务能访问其可变状态，编译器强制跨 actor 调用必须 await。
            2. class 没有并发保护，需要自己加锁或用串行队列。
            3. actor 不支持继承。

            **选型**
            - 共享可变状态被多个并发任务访问（如缓存、连接池、下载管理器）→ actor。
            - UI 相关状态 → @MainActor 的 class。
            - 纯值语义数据 → struct。
            """
            self.reply = ""
            self.question = ""
            self.questionPartial = ""
            self.status = .transcribing
            for ch in q {
                guard !Task.isCancelled else { return }
                self.question.append(ch)
                try? await Task.sleep(for: .milliseconds(18))
            }
            self.status = .thinking
            try? await Task.sleep(for: .milliseconds(450))
            self.status = .answering
            // 以 2~4 个字符为一个 "token" 模拟 SSE 流
            var idx = a.startIndex
            while idx < a.endIndex {
                guard !Task.isCancelled else { return }
                let next = a.index(idx, offsetBy: Int.random(in: 2...4), limitedBy: a.endIndex) ?? a.endIndex
                self.reply += a[idx..<next]
                idx = next
                try? await Task.sleep(for: .milliseconds(25))
            }
            self.status = self.isRecording ? .listening : .idle
        }
    }
}

struct TranscriptLine: Sendable {
    let source: AudioSource
    let offset: TimeInterval   // 距本轮监听开始的秒数
    let text: String

    var formatted: String {
        let t = Int(offset)
        return String(format: "[%02d:%02d] %@：%@", t / 60, t % 60, source == .remote ? "对方" : "我", text)
    }
}
