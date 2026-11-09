import SwiftUI

struct FloatingAssistantView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.isRecording {
                HStack(spacing: 12) {
                    LevelMeter(label: "对方", systemImage: "speaker.wave.2.fill",
                               level: state.remoteLevel, tint: .blue)
                    if let issue = state.lastSession?.micIssue {
                        Label(issue, systemImage: "mic.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(issue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LevelMeter(label: "我", systemImage: state.isMicMuted ? "mic.slash.fill" : "mic.fill",
                                   level: state.isMicMuted ? 0 : state.localLevel, tint: .green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                if !state.isReaderMode {
                    questionSection
                }
                replySection
            }
            .padding(12)
            Divider().opacity(0.4)
            actionBar
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy(duration: 0.2), value: state.isReaderMode)
    }

    // MARK: Header（拖动区域）

    private var header: some View {
        HStack(spacing: 6) {
            // 监听开关（原主界面的"录音"）
            HeaderIconButton(
                systemImage: state.isRecording ? "stop.circle.fill" : "record.circle",
                tint: state.isRecording ? .red : .secondary,
                help: state.isRecording ? "停止监听（⌃⌥R）" : "开始监听（⌃⌥R）"
            ) { state.toggleRecording() }

            // 麦克风静音
            HeaderIconButton(
                systemImage: state.isMicMuted ? "mic.slash.fill" : "mic.fill",
                tint: state.isMicMuted ? .red : .secondary,
                help: state.isMicMuted ? "取消静音（⌃⌥M）" : "麦克风静音（⌃⌥M）"
            ) { state.toggleMute() }

            // 状态指示灯
            StatusDot(color: state.status.color, pulsing: state.status != .idle)
                .padding(.leading, 4)
            Text(state.status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let hint = state.headerHint {
                Text("· \(hint)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(hint == "交叉核对中" ? "即圈即搜的第二路还在核对结论，不一致时会在圈选回答末尾提醒；不影响回答新问题" : hint)
            }

            Spacer(minLength: 4)

            // 即圈即搜：圈出屏幕上的代码 / 题目
            HeaderIconButton(systemImage: "text.viewfinder", tint: .secondary,
                             help: "即圈即搜：圈出屏幕上的代码或题目（⌃⌥F）") { state.startScreenSearch() }

            // 面试资料（简历 / JD）：没填时图标变橙色提醒
            HeaderIconButton(
                systemImage: state.hasInterviewContext ? "person.text.rectangle.fill" : "person.text.rectangle",
                tint: state.hasInterviewContext ? .secondary : .orange,
                help: state.hasInterviewContext ? "面试资料（简历 / JD）" : "还没填面试资料：AI 的回答不会贴合你的真实经历"
            ) { state.openInterviewContext() }

            Slider(value: Binding(get: { state.panelOpacity },
                                  set: { state.panelOpacity = $0 }),
                   in: 0.3...1)
                .controlSize(.mini)
                .frame(width: 56)
                .help("透明度")

            HeaderIconButton(systemImage: "xmark", tint: .secondary,
                             help: "隐藏悬浮窗（⌃⌥H 或菜单栏图标恢复）") {
                state.isPanelVisible = false
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    // MARK: Question

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "Question", systemImage: "person.wave.2")
            if let thumbnail = state.screenThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 90, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.orange.opacity(0.6)))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        questionText
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("questionBottom")
                    }
                }
                .onChange(of: state.questionPartial) { proxy.scrollTo("questionBottom", anchor: .bottom) }
                .onChange(of: state.question) { proxy.scrollTo("questionBottom", anchor: .bottom) }
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 已断句的文字用正常颜色，正在说的半句用浅色
    private var questionText: Text {
        let final = state.question
        let partial = state.questionPartial
        if final.isEmpty && partial.isEmpty {
            let placeholder = state.sttIssue.map { "⚠️ \($0)" } ?? "等待面试官提问…"
            return Text(placeholder).foregroundStyle(.tertiary)
        }
        let separator = final.isEmpty || partial.isEmpty ? "" : "\n"
        return Text(final).foregroundStyle(.primary)
            + Text(separator + partial).foregroundStyle(.secondary)
    }

    // MARK: Reply（流式内容自动滚到底）

    private var replySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "Reply", systemImage: "sparkles")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        replyText
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: state.reply) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var replyText: some View {
        if state.reply.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.status == .thinking ? "思考中…" : "AI 回复将显示在这里")
                    .foregroundStyle(.tertiary)
                if !state.hasInterviewContext && state.status != .thinking {
                    Button("还没填面试资料（简历 / 岗位 JD），点这里填写 →") { state.openInterviewContext() }
                        .buttonStyle(.link)
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        } else {
            // 流式过程中 Markdown 可能不完整，解析失败就退化为纯文本
            let attributed = (try? AttributedString(
                markdown: state.reply,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(state.reply)
            Text(attributed)
                .font(state.isReaderMode ? .title3 : .callout)
                .lineSpacing(state.isReaderMode ? 5 : 2)
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                state.toggleReaderMode()
            } label: {
                Label(state.isReaderMode ? "Back" : "Read",
                      systemImage: state.isReaderMode ? "arrow.uturn.backward" : "eye")
                    .frame(maxWidth: .infinity)
            }
            .help("阅读模式：隐藏问题、放大回复")

            Button {
                state.say()
            } label: {
                Label(state.speech.isSpeaking ? "Stop" : "Say",
                      systemImage: state.speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(state.speech.isSpeaking ? .red : .accentColor)
            .disabled(state.reply.isEmpty)
            .help("系统 TTS 朗读回复")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(10)
    }
}

// MARK: - Small components

struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.gradient)
                        .frame(width: geo.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.06), value: level)
                }
            }
            .frame(height: 5)
        }
    }
}

struct HeaderIconButton: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 2)
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(animate ? 0 : 1)
                    .opacity(pulsing ? 1 : 0)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
