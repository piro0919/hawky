import Foundation

/// 画面を出さずに、飛び先を決める規則だけを確かめる。`./Hawky --selftest` で走る。
/// ウィンドウにもファイルにも触らないので、CI のランナーで動く。
@MainActor
enum SelfTest {

    private static var failures = 0

    static func run() -> Int32 {
        failures = 0

        // 窓の題名は `<最前面のタブ> — <フォルダ名>`。前半だけをセッションの題名と比べる
        do {
            check(Focus.titleMatches("状況確認 — koidamashii", "状況確認"), "フォルダ名の前で切って比べる")
            check(Focus.titleMatches("状況確認", "状況確認"), "フォルダ名が無い窓でも比べられる")
            check(!Focus.titleMatches("別の作業 — koidamashii", "状況確認"), "題名が違えば当たらない")

            // VS Code は区切りが ` - ` で、末尾にアプリ名が付く
            check(
                Focus.titleMatches("状況確認 - koidamashii - Visual Studio Code", "状況確認"),
                "VS Code の窓の名前でも当たる")
            check(
                Focus.titleMatches("A - B の比較 - hawky - Visual Studio Code", "A - B の比較"),
                "題名に ` - ` が入っていても当たる")

            // macOS のタブのボタンは窓の題名をそのまま持つので、同じ規則で当たる
            check(
                Focus.titleMatches("Cursor の窓をタブにまとめる — hawky", "Cursor の窓をタブにまとめる"),
                "タブのボタンの題名でも当たる")
        }

        // 拡張は長い題名の末尾を `…` に詰める
        do {
            check(Focus.points("複数リポジトリでの…", at: "複数リポジトリでのエージェント実行"), "詰められた題名は前方一致で当たる")
            check(!Focus.points("複数リポジトリでの", at: "複数リポジトリでのエージェント実行"), "`…` が無ければ前方一致では当てない")

            // アクティビティバーの拡張の名前が、たまたま題名の頭と同じになる
            check(!Focus.points("Vercel", at: "Vercelのコスト削減"), "拡張の名前には当てない")

            // 短い断片で前方一致を許すと、似た名前のファイルを開いているだけの窓に当たる
            check(!Focus.points("複数…", at: "複数リポジトリでのエージェント実行"), "6文字未満の断片では当てない")
            check(!Focus.points("README.md", at: "READMEを直す"), "前方一致しなければ当てない")
        }

        // 窓を左右に分けると、タブの名前にどちらの側かが付く
        do {
            check(Focus.tabLabel("新しいサービス考察, エディター グループ 2") == "新しいサービス考察", "日本語の側の名前を落とす")
            check(Focus.tabLabel("Fix the build, Editor Group 1") == "Fix the build", "英語の側の名前を落とす")
            check(Focus.tabLabel("新しいサービス考察") == "新しいサービス考察", "側の名前が無ければそのまま")
            check(Focus.tabLabel("A, B and C") == "A, B and C", "題名の中の読点は残す")
            check(Focus.tabLabel("Welcome, preview") == "Welcome", "VS Code の試し開きの印を落とす")
            check(Focus.tabLabel("状況確認, preview, Editor Group 2") == "状況確認", "両方付いていても落とす")
            check(
                Focus.points(Focus.tabLabel("複数リポジトリでの…, エディター グループ 2"), at: "複数リポジトリでのエージェント実行"),
                "詰められた題名に側の名前が付いていても当たる")
        }

        // 作業ディレクトリ名での絞り込み
        do {
            check(Focus.holdsFolder("状況確認 — koidamashii", "koidamashii"), "題名にフォルダ名があれば当たる")
            check(!Focus.holdsFolder("状況確認 — koidamashii", ""), "フォルダ名が空なら当てない")
            check(!Focus.holdsFolder("状況確認", "koidamashii"), "フォルダを開いていない窓には当てない")
            let sameTitle = ["アナリティクスの状況 — koidamashii", "アナリティクスの状況 — kk-web"]
            check(
                Focus.preferFolder(sameTitle, "kk-web", name: { $0 }) == sameTitle[1],
                "題名が同じならフォルダ名の合う窓を選ぶ")
            check(
                Focus.preferFolder(["アナリティクスの状況"], "kk-web", name: { $0 }) == "アナリティクスの状況",
                "フォルダ名の入った窓が無ければ題名だけで選ぶ")
        }

        // 設定ファイルの読み書き。並びも書き方も Node の JSON.stringify(v, null, 2) と同じに戻る
        do {
            let text = """
                {
                  "b": 1,
                  "a": [
                    "日本語/そのまま",
                    true,
                    null,
                    -1.5e3
                  ],
                  "c": {},
                  "d": [],
                  "e": "quote \\" and \\\\ and \\n"
                }
                """
            let parsed = try? JSONValue.parse(text)
            check(parsed?.serialized() == text, "読んで書き戻すと元と同じになる")
            check((try? JSONValue.parse("{\"a\": }")) == nil, "壊れた JSON は読まない")
            check(JSONValue.ParseError().localizedDescription == Strings.invalidJSON, "読めなかった理由を文で出せる")
        }

        // フックの登録
        do {
            let exe = "/Applications/Hawky.app/Contents/MacOS/Hawky"
            let before = try! JSONValue.parse(
                """
                {
                  "theme": "dark",
                  "hooks": {
                    "PreToolUse": [
                      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "node check.mjs" }] }
                    ],
                    "Stop": [
                      { "hooks": [{ "type": "command", "command": "node '/x/hook/hawky-hook.mjs' clear" }] }
                    ]
                  }
                }
                """)
            let connected = Connection.updated(before, connecting: true, executable: exe)
            let commands = (connected["hooks"]?["Stop"]?.arrayValue ?? []).flatMap {
                ($0["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
            check(commands == ["'\(exe)' hook stop"], "Node 時代のフックを外して入れ替える")
            check(
                connected["hooks"]?["PreToolUse"]?.arrayValue?.count == 1
                    && connected["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue == "Bash",
                "ほかのフックは残す")
            check(connected["theme"]?.stringValue == "dark", "フック以外の設定は残す")
            check(
                Connection.updated(connected, connecting: true, executable: exe) == connected,
                "何度つないでも同じになる")

            let disconnected = Connection.updated(connected, connecting: false, executable: exe)
            check(disconnected["hooks"]?["Stop"] == nil, "外すと空になった項目ごと消える")
            check(disconnected["hooks"]?["PreToolUse"] != nil, "外してもほかのフックは残す")
        }

        // 設定フォルダを移したときの付け替え。一時フォルダの中で本物のファイルを書いて確かめる
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("hawky-selftest-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let exe = "/Applications/Hawky.app/Contents/MacOS/Hawky"
            let oldDir = root.appendingPathComponent("old")
            let newDir = root.appendingPathComponent("new")
            func read(_ dir: URL) -> JSONValue? {
                (try? String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8))
                    .flatMap { try? JSONValue.parse($0) }
            }
            func put(_ dir: URL, _ text: String) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? text.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            }
            let other = #"{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "node check.mjs" }] }"#
            let mine = #"{ "hooks": [{ "type": "command", "command": "'\#(exe)' hook stop" }] }"#
            put(oldDir, #"{ "hooks": { "PreToolUse": [\#(other)], "Stop": [\#(mine)] } }"#)
            put(newDir, #"{ "theme": "dark" }"#)

            let moved = (try? Connection.move(from: oldDir, to: newDir, executable: exe)) ?? false
            check(moved, "つないでいれば新しいフォルダへ付け替える")
            check(read(oldDir).map(Connection.containsMine) == false, "前のフォルダから自分のフックを外す")
            check(read(oldDir)?["hooks"]?["PreToolUse"] != nil, "前のフォルダのほかのフックは残す")
            check(
                fm.fileExists(atPath: oldDir.appendingPathComponent("settings.json.bak.hawky").path),
                "外す前に前のフォルダの控えを取る")
            check(read(newDir).map(Connection.containsMine) == true, "新しいフォルダに登録する")
            check(read(newDir)?["theme"]?.stringValue == "dark", "新しいフォルダのほかの設定は残す")

            let snapshot = read(newDir)
            let again = (try? Connection.move(from: oldDir, to: newDir, executable: exe)) ?? true
            check(!again && read(newDir) == snapshot, "もう一度流しても何も変わらない")

            let empty = root.appendingPathComponent("empty")
            let fresh = root.appendingPathComponent("fresh")
            put(empty, #"{ "hooks": { "PreToolUse": [\#(other)] } }"#)
            let untouched = (try? Connection.move(from: empty, to: fresh, executable: exe)) ?? true
            check(!untouched && !fm.fileExists(atPath: fresh.path), "つないでいなければ新しいフォルダにも入れない")

            let broken = root.appendingPathComponent("broken")
            put(broken, "{ \"hooks\": ")
            do {
                try Connection.move(from: broken, to: fresh, executable: exe)
                check(false, "読めない設定ファイルでは止める")
            } catch let error as Connection.MoveError {
                check(
                    error.url.lastPathComponent == "settings.json"
                        && error.url.deletingLastPathComponent().lastPathComponent == "broken",
                    "読めない設定ファイルでは止め、どのファイルかを返す")
            } catch {
                check(false, "読めない設定ファイルでは止め、どのファイルかを返す")
            }
            check(
                (try? String(contentsOf: broken.appendingPathComponent("settings.json"), encoding: .utf8))
                    == "{ \"hooks\": ",
                "読めない設定ファイルは書き換えない")
            check(
                (try? Connection.move(from: newDir, to: newDir, executable: exe)) == false
                    && read(newDir).map(Connection.containsMine) == true,
                "同じフォルダを選び直しても外さない")
        }

        // Claude Code の設定フォルダ。窓で選んだもの、CLAUDE_CONFIG_DIR、~/.claude の順
        do {
            let home = URL(fileURLWithPath: "/Users/me")
            let env = ["CLAUDE_CONFIG_DIR": "/opt/claude"]
            check(
                Paths.claudeDir(chosen: nil, environment: [:], home: home).path == "/Users/me/.claude",
                "何も無ければ ~/.claude")
            check(
                Paths.claudeDir(chosen: nil, environment: env, home: home).path == "/opt/claude",
                "CLAUDE_CONFIG_DIR があればそこ")
            check(
                Paths.claudeDir(chosen: "/srv/c", environment: env, home: home).path == "/srv/c",
                "窓で選んだものが環境変数より先")
            check(
                Paths.claudeDir(chosen: "", environment: ["CLAUDE_CONFIG_DIR": " "], home: home).path
                    == "/Users/me/.claude",
                "空の指定は無いものとして扱う")
            check(
                Paths.claudeDir(chosen: nil, environment: ["CLAUDE_CONFIG_DIR": "~/work/.claude"], home: home).path
                    == "/Users/me/work/.claude",
                "~ をホームに展開する")
            check(Paths.display(URL(fileURLWithPath: "/Users/me/.claude"), home: home) == "~/.claude", "ホームは ~ に縮めて出す")
            check(Paths.display(URL(fileURLWithPath: "/Users/meme"), home: home) == "/Users/meme", "名前が似ているだけなら縮めない")
            check(Paths.pendingDir.path.hasSuffix("/.claude/hawky/pending"), "待ちの置き場は設定フォルダに合わせて動かさない")
        }

        // 待ちを捨てる決まり
        do {
            let now = Date()
            let me = getpid()
            check(!Store.isStale(at: now.addingTimeInterval(-30 * 60), pid: me, now: now), "プロセスが生きていれば30分たっても残す")
            check(Store.isStale(at: now, pid: 999_999, now: now), "プロセスが居なければすぐ捨てる")
            check(Store.isStale(at: now.addingTimeInterval(-25 * 60 * 60), pid: me, now: now), "生きていても24時間たてば捨てる")
            check(!Store.isStale(at: now.addingTimeInterval(-30 * 60), pid: 0, now: now), "番号が無ければ1時間までは残す")
            check(!Store.isOrphanedFromEditor(me), "シェルから起動したプロセスは置き去りとみなさない")

            // 終わったセッションは、子のプロセスが起動しても消さない（裏の開発サーバーなど）
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/bin/sleep")
            server.arguments = ["5"]
            let since = Date().addingTimeInterval(-10)
            try? server.run()
            check(Store.settled(.finished, at: since, pid: getpid()) == .finished, "終わったセッションは子が起動しても残す")
            check(Store.settled(.permission, at: since, pid: getpid()) == .working, "許可待ちは子が起動したら作業中に移す")
            check(!Store.isStale(at: since, pid: getpid(), now: Date()), "子が起動しても、プロセスが居れば捨てない")
            server.terminate()
            check(Store.isStale(at: now.addingTimeInterval(-61 * 60), pid: 0, now: now), "番号が無ければ1時間で捨てる")

            // 許可されてコマンドが動き出したら、終わるのを待たずに作業中へ移す
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["5"]
            let before = Date().addingTimeInterval(-10)
            try? child.run()
            check(Store.startedWork(getpid(), since: before), "待ちのあとに起動した子が居れば、許可されたとみなす")
            check(!Store.startedWork(getpid(), since: Date().addingTimeInterval(60)), "待ちより前に起動した子では、許可されたとみなさない")
            child.terminate()
        }

        // 一覧に出す名前
        do {
            let inRepo = Pending(sessionID: "abcdef123456", cwd: "/Users/me/Repository/hawky", title: "", at: Date())
            check(inRepo.label == "hawky", "作業ディレクトリ名を出す")

            let nowhere = Pending(sessionID: "abcdef123456", cwd: "", title: "", at: Date())
            check(nowhere.label == "abcdef12", "作業ディレクトリが無ければセッションIDの頭8文字")

            // 1つの窓に複数のセッションがあると、フォルダ名だけでは行が同じになる
            let titled = Pending(
                sessionID: "abcdef123456", cwd: "/Users/me/Repository/hawky", title: "状況確認", at: Date())
            check(titled.label == "状況確認 — hawky", "題名があれば窓の名前と同じ形で出す")

            let long = Pending(
                sessionID: "abcdef123456", cwd: "/Users/me/Repository/hawky",
                title: String(repeating: "あ", count: 50), at: Date())
            check(long.label.hasSuffix("… — hawky"), "長い題名は詰める")
            check(long.label.count == Pending.titleLimit + 1 + " — hawky".count, "詰めた題名は上限の長さ")
        }

        // Esc で中断した記録。一時ファイルに transcript の形で書いて確かめる
        do {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("hawky-selftest-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: file) }
            func write(_ lines: [String]) {
                try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            let stopped =
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-10-07T10:00:05.123Z"}"#
            let toolStopped =
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-10-07T10:00:05.123Z"}"#
            let quoted =
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"[Request interrupted by user]"}]},"timestamp":"2026-10-07T10:00:05.123Z"}"#
            let started = ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")!
            let later = ISO8601DateFormatter().date(from: "2026-10-07T10:01:00Z")!

            write([stopped])
            check(Hook.interrupted(file.path, since: started), "作業を始めたあとの中断を拾う")
            check(!Hook.interrupted(file.path, since: later), "前の作業の中断は拾わない")
            write([toolStopped])
            check(Hook.interrupted(file.path, since: started), "ツールの途中の中断も拾う")
            write([quoted])
            check(!Hook.interrupted(file.path, since: started), "ツールの出力に混ざった文字列は拾わない")
            check(!Hook.interrupted("", since: started), "transcript が無ければ中断とみなさない")
        }

        // Snappy の展開。字の並び3つのあとに、3バイト前から6バイト写す
        do {
            let compressed: [UInt8] = [0x09, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03]
            check(Snappy.decompress(compressed) == Array("abcabcabc".utf8), "前の字を重ねて写して展開する")
            check(Snappy.decompress([0x0a, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03]) == nil, "長さが合わなければ読まない")
            check(Snappy.decompress([0x09, 0x08, 0x61, 0x62, 0x63, 0x09, 0x09]) == nil, "出した字より前は写さない")
        }

        // LevelDB の書き込みの控えと表。本物と同じ並びのバイト列を組んで読む
        do {
            func varint(_ n: Int) -> [UInt8] {
                var n = n
                var out: [UInt8] = []
                while n >= 0x80 {
                    out.append(UInt8(n & 0x7f) | 0x80)
                    n >>= 7
                }
                return out + [UInt8(n)]
            }
            func le(_ n: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((n >> (8 * UInt64($0))) & 0xff) } }
            let key = Array("_https://claude.ai\u{0}\u{1}epitaxy-unread-v1".utf8)
            let match: ([UInt8]) -> Bool = { $0.ends(with: Array("\u{0}\u{1}epitaxy-unread-v1".utf8)) }

            // 控え: 通し番号 7 から2件。1件目が書き込み、2件目が別の鍵の削除
            let batch =
                le(7, 8) + le(2, 4) + [1] + varint(key.count) + key + varint(3) + Array("old".utf8)
                + [0] + varint(3) + Array("abc".utf8)
            let record = [0, 0, 0, 0] + le(UInt64(batch.count), 2) + [1] + batch
            let records = LevelDB.log(record)
            check(
                records.count == 2 && records[0].key == key && records[0].entry.sequence == 7
                    && records[0].entry.value == Array("old".utf8) && records[1].entry.sequence == 8
                    && records[1].entry.type == 0,
                "書き込みの控えから鍵と値と通し番号を読む")
            check(LevelDB.log(Array(record.dropLast(2))).isEmpty, "途中で切れた控えは読み飛ばす")

            // 表: 無圧縮の塊1つと、それを指す索引。鍵の末尾8バイトに通し番号と種類が入る
            func block(_ items: [([UInt8], [UInt8])]) -> [UInt8] {
                items.flatMap { varint(0) + varint($0.0.count) + varint($0.1.count) + $0.0 + $0.1 } + le(0, 4)
                    + le(1, 4)
            }
            let data = block([(key + le(9 << 8 | 1, 8), Array("new".utf8))])
            let dataHandle = varint(0) + varint(data.count)
            let indexOffset = data.count + 5
            let index = block([(key + le(9 << 8 | 1, 8), dataHandle)])
            let metaHandle = varint(indexOffset + index.count + 5) + varint(0)
            var footer = metaHandle + varint(indexOffset) + varint(index.count)
            footer += [UInt8](repeating: 0, count: 40 - footer.count) + le(0xdb47_7524_8b80_fb57, 8)
            let table = data + [0, 0, 0, 0, 0] + index + [0, 0, 0, 0, 0] + footer
            let rows = LevelDB.table(table)
            check(
                rows.count == 1 && rows[0].key == key && rows[0].entry.sequence == 9
                    && rows[0].entry.value == Array("new".utf8),
                "表の塊から鍵と値と通し番号を読む")

            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("hawky-selftest-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(record).write(to: dir.appendingPathComponent("000003.log"))
            try? Data(table).write(to: dir.appendingPathComponent("000004.ldb"))
            check(
                LevelDB.latest(in: dir, matching: match)?.value == Array("new".utf8),
                "控えと表のうち、通し番号の大きい方を取る")
        }

        // デスクトップアプリの未読の一覧
        do {
            let json =
                #"{"state":{"unreadIds":["local_a"],"explicitUnreadIds":["local_b"],"stoppedRuns":[]},"version":0}"#
            check(
                Desktop.unreadIDs(fromLocalStorage: [1] + Array(json.utf8)) == ["local_a", "local_b"],
                "1バイトずつの値から未読と「未読にする」の印を読む")
            let utf16 = [UInt8](json.data(using: .utf16LittleEndian)!)
            check(Desktop.unreadIDs(fromLocalStorage: [0] + utf16) == ["local_a", "local_b"], "UTF-16 の値も読む")
            check(Desktop.unreadIDs(fromLocalStorage: [1] + Array("{".utf8)) == nil, "壊れた値は読まない")

            let state =
                #"{"sessionId":"local_a","cliSessionId":"cli-1","lastAssistantCliSessionId":"cli-2","title":"状況確認","isArchived":false}"#
            let pairs = Desktop.session(fromState: Data(state.utf8))
            check(
                pairs.map(\.0) == ["cli-1", "cli-2"]
                    && pairs.allSatisfy { $0.1 == Desktop.Session(id: "local_a", title: "状況確認") },
                "どちらの Claude Code のセッションからも引ける")
            let archived = #"{"sessionId":"local_a","cliSessionId":"cli-1","isArchived":true}"#
            check(Desktop.session(fromState: Data(archived.utf8)).isEmpty, "アーカイブしたセッションは引かない")

            let app = Desktop.bundleID
            let sessions = [
                "read": Desktop.Session(id: "local_read", title: "読んだ"),
                "unread": Desktop.Session(id: "local_unread", title: "未読"),
                "asking": Desktop.Session(id: "local_asking", title: "許可"),
            ]
            func pending(_ id: String, _ kind: Pending.Kind, app: String = app, title: String = "") -> Pending {
                Pending(
                    sessionID: id, cwd: "/Users/me/Repository/hawky", title: title, at: Date(), app: app, kind: kind)
            }
            let all = [
                pending("read", .finished), pending("unread", .finished), pending("asking", .permission),
                pending("lost", .finished), pending("cursor", .finished, app: Focus.cursorBundleID),
            ]
            let applied = Desktop.apply(all, sessions: sessions, unread: ["local_unread"])
            check(!applied.contains { $0.sessionID == "read" }, "読んだ指示待ちは外す")
            check(
                applied.first { $0.sessionID == "unread" }.map { $0.title == "未読" && $0.desktopID == "local_unread" }
                    == true,
                "未読の指示待ちは残し、題名と飛び先を付ける")
            check(applied.contains { $0.sessionID == "asking" }, "許可待ちは未読でなくても残す")
            check(applied.contains { $0.sessionID == "lost" }, "デスクトップアプリの記録に無いセッションは残す")
            check(
                applied.first { $0.sessionID == "cursor" }?.desktopID == "",
                "ほかのアプリのセッションには触らない")
            check(Desktop.apply(all, sessions: sessions, unread: nil).count == all.count, "未読の一覧が読めなければ何も外さない")
            check(
                Desktop.apply(
                    [pending("unread", .finished, title: "元の題名")], sessions: sessions, unread: ["local_unread"]
                )
                .first?.title == "元の題名",
                "transcript から題名を拾えていればそれを使う")
            check(
                Desktop.link(for: "local_a")?.absoluteString == "claude://claude.ai/epitaxy/local_a",
                "セッションのリンクを組む")
        }

        print(failures == 0 ? "selftest: ok" : "selftest: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ name: String) {
        guard !condition else { return }
        failures += 1
        print("FAIL: \(name)")
    }
}
