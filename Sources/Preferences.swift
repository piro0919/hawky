import Carbon.HIToolbox
import Foundation

/// 設定の窓で切り替えるもの。言語は Strings.swift の Language が持つ
enum Preferences {
    private static let showsFinishedKey = "showsFinished"
    private static let hotKeyKey = "hotKey"

    /// 作業を終えて次の指示を待っているセッションも、一覧に出すか
    static var showsFinished: Bool {
        get { UserDefaults.standard.object(forKey: showsFinishedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showsFinishedKey) }
    }

    /// ⌃⌥H で一番古い待ちへ飛ぶか
    static var usesHotKey: Bool {
        get { UserDefaults.standard.object(forKey: hotKeyKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: hotKeyKey)
            NotificationCenter.default.post(name: .hotKeyChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let hotKeyChanged = Notification.Name("hawky.hotKeyChanged")
}

/// どこからでも押せるキー。Carbon の RegisterEventHotKey で登録する。
/// アクセシビリティの許可が無くても動き、ほかのアプリがそのキーを取っていたら登録に失敗するだけで済む
@MainActor
final class HotKey {
    /// ⌃⌥H。H は Hawky の頭文字
    nonisolated static let display = "⌃⌥H"
    private static let keyCode = UInt32(kVK_ANSI_H)
    private static let modifiers = UInt32(controlKey | optionKey)

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func apply(enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard reference == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Carbon のイベントは主の実行ループで届く
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, context, &handler)

        let id = EventHotKeyID(signature: OSType(0x4841_574B), id: 1)  // "HAWK"
        RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
