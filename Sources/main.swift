import AppKit

/// メニューバーに常駐し、許可待ちの件数を出す。
/// セッションが無くても終了しない。消えると気付けないため
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    /// 作業中の輪を回す。作業中が無ければ止めておく
    private var animation: Timer?
    /// 回さないときの位置
    private var phase: CGFloat = 0.5
    private var pending: [Pending] = []
    private var settingsWindow = SettingsWindowController()
    private lazy var hotKey = HotKey { [weak self] in self?.revealOldest() }

    /// 一覧に出すもの。終わったセッションは設定で隠せる
    private var visible: [Pending] {
        Preferences.showsFinished ? pending : pending.filter { $0.kind != .finished }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            at: Paths.pendingDir, withIntermediateDirectories: true
        )
        item.menu = NSMenu()
        item.menu?.delegate = self
        startWatching()
        // 許可されたか、Claude Code が終わったかは、フックでは知らせが来ない。
        // ファイルの変化を待たずに、3秒ごとに見直す
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            // Timer は主の実行ループから呼ぶ。飛ばずに入り、違ったら落とす
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 言語を変えたら、設定の窓を作り直す。文字は窓を作るときに焼き込んでいる
        NotificationCenter.default.addObserver(forName: .languageChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasVisible = self.settingsWindow.window?.isVisible ?? false
                self.settingsWindow.close()
                self.settingsWindow = SettingsWindowController()
                if wasVisible { self.settingsWindow.show() }
                self.refresh()
            }
        }
        hotKey.apply(enabled: Preferences.usesHotKey)
        NotificationCenter.default.addObserver(forName: .hotKeyChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.hotKey.apply(enabled: Preferences.usesHotKey) }
        }
        Focus.ensureTrusted()
        refresh()
        Updater.shared.checkQuietly()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    /// フックがファイルを置いた瞬間に反応する
    private func startWatching() {
        let fd = Darwin.open(Paths.pendingDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// 鷹の影絵。テンプレート画像にして、明暗の色付けは macOS に任せる
    private let statusIcon: NSImage? = {
        guard let image = NSImage(named: "StatusIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private func refresh() {
        pending = Store.load()
        updateAnimation()
        drawStatus()
    }

    private var waitingCount: Int { pending.filter { $0.kind == .permission }.count }
    private var workingCount: Int { pending.filter { $0.kind == .working }.count }

    /// 数字は許可待ちと作業中だけ。終わったセッションは急がないので数えない
    private func drawStatus() {
        guard let button = item.button else { return }
        let waiting = waitingCount
        let working = workingCount
        // 何も無いときは影絵を薄くする。終わったセッションだけのときは、数字を出さずに濃くする
        button.appearsDisabled = visible.isEmpty
        guard waiting > 0 || working > 0 else {
            statusIcon?.accessibilityDescription = Strings.statusDescription
            button.image = statusIcon
            button.title = ""
            return
        }
        // 影絵ごと絵に描く。両方あれば2段、片方だけなら1段
        let image = StatusTitle.image(icon: statusIcon, waiting: waiting, working: working, phase: phase)
        image.accessibilityDescription = Strings.statusSummary(waiting: waiting, working: working)
        button.title = ""
        button.image = image
    }

    /// 作業中があるあいだだけ輪を回す。「視差効果を減らす」を選んでいれば回さずに止めて出す
    private func updateAnimation() {
        let moves = workingCount > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard moves != (animation != nil) else { return }
        guard moves else {
            animation?.invalidate()
            animation = nil
            phase = 0.5
            return
        }
        // 0.8 秒で一周する。メニューを開いているあいだも回るよう、common のモードに載せる
        let interval = 1.0 / 15
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = (self.phase + CGFloat(interval / 0.8)).truncatingRemainder(dividingBy: 1)
                self.drawStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// キーを押した。一番古い許可待ちへ、無ければ一番古い終わったセッションへ飛ぶ
    private func revealOldest() {
        refresh()
        // 作業中のセッションは急がないので飛び先にしない
        guard
            let target = visible.first(where: { $0.kind == .permission })
                ?? visible.first(where: { $0.kind == .finished })
        else {
            NSSound.beep()
            return
        }
        Focus.reveal(target)
    }

    private func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        // 接続していなければ、待ちは1件も届かない。入れた人が「動かない」と感じる前に、ここで知らせる
        if !Connection.isConnected {
            let warning = NSMenuItem(title: Strings.notConnected, action: #selector(openSettings), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        // 急ぐものから並べる。許可待ち、作業中、指示待ちの順
        let sections = [
            (Strings.permissionHeader, Pending.Kind.permission),
            (Strings.workingHeader, .working),
            (Strings.finishedHeader, .finished),
        ].map { header, kind in (header, visible.filter { $0.kind == kind }) }.filter { !$0.1.isEmpty }

        if sections.isEmpty {
            let empty = NSMenuItem(title: Strings.nothingWaiting, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        // 2種類以上あるときは、すべてに見出しを付けて分ける。一部にだけ付けると、
        // 見出しの無い側が何の行なのか分からない。許可待ちだけなら見出しは要らない
        for (index, (header, items)) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if sections.count > 1 || items.first?.kind != .permission { menu.addItem(.sectionHeader(title: header)) }
            for p in items { menu.addItem(row(for: p)) }
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: Strings.settings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: Strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSettings() { settingsWindow.show() }

    private func row(for p: Pending) -> NSMenuItem {
        let row = NSMenuItem(title: p.label, action: #selector(revealPending(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = p.sessionID
        return row
    }

    @objc private func revealPending(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = pending.first(where: { $0.sessionID == id })
        else { return }
        Focus.reveal(p)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 開かれる直前に組み直す。開きっぱなしの間に古くなるのを避ける
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }
}

// Claude Code のフックとして呼ばれた。画面は出さずに、待ちのファイルを書くか消すだけで終わる
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "hook" {
    exit(Hook.run(Array(CommandLine.arguments.dropFirst(2))))
}

if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
