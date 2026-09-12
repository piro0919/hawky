import Foundation

struct Pending {
    let sessionID: String
    let cwd: String
    /// Claude Code が付けたセッションの題名。フックが transcript から拾う。
    /// 題名が付く前に待ちが起きると空になる
    let title: String
    let at: Date

    /// 一覧に出す名前。作業ディレクトリ名だけで見分ける
    var label: String {
        folderName.isEmpty ? String(sessionID.prefix(8)) : folderName
    }

    var folderName: String {
        (cwd as NSString).lastPathComponent
    }
}

enum Store {
    /// Cursor ごと落ちるなどして解消のフックが飛ばなかった待ちは、
    /// この時間を過ぎたら捨てる。件数が減らないまま居座るのを防ぐ
    static let expiry: TimeInterval = 10 * 60

    static func load() -> [Pending] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Paths.pendingDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var out: [Pending] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = obj["session_id"] as? String
            else { continue }

            let at = Date(timeIntervalSince1970: (obj["at"] as? Double) ?? 0)
            if Date().timeIntervalSince(at) > expiry {
                try? fm.removeItem(at: file)
                continue
            }
            out.append(Pending(
                sessionID: id,
                cwd: (obj["cwd"] as? String) ?? "",
                title: (obj["title"] as? String) ?? "",
                at: at
            ))
        }
        // 古い待ちほど気付かれていない。上に置く
        return out.sorted { $0.at < $1.at }
    }
}
