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

        // 待ちを捨てる決まり
        do {
            let now = Date()
            let me = getpid()
            check(!Store.isStale(at: now.addingTimeInterval(-30 * 60), pid: me, now: now), "プロセスが生きていれば30分たっても残す")
            check(Store.isStale(at: now, pid: 999_999, now: now), "プロセスが居なければすぐ捨てる")
            check(Store.isStale(at: now.addingTimeInterval(-25 * 60 * 60), pid: me, now: now), "生きていても24時間たてば捨てる")
            check(!Store.isStale(at: now.addingTimeInterval(-30 * 60), pid: 0, now: now), "番号が無ければ1時間までは残す")

            // 終わったセッションは、子のプロセスが起動しても消さない（裏の開発サーバーなど）
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/bin/sleep")
            server.arguments = ["5"]
            let since = Date().addingTimeInterval(-10)
            try? server.run()
            check(
                !Store.isStale(at: since, pid: getpid(), kind: .finished, now: Date()),
                "終わったセッションは子が起動しても残す")
            check(Store.isStale(at: since, pid: getpid(), kind: .permission, now: Date()), "許可待ちは子が起動したら消す")
            server.terminate()
            check(Store.isStale(at: now.addingTimeInterval(-61 * 60), pid: 0, now: now), "番号が無ければ1時間で捨てる")

            // 許可されてコマンドが動き出したら、終わるのを待たずに消す
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

        print(failures == 0 ? "selftest: ok" : "selftest: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ name: String) {
        guard !condition else { return }
        failures += 1
        print("FAIL: \(name)")
    }
}
