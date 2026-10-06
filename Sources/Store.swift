import Foundation

struct Pending {
    /// 何を待っているか。許可の返事か、次の指示か。作業中は何も待っていない
    enum Kind: String {
        case permission
        case working
        case finished
    }

    let sessionID: String
    /// セッションを開いたときのフォルダ。Cursor の窓が開いているのはここ。
    /// 途中で cd した先ではない。古いフックの記録には無いので、そのときは cwd で代える
    let cwd: String
    /// Claude Code が付けたセッションの題名。フックが transcript から拾う。
    /// 題名が付く前に待ちが起きると空になる
    let title: String
    let at: Date
    /// セッションが動いているアプリの ID。フックが起動元から引き継いだ環境変数から拾う。
    /// 古い記録には無いので、そのときは Cursor とみなす
    var app: String = ""
    /// 古い記録には無い。そのときは許可待ち
    var kind: Kind = .permission
    /// 中断の記録を探す transcript。古い記録には無い
    var transcript: String = ""

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
    /// 待ちを捨てる決まり。許可待ちは何十分も放っておかれることがあるので、時間では捨てない。
    /// フックが Claude Code のプロセス番号を残していれば、そのプロセスが終わったときに捨てる。
    /// Cursor ごと落ちて解消のフックが飛ばなかった待ちも、これで居座らない。
    /// 10分で捨てていた頃は、10分を超えて待たせた本物の許可待ちまで消えていた
    static let expiryWithProcess: TimeInterval = 24 * 60 * 60
    /// プロセス番号の無い記録（古いフックが書いたものや、番号を取り損ねたもの）は時間で捨てる
    static let expiryWithoutProcess: TimeInterval = 60 * 60

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
            let pid = (obj["pid"] as? Int32) ?? Int32((obj["pid"] as? Int) ?? 0)
            var kind = (obj["kind"] as? String).flatMap(Pending.Kind.init(rawValue:)) ?? .permission
            let transcript = (obj["transcript"] as? String) ?? ""
            if isStale(at: at, pid: pid)
                || (kind == .working && Hook.interrupted(transcript, since: at))
            {
                try? fm.removeItem(at: file)
                continue
            }
            // 許可された待ちは、作業中に移す。消してしまうと、次のツールが終わるまで一覧から抜ける
            if kind != settled(kind, at: at, pid: pid) {
                kind = .working
                var next = obj
                next["kind"] = kind.rawValue
                if let out = try? JSONSerialization.data(withJSONObject: next) {
                    try? out.write(to: file, options: .atomic)
                }
            }
            out.append(
                Pending(
                    sessionID: id,
                    cwd: (obj["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (obj["cwd"] as? String) ?? "",
                    title: (obj["title"] as? String) ?? "",
                    at: at,
                    app: (obj["app"] as? String) ?? "",
                    kind: kind,
                    transcript: transcript
                ))
        }
        // 古い待ちほど気付かれていない。上に置く
        return out.sorted { $0.at < $1.at }
    }

    /// 記録の種類だけを読む。フックが、書き直すかどうかを決めるのに使う
    static func kind(of file: URL) -> Pending.Kind? {
        guard let data = try? Data(contentsOf: file),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["kind"] as? String).flatMap(Pending.Kind.init(rawValue:))
    }

    /// 捨てるか。許可された待ちは捨てずに作業中へ移すので、ここでは見ない（`load` が見る）
    static func isStale(at: Date, pid: Int32, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(at)
        guard pid > 0 else { return age > expiryWithoutProcess }
        return age > expiryWithProcess || !isAlive(pid) || isOrphanedFromEditor(pid)
    }

    /// 子のプロセスの起動を見て、種類を決め直す。許可待ちは子が起動したら作業中に移る。
    /// 終わったセッションは、指示を打てば UserPromptSubmit で作業中になる。裏で動かしている
    /// 開発サーバーが子を起こすこともあるので、子の起動では変えない
    static func settled(_ kind: Pending.Kind, at: Date, pid: Int32) -> Pending.Kind {
        kind == .permission && pid > 0 && startedWork(pid, since: at) ? .working : kind
    }

    /// 許可されたか。Claude Code には「許可された」ときに届くフックが無く、届くのは
    /// コマンドが終わったときの PostToolUse だけ。長く動くコマンドだと、許可したあとも
    /// 終わるまで待ちとして数え続けていた。許可されるとコマンドを動かすシェルが
    /// Claude Code の子として起動するので、待ちが始まったあとに起動した子が居れば
    /// 許可されたとみなす。MCP のサーバーや裏で動かしている開発サーバーは、
    /// 待ちより前に起動しているので当たらない。待ちを書いたフック自身も子として
    /// 起動するので、その分として2秒の猶予を置く
    static func startedWork(_ pid: Int32, since at: Date) -> Bool {
        let threshold = Int(at.timeIntervalSince1970) + 2
        return childStartTimes(of: pid).contains { $0 >= threshold }
    }

    /// 子のプロセスが起動した時刻（秒）
    static func childStartTimes(of pid: Int32) -> [Int] {
        var children = [Int32](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return children.prefix(Int(count)).compactMap { child in
            guard child > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Int(info.pbi_start_tvsec)
        }
    }

    /// そのプロセスが居るか。シグナル 0 は何も送らずに、居るかどうかだけを返す。
    /// 他人のプロセスなら EPERM になるが、居ることには変わりない
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// エディタに置き去りにされたか。Cursor を再起動すると、前の拡張ホストが死なずに
    /// launchd に引き取られて残ることがあり、そこから起動した Claude Code も生き続ける。
    /// 画面からは消えているのに、プロセスが居るので待ちが消えなかった。
    /// 拡張ホストは「〜 Helper (Plugin)」という名前で、本来はエディタの本体の子になる。
    /// 親が launchd になっていれば置き去りとみなす。ターミナルから起動した
    /// Claude Code は親がシェルなので当たらない
    static func isOrphanedFromEditor(_ pid: Int32) -> Bool {
        let parent = parentPID(of: pid)
        guard parent > 1, processName(parent).contains("Helper") else { return false }
        return parentPID(of: parent) == 1
    }

    static func parentPID(of pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Int32(info.pbi_ppid)
    }

    static func processName(_ pid: Int32) -> String {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "" }
        return String(cString: name)
    }
}
