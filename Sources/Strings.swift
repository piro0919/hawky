import Foundation

/// 画面に出す文言。日本語の環境なら日本語、それ以外は英語
enum Strings {
    private static let japanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false

    static let statusDescription = japanese ? "Claude Code の許可待ち" : "Claude Code waiting for permission"
    static let nothingWaiting = japanese ? "許可待ちはありません" : "Nothing is waiting"
    static let quit = japanese ? "終了" : "Quit Hawky"
}
