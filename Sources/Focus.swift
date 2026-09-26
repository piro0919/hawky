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

    /// 窓の名前の区切り。Cursor は `<タブ> — <フォルダ>`、VS Code は `<タブ> - <フォルダ> - Visual Studio Code`。
    /// 題名そのものに ` - ` が入ることもあるので、最初の区切りの前だけを題名の側とみなす
    static let titleSeparators = [" — ", " - "]

    /// タブの副役割とウェブ領域の役割。ApplicationServices は定数を出していないので文字列で持つ
    private static let tabButtonSubrole = "AXTabButton"
    private static let webAreaRole = "AXWebArea"

    /// 前方一致に要求する最小の長さ。これより短い断片だと、
    /// たまたま似た名前のファイルを開いているだけの窓に当たる
    private static let minimumStemLength = 6

    /// ツリーは大きな窓で8000要素を超える。6000で打ち切っていた頃は、
    /// タブの並びに届く前に探索が終わることがあった。1回の探索で見る上限
    private static let visitLimit = 30000

    /// 描画側のツリーが出てくるのを待つ間隔と、1つの窓で待つ回数。
    /// 手元では、フラグを立ててから0.4〜0.8秒で出てきた。1つの窓に0.6秒、
    /// 裏の窓を3枚まで渡り歩いて、合わせて2.4秒ほどで諦める
    private static let rendererInterval = Duration.milliseconds(150)
    private static let attemptsPerWindow = 4
    private static let rendererAttempts = attemptsPerWindow * 4

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
                .runningApplications(withBundleIdentifier: pending.app.isEmpty ? cursorBundleID : pending.app).first
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

        log("reveal title=\(pending.title) windows=\(openWindows.count)")
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

        // 手前の窓に無ければ、macOS のタブの裏の窓に居る。裏の窓はツリーに出ないので、
        // 前に出してから探すしかない。フォルダ名が窓の名前に入っている窓を先に試す。
        // ホームのようにフォルダ名が窓の名前に出ない窓もあるので、残りも順に試す
        let background = nativeTabs.filter { !isSelected($0.tab) }
        let folderFirst =
            background.filter { tabHoldsFolder($0.tab, pending.folderName) }
            + background.filter { !tabHoldsFolder($0.tab, pending.folderName) }
        let original = nativeTabs.first { isSelected($0.tab) }

        log(
            "step3 title=\(pending.title) folder=\(pending.folderName) background=\(background.count) original=\(original != nil)"
        )
        Task { @MainActor in
            var queue = folderFirst[...]
            for attempt in 0..<rendererAttempts {
                let titles = windows(of: axApp).compactMap { string($0, kAXTitleAttribute as String) }
                log(
                    "attempt \(attempt) windows=\(titles) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")"
                )
                // 押しても効かないことがある。メニューを選んだ直後は Cursor がまだ前面に
                // 来ておらず、そこで押したタブは選ばれない。押したら窓の名前が題名に
                // 変わったかを確かめ、変わっていなければ次の回で押し直す
                if pressTab(for: pending, in: axApp) {
                    log("pressed at attempt \(attempt)")
                    try? await Task.sleep(for: rendererInterval)
                    if windows(of: axApp).contains(where: { titleMatches(of: $0, pending.title) }) {
                        log("front window now matches")
                        return
                    }
                    continue
                }

                // ツリーが出てくるのを少し待ってから、次の窓へ移る
                if attempt % attemptsPerWindow == attemptsPerWindow - 1, let next = queue.popFirst() {
                    log("bring forward \(string(next.tab, kAXTitleAttribute as String) ?? "?")")
                    press(next.tab, in: next.window, of: axApp)
                }
                try? await Task.sleep(for: rendererInterval)
            }
            // 見つからなかった。裏の窓を渡り歩いたなら、元の窓に戻してから
            if folderFirst.count > queue.count, let original {
                press(original.tab, in: original.window, of: axApp)
            }
            // 4. 題名で決まらなかった
            raiseByFolder(pending, in: axApp, nativeTabs: nativeTabs)
        }
    }

    /// `--diag` を付けて起動したときだけ、探す段ごとの結果を標準エラーに書く
    private static func log(_ text: @autoclosure () -> String) {
        guard CommandLine.arguments.contains("--diag") else { return }
        FileHandle.standardError.write(Data("focus: \(text())\n".utf8))
    }

    private static func tabHoldsFolder(_ tab: AXUIElement, _ folder: String) -> Bool {
        string(tab, kAXTitleAttribute as String).map { holdsFolder($0, folder) } ?? false
    }

    /// 開いている窓の中から、題名がそのセッションのタブを探して押す。作業ディレクトリで絞れるなら絞る
    private static func pressTab(for pending: Pending, in axApp: AXUIElement) -> Bool {
        let openWindows = windows(of: axApp)
        let narrowed = openWindows.filter { holdsFolder($0, pending.folderName) }
        for window in narrowed.isEmpty ? openWindows : narrowed {
            guard let tab = findTab(in: window, titled: pending.title) else { continue }
            log(
                "found \(string(tab, kAXRoleAttribute as String) ?? "")/\(string(tab, kAXSubroleAttribute as String) ?? "") [\(string(tab, kAXDescriptionAttribute as String) ?? string(tab, kAXTitleAttribute as String) ?? "")]"
            )
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
        // 題名の側に区切りと同じ文字が入っていることもある。題名で始まるなら丸ごと当てる
        if title == sessionTitle { return true }
        for separator in titleSeparators where title.hasPrefix(sessionTitle + separator) { return true }
        let head = titleSeparators.reduce(title) { $0.components(separatedBy: $1).first ?? $0 }
        return points(head, at: sessionTitle)
    }

    /// 画面に出ている文字列が、そのセッションを指しているか。
    /// 拡張は長い題名の末尾を `…` に詰めるので、`…` で終わるものだけ前方一致で見る。
    /// `…` の無い前方一致まで許すと、アクティビティバーの「Vercel」が
    /// 「Vercelのコスト削減」に当たり、タブの代わりに拡張の画面を開いていた
    static func points(_ label: String, at sessionTitle: String) -> Bool {
        if label == sessionTitle { return true }
        guard label.hasSuffix("…") else { return false }
        let stem = String(label.dropLast())
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
        // 先頭を取り出して詰め直すと要素数の二乗になる。読む位置だけ進める。
        // 各要素には、ウェブ領域の内側に居るかを添えて積む
        var queue: [(element: AXUIElement, insideWeb: Bool)] = [(window, false)]
        var cursor = 0
        var fallback: AXUIElement?

        while cursor < queue.count, cursor < visitLimit {
            let (element, insideWeb) = queue[cursor]
            cursor += 1

            let subrole = string(element, kAXSubroleAttribute as String)
            if isPressable(element, subrole: subrole), labelMatches(element, sessionTitle) {
                if subrole == tabButtonSubrole { return element }
                if fallback == nil { fallback = element }
            }

            // Cursor 本体の画面は1枚のウェブ領域で、その中に拡張機能の画面が
            // ウェブ領域として入れ子になる。Claude Code のチャット欄は会話の分だけ
            // 要素が増え、1万を超えて探索に3秒近くかかっていた。タブのボタンは本体の側に
            // あるので、入れ子の方には入らない。手元の窓で 3556 番目が 150 番目になった
            let isWeb = string(element, kAXRoleAttribute as String) == webAreaRole
            if isWeb, insideWeb { continue }
            queue.append(contentsOf: children(element).map { ($0, insideWeb || isWeb) })
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
            if points(tabLabel(label), at: sessionTitle) { return true }
        }
        return false
    }

    /// タブの名前の末尾には、題名のほかに状態が付くことがある。比べる前に落として題名だけにする。
    /// 窓を左右に分けているとどちらの側か（「, エディター グループ 2」「, Editor Group 2」）、
    /// VS Code で試しに開いた状態なら「, preview」が付く。両方付くこともある
    static func tabLabel(_ label: String) -> String {
        var text = label
        while let range = text.range(of: ", ", options: .backwards) {
            let tail = text[range.upperBound...]
            guard tail.last?.isNumber == true || previewMarks.contains(String(tail)) else { break }
            text = String(text[..<range.lowerBound])
        }
        return text
    }

    private static let previewMarks: Set<String> = ["preview", "プレビュー"]

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
