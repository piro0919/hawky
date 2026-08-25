#!/usr/bin/env node
// Claude Code のフックから呼ばれ、許可待ちの有無をファイルとして残す。
//   add   … 許可待ちが発生した（Notification / permission_prompt）
//   clear … そのセッションが動き出した＝待ちが解消した
// 標準入力にフックの JSON が来る。session_id と cwd だけを使う。
import { readFileSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const mode = process.argv[2] === "add" ? "add" : "clear";
const dir = join(homedir(), ".claude", "machiban", "pending");

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

const file = join(dir, `${id}.json`);
if (mode === "add") {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    file,
    JSON.stringify({
      session_id: id,
      cwd: input.cwd ?? "",
      at: Math.floor(Date.now() / 1000),
    }),
  );
} else {
  rmSync(file, { force: true });
}
