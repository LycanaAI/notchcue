# Changelog

## Unreleased

- README reorganised: what it is, install, how to use, contributing.

## 0.2.1

Signed, notarised releases and a Homebrew cask.

### Added

- **Signed and notarised releases.** `make release` builds NotchCue.app for Apple silicon and Intel, signs it with a Developer ID and the hardened runtime, has Apple notarise it and staples the result into `dist/NotchCue-<version>.zip`. macOS opens releases without warnings, and permissions carry over between updates.
- **Homebrew cask**: `brew install --cask lycanaai/tap/notchcue`.
- **`notchcue` inside the app.** The launcher now ships in `NotchCue.app/Contents/Resources/notchcue`. Run from an installed app (or a link to it, as Homebrew makes), it opens that app and compiles nothing.
- `make publish` tags the release, uploads the zip to GitHub Releases and updates the Homebrew cask. See docs/releasing.md.

### Changed

- Local builds are signed with your Apple Development certificate when there is one, so macOS stops asking for microphone and speech permission after every rebuild. `NOTCHCUE_SIGN_IDENTITY` picks a different certificate (`-` for ad-hoc); without a certificate, builds are signed ad-hoc as before.
- Rebuilding no longer replaces a notarised release in `~/Applications` with a local build.
- CI runs `make check` on pull requests and pushes to main.

### Fixed

- Builds now target macOS 13, as Info.plist says. They used to target the macOS they were built on, so a build from a newer Mac wouldn't open on an older one.

## 0.2.0

NotchCue can now be opened and controlled without the command line.

### Added

- **App you can open from Spotlight or Launchpad.** `make install` copies NotchCue.app into ~/Applications as well as linking the `notchcue` command.
- **Welcome panel** when there's no script: drop a file, press ⌘O, paste with ⌘V, or try a sample.
- **Menu bar icon** with Open Script, Open Recent (last 5), Paste Script, Pause/Resume, Follow Voice / Steady Scroll, Back to Top, Text Size, Speed, Show/Hide Panel, Minimise, Settings, Help, Full Guide and Quit.
- **Minimise** (M, the ⌃ hover button or the menu): the panel shrinks to a small pill under the notch with a status dot, the line you're on and how far through you are. Voice following keeps tracking while minimised; a steady scroll stops and counts down again when you expand. Click the pill or press M to expand.
- **Hover controls**: pause, voice/steady, smaller and bigger text, minimise, settings, help and close. They fade in when the mouse is over the panel and hide again while you read.
- **Help overlay** (?, the ? button or Help in the menu) with the keys, how voice following works, the Dictation setting and permissions, and a link to the full guide.
- **Settings window** (⌘,): text size, panel width and height, speech language, start mode, steady speed and countdown. Saved between runs; command-line options still win for that run.
- **More file types**: Markdown (headings become cues, formatting is stripped), Word (.docx, .doc), RTF, RTFD, OpenDocument, HTML, web archives and PDF. Files can be dropped onto the panel or onto the app icon, opened with ⌘O or pasted with ⌘V. Unsupported files show a clear message.
- `--voice` (overrides a Settings start mode of steady scroll), `--sample`, `--show` (opens with help, controls, minimised or settings showing) and `--self-test`.
- Built-in tests for the Markdown converter, file loading and the voice matcher, run by `make check` and CI.
- docs/script-format.md: the full rules for cues, Markdown and other formats.

### Changed

- `notchcue` with no script now shows the welcome panel instead of sample text. Use `--sample` for the old behaviour.
- The status line at the bottom of the panel has a black backing so it doesn't run into the script.
- `notchcue --validate` (and `make build`) now only checks and builds; it no longer opens the app.
- The source is split into a few files under `Sources/`.

## 0.1.0

First release.

- A teleprompter panel that hangs from the notch, right under the camera.
- Follows your voice with Apple's on-device speech recognition: words you've said turn grey, it waits when you pause, and jumps back when you say a line again.
- Steady-scroll mode with a countdown and adjustable pace.
- Keys: V, Space, ↑/↓, +/−, R, Esc/Q.
- `notchcue` command for files, `--text` and stdin, returning straight away (or `--wait`).
- `--debug` logging to ~/Library/Logs/notchcue.log.
