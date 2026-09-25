import AppKit
import ServiceManagement

/// メニューバーに常駐し、許可待ちの件数を出す。
/// セッションが無くても終了しない。消えると気付けないため
@MainActor
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
        // 許可されたか、Claude Code が終わったかは、フックでは知らせが来ない。
        // ファイルの変化を待たずに、3秒ごとに見直す
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            // Timer は主の実行ループから呼ぶ。飛ばずに入り、違ったら落とす
            MainActor.assumeIsolated { self?.refresh() }
        }
        Focus.ensureTrusted()
        refresh()
        Updater.shared.checkQuietly()
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
        image.accessibilityDescription = Strings.statusDescription
        return image
    }()

    private func refresh() {
        pending = Store.load()
        let count = pending.count
        guard let button = item.button else { return }
        button.image = statusIcon
        // 待ちが無いときは影絵を薄くして、あるときとの違いを件数以外でも見せる
        button.appearsDisabled = count == 0
        button.title = count > 0 ? " \(count)" : ""
    }

    private func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        if pending.isEmpty {
            let empty = NSMenuItem(title: Strings.nothingWaiting, action: nil, keyEquivalent: "")
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

        let login = NSMenuItem(title: Strings.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let update = NSMenuItem(title: Strings.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: Strings.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 常駐して見張るのが役目なので、ログイン時に起動しないと意味が薄い。切り替えはここだけ
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func checkForUpdates() { Updater.shared.checkNow() }

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

if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
