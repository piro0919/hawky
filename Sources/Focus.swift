import AppKit
import ApplicationServices

/// 待っているセッションを画面に出す。
/// 1. そのセッションが最前面のタブなら、ウィンドウの題名がセッションの題名になる。それで突き合わせる
/// 2. 背面のタブに居るなら、描画側のツリーを出してタブを押す
/// 3. 題名で決まらなければ、作業ディレクトリ名だけで突き合わせる
enum Focus {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// タブの副役割。ApplicationServices は定数を出していないので文字列で持つ
    private static let tabButtonSubrole = "AXTabButton"

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

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = Self.windows(of: axApp)
        guard !windows.isEmpty else { return }

        // 1. 最前面のタブがそのセッションなら、ここで終わる
        if !pending.title.isEmpty,
           let window = windows.first(where: { titleMatches(of: $0, pending.title) })
        {
            raise(window, in: axApp)
            return
        }

        // 2. 背面のタブを探す。作業ディレクトリで絞れるなら絞る
        let narrowed = windows.filter { holdsFolder($0, pending.folderName) }
        let candidates = narrowed.isEmpty ? windows : narrowed

        if !pending.title.isEmpty {
            enableRendererAccessibility(axApp)
            for window in candidates {
                guard let tab = findTab(in: window, titled: pending.title) else { continue }
                raise(window, in: axApp)
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                return
            }
        }

        // 3. 作業ディレクトリ名だけで突き合わせる（v0.1 の挙動）
        if let window = narrowed.first {
            raise(window, in: axApp)
        }
    }

    // MARK: - ウィンドウの突き合わせ

    /// Cursor のウィンドウ名は `<最前面のタブ> — <フォルダ名>`。
    /// タブ名の側が長いと拡張が末尾を `…` に詰めるので、前方一致でも拾う
    private static func titleMatches(of window: AXUIElement, _ sessionTitle: String) -> Bool {
        guard let title = string(window, kAXTitleAttribute as String) else { return false }
        let head = title.components(separatedBy: " — ").first ?? title
        if head == sessionTitle { return true }

        let stem = head.hasSuffix("…") ? String(head.dropLast()) : head
        // 短い断片での前方一致は、たまたま似た名前のファイルを開いている窓に当たる
        return stem.count >= 6 && sessionTitle.hasPrefix(stem)
    }

    /// フォルダを開いていないウィンドウでは題名に名前が入らない。その場合は絞り込みに使えない
    private static func holdsFolder(_ window: AXUIElement, _ folder: String) -> Bool {
        guard !folder.isEmpty, let title = string(window, kAXTitleAttribute as String)
        else { return false }
        return title.contains(folder)
    }

    private static func raise(_ window: AXUIElement, in axApp: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
    }

    // MARK: - 描画側のツリー

    /// Electron は支援技術を検知するまで描画側の要素を出さない。
    /// 立てるとタブが見えるようになる代わりに Cursor の使う記憶が増えるので、
    /// 題名で決まらなかったときだけ呼ぶ
    private static func enableRendererAccessibility(_ axApp: AXUIElement) {
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 開いているタブのうち、題名がそのセッションのものを探す。
    /// ツリーは数千要素になるので、幅優先で見る数を区切る。
    /// セッションの題名は拡張のヘッダーにも出るので、タブだと分かる要素を優先する
    private static func findTab(in window: AXUIElement, titled sessionTitle: String) -> AXUIElement? {
        var queue = [window]
        var seen = 0
        var fallback: AXUIElement?

        while !queue.isEmpty, seen < 6000 {
            let element = queue.removeFirst()
            seen += 1

            if isPressable(element), labelMatches(element, sessionTitle) {
                if string(element, kAXSubroleAttribute as String) == tabButtonSubrole {
                    return element
                }
                if fallback == nil { fallback = element }
            }
            queue.append(contentsOf: children(element))
        }
        return fallback
    }

    private static func isPressable(_ element: AXUIElement) -> Bool {
        if string(element, kAXSubroleAttribute as String) == tabButtonSubrole {
            return true
        }
        let role = string(element, kAXRoleAttribute as String)
        return role == (kAXRadioButtonRole as String) || role == (kAXButtonRole as String)
    }

    private static func labelMatches(_ element: AXUIElement, _ sessionTitle: String) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] as [String] {
            guard let label = string(element, attribute), !label.isEmpty else { continue }
            if label == sessionTitle { return true }

            let stem = label.hasSuffix("…") ? String(label.dropLast()) : label
            if stem.count >= 6, sessionTitle.hasPrefix(stem) { return true }
        }
        return false
    }

    // MARK: - AX の細かい取り回し

    private static func windows(of axApp: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
            let windows = raw as? [AXUIElement]
        else { return [] }
        return windows
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
            let kids = raw as? [AXUIElement]
        else { return [] }
        return kids
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        return raw as? String
    }
}
