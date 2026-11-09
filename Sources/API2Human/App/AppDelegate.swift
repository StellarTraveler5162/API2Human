import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panelController: FloatingPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let question = Self.argument(after: "--selftest-llm") {
            Self.runLLMTest(question: question)
            return
        }
        if CommandLine.arguments.contains("--selftest-audio-route") {
            // 诊断：输入设备、谁被占用、自动选择会选哪个、当前算不算外放（演练时用）
            for d in HAL.inputDevices() {
                print("输入设备：\(d.name) | uid=\(d.uid) | \(d.isBluetooth ? "蓝牙" : d.isVirtual ? "虚拟" : "有线/内置") | \(d.isRunningSomewhere ? "正被占用" : "空闲")")
            }
            let out = HAL.defaultOutputInfo()
            let choice = MicrophoneSelector.choose(HAL.inputDevices(), defaultOutputUID: out.uid)
            print("自动选择：\(choice.device?.name ?? "不录")——\(choice.reason)")
            print("默认输出：\(out.uid ?? "无")，\(OutputRoute.isSpeaker(transport: out.transport, dataSource: out.dataSource) ? "外放（监听时禁用朗读）" : "耳机")")
            exit(0)
        }
        if let uid = Self.argument(after: "--selftest-mic-device") {
            // 调试：在指定 UID 的输入设备上录 3 秒，报告收到多少帧
            Task.detached {
                guard let device = HAL.inputDevices().first(where: { $0.uid == uid }) else { print("找不到设备 \(uid)"); exit(1) }
                final class Counter: @unchecked Sendable { var frames = 0; var rate = 0.0; let lock = NSLock() }
                let counter = Counter()
                let mic = MicrophoneCapture()
                do {
                    let format = try mic.start(device: device) { buf in
                        counter.lock.withLock { counter.frames += Int(buf.frameLength); counter.rate = buf.format.sampleRate }
                    }
                    print("已在「\(device.name)」上开始录音：\(format)")
                    try? await Task.sleep(for: .seconds(3))
                    mic.stop()
                    counter.lock.withLock { print("3 秒收到 \(counter.frames) 帧（单声道 \(Int(counter.rate))Hz），停止正常") }
                    exit(0)
                } catch { print("失败：\(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let path = Self.argument(after: "--selftest-screen-image") {
            Self.runScreenImageTest(path: path)
            return
        }
        if let out = Self.argument(after: "--selftest-capture") {
            // 调试：检查本 App 的屏幕录制权限并截一张全屏
            Task { @MainActor in
                guard ScreenCapture.hasPermission else { print("没有屏幕录制权限"); exit(1) }
                do {
                    let shots = try await ScreenCapture.captureAllScreens()
                    guard let shot = shots.first,
                          let png = NSBitmapImageRep(cgImage: shot.image).representation(using: .png, properties: [:]) else {
                        print("截图失败：没有截到任何显示器"); exit(1)
                    }
                    try png.write(to: URL(fileURLWithPath: out))
                    print("截图成功 \(shot.image.width)x\(shot.image.height) -> \(out)")
                    exit(0)
                } catch { print("截图失败：\(error)"); exit(1) }
            }
            return
        }
        if let path = Self.argument(after: "--selftest-card-ai-view") {
            // 调试：输出角色卡发给面试 AI 的内容，用来和 validate_a2hcard.py --ai-view 对比
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            print(CandidateCard.forAIFile(text), terminator: "")
            exit(0)
        }
        if let path = Self.argument(after: "--selftest-import") {
            do {
                let text = try InterviewContext.importText(from: URL(fileURLWithPath: path))
                print("导入成功 \(text.count) 字：\(text.prefix(60).replacingOccurrences(of: "\n", with: " / "))")
                exit(0)
            } catch { print("导入失败：\(error.localizedDescription)"); exit(1) }
        }
        if let path = Self.argument(after: "--selftest-stt-file") {
            Self.runFileTranscriptionTest(path: path)
            return
        }

        // 不进 Dock、不进 ⌘Tab：开会时切窗口不会切到我们
        NSApp.setActivationPolicy(.accessory)

        let controller = FloatingPanelController(state: state)
        controller.startObserving()
        panelController = controller

        registerHotKeys()
        TextRecognizer.warmUp()
        if CommandLine.arguments.contains("--open-context") { state.openInterviewContext() }
        if CommandLine.arguments.contains("--selftest-open-lasso") {
            Task { @MainActor [state] in
                try? await Task.sleep(for: .seconds(2))
                state.startScreenSearch()
            }
        }
        runSelfTestIfRequested()
    }

    /// 调试：`open API2Human.app --args --selftest-record 6` 自动录 6 秒后停止
    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest-record"),
              i + 1 < args.count, let seconds = Double(args[i + 1]) else { return }
        if args.contains("--no-mic") { state.micModeIsTemporary = true; state.micMode = .off }
        // --selftest-cycles N：连续开始/停止 N 轮（验证跨轮复用识别器、后台停止）
        let cycles = Self.argument(after: "--selftest-cycles").flatMap(Int.init) ?? 1
        Task { @MainActor [state] in
            for cycle in 1...max(1, cycles) {
                state.toggleRecording()          // 走真实入口（和按钮、⌃⌥R 一样）
                try? await Task.sleep(for: .seconds(seconds))
                Log.info("selftest 第 \(cycle) 轮: status=\(state.status.label) folder=\(state.lastSession?.folder.path ?? "nil")")
                state.toggleRecording()
                try? await Task.sleep(for: .seconds(2))
            }
            Log.info("selftest 结束")
        }
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 调试：`API2Human.app/Contents/MacOS/API2Human --selftest-stt-file x.wav`
    /// 把文件按 100ms 一块喂给流式识别器（和实时采集同一条代码路径），结果打到 stdout 后退出。
    private static func runFileTranscriptionTest(path: String) {
        Task.detached {
            @Sendable func out(_ s: String) { print(s); fflush(stdout) }
            do {
                let t0 = Date()
                // 默认和 App 一样用内置热词 + 角色卡技能；A2H_HOTWORDS="三次握手,进程" 换成指定的，A2H_HOTWORDS=none 关闭
                let env = ProcessInfo.processInfo.environment["A2H_HOTWORDS"]
                let hotwords = env == "none" ? [] : env?.split(separator: ",").map(String.init)
                    ?? { let c = InterviewContext.load(); return Hotwords.list(context: c.resume + "\n" + c.notes) }()
                let score = ProcessInfo.processInfo.environment["A2H_HOTWORD_SCORE"].flatMap(Float.init) ?? Hotwords.defaultScore
                let recognizer = try SherpaOnnxRecognizer(model: .init(directory: STTModelLocator.locate()), hotwords: hotwords, hotwordScore: score)
                out(String(format: "模型加载 %.2fs（热词 %d 个）", Date().timeIntervalSince(t0), hotwords.count))

                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                let format = file.processingFormat
                out("音频 \(Int(format.sampleRate))Hz \(format.channelCount)ch \(String(format: "%.1f", Double(file.length) / format.sampleRate))s")

                let transcriber = StreamingTranscriber(source: .remote, recognizer: recognizer) { event in
                    if event.isFinal { out("FINAL   \(event.text)") }
                    else if !event.text.isEmpty { out("partial \(event.text)") }
                }
                let chunk = AVAudioFrameCount(format.sampleRate / 10)
                let t1 = Date()
                while file.framePosition < file.length {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                    try file.read(into: buf, frameCount: chunk)
                    transcriber.accept(buf)
                }
                transcriber.finish()
                transcriber.drain()
                let audio = Double(file.length) / format.sampleRate
                let cost = Date().timeIntervalSince(t1)
                out(String(format: "识别耗时 %.2fs，实时率 RTF=%.3f", cost, cost / audio))
                exit(0)
            } catch {
                out("失败：\(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// 调试：`API2Human --selftest-llm "说一下 TCP 三次握手"`，流式打印回答和首字延迟
    private static func runLLMTest(question: String) {
        Task.detached {
            @Sendable func out(_ s: String, newline: Bool = true) {
                print(s, terminator: newline ? "\n" : ""); fflush(stdout)
            }
            do {
                var config = try LLMConfig.load()
                // A2H_BREAK_PRIMARY=1：主接口换成连不上的地址，备用用原来的配置，验证自动切换
                if ProcessInfo.processInfo.environment["A2H_BREAK_PRIMARY"] == "1" {
                    config.fallback = .init(baseURL: config.baseURL, authToken: config.authToken, model: config.model)
                    config.baseURL = "https://127.0.0.1:9"
                    config.model += "-broken"
                }
                out("→ \(config.messagesURL?.absoluteString ?? "?")  model=\(config.model)" +
                    (config.fallbackConfig.map { "，备用 \($0.model)" } ?? ""))
                // 和 App 同一套组装（超时、备用、Key 问题直接切备用），自测结果才有参考价值
                var provider = ResilientProvider.chain(for: config) { AnthropicMessagesProvider(config: $0) }
                provider.onRetry = { out("[重试：\($0)]") }
                let started = ContinuousClock.now
                var first: Duration?
                for try await chunk in provider.streamReply(
                    system: InterviewPrompt.system(context: InterviewContext.load(), legacyProfile: config.profile),
                    history: [ChatTurn(role: .user, content: InterviewPrompt.userMessage(question: question))]) {
                    if first == nil { first = ContinuousClock.now - started }
                    out(chunk, newline: false)
                }
                out("\n--- 首字 \(first.map { "\($0)" } ?? "-")，总计 \(ContinuousClock.now - started)")
                exit(0)
            } catch {
                out("\n失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                exit(1)
            }
        }
    }

    /// 调试：`API2Human --selftest-screen-image code.png ["面试官的话"]`：走 OCR + 屏幕圈选提示词 + screenModel
    private static func runScreenImageTest(path: String) {
        let args = CommandLine.arguments
        let speech = args.firstIndex(of: path).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        Task.detached {
            @Sendable func out(_ s: String, newline: Bool = true) { print(s, terminator: newline ? "\n" : ""); fflush(stdout) }
            do {
                guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    out("读不了图片"); exit(1)
                }
                var t = ContinuousClock.now
                let rawOCR = try await TextRecognizer.recognize(image)
                out("OCR \(ContinuousClock.now - t)：\n\(rawOCR)\n---")
                t = ContinuousClock.now
                let found = ProjectCodeSearch.search(ocr: rawOCR)
                let ocr = found.correctedOCR, project = found.context
                out("项目检索 \(ContinuousClock.now - t)：\n\(project ?? "（没找到）")\n---\n校正后的 OCR：\n\(ocr)\n---")
                var config = try LLMConfig.load()
                config.model = config.screenModel ?? config.model
                out("model=\(config.model)")
                t = ContinuousClock.now
                var first: Duration?
                var full = ""
                let provider = AnthropicMessagesProvider(config: config)
                let system = InterviewPrompt.system(context: InterviewContext.load(), legacyProfile: config.profile)
                let history = [ChatTurn(role: .user, content: InterviewPrompt.screenMessage(ocr: ocr, speech: speech, project: project))]
                var checkConfig = config
                checkConfig.model = config.screenCheckModel ?? config.model
                checkConfig.thinking = config.screenCheckThinking ?? config.thinking
                let checkProvider = AnthropicMessagesProvider(config: checkConfig)
                let checkStarted = ContinuousClock.now
                let checker = Task.detached { () -> String in
                    var text = ""
                    for try await chunk in checkProvider.streamReply(system: system, history: history) { text += chunk }
                    out("[第二路 \(checkConfig.model) thinking=\(checkConfig.thinking == true) 用时 \(ContinuousClock.now - checkStarted)，\(text.count) 字]")
                    return InterviewPrompt.stripTrace(text)
                }
                for try await chunk in provider.streamReply(system: system, history: history) {
                    full += chunk
                    if first == nil && !InterviewPrompt.stripTrace(full).isEmpty { first = ContinuousClock.now - t }
                }
                if let other = try? await checker.value,
                   let note = InterviewPrompt.crossCheckNote(shown: InterviewPrompt.stripTrace(full), other: other) {
                    full = InterviewPrompt.stripTrace(full) + note
                }
                if ProcessInfo.processInfo.environment["A2H_RAW"] == "1" { out("【原始输出】\n" + full + "\n【原始输出结束】") }
                out(InterviewPrompt.stripTrace(full))
                out("--- 可见首字 \(first.map { "\($0)" } ?? "-")，总计 \(ContinuousClock.now - t)")
                exit(0)
            } catch { out("失败：\(error.localizedDescription)"); exit(1) }
        }
    }

    /// 双击 .a2hcard 文件 / 拖到 App 图标上：打开面试资料窗口并载入（用户确认后再保存）
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == CandidateCard.fileExtension }) else { return }
        ContextWindowController.shared.show(importing: url)
    }

    /// 面试资料有未保存的修改时，退出前先问一下
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ContextWindowController.shared.confirmUnsavedChanges() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 全局快捷键：焦点在会议软件里时也能用（Carbon 热键，无需辅助功能权限）
    private func registerHotKeys() {
        let mods = controlKey | optionKey
        let hk = GlobalHotKeys.shared
        hk.register(keyCode: kVK_ANSI_H, modifiers: mods) { [state] in state.isPanelVisible.toggle() }
        hk.register(keyCode: kVK_ANSI_R, modifiers: mods) { [state] in state.toggleRecording() }
        hk.register(keyCode: kVK_ANSI_M, modifiers: mods) { [state] in state.toggleMute() }
        hk.register(keyCode: kVK_ANSI_S, modifiers: mods) { [state] in state.say() }
        hk.register(keyCode: kVK_ANSI_D, modifiers: mods) { [state] in state.runDemo() }
        hk.register(keyCode: kVK_ANSI_A, modifiers: mods) { [state] in state.answerNow() }
        hk.register(keyCode: kVK_ANSI_F, modifiers: mods) { [state] in state.startScreenSearch() }
    }
}
