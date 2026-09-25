#!/usr/bin/env node
// Claude Code のフックから呼ばれ、許可待ちの有無をファイルとして残す。
//   add   … 許可待ちが発生した（Notification / permission_prompt）
//   clear … そのセッションが動き出した＝待ちが解消した
// 標準入力にフックの JSON が来る。session_id と cwd、それに transcript から拾う題名を使う。
import {
  readFileSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  openSync,
  fstatSync,
  readSync,
  closeSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const mode = process.argv[2] === "add" ? "add" : "clear";
const dir = join(homedir(), ".claude", "hawky", "pending");

let input = {};
try {
  input = JSON.parse(readFileSync(0, "utf8") || "{}");
} catch {
  // フックは何があっても Claude Code を止めない。読めなければ黙って終わる
  process.exit(0);
}

// ファイル名になるので、パスを壊す文字は落とす
const id = String(input.session_id ?? "").replace(/[^A-Za-z0-9_-]/g, "");
if (!id) process.exit(0);

// Cursor のウィンドウ名とタブ名になるのは、Claude Code が付けた題名。
// transcript の末尾にある最後の ai-title がそれ。どのウィンドウで待っているかを
// 作業ディレクトリ名より細かく見分けるために要る
function sessionTitle(path) {
  if (!path) return "";
  let fd;
  try {
    fd = openSync(path, "r");
    const { size } = fstatSync(fd);
    // 題名は会話が進むごとに追記される。末尾だけ読めば足りる
    const length = Math.min(size, 512 * 1024);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, size - length);

    const lines = buffer.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('"ai-title"')) continue;
      try {
        const record = JSON.parse(lines[i]);
        if (record.type === "ai-title" && record.aiTitle) return String(record.aiTitle);
      } catch {
        // 先頭の1行は途中で切れている。落ちるのは織り込み済み
      }
    }
  } catch {
    return "";
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
  return "";
}

// セッションを開いたときのフォルダ。フックに来る cwd はその時点のシェルの居場所で、
// セッションの途中で cd すると別のリポジトリを指す。Cursor の窓が開いているのは
// 開いたときのフォルダなので、窓を探すにも一覧に出すにもこちらを使う。
// transcript の各行が cwd を持っていて、最初の行がそれにあたる
function projectFolder(path) {
  if (!path) return "";
  let fd;
  try {
    fd = openSync(path, "r");
    const length = Math.min(fstatSync(fd).size, 256 * 1024);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, 0);

    for (const line of buffer.toString("utf8").split("\n")) {
      if (!line.includes('"cwd"')) continue;
      try {
        const record = JSON.parse(line);
        if (record.cwd) return String(record.cwd);
      } catch {
        // 読んだ範囲の末尾の1行は途中で切れている。落ちるのは織り込み済み
      }
    }
  } catch {
    return "";
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
  return "";
}

const file = join(dir, `${id}.json`);
if (mode === "add") {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    file,
    JSON.stringify({
      session_id: id,
      cwd: input.cwd ?? "",
      project: projectFolder(input.transcript_path) || input.cwd || "",
      title: sessionTitle(input.transcript_path),
      at: Math.floor(Date.now() / 1000),
    }),
  );
} else {
  rmSync(file, { force: true });
}
