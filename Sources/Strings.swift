import Foundation

/// 画面の言語。既定はシステムに従い、日本語の環境なら日本語、それ以外は英語にする
enum Language: String, CaseIterable {
    case system, ja, en

    private static let key = "language"

    /// 設定で選ばれている言語
    static var chosen: Language {
        get { UserDefaults.standard.string(forKey: key).flatMap(Language.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    /// 実際に使う言語
    static var resolved: Language {
        switch chosen {
        case .ja: return .ja
        case .en: return .en
        case .system: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? .ja : .en
        }
    }

    var label: String {
        switch self {
        case .system: return Strings.t("システムに従う", "Follow system")
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

extension Notification.Name {
    static let languageChanged = Notification.Name("hawky.languageChanged")
}

/// 画面に出す文言。言語は設定で切り替えられるので、読むたびに選び直す
enum Strings {
    static func t(_ ja: String, _ en: String) -> String { Language.resolved == .ja ? ja : en }

    // メニュー
    static var statusDescription: String { t("Claude Code の許可待ち", "Claude Code waiting for permission") }
    static var nothingWaiting: String { t("許可待ちはありません", "Nothing is waiting") }
    static var notConnected: String { t("Claude Code に接続されていません", "Not connected to Claude Code") }
    static var finishedHeader: String { t("作業が終わったセッション", "Finished") }
    static var settings: String { t("設定…", "Settings…") }
    static var quit: String { t("終了", "Quit") }

    // 設定の窓
    static var settingsTitle: String { t("設定", "Settings") }
    static var claudeCode: String { "Claude Code" }
    static var connected: String { t("接続済み", "Connected") }
    static var disconnected: String { t("未接続", "Not connected") }
    static var connect: String { t("接続する", "Connect") }
    static var disconnect: String { t("接続を解除", "Disconnect") }
    static var connectFailed: String {
        t("Claude Code の設定ファイルを書き換えられませんでした", "Could not update Claude Code's settings file")
    }
    static var showsFinished: String { t("作業が終わったセッションも出す", "Show finished sessions") }
    static var hotKey: String { t("\(HotKey.display) で一番古い待ちへ移る", "Jump to the oldest wait with \(HotKey.display)") }
    static var language: String { t("言語", "Language") }
    static var launchAtLogin: String { t("ログイン時に起動", "Launch at Login") }
    static var launchFailed: String { t("ログイン時の起動を切り替えられませんでした", "Could not change Launch at Login") }
    static var checkForUpdates: String { t("アップデートを確認", "Check for Updates") }
}
