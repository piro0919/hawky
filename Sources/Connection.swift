import Foundation

/// Claude Code の `settings.json`（既定は `~/.claude/settings.json`）に Hawky のフックを登録する・外す。メニューの「Claude Code に接続」から呼ぶ。
/// 既にある他のフックは触らない。何度流しても同じ結果になる。
/// 以前はターミナルで install.mjs を叩いてもらっていた。そこで止まる人が出るので、アプリの中で済ませる
enum Connection {
    /// 置き場は `Paths.claudeDir` が決める。CLAUDE_CONFIG_DIR や設定の窓で移せる
    static var settingsURL: URL { Paths.claudeDir.appendingPathComponent("settings.json") }

    /// フックとして登録するコマンド。今動いているアプリの実行ファイルを指す。
    /// アプリを別の場所へ動かしたら、接続し直すと新しい場所に向け直される
    static func command(_ mode: String, executable: String = Bundle.main.executablePath ?? "") -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' hook \(mode)"
    }

    /// 自分が登録したフックか。Node 時代の hawky-hook.mjs も自分のものとして扱い、接続し直すときに外す
    static func isMine(_ command: String) -> Bool {
        command.contains("hawky-hook.mjs") || command.contains("/Contents/MacOS/Hawky' hook")
    }

    /// 今のアプリを指すフックが、必要な知らせに全部そろって登録されているか。
    /// 版が上がって登録の中身が変わったら、未接続として出し、接続し直してもらう
    static var isConnected: Bool {
        guard let settings = load() else { return false }
        return events.allSatisfy { event, matcher, mode in
            (settings["hooks"]?[event]?.arrayValue ?? []).contains { entry in
                entry["matcher"]?.stringValue == matcher
                    && (entry["hooks"]?.arrayValue ?? []).contains { $0["command"]?.stringValue == command(mode) }
            }
        }
    }

    static func connect() throws { try write(connecting: true, to: settingsURL) }
    static func disconnect() throws { try write(connecting: false, to: settingsURL) }

    /// どのファイルで失敗したか。設定フォルダを移したときは、前と後のどちらかで失敗しうる
    struct MoveError: Error {
        let url: URL
        let underlying: Error
    }

    /// 設定フォルダを移したときに、フックを前のフォルダから新しいフォルダへ付け替える。
    ///
    /// **前のフォルダに残すと、そちらの Claude Code からも待ちが届き続ける。** 外すのは接続を解除するときと
    /// 同じ書き方で、控えを取り、自分の登録だけを消す。前のフォルダに自分の登録が無ければ何も書かず、
    /// 新しいフォルダにも入れない（つないでいなかった人を勝手につながない）。何度流しても同じ結果になる。
    /// 付け替えたら true
    @discardableResult
    static func move(from oldDir: URL, to newDir: URL, executable: String = Bundle.main.executablePath ?? "") throws
        -> Bool
    {
        let old = oldDir.appendingPathComponent("settings.json")
        let new = newDir.appendingPathComponent("settings.json")
        if old.standardizedFileURL.resolvingSymlinksInPath() == new.standardizedFileURL.resolvingSymlinksInPath() {
            return false
        }
        do {
            // 読めない設定ファイルは外さずに止める。書き戻すと利用者の設定を壊す
            guard FileManager.default.fileExists(atPath: old.path),
                containsMine(try JSONValue.parse(String(contentsOf: old, encoding: .utf8)))
            else { return false }
            try write(connecting: false, to: old, executable: executable)
        } catch {
            throw MoveError(url: old, underlying: error)
        }
        do {
            try write(connecting: true, to: new, executable: executable)
        } catch {
            throw MoveError(url: new, underlying: error)
        }
        return true
    }

    /// 自分のフックが一つでも登録されているか。版の古い登録や Node 時代のものも数える
    static func containsMine(_ settings: JSONValue) -> Bool {
        guard case .object(let pairs)? = settings["hooks"] else { return false }
        return pairs.contains { entry in
            (entry.value.arrayValue ?? []).contains { matcher in
                (matcher["hooks"]?.arrayValue ?? []).contains { isMine($0["command"]?.stringValue ?? "") }
            }
        }
    }

    /// 登録の中身。どのフックで待ちを足し、どれで消すか
    static let events: [(event: String, matcher: String?, mode: String)] = [
        // 許可を求められたら1件足す
        ("Notification", "permission_prompt", "add"),
        // そのセッションが動き出したら消す。許可・拒否・入力のどれでも解消とみなす
        ("PostToolUse", "*", "clear"),
        ("UserPromptSubmit", nil, "clear"),
        // 作業を終えて次の指示を待つ。許可待ちが残っていれば、それも置き換わる
        ("Stop", nil, "stop"),
    ]

    /// 設定を読み、自分のフックを全部外してから、必要なら入れ直して書き戻す
    static func updated(_ settings: JSONValue, connecting: Bool, executable: String) -> JSONValue {
        var hooks: [(key: String, value: JSONValue)] = []
        if case .object(let pairs)? = settings["hooks"] { hooks = pairs }

        // まず自分の登録を全部消す。残っていると二重に積まれる
        hooks = hooks.compactMap { entry in
            let matchers = (entry.value.arrayValue ?? []).compactMap { matcher -> JSONValue? in
                let kept = (matcher["hooks"]?.arrayValue ?? []).filter { !isMine($0["command"]?.stringValue ?? "") }
                return kept.isEmpty ? nil : matcher.setting("hooks", .array(kept))
            }
            return matchers.isEmpty ? nil : (entry.key, .array(matchers))
        }

        if connecting {
            for (event, matcher, mode) in events {
                let hook = JSONValue.object([
                    ("type", .string("command")),
                    ("command", .string(command(mode, executable: executable))),
                ])
                var matchers = hooks.first { $0.key == event }?.value.arrayValue ?? []
                if let index = matchers.firstIndex(where: { $0["matcher"]?.stringValue == matcher }) {
                    let current = matchers[index]["hooks"]?.arrayValue ?? []
                    matchers[index] = matchers[index].setting("hooks", .array(current + [hook]))
                } else {
                    var pairs: [(key: String, value: JSONValue)] = []
                    if let matcher { pairs.append(("matcher", .string(matcher))) }
                    pairs.append(("hooks", .array([hook])))
                    matchers.append(.object(pairs))
                }
                if let index = hooks.firstIndex(where: { $0.key == event }) {
                    hooks[index].value = .array(matchers)
                } else {
                    hooks.append((event, .array(matchers)))
                }
            }
        }

        return settings.setting("hooks", hooks.isEmpty ? nil : .object(hooks))
    }

    private static func load() -> JSONValue? {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return nil }
        return try? JSONValue.parse(text)
    }

    private static func write(
        connecting: Bool, to settingsURL: URL, executable: String = Bundle.main.executablePath ?? ""
    ) throws {
        let fm = FileManager.default
        var settings = JSONValue.object([])
        if fm.fileExists(atPath: settingsURL.path) {
            // 読めない設定ファイルを上書きすると、利用者の設定を壊す。読めなければ何もしない
            settings = try JSONValue.parse(String(contentsOf: settingsURL, encoding: .utf8))
            let backup = settingsURL.appendingPathExtension("bak.hawky")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let next = updated(settings, connecting: connecting, executable: executable)
        try (next.serialized() + "\n").write(to: settingsURL, atomically: true, encoding: .utf8)
    }
}
