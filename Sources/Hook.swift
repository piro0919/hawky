import Foundation

/// Claude Code のフックとして呼ばれたときの入口。`Hawky hook add` / `Hawky hook clear`。
///   add   … 許可待ちが発生した（Notification / permission_prompt）
///   clear … そのセッションが動き出した＝待ちが解消した
/// 標準入力にフックの JSON が来る。画面は出さず、ファイルを1つ書くか消すだけで終わる。
/// 以前は Node のスクリプトで、Node の入っていない Mac では動かなかった
enum Hook {
    /// フックは何があっても Claude Code を止めない。読めなければ黙って 0 で終わる
    static func run(_ arguments: [String]) -> Int32 {
        let adding = arguments.first == "add"
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }

        // ファイル名になるので、パスを壊す文字は落とす
        let id = String(
            ((input["session_id"] as? String) ?? "").unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            })
        guard !id.isEmpty else { return 0 }

        let file = Paths.pendingDir.appendingPathComponent("\(id).json")
        guard adding else {
            try? FileManager.default.removeItem(at: file)
            return 0
        }

        let transcript = (input["transcript_path"] as? String) ?? ""
        let cwd = (input["cwd"] as? String) ?? ""
        let project = projectFolder(transcript)
        let record: [String: Any] = [
            "session_id": id,
            "cwd": cwd,
            "project": project.isEmpty ? cwd : project,
            "title": sessionTitle(transcript),
            "pid": Int(claudeProcess()),
            // 起動元のアプリの ID は環境変数で子まで引き継がれる。Cursor なら Cursor の、
            // VS Code なら VS Code の ID が入る。どのアプリの窓を探すかはこれで決める
            "app": ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "",
            "at": Int(Date().timeIntervalSince1970),
        ]
        try? FileManager.default.createDirectory(at: Paths.pendingDir, withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: record) {
            try? out.write(to: file, options: .atomic)
        }
        return 0
    }

    /// Cursor のウィンドウ名とタブ名になるのは、Claude Code が付けた題名。
    /// transcript の末尾にある最後の ai-title がそれ。会話が進むごとに追記されるので末尾だけ読む
    static func sessionTitle(_ path: String) -> String {
        guard let tail = read(path, fromEnd: true, limit: 512 * 1024) else { return "" }
        for line in tail.split(separator: "\n").reversed() where line.contains("\"ai-title\"") {
            // 先頭の1行は途中で切れている。読めないのは織り込み済み
            guard let record = object(line), record["type"] as? String == "ai-title",
                let title = record["aiTitle"] as? String
            else { continue }
            return title
        }
        return ""
    }

    /// セッションを開いたときのフォルダ。フックに来る cwd はその時点のシェルの居場所で、
    /// 途中で cd すると別のリポジトリを指す。transcript の各行が cwd を持ち、最初の行がそれにあたる
    static func projectFolder(_ path: String) -> String {
        guard let head = read(path, fromEnd: false, limit: 256 * 1024) else { return "" }
        for line in head.split(separator: "\n") where line.contains("\"cwd\"") {
            if let cwd = object(line)?["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return ""
    }

    /// このフックを呼んだ Claude Code のプロセス番号。フックはシェルを挟んで呼ばれるので、
    /// 親を辿って claude という名前のプロセスを探す
    static func claudeProcess() -> Int32 {
        var pid = getppid()
        for _ in 0..<6 where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
            let name = withUnsafeBytes(of: info.pbi_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "claude" { return pid }
            pid = Int32(info.pbi_ppid)
        }
        return 0
    }

    private static func read(_ path: String, fromEnd: Bool, limit: Int) -> String? {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let length = min(Int(size), limit)
        try? handle.seek(toOffset: fromEnd ? size - UInt64(length) : 0)
        guard let data = try? handle.read(upToCount: length) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}
