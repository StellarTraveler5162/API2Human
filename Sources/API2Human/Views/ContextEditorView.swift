import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation

extension UTType {
    /// API2Human 面试者角色卡（Info.plist 里声明的导出类型）
    static let candidateCard = UTType(exportedAs: "com.api2human.candidate-card", conformingTo: .plainText)
}

/// 编辑中的资料（窗口和"双击 .a2hcard 打开"共用）
@MainActor
@Observable
final class ContextEditorModel {
    var context = InterviewContext.load()
    private(set) var saved = InterviewContext.load()
    var message: String?

    var isDirty: Bool { context != saved }

    func revert() {
        context = saved
        message = nil
    }

    func save() {
        do {
            try context.save()
            saved = context
            NotificationCenter.default.post(name: InterviewContext.didChange, object: nil)
            message = "已保存：AI 回答下一个问题起生效，识别热词下次开始监听时生效"
            Log.info("面试资料已保存：简历 \(context.resume.count) 字，JD \(context.jobDescription.count) 字，补充 \(context.notes.count) 字")
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 导入角色卡会整张替换三栏：有未保存的修改先确认。返回 true 表示可以导入
    func confirmReplaceIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "导入角色卡会替换当前未保存的修改"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 导入角色卡：整张替换三栏（不自动保存，让用户先看一眼）
    func importCard(at url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let card = try CandidateCard(text: text)
            context = card.interviewContext
            let counts = CandidateCard.markerCounts(text)
            var parts = ["已导入角色卡 \(url.lastPathComponent)（\(card.meta["name"] ?? "")）"]
            if card.version > CandidateCard.supportedVersion { parts.append("版本 \(card.version) 较新，部分内容可能未识别") }
            if counts.unconfirmed > 0 { parts.append("\(counts.unconfirmed) 处待确认不会发给 AI") }
            if counts.missing > 0 { parts.append("\(counts.missing) 处待补充") }
            message = parts.joined(separator: "；") + "。确认后点保存"
            Log.info("导入角色卡 \(url.path)：\(card.sections.count) 个章节")
        } catch {
            message = error.localizedDescription
        }
    }
}

/// "面试资料"窗口：简历 / 岗位 JD / 补充信息，可粘贴、从文件导入，或直接导入 .a2hcard 角色卡。
@MainActor
final class ContextWindowController: NSObject, NSWindowDelegate {
    static let shared = ContextWindowController()
    private var window: NSWindow?
    private let model = ContextEditorModel()

    /// 标题栏关闭、Esc（取消）都走这里：有未保存的修改先问一下，行为一致
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmUnsavedChanges() }

    /// 有未保存的修改时询问"保存 / 不保存 / 取消"。返回 true 表示可以继续（关窗、退出）。
    /// 关闭窗口、退出 App 共用
    func confirmUnsavedChanges() -> Bool {
        guard model.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "面试资料有未保存的修改"
        alert.informativeText = "关闭前要保存吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return !model.isDirty          // 保存失败就不关，让用户看到错误
        case .alertSecondButtonReturn:
            model.revert()
            return true
        default:
            return false
        }
    }

    func show(importing url: URL? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "面试资料"
            w.isReleasedWhenClosed = false
            // 里面是简历，共享屏幕时同样不让对方看到（--sharing-visible 调试时可见）
            w.sharingType = CommandLine.arguments.contains("--sharing-visible") ? .readOnly : .none
            w.minSize = NSSize(width: 520, height: 420)
            w.delegate = self
            // 取消按钮 / Esc 走 performClose，和标题栏关闭一样经过 windowShouldClose
            w.contentView = NSHostingView(rootView: ContextEditorView(model: model) { [weak w] in w?.performClose(nil) })
            w.center()
            window = w
        }
        if let url {
            if model.confirmReplaceIfDirty() { model.importCard(at: url) }
        }
        // 本 App 不在 Dock，需要主动激活才能打字；系统拒绝激活时（不是用户点击触发）也至少把窗口提到最前
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

private struct ContextEditorView: View {
    enum Field: String, CaseIterable, Identifiable {
        case resume = "我的简历 / 背景"
        case jobDescription = "目标岗位 JD"
        case notes = "补充信息"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .resume: "粘贴简历，或从 PDF / Word / .a2hcard 角色卡导入。AI 只会引用这里有的项目、公司和数字，不再自己编。"
            case .jobDescription: "粘贴岗位描述。回答会往岗位要求上靠，并自然地用上 JD 里的关键词。"
            case .notes: "例如：公司主营业务、面试官是谁、这一轮考什么、想重点突出的项目、不想提的事（离职原因的口径等）。"
            }
        }
    }

    @Bindable var model: ContextEditorModel
    let close: () -> Void
    @State private var selection: Field = .resume

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selection) {
                ForEach(Field.allCases) { field in
                    Text(field.rawValue + (text(for: field).isEmpty ? "" : " ✓")).tag(field)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(selection.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: binding(for: selection))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("从文件导入…") { importFile() }
                Text("\(text(for: selection).count) / \(InterviewContext.maxCharsPerField) 字")
                    .font(.caption)
                    .foregroundStyle(text(for: selection).count > InterviewContext.maxCharsPerField ? .red : .secondary)
                Spacer()
                Button("取消") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }

    private func text(for field: Field) -> String {
        switch field {
        case .resume: model.context.resume
        case .jobDescription: model.context.jobDescription
        case .notes: model.context.notes
        }
    }

    private func binding(for field: Field) -> Binding<String> {
        switch field {
        case .resume: $model.context.resume
        case .jobDescription: $model.context.jobDescription
        case .notes: $model.context.notes
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.candidateCard, .pdf, .plainText, .rtf, .html,
                                     UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "docx") ?? .data,
                                     UTType(filenameExtension: "doc") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "选择 .a2hcard 角色卡会整张导入三栏；其他文件导入到当前栏"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == CandidateCard.fileExtension {
            if model.confirmReplaceIfDirty() { model.importCard(at: url) }
            return
        }
        do {
            let text = try InterviewContext.importText(from: url)
            let target = binding(for: selection)
            target.wrappedValue = target.wrappedValue.isEmpty ? text : target.wrappedValue + "\n\n" + text
            model.message = "已导入 \(url.lastPathComponent)（\(text.count) 字），记得保存"
        } catch {
            model.message = error.localizedDescription
        }
    }
}
