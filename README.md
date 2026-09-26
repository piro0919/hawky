# Hawky

A macOS menu bar app that tells you when Claude Code is waiting for permission,
and takes you to it.

Run Claude Code in a few repositories at once, one Cursor or VS Code window
each, and
sooner or later one of them stops to ask whether it may run something. It then
sits there, silently, while you are looking at another window. You find out ten
minutes later.

Hawky keeps watch from the menu bar. When a session is waiting, a count appears
next to the hawk. Pick the session from the menu and Hawky brings that window,
and that tab, to the front — also when the window is tucked behind others as a
macOS tab.

macOS 14+. No Xcode needed: `./build.sh` compiles with the Swift that ships with
the Command Line Tools.

There is a page for it at [hawky.kkweb.io](https://hawky.kkweb.io).

## Installing

With Homebrew:

```bash
brew install --cask piro0919/tap/hawky
```

Or download the DMG from [Releases](https://github.com/piro0919/hawky/releases/latest)
and drag Hawky into Applications.

The first launch will be blocked: Hawky is signed with a self-signed certificate,
not an Apple Developer ID, so macOS cannot verify who made it. To let it through,
open **System Settings → Privacy & Security**, scroll to the bottom, and click
**Open Anyway** next to the message about Hawky. You only do this once.

Then open Hawky's menu, choose **Settings…**, and click **Connect** next to
Claude Code. Until you do, the menu says *Not connected to Claude Code* at the
top. Connecting adds Hawky's
hooks to `~/.claude/settings.json`; hooks and settings you already have are left
as they are, and the file is backed up next to itself as `settings.json.bak.hawky`
first. The hooks call Hawky itself, so nothing else — not even Node — needs to be
installed. **Disconnect** in the same place takes the hooks out.

Grant Accessibility access when Hawky asks — it needs it to bring windows to the
front.

Updates arrive through Sparkle. Hawky looks once at launch and only says
something when there is one.

## What it does

- **Counts the sessions that are waiting.** The number sits next to the hawk in
  the menu bar. With nothing waiting, the hawk is dimmed.
- **Takes you there in one click.** Each waiting session is a row in the menu,
  named "<session title> — <folder>", the way Cursor and VS Code name their
  windows.
- **Tells two windows on the same repository apart.** It matches the window by
  the title Claude Code gave the session, not only by the folder.
- **Works in Cursor and VS Code.** The hook notes which app the session runs
  in, and Hawky goes to that app. Split editors and preview tabs are handled.
- **Works with windows merged into macOS tabs** (`window.nativeTabs`).
  A background tab is not in the window list at all; Hawky finds it in the tab
  bar and presses it.
- **Clears itself as soon as the session moves on.** Approving, denying and
  typing a new prompt all count. A wait stays for as long as it lasts, and
  goes away when its Claude Code process does — so closing the editor never
  leaves the count stuck. Once a command is approved and running, the wait is
  cleared without waiting for the command to finish.
- **Settings…** holds the Claude Code connection, the language (follow the
  system, English or Japanese), Launch at Login and Check for Updates.

## How it works

Claude Code fires a `Notification` hook with `permission_prompt` when it stops
to ask. Hawky's hook writes one small file per waiting session to
`~/.claude/hawky/pending/`, with the session's title read from the end of its
transcript, the folder it was opened in, the ID of its Claude Code process and
the app it runs in. `PostToolUse`, `UserPromptSubmit` and `Stop` delete it
again. The hook is Hawky's own binary, run as `Hawky hook add` or
`Hawky hook clear`; it takes a few milliseconds. The app watches that folder and
does nothing else in the background.

When you pick a row, it looks for the session in this order:

1. A window whose title starts with the session's title
2. A macOS tab with that title, in the tab bar of the front window
3. An editor tab with that title, inside the windows of that repository, and
   then behind each background macOS tab in turn
4. Any window of that repository

## Building and checking

```bash
./build.sh
./Hawky.app/Contents/MacOS/Hawky --selftest
open Hawky.app --args --settings   # opens Settings; click Connect
```

`--selftest` checks the window-matching rules, the settings-file editing and the
expiry rules without touching any window. `--diag` logs each step of a search to
standard error. CI
runs it together with `swift format lint --strict`. Sparkle is fetched into
`Vendor/` on the first build.

The icon comes from `assets/icon-source.png`. `python3 Tools/make-icon.py` rounds
it, writes `AppIcon.icns`, and cuts the hawk out as the menu bar template. The
prompts that produced the artwork are in [docs/art-prompt.md](docs/art-prompt.md).

## License

MIT
