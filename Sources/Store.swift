import Foundation

struct Pending {
    let sessionID: String
    /// セッションを開いたときのフォルダ。Cursor の窓が開いているのはここ。
    /// 途中で cd した先ではない。古いフックの記録には無いので、そのときは cwd で代える
    let cwd: String
    /// Claude Code が付けたセッションの題名。フックが transcript から拾う。
    /// 題名が付く前に待ちが起きると空になる
    let title: String
    let at: Date

    /// 一覧に出す名前。Cursor の窓の名前と同じ `<題名> — <フォルダ名>` の形にする。
    /// 1つの窓に複数のセッションがあると、フォルダ名だけでは行の見分けが付かない
    var label: String {
        let folder = folderName.isEmpty ? String(sessionID.prefix(8)) : folderName
        guard !title.isEmpty else { return folder }
        let head = title.count > Self.titleLimit ? "\(title.prefix(Self.titleLimit))…" : title
        return "\(head) — \(folder)"
    }

    /// メニューの幅を題名で押し広げないための上限
    static let titleLimit = 40

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
        guard
            let files = try? fm.contentsOfDirectory(
                at: Paths.pendingDir, includingPropertiesForKeys: nil
            )
        else { return [] }

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
            out.append(
                Pending(
                    sessionID: id,
                    cwd: (obj["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (obj["cwd"] as? String) ?? "",
                    title: (obj["title"] as? String) ?? "",
                    at: at
                ))
        }
        // 古い待ちほど気付かれていない。上に置く
        return out.sorted { $0.at < $1.at }
    }
}
