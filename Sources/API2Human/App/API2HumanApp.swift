import SwiftUI

/// 没有主窗口：屏幕左侧留给腾讯会议 / 飞书会议，本 App 只有
/// 1) 贴边的悬浮窗（FloatingPanel） 2) 菜单栏图标 3) 全局快捷键。
@main
struct API2HumanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("API2Human", systemImage: "waveform.circle") {
            MenuBarContent(state: appDelegate.state)
        }
    }
}

private struct MenuBarContent: View {
    let state: AppState

    var body: some View {
        Text("状态：\(state.status.label)")
        Divider()
        Button(state.isPanelVisible ? "隐藏悬浮窗  ⌃⌥H" : "显示悬浮窗  ⌃⌥H") {
            state.isPanelVisible.toggle()
        }
        Button(state.isRecording ? "停止监听  ⌃⌥R" : "开始监听  ⌃⌥R") {
            state.toggleRecording()
        }
        Button(state.isMicMuted ? "取消麦克风静音  ⌃⌥M" : "麦克风静音  ⌃⌥M") {
            state.toggleMute()
        }
        Picker("录哪里的声音（下次开始监听生效）", selection: Binding(
            get: { state.audioScope },
            set: { state.audioScope = $0 }
        )) {
            ForEach(AudioSourceScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if state.isRecording, let source = state.lastSession?.systemSource {
            Text("　正在录：\(source)")
        }
        Picker("麦克风（只用于复盘录音，下次开始监听生效）", selection: Binding(
            get: { state.micMode },
            set: { state.micMode = $0 }
        )) {
            ForEach(MicrophoneSelector.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if let device = state.lastSession?.micDevice {
            Text("　当前麦克风：\(device)")
        } else if state.isRecording, let issue = state.lastSession?.micIssue {
            Text("　麦克风：\(issue)")
        }
        Button("立即回答 / 重新生成  ⌃⌥A") { state.answerNow() }
        Button("即圈即搜（屏幕代码 / 题目）  ⌃⌥F") { state.startScreenSearch() }
        Button("添加代码项目目录…（已添加 \(state.projectDirCount) 个）") { state.addProjectDirectory() }
        if state.projectDirCount > 0 {
            Button("清空代码项目目录") { state.clearProjectDirectories() }
        }
        Button("打开录音文件夹") { state.openRecordingsFolder() }
        Button("面试资料（简历 / 岗位 JD）…") { state.openInterviewContext() }
        Button("编辑 AI 配置（llm.json）") { state.openLLMConfig() }
        Divider()
        Button("模拟一次问答 (Demo)  ⌃⌥D") { state.runDemo() }
        Button("重置悬浮窗位置") { state.resetPanelPositionToken += 1 }
        Divider()
        Button("退出 API2Human") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
