import AppKit

/// Claude デスクトップアプリで動いているセッション。
/// デスクトップアプリは、アーカイブするまでセッションごとの Claude Code のプロセスを生かしておく。
/// 「プロセスが終わったら消す」では指示待ちが消えず、開いたままのセッションが全部溜まった。
/// サイドバーの未読の印と同じものを見て、読んだ指示待ちは一覧から外す
enum Desktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    struct Session: Equatable {
        /// デスクトップアプリのセッションの ID。`local_` で始まる
        let id: String
        /// サイドバーに出ている題名。デスクトップアプリは transcript に ai-title を書かないので、ここから取る
        let title: String
    }

    static var supportDir: URL {
        Paths.home.appendingPathComponent("Library/Application Support/Claude")
    }

    /// 未読のセッションの一覧が入っている Local Storage の鍵。前に付く `_https://claude.ai\0\u{1}` は
    /// 読み込み元で、変わっても拾えるよう末尾で見る
    private static let unreadKey = Array("\u{0}\u{1}epitaxy-unread-v1".utf8)

    /// サイドバーで未読になっているセッションの ID。読めなければ nil で、そのときは何も外さない
    static func unreadIDs() -> Set<String>? {
        let dir = supportDir.appendingPathComponent("Local Storage/leveldb")
        guard let entry = LevelDB.latest(in: dir, matching: { $0.ends(with: unreadKey) }) else { return nil }
        // 消された鍵は、未読が無いのと同じ
        guard entry.type == 1 else { return [] }
        return unreadIDs(fromLocalStorage: entry.value)
    }

    /// Local Storage の値は、頭の1バイトで書き方が分かれる。1 なら1バイトずつ（Latin-1）、0 なら UTF-16
    static func unreadIDs(fromLocalStorage value: [UInt8]) -> Set<String>? {
        // 知らない書き方なら読まない。読めなければ何も外さない
        guard let head = value.first, head <= 1 else { return nil }
        let body = Data(value.dropFirst())
        guard let text = String(data: body, encoding: head == 1 ? .isoLatin1 : .utf16LittleEndian),
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let state = object["state"] as? [String: Any]
        else { return nil }
        // 「未読にする」で付けた印は別の一覧に入る
        let ids = [state["unreadIds"], state["explicitUnreadIds"]].flatMap { ($0 as? [String]) ?? [] }
        return Set(ids)
    }

    /// Claude Code のセッション ID から引く、デスクトップアプリのセッション。
    /// `claude-code-sessions/<アカウント>/<組織>/local_*.json` に1件1ファイルで置かれている
    static func sessions() -> [String: Session] {
        let fm = FileManager.default
        let root = supportDir.appendingPathComponent("claude-code-sessions")
        var out: [String: Session] = [:]
        var seen: Set<String> = []
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
                    seen.insert(file.path)
                    for (cli, session) in cachedSession(file) { out[cli] = session }
                }
            }
        }
        // 消したセッションの分を、覚えておかない
        lock.lock()
        cache = cache.filter { seen.contains($0.key) }
        lock.unlock()
        return out
    }

    /// 1件のファイルは数百KBになり、合わせると数MBある。3秒ごとに読み直さないよう、変わったものだけ読む
    nonisolated(unsafe) private static var cache: [String: (Date, [(String, Session)])] = [:]
    private static let lock = NSLock()

    private static func cachedSession(_ file: URL) -> [(String, Session)] {
        guard
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if let (seen, pairs) = cache[file.path], seen == modified { return pairs }
        let pairs = (try? Data(contentsOf: file)).map(session(fromState:)) ?? []
        cache[file.path] = (modified, pairs)
        return pairs
    }

    /// 1件のファイルから、Claude Code のセッション ID とデスクトップアプリのセッションの組を取る。
    /// Claude Code のセッションが途中で替わることがあるので、最後に返答したものも引けるようにする
    static func session(fromState data: Data) -> [(String, Session)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["sessionId"] as? String, (object["isArchived"] as? Bool) != true
        else { return [] }
        let session = Session(id: id, title: (object["title"] as? String) ?? "")
        let clis = Set([object["cliSessionId"], object["lastAssistantCliSessionId"]].compactMap { $0 as? String })
        return clis.filter { !$0.isEmpty }.sorted().map { ($0, session) }
    }

    /// デスクトップアプリのセッションに、題名と飛び先を付け、読んだ指示待ちを外す。
    /// 未読の一覧が読めないときや、セッションが見つからないときは、これまでどおり残す
    static func apply(_ pending: [Pending], sessions: [String: Session], unread: Set<String>?) -> [Pending] {
        pending.compactMap { p in
            guard p.app == bundleID, let session = sessions[p.sessionID] else { return p }
            if p.kind == .finished, let unread, !unread.contains(session.id) { return nil }
            var next = p
            next.desktopID = session.id
            if next.title.isEmpty { next.title = session.title }
            return next
        }
    }

    /// 見ているのはデスクトップアプリの中だけなので、デスクトップアプリのセッションが無ければ何も読まない
    static func apply(_ pending: [Pending]) -> [Pending] {
        guard pending.contains(where: { $0.app == bundleID }) else { return pending }
        return apply(pending, sessions: sessions(), unread: unreadIDs())
    }

    /// デスクトップアプリの窓の名前は「Claude」だけで、セッションの題名が出ない（実測）。窓を探さずに、
    /// セッションのリンクを開いて切り替える（そのセッションに切り替わることを実測した）
    static func link(for id: String) -> URL? {
        URL(string: "claude://claude.ai/epitaxy/\(id)")
    }
}

extension Array where Element: Equatable {
    func ends(with suffix: [Element]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
