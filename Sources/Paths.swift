import Foundation

enum Paths {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// フックが許可待ちを1件1ファイルで置く場所。Claude Code の設定フォルダを移していても、ここは動かさない。
    /// フックは Claude Code の中で動くので CLAUDE_CONFIG_DIR が見えるが、Finder から開いたアプリには見えない。
    /// 両者で置き場が食い違うと、待ちが一覧に出なくなる
    static var pendingDir: URL { home.appendingPathComponent(".claude/hawky/pending") }

    /// Claude Code の設定フォルダ。settings.json はここにある
    static var claudeDir: URL {
        claudeDir(
            chosen: Preferences.claudeDir, environment: ProcessInfo.processInfo.environment, home: home)
    }

    /// 設定の窓で選んだフォルダ、CLAUDE_CONFIG_DIR、`~/.claude` の順に見る。
    /// Finder から開いたアプリにはシェルの環境変数が届かないので、窓で選べるようにしてある
    static func claudeDir(chosen: String?, environment: [String: String], home: URL) -> URL {
        for path in [chosen, environment["CLAUDE_CONFIG_DIR"]] {
            guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { continue }
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent(".claude")
    }

    /// 画面に出すときは、ホームを `~` に縮める
    static func display(_ url: URL, home: URL = home) -> String {
        let path = url.standardizedFileURL.path
        let root = home.standardizedFileURL.path
        if path == root { return "~" }
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }
}
