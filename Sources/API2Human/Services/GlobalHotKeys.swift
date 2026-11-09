import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的全局快捷键。
/// 与 NSEvent.addGlobalMonitorForEvents 不同，它不需要"辅助功能"权限，且会吞掉该组合键。
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private static let signature: OSType = 0x4150_4948 // 'APIH'

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            Log.info("注册快捷键失败 keyCode=\(keyCode) status=\(status)（可能被其他 App 占用）")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon 应用事件在主线程分发
            MainActor.assumeIsolated { GlobalHotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
