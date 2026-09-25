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
