# Machiban

Claude Code が許可を待っていることに、メニューバーで気付くための常駐アプリ。

複数のセッションを同時に開いていると、どれかが許可を待って止まっていても気付けない。
Machiban はメニューバーに待ちの件数を出し、どのセッションが待っているかを一覧で見せ、
選んだセッションの Cursor ウィンドウを前面に出す。

## 仕組み

Claude Code のフックを使う。

- `Notification`（`permission_prompt`）で待ちが1件増える
- `PostToolUse` / `UserPromptSubmit` / `Stop` のいずれかで、そのセッションの待ちが消える
- 解消のフックが飛ばなかった待ちは10分で自動的に消える

待ちは `~/.claude/machiban/pending/` に1件1ファイルで置かれ、アプリはそこを見張る。

## 使う

```sh
./build.sh          # Machiban.app ができる
node hook/install.mjs   # ~/.claude/settings.json にフックを登録する
open ./Machiban.app
```

初回はアクセシビリティの許可を求められる。ウィンドウを前面に出すために要る。

外すとき:

```sh
node hook/install.mjs --remove
```

## 分かっていること

- Cursor の拡張として動かしている Claude Code でも、フックは発火する（実測）
- 一覧の行は作業ディレクトリ名で見分ける
- 前面に出せるのはウィンドウ単位まで。同じウィンドウの中のタブ切り替えは未対応
- メニューバーの常駐アイコンが埋まっていると、macOS がこのアイコンを画面外へ追いやる。
  そのとき項目の座標は `x = -9031` になる
