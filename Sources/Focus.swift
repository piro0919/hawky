import AppKit
import ApplicationServices

/// 待っているセッションを画面に出す。
/// 1. そのセッションが最前面のタブなら、ウィンドウの題名がセッションの題名になる。それで突き合わせる
/// 2. macOS のタブで窓を束ねているなら、背面の窓はタブバーのボタンにしか出ない。それを押す
/// 3. 背面のタブに居るなら、描画側のツリーを出してタブを押す。ツリーが出るまで待って探し直し、
///    手前の窓に無ければ同じフォルダの macOS のタブを前に出してから探す
/// 4. 題名で決まらなければ、作業ディレクトリ名だけで突き合わせる
@MainActor
enum Focus {
    nonisolated static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// タブの副役割。ApplicationServices は定数を出していないので文字列で持つ
    private static let tabButtonSubrole = "AXTabButton"

    /// 前方一致に要求する最小の長さ。これより短い断片だと、
    /// たまたま似た名前のファイルを開いているだけの窓に当たる
    private static let minimumStemLength = 6

    /// ツリーは大きな窓で8000要素を超える。6000で打ち切っていた頃は、
    /// タブの並びに届く前に探索が終わることがあった。1回の探索で見る上限
    private static let visitLimit = 30000

    /// 描画側のツリーが出てくるのを待つ回数と間隔。合わせて1.5秒ほど。
    /// 手元では、フラグを立ててから0.4〜0.8秒で出てきた
    private static let rendererAttempts = 10
    private static let rendererInterval = Duration.milliseconds(150)

    /// アクセシビリティの許可がないとウィンドウを触れない。
    /// 無ければ設定を開くよう促す（初回だけ出る）
    @discardableResult
    static func ensureTrusted() -> Bool {
        // kAXTrustedCheckOptionPrompt は C から来る var なので Swift 6 では触れない。
        // 中身は固定の文字列で、変わることがない
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func reveal(_ pending: Pending) {
        guard
            let app =
                NSRunningApplication
                .runningApplications(withBundleIdentifier: cursorBundleID).first
        else { return }

        // macOS 14 以降は、自分が持っている前面化の権利を明け渡さないと
        // 他のアプリを前に出せない。これが無いと並び替えだけ効いて前に来ない
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate(options: [.activateAllWindows])

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let openWindows = windows(of: axApp)
        guard !openWindows.isEmpty else { return }

        // 1. 最前面のタブがそのセッションなら、ここで終わる
        if !pending.title.isEmpty,
            let window = openWindows.first(where: { titleMatches(of: $0, pending.title) })
        {
            raise(window, in: axApp)
            return
        }

        // 2. macOS のタブで束ねた背面の窓を探す
        let nativeTabs = openWindows.flatMap { window in
            windowTabs(of: window).map { (window: window, tab: $0) }
        }
        if !pending.title.isEmpty,
            let hit = nativeTabs.first(where: { entry in
                string(entry.tab, kAXTitleAttribute as String).map { titleMatches($0, pending.title) } ?? false
            })
        {
            press(hit.tab, in: hit.window, of: axApp)
            return
        }

        // 3. 背面のタブを探す。描画側のツリーは、フラグを立ててから出てくるまでに
        //    間がある。すぐ探すと空振りして、1回目のクリックでは窓が前に出るだけになる。
        //    出てくるまで少しずつ待って探し直す
        guard !pending.title.isEmpty else {
            raiseByFolder(pending, in: axApp, nativeTabs: nativeTabs)
            return
        }
        enableRendererAccessibility(axApp)
        Task { @MainActor in
            var broughtTabForward = false
            for attempt in 0..<rendererAttempts {
                if pressTab(for: pending, in: axApp) { return }

                // 手前の窓に無ければ、同じフォルダの macOS のタブの裏に居る。
                // その窓を前に出せば、次の回からツリーに現れる
                if !broughtTabForward, attempt >= 2,
                    let hit = nativeTabs.first(where: { entry in
                        !isSelected(entry.tab)
                            && (string(entry.tab, kAXTitleAttribute as String).map {
                                holdsFolder($0, pending.folderName)
                            } ?? false)
                    })
                {
                    press(hit.tab, in: hit.window, of: axApp)
                    broughtTabForward = true
                }
                try? await Task.sleep(for: rendererInterval)
            }
            // 4. 題名で決まらなかった
            raiseByFolder(pending, in: axApp, nativeTabs: nativeTabs)
        }
    }

    /// 開いている窓の中から、題名がそのセッションのタブを探して押す。作業ディレクトリで絞れるなら絞る
    private static func pressTab(for pending: Pending, in axApp: AXUIElement) -> Bool {
        let openWindows = windows(of: axApp)
        let narrowed = openWindows.filter { holdsFolder($0, pending.folderName) }
        for window in narrowed.isEmpty ? openWindows : narrowed {
            guard let tab = findTab(in: window, titled: pending.title) else { continue }
            raise(window, in: axApp)
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            return true
        }
        return false
    }

    /// 作業ディレクトリ名だけで突き合わせる（v0.1 の挙動）
    private static func raiseByFolder(
        _ pending: Pending, in axApp: AXUIElement, nativeTabs: [(window: AXUIElement, tab: AXUIElement)]
    ) {
        if let window = windows(of: axApp).first(where: { holdsFolder($0, pending.folderName) }) {
            raise(window, in: axApp)
        } else if let hit = nativeTabs.first(where: { entry in
            string(entry.tab, kAXTitleAttribute as String).map { holdsFolder($0, pending.folderName) } ?? false
        }) {
            press(hit.tab, in: hit.window, of: axApp)
        }
    }

    // MARK: - ウィンドウの突き合わせ

    /// Cursor のウィンドウ名は `<最前面のタブ> — <フォルダ名>`。
    /// タブ名の側が長いと拡張が末尾を `…` に詰めるので、前方一致でも拾う
    private static func titleMatches(of window: AXUIElement, _ sessionTitle: String) -> Bool {
        guard let title = string(window, kAXTitleAttribute as String) else { return false }
        return titleMatches(title, sessionTitle)
    }

    /// macOS のタブのボタンは、そのタブの窓の題名をそのまま持つ。窓と同じ規則で見る
    static func titleMatches(_ title: String, _ sessionTitle: String) -> Bool {
        let head = title.components(separatedBy: " — ").first ?? title
        return points(head, at: sessionTitle)
    }

    /// 画面に出ている文字列が、そのセッションを指しているか。
    /// 拡張が末尾を `…` に詰めるので、丸ごと一致と前方一致の両方を見る
    static func points(_ label: String, at sessionTitle: String) -> Bool {
        if label == sessionTitle { return true }
        let stem = label.hasSuffix("…") ? String(label.dropLast()) : label
        return stem.count >= minimumStemLength && sessionTitle.hasPrefix(stem)
    }

    /// フォルダを開いていないウィンドウでは題名に名前が入らない。その場合は絞り込みに使えない
    private static func holdsFolder(_ window: AXUIElement, _ folder: String) -> Bool {
        guard let title = string(window, kAXTitleAttribute as String) else { return false }
        return holdsFolder(title, folder)
    }

    static func holdsFolder(_ title: String, _ folder: String) -> Bool {
        !folder.isEmpty && title.contains(folder)
    }

    /// macOS のタブで束ねた窓は、最前面のものしか窓の一覧に出ない。
    /// 残りは窓の上のタブバーに、それぞれの窓の題名を持つボタンとして並ぶ
    private static func windowTabs(of window: AXUIElement) -> [AXUIElement] {
        children(window)
            .filter { string($0, kAXRoleAttribute as String) == (kAXTabGroupRole as String) }
            .flatMap { children($0) }
            .filter { string($0, kAXRoleAttribute as String) == (kAXRadioButtonRole as String) }
    }

    private static func raise(_ window: AXUIElement, in axApp: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
    }

    private static func press(_ tab: AXUIElement, in window: AXUIElement, of axApp: AXUIElement) {
        raise(window, in: axApp)
        AXUIElementPerformAction(tab, kAXPressAction as CFString)
    }

    // MARK: - 描画側のツリー

    /// Electron は支援技術を検知するまで描画側の要素を出さない。
    /// 立てるとタブが見えるようになる代わりに Cursor の使う記憶が増えるので、
    /// 題名で決まらなかったときだけ呼ぶ
    private static func enableRendererAccessibility(_ axApp: AXUIElement) {
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 開いているタブのうち、題名がそのセッションのものを探す。
    /// 幅優先で、見る数を区切って探す。
    /// セッションの題名は拡張のヘッダーにも出るので、タブだと分かる要素を優先する
    private static func findTab(in window: AXUIElement, titled sessionTitle: String) -> AXUIElement? {
        // 先頭を取り出して詰め直すと要素数の二乗になる。読む位置だけ進める
        var queue = [window]
        var cursor = 0
        var fallback: AXUIElement?

        while cursor < queue.count, cursor < visitLimit {
            let element = queue[cursor]
            cursor += 1

            let subrole = string(element, kAXSubroleAttribute as String)
            if isPressable(element, subrole: subrole), labelMatches(element, sessionTitle) {
                if subrole == tabButtonSubrole { return element }
                if fallback == nil { fallback = element }
            }
            queue.append(contentsOf: children(element))
        }
        return fallback
    }

    private static func isPressable(_ element: AXUIElement, subrole: String?) -> Bool {
        if subrole == tabButtonSubrole { return true }
        let role = string(element, kAXRoleAttribute as String)
        return role == (kAXRadioButtonRole as String) || role == (kAXButtonRole as String)
    }

    private static func labelMatches(_ element: AXUIElement, _ sessionTitle: String) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] as [String] {
            guard let label = string(element, attribute), !label.isEmpty else { continue }
            if points(label, at: sessionTitle) { return true }
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

    /// タブのボタンは、選ばれているときに値が 1 になる
    private static func isSelected(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success
        else { return false }
        return (raw as? Int) == 1
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
