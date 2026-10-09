# Changelog

Notable changes to Hawky. `release.sh` publishes the section for the version being released as
its release notes, and stops if that section is missing or empty — so before releasing, rename
`Unreleased` to `[x.y.z] - YYYY-MM-DD` and commit.

Versions up to v0.1.5 predate this file; their history is in `git log`.

## [0.2.2] - 2026-10-09

### Changed

- The update window now follows the Mac's language, so it appears in Japanese on a Japanese
  Mac. It was always in English before.

## [0.2.1] - 2026-10-09

### Fixed

- When sessions in two folders have the same title, choosing one brings up the window for its
  own folder instead of whichever matching window came first.

## [0.2.0] - 2026-10-07

### Added

- The menu bar shows how many sessions are working, with a small spinner, below the
  permission count, which now carries a pause mark. Working sessions are listed under
  *Working* in the menu. Pressing Esc is picked up from the transcript, since Claude Code
  fires no hook for it. Reconnect from Settings to register the new hooks.
- Hawky honors `CLAUDE_CONFIG_DIR`, and Settings has a Config Folder picker that takes
  precedence over it — useful because an app opened from Finder does not see shell variables.

### Fixed

- When connecting to Claude Code fails, Settings shows the reason instead of only the file path.
- Changing the config folder in Settings moves Hawky's hooks to the new folder instead of
  leaving them behind in the old `settings.json`. Errors name the file that could not be
  updated.

### Internal

- The build verifies the SHA-256 of the Sparkle archive it downloads.
- The release script runs the self test, and refuses a dirty working tree, a commit that is not
  on origin/main, an existing tag, a version the built app does not carry, or a missing
  changelog section.
- Releases stop instead of falling back to an ad-hoc signature when the signing certificate is
  missing.
