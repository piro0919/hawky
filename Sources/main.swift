import AppKit

/// メニューバーに常駐し、許可待ちの件数を出す。
/// セッションが無くても終了しない。消えると気付けないため
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pending: [Pending] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            at: Paths.pendingDir, withIntermediateDirectories: true
        )
        item.menu = NSMenu()
        item.menu?.delegate = self
        startWatching()
        // 期限切れの待ちを落とすため、変化が無くても定期的に見直す
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        Focus.ensureTrusted()
        refresh()
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

    private func refresh() {
        pending = Store.load()
        let count = pending.count
        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: count > 0 ? "hand.raised.fill" : "hand.raised",
            accessibilityDescription: "Claude Code の許可待ち"
        )
        button.title = count > 0 ? " \(count)" : ""
    }

    private func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        if pending.isEmpty {
            let empty = NSMenuItem(title: "許可待ちはありません", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, p) in pending.enumerated() {
                let row = NSMenuItem(
                    title: p.label, action: #selector(revealPending(_:)), keyEquivalent: ""
                )
                row.target = self
                row.tag = index
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func revealPending(_ sender: NSMenuItem) {
        guard pending.indices.contains(sender.tag) else { return }
        Focus.reveal(pending[sender.tag])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    /// 開かれる直前に組み直す。開きっぱなしの間に古くなるのを避ける
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
