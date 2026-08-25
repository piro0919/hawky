import AppKit
import ApplicationServices

/// 待っているセッションの Cursor ウィンドウを前面に出す。
/// v0.1 はウィンドウ単位まで。同じウィンドウの中のタブ切り替えは扱わない
enum Focus {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// アクセシビリティの許可がないとウィンドウを触れない。
    /// 無ければ設定を開くよう促す（初回だけ出る）
    @discardableResult
    static func ensureTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func reveal(_ pending: Pending) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: cursorBundleID).first
        else { return }

        // macOS 14 以降は、自分が持っている前面化の権利を明け渡さないと
        // 他のアプリを前に出せない。これが無いと並び替えだけ効いて前に来ない
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate(options: [.activateAllWindows])

        // 前面に出してから、目的のウィンドウを一番上に持ち上げる
        let name = (pending.cwd as NSString).lastPathComponent
        if !name.isEmpty {
            raiseWindow(pid: app.processIdentifier, containing: name)
        }
    }

    /// Cursor のウィンドウ名にはプロジェクト名が入る。それで突き合わせる
    private static func raiseWindow(pid: pid_t, containing name: String) {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return }

        for window in windows {
            var raw: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &raw) == .success,
                let title = raw as? String, title.contains(name)
            else { continue }

            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
            return
        }
    }
}
