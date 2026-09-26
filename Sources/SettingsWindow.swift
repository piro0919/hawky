import AppKit
import ServiceManagement

/// 設定の窓。作りは Gocci に揃えてある。左に項目名を右寄せで置き、右に操作を並べる。
/// メニューは待っているセッションの一覧に絞り、切り替えるものはここに集める
@MainActor
final class SettingsWindowController: NSWindowController {
    private let connectionLabel = NSTextField(labelWithString: "")
    private let connectionButton = NSButton(title: "", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: Strings.launchAtLogin, target: nil, action: nil)
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

        let connectHint = NSTextField(wrappingLabelWithString: Strings.connectHint)
        connectHint.font = .systemFont(ofSize: 11)
        connectHint.textColor = .secondaryLabelColor
        connectHint.preferredMaxLayoutWidth = 250

        languagePopUp.target = self
        languagePopUp.action = #selector(changeLanguage)
        for language in Language.allCases {
            languagePopUp.addItem(withTitle: language.label)
        }

        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)

        messageLabel.font = .systemFont(ofSize: 11)
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
            aligned(connectHint),
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
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - 操作

    @objc private func toggleConnection() {
        do {
            if Connection.isConnected { try Connection.disconnect() } else { try Connection.connect() }
            report("")
        } catch {
            report("\(Strings.connectFailed): \(Connection.settingsURL.path)", failed: true)
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
