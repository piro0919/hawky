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
            check(Focus.points("複数リポジトリでの", at: "複数リポジトリでのエージェント実行"), "`…` が無くても前方一致で当たる")

            // 短い断片で前方一致を許すと、似た名前のファイルを開いているだけの窓に当たる
            check(!Focus.points("複数…", at: "複数リポジトリでのエージェント実行"), "6文字未満の断片では当てない")
            check(!Focus.points("README.md", at: "READMEを直す"), "前方一致しなければ当てない")
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
