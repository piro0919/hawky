import AppKit
import ServiceManagement

/// 設定の窓。作りは Gocci に揃えてある。左に項目名を右寄せで置き、右に操作を並べる。
/// メニューは待っているセッションの一覧に絞り、切り替えるものはここに集める
@MainActor
final class SettingsWindowController: NSWindowController {
    private let connectionLabel = NSTextField(labelWithString: "")
    private let connectionButton = NSButton(title: "", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private let languagePopUp = NSPopUpButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: Strings.launchAtLogin, target: nil, action: nil)
    private let finishedCheckbox = NSButton(checkboxWithTitle: Strings.showsFinished, target: nil, action: nil)
    private let hotKeyCheckbox = NSButton(checkboxWithTitle: Strings.hotKey, target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private lazy var messageRow: NSView = aligned(messageLabel)
    private var dividers: [NSView] = []

    /// 見出しの幅。操作の左端を一列に揃えるための基準
    private static let labelWidth: CGFloat = 110

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = Strings.settingsTitle
        window.isReleasedWhenClosed = false
        self.init(window: window)
        build()
    }

    private func build() {
        guard let window else { return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"

        connectionButton.bezelStyle = .rounded
        connectionButton.target = self
        connectionButton.action = #selector(toggleConnection)
        // 行の高さは、組み立てた時点の文字で揃う。空のまま組むと、あとで文字を入れたときに
        // 見出しだけが上に浮く。先に中身を入れておく
        showConnection()

        // 長いパスは真ん中を詰める。窓の幅は広げない
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderButton = NSButton(title: Strings.chooseFolder, target: self, action: #selector(chooseFolder))
        folderButton.bezelStyle = .rounded

        languagePopUp.target = self
        languagePopUp.action = #selector(changeLanguage)
        for language in Language.allCases {
            languagePopUp.addItem(withTitle: language.label)
        }

        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)
        finishedCheckbox.target = self
        finishedCheckbox.action = #selector(toggleFinished)
        hotKeyCheckbox.target = self
        hotKeyCheckbox.action = #selector(toggleHotKey)

        messageLabel.font = .systemFont(ofSize: 11)
        // エラーの文は長くなる。窓の幅は変えずに折り返す
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 420 - 24 * 2 - Self.labelWidth - 10
        // 文字が無いときは畳む。空のまま置くと、その行のぶんだけ間延びする
        messageLabel.isHidden = true
        messageRow.isHidden = true

        let updateButton = NSButton(title: Strings.checkForUpdates, target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded

        let about = NSTextField(labelWithString: "Hawky \(version)")
        about.textColor = .secondaryLabelColor
        about.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            row(Strings.claudeCode, connectionLabel, connectionButton),
            row(Strings.configFolder, folderLabel, folderButton),
            divider(),
            aligned(finishedCheckbox),
            aligned(hotKeyCheckbox),
            divider(),
            row(Strings.language, languagePopUp),
            aligned(launchCheckbox),
            messageRow,
            aligned(updateButton),
            aligned(about),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // 畳んだ行の場所を残さない
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 余白は枠との距離として直接指定する。積み上げ側の余白指定は、
        // 窓の幅を中身から決めるときに右側が勘定に入らない
        let margin: CGFloat = 24
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        // 区切り線は、積み上げた中身と同じ幅にする。固定値だと中身とずれる
        for line in dividers {
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
    }

    func show() {
        // 開くたびに読み直す。設定ファイルやログイン項目は、この窓の外でも変えられる
        showConnection()
        languagePopUp.selectItem(at: Language.allCases.firstIndex(of: Language.chosen) ?? 0)
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        finishedCheckbox.state = Preferences.showsFinished ? .on : .off
        hotKeyCheckbox.state = Preferences.usesHotKey ? .on : .off
        report("")

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func showConnection() {
        let connected = Connection.isConnected
        connectionLabel.stringValue = connected ? Strings.connected : Strings.disconnected
        connectionLabel.textColor = connected ? .labelColor : .systemOrange
        connectionButton.title = connected ? Strings.disconnect : Strings.connect
        folderLabel.stringValue = Paths.display(Paths.claudeDir)
        folderLabel.toolTip = Paths.claudeDir.path
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - 操作

    @objc private func toggleConnection() {
        do {
            if Connection.isConnected { try Connection.disconnect() } else { try Connection.connect() }
            report("")
        } catch {
            // 何が起きたかを出す。書き込めないのか、JSON が壊れているのかで、利用者のやることが違う
            report(
                "\(Strings.connectFailed): \(Paths.display(Connection.settingsURL))\n\(error.localizedDescription)",
                failed: true)
        }
        showConnection()
        NotificationCenter.default.post(name: .connectionChanged, object: nil)
    }

    /// Claude Code の設定フォルダを選ぶ。Finder から開いたアプリには CLAUDE_CONFIG_DIR が届かないので、ここで合わせる。
    /// 既定と同じフォルダを選んだら、選んだ記録を消して既定に戻す。つないでいたら、フックも新しいフォルダへ付け替える
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // .claude は隠しフォルダなので、見せないと選べない
        panel.showsHiddenFiles = true
        panel.directoryURL = Paths.claudeDir
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fallback = Paths.claudeDir(
            chosen: nil, environment: ProcessInfo.processInfo.environment, home: Paths.home)
        let previous = Paths.claudeDir
        Preferences.claudeDir = url.standardizedFileURL == fallback.standardizedFileURL ? nil : url.path
        // フックも前のフォルダから新しいフォルダへ移す。失敗してもフォルダの選択は残し、どのファイルかを出す
        do {
            try Connection.move(from: previous, to: Paths.claudeDir)
            report("")
        } catch let error as Connection.MoveError {
            report(
                "\(Strings.connectFailed): \(Paths.display(error.url))\n\(error.underlying.localizedDescription)",
                failed: true)
        } catch {
            report("\(Strings.connectFailed)\n\(error.localizedDescription)", failed: true)
        }
        showConnection()
        NotificationCenter.default.post(name: .connectionChanged, object: nil)
    }

    @objc private func changeLanguage() {
        let index = languagePopUp.indexOfSelectedItem
        guard Language.allCases.indices.contains(index) else { return }
        Language.chosen = Language.allCases[index]
    }

    /// 常駐して見張るのが役目なので、ログイン時に起動しないと意味が薄い
    @objc private func toggleLaunch() {
        do {
            if launchCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            report("")
        } catch {
            report(Strings.launchFailed, failed: true)
        }
        // OS 側の状態に見た目を合わせる。失敗したときは元に戻る
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleFinished() { Preferences.showsFinished = finishedCheckbox.state == .on }

    @objc private func toggleHotKey() { Preferences.usesHotKey = hotKeyCheckbox.state == .on }

    @objc private func checkForUpdates() { Updater.shared.checkNow() }

    // MARK: - 組み立て

    private func row(_ title: String, _ controls: NSView...) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        label.alignment = .right

        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    /// 見出しの無い行。操作の左端を見出しのある行に揃える
    private func aligned(_ views: NSView...) -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        let stack = NSStackView(views: [spacer] + views)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        dividers.append(line)
        return line
    }

    private func report(_ text: String, failed: Bool = false) {
        messageLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        messageRow.isHidden = text.isEmpty
    }
}

extension Notification.Name {
    static let connectionChanged = Notification.Name("hawky.connectionChanged")
}
