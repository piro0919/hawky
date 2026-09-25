#!/usr/bin/env node
// ~/.claude/settings.json に Hawky のフックを登録する。
// 既にある他のフックは触らない。何度流しても同じ結果になる。
//   node hook/install.mjs           … 登録
//   node hook/install.mjs --remove  … 解除
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const settingsPath = join(homedir(), ".claude", "settings.json");
const hookPath = join(dirname(fileURLToPath(import.meta.url)), "hawky-hook.mjs");
const remove = process.argv.includes("--remove");

const settings = existsSync(settingsPath)
  ? JSON.parse(readFileSync(settingsPath, "utf8"))
  : {};
if (existsSync(settingsPath)) copyFileSync(settingsPath, `${settingsPath}.bak.hawky`);

const isMine = (h) => String(h.command ?? "").includes("hawky-hook.mjs");
const entry = (mode) => ({
  type: "command",
  command: `node '${hookPath}' ${mode}`,
});

// まず自分の登録を全部消す。残っていると二重に積まれる
const hooks = settings.hooks ?? {};
for (const event of Object.keys(hooks)) {
  hooks[event] = hooks[event]
    .map((m) => ({ ...m, hooks: (m.hooks ?? []).filter((h) => !isMine(h)) }))
    .filter((m) => m.hooks.length > 0);
  if (hooks[event].length === 0) delete hooks[event];
}

if (!remove) {
  const add = (event, matcher, mode) => {
    hooks[event] ??= [];
    const found = hooks[event].find((m) => (m.matcher ?? "") === (matcher ?? ""));
    const target = found ?? (matcher === undefined ? { hooks: [] } : { matcher, hooks: [] });
    if (!found) hooks[event].push(target);
    target.hooks.push(entry(mode));
  };

  // 許可を求められたら1件足す
  add("Notification", "permission_prompt", "add");
  // そのセッションが動き出したら消す。許可・拒否・入力のどれでも解消とみなす
  add("PostToolUse", "*", "clear");
  add("UserPromptSubmit", undefined, "clear");
  add("Stop", undefined, "clear");
}

settings.hooks = hooks;
mkdirSync(dirname(settingsPath), { recursive: true });
writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
console.log(remove ? "Hawky のフックを外しました" : "Hawky のフックを登録しました");
