# Changelog

Notable changes to Hawky. `release.sh` publishes the section for the version being released as
its release notes, and stops if that section is missing or empty — so before releasing, rename
`Unreleased` to `[x.y.z] - YYYY-MM-DD` and commit.

Versions up to v0.1.5 predate this file; their history is in `git log`.

## [Unreleased]

### Added

- Hawky honors `CLAUDE_CONFIG_DIR`, and Settings has a Config Folder picker that takes
  precedence over it — useful because an app opened from Finder does not see shell variables.

### Fixed

- When connecting to Claude Code fails, Settings shows the reason instead of only the file path.

### Internal

- The build verifies the SHA-256 of the Sparkle archive it downloads.
- The release script runs the self test, and refuses a dirty working tree, a commit that is not
  on origin/main, an existing tag, a version the built app does not carry, or a missing
  changelog section.
- Releases stop instead of falling back to an ad-hoc signature when the signing certificate is
  missing.
