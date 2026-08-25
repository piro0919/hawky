import Foundation

enum Paths {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// フックが許可待ちを1件1ファイルで置く場所
    static var pendingDir: URL { home.appendingPathComponent(".claude/machiban/pending") }
}
